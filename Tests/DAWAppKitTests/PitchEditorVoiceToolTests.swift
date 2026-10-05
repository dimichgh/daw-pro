import AppKit
import CoreGraphics
import DAWCore
import Foundation
import Testing
@testable import DAWAppKit

/// W7-NTU U3 — the Voice tool's HEADLESS half (natural tuning
/// `docs/design/2026-09-25-natural-tuning.md` §1(f) items 2-3, R9, R11, R22,
/// R26): its arithmetic (`PitchEditorVoiceTool`, `PitchEditorVoiceDraft`), its
/// words (`PitchEditorFormantCopy`), its note-menu row (`PitchEditorNoteMenu`),
/// what its release plays (`PitchEditorAuditionRouter.releaseAudition`) and
/// its store read-back (`PitchEditorVoiceWrite.took`).
///
/// ⭐ EVERY EXPECTED VALUE IS A LITERAL, never the rule run a second time.
///
/// ⚠️ NOT `@MainActor`: all of it is pure. The pane half (the press, the one
/// commit, the store round trip) is `PitchEditorModelTests`' "W7-NTU U3"
/// block, in a suite that is already isolated.
@Suite("PitchEditorVoiceTool — the Voice tool's numbers, words, menu row and read-back (W7-NTU U3)")
struct PitchEditorVoiceToolTests {
    typealias T = PitchEditorVoiceTool
    typealias C = PitchEditorFormantCopy

    // MARK: - The numbers

    @Test("R9's reach: ±6 in the UI (the wire keeps ±24), 10 steps a semitone, 12 pt a semitone, ⌥ divides by 4, the menu sets 2")
    func thePicks() {
        #expect(T.uiRange == -6...6)
        #expect(NoteSegment.formantOffsetSemitonesRange == -24...24)
        #expect(T.stepsPerSemitone == 10)
        #expect(T.pointsPerSemitone == 12)
        #expect(T.fineDivisor == 4)
        #expect(T.menuSemitones == 2)
    }

    /// Planted and seen red (W7-NTU P-v-grid): `value` multiplying by 0.1
    /// instead of dividing by 10.
    @Test("a value is whole steps DIVIDED by 10: 21 steps is exactly 2.1, and every step from -60 to 60 is its own literal")
    func valuesAreCanonical() {
        #expect(T.value(baseline: 0, steps: 21) == 2.1)
        #expect(T.value(baseline: 0, steps: -7) == -0.7)
        #expect(T.value(baseline: 0, steps: 3) == 0.3)
        for steps in -60...60 {
            let literal = Double(steps) / 10
            #expect(T.value(baseline: 0, steps: steps) == literal, "\(steps) steps")
        }
    }

    @Test("zero steps is the baseline ITSELF (a wire value off the grid stays as stored); a step lands on the grid from the rounded baseline")
    func offGridBaseline() {
        #expect(T.value(baseline: 1.234, steps: 0) == 1.234)
        #expect(T.value(baseline: 1.234, steps: 1) == 1.3)
        #expect(T.value(baseline: 1.234, steps: -1) == 1.1)
    }

    @Test("the reach: ±6, widened to take in a baseline beyond it, never pulled back into range by a press")
    func reachAndClamp() {
        #expect(T.reach(from: 0) == -6...6)
        #expect(T.reach(from: -10) == -10...6)
        #expect(T.reach(from: 9) == -6...9)
        #expect(T.value(baseline: 0, steps: 61) == 6)
        #expect(T.value(baseline: 0, steps: -75) == -6)
        #expect(T.value(baseline: -10, steps: -1) == -10)
        #expect(T.value(baseline: -10, steps: 1) == -9.9)
    }

    @Test("travel: 12 pt is one semitone, to the nearest step; the banked travel stops at each end of the reach")
    func travel() {
        #expect(T.steps(forPointsUp: 12) == 10)
        #expect(T.steps(forPointsUp: -1.2) == -1)
        #expect(T.steps(forPointsUp: 0.5) == 0)
        #expect(T.steps(forPointsUp: 0.6) == 1)
        #expect(T.travelBounds(from: 0) == -72...72)
        #expect(T.travelBounds(from: 6) == -144...0)
        #expect(T.travelBounds(from: -10) == 0...192)
    }

