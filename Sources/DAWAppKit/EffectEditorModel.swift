import Foundation
import Observation
import DAWCore

/// The open effect editor's address: which insert chain hosts the effect —
/// `trackID` nil = the MASTER chain (the `MixerInsertsSection` convention) —
/// plus the effect id. Equatable so "click the open row again" reads as a
/// toggle-close in one comparison.
public struct EffectEditorTarget: Equatable, Sendable {
    public var trackID: UUID?
    public var effectID: UUID

    public init(trackID: UUID?, effectID: UUID) {
        self.trackID = trackID
        self.effectID = effectID
    }
}

/// One SECTION of the grouped knob layout (m17-a v2 — the 2026-07-19
/// knob-vs-slider report §6): a micro-header title ("TRIGGER", "TIME",
/// "OUTPUT") plus the member param specs with their in-group display labels.
/// Groups are the channel-strip precedent (SSL/Cubase/Pro-C3): sections run
/// input/trigger → processing/time → OUTPUT, and the OUTPUT/mix group is
/// always LAST — a hard layout rule, pinned by tests.
public struct EffectParamGroup: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        /// The wire-named spec — the SAME `fx.describe` schema entry.
        public let spec: EffectParamSpec
        /// The in-group display label. Inside a titled band group the
        /// redundant band prefix is dropped ("Low Shelf Freq" → "Freq" under
        /// "LOW SHELF") — the tight-column abbreviation convention (§5).
        public let label: String

        public init(spec: EffectParamSpec, label: String) {
            self.spec = spec
            self.label = label
        }
    }

    /// The section micro-header (already uppercase). Empty = a single-control
    /// card that needs no header (gain).
    public let title: String
    public let items: [Item]

    public init(title: String, items: [Item]) {
        self.title = title
        self.items = items
    }
}

/// Headless state machine for the built-in insert EFFECT EDITOR card (m17-a):
/// the spec-driven parameter rows a generic editor renders for every built-in
/// kind, the current values read from the live `EffectDescriptor`, and the
/// apply path — each edit goes through an injected closure wired to the SAME
/// `ProjectStore.setEffectParam` / `setMasterEffectParam` the wire's
/// `fx.setParam` calls (UI == wire, ZERO new wire surface). No SwiftUI/AppKit:
/// the modal card is thin over this and the tests drive it against fakes or a
/// real store (the `EffectPickerModel` / `QuantizeModel` precedent).
///
/// The editor is Pro-only by construction (it is reached only from the Pro
/// inserts section) and NEVER shows for a hosted AU (those open a plugin
/// window, M3 vi-b — `EffectParamSpec.specs(for: .audioUnit)` is empty and the
/// row never offers the editor). NO VIOLET — standard mixing chrome, not AI
/// content (docs/DESIGN-LANGUAGE.md Rule 3); cyan marks only the genuinely
/// level/gain-flavored readouts.
@MainActor
@Observable
public final class EffectEditorModel {
    /// Reads the LIVE descriptor for (trackID nil = master, effectID) — so a
    /// wire edit (`fx.setParam`) moves the open card's sliders, and a removed
    /// effect reads nil (the card renders nothing rather than a stale ghost).
    private let descriptorProvider: (UUID?, UUID) -> EffectDescriptor?
    /// Applies one validated param — wired to `store.setEffectParam` (track/bus)
    /// or `store.setMasterEffectParam` (master), the fx.setParam twins.
    private let applyParam: (UUID?, UUID, String, Double) throws -> Void
    /// Toggles bypass — wired to `store.setEffectBypassed` / the master twin.
    private let applyBypass: (UUID?, UUID, Bool) throws -> Void
    /// The CURRENT project tempo in BPM (m22-f) — read live so the synced
    /// delay card's derived-time readout tracks tempo edits. Wired to the
    /// store's tempo map at the playhead; defaulted so pre-m22-f call sites
    /// and fakes stay source-compatible.
    private let tempoBPM: () -> Double

    /// The open insert (nil = the model is idle). The card's visibility is the
    /// app model's `effectEditorTarget`; this mirrors it for value reads.
    public private(set) var target: EffectEditorTarget?
    /// The header's context tag ("on Drums" / "on Master") — computed by the
    /// caller at open time (the store owns names, the model just displays).
    public private(set) var targetLabel: String = ""
    /// A store refusal surfaced inline (the SidechainKeyModel idiom). Rare —
    /// the model clamps before applying, so only a vanished target throws.
    public private(set) var lastErrorMessage: String?

    public init(
        descriptor: @escaping (UUID?, UUID) -> EffectDescriptor?,
        apply: @escaping (UUID?, UUID, String, Double) throws -> Void,
        setBypassed: @escaping (UUID?, UUID, Bool) throws -> Void,
        tempoBPM: @escaping () -> Double = { 120 }
    ) {
        self.descriptorProvider = descriptor
        self.applyParam = apply
        self.applyBypass = setBypassed
        self.tempoBPM = tempoBPM
    }

    /// Points the editor at one insert and resets transient state.
    public func prepare(trackID: UUID?, effectID: UUID, targetLabel: String) {
        target = EffectEditorTarget(trackID: trackID, effectID: effectID)
        self.targetLabel = targetLabel
        lastErrorMessage = nil
    }

    /// Clears the target on close, so a stale card can never re-render.
    public func clear() {
        target = nil
        targetLabel = ""
        lastErrorMessage = nil
    }

    // MARK: - Live reads

    /// The open insert's live descriptor (nil = closed or removed).
    public var descriptor: EffectDescriptor? {
        guard let target else { return nil }
        return descriptorProvider(target.trackID, target.effectID)
    }

    public var kind: EffectDescriptor.Kind? { descriptor?.kind }
    public var displayName: String { descriptor.map(MixerFormat.effectDisplayName) ?? "" }
    public var isBypassed: Bool { descriptor?.isBypassed ?? false }

    /// The parameter rows, in schema-declaration order — the SAME
    /// `EffectParamSpec` table `fx.describe` serves (name/min/max/default/unit).
    public var specs: [EffectParamSpec] {
        kind.map { EffectParamSpec.specs(for: $0) } ?? []
    }

    /// The open insert's grouped sections (empty when closed/removed).
    public var groups: [EffectParamGroup] {
        kind.map { Self.groups(for: $0) } ?? []
    }

    // MARK: - Grouped layout (the 2026-07-19 knob-vs-slider report §6)

