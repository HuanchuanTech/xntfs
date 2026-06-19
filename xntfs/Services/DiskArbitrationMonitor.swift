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
        guard let bsd = bsdName(disk), let dev = makeDevice(disk, bsd: bsd) else { return }
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

    private func makeDevice(_ disk: DADisk, bsd: String) -> NTFSDevice? {
        guard let d = description(disk) else { return nil }
        let leaf = d[kDADiskDescriptionMediaLeafKey as String] as? Bool ?? false
        let content = d[kDADiskDescriptionMediaContentKey as String] as? String ?? ""
        let kind = d[kDADiskDescriptionVolumeKindKey as String] as? String ?? ""
        let ntfs = content == "Windows_NTFS" || kind.lowercased() == "ntfs"
        guard ntfs, leaf else { return nil }

        let name = d[kDADiskDescriptionVolumeNameKey as String] as? String
            ?? (d[kDADiskDescriptionMediaNameKey as String] as? String) ?? bsd
        let size = (d[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.uint64Value ?? 0
        let removable = (d[kDADiskDescriptionMediaRemovableKey as String] as? Bool) ?? false
        let ejectable = (d[kDADiskDescriptionMediaEjectableKey as String] as? Bool) ?? false
        let mountURL = d[kDADiskDescriptionVolumePathKey as String] as? URL

        var dev = NTFSDevice(
            id: bsd,
            volumeName: name,
            sizeBytes: size,
            kind: (removable || ejectable) ? .removable : .fixed,
            contentHint: content,
            isRemovable: removable || ejectable,
            devicePath: "/dev/\(bsd)")
        if let url = mountURL { dev.state = .mounted(url) }
        return dev
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
