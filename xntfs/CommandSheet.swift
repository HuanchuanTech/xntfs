//
//  CommandSheet.swift
//  Sheets that present copyable Terminal commands (attach / detach an image). The app
//  never runs them — the sandbox blocks hdiutil/mount.
//

import SwiftUI

/// A picked image file waiting to be attached (wrapper for `.sheet(item:)`).
struct PendingAttach: Identifiable {
    let id = UUID()
    let url: URL
}

/// Attach a disk image: choose read-only (default) or writable, then copy the
/// `hdiutil attach` command. Read-only by default so an image isn't written by accident;
/// a physical drive is unaffected (it auto-mounts read-write from its writable media).
struct AttachImageSheet: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    @State private var writable = false   // default: attach read-only

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Attach Disk Image").font(.title3).bold()
            Text(url.lastPathComponent)
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)

            Toggle("Attach writable", isOn: $writable)
            Text(writable ? "The image will mount read-write."
                          : "The image will mount read-only (recommended).")
                .font(.caption).foregroundStyle(.secondary)

            Divider()
            Text("Run this in Terminal — a sandboxed app can't do it for you:")
                .font(.callout).foregroundStyle(.secondary)
            CopyableCommand(command: MountService.attachCommand(url.path, readOnly: !writable))

            Spacer(minLength: 0)
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 580, height: 320)
    }
}

/// A small sheet presenting one fixed copyable command (e.g. detach).
struct CommandSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: LocalizedStringKey
    let command: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3).bold()
            Text("Run this in Terminal — a sandboxed app can't do it for you:")
                .font(.callout).foregroundStyle(.secondary)
            CopyableCommand(command: command)
            Spacer(minLength: 0)
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 580, height: 230)
    }
}
