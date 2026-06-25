//
//  DiskUtility.swift
//  Opens Apple's Disk Utility — the supported way (for a sandboxed app) to attach disk
//  images and, before macOS 27 where the app can't mount a third-party FSKit volume itself,
//  to mount NTFS volumes.
//

import AppKit

enum DiskUtility {
    static func open() {
        let ws = NSWorkspace.shared
        if let url = ws.urlForApplication(withBundleIdentifier: "com.apple.DiskUtility") {
            ws.open(url)
        } else {
            ws.open(URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app"))
        }
    }
}
