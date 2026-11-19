import AVFAudio
import CryptoKit
import DAWCore
import Foundation

// m23-q Phase 1 — THE TWO THINGS THE RENDER PATH OWNS THAT THE MODEL
// DELIBERATELY DOES NOT: the OUTPUT-FRAME ↔ SOURCE-SECOND mapping, and the
// deterministic digest that puts a clip's pitch edits into the render cache's
// identity.
//
// `PitchCorrection.swift`'s banner states the split: the model is authoritative
// in SOURCE-FILE SECONDS and offers no output-frame overload, because
// converting between the two needs the stretch schedule AND the curve latency,
// and a model that knew about both would be a second place that believes it
// owns the mapping. This file is that one place.

/// The mapping between a stretch render's DELIVERED OUTPUT FRAMES and the
/// SOURCE-FILE SECONDS a `PitchCorrectionCurve` is defined in.
///
/// **The derivation, in full, because every term is load-bearing:**
///
///  1. `StretchRenderCache` renders the WHOLE source file, never a clip window
///     (spec §3 — that is what makes a split clip share one phase-coherent
///     render and clip geometry never invalidate a key). So the render's input
///     frame 0 IS source-file second 0, and `Clip.startOffsetSeconds`,
///     `startBeat` and `lengthBeats` do not enter here at all.
///  2. `OfflineStretcher`'s alignment contract: delivered output frame 0
///     corresponds to input frame 0, and the output is exactly
///     `round(inputFrames × ratio)` frames.
///  3. The ratio is CONSTANT across the render (per-note timing is phase 3 and
///     is explicitly unread today), so the schedule is uniform: delivered
///     output frame `f` is fed by input frame `f / ratio`. ⚠️ m23-ap C2-1
///     added the representation (`PitchTimeWarp`) and the digest's time-warp
///     block, and this is STILL true after it: nothing here builds a W yet.
///     C2-3 makes this step read `W⁻¹(f / (ratio × sampleRate))` (timing
///     design §3.4 step 2), keeping today's expression verbatim as the
///     untimed branch.
///  4. The render runs at the SOURCE file's sample rate (the CAF is written at
///     `format.sampleRate`), so input frame `f / ratio` is source second
///     `f / (ratio × sampleRate)`.
///
/// Drop the ratio from step 3 — the single most likely mistake here — and a
/// correction asked for at source second 1.0 lands at output second 1.0 on a
/// half-speed render instead of 2.0. `PitchCurveRenderTests` renders exactly
/// that case at ratio 2 and measures where the pitch actually moves.
struct StretchCurvePlan: Sendable {
    /// **Does the render read the time warp W?** `false`: step 3 above is
    /// still `f / ratio`, and no render builds a W.
    ///
    /// ⚠️ **C2-3 FLIPS THIS IN THE SAME DIFF THAT MAKES STEP 3 READ W.** The
    /// bridge's time base (`RenderTimeBase`) reads it (p2-ren Stage A). While it
    /// is false, a timing-only edit re-keys the render but renders the same
    /// audio, so a pending clip may play its previous file, which is exact.
    /// Once W is read, a different W is a different time base, and the clip is
    /// silent while its render is pending, as every clip was before the bridge.
    /// Leave it false after C2-3 and the bridge would play the OLD timing for
    /// a moment and call it the previous version: right speed, wrong place.
    static let readsTimeWarp = false

    /// The SOURCE file's sample rate — the rate the render runs at.
    let sampleRate: Double
    /// `Clip.stretchRatio`: output duration multiplier.
    let ratio: Double
    /// The evaluator. Already carries the clip's whole-clip
    /// `pitchShiftSemitones`, which it SUBSUMES (design §6.4/§7.8: no second
    /// whole-clip pitch path) — so a renderer driven by this plan must NOT
    /// also pass `semitones:` to the stretcher.
    let curve: PitchCorrectionCurve
    /// Natural tuning §1(b): `PitchEditSet.engagesFormantCurve` of the set
    /// this plan was made from, THE ONE PREDICATE, read once in `make`.
    /// `formantCurve(formantPreserve:)` builds nothing unless it holds, so a
    /// legacy set's render never enters the formant branch.
    let engagesFormantCurve: Bool

    /// Step 4 above, for a render that holds a plan. It forwards to the static
    /// form below, which is the ONLY expression of the mapping.
    func sourceSecond(forOutputFrame frame: Int) -> Double {
        Self.sourceSecond(forOutputFrame: frame, ratio: ratio, sampleRate: sampleRate)
    }

    /// Step 4 above, and the ONLY expression of it. It is static because a
    /// render that builds NO plan still needs it: I7a's level mask runs on a
    /// level-only render (no curve, no stretcher) and on a stretched clip
    /// whose edits bend no pitch. C2-3 makes this W-aware, once, for both.
    static func sourceSecond(forOutputFrame frame: Int, ratio: Double,
                             sampleRate: Double) -> Double {
        guard ratio > 0, sampleRate > 0 else { return 0 }
        return Double(frame) / (ratio * sampleRate)
    }

    /// The INVERSE of step 4 (I1): the first delivered output frame whose
    /// source second is at or after `sourceSecond`, for a render that holds a
    /// plan. It forwards to the static form below.
    func outputFrame(forSourceSecond sourceSecond: Double) -> Int {
        Self.outputFrame(forSourceSecond: sourceSecond, ratio: ratio, sampleRate: sampleRate)
    }

    /// The INVERSE of step 4, source second → delivered output frame, for any
    /// render, including one with no plan (a pure stretch, or a source file at
    /// ratio 1). I1's audition maps a note's span onto the frames of the file
    /// playback plays through here, and nowhere else.
    ///
    /// ⭐ **NOT A SECOND EXPRESSION OF THE MAPPING.** It is a search over
    /// `sourceSecond(forOutputFrame:ratio:sampleRate:)`: a doubling probe finds
    /// a frame at or past the target, then `firstOutputFrame(atOrAfter…)`
    /// bisects. The forward formula stays the ONLY formula, so C2-3's W makes
    /// BOTH directions W-aware by changing it once (a search needs only that
    /// the forward mapping stays monotone).
    ///
    /// Exact on every frame: `outputFrame(forSourceSecond: sourceSecond(
    /// forOutputFrame: f)) == f` (pinned at ratios 1, 1.5 and 0.5). 0 for a
    /// non-positive or NaN second and for an unusable ratio or rate;
    /// `outputFrameSearchLimit` for a second beyond it.
    static func outputFrame(forSourceSecond sourceSecond: Double, ratio: Double,
                            sampleRate: Double) -> Int {
        guard ratio > 0, sampleRate > 0, !sourceSecond.isNaN, sourceSecond > 0 else { return 0 }
        var high = 1
        while Self.sourceSecond(forOutputFrame: high, ratio: ratio, sampleRate: sampleRate)
            < sourceSecond {
            guard high <= outputFrameSearchLimit / 2 else { return outputFrameSearchLimit }
            high *= 2
        }
        return firstOutputFrame(atOrAfterSourceSecond: sourceSecond, frames: high,
                                ratio: ratio, sampleRate: sampleRate)
    }

