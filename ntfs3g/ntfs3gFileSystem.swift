//
//  ntfs3gFileSystem.swift
//  FSUnaryFileSystem delegate: probes a resource (block device or image file),
//  loads it as an ntfs3gVolume (via libntfs-3g), and tears it down.
//

import Foundation
import FSKit

@available(macOS 15.4, *)
final class ntfs3gFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations,
                              FSManageableResourceMaintenanceOperations {

    private var volume: ntfs3gVolume?

    // MARK: probe / load / unload

    func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        debugLog("probeResource resource=\(resourceTypeDescription(resource))")
        var e: Int32 = 0
        guard let made = makeBackend(resource, out: &e) else {
            debugLog("probeResource makeBackend failed errno=\(e)")
            replyHandler(.notRecognized, nil)
            return
        }
        var nameBuf = [CChar](repeating: 0, count: 260)
        let recognized = nameBuf.withUnsafeMutableBufferPointer { nfsk_probe(made.backend, $0.baseAddress, $0.count) }
        let totalBytes = nfsk_block_total_bytes(made.backend)
        made.cleanup()
        nfsk_backend_free(made.backend)
        guard recognized == 1 else {
            debugLog("probeResource not recognized rc=\(recognized)")
            replyHandler(.notRecognized, nil)
            return
        }
        let label = String(cString: nameBuf)
        let uuid = NTFSVolumeSupport.stableUUID(label: label, sizeBytes: totalBytes)
        let container = FSContainerIdentifier(uuid: uuid)
        debugLog("probeResource usable label=\(label) totalBytes=\(totalBytes) uuid=\(uuid.uuidString)")
        replyHandler(.usable(name: label, containerID: container), nil)
    }

    func loadResource(resource: FSResource, options: FSTaskOptions,
                      replyHandler: @escaping (FSVolume?, (any Error)?) -> Void) {
        debugLog("loadResource start resource=\(resourceTypeDescription(resource)) options=\(options.taskOptions)")
        let forceReadOnly = options.taskOptions.contains("--rdonly") || options.taskOptions.contains("-r")
        var e: Int32 = 0
        guard let made = makeBackend(resource, out: &e) else {
            let error = posixError(e)
            containerStatus = .notReady(status: error)
            debugLog("loadResource makeBackend failed errno=\(e)")
            replyHandler(nil, error)
            return
        }
        do {
            // ntfs3gVolume takes ownership of the backend; on failure its init frees
            // the backend and runs cleanup itself.
            let vol = try ntfs3gVolume(backend: made.backend,
                                       readOnly: forceReadOnly || !made.writable,
                                       resourceRetain: made.retain,
                                       onTeardown: made.cleanup,
                                       onContainerStatusChange: { [weak self] status in
                                           self?.containerStatus = status
                                       })
            self.volume = vol
            containerStatus = .ready
            debugLog("loadResource success name=\(vol.name.string ?? "") uuid=\(vol.volumeID.uuid.uuidString) readOnly=\(forceReadOnly || !made.writable)")
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

    private struct Backend {
        let backend: UnsafeMutableRawPointer
        let retain: AnyObject?
        let cleanup: () -> Void
        let writable: Bool
    }

    /// Build an I/O backend for either a block device or an image file
    /// (`FSPathURLResource`, macOS 26+). Returns nil if the resource type is
    /// unsupported or the backend couldn't be opened (`err` set).
    private func makeBackend(_ resource: FSResource, out err: inout Int32) -> Backend? {
        if let block = resource as? FSBlockDeviceResource {
            guard let b = nfsk_backend_from_block(Unmanaged.passUnretained(block).toOpaque()) else {
                err = ENOMEM; return nil
            }
            return Backend(backend: b, retain: block, cleanup: {}, writable: block.isWritable)
        }
        if #available(macOS 26.0, *), let pathRes = resource as? FSPathURLResource {
            let url = pathRes.url
            let writable = pathRes.isWritable
            let access = url.startAccessingSecurityScopedResource()
            var e: Int32 = 0
            let b = url.path.withCString { nfsk_backend_from_file($0, writable ? 1 : 0, &e) }
            guard let b else {
                if access { url.stopAccessingSecurityScopedResource() }
                err = (e != 0 ? e : EIO); return nil
            }
            return Backend(backend: b, retain: pathRes,
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
