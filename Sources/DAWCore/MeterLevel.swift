import Foundation

/// THE one home for turning a LINEAR meter amplitude (`MeterFrame.peak` /
/// `MeterFrame.rms` — 0…1+, where >1 means the signal clipped) into dBFS.
///
/// WHY A NAMED SINGLE HOME FOR THREE CHARACTERS OF ARITHMETIC: `20·log10(x)`
/// is exactly the kind of computation that gets re-typed at each call site
/// until two of them quietly disagree about the floor, about what a zero
/// amplitude means, or about whether the result may be `-inf`. Every
/// meter-derived decibel figure in this project comes from here.
///
/// FLOOR: −80 dBFS — the house floor, taken from `MasterAnalysisSnapshot
/// .floorDB` rather than re-declared, so there is one floor as well as one
/// formula. That is the same floor `MasterMixAnalyzer` clamps its bands,
/// level and peak to (its amplitude epsilon 1e-4 is 20·log10 → −80 by
/// construction).
///
/// FINITE BY CONTRACT: these numbers are JSON-encoded (`project.overview`),
/// and JSON has no `-inf` and no `NaN` — an infinity here is an encode
/// failure, or a decode failure downstream, not a cosmetic wart. A zero,
/// negative, infinite or `NaN` amplitude therefore reads as the floor.
///
/// NEIGHBOURS THAT ARE A DIFFERENT QUANTITY and deliberately do NOT route
/// through here (checked at m23-cv — this list is the audit, keep it true):
///  - `MixerFormat.dbString(forGain:)` (DAWAppKit) converts a FADER/SEND
///    CONTROL VALUE into a display string. It describes where a knob is set,
///    not what was measured, and renders its floor as `"-∞"` for a human
///    rather than as a number for an agent.
///  - `Loudness` (LUFS / dBTP) is gated BS.1770 PROGRAM loudness measured
///    over rendered audio, not an instantaneous meter frame.
///  - `SegmentMeter` / `MiniLevelBar` light their segments from the LINEAR
///    fraction directly and never convert to dB at all, so there is no UI
///    copy of this computation to fold in. If a numeric dB readout is ever
///    added to a meter view, it must call this.
public enum MeterLevel {
    /// The house dB floor, −80 dBFS. Not a new constant: the `Double` form of
    /// `MasterAnalysisSnapshot.floorDB`, which is what every other level-like
    /// field in the project already clamps to.
    public static let floorDb = Double(MasterAnalysisSnapshot.floorDB)

    /// Linear meter amplitude → dBFS, clamped at ``floorDb`` and ALWAYS finite.
    ///
    /// `1.0` → `0`, `0.5` → ≈`-6.02`, `2.0` → ≈`+6.02` (clipping reads
    /// positive), `0` → `-80`.
    public static func dbFS(_ amplitude: Float) -> Double {
        let linear = Double(amplitude)
        // Zero, negative, NaN and ±inf all mean "there is no usable amplitude
        // here". Reporting the floor keeps the result finite and encodable;
        // `log10(0)` would be `-inf` and `log10(-1)` would be `NaN`.
        guard linear.isFinite, linear > 0 else { return floorDb }
        return max(floorDb, 20 * log10(linear))
    }
}

extension MeterFrame {
    /// This frame's peak in dBFS (floor −80, always finite). Positive means
    /// the track clipped. See ``MeterLevel`` — the one conversion.
    public var peakDb: Double { MeterLevel.dbFS(peak) }

    /// This frame's RMS in dBFS (floor −80, always finite) — "how loud does
    /// this sit", where ``peakDb`` is "did it clip". See ``MeterLevel``.
    public var rmsDb: Double { MeterLevel.dbFS(rms) }

    /// True when this frame carries measurable, USABLE signal.
    ///
    /// Two jobs in one predicate, both needed by the retained-meter store
    /// (`ProjectStore.lastNonSilentTrackMeters`, m23-cv): a `.silence` frame
    /// must not overwrite a real reading, and a non-finite frame — a broken
    /// engine push, not a loud one — must never be retained either, because
    /// it would be published as the floor and read as "this track is quiet"
    /// when the truth is "this measurement is garbage". A missing entry says
    /// "nothing observed", which is the honest answer in both cases.
    public var hasSignal: Bool {
        peak.isFinite && rms.isFinite && (peak > 0 || rms > 0)
    }
}
