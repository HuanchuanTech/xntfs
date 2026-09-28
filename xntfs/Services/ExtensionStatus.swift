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
    enum State: Equatable { case unknown, bundled, notInstalled, disabled, enabled }

    static var needsLegacyCompatibility: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15
    }

    static var supportsEnableWorkaround: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26
    }

    private(set) var state: State = .unknown
    private(set) var queryError: NSError?
    /// Resolved filesystem paths of ALL matching registrations (FSModuleIdentity.url).
    /// More than one means duplicate registrations — a known cause of the greyed-out toggle.
    private(set) var moduleURLs: [URL] = []
    /// Count of installed identities matching our bundle id, tracked separately so a
    /// duplicate is detectable even when a url can't be read.
    private(set) var installedCount = 0
    /// Bundle presence is not proof of registration or enablement on macOS 15.
    private(set) var bundledExtensionURL: URL?

    /// Must match the extension target's bundle identifier.
    static let bundleID = "com.huanchuan.xntfs.ntfs3g"

    var isInstalled: Bool { installedCount > 0 }
    var isDuplicated: Bool { installedCount > 1 }
    var isEnabled: Bool? {
        switch state {
        case .enabled: return true
        case .disabled: return false
        default: return nil
        }
    }

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
    var pluginkitCommand: String { "pluginkit -mAvvv -i \(Self.bundleID)" }

    var diagnosticReport: String {
        let app = Bundle.main
        let version = app.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = app.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let count = state == .unknown || Self.needsLegacyCompatibility ? "unknown" : String(installedCount)
        var lines = [
            "xntfs \(version) (\(build))",
            "OS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "App: \(app.bundleURL.path)",
            "Module: \(Self.bundleID)",
            "State: \(state)",
            "Bundled extension: \(bundledExtensionURL?.path ?? "not found")",
            "Registered copies: \(count)"
        ]
        lines.append(contentsOf: moduleURLs.map { "Registration: \($0.path)" })
        if let queryError {
            lines.append("FSClient.installedExtensions: \(queryError.domain) (\(queryError.code)): \(queryError.localizedDescription)")
        }
        return lines.joined(separator: "\n")
    }

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
        BID="\(Self.bundleID)"
        if [ ! -f "$PLIST" ]; then echo "enabledModules.plist not found — toggle a File System Extension once in System Settings to create it, then re-run."; exit 1; fi
        if ! /usr/libexec/PlistBuddy -c "Print" "$PLIST" | head -1 | grep -q "Array"; then echo "Root is not an array (likely written by an older script); refusing to modify to avoid corrupting it. Repair it or restore a backup, then re-run."; exit 1; fi
        /usr/libexec/PlistBuddy -c "Print" "$PLIST" | grep -qF "$BID" || /usr/libexec/PlistBuddy -c "Add :0 string $BID" "$PLIST"
        pkill -9 fskit_agent
        """
    }

    func refresh(appURL: URL = Bundle.main.bundleURL) async {
        queryError = nil
        bundledExtensionURL = Self.embeddedExtension(in: appURL)
        if Self.needsLegacyCompatibility {
            installedCount = 0
            moduleURLs = []
            state = bundledExtensionURL == nil ? .notInstalled : .bundled
            return
        }
        do {
            let modules = try await FSClient.shared.installedExtensions
            // filter (not first) so duplicate registrations are all surfaced.
            let mine = modules.filter { $0.bundleIdentifier == Self.bundleID }
            installedCount = mine.count
            moduleURLs = mine.compactMap { $0.url }
            if mine.isEmpty {
                state = .notInstalled
            } else {
                state = mine.contains { $0.isEnabled } ? .enabled : .disabled
            }
        } catch {
            queryError = error as NSError
            state = .unknown
            installedCount = 0
            moduleURLs = []
        }
    }

    static func embeddedExtension(in appURL: URL) -> URL? {
        let url = appURL.appendingPathComponent("Contents/Extensions/ntfs3g.appex", isDirectory: true)
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleID,
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty, !executable.contains("/"), executable != ".", executable != "..",
              FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS/\(executable)").path)
        else { return nil }
        return url
    }

    /// Opens File System Extensions on macOS 27, or its parent settings pane.
    @discardableResult
    static func openSettings() -> Bool {
        if #available(macOS 27.0, *) {
            if FSClient.shared.openFileSystemExtensionsSettings() { return true }
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            return NSWorkspace.shared.open(url)
        }
        return false
    }
}
