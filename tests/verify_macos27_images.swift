import Foundation
import CryptoKit

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
                guard try Data(contentsOf: file) == payload else { throw POSIXError(.EIO) }
                try checkOpenFileLifetime(url)
                try payload.write(to: url.appendingPathComponent("MiXeD-integration.txt"))
            } else {
                guard info.f_flags & UInt32(MNT_RDONLY) != 0 else { throw POSIXError(.EINVAL) }
                if phase == "remount-ro", try Data(contentsOf: file) != payload { throw POSIXError(.EIO) }
                if phase == "remount-ro" {
                    guard try Data(contentsOf: url.appendingPathComponent("mixed-integration.txt")) == payload,
                          try Data(contentsOf: url.appendingPathComponent("MIXED-INTEGRATION.TXT")) == payload else {
                        throw POSIXError(.EIO)
                    }
                    print("PASS: mounted case-insensitive lookup after remount")
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
