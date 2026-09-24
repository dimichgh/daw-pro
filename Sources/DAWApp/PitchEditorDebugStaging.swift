import DAWAppKit
import DAWControl
import DAWCore
import Foundation

// The `debug.pitchEditor` handler (m23-ap Phase 2, item p2-c) — the
// PianoRollMarqueeStaging / DefaultsDomainStaging tradition: app-tier,
// deliberately off `allCommands`, off MCP, and out of `DAWProApp.swift`
// itself (the m23-cq-1 shape — that file is 13 000+ lines and a standing
// merge magnet; the footprint there is the one dispatch line in
// `installDebugCommands()`).
//
// ═══════════════════════════════════════════════════════════════════════════
// WHAT THIS ECHOES, AND THE ONE THING IT CANNOT
// ═══════════════════════════════════════════════════════════════════════════
//
// Design `docs/design/2026-09-22-pitch-editor-ui.md` §12.4: "a spy gate beats
// a source-shape gate." `PitchEditorChromeLedger` (`PitchEditorView.swift`) IS
// that spy — the view writes the very strings and counts it drew, from inside
// the drawing arguments, into `AppModel.pitchEditorChrome`, and this handler
// reads that ledger back rather than re-deriving anything the view already
// computed. Both halves are echoed VERBATIM:
//   - the CHROME half — `statusKey`/`statusText`/`captionText`/`presetLabels`/
//     `presetSummaries`/`noteCount`/`tuningApplied`/`ticks`.
//   - the INTERACTION half (m23-ap Increment C) — `toolKey`/`paletteLabels`/
//     `toolHelp`/`dragReadout`/`refusalText`/`commitCount`/`interactionTicks`.
//
// ⚠️ **`interaction.toolKey` (and the top-level `tool` mirror of it) READS ""
// UNTIL THE PALETTE HAS DRAWN AT LEAST ONCE.** The ledger is written DURING
// `body`, so a `view.openPitchEditor` immediately followed by `debug.pitchEditor`
// with no SwiftUI pump in between can race the first paint. `view.capture`
// (which flushes pending updates, `ViewUIWireSurface.flushPendingViewUpdates`)
// or a short `RunLoop.main.run` between the two calls settles it — a caller
// that reads "" here has not necessarily hit a bug.
//
// ═══════════════════════════════════════════════════════════════════════════
// "NOTES AS DRAWN" — WHY THIS COMES FROM THE STORE, NOT FROM THE VIEW
// ═══════════════════════════════════════════════════════════════════════════
//
// The view's actual on-screen blobs come from `PitchEditorModel.noteTable`
// (`storedTable ?? seedTable`), and `seedTable` — the live, UNSAVED detection
// a freshly-opened pane draws before any edit — lives only in that model's
// `@State`, private to `PitchEditorView`. There is no reachable spy for it
// (extending the ledger to carry it needs a change in
// `Sources/DAWApp/PitchEditor/*`, out of this item's lane), and there must
// not be one on principle either: m23-q condition 4/F11 and this milestone's
// own writers (`ProjectStore+PitchNoteEdits.swift`'s banner) are explicit
// that **there is no pitch detection on the wire path** — the seed is an
// in-process-editor-only shortcut. So `notes` below is `clip.pitchEdits`, the
// STORED table — exactly what `clip.getPitchEdits` would answer, and exactly
// what a note MUST carry before `clip.setNotePitch`/`clip.splitNote` can
// address it.
//
// ⭐ **THIS MEANS `notes.count` AND `chrome.noteCount` CAN LEGITIMATELY
// DISAGREE, AND THAT DISAGREEMENT IS THE SIGNAL, NOT A BUG.** On a clip that
// has never been auto-corrected, the pane draws its live seed
// (`chrome.noteCount` > 0) while the store carries nothing (`notes` empty) —
// two instruments disagreeing, and the honest reading is "the screen is
// showing an unsaved detection." Call `clip.autoCorrectPitch` first (this
// milestone's own round-trip recipe) and the two converge: once a stored
// table exists, `PitchEditorModel.noteTable` prefers it unconditionally
// (`syncStoredNoteTable`'s doc: "the store is the truth the moment it has
// one"), so `notes` becomes exactly what is drawn.
//
// Filtered to the clip's CURRENT source window — `rebuildBlobs`'s own OVERLAP
// rule, mirrored here from the one home (`Clip.sourceWindowSeconds(tempoMap:)`)
// rather than re-derived: a trimmed clip keeps every segment it ever carried
// (they are source-absolute and deliberately never re-anchored), and drawing
// ones outside the current window would echo blobs the view does not.
//
// ═══════════════════════════════════════════════════════════════════════════
// C-0 (design 2026-09-24 §4.4) — THE PLAYED LINE, AS DRAWN
// ═══════════════════════════════════════════════════════════════════════════
//
// `clipPitchShiftSemitones` and `playedLine` are the LEDGER's — the transpose
// the surface drew at and the line it stroked, reported by the view from the
// values it drew with (`PitchEditorView.recordPlayedLine`). Each note's
// `playedMidi` is its DRAWN centre, through the one DAWAppKit function the
// view itself places blobs with (`PitchEditorGeometry.drawnMidi`), at the
// ledger's transpose — so a pane that missed a transpose shows up here as
// `playedMidi` disagreeing with `editedMidi` plus the clip's own shift. Like
// `tool`, these read their empty values until the pane has drawn once. This is
// dogfood, not the gate (the gate is the in-process equality test,
// `PitchEditorDisplayMatchesRenderTests`).
extension AppModel {

