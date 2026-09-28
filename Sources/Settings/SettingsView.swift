import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, shortcuts, history, appearance, privacy, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .history: return "History"
        case .appearance: return "Appearance"
        case .privacy: return "Privacy"
        case .about: return "About"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "command"
        case .history: return "clock.arrow.circlepath"
        case .appearance: return "paintbrush"
        case .privacy: return "hand.raised"
        case .about: return "info.circle"
        }
    }
}

/// Which section the settings window is showing. Held outside the view so opening settings
/// at a particular section actually lands there, rather than the argument being accepted and
/// dropped once the window already exists.
@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var section: SettingsSection = .general
    private init() {}
}

struct SettingsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var navigation = SettingsNavigation.shared

    private var section: SettingsSection { navigation.section }

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            VStack(alignment: .leading, spacing: 0) {
                // Held above the scroll view so the section you are in stays named however
                // far down the page you are. The hairline gives the scrolling content an
                // edge to disappear behind, instead of looking sliced off mid heading.
                Text(section.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .padding(.horizontal, SettingsLayout.gutter)
                    .padding(.top, 16)
                    .padding(.bottom, 10)

                // The one rule left in the window, and it earns its keep: it gives the
                // scrolling content an edge to pass behind instead of looking sliced off.
                Divider().overlay(Theme.hairline)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        content
                    }
                    .padding(.horizontal, SettingsLayout.gutter)
                    .padding(.top, 14)
                    .padding(.bottom, 20)
                    // Capped so a widened window gives more air rather than subtitle lines
                    // long enough to lose your place in.
                    .frame(maxWidth: SettingsLayout.measure, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // No scroller. It sat over the page as a strip of chrome with nothing to do
                // with the content. The wheel, the trackpad and the arrow keys all still work.
                .scrollIndicators(.never)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 680, minHeight: 460)
        .background(Theme.dynamic(light: NSColor.white, dark: NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 1)))
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Clipline")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
            }
            // Clear of the traffic lights, which sit over this column.
            .padding(.horizontal, 13)
            .padding(.top, 26)
            .padding(.bottom, 10)

            ForEach(SettingsSection.allCases) { item in
                SidebarButton(section: item, isActive: section == item) { navigation.section = item }
            }

            Spacer()

            Text(SettingsLayout.versionText)
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.tertiaryText)
                .padding(.horizontal, 13)
                .padding(.bottom, 10)
        }
        .frame(width: 150)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebarBackground)
    }

    // MARK: Sections

    @ViewBuilder
    private var content: some View {
        switch section {
        case .general: GeneralSettings()
        case .shortcuts: ShortcutSettings()
        case .history: HistorySettings()
        case .appearance: AppearanceSettings()
        case .privacy: PrivacySettings()
        case .about: AboutSettings()
        }
    }
}

// MARK: General

private struct GeneralSettings: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var accessibilityGranted = PasteEngine.shared.accessibilityGranted

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsGroup("Running") {
                SettingsToggle(title: "Launch at login",
                               subtitle: "Clipline starts quietly with your Mac",
                               isOn: $settings.launchAtLogin)
                SettingsToggle(title: "Show icon in the menu bar",
                               subtitle: "Turn this off to run with the shortcut alone",
                               isOn: $settings.showMenuBarIcon)
                SettingsToggle(title: "Close the panel when you click elsewhere",
                               subtitle: "Turn this off to leave the panel open beside your work",
                               isOn: $settings.hideOnFocusLoss)
                SettingsToggle(title: "Pause capturing",
                               subtitle: "Nothing new is recorded while this is on",
                               isOn: $settings.monitoringPaused)
            }

            SettingsGroup("Pasting") {
                SettingsToggle(title: "Paste into the active app",
                               subtitle: "Selecting an entry types it straight into your app",
                               isOn: $settings.pasteOnSelect)
                SettingsToggle(title: "Paste as plain text by default",
                               subtitle: "Drops fonts and colors, keeps the words",
                               isOn: $settings.pastePlainByDefault)
                SettingsRow(title: "Detection speed",
                            subtitle: settings.detectionSpeed.subtitle) {
                    Picker("", selection: $settings.detectionSpeed) {
                        ForEach(DetectionSpeed.allCases, id: \.self) { speed in
                            Text(speed.title).tag(speed)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            if settings.pasteOnSelect {
                SettingsGroup("Permission") {
                    SettingsRow(title: accessibilityGranted ? "Accessibility access granted" : "Accessibility access needed",
                                subtitle: accessibilityGranted
                                ? "Clipline can paste into other apps"
                                : "macOS needs your permission before Clipline can press paste for you") {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(accessibilityGranted ? Color.green : Theme.danger)
                                .frame(width: 7, height: 7)
                            if !accessibilityGranted {
                                Button("Open System Settings") {
                                    PasteEngine.shared.requestAccessibility()
                                    PasteEngine.shared.openAccessibilitySettings()
                                }
                                .buttonStyle(GhostButtonStyle())
                            }
                        }
                    }
                }
                .onAppear { accessibilityGranted = PasteEngine.shared.accessibilityGranted }
            }
        }
    }
}

