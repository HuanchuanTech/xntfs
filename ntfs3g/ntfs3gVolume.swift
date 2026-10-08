//
//  ntfs3gVolume.swift
//  An FSVolume backed by an NTFS filesystem through libntfs-3g.
//
//  libntfs-3g is not thread-safe, so every bridge call runs inside `withLock`
//  (a synchronous critical section — no `await` is held across the lock).
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
                          FSVolume.XattrOperations {

    private var handle: OpaquePointer?
    private var backend: NTFSBackend?
    private let activationBackend: ([String], Bool) throws -> NTFSBackend?
    private let onContainerStatusChange: (FSContainerStatus) -> Void
    private var tornDown = false
    private var readOnly: Bool
    private var activated = false
    private let lock = NSLock()
    private var items: [UInt64: ntfs3gItem] = [:]
    private let rootItem: ntfs3gItem

    /// `backend` comes from `nfsk_backend_from_block` / `nfsk_backend_from_file`.
    /// Ownership of `backend` transfers to this volume (freed in `teardown`).
    init(backend: NTFSBackend,
         activationBackend: @escaping ([String], Bool) throws -> NTFSBackend?,
         onContainerStatusChange: @escaping (FSContainerStatus) -> Void) throws {
        var err: Int32 = 0
        guard let h = nfsk_mount(backend.backend, !backend.writable, &err) else {
            backend.cleanup()
            nfsk_backend_free(backend.backend)
            throw posixError(err)
        }
        var st = nfsk_statfs_t()
        let statResult = nfsk_statfs(h, &st)
        guard statResult == 0 else {
            nfsk_umount(h)
            nfsk_backend_free(backend.backend)
            backend.cleanup()
            throw posixError(-statResult)
        }
        let label = withUnsafeBytes(of: st.volume_name) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        let volName = label.isEmpty ? "NTFS" : label
        let totalBytes = st.total_clusters &* UInt64(st.cluster_size)
        let root = ntfs3gItem(ino: NFSK_ROOT_INO,
                              parentIno: FSItem.Identifier.parentOfRoot.rawValue,
                              name: FSFileName(string: volName))

        self.handle = h
        self.backend = backend
        self.readOnly = st.read_only != 0
        self.activationBackend = activationBackend
        self.onContainerStatusChange = onContainerStatusChange
        self.rootItem = root

        let vid = FSVolume.Identifier(uuid: NTFSVolumeSupport.volumeUUID(serial: st.volume_serial, label: volName, sizeBytes: totalBytes))
        super.init(volumeID: vid, volumeName: FSFileName(string: volName))
        self.items[NFSK_ROOT_INO] = root
    }

    func teardown() {
        withLock {
            if tornDown { return }
            tornDown = true
            if let h = handle { nfsk_umount(h); handle = nil }
            if let b = backend { nfsk_backend_free(b.backend); b.cleanup(); backend = nil }
            items.removeAll()
        }
    }

    // MARK: lock helper (synchronous critical section)
    @discardableResult
    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
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
        attrs.flags = 0
        attrs.modifyTime = timespec(tv_sec: Int(a.mtime_sec), tv_nsec: Int(a.mtime_nsec))
        attrs.accessTime = timespec(tv_sec: Int(a.atime_sec), tv_nsec: Int(a.atime_nsec))
        attrs.changeTime = timespec(tv_sec: Int(a.ctime_sec), tv_nsec: Int(a.ctime_nsec))
        attrs.birthTime  = timespec(tv_sec: Int(a.btime_sec), tv_nsec: Int(a.btime_nsec))
        return attrs
    }

    fileprivate func attributes(ino: UInt64, parentIno: UInt64) -> FSItem.Attributes? {
        withLock {
            guard let h = handle else { return nil }
            var a = nfsk_attr_t()
            if nfsk_getattr(h, ino, &a) != 0 { return nil }
            return makeAttributes(a, parentIno: parentIno)
        }
    }

    // MARK: properties
    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let caps = FSVolume.SupportedCapabilities()
        caps.supportsHardLinks = true           // via ntfs_link (writable mounts)
        // Read-only symlinks: getattr/enumerate report resolvable reparse points as symlinks
        // and readSymbolicLink resolves them (FSKit drives readlink off the item type, not
        // this flag — see FSVolume.h). We do NOT advertise the capability, because creation is
        // unsupported; leaving it true would let the OS/Finder offer `ln -s` and then fail.
        caps.supportsSymbolicLinks = false
        caps.supportsPersistentObjectIDs = true
        caps.supports64BitObjectIDs = true
        caps.supports2TBFiles = true
        caps.supportsSparseFiles = true
        caps.supportsHiddenFiles = false        // getattr never reports UF_HIDDEN and setAttributes ignores .flags
        caps.caseFormat = .insensitiveCasePreserving
        return caps
    }

    var volumeStatistics: FSStatFSResult {
        // Must match the extension's FSShortName (ntfs3g/Info.plist) so the mounted
        // volume's statfs f_fstypename reads "xntfs" — that is how the app tells our
        // mounts apart from the legacy system NTFS driver.
        let stats = FSStatFSResult(fileSystemTypeName: "xntfs")
        return withLock {
            guard let h = handle else { return stats }
            var st = nfsk_statfs_t()
            guard nfsk_statfs(h, &st) == 0 else { return stats }
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
    }

    // FSKit retains unlinked/overwritten open files until their last reference closes.
    @available(macOS 26.0, *)
    var enableOpenUnlinkEmulation: Bool { true }

    @available(macOS 26.4, *)
    var requestedMountOptions: FSVolume.MountOptions {
        get { withLock { readOnly ? [.readOnly] : [] } }
        set { }
    }

    // MARK: lifecycle
    func activate(options: FSTaskOptions) async throws -> FSItem {
        try withLock {
            guard !tornDown, handle != nil else { throw posixError(ENXIO) }
            guard !activated else { throw posixError(EBUSY) }
            // Disk Arbitration supplies ro/rw here, after loadResource. Reopen before
            // exposing any items; loading metadata itself must never require writes.
            if let replacement = try activationBackend(options.taskOptions, readOnly) {
                if let h = handle { nfsk_umount(h); handle = nil }
                if let b = backend { nfsk_backend_free(b.backend); b.cleanup() }
                backend = replacement
                readOnly = !replacement.writable
                var err: Int32 = 0
                guard let h = nfsk_mount(replacement.backend, readOnly, &err) else { throw posixError(err) }
                handle = h
                var st = nfsk_statfs_t()
                let rc = nfsk_statfs(h, &st)
                guard rc == 0 else { throw posixError(-rc) }
                readOnly = st.read_only != 0
            }
            activated = true
        }
        onContainerStatusChange(.active)
        return rootItem
    }

    func deactivate(options: FSDeactivateOptions = []) async throws {
        withLock { activated = false }
        onContainerStatusChange(.ready)
    }

    func mount(options: FSTaskOptions) async throws {
        try withLock {
            // Older FSKit cannot request MNT_RDONLY after a writable activation.
            // Require an explicit read-only retry instead of exposing a writable mount.
            if #unavailable(macOS 26.4), readOnly && backend?.writable == true {
                throw posixError(EROFS)
            }
        }
    }
    func unmount() async {
        withLock {
            guard let h = handle else { return }
            let rc = nfsk_sync(h)
            if rc != 0 { NSLog("[xntfs] flush on unmount failed: errno \(-rc)") }
        }
    }

    func synchronize(flags: FSSyncFlags) async throws {
        try withLock {
            guard let h = handle else { return }
            let rc = nfsk_sync(h)
            if rc != 0 { throw posixError(-rc) }
        }
    }

    // MARK: attributes
    func attributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem) async throws -> FSItem.Attributes {
        try withLock {
            guard let it = item as? ntfs3gItem, let h = handle else { throw posixError(EINVAL) }
            var a = nfsk_attr_t()
            let rc = nfsk_getattr(h, it.ino, &a)
            if rc != 0 { throw posixError(-rc) }
            return makeAttributes(a, parentIno: it.parentIno)
        }
    }

    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem) async throws -> FSItem.Attributes {
        try withLock {
            guard let it = item as? ntfs3gItem, let h = handle else { throw posixError(EINVAL) }
            var consumed: FSItem.Attribute = []
            if newAttributes.isValid(.size) {
                let rc = nfsk_truncate(h, it.ino, newAttributes.size)
                if rc != 0 { throw posixError(-rc) }
                consumed.insert(.size)
            }
            let wantM = newAttributes.isValid(.modifyTime)
            let wantA = newAttributes.isValid(.accessTime)
            if wantM || wantA {
                let m = newAttributes.modifyTime
                let a = newAttributes.accessTime
                let rc = nfsk_set_times(h, it.ino,
                                        wantM ? Int64(m.tv_sec) : Int64.min, Int64(m.tv_nsec),
                                        wantA ? Int64(a.tv_sec) : Int64.min, Int64(a.tv_nsec))
                if rc != 0 { throw posixError(-rc) }
                if wantM { consumed.insert(.modifyTime) }
                if wantA { consumed.insert(.accessTime) }
            }
            // Report which attributes we actually applied: FSKit calls wasAttributeConsumed()
            // on the request and treats anything not in consumedAttributes as not-honored.
            newAttributes.consumedAttributes = consumed
            var a = nfsk_attr_t()
            let rc = nfsk_getattr(h, it.ino, &a)
            if rc != 0 { throw posixError(-rc) }
            return makeAttributes(a, parentIno: it.parentIno)
        }
    }

    // MARK: lookup / reclaim
    private func resolvedName(_ name: String, in directory: UInt64, handle: OpaquePointer) throws -> (UInt64, FSFileName) {
        var error: Int32 = 0
        var canonical = [CChar](repeating: 0, count: 1024)
        let ino = name.withCString { requested in
            canonical.withUnsafeMutableBufferPointer { buffer in
                nfsk_lookup_name(handle, directory, requested, buffer.baseAddress, buffer.count, &error)
            }
        }
        guard ino != 0 else { throw posixError(error == 0 ? ENOENT : error) }
        return (ino, FSFileName(string: String(cString: canonical)))
    }

    func lookupItem(named name: FSFileName, inDirectory directory: FSItem) async throws -> (FSItem, FSFileName) {
        try withLock {
            guard let dir = directory as? ntfs3gItem, let h = handle, let nameStr = name.string else { throw posixError(EINVAL) }
            let (ino, fsName) = try resolvedName(nameStr, in: dir.ino, handle: h)
            return (item(for: ino, parentIno: dir.ino, name: fsName), fsName)
        }
    }

    func reclaimItem(_ item: FSItem) async throws {
        withLock {
            guard let it = item as? ntfs3gItem else { return }
            guard it.ino != NFSK_ROOT_INO else { return }
            let removeCachedItem = {
                if self.items[it.ino] === it { self.items.removeValue(forKey: it.ino) }
            }
            if #available(macOS 27.0, *) {
                _ = it.tryReclaim(removeCachedItem)
            } else {
                removeCachedItem()
            }
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
        try withLock {
            guard let it = item as? ntfs3gItem, let h = handle else { throw posixError(EINVAL) }
            var buf = [CChar](repeating: 0, count: 4096)
            let rc = buf.withUnsafeMutableBufferPointer { nfsk_readlink(h, it.ino, $0.baseAddress, $0.count) }
            if rc != 0 { throw posixError(-rc) }
            return FSFileName(string: String(cString: buf))
        }
    }

    // MARK: create / remove / rename
    func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem,
                    attributes newAttributes: FSItem.SetAttributesRequest) async throws -> (FSItem, FSFileName) {
        try withLock {
            guard let dir = directory as? ntfs3gItem, let h = handle, let nameStr = name.string else { throw posixError(EINVAL) }
            let kind = UInt32(type == .directory ? NFSK_TYPE_DIR : NFSK_TYPE_FILE)
            var err: Int32 = 0
            let ino = nameStr.withCString { nfsk_create(h, dir.ino, $0, kind, &err) }
            if ino == 0 { throw posixError(err) }
            let fsName = FSFileName(string: nameStr)
            return (item(for: ino, parentIno: dir.ino, name: fsName), fsName)
        }
    }

    func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem,
                            attributes newAttributes: FSItem.SetAttributesRequest,
                            linkContents contents: FSFileName) async throws -> (FSItem, FSFileName) {
        throw posixError(ENOTSUP)
    }

    func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem) async throws -> FSFileName {
        try withLock {
            guard let target = item as? ntfs3gItem, let dir = directory as? ntfs3gItem,
                  let h = handle, let nameStr = name.string else { throw posixError(EINVAL) }
            var err: Int32 = 0
            let rc = nameStr.withCString { nfsk_link(h, target.ino, dir.ino, $0, &err) }
            if rc != 0 { throw posixError(err) }
            return FSFileName(string: nameStr)
        }
    }

    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem) async throws {
        try withLock {
            guard let dir = directory as? ntfs3gItem, let h = handle, let nameStr = name.string else { throw posixError(EINVAL) }
            let rc = nameStr.withCString { nfsk_remove(h, dir.ino, $0) }
            if rc != 0 { throw posixError(-rc) }
            evictDeletedItem(item, handle: h)
        }
    }

    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName,
                    to destinationName: FSFileName, inDirectory destinationDirectory: FSItem,
                    overItem: FSItem?) async throws -> FSFileName {
        try withLock {
            guard let sdir = sourceDirectory as? ntfs3gItem, let ddir = destinationDirectory as? ntfs3gItem,
                  let h = handle, let src = sourceName.string, let dst = destinationName.string else { throw posixError(EINVAL) }
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
        try withLock {
            guard let dir = directory as? ntfs3gItem, let h = handle else { throw posixError(EINVAL) }
            let wantDots = (attributes == nil)
            let c = cookie.rawValue
            let ctx = EnumContext(volume: self, packer: packer, parentIno: dir.ino, wantAttributes: attributes != nil)

            if wantDots {
                if c < 1 {
                    if !ctx.packRaw(name: ".", ino: dir.ino, type: UInt32(NFSK_TYPE_DIR), nextCookie: 1) {
                        return FSDirectoryVerifier(rawValue: 1)
                    }
                }
                if c < 2 {
                    if !ctx.packRaw(name: "..", ino: dir.ino, type: UInt32(NFSK_TYPE_DIR), nextCookie: 2) {
                        return FSDirectoryVerifier(rawValue: 1)
                    }
                }
            }
            let realSkip: Int64 = c <= 2 ? 0 : Int64(c - 2)
            let ctxPtr = Unmanaged.passUnretained(ctx).toOpaque()
            let rc = nfsk_readdir(h, dir.ino, realSkip, ctxPtr, enumTrampoline)
            if rc != 0 && !ctx.stopped { throw posixError(-rc) }
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
        try withLock {
            guard let it = item as? ntfs3gItem, let h = handle,
                  let key = name.string, !key.utf8.contains(0) else { throw posixError(EINVAL) }
            return try key.withCString { key in
                let size = nfsk_getxattr(h, it.ino, key, nil, 0)
                if size < 0 { throw posixError(Int32(-size)) }
                var data = Data(count: Int(size))
                let read = data.withUnsafeMutableBytes { nfsk_getxattr(h, it.ino, key, $0.baseAddress, $0.count) }
                if read < 0 { throw posixError(Int32(-read)) }
                guard read == size else { throw posixError(EIO) }
                return data
            }
        }
    }

    func setXattr(named name: FSFileName, to value: Data?, on item: FSItem,
                  policy: FSVolume.SetXattrPolicy) async throws {
        try withLock {
            guard let it = item as? ntfs3gItem, let h = handle,
                  let key = name.string, !key.utf8.contains(0) else { throw posixError(EINVAL) }
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
        try withLock {
            guard let it = item as? ntfs3gItem, let h = handle else { throw posixError(EINVAL) }
            let size = nfsk_listxattr(h, it.ino, nil, 0)
            if size < 0 { throw posixError(Int32(-size)) }
            if size == 0 { return [] }
            var bytes = [CChar](repeating: 0, count: Int(size))
            let read = bytes.withUnsafeMutableBufferPointer { nfsk_listxattr(h, it.ino, $0.baseAddress, $0.count) }
            if read < 0 { throw posixError(Int32(-read)) }
            guard read == size else { throw posixError(EIO) }
            return try bytes.split(separator: 0).map { name in
                guard let string = String(bytes: name.map { UInt8(bitPattern: $0) }, encoding: .utf8) else {
                    throw posixError(EIO)
                }
                return FSFileName(string: string)
            }
        }
    }

    // MARK: ReadWrite
    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer) async throws -> Int {
        try withLock {
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
        try withLock {
            guard let it = item as? ntfs3gItem, let h = handle else { throw posixError(EINVAL) }
            var err: Int32 = 0
            let n = contents.withUnsafeBytes { raw in
                nfsk_write(h, it.ino, Int64(offset), raw.baseAddress, Int64(raw.count), &err)
            }
            if n < 0 { throw posixError(err) }
            return Int(n)
        }
    }

    // MARK: OpenClose (no-ops)
    func openItem(_ item: FSItem, modes: FSVolume.OpenModes) async throws {}
    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes) async throws {}
}

// MARK: - Directory enumeration trampoline

@available(macOS 15.4, *)
final class EnumContext {
    unowned let volume: ntfs3gVolume
    let packer: FSDirectoryEntryPacker
    let parentIno: UInt64
    let wantAttributes: Bool
    var stopped = false

    init(volume: ntfs3gVolume, packer: FSDirectoryEntryPacker, parentIno: UInt64, wantAttributes: Bool) {
        self.volume = volume
        self.packer = packer
        self.parentIno = parentIno
        self.wantAttributes = wantAttributes
    }

    func packRaw(name: String, ino: UInt64, type: UInt32, nextCookie: UInt64) -> Bool {
        let itemType = FSItem.ItemType(rawValue: Int(type)) ?? .directory
        let ok = packer.packEntry(name: FSFileName(string: name), itemType: itemType,
                                  itemID: FSItem.Identifier(rawValue: ino) ?? .invalid,
                                  nextCookie: FSDirectoryCookie(rawValue: nextCookie), attributes: nil)
        if !ok { stopped = true }
        return ok
    }

    func pack(name: String, ino: UInt64, type: UInt32, bridgeCookie: Int64) -> Bool {
        let itemType = FSItem.ItemType(rawValue: Int(type)) ?? .file
        var attrs: FSItem.Attributes? = nil
        if wantAttributes {
            attrs = volume.enumAttributesRaw(ino: ino, parentIno: parentIno)
        }
        let next = UInt64(bridgeCookie) + 2
        let ok = packer.packEntry(name: FSFileName(string: name), itemType: itemType,
                                  itemID: FSItem.Identifier(rawValue: ino) ?? .invalid,
                                  nextCookie: FSDirectoryCookie(rawValue: next), attributes: attrs)
        if !ok { stopped = true }
        return ok
    }
}

@available(macOS 15.4, *)
extension ntfs3gVolume {
    // Called from the readdir trampoline while the lock is already held, so it
    // must NOT re-take the lock; access the bridge directly.
    fileprivate func enumAttributesRaw(ino: UInt64, parentIno: UInt64) -> FSItem.Attributes? {
        guard let h = handle else { return nil }
        var a = nfsk_attr_t()
        if nfsk_getattr(h, ino, &a) != 0 { return nil }
        return makeAttributes(a, parentIno: parentIno, preferContext: true)
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
