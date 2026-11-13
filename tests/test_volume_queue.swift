import Foundation
import FSKit
import Darwin

// Test-only ledgers. Counts describe these payloads and copied-source queue
// witnesses, not allocator overhead, FSKit/kernel buffers or total process RSS.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func access<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}

private enum Payload {
    struct State {
        var live = 0, peak = 0, made = 0, freed = 0, consumed = 0
        var lastValue: UInt8?
        var pointers: [UInt: Int] = [:]
    }
    struct Snapshot { let live: Int, peak: Int, made: Int, freed: Int, consumed: Int; let lastValue: UInt8? }
    static let state = Locked(State())
    static func make(bytes: Int, value: UInt8) -> Data {
        precondition((4096...(1 << 20)).contains(bytes))
        let raw = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
        raw.initializeMemory(as: UInt8.self, repeating: value, count: bytes)
        state.access { s in
            precondition(s.live + bytes <= 64 << 20, "bounded test payload budget")
            s.live += bytes; s.peak = max(s.peak, s.live); s.made += 1
            precondition(s.pointers.updateValue(bytes, forKey: UInt(bitPattern: raw)) == nil)
        }
        return Data(bytesNoCopy: raw, count: bytes, deallocator: .custom { pointer, count in
            state.access { s in
                precondition(s.pointers.removeValue(forKey: UInt(bitPattern: pointer)) == count)
                s.live -= count; s.freed += 1
            }
            pointer.deallocate()
        })
    }
    static func consumed(_ pointer: UnsafeRawPointer?, bytes: Int) {
        state.access { s in
            precondition(pointer != nil && s.pointers[UInt(bitPattern: pointer!)] == bytes,
                         "Swift-to-C write did not borrow the tracked payload")
            s.consumed += 1
            s.lastValue = pointer!.load(as: UInt8.self)
        }
    }
    static var snapshot: Snapshot {
        state.access { Snapshot(live: $0.live, peak: $0.peak, made: $0.made, freed: $0.freed,
                               consumed: $0.consumed, lastValue: $0.lastValue) }
    }
    static func reset() {
        state.access { s in
            precondition(s.live == 0 && s.made == s.freed && s.pointers.isEmpty)
            s = State()
        }
    }
}

// The runner inserts these witnesses into COPIED withIO/replyWithItem methods.
// An ObjectIdentifier carries identity only; no probe retains a volume or buffer.
final class VolumeQueueLease {
    let id: Int
    init(owner: ObjectIdentifier, function: String) { id = VolumeQueueProbe.enqueue(owner, function) }
    func submitted() { VolumeQueueProbe.submitted(id) }
    func started() { VolumeQueueProbe.started(id) }
    func finished() { VolumeQueueProbe.finished(id) }
    deinit { VolumeQueueProbe.retired(id) }
}

