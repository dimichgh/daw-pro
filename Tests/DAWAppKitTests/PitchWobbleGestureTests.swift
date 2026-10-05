import CoreGraphics
import Foundation
import Testing
@testable import DAWCore
@testable import DAWAppKit

/// m23-ap C5a-4a — **THE WOBBLE TOOL'S AND THE DOT'S GESTURE LOGIC, HEADLESS.**
/// Design `docs/design/2026-09-24-pitch-editor-vibrato-handle.md` §15 (T2, T4,
/// T7's display leg, T10, T11, T14–T16, T19) and §18.4 (T20–T23); the dot's
/// T-dot-1…3 and 5 (`docs/design/2026-09-24-unpitched-notes-presets-midi-targets.md`
/// §4); natural tuning §3b's coupling, selection and double-click.
///
/// Tests assert PHYSICS where the design asks for it: the played line
/// (`PitchPlayedLine.make`, the render's own curve over the render's own
/// contour) and the generator's zero crossings through `PitchCorrectionCurve`,
/// not a restatement of the arithmetic under test. Every test names the defect
/// planted to prove it can fail; each was applied to `PitchWobbleGesture.swift`,
/// seen red, and reverted (logs: `scratchpad/w4/C5a4a/plants/`).
///
/// ⚠️ NOT a `@MainActor` suite — `MainActorOccupancySiteTests` caps those, and
/// nothing here touches an actor: the gesture is pure values.
@Suite("C5a-4a — the Wobble gesture and the dot, headless")
struct PitchWobbleGestureTests {

    // MARK: - The fixture: one sung note through the render's own seam

    static let frameRate = 62.5
    static let period = 1 / 62.5
    static let row = 20.0

    /// Voiced frames at 62.5 fps over `[start, start + seconds)`, each frame's
    /// VALUE timed at its CENTRE (where the render places it): `hz` carrying
    /// `depth · sin(2π · rate · (centre − phase))` plus `drift(centre)` cents.
    static func frames(hz: Double, start: Double, seconds: Double, rate: Double = 5.5,
                       depth: Double = 40, phase: Double = 0,
                       drift: (Double) -> Double = { _ in 0 }) -> [ClipPitchFrame] {
        let count = Int((seconds / period).rounded(.down))
        return (0..<count).map { i in
            let t = start + Double(i) * period
            let centre = t + period / 2
            let cents = depth * sin(2 * .pi * rate * (centre - phase)) + drift(centre)
            return ClipPitchFrame(timeSeconds: t, frequencyHz: hz * pow(2, cents / 1200),
                                  confidence: 0.97, levelDbfs: -16, absence: nil)
        }
    }

    static func contour(_ frames: [ClipPitchFrame]) -> PitchRenderContour {
        .detected(PitchDetectionResult(
            frames: frames, frameCount: frames.count, voicedFrameCount: frames.count,
            voicedFraction: 1, frameRateHz: frameRate, analysisSampleRateHz: 16_000,
            sourceSampleRateHz: 48_000, windowStartSeconds: frames.first?.timeSeconds ?? 0,
            windowDurationSeconds: Double(frames.count) * period,
            confidenceThreshold: PitchDetectionDefaults.defaultConfidenceThreshold,
            silenceFloorDbfs: PitchDetectionDefaults.defaultSilenceFloorDbfs,
            minFrequencyHz: 46, maxFrequencyHz: 2_093))
    }

    /// One note and its seam: a sung wobble, as the render sees it.
    struct Sung {
        let note: NoteSegment
        let contour: PitchRenderContour
        var reading: PitchWobbleReading? { PitchWobbleEstimate.sung(note, contour: contour) }

        /// The line the render plays with `segment` in place of the note.
        func line(_ segment: NoteSegment) -> PitchPlayedLine {
            PitchPlayedLine.make(contour: contour, fallback: nil,
                                 editSet: PitchEditSet(segments: [segment]),
                                 clipPitchShiftSemitones: 0, sourceWindow: 0..<100)
        }

        /// The estimator's reading of `segment`'s played line — what the
        /// session reads from the line the view hands `update` (`line`).
        func played(_ segment: NoteSegment) -> PitchWobbleReading {
            PitchWobbleEstimate.played(segment, line: line(segment))
        }

        /// The note's played points away from the gate ramps, cents against
        /// `hz`, keyed by frame centre.
        func interior(_ segment: NoteSegment, margin: Double = 0.1) -> [(t: Double, cents: Double)] {
            let from = note.startSeconds + margin
            let to = note.endSeconds - margin
            let centre = Self.midi(note.detectedHz)
            var out: [(t: Double, cents: Double)] = []
            for run in line(segment).runs {
                for point in run where point.sourceSeconds >= from && point.sourceSeconds < to {
                    out.append((point.sourceSeconds, (point.playedMidi - centre) * 100))
                }
            }
            return out
        }

        static func midi(_ hz: Double) -> Double { 69 + 12 * log2(hz / 440) }
    }

    static func sung(hz: Double = 220, start: Double = 1.0, seconds: Double = 1.2,
                     rate: Double = 5.5, depth: Double = 40, phase: Double = 0,
                     drift: @escaping (Double) -> Double = { _ in 0 },
                     keep: Double = 1, driftScale: Double = 1) -> Sung {
        let note = NoteSegment(startSeconds: start, endSeconds: start + seconds, detectedHz: hz,
                               detectedConfidence: 0.95, driftScale: driftScale, vibratoScale: keep)
        return Sung(note: note, contour: contour(frames(hz: hz, start: start, seconds: seconds,
                                                         rate: rate, depth: depth, phase: phase,
                                                         drift: drift)))
    }

    static func note(start: Double = 1.0, seconds: Double = 1.2, hz: Double = 220,
                     keep: Double = 1, drift: Double = 1, rate: Double = 0, depth: Double = 0,
                     onset: Double = 0, anchor: Double = 0,
                     origin: NoteOrigin = .detected) -> NoteSegment {
        NoteSegment(startSeconds: start, endSeconds: start + seconds, detectedHz: hz,
                    detectedConfidence: 0.95, driftScale: drift, vibratoScale: keep,
                    vibratoRateHz: rate, vibratoDepthCents: depth, vibratoOnsetSeconds: onset,
                    vibratoPhaseAnchorSeconds: anchor, origin: origin)
    }

    /// A line with no points: the estimator reads it `.tooFewSamples`, so a
    /// handoff that reads it is refused — as a synthetic unmeasurable reading
    /// was before C5a-F9 made the session read the LINE.
    static let emptyLine = PitchPlayedLine(
        runs: [],
        curve: PitchRenderContour.unavailable(reason: "not needed")
            .curve(editSet: .empty, clipPitchShiftSemitones: 0),
        basis: .render, unresolvedSegmentIDsInWindow: [])

    /// A line for tests that need none: fails loudly if it is ever asked.
    static func noLine(_ segment: NoteSegment) -> PitchPlayedLine {
        Issue.record("playedLine was called for \(segment.id), and must not have been")
        return emptyLine
    }

    static let wobble40 = PitchWobbleReading.wobble(rateHz: 5.5, depthCents: 40,
                                                   anchorSeconds: 1.6, fit: 0.9)

    static func session(_ segment: NoteSegment, _ start: PitchWobbleStart, ratio: Double = 1,
                        members: [PitchWobbleMember] = [], door: PitchWobbleDoor = .drag,
                        coupling: PitchWobbleDriftCoupling = PitchWobbleGesture.coupling,
                        seed: PitchWobbleHandoffSeed = PitchWobbleGesture.handoffSeed)
    throws -> PitchWobbleSession {
        try #require(PitchWobbleSession.begin(segment: segment, start: start, stretchRatio: ratio,
                                              rowHeight: row, members: members, door: door,
                                              coupling: coupling, seed: seed))
    }

    static func rms(_ values: [Double]) -> Double {
        values.isEmpty ? .infinity : (values.map { $0 * $0 }.reduce(0, +) / Double(values.count)).squareRoot()
    }
}

// MARK: - T11: the layout is one constant, and the help follows it

extension PitchWobbleGestureTests {