    /// The per-kind section table: (title, [(wire name, label override)]).
    /// Names only — every range/default/unit still resolves through
    /// `EffectParamSpec.specs(for:)`, the single source of truth, so this
    /// table can never fork the schema. Section order is input/trigger →
    /// processing/time → OUTPUT-last (the SSL/Cubase/Pro-C3 strip precedent).
    private static func groupTable(
        for kind: EffectDescriptor.Kind
    ) -> [(title: String, members: [(name: String, label: String?)])] {
        switch kind {
        case .gain:
            // Two-control card — no header needed. m38-a appends the polarity
            // switch beside the trim, the hardware channel-strip layout (the
            // limiter's `truePeak` sits beside the ceiling it reinterprets for
            // the same reason: the toggle belongs with what it acts on).
            return [("", [("gainLinear", nil), ("invertPolarity", "Polarity")])]
        case .eq:
            // One band per group, low → high (HP first, LP last — signal-flow
            // order); short labels — the band prefix lives in the header (the
            // tight-column abbreviation rule, §5). m22-a: each gain band gets
            // its Q knob and an ON bypass toggle (4 items wrap to a second
            // row in the card); the HP/LP filters are Freq + Slope chip + ON.
            return [
                ("HIGH PASS", [("highPassFreq", "Freq"), ("highPassSlopeDbPerOct", "Slope"),
                               ("highPassEnabled", "On")]),
                ("LOW SHELF", [("lowShelfFreq", "Freq"), ("lowShelfGainDb", "Gain"),
                               ("lowShelfQ", "Q"), ("lowShelfEnabled", "On")]),
                ("PEAK 1", [("peak1Freq", "Freq"), ("peak1GainDb", "Gain"), ("peak1Q", "Q"),
                            ("peak1Enabled", "On")]),
                ("PEAK 2", [("peak2Freq", "Freq"), ("peak2GainDb", "Gain"), ("peak2Q", "Q"),
                            ("peak2Enabled", "On")]),
                ("HIGH SHELF", [("highShelfFreq", "Freq"), ("highShelfGainDb", "Gain"),
                                ("highShelfQ", "Q"), ("highShelfEnabled", "On")]),
                ("LOW PASS", [("lowPassFreq", "Freq"), ("lowPassSlopeDbPerOct", "Slope"),
                              ("lowPassEnabled", "On")]),
            ]
        case .compressor:
            // Pro-C3's own grouping: trigger/shape, then time smoothing,
            // makeup last. m23-ck: the parallel dry/wet blend joins OUTPUT
            // APPENDED after makeup, mirroring the schema append — it acts on
            // the makeup-inclusive wet signal, so it reads last in signal
            // order. (The saturator puts `mix` FIRST in its OUTPUT group; if
            // that ordering should win here instead, it is a design call, not
            // a correctness one.)
            // m39-ae: DE-ESS is its own section and it sits FIRST, before
            // TRIGGER — signal-flow order, because the detector filter is
            // upstream of the threshold that reads it. Labels are spelled out
            // ("Listen To", "Width") rather than left as the parameter names:
            // a novice reading "detectorFreqHz" on a compressor card has no
            // way to know it is the de-esser, which is this feature's whole
            // discovery problem in one row.
            return [
                ("DE-ESS", [("detectorMode", "Mode"), ("detectorFreqHz", "Listen To"),
                            ("detectorQ", "Width")]),
                ("TRIGGER", [("thresholdDb", nil), ("ratio", nil), ("kneeDb", nil)]),
                ("TIME", [("attackMs", nil), ("releaseMs", nil)]),
                ("OUTPUT", [("makeupDb", nil), ("mix", nil)]),
            ]
        case .limiter:
            // Release before Ceiling — input→output even on a 2-knob card.
            // m23-ch: the true-peak toggle sits BESIDE the ceiling it
            // reinterprets (dBFS vs dBTP), never in its own section.
            return [
                ("TIME", [("releaseMs", nil)]),
                ("OUTPUT", [("ceilingDb", nil), ("truePeak", "True Peak")]),
            ]
        case .reverb:
            return [
                ("CHARACTER", [("roomSize", nil), ("damping", nil), ("width", nil)]),
                ("TIME", [("preDelayMs", nil)]),
                ("OUTPUT", [("mix", nil)]),
            ]
        case .delay:
            // m22-f: SYNC + DIVISION join the TIME section — one row of
            // three cells (knob · toggle · menu picker). While synced the
            // TIME cell shows the tempo-derived ms read-only.
            return [
                ("TIME", [("timeMs", nil), ("sync", nil), ("division", nil)]),
                ("REPEATS", [("feedback", nil), ("pingPong", nil), ("highCutHz", nil)]),
                ("OUTPUT", [("mix", nil)]),
            ]
        case .saturator:
            // m39-ad: CHARACTER joins, between DRIVE and OUTPUT, carrying the
            // one control that changes what the saturation SOUNDS like without
            // changing how much of it there is — the `clipper`'s own section
            // name and its own "Quality" label, because it is literally the
            // same control on the same primitive and a user who has met one
            // should recognise the other.
            return [
                ("DRIVE", [("driveDb", nil)]),
                ("CHARACTER", [("oversampling", "Quality")]),
                ("OUTPUT", [("mix", nil), ("outputDb", nil)]),
            ]
        case .gate:
            return [
                ("TRIGGER", [("thresholdDb", nil)]),
                ("TIME", [("attackMs", nil), ("holdMs", nil), ("releaseMs", nil)]),
            ]
        case .chorus:
            return [
                ("MODULATION", [("rateHz", nil), ("depthMs", nil)]),
                ("OUTPUT", [("mix", nil)]),
            ]
        case .bassEnhancer:
            return [
                ("SPEAKER", [("crossoverHz", nil)]),
                ("HARMONICS", [("amount", nil)]),
                ("OUTPUT", [("mix", nil)]),
            ]
        case .bitCrusher:
            // BITS and RATE are the character pair; ALIASING groups the two
            // authenticity switches together, because they are one decision
            // (authentic vs. tamed) taken twice.
            return [
                ("RESOLUTION", [("bits", nil), ("downsampleHz", "RATE")]),
                ("ALIASING", [("antiAlias", "FILTER"), ("dither", nil)]),
                ("OUTPUT", [("mix", nil)]),
            ]
        case .djFilter:
            // m39-i. FILTER is the whole instrument — one bipolar knob, with
            // the resonance that IS its character beside it. CHARACTER holds
            // the two shaping controls a user sets once and leaves; SLOPE is
            // the 12/24 topology chip, which belongs with the filter it steepens
            // rather than in its own row (the limiter's `truePeak` precedent:
            // a toggle sits beside what it acts on). No OUTPUT group — this
            // effect deliberately has no `mix`.
            return [
                ("FILTER", [("position", nil), ("resonance", nil),
                            ("slopeDbPerOct", "Slope")]),
                ("CHARACTER", [("deadZoneWidth", "Centre"),
                               ("resonanceTrack", "Track")]),
            ]
        case .ringMod:
            // m39-m. CARRIER is the whole instrument — the frequency that IS
            // the effect, with the shape that colours it beside it, the
            // `slopeDbPerOct` chip precedent (a discrete switch sits with what
            // it acts on). TONE holds the input high-cut, which is a fold-back
            // control and belongs with neither the carrier nor the output.
            // OUTPUT is mix and the stereo spread — the two that decide how
            // much of this reaches the listener and how wide.
            return [
                ("CARRIER", [("carrierHz", "Freq"), ("waveform", "Shape")]),
                ("TONE", [("inputHighCutHz", "High Cut")]),
                ("OUTPUT", [("mix", nil), ("stereoSpreadDeg", "Spread")]),
            ]
        case .flanger:
            // m39-j. SWEEP is the instrument — the three controls that decide
            // where the comb sits and how it moves, in the order a player
            // reaches for them (how fast, how far, from where). RESONANCE
            // holds `feedback` alone because it is the single biggest change
            // to the character and reads as its own decision, not as a trim.
            // OUTPUT is mix and the stereo phase — how much of this reaches
            // the listener and how wide, the `.ringMod` grouping precedent.
            return [
                ("SWEEP", [("rateHz", "Rate"), ("depthMs", "Depth"),
                           ("delayMs", "Manual")]),
                ("RESONANCE", [("feedback", "Feedback")]),
                ("OUTPUT", [("mix", nil), ("stereoPhaseDeg", "Spread")]),
            ]
        case .hallReverb:
            // m39-l, and the only kind in the tree with FOURTEEN params, so
            // the grouping is doing real work rather than decorating. SPACE is
            // the instrument — the two that describe the room itself (how long
            // it rings, how big it is) plus the gap before it arrives.
            // CHARACTER holds the shaping that decides what KIND of room it
            // is: the input smear and where the listener stands. DECAY is the
            // two-band absorption as ONE group with its two crossovers,
            // because a multiplier and its corner frequency are unreadable
            // apart — the EQ-band precedent. MODULATION is the anti-metallic
            // pair, named so its purpose is discoverable. OUTPUT is mix, width
            // and the freeze switch (the `slopeDbPerOct` chip precedent: a
            // discrete switch sits with what it acts on, and freeze acts on
            // everything that reaches the listener).
            return [
                ("SPACE", [("sizeMeters", "Size"), ("decaySeconds", "Decay"),
                           ("preDelayMs", "Pre-Delay")]),
                ("CHARACTER", [("diffusion", "Diffusion"),
                               ("earlyLateBalance", "Distance")]),
                ("DECAY SHAPE", [("lowDecayMultiplier", "Low x"),
                                 ("lowCrossoverHz", "Low Freq"),
                                 ("highDecayMultiplier", "High x"),
                                 ("highCrossoverHz", "High Freq")]),
                ("MODULATION", [("modRateHz", "Rate"), ("modDepthMs", "Depth")]),
                ("OUTPUT", [("mix", nil), ("width", "Width"),
                            ("freeze", "Freeze")]),
            ]
        case .tapeDelay:
            // m39-n. ECHO is the delay proper — the two controls anyone
            // reaching for a delay came for. TRANSPORT is the identity: the
            // wobble that makes it a tape machine rather than a delay, grouped
            // and named so a user who wants "that tape sound" knows where to
            // look. TAPE is what the record head does to each pass — drive and
            // the high-cut belong together because they are one stage. OUTPUT
            // is mix, last, per the strip rule.
            return [
                ("ECHO", [("timeMs", "Time"), ("feedback", "Feedback")]),
                ("TRANSPORT", [("wowDepthMs", "Wow"), ("wowRateHz", "Wow Rate"),
                               ("flutterDepthMs", "Flutter")]),
                ("TAPE", [("saturationDrive", "Drive"), ("highCutHz", "High Cut")]),
                ("OUTPUT", [("mix", nil)]),
            ]
        case .stereoWidth:
            // m23-dj. IMAGE is the instrument — the two controls that decide
            // how wide it gets, in the order a user reaches for them: scale
            // what is already there, then manufacture what is not. LOW END is
            // the safety stage, and it is its own group because a crossover
            // frequency and the amount it removes are unreadable apart (the
            // hallReverb DECAY SHAPE precedent). There is no OUTPUT group:
            // this kind has no `mix`, deliberately — see
            // `StereoWidthParams.isNeutral`.
            return [
                ("IMAGE", [("width", "Width"), ("spread", "Spread")]),
                ("LOW END", [("bassMonoHz", "Mono Below"),
                             ("bassMonoAmount", "Amount")]),
            ]
        case .phaser:
            // m39-o. SWEEP is the instrument — the three controls that make
            // the whoosh, in the order a user reaches for them: where it sits,
            // how far it travels, how fast. CHARACTER is what the sweep sounds
            // LIKE rather than where it goes: `stages` sets how many notches
            // there are and `feedback` how sharp they are, and the two are
            // unreadable apart (the hallReverb DECAY SHAPE precedent). OUTPUT
            // is mix and the stereo spread, last, per the strip rule.
            return [
                ("SWEEP", [("centerHz", "Centre"), ("depthOctaves", "Depth"),
                           ("rateHz", "Rate")]),
                ("CHARACTER", [("stages", "Stages"), ("feedback", "Feedback")]),
                ("OUTPUT", [("mix", nil), ("stereoPhaseDeg", "Stereo")]),
            ]
        case .transientShaper:
            // m39-y. SHAPE is the instrument — the two things this effect
            // actually does, in the order a user reaches for them: the front of
            // the sound, then the tail. TIMING is how long each of those lasts;
            // an amount and its window are unreadable apart (the hallReverb
            // DECAY SHAPE precedent), but they are grouped by ROLE rather than
            // paired, because the two amounts are what a user compares against
            // each other. OUTPUT is trim and mix, last, per the strip rule —
            // and `outputDb` sits there rather than beside the amounts because
            // it is a level match, not a shaping control.
            return [
                ("SHAPE", [("attackDb", "Punch"), ("sustainDb", "Body")]),
                ("TIMING", [("attackMs", "Punch Length"),
                            ("sustainMs", "Body Length")]),
                ("OUTPUT", [("outputDb", "Trim"), ("mix", nil)]),
            ]
        case .freqShifter:
            // m39-z. SHIFT is the effect - the coarse knob and the fine one
            // TOGETHER, because they are one control split in two for
            // resolution and reading either alone is misleading (the hallReverb
            // DECAY SHAPE precedent for pairing what is unreadable apart).
            // IMAGE is the one stereo control. OUTPUT is trim and mix, last,
            // per the strip rule.
            return [
                ("SHIFT", [("shiftHz", "Shift"), ("fineHz", "Fine")]),
                ("IMAGE", [("stereoSpreadHz", "Spread")]),
                ("OUTPUT", [("outputDb", "Trim"), ("mix", nil)]),
            ]
        case .clipper:
            // m39-ac. CLIP is the instrument — where the ceiling is and how
            // hard the sound is pushed into it, in the order a user reaches for
            // them. The two are unreadable apart (the hallReverb DECAY SHAPE
            // precedent): neither knob alone says where clipping starts.
            // CHARACTER is what the clipping sounds LIKE rather than how much
            // of it there is — the shape of the cut and the quality setting
            // that decides whether the folded-back fizz comes with it. OUTPUT
            // is trim and mix, last, per the strip rule.
            return [
                ("CLIP", [("ceilingDb", "Ceiling"), ("driveDb", "Drive")]),
                ("CHARACTER", [("mode", "Shape"), ("oversampling", "Quality")]),
                ("OUTPUT", [("outputDb", "Trim"), ("mix", nil)]),
            ]
        case .dynamicEQ:
            // m39-af. FOUR IDENTICAL GROUPS, one per band, low → high, which is
            // the `.eq` card's own shape (one band per group, signal order left
            // to right) applied to a kind whose bands are uniform. No OUTPUT
            // group: this kind deliberately has no `mix` — a dynamic EQ's
            // wet/dry IS the band gain, and a second blend would be a confusing
            // duplicate (the `.djFilter` no-`mix` precedent).
            //
            // Labels are SPELLED OUT rather than left as parameter names — the
            // m39-ae DE-ESS precedent, and the same reason: a novice reading
            // "band2ThresholdDb" has no way to know which of eight knobs starts
            // the band moving. "Listen" carries the mode because the mode is
            // literally which side of the threshold the band listens to, and
            // "Range" is signed (minus turns the band down).
            //
            // ⚠️ EIGHT ITEMS PER GROUP is the widest card in the app — `.eq`'s
            // widest group is four. If a pixel check says four groups of eight
            // does not fit, the design's NAMED fallback is to drop to three
            // bands (24 slots); the per-band block is identical either way, so
            // that decision is genuinely late-binding. It must be made by
            // looking, not by hoping (design §10 G8).
            return (1...DynamicEQParams.bandCount).map { band in
                ("BAND \(band)", [
                    ("band\(band)Mode", "Listen"),
                    ("band\(band)Freq", "Freq"),
                    ("band\(band)Q", "Q"),
                    ("band\(band)ThresholdDb", "Threshold"),
                    ("band\(band)Ratio", "Ratio"),
                    ("band\(band)RangeDb", "Range"),
                    ("band\(band)AttackMs", "Attack"),
                    ("band\(band)ReleaseMs", "Release"),
                ])
            }
        case .audioUnit:
            // AU params are not on the generic surface (M3 vi-b).
            return []
        }
    }

