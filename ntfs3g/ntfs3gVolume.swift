//
//  ntfs3gVolume.swift
//  An FSVolume backed by an NTFS filesystem through libntfs-3g.
//
//  After initialization, libntfs-3g runs on a dedicated serial I/O queue.
//  FSKit's async callbacks suspend while it works; synchronous properties use
//  a separate snapshot and never wait for disk I/O.
//

import FSKit
import Foundation

@inline(__always)
func posixError(_ code: Int32) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code == 0 ? EIO : code))
}

struct NTFSBackend {
    let backend: UnsafeMutableRawPointer
    let retain: AnyObject?
    let cleanup: () -> Void
    let writable: Bool
}

@available(macOS 15.4, *)
final class ntfs3gVolume: FSVolume, FSVolume.Operations, FSVolume.PathConfOperations,
                          FSVolume.ReadWriteOperations, FSVolume.OpenCloseOperations,
                          FSVolume.XattrOperations, FSVolume.RenameOperations,
                          FSVolume.PreallocateOperations {

    private var handle: OpaquePointer?
    private var backend: NTFSBackend?
    private let activationBackend: ([String], Bool) throws -> NTFSBackend?
    private let onContainerStatusChange: (FSContainerStatus) -> Void
    private var tornDown = false
    // Includes an old handle destroyed by a failed activation replacement.
    private var teardownResult: Int32 = 0
    private var readOnly: Bool
    private var activated = false
    var diagnosticContext: [DiagnosticEvent.Field: String] = [:]
    // Drain autoreleased bridge/FSKit temporaries after each callback, even
    // under a continuous backlog. Strong in-flight arguments/results remain owned.
    private let ioQueue = DispatchQueue(label: "com.huanchuan.xntfs.volume.io", qos: .userInitiated,
                                        autoreleaseFrequency: .workItem)
    private let snapshotLock = NSLock()
    private let writeAdmissionLock = NSLock()
    // Protected by writeAdmissionLock: once final teardown is queued, later writes
    // cannot reach a live handle. Do not retain them behind stalled earlier I/O.
    private var retirementQueued = false
    // Property readers need counters only; do not retain/copy the legacy
    // 1024-byte name or mount-only serial under the snapshot lock.
    private struct StatisticsSnapshot {
        let cluster_size: UInt32
        let total_clusters: UInt64
        let free_clusters: UInt64
        let total_files: UInt64
        let free_files: UInt64
        let read_only: UInt8

        init(_ statistics: nfsk_statfs_counters_t) {
            cluster_size = statistics.cluster_size
            total_clusters = statistics.total_clusters
            free_clusters = statistics.free_clusters
            total_files = statistics.total_files
            free_files = statistics.free_files
            read_only = statistics.read_only
        }
    }
    private var cachedStatistics: StatisticsSnapshot
    private var items: [UInt64: ntfs3gItem] = [:]
    private let rootItem: ntfs3gItem
    private let legacyOpenUnlink: Bool

    static var needsLegacyOpenUnlink: Bool {
        if #available(macOS 26.0, *) { return false }
        return true
    }

    /// `backend` comes from `nfsk_backend_from_block` / `nfsk_backend_from_file`.
    /// Ownership of `backend` transfers to this volume (freed in `teardown`).
    init(backend: NTFSBackend,
         activationBackend: @escaping ([String], Bool) throws -> NTFSBackend?,
         onContainerStatusChange: @escaping (FSContainerStatus) -> Void,
         legacyOpenUnlink: Bool = ntfs3gVolume.needsLegacyOpenUnlink) throws {
        var err: Int32 = 0
        guard let h = nfsk_mount(backend.backend, !backend.writable, &err) else {
            backend.cleanup()
            nfsk_backend_free(backend.backend)
            throw posixError(err)
        }
        var st = nfsk_statfs_counters_t()
        let statResult = nfsk_statfs_counters(h, &st)
        guard statResult == 0, let cachedName = nfsk_volume_name(h) else {
            nfsk_umount(h)
            nfsk_backend_free(backend.backend)
            backend.cleanup()
            throw posixError(-statResult)
        }
        let label = String(cString: cachedName)
        let volName = label.isEmpty ? "NTFS" : label
        let totalBytes = st.total_clusters &* UInt64(st.cluster_size)
        let root = ntfs3gItem(ino: NFSK_ROOT_INO,
                              parentIno: FSItem.Identifier.parentOfRoot.rawValue,
                              name: FSFileName(string: volName))

        self.handle = h
        self.backend = backend
        self.readOnly = st.read_only != 0
        self.cachedStatistics = StatisticsSnapshot(st)
        self.activationBackend = activationBackend
        self.onContainerStatusChange = onContainerStatusChange
        self.rootItem = root
        self.legacyOpenUnlink = legacyOpenUnlink

        let vid = FSVolume.Identifier(uuid: NTFSVolumeSupport.volumeUUID(serial: st.volume_serial, label: volName, sizeBytes: totalBytes))
        super.init(volumeID: vid, volumeName: FSFileName(string: volName))
        self.items[NFSK_ROOT_INO] = root
    }

    @discardableResult
    func teardown() async -> Int32 {
        await withIO(retiring: true) { [self] in
            if tornDown { return teardownResult }
            tornDown = true
            if let h = handle { teardownResult = nfsk_umount(h); handle = nil }
            if let b = backend { nfsk_backend_free(b.backend); b.cleanup(); backend = nil }
            items.removeAll()
            return teardownResult
        }
    }

    // MARK: serialized I/O and nonblocking property snapshots
    // The work item retains each callback's arguments until it resumes the
    // continuation. Cancellation must not release FSKit buffers or the backend
    // while synchronous libntfs I/O is still running. Mutable volume state stays
    // on this queue, except for the locked statistics snapshot and write admission.
    @discardableResult
    private func withIO<T>(rejectAfterTeardown: Bool = false, _ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            if rejectAfterTeardown {
                writeAdmissionLock.lock()
                if retirementQueued {
                    writeAdmissionLock.unlock()
                    continuation.resume(throwing: posixError(EINVAL))
                    return
                }
            }
            ioQueue.async(execute: DispatchWorkItem { [self] in
                let result = Result { try body() }
                refreshStatistics()
                continuation.resume(with: result)
            })
            if rejectAfterTeardown { writeAdmissionLock.unlock() }
        }
    }

    @discardableResult
    private func withIO<T>(retiring: Bool = false, _ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            if retiring {
                writeAdmissionLock.lock()
                retirementQueued = true
            }
            ioQueue.async(execute: DispatchWorkItem { [self] in
                let result = body()
                refreshStatistics()
                continuation.resume(returning: result)
            })
            if retiring { writeAdmissionLock.unlock() }
        }
    }

    private func refreshStatistics() {
        dispatchPrecondition(condition: .onQueue(ioQueue))
        var statistics = nfsk_statfs_counters_t()
        statistics.read_only = readOnly ? 1 : 0
        // Read in-memory counters and the cached serial without copying a name. Do this
        // before taking snapshotLock; it must never protect a bridge operation.
        if let h = handle { _ = nfsk_statfs_counters(h, &statistics) }
        let snapshot = StatisticsSnapshot(statistics)
        snapshotLock.lock()
        cachedStatistics = snapshot
        snapshotLock.unlock()
    }

    private func statisticsSnapshot() -> StatisticsSnapshot {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return cachedStatistics
    }

    // FSKit accounts for returned items in its reply handler. Keep that handoff
    // on the same queue as tryReclaim; resuming an async Swift function here
    // would leave its eventual reply outside the synchronization boundary.
    private func replyWithItem(_ reply: @escaping (FSItem?, FSFileName?, Error?) -> Void,
                               _ body: @escaping () throws -> (FSItem, FSFileName)) {
        ioQueue.async(execute: DispatchWorkItem { [self] in
            let result = Result { try body() }
            refreshStatistics()
            switch result {
            case .success(let (item, name)): reply(item, name, nil)
            case .failure(let error): reply(nil, nil, error)
            }
        })
    }

    private func item(for ino: UInt64, parentIno: UInt64, name: FSFileName) -> ntfs3gItem {
        // FSKit identity is per-fileID (inode), so we cache one item per inode. The
        // parentIno/name held here are only a fallback hint: reported attributes take
        // their parent from the bridge (derived from the inode's FILE_NAME), so they
        // don't shift when the same inode is reached through another hard-link path.
        if let existing = items[ino] { return existing }
        let it = ntfs3gItem(ino: ino, parentIno: parentIno, name: name)
        items[ino] = it
        return it
    }

    fileprivate func makeAttributes(_ a: nfsk_attr_t, parentIno: UInt64, preferContext: Bool = false) -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        attrs.type = FSItem.ItemType(rawValue: Int(a.type)) ?? .file
        attrs.mode = a.mode
        attrs.linkCount = a.nlink
        attrs.size = a.size
        attrs.allocSize = a.alloc_size
        attrs.fileID = FSItem.Identifier(rawValue: a.ino) ?? .invalid
        // Parent reporting: directory enumeration knows the directory being listed and
        // passes preferContext=true to report it, so a hard link's parentID stays
        // consistent with the directory it appears in. Context-free attributes(of:)
        // instead prefer the stable parent the bridge derives from the inode's
        // FILE_NAME (not mutated by lookups, so a held handle's parentID can't be
        // corrupted by another hard-link path), falling back to the supplied hint.
        let parent = preferContext ? parentIno : (a.parent_ino != 0 ? a.parent_ino : parentIno)
        attrs.parentID = FSItem.Identifier(rawValue: parent) ?? .invalid
        attrs.uid = 0
        attrs.gid = 0
        attrs.flags = a.flags
        attrs.modifyTime = timespec(tv_sec: Int(a.mtime_sec), tv_nsec: Int(a.mtime_nsec))
        attrs.accessTime = timespec(tv_sec: Int(a.atime_sec), tv_nsec: Int(a.atime_nsec))
        attrs.changeTime = timespec(tv_sec: Int(a.ctime_sec), tv_nsec: Int(a.ctime_nsec))
        attrs.birthTime  = timespec(tv_sec: Int(a.btime_sec), tv_nsec: Int(a.btime_nsec))
        return attrs
    }

    // MARK: properties
    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let caps = FSVolume.SupportedCapabilities()
        caps.supportsHardLinks = true           // via ntfs_link (writable mounts)
        caps.supportsSymbolicLinks = true
        caps.supportsPersistentObjectIDs = true
        caps.supports64BitObjectIDs = true
        caps.supports2TBFiles = true
        caps.supportsSparseFiles = true
        caps.supportsHiddenFiles = true
        caps.caseFormat = .insensitiveCasePreserving
        return caps
    }

    var volumeStatistics: FSStatFSResult {
        // Must match the extension's FSShortName (ntfs3g/Info.plist) so the mounted
        // volume's statfs f_fstypename reads "xntfs" — that is how the app tells our
        // mounts apart from the legacy system NTFS driver.
        let stats = FSStatFSResult(fileSystemTypeName: "xntfs")
        let st = statisticsSnapshot()
        let bs = Int(st.cluster_size == 0 ? 4096 : st.cluster_size)
        stats.blockSize = bs
        stats.ioSize = bs
        stats.totalBlocks = st.total_clusters
        stats.availableBlocks = st.free_clusters
        stats.freeBlocks = st.free_clusters
        stats.usedBlocks = st.total_clusters > st.free_clusters ? st.total_clusters - st.free_clusters : 0
        stats.totalFiles = st.total_files
        stats.freeFiles = st.free_files
        return stats
    }

    // FSKit retains unlinked/overwritten open files until their last reference closes.
    @available(macOS 26.0, *)
    var enableOpenUnlinkEmulation: Bool { true }

    @available(macOS 26.4, *)
    var requestedMountOptions: FSVolume.MountOptions {
        get { statisticsSnapshot().read_only != 0 ? [.readOnly] : [] }
        set { }
    }

    // MARK: lifecycle
    private func withRecordedIO<T>(_ action: DiagnosticEvent.Action, _ body: @escaping () throws -> T) async throws -> T {
        try await withIO { [self] in
            DiagnosticRecorder.shared.record(action, .started, fields: diagnosticContext)
            do {
                let result = try body()
                DiagnosticRecorder.shared.record(action, .succeeded,
                    fields: diagnosticContext.merging([.effectiveReadOnly: String(readOnly)]) { _, new in new })
                return result
            } catch {
                DiagnosticRecorder.shared.record(action, .failed, fields: diagnosticContext, error: error)
                throw error
            }
        }
    }

    func quickCheck() async throws {
        try await withRecordedIO(.check) { [self] in
            guard !tornDown, let backend, handle != nil else { throw posixError(ENXIO) }
            guard !activated, readOnly else { throw posixError(EBUSY) }
            var reason: Int32 = 0
            let rc = nfsk_quick_check(backend.backend, &reason)
            guard rc == 0 else {
                DiagnosticRecorder.shared.record(.check, .failed,
                    fields: diagnosticContext.merging([.reason: String(reason)]) { _, new in new }, error: posixError(-rc))
                let detail: String
                switch reason {
                case Int32(NFSK_CHECK_DIRTY): detail = "The NTFS volume is marked dirty or a Windows disk check is in progress."
                case Int32(NFSK_CHECK_HIBERNATED): detail = "Windows hibernation or Fast Startup prevents writable mounting. Fully shut down Windows first."
                case Int32(NFSK_CHECK_JOURNAL): detail = "The NTFS journal is unclean, unreadable, or contains cached Windows metadata."
                default: detail = "NTFS core metadata could not be read or validated."
                }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(-rc), userInfo: [
                    NSLocalizedDescriptionKey: detail + " No repairs were attempted."
                ])
            }
        }
    }

    func activate(options: FSTaskOptions) async throws -> FSItem {
        try await activate(mountOptions: options.taskOptions)
    }

    func activate(mountOptions: [String]) async throws -> FSItem {
        try await withRecordedIO(.activate) { [self] in
            guard !tornDown, handle != nil else { throw posixError(ENXIO) }
            guard !activated else { throw posixError(EBUSY) }
            // Disk Arbitration supplies ro/rw here, after loadResource. Reopen before
            // exposing any items; loading metadata itself must never require writes.
            if let replacement = try activationBackend(mountOptions, readOnly) {
                let closeResult = handle.map { nfsk_umount($0) } ?? 0
                handle = nil
                if let b = backend { nfsk_backend_free(b.backend); b.cleanup() }
                backend = nil
                guard closeResult == 0 else {
                    teardownResult = closeResult
                    nfsk_backend_free(replacement.backend)
                    replacement.cleanup()
                    throw posixError(-closeResult)
                }
                backend = replacement
                readOnly = !replacement.writable
                var err: Int32 = 0
                guard let h = nfsk_mount(replacement.backend, readOnly, &err) else { throw posixError(err) }
                handle = h
                var st = nfsk_statfs_counters_t()
                let rc = nfsk_statfs_counters(h, &st)
                guard rc == 0 else { throw posixError(-rc) }
                readOnly = st.read_only != 0
            }
            activated = true
            // Publish on the same queue as deactivate, after the mount-option
            // snapshot is ready. Async continuation scheduling must not reorder
            // the container's active/ready notifications.
            refreshStatistics()
            onContainerStatusChange(.active)
            return rootItem
        }
    }

    func deactivate(options: FSDeactivateOptions = []) async throws {
        await withIO { [self] in
            guard !tornDown else { return }
            activated = false
            onContainerStatusChange(.ready)
        }
    }

    func mount(options: FSTaskOptions) async throws {
        try await mount()
    }

    func mount() async throws {
        try await withRecordedIO(.mount) { [self] in
            guard !tornDown, handle != nil else { throw posixError(ENXIO) }
            // Older FSKit cannot request MNT_RDONLY after a writable activation.
            // Require an explicit read-only retry instead of exposing a writable mount.
            if #unavailable(macOS 26.4), readOnly && backend?.writable == true {
                throw posixError(EROFS)
            }
        }
    }
    func unmount() async {
        await withIO { [self] in
            let rc = synchronizeOnQueue()
            if rc != 0 {
                DiagnosticRecorder.shared.record(.unmount, .failed, fields: diagnosticContext, error: posixError(-rc))
                NSLog("[xntfs] flush on unmount failed: errno \(-rc)")
            } else { DiagnosticRecorder.shared.record(.unmount, .succeeded, fields: diagnosticContext) }
        }
    }

    func synchronize(flags: FSSyncFlags) async throws {
        try await withIO { [self] in
            let rc = synchronizeOnQueue()
            if rc != 0 {
                DiagnosticRecorder.shared.record(.sync, .failed, fields: diagnosticContext, error: posixError(-rc))
                throw posixError(-rc)
            }
        }
    }

    private func synchronizeOnQueue() -> Int32 {
        dispatchPrecondition(condition: .onQueue(ioQueue))
        if let h = handle { return nfsk_sync(h) }
        // Queued or repeated sync must not turn failed destruction into success.
        if teardownResult != 0 { return teardownResult }
        // Successful retirement is idempotent; an incomplete activation is not.
        return tornDown ? 0 : -ENXIO
    }

    // MARK: attributes
    func attributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem) async throws -> FSItem.Attributes {
        try await withIO { [self] in
            guard let it = item as? ntfs3gItem, let h = handle else { throw posixError(EINVAL) }
            var a = nfsk_attr_t()
            let rc = nfsk_getattr(h, it.ino, &a)
            if rc != 0 { throw posixError(-rc) }
            return makeAttributes(a, parentIno: it.parentIno)
        }
    }

    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem) async throws -> FSItem.Attributes {
        try await withIO { [self] in
            guard let it = item as? ntfs3gItem, let h = handle else { throw posixError(EINVAL) }
            return try applyAttributes(newAttributes, ino: it.ino, parent: it.parentIno, handle: h)
        }
    }

    private func sizeRequest(_ request: FSItem.SetAttributesRequest, type: UInt32) throws -> UInt64? {
        // FSKit requires sizes on directories and symbolic links to be ignored.
        guard request.isValid(.size), type != UInt32(NFSK_TYPE_DIR), type != UInt32(NFSK_TYPE_SYMLINK) else { return nil }
        guard request.size <= UInt64(Int64.max) else { throw posixError(EFBIG) }
        return request.size
    }

    private func metadataRequest(_ request: FSItem.SetAttributesRequest) throws -> nfsk_metadata_t {
        // Unsupported optional fields such as backupTime stay unconsumed.
        var metadata = nfsk_metadata_t()
        if request.isValid(.modifyTime) {
            metadata.valid |= UInt32(NFSK_SET_MTIME)
            metadata.mtime_sec = Int64(request.modifyTime.tv_sec)
            metadata.mtime_nsec = Int64(request.modifyTime.tv_nsec)
        }
        if request.isValid(.accessTime) {
            metadata.valid |= UInt32(NFSK_SET_ATIME)
            metadata.atime_sec = Int64(request.accessTime.tv_sec)
            metadata.atime_nsec = Int64(request.accessTime.tv_nsec)
        }
        if request.isValid(.birthTime) {
            metadata.valid |= UInt32(NFSK_SET_BTIME)
            metadata.btime_sec = Int64(request.birthTime.tv_sec)
            metadata.btime_nsec = Int64(request.birthTime.tv_nsec)
        }
        if request.isValid(.flags) {
            metadata.valid |= UInt32(NFSK_SET_FLAGS)
            metadata.flags = request.flags
        }
        let rc = nfsk_validate_metadata(&metadata)
        if rc != 0 { throw posixError(-rc) }
        return metadata
    }

    // Called on ioQueue, including while initializing a new item.
    private func applyAttributes(_ request: FSItem.SetAttributesRequest, ino: UInt64,
                                 parent: UInt64, handle: OpaquePointer) throws -> FSItem.Attributes {
        guard !readOnly else { throw posixError(EROFS) }
        var metadata = try metadataRequest(request)
        var attributes = nfsk_attr_t()
        let initial = nfsk_getattr(handle, ino, &attributes)
        if initial != 0 { throw posixError(-initial) }
        request.consumedAttributes = []
        // Preserve the existing ignored-ownership policy: mode/uid/gid remain
        // unconsumed. Rejecting them here also rejects otherwise valid copy metadata.
        if let size = try sizeRequest(request, type: attributes.type) {
            if attributes.type == UInt32(NFSK_TYPE_FILE) {
                let rc = nfsk_truncate(handle, ino, size)
                if rc != 0 { throw posixError(-rc) }
            } else if size != attributes.size { throw posixError(EINVAL) }
            request.consumedAttributes.insert(.size)
        }
        if metadata.valid != 0 {
            let rc = nfsk_set_metadata(handle, ino, &metadata)
            if rc != 0 { throw posixError(-rc) }
            for attribute: FSItem.Attribute in [.modifyTime, .accessTime, .birthTime, .flags] where request.isValid(attribute) {
                request.consumedAttributes.insert(attribute)
            }
        }
        let rc = nfsk_getattr(handle, ino, &attributes)
        if rc != 0 { throw posixError(-rc) }
        return makeAttributes(attributes, parentIno: parent)
    }

    // MARK: lookup / reclaim
    // FSFileName.string consumes a leading BOM; basenames use the raw UTF8 bytes.
    private func resolvedName(_ name: String, in directory: UInt64, handle: OpaquePointer) throws -> (UInt64, FSFileName) {
        var error: Int32 = 0
        var canonical: UnsafeMutablePointer<CChar>?
        defer { free(canonical) }
        let ino = name.withCString { requested in
            nfsk_lookup_name_alloc(handle, directory, requested, &canonical, &error)
        }
        guard ino != 0 else { throw posixError(error == 0 ? ENOENT : error) }
        guard let canonical else { throw posixError(EIO) }
        return (ino, FSFileName(string: String(cString: canonical)))
    }

    func lookupItem(named name: FSFileName, inDirectory directory: FSItem,
                    replyHandler: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        replyWithItem(replyHandler) { [self] in
            guard let dir = directory as? ntfs3gItem, let h = handle, let nameStr = String(validating: name.data, as: UTF8.self) else { throw posixError(EINVAL) }
            let (ino, fsName) = try resolvedName(nameStr, in: dir.ino, handle: h)
            return (item(for: ino, parentIno: dir.ino, name: fsName), fsName)
        }
    }

    func reclaimItem(_ item: FSItem) async throws {
        try await withIO { [self] in
            guard let it = item as? ntfs3gItem else { return }
            guard it.ino != NFSK_ROOT_INO else { return }
            var reclaimError: Error?
            let removeCachedItem = {
                if self.items[it.ino] === it, let handle = self.handle {
                    let rc = nfsk_close_item(handle, it.ino)
                    if rc != 0 { reclaimError = posixError(-rc) }
                }
                if self.items[it.ino] === it { self.items.removeValue(forKey: it.ino) }
            }
            if #available(macOS 27.0, *) {
                _ = it.tryReclaim(removeCachedItem)
            } else {
                removeCachedItem()
            }
            if let reclaimError { throw reclaimError }
        }
    }

    private func evictDeletedItem(_ item: FSItem, handle: OpaquePointer) {
        guard let it = item as? ntfs3gItem, items[it.ino] === it else { return }
        var attributes = nfsk_attr_t()
        // NTFS may immediately reuse the record. A later create must get a new
        // FSItem, even if FSKit has not delivered the deleted object's reclaim yet.
        if nfsk_getattr(handle, it.ino, &attributes) == -ENOENT {
            items.removeValue(forKey: it.ino)
        }
    }

    func readSymbolicLink(_ item: FSItem) async throws -> FSFileName {
        try await withIO { [self] in
            guard let it = item as? ntfs3gItem, let h = handle else { throw posixError(EINVAL) }
            var target: UnsafeMutablePointer<CChar>?
            defer { free(target) }
            let rc = nfsk_readlink_alloc(h, it.ino, &target, 4096)
            if rc != 0 { throw posixError(-rc) }
            guard let target else { throw posixError(EIO) }
            return FSFileName(string: String(cString: target))
        }
    }

    // MARK: create / remove / rename
    func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem,
                    attributes newAttributes: FSItem.SetAttributesRequest,
                    replyHandler: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        replyWithItem(replyHandler) { [self] in
            guard let dir = directory as? ntfs3gItem, let h = handle, let nameStr = String(validating: name.data, as: UTF8.self) else { throw posixError(EINVAL) }
            guard type == .file || type == .directory else { throw posixError(ENOTSUP) }
            _ = try metadataRequest(newAttributes)
            let kind = UInt32(type == .directory ? NFSK_TYPE_DIR : NFSK_TYPE_FILE)
            _ = try sizeRequest(newAttributes, type: kind)
            var err: Int32 = 0
            let ino = nameStr.withCString { nfsk_create(h, dir.ino, $0, kind, &err) }
            if ino == 0 { throw posixError(err) }
            do { _ = try applyAttributes(newAttributes, ino: ino, parent: dir.ino, handle: h) }
            catch {
                let cleanup = nameStr.withCString { nfsk_remove(h, dir.ino, $0) }
                if cleanup != 0 { NSLog("[xntfs] failed to remove incompletely initialized item: errno \(-cleanup)") }
                throw error
            }
            let fsName = FSFileName(string: nameStr)
            items.removeValue(forKey: ino)
            return (item(for: ino, parentIno: dir.ino, name: fsName), fsName)
        }
    }

    func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem,
                            attributes newAttributes: FSItem.SetAttributesRequest,
                            linkContents contents: FSFileName,
                            replyHandler: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        replyWithItem(replyHandler) { [self] in
            guard let dir = directory as? ntfs3gItem, let h = handle,
                  let nameStr = String(validating: name.data, as: UTF8.self),
                  let target = String(validating: contents.data, as: UTF8.self),
                  !nameStr.utf8.contains(0), !target.utf8.contains(0) else { throw posixError(EINVAL) }
            _ = try metadataRequest(newAttributes)
            var error: Int32 = 0
            let ino = nameStr.withCString { name in
                target.withCString { nfsk_symlink(h, dir.ino, name, $0, &error) }
            }
            guard ino != 0 else { throw posixError(error) }
            do { _ = try applyAttributes(newAttributes, ino: ino, parent: dir.ino, handle: h) }
            catch {
                let cleanup = nameStr.withCString { nfsk_remove(h, dir.ino, $0) }
                if cleanup != 0 { NSLog("[xntfs] failed to remove incompletely initialized symlink: errno \(-cleanup)") }
                throw error
            }
            let actual = FSFileName(string: nameStr)
            items.removeValue(forKey: ino)
            return (item(for: ino, parentIno: dir.ino, name: actual), actual)
        }
    }

    func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem) async throws -> FSFileName {
        try await withIO { [self] in
            guard let target = item as? ntfs3gItem, let dir = directory as? ntfs3gItem,
                  let h = handle, let nameStr = String(validating: name.data, as: UTF8.self) else { throw posixError(EINVAL) }
            var err: Int32 = 0
            let rc = nameStr.withCString { nfsk_link(h, target.ino, dir.ino, $0, &err) }
            if rc != 0 { throw posixError(err) }
            return FSFileName(string: nameStr)
        }
    }

    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem) async throws {
        try await withIO { [self] in
            guard let dir = directory as? ntfs3gItem, let h = handle, let nameStr = String(validating: name.data, as: UTF8.self) else { throw posixError(EINVAL) }
            let rc = nameStr.withCString { nfsk_remove(h, dir.ino, $0) }
            if rc != 0 { throw posixError(-rc) }
            evictDeletedItem(item, handle: h)
        }
    }

    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName,
                    to destinationName: FSFileName, inDirectory destinationDirectory: FSItem,
                    overItem: FSItem?) async throws -> FSFileName {
        try await withIO { [self] in
            guard let sdir = sourceDirectory as? ntfs3gItem, let ddir = destinationDirectory as? ntfs3gItem,
                  let h = handle, let src = String(validating: sourceName.data, as: UTF8.self),
                  let dst = String(validating: destinationName.data, as: UTF8.self) else { throw posixError(EINVAL) }
            let rc = src.withCString { sp in dst.withCString { dp in nfsk_rename(h, sdir.ino, sp, ddir.ino, dp) } }
            if rc != 0 { throw posixError(-rc) }
            if let overItem { evictDeletedItem(overItem, handle: h) }
            let (_, actualName) = try resolvedName(dst, in: ddir.ino, handle: h)
            if let it = item as? ntfs3gItem {
                it.parentIno = ddir.ino
                it.name = actualName
            }
            return actualName
        }
    }

    // MARK: enumeration
    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier,
                            attributes: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker) async throws -> FSDirectoryVerifier {
        try await withIO { [self] in
            guard let dir = directory as? ntfs3gItem, let h = handle else { throw posixError(EINVAL) }
            let wantDots = (attributes == nil)
            let c = cookie.rawValue
            guard c <= UInt64(Int64.max) + 2 else { throw posixError(EINVAL) }
            let ctx = EnumContext(volume: self, packer: packer, parentIno: dir.ino)

            if wantDots {
                if c < 1 {
                    if !ctx.packRaw(name: ".", ino: dir.ino, type: UInt32(NFSK_TYPE_DIR), nextCookie: 1) {
                        return FSDirectoryVerifier(rawValue: 1)
                    }
                }
                if c < 2 {
                    let parent = dir.ino == NFSK_ROOT_INO ? dir.ino : dir.parentIno
                    if !ctx.packRaw(name: "..", ino: parent, type: UInt32(NFSK_TYPE_DIR), nextCookie: 2) {
                        return FSDirectoryVerifier(rawValue: 1)
                    }
                }
            }
            let realSkip: Int64 = c <= 2 ? 0 : Int64(c - 2)
            let ctxPtr = Unmanaged.passUnretained(ctx).toOpaque()
            let rc = attributes == nil
                ? nfsk_readdir(h, dir.ino, realSkip, ctxPtr, enumTrampoline)
                : nfsk_readdir_attributes(h, dir.ino, realSkip, ctxPtr, enumAttributesTrampoline)
            // A full packer is a normal C callback stop (rc == 0). A later
            // directory-close error must still reach FSKit.
            if rc != 0 { throw posixError(-rc) }
            return FSDirectoryVerifier(rawValue: 1)
        }
    }

    // MARK: PathConf
    var maximumLinkCount: Int { 1023 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { false }
    var truncatesLongNames: Bool { false }
    var maximumFileSize: UInt64 { UInt64(Int64.max) }
    // FSKit's automatic conversion adds one; UInt64.max overflows and makes
    // Finder see a 2 GiB limit. Match the bridge's signed 64-bit file offsets.
    var maximumFileSizeInBits: Int { 64 }
    var maximumXattrSize: Int { Int(NFSK_MAX_XATTR_SIZE) }

    // MARK: Extended attributes
    func xattr(named name: FSFileName, of item: FSItem) async throws -> Data {
        try await withIO { [self] in
            // Foundation's string conversion consumes a leading BOM; xattr
            // names use the exact bytes supplied by FSKit.
            guard let it = item as? ntfs3gItem, let h = handle,
                  let key = String(validating: name.data, as: UTF8.self), !key.utf8.contains(0) else { throw posixError(EINVAL) }
            return try key.withCString { key in
                var buffer: UnsafeMutableRawPointer?
                let size = nfsk_getxattr_alloc(h, it.ino, key, &buffer)
                if size < 0 { throw posixError(Int32(-size)) }
                guard let buffer else {
                    guard size == 0 else { throw posixError(EIO) }
                    return Data()
                }
                // The bridge closes libntfs objects before handing off this
                // allocation. Data owns it across continuation/FSKit replies.
                return Data(bytesNoCopy: buffer, count: Int(size), deallocator: .free)
            }
        }
    }

    func setXattr(named name: FSFileName, to value: Data?, on item: FSItem,
                  policy: FSVolume.SetXattrPolicy) async throws {
        try await withIO(rejectAfterTeardown: true) { [self] in
            guard let it = item as? ntfs3gItem, let h = handle,
                  let key = String(validating: name.data, as: UTF8.self), !key.utf8.contains(0) else { throw posixError(EINVAL) }
            let bridgePolicy: Int32
            switch policy {
            case .alwaysSet: bridgePolicy = Int32(NFSK_XATTR_SET)
            case .mustCreate: bridgePolicy = Int32(NFSK_XATTR_CREATE)
            case .mustReplace: bridgePolicy = Int32(NFSK_XATTR_REPLACE)
            case .delete: bridgePolicy = Int32(NFSK_XATTR_DELETE)
            @unknown default: throw posixError(EINVAL)
            }
            let rc: Int32 = try key.withCString { key in
                if policy == .delete { return nfsk_setxattr(h, it.ino, key, nil, 0, bridgePolicy) }
                guard let value else { throw posixError(EINVAL) }
                return value.withUnsafeBytes { nfsk_setxattr(h, it.ino, key, $0.baseAddress, $0.count, bridgePolicy) }
            }
            if rc < 0 { throw posixError(-rc) }
        }
    }

    func xattrs(of item: FSItem) async throws -> [FSFileName] {
        try await withIO { [self] in
            guard let it = item as? ntfs3gItem, let h = handle else { throw posixError(EINVAL) }
            var buffer: UnsafeMutablePointer<CChar>?
            let size = nfsk_listxattr_alloc(h, it.ino, &buffer)
            if size < 0 { throw posixError(Int32(-size)) }
            defer { free(buffer) }
            if size == 0 { return [] }
            guard let buffer else { throw posixError(EIO) }
            let bytes = UnsafeRawBufferPointer(start: buffer, count: Int(size))
            return try bytes.split(separator: 0).map { name in
                guard let string = String(validating: name, as: UTF8.self) else {
                    throw posixError(EIO)
                }
                return FSFileName(string: string)
            }
        }
    }

    // MARK: ReadWrite
    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer) async throws -> Int {
        try await withIO { [self] in
            guard let it = item as? ntfs3gItem, let h = handle else { throw posixError(EINVAL) }
            let cap = min(length, buffer.length)
            var err: Int32 = 0
            let n = buffer.withUnsafeMutableBytes { raw in
                nfsk_read(h, it.ino, Int64(offset), raw.baseAddress, Int64(cap), &err)
            }
            if n < 0 { throw posixError(err) }
            return Int(n)
        }
    }

    func write(contents: Data, to item: FSItem, at offset: off_t) async throws -> Int {
        try await withIO(rejectAfterTeardown: true) { [self] in
            guard let it = item as? ntfs3gItem, let h = handle else { throw posixError(EINVAL) }
            var err: Int32 = 0
            let n = contents.withUnsafeBytes { raw in
                nfsk_write(h, it.ino, Int64(offset), raw.baseAddress, Int64(raw.count), &err)
            }
            if n < 0 { throw posixError(err) }
            return Int(n)
        }
    }

    // MARK: Volume name / preallocation
    func setVolumeName(_ name: FSFileName) async throws -> FSFileName {
        try await withIO { [self] in
            guard let h = handle, let label = String(validating: name.data, as: UTF8.self), !label.utf8.contains(0) else { throw posixError(EINVAL) }
            let rc = label.withCString { nfsk_rename_volume(h, $0) }
            if rc != 0 { throw posixError(-rc) }
            self.name = name
            rootItem.name = name
            return name
        }
    }

    func preallocateSpace(for item: FSItem, at offset: off_t, length: Int,
                          flags: FSVolume.PreallocateFlags) async throws -> Int {
        try await withIO { [self] in
            guard let h = handle, let item = item as? ntfs3gItem else { throw posixError(EINVAL) }
            guard !readOnly else { throw posixError(EROFS) }
            let supported: FSVolume.PreallocateFlags = [.all, .persist, .fromEOF]
            guard flags.subtracting(supported).isEmpty else { throw posixError(ENOTSUP) }
            let rc = nfsk_preallocate(h, item.ino, Int64(offset), Int64(length), flags.contains(.fromEOF))
            if rc < 0 { throw posixError(Int32(-rc)) }
            return Int(rc)
        }
    }

    // MARK: OpenClose
    func openItem(_ item: FSItem, modes: FSVolume.OpenModes) async throws {
        try await withIO { [self] in
            guard let h = handle, let it = item as? ntfs3gItem else { throw posixError(EINVAL) }
            if readOnly && modes.contains(.write) { throw posixError(EROFS) }
            if modes.contains(.write) {
                // Reject before the kernel can cache bytes from a failed write.
                let rc = nfsk_check_write_access(h, it.ino)
                if rc != 0 { throw posixError(-rc) }
            }
            guard legacyOpenUnlink else { return }
            let rc = nfsk_open_item(h, it.ino)
            if rc != 0 { throw posixError(-rc) }
        }
    }

    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes) async throws {
        guard modes.isEmpty else { return }
        try await withIO { [self] in
            guard let h = handle, let it = item as? ntfs3gItem else { throw posixError(EINVAL) }
            guard items[it.ino] === it else { return }
            let rc = nfsk_close_item(h, it.ino)
            if rc != 0 { throw posixError(-rc) }
            evictDeletedItem(item, handle: h)
        }
    }
}

