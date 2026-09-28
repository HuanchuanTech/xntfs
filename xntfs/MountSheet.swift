//
//  MountSheet.swift
//  In-app mount of a device/image volume — only presented on macOS 27+, the only systems
//  where a sandboxed app can mount a third-party FSKit volume (FSKit Mounter). Always targets
//  /Volumes. On earlier systems the UI routes the user to Disk Utility instead.
//

import SwiftUI

struct MountSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let device: NTFSDevice

    @State private var readOnly = false
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Mount \(device.displayName)").font(.title2).bold()
            Text("Mounts under /Volumes.").font(.callout).foregroundStyle(.secondary)

            Toggle("Mount read-only", isOn: $readOnly)
                .disabled(busy || !device.mediaWritable)
            if !device.mediaWritable {
                Text("This volume is read-only (e.g. an image attached read-only) and can only be mounted read-only.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let errorText {
                Divider()
                Text(errorText).font(.callout).foregroundStyle(.red)
                Button("Open Disk Utility") { DiskUtility.open() }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .disabled(busy)
                Button("Mount") { Task { await doMount() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
            }
        }
        .padding(20)
        .frame(width: 520)
        .frame(minHeight: errorText == nil ? 230 : 320)
        .interactiveDismissDisabled(busy)
        .onAppear {
            readOnly = !device.mediaWritable ? true
                : (device.kind == .diskImage ? model.settings.imageReadOnly : model.settings.deviceReadOnly)
        }
    }

    private func doMount() async {
        guard !busy else { return }
        errorText = nil
        busy = true
        defer { busy = false }
        switch await model.mount(device, readOnly: readOnly) {
        case .mounted: dismiss()
        case .failed(let msg): errorText = msg
        }
    }
}