    /// The largest frame `outputFrame(forSourceSecond:…)` answers: about 12 h
    /// at 48 kHz, past any file; it only bounds the probe on a bad input.
    static let outputFrameSearchLimit = Int(Int32.max)

    /// The first delivered output frame whose source second is at or after
    /// `sourceSecond`, or `frames` when there is none. It is a binary search
    /// over the forward mapping above (monotone in the frame), so the
    /// mapping keeps one expression and never grows an inverse.
    static func firstOutputFrame(atOrAfterSourceSecond sourceSecond: Double, frames: Int,
                                 ratio: Double, sampleRate: Double) -> Int {
        var low = 0
        var high = max(0, frames)
        while low < high {
            let mid = low + (high - low) / 2
            if Self.sourceSecond(forOutputFrame: mid, ratio: ratio, sampleRate: sampleRate)
                < sourceSecond {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    /// **I7a/U-C: THE LEVEL MASK PASS.** It multiplies each delivered output
    /// frame by `PitchEditSet.gain(atSourceSecond:)`, the ONE mask home, at
    /// the source second that frame plays, found through the one mapping
    /// above. Offline only: this runs inside `performRender`'s detached job,
    /// never on the render thread.
    ///
    /// ⭐ **ONLY FRAMES INSIDE A LEVEL-EDITED NOTE ARE VISITED, AND A FRAME
    /// WHOSE MASK IS 1 IS NOT WRITTEN.** Outside those notes the mask is the
    /// literal 1.0 (`PitchNoteLevelTests` pins that bit for bit, including an
    /// untouched note that abuts a cleared one). So every other sample keeps
    /// its bytes by construction, not because `x × 1.0 == x` happens to hold.
    ///
    /// Denormal guard: a product below `Float.leastNormalMagnitude` is
    /// flushed to +0. That can only happen where the mask is below 1, and it
    /// keeps a faded or levelled tail from carrying denormals into the mixer.
    /// A cleared plateau multiplies by exactly 0, so its samples are ±0, and
    /// the flush makes them +0. They are numeric zeros either way (design
    /// §17.5: the gate is `sample == 0`, not a byte compare).
    ///
    /// No-op when the set has no level edit (`PitchEditSet.hasLevelEdits`, the
    /// one predicate), so a set nobody cleared or levelled renders byte for
    /// byte as it did before the mask existed.
    ///
    /// I1-F1: `outputFrameOffset` is the whole-file output frame of
    /// `channels[…][0]`, for a WINDOW of the render (`StretchWindow`). Every
    /// frame is still mapped as a WHOLE-FILE frame, so a window's mask is the
    /// whole-file mask's samples, not a mask of its own. 0 (the whole-file
    /// render) is the arithmetic this pass always did.
    static func applyLevelMask(_ editSet: PitchEditSet, to channels: inout [[Float]],
                               sampleRate: Double, ratio: Double,
                               outputFrameOffset: Int = 0,
                               isCancelled: () -> Bool = { false }) throws {
        guard editSet.hasLevelEdits, let count = channels.first?.count, count > 0 else {
            return
        }
        // Whole-file output frames `outputFrameOffset ..< frames` are present.
        let frames = outputFrameOffset + count
        for note in editSet.segments where note.hasLevelEdits {
            if isCancelled() { throw OfflineStretcherError.cancelled }
            var frame = max(outputFrameOffset,
                            firstOutputFrame(atOrAfterSourceSecond: note.startSeconds,
                                             frames: frames, ratio: ratio,
                                             sampleRate: sampleRate))
            while frame < frames {
                let second = sourceSecond(forOutputFrame: frame, ratio: ratio,
                                          sampleRate: sampleRate)
                guard second < note.endSeconds else { break }
                let gain = editSet.gain(atSourceSecond: second)
                if gain != 1 {
                    let factor = Float(gain)
                    let index = frame - outputFrameOffset
                    for channel in channels.indices {
                        var sample = channels[channel][index] * factor
                        if abs(sample) < Float.leastNormalMagnitude { sample = 0 }
                        channels[channel][index] = sample
                    }
                }
                frame += 1
            }
        }
    }

    /// One fade the consonant mix wrote (R1): where it is and the correlation
    /// its law used. Returned for the gates and the report; the render
    /// ignores it.
    struct ConsonantFade: Sendable, Equatable {
        /// Whole-file output frames of the fade: the frames with 0 < w < 1.
        let frames: Range<Int>
        /// True for the fade that hands over FROM the note before the region
        /// (the region's start), false for the one that hands over TO the note
        /// after it.
        let afterNote: Bool
        /// The dry/wet normalised correlation over the fade, as measured, and
        /// the value the law used (clamped to [0, 1]).
        let correlation: Double
        let rho: Double
    }

    /// **NATURAL TUNING §2 (NT-E2): THE CONSONANT MIX PASS**, the design's
    /// §2b.3 as amended by R1. Between notes the render plays the SOURCE's own
    /// samples. Each delivered output frame inside a consonant region becomes
    /// `gw·wet + gd·dry`, where `w` is `PitchConsonantRegion.tunedWeight` at
    /// the source second the frame plays (the one mapping above), and the
    /// gains are R1's power-matched law:
    ///
    ///     gw = w/n,  gd = (1 − w)/n,  n = √(w² + (1 − w)² + 2ρ·w·(1 − w))
    ///
    /// `ρ` is the dry/wet normalised correlation MEASURED over that one fade's
    /// frames (channels pooled), clamped to [0, 1]; silence on either side
    /// reads 1. It is the MATH of `ProvisionalRender.crossfade`, copied, not
    /// called (that one ramps linearly over a frame count). After a moved note
    /// the tuned gap is the source with per-bin phase rotations (R1), so ρ runs
    /// from about 1 (clean history: `n` = 1, equal gain) to 0 (`n` =
    /// √(w² + (1 − w)²), equal power), and the fade keeps the sides' power
    /// either way.
    ///
    /// ⭐ **THE BYTE CLAIMS HOLD BY CONSTRUCTION, NOT BY ARITHMETIC:**
    ///  * only frames inside a region are visited, and a frame whose weight is
    ///    1 (a note's own edge sample, where the ramp starts) is never written,
    ///    so every note sample keeps its bytes (gate G-C2);
    ///  * a frame whose weight is 0 is the dry sample COPIED, not computed, so
    ///    a gap beyond its fades is the source's bytes (G-C1);
    ///  * only a fade frame (0 < w < 1) is computed. A result below
    ///    `Float.leastNormalMagnitude` is flushed to +0 (the level mask's
    ///    guard), and a non-finite blend (a NaN or ∞ on the wet side) plays
    ///    the dry sample.
    ///
    /// ⛔ **RUN IT BEFORE `applyLevelMask`, NEVER AFTER.** A cleared, untouched
    /// sound sits inside a region (w 0) AND under the level mask (gain 0). Mix
    /// then mask: silence, as the user asked. Mask then mix: the dry source is
    /// written back over the silenced frames, and the cleared breath plays.
    ///
    /// ⚠️ ρ belongs to the WHOLE fade. A window render must hand this pass
    /// every fade it touches in full, or a cut fade's gains differ from the
    /// whole-file render's; `StretchRenderCache.renderAudio` widens its window
    /// for that.
    ///
    /// `regions` is `PitchEditSet.consonantRegions()`, taken ONCE by the
    /// caller (the set-level `tunedWeight` searches the table on every call).
    /// The tail's `+infinity` end is clamped to the frames present. `dry` is
    /// the source at the SAME whole-file frames as `wet`: the caller gates on
    /// `consonantMixActive` (ratio 1, 0 st), where output frame `f` plays
    /// source frame `f`. Offline only (the detached render job, never the
    /// render thread); cost O(region frames).
    @discardableResult
    static func applyConsonantMix(_ regions: [PitchConsonantRegion],
                                  wet: inout [[Float]], dry: [[Float]],
                                  sampleRate: Double, ratio: Double,
                                  outputFrameOffset: Int = 0,
                                  isCancelled: () -> Bool = { false }) throws -> [ConsonantFade] {
        guard !regions.isEmpty, let count = wet.first?.count, count > 0 else { return [] }
        guard dry.count == wet.count, wet.allSatisfy({ $0.count == count }),
              dry.allSatisfy({ $0.count == count }) else {
            throw OfflineStretcherError.invalidInput("consonant mix: the dry audio is not the tuned audio's shape")
        }
        // Whole-file output frames `outputFrameOffset ..< frames` are present.
        let frames = outputFrameOffset + count
        var fades: [ConsonantFade] = []
        for region in regions {
            if isCancelled() { throw OfflineStretcherError.cancelled }
            let lo = max(outputFrameOffset,
                         firstOutputFrame(atOrAfterSourceSecond: region.startSeconds,
                                          frames: frames, ratio: ratio, sampleRate: sampleRate))
            let hi = region.endSeconds.isFinite
                ? firstOutputFrame(atOrAfterSourceSecond: region.endSeconds, frames: frames,
                                   ratio: ratio, sampleRate: sampleRate)
                : frames
            guard hi > lo else { continue }
            // A frame before the region's midpoint belongs to the fade FROM the
            // note before it, the rest to the fade TO the note after it (the
            // half-region clamp keeps the two ramps apart). The tail's midpoint
            // is +infinity: it has only the first kind.
            let midpoint = region.startSeconds + region.durationSeconds / 2
            // Where the weight can be off 0: the ramp at each end that meets a
            // note, `region.fadeSeconds` long (DAWCore's own clamped ramp, the
            // frames R1's ρ is measured over), with one frame of margin for
            // rounding. Everywhere else in a region the weight is exactly 0
            // (the mask's rule), so those frames are the dry copy, in bulk.
            // `tunedWeight` still decides every frame inside a ramp window.
            let fade = region.fadeSeconds
            var ramps: [Range<Int>] = []
            if region.followsNote, fade > 0 {
                let end = firstOutputFrame(atOrAfterSourceSecond: region.startSeconds + fade,
                                           frames: frames, ratio: ratio, sampleRate: sampleRate) + 1
                ramps.append(lo..<max(lo, min(hi, end)))
            }
            if region.precedesNote, fade > 0, region.endSeconds.isFinite {
                let start = firstOutputFrame(atOrAfterSourceSecond: region.endSeconds - fade,
                                             frames: frames, ratio: ratio, sampleRate: sampleRate) - 1
                let from = min(hi, max(lo, start))
                if let previous = ramps.last, from <= previous.upperBound {
                    ramps[ramps.count - 1] = previous.lowerBound..<hi
                } else {
                    ramps.append(from..<hi)
                }
            }
            // Pass 1: each fade's correlation.
            var cross = [0.0, 0.0], dryPower = [0.0, 0.0], wetPower = [0.0, 0.0]
            var first = [Int.max, Int.max], last = [Int.min, Int.min]
            for frame in ramps.joined() {
                let second = sourceSecond(forOutputFrame: frame, ratio: ratio, sampleRate: sampleRate)
                let w = region.tunedWeight(atSourceSecond: second)
                guard w > 0, w < 1 else { continue }
                let side = second < midpoint ? 0 : 1
                let index = frame - outputFrameOffset
                for channel in wet.indices {
                    let d = Double(dry[channel][index]), x = Double(wet[channel][index])
                    guard d.isFinite, x.isFinite else { continue }
                    cross[side] += d * x
                    dryPower[side] += d * d
                    wetPower[side] += x * x
                }
                first[side] = min(first[side], frame)
                last[side] = max(last[side], frame)
            }
            var rho = [1.0, 1.0]
            for side in 0..<2 where first[side] <= last[side] {
                let denominator = (dryPower[side] * wetPower[side]).squareRoot()
                let correlation = denominator > 1e-20 ? cross[side] / denominator : 1
                rho[side] = min(1, max(0, correlation))
                fades.append(ConsonantFade(frames: first[side]..<(last[side] + 1),
                                           afterNote: side == 0, correlation: correlation,
                                           rho: rho[side]))
            }
            // Pass 2: the mix. Between the ramp windows, the dry copy in bulk.
            // Inside them, w == 1 is never written and w == 0 is the dry copy.
            var cursor = lo
            for ramp in ramps + [hi..<hi] {
                if ramp.lowerBound > cursor {
                    let a = cursor - outputFrameOffset, b = ramp.lowerBound - outputFrameOffset
                    for channel in wet.indices { wet[channel][a..<b] = dry[channel][a..<b] }
                }
                cursor = max(cursor, ramp.upperBound)
                for frame in ramp {
                    let second = sourceSecond(forOutputFrame: frame, ratio: ratio, sampleRate: sampleRate)
                    let w = region.tunedWeight(atSourceSecond: second)
                    guard w.isFinite, w < 1 else { continue }
                    let index = frame - outputFrameOffset
                    guard w > 0 else {
                        for channel in wet.indices { wet[channel][index] = dry[channel][index] }
                        continue
                    }
                    let r = rho[second < midpoint ? 0 : 1]
                    let norm = (w * w + (1 - w) * (1 - w) + 2 * r * w * (1 - w)).squareRoot()
                    let wetGain = Float(w / norm), dryGain = Float((1 - w) / norm)
                    for channel in wet.indices {
                        let d = dry[channel][index]
                        var sample = dryGain * d + wetGain * wet[channel][index]
                        if !sample.isFinite { sample = d }
                        if abs(sample) < Float.leastNormalMagnitude { sample = 0 }
                        wet[channel][index] = sample
                    }
                }
            }
        }
        return fades
    }

    /// **THE RENDER'S `D`: the source file's duration that `PitchTimeWarp` is
    /// pinned to** (m23-ap C2-1; timing design §3.2, "Why D is a parameter").
    ///
    /// ONE expression, `Double(file.length) / file.processingFormat.sampleRate`.
    /// It is the one `AudioFileImporter.audioFileInfo(at:)` computes
    /// `durationSeconds` with, which is what the store and the editor read
    /// through `media`. `PitchCurveRenderTests` pins the two BIT-identical on
    /// fixture files. If they ever differ, the display's W and the render's W
    /// differ in their last piece.
    ///
    /// ⚠️ **C2-3 MUST call this in `performRender`, on the reader it already
    /// opened, and must not write its own.** In particular it must not use
    /// the count of frames the read loop delivered: `AVAudioFile.read(into:)`
    /// can return short, and that count is not the file's `length`.
    static func sourceDurationSeconds(of file: AVAudioFile) -> Double {
        let sampleRate = file.processingFormat.sampleRate
        return sampleRate > 0 ? Double(file.length) / sampleRate : 0
    }

    /// What the stretcher should be transposing by at a delivered output frame.
    /// Total: the curve's own evaluator clamps non-finite inputs and results
    /// back to the clip's constant shift, so this can never hand a NaN to
    /// `css_set_transpose_semitones`.
    func semitones(atOutputFrame frame: Int) -> Double {
        curve.semitones(atSourceSecond: sourceSecond(forOutputFrame: frame))
    }

    /// Natural tuning §1(b): the formant shift (semitones relative to the
    /// SOURCE envelope) the stretcher should apply at a delivered output
    /// frame, through the same one mapping as the transpose. Total: the
    /// evaluator returns the clip term for non-finite input. `formantPreserve`
    /// is `Clip.formantPreserve`, which the curve deliberately does not store.
    func formantSemitones(atOutputFrame frame: Int, formantPreserve: Bool) -> Double {
        curve.formantSemitones(atSourceSecond: sourceSecond(forOutputFrame: frame),
                               formantPreserve: formantPreserve)
    }

    /// Natural tuning §1(b): the formant stage's f0 hint, Hz, at a delivered
    /// output frame. Never below `PitchCorrectionCurve.formantBaseFloorHz`,
    /// never 0 (R3).
    func formantBaseHz(atOutputFrame frame: Int) -> Double {
        curve.formantBaseHz(atSourceSecond: sourceSecond(forOutputFrame: frame))
    }

    /// Natural tuning §1(b): **THE PER-HOP FORMANT CURVE a render of this plan
    /// hands the curve loop**, or `nil` when the set does not
    /// `engagesFormantCurve`, and then the loop runs today's code (the one
    /// `css_set_formant_preserve(flag)` call) byte for byte.
    ///
    /// ⚠️ The clip flag is an ARGUMENT here, not a `make` parameter: `make` is
    /// called from the render, `RenderDiff` and many tests, and a defaulted
    /// flag there is one a caller can forget. Every caller that renders holds
    /// `Params.formantPreserve` and passes it; `RenderDiff` passes the same
    /// flag, so it compares what the render hands the stretcher.
    func formantCurve(formantPreserve: Bool) -> OfflineStretcher.FormantCurve? {
        guard engagesFormantCurve else { return nil }
        let plan = self
        return OfflineStretcher.FormantCurve(
            semitonesAtOutputFrame: {
                plan.formantSemitones(atOutputFrame: $0, formantPreserve: formantPreserve)
            },
            baseHzAtOutputFrame: { plan.formantBaseHz(atOutputFrame: $0) })
    }

    /// The plan for a render, or `nil` when the clip's edits bend no PITCH and
    /// the render must take the existing constant path BYTE-FOR-BYTE.
    ///
    /// I7a/U-C: the guard is `PitchEditSet.isPitchIdentity`, not `isIdentity`.
    /// A set whose only edits are levels (a cleared note, a per-note level)
    /// takes NO curve. Its level is applied afterwards by `applyLevelMask`,
    /// and on a clip that is neither stretched nor transposed the stretcher
    /// never runs at all (`performRender`'s level-only path).
    ///
    /// `contour` is what `PitchContourCache.renderContour` — THE seam — returned
    /// for this clip's source, and the curve is built through
    /// `PitchRenderContour.curve(editSet:…)` and nothing else, so the render
    /// and a display reading the same seam build the same curve.
    ///
    /// ⚠️ **`nil` IS THE PRE-CONTOUR CURVE, BIT FOR BIT.** A render that needs
    /// no contour (the whole preset ladder, generator-only edits) or whose
    /// contour is unavailable passes `nil`, and gets exactly the curve this
    /// function built before the contour reached the render:
    /// `PitchCorrectionCurve.make(editSet:clipPitchShiftSemitones:)`. Segments
    /// asking for drift/vibrato SHAPING then keep their constant offset and are
    /// named in `curve.unresolvedShapingSegmentIDs`.
    /// `NoteVibratoGeneratorTests`' render goldens stand on this branch.
    ///
    /// Natural tuning §1(b): the plan records `editSet.engagesFormantCurve`
    /// and nothing else about formants; `formantCurve(formantPreserve:)`
    /// builds the formant closures only when it holds.
    ///
    /// Natural tuning §3 (W7-C3): `separator` reaches the curve only through
    /// `contour` (a curve with no contour shapes nothing). The app passes
    /// nothing (`.production`); G3 threads a test separator here from its
    /// `StretchRenderCache` instance.
    static func make(editSet: PitchEditSet?,
                     clipPitchShiftSemitones: Double,
                     sampleRate: Double,
                     ratio: Double,
                     contour: PitchRenderContour? = nil,
                     separator: PitchCorrectionCurve.Separator = .production) -> StretchCurvePlan? {
        guard let editSet, !editSet.isPitchIdentity else { return nil }
        let curve = contour?.curve(editSet: editSet,
                                   clipPitchShiftSemitones: clipPitchShiftSemitones,
                                   separator: separator)
            ?? PitchCorrectionCurve.make(editSet: editSet,
                                         clipPitchShiftSemitones: clipPitchShiftSemitones)
        return StretchCurvePlan(sampleRate: sampleRate, ratio: ratio, curve: curve,
                                engagesFormantCurve: editSet.engagesFormantCurve)
    }

    /// Natural tuning §2b.5: why the consonant mix does not run for these
    /// render params, or nil. ⭐ A FORWARDER, NOT A SECOND RULE: the rule is
    /// DAWCore's `PitchEditSet.consonantMixInactiveReason`, because the wire
    /// (DAWControl) and the pitch editor (DAWAppKit) must call the SAME
    /// function and neither can see this type. `params.pitchEdits` is nil for
    /// a set that bends nothing (`Params.init` normalises it), so that reads
    /// nil here: nothing to stop.
    static func consonantMixInactiveReason(_ params: StretchRenderCache.Params)
        -> ConsonantMixInactiveReason? {
        params.pitchEdits?.consonantMixInactiveReason(stretchRatio: params.ratio,
                                                      clipSemitones: params.semitones)
    }

    /// Natural tuning §2b.4: the render runs the consonant mix for these
    /// params (NT-E2's `renderAudio` gate). DAWCore's
    /// `PitchEditSet.consonantMixIsActive`, forwarded, never restated.
    static func consonantMixActive(_ params: StretchRenderCache.Params) -> Bool {
        params.pitchEdits?.consonantMixIsActive(stretchRatio: params.ratio,
                                                clipSemitones: params.semitones) ?? false
    }
}

/// The deterministic content digest of a clip's pitch edits — the material
/// that puts an edit set into the render cache's key and into the playback
/// graph's schedule identity.
///
/// ⚠️⚠️ **NOT `Hashable.hashValue`, AND THAT IS THE WHOLE POINT.** Swift's
/// hashing is seeded per PROCESS: the same edit set hashes differently in the
/// next launch, so an on-disk cache keyed on it would miss forever and grow
/// without bound. This is SHA256 over the fields' raw bit patterns, which is
/// stable across launches, machines and OS versions.
///
/// ⚠️ **EVERY STORED FIELD IS HASHED, INCLUDING THE ONES NO RENDERER READS**
/// (the phase-3 timing deltas; `formantOffsetSemitones` too, which natural
/// tuning §1 now reads, and slot 7 re-keys the sets it engages). Hashing an unread
/// field costs at worst one redundant re-render when it changes; MISSING a
/// field that later becomes read costs stale audio nobody can explain.
/// `PitchCurveRenderTests.digestCoversEveryStoredField` enumerates
/// `NoteSegment`'s stored properties by REFLECTION and fails when a new one
/// appears, so the next field cannot be added without this being updated.
enum PitchEditSetDigest {
    /// Bumped when the LAYOUT below changes (field order, added field). Not a
    /// quality version — `StretchRenderCache.stretchEngineVersion` owns that.
    ///
    /// ⚠️ **STILL 1 AFTER m23-ap C5a ADDED THREE FIELDS, AND THAT IS NOT AN
    /// OVERSIGHT.** The generator's fields are hashed in a SUFFIX BLOCK that
    /// is emitted only when at least one segment actually carries a generator
    /// (`suffixMarker` below). A set without one therefore produces the SAME
    /// BYTES it produced before those fields existed, so every cache entry on
    /// every existing disk stays valid. Bumping this instead would have
    /// orphaned all of them — correct audio, but a silent re-render of every
    /// corrected vocal in every project, which is precisely the cost the
    /// "appended only when non-empty" rule was invented to avoid when
    /// `pitchEditSetHash` was first added to the key.
    ///
    /// **STILL 1 AFTER m23-ap C2-1 ADDED THE TIME-WARP BLOCK, FOR THE SAME
    /// REASON.** The block is emitted only when a set has time edits, so every
    /// untimed set keeps its bytes. See the block-order note in `hex`.
    ///
    /// **STILL 1 AFTER I7a ADDED THE LEVEL BLOCK (slot 5), AGAIN FOR THE SAME
    /// REASON.** It is emitted only when a note is cleared or levelled, so a
    /// set with neither keeps its bytes.
    ///
    /// **STILL 1 AFTER U-A ADDED THE ORIGIN BLOCK (slot 6), FOR THE SAME
    /// REASON.** It is emitted only when some segment is not `.detected`, so a
    /// set with no sound and no slide keeps its bytes.
    ///
    /// **STILL 1 AFTER NATURAL TUNING ADDED THE FORMANT BLOCK (slot 7), FOR
    /// THE SAME REASON.** It is emitted only when the set
    /// `engagesFormantCurve`, so a legacy set (no amount, every offset 0)
    /// keeps its bytes.
    ///
    /// **STILL 1 AFTER NT-C C4 ADDED THE TRANSITION BLOCK (slot 9), FOR THE
    /// SAME REASON.** It is emitted only when the set `usesSoftJoins`, so a
    /// legacy set (no slope, no width, no follow) keeps its bytes.
    ///
    /// **STILL 1 AFTER NT-C C2 ADDED THE CONSONANT BLOCK (slot 8), FOR THE
    /// SAME REASON.** It is emitted only when the set `hasConsonantMix`, so a
    /// legacy set (flag off) and a set that bends nothing keep their bytes.
    ///
    /// **STILL 1 AFTER C5b-1 ADDED THE DRAWN-SHAPE BLOCK (slot 4), FOR THE
    /// SAME REASON.** It is emitted only when some segment `hasShape`, so a
    /// set with no drawn shape keeps its bytes.
    ///
    /// **STILL 1 AFTER vf-18 APPENDED THE SLIDE-FOLLOW RULE TO SLOT 9, FOR
    /// THE SAME REASON.** It is emitted only when a set is not on the legacy
    /// rule (`slideFollowMarker`), so every legacy set keeps its bytes.
    static let layoutVersion: UInt64 = 1

    /// Introduces the generator suffix block. An arbitrary, distinctive
    /// constant; its only job is to make the suffix's presence explicit in the
    /// hashed stream rather than implied by length.
    static let suffixMarker: UInt64 = 0x5631_4252_4154_4F01

    /// Introduces the vibrato PHASE-ANCHOR block (m23-ap C5a-1,
    /// vibrato-handle design §7.5, slot 2): "A1NCHOR" plus a 01, in the style
    /// of the other markers, and distinct from all of them. `layoutVersion`
    /// stays 1 after this block too, for the generator block's reason: it is
    /// emitted only when a generated wobble carries an anchor, so every set
    /// without one keeps its bytes.
    static let anchorSuffixMarker: UInt64 = 0x4131_4E43_484F_5201

    /// Introduces the TIME-WARP block (m23-ap C2-1, timing design §3.5).
    /// Distinct from every other block's marker, so which blocks a stream
    /// carries is explicit in the stream, not implied by its length.
    static let timeWarpSuffixMarker: UInt64 = 0x5431_4D45_5752_5001

    /// Introduces the DRAWN-SHAPE block (m23-ap C5b-1, timing-and-freehand
    /// design §5.4, slot 4): "S1HAPES" plus a 01, in the style of the other
    /// markers, and distinct from every one of them.
    static let shapeSuffixMarker: UInt64 = 0x5331_4841_5045_5301

    /// Introduces the LEVEL block (I7a/U-C, interaction-batch design §17,
    /// slot 5): "L1EVELS" plus a 01, in the style of the two markers above,
    /// and distinct from both.
    static let levelSuffixMarker: UInt64 = 0x4C31_4556_454C_5301

    /// Introduces the ORIGIN block (U-A, unpitched-notes design §1.4, slot 6):
    /// "O1RIGIN" plus a 01, in the style of the markers above, and distinct
    /// from all three.
    static let originSuffixMarker: UInt64 = 0x4F31_5249_4749_4E01

    /// Introduces the FORMANT block (natural tuning §1(d), X1, slot 7):
    /// "F1ORMAN" plus a 01, in the style of the markers above, and distinct
    /// from all four.
    static let formantSuffixMarker: UInt64 = 0x4631_4F52_4D41_4E01

    /// Introduces the CONSONANT block (natural tuning §2d, X1, slot 8):
    /// "C1ONSON" plus a 01, in the style of the markers above, and distinct
    /// from all seven.
    static let consonantSuffixMarker: UInt64 = 0x4331_4F4E_534F_4E01

    /// Introduces the TRANSITION block (natural tuning §4.d, X1, slot 9):
    /// "T1RANSI" plus a 01, in the style of the markers above, and distinct
    /// from all five (the time-warp marker also starts "T1", then differs).
    static let transitionSuffixMarker: UInt64 = 0x5431_5241_4E53_4901

    /// vf-18 (W9-SLFX): introduces the SLIDE-FOLLOW RULE inside slot 9:
    /// "F1OLLOW" plus a 01, in the style of the markers above, and distinct
    /// from all of them (the formant marker also starts "F1O", then differs).
    /// Appended at the END of the transition block, and only when the set is
    /// NOT on the legacy rule, so every legacy key keeps its bytes and
    /// `layoutVersion` stays 1 (the blocks' own precedent, applied inside one).
    static let slideFollowMarker: UInt64 = 0x4631_4F4C_4C4F_5701

    /// The version of what the HOLD rule renders (its anchors and edge values,
    /// `PitchEditSet.slideAnchorCents` / `slideEdgeValueCents`): bump it when
    /// they change, so exactly the sets on that rule re-key.
    /// ⛔ NEVER `PitchEditSet.transitionRenderVersion` for that (its doc says
    /// why: it would re-key every soft set).
    static let slideFollowRuleVersion = 1

    /// Each non-legacy rule's code in the slide-follow block. ⚠️ EXPLICIT,
    /// never a case's position (the `originByte` rule): a new case picks a
    /// new code here on purpose. The legacy rule has none: it emits nothing.
    static func slideFollowRuleCode(_ rule: PitchEditSet.SlideFollowRule) -> Int? {
        switch rule {
        case .sungAtOpenSide: return nil
        case .holdAtOpenSide: return 1
        }
    }

    /// Each origin's byte in the origin block. ⚠️ **EXPLICIT, NEVER A CASE'S
    /// POSITION** (`allCases.firstIndex`): reordering `NoteOrigin`'s cases
    /// must not re-key a render, and a new case must pick a new byte here on
    /// purpose. `.detected` is 0 so a block that lists a mixed table reads
    /// "detected" by default.
    static func originByte(_ origin: NoteOrigin) -> UInt8 {
        switch origin {
        case .detected: return 0
        case .transition: return 1
        case .unpitched: return 2
        }
    }

    /// Hex digest, or `""` when the set bends nothing.
    ///
    /// **`""` for nil AND for an identity set**, which is the §6.4 rule
    /// expressed as a key: a clip carrying freshly DETECTED but unedited notes
    /// must produce the same cache key — and therefore the same render, and on
    /// an identity clip the same identity BYPASS — as a clip with no notes at
    /// all. It matches `Clip.hasPitchEdits` by construction, and a test pins
    /// that the two agree.
    static func hex(_ set: PitchEditSet?) -> String {
        guard let set, !set.isIdentity else { return "" }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(40 + set.segments.count * 112)
        func putBits(_ value: UInt64) {
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }
        func putDouble(_ value: Double) { putBits(value.bitPattern) }
        func putInt(_ value: Int) { putBits(UInt64(bitPattern: Int64(value))) }
        func putUUID(_ value: UUID) {
            withUnsafeBytes(of: value.uuid) { bytes.append(contentsOf: $0) }
        }

        putBits(layoutVersion)
        putInt(set.analysisVersion)
        putDouble(set.retuneMs)
        putInt(set.segments.count)
        for segment in set.segments {
            putUUID(segment.id)
            putDouble(segment.startSeconds)
            putDouble(segment.endSeconds)
            putDouble(segment.detectedHz)
            putDouble(segment.detectedConfidence)
            putDouble(segment.pitchOffsetCents)
            putDouble(segment.driftScale)
            putDouble(segment.vibratoScale)
            putDouble(segment.formantOffsetSemitones)
            putDouble(segment.timeStartDeltaSeconds)
            putDouble(segment.timeEndDeltaSeconds)
            putDouble(segment.amplitudeDb)
        }
        // m23-ap C5a — THE GENERATOR SUFFIX. Emitted only when at least one
        // segment carries a generator, so a legacy set hashes byte-for-byte
        // the material it always did (see `layoutVersion`). When it IS
        // emitted it covers EVERY segment's three fields, not just the ones
        // with a depth: a rate changed on a segment whose depth is zero is
        // inert TODAY, and a hash that omitted it would serve the wrong audio
        // the moment that depth became non-zero in the same edit.
        //
        // ═══════════════════════════════════════════════════════════════════
        // ⭐ THE SUFFIX BLOCKS: ONE FIXED ORDER, EACH MARKER-GATED.
        //   1. generator   (m23-ap C5a)   — below
        //   2. anchor      (C5a-1)        — below
        //   3. time warp   (C2-1)         — below
        //   4. shape       (C5b-1)        — below
        //   5. level       (I7a/U-C)      — below
        //   6. origin      (U-A)          — below
        //   7. formant     (natural tuning §1, NT-E1)             — below
        //   8. consonant   (natural tuning §2, NT-C C2)           — below
        //   9. transition  (natural tuning §4, NT-C C4)           — below
        // (vibrato-handle design §7.5; timing design §5.4; interaction-batch
        // design §17; unpitched-notes design §1.4; natural-tuning design
        // §1(d) and X1, which fixed 7/8/9 before any of them landed.) Each block is
        // emitted only when some segment uses its feature, so a block
        // inserted into its slot later changes no digest except those of the
        // sets that use it. The order is by slot, never by which item landed
        // first. A block placed out of its slot would change the digest of
        // every set that uses two of these features, relative to the order
        // both design documents fix.
        // ═══════════════════════════════════════════════════════════════════
        //
        // (1) m23-ap C5a — THE GENERATOR SUFFIX.
        if set.segments.contains(where: \.hasGeneratedVibrato) {
            putBits(suffixMarker)
            putInt(set.segments.count)
            for segment in set.segments {
                putDouble(segment.vibratoRateHz)
                putDouble(segment.vibratoDepthCents)
                putDouble(segment.vibratoOnsetSeconds)
            }
        }
        // (2) m23-ap C5a-1 — THE PHASE-ANCHOR BLOCK (vibrato-handle design
        // §7.5). Its own block, never a field inside the generator block:
        // that would change the material of every existing generator set and
        // re-render them all for no audible change. Gated on some segment
        // having a generated wobble AND a non-zero anchor, because an anchor
        // on a note with no generator changes nothing audible (the rate and
        // onset precedent), so a set with no anchor keeps its bytes. When it
        // IS emitted it covers EVERY segment's anchor, inert ones included
        // (the generator block's rule): a needless re-render is the safe
        // direction, and the editor never stores an inert anchor. Laid out
        // like its siblings: the marker, the segment count, one Double each.
        if set.segments.contains(where: {
            $0.hasGeneratedVibrato && $0.vibratoPhaseAnchorSeconds != 0
        }) {
            putBits(anchorSuffixMarker)
            putInt(set.segments.count)
            for segment in set.segments {
                putDouble(segment.vibratoPhaseAnchorSeconds)
            }
        }
        //
        // (3) m23-ap C2-1 — THE TIME-WARP BLOCK. The deltas themselves are
        // already hashed INLINE above, so this block does not carry them. Its
        // one job is the stale-key hazard (timing design F7, §3.5). A set that
        // carried non-zero deltas BEFORE C2 was rendered with them IGNORED,
        // under a key that already included them. On the day the render
        // starts reading them, that same key would serve the stale, unwarped
        // audio. This block re-keys exactly the retimed sets, including
        // those written before C2 existed, and `scheduleVersion` re-keys them
        // again whenever the warped schedule changes. `D` is NOT hashed: it
        // is a property of the source file, whose identity
        // `sourceIdentityFields(source:)` already puts in the render key.
        // Gated on `PitchEditSet.hasTimeEdits`, the one predicate.
        if set.hasTimeEdits {
            putBits(timeWarpSuffixMarker)
            putInt(PitchTimeWarp.scheduleVersion)
        }
        // (4) m23-ap C5b-1 — THE DRAWN-SHAPE BLOCK (timing-and-freehand design
        // §5.4). The shape is hashed ONLY here, never inline: inline would
        // re-key every tuned render on the machine. Gated on some segment
        // `hasShape`, the one predicate, so a set with no shape keeps its
        // bytes. Laid out as the marker, `NoteSegment.shapeRenderVersion`
        // (a change to the term's arithmetic re-keys exactly the shaped
        // renders), the number of SHAPED segments, then per shaped segment:
        // its index in `segments`, `shapeStartIndex`, the sample COUNT and
        // every sample. The count comes before the samples, so no two
        // layouts share a stream at a block boundary, and every sample is
        // hashed (hashing only the count would serve stale audio after an
        // interior edit, design §5.8 mode 2).
        if set.segments.contains(where: \.hasShape) {
            putBits(shapeSuffixMarker)
            putInt(NoteSegment.shapeRenderVersion)
            let shaped = set.segments.indices.filter { set.segments[$0].hasShape }
            putInt(shaped.count)
            for index in shaped {
                let segment = set.segments[index]
                putInt(index)
                putInt(segment.shapeStartIndex)
                putInt(segment.shapeTenthsOfCents.count)
                for sample in segment.shapeTenthsOfCents { putInt(Int(sample)) }
            }
        }
        //
        // (5) I7a/U-C — THE LEVEL BLOCK (interaction-batch design §17).
        // `amplitudeDb` is already hashed INLINE above, and it stays there:
        // moving it would re-key every set. This block carries the one level
        // field that is not inline, each segment's CLEARED byte. It also closes
        // the stale-key hazard, the time-warp block's F7 precedent. A set that
        // carried a non-zero `amplitudeDb` before U-C was rendered with it
        // IGNORED, under a key that already hashed it. On the day the render
        // reads it, that same key would serve the unlevelled audio. Gated on
        // `PitchEditSet.hasLevelEdits`, the one predicate, so it re-keys
        // exactly the cleared or levelled sets, including those written before
        // U-C. `PitchEditSet.levelMaskVersion` re-keys them again whenever the
        // mask's arithmetic changes.
        if set.hasLevelEdits {
            putBits(levelSuffixMarker)
            putInt(PitchEditSet.levelMaskVersion)
            putInt(set.segments.count)
            for segment in set.segments {
                bytes.append(segment.isCleared ? 1 : 0)
            }
        }
        // (6) U-A — THE ORIGIN BLOCK (unpitched-notes design §1.4). `origin`
        // is a `let`, never hashed inline, so this block is the only place a
        // key sees it. Gated on some segment NOT being `.detected`, so a set
        // with no sound and no slide keeps the bytes it had before the field
        // existed. An UNTOUCHED sound never reaches here on its own: a set of
        // detected notes plus untouched sounds is still identity, and digests
        // to "" above. What it does re-key is an EDITED set that gains or
        // loses sounds (one byte-identical re-render, never stale audio), and
        // the same table read as sounds versus as notes, which render
        // differently the moment either is moved.
        if set.segments.contains(where: { $0.origin != .detected }) {
            putBits(originSuffixMarker)
            putInt(set.segments.count)
            for segment in set.segments {
                bytes.append(Self.originByte(segment.origin))
            }
        }
        // (7) Natural tuning §1 — THE FORMANT BLOCK (design §1(d), X1). The
        // per-note `formantOffsetSemitones` are already hashed INLINE above
        // and stay there (moving them would re-key every set). This block
        // carries the SET-level amount and closes the stale-key hazard, the
        // time-warp block's F7 precedent: a hand-authored offset was hashed
        // but IGNORED by every render before §1, and on the day the render
        // reads it that same key would serve the unshaped audio.
        // `formantRenderVersion` re-keys exactly the engaged sets whenever the
        // base policy, the F arithmetic or the shim's semantics change (never
        // `stretchEngineVersion`, which would re-render every stretched clip).
        // The nil-flag byte keeps nil (the clip flag decides `c`) apart from
        // 0.0 (an engaged amount), which the Double alone would conflate.
        // Gated on `PitchEditSet.engagesFormantCurve`, the one predicate.
        if set.engagesFormantCurve {
            putBits(formantSuffixMarker)
            putInt(PitchEditSet.formantRenderVersion)
            bytes.append(set.formantCorrection != nil ? 1 : 0)
            putDouble(set.formantCorrection ?? 0)
        }
        // (8) Natural tuning §2 — THE CONSONANT BLOCK (design §2d, X1; NT-C
        // C2). The set-level `keepsConsonantsUntuned` is hashed ONLY here,
        // never inline. It closes the stale-key hazard, the time-warp
        // block's F7 precedent: every table seeded since NT-C C0 already
        // CARRIES the flag, rendered with it IGNORED under a key that did not
        // hash it; the day the render mixes the source back into the gaps
        // (NT-E2) this block re-keys exactly those sets.
        // `consonantMaskVersion` re-keys them again whenever the mask's
        // arithmetic changes (fade, ramp, clamp, head/tail, `joinKind` and
        // its threshold). The regions need nothing more: they are a function
        // of the note edges and origins, already hashed above.
        // Gated on `PitchEditSet.hasConsonantMix`, the one predicate, NOT on
        // the flag alone (X1's wording): a levels-only set never reaches the
        // stretcher, so the mix can never run on it and it keeps its bytes.
        // The clip conditions that stop the mix (stretched, transposed) do
        // NOT remove the block (§2d, deliberate): the key stays a function of
        // the set alone, at the cost of one redundant render when the flag is
        // toggled on a transposed clip.
        if set.hasConsonantMix {
            putBits(consonantSuffixMarker)
            putInt(PitchEditSet.consonantMaskVersion)
        }
        //
        // (9) Natural tuning §4 — THE TRANSITION BLOCK (design §4.d, X1;
        // NT-C C4). The slope, the per-note join widths and follow amounts
        // are hashed ONLY here, never inline: inline would re-key every
        // tuned render on the machine. It also closes the stale-key hazard,
        // the time-warp block's F7 precedent: tables seeded since NT-C C0
        // already CARRY a slope (and follows on slides), rendered with them
        // IGNORED under a key that did not hash them; the day the curve reads
        // them this block re-keys exactly those sets. It keys the FORMANT
        // curve's joins too (X7: it reads the same spans).
        // `transitionRenderVersion` re-keys exactly the soft sets whenever the
        // join arithmetic changes (`PitchEditSet.softJoin`, the bridge,
        // `joinKind` and its threshold). When emitted it covers EVERY
        // segment's two fields, inert ones included (the generator block's
        // rule). Gated on `PitchEditSet.usesSoftJoins`, the one predicate, so
        // a legacy set keeps its bytes; an identity set never gets here
        // (`""` above), so a fresh seeded table stays keyless.
        //
        // vf-18 (W9-SLFX): the set's SLIDE-FOLLOW RULE, appended after the
        // per-segment loop and ONLY when it is not the legacy rule (marker,
        // rule code, version). A legacy set's slot 9 is byte for byte what it
        // was, so every saved key stays valid; a set that adopts the hold rule
        // re-keys once. The rule only renders through soft joins, so a set
        // that does not `usesSoftJoins` needs no key for it.
        if set.usesSoftJoins {
            putBits(transitionSuffixMarker)
            putInt(PitchEditSet.transitionRenderVersion)
            putDouble(set.transitionSlopeCentsPerSecond)
            putInt(set.segments.count)
            for segment in set.segments {
                putDouble(segment.transitionOutMs)
                putDouble(segment.glideFollow)
            }
            if let code = Self.slideFollowRuleCode(set.slideFollowRule) {
                putBits(slideFollowMarker)
                putInt(code)
                putInt(slideFollowRuleVersion)
            }
        }
        var hasher = SHA256()
        hasher.update(data: Data(bytes))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
