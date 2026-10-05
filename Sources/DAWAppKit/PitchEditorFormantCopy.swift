import Foundation
import DAWCore

// W7-NTU (natural tuning, design `docs/design/2026-09-25-natural-tuning.md`
// X9 + R26) — EVERY WORD the pitch editor's "Sound like the singer" group
// draws, in ONE home.
//
// ⭐ **ONE HOME, ASSERTED BY VALUE.** The view draws these, the chrome ledger
// reports the very strings drawn, and `PitchEditorSingerGroupTests` pins them
// by value (the state-line law, `docs/DESIGN-LANGUAGE.md`). A second copy of a
// sentence in the view is how the card and the wire come to disagree.
//
// ⛔ **THREE WORD RULES, ALL FROM THE DESIGN:**
//  * No row uses the word "Natural": it is a preset chip's name (X9). Kept
//    out of the tooltips too, so the rule has no exceptions to argue.
//  * No jargon: not "formant", not "cents", not "vibrato" (the brief's rule).
//  * "Gentle" and "Sharp" are taken (a preset chip; "too high"), so the Slides
//    steps are Snappy / Quick / Smooth / Slow (R26), and their tooltips say
//    "soft", never "gentle". (X9's own Slides line, "How gently…", stays.)

/// Every user-facing string of the header group "Sound like the singer"
/// (natural tuning X9, R26) and of the Voice tool (§1(f) items 2-3, U3).
public enum PitchEditorFormantCopy {

    // MARK: The group (X9)

    /// The group's title, in the header's caption dress (the "TUNE THIS
    /// VOCAL" style: SF Mono caps), so it is drawn as written here.
    public static let groupTitle = "SOUND LIKE THE SINGER"

    /// The app's refusal bubble when a group change was accepted and then not
    /// found in the clip (`PitchEditorSingerWrite`'s read-back failed).
    public static let settingDidNotTake =
        "That change did not stick. The vocal is as it was, and nothing else was altered. "
            + "Try again."

    // MARK: Keep voice size (§1(f), R26)

    public static let voiceLabel = "Keep voice size"
    /// X9's novice line, drawn under the row.
    public static let voiceLine = "Keeps the voice its own size when notes move."
    public static let voiceHelp =
        "How much of the singer's own voice size a moved note keeps. 100% keeps all of it. "
            + "Off lets the voice follow the note, which can sound small and squeaky after a big move."

    /// ⭐ **THE UPGRADE LINE, WORDED FOR THE USER'S RULING (b)** (Q-U1, D4-1):
    /// a vocal tuned before this update updates on its FIRST note change, and a
    /// tap updates it now (`ProjectStore.upgradeToNaturalTuning`). Both halves
    /// are said, because both are what happens. ≤ 51 characters (the dim law's
    /// measured budget, `docs/DESIGN-LANGUAGE.md`): 47, measured with `wc -m`.
    /// Shown exactly while `PitchEditSet.predatesNaturalTuning` holds (R16).
    public static let voiceUpdateLine = "Older tuning. Tap, or change a note, to update."
    /// The update line's tooltip: the WHY, which costs no pixels (the dim law).
    public static let voiceUpdateHelp =
        "This vocal was tuned before the app could keep a singer's voice size, S sounds and "
            + "slides. Tap here, or change any note, and the whole vocal updates in one step. "
            + "Undo takes it back."

    /// The readout for NO voice-size setting (a vocal tuned before this
    /// update, or one set back to that on purpose): a dash, never a number the
    /// render does not use.
    public static let voiceReadoutUnset = "—"
    /// The readout at 0: the OFF law (`docs/DESIGN-LANGUAGE.md`, "a range whose
    /// bottom means off must read OFF"). 0 keeps none of the voice's size: the
    /// voice follows the note.
    public static let voiceReadoutOff = "Off"

