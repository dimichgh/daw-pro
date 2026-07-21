import Foundation
import Observation
import DAWCore

// MARK: - Plot geometry (pure, non-isolated — Canvas @Sendable closures may call it)

/// The EQ curve editor's fixed plot geometry (m22-b Phase 2, design
/// docs/research/design-m22b-eq-curve-editor.md §5.1): log₂-frequency x over
/// a FIXED 20 Hz → 20 kHz axis (deliberately NOT `EffectEditorModel.Scale`'s
/// per-spec range mapping — every band shares one axis; per-band spec
/// clamping still applies on write), linear-dB y over ±24
/// (`EQParams.gainDbRange`) with 0 dB at center, the grid line positions +
/// beginner-readable label strings, and curve path point generation over
/// `EQFilterResponse.logFrequencyGrid(count: 256)`.
///
/// Pure `Double` math, no state, no isolation — the Phase 3 Canvas layers
/// compute value captures from this before their `@Sendable` renderer
/// closures run (the m16-a contract). Screen convention: x grows rightward,
/// y grows DOWNWARD (+24 dB at y = 0, −24 dB at y = height).
public enum EQCurveGeometry {
    /// The fixed editor axis (≈ 9.97 octaves) — every band shares it.
    public static let frequencyRange: ClosedRange<Double> = 20...20_000
    /// The linear y axis = `EQParams.gainDbRange` (±24, 0 dB center line).
    public static let dbRange: ClosedRange<Double> = EQParams.gainDbRange
    /// Curve sampling density (§5.1): 256 log-spaced points.
    public static let curveSampleCount = 256

    // MARK: x ↔ frequency (log)

    /// x for a frequency: `width · log(f/20) / log(20000/20)`.
    public static func x(forFrequency frequency: Double, in width: Double) -> Double {
        let f = frequency.clamped(to: frequencyRange)
        return width * log(f / frequencyRange.lowerBound)
            / log(frequencyRange.upperBound / frequencyRange.lowerBound)
    }

    /// The inverse (for hit-testing and drags), clamped to the axis so an
    /// off-plot pointer can never produce a runaway value.
    public static func frequency(forX x: Double, in width: Double) -> Double {
        guard width > 0 else { return frequencyRange.lowerBound }
        let f = frequencyRange.lowerBound
            * pow(frequencyRange.upperBound / frequencyRange.lowerBound, x / width)
        return f.clamped(to: frequencyRange)
    }

    // MARK: y ↔ dB (linear, +24 at top)

    public static func y(forDb db: Double, in height: Double) -> Double {
        let d = db.clamped(to: dbRange)
        return height * (dbRange.upperBound - d)
            / (dbRange.upperBound - dbRange.lowerBound)
    }

    public static func db(forY y: Double, in height: Double) -> Double {
        guard height > 0 else { return 0 }
        let d = dbRange.upperBound
            - (dbRange.upperBound - dbRange.lowerBound) * y / height
        return d.clamped(to: dbRange)
    }

    // MARK: Grid (§5.1: hairlines every 6 dB; the beginner-readable Hz decade marks)

    /// Horizontal hairline positions — every 6 dB including the 0 dB center.
    public static let dbGridLines: [Double] = [-18, -12, -6, 0, 6, 12, 18]

    /// Label for a dB hairline: signed "+6"/"-12" (SF Mono, `textDim`); the
    /// 0 dB center line carries no label (it is the drawn center line).
    public static func dbGridLabel(_ db: Double) -> String? {
        guard db != 0 else { return nil }
        return db > 0 ? "+\(Int(db))" : "\(Int(db))"
    }

    /// Vertical hairline frequencies — beginner-readable decade marks.
    public static let frequencyGridLines: [Double] =
        [20, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000]

    /// Label for a frequency hairline: "100" below 1 kHz, "1k"/"10k" style
    /// above — no scientific notation, ever (§5.1 beginner rule).
    public static func frequencyGridLabel(_ hz: Double) -> String {
        hz >= 1_000 ? "\(Int(hz / 1_000))k" : "\(Int(hz))"
    }

    // MARK: Curve path points (composite + per-band, §5.1)