// MARK: Shortcuts

private struct ShortcutSettings: View {
    @ObservedObject private var settings = SettingsStore.shared

    private let panelKeys: [(String, String)] = [
        ("↑ ↓", "Move through the list"),
        ("return", "Paste the selected entry"),
        ("⌥return", "Paste without formatting"),
        ("⌘return", "Copy without pasting"),
        ("⌘1 … ⌘9", "Paste that numbered row"),
        ("⌘P", "Pin or unpin"),
        ("⌘H", "Hide or show the entry's content in the list"),
        ("⌘⌫", "Delete the entry, unless it is pinned"),
        ("⌫", "Also deletes, while the search field is away"),
        ("⌘F", "Show or hide the search field"),
        ("tab", "Next filter, ⇧tab for the previous one"),
        ("⌘O", "Open a link, or reveal a file in Finder"),
        ("⌘,", "Open settings"),
        ("esc", "Clear the search, then close")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsGroup("Global",
                          caption: "Work anywhere on the Mac. Click one to record; esc cancels, delete clears.",
                          actionTitle: "Reset to defaults",
                          action: { settings.resetShortcuts() }) {
                ForEach(Array(ActionID.allCases.enumerated()), id: \.element) { index, action in
                    SettingsRow(title: action.title, subtitle: action.subtitle) {
                        ShortcutRecorder(action: action)
                            .frame(width: SettingsLayout.recorder, height: 24)
                    }
                }
            }

            SettingsGroup("Inside the panel", caption: "Fixed, and listed so they are never a guess.") {
                ForEach(Array(panelKeys.enumerated()), id: \.offset) { index, pair in
                    HStack(spacing: 10) {
                        KeyCap(pair.0)
                            .frame(width: 66, alignment: .trailing)
                        Text(pair.1)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.secondaryText)
                        Spacer(minLength: 4)
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 12)
                }
            }
        }
    }
}

// MARK: History