    /// T11 `layoutIsOneConstant`. For each layout, pure `+dx` changes exactly
    /// the quantity §4.3's table names, and it does so THROUGH A SESSION (the
    /// behaviour, not only the mapping). The help names each layout's own
    /// directions; the ⌘ sentence appears only when the Shape tool exists.
    ///
    /// Planted, red: `travel` ignoring the layout (`speed: dx, width: -dy`
    /// always) — the `sidewaysIsWidth` leg's depth never moves.
    @Test func layoutIsOneConstant() throws {
        #expect(PitchWobbleGesture.layout == .sidewaysIsSpeed, "the user's `vibrato-axis: x-speed`")
        let right = CGSize(width: 40, height: 0)
        let expected: [(PitchWobbleHandleLayout, PitchWobbleKnob, PitchWobbleTravel)] = [
            (.sidewaysIsSpeed, .both, PitchWobbleTravel(speed: 40, width: 0)),
            (.sidewaysIsWidth, .both, PitchWobbleTravel(speed: 0, width: 40)),
            (.twoHandles, .speed, PitchWobbleTravel(speed: 40, width: 0)),
            (.twoHandles, .width, PitchWobbleTravel(speed: 0, width: 0)),
        ]
        for (layout, knob, travel) in expected {
            #expect(PitchWobbleGesture.travel(translation: right, knob: knob, layout: layout) == travel,
                    "\(layout) \(knob)")
        }
        // Up is wider (dy grows DOWN).
        #expect(PitchWobbleGesture.travel(translation: CGSize(width: 0, height: -10), knob: .both,
                                          layout: .sidewaysIsSpeed) == PitchWobbleTravel(speed: 0, width: 10))
        #expect(PitchWobbleGesture.travel(translation: CGSize(width: 0, height: -10), knob: .width,
                                          layout: .twoHandles) == PitchWobbleTravel(speed: 0, width: 10))

        // Through a session: a new wobble dragged right.
        let made = Self.note(rate: 5.5, depth: 40, anchor: 1.6)
        for layout in PitchWobbleHandleLayout.allCases {
            let knob: PitchWobbleKnob = layout == .twoHandles ? .speed : .both
            var s = try Self.session(made, .made(fromNothing: false))
            s.update(travel: PitchWobbleGesture.travel(translation: right, knob: knob, layout: layout),
                     fine: false, playedLine: Self.noLine)
            let widthMoved = s.draft.vibratoDepthCents != 40
            let speedMoved = s.draft.vibratoRateHz != 5.5
            #expect(widthMoved == (layout == .sidewaysIsWidth), "\(layout): width")
            #expect(speedMoved == (layout != .sidewaysIsWidth), "\(layout): speed")
        }

        // The help, derived from the layout.
        let speedHelp = PitchWobbleGesture.help(layout: .sidewaysIsSpeed, drawToolAvailable: false)
        #expect(speedHelp == "Drag up for a wider wobble, down for a flatter one, sideways for faster or slower. "
                + "100 cents is one piano key. Let go to hear it.")
        #expect(PitchWobbleGesture.help(layout: .sidewaysIsWidth, drawToolAvailable: false)
                    .hasPrefix("Drag a note right to widen its wobble, left to smooth it flat. "
                               + "Drag up or down for a faster or slower wobble."))
        #expect(PitchWobbleGesture.help(layout: .twoHandles, drawToolAvailable: false)
                    .hasPrefix("Drag the ↕ knob up to widen a note's wobble, down to smooth it flat. "
                               + "Drag the ↔ knob sideways for a faster or slower wobble."))
        for layout in PitchWobbleHandleLayout.allCases {
            let without = PitchWobbleGesture.help(layout: layout, drawToolAvailable: false)
            let with = PitchWobbleGesture.help(layout: layout, drawToolAvailable: true)
            #expect(!without.contains("⌘"))
            #expect(with.contains("Hold ⌘ to draw instead."))
            #expect(with.hasSuffix("Let go to hear it.") && without.hasSuffix("Let go to hear it."))
        }
    }

    /// The dot and the knobs (unpitched-notes §4, §4.3): the dot at the blob's
    /// TOP centre, grabbed within 12 pt; `twoHandles`' knobs on the same edge,
    /// none on a blob narrower than 40 pt; a click is the router's (4 pt).
    ///
    /// Planted, red: `travelled` with a 5 pt slop — 4 pt of travel then reads
    /// as a click, i.e. a STEP (the dot design's own plant, "4 pt of travel is
    /// a drag, not a step").
    @Test func theDotAndTheKnobs() {
        let blob = CGRect(x: 100, y: 50, width: 90, height: 14)
        #expect(PitchWobbleGesture.dot(in: blob) == CGPoint(x: 145, y: 50))
        #expect(PitchWobbleGesture.knobs(in: blob, layout: .sidewaysIsSpeed)
                == [PitchWobbleKnobPlacement(knob: .both, centre: CGPoint(x: 145, y: 50))])
        #expect(PitchWobbleGesture.knobs(in: blob, layout: .twoHandles)
                == [PitchWobbleKnobPlacement(knob: .speed, centre: CGPoint(x: 130, y: 50)),
                    PitchWobbleKnobPlacement(knob: .width, centre: CGPoint(x: 160, y: 50))])
        #expect(PitchWobbleGesture.knob(at: CGPoint(x: 101, y: 60), in: blob, layout: .twoHandles) == .speed)
        #expect(PitchWobbleGesture.knob(at: CGPoint(x: 189, y: 60), in: blob, layout: .twoHandles) == .width)
        #expect(PitchWobbleGesture.knob(at: CGPoint(x: 101, y: 60), in: blob, layout: .sidewaysIsSpeed) == .both)
        let narrow = CGRect(x: 0, y: 0, width: 39, height: 14)
        #expect(PitchWobbleGesture.knobs(in: narrow, layout: .twoHandles).isEmpty)
        #expect(PitchWobbleGesture.knob(at: .zero, in: narrow, layout: .twoHandles) == nil)
        #expect(PitchWobbleCopy.zoomInForTwoHandles == "Zoom in to change this note's wobble")

        // The door.
        #expect(PitchWobbleGesture.door(at: CGPoint(x: 145, y: 62), blobRect: blob) == .dot)
        #expect(PitchWobbleGesture.door(at: CGPoint(x: 157, y: 50), blobRect: blob) == .dot)
        #expect(PitchWobbleGesture.door(at: CGPoint(x: 158, y: 50), blobRect: blob) == .drag)

        // Click or drag: the ROUTER's slop, one home.
        let origin = CGPoint(x: 145, y: 50)
        let almost = PitchWobbleGesture.travelled(from: origin, to: CGPoint(x: 148.9, y: 50))
        let four = PitchWobbleGesture.travelled(from: origin, to: CGPoint(x: 149, y: 50))
        #expect(!almost && four)
        #expect(PitchWobbleGesture.release(door: .dot, travelled: four, optionHeld: false) == .endDrag)
        #expect(PitchWobbleGesture.release(door: .dot, travelled: almost, optionHeld: false)
                == .step(bigger: true))
        #expect(PitchWobbleGesture.release(door: .dot, travelled: false, optionHeld: true)
                == .step(bigger: false))
        #expect(PitchWobbleGesture.release(door: .drag, travelled: false, optionHeld: false) == .click)
        #expect(PitchWobbleGesture.release(door: .drag, travelled: true, optionHeld: true) == .endDrag)
    }
}

// MARK: - The branch, and T15: gated while estimating

extension PitchWobbleGestureTests {

    /// §5.1's order, §5.5's gate, §1.7's sound. T15 `gatedWhileEstimating`:
    /// with basis `.estimate`, a press on your wobble is refused with the
    /// caption; a new wobble with both scales at 1 is allowed; one with a
    /// scale at 0 is refused. An `.unmeasurable` wobble refuses the handoff
    /// with §18.3's sentence.
    ///
    /// Planted, red: the gate removed (`.estimate` read as `.render`) — the
    /// own-branch press starts.
    @Test func gatedWhileEstimating() throws {
        let plain = Self.note()
        let made = Self.note(rate: 5.5, depth: 40, anchor: 1.6)
        let madeFlat = Self.note(keep: 0, drift: 0, rate: 5.5, depth: 40, anchor: 1.6)
        let pending = PitchPlayedLine.Basis.estimate(reason: PitchPlayedLine.pendingReason)
        let failed = PitchPlayedLine.Basis.estimate(
            reason: PitchPlayedLine.estimateReason(for: .unavailable(reason: "no model")) ?? "")

        #expect(PitchWobbleGesture.classify(segment: plain, sung: Self.wobble40, basis: pending)
                == .refused("Changing a wobble needs the app's analysis of this recording. One moment."))
        #expect(PitchWobbleGesture.classify(segment: plain, sung: Self.wobble40, basis: failed)
                == .refused("The app couldn't analyse this recording, so this note's wobble can't be "
                            + "changed. Its pitch can still be moved."))
        #expect(PitchWobbleGesture.classify(segment: made, sung: nil, basis: pending) == .made(fromNothing: false))
        #expect(PitchWobbleGesture.classify(segment: madeFlat, sung: nil, basis: pending).refusal != nil)
        #expect(PitchWobbleSession.begin(segment: plain,
                                         start: PitchWobbleGesture.classify(segment: plain,
                                                                            sung: Self.wobble40,
                                                                            basis: pending),
                                         stretchRatio: 1, rowHeight: Self.row) == nil)

        // §5.1 under `.render`.
        #expect(PitchWobbleGesture.classify(segment: made, sung: Self.wobble40, basis: .render)
                == .made(fromNothing: false))
        #expect(PitchWobbleGesture.classify(segment: plain, sung: .noWobble, basis: .render)
                == .made(fromNothing: true))
        #expect(PitchWobbleGesture.classify(segment: plain, sung: Self.wobble40, basis: .render)
                == .own(sung: Self.wobble40))
        #expect(PitchWobbleGesture.classify(segment: plain, sung: nil, basis: .render)
                == .own(sung: .unmeasurable(.tooFewSamples)))
        let flattened = Self.note(keep: 0, drift: 0)
        #expect(PitchWobbleGesture.classify(segment: flattened, sung: Self.wobble40, basis: .render)
                == .own(sung: Self.wobble40), "flat is the bottom of your wobble, not a new one")
        // A sound: no pitch, no wobble — and no dot (begin refuses).
        let sound = Self.note(origin: .unpitched)
        #expect(PitchWobbleGesture.classify(segment: sound, sung: Self.wobble40, basis: .render)
                == .refused("No pitch here, so there is no wobble to change."))

        // An unmeasurable wobble refuses the handoff, in §18.3's words
        // (shortened by W7-NTU 2026-10-04 to fit the palette at 1208 pt).
        var uneven = try Self.session(plain, .own(sung: .unmeasurable(.tooUneven)))
        uneven.update(travel: PitchWobbleTravel(speed: 30, width: 0), fine: false) { _ in
            Self.emptyLine
        }
        #expect(uneven.phase == .own)
        #expect(uneven.draft == plain)
        #expect(uneven.readout(played: nil).text
                == "To change its speed, drag down to smooth it flat, then sideways to add a new wobble.")
    }
}

// MARK: - T2 and T10: the first ticks change nothing; one commit per gesture

extension PitchWobbleGestureTests {

