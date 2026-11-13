import Foundation
import Darwin

@main
struct DiagnosticBatchTests {
    private static var passed = 0
    private static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message); passed += 1; print("PASS: \(message)")
    }
    private static func wait(_ predicate: () -> Bool) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while !predicate() {
            precondition(DispatchTime.now().uptimeNanoseconds < deadline, "Gate or snapshot did not start")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    private static func values(_ history: DiagnosticHistory) -> Set<String> { Set(history.events.compactMap { $0.fields["count"] }) }
    private static func add(_ recorder: DiagnosticRecorder, _ value: String) {
        recorder.record(.probe, .observed, fields: [.count: value])
    }
    private static func boundary(_ root: URL) async throws {
        let recorder = DiagnosticRecorder(directory: root, component: "app")
        DiagnosticProbe.reset(blockStore: 1)
        add(recorder, "first")
        try await wait { DiagnosticProbe.entered }
        add(recorder, "before1"); add(recorder, "before2")
        let snapshot = Task { await recorder.snapshot() }
        try await wait { DiagnosticProbe.counts.snapshots == 1 }
        snapshot.cancel() // snapshot is nonthrowing and still owns its continuation.
        add(recorder, "after1"); add(recorder, "after2")
        DiagnosticProbe.release()
        let earlier = await snapshot.value
        check(values(earlier) == ["first", "before1", "before2"], "snapshot includes completed prior records and excludes records appended after its enqueue, even when cancelled")
        let later = await recorder.snapshot()
        check(values(later) == ["first", "before1", "before2", "after1", "after2"] && later.warning == nil,
              "later records survive the snapshot boundary and complete normally")
        check(DiagnosticProbe.counts.writes <= 7, "bounded stores complete without a self-enqueue loop")
    }
    private static func capacity(_ root: URL) async throws {
        let recorder = DiagnosticRecorder(directory: root, component: "app")
        DiagnosticProbe.reset(blockStore: 1)
        add(recorder, "first")
        try await wait { DiagnosticProbe.entered }
        DispatchQueue.concurrentPerform(iterations: 8) { producer in
            for index in 0..<32 { recorder.record(.load, .observed, fields: [.count: "\(producer)-\(index)"]) }
        }
        let snapshot = Task { await recorder.snapshot() }
        try await wait { DiagnosticProbe.counts.snapshots == 1 }
        check(DiagnosticProbe.counts.maximumPending == 64, "64-event capacity includes both the active write and concurrent queued records")
        DiagnosticProbe.release()
        let history = await snapshot.value
        check(history.events.count == 64 && history.droppedInThisProcess == 193 && Set(history.events.map(\.id)).count == 64,
              "257 attempts retain exactly 64 unique events and report 193 omissions under a paused store")
        add(recorder, "retry")
        let retried = await recorder.snapshot()
        check(values(retried).contains("retry") && retried.events.count == 65 && retried.droppedInThisProcess == 193,
              "completion releases all admission slots without clearing prior drop evidence")
        let disk = await DiagnosticRecorder(directory: root, component: "extension").snapshot()
        check(Set(disk.events.map(\.id)) == Set(retried.events.map(\.id)), "fresh recorder reads every successfully persisted accepted event")
    }
    private static func failures(_ root: URL, error: Int32) async throws {
        let recorder = DiagnosticRecorder(directory: root, component: "app")
        DiagnosticProbe.reset(blockStore: 1)
        add(recorder, "0")
        try await wait { DiagnosticProbe.entered }
        for index in 1..<32 { add(recorder, String(index)) }
        DiagnosticProbe.failWrites(error); DiagnosticProbe.release()
        let failed = await recorder.snapshot()
        check(failed.events.count == 32 && failed.warning == "NSPOSIXErrorDomain:\(error)" && failed.droppedInThisProcess == 0,
              "failed batch writes retain all 32 events in memory with the original errno warning (\(error))")
        let fresh = await DiagnosticRecorder(directory: root, component: "extension").snapshot()
        check(fresh.events.isEmpty, "failed write is not reported as persisted data (\(error))")
        DiagnosticProbe.failWrites(0)
        add(recorder, "recovered")
        let recovered = await recorder.snapshot()
        let disk = await DiagnosticRecorder(directory: root, component: "extension").snapshot()
        check(recovered.events.count == 33 && Set(disk.events.map(\.id)) == Set(recovered.events.map(\.id)),
              "next successful record persists retained events and frees capacity after error (\(error))")
        check(recovered.warning == failed.warning, "recovery preserves the existing historical warning semantics (\(error))")
    }
    private static func contention(_ root: URL) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = open(root.appendingPathComponent("history.lock", isDirectory: false).path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        precondition(fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0)
        defer { flock(fd, LOCK_UN); close(fd) }
        DiagnosticProbe.reset()
        let recorder = DiagnosticRecorder(directory: root, component: "app")
        let start = DispatchTime.now().uptimeNanoseconds
        for index in 0..<16 { add(recorder, String(index)) }
        let history = await recorder.snapshot()
        check(history.events.count == 16 && history.warning == "NSPOSIXErrorDomain:\(EBUSY)" &&
              DispatchTime.now().uptimeNanoseconds - start < 2_000_000_000,
              "real flock contention is bounded and preserves accepted memory evidence")
        precondition(flock(fd, LOCK_UN) == 0)
        add(recorder, "recovered")
        _ = await recorder.snapshot()
        let disk = await DiagnosticRecorder(directory: root, component: "extension").snapshot()
        check(disk.events.count == 17, "history merges correctly after the conflicting lock is released")
    }
    private static func memory() async {
        DiagnosticProbe.reset()
        let recorder = DiagnosticRecorder(directory: nil, component: "app")
        for group in 0..<15 {
            for index in 0..<32 { add(recorder, String(group * 32 + index)) }
            _ = await recorder.snapshot()
        }
        let history = await recorder.snapshot()
        check(values(history) == Set((80..<480).map(String.init)) && history.storage == "process-memory-only" &&
              history.warning != nil && history.droppedInThisProcess == 0 && DiagnosticProbe.counts.writes == 0,
              "memory-only recording preserves newest 400 events and warns without any file writes")
    }
    private static func limits(_ root: URL) async throws {
        DiagnosticProbe.reset()
        let recorder = DiagnosticRecorder(directory: root, component: "app")
        let fields: [DiagnosticEvent.Field] = [.kind, .requestedReadOnly, .effectiveReadOnly, .mediaWritable, .driver, .state, .source, .reason, .attempt]
        let domain = String(repeating: "D", count: 128)
        let third = NSError(domain: domain, code: Int.max, userInfo: [NSLocalizedDescriptionKey: "/private/secret"])
        let second = NSError(domain: domain, code: Int.max, userInfo: [NSUnderlyingErrorKey: third])
        let error = NSError(domain: domain, code: Int.max, userInfo: [NSUnderlyingErrorKey: second])
        for group in 0..<25 {
            for index in 0..<16 {
                var values = Dictionary(uniqueKeysWithValues: fields.map { ($0, String(repeating: "A", count: 64)) })
                values[.count] = String(group * 16 + index); values[.device] = "disk99s1"
                recorder.record(.mount, .failed, fields: values, error: error)
            }
            _ = await recorder.snapshot()
        }
        let history = await recorder.snapshot()
        let file = root.appendingPathComponent("history.json", isDirectory: false)
        let data = try Data(contentsOf: file), persisted = try JSONDecoder().decode([DiagnosticEvent].self, from: data)
        check(data.count <= DiagnosticRecorder.maximumBytes && !persisted.isEmpty && persisted.count < 400 && history.events.count == 400,
              "large valid events exercise the disk byte cap while retaining bounded local history")
        check(!String(decoding: data, as: UTF8.self).contains("secret") && persisted.allSatisfy { $0.errors.count == 3 },
              "batching preserves sanitized fields and bounded numeric error chains")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "atomic history remains owner-readable only")
        let expired = DiagnosticEvent(action: .probe, phase: .observed, process: UUID(), component: "app",
                                      time: Date().addingTimeInterval(-8 * 86400))
        let old = root.appendingPathComponent("expired", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try JSONEncoder().encode([expired]).write(to: old.appendingPathComponent("history.json", isDirectory: false))
        let oldRecorder = DiagnosticRecorder(directory: old, component: "app")
        for index in 0..<8 { add(oldRecorder, String(index)) }
        let kept = await oldRecorder.snapshot()
        check(kept.events.count == 8 && !kept.events.contains { $0.id == expired.id }, "expired events cannot return through a batched merge")
    }
    private static func writers(_ root: URL) async throws {
        let children = try (0..<3).map { _ -> Process in
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0], isDirectory: false)
            child.arguments = ["--writer", root.path]
            try child.run(); return child
        }
        for child in children { child.waitUntilExit() }
        check(children.allSatisfy { $0.terminationStatus == 0 }, "three independent batched writer processes complete normally")
        let history = await DiagnosticRecorder(directory: root, component: "reader").snapshot()
        let original = history.events.filter { $0.fields["count"]?.hasPrefix("item-") == true }
        check(original.count == 192 && Set(original.map(\.process)).count == 3 && Set(original.map(\.id)).count == 192 &&
              history.events.count <= 216 && history.warning == nil,
              "cross-process merge retains all 192 events without duplicates or overwrite")
    }
    static func main() async throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { _exit(124) }
        let args = CommandLine.arguments
        if args[1] == "--writer" {
            let directory = URL(fileURLWithPath: args[2], isDirectory: true)
            let recorder = DiagnosticRecorder(directory: directory, component: "writer")
            let expected = Set((0..<64).map { "item-\(getpid())-\($0)" })
            func validate(_ snapshot: DiagnosticHistory) {
                // A bounded lock attempt may legitimately lose to another writer,
                // particularly under TSan. Warnings are sticky; assert retained
                // ownership and actual eventual disk contents instead of nil.
                precondition(snapshot.droppedInThisProcess == 0 &&
                             (snapshot.warning == nil || snapshot.warning == "NSPOSIXErrorDomain:\(EBUSY)"),
                             "Unexpected writer error: \(snapshot.warning ?? "none")")
            }
            for group in 0..<8 {
                for index in 0..<8 { add(recorder, "item-\(getpid())-\(group * 8 + index)") }
                let snapshot = await recorder.snapshot()
                validate(snapshot)
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            for attempt in 0...8 {
                let saved = try JSONDecoder().decode([DiagnosticEvent].self,
                    from: Data(contentsOf: directory.appendingPathComponent("history.json")))
                if expected.isSubset(of: Set(saved.compactMap { $0.fields["count"] })) { return }
                precondition(attempt < 8, "Accepted writer events did not reach disk after bounded recovery")
                try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 5_000_000)
                add(recorder, "retry-\(getpid())-\(attempt)")
                validate(await recorder.snapshot())
            }
            preconditionFailure("Unreachable writer recovery exit")
        }
        let root = URL(fileURLWithPath: args[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { DiagnosticProbe.release(); try? FileManager.default.removeItem(at: root) }
        try await boundary(root.appendingPathComponent("boundary", isDirectory: true))
        try await capacity(root.appendingPathComponent("capacity", isDirectory: true))
        for code in [EIO, ENOSPC] { try await failures(root.appendingPathComponent("error-\(code)", isDirectory: true), error: code) }
        try await contention(root.appendingPathComponent("contention", isDirectory: true))
        await memory()
        try await limits(root.appendingPathComponent("limits", isDirectory: true))
        try await writers(root.appendingPathComponent("writers", isDirectory: true))
        print("\(passed) diagnostic checks passed; temporary stores only, no App Group or external requests")
    }
}
