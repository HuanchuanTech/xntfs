import Foundation
import CryptoKit

// Opt-in fixture seeded by the release-guard preparation step, never user media.
func checkCompressedWriteGuard(_ volume: URL, writable: Bool) throws {
    let file = volume.appendingPathComponent("xntfs-guard-compressed.bin")
    let empty = volume.appendingPathComponent("xntfs-guard-empty.bin")
    let original = Data(repeating: 67, count: 66236)
    let originalXattr = Data("preserved compressed xattr\n".utf8)
    let key = "com.apple.testCompressed"
    func failed(_ message: String) -> NSError {
        NSError(domain: "CompressedGuard", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: message])
    }
    func rejected(_ operation: String, _ result: Int, _ expected: Int32) throws {
        let error = errno
        print("COMPRESSED GUARD \(operation): result=\(result) errno=\(error)")
        guard result == -1, error == expected else { throw failed("\(operation): result=\(result) errno=\(error), expected=\(expected)") }
    }
    func preserved(_ phase: String) throws {
        var sidecar = stat()
        let result = lstat(volume.appendingPathComponent("._" + file.lastPathComponent).path, &sidecar)
        guard result == -1, errno == ENOENT else { throw failed("\(phase): unexpected AppleDouble sidecar, result=\(result), errno=\(errno)") }
        let current = try Data(contentsOf: file)
        let difference = zip(current, original).enumerated().first { $0.element.0 != $0.element.1 }?.offset
        print("COMPRESSED GUARD \(phase): size=\(current.count), firstDifference=\(String(describing: difference))")
        guard current == original else { throw failed("\(phase): compressed file bytes changed, size=\(current.count), prefix=\(current.prefix(16).map { String(format: "%02x", $0) }.joined())") }
        var value = Data(count: originalXattr.count)
        let count = value.withUnsafeMutableBytes { getxattr(file.path, key, $0.baseAddress, $0.count, 0, 0) }
        guard count == originalXattr.count, value == originalXattr else { throw failed("\(phase): xattr count=\(count), expected=\(originalXattr.count), errno=\(errno)") }
    }
    try preserved("before")
    guard try Data(contentsOf: empty).isEmpty else { throw failed("compressed empty fixture changed") }
    if writable {
        for flags in [O_WRONLY, O_RDWR, O_WRONLY | O_APPEND, O_WRONLY | O_TRUNC, O_WRONLY | O_CREAT] {
            let opened = open(file.path, flags, mode_t(0600))
            if opened >= 0 { close(opened) }
            try rejected("writable open flags=\(flags)", Int(opened), ENOTSUP)
            try preserved("after-open-\(flags)")
        }
        let emptyOpen = open(empty.path, O_RDWR)
        if emptyOpen >= 0 { close(emptyOpen) }
        try rejected("empty writable open", Int(emptyOpen), ENOTSUP)
        // Creation may leave an empty inode when its subsequent open is denied.
        // It must never hand out a writable descriptor for inherited compression.
        let inherited = volume.appendingPathComponent("xntfs-guard-directory/new-file.bin")
        let created = open(inherited.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0600))
        if created >= 0 { close(created) }
        try rejected("inherited compressed create/open", Int(created), ENOTSUP)
        if FileManager.default.fileExists(atPath: inherited.path) {
            guard try Data(contentsOf: inherited).isEmpty else { throw failed("inherited file is not empty") }
            try FileManager.default.removeItem(at: inherited)
        }
        for size in [off_t(0), off_t(original.count + 700)] {
            try rejected("path truncate size=\(size)", Int(truncate(file.path, size)), ENOTSUP)
            try preserved("after-truncate-\(size)")
        }
        let fd = open(file.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard fcntl(fd, F_NOCACHE, 1) == 0 else { throw POSIXError(.EIO) }
        let blocked = Data("blocked".utf8)
        for name in [key, "com.apple.releaseGuardNew"] {
            let result = blocked.withUnsafeBytes { setxattr(file.path, name, $0.baseAddress, $0.count, 0, 0) }
            try rejected("setxattr \(name)", Int(result), EPERM)
        }
        try rejected("removexattr", Int(removexattr(file.path, key, 0)), EPERM)
        let missing = getxattr(file.path, "com.apple.releaseGuardNew", nil, 0, 0, 0)
        guard missing == -1, errno == ENOATTR else { throw failed("new xattr appeared: result=\(missing), errno=\(errno)") }
        let synced = fsync(fd)
        print("COMPRESSED GUARD fsync: result=\(synced) errno=\(errno)")
        guard synced == 0 else { throw failed("fsync after rejection: result=\(synced), errno=\(errno)") }
        try preserved("after")
        print("PASS compressed guard: writable opens, truncate, existing/new xattr and deletion rejected; old bytes and sync preserved, no AppleDouble sidecar")
    } else {
        print("PASS compressed guard: compressed file and xattr readable and unchanged on read-only mount")
    }
}

