import Foundation
import Darwin

// Shared by the host and extension. Never pass paths, labels, UUIDs, file contents,
// NSError.userInfo or localized error descriptions into this recorder.
nonisolated struct DiagnosticEvent: Codable, Sendable {
    enum Action: String, Codable { case appStart, deviceObserved, extensionQuery, mount, unmount, probe, load, activate, check, unload, sync }
    enum Phase: String, Codable { case started, succeeded, failed, observed }
    enum Field: String { case device, kind, requestedReadOnly, effectiveReadOnly, mediaWritable, driver, state, count, source, reason, attempt }

    let id: UUID
    let time: Date
    let process: UUID
    let component: String
    let version: String
    let build: String
    let action: Action
    let phase: Phase
    let fields: [String: String]
    let errors: [DiagnosticError]

    init(action: Action, phase: Phase, fields: [Field: String] = [:], error: Error? = nil,
         process: UUID, component: String, time: Date = Date()) {
        id = UUID()
        self.time = time
        self.process = process
        self.component = component
        version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        self.action = action
        self.phase = phase
        self.fields = Dictionary(uniqueKeysWithValues: fields.map { key, value in
            let pattern = key == .device ? #"^(?:r?disk[0-9]+(?:s[0-9]+)*)$"# : #"^[A-Za-z0-9_.-]{1,64}$"#
            return (key.rawValue, value.range(of: pattern, options: .regularExpression) == nil ? "omitted" : value)
        })
        errors = DiagnosticError.chain(error)
    }
}

nonisolated struct DiagnosticError: Codable, Sendable {
    let domain: String
    let code: Int
    let hex: String

    init(_ error: NSError) {
        domain = error.domain.range(of: #"^[A-Za-z0-9_.-]{1,128}$"#, options: .regularExpression) == nil
            ? "other" : error.domain
        code = error.code
        hex = String(format: "0x%08X", UInt32(truncatingIfNeeded: code))
    }

    static func chain(_ error: Error?) -> [DiagnosticError] {
        var result: [DiagnosticError] = []
        var current = error as NSError?
        // Bound cycles and never serialize arbitrary userInfo (it often contains URLs).
        while let value = current, result.count < 3 {
            result.append(DiagnosticError(value))
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return result
    }
}

nonisolated struct DiagnosticHistory: Codable, Sendable {
    let events: [DiagnosticEvent]
    let storage: String
    let warning: String?
    let droppedInThisProcess: Int
}

nonisolated final class DiagnosticRecorder: @unchecked Sendable {
    static let groupID = "529LJDH392.group.com.huanchuan.xntfs"
    static let maximumEvents = 400
    static let maximumBytes = 512 * 1024
    static let retention: TimeInterval = 7 * 24 * 60 * 60
    static let shared: DiagnosticRecorder = {
        let productionBundle = ["com.huanchuan.xntfs", "com.huanchuan.xntfs.ntfs3g"].contains(Bundle.main.bundleIdentifier ?? "")
        let root = productionBundle ? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) : nil
        return DiagnosticRecorder(directory: root?.appendingPathComponent("Library/Application Support/Diagnostics", isDirectory: true),
                                  component: Bundle.main.bundleURL.pathExtension == "appex" ? "extension" : "app")
    }()

    private let directory: URL?
    private let component: String
    private let process = UUID()
    private let queue = DispatchQueue(label: "com.huanchuan.xntfs.diagnostics", qos: .utility)
    private let pendingLock = NSLock()
    private var pending = 0
    private var dropped = 0
    private var warning: String?
    private var memory: [DiagnosticEvent] = []

    init(directory: URL?, component: String) {
        self.directory = directory
        self.component = component
    }

    func record(_ action: DiagnosticEvent.Action, _ phase: DiagnosticEvent.Phase,
                fields: [DiagnosticEvent.Field: String] = [:], error: Error? = nil) {
        pendingLock.lock()
        guard pending < 64 else { dropped += 1; pendingLock.unlock(); return }
        pending += 1
        pendingLock.unlock()
        let event = DiagnosticEvent(action: action, phase: phase, fields: fields, error: error,
                                    process: process, component: component)
        queue.async { [self] in
            defer { pendingLock.lock(); pending -= 1; pendingLock.unlock() }
            memory = Array((memory + [event]).suffix(Self.maximumEvents))
            do {
                try withStore { url in
                    let persisted = try read(url)
                    let ids = Set(persisted.map(\.id))
                    var events = retained(persisted + memory.filter { !ids.contains($0.id) })
                    var data = try JSONEncoder().encode(events)
                    while data.count > Self.maximumBytes, !events.isEmpty {
                        events.removeFirst()
                        data = try JSONEncoder().encode(events)
                    }
                    try data.write(to: url, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                }
            } catch { warning = storageError(error) }
        }
    }

    func snapshot() async -> DiagnosticHistory {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                var events = retained(memory)
                do {
                    try withStore { url in
                        let persisted = retained(try read(url))
                        let ids = Set(persisted.map(\.id))
                        events = retained(persisted + events.filter { !ids.contains($0.id) })
                        // Expired entries are also removed when making a report.
                        try JSONEncoder().encode(persisted).write(to: url, options: .atomic)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    }
                } catch { warning = storageError(error) }
                pendingLock.lock()
                let droppedCount = dropped
                pendingLock.unlock()
                continuation.resume(returning: DiagnosticHistory(events: events,
                    storage: directory == nil ? "process-memory-only" : "app-group",
                    warning: warning, droppedInThisProcess: droppedCount))
            }
        }
    }

    private func retained(_ events: [DiagnosticEvent]) -> [DiagnosticEvent] {
        Array(events.filter { $0.time >= Date().addingTimeInterval(-Self.retention) }
            .sorted { $0.time < $1.time }.suffix(Self.maximumEvents))
    }

    private func read(_ url: URL) throws -> [DiagnosticEvent] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= Self.maximumBytes else {
            throw POSIXError(.EFBIG)
        }
        do { return try JSONDecoder().decode([DiagnosticEvent].self, from: Data(contentsOf: url)) }
        catch { warning = "invalid-history-replaced"; return [] }
    }

    private func withStore(_ body: (URL) throws -> Void) throws {
        guard let directory else { throw POSIXError(.ENOENT) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let fd = open(directory.appendingPathComponent("history.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        // Never stall a filesystem operation behind another process's diagnostics.
        var locked = false
        for _ in 0..<10 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { locked = true; break }
            usleep(2_000)
        }
        guard locked else { throw POSIXError(.EBUSY) }
        defer { flock(fd, LOCK_UN) }
        try body(directory.appendingPathComponent("history.json"))
    }

    private func storageError(_ error: Error) -> String {
        let code = DiagnosticError(error as NSError)
        return "\(code.domain):\(code.code)"
    }
}
