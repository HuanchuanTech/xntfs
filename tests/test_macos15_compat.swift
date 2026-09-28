import Foundation

@main
struct CompatibilityTests {
    @MainActor
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            .appendingPathComponent("compat-unit-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let app = root.appendingPathComponent("A ' quoted.app", isDirectory: true)
        let extensionURL = app.appendingPathComponent("Contents/Extensions/ntfs3g.appex", isDirectory: true)
        let executable = extensionURL.appendingPathComponent("Contents/MacOS/ntfs3g")
        try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plistURL = extensionURL.appendingPathComponent("Contents/Info.plist")
        func writeInfo(id: String, executable: String = "ntfs3g") throws {
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundleExecutable": executable],
                                              format: .xml, options: 0).write(to: plistURL)
        }
        assert(ExtensionStatus.embeddedExtension(in: app) == nil)
        try writeInfo(id: ExtensionStatus.bundleID)
        assert(ExtensionStatus.embeddedExtension(in: app) == nil)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        assert(ExtensionStatus.embeddedExtension(in: app) == extensionURL)
        try writeInfo(id: "someone.else")
        assert(ExtensionStatus.embeddedExtension(in: app) == nil)
        try writeInfo(id: ExtensionStatus.bundleID, executable: "../escape")
        assert(ExtensionStatus.embeddedExtension(in: app) == nil)

        let status = ExtensionStatus()
        assert(status.isEnabled == nil && !status.isInstalled && status.registrationOK == nil)
        if ExtensionStatus.needsLegacyCompatibility {
            try writeInfo(id: ExtensionStatus.bundleID)
            await status.refresh(appURL: app)
            assert(status.state == .bundled && status.isEnabled == nil && !status.isInstalled)
            assert(status.moduleURLs.isEmpty && status.registrationOK == nil)
            try writeInfo(id: "someone.else")
            await status.refresh(appURL: app)
            assert(status.state == .notInstalled && status.bundledExtensionURL == nil)
        }
        assert(LegacyMountCommand.quote("a'b $HOME; /tmp") == "'a'\"'\"'b $HOME; /tmp'")
        assert(LegacyMountCommand.bootSessionUUID() != nil)
        let script = root.appendingPathComponent("A ' script.sh")
        let boot = UUID().uuidString
        var device = NTFSDevice(id: "disk6s1", volumeName: "Test", sizeBytes: 66060288, kind: .diskImage,
                                contentHint: "Windows_NTFS", isRemovable: true, devicePath: "/dev/disk6s1")
        func command(_ d: NTFSDevice, readOnly: Bool = false) -> String? {
            LegacyMountCommand.mount(device: d, readOnly: readOnly, script: script, app: app, bootSession: boot)
        }
        assert(command(device) == nil)
        device.registryEntryID = 4294968000
        assert(command(device)!.contains("'disk6s1' 4294968000 66060288 '\(boot)' auto"))
        try Data("printf '%s\\n' \"$@\"\n".utf8).write(to: script)
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command(device)!]
        process.standardOutput = output
        try process.run()
        let arguments = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        assert(process.terminationStatus == 0)
        assert(arguments.split(separator: "\n").map(String.init) ==
               ["mount", "disk6s1", "4294968000", "66060288", boot, "auto", app.path])
        assert(command(device, readOnly: true)!.contains("'\(boot)' ro"))
        var changed = device
        changed.mediaWritable = false
        assert(command(changed)!.contains("'\(boot)' ro"))
        changed = device
        changed.registryEntryID = 4294968001
        assert(changed != device)
        changed.sizeBytes = 0
        assert(command(changed) == nil)
        assert(LegacyMountCommand.mount(device: device, readOnly: false, script: script, app: app, bootSession: "bad") == nil)
        for mounted in [false, true] {
            for kind in [DeviceKind.diskImage, .removable, .fixed] {
                device.kind = kind
                device.state = mounted ? .mounted(URL(fileURLWithPath: "/Volumes/Test")) : .unmounted
                assert(command(device) != nil)
            }
        }
        print("PASS: bundle detection, unknown status, command quoting, identity, read-only and mounted/unmounted devices.")
    }
}
