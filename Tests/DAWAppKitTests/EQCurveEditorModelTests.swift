import Foundation
import Testing
@testable import DAWAppKit
import DAWCore

/// Unit tests for the headless EQ CURVE EDITOR model (m22-b Phase 2, design
/// docs/research/design-m22b-eq-curve-editor.md §8.3/§8.4): the fixed
/// log-x/linear-y plot geometry, handle layout from `EQParams` via the
/// resolved accessors, 28 pt hit-testing with the smaller-Q tie-break, the
/// drag/⌥-drag/scroll/⇧/keyboard/double-click → `[(name, value)]` interaction
/// laws, write-through via the wrapped `EffectEditorModel` (recorded fakes +
/// real-store wire parity), the §4.1 spectrum display smoother, and the §8.4
/// < 1 ms full-recompute bound.
@Suite("EQCurveEditorModel")
@MainActor
struct EQCurveEditorModelTests {
    typealias Band = EQFilterResponse.Band

    /// The design's reference plot size (§6: plot ≈ 528×260).
    static let width = 528.0
    static let height = 260.0

    // MARK: - Fixtures

    /// Records every (name, value) the model pushes through the editor's
    /// apply closure — the established fake-store pattern.
    @MainActor
    final class WriteRecorder {
        var writes: [(name: String, value: Double)] = []
    }

    /// An `EffectEditorModel` over a REAL store (the EffectEditorModelTests
    /// fixture — the same closures `AppModel` injects, UI == wire by
    /// construction), optionally recording each applied write.
    private static func makeStoreBacked(
        _ store: ProjectStore, recorder: WriteRecorder? = nil
    ) -> EffectEditorModel {
        EffectEditorModel(
            descriptor: { trackID, effectID in
                if let trackID {
                    return store.tracks.first { $0.id == trackID }?
                        .effects.first { $0.id == effectID }
                }
                return store.masterEffects.first { $0.id == effectID }
            },
            apply: { trackID, effectID, name, value in
                recorder?.writes.append((name, value))
                if let trackID {
                    _ = try store.setEffectParam(
                        trackID: trackID, effectID: effectID, name: name, value: value)
                } else {
                    _ = try store.setMasterEffectParam(
                        effectID: effectID, name: name, value: value)
                }
            },
            setBypassed: { trackID, effectID, bypassed in
                if let trackID {
                    try store.setEffectBypassed(
                        trackID: trackID, effectID: effectID, bypassed: bypassed)
                } else {
                    try store.setMasterEffectBypassed(effectID: effectID, bypassed: bypassed)
                }
            })
    }

    /// A store-backed curve model over a fresh track-chain EQ.
    private static func makeCurveModel(
        recorder: WriteRecorder? = nil
    ) -> (store: ProjectStore, model: EQCurveEditorModel) {
        let store = ProjectStore()
        let track = store.addTrack(kind: .audio)
        let fx = try! store.addEffect(toTrack: track.id, kind: .eq)
        let editor = makeStoreBacked(store, recorder: recorder)
        editor.prepare(trackID: track.id, effectID: fx.id, targetLabel: "on Test")
        return (store, EQCurveEditorModel(editor: editor, sampleRate: 48_000))
    }

    /// A curve model over a pure FAKE editor: descriptor is a fresh eq that
    /// never changes; writes are ONLY recorded (zero store anywhere).
    private static func makeFakeBacked() -> (recorder: WriteRecorder, model: EQCurveEditorModel) {
        let recorder = WriteRecorder()
        let descriptor = EffectDescriptor(kind: .eq)
        let editor = EffectEditorModel(
            descriptor: { _, _ in descriptor },
            apply: { _, _, name, value in recorder.writes.append((name, value)) },
            setBypassed: { _, _, _ in })
        editor.prepare(trackID: nil, effectID: descriptor.id, targetLabel: "on Master")
        return (recorder, EQCurveEditorModel(editor: editor, sampleRate: 48_000))
    }

    // MARK: - §8.3 Geometry round-trips

    @Test("x↔frequency is the fixed 20 Hz–20 kHz log axis; 1 kHz at ≈0.566")
    func geometryFrequencyRoundTrip() {
        let w = Self.width
        #expect(EQCurveGeometry.x(forFrequency: 20, in: w) == 0)
        #expect(abs(EQCurveGeometry.x(forFrequency: 20_000, in: w) - w) < 1e-9)
        // THE pin: 1 kHz sits at x/width = log(50)/log(1000) ≈ 0.566 (§8.3).
        let kHz = EQCurveGeometry.x(forFrequency: 1_000, in: 1)
        #expect(abs(kHz - log(50.0) / log(1_000.0)) < 1e-12)
        #expect(abs(kHz - 0.566) < 0.001)
        // Inverse round-trips across the axis.
        for f in [20.0, 55, 440, 1_000, 8_000, 20_000] {
            let back = EQCurveGeometry.frequency(
                forX: EQCurveGeometry.x(forFrequency: f, in: w), in: w)
            #expect(abs(back - f) < f * 1e-9, "round-trip at \(f) Hz")
        }
        // The inverse clamps to the axis (off-plot pointer safety).
        #expect(EQCurveGeometry.frequency(forX: -100, in: w) == 20)
        #expect(EQCurveGeometry.frequency(forX: w * 10, in: w) == 20_000)
    }

    @Test("y↔dB is linear over ±24 with 0 dB at center; edges exact")
    func geometryDbRoundTrip() {
        let h = Self.height
        #expect(EQCurveGeometry.y(forDb: 24, in: h) == 0)
        #expect(EQCurveGeometry.y(forDb: -24, in: h) == h)
        #expect(EQCurveGeometry.y(forDb: 0, in: h) == h / 2)
        for db in [-24.0, -7.5, 0, 3, 24] {
            let back = EQCurveGeometry.db(forY: EQCurveGeometry.y(forDb: db, in: h), in: h)
            #expect(abs(back - db) < 1e-9, "round-trip at \(db) dB")
        }
        // Off-plot y clamps to the dB range.
        #expect(EQCurveGeometry.db(forY: -50, in: h) == 24)
        #expect(EQCurveGeometry.db(forY: h + 50, in: h) == -24)
    }

