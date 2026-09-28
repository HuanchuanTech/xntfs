import Foundation

@main
struct DiskClassificationTests {
    static func main() throws {
        let cases: [(String?, String, String, Bool, Bool)] = [
            ("exfat", "exfat", "Windows_NTFS", true, false),
            ("exfat", "ntfs", "Windows_NTFS", true, false),
            (nil, "exfat", "Windows_NTFS", true, false),
            (nil, "msdos", "Windows_NTFS", true, false),
            ("apfs", "ntfs", "Windows_NTFS", true, false),
            ("xntfs", "exfat", "Windows_NTFS", true, true),
            ("ntfs", "ntfs", "Windows_NTFS", true, true),
            ("ufsd", "ntfs", "Windows_NTFS", true, true),
            ("ufsd", "exfat", "Windows_NTFS", true, false),
            ("macfuse", "ntfs", "Windows_NTFS", true, true),
            ("tuxera_ntfs", "ntfs", "Windows_NTFS", true, true),
            (nil, "ntfs", "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", true, true),
            (nil, "", "Windows_NTFS", true, true),
            (nil, "", "Windows_NTFS", false, false),
            (nil, "", "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7", true, false)
        ]
        for (mounted, kind, content, leaf, expected) in cases {
            let actual = DiskArbitrationMonitor.isNTFSVolume(mountedType: mounted, volumeKind: kind,
                                                            contentHint: content, leaf: leaf)
            precondition(actual == expected, "classification mismatch: \(mounted ?? "unmounted"), \(kind)")
        }
        precondition(DiskArbitrationMonitor.mountInfo(FileManager.default.temporaryDirectory) == nil,
                     "An ordinary folder must not be reported as a mounted device")
        print("PASS: \(cases.count) NTFS/exFAT classification cases and stale mount-point handling")
    }
}
