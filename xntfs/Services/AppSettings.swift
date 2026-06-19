//
//  AppSettings.swift
//  User-configurable settings. NTFS drives auto-mount via the system + the
//  file-system extension, so the app only needs a couple of manual-mount prefs.
//

import Foundation
import Observation

@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    /// Mount drives read-only when the user mounts them manually from the app.
    var defaultReadOnly: Bool { didSet { defaults.set(defaultReadOnly, forKey: Keys.readOnly) } }

    init() {
        self.defaultReadOnly = defaults.object(forKey: Keys.readOnly) as? Bool ?? false
    }

    private enum Keys {
        static let readOnly = "defaultReadOnly"
    }
}