    /// The grouped sections for one kind, resolved against the spec table.
    /// A table name missing from the schema is dropped (structurally
    /// impossible while the tests pin exact-once coverage).
    public static func groups(for kind: EffectDescriptor.Kind) -> [EffectParamGroup] {
        let specs = EffectParamSpec.specs(for: kind)
        return groupTable(for: kind).compactMap { title, members in
            let items = members.compactMap { name, override -> EffectParamGroup.Item? in
                guard let spec = specs.first(where: { $0.name == name }) else { return nil }
                return EffectParamGroup.Item(spec: spec, label: override ?? label(for: spec))
            }
            return items.isEmpty ? nil : EffectParamGroup(title: title, items: items)
        }
    }

    // MARK: - Knob geometry (unipolar sweep vs bipolar center-out)

    /// How a knob FILLS its arc. `unipolar` sweeps from the range minimum
    /// (freq/Q/time/threshold/ratio/mix); `bipolar` fills center-out from the
    /// zero detent (±dB gain params — EQ band gains, saturator output), the
    /// `PanKnob` shape.
    public enum KnobStyle: Sendable, Equatable {
        case unipolar
        case bipolar
    }

    /// Bipolar iff the range genuinely spans zero on BOTH sides. A -60…0
    /// threshold or -24…0 ceiling is unipolar — nothing to be "center-out"
    /// about when zero is an endpoint.
    public static func knobStyle(for spec: EffectParamSpec) -> KnobStyle {
        spec.range.lowerBound < 0 && spec.range.upperBound > 0 ? .bipolar : .unipolar
    }

