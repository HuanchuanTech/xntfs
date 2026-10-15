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

        let drivers: [(String?, MountDriver)] = [
            (nil, .unknown), ("", .unknown), ("ntfs", .system), ("NTFS", .system),
            ("xntfs", .xntfs), ("XNTFS", .xntfs), ("ufsd", .other("ufsd")),
            ("tuxera_ntfs", .other("tuxera_ntfs")), ("fusefs_txantfs", .other("fusefs_txantfs")),
            ("macfuse", .other("macfuse")), ("osxfuse", .other("osxfuse"))
        ]
        precondition(MountDriver(fileSystemType: DiskArbitrationMonitor.moduleFSType) == .xntfs)
        let mounted = MountState.mounted(URL(fileURLWithPath: "/Volumes/Test"))
        let states: [MountState] = [.unmounted, .mounting, mounted, .unmounting, .failed("test")]
        var device = NTFSDevice(id: "disk6s1", volumeName: "Test", sizeBytes: 66060288,
                                kind: .removable, contentHint: "Windows_NTFS",
                                isRemovable: true, devicePath: "/dev/disk6s1")
        var count = 0
        for (fsType, expectedDriver) in drivers {
            precondition(MountDriver(fileSystemType: fsType) == expectedDriver)
            for state in states {
                for readOnly in [false, true] {
                    for writable in [false, true] {
                        for kind in [DeviceKind.removable, .diskImage, .fixed] {
                            device.mountedFileSystemType = fsType
                            device.state = state
                            device.readOnly = readOnly
                            device.mediaWritable = writable
                            device.kind = kind
                            precondition(device.mountDriver == (state.isMounted ? expectedDriver : .unknown))
                            precondition(device.mountedByXntfs == (state.isMounted && expectedDriver == .xntfs))
                            precondition(device.needsXntfsMountGuidance ==
                                         (state.isMounted && expectedDriver == .system && readOnly))
                            count += 1
                        }
                    }
                }
            }
        }

        device.state = mounted
        device.readOnly = true
        device.mountedFileSystemType = "ntfs"
        precondition(device.needsXntfsMountGuidance)
        var changed = device
        changed.mountedFileSystemType = "xntfs"
        precondition(changed != device && changed.mountedByXntfs && !changed.needsXntfsMountGuidance,
                     "A successful xntfs remount must remove guidance, even when it remains read-only")
        changed.mountedFileSystemType = "ufsd"
        precondition(changed != device && !changed.needsXntfsMountGuidance,
                     "A third-party driver must not be labeled as System")
        changed.mountedFileSystemType = nil
        precondition(changed != device && changed.mountDriver == .unknown && !changed.needsXntfsMountGuidance,
                     "A failed statfs query must not be labeled as System")
        changed = device
        changed.kind = .diskImage
        precondition(changed != device, "A device-kind change must update the recovery instructions")
        print("PASS: \(count) driver/access/state/media/kind cases and driver transitions")
    }
}
