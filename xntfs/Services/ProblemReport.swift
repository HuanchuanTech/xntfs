import Foundation
import Darwin

nonisolated struct ProblemReport: Codable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let createdAt: Date
    let description: String
    let steps: String
    let contactEmail: String?
    let diagnostics: DiagnosticSnapshot?

    init(description: String, steps: String, contactEmail: String, diagnostics: DiagnosticSnapshot?) {
        schemaVersion = 1
        id = UUID()
        createdAt = Date()
        self.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        self.steps = steps.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = contactEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        self.contactEmail = email.isEmpty ? nil : email
        self.diagnostics = diagnostics
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    var eventID: String { id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
}

nonisolated struct DiagnosticSnapshot: Codable, Sendable {
    let capturedAt: Date
    let appVersion: String
    let appBuild: String
    let osVersion: String
    let osBuild: String
    let hardwareModel: String
    let processArchitecture: String
    let translated: Bool
    let appLocation: String
    let extensionState: String
    let registrationCount: Int?
    let registrationLocations: [String]
    let queryErrors: [DiagnosticError]
    let deviceReadOnlyDefault: Bool
    let imageReadOnlyDefault: Bool
    let devices: [Device]
    let history: DiagnosticHistory

    struct Device: Codable, Sendable {
        let device: String
        let kind: String
        let state: String
        let driver: String
        let readOnly: Bool
        let mediaWritable: Bool?
        let capacityBytes: UInt64
    }

    static func location(_ url: URL) -> String {
        // Classify registration issues without exporting usernames or build paths.
        if url.path.hasPrefix("/Applications/") { return "Applications" }
        if url.path.contains("/DerivedData/") { return "DerivedData" }
        if url.path.contains("/AppTranslocation/") { return "AppTranslocation" }
        return "other"
    }

    static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size < 1024 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: bytes)
    }

    static var isTranslated: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("sysctl.proc_translated", &value, &size, nil, 0) == 0 && value == 1
    }
}

extension DiagnosticSnapshot {
    @MainActor
    static func capture(model: AppModel) async -> DiagnosticSnapshot {
        let status = ExtensionStatus()
        await status.refresh()
        // The ordinary UI refresh is fire-and-forget. Await a separate read-only
        // observation so the snapshot does not capture the previous UI state.
        let currentDevices = await model.devicesForDiagnostics()
        let currentImages = ImageMountService.mountedImages()
        // Copy current state before yielding to the recorder. Historical events keep
        // their own timestamps; a refresh must not rewrite a failed attempt's facts.
        let capturedAt = Date()
        var devices = currentDevices.map { device in
            Device(device: device.id, kind: device.diagnosticKind, state: device.diagnosticState,
                   driver: device.diagnosticDriver, readOnly: device.readOnly,
                   mediaWritable: device.mediaWritable, capacityBytes: device.sizeBytes)
        }
        devices += currentImages.enumerated().map { index, image in
            Device(device: "direct-image-\(index + 1)", kind: "directImage", state: "mounted",
                   driver: "xntfs", readOnly: image.readOnly, mediaWritable: nil,
                   capacityBytes: image.sizeBytes)
        }
        let state = String(describing: status.state)
        let count = ExtensionStatus.needsLegacyCompatibility || status.queryError != nil ? nil : status.installedCount
        let locations = status.moduleURLs.map(location)
        let errors = DiagnosticError.chain(status.queryError)
        let deviceRO = model.settings.deviceReadOnly
        let imageRO = model.settings.imageReadOnly
        let history = await DiagnosticRecorder.shared.snapshot()
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return DiagnosticSnapshot(capturedAt: capturedAt,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString, osBuild: sysctlString("kern.osversion"),
            hardwareModel: sysctlString("hw.model"), processArchitecture: architecture, translated: isTranslated,
            appLocation: location(Bundle.main.bundleURL), extensionState: state, registrationCount: count,
            registrationLocations: locations, queryErrors: errors,
            deviceReadOnlyDefault: deviceRO, imageReadOnlyDefault: imageRO, devices: devices, history: history)
    }
}

extension NTFSDevice {
    var diagnosticKind: String {
        switch kind { case .removable: "removable"; case .diskImage: "diskImage"; case .fixed: "fixed" }
    }
    var diagnosticState: String {
        switch state {
        case .unmounted: "unmounted"
        case .mounting: "mounting"
        case .mounted: "mounted"
        case .unmounting: "unmounting"
        case .failed: "failed"
        }
    }
    var diagnosticDriver: String {
        switch mountDriver { case .xntfs: "xntfs"; case .system: "system"; case .other: "other"; case .unknown: "unknown" }
    }
    var diagnosticFields: [DiagnosticEvent.Field: String] {
        [.device: id, .kind: diagnosticKind, .state: diagnosticState, .driver: diagnosticDriver,
         .effectiveReadOnly: String(readOnly), .mediaWritable: String(mediaWritable)]
    }
}
