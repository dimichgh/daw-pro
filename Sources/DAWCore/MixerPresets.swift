import Foundation

// MARK: - Mixer preset catalog (M7 macro-b)

/// One curated, named mixer preset: a tone-shaping insert chain that REPLACES a
/// strip's current effect chain as ONE undoable edit. Presets are TONE, not
/// balance — volume/pan/sends are never touched. Only the built-in FX pack may
/// appear in a preset chain (the 4-band EQ, the soft-knee compressor, the
/// lookahead limiter, the gain effect). The `CopilotToolCatalog` precedent: a
/// static, versioned, code-defined catalog, not user data.
public struct MixerPreset: Sendable, Equatable {
    /// Stable kebab-case identifier — the wire/enum value ("drum-bus-glue").
    public let name: String
    /// Beginner-readable display name — also the undo label body:
    /// "Apply Preset '<displayName>'".
    public let displayName: String
    /// One beginner-readable sentence describing the sound the preset gives.
    public let summary: String
    /// The insert chain, in chain order, as fully-specified built-in effect
    /// descriptors. Templates carry throwaway ids; `freshChain()` mints new ids
    /// per apply (see `applyMixerPreset`) so effect ids never collide across
    /// strips.
    public let chain: [EffectDescriptor]

    public init(name: String, displayName: String, summary: String, chain: [EffectDescriptor]) {
        self.name = name
        self.displayName = displayName
        self.summary = summary
        self.chain = chain
    }

    /// The chain with fresh effect ids — presets mint new effect instances on
    /// every apply so two strips carrying the same preset still have distinct
    /// `effectId`s (fx.* commands address effects by id).
    public func freshChain() -> [EffectDescriptor] { chain.map { $0.withFreshID() } }
}

extension EffectDescriptor {
    /// A copy carrying the same kind/params/bypass but a brand-new id. Used by
    /// mixer presets so a template descriptor can be stamped onto many strips.
    func withFreshID() -> EffectDescriptor {
        EffectDescriptor(
            kind: kind,
            isBypassed: isBypassed,
            gain: gain,
            eq: eq,
            compressor: compressor,
            limiter: limiter,
            reverb: reverb,
            delay: delay,
            saturator: saturator,
            gate: gate,
            chorus: chorus,
            audioUnit: audioUnit)
    }
}

/// The v1 curated preset catalog. Six musical intents mapped onto the real
/// built-in effect param surfaces (values kept sane; each choice is commented).
///
/// DESIGN NOTE — no dedicated high-pass filter exists in the built-in EQ, so
/// every "rumble cut / sub trim" intent is expressed as the CLOSEST available
/// shape: a low-shelf band with negative gain (attenuates the low end rather
/// than steeply removing it). This is a deliberate approximation, not a missing
/// effect — we never add new effect types for a preset.
public enum MixerPresetCatalog {
    /// Every v1 preset, in catalog order (matches the MCP enum ordering).
    public static let v1: [MixerPreset] = [
        drumBusGlue,
        vocalPresence,
        bassTight,
        masterGlue,
        warmKeys,
        cleanBoost,
    ]

    /// Lookup by kebab-case name; `nil` when unknown.
    public static func preset(named name: String) -> MixerPreset? {
        v1.first { $0.name == name }
    }

    /// Every valid preset name, in catalog order (for the enum + error listing).
    public static var names: [String] { v1.map(\.name) }

    // MARK: Presets

    /// Gentle bus glue for a drum submix: a 4:1 compressor at a moderate
    /// threshold with a slow-ish attack (lets transients through) and a musical
    /// ~100 ms release, then a light tonal lift — a small low-shelf for weight
    /// and a broad upper-mid presence bell for snap. Order: EQ shapes, then the
    /// compressor glues the shaped signal.
    static let drumBusGlue = MixerPreset(
        name: "drum-bus-glue",
        displayName: "Drum Bus Glue",
        summary: "Gently compresses a drum group so it sounds like one punchy kit, with a touch of low-end weight and upper-mid snap.",
        chain: [
            EffectDescriptor(kind: .eq, eq: EQParams(
                lowShelfFreq: 100, lowShelfGainDb: 2,   // small low-shelf lift for weight
                peak2Freq: 4_000, peak2GainDb: 2, peak2Q: 1)), // broad upper-mid presence bell
            EffectDescriptor(kind: .compressor, compressor: CompressorParams(
                thresholdDb: -18,  // moderate threshold
                ratio: 4,          // ~4:1 glue
                attackMs: 30,      // slow-ish: preserve transients
                releaseMs: 100,    // musical release
                kneeDb: 6)),
        ])

    /// Vocal presence & control: an EQ that trims low rumble (low-shelf cut),
    /// adds a ~3 kHz presence bell and a gentle high-shelf "air", followed by a
    /// 3:1 compressor with a fairly fast 10 ms attack to even out the level.
    static let vocalPresence = MixerPreset(
        name: "vocal-presence",
        displayName: "Vocal Presence",
        summary: "Makes a lead vocal sit forward and clear — cuts low rumble, lifts presence around 3 kHz, adds a little air, then smooths the level.",
        chain: [
            EffectDescriptor(kind: .eq, eq: EQParams(
                lowShelfFreq: 100, lowShelfGainDb: -3,   // low rumble shelf cut (no HPF available)
                peak1Freq: 3_000, peak1GainDb: 2.5, peak1Q: 1, // ~3 kHz presence bell
                highShelfFreq: 10_000, highShelfGainDb: 2)),   // gentle high-shelf air
            EffectDescriptor(kind: .compressor, compressor: CompressorParams(
                thresholdDb: -18,
                ratio: 3,          // ~3:1
                attackMs: 10,      // faster attack: catch consonants
                releaseMs: 100,
                kneeDb: 6)),
        ])

