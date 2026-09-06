import SwiftUI

/// The menu bar app. No Dock icon, no main window — the panel *is* the app.
struct WattsonApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            // Hollow while everything behaves, filled the moment it doesn't.
            Image(systemName: model.state.anomalyCount > 0 ? "flame.fill" : "flame")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Settings live in an ordinary window, created on demand. A menu bar app has
/// no Settings scene to hang them off.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show(model: AppModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        let created = NSWindow(contentViewController: hosting)
        created.title = "Wattson"
        created.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        created.titlebarAppearsTransparent = true
        created.titleVisibility = .hidden
        created.identifier = NSUserInterfaceItemIdentifier("settings")
        created.isReleasedWhenClosed = false
        created.center()
        created.makeKeyAndOrderFront(nil)
        window = created
    }
}


/// Opens the panel and settings side by side in ordinary windows, so the layout
/// can be inspected without hunting through menu bar states.
@MainActor
enum PreviewWindows {
    private static var windows: [NSWindow] = []

    static func show(appearance: String? = nil, language: String? = nil) {
        if let language { activeLanguage = language == "zh" ? .chinese : .english }
        let model = AppModel.preview()
        NSApplication.shared.setActivationPolicy(.regular)
        if let appearance {
            NSApp.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        }

        let panelHost = NSHostingController(rootView: PanelView(model: model))
        let panel = NSWindow(contentViewController: panelHost)
        panel.title = "Panel"
        panel.styleMask = [.titled, .closable, .fullSizeContentView]
        blend(panel)
        // The hosting view knows how tall the layout wants to be; the window
        // does not, and defaults to something far shorter.
        panel.setContentSize(panelHost.view.fittingSize)
        panel.setFrameOrigin(NSPoint(x: 140, y: 180))
        panel.makeKeyAndOrderFront(nil)

        let settingsHost = NSHostingController(rootView: SettingsView(model: model))
        let settings = NSWindow(contentViewController: settingsHost)
        settings.title = "Settings"
        settings.styleMask = [.titled, .closable, .fullSizeContentView]
        blend(settings)
        settings.setContentSize(settingsHost.view.fittingSize)
        settings.setFrameOrigin(NSPoint(x: 600, y: 120))
        settings.makeKeyAndOrderFront(nil)

        windows = [panel, settings]
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Let the title bar disappear into the canvas rather than sitting on top
    /// of it as a separate grey band.
    private static func blend(_ window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(rgb: 0x1F1E1D) : NSColor(rgb: 0xFAF9F5)
        }
    }
}


/// Renders the UI straight to PNG without showing a window.
///
/// Screenshotting a live window is unreliable — full-screen apps put it on
/// another Space, and the capture races the layout pass — and these same images
/// are what the README needs anyway.
@MainActor
enum Shoot {
    static func render(into directory: String, appearance: String, language: String) {
        activeLanguage = language == "zh" ? .chinese : .english
        let model = AppModel.preview()
        let look = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)!

        let dir = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        write(PanelView(model: model), to: dir, named: "panel-\(appearance)-\(language)",
              appearance: look)
        write(SettingsView(model: model), to: dir, named: "settings-\(appearance)-\(language)",
              appearance: look)
        print("wrote images to \(dir.path)")
    }

    private static func write<V: View>(_ view: V, to dir: URL, named name: String,
                                       appearance: NSAppearance) {
        let host = NSHostingView(rootView: view)
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: host.fittingSize)

        // Force a full layout pass before capture, or the image is of an
        // unlaid-out view.
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: dir.appendingPathComponent("\(name).png"))
    }
}
