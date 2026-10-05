import Foundation
import Testing
@testable import DAWCore

// m23-ap C5a-2 — THE ONE WOBBLE CLAMP and THE BATCH TRANSFORM, tested PURE
// (no store, no main actor). The store legs (one undo step, the read-back
// against an independent clamp, reset, split) are appended to
// `PitchCorrectionWriterTests`, because the @MainActor suite cadence is full.
//
// Design: `docs/design/2026-09-24-pitch-editor-vibrato-handle.md` §10 (T9's
// clamp half) and `docs/design/2026-09-25-natural-tuning.md` §3b (the batch).
//
// ⚠️ THE EXPECTED NUMBERS ARE THE DESIGN'S, WRITTEN AS LITERALS (8, 6.4, 200,
// 86 400), never recomputed from the ranges the code reads. A test that
// derived its expectation from `NoteSegment.vibratoRateHzRange` would agree
// with any range the code happened to hold.
@Suite("NoteVibratoLimits — the one wobble clamp and the batch transform (C5a-2)")
struct NoteVibratoLimitsTests {

    private func refusal(_ body: () throws -> Void) -> String {
        do { try body(); return "ACCEPTED" } catch { return error.localizedDescription }
    }

    // MARK: - clamp

    @Test("in-range values are kept verbatim, nil stays nil, and nothing is reported as bound")
    func inRangeIsVerbatim() throws {
        let edit = NoteVibratoEdit(vibratoRateHz: 5.5, vibratoDepthCents: 40,
                                   vibratoOnsetSeconds: 0.25, vibratoPhaseAnchorSeconds: 12.3,
                                   vibratoScale: 0.5, driftScale: 1.5)
        let clamp = try NoteVibratoLimits.clamp(edit, stretchRatio: 1)
        #expect(clamp.edit == edit)
        #expect(clamp.bound.isEmpty)
        // nil fields stay nil: a partial edit never grows fields the caller left out.
        let partial = try NoteVibratoLimits.clamp(NoteVibratoEdit(vibratoDepthCents: 50),
                                                  stretchRatio: 1)
        #expect(partial.edit == NoteVibratoEdit(vibratoDepthCents: 50))
        // Total: an empty edit clamps to an empty edit (the SETTERS refuse it, not the clamp).
        let empty = try NoteVibratoLimits.clamp(NoteVibratoEdit(), stretchRatio: 1)
        #expect(empty.edit.isEmpty && empty.bound.isEmpty)
    }

