import Foundation
import Darwin

nonisolated private enum DiagnosticText {
    static func isToken(_ value: String, limit: Int = 64) -> Bool {
        let bytes = value.utf8.prefix(limit + 1)
        return !bytes.isEmpty && bytes.count <= limit && bytes.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) ||
                $0 == 95 || $0 == 46 || $0 == 45
        }
    }

    static func isField(_ value: String, key: DiagnosticEvent.Field) -> Bool {
        guard isToken(value) else { return false }
        return key != .device || value == "omitted" ||
            value.range(of: #"^(?:r?disk[0-9]+(?:s[0-9]+)*)$"#, options: .regularExpression) != nil
    }

    static func copy(_ value: String) -> String {
        // Own only the validated bytes, not an oversized bridged backing string.
        String(decoding: value.utf8, as: UTF8.self)
    }

    static func token(_ value: String, limit: Int = 64, fallback: String = "unknown") -> String {
        isToken(value, limit: limit) ? copy(value) : fallback
    }

    static func invalid(_ decoder: Decoder) -> DecodingError {
        .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid or oversized diagnostic history"))
    }
}

nonisolated private struct DiagnosticFieldKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

// Shared by the host and extension. Never pass paths, labels, UUIDs, file contents,
// NSError.userInfo or localized error descriptions into this recorder.
nonisolated struct DiagnosticEvent: Codable, Sendable {
    enum Action: String, Codable { case appStart, deviceObserved, extensionQuery, mount, unmount, probe, load, activate, check, unload, sync }
    enum Phase: String, Codable { case started, succeeded, failed, observed }
    enum Field: String, CaseIterable { case device, kind, requestedReadOnly, effectiveReadOnly, mediaWritable, driver, state, count, source, reason, attempt }
    static let maximumPayloadBytes = 2 * 1024
    private enum CodingKeys: String, CodingKey {
        case id, time, process, component, version, build, action, phase, fields, errors
    }

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
        self.component = DiagnosticText.token(component, fallback: "other")
        version = DiagnosticText.token(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")
        build = DiagnosticText.token(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")
        self.action = action
        self.phase = phase
        self.fields = Dictionary(uniqueKeysWithValues: fields.map { key, value in
            (key.rawValue, DiagnosticText.isField(value, key: key) ? DiagnosticText.copy(value) : "omitted")
        })
        errors = DiagnosticError.chain(error)
    }

    var payloadBytes: Int {
        component.utf8.count + version.utf8.count + build.utf8.count +
            fields.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count } +
            errors.reduce(0) { $0 + $1.domain.utf8.count + $1.hex.utf8.count }
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        time = try values.decode(Date.self, forKey: .time)
        process = try values.decode(UUID.self, forKey: .process)
        let storedComponent = try values.decode(String.self, forKey: .component)
        let storedVersion = try values.decode(String.self, forKey: .version)
        let storedBuild = try values.decode(String.self, forKey: .build)
        guard time.timeIntervalSinceReferenceDate.isFinite,
              [storedComponent, storedVersion, storedBuild].allSatisfy({ DiagnosticText.isToken($0) }) else {
            throw DiagnosticText.invalid(decoder)
        }
        component = DiagnosticText.copy(storedComponent)
        version = DiagnosticText.copy(storedVersion)
        build = DiagnosticText.copy(storedBuild)
        action = try values.decode(Action.self, forKey: .action)
        phase = try values.decode(Phase.self, forKey: .phase)
        let storedFields = try values.nestedContainer(keyedBy: DiagnosticFieldKey.self, forKey: .fields)
        let keys = storedFields.allKeys
        guard keys.count <= Field.allCases.count else { throw DiagnosticText.invalid(decoder) }
        var decodedFields: [String: String] = [:]
        for key in keys {
            guard let field = Field(rawValue: key.stringValue) else { throw DiagnosticText.invalid(decoder) }
            let value = try storedFields.decode(String.self, forKey: key)
            guard DiagnosticText.isField(value, key: field) else { throw DiagnosticText.invalid(decoder) }
            decodedFields[field.rawValue] = DiagnosticText.copy(value)
        }
        fields = decodedFields
        var storedErrors = try values.nestedUnkeyedContainer(forKey: .errors)
        guard storedErrors.count.map({ $0 <= 3 }) ?? true else { throw DiagnosticText.invalid(decoder) }
        var decodedErrors: [DiagnosticError] = []
        while !storedErrors.isAtEnd {
            guard decodedErrors.count < 3 else { throw DiagnosticText.invalid(decoder) }
            decodedErrors.append(try storedErrors.decode(DiagnosticError.self))
        }
        errors = decodedErrors
        guard payloadBytes <= Self.maximumPayloadBytes else { throw DiagnosticText.invalid(decoder) }
    }
}

