import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ProblemReportView: View {
    @Environment(AppModel.self) private var model
    @State private var description = ""
    @State private var steps = ""
    @State private var email = ""
    @State private var includeDiagnostics = true
    @State private var consent = false
    @State private var busy = false
    @State private var report: ProblemReport?
    @State private var reportData = Data()
    @State private var message: String?
    @State private var sent = false
    private let destination = SentryDestination.configured()

    private var validInput: Bool {
        !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        description.count <= 4_000 && steps.count <= 4_000 && email.count <= 320 &&
        (email.isEmpty || email.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Report a Problem").font(.title2).bold()
            if report == nil {
                Form {
                    Section {
                        Text("What went wrong?")
                        TextEditor(text: $description).frame(height: 90)
                        Text("Steps to reproduce (optional)")
                        TextEditor(text: $steps).frame(height: 70)
                        TextField("Reply email (optional)", text: $email)
                        Toggle("Include diagnostic snapshot", isOn: $includeDiagnostics)
                    }
                    Section {
                        Text("Diagnostics contain app and macOS versions, hardware model, extension status, mount state and recent error codes. File contents, volume names and full paths are not collected.")
                        Text("Review your description for private information before sharing. Each text field allows up to 4,000 characters.")
                    }.font(.caption).foregroundStyle(.secondary)
                }
                .formStyle(.grouped)
                .disabled(busy)
            } else {
                HStack {
                    Text("Report Preview").font(.headline)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(reportData.count), countStyle: .file))
                        .foregroundStyle(.secondary)
                }
                ReportPreview(text: String(decoding: reportData, as: UTF8.self))
                    .frame(minHeight: 260)
                    .border(.separator)
                Text("This is the report that will be exported or sent. The snapshot stays unchanged until you edit the report.")
                    .font(.caption).foregroundStyle(.secondary)
                if let destination {
                    Text("Recipient: \(destination.displayName)").font(.caption).textSelection(.enabled)
                    Text("Sending uses Sentry. The receiving service can see your IP address. Your email is included only if you entered it.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("I have reviewed this report and agree to send it.", isOn: $consent)
                        .disabled(busy || sent)
                }
            }
            if destination == nil {
                Text("Online sending is not configured in this build. You can export the report.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let message { Text(message).font(.callout).textSelection(.enabled) }
            Divider()
            HStack {
                if busy { ProgressView().controlSize(.small) }
                if report != nil {
                    Button("Edit Report") {
                        report = nil
                        reportData = Data()
                        consent = false
                        sent = false
                        message = nil
                    }.disabled(busy)
                }
                Spacer()
                if report != nil {
                    Button { export() } label: { Label("Export Report...", systemImage: "square.and.arrow.up") }
                        .disabled(busy)
                    Button { Task { await send() } } label: { Label("Send Report", systemImage: "paperplane") }
                        .disabled(destination == nil || !consent || busy || sent)
                } else {
                    Button("Create Snapshot & Preview") { Task { await prepare() } }
                        .disabled(!validInput || busy)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 680, minHeight: 640, idealHeight: 700)
    }

    private func prepare() async {
        guard !busy, validInput else { return }
        busy = true
        message = nil
        defer { busy = false }
        let snapshot = includeDiagnostics ? await DiagnosticSnapshot.capture(model: model) : nil
        let newReport = ProblemReport(description: description, steps: steps, contactEmail: email, diagnostics: snapshot)
        do {
            let data = try newReport.encoded()
            guard data.count <= SentryReportSender.maximumReportBytes else { throw ReportSendError.tooLarge }
            reportData = data
            report = newReport
            consent = false
        } catch { message = error.localizedDescription }
    }

    private func export() {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "xntfs-report-\(report.eventID.prefix(8)).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try reportData.write(to: url, options: .atomic)
            message = String(localized: "Report exported. Nothing was uploaded.")
        } catch { message = error.localizedDescription }
    }

    private func send() async {
        guard let report, let destination, consent, !busy, !sent else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            try await SentryReportSender.send(report: report, data: reportData, destination: destination, consent: consent)
            sent = true
            consent = false
            message = String(localized: "The service accepted report \(report.eventID). This does not confirm that it has been reviewed.")
        } catch {
            consent = false
            message = error.localizedDescription
        }
    }
}

private struct ReportPreview: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.isSelectable = true
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = NSSize(width: 8, height: 8)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let view = scroll.documentView as! NSTextView
        if view.string != text { view.string = text }
    }
}