    /// The readout for a kept amount `0...1`: whole percent, "Off" at 0, no
    /// space before "%" (the app's drawn percentages, e.g. the Wobble tip's
    /// "(100%)").
    public static func voiceReadout(_ amount: Double?) -> String {
        guard let amount, amount.isFinite else { return voiceReadoutUnset }
        let percent = Int((amount.clamped(to: 0...1) * 100).rounded())
        return percent == 0 ? voiceReadoutOff : "\(percent)%"
    }

    // MARK: Consonants (§2f)

    public static let consonantsLabel = "Consonants"
    /// §2f's drawn summary, kept verbatim by X9.
    public static let consonantsLine = "S, T and breaths keep their own pitch."
    public static let consonantsHelp =
        "When this is on, the S, T and breath sounds between notes play as you recorded them, "
            + "so they never get a robotic pitch."
    /// The switch's two faces, the house ON/OFF capsule.
    public static let switchOn = "ON"
    public static let switchOff = "OFF"

    /// The amber line while the switch is ON but the render cannot run it
    /// (§2f: "stays LIVE, goes DIM and SAYS SO"), in the pane's words, not the
    /// wire's. Gated on `PitchEditSet.consonantMixInactiveReason`, the ONE rule.
    public static func consonantsPaused(_ reason: ConsonantMixInactiveReason) -> String {
        switch reason {
        case .clipStretched: return "Paused while the clip plays faster or slower."
        case .clipTransposed: return "Paused while the whole clip is shifted in pitch."
        case .timeEdits: return "Paused while notes are moved in time."
        }
    }

    // MARK: Slides (§4.f, R26)

    public static let slidesLabel = "Slides"
    /// X9's novice line.
    public static let slidesLine = "How gently a moved note slides into the next."
    public static let slidesHelp =
        "How gently a moved note glides into the next one. After a big move, a smoother "
            + "slide sounds more like real singing."

    /// ⚠️ **NOT "Set by preset"**, which §4.f and the brief name. R14 made
    /// every preset seed the slide smoothness too (`PitchEditSet.seeded`,
    /// both seed policies), so a smoothness of 0 now means ONE thing: this
    /// vocal was tuned before the update, by a preset OR by hand. "Set by
    /// preset" would be false for the hand-tuned ones. This face is true for
    /// both, and says what a pick does (§4.f's hint).
    public static let slidesOldTuningLine = "Set by the old tuning. Pick one to take over."
    /// A smoothness that is none of the four steps (an agent set it on the
    /// wire): no step is lit, because none is in force (§4.f: "it never shows a
    /// step the render is not using").
    public static let slidesCustomLine = "Set to a custom smoothness. Pick one to change it."

    /// Each step's name (R26), drawn on its chip.
    public static func slideStepName(_ step: PitchEditorSlideStep) -> String {
        switch step {
        case .snappy: return "Snappy"
        case .quick: return "Quick"
        case .smooth: return "Smooth"
        case .slow: return "Slow"
        }
    }

    /// Each step's tooltip.
    public static func slideStepHelp(_ step: PitchEditorSlideStep) -> String {
        switch step {
        case .snappy: return "The fastest slide: a moved note jumps into the next one."
        case .quick: return "A short slide into the next note."
        case .smooth: return "A soft slide that grows with the size of the jump."
        case .slow: return "A long, soft slide into the next note."
        }
    }

    // MARK: The Voice tool (§1(f) items 2-3, R9, R11, R22, R25, R26 — W7-NTU U3)
    //
    // ⚠️ "Voice" here is ONE NOTE'S voice, made deeper or brighter. The header's
    // "Keep voice size" is the whole vocal's setting. The two share a word on
    // purpose (R25 names the Formant tool "Voice"), so every sentence below
    // says "note" or "deeper or brighter" beside it, and the replace card
    // names this edit by what it does ("made deeper or brighter"), never by
    // "voice" alone, where it would read as the header's setting.

    /// The palette slot's name (R25: "Formant tool → Voice").
    public static let voiceToolLabel = "Voice"
    /// §1(f) item 2's caption, verbatim: the help's first sentence.
    public static let voiceToolDirections =
        "Drag a note up or down to make that part of the voice brighter or deeper, "
            + "without changing the note."
    /// The knob law's two gestures, in the help (⌥ fine, double-click resets).
    public static let voiceToolKeys = "Hold ⌥ for finer steps. Double-click a note to put it back as sung."

