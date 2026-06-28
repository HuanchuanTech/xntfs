//
//  SettingsView.swift
//  Read-only mount preferences, one per scenario (drives / disk images). They set the
//  access the extension uses when the system auto-mounts a volume, and the default for
//  in-app mounting on macOS 27+.
//

import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section("Disk drives") {
                Toggle("Mount read-only", isOn: $settings.deviceReadOnly)
                Text("Read-only access for NTFS disk drives.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Disk images") {
                Toggle("Mount read-only", isOn: $settings.imageReadOnly)
                Text("Read-only access for attached NTFS disk images.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 280)
    }
}
