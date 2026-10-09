import Foundation
import FSKit

@main
struct VolumeRegressionTests {
    static func expect(_ code: Int32, _ operation: () async throws -> Void) async throws {
        do { try await operation(); preconditionFailure("Expected errno \(code)") }
        catch { precondition((error as NSError).code == Int(code), "Unexpected error: \(error)") }
    }

    static func featureTests(_ image: URL) async throws {
        let volume = try ntfs3gVolume(backend: backend(image, writable: true),
            activationBackend: { _, _ in nil }, onContainerStatusChange: { _ in }, legacyOpenUnlink: true)
        let root = ntfs3gItem(ino: NFSK_ROOT_INO, parentIno: NFSK_PARENT_OF_ROOT, name: FSFileName(string: "/"))
        let create = FSItem.SetAttributesRequest()
        create.size = 123
        create.mode = 0o600
        create.birthTime = timespec(tv_sec: 946684800, tv_nsec: 123456700)
        create.modifyTime = timespec(tv_sec: 946684801, tv_nsec: 0)
        create.flags = UInt32(UF_HIDDEN)
        let (item, _) = try await volume.createItem(named: FSFileName(string: "SwiftAttributes"), type: .file,
                                                   inDirectory: root, attributes: create)
        let get = FSItem.GetAttributesRequest()
        get.wantedAttributes = [.size, .allocSize, .birthTime, .modifyTime, .flags, .linkCount]
        var attrs = try await volume.attributes(get, of: item)
        precondition(attrs.size == 123 && attrs.birthTime.tv_sec == 946684800 && attrs.birthTime.tv_nsec == 123456700)
        precondition(attrs.modifyTime.tv_sec == 946684801 && attrs.flags == UInt32(UF_HIDDEN))
        for attribute: FSItem.Attribute in [.size, .birthTime, .modifyTime, .flags] {
            precondition(create.wasAttributeConsumed(attribute))
        }
        precondition(!create.wasAttributeConsumed(.mode))
        let update = FSItem.SetAttributesRequest()
        update.size = 456
        update.birthTime = timespec(tv_sec: 946684802, tv_nsec: 0)
        update.flags = 0
        attrs = try await volume.setAttributes(update, on: item)
        precondition(attrs.size == 456 && attrs.birthTime.tv_sec == 946684802 && attrs.flags == 0)
        for attribute: FSItem.Attribute in [.size, .birthTime, .flags] { precondition(update.wasAttributeConsumed(attribute)) }
        let unsupported = FSItem.SetAttributesRequest()
        unsupported.size = 1
        unsupported.backupTime = timespec(tv_sec: 946684803, tv_nsec: 0)
        try await expect(ENOTSUP) { _ = try await volume.setAttributes(unsupported, on: item) }
        attrs = try await volume.attributes(get, of: item)
        precondition(attrs.size == 456 && !attrs.isValid(.backupTime))
        let flags = FSItem.SetAttributesRequest()
        flags.flags = UInt32(UF_IMMUTABLE)
        try await expect(ENOTSUP) { _ = try await volume.setAttributes(flags, on: item) }
        let mode = FSItem.SetAttributesRequest()
        mode.mode = 0o700
        mode.modifyTime = timespec(tv_sec: 946684805, tv_nsec: 0)
        attrs = try await volume.setAttributes(mode, on: item)
        precondition(attrs.mode == 0o666 && !mode.wasAttributeConsumed(.mode) && mode.wasAttributeConsumed(.modifyTime))
        try await expect(ENOTSUP) {
            _ = try await volume.createItem(named: FSFileName(string: "UnsupportedCreate"), type: .file,
                                            inDirectory: root, attributes: flags)
        }
        try await expect(ENOENT) { _ = try await volume.lookupItem(named: FSFileName(string: "UnsupportedCreate"), inDirectory: root) }
        try await expect(ENOTSUP) {
            _ = try await volume.createItem(named: FSFileName(string: "UnsupportedFIFO"), type: .fifo,
                                            inDirectory: root, attributes: FSItem.SetAttributesRequest())
        }
        print("PASS: creation attributes, consumed fields, native times/hidden flags, unsupported metadata rejection")

        let linkAttrs = FSItem.SetAttributesRequest()
        linkAttrs.birthTime = timespec(tv_sec: 946684804, tv_nsec: 0)
        let (link, _) = try await volume.createSymbolicLink(named: FSFileName(string: "SwiftLink"), inDirectory: root,
            attributes: linkAttrs, linkContents: FSFileName(string: "/some/target"))
        let contents = try await volume.readSymbolicLink(link)
        precondition(contents.string == "/some/target" && linkAttrs.wasAttributeConsumed(.birthTime))
        precondition(volume.supportedVolumeCapabilities.supportsSymbolicLinks && volume.supportedVolumeCapabilities.supportsHiddenFiles)
        let identity = volume.volumeID
        let renamed = try await volume.setVolumeName(FSFileName(string: "Swift Rename"))
        precondition(renamed.string == "Swift Rename" && volume.name.string == "Swift Rename" && volume.volumeID == identity)
        let allocated = try await volume.preallocateSpace(for: item, at: 123, length: 65536, flags: [.all, .persist, .fromEOF])
        attrs = try await volume.attributes(get, of: item)
        precondition(allocated >= 65536 && attrs.size == 456 && attrs.allocSize >= 65536)
        try await expect(ENOTSUP) { _ = try await volume.preallocateSpace(for: item, at: 0, length: 1, flags: [.contiguous]) }
        var protocols = ["FSVolumeRenameOperations", "FSVolumePreallocateOperations"]
        if #available(macOS 27.0, *) { protocols.append("FSVolumeSeekRegionHandler") }
        for name in protocols {
            precondition(volume.conforms(to: NSProtocolFromString(name)!))
        }
        print("PASS: Swift symlink creation, volume rename and preallocation")
        if #available(macOS 27.0, *) { print("PASS: macOS 27 seek conformance") }
        else { print("SKIP: seek conformance requires macOS 27") }

        try await volume.openItem(item, modes: [.read])
        try await volume.openItem(item, modes: [.read, .write])
        try await volume.removeItem(item, named: FSFileName(string: "SwiftAttributes"), fromDirectory: root)
        attrs = try await volume.attributes(get, of: item)
        precondition(attrs.linkCount == 0)
        try await volume.closeItem(item, modes: [.read])
        attrs = try await volume.attributes(get, of: item)
        precondition(attrs.size == 456)
        let written = try await volume.write(contents: Data("alive".utf8), to: item, at: 0)
        precondition(written == 5)
        try await volume.closeItem(item, modes: [])
        try await expect(ENOENT) { _ = try await volume.attributes(get, of: item) }
        let (reused, _) = try await volume.createItem(named: FSFileName(string: "ReusedRecord"), type: .file,
            inDirectory: root, attributes: FSItem.SetAttributesRequest())
        let reusedIno = (reused as! ntfs3gItem).ino
        let stale = ntfs3gItem(ino: reusedIno, parentIno: NFSK_ROOT_INO, name: FSFileName(string: "PreviousObject"))
        precondition(reused !== item)
        try await volume.openItem(reused, modes: [.read, .write])
        try await volume.closeItem(stale, modes: [])
        try await volume.reclaimItem(stale)
        try await volume.removeItem(reused, named: FSFileName(string: "ReusedRecord"), fromDirectory: root)
        attrs = try await volume.attributes(get, of: reused)
        precondition(attrs.linkCount == 0)
        try await volume.closeItem(reused, modes: [])
        try await expect(ENOENT) { _ = try await volume.attributes(get, of: reused) }
        print("PASS: legacy lifecycle uses retained modes and releases only on final close")
        try await expect(EBUSY) { try volume.quickCheck() }
        volume.teardown()

        let readOnly = try ntfs3gVolume(backend: backend(image, writable: false),
            activationBackend: { _, _ in nil }, onContainerStatusChange: { _ in })
        defer { readOnly.teardown() }
        try readOnly.quickCheck()
        try await expect(EROFS) { try await readOnly.openItem(root, modes: [.write]) }
        try await expect(EROFS) { _ = try await readOnly.setVolumeName(FSFileName(string: "No")) }
        let modes = try [["-q"], ["-qn"], ["-y"], ["-n"], []].map { try ntfs3gFileSystem.CheckMode(options: $0) }
        precondition(modes == [.quick, .quick, .repair, .verify, .verify])
        try await expect(EINVAL) { _ = try ntfs3gFileSystem.CheckMode(options: ["-qy"]) }
        try await expect(EINVAL) { _ = try ntfs3gFileSystem.CheckMode(options: ["-p"]) }
        print("PASS: read-only quick check, writable-volume guard, and maintenance mode parsing")
    }