    /// The travel fraction a knob's value arc anchors from: 0 (min-start
    /// sweep) for unipolar, the zero-crossing detent for bipolar.
    public static func knobFillAnchor(for spec: EffectParamSpec) -> Double {
        switch knobStyle(for: spec) {
        case .unipolar: return 0
        case .bipolar: return fraction(forValue: 0, spec: spec)
        }
    }

    // MARK: - Toggle params (pingPong + the m22-a EQ binaries)

    /// Binary-at-the-model-layer params render as TOGGLES, never knobs
    /// (report §3/§6): delay `pingPong` (`DelayParams` rounds it), the
    /// EQ's `*Enabled` band bypasses (the store snaps ≥ 0.5 to on, m22-a),
    /// the delay's tempo `sync` (m22-f, same ≥ 0.5 snap), the limiter's
    /// `truePeak` mode (m23-ch, same ≥ 0.5 snap), the bit-crusher's
    /// `antiAlias`/`dither` switches (m32-e, same ≥ 0.5 snap), and the gain
    /// utility's `invertPolarity` Ø switch (m38-a, same ≥ 0.5 snap). The wire shape
    /// is untouched: the toggle still writes 0.0/1.0 through the same `set`
    /// path.
    ///
    /// ⚠️ THIS LIST IS THE FAILURE MODE, AND IT IS NOT SELF-ENFORCING. A binary
    /// param missing from it renders as a KNOB over a 0…1 continuum, so the user
    /// can park it at 0.43, watch the readout say "0.43", and hear a value the
    /// store already snapped to OFF — a control that visibly disagrees with the
    /// sound. m32-e arrived with exactly that gap, and the suite stayed green
    /// because the pinning test RESTATED this same expression instead of
    /// checking it. `binaryModelParamsRenderAsToggles` now derives the expected
    /// answer from what a REAL store does to a 0.4 write, which is the fact the
    /// toggle rendering is justified by in the first place.
    ///
    /// It cannot be replaced by "the range is 0…1": `mix`, `amount`, `roomSize`
    /// and `damping` all share that range and are genuine continua.
    public static func isToggleParam(_ spec: EffectParamSpec) -> Bool {
        spec.name == "pingPong" || spec.name == "sync" || spec.name == "truePeak"
            || spec.name == "antiAlias" || spec.name == "dither"
            || spec.name == "invertPolarity"
            || spec.name.hasSuffix("Enabled")
    }

