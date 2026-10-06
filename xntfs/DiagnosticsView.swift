//
//  DiagnosticsView.swift
//  Explains why the FSKit extension may not be working and how to fix it.
//
//  Everything here is sandbox-safe: registration comes from FSClient on macOS 26+;
//  macOS 15 can only confirm the bundled extension. Anything the sandbox can't do — the pre-27 force-enable
//  workaround, inspecting the resolved install path — is offered as a copyable
//  Terminal command for the user to run, never executed by the app.
//

import SwiftUI
import AppKit

struct DiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let status: ExtensionStatus
    /// Set once the user has been sent to System Settings; combined with a still-disabled
    /// state after returning (re-checked on scenePhase change) it reveals the fallback.
    @State private var visitedSettings = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Extension Diagnostics").font(.title2).bold()
                Spacer()
                Button { Task { await status.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Re-check")
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    installedCheck
                    Divider()
                    enabledCheck
                    if status.isInstalled || status.bundledExtensionURL != nil {
                        Divider()
                        registrationCheck
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(status.diagnosticReport, forType: .string)
                } label: {
                    Label("Copy Diagnostics", systemImage: "doc.on.doc")
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 440, idealHeight: 560)
        .task { await status.refresh() }
        .onChange(of: scenePhase) { _, phase in
            // Re-check when the user comes back from System Settings.
            if phase == .active { Task { await status.refresh() } }
        }
    }

    // MARK: checks

    private var installedCheck: some View {
        CheckRow(ok: status.state == .bundled ? true : (status.state == .unknown ? nil : status.isInstalled),
                 title: ExtensionStatus.needsLegacyCompatibility ? "Extension in this app" : "Extension installed",
                 detail: installationDetail) {
            if let error = status.queryError {
                Text(verbatim: "\(error.domain) (\(error.code)): \(error.localizedDescription)")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    private var installationDetail: LocalizedStringKey {
        if status.state == .bundled {
            return "ntfs3g is included in this app. macOS 15 cannot reliably report third-party FSKit registration or enablement to the app."
        }
        if status.isInstalled { return "ntfs3g is registered with the system." }
        if status.state == .unknown { return "Couldn't query FSKit — try Re-check." }
        return "Not found. Run the app from Xcode once, or install it to /Applications."
    }

    private var enabledCheck: some View {
        CheckRow(ok: status.isEnabled,
                 title: "Extension enabled",
                 detail: enablementDetail) {
            if status.state == .disabled || status.state == .bundled {
                VStack(alignment: .leading, spacing: 12) {
                    ExtensionEnablementInstructions()
                    Button("Open Settings…") {
                        visitedSettings = ExtensionStatus.openSettings()
                    }
                    if ExtensionStatus.supportsEnableWorkaround && visitedSettings && status.state == .disabled {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Still off after toggling? On macOS 26 the File System Extensions switch can be a no-op (a known system bug). As a last resort — unsupported — inspect the FSKit settings, force-enable, and restart its agent:")
                                .font(.caption).foregroundStyle(.secondary)
                            CopyableCommand(command: status.enableFallbackScript)
                            Text("This appends ntfs3g to the enabled-modules list only if it's missing, then restarts fskit_agent. It edits files outside the sandbox, so the app can't run it for you.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var enablementDetail: LocalizedStringKey {
        switch status.state {
        case .enabled:
            return "ntfs3g is enabled in System Settings."
        case .unknown:
            return "Couldn't query FSKit — try Re-check."
        case .bundled:
            return "Status unavailable on macOS 15. Check the ntfs3g switch in System Settings; an unknown status does not mean it is disabled."
        case .disabled, .notInstalled:
            return "Turn on ntfs3g under File System Extensions."
        }
    }

    private var registrationCheck: some View {
        CheckRow(ok: status.registrationOK,
                 title: "Registration",
                 detail: registrationDetail) {
            // Show every resolved path; red when there's more than one (a duplicate).
            ForEach(Array(status.moduleURLs.enumerated()), id: \.offset) { _, url in
                Text(url.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(status.isDuplicated ? .red : .secondary)
                    .textSelection(.enabled)
            }
            if status.moduleURLs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Couldn't read install paths in-app. Check in Terminal — expect a single /Applications path (not DerivedData) and no duplicates:")
                        .font(.caption).foregroundStyle(.secondary)
                    CopyableCommand(command: status.pluginkitCommand)
                }
            } else if status.isDuplicated {
                Text("Multiple registrations — remove the stale copies (old DerivedData/dev builds) so only the /Applications copy remains, then Re-check. Duplicates are a known cause of a greyed-out toggle.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var registrationDetail: LocalizedStringKey {
        if status.isDuplicated { return "More than one registration found — this can grey out the toggle." }
        switch status.registrationOK {
        case true?:  return "A single copy under /Applications."
        case false?: return "FSKit reports a copy outside /Applications. Check which app is registered."
        default:     return "Install path unknown."
        }
    }
}

// MARK: - components

/// A single pass/warn/fail diagnostic row with optional inline detail content.
private struct CheckRow<Extra: View>: View {
    let ok: Bool?
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    @ViewBuilder let extra: () -> Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.semibold)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            extra().padding(.leading, 28)
        }
    }

    private var symbol: String {
        switch ok {
        case true?:  return "checkmark.circle.fill"
        case false?: return "exclamationmark.triangle.fill"
        default:     return "questionmark.circle.fill"
        }
    }
    private var tint: Color {
        switch ok {
        case true?:  return .green
        case false?: return .orange
        default:     return .secondary
        }
    }
}

// CopyableCommand is shared — see CopyableCommand.swift.