    static func backend(_ image: URL, writable: Bool) throws -> NTFSBackend {
        var error: Int32 = 0
        guard let pointer = nfsk_backend_from_file(image.path, writable ? 1 : 0, &error) else {
            throw posixError(error)
        }
        return NTFSBackend(backend: pointer, retain: nil, cleanup: {}, writable: writable)
    }

    static func main() async throws {
        print("Runtime: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        let image = URL(fileURLWithPath: CommandLine.arguments[1])
        let normal = try ntfs3gVolume(backend: backend(image, writable: true),
                                     activationBackend: { _, _ in nil }, onContainerStatusChange: { _ in })
        let stats = normal.volumeStatistics
        precondition(stats.availableBlocks > stats.totalBlocks / 2)
        if #available(macOS 26.4, *) {
            precondition(!normal.requestedMountOptions.contains(.readOnly))
        }
        if #available(macOS 26.0, *) {
            precondition(normal.enableOpenUnlinkEmulation)
            precondition(!ntfs3gVolume.needsLegacyOpenUnlink)
        } else {
            precondition(ntfs3gVolume.needsLegacyOpenUnlink)
        }
        precondition(normal.supportedVolumeCapabilities.caseFormat == .insensitiveCasePreserving)
        precondition(normal.maximumFileSize == UInt64(Int64.max) && normal.maximumFileSizeInBits == 64)
        precondition(normal.maximumXattrSize == Int(NFSK_MAX_XATTR_SIZE))
        let root = ntfs3gItem(ino: NFSK_ROOT_INO, parentIno: NFSK_PARENT_OF_ROOT, name: FSFileName(string: "/"))
        let xattrName = FSFileName(string: "com.apple.metadata:_kMDItemUserTags")
        let value = Data("test tags".utf8)
        try await normal.setXattr(named: xattrName, to: value, on: root, policy: .mustCreate)
        let readback = try await normal.xattr(named: xattrName, of: root)
        let names = try await normal.xattrs(of: root)
        precondition(readback == value && names.contains(where: { $0.string == xattrName.string }))
        do {
            try await normal.setXattr(named: xattrName, to: Data(), on: root, policy: .mustCreate)
            preconditionFailure("mustCreate accepted a duplicate")
        } catch { precondition((error as NSError).code == Int(EEXIST)) }
        try await normal.setXattr(named: xattrName, to: Data(), on: root, policy: .mustReplace)
        let empty = try await normal.xattr(named: xattrName, of: root)
        precondition(empty.isEmpty)
        try await normal.setXattr(named: xattrName, to: nil, on: root, policy: .delete)
        do {
            _ = try await normal.xattr(named: xattrName, of: root)
            preconditionFailure("deleted xattr still exists")
        } catch { precondition((error as NSError).code == Int(ENOATTR)) }
        normal.teardown()
        print("PASS: FSKit free-space fields and OS-specific open-file lifetime selection")
        print("PASS: signed 64-bit size limits and native FSKit xattr create/read/list/replace/delete")