@available(macOS 27.0, *)
extension ntfs3gVolume: FSVolume.SeekRegionHandler {
    func seek(within item: FSItem, from offset: off_t, region: FSVolume.SeekRegion,
              context: FSContext) async throws -> FSSeekRegionResult {
        try await withIO { [self] in
            guard let h = handle, let it = item as? ntfs3gItem else { throw posixError(EINVAL) }
            guard region == .data || region == .hole else { throw posixError(EINVAL) }
            var result: Int64 = 0
            let rc = nfsk_seek_region(h, it.ino, Int64(offset), region == .data, &result)
            if rc != 0 { throw posixError(-rc) }
            return FSSeekRegionResult(returnedOffset: off_t(result))
        }
    }
}

// MARK: - Directory enumeration trampoline

@available(macOS 15.4, *)
final class EnumContext {
    unowned let volume: ntfs3gVolume
    let packer: FSDirectoryEntryPacker
    let parentIno: UInt64

    init(volume: ntfs3gVolume, packer: FSDirectoryEntryPacker, parentIno: UInt64) {
        self.volume = volume
        self.packer = packer
        self.parentIno = parentIno
    }

    func packRaw(name: String, ino: UInt64, type: UInt32, nextCookie: UInt64) -> Bool {
        let itemType = FSItem.ItemType(rawValue: Int(type)) ?? .directory
        let ok = packer.packEntry(name: FSFileName(string: name), itemType: itemType,
                                  itemID: FSItem.Identifier(rawValue: ino) ?? .invalid,
                                  nextCookie: FSDirectoryCookie(rawValue: nextCookie), attributes: nil)
        return ok
    }