enum VolumeQueueProbe {
    struct Record {
        let id: Int, owner: ObjectIdentifier, function: String
        var submitted = false, started = false, finished = false, retired = false
    }
    struct State {
        var records: [Record] = []
        var starts: [Int] = []
        var live = 0, active = 0, peak = 0, peakActive = 0
        var activeOwners: Set<ObjectIdentifier> = []
        var submitted: Int { records.filter(\.submitted).count }
    }
    struct Snapshot { let submitted: Int, live: Int, active: Int, peak: Int, peakActive: Int }
    private static let state = Locked(State())
    static func enqueue(_ owner: ObjectIdentifier, _ function: String) -> Int {
        state.access { s in
            precondition(s.records.count < 1024, "bounded queue evidence")
            let id = s.records.count
            s.records.append(Record(id: id, owner: owner, function: function))
            s.live += 1; s.peak = max(s.peak, s.live)
            return id
        }
    }
    static func submitted(_ id: Int) { state.access { $0.records[id].submitted = true } }
    static func started(_ id: Int) {
        state.access { s in
            precondition(!s.records[id].started && s.activeOwners.insert(s.records[id].owner).inserted,
                         "same-volume work overlapped")
            s.records[id].started = true; s.starts.append(id)
            s.active += 1; s.peakActive = max(s.peakActive, s.active)
        }
    }
    static func finished(_ id: Int) {
        state.access { s in
            precondition(s.records[id].started && !s.records[id].finished)
            s.records[id].finished = true; s.active -= 1
            precondition(s.activeOwners.remove(s.records[id].owner) != nil)
        }
    }
    static func retired(_ id: Int) {
        state.access { s in
            precondition(s.records[id].finished && !s.records[id].retired)
            s.records[id].retired = true; s.live -= 1
        }
    }
    static func writePointer(_ pointer: UnsafeRawPointer?, bytes: Int) { Payload.consumed(pointer, bytes: bytes) }
    static var snapshot: Snapshot {
        // Inspect mutable containers under the lock; only scalar values escape.
        state.access { Snapshot(submitted: $0.submitted, live: $0.live, active: $0.active,
                                peak: $0.peak, peakActive: $0.peakActive) }
    }
    static func checkFIFO(syncAt index: Int) {
        state.access { s in
            precondition(s.starts == Array(s.records.indices) && s.records.allSatisfy(\.retired))
            precondition(s.records[index].function.hasPrefix("synchronize") && s.records[index + 3].function.hasPrefix("teardown"))
        }
    }
    static func checkTeardownLast() {
        state.access { s in
            precondition(s.starts == Array(s.records.indices) && s.records.allSatisfy(\.retired))
            precondition(s.records.last?.function.hasPrefix("teardown") == true)
        }
    }
    static func checkTerminalSync() {
        state.access { s in
            precondition(s.starts == Array(s.records.indices) && s.records.allSatisfy(\.retired))
            precondition(s.records[1].function.hasPrefix("teardown") &&
                         s.records.dropFirst(2).allSatisfy { $0.function.hasPrefix("synchronize") })
        }
    }
    static func checkMountRetirement() {
        state.access { s in
            precondition(s.starts == Array(s.records.indices) && s.records.allSatisfy(\.retired))
            precondition(s.records.count == 4 && s.records[2].function.hasPrefix("teardown") &&
                         s.records[1].function.hasPrefix("withRecordedIO") &&
                         s.records[3].function.hasPrefix("withRecordedIO"))
        }
    }
    static func reset() {
        state.access { s in
            precondition(s.live == 0 && s.active == 0 && s.activeOwners.isEmpty)
            s = State()
        }
        Payload.reset()
    }
}

private final class ReplyGate {
    private let released = DispatchSemaphore(value: 0)
    let entered = Locked(false)
    init(_ volume: ntfs3gVolume, root: FSItem, name: String) {
        volume.lookupItem(named: FSFileName(string: name), inDirectory: root) { [self] item, _, error in
            precondition(error == nil && item != nil)
            entered.access { $0 = true }
            precondition(released.wait(timeout: .now() + 20) == .success, "reply gate timed out")
        }
    }
    func release() { released.signal() }
}

