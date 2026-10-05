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
            bassEnhancer: bassEnhancer,
            bitCrusher: bitCrusher,
            djFilter: djFilter,
            ringMod: ringMod,
            flanger: flanger,
            hallReverb: hallReverb,
            tapeDelay: tapeDelay,
            stereoWidth: stereoWidth,
            phaser: phaser,
            // ⛔⛔ THIS LINE IS COMPILER-SILENT AND SO IS EVERY LINE ABOVE IT.
            // `EffectDescriptor.init`'s params are ALL `= nil`-defaulted, so a
            // rebuild call site that omits a kind compiles cleanly and SILENTLY
            // DROPS IT — a preset containing that kind would stamp onto a strip
            // with the right kind and default values. No gate covers this file
            // (`effect-kind-surface.mjs` does not list it as a surface);
            // `MixerPresetsTests`' per-kind preset round trip is the only
            // instrument, and it is driven from `Kind.allCases`.
            transientShaper: transientShaper,
            freqShifter: freqShifter,
            clipper: clipper,
            dynamicEQ: dynamicEQ,
            audioUnit: audioUnit)
    }
}

/// The v1 curated preset catalog. Twelve musical intents mapped onto the real
/// built-in effect param surfaces (values kept sane; each choice is commented).
/// `v1` GROWS IN PLACE — the six m26-p additions are appended AFTER the original
/// six so catalog order (and therefore the MCP enum's order) stays stable, and
/// no existing preset is retuned. The `CopilotToolCatalog` precedent: a version
/// is a SHAPE, not a length.
///
/// DESIGN NOTE — "rumble cut / sub trim" intents are expressed as a low-shelf
/// band with NEGATIVE gain (attenuating the low end rather than steeply
/// removing it), never as a high-pass.
/// ⚠️ CORRECTED 2026-08-18 (m26-p): this note used to claim "no dedicated
/// high-pass filter exists in the built-in EQ". That WAS true when the catalog
/// was written and m22-a (EQ v2) made it FALSE — `EQParams.highPassFreq` /
/// `highPassSlopeDbPerOct` / `highPassEnabled` are real fields today. The
/// negative low-shelf survives as a DELIBERATE HOUSE STYLE, not as a
/// workaround: every preset here predates the high-pass, retuning them would
/// change the sound of existing projects, and a catalog where half the presets
/// trim with a shelf and half with a filter is harder to reason about than one
/// that is consistent. New presets follow the shelf. A preset still never adds
/// a new effect TYPE for its own sake.
public enum MixerPresetCatalog {
    /// Every v1 preset, in catalog order (matches the MCP enum ordering).
    public static let v1: [MixerPreset] = [
        drumBusGlue,
        vocalPresence,
        bassTight,
        masterGlue,
        warmKeys,
        cleanBoost,
        // m26-p additions — appended, never interleaved (order is wire-visible).
        bassRound,
        guitarCrunch,
        acousticSparkle,
        hornSection,
        drumRoom,
        lofiTape,
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

    // MARK: m26-p additions

    /// ⭐ THE DELIBERATE COUNTERPART TO `bass-tight` (m26-p, from the 2026-08-17
    /// field report's N6). A blues/jazz/soul bass wants to BLOOM — the note
    /// swells after the pluck — and `bass-tight`'s firm 4:1 at a 5 ms attack
    /// catches that swell and flattens it. This preset inverts BOTH of those
    /// numbers on purpose:
    ///
    ///   | | `bass-tight` | `bass-round` |
    ///   |---|---|---|
    ///   | low end | −3 dB shelf (trimmed) | +2 dB shelf (weight) |
    ///   | ratio | 4:1 | 2.5:1 |
    ///   | attack | 5 ms (clamps the pluck) | 20 ms (lets it through) |
    ///
    /// The threshold is DELIBERATELY IDENTICAL (−20 dB) so the two presets
    /// differ in HOW they compress, not in how much signal they see — that is
    /// what makes the pair legible, and a test pins the ratio/attack direction
    /// so a later "tidy-up" cannot quietly converge them.
    static let bassRound = MixerPreset(
        name: "bass-round",
        displayName: "Bass Round",
        summary: "Warm, singing bass that keeps its bloom — adds low-end weight and lets each note swell before compressing gently. Pick this over 'bass-tight' for blues, jazz, soul and anything played with feel; pick 'bass-tight' when the bass must sit rock-steady under a dense mix.",
        chain: [
            EffectDescriptor(kind: .eq, eq: EQParams(
                lowShelfFreq: 80, lowShelfGainDb: 2,          // low-shelf LIFT for weight (bass-tight cuts here)
                peak1Freq: 300, peak1GainDb: -1.5, peak1Q: 1, // gentle low-mid trim: clarity without thinning
                highShelfFreq: 6_000, highShelfGainDb: -1.5)), // slight top roll-off: singing, not clacky
            EffectDescriptor(kind: .compressor, compressor: CompressorParams(
                thresholdDb: -20,  // SAME as bass-tight on purpose — only the shape differs
                ratio: 2.5,        // LOW ratio: guides the level, never clamps it
                attackMs: 20,      // SLOW attack: the note blooms before the compressor catches it
                releaseMs: 150,    // longer release: no pumping between notes
                kneeDb: 9)),       // softer knee than bass-tight's 6 — the reduction eases in
        ])

    /// Driven electric guitar. Saturator FIRST (it generates the harmonics),
    /// then the EQ shapes what the drive produced — the reverse order would
    /// distort an already-scooped signal and lose the bite the EQ just added.
    static let guitarCrunch = MixerPreset(
        name: "guitar-crunch",
        displayName: "Guitar Crunch",
        summary: "Gives an electric guitar a driven, gritty edge — adds harmonic crunch, clears the muddy low-mids, and lifts the bite that cuts through a band.",
        chain: [
            EffectDescriptor(kind: .saturator, saturator: SaturatorParams(
                driveDb: 9,        // moderate grit (range 0...36; 12 is the default "obvious" drive)
                mix: 0.8,          // mostly wet, a little clean signal left for pick definition
                outputDb: -2)),    // trim back the level the drive added
            EffectDescriptor(kind: .eq, eq: EQParams(
                lowShelfFreq: 100, lowShelfGainDb: -2,           // trim boom that fights the bass
                peak1Freq: 400, peak1GainDb: -3, peak1Q: 1.2,    // scoop the low-mid mud
                peak2Freq: 2_500, peak2GainDb: 3, peak2Q: 1,     // lift the bite that cuts through
                highShelfFreq: 10_000, highShelfGainDb: -1)),    // tame the fizz the drive adds up top
        ])

    /// Acoustic guitar, EQ-only (the `warm-keys` precedent — no dynamics where
    /// the intent is purely tonal): out with the box, in with the string.
    static let acousticSparkle = MixerPreset(
        name: "acoustic-sparkle",
        displayName: "Acoustic Sparkle",
        summary: "Opens up an acoustic guitar — takes out the boxy honk, brings back the shimmer of the strings and a little air on top.",
        chain: [
            EffectDescriptor(kind: .eq, eq: EQParams(
                lowShelfFreq: 90, lowShelfGainDb: -2,            // trim body boom (low-shelf, the house style)
                peak1Freq: 300, peak1GainDb: -2.5, peak1Q: 1.2,  // the "boxy" band on a mic'd acoustic
                peak2Freq: 5_000, peak2GainDb: 2, peak2Q: 1,     // string presence and pick detail
                highShelfFreq: 10_000, highShelfGainDb: 2.5)),   // air
        ])

    /// Brass presence and control: shape first, then even the level. Horns swing
    /// 10+ dB between a held note and a stab, so the compressor is the point —
    /// but a 15 ms attack still lets the blat of the attack through.
    static let hornSection = MixerPreset(
        name: "horn-section",
        displayName: "Horn Section",
        summary: "Makes horns sound bold and even — brings out the brassy core, softens the harsh edge, and stops the loud stabs jumping out of the mix.",
        chain: [
            EffectDescriptor(kind: .eq, eq: EQParams(
                lowShelfFreq: 80, lowShelfGainDb: -2,             // trim room rumble under the horns
                peak1Freq: 800, peak1GainDb: 2, peak1Q: 1,        // the brassy core
                peak2Freq: 3_500, peak2GainDb: -2.5, peak2Q: 1.5, // tame the harsh blare
                highShelfFreq: 10_000, highShelfGainDb: 1)),      // a little sheen back on top
            EffectDescriptor(kind: .compressor, compressor: CompressorParams(
                thresholdDb: -16,
                ratio: 3,          // ~3:1 — control, not clamp
                attackMs: 15,      // slow enough to let the attack "blat" through
                releaseMs: 120,
                kneeDb: 6)),
        ])

    /// Kit in a room. A REVERB-ONLY chain (the `clean-boost` precedent — one
    /// effect where one effect is the whole intent): a short, damped, modest-mix
    /// space so the kit breathes without the mix going wet.
    static let drumRoom = MixerPreset(
        name: "drum-room",
        displayName: "Drum Room",
        summary: "Puts the drums in a small live room — they breathe and sound less flat, while staying dry and up front.",
        chain: [
            EffectDescriptor(kind: .reverb, reverb: ReverbParams(
                roomSize: 0.35,    // small-to-medium room, not a hall (range 0...1)
                damping: 0.6,      // soft walls: the tail loses its top quickly
                mix: 0.18,         // MODEST — the kit stays dry and up front
                preDelayMs: 12,    // keeps the stick attack clear of the tail
                width: 0.9)),      // wide, just short of fully spread
        ])

    /// Tape/vinyl character. Saturator first for the tape-style harmonics, then
    /// the EQ dulls what came out — the aged top end IS the effect, so the
    /// high-shelf cut has to sit AFTER the drive that would otherwise re-add it.
    static let lofiTape = MixerPreset(
        name: "lofi-tape",
        displayName: "Lo-Fi Tape",
        summary: "Gives a track the warm, dulled sound of old tape or vinyl — soft harmonic fuzz, rolled-off treble and a boxy midrange.",
        chain: [
            EffectDescriptor(kind: .saturator, saturator: SaturatorParams(
                driveDb: 6,        // gentle: character, not distortion
                mix: 0.7,          // blended, so transients survive
                outputDb: -1)),
            EffectDescriptor(kind: .eq, eq: EQParams(
                lowShelfFreq: 60, lowShelfGainDb: -2,           // thin the sub, like a worn tape
                peak1Freq: 900, peak1GainDb: 1.5, peak1Q: 0.8,  // boxy "old radio" midrange bump
                highShelfFreq: 6_000, highShelfGainDb: -4)),    // THE aged, dulled top end
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
