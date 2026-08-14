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
    case .verticalBar:     return .playheadPlace
    }
}

extension NSCursor {
    /// The "place the transport position" pointer (m25-o) — the app's ONE custom
    /// cursor image, and the reason it is drawn rather than borrowed is that AppKit
    /// has no honest stock candidate. `iBeam` is the closest SHAPE and is
    /// specifically wrong: docs/DESIGN-LANGUAGE.md reserves it (*"Text-editable
    /// fields stay the system I-beam — never override it"*), so spending it here
    /// would teach the pointer to lie about text. `crosshair` is the place/paint
    /// family but is not vertical, and the user asked for *"some vertical sign"*.
    /// `resizeLeftRight` — what the scrub strip uses — reads as "widen this", which
    /// is the one thing this gesture cannot do.
    ///
    /// A `static let` so the `NSImage` is rasterised ONCE for the process. This is
    /// resolved on the hover path and, via the flags monitor, on every ⌘ press, so
    /// building an image per resolution would be the house per-frame-allocation
    /// smell on a path the user drives continuously.
    /// `@MainActor` because `NSCursor` is not `Sendable` and this is a stored
    /// global — Swift 6 strict concurrency rejects it otherwise. Every caller is
    /// already main-actor (`nsCursor(for:)` is, and cursors are AppKit UI state),
    /// so the isolation costs nothing and documents the truth.
    @MainActor
    static let playheadPlace: NSCursor = {
        let size: CGFloat = 24
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let path = NSBezierPath()
        // ⭐ **A CAP OVER A HAIRLINE — THE APP'S OWN PLAYHEAD HANDLE IN
        // MINIATURE, not an invented glyph.** `PianoRollScrubRuler.handleWidth`
        // is 9 and the handle it sizes is a plain rectangular cap sitting on the
        // transport line, so the cap here is 9 wide over a 2.5 pt bar. The
        // pointer is therefore a picture of the thing it is about to place, which
        // is the strongest cue available at 24 pt.
        //
        // ⚠️ **ONE CLOSED SILHOUETTE, NOT A TRIANGLE PLUS A RECT.** Two subpaths
        // get stroked along their SHARED interior edges too, which draws black
        // lines down the middle of the glyph; MEASURED — the first two renders of
        // this cursor read as a funnel with a seam, not as a playhead. Tracing the
        // outline once is what makes the stroke an outline.
        //
        // Drawn in the image's default bottom-left origin space, so "the cap is at
        // the top" is y near `size`.
        path.move(to: NSPoint(x: 7.5, y: size - 1))
        path.line(to: NSPoint(x: 16.5, y: size - 1))
        path.line(to: NSPoint(x: 16.5, y: size - 4.5))
        path.line(to: NSPoint(x: 13.25, y: size - 4.5))
        path.line(to: NSPoint(x: 13.25, y: 2))
        path.line(to: NSPoint(x: 10.75, y: 2))
        path.line(to: NSPoint(x: 10.75, y: size - 4.5))
        path.line(to: NSPoint(x: 7.5, y: size - 4.5))
        path.close()
        // Outline first, fill second: the black stroke lays ~0.5 pt outside the
        // shape, which is what keeps a white cursor legible if it ever crosses a
        // light surface. Without it the bar vanishes against pale content — the
        // classic custom-cursor bug. Verified against BOTH grounds.
        NSColor.black.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 1
        path.stroke()
        NSColor.white.setFill()
        path.fill()
        image.unlockFocus()
        // ⚠️ THE HOT SPOT IS THE BAR'S OWN x, NOT THE IMAGE CENTRE BY COINCIDENCE.
        // The bar spans x 11…13, so its centre is 12 — and on a SNAPPING surface a
        // hot spot even a couple of points off makes the cursor point at one grid
        // line while the click lands on another, which is precisely the confusion
        // the affordance exists to remove.
        return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
    }()
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
    ///
    /// `refresh` is an OPT-IN re-resolution token (m25-o): the overlay below is
    /// driven by an `NSTrackingArea`, so it re-resolves on pointer MOVEMENT and
    /// nothing else. A surface whose affordance depends on something other than
    /// position — the roll's grid, where holding ⌘ changes what a click does with
    /// the mouse perfectly still — bumps this value and the overlay re-asks at the
    /// pointer's current location.
    ///
    /// ⚠️ **OPT-IN, WITH A PLAIN `Int` DEFAULT, FOR TWO SEPARATE REASONS.**
    /// Behaviourally: re-applying on every body evaluation would let two
    /// OVERLAPPING tracking areas (an arrange clip block inside its lane) both
    /// claim the pointer and fight over the cursor, where today only the one
    /// receiving `mouseMoved` sets it — so every surface that does not pass a token
    /// keeps byte-identical behaviour. Mechanically: an `AnyHashable` token would
    /// box on every body eval, and these views re-evaluate on the transport tick,
    /// which is the allocation this codebase's drawing rule forbids.
    func hoverCursor(resolve: @escaping (CGPoint) -> CursorKind?,
                     refresh: Int = 0) -> some View {
        overlay(CursorTrackingOverlay(resolve: resolve, refresh: refresh)
            .allowsHitTesting(false))
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
    var refresh: Int = 0

    func makeNSView(context: Context) -> CursorTrackingNSView {
        let view = CursorTrackingNSView()
        view.resolve = resolve
        // Seeded, not left at 0, so mounting never counts as a token change and
        // fires a spurious re-resolve before the pointer has been anywhere.
        view.refreshToken = refresh
        return view
    }

    func updateNSView(_ view: CursorTrackingNSView, context: Context) {
        // The closure captures fresh view state each body eval; just re-store it.
        //
        // ⚠️ STORED BEFORE THE TOKEN COMPARISON, NOT AFTER. `reapplyAtPointer`
        // calls `resolve`, so re-applying first would answer with the PREVIOUS
        // body's closure — the affordance would lag exactly one modifier press,
        // which is the failure that looks like "it works, just late" and gets
        // debugged as a timing problem.
        view.resolve = resolve
        if view.refreshToken != refresh {
            view.refreshToken = refresh
            view.reapplyAtPointer()
        }
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
    /// Last `refresh` token seen from SwiftUI (m25-o) — a change means "re-ask,
    /// the answer may have changed without the pointer moving".
    var refreshToken = 0
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
        apply(at: convert(event.locationInWindow, from: nil))
    }

    private func apply(at local: NSPoint) {
        guard let resolve else { return }
        if let kind = resolve(local) {
            nsCursor(for: kind).set()
            showingCustom = true
        } else {
            resetIfShowingCustom()
        }
    }

    /// Re-resolve at wherever the pointer is RIGHT NOW, with no mouse event to
    /// carry the location (m25-o — a modifier changed and the affordance with it).
    ///
    /// ⚠️ **THE POINTER IS READ LIVE, NOT REMEMBERED.** A cached "last local
    /// point" goes stale in the exact situation this exists for: the content can
    /// scroll under a motionless pointer, so the remembered point would name a
    /// beat the pointer is no longer over — and this surface's whole promise is
    /// that the cursor and the click agree. `mouseLocationOutsideOfEventStream` is
    /// the current truth.
    ///
    /// Guarded three ways so a background window, a pointer that has left this
    /// view, or a view not yet in a window can never have a cursor forced on it.
    func reapplyAtPointer() {
        guard let window, window.isKeyWindow else { return }
        let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(local) else { resetIfShowingCustom(); return }
        apply(at: local)
    }

    /// Reset to the arrow only if we were the one showing a custom cursor.
    func resetIfShowingCustom() {
        guard showingCustom else { return }
        NSCursor.arrow.set()
        showingCustom = false
    }
}
