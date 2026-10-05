import Foundation

// m23-ap C-0 — THE STORE'S DOOR TO THE CONTOUR THE RENDER USES.
//
// Design: `docs/design/2026-09-24-pitch-editor-timing-and-freehand.md` §4.3.
//
// The pitch editor's line must come from the SAME analysis the render shapes
// against (finding F18: the editor's window detection and the render's
// whole-file contour are different analyses — the frame grid 2.0 ms off, 16 of
// 2004 frames flipping voicing, a median 1.7 cents apart on a trimmed clip).
// This is the one place above the engine that asks for it, so the editor and
// the wire verb (`clip.getPlayedPitch`, C-0c) ask the same question with the
// same arguments.

/// Everything the played line needs from outside the model: the contour the
/// render uses, and the source file's duration (read now so C2's time map —
/// pinned at W(D) = D — has its D from the same place the render will).
public struct PitchRenderInputs: Sendable, Equatable {
    /// What THE seam answered. Never a fabricated contour: every refusal is
    /// `.unavailable(reason:)`.
    public var contour: PitchRenderContour
    /// The source file's length, seconds, via `MediaImporting.audioFileInfo`
    /// — `nil` when the store has no `media` or the header could not be read
    /// (design §3.10 mode 5: a site with no D says so, never guesses one).
    public var sourceDurationSeconds: Double?

    public init(contour: PitchRenderContour, sourceDurationSeconds: Double?) {
        self.contour = contour
        self.sourceDurationSeconds = sourceDurationSeconds
    }
}

extension ProjectStore {

    /// The contour the render uses for this clip, fetched through the engine.
    ///
    /// **THE SEAM'S CONTRACT, CARRIED VERBATIM** (`PitchContourCache.renderContour`):
    ///  * the URL is the clip's SOURCE FILE (`clip.audioFileURL`), never a
    ///    window;
    ///  * the version is the clip's own set's `analysisVersion`, or
    ///    `PitchEditSet.currentAnalysisVersion` for a clip with no edits — so a
    ///    set made by another detector generation is answered
    ///    `.analysisVersionMismatch`, exactly as the render would treat it.
    ///    ⛔ Passing `currentAnalysisVersion` unconditionally would draw a
    ///    shaped line the render refuses to play; `seamIsCalledWithTheRenderArguments`
    ///    plants exactly that.
    ///
    /// TOTAL — never throws. A clip that is not there, has no file, or meets
    /// no engine answers `.unavailable(reason:)` with a clause that completes
    /// "the app couldn't analyse this recording (…)".
    ///
    /// Not detached HERE: the engine's own `renderPitchContour` already hops
    /// to a detached task (`StretchRenderCache.renderContour`). The blocking
    /// static `PitchContourCache.renderContour` is never reached from the
    /// main actor.
    public func renderPitchContour(clipId: UUID) async -> PitchRenderInputs {
        guard let (t, c) = locateClipIndexForRenderContour(clipId) else {
            return PitchRenderInputs(
                contour: .unavailable(reason: "this clip is no longer in the project"),
                sourceDurationSeconds: nil)
        }
        let clip = tracks[t].clips[c]
        guard !clip.isMIDI, let url = clip.audioFileURL else {
            return PitchRenderInputs(contour: .unavailable(reason: "this clip has no audio file"),
                                     sourceDurationSeconds: nil)
        }
        let duration = try? media?.audioFileInfo(at: url).durationSeconds
        guard let engine else {
            return PitchRenderInputs(contour: .unavailable(reason: "no audio engine is running"),
                                     sourceDurationSeconds: duration)
        }
        let analysisVersion = clip.pitchEdits?.analysisVersion
            ?? PitchEditSet.currentAnalysisVersion
        let contour = await engine.renderPitchContour(inFileAt: url,
                                                      analysisVersion: analysisVersion)
        return PitchRenderInputs(contour: contour, sourceDurationSeconds: duration)
    }

    /// Extension-local clip lookup — the repo-wide convention (every
    /// `ProjectStore+…` file keeps its own twin, because `ProjectStore`'s
    /// private `locateClip(_:)` is not visible cross-file). Tracks' clips
    /// only, the same scope `detectClipPitch` and the pitch editor's own
    /// `openPitchEditorClip` resolve (take lanes: design follow-up C-F2).
    private func locateClipIndexForRenderContour(_ id: UUID) -> (t: Int, c: Int)? {
        for (t, track) in tracks.enumerated() {
            if let c = track.clips.firstIndex(where: { $0.id == id }) {
                return (t, c)
            }
        }
        return nil
    }