    /// The drawn help. The ⌘ sentence and "Let go to hear it." are the Wobble
    /// tool's own (`PitchWobbleCopy`): one home for each, and the two tools say
    /// them the same way. The ⌘ sentence only while ⌘ draws in this tool
    /// (`PitchEditorGestureRouter.commandDraws`).
    public static func voiceToolHelp(drawToolAvailable: Bool) -> String {
        var sentences = [voiceToolDirections, voiceToolKeys]
        if drawToolAvailable { sentences.append(PitchWobbleCopy.helpHoldCommand) }
        sentences.append(PitchWobbleCopy.helpLetGo)
        return sentences.joined(separator: " ")
    }

    /// R11, verbatim: the readout on a note shorter than
    /// `PitchEditSet.minimumVoiceNoteSeconds`. Like §3's "too short to
    /// separate", it is a READOUT, not a refusal: the edit is taken, and this
    /// says how far it can reach. Drawn in the readout slot's own ink, never
    /// amber (amber means "the render could not apply this", R22).
    public static let voiceTooShort = "Too short to change the voice of this note alone"

    /// §1(f) item 4's far-move hint, in R26's wording (the row is "Keep voice
    /// size", not item 4's older "Keep voice natural"). Drawn in the palette
    /// after a pitch drag leaves a note 3 semitones or more from where it was
    /// sung on a vocal that keeps under half its voice size
    /// (`PitchEditorFarMoveHint`). Advice, not a refusal: secondary ink, never
    /// amber, since nothing was refused.
    public static let farMoveHint = "Big jump: turn up Keep voice size so it doesn't sound squeaky."

    /// A press on a SOUND (a breath or a consonant, `NoteOrigin.unpitched`): the
    /// store refuses its Voice (it has no sung voice to reshape), so the tool
    /// refuses the press first, in a novice's words, not the store's (which
    /// name a note id).
    public static let voiceSoundRefusal =
        "This is a breath or a consonant, so it has no voice to make deeper or brighter."

    /// A Voice amount in semitones, one decimal and no sign. The house rule
    /// for a level applies (`NoteBlob.levelReadout`): a non-zero value always
    /// reads, even one that rounds to "0.0", because the direction word beside
    /// it says there IS a change.
    static func voiceAmount(_ semitones: Double) -> String {
        String(format: "%.1f", abs(semitones))
    }

    /// The chip under a note (§1(f) item 2's words): "Deeper 2.0" or
    /// "Brighter 1.5". "" for a note as sung, which draws no chip.
    public static func voiceChip(_ semitones: Double) -> String {
        guard semitones.isFinite, semitones != 0 else { return "" }
        return (semitones < 0 ? "Deeper " : "Brighter ") + voiceAmount(semitones)
    }

    /// The palette's SF Mono readout for a note's Voice: "Voice: as sung",
    /// "Voice: deeper 2.0" or "Voice: brighter 1.5".
    public static func voiceToolReadout(_ semitones: Double) -> String {
        guard semitones.isFinite, semitones != 0 else { return "Voice: as sung" }
        return (semitones < 0 ? "Voice: deeper " : "Voice: brighter ") + voiceAmount(semitones)
    }

    /// §1(f) item 3's note-menu row: "Voice: Deeper 2.0", "Voice: Brighter 2.0"
    /// and "Voice: As sung". The number is the value the row SETS (absolute,
    /// `PitchEditorVoiceTool.menuSemitones`), so "Deeper" can never read as a
    /// step on a note that is already deeper than that.
    public static func voiceMenuTitle(_ semitones: Double) -> String {
        guard semitones.isFinite, semitones != 0 else { return "Voice: As sung" }
        return (semitones < 0 ? "Voice: Deeper " : "Voice: Brighter ") + voiceAmount(semitones)
    }
}