        try await featureTests(image)

        let prepared = try backend(image, writable: true)
        var error: Int32 = 0
        guard let handle = nfsk_mount(prepared.backend, false, &error) else { throw posixError(error) }
        let mixed = nfsk_create(handle, NFSK_ROOT_INO, "VolumeMiXeD.txt", UInt32(NFSK_TYPE_FILE), &error)
        let fixture = nfsk_create(handle, NFSK_ROOT_INO, "hiberfil.sys", UInt32(NFSK_TYPE_FILE), &error)
        precondition(mixed != 0 && fixture != 0)
        var bytes = [UInt8](repeating: 0, count: 4096)
        bytes.replaceSubrange(0..<4, with: "hibr".utf8)
        let count = bytes.withUnsafeBytes { nfsk_write(handle, fixture, 0, $0.baseAddress, Int64($0.count), &error) }
        precondition(count == 4096)
        nfsk_umount(handle)
        nfsk_backend_free(prepared.backend)

        let fallback = try ntfs3gVolume(backend: backend(image, writable: true),
                                       activationBackend: { _, _ in nil }, onContainerStatusChange: { _ in })
        defer { fallback.teardown() }
        if #available(macOS 26.4, *) {
            precondition(fallback.requestedMountOptions.contains(.readOnly))
        } else {
            try await expect(EROFS) {
                _ = try await fallback.createItem(named: FSFileName(string: "MustNotCreate"), type: .file,
                    inDirectory: root, attributes: FSItem.SetAttributesRequest())
            }
            print("SKIP: mount callback requires system-provided FSTaskOptions; tested fallback write rejection")
        }
        let (item, name) = try await fallback.lookupItem(named: FSFileName(string: "volumemixed.txt"), inDirectory: root)
        precondition((item as? ntfs3gItem)?.ino == mixed && name.string == "VolumeMiXeD.txt")
        print("PASS: OS-specific read-only fallback guard and canonical lookup")
    }
}