    /// T2 `firstSidewaysTickIsIdentical`. A 5.5 Hz ±40 c sung note, basis
    /// `.render`: speed travel of 1…15 pt leaves the draft — and so the drawn
    /// line — EQUAL to the stored one at every tick, never reads the draft, and
    /// ends with no commit. 15 pt sideways with 30 pt up never hands off (the
    /// dominance condition), so the generator fields stay the stored ones.
    ///
    /// Planted, red: `deadZonePoints = 0` — the first sideways tick hands off.
    @Test func firstSidewaysTickIsIdentical() throws {
        let sung = Self.sung()
        let reading = try #require(sung.reading)
        guard case .wobble = reading else { Issue.record("fixture must read as a wobble: \(reading)"); return }
        let start = PitchWobbleGesture.classify(segment: sung.note, sung: reading, basis: .render)
        var s = try Self.session(sung.note, start)
        let stored = sung.line(sung.note)
        for points in 1...15 {
            s.update(travel: PitchWobbleTravel(speed: Double(points), width: 0), fine: false,
                     playedLine: Self.noLine)
            #expect(s.draft == sung.note, "tick \(points)")
            #expect(sung.line(s.draft) == stored, "tick \(points)")
            #expect(s.phase == .own)
        }
        #expect(s.commit() == nil)

        var mostlyUp = try Self.session(sung.note, start)
        mostlyUp.update(travel: PitchWobbleTravel(speed: 15, width: 30), fine: false, playedLine: Self.noLine)
        #expect(mostlyUp.phase == .own)
        #expect(mostlyUp.draft.vibratoRateHz == 0 && mostlyUp.draft.vibratoDepthCents == 0
                && mostlyUp.draft.vibratoPhaseAnchorSeconds == 0)
        mostlyUp.update(travel: PitchWobbleTravel(speed: 20, width: 25), fine: false, playedLine: Self.noLine)
        #expect(mostlyUp.phase == .own, "20 sideways, 25 up: still mostly vertical")
        var reads = 0
        mostlyUp.update(travel: PitchWobbleTravel(speed: 20, width: 19), fine: false) {
            reads += 1
            return sung.line($0)
        }
        #expect(mostlyUp.phase == .handedOff, "20 sideways, 19 up: crossed")
        #expect(reads == 1)
    }

    /// T10 `oneCommitPerWobbleGesture`. Fifty ticks produce no commit (a tick
    /// has no commit output by type) and the estimator runs at most ONCE per
    /// gesture (§8.2 step 7), however long the sideways drag; the release makes
    /// exactly one commit, or none for a no-op. A `fromNothing` gesture that
    /// goes up and comes back to width 0 commits NOTHING, although its draft
    /// parked a rate, a centre anchor and an onset (§5.4).
    ///
    /// Planted, red: (ii) the no-op decided by field inequality alone — the
    /// up-and-back `fromNothing` gesture commits an inaudible, edited-looking
    /// note.
    @Test func oneCommitPerWobbleGesture() throws {
        let sung = Self.sung()
        let reading = try #require(sung.reading)
        var s = try Self.session(sung.note, .own(sung: reading))
        var reads = 0
        for tick in 1...50 {
            s.update(travel: PitchWobbleTravel(speed: Double(tick), width: -Double(tick) / 10),
                     fine: false) {
                reads += 1
                return sung.line($0)
            }
        }
        #expect(reads == 1)
        #expect(s.phase == .handedOff)
        let commit = try #require(s.commit())
        #expect(commit.items.count == 1 && commit.items[0].segmentId == sung.note.id)
        #expect(!commit.isGroup && commit.door == .drag)
        #expect(commit.items[0].edit == NoteVibratoEdit(storedIn: s.draft), "all six fields")

        // A gesture that comes back to where it began commits nothing.
        var back = try Self.session(sung.note, .own(sung: reading))
        back.update(travel: PitchWobbleTravel(speed: 0, width: 30), fine: false, playedLine: Self.noLine)
        #expect(back.commit() != nil)
        back.update(travel: .zero, fine: false, playedLine: Self.noLine)
        #expect(back.draft == sung.note)
        #expect(back.commit() == nil)

        // `fromNothing`: up, then back to width 0.
        let plain = Self.note()
        var parked = try Self.session(plain, .made(fromNothing: true))
        #expect(parked.draft.vibratoRateHz == 5.5 && abs(parked.draft.vibratoPhaseAnchorSeconds - 1.6) < 1e-12)
        parked.update(travel: PitchWobbleTravel(speed: 30, width: 12), fine: false, playedLine: Self.noLine)
        #expect(parked.draft.vibratoDepthCents == 60)
        #expect(parked.commit() != nil)
        parked.update(travel: PitchWobbleTravel(speed: 30, width: 0), fine: false, playedLine: Self.noLine)
        #expect(parked.draft.vibratoDepthCents == 0)
        #expect(parked.draft != plain, "the draft still carries the parked fields")
        #expect(parked.commit() == nil, "plays exactly like the stored note")

        // A note that HAD a new wobble, pulled to width 0: commits, rate kept.
        let made = Self.note(rate: 6, depth: 40, anchor: 1.6)
        var down = try Self.session(made, .made(fromNothing: false))
        down.update(travel: PitchWobbleTravel(speed: 0, width: -40), fine: false, playedLine: Self.noLine)
        let flat = try #require(down.commit())
        #expect(flat.items[0].edit.vibratoDepthCents == 0 && flat.items[0].edit.vibratoRateHz == 6)
    }
}

// MARK: - T4 and T7: the knob holds the phase; flat is flat

extension PitchWobbleGestureTests {

    /// The rising zero crossing of the RENDERED generator nearest `t`, found on
    /// the curve itself (`PitchCorrectionCurve`, 0.05 ms steps, refined).
    static func risingCrossing(of segment: NoteSegment, near t: Double) -> Double? {
        let curve = PitchRenderContour.unavailable(reason: "not needed")
            .curve(editSet: PitchEditSet(segments: [segment]), clipPitchShiftSemitones: 0)
        let step = 0.00005
        var best: Double?
        var previous = curve.semitones(atSourceSecond: t - 0.12)
        var x = t - 0.12 + step
        while x <= t + 0.12 {
            let value = curve.semitones(atSourceSecond: x)
            if previous < 0, value >= 0 {
                let crossing = x - step * value / (value - previous)
                if best.map({ abs(crossing - t) < abs($0 - t) }) ?? true { best = crossing }
            }
            previous = value
            x += step
        }
        return best
    }

    /// T4 `speedDragStretchesAroundTheKnob`. A new wobble on a note centred at
    /// 12.3 s: one speed step (0.1 per second) moves the rising zero crossing
    /// nearest the knob by less than 0.5 ms — the cycles stretch around the
    /// knob instead of jumping (V6).
    ///
    /// Planted, red: the anchor forced to 0 (`centreSeconds` returning 0) — the
    /// crossing moves by about 42 ms (12.3 s × 0.1 Hz of phase).
    @Test func speedDragStretchesAroundTheKnob() throws {
        let plain = Self.note(start: 11.8, seconds: 1.0)
        var s = try Self.session(plain, .made(fromNothing: true))
        s.update(travel: PitchWobbleTravel(speed: 0, width: 8), fine: false, playedLine: Self.noLine)
        #expect(s.draft.vibratoDepthCents == 40)
        let before = try #require(Self.risingCrossing(of: s.draft, near: 12.3))
        s.update(travel: PitchWobbleTravel(speed: 2, width: 8), fine: false, playedLine: Self.noLine)
        #expect(abs(s.heardRateHz - 5.6) < 1e-12)
        let after = try #require(Self.risingCrossing(of: s.draft, near: 12.3))
        #expect(abs(after - before) < 0.0005, "moved \((after - before) * 1000) ms")
        #expect(abs(before - 12.3) < 0.0005, "the crossing sits at the knob")
    }

    /// T7 `flatIsFlat` (the display leg). Pulling a note fully down stores
    /// `vibratoScale 0` AND `driftScale 0` (the default coupling), and the
    /// played line inside the note, away from the gate ramps, has a
    /// peak-to-peak of at most 1 c — on a sung note that wobbles ±40 c AND
    /// drifts 30 c.
    ///
    /// Planted, red: drift left at 1 (the banner's old `vibratoScale 0` alone)
    /// — the 250 ms separator's inverted leak stays in the line, about 17 c
    /// peak-to-peak.
    @Test func flatIsFlat() throws {
        let sung = Self.sung(drift: { 25 * ($0 - 1.6) })
        let reading = try #require(sung.reading)
        var s = try Self.session(sung.note, .own(sung: reading), coupling: .proportional)
        s.update(travel: PitchWobbleTravel(speed: 0, width: -200), fine: false, playedLine: Self.noLine)
        let commit = try #require(s.commit())
        #expect(commit.items[0].edit.vibratoScale == 0 && commit.items[0].edit.driftScale == 0)
        let interior = sung.interior(s.draft).map(\.cents)
        let spread = (interior.max() ?? .infinity) - (interior.min() ?? -.infinity)
        #expect(interior.count > 40)
        #expect(spread <= 1, "peak-to-peak \(spread) c")
        #expect(s.readout(played: sung.played(s.draft)).text == "Your wobble: smoothed flat")

        // Decoupled (G3 passed): the Wobble tool writes the keep only.
        var decoupled = try Self.session(sung.note, .own(sung: reading), coupling: .decoupled)
        decoupled.update(travel: PitchWobbleTravel(speed: 0, width: -200), fine: false, playedLine: Self.noLine)
        #expect(decoupled.draft.vibratoScale == 0 && decoupled.draft.driftScale == 1)
    }
}

// MARK: - T14 and T23: the handoff — what ships, and the design as written

extension PitchWobbleGestureTests {

    /// Hands a sung note off with one sideways tick and returns the lines and
    /// readings on both sides of the crossing.
    struct Crossing {
        let pre: PitchWobbleReading
        let post: PitchWobbleReading
        let rmsCents: Double
        let session: PitchWobbleSession
    }

    static func crossing(_ sung: Sung, seed: PitchWobbleHandoffSeed) throws -> Crossing {
        let reading = try #require(sung.reading)
        var s = try Self.session(sung.note, .own(sung: reading), seed: seed)
        s.update(travel: PitchWobbleTravel(speed: 20, width: 0), fine: false, playedLine: sung.line)
        let pre = sung.interior(sung.note)
        let post = sung.interior(s.draft)
        #expect(pre.count == post.count && pre.count > 40)
        let rms = Self.rms(zip(pre, post).map { $1.cents - $0.cents })
        let crossing = Crossing(pre: sung.played(sung.note), post: sung.played(s.draft), rmsCents: rms,
                                session: s)
        if case .wobble(let r0, let d0, let a0, _) = crossing.pre,
           case .wobble(let r1, let d1, let a1, _) = crossing.post {
            print("c5a4a| T14 \(seed.rawValue) " + String(
                format: "%.1f Hz: rate %.4f→%.4f width %.2f→%.2f anchor Δ %+.2f ms RMS %.2f c",
                sung.note.detectedHz, r0, r1, d0, d1, (a1 - a0) * 1000, rms))
        }
        return crossing
    }

    /// T14 `handoffMatchesWhatWasOnScreen`. A jitter-free 5.5 Hz ±40 c sung
    /// wobble whose phase is EXACTLY opposite to an anchor-0 sine (φ = half a
    /// period), at 150 Hz — inside the one block where `response` (0.83) and
    /// the anchor lag (+6.7 ms) both exist, so both corrections could bite.
    ///
    /// Design leg (§15's tolerance): the two readings agree — rate within
    /// 0.2 Hz, width within 10 c, anchor within 5 ms — and the drawn lines
    /// inside the note differ by at most 10 c RMS.
    ///
    /// Decision leg (tight, from the grids): width within 3 c (half a 5 c
    /// step plus the fit), anchor within 2 ms, RMS within 2 c. By the render
    /// rule the drawn line IS the audio's delta, so this is the sound's
    /// continuity too (the banner's arithmetic).
    ///
    /// Planted, red: (a) the anchor forced to 0 — about half a period off,
    /// ~56 c RMS; (b) the lag subtracted under `.asRead` — the anchor leg (6.7
    /// ms > 5 ms, and > 2 ms); (c) the depth ÷ response under `.asRead` — the
    /// tight width leg (50 vs 40).
    @Test func handoffMatchesWhatWasOnScreen() throws {
        let sung = Self.sung(hz: 150, phase: 1 / 11)
        #expect(PitchWobbleEstimate.response(pitchHz: 150) == 0.83)
        #expect(PitchWobbleEstimate.anchorLagSeconds(pitchHz: 150) == 0.0067)
        let c = try Self.crossing(sung, seed: .asRead)
        #expect(c.session.phase == .handedOff)
        guard case .wobble(let preRate, let preDepth, let preAnchor, _) = c.pre,
              case .wobble(let postRate, let postDepth, let postAnchor, _) = c.post else {
            Issue.record("both sides must read as wobbles: \(c.pre) / \(c.post)"); return
        }
        // Design leg.
        #expect(abs(postRate - preRate) <= 0.2)
        #expect(abs(postDepth - preDepth) <= 10)
        #expect(abs(postAnchor - preAnchor) <= 0.005, "anchor off by \((postAnchor - preAnchor) * 1000) ms")
        #expect(c.rmsCents <= 10, "RMS \(c.rmsCents) c")
        // Decision leg.
        #expect(abs(postDepth - preDepth) <= 3, "width \(preDepth) → \(postDepth)")
        #expect(abs(postAnchor - preAnchor) <= 0.002)
        #expect(c.rmsCents <= 2, "RMS \(c.rmsCents) c")
        // What was seeded: the reading, as read.
        #expect(c.session.draft.vibratoScale == 0 && c.session.draft.driftScale == 0)
        #expect(c.session.draft.vibratoOnsetSeconds == 0, "the user's `wobble-onset: same`")
        #expect(c.session.readout(played: nil).text.hasSuffix(" (replaces most of your own)"))
    }

