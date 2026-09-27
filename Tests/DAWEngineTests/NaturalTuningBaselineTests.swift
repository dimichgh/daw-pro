import DAWCore
import Foundation
import Testing

@testable import DAWEngine

/// m23-nt NT-G — **RED-ON-TODAY BASELINES.** Design
/// `docs/design/2026-09-25-natural-tuning.md`, "Order inside the serial
/// lanes → NT-G": four numbers, each measured against TODAY'S API (813c415
/// era), that later gates (owned by other lanes) cite as their positive
/// control, their negative control, or their pre-registered threshold.
///
/// ⚠️ **NO ASSERTION HERE MAY FAIL ON HEAD — EXCEPT §1 G5, which since NT-E1b
/// (2026-09-25) is a PRODUCT check, not a baseline (its own doc comment says
/// why).** Every other `#expect` is structural —
/// a control reads as its OWN mechanism predicts, a value is finite, a
/// mechanism the code comments already claim (e.g. "this field is unread")
/// is exercised. The FINDING itself (the field does nothing; the 's' moves;
/// the wobble widens; the curve dips) is `log`ged as a number, never
/// asserted to pass or fail — that is the gates-first lane's whole point:
/// the number has to exist before another lane's gate can cite it.
///
/// Covers, one `@Test` each:
///  * §1 G5 — a per-note `formantOffsetSemitones` REACHES the app's render
///    (it was unread until NT-E1b switched the formant render on, 2026-09-25;
///    the test is now a note-level product check with the old render as its
///    negative control).
///  * §2 G-C3 (+ R5's waveform-residual leg) — the 's' moves with the vowel.
///  * §3 G0 — today's drift/vibrato separator leak (env-gated, reuses
///    `ContourShapingSweepTests`' own instrument, per its `CONTOUR_SWEEP`
///    convention — this file adds a CELL, not a new file, per §3g's own
///    text; NT-G's ownership is only of ITS OWN five files, so the cell
///    lives here rather than editing that file).
///  * §4 F12 — unequal half-ramps dip at a soft join (pure DAWCore
///    arithmetic, no render). First measured as an EXACT zero, which turned
///    out to be a DISTINCT `firstSpanIndex` skip defect, not the F12 dip
///    itself; p2-span fixed the skip and the test now reads the dip — see
///    that test's own doc comment and results.md.
///
/// Print convention: `nt-baseline| <section> <finding>`.
@Suite("Natural tuning — red-on-today baselines (measurement, m23-nt NT-G)")
struct NaturalTuningBaselineTests {
    static let sampleRate = 48_000.0

    static func log(_ message: String) { print("nt-baseline| \(message)") }

