import SwiftUI

struct LegacyMountSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let device: NTFSDevice

    private var currentDevice: NTFSDevice? {
        model.devices.first { $0.id == device.id && $0.registryEntryID == device.registryEntryID }
    }

    private var command: String? {
        guard let currentDevice, let script = LegacyMountCommand.scriptURL,
              let boot = LegacyMountCommand.bootSessionUUID() else { return nil }
        let readOnly = currentDevice.kind == .diskImage ? model.settings.imageReadOnly : model.settings.deviceReadOnly
        return LegacyMountCommand.mount(device: currentDevice, readOnly: readOnly, script: script,
                                       app: Bundle.main.bundleURL, bootSession: boot)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Mount with xntfs").font(.title2).bold()
                Spacer()
                Button { model.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Re-check")
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LabeledContent("Name", value: device.displayName)
                    LabeledContent("BSD device", value: device.devicePath)
                    if let currentDevice, currentDevice.state.isMounted && currentDevice.mountedByXntfs {
                        Label("This volume is mounted with xntfs.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        LabeledContent("Access") {
                            Text(currentDevice.readOnly ? "Read-only" : "Read/write")
                        }
                    }
                    Text("macOS 15 prefers Apple's NTFS driver. This one-time compatibility command switches only the selected volume to xntfs.")
                    Text("First enable ntfs3g in System Settings. Close files on this volume before continuing. A mounted volume will be unmounted normally; busy volumes will not be forced.")
                    ExtensionEnablementInstructions()
                    Button { ExtensionStatus.openSettings() } label: {
                        Label("Open Settings…", systemImage: "gearshape")
                    }
                    Text("Run the command yourself in Terminal. It asks for confirmation and an administrator password. The app does not run it or request administrator access.")
                    Text("Access follows your read-only preferences. An image attached read-only stays read-only.")
                        .foregroundStyle(.secondary)
                    SettingsLink { Label("Read-only preferences", systemImage: "slider.horizontal.3") }
                    if let command {
                        CopyableCommand(command: command)
                    } else {
                        Text("The device identity or command resource is unavailable. Reconnect the volume and reopen this panel; do not reuse an old command.")
                            .foregroundStyle(.orange)
                    }
                    Text("The temporary routing entry is removed after the attempt, including on failure or cancellation. Reconnecting the drive may require running a new command.")
                        .font(.callout).foregroundStyle(.secondary)
                    DisclosureGroup("Cleanup after an interrupted attempt") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("This removes only xntfs's inactive compatibility entry. It does not unmount volumes, change extension enablement, or remove other filesystem drivers.")
                                .font(.callout)
                            if let cleanup = LegacyMountCommand.cleanup { CopyableCommand(command: cleanup) }
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 440, idealHeight: 660)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshDevices() }
        }
    }
}
