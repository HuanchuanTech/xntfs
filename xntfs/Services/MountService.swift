//
//  MountService.swift
//  Mounts / unmounts NTFS device volumes via DiskArbitration, and builds the copyable
//  Terminal commands the sandbox can't run itself: `mount` (on macOS < 27 or a custom
//  folder) and `hdiutil attach` / `detach` for disk images.
//

import Foundation
import DiskArbitration

enum MountError: LocalizedError {
    case daUnavailable
    case diskNotFound(String)
    case dissented(status: DAReturn, message: String?)
    case cannotCreateMountPoint(String)

    var errorDescription: String? {
        switch self {
        case .daUnavailable: return "DiskArbitration is unavailable."
        case .diskNotFound(let b): return "Device \(b) was not found."
        case .dissented(let status, let message): return "Mount was refused: \(message ?? "status \(status)")"
        case .cannotCreateMountPoint(let p): return "Couldn't create the mount folder at \(p)."
        }
    }

    /// kDAReturnNotPrivileged — the sandbox isn't allowed to perform this mount, so the
    /// only path is a user-run Terminal command (every other failure is a real error).
    var isNotPrivileged: Bool {
        if case .dissented(let status, _) = self { return status == kDAReturnNotPrivileged }
        return false
    }
}

/// Result of a mount attempt.
enum MountOutcome {
    case mounted(URL)
    case needsCommand(String)
    case failed(String)
}

final class MountService {
    private let monitor: DiskArbitrationMonitor
    init(monitor: DiskArbitrationMonitor) { self.monitor = monitor }

    // MARK: mount
    //
    // FSKit Mounter only authorizes the macOS 27 FSClient API (into /Volumes); a sandboxed
    // app's DiskArbitration mount of a third-party FSKit volume is refused as not-privileged.
    // So the in-app path is best-effort on macOS 27; otherwise we hand back a `mount` command.

    func unifiedMount(_ device: NTFSDevice, to target: URL?, readOnly: Bool) async -> MountOutcome {
        let command = Self.mountCommand(for: device, target: target, readOnly: readOnly)
        guard #available(macOS 27.0, *) else { return .needsCommand(command) }
        do { return .mounted(try await mount(device, at: target, readOnly: readOnly)) }
        catch {
            if let me = error as? MountError, me.isNotPrivileged { return .needsCommand(command) }
            return .failed(error.localizedDescription)
        }
    }

    func mount(_ device: NTFSDevice, at mountPoint: URL?, readOnly: Bool) async throws -> URL {
        let session = monitor.sessionRef()
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, device.id) else {
            throw MountError.diskNotFound(device.id)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let args = readOnly ? ["rdonly"] : []
            withMountArguments(args) { argv in
                let box = DACallbackBox { dissenter in
                    if let dissenter {
                        let status = DADissenterGetStatus(dissenter)
                        let msg = DADissenterGetStatusString(dissenter).map { $0 as String }
                        cont.resume(throwing: MountError.dissented(status: status, message: msg))
                    } else {
                        cont.resume(returning: ())
                    }
                }
                DADiskMountWithArguments(disk, mountPoint as CFURL?, DADiskMountOptions(kDADiskMountOptionDefault),
                                         { _, dissenter, ctx in daInvokeBox(dissenter, ctx) },
                                         Unmanaged.passRetained(box).toOpaque(), argv)
            }
        }
        if let mountPoint { return mountPoint }
        if let desc = DADiskCopyDescription(disk) as? [String: Any],
           let url = desc[kDADiskDescriptionVolumePathKey as String] as? URL {
            return url
        }
        return URL(fileURLWithPath: "/Volumes/\(device.volumeName)")
    }

    func unmount(_ device: NTFSDevice, force: Bool = false) async throws {
        let session = monitor.sessionRef()
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, device.id) else {
            throw MountError.diskNotFound(device.id)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let box = DACallbackBox { dissenter in
                if let dissenter { cont.resume(throwing: MountError.dissented(status: DADissenterGetStatus(dissenter), message: nil)) }
                else { cont.resume(returning: ()) }
            }
            let opts: DADiskUnmountOptions = force ? DADiskUnmountOptions(kDADiskUnmountOptionForce) : DADiskUnmountOptions(kDADiskUnmountOptionDefault)
            DADiskUnmount(disk, opts, { _, dissenter, ctx in daInvokeBox(dissenter, ctx) },
                          Unmanaged.passRetained(box).toOpaque())
        }
    }

    // MARK: copyable commands

    /// `diskutil mount` command for a device volume — routed through diskarbitrationd, the
    /// same path the system uses to auto-mount xntfs. `mount -F -t xntfs` instead does a
    /// low-level FSKit probe the extension's sandbox denies ("Probing resource: Permission
    /// denied"). A custom mount point still only works where the extension's sandbox allows
    /// it (e.g. /tmp); /Volumes works because diskarbitrationd owns it.
    static func mountCommand(for device: NTFSDevice, target: URL?, readOnly: Bool) -> String {
        let ro = readOnly ? "readOnly " : ""
        if let target {
            return "diskutil mount \(ro)-mountPoint \(shellQuote(target.path)) \(shellQuote(device.devicePath))"
        }
        return "diskutil mount \(ro)\(shellQuote(device.devicePath))"
    }

    /// Attach a disk image as a device — xntfs then auto-mounts any NTFS volume on it.
    /// Read-only by default (an attached image mounts with the device's writability);
    /// pass readOnly: false to attach writable.
    static func attachCommand(_ imagePath: String, readOnly: Bool) -> String {
        let ro = readOnly ? " -readonly" : ""
        return "hdiutil attach\(ro) \(shellQuote(imagePath))"
    }

    /// Detach an attached image by its whole-disk node (e.g. "disk6").
    static func detachCommand(wholeDiskBSD: String) -> String {
        "hdiutil detach /dev/\(wholeDiskBSD)"
    }

    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - DiskArbitration callback bridging

final class DACallbackBox {
    let handler: (DADissenter?) -> Void
    init(_ handler: @escaping (DADissenter?) -> Void) { self.handler = handler }
}

/// Shared body for the inline DiskArbitration mount/unmount completion closures.
private func daInvokeBox(_ dissenter: DADissenter?, _ ctx: UnsafeMutableRawPointer?) {
    guard let ctx else { return }
    let box = Unmanaged<DACallbackBox>.fromOpaque(ctx).takeRetainedValue()
    box.handler(dissenter)
}

/// Build a NULL-terminated C array of CFString mount arguments and pass it to `body`.
private func withMountArguments<T>(_ args: [String], _ body: (UnsafeMutablePointer<Unmanaged<CFString>?>?) -> T) -> T {
    if args.isEmpty { return body(nil) }
    let cfs = args.map { $0 as CFString }
    let buf = UnsafeMutablePointer<Unmanaged<CFString>?>.allocate(capacity: cfs.count + 1)
    defer { buf.deallocate() }
    for (i, s) in cfs.enumerated() { buf[i] = Unmanaged.passUnretained(s) }
    buf[cfs.count] = nil
    return body(buf)
}
