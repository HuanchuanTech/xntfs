import Foundation
import Darwin

// The runner substitutes only the production FSClient query expression and OS
// branch. Test continuations/tasks are finite caller-owned fixtures, not a model
// memory budget or a test of the framework's real transport/installed extension.
@MainActor
enum ExtensionQueryFixture {
    struct Module {
        let bundleIdentifier: String
        let url: URL?
        let isEnabled: Bool
    }
    static var started = 0
    static var peak = 0
    static var immediate = false
    static var replies: [Int: CheckedContinuation<[Module], Error>] = [:]
    static var pauseNextPromotion = false
    static var promotion: CheckedContinuation<Void, Never>?
    static var live: Int { replies.count }
    static let enabled = [Module(bundleIdentifier: ExtensionStatus.bundleID,
        url: URL(fileURLWithPath: "/Applications/xntfs.app/Contents/Extensions/ntfs3g.appex"), isEnabled: true)]

    static var installedExtensions: [Module] {
        get async throws {
            started += 1
            let id = started
            if immediate { return enabled }
            precondition(replies.count < 256, "finite fixture query capacity exceeded")
            return try await withCheckedThrowingContinuation { continuation in
                replies[id] = continuation
                peak = max(peak, live)
            }
        }
    }
    static func reply(_ id: Int, _ modules: [Module] = enabled, error: NSError? = nil) {
        guard let continuation = replies.removeValue(forKey: id) else {
            fatalError("No held query \(id)")
        }
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: modules) }
    }
    static func reset() {
        precondition(replies.isEmpty && promotion == nil, "fixture work still live")
        started = 0; peak = 0; immediate = false; pauseNextPromotion = false
    }
    static func pausePromotion() async {
        guard pauseNextPromotion else { return }
        pauseNextPromotion = false
        await withCheckedContinuation { promotion = $0 }
    }
}

@MainActor
enum Checks {
    static var count = 0
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else {
            print("FAIL: \(message)")
            fflush(stdout)
            exit(1)
        }
        count += 1
    }
    static func until(_ message: String, _ condition: () -> Bool) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !condition() {
            if ProcessInfo.processInfo.systemUptime >= deadline { expect(false, "timeout: \(message)") }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
    static func settle() async {
        // Let all already-created MainActor caller tasks reach their first await.
        // Query replies remain gated, so elapsed time cannot complete work.
        for _ in 0..<20 { await Task.yield() }
    }
}

@main
@MainActor
struct ExtensionRefreshTests {
    static let fixtureRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    static let missingApp = fixtureRoot.appendingPathComponent("missing-app")

