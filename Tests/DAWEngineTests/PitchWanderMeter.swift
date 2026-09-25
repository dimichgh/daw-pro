import Accelerate
import DAWCore
import Foundation

@testable import DAWEngine

/// ⭐ **THE WITHIN-NOTE WANDER INSTRUMENT — ONE DEFINITION, PINNED IN CODE.**
///
/// Every "wander before → after" number this tree quotes for contour-to-render
/// comes out of THIS function: the product-path gate, the `vibratoScale: 0`
/// invariance control, the harness ≡ product comparison and the listening
/// folder's per-file figures. The README that first reported "92.8 → 18.2
/// cents" left no script behind, so that figure cannot be re-derived and is not
/// compared against; this one can be. Since p2-seg-F-metric (2026-09-24) the
/// gates score it per HELD note part, not per stored segment, with a second
/// leg for "on its own note": see `HeldPartWander` at the end of this file.
///
/// **What it measures.** For each note segment it reads the RENDERED AUDIO's f0
/// with `M23QToneTracker` — the phase-difference tracker phase 0
/// positive-controlled against signals with known answers — restricted to a
/// band of ±`bandCents` around the note's `detectedHz`, so the note's own
/// fundamental is the only partial in view (the 2nd harmonic sits 1200 cents
/// up, far outside it). It keeps the estimates whose centre falls in the note's
/// INTERIOR (`edgeMarginSeconds` in from each end, which clears the widest
/// preset ramp — Gentle's 200 ms, ±100 ms — plus half the tracker window), and
/// reports:
///
///  * `spreadCents` — the standard deviation of the note's f0 in cents about
///    its own mean. **This is "wander".** A ±A-cent sinusoidal vibrato reads
///    A/√2; a perfectly flat note reads the instrument's own floor.
///  * `iqrCents` — the interquartile range, the robust twin. Two instruments
///    disagreeing is the signal: a spread far above IQR/1.349 means a few
///    outliers, not wander.
///  * `medianHz` — the note's centre. ⚠️ Trust it on synthetic fixtures
///    only: on a low voice whose notes slide further than the band, a
///    constant shift does NOT move it by that shift (on the real dry vocal,
///    Tight's constant −36 and +40 cent offsets moved it −17 and +58, where
///    `SpectralShiftMeter` reads both within 3 cents of asked). A delivered
///    CENTRE CORRECTION is read with `SpectralShiftMeter` below.
///
/// ⚠️ **NOT SwiftF0, ON PURPOSE.** SwiftF0 reports an argmax over 25.79-cent
/// bins, so a perfectly flattened note sitting between two bins reads as a
/// ±12.9-cent flicker — the instrument would be the loudest thing in the
/// measurement. It is also the detector that BUILT the flattening, and an
/// instrument grading its own output is a closed loop.
enum PitchWanderMeter {
    struct NoteReading: Sendable {
        let segmentID: UUID
        let startSeconds: Double
        let endSeconds: Double
        let estimateCount: Int
        let medianHz: Double
        let spreadCents: Double
        let iqrCents: Double
    }

    /// 2048 at 48 kHz = 42.7 ms. Wide enough that the 2nd harmonic's leakage
    /// into the fundamental's bins is ~−55 dB (a 1024 window leaves ~−40 dB,
    /// which is a few cents of phase noise at `phaseHop`), short enough that a
    /// 5.5 Hz vibrato keeps ~95 % of its depth.
    static let windowSize = 2048
    /// Unambiguous while |f − binCentre| < sr/(2·phaseHop) = 187.5 Hz at
    /// 48 kHz — the band is a few bins wide, so this never wraps.
    static let phaseHop = 128
    /// One estimate per 5 ms at 48 kHz.
    static let estimateHop = 240
    /// ±3 semitones around `detectedHz`: room for a ±50-cent correction plus a
    /// ±100-cent vibrato plus detector error, and nowhere near the octave.
    static let bandCents = 300.0
    /// Clears Gentle's ±100 ms ramp and half the tracker window.
    static let edgeMarginSeconds = 0.10
    /// A note whose interior is shorter than this is skipped, not measured.
    static let minimumInteriorSeconds = 0.10
    static let minimumEstimates = 12

