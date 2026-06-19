//
//  datest.swift — probe whether THIS process may drive DiskArbitration mounting.
//  Usage: datest <bsdName> [mountPath]
//    no mountPath  -> DADiskMount(NULL)  => "standard" path (/Volumes/<name>)
//    mountPath     -> DADiskMount(url)   => custom location
//
import Foundation
import DiskArbitration

let args = CommandLine.arguments
guard args.count >= 2 else { FileHandle.standardError.write("usage: datest <bsd> [path]\n".data(using: .utf8)!); exit(2) }
let bsd = args[1]
let customPath: String? = args.count >= 3 ? args[2] : nil

guard let session = DASessionCreate(kCFAllocatorDefault) else { print("RESULT no-session"); exit(3) }
DASessionScheduleWithRunLoop(session, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd) else { print("RESULT no-disk"); exit(4) }

var pathURL: URL? = nil
if let p = customPath {
    let u = URL(fileURLWithPath: p, isDirectory: true)
    do { try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true) }
    catch { print("RESULT mkdir-failed \(error.localizedDescription)"); exit(6) }
    pathURL = u
}

final class Box { var done = false; var result = "timeout" }
let box = Box()
let ctx = Unmanaged.passUnretained(box).toOpaque()

DADiskMount(disk, pathURL as CFURL?, DADiskMountOptions(kDADiskMountOptionDefault),
            { _, dissenter, ctx in
                let b = Unmanaged<Box>.fromOpaque(ctx!).takeUnretainedValue()
                if let d = dissenter {
                    let status = DADissenterGetStatus(d)
                    let msg = DADissenterGetStatusString(d).map { $0 as String } ?? "(none)"
                    b.result = String(format: "DISSENTED status=0x%08X msg=%@", status, msg)
                } else {
                    b.result = "MOUNTED-OK"
                }
                b.done = true
                CFRunLoopStop(CFRunLoopGetCurrent())
            }, ctx)

let deadline = Date().addingTimeInterval(12)
while !box.done && Date() < deadline { CFRunLoopRunInMode(.defaultMode, 0.25, true) }
print("RESULT \(box.result)")
exit(0)