    /// T23 (re-scoped by the §18.7 decision). `.calibrated` is the design as
    /// written: the seed is read ÷ `response(pitch)`, the anchor subtracts the
    /// measured lag, and the handoff is refused where `response` is nil.
    /// `.asRead` (the default) seeds the reading as read and is never refused
    /// for the pitch — at 110 Hz, where this singer's six real wobbles sit, it
    /// hands off.
    ///
    /// And the arithmetic, measured on the T14 fixture: `.calibrated` jumps
    /// the line by the amounts the banner predicts (width +10 c after the 5 c
    /// grid, anchor −6.7 ms, ≈ 10 c RMS) — each inside §15's 10 c RMS bound on
    /// its own, which is why the tight leg exists.
    ///
    /// Planted, red: `response` fixed at 1.0 — the calibrated seed equals the
    /// read depth.
    @Test func calibratedPolicyIsTheDesignAsWritten() throws {
        let read = PitchWobbleReading.wobble(rateHz: 5.5, depthCents: 40, anchorSeconds: 1.62, fit: 0.9)
        let at150 = Self.note(hz: 150)
        let at110 = Self.note(hz: 110)

        let calibrated = PitchWobbleGesture.handoff(draft: at150, reading: read, sung: read,
                                                    stretchRatio: 1, coupling: .proportional,
                                                    seed: .calibrated)
        guard case .seeded(let edit, let heard) = calibrated else {
            Issue.record("calibrated at 150 Hz must seed: \(calibrated)"); return
        }
        #expect(edit.vibratoDepthCents == 50, "40 ÷ 0.83 = 48.2, on the 5 c grid")
        #expect(abs((edit.vibratoPhaseAnchorSeconds ?? 0) - (1.62 - 0.0067)) < 1e-12)
        #expect(heard == 5.5 && edit.vibratoRateHz == 5.5)
        #expect(PitchWobbleGesture.handoff(draft: at110, reading: read, sung: read, stretchRatio: 1,
                                           seed: .calibrated)
                == .refused(PitchWobbleCopy.handoffRefused))

        for note in [at150, at110] {
            let asRead = PitchWobbleGesture.handoff(draft: note, reading: read, sung: read,
                                                    stretchRatio: 1, coupling: .proportional,
                                                    seed: .asRead)
            #expect(asRead == .seeded(NoteVibratoEdit(vibratoRateHz: 5.5, vibratoDepthCents: 40,
                                                      vibratoOnsetSeconds: 0,
                                                      vibratoPhaseAnchorSeconds: 1.62,
                                                      vibratoScale: 0, driftScale: 0),
                                      heardRateHz: 5.5), "\(note.detectedHz) Hz")
        }
        #expect(PitchWobbleGesture.handoffSeed == .asRead)

        // The design as written, measured on the line.
        let c = try Self.crossing(Self.sung(hz: 150, phase: 1 / 11), seed: .calibrated)
        guard case .wobble(_, let preDepth, let preAnchor, _) = c.pre,
              case .wobble(_, let postDepth, let postAnchor, _) = c.post else {
            Issue.record("both sides must read as wobbles"); return
        }
        #expect(postDepth - preDepth >= 7, "the calibration widens the line: \(preDepth) → \(postDepth)")
        #expect(preAnchor - postAnchor >= 0.005, "the lag moves the sine early")
        #expect(c.rmsCents >= 7 && c.rmsCents <= 12, "RMS \(c.rmsCents) c")
    }

    /// The refusal's own route inside ONE gesture (§18.3: "first drag down to
    /// smooth it flat, then drag sideways"). A `.tooShort` note refuses the
    /// handoff; the same gesture then pulls it flat (width dominating, so no
    /// crossing) and goes sideways again: now it hands off — flat by
    /// construction, so without a second read of the draft.
    ///
    /// Planted, red: the refusal made final for the gesture (the `|| flat`
    /// re-attempt dropped) — speed stays inert after the flatten.
    @Test func aRefusedHandoffIsRetriedOnceFlat() throws {
        var s = try Self.session(Self.note(), .own(sung: .unmeasurable(.tooShort)))
        var reads = 0
        let read: (NoteSegment) -> PitchPlayedLine = { _ in
            reads += 1
            return Self.emptyLine
        }
        s.update(travel: PitchWobbleTravel(speed: 20, width: 0), fine: false, playedLine: read)
        #expect(s.phase == .own && s.handoffRefusal == PitchWobbleCopy.handoffRefused && reads == 1)
        s.update(travel: PitchWobbleTravel(speed: 20, width: -200), fine: false, playedLine: read)
        #expect(s.draft.vibratoScale == 0 && s.draft.driftScale == 0 && s.phase == .own)
        s.update(travel: PitchWobbleTravel(speed: 250, width: -200), fine: false, playedLine: read)
        #expect(s.phase == .handedOff)
        #expect(reads == 1, "flat by construction needs no second read")
        #expect(s.readout(played: nil).text == "New wobble: 5.5 per second, none yet. Drag up to add it.")
    }

    /// §18.3 Defect 1 / T20. A 0.2 s note already flat (keep 0, drift 0),
    /// dragged sideways past the dead zone, HANDS OFF — its played line is the
    /// target line, so no measurement is needed (the estimator would say
    /// `.tooFewSamples` forever). It starts at width 0; dragging up then commits
    /// a new wobble.
    ///
    /// ⚠️ T20 as worded says the depth-0 handoff "commits a new wobble at depth
    /// 0"; T10 says a gesture that plays like the stored note commits NOTHING.
    /// T10 wins: this asserts the handoff happens and that a release at width 0
    /// stores nothing.
    ///
    /// Planted, red: the flat rule removed — the handoff reads the draft, gets
    /// `.tooFewSamples`, and is refused.
    @Test func aFlatShortNoteHandsOff() throws {
        let short = Self.note(seconds: 0.2, keep: 0, drift: 0)
        let start = PitchWobbleGesture.classify(segment: short, sung: .unmeasurable(.tooFewSamples),
                                                basis: .render)
        var s = try Self.session(short, start)
        s.update(travel: PitchWobbleTravel(speed: 20, width: 0), fine: false) { _ in
            Self.emptyLine
        }
        #expect(s.phase == .handedOff)
        #expect(s.draft.vibratoDepthCents == 0 && s.heardRateHz == 5.5)
        #expect(abs(s.draft.vibratoPhaseAnchorSeconds - 1.1) < 1e-12, "the note's centre")
        #expect(s.readout(played: nil).text == "New wobble: 5.5 per second, none yet. Drag up to add it.")
        #expect(s.commit() == nil, "T10: width 0 plays like the stored note")
        s.update(travel: PitchWobbleTravel(speed: 20, width: 6), fine: false, playedLine: Self.noLine)
        let commit = try #require(s.commit())
        #expect(commit.items[0].edit.vibratoDepthCents == 30)
        #expect(commit.items[0].edit.vibratoScale == 0 && commit.items[0].edit.driftScale == 0)
    }
}

// MARK: - C5a-F9: the report floor is a display rule, not a continuity rule

extension PitchWobbleGestureTests {

    /// One narrowed crossing, measured on both sides of the crossing tick.
    struct NarrowedCrossing {
        let pre: PitchWobbleReading
        let preReadout: String
        let lineRMS: Double
        let audioRMS: Double
        let session: PitchWobbleSession
    }

    /// Drags `sung` straight down in quarter-point ticks until its keep is
    /// `keep`, then crosses with ONE sideways tick at the same width, and
    /// measures that tick's jump twice:
    ///  * the played line at its frame centres, inside the note away from the
    ///    gate ramps — what is drawn;
    ///  * the correction curve at 1 ms steps over the same span — what the
    ///    render adds to the detected pitch. REPLACE is `− detected(t) +
    ///    generated(t)` and the detected pitch does not move, so the curve's
    ///    delta IS the heard pitch's delta: the audio path the line predicts.
    static func narrowedCrossing(_ sung: Sung, keep: Double) throws -> NarrowedCrossing {
        let reading = try #require(sung.reading)
        var s = try Self.session(sung.note, .own(sung: reading))
        let target = (keep - 1) / PitchWobbleGesture.keepPerPoint(sung: reading, rowHeight: Self.row)
        var width = 0.0
        while width > target {
            width = max(width - 0.25, target)
            s.update(travel: PitchWobbleTravel(speed: 0, width: width), fine: false, playedLine: Self.noLine)
        }
        #expect(abs(s.draft.vibratoScale - keep) < 1e-9, "keep \(s.draft.vibratoScale), asked \(keep)")
        #expect(s.phase == .own)
        let before = s.draft
        let pre = sung.played(before)
        let preReadout = s.readout(played: pre).text
        s.update(travel: PitchWobbleTravel(speed: 20, width: width), fine: false, playedLine: sung.line)
        #expect(s.phase == .handedOff, "keep \(keep): \(s.handoffRefusal ?? "no refusal")")

        let drawnBefore = sung.interior(before)
        let drawnAfter = sung.interior(s.draft)
        #expect(drawnBefore.count == drawnAfter.count && drawnBefore.count > 40)
        let lineRMS = Self.rms(zip(drawnBefore, drawnAfter).map { $1.cents - $0.cents })

        let heardBefore = sung.line(before).curve
        let heardAfter = sung.line(s.draft).curve
        var deltas: [Double] = []
        var t = sung.note.startSeconds + 0.1
        while t < sung.note.endSeconds - 0.1 {
            deltas.append((heardAfter.semitones(atSourceSecond: t)
                           - heardBefore.semitones(atSourceSecond: t)) * 100)
            t += 0.001
        }
        #expect(deltas.count > 900)
        return NarrowedCrossing(pre: pre, preReadout: preReadout, lineRMS: lineRMS,
                                audioRMS: Self.rms(deltas), session: s)
    }

