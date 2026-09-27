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
    /// stamp field itself. nil only if the set cannot be encoded at all, and
    /// the predicate below reads that as "may carry hand edits".
    ///
    /// Computed on a copy with `autoCorrectStamp = nil`, through the type's own
    /// `encode(to:)` (which omits a nil stamp), so the stamp can never be part
    /// of its own input. Sorted keys make the bytes independent of dictionary
    /// order. Cost: one JSON encode plus one pass over the bytes. It is asked
    /// once per preset write and once per preset click, never per frame.
    public var contentStamp: String? {
        var unstamped = self
        unstamped.autoCorrectStamp = nil
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

    /// This set as an auto-correct pass writes it: stamped with its own
    /// content. `ProjectStore.autoCorrectClipPitch` is the one caller.
    public func stampedAsAutoCorrectOutput() -> PitchEditSet {
        var stamped = self
        stamped.autoCorrectStamp = contentStamp
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
}
