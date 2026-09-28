import AppKit
import Combine
import ServiceManagement

/// How often the pasteboard is checked for changes.
enum DetectionSpeed: String, CaseIterable, Codable {
    case instant, fast, balanced, relaxed

    var interval: TimeInterval {
        switch self {
        case .instant: return 0.15
        case .fast: return 0.35
        case .balanced: return 0.7
        case .relaxed: return 1.5
        }
    }

    var title: String {
        switch self {
        case .instant: return "Instant"
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .relaxed: return "Relaxed"
        }
    }

    var subtitle: String {
        switch self {
        case .instant: return "Checks every 0.15 seconds"
        case .fast: return "Checks every 0.35 seconds"
        case .balanced: return "Checks every 0.7 seconds"
        case .relaxed: return "Checks every 1.5 seconds, lightest on battery"
        }
    }
}

/// Where the panel appears when the shortcut is pressed.
enum PanelPlacement: String, CaseIterable, Codable {
    case remembered, center, pointer, menuBar

    var title: String {
        switch self {
        case .remembered: return "Where you left it"
        case .center: return "Center of screen"
        case .pointer: return "At the pointer"
        case .menuBar: return "Under the menu bar"
        }
    }
}

enum PanelSize: String, CaseIterable, Codable {
    case compact, standard, large

    var title: String {
        switch self {
        case .compact: return "Compact"
        case .standard: return "Standard"
        case .large: return "Large"
        }
    }

    var size: NSSize {
        switch self {
        case .compact: return NSSize(width: 340, height: 400)
        case .standard: return NSSize(width: 400, height: 500)
        case .large: return NSSize(width: 480, height: 620)
        }
    }

    /// Smallest and largest the panel can be dragged to.
    static let minimumSize = NSSize(width: 280, height: 220)
    static let maximumSize = NSSize(width: 900, height: 1100)
}

enum AppearanceMode: String, CaseIterable, Codable {
    case system, dark, light

    var title: String {
        switch self {
        case .system: return "Match system"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        }
    }
}

