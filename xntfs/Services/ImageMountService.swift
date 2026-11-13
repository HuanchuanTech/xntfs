import Foundation
import FSKit

nonisolated struct MountedImage: Identifiable, Equatable, Sendable {
    let mountPoint: URL
    let source: URL
    let readOnly: Bool
    let sizeBytes: UInt64
    let fileSystemID: [Int32]

    var id: String { "image:" + mountPoint.path }
    var name: String { mountPoint.lastPathComponent }

    func isSameMount(as other: MountedImage) -> Bool {
        mountPoint == other.mountPoint && source == other.source && fileSystemID == other.fileSystemID
    }
}

nonisolated enum ImageMountError: LocalizedError {
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

// Filesystem operations run on the preflight queue. Keep permission ownership
// independent of the MainActor client so it survives cancellation and awaits.
nonisolated struct ImageMountFileAccess: Sendable {
    var start: @Sendable (URL) -> Bool
    var stop: @Sendable (URL) -> Void
    var scopedURL: @Sendable (URL, Bool) throws -> URL

    static let live = Self(
        start: { $0.startAccessingSecurityScopedResource() },
        stop: { $0.stopAccessingSecurityScopedResource() },
        scopedURL: { source, readOnly in
            var options: URL.BookmarkCreationOptions = [.withSecurityScope]
            if readOnly { options.insert(.securityScopeAllowOnlyReadAccess) }
            let bookmark = try source.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
            var stale = false
            return try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                           relativeTo: nil, bookmarkDataIsStale: &stale)
        })
}

nonisolated private final class ImageMountScope: Sendable {
    let url: URL
    private let access: ImageMountFileAccess
    private let acquired: Bool

    init(_ url: URL, access: ImageMountFileAccess) {
        self.url = url
        self.access = access
        acquired = access.start(url)
    }

    deinit { if acquired { access.stop(url) } }
}

@available(macOS 27.0, *)
@MainActor
struct ImageMountClient {
    var images: () throws -> [MountedImage]
    var enabled: () async throws -> Bool
    var submit: (URL, Bool) async throws -> URL

    static var live: Self {
        Self(images: { try ImageMountService.queryMountedImages() }, enabled: {
            try await FSClient.shared.installedExtensions.contains {
                $0.bundleIdentifier == ExtensionStatus.bundleID && $0.isEnabled
            }
        }, submit: { url, readOnly in
            // FSKit forwards this scope to the extension until unload.
            let resource = FSPathURLResource(url: url, writable: !readOnly)
            return try await FSClient.shared.mountSingleVolume(
                resource: resource, bundleID: ExtensionStatus.bundleID,
                options: ["-o", readOnly ? "rdonly" : "rw"])
        })
    }
}

@MainActor
enum ImageMountService {
    private static var mounting = false
    nonisolated private static let preflightQueue = DispatchQueue(label: "com.huanchuan.xntfs.image-preflight", qos: .userInitiated)

    nonisolated private static func preflight<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            preflightQueue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    @available(macOS 27.0, *)
    static func mount(_ source: URL, readOnly: Bool, client: ImageMountClient? = nil,
                      fileAccess: ImageMountFileAccess = .live) async throws -> URL {
        try Task.checkCancellation()
        guard !mounting else { throw POSIXError(.EBUSY) }
        mounting = true
        defer { mounting = false }
        let client = client ?? .live

        let (sourceScope, canonicalSource) = try await preflight {
            let scope = ImageMountScope(source, access: fileAccess)
            return (scope, try validatedImageURL(source))
        }
        defer { withExtendedLifetime(sourceScope) {} }
        try Task.checkCancellation()
        // Take the cached snapshot after the potentially slow source read.
        let before = try client.images()
        if !before.isEmpty {
            try await preflight {
                guard !before.contains(where: { $0.source.resolvingSymlinksInPath().standardizedFileURL == canonicalSource }) else {
                    throw ImageMountError.alreadyMounted
                }
            }
        }
        try Task.checkCancellation()
        guard try await client.enabled() else {
            throw ImageMountError.extensionUnavailable
        }
        try Task.checkCancellation()
        let scoped = try await preflight {
            ImageMountScope(try fileAccess.scopedURL(sourceScope.url, readOnly), access: fileAccess)
        }
        defer { withExtendedLifetime(scoped) {} }
        try Task.checkCancellation()
        // Once submitted, cancellation cannot undo a mount. Finish its reply and
        // verify it rather than abandoning a potentially successful OS operation.
        let mounted = try await client.submit(scoped.url, readOnly)
        guard !before.contains(where: { $0.mountPoint == mounted }) else {
            throw ImageMountError.alreadyMounted
        }
        guard try client.images().contains(where: { $0.mountPoint == mounted }) else {
            throw ImageMountError.unexpectedMount
        }
        return mounted
    }

    nonisolated static func validateImage(_ source: URL) throws {
        _ = try validatedImageURL(source)
    }

    nonisolated private static func validatedImageURL(_ source: URL) throws -> URL {
        guard source.isFileURL else { throw ImageMountError.unsupportedImage }
        let canonical = source.resolvingSymlinksInPath().standardizedFileURL
        guard try canonical.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw ImageMountError.unsupportedImage
        }
        let file = try FileHandle(forReadingFrom: source)
        defer { try? file.close() }
        let boot = try file.read(upToCount: 512) ?? Data()
        guard boot.count == 512, boot[3..<11] == Data("NTFS    ".utf8),
              boot[510] == 0x55, boot[511] == 0xaa else {
            throw ImageMountError.unsupportedImage
        }
        return canonical
    }

    // Path-backed FSKit mounts have no BSD disk and are absent from Disk Arbitration.
    // Read the mount table so they also survive app restarts and Finder unmounts.
    static func mountedImages() -> [MountedImage] {
        (try? queryMountedImages()) ?? []
    }

    static func queryMountedImages() throws -> [MountedImage] {
        mountedImages(in: try DiskArbitrationMonitor.queryMountTable())
    }

    static func mountedImages(in entries: [statfs]) -> [MountedImage] {
        entries.compactMap { entry in
            guard string(entry.f_fstypename) == DiskArbitrationMonitor.moduleFSType,
                  let source = URL(string: string(entry.f_mntfromname)), source.isFileURL else { return nil }
            let path = string(entry.f_mntonname)
            // Cached capacity can initially be zero. Keep the mount visible;
            // never fall back to blocking filesystem I/O for a display query.
            return MountedImage(mountPoint: URL(fileURLWithPath: path, isDirectory: true),
                                source: source,
                                readOnly: entry.f_flags & UInt32(MNT_RDONLY) != 0,
                                sizeBytes: entry.f_blocks * UInt64(entry.f_bsize),
                                fileSystemID: [entry.f_fsid.val.0, entry.f_fsid.val.1])
        }.sorted { $0.mountPoint.path < $1.mountPoint.path }
    }

    static func unmount(_ image: MountedImage) async throws {
        guard try queryMountedImages().contains(where: { $0.isSameMount(as: image) }) else { return }
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
