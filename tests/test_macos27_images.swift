import CryptoKit
import Foundation

// Run in a signed, sandboxed test bundle with the FSKit Mounter entitlement.
// The host-side verifier checks Finder-equivalent I/O, which is outside this app's sandbox.
@main
struct NativeImageTests {
    @MainActor
    static func main() async throws {
        setbuf(stdout, nil)
        let status = ExtensionStatus()
        await status.refresh()
        let expected = ProcessInfo.processInfo.environment["XNTFS_TEST_EXTENSION"]
        guard status.isEnabled == true, status.installedCount == 1,
              status.moduleURLs.map(\.path) == [expected].compactMap({ $0 }) else {
            throw TestFailure("Expected one enabled installed extension: \(status.diagnosticReport)")
        }
        print("EXTENSION \(status.moduleURLs[0].path)")
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("xntfs-native-tests-\(UUID())")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("quoted ' NTFS \u{955C}\u{50CF}.img")
        try fm.copyItem(at: Bundle.main.url(forResource: "input", withExtension: "img")!, to: source)
        let file = try FileHandle(forUpdating: source)
        var serial = UInt64.random(in: 1...UInt64.max).littleEndian
        let bytes = withUnsafeBytes(of: &serial) { Data($0) }
        let length = try file.seekToEnd()
        try file.seek(toOffset: 0x48)
        try file.write(contentsOf: bytes)
        try file.seek(toOffset: length - 512 + 0x48)
        try file.write(contentsOf: bytes)
        try file.close()

        var active: MountedImage?
        do {
            let invalid = directory.appendingPathComponent("partitioned.img")
            var mbr = Data(repeating: 0, count: 512)
            mbr[510] = 0x55; mbr[511] = 0xaa
            try mbr.write(to: invalid)
            for url in [directory, invalid] {
                do {
                    try ImageMountService.validateImage(url)
                    throw TestFailure("Accepted a non-NTFS image")
                } catch ImageMountError.unsupportedImage { }
            }
            try ImageMountService.validateImage(source)
            let initialHash = try hash(source)
            for phase in ["ro", "rw", "remount-ro"] {
                let readOnly = phase != "rw"
                let model = AppModel()
                let url = try await model.mountImage(source, readOnly: readOnly)
                guard let image = model.mountedImages.first(where: { $0.mountPoint == url }) else {
                    throw TestFailure("Mounted image missing from AppModel")
                }
                active = image
                print("MOUNT mode=\(phase) readOnly=\(image.readOnly) bytes=\(image.sizeBytes) source=\(image.source.absoluteString) expected=\(source.absoluteString)")
                guard image.readOnly == readOnly,
                      image.source.standardizedFileURL == source.standardizedFileURL,
                      image.sizeBytes > 0 else { throw TestFailure("Incorrect image identity/access/capacity") }
                let reopenedModel = AppModel()
                reopenedModel.refreshDevices()
                guard reopenedModel.mountedImages.contains(image) else {
                    throw TestFailure("Image not rediscovered by a new model")
                }
                do {
                    _ = try await model.mountImage(source, readOnly: !readOnly)
                    throw TestFailure("Duplicate mount was accepted")
                } catch ImageMountError.alreadyMounted { }
                let alias = directory.appendingPathComponent("alias.img")
                try? fm.removeItem(at: alias)
                try fm.createSymbolicLink(at: alias, withDestinationURL: source)
                do {
                    _ = try await model.mountImage(alias, readOnly: readOnly)
                    throw TestFailure("Symlink duplicate mount was accepted")
                } catch ImageMountError.alreadyMounted { }
                let json = try JSONSerialization.data(withJSONObject: ["phase": phase, "mountPath": url.path])
                print("CHECK " + String(decoding: json, as: UTF8.self))
                guard readLine() == "ok" else { throw TestFailure("Host I/O verification failed") }
                await model.unmountImage(image)
                guard model.lastError == nil, !model.mountedImages.contains(where: { $0.id == image.id }) else {
                    throw TestFailure("Unmount or list refresh failed: \(model.lastError ?? "still listed")")
                }
                active = nil
                if phase == "ro", try hash(source) != initialHash {
                    throw TestFailure("Read-only mount changed the image")
                }
                print("PASS \(phase): mount, actual mode, model recovery, duplicate rejection, unmount")
            }
            try fm.removeItem(at: directory)
            print("PASS cleanup")
        } catch {
            if let active { try? await ImageMountService.unmount(active) }
            if !ImageMountService.mountedImages().contains(where: { $0.source == source }) {
                try? fm.removeItem(at: directory)
            }
            throw error
        }
    }

    static func hash(_ file: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize()
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
