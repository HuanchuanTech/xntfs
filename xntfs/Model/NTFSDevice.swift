//
//  NTFSDevice.swift
//  A removable / image-backed NTFS volume the app knows about.
//

import Foundation

enum DeviceKind: Equatable {
    case removable        // physical disk (USB, SD, etc.)
    case diskImage        // attached raw NTFS image file
    case fixed            // internal / non-removable
}

enum MountState: Equatable {
    case unmounted
    case mounting
    case mounted(URL)              // current mount point
    case unmounting
    case failed(String)            // last error message

    var isMounted: Bool { if case .mounted = self { return true }; return false }
    var mountPoint: URL? { if case .mounted(let u) = self { return u }; return nil }
}

enum MountDriver: Equatable {
    case xntfs
    case system
    case other(String)
    case unknown

    init(fileSystemType: String?) {
        switch fileSystemType?.lowercased() {
        case "xntfs": self = .xntfs
        case "ntfs": self = .system
        case nil, "": self = .unknown
        case let name?: self = .other(name)
        }
    }
}

/// One NTFS volume/partition. Identified by its BSD name (e.g. `disk4s1`).
struct NTFSDevice: Identifiable, Equatable {
    let id: String                 // BSD name, e.g. "disk4s1"
    var volumeName: String         // on-disk label or fallback
    var sizeBytes: UInt64
    var kind: DeviceKind
    var contentHint: String        // DiskArbitration media content (e.g. "Windows_NTFS")
    var isRemovable: Bool
    var devicePath: String         // "/dev/disk4s1"
    var state: MountState = .unmounted
    /// Actual statfs type, not Disk Arbitration's format hint or extension enablement.
    /// nil means that the current driver could not be determined.
    var mountedFileSystemType: String?
    /// True when the mounted volume is read-only (statfs MNT_RDONLY).
    var readOnly: Bool = false
    /// Whether the underlying media is writable (DAMediaWritable). When false the volume
    /// can only be mounted read-only — e.g. an image attached with `hdiutil attach -readonly`.
    var mediaWritable: Bool = true
    /// For image-backed devices (kind == .diskImage): the whole-disk node (e.g. "disk6"),
    /// used to detach the image via `hdiutil detach`.
    var wholeDiskBSD: String = ""
    /// Changes on reconnect, even when Disk Arbitration reuses the BSD name.
    var registryEntryID: UInt64?

    var displayName: String { volumeName.isEmpty ? id : volumeName }

    var mountDriver: MountDriver {
        state.isMounted ? MountDriver(fileSystemType: mountedFileSystemType) : .unknown
    }

    var mountedByXntfs: Bool { mountDriver == .xntfs }

    var needsXntfsMountGuidance: Bool { mountDriver == .system && readOnly }

    static func == (lhs: NTFSDevice, rhs: NTFSDevice) -> Bool {
        lhs.id == rhs.id && lhs.volumeName == rhs.volumeName &&
        lhs.state == rhs.state && lhs.sizeBytes == rhs.sizeBytes && lhs.kind == rhs.kind &&
        lhs.mountedFileSystemType == rhs.mountedFileSystemType && lhs.readOnly == rhs.readOnly &&
        lhs.mediaWritable == rhs.mediaWritable && lhs.registryEntryID == rhs.registryEntryID
    }
}

extension UInt64 {
    var humanSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file)
    }
}
