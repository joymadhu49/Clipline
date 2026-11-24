import AppKit
import SwiftUI

/// One gesture for everything a left press on a row can mean: a click pastes, holding still
/// opens the preview, and moving drags the entry out of the panel.
///
/// Separate tap, long press and drag gestures would leave SwiftUI to pick between them, and
/// `onDrag` cannot carry what Chromium apps need (see `RowDragController`). A single drag
/// gesture that starts on mouse down sees the whole press and decides for itself. Buttons
/// inside the row keep working, since a child's gesture wins over one attached here.
struct RowPressModifier: ViewModifier {
    let onClick: () -> Void
    let onHold: () -> Void
    /// Called with the mouse event that crossed the drag distance. Returns whether a drag began.
    let onDrag: (NSEvent) -> Bool

    @State private var tracker = PressTracker()

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    tracker.changed(start: value.startLocation, translation: value.translation,
                                    onHold: onHold, onDrag: onDrag)
                }
                .onEnded { _ in
                    tracker.ended(onClick: onClick)
                }
        )
    }
}

extension View {
    func rowPress(onClick: @escaping () -> Void,
                  onHold: @escaping () -> Void,
                  onDrag: @escaping (NSEvent) -> Bool) -> some View {
        modifier(RowPressModifier(onClick: onClick, onHold: onHold, onDrag: onDrag))
    }
}

/// The state of one press. A class, so the hold timer can look at it when it fires.
final class PressTracker {
    enum Phase { case idle, pressing, held, dragging, ignored }

    /// How long the pointer has to rest for a press to open the preview.
    static let holdDuration: TimeInterval = 0.4
    /// How far the pointer may wander before a press becomes a drag.
    static let dragDistance: CGFloat = 4

    private(set) var phase: Phase = .idle
    private var start: CGPoint = .zero
    private var holdTimer: DispatchWorkItem?

    func changed(start location: CGPoint, translation: CGSize,
                 onHold: @escaping () -> Void, onDrag: (NSEvent) -> Bool) {
        // A drag session takes the mouse up away from SwiftUI, so a press that turned into a
        // drag is never told it ended. Each mouse down starts over instead of trusting that.
        let isMouseDown = NSApp.currentEvent?.type == .leftMouseDown
        if isMouseDown || phase == .idle || location != start {
            begin(at: location, onHold: onHold)
        }
        guard phase == .pressing,
              hypot(translation.width, translation.height) > Self.dragDistance else { return }
        cancelHold()
        phase = .dragging
        if let event = Self.dragEvent() { _ = onDrag(event) }
    }

    func ended(onClick: () -> Void) {
        cancelHold()
        let wasPlainPress = phase == .pressing
        phase = .idle
        if wasPlainPress { onClick() }
    }

    private func begin(at location: CGPoint, onHold: @escaping () -> Void) {
        cancelHold()
        start = location
        // Control-click is the context menu, not a click on the row.
        if NSEvent.modifierFlags.contains(.control) {
            phase = .ignored
            return
        }
        phase = .pressing
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .pressing else { return }
            self.phase = .held
            onHold()
        }
        holdTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDuration, execute: timer)
    }

    private func cancelHold() {
        holdTimer?.cancel()
        holdTimer = nil
    }

    /// The mouse event a drag starts from. AppKit wants the event being handled, which is
    /// the current one; should SwiftUI ever call back outside it, an equivalent event is
    /// made at the pointer so the drag still starts in the right window and place.
    private static func dragEvent() -> NSEvent? {
        if let event = NSApp.currentEvent, event.window != nil,
           event.type == .leftMouseDragged || event.type == .leftMouseDown {
            return event
        }
        guard let window = NSApp.keyWindow else { return nil }
        return NSEvent.mouseEvent(with: .leftMouseDragged,
                                  location: window.mouseLocationOutsideOfEventStream,
                                  modifierFlags: [],
                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber,
                                  context: nil,
                                  eventNumber: 0,
                                  clickCount: 1,
                                  pressure: 1)
    }
}