    /// C5a-F9 — THE GATE. A 5.5 Hz ±40 c sung wobble, dragged down and handed
    /// off at every keep from 0.05 to 0.95. At keep 0.45 — the defect's own
    /// case — the draft plays ±18 c, reads `.noWobble`, says "narrower" (never
    /// "smoothed flat"), and the handoff seeds 20 c (18 on the 5 c grid), not 0.
    ///
    /// The orchestrator's bound, across the floor (keeps 0.30…0.60, both
    /// readings present): the crossing tick moves the drawn line by at most
    /// 2 c RMS AND the heard pitch by at most 2 c RMS.
    ///
    /// Everywhere else the bounds are DERIVED, and each term is pinned:
    ///  * the line: the depth seed's 5 c grid, ≤ 2.5 c of amplitude, so
    ///    ≤ 2.5/√2 = 1.77 c RMS — at frame centres nothing else moves in a
    ///    jitter-free fixture (a seed that lands on the grid jumps 0.00 c);
    ///  * the audio adds the between-frame term: the render cancels the
    ///    detected line as the curve INTERPOLATES it, while the generator is a
    ///    smooth sine — `A·φ²/2·u(1−u)` with `φ = 2π·5.5/62.5`, ≈ 2.0 % of the
    ///    width RMS (pinned below where the seed is exact) and coherent with
    ///    the sine, so it ADDS to a grid round-up: ≤ (2.5 + 1.0)/√2 ≈ 2.5 c.
    ///    Measured: 2.11 c at keep 0.95 (38 → 40 c). That is the pre-F9
    ///    `.wobble` path; F9 did not change it, and the line does not show it.
    ///
    /// Planted, red: (P29) the old zeroing restored — a `.noWobble` reading
    /// seeds width 0 — every keep under the floor drops its whole wobble
    /// (≈ 12.7 c RMS at keep 0.45); (F10-P1, in DAWCore) the accessor's
    /// selection drops the last sample at the end edge.
    @Test func aNarrowedWobbleHandsOffWithoutAJump() throws {
        let sung = Self.sung()
        var under = 0
        var over = 0
        var exact = 0
        for step in 1...19 {
            let keep = Double(step) * PitchWobbleGesture.keepStep
            let c = try Self.narrowedCrossing(sung, keep: keep)
            let depth = c.session.draft.vibratoDepthCents
            print("c5a4a| F9 " + String(format: "keep %.2f: seeded %2.0f c, line %.2f c RMS, audio %.2f c RMS",
                                        keep, depth, c.lineRMS, c.audioRMS)
                  + " — read \(c.pre == .noWobble ? "noWobble" : "wobble")")
            #expect(c.preReadout != PitchWobbleCopy.smoothedFlat, "keep \(keep) is not flat")
            #expect(c.lineRMS <= 2.5 / 2.0.squareRoot(), "keep \(keep): the line jumps \(c.lineRMS) c RMS")
            #expect(c.audioRMS <= 2.5, "keep \(keep): the heard pitch jumps \(c.audioRMS) c RMS")
            if c.lineRMS < 0.01 {
                exact += 1
                #expect(c.audioRMS <= 0.025 * depth, "keep \(keep): between frames \(c.audioRMS) c at \(depth) c")
            }
            if keep > 0.29 && keep < 0.61 {
                if c.pre == .noWobble { under += 1 } else if case .wobble = c.pre { over += 1 }
                #expect(c.lineRMS <= 2, "keep \(keep): the drawn line jumps \(c.lineRMS) c RMS")
                #expect(c.audioRMS <= 2, "keep \(keep): the heard pitch jumps \(c.audioRMS) c RMS")
            }
        }
        #expect(under >= 2 && over >= 2, "the band must straddle the floor: \(under) under, \(over) over")
        #expect(exact >= 2, "the between-frame term needs exact seeds to be pinned: \(exact)")

        let at45 = try Self.narrowedCrossing(sung, keep: 0.45)
        #expect(at45.pre == .noWobble, "±18 c reads under the 20 c report floor")
        #expect(at45.preReadout == "Your wobble: narrower")
        #expect(at45.session.draft.vibratoDepthCents == 20, "18 c on the 5 c grid — not 0")
        #expect(at45.session.draft.vibratoScale == 0 && at45.session.draft.driftScale == 0)
        #expect(at45.session.heardRateHz == 5.5)
        #expect(at45.session.readout(played: nil).text
                == "New wobble: 5.5 per second, 20 cents each way (replaces most of your own)")
    }

    /// C5a-F9 at the function. A `.noWobble` reading of a draft that is NOT
    /// flat by construction seeds the sub-floor fit (on the grids, as a
    /// `.wobble` reading would); with no fit it is REFUSED, never zeroed; only
    /// a draft flat by construction seeds width 0 — per coupling. And
    /// `subFloorFit` needs a sung rate, fits at it, and converts it by the
    /// line's own edited-per-source slope.
    ///
    /// Planted, red: (P31) a missing fit falls through to the flat seed — the
    /// nil-fit handoff seeds width 0 instead of refusing.
    @Test func underTheFloorIsNotFlat() throws {
        let narrowed = Self.note(keep: 0.45, drift: 0.45)
        let fit = PitchWobbleFit(rateHz: 5.5, depthCents: 17.6, anchorSeconds: 1.62)
        #expect(PitchWobbleGesture.handoff(draft: narrowed, reading: .noWobble, sung: Self.wobble40,
                                           subFloorFit: fit, stretchRatio: 1, coupling: .proportional)
                == .seeded(NoteVibratoEdit(vibratoRateHz: 5.5, vibratoDepthCents: 20, vibratoOnsetSeconds: 0,
                                           vibratoPhaseAnchorSeconds: 1.62, vibratoScale: 0, driftScale: 0),
                           heardRateHz: 5.5))
        #expect(PitchWobbleGesture.handoff(draft: narrowed, reading: .noWobble, sung: Self.wobble40,
                                           stretchRatio: 1, coupling: .proportional)
                == .refused(PitchWobbleCopy.handoffRefused))
        // Decoupled: drift left at 1 is not flat either while the keep is 0.45.
        #expect(PitchWobbleGesture.handoff(draft: Self.note(keep: 0.45), reading: .noWobble,
                                           sung: Self.wobble40, stretchRatio: 1, coupling: .decoupled)
                == .refused(PitchWobbleCopy.handoffRefused))

        // Flat by construction: width 0 whatever a fit would say.
        for (draft, coupling) in [(Self.note(keep: 0, drift: 0), PitchWobbleDriftCoupling.proportional),
                                  (Self.note(keep: 0), .decoupled)] {
            let flat = PitchWobbleGesture.handoff(draft: draft, reading: .noWobble, sung: Self.wobble40,
                                                  subFloorFit: fit, stretchRatio: 1, coupling: coupling)
            guard case .seeded(let edit, let heard) = flat else {
                Issue.record("\(coupling): flat by construction must seed: \(flat)"); continue
            }
            #expect(edit.vibratoDepthCents == 0 && heard == 5.5, "\(coupling)")
            #expect(abs((edit.vibratoPhaseAnchorSeconds ?? 0) - 1.6) < 1e-12, "\(coupling): the centre")
        }

        // The fit itself, on the fixture's line at keep 0.45.
        let sung = Self.sung()
        let reading = try #require(sung.reading)
        guard case .wobble(let sungRate, let sungDepth, _, _) = reading else { Issue.record("fixture"); return }
        let draft = Self.sung(keep: 0.45, driftScale: 0.45).note
        let line = sung.line(draft)
        #expect(PitchWobbleEstimate.played(draft, line: line) == .noWobble)
        let measured = try #require(PitchWobbleGesture.subFloorFit(of: draft, line: line, sung: reading))
        #expect(measured.rateHz == sungRate)
        #expect(abs(measured.depthCents - 0.45 * sungDepth) < 0.5, "\(measured.depthCents) vs \(0.45 * sungDepth)")
        for unrated in [PitchWobbleReading.noWobble, .unmeasurable(.tooShort), .unmeasurable(.tooUneven)] {
            #expect(PitchWobbleGesture.subFloorFit(of: draft, line: line, sung: unrated) == nil, "\(unrated)")
        }

        // A line whose edited axis runs at twice the source's: the rate halves.
        let doubled = line.runs.map { run in
            run.map { PitchPlayedLine.Point(sourceSeconds: $0.sourceSeconds,
                                            editedSeconds: 1 + 2 * ($0.sourceSeconds - 1),
                                            sungMidi: $0.sungMidi, playedMidi: $0.playedMidi) }
        }
        let slowed = PitchPlayedLine(runs: doubled, curve: line.curve, basis: .render,
                                     unresolvedSegmentIDsInWindow: [])
        let halved = try #require(PitchWobbleGesture.subFloorFit(of: draft, line: slowed, sung: reading))
        #expect(abs(halved.rateHz - sungRate / 2) < 1e-9)
        #expect(abs(halved.depthCents - measured.depthCents) < 0.5, "the same wobble, slower")
    }

    /// C5a-F9, the refusal inside a gesture. A `.tooShort` sung note (0.4 s,
    /// ±60 c: the estimator fitted ≥ 20 c but cannot trust its rate) narrowed
    /// under the floor has no rate to seed at: the crossing is REFUSED with
    /// §18.3's sentence and the line does not move — not zeroed. The route the
    /// sentence names then hands off continuously (flat by construction).
    @Test func aShortNarrowedWobbleIsRefusedNotZeroed() throws {
        let sung = Self.sung(seconds: 0.4, depth: 60)
        let reading = try #require(sung.reading)
        #expect(reading == .unmeasurable(.tooShort))
        var s = try Self.session(sung.note, .own(sung: reading))
        let width = -0.7 / PitchWobbleGesture.keepPerPoint(sung: reading, rowHeight: Self.row)
        s.update(travel: PitchWobbleTravel(speed: 0, width: width), fine: false, playedLine: Self.noLine)
        #expect(abs(s.draft.vibratoScale - 0.3) < 1e-9)
        let before = s.draft
        #expect(sung.played(before) == .noWobble, "±18 c reads under the floor")
        var reads = 0
        s.update(travel: PitchWobbleTravel(speed: -width + 1, width: width), fine: false) {
            reads += 1
            return sung.line($0)
        }
        #expect(reads == 1)
        #expect(s.phase == .own && s.handoffRefusal == PitchWobbleCopy.handoffRefused)
        #expect(s.draft == before, "refused: nothing moved")
        #expect(s.readout(played: nil).text == PitchWobbleCopy.handoffRefused)
        s.update(travel: PitchWobbleTravel(speed: -width + 1, width: -500), fine: false, playedLine: Self.noLine)
        #expect(s.draft.vibratoScale == 0 && s.draft.driftScale == 0)
        s.update(travel: PitchWobbleTravel(speed: 600, width: -500), fine: false, playedLine: Self.noLine)
        #expect(s.phase == .handedOff, "flat by construction: no second read")
        #expect(reads == 1)
    }

    // ⛔ RETIRED in C5a-F10: `playedSamplesMirrorTheEstimator`. It pinned
    // `PitchWobbleGesture.playedSamples`, a COPY of `played`'s attribution kept
    // here while DAWCore had no accessor. The copy is deleted — the handoff
    // calls `PitchWobbleEstimate.playedSamples`, the one home `played` itself
    // reads through — so there is nothing left to mirror. Its last run (stage
    // A, `scratchpad/w4/C5a4a/f10/stageA-*.log`) compared the copy, i.e. the
    // pre-F10 `played` body verbatim, with the new home bit for bit on its six
    // fixtures. `playedSamplesAreOneFrozenRule` below replaces it.

    /// C5a-F10: `PitchWobbleEstimate.playedSamples` — the ONE home of the
    /// played attribution — against a FROZEN expectation on a hand-built line
    /// whose values are exact in binary: the frame-centre rule (a point AT the
    /// start is in, a point AT the end is out, points outside are out), across
    /// two runs, on the edited axis, against the played (not the sung) median
    /// of an even count. And `played` IS `read` over exactly those samples.
    ///
    /// Planted, red: (F10-P1) the selection drops the last sample at the end
    /// edge — four samples become three. (A `sungMidi` selection would read
    /// all-zero cents; a `sourceSeconds` time axis would read 1.0…1.375.)
    @Test func playedSamplesAreOneFrozenRule() {
        func point(_ source: Double, _ edited: Double, _ played: Double) -> PitchPlayedLine.Point {
            PitchPlayedLine.Point(sourceSeconds: source, editedSeconds: edited, sungMidi: 60, playedMidi: played)
        }
        let line = PitchPlayedLine(
            runs: [[point(0.75, 0.75, 60.25), point(1.0, 1.0, 60.25), point(1.125, 1.25, 60.5)],
                   [point(1.25, 1.5, 61.0), point(1.375, 1.75, 60.75), point(1.5, 2.0, 62.0),
                    point(1.625, 2.25, 63.0)]],
            curve: Self.emptyLine.curve, basis: .render, unresolvedSegmentIDsInWindow: [])
        let note = Self.note(start: 1.0, seconds: 0.5)
        let samples = PitchWobbleEstimate.playedSamples(note, line: line)
        #expect(samples.times == [1.0, 1.25, 1.5, 1.75])
        #expect(samples.cents == [-37.5, -12.5, 37.5, 12.5], "against the played median 60.625")
        #expect(samples.sourceSeconds == [1.0, 1.125, 1.25, 1.375])
        #expect(PitchWobbleEstimate.played(note, line: line)
                == PitchWobbleEstimate.read(times: [1.0, 1.25, 1.5, 1.75], cents: [-37.5, -12.5, 37.5, 12.5]))

        let empty = PitchWobbleEstimate.playedSamples(Self.note(start: 5, seconds: 1), line: line)
        #expect(empty.times.isEmpty && empty.cents.isEmpty && empty.sourceSeconds.isEmpty)
        #expect(PitchWobbleEstimate.played(Self.note(start: 5, seconds: 1), line: line)
                == .unmeasurable(.tooFewSamples))
    }
}