    func pack(name: String, ino: UInt64, type: UInt32, bridgeCookie: Int64, attributes: FSItem.Attributes? = nil) -> Bool {
        let itemType = FSItem.ItemType(rawValue: Int(type)) ?? .file
        let next = UInt64(bridgeCookie) + 2
        let ok = packer.packEntry(name: FSFileName(string: name), itemType: itemType,
                                  itemID: FSItem.Identifier(rawValue: ino) ?? .invalid,
                                  nextCookie: FSDirectoryCookie(rawValue: next), attributes: attributes)
        return ok
    }
}

@available(macOS 15.4, *)
let enumTrampoline: @convention(c)
    (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UInt64, UInt32, Int64) -> Int32 = {
        ctxPtr, namePtr, ino, type, cookie in
        guard let ctxPtr = ctxPtr, let namePtr = namePtr else { return 1 }
        let ctx = Unmanaged<EnumContext>.fromOpaque(ctxPtr).takeUnretainedValue()
        let cont = ctx.pack(name: String(cString: namePtr), ino: ino, type: type, bridgeCookie: cookie)
        return cont ? 0 : 1
    }

@available(macOS 15.4, *)
let enumAttributesTrampoline: @convention(c)
    (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<nfsk_attr_t>?, Int64) -> Int32 = {
        ctxPtr, namePtr, attributesPtr, cookie in
        guard let ctxPtr, let namePtr, let attributesPtr else { return 1 }
        let ctx = Unmanaged<EnumContext>.fromOpaque(ctxPtr).takeUnretainedValue()
        let attributes = attributesPtr.pointee
        let result = ctx.volume.makeAttributes(attributes, parentIno: ctx.parentIno, preferContext: true)
        return ctx.pack(name: String(cString: namePtr), ino: attributes.ino, type: attributes.type,
                        bridgeCookie: cookie, attributes: result) ? 0 : 1
    }

