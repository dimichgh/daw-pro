import Foundation

// m23-ap C-0 — THE PITCH LINE THE RENDER WILL ACTUALLY PLAY.
//
// Design: `docs/design/2026-09-24-pitch-editor-timing-and-freehand.md` §4.
//
// ═══════════════════════════════════════════════════════════════════════════
// ⛔ WHY THIS TYPE EXISTS: THE PICTURE DISAGREED WITH THE SOUND, SEEN BY EYE
// ═══════════════════════════════════════════════════════════════════════════
//
// A note dragged up a semitone drew as an EMPTY bar on its new row while its
// wobble — the sung pitch line — stayed behind inside the dashed ghost on the
// old row. The audio played that wobble at the new pitch. Three causes, one
// fix each, all in this file:
//
//  1. The editor drew the DETECTED contour (what the singer did). It now draws
//     `playedMidi = sungMidi + curve.semitones(atSourceSecond:)` — what the
//     render transposes the singer TO.
//  2. The editor ignored the clip's whole-clip transpose. The render's curve
//     SUBSUMES it (`PitchCorrectionCurve`, term 1), so the same expression
//     that fixes (1) fixes this too.
//  3. The editor's line came from a different ANALYSIS than the render's (a
//     clip-window detection vs the whole-file contour). The line is now drawn
//     from `PitchRenderContour` — THE seam the render shapes against — and
//     only falls back to the window detection, SAID OUT LOUD as an estimate,
//     when the seam has no frames.
//
// ⭐ **ONE CURVE, NOT TWO THAT AGREE MOST OF THE TIME.** `curve` is built by
// `PitchRenderContour.curve(editSet:clipPitchShiftSemitones:)` for EVERY
// contour case — the function `StretchCurvePlan.make` builds the render's
// curve through — and `PitchEditorDisplayMatchesRenderTests` asserts the two
// curve OBJECTS are equal (`PitchCorrectionCurve` is `Equatable` over its
// spans), for `.detected`, `.analysisVersionMismatch` and `.unavailable`.

/// The pitch line a clip will PLAY, frame by frame, after every edit — the
/// render's own contour passed through the render's own curve.
///
/// Pure and headless: the pitch editor draws it, and the wire verb
/// `clip.getPlayedPitch` (C-0c) returns it, so a person and an agent see ONE
/// line (§4.5).
public struct PitchPlayedLine: Sendable, Equatable {

    /// Where the SUNG half of the line came from.
    public enum Basis: Sendable, Equatable {
        /// The seam answered `.detected`: the line is the render's own
        /// contour, frame for frame.
        case render
        /// The seam had no frames (not answered yet, another detector
        /// generation, or analysis failed). The line is drawn from the editor's
        /// own window detection — an honest picture of the sung audio, but NOT
        /// the analysis the render shapes against. `reason` is the novice
        /// sentence a surface must show beside it.
        case estimate(reason: String)

        /// `"render"` / `"estimate"` — a stable machine tag for echoes and the
        /// wire. Additive only, never renamed.
        public var key: String {
            switch self {
            case .render: return "render"
            case .estimate: return "estimate"
            }
        }

        /// The estimate's reason, or `nil` for `.render`.
        public var reason: String? {
            if case .estimate(let reason) = self { return reason }
            return nil
        }
    }

    /// One drawn frame.
    public struct Point: Sendable, Equatable {
        /// The frame's CENTRE, source-file seconds: `frame.timeSeconds +
        /// PitchRenderContour.frameValueOffsetSeconds`. ⚠️ **NOT the frame
        /// start** that `ClipPitchFrame.timeSeconds` and
        /// `PitchEditorContourPoint.sourceSeconds` carry — the render places
        /// each detector value at the frame centre (a MEASURED 8.58 ms lead,
        /// `PitchCorrectionCurve.make`'s doc), and evaluating the curve
        /// anywhere else draws an interpolated shaping value the render never
        /// plays.
        public var sourceSeconds: Double
        /// `W(sourceSeconds)`, the edited time a per-note retime (C2) moves this
        /// frame to. EQUAL to `sourceSeconds` until C2 lands; a surface places
        /// x from THIS field so that C2 changes one function, not every draw
        /// site.
        public var editedSeconds: Double
        /// What the singer sang at this frame, fractional MIDI.
        public var sungMidi: Double
        /// What the render plays at this frame, fractional MIDI:
        /// `sungMidi + curve.semitones(atSourceSecond: sourceSeconds)`. The
        /// clip's whole-clip transpose is INSIDE this number (the curve
        /// subsumes it).
        public var playedMidi: Double

