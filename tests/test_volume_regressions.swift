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
        normal.teardown()
        print("PASS: FSKit free-space fields, writable flags, and open-unlink emulation opt-in")

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
        let root = ntfs3gItem(ino: NFSK_ROOT_INO, parentIno: NFSK_PARENT_OF_ROOT, name: FSFileName(string: "/"))
        let (item, name) = try await fallback.lookupItem(named: FSFileName(string: "volumemixed.txt"), inDirectory: root)
        precondition((item as? ntfs3gItem)?.ino == mixed && name.string == "VolumeMiXeD.txt")
        print("PASS: effective read-only fallback reaches FSKit mount options; canonical lookup reaches Swift")
    }
}
