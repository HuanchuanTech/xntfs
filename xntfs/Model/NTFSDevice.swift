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
    /// For disk-image devices: the source image file URL (so we can detach later).
    var imageSourceURL: URL? = nil

    var displayName: String { volumeName.isEmpty ? id : volumeName }

    static func == (lhs: NTFSDevice, rhs: NTFSDevice) -> Bool {
        lhs.id == rhs.id && lhs.volumeName == rhs.volumeName &&
        lhs.state == rhs.state && lhs.sizeBytes == rhs.sizeBytes
    }
}

extension UInt64 {
    var humanSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file)
    }
}
