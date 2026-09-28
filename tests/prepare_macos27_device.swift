import Foundation

if CommandLine.arguments[1] == "--devices" {
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
    let entities = plist["system-entities"] as! [[String: Any]]
    let whole = entities.first { $0["content-hint"] as? String == "FDisk_partition_scheme" }?["dev-entry"] as! String
    let partition = entities.first { $0["content-hint"] as? String == "Windows_NTFS" }?["dev-entry"] as! String
    precondition(whole.range(of: #"^/dev/disk[0-9]+$"#, options: .regularExpression) != nil && partition == whole + "s1")
    print(whole)
    print(partition)
    exit(0)
}

let source = URL(fileURLWithPath: CommandLine.arguments[1])
let target = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.copyItem(at: source, to: target)
let file = try FileHandle(forUpdating: target)
defer { try? file.close() }
let mbr = try file.read(upToCount: 512)!
precondition(mbr.count == 512 && mbr[510] == 0x55 && mbr[511] == 0xaa && mbr[450] == 7)
func little(_ offset: Int) -> UInt64 {
    (0..<4).reduce(0) { $0 | UInt64(mbr[offset + $1]) << ($1 * 8) }
}
let offset = little(454) * 512, length = little(458) * 512
precondition(length >= 1024 && offset + length <= (try! file.seekToEnd()))
try file.seek(toOffset: offset)
let boot = try file.read(upToCount: 512)!
precondition(boot.count == 512 && boot[3..<11] == Data("NTFS    ".utf8))
var serial = UInt64.random(in: 1...UInt64.max).littleEndian
let bytes = withUnsafeBytes(of: &serial) { Data($0) }
try file.seek(toOffset: offset + 0x48)
try file.write(contentsOf: bytes)
try file.seek(toOffset: offset + length - 512 + 0x48)
try file.write(contentsOf: bytes)
print("Prepared disposable partition image: \(target.path)")
