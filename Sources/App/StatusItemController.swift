import AppKit

/// Menu bar presence. Left click opens the panel, right click opens the menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    static let shared = StatusItemController()

    private var statusItem: NSStatusItem?

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(menuBarSettingChanged),
                                               name: .clipMenuBarChanged, object: nil)
    }

    func install() {
        guard SettingsStore.shared.showMenuBarIcon else { return }
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "Clipline")
                ?? NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipline")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(buttonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Clipline"
        }
        statusItem = item
    }

    func remove() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    @objc private func menuBarSettingChanged() {
        if SettingsStore.shared.showMenuBarIcon {
            install()
        } else {
            remove()
        }
    }

    /// Screen frame of the menu bar button, used to place the panel under it.
    var buttonFrame: NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        ClipPanelController.shared.statusItemFrame = buttonFrame
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        if isRightClick {
            showMenu()
        } else {
            ClipPanelController.shared.toggle()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let open = NSMenuItem(title: "Open Clipboard", action: #selector(openPanel), keyEquivalent: "")
        open.target = self
        if let shortcut = SettingsStore.shared.shortcut(for: .showPanel) {
            open.keyEquivalent = shortcut.keyEquivalentCharacter
            open.keyEquivalentModifierMask = shortcut.modifierFlags
        }
        menu.addItem(open)

        let pinned = NSMenuItem(title: "Open Pinned Items", action: #selector(openPinned), keyEquivalent: "")
        pinned.target = self
        menu.addItem(pinned)

        menu.addItem(.separator())

        let pause = NSMenuItem(title: SettingsStore.shared.monitoringPaused ? "Resume Capturing" : "Pause Capturing",
                               action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)

        let clear = NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let updates = NSMenuItem(title: "Check for Updates…",
                                 action: #selector(UpdateController.checkForUpdates), keyEquivalent: "")
        updates.target = UpdateController.shared
        menu.addItem(updates)

        let quit = NSMenuItem(title: "Quit Clipline", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        // Detach the menu so the next left click opens the panel instead.
        statusItem?.menu = nil
    }

    @objc private func openPanel() {
        ClipPanelController.shared.show()
    }

    @objc private func openPinned() {
        ClipPanelController.shared.show(filter: .pinned)
    }

    @objc private func togglePause() {
        SettingsStore.shared.monitoringPaused.toggle()
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history"
        alert.informativeText = "Every entry that is not pinned will be removed. This cannot be undone."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            ThumbnailCache.shared.clear()
            ClipStore.shared.clearInBackground(includingPinned: false)
        }
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
