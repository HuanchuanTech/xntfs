import Foundation
import FSKit

struct MountedImage: Identifiable, Equatable {
    let mountPoint: URL
    let source: URL
    let readOnly: Bool
    let sizeBytes: UInt64
    let fileSystemID: [Int32]

    var id: String { "image:" + mountPoint.path }
    var name: String { mountPoint.lastPathComponent }
}

enum ImageMountError: LocalizedError {
    case unsupportedImage
    case extensionUnavailable
    case alreadyMounted
    case unexpectedMount

    var errorDescription: String? {
        switch self {
        case .unsupportedImage:
            return String(localized: "Select a raw NTFS volume image. Open partitioned or compressed disk images in Disk Utility.")
        case .extensionUnavailable:
            return String(localized: "Enable ntfs3g in File System Extensions before mounting an image.")
        case .alreadyMounted:
            return String(localized: "This image is already mounted. Eject it before changing its access mode.")
        case .unexpectedMount:
            return String(localized: "The system did not return an xntfs image mount. Refresh the volume list and check Diagnostics.")
        }
    }
}

@MainActor
enum ImageMountService {
    @available(macOS 27.0, *)
    static func mount(_ source: URL, readOnly: Bool) async throws -> URL {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        try validateImage(source)
        let before = mountedImages()
        let canonicalSource = source.resolvingSymlinksInPath().standardizedFileURL
        guard !before.contains(where: { $0.source.resolvingSymlinksInPath().standardizedFileURL == canonicalSource }) else {
            throw ImageMountError.alreadyMounted
        }
        let modules = try await FSClient.shared.installedExtensions
        guard modules.contains(where: { $0.bundleIdentifier == ExtensionStatus.bundleID && $0.isEnabled }) else {
            throw ImageMountError.extensionUnavailable
        }

        // FSKit forwards this scope to the extension, which holds it until unload.
        var options: URL.BookmarkCreationOptions = [.withSecurityScope]
        if readOnly { options.insert(.securityScopeAllowOnlyReadAccess) }
        let bookmark = try source.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
        var stale = false
        let scoped = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                             relativeTo: nil, bookmarkDataIsStale: &stale)
        let scopedAccess = scoped.startAccessingSecurityScopedResource()
        defer { if scopedAccess { scoped.stopAccessingSecurityScopedResource() } }
        let resource = FSPathURLResource(url: scoped, writable: !readOnly)
        let mounted = try await FSClient.shared.mountSingleVolume(
            resource: resource, bundleID: ExtensionStatus.bundleID,
            options: ["-o", readOnly ? "rdonly" : "rw"])
        guard !before.contains(where: { $0.mountPoint == mounted }) else {
            throw ImageMountError.alreadyMounted
        }
        guard mountedImages().contains(where: { $0.mountPoint == mounted }) else {
            throw ImageMountError.unexpectedMount
        }
        return mounted
    }

    static func validateImage(_ source: URL) throws {
        guard source.isFileURL,
              try source.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw ImageMountError.unsupportedImage
        }
        let file = try FileHandle(forReadingFrom: source)
        defer { try? file.close() }
        let boot = try file.read(upToCount: 512) ?? Data()
        guard boot.count == 512, boot[3..<11] == Data("NTFS    ".utf8),
              boot[510] == 0x55, boot[511] == 0xaa else {
            throw ImageMountError.unsupportedImage
        }
    }

    // Path-backed FSKit mounts have no BSD disk and are absent from Disk Arbitration.
    // Read the mount table so they also survive app restarts and Finder unmounts.
    static func mountedImages() -> [MountedImage] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }
        defer { free(buffer) }
        return (0..<Int(count)).compactMap { index in
            var entry = buffer[index]
            guard string(entry.f_fstypename) == DiskArbitrationMonitor.moduleFSType,
                  let source = URL(string: string(entry.f_mntfromname)), source.isFileURL else { return nil }
            let path = string(entry.f_mntonname)
            // A new mount's cached block counts can still be zero with MNT_NOWAIT.
            guard statfs(path, &entry) == 0,
                  string(entry.f_fstypename) == DiskArbitrationMonitor.moduleFSType,
                  URL(string: string(entry.f_mntfromname)) == source else { return nil }
            return MountedImage(mountPoint: URL(fileURLWithPath: path),
                                source: source,
                                readOnly: entry.f_flags & UInt32(MNT_RDONLY) != 0,
                                sizeBytes: entry.f_blocks * UInt64(entry.f_bsize),
                                fileSystemID: [entry.f_fsid.val.0, entry.f_fsid.val.1])
        }.sorted { $0.mountPoint.path < $1.mountPoint.path }
    }

    static func unmount(_ image: MountedImage) async throws {
        guard mountedImages().contains(image) else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            FileManager.default.unmountVolume(at: image.mountPoint, options: .withoutUI) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    static func diagnosticMessage(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(error.localizedDescription)\n\(nsError.domain) (\(nsError.code))"
    }

    private static func string<T>(_ field: T) -> String {
        withUnsafeBytes(of: field) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
