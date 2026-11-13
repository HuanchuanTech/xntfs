import Foundation
import FSKit

// The runner injects calls to this recorder only into diagnostic source copies.
// Uninstrumented A/B builds do not execute it or redirect production C functions.
enum VolumeTrace {
    @TaskLocal static var requestID = -1
    private static let lock = NSLock()
    private static var records: [Int: [UInt64]] = [:]
    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    static func record(_ id: Int, _ enqueued: UInt64, _ started: UInt64, _ body: UInt64, _ finished: UInt64) {
        guard id >= 0 else { return }
        lock.lock()
        var r = records[id] ?? [enqueued, 0, 0, 0]
        r[1] += started - enqueued; r[2] += body - started; r[3] += finished - body
        records[id] = r
        lock.unlock()
    }
    static func take(_ id: Int, start: UInt64, end: UInt64) -> [UInt64] {
        lock.lock(); let record = records.removeValue(forKey: id); lock.unlock()
        guard let r = record else { return [] }
        let entry = r[0] - start
        return [entry, r[1], r[2], r[3], end - start - entry - r[1] - r[2] - r[3]]
    }
}

private struct VolumeSample {
    let latency: UInt64
    let trace: [UInt64]
}

@main
struct VolumeBenchmark {
    static let directorySuite = ProcessInfo.processInfo.environment["NFSK_BENCH_SUITE"] == "directory"
    static let lookupSuite = ProcessInfo.processInfo.environment["NFSK_BENCH_SUITE"] == "lookup"
    static let lookupCases: [String: (stored: String, query: String, canonical: String)] = {
        let names = ["ascii": "Short-MiXeD.txt", "casefold": "Short-MiXeD.txt",
                     "long-ascii": String(repeating: "Z", count: 255), "unicode": "Café-文件-😀",
                     "prefix-unicode": String(repeating: "U", count: 254) + "é",
                     "long-unicode": String(repeating: "각", count: 255), "miss": "Missing-Lookup.txt"]
        return Dictionary(uniqueKeysWithValues: names.map { key, value in
            ("lookup." + key, (value, key == "casefold" ? value.lowercased() : value,
                               value.decomposedStringWithCanonicalMapping))
        })
    }()
    static let samples: Int = {
        guard let raw = ProcessInfo.processInfo.environment["NFSK_BENCH_SAMPLES"] else {
            return directorySuite ? 512 : 16384
        }
        guard let value = Int(raw), (128...16384).contains(value) else {
            preconditionFailure("samples must be 128...16384")
        }
        return value
    }()
    static let workloadFilter = Set((ProcessInfo.processInfo.environment["NFSK_BENCH_WORKLOADS"] ?? "")
        .split(separator: ",").map(String.init))
    static func selected(_ name: String) -> Bool { workloadFilter.isEmpty || workloadFilter.contains(name) }
    static let directoryEntries = 128
    static let directoryNames = (0..<directoryEntries).map { String(format: "Entry-%04d", $0) }
    static func entryType(_ kind: String, _ i: Int) -> UInt32 {
        if kind == "links" || (kind == "mixed" && i % 4 == 2) { return UInt32(NFSK_TYPE_SYMLINK) }
        if kind == "mixed" && i % 4 == 0 { return UInt32(NFSK_TYPE_DIR) }
        return UInt32(NFSK_TYPE_FILE)
    }
    static let payloads: [String: Data] = {
        var data = ["bench.small": Data(repeating: 0x41, count: 64),
                    "bench.large": Data(repeating: 0x42, count: 16384),
                    "bench.empty": Data()]
        for i in 0..<8 { data["bench.entry\(i)"] = Data(repeating: UInt8(i), count: 16) }
        return data
    }()

    static func backend(_ path: String, writable: Bool) throws -> NTFSBackend {
        var error: Int32 = 0
        guard let b = path.withCString({ nfsk_backend_from_file($0, writable ? 1 : 0, &error) }) else {
            throw posixError(error)
        }
        return NTFSBackend(backend: b, retain: nil, cleanup: {}, writable: writable)
    }

