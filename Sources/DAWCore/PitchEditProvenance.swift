import Foundation

// m23-ap C-F3 (design `docs/design/2026-09-24-pitch-editor-timing-and-freehand.md`,
// finding F22) — "HAS ANYONE EDITED THIS BY HAND SINCE THE LAST PRESET?"
//
// `ProjectStore.autoCorrectClipPitch` REPLACES a clip's whole note table. Once
// people can move and split notes by hand, one preset click erases that work,
// so the preset doors must ask first. They must NOT ask when the clip holds
// only a preset's own output: switching Gentle → Natural → Tight to compare
// them is the main way people use presets, and a dialog on every switch would
// teach them to click through dialogs.
//
// `NoteSegment.isEdited` cannot tell those two apart, because a preset's own
// output sets per-note fields too. So:
//
// ═══════════════════════════════════════════════════════════════════════════
// THE MECHANISM: a content stamp, written by the preset, compared on demand
// ═══════════════════════════════════════════════════════════════════════════
//
// When an auto-correct pass writes a set it records `contentStamp` in
// `autoCorrectStamp`. Later, `hasHandEditsSinceAutoCorrect` asks whether the
// content still matches that stamp.
//
// ⭐⭐ **WHY A STAMP AND NOT A FLAG THE HAND-EDIT SETTERS SET.** A flag is only
// as good as the last setter that remembered to set it, and per-note setters
// are being added right now (wobble, timing, drawn shapes). One that forgot
// would silently disarm the warning: the exact F22 shape, "a write that
// succeeds and quietly breaks the guard". A stamp needs no setter's help: ANY
// write through ANY path changes the content, and the content no longer
// matches. The type's own `encode(to:)` is the field census, the same move
// `splitClipNoteSegment`'s `reidentified` makes in the same domain for the same
// reason, so a field added tomorrow is covered the day it is added.
//
// Two properties fall out, both pinned by tests:
//  * Move a note and move it back: the set is byte-identical to the preset's
//    output, and the answer is "no hand edits". There is nothing to lose.
//  * The stamp lives INSIDE the set, so undo/redo restore it with the notes
//    (`EditState` snapshots the tracks), and an arrange split — which copies
//    the whole set to both halves verbatim — keeps both halves quiet.
//
// ⚠️ **NOT `PitchEditSetDigest` (DAWEngine), AND THE TWO MUST NOT BE UNIFIED.**
// That digest is the RENDER key: it walks fields explicitly, answers "" for a
// set that bends nothing, and must never include this stamp (identical notes
// must share one cached render whoever wrote them). This stamp answers a
// different question, "is this exactly what the machine wrote?". A cut that
// changes nothing audible is still a change here.
//
// ⚠️ **`StretchRenderCache.Params` CARRIES THE RAW SET, SO ITS SYNTHESIZED
// `==` SEES THIS STAMP**, while its hash, its disk keys and its in-flight job
// key see only the digest. A difference in the stamp ALONE (same notes,
// different stamp) arises on ONE path: a set with no stamp (saved before this
// field existed) replaced by a preset whose output is byte-identical to it,
// plus that step's undo and redo. Every other writer, censused 2026-09-24,
// either writes the stamp WITH its content (the preset), keeps it
// (`setClipNotePitchOffset` mutates in place), or changes the content anyway
// (`splitClipNoteSegment` rebuilds the set and drops the stamp, which answers
// the same as a stale one). What that path costs, read from source: an
// "Auto-Correct Pitch" undo step that changes nothing audible, and at most one
// extra wrapper from `AudioEngine.kickStretchRender`, which finds the
// committed file or joins the running job (`renderIfNeeded`,
// `job.key == key`). No extra render. It settles because the stamp is a pure
// function of the stored set, so the "re-kicks forever" hazard noted at
// `Params.init` (Params changing while the model does not) cannot follow from
// it. A Hard Tune set playing its fallback may repeat its contour notice once.
//
// NT-C2-F1 (W7-D2) added a SECOND field that `==` sees and the digest does
// not: the consonant CHOICE (`PitchEditSet.consonantProtection`, an OFF
// somebody chose versus one nobody chose; both read `keepsConsonantsUntuned`
// false). Its one same-notes path is `setClipConsonantProtection(enabled:
// false)` on an OFF nobody chose, plus that step's undo and redo: the same
// shape, and by the same mechanism the same cost, as the stamp path above
// (argued from this paragraph, not re-measured). The choice is ALSO part of
// what the set saves, so `contentStamp` sees it, with no exception here: a
// choice made after a preset reads as a change since that preset, exactly as
// a flip of the flag always has.
//
// ═══════════════════════════════════════════════════════════════════════════
// W7-NTU (2026-10-04): A SECOND STAMP, FOR WHAT A PRESET WOULD REPLACE
// ═══════════════════════════════════════════════════════════════════════════
//
// The whole-set stamp moves when the voice size or the consonant choice is
// changed after a preset, exactly as a moved note moves it. But the next
// preset does not lose those two: `ProjectStore.autoCorrectClipPitchReport`
// CARRIES a voice size the table holds (unless the options name one) and a
// consonant setting somebody chose (all but `.offByDefault`). So a card that
// asks before replacing hand edits asked about something it would keep.
//
// `replaceableContentStamp` is the content stamp with those two FOLDED to
// "kept / not kept" (a voice size → the seed's, nil stays nil; a chosen
// consonant setting → `.on`, `.offByDefault` stays). The preset records it in
// `autoCorrectReplaceableStamp` beside the whole one, and
// `hasHandEditsARerunWouldReplace(_:)` compares it. Everything a preset DOES
// replace is still in it: every note, the slide smoothness (re-seeded, never
// carried), the retune speed.
//
// ⛔ **`hasHandEditsSinceAutoCorrect` IS UNCHANGED, ON PURPOSE.** It is also
// the store's `replaceExisting:false` refusal, and the WIRE may name a voice
// size of its own (`PitchAutoCorrectOptions.formantCorrection`), which
// REPLACES the hand-set one. Relaxing it would let that call overwrite a
// hand-set voice size with no refusal. The new predicate takes the options
// and folds the voice size only when they name none.
//
// ⭐ **ABSENT IS TODAY'S BEHAVIOUR.** A set saved before the field has no
// replaceable stamp, and the predicate answers exactly as
// `hasHandEditsSinceAutoCorrect` does: one more question for that clip, and
// the preset that follows writes both stamps (the rule this banner already
// states for sets saved before `autoCorrectStamp`).
//
// The new stamp is a THIRD field `StretchRenderCache.Params`' `==` sees and the
// digest does not. It is written only WITH `autoCorrectStamp`, by the same
// preset write, so it adds no same-notes path of its own: the stamp paragraph
// above covers it.
//
// ⚠️ **WHY FNV-1a AND NOT SHA256.** DAWCore imports Foundation only, and
// Swift's `Hashable` is seeded per process, so it would never match a stamp
// saved by an earlier launch. This is change detection, not security: 64 bits
// make an accidental collision about 1 in 1.8 × 10¹⁹.
//
// ⚠️ **ONE CROSS-VERSION CASE, AND IT FAILS IN THE SAFE DIRECTION. DO NOT "FIX"
// IT.** `JSONEncoder`'s number formatting is Foundation's, and a future OS
// could format a Double differently. The only effect would be a project stamped
// on one OS and opened on another reading as "may carry hand edits": ONE
// unnecessary confirm for that clip, which re-stamps on the next preset. The
// tempting fix, a hand-written walk over raw bit patterns, would bring back the
// hand-maintained field list this design exists to avoid.