    static func bundle(_ name: String) throws -> URL {
        let app = fixtureRoot.appendingPathComponent(name, isDirectory: true)
        let contents = app.appendingPathComponent("Contents/Extensions/ntfs3g.appex/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList:
            ["CFBundleIdentifier": ExtensionStatus.bundleID, "CFBundleExecutable": "fixture"], format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        let executable = contents.appendingPathComponent("MacOS/fixture")
        try Data("fixture, never executed".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return app
    }

    static func baselineProbe() async {
        let status = ExtensionStatus()
        let older = Task { await status.refresh(appURL: missingApp) }
        await Checks.until("first query") { ExtensionQueryFixture.started == 1 }
        let newer = Task { await status.refresh(appURL: missingApp) }
        await Checks.until("overlapping second query") { ExtensionQueryFixture.started == 2 }
        ExtensionQueryFixture.reply(2)
        await newer.value
        Checks.expect(status.state == .enabled, "newer query first shows enabled")
        ExtensionQueryFixture.reply(1, error: NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
        await older.value
        Checks.expect(status.state == .unknown && status.queryError?.code == Int(EIO), "older failure overwrites newer success")
        Checks.expect(ExtensionQueryFixture.peak == 2, "baseline queries overlap")
        print("BASELINE REPRODUCED: newer enabled -> older EIO/unknown; peak queries 2")
        ExtensionQueryFixture.reset()
        let callers = (0..<128).map { _ in Task { await status.refresh(appURL: missingApp) } }
        await Checks.until("baseline burst") { ExtensionQueryFixture.started == 128 }
        Checks.expect(ExtensionQueryFixture.live == 128, "baseline holds every burst query")
        for id in 1...128 { ExtensionQueryFixture.reply(id) }
        for caller in callers { await caller.value }
        print("BASELINE REPRODUCED: 128 callers -> 128 simultaneous queries")
    }

    static func burstAndProgress() async throws {
        ExtensionQueryFixture.reset()
        let a = try bundle("fixture-a"), b = try bundle("fixture-b")
        let status = ExtensionStatus()
        var firstDone = false, burstDone = 0, entered = 0
        let first = Task { await status.refresh(appURL: a); firstDone = true }
        await Checks.until("first query") { ExtensionQueryFixture.started == 1 }
        let callers = (0..<128).map { _ in Task {
            entered += 1
            await status.refresh(appURL: a)
            burstDone += 1
        } }
        await Checks.until("all burst callers entered") { entered == 128 }
        let latest = Task { await status.refresh(appURL: b); burstDone += 1 }
        await Checks.settle()
        Checks.expect(ExtensionQueryFixture.started == 1 && ExtensionQueryFixture.live == 1, "burst holds one active query")
        Checks.expect(!firstDone && burstDone == 0, "no caller returns before its query")
        ExtensionQueryFixture.reply(1)
        await Checks.until("fresh follow-up and first caller completes") { ExtensionQueryFixture.started == 2 && firstDone }
        Checks.expect(burstDone == 0, "pending callers await fresh follow-up, not initial result")
        Checks.expect(status.bundledExtensionURL == ExtensionStatus.embeddedExtension(in: b), "latest pending app URL wins")
        var thirdDone = false
        let third = Task { await status.refresh(appURL: a); thirdDone = true }
        await Checks.settle()
        Checks.expect(ExtensionQueryFixture.started == 2, "next generation waits for active query")
        ExtensionQueryFixture.reply(2, [])
        await Checks.until("third query and earlier waiters complete") { ExtensionQueryFixture.started == 3 && burstDone == 129 }
        Checks.expect(!thirdDone && status.state == .notInstalled, "continuous refresh does not starve older callers")
        ExtensionQueryFixture.reply(3)
        await third.value; await first.value; await latest.value
        for caller in callers { await caller.value }
        Checks.expect(status.state == .enabled && ExtensionQueryFixture.peak == 1 && ExtensionQueryFixture.live == 0,
                      "three ordered queries finish with latest state")
        let history = await DiagnosticRecorder.shared.snapshot()
        let queries = history.events.filter { $0.action == .extensionQuery }
        Checks.expect(queries.count == 3 && queries.map { $0.fields["state"] } == ["enabled", "notInstalled", "enabled"],
                      "one ordered diagnostic event per executed query")
        Checks.expect(history.storage == "process-memory-only" && history.droppedInThisProcess == 0,
                      "diagnostics use memory without drops")
    }

    static func errorsAndClassification() async {
        ExtensionQueryFixture.reset()
        let status = ExtensionStatus()
        let error = NSError(domain: "fixture.query", code: 73, userInfo: [NSLocalizedDescriptionKey: "private path"])
        let failed = Task { await status.refresh(appURL: missingApp) }
        await Checks.until("failed query") { ExtensionQueryFixture.started == 1 }
        ExtensionQueryFixture.reply(1, error: error)
        await failed.value
        Checks.expect(status.state == .unknown && status.queryError?.domain == "fixture.query" && status.queryError?.code == 73,
                      "query error is preserved")
        Checks.expect(status.installedCount == 0 && status.moduleURLs.isEmpty && status.isEnabled == nil,
                      "failure does not expose installed success")
        let failedEvent = await DiagnosticRecorder.shared.snapshot().events.last
        Checks.expect(failedEvent?.phase == .failed && failedEvent?.fields["count"] == "unknown" &&
                      failedEvent?.errors.first?.domain == "fixture.query" && failedEvent?.errors.first?.code == 73,
                      "failed diagnostic has numeric error and unknown count")
        let outputs: [[ExtensionQueryFixture.Module]] = [
            [],
            [.init(bundleIdentifier: "different.module", url: nil, isEnabled: true)],
            [.init(bundleIdentifier: ExtensionStatus.bundleID, url: nil, isEnabled: false)],
            [.init(bundleIdentifier: ExtensionStatus.bundleID, url: nil, isEnabled: false)] + ExtensionQueryFixture.enabled,
            [.init(bundleIdentifier: ExtensionStatus.bundleID, url: URL(fileURLWithPath: "/tmp/Build/Products/copy.appex"), isEnabled: true)],
            ExtensionQueryFixture.enabled
        ]
        for (offset, output) in outputs.enumerated() {
            let call = Task { await status.refresh(appURL: missingApp) }
            await Checks.until("classification query") { ExtensionQueryFixture.started == offset + 2 }
            ExtensionQueryFixture.reply(offset + 2, output)
            await call.value
            Checks.expect(status.queryError == nil, "successful retry clears query error")
            switch offset {
            case 0, 1: Checks.expect(status.state == .notInstalled && !status.isInstalled, "unmatched registration excluded")
            case 2: Checks.expect(status.state == .disabled && status.isInstalled && status.registrationOK == nil, "disabled identity with no URL")
            case 3: Checks.expect(status.state == .enabled && status.isDuplicated && status.installedCount == 2 &&
                                  status.moduleURLs.count == 1 && status.registrationOK == false, "duplicate including unreadable URL retained")
            case 4: Checks.expect(status.registrationOK == false, "build path remains unhealthy")
            default: Checks.expect(status.state == .enabled && status.registrationOK == true, "single Applications identity healthy")
            }
        }
    }

    static func cancellationAndIndependence() async {
        ExtensionQueryFixture.reset()
        let status = ExtensionStatus()
        let cancelled = Task { await status.refresh(appURL: missingApp) }
        cancelled.cancel()
        await cancelled.value
        Checks.expect(ExtensionQueryFixture.started == 0 && status.state == .unknown, "pre-cancelled caller admits no work")
        var activeDone = false, pendingDone = false
        let active = Task { await status.refresh(appURL: missingApp); activeDone = true }
        await Checks.until("active query") { ExtensionQueryFixture.started == 1 }
        let pending = Task { await status.refresh(appURL: missingApp); pendingDone = true }
        await Checks.settle()
        active.cancel(); pending.cancel()
        let peer = Task { await status.refresh(appURL: missingApp) }
        await Checks.settle()
        Checks.expect(ExtensionQueryFixture.started == 1 && !activeDone && !pendingDone, "cancellation retains admitted work")
        let independent = ExtensionStatus()
        let other = Task { await independent.refresh(appURL: missingApp) }
        await Checks.until("independent instance") { ExtensionQueryFixture.started == 2 }
        ExtensionQueryFixture.reply(2)
        await other.value
        Checks.expect(independent.state == .enabled && ExtensionQueryFixture.live == 1, "independent model progresses while first is blocked")
        ExtensionQueryFixture.reply(1, error: NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
        await Checks.until("pending retry after failure") { ExtensionQueryFixture.started == 3 && activeDone }
        Checks.expect(!pendingDone && status.state == .unknown, "failed generation returns before retry completes")
        ExtensionQueryFixture.reply(3)
        await peer.value; await active.value; await pending.value
        Checks.expect(status.state == .enabled && status.queryError == nil && ExtensionQueryFixture.live == 0,
                      "cancelled waiter does not cancel peer's shared follow-up")
    }

    static func retirement() async {
        for _ in 0..<64 {
            ExtensionQueryFixture.reset()
            weak var witness: ExtensionStatus?
            // Keeping only the weak witness after this scope detects a task/self
            // cycle; the held query must keep the model alive before completion.
            func cycle() async {
                let status = ExtensionStatus()
                witness = status
                let first = Task { await status.refresh(appURL: missingApp) }
                await Checks.until("lifetime first query") { ExtensionQueryFixture.started == 1 }
                let second = Task { await status.refresh(appURL: missingApp) }
                await Checks.settle()
                Checks.expect(witness != nil && ExtensionQueryFixture.live == 1, "active model remains owned")
                ExtensionQueryFixture.reply(1)
                await Checks.until("lifetime follow-up") { ExtensionQueryFixture.started == 2 }
                ExtensionQueryFixture.reply(2)
                await first.value; await second.value
            }
            await cycle()
            await Checks.until("model released after completed tasks") { witness == nil }
            Checks.expect(ExtensionQueryFixture.started == 2 && ExtensionQueryFixture.peak == 1 && ExtensionQueryFixture.live == 0,
                          "repeated generations retire all provider work")
        }
    }

    static func promotionGap() async {
        #if EXTENSION_REFRESH_PROBE
        ExtensionQueryFixture.reset()
        ExtensionQueryFixture.pauseNextPromotion = true
        let status = ExtensionStatus()
        let first = Task { await status.refresh(appURL: missingApp) }
        await Checks.until("gap initial") { ExtensionQueryFixture.started == 1 }
        let second = Task { await status.refresh(appURL: missingApp) }
        await Checks.settle()
        ExtensionQueryFixture.reply(1)
        await first.value
        await Checks.until("promotion paused after predecessor completes") { ExtensionQueryFixture.promotion != nil }
        let late = Task { await status.refresh(appURL: missingApp) }
        await Checks.settle()
        Checks.expect(ExtensionQueryFixture.started == 1, "handoff gap does not admit another active query")
        let continuation = ExtensionQueryFixture.promotion
        ExtensionQueryFixture.promotion = nil
        continuation?.resume()
        await Checks.until("promoted query") { ExtensionQueryFixture.started == 2 }
        ExtensionQueryFixture.reply(2)
        await second.value; await late.value
        Checks.expect(ExtensionQueryFixture.started == 2 && ExtensionQueryFixture.live == 0, "gap caller joins existing pending generation")
        #endif
    }

    static func legacy() async throws {
        let app = try bundle("legacy-fixture")
        let status = ExtensionStatus()
        await status.refresh(appURL: app)
        Checks.expect(status.state == .bundled && !status.isInstalled && status.isEnabled == nil && status.registrationOK == nil,
                      "legacy bundle is not proof of enablement")
        await status.refresh(appURL: missingApp)
        Checks.expect(status.state == .notInstalled && status.bundledExtensionURL == nil, "legacy missing bundle")
        Checks.expect(ExtensionQueryFixture.started == 0, "legacy never queries FSClient")
        let history = await DiagnosticRecorder.shared.snapshot()
        Checks.expect(history.events.count == 2 && history.events.allSatisfy { $0.fields["count"] == "unknown" },
                      "legacy diagnostic count remains unknown")
    }

    static func benchmark() async throws {
        ExtensionQueryFixture.reset()
        ExtensionQueryFixture.immediate = true
        let app = try bundle("benchmark-fixture")
        let status = ExtensionStatus()
        for _ in 0..<100 { await status.refresh(appURL: app) }
        _ = await DiagnosticRecorder.shared.snapshot()
        var durations: [UInt64] = []
        durations.reserveCapacity(2000)
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<2000 {
            let before = DispatchTime.now().uptimeNanoseconds
            await status.refresh(appURL: app)
            durations.append(DispatchTime.now().uptimeNanoseconds - before)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let history = await DiagnosticRecorder.shared.snapshot()
        durations.sort()
        let result: [String: Any] = ["case": "sequential-immediate-query", "iterations": durations.count,
            "wall_ns": elapsed, "median_ns": durations[durations.count / 2],
            "p99_ns": durations[durations.count * 99 / 100], "queries": ExtensionQueryFixture.started,
            "diagnostic_drops": history.droppedInThisProcess, "state": String(describing: status.state)]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: .sortedKeys), as: UTF8.self))
    }

    static func burstCounts() async throws {
        ExtensionQueryFixture.reset()
        let status = ExtensionStatus()
        var entered = 0, completed = 0
        let first = Task { await status.refresh(appURL: missingApp); completed += 1 }
        await Checks.until("count initial query") { ExtensionQueryFixture.started == 1 }
        let callers = (0..<127).map { _ in Task {
            entered += 1
            await status.refresh(appURL: missingApp)
            completed += 1
        } }
        await Checks.until("count burst admitted") { entered == 127 }
        await Checks.settle()
        let held = ExtensionQueryFixture.live
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while completed < 128 {
            Checks.expect(ProcessInfo.processInfo.systemUptime < deadline, "count burst completes")
            for id in ExtensionQueryFixture.replies.keys.sorted() { ExtensionQueryFixture.reply(id) }
            await Checks.settle()
        }
        await first.value
        for caller in callers { await caller.value }
        Checks.expect(status.state == .enabled && ExtensionQueryFixture.live == 0, "count burst leaves no provider work")
        let result: [String: Any] = ["case": "128-call-held-burst", "callers": 128, "completed": completed,
            "held_queries": held, "queries": ExtensionQueryFixture.started, "peak_queries": ExtensionQueryFixture.peak,
            "live_queries": ExtensionQueryFixture.live]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: .sortedKeys), as: UTF8.self))
    }

    static func main() async throws {
        if CommandLine.arguments.contains("--benchmark") { try await benchmark(); return }
        if CommandLine.arguments.contains("--burst-counts") { try await burstCounts(); return }
        if CommandLine.arguments.contains("--baseline-probe") { await baselineProbe(); return }
        if ExtensionStatus.needsLegacyCompatibility { try await legacy() }
        else {
            try await burstAndProgress()
            await errorsAndClassification()
            await cancellationAndIndependence()
            await retirement()
            await promotionGap()
        }
        print("PASS: \(Checks.count) extension refresh checks; provider live \(ExtensionQueryFixture.live)")
    }
}
