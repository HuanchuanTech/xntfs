import AppKit
import SwiftUI

@MainActor
enum MountSheetProbe {
    struct Snapshot {
        let selected: NTFSDevice
        let readOnly: Bool
        let busy: Bool
    }
    static var latest: Snapshot?
    static var mount: (() async -> Void)?
    static var toggle: ((Bool) -> Void)?
    static var command: String?
    static var error: String?
    static var renders = 0
    static var dismissals = 0
    static var closeIsDisabled: Bool?
    static var mountIsDisabled: Bool?
    static var forbidCommandDisplay = false
    static var forbiddenDisplays = 0
    static func observe(selected: NTFSDevice, readOnly: Bool, busy: Bool,
                        mount: @escaping () async -> Void, toggle: @escaping (Bool) -> Void) {
        latest = Snapshot(selected: selected, readOnly: readOnly, busy: busy)
        self.mount = mount; self.toggle = toggle
        command = nil; error = nil; closeIsDisabled = nil; mountIsDisabled = nil; renders += 1
    }
    static func display(_ value: String) -> String {
        if forbidCommandDisplay { forbiddenDisplays += 1 }
        command = value; return value
    }
    static func displayError(_ value: String) -> String { error = value; return value }
    static func didDismiss() { dismissals += 1 }
    static func closeDisabled(_ value: Bool) -> Bool { closeIsDisabled = value; return value }
    static func mountDisabled(_ value: Bool) -> Bool { mountIsDisabled = value; return value }
    static func reset() {
        latest = nil; mount = nil; toggle = nil; command = nil; error = nil; dismissals = 0
        closeIsDisabled = nil; mountIsDisabled = nil
        forbidCommandDisplay = false; forbiddenDisplays = 0
    }
}

@MainActor
private final class SheetMounter: DeviceMounting {
    var calls = 0
    var submitted: NTFSDevice?
    var requestedReadOnly: Bool?
    var pending: CheckedContinuation<MountOutcome, Never>?
    func unifiedMount(_ device: NTFSDevice, readOnly: Bool) async -> MountOutcome {
        precondition(pending == nil)
        calls += 1; submitted = device; requestedReadOnly = readOnly
        return await withCheckedContinuation { pending = $0 }
    }
    func unmount(_ device: NTFSDevice, force: Bool) async throws { throw POSIXError(.EINVAL) }
    func finish(_ outcome: MountOutcome) {
        let completion = pending; pending = nil
        completion?.resume(returning: outcome)
    }
}

@MainActor
private final class SheetAction {
    var done = false
    var task: Task<Void, Never>?
    init() {
        let action = MountSheetProbe.mount!
        task = Task { [weak self] in await action(); self?.done = true }
    }
}

