//
//  ContentView.swift
//  HyperspaceHost
//

import SwiftUI

struct ContentView: View {
    @State private var controller = SaverHostController()

    var body: some View {
        HyperspaceHostView(controller: controller)
            .frame(minWidth: 480, minHeight: 360)
            .onAppear {
                DispatchQueue.main.async { controller.start() }
            }
            .onDisappear { controller.stop() }
            .onReceive(NotificationCenter.default.publisher(for: .hyperspaceConfigure)) { _ in
                controller.showConfigureSheet(in: NSApp.keyWindow)
            }
    }
}

#Preview {
    ContentView()
}
