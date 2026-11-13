//
//  DiskArbitrationMonitor.swift
//  Detects NTFS volumes via DiskArbitration so the app can list them and offer
//  manual mount / unmount. Detection only — auto-mounting is handled by the
//  system + the file-system extension (FSMediaTypes).
//

import Foundation
import DiskArbitration
import IOKit

final class DiskArbitrationMonitor {

    /// Delivers the latest known device set on main; pending updates may coalesce.
    var onDevicesChanged: (([NTFSDevice]) -> Void)?

    private let session: DASession
    private let queue = DispatchQueue(label: "com.huanchuan.xntfs.diskarb")
    private let callbackContext = MonitorCallbackContext()
    private var devices: [String: NTFSDevice] = [:]
    private let lock = NSLock()
    private var refreshQueued = false
    private var publicationQueued = false
    private static let maximumDiagnosticQueries = 4
    private var pendingDiagnosticQueries = 0

    init?() {
        guard let s = DASessionCreate(kCFAllocatorDefault) else { return nil }
        session = s
        DASessionSetDispatchQueue(session, queue)
        callbackContext.monitor = self
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            let ctx = Unmanaged.passUnretained(self.callbackContext).toOpaque()
            DARegisterDiskAppearedCallback(self.session, nil, daAppeared, ctx)
            DARegisterDiskDisappearedCallback(self.session, nil, daDisappeared, ctx)
            DARegisterDiskDescriptionChangedCallback(self.session, nil, nil, daChanged, ctx)
        }
    }

    deinit {
        // Keep the weak context alive until earlier callbacks have drained. A DA
        // session can outlive its owner while its dispatch source is scheduled.
        let session = session, context = callbackContext
        queue.async {
            withExtendedLifetime(context) {
                let ctx = Unmanaged.passUnretained(context).toOpaque()
                DAUnregisterCallback(session, unsafeBitCast(daAppeared as DADiskAppearedCallback, to: UnsafeMutableRawPointer.self), ctx)
                DAUnregisterCallback(session, unsafeBitCast(daDisappeared as DADiskDisappearedCallback, to: UnsafeMutableRawPointer.self), ctx)
                DAUnregisterCallback(session, unsafeBitCast(daChanged as DADiskDescriptionChangedCallback, to: UnsafeMutableRawPointer.self), ctx)
                DASessionSetDispatchQueue(session, nil)
            }
        }
    }

    func sessionRef() -> DASession { session }

    func refresh() {
        lock.lock(); defer { lock.unlock() }
        guard !refreshQueued else { return }
        refreshQueued = true
        // Enqueue before releasing the admission lock. A waiting refresh covers
        // later callers; an active refresh may need one follow-up with new data.
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.refreshQueued = false; self.lock.unlock()
            // Acquire snapshots only within this operation. Standalone DA
            // callbacks and any follow-up refresh start with fresh metadata.
            var mountEntries: [statfs]?
            let knownDevices = self.currentDevices
            var visited = Set(knownDevices.lazy.map(\.id))
            for device in knownDevices {
                if let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, self.session, device.id) {
                    self.handleAppearedOrChanged(disk, mountEntries: &mountEntries)
                }
            }
            // A failed observation may have removed a mounted device from the
            // list. Rediscover from current cached metadata, without retaining
            // missing-device history or re-registering DA callbacks.
            if mountEntries == nil { mountEntries = Self.mountTable() }
            for var entry in mountEntries ?? [] {
                let fsType = Self.mountString(&entry.f_fstypename).lowercased()
                guard Self.ntfsTypes.contains(fsType) || Self.genericTypes.contains(fsType) else { continue }
                let source = Self.mountString(&entry.f_mntfromname)
                guard source.hasPrefix("/dev/disk") else { continue }
                let bsd = String(source.dropFirst(5))
                guard !bsd.contains("/"), visited.insert(bsd).inserted,
                      let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, self.session, bsd),
                      self.bsdName(disk) == bsd else { continue }
                guard let device = self.makeDevice(disk, bsd: bsd, mountEntries: &mountEntries,
                    matchingSource: source, requireMounted: true).device else { continue }
                self.recordDevice(device)
            }
            self.recoverRegisteredMedia(visited: &visited, mountEntries: &mountEntries)
        }
    }

    private func recoverRegisteredMedia(visited: inout Set<String>, mountEntries: inout [statfs]?) {
        // Unmounted media has no mount-table row. Resolve current registered
        // media instead of retaining a history of failed/missing observations.
        guard let matching = IOServiceMatching("IOMedia") else { return }
        var iterator: io_iterator_t = IO_OBJECT_NULL
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        defer { if iterator != IO_OBJECT_NULL { IOObjectRelease(iterator) } }
        guard result == KERN_SUCCESS, iterator != IO_OBJECT_NULL else { return }
        while true {
            let media = IOIteratorNext(iterator)
            // Zero also covers an invalidated iterator. Stop this best-effort
            // pass; a later refresh can retry without an unbounded restart loop.
            guard media != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(media) }
            guard let disk = DADiskCreateFromIOMedia(kCFAllocatorDefault, session, media),
                  let bsd = bsdName(disk), visited.insert(bsd).inserted else { continue }
            let observation = makeDevice(disk, bsd: bsd, mountEntries: &mountEntries,
                                         matchingSource: "/dev/\(bsd)")
            guard observation.isComplete, let device = observation.device else { continue }
            recordDevice(device)
        }
    }

    struct DiagnosticObservation {
        let devices: [NTFSDevice]
        let isComplete: Bool
    }

    func devicesForDiagnostics() async throws -> DiagnosticObservation {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard pendingDiagnosticQueries < Self.maximumDiagnosticQueries else {
                lock.unlock()
                continuation.resume(throwing: POSIXError(.EBUSY))
                return
            }
            pendingDiagnosticQueries += 1
            defer { lock.unlock() }
            // Keep each admitted observation separate and enqueue before unlock.
            // Cancellation does not retire a queued operation or its continuation.
            queue.async { [self] in
                var mountEntries: [statfs]?
                var isComplete = true
                let snapshot = currentDevices.compactMap { device -> NTFSDevice? in
                    guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, device.id) else {
                        isComplete = false
                        return nil
                    }
                    let observation = makeDevice(disk, bsd: device.id, mountEntries: &mountEntries,
                                                 matchingSource: device.devicePath)
                    guard observation.isComplete else {
                        isComplete = false
                        return nil
                    }
                    return observation.device
                }
                lock.lock(); pendingDiagnosticQueries -= 1; lock.unlock()
                continuation.resume(returning: DiagnosticObservation(devices: snapshot, isComplete: isComplete))
            }
        }
    }

    var currentDevices: [NTFSDevice] {
        lock.lock()
        let list = Array(devices.values)
        lock.unlock()
        return list.sorted { $0.id < $1.id }
    }

    // MARK: callback handlers

    fileprivate func handleAppearedOrChanged(_ disk: DADisk) {
        var mountEntries: [statfs]?
        handleAppearedOrChanged(disk, mountEntries: &mountEntries)
    }

    private func handleAppearedOrChanged(_ disk: DADisk, mountEntries: inout [statfs]?) {
        guard let bsd = bsdName(disk) else { return }
        guard let dev = makeDevice(disk, bsd: bsd, mountEntries: &mountEntries,
                                  matchingSource: "/dev/\(bsd)").device else {
            // A DA "changed" event left this device no longer matching (e.g. reformatted to a
            // non-NTFS fs, or our module unmounted it) — drop any tracked entry so it leaves
            // the list instead of lingering stale.
            lock.lock(); let removed = devices.removeValue(forKey: bsd) != nil; lock.unlock()
            if removed { publish() }
            return
        }
        recordDevice(dev)
    }

    private func recordDevice(_ device: NTFSDevice) {
        var dev = device
        lock.lock()
        if let previous = devices[dev.id], previous.registryEntryID == dev.registryEntryID {
            dev.discoveryID = previous.discoveryID
        }
        devices[dev.id] = dev
        lock.unlock()
        publish()
    }

    fileprivate func handleDisappeared(_ disk: DADisk) {
        guard let bsd = bsdName(disk) else { return }
        lock.lock(); devices[bsd] = nil; lock.unlock()
        publish()
    }

    private func publish() {
        lock.lock(); defer { lock.unlock() }
        guard !publicationQueued else { return }
        publicationQueued = true
        // A queued delivery holds no list or strong monitor reference. Copy the
        // latest state only when main can consume it, rather than replaying a backlog.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let list = Array(self.devices.values)
            // Updates after this snapshot must be able to enqueue a follow-up,
            // including updates triggered from inside the consumer callback.
            self.publicationQueued = false
            self.lock.unlock()
            self.onDevicesChanged?(list.sorted { $0.id < $1.id })
        }
    }

    // MARK: description parsing

    private func bsdName(_ disk: DADisk) -> String? {
        guard let c = DADiskGetBSDName(disk) else { return nil }
        return String(cString: c)
    }

    private func description(_ disk: DADisk) -> [String: Any]? {
        DADiskCopyDescription(disk) as? [String: Any]
    }

    /// The mount fs-type our extension reports — must match the extension's
    /// FSShortName (ntfs3g/Info.plist). Used to recognize volumes we're serving.
    static let moduleFSType = "xntfs"

    private static let ntfsTypes: Set<String> = ["ntfs", moduleFSType, "tuxera_ntfs", "fusefs_txantfs"]
    private static let genericTypes: Set<String> = ["ufsd", "macfuse", "osxfuse"]

    /// DADeviceModel value reported by disk-image-backed devices (verified via the DA
    /// description: Apple's AppleDiskImagesController reports model "Disk Image").
    static let imageDeviceModel = "Disk Image"

    private func makeDevice(_ disk: DADisk, bsd: String, mountEntries: inout [statfs]?,
                            matchingSource: String, requireMounted: Bool = false)
        -> (device: NTFSDevice?, isComplete: Bool) {
        guard let d = description(disk) else { return (nil, false) }
        let leaf = d[kDADiskDescriptionMediaLeafKey as String] as? Bool ?? false
        let content = d[kDADiskDescriptionMediaContentKey as String] as? String ?? ""
        let kind = (d[kDADiskDescriptionVolumeKindKey as String] as? String ?? "").lowercased()
        let mountURL = d[kDADiskDescriptionVolumePathKey as String] as? URL
        if requireMounted, mountURL?.isFileURL != true { return (nil, false) }

        // Authoritative: is the volume actually mounted through our module? The media
        // content hint can't be trusted for mounted volumes — DiskArbitration has been
        // seen to mislabel NTFS as MS-DOS/exFAT — so check the real mount fs-type.
        let info: (fsType: String, readOnly: Bool)?
        if let mountURL, mountURL.isFileURL {
            let entries = mountEntries ?? Self.mountTable()
            // An unavailable table must not turn one transient query failure
            // into missing observations for every remaining device in the batch.
            if mountEntries == nil, !entries.isEmpty { mountEntries = entries }
            info = Self.mountInfo(mountURL, entries: entries, matchingSource: matchingSource)
        } else {
            info = nil
        }
        // Rediscovery must identify an actual current mount. A DA hint alone
        // must not turn a stale table row or reused BSD name into a mounted device.
        if requireMounted {
            guard let info, !info.fsType.isEmpty else { return (nil, false) }
        }
        // A missing path is a normal unmounted observation. A present path needs
        // matching authoritative metadata before diagnostic mounted flags are facts.
        let isComplete = mountURL == nil || (mountURL?.isFileURL == true && info?.fsType.isEmpty == false)
        guard Self.isNTFSVolume(mountedType: info?.fsType, volumeKind: kind,
                                contentHint: content, leaf: leaf) else { return (nil, isComplete) }

        let name = d[kDADiskDescriptionVolumeNameKey as String] as? String
            ?? (d[kDADiskDescriptionMediaNameKey as String] as? String) ?? bsd
        let size = (d[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.uint64Value ?? 0
        let removable = (d[kDADiskDescriptionMediaRemovableKey as String] as? Bool) ?? false
        let ejectable = (d[kDADiskDescriptionMediaEjectableKey as String] as? Bool) ?? false

        // Image-backed devices report DADeviceModel == "Disk Image"; their NTFS volumes go
        // in the "Disk Images" section and detach via the whole-disk node (disk<unit>).
        let isImage = (d[kDADiskDescriptionDeviceModelKey as String] as? String) == Self.imageDeviceModel
        let deviceKind: DeviceKind = isImage ? .diskImage : ((removable || ejectable) ? .removable : .fixed)

        var dev = NTFSDevice(
            id: bsd,
            volumeName: name,
            sizeBytes: size,
            kind: deviceKind,
            contentHint: content,
            isRemovable: removable || ejectable,
            devicePath: "/dev/\(bsd)")
        dev.mountedFileSystemType = info?.fsType
        dev.readOnly = info?.readOnly ?? false
        dev.mediaWritable = (d[kDADiskDescriptionMediaWritableKey as String] as? Bool) ?? true
        let media = DADiskCopyIOMedia(disk)
        if media != IO_OBJECT_NULL {
            var entryID: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(media, &entryID) == KERN_SUCCESS, entryID != 0 {
                dev.registryEntryID = entryID
            }
            IOObjectRelease(media)
        }
        // The whole-disk node for detach — straight from DiskArbitration, not inferred from
        // the BSD unit number (DADiskCopyWholeDisk returns the parent disk of a partition,
        // or the disk itself if it is already whole).
        if isImage {
            if let whole = DADiskCopyWholeDisk(disk), let c = DADiskGetBSDName(whole) {
                dev.wholeDiskBSD = String(cString: c)
            } else {
                // Fallback so detach always has a valid node: strip the partition suffix
                // (disk6s1 -> disk6); a whole-disk name is left unchanged.
                dev.wholeDiskBSD = bsd.replacingOccurrences(of: #"s\d+$"#, with: "", options: .regularExpression)
            }
        }
        if let url = mountURL { dev.state = .mounted(url) }
        return (dev, isComplete)
    }

    /// A partition type is only a fallback: MBR type 0x07 also contains exFAT.
    static func isNTFSVolume(mountedType: String?, volumeKind: String, contentHint: String, leaf: Bool) -> Bool {
        let mounted = mountedType?.lowercased() ?? ""
        let kind = volumeKind.lowercased()
        if !mounted.isEmpty {
            // Generic third-party driver names can serve several filesystem formats.
            if genericTypes.contains(mounted) {
                return leaf && ntfsTypes.contains(kind)
            }
            return ntfsTypes.contains(mounted) && (leaf || mounted == moduleFSType)
        }
        guard leaf else { return false }
        if !kind.isEmpty { return ntfsTypes.contains(kind) }
        return contentHint == "Windows_NTFS"
    }

    /// A caller-owned copy of the kernel's cached mount table. MNT_NOWAIT avoids
    /// querying each filesystem, so a stalled volume cannot block DA callbacks.
    static func mountTable() -> [statfs] {
        (try? queryMountTable()) ?? []
    }

    /// Preserve query failure for callers that must distinguish absence from
    /// unavailable metadata. The ordinary UI observation keeps its empty fallback.
    static func queryMountTable() throws -> [statfs] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&buffer, MNT_NOWAIT)
        defer { if let buffer { free(buffer) } }
        guard count > 0 else {
            let code = errno // Capture before the deferred free can change it.
            throw POSIXError(POSIXErrorCode(rawValue: code > 0 ? code : EIO) ?? .EIO)
        }
        guard let buffer else { throw POSIXError(.EIO) }
        return Array(UnsafeBufferPointer(start: buffer, count: Int(count)))
    }

    /// Cached `(f_fstypename, read-only)` for this exact mount point.
    static func mountInfo(_ url: URL, entries: [statfs]? = nil,
                          matchingSource: String? = nil) -> (fsType: String, readOnly: Bool)? {
        guard url.isFileURL else { return nil }
        for var entry in entries ?? mountTable() {
            let mountedAt = mountString(&entry.f_mntonname)
            // A stale DA path can still exist on the parent APFS volume.
            // Compare cached paths directly. Inferring a URL's directory type or
            // standardizing '..' can consult the very filesystem being observed.
            guard mountedAt == url.path else { continue }
            if let matchingSource, mountString(&entry.f_mntfromname) != matchingSource { return nil }
            let fsType = mountString(&entry.f_fstypename)
            return (fsType, (entry.f_flags & UInt32(MNT_RDONLY)) != 0)
        }
        return nil
    }

    private static func mountString<T>(_ value: inout T) -> String {
        withUnsafeBytes(of: &value) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

// MARK: - C trampolines

private final class MonitorCallbackContext {
    weak var monitor: DiskArbitrationMonitor?
}

private func monitor(_ ctx: UnsafeMutableRawPointer?) -> DiskArbitrationMonitor? {
    guard let ctx else { return nil }
    return Unmanaged<MonitorCallbackContext>.fromOpaque(ctx).takeUnretainedValue().monitor
}

private func daAppeared(_ disk: DADisk, _ ctx: UnsafeMutableRawPointer?) {
    monitor(ctx)?.handleAppearedOrChanged(disk)
}
private func daDisappeared(_ disk: DADisk, _ ctx: UnsafeMutableRawPointer?) {
    monitor(ctx)?.handleDisappeared(disk)
}
private func daChanged(_ disk: DADisk, _ keys: CFArray, _ ctx: UnsafeMutableRawPointer?) {
    monitor(ctx)?.handleAppearedOrChanged(disk)
}