    /// The glowing composite curve: 256 log-spaced points of
    /// `EQFilterResponse.responseDb`, dB clamped to the ±24 plot so HP/LP
    /// skirts CLIP at the plot edge (§5.1). Main-actor tier — recomputed only
    /// on param/sample-rate change (Observation-driven), never per frame.
    public static func compositeCurve(params: EQParams, sampleRate: Double,
                                      width: Double, height: Double) -> [CGPoint] {
        let grid = EQFilterResponse.logFrequencyGrid(
            count: curveSampleCount,
            lo: frequencyRange.lowerBound, hi: frequencyRange.upperBound)
        return grid.map { f in
            CGPoint(x: x(forFrequency: f, in: width),
                    y: y(forDb: EQFilterResponse.responseDb(
                            params: params, frequency: f, sampleRate: sampleRate),
                         in: height))
        }
    }

    /// One logical band's dim curve — `EQFilterResponse.bandResponseDb` over
    /// the same grid (an inactive band draws the flat 0 dB line).
    public static func bandCurve(_ band: EQFilterResponse.Band,
                                 params: EQParams, sampleRate: Double,
                                 width: Double, height: Double) -> [CGPoint] {
        let grid = EQFilterResponse.logFrequencyGrid(
            count: curveSampleCount,
            lo: frequencyRange.lowerBound, hi: frequencyRange.upperBound)
        return grid.map { f in
            CGPoint(x: x(forFrequency: f, in: width),
                    y: y(forDb: EQFilterResponse.bandResponseDb(
                            band, params: params, frequency: f, sampleRate: sampleRate),
                         in: height))
        }
    }
}

// MARK: - The headless curve editor model

/// Headless state machine for the EQ FREQUENCY-CURVE editor surface (m22-b
/// Phase 2, design §5/§5.6): handle layout from `EQParams` via the
/// `resolved*` accessors, 28 pt hit-testing, and the drag / ⌥-drag / scroll /
/// keyboard / double-click interaction math — each producing plain
/// `[(name, value)]` deltas that route through the wrapped
/// `EffectEditorModel.set(name:value:)`, the SAME injected
/// `setEffectParam`/`setMasterEffectParam` closures the knob strip and the
/// wire's `fx.setParam` use (UI == wire; per-(chain, effect, name) undo
/// coalescing comes free). **This model owns ZERO store access** — every
/// write is `editor.set`, every read is the editor's live descriptor.
///
/// Also home to the spectrum DISPLAY smoother (§4.1): a per-band asymmetric
/// one-pole in the `VibeMeterModel.smooth` idiom (attack τ 0.05 s / release
/// τ 0.32 s, the house ballistics) over `MasterAnalysisSnapshot` band input,
/// mapped over the −72…−6 dB span to 0…0.85 of the plot height; silence
/// decays to NOTHING (a sub-threshold value snaps to exactly 0). The
/// per-frame update mutates the preallocated array in place — no allocation
/// on the timeline tick.
///
/// NO VIOLET anywhere on this surface — an EQ curve is standard mixing
/// chrome, not AI content (docs/DESIGN-LANGUAGE.md Rule 3; §4.2 colors:
/// signal-green spectrum, playback-cyan composite, neutral band curves).
@MainActor
@Observable
public final class EQCurveEditorModel {
    public typealias Band = EQFilterResponse.Band

    /// The wrapped knob-strip model — the ONLY write path and the live
    /// descriptor reader (a wire `fx.setParam` moves the curve live).
    private let editor: EffectEditorModel
    /// The engine's render rate, injected at open time
    /// (`ProjectStore.renderSampleRateHz()`, §3.4) — coefficients near
    /// Nyquist depend on it. Headless/stub sessions honestly pass 48 k.
    public let sampleRate: Double

    // MARK: Selection / hover / readout state (§5.2, §5.5)

    /// The selected band — shared by the handle layer AND the band strip
    /// (§5.5 "clicking a cell selects that band"), so the two can never
    /// disagree: one property IS the sync.
    public var selectedBand: Band?
    /// The hovered handle (bright rest state; scroll-over-plot resolves to
    /// hovered ?? selected).
    public var hoveredBand: Band?
    /// The SF Mono chip near a dragged handle — e.g.
    /// "1.02 kHz · +3.5 dB · Q 1.40" — composed from the exact
    /// `EffectEditorModel.readout` formats (§5.2; consistency with the knob
    /// strip). nil when no drag is live.
    public private(set) var dragReadout: String?

    // MARK: Spectrum display state (§4.1)