// MARK: - T16: the readout never overclaims

extension PitchWobbleGestureTests {

    /// T16 `readoutNeverOverclaims`.
    ///  * Your wobble at keep 2 on a 5.5 Hz ±40 c note prints EXACTLY the
    ///    estimator's reading of the draft line, rounded to 5, and that reading
    ///    is the one the SHIPPED drift/vibrato separator predicts for the played
    ///    line: `(1 + (k − 1)(1 − H)) × D`, H the drift kernel's response at the
    ///    sung rate, measured here on the product's own kernel.
    ///  * ⚠️ RE-DERIVED BY W7-C3 (natural tuning §3, 2026-09-27; this one test,
    ///    on the orchestrator's grant). Until then this bullet read "that is not
    ///    `k × D` = 80 (the separator's leak makes it ≈ 2.215 × 40 ≈ 89)" and
    ///    asserted `depth > 2.1 × D`: v1's boxcar has H(5.5 Hz) = −0.2155, and
    ///    that LEAK was pinned as if it were the product's truth. An
    ///    unequal-scale note now takes the v2 triangle (L = 0.16 s,
    ///    H(5.5 Hz) ≈ +0.001), so keep 2 reads ≈ 2.00 × D ≈ 80 = `k × D`: at
    ///    5.5 Hz no text can tell the reading from `k × D` any more. The readout
    ///    did not start to overclaim; the physics it reports changed.
    ///  * So the `k × D` plant is caught at 4 Hz, where the v2 kernel does act
    ///    (H ≈ 0.13 at L = 0.16 s): keep 2 reads ≈ 74.6 → "75", `k × D` prints
    ///    80. The fixture checks that the two round apart, and says so when a
    ///    kernel change makes them stop.
    ///  * A new wobble on a ratio-1.25 clip prints the HEARD 6.2, not the
    ///    stored 7.75.
    ///  * `.noWobble` prints no cents; no readout prints a percentage or
    ///    "0 cents"; a pitch no measured block covers prints the speed only.
    ///  * Heard above 8 after a clip-speed change prints the red sentence.
    ///
    /// Planted, red (C5a-4a, under v1): (i) the width computed as `k × D` —
    /// printed 80 at 5.5 Hz; (ii) the stored rate printed — 7.8. ⚠️ Under v2
    /// only the 4 Hz leg above can catch (i), and that leg has NOT been planted
    /// yet: W7-C3 re-derived this test but may not edit
    /// `PitchWobbleGesture.swift`, so the re-plant is owed to its owner (W7-C3
    /// STATUS, 2026-09-27).
    @Test func readoutNeverOverclaims() throws {
        // The shipped drift kernel's response at `rateHz` on this fixture's
        // 62.5 fps grid: the interior gain of a long cosine through the
        // product's own separator (v2: `PitchCorrectionMath.triangularAverage`
        // with the curve's constants), not a restated formula.
        func separatorResponse(atHz rateHz: Double) -> Double {
            let n = 1500
            let x = (0..<n).map { cos(2 * .pi * rateHz * Double($0) * Self.period) }
            let y = PitchCorrectionMath.triangularAverage(
                x, windowSeconds: PitchCorrectionCurve.separatedDriftWindowSeconds,
                stepSeconds: Self.period, edge: PitchCorrectionCurve.separatedDriftEdge)
            var num = 0.0, den = 0.0
            for i in 100..<(n - 100) { num += x[i] * y[i]; den += x[i] * x[i] }
            return num / den
        }
        let sung = Self.sung()
        let reading = try #require(sung.reading)
        guard case .wobble(_, let sungDepth, _, _) = reading else { Issue.record("fixture"); return }
        var wide = try Self.session(sung.note, .own(sung: reading))
        wide.update(travel: PitchWobbleTravel(speed: 0, width: 20), fine: false, playedLine: Self.noLine)
        #expect(wide.draft.vibratoScale == 2 && wide.draft.driftScale == 1)
        let played = sung.played(wide.draft)
        guard case .wobble(let rate, let depth, _, _) = played else { Issue.record("keep 2: \(played)"); return }
        let text = wide.readout(played: played).text
        let predicted = sungDepth * (1 + (2 - 1) * (1 - separatorResponse(atHz: 5.5)))
        print(String(format: "c5a4a| T16 keep 2: played reading %.2f c at %.3f Hz; k × D = %.2f c; "
                     + "the separator predicts %.2f c", depth, rate, 2 * sungDepth, predicted) + " → \(text)")
        #expect(text == "Your wobble: about \(String(format: "%.1f", rate)) per second, about "
                + "\(String(format: "%.0f", (depth / 5).rounded() * 5)) cents each way")
        #expect(abs(depth / predicted - 1) < 0.02,
                "the reading is not the played line's: \(depth) c against the separator's \(predicted) c")

        // The `k × D` plant, at a rate where the drift kernel acts.
        let slow = Self.sung(rate: 4)
        let slowReading = try #require(slow.reading)
        guard case .wobble(_, let slowSungDepth, _, _) = slowReading else { Issue.record("4 Hz fixture"); return }
        var slowWide = try Self.session(slow.note, .own(sung: slowReading))
        slowWide.update(travel: PitchWobbleTravel(speed: 0, width: 20), fine: false, playedLine: Self.noLine)
        #expect(slowWide.draft.vibratoScale == 2 && slowWide.draft.driftScale == 1)
        let slowPlayed = slow.played(slowWide.draft)
        guard case .wobble(let slowRate, let slowDepth, _, _) = slowPlayed else {
            Issue.record("4 Hz keep 2: \(slowPlayed)"); return
        }
        let slowText = slowWide.readout(played: slowPlayed).text
        let slowPredicted = slowSungDepth * (1 + (2 - 1) * (1 - separatorResponse(atHz: 4)))
        print(String(format: "c5a4a| T16 keep 2 at 4 Hz: played reading %.2f c at %.3f Hz; k × D = %.2f c; "
                     + "the separator predicts %.2f c", slowDepth, slowRate, 2 * slowSungDepth, slowPredicted)
              + " → \(slowText)")
        #expect(abs(slowDepth / slowPredicted - 1) < 0.02,
                "the 4 Hz reading is not the played line's: \(slowDepth) c against \(slowPredicted) c")
        // Both sides as the readout prints them (rounded to 5): comparing the
        // rounded reading with the UNROUNDED k × D read 4.99987 < 5 here
        // (W7-C3's own first draft, 07:50) though the texts differ, 75 vs 80.
        #expect((slowDepth / 5).rounded() != (2 * slowSungDepth / 5).rounded(),
                "fixture: at 4 Hz the reading and k × D print the same cents, so this cannot catch the plant; pick a rate where the drift kernel acts")
        #expect(slowText == "Your wobble: about \(String(format: "%.1f", slowRate)) per second, about "
                + "\(String(format: "%.0f", (slowDepth / 5).rounded() * 5)) cents each way")
        #expect(!slowText.contains("\(String(format: "%.0f", 2 * slowSungDepth)) cents"), "\(slowText)")

        // Narrowed under the report floor is "narrower", never "smoothed flat".
        var narrowed = try Self.session(sung.note, .own(sung: reading))
        narrowed.update(travel: PitchWobbleTravel(speed: 0, width: -4.8), fine: false, playedLine: Self.noLine)
        #expect(narrowed.draft.vibratoScale == 0.4)
        let underFloor = sung.played(narrowed.draft)
        #expect(underFloor == .noWobble, "16 c reads under the 20 c report floor")
        #expect(narrowed.readout(played: underFloor).text == "Your wobble: narrower")

        // Heard, not stored.
        let slowed = Self.note(rate: 7.75, depth: 40, anchor: 1.6)
        let heard = try Self.session(slowed, .made(fromNothing: false), ratio: 1.25)
        #expect(heard.readout(played: nil).text == "New wobble: 6.2 per second, 40 cents each way")

        // Nothing measurable: no number of cents at all.
        let plain = Self.note()
        let nothing = try Self.session(plain, .made(fromNothing: true))
        #expect(nothing.readout(played: nil).text == "No wobble the app can measure. Drag up to add one.")

        // Speed only where no block covers the pitch (110 Hz: response nil).
        let low = Self.sung(hz: 110)
        let lowReading = try #require(low.reading)
        let lowSession = try Self.session(low.note, .own(sung: lowReading))
        let lowText = lowSession.readout(played: low.played(low.note)).text
        #expect(lowText.hasPrefix("Your wobble: about 5.") && lowText.hasSuffix(" per second"), "\(lowText)")
        #expect(!lowText.contains("cents"))

        // Red: 8 stored, then the clip sped up to ratio 0.8333… (heard 9.6).
        let fast = Self.note(rate: 8, depth: 40, anchor: 1.6)
        let red = try Self.session(fast, .made(fromNothing: false), ratio: 8 / 9.6).readout(played: nil)
        #expect(red == PitchWobbleReadout(
            "New wobble: 9.6 per second: too fast to play cleanly at this clip's speed", isWarning: true))

        // Over a sweep of states: never a percentage, never "0 cents".
        var texts: [String] = [text, heard.readout(played: nil).text, nothing.readout(played: nil).text,
                               lowText, red.text]
        for width in stride(from: -40.0, through: 40, by: 4) {
            var s = try Self.session(sung.note, .own(sung: reading))
            s.update(travel: PitchWobbleTravel(speed: 0, width: width), fine: false, playedLine: Self.noLine)
            texts.append(s.readout(played: sung.played(s.draft)).text)
            var m = try Self.session(plain, .made(fromNothing: true))
            m.update(travel: PitchWobbleTravel(speed: width * 2, width: width), fine: false, playedLine: Self.noLine)
            texts.append(m.readout(played: nil).text)
        }
        for t in texts {
            #expect(!t.contains("%") && !t.contains(" 0 cents") && !t.hasPrefix("0 cents"), "\(t)")
        }
    }

    /// The ceiling words (§9.2): the fastest that plays cleanly (ratio ≤ 1),
    /// the fastest on a slowed clip (ratio 1.25: 6.4), the slowest, the widest.
    @Test func theCeilingsAreSaid() throws {
        let plain = Self.note()
        var fast = try Self.session(plain, .made(fromNothing: true))
        fast.update(travel: PitchWobbleTravel(speed: 200, width: 8), fine: false, playedLine: Self.noLine)
        #expect(fast.readout(played: nil).text
                == "New wobble: 8.0 per second (the fastest that plays cleanly), 40 cents each way")
        var slowedClip = try Self.session(plain, .made(fromNothing: true), ratio: 1.25)
        slowedClip.update(travel: PitchWobbleTravel(speed: 200, width: 8), fine: false, playedLine: Self.noLine)
        #expect(slowedClip.draft.vibratoRateHz == 8)
        #expect(slowedClip.readout(played: nil).text
                == "New wobble: 6.4 per second (the fastest possible on this slowed-down clip), 40 cents each way")
        var slow = try Self.session(plain, .made(fromNothing: true))
        slow.update(travel: PitchWobbleTravel(speed: -200, width: 100), fine: false, playedLine: Self.noLine)
        #expect(slow.readout(played: nil).text
                == "New wobble: 2.0 per second (the slowest this control goes), "
                + "200 cents each way (the most this control allows)")
        #expect(PitchWobbleGesture.heardRateCeiling(stretchRatio: 0.8) == 8)
        #expect(PitchWobbleGesture.heardRateCeiling(stretchRatio: 1.3) == 6.1, "rounded DOWN: 8 ÷ 1.3 = 6.15")
        let drawn = try Self.session(Self.note(rate: 5.5, depth: 30, anchor: 1.6), .made(fromNothing: false))
        #expect(drawn.readout(played: nil, hasDrawnShape: true).text
                == "New wobble: 5.5 per second, 30 cents each way (your drawn changes stay on top)")
    }
}