        public init(sourceSeconds: Double, editedSeconds: Double,
                    sungMidi: Double, playedMidi: Double) {
            self.sourceSeconds = sourceSeconds
            self.editedSeconds = editedSeconds
            self.sungMidi = sungMidi
            self.playedMidi = playedMidi
        }
    }

    /// One polyline per VOICED RUN, in time order — the hole rule
    /// (`PitchAutoCorrect.voicedRuns`, its one home).
    ///
    /// ⛔ **PER RUN, NEVER PER NOTE.** A split (C3) puts two notes inside one
    /// run; drawing per note would break the line at the cut, a 16 ms hole
    /// where the singer never stopped. And never one path across an unvoiced
    /// frame: that would invent pitch where none was measured.
    public let runs: [[Point]]

    /// THE curve a render of this clip's edits plays. Equal — as an object —
    /// to the one `StretchCurvePlan.make` builds for the render.
    public let curve: PitchCorrectionCurve

    /// Where the sung half of the line came from.
    public let basis: Basis

    /// Unresolved shaping segments (they asked for a wobble change the curve
    /// could not apply) that OVERLAP the clip's source window, in table order.
    /// The subset a caption may count: a note a trim left outside the window
    /// is not on screen, and "3 notes…" must name notes a person can find.
    public let unresolvedSegmentIDsInWindow: [UUID]

    /// Every unresolved shaping segment, including ones outside the window —
    /// the curve's own list, restated for the call sites §4.2 names.
    public var unresolvedSegmentIDs: [UUID] { curve.unresolvedShapingSegmentIDs }

    public init(runs: [[Point]], curve: PitchCorrectionCurve, basis: Basis,
                unresolvedSegmentIDsInWindow: [UUID]) {
        self.runs = runs
        self.curve = curve
        self.basis = basis
        self.unresolvedSegmentIDsInWindow = unresolvedSegmentIDsInWindow
    }

    // MARK: - The words (one home, shared by the editor and the wire)

    /// The estimate reason while the seam has not answered yet (§4.3 step 3).
    public static let pendingReason = "Matching the line to the sound…"

    /// The estimate reason for a contour that is not `.detected`, or `nil` for
    /// `.detected`. Each sentence states the CONSEQUENCE, never only the cause
    /// (§4.4) — written for someone who has never used a tuner.
    ///
    /// ⚠️ "older"/"newer" is read off the two version numbers rather than
    /// assumed: a project saved by a newer build and opened in this one is a
    /// mismatch in the other direction, and "older" would then be false.
    public static func estimateReason(for contour: PitchRenderContour?) -> String? {
        switch contour {
        case nil:
            return pendingReason
        case .detected?:
            return nil
        case .analysisVersionMismatch(let editSet, let detector)?:
            let age = editSet < detector ? "an older" : "a newer"
            return "These notes were found by \(age) version of the app, so wobble changes "
                + "can't be applied to them. Pitch moves still play."
        case .unavailable(let reason)?:
            return "The app couldn't analyse this recording (\(reason)), so wobble changes "
                + "can't be applied. Pitch moves still play."
        }
    }

    /// The caption for notes the RENDER basis could not shape (fewer than two
    /// voiced frames inside the note), or `nil` for none.
    public static func unresolvedCaption(count: Int) -> String? {
        guard count > 0 else { return nil }
        if count == 1 {
            return "1 note has no steady pitch the app could hear, so its wobble setting "
                + "can't change it. Its pitch move still plays."
        }
        return "\(count) notes have no steady pitch the app could hear, so their wobble "
            + "setting can't change them. Their pitch moves still play."
    }

