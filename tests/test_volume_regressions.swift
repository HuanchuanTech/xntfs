import Foundation
import FSKit

@main
struct VolumeRegressionTests {
    static func backend(_ image: URL, writable: Bool) throws -> NTFSBackend {
        var error: Int32 = 0
        guard let pointer = nfsk_backend_from_file(image.path, writable ? 1 : 0, &error) else {
            throw posixError(error)
        }
        return NTFSBackend(backend: pointer, retain: nil, cleanup: {}, writable: writable)
    }

    static func main() async throws {
        let image = URL(fileURLWithPath: CommandLine.arguments[1])
        let normal = try ntfs3gVolume(backend: backend(image, writable: true),
                                     activationBackend: { _, _ in nil }, onContainerStatusChange: { _ in })
        let stats = normal.volumeStatistics
        precondition(stats.availableBlocks > stats.totalBlocks / 2)
        precondition(!normal.requestedMountOptions.contains(.readOnly))
        precondition(normal.enableOpenUnlinkEmulation)
        precondition(normal.supportedVolumeCapabilities.caseFormat == .insensitiveCasePreserving)
        precondition(normal.maximumFileSize == UInt64(Int64.max) && normal.maximumFileSizeInBits == 64)
        precondition(normal.maximumXattrSize == Int(NFSK_MAX_XATTR_SIZE))
        let root = ntfs3gItem(ino: NFSK_ROOT_INO, parentIno: NFSK_PARENT_OF_ROOT, name: FSFileName(string: "/"))
        let xattrName = FSFileName(string: "com.apple.metadata:_kMDItemUserTags")
        let value = Data("test tags".utf8)
        try await normal.setXattr(named: xattrName, to: value, on: root, policy: .mustCreate)
        let readback = try await normal.xattr(named: xattrName, of: root)
        let names = try await normal.xattrs(of: root)
        precondition(readback == value && names.contains(where: { $0.string == xattrName.string }))
        do {
            try await normal.setXattr(named: xattrName, to: Data(), on: root, policy: .mustCreate)
            preconditionFailure("mustCreate accepted a duplicate")
        } catch { precondition((error as NSError).code == Int(EEXIST)) }
        try await normal.setXattr(named: xattrName, to: Data(), on: root, policy: .mustReplace)
        let empty = try await normal.xattr(named: xattrName, of: root)
        precondition(empty.isEmpty)
        try await normal.setXattr(named: xattrName, to: nil, on: root, policy: .delete)
        do {
            _ = try await normal.xattr(named: xattrName, of: root)
            preconditionFailure("deleted xattr still exists")
        } catch { precondition((error as NSError).code == Int(ENOATTR)) }
        normal.teardown()
        print("PASS: FSKit free-space fields, writable flags, and open-unlink emulation opt-in")
        print("PASS: signed 64-bit size limits and native FSKit xattr create/read/list/replace/delete")

        let prepared = try backend(image, writable: true)
        var error: Int32 = 0
        guard let handle = nfsk_mount(prepared.backend, false, &error) else { throw posixError(error) }
        let mixed = nfsk_create(handle, NFSK_ROOT_INO, "VolumeMiXeD.txt", UInt32(NFSK_TYPE_FILE), &error)
        let fixture = nfsk_create(handle, NFSK_ROOT_INO, "hiberfil.sys", UInt32(NFSK_TYPE_FILE), &error)
        precondition(mixed != 0 && fixture != 0)
        var bytes = [UInt8](repeating: 0, count: 4096)
        bytes.replaceSubrange(0..<4, with: "hibr".utf8)
        let count = bytes.withUnsafeBytes { nfsk_write(handle, fixture, 0, $0.baseAddress, Int64($0.count), &error) }
        precondition(count == 4096)
        nfsk_umount(handle)
        nfsk_backend_free(prepared.backend)

        let fallback = try ntfs3gVolume(backend: backend(image, writable: true),
                                       activationBackend: { _, _ in nil }, onContainerStatusChange: { _ in })
        defer { fallback.teardown() }
        precondition(fallback.requestedMountOptions.contains(.readOnly))
        let (item, name) = try await fallback.lookupItem(named: FSFileName(string: "volumemixed.txt"), inDirectory: root)
        precondition((item as? ntfs3gItem)?.ino == mixed && name.string == "VolumeMiXeD.txt")
        print("PASS: effective read-only fallback reaches FSKit mount options; canonical lookup reaches Swift")
    }
}
