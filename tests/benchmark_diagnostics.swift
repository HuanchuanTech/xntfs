import Foundation
import Darwin

@main
struct DiagnosticBenchmark {
    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private static func cpu() -> UInt64 {
        var usage = rusage(); precondition(getrusage(RUSAGE_SELF, &usage) == 0)
        return UInt64(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000_000_000 +
            UInt64(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) * 1000
    }
    private static func verify(_ history: DiagnosticHistory, count: Int) {
        let expected = Set((max(0, count - DiagnosticRecorder.maximumEvents)..<count).map(String.init))
        let measured = history.events.filter { $0.fields["source"] == "measure" }
        precondition(Set(measured.compactMap { $0.fields["count"] }) == expected)
        precondition(Set(history.events.map(\.id)).count == history.events.count && history.droppedInThisProcess == 0)
    }
    private static func run(root: URL, size: Int, groups: Int, memory: Bool = false) async throws {
        let folder = root.appendingPathComponent(memory ? "memory" : "batch-\(size)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        if !memory {
            let base = Date().addingTimeInterval(-1), process = UUID()
            let events = (0..<DiagnosticRecorder.maximumEvents).map { index in
                DiagnosticEvent(action: .probe, phase: .observed, fields: [.source: "seed", .count: String(index)],
                                process: process, component: "app", time: base.addingTimeInterval(Double(index) / 10000))
            }
            try JSONEncoder().encode(events).write(to: folder.appendingPathComponent("history.json", isDirectory: false))
        }
        let recorder = DiagnosticRecorder(directory: memory ? nil : folder, component: "app")
        _ = await recorder.snapshot()
        DiagnosticProbe.reset()
        var samples: [UInt64] = [], callerSamples: [UInt64] = []
        var history: DiagnosticHistory?
        let startCPU = cpu(), start = now()
        for group in 0..<groups {
            let groupStart = now()
            for index in 0..<size {
                let callStart = now()
                recorder.record(.probe, .observed, fields: [.source: "measure", .count: String(group * size + index)])
                callerSamples.append(now() - callStart)
            }
            history = await recorder.snapshot()
            samples.append(now() - groupStart)
            verify(history!, count: (group + 1) * size)
        }
        let elapsed = now() - start, usedCPU = cpu() - startCPU, counts = DiagnosticProbe.counts
        if !memory {
            precondition(history?.warning == nil)
            let fresh = await DiagnosticRecorder(directory: folder, component: "extension").snapshot()
            verify(fresh, count: groups * size)
            let file = folder.appendingPathComponent("history.json", isDirectory: false)
            let data = try Data(contentsOf: file)
            precondition(data.count <= DiagnosticRecorder.maximumBytes)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        } else { precondition(history?.storage == "process-memory-only" && history?.warning != nil) }
        var usage = rusage(); precondition(getrusage(RUSAGE_SELF, &usage) == 0)
        let ordered = samples.sorted(), orderedCaller = callerSamples.sorted()
        let row: [String: Any] = ["workload": memory ? "memory32" : "disk\(size)", "groups": groups,
            "operations": size * groups, "wall_ns": elapsed, "cpu_ns": usedCPU, "rss_bytes": usage.ru_maxrss,
            "p95_group_ns": ordered[(groups * 95 + 99) / 100 - 1],
            "p95_caller_ns": orderedCaller[(callerSamples.count * 95 + 99) / 100 - 1],
            "samples_ns": samples, "caller_samples_ns": callerSamples,
            "stores": counts.stores, "writes": counts.writes, "bytes": counts.bytes, "maximum_pending": counts.maximumPending]
        print(String(data: try JSONSerialization.data(withJSONObject: row, options: .sortedKeys), encoding: .utf8)!)
    }
    static func main() async throws {
        let args = CommandLine.arguments
        precondition(args.count == 3)
        let root = URL(fileURLWithPath: args[1], isDirectory: true), groups = Int(args[2])!
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for size in [1, 8, 32] { try await run(root: root, size: size, groups: groups) }
        try await run(root: root, size: 32, groups: groups, memory: true)
        fputs("PASS: exact accepted events, bounded history, reopen, permissions and memory fallback\n", stderr)
    }
}
