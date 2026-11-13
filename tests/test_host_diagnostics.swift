import Foundation
import Darwin

// Used only by the runner's copied ExtensionStatus implementation.
@MainActor
enum CaptureFixture {
    static var queryError: NSError?
    static var held = false
    static var started = 0
    static var live = 0
    static var peak = 0
    private static var waiters: [CheckedContinuation<Void, Never>] = []

    static func reset(held: Bool = false) {
        precondition(live == 0 && waiters.isEmpty)
        self.held = held
        started = 0; peak = 0
    }
    static func refresh() async {
        started += 1; live += 1; peak = max(peak, live)
        defer { live -= 1 }
        if held {
            await withCheckedContinuation { continuation in
                precondition(waiters.count < 64) // Finite fixture, including the unbounded baseline.
                waiters.append(continuation)
            }
        }
    }
    static func releaseOne() {
        precondition(!waiters.isEmpty)
        waiters.removeFirst().resume()
    }
    static func releaseAll() {
        held = false
        while !waiters.isEmpty { releaseOne() }
    }
}

// Only the runner's frozen recorder copy calls this gate. Locks protect these
// counters from its real background queue; no production test hooks are added.
nonisolated enum CaptureHistoryGate {
    private static let condition = NSCondition()
    nonisolated(unsafe) private static var held = false
    nonisolated(unsafe) private static var entered = false
    nonisolated(unsafe) private static var started = 0
    static func reset(held: Bool = false) {
        condition.lock(); defer { condition.unlock() }
        precondition(!entered)
        self.held = held; started = 0
    }
    static func wait() {
        condition.lock(); defer { condition.unlock() }
        entered = true
        while held { condition.wait() }
        entered = false
    }
    static func release() {
        condition.lock(); defer { condition.unlock() }
        held = false; condition.broadcast()
    }
    static func snapshotStarted() {
        condition.lock(); defer { condition.unlock() }
        started += 1
    }
    static var state: (entered: Bool, started: Int) {
        condition.lock(); defer { condition.unlock() }
        return (entered, started)
    }
}

@MainActor
private final class CaptureResults {
    var values: [Int: Result<DiagnosticSnapshot, Error>] = [:]
    var busyCount: Int {
        values.values.filter {
            guard case .failure(let error) = $0 else { return false }
            let e = error as NSError
            return e.domain == NSPOSIXErrorDomain && e.code == Int(EBUSY)
        }.count
    }
    var cancelledCount: Int {
        values.values.filter { if case .failure(is CancellationError) = $0 { return true }; return false }.count
    }
}

@MainActor
private final class QueryResults {
    var values: [Int: Result<DiskArbitrationMonitor.DiagnosticObservation, Error>] = [:]
    var busyCount: Int {
        values.values.filter {
            if case .failure(let error) = $0 {
                let e = error as NSError
                return e.domain == NSPOSIXErrorDomain && e.code == Int(EBUSY)
            }
            return false
        }.count
    }
    var successes: [[NTFSDevice]] {
        values.values.compactMap { try? $0.get().devices }
    }
}

#if HOST_DIAGNOSTIC_PROBE
nonisolated final class DiagnosticOwnershipProbe: Sendable {
    private static let lock = NSLock()
    private let owner: ObjectIdentifier
    nonisolated(unsafe) private static var live = 0
    nonisolated(unsafe) private static var peak = 0
    nonisolated(unsafe) private static var created = 0
    nonisolated(unsafe) private static var owners: [ObjectIdentifier: Int] = [:]
    nonisolated(unsafe) private static var peakPerMonitor = 0
    nonisolated(unsafe) private static var peakMonitors = 0
    init(owner: ObjectIdentifier) {
        self.owner = owner // Value identity only; does not retain the monitor.
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.live += 1; Self.created += 1; Self.peak = max(Self.peak, Self.live)
        Self.owners[owner, default: 0] += 1
        Self.peakPerMonitor = max(Self.peakPerMonitor, Self.owners[owner]!)
        Self.peakMonitors = max(Self.peakMonitors, Self.owners.count)
    }
    deinit {
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.live -= 1; precondition(Self.live >= 0)
        let count = Self.owners[owner]! - 1
        precondition(count >= 0)
        if count == 0 { Self.owners.removeValue(forKey: owner) }
        else { Self.owners[owner] = count }
    }
    static func snapshot() -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return ["live": live, "peak": peak, "created": created, "live_monitors": owners.count,
                "peak_per_monitor": peakPerMonitor, "peak_monitors": peakMonitors]
    }
    static func checkRetired() {
        let value = snapshot()
        precondition(value["live"] == 0 && value["live_monitors"] == 0, "Diagnostic closure retained after retirement")
    }
}
#endif

#if HOST_DIAGNOSTIC_PROBE
nonisolated final class PublicationOwnershipProbe: Sendable {
    private static let lock = NSLock()
    private let owner: ObjectIdentifier
    nonisolated(unsafe) private static var live = 0, peak = 0, created = 0, copies = 0, rows = 0, peakPerMonitor = 0
    nonisolated(unsafe) private static var owners: [ObjectIdentifier: Int] = [:]
    init(owner: ObjectIdentifier) {
        self.owner = owner // Identity only; never retain the monitor or device array.
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.live += 1; Self.created += 1; Self.peak = max(Self.peak, Self.live)
        Self.owners[owner, default: 0] += 1
        Self.peakPerMonitor = max(Self.peakPerMonitor, Self.owners[owner]!)
    }
    deinit {
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.live -= 1; precondition(Self.live >= 0)
        let count = Self.owners[owner]! - 1
        if count == 0 { Self.owners.removeValue(forKey: owner) }
        else { Self.owners[owner] = count }
    }
    static func copied(rows: Int) {
        lock.lock(); defer { lock.unlock() }
        copies += 1; self.rows += rows
    }
    static func snapshot() -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return ["live": live, "peak": peak, "created": created, "copies": copies, "rows": rows,
                "live_monitors": owners.count, "peak_per_monitor": peakPerMonitor]
    }
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        precondition(live == 0 && owners.isEmpty)
        peak = 0; created = 0; copies = 0; rows = 0; peakPerMonitor = 0
    }
}
#endif

@MainActor
private final class PublicationMounter: DeviceMounting {
    var calls = 0
    private var pending: [CheckedContinuation<Void, Error>] = []
    func unifiedMount(_ device: NTFSDevice, readOnly: Bool) async -> MountOutcome { .failed("unused") }
    func unmount(_ device: NTFSDevice, force: Bool) async throws {
        calls += 1
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func finish(_ error: Error? = nil) {
        let completion = pending.removeFirst()
        if let error { completion.resume(throwing: error) }
        else { completion.resume() }
    }
}

@MainActor
private final class PassiveSourceMounter: DeviceMounting {
    var pending: CheckedContinuation<MountOutcome, Never>?
    func unifiedMount(_ device: NTFSDevice, readOnly: Bool) async -> MountOutcome {
        precondition(pending == nil)
        return await withCheckedContinuation { pending = $0 }
    }
    func unmount(_ device: NTFSDevice, force: Bool) async throws { throw POSIXError(.EINVAL) }
    func finish(_ outcome: MountOutcome) {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: outcome)
    }
}

@main
@MainActor
struct HostDiagnosticTests {
    static func passiveCheck(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { print("FAIL: \(message)"); exit(1) }
    }

