import CoreGraphics
import Testing
@testable import DAWAppKit

/// Headless coverage for the pointer-affordance model (beta item m10-c;
/// docs/DESIGN-LANGUAGE.md "Pointer affordances"). The DAWApp side owns only a
/// thin `CursorKind → NSCursor` switch and the NSTrackingArea overlay (both
/// un-testable in this headless target — see the report note); everything a test
/// CAN pin lives here: the per-surface catalog is exhaustive, the family
/// conventions hold, the clip/note zone mappings mirror the geometry classifiers,
/// and the edge-zone constants the resolvers depend on stay sane.
@MainActor
@Suite("CursorModel — pointer affordances (m10-c)")
struct CursorModelTests {

    // MARK: - CursorKind

    @Test("every CursorKind round-trips through its raw value")
    func kindRawValueRoundTrips() {
        for kind in CursorKind.allCases {
            #expect(CursorKind(rawValue: kind.rawValue) == kind)
        }
        // The vocabulary the app actually needs (guards a silent shrink).
        #expect(Set(CursorKind.allCases) == [
            .resizeLeftRight, .resizeUpDown, .grab, .grabbing, .crosshair,
        ])
    }

    // MARK: - Catalog completeness

    @Test("every affordance resolves a rest and a drag cursor")
    func everyAffordanceResolves() {
        // Exhaustive `switch`es make this total, but assert it explicitly so a new
        // case that forgets a branch fails loudly rather than trapping.
        for role in CursorAffordance.allCases {
            _ = role.restCursor
            _ = role.dragCursor
        }
        // 12 → 13 in m17-c: the arrange playhead grab strip joined the movable
        // bodies (drag scrub-seeks the transport).
        #expect(CursorAffordance.allCases.count == 13)
    }

    @Test("value adjusters keep their resize cursor for the whole drag")
    func valueAdjustersDoNotGrab() {
        // A fader/knob never turns into a hand — it stays a resize the whole drag.
        for role in [CursorAffordance.verticalFader, .knob, .velocityStem, .clipGain] {
            #expect(role.restCursor == .resizeUpDown)
            #expect(role.dragCursor == .resizeUpDown)
        }
        #expect(CursorAffordance.horizontalFader.restCursor == .resizeLeftRight)
        #expect(CursorAffordance.horizontalFader.dragCursor == .resizeLeftRight)
    }

    @Test("trim edges and fade grips are horizontal resizes, rest == drag")
    func edgesAreHorizontalResizes() {
        for role in [CursorAffordance.trimEdge, .fadeGrip] {
            #expect(role.restCursor == .resizeLeftRight)
            #expect(role.dragCursor == .resizeLeftRight)
        }
    }

    @Test("movable bodies open the hand at rest and close it while dragging")
    func bodiesGrabThenGrabbing() {
        for role in [CursorAffordance.clipBody, .noteBody, .automationPoint, .playhead] {
            #expect(role.restCursor == .grab)
            #expect(role.dragCursor == .grabbing)
        }
    }

    @Test("place / paint surfaces use the crosshair")
    func paintSurfacesAreCrosshair() {
        for role in [CursorAffordance.automationField, .takeLanePaint] {
            #expect(role.restCursor == .crosshair)
        }
    }

    // MARK: - Zone mappings (mirror the geometry classifiers)

    @Test("clip zones map: edges/fades resize, body grabs then grabbing")
    func clipZoneMapping() {
        #expect(CursorAffordance.forClipZone(.trimStart) == .resizeLeftRight)
        #expect(CursorAffordance.forClipZone(.trimEnd) == .resizeLeftRight)
        #expect(CursorAffordance.forClipZone(.fadeInHandle) == .resizeLeftRight)
        #expect(CursorAffordance.forClipZone(.fadeOutHandle) == .resizeLeftRight)
        #expect(CursorAffordance.forClipZone(.body) == .grab)
        // The body closes the hand mid-drag; an edge stays a resize.
        #expect(CursorAffordance.forClipZone(.body, dragging: true) == .grabbing)
        #expect(CursorAffordance.forClipZone(.trimEnd, dragging: true) == .resizeLeftRight)
    }

    @Test("every ClipZone resolves (exhaustive, no crash)")
    func clipZoneExhaustive() {
        let zones: [ClipZone] = [.fadeInHandle, .fadeOutHandle, .trimStart, .trimEnd, .body]
        for zone in zones {
            _ = CursorAffordance.forClipZone(zone)
            _ = CursorAffordance.forClipZone(zone, dragging: true)
        }
    }

    @Test("note zones map: resize handle resizes, body grabs then grabbing")
    func noteZoneMapping() {
        #expect(CursorAffordance.forNoteZone(.resizeHandle) == .resizeLeftRight)
        #expect(CursorAffordance.forNoteZone(.body) == .grab)
        #expect(CursorAffordance.forNoteZone(.body, dragging: true) == .grabbing)
        #expect(CursorAffordance.forNoteZone(.resizeHandle, dragging: true) == .resizeLeftRight)
    }

    // MARK: - Edge-zone constants the resolvers depend on

    /// The cursor resolvers reuse the SAME hit geometry the gestures do, so a
    /// zeroed edge strip would silently kill both the interaction AND its cursor
    /// cue. Pin the constants sane (positive, and not so wide they swallow the
    /// body).
    @Test("clip edge / fade hit zones are positive and reasonable")
    func clipEdgeConstantsSane() {
        let g = ClipEditGeometry()
        #expect(g.edgeHitWidth > 0 && g.edgeHitWidth <= 20)
        #expect(g.fadeHandleHitRadius > 0 && g.fadeHandleHitRadius <= 20)
        #expect(g.fadeHandleZoneHeight > 0 && g.fadeHandleZoneHeight <= g.laneHeight)
    }

    @Test("note resize handle width is positive and reasonable")
    func noteResizeConstantSane() {
        #expect(PianoRollModel.resizeHandleWidth > 0 && PianoRollModel.resizeHandleWidth <= 20)
    }

    @Test("automation breakpoint hit radius is positive and reasonable")
    func automationHitRadiusSane() {
        let g = AutomationGeometry(range: 0...2)
        #expect(g.hitRadius > 0 && g.hitRadius <= 20)
    }
}