    /// Reads every measurable note. Notes too short to have an interior are
    /// SKIPPED rather than read from their ramps — the count that survives is
    /// part of the result and callers print it.
    static func readNotes(_ audio: [Float], sampleRate: Double,
                          segments: [NoteSegment]) -> [NoteReading] {
        var out: [NoteReading] = []
        for segment in segments where segment.detectedHz > 0 {
            let lo = segment.startSeconds + edgeMarginSeconds
            let hi = segment.endSeconds - edgeMarginSeconds
            guard hi - lo >= minimumInteriorSeconds else { continue }
            // Track only a slice around the interior; the estimates' centre
            // frames are shifted back into whole-file frames below.
            let pad = windowSize + phaseHop
            let sliceStart = max(0, Int(lo * sampleRate) - pad)
            let sliceEnd = min(audio.count, Int(hi * sampleRate) + pad)
            guard sliceEnd - sliceStart > windowSize + phaseHop else { continue }
            let slice = Array(audio[sliceStart..<sliceEnd])
            let band = (segment.detectedHz * pow(2, -bandCents / 1200))
                ... (segment.detectedHz * pow(2, bandCents / 1200))
            let estimates = M23QToneTracker.track(
                slice, sampleRate: sampleRate, windowSize: windowSize,
                phaseHop: phaseHop, estimateHop: estimateHop, band: band)
            let interior = estimates.filter {
                let t = (Double(sliceStart) + $0.centreFrame) / sampleRate
                return t >= lo && t <= hi && $0.hz.isFinite && $0.hz > 0
            }.map(\.hz)
            guard interior.count >= minimumEstimates else { continue }
            let sortedHz = interior.sorted()
            let medianHz = sortedHz[sortedHz.count / 2]
            let cents = interior.map { 1200 * log2($0 / medianHz) }
            let mean = cents.reduce(0, +) / Double(cents.count)
            let variance = cents.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
                / Double(cents.count)
            let sortedCents = cents.sorted()
            let q1 = sortedCents[sortedCents.count / 4]
            let q3 = sortedCents[(3 * sortedCents.count) / 4]
            out.append(NoteReading(
                segmentID: segment.id, startSeconds: segment.startSeconds,
                endSeconds: segment.endSeconds, estimateCount: interior.count,
                medianHz: medianHz, spreadCents: variance.squareRoot(),
                iqrCents: q3 - q1))
        }
        return out
    }

    /// Median of a sample; `nil` when empty.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// The per-note comparison of two renders over the SAME segments: the
    /// median wander of each, the median fraction by which `after` reduced it,
    /// and the median absolute movement of the note centre.
    struct Comparison: Sendable {
        let notes: Int
        let beforeWanderCents: Double
        let afterWanderCents: Double
        let beforeIQRCents: Double
        let afterIQRCents: Double
        /// Median over notes of (1 − after/before).
        let medianReduction: Double
        /// Median over notes of |cents(after.centre, before.centre)| — the
        /// TRACKED centre; see `medianHz` for when not to quote it.
        let medianCentreMoveCents: Double
    }

    static func compare(before: [NoteReading], after: [NoteReading]) -> Comparison? {
        let afterByID = Dictionary(after.map { ($0.segmentID, $0) },
                                   uniquingKeysWith: { a, _ in a })
        var pairs: [(NoteReading, NoteReading)] = []
        for b in before { if let a = afterByID[b.segmentID] { pairs.append((b, a)) } }
        guard !pairs.isEmpty else { return nil }
        return Comparison(
            notes: pairs.count,
            beforeWanderCents: median(pairs.map(\.0.spreadCents)) ?? 0,
            afterWanderCents: median(pairs.map(\.1.spreadCents)) ?? 0,
            beforeIQRCents: median(pairs.map(\.0.iqrCents)) ?? 0,
            afterIQRCents: median(pairs.map(\.1.iqrCents)) ?? 0,
            medianReduction: median(pairs.map {
                $0.0.spreadCents > 0 ? 1 - $0.1.spreadCents / $0.0.spreadCents : 0
            }) ?? 0,
            medianCentreMoveCents: median(pairs.map {
                abs(1200 * log2($0.1.medianHz / $0.0.medianHz))
            }) ?? 0)
    }
}


