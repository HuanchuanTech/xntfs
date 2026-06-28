//
//  AppSettings.swift
//  Per-scenario read-only mount preferences, stored in the App Group container shared
//  with the file-system extension (which reads them when it auto-mounts a volume).
//  `true` == mount read-only. Drives default to read/write, disk images to read-only.
//

import Foundation
import Observation

@Observable
final class AppSettings {
    /// App Group shared with the ntfs3g extension (both targets carry the entitlement).
    /// macOS requires third-party group container identifiers to use the Team ID prefix.
    static let appGroupID = "529LJDH392.group.com.huanchuan.xntfs"
    static let deviceReadOnlyKey = "deviceReadOnly"
    static let imageReadOnlyKey  = "imageReadOnly"

    private let shared = UserDefaults(suiteName: AppSettings.appGroupID)

    /// Read-only access for disk drives. Default off (read/write).
    var deviceReadOnly: Bool { didSet { Self.persist(deviceReadOnly, forKey: AppSettings.deviceReadOnlyKey, defaults: shared) } }
    /// Read-only access for disk images. Default on (read-only).
    var imageReadOnly: Bool { didSet { Self.persist(imageReadOnly, forKey: AppSettings.imageReadOnlyKey, defaults: shared) } }

    init() {
        let deviceValue = shared?.object(forKey: AppSettings.deviceReadOnlyKey) as? Bool
        let imageValue = shared?.object(forKey: AppSettings.imageReadOnlyKey) as? Bool
        self.deviceReadOnly = deviceValue ?? false
        self.imageReadOnly = imageValue ?? true
        if deviceValue == nil { Self.persist(deviceReadOnly, forKey: AppSettings.deviceReadOnlyKey, defaults: shared) }
        if imageValue == nil { Self.persist(imageReadOnly, forKey: AppSettings.imageReadOnlyKey, defaults: shared) }
    }

    private static func persist(_ value: Bool, forKey key: String, defaults: UserDefaults?) {
        defaults?.set(value, forKey: key)
        defaults?.synchronize()
    }
}
