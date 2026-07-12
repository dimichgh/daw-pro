import CoreGraphics
import Foundation

/// The pointer shapes DAW Pro shows on hover to advertise a drag/resize
/// affordance so controllability is discoverable (beta item m10-c;
/// docs/DESIGN-LANGUAGE.md "Pointer affordances"). Pure + `Sendable` so the
/// per-surface decision logic is headless-testable; the DAWApp side maps each
/// case to an `NSCursor` in ONE thin switch (the `PanelDensity` precedent: pure
/// model here, AppKit glue in DAWApp).
///
/// The raw value is a stable string so a test can name a case without importing
/// AppKit.
public enum CursorKind: String, CaseIterable, Sendable, Equatable {
    /// Horizontal resize/trim — a clip trim edge, a note's right-edge resize
    /// handle, a clip fade grip, a horizontal value fader. macOS `resizeLeftRight`.
    case resizeLeftRight
    /// Vertical value adjust — a long-throw fader, a rotary knob, a velocity
    /// stem, the clip-gain chip. macOS `resizeUpDown`.
    case resizeUpDown
    /// A movable body AT REST — an arrange clip, a piano-roll note, an automation
    /// breakpoint. macOS open hand.
    case grab
    /// A movable body WHILE it is being dragged. macOS closed hand — held for the
    /// WHOLE drag even if the pointer leaves the body, so it is driven by the
    /// gesture (onChanged/onEnded), never by hover.
    case grabbing
    /// A precise place/paint surface — click empty automation space to add a
    /// breakpoint, drag a take lane to paint a comp range. macOS crosshair.
    case crosshair
}

/// The interactive surface families in the app, each mapped to the pointer it
/// advertises at rest (hover) and — for movable bodies — while dragging. ONE
/// tested source of truth so every view resolves the same cursor for the same
/// role, and a new control picks its family instead of hand-coding a cursor
/// (docs/DESIGN-LANGUAGE.md "Pointer affordances"). The convention families:
///
/// - **Value adjusters** keep their resize cursor for the whole drag (a fader
///   never "grabs").
/// - **Resize / trim edges** likewise keep `resizeLeftRight`.
/// - **Movable bodies** open the hand at rest and CLOSE it while dragging.
/// - **Place / paint** surfaces use the crosshair (authoring content by
///   position, distinct from picking up an existing object).
public enum CursorAffordance: String, CaseIterable, Sendable {
    // Value adjusters (vertical throw).
    case verticalFader     // master + channel long-throw fader
    case knob              // pan / rotary — vertical drag
    case velocityStem      // piano-roll velocity lane stem
    case clipGain          // arrange clip gain dB chip
    // Value adjuster (horizontal throw).
    case horizontalFader   // send mini-fader
    // Resize / trim edges.
    case trimEdge          // clip trim edge, note right-edge resize handle
    case fadeGrip          // clip fade corner grip
    // Movable bodies.
    case clipBody          // arrange clip block
    case noteBody          // piano-roll note
    case automationPoint   // automation breakpoint
    // Place / paint.
    case automationField   // empty automation lane (click adds a point)
    case takeLanePaint     // take lane comp paint / select

    /// Pointer shown while merely hovering the surface.
    public var restCursor: CursorKind {
        switch self {
        case .verticalFader, .knob, .velocityStem, .clipGain:
            return .resizeUpDown
        case .horizontalFader, .trimEdge, .fadeGrip:
            return .resizeLeftRight
        case .clipBody, .noteBody, .automationPoint:
            return .grab
        case .automationField, .takeLanePaint:
            return .crosshair
        }
    }

    /// Pointer shown while the surface is being actively dragged. Movable bodies
    /// close the hand (`grab` → `grabbing`); every other family keeps its rest
    /// cursor for the whole drag (a resize stays a resize, a fader stays a fader).
    public var dragCursor: CursorKind {
        switch self {
        case .clipBody, .noteBody, .automationPoint:
            return .grabbing
        default:
            return restCursor
        }
    }
}

extension CursorAffordance {
    /// Cursor an arrange clip zone advertises (the `ClipBlock` resolver mirrors
    /// `ClipEditGeometry.classifyZone`). Trim edges and fade grips resize
    /// horizontally; the body is a movable grab that closes the hand on drag.
    public static func forClipZone(_ zone: ClipZone, dragging: Bool = false) -> CursorKind {
        switch zone {
        case .trimStart, .trimEnd:
            return dragging ? CursorAffordance.trimEdge.dragCursor : CursorAffordance.trimEdge.restCursor
        case .fadeInHandle, .fadeOutHandle:
            return dragging ? CursorAffordance.fadeGrip.dragCursor : CursorAffordance.fadeGrip.restCursor
        case .body:
            return dragging ? CursorAffordance.clipBody.dragCursor : CursorAffordance.clipBody.restCursor
        }
    }

    /// Cursor a piano-roll note zone advertises (mirrors `PianoRollModel.hitTest`).
    /// The right-edge resize handle resizes horizontally; the body is a movable
    /// grab that closes the hand on drag.
    public static func forNoteZone(_ zone: NoteZone, dragging: Bool = false) -> CursorKind {
        switch zone {
        case .resizeHandle:
            return dragging ? CursorAffordance.trimEdge.dragCursor : CursorAffordance.trimEdge.restCursor
        case .body:
            return dragging ? CursorAffordance.noteBody.dragCursor : CursorAffordance.noteBody.restCursor
        }
    }

    /// Cursor an arrange loop-ruler zone advertises (beta m10-g; mirrors
    /// `LoopRulerGeometry.classify`). The region's edges resize horizontally; its
    /// body is a movable grab that closes the hand on drag; the empty ruler is a
    /// horizontal position surface (drag to sketch a loop, or click to seek), so it
    /// reads as `resizeLeftRight` — the piano-roll scrub-strip family (a horizontal
    /// position drag), rest == drag.
    public static func forLoopZone(_ zone: LoopRulerZone, dragging: Bool = false) -> CursorKind {
        switch zone {
        case .edgeStart, .edgeEnd:
            return dragging ? CursorAffordance.trimEdge.dragCursor : CursorAffordance.trimEdge.restCursor
        case .body:
            return dragging ? CursorAffordance.clipBody.dragCursor : CursorAffordance.clipBody.restCursor
        case .empty:
            return .resizeLeftRight
        }
    }
}