    /// The delay's `division` (m22-f) is an 18-way note-length CHOICE, not a
    /// continuum — it renders as a compact menu picker of `NoteDivision`
    /// tokens, never a knob. Numerically it still rides the generic surface
    /// as its length in beats (the store snaps to the nearest legal value).
    public static func isDivisionParam(_ spec: EffectParamSpec) -> Bool {
        spec.name == "division"
    }

    // MARK: - Delay tempo sync (m22-f)

    /// True while the open insert is a delay with tempo sync ON — the TIME
    /// knob then yields to the read-only derived readout (never fight a knob
    /// the tempo owns).
    public var delaySyncActive: Bool {
        guard let descriptor, descriptor.kind == .delay else { return false }
        return descriptor.resolvedDelay.resolvedSync
    }

    /// The synced delay's EFFECTIVE time at the current tempo (nil while the
    /// card isn't a synced delay) — the SAME `effectiveTimeMs` the engine's
    /// control-plane resolve pushes to the render thread.
    public var syncedDelayTimeMs: Double? {
        guard delaySyncActive, let descriptor else { return nil }
        return descriptor.resolvedDelay.effectiveTimeMs(atTempoBPM: tempoBPM())
    }

    /// The open delay's current division (the picker's selection); defaults
    /// through the resolved accessor (nil = 1/4).
    public var delayDivision: NoteDivision {
        descriptor?.resolvedDelay.resolvedDivision ?? .quarter
    }

    /// Picks a division through the SAME numeric `set` path the wire uses
    /// (value = the division's length in beats; the store snaps exactly).
    public func setDelayDivision(_ division: NoteDivision) {
        set(name: "division", value: division.beats)
    }

    /// The HP/LP slope params are TWO-STATE (12 or 24 dB/oct — the model layer
    /// snaps anything else through `EQParams.snapSlope`, m22-a), so they render
    /// as a 12/24 chip, not a knob. Same numeric wire underneath.
    ///
    /// ⛔⛔ **THE MATCH IS CASE-INSENSITIVE, AND THAT IS A SHIPPED BUG'S FIX**
    /// (m39-ag). It was `hasSuffix("SlopeDbPerOct")`, which matches the EQ's
    /// `highPassSlopeDbPerOct` / `lowPassSlopeDbPerOct` but **NOT the DJ
    /// filter's, which is the bare `slopeDbPerOct` with a lowercase s** — so
    /// `djFilter`'s topology switch fell through to `knobCell` and drew a rotary
    /// over a two-value param. It went unnoticed for the ordinary reason: the
    /// test that pinned this function RESTATED `hasSuffix("SlopeDbPerOct")`
    /// instead of checking it, so source and test agreed with each other and
    /// with nothing else. `EffectChoiceParamTests.everyDiscreteParamAvoidsTheKnob`
    /// — which derives the discrete set from `.refused` — caught it on its first
    /// run, having been written for a different family entirely.
    public static func isSlopeParam(_ spec: EffectParamSpec) -> Bool {
        spec.name.lowercased().hasSuffix("slopedbperoct")
    }

    /// The chip's read side: 24 at or above the snap midpoint, else 12 —
    /// mirrors `EQParams.snapSlope`.
    public static func slopeIs24(_ value: Double) -> Bool {
        value >= 18
    }

    /// The toggle read threshold — mirrors the model layer's `.rounded()`
    /// (0.5 rounds up).
    public static func toggleIsOn(_ value: Double) -> Bool {
        value >= 0.5
    }

    // MARK: - Discrete CHOICE params (m39-ag)

    /// One legal setting of a discrete choice param: the exact wire value the
    /// chip writes, and the beginner-readable label it draws.
    public struct EffectParamChoice: Equatable, Sendable {
        /// The value written through `set(name:value:)` — always a legal,
        /// already-snapped number, so the card can never store a 1.7.
        public let value: Double
        /// What the chip draws. Title case, drawn VERBATIM — the string the
        /// tests pin is the string on screen.
        public let label: String

        public init(value: Double, label: String) {
            self.value = value
            self.label = label
        }
    }

    /// The `band1Mode`…`band4Mode` names, off `DynamicEQParams.bandCount` rather
    /// than a literal 4 — a fifth band must not silently fall back to a knob.
    public static let dynamicEQModeParamNames: Set<String> =
        Set((1...DynamicEQParams.bandCount).map { "band\($0)Mode" })

