import Foundation
import Darwin

@main
@MainActor
struct ImagePreflightBenchmark {
    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private static func cpu() -> UInt64 {
        var usage = rusage(); precondition(getrusage(RUSAGE_SELF, &usage) == 0)
        return UInt64(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000_000_000 +
            UInt64(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) * 1000
    }
    private static func operation(_ source: URL) async throws {
        #if NFSK_BASELINE
        // The old real validator blocks MainActor. This measures that component,
        // not baseline FSClient latency or a complete old mounting workflow.
        try ImageMountService.validateImage(source)
        #else
        guard #available(macOS 27.0, *) else { preconditionFailure("Requires macOS 27") }
        var images: [MountedImage] = []
        let point = URL(fileURLWithPath: "/Volumes/Unused-Preflight-Benchmark", isDirectory: true)
        let client = ImageMountClient(images: { images }, enabled: { true }, submit: { url, readOnly in
            images = [MountedImage(mountPoint: point, source: url, readOnly: readOnly, sizeBytes: 512, fileSystemID: [99, 2])]
            return point
        })
        let access = ImageMountFileAccess(start: { _ in false }, stop: { _ in preconditionFailure("No scope was granted") }, scopedURL: { source, _ in source })
        let result = try await ImageMountService.mount(source, readOnly: true, client: client, fileAccess: access)
        precondition(result == point)
        #endif
    }
    private static func run(_ source: URL, delay: UInt32, iterations: Int) async throws {
        var gaps: [UInt64] = [], latencies: [UInt64] = []
        let heartbeat = Task { @MainActor in
            var previous = now()
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000) } catch { break }
                let time = now(); gaps.append(time - previous); previous = time
            }
        }
        defer { heartbeat.cancel() }
        try await Task.sleep(nanoseconds: 3_000_000)
        var elapsedCPU: UInt64 = 0, totalReads: UInt64 = 0, totalBytes: UInt64 = 0, totalCloses: UInt64 = 0, mainReads: UInt64 = 0
        for _ in 0..<iterations {
            precondition(source.path.withCString { image_gate_arm($0, 0, delay, 0) } == 0)
            let start = now(), beforeCPU = cpu()
            try await operation(source)
            elapsedCPU += cpu() - beforeCPU; latencies.append(now() - start)
            precondition(image_gate_reads() == 1 && image_gate_requested_bytes() == 512 && image_gate_closes() == 1)
            #if NFSK_BASELINE
            precondition(image_gate_main_reads() == 1)
            #else
            precondition(image_gate_main_reads() == 0)
            #endif
            totalReads += UInt64(image_gate_reads()); totalBytes += image_gate_requested_bytes()
            totalCloses += UInt64(image_gate_closes()); mainReads += UInt64(image_gate_main_reads())
            image_gate_clear()
            // Let a heartbeat observe each blocked interval, including the last.
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        heartbeat.cancel(); await heartbeat.value
        precondition(!gaps.isEmpty)
        var usage = rusage(); precondition(getrusage(RUSAGE_SELF, &usage) == 0)
        let row: [String: Any] = ["workload": delay == 0 ? "fast" : "delayed", "operations": iterations,
            "injected_read_delay_ms": delay, "samples_ns": latencies, "heartbeat_gaps_ns": gaps,
            "heartbeat_max_ns": gaps.max()!, "wall_ns": latencies.reduce(0, +), "cpu_ns": elapsedCPU,
            "read_calls": totalReads, "read_bytes": totalBytes, "close_calls": totalCloses,
            "main_thread_reads": mainReads, "rss_bytes": usage.ru_maxrss]
        print(String(data: try JSONSerialization.data(withJSONObject: row, options: .sortedKeys), encoding: .utf8)!)
    }
    static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let source = folder.appendingPathComponent("header.ntfs", isDirectory: false)
        var boot = Data(repeating: 0, count: 512)
        boot.replaceSubrange(3..<11, with: Data("NTFS    ".utf8)); boot[510] = 0x55; boot[511] = 0xaa
        try boot.write(to: source)
        defer { image_gate_clear(); try? FileManager.default.removeItem(at: source) }
        for _ in 0..<20 { try await operation(source) }
        try await run(source, delay: 0, iterations: 100)
        try await run(source, delay: 150, iterations: 3)
        fputs("PASS: actual header reads and close counts; stub clients; no OS mounts\n", stderr)
    }
}
