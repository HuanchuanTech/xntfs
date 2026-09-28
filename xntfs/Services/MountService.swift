//
//  MountService.swift
//  Mounts / unmounts NTFS device volumes via DiskArbitration. In-app mounting is only
//  attempted on macOS 27+ (FSKit Mounter); on earlier systems the user mounts via Disk
//  Utility instead.
//

import Foundation
import DiskArbitration
import FSKit
import IOKit

enum MountError: LocalizedError {
    case daUnavailable
    case diskNotFound(String)
    case dissented(status: DAReturn, message: String?)
    case cannotCreateMountPoint(String)
    case alreadyMounted
    case extensionUnavailable
    case unexpectedMount
    case accessModeMismatch

    var errorDescription: String? {
        switch self {
        case .daUnavailable: return "DiskArbitration is unavailable."
        case .diskNotFound(let b): return "Device \(b) was not found."
        case .dissented(let status, let message): return "Mount was refused: \(message ?? "status \(status)")"
        case .cannotCreateMountPoint(let p): return "Couldn't create the mount folder at \(p)."
        case .alreadyMounted:
            return String(localized: "This volume is already mounted. Eject it before changing its access mode.")
        case .extensionUnavailable:
            return String(localized: "Enable ntfs3g in File System Extensions before mounting this volume.")
        case .unexpectedMount:
            return String(localized: "The system did not return an xntfs mount. Refresh the volume list and check Diagnostics.")
        case .accessModeMismatch:
            return String(localized: "The volume mounted with a different access mode than requested. Check its current status before using it.")
        }
    }

}

/// Result of a mount attempt.
enum MountOutcome {
    case mounted(URL)
    case failed(String)
}

@MainActor
final class MountService {
    private let monitor: DiskArbitrationMonitor
    init(monitor: DiskArbitrationMonitor) { self.monitor = monitor }

    // MARK: mount
    func unifiedMount(_ device: NTFSDevice, readOnly: Bool) async -> MountOutcome {
        guard #available(macOS 27.0, *) else {
            return .failed(String(localized: "Mounting in the app isn't available — use Disk Utility to mount this volume."))
        }
        do {
            let modules = try await FSClient.shared.installedExtensions
            guard modules.contains(where: { $0.bundleIdentifier == ExtensionStatus.bundleID && $0.isEnabled }) else {
                throw MountError.extensionUnavailable
            }
            return .mounted(try await mount(device, readOnly: readOnly))
        } catch { return .failed(error.localizedDescription) }
    }

    private func mount(_ device: NTFSDevice, readOnly: Bool) async throws -> URL {
        let session = monitor.sessionRef()
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, device.id) else {
            throw MountError.diskNotFound(device.id)
        }
        if let expectedID = device.registryEntryID {
            let media = DADiskCopyIOMedia(disk)
            guard media != IO_OBJECT_NULL else { throw MountError.diskNotFound(device.id) }
            defer { IOObjectRelease(media) }
            var actualID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(media, &actualID) == KERN_SUCCESS,
                  actualID == expectedID else { throw MountError.diskNotFound(device.id) }
        }
        guard let description = DADiskCopyDescription(disk) as? [String: Any] else {
            throw MountError.diskNotFound(device.id)
        }
        guard description[kDADiskDescriptionVolumePathKey as String] == nil else { throw MountError.alreadyMounted }
        let mediaWritable = description[kDADiskDescriptionMediaWritableKey as String] as? Bool ?? device.mediaWritable
        let effectiveReadOnly = readOnly || !mediaWritable
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // Pass an explicit ro/rw so the extension can tell a deliberate in-app mount
            // from a system auto-mount (which carries no ro/rw and honors the app setting).
            let args = effectiveReadOnly ? ["rdonly"] : ["rw"]
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
                DADiskMountWithArguments(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault),
                                         { _, dissenter, ctx in daInvokeBox(dissenter, ctx) },
                                         Unmanaged.passRetained(box).toOpaque(), argv)
            }
        }
        guard let desc = DADiskCopyDescription(disk) as? [String: Any],
              let url = desc[kDADiskDescriptionVolumePathKey as String] as? URL,
              let info = DiskArbitrationMonitor.mountInfo(url),
              info.fsType == DiskArbitrationMonitor.moduleFSType else {
            throw MountError.unexpectedMount
        }
        guard info.readOnly == effectiveReadOnly else { throw MountError.accessModeMismatch }
        return url
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