/// ⭐ **THE SECOND INSTRUMENT: the delivered TRANSPOSITION of a note between
/// two renders, read from its SPECTRUM, not from an f0 track.**
///
/// Why it exists (measured 2026-09-24 on the real dry vocal): the note-CENTRE
/// figure `PitchWanderMeter` gives — the median of a tracked f0 — is not
/// shift-equivariant on this voice. The notes sit at 81–134 Hz and many slide
/// by more than the tracker's ±300-cent band, so Tight's constant −36 and +40
/// cent offsets moved two notes' tracked medians by −17 and +58, while its
/// own median disagreed with SwiftF0's by up to 124 cents. Two instruments
/// disagreeing is the signal; this one does not track anything — and it reads
/// Tight's offsets back within 0.5 cents (median) of what the notes asked.
///
/// **What it measures.** The note interior's magnitude spectrum (one Hann
/// window over the whole interior, zero-padded to 2^17), resampled onto a
/// 1-cent log-frequency grid from 70 Hz to 4 kHz, log-compressed with a floor
/// 60 dB under its peak, mean-removed; then the lag (in cents, parabolic
/// refinement) that best aligns the second spectrum with the first. A pure
/// transposition by c cents moves EVERY partial by c on that axis, so a
/// constant-offset render reads back exactly its offset however much the note
/// slides — the slide is the same in both renders. A render that changes the
/// SHAPE (Hard Tune) reads back the best single shift, which is an honest
/// "where did the note's energy move to", not a centre.
///
/// Positive-controlled where it is used: a render of the same file
/// transposed by a known constant must read back that constant on every note.
enum SpectralShiftMeter {
    static let fftLog2 = 17
    static let lowHz = 70.0
    static let highHz = 4000.0
    static let maxLagCents = 200

    static func logSpectrum(_ x: [Float], sampleRate: Double) -> [Double] {
        let n = 1 << fftLog2
        guard x.count >= 64, x.count <= n else { return [] }
        var windowed = [Float](repeating: 0, count: n)
        var window = [Float](repeating: 0, count: x.count)
        vDSP_hann_window(&window, vDSP_Length(x.count), Int32(vDSP_HANN_NORM))
        vDSP_vmul(x, 1, window, 1, &windowed, 1, vDSP_Length(x.count))
        guard let setup = vDSP_create_fftsetup(vDSP_Length(fftLog2), FFTRadix(kFFTRadix2)) else {
            return []
        }
        defer { vDSP_destroy_fftsetup(setup) }
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(fftLog2), FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }
        mags[0] = 0  // DC and Nyquist are packed here; neither is a partial
        let peak = Double(mags.max() ?? 0)
        guard peak > 0 else { return [] }
        let floor = peak * 1e-3
        let binHz = sampleRate / Double(n)
        let count = Int(1200 * log2(highHz / lowHz))
        var out = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let pos = lowHz * pow(2, Double(i) / 1200) / binHz
            let j = Int(pos)
            guard j + 1 < mags.count else { return [] }
            let frac = pos - Double(j)
            out[i] = log(Double(mags[j]) * (1 - frac) + Double(mags[j + 1]) * frac + floor)
        }
        let mean = out.reduce(0, +) / Double(count)
        return out.map { $0 - mean }
    }

    /// Cents by which `shifted` sits above `reference` (negative = below), or
    /// `nil` when either slice is too short or silent.
    static func shiftCents(reference: [Float], shifted: [Float], sampleRate: Double) -> Double? {
        let a = logSpectrum(reference, sampleRate: sampleRate)
        let b = logSpectrum(shifted, sampleRate: sampleRate)
        guard !a.isEmpty, a.count == b.count else { return nil }
        var scores: [Double] = []
        for lag in -maxLagCents...maxLagCents {
            let lo = max(0, -lag), hi = min(a.count, b.count - lag)
            var sum = 0.0
            for k in lo..<hi { sum += a[k] * b[k + lag] }
            scores.append(hi > lo ? sum / Double(hi - lo) : -.infinity)
        }
        guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }) else { return nil }
        var refine = 0.0
        if best > 0, best < scores.count - 1 {
            let (l, c, r) = (scores[best - 1], scores[best], scores[best + 1])
            let denom = l - 2 * c + r
            if denom < 0 { refine = 0.5 * (l - r) / denom }
        }
        return Double(best - maxLagCents) + refine
    }

    /// Per measurable note (the same interior `PitchWanderMeter` reads): the
    /// spectral shift of `shifted` against `reference`.
    static func noteShifts(reference: [Float], shifted: [Float], sampleRate: Double,
                           segments: [NoteSegment]) -> [UUID: Double] {
        var out: [UUID: Double] = [:]
        for segment in segments where segment.detectedHz > 0 {
            let lo = Int((segment.startSeconds + PitchWanderMeter.edgeMarginSeconds) * sampleRate)
            let hi = Int((segment.endSeconds - PitchWanderMeter.edgeMarginSeconds) * sampleRate)
            guard hi - lo >= Int(PitchWanderMeter.minimumInteriorSeconds * sampleRate),
                  lo >= 0, hi <= reference.count, hi <= shifted.count else { continue }
            if let cents = shiftCents(reference: Array(reference[lo..<hi]),
                                      shifted: Array(shifted[lo..<hi]), sampleRate: sampleRate) {
                out[segment.id] = cents
            }
        }
        return out
    }
}


