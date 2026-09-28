//
//  AppModel.swift
//  Central coordinator: owns settings, the DiskArbitration monitor and the mount service,
//  exposes detected devices, direct image mounts, and the actions the UI calls.
//

import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    let settings = AppSettings()
    /// All NTFS volumes the monitor knows about — physical and image-backed (kind == .diskImage).
    private(set) var devices: [NTFSDevice] = []
    private(set) var mountedImages: [MountedImage] = []
    private(set) var unmountingImages: Set<String> = []
    private(set) var mountingImage = false
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
        mountedImages = ImageMountService.mountedImages()
        guard !started, let monitor else { return }
        started = true
        monitor.onDevicesChanged = { [weak self] list in
            guard let self else { return }
            // Preserve any locally-tracked transitional state so a DA "changed" event
            // mid-transition can't clobber it — e.g. revert .unmounting back to .mounted
            // and make the Eject button clickable again.
            self.devices = list.map { incoming in
                if let existing = self.devices.first(where: { $0.id == incoming.id && $0.registryEntryID == incoming.registryEntryID }) {
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

    func refreshDevices() {
        monitor?.refresh()
        mountedImages = ImageMountService.mountedImages()
    }

    @available(macOS 27.0, *)
    func mountImage(_ source: URL, readOnly: Bool) async throws -> URL {
        guard !mountingImage else { throw POSIXError(.EBUSY) }
        mountingImage = true
        defer {
            mountingImage = false
            refreshDevices()
        }
        return try await ImageMountService.mount(source, readOnly: readOnly)
    }

    func unmountImage(_ image: MountedImage) async {
        guard unmountingImages.insert(image.id).inserted else { return }
        defer {
            unmountingImages.remove(image.id)
            refreshDevices()
        }
        do { try await ImageMountService.unmount(image) }
        catch { setError(ImageMountService.diagnosticMessage(error)) }
    }

    /// Mount a device/image volume (in-app only on macOS 27+). Returns the outcome so the
    /// mount sheet can surface an error.
    @discardableResult
    func mount(_ device: NTFSDevice, readOnly: Bool) async -> MountOutcome {
        guard let mounter else { let m = "DiskArbitration unavailable"; setError(m); return .failed(m) }
        guard let current = devices.first(where: { $0.id == device.id && $0.registryEntryID == device.registryEntryID }) else {
            return .failed(MountError.diskNotFound(device.id).localizedDescription)
        }
        switch current.state {
        case .mounting, .unmounting: return .failed(POSIXError(.EBUSY).localizedDescription)
        case .mounted: return .failed(MountError.alreadyMounted.localizedDescription)
        default: break
        }
        updateState(device.id, .mounting)
        let outcome = await mounter.unifiedMount(device, readOnly: readOnly)
        if let index = devices.firstIndex(where: { $0.id == device.id && $0.registryEntryID == device.registryEntryID }) {
            switch outcome {
            case .mounted(let url):
                devices[index].state = .mounted(url)
                if let info = DiskArbitrationMonitor.mountInfo(url) {
                    devices[index].readOnly = info.readOnly
                    devices[index].mountedByXntfs = info.fsType == DiskArbitrationMonitor.moduleFSType
                }
            case .failed(let msg): devices[index].state = .failed(msg)
            }
        }
        refreshDevices()
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
