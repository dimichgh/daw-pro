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

    /// The six (tool, hit) answers, each spelled out TWICE: without ⌘ (plain
    /// and ⇧) and with it (⌘ and ⇧⌘). Iterated under all four chords below:
    /// 24 rows. m23-ap C5b-4b — ⌘ on a note in the Move tool is the BRUSH;
    /// every other row reads the same with and without it.
    private static let routeRows: [(tool: PitchEditorTool, hit: PitchEditorPressHit,
                                    expected: PitchEditorPressKind,
                                    withCommand: PitchEditorPressKind)] = [
        (.pointer, .note(noteA), .noteDrag(noteA), .brush(noteA)),
        (.pointer, .empty, .band, .band),
        (.pointer, .inert, .none, .none),
        (.scissors, .note(noteA), .cut, .cut),
        (.scissors, .empty, .cut, .cut),
        (.scissors, .inert, .none, .none),
    ]

    @Test("⭐ the full truth table: 2 tools × 4 chords × 3 hits, every row a literal")
    func fullTruthTable() {
        var rows = 0
        for chord in Self.chords {
            for row in Self.routeRows {
                let kind = PitchEditorGestureRouter.route(tool: row.tool, modifiersAtPress: chord.value,
                                                          hit: row.hit)
                let expected = chord.value.contains(.command) ? row.withCommand : row.expected
                #expect(kind == expected, "\(row.tool) + \(chord.name) on \(row.hit)")
                rows += 1
            }
        }
        #expect(rows == 24)
    }

    /// ⚠️ RETIRED BY NAME at m23-ap C5b-4b: "no kind depends on the press chord
    /// yet — the designed ⌘ kinds are not built" (`chordIsInertToday`). Its own
    /// doc said adding the ⌘-brush "must be a deliberate row change", and this
    /// is that change: the claim it pinned is now false by design.
    ///
    /// Its replacement states EXACTLY which (tool, hit) pairs the chord
    /// changes — every pair in all three tools, dots included: ⇧ changes
    /// nothing anywhere; ⌘ changes precisely the note and dot presses of the
    /// Move and Wobble tools, into `.brush` on that note; the knife, empty
    /// surface and an inert surface ignore every chord. A router that let ⌘
    /// reach the knife, or ⇧ start a stroke, fails here by name.
    @Test("C5b-4b — only ⌘, and only on a note or its dot in Move or Wobble, changes a kind: into the brush on that note")
    func onlyCommandOnANoteChangesAKind() {
        let a = Self.noteA
        let hits: [PitchEditorPressHit] = [.note(a), .dot(a), .empty, .inert]
        var changed: [String] = []
        for tool in PitchEditorTool.allCases {
            for hit in hits {
                let plain = PitchEditorGestureRouter.route(tool: tool, modifiersAtPress: .none, hit: hit)
                #expect(PitchEditorGestureRouter.route(tool: tool, modifiersAtPress: .shift, hit: hit) == plain,
                        "⇧ changed \(tool) on \(hit)")
                let command = PitchEditorGestureRouter.route(tool: tool, modifiersAtPress: .command, hit: hit)
                #expect(PitchEditorGestureRouter.route(tool: tool, modifiersAtPress: [.shift, .command],
                                                       hit: hit) == command,
                        "⇧⌘ disagrees with ⌘ on \(tool) on \(hit)")
                if command != plain {
                    #expect(command == .brush(a), "⌘ on \(tool) on \(hit) routed \(command), not the brush")
                    changed.append("\(tool.rawValue)/\(hit)")
                }
            }
        }
        // W7-NTU U3 — the Voice tool draws with ⌘ too ("⌘ held at mouse-down
        // is the C5b brush in every tool"), and still only on a note.
        #expect(changed == ["pointer/note(\(a))", "pointer/dot(\(a))",
                            "wobble/note(\(a))", "wobble/dot(\(a))",
                            "voice/note(\(a))", "voice/dot(\(a))"],
                "⌘ changed exactly these presses: \(changed)")
        // The one home of "does ⌘ draw here", literal per tool.
        #expect(PitchEditorGestureRouter.commandDraws(in: .pointer))
        #expect(PitchEditorGestureRouter.commandDraws(in: .wobble))
        #expect(PitchEditorGestureRouter.commandDraws(in: .voice))
        #expect(!PitchEditorGestureRouter.commandDraws(in: .scissors))
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
        // C5b-4b — the brush's press and release.
        #expect(PitchEditorPressKind.brush(Self.noteB).noteID == Self.noteB)
        #expect(PitchEditorPressKind.brush(Self.noteB).wobbleDoor == nil)
        #expect(PitchEditorPressKind.brush(Self.noteB).key == "brush")
        #expect(PitchEditorReleaseAction.endBrush(Self.noteB).key == "endBrush")
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
            // C5b-4b — the brush: travelled ends the stroke whatever is held at
            // the release; a press that never left the slop is the house click,
            // read with the chord AT RELEASE (⌘ let go first: a plain click).
            (.brush(a), true, .none, .endBrush(a)),
            (.brush(a), true, .command, .endBrush(a)),
            (.brush(a), true, [.shift, .command], .endBrush(a)),
            (.brush(a), false, .command, .click(.toggle(a))),
            (.brush(a), false, .shift, .click(.toggle(a))),
            (.brush(a), false, .none, .click(.selectOnly(a))),
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

    // MARK: - m23-ap C5a-4b — the Wobble tool's rows

    /// The Wobble tool's routes and releases, every answer a literal, beside
    /// the Move and Split rows it must not disturb. A `.dot` hit is only ever
    /// REPORTED in the Wobble tool, but the table is total: Move answers it as
    /// the note it sits on, Split as a cut.
    ///
    /// Planted and seen red: `(.wobble, .note)` routed `.noteDrag` (the Wobble
    /// tool moving pitch), and the dot's ⌥ read from the press chord instead
    /// of `optionAtRelease` (every ⌥-click a step UP).
    @Test("C5a-4b — the Wobble tool routes a note press to the wobble (door drag), a dot press to its step (door dot), empty to a band; its release: travelled ends the drag, a still dot is ONE step (⌥ at release = smaller), a still note press is the house click; Move and Split unchanged")
    func wobbleToolRowsAreLiterals() {
        let a = Self.noteA
        // C5b-4b — each row spelled with and without ⌘: ⌘ at the press on a
        // note or its dot is the BRUSH in the Wobble tool too (vibrato design
        // §4.2), and the knife ignores it.
        let routes: [(tool: PitchEditorTool, hit: PitchEditorPressHit, expected: PitchEditorPressKind,
                      withCommand: PitchEditorPressKind)] = [
            (.wobble, .note(a), .wobble(a, door: .drag), .brush(a)),
            (.wobble, .dot(a), .wobble(a, door: .dot), .brush(a)),
            (.wobble, .empty, .band, .band),
            (.wobble, .inert, .none, .none),
            // Move and Split, re-asked with the new hit: unchanged in meaning.
            (.pointer, .dot(a), .noteDrag(a), .brush(a)),
            (.scissors, .dot(a), .cut, .cut),
        ]
        for chord in Self.chords {
            for row in routes {
                let expected = chord.value.contains(.command) ? row.withCommand : row.expected
                #expect(PitchEditorGestureRouter.route(tool: row.tool, modifiersAtPress: chord.value,
                                                       hit: row.hit) == expected,
                        "\(row.tool) + \(chord.name) on \(row.hit)")
            }
        }
        // The Move tool's own table, re-read with the new ⌥ argument at both
        // values: ⌥ at release means nothing outside the Wobble tool.
        let origin = CGPoint(x: 40, y: 12)
        for travelled in [false, true] {
            for option in [false, true] {
                #expect(PitchEditorGestureRouter.release(kind: .noteDrag(a), travelled: travelled,
                                                         origin: origin, modifiersAtRelease: .none,
                                                         optionAtRelease: option)
                        == (travelled ? .endNoteDrag(a) : .click(.selectOnly(a))))
                #expect(PitchEditorGestureRouter.release(kind: .band, travelled: travelled,
                                                         origin: origin, modifiersAtRelease: .none,
                                                         optionAtRelease: option)
                        == (travelled ? .endBand : .click(.deselect)))
            }
        }
        let releases: [(PitchEditorPressKind, Bool, Bool, ArrangeClickModifiers, PitchEditorReleaseAction)] = [
            // (kind, travelled, ⌥ at release, chord, expected)
            (.wobble(a, door: .dot), false, false, .none, .wobbleStep(a, bigger: true)),
            (.wobble(a, door: .dot), false, true, .none, .wobbleStep(a, bigger: false)),
            (.wobble(a, door: .dot), false, false, .shift, .wobbleStep(a, bigger: true)),
            (.wobble(a, door: .dot), true, false, .none, .endWobble(a)),
            (.wobble(a, door: .dot), true, true, .none, .endWobble(a)),
            (.wobble(a, door: .drag), true, false, .none, .endWobble(a)),
            (.wobble(a, door: .drag), true, true, .command, .endWobble(a)),
            (.wobble(a, door: .drag), false, false, .none, .click(.selectOnly(a))),
            (.wobble(a, door: .drag), false, true, .none, .click(.selectOnly(a))),
            (.wobble(a, door: .drag), false, false, .shift, .click(.toggle(a))),
        ]
        for (kind, travelled, option, chord, expected) in releases {
            #expect(PitchEditorGestureRouter.release(kind: kind, travelled: travelled, origin: origin,
                                                     modifiersAtRelease: chord,
                                                     optionAtRelease: option) == expected,
                    "\(kind) travelled=\(travelled) ⌥=\(option) chord=\(chord.rawValue)")
        }
        // The echo's tags and payloads.
        #expect(PitchEditorPressKind.wobble(a, door: .dot).key == "wobble")
        #expect(PitchEditorPressKind.wobble(a, door: .dot).noteID == a)
        #expect(PitchEditorPressKind.wobble(a, door: .drag).wobbleDoor == .drag)
        #expect(PitchEditorPressKind.noteDrag(a).wobbleDoor == nil)
        #expect([PitchEditorReleaseAction.endWobble(a), .wobbleStep(a, bigger: true)].map(\.key)
                == ["endWobble", "wobbleStep"])
    }

    /// ⭐ **4 pt IS A DRAG, not a step** — the Wobble tool borrows the ONE slop
    /// (vibrato-handle §18.8): a dot press that travelled exactly
    /// `PitchEditorGestureRouter.slop` releases as the end of a drag; 3.99 pt
    /// is still a click, so a step. Through the tracker, the way the pane runs
    /// it. Planted and seen red: the wobble release reading `hasTravelled` with
    /// `>` (4 pt a step).
    @Test("C5a-4b — 4 pt of travel on the dot is a DRAG (endWobble); 3.99 pt is still a click (one step)")
    func fourPointsOnTheDotIsADrag() {
        let a = Self.noteA
        let start = CGPoint(x: 100, y: 100)
        for (end, expected) in [(CGPoint(x: 104, y: 100), PitchEditorReleaseAction.endWobble(a)),
                                (CGPoint(x: 100, y: 96), .endWobble(a)),
                                (CGPoint(x: 103.99, y: 100), .wobbleStep(a, bigger: true))] {
            var tracker = PitchEditorPressTracker()
            _ = tracker.tick(start: start, location: start, tool: .wobble, modifiers: .none,
                             hit: { _ in .dot(a) })
            _ = tracker.tick(start: start, location: end, tool: .wobble, modifiers: .none,
                             hit: { _ in .dot(a) })
            #expect(tracker.release(start: start, at: end, modifiers: .none) == expected,
                    "released at \(end)")
        }
    }

    // MARK: - W7-NTU U3 — the Voice tool

    /// Planted and seen red (W7-NTU P-v-route): `(.voice, .note)` routed
    /// `.noteDrag` (the Voice tool moving pitch).
    @Test("W7-NTU U3 — the Voice tool routes a note press to its Voice (the brush with ⌘), empty to a band, an inert surface to nothing; every row a literal under all four chords")
    func voiceToolRowsAreLiterals() {
        let a = Self.noteA
        let routes: [(hit: PitchEditorPressHit, expected: PitchEditorPressKind,
                      withCommand: PitchEditorPressKind)] = [
            (.note(a), .formantDrag(a), .brush(a)),
            (.dot(a), .formantDrag(a), .brush(a)),
            (.empty, .band, .band),
            (.inert, .none, .none),
        ]
        var rows = 0
        for chord in Self.chords {
            for row in routes {
                let expected = chord.value.contains(.command) ? row.withCommand : row.expected
                #expect(PitchEditorGestureRouter.route(tool: .voice, modifiersAtPress: chord.value,
                                                       hit: row.hit) == expected,
                        "voice + \(chord.name) on \(row.hit)")
                rows += 1
            }
        }
        #expect(rows == 16)
        #expect(PitchEditorPressKind.formantDrag(a).key == "formantDrag")
        #expect(PitchEditorPressKind.formantDrag(a).noteID == a)
        #expect(PitchEditorPressKind.formantDrag(a).wobbleDoor == nil)
        #expect([PitchEditorReleaseAction.endFormantDrag(a), .formantReset(a)].map(\.key)
                == ["endFormantDrag", "formantReset"])
    }

    /// Planted and seen red (W7-NTU P-v-dbl): the click count ignored (a
    /// double-click is two selects and never a reset).
    @Test("W7-NTU U3 — a Voice press's release: travelled ends the drag whatever the count; a still press is the house click, and the SECOND click of a double-click resets; no other kind reads the count")
    func voiceReleaseReadsTheClickCount() {
        let a = Self.noteA
        let origin = CGPoint(x: 40, y: 12)
        let rows: [(travelled: Bool, clicks: Int, chord: ArrangeClickModifiers,
                    expected: PitchEditorReleaseAction)] = [
            (true, 1, .none, .endFormantDrag(a)),
            (true, 2, .none, .endFormantDrag(a)),
            (true, 1, .command, .endFormantDrag(a)),
            (false, 1, .none, .click(.selectOnly(a))),
            (false, 1, .shift, .click(.toggle(a))),
            (false, 1, .command, .click(.toggle(a))),
            (false, 2, .none, .formantReset(a)),
            (false, 2, .shift, .formantReset(a)),
            (false, 3, .none, .formantReset(a)),
        ]
        for row in rows {
            #expect(PitchEditorGestureRouter.release(kind: .formantDrag(a), travelled: row.travelled,
                                                     origin: origin, modifiersAtRelease: row.chord,
                                                     clickCount: row.clicks) == row.expected,
                    "travelled=\(row.travelled) clicks=\(row.clicks) chord=\(row.chord.rawValue)")
        }
        // Every other kind ignores the count: a double-click in the Move tool
        // is still a select, on empty surface still a deselect.
        #expect(PitchEditorGestureRouter.release(kind: .noteDrag(a), travelled: false, origin: origin,
                                                 modifiersAtRelease: .none, clickCount: 2)
                == .click(.selectOnly(a)))
        #expect(PitchEditorGestureRouter.release(kind: .band, travelled: false, origin: origin,
                                                 modifiersAtRelease: .none, clickCount: 2)
                == .click(.deselect))
        #expect(PitchEditorGestureRouter.release(kind: .wobble(a, door: .drag), travelled: false,
                                                 origin: origin, modifiersAtRelease: .none,
                                                 clickCount: 2)
                == .click(.selectOnly(a)))
    }

    /// Planted and seen red (W7-NTU P-v-track): the tracker not handing the
    /// count on.
    @Test("W7-NTU U3 — through the tracker, the way the pane runs it: the release's click count reaches the router")
    func trackerHandsTheClickCountOn() {
        let a = Self.noteA
        let start = CGPoint(x: 100, y: 100)
        for (clicks, expected) in [(1, PitchEditorReleaseAction.click(.selectOnly(a))),
                                   (2, .formantReset(a))] {
            var tracker = PitchEditorPressTracker()
            _ = tracker.tick(start: start, location: start, tool: .voice, modifiers: .none,
                             hit: { _ in .note(a) })
            #expect(tracker.release(start: start, at: start, modifiers: .none, clickCount: clicks)
                    == expected, "clicks=\(clicks)")
        }
        // 4 pt of travel is a drag, a double-click or not.
        var tracker = PitchEditorPressTracker()
        _ = tracker.tick(start: start, location: start, tool: .voice, modifiers: .none, hit: { _ in .note(a) })
        _ = tracker.tick(start: start, location: CGPoint(x: 100, y: 96), tool: .voice, modifiers: .none,
                         hit: { _ in .note(a) })
        #expect(tracker.release(start: start, at: CGPoint(x: 100, y: 96), modifiers: .none, clickCount: 2)
                == .endFormantDrag(a))
    }
}
