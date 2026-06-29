//
//  DiskArbitrationMonitor.swift
//  Detects NTFS volumes via DiskArbitration so the app can list them and offer
//  manual mount / unmount. Detection only — auto-mounting is handled by the
//  system + the file-system extension (FSMediaTypes).
//

import Foundation
import DiskArbitration

final class DiskArbitrationMonitor {

    /// Called (on the main queue) whenever the known device set changes.
    var onDevicesChanged: (([NTFSDevice]) -> Void)?

    private let session: DASession
    private let queue = DispatchQueue(label: "com.huanchuan.xntfs.diskarb")
    private var devices: [String: NTFSDevice] = [:]
    private let lock = NSLock()

    init?() {
        guard let s = DASessionCreate(kCFAllocatorDefault) else { return nil }
        session = s
        DASessionSetDispatchQueue(session, queue)
    }

    func start() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, daAppeared, ctx)
        DARegisterDiskDisappearedCallback(session, nil, daDisappeared, ctx)
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, daChanged, ctx)
    }

    func sessionRef() -> DASession { session }

    var currentDevices: [NTFSDevice] {
        lock.lock(); defer { lock.unlock() }
        return Array(devices.values).sorted { $0.id < $1.id }
    }

    // MARK: callback handlers

    fileprivate func handleAppearedOrChanged(_ disk: DADisk) {
        guard let bsd = bsdName(disk) else { return }
        guard let dev = makeDevice(disk, bsd: bsd) else {
            // A DA "changed" event left this device no longer matching (e.g. reformatted to a
            // non-NTFS fs, or our module unmounted it) — drop any tracked entry so it leaves
            // the list instead of lingering stale.
            lock.lock(); let removed = devices.removeValue(forKey: bsd) != nil; lock.unlock()
            if removed { publish() }
            return
        }
        lock.lock(); devices[bsd] = dev; lock.unlock()
        publish()
    }

    fileprivate func handleDisappeared(_ disk: DADisk) {
        guard let bsd = bsdName(disk) else { return }
        lock.lock(); devices[bsd] = nil; lock.unlock()
        publish()
    }

    private func publish() {
        let list = currentDevices
        DispatchQueue.main.async { [weak self] in self?.onDevicesChanged?(list) }
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

    /// DADeviceModel value reported by disk-image-backed devices (verified via the DA
    /// description: Apple's AppleDiskImagesController reports model "Disk Image").
    static let imageDeviceModel = "Disk Image"

    private func makeDevice(_ disk: DADisk, bsd: String) -> NTFSDevice? {
        guard let d = description(disk) else { return nil }
        let leaf = d[kDADiskDescriptionMediaLeafKey as String] as? Bool ?? false
        let content = d[kDADiskDescriptionMediaContentKey as String] as? String ?? ""
        let kind = (d[kDADiskDescriptionVolumeKindKey as String] as? String ?? "").lowercased()
        let mountURL = d[kDADiskDescriptionVolumePathKey as String] as? URL

        // Authoritative: is the volume actually mounted through our module? The media
        // content hint can't be trusted for mounted volumes — DiskArbitration has been
        // seen to mislabel NTFS as MS-DOS/exFAT — so check the real mount fs-type.
        let info = mountURL.flatMap { Self.mountInfo($0) }
        let byModule = info?.fsType == Self.moduleFSType
        let isNTFSMedia = content == "Windows_NTFS" || kind == "ntfs" || kind == Self.moduleFSType
        guard byModule || (isNTFSMedia && leaf) else { return nil }

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
        dev.mountedByXntfs = byModule
        dev.readOnly = info?.readOnly ?? false
        dev.mediaWritable = (d[kDADiskDescriptionMediaWritableKey as String] as? Bool) ?? true
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
        return dev
    }

    /// `(f_fstypename, read-only)` of the filesystem mounted at `url`, or nil if not mounted.
    private static func mountInfo(_ url: URL) -> (fsType: String, readOnly: Bool)? {
        guard url.isFileURL else { return nil }
        var s = statfs()
        guard statfs(url.path, &s) == 0 else { return nil }
        let fsType = withUnsafeBytes(of: &s.f_fstypename) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return (fsType, (s.f_flags & UInt32(MNT_RDONLY)) != 0)
    }
}

// MARK: - C trampolines

private func monitor(_ ctx: UnsafeMutableRawPointer?) -> DiskArbitrationMonitor? {
    guard let ctx else { return nil }
    return Unmanaged<DiskArbitrationMonitor>.fromOpaque(ctx).takeUnretainedValue()
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
