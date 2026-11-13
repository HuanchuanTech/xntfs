import Foundation
import FSKit

// Ordinary-file fixture only. Kernel buffer ownership and installed FSKit remain separate.
@main
struct CompressedWriteGuardTests {
    static func expect(_ code: Int32, _ operation: () async throws -> Void) async throws {
        do {
            try await operation()
            preconditionFailure("Expected errno \(code)")
        } catch {
            let error = error as NSError
            precondition(error.domain == NSPOSIXErrorDomain && error.code == Int(code), "Unexpected error: \(error)")
        }
    }

    static func main() async throws {
        precondition(CommandLine.arguments.count == 3)
        var error: Int32 = 0
        guard let pointer = nfsk_backend_from_file(CommandLine.arguments[1], 1, &error) else { throw posixError(error) }
        let backend = NTFSBackend(backend: pointer, retain: nil, cleanup: {}, writable: true)
        let legacy = CommandLine.arguments[2] == "legacy"
        let volume = try ntfs3gVolume(backend: backend, activationBackend: { _, _ in nil },
                                    onContainerStatusChange: { _ in }, legacyOpenUnlink: legacy)
        let root = ntfs3gItem(ino: NFSK_ROOT_INO, parentIno: NFSK_PARENT_OF_ROOT, name: FSFileName(string: "/"))
        let ops = volume as any FSVolume.Operations
        let get = FSItem.GetAttributesRequest()
        get.wantedAttributes = [.size, .allocSize, .modifyTime, .changeTime]
        let payload = Data(repeating: 82, count: 700)
        let key = FSFileName(string: "com.apple.testCompressed")
        for name in ["Empty", "Small", "High"] {
            let (item, _) = try await ops.lookupItem(named: FSFileName(string: name), inDirectory: root)
            let before = try await volume.attributes(get, of: item)
            for modes: FSVolume.OpenModes in [[.write], [.read, .write]] {
                try await expect(ENOTSUP) { try await volume.openItem(item, modes: modes) }
            }
            try await volume.openItem(item, modes: [.read])
            try await expect(ENOTSUP) { _ = try await volume.write(contents: payload, to: item, at: 0) }
            let resize = FSItem.SetAttributesRequest()
            resize.size = before.size + 700
            try await expect(ENOTSUP) { _ = try await volume.setAttributes(resize, on: item) }
            precondition(!resize.wasAttributeConsumed(.size))
            for policy: FSVolume.SetXattrPolicy in [.alwaysSet, .mustCreate] {
                try await expect(EPERM) { try await volume.setXattr(named: key, to: payload, on: item, policy: policy) }
            }
            try await expect(ENOATTR) { try await volume.setXattr(named: key, to: payload, on: item, policy: .mustReplace) }
            let zero = try await volume.write(contents: Data(), to: item, at: 0)
            precondition(zero == 0)
            try await volume.closeItem(item, modes: [])
            try await volume.closeItem(item, modes: [])
            try await volume.synchronize(flags: .wait)
            let after = try await volume.attributes(get, of: item)
            precondition(after.size == before.size && after.allocSize == before.allocSize)
            precondition(after.modifyTime.tv_sec == before.modifyTime.tv_sec && after.modifyTime.tv_nsec == before.modifyTime.tv_nsec)
            precondition(after.changeTime.tv_sec == before.changeTime.tv_sec && after.changeTime.tv_nsec == before.changeTime.tv_nsec)
            let names = try await volume.xattrs(of: item)
            precondition(names.isEmpty)
        }
        // A rejected compressed operation must not poison a later ordinary write.
        let (plain, _) = try await ops.lookupItem(named: FSFileName(string: "Plain"), inDirectory: root)
        try await volume.openItem(plain, modes: [.read, .write])
        let written = try await volume.write(contents: payload, to: plain, at: 0)
        precondition(written == payload.count)
        try await volume.setXattr(named: key, to: payload, on: plain, policy: .mustCreate)
        let bytes = try await volume.xattr(named: key, of: plain)
        precondition(bytes == payload)
        try await volume.synchronize(flags: .wait)
        try await volume.closeItem(plain, modes: [])
        let released = await volume.teardown()
        let repeated = await volume.teardown()
        precondition(released == 0 && repeated == 0)
        print("PASS: \(legacy ? "legacy" : "modern") compressed rejection, unchanged metadata, unconsumed size, ordinary write/xattr and repeated release")
    }
}