    /// The ONE sentence a surface shows about this line, or `nil` when there
    /// is nothing to say: the estimate's reason, else the unresolved caption.
    public var caption: String? {
        switch basis {
        case .estimate(let reason): return reason
        case .render: return Self.unresolvedCaption(count: unresolvedSegmentIDsInWindow.count)
        }
    }

    // MARK: - The one builder

    /// Build the line a render of `editSet` on this clip plays.
    ///
    /// - Parameters:
    ///   - contour: what the seam answered for this clip
    ///     (`ProjectStore.renderPitchContour(clipId:)` →
    ///     `AudioEngineControlling.renderPitchContour`), or `nil` when it has
    ///     not answered YET. ⚠️ `nil` is NOT "analysis failed" — it is
    ///     "nothing has come back", and it reads as `pendingReason`. (A
    ///     divergence from §4.2's non-optional signature, taken so the editor's
    ///     "still matching" state has a representation that no failure shares.)
    ///   - fallback: the editor's own window detection — the SUNG line
    ///     whenever the contour has no frames. `nil` with no contour frames
    ///     yields no runs at all.
    ///   - editSet: the clip's edits (`Clip.pitchEdits`, or the editor's note
    ///     table with a live draft applied). `nil` is the empty set.
    ///   - clipPitchShiftSemitones: `Clip.pitchShiftSemitones`, which the
    ///     curve SUBSUMES.
    ///   - sourceWindow: the clip's window in the SOURCE file,
    ///     `[startOffsetSeconds, + sourceWindowSeconds)`.
    ///
    /// ⛔ **THE CURVE IS BUILT FROM THE WHOLE CONTOUR, NEVER FROM A CROP.** Only
    /// the SUNG line is cropped to the window. A shaping note that straddles
    /// the window edge shapes against frames outside it — in the render, which
    /// renders the whole file — so a curve built from cropped frames would be a
    /// different curve from the one the sound was made with.
    ///
    /// **Runs first, crop second.** `voicedRuns` segments the WHOLE sung frame
    /// list, then each run's points are cropped to the window widened by one
    /// frame on each side (so the line reaches the clip's edges). Cropping
    /// first would drop the in-window stub of a note a trim cut in half
    /// whenever the stub is under `PitchAutoCorrect.minimumNoteSeconds` — and
    /// that note's BLOB still draws (the editor's overlap rule), so its line
    /// must too.
    public static func make(contour: PitchRenderContour?,
                            fallback: PitchDetectionResult?,
                            editSet: PitchEditSet?,
                            clipPitchShiftSemitones: Double,
                            sourceWindow: Range<Double>) -> PitchPlayedLine {
        let set = editSet ?? .empty
        // THE render's curve function, for every case. A non-`.detected`
        // contour has no frames and a zero offset, so this reduces to exactly
        // the render's nil-contour fallback (`StretchCurvePlan.make`). `nil`
        // (not answered yet) takes the same no-frames path.
        let curve = (contour ?? .unavailable(reason: pendingReason))
            .curve(editSet: set, clipPitchShiftSemitones: clipPitchShiftSemitones)

        let basis: Basis
        let sung: PitchDetectionResult?
        let valueOffset: Double
        if let detection = contour?.detection {
            basis = .render
            sung = detection
            // The render's own offset — read off the contour, never restated.
            valueOffset = contour?.frameValueOffsetSeconds ?? 0
        } else {
            basis = .estimate(reason: estimateReason(for: contour) ?? pendingReason)
            sung = fallback
            // "the same formula" (§4.2): half a frame at the detector's own
            // reported rate.
            let rate = fallback?.frameRateHz ?? 0
            valueOffset = rate.isFinite && rate > 0 ? 0.5 / rate : 0
        }

        let runs = sung.map {
            sungRuns(frames: $0.frames, frameRateHz: $0.frameRateHz,
                     valueOffsetSeconds: valueOffset, sourceWindow: sourceWindow, curve: curve)
        } ?? []

        let windowStart = sourceWindow.lowerBound
        let windowEnd = sourceWindow.upperBound
        let inWindow = Set(set.segments.lazy
            .filter { $0.endSeconds > windowStart && $0.startSeconds < windowEnd }
            .map(\.id))
        let unresolvedInWindow = curve.unresolvedShapingSegmentIDs.filter { inWindow.contains($0) }

        return PitchPlayedLine(runs: runs, curve: curve, basis: basis,
                               unresolvedSegmentIDsInWindow: unresolvedInWindow)
    }