nonisolated struct DiagnosticError: Codable, Sendable {
    private enum CodingKeys: String, CodingKey { case domain, code, hex }
    let domain: String
    let code: Int
    let hex: String

    init(_ error: NSError) {
        domain = DiagnosticText.token(error.domain, limit: 128, fallback: "other")
        code = error.code
        hex = String(format: "0x%08X", UInt32(truncatingIfNeeded: code))
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let storedDomain = try values.decode(String.self, forKey: .domain)
        code = try values.decode(Int.self, forKey: .code)
        let storedHex = try values.decode(String.self, forKey: .hex)
        guard DiagnosticText.isToken(storedDomain, limit: 128), storedHex.utf8.prefix(11).count == 10,
              storedHex == String(format: "0x%08X", UInt32(truncatingIfNeeded: code)) else {
            throw DiagnosticText.invalid(decoder)
        }
        domain = DiagnosticText.copy(storedDomain)
        hex = DiagnosticText.copy(storedHex)
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

nonisolated private struct StoredDiagnosticEvents: Decodable {
    let events: [DiagnosticEvent]
    init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        guard values.count.map({ $0 <= DiagnosticRecorder.maximumEvents }) ?? true else {
            throw DiagnosticText.invalid(decoder)
        }
        var decoded: [DiagnosticEvent] = []
        while !values.isAtEnd {
            guard decoded.count < DiagnosticRecorder.maximumEvents else { throw DiagnosticText.invalid(decoder) }
            decoded.append(try values.decode(DiagnosticEvent.self))
        }
        events = decoded
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
    static let maximumPendingEvents = 64
    static let maximumSnapshots = 4
    // Text payload bounds, not Foundation container or process RSS limits.
    static let maximumPendingPayloadBytes = maximumPendingEvents * DiagnosticEvent.maximumPayloadBytes
    static let maximumHistoryPayloadBytes = maximumEvents * DiagnosticEvent.maximumPayloadBytes
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
    // These batches and admission counters are protected by pendingLock. Store
    // state below is confined to queue; no filesystem work holds pendingLock.
    private var pending = 0
    private var pendingSnapshots = 0
    private var dropped = 0
    private var batches: [UInt64: [DiagnosticEvent]] = [:]
    private var openBatch: UInt64?
    private var nextBatch: UInt64 = 0
    private var warning: String?
    private var memory: [DiagnosticEvent] = []

    init(directory: URL?, component: String) {
        self.directory = directory
        self.component = DiagnosticText.token(component, fallback: "other")
    }

    func record(_ action: DiagnosticEvent.Action, _ phase: DiagnosticEvent.Phase,
                fields: [DiagnosticEvent.Field: String] = [:], error: Error? = nil) {
        pendingLock.lock()
        guard pending < Self.maximumPendingEvents else { dropped += 1; pendingLock.unlock(); return }
        pending += 1
        pendingLock.unlock()
        let event = DiagnosticEvent(action: action, phase: phase, fields: fields, error: error,
                                    process: process, component: component)
        pendingLock.lock()
        guard event.payloadBytes <= DiagnosticEvent.maximumPayloadBytes else {
            pending -= 1
            dropped += 1
            pendingLock.unlock()
            return
        }
        if let batch = openBatch {
            batches[batch]!.append(event)
        } else {
            let batch = nextBatch
            // FIFO workers and the 64-event cap retire every old identifier
            // before this counter could wrap around to an outstanding batch.
            nextBatch &+= 1
            batches[batch] = [event]
            openBatch = batch
            queue.async { [self] in persistBatch(batch) }
        }
        pendingLock.unlock()
    }

    private func persistBatch(_ batch: UInt64) {
        pendingLock.lock()
        if openBatch == batch { openBatch = nil }
        let added = batches.removeValue(forKey: batch)!
        pendingLock.unlock()
        defer { pendingLock.lock(); pending -= added.count; pendingLock.unlock() }
        memory = Array((memory + added).suffix(Self.maximumEvents))
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

    func snapshot() async -> DiagnosticHistory {
        await withCheckedContinuation { continuation in
            pendingLock.lock()
            guard pendingSnapshots < Self.maximumSnapshots else {
                let droppedCount = dropped
                pendingLock.unlock()
                continuation.resume(returning: DiagnosticHistory(events: [],
                    storage: directory == nil ? "process-memory-only" : "app-group",
                    warning: "snapshot-capacity-exceeded", droppedInThisProcess: droppedCount))
                return
            }
            pendingSnapshots += 1
            defer { pendingLock.unlock() }
            // Later records must not join an earlier worker and overtake this
            // snapshot. The enqueue and batch cut share the record admission lock.
            openBatch = nil
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
                pendingSnapshots -= 1
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
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return [] }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= Self.maximumBytes else {
            throw POSIXError(.EFBIG)
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        // A non-cooperating writer can grow the file after fstat. Read at most
        // the cap plus one detection byte, never an unchecked read-to-end.
        while data.count <= Self.maximumBytes {
            let remaining = Self.maximumBytes + 1 - data.count
            guard let chunk = try file.read(upToCount: min(64 * 1024, remaining)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= Self.maximumBytes else { throw POSIXError(.EFBIG) }
        do { return try JSONDecoder().decode(StoredDiagnosticEvents.self, from: data).events }
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