    static func prepare(_ path: String) throws {
        let b = try backend(path, writable: true)
        defer { nfsk_backend_free(b.backend) }
        var error: Int32 = 0
        guard let h = nfsk_mount(b.backend, false, &error) else { throw posixError(error) }
        let ino = nfsk_create(h, NFSK_ROOT_INO, "VolumeBenchmark", UInt32(NFSK_TYPE_FILE), &error)
        precondition(ino != 0)
        let content = Data(repeating: 0x33, count: 64)
        precondition(content.withUnsafeBytes { nfsk_write(h, ino, 0, $0.baseAddress, 64, &error) } == 64)
        for key in payloads.keys.sorted() {
            let data = payloads[key]!
            let rc = key.withCString { key in
                data.withUnsafeBytes { nfsk_setxattr(h, ino, key, $0.baseAddress, $0.count, Int32(NFSK_XATTR_CREATE)) }
            }
            precondition(rc == 0)
        }
        if lookupSuite {
            let dir = nfsk_create(h, NFSK_ROOT_INO, "LookupBenchmark", UInt32(NFSK_TYPE_DIR), &error)
            precondition(dir != 0)
            for stored in Set(lookupCases.filter { $0.key != "lookup.miss" }.map { $0.value.stored }).sorted() {
                let file = stored.withCString { nfsk_create(h, dir, $0, UInt32(NFSK_TYPE_FILE), &error) }
                precondition(file != 0)
            }
        } else if directorySuite {
            for kind in ["ordinary", "mixed", "links"] {
                let dir = ("Directory-" + kind).withCString { nfsk_create(h, NFSK_ROOT_INO, $0, UInt32(NFSK_TYPE_DIR), &error) }
                precondition(dir != 0)
                for i in 0..<directoryEntries {
                    let type = entryType(kind, i)
                    let ino = directoryNames[i].withCString {
                        type == NFSK_TYPE_SYMLINK ? nfsk_symlink(h, dir, $0, "target", &error) : nfsk_create(h, dir, $0, type, &error)
                    }
                    precondition(ino != 0)
                    if type == NFSK_TYPE_FILE {
                        precondition(content.withUnsafeBytes { nfsk_write(h, ino, 0, $0.baseAddress, 64, &error) } == 64)
                    }
                }
            }
        }
        precondition(nfsk_sync(h) == 0 && nfsk_umount(h) == 0)
    }

