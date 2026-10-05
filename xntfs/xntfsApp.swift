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
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About xntfs") {
                    AboutPanel.show()
                }
            }
            CommandGroup(replacing: .help) {
                Link("GitHub", destination: URL(string: "https://github.com/HuanchuanTech/xntfs")!)
                Link("GitHub Issues", destination: URL(string: "https://github.com/HuanchuanTech/xntfs/issues")!)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