    /// The sung frames as played points, one array per voiced run.
    ///
    /// The runs are `PitchAutoCorrect.voicedRuns`' — the ONE home for where the
    /// singer stops (a note can also end INSIDE a run since p2-seg; the line
    /// does not break there) — and this only gathers each run's own voiced frames
    /// (half-open `[start, end)`, the interval `voicedRuns` built from frame
    /// starts), then keeps the ones inside the widened window.
    private static func sungRuns(frames: [ClipPitchFrame], frameRateHz: Double,
                                 valueOffsetSeconds: Double, sourceWindow: Range<Double>,
                                 curve: PitchCorrectionCurve) -> [[Point]] {
        let voicedRuns = PitchAutoCorrect.voicedRuns(in: frames, frameRateHz: frameRateHz)
        guard !voicedRuns.isEmpty, frameRateHz.isFinite, frameRateHz > 0 else { return [] }
        let period = 1 / frameRateHz
        // "Cropped to the window, extended by one frame on each side" (§4.2):
        // every frame whose interval [t, t + period) meets the window, plus
        // one more on each side, so the line reaches both clip edges instead
        // of stopping a frame short of them. The view clips what overhangs.
        let keepAfter = sourceWindow.lowerBound - 2 * period    // t > keepAfter
        let keepBefore = sourceWindow.upperBound + period       // t < keepBefore
        let ordered = frames.sorted { $0.timeSeconds < $1.timeSeconds }

        var out: [[Point]] = []
        out.reserveCapacity(voicedRuns.count)
        var index = 0
        for run in voicedRuns {
            // A run wholly outside the widened window contributes nothing, so
            // it costs no curve evaluations (the frame cursor still advances
            // past it on the next run's walk — one linear pass overall).
            guard run.endSeconds > keepAfter, run.startSeconds < keepBefore else { continue }
            while index < ordered.count, ordered[index].timeSeconds < run.startSeconds {
                index += 1
            }
            var points: [Point] = []
            var scan = index
            while scan < ordered.count, ordered[scan].timeSeconds < run.endSeconds {
                let frame = ordered[scan]
                scan += 1
                guard let hz = frame.frequencyHz,
                      frame.timeSeconds > keepAfter, frame.timeSeconds < keepBefore else { continue }
                let centre = frame.timeSeconds + valueOffsetSeconds
                let sungMidi = PitchCorrectionMath.midi(fromHz: hz)
                points.append(Point(
                    sourceSeconds: centre,
                    // C2 (`PitchTimeWarp`) replaces this with W(centre).
                    editedSeconds: centre,
                    sungMidi: sungMidi,
                    playedMidi: sungMidi + curve.semitones(atSourceSecond: centre)))
            }
            index = scan
            if !points.isEmpty { out.append(points) }
        }
        return out
    }

    // MARK: - Per-note summary (the `debug.pitchEditor` spy, §4.4)

    /// What one note's slice of the played line spans.
    public struct NoteSummary: Sendable, Equatable {
        public let id: UUID
        /// Lowest / median / highest `playedMidi` among the points whose
        /// frame CENTRE lies inside the note. `nil` when the note covers no
        /// drawn point — an absence, never a 0.
        public let minMidi: Double?
        public let medianMidi: Double?
        public let maxMidi: Double?
        public let pointCount: Int

