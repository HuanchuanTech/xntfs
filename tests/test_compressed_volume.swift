import Foundation
import FSKit

// Called only with a disposable regular-file image prepared by the compressed runner.
@main
struct CompressedVolumeTests {
    static func main() async throws {
        precondition(CommandLine.arguments.count == 3 || CommandLine.arguments.count == 5)
        let path = CommandLine.arguments[1]
        let mode = CommandLine.arguments[2]
        let legacy = mode.hasPrefix("legacy")
        var error: Int32 = 0
        guard let pointer = nfsk_backend_from_file(path, 1, &error) else { throw posixError(error) }
        let backend = NTFSBackend(backend: pointer, retain: nil, cleanup: {}, writable: true)
        let volume = try ntfs3gVolume(backend: backend, activationBackend: { _, _ in nil },
                                    onContainerStatusChange: { _ in }, legacyOpenUnlink: legacy)
        let root = ntfs3gItem(ino: NFSK_ROOT_INO, parentIno: NFSK_PARENT_OF_ROOT, name: FSFileName(string: "/"))
        let fileName = CommandLine.arguments.count == 5 ? CommandLine.arguments[3] : "High"
        let name = FSFileName(string: fileName)
        let (item, _) = try await (volume as any FSVolume.Operations).lookupItem(named: name, inDirectory: root)
        let request = FSItem.GetAttributesRequest()
        request.wantedAttributes = [.size, .allocSize, .linkCount]
        let original = try await volume.attributes(request, of: item)
        precondition(original.size <= 4 * 65536)
        if mode != "sync" && mode != "unmount" { try await volume.openItem(item, modes: [.read, .write]) }
        for index in 0..<7 {
            let count = try await volume.write(contents: Data(repeating: 82, count: 100), to: item,
                                               at: off_t(original.size) + off_t(index * 100))
            precondition(count == 100)
        }
        let pending = try await volume.attributes(request, of: item)
        precondition(pending.size == original.size + 700)
        // The known unfinalized Empty transition can report zero compressed_size
        // despite allocated clusters. Check its exact allocation after finalization.
        precondition((fileName == "Empty" && original.size == 0) || pending.allocSize > original.allocSize)
        let expectedAllocation: UInt64
        if CommandLine.arguments.count == 5 {
            let expected = CommandLine.arguments[4]
            expectedAllocation = expected == "pending" ? pending.allocSize : UInt64(expected)!
        } else {
            // Keep the original full-finalization acceptance mode unchanged.
            precondition(original.size == 196731)
            expectedAllocation = original.allocSize
        }
        if mode == "legacy-unlink" {
            try await volume.removeItem(item, named: name, fromDirectory: root)
            let deleted = try await volume.attributes(request, of: item)
            precondition(deleted.linkCount == 0 && deleted.allocSize == expectedAllocation)
            let count = try await volume.write(contents: Data(repeating: 83, count: 100), to: item,
                                               at: off_t(pending.size))
            precondition(count == 100)
            try await volume.closeItem(item, modes: [])
            do {
                _ = try await volume.attributes(request, of: item)
                preconditionFailure("open-unlink record survived final close")
            } catch { precondition((error as NSError).code == Int(ENOENT)) }
        } else if mode == "unmount" {
            // Teardown itself must finish the pending file without an explicit close/sync.
            let result = await volume.teardown()
            precondition(result == 0)
        } else {
            if mode == "reclaim" {
                try await volume.reclaimItem(item)
                let afterReclaim = try await volume.attributes(request, of: item)
                if afterReclaim.allocSize == pending.allocSize && expectedAllocation != pending.allocSize {
                    // An ordinary-file harness has no kernel reference handoff.
                    // A refused tryReclaim must leave the pending work for sync.
                    precondition(ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27)
                    print("NOT RUN: successful SDK tryReclaim; local SDK deferred cleanup, checking later sync")
                    try await volume.synchronize(flags: .wait)
                }
            } else if mode == "sync" {
                try await volume.synchronize(flags: .wait)
            } else {
                // Retained modes and stale objects must not finalize someone else's file.
                try await volume.closeItem(item, modes: [.read])
                let stale = ntfs3gItem(ino: (item as! ntfs3gItem).ino, parentIno: NFSK_ROOT_INO,
                                      name: FSFileName(string: "stale"))
                try await volume.closeItem(stale, modes: [])
                let stillPending = try await volume.attributes(request, of: item)
                precondition(stillPending.allocSize == pending.allocSize)
                try await volume.closeItem(item, modes: [])
                try await volume.closeItem(item, modes: [])
            }
            let finalized = try await volume.attributes(request, of: item)
            precondition(finalized.size == pending.size && finalized.allocSize == expectedAllocation)
        }
        if mode != "unmount" {
            let result = await volume.teardown()
            precondition(result == 0)
        }
        print("PASS: compressed Swift \(fileName) \(mode), expected allocation \(expectedAllocation)")
    }
}