    /// Smoothed per-band spectrum heights, 0…`spectrumMaxHeight` fractions of
    /// the plot height (24 analysis bands, bass → treble). Context, not a
    /// measurement readout — NO y-axis relationship with the EQ-gain scale.
    ///
    /// `@ObservationIgnored` ON PURPOSE (the `VibeSmoother` scratch idiom,
    /// VibeMeterView.swift): the spectrum layer's own `TimelineView` drives
    /// every frame and reads this fresh each tick, so observation buys nothing
    /// — while `updateSpectrum` mutating an OBSERVED property from inside the
    /// timeline's view-update closure would schedule a redundant invalidation
    /// every frame (exactly the churn §5.3 isolates the spectrum to prevent).
    @ObservationIgnored public private(set) var spectrumHeights: [Double]

    /// A live drag's captured origin (band + start freq/gain/Q) — translations
    /// apply against this, so a drag never accumulates rounding.
    private struct DragOrigin {
        let band: Band
        let frequency: Double
        let gainDb: Double
        let q: Double
    }

    private var dragOrigin: DragOrigin?

    public init(editor: EffectEditorModel, sampleRate: Double) {
        self.editor = editor
        self.sampleRate = sampleRate
        self.spectrumHeights = [Double](repeating: 0,
                                        count: MasterAnalysisSnapshot.bandCount)
    }

    // MARK: - Live reads (through the wrapped editor ONLY)

    /// The open insert's resolved EQ params — nil when the editor is closed,
    /// the effect vanished, or the open insert is not an EQ.
    public var params: EQParams? {
        guard let descriptor = editor.descriptor, descriptor.kind == .eq else { return nil }
        return descriptor.resolvedEQ
    }

    /// The six handles for the current params (empty when closed).
    public var handles: [Handle] {
        params.map(Self.handles(params:)) ?? []
    }

    public func compositeCurve(width: Double, height: Double) -> [CGPoint] {
        guard let params else { return [] }
        return EQCurveGeometry.compositeCurve(params: params, sampleRate: sampleRate,
                                              width: width, height: height)
    }

    public func bandCurve(_ band: Band, width: Double, height: Double) -> [CGPoint] {
        guard let params else { return [] }
        return EQCurveGeometry.bandCurve(band, params: params, sampleRate: sampleRate,
                                         width: width, height: height)
    }

    public func hitTest(x: Double, y: Double, width: Double, height: Double) -> Band? {
        guard let params else { return nil }
        return Self.hitTest(x: x, y: y, params: params, width: width, height: height)
    }

    // MARK: - Interaction constants (§5.2)

    /// Generous hit target around a handle center (beginner rule).
    public static let hitRadius = 28.0
    /// The drawn handle dot diameter (the view's constant, pinned here so
    /// tests and the view share one number).
    public static let handleDiameter = 12.0
    /// ⇧ = fine: 0.25× drag rate (⌥ is TAKEN by Q per the roadmap spec — a
    /// deliberate, documented deviation from the knob ⌥-fine convention).
    public static let fineRate = 0.25
    /// ⌥-drag Q law: `Q·2^(−dy/48pt)`.
    public static let qDragDivisorPoints = 48.0
    /// Scroll Q law: `Q·2^(Δy·0.05)`.
    public static let scrollQFactor = 0.05
    /// Keyboard nudge steps (§5.2): ←/→ ∓1/12 octave, ↑/↓ ±0.5 dB;
    /// ⇧ = 1/48 octave / 0.1 dB.
    public static let nudgeOctaves = 1.0 / 12.0
    public static let fineNudgeOctaves = 1.0 / 48.0
    public static let nudgeDb = 0.5
    public static let fineNudgeDb = 0.1

    // MARK: - Band tables (names, ranges, resolved reads)

    /// The per-band FREQ write name — the `fx.describe` schema names.
    public static func freqParamName(for band: Band) -> String {
        switch band {
        case .highPass: return "highPassFreq"
        case .lowShelf: return "lowShelfFreq"
        case .peak1: return "peak1Freq"
        case .peak2: return "peak2Freq"
        case .highShelf: return "highShelfFreq"
        case .lowPass: return "lowPassFreq"
        }
    }

    /// The per-band GAIN write name — nil for HP/LP (pinned to the 0 dB
    /// line; vertical drag is ignored, §5.2).
    public static func gainParamName(for band: Band) -> String? {
        switch band {
        case .highPass, .lowPass: return nil
        case .lowShelf: return "lowShelfGainDb"
        case .peak1: return "peak1GainDb"
        case .peak2: return "peak2GainDb"
        case .highShelf: return "highShelfGainDb"
        }
    }

