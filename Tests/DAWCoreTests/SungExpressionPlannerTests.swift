import Foundation
import Testing
@testable import DAWCore

/// p2-sing-x5 (DSP half, W8-X5D): `SungExpressionPlanner`'s tables, design
/// `docs/design/2026-10-06-p2-sing-expansion.md` §5.4 / §5.7 "Planner tables".
/// Pre-registered in the lane's PREDICTIONS P1 before this file existed.
///
/// Pure and nonisolated (`MainActorOccupancySiteTests` Leg C caps
/// `@MainActor` suites).
@Suite("p2-sing-x5 — SungExpressionPlanner: mapping, presets, velocity, nil is today")
struct SungExpressionPlannerTests {

    // MARK: - Fixtures

    static func segment(_ start: Double, _ end: Double, _ origin: NoteOrigin = .detected,
                        id: UUID = UUID()) -> NoteSegment {
        NoteSegment(id: id, startSeconds: start, endSeconds: end, detectedHz: 220,
                    detectedConfidence: 0.95, origin: origin)
    }

    /// The editor's seed, as `PitchNoteTable.detected` builds it (not legacy).
    static func table(_ segments: [NoteSegment]) -> PitchEditSet {
        PitchEditSet.seeded(analysisVersion: PitchEditSet.currentAnalysisVersion, segments: segments,
                            retuneMs: 30, partKinds: [:], seedPolicy: .editor)
    }

    static func note(_ start: Double, _ end: Double, velocity: Int = 100,
                     id: UUID = UUID()) -> SungExpressionPlanner.Note {
        SungExpressionPlanner.Note(noteID: id, startSeconds: start, endSeconds: end, velocity: velocity)
    }

    static let clipID = UUID()

    static func plan(_ notes: [SungExpressionPlanner.Note], _ style: SingStyle?,
                     _ detected: PitchEditSet) throws -> SungExpressionPlanner.Plan {
        try SungExpressionPlanner.plan(notes: notes, style: style, detected: detected, clipID: clipID)
    }

    // MARK: - Mapping

    @Test("a segment belongs to the note it overlaps most, needing at least half its length; a tie goes to the earlier note")
    func mappingByOverlap() {
        let notes = [Self.note(0, 1), Self.note(1, 2)]
        func owner(_ a: Double, _ b: Double) -> Int? {
            SungExpressionPlanner.owner(of: Self.segment(a, b), among: notes)
        }
        #expect(owner(0.2, 0.9) == 0)
        #expect(owner(0.8, 1.6) == 1, "0.2 s in the first note, 0.6 s in the second")
        #expect(owner(0.75, 1.25) == 0, "an exact tie goes to the earlier note")
        #expect(owner(1.8, 2.6) == nil, "0.2 of 0.8 s inside a note is less than half")
        #expect(owner(1.5, 2.5) == 1, "exactly half inside counts")
        #expect(owner(3, 4) == nil, "no overlap at all")
        // A note with a non-finite or inverted time never owns anything.
        let broken = [SungExpressionPlanner.Note(noteID: UUID(), startSeconds: .nan, endSeconds: 2, velocity: 100),
                      Self.note(1, 0.5)]
        #expect(SungExpressionPlanner.owner(of: Self.segment(0.6, 0.9), among: broken) == nil)
    }

    // MARK: - Presets

