//
//  MountSheet.swift
//  In-app mount of a device/image volume — only presented on macOS 27+, the only systems
//  where a sandboxed app can mount a third-party FSKit volume (FSKit Mounter). Always targets
//  /Volumes. On earlier systems the UI routes the user to Disk Utility instead.
//
//  Copyright (C) 2026 Aïssa BELKOUSSA — modified 2026-10-03: sandbox-denied mount fallback.
//

import SwiftUI

struct MountSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    // Keep the target of this presentation even when its parent is refreshed.
    @State private var device: NTFSDevice

    @State private var readOnly = false
    @State private var busy = false
    @State private var errorText: String?
    @State private var systemCommand: String?

    init(device: NTFSDevice) {
        _device = State(initialValue: device)
    }

    private var currentDevice: NTFSDevice? {
        model.devices.first { $0.isSameDevice(as: device) }
    }

    var body: some View {
        let current = currentDevice
        let mediaWritable = current?.mediaWritable ?? device.mediaWritable
        let visibleError = current == nil ? MountError.diskNotFound(device.id).localizedDescription : errorText
        let visibleSystemCommand = current == nil ? nil : systemCommand
        VStack(alignment: .leading, spacing: 16) {
            Text("Mount \(device.displayName)").font(.title2).bold()
            Text("Mounts under /Volumes.").font(.callout).foregroundStyle(.secondary)

            Toggle("Mount read-only", isOn: $readOnly)
                .disabled(busy || current == nil || !mediaWritable)
            if !mediaWritable {
                Text("This volume is read-only (e.g. an image attached read-only) and can only be mounted read-only.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let errorText = visibleError {
                Divider()
                Text(errorText).font(.callout).foregroundStyle(visibleSystemCommand == nil ? .red : .primary)
                if let systemCommand = visibleSystemCommand { CopyableCommand(command: systemCommand) }
                Button("Open Disk Utility") { DiskUtility.open() }
                Button("Report a Problem...") { openWindow(id: "problem-report") }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .disabled(busy)
                Button("Mount") { Task { await doMount() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || current == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .frame(minHeight: visibleError == nil ? 230 : 320)
        .interactiveDismissDisabled(busy)
        .onAppear {
            readOnly = !mediaWritable ? true
                : (device.kind == .diskImage ? model.settings.imageReadOnly : model.settings.deviceReadOnly)
        }
        // The sandbox denial doesn't depend on the access mode, so keep the shown command in
        // sync with the toggle instead of leaving a stale rw/readOnly command to be copied.
        .onChange(of: readOnly) { _, _ in updateSystemCommand() }
        .onChange(of: current?.mediaWritable) { _, writable in
            if writable == false { readOnly = true }
            updateSystemCommand()
        }
    }

    private func updateSystemCommand() {
        guard systemCommand != nil else { return }
        guard let current = currentDevice else { systemCommand = nil; return }
        systemCommand = SystemMountCommand.diskutil(bsdName: current.id, readOnly: readOnly || !current.mediaWritable)
    }

    private func doMount() async {
        guard !busy else { return }
        errorText = nil
        systemCommand = nil
        guard let current = currentDevice else {
            errorText = MountError.diskNotFound(device.id).localizedDescription
            return
        }
        busy = true
        defer { busy = false }
        let outcome = await model.mount(current, readOnly: readOnly || !current.mediaWritable)
        guard currentDevice != nil else {
            errorText = MountError.diskNotFound(device.id).localizedDescription
            return
        }
        switch outcome {
        case .mounted: dismiss()
        case .failed(let msg): errorText = msg
        case .needsSystemMount(let msg, let command):
            errorText = msg
            systemCommand = command
        }
    }
}