    /// A param whose legal values are a small FINITE SET renders as a chip that
    /// names the setting, never a knob over a continuum that does not exist
    /// (m39-ag). `dynamicEQ.band1Mode` shipped as a rotary reading **`0.00`**
    /// for a three-way off/above/below switch — the single most important
    /// control on the card, and from the card you could not tell which of the
    /// three it was.
    ///
    /// ⚠️ **AN EXPLICIT LIST, ON PURPOSE, AND IT IS NOT SELF-ENFORCING** — the
    /// exact shape (and the exact hazard) of `isToggleParam` above. It is
    /// deliberately NOT written as `spec.modulatable == .refused && !toggle &&
    /// …`: `EffectChoiceParamTests.everyDiscreteParamAvoidsTheKnob` DERIVES the
    /// expected answer from `.refused` — which `Modulation.swift` maintains for
    /// an unrelated reason ("modulation additionally refuses DISCRETE params,
    /// because an LFO cannot meaningfully drive a boolean or a topology
    /// switch") — so a definition in those terms would make the census restate
    /// itself and never fail. That is the m32-e trap documented above, which
    /// shipped two binary params as knobs with the suite green.
    ///
    /// Names are unique across the built-in kinds (`oversampling` is the one
    /// that repeats, on `clipper` and `saturator`, and the two share a snap by
    /// construction — `SaturatorParams.oversamplingFactor` forwards). The census
    /// test checks BOTH directions, so a future continuous param that happens to
    /// be called `mode` fails there rather than shipping as a chip.
    public static func isChoiceParam(_ spec: EffectParamSpec) -> Bool {
        switch spec.name {
        case "detectorMode",    // compressor — the de-esser's off/band/high
             "mode",            // clipper — hard vs soft
             "oversampling",    // clipper + saturator — 1× / 2× / 4×
             "waveform",        // ringMod — the carrier shape
             "stages",          // phaser — even-only 2…12
             "freeze":          // hallReverb — "DISCRETE on a continuous surface"
            return true
        default:
            return dynamicEQModeParamNames.contains(spec.name)
        }
    }

    /// The label for a raw value — **snapped through the KIND'S OWN one-home
    /// snapping function in `DAWCore` first**, so the chip names what is
    /// actually in force rather than what happens to be stored.
    ///
    /// ⭐ That distinction is the whole defect. `fx.setParam` CLAMPS these
    /// without rounding (the documented `phaser.stages` precedent), so a stored
    /// `band1Mode` of 0.4 is a real, reachable state whose RENDER behaviour is
    /// `off` — and the card must say `Off`, exactly as the wire's
    /// `band1ModeLabel` already does.
    ///
    /// ⚠️ Every arm is an exhaustive `switch` over a shared `DAWCore` enum or an
    /// `Int` the snap returns — never a `[Double: String]` keyed by number. A
    /// new enum case therefore fails to COMPILE here rather than silently
    /// drawing the wrong word.
    ///
    /// ⛔ RESIDUAL, and it is a real one: `CompressorParams.DetectorMode`,
    /// `ClipperParams.Mode` and `DynamicEQParams.Mode` carry no `displayName`,
    /// so `Commands.swift` spells them inline (`"off"`/`"above"`/`"below"`,
    /// `"bandPass"`, `"soft"`) and this is a SECOND SPELLING of one enum. The
    /// meaning has one home — the snap — and an added case breaks both sites at
    /// compile time; only a re-WORDING of an existing case can drift, and the
    /// literal pins in `EffectChoiceParamTests` catch that on this side. The fix
    /// is a `displayName` on those three enums that `Commands.swift` reads, and
    /// it was NOT done here for two reasons: `Sources/DAWCore/` was being edited
    /// concurrently, and changing the wire's `"bandPass"` token is a wire change.
    public static func choiceLabel(value: Double, spec: EffectParamSpec) -> String {
        switch spec.name {
        case "detectorMode":
            switch CompressorParams.detectorMode(at: value) {
            case .off: return "Off"
            case .bandPass: return "Band-Pass"
            case .highPass: return "High-Pass"
            }
        case "mode":
            switch ClipperParams.mode(at: value) {
            case .hard: return "Hard"
            case .soft: return "Soft"
            }
        case "oversampling":
            // `SaturatorParams.oversamplingFactor` forwards here by design, and
            // `oversamplingSnapIsSharedWithTheSaturator` pins that it still does,
            // so one arm is correct for both kinds.
            return "\(ClipperParams.oversamplingFactor(at: value))×"
        case "waveform":
            // The only one with a `displayName` already in DAWCore — the wire's
            // own source for `waveformLabel`, so this is genuinely one home.
            return RingModParams.waveform(at: value).displayName
        case "stages":
            // Even-only; the snap resolves an odd tie UPWARD (5 → 6).
            return "\(PhaserParams.snappedStages(value))"
        case "freeze":
            return HallReverbParams.isFrozen(value) ? "Hold" : "Off"
        default:
            guard dynamicEQModeParamNames.contains(spec.name) else { return "" }
            switch DynamicEQParams.mode(at: value) {
            case .off: return "Off"
            case .above: return "Above"
            case .below: return "Below"
            }
        }
    }

    /// Every legal setting of a choice param, in wire order — the chip's menu.
    /// Option VALUES come from the `DAWCore` range/roster constants, never from
    /// numbers typed here, so a widened range grows the menu on its own.
    public static func choices(for spec: EffectParamSpec) -> [EffectParamChoice] {
        let values: [Double]
        switch spec.name {
        case "detectorMode":
            values = Self.wholeSteps(in: CompressorParams.detectorModeRange)
        case "mode":
            values = Self.wholeSteps(in: ClipperParams.modeRange)
        case "oversampling":
            values = OversamplerDesign.supportedFactors.map(Double.init)
        case "waveform":
            values = RingModParams.Waveform.allCases.map { Double($0.rawValue) }
        case "stages":
            values = stride(from: PhaserParams.stagesRange.lowerBound,
                            through: PhaserParams.stagesRange.upperBound, by: 2).map { $0 }
        case "freeze":
            values = Self.wholeSteps(in: HallReverbParams.freezeRange)
        default:
            guard dynamicEQModeParamNames.contains(spec.name) else { return [] }
            values = Self.wholeSteps(in: DynamicEQParams.modeRange)
        }
        return values.map {
            EffectParamChoice(value: $0, label: choiceLabel(value: $0, spec: spec))
        }
    }

    /// Whole numbers across a closed range — the enum-backed choice domains.
    private static func wholeSteps(in range: ClosedRange<Double>) -> [Double] {
        stride(from: range.lowerBound, through: range.upperBound, by: 1).map { $0 }
    }

    /// The current value for one row — read from the live descriptor via the
    /// kind-keyed reader; the spec default when unreadable (a fresh insert
    /// carries nil params, which resolve to defaults model-side too).
    public func value(for spec: EffectParamSpec) -> Double {
        guard let descriptor else { return spec.defaultValue }
        return Self.paramValue(spec.name, in: descriptor) ?? spec.defaultValue
    }

    // MARK: - Edits (the wire-identical apply path)

