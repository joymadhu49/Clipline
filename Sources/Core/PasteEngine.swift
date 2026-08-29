import AppKit
import Carbon.HIToolbox

/// Puts history entries back on the pasteboard and, when allowed, pastes them into the
/// app the user was working in.
final class PasteEngine {
    static let shared = PasteEngine()

    private(set) var targetApp: NSRunningApplication?

    private init() {}

    /// Remembers the app that was frontmost before the panel took focus.
    func rememberFrontmostApp() {
        let current = NSWorkspace.shared.frontmostApplication
        if current?.bundleIdentifier != Bundle.main.bundleIdentifier {
            targetApp = current
        }
    }

    var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// What will be written to the pasteboard, gathered before anything is cleared.
    private enum Payload {
        case image(Data, NSPasteboard.PasteboardType)
        case files([URL])
        case text(String, rtf: Data?)
    }

    /// Reads an entry back off disk. Returns nil when the stored content is gone.
    private func payload(for item: ClipItem, plainText: Bool) -> Payload? {
        switch item.kind {
        case .image:
            guard let url = ClipStore.shared.blobURL(id: item.id),
                  let data = try? Data(contentsOf: url) else { return nil }
            return .image(data, url.pathExtension == "tiff" ? .tiff : .png)

        case .file:
            let urls = ClipStore.shared.filePaths(id: item.id)
            guard !urls.isEmpty else { return nil }
            return .files(urls)

        case .text, .link, .color:
            guard let body = ClipStore.shared.body(id: item.id) else { return nil }
            let rtf = plainText ? nil : ClipStore.shared.richTextData(id: item.id)
            return .text(body, rtf: rtf)
        }
    }

    /// Writes an entry to the general pasteboard. Returns false when the payload is gone.
    ///
    /// The payload is read first and the pasteboard is only cleared once there is something
    /// to put on it, so a missing file can never leave the user with an empty clipboard.
    @discardableResult
    func placeOnPasteboard(_ item: ClipItem, plainText: Bool) -> Bool {
        guard let payload = payload(for: item, plainText: plainText) else { return false }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch payload {
        case .image(let data, let type):
            // Apps disagree about which image flavour they accept, so offer both. Preview and
            // Finder reach for PNG, while Pages, Mail and most editors want TIFF.
            let entry = NSPasteboardItem()
            entry.setData(data, forType: type)
            if type == .png, let tiff = NSImage(data: data)?.tiffRepresentation {
                entry.setData(tiff, forType: .tiff)
            } else if type == .tiff, let png = ClipboardMonitor.convertToPNG(data) {
                entry.setData(png, forType: .png)
            }
            pasteboard.writeObjects([entry])
        case .files(let urls):
            pasteboard.writeObjects(urls as [NSURL])
        case .text(let body, let rtf):
            if let rtf { pasteboard.setData(rtf, forType: .rtf) }
            pasteboard.setString(body, forType: .string)
        }
        ClipboardMonitor.shared.markOwnWrite()
        return true
    }

    /// Copies an entry without pasting it.
    @discardableResult
    func copy(_ item: ClipItem, plainText: Bool = false) -> Bool {
        let placed = placeOnPasteboard(item, plainText: plainText)
        if placed { ClipStore.shared.touch(id: item.id) }
        return placed
    }

    /// Puts an entry on the pasteboard ready to be pasted, without pasting it yet.
    /// Returns false when the stored content could not be read.
    func stage(_ item: ClipItem, plainText: Bool) -> Bool {
        guard placeOnPasteboard(item, plainText: plainText) else { return false }
        ClipStore.shared.touch(id: item.id)
        return true
    }

    /// Sends the paste keystroke for a staged entry. Call once the panel is out of the way,
    /// so the keystroke lands in the app the user was working in.
    func deliverStagedPaste() {
        guard SettingsStore.shared.pasteOnSelect, accessibilityGranted else { return }
        deliverPaste()
    }

    /// Returns focus to the previous app, then synthesises the paste keystroke.
    private func deliverPaste() {
        guard let target = targetApp, !target.isTerminated else {
            sendPasteKeystroke()
            return
        }
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: target)
        }
        target.activate(options: [])
        waitForActivation(of: target, attempt: 0)
    }

    /// Polls briefly so the keystroke never lands before the target app is frontmost.
    private func waitForActivation(of target: NSRunningApplication, attempt: Int) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier || attempt >= 12 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                self?.sendPasteKeystroke()
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.waitForActivation(of: target, attempt: attempt + 1)
        }
    }

    private func sendPasteKeystroke() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        source.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents],
                                                          state: .eventSuppressionStateSuppressionInterval)
        let key = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// Captures whatever is on the pasteboard right now and pins that exact entry.
    func pinCurrentClipboard() {
        ClipboardMonitor.shared.captureNow { id in
            guard let id else { return }
            ClipStore.shared.setPinned(true, id: id)
        }
    }
}
