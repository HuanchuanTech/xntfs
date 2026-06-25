//
//  AppModel.swift
//  Central coordinator: owns settings, the DiskArbitration monitor and the mount service,
//  exposes the device/image list (all monitor-detected) and the actions the UI calls.
//

import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    let settings = AppSettings()
    /// All NTFS volumes the monitor knows about — physical and image-backed (kind == .diskImage).
    private(set) var devices: [NTFSDevice] = []
    var lastError: String?

    private let monitor: DiskArbitrationMonitor?
    private let mounter: MountService?
    private var started = false

    init() {
        if let m = DiskArbitrationMonitor() {
            monitor = m
            mounter = MountService(monitor: m)
        } else {
            monitor = nil
            mounter = nil
        }
    }

    func start() {
        guard !started, let monitor else { return }
        started = true
        monitor.onDevicesChanged = { [weak self] list in
            guard let self else { return }
            // Preserve any locally-tracked transitional state so a DA "changed" event
            // mid-transition can't clobber it — e.g. revert .unmounting back to .mounted
            // and make the Eject button clickable again.
            self.devices = list.map { incoming in
                if let existing = self.devices.first(where: { $0.id == incoming.id }) {
                    switch existing.state {
                    case .mounting, .unmounting: return existing
                    default: break
                    }
                }
                return incoming
            }
        }
        monitor.start()
        devices = monitor.currentDevices
    }

    // MARK: actions

    /// Mount a device/image volume (in-app only on macOS 27+). Returns the outcome so the
    /// mount sheet can surface an error.
    @discardableResult
    func mount(_ device: NTFSDevice, readOnly: Bool) async -> MountOutcome {
        guard let mounter else { let m = "DiskArbitration unavailable"; setError(m); return .failed(m) }
        let outcome = await mounter.unifiedMount(device, readOnly: readOnly)
        switch outcome {
        case .mounted(let url): updateState(device.id, .mounted(url))
        case .failed(let msg): updateState(device.id, .failed(msg)); setError(msg)
        }
        return outcome
    }

    func unmount(_ device: NTFSDevice, force: Bool = false) async {
        guard let mounter else { return }
        updateState(device.id, .unmounting)
        do {
            try await mounter.unmount(device, force: force)
            updateState(device.id, .unmounted)
        } catch {
            updateState(device.id, .failed(error.localizedDescription))
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