    /// `debug.pitchEditor` — read-only, no params. See this file's header for
    /// what each field means and the one place a wire-only caller cannot
    /// reach (the live, unsaved detection seed).
    func pitchEditorDebug() -> JSONValue {
        guard let clip = openPitchEditorClip else {
            return .object([
                "open": .bool(false),
                "clipId": .null,
                "trackId": .null,
                "tool": .string(pitchEditorChrome.toolKey),
                "zoom": Self.pitchEditorZoomJSON(self),
                "notes": .array([]),
                "chrome": Self.pitchEditorChromeJSON(pitchEditorChrome),
                "interaction": Self.pitchEditorInteractionJSON(pitchEditorChrome),
                "clipPitchShiftSemitones": .number(pitchEditorChrome.clipPitchShiftSemitones),
                "playedLine": Self.pitchEditorPlayedLineJSON(pitchEditorChrome),
            ])
        }
        let trackID = store.tracks.first(where: { track in
            track.clips.contains { $0.id == clip.id }
        })?.id

        let windowStart = clip.startOffsetSeconds
        let windowEnd = windowStart + clip.sourceWindowSeconds(tempoMap: store.transport.tempoMap)
        let segments = (clip.pitchEdits?.segments ?? []).filter { segment in
            segment.endSeconds > windowStart && segment.startSeconds < windowEnd
        }

        return .object([
            "open": .bool(true),
            "clipId": .string(clip.id.uuidString),
            "trackId": trackID.map { JSONValue.string($0.uuidString) } ?? .null,
            "tool": .string(pitchEditorChrome.toolKey),
            "zoom": Self.pitchEditorZoomJSON(self),
            "notes": .array(segments.map { segment in
                Self.pitchEditorNoteJSON(
                    segment,
                    drawnShiftSemitones: pitchEditorChrome.clipPitchShiftSemitones)
            }),
            "chrome": Self.pitchEditorChromeJSON(pitchEditorChrome),
            "interaction": Self.pitchEditorInteractionJSON(pitchEditorChrome),
            "clipPitchShiftSemitones": .number(pitchEditorChrome.clipPitchShiftSemitones),
            "playedLine": Self.pitchEditorPlayedLineJSON(pitchEditorChrome),
        ])
    }

    /// `{pixelsPerBeat, rowHeight}` — `PitchEditorGeometry`'s own horizontal/
    /// vertical scale, read from the ONE home (design §5.8: `debug.panelLayout`
    /// tier, not `view.panelLayout` — this changes what an eye prefers, not
    /// what exists to be seen). `PitchEditorView` constructs its model from
    /// exactly these two properties (`layout.pitchEditorPPB`/
    /// `layout.pitchEditorRowHeight`), so this is the value the view draws
    /// at, not a second guess at it.
    private static func pitchEditorZoomJSON(_ model: AppModel) -> JSONValue {
        .object([
            "pixelsPerBeat": .number(Double(model.panelLayout.pitchEditorPPB)),
            "rowHeight": .number(Double(model.panelLayout.pitchEditorRowHeight)),
        ])
    }

