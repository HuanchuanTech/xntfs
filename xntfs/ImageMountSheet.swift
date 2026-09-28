import SwiftUI

struct PendingImage: Identifiable {
    let id = UUID()
    let url: URL
}

struct ImageMountSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let source: URL
    var onMounted: (URL) -> Void

    @State private var readOnly = true
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Mount Disk Image").font(.title2).bold()
            Text(source.lastPathComponent).lineLimit(2).textSelection(.enabled)
            Toggle("Mount read-only", isOn: $readOnly).disabled(busy)
            if let errorText {
                Text(errorText).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                HStack {
                    Button("Open Settings…") { ExtensionStatus.openSettings() }
                    Button("Open Disk Utility") { DiskUtility.open() }
                }
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.disabled(busy)
                Button("Mount") { Task { await mount() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
            }
        }
        .padding(20)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled(busy)
        .onAppear { readOnly = model.settings.imageReadOnly }
    }

    private func mount() async {
        guard #available(macOS 27.0, *) else { return }
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            let url = try await model.mountImage(source, readOnly: readOnly)
            onMounted(url)
            dismiss()
        } catch {
            errorText = ImageMountService.diagnosticMessage(error)
        }
    }
}

struct ImageDetailView: View {
    @Environment(AppModel.self) private var model
    let image: MountedImage

    var body: some View {
        Form {
            Section("Volume") {
                LabeledContent("Name", value: image.name)
                LabeledContent("Image file", value: image.source.path)
                    .textSelection(.enabled)
                LabeledContent("Capacity", value: image.sizeBytes.humanSize)
                LabeledContent("Format", value: "NTFS (xntfs)")
                LabeledContent("Mounted at", value: image.mountPoint.path)
                LabeledContent("Access") {
                    Text(image.readOnly ? LocalizedStringKey("Read-only") : "Read/write")
                }
            }
            Section {
                Button {
                    Task { await model.unmountImage(image) }
                } label: { Label("Eject", systemImage: "eject.fill") }
                .disabled(model.unmountingImages.contains(image.id))
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([image.mountPoint])
                } label: { Label("Reveal in Finder", systemImage: "folder") }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(image.name)
    }
}
