import AppKit
import SwiftUI

@MainActor
enum LegacySheetProbe {
    struct Snapshot {
        let selected: NTFSDevice
        let current: NTFSDevice?
        let command: String?
    }
    static var latest: Snapshot?
    static var renders = 0
    static func observe(selected: NTFSDevice, current: NTFSDevice?, command: String?) {
        latest = Snapshot(selected: selected, current: current, command: command)
        renders += 1
    }
}

@main
@MainActor
struct LegacySheetTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { print("FAIL: \(message)"); exit(1) }
    }

    static func settle(_ host: NSHostingView<AnyView>?, until predicate: () -> Bool) {
        let end = Date().addingTimeInterval(5)
        repeat {
            host?.layoutSubtreeIfNeeded()
            if predicate() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        } while Date() < end
        check(false, "hosted view did not settle")
    }

    static func device(registry: UInt64?) -> NTFSDevice {
        var value = NTFSDevice(id: "disk42s1", volumeName: "Selected", sizeBytes: 66060288,
                               kind: .removable, contentHint: "Windows_NTFS", isRemovable: true,
                               devicePath: "/dev/disk42s1")
        value.registryEntryID = registry
        return value
    }

    static func root(_ selected: NTFSDevice, _ model: AppModel) -> AnyView {
        AnyView(LegacyMountSheet(device: selected).environment(model))
    }

    static func host(_ selected: NTFSDevice, _ model: AppModel) -> NSHostingView<AnyView> {
        LegacySheetProbe.latest = nil
        let view = NSHostingView(rootView: root(selected, model))
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 660)
        settle(view) { LegacySheetProbe.latest != nil }
        return view
    }

    static func changed(_ view: NSHostingView<AnyView>, _ action: () -> Void) {
        let before = LegacySheetProbe.renders
        action()
        settle(view) { LegacySheetProbe.renders > before }
    }

    static var snapshot: LegacySheetProbe.Snapshot { LegacySheetProbe.latest! }

    static func stale(registry: UInt64?) {
        let original = device(registry: registry)
        let model = AppModel(monitor: nil, settings: AppSettings(defaults: nil))
        model.receiveDevices([original])
        let view = host(original, model)
        var replacement = original
        replacement.discoveryID = UUID()
        replacement.state = .mounted(URL(fileURLWithPath: "/Volumes/Synthetic", isDirectory: true))
        replacement.mountedFileSystemType = "xntfs"
        changed(view) { model.receiveDevices([replacement]) }
        print("Stale lookup registry=\(registry.map(String.init) ?? "nil"): current=\(snapshot.current != nil), command=\(snapshot.command != nil)")
        check(snapshot.selected.isSameDevice(as: original), "initial selection changed without a new sheet")
        check(snapshot.current == nil && snapshot.command == nil, "old sheet borrowed a rediscovered observation")
        view.rootView = AnyView(EmptyView())
    }

    static func parentChange() {
        let original = device(registry: 12345)
        let model = AppModel(monitor: nil, settings: AppSettings(defaults: nil))
        model.receiveDevices([original])
        let view = host(original, model)
        var replacement = original
        replacement.discoveryID = UUID()
        changed(view) {
            model.receiveDevices([replacement])
            // A parent may reconstruct the same presented view with newer input.
            view.rootView = root(replacement, model)
        }
        print("Parent replacement: original selected=\(snapshot.selected.isSameDevice(as: original)), command=\(snapshot.command != nil)")
        check(snapshot.selected.isSameDevice(as: original), "parent update retargeted the open sheet")
        check(snapshot.current == nil && snapshot.command == nil, "retargeted sheet offers a replacement command")
        view.rootView = AnyView(EmptyView())
        let reopened = host(replacement, model)
        check(snapshot.selected.isSameDevice(as: replacement) && snapshot.current?.isSameDevice(as: replacement) == true,
              "newly opened sheet did not select the current observation")
        check(snapshot.command != nil, "fresh valid selection lost command")
        reopened.rootView = AnyView(EmptyView())
    }

    static func healthy() {
        var current = device(registry: 12345)
        let original = current
        let settings = AppSettings(defaults: nil)
        let model = AppModel(monitor: nil, settings: settings)
        model.receiveDevices([current])
        let view = host(current, model)
        check(snapshot.command?.contains(" auto ") == true, "normal writable command missing")
        current.volumeName = "Renamed"
        current.sizeBytes *= 2
        current.state = .mounted(URL(fileURLWithPath: "/Volumes/Synthetic", isDirectory: true))
        current.mountedFileSystemType = "xntfs"
        current.readOnly = true
        changed(view) {
            model.receiveDevices([current])
            view.rootView = root(current, model)
        }
        check(snapshot.selected.isSameDevice(as: original) && snapshot.selected.volumeName == "Selected",
              "presentation target did not stay fixed")
        check(snapshot.current?.mountedByXntfs == true && snapshot.current?.readOnly == true &&
              snapshot.current?.volumeName == "Renamed", "same observation lost current status")
        check(snapshot.command?.contains(" 132120576 ") == true, "command stopped using current validated observation")
        changed(view) { settings.deviceReadOnly = true }
        check(snapshot.command?.contains(" ro ") == true, "device read-only preference stopped updating")
        changed(view) {
            settings.deviceReadOnly = false
            current.mediaWritable = false
            model.receiveDevices([current])
        }
        check(snapshot.command?.contains(" ro ") == true, "read-only media became writable")
        changed(view) {
            current.kind = .diskImage
            current.mediaWritable = true
            model.receiveDevices([current])
        }
        check(snapshot.command?.contains(" ro ") == true, "image preference not taken from current observation")
        changed(view) { settings.imageReadOnly = false }
        check(snapshot.command?.contains(" auto ") == true, "image preference stopped updating")
        changed(view) { model.receiveDevices([]) }
        check(snapshot.current == nil && snapshot.command == nil, "removed selection remains actionable")
        var differentRegistry = original
        differentRegistry.registryEntryID = 67890
        changed(view) { model.receiveDevices([differentRegistry]) }
        check(snapshot.current == nil && snapshot.command == nil, "different registry accepted")
        var otherBSD = NTFSDevice(id: "disk43s1", volumeName: "Other", sizeBytes: original.sizeBytes,
                                  kind: .removable, contentHint: "Windows_NTFS", isRemovable: true,
                                  devicePath: "/dev/disk43s1")
        otherBSD.registryEntryID = original.registryEntryID
        otherBSD.discoveryID = original.discoveryID
        changed(view) { model.receiveDevices([otherBSD]) }
        check(snapshot.current == nil && snapshot.command == nil, "different BSD name accepted")
        // Descriptions for a continuous observation may recover without a new ID.
        changed(view) { model.receiveDevices([original]) }
        check(snapshot.current?.isSameDevice(as: original) == true && snapshot.command != nil,
              "continuous selected observation did not recover")
        view.rootView = AnyView(EmptyView())
        print("PASS: current status, command size/modes, missing/BSD/registry identity and continuous recovery")
    }

    static func retirement() {
        for _ in 0..<16 {
            weak var weakModel: AppModel?
            weak var weakHost: NSHostingView<AnyView>?
            autoreleasepool {
                let value = device(registry: 12345)
                let model = AppModel(monitor: nil, settings: AppSettings(defaults: nil))
                model.receiveDevices([value])
                let view = host(value, model)
                weakModel = model; weakHost = view
                view.rootView = AnyView(EmptyView())
                view.layoutSubtreeIfNeeded()
            }
            settle(nil) { weakModel == nil && weakHost == nil }
            check(weakModel == nil && weakHost == nil, "sheet retirement retained model or host")
        }
        print("PASS: 16 hosted sheet/model retirement cycles")
    }

    static func main() {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.prohibited)
        xntfs_observation_reset(0, 1)
        xntfs_test_begin_query_guard()
        let mode = CommandLine.arguments.dropFirst().first ?? "all"
        if mode == "stale" || mode == "all" { stale(registry: 12345); stale(registry: nil) }
        if mode == "parent" || mode == "all" { parentChange() }
        if mode == "all" { healthy(); retirement() }
        check(xntfs_observation_mount_calls() == 0 && xntfs_observation_registration_calls() == 0 &&
              xntfs_observation_sessions() == 0 && xntfs_test_query_count() == 0,
              "sheet made an unexpected external observation")
        check(NSApplication.shared.windows.allSatisfy { !$0.isVisible }, "test presented a visible window")
        print("PASS: \(checks) hosted checks; no visible window, command execution, registration, device query or preferences")
    }
}
