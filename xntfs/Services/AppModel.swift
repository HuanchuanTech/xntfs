//
//  AppModel.swift
//  Central coordinator: owns settings, the DiskArbitration monitor and the mount
//  service, exposes the device list and the high-level actions the UI calls.
//

import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    let settings = AppSettings()
    private(set) var devices: [NTFSDevice] = []
    /// BSD names this app mounted itself (vs. volumes the system auto-mounted).
    private(set) var appMountedIDs: Set<String> = []
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
            // Preserve any locally-tracked transitional states (mounting/unmounting).
            self.devices = list.map { incoming in
                if let existing = self.devices.first(where: { $0.id == incoming.id }),
                   case .mounting = existing.state { return existing }
                return incoming
            }
            // Drop app-mounted marks for volumes that are gone or no longer mounted.
            self.appMountedIDs = self.appMountedIDs.filter { id in
                self.devices.contains { $0.id == id && $0.state.isMounted }
            }
        }
        monitor.start()
        devices = monitor.currentDevices
    }

    // MARK: actions

    func mount(_ device: NTFSDevice, to target: URL?, readOnly: Bool) async {
        await performMount(device, to: target, readOnly: readOnly)
    }

    private func performMount(_ device: NTFSDevice, to target: URL?, readOnly: Bool) async {
        guard let mounter else { setError("DiskArbitration unavailable"); return }
        updateState(device.id, .mounting)
        do {
            let mounted = try await mounter.mount(device, at: target, readOnly: readOnly)
            appMountedIDs.insert(device.id)
            updateState(device.id, .mounted(mounted))
        } catch {
            updateState(device.id, .failed(error.localizedDescription))
            setError(error.localizedDescription)
        }
    }

    func unmount(_ device: NTFSDevice, force: Bool = false) async {
        guard let mounter else { return }
        updateState(device.id, .unmounting)
        do {
            try await mounter.unmount(device, force: force)
            appMountedIDs.remove(device.id)
            updateState(device.id, .unmounted)
        } catch {
            updateState(device.id, .failed(error.localizedDescription))
            setError(error.localizedDescription)
        }
    }

    /// Mount an NTFS image file (source). With `target == nil` it mounts into /Volumes
    /// (directly on macOS 27+); a custom `target` yields a copyable Terminal command.
    func mountImage(source: URL, target: URL?, readOnly: Bool) async -> ImageMountOutcome {
        guard let mounter else { return .failed("DiskArbitration unavailable") }
        let outcome = await mounter.mountImage(source: source, target: target, readOnly: readOnly)
        if case .failed(let message) = outcome { setError(message) }
        return outcome
    }

    // MARK: helpers

    private func updateState(_ id: String, _ state: MountState) {
        if let idx = devices.firstIndex(where: { $0.id == id }) {
            devices[idx].state = state
        }
    }

    private func setError(_ message: String) { lastError = message }
    func clearError() { lastError = nil }
}