    @Test("R11: a note shorter than the MEASURED 80 ms is too short to change alone; 80 ms is not")
    func tooShort() {
        #expect(PitchEditSet.minimumVoiceNoteSeconds == 0.08)
        let short = NoteSegment(startSeconds: 0, endSeconds: 0.079, detectedHz: 220, detectedConfidence: 0.9)
        let enough = NoteSegment(startSeconds: 0, endSeconds: 0.08, detectedHz: 220, detectedConfidence: 0.9)
        #expect(T.isTooShort(short))
        #expect(!T.isTooShort(enough))
    }

    @Test("the bar's place: the value over 6, clamped to the blob's edges; an agent's -10 sits at the bottom edge")
    func offsetFraction() {
        #expect(T.offsetFraction(3) == 0.5)
        #expect(T.offsetFraction(-6) == -1)
        #expect(T.offsetFraction(-10) == -1)
        #expect(T.offsetFraction(12) == 1)
        #expect(T.offsetFraction(0) == 0)
        #expect(T.offsetFraction(.nan) == 0)
    }

    // MARK: - The draft

    /// Planted and seen red (W7-NTU P-v-fine): the ⌥ part not divided.
    @Test("a drag: up is brighter, down is deeper, 12 pt a semitone; ⌥ banks a quarter of THIS tick's travel, so letting go of it never jumps")
    func draftUpdates() {
        // A mutating call is never made inside `#expect` (the macro hands its
        // receiver in as a constant): each answer is taken first.
        var draft = PitchEditorVoiceDraft(segmentID: UUID(), baseline: 0, isTooShort: false)
        #expect(draft.semitones == 0 && !draft.isDragging)
        let first = draft.update(translationHeight: -12, fine: false)
        #expect(first && draft.semitones == 1 && draft.isDragging)
        let second = draft.update(translationHeight: -24, fine: false)
        #expect(second && draft.semitones == 2)
        // 12 pt more with ⌥: 3 pt banked, 27 in all: 22.5 steps, rounded to 23.
        let fine = draft.update(translationHeight: -36, fine: true)
        #expect(fine && draft.semitones == 2.3 && draft.fine)
        // ⌥ let go without moving: nothing moves.
        let still = draft.update(translationHeight: -36, fine: false)
        #expect(!still && draft.semitones == 2.3)

        var down = PitchEditorVoiceDraft(segmentID: UUID(), baseline: 0, isTooShort: false)
        down.update(translationHeight: 24, fine: false)
        #expect(down.semitones == -2)
    }

    /// Planted and seen red (W7-NTU P-v-bank): the banked travel not clamped.
    @Test("a knob stops at its end: past +6 and back 12 pt is 5.0 at once, never after 900 pt of dead travel")
    func noDeadTravel() {
        var draft = PitchEditorVoiceDraft(segmentID: UUID(), baseline: 0, isTooShort: false)
        draft.update(translationHeight: -1000, fine: false)
        #expect(draft.semitones == 6)
        #expect(draft.bankedPoints == 72)
        draft.update(translationHeight: -988, fine: false)
        #expect(draft.semitones == 5)
    }

    @Test("what the release writes: nothing for a click or a drag back to the stored value; the value otherwise")
    func commitValue() {
        var draft = PitchEditorVoiceDraft(segmentID: UUID(), baseline: -1.5, isTooShort: false)
        #expect(draft.commitValue == nil, "a press that never became a drag wrote something")
        draft.update(translationHeight: -12, fine: false)
        #expect(draft.commitValue == -0.5)
        draft.update(translationHeight: 0, fine: false)
        #expect(draft.semitones == -1.5)
        #expect(draft.commitValue == nil, "a drag back to where it began wrote an undo step that undoes nothing")
    }

    @Test("a mark: the chip's words and the bar's place come from the value, verbatim")
    func mark() {
        let rect = CGRect(x: 10, y: 20, width: 40, height: 12)
        let mark = PitchEditorVoiceMark(segmentID: UUID(), semitones: -3, blobRect: rect, isLive: true)
        #expect(mark.chip == "Deeper 3.0")
        #expect(mark.offsetFraction == -0.5)
        #expect(mark.blobRect == rect && mark.isLive)
    }

