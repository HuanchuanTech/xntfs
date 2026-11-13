//
//  AppModel.swift
//  Central coordinator: owns settings, the DiskArbitration monitor and the mount service,
//  exposes detected devices, direct image mounts, and the actions the UI calls.
//
//  Copyright (C) 2026 Aïssa BELKOUSSA — modified 2026-10-03: sandbox-denied mount fallback.
//

import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    /// All NTFS volumes the monitor knows about — physical and image-backed (kind == .diskImage).
    private(set) var devices: [NTFSDevice] = []
    private(set) var mountedImages: [MountedImage] = []
    private(set) var unmountingImages: Set<String> = []
    private(set) var mountingImage = false
    var lastError: String?

    private let monitor: DiskArbitrationMonitor?
    private let mounter: (any DeviceMounting)?
    private var unmountAttempts: [String: (device: NTFSDevice, token: UUID)] = [:]
    private var started = false

    convenience init() {
        self.init(monitor: DiskArbitrationMonitor())
    }

    init(monitor: DiskArbitrationMonitor?,
         mounter: (any DeviceMounting)? = nil, settings: AppSettings? = nil) {
        self.settings = settings ?? AppSettings()
        self.monitor = monitor
        self.mounter = mounter ?? monitor.map { MountService(monitor: $0) }
    }

    func start() {
        mountedImages = ImageMountService.mountedImages()
        guard !started else { return }
        started = true
        DiagnosticRecorder.shared.record(.appStart, .observed,
            fields: [.state: monitor == nil ? "diskArbitrationUnavailable" : "ready"])
        guard let monitor else { return }
        monitor.onDevicesChanged = { [weak self] list in self?.receiveDevices(list) }
        monitor.start()
        devices = monitor.currentDevices
    }

    func receiveDevices(_ list: [NTFSDevice]) {
        unmountAttempts = unmountAttempts.filter { _, attempt in
            list.contains { $0.isSameDevice(as: attempt.device) }
        }
        for device in list {
            let previous = devices.first { $0.isSameDevice(as: device) }
            if previous?.diagnosticFields != device.diagnosticFields {
                DiagnosticRecorder.shared.record(.deviceObserved, .observed, fields: device.diagnosticFields)
            }
        }
        // Preserve transitions only for the same observation of the same media.
        devices = list.map { incoming in
            if let existing = devices.first(where: { $0.isSameDevice(as: incoming) }) {
                switch existing.state {
                case .mounting, .unmounting: return existing
                default: break
                }
            }
            return incoming
        }
    }

    // MARK: actions

    func refreshDevices() {
        monitor?.refresh()
        mountedImages = ImageMountService.mountedImages()
    }

    func devicesForDiagnostics() async throws -> DiskArbitrationMonitor.DiagnosticObservation {
        guard let monitor else { return .init(devices: [], isComplete: false) }
        return try await monitor.devicesForDiagnostics()
    }

    @available(macOS 27.0, *)
    func mountImage(_ source: URL, readOnly: Bool) async throws -> URL {
        guard !mountingImage else { throw POSIXError(.EBUSY) }
        mountingImage = true
        defer {
            mountingImage = false
            refreshDevices()
        }
        let attempt = UUID().uuidString
        let fields: [DiagnosticEvent.Field: String] = [.kind: "directImage", .requestedReadOnly: String(readOnly), .attempt: attempt]
        DiagnosticRecorder.shared.record(.mount, .started, fields: fields)
        do {
            let url = try await ImageMountService.mount(source, readOnly: readOnly)
            DiagnosticRecorder.shared.record(.mount, .succeeded, fields: fields)
            return url
        } catch {
            DiagnosticRecorder.shared.record(.mount, .failed, fields: fields, error: error)
            throw error
        }
    }

    func unmountImage(_ image: MountedImage) async {
        guard unmountingImages.insert(image.id).inserted else { return }
        defer {
            unmountingImages.remove(image.id)
            refreshDevices()
        }
        DiagnosticRecorder.shared.record(.unmount, .started, fields: [.kind: "directImage"])
        do {
            try await ImageMountService.unmount(image)
            DiagnosticRecorder.shared.record(.unmount, .succeeded, fields: [.kind: "directImage"])
        } catch {
            DiagnosticRecorder.shared.record(.unmount, .failed, fields: [.kind: "directImage"], error: error)
            setError(ImageMountService.diagnosticMessage(error))
        }
    }

    /// Mount a device/image volume (in-app only on macOS 27+). Returns the outcome so the
    /// mount sheet can surface an error.
    @discardableResult
    func mount(_ device: NTFSDevice, readOnly: Bool) async -> MountOutcome {
        guard let mounter else { let m = "DiskArbitration unavailable"; setError(m); return .failed(m) }
        guard let current = devices.first(where: { $0.isSameDevice(as: device) }) else {
            return .failed(MountError.diskNotFound(device.id).localizedDescription)
        }
        switch current.state {
        case .mounting, .unmounting: return .failed(POSIXError(.EBUSY).localizedDescription)
        case .mounted: return .failed(MountError.alreadyMounted.localizedDescription)
        default: break
        }
        updateState(device.id, .mounting)
        let outcome = await mounter.unifiedMount(device, readOnly: readOnly)
        if let index = devices.firstIndex(where: { $0.isSameDevice(as: device) }) {
            switch outcome {
            case .mounted(let url):
                devices[index].state = .mounted(url)
                let info = DiskArbitrationMonitor.mountInfo(url, matchingSource: device.devicePath)
                devices[index].readOnly = info?.readOnly ?? false
                devices[index].mountedFileSystemType = info?.fsType
            case .failed(let msg), .needsSystemMount(let msg, _): devices[index].state = .failed(msg)
            }
        }
        refreshDevices()
        return outcome
    }

    func unmount(_ device: NTFSDevice, force: Bool = false) async {
        guard let mounter, let index = devices.firstIndex(where: { $0.isSameDevice(as: device) }),
              unmountAttempts[device.id] == nil else { return }
        switch devices[index].state {
        case .mounting, .unmounting: return
        default: break
        }
        let token = UUID()
        unmountAttempts[device.id] = (device, token)
        defer { if unmountAttempts[device.id]?.token == token { unmountAttempts.removeValue(forKey: device.id) } }
        DiagnosticRecorder.shared.record(.unmount, .started, fields: device.diagnosticFields)
        updateState(device.id, .unmounting)
        do {
            try await mounter.unmount(device, force: force)
            guard unmountAttempts[device.id]?.token == token,
                  let index = devices.firstIndex(where: { $0.isSameDevice(as: device) }) else { return }
            DiagnosticRecorder.shared.record(.unmount, .succeeded, fields: [.device: device.id])
            devices[index].state = .unmounted
        } catch {
            guard unmountAttempts[device.id]?.token == token,
                  let index = devices.firstIndex(where: { $0.isSameDevice(as: device) }) else { return }
            DiagnosticRecorder.shared.record(.unmount, .failed, fields: [.device: device.id], error: error)
            devices[index].state = .failed(error.localizedDescription)
            setError(error.localizedDescription)
        }
    }

    // MARK: helpers

    private func updateState(_ id: String, _ state: MountState) {
        if let i = devices.firstIndex(where: { $0.id == id }) { devices[i].state = state }
    }

    private func setError(_ message: String) { lastError = message }
    func clearError() { lastError = nil }
}
