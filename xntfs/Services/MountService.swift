//
//  MountService.swift
//  Mounts / unmounts NTFS device volumes via DiskArbitration. In-app mounting is only
//  attempted on macOS 27+ (FSKit Mounter); on earlier systems the user mounts via Disk
//  Utility instead.
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

}

/// Result of a mount attempt.
enum MountOutcome {
    case mounted(URL)
    case failed(String)
}

final class MountService {
    private let monitor: DiskArbitrationMonitor
    init(monitor: DiskArbitrationMonitor) { self.monitor = monitor }

    // MARK: mount
    //
    // In-app mounting needs the macOS 27 FSKit Mounter, which can only be built against the
    // (still beta) macOS 27 SDK — disabled for now; the UI routes the user to Disk Utility.
    // Re-enable the body below (and `mount(_:at:readOnly:)`) when the 27 SDK is out of beta.

    func unifiedMount(_ device: NTFSDevice, readOnly: Bool) async -> MountOutcome {
        // guard #available(macOS 27.0, *) else { … }
        // do { return .mounted(try await mount(device, at: nil, readOnly: readOnly)) }
        // catch { return .failed(error.localizedDescription) }
        return .failed(String(localized: "Mounting in the app isn't available — use Disk Utility to mount this volume."))
    }

    func mount(_ device: NTFSDevice, at mountPoint: URL?, readOnly: Bool) async throws -> URL {
        let session = monitor.sessionRef()
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, device.id) else {
            throw MountError.diskNotFound(device.id)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // Pass an explicit ro/rw so the extension can tell a deliberate in-app mount
            // from a system auto-mount (which carries no ro/rw and honors the app setting).
            let args = readOnly ? ["rdonly"] : ["rw"]
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