    @Test("grid lines and label strings are the settled §5.1 set")
    func gridLinesAndLabels() {
        #expect(EQCurveGeometry.dbGridLines == [-18, -12, -6, 0, 6, 12, 18])
        #expect(EQCurveGeometry.dbGridLabel(6) == "+6")
        #expect(EQCurveGeometry.dbGridLabel(18) == "+18")
        #expect(EQCurveGeometry.dbGridLabel(-12) == "-12")
        #expect(EQCurveGeometry.dbGridLabel(0) == nil, "the center line carries no label")
        #expect(EQCurveGeometry.frequencyGridLines
                == [20, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000])
        #expect(EQCurveGeometry.frequencyGridLines.map(EQCurveGeometry.frequencyGridLabel(_:))
                == ["20", "50", "100", "200", "500", "1k", "2k", "5k", "10k", "20k"])
    }

    @Test("curve generation: 256 points, neutral = center line, peaks land, skirts clip")
    func curveGeneration() {
        let w = Self.width, h = Self.height
        // Neutral params: the composite is EXACTLY the 0 dB center line.
        let neutral = EQCurveGeometry.compositeCurve(
            params: EQParams(), sampleRate: 48_000, width: w, height: h)
        #expect(neutral.count == EQCurveGeometry.curveSampleCount)
        #expect(neutral[0].x == 0)
        #expect(abs(neutral[255].x - w) < 1e-6)
        #expect(neutral.allSatisfy { $0.y == h / 2 }, "neutral EQ draws the exact center line")
        // A +6 dB peak at 2 kHz (grid index 170: 20·1000^(170/255) = 2 kHz)
        // pulls the composite to y(+6) there.
        let boosted = EQParams(peak1Freq: 2_000, peak1GainDb: 6, peak1Q: 1)
        let curve = EQCurveGeometry.compositeCurve(
            params: boosted, sampleRate: 48_000, width: w, height: h)
        #expect(abs(curve[170].y - EQCurveGeometry.y(forDb: 6, in: h)) < 0.01)
        // The per-band curve of an INACTIVE band is the flat center line.
        let idleBand = EQCurveGeometry.bandCurve(
            .peak2, params: boosted, sampleRate: 48_000, width: w, height: h)
        #expect(idleBand.allSatisfy { $0.y == h / 2 })
        // An HP 24 skirt plunges past −24 and CLIPS at the plot edge (§5.1).
        let hp = EQParams(highPassFreq: 1_000, highPassSlopeDbPerOct: 24,
                          highPassEnabled: true)
        let hpCurve = EQCurveGeometry.compositeCurve(
            params: hp, sampleRate: 48_000, width: w, height: h)
        // NB: Double(...) keeps the decomposed #expect operands HOMOGENEOUS —
        // a heterogeneous CGFloat == Double at the macro's top level fails
        // even on bit-identical values (toolchain quirk, verified by pattern).
        #expect(Double(hpCurve[0].y) == h, "the 20 Hz skirt point clips to the bottom plot edge")
    }

    // MARK: - §8.3 Handle layout

    @Test("fresh EQ: six handles in signal-flow order; OFF HP at 20 Hz dim-hollow")
    func handleLayoutDefaults() {
        let handles = EQCurveEditorModel.handles(params: EQParams())
        #expect(handles.map(\.band) == Band.allCases)
        #expect(handles.map(\.tag) == ["HP", "LS", "1", "2", "HS", "LP"])
        // The §8.3 pin: an OFF HP parks dim-hollow at 20 Hz on the 0 dB line.
        let hp = handles[0]
        #expect(hp.frequency == 20 && hp.gainDb == 0 && !hp.isEnabled)
        // The OFF LP mirrors at 20 kHz.
        let lp = handles[5]
        #expect(lp.frequency == 20_000 && lp.gainDb == 0 && !lp.isEnabled)
        // Gain bands sit at their stored defaults, enabled.
        #expect(handles[1].frequency == 100 && handles[1].isEnabled)
        #expect(handles[2].frequency == 500 && handles[2].gainDb == 0)
        #expect(handles[3].frequency == 3_000)
        #expect(handles[4].frequency == 8_000)
        // Resolved Qs: peaks stored, shelves the legacy 1/√2, cuts Butterworth.
        #expect(handles[2].q == 1)
        #expect(handles[1].q == EQParams.defaultShelfQ)
        #expect(handles[0].q == EQFilterResponse.butterworth2Q)
    }

    @Test("handle layout reads disabled/nil states through the resolved accessors")
    func handleLayoutStates() {
        // A bypassed gain band: dim-hollow at its STORED position.
        let bypassedPeak = EQParams(peak1Freq: 750, peak1GainDb: 5, peak1Enabled: false)
        let peak = EQCurveEditorModel.handles(params: bypassedPeak)[2]
        #expect(peak.frequency == 750 && peak.gainDb == 5 && !peak.isEnabled)
        // A live HP: at its corner, pinned to the 0 dB line, filled.
        let liveHP = EQParams(highPassFreq: 250, highPassEnabled: true)
        let hp = EQCurveEditorModel.handles(params: liveHP)[0]
        #expect(hp.frequency == 250 && hp.gainDb == 0 && hp.isEnabled)
        // A bypassed HP KEEPS its stored corner (bypass, not reset).
        let bypassedHP = EQParams(highPassFreq: 250, highPassEnabled: false)
        let hpOff = EQCurveEditorModel.handles(params: bypassedHP)[0]
        #expect(hpOff.frequency == 250 && !hpOff.isEnabled)
    }

    // MARK: - §8.3 Hit-testing

    @Test("nearest handle within 28 pt wins; ties break to the smaller-Q band")
    func hitTesting() {
        let w = Self.width, h = Self.height
        // Direct hit on P1's center.
        let defaults = EQParams()
        let p1x = EQCurveGeometry.x(forFrequency: 500, in: w)
        let center = EQCurveGeometry.y(forDb: 0, in: h)
        #expect(EQCurveEditorModel.hitTest(x: p1x, y: center, params: defaults,
                                           width: w, height: h) == .peak1)
        // 29 pt off is outside the 28 pt target → nil.
        #expect(EQCurveEditorModel.hitTest(x: p1x, y: center - 29, params: defaults,
                                           width: w, height: h) == nil)
        // 27 pt off is inside.
        #expect(EQCurveEditorModel.hitTest(x: p1x, y: center - 27, params: defaults,
                                           width: w, height: h) == .peak1)
        // Nearest wins between two in-radius handles.
        let close = EQParams(peak1Freq: 900, peak2Freq: 1_000)
        #expect(EQCurveEditorModel.hitTest(
            x: EQCurveGeometry.x(forFrequency: 1_000, in: w), y: center,
            params: close, width: w, height: h) == .peak2)
        // An exact tie (coincident handles) breaks to the smaller-Q band.
        let tied = EQParams(peak1Freq: 1_000, peak1GainDb: 6, peak1Q: 5,
                            peak2Freq: 1_000, peak2GainDb: 6, peak2Q: 1)
        #expect(EQCurveEditorModel.hitTest(
            x: EQCurveGeometry.x(forFrequency: 1_000, in: w),
            y: EQCurveGeometry.y(forDb: 6, in: h),
            params: tied, width: w, height: h) == .peak2,
                "the harder-to-grab (narrower) band wins the tie")
    }

    // MARK: - §8.3 Drag → writes

    @Test("a P1 drag emits peak1Freq + peak1GainDb per the axis laws, clamped")
    func dragWritesFreqGain() {
        let w = Self.width, h = Self.height
        // w/3 rightward = ×1000^(1/3) = ×10 in frequency; −h/8 upward = +6 dB.
        let writes = EQCurveEditorModel.dragWrites(
            band: .peak1, startFrequency: 500, startGainDb: 0,
            translationX: w / 3, translationY: -h / 8,
            width: w, height: h, fine: false)
        #expect(writes.map(\.name) == ["peak1Freq", "peak1GainDb"])
        #expect(abs(writes[0].value - 5_000) < 5_000 * 1e-9)
        #expect(abs(writes[1].value - 6) < 1e-12)
        // Clamps: a huge drag pins to the band's spec range and ±24.
        let clamped = EQCurveEditorModel.dragWrites(
            band: .peak1, startFrequency: 500, startGainDb: 0,
            translationX: w * 10, translationY: h * 10,
            width: w, height: h, fine: false)
        #expect(clamped[0].value == EQParams.peakFreqRange.upperBound)
        #expect(clamped[1].value == EQParams.gainDbRange.lowerBound)
        // The high shelf clamps to ITS spec floor (200 Hz), not the axis's.
        let shelf = EQCurveEditorModel.dragWrites(
            band: .highShelf, startFrequency: 8_000, startGainDb: 0,
            translationX: -w, translationY: 0,
            width: w, height: h, fine: false)
        #expect(shelf[0].value == EQParams.highShelfFreqRange.lowerBound)
    }

    @Test("HP/LP drags emit freq ONLY, clamped to their ranges")
    func dragWritesCutBands() {
        let w = Self.width, h = Self.height
        let hp = EQCurveEditorModel.dragWrites(
            band: .highPass, startFrequency: 100, startGainDb: 0,
            translationX: w, translationY: -h / 4,
            width: w, height: h, fine: false)
        #expect(hp.count == 1, "vertical drag is ignored on a cut band")
        #expect(hp[0].name == "highPassFreq")
        #expect(hp[0].value == EQParams.highPassFreqRange.upperBound)   // 1 kHz cap
        let lp = EQCurveEditorModel.dragWrites(
            band: .lowPass, startFrequency: 12_000, startGainDb: 0,
            translationX: -w, translationY: 0,
            width: w, height: h, fine: false)
        #expect(lp.count == 1 && lp[0].name == "lowPassFreq")
        #expect(lp[0].value == EQParams.lowPassFreqRange.lowerBound)    // 1 kHz floor
    }

    @Test("⇧ fine scales the drag rate to 0.25×")
    func dragFine() {
        let w = Self.width, h = Self.height
        let writes = EQCurveEditorModel.dragWrites(
            band: .peak1, startFrequency: 500, startGainDb: 0,
            translationX: w / 3, translationY: -h / 8,
            width: w, height: h, fine: true)
        // A quarter of w/3 = w/12 → ×1000^(1/12); a quarter of +6 dB = +1.5.
        let expectedFreq = 500 * pow(1_000, 1.0 / 12.0)
        #expect(abs(writes[0].value - expectedFreq) < expectedFreq * 1e-9)
        #expect(abs(writes[1].value - 1.5) < 1e-12)
    }

    // MARK: - §8.3 Q laws (⌥-drag + scroll)

    @Test("⌥-drag maps Q·2^(−dy/48pt), clamped 0.1…18; nil for HP/LP")
    func qDragLaw() {
        // 48 pt up = double the Q; 48 pt down = halve it.
        let up = EQCurveEditorModel.qDragWrite(
            band: .peak1, startQ: 1, translationY: -48, fine: false)
        #expect(up?.name == "peak1Q")
        #expect(abs((up?.value ?? 0) - 2) < 1e-12)
        let down = EQCurveEditorModel.qDragWrite(
            band: .peak1, startQ: 1, translationY: 48, fine: false)
        #expect(abs((down?.value ?? 0) - 0.5) < 1e-12)
        // ⇧ fine quarters the exponent: 48 pt up → 2^0.25.
        let fine = EQCurveEditorModel.qDragWrite(
            band: .peak1, startQ: 1, translationY: -48, fine: true)
        #expect(abs((fine?.value ?? 0) - pow(2, 0.25)) < 1e-12)
        // Clamps to the spec range at both ends.
        let high = EQCurveEditorModel.qDragWrite(
            band: .peak1, startQ: 16, translationY: -96, fine: false)
        #expect(high?.value == EQParams.qRange.upperBound)
        let low = EQCurveEditorModel.qDragWrite(
            band: .peak1, startQ: 0.5, translationY: 240, fine: false)
        #expect(low?.value == EQParams.qRange.lowerBound)
        // Shelves write their Q names; cut bands have NO Q gesture.
        #expect(EQCurveEditorModel.qDragWrite(
            band: .lowShelf, startQ: 1, translationY: -48, fine: false)?.name == "lowShelfQ")
        #expect(EQCurveEditorModel.qDragWrite(
            band: .highPass, startQ: 1, translationY: -48, fine: false) == nil)
        #expect(EQCurveEditorModel.qDragWrite(
            band: .lowPass, startQ: 1, translationY: -48, fine: false) == nil)
    }

    @Test("scroll maps Q·2^(Δy·0.05), clamped; nil for cut bands")
    func scrollLaw() {
        let up = EQCurveEditorModel.scrollWrite(
            band: .peak2, currentQ: 1, deltaY: 20, fine: false)
        #expect(up?.name == "peak2Q")
        #expect(abs((up?.value ?? 0) - 2) < 1e-9)
        let down = EQCurveEditorModel.scrollWrite(
            band: .peak2, currentQ: 1, deltaY: -20, fine: false)
        #expect(abs((down?.value ?? 0) - 0.5) < 1e-9)
        let fine = EQCurveEditorModel.scrollWrite(
            band: .peak2, currentQ: 1, deltaY: 20, fine: true)
        #expect(abs((fine?.value ?? 0) - pow(2, 0.25)) < 1e-9)
        let clamped = EQCurveEditorModel.scrollWrite(
            band: .peak2, currentQ: 16, deltaY: 200, fine: false)
        #expect(clamped?.value == EQParams.qRange.upperBound)
        #expect(EQCurveEditorModel.scrollWrite(
            band: .highPass, currentQ: 1, deltaY: 20, fine: false) == nil,
                "scroll over a cut band falls through — no window-scroll hijack")
    }

    // MARK: - §5.2 Keyboard nudges

    @Test("←/→ nudge ∓1/12 octave, ↑/↓ ±0.5 dB; ⇧ = 1/48 octave / 0.1 dB")
    func nudgeLaw() {
        let p = EQParams()
        let right = EQCurveEditorModel.nudgeWrites(
            band: .peak1, params: p, key: .right, fine: false)
        #expect(right.map(\.name) == ["peak1Freq"])
        #expect(abs(right[0].value - 500 * pow(2, 1.0 / 12.0)) < 1e-9)
        let left = EQCurveEditorModel.nudgeWrites(
            band: .peak1, params: p, key: .left, fine: false)
        #expect(abs(left[0].value - 500 * pow(2, -1.0 / 12.0)) < 1e-9)
        let fineRight = EQCurveEditorModel.nudgeWrites(
            band: .peak1, params: p, key: .right, fine: true)
        #expect(abs(fineRight[0].value - 500 * pow(2, 1.0 / 48.0)) < 1e-9)
        let up = EQCurveEditorModel.nudgeWrites(
            band: .peak1, params: p, key: .up, fine: false)
        #expect(up.map(\.name) == ["peak1GainDb"])
        #expect(up[0].value == 0.5)
        let down = EQCurveEditorModel.nudgeWrites(
            band: .peak1, params: p, key: .down, fine: false)
        #expect(down[0].value == -0.5)
        let fineUp = EQCurveEditorModel.nudgeWrites(
            band: .peak1, params: p, key: .up, fine: true)
        #expect(fineUp[0].value == 0.1)
        // Gain nudges clamp to ±24.
        let nearCeiling = EQParams(peak1Freq: 500, peak1GainDb: 23.8)
        let clamped = EQCurveEditorModel.nudgeWrites(
            band: .peak1, params: nearCeiling, key: .up, fine: false)
        #expect(clamped[0].value == 24)
        // Cut bands: vertical nudges emit NOTHING; horizontal moves the
        // corner within its range (the OFF HP pins at its 20 Hz floor).
        #expect(EQCurveEditorModel.nudgeWrites(
            band: .highPass, params: p, key: .up, fine: false).isEmpty)
        let hpLeft = EQCurveEditorModel.nudgeWrites(
            band: .highPass, params: p, key: .left, fine: false)
        #expect(hpLeft.map(\.name) == ["highPassFreq"])
        #expect(hpLeft[0].value == 20)
    }

    // MARK: - §8.3 Double-click enable flip

    @Test("double-click flips *Enabled from the RESOLVED state")
    func toggleWrites() {
        // An enabled band flips off.
        let off = EQCurveEditorModel.toggleWrite(band: .peak1, params: EQParams())
        #expect(off == ("peak1Enabled", 0))
        // A fresh (OFF) HP flips ON — the write that materializes a corner.
        let on = EQCurveEditorModel.toggleWrite(band: .highPass, params: EQParams())
        #expect(on == ("highPassEnabled", 1))
        // An HP with a corner but bypassed also flips ON.
        let bypassed = EQParams(highPassFreq: 250, highPassEnabled: false)
        #expect(EQCurveEditorModel.toggleWrite(band: .highPass, params: bypassed)
                == ("highPassEnabled", 1))
        // A live HP flips OFF.
        let live = EQParams(highPassFreq: 250, highPassEnabled: true)
        #expect(EQCurveEditorModel.toggleWrite(band: .highPass, params: live)
                == ("highPassEnabled", 0))
    }

    // MARK: - §8.3 Write-through (recorded fake apply closure)

    @Test("all gestures write through the wrapped editor's apply closure only")
    func writesThroughRecordedFake() {
        let w = Self.width, h = Self.height
        let (recorder, model) = Self.makeFakeBacked()
        // A freq+gain drag tick: exactly two named writes.
        model.beginDrag(.peak1)
        #expect(recorder.writes.isEmpty, "grabbing writes nothing")
        model.updateDrag(translationX: w / 3, translationY: -h / 8, width: w, height: h)
        #expect(recorder.writes.map(\.name) == ["peak1Freq", "peak1GainDb"])
        #expect(abs(recorder.writes[0].value - 5_000) < 5_000 * 1e-9)
        #expect(abs(recorder.writes[1].value - 6) < 1e-12)
        model.endDrag()
        // After endDrag a stray tick writes nothing.
        model.updateDrag(translationX: 50, translationY: 0, width: w, height: h)
        #expect(recorder.writes.count == 2)
        // ⌥-drag routes the vertical to the Q law (start Q 1 → 2).
        model.beginDrag(.peak1)
        model.updateDrag(translationX: 0, translationY: -48, width: w, height: h,
                         adjustQ: true)
        #expect(recorder.writes.count == 3)
        #expect(recorder.writes[2].name == "peak1Q")
        #expect(abs(recorder.writes[2].value - 2) < 1e-12)
        model.endDrag()
        // Double-click flips the enable.
        model.toggleEnabled(.peak1)
        #expect(recorder.writes[3].name == "peak1Enabled" && recorder.writes[3].value == 0)
        // Scroll resolves to the HOVERED band.
        model.hoveredBand = .peak2
        model.scroll(deltaY: 20)
        #expect(recorder.writes[4].name == "peak2Q")
        #expect(abs(recorder.writes[4].value - 2) < 1e-9)
        // Scroll over a cut band falls through silently.
        model.hoveredBand = .highPass
        model.selectedBand = nil
        model.scroll(deltaY: 20)
        #expect(recorder.writes.count == 5)
        // Keyboard nudges act on the SELECTED band.
        model.selectedBand = .peak1
        model.hoveredBand = nil
        model.nudge(.up)
        #expect(recorder.writes[5].name == "peak1GainDb" && recorder.writes[5].value == 0.5)
    }

    @Test("double-click on the OFF HP materializes the default corner (m22-a law)")
    func storeBackedToggleMaterializesHP() {
        let (store, model) = Self.makeCurveModel()
        #expect(model.handles[0].isEnabled == false)
        model.toggleEnabled(.highPass)
        let eq = store.tracks[0].effects[0].resolvedEQ
        #expect(eq.resolvedHighPassEnabled)
        #expect(eq.highPassFreq == 20, "enabling materializes the spec default corner")
        #expect(model.handles[0].isEnabled, "the handle reads live through the editor")
        // Off again KEEPS the corner (bypass, not reset).
        model.toggleEnabled(.highPass)
        let off = store.tracks[0].effects[0].resolvedEQ
        #expect(!off.resolvedHighPassEnabled && off.highPassFreq == 20)
    }

    // MARK: - §8.3 Wire parity (UI == wire seam)

    @Test("a recorded gesture replayed via setEffectParam yields the identical EQ")
    func wireParityReplay() {
        let w = Self.width, h = Self.height
        let recorder = Self.WriteRecorder()
        let (storeA, model) = Self.makeCurveModel(recorder: recorder)
        // A representative session: a diagonal drag (several ticks), an
        // ⌥-drag Q shape, a scroll, and an enable toggle.
        model.beginDrag(.peak1)
        model.updateDrag(translationX: w / 6, translationY: -h / 16, width: w, height: h)
        model.updateDrag(translationX: w / 3, translationY: -h / 8, width: w, height: h)
        model.endDrag()
        model.beginDrag(.peak1)
        model.updateDrag(translationX: 0, translationY: -30, width: w, height: h,
                         adjustQ: true)
        model.endDrag()
        model.hoveredBand = .highShelf
        model.scroll(deltaY: 10)
        model.toggleEnabled(.lowPass)
        #expect(!recorder.writes.isEmpty)
        // Replay the exact recorded (name, value) stream through the SAME
        // store method `fx.setParam` calls, on a second store.
        let storeB = ProjectStore()
        let track = storeB.addTrack(kind: .audio)
        let fx = try! storeB.addEffect(toTrack: track.id, kind: .eq)
        for write in recorder.writes {
            _ = try! storeB.setEffectParam(trackID: track.id, effectID: fx.id,
                                           name: write.name, value: write.value)
        }
        #expect(storeA.tracks[0].effects[0].resolvedEQ
                == storeB.tracks[0].effects[0].resolvedEQ,
                "the curve editor and the wire must land on the identical descriptor")
    }

    // MARK: - §5.2 Drag readout (the EffectEditorModel.readout formats, reused)

    @Test("dragReadout composes the knob strip's exact readout formats")
    func dragReadoutFormats() {
        let (store, model) = Self.makeCurveModel()
        let track = store.tracks[0]
        _ = try! store.setEffectParam(trackID: track.id, effectID: track.effects[0].id,
                                      name: "peak1Freq", value: 1_020)
        _ = try! store.setEffectParam(trackID: track.id, effectID: track.effects[0].id,
                                      name: "peak1GainDb", value: 3.5)
        _ = try! store.setEffectParam(trackID: track.id, effectID: track.effects[0].id,
                                      name: "peak1Q", value: 1.4)
        model.beginDrag(.peak1)
        #expect(model.dragReadout == "1.02 kHz · +3.5 dB · Q 1.40")
        model.endDrag()
        #expect(model.dragReadout == nil, "the chip drops with the drag")
        // Negative gain carries the readout's own sign — no double mark.
        _ = try! store.setEffectParam(trackID: track.id, effectID: track.effects[0].id,
                                      name: "peak1GainDb", value: -6)
        #expect(EQCurveEditorModel.dragReadout(
            band: .peak1, params: store.tracks[0].effects[0].resolvedEQ)
            == "1.02 kHz · -6.0 dB · Q 1.40")
        // A cut band reads frequency only.
        _ = try! store.setEffectParam(trackID: track.id, effectID: track.effects[0].id,
                                      name: "highPassFreq", value: 80)
        model.beginDrag(.highPass)
        #expect(model.dragReadout == "80 Hz")
    }

    // MARK: - §8.3 Spectrum display smoother (§4.1)

    @Test("the smoother rises with attack τ 0.05 and falls with release τ 0.32")
    func spectrumSmootherBallistics() {
        let (_, model) = Self.makeCurveModel()
        #expect(model.spectrumHeights == [Double](repeating: 0, count: 24))
        let loud = MasterAnalysisSnapshot(
            bands: [Float](repeating: -6, count: 24),
            levelDB: -6, peakDB: -6, centroidHz: 1_000, flux: 0)
        // One attack-τ step toward the 0.85 ceiling: 0.85·(1−e⁻¹).
        model.updateSpectrum(with: loud, deltaTime: 0.05)
        let risen = model.spectrumHeights[0]
        #expect(abs(risen - 0.85 * (1 - exp(-1))) < 1e-9)
        // The same dt FALLING moves far less (release τ 0.32) — asymmetry.
        model.updateSpectrum(with: .floor, deltaTime: 0.05)
        let fallen = model.spectrumHeights[0]
        let fallDelta = risen - fallen
        #expect(abs(fallDelta - risen * (1 - exp(-0.05 / 0.32))) < 1e-9)
        #expect(risen > fallDelta, "attack must outpace release for equal dt")
        // Non-positive deltaTime is a no-op (stalled frame never snaps).
        let before = model.spectrumHeights
        model.updateSpectrum(with: loud, deltaTime: 0)
        model.updateSpectrum(with: loud, deltaTime: -1)
        #expect(model.spectrumHeights == before)
    }

    @Test("silence decays to EXACTLY zero; the −72…−6 span maps to 0…0.85")
    func spectrumDecayAndSpan() {
        let (_, model) = Self.makeCurveModel()
        let loud = MasterAnalysisSnapshot(
            bands: [Float](repeating: -6, count: 24),
            levelDB: -6, peakDB: -6, centroidHz: 1_000, flux: 0)
        model.updateSpectrum(with: loud, deltaTime: 0.5)
        #expect(model.spectrumHeights[0] > 0.5)
        // A stopped session decays to NOTHING — exact zero, not an asymptote.
        for _ in 0..<200 {
            model.updateSpectrum(with: .floor, deltaTime: 0.1)
        }
        #expect(model.spectrumHeights == [Double](repeating: 0, count: 24))
        // The span pins: −6 dB → 0.85 of plot height, −72 and the −80 floor
        // → 0, the midpoint −39 → 0.425; above-ceiling clamps to 0.85.
        #expect(EQCurveEditorModel.spectrumHeight(forDB: -6) == 0.85)
        #expect(EQCurveEditorModel.spectrumHeight(forDB: -72) == 0)
        #expect(EQCurveEditorModel.spectrumHeight(forDB: -80) == 0)
        #expect(abs(EQCurveEditorModel.spectrumHeight(forDB: -39) - 0.425) < 1e-9)
        #expect(EQCurveEditorModel.spectrumHeight(forDB: 0) == 0.85)
    }

    @Test("spectrum bands draw at their TRUE 40 Hz→16 kHz geometric edges")
    func spectrumBandEdgeMapping() {
        let w = Self.width
        // The restated formula matches MasterMixAnalyzer.bandEdges: 25
        // geometric edges 40·(16000/40)^(k/24).
        for k in 0...24 {
            let expected = 40.0 * pow(400.0, Double(k) / 24.0)
            #expect(abs(EQCurveEditorModel.spectrumBandEdgeHz(k) - expected)
                    < expected * 1e-12, "edge \(k)")
        }
        #expect(EQCurveEditorModel.spectrumBandEdgeHz(0) == 40)
        #expect(abs(EQCurveEditorModel.spectrumBandEdgeHz(12) - 800) < 1e-9)
        #expect(abs(EQCurveEditorModel.spectrumBandEdgeHz(24) - 16_000) < 1e-9)
        // On the plot: bands tile contiguously INSIDE the axis — never
        // stretched to fill 20 Hz–20 kHz (§4.1 mapping honesty).
        let first = EQCurveEditorModel.spectrumBandXRange(0, width: w)
        let last = EQCurveEditorModel.spectrumBandXRange(23, width: w)
        #expect(first.lo > 0, "40 Hz sits inside the 20 Hz axis start")
        #expect(last.hi < w, "16 kHz sits inside the 20 kHz axis end")
        for k in 0..<24 {
            let band = EQCurveEditorModel.spectrumBandXRange(k, width: w)
            #expect(band.lo < band.hi)
            if k > 0 {
                let previous = EQCurveEditorModel.spectrumBandXRange(k - 1, width: w)
                #expect(previous.hi == band.lo, "bands tile without gaps")
            }
        }
    }

    @Test("spectrum path points: true-edge anchors, per-band geometric centers, y map")
    func spectrumPathPoints() {
        let w = Self.width, h = Self.height
        let heights = (0..<24).map { Double($0) / 24.0 * 0.85 }
        let points = EQCurveEditorModel.spectrumPathPoints(heights: heights,
                                                           width: w, height: h)
        // One point per band + the two true-edge anchors (Phase 3 fill shape).
        #expect(points.count == 26)
        // Anchors sit at band 0's LOW edge (40 Hz) and band 23's HIGH edge
        // (16 kHz) — inside the axis, never stretched to its 20 Hz/20 kHz ends.
        #expect(abs(points[0].x - EQCurveGeometry.x(forFrequency: 40, in: w)) < 1e-9)
        #expect(abs(points[25].x - EQCurveGeometry.x(forFrequency: 16_000, in: w)) < 1e-9)
        #expect(points[0].x > 0 && points[25].x < w)
        // Anchors carry their neighbor band's height.
        #expect(points[0].y == points[1].y)
        #expect(points[25].y == points[24].y)
        // Band k's point sits at its geometric-center frequency √(lo·hi).
        for k in 0..<24 {
            let lo = EQCurveEditorModel.spectrumBandEdgeHz(k)
            let hi = EQCurveEditorModel.spectrumBandEdgeHz(k + 1)
            let expectedX = EQCurveGeometry.x(forFrequency: (lo * hi).squareRoot(), in: w)
            #expect(abs(points[k + 1].x - expectedX) < 1e-9, "band \(k) center x")
            // y = height · (1 − fraction), the bottom-anchored fill map.
            #expect(abs(points[k + 1].y - h * (1 - heights[k])) < 1e-9, "band \(k) y")
        }
        // x strictly increases (a drawable left-to-right silhouette).
        for i in 1..<points.count {
            #expect(points[i].x > points[i - 1].x)
        }
        // Out-of-range heights clamp to the 0…1 fraction span; empty = empty.
        let clamped = EQCurveEditorModel.spectrumPathPoints(
            heights: [Double](repeating: 2, count: 24), width: w, height: h)
        #expect(clamped.allSatisfy { $0.y == 0 })
        #expect(EQCurveEditorModel.spectrumPathPoints(heights: [], width: w, height: h)
                    .isEmpty)
    }

    @Test("slopeParamName: the HP/LP chip names only; nil for gain bands")
    func slopeParamNames() {
        #expect(EQCurveEditorModel.slopeParamName(for: .highPass) == "highPassSlopeDbPerOct")
        #expect(EQCurveEditorModel.slopeParamName(for: .lowPass) == "lowPassSlopeDbPerOct")
        for band in [Band.lowShelf, .peak1, .peak2, .highShelf] {
            #expect(EQCurveEditorModel.slopeParamName(for: band) == nil, "\(band)")
        }
        // The names resolve in the fx.describe schema (never a dead write).
        let specs = EffectParamSpec.specs(for: .eq)
        for band in [Band.highPass, .lowPass] {
            let name = EQCurveEditorModel.slopeParamName(for: band)!
            #expect(specs.contains { $0.name == name }, Comment(rawValue: name))
        }
    }

    // MARK: - §8.3 Density + selection sync

    @Test("the Simple/Pro density chip renders for the eq kind ONLY")
    func densityChipEqOnly() {
        #expect(EQCurveEditorModel.showsDensityChip(for: .eq))
        for kind in EffectDescriptor.Kind.allCases where kind != .eq {
            #expect(!EQCurveEditorModel.showsDensityChip(for: kind), "\(kind)")
        }
        #expect(!EQCurveEditorModel.showsDensityChip(for: nil))
    }

    @Test("handle and band-strip selection share ONE property; hover is separate")
    func selectionSync() {
        let (_, model) = Self.makeCurveModel()
        #expect(model.selectedBand == nil)
        // The strip cell writes the same property the handles read.
        model.selectedBand = .peak2
        #expect(model.selectedBand == .peak2)
        // Grabbing a handle selects its band.
        model.beginDrag(.highShelf)
        #expect(model.selectedBand == .highShelf)
        model.endDrag()
        // The strip's ON toggle selects too (clicking a cell selects, §5.5).
        model.toggleEnabled(.lowShelf)
        #expect(model.selectedBand == .lowShelf)
        // Hover never disturbs selection.
        model.hoveredBand = .peak1
        #expect(model.selectedBand == .lowShelf)
        #expect(model.hoveredBand == .peak1)
    }

    @Test("a closed or non-eq editor yields no params, handles, or writes")
    func closedYieldsNothing() {
        let store = ProjectStore()
        let editor = Self.makeStoreBacked(store)
        let model = EQCurveEditorModel(editor: editor, sampleRate: 48_000)
        #expect(model.params == nil)
        #expect(model.handles.isEmpty)
        #expect(model.compositeCurve(width: Self.width, height: Self.height).isEmpty)
        #expect(model.hitTest(x: 0, y: 0, width: Self.width, height: Self.height) == nil)
        model.beginDrag(.peak1)
        #expect(model.dragReadout == nil)
        model.toggleEnabled(.peak1)   // silently nothing — no target to write
        // A non-eq insert is equally inert on this surface.
        let track = store.addTrack(kind: .audio)
        let comp = try! store.addEffect(toTrack: track.id, kind: .compressor)
        editor.prepare(trackID: track.id, effectID: comp.id, targetLabel: "on Test")
        #expect(model.params == nil && model.handles.isEmpty)
    }

    // MARK: - §8.4 Recompute bound (m23-ab-2)
    //
    // ORIGINAL SHAPE (pre-m23-ab-2): `#expect(best < .milliseconds(1))` on a
    // best-of-5 `ContinuousClock` measurement, no longer present anywhere in
    // this suite — §8.4's 1 ms figure is a DESIGN TARGET now, not something
    // any test pins. A wall-clock absolute is the single most
    // load-contaminated quantity a process can measure — best-of-N narrows
    // variance around a median that itself moves when the whole machine is
    // busy — and this suite carried no `.serialized`, so a sibling suite
    // saturating every core moved the median directly. MEASURED on this
    // machine: unloaded best-of-5 is ~650-750 µs at `-Onone` (`swift test`'s
    // build mode — NOT measured at `-O`, so the shipped "expected < 100 µs"
    // comment's own accuracy at `-O` is unverified), i.e. already 65-75% of
    // the 1 ms budget with ZERO load, which is why load alone was enough to
    // tip it over.
    //
    // FIX: assert a RATIO against a same-process, same-run CPU-bound
    // calibration instead of an absolute bound. Under load, a saturated
    // machine slows BOTH the recompute and the calibration by (approximately
    // — see the K derivation below for the one measured asymmetry) the same
    // factor — both are pure single-threaded floating-point work, no locks,
    // no allocation, no I/O — so the ratio stays put while either side's
    // absolute time does not. This is the control-group idea applied to
    // timing. TRADE-OFF, stated plainly: the new bound catches recompute
    // regressions ≥ 2.6× (K = 2.5 against a ~0.95 healthy ratio); the old
    // absolute bound nominally caught ≥ 1.4× (1 ms / ~0.7 ms healthy), but
    // that headline number was never honest — MEASURED here, full-suite load
    // alone moved `recomputeAll`'s absolute best-of-5 from ~650-750 µs
    // isolated to ~850-1025 µs loaded (roughly 1.2-1.6×) with NO regression
    // at all, which is the whole reason the old bound flaked.

    /// A fixed, DELIBERATELY UNRELATED CPU-bound operation (no shared code
    /// with `EQFilterResponse`/`EQCurveGeometry`, so a real regression in the
    /// geometry math still moves the ratio) — transcendental/sqrt/log work
    /// with no allocation, no locks, no syscalls, so contention affects it
    /// the same way it affects `recomputeAll`. Iteration count (30_000) was
    /// chosen so its OWN unloaded cost lands in the same order of magnitude
    /// as `recomputeAll`'s (~650-750 µs on this machine, -Onone) — see the
    /// `recomputeBudgetK` derivation below for the measured numbers.
    private static func calibrationWork(_ iterations: Int) -> Double {
        var acc = 0.0
        var x = 0.137
        var i = 0
        while i < iterations {
            x = sin(x) + cos(x * 1.0000001)
            acc += (abs(x) + 1e-9).squareRoot() + log(abs(x) + 1e-9)
            i += 1
        }
        return acc
    }
    private static let calibrationIterations = 30_000

    /// `Duration` → `Double` seconds, for ratio arithmetic (`Duration` has no
    /// direct division into a scalar).
    private static func secondsOf(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// MEASURED 2026-07-29 (m23-ab-2), this machine, `./scripts/test.sh`
    /// build mode: `recomputeAll/calibrationWork(30_000)` ratio, best-of-5 on
    /// each side, for the CURRENT (correct) implementation —
    ///   - 5 isolated `--filter` runs (50 samples): [0.814, 1.139]
    ///   - 3 full-suite runs, 446 suites concurrent (30 samples): [0.804, 1.167]
    ///   - 1 run under 20 additional CPU-bound background processes
    ///     (10 samples, deliberately adversarial): [0.494, 1.192]
    /// Combined ceiling ≈ 1.19. K = 2.5 sits with ≈ 2.1× margin above that —
    /// so this bound catches recompute regressions ≥ 2.6× the healthy ratio
    /// (2.5 / ~0.95) IN ISOLATION. That sensitivity is not a constant: it
    /// moves with whatever the healthy ratio happens to be on a given run,
    /// and the healthy ratio itself spans [0.494, 1.192] across the samples
    /// above. At the low end (0.494, the adversarial-load sample with an
    /// inflated calibration denominator) a regression must reach ~5.1× to
    /// trip K before the healthy-leg noise would; at the high end (1.192) it
    /// only needs ~2.1×. Read "≥ 2.6×" as the isolated/typical case, not a
    /// guaranteed floor across all conditions.
    ///
    /// The regression side needed a SECOND round of measurement: a first
    /// attempt at `recomputeRegressionTripsCalibratedBudget` used a 4×
    /// (not 8×) mutation and, under the SAME 20-process adversarial load
    /// above, produced ratios in [2.92, 4.18] — one sample only 1.17× above
    /// K, i.e. a NEW load-sensitive near-miss replacing the one this fix
    /// removed. Cause, measured: that adversarial load inflates the
    /// CALIBRATION denominator too (`calib` samples up to 0.0015-0.0016 s
    /// against a typical 0.0007 s, ~2.2×) in the SAME runs that produced the
    /// healthy leg's 1.19 ceiling — the ratio's numerator and denominator are
    /// only APPROXIMATELY common-mode under adversarial scheduling, not
    /// perfectly so. 8× moves the unloaded regression ratio to ~7.4-7.8 and,
    /// re-measured under the identical adversarial load, gave [5.71, 7.76]
    /// (10 samples) — the worst case still ≈ 2.28× above K, comparable
    /// margin to the healthy leg's 2.1×.
    private static let recomputeBudgetK = 2.5

    @Test("composite + 6 band curves on the 256-pt grid recompute within a calibrated CPU budget")
    func recomputeStaysWithinCalibratedBudget() {
        // The §8.2 F7 rich param set — every band active, ~8 live sections.
        let rich = EQParams(
            lowShelfFreq: 150, lowShelfGainDb: -4,
            peak1Freq: 800, peak1GainDb: 5, peak1Q: 3,
            peak2Freq: 2_500, peak2GainDb: -6, peak2Q: 0.8,
            highShelfFreq: 8_000, highShelfGainDb: 3,
            highPassFreq: 120, highPassSlopeDbPerOct: 24, highPassEnabled: true,
            lowPassFreq: 12_000, lowPassSlopeDbPerOct: 12, lowPassEnabled: true,
            lowShelfQ: 2)
        let w = Self.width, h = Self.height
        func recomputeAll() -> Int {
            var points = EQCurveGeometry.compositeCurve(
                params: rich, sampleRate: 48_000, width: w, height: h).count
            for band in Band.allCases {
                points += EQCurveGeometry.bandCurve(
                    band, params: rich, sampleRate: 48_000, width: w, height: h).count
            }
            return points
        }
        let clock = ContinuousClock()

        // Warm up once, then take the best of 5 on BOTH sides (CI-noise-safe;
        // each approximates its own unloaded cost).
        #expect(recomputeAll() == 256 * 7)
        var bestRecompute = Duration.seconds(1)
        var total = 0
        for _ in 0..<5 {
            let elapsed = clock.measure { total += recomputeAll() }
            if elapsed < bestRecompute { bestRecompute = elapsed }
        }
        #expect(total == 256 * 7 * 5)

        _ = Self.calibrationWork(Self.calibrationIterations)
        var bestCalibration = Duration.seconds(1)
        for _ in 0..<5 {
            let elapsed = clock.measure { _ = Self.calibrationWork(Self.calibrationIterations) }
            if elapsed < bestCalibration { bestCalibration = elapsed }
        }

        let ratio = Self.secondsOf(bestRecompute) / Self.secondsOf(bestCalibration)
        print("m23-ab-2 recompute/calibration: recompute=\(bestRecompute) "
              + "calibration=\(bestCalibration) ratio=\(ratio)")
        #expect(ratio < Self.recomputeBudgetK,
                "§8.4/m23-ab-2: full recompute must stay under \(Self.recomputeBudgetK)× a same-process, same-run CPU calibration (load-invariant by construction)")
    }

    /// Proves the bound above has teeth, WITHOUT literally reddening the
    /// shipped test — the same "fidelity NEGATIVE" convention
    /// `InsertSpectrumTapTests.fidelityDiscriminatorSeesADroppedBlock` uses:
    /// perturb the thing under test, then assert the SAME assertion shape
    /// now goes the other way. Here the perturbation is calling the real
    /// `recomputeAll` 8× instead of once — a genuine regression class (an
    /// Observation-driven surface recomputing every frame instead of once
    /// per param change), not an arbitrary `sleep`. Nothing about "8" is
    /// load-bearing — the job is to show the bound has teeth at all, not to
    /// find the smallest detectable regression.
    ///
    /// 4× WAS TRIED FIRST AND REJECTED, MEASURED: under the same 20-process
    /// adversarial load used for the healthy leg's ceiling, a 4× regression's
    /// ratio ranged [2.92, 4.18] — one sample landed only 1.17× above K, i.e.
    /// the fix would have shipped a NEW load-sensitive near-miss to replace
    /// the one it removed, because that adversarial load inflates the
    /// CALIBRATION denominator (not just the numerator) by up to ~2.2× in the
    /// same runs that produced the healthy leg's ceiling (`calib` samples of
    /// 0.0015-0.0016 s against a typical 0.0007 s) — a ratio's numerator and
    /// denominator are not perfectly common-mode under adversarial
    /// scheduling, only APPROXIMATELY so. 8× moves the unloaded ratio to
    /// ~7.6 (2× the 4× case), which absorbs the same ~2.2× denominator
    /// inflation with room to spare — MEASURED below.
    @Test("m23-ab-2 discriminator: a recompute-runs-8×-instead-of-once regression trips the calibrated budget")
    func recomputeRegressionTripsCalibratedBudget() {
        let rich = EQParams(
            lowShelfFreq: 150, lowShelfGainDb: -4,
            peak1Freq: 800, peak1GainDb: 5, peak1Q: 3,
            peak2Freq: 2_500, peak2GainDb: -6, peak2Q: 0.8,
            highShelfFreq: 8_000, highShelfGainDb: 3,
            highPassFreq: 120, highPassSlopeDbPerOct: 24, highPassEnabled: true,
            lowPassFreq: 12_000, lowPassSlopeDbPerOct: 12, lowPassEnabled: true,
            lowShelfQ: 2)
        let w = Self.width, h = Self.height
        func recomputeAll() -> Int {
            var points = EQCurveGeometry.compositeCurve(
                params: rich, sampleRate: 48_000, width: w, height: h).count
            for band in Band.allCases {
                points += EQCurveGeometry.bandCurve(
                    band, params: rich, sampleRate: 48_000, width: w, height: h).count
            }
            return points
        }
        func regressedRecomputeAll8x() -> Int {
            var last = 0
            for _ in 0..<8 { last = recomputeAll() }
            return last
        }
        let clock = ContinuousClock()

        _ = regressedRecomputeAll8x()
        var bestRegressed = Duration.seconds(1)
        for _ in 0..<5 {
            let elapsed = clock.measure { _ = regressedRecomputeAll8x() }
            if elapsed < bestRegressed { bestRegressed = elapsed }
        }

        _ = Self.calibrationWork(Self.calibrationIterations)
        var bestCalibration = Duration.seconds(1)
        for _ in 0..<5 {
            let elapsed = clock.measure { _ = Self.calibrationWork(Self.calibrationIterations) }
            if elapsed < bestCalibration { bestCalibration = elapsed }
        }

        let regressedRatio = Self.secondsOf(bestRegressed) / Self.secondsOf(bestCalibration)
        print("m23-ab-2 discriminator: regressed(8x)/calibration ratio=\(regressedRatio), "
              + "budget K=\(Self.recomputeBudgetK)")
        #expect(regressedRatio > Self.recomputeBudgetK,
                "an 8× recompute regression must trip the same K the healthy leg is held to — if this doesn't redden, the calibrated budget has no discriminating power")
    }

    // MARK: - m23-r3: the spectrum gate + the pre/post-fader labelling law

    @Test("m23-r3: the spectrum layer draws on EVERY open EQ card, not just master")
    func spectrumGateCoversTrackCards() {
        let master = EffectEditorTarget(trackID: nil, effectID: UUID())
        let track = EffectEditorTarget(trackID: UUID(), effectID: UUID())
        // m22-b drew it on master alone (no per-track tap existed). Since
        // m23-r1/r2a/r2b there IS one, so a track card draws too.
        #expect(EQCurveEditorModel.showsSpectrum(for: master))
        #expect(EQCurveEditorModel.showsSpectrum(for: track))
        // No card, no layer.
        #expect(!EQCurveEditorModel.showsSpectrum(for: nil))
    }

    @Test("m23-r3: the MASTER card's spectrum caption is byte-identical to m22-b's")
    func masterSpectrumHelpUnchanged() {
        // r3 changed nothing about the master curve: same reading, same words.
        // Pinned against the LITERAL, never against the source expression.
        let master = EffectEditorTarget(trackID: nil, effectID: UUID())
        let expected = "The green fill is the live master-mix spectrum — context only; "
            + "its height is not the EQ's dB scale."
        #expect(EQCurveEditorModel.curveHelp(for: master, isMeasuring: true) == expected)
        // A master card is always measuring — `masterAnalysis()` needs no arm —
        // so the caption must not fork on that flag either.
        #expect(EQCurveEditorModel.curveHelp(for: master, isMeasuring: false) == expected)
    }

    @Test("m23-r3: a TRACK card's caption says post-EQ AND pre-fader, and differs from master's")
    func trackSpectrumHelpStatesPreFader() {
        let track = EQCurveEditorModel.curveHelp(
            for: EffectEditorTarget(trackID: UUID(), effectID: UUID()), isMeasuring: true)
        let master = EQCurveEditorModel.curveHelp(
            for: EffectEditorTarget(trackID: nil, effectID: UUID()), isMeasuring: true)
        // THE LABELLING LAW (m23-r2b measurement): a strip insert taps
        // PRE-fader (a 1.0 → 0.5 track-fader move shifts the tapped 1 kHz band
        // by 0.0 dB) while a master insert taps POST-fader (the same move
        // shifts it 6.0206 dB). Two different measurements in identical green
        // ink must never share a caption.
        #expect(track != master)
        #expect(!track.contains("master-mix"))
        // It has to say BOTH things: which point in the chain, and which side
        // of the fader — the second is what stops "I pulled the fader and the
        // meter didn't move, so it's broken".
        #expect(track.contains("AFTER this EQ"))
        #expect(track.contains("BEFORE the fader"))
        #expect(track.contains("fader will not move it"))
        // Still context, not a dB readout — the m22-b honesty clause survives.
        #expect(track.contains("not the EQ's dB scale"))
    }

    @Test("m23-r3: a track card that is NOT measuring says so instead of promising a live reading")
    func trackSpectrumHelpIsHonestWhenUnarmed() {
        let track = EffectEditorTarget(trackID: UUID(), effectID: UUID())
        let unarmed = EQCurveEditorModel.curveHelp(for: track, isMeasuring: false)
        let armed = EQCurveEditorModel.curveHelp(for: track, isMeasuring: true)
        #expect(unarmed != armed)
        // A refused/absent tap draws the honest floor, never a fabricated
        // curve — so the caption must not claim a live reading over it.
        #expect(!unarmed.contains("live spectrum"))
        #expect(unarmed.contains("not running"))
        #expect(unarmed.contains("honest, not a silent track"))
    }

    @Test("m23-r3: the no-spectrum caption is the plain curve hint")
    func curveOnlyHelpUnchanged() {
        #expect(EQCurveEditorModel.curveOnlyHelp == "Drag a handle to shape the EQ curve.")
        // No card ⇒ no spectrum layer ⇒ the whole caption resolves to the hint,
        // in the SAME call the card makes: one function owns the whole line, so
        // no call site can pick a branch of its own.
        #expect(EQCurveEditorModel.curveHelp(for: nil, isMeasuring: true)
                == EQCurveEditorModel.curveOnlyHelp)
    }

    // MARK: - m23-r4 L9: InsertSpectrumTapPoint agrees with this UI caption

    @Test("m23-r4: InsertSpectrumTapPoint.forInsert(trackID:) agrees with the pinned UI captions above — one fact, two readers that must never drift apart")
    func tapPointAgreesWithCurveHelp() {
        let trackID = UUID()
        #expect(InsertSpectrumTapPoint.forInsert(trackID: trackID).wireValue
                == "postInsertPreFader")
        #expect(InsertSpectrumTapPoint.forInsert(trackID: nil).wireValue
                == "postInsertPostFader")

        // The pinned track caption (trackSpectrumHelpStatesPreFader above)
        // says "BEFORE the fader" for exactly the target
        // InsertSpectrumTapPoint.forInsert classifies preInsertPreFader —
        // a real track id. If either side's mapping ever flipped alone,
        // this assertion (not just the two above) would redden.
        let trackHelp = EQCurveEditorModel.curveHelp(
            for: EffectEditorTarget(trackID: trackID, effectID: UUID()), isMeasuring: true)
        #expect(trackHelp.contains("BEFORE the fader"),
                "the track card's caption and InsertSpectrumTapPoint.postInsertPreFader must describe the SAME fact")
    }
}
