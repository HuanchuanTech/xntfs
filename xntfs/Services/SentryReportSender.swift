import Foundation

nonisolated struct SentryDestination: Sendable {
    let endpoint: URL
    let publicKey: String
    let displayName: String

    init(dsn: String) throws {
        guard var url = URLComponents(string: dsn), url.scheme == "https",
              let host = url.host, !host.isEmpty,
              let key = url.user, key.range(of: #"^[A-Za-z0-9]+$"#, options: .regularExpression) != nil,
              url.password == nil, url.query == nil, url.fragment == nil else { throw ReportSendError.invalidConfiguration }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false)
        guard let project = parts.last, !project.isEmpty, project.allSatisfy({ $0.isASCII && $0.isNumber }),
              !parts.contains(".."), !parts.contains(".") else { throw ReportSendError.invalidConfiguration }
        publicKey = key
        displayName = "\(host) / \(project)"
        url.user = nil
        url.path = parts.dropLast().joined(separator: "/") + "/api/\(project)/envelope/"
        guard let endpoint = url.url else { throw ReportSendError.invalidConfiguration }
        self.endpoint = endpoint
    }

    static func configured(in bundle: Bundle = .main) -> SentryDestination? {
        guard let dsn = bundle.object(forInfoDictionaryKey: "XNTFSSentryDSN") as? String,
              !dsn.isEmpty else { return nil }
        return try? SentryDestination(dsn: dsn)
    }
}

nonisolated enum ReportSendError: LocalizedError {
    case invalidConfiguration, consentRequired, tooLarge, invalidResponse, rateLimited, attachmentUnconfirmed, rejected(Int)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: String(localized: "Online sending is not configured in this build. You can export the report.")
        case .consentRequired: String(localized: "Review the report and confirm before sending.")
        case .tooLarge: String(localized: "The report exceeds the 512 KB limit. Shorten the description or exclude diagnostics.")
        case .invalidResponse: String(localized: "Delivery could not be confirmed. Export the report or try again later.")
        case .rateLimited: String(localized: "The receiving service has reached a limit. Export the report or try again later.")
        case .attachmentUnconfirmed: String(localized: "The service may have accepted the feedback without its attachment. Please export the report as a backup.")
        case .rejected(let status): String(localized: "The receiving service rejected the report (HTTP \(status)). You can export it instead.")
        }
    }
}

nonisolated enum SentryReportSender {
    static let maximumReportBytes = 512 * 1024

    static func envelope(report: ProblemReport, data: Data) throws -> Data {
        guard data.count <= maximumReportBytes else { throw ReportSendError.tooLarge }
        var feedback: [String: Any] = ["message": report.description + (report.steps.isEmpty ? "" : "\n\n" + report.steps), "source": "custom"]
        if let email = report.contactEmail { feedback["contact_email"] = email }
        let event: [String: Any] = ["event_id": report.eventID, "type": "feedback", "platform": "cocoa",
                                    "timestamp": report.createdAt.timeIntervalSince1970,
                                    "contexts": ["feedback": feedback]]
        let payload = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        var envelope = try JSONSerialization.data(withJSONObject: ["event_id": report.eventID,
                    "sent_at": ISO8601DateFormatter().string(from: Date())], options: [.sortedKeys])
        envelope.append(10)
        func append(_ header: [String: Any], _ body: Data) throws {
            envelope.append(try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]))
            envelope.append(10)
            envelope.append(body)
            envelope.append(10)
        }
        try append(["type": "feedback", "length": payload.count], payload)
        try append(["type": "attachment", "length": data.count, "filename": "xntfs-report.json",
                    "content_type": "application/json", "attachment_type": "event.attachment"], data)
        return envelope
    }

    static func request(report: ProblemReport, data: Data, destination: SentryDestination,
                        consent: Bool) throws -> URLRequest {
        guard consent else { throw ReportSendError.consentRequired }
        var request = URLRequest(url: destination.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-sentry-envelope", forHTTPHeaderField: "Content-Type")
        request.setValue("Sentry sentry_version=7, sentry_key=\(destination.publicKey), sentry_client=xntfs-manual-report/1", forHTTPHeaderField: "X-Sentry-Auth")
        request.setValue("xntfs-manual-report/1", forHTTPHeaderField: "User-Agent")
        request.httpBody = try envelope(report: report, data: data)
        return request
    }

    static func validateResponse(_ response: HTTPURLResponse) throws {
        if response.statusCode == 429 { throw ReportSendError.rateLimited }
        guard (200..<300).contains(response.statusCode) else { throw ReportSendError.rejected(response.statusCode) }
        // A 2xx response can still contain per-category quota rejections.
        if let limits = response.value(forHTTPHeaderField: "X-Sentry-Rate-Limits") {
            for quota in limits.split(separator: ",") {
                let parts = quota.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
                guard parts.count >= 2, (Double(parts[0]) ?? 0) > 0 else { continue }
                let categories = Set(parts[1].split(separator: ";").map(String.init))
                if categories.isEmpty || !categories.isDisjoint(with: ["attachment", "feedback", "user_report"]) {
                    throw ReportSendError.attachmentUnconfirmed
                }
            }
        }
    }

    static func send(report: ProblemReport, data: Data, destination: SentryDestination, consent: Bool,
                     configuration: URLSessionConfiguration = .ephemeral) async throws {
        let request = try request(report: report, data: data, destination: destination, consent: consent)
        let config = configuration
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForResource = 40
        let session = URLSession(configuration: config, delegate: NoReportRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw ReportSendError.invalidResponse }
        try validateResponse(response)
        var body = Data()
        for try await byte in bytes {
            guard body.count < 64 * 1024 else { throw ReportSendError.invalidResponse }
            body.append(byte)
        }
        guard let result = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              (result["id"] as? String)?.lowercased() == report.eventID else { throw ReportSendError.invalidResponse }
        // This confirms HTTP acceptance, not retention, attachment processing or human review.
    }
}

nonisolated private final class NoReportRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
