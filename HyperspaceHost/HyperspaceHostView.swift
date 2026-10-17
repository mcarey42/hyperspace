//
//  HyperspaceHostView.swift
//  HyperspaceHost
//
//  Debug-only host for the Hyperspace.saver bundle: loads it dynamically via
//  NSBundle (the same mechanism legacyScreenSaver uses) so it runs in a normal,
//  debuggable, Metal-API-validated app process instead of inside the system's
//  screen saver engine.
//

import SwiftUI
import AppKit
import ScreenSaver

enum HyperspaceSaverLoader {
    static func loadView(frame: NSRect) -> ScreenSaverView? {
        let fileManager = FileManager.default
        let candidates = [
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Hyperspace.saver"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Screen Savers/Hyperspace.saver")
        ]

        for url in candidates {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            guard let bundle = Bundle(url: url) else { continue }
            guard let viewClass = bundle.principalClass as? ScreenSaverView.Type else { continue }
            if let view = viewClass.init(frame: frame, isPreview: false) {
                return view
            }
        }
        return nil
    }
}

final class SaverHostController: NSObject {
    private(set) var saverView: ScreenSaverView?
    let loadErrorMessage: String?
    private var timer: Timer?

    override init() {
        if let view = HyperspaceSaverLoader.loadView(frame: NSRect(x: 0, y: 0, width: 800, height: 600)) {
            saverView = view
            loadErrorMessage = nil
        } else {
            saverView = nil
            loadErrorMessage = "Couldn't find Hyperspace.saver.\nBuild the \"Hyperspace\" target first, or install it to ~/Library/Screen Savers."
        }
        super.init()
    }

    func start() {
        guard let saverView else { return }
        saverView.startAnimation()
        timer?.invalidate()
        let interval = max(saverView.animationTimeInterval, 1.0 / 60.0)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak saverView] _ in
            saverView?.animateOneFrame()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        saverView?.stopAnimation()
    }

    func showConfigureSheet(in window: NSWindow?) {
        guard let saverView, saverView.hasConfigureSheet, let sheet = saverView.configureSheet, let window else { return }
        window.beginSheet(sheet)
    }
}

struct HyperspaceHostView: NSViewRepresentable {
    let controller: SaverHostController

    func makeNSView(context: Context) -> NSView {
        if let saverView = controller.saverView {
            return saverView
        }
        let label = NSTextField(labelWithString: controller.loadErrorMessage ?? "Unable to load Hyperspace.saver.")
        label.alignment = .center
        label.maximumNumberOfLines = 0
        return label
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension Notification.Name {
    static let hyperspaceConfigure = Notification.Name("HyperspaceConfigure")
}
