import Foundation
import DiskArbitration
import Darwin

@MainActor
enum MountModuleFixture {
    struct Module { let bundleIdentifier: String; let isEnabled: Bool }
    static var enabled = true
    static var error: NSError?
    static var queries = 0
    static var installedExtensions: [Module] {
        get async throws {
            queries += 1
            if let error { throw error }
            return [Module(bundleIdentifier: ExtensionStatus.bundleID, isEnabled: enabled)]
        }
    }
}

// Optional witness in a copied DACallbackBox; no production instrumentation.
nonisolated final class MountCallbackProbe: @unchecked Sendable {
    static let shared = MountCallbackProbe()
    private let lock = NSLock()
    private var created = 0, live = 0, peak = 0
    func acquire() { lock.lock(); created += 1; live += 1; peak = max(peak, live); lock.unlock() }
    func release() { lock.lock(); live -= 1; precondition(live >= 0); lock.unlock() }
    func snapshot() -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return ["created": created, "live": live, "peak": peak]
    }
}

@main
@MainActor
struct MountCompletionTests {
    struct Context {
        let monitor: DiskArbitrationMonitor
        let service: MountService
        let devices: [NTFSDevice]
    }
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { print("FAIL: \(message)"); exit(1) }
        checks += 1
    }
    static func until(_ message: String, _ condition: () -> Bool) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !condition() {
            if ProcessInfo.processInfo.systemUptime > deadline { check(false, "timeout: \(message)") }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
    static func context(_ count: UInt32 = 1, entries: UInt32 = 64,
                        bsd: String? = nil, writable: Int32 = 1) -> Context {
        xntfs_mount_fixture_reset()
        xntfs_observation_reset(count, entries)
        MountModuleFixture.enabled = true; MountModuleFixture.error = nil; MountModuleFixture.queries = 0
        for index in 0..<count {
            xntfs_observation_set_kind(index, "ntfs")
            xntfs_observation_set_path(index, 0)
            xntfs_observation_set_writable(index, writable)
        }
        if let bsd {
            precondition(count == 1)
            xntfs_observation_set_bsd(0, bsd)
            xntfs_observation_set_entry(0, "/dev/" + bsd, "/Volumes/Synthetic0", "xntfs")
        }
        let monitor = DiskArbitrationMonitor()!
        monitor.start(); xntfs_observation_drain(monitor.sessionRef())
        for index in 0..<count { xntfs_observation_emit(monitor.sessionRef(), index, 0) }
        return Context(monitor: monitor, service: MountService(monitor: monitor), devices: monitor.currentDevices)
    }
    static func mounted(_ outcome: MountOutcome) -> Bool {
        if case .mounted = outcome { return true }
        return false
    }
    static func failed(_ outcome: MountOutcome, _ message: String) -> Bool {
        if case .failed(let value) = outcome { return value == message }
        return false
    }
    static func prepareResult(_ index: UInt32 = 0, readOnly: Bool = false) {
        xntfs_observation_set_path(index, 1)
        xntfs_observation_set_mount(index, "xntfs", readOnly)
    }
    static func retired() async {
        await until("DA session retirement") { xntfs_observation_sessions() == 0 }
        check(xntfs_mount_pending() == 0 && xntfs_observation_media_live() == 0 && xntfs_observation_iterators_live() == 0,
              "callback/media ownership fully retired")
        #if MOUNT_COMPLETION_PROBE
        check(MountCallbackProbe.shared.snapshot()["live"] == 0, "callback boxes retired")
        #endif
    }
    static func replacement(_ kind: String, baseline: Bool = false) async {
        let ctx = context()
        let before = await DiagnosticRecorder.shared.snapshot()
        let call = Task { await ctx.service.unifiedMount(ctx.devices[0], readOnly: false) }
        await until("mount submission") { xntfs_mount_submissions() == 1 }
        prepareResult()
        switch kind {
        case "registry": xntfs_observation_set_registry(0, 9000)
        case "discovery":
            xntfs_observation_emit(ctx.monitor.sessionRef(), 0, 2)
            xntfs_observation_emit(ctx.monitor.sessionRef(), 0, 0)
        case "missing": xntfs_observation_set_missing(0, true, false)
        case "source": xntfs_observation_set_entry(0, "/dev/diskOther", "/Volumes/Synthetic0", "xntfs")
        default: preconditionFailure("bad fixture scenario")
        }
        xntfs_observation_reset_counts()
        xntfs_mount_finish(0, 0)
        let result = await call.value
        let history = await DiagnosticRecorder.shared.snapshot()
        let oldIDs = Set(before.events.map(\.id))
        let events = history.events.filter { !oldIDs.contains($0.id) && $0.action == .mount }
        if baseline {
            check(mounted(result), "baseline wrongly accepts replaced \(kind)")
            check(events.contains { $0.phase == .succeeded }, "baseline records false success")
            print("BASELINE REPRODUCED: \(kind) replacement still returns and logs mounted")
        } else {
            let error = kind == "source" ? MountError.unexpectedMount : MountError.diskNotFound(ctx.devices[0].id)
            check(failed(result, error.localizedDescription), "completion rejects replaced \(kind)")
            check(!events.contains { $0.phase == .succeeded } && events.last?.phase == .failed,
                  "replaced \(kind) has no false successful diagnostic")
            check(xntfs_observation_mount_calls() == (kind == "source" ? 1 : 0), "identity checked before mount metadata")
        }
        check(xntfs_mount_completions() == 1 && xntfs_mount_pending() == 0, "replacement callback completes once")
    }
    static func normalAndFailures() async {
        let ctx = context()
        for scenario in ["rw", "ro", "wrong-mode", "wrong-driver", "missing-description", "missing-path", "bad-path", "table-error", "second-table-error"] {
            xntfs_mount_fixture_reset()
            xntfs_observation_set_path(0, 0); xntfs_observation_set_missing(0, false, false)
            xntfs_observation_fail_table(false)
            let readOnly = scenario == "ro"
            let call = Task { await ctx.service.unifiedMount(ctx.devices[0], readOnly: readOnly) }
            await until("normal/failure submission") { xntfs_mount_submissions() == 1 }
            check(xntfs_mount_requested_read_only(0) == readOnly, "explicit mount mode retained")
            prepareResult(readOnly: readOnly)
            switch scenario {
            case "wrong-mode": xntfs_observation_set_mount(0, "xntfs", true)
            case "wrong-driver": xntfs_observation_set_mount(0, "ntfs", readOnly)
            case "missing-description": xntfs_observation_set_missing(0, false, true)
            case "missing-path": xntfs_observation_set_path(0, 0)
            case "bad-path": xntfs_observation_set_path(0, 3)
            case "table-error": xntfs_observation_fail_table(true)
            default: break
            }
            xntfs_observation_reset_counts()
            if scenario == "second-table-error" { xntfs_observation_fail_table_on_call(2) }
            xntfs_mount_finish(0, 0)
            let outcome = await call.value
            if scenario == "rw" || scenario == "ro" || scenario == "second-table-error" {
                check(mounted(outcome), "healthy mode succeeds")
                check(xntfs_observation_mount_calls() == 1, "success diagnostics reuse verified mount metadata")
                let event = await DiagnosticRecorder.shared.snapshot().events.last
                check(event?.phase == .succeeded && event?.fields["effectiveReadOnly"] == String(readOnly),
                      "successful diagnostic uses validated mode")
            } else {
                let error = scenario == "wrong-mode" ? MountError.accessModeMismatch : MountError.unexpectedMount
                check(failed(outcome, error.localizedDescription), "\(scenario) remains a failed postcondition")
                check(xntfs_observation_mount_calls() <= 1, "failure does not retry mount metadata")
            }
            check(xntfs_mount_completions() == 1 && xntfs_observation_media_live() == 0, "normal/error owners released")
        }
    }
    static func queryAndDAErrors() async {
        let ctx = context()
        MountModuleFixture.enabled = false
        let unavailable = await ctx.service.unifiedMount(ctx.devices[0], readOnly: false)
        check(failed(unavailable, MountError.extensionUnavailable.localizedDescription),
              "unavailable extension preserved")
        MountModuleFixture.enabled = true
        let error = NSError(domain: "fixture.extension", code: 73)
        MountModuleFixture.error = error
        let result = await ctx.service.unifiedMount(ctx.devices[0], readOnly: false)
        check(failed(result, error.localizedDescription) && xntfs_mount_submissions() == 0, "query failure never submits mount")
        MountModuleFixture.error = nil
        let call = Task { await ctx.service.unifiedMount(ctx.devices[0], readOnly: false) }
        await until("DA error submission") { xntfs_mount_submissions() == 1 }
        xntfs_observation_set_registry(0, 9000)
        xntfs_observation_reset_counts()
        xntfs_mount_finish(0, DAReturn(kDAReturnBusy))
        let refused = await call.value
        check(failed(refused, MountError.dissented(status: DAReturn(kDAReturnBusy), message: "fixture refusal").localizedDescription),
              "DA failure is not overwritten by later identity loss")
        check(xntfs_observation_disk_requests() == 0 && xntfs_observation_mount_calls() == 0, "failed callback does not run success validation")
        let history = await DiagnosticRecorder.shared.snapshot()
        check(history.events.contains { $0.errors.contains { $0.domain == "DiskArbitration" && $0.code == Int(kDAReturnBusy) } },
              "native numeric refusal preserved")
    }
    static func sandboxDenial(_ scenario: String) async {
        let initialReadOnly = scenario == "native-ro" || scenario == "absent-ro"
        let ctx = context(bsd: scenario == "invalid-bsd" ? nil : "disk42s1",
                          writable: initialReadOnly ? 0 : 1)
        var device = ctx.devices[0]
        if scenario == "image" { device.kind = .diskImage }
        let requestReadOnly = scenario == "requested-ro"
        if scenario == "preflight-ro" { xntfs_observation_set_writable(0, 0) }
        let before = await DiagnosticRecorder.shared.snapshot()
        var done = false
        let call = Task {
            let result = await ctx.service.unifiedMount(device, readOnly: requestReadOnly)
            done = true
            return result
        }
        await until("sandbox denial submission") { xntfs_mount_submissions() == 1 }
        check(xntfs_mount_requested_read_only(0) == (requestReadOnly || initialReadOnly || scenario == "preflight-ro"),
              "denial fixture submitted expected native mode")
        switch scenario {
        case "registry": xntfs_observation_set_registry(0, 9000)
        case "discovery":
            xntfs_observation_emit(ctx.monitor.sessionRef(), 0, 2)
            xntfs_observation_emit(ctx.monitor.sessionRef(), 0, 0)
        case "missing": xntfs_observation_set_missing(0, true, false)
        case "description": xntfs_observation_set_missing(0, false, true)
        case "mounted": xntfs_observation_set_path(0, 1)
        case "readonly": xntfs_observation_set_writable(0, 0)
        case "absent-rw", "absent-ro": xntfs_observation_set_writable(0, -1)
        case "cancelled":
            call.cancel()
            await Task.yield()
            check(!done && xntfs_mount_pending() == 1, "denial cancellation retains native completion")
        default: break
        }
        xntfs_observation_reset_counts()
        xntfs_mount_finish(0, DAReturn(kDAReturnNotPrivileged))
        let result = await call.value
        print("DENIAL \(scenario): \(result)")
        switch scenario {
        case "registry", "discovery", "missing", "description":
            check(failed(result, MountError.diskNotFound(device.id).localizedDescription),
                  "denial cannot offer a command for \(scenario) media")
        case "mounted":
            check(failed(result, MountError.alreadyMounted.localizedDescription), "denial cannot remount newly mounted media")
        case "invalid-bsd":
            check(failed(result, MountError.sandboxDenied.localizedDescription), "invalid BSD command remains rejected")
        case "image":
            check(failed(result, MountError.dissented(status: DAReturn(kDAReturnNotPrivileged), message: "fixture refusal").localizedDescription),
                  "image refusal remains original native error")
        default:
            let expectedReadOnly = requestReadOnly || initialReadOnly || scenario == "readonly" || scenario == "preflight-ro"
            let expected = expectedReadOnly ? "diskutil mount readOnly disk42s1" : "diskutil mount -mountOptions rw disk42s1"
            if case .needsSystemMount(let message, let command) = result {
                check(command == expected && message == MountError.sandboxDenied.localizedDescription,
                      "denial \(scenario) uses current native mode and original message")
            } else { check(false, "current physical denial must offer a command") }
        }
        let history = await DiagnosticRecorder.shared.snapshot()
        let prior = Set(before.events.map(\.id))
        let events = history.events.filter { !prior.contains($0.id) && $0.action == .mount }
        check(events.contains { $0.errors.contains { $0.domain == "DiskArbitration" && $0.code == Int(kDAReturnNotPrivileged) } },
              "denial preserves native numeric error")
        check(!events.contains { $0.phase == .succeeded } && events.last?.phase == .failed,
              "fallback never logs successful mounting")
        check(MountModuleFixture.queries == 1, "fallback does not repeat extension query")
        check(xntfs_observation_mount_calls() == 0 && xntfs_observation_disk_requests() == (scenario == "discovery" || scenario == "image" ? 0 : 1),
              "fallback observes current identity once without mount-table query")
        check(done && xntfs_mount_completions() == 1 && xntfs_mount_pending() == 0,
              "denied callback completes exactly once")
    }
    static func denialRetry() async {
        let ctx = context(bsd: "disk42s1")
        for readOnly in [true, false] {
            xntfs_mount_fixture_reset()
            let call = Task { await ctx.service.unifiedMount(ctx.devices[0], readOnly: false) }
            await until("denial retry submission") { xntfs_mount_submissions() == 1 }
            xntfs_observation_set_writable(0, readOnly ? 0 : 1)
            xntfs_mount_finish(0, DAReturn(kDAReturnNotPrivileged))
            if case .needsSystemMount(_, let command) = await call.value {
                check(command == (readOnly ? "diskutil mount readOnly disk42s1" : "diskutil mount -mountOptions rw disk42s1"),
                      "retry recomputes native writability without caching command")
            } else { check(false, "denial retry offers current command") }
        }
    }
    static func denialLifetime() async {
        for cycle in 0..<16 {
            weak var service: MountService?
            func run() async {
                let ctx = context(bsd: "disk42s1")
                service = ctx.service
                let call = Task { await ctx.service.unifiedMount(ctx.devices[0], readOnly: false) }
                await until("denial lifetime submission") { xntfs_mount_submissions() == 1 }
                if cycle % 2 == 0 { xntfs_observation_set_registry(0, 9000) }
                xntfs_mount_finish(0, DAReturn(kDAReturnNotPrivileged))
                let outcome = await call.value
                if cycle % 2 == 0 {
                    check(failed(outcome, MountError.diskNotFound(ctx.devices[0].id).localizedDescription), "denial lifetime rejects replaced media")
                } else if case .needsSystemMount = outcome {
                    check(true, "denial lifetime offers valid command")
                } else { check(false, "denial lifetime current outcome") }
            }
            await run()
            await until("denial service released") { service == nil }
            await retired()
        }
    }
    static func allDenials() async {
        for scenario in ["registry", "discovery", "missing", "description", "mounted", "readonly",
                         "rw", "requested-ro", "native-ro", "preflight-ro", "absent-rw", "absent-ro",
                         "invalid-bsd", "image", "cancelled"] {
            await sandboxDenial(scenario); await retired()
        }
        await denialRetry(); await retired()
        await denialLifetime()
    }
    static func cancellationAndIndependence() async {
        let ctx = context(2)
        var firstDone = false
        let first = Task { let result = await ctx.service.unifiedMount(ctx.devices[0], readOnly: false); firstDone = true; return result }
        await until("first mount") { xntfs_mount_submissions() == 1 }
        first.cancel()
        let second = Task { await ctx.service.unifiedMount(ctx.devices[1], readOnly: true) }
        await until("second mount") { xntfs_mount_submissions() == 2 }
        check(!firstDone && xntfs_mount_pending() == 2, "cancelled submitted mount retains completion ownership")
        prepareResult(1, readOnly: true); xntfs_mount_finish(1, 0)
        let secondResult = await second.value
        check(mounted(secondResult) && !firstDone && xntfs_mount_pending() == 1, "independent mount completes first")
        prepareResult(); xntfs_mount_finish(0, 0)
        let firstResult = await first.value
        check(mounted(firstResult) && firstDone, "cancelled caller still observes submitted mount outcome")
    }
    static func lifetime() async {
        for cycle in 0..<32 {
            weak var service: MountService?
            func run() async {
                let ctx = context()
                service = ctx.service
                let call = Task { await ctx.service.unifiedMount(ctx.devices[0], readOnly: false) }
                await until("lifetime submission") { xntfs_mount_submissions() == 1 }
                check(service != nil && xntfs_mount_pending() == 1, "pending service owned")
                prepareResult()
                if cycle % 2 == 0 { xntfs_observation_set_registry(0, 9000) }
                xntfs_mount_finish(0, 0)
                let result = await call.value
                check(mounted(result) == (cycle % 2 != 0), "repeated current/replaced completion classified")
            }
            await run()
            await until("service released") { service == nil }
            await retired()
        }
    }
    static func benchmark() async {
        let entries = UInt32(CommandLine.arguments[2])!
        let iterations = Int(CommandLine.arguments[3])!
        let devices = UInt32(CommandLine.arguments[4])!
        precondition(devices >= 1 && devices <= 128 && entries >= devices && entries <= 512 && iterations > 0 && iterations <= 5000)
        let ctx = context(devices, entries: entries)
        func run() async -> UInt64 {
            xntfs_observation_set_path(0, 0)
            let call = Task { await ctx.service.unifiedMount(ctx.devices[0], readOnly: false) }
            while xntfs_mount_pending() == 0 { await Task.yield() }
            prepareResult()
            let start = DispatchTime.now().uptimeNanoseconds
            xntfs_mount_finish(0, 0)
            let result = await call.value
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            precondition(mounted(result))
            // Keep history backlog equal across implementations, outside the
            // measured completion stage. This is not end-to-end mount latency.
            _ = await DiagnosticRecorder.shared.snapshot()
            return elapsed
        }
        for _ in 0..<50 { _ = await run() }
        xntfs_observation_reset_counts()
        var samples: [UInt64] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations { samples.append(await run()) }
        let history = await DiagnosticRecorder.shared.snapshot()
        let sum = samples.reduce(UInt64(0), +)
        samples.sort()
        let value: [String: Any] = ["devices": devices, "entries": entries, "iterations": iterations,
            "completion_wall_ns": sum, "median_ns": samples[iterations / 2], "p99_ns": samples[iterations * 99 / 100],
            "mount_queries": xntfs_observation_mount_calls(), "bsd_lookups": xntfs_observation_disk_requests(),
            "copied_table_bytes": xntfs_observation_copied_bytes(), "diagnostic_drops": history.droppedInThisProcess,
            "pending_mounts": xntfs_mount_pending()]
        print(String(decoding: try! JSONSerialization.data(withJSONObject: value, options: .sortedKeys), as: UTF8.self))
    }
    static func main() async {
        setbuf(stdout, nil)
        xntfs_test_begin_query_guard()
        defer { xntfs_test_end_query_guard() }
        if CommandLine.arguments.contains("--benchmark") { await benchmark(); return }
        if CommandLine.arguments.contains("--baseline-probe") {
            for kind in ["registry", "discovery", "missing", "source"] { await replacement(kind, baseline: true); await retired() }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--denial-case") {
            let scenario = CommandLine.arguments[index + 1]
            if scenario == "all" { await allDenials() }
            else { await sandboxDenial(scenario); await retired() }
            print("PASS: \(checks) sandbox denial checks")
            return
        }
        for kind in ["registry", "discovery", "missing", "source"] { await replacement(kind); await retired() }
        await normalAndFailures(); await retired()
        await queryAndDAErrors(); await retired()
        await allDenials()
        await cancellationAndIndependence(); await retired()
        await lifetime()
        check(xntfs_test_query_count() == 0 && xntfs_observation_wrong_flags() == 0, "no per-volume queries")
        #if MOUNT_COMPLETION_PROBE
        print("Callback ownership: \(MountCallbackProbe.shared.snapshot())")
        #endif
        print("PASS: \(checks) mount completion checks; no real FSClient, mount or unmount submissions")
    }
}