@main
struct VolumeQueueTests {
    static func until(_ label: String, _ predicate: () -> Bool) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
        while !predicate() {
            precondition(DispatchTime.now().uptimeNanoseconds < deadline, "Timed out: \(label)")
            try! await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    static func retired() async {
        await until("queue retirement") { VolumeQueueProbe.snapshot.live == 0 }
        await until("payload retirement") { Payload.snapshot.live == 0 }
        let p = Payload.snapshot
        precondition(p.made == p.freed)
    }
    private static func makeVolume(_ path: String, cleanup: Locked<Int>) throws -> (ntfs3gVolume, ntfs3gItem) {
        var error: Int32 = 0
        let raw = path.withCString { nfsk_backend_from_file($0, 1, &error) }
        precondition(raw != nil && error == 0)
        let backend = NTFSBackend(backend: raw!, retain: nil, cleanup: { cleanup.access { $0 += 1 } }, writable: true)
        let volume = try ntfs3gVolume(backend: backend, activationBackend: { _, _ in nil }, onContainerStatusChange: { _ in })
        let root = ntfs3gItem(ino: NFSK_ROOT_INO, parentIno: NFSK_PARENT_OF_ROOT, name: FSFileName(string: "/"))
        return (volume, root)
    }
    static func create(_ volume: ntfs3gVolume, root: FSItem, name: String) async throws -> FSItem {
        try await (volume as any FSVolume.Operations).createItem(named: FSFileName(string: name), type: .file,
            inDirectory: root, attributes: FSItem.SetAttributesRequest()).0
    }
    private static func write(_ volume: ntfs3gVolume, item: FSItem, bytes: Int, offset: Int,
                      value: UInt8, done: Locked<Int>) -> Task<Int, Error> {
        let data = Payload.make(bytes: bytes, value: value)
        return Task.detached {
            defer { done.access { $0 += 1 } }
            return try await volume.write(contents: data, to: item, at: off_t(offset))
        }
    }
    static func evidence(_ name: String, expectedPayload: Int) {
        let p = Payload.snapshot, q = VolumeQueueProbe.snapshot
        precondition(p.live == expectedPayload)
        let result: [String: Any] = ["case": name, "payload_live": p.live, "payload_peak": p.peak,
            "payload_made": p.made, "payload_freed": p.freed, "borrowed_write_pointers": p.consumed,
            "submitted": q.submitted, "queue_live": q.live, "active": q.active,
            "queue_peak": q.peak, "active_peak": q.peakActive]
        print("QUEUE_OWNERSHIP " + String(data: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
    }
    static func verify(_ image: String, ino: UInt64, count: Int, bytes: Int, value: UInt8? = nil) {
        var error: Int32 = 0
        let backend = image.withCString { nfsk_backend_from_file($0, 0, &error) }!
        defer { nfsk_backend_free(backend) }
        let h = nfsk_mount(backend, true, &error)!
        var attributes = nfsk_attr_t()
        precondition(nfsk_getattr(h, ino, &attributes) == 0 && attributes.size == count * bytes,
                     "accepted writes did not survive reopening")
        var buffer = [UInt8](repeating: 0, count: bytes)
        for index in 0..<count {
            let n = buffer.withUnsafeMutableBytes { nfsk_read(h, ino, Int64(index * bytes), $0.baseAddress, Int64(bytes), &error) }
            precondition(n == bytes && buffer.allSatisfy { $0 == (value ?? UInt8(index + 1)) }, "persisted payload mismatch")
        }
        precondition(nfsk_umount(h) == 0)
    }
    static func backlog(_ image: String, count: Int, bytes: Int) async throws {
        let cleaned = Locked(0), done = Locked(0)
        let (volume, root) = try makeVolume(image, cleanup: cleaned)
        let file = try await create(volume, root: root, name: "QueueBacklog.bin")
        try await volume.openItem(file, modes: .write)
        await retired(); VolumeQueueProbe.reset()
        nfsk_test_arm_write(); defer { nfsk_test_release_write() }
        var writes = [write(volume, item: file, bytes: bytes, offset: 0, value: 1, done: done)]
        let entered = await withCheckedContinuation { c in
            DispatchQueue.global().async { c.resume(returning: nfsk_test_wait_for_write()) }
        }
        precondition(entered != 0)
        await until("first write submitted") { VolumeQueueProbe.snapshot.submitted == 1 }
        for i in 1..<count {
            writes.append(write(volume, item: file, bytes: bytes, offset: i * bytes, value: UInt8(i + 1), done: done))
            await until("queued write") { VolumeQueueProbe.snapshot.submitted == i + 1 }
        }
        writes.forEach { $0.cancel() }
        let sync = Task { try await volume.synchronize(flags: .wait) }
        await until("sync queued") { VolumeQueueProbe.snapshot.submitted == count + 1 }
        let close = Task { try await volume.closeItem(file, modes: []) }
        await until("close queued") { VolumeQueueProbe.snapshot.submitted == count + 2 }
        let reclaim = Task { try await volume.reclaimItem(file) }
        await until("reclaim queued") { VolumeQueueProbe.snapshot.submitted == count + 3 }
        let teardown = Task { await volume.teardown() }
        await until("teardown queued") { VolumeQueueProbe.snapshot.submitted == count + 4 }
        var later: [Task<Int, Error>] = []
        for i in 0..<8 {
            later.append(write(volume, item: file, bytes: bytes, offset: 0, value: 0xee, done: done))
            await until("late write rejected before stalled I/O returns") { done.access { $0 } == i + 1 }
        }
        for task in later {
            do { _ = try await task.value; preconditionFailure("write admitted after teardown barrier") }
            catch { precondition((error as NSError).code == Int(EINVAL)) }
        }
        await until("rejected write payload retired") { Payload.snapshot.live == count * bytes }
        precondition(done.access { $0 } == 8 && cleaned.access { $0 } == 0)
        precondition(VolumeQueueProbe.snapshot.submitted == count + 4)
        precondition(VolumeQueueProbe.snapshot.active == 1)
        evidence("held-write-\(count)", expectedPayload: count * bytes)
        nfsk_test_release_write()
        for task in writes { let n = try await task.value; precondition(n == bytes) }
        try await sync.value; try await close.value; try await reclaim.value
        let result = await teardown.value; precondition(result == 0 && cleaned.access { $0 } == 1)
        await retired()
        VolumeQueueProbe.checkFIFO(syncAt: count)
        precondition(Payload.snapshot.consumed == count && done.access { $0 } == count + 8)
        evidence("retired-write-\(count)", expectedPayload: 0)
        verify(image, ino: (file as! ntfs3gItem).ino, count: count, bytes: bytes)
        let again = await volume.teardown(); precondition(again == result && cleaned.access { $0 } == 1)
        await retired()
        print("PASS: early late-write EINVAL without retaining payload; accepted cancelled writes retain data; FIFO sync/close/reclaim/teardown, single cleanup, repeat result and persisted bytes")
    }
    static func independent(_ images: [String]) async throws {
        let cleanedA = Locked(0), cleanedB = Locked(0), done = Locked(0)
        let (a, ra) = try makeVolume(images[0], cleanup: cleanedA)
        let (b, rb) = try makeVolume(images[1], cleanup: cleanedB)
        let fa = try await create(a, root: ra, name: "QueueParallel.bin")
        let fb = try await create(b, root: rb, name: "QueueParallel.bin")
        await retired(); VolumeQueueProbe.reset()
        let ga = ReplyGate(a, root: ra, name: "QueueParallel.bin")
        await until("first volume held") { ga.entered.access { $0 } }
        let wanted = FSItem.GetAttributesRequest()
        wanted.wantedAttributes = [.size]
        _ = try await b.attributes(wanted, of: fb)
        let gb = ReplyGate(b, root: rb, name: "QueueParallel.bin")
        await until("both volumes held") { gb.entered.access { $0 } }
        var first: [Task<Int, Error>] = [], second: [Task<Int, Error>] = []
        let base = VolumeQueueProbe.snapshot.submitted
        for i in 0..<32 {
            first.append(write(a, item: fa, bytes: 256 << 10, offset: 0, value: 0x31, done: done))
            second.append(write(b, item: fb, bytes: 256 << 10, offset: 0, value: 0x32, done: done))
            await until("both queued") { VolumeQueueProbe.snapshot.submitted == base + (i + 1) * 2 }
        }
        precondition(VolumeQueueProbe.snapshot.active == 2 && done.access { $0 } == 0)
        evidence("two-volumes-held", expectedPayload: 16 << 20)
        ga.release()
        for task in first { let n = try await task.value; precondition(n == 256 << 10) }
        await until("first volume payload retired") { Payload.snapshot.live == 8 << 20 }
        precondition(done.access { $0 } == 32 && VolumeQueueProbe.snapshot.active == 1)
        evidence("second-volume-still-held", expectedPayload: 8 << 20)
        gb.release()
        for task in second { let n = try await task.value; precondition(n == 256 << 10) }
        await retired(); evidence("two-volumes-retired", expectedPayload: 0)
        let ar = await a.teardown(), br = await b.teardown()
        precondition(ar == 0 && br == 0 && cleanedA.access { $0 } == 1 && cleanedB.access { $0 } == 1)
        await retired()
        print("PASS: independent volume progress and aggregate 16 MiB caller payload; one volume may retire while the other remains held")
    }
    static func repeated(_ image: String) async throws {
        let cleaned = Locked(0), done = Locked(0)
        let (volume, root) = try makeVolume(image, cleanup: cleaned)
        let file = try await create(volume, root: root, name: "QueueRepeat.bin")
        await retired()
        for round in 0..<32 {
            VolumeQueueProbe.reset()
            let gate = ReplyGate(volume, root: root, name: "QueueRepeat.bin")
            await until("repeat gate") { gate.entered.access { $0 } }
            var jobs: [Task<Int, Error>] = []
            for i in 0..<4 {
                jobs.append(write(volume, item: file, bytes: 4096, offset: 0, value: UInt8(i + 1), done: done))
                await until("repeat request") { VolumeQueueProbe.snapshot.submitted == i + 2 }
            }
            jobs[1].cancel(); jobs[3].cancel()
            precondition(Payload.snapshot.live == 16384)
            gate.release()
            for job in jobs { let n = try await job.value; precondition(n == 4096) }
            await retired()
            precondition(Payload.snapshot.consumed == 4)
            if round == 0 || round == 31 { evidence("repeat-\(round + 1)", expectedPayload: 0) }
        }
        VolumeQueueProbe.reset()
        nfsk_test_fail_inode_open((file as! ntfs3gItem).ino)
        let failing = write(volume, item: file, bytes: 4096, offset: 0, value: 0x44, done: done)
        do { _ = try await failing.value; preconditionFailure("injected write failure hidden") }
        catch { precondition((error as NSError).code == Int(EIO)) }
        await retired()
        precondition(nfsk_test_inode_faults() == 1)
        let retry = write(volume, item: file, bytes: 4096, offset: 0, value: 0x45, done: done)
        let count = try await retry.value; precondition(count == 4096)
        await retired()
        var retained: Data? = Payload.make(bytes: 1 << 20, value: 0x55)
        let written = try await volume.write(contents: retained!, to: file, at: 0)
        precondition(written == 1 << 20)
        await until("caller-held request retired") { VolumeQueueProbe.snapshot.live == 0 }
        let result = await volume.teardown(); precondition(result == 0 && cleaned.access { $0 } == 1)
        await until("caller-held teardown retired") { VolumeQueueProbe.snapshot.live == 0 }
        withExtendedLifetime(retained) { evidence("caller-retained-after-teardown", expectedPayload: 1 << 20) }
        retained = nil
        await retired(); evidence("caller-released", expectedPayload: 0)
        print("PASS: 32 cancelled bursts, EIO propagation/retry and caller-owned payload beyond reply/teardown; all released by their actual owner")
    }
    static func admissionRace(_ image: String) async throws {
        for round in 0..<8 {
            let cleaned = Locked(0), done = Locked(0)
            let (volume, root) = try makeVolume(image, cleanup: cleaned)
            let file = try await create(volume, root: root, name: "QueueRace\(round).bin")
            await retired(); VolumeQueueProbe.reset()
            nfsk_test_arm_write()
            var jobs = [write(volume, item: file, bytes: 4096, offset: 0, value: 1, done: done)]
            let entered = await withCheckedContinuation { c in
                DispatchQueue.global().async { c.resume(returning: nfsk_test_wait_for_write()) }
            }
            precondition(entered != 0)
            var teardown: Task<Int32, Never>?
            for i in 1...32 {
                jobs.append(write(volume, item: file, bytes: 4096, offset: 0, value: UInt8(i + 1), done: done))
                if i == 16 { teardown = Task.detached { await volume.teardown() } }
            }
            await until("racing requests classified") {
                VolumeQueueProbe.snapshot.submitted + done.access { $0 } == 34
            }
            precondition(cleaned.access { $0 } == 0)
            nfsk_test_release_write()
            var accepted = 0, rejected = 0
            for job in jobs {
                do { let n = try await job.value; precondition(n == 4096); accepted += 1 }
                catch { precondition((error as NSError).code == Int(EINVAL)); rejected += 1 }
            }
            let result = await teardown!.value
            precondition(result == 0 && cleaned.access { $0 } == 1 && accepted + rejected == 33)
            await retired(); VolumeQueueProbe.checkTeardownLast()
            precondition(Payload.snapshot.consumed == accepted)
            verify(image, ino: (file as! ntfs3gItem).ino, count: 1, bytes: 4096, value: Payload.snapshot.lastValue!)
            print("ADMISSION_RACE round=\(round + 1) accepted=\(accepted) rejected=\(rejected) released=\(Payload.snapshot.freed)")
        }
        print("PASS: concurrent write/teardown admission is atomic; accepted writes precede teardown and persist, rejected writes do not enter the queue")
    }
    static func terminalSync(_ image: String) async throws {
        let flags: [FSSyncFlags] = [.wait, .noWait, .dWait]
        for fail in [false, true] {
            let cleaned = Locked(0)
            let (volume, root) = try makeVolume(image, cleanup: cleaned)
            let name = fail ? "TerminalError.bin" : "TerminalClean.bin"
            _ = try await create(volume, root: root, name: name)
            await retired(); VolumeQueueProbe.reset()
            let gate = ReplyGate(volume, root: root, name: name)
            await until("terminal reply held") { gate.entered.access { $0 } }
            if fail { nfsk_test_fail_next_sync() }
            let teardown = Task { await volume.teardown() }
            await until("terminal teardown queued") { VolumeQueueProbe.snapshot.submitted == 2 }
            var syncs: [Task<Int, Never>] = []
            for (index, flag) in flags.enumerated() {
                syncs.append(Task {
                    do { try await volume.synchronize(flags: flag); return 0 }
                    catch { precondition((error as NSError).domain == NSPOSIXErrorDomain); return (error as NSError).code }
                })
                await until("terminal sync queued") { VolumeQueueProbe.snapshot.submitted == index + 3 }
            }
            syncs[1].cancel()
            precondition(cleaned.access { $0 } == 0 && VolumeQueueProbe.snapshot.active == 1)
            gate.release()
            let released = await teardown.value
            precondition(released == (fail ? -EIO : 0) && cleaned.access { $0 } == 1)
            for (index, sync) in syncs.enumerated() {
                let code = await sync.value
                print("TERMINAL_SYNC failed=\(fail) flag=\(flags[index].rawValue) returned=\(code)")
                precondition(code == (fail ? Int(EIO) : 0), "queued sync lost the terminal release result")
            }
            await retired(); VolumeQueueProbe.checkTerminalSync()
            let repeated = await volume.teardown()
            precondition(repeated == released && cleaned.access { $0 } == 1)
            do {
                try await volume.synchronize(flags: .wait)
                precondition(!fail, "repeated sync lost the terminal error")
            } catch { precondition(fail && (error as NSError).code == Int(EIO)) }
            await retired(); evidence(fail ? "terminal-error" : "terminal-clean", expectedPayload: 0)
        }
        print("PASS: queued and repeated sync preserves failed teardown; healthy retirement stays idempotent; cancellation retains FIFO and one cleanup")
    }
    static func terminalMount(_ image: String) async throws {
        for fail in [false, true] {
            let cleaned = Locked(0), completed = Locked(0)
            let (volume, root) = try makeVolume(image, cleanup: cleaned)
            _ = try await volume.activate(mountOptions: [])
            let name = fail ? "MountRetirementError.bin" : "MountRetirementClean.bin"
            _ = try await create(volume, root: root, name: name)
            await retired(); VolumeQueueProbe.reset()
            let gate = ReplyGate(volume, root: root, name: name)
            await until("mount reply held") { gate.entered.access { $0 } }
            func mounting() -> Task<Int, Never> {
                Task.detached {
                    defer { completed.access { $0 += 1 } }
                    do { try await volume.mount(); return 0 }
                    catch {
                        precondition((error as NSError).domain == NSPOSIXErrorDomain)
                        return (error as NSError).code
                    }
                }
            }
            let before = mounting()
            await until("live mount queued") { VolumeQueueProbe.snapshot.submitted == 2 }
            if fail { nfsk_test_fail_next_sync() }
            let teardown = Task { await volume.teardown() }
            await until("mount teardown queued") { VolumeQueueProbe.snapshot.submitted == 3 }
            let after = mounting()
            await until("retired mount queued") { VolumeQueueProbe.snapshot.submitted == 4 }
            before.cancel(); after.cancel()
            precondition(completed.access { $0 } == 0 && cleaned.access { $0 } == 0)
            gate.release()
            let liveResult = await before.value, retiredResult = await after.value, releaseResult = await teardown.value
            print("MOUNT_QUEUE failed=\(fail) before=\(liveResult) after=\(retiredResult) release=\(releaseResult)")
            precondition(liveResult == 0 && retiredResult == Int(ENXIO) && releaseResult == (fail ? -EIO : 0))
            await retired(); VolumeQueueProbe.checkMountRetirement()
            precondition(completed.access { $0 } == 2 && cleaned.access { $0 } == 1)
            let repeated = await volume.teardown()
            precondition(repeated == releaseResult && cleaned.access { $0 } == 1)
            do { try await volume.synchronize(flags: .wait); precondition(!fail) }
            catch { precondition(fail && (error as NSError).code == Int(EIO)) }
            await retired()
        }
        print("PASS: cancelled mount callbacks retain FIFO; mount before teardown succeeds, mount after returns ENXIO, release/sync errors and single cleanup preserved")
    }
    private static func setXattr(_ volume: ntfs3gVolume, item: FSItem, name: String,
                                 bytes: Int, value: UInt8, done: Locked<Int>) -> Task<Int, Never> {
        let payload = Payload.make(bytes: bytes, value: value)
        return Task.detached {
            defer { done.access { $0 += 1 } }
            do {
                try await volume.setXattr(named: FSFileName(string: name), to: payload,
                                          on: item, policy: .alwaysSet)
                return 0
            } catch {
                precondition((error as NSError).domain == NSPOSIXErrorDomain)
                return (error as NSError).code
            }
        }
    }
    private static func verifyXattrs(_ image: String, ino: UInt64, prefix: String,
                                     codes: [Int], bytes: Int) {
        var error: Int32 = 0
        let backend = image.withCString { nfsk_backend_from_file($0, 0, &error) }!
        defer { nfsk_backend_free(backend) }
        let handle = nfsk_mount(backend, true, &error)!
        for (index, code) in codes.enumerated() {
            var buffer: UnsafeMutableRawPointer?
            let size = (prefix + String(index)).withCString { nfsk_getxattr_alloc(handle, ino, $0, &buffer) }
            if code == 0 {
                precondition(size == bytes && buffer != nil)
                let contents = UnsafeRawBufferPointer(start: buffer, count: Int(size))
                precondition(contents.allSatisfy { $0 == UInt8(index + 1) }, "accepted xattr lost or corrupted")
            } else {
                precondition(code == Int(EINVAL) && size == -Int64(ENOATTR) && buffer == nil,
                             "rejected xattr reached storage")
            }
            free(buffer)
        }
        precondition(nfsk_umount(handle) == 0)
    }
    static func xattrRetirement(_ image: String) async throws {
        let bytes = 128 << 10
        for fail in [false, true] {
            let cleaned = Locked(0), done = Locked(0)
            let (volume, root) = try makeVolume(image, cleanup: cleaned)
            let name = fail ? "XattrRetirementError.bin" : "XattrRetirementClean.bin"
            let file = try await create(volume, root: root, name: name)
            await retired(); VolumeQueueProbe.reset()
            let gate = ReplyGate(volume, root: root, name: name)
            await until("xattr reply held") { gate.entered.access { $0 } }
            let acceptedCount = fail ? 0 : 4
            var accepted: [Task<Int, Never>] = []
            for index in 0..<acceptedCount {
                accepted.append(setXattr(volume, item: file, name: "queue.xattr.\(index)",
                                         bytes: bytes, value: UInt8(index + 1), done: done))
                await until("accepted xattr queued") { VolumeQueueProbe.snapshot.submitted == index + 2 }
            }
            accepted.forEach { $0.cancel() }
            if fail { nfsk_test_fail_next_sync() }
            let teardown = Task { await volume.teardown() }
            let queuedBeforeLate = acceptedCount + 2
            await until("xattr teardown queued") { VolumeQueueProbe.snapshot.submitted == queuedBeforeLate }
            var late: [Task<Int, Never>] = []
            for index in 0..<8 {
                late.append(setXattr(volume, item: file, name: "queue.late.\(index)",
                                     bytes: bytes, value: UInt8(index + 1), done: done))
            }
            late.forEach { $0.cancel() }
            // Both variants reach this point: old requests queue; the candidate replies.
            await until("late xattrs classified") {
                VolumeQueueProbe.snapshot.submitted + done.access { $0 } == queuedBeforeLate + 8
            }
            let early = done.access { $0 }, lateQueued = VolumeQueueProbe.snapshot.submitted - queuedBeforeLate
            await until("rejected xattr ownership released") { Payload.snapshot.live == (acceptedCount + lateQueued) * bytes }
            precondition(cleaned.access { $0 } == 0 && VolumeQueueProbe.snapshot.active == 1)
            evidence("xattr-held-\(fail)", expectedPayload: (acceptedCount + lateQueued) * bytes)
            print("XATTR_RETIREMENT failed=\(fail) early=\(early) late_queued=\(lateQueued) late_bytes=\(lateQueued * bytes)")
            gate.release()
            for task in accepted { let code = await task.value; precondition(code == 0) }
            for task in late { let code = await task.value; precondition(code == Int(EINVAL)) }
            let result = await teardown.value
            precondition(result == (fail ? -EIO : 0) && cleaned.access { $0 } == 1)
            await retired()
            precondition(done.access { $0 } == acceptedCount + 8 && Payload.snapshot.consumed == acceptedCount)
            if !fail {
                verifyXattrs(image, ino: (file as! ntfs3gItem).ino, prefix: "queue.xattr.",
                             codes: Array(repeating: 0, count: acceptedCount), bytes: bytes)
                verifyXattrs(image, ino: (file as! ntfs3gItem).ino, prefix: "queue.late.",
                             codes: Array(repeating: Int(EINVAL), count: 8), bytes: bytes)
            }
            print("XATTR_RETIREMENT_COMPLETED failed=\(fail) accepted=\(acceptedCount) late_errno=\(EINVAL) cleanup=\(cleaned.access { $0 }) payload_live=\(Payload.snapshot.live) persisted_checked=\(!fail)")
            precondition(early == 8 && lateQueued == 0, "late xattrs retained payload behind final teardown")
            VolumeQueueProbe.checkTeardownLast()
            for policy: FSVolume.SetXattrPolicy in [.alwaysSet, .mustCreate, .mustReplace, .delete] {
                do {
                    try await volume.setXattr(named: FSFileName(string: "queue.xattr.0"), to: nil,
                                              on: file, policy: policy)
                    preconditionFailure("retired xattr operation succeeded")
                } catch { precondition((error as NSError).code == Int(EINVAL)) }
            }
            precondition(VolumeQueueProbe.snapshot.submitted == queuedBeforeLate)
            let again = await volume.teardown()
            precondition(again == result && cleaned.access { $0 } == 1)
            await retired()
        }
        print("PASS: late xattr EINVAL releases 1 MiB without queueing; accepted cancelled payload survives reopen; failed/repeated teardown and all policies preserved")
    }
    static func xattrAdmissionRace(_ image: String) async throws {
        for round in 0..<8 {
            let cleaned = Locked(0), done = Locked(0)
            let (volume, root) = try makeVolume(image, cleanup: cleaned)
            let name = "XattrRace\(round).bin"
            let file = try await create(volume, root: root, name: name)
            await retired(); VolumeQueueProbe.reset()
            let gate = ReplyGate(volume, root: root, name: name)
            await until("xattr race held") { gate.entered.access { $0 } }
            var jobs: [Task<Int, Never>] = []
            var teardown: Task<Int32, Never>?
            for index in 0..<32 {
                jobs.append(setXattr(volume, item: file, name: "queue.race.\(index)", bytes: 4096,
                                     value: UInt8(index + 1), done: done))
                if index == 15 { teardown = Task.detached { await volume.teardown() } }
            }
            await until("xattr race classified") { VolumeQueueProbe.snapshot.submitted + done.access { $0 } == 34 }
            jobs.forEach { $0.cancel() }
            gate.release()
            var codes: [Int] = []
            for job in jobs { codes.append(await job.value) }
            let result = await teardown!.value
            precondition(result == 0 && cleaned.access { $0 } == 1 && done.access { $0 } == 32)
            await retired(); VolumeQueueProbe.checkTeardownLast()
            precondition(Payload.snapshot.consumed == codes.filter { $0 == 0 }.count)
            verifyXattrs(image, ino: (file as! ntfs3gItem).ino, prefix: "queue.race.", codes: codes, bytes: 4096)
            print("XATTR_ADMISSION_RACE round=\(round + 1) accepted=\(Payload.snapshot.consumed) released=\(Payload.snapshot.freed)")
        }
        print("PASS: racing xattr/teardown admission keeps every accepted payload and excludes every rejected attribute")
    }
    static func main() async throws {
        setbuf(stdout, nil)
        DispatchQueue.global().asyncAfter(deadline: .now() + 110) { _exit(124) }
        let args = Array(CommandLine.arguments.dropFirst())
        precondition(args.first == "all" || args.first == "xattr-retirement")
        let paths = Array(args.dropFirst())
        if args[0] == "xattr-retirement" {
            precondition(paths.count == 1)
            try await xattrRetirement(paths[0])
            try await xattrAdmissionRace(paths[0])
            return
        }
        precondition(paths.count == 6)
        try await backlog(paths[0], count: 8, bytes: 256 << 10)
        try await backlog(paths[1], count: 32, bytes: 256 << 10)
        try await independent(Array(paths[2...3]))
        try await repeated(paths[4])
        try await admissionRace(paths[5])
        try await terminalSync(paths[5])
        try await terminalMount(paths[5])
        try await xattrRetirement(paths[5])
        try await xattrAdmissionRace(paths[5])
        await retired()
        print("PASS: actual volume/file-backend queue contract; no total RAM cap, system read-buffer or mounted FSKit/device claim")
    }
}