    /// One stored note — `id`, SOURCE-FILE `startSeconds`/`endSeconds`, the
    /// measurement (`detectedHz`, and `sungMidi` through
    /// `PitchCorrectionMath.midi(fromHz:)`, the SAME conversion
    /// `DAWAppKit.NoteBlob.centreMidi` uses) and the edit (`pitchOffsetCents`,
    /// `editedMidi` = `sungMidi + pitchOffsetCents / 100`, and — C-0 —
    /// `playedMidi`, the DRAWN centre: `editedMidi` plus the transpose the
    /// surface drew at, through `PitchEditorGeometry.drawnMidi`, the function
    /// the view places the blob with). `edited` is `NoteSegment.isEdited` —
    /// ANY per-note field off its default, not `pitchOffsetCents` alone, so a
    /// note whose only edit is its wobble or its drift reads as edited
    /// (`NoteBlob.hasEdits` is built from the same predicate).
    private static func pitchEditorNoteJSON(_ segment: NoteSegment,
                                            drawnShiftSemitones: Double) -> JSONValue {
        let sungMidi = PitchCorrectionMath.midi(fromHz: segment.detectedHz)
        return .object([
            "id": .string(segment.id.uuidString),
            "startSeconds": .number(segment.startSeconds),
            "endSeconds": .number(segment.endSeconds),
            "detectedHz": .number(segment.detectedHz),
            "sungMidi": .number(sungMidi),
            "pitchOffsetCents": .number(segment.pitchOffsetCents),
            "editedMidi": .number(sungMidi + segment.pitchOffsetCents / 100),
            "playedMidi": .number(PitchEditorGeometry.drawnMidi(
                centreMidi: sungMidi, offsetCents: segment.pitchOffsetCents,
                clipPitchShiftSemitones: drawnShiftSemitones)),
            "edited": .bool(segment.isEdited),
        ])
    }

    /// C-0 — the played line, verbatim from `PitchEditorChromeLedger.recordPlayedLine`:
    /// `basis` (`"render"` / `"estimate"`, "" before the first report),
    /// `reason` (why it is an estimate, else null), the notes drawn with the
    /// amber outline, and per drawn note the line's min / median / max midi
    /// (null for a note the line has no points in).
    private static func pitchEditorPlayedLineJSON(_ chrome: PitchEditorChromeLedger) -> JSONValue {
        func midi(_ value: Double?) -> JSONValue { value.map { .number($0) } ?? .null }
        return .object([
            "basis": .string(chrome.lineBasisKey),
            "reason": chrome.lineReason.map { .string($0) } ?? .null,
            "captionText": .string(chrome.lineCaptionText),
            "captionKind": .string(chrome.lineCaptionKind),
            "unresolvedNoteIds": .array(chrome.unresolvedNoteIDs.map { .string($0.uuidString) }),
            "perNote": .array(chrome.perNote.map { note in
                .object([
                    "id": .string(note.id.uuidString),
                    "minMidi": midi(note.minMidi),
                    "medianMidi": midi(note.medianMidi),
                    "maxMidi": midi(note.maxMidi),
                ])
            }),
            "lineTicks": .number(Double(chrome.lineTicks)),
        ])
    }

    /// The chrome half, verbatim — `PitchEditorChromeLedger.record`'s fields.
    private static func pitchEditorChromeJSON(_ chrome: PitchEditorChromeLedger) -> JSONValue {
        .object([
            "statusKey": .string(chrome.statusKey),
            "statusText": .string(chrome.statusText),
            "captionText": .string(chrome.captionText),
            "presetLabels": .array(chrome.presetLabels.map { .string($0) }),
            "presetSummaries": .array(chrome.presetSummaries.map { .string($0) }),
            "noteCount": .number(Double(chrome.noteCount)),
            "tuningApplied": .bool(chrome.tuningApplied),
            "ticks": .number(Double(chrome.ticks)),
        ])
    }

    /// The interaction half, verbatim — `PitchEditorChromeLedger.recordInteraction`'s
    /// fields (m23-ap Increment C).
    private static func pitchEditorInteractionJSON(_ chrome: PitchEditorChromeLedger) -> JSONValue {
        .object([
            "toolKey": .string(chrome.toolKey),
            "paletteLabels": .array(chrome.paletteLabels.map { .string($0) }),
            "toolHelp": .string(chrome.toolHelp),
            "dragReadout": .string(chrome.dragReadout),
            "refusalText": .string(chrome.refusalText),
            "commitCount": .number(Double(chrome.commitCount)),
            "interactionTicks": .number(Double(chrome.interactionTicks)),
        ])
    }
}
