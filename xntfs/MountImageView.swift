//
//  MountImageView.swift
//  Mount a raw NTFS image file at a chosen folder. On macOS 27+ this mounts
//  directly; on earlier systems it shows a copyable Terminal command (a sandboxed
//  app can't run `mount` itself).
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MountImageView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var source: URL?
    @State private var target: URL?
    @State private var readOnly = false
    @State private var showSourcePicker = false
    @State private var showTargetPicker = false
    @State private var command: String?
    @State private var copied = false
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Mount Disk Image").font(.title2).bold()

            GroupBox {
                row(label: "Image file",
                    value: source?.lastPathComponent,
                    button: "Choose Image…") { showSourcePicker = true }
                Divider()
                row(label: "Mount into folder",
                    value: target?.path,
                    button: "Choose Folder…") { showTargetPicker = true }
            }

            Toggle("Mount read-only", isOn: $readOnly)

            Text("In-app mount goes to /Volumes (macOS 27+). Choose a folder to mount into a custom location via a Terminal command.")
                .font(.caption).foregroundStyle(.secondary)

            if let command {
                Divider()
                Text("On this macOS a sandboxed app can't run mount for you. Paste this into Terminal:")
                    .font(.callout)
                HStack(alignment: .top, spacing: 8) {
                    Text(command)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                Button("Mount") { Task { await mount() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(source == nil || busy || (!canMountToVolumes && target == nil))
            }
        }
        .padding(20)
        .frame(width: 560, height: command == nil ? 300 : 440)
        .onAppear { readOnly = model.settings.defaultReadOnly }
        .fileImporter(isPresented: $showSourcePicker, allowedContentTypes: imageTypes) { result in
            if case .success(let url) = result { source = url; command = nil; copied = false }
        }
        .fileImporter(isPresented: $showTargetPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { target = url; command = nil; copied = false }
        }
    }

    @ViewBuilder
    private func row(label: LocalizedStringKey, value: String?, button: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value ?? String(localized: "None selected"))
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(value == nil ? .secondary : .primary)
            }
            Spacer()
            Button(button, action: action)
        }
        .padding(.vertical, 4)
    }

    private func mount() async {
        guard let source else { return }
        busy = true
        defer { busy = false }
        // Hold security-scoped access for the duration (needed by the macOS-27 direct
        // path; harmless for the manual-command path).
        let s = source.startAccessingSecurityScopedResource()
        let t = target?.startAccessingSecurityScopedResource() ?? false
        defer {
            if s { source.stopAccessingSecurityScopedResource() }
            if t { target?.stopAccessingSecurityScopedResource() }
        }
        let outcome = await model.mountImage(source: source, target: target, readOnly: readOnly)
        switch outcome {
        case .mounted:
            dismiss()
        case .needsManualCommand(let cmd):
            command = cmd
            copied = false
        case .failed:
            dismiss()   // the error is surfaced by the model's alert
        }
    }

    private var imageTypes: [UTType] {
        var types: [UTType] = [.diskImage, .data]
        for ext in ["ntfs", "img", "dd", "raw", "bin"] {
            if let u = UTType(filenameExtension: ext) { types.append(u) }
        }
        return types
    }

    /// macOS 27+ can mount into /Volumes in-app (FSClient.mountSingleVolume).
    private var canMountToVolumes: Bool {
        if #available(macOS 27.0, *) { true } else { false }
    }
}