// MARK: - T19 and the two coupling policies

extension PitchWobbleGestureTests {

    /// T19 `wideningLeavesTheSlidesAlone`, as natural tuning §3b amends it
    /// (`d0 · k / k0` on the way down). Keep 1 → 1.5: drift stays 1. Keep
    /// 1 → 0.5: drift 0.5. A preset's 0.3/0.3 widened to 0.8: drift stays 0.3.
    /// And the case §5.2's retired `min(d0, k)` got wrong: drift 1 under keep
    /// 0.5 does NOT snap to 0.5 with zero travel, and narrowing to 0.25 takes
    /// it to 0.5, proportionally. Decoupled: drift never moves.
    ///
    /// Planted, red: `min(d0, k)` — the zero-travel leg; drift coupled in both
    /// directions — the widening legs.
    @Test func wideningLeavesTheSlidesAlone() throws {
        func dragged(keep: Double, drift: Double, width: Double,
                     coupling: PitchWobbleDriftCoupling = .proportional) throws -> NoteSegment {
            var s = try Self.session(Self.note(keep: keep, drift: drift), .own(sung: Self.wobble40),
                                     coupling: coupling)
            s.update(travel: PitchWobbleTravel(speed: 0, width: width), fine: false, playedLine: Self.noLine)
            return s.draft
        }
        // 40 c sung at a 20 pt row: 0.125 keep per point.
        #expect(try dragged(keep: 1, drift: 1, width: 4).vibratoScale == 1.5)
        #expect(try dragged(keep: 1, drift: 1, width: 4).driftScale == 1)
        #expect(try dragged(keep: 1, drift: 1, width: -4).driftScale == 0.5)
        #expect(try dragged(keep: 0.3, drift: 0.3, width: 4).vibratoScale == 0.8)
        #expect(try dragged(keep: 0.3, drift: 0.3, width: 4).driftScale == 0.3)
        #expect(try dragged(keep: 0.5, drift: 1, width: 0).driftScale == 1, "no jump with zero travel")
        #expect(try dragged(keep: 0.5, drift: 1, width: -2).driftScale == 0.5)
        #expect(try dragged(keep: 0, drift: 0.7, width: 4).driftScale == 0.7, "k0 = 0: drift untouched")
        for width in [-8.0, -4, 0, 4, 8] {
            #expect(try dragged(keep: 1, drift: 0.6, width: width, coupling: .decoupled).driftScale == 0.6)
        }
        #expect(PitchWobbleGesture.coupling == .proportional, "G3 has not run; v2 does not exist")
        for k in stride(from: 0.0, through: 2, by: 0.05) {
            for coupling in PitchWobbleDriftCoupling.allCases {
                #expect(PitchWobbleGesture.driftScale(keep: 0.9, keepAtStart: 0.9, driftAtStart: k,
                                                      coupling: coupling) == k, "continuous at k = k0")
            }
        }
    }
}

// MARK: - T21, T22 and the premise the cap stands on

extension PitchWobbleGestureTests {

    /// T21: on a `.tooFewSamples` note, dragging up keeps the keep at 1 and
    /// says §18.3's "As you sang it" row; down still smooths. A `.tooShort` or
    /// `.tooUneven` note (the estimator fitted ≥ 20 c) may widen to 2.
    ///
    /// Planted, red: the cap removed (`keepCap` always 2) — the keep reaches 2.
    @Test func shortNotesCannotBeWidened() throws {
        let plain = Self.note()
        var s = try Self.session(plain, .own(sung: .unmeasurable(.tooFewSamples)))
        s.update(travel: PitchWobbleTravel(speed: 0, width: 200), fine: false, playedLine: Self.noLine)
        #expect(s.draft.vibratoScale == 1)
        #expect(s.readout(played: nil).text == "As you sang it. This note is too short to make its wobble wider.")
        s.update(travel: PitchWobbleTravel(speed: 0, width: -30), fine: false, playedLine: Self.noLine)
        #expect(s.draft.vibratoScale == 0.5)
        #expect(s.readout(played: nil).text == "Your wobble: narrower")
        for proven in [PitchWobbleShortfall.tooShort, .tooUneven] {
            var w = try Self.session(plain, .own(sung: .unmeasurable(proven)))
            w.update(travel: PitchWobbleTravel(speed: 0, width: 200), fine: false, playedLine: Self.noLine)
            #expect(w.draft.vibratoScale == 2, "\(proven)")
        }
        // An agent's keep of 1.5 on a short note never snaps down on the first tick.
        var agent = try Self.session(Self.note(keep: 1.5), .own(sung: .unmeasurable(.tooFewSamples)))
        agent.update(travel: PitchWobbleTravel(speed: 0, width: 1), fine: false, playedLine: Self.noLine)
        #expect(agent.draft.vibratoScale == 1.5)
    }

    /// T22: §18.3's words, verbatim, by reading. And the idle words for the
    /// notes the tool cannot measure — the common case on this singer.
    @Test func theWordsForNotesItCannotMeasure() throws {
        #expect(PitchWobbleCopy.tooShortToMeasure
                == "This note is too short to measure its wobble. Drag down to smooth it.")
        #expect(PitchWobbleCopy.tooUnevenToMeasure
                == "This note's pitch slides around rather than wobbling evenly. Drag down to smooth it.")
        #expect(PitchWobbleCopy.cannotWiden == "As you sang it. This note is too short to make its wobble wider.")
        // W7-NTU (2026-10-04): shortened to fit the palette at the 1208 pt
        // floor (`PitchEditorPaletteFitTests.wobbleHelpFitsAtTheFloor`).
        #expect(PitchWobbleCopy.handoffRefused
                == "To change its speed, drag down to smooth it flat, then sideways to add a new wobble.")
        #expect(PitchWobbleCopy.noWobbleToMeasure == "No wobble the app can measure. Drag up to add one.")
        #expect(PitchWobbleCopy.yourWobble(heardRateHz: 5.5, depthCents: nil) == "Your wobble: about 5.5 per second")
        #expect(PitchWobbleCopy.yourWobble(heardRateHz: 5.46, depthCents: 41)
                == "Your wobble: about 5.5 per second, about 40 cents each way")
        #expect(PitchWobbleCopy.speedOneNoteAtATime == "Speed works on one note at a time")

        let plain = Self.note()
        for (shortfall, words) in [(PitchWobbleShortfall.tooFewSamples, PitchWobbleCopy.tooShortToMeasure),
                                   (.tooShort, PitchWobbleCopy.tooShortToMeasure),
                                   (.tooUneven, PitchWobbleCopy.tooUnevenToMeasure)] {
            let s = try Self.session(plain, .own(sung: .unmeasurable(shortfall)))
            #expect(s.readout(played: .unmeasurable(shortfall)).text == words, "\(shortfall)")
        }
    }

    /// The premise `PitchWobbleGesture.keepCap` stands on: the estimator
    /// checks the 20 c report floor BEFORE it calls a note too short or too
    /// uneven — so every `.tooShort` / `.tooUneven` it returns fitted ≥ 20 c,
    /// and `.tooFewSamples` fitted nothing. If DAWCore reorders its decision,
    /// this goes red instead of the cap silently widening an artefact.
    @Test func theEstimatorDecidesTheFloorFirst() {
        func read(seconds: Double, depth: Double) -> PitchWobbleReading {
            let count = Int((seconds / Self.period).rounded(.down))
            let times = (0..<count).map { Double($0) * Self.period }
            return PitchWobbleEstimate.read(times: times,
                                            cents: times.map { depth * sin(2 * .pi * 5.5 * $0) })
        }
        #expect(read(seconds: 0.40, depth: 10) == .noWobble, "short AND below the floor: the floor wins")
        #expect(read(seconds: 0.40, depth: 60) == .unmeasurable(.tooShort))
        #expect(read(seconds: 0.35, depth: 60) == .unmeasurable(.tooFewSamples))
        #expect(PitchWobbleEstimate.reportFloorCents == 20)
    }
}

