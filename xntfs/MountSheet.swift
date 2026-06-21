//
//  MountSheet.swift
//  Manual (re)mount of a device/image volume. Mounting only ever targets /Volumes: a
//  sandboxed app/extension can't be granted access to an arbitrary folder (only /Volumes,
//  owned by diskarbitrationd, and the extension's own sandbox-allowed temp paths work).
//  On macOS 27 the in-app FSClient path mounts directly; otherwise a copyable
//  `diskutil mount` command is shown.
//

import SwiftUI

struct MountSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let device: NTFSDevice

    @State private var readOnly = false
    @State private var command: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Mount \(device.displayName)").font(.title2).bold()
            Text("Mounts under /Volumes.").font(.callout).foregroundStyle(.secondary)

            Toggle("Mount read-only", isOn: $readOnly)
                .disabled(!device.mediaWritable)
                .onChange(of: readOnly) { _, _ in command = nil }
            if !device.mediaWritable {
                Text("This volume is read-only (e.g. an image attached read-only) and can only be mounted read-only.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let command {
                Divider()
                Text("A sandboxed app can't mount this here, so paste this into Terminal:")
                    .font(.callout)
                CopyableCommand(command: command)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                Button("Mount") { Task { await doMount() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
            }
        }
        .padding(20)
        .frame(width: 560, height: command == nil ? 240 : 380)
        .onAppear { readOnly = device.mediaWritable ? model.settings.defaultReadOnly : true }
    }

    private func doMount() async {
        busy = true
        defer { busy = false }
        let outcome = await model.mount(device, to: nil, readOnly: readOnly)
        switch outcome {
        case .mounted: dismiss()
        case .needsCommand(let cmd): command = cmd
        case .failed: dismiss()   // error surfaced by the model's alert
        }
    }
}