extension PitchEditSet {

    /// A deterministic stamp of everything this set would SAVE, except the
    /// two stamp fields. nil only if the set cannot be encoded at all, and
    /// the predicate below reads that as "may carry hand edits".
    ///
    /// Computed on a copy with `autoCorrectStamp` and
    /// `autoCorrectReplaceableStamp` nil, through the type's own `encode(to:)`
    /// (which omits a nil stamp), so neither stamp can be part of its own
    /// input. On a set with no replaceable stamp (every set saved before
    /// 2026-10-04) that is the same bytes, so the same stamp, as before. Sorted keys make the bytes independent of dictionary
    /// order. Cost: one JSON encode plus one pass over the bytes. It is asked
    /// once per preset write and once per preset click, never per frame.
    public var contentStamp: String? {
        var unstamped = self
        unstamped.autoCorrectStamp = nil
        unstamped.autoCorrectReplaceableStamp = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let bytes = try? encoder.encode(unstamped) else { return nil }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325          // FNV-1a 64 offset basis
        bytes.withUnsafeBytes { raw in
            for byte in raw {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3      // FNV-1a 64 prime
            }
        }
        return String(format: "%016llx", hash)
    }

    /// W7-NTU (2026-10-04) — the content stamp of what a preset would REPLACE:
    /// `contentStamp` of this set with the two settings a preset KEEPS folded
    /// to "kept / not kept". The fold is the store's carry rule
    /// (`ProjectStore.autoCorrectClipPitchReport`): a voice size the set holds
    /// is carried (→ `newSetFormantCorrection`; nil, which a preset re-seeds,
    /// stays nil), and a consonant setting somebody chose is kept (`.on` and
    /// `.offByChoice` → `.on`; `.offByDefault`, which a preset re-seeds,
    /// stays). The slide smoothness is NOT folded: a preset re-seeds it.
    /// `PitchEditReplaceableStampTests` runs the REAL store's preset after each
    /// change and reads the result back, so a carry rule that moves turns it
    /// red.
    public var replaceableContentStamp: String? {
        var folded = self
        if folded.formantCorrection != nil {
            folded.formantCorrection = Self.newSetFormantCorrection
        }
        if folded.consonantProtection != .offByDefault {
            folded.consonantProtection = .on
        }
        return folded.contentStamp
    }