    /// The per-band Q write name — nil for HP/LP (their steepness is the
    /// 12/24 slope chip in the band strip, not a Q).
    public static func qParamName(for band: Band) -> String? {
        switch band {
        case .highPass, .lowPass: return nil
        case .lowShelf: return "lowShelfQ"
        case .peak1: return "peak1Q"
        case .peak2: return "peak2Q"
        case .highShelf: return "highShelfQ"
        }
    }

    /// The per-band SLOPE write name — HP/LP only (the band strip's 12/24
    /// chip); nil for the gain bands (their width is Q, not a slope).
    public static func slopeParamName(for band: Band) -> String? {
        switch band {
        case .highPass: return "highPassSlopeDbPerOct"
        case .lowPass: return "lowPassSlopeDbPerOct"
        case .lowShelf, .peak1, .peak2, .highShelf: return nil
        }
    }

    /// The per-band bypass name (the double-click toggle target).
    public static func enabledParamName(for band: Band) -> String {
        switch band {
        case .highPass: return "highPassEnabled"
        case .lowShelf: return "lowShelfEnabled"
        case .peak1: return "peak1Enabled"
        case .peak2: return "peak2Enabled"
        case .highShelf: return "highShelfEnabled"
        case .lowPass: return "lowPassEnabled"
        }
    }

    /// Each band's SPEC frequency range (Effects.swift) — drags clamp to it
    /// even though every band shares the full 20 Hz–20 kHz axis.
    public static func frequencyRange(for band: Band) -> ClosedRange<Double> {
        switch band {
        case .highPass: return EQParams.highPassFreqRange
        case .lowShelf: return EQParams.lowShelfFreqRange
        case .peak1, .peak2: return EQParams.peakFreqRange
        case .highShelf: return EQParams.highShelfFreqRange
        case .lowPass: return EQParams.lowPassFreqRange
        }
    }

    /// The handle's SF Mono micro-tag (§5.2: HP·LS·1·2·HS·LP).
    public static func tag(for band: Band) -> String {
        switch band {
        case .highPass: return "HP"
        case .lowShelf: return "LS"
        case .peak1: return "1"
        case .peak2: return "2"
        case .highShelf: return "HS"
        case .lowPass: return "LP"
        }
    }

    /// The band strip's beginner-readable name (§5.5).
    public static func bandName(_ band: Band) -> String {
        switch band {
        case .highPass: return "High Pass"
        case .lowShelf: return "Low Shelf"
        case .peak1: return "Peak 1"
        case .peak2: return "Peak 2"
        case .highShelf: return "High Shelf"
        case .lowPass: return "Low Pass"
        }
    }

    /// The band's displayed frequency: stored freq for gain bands,
    /// `resolved*Freq` for HP/LP (an OFF filter parks at its range edge —
    /// "out of the way", Effects.swift resolved semantics).
    public static func currentFrequency(of band: Band, in params: EQParams) -> Double {
        switch band {
        case .highPass: return params.resolvedHighPassFreq
        case .lowShelf: return params.lowShelfFreq
        case .peak1: return params.peak1Freq
        case .peak2: return params.peak2Freq
        case .highShelf: return params.highShelfFreq
        case .lowPass: return params.resolvedLowPassFreq
        }
    }

    /// The band's gain — nil for HP/LP (drawn pinned to the 0 dB line).
    public static func currentGainDb(of band: Band, in params: EQParams) -> Double? {
        switch band {
        case .highPass, .lowPass: return nil
        case .lowShelf: return params.lowShelfGainDb
        case .peak1: return params.peak1GainDb
        case .peak2: return params.peak2GainDb
        case .highShelf: return params.highShelfGainDb
        }
    }

    /// The band's resolved Q — nil for HP/LP.
    public static func currentQ(of band: Band, in params: EQParams) -> Double? {
        switch band {
        case .highPass, .lowPass: return nil
        case .lowShelf: return params.resolvedLowShelfQ
        case .peak1: return params.peak1Q
        case .peak2: return params.peak2Q
        case .highShelf: return params.resolvedHighShelfQ
        }
    }