    /// Applies one parameter edit: clamps to the spec range (the store clamps
    /// again — belt and suspenders), then routes through the injected closure —
    /// `setEffectParam`/`setMasterEffectParam`, the exact methods `fx.setParam`
    /// calls. The store coalesces per (chain, effect, name), so a slider drag
    /// that applies every tick still lands as ONE undo step.
    public func set(name: String, value: Double) {
        guard let target, let kind else { return }
        guard let spec = EffectParamSpec.specs(for: kind).first(where: { $0.name == name }) else {
            return
        }
        let clamped = value.clamped(to: spec.range)
        do {
            try applyParam(target.trackID, target.effectID, name, clamped)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Sets a row from a 0…1 slider fraction (through the row's scale).
    public func setFraction(_ fraction: Double, for spec: EffectParamSpec) {
        set(name: spec.name, value: Self.value(forFraction: fraction, spec: spec))
    }

    /// Double-click reset — back to the spec default (one coalesced edit).
    public func resetToDefault(_ spec: EffectParamSpec) {
        set(name: spec.name, value: spec.defaultValue)
    }

    /// Toggles bypass through the SAME store method the row's dot and the
    /// wire's `fx.setBypass` use.
    public func toggleBypass() {
        guard let target, let descriptor else { return }
        do {
            try applyBypass(target.trackID, target.effectID, !descriptor.isBypassed)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Slider geometry (fraction ↔ value)

    /// How a row's slider travel maps onto its range. Frequencies are
    /// LOGARITHMIC — musical octaves read evenly across the travel (a linear
    /// 20 Hz–20 kHz slider buries everything below 2 kHz in the first tenth);
    /// everything else is linear.
    ///
    /// ⭐ m39-a: this WAS a private two-case enum re-derived from the free-text
    /// unit string here AND again in `PolySynthEditorModel`. It is now an alias
    /// for `DAWCore.ParamCurve`, the one home — the taper is read off the spec,
    /// never inferred. The alias is kept so every existing caller and test that
    /// writes `EffectEditorModel.Scale` / `== .logarithmic` keeps compiling
    /// (additive only; nothing renamed).
    public typealias Scale = ParamCurve

    /// The row's DECLARED curve. No heuristic: `EffectParamSpec.curve` is the
    /// property, and `ParamCurveConformanceTests` pins that every shipping
    /// param still resolves to exactly the curve the old `unit == "Hz"`
    /// inference gave it.
    ///
    /// ⚠️ m27-r: this stays the DECLARED curve even where the knob travels
    /// differently. The gain utility's `gainLinear` declares `.linear` (that is
    /// the wire's and the modulation depth law's domain) but its on-screen
    /// knob takes the power taper below — read `fraction(forValue:spec:)` /
    /// `value(forFraction:spec:)` for where the knob actually sits.
    public static func scale(for spec: EffectParamSpec) -> Scale {
        spec.curve
    }

    /// The 0…1 slider fraction for a value: the row's declared curve, except
    /// the gain utility's knob (m27-r, `gainTravelExponent(for:)`).
    public static func fraction(forValue value: Double, spec: EffectParamSpec) -> Double {
        if let k = gainTravelExponent(for: spec) {
            let v = value.clamped(to: spec.range)
            return pow(v / spec.range.upperBound, 1 / k).clamped(to: 0...1)
        }
        return spec.curve.fraction(forValue: value, in: spec.range)
    }

    /// The value at a 0…1 slider fraction: the row's declared curve, except
    /// the gain utility's knob (m27-r, `gainTravelExponent(for:)`). The exact
    /// inverse of `fraction(forValue:spec:)`.
    public static func value(forFraction fraction: Double, spec: EffectParamSpec) -> Double {
        if let k = gainTravelExponent(for: spec) {
            let f = fraction.clamped(to: 0...1)
            return (spec.range.upperBound * pow(f, k)).clamped(to: spec.range)
        }
        return spec.curve.value(forFraction: fraction, in: spec.range)
    }

    // MARK: - The gain utility's knob travel (m27-r)

    /// The exponent of the gain utility knob's power taper, or nil for every
    /// other row (which keeps its declared curve, bit for bit).
    ///
    /// WHY: m27-c widened `gainLinear` from 0…4 to 0…16 (+24.08 dB in one
    /// insert) and left the knob travelling LINEARLY, so unity sat at 6.25 % of
    /// the travel and one percent of it near unity was about 1.3–1.5 dB — four
    /// times twitchier than before, at the value people dial most.
    ///
    /// THE TAPER: `value = hi · fraction^k` with `k = log2(hi)`, which puts
    /// unity (×1, 0 dB) at EXACTLY half travel — straight up on the 270° knob —
    /// whatever the ceiling is. For a 0…2 range `k` is 1 and the formula IS the
    /// house fader (`MixerMath`: linear, unity at half travel), so this is that
    /// rule generalised to a 16× ceiling, and a future range change cannot move
    /// unity again. At 0…16 (`k` = 4) one percent of travel at unity is about
    /// 0.7 dB; the boost half gets half the travel; deep cuts are coarse
    /// (≈1.4 dB per percent at −24 dB), and the readout still shows the exact
    /// value. Continuous down to silence: every value has exactly one position.
    ///
    /// ⚠️ EDITOR-ONLY. The spec still declares `.linear`; the wire, the stored
    /// value, `fx.describe` and the modulation depth law (which read
    /// `spec.curve`, never this) do not move. Name-keyed, the same predicate
    /// shape as the dB readout and `isLevelParam`. The range must start at
    /// silence and reach above unity; otherwise nil and the declared curve
    /// applies (a test pins that the shipping range passes).
    public static func gainTravelExponent(for spec: EffectParamSpec) -> Double? {
        guard spec.name == "gainLinear",
              spec.range.lowerBound == 0, spec.range.upperBound > 1 else { return nil }
        return log2(spec.range.upperBound)
    }

    /// Whether a row's knob takes the gain utility's power taper instead of
    /// its declared curve (true for `gain.gainLinear` only).
    public static func usesGainTravelTaper(_ spec: EffectParamSpec) -> Bool {
        gainTravelExponent(for: spec) != nil
    }

    /// The current row fraction (for the thin view's slider position).
    public func fraction(for spec: EffectParamSpec) -> Double {
        Self.fraction(forValue: value(for: spec), spec: spec)
    }

    // MARK: - Presentation (label / readout / accent)

    /// A row's human label from its wire name: camelCase split ("lowShelfFreq"
    /// → "Low Shelf Freq", "peak1GainDb" → "Peak 1 Gain Db"), then a trailing
    /// unit token that just repeats `spec.unit` is dropped ("… Gain Db" →
    /// "… Gain" — the readout already shows the unit).
    public static func label(for spec: EffectParamSpec) -> String {
        var words: [String] = []
        var current = ""
        for ch in spec.name {
            if ch.isUppercase || ch.isNumber, !current.isEmpty,
               !(ch.isNumber && current.last?.isNumber == true) {
                words.append(current)
                current = ""
            }
            current.append(ch)
        }
        if !current.isEmpty { words.append(current) }
        let redundant: [String: String] = [
            "dB": "db", "Hz": "hz", "ms": "ms", "s": "s", "linear": "linear",
        ]
        if let unitToken = redundant[spec.unit], words.count > 1,
           words.last?.lowercased() == unitToken {
            words.removeLast()
        }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Whether a 0…1 "linear" AMOUNT param reads as a PERCENTAGE (mix, room
    /// size, damping, width, feedback — the report's Actionable-5 convention;
    /// every cited competitor shows these as %). Excludes Q (0.1…18), linear
    /// gain (0…4, dB-equivalent below), and the pingPong toggle. Formatter
    /// side ONLY — the wire value stays the raw 0…1 fraction.
    /// ⚠️ m39-ag adds the `isChoiceParam` exclusion, and it was load-bearing for
    /// a shipped defect: `hallReverb.freeze` is `0…1` with unit `"linear"` and
    /// is NOT a toggle param, so it satisfied every clause here and the card
    /// drew an infinite-hold SWITCH as a knob reading **`0 %`** — a percentage
    /// of a binary. (It is not in `isToggleParam` for a good reason: the store
    /// CLAMPS it without rounding, so `binaryModelParamsRenderAsToggles`, which
    /// derives from a real 0.4 write, correctly calls it non-binary. The
    /// discreteness lives in `HallReverbParams.isFrozen` — "DISCRETE on a
    /// continuous surface" — which is the choice family, not the toggle family.)
    public static func isPercentParam(_ spec: EffectParamSpec) -> Bool {
        spec.unit == "linear" && !isToggleParam(spec) && !isChoiceParam(spec)
            && spec.range.lowerBound == 0 && spec.range.upperBound <= 1
    }

    /// The SF Mono readout for a value: `(text, unit)` — "3.0" + "kHz",
    /// "-18.0" + "dB", "4.0:1" + "", "35" + "%". Deterministic formats so
    /// captures and tests pin exact strings.
    public static func readout(value: Double, spec: EffectParamSpec) -> (text: String, unit: String) {
        // The binary pingPong reads as a state word, never a fraction (§6).
        if isToggleParam(spec) {
            return (toggleIsOn(value) ? "ON" : "OFF", "")
        }
        // The two-state HP/LP slope reads as its snapped value (m22-a).
        if isSlopeParam(spec) {
            return (slopeIs24(value) ? "24" : "12", "dB/oct")
        }
        // The delay division reads as its note token, never raw beats
        // (m22-f) — the same nearest-snap the store applies.
        if isDivisionParam(spec) {
            return (NoteDivision.nearest(toBeats: value).rawValue, "")
        }
        // A discrete choice reads as the SNAPPED setting's name, never a
        // number (m39-ag) — "Above", not "1.00"; "Off", not "0.00". This arm
        // must sit ahead of the percent check below, which `freeze` would
        // otherwise satisfy and read as "0 %".
        if isChoiceParam(spec) {
            return (choiceLabel(value: value, spec: spec), "")
        }
        // 0…1 amount knobs read in % (report Actionable-5); wire stays 0…1.
        if isPercentParam(spec) {
            return (String(format: "%.0f", value * 100), "%")
        }
        // The gain utility's linear multiplier reads as its dB equivalent
        // (20·log10) so every trim/gain knob in the app speaks one unit
        // (report §6 `gain`); the wire keeps the linear value.
        if spec.name == "gainLinear" {
            guard value > 0 else { return ("-∞", "dB") }
            return (String(format: "%.1f", 20 * log10(value)), "dB")
        }
        switch spec.unit {
        case "dB":
            return (String(format: "%.1f", value), "dB")
        case "Hz":
            if value >= 1_000 {
                return (String(format: "%.2f", value / 1_000), "kHz")
            }
            if value < 10 {
                // Sub-10 Hz rates (chorus/LFO territory) need decimals — a
                // 0.8 Hz default must never read as "1".
                return (String(format: "%.2f", value), "Hz")
            }
            return (String(format: "%.0f", value), "Hz")
        case "ms":
            if value >= 1_000 {
                // Long delays/releases cross to seconds — the Hz→kHz
                // crossover's twin (report §6 `delay`).
                return (String(format: "%.2f", value / 1_000), "s")
            }
            if value < 10 {
                return (String(format: "%.1f", value), "ms")
            }
            return (String(format: "%.0f", value), "ms")
        case "s":
            return (String(format: "%.2f", value), "s")
        case "ratio":
            return (String(format: "%.1f:1", value), "")
        default:
            // "linear" and anything future: two decimals, no unit tag (the
            // raw word "linear" reads as jargon, not information).
            return (String(format: "%.2f", value), "")
        }
    }

    /// Whether a row earns the cyan accent: only genuinely level/gain-flavored
    /// params (dB values, linear gain) — pan-type/tone params stay neutral
    /// white, the `PanKnob` precedent (docs/DESIGN-LANGUAGE.md Rule 3).
    public static func isLevelParam(_ spec: EffectParamSpec) -> Bool {
        spec.unit == "dB" || spec.name == "gainLinear"
    }

    // MARK: - The kind-keyed value reader

    /// Reads one named param out of a descriptor — the exact inverse of
    /// `ProjectStore.applyEffectParam`'s name→field mapping, over the SAME
    /// wire names `fx.setParam`/`fx.describe` use. nil for an unknown name or
    /// an AU descriptor (AU params are not on this surface in v1).
    public static func paramValue(_ name: String, in effect: EffectDescriptor) -> Double? {
        // ONE HOME (m39-e): the name→field mapping moved to DAWCore so the
        // render-side modulation publish and `mod.describe` read the SAME
        // function this editor does. Kept as a static here because call sites
        // and tests spell it this way.
        effect.paramValue(name)
    }
}
