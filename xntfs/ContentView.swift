//
//  ContentView.swift
//  Disk Utility-style tree (Devices + Disk Images, both monitor-detected) with a detail
//  pane. Attaching/detaching images and mounting (on <27 or to a folder) are copyable
//  Terminal commands, since a sandboxed app can't run hdiutil/mount itself.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var extStatus = ExtensionStatus()
    @State private var selection: NTFSDevice.ID?
    @State private var showAddImage = false
    @State private var showDiagnostics = false
    @State private var pendingAttach: PendingAttach?
    @State private var showError = false

    var body: some View {
        VStack(spacing: 0) {
            if extStatus.state == .disabled || extStatus.state == .notInstalled {
                ExtensionBanner(status: extStatus, onDiagnostics: { showDiagnostics = true })
            }
            mainContent
        }
        .task { await extStatus.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await extStatus.refresh() } }
        }
    }

    private var physicalDevices: [NTFSDevice] { model.devices.filter { $0.kind != .diskImage } }
    private var imageDevices: [NTFSDevice] { model.devices.filter { $0.kind == .diskImage } }

    private var selectedDevice: NTFSDevice? {
        guard let id = selection else { return nil }
        return model.devices.first { $0.id == id }
    }

    private var mainContent: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Devices") {
                    ForEach(physicalDevices) { device in
                        DeviceRow(device: device, byXntfs: device.mountedByXntfs, isSelected: selection == device.id).tag(device.id)
                    }
                }
                Section("Disk Images") {
                    ForEach(imageDevices) { device in
                        DeviceRow(device: device, byXntfs: device.mountedByXntfs, isSelected: selection == device.id).tag(device.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
            .overlay {
                if model.devices.isEmpty {
                    ContentUnavailableView("No NTFS volumes",
                                           systemImage: "externaldrive.badge.questionmark",
                                           description: Text("Plug in an NTFS drive, or add a disk image."))
                }
            }
        } detail: {
            if let device = selectedDevice {
                DeviceDetailView(device: device)
            } else {
                ContentUnavailableView("Select a volume", systemImage: "externaldrive")
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAddImage = true } label: {
                    Label("Add Disk Image…", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showDiagnostics = true } label: {
                    Label("Diagnostics…", systemImage: "stethoscope")
                }
            }
        }
        .fileImporter(isPresented: $showAddImage, allowedContentTypes: Self.imageTypes) { result in
            if case .success(let url) = result { pendingAttach = PendingAttach(url: url) }
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView(status: extStatus)
        }
        .sheet(item: $pendingAttach) { p in
            AttachImageSheet(url: p.url)
        }
        .onChange(of: model.lastError) { _, newValue in showError = (newValue != nil) }
        .alert("Operation failed", isPresented: $showError) {
            Button("OK") { model.clearError() }
        } message: {
            Text(model.lastError ?? "")
        }
    }

    private static var imageTypes: [UTType] {
        var types: [UTType] = [.diskImage, .data]
        for ext in ["ntfs", "img", "dd", "raw", "bin"] {
            if let u = UTType(filenameExtension: ext) { types.append(u) }
        }
        return types
    }
}

struct ExtensionBanner: View {
    let status: ExtensionStatus
    var onDiagnostics: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout).fontWeight(.semibold)
                Text(instruction)
                    .font(.caption).foregroundStyle(.secondary)
                Text("Can't enable it? Open Diagnostics to troubleshoot.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Diagnostics…") { onDiagnostics() }
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
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(iconColor)
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
                    .background(badgeColor.opacity(0.18))
                    .foregroundStyle(badgeColor)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 2)
    }

    // When the row is selected the List paints an accent background, so accent-colored
    // content (the icon, the badge) blends in and vanishes — use white instead.
    private var iconColor: Color {
        if isSelected { return .white }
        return device.state.isMounted ? .accentColor : .secondary
    }
    private var badgeColor: Color {
        if isSelected { return .white }
        return byXntfs ? .accentColor : .secondary
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
        case .mounted: return device.readOnly ? "Mounted · read-only" : "Mounted"
        case .unmounting: return "Ejecting…"
        case .failed: return "Failed"
        }
    }
}

struct DeviceDetailView: View {
    @Environment(AppModel.self) private var model
    let device: NTFSDevice
    @State private var showMountSheet = false
    @State private var showDetach = false

    var body: some View {
        Form {
            Section("Volume") {
                LabeledContent("Name", value: device.displayName)
                LabeledContent("BSD device", value: device.devicePath)
                LabeledContent("Capacity", value: device.sizeBytes.humanSize)
                LabeledContent("Format", value: "NTFS")
                if case .mounted(let url) = device.state {
                    LabeledContent("Mounted at", value: url.path)
                    LabeledContent("Access", value: device.readOnly ? "Read-only" : "Read/write")
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
                        showMountSheet = true
                    } label: { Label("Mount…", systemImage: "play.fill") }
                }
                if device.kind == .diskImage {
                    Button(role: .destructive) {
                        showDetach = true
                    } label: { Label("Detach Image…", systemImage: "eject.circle") }
                    .disabled(device.wholeDiskBSD.isEmpty)
                }
            }

            if case .failed(let message) = device.state {
                Section { Text(message).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(device.displayName)
        .sheet(isPresented: $showMountSheet) {
            MountSheet(device: device).environment(model)
        }
        .sheet(isPresented: $showDetach) {
            CommandSheet(title: "Detach Disk Image",
                         command: MountService.detachCommand(wholeDiskBSD: device.wholeDiskBSD))
        }
    }
}