    /// The band's resolved enabled state (the dim-hollow test: false = a dim
    /// hollow ring at the stored/resolved position, §5.2).
    public static func isEnabled(_ band: Band, in params: EQParams) -> Bool {
        switch band {
        case .highPass: return params.resolvedHighPassEnabled
        case .lowShelf: return params.resolvedLowShelfEnabled
        case .peak1: return params.resolvedPeak1Enabled
        case .peak2: return params.resolvedPeak2Enabled
        case .highShelf: return params.resolvedHighShelfEnabled
        case .lowPass: return params.resolvedLowPassEnabled
        }
    }

    // MARK: - Handles (§5.2)

    /// One drawable handle: band identity, micro-tag, plot position values,
    /// resolved Q (also the hit-test tie-break weight), and the enabled flag
    /// (false renders the dim hollow ring).
    public struct Handle: Equatable, Sendable {
        public let band: Band
        public let tag: String
        /// Stored freq (gain bands) / resolved corner (HP/LP).
        public let frequency: Double
        /// Stored gain; exactly 0 for HP/LP — pinned to the 0 dB line.
        public let gainDb: Double
        /// Resolved Q; HP/LP carry the 1/√2 Butterworth section Q as their
        /// tie-break weight (they have no user Q).
        public let q: Double
        public let isEnabled: Bool
    }

    /// The six fixed handles, in the §5.2 signal-flow order
    /// (HP·LS·P1·P2·HS·LP = `Band.allCases`).
    public static func handles(params: EQParams) -> [Handle] {
        Band.allCases.map { band in
            Handle(band: band,
                   tag: tag(for: band),
                   frequency: currentFrequency(of: band, in: params),
                   gainDb: currentGainDb(of: band, in: params) ?? 0,
                   q: currentQ(of: band, in: params) ?? EQFilterResponse.butterworth2Q,
                   isEnabled: isEnabled(band, in: params))
        }
    }

    /// A handle's plot-space center.
    public static func handleCenter(_ handle: Handle,
                                    width: Double, height: Double) -> CGPoint {
        CGPoint(x: EQCurveGeometry.x(forFrequency: handle.frequency, in: width),
                y: EQCurveGeometry.y(forDb: handle.gainDb, in: height))
    }

    /// Hit-testing rule (§5.3): nearest handle center within 28 pt wins;
    /// ties break to the smaller-Q (harder-to-grab) band; nothing in range
    /// returns nil (empty-plot double-click is a no-op in v1).
    public static func hitTest(x: Double, y: Double, params: EQParams,
                               width: Double, height: Double) -> Band? {
        var best: (band: Band, distance: Double, q: Double)?
        for handle in handles(params: params) {
            let center = handleCenter(handle, width: width, height: height)
            let distance = ((x - center.x) * (x - center.x)
                + (y - center.y) * (y - center.y)).squareRoot()
            guard distance <= hitRadius else { continue }
            if let current = best {
                if distance < current.distance
                    || (distance == current.distance && handle.q < current.q) {
                    best = (handle.band, distance, handle.q)
                }
            } else {
                best = (handle.band, distance, handle.q)
            }
        }
        return best?.band
    }

    // MARK: - Pure interaction math → [(name, value)] deltas (§5.2)

    /// A freq(x)+gain(y) drag from the captured origin: translations scale by
    /// `fineRate` under ⇧; the new frequency clamps to the BAND's spec range,
    /// gain to ±24. HP/LP emit freq ONLY (vertical is ignored).
    public static func dragWrites(band: Band,
                                  startFrequency: Double, startGainDb: Double,
                                  translationX: Double, translationY: Double,
                                  width: Double, height: Double,
                                  fine: Bool) -> [(name: String, value: Double)] {
        let rate = fine ? fineRate : 1.0
        let startX = EQCurveGeometry.x(forFrequency: startFrequency, in: width)
        let newFrequency = EQCurveGeometry
            .frequency(forX: startX + translationX * rate, in: width)
            .clamped(to: frequencyRange(for: band))
        var writes: [(name: String, value: Double)] = [
            (freqParamName(for: band), newFrequency)
        ]
        if let gainName = gainParamName(for: band) {
            let startY = EQCurveGeometry.y(forDb: startGainDb, in: height)
            let newGain = EQCurveGeometry
                .db(forY: startY + translationY * rate, in: height)
                .clamped(to: EQParams.gainDbRange)
            writes.append((gainName, newGain))
        }
        return writes
    }

