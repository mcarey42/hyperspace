//
//  HyperspaceHostApp.swift
//  HyperspaceHost
//

import SwiftUI

@main
struct HyperspaceHostApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandMenu("Hyperspace") {
                Button("Configure…") {
                    NotificationCenter.default.post(name: .hyperspaceConfigure, object: nil)
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }
    }
}