    @Test("T9, the clamp half: each out-of-range input stores the design's number and names ONE limit")
    func clampsAndSaysSo() throws {
        func run(_ edit: NoteVibratoEdit, ratio: Double = 1) throws -> NoteVibratoClamp {
            try NoteVibratoLimits.clamp(edit, stretchRatio: ratio)
        }
        // rate 12 at ratio 1 → 8, the model's measured ceiling.
        var c = try run(NoteVibratoEdit(vibratoRateHz: 12))
        #expect(c.edit.vibratoRateHz == 8 && c.bound == [.rateRange])
        // rate 7 at ratio 0.8 → 6.4: heard at 6.4 / 0.8 = 8 per second (design §10 item 4).
        c = try run(NoteVibratoEdit(vibratoRateHz: 7), ratio: 0.8)
        #expect(abs(try #require(c.edit.vibratoRateHz) - 6.4) < 1e-12)
        #expect(c.bound == [.heardRateCeiling])
        // rate 12 at ratio 0.8 exceeds BOTH, and reports only the one that decided 6.4.
        c = try run(NoteVibratoEdit(vibratoRateHz: 12), ratio: 0.8)
        #expect(abs(try #require(c.edit.vibratoRateHz) - 6.4) < 1e-12)
        #expect(c.bound == [.heardRateCeiling])
        // A slowed clip (1.25) cannot scale the model's range up: 9 → 8, heard 6.4 (failure mode 8).
        c = try run(NoteVibratoEdit(vibratoRateHz: 9), ratio: 1.25)
        #expect(c.edit.vibratoRateHz == 8 && c.bound == [.rateRange])
        // At ratio 2 a stored 8 is heard at 4: nothing binds.
        c = try run(NoteVibratoEdit(vibratoRateHz: 8), ratio: 2)
        #expect(c.edit.vibratoRateHz == 8 && c.bound.isEmpty)
        // A negative rate floors at 0.
        c = try run(NoteVibratoEdit(vibratoRateHz: -1))
        #expect(c.edit.vibratoRateHz == 0 && c.bound == [.rateRange])
        // depth 500 → 200; keep −1 → 0; drift 7 → 4; onset 9 → 5.
        c = try run(NoteVibratoEdit(vibratoDepthCents: 500, vibratoOnsetSeconds: 9,
                                    vibratoScale: -1, driftScale: 7))
        #expect(c.edit == NoteVibratoEdit(vibratoDepthCents: 200, vibratoOnsetSeconds: 5,
                                          vibratoScale: 0, driftScale: 4))
        #expect(c.bound == [.depthRange, .onsetRange, .scaleRange, .driftRange])
        // C5a-1's hand-off: the MODEL clamps the anchor silently; the clamp REPORTS it.
        c = try run(NoteVibratoEdit(vibratoPhaseAnchorSeconds: 1e9))
        #expect(c.edit.vibratoPhaseAnchorSeconds == 86_400 && c.bound == [.anchorRange])
        c = try run(NoteVibratoEdit(vibratoPhaseAnchorSeconds: -5))
        #expect(c.edit.vibratoPhaseAnchorSeconds == -1 && c.bound == [.anchorRange])
        // Field order in `bound`, with every field binding at once.
        c = try run(NoteVibratoEdit(vibratoRateHz: 99, vibratoDepthCents: 999,
                                    vibratoOnsetSeconds: 99, vibratoPhaseAnchorSeconds: 1e12,
                                    vibratoScale: 99, driftScale: 99), ratio: 1)
        #expect(c.bound == [.rateRange, .depthRange, .onsetRange, .anchorRange,
                            .scaleRange, .driftRange])
    }

    @Test("a NaN or an infinity is REFUSED in words naming the field, never healed")
    func nonFiniteIsRefusedByName() {
        let keys = ["vibratoRateHz", "vibratoDepthCents", "vibratoOnsetSeconds",
                    "vibratoPhaseAnchorSeconds", "vibratoScale", "driftScale"]
        for bad in [Double.nan, .infinity, -.infinity] {
            for (i, key) in keys.enumerated() {
                // Every OTHER field is valid, so only the named one can be the reason.
                var values: [Double?] = [5, 40, 0.1, 1, 0.5, 0.5]
                values[i] = bad
                let edit = NoteVibratoEdit(vibratoRateHz: values[0], vibratoDepthCents: values[1],
                                           vibratoOnsetSeconds: values[2],
                                           vibratoPhaseAnchorSeconds: values[3],
                                           vibratoScale: values[4], driftScale: values[5])
                let message = refusal { _ = try NoteVibratoLimits.clamp(edit, stretchRatio: 1) }
                #expect(message.hasPrefix(key + " has to be a number"), "\(key) \(bad): \(message)")
                #expect(message.contains("Nothing was changed"), "\(message)")
            }
        }
        // The exact words C5a-3 copies to the wire, pinned once.
        #expect(refusal {
            _ = try NoteVibratoLimits.clamp(NoteVibratoEdit(vibratoRateHz: .nan), stretchRatio: 1)
        } == "vibratoRateHz has to be a number from 0 to 8; nan is not one. Nothing was changed.")
        #expect(refusal {
            _ = try NoteVibratoLimits.clamp(NoteVibratoEdit(vibratoPhaseAnchorSeconds: .infinity),
                                            stretchRatio: 1)
        } == "vibratoPhaseAnchorSeconds has to be a number from -1 to 86400; inf is not one. "
            + "Nothing was changed.")
    }

    @Test("−0.0 is stored as +0.0, so a default-valued edit writes the model's exact defaults")
    func negativeZeroIsPositiveZero() throws {
        let clamp = try NoteVibratoLimits.clamp(
            NoteVibratoEdit(vibratoRateHz: -0.0, vibratoDepthCents: -0.0, vibratoOnsetSeconds: -0.0,
                            vibratoPhaseAnchorSeconds: -0.0),
            stretchRatio: 1)
        for value in [clamp.edit.vibratoRateHz, clamp.edit.vibratoDepthCents,
                      clamp.edit.vibratoOnsetSeconds, clamp.edit.vibratoPhaseAnchorSeconds] {
            let v = try #require(value)
            #expect(v == 0 && v.sign == .plus, "a -0.0 reached the stored note")
        }
        #expect(clamp.bound.isEmpty, "-0.0 is not out of range; nothing bound")
    }

    @Test("the heard ceiling is the model's 8 in OUTPUT time: stored ceiling = min(8, 8 × ratio)")
    func storedCeilingFollowsTheRatio() {
        #expect(NoteVibratoLimits.heardRateCeilingHz == 8)
        #expect(NoteVibratoLimits.storedRateCeiling(stretchRatio: 1) == 8)
        #expect(NoteVibratoLimits.storedRateCeiling(stretchRatio: 0.5) == 4)
        #expect(NoteVibratoLimits.storedRateCeiling(stretchRatio: 2) == 8)
        // A ratio no Clip can hold reads as the nearest one it could (0.25...4), and NaN as 1.
        #expect(NoteVibratoLimits.storedRateCeiling(stretchRatio: 0) == 2)
        #expect(NoteVibratoLimits.storedRateCeiling(stretchRatio: .nan) == 8)
    }

    @Test("applied(to:) writes exactly the supplied fields and nothing else")
    func appliedWritesOnlyTheSuppliedFields() throws {
        var note = NoteSegment(startSeconds: 1, endSeconds: 2, detectedHz: 220,
                               detectedConfidence: 0.9, pitchOffsetCents: -30,
                               vibratoScale: 0.7, vibratoRateHz: 3)
        note.amplitudeDb = -4
        let clamp = try NoteVibratoLimits.clamp(NoteVibratoEdit(vibratoDepthCents: 35, driftScale: 0),
                                                stretchRatio: 1)
        let out = clamp.applied(to: note)
        var expected = note
        expected.vibratoDepthCents = 35
        expected.driftScale = 0
        #expect(out == expected)
        #expect(out.vibratoScale == 0.7 && out.vibratoRateHz == 3 && out.pitchOffsetCents == -30)
    }

    @Test("asSung is the six model defaults; isDriftOnly is driftScale alone")
    func asSungAndDriftOnly() {
        let fresh = NoteSegment(startSeconds: 0, endSeconds: 1, detectedHz: 220, detectedConfidence: 1)
        #expect(NoteVibratoEdit.asSung == NoteVibratoEdit(storedIn: fresh))
        #expect(NoteVibratoEdit(driftScale: 0.3).isDriftOnly)
        #expect(!NoteVibratoEdit(vibratoScale: 0.3, driftScale: 0.3).isDriftOnly)
        #expect(!NoteVibratoEdit().isDriftOnly)
        #expect(NoteVibratoEdit().isEmpty && !NoteVibratoEdit(vibratoOnsetSeconds: 0).isEmpty)
    }

    // MARK: - applyingNoteVibratos (the batch rule's one home)

    /// Three notes and one sound between them, no edits.
    private func table() -> PitchEditSet {
        PitchEditSet(segments: [
            NoteSegment(startSeconds: 0.0, endSeconds: 0.5, detectedHz: 220, detectedConfidence: 0.9),
            NoteSegment(startSeconds: 0.5, endSeconds: 1.0, detectedHz: 247, detectedConfidence: 0.9),
            NoteSegment(startSeconds: 1.0, endSeconds: 1.2, detectedHz: 247, detectedConfidence: 0.3,
                        origin: .unpitched),
            NoteSegment(startSeconds: 1.2, endSeconds: 2.0, detectedHz: 262, detectedConfidence: 0.9),
        ])
    }

    @Test("batch: each note clamped PER NOTE, sounds skipped AND reported, nothing else moves")
    func batchClampsPerNoteAndSkipsSounds() throws {
        let set = table()
        let ids = set.segments.map(\.id)
        let clip = UUID()
        let items = [NoteVibratoItem(segmentId: ids[0], edit: NoteVibratoEdit(driftScale: 0.3)),
                     NoteVibratoItem(segmentId: ids[2], edit: NoteVibratoEdit(driftScale: 0.3)),
                     NoteVibratoItem(segmentId: ids[3], edit: NoteVibratoEdit(driftScale: 9))]
        let result = try set.applyingNoteVibratos(items, stretchRatio: 1, clipId: clip)
        #expect(result.set.segments[0].driftScale == 0.3)
        #expect(result.set.segments[3].driftScale == 4, "clamped per note")
        #expect(result.notes.map(\.segmentId) == [ids[0], ids[3]])
        #expect(result.notes.map(\.bound) == [[], [.driftRange]])
        // ⭐ THE SKIP IS SAID, NEVER SILENT.
        #expect(result.skippedSoundIds == [ids[2]])
        #expect(result.skippedSoundsSentence == "Left 1 sound alone: it is a breath or a consonant "
                + "with no pitch, so there is no wobble to change.")
        // INVARIANCE CONTROL: the sound and the unnamed note are byte-for-byte what they were.
        #expect(result.set.segments[2] == set.segments[2])
        #expect(result.set.segments[1] == set.segments[1])
        // A batch with no sound reports none.
        let clean = try set.applyingNoteVibratos(Array(items.prefix(1)), stretchRatio: 1, clipId: clip)
        #expect(clean.skippedSoundIds.isEmpty && clean.skippedSoundsSentence == nil)
    }

    @Test("batch: every refusal is in words and returns no set — empty list, empty item, NaN, unknown id, two edits for one note, only sounds")
    func batchRefusals() throws {
        let set = table()
        let ids = set.segments.map(\.id)
        let clip = UUID()
        func run(_ items: [NoteVibratoItem]) -> String {
            refusal { _ = try set.applyingNoteVibratos(items, stretchRatio: 1, clipId: clip) }
        }
        #expect(run([]) == "Name at least one note to change the wobble of. Read the clip's note "
                + "ids with `clip.getPitchEdits` first.")
        // One item: the sentence alone (design §10 item 1, verbatim).
        #expect(run([NoteVibratoItem(segmentId: ids[0], edit: NoteVibratoEdit())])
                == "Nothing to change: give at least one wobble setting.")
        // Several items: the same sentence, prefixed with the note it is about.
        #expect(run([NoteVibratoItem(segmentId: ids[0], edit: NoteVibratoEdit(vibratoScale: 0)),
                     NoteVibratoItem(segmentId: ids[1], edit: NoteVibratoEdit())])
                == "Note \(ids[1]): Nothing to change: give at least one wobble setting.")
        #expect(run([NoteVibratoItem(segmentId: ids[0], edit: NoteVibratoEdit(vibratoScale: 0)),
                     NoteVibratoItem(segmentId: ids[1], edit: NoteVibratoEdit(vibratoRateHz: .nan))])
                .hasPrefix("Note \(ids[1]): vibratoRateHz has to be a number"))
        // An unknown id among good ones names the count.
        let unknown = UUID()
        #expect(run([NoteVibratoItem(segmentId: ids[0], edit: NoteVibratoEdit(vibratoScale: 0)),
                     NoteVibratoItem(segmentId: unknown, edit: NoteVibratoEdit(vibratoScale: 0))])
                == "No note with id \(unknown) on clip \(clip). That clip carries 4 note(s); read "
                + "them back with `clip.getPitchEdits` before editing one.")
        // One id, two different edits: refused. The same edit twice (after clamping): folded.
        #expect(run([NoteVibratoItem(segmentId: ids[0], edit: NoteVibratoEdit(vibratoScale: 0)),
                     NoteVibratoItem(segmentId: ids[0], edit: NoteVibratoEdit(vibratoScale: 1))])
                == "Note \(ids[0]) is named twice with two different wobble settings. Name each "
                + "note once.")
        let folded = try set.applyingNoteVibratos(
            [NoteVibratoItem(segmentId: ids[0], edit: NoteVibratoEdit(vibratoScale: 9)),
             NoteVibratoItem(segmentId: ids[0], edit: NoteVibratoEdit(vibratoScale: 4))],
            stretchRatio: 1, clipId: clip)
        #expect(folded.notes.count == 1 && folded.set.segments[0].vibratoScale == 4)
        // Only sounds: a call that would change nothing is refused. Alone, §1.7 verbatim.
        #expect(run([NoteVibratoItem(segmentId: ids[2], edit: NoteVibratoEdit(vibratoScale: 0))])
                == "No pitch here, so there is no wobble to change.")
        // POSITIVE CONTROL for the skip rule: the same sound beside a sung note is skipped, not refused.
        #expect(run([NoteVibratoItem(segmentId: ids[2], edit: NoteVibratoEdit(vibratoScale: 0)),
                     NoteVibratoItem(segmentId: ids[3], edit: NoteVibratoEdit(vibratoScale: 0))])
                == "ACCEPTED")
    }

    @Test("a default-valued edit on an untouched table is the SAME table: equal, byte-identical, same stamp")
    func defaultValuedEditIsByteIdentical() throws {
        let set = table().stampedAsAutoCorrectOutput()
        let items = set.segments.filter { $0.origin != .unpitched }
            .map { NoteVibratoItem(segmentId: $0.id, edit: .asSung) }
        let result = try set.applyingNoteVibratos(items, stretchRatio: 1.25, clipId: UUID())
        #expect(result.set == set)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(result.set) == encoder.encode(set), "a default-valued edit moved a byte")
        #expect(result.set.contentStamp == set.contentStamp)
        #expect(!result.set.hasHandEditsSinceAutoCorrect, "a no-op edit made a preset's output look hand-edited")
        #expect(result.set.isPitchIdentity)
        // POSITIVE CONTROL: the probe CAN see a change — one real field moves the bytes and the stamp.
        let moved = try set.applyingNoteVibratos(
            [NoteVibratoItem(segmentId: items[0].segmentId, edit: NoteVibratoEdit(vibratoRateHz: 5))],
            stretchRatio: 1, clipId: UUID())
        #expect(try encoder.encode(moved.set) != encoder.encode(set))
        #expect(moved.set.contentStamp != set.contentStamp)
    }

    @Test("the report says heard rate, a silent wobble and a parked rate out loud")
    func reportFlags() throws {
        let set = table()
        let id = set.segments[0].id
        let silent = try set.applyingNoteVibratos(
            [NoteVibratoItem(segmentId: id, edit: NoteVibratoEdit(vibratoDepthCents: 40))],
            stretchRatio: 1, clipId: UUID())
        #expect(silent.notes[0].silentWobble && !silent.notes[0].parkedRate)
        let parked = try set.applyingNoteVibratos(
            [NoteVibratoItem(segmentId: id, edit: NoteVibratoEdit(vibratoRateHz: 7.75))],
            stretchRatio: 1.25, clipId: UUID())
        #expect(parked.notes[0].parkedRate && !parked.notes[0].silentWobble)
        // Heard = stored ÷ ratio: 7.75 at 1.25 is heard at 6.2 (design T3's fixture).
        #expect(abs(parked.notes[0].heardRateHz - 6.2) < 1e-12)
        let both = try set.applyingNoteVibratos(
            [NoteVibratoItem(segmentId: id, edit: NoteVibratoEdit(vibratoRateHz: 5.5,
                                                                  vibratoDepthCents: 40))],
            stretchRatio: 1, clipId: UUID())
        #expect(!both.notes[0].silentWobble && !both.notes[0].parkedRate)
    }
}