// MARK: - The held-part population and the Hard Tune gate (p2-seg-F-metric)

/// ⭐ **PER NOTE PART, NOT PER STORED SEGMENT, AND FLAT ON ITS OWN NOTE, NOT
/// MERELY FLAT** (p2-seg-F-metric, 2026-09-24). Every choice here was
/// pre-registered BEFORE the first number existed, in
/// `~/Music/DAW Pro Dogfood/2026-09-24 p2-seg physics/F-metric/PREREG.txt`.
///
/// **Why the population moved.** Note splitting (`PitchNoteSplitter`, 109b483)
/// made a stored segment a PART of a voiced run. Scored per stored segment, the
/// wander gate's population changed under it. Before the split, 11 of its 23
/// "notes" were whole multi-note runs, and their "wander" included the melody's
/// own intervals, so pinning a phrase to ONE note scored as a 70 % flattening.
/// After the split, the shipped render scored 48.8 % and the gate went red. That
/// render is bit-identical to the user's pick, which passes the pitch physics
/// (design §16.4). What had changed was the population under the gate.
///
/// The population is now the HELD parts. They are chosen from the PART TABLE:
/// `PitchNoteSplitter.parts` on the same detection, zipped bit for bit onto the
/// set's segments. They are never chosen from the edit values. A `.transition` is
/// identity under the shipped slide shape and under every preserve-vibrato
/// preset, so scoring one measures the design, not the tuning. Each unsplit run
/// is one `.held` part, so unsplit runs stay in.
///
/// **Why two legs.** Under `.runPin` every held part is flattened too, but onto
/// its RUN's note. Wander alone would score that as a win, which is the trap the
/// old metric fell into. So the Hard Tune gate is a conjunction of two legs.
///  * **Leg W (flat):** the median over measurable held parts of the per-part cut
///    `1 − spread(after) / spread(before)` must be at least `hardCutThreshold`.
///    This is `PitchWanderMeter.compare`'s `medianReduction`.
///  * **Leg N (the right note):** EVERY measurable held part's rendered pitch
///    must sit within ±`noteToleranceCents` of the nearest chromatic note to its
///    OWN sung median. The rendered pitch is the tracked median, read once the
///    note is flat. 50 c is the nearest-note boundary: the leg asks which note
///    the part plays, not how finely it is tuned.
///    `PitchWanderMeter.medianHz`'s own warning (do not trust it as a centre on
///    this voice) is about SHIFTS of notes that slide past the band. Leg N reads
///    a FLATTENED note, which has no slide. On the user's take the independent
///    YIN gives the same leg-N verdict on the product and on both plants, and
///    reads the worst part within 9 c of this instrument.
///
/// ⚠️ **The instrument's known bias, and why it fails safe here.** On the take's
/// two lowest notes (78.7 and 83.2 Hz), `PitchWanderMeter` reads about twice the
/// wobble an independent YIN sees, and it barely drops under flattening (P-L,
/// 2026-09-24). That UNDER-reads Hard Tune's cut, so a `>= threshold` gate errs
/// toward failing. The verdict without those notes (`lowNoteHz`) is logged
/// beside every run, and the YIN's own figures are in the F-metric folder.
enum HeldPartWander {
    /// Leg W's floor for Hard Tune. It is DERIVED by the pre-registered rule, not
    /// picked: take the committed product's measured cut minus 0.15, then round
    /// DOWN to a multiple of 0.05. The measurement and the derivation are in
    /// F-metric/README.txt.
    ///
    /// **Measured on 109b483, on the user's take:** 19 measurable held parts,
    /// cut 0.4900. That gives 0.4900 − 0.15 = 0.3400, rounded down to 0.30.
    /// * Leave-one-part-out moves the cut at most 0.24 points, far inside the
    ///   15-point margin.
    /// * The constant-offset fallback reads −0.011, 31 points under this floor.
    /// * `.runPin` reads 0.487 and PASSES this leg. It is leg N that must catch
    ///   it, and does: 4 held parts sit 84–455 c off their own notes.
    /// * The independent YIN reads the same Hard Tune render at 0.679 on these
    ///   parts. This instrument is the conservative one.
    static let hardCutThreshold: Double = 0.30
    /// Leg N: the nearest-note boundary, in cents.
    static let noteToleranceCents = 50.0
    /// The "must NOT flatten" ceiling, for Tight and for the constant-offset
    /// fallback.
    static let noFlatteningCeiling = 0.10
    /// Below this, `PitchWanderMeter` is known to over-read (P-L). Used for the
    /// sensitivity report only; it never changes the population.
    static let lowNoteHz = 85.0

