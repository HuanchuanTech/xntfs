//
//  ntfs3gFileSystem.swift
//  FSUnaryFileSystem delegate: probes a resource (block device or image file),
//  loads it as an ntfs3gVolume (via libntfs-3g), and tears it down.
//

import Foundation
import FSKit
import DiskArbitration

@available(macOS 15.4, *)
final class ntfs3gFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations,
                              FSManageableResourceMaintenanceOperations {

    private var volume: ntfs3gVolume?

    // MARK: read-only resolution (mount options + per-scenario app preference)

    /// App Group + keys shared with the host app's AppSettings (keep both in sync).
    /// macOS requires third-party group container identifiers to use the Team ID prefix.
    private static let appGroupID = "529LJDH392.group.com.huanchuan.xntfs"
    private static let deviceReadOnlyKey = "deviceReadOnly"
    private static let imageReadOnlyKey = "imageReadOnly"

    private struct ReadOnlyDecision {
        let readOnly: Bool
        let isImage: Bool
        let key: String?
        let storedPreference: Bool?
        let source: String
    }

    /// Read-only if the mount explicitly asks for it; otherwise (a system auto-mount,
    /// carrying no explicit ro/rw) fall back to the user's per-scenario default from the
    /// shared App Group container — keyed by whether this is a disk image (default
    /// read-only) or a physical drive (default read/write).
    private static func readOnlyDecision(_ opts: [String], resource: FSResource) -> ReadOnlyDecision {
        if requestsReadOnly(opts) {
            return ReadOnlyDecision(readOnly: true, isImage: false, key: nil, storedPreference: nil, source: "mount-option-ro")
        }
        if requestsReadWrite(opts) {
            return ReadOnlyDecision(readOnly: false, isImage: false, key: nil, storedPreference: nil, source: "mount-option-rw")
        }
        let isImage = isDiskImage(resource)
        let key = isImage ? imageReadOnlyKey : deviceReadOnlyKey
        let stored = storedPreference(forKey: key)
        return ReadOnlyDecision(readOnly: stored ?? isImage,
                                isImage: isImage,
                                key: key,
                                storedPreference: stored,
                                source: stored == nil ? "scenario-default" : "app-group")
    }

    private static func storedPreference(forKey key: String) -> Bool? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return nil
        }
        let url = container.appendingPathComponent("Library/Preferences/\(appGroupID).plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return plist[key] as? Bool
    }

    /// A disk image presents as a block device whose DiskArbitration device model is
    /// "Disk Image" or whose protocol is "Disk Image" (the same signal diskutil shows);
    /// anything else is a drive.
    private static func isDiskImage(_ resource: FSResource) -> Bool {
        if #available(macOS 26.0, *), resource is FSPathURLResource { return true }
        guard let block = resource as? FSBlockDeviceResource,
              let session = DASessionCreate(kCFAllocatorDefault) else { return false }
        let names = bsdNameCandidates(block.bsdName)
        for name in names {
            let disk = name.withCString { DADiskCreateFromBSDName(kCFAllocatorDefault, session, $0) }
            guard let disk, let desc = DADiskCopyDescription(disk) as? [String: Any] else { continue }
            let model = desc[kDADiskDescriptionDeviceModelKey as String] as? String
            let proto = desc[kDADiskDescriptionDeviceProtocolKey as String] as? String
            if model?.localizedCaseInsensitiveContains("disk image") == true ||
                proto?.localizedCaseInsensitiveContains("disk image") == true {
                return true
            }
        }
        return false
    }

    private static func bsdNameCandidates(_ name: String) -> [String] {
        if name.hasPrefix("/dev/") {
            return [name, String(name.dropFirst("/dev/".count))]
        }
        return [name, "/dev/\(name)"]
    }

    /// `-r`, `--rdonly`, `--read-only`, bare `ro`/`rdonly`, or `-o <list>` containing them.
    private static func requestsReadOnly(_ taskOptions: [String]) -> Bool {
        matchOptions(taskOptions, tokens: ["ro", "rdonly"], flags: ["-r", "--rdonly", "--read-only", "rdonly", "ro"])
    }
    /// `-w`, bare `rw`, or `-o <list>` containing `rw`.
    private static func requestsReadWrite(_ taskOptions: [String]) -> Bool {
        matchOptions(taskOptions, tokens: ["rw"], flags: ["-w", "rw"])
    }

    private static func matchOptions(_ taskOptions: [String], tokens: Set<String>, flags: Set<String>) -> Bool {
        var i = 0
        while i < taskOptions.count {
            let opt = taskOptions[i]
            if flags.contains(opt) { return true }
            var oArg: String? = nil
            if opt == "-o", i + 1 < taskOptions.count { oArg = taskOptions[i + 1]; i += 1 }
            else if opt.hasPrefix("-o"), opt.count > 2 { oArg = String(opt.dropFirst(2)) }
            if let oArg {
                for tok in oArg.split(separator: ",") where tokens.contains(tok.trimmingCharacters(in: .whitespaces)) { return true }
            }
            i += 1
        }
        return false
    }

    // MARK: probe / load / unload

    func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        debugLog("probeResource resource=\(resourceTypeDescription(resource))")
        var e: Int32 = 0
        guard let made = Self.makeBackend(resource, allowWrite: false, out: &e) else {   // probe never writes
            debugLog("probeResource makeBackend failed errno=\(e)")
            replyHandler(.notRecognized, nil)
            return
        }
        var nameBuf = [CChar](repeating: 0, count: 260)
        var serial: UInt64 = 0
        let recognized = nameBuf.withUnsafeMutableBufferPointer { nfsk_probe(made.backend, $0.baseAddress, $0.count, &serial) }
        let totalBytes = nfsk_block_total_bytes(made.backend)
        made.cleanup()
        nfsk_backend_free(made.backend)
        guard recognized == 1 else {
            debugLog("probeResource not recognized rc=\(recognized)")
            replyHandler(.notRecognized, nil)
            return
        }
        let label = String(cString: nameBuf)
        let uuid = NTFSVolumeSupport.volumeUUID(serial: serial, label: label, sizeBytes: totalBytes)
        let container = FSContainerIdentifier(uuid: uuid)
        debugLog("probeResource usable label=\(label) totalBytes=\(totalBytes) uuid=\(uuid.uuidString)")
        replyHandler(.usable(name: label, containerID: container), nil)
    }

    func loadResource(resource: FSResource, options: FSTaskOptions,
                      replyHandler: @escaping (FSVolume?, (any Error)?) -> Void) {
        debugLog("loadResource start resource=\(resourceTypeDescription(resource)) options=\(options.taskOptions)")
        let decision = Self.readOnlyDecision(options.taskOptions, resource: resource)
        var e: Int32 = 0
        // Block-device mount options arrive at activate, not load. Inspect metadata
        // read-only first, including when the user's default is read/write.
        guard let made = Self.makeBackend(resource, allowWrite: false, out: &e) else {
            let error = posixError(e)
            containerStatus = .notReady(status: error)
            debugLog("loadResource makeBackend failed errno=\(e)")
            replyHandler(nil, error)
            return
        }
        do {
            // ntfs3gVolume takes ownership of the backend; on failure its init frees
            // the backend and runs cleanup itself.
            let vol = try ntfs3gVolume(backend: made,
                                       activationBackend: { activationOptions, currentReadOnly in
                                           let explicitOptions = options.taskOptions + activationOptions
                                           let readOnly = Self.requestsReadOnly(explicitOptions) ? true
                                               : Self.requestsReadWrite(explicitOptions) ? false : decision.readOnly
                                           guard readOnly != currentReadOnly else { return nil }
                                           var error: Int32 = 0
                                           guard let backend = Self.makeBackend(resource, allowWrite: !readOnly, out: &error) else {
                                               throw posixError(error)
                                           }
                                           return backend
                                       },
                                       onContainerStatusChange: { [weak self] status in
                                           self?.containerStatus = status
                                       })
            self.volume = vol
            containerStatus = .ready
            debugLog("loadResource success name=\(vol.name.string ?? "") uuid=\(vol.volumeID.uuid.uuidString) initialReadOnly=true defaultReadOnly=\(decision.readOnly) decisionSource=\(decision.source) isImage=\(decision.isImage) key=\(decision.key ?? "none") storedPreference=\(String(describing: decision.storedPreference))")
            replyHandler(vol, nil)
        } catch {
            containerStatus = .notReady(status: error as NSError)
            debugLog("loadResource failed error=\(error)")
            replyHandler(nil, error)
        }
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions) async throws {
        debugLog("unloadResource resource=\(resourceTypeDescription(resource)) options=\(options.taskOptions)")
        volume?.teardown()
        volume = nil
        containerStatus = .notReady(status: posixError(EAGAIN))
    }

    // MARK: backend construction

    /// Build an I/O backend for either a block device or an image file
    /// (`FSPathURLResource`, macOS 26+). `allowWrite` gates write access at the lowest
    /// level: probe/load pass false, activation passes the resolved write policy. The
    /// backend is opened writable only when the operation allows it AND the resource itself
    /// is writable — so a probe never holds a writable handle, and a read-only mount can't
    /// write to the underlying file/device even if the media is writable. Returns nil if the
    /// resource type is unsupported or the backend couldn't be opened (`err` set).
    private static func makeBackend(_ resource: FSResource, allowWrite: Bool, out err: inout Int32) -> NTFSBackend? {
        if let block = resource as? FSBlockDeviceResource {
            guard let b = nfsk_backend_from_block(Unmanaged.passUnretained(block).toOpaque(), allowWrite ? 1 : 0) else {
                err = ENOMEM; return nil
            }
            return NTFSBackend(backend: b, retain: block, cleanup: {}, writable: allowWrite && block.isWritable)
        }
        if #available(macOS 26.0, *), let pathRes = resource as? FSPathURLResource {
            let url = pathRes.url
            let writable = allowWrite && pathRes.isWritable   // O_RDONLY unless writing is allowed
            let access = url.startAccessingSecurityScopedResource()
            var e: Int32 = 0
            let b = url.path.withCString { nfsk_backend_from_file($0, writable ? 1 : 0, &e) }
            guard let b else {
                if access { url.stopAccessingSecurityScopedResource() }
                err = (e != 0 ? e : EIO); return nil
            }
            return NTFSBackend(backend: b, retain: pathRes,
                           cleanup: { if access { url.stopAccessingSecurityScopedResource() } },
                           writable: writable)
        }
        err = EINVAL
        return nil
    }

    private func resourceTypeDescription(_ resource: FSResource) -> String {
        if let block = resource as? FSBlockDeviceResource {
            return "block(writable=\(block.isWritable))"
        }
        if #available(macOS 26.0, *), let path = resource as? FSPathURLResource {
            return "path(url=\(path.url.path), writable=\(path.isWritable))"
        }
        return String(describing: type(of: resource))
    }

    private func debugLog(_ message: String) {
        NSLog("[xntfs] \(message)")
    }

    // MARK: maintenance (required for block-device unary file systems)

    func startCheck(task: FSTask, options: FSTaskOptions) throws -> Progress {
        let progress = Progress(totalUnitCount: 1)
        debugLog("startCheck options=\(options.taskOptions)")
        DispatchQueue.global(qos: .utility).async {
            progress.completedUnitCount = 1
            task.didComplete(error: nil)
        }
        return progress
    }

    func startFormat(task: FSTask, options: FSTaskOptions) throws -> Progress {
        throw posixError(ENOTSUP)
    }
}
