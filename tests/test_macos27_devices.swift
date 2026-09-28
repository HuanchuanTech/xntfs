import Foundation

// The host runner attaches a disposable MBR image. This executable uses the same
// sandbox, provisioning profile, and production model/service as the app.
@main
struct AttachedDeviceTests {
    @MainActor
    static func main() async throws {
        setbuf(stdout, nil)
        let status = ExtensionStatus()
        await status.refresh()
        let expected = ProcessInfo.processInfo.environment["XNTFS_TEST_EXTENSION"]
        guard status.isEnabled == true, status.installedCount == 1,
              status.moduleURLs.map(\.path) == [expected].compactMap({ $0 }) else {
            throw Failure("Expected one enabled installed extension: \(status.diagnosticReport)")
        }
        print("EXTENSION \(status.moduleURLs[0].path)")
        let name = CommandLine.arguments[1]
        let readOnlyMedia = ProcessInfo.processInfo.environment["XNTFS_TEST_READ_ONLY_MEDIA"] == "1"
        let model = AppModel()
        model.start()
        let original = try await waitForDevice(model, name: name) { !$0.state.isMounted }
        guard original.kind == .diskImage, original.mediaWritable != readOnlyMedia, original.registryEntryID != nil else {
            throw Failure("Unexpected disposable image media properties")
        }
        var stale = original
        stale.registryEntryID = original.registryEntryID! ^ 1
        let monitor = DiskArbitrationMonitor()!
        if case .mounted = await MountService(monitor: monitor).unifiedMount(stale, readOnly: true) {
            throw Failure("A stale I/O Registry identity was accepted")
        }
        print("PASS stale device identity rejected")

        for phase in readOnlyMedia ? ["ro"] : ["ro", "rw", "remount-ro"] {
            let device = try await waitForDevice(model, name: name) { !$0.state.isMounted }
            let readOnly = phase != "rw"
            guard case .mounted(let url) = await model.mount(device, readOnly: readOnly && !readOnlyMedia) else {
                throw Failure("Mount failed: \(model.devices.first { $0.id == name }?.state.descriptionForTest ?? "device missing")")
            }
            let mounted = try await waitForDevice(model, name: name) { $0.state.isMounted }
            guard mounted.mountedByXntfs, mounted.readOnly == readOnly else { throw Failure("Wrong driver or access mode") }
            if case .mounted = await model.mount(mounted, readOnly: !readOnly) {
                throw Failure("Accepted a duplicate mount")
            }
            let reopened = AppModel()
            reopened.start()
            let recovered = try await waitForDevice(reopened, name: name) { $0.state.isMounted }
            guard recovered.mountedByXntfs, recovered.readOnly == readOnly else { throw Failure("Incorrect recovered mount") }
            try hostCheck(["phase": phase, "mountPath": url.path])
            await model.unmount(mounted)
            _ = try await waitForDevice(model, name: name) { $0.state == .unmounted }
            guard model.lastError == nil else { throw Failure(model.lastError!) }
            if phase == "ro" { try hostCheck(["phase": "unmount-ro"]) }
            print("PASS \(phase): attached partition, model state, actual mode, recovery, duplicate rejection, unmount")
        }
    }

    @MainActor
    static func waitForDevice(_ model: AppModel, name: String,
                              matching predicate: (NTFSDevice) -> Bool) async throws -> NTFSDevice {
        for _ in 0..<100 {
            if let device = model.devices.first(where: { $0.id == name }), predicate(device) { return device }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure("Device state did not settle: \(name)")
    }

    static func hostCheck(_ values: [String: String]) throws {
        let json = try JSONSerialization.data(withJSONObject: values)
        print("CHECK " + String(decoding: json, as: UTF8.self))
        guard readLine() == "ok" else { throw Failure("Host verification failed") }
    }
}

private extension MountState {
    var descriptionForTest: String { String(describing: self) }
}

private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
