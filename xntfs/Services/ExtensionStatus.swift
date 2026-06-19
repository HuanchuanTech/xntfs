//
//  ExtensionStatus.swift
//  Detects whether our FSKit file-system extension is installed and enabled,
//  and deep-links the user to the System Settings pane to enable it.
//
//  macOS requires the user to enable a file-system extension themselves; an app
//  can't do it programmatically. We can only detect the state and guide them.
//

import Foundation
import FSKit
import AppKit
import Observation

@MainActor
@Observable
final class ExtensionStatus {
    enum State: Equatable { case unknown, notInstalled, disabled, enabled }

    private(set) var state: State = .unknown

    /// Must match the extension target's bundle identifier.
    private let bundleID = "com.huanchuan.xntfs.ntfs3g"

    func refresh() async {
        do {
            let modules = try await FSClient.shared.installedExtensions
            if let mine = modules.first(where: { $0.bundleIdentifier == bundleID }) {
                state = mine.isEnabled ? .enabled : .disabled
            } else {
                state = .notInstalled
            }
        } catch {
            state = .unknown
        }
    }

    /// Opens System Settings at "Login Items & Extensions", where the
    /// "File System Extensions" toggle lives. Returns whether a pane opened.
    @discardableResult
    static func openSettings() -> Bool {
        // macOS 27 ships an official jump straight to File System Extensions.
        if #available(macOS 27.0, *) {
            if FSClient.shared.openFileSystemExtensionsSettings() { return true }
        }
        // Pre-27 there is no anchor for the File System Extensions detail (the pane only
        // exposes "ExtensionItems"/"startupItemsPref"), so just open the Login Items &
        // Extensions page; the banner covers the remaining steps.
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            return NSWorkspace.shared.open(url)
        }
        return false
    }
}