        public init(id: UUID, minMidi: Double?, medianMidi: Double?, maxMidi: Double?,
                    pointCount: Int) {
            self.id = id
            self.minMidi = minMidi
            self.medianMidi = medianMidi
            self.maxMidi = maxMidi
            self.pointCount = pointCount
        }
    }

    /// One summary per segment, in the order given. Attribution is by frame
    /// CENTRE in `[startSeconds, endSeconds)`; the note builders cut a run into
    /// parts at frame STARTS (`PitchNoteSplitter`), so a part's centres all sit
    /// inside the segment built from it and an untouched note owns exactly its
    /// own frames.
    public func noteSummaries(for segments: [NoteSegment]) -> [NoteSummary] {
        let points = runs.joined().sorted { $0.sourceSeconds < $1.sourceSeconds }
        return segments.map { segment in
            // Binary search for the first point at or after the start.
            var low = 0
            var high = points.count
            while low < high {
                let mid = (low + high) / 2
                if points[mid].sourceSeconds < segment.startSeconds { low = mid + 1 } else { high = mid }
            }
            var played: [Double] = []
            var index = low
            while index < points.count, points[index].sourceSeconds < segment.endSeconds {
                played.append(points[index].playedMidi)
                index += 1
            }
            return NoteSummary(id: segment.id,
                               minMidi: played.min(),
                               medianMidi: PitchCorrectionMath.median(played),
                               maxMidi: played.max(),
                               pointCount: played.count)
        }
    }

    // MARK: - The one-line door for the wire verb (C-0c)

    /// The clip's window in its SOURCE file, `[startOffsetSeconds,
    /// startOffsetSeconds + sourceWindowSeconds)` — total for any clip (a
    /// non-finite or negative span collapses to an empty range rather than
    /// trapping `..<`).
    public static func sourceWindow(of clip: Clip, tempoMap: TempoMap) -> Range<Double> {
        let start = clip.startOffsetSeconds.isFinite ? clip.startOffsetSeconds : 0
        let span = clip.sourceWindowSeconds(tempoMap: tempoMap)
        let end = span.isFinite && span > 0 ? start + span : start
        return start..<end
    }

    /// `make` for a clip as the store holds it — what `clip.getPlayedPitch`
    /// calls in ONE line after `ProjectStore.renderPitchContour(clipId:)`:
    /// the clip's own edits, its own transpose and its own window.
    public static func make(inputs: PitchRenderInputs, clip: Clip, tempoMap: TempoMap,
                            fallback: PitchDetectionResult? = nil) -> PitchPlayedLine {
        make(contour: inputs.contour, fallback: fallback, editSet: clip.pitchEdits,
             clipPitchShiftSemitones: clip.pitchShiftSemitones,
             sourceWindow: sourceWindow(of: clip, tempoMap: tempoMap))
    }

    // MARK: - Bounding a response (the wire verb's own concern, C-0c §4.5)

    /// `clip.getPlayedPitch`'s default cap — the design's own number: "a
    /// 5-minute vocal is ~18,900 frames," so the DEFAULT whole-clip call on a
    /// real take decimates. Never silent: see `ResponseWindow`.
    public static let defaultMaxPoints = 2000

    /// A caller asking for more than this almost certainly meant something
    /// else (the `retuneMs`/`maxSlices` precedent for a LOUD range error
    /// rather than a silent clamp) — comfortably over a dense multi-run
    /// 15-minute take (~56,000 frames at 62.5 fps) with headroom to spare.
    public static let maxPointsHardCap = 100_000

    /// One bounded slice of `runs`, ready for the wire — points optionally
    /// narrowed to a caller's window, then decimated to at most `maxPoints`.
    public struct ResponseWindow: Sendable, Equatable {
        /// The (possibly windowed, possibly decimated) runs. Never drops a
        /// RUN that had at least one point in scope — only points within it.
        public let runs: [[Point]]
        /// Points actually returned, summed across `runs`.
        public let pointCount: Int
        /// Points that were IN SCOPE (after windowing, before decimation) —
        /// `pointCount < totalPointCount` is the honest "this was decimated"
        /// signal a caller can check without trusting the flag alone.
        public let totalPointCount: Int
        /// `true` iff decimation actually dropped points. NEVER silent: a
        /// caller asserting the physics of an edit must be able to tell "no
        /// gap here" from "I only sent you every Nth point."
        public let decimated: Bool
        /// The EFFECTIVE window applied, SOURCE-FILE-absolute seconds —
        /// always finite and always reported, even when the caller supplied
        /// neither bound (then it echoes the clip's own full window).
        public let fromSeconds: Double
        public let durationSeconds: Double
    }