    /// ⌥-drag vertical = Q, log-mapped `Q·2^(−dy/48pt)` (up = narrower),
    /// clamped to the 0.1…18 spec range; ⇧ scales the rate. nil for HP/LP.
    public static func qDragWrite(band: Band, startQ: Double,
                                  translationY: Double,
                                  fine: Bool) -> (name: String, value: Double)? {
        guard let qName = qParamName(for: band) else { return nil }
        let rate = fine ? fineRate : 1.0
        let newQ = (startQ * pow(2, -(translationY * rate) / qDragDivisorPoints))
            .clamped(to: EQParams.qRange)
        return (qName, newQ)
    }

    /// Scroll over a hovered/selected band = Q, `Q·2^(Δy·0.05)` per event,
    /// clamped 0.1…18; ⇧ scales the rate. nil for HP/LP (the event falls
    /// through — Q-scroll never hijacks window scroll, §10).
    public static func scrollWrite(band: Band, currentQ: Double,
                                   deltaY: Double,
                                   fine: Bool) -> (name: String, value: Double)? {
        guard let qName = qParamName(for: band) else { return nil }
        let rate = fine ? fineRate : 1.0
        let newQ = (currentQ * pow(2, deltaY * scrollQFactor * rate))
            .clamped(to: EQParams.qRange)
        return (qName, newQ)
    }

    /// Keyboard nudges for the selected handle (§5.2).
    public enum NudgeKey: Sendable {
        case left, right, up, down
    }

    /// ←/→ = ∓1/12 octave (⇧ 1/48), ↑/↓ = ±0.5 dB (⇧ 0.1), from the CURRENT
    /// values, clamped to the band's spec ranges. Vertical nudges on HP/LP
    /// emit nothing (no gain to move).
    public static func nudgeWrites(band: Band, params: EQParams,
                                   key: NudgeKey,
                                   fine: Bool) -> [(name: String, value: Double)] {
        switch key {
        case .left, .right:
            let octaves = (fine ? fineNudgeOctaves : nudgeOctaves)
                * (key == .right ? 1.0 : -1.0)
            let newFrequency = (currentFrequency(of: band, in: params) * pow(2, octaves))
                .clamped(to: frequencyRange(for: band))
            return [(freqParamName(for: band), newFrequency)]
        case .up, .down:
            guard let gainName = gainParamName(for: band),
                  let gain = currentGainDb(of: band, in: params) else { return [] }
            let step = (fine ? fineNudgeDb : nudgeDb) * (key == .up ? 1.0 : -1.0)
            return [(gainName, (gain + step).clamped(to: EQParams.gainDbRange))]
        }
    }

    /// Double-click = `*Enabled` 0/1 flip from the RESOLVED state. Flipping
    /// an OFF HP/LP writes `*Enabled = 1`, which materializes the default
    /// corner store-side — never a silent no-op (the m22-a law).
    public static func toggleWrite(band: Band,
                                   params: EQParams) -> (name: String, value: Double) {
        (enabledParamName(for: band), isEnabled(band, in: params) ? 0 : 1)
    }

