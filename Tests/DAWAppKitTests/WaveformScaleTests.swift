import CoreGraphics
import Foundation
import Testing
@testable import DAWAppKit

/// Headless coverage for `WaveformScale` (m25-e) — the arrange waveform's
/// VERTICAL scale, the sibling of `ArrangeZoom`'s horizontal one. The drawing
/// itself lives in `DAWApp.ClipWaveform`, which no test target can reach, so
/// every rule that decides how tall a bar is drawn lives HERE and is pinned here;
/// the Canvas does one multiply and no other math.
///
/// The two REQUIREMENTS this suite exists to hold, in the user's terms:
///   1. Quiet-but-real material fills the clip (the reported defect).
///   2. Near-silence still reads as near-silence, and relative level between
///      clips is genuinely recoverable — normalisation is a MODE, not a
///      one-way door.
@Suite("WaveformScale — auto-fit + vertical zoom (m25-e)")
struct WaveformScaleTests {

    // MARK: - The defect this item fixes

    @Test("a clip mastered well below full scale is boosted to FILL its block")
    func quietMaterialFillsTheClip() {
        // The user's case: material peaking at a quarter of full scale drew at
        // ~25 % of the half-height and left ~75 % of the block empty.
        let gain = WaveformScale.normalizeGain(peakMax: 0.25, normalize: true)
        #expect(gain == 4)
        // Which is exactly "fills it": peak × gain lands on 1.0, the full half-height.
        #expect(abs(0.25 * Float(gain) - 1) < 0.0001)

        // A half-scale peak needs 2× and gets it.
        #expect(WaveformScale.normalizeGain(peakMax: 0.5, normalize: true) == 2)
        // And a peak a shade under full scale is barely touched.
        let hot = WaveformScale.normalizeGain(peakMax: 0.95, normalize: true)
        #expect(hot > 1 && hot < 1.06)
    }

    @Test("the whole quiet-to-loud band a mix actually occupies fills the clip")
    func theCoveredBand() {
        // Every peak from a quarter of full scale UP reaches the full height —
        // that is the band the cap was chosen to cover, asserted rather than
        // asserted-about-in-a-comment.
        for peak in stride(from: Float(0.25), through: 1.0, by: 0.05) {
            let drawn = Double(peak) * WaveformScale.normalizeGain(peakMax: peak, normalize: true)
            #expect(abs(drawn - 1) < 0.02, "peak \(peak) drew at \(drawn), not full height")
        }
    }

    // MARK: - The cap (near-silence must not explode)

    @Test("the boost is capped at 4× so a near-silent clip still reads near-silent")
    func capHoldsNearSilenceDown() {
        // A noise floor a hundredth of full scale would need 100× to fill the
        // block. Capped, it draws at 4 % of the half-height — visible as
        // near-nothing, which is the truth about it.
        let gain = WaveformScale.normalizeGain(peakMax: 0.01, normalize: true)
        #expect(gain == WaveformScale.maxNormalizeBoost)
        #expect(gain == 4)
        #expect(abs(0.01 * Double(gain) - 0.04) < 0.0001)

        // Even absurdly quiet material cannot exceed the cap.
        #expect(WaveformScale.normalizeGain(peakMax: 0.00001, normalize: true) == 4)
        // And the cap is a real ceiling for every peak below the covered band.
        for peak in [Float(0.2), 0.1, 0.05, 0.001] {
            #expect(WaveformScale.normalizeGain(peakMax: peak, normalize: true) == 4)
            let drawn = Double(peak) * 4
            #expect(drawn < 1, "peak \(peak) reached full height — the cap failed")
        }
    }

    @Test("a quieter clip is still drawn shorter than a louder one below the cap")
    func orderingSurvivesUnderTheCap() {
        // The cap flattens the TOP of the range (stated cost), but under it the
        // ordering — the thing that makes near-silence readable as near-silence —
        // must survive.
        let quiet = 0.02 * Double(WaveformScale.normalizeGain(peakMax: 0.02, normalize: true))
        let mid = 0.10 * Double(WaveformScale.normalizeGain(peakMax: 0.10, normalize: true))
        let loud = 0.20 * Double(WaveformScale.normalizeGain(peakMax: 0.20, normalize: true))
        #expect(quiet < mid)
        #expect(mid < loud)
        #expect(loud < 1)
    }