    /// One stored segment, with the note part it was written from.
    struct Entry: Sendable {
        let index: Int
        let part: NotePart
        let segment: NoteSegment
    }

    /// `set`'s segments zipped onto `parts`: the splitter's parts of the SAME
    /// detection the set was built from. The zip is a precondition, not a hope,
    /// so a pair that does not match bit for bit on start, end and centre
    /// returns a reason instead of entries.
    static func table(of set: PitchEditSet, parts: [NotePart]) -> (entries: [Entry], mismatch: String?) {
        guard parts.count == set.segments.count else {
            return ([], "\(parts.count) note parts but \(set.segments.count) stored segments")
        }
        var entries: [Entry] = []
        for (index, (part, segment)) in zip(parts, set.segments).enumerated() {
            guard part.startSeconds.bitPattern == segment.startSeconds.bitPattern,
                  part.endSeconds.bitPattern == segment.endSeconds.bitPattern,
                  part.centreHz.bitPattern == segment.detectedHz.bitPattern else {
                return ([], "part \(index) is not segment \(index)")
            }
            entries.append(Entry(index: index, part: part, segment: segment))
        }
        return (entries, nil)
    }

    /// The population: the held parts' own segments, in time order.
    static func held(_ entries: [Entry]) -> [NoteSegment] {
        entries.filter { $0.part.kind == .held }.map(\.segment)
    }

    /// The nearest chromatic note (MIDI) to a sung frequency.
    static func targetMidi(ofHz hz: Double) -> Double {
        (69 + 12 * log2(hz / 440)).rounded()
    }

    /// Leg N's reading: how many cents `reading`'s tracked median sits above the
    /// nearest chromatic note to `segment.detectedHz`.
    static func missCents(_ reading: PitchWanderMeter.NoteReading, of segment: NoteSegment) -> Double {
        let targetHz = 440 * pow(2, (targetMidi(ofHz: segment.detectedHz) - 69) / 12)
        return 1200 * log2(reading.medianHz / targetHz)
    }

    /// One measurable held part, read in both renders.
    struct PartScore: Sendable {
        let segment: NoteSegment
        let before: PitchWanderMeter.NoteReading
        let after: PitchWanderMeter.NoteReading
        var cut: Double { before.spreadCents > 0 ? 1 - after.spreadCents / before.spreadCents : 0 }
        var missCents: Double { HeldPartWander.missCents(after, of: segment) }
    }