    /// Tight, controlled bass: EQ trims sub rumble and a little low-mid mud,
    /// then a firm 4:1 compressor with a fast 5 ms attack clamps the dynamics so
    /// the bass stays even in the mix.
    static let bassTight = MixerPreset(
        name: "bass-tight",
        displayName: "Bass Tight",
        summary: "Keeps a bass part steady and defined — trims sub rumble and low-mid mud, then firmly evens out the dynamics.",
        chain: [
            EffectDescriptor(kind: .eq, eq: EQParams(
                lowShelfFreq: 40, lowShelfGainDb: -3,     // sub rumble trimmed (low-shelf, no HPF)
                peak1Freq: 250, peak1GainDb: -2, peak1Q: 1)), // small low-mid control cut
            EffectDescriptor(kind: .compressor, compressor: CompressorParams(
                thresholdDb: -20,
                ratio: 4,          // firm ~4:1
                attackMs: 5,       // fast attack: clamp peaks
                releaseMs: 100,
                kneeDb: 6)),
        ])

    /// Master-bus glue and safety: a low-ratio 2:1 compressor at a low
    /// threshold with a ~30 ms attack for gentle cohesion, then a brickwall
    /// limiter with a -1 dB ceiling as the final peak stop. Order: compressor
    /// glues, limiter catches whatever is left (ceiling must be last).
    static let masterGlue = MixerPreset(
        name: "master-glue",
        displayName: "Master Glue",
        summary: "Ties a whole mix together with light overall compression, then holds the peaks just under 0 dB so nothing clips.",
        chain: [
            EffectDescriptor(kind: .compressor, compressor: CompressorParams(
                thresholdDb: -12,  // low threshold: only the loudest peaks
                ratio: 2,          // ~2:1 gentle glue
                attackMs: 30,      // slow-ish: keep punch
                releaseMs: 100,
                kneeDb: 6)),
            EffectDescriptor(kind: .limiter, limiter: LimiterParams(
                ceilingDb: -1)),   // ~-1 dB brickwall ceiling
        ])

    /// Warm keys tone: an EQ-only preset that gently rolls the high shelf down
    /// (~-1.5 dB, softens brightness) and nudges the low shelf up (~+1 dB, adds
    /// body) — a subtle, tasteful warmth with no dynamics processing.
    static let warmKeys = MixerPreset(
        name: "warm-keys",
        displayName: "Warm Keys",
        summary: "Softens a bright keyboard or synth — eases off the top end and adds a little low-end body for a warmer tone.",
        chain: [
            EffectDescriptor(kind: .eq, eq: EQParams(
                lowShelfFreq: 100, lowShelfGainDb: 1,       // low shelf slightly up: body
                highShelfFreq: 8_000, highShelfGainDb: -1.5)), // high shelf slightly down: warmth
        ])

    /// Clean level boost: a single gain effect at +3 dB and nothing else — a
    /// transparent trim-up. +3 dB in linear is 10^(3/20).
    static let cleanBoost = MixerPreset(
        name: "clean-boost",
        displayName: "Clean Boost",
        summary: "Simply turns the track up by about 3 dB with no tone change — a clean level lift.",
        chain: [
            EffectDescriptor(kind: .gain, gain: GainParams(gainLinear: pow(10, 3.0 / 20.0))),
        ])
}

// MARK: - Apply (store method)

extension ProjectStore {
    /// Applies a curated mixer preset to a track/bus strip: the preset's insert
    /// chain REPLACES the strip's current chain as ONE undoable edit
    /// ("Apply Preset '<displayName>'") — undo restores the exact prior chain.
    /// Volume, pan, and sends are untouched (presets are tone, not balance).
    /// Works on audio, instrument, and bus tracks alike.
    ///
    /// Guards OUTSIDE the edit body (the fx.* precedent): unknown track →
    /// `trackNotFound`; unknown preset → `mixerPresetNotFound` whose message
    /// lists every valid preset name. The replacement publishes through the same
    /// atomic `performEdit` snapshot the fx.* commands use — never a piecemeal
    /// live-graph mutation (M4 convention). Returns the updated track so the
    /// control layer / callers can echo the resulting chain.
    @discardableResult
    public func applyMixerPreset(trackID: UUID, presetName: String) throws -> Track {
        guard let ti = tracks.firstIndex(where: { $0.id == trackID }) else {
            throw ProjectError.trackNotFound(trackID)
        }
        guard let preset = MixerPresetCatalog.preset(named: presetName) else {
            let valid = MixerPresetCatalog.names.joined(separator: ", ")
            throw ProjectError.mixerPresetNotFound(
                "unknown mixer preset '\(presetName)' — valid: \(valid)")
        }
        let newChain = preset.freshChain()
        performEdit("Apply Preset '\(preset.displayName)'") {
            tracks[ti].effects = newChain
            engine?.tracksDidChange(tracks)
        }
        return tracks[ti]
    }
}
