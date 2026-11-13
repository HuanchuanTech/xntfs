import Foundation
import Darwin

@MainActor
private final class Publications {
    var values: [[NTFSDevice]] = []
}

@main
@MainActor
struct HostObservationTests {
    static func flushMain() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private static func monitor(_ count: UInt32, publications: Publications? = nil) async -> DiskArbitrationMonitor {
        let monitor = DiskArbitrationMonitor()!
        monitor.onDevicesChanged = { values in
            dispatchPrecondition(condition: .onQueue(.main))
            publications?.values.append(values)
        }
        monitor.start()
        xntfs_observation_drain(monitor.sessionRef())
        for index in 0..<count { xntfs_observation_emit(monitor.sessionRef(), index, 0) }
        await flushMain()
        precondition(monitor.currentDevices.count == Int(count))
        return monitor
    }

    static func diagnostics(_ monitor: DiskArbitrationMonitor) async -> [NTFSDevice] {
        do { return try await monitor.devicesForDiagnostics().devices }
        catch { preconditionFailure("Unexpected diagnostic query failure: \(error)") }
    }

    static func refresh(_ monitor: DiskArbitrationMonitor) async {
        monitor.refresh()
        xntfs_observation_drain(monitor.sessionRef())
        await flushMain()
    }

    static func checkUnmountedRecovery() async {
        xntfs_observation_reset(1, 16)
        xntfs_observation_set_kind(0, "ntfs")
        xntfs_observation_set_path(0, 0)
        // Unmounted media has no entry in the kernel mount table.
        xntfs_observation_set_entry(0, "/dev/unrelated", "/Volumes/Unrelated", "apfs")
        let monitor = await monitor(1)
        let original = monitor.currentDevices[0]
        precondition(!original.state.isMounted)
        xntfs_observation_set_missing(0, false, true)
        xntfs_observation_emit(monitor.sessionRef(), 0, 1)
        await flushMain()
        precondition(monitor.currentDevices.isEmpty)
        xntfs_observation_set_missing(0, false, false)
        await refresh(monitor)
        print("Unmounted recovery after description failure: \(monitor.currentDevices.count) devices")
        precondition(monitor.currentDevices.count == 1,
                     "Refresh cannot recover an unmounted device after one description failure")
        let recovered = monitor.currentDevices[0]
        precondition(!recovered.state.isMounted && recovered.mountedFileSystemType == nil)
        precondition(recovered.registryEntryID == original.registryEntryID && !recovered.isSameDevice(as: original))
        await refresh(monitor)
        precondition(monitor.currentDevices[0].isSameDevice(as: recovered))
        print("PASS: unmounted description recovery needs no mount-table row or new DA event; fresh identity then remains stable")
    }

    static func configureUnmounted(_ count: UInt32) {
        xntfs_observation_reset(count, max(count, 16))
        for index in 0..<count {
            xntfs_observation_set_kind(index, "ntfs")
            xntfs_observation_set_path(index, 0)
            xntfs_observation_set_entry(index, "/dev/unrelated", "/Volumes/Unrelated", "apfs")
        }
    }

    static func checkMediaRecoveryFiltering() async {
        configureUnmounted(8)
        xntfs_observation_set_kind(1, "exfat")
        xntfs_observation_set_kind(2, "") // Existing leaf/content-hint fallback.
        xntfs_observation_set_leaf(3, false)
        xntfs_observation_set_missing(4, true, false)
        xntfs_observation_set_missing(5, false, true)
        xntfs_observation_set_path(6, 3) // Non-file path.
        xntfs_observation_set_path(7, 2) // No matching mount point.
        let publications = Publications()
        let monitor = await monitor(0, publications: publications)
        await refresh(monitor)
        precondition(monitor.currentDevices.map(\.id) == ["diskTest0", "diskTest2"])
        precondition(publications.values.count == 1 && xntfs_observation_mount_calls() == 1)
        precondition(xntfs_observation_enumeration_calls() == 1 && xntfs_observation_media_disk_requests() == 8)
        precondition(xntfs_observation_disk_requests() == 0)
        let original = monitor.currentDevices
        let observation = await diagnostics(monitor)
        xntfs_observation_emit(monitor.sessionRef(), 1, 1)
        precondition(observation.count == 2 && xntfs_observation_enumeration_calls() == 1,
                     "Diagnostics/callbacks unexpectedly enumerated registered media")
        xntfs_observation_set_leaf(3, true)
        xntfs_observation_set_missing(4, false, false)
        xntfs_observation_set_missing(5, false, false)
        xntfs_observation_set_path(6, 0); xntfs_observation_set_path(7, 0)
        await refresh(monitor)
        precondition(monitor.currentDevices.count == 7 && monitor.currentDevices.allSatisfy { !$0.state.isMounted })
        precondition(original.allSatisfy { old in monitor.currentDevices.contains { $0.isSameDevice(as: old) } })
        xntfs_observation_set_enumeration(0, -1, true)
        xntfs_observation_reset_counts(); publications.values.removeAll()
        await refresh(monitor)
        precondition(xntfs_observation_enumeration_calls() == 1 && xntfs_observation_media_disk_requests() == 16)
        precondition(publications.values.count == 1 && monitor.currentDevices.count == 7,
                     "Repeated media candidates duplicated an observation/publication")
        print("PASS: missed unmounted appearances recover; format/leaf/completeness filters and per-operation dedup remain; diagnostics/callbacks do not scan")
    }