/// UserDefaults backed app settings, observable by SwiftUI.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    // MARK: General
    @Published var launchAtLogin: Bool { didSet { save("launchAtLogin", launchAtLogin); applyLoginItem() } }
    @Published var pasteOnSelect: Bool { didSet { save("pasteOnSelect", pasteOnSelect) } }
    @Published var pastePlainByDefault: Bool { didSet { save("pastePlainByDefault", pastePlainByDefault) } }
    @Published var detectionSpeed: DetectionSpeed { didSet { save("detectionSpeed", detectionSpeed.rawValue); notifyMonitor() } }
    @Published var monitoringPaused: Bool { didSet { save("monitoringPaused", monitoringPaused); notifyMonitor() } }
    @Published var showMenuBarIcon: Bool { didSet { save("showMenuBarIcon", showMenuBarIcon); notifyMenuBar() } }

    // MARK: History
    @Published var historyLimit: Int { didSet { save("historyLimit", historyLimit) } }
    /// How long an unpinned entry is kept, in hours. Zero keeps it forever.
    @Published var retentionHours: Int { didSet { save("retentionHours", retentionHours); notifyRetention() } }
    @Published var storeImages: Bool { didSet { save("storeImages", storeImages) } }
    @Published var storeFiles: Bool { didSet { save("storeFiles", storeFiles) } }
    @Published var maxItemMegabytes: Int { didSet { save("maxItemMegabytes", maxItemMegabytes) } }

    // MARK: Appearance
    /// Picking a preset resets the remembered size the user may have dragged to.
    @Published var panelSize: PanelSize {
        didSet {
            save("panelSize", panelSize.rawValue)
            panelWidth = panelSize.size.width
            panelHeight = panelSize.size.height
            notifyAppearance()
        }
    }
    @Published var panelWidth: Double { didSet { save("panelWidth", panelWidth) } }
    @Published var panelHeight: Double { didSet { save("panelHeight", panelHeight) } }
    /// Where the user last dragged the panel to. Negative values are legitimate on a second
    /// display, so "not set yet" is tracked separately.
    @Published var panelOriginX: Double { didSet { save("panelOriginX", panelOriginX) } }
    @Published var panelOriginY: Double { didSet { save("panelOriginY", panelOriginY) } }
    @Published var hasPanelOrigin: Bool { didSet { save("hasPanelOrigin", hasPanelOrigin) } }
    @Published var hideOnFocusLoss: Bool { didSet { save("hideOnFocusLoss", hideOnFocusLoss) } }
    @Published var panelPlacement: PanelPlacement { didSet { save("panelPlacement", panelPlacement.rawValue) } }
    @Published var appearanceMode: AppearanceMode { didSet { save("appearanceMode", appearanceMode.rawValue); notifyAppearance() } }
    @Published var showSearchField: Bool { didSet { save("showSearchField", showSearchField); notifyAppearance() } }
    @Published var showQuickNumbers: Bool { didSet { save("showQuickNumbers", showQuickNumbers); notifyAppearance() } }
    @Published var showSourceApp: Bool { didSet { save("showSourceApp", showSourceApp); notifyAppearance() } }
    @Published var denseRows: Bool { didSet { save("denseRows", denseRows); notifyAppearance() } }

    // MARK: Privacy
    @Published var ignoreConcealed: Bool { didSet { save("ignoreConcealed", ignoreConcealed) } }
    /// Keeps the panel out of screen recordings, streams and screen sharing. The panel
    /// looks the same in person; capture simply never carries it.
    @Published var hidePanelFromCapture: Bool { didSet { save("hidePanelFromCapture", hidePanelFromCapture); notifyAppearance() } }
    @Published var clearOnQuit: Bool { didSet { save("clearOnQuit", clearOnQuit) } }
    @Published var ignoredBundleIDs: [String] { didSet { save("ignoredBundleIDs", ignoredBundleIDs) } }

    // MARK: Shortcuts
    @Published private(set) var shortcuts: [String: Shortcut]

    private init() {
        launchAtLogin = defaults.object(forKey: "launchAtLogin") as? Bool ?? false
        pasteOnSelect = defaults.object(forKey: "pasteOnSelect") as? Bool ?? true
        pastePlainByDefault = defaults.object(forKey: "pastePlainByDefault") as? Bool ?? false
        detectionSpeed = DetectionSpeed(rawValue: defaults.string(forKey: "detectionSpeed") ?? "fast") ?? .fast
        monitoringPaused = defaults.object(forKey: "monitoringPaused") as? Bool ?? false
        showMenuBarIcon = defaults.object(forKey: "showMenuBarIcon") as? Bool ?? true
        historyLimit = defaults.object(forKey: "historyLimit") as? Int ?? 500
        // Retention used to be stored in days. Carry an old choice over rather than
        // quietly resetting it to forever.
        retentionHours = defaults.object(forKey: "retentionHours") as? Int
            ?? (defaults.object(forKey: "retentionDays") as? Int).map { $0 * 24 }
            ?? 0
        storeImages = defaults.object(forKey: "storeImages") as? Bool ?? true
        storeFiles = defaults.object(forKey: "storeFiles") as? Bool ?? true
        maxItemMegabytes = defaults.object(forKey: "maxItemMegabytes") as? Int ?? 8
        let storedSize = PanelSize(rawValue: defaults.string(forKey: "panelSize") ?? "compact") ?? .compact
        panelSize = storedSize
        panelWidth = defaults.object(forKey: "panelWidth") as? Double ?? storedSize.size.width
        panelHeight = defaults.object(forKey: "panelHeight") as? Double ?? storedSize.size.height
        panelPlacement = PanelPlacement(rawValue: defaults.string(forKey: "panelPlacement") ?? "remembered") ?? .remembered
        panelOriginX = defaults.object(forKey: "panelOriginX") as? Double ?? 0
        panelOriginY = defaults.object(forKey: "panelOriginY") as? Double ?? 0
        hasPanelOrigin = defaults.object(forKey: "hasPanelOrigin") as? Bool ?? false
        hideOnFocusLoss = defaults.object(forKey: "hideOnFocusLoss") as? Bool ?? true
        appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: "appearanceMode") ?? "system") ?? .system
        showSearchField = defaults.object(forKey: "showSearchField") as? Bool ?? false
        showQuickNumbers = defaults.object(forKey: "showQuickNumbers") as? Bool ?? true
        showSourceApp = defaults.object(forKey: "showSourceApp") as? Bool ?? true
        denseRows = defaults.object(forKey: "denseRows") as? Bool ?? false
        ignoreConcealed = defaults.object(forKey: "ignoreConcealed") as? Bool ?? true
        hidePanelFromCapture = defaults.object(forKey: "hidePanelFromCapture") as? Bool ?? true
        clearOnQuit = defaults.object(forKey: "clearOnQuit") as? Bool ?? false
        ignoredBundleIDs = defaults.stringArray(forKey: "ignoredBundleIDs") ?? SettingsStore.defaultIgnoredBundleIDs

        if let data = defaults.data(forKey: "shortcuts"),
           let decoded = try? JSONDecoder().decode([String: Shortcut].self, from: data) {
            shortcuts = decoded
        } else {
            var initial: [String: Shortcut] = [:]
            for action in ActionID.allCases {
                if let value = action.defaultShortcut { initial[action.rawValue] = value }
            }
            shortcuts = initial
        }
    }

    /// Password managers that should never have their clipboard recorded.
    static let defaultIgnoredBundleIDs = [
        "com.apple.keychainaccess",
        "com.agilebits.onepassword7",
        "com.1password.1password",
        "com.bitwarden.desktop"
    ]

    var maxItemBytes: Int { maxItemMegabytes * 1024 * 1024 }

    /// The size the panel opens at, kept inside the allowed range.
    var panelFrameSize: NSSize {
        NSSize(width: min(max(panelWidth, PanelSize.minimumSize.width), PanelSize.maximumSize.width),
               height: min(max(panelHeight, PanelSize.minimumSize.height), PanelSize.maximumSize.height))
    }

    /// Records where the user dragged the panel so it opens there next time.
    func rememberPanelOrigin(_ origin: NSPoint) {
        panelOriginX = Double(origin.x)
        panelOriginY = Double(origin.y)
        hasPanelOrigin = true
    }

    /// Forgets the spot and the size the panel was dragged to, so the next open uses the
    /// preset again. The way back when the panel was left on a display that is now gone.
    func resetPanelFrame() {
        hasPanelOrigin = false
        panelOriginX = 0
        panelOriginY = 0
        panelWidth = panelSize.size.width
        panelHeight = panelSize.size.height
        notifyAppearance()
    }

    /// True once the panel has been put somewhere by hand, which is what the reset button
    /// in Settings has to offer itself for.
    var hasCustomPanelFrame: Bool {
        hasPanelOrigin
            || abs(panelWidth - panelSize.size.width) > 0.5
            || abs(panelHeight - panelSize.size.height) > 0.5
    }

    /// Records a size the user reached by dragging the panel edge. Values outside the
    /// allowed range are clamped so a stray layout pass can never store a broken size.
    func rememberPanelSize(_ size: NSSize) {
        let width = min(max(Double(size.width), PanelSize.minimumSize.width), PanelSize.maximumSize.width)
        let height = min(max(Double(size.height), PanelSize.minimumSize.height), PanelSize.maximumSize.height)
        guard abs(width - panelWidth) > 0.5 || abs(height - panelHeight) > 0.5 else { return }
        panelWidth = width
        panelHeight = height
    }

    // MARK: Shortcut access

    func shortcut(for action: ActionID) -> Shortcut? {
        shortcuts[action.rawValue]
    }

    func setShortcut(_ shortcut: Shortcut?, for action: ActionID) {
        if let shortcut {
            shortcuts[action.rawValue] = shortcut
        } else {
            shortcuts.removeValue(forKey: action.rawValue)
        }
        if let data = try? JSONEncoder().encode(shortcuts) {
            defaults.set(data, forKey: "shortcuts")
        }
        HotkeyCenter.shared.reloadAll(from: self)
        NotificationCenter.default.post(name: .clipShortcutsChanged, object: nil)
    }

    func resetShortcuts() {
        var initial: [String: Shortcut] = [:]
        for action in ActionID.allCases {
            if let value = action.defaultShortcut { initial[action.rawValue] = value }
        }
        shortcuts = initial
        if let data = try? JSONEncoder().encode(shortcuts) {
            defaults.set(data, forKey: "shortcuts")
        }
        HotkeyCenter.shared.reloadAll(from: self)
        NotificationCenter.default.post(name: .clipShortcutsChanged, object: nil)
    }

    // MARK: Helpers

    private func save(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
    }

    private func notifyMonitor() {
        NotificationCenter.default.post(name: .clipMonitorSettingsChanged, object: nil)
    }

    private func notifyAppearance() {
        NotificationCenter.default.post(name: .clipAppearanceChanged, object: nil)
    }

    private func notifyRetention() {
        NotificationCenter.default.post(name: .clipRetentionChanged, object: nil)
    }

    private func notifyMenuBar() {
        NotificationCenter.default.post(name: .clipMenuBarChanged, object: nil)
    }

    private func applyLoginItem() {
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            NSLog("Clipline login item error: %@", error.localizedDescription)
        }
    }
}

extension Notification.Name {
    static let clipMonitorSettingsChanged = Notification.Name("com.joymadhu.Clipline.monitorSettingsChanged")
    static let clipAppearanceChanged = Notification.Name("com.joymadhu.Clipline.appearanceChanged")
    static let clipMenuBarChanged = Notification.Name("com.joymadhu.Clipline.menuBarChanged")
    static let clipRetentionChanged = Notification.Name("com.joymadhu.Clipline.retentionChanged")
}