func checkCaseVariants(_ volume: URL, payload: Data, writable: Bool) throws {
    func failed(_ operation: String) -> NSError {
        NSError(domain: "CaseSemantics", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: operation])
    }
    let exact = volume.appendingPathComponent("MiXeD-integration.txt")
    var original = stat()
    guard stat(exact.path, &original) == 0 else { throw failed("stat original") }
    for name in ["mixed-integration.txt", "MIXED-INTEGRATION.TXT"] {
        let variant = volume.appendingPathComponent(name)
        var attributes = stat()
        guard stat(variant.path, &attributes) == 0 else { throw failed("stat \(name)") }
        guard attributes.st_ino == original.st_ino,
              try Data(contentsOf: variant) == payload else { throw failed("inode/payload mismatch: \(name)") }
        if writable {
            let fd = open(variant.path, O_WRONLY | O_CREAT, mode_t(0600))
            guard fd >= 0 else { throw failed("O_CREAT \(name)") }
            let result = fstat(fd, &attributes)
            close(fd)
            guard result == 0, attributes.st_ino == original.st_ino else { throw failed("O_CREAT inode mismatch: \(name)") }
            let duplicate = open(variant.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0600))
            let error = errno
            if duplicate >= 0 { close(duplicate) }
            guard duplicate == -1, error == EEXIST else { throw failed("O_EXCL \(name): fd=\(duplicate), errno=\(error)") }
            guard mkdir(variant.path, mode_t(0700)) == -1, errno == EEXIST else { throw failed("mkdir collision: \(name)") }
            guard link(exact.path, variant.path) == -1, errno == EEXIST else { throw failed("link collision: \(name)") }
        }
    }
    let names = try FileManager.default.contentsOfDirectory(atPath: volume.path)
        .filter { $0.lowercased() == exact.lastPathComponent.lowercased() }
    guard names == [exact.lastPathComponent], try Data(contentsOf: exact) == payload else { throw failed("stored names: \(names)") }
    print("PASS: case variants share an inode, spelling is preserved, and duplicate names are rejected")
}

