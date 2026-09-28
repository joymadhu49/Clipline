import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Borderless floating panel that can take keyboard focus without a title bar.
final class ClipPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the popup panel: placement, appearance, key handling and show or hide animation.
@MainActor
final class ClipPanelController: NSObject, NSWindowDelegate {
    static let shared = ClipPanelController()

    let model = PanelModel()

    private var panel: ClipPanel?
    private var keyMonitor: Any?
    private var isVisible = false
    private var userIsResizing = false
    /// True while a dialog the panel opened holds focus, so losing key does not hide it.
    private var isPresentingDialog = false
    /// The size the panel is supposed to have right now. Anything else gets corrected.
    private var intendedSize: NSSize = .zero
    /// True while Clipline itself is placing the window, so its own moves are not mistaken
    /// for the user dragging the panel somewhere.
    private var isPositioning = false

    /// Frame of the menu bar button, used by the menu bar placement option.
    var statusItemFrame: NSRect?

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(appearanceChanged),
                                               name: .clipAppearanceChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(storeChanged),
                                               name: .clipStoreChanged, object: nil)
    }

    // MARK: Show and hide

    func toggle(filter: ClipFilter = .all) {
        if isVisible {
            hide()
        } else {
            show(filter: filter)
        }
    }

    func show(filter: ClipFilter = .all) {
        PasteEngine.shared.rememberFrontmostApp()
        let panel = panel ?? makePanel()
        self.panel = panel
        applyAppearance(to: panel)

        model.prepareForShow(filter: filter)

        let frame = openingFrame()
        intendedSize = frame.size
        place(frame, on: panel, display: false)

        panel.alphaValue = 0
        // No NSApp.activate here. The panel is non-activating, so it takes the keyboard
        // while the app the user is in stays active. Activating Clipline would pull every
        // one of its windows forward with it, so an open Settings window jumped out from
        // behind whatever the user was working in each time the shortcut was pressed.
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        // Laying out the content can nudge the frame, so restate the frame we actually want.
        place(frame, on: panel, display: false)
        isVisible = true
        installKeyMonitor()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.09
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func hide(restoringFocus: Bool = true) {
        guard isVisible, let panel else { return }
        // Wherever it ended up is where it should come back, so the spot is banked on the
        // way out as well as on every drag. A close that follows a move too quickly for the
        // move notification would otherwise lose it.
        if SettingsStore.shared.panelPlacement == .remembered {
            SettingsStore.shared.rememberPanelOrigin(panel.frame.origin)
        }
        isVisible = false
        removeKeyMonitor()
        panel.orderOut(nil)
        // Normally the app the user was in never lost activation, and it simply gets the
        // keyboard back. Clipline is only active here if a dialog or the Settings window
        // made it so. Hiding the app then hands activation back, but it would also hide
        // Settings, so while Settings is open it keeps the focus instead.
        if restoringFocus, NSApp.isActive, !SettingsWindowController.shared.isShowing {
            NSApp.hide(nil)
        }
    }

    var isShowing: Bool { isVisible }

    /// Where the panel actually is. Read by the placement QA hook.
    var panelFrame: NSRect? { panel?.frame }

    /// Renders the panel's content to a PNG from inside the app. The panel opts out of
    /// screen capture, so a screen recording of it comes back with a hole where the panel
    /// was; drawing it into a bitmap here is the only way to get a picture of it without
    /// turning that protection off. The window's shadow and rounded corner mask are drawn
    /// by the window server, not the view, so they are not in the result.
    func writeSnapshot(to url: URL) -> Bool {
        guard let view = panel?.contentView else { return false }
        return view.writeSnapshot(to: url)
    }

    // MARK: Panel construction

    private func makePanel() -> ClipPanel {
        let size = SettingsStore.shared.panelFrameSize
        // A real title bar, so the panel carries the standard window buttons and can be
        // moved by its bar the way any other window is.
        let panel = ClipPanel(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                          .fullSizeContentView, .nonactivatingPanel],
                              backing: .buffered,
                              defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.title = "Clipline"
        // Close and minimize only. Zooming a small floating panel serves no purpose.
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        // Must stay off: a movable background steals the mouse from rows, so dragging an
        // entry out of the panel would move the window instead. The header carries an
        // explicit drag area for repositioning.
        panel.isMovableByWindowBackground = false
        panel.minSize = PanelSize.minimumSize
        panel.maxSize = PanelSize.maximumSize
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.delegate = self

        let root = ClipPanelView().environmentObject(model)
        let hosting = NSHostingView(rootView: root)
        // A hosting view used directly as the content view feeds its layout back into the
        // window, which made the panel resize itself a little smaller on every open. Holding
        // it inside a plain container keeps the window the one deciding the size.
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.autoresizesSubviews = true
        container.addSubview(hosting)
        panel.contentView = container
        return panel
    }

    private func applyAppearance(to panel: ClipPanel) {
        panel.appearance = SettingsStore.shared.appearanceMode.appearance
        // Invisible to screen recording, streaming and screen sharing while the setting is
        // on. The panel looks exactly the same in person; capture simply never carries it.
        panel.sharingType = SettingsStore.shared.hidePanelFromCapture ? .none : .readOnly
    }

    /// Runs a modal dialog on the panel's behalf. Focus moving to the dialog must not
    /// trigger the hide-on-focus-loss path, and the panel takes key back afterwards.
    func runHoldingPanel(_ body: () -> Void) {
        isPresentingDialog = true
        body()
        isPresentingDialog = false
        if isVisible { panel?.makeKeyAndOrderFront(nil) }
    }

    @objc private func appearanceChanged() {
        guard let panel else { return }
        applyAppearance(to: panel)
        let size = SettingsStore.shared.panelFrameSize
        intendedSize = size
        if isVisible {
            // Resize where it stands. Changing a setting is not a request to move the panel,
            // and re-placing it here used to overwrite the spot the user had dragged it to.
            var frame = panel.frame
            frame.origin.y = frame.maxY - size.height
            frame.size = size
            place(fitted(frame) ?? frame, on: panel, display: true)
        } else {
            panel.setContentSize(size)
        }
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        userIsResizing = true
    }

    /// The panel keeps exactly the size it was given. A SwiftUI layout pass would otherwise
    /// occasionally push the window down towards the content's own minimum, which looked
    /// like the panel shrinking on its own a moment after opening.
    func windowDidResize(_ notification: Notification) {
        guard let panel, isVisible, !userIsResizing, intendedSize != .zero else { return }
        let current = panel.frame.size
        guard abs(current.width - intendedSize.width) > 0.5
                || abs(current.height - intendedSize.height) > 0.5 else { return }
        var frame = panel.frame
        // Restore from the top edge so the search field never jumps.
        frame.origin.y = frame.maxY - intendedSize.height
        frame.size = intendedSize
        place(frame, on: panel, display: true)
    }

    /// Dragging an edge is a size preference, so it is remembered for the next open.
    /// Only a drag the user started counts, never a frame change the layout caused.
    func windowDidEndLiveResize(_ notification: Notification) {
        guard userIsResizing, let panel, isVisible else { return }
        userIsResizing = false
        intendedSize = panel.frame.size
        SettingsStore.shared.rememberPanelSize(panel.frame.size)
        // Dragging the left or the bottom edge moves the origin as well as changing the
        // size, so the new corner is banked with it.
        adoptCurrentSpot(panel.frame)
    }

    @objc private func storeChanged() {
        guard isVisible else { return }
        model.reload()
    }

    // MARK: Placement

    /// The frame the panel opens at. A spot the user put the panel in wins over the
    /// placement preset, which is what makes a drag stick.
    private func openingFrame() -> NSRect {
        let settings = SettingsStore.shared
        let size = settings.panelFrameSize
        if settings.panelPlacement == .remembered, settings.hasPanelOrigin {
            let stored = NSRect(origin: NSPoint(x: settings.panelOriginX, y: settings.panelOriginY),
                                size: size)
            if let usable = fitted(stored) { return usable }
        }
        return NSRect(origin: placementOrigin(for: size), size: size)
    }

    /// Pulls a frame fully onto the screen it mostly sits on. Returns nil when no screen
    /// holds a meaningful part of it, which is how a display that has gone away is caught.
    private func fitted(_ frame: NSRect) -> NSRect? {
        let area = frame.width * frame.height
        var best: NSScreen?
        var bestOverlap: CGFloat = 0
        for screen in NSScreen.screens {
            let overlap = NSIntersectionRect(frame, screen.visibleFrame)
            let covered = overlap.width * overlap.height
            if covered > bestOverlap {
                bestOverlap = covered
                best = screen
            }
        }
        // A corner poking onto a screen is not "where you left it", so a sliver does not
        // count and the panel falls back to the preset placement instead.
        guard let screen = best, area > 0, bestOverlap / area >= 0.5 else { return nil }
        return NSRect(origin: clamp(frame.origin, size: frame.size, in: screen.visibleFrame),
                      size: frame.size)
    }

    /// Records where the panel is now, and lets a drag settle the placement preference.
    /// Without this the panel would land back in the middle on the next open and moving it
    /// would look like it had simply been ignored.
    private func adoptCurrentSpot(_ frame: NSRect) {
        let settings = SettingsStore.shared
        settings.rememberPanelOrigin(frame.origin)
        guard settings.panelPlacement != .remembered else { return }
        settings.panelPlacement = .remembered
        model.showToast("Clipline will open here from now on")
    }

    /// Applies a frame Clipline decided on, so the move and resize notifications that follow
    /// are not mistaken for the user dragging the panel about.
    private func place(_ frame: NSRect, on panel: NSWindow, display: Bool) {
        isPositioning = true
        panel.setFrame(frame, display: display)
        // AppKit can follow up with a constraint pass of its own on the next turn of the run
        // loop, so the flag stays raised until that has been and gone.
        DispatchQueue.main.async { [weak self] in self?.isPositioning = false }
    }

    private func placementOrigin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return .zero }

        switch SettingsStore.shared.panelPlacement {
        // A remembered spot is resolved in openingFrame, so reaching here means there is
        // nothing usable to go back to and the middle is the honest fallback.
        case .remembered, .center:
            let x = frame.midX - size.width / 2
            let y = frame.midY - size.height / 2 + frame.height * 0.05
            return clamp(NSPoint(x: x, y: y), size: size, in: frame)
        case .pointer:
            let x = mouse.x - size.width / 2
            let y = mouse.y - size.height + 24
            return clamp(NSPoint(x: x, y: y), size: size, in: frame)
        case .menuBar:
            if let button = statusItemFrame {
                let x = button.midX - size.width / 2
                let y = button.minY - size.height - 6
                return clamp(NSPoint(x: x, y: y), size: size, in: frame)
            }
            let x = frame.maxX - size.width - 12
            return clamp(NSPoint(x: x, y: frame.maxY - size.height - 12), size: size, in: frame)
        }
    }

    private func clamp(_ point: NSPoint, size: NSSize, in frame: NSRect) -> NSPoint {
        let inset: CGFloat = 8
        // The upper bounds are floored against the lower ones so a panel bigger than the
        // screen it is on lands at the top left corner rather than off the far edge.
        let limitX = max(frame.minX + inset, frame.maxX - size.width - inset)
        let limitY = max(frame.minY + inset, frame.maxY - size.height - inset)
        return NSPoint(x: min(max(frame.minX + inset, point.x), limitX),
                       y: min(max(frame.minY + inset, point.y), limitY))
    }

    func windowDidResignKey(_ notification: Notification) {
        guard isVisible, !isPresentingDialog, SettingsStore.shared.hideOnFocusLoss else { return }
        hide(restoringFocus: false)
    }

    /// Dragging the panel by its title bar is a direct statement about where it belongs, so
    /// the spot is kept and the placement preference follows the drag.
    func windowDidMove(_ notification: Notification) {
        guard isVisible, !isPositioning, let panel else { return }
        adoptCurrentSpot(panel.frame)
    }

    /// The close button puts the panel away rather than destroying it.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Returns true when the panel consumed the key so the search field never sees it.
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let option = flags.contains(.option)
        let control = flags.contains(.control)
        let shift = flags.contains(.shift)

        switch Int(event.keyCode) {
        case kVK_Escape:
            // Steps back: clear the search, put the field away, then close.
            if !model.dismissSearchStep() { hide() }
            return true

        case kVK_ANSI_F where command:
            model.toggleSearch()
            return true

        case kVK_Return, kVK_ANSI_KeypadEnter:
            if command {
                model.copyOnly()
            } else {
                model.paste(plainText: option)
            }
            return true

        case kVK_UpArrow:
            if command { model.moveToStart() } else { model.move(by: -1) }
            return true

        case kVK_DownArrow:
            if command { model.moveToEnd() } else { model.move(by: 1) }
            return true

        case kVK_PageUp:
            model.move(by: -8)
            return true

        case kVK_PageDown:
            model.move(by: 8)
            return true

        case kVK_Tab:
            model.cycleFilter(forward: !shift)
            return true

        case kVK_ANSI_LeftBracket where command:
            model.cycleFilter(forward: false)
            return true

        case kVK_ANSI_RightBracket where command:
            model.cycleFilter(forward: true)
            return true

        case kVK_ANSI_N where control:
            model.move(by: 1)
            return true

        case kVK_ANSI_P where control:
            model.move(by: -1)
            return true

        case kVK_ANSI_P where command:
            model.togglePin()
            return true

        case kVK_ANSI_H where command:
            model.toggleMasked()
            return true

        case kVK_ANSI_C where command:
            model.copyOnly()
            return true

        case kVK_ANSI_V where command:
            // Someone reaching for Command V in a clipboard panel wants the selected entry
            // pasted, not the system clipboard dropped into the search field.
            model.paste(plainText: option)
            return true

        case kVK_Delete where command:
            model.delete()
            return true

        case kVK_Delete, kVK_ForwardDelete:
            // With the search field away there is nothing to edit, so the bare key deletes
            // the selected entry. While the field is out, deleting stays on Command.
            guard !model.searchVisible else { return false }
            model.delete()
            return true

        case kVK_ANSI_Comma where command:
            hide(restoringFocus: false)
            SettingsWindowController.shared.show()
            return true

        case kVK_ANSI_O where command:
            if let item = model.selectedItem {
                if item.kind == .link { model.openLink() }
                if item.kind == .file { model.revealInFinder() }
            }
            return true

        default:
            break
        }

        // Command plus a digit pastes that row straight away.
        if command, !option, !control, let characters = event.charactersIgnoringModifiers,
           let digit = Int(characters), digit >= 1, digit <= 9 {
            let index = digit - 1
            if model.items.indices.contains(index) {
                model.paste(model.items[index])
            }
            return true
        }

        return false
    }
}