    static func checkPassiveMonitorSource() async throws {
        let monitor = await monitor(1)
        let original = monitor.currentDevices[0]
        let model = AppModel(monitor: monitor, settings: AppSettings(defaults: nil))
        model.receiveDevices(monitor.currentDevices)
        monitor.onDevicesChanged = { [weak model] in model?.receiveDevices($0) }
        xntfs_observation_set_kind(0, "ntfs")
        // Same displayed path, but the cached mount belongs to other media.
        xntfs_observation_set_entry(0, "/dev/diskForeign", "/Volumes/Synthetic0", "ntfs")
        xntfs_observation_reset_counts()
        xntfs_observation_emit(monitor.sessionRef(), 0, 1)
        await flushMain()
        let unknown = model.devices[0]
        print("Passive source mismatch: driver=\(unknown.diagnosticDriver), access=\(unknown.diagnosticFields[.effectiveReadOnly] ?? "missing")")
        passiveCheck(unknown.mountDriver == .unknown && !unknown.needsXntfsMountGuidance,
                     "callback borrowed driver/access guidance from a different mount source")
        passiveCheck(unknown.state.isMounted && unknown.isSameDevice(as: original),
                     "credible hint keeps the unknown observation and its identity")
        passiveCheck(unknown.diagnosticFields[.effectiveReadOnly] == "unknown", "unknown callback history claims a known mode")
        passiveCheck(xntfs_observation_mount_calls() == 1 && xntfs_observation_enumeration_calls() == 0,
                     "callback source validation added queries or enumeration")
        let observation = try await monitor.devicesForDiagnostics()
        passiveCheck(!observation.isComplete && observation.devices.isEmpty, "unknown mounted row exported as confirmed diagnostics")
        CaptureFixture.queryError = nil
        let snapshot = try await DiagnosticSnapshot.capture(model: model)
        passiveCheck(snapshot.devices.isEmpty && snapshot.queryErrors.map(\.domain) == ["com.huanchuan.xntfs.deviceObservation.incomplete"],
                     "source mismatch lost bounded partial-report evidence")
        let report = ProblemReport(description: "test", steps: "", contactEmail: "", diagnostics: snapshot)
        let encoded = try report.encoded()
        let json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        passiveCheck(json["schemaVersion"] as? Int == 1 && !String(decoding: encoded, as: UTF8.self).contains("diskForeign"),
                     "source validation changed report schema or leaked mount source")

        // The known-device refresh path must apply the same source rule, even
        // when the foreign filesystem would otherwise exclude the NTFS row.
        xntfs_observation_set_entry(0, "/dev/diskForeign", "/Volumes/Synthetic0", "apfs")
        xntfs_observation_reset_counts()
        monitor.refresh(); xntfs_observation_drain(monitor.sessionRef()); await flushMain()
        passiveCheck(model.devices.count == 1 && model.devices[0].mountDriver == .unknown &&
                     model.devices[0].isSameDevice(as: original), "refresh classified the device using foreign metadata")
        passiveCheck(xntfs_observation_mount_calls() == 1, "known refresh acquired another source-validation snapshot")

        // A misleading hint cannot establish NTFS when the authoritative source
        // no longer matches. Restoration still recovers without a new DA event.
        xntfs_observation_set_kind(0, "msdos")
        xntfs_observation_set_entry(0, "/dev/diskForeign", "/Volumes/Synthetic0", "xntfs")
        xntfs_observation_emit(monitor.sessionRef(), 0, 1); await flushMain()
        passiveCheck(model.devices.isEmpty, "misleading hint plus foreign xntfs created a device")
        xntfs_observation_set_entry(0, "/dev/diskTest0", "/Volumes/Synthetic0", "xntfs")
        monitor.refresh(); xntfs_observation_drain(monitor.sessionRef()); await flushMain()
        passiveCheck(model.devices.count == 1 && model.devices[0].mountedByXntfs && !model.devices[0].isSameDevice(as: original),
                     "source restoration failed to recover a fresh observation")
        let recovered = model.devices[0]
        xntfs_observation_set_kind(0, "ntfs")
        for cycle in 0..<32 {
            xntfs_observation_set_entry(0, "/dev/diskForeign", "/Volumes/Synthetic0", "xntfs")
            xntfs_observation_emit(monitor.sessionRef(), 0, 1); await flushMain()
            passiveCheck(model.devices[0].mountDriver == .unknown && model.devices[0].isSameDevice(as: recovered), "repeated unknown state/identity")
            xntfs_observation_set_entry(0, "/dev/diskTest0", "/Volumes/Synthetic0", "xntfs")
            xntfs_observation_set_mount(0, "xntfs", cycle % 2 == 0)
            monitor.refresh(); xntfs_observation_drain(monitor.sessionRef()); await flushMain()
            passiveCheck(model.devices[0].mountedByXntfs && model.devices[0].readOnly == (cycle % 2 == 0) &&
                         model.devices[0].isSameDevice(as: recovered), "repeated recovery used cached flags or changed identity")
            passiveCheck(xntfs_observation_media_live() == 0 && xntfs_observation_iterators_live() == 0, "source recovery retained native handles")
        }
        xntfs_observation_set_mount(0, "exfat", false)
        xntfs_observation_emit(monitor.sessionRef(), 0, 1); await flushMain()
        passiveCheck(model.devices.isEmpty, "same-source non-NTFS classification regressed")
        print("PASS: callback/known refresh source match, honest unknown history, partial report, identity and 32 recovery cycles")
    }

    static func checkPassiveModelSource() async {
        xntfs_observation_reset(1, 32)
        let mounter = PassiveSourceMounter()
        let model = AppModel(monitor: nil, mounter: mounter, settings: AppSettings(defaults: nil))
        let device = NTFSDevice(id: "diskTest0", volumeName: "fixture", sizeBytes: 4096,
                                kind: .removable, contentHint: "Windows_NTFS", isRemovable: true, devicePath: "/dev/diskTest0")
        let url = URL(fileURLWithPath: "/Volumes/Synthetic0", isDirectory: true)
        for scenario in ["foreign", "missing", "failed", "empty-type", "ro", "rw"] {
            model.receiveDevices([device])
            xntfs_observation_fail_table(false)
            xntfs_observation_set_entry(0, "/dev/diskTest0", "/Volumes/Synthetic0", "xntfs")
            xntfs_observation_set_mount(0, "xntfs", scenario == "ro")
            let call = Task { await model.mount(device, readOnly: scenario == "ro") }
            await requireEventually { mounter.pending != nil }
            switch scenario {
            case "foreign":
                xntfs_observation_set_entry(0, "/dev/diskForeign", "/Volumes/Synthetic0", "ntfs")
                xntfs_observation_set_mount(0, "ntfs", true)
            case "missing": xntfs_observation_set_entry(0, "/dev/diskTest0", "/Volumes/Other", "xntfs")
            case "failed": xntfs_observation_fail_table(true)
            case "empty-type": xntfs_observation_set_entry(0, "/dev/diskTest0", "/Volumes/Synthetic0", "")
            default: break
            }
            xntfs_observation_reset_counts()
            mounter.finish(.mounted(url))
            let result = await call.value
            if case .mounted = result {} else { passiveCheck(false, "UI observation rewrote action outcome") }
            let current = model.devices[0]
            print("Post-mount UI \(scenario): driver=\(current.diagnosticDriver), access=\(current.diagnosticFields[.effectiveReadOnly] ?? "missing")")
            passiveCheck(current.state.isMounted && current.isSameDevice(as: device), "UI update changed observation identity")
            if scenario == "ro" || scenario == "rw" {
                passiveCheck(current.mountedByXntfs && current.readOnly == (scenario == "ro"), "known post-mount flags changed")
                passiveCheck(current.diagnosticFields[.effectiveReadOnly] == String(scenario == "ro"), "known mode lost from history")
            } else {
                passiveCheck(current.mountDriver == .unknown && !current.needsXntfsMountGuidance, "post-mount UI borrowed foreign driver/guidance")
                passiveCheck(current.diagnosticFields[.effectiveReadOnly] == "unknown", "post-mount missing metadata claims known access")
            }
            passiveCheck(xntfs_observation_mount_calls() == 2, "UI source matching added a query beyond UI and image observations")
        }
        print("PASS: actual AppModel post-mount source checks preserve outcome, known modes and unknown evidence")
    }

