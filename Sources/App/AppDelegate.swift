import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var firstLaunch = false
    private var housekeepingTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        firstLaunch = !UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
        UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")

        buildMainMenu()
        ClipStore.shared.open()
        StatusItemController.shared.install()
        ClipboardMonitor.shared.start()

        HotkeyCenter.shared.handler = { action in
            Task { @MainActor in
                switch action {
                case .showPanel:
                    ClipPanelController.shared.statusItemFrame = StatusItemController.shared.buttonFrame
                    ClipPanelController.shared.toggle()
                case .showPinned:
                    ClipPanelController.shared.statusItemFrame = StatusItemController.shared.buttonFrame
                    ClipPanelController.shared.toggle(filter: .pinned)
                case .pinCurrent:
                    PasteEngine.shared.pinCurrentClipboard()
                }
            }
        }
        HotkeyCenter.shared.reloadAll(from: SettingsStore.shared)

        // Whenever the user leaves Clipline, fold the write ahead log back into the database.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: nil, queue: .main) { _ in
            DispatchQueue.global(qos: .utility).async { ClipStore.shared.checkpoint() }
        }

        // Housekeeping on launch so a long pause between sessions cannot leave stale rows,
        // again whenever the retention window changes, and then every few minutes. With a
        // window measured in hours, waiting for the next capture could leave an entry on
        // screen well past its time on a quiet afternoon.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.sweepExpired() }
        NotificationCenter.default.addObserver(forName: .clipRetentionChanged,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.sweepExpired()
        }
        housekeepingTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            self?.sweepExpired()
        }
        housekeepingTimer?.tolerance = 60

        UpdateController.shared.start()

        // QA hooks: open a surface straight away without needing the global shortcut.
        let arguments = CommandLine.arguments
        if arguments.contains("-selfTestPinGuard") {
            // Pins the newest entry, asks the panel to delete it, and records whether the
            // guard held.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard let newest = ClipStore.shared.items(filter: .all, query: "", limit: 1).first else { return }
                ClipStore.shared.setPinned(true, id: newest.id)
                let model = ClipPanelController.shared.model
                model.reload()
                if let pinned = ClipStore.shared.item(id: newest.id) {
                    model.delete(pinned)
                }
                let survived = ClipStore.shared.item(id: newest.id) != nil
                ClipStore.shared.setPinned(false, id: newest.id)
                ClipStore.shared.audit("selfTestPinGuard pinnedEntrySurvivedDelete=\(survived)")
            }
            return
        }

        if arguments.contains("-selfTestDelete") {
            // Deletes the newest entry and records the row count and stored bytes either
            // side, so the reclaim path can be checked without driving the interface.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard let newest = ClipStore.shared.items(filter: .all, query: "", limit: 1).first else { return }
                let before = ClipStore.shared.stats()
                ClipStore.shared.delete(id: newest.id)
                let after = ClipStore.shared.stats()
                ClipStore.shared.audit("selfTestDelete rowsBefore=\(before.total) rowsAfter=\(after.total) "
                                       + "fileBytesBefore=\(before.fileBytes) fileBytesAfter=\(after.fileBytes)")
            }
            return
        }

        if arguments.contains("-selfTestPanelFrame") {
            // Opens the panel and reports where it was asked to go, where it actually landed,
            // and whether anything rewrote the stored spot on the way, so placement can be
            // checked without driving the interface.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                let settings = SettingsStore.shared
                func stored() -> String {
                    "\(Int(settings.panelOriginX)),\(Int(settings.panelOriginY))"
                        + " \(Int(settings.panelWidth))x\(Int(settings.panelHeight))"
                }
                func describe(_ rect: NSRect) -> String {
                    "\(Int(rect.origin.x)),\(Int(rect.origin.y)) \(Int(rect.width))x\(Int(rect.height))"
                }
                let before = stored()
                ClipPanelController.shared.show()
                let immediate = describe(ClipPanelController.shared.panelFrame ?? .zero)
                try? await Task.sleep(nanoseconds: 900_000_000)
                let settled = describe(ClipPanelController.shared.panelFrame ?? .zero)
                let screens = NSScreen.screens.map { describe($0.visibleFrame) }.joined(separator: " / ")
                ClipStore.shared.audit("selfTestPanelFrame placement=\(settings.panelPlacement.rawValue) "
                    + "storedBefore=[\(before)] immediate=[\(immediate)] settled=[\(settled)] "
                    + "storedAfter=[\(stored())] screens=[\(screens)]")
            }
            return
        }

        if let index = arguments.firstIndex(of: "-selfTestShot") {
            // Renders the interface to PNGs in the support folder, so it can be reviewed
            // without a screen recording grant. QA only.
            //
            //   -selfTestShot            every settings section
            //   -selfTestShot privacy    just that section
            //   -selfTestShot panel      the clipboard panel
            let target = arguments.count > index + 1 ? arguments[index + 1] : nil
            let named = target.flatMap { SettingsSection(rawValue: $0) }
            let sections = named.map { [$0] } ?? SettingsSection.allCases
            Task { @MainActor in
                let folder = ClipStore.shared.supportDirectory.appendingPathComponent("shots")
                if target == "panel" {
                    // The panel is the one part of the interface a screen recording cannot
                    // reach, since it excludes itself from capture. Ask it to draw itself.
                    ClipPanelController.shared.show()
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    let url = folder.appendingPathComponent("panel.png")
                    let written = ClipPanelController.shared.writeSnapshot(to: url)
                    ClipStore.shared.audit("selfTestShot target=panel written=\(written) path=\(url.path)")
                    return
                }
                for section in sections {
                    SettingsWindowController.shared.show(section: section)
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    let url = folder.appendingPathComponent("settings-\(section.rawValue).png")
                    let written = SettingsWindowController.shared.writeSnapshot(to: url)
                    ClipStore.shared.audit("selfTestShot section=\(section.rawValue) written=\(written) path=\(url.path)")
                }
            }
            return
        }

        if arguments.contains("-copyNewest") || arguments.contains("-pasteNewest") {
            let alsoPaste = arguments.contains("-pasteNewest")
            // Stages the newest entry on the pasteboard so the paste path can be inspected
            // from a terminal instead of by driving the interface.
            let filter = ClipFilter(rawValue: arguments.last ?? "all") ?? .all
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if let newest = ClipStore.shared.items(filter: filter, query: "", limit: 1).first {
                    let placed = PasteEngine.shared.placeOnPasteboard(newest, plainText: false)
                    NSLog("Clipline staged id %lld kind %@ placed %@",
                          newest.id, newest.kind.rawValue, placed ? "yes" : "no")
                    if alsoPaste, placed { PasteEngine.shared.deliverStagedPaste() }
                }
            }
            return
        }
        if arguments.contains("-panel") || arguments.contains("-settings") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                if arguments.contains("-panel") { ClipPanelController.shared.show() }
                if arguments.contains("-settings") { SettingsWindowController.shared.show() }
            }
            return
        }

        if firstLaunch {
            Task { @MainActor in
                showWelcome()
            }
        }
    }

    /// Applies the history limit and the retention window off the main thread. The limits
    /// are read here on main and handed over as plain values.
    private func sweepExpired() {
        let historyLimit = SettingsStore.shared.historyLimit
        let retentionHours = SettingsStore.shared.retentionHours
        DispatchQueue.global(qos: .utility).async {
            ClipStore.shared.trimNow(historyLimit: historyLimit, retentionHours: retentionHours)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if SettingsStore.shared.clearOnQuit {
            // No VACUUM here. Quit has to be quick, and the next cleanup reclaims the space.
            ClipStore.shared.clear(includingPinned: false, reclaimSpace: false)
        }
        ClipboardMonitor.shared.stop()
        ClipStore.shared.close()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return true
    }

    /// Text fields get their editing keys from the main menu, so the search field needs one
    /// even though Clipline normally runs without a menu bar of its own.
    @MainActor
    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Clipline", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let updatesItem = NSMenuItem(title: "Check for Updates…",
                                     action: #selector(UpdateController.checkForUpdates), keyEquivalent: "")
        updatesItem.target = UpdateController.shared
        appMenu.addItem(updatesItem)
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Clipline", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Clipline", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func openSettings() {
        Task { @MainActor in SettingsWindowController.shared.show() }
    }

    @MainActor
    private func showWelcome() {
        let shortcut = SettingsStore.shared.shortcut(for: .showPanel)?.displayString ?? "the shortcut you set"
        let alert = NSAlert()
        alert.messageText = "Clipline is running"
        alert.informativeText = """
        Press \(shortcut) anywhere to open your clipboard history.

        Clipline lives in the menu bar. To let it paste straight into other apps, allow \
        Accessibility access when macOS asks.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            SettingsWindowController.shared.show()
        }
        PasteEngine.shared.requestAccessibility()
    }
}
