import SwiftUI

struct ExtensionEnablementInstructions: View {
    var majorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Open System Settings > General > Login Items & Extensions, then scroll down to Extensions.")
            if majorVersion >= 26 {
                Text("Select **By Category**, not By App. Open File System Extensions and turn on ntfs3g.")
            } else {
                Text("Open File System Extension and turn on ntfs3g.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct LegacyExtensionGuidance: View {
    var onDiagnostics: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle")
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                Text("On macOS 15, xntfs cannot check whether ntfs3g is enabled. If it is already on, dismiss this tip and select a volume to mount with xntfs.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                ExtensionEnablementInstructions(majorVersion: 15)
                HStack(spacing: 12) {
                    Button("Open Settings…") { ExtensionStatus.openSettings() }
                    Button("Diagnostics…") { onDiagnostics() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help("Don't show this tip again")
            .accessibilityLabel("Don't show this tip again")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider() }
    }
}
