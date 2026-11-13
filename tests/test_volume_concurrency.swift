import Foundation
import FSKit
import Darwin

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class ItemHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var item: FSItem?
    func store(_ value: FSItem) { lock.withLock { item = value } }
    var value: FSItem { lock.withLock { item! } }
}

@main
struct VolumeConcurrencyTests {
    static func waitForRead() async {
        let entered = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: nfsk_test_wait_for_read() != 0)
            }
        }
        precondition(entered, "The read did not reach the injected pause")
    }

    static func verifyReplyHandoff(_ volume: ntfs3gVolume, root: FSItem) async throws {
        for operation in 0..<3 {
            let entered = Counter(), reclaimStarted = Counter(), reclaimed = Counter()
            let holder = ItemHolder(), release = DispatchSemaphore(value: 0)
            let reply: (FSItem?, FSFileName?, Error?) -> Void = { item, name, error in
                precondition(error == nil && item != nil && name != nil)
                holder.store(item!)
                entered.increment()
                precondition(release.wait(timeout: .now() + 5) == .success)
            }
            switch operation {
            case 0:
                volume.lookupItem(named: FSFileName(string: "QueuedWrites.bin"), inDirectory: root, replyHandler: reply)
            case 1:
                volume.createItem(named: FSFileName(string: "ReplyHandoff.bin"), type: .file,
                    inDirectory: root, attributes: FSItem.SetAttributesRequest(), replyHandler: reply)
            default:
                volume.createSymbolicLink(named: FSFileName(string: "ReplyHandoff.link"), inDirectory: root,
                    attributes: FSItem.SetAttributesRequest(), linkContents: FSFileName(string: "QueuedWrites.bin"), replyHandler: reply)
            }
            try await waitFor(entered, count: 1)
            let reclaim = Task.detached {
                reclaimStarted.increment()
                try await volume.reclaimItem(holder.value)
                reclaimed.increment()
            }
            try await waitFor(reclaimStarted, count: 1)
            try await Task.sleep(nanoseconds: 50_000_000)
            precondition(reclaimed.value == 0, "Reclaim crossed an unfinished item-reply handoff")
            release.signal()
            try await reclaim.value
            precondition(reclaimed.value == 1)
        }
        print("PASS: lookup/create/symlink reply handoffs exclude concurrent reclaim")
    }

    private static func load(_ fs: ntfs3gFileSystem, resource: FSResource, options: [String] = [], returned: Counter? = nil) async throws -> ntfs3gVolume {
        try await withCheckedThrowingContinuation { continuation in
            fs.loadResource(resource: resource, mountOptions: options) { volume, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: volume as! ntfs3gVolume) }
            }
            returned?.increment()
        }
    }

    static func verifyResourceLifecycle(_ image: String) async throws {
        guard #available(macOS 26.0, *) else { return }
        let resource = FSPathURLResource(url: URL(fileURLWithPath: image), writable: false)
        let fs = ntfs3gFileSystem()
        let probeDone = Counter()
        nfsk_test_arm_read()
        defer { nfsk_test_release_read() }
        fs.probeResource(resource: resource) { result, error in
            precondition(error == nil && result != nil)
            probeDone.increment()
        }
        await waitForRead()
        precondition(probeDone.value == 0, "Probe must remain pending while backend read is paused")
        nfsk_test_release_read()
        try await waitFor(probeDone, count: 1)
        print("PASS: probe returns without blocking its caller on backend I/O")

        nfsk_test_arm_read()
        let loadReturned = Counter()
        let loading = Task { try await load(fs, resource: resource, returned: loadReturned) }
        await waitForRead()
        precondition(loadReturned.value == 1, "Load blocked its entry-point thread")
        do { _ = try await load(fs, resource: resource); preconditionFailure("Concurrent load was accepted") }
        catch { precondition((error as NSError).code == Int(EBUSY)) }
        nfsk_test_release_read()
        let volume = try await loading.value
        print("PASS: load suspends backend work and rejects a second live volume")

        nfsk_test_arm_read()
        let check = Task { try await volume.quickCheck() }
        await waitForRead()
        let completed = Counter()
        let unloads = (0..<2).map { _ in
            Task { () -> Int in
                defer { completed.increment() }
                do { try await fs.unloadResource(resource: resource); return 0 }
                catch { return (error as NSError).code }
            }
        }
        try await waitFor(completed, count: 1)
        precondition(volume.volumeStatistics.totalBlocks > 0, "Unload freed an in-flight check")
        do { _ = try await load(fs, resource: resource); preconditionFailure("Load replaced a retiring volume") }
        catch { precondition((error as NSError).code == Int(EBUSY)) }
        nfsk_test_release_read()
        try await check.value
        var results: [Int] = []
        for unload in unloads { results.append(await unload.value) }
        precondition(results.sorted() == [0, Int(EBUSY)] && volume.volumeStatistics.totalBlocks == 0)
        _ = try await load(fs, resource: resource)
        try await fs.unloadResource(resource: resource)
        print("PASS: load/unload/check lifetimes serialize publication and release without blocking control callbacks")

        let missing = FSPathURLResource(url: URL(fileURLWithPath: image + ".missing", isDirectory: false), writable: false)
        await withCheckedContinuation { continuation in
            fs.probeResource(resource: missing) { result, error in
                precondition(result?.result == .notRecognized && error == nil)
                continuation.resume()
            }
        }
        do { _ = try await load(fs, resource: missing); preconditionFailure("Missing resource loaded") }
        catch { precondition((error as NSError).code == Int(ENOENT)) }
        _ = try await load(fs, resource: resource)
        try await fs.unloadResource(resource: resource)
        print("PASS: failed load releases its reservation and permits the next load")
    }

    static func verifyReleaseErrors(_ image: String) async throws {
        guard #available(macOS 26.0, *) else { return }
        var terminalFailures = 0
        func expectSync(_ volume: ntfs3gVolume, _ code: Int, _ label: String, flags: FSSyncFlags = .wait) async {
            let actual: Int
            do { try await volume.synchronize(flags: flags); actual = 0 }
            catch { precondition((error as NSError).domain == NSPOSIXErrorDomain); actual = (error as NSError).code }
            print("TERMINAL_SYNC \(label) expected=\(code) returned=\(actual)")
            if actual != code { terminalFailures += 1 }
        }
        func expectMount(_ volume: ntfs3gVolume, _ code: Int, _ label: String) async {
            let actual: Int
            do { try await volume.mount(); actual = 0 }
            catch { precondition((error as NSError).domain == NSPOSIXErrorDomain); actual = (error as NSError).code }
            print("MOUNT_AVAILABILITY \(label) expected=\(code) returned=\(actual)")
            if actual != code { terminalFailures += 1 }
        }
        let resource = FSPathURLResource(url: URL(fileURLWithPath: image, isDirectory: false), writable: true)
        let fs = ntfs3gFileSystem()
        let volume = try await load(fs, resource: resource, options: ["rw"])
        _ = try await volume.activate(mountOptions: [])
        await expectMount(volume, 0, "activated-writable")
        nfsk_test_fail_next_sync()
        do { try await fs.unloadResource(resource: resource); preconditionFailure("Unload swallowed its flush error") }
        catch { precondition((error as NSError).code == Int(EIO)) }
        let repeated = await volume.teardown()
        precondition(repeated == -EIO && volume.volumeStatistics.totalBlocks == 0)
        await expectSync(volume, Int(EIO), "failed-unload")
        await expectMount(volume, Int(ENXIO), "failed-unload")
        await volume.unmount() // Nonthrowing callback reports the same terminal error.
        await expectSync(volume, Int(EIO), "failed-unload-after-unmount")
        let reloaded = try await load(fs, resource: resource, options: ["ro"])
        _ = try await reloaded.activate(mountOptions: ["ro"])
        await expectMount(reloaded, 0, "activated-readonly")
        try await reloaded.synchronize(flags: .wait)
        try await fs.unloadResource(resource: resource)
        await expectMount(reloaded, Int(ENXIO), "healthy-unload")

        let oldFreed = Counter(), replacementFreed = Counter(), statuses = Counter()
        let switching = try ntfs3gVolume(backend: backend(image, writable: true, cleanup: { oldFreed.increment() }),
            activationBackend: { _, _ in try backend(image, writable: false, cleanup: { replacementFreed.increment() }) },
            onContainerStatusChange: { _ in statuses.increment() })
        nfsk_test_fail_next_sync()
        do { _ = try await switching.activate(mountOptions: ["ro"]); preconditionFailure("Activation swallowed the old backend's error") }
        catch { precondition((error as NSError).code == Int(EIO)) }
        await expectSync(switching, Int(EIO), "failed-activation-release")
        await expectMount(switching, Int(ENXIO), "failed-activation-release")
        let switchRelease = await switching.teardown()
        print("TERMINAL_RELEASE failed-activation expected=\(-EIO) returned=\(switchRelease)")
        if switchRelease != -EIO { terminalFailures += 1 }
        await expectSync(switching, Int(EIO), "failed-activation-after-teardown", flags: .dWait)
        await expectMount(switching, Int(ENXIO), "failed-activation-after-teardown")
        precondition(oldFreed.value == 1 && replacementFreed.value == 1 && statuses.value == 0)

        let rejectedFreed = Counter()
        let rejected = try ntfs3gVolume(backend: backend(image, writable: true, cleanup: { rejectedFreed.increment() }),
            activationBackend: { _, _ in throw posixError(EACCES) }, onContainerStatusChange: { _ in })
        do { _ = try await rejected.activate(mountOptions: ["ro"]); preconditionFailure("Backend factory rejection ignored") }
        catch { precondition((error as NSError).code == Int(EACCES)) }
        try await rejected.synchronize(flags: .wait)
        await expectMount(rejected, 0, "factory-rejection-keeps-handle")
        precondition(rejected.volumeStatistics.totalBlocks > 0 && rejectedFreed.value == 0)
        let rejectedRelease = await rejected.teardown()
        precondition(rejectedRelease == 0 && rejectedFreed.value == 1)
        await expectMount(rejected, Int(ENXIO), "factory-rejection-after-teardown")

        let invalid = URL(fileURLWithPath: image + ".invalid", isDirectory: false)
        precondition(!FileManager.default.fileExists(atPath: invalid.path))
        try Data(repeating: 0, count: 4096).write(to: invalid)
        defer { try? FileManager.default.removeItem(at: invalid) }
        let validFreed = Counter(), invalidFreed = Counter(), invalidStatuses = Counter()
        let failedMount = try ntfs3gVolume(backend: backend(image, writable: true, cleanup: { validFreed.increment() }),
            activationBackend: { _, _ in try backend(invalid.path, writable: false, cleanup: { invalidFreed.increment() }) },
            onContainerStatusChange: { _ in invalidStatuses.increment() })
        do { _ = try await failedMount.activate(mountOptions: ["ro"]); preconditionFailure("Invalid replacement mounted") }
        catch { precondition((error as NSError).domain == NSPOSIXErrorDomain) }
        await expectSync(failedMount, Int(ENXIO), "unavailable-replacement")
        await expectMount(failedMount, Int(ENXIO), "unavailable-replacement")
        precondition(validFreed.value == 1 && invalidFreed.value == 0 && invalidStatuses.value == 0)
        let invalidRelease = await failedMount.teardown()
        precondition(invalidRelease == 0 && validFreed.value == 1 && invalidFreed.value == 1)
        try await failedMount.synchronize(flags: .wait)
        await expectMount(failedMount, Int(ENXIO), "unavailable-replacement-after-cleanup")
        precondition(terminalFailures == 0, "terminal release/sync/mount results were lost")
        print("PASS: unload and activation retain terminal sync errors, release once, distinguish unavailable handles, and preserve live handles after factory rejection")
    }
    static func backend(_ image: String, writable: Bool, cleanup: @escaping () -> Void = {}) throws -> NTFSBackend {
        var error: Int32 = 0
        guard let pointer = nfsk_backend_from_file(image, writable ? 1 : 0, &error) else { throw posixError(error) }
        return NTFSBackend(backend: pointer, retain: nil, cleanup: cleanup, writable: writable)
    }

    static func waitForWrite() async {
        let entered = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: nfsk_test_wait_for_write() != 0)
            }
        }
        precondition(entered, "The write did not reach the injected pause")
    }

    private static func waitFor(_ counter: Counter, count: Int) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while counter.value != count {
            precondition(DispatchTime.now().uptimeNanoseconds < deadline, "Swift tasks did not make progress")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    static func assertPropertiesRespond(_ volume: ntfs3gVolume, expected: FSStatFSResult) async {
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async(execute: DispatchWorkItem {
            let snapshot = volume.volumeStatistics
            precondition(snapshot.blockSize == expected.blockSize && snapshot.ioSize == expected.ioSize &&
                         snapshot.totalBlocks == expected.totalBlocks && snapshot.freeBlocks == expected.freeBlocks &&
                         snapshot.availableBlocks == expected.availableBlocks && snapshot.usedBlocks == expected.usedBlocks &&
                         snapshot.totalFiles == expected.totalFiles && snapshot.freeFiles == expected.freeFiles,
                         "A pending I/O must expose the last completed statistics snapshot")
            if #available(macOS 26.4, *) { precondition(!volume.requestedMountOptions.contains(.readOnly)) }
            finished.signal()
        })
        let responsive = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: finished.wait(timeout: .now() + 2) == .success)
            }
        }
        precondition(responsive, "Synchronous FSKit properties waited for disk I/O")
    }

    static func verifyPersistedWrites(_ image: String, queuedCount: Int, statistics: FSStatFSResult) throws {
        let source = try backend(image, writable: false)
        defer { nfsk_backend_free(source.backend); source.cleanup() }
        var error: Int32 = 0
        guard let handle = nfsk_mount(source.backend, true, &error) else { throw posixError(error) }
        defer { nfsk_umount(handle) }
        let ino = nfsk_lookup(handle, NFSK_ROOT_INO, "QueuedWrites.bin", &error)
        precondition(ino != 0)
        var bytes = [UInt8](repeating: 0, count: 8192)
        let count = bytes.withUnsafeMutableBytes { nfsk_read(handle, ino, 0, $0.baseAddress, Int64($0.count), &error) }
        precondition(count == 8192 && bytes.allSatisfy { $0 == 0x5a })
        for index in 0..<queuedCount {
            bytes = [UInt8](repeating: 0, count: 4096)
            let count = bytes.withUnsafeMutableBytes {
                nfsk_read(handle, ino, Int64(8192 + index * 4096), $0.baseAddress, Int64($0.count), &error)
            }
            precondition(count == 4096 && bytes.allSatisfy { $0 == UInt8(index % 256) }, "Queued write lost its buffer")
        }
        var stats = nfsk_statfs_t()
        precondition(nfsk_statfs(handle, &stats) == 0 &&
                     Int(stats.cluster_size) == statistics.blockSize && statistics.ioSize == statistics.blockSize &&
                     stats.total_clusters == statistics.totalBlocks && stats.free_clusters == statistics.freeBlocks &&
                     stats.free_clusters == statistics.availableBlocks &&
                     statistics.usedBlocks == stats.total_clusters - stats.free_clusters &&
                     stats.total_files == statistics.totalFiles && stats.free_files == statistics.freeFiles,
                     "Published statistics disagree with independently remounted data")
    }

    static func verifyXattrLifetime(_ image: String) async throws {
        let root = ntfs3gItem(ino: NFSK_ROOT_INO, parentIno: NFSK_PARENT_OF_ROOT, name: FSFileName(string: "/"))
        let name = FSFileName(string: "test.cancelled-read")
        let payload = Data(repeating: 0x63, count: Int(NFSK_MAX_XATTR_SIZE))
        for list in [false, true] {
            let cleaned = Counter(), started = Counter(), finished = Counter()
            let volume = try ntfs3gVolume(backend: backend(image, writable: true, cleanup: { cleaned.increment() }),
                activationBackend: { _, _ in nil }, onContainerStatusChange: { _ in })
            try await volume.setXattr(named: name, to: payload, on: root, policy: .alwaysSet)
            let stats = volume.volumeStatistics
            nfsk_test_arm_read()
            defer { nfsk_test_release_read() }
            let reading = Task.detached { () -> Data in
                if list {
                    let names = try await volume.xattrs(of: root)
                    precondition(names.count == 1 && names[0].string == name.string)
                    return Data(names[0].string!.utf8)
                }
                return try await volume.xattr(named: name, of: root)
            }
            await waitForRead()
            reading.cancel()
            let teardown = Task.detached {
                started.increment()
                let result = await volume.teardown()
                finished.increment()
                return result
            }
            try await waitFor(started, count: 1)
            try await Task.sleep(nanoseconds: 50_000_000)
            precondition(cleaned.value == 0 && finished.value == 0, "Teardown crossed a pending xattr read")
            await assertPropertiesRespond(volume, expected: stats)
            nfsk_test_release_read()
            let result = try await reading.value
            let teardownResult = await teardown.value
            precondition(teardownResult == 0 && cleaned.value == 1 && finished.value == 1)
            precondition(result == (list ? Data(name.string!.utf8) : payload),
                         "Cancelled xattr read lost its output during teardown")
        }
        print("PASS: cancelled xattr value/list reads retain buffers and exclude teardown until completion")
    }

    static func verifyEnumerationErrors(_ image: String) async throws {
        let volume = try ntfs3gVolume(backend: backend(image, writable: true),
            activationBackend: { _, _ in nil }, onContainerStatusChange: { _ in })
        let root = ntfs3gItem(ino: NFSK_ROOT_INO, parentIno: NFSK_PARENT_OF_ROOT, name: FSFileName(string: "/"))
        let ops = volume as any FSVolume.Operations
        let (dir, _) = try await ops.createItem(named: FSFileName(string: "EnumFaults"), type: .directory,
            inDirectory: root, attributes: FSItem.SetAttributesRequest())
        let (file, _) = try await ops.createItem(named: FSFileName(string: "File"), type: .file,
            inDirectory: dir, attributes: FSItem.SetAttributesRequest())
        let request = FSItem.GetAttributesRequest()
        request.wantedAttributes = [.size, .fileID]
        let called = Counter(), before = nfsk_test_inode_faults()
        nfsk_test_fail_inode_open((file as! ntfs3gItem).ino)
        do {
            _ = try await volume.enumerateDirectory(dir, startingAt: FSDirectoryCookie(rawValue: 2),
                verifier: FSDirectoryVerifier(rawValue: 1), attributes: request,
                packer: nfsk_test_packer { _, _, _, _, _ in called.increment(); return true })
            preconditionFailure("Enumeration hid a requested attribute-read failure")
        } catch { precondition((error as NSError).code == Int(EIO)) }
        precondition(called.value == 0 && nfsk_test_inode_faults() == before + 1)
        for wantAttributes in [false, true] {
            let before = nfsk_test_inode_faults()
            do {
                _ = try await volume.enumerateDirectory(dir, startingAt: FSDirectoryCookie(rawValue: 2),
                    verifier: FSDirectoryVerifier(rawValue: 1), attributes: wantAttributes ? request : nil,
                    packer: nfsk_test_packer { _, _, _, _, _ in
                        nfsk_test_fail_inode_close((dir as! ntfs3gItem).ino)
                        return false
                    })
                preconditionFailure("Packer rejection hid a directory-close failure")
            } catch { precondition((error as NSError).code == Int(EIO)) }
            precondition(nfsk_test_inode_faults() == before + 1)
            do { try await volume.synchronize(flags: .wait); preconditionFailure("Lost saved close error") }
            catch { precondition((error as NSError).code == Int(EIO)) }
            try await volume.synchronize(flags: .wait)
        }
        var count = 0
        _ = try await volume.enumerateDirectory(dir, startingAt: FSDirectoryCookie(rawValue: 2),
            verifier: FSDirectoryVerifier(rawValue: 1), attributes: request,
            packer: nfsk_test_packer { _, _, _, _, attrs in precondition(attrs != nil); count += 1; return true })
        precondition(count == 1)
        let closed = await volume.teardown()
        precondition(closed == 0)
        print("PASS: requested attributes and rejected packer entries propagate real errors and recover through sync")
    }

    static func verifyEnumerationLifetime(_ image: String) async throws {
        let cleaned = Counter(), started = Counter(), finished = Counter(), armed = Counter()
        let volume = try ntfs3gVolume(backend: backend(image, writable: true, cleanup: { cleaned.increment() }),
            activationBackend: { _, _ in nil }, onContainerStatusChange: { _ in })
        let root = ntfs3gItem(ino: NFSK_ROOT_INO, parentIno: NFSK_PARENT_OF_ROOT, name: FSFileName(string: "/"))
        let ops = volume as any FSVolume.Operations
        let (dir, _) = try await ops.createItem(named: FSFileName(string: "EnumPaused"), type: .directory,
            inDirectory: root, attributes: FSItem.SetAttributesRequest())
        for i in 0..<3 {
            _ = try await ops.createItem(named: FSFileName(string: "File\(i)"), type: .file,
                inDirectory: dir, attributes: FSItem.SetAttributesRequest())
        }
        let stats = volume.volumeStatistics
        let reading = Task.detached { () -> [FSItem.Attributes] in
            var values: [FSItem.Attributes] = []
            let request = FSItem.GetAttributesRequest()
            request.wantedAttributes = [.size, .fileID, .parentID]
            _ = try await volume.enumerateDirectory(dir, startingAt: FSDirectoryCookie(rawValue: 0),
                verifier: FSDirectoryVerifier(rawValue: 1), attributes: request,
                packer: nfsk_test_packer { _, _, _, _, attrs in
                    precondition(attrs != nil)
                    values.append(attrs!)
                    if values.count == 1 {
                        nfsk_test_arm_read()
                        armed.increment()
                    }
                    return true
                })
            return values
        }
        defer { nfsk_test_release_read() }
        // The gate is armed inside the first callback, not before spawning the
        // task. Wait for this generation before inspecting its entered flag;
        // the previous lifetime test may have left that flag true after release.
        try await waitFor(armed, count: 1)
        await waitForRead()
        reading.cancel()
        let teardown = Task.detached {
            started.increment()
            let result = await volume.teardown()
            finished.increment()
            return result
        }
        try await waitFor(started, count: 1)
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(cleaned.value == 0 && finished.value == 0)
        await assertPropertiesRespond(volume, expected: stats)
        nfsk_test_release_read()
        let values = try await reading.value
        let result = await teardown.value
        precondition(result == 0 && cleaned.value == 1 && values.count == 3)
        precondition(Set(values.map(\.fileID)).count == 3 && values.allSatisfy { $0.parentID.rawValue == (dir as! ntfs3gItem).ino })
        print("PASS: cancelled attribute enumeration excludes teardown and returned attributes outlive the C callback and backend")
    }

    static func main() async throws {
        setbuf(stdout, nil)
        // Only this disposable-image test process exits on a hang.
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
            fputs("FAIL: concurrency test timed out\n", stderr)
            _exit(124)
        }
        let image = CommandLine.arguments[1]
        let volume = try ntfs3gVolume(backend: backend(image, writable: true),
            activationBackend: { _, _ in nil }, onContainerStatusChange: { _ in })
        let root = ntfs3gItem(ino: NFSK_ROOT_INO, parentIno: NFSK_PARENT_OF_ROOT, name: FSFileName(string: "/"))
        let (item, _) = try await (volume as any FSVolume.Operations).createItem(named: FSFileName(string: "QueuedWrites.bin"), type: .file,
                                                   inDirectory: root, attributes: FSItem.SetAttributesRequest())
        let before = volume.volumeStatistics
        nfsk_test_arm_write()
        defer { nfsk_test_release_write() }
        let firstWrite = Task.detached { try await volume.write(contents: Data(repeating: 0x5a, count: 8192), to: item, at: 0) }
        await waitForWrite()
        firstWrite.cancel() // Cancellation cannot free a buffer still used by synchronous I/O.
        await assertPropertiesRespond(volume, expected: before)
        print("PASS: volumeStatistics and requestedMountOptions respond while pwrite is paused")

        let started = Counter(), completed = Counter()
        let queuedCount = max(64, ProcessInfo.processInfo.activeProcessorCount * 2)
        let writes = (0..<queuedCount).map { index in
            Task.detached {
                started.increment()
                let count = try await volume.write(contents: Data(repeating: UInt8(index % 256), count: 4096),
                                                   to: item, at: off_t(8192 + index * 4096))
                completed.increment()
                return count
            }
        }
        try await waitFor(started, count: queuedCount)
        let heartbeat = await Task.detached { 42 }.value
        precondition(heartbeat == 42 && completed.value == 0, "Writes must remain serialized behind the paused I/O")
        await assertPropertiesRespond(volume, expected: before)
        print("PASS: \(queuedCount) waiting writes suspend and an unrelated Swift task still runs")
        nfsk_test_release_write()
        let firstCount = try await firstWrite.value
        precondition(firstCount == 8192)
        for write in writes {
            let count = try await write.value
            precondition(count == 4096)
        }
        precondition(completed.value == queuedCount)
        try await volume.synchronize(flags: .wait)
        let after = volume.volumeStatistics
        precondition(after.freeBlocks < before.freeBlocks && after.totalBlocks == before.totalBlocks)
        try await verifyReplyHandoff(volume, root: root)
        let finalStatistics = volume.volumeStatistics
        await volume.teardown()
        try verifyPersistedWrites(image, queuedCount: queuedCount, statistics: finalStatistics)
        print("PASS: queued writes persist intact and completed writes refresh free-space statistics")

        let cleaned = Counter(), teardownStarted = Counter(), teardownCompleted = Counter()
        let closing = try ntfs3gVolume(backend: backend(image, writable: true, cleanup: { cleaned.increment() }),
            activationBackend: { _, _ in nil }, onContainerStatusChange: { _ in })
        let (heldItem, _) = try await (closing as any FSVolume.Operations).lookupItem(named: FSFileName(string: "QueuedWrites.bin"), inDirectory: root)
        let closingStats = closing.volumeStatistics
        nfsk_test_arm_write()
        let lastWrite = Task.detached { try await closing.write(contents: Data(repeating: 0x33, count: 8192), to: heldItem, at: 0) }
        await waitForWrite()
        let teardown = Task.detached {
            teardownStarted.increment()
            await closing.teardown()
            teardownCompleted.increment()
        }
        try await waitFor(teardownStarted, count: 1)
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(cleaned.value == 0 && teardownCompleted.value == 0, "Teardown freed an in-flight backend")
        await assertPropertiesRespond(closing, expected: closingStats)
        nfsk_test_release_write()
        let lastCount = try await lastWrite.value
        precondition(lastCount == 8192)
        await teardown.value
        await closing.teardown()
        let retired = closing.volumeStatistics
        precondition(cleaned.value == 1 && retired.totalBlocks == 0 && retired.freeBlocks == 0 &&
                     retired.availableBlocks == 0 && retired.usedBlocks == 0 &&
                     retired.totalFiles == 0 && retired.freeFiles == 0 &&
                     retired.blockSize == 4096 && retired.ioSize == 4096)
        print("PASS: teardown waits for in-flight I/O, releases the backend once and clears statistics")
        try await verifyResourceLifecycle(image)
        try await verifyReleaseErrors(image)
        try await verifyXattrLifetime(image)
        try await verifyEnumerationErrors(image)
        try await verifyEnumerationLifetime(image)
    }
}
