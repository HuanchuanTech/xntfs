import Foundation
import Darwin

nonisolated final class ReportMockProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseID = ""
    nonisolated(unsafe) static var requests = 0
    nonisolated(unsafe) static var failure: Error?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: ["id": Self.responseID]))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct ProblemReportTests {
    static var passed = 0
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError("FAIL: \(message)") }
        passed += 1
        print("PASS: \(message)")
    }

    static func main() async throws {
        if CommandLine.arguments[1] == "--writer" {
            let store = DiagnosticRecorder(directory: URL(fileURLWithPath: CommandLine.arguments[2]), component: "extension")
            for index in 0..<20 {
                store.record(.load, .observed, fields: [.count: String(index)])
                _ = await store.snapshot()
            }
            return
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let path = root.appendingPathComponent("shared")
        let app = DiagnosticRecorder(directory: path, component: "app")
        let ext = DiagnosticRecorder(directory: path, component: "extension")
        let cause = NSError(domain: NSPOSIXErrorDomain, code: 13, userInfo: [NSFilePathErrorKey: "/Users/private/secret.img"])
        let error = NSError(domain: "DiskArbitration", code: -119930871,
                            userInfo: [NSUnderlyingErrorKey: cause, NSLocalizedDescriptionKey: "SecretVolume /Volumes/private"])
        app.record(.mount, .failed, fields: [.device: "disk7s2", .requestedReadOnly: "false"], error: error)
        ext.record(.activate, .failed, fields: [.kind: "block", .source: "/Users/private/secret"], error: cause)
        _ = await app.snapshot()
        _ = await ext.snapshot()
        let history = await app.snapshot()
        check(history.events.count == 2, "app and extension records merge without overwrite")
        check(Set(history.events.map(\.process)).count == 2, "process identifiers are independent")
        let raw = String(decoding: try JSONEncoder().encode(history), as: UTF8.self)
        check(!raw.contains("private") && !raw.contains("SecretVolume") && !raw.contains("secret.img"), "paths, labels and userInfo do not enter history")
        let recorded = history.events.first { $0.component == "app" }!
        check(recorded.errors.map(\.code) == [-119930871, 13], "numeric underlying error chain retained")
        check(recorded.errors.first?.hex == "0xF8DA0009", "Disk Arbitration hexadecimal error is preserved")
        let invalid = DiagnosticEvent(action: .mount, phase: .failed, fields: [.device: "disk7s2;secret"],
                                      process: UUID(), component: "app")
        check(invalid.fields["device"] == "omitted", "device field only accepts BSD names")

        for index in 0..<430 {
            app.record(.probe, .observed, fields: [.count: String(index)])
            if index % 20 == 0 { _ = await app.snapshot() }
        }
        let bounded = await app.snapshot()
        check(bounded.events.count == DiagnosticRecorder.maximumEvents, "event history has a hard count limit")
        check(try Data(contentsOf: path.appendingPathComponent("history.json")).count <= DiagnosticRecorder.maximumBytes, "disk history has a hard byte limit")
        let attrs = try FileManager.default.attributesOfItem(atPath: path.appendingPathComponent("history.json").path)
        check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "history is owner-readable only")

        let concurrentPath = root.appendingPathComponent("multiprocess")
        let children = try (0..<3).map { _ -> Process in
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--writer", concurrentPath.path]
            try child.run()
            return child
        }
        for child in children { child.waitUntilExit() }
        check(children.allSatisfy { $0.terminationStatus == 0 }, "independent writer processes exit normally")
        let concurrent = await DiagnosticRecorder(directory: concurrentPath, component: "app").snapshot()
        check(concurrent.events.count == 60 && Set(concurrent.events.map(\.process)).count == 3,
              "cross-process locking preserves all writers")
        let burstStore = DiagnosticRecorder(directory: root.appendingPathComponent("burst"), component: "app")
        for _ in 0..<5_000 { burstStore.record(.probe, .observed) }
        let burst = await burstStore.snapshot()
        check(burst.droppedInThisProcess > 0 && burst.events.count <= DiagnosticRecorder.maximumEvents,
              "event bursts are bounded and omissions are visible")

        let oldPath = root.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: oldPath, withIntermediateDirectories: true)
        let expired = DiagnosticEvent(action: .mount, phase: .failed, process: UUID(), component: "app", time: Date().addingTimeInterval(-8 * 86400))
        try JSONEncoder().encode([expired]).write(to: oldPath.appendingPathComponent("history.json"))
        let oldStore = DiagnosticRecorder(directory: oldPath, component: "app")
        let oldHistory = await oldStore.snapshot()
        check(oldHistory.events.isEmpty, "expired events are not exported")
        check(try JSONDecoder().decode([DiagnosticEvent].self, from: Data(contentsOf: oldPath.appendingPathComponent("history.json"))).isEmpty, "snapshot prunes expired disk history")
        try Data("invalid-json".utf8).write(to: oldPath.appendingPathComponent("history.json"))
        let corrupt = await oldStore.snapshot()
        check(corrupt.warning == "invalid-history-replaced", "corrupt history is explicitly reported")
        let memory = DiagnosticRecorder(directory: nil, component: "app")
        memory.record(.appStart, .observed)
        let fallback = await memory.snapshot()
        check(fallback.events.count == 1 && fallback.storage == "process-memory-only" && fallback.warning != nil, "unavailable app group retains process evidence with warning")
        check(DiagnosticSnapshot.location(URL(fileURLWithPath: "/Users/private/Library/Developer/Xcode/DerivedData/a.app")) == "DerivedData", "registration paths are classified, not disclosed")

        let report = ProblemReport(description: "Test: 挂载失败", steps: "Connect\nMount", contactEmail: "", diagnostics: nil)
        let data = try report.encoded()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        check(json["diagnostics"] == nil && json["contactEmail"] == nil, "opting out excludes diagnostics and blank email")
        let decoded = try JSONDecoder.withDates.decode(ProblemReport.self, from: data)
        check(decoded.id == report.id && decoded.description == report.description, "export round-trips with Unicode")
        check(try report.encoded() == data, "preview bytes remain stable")

        let destination = try SentryDestination(dsn: "https://publickey@example.invalid/sentry/123")
        check(destination.endpoint.absoluteString == "https://example.invalid/sentry/api/123/envelope/", "Sentry DSN prefix maps to ingest endpoint")
        check(!destination.displayName.contains("publickey"), "recipient display omits credential")
        for invalidDSN in ["", "http://key@example.invalid/1", "https://key:secret@example.invalid/1", "https://key@example.invalid/no", "https://key@example.invalid/1?q=secret", "https://key@example.invalid/1#fragment"] {
            check((try? SentryDestination(dsn: invalidDSN)) == nil, "invalid or non-HTTPS DSN rejected")
        }
        check(SentryDestination.configured() == nil, "missing DSN does not silently configure upload")
        check((try? SentryReportSender.request(report: report, data: data, destination: destination, consent: false)) == nil, "request construction requires consent")
        let request = try SentryReportSender.request(report: report, data: data, destination: destination, consent: true)
        check(request.httpMethod == "POST" && request.value(forHTTPHeaderField: "Content-Type") == "application/x-sentry-envelope", "documented Sentry envelope transport")

        // Parse by UTF-8 byte count, not characters or lines: attachments contain both.
        let envelope = Array(request.httpBody!)
        var cursor = 0
        func line() throws -> [String: Any] {
            let end = envelope[cursor...].firstIndex(of: 10)!
            let value = try JSONSerialization.jsonObject(with: Data(envelope[cursor..<end])) as! [String: Any]
            cursor = end + 1
            return value
        }
        let header = try line()
        check(header["event_id"] as? String == report.eventID, "report ID links envelope and feedback")
        let item = try line()
        let size = item["length"] as! Int
        let feedback = try JSONSerialization.jsonObject(with: Data(envelope[cursor..<cursor+size])) as! [String: Any]
        cursor += size + 1
        check(item["type"] as? String == "feedback" && feedback["type"] as? String == "feedback", "feedback is not uploaded as billable error events")
        let attachment = try line()
        let attachmentSize = attachment["length"] as! Int
        check(Data(envelope[cursor..<cursor+attachmentSize]) == data, "attachment bytes exactly match reviewed export")
        check(attachmentSize == data.count && cursor + attachmentSize + 1 == envelope.count, "Unicode byte lengths and envelope framing are exact")
        check((try? SentryReportSender.envelope(report: report, data: Data(count: SentryReportSender.maximumReportBytes + 1))) == nil, "oversized report rejected before upload")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReportMockProtocol.self]
        ReportMockProtocol.responseID = report.eventID
        do {
            try await SentryReportSender.send(report: report, data: data, destination: destination, consent: false, configuration: config)
            fatalError("accepted without consent")
        } catch { check(ReportMockProtocol.requests == 0, "no network request without consent") }
        try await SentryReportSender.send(report: report, data: data, destination: destination, consent: true, configuration: config)
        check(ReportMockProtocol.requests == 1, "explicit send makes one request and validates matching receipt")
        for status in [302, 403, 429, 500] {
            ReportMockProtocol.status = status
            do {
                try await SentryReportSender.send(report: report, data: data, destination: destination, consent: true, configuration: config)
                fatalError("HTTP \(status) accepted")
            } catch { check(true, "HTTP \(status) is not reported as success") }
        }
        ReportMockProtocol.status = 200
        ReportMockProtocol.responseID = "wrong-receipt"
        do {
            try await SentryReportSender.send(report: report, data: data, destination: destination, consent: true, configuration: config)
            fatalError("wrong receipt accepted")
        } catch { check(true, "unmatched receipt is not delivery confirmation") }
        ReportMockProtocol.failure = URLError(.notConnectedToInternet)
        let before = ReportMockProtocol.requests
        do {
            try await SentryReportSender.send(report: report, data: data, destination: destination, consent: true, configuration: config)
            fatalError("offline success")
        } catch { check(ReportMockProtocol.requests == before + 1, "offline failure does not retry in background") }
        check(try report.encoded() == data, "send failure leaves export intact")
        let limited = HTTPURLResponse(url: destination.endpoint, statusCode: 200, httpVersion: nil,
                                     headerFields: ["X-Sentry-Rate-Limits": "60:attachment:organization"] )!
        check((try? SentryReportSender.validateResponse(limited)) == nil, "partial attachment quota is not silent success")
        let unrelated = HTTPURLResponse(url: destination.endpoint, statusCode: 200, httpVersion: nil,
                                       headerFields: ["X-Sentry-Rate-Limits": "60:error;transaction;replay:organization"] )!
        do {
            try SentryReportSender.validateResponse(unrelated)
            check(true, "unrelated error and replay quotas do not block feedback")
        } catch { fatalError("unrelated quota rejected feedback") }
        print("\(passed) report checks passed. No external requests or mounted volumes were used.")
    }
}

extension JSONDecoder {
    static var withDates: JSONDecoder { let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value }
}
