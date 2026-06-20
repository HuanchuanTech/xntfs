//
//  ContentView.swift
//  Device list + per-device mount/unmount actions, plus raw-image mounting.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var extStatus = ExtensionStatus()
    @State private var selection: NTFSDevice.ID?
    @State private var showImageSheet = false
    @State private var showError = false

    var body: some View {
        VStack(spacing: 0) {
            if extStatus.state == .disabled || extStatus.state == .notInstalled {
                ExtensionBanner(status: extStatus)
            }
            mainContent
        }
        .task { await extStatus.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await extStatus.refresh() } }
        }
    }

    private var mainContent: some View {
        NavigationSplitView {
            List(model.devices, selection: $selection) { device in
                DeviceRow(device: device, byXntfs: device.mountedByXntfs)
                    .tag(device.id)
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
            .overlay {
                if model.devices.isEmpty {
                    ContentUnavailableView("No NTFS volumes",
                                           systemImage: "externaldrive.badge.questionmark",
                                           description: Text("Plug in an NTFS drive, or mount a disk image."))
                }
            }
        } detail: {
            if let id = selection, let device = model.devices.first(where: { $0.id == id }) {
                DeviceDetailView(device: device)
            } else {
                ContentUnavailableView("Select a volume", systemImage: "externaldrive")
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showImageSheet = true
                } label: {
                    Label("Mount Image…", systemImage: "opticaldiscdrive")
                }
            }
        }
        .sheet(isPresented: $showImageSheet) {
            MountImageView().environment(model)
        }
        .onChange(of: model.lastError) { _, newValue in showError = (newValue != nil) }
        .alert("Operation failed", isPresented: $showError) {
            Button("OK") { model.clearError() }
        } message: {
            Text(model.lastError ?? "")
        }
    }
}

struct ExtensionBanner: View {
    let status: ExtensionStatus

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout).fontWeight(.semibold)
                Text(instruction)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Open Settings…") { ExtensionStatus.openSettings() }
                .buttonStyle(.borderedProminent)
            Button {
                Task { await status.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Re-check")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var title: LocalizedStringKey {
        status.state == .notInstalled ? "NTFS extension not installed" : "NTFS extension not enabled"
    }

    /// Before macOS 27 the button can only open the pane (no deep-link to the detail), so
    /// spell out the remaining steps; on macOS 27 the official jump lands on the list.
    private var instruction: LocalizedStringKey {
        if #available(macOS 27.0, *) {
            return "Turn on “ntfs3g” in the File System Extensions list."
        }
        return "In Settings, scroll to Extensions → open “File System Extensions” → turn on “ntfs3g”."
    }
}

struct DeviceRow: View {
    let device: NTFSDevice
    var byXntfs: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(device.state.isMounted ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName).font(.body)
                Text("\(device.sizeBytes.humanSize) · \(Text(statusText))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if device.state.isMounted {
                Text(byXntfs ? "xntfs" : "System")
                    .font(.caption2).fontWeight(.semibold)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background((byXntfs ? Color.accentColor : Color.secondary).opacity(0.18))
                    .foregroundStyle(byXntfs ? Color.accentColor : Color.secondary)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch device.kind {
        case .diskImage: return "opticaldiscdrive.fill"
        case .removable: return "externaldrive.fill"
        case .fixed: return "internaldrive.fill"
        }
    }

    private var statusText: LocalizedStringKey {
        switch device.state {
        case .unmounted: return "Not mounted"
        case .mounting: return "Mounting…"
        case .mounted: return "Mounted"
        case .unmounting: return "Ejecting…"
        case .failed: return "Failed"
        }
    }
}

struct DeviceDetailView: View {
    @Environment(AppModel.self) private var model
    let device: NTFSDevice
    @State private var showFolderPicker = false

    var body: some View {
        Form {
            Section("Volume") {
                LabeledContent("Name", value: device.displayName)
                LabeledContent("BSD device", value: device.devicePath)
                LabeledContent("Capacity", value: device.sizeBytes.humanSize)
                LabeledContent("Format", value: "NTFS")
                if case .mounted(let url) = device.state {
                    LabeledContent("Mounted at", value: url.path)
                }
            }

            Section {
                if device.state.isMounted {
                    Button {
                        Task { await model.unmount(device) }
                    } label: { Label("Eject", systemImage: "eject.fill") }

                    if let url = device.state.mountPoint {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } label: { Label("Reveal in Finder", systemImage: "folder") }
                    }
                } else {
                    Button {
                        Task { await model.mount(device, to: nil, readOnly: model.settings.defaultReadOnly) }
                    } label: { Label("Mount", systemImage: "play.fill") }

                    Button {
                        showFolderPicker = true
                    } label: { Label("Mount to Folder…", systemImage: "folder.badge.plus") }
                }
            }

            if case .failed(let message) = device.state {
                Section { Text(message).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(device.displayName)
        .fileImporter(isPresented: $showFolderPicker,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let folder = urls.first {
                Task {
                    await SecurityScope.withAccessAsync(folder) {
                        await model.mount(device, to: folder, readOnly: model.settings.defaultReadOnly)
                    }
                }
            }
        }
    }
}