    static func checkMediaEnumerationFailures() async {
        configureUnmounted(3)
        let monitor = await monitor(1)
        let original = monitor.currentDevices[0]
        let registrations = xntfs_observation_registration_calls()
        for failure in 1...3 {
            xntfs_observation_set_enumeration(Int32(failure), -1, false)
            xntfs_observation_reset_counts()
            await refresh(monitor)
            precondition(monitor.currentDevices.count == 1 && monitor.currentDevices[0].isSameDevice(as: original))
            precondition(xntfs_observation_enumeration_calls() == 1 && xntfs_observation_media_disk_requests() == 0)
            precondition(xntfs_observation_iterators_live() == 0 && xntfs_observation_media_live() == 0,
                         "Failed/null enumeration retained an owned iterator/media")
        }
        xntfs_observation_set_enumeration(0, 2, false) // Invalidate after known0 plus new1.
        xntfs_observation_reset_counts()
        await refresh(monitor)
        precondition(monitor.currentDevices.map(\.id) == ["diskTest0", "diskTest1"])
        precondition(xntfs_observation_enumeration_calls() == 1 && xntfs_observation_media_disk_requests() == 2,
                     "Invalid iterator triggered a restart loop")
        precondition(xntfs_observation_iterators_live() == 0 && xntfs_observation_media_live() == 0)
        xntfs_observation_set_enumeration(0, -1, false)
        await refresh(monitor)
        precondition(monitor.currentDevices.count == 3 && monitor.currentDevices[0].isSameDevice(as: original))
        let beforeRemoval = monitor.currentDevices[1]
        xntfs_observation_set_missing(1, true, false)
        xntfs_observation_emit(monitor.sessionRef(), 1, 2)
        await refresh(monitor)
        precondition(monitor.currentDevices.map(\.id) == ["diskTest0", "diskTest2"])
        xntfs_observation_set_registry(1, 9001); xntfs_observation_set_missing(1, false, false)
        await refresh(monitor)
        precondition(monitor.currentDevices[1].registryEntryID == 9001 && !monitor.currentDevices[1].isSameDevice(as: beforeRemoval))
        precondition(xntfs_observation_registration_calls() == registrations)
        print("PASS: failed/null/invalidated traversal retires ownership, keeps confirmed rows, retries next refresh and isolates reused BSD identities")
    }

    static func checkMediaEnumerationOverlap() async {
        configureUnmounted(2)
        let first = await monitor(0), second = await monitor(0)
        xntfs_observation_reset_counts()
        xntfs_observation_hold_next_enumeration(); first.refresh(); xntfs_observation_wait_held()
        precondition(xntfs_observation_iterators_live() == 1)
        for _ in 0..<256 { first.refresh() }
        await refresh(second)
        precondition(second.currentDevices.count == 2 && first.currentDevices.isEmpty)
        precondition(xntfs_observation_iterators_live() == 1 && xntfs_observation_iterators_peak() == 2)
        xntfs_observation_release_and_drain(first.sessionRef()); await flushMain()
        precondition(first.currentDevices.count == 2 && xntfs_observation_enumeration_calls() == 3,
                     "Queued refresh callers each retained a media traversal")
        precondition(xntfs_observation_iterators_live() == 0 && xntfs_observation_media_live() == 0)
        print("PASS: two monitor iterators coexist independently; 256 queued callers add only one follow-up; all handles retire")
    }