    /// This set as an auto-correct pass writes it: stamped with its own
    /// content, whole and as a preset would replace it.
    /// `ProjectStore.autoCorrectClipPitch` is the caller (and the
    /// `findUnpitchedSounds` merge, re-stamping a set that was exactly a
    /// preset's output).
    public func stampedAsAutoCorrectOutput() -> PitchEditSet {
        var stamped = self
        stamped.autoCorrectStamp = contentStamp
        stamped.autoCorrectReplaceableStamp = replaceableContentStamp
        return stamped
    }

    /// ⭐ **THE question the preset doors ask before replacing this set.**
    ///
    /// **false** means this set is exactly what the last auto-correct pass
    /// wrote. Replacing it loses nothing a preset click cannot re-create, so
    /// the doors switch presets with no dialog.
    ///
    /// **true** means something changed it since then (a note moved or split,
    /// by the editor or over the wire), OR nothing proves it is a preset's
    /// output:
    ///  * a table the note editor seeded and the person then edited, which
    ///    never had a preset at all;
    ///  * a set saved before this field existed. Those clips each get ONE
    ///    unnecessary confirm, and the preset that follows re-stamps them. An
    ///    extra question is recoverable; a silent erase is not.
    ///
    /// A clip with no set at all (`pitchEdits == nil`) has nothing to lose, and
    /// callers answer that before reaching here.
    public var hasHandEditsSinceAutoCorrect: Bool {
        guard let stamp = autoCorrectStamp, let now = contentStamp else { return true }
        return stamp != now
    }

    /// W7-NTU (2026-10-04) — ⭐ **THE question the preset CARD asks: would
    /// re-running a preset with `options` throw away work it cannot re-create?**
    ///
    /// **false** when everything a preset REPLACES is exactly what the last
    /// pass wrote: the notes, the slide smoothness and the retune speed are
    /// untouched, and any change is to a setting the preset KEEPS (a voice
    /// size, a consonant choice). **true** otherwise, exactly as
    /// `hasHandEditsSinceAutoCorrect`, whenever:
    ///  * the options NAME a voice size (only the wire can): that preset
    ///    replaces the voice size too, so nothing is folded;
    ///  * the set has no replaceable stamp (saved before 2026-10-04, or
    ///    never written by a preset): today's whole-set rule, one question.
    ///
    /// The store's `replaceExisting:false` refusal still asks
    /// `hasHandEditsSinceAutoCorrect`: it is the more careful of the two, and
    /// it moves to this one only with its own route (W7-NTU STATUS).
    ///
    /// TODO(mcp-integration-engineer, W7-NTU ruling 1 wire half): adopt this in
    /// `ProjectStore.autoCorrectClipPitchReport`'s two `replaceExisting:false`
    /// checks (`existing.hasHandEditsARerunWouldReplace(options)`), and echo it
    /// beside `handEditedSinceAutoCorrect` in `clip.getPitchEdits`, so the wire
    /// and the card agree again. MCP tools `clip_auto_correct_pitch` and
    /// `clip_get_pitch_edits`.
    public func hasHandEditsARerunWouldReplace(_ options: PitchAutoCorrectOptions) -> Bool {
        guard options.formantCorrectionOverride == nil,
              let stamp = autoCorrectReplaceableStamp,
              let now = replaceableContentStamp
        else { return hasHandEditsSinceAutoCorrect }
        return stamp != now
    }
}
