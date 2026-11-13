import Foundation
import Darwin

@MainActor
private final class ControlledMounter: DeviceMounting {
    var pending: [CheckedContinuation<Void, Error>] = []
    var calls = 0
    func unifiedMount(_ device: NTFSDevice, readOnly: Bool) async -> MountOutcome { .failed("unused") }
    func unmount(_ device: NTFSDevice, force: Bool) async throws {
        calls += 1
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func finish(_ error: Error? = nil) {
        let continuation = pending.removeFirst()
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
    }
}

@main
@MainActor
struct HostConcurrencyTests {
    private static func waitForCalls(_ mounter: ControlledMounter, _ count: Int) async throws {
        let end = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while mounter.calls != count {
            precondition(DispatchTime.now().uptimeNanoseconds < end, "Unmount did not start")
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    static func device(_ registry: UInt64?) -> NTFSDevice {
        var value = NTFSDevice(id: "disk99s1", volumeName: "Synthetic", sizeBytes: 4096,
            kind: .removable, contentHint: "Windows_NTFS", isRemovable: true, devicePath: "/dev/disk99s1")
        value.registryEntryID = registry
        value.state = .mounted(URL(fileURLWithPath: "/Volumes/Synthetic", isDirectory: true))
        return value
    }

    static func checkUnmounts(oldError: Error?, registry: UInt64?) async throws {
        let mounter = ControlledMounter()
        let model = AppModel(monitor: nil, mounter: mounter, settings: AppSettings(defaults: nil))
        let old = device(registry)
        model.receiveDevices([old])
        let first = Task { await model.unmount(old) }
        try await waitForCalls(mounter, 1)
        model.receiveDevices([old])
        precondition(model.devices[0].state == .unmounting, "DA observation lost the transition")
        await model.unmount(old)
        precondition(mounter.calls == 1, "Duplicate unmount was submitted")

        model.receiveDevices([])
        let replacement = device(registry) // Even equal/missing registry IDs are a new observation.
        model.receiveDevices([replacement])
        await model.unmount(old)
        precondition(mounter.calls == 1, "Stale selected device was accepted")
        let second = Task { await model.unmount(replacement) }
        try await waitForCalls(mounter, 2)
        mounter.finish(oldError)
        await first.value
        precondition(model.devices[0].isSameDevice(as: replacement) && model.devices[0].state == .unmounting)
        precondition(model.lastError == nil, "Old operation reported an error on a replacement device")
        mounter.finish()
        await second.value
        precondition(model.devices[0].state == .unmounted)

        model.receiveDevices([replacement])
        let third = Task { await model.unmount(replacement) }
        try await waitForCalls(mounter, 3)
        mounter.finish(POSIXError(.EBUSY))
        await third.value
        guard case .failed = model.devices[0].state else { preconditionFailure("Current failure was lost") }
        precondition(model.lastError != nil)
    }

    static func put<T>(_ string: String, in field: inout T) {
        withUnsafeMutableBytes(of: &field) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            precondition(string.utf8.count < bytes.count)
            bytes.copyBytes(from: string.utf8)
        }
    }

    static func checkMountTable() {
        xntfs_test_begin_query_guard()
        defer { xntfs_test_end_query_guard() }
        var control = statfs()
        precondition(statfs("/Volumes/Synthetic", &control) == -1 && errno == EIO)
        precondition(xntfs_test_query_count() == 1, "Filesystem-query guard did not interpose")
        xntfs_test_begin_query_guard()
        var root = statfs(), image = statfs(), physical = statfs()
        put("/", in: &root.f_mntonname); put("apfs", in: &root.f_fstypename)
        put("/Volumes/Synthetic", in: &image.f_mntonname)
        put("xntfs", in: &image.f_fstypename)
        put("file:///tmp/unused-synthetic.ntfs", in: &image.f_mntfromname)
        image.f_flags = UInt32(MNT_RDONLY); image.f_fsid.val = (7, 8)
        physical = image
        put("/Volumes/Physical", in: &physical.f_mntonname)
        put("/dev/disk99s1", in: &physical.f_mntfromname)
        let entries = [root, image, physical]
        let info = DiskArbitrationMonitor.mountInfo(URL(fileURLWithPath: "/Volumes/Synthetic", isDirectory: true), entries: entries)
        precondition(info?.fsType == "xntfs" && info?.readOnly == true)
        precondition(DiskArbitrationMonitor.mountInfo(URL(fileURLWithPath: "/Volumes/Stale", isDirectory: true), entries: entries) == nil)
        precondition(DiskArbitrationMonitor.mountInfo(URL(fileURLWithPath: "/Volumes/Synthetic/subdir", isDirectory: true), entries: entries) == nil)
        let images = ImageMountService.mountedImages(in: entries)
        precondition(images.count == 1 && images[0].sizeBytes == 0 && images[0].readOnly)
        image.f_blocks = 100; image.f_bsize = 4096
        let refreshed = ImageMountService.mountedImages(in: [image])[0]
        precondition(refreshed.sizeBytes == 409600 && refreshed.isSameMount(as: images[0]),
            "A capacity refresh changed the mount identity")
        image.f_fsid.val = (9, 10)
        precondition(!ImageMountService.mountedImages(in: [image])[0].isSameMount(as: images[0]))
        precondition(images[0].mountPoint.hasDirectoryPath && xntfs_test_query_count() == 0,
            "A cached observation queried the filesystem")
        print("PASS: cached mount-table parsing preserves identity, zero-size mounts, flags and exact paths without filesystem queries")
    }

    static func main() async throws {
        checkMountTable()
        for registry: UInt64? in [42, nil] {
            try await checkUnmounts(oldError: nil, registry: registry)
            try await checkUnmounts(oldError: POSIXError(.EIO), registry: registry)
        }
        print("PASS: stale/duplicate unmounts, reconnect, overlapping completion and current failure; no devices or preferences changed")
    }
}
