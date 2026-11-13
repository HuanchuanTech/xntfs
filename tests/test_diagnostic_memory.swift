import Foundation
import Darwin

@main
struct DiagnosticMemoryTests {
    private static var passed = 0
    private static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message); passed += 1; print("PASS: \(message)")
    }
    private static func wait(_ predicate: () -> Bool) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while !predicate() {
            precondition(DispatchTime.now().uptimeNanoseconds < deadline, "Gate or lifetime did not complete")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    private static func event(_ index: Int = 0) -> DiagnosticEvent {
        DiagnosticEvent(action: .probe, phase: .observed, fields: [.count: String(index)], process: UUID(), component: "app")
    }
    private static func file(_ root: URL, _ name: String, data: Data) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("history.json", isDirectory: false))
        return folder
    }

    private static func fields() async throws {
        let huge = String(repeating: "1", count: 1024 * 1024)
        let error = NSError(domain: huge, code: Int.min)
        let recorder = DiagnosticRecorder(directory: nil, component: huge)
        recorder.record(.probe, .failed, fields: [.device: "disk" + huge, .source: String(repeating: "é", count: 32),
            .kind: String(repeating: "A", count: 64), .reason: "ok\n"], error: error)
        let history = await recorder.snapshot(), value = history.events[0]
        check(value.fields["device"] == "omitted" && value.fields["source"] == "omitted" && value.fields["reason"] == "omitted",
              "oversized device, non-ASCII and trailing newline are omitted before retention")
        check(value.component == "other" && value.errors[0].domain == "other" && value.fields["kind"]?.utf8.count == 64,
              "oversized component/error domain are bounded while valid fields survive")
        let encodedSize = try JSONEncoder().encode(value).count
        check(value.payloadBytes <= DiagnosticEvent.maximumPayloadBytes && encodedSize < 2048,
              "one-megabyte synthetic input no longer produces a one-megabyte retained event")

        let domain = String(repeating: "D", count: 128)
        let third = NSError(domain: domain, code: 3)
        let second = NSError(domain: domain, code: 2, userInfo: [NSUnderlyingErrorKey: third])
        let first = NSError(domain: domain, code: 1, userInfo: [NSUnderlyingErrorKey: second])
        var values = Dictionary(uniqueKeysWithValues: DiagnosticEvent.Field.allCases.map { ($0, String(repeating: "A", count: 64)) })
        values[.device] = "rdisk" + String(repeating: "1", count: 59)
        let full = DiagnosticEvent(action: .mount, phase: .failed, fields: values, error: first, process: UUID(),
                                   component: String(repeating: "C", count: 64))
        let reopened = try JSONDecoder().decode(DiagnosticEvent.self, from: JSONEncoder().encode(full))
        check(full.payloadBytes <= 2048 && reopened.fields == full.fields && reopened.errors.map(\.code) == [1, 2, 3],
              "maximum valid field set and three full error domains round-trip within the event payload quota")
        let tooLong = DiagnosticEvent(action: .probe, phase: .observed,
                                     fields: [.device: "disk" + String(repeating: "1", count: 61)], process: UUID(), component: "app")
        check(tooLong.fields["device"] == "omitted" && DiagnosticError(NSError(domain: domain + "D", code: 0)).domain == "other",
              "65-byte devices and 129-byte error domains cross the precise rejection boundary")
    }

    private static func storedHistory(_ root: URL) async throws {
        let valid = (0..<400).map(event)
        let path = try file(root, "valid", data: JSONEncoder().encode(valid))
        let history = await DiagnosticRecorder(directory: path, component: "app").snapshot()
        check(history.events.count == 400 && history.warning == nil && Set(history.events.map(\.id)) == Set(valid.map(\.id)),
              "existing valid 400-event JSON history remains compatible")
        let excess = try file(root, "excess-count", data: JSONEncoder().encode(valid + [event(400)]))
        let rejected = await DiagnosticRecorder(directory: excess, component: "app").snapshot()
        check(rejected.events.isEmpty && rejected.warning == "invalid-history-replaced",
              "401-event history is rejected rather than fully restored then pruned")

        let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event())) as! [String: Any]
        let error: [String: Any] = ["domain": "NSPOSIXErrorDomain", "code": 5, "hex": "0x00000005"]
        var cases: [(String, [String: Any])] = []
        for key in ["component", "version", "build"] {
            var bad = base; bad[key] = String(repeating: "A", count: 65); cases.append((key, bad))
        }
        var bad = base; bad["fields"] = ["device": "disk" + String(repeating: "1", count: 300_000)]; cases.append(("large-device", bad))
        bad = base; bad["fields"] = ["path": "/private/secret"]; cases.append(("unknown-field", bad))
        bad = base; bad["fields"] = Dictionary(uniqueKeysWithValues: (0..<12).map { ("key\($0)", "A") }); cases.append(("many-fields", bad))
        bad = base; bad["fields"] = ["count": 42]; cases.append(("field-type", bad))
        bad = base; bad["fields"] = ["device": "disk1\n"]; cases.append(("newline", bad))
        bad = base; bad["errors"] = Array(repeating: error, count: 4); cases.append(("error-count", bad))
        var badError = error; badError["domain"] = String(repeating: "D", count: 129)
        bad = base; bad["errors"] = [badError]; cases.append(("error-domain", bad))
        badError = error; badError["hex"] = "0x00000000"
        bad = base; bad["errors"] = [badError]; cases.append(("error-code", bad))
        for (name, object) in cases {
            let folder = try file(root, name, data: JSONSerialization.data(withJSONObject: [object]))
            let value = await DiagnosticRecorder(directory: folder, component: "app").snapshot()
            check(value.events.isEmpty && value.warning == "invalid-history-replaced", "unsafe stored schema is explicitly replaced: \(name)")
        }
    }

    private static func boundedRead(_ root: URL) async throws {
        DiagnosticProbe.reset()
        let excess = try file(root, "oversize-file", data: Data(repeating: 32, count: DiagnosticRecorder.maximumBytes + 1))
        let rejected = await DiagnosticRecorder(directory: excess, component: "app").snapshot()
        check(rejected.warning == "NSPOSIXErrorDomain:\(EFBIG)" && DiagnosticProbe.counts.maximumReadBytes == 0,
              "oversized ordinary file is refused before allocating a read buffer")

        let fifo = root.appendingPathComponent("fifo", isDirectory: true)
        try FileManager.default.createDirectory(at: fifo, withIntermediateDirectories: true)
        precondition(mkfifo(fifo.appendingPathComponent("history.json", isDirectory: false).path, 0o600) == 0)
        let rejectedFIFO = await DiagnosticRecorder(directory: fifo, component: "app").snapshot()
        check(rejectedFIFO.warning == "NSPOSIXErrorDomain:\(EFBIG)", "nonregular history cannot block on a FIFO read")

        let targetData = try JSONEncoder().encode([event()])
        let target = try file(root, "target", data: targetData).appendingPathComponent("history.json", isDirectory: false)
        let linkFolder = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: linkFolder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkFolder.appendingPathComponent("history.json", isDirectory: false), withDestinationURL: target)
        let linked = await DiagnosticRecorder(directory: linkFolder, component: "app").snapshot()
        let remainingTarget = try Data(contentsOf: target)
        check(linked.warning != nil && linked.events.isEmpty && remainingTarget == targetData,
              "history symlinks are refused without reading or rewriting their target")

        let growing = try file(root, "growing", data: Data("[]".utf8))
        DiagnosticProbe.reset(blockRead: true)
        let snapshot = Task { await DiagnosticRecorder(directory: growing, component: "app").snapshot() }
        try await wait { DiagnosticProbe.hasEnteredRead }
        let writer = try FileHandle(forWritingTo: growing.appendingPathComponent("history.json", isDirectory: false))
        try writer.seekToEnd()
        try writer.write(contentsOf: Data(repeating: 32, count: DiagnosticRecorder.maximumBytes + 10))
        try writer.close()
        DiagnosticProbe.release()
        let changed = await snapshot.value
        check(changed.warning == "NSPOSIXErrorDomain:\(EFBIG)" &&
              DiagnosticProbe.counts.maximumReadBytes == DiagnosticRecorder.maximumBytes + 1,
              "file growth after fstat reads only the limit plus one detection byte")
    }

    private static func snapshotAdmission(_ root: URL) async throws {
        DiagnosticProbe.reset(blockStore: 1)
        let recorder = DiagnosticRecorder(directory: root, component: "app")
        recorder.record(.probe, .observed, fields: [.count: "before"])
        try await wait { DiagnosticProbe.entered }
        var admitted: [Task<DiagnosticHistory, Never>] = []
        for count in 1...DiagnosticRecorder.maximumSnapshots {
            admitted.append(Task { await recorder.snapshot() })
            try await wait { DiagnosticProbe.counts.currentSnapshots == count }
        }
        admitted[0].cancel()
        let rejected = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    let value = await recorder.snapshot()
                    return value.events.isEmpty && value.warning == "snapshot-capacity-exceeded" && value.droppedInThisProcess == 0
                }
            }
            var count = 0
            for await rejected in group { if rejected { count += 1 } }
            return count
        }
        check(rejected == 64 && DiagnosticProbe.counts.maximumSnapshots == 4 && DiagnosticProbe.counts.currentSnapshots == 4,
              "snapshot flood is immediately explicit and bounded even when an admitted snapshot is cancelled")
        recorder.record(.probe, .observed, fields: [.count: "after"])
        DiagnosticProbe.release()
        var correct = true
        for task in admitted {
            let value = await task.value
            correct = correct && value.events.compactMap { $0.fields["count"] } == ["before"] && value.warning == nil
        }
        check(correct && DiagnosticProbe.counts.currentSnapshots == 0, "admitted snapshots retain their earlier boundary and release every slot")
        let next = await recorder.snapshot()
        check(Set(next.events.compactMap { $0.fields["count"] }) == ["before", "after"] && next.warning == nil,
              "capacity rejection neither clears history nor poisons later snapshots")
    }

    private final class WeakRecorder {
        weak var value: DiagnosticRecorder?
        init(_ value: DiagnosticRecorder) { self.value = value }
    }
    private static func usage() -> [String: UInt64] {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        precondition(result == KERN_SUCCESS)
        return ["resident_bytes": info.resident_size, "physical_footprint_bytes": info.phys_footprint]
    }
    private static func cycles(instances: Int) async throws -> [WeakRecorder] {
        let recorders = (0..<instances).map { _ in DiagnosticRecorder(directory: nil, component: "app") }
        let weak = recorders.map(WeakRecorder.init)
        var fields = Dictionary(uniqueKeysWithValues: DiagnosticEvent.Field.allCases.map { ($0, String(repeating: "A", count: 64)) })
        fields[.device] = "rdisk1s1"
        var samples: [[String: Any]] = []
        for cycle in 0..<100 {
            var totalPayload = 0
            for recorder in recorders {
                for index in 0..<32 {
                    fields[.count] = String(cycle * 32 + index)
                    recorder.record(.probe, .observed, fields: fields)
                }
                let value = await recorder.snapshot()
                precondition(value.events.count == min(400, (cycle + 1) * 32) && value.droppedInThisProcess == 0)
                let payload = value.events.reduce(0) { $0 + $1.payloadBytes }
                precondition(payload <= DiagnosticRecorder.maximumHistoryPayloadBytes)
                totalPayload += payload
            }
            if [0, 19, 49, 99].contains(cycle) {
                samples.append(["cycle": cycle + 1, "retained_event_payload_bytes": totalPayload, "process": usage()])
            }
        }
        let row: [String: Any] = ["instances": instances, "cycles": 100, "samples": samples,
                                  "scope": "Process observation includes allocator/runtime; payload is not total heap or RSS"]
        print(String(decoding: try JSONSerialization.data(withJSONObject: row, options: .sortedKeys), as: UTF8.self))
        return weak
    }
    private static func lifetime() async throws {
        for instances in [1, 8] {
            let weak = try await cycles(instances: instances)
            try await wait { weak.allSatisfy { $0.value == nil } }
            check(weak.allSatisfy { $0.value == nil }, "\(instances)-recorder, 100-cycle workload stays within payload bounds and releases every recorder")
            print("after_release_\(instances): \(usage())")
        }
    }

    static func main() async throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { _exit(124) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { DiagnosticProbe.release(); try? FileManager.default.removeItem(at: root) }
        if !CommandLine.arguments.contains("--measure-only") {
            try await fields()
            try await storedHistory(root)
            try await boundedRead(root)
            try await snapshotAdmission(root.appendingPathComponent("admission", isDirectory: true))
        }
        try await lifetime()
        print("\(passed) diagnostic memory checks passed; synthetic stores only, no device or external requests")
    }
}