    static func checkUnknownHistory() async {
        var device = NTFSDevice(id: "disk99s1", volumeName: "private-label", sizeBytes: 4096,
                                kind: .removable, contentHint: "Windows_NTFS", isRemovable: true, devicePath: "/dev/disk99s1")
        let states: [MountState] = [.unmounted, .mounting, .mounted(URL(fileURLWithPath: "/Volumes/Private", isDirectory: true)), .unmounting, .failed("private failure")]
        for state in states {
            for type: String? in [nil, "", "ntfs", "xntfs", "ufsd"] {
                for readOnly in [false, true] {
                    device.state = state; device.mountedFileSystemType = type; device.readOnly = readOnly
                    let expected = state.isMounted && type != nil && type != "" ? String(readOnly) : "unknown"
                    let actual = device.diagnosticFields[.effectiveReadOnly]
                    if actual != expected { print("History \(device.diagnosticState)/\(device.diagnosticDriver): \(actual ?? "missing") expected \(expected)") }
                    passiveCheck(actual == expected, "history serialized an unknown mode as a Boolean")
                }
            }
        }
        device.state = .mounted(URL(fileURLWithPath: "/Volumes/Private", isDirectory: true))
        device.mountedFileSystemType = nil
        let event = DiagnosticEvent(action: .deviceObserved, phase: .observed, fields: device.diagnosticFields,
                                    process: UUID(), component: "app")
        let data = try! JSONEncoder().encode(event)
        let decoded = try! JSONDecoder().decode(DiagnosticEvent.self, from: data)
        passiveCheck(decoded.fields["effectiveReadOnly"] == "unknown" && !String(decoding: data, as: UTF8.self).contains("Private"),
                     "unknown history encoding/privacy changed")
        print("PASS: unknown/known history across 50 state/type/mode combinations, existing field/schema and privacy")
    }
    static func waitUntil(_ predicate: () -> Bool) async -> Bool {
        let end = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while !predicate() {
            if DispatchTime.now().uptimeNanoseconds >= end { return false }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return true
    }

    static func flushMain() async {
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
    }

    static func checkPublicationBurst() async {
        let monitor = await monitor(8)
        let original = monitor.currentDevices
        var calls = 0, latest: [NTFSDevice] = []
        monitor.onDevicesChanged = { list in
            dispatchPrecondition(condition: .onQueue(.main))
            calls += 1; latest = list
        }
        #if HOST_DIAGNOSTIC_PROBE
        PublicationOwnershipProbe.reset()
        #endif
        // This synchronous main-actor burst prevents queued deliveries from running.
        for index in 0..<1024 {
            xntfs_observation_set_mount(0, "xntfs", index % 2 == 0)
            xntfs_observation_emit(monitor.sessionRef(), 0, 1)
        }
        precondition(calls == 0)
        #if HOST_DIAGNOSTIC_PROBE
        let held = PublicationOwnershipProbe.snapshot()
        print("Held publication ownership: \(held)")
        precondition(held["created"] == 1 && held["live"] == 1 && held["copies"] == 0,
                     "Busy main queue retained a publication or list per event")
        #endif
        await flushMain()
        precondition(calls == 1 && latest.count == 8 && !latest[0].readOnly,
                     "Publication did not deliver the latest state once")
        precondition(zip(original, latest).allSatisfy { $0.isSameDevice(as: $1) })
        #if HOST_DIAGNOSTIC_PROBE
        let retired = PublicationOwnershipProbe.snapshot()
        precondition(retired["live"] == 0 && retired["copies"] == 1 && retired["rows"] == 8)
        #endif
        print("PASS: 1024 pending updates retain one weak job, no queued list, and deliver one fresh sorted snapshot")
    }

    static func checkPublicationFollowup() async {
        let monitor = await monitor(2)
        var calls = 0
        #if HOST_DIAGNOSTIC_PROBE
        PublicationOwnershipProbe.reset()
        #endif
        monitor.onDevicesChanged = { list in
            calls += 1
            if calls == 1 {
                precondition(list[0].mountedFileSystemType == "xntfs" && list[0].readOnly)
                for _ in 0..<64 {
                    xntfs_observation_set_mount(0, "ntfs", false)
                    xntfs_observation_emit(monitor.sessionRef(), 0, 1)
                }
                // The consumer can reenter without the publication lock being held.
                precondition(monitor.currentDevices[0].mountedFileSystemType == "ntfs")
                precondition(list[0].mountedFileSystemType == "xntfs", "Delivered value snapshot mutated")
                #if HOST_DIAGNOSTIC_PROBE
                let active = PublicationOwnershipProbe.snapshot()
                precondition(active["live"] == 2 && active["created"] == 2 && active["copies"] == 1)
                #endif
            } else {
                precondition(calls == 2 && list[0].mountedFileSystemType == "ntfs" && !list[0].readOnly)
            }
        }
        xntfs_observation_emit(monitor.sessionRef(), 0, 1)
        await requireEventually { calls == 2 }
        await flushMain()
        #if HOST_DIAGNOSTIC_PROBE
        let retired = PublicationOwnershipProbe.snapshot()
        precondition(retired["live"] == 0 && retired["copies"] == 2 && retired["peak_per_monitor"] == 2)
        #endif
        monitor.onDevicesChanged = nil // Break the test consumer's explicit monitor capture.
        print("PASS: active delivery permits one fresh follow-up; reentrant consumer runs outside lock and keeps its value snapshot")
    }

    static func checkPublicationIndependence() async {
        let first = await monitor(1), second = await monitor(1)
        var a = 0, b = 0
        first.onDevicesChanged = { _ in a += 1 }
        second.onDevicesChanged = { _ in b += 1 }
        #if HOST_DIAGNOSTIC_PROBE
        PublicationOwnershipProbe.reset()
        #endif
        for _ in 0..<128 {
            xntfs_observation_emit(first.sessionRef(), 0, 1)
            xntfs_observation_emit(second.sessionRef(), 0, 1)
        }
        #if HOST_DIAGNOSTIC_PROBE
        let held = PublicationOwnershipProbe.snapshot()
        precondition(held["live"] == 2 && held["live_monitors"] == 2 && held["peak_per_monitor"] == 1 && held["copies"] == 0)
        #endif
        await flushMain()
        precondition(a == 1 && b == 1)
        first.onDevicesChanged = nil
        xntfs_observation_emit(first.sessionRef(), 0, 1); await flushMain()
        first.onDevicesChanged = { _ in a += 1 }
        xntfs_observation_emit(first.sessionRef(), 0, 1); await flushMain()
        precondition(a == 2 && b == 1, "Nil consumer left publication admission stuck")
        print("PASS: publication bounds are per monitor; nil consumer retires admission and later delivery recovers")
    }

    static func checkPublicationTeardown() async {
        var monitor: DiskArbitrationMonitor? = await monitor(1)
        weak let weakMonitor = monitor
        let session = monitor!.sessionRef()
        var calls = 0
        monitor!.onDevicesChanged = { _ in calls += 1 }
        #if HOST_DIAGNOSTIC_PROBE
        PublicationOwnershipProbe.reset()
        #endif
        for _ in 0..<64 { xntfs_observation_emit(session, 0, 1) }
        monitor = nil
        precondition(weakMonitor == nil, "Queued publication retained its monitor")
        xntfs_observation_drain(session)
        await flushMain()
        precondition(calls == 0)
        #if HOST_DIAGNOSTIC_PROBE
        let value = PublicationOwnershipProbe.snapshot()
        precondition(value["created"] == 1 && value["live"] == 0 && value["copies"] == 0)
        #endif
        print("PASS: queued publication neither keeps the monitor alive nor materializes a list after teardown")
    }

    static func checkRepeatedPublications() async {
        let monitor = await monitor(8)
        var calls = 0, latest: [NTFSDevice] = []
        monitor.onDevicesChanged = { calls += 1; latest = $0 }
        #if HOST_DIAGNOSTIC_PROBE
        PublicationOwnershipProbe.reset()
        #endif
        for cycle in 0..<32 {
            xntfs_observation_set_mount(0, "xntfs", cycle % 2 == 0)
            for _ in 0..<64 { xntfs_observation_emit(monitor.sessionRef(), 0, 1) }
            await flushMain()
            precondition(calls == cycle + 1 && latest.count == 8 && latest[0].readOnly == (cycle % 2 == 0))
            #if HOST_DIAGNOSTIC_PROBE
            let value = PublicationOwnershipProbe.snapshot()
            precondition(value["live"] == 0 && value["created"] == cycle + 1 && value["copies"] == cycle + 1)
            #endif
        }
        print("PASS: 32 publication bursts retain only current delivery work and release every completed closure")
    }

    static func checkPublishedActionIdentity(registry: UInt64, oldError: Error?) async {
        let monitor = await monitor(1)
        xntfs_observation_set_registry(0, registry)
        xntfs_observation_emit(monitor.sessionRef(), 0, 1); await flushMain()
        let mounter = PublicationMounter()
        let model = AppModel(monitor: monitor, mounter: mounter, settings: AppSettings(defaults: nil))
        var receivedEmpty = false
        monitor.onDevicesChanged = { [weak model] list in
            receivedEmpty = receivedEmpty || list.isEmpty
            model?.receiveDevices(list)
        }
        model.receiveDevices(monitor.currentDevices)
        let old = model.devices[0]
        let first = Task { await model.unmount(old) }
        await requireEventually { mounter.calls == 1 }
        for _ in 0..<64 { xntfs_observation_emit(monitor.sessionRef(), 0, 1) }
        await flushMain()
        precondition(model.devices[0].state == .unmounting, "Coalescing lost a current operation transition")
        await model.unmount(old); precondition(mounter.calls == 1)

        // No main delivery between disappearance and same-name/same-registry return.
        xntfs_observation_emit(monitor.sessionRef(), 0, 2)
        xntfs_observation_emit(monitor.sessionRef(), 0, 0)
        precondition(model.devices[0].isSameDevice(as: old))
        await flushMain()
        let replacement = model.devices[0]
        precondition(!receivedEmpty && !replacement.isSameDevice(as: old) && replacement.registryEntryID == old.registryEntryID)
        precondition(replacement.state.isMounted)
        await model.unmount(old); precondition(mounter.calls == 1, "Old selection acted on a coalesced replacement")
        let second = Task { await model.unmount(replacement) }
        await requireEventually { mounter.calls == 2 }
        mounter.finish(oldError); await first.value
        precondition(model.devices[0].isSameDevice(as: replacement) && model.devices[0].state == .unmounting && model.lastError == nil)
        mounter.finish(); await second.value
        precondition(model.devices[0].state == .unmounted)

        xntfs_observation_emit(monitor.sessionRef(), 0, 1); await flushMain()
        let current = Task { await model.unmount(replacement) }
        await requireEventually { mounter.calls == 3 }
        mounter.finish(POSIXError(.EIO)); await current.value
        precondition(model.lastError != nil)
        let history = await DiagnosticRecorder.shared.snapshot()
        precondition(history.events.last { $0.action == .unmount }?.phase == .failed)
        precondition(history.events.last { $0.action == .unmount }?.errors.last?.code == Int(EIO))
        print("PASS: actual coalesced producer/AppModel preserves busy state, replacement identity, late completion and current error evidence (registry=\(registry))")
    }

    static func requireEventually(_ predicate: () -> Bool) async {
        let completed = await waitUntil(predicate)
        precondition(completed, "Timed out waiting for the controlled capture stage")
    }

    private static func captures(_ models: [AppModel], count: Int, offset: Int = 0,
                                 into results: CaptureResults) -> [Task<Void, Never>] {
        (0..<count).map { index in
            Task {
                do { results.values[offset + index] = .success(try await DiagnosticSnapshot.capture(model: models[index % models.count])) }
                catch { results.values[offset + index] = .failure(error) }
            }
        }
    }

    static func checkWholeCaptureEntry() async throws {
        let monitor = await monitor(2)
        let models = [AppModel(monitor: monitor, settings: AppSettings(defaults: nil)),
                      AppModel(monitor: nil, settings: AppSettings(defaults: nil))]
        CaptureFixture.reset(held: true); CaptureHistoryGate.reset()
        xntfs_observation_reset_counts()
        let results = CaptureResults()
        let tasks = captures(models, count: 64, into: results)
        await requireEventually { results.busyCount == 60 || CaptureFixture.started == 64 }
        print("Whole capture held prefix: started=\(CaptureFixture.started), busy=\(results.busyCount), peak=\(CaptureFixture.peak)")
        precondition(CaptureFixture.started == 4 && results.busyCount == 60,
                     "Report admission did not bound the extension-query prefix across models")
        precondition(xntfs_observation_disk_requests() == 0 && xntfs_observation_mount_calls() == 0)
        tasks.forEach { $0.cancel() }
        let extra = captures(models, count: 4, offset: 64, into: results)
        await requireEventually { results.busyCount == 64 }
        precondition(CaptureFixture.live == 4 && CaptureFixture.started == 4,
                     "Cancellation released whole-report admission before extension completion")
        CaptureFixture.releaseAll()
        for task in tasks + extra { await task.value }
        precondition(results.cancelledCount == 4 && results.busyCount == 64)
        precondition(CaptureFixture.live == 0 && xntfs_observation_mount_calls() == 0 && CaptureHistoryGate.state.started == 0,
                     "Cancelled extension query continued into downstream report work")

        CaptureFixture.reset()
        let beforeCancelled = CaptureResults()
        let cancelled = captures(models, count: 1, into: beforeCancelled)[0]
        cancelled.cancel(); await cancelled.value
        precondition(beforeCancelled.cancelledCount == 1 && CaptureFixture.started == 0,
                     "Pre-cancelled capture started an extension query")
        let retry = try await DiagnosticSnapshot.capture(model: models[0])
        precondition(retry.queryErrors.isEmpty && retry.devices.count == 2)
        print("PASS: whole-report entry caps 64 calls at four across models, rejects early and retains cancelled extension work until completion")
    }

    static func checkWholeCaptureDownstream(history: Bool) async throws {
        let monitor = await monitor(1)
        let model = AppModel(monitor: monitor, settings: AppSettings(defaults: nil))
        CaptureFixture.reset(); CaptureHistoryGate.reset(held: history)
        xntfs_observation_reset_counts()
        if history {
            DiagnosticRecorder.shared.holdCaptureHistoryForTest()
            await requireEventually { CaptureHistoryGate.state.entered }
        } else {
            xntfs_observation_hold_queue(monitor.sessionRef()); xntfs_observation_wait_held()
        }
        let results = CaptureResults(), tasks = captures([model], count: 6, into: results)
        await requireEventually { results.busyCount == 2 }
        if history { await requireEventually { CaptureHistoryGate.state.started == 4 } }
        precondition(CaptureFixture.started == 4 && CaptureFixture.live == 0)
        tasks.forEach { $0.cancel() }
        let extra = captures([model], count: 2, offset: 6, into: results)
        await requireEventually { results.busyCount == 4 }
        precondition(CaptureFixture.started == 4,
                     "Cancellation released admission before a downstream producer finished")
        if history {
            precondition(xntfs_observation_mount_calls() == 8)
            CaptureHistoryGate.release()
        } else {
            precondition(xntfs_observation_mount_calls() == 0 && CaptureHistoryGate.state.started == 0)
            xntfs_observation_release_and_drain(monitor.sessionRef())
        }
        for task in tasks + extra { await task.value }
        precondition(results.cancelledCount == 4 && results.busyCount == 4,
                     "Cancellation became a successful partial report")
        if !history {
            precondition(xntfs_observation_mount_calls() == 4 && CaptureHistoryGate.state.started == 0,
                         "Cancelled DA work continued into image/history acquisition")
        }
        let retry = try await DiagnosticSnapshot.capture(model: model)
        precondition(retry.queryErrors.isEmpty && retry.devices.count == 1)
        print("PASS: whole capture retains admission through cancelled \(history ? "recorder" : "device") work and retries after retirement")
    }

    static func checkWholeCaptureFreshness() async throws {
        let monitor = await monitor(1)
        let model = AppModel(monitor: monitor, settings: AppSettings(defaults: nil))
        CaptureFixture.reset(held: true)
        let results = CaptureResults(), tasks = captures([model], count: 4, into: results)
        await requireEventually { CaptureFixture.started == 4 }
        var seen: Set<Int> = []
        for index in 0..<4 {
            // No device work is in flight: each preceding capture has completed.
            xntfs_observation_set_mount(0, "xntfs", index % 2 == 0)
            CaptureFixture.releaseOne()
            await requireEventually { results.values.count == index + 1 }
            let arrived = Set(results.values.keys).subtracting(seen)
            precondition(arrived.count == 1)
            let snapshot = try results.values[arrived.first!]!.get()
            seen.formUnion(arrived)
            precondition(snapshot.devices.count == 1 && snapshot.devices[0].readOnly == (index % 2 == 0),
                         "Accepted reports reused an earlier caller's observation")
        }
        CaptureFixture.releaseAll()
        for task in tasks { await task.value }
        print("PASS: admitted reports acquire independent fresh observations")
    }

    static func checkWholeCaptureCycles() async {
        let monitor = await monitor(0)
        let model = AppModel(monitor: monitor, settings: AppSettings(defaults: nil))
        for cycle in 0..<32 {
            CaptureFixture.reset(held: true)
            let results = CaptureResults(), tasks = captures([model], count: 8, into: results)
            await requireEventually { results.busyCount == 4 }
            if cycle % 2 == 0 { tasks.forEach { $0.cancel() } }
            CaptureFixture.releaseAll()
            for task in tasks { await task.value }
            precondition(results.values.count == 8 && results.busyCount == 4 && CaptureFixture.live == 0)
            precondition(results.cancelledCount == (cycle % 2 == 0 ? 4 : 0))
            if cycle % 2 != 0 {
                precondition(results.values.values.filter { (try? $0.get()) != nil }.count == 4)
            }
        }
        print("PASS: 32 saturated capture cycles retire success/cancellation without losing capacity")
    }

    static func monitor(_ count: UInt32) async -> DiskArbitrationMonitor {
        xntfs_observation_reset(count, 32)
        let result = DiskArbitrationMonitor()!
        result.start(); xntfs_observation_drain(result.sessionRef())
        for i in 0..<count { xntfs_observation_emit(result.sessionRef(), i, 0) }
        await flushMain()
        precondition(result.currentDevices.count == Int(count))
        return result
    }

    private static func queries(_ monitor: DiskArbitrationMonitor, count: Int,
                        into results: QueryResults) -> [Task<Void, Never>] {
        (0..<count).map { index in
            Task {
                do { results.values[index] = .success(try await monitor.devicesForDiagnostics()) }
                catch { results.values[index] = .failure(error) }
            }
        }
    }

    static func finish(_ tasks: [Task<Void, Never>], monitor: DiskArbitrationMonitor) async {
        for task in tasks { await task.value }
        xntfs_observation_drain(monitor.sessionRef())
        await flushMain()
        #if HOST_DIAGNOSTIC_PROBE
        DiagnosticOwnershipProbe.checkRetired()
        precondition(PublicationOwnershipProbe.snapshot()["live"] == 0)
        #endif
    }

    static func checkCapacity(_ count: UInt32) async throws {
        let monitor = await monitor(count)
        let original = monitor.currentDevices
        xntfs_observation_reset_counts()
        xntfs_observation_hold_queue(monitor.sessionRef()); xntfs_observation_wait_held()
        let results = QueryResults(), tasks = queries(monitor, count: 64, into: results)
        let rejectedWhileHeld = await waitUntil { results.busyCount == 60 }
        #if HOST_DIAGNOSTIC_PROBE
        print("Held query ownership: \(DiagnosticOwnershipProbe.snapshot())")
        #endif
        if rejectedWhileHeld {
            precondition(xntfs_observation_disk_requests() == 0 && xntfs_observation_mount_calls() == 0)
            // Cancelling an accepted caller cannot free the queued operation's slot.
            for i in tasks.indices where results.values[i] == nil { tasks[i].cancel() }
            do {
                _ = try await monitor.devicesForDiagnostics()
                preconditionFailure("Cancellation reopened occupied query capacity")
            } catch {
                precondition((error as NSError).domain == NSPOSIXErrorDomain && (error as NSError).code == Int(EBUSY))
            }
        }
        xntfs_observation_release_and_drain(monitor.sessionRef())
        await finish(tasks, monitor: monitor)
        print("Capacity result: devices=\(count) accepted=\(results.successes.count) busy=\(results.busyCount)")
        precondition(rejectedWhileHeld && results.successes.count == 4 && results.busyCount == 60,
                     "Diagnostic backlog exceeded four admitted queries")
        precondition(results.successes.allSatisfy { $0.count == Int(count) })
        precondition(xntfs_observation_disk_requests() == count * 4)
        precondition(xntfs_observation_mount_calls() == (count == 0 ? 0 : 4))
        precondition(zip(original, monitor.currentDevices).allSatisfy { $0.isSameDevice(as: $1) })
        let later = try await monitor.devicesForDiagnostics()
        precondition(later.isComplete && later.devices.count == Int(count), "Completed query did not release admission")
        if count > 0 {
            xntfs_observation_fail_table(true)
            let failed = try await monitor.devicesForDiagnostics()
            precondition(!failed.isComplete && failed.devices.isEmpty)
            xntfs_observation_fail_table(false)
            let recovered = try await monitor.devicesForDiagnostics()
            precondition(recovered.isComplete && recovered.devices.count == Int(count))
        }
        print("PASS: bounded query admission, explicit EBUSY, cancellation ownership, failure and later retry")
    }

    static func checkFreshness() async throws {
        let monitor = await monitor(1)
        xntfs_observation_reset_counts()
        xntfs_observation_hold_next_table()
        let first = Task { try await monitor.devicesForDiagnostics() }
        // Let the task enter the monitor before waiting synchronously on its gate.
        let entered = await waitUntil { xntfs_observation_mount_calls() == 1 }
        precondition(entered)
        xntfs_observation_wait_held()
        xntfs_observation_set_mount(0, "ntfs", false)
        let results = QueryResults(), later = queries(monitor, count: 4, into: results)
        let rejected = await waitUntil { results.busyCount == 1 }
        xntfs_observation_release_and_drain(monitor.sessionRef())
        let old = try await first.value
        await finish(later, monitor: monitor)
        precondition(rejected && results.successes.count == 3)
        precondition(old.isComplete && old.devices[0].mountedFileSystemType == "xntfs" && old.devices[0].readOnly)
        precondition(results.successes.allSatisfy { $0[0].mountedFileSystemType == "ntfs" && !$0[0].readOnly })
        precondition(xntfs_observation_mount_calls() == 4, "Distinct diagnostics were coalesced")
        print("PASS: active and queued queries retain separate FIFO snapshots")
    }

    static func checkIndependentMonitors() async throws {
        let first = await monitor(1)
        let second = DiskArbitrationMonitor()!
        second.start(); xntfs_observation_drain(second.sessionRef())
        xntfs_observation_emit(second.sessionRef(), 0, 0)
        xntfs_observation_hold_queue(first.sessionRef()); xntfs_observation_wait_held()
        let results = QueryResults(), tasks = queries(first, count: 5, into: results)
        let rejected = await waitUntil { results.busyCount == 1 }
        let independent = try await second.devicesForDiagnostics()
        precondition(independent.isComplete && independent.devices.count == 1)
        second.refresh(); xntfs_observation_drain(second.sessionRef())
        xntfs_observation_release_and_drain(first.sessionRef())
        await finish(tasks, monitor: first)
        precondition(rejected && results.successes.count == 4)
        print("PASS: query admission is per monitor and leaves ordinary refresh independent")
    }

    static func checkRepeated() async {
        let monitor = await monitor(8)
        let registrations = xntfs_observation_registration_calls()
        xntfs_observation_reset_counts()
        for cycle in 0..<100 {
            xntfs_observation_hold_queue(monitor.sessionRef()); xntfs_observation_wait_held()
            let results = QueryResults(), tasks = queries(monitor, count: 8, into: results)
            let rejected = await waitUntil { results.busyCount == 4 }
            xntfs_observation_release_and_drain(monitor.sessionRef())
            await finish(tasks, monitor: monitor)
            precondition(rejected && results.successes.count == 4)
            precondition(xntfs_observation_mount_calls() == UInt32((cycle + 1) * 4))
        }
        precondition(xntfs_observation_registration_calls() == registrations)
        print("PASS: 100 saturated query cycles release slots without repeated registration")
    }

    static func checkCapture() async throws {
        let monitor = await monitor(8)
        let model = AppModel(monitor: monitor, settings: AppSettings(defaults: nil))
        model.receiveDevices(monitor.currentDevices)
        // A synthetic direct image still belongs in a partial report, without its path.
        xntfs_observation_set_entry(8, "file:///tmp/private-image.ntfs", "/Volumes/SyntheticImage", "xntfs")
        let privateCause = NSError(domain: NSPOSIXErrorDomain, code: 5,
                                   userInfo: [NSFilePathErrorKey: "/Users/private/secret"])
        CaptureFixture.queryError = NSError(domain: "FixtureExtension", code: 77,
                                            userInfo: [NSUnderlyingErrorKey: privateCause])
        defer { CaptureFixture.queryError = nil }
        DiagnosticRecorder.shared.record(.mount, .failed, fields: [.device: "disk99s1"], error: privateCause)
        let history = await DiagnosticRecorder.shared.snapshot()
        precondition(history.storage == "process-memory-only")
        xntfs_observation_hold_queue(monitor.sessionRef()); xntfs_observation_wait_held()
        let results = QueryResults(), tasks = queries(monitor, count: 5, into: results)
        let rejected = await waitUntil { results.busyCount == 1 }
        precondition(rejected)
        let partial = try await DiagnosticSnapshot.capture(model: model)
        xntfs_observation_release_and_drain(monitor.sessionRef())
        await finish(tasks, monitor: monitor)
        precondition(partial.queryErrors.map(\.domain) == ["FixtureExtension", NSPOSIXErrorDomain,
                     "com.huanchuan.xntfs.deviceObservation", NSPOSIXErrorDomain], "Report lost query failure context")
        precondition(partial.queryErrors.map(\.code) == [77, 5, Int(EBUSY), Int(EBUSY)])
        precondition(partial.devices.count == 1 && partial.devices[0].kind == "directImage",
                     "Partial report invented a fresh physical-device observation")
        precondition(model.devices.count == 8 && model.lastError == nil)
        precondition(partial.history.events.contains { $0.action == .mount && $0.errors.first?.code == 5 })
        let encoded = try ProblemReport(description: "Test", steps: "", contactEmail: "", diagnostics: partial).encoded()
        let raw = String(decoding: encoded, as: UTF8.self)
        precondition(!raw.contains("private") && !raw.contains("secret") && !raw.contains("/Volumes/"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ProblemReport.self, from: encoded)
        precondition(decoded.schemaVersion == 1 && decoded.diagnostics?.queryErrors.map(\.code) == partial.queryErrors.map(\.code))
        CaptureFixture.queryError = nil
        xntfs_observation_set_mount(0, "ntfs", false)
        let retried = try await DiagnosticSnapshot.capture(model: model)
        precondition(retried.queryErrors.isEmpty && retried.devices.count == 9)
        let current = retried.devices.first { $0.device == "diskTest0" }!
        precondition(current.driver == "system" && !current.readOnly, "Retry used the stale UI list")
        precondition(model.devices[0].mountedFileSystemType == "xntfs")
        let fallback = AppModel(monitor: nil, settings: AppSettings(defaults: nil))
        fallback.receiveDevices(model.devices)
        let withoutMonitor = try await fallback.devicesForDiagnostics()
        precondition(!withoutMonitor.isComplete && withoutMonitor.devices.isEmpty)
        print("PASS: AppModel/capture preserve query context, partial images/history/privacy, encoding and fresh retry")
    }

    static func checkIncompleteCapture() async throws {
        let monitor = await monitor(8)
        let original = monitor.currentDevices
        let model = AppModel(monitor: monitor, settings: AppSettings(defaults: nil))
        model.receiveDevices(original)
        let domain = "com.huanchuan.xntfs.deviceObservation.incomplete"
        xntfs_observation_set_entry(8, "file:///tmp/private-image.ntfs", "/Volumes/SyntheticImage", "xntfs")
        let complete = try await DiagnosticSnapshot.capture(model: model)
        precondition(complete.queryErrors.isEmpty && complete.devices.count == 9)

        // Missing DA data is ambiguous; confirmed non-NTFS and unmounted rows are not errors.
        xntfs_observation_set_missing(0, true, false)
        xntfs_observation_set_missing(1, false, true)
        xntfs_observation_set_mount(2, "exfat", false)
        xntfs_observation_set_path(3, 2) // Stale mount path.
        xntfs_observation_set_mount(4, "", false)
        xntfs_observation_set_path(5, 3) // Not a file URL.
        xntfs_observation_set_kind(6, "ntfs")
        xntfs_observation_set_path(6, 0) // Legitimately unmounted.
        CaptureFixture.queryError = NSError(domain: "FixtureExtension", code: 77)
        defer { CaptureFixture.queryError = nil }
        let partial = try await DiagnosticSnapshot.capture(model: model)
        precondition(partial.queryErrors.map(\.domain) == ["FixtureExtension", domain],
                     "Missing metadata was exported as a complete observation")
        precondition(partial.queryErrors.map(\.code) == [77, 1])
        precondition(Set(partial.devices.map(\.device)) == ["diskTest6", "diskTest7", "direct-image-1"],
                     "Partial capture discarded good rows or invented unverified metadata")
        precondition(partial.devices.first { $0.device == "diskTest6" }?.state == "unmounted")
        precondition(partial.devices.first { $0.device == "diskTest7" }?.driver == "xntfs")
        precondition(model.devices.count == 8 && model.lastError == nil)
        precondition(zip(original, monitor.currentDevices).allSatisfy { $0.isSameDevice(as: $1) })
        let bytes = try ProblemReport(description: "Test", steps: "", contactEmail: "", diagnostics: partial).encoded()
        let text = String(decoding: bytes, as: UTF8.self)
        precondition(!text.contains("private") && !text.contains("/Volumes/"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ProblemReport.self, from: bytes)
        precondition(decoded.schemaVersion == 1 && decoded.diagnostics?.queryErrors.last?.domain == domain)
        CaptureFixture.queryError = nil

        for i in 0..<UInt32(8) {
            xntfs_observation_set_missing(i, false, false)
            xntfs_observation_set_path(i, 1)
            xntfs_observation_set_kind(i, "ntfs")
            xntfs_observation_set_mount(i, "xntfs", false)
        }
        let recovered = try await DiagnosticSnapshot.capture(model: model)
        precondition(recovered.queryErrors.isEmpty && recovered.devices.count == 9)

        // Each cause must mark a partial observation even when it is the only failure.
        for scenario in 0..<6 {
            switch scenario {
            case 0: xntfs_observation_set_missing(0, true, false)
            case 1: xntfs_observation_set_missing(0, false, true)
            case 2: xntfs_observation_set_path(0, 2)
            case 3: xntfs_observation_set_path(0, 3)
            case 4: xntfs_observation_set_mount(0, "", false)
            default: xntfs_observation_set_entry(0, "/dev/diskReused", "/Volumes/Synthetic0", "xntfs")
            }
            let value = try await DiagnosticSnapshot.capture(model: model)
            precondition(value.queryErrors.map(\.domain) == [domain] && value.queryErrors.map(\.code) == [1],
                         "Isolated metadata failure lost its incomplete marker")
            precondition(value.devices.count == 8 && !value.devices.contains { $0.device == "diskTest0" })
            xntfs_observation_set_missing(0, false, false)
            xntfs_observation_set_path(0, 1)
            xntfs_observation_set_entry(0, "/dev/diskTest0", "/Volumes/Synthetic0", "xntfs")
        }

        // A truthful DA hint cannot manufacture mounted flags after the table fails.
        xntfs_observation_fail_table(true)
        let failed = try await DiagnosticSnapshot.capture(model: model)
        precondition(failed.queryErrors.map(\.domain) == [domain,
                     "com.huanchuan.xntfs.imageObservation", NSPOSIXErrorDomain] && failed.devices.isEmpty)
        precondition(failed.queryErrors.map(\.code) == [1, Int(EIO), Int(EIO)])
        xntfs_observation_fail_table(false)
        xntfs_observation_reset_counts()
        xntfs_observation_fail_next_table()
        let transient = try await DiagnosticSnapshot.capture(model: model)
        precondition(transient.queryErrors.map(\.domain) == [domain] && transient.devices.count == 8)
        precondition(!transient.devices.contains { $0.device == "diskTest0" })
        precondition(xntfs_observation_mount_calls() == 3, "One failed table poisoned later rows or retried without bound")

        // The same mount path can now belong to a different source.
        xntfs_observation_set_entry(0, "/dev/diskReused", "/Volumes/Synthetic0", "xntfs")
        let reused = try await DiagnosticSnapshot.capture(model: model)
        precondition(reused.queryErrors.map(\.domain) == [domain] && reused.devices.count == 8)
        precondition(!reused.devices.contains { $0.device == "diskTest0" })
        xntfs_observation_set_entry(0, "/dev/diskTest0", "/Volumes/Synthetic0", "xntfs")

        for cycle in 0..<100 {
            xntfs_observation_set_missing(0, false, cycle % 2 == 0)
            let value = try await DiagnosticSnapshot.capture(model: model)
            precondition(value.queryErrors.map(\.domain) == (cycle % 2 == 0 ? [domain] : []))
            precondition(value.devices.count == (cycle % 2 == 0 ? 8 : 9))
            xntfs_observation_drain(monitor.sessionRef())
            #if HOST_DIAGNOSTIC_PROBE
            DiagnosticOwnershipProbe.checkRetired()
            #endif
        }

        for i in 0..<UInt32(8) { xntfs_observation_set_mount(i, "exfat", false) }
        let reformatted = try await DiagnosticSnapshot.capture(model: model)
        precondition(reformatted.queryErrors.isEmpty && reformatted.devices.count == 1)
        for i in 0..<UInt32(8) { xntfs_observation_set_path(i, 0) }
        xntfs_observation_reset_counts()
        let unmounted = try await DiagnosticSnapshot.capture(model: model)
        precondition(unmounted.queryErrors.isEmpty && unmounted.devices.count == 9)
        precondition(unmounted.devices.filter { $0.state == "unmounted" }.count == 8)
        precondition(xntfs_observation_mount_calls() == 1, "Unmounted device diagnostics queried the table")
        for i in 0..<UInt32(8) { xntfs_observation_emit(monitor.sessionRef(), i, 2) }
        let gone = try await DiagnosticSnapshot.capture(model: model)
        precondition(gone.queryErrors.isEmpty && gone.devices.count == 1)
        let unavailable = AppModel(monitor: nil, settings: AppSettings(defaults: nil))
        unavailable.receiveDevices(original)
        let noMonitor = try await DiagnosticSnapshot.capture(model: unavailable)
        precondition(noMonitor.queryErrors.map(\.domain) == [domain] && noMonitor.devices.count == 1,
                     "No monitor presented stale UI state as a fresh observation")
        print("PASS: incomplete metadata preserves good rows and one bounded warning; normal exclusions, transient retries, source identity, privacy and no-monitor state")
    }

    static func checkImageQueryFailure() async throws {
        let monitor = await monitor(0)
        let model = AppModel(monitor: monitor, settings: AppSettings(defaults: nil))
        xntfs_observation_set_entry(0, "file:///tmp/private-image.ntfs", "/Volumes/SyntheticImage", "xntfs")
        let image = ImageMountService.mountedImages()[0]
        CaptureFixture.queryError = NSError(domain: "FixtureExtension", code: 77,
                                            userInfo: [NSFilePathErrorKey: "/Users/private/secret"])
        defer { CaptureFixture.queryError = nil }
        xntfs_observation_fail_table(true)
        xntfs_observation_reset_counts()
        let partial = try await DiagnosticSnapshot.capture(model: model)
        precondition(xntfs_observation_mount_calls() == 1 && partial.devices.isEmpty)
        // Failure/absence paths stop before FileManager unmount; no OS operation is submitted.
        await model.unmountImage(image)
        xntfs_observation_drain(monitor.sessionRef())
        let history = await DiagnosticRecorder.shared.snapshot()
        let unmount = history.events.last { $0.action == .unmount }
        print("Image query failure: report domains=\(partial.queryErrors.map(\.domain)); unmount phase=\(unmount?.phase.rawValue ?? "none")")
        precondition(partial.queryErrors.map(\.domain) == ["FixtureExtension",
                     "com.huanchuan.xntfs.imageObservation", NSPOSIXErrorDomain],
                     "Image table failure was exported as a successful empty list")
        precondition(partial.queryErrors.map(\.code) == [77, Int(EIO), Int(EIO)])
        precondition(model.lastError != nil && model.unmountingImages.isEmpty && unmount?.phase == .failed,
                     "Unavailable image observation was recorded as successful unmount")
        precondition(unmount?.errors.first?.code == Int(EIO))
        let bytes = try ProblemReport(description: "Test", steps: "", contactEmail: "", diagnostics: partial).encoded()
        let text = String(decoding: bytes, as: UTF8.self)
        precondition(!text.contains("private") && !text.contains("/Volumes/"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ProblemReport.self, from: bytes)
        precondition(decoded.schemaVersion == 1 && decoded.diagnostics?.queryErrors.last?.code == Int(EIO))
        CaptureFixture.queryError = nil
        xntfs_observation_fail_table(false)
        let recovered = try await DiagnosticSnapshot.capture(model: model)
        precondition(recovered.queryErrors.isEmpty && recovered.devices.count == 1)
        for (error, nonnull) in [(EIO, true), (ENOMEM, false), (0, false)] {
            xntfs_observation_set_table_failure(error, nonnull)
            xntfs_observation_fail_table(true)
            xntfs_observation_reset_counts()
            let value = try await DiagnosticSnapshot.capture(model: model)
            let expected = Int(error > 0 ? error : EIO)
            precondition(value.queryErrors.map(\.domain) == ["com.huanchuan.xntfs.imageObservation", NSPOSIXErrorDomain])
            precondition(value.queryErrors.map(\.code) == [expected, expected] && value.devices.isEmpty)
            precondition(xntfs_observation_mount_calls() == 1)
            precondition(ImageMountService.mountedImages().isEmpty && DiskArbitrationMonitor.mountTable().isEmpty,
                         "Legacy UI observation lost its existing fallback")
            do {
                try await ImageMountService.unmount(image)
                preconditionFailure("Unavailable table became successful image unmount")
            } catch {
                precondition((error as NSError).domain == NSPOSIXErrorDomain && (error as NSError).code == expected)
            }
        }
        xntfs_observation_set_table_failure(EIO, true)
        for cycle in 0..<100 {
            xntfs_observation_fail_table(cycle % 2 == 0)
            xntfs_observation_reset_counts()
            let value = try await DiagnosticSnapshot.capture(model: model)
            precondition(value.queryErrors.count == (cycle % 2 == 0 ? 2 : 0))
            precondition(value.devices.count == (cycle % 2 == 0 ? 0 : 1))
            precondition(xntfs_observation_mount_calls() == 1)
            xntfs_observation_drain(monitor.sessionRef())
            #if HOST_DIAGNOSTIC_PROBE
            DiagnosticOwnershipProbe.checkRetired()
            #endif
        }
        xntfs_observation_set_entry(0, "/dev/diskUnrelated", "/Volumes/SyntheticImage", "apfs")
        let absent = try await DiagnosticSnapshot.capture(model: model)
        precondition(absent.queryErrors.isEmpty && absent.devices.isEmpty)
        try await ImageMountService.unmount(image) // Confirmed absence remains a no-op.
        print("PASS: image query error keeps context/privacy, failed unmount retires state, normal absence and retry remain distinct")
    }

    static func checkIndependentImageFailure() async throws {
        let monitor = await monitor(2)
        let model = AppModel(monitor: monitor, settings: AppSettings(defaults: nil))
        xntfs_observation_set_entry(2, "file:///tmp/private-image.ntfs", "/Volumes/SyntheticImage", "xntfs")
        model.refreshDevices(); xntfs_observation_drain(monitor.sessionRef())
        precondition(model.mountedImages.count == 1)
        xntfs_observation_reset_counts()
        xntfs_observation_fail_table_on_call(2) // Device snapshot succeeds, independent image query fails.
        let partial = try await DiagnosticSnapshot.capture(model: model)
        precondition(xntfs_observation_mount_calls() == 2)
        precondition(partial.queryErrors.map(\.domain) == ["com.huanchuan.xntfs.imageObservation", NSPOSIXErrorDomain])
        precondition(Set(partial.devices.map(\.device)) == ["diskTest0", "diskTest1"])
        precondition(partial.devices.allSatisfy { $0.driver == "xntfs" } && model.mountedImages.count == 1,
                     "Failed image query lost good device evidence or substituted stale UI images")
        let retry = try await DiagnosticSnapshot.capture(model: model)
        precondition(retry.queryErrors.isEmpty && retry.devices.count == 3)
        print("PASS: independent image failure retains confirmed devices, excludes stale UI images and retries afresh")
    }

    static func retire() async {
        let retired = await waitUntil { xntfs_observation_sessions() == 0 }
        precondition(retired, "Monitor/session retained after query")
        await flushMain()
        #if HOST_DIAGNOSTIC_PROBE
        DiagnosticOwnershipProbe.checkRetired()
        precondition(PublicationOwnershipProbe.snapshot()["live"] == 0)
        #endif
    }

    static func main() async throws {
        setbuf(stdout, nil) // Preserve ownership/count evidence if a negative control traps.
        xntfs_test_begin_query_guard()
        defer { xntfs_test_end_query_guard() }
        var control = statfs()
        precondition(statfs("/Volumes/Synthetic0", &control) == -1 && xntfs_test_query_count() == 1)
        xntfs_test_begin_query_guard()
        if let argument = CommandLine.arguments.firstIndex(of: "--passive-case") {
            switch CommandLine.arguments[argument + 1] {
            case "monitor": try await checkPassiveMonitorSource()
            case "model": await checkPassiveModelSource()
            case "history": await checkUnknownHistory()
            default: preconditionFailure("unknown passive case")
            }
            await retire()
            passiveCheck(xntfs_test_query_count() == 0 && xntfs_observation_wrong_flags() == 0, "unexpected filesystem queries")
            return
        }
        try await checkPassiveMonitorSource(); await retire()
        await checkPassiveModelSource(); await retire()
        await checkUnknownHistory(); await retire()
        await checkPublicationBurst(); await retire()
        await checkPublicationFollowup(); await retire()
        await checkPublicationIndependence(); await retire()
        await checkPublicationTeardown(); await retire()
        await checkRepeatedPublications(); await retire()
        for registry: UInt64 in [1000, 0] {
            await checkPublishedActionIdentity(registry: registry, oldError: nil); await retire()
            await checkPublishedActionIdentity(registry: registry, oldError: POSIXError(.EIO)); await retire()
        }
        try await checkWholeCaptureEntry(); await retire()
        try await checkWholeCaptureDownstream(history: false); await retire()
        try await checkWholeCaptureDownstream(history: true); await retire()
        try await checkWholeCaptureFreshness(); await retire()
        await checkWholeCaptureCycles(); await retire()
        if !CommandLine.arguments.contains("--capture-only") {
            try await checkCapacity(8); await retire()
            try await checkCapacity(0); await retire()
            try await checkFreshness(); await retire()
            try await checkIndependentMonitors(); await retire()
            await checkRepeated(); await retire()
        }
        try await checkCapture(); await retire()
        try await checkImageQueryFailure(); await retire()
        try await checkIndependentImageFailure(); await retire()
        try await checkIncompleteCapture(); await retire()
        precondition(xntfs_test_query_count() == 0 && xntfs_observation_wrong_flags() == 0)
        #if HOST_DIAGNOSTIC_PROBE
        print("Final query ownership: \(DiagnosticOwnershipProbe.snapshot())")
        #endif
        print("PASS: no per-volume queries, real DA/FSClient registration, preference writes or device actions")
    }
}