    /// A render scored against the reference over held parts. The threshold
    /// travels with the verdict, so a log line always says what was asked.
    struct Verdict: Sendable {
        let scores: [PartScore]
        let comparison: PitchWanderMeter.Comparison
        let threshold: Double

        var cut: Double { comparison.medianReduction }
        var worstMiss: PartScore? { scores.max { abs($0.missCents) < abs($1.missCents) } }
        var maxAbsMiss: Double { worstMiss.map { abs($0.missCents) } ?? .infinity }
        /// Measurable held parts that sit off their own note.
        var offNote: [PartScore] {
            scores.filter { abs($0.missCents) > HeldPartWander.noteToleranceCents }
        }
        var passesW: Bool { cut >= threshold }
        var passesN: Bool { maxAbsMiss <= HeldPartWander.noteToleranceCents }
        var passes: Bool { passesW && passesN }

        /// The largest |change| in the cut when any ONE measurable part is
        /// dropped: how close the gate sits to a population change.
        var leaveOneOutSensitivity: Double {
            let cuts = scores.map(\.cut)
            guard cuts.count > 1, let whole = PitchWanderMeter.median(cuts) else { return 0 }
            return cuts.indices.map { index -> Double in
                var rest = cuts
                rest.remove(at: index)
                return abs((PitchWanderMeter.median(rest) ?? whole) - whole)
            }.max() ?? 0
        }

        /// The same verdict without the parts whose sung pitch is under `hz`.
        func without(hzBelow hz: Double) -> Verdict? {
            HeldPartWander.verdict(scores: scores.filter { $0.segment.detectedHz >= hz },
                                   threshold: threshold)
        }

        /// The population and the wander alone, for renders the Hard Tune gate
        /// does not apply to (the ladder presets).
        var wanderSummary: String {
            String(format: "held parts %d | wander %.1f -> %.1f c, IQR %.1f -> %.1f c | cut %.1f%%",
                   comparison.notes, comparison.beforeWanderCents, comparison.afterWanderCents,
                   comparison.beforeIQRCents, comparison.afterIQRCents, cut * 100)
        }

        /// One log line: both legs, the population and the headline pair.
        var summary: String {
            let worst = worstMiss.map {
                String(format: "%+.1f c at %.3f s", $0.missCents, $0.segment.startSeconds)
            } ?? "n/a"
            return String(format:
                "held parts %d | wander %.1f -> %.1f c, IQR %.1f -> %.1f c | cut %.1f%% (leg W >= %.0f%%: %@) | leg N worst %@, %d off their own note (%@) | gate %@",
                comparison.notes, comparison.beforeWanderCents, comparison.afterWanderCents,
                comparison.beforeIQRCents, comparison.afterIQRCents, cut * 100, threshold * 100,
                (passesW ? "pass" : "FAIL") as NSString, worst as NSString, offNote.count,
                (passesN ? "pass" : "FAIL") as NSString, (passes ? "PASS" : "FAIL") as NSString)
        }
    }

    /// Scores `after` against `before` on the held segments both read.
    /// `nil` when no segment reads in both.
    static func verdict(before: [PitchWanderMeter.NoteReading],
                        after: [PitchWanderMeter.NoteReading],
                        segments: [NoteSegment], threshold: Double) -> Verdict? {
        let segmentByID = Dictionary(segments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let afterByID = Dictionary(after.map { ($0.segmentID, $0) }, uniquingKeysWith: { a, _ in a })
        let scores = before.compactMap { b -> PartScore? in
            guard let a = afterByID[b.segmentID], let s = segmentByID[b.segmentID] else { return nil }
            return PartScore(segment: s, before: b, after: a)
        }
        return verdict(scores: scores, threshold: threshold)
    }

    static func verdict(scores: [PartScore], threshold: Double) -> Verdict? {
        guard let comparison = PitchWanderMeter.compare(before: scores.map(\.before),
                                                        after: scores.map(\.after)) else { return nil }
        return Verdict(scores: scores, comparison: comparison, threshold: threshold)
    }
}