// MARK: - The dot: one step per click (unpitched-notes §4)

extension PitchWobbleGestureTests {

    /// T-dot-1 / T-dot-2 / T-dot-3. A click moves keep 0.2 to 0.3 in ONE
    /// commit; ⌥-click steps down; the clamps hold at 0, at §18.3's 1 on a note
    /// that cannot be widened, and at 2; a new wobble steps 5 c, up to 200; a
    /// note with none starts one at 5 c; a step that changes nothing commits
    /// nothing.
    ///
    /// Planted, red: the keep step at 0.05 instead of 0.10 — 0.2 → 0.25.
    @Test func aDotClickIsOneStep() throws {
        func clicked(_ segment: NoteSegment, _ start: PitchWobbleStart, bigger: Bool = true)
        throws -> PitchWobbleSession {
            var s = try Self.session(segment, start, door: .dot)
            s.step(bigger: bigger)
            return s
        }
        let one = try clicked(Self.note(keep: 0.2, drift: 0.2), .own(sung: Self.wobble40))
        let commit = try #require(one.commit())
        #expect(commit.items.count == 1 && commit.door == .dot)
        #expect(commit.items[0].edit.vibratoScale == 0.3)
        #expect(one.dotTip().text == "Wobble kept: 30% of how you sang it")

        #expect(try clicked(Self.note(keep: 0.3, drift: 0.3), .own(sung: Self.wobble40),
                            bigger: false).draft.vibratoScale == 0.2)
        #expect(try clicked(Self.note(keep: 0.05, drift: 0.05), .own(sung: Self.wobble40),
                            bigger: false).draft.vibratoScale == 0)
        let atFloor = try clicked(Self.note(keep: 0, drift: 0), .own(sung: Self.wobble40), bigger: false)
        #expect(atFloor.draft.vibratoScale == 0 && atFloor.commit() == nil)
        #expect(atFloor.dotTip().text == "Smoothed flat (a little of your own movement may remain)")

        let capped = try clicked(Self.note(keep: 0.95), .own(sung: .unmeasurable(.tooFewSamples)))
        #expect(capped.draft.vibratoScale == 1)
        let blocked = try clicked(Self.note(), .own(sung: .unmeasurable(.tooFewSamples)))
        #expect(blocked.draft.vibratoScale == 1 && blocked.commit() == nil)
        #expect(blocked.dotTip().text == "As you sang it. This note is too short to make its wobble wider.")

        let top = try clicked(Self.note(keep: 1.95), .own(sung: Self.wobble40))
        #expect(top.draft.vibratoScale == 2)
        #expect(top.dotTip().text == "Wobble widened to 200%")
        #expect(try clicked(Self.note(keep: 2), .own(sung: Self.wobble40)).commit() == nil)
        #expect(try clicked(Self.note(keep: 0.9), .own(sung: Self.wobble40)).dotTip().text
                == "As you sang it (100%)")

        // A new wobble: ± 5 c, up to 200.
        let made = try clicked(Self.note(rate: 5.5, depth: 195, anchor: 1.6), .made(fromNothing: false))
        #expect(made.draft.vibratoDepthCents == 200)
        #expect(try clicked(Self.note(rate: 5.5, depth: 200, anchor: 1.6), .made(fromNothing: false))
                    .commit() == nil)
        let started = try clicked(Self.note(), .made(fromNothing: true))
        #expect(started.draft.vibratoDepthCents == 5 && started.draft.vibratoRateHz == 5.5)
        #expect(started.dotTip().text == "New wobble: 5.5 per second, 5 cents each way")
        #expect(started.commit() != nil)
        #expect(try clicked(Self.note(), .made(fromNothing: true), bigger: false).commit() == nil)
    }

    /// T-dot-5: the tip's exact strings, the user's own wording (`dot: other`).
    @Test func theDotTipIsTheUsersWording() {
        #expect(PitchWobbleCopy.dotTip(keep: 0.3) == "Wobble kept: 30% of how you sang it")
        #expect(PitchWobbleCopy.dotTip(keep: 1) == "As you sang it (100%)")
        #expect(PitchWobbleCopy.dotTip(keep: 0) == "Smoothed flat (a little of your own movement may remain)")
        #expect(PitchWobbleCopy.dotTip(keep: 1.3) == "Wobble widened to 130%")
        #expect(PitchWobbleCopy.dotTip(keep: 0.31) == "Wobble kept: 31% of how you sang it")
    }
}

// MARK: - The draft is what the store keeps; selection; double-click; ⌥

extension PitchWobbleGestureTests {

    /// Every draft goes through `NoteVibratoLimits.clamp`, and the commit is a
    /// fixed point of it: the store's own batch transform writes exactly the
    /// session's draft (C5a-2's read-back rule: expect `clamp(edit).edit`).
    /// At ratio 0.8 the fastest heard 8.0 is a STORED 6.4; at 1.25 the fastest
    /// heard is 6.4, a stored 8.
    ///
    /// Planted, red: the heard rate written as stored (`× ratio` forgotten) —
    /// at 1.25 the note would play 5.1 per second under a readout of 6.4 (at
    /// 0.8 the clamp hides it: 8 stored clamps to the same 6.4).
    @Test func theDraftIsWhatTheStoreKeeps() throws {
        for ratio in [0.8, 1, 1.25] {
            let plain = Self.note()
            var s = try Self.session(plain, .made(fromNothing: true), ratio: ratio)
            s.update(travel: PitchWobbleTravel(speed: 300, width: 10), fine: false, playedLine: Self.noLine)
            let commit = try #require(s.commit())
            let edit = commit.items[0].edit
            let clamp = try NoteVibratoLimits.clamp(edit, stretchRatio: ratio)
            #expect(clamp.bound.isEmpty && clamp.edit == edit, "ratio \(ratio): \(clamp.bound)")
            let table = PitchEditSet(segments: [plain])
            let written = try table.applyingNoteVibratos(commit.items, stretchRatio: ratio, clipId: UUID())
            #expect(written.set.segments[0] == s.draft, "ratio \(ratio)")
            #expect(abs(s.draft.vibratoRateHz / ratio - s.heardRateHz) < 1e-9)
        }
        var fast = try Self.session(Self.note(), .made(fromNothing: true), ratio: 0.8)
        fast.update(travel: PitchWobbleTravel(speed: 300, width: 10), fine: false, playedLine: Self.noLine)
        #expect(fast.heardRateHz == 8 && abs(fast.draft.vibratoRateHz - 6.4) < 1e-12)
    }

    /// Natural tuning §3b: a press on a note inside a selection moves every
    /// selected note's keep by the SAME Δ from its OWN mouse-down value, each
    /// clamped by its own cap; a sound rides along untouched; speed does
    /// nothing and says so; the commit is one group step.
    @Test func aSelectionRidesTheKeepLever() throws {
        let pressed = Self.note(start: 1)
        let wide = Self.note(start: 3, keep: 1.8)
        let short = Self.note(start: 5, seconds: 0.2)
        let sound = Self.note(start: 6, origin: .unpitched)
        let members = [PitchWobbleMember(segment: wide, sung: Self.wobble40),
                       PitchWobbleMember(segment: short, sung: .unmeasurable(.tooFewSamples)),
                       PitchWobbleMember(segment: sound, sung: nil)]
        var s = try Self.session(pressed, .own(sung: Self.wobble40), members: members)
        #expect(s.phase == .group && s.members.count == 2, "the sound is dropped")
        s.update(travel: PitchWobbleTravel(speed: 0, width: 4), fine: false, playedLine: Self.noLine)
        #expect(s.draft.vibratoScale == 1.5)
        #expect(s.memberDrafts.map(\.vibratoScale) == [2, 1], "each from its own start, its own cap")
        s.update(travel: PitchWobbleTravel(speed: 40, width: 4), fine: false, playedLine: Self.noLine)
        #expect(s.readout(played: nil).text == "Speed works on one note at a time")
        #expect(s.draft.vibratoRateHz == 0 && s.phase == .group)
        let commit = try #require(s.commit())
        #expect(commit.isGroup)
        #expect(commit.items.map(\.segmentId) == [pressed.id, wide.id], "the capped note did not change")
    }

    /// Natural tuning §3b: double-click toggles as sung ↔ flat (the value it
    /// leaves is not remembered). Proportional: both scales; decoupled: the
    /// keep only. A sound has none.
    @Test func doubleClickTogglesAsSungAndFlat() {
        #expect(PitchWobbleGesture.doubleClickEdit(Self.note(keep: 0.6, drift: 0.6), coupling: .proportional)
                == NoteVibratoEdit(vibratoScale: 0, driftScale: 0))
        #expect(PitchWobbleGesture.doubleClickEdit(Self.note(keep: 0, drift: 0), coupling: .proportional)
                == NoteVibratoEdit(vibratoScale: 1, driftScale: 1))
        #expect(PitchWobbleGesture.doubleClickEdit(Self.note(keep: 1), coupling: .decoupled)
                == NoteVibratoEdit(vibratoScale: 0))
        #expect(PitchWobbleGesture.doubleClickEdit(Self.note(origin: .unpitched)) == nil)
    }

    /// §4.1: ⌥ divides every GAIN by 4, read per tick, and toggling it
    /// mid-drag never jumps the value; the dead zone is a distance and is not
    /// divided.
    @Test func fineControlDividesGainsNotTheDeadZone() throws {
        var fine = try Self.session(Self.note(), .own(sung: Self.wobble40))
        fine.update(travel: PitchWobbleTravel(speed: 0, width: 8), fine: true, playedLine: Self.noLine)
        #expect(fine.draft.vibratoScale == 1.25, "8 pt × 0.125 ÷ 4")
        fine.update(travel: PitchWobbleTravel(speed: 0, width: 8), fine: false, playedLine: Self.noLine)
        #expect(fine.draft.vibratoScale == 1.25, "releasing ⌥ without moving changes nothing")
        fine.update(travel: PitchWobbleTravel(speed: 0, width: 12), fine: false, playedLine: Self.noLine)
        #expect(fine.draft.vibratoScale == 1.75)
        let sung = Self.sung()
        var crossing = try Self.session(sung.note, .own(sung: try #require(sung.reading)))
        var reads = 0
        crossing.update(travel: PitchWobbleTravel(speed: 16, width: 0), fine: true) {
            reads += 1
            return sung.line($0)
        }
        #expect(reads == 1 && crossing.phase == .handedOff)
    }
}
