import AppKit
import SwiftUI
import DAWAppKit

// Pointer affordances (beta item m10-c; docs/DESIGN-LANGUAGE.md "Pointer
// affordances"): make every drag/resize surface advertise its controllability by
// changing the mouse cursor on hover. The pure model (`CursorKind` +
// `CursorAffordance` catalog + the clip/note zone mappings) lives in DAWAppKit so
// it is headless-testable; this file is the thin AppKit glue — one `NSCursor`
// switch plus a robust NSTrackingArea overlay — the `PanelDensity` precedent.

/// The ONE place AppKit's cursor vocabulary meets the headless `CursorKind`.
@MainActor
func nsCursor(for kind: CursorKind) -> NSCursor {
    switch kind {
    case .resizeLeftRight: return .resizeLeftRight
    case .resizeUpDown:    return .resizeUpDown
    case .grab:            return .openHand
    case .grabbing:        return .closedHand
    case .crosshair:       return .crosshair
    }
}

// MARK: - Drag cursor (gesture-driven)

/// Forces a cursor for the DURATION of a SwiftUI drag, so `grabbing` (closed
/// hand) — or a held resize cursor — persists even when the pointer leaves the
/// source bounds. Driven by the gesture's `onChanged` / `onEnded` (never by
/// hover): during a drag the hover overlay below is dormant (the mouse is captured
/// by the SwiftUI content), so re-`set()`ing per tick is both safe and cheap
/// (`NSCursor`s are cached statics — no per-tick allocation).
@MainActor
enum DragCursor {
    /// Call on each `onChanged` tick with the drag's kind.
    static func set(_ kind: CursorKind) { nsCursor(for: kind).set() }
    /// Call on `onEnded` (and on `onDisappear` if a drag may still be live). Drops
    /// to the arrow so a cancelled/ended drag never STICKS a hand/resize; the next
    /// hover immediately re-resolves the correct rest cursor.
    static func clear() { NSCursor.arrow.set() }
}

// MARK: - Hover cursor overlay

extension View {
    /// Show `kind` while the pointer hovers this view (a uniform surface — a
    /// fader, a knob, a take lane). The overlay is transparent and never steals
    /// clicks or SwiftUI hover, so it COEXISTS with the Explain hover machinery
    /// and the view's own gestures.
    func hoverCursor(_ kind: CursorKind) -> some View {
        overlay(CursorTrackingOverlay(resolve: { _ in kind }).allowsHitTesting(false))
    }

    /// Resolve the cursor per LOCAL point (a position-dependent surface — the clip
    /// block's trim edges vs. body, the piano-roll grid's notes vs. empty space,
    /// the automation lane's breakpoints vs. empty). The closure receives a
    /// top-left-origin point in this view's coordinate space; return `nil` for
    /// "no special cursor here" (falls back to the arrow).
    func hoverCursor(resolve: @escaping (CGPoint) -> CursorKind?) -> some View {
        overlay(CursorTrackingOverlay(resolve: resolve).allowsHitTesting(false))
    }
}

/// A transparent AppKit overlay that reads the pointer via an `NSTrackingArea`
/// and sets the cursor for the hovered point. Chosen over SwiftUI's binary
/// `.onHover` because the affordance is POSITION-dependent (a clip's edge vs. its
/// body) and because AppKit's tracking-area lifecycle avoids the classic
/// stuck-cursor bugs: the view is `hitTest`-transparent (clicks/gestures pass
/// through untouched) and restores the arrow on exit / teardown so a cursor never
/// sticks when the hovered view disappears or a sheet opens mid-hover.
private struct CursorTrackingOverlay: NSViewRepresentable {
    var resolve: (CGPoint) -> CursorKind?

    func makeNSView(context: Context) -> CursorTrackingNSView {
        let view = CursorTrackingNSView()
        view.resolve = resolve
        return view
    }

    func updateNSView(_ view: CursorTrackingNSView, context: Context) {
        // The closure captures fresh view state each body eval; just re-store it.
        view.resolve = resolve
    }

    static func dismantleNSView(_ view: CursorTrackingNSView, coordinator: ()) {
        // The overlay is going away (view disappeared, panel/sheet swapped): drop
        // any custom cursor so it can't outlive the surface it described.
        view.resetIfShowingCustom()
    }
}

/// The tracking NSView. Flipped so its coordinate system is top-left, matching the
/// SwiftUI local points the resolvers classify against.
final class CursorTrackingNSView: NSView {
    var resolve: ((CGPoint) -> CursorKind?)?
    /// Whether WE last set a non-arrow cursor — so exit/teardown only resets when
    /// we were responsible (never stomps another view's cursor).
    private var showingCustom = false

    override var isFlipped: Bool { true }

    /// Click/gesture pass-through: the overlay is cursor-only, so it must never
    /// intercept the mouse — hit-testing finds the interactive SwiftUI view below.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            // `.cursorUpdate` handles entry; `.mouseMoved` drives the
            // position-dependent update within the area; enter/exit resets on the
            // boundary. `.inVisibleRect` keeps the area glued to the live bounds.
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
                      .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { apply(event) }
    override func mouseMoved(with event: NSEvent) { apply(event) }
    override func cursorUpdate(with event: NSEvent) { apply(event) }
    override func mouseExited(with event: NSEvent) { resetIfShowingCustom() }

    private func apply(_ event: NSEvent) {
        guard let resolve else { return }
        let local = convert(event.locationInWindow, from: nil)
        if let kind = resolve(local) {
            nsCursor(for: kind).set()
            showingCustom = true
        } else {
            resetIfShowingCustom()
        }
    }

    /// Reset to the arrow only if we were the one showing a custom cursor.
    func resetIfShowingCustom() {
        guard showingCustom else { return }
        NSCursor.arrow.set()
        showingCustom = false
    }
}
