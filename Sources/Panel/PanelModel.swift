import AppKit
import SwiftUI

/// Drives the popup panel: the visible rows, the selection and every action a key can fire.
@MainActor
final class PanelModel: ObservableObject {
    @Published var query: String = "" {
        didSet {
            guard oldValue != query, !isPreparing else { return }
            // Typing anything brings the hidden field into view with the text already in it.
            if !query.isEmpty, !searchVisible { searchVisible = true }
            scheduleReload(resetSelection: true)
        }
    }
    @Published var filter: ClipFilter = .all {
        didSet { if oldValue != filter, !isPreparing { reload(resetSelection: true) } }
    }
    @Published private(set) var items: [ClipItem] = []
    @Published var selectedIndex: Int = 0
    @Published var toast: String?
    /// Bumped every time the panel opens so the search field takes focus again.
    @Published private(set) var focusToken: Int = 0
    /// The search field is off by default and appears on demand.
    @Published private(set) var searchVisible: Bool = false
    /// Bumped when the selection moves by keyboard, so the list scrolls to keep up. Hover
    /// selection deliberately leaves it alone: the pointer already sits on the row, and
    /// scrolling would drag a different row underneath it.
    @Published private(set) var scrollToken: Int = 0

    private let pageSize = 120

    private var limit = 120
    private var isPreparing = false
    /// Where the pointer was the last time a row reported it. Hover only claims the
    /// selection once the pointer has actually travelled, so a keyboard scroll sliding
    /// rows under a resting pointer cannot steal the selection back.
    private var lastPointer: CGPoint?
    private var reloadTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    var selectedItem: ClipItem? {
        items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }

    var isEmpty: Bool { items.isEmpty }

    // MARK: Loading

    func prepareForShow(filter: ClipFilter) {
        // Clearing the query and the filter here must not leave a debounced reload queued
        // behind us, or it fires later and drags the selection back to the top.
        isPreparing = true
        reloadTask?.cancel()
        query = ""
        self.filter = filter
        isPreparing = false

        limit = pageSize
        searchVisible = SettingsStore.shared.showSearchField
        // Forget the pointer between opens, so the first hover event after the panel
        // appears cannot move the selection off the top row.
        lastPointer = nil
        reload(resetSelection: true)
        focusToken &+= 1
    }

    /// Brings the search field into view. The field itself is always mounted and focused,
    /// hidden only visually, so typing reaches it whether or not it is on screen.
    func revealSearch() {
        if !searchVisible { searchVisible = true }
        focusToken &+= 1
    }

    /// Command F opens the search field, or puts it away again when it is empty.
    func toggleSearch() {
        if searchVisible, query.isEmpty, !SettingsStore.shared.showSearchField {
            searchVisible = false
        } else {
            revealSearch()
        }
    }

    /// Esc steps back: clear the text, then put the field away, then close the panel.
    /// Returns true when it handled the key.
    func dismissSearchStep() -> Bool {
        if !query.isEmpty {
            query = ""
            return true
        }
        if searchVisible, !SettingsStore.shared.showSearchField {
            searchVisible = false
            return true
        }
        return false
    }

    func reload(resetSelection: Bool = false) {
        let previousID = resetSelection ? nil : selectedItem?.id
        items = ClipStore.shared.items(filter: filter, query: query, limit: limit)
        if let previousID, let index = items.firstIndex(where: { $0.id == previousID }) {
            selectedIndex = index
        } else {
            selectedIndex = min(max(0, selectedIndex), max(0, items.count - 1))
        }
        if resetSelection {
            selectedIndex = 0
            scrollToken &+= 1
        }
    }

    func loadMore() {
        guard items.count >= limit else { return }
        limit += pageSize
        reload()
    }

