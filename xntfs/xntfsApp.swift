//
//  xntfsApp.swift
//  NTFS for macOS — reads/writes NTFS volumes via ntfs-3g + FSKit.
//

import SwiftUI

@main
struct xntfsApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .task { model.start() }
                .frame(minWidth: 720, minHeight: 460)
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