    static func cpu() -> UInt64 {
        var time = timespec()
        precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time) == 0)
        return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
    }

    static func operation(_ name: String, volume: ntfs3gVolume, item: ntfs3gItem, lookupID: UInt64? = nil) async throws {
        if lookupSuite, let test = lookupCases[name] {
            do {
                let (found, actual) = try await (volume as any FSVolume.Operations).lookupItem(named: FSFileName(string: test.query), inDirectory: item)
                precondition(lookupID != nil && (found as? ntfs3gItem)?.ino == lookupID &&
                             actual.string!.utf8.elementsEqual(test.canonical.utf8), "lookup inode/spelling mismatch")
            } catch {
                guard name == "lookup.miss" && (error as NSError).code == Int(ENOENT) else { throw error }
            }
            return
        }
        if name.hasPrefix("directory.") {
            let kind = String(name.split(separator: ".")[1])
            let wantAttributes = name.contains(".attrs"), limit = name.hasSuffix("64") ? 64 : 7
            let request: FSItem.GetAttributesRequest? = wantAttributes ? FSItem.GetAttributesRequest() : nil
            request?.wantedAttributes = [.type, .fileID, .parentID, .size, .flags, .modifyTime]
            var cookie = FSDirectoryCookie(rawValue: 0), total = 0
            while true {
                var accepted = 0
                let packer = nfsk_test_packer { name, type, ino, next, attrs in
                    if accepted == limit { return false }
                    accepted += 1; cookie = next
                    let spelling = name.string!
                    if spelling == "." || spelling == ".." {
                        precondition(!wantAttributes && type == .directory && attrs == nil)
                        return true
                    }
                    precondition(total < directoryEntries && spelling == directoryNames[total] && ino.rawValue != 0)
                    let expected = entryType(kind, total)
                    precondition(type.rawValue == Int(expected) && next.rawValue == UInt64(total + 3))
                    if wantAttributes {
                        precondition(attrs?.type == type && attrs?.fileID == ino && attrs?.parentID.rawValue == item.ino)
                        if expected != NFSK_TYPE_DIR { precondition(attrs?.size == (expected == NFSK_TYPE_SYMLINK ? 6 : 64)) }
                    } else { precondition(attrs == nil) }
                    total += 1
                    return true
                }
                _ = try await volume.enumerateDirectory(item, startingAt: cookie, verifier: FSDirectoryVerifier(rawValue: 1), attributes: request, packer: packer)
                if accepted == 0 { break }
            }
            precondition(total == directoryEntries)
            return
        }
        switch name {
        case "attributes":
            let request = FSItem.GetAttributesRequest()
            request.wantedAttributes = [.size, .fileID, .flags, .modifyTime]
            let result = try await volume.attributes(request, of: item)
            precondition(result.size == 64 && result.fileID.rawValue == item.ino)
        case "list":
            let names = try await volume.xattrs(of: item)
            precondition(Set(names.compactMap(\.string)) == Set(payloads.keys))
        default:
            let data = try await volume.xattr(named: FSFileName(string: name), of: item)
            precondition(data == payloads[name], "xattr payload mismatch")
        }
    }

    private static func measured(_ id: Int, name: String, volume: ntfs3gVolume, item: ntfs3gItem, lookupID: UInt64? = nil) async throws -> VolumeSample {
        let measure = { () async throws -> VolumeSample in
            let start = VolumeTrace.now()
            try await operation(name, volume: volume, item: item, lookupID: lookupID)
            let end = VolumeTrace.now()
            #if NFSK_PERF_TRACE
            let trace = VolumeTrace.take(id, start: start, end: end)
            precondition(trace.count == 5, "missing queue trace")
            #else
            let trace: [UInt64] = []
            #endif
            return VolumeSample(latency: end - start, trace: trace)
        }
        #if NFSK_PERF_TRACE
        return try await VolumeTrace.$requestID.withValue(id) { try await measure() }
        #else
        return try await measure()
        #endif
    }

    static func run(_ name: String, concurrency: Int, volume: ntfs3gVolume, item: ntfs3gItem, lookupID: UInt64? = nil) async throws {
        // Warm the same operation rather than labeling a fresh handle as cold I/O.
        let warmUntil = VolumeTrace.now() + 100_000_000
        repeat { try await operation(name, volume: volume, item: item, lookupID: lookupID) }
        while VolumeTrace.now() < warmUntil
        nfsk_perf_reset()
        var results: [VolumeSample] = []
        results.reserveCapacity(samples)
        let cpuStart = cpu(), start = VolumeTrace.now()
        if concurrency == 1 {
            for i in 0..<samples { results.append(try await measured(i, name: name, volume: volume, item: item, lookupID: lookupID)) }
        } else {
            try await withThrowingTaskGroup(of: VolumeSample.self) { group in
                var next = 0
                for _ in 0..<concurrency {
                    let i = next; next += 1
                    group.addTask { try await measured(i, name: name, volume: volume, item: item, lookupID: lookupID) }
                }
                for try await result in group {
                    results.append(result)
                    if next < samples {
                        let i = next; next += 1
                        group.addTask { try await measured(i, name: name, volume: volume, item: item, lookupID: lookupID) }
                    }
                }
            }
        }
        let elapsed = VolumeTrace.now() - start, cpuElapsed = cpu() - cpuStart
        let counters = nfsk_perf_snapshot()
        var usage = rusage(); precondition(getrusage(RUSAGE_SELF, &usage) == 0)
        let sorted = results.map(\.latency).sorted()
        let row: [String: Any] = [
            "workload": name, "concurrency": concurrency, "operations": samples,
            "wall_ns": elapsed, "cpu_ns": cpuElapsed, "rss_bytes": usage.ru_maxrss,
            "p50_ns": sorted[(samples*50+99)/100-1], "p95_ns": sorted[(samples*95+99)/100-1],
            "p99_ns": sorted[(samples*99+99)/100-1], "samples_ns": results.map(\.latency),
            "trace_columns": ["entry_ns", "queue_wait_ns", "body_ns", "snapshot_ns", "resume_and_caller_ns"],
            "traces": results.map(\.trace), "pread_calls": counters.pread_calls,
            "pread_bytes": counters.pread_bytes, "pread_ns": counters.pread_ns,
            "inode_opens": counters.inode_opens, "attr_opens": counters.attr_opens,
            "statfs_calls": counters.statfs_calls, "statfs_ns": counters.statfs_ns,
            "symlink_parses": counters.symlink_parses,
            "inode_open_ns": counters.inode_open_ns, "inode_closes": counters.inode_closes,
            "inode_close_ns": counters.inode_close_ns, "attr_open_ns": counters.attr_open_ns,
            "attr_closes": counters.attr_closes, "attr_close_ns": counters.attr_close_ns,
            "mbstoucs_calls": counters.mbstoucs_calls, "mbstoucs_ns": counters.mbstoucs_ns,
            "reparse_validations": counters.reparse_validations, "reparse_validation_ns": counters.reparse_validation_ns
        ]
        print(String(data: try JSONSerialization.data(withJSONObject: row, options: .sortedKeys), encoding: .utf8)!)
    }

    static func main() async throws {
        // Match the production volume queue's QoS; don't let unrelated lower
        // priority executor placement dominate the sequential caller overhead.
        try await Task.detached(priority: .userInitiated) { try await execute() }.value
    }

    static func execute() async throws {
        let args = CommandLine.arguments
        precondition(args.count == 3 && ["prepare", "measure"].contains(args[1]))
        let available = lookupSuite ? Set(lookupCases.keys) : directorySuite
            ? Set(["ordinary", "mixed", "links"].flatMap { kind in
                ["names7", "attrs7", "attrs64"].map { "directory.\(kind).\($0)" }
            })
            : Set(["attributes", "bench.small", "bench.large", "bench.empty", "list"])
        precondition(workloadFilter.isSubset(of: available), "unknown workload for this suite")
        if args[1] == "prepare" { try prepare(args[2]); return }
        let b = try backend(args[2], writable: false)
        var error: Int32 = 0
        guard let handle = nfsk_mount(b.backend, true, &error) else { throw posixError(error) }
        let ino = nfsk_lookup(handle, NFSK_ROOT_INO, "VolumeBenchmark", &error)
        var dirs: [String: UInt64] = [:]
        var lookupIDs: [String: UInt64] = [:]
        if lookupSuite {
            let directory = nfsk_lookup(handle, NFSK_ROOT_INO, "LookupBenchmark", &error)
            precondition(directory != 0)
            dirs["lookup"] = directory
            for (name, test) in lookupCases where name != "lookup.miss" {
                let id = test.stored.withCString { nfsk_lookup(handle, directory, $0, &error) }
                precondition(id != 0)
                lookupIDs[name] = id
            }
        } else if directorySuite {
            for kind in ["ordinary", "mixed", "links"] {
                dirs[kind] = ("Directory-" + kind).withCString { nfsk_lookup(handle, NFSK_ROOT_INO, $0, &error) }
                precondition(dirs[kind]! != 0)
            }
        }
        precondition(ino != 0 && nfsk_umount(handle) == 0)
        let volume = try ntfs3gVolume(backend: b, activationBackend: { _, _ in nil }, onContainerStatusChange: { _ in })
        let item = ntfs3gItem(ino: ino, parentIno: NFSK_ROOT_INO, name: FSFileName(string: "VolumeBenchmark"))
        if lookupSuite {
            let directory = ntfs3gItem(ino: dirs["lookup"]!, parentIno: NFSK_ROOT_INO, name: FSFileName(string: "LookupBenchmark"))
            for name in lookupCases.keys.sorted() where selected(name) {
                for concurrency in [1, 8] {
                    try await run(name, concurrency: concurrency, volume: volume, item: directory, lookupID: lookupIDs[name])
                }
            }
        } else if directorySuite {
            for kind in ["ordinary", "mixed", "links"] {
                let directory = ntfs3gItem(ino: dirs[kind]!, parentIno: NFSK_ROOT_INO, name: FSFileName(string: "Directory-" + kind))
                for mode in ["names7", "attrs7", "attrs64"] where selected("directory.\(kind).\(mode)") {
                    try await run("directory.\(kind).\(mode)", concurrency: 1, volume: volume, item: directory)
                }
            }
        } else {
            for name in ["attributes", "bench.small", "bench.large", "bench.empty", "list"] where selected(name) {
                try await run(name, concurrency: 1, volume: volume, item: item)
            }
            for name in ["attributes", "bench.small", "list"] where selected(name) {
                try await run(name, concurrency: 8, volume: volume, item: item)
            }
        }
        let teardown = await volume.teardown()
        precondition(teardown == 0)
        fputs("PASS: read-only Swift volume payloads, names and teardown\n", stderr)
    }
}
