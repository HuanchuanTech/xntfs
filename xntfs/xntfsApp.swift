//
//  xntfsApp.swift
//  NTFS for macOS — reads/writes NTFS volumes via ntfs-3g + FSKit.
//

import SwiftUI

@main
struct xntfsApp: App {
    @Environment(\.openWindow) private var openWindow
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
                Button("Report a Problem...") { openWindow(id: "problem-report") }
                Divider()
                Link("GitHub", destination: URL(string: "https://github.com/HuanchuanTech/xntfs")!)
                Link("GitHub Issues", destination: URL(string: "https://github.com/HuanchuanTech/xntfs/issues")!)
            }
        }

        Window("Report a Problem", id: "problem-report") {
            ProblemReportView().environment(model)
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