private struct HistorySettings: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var stats = ClipStore.Stats()
    @State private var confirmingClear = false
    @State private var cleaning = false

    private let limits = [100, 250, 500, 1000, 2500]
    /// In hours.
    private let retentions: [(Int, String)] = [
        (0, "Forever"), (3, "3 hours"), (5, "5 hours"), (24, "1 day"),
        (7 * 24, "7 days"), (30 * 24, "30 days"), (90 * 24, "90 days")
    ]
    private let sizes = [2, 4, 8, 16, 32]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsGroup("Limits") {
                SettingsRow(title: "Keep at most",
                            subtitle: "Older entries drop off. Pinned entries always stay.") {
                    Picker("", selection: $settings.historyLimit) {
                        ForEach(limits, id: \.self) { Text("\($0) items").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsRow(title: "Keep entries for",
                            subtitle: "Anything older is removed automatically. Pinned entries always stay.") {
                    Picker("", selection: $settings.retentionHours) {
                        ForEach(retentions, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsRow(title: "Skip anything larger than",
                            subtitle: "Protects memory and disk from very large copies") {
                    Picker("", selection: $settings.maxItemMegabytes) {
                        ForEach(sizes, id: \.self) { Text("\($0) MB").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            SettingsGroup("What is kept") {
                SettingsToggle(title: "Store images",
                               subtitle: "Screenshots and copied pictures are kept as files, not in memory",
                               isOn: $settings.storeImages)
                SettingsToggle(title: "Store copied files",
                               subtitle: "Remembers the file paths so you can paste them again",
                               isOn: $settings.storeFiles)
            }

            SettingsGroup("Storage") {
                SettingsRow(title: "Storage in use", subtitle: storageSubtitle) {
                    QuietButton("Refresh") { refresh() }
                }
                SettingsRow(title: "Clean up now",
                            subtitle: "Applies your limits and reclaims space right away") {
                    QuietButton(cleaning ? "Working" : "Clean up") {
                        let limit = settings.historyLimit
                        let hours = settings.retentionHours
                        cleaning = true
                        ThumbnailCache.shared.clear()
                        DispatchQueue.global(qos: .userInitiated).async {
                            ClipStore.shared.trimNow(historyLimit: limit, retentionHours: hours)
                            ClipStore.shared.compact()
                            DispatchQueue.main.async {
                                cleaning = false
                                refresh()
                            }
                        }
                    }
                    .disabled(cleaning)
                }
                SettingsRow(title: "Clear history",
                            subtitle: confirmingClear ? "This cannot be undone" : "Removes every entry that is not pinned") {
                    HStack(spacing: 6) {
                        if confirmingClear {
                            Button("Cancel") { confirmingClear = false }
                                .buttonStyle(GhostButtonStyle())
                            Button("Delete all") {
                                ThumbnailCache.shared.clear()
                                confirmingClear = false
                                ClipStore.shared.clearInBackground(includingPinned: false) {
                                    refresh()
                                }
                            }
                            .buttonStyle(GhostButtonStyle(tint: Theme.danger))
                        } else {
                            Button("Clear") { confirmingClear = true }
                                .buttonStyle(GhostButtonStyle(tint: Theme.danger))
                        }
                    }
                }
            }
        }
        .onAppear { refresh() }
    }

    private var storageSubtitle: String {
        let items = stats.total == 1 ? "1 entry" : "\(stats.total) entries"
        let pinned = stats.pinned == 1 ? "1 pinned" : "\(stats.pinned) pinned"
        return "\(items), \(pinned), using \(format(stats.totalBytes)) on disk"
    }

    private func format(_ bytes: Int64) -> String {
        let value = Double(bytes)
        if value < 1024 { return "\(bytes) B" }
        if value < 1024 * 1024 { return String(format: "%.0f KB", value / 1024) }
        return String(format: "%.1f MB", value / (1024 * 1024))
    }

    private func refresh() {
        DispatchQueue.global(qos: .userInitiated).async {
            let value = ClipStore.shared.stats()
            DispatchQueue.main.async { stats = value }
        }
    }
}

// MARK: Appearance

private struct AppearanceSettings: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsGroup("The panel",
                          actionTitle: "Reset",
                          actionEnabled: settings.hasCustomPanelFrame,
                          action: { settings.resetPanelFrame() }) {
                SettingsRow(title: "Theme", subtitle: "How the panel and this window are painted") {
                    Picker("", selection: $settings.appearanceMode) {
                        ForEach(AppearanceMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsRow(title: "Panel size",
                            subtitle: "A starting size. Drag any edge to change it.") {
                    Picker("", selection: $settings.panelSize) {
                        ForEach(PanelSize.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsRow(title: "Panel appears",
                            subtitle: "Dragging the panel switches this to where you left it.") {
                    Picker("", selection: $settings.panelPlacement) {
                        ForEach(PanelPlacement.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            SettingsGroup("What the rows show") {
                SettingsToggle(title: "Always show the search field",
                               subtitle: "Off by default. Press Command F or simply start typing to search.",
                               isOn: $settings.showSearchField)
                SettingsToggle(title: "Show quick numbers",
                               subtitle: "Command with a number pastes that row instantly",
                               isOn: $settings.showQuickNumbers)
                SettingsToggle(title: "Show the source app",
                               subtitle: "Each row says where the copy came from",
                               isOn: $settings.showSourceApp)
                SettingsToggle(title: "Compact rows",
                               subtitle: "Single line rows so more history fits on screen",
                               isOn: $settings.denseRows)
            }

            HStack {
                Spacer()
                Button("Preview the panel") {
                    ClipPanelController.shared.show()
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }
}

// MARK: Privacy

private struct PrivacySettings: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsGroup("What is never recorded") {
                SettingsToggle(title: "Ignore passwords and hidden content",
                               subtitle: "Skips anything an app marks as concealed, such as password managers",
                               isOn: $settings.ignoreConcealed)
                SettingsToggle(title: "Clear history when Clipline quits",
                               subtitle: "Pinned entries are kept",
                               isOn: $settings.clearOnQuit)
            }

            SettingsGroup("On a shared screen") {
                SettingsToggle(title: "Keep the panel out of recordings and streams",
                               subtitle: "The panel never appears in screen capture, streaming or screen sharing. You still see it as normal",
                               isOn: $settings.hidePanelFromCapture)
            }

            SettingsGroup("Apps to ignore",
                          caption: "Copies made while one of these apps is in front are never recorded.",
                          actionTitle: "Add an app",
                          action: { pickApp() }) {
                if settings.ignoredBundleIDs.isEmpty {
                    HStack {
                        Text("No apps are being ignored")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.tertiaryText)
                        Spacer()
                    }
                    .padding(.vertical, 9)
                    .padding(.horizontal, 12)
                } else {
                    ForEach(Array(settings.ignoredBundleIDs.enumerated()), id: \.element) { index, bundleID in
                        HStack(spacing: 9) {
                            if let image = icon(for: bundleID) {
                                Image(nsImage: image)
                                    .resizable()
                                    .frame(width: 16, height: 16)
                            } else {
                                Image(systemName: "app.dashed")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.tertiaryText)
                                    .frame(width: 16, height: 16)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(displayName(for: bundleID))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Theme.primaryText)
                                Text(bundleID)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.tertiaryText)
                            }
                            Spacer()
                            IconButton(symbol: "minus.circle",
                                       help: "Stop ignoring \(displayName(for: bundleID))",
                                       danger: true) {
                                settings.ignoredBundleIDs.removeAll { $0 == bundleID }
                            }
                        }
                        .padding(.vertical, 5.5)
                        .padding(.horizontal, 12)
                    }
                }
            }
        }
    }

    /// Nil when the app is not installed, so the row can say so rather than showing the
    /// generic bundle icon and looking like a broken image.
    private func icon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Names for apps that may not be installed, so the list never shows a raw bundle id.
    private static let knownNames = [
        "com.apple.keychainaccess": "Keychain Access",
        "com.agilebits.onepassword7": "1Password 7",
        "com.1password.1password": "1Password",
        "com.bitwarden.desktop": "Bitwarden"
    ]

    private func displayName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        if let known = Self.knownNames[bundleID] { return known }
        let last = bundleID.components(separatedBy: ".").last ?? bundleID
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Ignore"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else { continue }
            if !settings.ignoredBundleIDs.contains(identifier) {
                settings.ignoredBundleIDs.append(identifier)
            }
        }
    }
}

// MARK: About

private struct AboutSettings: View {
    @ObservedObject private var updates = UpdateController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsCard {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                        .resizable()
                        .frame(width: 46, height: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clipline")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.primaryText)
                        Text(SettingsLayout.versionText)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.tertiaryText)
                        Text("A quiet clipboard history for macOS. Everything stays on this Mac.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                }
                .padding(12)
            }

            SettingsGroup("Updates") {
                SettingsToggle(title: "Check for updates automatically",
                               subtitle: "Once a day, from GitHub. Updates are signed and verified before they install.",
                               isOn: $updates.automaticallyChecks)
                SettingsRow(title: "Check now", subtitle: lastCheckText) {
                    QuietButton("Check for Updates") { updates.checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates)
                }
            }

            SettingsGroup("How it behaves") {
                aboutRow("Local only", "History lives in your Application Support folder and is never uploaded. The only thing Clipline asks the internet for is whether a new version exists.")
                aboutRow("Light on memory", "Rows hold a short preview. Full text and images are read from disk only when you look at them.")
                aboutRow("Light on disk", "Duplicates fold into one entry, large copies are skipped, and old entries are trimmed automatically.")
            }

            HStack(spacing: 8) {
                Button("Open the panel") { ClipPanelController.shared.show() }
                    .buttonStyle(GhostButtonStyle())
                Spacer()
                Button("Quit Clipline") { NSApp.terminate(nil) }
                    .buttonStyle(GhostButtonStyle(tint: Theme.danger))
            }
        }
    }

    private var lastCheckText: String {
        guard let last = updates.lastCheck else { return "Not checked yet" }
        // Sparkle stamps the date on first launch, a moment before the view reads it, and
        // the formatter would then say "in 0 seconds".
        guard Date().timeIntervalSince(last) >= 60 else { return "Last checked just now" }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .full
        return "Last checked \(relative.localizedString(for: last, relativeTo: Date()))"
    }

    private func aboutRow(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.primaryText)
            Text(subtitle)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
        .padding(.horizontal, 12)
    }
}

// MARK: Shared pieces

/// The handful of measurements that keep every section reading as one page.
enum SettingsLayout {
    /// Controls in the right hand column are flush right, so they line up on their trailing
    /// edge without a shared width. Pickers size to their own content; only the recorder,
    /// being an AppKit view, needs telling.
    static let recorder: CGFloat = 112
    static let gutter: CGFloat = 22
    /// Longest a line of body text is allowed to get, however wide the window is dragged.
    static let measure: CGFloat = 600

    static var versionText: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "Version \(short)"
    }
}

/// A named card. Anonymous stacked cards left the reader working out for themselves why
/// two settings had been put together, so every group says what it is.
struct SettingsGroup<Content: View>: View {
    let title: String
    var caption: String?
    var actionTitle: String?
    var actionEnabled: Bool = true
    var action: (() -> Void)?
    @ViewBuilder let content: Content

    init(_ title: String,
         caption: String? = nil,
         actionTitle: String? = nil,
         actionEnabled: Bool = true,
         action: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.caption = caption
        self.actionTitle = actionTitle
        self.actionEnabled = actionEnabled
        self.action = action
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.tertiaryText)
                Spacer(minLength: 4)
                // The group's own action rides in its heading. Left on its own below the
                // card it was a button floating in a gap, unattached to anything.
                if let actionTitle, let action {
                    QuietButton(actionTitle, action: action)
                        .disabled(!actionEnabled)
                        .opacity(actionEnabled ? 1 : 0.4)
                }
            }

            if let caption {
                Text(caption)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 1)
            }

            SettingsCard { content }
        }
    }
}

/// A text button with no chrome of its own, for actions that belong to a heading rather
/// than to the page.
struct QuietButton: View {
    let title: String
    let action: () -> Void

    @State private var isHovering = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isHovering ? Theme.accent : Theme.secondaryText)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// A key drawn as a key. Matches the hints along the bottom of the panel, so the same
/// shortcut looks the same wherever Clipline shows it.
struct KeyCap: View {
    let label: String

    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 5)
            .padding(.vertical, 2.5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Theme.surfaceStrong)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    )
            )
            .fixedSize()
    }
}