func checkOpenFileLifetime(_ volume: URL) throws {
    let directory = volume.appendingPathComponent("open-lifetime-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let oldBytes = Data(repeating: 0x41, count: 65536)
    let newBytes = Data(repeating: 0x42, count: 65536)
    func openUncached(_ url: URL) throws -> Int32 {
        let fd = open(url.path, O_RDWR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard fcntl(fd, F_NOCACHE, 1) == 0, fsync(fd) == 0 else {
            let error = errno; close(fd); throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
        return fd
    }
    func readOld(_ fd: Int32) throws {
        var bytes = [UInt8](repeating: 0, count: 65536)
        let read = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
        var attributes = stat()
        guard read == bytes.count, Data(bytes) == oldBytes,
              fstat(fd, &attributes) == 0, attributes.st_size == oldBytes.count else { throw POSIXError(.EIO) }
    }
    let unlinked = directory.appendingPathComponent("unlinked.bin")
    try oldBytes.write(to: unlinked)
    let unlinkedFD = try openUncached(unlinked)
    defer { close(unlinkedFD) }
    guard unlink(unlinked.path) == 0 else { throw POSIXError(.EIO) }
    try readOld(unlinkedFD)
    let source = directory.appendingPathComponent("source.bin")
    let destination = directory.appendingPathComponent("destination.bin")
    try newBytes.write(to: source)
    try oldBytes.write(to: destination)
    let oldFD = try openUncached(destination)
    defer { close(oldFD) }
    guard rename(source.path, destination.path) == 0 else { throw POSIXError(.EIO) }
    try readOld(oldFD)
    guard try Data(contentsOf: destination) == newBytes else { throw POSIXError(.EIO) }
    print("PASS: uncached read/fstat survive unlink and replacement rename; new path sees replacement data")
}

setbuf(stdout, nil)
let device = ProcessInfo.processInfo.environment["XNTFS_TEST_DEVICE"]
let readOnlyMedia = ProcessInfo.processInfo.environment["XNTFS_TEST_READ_ONLY_MEDIA"] == "1"
let sourceImage = ProcessInfo.processInfo.environment["XNTFS_TEST_IMAGE"].map { URL(fileURLWithPath: $0) }
let initialHash = try sourceImage.map { SHA256.hash(data: try Data(contentsOf: $0)) }

let child = Process()
let output = Pipe(), input = Pipe()
child.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
if let device { child.arguments = [device] }
child.standardOutput = output
child.standardInput = input
try child.run()
var pending = Data()
var failed = false
var checks = 0
while true {
    let chunk = output.fileHandleForReading.availableData
    if chunk.isEmpty { break }
    pending.append(chunk)
    while let newline = pending.firstIndex(of: 10) {
        let line = String(decoding: pending[..<newline], as: UTF8.self)
        pending.removeSubrange(...newline)
        print(line)
        guard line.hasPrefix("CHECK ") else { continue }
        do {
            let object = try JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as! [String: String]
            let phase = object["phase"]!
            if phase == "unmount-ro", let sourceImage, let initialHash {
                guard try SHA256.hash(data: Data(contentsOf: sourceImage)) == initialHash else { throw POSIXError(.EIO) }
                print("PASS read-only attached image unchanged")
                try input.fileHandleForWriting.write(contentsOf: Data("ok\n".utf8))
                continue
            }
            let url = URL(fileURLWithPath: object["mountPath"]!)
            var info = statfs()
            guard statfs(url.path, &info) == 0 else { throw POSIXError(.EIO) }
            let type = withUnsafeBytes(of: info.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let source = withUnsafeBytes(of: info.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let expectedSource = device.map { source == "/dev/\($0)" } ?? source.contains("xntfs-native-tests-")
            guard url.path.hasPrefix("/Volumes/"), type == "xntfs", expectedSource else {
                throw POSIXError(.EINVAL)
            }
            print("FILESYSTEM phase=\(phase) type=\(type) source=\(source) target=\(url.path) flags=\(info.f_flags)")
            let payload = Data("Native FSKit image persistence test\n".utf8)
            let file = url.appendingPathComponent("native-integration.txt")
            guard info.f_bavail > info.f_blocks / 2 else { throw POSIXError(.ENOSPC) }
            if phase == "prepare-hibernation" {
                guard info.f_flags & UInt32(MNT_RDONLY) == 0 else { throw POSIXError(.EROFS) }
                var hibernation = Data(repeating: 0, count: 4096)
                hibernation.replaceSubrange(0..<4, with: "hibr".utf8)
                let fixture = url.appendingPathComponent("hiberfil.sys")
                try hibernation.write(to: fixture)
                let handle = try FileHandle(forWritingTo: fixture)
                try handle.synchronize()
                try handle.close()
            } else if phase == "rw" {
                guard info.f_flags & UInt32(MNT_RDONLY) == 0 else { throw POSIXError(.EROFS) }
                let staging = url.appendingPathComponent("native-staging.txt")
                try payload.write(to: staging)
                try FileManager.default.moveItem(at: staging, to: file)
                let handle = try FileHandle(forWritingTo: file)
                do {
                    try handle.synchronize()
                    try handle.close()
                } catch {
                    try? handle.close()
                    throw error
                }
                print("PASS explicit file sync and close")
                guard try Data(contentsOf: file) == payload else { throw POSIXError(.EIO) }
                try checkOpenFileLifetime(url)
                try payload.write(to: url.appendingPathComponent("MiXeD-integration.txt"))
                try checkCaseVariants(url, payload: payload, writable: true)
            } else {
                guard info.f_flags & UInt32(MNT_RDONLY) != 0 else { throw POSIXError(.EINVAL) }
                if phase == "remount-ro", try Data(contentsOf: file) != payload { throw POSIXError(.EIO) }
                if phase == "remount-ro" {
                    guard try Data(contentsOf: url.appendingPathComponent("mixed-integration.txt")) == payload,
                          try Data(contentsOf: url.appendingPathComponent("MIXED-INTEGRATION.TXT")) == payload else {
                        throw POSIXError(.EIO)
                    }
                    print("PASS: mounted case-insensitive lookup after remount")
                    try checkCaseVariants(url, payload: payload, writable: false)
                }
                do {
                    try payload.write(to: url.appendingPathComponent("must-not-write.txt"))
                    throw NSError(domain: "UnexpectedWrite", code: 1)
                } catch {
                    let error = error as NSError
                    let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError ?? error
                    guard underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(EROFS) else { throw error }
                }
            }
            if ProcessInfo.processInfo.environment["XNTFS_TEST_COMPRESSED_GUARD"] == "1" {
                try checkCompressedWriteGuard(url, writable: phase == "rw")
            }
            if ProcessInfo.processInfo.environment["XNTFS_TEST_STABILITY"] == "1",
               phase == "rw" || phase == "remount-ro" {
                guard let script = ProcessInfo.processInfo.environment["XNTFS_TEST_STABILITY_SCRIPT"],
                      let report = ProcessInfo.processInfo.environment["XNTFS_TEST_STABILITY_OUTPUT"] else {
                    throw POSIXError(.EINVAL)
                }
                let load = Process()
                load.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                load.arguments = ["python3", "-B", script, phase, url.path, report]
                try load.run()
                load.waitUntilExit()
                guard load.terminationStatus == 0 else { throw POSIXError(.EIO) }
            }
            checks += 1
            print("PASS host I/O: \(phase)")
            try input.fileHandleForWriting.write(contentsOf: Data("ok\n".utf8))
        } catch {
            failed = true
            print("FAIL host: \(error)")
            try input.fileHandleForWriting.write(contentsOf: Data("failed\n".utf8))
        }
    }
}
child.waitUntilExit()
guard child.terminationStatus == 0, !failed, checks == (readOnlyMedia ? 1 : device == nil ? 5 : 3) else {
    print("FAIL: child exit=\(child.terminationStatus), I/O checks=\(checks), failed=\(failed)")
    exit(1)
}
print("PASS: sandbox mount lifecycle and host I/O verified")
