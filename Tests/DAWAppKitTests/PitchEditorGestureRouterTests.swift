import CoreGraphics
import Foundation
import Testing
@testable import DAWAppKit

/// m23-ap interaction batch I0 — `PitchEditorGestureRouter` and
/// `PitchEditorPressTracker`: what a press on the pitch editor's surface IS,
/// decided ONCE, and what its release does (design
/// `2026-09-24-pitch-editor-interaction-batch.md` §3 item 5; the vibrato
/// design's §4.2 named the router first).
///
/// ⭐ **THE EXPECTED VALUES ARE LITERALS, NOT A SECOND COPY OF THE RULE.** A
/// truth table that recomputes its answers with the same `switch` it is testing
/// agrees with any mutation of that switch. Every row below spells its answer.
///
/// ⚠️ NOT `@MainActor`: the router is a pure function and the tracker a pure
/// value; an isolated suite would spend one of the review-cadence slots
/// `MainActorOccupancySiteTests` bounds.
@Suite("PitchEditorGestureRouter — a press is decided once, and its release follows from it (m23-ap I0)")
struct PitchEditorGestureRouterTests {

    private static let noteA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private static let noteB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    /// Every chord the router is handed (`ArrangeClickModifiers` carries ⇧ and ⌘
    /// only — ⌥ is read per tick, never at press).
    private static let chords: [(name: String, value: ArrangeClickModifiers)] = [
        ("plain", .none), ("⇧", .shift), ("⌘", .command), ("⇧⌘", [.shift, .command]),
    ]

    // MARK: - route: the full truth table, tool × chord × hit

    /// The six (tool, hit) answers, each spelled out. Iterated under all four
    /// chords below: 24 rows.
    private static let routeRows: [(tool: PitchEditorTool, hit: PitchEditorPressHit,
                                    expected: PitchEditorPressKind)] = [
        (.pointer, .note(noteA), .noteDrag(noteA)),
        (.pointer, .empty, .band),
        (.pointer, .inert, .none),
        (.scissors, .note(noteA), .cut),
        (.scissors, .empty, .cut),
        (.scissors, .inert, .none),
    ]

    @Test("⭐ the full truth table: 2 tools × 4 chords × 3 hits, every row a literal")
    func fullTruthTable() {
        var rows = 0
        for chord in Self.chords {
            for row in Self.routeRows {
                let kind = PitchEditorGestureRouter.route(tool: row.tool, modifiersAtPress: chord.value,
                                                          hit: row.hit)
                #expect(kind == row.expected, "\(row.tool) + \(chord.name) on \(row.hit)")
                rows += 1
            }
        }
        #expect(rows == 24)
    }

