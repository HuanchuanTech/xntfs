import Foundation
import Darwin

/// Generates text only. The sandboxed app never starts a shell or requests root.
enum LegacyMountCommand {
    static var scriptURL: URL? {
        Bundle.main.url(forResource: "macos15-mount", withExtension: "sh")
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func bootSessionUUID() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0,
              let uuid = UUID(uuidString: String(cString: bytes)) else { return nil }
        return uuid.uuidString
    }

    static func mount(device: NTFSDevice, readOnly: Bool, script: URL, app: URL, bootSession: String) -> String? {
        guard device.id.range(of: #"^disk[0-9]+(?:s[0-9]+)*$"#, options: .regularExpression) != nil,
              let entryID = device.registryEntryID, entryID > 0, entryID <= 9_007_199_254_740_991,
              device.sizeBytes > 0, device.sizeBytes <= 9_007_199_254_740_991,
              let boot = UUID(uuidString: bootSession), script.isFileURL, app.isFileURL else { return nil }
        return (["/bin/bash", quote(script.path), "mount", quote(device.id), String(entryID),
                 String(device.sizeBytes), quote(boot.uuidString), readOnly || !device.mediaWritable ? "ro" : "auto",
                 quote(app.path)]).joined(separator: " ")
    }

    static var cleanup: String? {
        scriptURL.map { "/bin/bash \(quote($0.path)) cleanup" }
    }
}