    static func checkRepeatedUnmountedRecovery() async {
        configureUnmounted(4)
        let first = await monitor(0), second = await monitor(0)
        for cycle in 0..<32 {
            for index in 0..<4 {
                xntfs_observation_set_missing(UInt32(index), false, true)
                xntfs_observation_emit(first.sessionRef(), UInt32(index), 1)
                xntfs_observation_emit(second.sessionRef(), UInt32(index), 1)
            }
            precondition(first.currentDevices.isEmpty && second.currentDevices.isEmpty)
            for index in 0..<4 { xntfs_observation_set_missing(UInt32(index), false, false) }
            first.refresh(); second.refresh()
            xntfs_observation_drain(first.sessionRef()); xntfs_observation_drain(second.sessionRef())
            await flushMain()
            precondition(first.currentDevices.count == 4 && second.currentDevices.count == 4)
            precondition(xntfs_observation_enumeration_calls() == UInt32((cycle + 1) * 2))
            precondition(xntfs_observation_iterators_live() == 0 && xntfs_observation_media_live() == 0)
        }
        precondition(xntfs_observation_iterators_peak() <= 2 && xntfs_observation_media_peak() <= 4)
        print("PASS: 32 unmounted loss/recovery cycles across two monitors; bounded iterator/media ownership and no retained history")
    }