    /// The table above cannot tell "the chord is ignored" from "every chord
    /// happens to agree". This leg states it: no kind depends on the press-time
    /// chord YET — the kinds that will (C5b-4's ⌘-brush, C2-5's ⌘-edge) are
    /// designed and not built, and adding one must be a deliberate row change.
    @Test("no kind depends on the press chord yet — the designed ⌘ kinds are not built")
    func chordIsInertToday() {
        for row in Self.routeRows {
            let plain = PitchEditorGestureRouter.route(tool: row.tool, modifiersAtPress: .none, hit: row.hit)
            for chord in Self.chords {
                #expect(PitchEditorGestureRouter.route(tool: row.tool, modifiersAtPress: chord.value,
                                                       hit: row.hit) == plain,
                        "\(row.tool) + \(chord.name) on \(row.hit)")
            }
        }
    }

    @Test("the pressed note rides on the kind; its echo tags are stable")
    func kindPayloadAndKeys() {
        #expect(PitchEditorPressKind.noteDrag(Self.noteB).noteID == Self.noteB)
        #expect(PitchEditorPressKind.band.noteID == nil)
        #expect(PitchEditorPressKind.cut.noteID == nil)
        #expect(PitchEditorPressKind.none.noteID == nil)
        #expect([PitchEditorPressKind.noteDrag(Self.noteA), .band, .cut, .none].map(\.key)
                == ["noteDrag", "band", "cut", "none"])
        #expect([PitchEditorReleaseAction.endNoteDrag(Self.noteA), .endBand, .cut(at: .zero),
                 .click(.deselect), .nothing].map(\.key)
                == ["endNoteDrag", "endBand", "cut", "click", "nothing"])
    }

    // MARK: - release: kind × travelled × chord-at-release

    @Test("⭐ release truth table: a no-travel press is the house CLICK, read with the chord AT RELEASE")
    func releaseTruthTable() {
        let origin = CGPoint(x: 40, y: 12)
        let a = Self.noteA
        // (kind, travelled, chord, expected) — every answer spelled.
        let rows: [(PitchEditorPressKind, Bool, ArrangeClickModifiers, PitchEditorReleaseAction)] = [
            (.noteDrag(a), true, .none, .endNoteDrag(a)),
            (.noteDrag(a), true, .shift, .endNoteDrag(a)),
            (.noteDrag(a), true, .command, .endNoteDrag(a)),
            (.noteDrag(a), true, [.shift, .command], .endNoteDrag(a)),
            (.noteDrag(a), false, .none, .click(.selectOnly(a))),
            (.noteDrag(a), false, .shift, .click(.toggle(a))),
            (.noteDrag(a), false, .command, .click(.toggle(a))),
            (.noteDrag(a), false, [.shift, .command], .click(.toggle(a))),
            (.band, true, .none, .endBand),
            (.band, true, .command, .endBand),
            (.band, false, .none, .click(.deselect)),
            (.band, false, .shift, .click(.doNothing)),
            (.band, false, .command, .click(.positionPlayhead)),
            (.band, false, [.shift, .command], .click(.positionPlayhead)),
            // The knife is a click by definition: it lands at the PRESS point,
            // travelled or not, whatever the chord.
            (.cut, false, .none, .cut(at: origin)),
            (.cut, true, .none, .cut(at: origin)),
            (.cut, false, .command, .cut(at: origin)),
            (.cut, true, [.shift, .command], .cut(at: origin)),
            (.none, false, .none, .nothing),
            (.none, true, .none, .nothing),
            (.none, false, .command, .nothing),
        ]
        for (kind, travelled, chord, expected) in rows {
            let action = PitchEditorGestureRouter.release(kind: kind, travelled: travelled, origin: origin,
                                                          modifiersAtRelease: chord)
            #expect(action == expected, "\(kind) travelled=\(travelled) chord=\(chord.rawValue)")
        }
    }

    // MARK: - The slop

    @Test("the slop is the roll's band threshold, RADIAL, and inclusive at exactly 4 pt")
    func slopBoundary() {
        let o = CGPoint(x: 100, y: 100)
        #expect(PitchEditorGestureRouter.slop == PianoRollMarquee.dragSlop)
        #expect(PitchEditorGestureRouter.slop == 4)
        #expect(!PitchEditorGestureRouter.hasTravelled(from: o, to: CGPoint(x: 103.99, y: 100)))
        #expect(PitchEditorGestureRouter.hasTravelled(from: o, to: CGPoint(x: 104, y: 100)))
        #expect(PitchEditorGestureRouter.hasTravelled(from: o, to: CGPoint(x: 100, y: 96)))
        // Radial, not per-axis: 2.8 on each axis is 3.96 pt; 3 on each is 4.24.
        #expect(!PitchEditorGestureRouter.hasTravelled(from: o, to: CGPoint(x: 102.8, y: 102.8)))
        #expect(PitchEditorGestureRouter.hasTravelled(from: o, to: CGPoint(x: 103, y: 103)))
    }

    // MARK: - The tracker: decided ONCE

    /// ⛔⛔ **THE PROPERTY THE WHOLE ROUTER EXISTS FOR.** Mid-gesture the tool
    /// switches, and what is under the press point changes (a zoom, a table
    /// read-back): the press must stay what its first tick decided, and the hit
    /// must not even be ASKED again.
    @Test("⛔ decided ONCE: a tool switch or a changed hit mid-gesture never re-routes the press")
    func decidedOnce() {
        var tracker = PitchEditorPressTracker()
        let start = CGPoint(x: 50, y: 20)
        var hitCalls = 0
        var underPress = PitchEditorPressHit.note(Self.noteA)
        let hit: (CGPoint) -> PitchEditorPressHit = { _ in hitCalls += 1; return underPress }

        let first = tracker.tick(start: start, location: start, tool: .pointer, modifiers: .none, hit: hit)
        #expect(first.isFirst)
        #expect(first.kind == .noteDrag(Self.noteA))
        #expect(hitCalls == 1)

        // The world changes under the press: the Split tool is engaged, the note
        // is gone, the chord is different.
        underPress = .empty
        let path = [CGPoint(x: 51, y: 21), CGPoint(x: 60, y: 40), CGPoint(x: 30, y: 90)]
        for (n, location) in path.enumerated() {
            let tick = tracker.tick(start: start, location: location, tool: .scissors,
                                    modifiers: .command, hit: hit)
            #expect(!tick.isFirst, "tick \(n + 2)")
            #expect(tick.kind == .noteDrag(Self.noteA), "tick \(n + 2) re-routed to \(tick.kind)")
        }
        #expect(hitCalls == 1, "the hit was re-evaluated mid-gesture (\(hitCalls) calls)")
        #expect(tracker.current?.kind == .noteDrag(Self.noteA))
        #expect(tracker.current?.modifiersAtPress == ArrangeClickModifiers.none)
        // …and the release is the drag's, not the knife's now engaged.
        #expect(tracker.release(start: start, at: CGPoint(x: 30, y: 90), modifiers: .none)
                == .endNoteDrag(Self.noteA))
        #expect(tracker.current == nil)
    }

    @Test("promotion happens once, on the tick that crosses the slop, and then LATCHES")
    func promotionLatches() {
        var tracker = PitchEditorPressTracker()
        let start = CGPoint(x: 10, y: 10)
        let hit: (CGPoint) -> PitchEditorPressHit = { _ in .note(Self.noteA) }
        let steps: [(CGPoint, didPromote: Bool, isPromoted: Bool)] = [
            (CGPoint(x: 10, y: 10), false, false),     // the press
            (CGPoint(x: 12, y: 11), false, false),     // 2.2 pt — inside
            (CGPoint(x: 10, y: 15), true, true),       // 5 pt — crosses
            (CGPoint(x: 10, y: 30), false, true),      // further: no second crossing
            (CGPoint(x: 10, y: 10), false, true),      // back home: still a drag
        ]
        for (n, step) in steps.enumerated() {
            let tick = tracker.tick(start: start, location: step.0, tool: .pointer, modifiers: .none, hit: hit)
            #expect(tick.isFirst == (n == 0), "tick \(n)")
            #expect(tick.didPromote == step.didPromote, "tick \(n) didPromote")
            #expect(tick.isPromoted == step.isPromoted, "tick \(n) isPromoted")
        }
        // Released back at the press point, the drag that went out is still a
        // drag — not a click that would select-and-snap.
        #expect(tracker.release(start: start, at: start, modifiers: .none) == .endNoteDrag(Self.noteA))
    }

    @Test("a first tick that already travelled (a late flick) creates AND promotes the press")
    func lateFlickPromotesOnItsFirstTick() {
        var tracker = PitchEditorPressTracker()
        let start = CGPoint(x: 0, y: 0)
        let tick = tracker.tick(start: start, location: CGPoint(x: 0, y: 9), tool: .pointer, modifiers: .none,
                                hit: { _ in .note(Self.noteB) })
        #expect(tick.isFirst && tick.didPromote && tick.isPromoted)
        #expect(tick.kind == .noteDrag(Self.noteB))
    }

    @Test("a press that never left the slop releases as a click; the release point's travel still counts")
    func clickWithinSlopAndReleaseTravel() {
        let start = CGPoint(x: 20, y: 20)
        let hit: (CGPoint) -> PitchEditorPressHit = { _ in .note(Self.noteA) }

        var click = PitchEditorPressTracker()
        _ = click.tick(start: start, location: CGPoint(x: 22, y: 21), tool: .pointer, modifiers: .command, hit: hit)
        // The chord is read AT RELEASE (the house table's rule): ⌘ at press,
        // plain at release, is a plain click.
        #expect(click.release(start: start, at: CGPoint(x: 22, y: 21), modifiers: .none)
                == .click(.selectOnly(Self.noteA)))

        var shiftClick = PitchEditorPressTracker()
        _ = shiftClick.tick(start: start, location: start, tool: .pointer, modifiers: .none, hit: hit)
        #expect(shiftClick.release(start: start, at: start, modifiers: .shift) == .click(.toggle(Self.noteA)))

        // No tick past the slop, but the RELEASE lands 10 pt away: it travelled.
        var jump = PitchEditorPressTracker()
        _ = jump.tick(start: start, location: start, tool: .pointer, modifiers: .none, hit: hit)
        #expect(jump.release(start: start, at: CGPoint(x: 20, y: 30), modifiers: .none)
                == .endNoteDrag(Self.noteA))
    }

    @Test("the knife cuts at the PRESS point, however far the hand slipped before release")
    func knifeLandsAtThePress() {
        var tracker = PitchEditorPressTracker()
        let start = CGPoint(x: 100, y: 50)
        _ = tracker.tick(start: start, location: start, tool: .scissors, modifiers: .none, hit: { _ in .note(Self.noteA) })
        _ = tracker.tick(start: start, location: CGPoint(x: 130, y: 70), tool: .scissors, modifiers: .none,
                     hit: { _ in .empty })
        #expect(tracker.release(start: start, at: CGPoint(x: 130, y: 70), modifiers: .none)
                == .cut(at: start))
    }

    @Test("an inert surface: the press is .none and its release does nothing")
    func inertSurface() {
        var tracker = PitchEditorPressTracker()
        let start = CGPoint(x: 5, y: 5)
        let tick = tracker.tick(start: start, location: start, tool: .scissors, modifiers: .none,
                                hit: { _ in .inert })
        #expect(tick.kind == PitchEditorPressKind.none)
        #expect(tracker.release(start: start, at: CGPoint(x: 50, y: 5), modifiers: .none) == .nothing)
    }

    // MARK: - The tracker: gestures are identified by their start

    /// `DragGesture.onEnded` is not guaranteed; the next gesture must not inherit
    /// a stale kind. A DIFFERENT start is a new gesture — routed afresh, which is
    /// not a re-decision of the old one.
    @Test("a new start is a NEW gesture: a stale press is replaced, never inherited")
    func newStartIsANewGesture() {
        var tracker = PitchEditorPressTracker()
        var hitCalls = 0
        let first = CGPoint(x: 10, y: 10)
        _ = tracker.tick(start: first, location: CGPoint(x: 10, y: 40), tool: .pointer, modifiers: .none,
                     hit: { _ in hitCalls += 1; return .note(Self.noteA) })
        // No release arrived. A fresh press elsewhere, with the Split tool:
        let second = CGPoint(x: 300, y: 10)
        let tick = tracker.tick(start: second, location: second, tool: .scissors, modifiers: .none,
                                hit: { _ in hitCalls += 1; return .empty })
        #expect(tick.isFirst)
        #expect(tick.kind == .cut)
        #expect(!tick.isPromoted, "the new press inherited the stale press's promotion")
        #expect(hitCalls == 2)
        #expect(tracker.current?.origin == second)
    }

    @Test("releasing a gesture that is not the one in flight does nothing, and ends the stale press")
    func releaseOfAnotherGestureIsNothing() {
        var tracker = PitchEditorPressTracker()
        let start = CGPoint(x: 10, y: 10)
        _ = tracker.tick(start: start, location: CGPoint(x: 10, y: 40), tool: .pointer, modifiers: .none,
                     hit: { _ in .note(Self.noteA) })
        #expect(tracker.release(start: CGPoint(x: 99, y: 99), at: CGPoint(x: 99, y: 99), modifiers: .none)
                == .nothing)
        #expect(tracker.current == nil)
        // A release with nothing in flight is nothing, too.
        #expect(tracker.release(start: start, at: start, modifiers: .none) == .nothing)
    }

    @Test("cancel abandons the press: the next tick at the SAME point is a new first tick")
    func cancelAbandons() {
        var tracker = PitchEditorPressTracker()
        var hitCalls = 0
        let start = CGPoint(x: 10, y: 10)
        let hit: (CGPoint) -> PitchEditorPressHit = { _ in hitCalls += 1; return .empty }
        _ = tracker.tick(start: start, location: CGPoint(x: 10, y: 30), tool: .pointer, modifiers: .none, hit: hit)
        tracker.cancel()
        #expect(tracker.current == nil)
        let tick = tracker.tick(start: start, location: start, tool: .pointer, modifiers: .none, hit: hit)
        #expect(tick.isFirst && !tick.isPromoted)
        #expect(hitCalls == 2)
    }
}