    @Test("the preset table: As sung none; Straight removes the wobble only; Gentle/Normal/Wide remove it and add 5.5 Hz at 25/45/70 c")
    func presetEdits() {
        let long = Self.segment(1.0, 2.0)
        #expect(SungExpressionPlanner.edit(for: .asSung, segment: long) == nil)
        #expect(SungExpressionPlanner.edit(for: .straight, segment: long) == NoteVibratoEdit(vibratoScale: 0),
                "Straight touches vibratoScale and nothing else: driftScale stays as sung")
        for (preset, depth) in [(SingStyle.Vibrato.gentle, 25.0), (.normal, 45.0), (.wide, 70.0)] {
            let edit = SungExpressionPlanner.edit(for: preset, segment: long)
            #expect(edit == NoteVibratoEdit(vibratoRateHz: 5.5, vibratoDepthCents: depth,
                                            vibratoOnsetSeconds: 0.25, vibratoPhaseAnchorSeconds: 1.5,
                                            vibratoScale: 0),
                    "\(preset): \(String(describing: edit))")
            #expect(edit?.driftScale == nil, "\(preset) must leave driftScale untouched")
        }
    }

    @Test("Gentle/Normal/Wide only on segments of at least 0.45 s; Straight on any length")
    func shortSegments() throws {
        #expect(SungExpressionPlanner.edit(for: .normal, segment: Self.segment(1, 1.44)) == nil)
        #expect(SungExpressionPlanner.edit(for: .normal, segment: Self.segment(1, 1.45)) != nil)
        #expect(SungExpressionPlanner.edit(for: .straight, segment: Self.segment(1, 1.1)) == NoteVibratoEdit(vibratoScale: 0))

        let short = Self.segment(0.1, 0.4)
        let long = Self.segment(0.5, 1.5)
        let result = try Self.plan([Self.note(0, 0.45), Self.note(0.45, 1.6)], SingStyle(vibrato: .wide),
                                   Self.table([short, long]))
        let table = try #require(result.table)
        #expect(table.segments[0] == short, "a 0.3 s segment of a Wide note is left exactly as sung")
        #expect(table.segments[1].vibratoDepthCents == 70)
        #expect(result.shortSegments == 1 && result.vibratoSegments == 1)
    }

    @Test("through plan: the table carries the preset through the one clamp, drift untouched, anchor at the centre")
    func planWritesThePreset() throws {
        let segment = Self.segment(0.30, 4.30)
        let result = try Self.plan([Self.note(0.30, 4.30)], SingStyle(vibrato: .normal), Self.table([segment]))
        let written = try #require(result.table?.segments.first)
        #expect(written.id == segment.id)
        #expect(written.vibratoScale == 0 && written.driftScale == 1)
        #expect(written.vibratoRateHz == 5.5 && written.vibratoDepthCents == 45)
        #expect(written.vibratoOnsetSeconds == 0.25)
        #expect(abs(written.vibratoPhaseAnchorSeconds - 2.30) < 1e-12, "anchored at the segment's centre")
        #expect(written.amplitudeDb == 0 && written.pitchOffsetCents == 0)

        let straight = try Self.plan([Self.note(0.30, 4.30)], SingStyle(vibrato: .straight), Self.table([segment]))
        let flat = try #require(straight.table?.segments.first)
        #expect(flat.vibratoScale == 0 && flat.driftScale == 1, "Straight keeps the slow drift (design §5.4)")
        #expect(flat.vibratoRateHz == 0 && flat.vibratoDepthCents == 0)
    }

    @Test("sounds and slides never get a vibrato edit, under any preset")
    func soundsAndSlidesUntouched() throws {
        let sound = Self.segment(0.0, 0.6, .unpitched)
        let slide = Self.segment(0.6, 1.2, .transition)
        let held = Self.segment(1.2, 2.4)
        let detected = Self.table([sound, slide, held])
        for preset in [SingStyle.Vibrato.straight, .gentle, .normal, .wide] {
            let result = try Self.plan([Self.note(0, 2.4)], SingStyle(vibrato: preset), detected)
            let table = try #require(result.table, "\(preset)")
            #expect(table.segments[0] == detected.segments[0], "\(preset) touched a sound")
            #expect(table.segments[1] == detected.segments[1], "\(preset) touched a slide")
            #expect(table.segments[2].vibratoScale == 0, "\(preset) missed the held note")
        }
        for origin in [NoteOrigin.unpitched, .transition] {
            #expect(SungExpressionPlanner.edit(for: .wide, segment: Self.segment(0, 2, origin)) == nil)
            #expect(SungExpressionPlanner.edit(for: .straight, segment: Self.segment(0, 2, origin)) == nil)
        }
    }

    @Test("a note's own As sung beats the clip's preset: its segments stay exactly as detected")
    func perNoteOverride() throws {
        let a = Self.note(0, 1.5), b = Self.note(1.5, 3)
        let sa = Self.segment(0.1, 1.4), sb = Self.segment(1.6, 2.9)
        let style = SingStyle(vibrato: .wide, notes: [b.noteID: NoteSingStyle(vibrato: .asSung)])
        let table = try #require(try Self.plan([a, b], style, Self.table([sa, sb])).table)
        #expect(table.segments[0].vibratoDepthCents == 70)
        #expect(table.segments[1] == sb)
    }

    // MARK: - nil is today

    @Test("every note as sung, no air, velocity not followed → NO table and no air (the default never seeds)")
    func asSungIsNil() throws {
        let a = Self.note(0, 1.5, velocity: 64)
        let detected = Self.table([Self.segment(0.1, 1.4), Self.segment(1.4, 1.5, .unpitched)])
        // W9-PICKS (round V): nil and `SingStyle()` are no longer as sung (they sing the default, Normal; see
        // `picksNilStylePlansNormal`), so this list names As sung.
        let styles: [SingStyle?] = [
            SingStyle(vibrato: .asSung), SingStyle(vibrato: .asSung, air: 0),
            SingStyle(vibrato: .asSung, notes: [a.noteID: NoteSingStyle(vibrato: .asSung, air: 0)]),
        ]
        for style in styles {
            let result = try Self.plan([a], style, detected)
            #expect(result.table == nil, "\(String(describing: style)) seeded a table")
            #expect(result.airSpans.isEmpty && result.isNoOp)
            #expect(SungExpressionPlanner.isNoOp(style: style))
        }
        // Following velocity on notes at 100 or louder changes no note either.
        let loud = try Self.plan([Self.note(0, 1.5, velocity: 127)], SingStyle(vibrato: .asSung, followVelocity: true),
                                 detected)
        #expect(loud.table == nil)
        #expect(!SungExpressionPlanner.isNoOp(style: SingStyle(followVelocity: true)))
        #expect(!SungExpressionPlanner.isNoOp(style: SingStyle(notes: [a.noteID: NoteSingStyle(air: 0.2)])))
        // An empty detected table changes nothing.
        #expect(try Self.plan([a], SingStyle(vibrato: .wide), Self.table([])).table == nil)
    }

    @Test("air alone makes air spans over the planned notes and no table")
    func airOnly() throws {
        let a = Self.note(0.5, 1.5), b = Self.note(1.5, 2.5), c = Self.note(2.5, 3.0)
        let style = SingStyle(air: SungAirLayer.airSome,
                              notes: [b.noteID: NoteSingStyle(air: 0), c.noteID: NoteSingStyle(air: SungAirLayer.airLots)])
        let result = try Self.plan([c, a, b], style, Self.table([Self.segment(0.5, 3.0)]))
        #expect(result.table == nil, "air is baked into the take, never a pitch-table edit")
        let expected: [(Double, Double, Double)] = [(0.5, 1.5, -18), (2.5, 3.0, -12)]
        #expect(result.airSpans.count == expected.count, "\(result.airSpans)")
        for (span, want) in zip(result.airSpans, expected) {
            #expect(span.startSeconds == want.0 && span.endSeconds == want.1)
            #expect(abs(span.levelDb - want.2) < 1e-9, "\(span)")
        }
    }

    // MARK: - Velocity

    @Test("the velocity curve: 100 and up 0 dB, 64 → −3.88 dB, 0 and 1 → −12 dB, never above 0")
    func velocityCurve() {
        #expect(SungExpressionPlanner.levelDb(velocity: 100) == 0)
        #expect(SungExpressionPlanner.levelDb(velocity: 127) == 0)
        #expect(abs(SungExpressionPlanner.levelDb(velocity: 64) - (-3.876)) < 0.001)
        #expect(abs(SungExpressionPlanner.levelDb(velocity: 50) - (-6.021)) < 0.001)
        #expect(SungExpressionPlanner.levelDb(velocity: 1) == -12)
        #expect(SungExpressionPlanner.levelDb(velocity: 0) == -12)
        #expect(SungExpressionPlanner.levelDb(velocity: -5) == -12)
        for velocity in -1...200 {
            let db = SungExpressionPlanner.levelDb(velocity: velocity)
            #expect(db <= 0 && db >= -12 && db.isFinite, "velocity \(velocity) → \(db)")
        }
    }

    @Test("follow velocity writes the level on every segment of a quiet note (sounds and slides too), none on a loud one")
    func velocityThroughPlan() throws {
        let quiet = Self.note(0, 1.5, velocity: 64), loud = Self.note(1.5, 3, velocity: 110)
        let detected = Self.table([Self.segment(0, 0.2, .unpitched), Self.segment(0.2, 1.4),
                                   Self.segment(1.6, 2.9)])
        // W9-PICKS: As sung named, so the level is the only edit (an unnamed vibrato is Normal now).
        let result = try Self.plan([quiet, loud], SingStyle(vibrato: .asSung, followVelocity: true), detected)
        let table = try #require(result.table)
        #expect(abs(table.segments[0].amplitudeDb - (-3.876)) < 0.001)
        #expect(abs(table.segments[1].amplitudeDb - (-3.876)) < 0.001)
        #expect(table.segments[2] == detected.segments[2])
        #expect(table.segments.allSatisfy { $0.amplitudeDb <= 0 })
        #expect(table.segments[1].vibratoScale == 1, "follow velocity alone adds no vibrato edit")
        // Off: the same velocities change nothing.
        #expect(try Self.plan([quiet, loud], SingStyle(vibrato: .asSung), detected).table == nil)
    }

    // MARK: - The x6 helper

    @Test("notes(planned:windows:velocities:) zips in order, defaults a missing velocity to 100, refuses a length mismatch")
    func notesHelper() {
        let ids = [UUID(), UUID()]
        let planned = ids.map { SingNote(noteID: $0, startSeconds: 0, endSeconds: 0.5, midi: 60, sourcePitch: 60) }
        let notes = SungExpressionPlanner.notes(planned: planned, windows: [(0.24, 0.74), (0.74, 1.5)],
                                                velocities: [ids[0]: 70])
        #expect(notes == [
            SungExpressionPlanner.Note(noteID: ids[0], startSeconds: 0.24, endSeconds: 0.74, velocity: 70),
            SungExpressionPlanner.Note(noteID: ids[1], startSeconds: 0.74, endSeconds: 1.5, velocity: 100),
        ])
        #expect(SungExpressionPlanner.notes(planned: planned, windows: [(0, 1)], velocities: [:]) == nil)
    }
}

// MARK: - W9-PICKS (p2-sing-x9-picks): round V, a style that names no vibrato sings Normal

extension SungExpressionPlannerTests {

    @Test("PICKS V: no style plans exactly what an explicit Normal plans; a named As sung still plans nothing")
    func picksNilStylePlansNormal() throws {
        let a = Self.note(0, 1.5)
        let detected = Self.table([Self.segment(0.1, 1.4), Self.segment(1.4, 1.5, .unpitched)])
        let normal = try Self.plan([a], SingStyle(vibrato: .normal), detected)
        let table = try #require(normal.table, "Normal on a 1.3 s segment lands a wobble")
        #expect(table.segments[0].vibratoDepthCents == 45 && table.segments[0].vibratoScale == 0)
        for style in [nil, SingStyle(), SingStyle(air: 0)] as [SingStyle?] {
            #expect(try Self.plan([a], style, detected) == normal, "\(String(describing: style))")
            #expect(!SungExpressionPlanner.isNoOp(style: style), "\(String(describing: style)) is not a no-op")
        }
        #expect(try Self.plan([a], SingStyle(vibrato: .asSung), detected).table == nil)
        #expect(SungExpressionPlanner.isNoOp(style: SingStyle(vibrato: .asSung)))
    }
}