    /// Build the wire's `ResponseWindow` over `runs`.
    ///
    /// ⛔ **FILTERS ONLY WHEN THE CALLER ASKED.** `sungRuns` deliberately keeps
    /// one frame of overhang past each clip edge (§4.2's "extended by one
    /// frame on each side," so the line reaches both edges on screen) — a
    /// default that silently re-cropped to `clipWindow` would throw those
    /// points away and stop matching `PitchPlayedLine.make`'s own output,
    /// which is exactly the "a second path can't pass" defect this type
    /// exists to prevent one call up. So: neither bound given → `runs`
    /// verbatim, no window arithmetic at all. Either bound given → filtered
    /// to `[effective lower, effective upper)`, where an OMITTED bound fills
    /// from `clipWindow` (the `clip.detectPitch` fromSeconds/durationSeconds
    /// default-filling idiom, restated here since this method has no clip of
    /// its own to ask).
    ///
    /// **Decimation is independent of windowing and always evaluated**
    /// (never skipped just because a window was given — "a window gives full
    /// resolution" in the common case is a CONSEQUENCE of a window usually
    /// having fewer points than `maxPoints`, not a separate code path that
    /// disables the cap). Stride is constant across the whole response
    /// ("decimates evenly"); every non-empty run keeps its first point
    /// (index 0 survives any stride) and its last (forced back in if the
    /// stride skipped it) — decimation thins a run, it never erases one, so
    /// a caller can always tell "this run has no data here" from "the reply
    /// only sent every Nth point."
    public func responseWindow(fromSeconds: Double?, durationSeconds: Double?,
                               clipWindow: Range<Double>, maxPoints: Int) -> ResponseWindow {
        let requestedWindow = fromSeconds != nil || durationSeconds != nil
        let effectiveLower = fromSeconds ?? clipWindow.lowerBound
        let effectiveUpper = durationSeconds.map { effectiveLower + $0 } ?? clipWindow.upperBound

        let scoped: [[Point]]
        if requestedWindow {
            scoped = runs
                .map { $0.filter { $0.sourceSeconds >= effectiveLower && $0.sourceSeconds < effectiveUpper } }
                .filter { !$0.isEmpty }
        } else {
            scoped = runs
        }

        let totalPointCount = scoped.reduce(0) { $0 + $1.count }
        let cap = max(1, maxPoints)
        let reportedFrom = effectiveLower
        let reportedDuration = max(0, effectiveUpper - effectiveLower)
        guard totalPointCount > cap else {
            return ResponseWindow(runs: scoped, pointCount: totalPointCount,
                                  totalPointCount: totalPointCount, decimated: false,
                                  fromSeconds: reportedFrom, durationSeconds: reportedDuration)
        }

        let stride = Int((Double(totalPointCount) / Double(cap)).rounded(.up))
        let decimatedRuns = scoped.map { run -> [Point] in
            guard stride > 1, !run.isEmpty else { return run }
            var kept = run.enumerated().compactMap { $0.offset % stride == 0 ? $0.element : nil }
            if let last = run.last, kept.last?.sourceSeconds != last.sourceSeconds {
                kept.append(last)
            }
            return kept
        }
        let pointCount = decimatedRuns.reduce(0) { $0 + $1.count }
        return ResponseWindow(runs: decimatedRuns, pointCount: pointCount,
                              totalPointCount: totalPointCount, decimated: true,
                              fromSeconds: reportedFrom, durationSeconds: reportedDuration)
    }
}
