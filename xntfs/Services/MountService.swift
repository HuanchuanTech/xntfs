//
//  MountService.swift
//  Mounts / unmounts NTFS volumes through DiskArbitration, and attaches raw
//  NTFS disk images. Mount-point selection (with duplicate handling) lives here.
//

import Foundation
import DiskArbitration
import FSKit

enum MountError: LocalizedError {
    case daUnavailable
    case diskNotFound(String)
    case dissented(String)
    case cannotCreateMountPoint(String)

    var errorDescription: String? {
        switch self {
        case .daUnavailable: return "DiskArbitration is unavailable."
        case .diskNotFound(let b): return "Device \(b) was not found."
        case .dissented(let m): return "Mount was refused: \(m)"
        case .cannotCreateMountPoint(let p): return "Couldn't create the mount folder at \(p)."
        }
    }
}

/// Result of an image-file mount attempt.
enum ImageMountOutcome {
    case mounted(URL)
    case needsManualCommand(String)
    case failed(String)
}

final class MountService {
    private let monitor: DiskArbitrationMonitor
    init(monitor: DiskArbitrationMonitor) { self.monitor = monitor }

    // MARK: mount / unmount

    /// Mounts `device`. Pass `mountPoint == nil` to use the standard location
    /// (`/Volumes/<name>`, chosen by the system, which also de-duplicates names);
    /// pass a user-chosen folder URL to mount there. Returns the resulting path.
    func mount(_ device: NTFSDevice, at mountPoint: URL?, readOnly: Bool) async throws -> URL {
        let session = monitor.sessionRef()
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, device.id) else {
            throw MountError.diskNotFound(device.id)
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let args = readOnly ? ["rdonly"] : []
            withMountArguments(args) { argv in
                let box = DACallbackBox { dissenter in
                    if let dissenter, let msg = DADissenterGetStatusString(dissenter) {
                        cont.resume(throwing: MountError.dissented(msg as String))
                    } else if let dissenter {
                        cont.resume(throwing: MountError.dissented("status \(DADissenterGetStatus(dissenter))"))
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
                if let dissenter { cont.resume(throwing: MountError.dissented("status \(DADissenterGetStatus(dissenter))")) }
                else { cont.resume(returning: ()) }
            }
            let opts: DADiskUnmountOptions = force ? DADiskUnmountOptions(kDADiskUnmountOptionForce) : DADiskUnmountOptions(kDADiskUnmountOptionDefault)
            DADiskUnmount(disk, opts, { _, dissenter, ctx in daInvokeBox(dissenter, ctx) },
                          Unmanaged.passRetained(box).toOpaque())
        }
    }

    // MARK: image-file mounting
    //
    // A raw NTFS image is an FSPathURLResource (the extension sets FSSupportsPathURLs).
    // On macOS 27+ the app mounts it directly via FSClient.mountSingleVolume (needs the
    // `com.apple.developer.fskit.mount` entitlement). That API mounts ONLY into /Volumes
    // -- it has no custom-path parameter -- so a user-chosen target folder is offered via a
    // copyable `mount` command instead (a sandboxed app can't run mount itself).

    static let moduleBundleID = "com.huanchuan.xntfs.ntfs3g"

    /// A command the user can paste into Terminal to mount `source` at `target`.
    static func manualMountCommand(source: URL, target: URL, readOnly: Bool) -> String {
        let ro = readOnly ? " -o rdonly" : ""
        return "sudo mount -F -t xntfs\(ro) \(shellQuote(source.path)) \(shellQuote(target.path))"
    }

    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Mount an NTFS image file.
    /// - A non-nil `target` (custom folder) returns a copyable Terminal command -- the
    ///   sandbox-safe FSKit API only mounts into /Volumes.
    /// - With `target == nil`, macOS 27+ mounts into /Volumes directly via FSClient; earlier
    ///   systems return a command (no sandbox-safe mount API before macOS 27).
    func mountImage(source: URL, target: URL?, readOnly: Bool) async -> ImageMountOutcome {
        if target == nil, #available(macOS 27.0, *) {
            return await mountImageToVolumes(source: source, readOnly: readOnly)
        }
        let dst = target ?? URL(fileURLWithPath: "/Volumes/\(source.deletingPathExtension().lastPathComponent)")
        return .needsManualCommand(Self.manualMountCommand(source: source, target: dst, readOnly: readOnly))
    }

    @available(macOS 27.0, *)
    private func mountImageToVolumes(source: URL, readOnly: Bool) async -> ImageMountOutcome {
        let resource = FSPathURLResource(url: source, writable: !readOnly)
        let options = readOnly ? ["rdonly"] : []
        do {
            let mountPath = try await FSClient.shared.mountSingleVolume(
                resource: resource, bundleID: Self.moduleBundleID, options: options)
            return .mounted(mountPath)
        } catch {
            return .failed(error.localizedDescription)
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
