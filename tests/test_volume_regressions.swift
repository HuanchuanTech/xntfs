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
        let rootGet = FSItem.GetAttributesRequest()
        rootGet.wantedAttributes = [.flags, .modifyTime, .changeTime]
        let rootBefore = try await volume.attributes(rootGet, of: root)
        precondition(rootBefore.flags == 0)
        let rootClear = FSItem.SetAttributesRequest()
        rootClear.flags = 0
        var rootAttrs = try await volume.setAttributes(rootClear, on: root)
        precondition(rootAttrs.flags == 0 && rootClear.wasAttributeConsumed(.flags))
        precondition(rootAttrs.changeTime.tv_sec == rootBefore.changeTime.tv_sec &&
                     rootAttrs.changeTime.tv_nsec == rootBefore.changeTime.tv_nsec)
        let rootUpdate = FSItem.SetAttributesRequest()
        rootUpdate.flags = 0
        rootUpdate.modifyTime = timespec(tv_sec: 946684790, tv_nsec: 123456700)
        rootAttrs = try await volume.setAttributes(rootUpdate, on: root)
        precondition(rootAttrs.flags == 0 && rootAttrs.modifyTime.tv_sec == 946684790 &&
                     rootAttrs.modifyTime.tv_nsec == 123456700)
        precondition(rootUpdate.wasAttributeConsumed(.flags) && rootUpdate.wasAttributeConsumed(.modifyTime))
        let rootHide = FSItem.SetAttributesRequest()
        rootHide.flags = UInt32(UF_HIDDEN)
        rootHide.modifyTime = timespec(tv_sec: 946684791, tv_nsec: 0)
        try await expect(ENOTSUP) { _ = try await volume.setAttributes(rootHide, on: root) }
        rootAttrs = try await volume.attributes(rootGet, of: root)
        precondition(rootAttrs.flags == 0 && rootAttrs.modifyTime.tv_sec == 946684790 &&
                     rootAttrs.modifyTime.tv_nsec == 123456700)
        precondition(!rootHide.wasAttributeConsumed(.flags) && !rootHide.wasAttributeConsumed(.modifyTime))
        print("PASS: visible volume root, nohidden no-op, combined metadata and root hiding rejection")

        let create = FSItem.SetAttributesRequest()
        create.size = 123
        create.mode = 0o600
        create.birthTime = timespec(tv_sec: 946684800, tv_nsec: 123456700)
        create.modifyTime = timespec(tv_sec: 946684801, tv_nsec: 0)
        create.flags = UInt32(UF_HIDDEN)
        let (item, _) = try await (volume as any FSVolume.Operations).createItem(named: FSFileName(string: "SwiftAttributes"), type: .file,
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
        unsupported.flags = UInt32(UF_IMMUTABLE)
        try await expect(ENOTSUP) { _ = try await volume.setAttributes(unsupported, on: item) }
        attrs = try await volume.attributes(get, of: item)
        precondition(attrs.size == 456 && attrs.flags == 0)
        let flags = FSItem.SetAttributesRequest()
        flags.flags = UInt32(UF_IMMUTABLE)
        try await expect(ENOTSUP) { _ = try await volume.setAttributes(flags, on: item) }
        let mode = FSItem.SetAttributesRequest()
        mode.mode = 0o700
        mode.modifyTime = timespec(tv_sec: 946684805, tv_nsec: 0)
        attrs = try await volume.setAttributes(mode, on: item)
        precondition(attrs.mode == 0o666 && !mode.wasAttributeConsumed(.mode) && mode.wasAttributeConsumed(.modifyTime))
        try await expect(ENOTSUP) {
            _ = try await (volume as any FSVolume.Operations).createItem(named: FSFileName(string: "UnsupportedCreate"), type: .file,
                                            inDirectory: root, attributes: flags)
        }
        try await expect(ENOENT) { _ = try await (volume as any FSVolume.Operations).lookupItem(named: FSFileName(string: "UnsupportedCreate"), inDirectory: root) }
        try await expect(ENOTSUP) {
            _ = try await (volume as any FSVolume.Operations).createItem(named: FSFileName(string: "UnsupportedFIFO"), type: .fifo,
                                            inDirectory: root, attributes: FSItem.SetAttributesRequest())
        }
        print("PASS: creation attributes, consumed fields, native times/hidden flags, unsupported metadata rejection")

        let linkAttrs = FSItem.SetAttributesRequest()
        linkAttrs.birthTime = timespec(tv_sec: 946684804, tv_nsec: 0)
        let (link, _) = try await (volume as any FSVolume.Operations).createSymbolicLink(named: FSFileName(string: "SwiftLink"), inDirectory: root,
            attributes: linkAttrs, linkContents: FSFileName(string: "/some/target"))
        let contents = try await volume.readSymbolicLink(link)
        precondition(contents.string == "/some/target" && linkAttrs.wasAttributeConsumed(.birthTime))
        let targetCases = ["a", "../école/文件/😀", String(repeating: "x", count: 900),
                           String(repeating: "a", count: 1023), String(repeating: "각", count: 341)]
        var retainedTargets: [(String, FSFileName)] = []
        for (index, target) in targetCases.enumerated() {
            let (created, _) = try await (volume as any FSVolume.Operations).createSymbolicLink(
                named: FSFileName(string: "TargetOwnership-\(index)"), inDirectory: root,
                attributes: FSItem.SetAttributesRequest(), linkContents: FSFileName(string: target))
            let retained = try await volume.readSymbolicLink(created)
            let again = try await volume.readSymbolicLink(created)
            precondition(retained.string?.utf8.elementsEqual(target.decomposedStringWithCanonicalMapping.utf8) == true &&
                         again.string == retained.string)
            retainedTargets.append(("TargetOwnership-\(index)", retained))
        }
        precondition(volume.supportedVolumeCapabilities.supportsSymbolicLinks && volume.supportedVolumeCapabilities.supportsHiddenFiles)
        let identity = volume.volumeID
        let renamed = try await volume.setVolumeName(FSFileName(string: "Swift Rename"))
        precondition(renamed.string == "Swift Rename" && volume.name.string == "Swift Rename" && volume.volumeID == identity)
        let beforeAllocation = volume.volumeStatistics.freeBlocks
        let allocated = try await volume.preallocateSpace(for: item, at: 123, length: 65536, flags: [.all, .persist, .fromEOF])
        attrs = try await volume.attributes(get, of: item)
        precondition(allocated >= 65536 && attrs.size == 456 && attrs.allocSize >= 65536)
        precondition(volume.volumeStatistics.freeBlocks < beforeAllocation)
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
        let beforeClose = volume.volumeStatistics.freeBlocks
        try await volume.closeItem(item, modes: [])
        precondition(volume.volumeStatistics.freeBlocks > beforeClose)
        try await expect(ENOENT) { _ = try await volume.attributes(get, of: item) }
        let (reused, _) = try await (volume as any FSVolume.Operations).createItem(named: FSFileName(string: "ReusedRecord"), type: .file,
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
        print("PASS: legacy lifecycle uses retained modes and releases only on final close; space snapshots refresh")
        try await expect(EBUSY) { try await volume.quickCheck() }
        await volume.teardown()
        for (index, retained) in retainedTargets.enumerated() {
            precondition(retained.1.string!.utf8.elementsEqual(targetCases[index].decomposedStringWithCanonicalMapping.utf8))
        }

        let readOnly = try ntfs3gVolume(backend: backend(image, writable: false),
            activationBackend: { _, _ in nil }, onContainerStatusChange: { _ in })
        for (name, retained) in retainedTargets {
            let (reopened, _) = try await (readOnly as any FSVolume.Operations).lookupItem(
                named: FSFileName(string: name), inDirectory: root)
            let actual = try await readOnly.readSymbolicLink(reopened)
            precondition(actual.string!.utf8.elementsEqual(retained.string!.utf8))
        }
        precondition(retainedTargets.last!.1.string!.utf8.count == 3069)
        print("PASS: readlink targets own complete bytes across later reads, teardown and read-only reopen")
        try await readOnly.quickCheck()
        rootAttrs = try await readOnly.attributes(rootGet, of: root)
        precondition(rootAttrs.flags == 0)
        try await expect(EROFS) { _ = try await readOnly.setAttributes(rootClear, on: root) }
        try await expect(EROFS) { try await readOnly.openItem(root, modes: [.write]) }
        try await expect(EROFS) { _ = try await readOnly.setVolumeName(FSFileName(string: "No")) }
        let modes = try [["-q"], ["-qn"], ["-y"], ["-n"], []].map { try ntfs3gFileSystem.CheckMode(options: $0) }
        precondition(modes == [.quick, .quick, .repair, .verify, .verify])
        try await expect(EINVAL) { _ = try ntfs3gFileSystem.CheckMode(options: ["-qy"]) }
        try await expect(EINVAL) { _ = try ntfs3gFileSystem.CheckMode(options: ["-p"]) }
        await readOnly.teardown()
        print("PASS: read-only quick check, writable-volume guard, and maintenance mode parsing")
    }

    static func backend(_ image: URL, writable: Bool) throws -> NTFSBackend {
        var error: Int32 = 0
        guard let pointer = nfsk_backend_from_file(image.path, writable ? 1 : 0, &error) else {
            throw posixError(error)
        }
        return NTFSBackend(backend: pointer, retain: nil, cleanup: {}, writable: writable)
    }

    static func directoryTests(_ image: URL) async throws {
        let volume = try ntfs3gVolume(backend: backend(image, writable: true),
            activationBackend: { _, _ in nil }, onContainerStatusChange: { _ in })
        let root = ntfs3gItem(ino: NFSK_ROOT_INO, parentIno: NFSK_PARENT_OF_ROOT, name: FSFileName(string: "/"))
        let operations = volume as any FSVolume.Operations
        let (first, _) = try await operations.createItem(named: FSFileName(string: "ListingA"), type: .directory,
            inDirectory: root, attributes: FSItem.SetAttributesRequest())
        let (second, _) = try await operations.createItem(named: FSFileName(string: "ListingB"), type: .directory,
            inDirectory: root, attributes: FSItem.SetAttributesRequest())
        let (file, _) = try await operations.createItem(named: FSFileName(string: "File"), type: .file,
            inDirectory: first, attributes: FSItem.SetAttributesRequest())
        let written = try await volume.write(contents: Data(repeating: 0x39, count: 4097), to: file, at: 0)
        precondition(written == 4097)
        try await expect(EINVAL) { _ = try await volume.write(contents: Data([1]), to: file, at: -1) }
        try await expect(EINVAL) { _ = try await volume.write(contents: Data(), to: file, at: -1) }
        try await expect(EFBIG) { _ = try await volume.write(contents: Data([1]), to: file, at: Int64.max) }
        let zeroWrite = try await volume.write(contents: Data(), to: file, at: Int64.max)
        let sizeRequest = FSItem.GetAttributesRequest()
        sizeRequest.wantedAttributes = [.size]
        let sizeAfterRejectedWrites = try await volume.attributes(sizeRequest, of: file).size
        precondition(zeroWrite == 0 && sizeAfterRejectedWrites == 4097)
        print("PASS: FSKit write offset errors, zero-byte semantics and unchanged file size")
        _ = try await volume.createLink(to: file, named: FSFileName(string: "Hard"), inDirectory: second)
        let (link, _) = try await operations.createSymbolicLink(named: FSFileName(string: "Link"), inDirectory: first,
            attributes: FSItem.SetAttributesRequest(), linkContents: FSFileName(string: "File"))
        let (subdir, _) = try await operations.createItem(named: FSFileName(string: "Subdir"), type: .directory,
            inDirectory: first, attributes: FSItem.SetAttributesRequest())
        let request = FSItem.GetAttributesRequest()
        request.wantedAttributes = [.type, .fileID, .parentID, .size, .flags, .modifyTime]
        for attributes in [nil, request] as [FSItem.GetAttributesRequest?] {
            try await expect(EINVAL) {
                _ = try await volume.enumerateDirectory(first, startingAt: FSDirectoryCookie(rawValue: UInt64.max),
                    verifier: FSDirectoryVerifier(rawValue: 1), attributes: attributes,
                    packer: nfsk_test_packer { _, _, _, _, _ in preconditionFailure("Invalid cookie reached the packer") })
            }
        }
        let stableParent = try await volume.attributes(request, of: file).parentID
        for (directory, expected) in [(first, ["File": file, "Link": link, "Subdir": subdir]), (second, ["Hard": file])] {
            var rawNames: Set<String> = [], rawCookie = FSDirectoryCookie(rawValue: 0)
            while true {
                var accepted = false
                let packer = nfsk_test_packer { name, _, ino, next, attrs in
                    if accepted { return false }
                    let name = name.string!
                    precondition(attrs == nil && !rawNames.contains(name))
                    if name == "." { precondition(ino.rawValue == (directory as! ntfs3gItem).ino) }
                    if name == ".." { precondition(ino.rawValue == NFSK_ROOT_INO) }
                    rawNames.insert(name); rawCookie = next; accepted = true
                    return true
                }
                _ = try await volume.enumerateDirectory(directory, startingAt: rawCookie, verifier: FSDirectoryVerifier(rawValue: 1),
                    attributes: nil, packer: packer)
                if !accepted { break }
            }
            precondition(rawNames == Set(expected.keys).union([".", ".."]))
            for limit in [1, 7, 64] {
                var seen: [String: FSItem.Attributes] = [:]
                var cookie = FSDirectoryCookie(rawValue: 0)
                while true {
                    var accepted = 0
                    let packer = nfsk_test_packer { name, type, ino, next, attrs in
                        if accepted == limit { return false }
                        accepted += 1
                        let name = name.string!
                        precondition(seen[name] == nil && expected[name] != nil)
                        precondition(attrs != nil && attrs!.fileID == ino && attrs!.type == type)
                        precondition(ino.rawValue == (expected[name] as! ntfs3gItem).ino &&
                                     attrs!.parentID.rawValue == (directory as! ntfs3gItem).ino)
                        if name == "File" || name == "Hard" { precondition(attrs!.size == 4097 && attrs!.linkCount == 2) }
                        if name == "Link" { precondition(type == .symlink && attrs!.size == 4) }
                        cookie = next; seen[name] = attrs!
                        return true
                    }
                    _ = try await volume.enumerateDirectory(directory, startingAt: cookie, verifier: FSDirectoryVerifier(rawValue: 1),
                        attributes: request, packer: packer)
                    if accepted == 0 { break }
                }
                precondition(Set(seen.keys) == Set(expected.keys))
                // FSItem.Attributes must be independent of the C callback stack.
                for name in seen.keys { precondition(seen[name]!.fileID.rawValue == (expected[name] as! ntfs3gItem).ino) }
            }
        }
        let parentAfter = try await volume.attributes(request, of: file).parentID
        precondition(stableParent == parentAfter)
        await volume.teardown()
        print("PASS: Swift combined directory pages preserve metadata, symlink sizes, hard-link parents and borrowed-buffer lifetime")
    }

    static func canonicalNameTests(_ image: URL) async throws {
        let volume = try ntfs3gVolume(backend: backend(image, writable: true),
            activationBackend: { _, _ in nil }, onContainerStatusChange: { _ in })
        let root = ntfs3gItem(ino: NFSK_ROOT_INO, parentIno: NFSK_PARENT_OF_ROOT, name: FSFileName(string: "/"))
        let (directory, _) = try await (volume as any FSVolume.Operations).createItem(named: FSFileName(string: "CanonicalNames"),
            type: .directory, inDirectory: root, attributes: FSItem.SetAttributesRequest())
        let names = [String(repeating: "Z", count: 255), "LookupMiXeD.txt", "Café.txt",
                     String(repeating: "😀", count: 127) + "X", String(repeating: "각", count: 255),
                     ".hidden", "...", "a:b", "a\\b", "part／name", " ", "win:*?\"<>|chars"]
        var expected: [(name: String, item: FSItem, bytes: Data)] = []
        var retainedNames: [FSFileName] = []
        for (index, name) in names.enumerated() {
            let (item, _) = try await (volume as any FSVolume.Operations).createItem(named: FSFileName(string: name),
                type: .file, inDirectory: directory, attributes: FSItem.SetAttributesRequest())
            let payload = Data("canonical-payload-\(index)".utf8)
            let written = try await volume.write(contents: payload, to: item, at: 0)
            precondition(written == payload.count)
            expected.append((name, item, payload))
            let nfd = name.decomposedStringWithCanonicalMapping
            for query in [name, nfd, name.lowercased()] {
                let (found, canonical) = try await (volume as any FSVolume.Operations).lookupItem(named: FSFileName(string: query), inDirectory: directory)
                precondition((found as! ntfs3gItem).ino == (item as! ntfs3gItem).ino &&
                             Data(canonical.string!.utf8) == Data(nfd.utf8))
                retainedNames.append(canonical)
            }
        }
        let invalidNames = [String(repeating: "L", count: 256), String(repeating: "L", count: 257),
                            String(repeating: "각", count: 256).decomposedStringWithCanonicalMapping,
                            String(repeating: "각", count: 257).decomposedStringWithCanonicalMapping,
                            String(repeating: "😀", count: 128), String(repeating: "😀", count: 128) + "X"]
        for name in invalidNames {
            for type: FSItem.ItemType in [.file, .directory] {
                try await expect(ENAMETOOLONG) {
                    _ = try await (volume as any FSVolume.Operations).createItem(named: FSFileName(string: name),
                        type: type, inDirectory: directory, attributes: FSItem.SetAttributesRequest())
                }
            }
            try await expect(ENAMETOOLONG) {
                _ = try await volume.createLink(to: expected[1].item, named: FSFileName(string: name), inDirectory: directory)
            }
            try await expect(ENAMETOOLONG) {
                _ = try await volume.renameItem(expected[1].item, inDirectory: directory, named: FSFileName(string: names[1]),
                    to: FSFileName(string: name), inDirectory: directory, overItem: nil)
            }
        }
        for name in ["", ".", "..", "/", "part/name", "part/", "/part"] {
            for type: FSItem.ItemType in [.file, .directory] {
                try await expect(EINVAL) {
                    _ = try await (volume as any FSVolume.Operations).createItem(named: FSFileName(string: name),
                        type: type, inDirectory: directory, attributes: FSItem.SetAttributesRequest())
                }
            }
            try await expect(EINVAL) {
                _ = try await volume.createLink(to: expected[1].item, named: FSFileName(string: name), inDirectory: directory)
            }
            try await expect(EINVAL) {
                _ = try await volume.renameItem(expected[1].item, inDirectory: directory, named: FSFileName(string: names[1]),
                    to: FSFileName(string: name), inDirectory: directory, overItem: nil)
            }
            try await expect(EINVAL) {
                _ = try await (volume as any FSVolume.Operations).createSymbolicLink(named: FSFileName(string: name),
                    inDirectory: directory, attributes: FSItem.SetAttributesRequest(),
                    linkContents: FSFileName(string: "../CanonicalNames/LookupMiXeD.txt"))
            }
        }
        let longest = names[4].decomposedStringWithCanonicalMapping
        precondition(longest.utf8.count == 2295)
        var listed: Set<Data> = []
        _ = try await volume.enumerateDirectory(directory, startingAt: FSDirectoryCookie(rawValue: 0),
            verifier: FSDirectoryVerifier(rawValue: 1), attributes: nil,
            packer: nfsk_test_packer { name, _, _, _, _ in
                if let text = name.string, text != "." && text != ".." { listed.insert(Data(text.utf8)) }
                return true
            })
        precondition(listed == Set(names.map { Data($0.decomposedStringWithCanonicalMapping.utf8) }))
        let longAlias = "H" + String(repeating: "각", count: 254)
        _ = try await volume.createLink(to: expected[1].item, named: FSFileName(string: longAlias), inDirectory: directory)
        let (alias, aliasName) = try await (volume as any FSVolume.Operations).lookupItem(named: FSFileName(string: longAlias), inDirectory: directory)
        precondition((alias as! ntfs3gItem).ino == (expected[1].item as! ntfs3gItem).ino &&
                     Data(aliasName.string!.utf8) == Data(longAlias.decomposedStringWithCanonicalMapping.utf8))
        retainedNames.append(aliasName)
        expected.append((longAlias, alias, expected[1].bytes))
        let replacement = String(repeating: "갂", count: 255)
        let renameResult = try await volume.renameItem(expected[4].item, inDirectory: directory, named: FSFileName(string: names[4]),
            to: FSFileName(string: replacement), inDirectory: directory, overItem: nil)
        precondition(Data(renameResult.string!.utf8) == Data(replacement.decomposedStringWithCanonicalMapping.utf8))
        retainedNames.append(renameResult)
        expected[4].name = replacement
        try await expect(ENOENT) {
            _ = try await (volume as any FSVolume.Operations).lookupItem(named: FSFileName(string: names[4]), inDirectory: directory)
        }
        try await volume.synchronize(flags: .wait)
        let released = await volume.teardown()
        precondition(released == 0)
        precondition(retainedNames[12].string!.utf8.count == 2295 &&
                     Data(retainedNames.last!.string!.utf8) == Data(replacement.decomposedStringWithCanonicalMapping.utf8),
                     "Canonical names must own their bytes after C release and volume teardown")

        let readOnly = try ntfs3gVolume(backend: backend(image, writable: false),
            activationBackend: { _, _ in nil }, onContainerStatusChange: { _ in })
        let (reopenedDirectory, _) = try await (readOnly as any FSVolume.Operations).lookupItem(named: FSFileName(string: "CanonicalNames"), inDirectory: root)
        for entry in expected {
            let (found, actual) = try await (readOnly as any FSVolume.Operations).lookupItem(named: FSFileName(string: entry.name), inDirectory: reopenedDirectory)
            precondition((found as! ntfs3gItem).ino == (entry.item as! ntfs3gItem).ino &&
                         Data(actual.string!.utf8) == Data(entry.name.decomposedStringWithCanonicalMapping.utf8))
        }
        let readOnlyReleased = await readOnly.teardown()
        precondition(readOnlyReleased == 0)
        let native = try backend(image, writable: false)
        var error: Int32 = 0
        guard let handle = nfsk_mount(native.backend, true, &error) else { throw posixError(error) }
        for entry in expected {
            var bytes = Data(count: entry.bytes.count)
            let read = bytes.withUnsafeMutableBytes { nfsk_read(handle, (entry.item as! ntfs3gItem).ino, 0, $0.baseAddress, Int64($0.count), &error) }
            precondition(read == entry.bytes.count && bytes == entry.bytes)
        }
        precondition(nfsk_umount(handle) == 0)
        nfsk_backend_free(native.backend)
        print("PASS: complete canonical names, 24 overlong and 35 invalid-component rejections, POSIX punctuation, case/NFC/NFD lookup, hard links, long rename, owned lifetime and reopened payloads")
    }

    static func ignoredNonFileSizeTests(_ image: URL) async throws -> Int {
        var failures = 0, checks = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures += 1; print("FAIL: \(message)") }
        }
        func sameTime(_ a: timespec, _ b: timespec) -> Bool { a.tv_sec == b.tv_sec && a.tv_nsec == b.tv_nsec }
        let volume = try ntfs3gVolume(backend: backend(image, writable: true),
            activationBackend: { _, _ in nil }, onContainerStatusChange: { _ in })
        let root = ntfs3gItem(ino: NFSK_ROOT_INO, parentIno: NFSK_PARENT_OF_ROOT, name: FSFileName(string: "/"))
        let ops = volume as any FSVolume.Operations
        let (parent, _) = try await ops.createItem(named: FSFileName(string: "IgnoredSize"), type: .directory,
            inDirectory: root, attributes: FSItem.SetAttributesRequest())
        let (directory, _) = try await ops.createItem(named: FSFileName(string: "Child"), type: .directory,
            inDirectory: parent, attributes: FSItem.SetAttributesRequest())
        let target = "../IgnoredSize/Payload.bin"
        let (link, _) = try await ops.createSymbolicLink(named: FSFileName(string: "Link"), inDirectory: parent,
            attributes: FSItem.SetAttributesRequest(), linkContents: FSFileName(string: target))
        let (file, _) = try await ops.createItem(named: FSFileName(string: "Payload.bin"), type: .file,
            inDirectory: parent, attributes: FSItem.SetAttributesRequest())
        let payload = Data("non-file size requests preserve payload".utf8)
        let written = try await volume.write(contents: payload, to: file, at: 0)
        precondition(written == payload.count)
        let get = FSItem.GetAttributesRequest()
        get.wantedAttributes = [.type, .size, .allocSize, .modifyTime, .changeTime, .flags, .linkCount]
        var created: [(String, FSItem, FSItem.ItemType)] = []
        for kind: FSItem.ItemType in [.directory, .symlink] {
            for (index, size) in [UInt64(0), 7, UInt64.max].enumerated() {
                let name = "Created-\(kind.rawValue)-\(index)"
                let request = FSItem.SetAttributesRequest()
                request.size = size
                request.modifyTime = timespec(tv_sec: 946684801, tv_nsec: 123456700)
                var code = 0
                do {
                    let result: (FSItem, FSFileName)
                    if kind == .directory {
                        result = try await ops.createItem(named: FSFileName(string: name), type: kind,
                            inDirectory: parent, attributes: request)
                    } else {
                        result = try await ops.createSymbolicLink(named: FSFileName(string: name), inDirectory: parent,
                            attributes: request, linkContents: FSFileName(string: target))
                    }
                    let item = result.0
                    created.append((name, item, kind))
                    let actual = try await volume.attributes(get, of: item)
                    check(actual.type == kind && sameTime(actual.modifyTime, request.modifyTime) &&
                          request.wasAttributeConsumed(.modifyTime), "created non-file applies requested time")
                    if kind == .symlink {
                        let contents = try await volume.readSymbolicLink(item)
                        check(contents.string == target, "created link ignores requested size and keeps its target")
                    }
                } catch { code = (error as NSError).code }
                print("IGNORED SIZE CREATE: kind=\(kind.rawValue) case=\(index) size=\(size) code=\(code) consumed=\(request.wasAttributeConsumed(.size))")
                check(code == 0 && !request.wasAttributeConsumed(.size), "creation ignores non-file size without consuming it")
            }
        }
        check(created.count == 6, "all directory/symlink creations survive ignored sizes")

        let resize = FSItem.SetAttributesRequest()
        for size in [payload.count + 4096, payload.count] {
            resize.size = UInt64(size)
            let actual = try await volume.setAttributes(resize, on: file)
            check(actual.size == UInt64(size) && resize.wasAttributeConsumed(.size), "regular-file size still grows/shrinks and is consumed")
        }
        let oversized = FSItem.SetAttributesRequest(); oversized.size = UInt64.max
        try await expect(EFBIG) { _ = try await volume.setAttributes(oversized, on: file) }
        try await expect(EFBIG) {
            _ = try await ops.createItem(named: FSFileName(string: "OversizedFile"), type: .file,
                inDirectory: parent, attributes: oversized)
        }
        try await expect(ENOENT) { _ = try await ops.lookupItem(named: FSFileName(string: "OversizedFile"), inDirectory: parent) }
        let invalidTime = FSItem.SetAttributesRequest()
        invalidTime.size = 0; invalidTime.modifyTime = timespec(tv_sec: 0, tv_nsec: -1)
        try await expect(EINVAL) { _ = try await volume.setAttributes(invalidTime, on: directory) }
        let (missing, _) = try await ops.createItem(named: FSFileName(string: "Missing"), type: .file,
            inDirectory: parent, attributes: FSItem.SetAttributesRequest())
        try await volume.removeItem(missing, named: FSFileName(string: "Missing"), fromDirectory: parent)
        let ignored = FSItem.SetAttributesRequest(); ignored.size = 0
        try await expect(ENOENT) { _ = try await volume.setAttributes(ignored, on: missing) }

        let nonFiles: [(String, FSItem)] = [("root", root), ("Child", directory), ("Link", link)]
        var preserved: [(String, FSItem, FSItem.Attributes)] = []
        for (kind, entry) in nonFiles.enumerated() {
            let initial = try await volume.attributes(get, of: entry.1)
            for (index, size) in [UInt64(0), initial.size + 1, initial.size, UInt64.max].enumerated() {
                for combined in [false, true] {
                    let before = try await volume.attributes(get, of: entry.1)
                    let request = FSItem.SetAttributesRequest(); request.size = size
                    if combined { request.modifyTime = timespec(tv_sec: 946685000 + kind * 10 + index, tv_nsec: 123456700) }
                    var code = 0
                    do { _ = try await volume.setAttributes(request, on: entry.1) }
                    catch { code = (error as NSError).code }
                    print("IGNORED SIZE SET: kind=\(entry.0) case=\(index) combined=\(combined) size=\(size) code=\(code) consumed=\(request.wasAttributeConsumed(.size))")
                    check(code == 0 && !request.wasAttributeConsumed(.size), "non-file size is ignored without an error or consumed bit")
                    let after = try await volume.attributes(get, of: entry.1)
                    check(after.type == before.type && after.size == before.size && after.allocSize == before.allocSize &&
                          after.flags == before.flags && after.linkCount == before.linkCount,
                          "ignored size preserves type, size, allocation, flags and links")
                    if combined {
                        check(sameTime(after.modifyTime, request.modifyTime) && request.wasAttributeConsumed(.modifyTime),
                              "ignored size does not block requested time update")
                    } else {
                        check(sameTime(after.modifyTime, before.modifyTime) && sameTime(after.changeTime, before.changeTime),
                              "size-only non-file request leaves timestamps unchanged")
                    }
                }
            }
            let after = try await volume.attributes(get, of: entry.1)
            preserved.append((entry.0, entry.1, after))
        }
        let linkContents = try await volume.readSymbolicLink(link)
        check(linkContents.string == target, "all ignored requests preserve the original symlink target")
        try await volume.synchronize(flags: .wait)
        let released = await volume.teardown(); check(released == 0, "size-request volume retires cleanly")

        let readOnly = try ntfs3gVolume(backend: backend(image, writable: false),
            activationBackend: { _, _ in nil }, onContainerStatusChange: { _ in })
        let readOps = readOnly as any FSVolume.Operations
        let (reopenedParent, _) = try await readOps.lookupItem(named: FSFileName(string: "IgnoredSize"), inDirectory: root)
        for (name, item, saved) in preserved {
            let actual = try await readOnly.attributes(get, of: item)
            check(actual.type == saved.type && actual.size == saved.size && actual.allocSize == saved.allocSize &&
                  actual.linkCount == saved.linkCount && actual.flags == saved.flags &&
                  sameTime(actual.modifyTime, saved.modifyTime) && sameTime(actual.changeTime, saved.changeTime),
                  "read-only reopen preserves non-file attributes for \(name)")
        }
        for (name, item, kind) in created {
            let (found, _) = try await readOps.lookupItem(named: FSFileName(string: name), inDirectory: reopenedParent)
            let actual = try await readOnly.attributes(get, of: found)
            check((found as! ntfs3gItem).ino == (item as! ntfs3gItem).ino && actual.type == kind &&
                  actual.modifyTime.tv_sec == 946684801 && actual.modifyTime.tv_nsec == 123456700,
                  "read-only reopen preserves newly created non-file and metadata")
            if kind == .symlink {
                let contents = try await readOnly.readSymbolicLink(found)
                check(contents.string == target, "read-only reopen preserves created link target")
            }
        }
        var names: Set<String> = []
        _ = try await readOnly.enumerateDirectory(reopenedParent, startingAt: FSDirectoryCookie(rawValue: 0),
            verifier: FSDirectoryVerifier(rawValue: 1), attributes: nil,
            packer: nfsk_test_packer { name, _, _, _, _ in
                if let name = name.string, name != "." && name != ".." { names.insert(name) }
                return true
            })
        check(names == Set(["Child", "Link", "Payload.bin"] + created.map { $0.0 }), "reopened namespace has no failed-create residue")
        try await expect(EROFS) { _ = try await readOnly.setAttributes(ignored, on: directory) }
        let originalTarget = try await readOnly.readSymbolicLink(link)
        check(originalTarget.string == target, "reopened original target is unchanged")
        let readReleased = await readOnly.teardown(); check(readReleased == 0, "read-only size observer retires cleanly")
        let native = try backend(image, writable: false)
        var error: Int32 = 0
        guard let handle = nfsk_mount(native.backend, true, &error) else { throw posixError(error) }
        var bytes = Data(count: payload.count + 1)
        let read = bytes.withUnsafeMutableBytes { nfsk_read(handle, (file as! ntfs3gItem).ino, 0, $0.baseAddress, Int64($0.count), &error) }
        check(read == payload.count && bytes.prefix(payload.count) == payload, "reopened file payload and EOF survive ignored/oversized requests")
        check(nfsk_umount(handle) == 0, "native payload observer retires cleanly")
        nfsk_backend_free(native.backend)
        print("NONFILE SIZE SUMMARY: \(checks) checks, \(failures) failures, created=\(created.count)/6")
        return failures
    }

    static func ignoredBackupTimeTests(_ image: URL) async throws -> Int {
        var failures = 0, checks = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures += 1; print("FAIL: \(message)") }
        }
        func sameTime(_ a: timespec, _ b: timespec) -> Bool { a.tv_sec == b.tv_sec && a.tv_nsec == b.tv_nsec }
        func backupRequest() -> FSItem.SetAttributesRequest {
            let request = FSItem.SetAttributesRequest()
            request.backupTime = timespec(tv_sec: 946684803, tv_nsec: 123456700)
            return request
        }
        func rejected(_ expected: Int32, _ label: String, _ operation: () async throws -> Void) async {
            var code = 0
            do { try await operation() } catch { code = (error as NSError).code }
            print("BACKUP ERROR: case=\(label) expected=\(expected) actual=\(code)")
            check(code == Int(expected), "backupTime does not mask \(label) error")
        }
        let volume = try ntfs3gVolume(backend: backend(image, writable: true),
            activationBackend: { _, _ in nil }, onContainerStatusChange: { _ in })
        let ops = volume as any FSVolume.Operations
        let root = ntfs3gItem(ino: NFSK_ROOT_INO, parentIno: NFSK_PARENT_OF_ROOT, name: FSFileName(string: "/"))
        let (parent, _) = try await ops.createItem(named: FSFileName(string: "IgnoredBackupTime"), type: .directory,
            inDirectory: root, attributes: FSItem.SetAttributesRequest())
        let (directory, _) = try await ops.createItem(named: FSFileName(string: "Child"), type: .directory,
            inDirectory: parent, attributes: FSItem.SetAttributesRequest())
        let target = "./Payload.bin"
        let (link, _) = try await ops.createSymbolicLink(named: FSFileName(string: "Link"), inDirectory: parent,
            attributes: FSItem.SetAttributesRequest(), linkContents: FSFileName(string: target))
        let (file, _) = try await ops.createItem(named: FSFileName(string: "Payload.bin"), type: .file,
            inDirectory: parent, attributes: FSItem.SetAttributesRequest())
        let payload = Data("backupTime must not veto supported metadata".utf8)
        let written = try await volume.write(contents: payload, to: file, at: 0)
        precondition(written == payload.count)
        let get = FSItem.GetAttributesRequest()
        get.wantedAttributes = [.type, .size, .allocSize, .mode, .uid, .gid, .flags, .linkCount,
                                .modifyTime, .accessTime, .birthTime, .changeTime, .backupTime, .addedTime]
        var created: [(String, FSItem, FSItem.ItemType)] = []
        for kind: FSItem.ItemType in [.file, .directory, .symlink] {
            let name = "Created-\(kind.rawValue)"
            let request = backupRequest()
            request.size = kind == .file ? 16 : UInt64.max
            request.modifyTime = timespec(tv_sec: 946684901, tv_nsec: 123456700)
            var code = 0
            do {
                let result: (FSItem, FSFileName)
                if kind == .symlink {
                    result = try await ops.createSymbolicLink(named: FSFileName(string: name), inDirectory: parent,
                        attributes: request, linkContents: FSFileName(string: target))
                } else {
                    result = try await ops.createItem(named: FSFileName(string: name), type: kind,
                        inDirectory: parent, attributes: request)
                }
                created.append((name, result.0, kind))
                let attrs = try await volume.attributes(get, of: result.0)
                check(attrs.type == kind && sameTime(attrs.modifyTime, request.modifyTime) &&
                      request.wasAttributeConsumed(.modifyTime) &&
                      request.wasAttributeConsumed(.size) == (kind == .file), "creation uses supported fields alongside backupTime")
                check(!attrs.isValid(.backupTime) && !request.wasAttributeConsumed(.backupTime), "creation does not fabricate backup time")
            } catch { code = (error as NSError).code }
            print("BACKUP CREATE: kind=\(kind.rawValue) code=\(code)")
            check(code == 0, "backupTime does not reject initial file/directory/link attributes")
        }
        check(created.count == 3, "all optional-backup-time creations succeed")
        let entries: [(String, FSItem)] = [("root", root), ("Payload.bin", file), ("Child", directory), ("Link", link)]
        for (name, item) in entries {
            for combined in [false, true] {
                let before = try await volume.attributes(get, of: item)
                let request = backupRequest()
                if combined {
                    request.size = before.type == .file ? UInt64(payload.count + 7) : UInt64.max
                    request.modifyTime = timespec(tv_sec: 946685001, tv_nsec: 123456700)
                    request.accessTime = timespec(tv_sec: 946685002, tv_nsec: 123456700)
                    request.birthTime = timespec(tv_sec: 946685003, tv_nsec: 123456700)
                    request.flags = name == "root" ? 0 : UInt32(UF_HIDDEN)
                    request.mode = 0o400; request.uid = 12345; request.gid = 12346
                    request.addedTime = timespec(tv_sec: 946685004, tv_nsec: 0)
                }
                var code = 0
                do { _ = try await volume.setAttributes(request, on: item) }
                catch { code = (error as NSError).code }
                print("BACKUP SET: kind=\(name) combined=\(combined) code=\(code) consumed=\(request.wasAttributeConsumed(.backupTime))")
                check(code == 0, "backupTime alone or combined is accepted")
                let after = try await volume.attributes(get, of: item)
                check(!after.isValid(.backupTime) && !request.wasAttributeConsumed(.backupTime), "unsupported backupTime remains absent and unconsumed")
                if combined {
                    check(sameTime(after.modifyTime, request.modifyTime) && sameTime(after.accessTime, request.accessTime) &&
                          sameTime(after.birthTime, request.birthTime) && after.flags == request.flags &&
                          [.modifyTime, .accessTime, .birthTime, .flags].allSatisfy { request.wasAttributeConsumed($0) },
                          "supported native fields apply despite backupTime")
                    check(after.size == (before.type == .file ? request.size : before.size) &&
                          request.wasAttributeConsumed(.size) == (before.type == .file), "size semantics survive optional backupTime")
                    check(after.mode == before.mode && after.uid == before.uid && after.gid == before.gid &&
                          !after.isValid(.addedTime) && [.mode, .uid, .gid, .addedTime].allSatisfy { !request.wasAttributeConsumed($0) },
                          "existing ignored ownership and addedTime fields stay unconsumed")
                } else {
                    check(after.size == before.size && after.allocSize == before.allocSize && after.flags == before.flags &&
                          after.linkCount == before.linkCount && sameTime(after.modifyTime, before.modifyTime) &&
                          sameTime(after.accessTime, before.accessTime) && sameTime(after.birthTime, before.birthTime) &&
                          sameTime(after.changeTime, before.changeTime), "backup-only request preserves all actual metadata")
                }
            }
        }
        let beforeErrors = try await volume.attributes(get, of: file)
        let badFlags = backupRequest(); badFlags.size = 1; badFlags.flags = UInt32(UF_IMMUTABLE)
        await rejected(ENOTSUP, "flags") { _ = try await volume.setAttributes(badFlags, on: file) }
        let badTime = backupRequest(); badTime.size = 1; badTime.modifyTime = timespec(tv_sec: 0, tv_nsec: -1)
        await rejected(EINVAL, "time") { _ = try await volume.setAttributes(badTime, on: file) }
        let huge = backupRequest(); huge.size = UInt64.max
        await rejected(EFBIG, "file-size") { _ = try await volume.setAttributes(huge, on: file) }
        await rejected(EFBIG, "create-size") {
            _ = try await ops.createItem(named: FSFileName(string: "Rejected"), type: .file, inDirectory: parent, attributes: huge)
        }
        try await expect(ENOENT) { _ = try await ops.lookupItem(named: FSFileName(string: "Rejected"), inDirectory: parent) }
        let afterErrors = try await volume.attributes(get, of: file)
        check(afterErrors.size == beforeErrors.size && afterErrors.flags == beforeErrors.flags &&
              sameTime(afterErrors.modifyTime, beforeErrors.modifyTime) && sameTime(afterErrors.changeTime, beforeErrors.changeTime),
              "invalid combined fields reject before changing file size or metadata")
        let (missing, _) = try await ops.createItem(named: FSFileName(string: "Missing"), type: .file,
            inDirectory: parent, attributes: FSItem.SetAttributesRequest())
        try await volume.removeItem(missing, named: FSFileName(string: "Missing"), fromDirectory: parent)
        await rejected(ENOENT, "missing") { _ = try await volume.setAttributes(backupRequest(), on: missing) }
        var saved: [(String, FSItem, FSItem.Attributes)] = []
        for (name, item) in entries { saved.append((name, item, try await volume.attributes(get, of: item))) }
        try await volume.synchronize(flags: .wait)
        let released = await volume.teardown(); check(released == 0, "backup-time writer retires cleanly")
        let readOnly = try ntfs3gVolume(backend: backend(image, writable: false),
            activationBackend: { _, _ in nil }, onContainerStatusChange: { _ in })
        let readOps = readOnly as any FSVolume.Operations
        let (reopenedParent, _) = try await readOps.lookupItem(named: FSFileName(string: "IgnoredBackupTime"), inDirectory: root)
        for (name, item, expected) in saved {
            let actual = try await readOnly.attributes(get, of: item)
            check(actual.type == expected.type && actual.size == expected.size && actual.flags == expected.flags &&
                  actual.linkCount == expected.linkCount && sameTime(actual.modifyTime, expected.modifyTime) &&
                  sameTime(actual.accessTime, expected.accessTime) && sameTime(actual.birthTime, expected.birthTime) &&
                  sameTime(actual.changeTime, expected.changeTime) && !actual.isValid(.backupTime), "reopen preserves real fields for \(name)")
        }
        for (name, item, kind) in created {
            let (found, _) = try await readOps.lookupItem(named: FSFileName(string: name), inDirectory: reopenedParent)
            let actual = try await readOnly.attributes(get, of: found)
            check((found as! ntfs3gItem).ino == (item as! ntfs3gItem).ino && actual.type == kind &&
                  actual.modifyTime.tv_sec == 946684901 && actual.modifyTime.tv_nsec == 123456700 &&
                  !actual.isValid(.backupTime), "created object and supported metadata persist")
            if kind == .symlink {
                let contents = try await readOnly.readSymbolicLink(found)
                check(contents.string == target, "created link retains its target")
            }
        }
        let originalTarget = try await readOnly.readSymbolicLink(link)
        check(originalTarget.string == target, "original target survives optional backup time")
        await rejected(EROFS, "read-only") { _ = try await readOnly.setAttributes(backupRequest(), on: file) }
        let readReleased = await readOnly.teardown(); check(readReleased == 0, "backup-time observer retires cleanly")
        let native = try backend(image, writable: false)
        var error: Int32 = 0
        guard let handle = nfsk_mount(native.backend, true, &error) else { throw posixError(error) }
        let expectedPayload = payload + Data(repeating: 0, count: 7)
        var bytes = Data(count: expectedPayload.count + 1)
        let read = bytes.withUnsafeMutableBytes { nfsk_read(handle, (file as! ntfs3gItem).ino, 0, $0.baseAddress, Int64($0.count), &error) }
        check(read == expectedPayload.count && bytes.prefix(expectedPayload.count) == expectedPayload,
              "reopened payload preserves accepted size growth and rejected-request integrity")
        for (_, item, kind) in created where kind == .file {
            var zeroes = Data(repeating: 0x5a, count: 17)
            let count = zeroes.withUnsafeMutableBytes { nfsk_read(handle, (item as! ntfs3gItem).ino, 0, $0.baseAddress, Int64($0.count), &error) }
            check(count == 16 && zeroes.prefix(16).allSatisfy { $0 == 0 }, "created file size is applied and zero-initialized")
        }
        check(nfsk_umount(handle) == 0, "backup payload observer retires cleanly")
        nfsk_backend_free(native.backend)
        print("BACKUP SUMMARY: \(checks) checks, \(failures) failures, created=\(created.count)/3")
        return failures
    }

    static func bomXattrTests(_ image: URL) async throws -> Int {
        let keys = ["\u{FEFF}", "\u{FEFF}\u{FEFF}", "\u{FEFF}alpha", "\u{FEFF}\u{FEFF}alpha",
                    "\u{FEFF}$private", "\u{FEFF}WofCompressedData", "\u{FEFF}ntfs-3g.acl",
                    "\u{FEFF}" + String(repeating: "a", count: 124)]
        let body = Data("ordinary Swift body stays separate".utf8)
        let neighbor = Data("neighbor".utf8), first = Data("bom-first".utf8), final = Data("bom-final".utf8)
        var checks = 0, failures = 0
        func check(_ valid: Bool, _ message: String) {
            checks += 1
            if !valid { failures += 1; print("FAIL: BOM Swift \(message)") }
        }
        func status(_ operation: () async throws -> Void) async -> Int {
            do { try await operation(); return 0 }
            catch { return (error as NSError).code }
        }
        let prepared = try backend(image, writable: true)
        var error: Int32 = 0
        guard let handle = nfsk_mount(prepared.backend, false, &error) else { throw posixError(error) }
        var inodes: [UInt64] = []
        for index in keys.indices {
            let ino = nfsk_create(handle, NFSK_ROOT_INO, "SwiftXattrBOM\(index)", UInt32(NFSK_TYPE_FILE), &error)
            precondition(ino != 0)
            precondition(body.withUnsafeBytes { nfsk_write(handle, ino, 0, $0.baseAddress, Int64($0.count), &error) } == body.count)
            precondition(neighbor.withUnsafeBytes { nfsk_setxattr(handle, ino, "alpha", $0.baseAddress, $0.count, Int32(NFSK_XATTR_CREATE)) } == 0)
            inodes.append(ino)
        }
        precondition(nfsk_sync(handle) == 0 && nfsk_umount(handle) == 0)
        prepared.cleanup(); nfsk_backend_free(prepared.backend)

        let volume = try ntfs3gVolume(backend: backend(image, writable: true),
            activationBackend: { _, _ in nil }, onContainerStatusChange: { _ in })
        let root = ntfs3gItem(ino: NFSK_ROOT_INO, parentIno: NFSK_PARENT_OF_ROOT, name: FSFileName(string: "/"))
        var retainedValues: [Data] = [], retainedNames: [[Data]] = []
        for index in keys.indices {
            let (item, _) = try await (volume as any FSVolume.Operations).lookupItem(
                named: FSFileName(string: "SwiftXattrBOM\(index)"), inDirectory: root)
            let name = FSFileName(data: Data(keys[index].utf8))
            check(name.data == Data(keys[index].utf8), "producer retains raw name bytes")
            let missing = await status { _ = try await volume.xattr(named: name, of: item) }
            let missingDelete = await status { try await volume.setXattr(named: name, to: nil, on: item, policy: .delete) }
            check(missing == Int(ENOATTR) && missingDelete == Int(ENOATTR), "absent name cannot alias body/neighbor")
            let create = await status { try await volume.setXattr(named: name, to: first, on: item, policy: .mustCreate) }
            check(create == 0, "literal name creates independently")
            var readback: Data?
            let read = await status { readback = try await volume.xattr(named: name, of: item) }
            check(read == 0 && readback == first, "complete literal value returned")
            if let readback { retainedValues.append(readback) }
            let duplicate = await status { try await volume.setXattr(named: name, to: final, on: item, policy: .mustCreate) }
            check(duplicate == Int(EEXIST), "duplicate exact name rejected")
            let replace = await status { try await volume.setXattr(named: name, to: final, on: item, policy: .mustReplace) }
            check(replace == 0, "replace exact name")
            var listed: [FSFileName] = []
            let list = await status { listed = try await volume.xattrs(of: item) }
            let raw = listed.map(\.data)
            check(list == 0 && Set(raw) == Set([Data("alpha".utf8), Data(keys[index].utf8)]), "list preserves complete BOM bytes")
            retainedNames.append(raw)
            let remove = await status { try await volume.setXattr(named: name, to: nil, on: item, policy: .delete) }
            let gone = await status { _ = try await volume.xattr(named: name, of: item) }
            check(remove == 0 && gone == Int(ENOATTR), "delete exact named attribute")
            let recreate = await status { try await volume.setXattr(named: name, to: final, on: item, policy: .alwaysSet) }
            check(recreate == 0, "always-set recreates literal name")
            var actualNeighbor: Data?
            let neighborCode = await status { actualNeighbor = try await volume.xattr(named: FSFileName(string: "alpha"), of: item) }
            check(neighborCode == 0 && actualNeighbor == neighbor, "unprefixed neighbor retained")
            print("BOM_SWIFT_CASE index=\(index) missing=\(missing) delete=\(missingDelete) create=\(create) read=\(read) replace=\(replace) list=\(list) neighbor=\(actualNeighbor == neighbor)")
        }
        let firstItem = ntfs3gItem(ino: inodes[0], parentIno: NFSK_ROOT_INO, name: FSFileName(string: "SwiftXattrBOM0"))
        let tooLong = FSFileName(data: Data(("\u{FEFF}" + String(repeating: "a", count: 125)).utf8))
        check(await status { try await volume.setXattr(named: tooLong, to: first, on: firstItem, policy: .alwaysSet) } == Int(ENAMETOOLONG),
              "original UTF8 bytes determine name limit")
        check(await status { _ = try await volume.xattr(named: FSFileName(data: Data([0xff])), of: firstItem) } == Int(EINVAL),
              "invalid UTF8 still fails strict validation")
        for key in ["$private", "WofCompressedData", "ntfs-3g.acl"] {
            check(await status { try await volume.setXattr(named: FSFileName(string: key), to: first, on: firstItem, policy: .alwaysSet) } == Int(EPERM),
                  "actual private streams remain protected")
        }
        check(await status { try await volume.synchronize(flags: .wait) } == 0, "synchronize succeeds")
        check(await volume.teardown() == 0, "writable volume retires cleanly")
        check(retainedValues.count == keys.count && retainedValues.allSatisfy { $0 == first }, "returned values outlive replacement and retirement")
        for index in keys.indices {
            check(Set(retainedNames[index]) == Set([Data("alpha".utf8), Data(keys[index].utf8)]), "returned names outlive retirement")
        }

        let reopened = try backend(image, writable: false)
        guard let reader = nfsk_mount(reopened.backend, true, &error) else { throw posixError(error) }
        for index in keys.indices {
            var bytes = [UInt8](repeating: 0, count: 128)
            let count = bytes.withUnsafeMutableBytes { nfsk_read(reader, inodes[index], 0, $0.baseAddress, Int64($0.count), &error) }
            let bodyOK = count == body.count && Data(bytes.prefix(body.count)) == body
            check(bodyOK, "native ordinary contents and EOF survive all policies")
            var owned: UnsafeMutableRawPointer?
            let size = nfsk_getxattr_alloc(reader, inodes[index], keys[index], &owned)
            let actual = owned.map { Data(bytes: $0, count: max(0, Int(size))) }
            free(owned)
            check(size == final.count && actual == final, "bridge readback resolves literal raw name after reopen")
            print("BOM_SWIFT_CONTENT index=\(index) body=\(bodyOK) literal=\(actual == final)")
        }
        check(nfsk_umount(reader) == 0, "read-only native reader retires")
        reopened.cleanup(); nfsk_backend_free(reopened.backend)
        print("BOM SWIFT SUMMARY: \(checks) checks, \(failures) failures")
        return failures
    }

    static func bomNamespaceTests(_ image: URL) async throws -> Int {
        var checks = 0, failures = 0
        func check(_ ok: Bool, _ message: String) {
            checks += 1
            if !ok { failures += 1; print("FAIL NAMESPACE BOM SWIFT: \(message)") }
        }
        func status(_ operation: () async throws -> Void) async -> Int {
            do { try await operation(); return 0 } catch { return (error as NSError).code }
        }
        func raw(_ text: String) -> FSFileName { FSFileName(data: Data(text.utf8)) }
        let keys = ["\u{FEFF}", "\u{FEFF}\u{FEFF}", "\u{FEFF}Alpha", "\u{FEFF}\u{FEFF}Alpha",
                    "\u{FEFF}e\u{0301}", "\u{FEFF}.", "\u{FEFF}..",
                    "\u{FEFF}" + String(repeating: "각", count: 254),
                    "\u{FEFF}" + String(repeating: "😀", count: 127)]
        let volume = try ntfs3gVolume(backend: backend(image, writable: true),
            activationBackend: { _, _ in nil }, onContainerStatusChange: { _ in })
        let root = ntfs3gItem(ino: NFSK_ROOT_INO, parentIno: NFSK_PARENT_OF_ROOT, name: raw("/"))
        let ops = volume as any FSVolume.Operations
        var retained: [(FSFileName, Data)] = []
        var payloads: [(UInt64, Data)] = []
        var persisted: [(FSItem, String, UInt64)] = []
        for (index, key) in keys.enumerated() {
            let (parent, _) = try await ops.createItem(named: raw("SwiftNamespaceBOM\(index)"), type: .directory,
                inDirectory: root, attributes: FSItem.SetAttributesRequest())
            let (neighbor, _) = try await ops.createItem(named: raw("Alpha"), type: .file,
                inDirectory: parent, attributes: FSItem.SetAttributesRequest())
            let neighborBytes = Data("Unprefixed-neighbor-\(index)".utf8)
            _ = try await volume.write(contents: neighborBytes, to: neighbor, at: 0)
            payloads.append(((neighbor as! ntfs3gItem).ino, neighborBytes))
            let name = raw(key), expected = Data(key.decomposedStringWithCanonicalMapping.utf8)
            check(name.data == Data(key.utf8), "producer retains raw prefix bytes")
            check(await status { _ = try await ops.lookupItem(named: name, inDirectory: parent) } == Int(ENOENT),
                  "missing literal name does not look up the unprefixed neighbor")
            check(await status { try await volume.removeItem(neighbor, named: name, fromDirectory: parent) } == Int(ENOENT),
                  "missing literal removal leaves the neighbor alone")
            var file: FSItem?
            let created = await status {
                let (item, actual) = try await ops.createItem(named: name, type: .file,
                    inDirectory: parent, attributes: FSItem.SetAttributesRequest())
                file = item; retained.append((actual, Data(key.utf8)))
                check(actual.data == Data(key.utf8), "file creation reply retains literal name bytes")
            }
            check(created == 0, "literal BOM file creation succeeds")
            if let file {
                let ino = (file as! ntfs3gItem).ino, body = Data("BOM-file-\(index)".utf8)
                check(await status { _ = try await volume.write(contents: body, to: file, at: 0) } == 0, "write BOM file payload")
                payloads.append((ino, body)); persisted.append((parent, key, ino))
                var found: FSItem?, canonical: FSFileName?
                let lookup = await status {
                    (found, canonical) = try await ops.lookupItem(named: raw(key.lowercased()), inDirectory: parent)
                }
                check(lookup == 0 && (found as? ntfs3gItem)?.ino == ino && canonical?.data == expected,
                      "lookup preserves BOM while retaining case-folded and NFD canonical behavior")
                if let canonical { retained.append((canonical, expected)) }
                let attributes = FSItem.GetAttributesRequest(); attributes.wantedAttributes = [.size]
                for request in [nil, attributes] {
                    var actual: [Data] = []
                    let listed = await status {
                        _ = try await volume.enumerateDirectory(parent, startingAt: FSDirectoryCookie(rawValue: 0),
                            verifier: FSDirectoryVerifier(rawValue: 1), attributes: request,
                            packer: nfsk_test_packer { name, _, _, _, _ in
                                if name.data != Data(".".utf8) && name.data != Data("..".utf8) { actual.append(name.data) }
                                return true
                            })
                    }
                    check(listed == 0 && actual.count == 2 && Set(actual) == Set([Data("Alpha".utf8), expected]),
                          "Swift packer receives distinct literal names with and without attributes")
                }
                let (links, _) = try await ops.createItem(named: raw("Links"), type: .directory,
                    inDirectory: parent, attributes: FSItem.SetAttributesRequest())
                check(await status {
                    let actual = try await volume.createLink(to: file, named: name, inDirectory: links)
                    retained.append((actual, Data(key.utf8)))
                    check(actual.data == Data(key.utf8), "hardlink reply preserves prefix")
                } == 0, "BOM hardlink creation succeeds")
                check(await status {
                    _ = try await volume.renameItem(file, inDirectory: links, named: name, to: raw("Moved"),
                        inDirectory: links, overItem: nil)
                } == 0, "rename addresses literal source")
                check(await status {
                    let actual = try await volume.renameItem(file, inDirectory: links, named: raw("Moved"), to: name,
                        inDirectory: links, overItem: nil)
                    retained.append((actual, expected)); check(actual.data == expected, "rename reply preserves normalized literal destination")
                } == 0, "rename writes literal destination")
                check(await status { try await volume.removeItem(file, named: name, fromDirectory: links) } == 0,
                      "literal hardlink removal succeeds")
                check(await status { _ = try await ops.lookupItem(named: name, inDirectory: links) } == Int(ENOENT),
                      "removed literal hardlink stays absent")
            }
            let (container, _) = try await ops.createItem(named: raw("Directories"), type: .directory,
                inDirectory: parent, attributes: FSItem.SetAttributesRequest())
            check(await status {
                let (_, actual) = try await ops.createItem(named: name, type: .directory,
                    inDirectory: container, attributes: FSItem.SetAttributesRequest())
                retained.append((actual, Data(key.utf8))); check(actual.data == Data(key.utf8), "directory creation preserves raw prefix")
            } == 0, "BOM directory creation succeeds")
            let (symlinks, _) = try await ops.createItem(named: raw("Symlinks"), type: .directory,
                inDirectory: parent, attributes: FSItem.SetAttributesRequest())
            check(await status {
                let (link, actual) = try await ops.createSymbolicLink(named: name, inDirectory: symlinks,
                    attributes: FSItem.SetAttributesRequest(), linkContents: raw("../Alpha"))
                retained.append((actual, Data(key.utf8)))
                let target = try await volume.readSymbolicLink(link)
                check(actual.data == Data(key.utf8) && target.data == Data("../Alpha".utf8),
                      "symlink basename preserves prefix with unchanged ordinary target")
                let (_, canonical) = try await ops.lookupItem(named: name, inDirectory: symlinks)
                check(canonical.data == expected, "symlink canonical name retains BOM")
            } == 0, "BOM symlink creation and lookup succeed")
            check(await status {
                let (found, _) = try await ops.lookupItem(named: raw("Alpha"), inDirectory: parent)
                check((found as! ntfs3gItem).ino == (neighbor as! ntfs3gItem).ino, "unprefixed neighbor keeps its original identity")
            } == 0, "unprefixed neighbor still resolves")
            print("NAMESPACE BOM SWIFT CASE: index=\(index) create=\(created)")
        }
        let invalid = FSFileName(data: Data([0xef, 0xbb, 0xbf, 0xff]))
        check(await status { _ = try await ops.lookupItem(named: invalid, inDirectory: root) } == Int(EINVAL),
              "strict raw-data decoder rejects malformed UTF8")
        let tooLong = raw("\u{FEFF}" + String(repeating: "L", count: 255))
        check(await status {
            _ = try await ops.createItem(named: tooLong, type: .file, inDirectory: root, attributes: FSItem.SetAttributesRequest())
        } == Int(ENAMETOOLONG), "BOM counts in normalized 255-unit name limit")
        check(await status { try await volume.synchronize(flags: .wait) } == 0, "namespace synchronization succeeds")
        check(await volume.teardown() == 0, "namespace writable volume retires")
        check(retained.allSatisfy { $0.0.data == $0.1 }, "all returned literal names own bytes after subsequent operations and retirement")
        let reopened = try ntfs3gVolume(backend: backend(image, writable: false),
            activationBackend: { _, _ in nil }, onContainerStatusChange: { _ in })
        for (parent, key, ino) in persisted {
            check(await status {
                let (found, actual) = try await (reopened as any FSVolume.Operations).lookupItem(named: raw(key), inDirectory: parent)
                check((found as! ntfs3gItem).ino == ino && actual.data == Data(key.decomposedStringWithCanonicalMapping.utf8),
                      "read-only reopen retains literal inode and canonical spelling")
            } == 0, "read-only lookup succeeds")
        }
        check(await reopened.teardown() == 0, "read-only Swift volume retires")
        let native = try backend(image, writable: false)
        var error: Int32 = 0
        guard let reader = nfsk_mount(native.backend, true, &error) else { throw posixError(error) }
        for (ino, expected) in payloads {
            var bytes = Data(count: expected.count + 1)
            let count = bytes.withUnsafeMutableBytes { nfsk_read(reader, ino, 0, $0.baseAddress, Int64($0.count), &error) }
            check(count == expected.count && bytes.prefix(expected.count) == expected, "native readback preserves exact file and neighbor payload/EOF")
        }
        check(nfsk_umount(reader) == 0, "native namespace reader retires")
        native.cleanup(); nfsk_backend_free(native.backend)
        print("NAMESPACE BOM SWIFT SUMMARY: \(checks) checks, \(failures) failures")
        return failures
    }

    static func literalSymlinkTargetTests(_ image: URL) async throws -> Int {
        var checks = 0, failures = 0
        func check(_ ok: Bool, _ message: String) {
            checks += 1
            if !ok { failures += 1; print("FAIL TARGET SWIFT: \(message)") }
        }
        let targets = ["\u{FEFF}", "\u{FEFF}\u{FEFF}", "\u{FEFF}Alpha", "\u{FEFF}\u{FEFF}Alpha",
                       "\u{FEFF}e\u{0301}", "\u{FEFF}" + String(repeating: "각", count: 340),
                       "\u{FEFF}" + String(repeating: "a", count: 1020),
                       String(repeating: "a", count: 1023), "./\u{FEFF}Alpha", "\u{FEFF}😀",
                       String(repeating: "\u{FEFF}", count: 341), "Normal target"]
        let volume = try ntfs3gVolume(backend: backend(image, writable: true),
            activationBackend: { _, _ in nil }, onContainerStatusChange: { _ in })
        let root = ntfs3gItem(ino: NFSK_ROOT_INO, parentIno: NFSK_PARENT_OF_ROOT,
                             name: FSFileName(string: "/"))
        let ops = volume as any FSVolume.Operations
        var retained: [(FSFileName, Data)] = [], created: [(String, Data)] = []
        for (index, target) in targets.enumerated() {
            let name = "SwiftLiteralTarget\(index)", expected = Data(target.decomposedStringWithCanonicalMapping.utf8)
            do {
                let (item, actual) = try await ops.createSymbolicLink(named: FSFileName(string: name),
                    inDirectory: root, attributes: FSItem.SetAttributesRequest(),
                    linkContents: FSFileName(data: Data(target.utf8)))
                check(actual.data == Data(name.utf8), "creation preserves requested basename")
                let first = try await volume.readSymbolicLink(item)
                let second = try await volume.readSymbolicLink(item)
                check(first.data == expected && second.data == expected,
                      "actual callbacks retain every target BOM and complete NFD output")
                retained.append((first, expected)); created.append((name, expected))
                check(true, "valid literal target accepted")
            } catch {
                check(false, "valid literal target \(index) rejected with \((error as NSError).code)")
            }
        }
        for (index, target) in ["\u{FEFF}" + String(repeating: "a", count: 1021),
                                String(repeating: "\u{FEFF}", count: 342)].enumerated() {
            do {
                _ = try await ops.createSymbolicLink(named: FSFileName(string: "SwiftOversizeTarget\(index)"),
                    inDirectory: root, attributes: FSItem.SetAttributesRequest(),
                    linkContents: FSFileName(data: Data(target.utf8)))
                check(false, "native raw UTF8 limit must reject oversized literal target")
            } catch { check((error as NSError).code == Int(ENAMETOOLONG), "oversized target retains native limit error") }
        }
        check(await volume.teardown() == 0, "literal target volume retires cleanly")
        let reader = try ntfs3gVolume(backend: backend(image, writable: false),
            activationBackend: { _, _ in nil }, onContainerStatusChange: { _ in })
        for (name, expected) in created {
            let (item, _) = try await (reader as any FSVolume.Operations).lookupItem(named: FSFileName(string: name), inDirectory: root)
            let target = try await reader.readSymbolicLink(item)
            check(target.data == expected, "read-only reopen preserves the full target contents")
            retained.append((target, expected))
        }
        check(await reader.teardown() == 0, "read-only target reader retires cleanly")
        check(retained.allSatisfy { $0.0.data == $0.1 }, "retained FSFileName targets outlive both volumes")
        print("SYMLINK TARGET SWIFT SUMMARY: \(checks) checks, \(failures) failures")
        return failures
    }

    static func literalVolumeLabelTests(_ image: URL) async throws -> Int {
        var checks = 0, failures = 0
        func check(_ ok: Bool, _ message: String) {
            checks += 1
            if !ok { failures += 1; print("FAIL LABEL SWIFT: \(message)") }
        }
        func status(_ operation: () async throws -> Void) async -> Int {
            do { try await operation(); return 0 } catch { return (error as NSError).code }
        }
        let labels = ["\u{FEFF}", "\u{FEFF}\u{FEFF}", "\u{FEFF}Alpha", "\u{FEFF}\u{FEFF}Alpha",
                      "\u{FEFF}e\u{0301}", String(repeating: "각", count: 127),
                      "\u{FEFF}" + String(repeating: "각", count: 126),
                      String(repeating: "\u{FEFF}", count: 127), "Normal école 😀"]
        var retained: [(FSFileName, Data)] = [], probeNames: [(String, Data)] = []
        var stableID: FSVolume.Identifier?
        for (index, label) in labels.enumerated() {
            let volume = try ntfs3gVolume(backend: backend(image, writable: true),
                activationBackend: { _, _ in nil }, onContainerStatusChange: { _ in })
            if stableID == nil { stableID = volume.volumeID }
            let requested = FSFileName(data: Data(label.utf8))
            let expected = Data(label.decomposedStringWithCanonicalMapping.utf8)
            let renamed = await status {
                let actual = try await volume.setVolumeName(requested)
                check(actual.data == Data(label.utf8) && volume.name.data == Data(label.utf8),
                      "rename reply and live volume retain requested label bytes")
                retained.append((actual, Data(label.utf8)))
            }
            check(renamed == 0, "valid literal or expanded Unicode label is accepted")
            check(volume.volumeID == stableID, "relabel keeps durable volume identity")
            check(await volume.teardown() == 0, "renamed volume retires cleanly")
            let reopened = try ntfs3gVolume(backend: backend(image, writable: false),
                activationBackend: { _, _ in nil }, onContainerStatusChange: { _ in })
            check(reopened.name.data == expected && reopened.volumeID == stableID,
                  "read-only initialization publishes every BOM and complete NFD label")
            retained.append((reopened.name, expected))
            let readonly = await status { _ = try await reopened.setVolumeName(FSFileName(string: "NotAllowed")) }
            check(readonly == Int(EROFS), "literal-label path retains read-only rejection")
            check(await reopened.teardown() == 0, "read-only label volume retires cleanly")
            if #available(macOS 26.0, *) {
                let fs = ntfs3gFileSystem(), resource = FSPathURLResource(url: image, writable: false)
                let result: FSProbeResult = try await withCheckedThrowingContinuation { continuation in
                    fs.probeResource(resource: resource) { result, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let result { continuation.resume(returning: result) }
                        else { continuation.resume(throwing: posixError(EIO)) }
                    }
                }
                check(result.name.map { Data($0.utf8) } == expected && result.containerID != nil,
                      "actual filesystem probe callback publishes the complete literal label")
                if let name = result.name { probeNames.append((name, expected)) }
            }
            print("LABEL SWIFT CASE: index=\(index) rename=\(renamed) expected_bytes=\(expected.count) reopened_bytes=\(reopened.name.data.count)")
        }
        let volume = try ntfs3gVolume(backend: backend(image, writable: true),
            activationBackend: { _, _ in nil }, onContainerStatusChange: { _ in })
        let original = volume.name.data
        check(await status {
            _ = try await volume.setVolumeName(FSFileName(data: Data(("\u{FEFF}" + String(repeating: "L", count: 127)).utf8)))
        } == Int(ENAMETOOLONG), "BOM counts in existing 127-unit setter limit")
        check(await status { _ = try await volume.setVolumeName(FSFileName(data: Data([0xef, 0xbb, 0xbf, 0xff]))) } == Int(EINVAL),
              "invalid raw label UTF8 is rejected")
        for invalid in ["", "bad/name", "bad\nname"] {
            check(await status { _ = try await volume.setVolumeName(FSFileName(string: invalid)) } == Int(EINVAL),
                  "existing label component restrictions remain")
        }
        check(volume.name.data == original, "rejected labels do not change the live name")
        _ = try await volume.setVolumeName(FSFileName(string: "Swift Rename"))
        check(await volume.teardown() == 0, "label controls retire cleanly")
        check(retained.allSatisfy { $0.0.data == $0.1 } && probeNames.allSatisfy { Data($0.0.utf8) == $0.1 },
              "owned callback and probe labels survive later relabels and teardown")
        print("LABEL SWIFT SUMMARY: \(checks) checks, \(failures) failures")
        return failures
    }

    static func main() async throws {
        print("Runtime: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        let image = URL(fileURLWithPath: CommandLine.arguments[1])
        let normal = try ntfs3gVolume(backend: backend(image, writable: true),
                                     activationBackend: { _, _ in nil }, onContainerStatusChange: { _ in })
        _ = try await normal.activate(mountOptions: [])
        try await normal.mount()
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
        let large = Data(repeating: 0x5a, count: Int(NFSK_MAX_XATTR_SIZE))
        try await normal.setXattr(named: xattrName, to: large, on: root, policy: .mustReplace)
        var retained = try await normal.xattr(named: xattrName, of: root)
        let independent = try await normal.xattr(named: xattrName, of: root)
        precondition(retained == large && independent == large)
        retained[0] = 0x11
        precondition(independent == large, "Separate reads must own separate buffers")
        var extras: [FSFileName] = []
        for i in 0..<24 {
            let name = FSFileName(string: "test.\(i)." + String(repeating: "x", count: 100))
            extras.append(name)
            try await normal.setXattr(named: name, to: Data(), on: root, policy: .mustCreate)
        }
        for text in ["test.\u{00e9}", "test.e\u{0301}", "test.中文", "test.emoji😀"] {
            let name = FSFileName(string: text)
            extras.append(name)
            try await normal.setXattr(named: name, to: Data(), on: root, policy: .mustCreate)
        }
        let grownNames = try await normal.xattrs(of: root)
        // Swift String equality folds canonical equivalents; compare UTF-8
        // bytes so composed/decomposed stream names cannot silently coalesce.
        let expectedNames = Set((extras + [xattrName]).map { Data($0.string!.utf8) })
        precondition(Set(grownNames.map { Data($0.string!.utf8) }) == expectedNames &&
                     grownNames.count == expectedNames.count)
        for name in extras { try await normal.setXattr(named: name, to: nil, on: root, policy: .delete) }
        try await normal.setXattr(named: xattrName, to: nil, on: root, policy: .delete)
        do {
            _ = try await normal.xattr(named: xattrName, of: root)
            preconditionFailure("deleted xattr still exists")
        } catch { precondition((error as NSError).code == Int(ENOATTR)) }
        let emptyNames = try await normal.xattrs(of: root)
        precondition(emptyNames.isEmpty)
        await normal.teardown()
        precondition(independent == large && retained[0] == 0x11 && retained.dropFirst() == large.dropFirst())
        precondition(readback == value && names.first?.string == xattrName.string && grownNames.count == extras.count + 1,
                     "Returned xattr values and names must outlive replacement, deletion and teardown")
        print("PASS: owned xattr values, independent mutations, grown lists and post-teardown lifetime")
        print("PASS: FSKit free-space fields and OS-specific open-file lifetime selection")
        print("PASS: signed 64-bit size limits and native FSKit xattr create/read/list/replace/delete")

        try await featureTests(image)
        try await directoryTests(image)
        try await canonicalNameTests(image)
        if try await ignoredNonFileSizeTests(image) != 0 { exit(1) }
        if try await ignoredBackupTimeTests(image) != 0 { exit(1) }
        if try await bomXattrTests(image) != 0 { exit(1) }
        if try await bomNamespaceTests(image) != 0 { exit(1) }
        if try await literalVolumeLabelTests(image) != 0 { exit(1) }
        if try await literalSymlinkTargetTests(image) != 0 { exit(1) }

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
        _ = try await fallback.activate(mountOptions: [])
        if #available(macOS 26.4, *) {
            precondition(fallback.requestedMountOptions.contains(.readOnly))
            try await fallback.mount()
        } else {
            try await expect(EROFS) { try await fallback.mount() }
            try await expect(EROFS) {
                _ = try await (fallback as any FSVolume.Operations).createItem(named: FSFileName(string: "MustNotCreate"), type: .file,
                    inDirectory: root, attributes: FSItem.SetAttributesRequest())
            }
        }
        let (item, name) = try await (fallback as any FSVolume.Operations).lookupItem(named: FSFileName(string: "volumemixed.txt"), inDirectory: root)
        precondition((item as? ntfs3gItem)?.ino == mixed && name.string == "VolumeMiXeD.txt")
        await fallback.teardown()
        print("PASS: OS-specific read-only fallback guard and canonical lookup")
    }
}