    private func scheduleReload(resetSelection: Bool) {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000)
            guard !Task.isCancelled else { return }
            self?.limit = self?.pageSize ?? 120
            self?.reload(resetSelection: resetSelection)
        }
    }

    // MARK: Selection

    func move(by delta: Int) {
        guard !items.isEmpty else { return }
        let next = selectedIndex + delta
        selectedIndex = min(max(0, next), items.count - 1)
        scrollToken &+= 1
        if selectedIndex > items.count - 8 { loadMore() }
    }

    func moveToStart() {
        guard !items.isEmpty else { return }
        selectedIndex = 0
        scrollToken &+= 1
    }

    func moveToEnd() {
        guard !items.isEmpty else { return }
        selectedIndex = items.count - 1
        scrollToken &+= 1
    }

    /// Hovering a row selects it, so the pin and delete keys act on the entry under the
    /// pointer. Only real pointer travel counts: `pointer` arrives in window coordinates,
    /// which stay put while the list scrolls beneath a resting mouse.
    func hoverSelect(_ index: Int, pointer: CGPoint) {
        defer { lastPointer = pointer }
        guard items.indices.contains(index), selectedIndex != index else { return }
        guard let last = lastPointer,
              abs(pointer.x - last.x) > 1 || abs(pointer.y - last.y) > 1 else { return }
        selectedIndex = index
    }

    func cycleFilter(forward: Bool) {
        let all = ClipFilter.allCases
        guard let index = all.firstIndex(of: filter) else { return }
        let next = forward ? (index + 1) % all.count : (index - 1 + all.count) % all.count
        filter = all[next]
    }

    // MARK: Actions

    func paste(_ item: ClipItem? = nil, plainText: Bool = false) {
        guard let item = item ?? selectedItem else { return }
        let plain = plainText || SettingsStore.shared.pastePlainByDefault
        // Stay open and say so if the stored content has gone missing.
        guard PasteEngine.shared.stage(item, plainText: plain) else {
            reportMissing(item)
            return
        }
        ClipPanelController.shared.hide()
        PasteEngine.shared.deliverStagedPaste()
    }

    func copyOnly(_ item: ClipItem? = nil) {
        guard let item = item ?? selectedItem else { return }
        guard PasteEngine.shared.copy(item) else {
            reportMissing(item)
            return
        }
        ClipPanelController.shared.hide()
    }

    /// The row outlived its stored content, so drop it and tell the user why.
    private func reportMissing(_ item: ClipItem) {
        showToast("That entry is no longer available")
        ClipStore.shared.delete(id: item.id)
        reload()
    }

    func togglePin(_ item: ClipItem? = nil) {
        guard let item = item ?? selectedItem else { return }
        ClipStore.shared.setPinned(!item.pinned, id: item.id)
        showToast(item.pinned ? "Unpinned" : "Pinned")
        reload()
    }

    /// Masks or unmasks an entry. Masked entries paste as normal, but the list shows their
    /// name or dots instead of the content, safe on a shared or recorded screen.
    func toggleMasked(_ item: ClipItem? = nil) {
        guard let item = item ?? selectedItem else { return }
        ClipStore.shared.setMasked(!item.masked, id: item.id)
        showToast(item.masked ? "Content shown again" : "Content hidden")
        reload()
    }

    /// Asks for a name for the entry. The name stands in for the content in the list, which
    /// is what makes a masked entry tell you what it is without showing what it holds.
    func rename(_ item: ClipItem? = nil) {
        guard let item = item ?? selectedItem else { return }
        ClipPanelController.shared.runHoldingPanel {
            let alert = NSAlert()
            alert.messageText = "Name this entry"
            alert.informativeText = "The name is shown in the list instead of the content."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
            field.stringValue = item.label
            field.placeholderString = "Email, Password, License key…"
            alert.accessoryView = field
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            if alert.runModal() == .alertFirstButtonReturn {
                let label = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                ClipStore.shared.setLabel(label, id: item.id)
            }
        }
        reload()
    }

    func delete(_ item: ClipItem? = nil) {
        guard let item = item ?? selectedItem else { return }
        // Pinning means keep this one, so it has to be unpinned before it can go.
        guard !item.pinned else {
            showToast("Pinned. Press Command P to unpin it first")
            return
        }
        let wasSelected = selectedItem?.id == item.id
        let index = items.firstIndex(where: { $0.id == item.id }) ?? selectedIndex
        ClipStore.shared.delete(id: item.id)
        showToast("Deleted")
        reload()
        // Only take over the selection when the row that went away was the selected one.
        // Otherwise reload already restored the selection by id.
        if wasSelected, !items.isEmpty {
            selectedIndex = min(index, items.count - 1)
        }
    }

    func openLink(_ item: ClipItem? = nil) {
        guard let item = item ?? selectedItem, item.kind == .link,
              let body = ClipStore.shared.body(id: item.id),
              let url = URL(string: body.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        ClipPanelController.shared.hide()
        NSWorkspace.shared.open(url)
    }

    func revealInFinder(_ item: ClipItem? = nil) {
        guard let item = item ?? selectedItem, item.kind == .file else { return }
        let urls = ClipStore.shared.filePaths(id: item.id)
        guard !urls.isEmpty else { return }
        ClipPanelController.shared.hide()
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    /// Text handed to the drag session when a row is dragged out of the panel.
    func dragText(for item: ClipItem) -> String {
        ClipStore.shared.body(id: item.id) ?? item.preview
    }
}
