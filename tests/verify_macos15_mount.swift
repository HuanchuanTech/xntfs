import Foundation
import Darwin

enum CheckError: Error { case invalid(String) }

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckError.invalid(message) }
}

func plist(_ path: String) throws -> Any {
    try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)),
                                              format: nil)
}

let args = Array(CommandLine.arguments.dropFirst())
do {
    switch args.first {
    case "attach":
        let info = try plist(args[1]) as! [String: Any]
        let entities = info["system-entities"] as! [[String: Any]]
        let whole = entities.first { $0["content-hint"] as? String == "FDisk_partition_scheme" }?["dev-entry"] as! String
        let part = entities.first { $0["content-hint"] as? String == "Windows_NTFS" }?["dev-entry"] as! String
        try require(whole.range(of: #"^/dev/disk[0-9]+$"#, options: .regularExpression) != nil && part == whole + "s1",
                    "Expected an MBR fixture with NTFS in partition 1")
        print("\(whole) \(part.dropFirst(5))")
    case "media":
        var matches: [[String: Any]] = []
        func walk(_ nodes: [[String: Any]]) {
            for node in nodes {
                if node["IOObjectClass"] as? String == "IOMedia", node["BSD Name"] as? String == args[2] {
                    matches.append(node)
                }
                walk(node["IORegistryEntryChildren"] as? [[String: Any]] ?? [])
            }
        }
        walk(try plist(args[1]) as! [[String: Any]])
        try require(matches.count == 1, "Expected one IOMedia connection")
        print("\(matches[0]["IORegistryEntryID"] as! UInt64) \(matches[0]["Size"] as! UInt64)")
    case "point":
        let info = try plist(args[1]) as! [String: Any]
        guard let path = info["MountPoint"] as? String, path.hasPrefix("/Volumes/") else {
            throw CheckError.invalid("No mounted volume under /Volumes")
        }
        print(path)
    case "attachment":
        try require(args.count == 5, "attachment INFO_PLIST OWNED_IMAGE WHOLE PARTITION")
        let expected = URL(fileURLWithPath: args[2]).resolvingSymlinksInPath().path
        let info = try plist(args[1]) as? [String: Any] ?? [:]
        let images = info["images"] as? [[String: Any]] ?? []
        let matches = images.filter {
            guard let path = $0["image-path"] as? String else { return false }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path == expected
        }
        try require(matches.count == 1, "Exactly one current attachment for the owned image is required")
        let devices = (matches[0]["system-entities"] as? [[String: Any]] ?? [])
            .compactMap { $0["dev-entry"] as? String }
        try require(args[3].range(of: #"^/dev/disk[0-9]+$"#, options: .regularExpression) != nil
                    && "/dev/" + args[4] == args[3] + "s1"
                    && devices.contains(args[3]) && devices.contains("/dev/" + args[4]),
                    "Current whole/partition devices must belong to the owned image")
        print("PASS: current attachment belongs to the owned image")
    case "check":
        try require(getuid() != 0, "Host I/O checks must run as the desktop user")
        let phase = args[1], path = args[2], device = args[3]
        var info = statfs()
        guard statfs(path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let type = withUnsafeBytes(of: info.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let source = withUnsafeBytes(of: info.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        try require(path.hasPrefix("/Volumes/") && type == "xntfs" && source == "/dev/\(device)",
                    "Wrong mount: path=\(path), type=\(type), source=\(source)")
        let readOnly = info.f_flags & UInt32(MNT_RDONLY) != 0
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let target = root.appendingPathComponent("unified-flow-persisted.txt")
        let payload = Data("macOS 15 unified load/activate persistence test\n".utf8)
        if phase == "rw" {
            try require(!readOnly, "Writable request remained read-only")
            let staging = root.appendingPathComponent("unified-flow-staging.txt")
            try payload.write(to: staging)
            let handle = try FileHandle(forWritingTo: staging)
            do {
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            print("PASS: explicit file sync and close")
            try FileManager.default.moveItem(at: staging, to: target)
            try require(try Data(contentsOf: target) == payload, "Readback differs")
        } else {
            try require(readOnly, "Read-only mount flag is absent")
            if phase == "remount-ro" || phase == "media-ro" {
                try require(try Data(contentsOf: target) == payload, "Data did not survive unmount/remount")
            }
            let forbidden = root.appendingPathComponent("unified-flow-must-not-write.txt")
            let fd = open(forbidden.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            if fd >= 0 {
                close(fd)
                try? FileManager.default.removeItem(at: forbidden)
                throw CheckError.invalid("Read-only volume accepted a write")
            }
            try require(errno == EROFS, "Expected EROFS, got errno \(errno)")
        }
        print("PASS host I/O: \(phase), type=\(type), readOnly=\(readOnly), source=\(source)")
    default:
        throw CheckError.invalid("Use attach, media, point, or check")
    }
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