    @Test("the documented COST of the cap is real: two hot clips become alike in FIT")
    func theStatedCost() {
        // Honest counter-test. Above the cap's reach, fit mode genuinely does
        // erase the difference between a hotter and a quieter clip — which is
        // WHY raw mode has to exist. If this ever stops being true the doc is
        // wrong, not the code.
        let a = 0.30 * Double(WaveformScale.normalizeGain(peakMax: 0.30, normalize: true))
        let b = 0.60 * Double(WaveformScale.normalizeGain(peakMax: 0.60, normalize: true))
        #expect(abs(a - b) < 0.0001)
        // …and raw mode recovers exactly that difference.
        let rawA = 0.30 * Double(WaveformScale.normalizeGain(peakMax: 0.30, normalize: false))
        let rawB = 0.60 * Double(WaveformScale.normalizeGain(peakMax: 0.60, normalize: false))
        #expect(abs(rawB - rawA * 2) < 0.0001)
    }

    // MARK: - Raw mode + the guards

    @Test("raw mode is a true passthrough — every peak draws at its own amplitude")
    func rawIsPassthrough() {
        for peak in [Float(0), 0.01, 0.25, 0.5, 1.0] {
            #expect(WaveformScale.normalizeGain(peakMax: peak, normalize: false) == 1,
                    "raw mode scaled a \(peak) peak")
        }
    }

    @Test("normalisation never SQUASHES a hot file, and never divides by zero")
    func guards() {
        // A full-scale file is already fitted — no change, and definitely no
        // reduction (a hot clip must not be drawn shorter than it is).
        #expect(WaveformScale.normalizeGain(peakMax: 1.0, normalize: true) == 1)
        // A peak above 1 cannot occur (`computePeaks` clamps), but if it did the
        // factor must not drop below 1.
        #expect(WaveformScale.normalizeGain(peakMax: 2.0, normalize: true) == 1)
        // An all-silent file: no shape to fit, and the divide must not happen.
        #expect(WaveformScale.normalizeGain(peakMax: 0, normalize: true) == 1)
        #expect(WaveformScale.normalizeGain(peakMax: -1, normalize: true) == 1)
    }

    // MARK: - Vertical zoom

    @Test("zoom defaults to 1×, clamps to 1–8, and never shrinks below 1×")
    func zoomClamp() {
        #expect(WaveformScale.defaultVerticalZoom == 1)
        #expect(WaveformScale.clampZoom(1) == 1)
        #expect(WaveformScale.clampZoom(3.7) == 3.7)      // between rungs is legal
        #expect(WaveformScale.clampZoom(0.25) == 1)       // shrinking is the defect, not a feature
        #expect(WaveformScale.clampZoom(-2) == 1)
        #expect(WaveformScale.clampZoom(1000) == 8)
    }

    @Test("stepping walks the ladder and stops at both ends")
    func zoomLadderSteps() {
        var z = WaveformScale.defaultVerticalZoom
        var visited: [CGFloat] = [z]
        for _ in 0..<20 { z = WaveformScale.zoomedIn(z); visited.append(z) }
        #expect(z == 8, "zoom-in did not reach the top rung")
        // Every rung was visited in order, and it parked at the top.
        #expect(Array(visited.prefix(WaveformScale.zoomLadder.count)) == WaveformScale.zoomLadder)

        for _ in 0..<20 { z = WaveformScale.zoomedOut(z) }
        #expect(z == 1, "zoom-out did not reach the bottom rung")
        // Parked, not wrapped or driven negative.
        #expect(WaveformScale.zoomedOut(1) == 1)
        #expect(WaveformScale.zoomedIn(8) == 8)
    }

    @Test("stepping from a between-rungs value lands on the next rung in that direction")
    func zoomFromOffLadder() {
        // A wire- or drag-set value need not sit on a rung; a step from it must
        // still move, and must move the right way.
        #expect(WaveformScale.zoomedIn(2.5) == 3)
        #expect(WaveformScale.zoomedOut(2.5) == 2)
        #expect(WaveformScale.zoomedIn(1.2) == 1.5)
        #expect(WaveformScale.zoomedOut(7.9) == 6)
        // A rung that arrived as a floating-point round-trip still steps OFF
        // itself rather than sticking (the tolerance's whole job).
        #expect(WaveformScale.zoomedIn(2.0000000000000004) == 3)
        #expect(WaveformScale.zoomedOut(1.9999999999999998) == 1.5)
    }

    // MARK: - The composed factor the Canvas multiplies by

    @Test("drawScale composes the fit and the zoom, in both modes")
    func drawScaleComposes() {
        // FIT at 1× — the default: a quarter-scale peak fills the block.
        #expect(WaveformScale.drawScale(peakMax: 0.25, normalize: true, verticalZoom: 1) == 4)
        // FIT × 2 — the user pushing further to see a pattern.
        #expect(WaveformScale.drawScale(peakMax: 0.25, normalize: true, verticalZoom: 2) == 8)
        // RAW at 1× is EXACTLY the pre-m25-e drawing — the no-change guarantee
        // that makes raw a real escape hatch and not an approximation of one.
        #expect(WaveformScale.drawScale(peakMax: 0.25, normalize: false, verticalZoom: 1) == 1)
        #expect(WaveformScale.drawScale(peakMax: 1.0, normalize: false, verticalZoom: 1) == 1)
        // RAW × 4 — magnifying true amplitude, which is the combination that lets
        // a user compare levels AND see detail at the same time.
        #expect(WaveformScale.drawScale(peakMax: 0.25, normalize: false, verticalZoom: 4) == 4)
        // An out-of-range zoom is clamped inside drawScale, so the drawing layer
        // can never receive an unbounded factor.
        #expect(WaveformScale.drawScale(peakMax: 1.0, normalize: false, verticalZoom: 1e6) == 8)
        // The largest factor the whole surface can produce: cap × top rung.
        #expect(WaveformScale.drawScale(peakMax: 0.001, normalize: true, verticalZoom: 8) == 32)
    }

    // MARK: - Readouts

    @Test("zoom labels are short and drop a needless decimal")
    func zoomLabels() {
        #expect(WaveformScale.zoomLabel(1) == "1×")
        #expect(WaveformScale.zoomLabel(1.5) == "1.5×")
        #expect(WaveformScale.zoomLabel(2) == "2×")
        #expect(WaveformScale.zoomLabel(8) == "8×")
        // Every rung's label fits the pinned chip width (≤ 4 glyphs).
        for rung in WaveformScale.zoomLadder {
            #expect(WaveformScale.zoomLabel(rung).count <= 4, "\(rung) label is too wide")
        }
    }

    @Test("the mode label names the mode, and the zoom only when it is doing something")
    func modeLabels() {
        #expect(WaveformScale.modeLabel(normalize: true, verticalZoom: 1) == "FIT")
        #expect(WaveformScale.modeLabel(normalize: false, verticalZoom: 1) == "RAW")
        #expect(WaveformScale.modeLabel(normalize: true, verticalZoom: 2) == "FIT 2×")
        #expect(WaveformScale.modeLabel(normalize: false, verticalZoom: 1.5) == "RAW 1.5×")
        // The chip's width is pinned at the widest string the model can produce;
        // nothing may exceed it (the m22-g no-truncation law).
        var widest = 0
        for normalize in [true, false] {
            for rung in WaveformScale.zoomLadder {
                widest = max(widest, WaveformScale.modeLabel(normalize: normalize,
                                                             verticalZoom: rung).count)
            }
        }
        #expect(widest == 8, "the widest mode label changed to \(widest) glyphs — re-pin the chip")
    }

    @Test("the help line describes the mode in beginner words and names the trim")
    func helpCopy() {
        let fit = WaveformScale.help(normalize: true, verticalZoom: 1)
        #expect(fit.contains("fill the clip"))
        let raw = WaveformScale.help(normalize: false, verticalZoom: 1)
        #expect(raw.contains("true level"))
        #expect(raw.contains("louder"))
        // Zoomed, it says so AND warns that peaks get trimmed — the honest
        // readout rule: a magnified view that silently loses the tops of peaks
        // must say that is what it is doing.
        let zoomed = WaveformScale.help(normalize: true, verticalZoom: 4)
        #expect(zoomed.contains("4×"))
        #expect(zoomed.contains("trimmed"))
        // Unzoomed copy makes no trim claim it isn't earning.
        #expect(fit.contains("trimmed") == false)
    }

    // MARK: - Guard the guard

    @Test("the ladder is sane: ascending, starts at the default, ends at the range top")
    func ladderShape() {
        #expect(WaveformScale.zoomLadder.first == WaveformScale.defaultVerticalZoom)
        #expect(WaveformScale.zoomLadder.last == WaveformScale.verticalZoomRange.upperBound)
        #expect(WaveformScale.zoomLadder.first == WaveformScale.verticalZoomRange.lowerBound)
        #expect(zip(WaveformScale.zoomLadder, WaveformScale.zoomLadder.dropFirst())
            .allSatisfy { $0 < $1 }, "the ladder is not strictly ascending")
    }
}