    /// The wire verb's ONE home (`clip.getPlayedPitch`, C-0c, design §4.5):
    /// every check, the fetch, and the build — collapsing to the ONE line
    /// `PitchPlayedLine.make`'s own doc promises, so a second curve-building
    /// path (this item's planted defect: building a curve WITHOUT the clip's
    /// transpose) has nowhere to hide.
    ///
    /// ⛔ **NO PITCH DETECTION.** Never calls `detectClipPitch` — the
    /// in-process editor's own live window-detection detour
    /// (`fallback:`) exists so a drag has something to draw before the seam
    /// answers; the wire has no live drag to serve, and `clip.setNotePitch`'s
    /// own rule (this file's header) is that a clip with no STORED table
    /// gets a teaching refusal, never a detour that mints one from a live
    /// detect. So `fallback` is always `nil` here: whenever the seam's own
    /// contour is not `.detected`, the returned line is an honest
    /// `.estimate` with **no sung points at all** (`runs == []`), not a
    /// fabricated one. The seam's own WHOLE-FILE contour
    /// (`renderPitchContour`, called below) is a DIFFERENT thing and IS
    /// called — it is the same cached analysis the render itself shapes
    /// against, not per-call wire detection — and MAY compute and cache that
    /// analysis on first use, which can be slow (an on-device model pass
    /// over the whole source file): a caller's FIRST `clip.getPlayedPitch`
    /// on a clip is not a cheap read.
    ///
    /// Honest failures, checked BEFORE that possibly-slow fetch:
    ///  * a missing clip → `clipNotFound`;
    ///  * a MIDI clip → `pitchDetectionRequiresAudioClip` (this verb answers
    ///    "what will this clip's EDITS sound like," and a MIDI note already
    ///    has a definite pitch — nothing to shape);
    ///  * a clip with NO stored note table (`clip.pitchEdits == nil` or
    ///    empty) → a teaching `invalidClipEdit`. This verb reads back what
    ///    `clip.autoCorrectPitch` / `clip.setNotePitch` already did — there
    ///    is nothing to verify on a clip nothing has touched yet, and a
    ///    caller wanting the plain sung pitch with no edits at all already
    ///    has `clip.detectPitch`.
    ///
    /// STRICTLY READ-ONLY — the `clip.getPitchEdits` idiom: no `performEdit`,
    /// no engine mutation, no undo entry, no `requireNotCompMember` (reading
    /// a comp member's played line is harmless; only writing to one is
    /// gated).
    ///
    /// Returns the line PLUS the clip's own source window, so the wire can
    /// fill in an omitted `fromSeconds`/`durationSeconds` the same way
    /// `clip.detectPitch` does, without this call reaching back into the
    /// store a second time.
    public func playedPitchLine(clipId: UUID) async throws -> (line: PitchPlayedLine, sourceWindow: Range<Double>) {
        guard let (t, c) = locateClipIndexForRenderContour(clipId) else {
            throw ProjectError.clipNotFound(clipId)
        }
        guard !tracks[t].clips[c].isMIDI else {
            throw ProjectError.pitchDetectionRequiresAudioClip(clipId)
        }
        guard let edits = tracks[t].clips[c].pitchEdits, !edits.isEmpty else {
            throw ProjectError.invalidClipEdit(
                "This clip has no pitch edits yet, so there is nothing for clip.getPlayedPitch "
                    + "to read back — it shows what clip.autoCorrectPitch / clip.setNotePitch "
                    + "already did, not a general-purpose pitch reader. Run clip.autoCorrectPitch "
                    + "first (or call clip.detectPitch to hear the plain sung pitch with no edits "
                    + "at all).")
        }

        let inputs = await renderPitchContour(clipId: clipId)
        // Re-locate: the await above opened a gap a concurrent edit could
        // have used to remove the clip (spec §8 risk 7, the race every async
        // store op here names) — read the CURRENT clip, not a stale copy.
        guard let (t2, c2) = locateClipIndexForRenderContour(clipId) else {
            throw ProjectError.clipNotFound(clipId)
        }
        let clip = tracks[t2].clips[c2]
        let window = PitchPlayedLine.sourceWindow(of: clip, tempoMap: transport.tempoMap)
        let line = PitchPlayedLine.make(inputs: inputs, clip: clip, tempoMap: transport.tempoMap)
        return (line, window)
    }
}