    static func checkQueuedRefreshes() async {
        xntfs_observation_reset(8, 64)
        let publications = Publications()
        let monitor = await monitor(8, publications: publications)
        let original = monitor.currentDevices
        publications.values.removeAll()
        xntfs_observation_reset_counts()
        xntfs_observation_hold_queue(monitor.sessionRef())
        xntfs_observation_wait_held()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<128 { monitor.refresh() }
        }
        xntfs_observation_release_and_drain(monitor.sessionRef())
        await flushMain()
        precondition(xntfs_observation_mount_calls() == 1, "Queued refresh burst was not coalesced")
        precondition(xntfs_observation_disk_requests() == 8 && publications.values.count == 1)
        precondition(zip(original, monitor.currentDevices).allSatisfy { $0.isSameDevice(as: $1) })
        await refresh(monitor)
        precondition(xntfs_observation_mount_calls() == 2 && publications.values.count == 2,
                     "Retired refresh kept admission closed")
        print("PASS: 1024 concurrent queued refresh calls coalesce; later refresh and identity/publications remain correct")
    }

    static func checkActiveRefreshes() async {
        xntfs_observation_reset(2, 32)
        let publications = Publications()
        let monitor = await monitor(2, publications: publications)
        let original = monitor.currentDevices
        publications.values.removeAll()
        xntfs_observation_reset_counts()
        xntfs_observation_hold_next_table()
        monitor.refresh()
        xntfs_observation_wait_held()
        // The active refresh already copied the old table. Only table bytes are
        // changed at this gate; DA fixture descriptions stay immutable.
        xntfs_observation_set_mount(0, "ntfs", false)
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            for _ in 0..<128 { monitor.refresh() }
        }
        xntfs_observation_release_and_drain(monitor.sessionRef())
        await flushMain()
        precondition(xntfs_observation_mount_calls() == 2 && xntfs_observation_disk_requests() == 4,
                     "Active refresh did not admit exactly one follow-up")
        precondition(publications.values.count == 1)
        precondition(publications.values[0][0].mountedFileSystemType == "ntfs" && !publications.values[0][0].readOnly,
                     "Delayed main delivery did not consume the latest completed refresh")
        precondition(monitor.currentDevices[0].mountedFileSystemType == "ntfs" && !monitor.currentDevices[0].readOnly,
                     "Request during active work lost the newer metadata")
        precondition(zip(original, monitor.currentDevices).allSatisfy { $0.isSameDevice(as: $1) })

        // A failed active snapshot may drop the only trustworthy observation;
        // its admitted follow-up must still rediscover it without another event.
        xntfs_observation_reset_counts()
        xntfs_observation_hold_next_table()
        xntfs_observation_fail_next_table()
        monitor.refresh()
        xntfs_observation_wait_held()
        for _ in 0..<64 { monitor.refresh() }
        xntfs_observation_release_and_drain(monitor.sessionRef())
        await flushMain()
        precondition(xntfs_observation_mount_calls() == 3 && monitor.currentDevices.count == 2)
        precondition(!monitor.currentDevices[0].isSameDevice(as: original[0]))
        print("PASS: active snapshot admits one fresh follow-up, including failure and rediscovery")
    }

    static func checkRefreshIsolation() async {
        xntfs_observation_reset(1, 32)
        let first = await monitor(1), second = await monitor(1)
        xntfs_observation_reset_counts()
        xntfs_observation_hold_queue(first.sessionRef())
        xntfs_observation_wait_held()
        for _ in 0..<128 { first.refresh() }
        await refresh(second)
        precondition(xntfs_observation_mount_calls() == 1, "One monitor blocked another")
        let diagnostic = await diagnostics(second)
        precondition(diagnostic.count == 1 && xntfs_observation_mount_calls() == 2)
        xntfs_observation_release_and_drain(first.sessionRef())
        await flushMain()
        precondition(xntfs_observation_mount_calls() == 3)
        // Diagnostics and DA callbacks each retain their own operation/snapshot.
        async let one = diagnostics(first)
        async let two = diagnostics(first)
        let values = await (one, two)
        precondition(values.0.count == 1 && values.1.count == 1 && xntfs_observation_mount_calls() == 5)
        xntfs_observation_emit(first.sessionRef(), 0, 1)
        precondition(xntfs_observation_mount_calls() == 6)
        print("PASS: refresh admission is per monitor; diagnostics and DA callbacks remain independent")
    }

    static func checkQueuedRefreshRetirement() async {
        xntfs_observation_reset(1, 32)
        var retiring: DiskArbitrationMonitor? = await monitor(1)
        weak let witness = retiring
        let session = retiring!.sessionRef()
        xntfs_observation_reset_counts()
        xntfs_observation_hold_queue(session)
        xntfs_observation_wait_held()
        for _ in 0..<128 { retiring!.refresh() }
        retiring = nil
        precondition(witness == nil, "Queued refresh retained the monitor")
        xntfs_observation_release_and_drain(session)
        await flushMain()
        precondition(xntfs_observation_mount_calls() == 0 && xntfs_observation_sessions() == 0)
        print("PASS: queued refresh does not keep monitor/session alive or query after teardown")
    }

    static func checkRepeatedRefreshAdmission() async {
        xntfs_observation_reset(8, 128)
        let monitor = await monitor(8)
        let original = monitor.currentDevices
        let registrations = xntfs_observation_registration_calls()
        xntfs_observation_reset_counts()
        for cycle in 0..<100 {
            xntfs_observation_hold_queue(monitor.sessionRef())
            xntfs_observation_wait_held()
            for _ in 0..<128 { monitor.refresh() }
            xntfs_observation_release_and_drain(monitor.sessionRef())
            await flushMain()
            precondition(xntfs_observation_mount_calls() == UInt32(cycle + 1))
            precondition(zip(original, monitor.currentDevices).allSatisfy { $0.isSameDevice(as: $1) })
            #if REFRESH_LIFETIME_PROBE
            RefreshAdmissionProbe.checkRetired()
            #endif
        }
        precondition(xntfs_observation_registration_calls() == registrations)
        print("PASS: 100 blocked bursts retire admission and preserve identity without repeated registration")
    }

    static func checkBatch() async {
        xntfs_observation_reset(8, 64)
        let publications = Publications()
        let monitor = await monitor(8, publications: publications)
        let original = monitor.currentDevices
        precondition(publications.values.count == 1)
        precondition(original.allSatisfy { $0.mountedFileSystemType == "xntfs" })
        precondition(original[0].readOnly && !original[1].readOnly)

        xntfs_observation_reset_counts()
        let diagnostic = await diagnostics(monitor)
        xntfs_observation_drain(monitor.sessionRef())
        precondition(diagnostic.count == 8 && diagnostic.map(\.id) == original.map(\.id))
        precondition(xntfs_observation_mount_calls() == 1, "Diagnostics copied a table per device")
        precondition(publications.values.count == 1, "Diagnostics published a device update")

        xntfs_observation_reset_counts()
        await refresh(monitor)
        precondition(xntfs_observation_mount_calls() == 1, "Refresh copied a table per device")
        precondition(publications.values.count == 2, "Refresh lost its latest-state publication")
        precondition(zip(original, monitor.currentDevices).allSatisfy { $0.isSameDevice(as: $1) })
        precondition(publications.values.allSatisfy { $0.count == 8 && $0.map(\.id) == original.map(\.id) })

        // Standalone callbacks must observe fresh flags, not the previous batch's table.
        xntfs_observation_reset_counts()
        xntfs_observation_set_mount(0, "ntfs", false)
        xntfs_observation_emit(monitor.sessionRef(), 0, 1)
        precondition(monitor.currentDevices[0].mountedFileSystemType == "ntfs" && !monitor.currentDevices[0].readOnly)
        xntfs_observation_set_mount(0, "xntfs", true)
        xntfs_observation_emit(monitor.sessionRef(), 0, 1)
        precondition(xntfs_observation_mount_calls() == 2 && monitor.currentDevices[0].readOnly)
        precondition(monitor.currentDevices[0].isSameDevice(as: original[0]))

        xntfs_observation_set_registry(0, 7777)
        xntfs_observation_emit(monitor.sessionRef(), 0, 1)
        let replacement = monitor.currentDevices[0]
        precondition(!replacement.isSameDevice(as: original[0]))
        xntfs_observation_emit(monitor.sessionRef(), 0, 2)
        xntfs_observation_emit(monitor.sessionRef(), 0, 0)
        precondition(!monitor.currentDevices[0].isSameDevice(as: replacement))
        await flushMain()
        print("PASS: refresh/diagnostic reuse, publication order/count, fresh callbacks and reconnect identity")

        // An unavailable table retains the existing per-device retry behavior;
        // it must not poison the remaining observations after a transient failure.
        for index in 0..<8 { xntfs_observation_set_kind(UInt32(index), "ntfs") }
        xntfs_observation_fail_table(true)
        xntfs_observation_reset_counts()
        let unknown = await diagnostics(monitor)
        precondition(unknown.isEmpty, "Diagnostics exported unverified mounted flags from DA hints")
        precondition(xntfs_observation_mount_calls() == 8, "Failed query changed per-device retry behavior")
        xntfs_observation_reset_counts()
        await refresh(monitor)
        precondition(xntfs_observation_mount_calls() == 9 && monitor.currentDevices.count == 8)
        xntfs_observation_fail_table(false)
        xntfs_observation_reset_counts()
        await refresh(monitor)
        precondition(xntfs_observation_mount_calls() == 1 && monitor.currentDevices[0].mountedFileSystemType == "xntfs")

        xntfs_observation_set_mount(0, "exfat", false)
        xntfs_observation_set_missing(1, false, true)
        xntfs_observation_set_missing(2, true, false)
        let count = publications.values.count
        xntfs_observation_reset_counts()
        let filtered = await diagnostics(monitor)
        precondition(filtered.count == 5 && monitor.currentDevices.count == 8)
        precondition(xntfs_observation_mount_calls() == 1)
        await refresh(monitor)
        precondition(monitor.currentDevices.count == 6) // Missing DA disk retains its old observation, as before.
        precondition(publications.values.count == count + 1)
        precondition(!monitor.currentDevices.contains { $0.id == "diskTest0" || $0.id == "diskTest1" })
        print("PASS: failed snapshot, next-batch recovery, authoritative filesystem classification and missing descriptions/disks")
    }

    static func checkLazy() async {
        xntfs_observation_reset(4, 64)
        for index in 0..<4 {
            xntfs_observation_set_kind(UInt32(index), "ntfs")
            xntfs_observation_set_path(UInt32(index), index == 0 ? 3 : 0)
        }
        let monitor = await monitor(4)
        precondition(xntfs_observation_mount_calls() == 0)
        _ = await diagnostics(monitor)
        await refresh(monitor)
        precondition(xntfs_observation_mount_calls() == 1, "Refresh must take one rediscovery snapshot")
        xntfs_observation_set_path(3, 2)
        xntfs_observation_reset_counts()
        let stale = await diagnostics(monitor)
        precondition(xntfs_observation_mount_calls() == 1 && stale.map(\.id) == ["diskTest1", "diskTest2"])
        xntfs_observation_set_path(3, 1)
        xntfs_observation_reset_counts()
        await refresh(monitor)
        precondition(xntfs_observation_mount_calls() == 1 && monitor.currentDevices[3].mountedFileSystemType == "xntfs")
        for index in 0..<4 {
            xntfs_observation_set_missing(UInt32(index), true, false)
            xntfs_observation_emit(monitor.sessionRef(), UInt32(index), 2)
        }
        xntfs_observation_reset_counts()
        _ = await diagnostics(monitor)
        await refresh(monitor)
        precondition(monitor.currentDevices.isEmpty && xntfs_observation_mount_calls() == 1)
        print("PASS: diagnostics remain lazy; refresh takes one recovery snapshot; disappeared devices do not reappear from stale rows")
    }

    static func checkTransientFailure() async {
        xntfs_observation_reset(8, 32)
        let monitor = await monitor(8) // Default DA kind is misleading "msdos".
        let original = monitor.currentDevices
        xntfs_observation_reset_counts()
        xntfs_observation_fail_next_table()
        let diagnostic = await diagnostics(monitor)
        precondition(diagnostic.count == 7 && monitor.currentDevices.count == 8,
                     "One failed query removed later diagnostic observations")
        precondition(xntfs_observation_mount_calls() == 2, "Transient failure poisoned later diagnostics")
        xntfs_observation_reset_counts()
        xntfs_observation_fail_next_table()
        await refresh(monitor)
        precondition(monitor.currentDevices.count == 7 && xntfs_observation_mount_calls() == 2,
                     "One failed query removed the whole batch")
        let survivors = monitor.currentDevices
        xntfs_observation_reset_counts()
        await refresh(monitor) // No new DA event: refresh must rediscover the omitted device.
        precondition(monitor.currentDevices.count == 8, "Refresh did not rediscover the lost mounted device")
        precondition(xntfs_observation_mount_calls() == 1)
        precondition(survivors.allSatisfy { old in monitor.currentDevices.contains { $0.isSameDevice(as: old) } })
        precondition(!monitor.currentDevices[0].isSameDevice(as: original[0]), "Rediscovery revived a removed observation's identity")
        print("PASS: single failed query is isolated; ordinary refresh rediscovers the omitted device without a DA event")
    }

    static func checkMissingAppearances() async {
        xntfs_observation_reset(4, 32)
        let publications = Publications()
        let monitor = await monitor(0, publications: publications)
        xntfs_observation_fail_table(true)
        for _ in 0..<3 { await refresh(monitor) }
        precondition(monitor.currentDevices.isEmpty && publications.values.isEmpty)
        precondition(xntfs_observation_mount_calls() == 3 && xntfs_observation_disk_requests() == 0)

        xntfs_observation_fail_table(false)
        xntfs_observation_set_missing(2, false, true)
        xntfs_observation_reset_counts()
        await refresh(monitor)
        precondition(monitor.currentDevices.count == 3 && publications.values.count == 1)
        precondition(xntfs_observation_mount_calls() == 1 && xntfs_observation_disk_requests() == 4)
        let known = monitor.currentDevices
        xntfs_observation_set_missing(2, false, false)
        xntfs_observation_reset_counts()
        await refresh(monitor)
        precondition(monitor.currentDevices.count == 4 && publications.values.count == 2)
        precondition(xntfs_observation_mount_calls() == 1 && xntfs_observation_disk_requests() == 4)
        precondition(known.allSatisfy { old in monitor.currentDevices.contains { $0.isSameDevice(as: old) } })

        let old = monitor.currentDevices[0]
        xntfs_observation_set_missing(0, true, false)
        xntfs_observation_emit(monitor.sessionRef(), 0, 2)
        await refresh(monitor)
        precondition(monitor.currentDevices.count == 3, "Stale mount table revived a disappeared device")
        xntfs_observation_set_registry(0, 5678)
        xntfs_observation_set_missing(0, false, false)
        await refresh(monitor)
        let replacement = monitor.currentDevices[0]
        precondition(replacement.registryEntryID == 5678 && !replacement.isSameDevice(as: old))
        xntfs_observation_set_registry(0, 6789)
        await refresh(monitor)
        precondition(!monitor.currentDevices[0].isSameDevice(as: replacement))
        print("PASS: missed appearances and description failures recover; current identities/publication counts and reused BSD names remain isolated")
    }

    static func checkRecoveryFiltering() async {
        xntfs_observation_reset(8, 12)
        xntfs_observation_set_entry(0, "file:///tmp/synthetic.ntfs", "/Volumes/Synthetic0", "xntfs")
        xntfs_observation_set_entry(1, "/tmp/not-a-device", "/Volumes/Synthetic1", "xntfs")
        xntfs_observation_set_mount(2, "apfs", false)
        xntfs_observation_set_mount(3, "exfat", false)
        xntfs_observation_set_mount(4, "ufsd", false)
        xntfs_observation_set_kind(4, "exfat")
        xntfs_observation_set_mount(5, "ufsd", true)
        xntfs_observation_set_kind(5, "ntfs")
        xntfs_observation_set_path(6, 2)
        xntfs_observation_set_missing(7, true, false)
        xntfs_observation_set_entry(8, "/dev/diskTest5", "/Volumes/Synthetic5", "ufsd")
        xntfs_observation_set_entry(9, "/dev/diskTest5/../diskTest6", "/Volumes/Synthetic6", "xntfs")
        xntfs_observation_set_entry(10, "/dev/", "/Volumes/Synthetic0", "xntfs")
        xntfs_observation_set_entry(11, "/dev/diskTest1", "/Volumes/Synthetic1", "xntfs")
        xntfs_observation_set_kind(1, "ntfs") // A hint cannot bypass the mismatched first mount source.
        let monitor = await monitor(0)
        await refresh(monitor)
        precondition(monitor.currentDevices.map(\.id) == ["diskTest5"], "Recovery invented or misclassified a mounted device")
        precondition(monitor.currentDevices[0].readOnly && monitor.currentDevices[0].mountedFileSystemType == "ufsd")
        precondition(xntfs_observation_mount_calls() == 1 && xntfs_observation_disk_requests() == 5,
                     "Duplicate/irrelevant mount sources triggered extra BSD-name lookups")

        // A supported driver is not enough if DA no longer has this exact mount.
        xntfs_observation_set_missing(7, false, false)
        xntfs_observation_set_path(7, 0)
        xntfs_observation_set_kind(7, "ntfs")
        await refresh(monitor)
        precondition(monitor.currentDevices.map(\.id) == ["diskTest5"])
        xntfs_observation_set_path(6, 1)
        await refresh(monitor)
        precondition(monitor.currentDevices.map(\.id) == ["diskTest5", "diskTest6"])
        print("PASS: exact current source/path, authoritative format, generic-driver hints, direct-image exclusion and deduplicated BSD-name lookups")
    }

    static func checkRepeatedSource() async {
        xntfs_observation_reset(2, 2)
        xntfs_observation_set_entry(0, "/dev/diskTest1", "/Volumes/OlderMount", "xntfs")
        let publications = Publications()
        let monitor = await monitor(0, publications: publications)
        await refresh(monitor)
        precondition(monitor.currentDevices.map(\.id) == ["diskTest1"])
        precondition(xntfs_observation_disk_requests() == 1 && publications.values.count == 1)
        print("PASS: repeated BSD source resolves DA's current exact mount once")
    }

    static func checkRecoveryDrivers() async {
        let types = ["ntfs", "XNTFS", "tuxera_ntfs", "fusefs_txantfs", "ufsd", "macfuse", "osxfuse"]
        xntfs_observation_reset(UInt32(types.count), 16)
        for (index, type) in types.enumerated() {
            xntfs_observation_set_mount(UInt32(index), type, index.isMultiple(of: 2))
            xntfs_observation_set_kind(UInt32(index), "ntfs")
        }
        let monitor = await monitor(0)
        await refresh(monitor)
        precondition(monitor.currentDevices.map(\.mountedFileSystemType) == types.map(Optional.some))
        precondition(xntfs_observation_disk_requests() == UInt32(types.count))
        xntfs_observation_set_kind(4, "exfat")
        await refresh(monitor)
        await refresh(monitor)
        precondition(monitor.currentDevices.count == types.count - 1 && !monitor.currentDevices.contains { $0.id == "diskTest4" })
        print("PASS: all recognized and generic NTFS driver paths share the existing classification contract")
    }

    static func checkRepeatedRecovery() async {
        xntfs_observation_reset(8, 128)
        let first = await monitor(8), second = await monitor(8)
        let registrations = xntfs_observation_registration_calls()
        for _ in 0..<100 {
            xntfs_observation_fail_table(true)
            await refresh(first); await refresh(second)
            precondition(first.currentDevices.isEmpty && second.currentDevices.isEmpty)
            xntfs_observation_fail_table(false)
            xntfs_observation_reset_counts()
            await refresh(first); await refresh(second)
            precondition(first.currentDevices.count == 8 && second.currentDevices.count == 8)
            precondition(xntfs_observation_mount_calls() == 2 && xntfs_observation_disk_requests() == 16)
            #if OBSERVATION_LIFETIME_PROBE
            ObservationLifetimeProbe.checkRetired()
            #endif
        }
        precondition(xntfs_observation_registration_calls() == registrations)
        print("PASS: 100 disappearance/recovery cycles across two monitors; no retained history or repeated DA registration")
    }

    static func checkLargeSnapshot() async {
        xntfs_observation_reset(128, 512)
        let monitor = await monitor(0)
        await refresh(monitor)
        precondition(monitor.currentDevices.count == 128 && xntfs_observation_disk_requests() == 128)
        let original = monitor.currentDevices
        for _ in 0..<10 {
            xntfs_observation_reset_counts()
            await refresh(monitor)
            precondition(xntfs_observation_mount_calls() == 1 && xntfs_observation_disk_requests() == 128)
            precondition(zip(original, monitor.currentDevices).allSatisfy { $0.isSameDevice(as: $1) })
            #if OBSERVATION_LIFETIME_PROBE
            ObservationLifetimeProbe.checkRetired()
            #endif
        }
        print("PASS: 128 devices in a 512-entry snapshot, one BSD-name lookup per device, coalesced latest-state delivery, separate media traversal and stable identities")
    }

    static func checkRepeated() async {
        xntfs_observation_reset(8, 128)
        let first = await monitor(8), second = await monitor(8)
        xntfs_observation_reset_counts()
        for cycle in 0..<100 {
            // Separate monitors and overlapping requests each own a fresh snapshot.
            async let a = diagnostics(first)
            async let b = diagnostics(second)
            async let c = diagnostics(first)
            let values = await (a, b, c)
            precondition(values.0.count == 8 && values.1.count == 8 && values.2.count == 8)
            await refresh(first); await refresh(second)
            precondition(xntfs_observation_mount_calls() == UInt32((cycle + 1) * 5))
            #if OBSERVATION_LIFETIME_PROBE
            ObservationLifetimeProbe.checkRetired()
            #endif
        }
        precondition(xntfs_observation_copied_bytes() == UInt64(500 * 128 * MemoryLayout<statfs>.stride))
        print("PASS: 100 cycles, two monitors, overlapping diagnostics, one snapshot per operation")
    }

    static func waitForRetirement() async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while xntfs_observation_sessions() != 0 {
            precondition(DispatchTime.now().uptimeNanoseconds < deadline, "Monitor/session retained after batch")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        await flushMain()
        precondition(xntfs_observation_iterators_live() == 0 && xntfs_observation_media_live() == 0,
                     "Iterator/media handle retained after operation retirement")
    }

    static func cpuTime() -> Double {
        var usage = rusage(); precondition(getrusage(RUSAGE_SELF, &usage) == 0)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) +
            Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    static func benchmark() async {
        let args = CommandLine.arguments
        precondition(args.count == 6)
        let count = UInt32(args[2])!, entries = UInt32(args[3])!, iterations = Int(args[4])!
        let mode = args[5]
        precondition(mode == "refresh" || mode == "diagnostics" || mode == "burst")
        xntfs_observation_reset(count, entries)
        let monitor = await monitor(count)
        func run() async {
            if mode == "burst" {
                xntfs_observation_hold_queue(monitor.sessionRef())
                xntfs_observation_wait_held()
                for _ in 0..<64 { monitor.refresh() }
                xntfs_observation_release_and_drain(monitor.sessionRef())
                await flushMain()
            } else if mode == "refresh" { await refresh(monitor) }
            else {
                let values = await diagnostics(monitor)
                precondition(values.count == Int(count))
            }
        }
        for _ in 0..<10 { await run() }
        xntfs_observation_reset_counts()
        let cpuStart = cpuTime(), start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { await run() }
        let wall = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        let cpu = cpuTime() - cpuStart
        xntfs_observation_drain(monitor.sessionRef())
        var result: [String: Any] = ["devices": count, "entries": entries, "iterations": iterations,
            "mode": mode, "wall_seconds": wall, "cpu_seconds": cpu,
            "mount_calls": xntfs_observation_mount_calls(), "copied_bytes": xntfs_observation_copied_bytes(),
            "disk_requests": xntfs_observation_disk_requests()]
        result["requests_per_iteration"] = mode == "burst" ? 64 : 1
        #if REFRESH_LIFETIME_PROBE
        result["refresh_ownership"] = RefreshAdmissionProbe.snapshot()
        #endif
        print(String(data: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
    }

    static func main() async throws {
        setbuf(stdout, nil)
        if CommandLine.arguments.dropFirst().first == "--benchmark" { await benchmark(); return }
        xntfs_test_begin_query_guard()
        defer { xntfs_test_end_query_guard() }
        var control = statfs()
        precondition(statfs("/Volumes/Synthetic0", &control) == -1 && xntfs_test_query_count() == 1)
        xntfs_test_begin_query_guard()
        await checkUnmountedRecovery(); try await waitForRetirement()
        await checkMediaRecoveryFiltering(); try await waitForRetirement()
        await checkMediaEnumerationFailures(); try await waitForRetirement()
        await checkMediaEnumerationOverlap(); try await waitForRetirement()
        await checkRepeatedUnmountedRecovery(); try await waitForRetirement()
        await checkQueuedRefreshes(); try await waitForRetirement()
        await checkActiveRefreshes(); try await waitForRetirement()
        await checkRefreshIsolation(); try await waitForRetirement()
        await checkQueuedRefreshRetirement(); try await waitForRetirement()
        await checkRepeatedRefreshAdmission(); try await waitForRetirement()
        await checkTransientFailure(); try await waitForRetirement()
        await checkMissingAppearances(); try await waitForRetirement()
        await checkRecoveryFiltering(); try await waitForRetirement()
        await checkRepeatedSource(); try await waitForRetirement()
        await checkRecoveryDrivers(); try await waitForRetirement()
        await checkBatch(); try await waitForRetirement()
        await checkLazy(); try await waitForRetirement()
        await checkRepeated(); try await waitForRetirement()
        await checkRepeatedRecovery(); try await waitForRetirement()
        await checkLargeSnapshot(); try await waitForRetirement()
        precondition(xntfs_observation_wrong_flags() == 0 && xntfs_test_query_count() == 0)
        #if REFRESH_LIFETIME_PROBE
        RefreshAdmissionProbe.checkRetired()
        print(RefreshAdmissionProbe.snapshot())
        #endif
        #if OBSERVATION_LIFETIME_PROBE
        ObservationLifetimeProbe.checkRetired()
        ObservationLifetimeProbe.report()
        #endif
        print("PASS: MNT_NOWAIT only; no volume stat/statfs/path queries or retained sessions; no devices/preferences changed")
    }
}
