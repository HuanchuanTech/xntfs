import CryptoKit
import Foundation
import AppKit

// Run in a signed, sandboxed test bundle with the FSKit Mounter entitlement.
// The host-side verifier checks Finder-equivalent I/O, which is outside this app's sandbox.
@main
struct NativeImageTests {
    @MainActor
    static func main() {
        setbuf(stdout, nil)
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        Task {
            do {
                try await run()
                exit(0)
            } catch {
                print("FAIL native: \(error)")
                exit(1)
            }
        }
        application.run()
        print("FAIL native: application event loop stopped before completion")
        exit(1)
    }

    @MainActor
    static func run() async throws {
        if CommandLine.arguments.contains("--event-loop-smoke") {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                                styleMask: [], backing: .buffered, defer: false)
            panel.alphaValue = 0
            let timer = Timer(timeInterval: 0.1, repeats: false) { _ in NSApplication.shared.abortModal() }
            RunLoop.main.add(timer, forMode: .modalPanel)
            _ = NSApplication.shared.runModal(for: panel)
            panel.orderOut(nil)
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { continuation.resume() }
            }
            print("PASS native event loop: async continuation after modal close")
            return
        }
        let status = ExtensionStatus()
        await status.refresh()
        let expected = ProcessInfo.processInfo.environment["XNTFS_TEST_EXTENSION"]
        guard status.isEnabled == true, status.installedCount == 1,
              status.moduleURLs.map(\.path) == [expected].compactMap({ $0 }) else {
            throw TestFailure("Expected one enabled installed extension: \(status.diagnosticReport)")
        }
        print("EXTENSION \(status.moduleURLs[0].path)")
        let fm = FileManager.default
        let preferencesBefore = try preferenceHash()
        print("PREFERENCES before=\(preferencesBefore)")
        guard let path = ProcessInfo.processInfo.environment["XNTFS_TEST_IMAGE"] else {
            throw TestFailure("The runner must supply its owned raw image")
        }
        let source = URL(fileURLWithPath: path)
        let directory = source.deletingLastPathComponent()
        guard directory.lastPathComponent.hasPrefix("xntfs-native-tests-") else {
            throw TestFailure("Unexpected raw test directory")
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        panel.prompt = "授权测试目录"
        panel.message = "仅选择本轮 xntfs-native-tests 目录。测试只修改里面的一次性镜像。"
        print("AUTHORIZE raw test directory: \(directory.path)")
        guard panel.runModal() == .OK, let selected = panel.url,
              selected.standardizedFileURL == directory.standardizedFileURL else {
            throw TestFailure("The exact owned test directory must be selected")
        }
        guard selected.startAccessingSecurityScopedResource() else {
            throw TestFailure("No security-scoped directory access")
        }
        defer { selected.stopAccessingSecurityScopedResource() }
        print("AUTHORIZED raw test directory: \(directory.path)")
        let attributes = try fm.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw TestFailure("Raw input must be an owned regular file")
        }
        let file = try FileHandle(forUpdating: source)
        var serial = UInt64.random(in: 1...UInt64.max).littleEndian
        let bytes = withUnsafeBytes(of: &serial) { Data($0) }
        let length = try file.seekToEnd()
        try file.seek(toOffset: 0x48)
        try file.write(contentsOf: bytes)
        try file.seek(toOffset: length - 512 + 0x48)
        try file.write(contentsOf: bytes)
        try file.synchronize()
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
            print("PASS raw input and non-NTFS rejection checks")
            for phase in ["ro", "rw", "remount-ro", "prepare-hibernation", "fallback-ro"] {
                let readOnly = phase == "ro" || phase == "remount-ro"
                let expectedReadOnly = readOnly || phase == "fallback-ro"
                let model = AppModel(monitor: DiskArbitrationMonitor(), settings: AppSettings(defaults: nil))
                print("BEGIN raw mount phase=\(phase)")
                let url = try await model.mountImage(source, readOnly: readOnly)
                guard let image = model.mountedImages.first(where: { $0.mountPoint == url }) else {
                    throw TestFailure("Mounted image missing from AppModel")
                }
                active = image
                print("MOUNT mode=\(phase) readOnly=\(image.readOnly) bytes=\(image.sizeBytes) source=\(image.source.absoluteString) expected=\(source.absoluteString)")
                guard image.readOnly == expectedReadOnly,
                      image.source.standardizedFileURL == source.standardizedFileURL else {
                    throw TestFailure("Incorrect image identity/access")
                }
                // Passive snapshots may have unknown capacity; the host verifier
                // checks live statfs values separately from mount identity.
                let reopenedModel = AppModel(monitor: DiskArbitrationMonitor(), settings: AppSettings(defaults: nil))
                reopenedModel.refreshDevices()
                guard reopenedModel.mountedImages.contains(where: {
                    $0.isSameMount(as: image) && $0.readOnly == expectedReadOnly
                }) else {
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
            let preferencesAfter = try preferenceHash()
            print("PREFERENCES after=\(preferencesAfter)")
            guard preferencesAfter == preferencesBefore else {
                throw TestFailure("App Group preferences changed")
            }
            print("PASS cleanup: all owned mounts removed; raw image retained for host evidence cleanup")
        } catch {
            if let active { try? await ImageMountService.unmount(active) }
            print("PRESERVED failing raw image: \(source.path)")
            throw error
        }
    }

    static func preferenceHash() throws -> String {
        let group = "529LJDH392.group.com.huanchuan.xntfs"
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw TestFailure("Cannot inspect the existing App Group preferences")
        }
        let file = root.appendingPathComponent("Library/Preferences/\(group).plist")
        do {
            return try SHA256.hash(data: Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return "absent"
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