@main
@MainActor
struct MountSheetTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard value() else { print("FAIL: \(message)"); exit(1) }
    }
    static func settle(_ view: NSHostingView<AnyView>?, until predicate: () -> Bool) {
        let end = Date().addingTimeInterval(5)
        repeat {
            view?.layoutSubtreeIfNeeded()
            if predicate() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        } while Date() < end
        check(false, "hosted action did not settle")
    }
    static func device(registry: UInt64? = 12345) -> NTFSDevice {
        var value = NTFSDevice(id: "disk42s1", volumeName: "Selected", sizeBytes: 66060288,
                               kind: .removable, contentHint: "Windows_NTFS", isRemovable: true,
                               devicePath: "/dev/disk42s1")
        value.registryEntryID = registry
        return value
    }
    static func root(_ selected: NTFSDevice, _ model: AppModel) -> AnyView {
        AnyView(MountSheet(device: selected).environment(model))
    }
    static func host(_ selected: NTFSDevice, _ model: AppModel) -> NSHostingView<AnyView> {
        MountSheetProbe.reset()
        let view = NSHostingView(rootView: root(selected, model))
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 400)
        settle(view) { MountSheetProbe.latest != nil }
        return view
    }
    static func change(_ view: NSHostingView<AnyView>, _ action: () -> Void) {
        let before = MountSheetProbe.renders
        action()
        settle(view) { MountSheetProbe.renders > before }
    }
    static func retire(_ view: NSHostingView<AnyView>) {
        view.rootView = AnyView(EmptyView())
        view.layoutSubtreeIfNeeded()
        MountSheetProbe.reset() // Test action closures must not retain the view graph.
    }
    private static func finish(_ call: SheetAction, view: NSHostingView<AnyView>, mounter: SheetMounter,
                       outcome: MountOutcome) {
        mounter.finish(outcome)
        settle(view) { call.done && MountSheetProbe.latest?.busy == false }
        call.task = nil
    }
    static var fallback: MountOutcome {
        .needsSystemMount(message: "Controlled sandbox denial",
                          command: SystemMountCommand.diskutil(bsdName: "disk42s1", readOnly: false)!)
    }

    static func parentBeforeSubmit(registry: UInt64?) {
        let original = device(registry: registry), mounter = SheetMounter()
        let model = AppModel(monitor: nil, mounter: mounter, settings: AppSettings(defaults: nil))
        model.receiveDevices([original])
        let view = host(original, model)
        var replacement = original; replacement.discoveryID = UUID()
        change(view) { model.receiveDevices([replacement]); view.rootView = root(replacement, model) }
        let call = SheetAction()
        settle(view) { call.done || mounter.pending != nil }
        if mounter.pending != nil { finish(call, view: view, mounter: mounter, outcome: .failed("Controlled completion")) }
        print("Pre-submit parent: original selected=\(MountSheetProbe.latest!.selected.isSameDevice(as: original)), submissions=\(mounter.calls)")
        check(mounter.calls == 0, "open sheet submitted a replacement observation")
        check(MountSheetProbe.latest!.selected.isSameDevice(as: original), "parent retargeted selection")
        check(MountSheetProbe.command == nil && MountSheetProbe.error != nil, "stale selection lacks unavailable evidence")
        check(MountSheetProbe.closeIsDisabled == false && MountSheetProbe.mountIsDisabled == true,
              "unavailable selection must remain closable and cannot be mounted")
        check(model.devices[0].isSameDevice(as: replacement) && model.devices[0].state == .unmounted,
              "stale attempt changed replacement state")
        retire(view)
        let reopened = host(replacement, model)
        let fresh = SheetAction(); settle(reopened) { mounter.pending != nil }
        check(mounter.submitted?.isSameDevice(as: replacement) == true, "new panel did not submit new selection")
        finish(fresh, view: reopened, mounter: mounter, outcome: .failed("Controlled retry"))
        retire(reopened)
    }

    static func staleCompletion(_ outcome: MountOutcome, label: String) {
        let original = device(), mounter = SheetMounter()
        let model = AppModel(monitor: nil, mounter: mounter, settings: AppSettings(defaults: nil))
        model.receiveDevices([original]); let view = host(original, model)
        let call = SheetAction(); settle(view) { mounter.pending != nil }
        check(MountSheetProbe.latest?.busy == true, "action did not retain busy state")
        check(MountSheetProbe.closeIsDisabled == true && MountSheetProbe.mountIsDisabled == true,
              "pending action did not keep both controls disabled")
        let duplicate = SheetAction(); settle(view) { duplicate.done }
        check(mounter.calls == 1, "busy action submitted a duplicate")
        var replacement = original; replacement.discoveryID = UUID()
        change(view) { model.receiveDevices([replacement]); view.rootView = root(replacement, model) }
        call.task?.cancel()
        check(mounter.pending != nil && MountSheetProbe.latest?.busy == true, "cancellation abandoned native completion")
        finish(call, view: view, mounter: mounter, outcome: outcome)
        print("Stale \(label): command=\(MountSheetProbe.command != nil), dismissals=\(MountSheetProbe.dismissals), error=\(MountSheetProbe.error ?? "nil")")
        check(MountSheetProbe.dismissals == 0, "stale success dismissed replacement presentation")
        check(MountSheetProbe.command == nil, "stale callback exposed a fallback command")
        check(MountSheetProbe.error != nil && MountSheetProbe.error != "Controlled failure" &&
              MountSheetProbe.error != "Controlled sandbox denial", "stale result attributed to current selection")
        check(model.devices[0].state == .unmounted && model.devices[0].isSameDevice(as: replacement),
              "stale completion mutated replacement list row")
        retire(view)
    }

    static func displayedCommand() {
        let original = device(), mounter = SheetMounter()
        let settings = AppSettings(defaults: nil)
        let model = AppModel(monitor: nil, mounter: mounter, settings: settings)
        model.receiveDevices([original]); let view = host(original, model)
        let call = SheetAction(); settle(view) { mounter.pending != nil }
        finish(call, view: view, mounter: mounter, outcome: fallback)
        check(MountSheetProbe.command?.contains("-mountOptions rw") == true, "normal fallback command missing")
        change(view) { MountSheetProbe.toggle?(true) }
        settle(view) { MountSheetProbe.command?.contains("mount readOnly") == true }
        check(MountSheetProbe.command?.contains("mount readOnly") == true, "toggle did not update fallback mode")
        change(view) { MountSheetProbe.toggle?(false) }
        settle(view) { MountSheetProbe.command?.contains("-mountOptions rw") == true }
        var current = model.devices[0]; current.mediaWritable = false
        change(view) { model.receiveDevices([current]) }
        settle(view) { MountSheetProbe.command?.contains("mount readOnly") == true }
        check(MountSheetProbe.latest?.readOnly == true, "current media capability did not constrain toggle")
        var replacement = original; replacement.discoveryID = UUID()
        change(view) {
            MountSheetProbe.forbidCommandDisplay = true
            model.receiveDevices([replacement]); view.rootView = root(replacement, model)
        }
        print("Displayed command after replacement: \(MountSheetProbe.command ?? "nil")")
        check(MountSheetProbe.forbiddenDisplays == 0, "stale command was exposed during view update")
        check(MountSheetProbe.command == nil, "previously displayed command survives identity replacement")
        change(view) { MountSheetProbe.toggle?(false) }
        check(MountSheetProbe.command == nil, "toggle revived stale command")
        retire(view)
    }

    static func healthy() {
        var value = device(); let original = value
        let mounter = SheetMounter(), settings = AppSettings(defaults: nil)
        let model = AppModel(monitor: nil, mounter: mounter, settings: settings)
        model.receiveDevices([value]); let view = host(value, model)
        value.mediaWritable = false; value.volumeName = "Current name"
        change(view) { model.receiveDevices([value]); view.rootView = root(value, model) }
        let first = SheetAction(); settle(view) { mounter.pending != nil }
        check(mounter.submitted?.isSameDevice(as: original) == true && mounter.submitted?.mediaWritable == false,
              "same-identity action stopped using current metadata")
        check(mounter.requestedReadOnly == true, "read-only media not honored at submission")
        finish(first, view: view, mounter: mounter, outcome: .failed("Controlled failure"))
        check(MountSheetProbe.error == "Controlled failure", "current error changed")
        value.state = .unmounted; value.mediaWritable = true
        change(view) { model.receiveDevices([value]) }
        let retry = SheetAction(); settle(view) { mounter.pending != nil }
        check(mounter.calls == 2, "current failure could not retry")
        finish(retry, view: view, mounter: mounter,
               outcome: .mounted(URL(fileURLWithPath: "/Volumes/Synthetic0", isDirectory: true)))
        check(MountSheetProbe.dismissals == 1 && model.devices[0].state.isMounted, "current success did not dismiss/update")
        retire(view)
        print("PASS: continuous metadata, forced read-only, current error/retry and success")
    }

    static func defaults() {
        for kind in [DeviceKind.removable, .diskImage] {
            for preferred in [false, true] {
                var value = device(); value.kind = kind
                let mounter = SheetMounter(), settings = AppSettings(defaults: nil)
                settings.deviceReadOnly = preferred; settings.imageReadOnly = !preferred
                let model = AppModel(monitor: nil, mounter: mounter, settings: settings)
                model.receiveDevices([value]); let view = host(value, model)
                let expected = kind == .diskImage ? !preferred : preferred
                settle(view) { MountSheetProbe.latest?.readOnly == expected }
                check(MountSheetProbe.latest?.readOnly == expected, "on-appear preference changed")
                let call = SheetAction(); settle(view) { mounter.pending != nil }
                check(mounter.requestedReadOnly == expected, "selected access preference not submitted")
                finish(call, view: view, mounter: mounter, outcome: .failed("Controlled mode"))
                retire(view)
            }
        }
        print("PASS: actual on-appear device/image preferences and submitted modes")
    }

    static func retirement() {
        for index in 0..<16 {
            weak var weakModel: AppModel?
            weak var weakView: NSHostingView<AnyView>?
            weak var weakMounter: SheetMounter?
            autoreleasepool {
                let value = device(), mounter = SheetMounter()
                let model = AppModel(monitor: nil, mounter: mounter, settings: AppSettings(defaults: nil))
                model.receiveDevices([value]); let view = host(value, model)
                weakModel = model; weakView = view; weakMounter = mounter
                let call = SheetAction(); settle(view) { mounter.pending != nil }
                if index % 2 == 0 {
                    finish(call, view: view, mounter: mounter, outcome: .failed("Controlled retirement"))
                    retire(view)
                } else {
                    // Parent removal can retire a presentation while a native reply
                    // still owns its action. Completion must still be consumed once.
                    model.receiveDevices([])
                    retire(view)
                    call.task?.cancel()
                    check(mounter.pending != nil, "retirement dropped the pending completion")
                    mounter.finish(.failed("Controlled late retirement"))
                    settle(nil) { call.done }
                    call.task = nil
                }
            }
            settle(nil) { weakModel == nil && weakView == nil && weakMounter == nil }
            check(weakModel == nil && weakView == nil && weakMounter == nil, "retired sheet/action retained owners")
        }
        print("PASS: 16 ordinary/in-flight retirement cycles release host, model and mounter")
    }

    static func main() {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.prohibited)
        xntfs_observation_reset(1, 32)
        xntfs_observation_set_entry(0, "/dev/disk42s1", "/Volumes/Synthetic0", "xntfs")
        xntfs_test_begin_query_guard()
        let mode = CommandLine.arguments.dropFirst().first ?? "all"
        if mode == "parent" || mode == "all" { parentBeforeSubmit(registry: 12345); parentBeforeSubmit(registry: nil) }
        if mode == "inflight" || mode == "all" {
            staleCompletion(fallback, label: "fallback")
            staleCompletion(.failed("Controlled failure"), label: "failure")
            staleCompletion(.mounted(URL(fileURLWithPath: "/Volumes/Synthetic0", isDirectory: true)), label: "success")
        }
        if mode == "command" || mode == "all" { displayedCommand() }
        if mode == "all" { healthy(); defaults(); retirement() }
        check(xntfs_observation_registration_calls() == 0 && xntfs_observation_sessions() == 0 &&
              xntfs_observation_disk_requests() == 0 && xntfs_test_query_count() == 0,
              "unexpected DA registration/device/volume-path query")
        check(NSApplication.shared.windows.allSatisfy { !$0.isVisible }, "visible window")
        print("PASS: \(checks) modern hosted checks; controlled actions only, no window, shell or device operations")
    }
}