    // MARK: - The words (one home: PitchEditorFormantCopy)

    @Test("every Voice word, by value: the slot, the help, the readout, the chip, the menu row, R11's line, the sound's refusal")
    func wordsByValue() {
        #expect(C.voiceToolLabel == "Voice")
        #expect(C.voiceToolDirections
                == "Drag a note up or down to make that part of the voice brighter or deeper, without changing the note.")
        #expect(C.voiceToolKeys == "Hold ⌥ for finer steps. Double-click a note to put it back as sung.")
        #expect(C.voiceToolHelp(drawToolAvailable: true)
                == "Drag a note up or down to make that part of the voice brighter or deeper, without changing "
                + "the note. Hold ⌥ for finer steps. Double-click a note to put it back as sung. Hold ⌘ to "
                + "draw instead. Let go to hear it.")
        #expect(!C.voiceToolHelp(drawToolAvailable: false).contains("⌘"))
        #expect(C.voiceTooShort == "Too short to change the voice of this note alone")
        #expect(C.voiceSoundRefusal
                == "This is a breath or a consonant, so it has no voice to make deeper or brighter.")
        #expect(C.voiceChip(-2) == "Deeper 2.0")
        #expect(C.voiceChip(1.5) == "Brighter 1.5")
        #expect(C.voiceChip(0) == "")
        // The level's house rule: a non-zero value always reads.
        #expect(C.voiceChip(0.04) == "Brighter 0.0")
        #expect(C.voiceToolReadout(0) == "Voice: as sung")
        #expect(C.voiceToolReadout(-2) == "Voice: deeper 2.0")
        #expect(C.voiceToolReadout(1.5) == "Voice: brighter 1.5")
        #expect(C.voiceMenuTitle(-2) == "Voice: Deeper 2.0")
        #expect(C.voiceMenuTitle(2) == "Voice: Brighter 2.0")
        #expect(C.voiceMenuTitle(0) == "Voice: As sung")
    }

    /// Every string the Voice tool draws, in one list, so the word rules below
    /// cannot miss one.
    static var everyVoiceString: [String] {
        var strings = [C.voiceToolLabel, C.voiceToolDirections, C.voiceToolKeys,
                       C.voiceToolHelp(drawToolAvailable: true), C.voiceToolHelp(drawToolAvailable: false),
                       C.voiceTooShort, C.voiceSoundRefusal, C.farMoveHint]
        for value in [-24.0, -6, -2, -0.1, 0, 0.1, 2, 6, 24] {
            strings += [C.voiceChip(value), C.voiceToolReadout(value), C.voiceMenuTitle(value)]
        }
        return strings.filter { !$0.isEmpty }
    }

    @Test("⛔ the Voice words: no jargon (formant, semitone, cents, vibrato, pitch shift), no \"natural\" (X9), no minus sign or unit on a number")
    func voiceWordRules() {
        #expect(Self.everyVoiceString.count > 20, "the list is empty: the rules below would pass on nothing")
        for string in Self.everyVoiceString {
            let lower = string.lowercased()
            for jargon in ["formant", "semitone", "cents", "vibrato", "pitch shift", "natural"] {
                #expect(!lower.contains(jargon), "\"\(string)\" says \(jargon)")
            }
            let signed = string.range(of: #"[-−+]\s*[0-9]"#, options: .regularExpression) != nil
            #expect(!signed, "\"\(string)\" signs a number: the words say deeper or brighter")
            let unit = string.range(of: #"[0-9]\s*(st|semi)"#, options: .regularExpression) != nil
            #expect(!unit, "\"\(string)\" puts a unit on the number")
        }
        // CONTROL — the two patterns can say NO.
        #expect("Voice: -2.0".range(of: #"[-−+]\s*[0-9]"#, options: .regularExpression) != nil)
        #expect("2.0 st".range(of: #"[0-9]\s*(st|semi)"#, options: .regularExpression) != nil)
    }

    @Test("the palette slot: Voice, the mouth glyph, and its help is the one from the copy")
    func theSlot() {
        #expect(PitchEditorTool.voice.rawValue == "voice")
        #expect(PitchEditorTool.voice.label == "Voice")
        #expect(PitchEditorTool.voice.symbolName == "mouth")
        #expect(PitchEditorTool.voice.help == C.voiceToolHelp(drawToolAvailable: true))
        #expect(PitchEditorGestureRouter.commandDraws(in: .voice))
    }

    // MARK: - The note menu's Voice row (§1(f) item 3)

    private func menu(_ targets: [PitchEditorNoteMenu.Target], voiceTool: Bool) -> [String] {
        PitchEditorNoteMenu.items(for: targets, voiceTool: voiceTool)
            .map { "\($0.title)\($0.isEnabled ? "" : " (disabled)")" }
    }

    private func note(_ voice: Double = 0) -> PitchEditorNoteMenu.Target {
        PitchEditorNoteMenu.Target(kind: .note, isCleared: false, voiceSemitones: voice)
    }

    /// Planted and seen red (W7-NTU P-v-menu): the row offered for sounds.
    @Test("the Voice row: Deeper and Brighter in the Voice tool, greyed at their own value; As sung in every tool, only when a note has a Voice; never for sounds")
    func voiceRow() {
        #expect(menu([note()], voiceTool: true) == ["Clear Note", "Voice: Deeper 2.0", "Voice: Brighter 2.0"])
        // Another tool: the menu is exactly what it was before U3.
        #expect(menu([note()], voiceTool: false) == ["Clear Note"])
        #expect(menu([note(-2)], voiceTool: true)
                == ["Clear Note", "Voice: Deeper 2.0 (disabled)", "Voice: Brighter 2.0", "Voice: As sung"])
        #expect(menu([note(-2)], voiceTool: false) == ["Clear Note", "Voice: As sung"])
        // Two notes, one already deeper: Deeper still changes the other.
        #expect(menu([note(-2), note()], voiceTool: true)
                == ["Clear 2 Notes", "Voice: Deeper 2.0", "Voice: Brighter 2.0", "Voice: As sung"])
        // Sounds only: no Voice row at all, whatever they carry.
        let sound = PitchEditorNoteMenu.Target(kind: .sound, isCleared: false, voiceSemitones: -3)
        #expect(menu([sound], voiceTool: true) == ["Clear Sound"])
        // A mix: the row counts the note only.
        #expect(menu([note(), sound], voiceTool: true)
                == ["Clear 2 Selected", "Voice: Deeper 2.0", "Voice: Brighter 2.0"])
        // Nothing to act on: no Voice row either.
        #expect(menu([], voiceTool: true) == ["Clear Notes (disabled)"])
    }

    @Test("each Voice row SETS one absolute value; no other row sets one")
    func voiceValues() {
        #expect(PitchEditorNoteMenu.voiceValue(of: .voiceDeeper) == -2)
        #expect(PitchEditorNoteMenu.voiceValue(of: .voiceBrighter) == 2)
        #expect(PitchEditorNoteMenu.voiceValue(of: .voiceAsSung) == 0)
        for action in [PitchEditorNoteMenu.Action.clear, .restore, .resetWobble, .resetShape] {
            #expect(PitchEditorNoteMenu.voiceValue(of: action) == nil)
        }
        #expect(PitchEditorNoteMenu.Action.voiceDeeper.rawValue == "voiceDeeper")
        #expect(PitchEditorNoteMenu.Action.voiceBrighter.rawValue == "voiceBrighter")
        #expect(PitchEditorNoteMenu.Action.voiceAsSung.rawValue == "voiceAsSung")
    }

    // MARK: - What the release plays

    @Test("a Voice commit is HEARD: its notes, with the pitch edit's context (the tool's own \"Let go to hear it\")")
    func voiceCommitIsHeard() {
        let a = UUID()
        let b = UUID()
        #expect(PitchEditorAuditionRouter.releaseAudition(for: .noteFormant(segmentIDs: [a, b], semitones: 2))
                == PitchEditorReleaseAudition(edit: .pitch, segmentIDs: [a, b]))
        #expect(PitchEditorAuditionRouter.releaseAudition(for: .noteFormant(segmentIDs: [a], semitones: 0))
                == PitchEditorReleaseAudition(edit: .pitch, segmentIDs: [a]))
    }

    // MARK: - The read-back (`PitchEditorVoiceWrite.took`)

    /// A vocal tuned BEFORE natural tuning (no voice size, no slide
    /// smoothness) whose consonants somebody switched OFF on purpose, the one
    /// state NT-C2-F1 keeps through the update.
    private static func legacyChosenOff() -> PitchEditSet {
        var set = PitchEditSet(segments: [
            NoteSegment(startSeconds: 0, endSeconds: 0.5, detectedHz: 220, detectedConfidence: 0.95,
                        pitchOffsetCents: -30),
            NoteSegment(startSeconds: 0.5, endSeconds: 1, detectedHz: 247, detectedConfidence: 0.95),
        ])
        set.consonantProtection = .offByChoice
        return set
    }

    @Test("the fixture is what it claims: an old vocal, consonants OFF by choice, and the update keeps that choice")
    func fixtureIsWhatItClaims() {
        let before = Self.legacyChosenOff()
        #expect(before.predatesNaturalTuning)
        #expect(before.consonantProtection == .offByChoice)
        let updated = before.upgradedToNaturalTuning()
        #expect(updated.formantCorrection == 1 && updated.transitionSlopeCentsPerSecond == 3000)
        #expect(updated.consonantProtection == .offByChoice)
    }

    /// Planted and seen red (W7-NTU P-v-d41): `took` without
    /// `afterHandEdit(from:)` — it then says NO to the store's correct write.
    @Test("⛔ the read-back: YES to the store's own write (the old vocal updated, the chosen OFF kept), NO to a store that skipped the update, switched the OFF on, moved a pitch, or lost the note")
    func tookReadsTheWholeSet() {
        let before = Self.legacyChosenOff()
        let a = before.segments[0].id
        var edited = before
        edited.segments[0].formantOffsetSemitones = -2
        let stored = edited.upgradedToNaturalTuning()
        #expect(PitchEditorVoiceWrite.took(before: before, segmentIDs: [a], semitones: -2, stored: stored))
        // The update skipped: the Voice is right and the vocal is still old.
        #expect(!PitchEditorVoiceWrite.took(before: before, segmentIDs: [a], semitones: -2, stored: edited))
        // The chosen OFF switched back on by the update.
        var switchedOn = stored
        switchedOn.consonantProtection = .on
        #expect(!PitchEditorVoiceWrite.took(before: before, segmentIDs: [a], semitones: -2, stored: switchedOn))
        // Another note's pitch moved in the same write.
        var moved = stored
        moved.segments[1].pitchOffsetCents = 40
        #expect(!PitchEditorVoiceWrite.took(before: before, segmentIDs: [a], semitones: -2, stored: moved))
        // The wrong value stored.
        var wrong = before
        wrong.segments[0].formantOffsetSemitones = -1.9
        #expect(!PitchEditorVoiceWrite.took(before: before, segmentIDs: [a], semitones: -2,
                                            stored: wrong.upgradedToNaturalTuning()))
        // A note that is not there, no note, no table.
        #expect(!PitchEditorVoiceWrite.took(before: before, segmentIDs: [UUID()], semitones: -2, stored: stored))
        #expect(!PitchEditorVoiceWrite.took(before: before, segmentIDs: [], semitones: -2, stored: stored))
        #expect(!PitchEditorVoiceWrite.took(before: before, segmentIDs: [a], semitones: -2, stored: nil))
        #expect(!PitchEditorVoiceWrite.took(before: nil, segmentIDs: [a], semitones: -2, stored: stored))
    }

    @Test("the read-back clamps as the store does (±24; a non-finite value is 0), and a Voice a note already has updates NOTHING (D4-1's no-op rule)")
    func tookClampsAndNoOp() {
        let before = Self.legacyChosenOff()
        let a = before.segments[0].id
        let b = before.segments[1].id
        var clamped = before
        clamped.segments[0].formantOffsetSemitones = 24
        #expect(PitchEditorVoiceWrite.took(before: before, segmentIDs: [a], semitones: 30,
                                           stored: clamped.upgradedToNaturalTuning()))
        // b is already as sung: writing 0 (or a NaN, read as 0) changes no
        // note, so the old vocal stays exactly as it was.
        #expect(PitchEditorVoiceWrite.took(before: before, segmentIDs: [b], semitones: 0, stored: before))
        #expect(PitchEditorVoiceWrite.took(before: before, segmentIDs: [b], semitones: .nan, stored: before))
        #expect(!PitchEditorVoiceWrite.took(before: before, segmentIDs: [b], semitones: 0,
                                            stored: before.upgradedToNaturalTuning()),
                "a no-op that updated the whole vocal read as a success")
    }

    // MARK: - The far-move hint (§1(f) item 4, R26's words — W7-NTU 2026-10-04)

    /// Four notes: up 300, down 300, up 299 and as sung. `keep` is the vocal's
    /// own voice-size amount (nil: tuned before this update).
    static func farFixture(keep: Double?) -> PitchEditSet {
        var set = PitchEditSet(segments: [
            NoteSegment(startSeconds: 0, endSeconds: 0.5, detectedHz: 220, detectedConfidence: 0.95,
                        pitchOffsetCents: 300),
            NoteSegment(startSeconds: 0.5, endSeconds: 1, detectedHz: 220, detectedConfidence: 0.95,
                        pitchOffsetCents: -300),
            NoteSegment(startSeconds: 1, endSeconds: 1.5, detectedHz: 220, detectedConfidence: 0.95,
                        pitchOffsetCents: 299),
            NoteSegment(startSeconds: 1.5, endSeconds: 2, detectedHz: 220, detectedConfidence: 0.95),
        ])
        set.formantCorrection = keep
        return set
    }

    /// Planted and seen red (W7-NTU P-far-edge): `farMoveCents` compared with
    /// `>` (a move of exactly 3 semitones would not ask).
    @Test("§1(f) item 4 — the hint: R26's words; a note 3 semitones or more from where it was sung, either way, on a vocal keeping UNDER half its voice size; 299 is not far, 0.5 is not under")
    func farMoveHintRule() {
        typealias H = PitchEditorFarMoveHint
        #expect(C.farMoveHint == "Big jump: turn up Keep voice size so it doesn't sound squeaky.")
        #expect(C.farMoveHint.contains(C.voiceLabel), "the hint names a control that is not on screen")
        #expect(H.farMoveCents == 300)
        #expect(H.keepBelow == 0.5)
        let off = Self.farFixture(keep: 0)
        let up = off.segments[0].id, down = off.segments[1].id
        let nearly = off.segments[2].id, still = off.segments[3].id
        // How far: inclusive at 300, either direction; 299 and 0 are not far.
        #expect(H.line(movedNoteIDs: [up], table: off, formantPreserve: false) == C.farMoveHint)
        #expect(H.line(movedNoteIDs: [down], table: off, formantPreserve: false) == C.farMoveHint)
        #expect(H.line(movedNoteIDs: [nearly], table: off, formantPreserve: false) == nil)
        #expect(H.line(movedNoteIDs: [still], table: off, formantPreserve: false) == nil)
        // A group: any far note asks.
        #expect(H.line(movedNoteIDs: [nearly, still, up], table: off, formantPreserve: false) == C.farMoveHint)
        // Nothing moved, or a note that is not in the table: nothing to say.
        #expect(H.line(movedNoteIDs: [], table: off, formantPreserve: false) == nil)
        #expect(H.line(movedNoteIDs: [UUID()], table: off, formantPreserve: false) == nil)
        // How much is kept: under 0.5 asks, 0.5 and over does not. The vocal's
        // own amount wins over the clip flag.
        for (keep, asks) in [(0.0, true), (0.25, true), (0.49, true), (0.5, false), (0.75, false), (1.0, false)] {
            let table = Self.farFixture(keep: keep)
            #expect((H.line(movedNoteIDs: [table.segments[0].id], table: table, formantPreserve: true) != nil) == asks,
                    "keep \(keep)")
        }
        // A vocal with no amount of its own: the clip flag decides, 1 or 0.
        let legacy = Self.farFixture(keep: nil)
        #expect(H.effectiveKeep(legacy, formantPreserve: true) == 1)
        #expect(H.effectiveKeep(legacy, formantPreserve: false) == 0)
        #expect(H.line(movedNoteIDs: [legacy.segments[0].id], table: legacy, formantPreserve: true) == nil)
        #expect(H.line(movedNoteIDs: [legacy.segments[0].id], table: legacy, formantPreserve: false) == C.farMoveHint)
        #expect(H.effectiveKeep(Self.farFixture(keep: 0.3), formantPreserve: true) == 0.3)
    }

    // MARK: - The double-click, from a REAL event (W7-NTU ruling 4, 2026-10-04)

    /// A real `NSEvent` of `type`, with `clicks` as its click count.
    static func mouseEvent(_ type: NSEvent.EventType, clicks: Int) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: 0, context: nil, eventNumber: 0,
                                        clickCount: clicks, pressure: 0))
    }

    /// The live pane's one line, `PitchEditorChord.current`, as a function of
    /// the event: `clickCount(eventType:readClickCount:)` with the event's
    /// own type and count. `reads` counts every time the count was READ.
    static func clicks(of event: NSEvent?, reads: inout Int) -> Int {
        PitchEditorChord.clickCount(eventType: event.map { UInt($0.type.rawValue) },
                                    readClickCount: { reads += 1; return event?.clickCount ?? 1 })
    }

    /// Planted and seen red (W7-NTU P-clicks): the decision reading the count
    /// on every event type.
    @Test("a double-click's mouse-up reads 2 from a REAL NSEvent; a key event or no event reads 1 and the count is NEVER read (it raises on those)")
    func clickCountFromRealEvents() throws {
        // The plain numbers are AppKit's own.
        #expect(PitchEditorChord.leftMouseDownEventType == UInt(NSEvent.EventType.leftMouseDown.rawValue))
        #expect(PitchEditorChord.leftMouseUpEventType == UInt(NSEvent.EventType.leftMouseUp.rawValue))

        var reads = 0
        #expect(Self.clicks(of: try Self.mouseEvent(.leftMouseUp, clicks: 2), reads: &reads) == 2)
        #expect(Self.clicks(of: try Self.mouseEvent(.leftMouseDown, clicks: 2), reads: &reads) == 2)
        #expect(Self.clicks(of: try Self.mouseEvent(.leftMouseUp, clicks: 1), reads: &reads) == 1)
        #expect(Self.clicks(of: try Self.mouseEvent(.leftMouseUp, clicks: 3), reads: &reads) == 3)
        #expect(reads == 4, "a mouse-down or mouse-up must READ its count")

        // Never read: a drag tick, a right click, a key, no event at all. The
        // spy answers 9 WITHOUT touching the event (reading a key event's
        // count raises, which would end the run rather than fail this test),
        // so a decision that reads anyway returns 9 here.
        func unread(_ event: NSEvent?) -> Int {
            PitchEditorChord.clickCount(eventType: event.map { UInt($0.type.rawValue) },
                                        readClickCount: { reads += 1; return 9 })
        }
        reads = 0
        #expect(unread(try Self.mouseEvent(.leftMouseDragged, clicks: 2)) == 1)
        #expect(unread(try Self.mouseEvent(.rightMouseUp, clicks: 2)) == 1)
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                timestamp: 0, windowNumber: 0, context: nil,
                                                characters: "a", charactersIgnoringModifiers: "a",
                                                isARepeat: false, keyCode: 0))
        #expect(unread(key) == 1)
        #expect(unread(nil) == 1)
        #expect(reads == 0, "the count was read on an event that does not define it")

        // A count below 1 reads 1, as `PitchEditorChord.init` does.
        #expect(PitchEditorChord.clickCount(eventType: PitchEditorChord.leftMouseUpEventType,
                                            readClickCount: { 0 }) == 1)

        // And a chord built from it carries it to the release.
        let chord = PitchEditorChord(clickCount: Self.clicks(of: try Self.mouseEvent(.leftMouseUp, clicks: 2),
                                                             reads: &reads))
        #expect(chord.clickCount == 2)
    }
}