    /// The shipping path, minimal form: `StretchCurvePlan` + the curve loop
    /// with its compensation — exactly `NoteVibratoGeneratorTests
    /// .renderThroughShippingPath`'s shape, generalised to an arbitrary
    /// input signal (that helper always synthesises its own sine).
    static func renderThroughShippingPath(_ input: [Float], set: PitchEditSet) throws -> [Float] {
        let plan = try #require(StretchCurvePlan.make(
            editSet: set, clipPitchShiftSemitones: 0,
            sampleRate: sampleRate, ratio: 1))
        return try OfflineStretcher.stretchTransposeCurve(
            input: [input], sampleRate: sampleRate, ratio: 1,
            semitonesAtOutputFrame: { plan.semitones(atOutputFrame: $0) },
            formantPreserve: false,
            compensation: OfflineStretcher.curveLatencyCompensation(
                sampleRate: sampleRate))[0]
    }

    /// `10·log10(Σ(render−source)² / Σsource²)` over the shorter of the two.
    /// `-inf` when the two are bit-identical (digital zero, R5's "flag on"
    /// spelling); 0 dB means the residual is as loud as the source itself.
    static func residualDb(_ rendered: [Float], _ source: [Float]) -> Double {
        let n = min(rendered.count, source.count)
        guard n > 0 else { return -Double.infinity }
        var sumSourceSq = 0.0, sumDiffSq = 0.0
        for i in 0..<n {
            let s = Double(source[i]), r = Double(rendered[i])
            sumSourceSq += s * s
            let d = r - s
            sumDiffSq += d * d
        }
        guard sumSourceSq > 0, sumDiffSq > 0 else {
            return sumDiffSq > 0 ? 0 : -Double.infinity
        }
        return 10 * log10(sumDiffSq / sumSourceSq)
    }

    // MARK: - §1 G5 — a per-note formantOffsetSemitones, read by the PRODUCT

    /// ⚠️ **NO LONGER A BASELINE (NT-E1b, 2026-09-25): a NOTE-LEVEL PRODUCT
    /// CHECK.** It was NT-G's red-on-HEAD measurement that the field was
    /// unread, and it rendered through the direct curve loop WITHOUT
    /// `formant:`, so it could never go red once the product engaged. It now
    /// supersedes this file's banner line for §1 G5: a LEGACY set (amount nil)
    /// whose one note carries a hand-authored −2 st Voice offset and no pitch
    /// move, rendered by `StretchRenderCache.renderAudio` (the app's render;
    /// clip flag OFF, so c = 0 and F = −2 st), moves the note's envelope like
    /// a planted −200 c scale (within 50 c) and leaves its pitch (YIN, ±10 c).
    /// The OLD baseline render, the direct loop with no formant curve, is
    /// kept as the NEGATIVE CONTROL: it must FAIL the same check, which is
    /// what the product would read if its wiring were removed. This is the
    /// 1(c) row "legacy set + hand-authored offset" NT-E1 left unrendered.
    /// The multi-note gate (neighbours, the wrong note) is NT-E1's
    /// `NaturalTuningFormantRenderTests.g5PerNoteOffset`; the byte gate is
    /// its `productRenderEngagesTheFormantCurve`.
    @Test("§1 G5: a per-note formantOffsetSemitones is read by the product render (was: unread, baseline)")
    func g5FormantOffsetIsUnreadToday() throws {
        let seconds = 0.5
        let frames = Int(seconds * Self.sampleRate)
        let f0 = 110.0
        let source = SourceFilterVoice.voice(f0Hz: f0, formantScaleCents: 0,
                                             frames: frames, sampleRate: Self.sampleRate)

        let segment = NoteSegment(startSeconds: 0, endSeconds: seconds, detectedHz: f0,
                                  detectedConfidence: 1, formantOffsetSemitones: -2)
        let set = PitchEditSet(segments: [segment], retuneMs: 30)
        #expect(!set.isPitchIdentity,
                "formantOffsetSemitones alone should still force the stretcher branch to engage — NoteSegment.isPitchIdentity reads this field")
        #expect(set.formantCorrection == nil && set.engagesFormantCurve,
                "a hand-authored offset engages the formant curve with the amount still nil")

        var whole = [source]
        let product = try StretchRenderCache.renderAudio(
            whole: &whole, window: nil, sampleRate: Self.sampleRate,
            params: StretchRenderCache.Params(ratio: 1, semitones: 0, formantPreserve: false,
                                              pitchEdits: set),
            curveContour: nil, isCancelled: { false })
        #expect(product.path == .curve)
        let rendered = product.output.planar[0]
        let unread = try Self.renderThroughShippingPath(source, set: set)

        func mid(_ x: [Float]) -> [Float] { Array(x[(frames / 2 - 4096)..<(frames / 2 + 4096)]) }
        let envelopeShift = SpectralEnvelopeMeter.envelopeShiftCents(
            reference: mid(source), shifted: mid(rendered), sampleRate: Self.sampleRate)
        let unreadShift = SpectralEnvelopeMeter.envelopeShiftCents(
            reference: mid(source), shifted: mid(unread), sampleRate: Self.sampleRate)
        let pitch = NaturalTuningFormantRenderTests.pitchCents(source, rendered, centre: frames / 2)

        // The known answer: the SAME meter on a signal actually built with a
        // −200 c formant scale (proves the meter can see a −2 st shift here).
        let controlShifted = SourceFilterVoice.voice(f0Hz: f0, formantScaleCents: -200,
                                                     frames: frames, sampleRate: Self.sampleRate)
        let controlShift = try #require(SpectralEnvelopeMeter.envelopeShiftCents(
            reference: mid(source), shifted: mid(controlShifted), sampleRate: Self.sampleRate))
        Self.log("""
            G5 PRODUCT formantOffsetSemitones=-2, amount nil, flag off, no pitch move: \
            envelope shift = \(envelopeShift.map { String(format: "%.1f", $0) } ?? "nil") c \
            (planted -200 c reads \(String(format: "%.1f", controlShift)) c), pitch \(String(format: "%.1f", pitch)) c; \
            NEGATIVE CONTROL, the render without the curve (the old baseline): \
            \(unreadShift.map { String(format: "%.1f", $0) } ?? "nil") c
            """)
        #expect(abs(controlShift - (-200)) < 100,
                "control failed to read a planted -200 c shift; the meter would be at fault, not the field")
        let shift = try #require(envelopeShift, "the meter produced no reading of the product render")
        #expect(abs(shift - controlShift) <= 50,
                "the product render did not move the note's envelope like the planted −200 c: \(shift) c vs \(controlShift) c")
        #expect(abs(pitch) <= 10, "the Voice offset moved the pitch: \(pitch) c")
        let unreadReading = try #require(unreadShift, "the meter produced no reading of the negative control")
        #expect(abs(unreadReading - controlShift) > 50,
                "negative control: the render WITHOUT the formant curve passed too (\(unreadReading) c), so this check cannot fail")
    }

    // MARK: - §2 G-C3 (+ R5) — the 's' moves with the vowel today

    /// The `'Star'` fixture ("St|ar"): only the /a/ is a note (`pitchOffsetCents
    /// 300`, i.e. +3 st); the 's' and 't' are not notes at all today (no
    /// consonant mask exists on HEAD). Gentle retune (200 ms, R5: "r/2 = 100
    /// ms leak") so the note's ramp reaches back into the 's', per the
    /// design's own worked arithmetic (R5). This gap PRECEDES the moved note
    /// ("St" precedes the "ar" that moves) -- R5's after-a-moved-note
    /// residual threshold instead comes from the take harness's M-1
    /// (`NaturalTuningTakeHarnessTests`), which has gaps on both sides of a
    /// moved note; this synthetic fixture only ever has the one.
    @Test("§2 G-C3: the 's' moves with the vowel today (baseline, + R5 waveform-residual leg)")
    func gC3TheSMovesWithTheVowelToday() throws {
        let f0 = 110.0
        let star = SourceFilterVoice.starSyllable(f0Hz: f0, sampleRate: Self.sampleRate)
        let source = star.audio
        let sEndFrame = Int((star.sSeconds.upperBound * Self.sampleRate).rounded())
        let noteStart = star.voicedRange.lowerBound
        let halfRamp = min(0.200 / 2, (star.voicedRange.upperBound - noteStart) / 2) // retune 200 ms
        // The ramp's back-reach (noteStart - halfRamp) splits the 's' into a
        // FAR part it cannot touch and a NEAR part it does -- averaging the
        // whole 's' as one block dilutes the leak with the untouched part
        // (measured: it reads only ~1 c that way). R5's own arithmetic names
        // this split ("the leak covers most of the 's'").
        let reachFrame = max(0, Int(((noteStart - halfRamp) * Self.sampleRate).rounded()))

        let segment = NoteSegment(startSeconds: noteStart, endSeconds: star.voicedRange.upperBound,
                                  detectedHz: f0, detectedConfidence: 1, pitchOffsetCents: 300)
        let set = PitchEditSet(segments: [segment], retuneMs: 200) // Gentle, per R5
        let rendered = try Self.renderThroughShippingPath(source, set: set)

        func measure(_ label: String, _ lo: Int, _ hi: Int) {
            guard lo < hi, hi <= source.count, hi <= rendered.count else {
                Self.log("G-C3 \(label): window empty or out of range [\(lo), \(hi))")
                return
            }
            let src = Array(source[lo..<hi]), rend = Array(rendered[lo..<hi])
            let centroidShift = ConsonantSpectrumMeter.centroidShiftCents(
                reference: src, shifted: rend, sampleRate: Self.sampleRate)
            let lsd = ConsonantSpectrumMeter.logSpectralDistance(
                reference: src, shifted: rend, sampleRate: Self.sampleRate)
            let residual = Self.residualDb(rend, src)
            // M-1-style alignment check (R5: "a number NT-G records from M-1
            // first") -- a same-INDEX residual is meaningless if the render
            // is a few samples off from the source at this point; report the
            // lag/rho alongside it so a high residual can be told apart from
            // a plain alignment offset.
            let (lag, rho) = ConsonantSpectrumMeter.analyticLagRho(dry: src, wet: rend, maxLag: 256)
            Self.log("""
                G-C3 \(label) [\(String(format: "%.1f", Double(lo) / Self.sampleRate * 1000))-\
                \(String(format: "%.1f", Double(hi) / Self.sampleRate * 1000)) ms]: \
                centroid shift = \(centroidShift.map { String(format: "%.1f", $0) } ?? "nil") c, \
                LSD = \(lsd.map { String(format: "%.3f", $0) } ?? "nil"), \
                residual = \(String(format: "%.1f", residual)) dB, \
                lag = \(lag) samples, rho = \(String(format: "%.3f", rho))
                """)
        }
        measure("'s' whole (0-diluted average, kept for comparability)", 0, sEndFrame)
        measure("'s' FAR (outside the ramp's reach -- expect ~untouched)", 0, min(reachFrame, sEndFrame))
        measure("'s' NEAR (inside the ramp's reach -- R5's leak)", min(reachFrame, sEndFrame), sEndFrame)

        // Positive control: a CONSTANT clip-wide transpose (no note boundary
        // at all -- the 's' is unambiguously inside the moved region) must
        // read a clear shift; proves the instrument is not simply blind to
        // any shift in this material.
        let wholeClipSet = PitchEditSet(segments: [NoteSegment(
            startSeconds: 0, endSeconds: Double(source.count) / Self.sampleRate,
            detectedHz: f0, detectedConfidence: 1, pitchOffsetCents: 300)], retuneMs: 200)
        let wholeRendered = try Self.renderThroughShippingPath(source, set: wholeClipSet)
        let sSource = Array(source[0..<sEndFrame])
        let wholeSRendered = Array(wholeRendered[0..<sEndFrame])
        let wholeCentroidShift = try #require(ConsonantSpectrumMeter.centroidShiftCents(
            reference: sSource, shifted: wholeSRendered, sampleRate: Self.sampleRate))
        Self.log("G-C3 positive control (constant clip-wide +300 c transpose): " +
                "'s' centroid shift = \(String(format: "%.1f", wholeCentroidShift)) c")
        #expect(abs(wholeCentroidShift) > 20,
                "the positive control should show a clear shift; if it does not, this instrument cannot see ANY shift in the 's' region and the numbers above are meaningless")

        // Negative-control check: the /a/ ITSELF still moves in the case
        // under test -- confirms the render mechanism did what it was asked,
        // so the 's' reading above is a real leak, not a broken fixture.
        // ⚠️ `SpectralShiftMeter.maxLagCents == 200` (PitchWanderMeter.swift):
        // it cannot report past its own search ceiling, so a genuine +300 c
        // move reads AT the ceiling, not at 300 -- measured, not a defect in
        // this check (matches the same saturation behaviour documented on
        // `SpectralEnvelopeMeter`'s un-detrended plant).
        let noteStartFrame = Int((noteStart * Self.sampleRate).rounded())
        let aSource = Array(source[noteStartFrame...])
        let aRendered = Array(rendered[noteStartFrame...])
        let aShift = try #require(SpectralShiftMeter.shiftCents(
            reference: aSource, shifted: aRendered, sampleRate: Self.sampleRate))
        Self.log("G-C3 negative-control check: the /a/ itself reads " +
                "\(String(format: "%.1f", aShift)) c (meter ceiling 200 c; expect close to it)")
        #expect(aShift > 150, "the /a/ should show a large positive shift; the render mechanism may be broken")
    }

    // MARK: - §3 G0 — today's drift/vibrato separator leak on the product path

    /// Design §3g G0: "Add cells (drift 0, vibrato 1) at A3, B3 and 110 Hz to
    /// `ContourShapingSweepTests` (env `CONTOUR_SWEEP`), read by
    /// `PitchWanderMeter`." NT-G's lane table only owns THIS file, so the
    /// cell is added here rather than by editing that one — it reuses that
    /// suite's own `render`/`set`/`log` helpers (all plain `static func`,
    /// same module, un-edited) and its `enabled` flag, so it is silent in a
    /// normal `./scripts/test.sh` run exactly like its sibling cells and
    /// costs nothing when `CONTOUR_SWEEP` is unset.
    ///
    /// Axis: `ContourShapingSweepTests.render` prints `before -> after`
    /// `spreadCents` (before = the UNCORRECTED/as-sung tone). This fixture's
    /// tone (`hz * 2^(45·sin(2π·5.5t)/1200)`) carries NO separate drift term
    /// — pure vibrato by construction — so for THIS fixture the as-sung
    /// "before" reading already equals what §3g quotes as `IdealReading`
    /// (there is no drift to remove, so the ideal output equals the input).
    /// The printed before→after ratio therefore IS "delivered ÷ ideal", not
    /// a different axis; the run's own log lines carry the actual number.
    @Test("§3 G0: today's drift/vibrato separator leak on the product path (baseline)",
          .enabled(if: ContourShapingSweepTests.enabled))
    @MainActor
    func g0SeparatorLeakToday() async throws {
        func vibratoOnly(hz: Double) -> [Float] {
            ContourToRenderTests.tone(seconds: 3) { t in hz * pow(2, 45 * sin(2 * .pi * 5.5 * t) / 1200) }
        }
        for (label, hz) in [("A3", 220.0), ("B3", 246.94), ("110Hz", 110.0)] {
            try await ContourShapingSweepTests.render("G0 \(label), drift 0 + vibrato 1", input: vibratoOnly(hz: hz)) {
                ContourShapingSweepTests.set($0, drift: { _ in 0 }, vibrato: { _ in 1 })
            }
        }
        Self.log("G0 axis: delivered/ideal == after.spreadCents/before.spreadCents above, " +
                "because this fixture has no drift term (pure vibrato input) so the as-sung " +
                "'before' reading already IS the ideal reading G3's negative control must beat")
    }

    // MARK: - §4 F12 — unequal half-ramps dip at a soft join

    /// Design §4.g G-SUM's own plant names this: "give the right side `h/2` ⇒
    /// dip detected (the F12 shape)." A half-ramp is
    /// `min(retune/2, duration/2)` (`PitchCorrection.swift:1335`); two
    /// abutting notes of unequal duration get unequal half-ramps, their gates
    /// then do not sum to 1 at the join (`gate()` normalises only when the
    /// sum EXCEEDS 1, `:1449-1453`), and the blended value dips toward 0
    /// rather than holding the shared target. Pure DAWCore arithmetic --
    /// `PitchCorrectionCurve.make` + `semitones(atSourceSecond:)` -- no
    /// render needed.
    ///
    /// ⚠️⚠️ **HISTORY: THE FIRST MEASURED NUMBER WAS AN EXACT ZERO, AND THAT
    /// WAS A SEPARATE DEFECT FROM THE F12 UNDER-SUM DIP -- do not conflate
    /// them (caught on review, not by this comment's first draft).** The two
    /// spans' ramped reach (`endSeconds + halfRamp`) is `[2.1, 2.09]` here --
    /// DECREASING, because the SHORT note's half-ramp (30 ms, clamped to its
    /// own half duration) is narrower than the LONG note's (100 ms).
    /// `firstSpanIndex` binary-searched assuming that sequence was
    /// non-decreasing, returned one PAST the last span for t in
    /// [2.09, 2.1), and BOTH spans were skipped: an EXACT 0 where the long
    /// note's tail was still open (2.2 c at worst). **p2-span (2026-09-25)
    /// FIXED that skip**; `PitchSpanSearchTests` holds both evaluators to a
    /// linear scan, and the `tail` check below is this test's own proof.
    ///
    /// ⚠️ **THE WINDOW NOW STOPS WHERE THE SHORT NOTE STARTS TO FADE OUT
    /// (its end minus its 30 ms half-ramp), ON PURPOSE (p2-span).** Nothing
    /// follows the short note, so past that point both notes fade to the
    /// clip's 0 st. The old window ran to +150 ms and took its minimum
    /// THERE: "300.00 c at +90 ms" with the skip, "300.00 c at +100 ms"
    /// without it. That was the TRAILING EDGE of the edit, not a dip at the
    /// join. What this window measures is the F12 under-sum dip itself,
    /// which natural tuning §4 owns.
    @Test("§4 F12: unequal half-ramps dip at a soft join (baseline)")
    func f12AsymmetricRampDip() throws {
        let joinTime = 2.0
        let longNote = NoteSegment(startSeconds: 0, endSeconds: joinTime,
                                   detectedHz: 220, detectedConfidence: 1, pitchOffsetCents: 300)
        let shortNote = NoteSegment(startSeconds: joinTime, endSeconds: joinTime + 0.06,
                                    detectedHz: 220, detectedConfidence: 1, pitchOffsetCents: 300)
        let set = PitchEditSet(segments: [longNote, shortNote], retuneMs: 200)
        let curve = PitchCorrectionCurve.make(editSet: set)

        // p2-span: up to where the short note starts to fade out (see the doc
        // comment), not +150 ms into the edit's trailing edge.
        let windowEnd = shortNote.endSeconds - min(0.200 / 2, shortNote.durationSeconds / 2)
        var minValue = Double.infinity
        var minTime = joinTime
        var t = joinTime - 0.15
        while t <= windowEnd {
            let v = curve.semitones(atSourceSecond: t)
            if v < minValue { minValue = v; minTime = t }
            t += 0.0005
        }
        let dipCents = (3.0 - minValue) * 100
        let offsetMs = (minTime - joinTime) * 1000
        Self.log("F12 unequal-halfRamp join (retune 200 ms, 60 ms note abutting a 2 s note, " +
                "both +300 c): dip = \(String(format: "%.2f", dipCents)) c, " +
                "\(String(format: "%.1f", offsetMs)) ms from the join")
        #expect(minValue.isFinite)
        #expect(dipCents > 0.01,
                "expected a measurable dip from the unequal half-ramps; the under-sum mechanism (gate() §4.b.3) may have changed")

        // p2-span: the skip is gone. At +95 ms the long note's tail is still
        // open (reach 2.1 s) behind the short note's closed one (2.09 s);
        // before p2-span the search landed past both and read an EXACT 0.
        let tail = curve.semitones(atSourceSecond: joinTime + 0.095)
        Self.log("F12 p2-span: at +95 ms the long note's tail reads " +
                "\(String(format: "%.3f", tail * 100)) c (an exact 0 before p2-span)")
        #expect(tail > 0, "the long note's still-open tail was skipped again (p2-span)")

        // Control: two EQUAL-length notes at the same offset must read a
        // FLAT 3.0 st through their join (complementary smoothstep,
        // s(x)+s(1-x)==1 when both sides share one half-ramp) -- proves the
        // dip above is the length mismatch, not the meter or a general
        // property of soft joins.
        let equalA = NoteSegment(startSeconds: 0, endSeconds: 1.0, detectedHz: 220,
                                 detectedConfidence: 1, pitchOffsetCents: 300)
        let equalB = NoteSegment(startSeconds: 1.0, endSeconds: 2.0, detectedHz: 220,
                                 detectedConfidence: 1, pitchOffsetCents: 300)
        let equalCurve = PitchCorrectionCurve.make(
            editSet: PitchEditSet(segments: [equalA, equalB], retuneMs: 200))
        var maxDeviation = 0.0
        t = 1.0 - 0.15
        while t <= 1.0 + 0.15 {
            maxDeviation = max(maxDeviation, abs(equalCurve.semitones(atSourceSecond: t) - 3.0))
            t += 0.0005
        }
        Self.log("F12 control (equal half-ramps): max deviation from 3.0 st = \(maxDeviation) st")
        #expect(maxDeviation < 1e-9,
                "equal half-ramps should sum to 1 and read a flat 3.0 st; got a deviation of \(maxDeviation)")
    }
}