/// A glyph that behaves like a button without wearing a full bordered one. The destructive
/// tint waits until the pointer is actually on it.
struct IconButton: View {
    let symbol: String
    var help: String = ""
    var danger: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovering ? (danger ? Theme.danger.opacity(0.14) : Theme.hover) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovering = $0 }
    }

    private var tint: Color {
        if danger { return isHovering ? Theme.danger : Theme.tertiaryText }
        return isHovering ? Theme.primaryText : Theme.tertiaryText
    }
}

private struct SidebarButton: View {
    let section: SettingsSection
    let isActive: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: section.symbolName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isActive ? Theme.accent : Theme.tertiaryText)
                    .frame(width: 14)
                Text(section.title)
                    .font(.system(size: 11.5, weight: isActive ? .medium : .regular))
                    .foregroundStyle(isActive ? Theme.primaryText : Theme.secondaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4.5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isActive ? Theme.selection : (isHovering ? Theme.hover : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { isHovering = $0 }
    }
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.card)
            )
    }
}

struct SettingsRow<Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1.5) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 10)
            accessory
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
    }
}

struct SettingsToggle: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    @State private var isHovering = false

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Theme.accent)
        }
        .background { isHovering ? Theme.hover : Color.clear }
        // The label is the obvious thing to hit, so the whole row takes the click rather
        // than asking for the switch itself every time.
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
        .onHover { isHovering = $0 }
    }
}