// MARK: - Shared helpers

enum NTFSVolumeSupport {
    /// The volume's identity UUID: derived from the durable 64-bit NTFS boot-sector
    /// serial when present, else a synthesized label+size fallback. The serial is immutable,
    /// so identity survives relabels and stays distinct between independently-formatted
    /// same-label/same-size volumes. (A block-level clone copies the serial, so clones share
    /// identity.) Mirrors xlinuxfs's native-fs-UUID approach.
    static func volumeUUID(serial: UInt64, label: String, sizeBytes: UInt64) -> UUID {
        guard serial != 0 else { return stableUUID(label: label, sizeBytes: sizeBytes) }
        var u = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            let byte = UInt8(truncatingIfNeeded: serial >> (8 * UInt64(i)))
            u[i] = byte
            u[8 + i] = byte ^ 0x4E          // 'N' — deterministic high half
        }
        u[6] = (u[6] & 0x0F) | 0x40         // version-4 shape
        u[8] = (u[8] & 0x3F) | 0x80         // variant
        return UUID(uuid: (u[0],u[1],u[2],u[3],u[4],u[5],u[6],u[7],u[8],u[9],u[10],u[11],u[12],u[13],u[14],u[15]))
    }

    static func stableUUID(label: String, sizeBytes: UInt64) -> UUID {
        var bytes = Array("NTFS-3G:\(label):\(sizeBytes)".utf8)
        var u = [UInt8](repeating: 0, count: 16)
        for (i, b) in bytes.enumerated() { u[i % 16] = u[i % 16] &+ b &+ UInt8(i & 0xff) }
        bytes.removeAll()
        u[6] = (u[6] & 0x0F) | 0x40
        u[8] = (u[8] & 0x3F) | 0x80
        return UUID(uuid: (u[0],u[1],u[2],u[3],u[4],u[5],u[6],u[7],u[8],u[9],u[10],u[11],u[12],u[13],u[14],u[15]))
    }
}