    /// The SF Mono drag-readout chip, composed from the EXACT
    /// `EffectEditorModel.readout` formats (§5.2 consistency rule): gain
    /// bands read "1.02 kHz · +3.5 dB · Q 1.40" (positive gain earns an
    /// explicit "+" — the bipolar axis needs the sign), HP/LP just "80 Hz".
    public static func dragReadout(band: Band, params: EQParams) -> String {
        let specs = EffectParamSpec.specs(for: .eq)
        func spec(named name: String) -> EffectParamSpec? {
            specs.first { $0.name == name }
        }
        var parts: [String] = []
        if let freqSpec = spec(named: freqParamName(for: band)) {
            let r = EffectEditorModel.readout(
                value: currentFrequency(of: band, in: params), spec: freqSpec)
            parts.append("\(r.text) \(r.unit)")
        }
        if let gainName = gainParamName(for: band), let gainSpec = spec(named: gainName),
           let gain = currentGainDb(of: band, in: params) {
            let r = EffectEditorModel.readout(value: gain, spec: gainSpec)
            parts.append("\(gain > 0 ? "+" : "")\(r.text) \(r.unit)")
        }
        if let qName = qParamName(for: band), let qSpec = spec(named: qName),
           let q = currentQ(of: band, in: params) {
            let r = EffectEditorModel.readout(value: q, spec: qSpec)
            parts.append("Q \(r.text)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Gestures (stateful; ALL writes via editor.set)

    /// Grabbing a handle: selects the band and captures the drag origin.
    public func beginDrag(_ band: Band) {
        guard let params else { return }
        selectedBand = band
        dragOrigin = DragOrigin(
            band: band,
            frequency: Self.currentFrequency(of: band, in: params),
            gainDb: Self.currentGainDb(of: band, in: params) ?? 0,
            q: Self.currentQ(of: band, in: params) ?? EQFilterResponse.butterworth2Q)
        dragReadout = Self.dragReadout(band: band, params: params)
    }

    /// One drag tick: `adjustQ` (⌥ held) routes the vertical translation to
    /// the Q law; otherwise freq(x)+gain(y). Each changed name is one
    /// `editor.set` — the knob strip's per-tick store-edit cadence, coalesced
    /// per (chain, effect, name) store-side.
    public func updateDrag(translationX: Double, translationY: Double,
                           width: Double, height: Double,
                           adjustQ: Bool = false, fine: Bool = false) {
        guard let origin = dragOrigin else { return }
        if adjustQ {
            if let write = Self.qDragWrite(band: origin.band, startQ: origin.q,
                                           translationY: translationY, fine: fine) {
                apply([write])
            }
        } else {
            apply(Self.dragWrites(band: origin.band,
                                  startFrequency: origin.frequency,
                                  startGainDb: origin.gainDb,
                                  translationX: translationX,
                                  translationY: translationY,
                                  width: width, height: height, fine: fine))
        }
        if let params {
            dragReadout = Self.dragReadout(band: origin.band, params: params)
        }
    }

    /// Drag end: drops the origin and the readout chip.
    public func endDrag() {
        dragOrigin = nil
        dragReadout = nil
    }

    /// A scroll event over the plot, resolved to the hovered ?? selected
    /// band; a cut band (or no band) lets the event fall through.
    public func scroll(deltaY: Double, fine: Bool = false) {
        guard let band = hoveredBand ?? selectedBand, let params,
              let q = Self.currentQ(of: band, in: params),
              let write = Self.scrollWrite(band: band, currentQ: q,
                                           deltaY: deltaY, fine: fine)
        else { return }
        apply([write])
    }

    /// A keyboard nudge on the selected handle.
    public func nudge(_ key: NudgeKey, fine: Bool = false) {
        guard let band = selectedBand, let params else { return }
        apply(Self.nudgeWrites(band: band, params: params, key: key, fine: fine))
    }

    /// Double-click on a handle / the band strip's ON toggle: flips the
    /// band's `*Enabled` and selects it (clicking a cell selects, §5.5).
    public func toggleEnabled(_ band: Band) {
        guard let params else { return }
        selectedBand = band
        let write = Self.toggleWrite(band: band, params: params)
        apply([write])
    }

    /// The single write funnel — `EffectEditorModel.set` is the whole story
    /// (model clamps, store clamps again, coalescing keys, undo — all
    /// inherited; this model owns zero store access).
    private func apply(_ writes: [(name: String, value: Double)]) {
        for write in writes {
            editor.set(name: write.name, value: write.value)
        }
    }

    // MARK: - Density (§6)

    /// The Simple/Pro chip renders ONLY for the eq kind — every other kind's
    /// modes coincide and the density law forbids a do-nothing toggle
    /// (docs/DESIGN-LANGUAGE.md Panels rule).
    public static func showsDensityChip(for kind: EffectDescriptor.Kind?) -> Bool {
        kind == .eq
    }

    // MARK: - Spectrum display smoothing (§4.1)

    /// Band dB maps over −72…−6 (the vibe meter's punchy span,
    /// `VibeMeterModel.bandFloorDB/bandCeilingDB`) to 0…0.85 of the plot
    /// height — context under the curve, never full-bleed.
    public static let spectrumMaxHeight = 0.85
    /// Below this a released band snaps to EXACTLY 0 — silence decays to
    /// nothing, not to a one-pole asymptote (§4.1).
    static let spectrumZeroFloor = 1e-4

    /// One band dB → its target height fraction (0…0.85). Reuses the house
    /// −72…−6 span mapping (`VibeMeterModel.bandMagnitude`).
    public static func spectrumHeight(forDB db: Float) -> Double {
        VibeMeterModel.bandMagnitude(forDB: db) * spectrumMaxHeight
    }

    /// The 25 geometric band edges of the analysis spectrum, 40 Hz → 16 kHz.
    /// This RESTATES the `MasterMixAnalyzer.bandEdges` formula
    /// (Sources/DAWEngine/Analysis/MasterMixAnalyzer.swift:80-83) —
    /// DAWAppKit must not import DAWEngine, and the geometry is a published
    /// contract of the snapshot shape (24 geometric subdivisions of
    /// [40, 16000], `MasterAnalysisSnapshot` doc). The bands draw at their
    /// TRUE edges inside the 20 Hz–20 kHz axis — never stretched to fill it
    /// (§4.1 mapping honesty).
    public static let spectrumLowestBandHz = 40.0
    public static let spectrumHighestBandHz = 16_000.0

    public static func spectrumBandEdgeHz(_ index: Int) -> Double {
        spectrumLowestBandHz * pow(spectrumHighestBandHz / spectrumLowestBandHz,
                                   Double(index) / Double(MasterAnalysisSnapshot.bandCount))
    }

    /// Band `index`'s x extent on the plot (its true geometric edges mapped
    /// through the shared axis).
    public static func spectrumBandXRange(_ index: Int,
                                          width: Double) -> (lo: Double, hi: Double) {
        (EQCurveGeometry.x(forFrequency: spectrumBandEdgeHz(index), in: width),
         EQCurveGeometry.x(forFrequency: spectrumBandEdgeHz(index + 1), in: width))
    }

    /// The spectrum fill's silhouette points for one frame (§4.1 mapping
    /// honesty): the FIRST point sits at band 0's true LOW edge (40 Hz) and
    /// the LAST at band 23's true HIGH edge (16 kHz) — the fill never
    /// stretches to the 20 Hz–20 kHz axis edges — with one point per band at
    /// its geometric-center x. Heights are the smoothed 0…0.85 fractions;
    /// y = height · (1 − fraction), so the view closes the path straight down
    /// to the plot bottom (bottom-anchored fill). Pure — the view calls this
    /// each timeline tick with the freshly advanced `spectrumHeights` (the
    /// small per-frame point buffer is the `VibeMeterView.silhouettePoints`
    /// precedent).
    public static func spectrumPathPoints(heights: [Double],
                                          width: Double, height: Double) -> [CGPoint] {
        guard !heights.isEmpty else { return [] }
        func y(_ fraction: Double) -> Double {
            height * (1 - fraction.clamped(to: 0...1))
        }
        var points: [CGPoint] = []
        points.reserveCapacity(heights.count + 2)
        points.append(CGPoint(x: EQCurveGeometry.x(forFrequency: spectrumBandEdgeHz(0),
                                                   in: width),
                              y: y(heights[0])))
        for (index, fraction) in heights.enumerated() {
            // The band's geometric-center frequency = √(lo·hi), mapped through
            // the shared log axis.
            let centerHz = (spectrumBandEdgeHz(index) * spectrumBandEdgeHz(index + 1))
                .squareRoot()
            points.append(CGPoint(x: EQCurveGeometry.x(forFrequency: centerHz, in: width),
                                  y: y(fraction)))
        }
        points.append(CGPoint(
            x: EQCurveGeometry.x(forFrequency: spectrumBandEdgeHz(heights.count), in: width),
            y: y(heights[heights.count - 1])))
        return points
    }

    /// Advances the smoothed spectrum one frame toward `snapshot`'s mapped
    /// band targets — the `VibeMeterModel.smooth` asymmetric one-pole with
    /// the house ballistics (attack τ 0.05 s, release τ 0.32 s), called each
    /// `TimelineView` tick with the freshly polled snapshot. Mutates the
    /// preallocated array IN PLACE — no allocation per frame. Non-positive
    /// `deltaTime` is a no-op (a stalled frame must not snap the visual).
    public func updateSpectrum(with snapshot: MasterAnalysisSnapshot, deltaTime: Double) {
        guard deltaTime > 0 else { return }
        for i in spectrumHeights.indices {
            let db = i < snapshot.bands.count
                ? snapshot.bands[i] : MasterAnalysisSnapshot.floorDB
            var value = VibeMeterModel.smooth(
                spectrumHeights[i],
                toward: Self.spectrumHeight(forDB: db),
                deltaTime: deltaTime,
                risingTau: VibeMeterModel.attackTau,
                fallingTau: VibeMeterModel.releaseTau)
            if value < Self.spectrumZeroFloor { value = 0 }
            spectrumHeights[i] = value
        }
    }
}
