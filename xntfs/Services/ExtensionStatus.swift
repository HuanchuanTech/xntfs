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
    /// Resolved filesystem paths of ALL matching registrations (FSModuleIdentity.url).
    /// More than one means duplicate registrations — a known cause of the greyed-out toggle.
    private(set) var moduleURLs: [URL] = []
    /// Count of installed identities matching our bundle id, tracked separately so a
    /// duplicate is detectable even when a url can't be read.
    private(set) var installedCount = 0

    /// Must match the extension target's bundle identifier.
    private let bundleID = "com.huanchuan.xntfs.ntfs3g"

    var isInstalled: Bool { installedCount > 0 }
    var isDuplicated: Bool { installedCount > 1 }

    /// Registration health: nil = unknown (no readable paths), false = a problem (duplicate
    /// registrations, or a copy served from a dev build), true = a single /Applications copy.
    var registrationOK: Bool? {
        if isDuplicated { return false }
        guard !moduleURLs.isEmpty else { return nil }
        return moduleURLs.allSatisfy(Self.isProperLocation)
    }
    private static func isProperLocation(_ url: URL) -> Bool {
        let p = url.path
        if p.contains("/DerivedData/") || p.contains("/Build/Products/") { return false }
        return p.hasPrefix("/Applications/")
    }

    /// Copyable command to inspect ALL registrations + their resolved paths by hand.
    var pluginkitCommand: String { "pluginkit -mAvvv -i \(bundleID)" }

    /// Last-resort, UNSUPPORTED workaround for the pre-27 bug where the System Settings
    /// toggle is a no-op. enabledModules.plist has an ARRAY root (a list of enabled bundle
    /// ids). This bails out if the file is missing or its root is NOT an array (so it can
    /// never corrupt it — `defaults write`, or `Add :0` on a non-array, would wrongly produce
    /// a dict), and otherwise adds ours at the front of the array (`Add :0`; position is
    /// irrelevant for an enabled set) only if absent, then restarts fskit_agent so it
    /// re-reads. PlistBuddy is always present, no Command Line Tools needed.
    var enableFallbackScript: String {
        """
        PLIST="$HOME/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist"
        BID="\(bundleID)"
        if [ ! -f "$PLIST" ]; then echo "enabledModules.plist not found — toggle a File System Extension once in System Settings to create it, then re-run."; exit 1; fi
        if ! /usr/libexec/PlistBuddy -c "Print" "$PLIST" | head -1 | grep -q "Array"; then echo "Root is not an array (likely written by an older script); refusing to modify to avoid corrupting it. Repair it or restore a backup, then re-run."; exit 1; fi
        /usr/libexec/PlistBuddy -c "Print" "$PLIST" | grep -qF "$BID" || /usr/libexec/PlistBuddy -c "Add :0 string $BID" "$PLIST"
        pkill -9 fskit_agent
        """
    }

    func refresh() async {
        do {
            let modules = try await FSClient.shared.installedExtensions
            // filter (not first) so duplicate registrations are all surfaced.
            let mine = modules.filter { $0.bundleIdentifier == bundleID }
            installedCount = mine.count
            // FSModuleIdentity.url — used only to flag stale/dev-build registrations.
            // VERIFY ON DEVICE: confirm this property exists/populates in your SDK; if not,
            // drop this line (moduleURLs stays empty → the pluginkit command fallback shows).
            moduleURLs = mine.compactMap { $0.url }
            if mine.isEmpty {
                state = .notInstalled
            } else {
                state = mine.contains { $0.isEnabled } ? .enabled : .disabled
            }
        } catch {
            state = .unknown
            installedCount = 0
            moduleURLs = []
        }
    }

    /// Opens System Settings at "Login Items & Extensions", where the
    /// "File System Extensions" toggle lives. Returns whether a pane opened.
    @discardableResult
    static func openSettings() -> Bool {
        // macOS 27 ships an official jump straight to File System Extensions, but
        // FSClient.openFileSystemExtensionsSettings() isn't in the stable SDK. Re-enable when
        // building against the macOS 27 SDK (out of beta):
        // if #available(macOS 27.0, *) {
        //     if FSClient.shared.openFileSystemExtensionsSettings() { return true }
        // }
        // Without that anchor for the File System Extensions detail (the pane only
        // exposes "ExtensionItems"/"startupItemsPref"), so just open the Login Items &
        // Extensions page; the banner covers the remaining steps.
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            return NSWorkspace.shared.open(url)
        }
        return false
    }
}
