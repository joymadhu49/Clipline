import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Transparent area that lets a drag move the window. Used behind the header only, so rows
/// keep their own drag and drop.
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}

/// Root view of the popup panel: a search field, filter chips and the history list.
///
/// Deliberately one column. The list itself is the interface, so the panel stays narrow
/// enough to sit over your work without covering it.
struct ClipPanelView: View {
    @EnvironmentObject private var model: PanelModel
    @ObservedObject private var settings = SettingsStore.shared
    @FocusState private var searchFocused: Bool
    @State private var needsAccessibility = false
    @State private var measuredWidth: CGFloat = 380

    var body: some View {
        panelBody(width: measuredWidth)
            // Fill whatever the window offers instead of asking for a size of its own.
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(key: PanelWidthKey.self, value: geometry.size.width)
                }
            )
            .onPreferenceChange(PanelWidthKey.self) { width in
                if abs(width - measuredWidth) > 0.5 { measuredWidth = width }
            }
    }

    private func panelBody(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            list
            Divider().overlay(Theme.hairline)
            if needsAccessibility { accessibilityBar }
            footer(width: width)
        }
        // The window itself provides the rounded shape now that it has a title bar, so the
        // content just fills it.
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(Theme.panelBackground)
            }
            .ignoresSafeArea()
        )
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(Theme.surfaceStrong)
                            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                    )
                    .padding(.bottom, 44)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: model.toast)
        .onChange(of: model.focusToken) {
            searchFocused = true
            refreshAccessibilityState()
        }
        .onAppear {
            searchFocused = true
            refreshAccessibilityState()
        }
    }

    private func refreshAccessibilityState() {
        needsAccessibility = settings.pasteOnSelect && !PasteEngine.shared.accessibilityGranted
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // With search hidden the filters take the top line, so the row beside the
                // window buttons is never just empty space.
                if model.searchVisible {
                    searchField
                } else {
                    filterChips
                }

                Spacer(minLength: 4)

                if !model.searchVisible {
                    Button {
                        model.revealSearch()
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Theme.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Search, or press Command F")
                }

                Button {
                    // Keep activation with Clipline so the settings window can come forward.
                    ClipPanelController.shared.hide(restoringFocus: false)
                    SettingsWindowController.shared.show()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.tertiaryText)
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
            .padding(.leading, 48)
            .padding(.trailing, 10)
            .frame(height: 28)
            .background(WindowDragArea())
            .padding(.top, 3)
            .padding(.bottom, 7)

            if model.searchVisible {
                filterChips
                    .padding(.horizontal, 10)
                    .padding(.bottom, 7)
            }
        }
    }

    private var filterChips: some View {
        HStack(spacing: 4) {
            ForEach(ClipFilter.allCases) { filter in
                FilterPill(filter: filter, isActive: model.filter == filter) {
                    model.filter = filter
                    if model.searchVisible { searchFocused = true }
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)

            TextField("Search", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.primaryText)
                .focused($searchFocused)
                .onSubmit { model.paste() }

            if !model.query.isEmpty {
                Text("\(model.items.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.tertiaryText)
                    .monospacedDigit()
                Button {
                    model.query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        // A real field, so it reads as a control sitting beside the window buttons rather
        // than as text that failed to line up with the list below.
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(searchFocused ? Theme.accent.opacity(0.45) : Theme.hairline,
                                      lineWidth: 1)
                )
        )
    }

    // MARK: List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1, pinnedViews: []) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        if let title = sectionTitle(at: index) {
                            sectionHeader(title)
                        }
                        ClipRowView(item: item,
                                    index: index,
                                    isSelected: index == model.selectedIndex,
                                    dense: settings.denseRows,
                                    showNumber: settings.showQuickNumbers,
                                    showSource: settings.showSourceApp,
                                    onPin: { model.togglePin(item) },
                                    onDelete: { model.delete(item) })
                            .id(item.id)
                            // A single click pastes. Clicking an entry in a clipboard picker
                            // means "use this one", and waiting for a second click to decide
                            // would add a visible delay to every pick.
                            .onTapGesture {
                                model.selectedIndex = index
                                model.paste(item)
                            }
                            // The pointer carries the selection with it, so the pin and
                            // delete keys always act on the row under the mouse.
                            .onContinuousHover(coordinateSpace: .global) { phase in
                                if case .active(let location) = phase {
                                    model.hoverSelect(index, pointer: location)
                                }
                            }
                            .contextMenu { rowMenu(item) }
                            .onDrag { dragProvider(for: item) }
                            .onAppear {
                                if item.id == model.items.last?.id { model.loadMore() }
                            }
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 5)
            }
            // Scrolls only when the keyboard moved the selection. A hover selection must
            // never scroll: the pointer is already on its row, and moving the list would
            // slide a different row underneath it.
            .onChange(of: model.scrollToken) {
                let index = model.selectedIndex
                guard model.items.indices.contains(index) else { return }
                withAnimation(.easeOut(duration: 0.08)) {
                    proxy.scrollTo(model.items[index].id)
                }
            }
            .overlay {
                if model.isEmpty { emptyState }
            }
            // No scroller down the side. In a column this narrow it took a slice of every
            // row and gave nothing back; the list is short and the wheel still scrolls it.
            .scrollIndicators(.never)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Pinned entries sort to the top, so a header goes in where the two groups meet.
    /// Only while browsing the full unsearched list, where the split means something.
    private func sectionTitle(at index: Int) -> String? {
        guard model.filter == .all, model.query.isEmpty else { return nil }
        let item = model.items[index]
        if index == 0 { return item.pinned ? "Pinned" : nil }
        let previous = model.items[index - 1]
        if previous.pinned, !item.pinned { return "Recent" }
        return nil
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.tertiaryText)
            Spacer()
        }
        .padding(.horizontal, 11)
        .padding(.top, 7)
        .padding(.bottom, 3)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.query.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.tertiaryText)
            Text(emptyTitle)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
            Text(emptySubtitle)
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
        }
        .padding(.horizontal, 16)
    }

    private var emptyTitle: String {
        if !model.query.isEmpty { return "No matches" }
        switch model.filter {
        case .pinned: return "No pinned items yet"
        case .all: return "Your history is empty"
        default: return "Nothing of this kind yet"
        }
    }

    private var emptySubtitle: String {
        if !model.query.isEmpty { return "Try a shorter search or another filter." }
        if model.filter == .pinned { return "Select any entry and press Command P to keep it here for good." }
        return "Copy something and it lands here instantly."
    }

    @ViewBuilder
    private func rowMenu(_ item: ClipItem) -> some View {
        Button("Paste") { model.paste(item) }
        Button("Paste as plain text") { model.paste(item, plainText: true) }
        Button("Copy") { model.copyOnly(item) }
        Divider()
        Button(item.pinned ? "Unpin" : "Pin") { model.togglePin(item) }
        // Masking keeps the entry fully usable while the list shows its name or dots
        // instead of the content. Made for pasting on a shared or recorded screen.
        Button(item.masked ? "Show content" : "Hide content") { model.toggleMasked(item) }
        Button(item.label.isEmpty ? "Name…" : "Rename…") { model.rename(item) }
        if item.kind == .link { Button("Open link") { model.openLink(item) } }
        if item.kind == .file { Button("Reveal in Finder") { model.revealInFinder(item) } }
        Divider()
        // A pinned entry is kept on purpose, so deleting it is off the table until it is
        // unpinned.
        Button("Delete") { model.delete(item) }
            .disabled(item.pinned)
    }

    /// Drag payloads. Images offer both the file on disk and the raw bytes, so a drop lands
    /// whether the target wants a file (Finder, Mail) or image data (Pages, Figma).
    private func dragProvider(for item: ClipItem) -> NSItemProvider {
        switch item.kind {
        case .image:
            guard let url = ClipStore.shared.blobURL(id: item.id) else {
                return NSItemProvider(object: item.preview as NSString)
            }
            let type = url.pathExtension == "tiff" ? UTType.tiff : UTType.png
            let provider = NSItemProvider()
            provider.suggestedName = "Clipline image." + url.pathExtension
            provider.registerFileRepresentation(forTypeIdentifier: type.identifier,
                                                fileOptions: [],
                                                visibility: .all) { completion in
                completion(url, true, nil)
                return nil
            }
            provider.registerDataRepresentation(forTypeIdentifier: type.identifier,
                                                visibility: .all) { completion in
                DispatchQueue.global(qos: .userInitiated).async {
                    completion(try? Data(contentsOf: url), nil)
                }
                return nil
            }
            return provider

        case .file:
            let urls = ClipStore.shared.filePaths(id: item.id)
            if let first = urls.first, let provider = NSItemProvider(contentsOf: first) {
                return provider
            }
            return NSItemProvider(object: item.preview as NSString)

        case .text, .link, .color:
            return NSItemProvider(object: model.dragText(for: item) as NSString)
        }
    }

    // MARK: Footer

    /// Shown only while Clipline lacks the permission it needs to press paste for you.
    private var accessibilityBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9.5))
                .foregroundStyle(Color.orange)
            Text("Return copies only until you allow Accessibility.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Allow") {
                ClipPanelController.shared.hide()
                PasteEngine.shared.requestAccessibility()
                PasteEngine.shared.openAccessibilitySettings()
            }
            .buttonStyle(.plain)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Color.orange.opacity(0.08))
    }

    /// Hints drop away from the least important end as the panel gets narrower.
    private func footer(width: CGFloat) -> some View {
        HStack(spacing: 11) {
            hint("return", "Paste")
            if !model.searchVisible { hint("⌘F", "Search") }
            if width >= 330 { hint("⌘C", "Copy") }
            if width >= 420 { hint("⌘P", "Pin") }
            if width >= 500 { hint(model.searchVisible ? "⌘⌫" : "⌫", "Delete") }
            Spacer(minLength: 6)
            hint("esc", "Close")
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 3.5)
                .padding(.vertical, 1.5)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Theme.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(Theme.hairline, lineWidth: 1)
                        )
                )
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiaryText)
        }
    }
}

/// Carries the panel width up from a background reader.
private struct PanelWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 380
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}


/// Filter chip in the panel header.
private struct FilterPill: View {
    let filter: ClipFilter
    let isActive: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: filter.symbolName)
                    .font(.system(size: 9, weight: .medium))
                // Only the chosen filter spells itself out, so every filter fits however
                // narrow the panel is and nothing ends up half cut at the edge.
                if isActive {
                    Text(filter.title)
                        .font(.system(size: 10.5, weight: .medium))
                        .fixedSize()
                }
            }
            .foregroundStyle(isActive ? Theme.accent : Theme.secondaryText)
            .frame(height: 15)
            .padding(.horizontal, isActive ? 8 : 6)
            .padding(.vertical, 3.5)
            .background(
                Capsule()
                    .fill(isActive ? Theme.accentSoft : (isHovering ? Theme.hover : Color.clear))
                    .overlay(
                        Capsule().strokeBorder(isActive ? Theme.accent.opacity(0.35) : Theme.hairline, lineWidth: 1)
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(filter.title)
        .animation(.easeOut(duration: 0.14), value: isActive)
        .onHover { isHovering = $0 }
    }
}
