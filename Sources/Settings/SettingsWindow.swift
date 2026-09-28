import AppKit
import SwiftUI

/// Owns the single settings window.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(appearanceChanged),
                                               name: .clipAppearanceChanged, object: nil)
    }

    func show(section: SettingsSection = .general) {
        SettingsNavigation.shared.section = section
        let isNew = window == nil
        let window = window ?? makeWindow()
        self.window = window
        // Only centre on the first open, so a window the user moved stays where they put it.
        if isNew { window.center() }
        window.appearance = SettingsStore.shared.appearanceMode.appearance
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Cooperative activation on recent macOS will not raise the window without this.
        window.orderFrontRegardless()
    }

    var isShowing: Bool { window?.isVisible == true }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        window.contentMinSize = NSSize(width: 660, height: 440)
        window.title = "Clipline Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.contentView = NSHostingView(rootView: SettingsView())
        window.isReleasedWhenClosed = false
        return window
    }

    /// Renders the settings window's content to a PNG from inside the app, so the interface
    /// can be looked at without a screen recording grant. QA only.
    func writeSnapshot(to url: URL) -> Bool {
        guard let view = window?.contentView else { return false }
        return view.writeSnapshot(to: url)
    }

    @objc private func appearanceChanged() {
        window?.appearance = SettingsStore.shared.appearanceMode.appearance
    }

    func windowWillClose(_ notification: Notification) {
        // Back to an accessory app so no Dock icon lingers after settings close.
        NSApp.setActivationPolicy(.accessory)
    }
}
