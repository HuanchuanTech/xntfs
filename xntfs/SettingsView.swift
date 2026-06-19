//
//  SettingsView.swift
//  A couple of manual-mount preferences. NTFS drives auto-mount under /Volumes
//  via the file-system extension; this app is the control panel.
//

import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section("Manual mounting") {
                Toggle("Mount as read-only by default", isOn: $settings.defaultReadOnly)
            }

            Section {
                Text("NTFS drives mount automatically under /Volumes via the file-system extension. Use this app to eject, remount read-only, mount to a folder you choose, or open a disk image.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 470, height: 240)
    }
}
