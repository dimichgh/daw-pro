import Foundation
import Observation
import DAWCore

/// One tunable numeric Sampler parameter as the editor card renders it: the
/// field name (the same name `track.setInstrument`'s sampler payload uses), the
/// knob micro-label, the range/default straight from `SamplerParams` /
/// `SamplerZone` (the single source of truth — this table can never fork the
/// domain clamps), and the storage unit the formatter keys on.
///
/// The `PolySynthParamSpec` twin. Deliberately a SEPARATE type rather than a
/// reuse: the sampler's units ("cents", "pan") and its bipolar ranges have no
/// counterpart on the poly synth, and a shared type would have to grow both
/// vocabularies.
public struct SamplerParamSpec: Equatable, Sendable {
    /// The field name ("attack", "tuneCents", …) — identical to the wire's own
    /// key in `track.setInstrument`'s sampler / zone payload.
    public let name: String
    /// The knob micro-label ("Attack", "Tune", …).
    public let label: String
    /// The legal range — `SamplerParams`'s / `SamplerZone`'s own clamp range,
    /// verbatim.
    public let range: ClosedRange<Double>
    /// The double-click reset value. For a per-zone field this is the value the
    /// domain's `nil` means (0 cents, no decay stage, sustain at peak, unity
    /// gain) — see `SamplerEditorModel.zoneValue(for:)` for the two fields
    /// whose nil resolves against a LIVE global instead.
    public let defaultValue: Double
    /// The STORAGE unit ("s" / "linear" / "cents" / "pan" / "level") — display
    /// crossovers (ms↔s, dB-for-gain, %-for-levels, L/C/R-for-pan) live in
    /// `readout(value:spec:)`.
    public let unit: String

    public init(name: String, label: String, range: ClosedRange<Double>,
                defaultValue: Double, unit: String) {
        self.name = name
        self.label = label
        self.range = range
        self.defaultValue = defaultValue
        self.unit = unit
    }
}

/// The Sampler's one BOOLEAN global. Modelled apart from `SamplerParamSpec`
/// deliberately: a two-state setting is categorical, so it renders as a toggle
/// and never as a knob (the same rule that keeps the poly synth's waveform out
/// of its knob table — the 2026-07-19 knob-vs-slider report §3).
public struct SamplerToggleSpec: Equatable, Sendable {
    public let name: String
    public let label: String
    public let defaultValue: Bool
    /// The one-line explanation the card's help text carries.
    public let detail: String

    public init(name: String, label: String, defaultValue: Bool, detail: String) {
        self.name = name
        self.label = label
        self.defaultValue = defaultValue
        self.detail = detail
    }
}

/// One row of the zone list, in the shape a list view renders: no view ever
/// reaches into a `SamplerZone` and no view ever recomputes a label. Value
/// type, `Equatable`, so SwiftUI diffs it cheaply — a 300-zone library must not
/// re-render on an unrelated edit.
public struct SamplerZoneRow: Identifiable, Equatable, Sendable {
    /// The zone's OWN id (m26-g) — the stable selection handle. Never an index:
    /// zones are wholesale-replaced, so an index can land on a different zone.
    public let id: UUID
    /// The sample file's last path component ("SaxTenor_C4_mf.wav"). The full
    /// path is deliberately NOT here — a 46-zone list of absolute paths is
    /// unreadable, and the model is not the place to decide how much of one to
    /// elide.
    public let fileName: String
    public let rootPitch: Int
    public let minPitch: Int
    public let maxPitch: Int
    /// The RESOLVED velocity span: nil bounds read as the full
    /// `SamplerZone.velocityRange`, the model's own documented default — never
    /// 0, which would show a silent layer that does not exist.
    public let minVelocity: Int
    public let maxVelocity: Int
    /// The resolved layering group (nil = implicit group 0).
    public let group: Int
    /// nil = this zone does not loop.
    public let loopMode: SamplerLoopMode?

    public init(zone: SamplerZone) {
        self.id = zone.id
        self.fileName = zone.audioFileURL.lastPathComponent
        self.rootPitch = zone.rootPitch
        self.minPitch = zone.minPitch
        self.maxPitch = zone.maxPitch
        self.minVelocity = zone.minVelocity ?? SamplerZone.velocityRange.lowerBound
        self.maxVelocity = zone.maxVelocity ?? SamplerZone.velocityRange.upperBound
        self.group = zone.group ?? 0
        self.loopMode = zone.loopMode
    }

    /// "C4" — the root note in scientific pitch, through DAWCore's SOLE
    /// note-name derivation (`Fundamental.noteName`).
    public var rootLabel: String { Fundamental.noteName(midiNote: rootPitch) }

    /// "C1–C7", or just "C4" when the zone answers to a single key.
    public var pitchSpanLabel: String {
        SamplerEditorModel.pitchSpanLabel(min: minPitch, max: maxPitch)
    }

    /// "1–127", or "64" for a single-velocity zone.
    public var velocitySpanLabel: String {
        minVelocity == maxVelocity ? "\(minVelocity)" : "\(minVelocity)–\(maxVelocity)"
    }
}

/// The zone map's health, for the editor header: how many zones, what pitch and
/// velocity they actually cover, and — the part a naive min/max cannot see —
/// how many INTERIOR holes there are.
///
/// The coverage arithmetic is `DAWCore.SamplerZoneCoverage`, the SAME function
/// `instrument.describeSampler` reports over the wire (m26-i). The UI and an AI
/// agent asking the wire therefore cannot disagree about whether a keymap has a
/// hole in it.
public struct SamplerCoverageSummary: Equatable, Sendable {
    public let zoneCount: Int
    /// nil = no zones. A zero-zone sampler is a legal, describable state (the
    /// documented `zones: []` clear — a silent sampler), NOT an error and NOT a
    /// zero-width envelope at 0.
    public let pitch: SamplerZoneCoverage?
    public let velocity: SamplerZoneCoverage?

    public init(zones: [SamplerZone]) {
        self.zoneCount = zones.count
        self.pitch = SamplerZoneCoverage.pitchCoverage(of: zones)
        self.velocity = SamplerZoneCoverage.velocityCoverage(of: zones)
    }

    /// Interior pitch holes — keys inside the mapped range that play NOTHING.
    public var pitchGapCount: Int { pitch?.gaps.count ?? 0 }
    /// Interior velocity holes — dynamics inside the mapped range that trigger
    /// no layer.
    public var velocityGapCount: Int { velocity?.gaps.count ?? 0 }
    /// Both kinds together. The header's ⚠ badge keys on this; the two counts
    /// above say WHICH, because "a gap" means very different repairs for a
    /// missing octave and for a missing velocity layer.
    public var gapCount: Int { pitchGapCount + velocityGapCount }

    /// "C1–C7" — nil when there are no zones.
    public var pitchLabel: String? {
        pitch.map { SamplerEditorModel.pitchSpanLabel(min: $0.lowerBound, max: $0.upperBound) }
    }

    /// "0–127" — nil when there are no zones.
    public var velocityLabel: String? {
        velocity.map { $0.lowerBound == $0.upperBound
            ? "\($0.lowerBound)"
            : "\($0.lowerBound)–\($0.upperBound)" }
    }

    /// The one-line header: "46 zones · C1–C7 · ⚠ 1 pitch gap". Says WHICH kind
    /// of gap rather than a bare count, and says nothing at all when the map is
    /// solid — a permanently-lit warning slot teaches nothing.
    public var headline: String {
        var parts = ["\(zoneCount) " + (zoneCount == 1 ? "zone" : "zones")]
        if let pitchLabel { parts.append(pitchLabel) }
        if pitchGapCount > 0 {
            parts.append("⚠ \(pitchGapCount) pitch " + (pitchGapCount == 1 ? "gap" : "gaps"))
        }
        if velocityGapCount > 0 {
            parts.append("⚠ \(velocityGapCount) velocity "
                         + (velocityGapCount == 1 ? "gap" : "gaps"))
        }
        return parts.joined(separator: " · ")
    }
}

/// Headless state machine for the built-in SAMPLER editor card — the
/// `PolySynthEditorModel` idiom pointed at the OTHER built-in instrument: the
/// spec tables the card renders, the values read from the LIVE track descriptor
/// (so a wire `track.setInstrument` moves the open card's controls), the zone
/// list and its coverage health, and the apply path.
///
/// ## Why this exists (m26-i's UI half)
///
/// The built-in sampler is deeply tunable in the model and over the wire and
/// had ZERO UI: nothing under `Sources/DAWApp` mentioned `SamplerParams`,
/// `SamplerZone`, `tuneCents`, `loopMode`, or `ampVelTrack`. That is the defect
/// ROADMAP m26-j names — a capability that exists in the code and is invisible
/// because no surface mentions it.
///
/// ## The apply path is a READ-MODIFY-WRITE, and that is not an implementation
/// detail
///
/// `ProjectStore.setInstrument(id:sampler:)` takes a FULL `SamplerParams` and
/// swaps it WHOLESALE (ProjectStore.swift:3079). The wire's `zonePatches` merge
/// is a DAWControl PARSING convenience that does not exist at the store layer.
/// So every edit here reads the live params, mutates ONE field in place, and
/// writes the whole struct back. Three consequences, each of which has a test:
///
/// 1. **The read happens FRESH inside every apply**, never from a snapshot
///    taken when the card opened — otherwise one knob drag would clobber a
///    concurrent wire edit by writing back a stale copy of everything else.
/// 2. **Mutation is in place on a `var`**, never a re-`init`. `SamplerZone` has
///    25 initialiser parameters and `SamplerParams` carries the m26-h
///    provenance fields; a rebuild that forgets one silently NILS it, and
///    "every knob turn erases which library this came from" is precisely the
///    kind of silent-plausible failure this tree keeps producing.
/// 3. **This model's clamp is the ONLY clamp.** Unlike the poly-synth path —
///    which the store rebuilds through `PolySynthParams.init`
///    (ProjectStore.swift:3069) — a supplied `SamplerParams` passes through
///    untouched. There is no belt-and-suspenders re-clamp behind us.
///
/// ## What edits cost
///
/// `setInstrument` validates EVERY zone's file before committing
/// (ProjectStore.swift:3052 → `validateSamplerZones`): a `fileExists` plus a
/// media read per zone, per apply. For a 300-zone library that is 300 stats on
/// the main actor per knob tick, and if any sample file has MOVED the whole
/// sampler becomes read-only — even `gain` and `oneShot` throw. The view must
/// therefore treat `lastErrorMessage` as a real, reachable state, not a
/// theoretical one, and should think twice before wiring this to a
/// per-frame drag on a large library.
///
/// No SwiftUI/AppKit: the card is thin over this and the tests drive it against
/// a real store. NO NEW WIRE SURFACE — every edit funnels through the same
/// `ProjectStore.setInstrument` that `track.setInstrument` calls, and every read
/// mirrors `instrument.describeSampler`.
@MainActor
@Observable
public final class SamplerEditorModel {
    /// Reads the LIVE resolved descriptor for a track — nil when the track is
    /// gone or is not an instrument track (the `PolySynthEditorModel`
    /// injector's contract, verbatim).
    private let descriptorProvider: (UUID) -> InstrumentDescriptor?
    /// Writes a complete `SamplerParams` — wired to
    /// `store.setInstrument(id:sampler:)`, the wire's own funnel. Throws for a
    /// non-instrument track, for a zone whose file has vanished, and for a
    /// routed strip mid-take.
    private let applySampler: (UUID, SamplerParams) throws -> Void

    /// The track being tuned (nil = the model is idle).
    public private(set) var trackID: UUID?
    /// The header's context tag ("on Sax") — computed by the caller at open
    /// time (the store owns names, the model just displays).
    public private(set) var targetLabel: String = ""
    /// A store refusal surfaced inline. NOT rare on this card — see the
    /// read-only case in the type doc.
    public private(set) var lastErrorMessage: String?
    /// The zone the per-zone controls edit (nil = none selected, the card shows
    /// only the globals and the list). Set through `select(zoneID:)`.
    public private(set) var selectedZoneID: UUID?

    public init(
        descriptor: @escaping (UUID) -> InstrumentDescriptor?,
        applySampler: @escaping (UUID, SamplerParams) throws -> Void
    ) {
        self.descriptorProvider = descriptor
        self.applySampler = applySampler
    }

    /// Points the editor at one track and resets transient state.
    public func prepare(trackID: UUID, targetLabel: String) {
        self.trackID = trackID
        self.targetLabel = targetLabel
        lastErrorMessage = nil
        selectedZoneID = nil
    }

    /// Clears the target on close, so a stale card can never re-render.
    public func clear() {
        trackID = nil
        targetLabel = ""
        lastErrorMessage = nil
        selectedZoneID = nil
    }

    // MARK: - Live reads

    /// The open track's live instrument descriptor (nil = closed, the track
    /// vanished, or it is not an instrument track).
    public var descriptor: InstrumentDescriptor? {
        trackID.flatMap { descriptorProvider($0) }
    }

    /// Whether the open target still plays the built-in sampler — the card's
    /// render gate: a wire kind-switch mid-open honestly drops the card, never
    /// a stale ghost.
    public var targetIsSampler: Bool {
        descriptor?.kind == .sampler
    }

    /// The live sampler config. A `.sampler` track that has never been
    /// configured resolves to `SamplerParams()` — zero zones, a silent but
    /// entirely legal sampler. (The wire's `instrument.describeSampler`
    /// REFUSES that state; the editor deliberately does not, because refusing
    /// to show a user the controls for the instrument they just selected is not
    /// a defensible UI. The first edit materialises the config.)
    public var params: SamplerParams {
        descriptor?.resolvedSampler ?? SamplerParams()
    }

    /// The live zone list, O(1) — for the header's count, so no view ever walks
    /// a 300-element array to render "46 zones".
    public var zoneCount: Int { params.zones.count }

    /// The zone list in render shape.
    public var zoneRows: [SamplerZoneRow] { params.zones.map(SamplerZoneRow.init) }

    /// The header's coverage health.
    public var coverage: SamplerCoverageSummary { SamplerCoverageSummary(zones: params.zones) }

    // MARK: - The global spec tables (source of truth: SamplerParams)

    /// The Sampler's numeric globals, in `SamplerParams` field order. Ranges and
    /// reset defaults come from `SamplerParams` itself so the table cannot drift
    /// from the domain clamps.
    ///
    /// `attack`/`release` are the sampler's ANTI-CLICK ramps, not a musical
    /// envelope — the musical shaping is per-zone. The labels say so.
    public static let specs: [SamplerParamSpec] = {
        let d = SamplerParams()
        return [
            SamplerParamSpec(name: "attack", label: "Attack",
                             range: SamplerParams.attackRange,
                             defaultValue: d.attack, unit: "s"),
            SamplerParamSpec(name: "release", label: "Release",
                             range: SamplerParams.releaseRange,
                             defaultValue: d.release, unit: "s"),
            SamplerParamSpec(name: "gain", label: "Gain",
                             range: SamplerParams.gainRange,
                             defaultValue: d.gain, unit: "linear"),
        ]
    }()

    /// The one boolean global. NOT in `specs` — a toggle, never a knob.
    ///
    /// ⚠️ The detail line states the loop precedence because a user who turns
    /// this on for a looping library and hears no change deserves to be told
    /// why, not left to guess.
    public static let oneShotSpec = SamplerToggleSpec(
        name: "oneShot", label: "One Shot", defaultValue: SamplerParams().oneShot,
        detail: "Play each sample to its end and ignore note-off — for drums and "
              + "percussion. Zones that LOOP ignore this.")

    // MARK: - The per-zone spec table (source of truth: SamplerZone)

    /// Every numeric per-zone parameter the card edits.
    ///
    /// ⚠️ Two ranges here are NOT the global's, despite sharing a field name:
    /// per-zone `gain` is 0…2 (+6 dB — m19-b amendment A5, so an SFZ `volume`
    /// boost imports at level) where the global is 0…1; and per-zone
    /// `decay` is 0…8 with NO minimum floor, deliberately unlike
    /// `SamplerParams.releaseRange`, because a present 0 must stay legal (it
    /// equals the nil default: no decay stage).
    ///
    /// ⚠️ Per-zone `attack`/`release` clamp to `SamplerParams`' ranges —
    /// `SamplerZone` has no attack/release range of its own (Model.swift:1800,
    /// 1803). That is the domain's choice, mirrored, not a shortcut.
    public static let zoneSpecs: [SamplerParamSpec] = [
        SamplerParamSpec(name: "tuneCents", label: "Tune",
                         range: SamplerZone.tuneCentsRange, defaultValue: 0, unit: "cents"),
        SamplerParamSpec(name: "pan", label: "Pan",
                         range: SamplerZone.panRange, defaultValue: 0, unit: "pan"),
        SamplerParamSpec(name: "attack", label: "Attack",
                         range: SamplerParams.attackRange,
                         defaultValue: SamplerParams().attack, unit: "s"),
        SamplerParamSpec(name: "decay", label: "Decay",
                         range: SamplerZone.decayRange, defaultValue: 0, unit: "s"),
        SamplerParamSpec(name: "sustain", label: "Sustain",
                         range: SamplerZone.sustainRange, defaultValue: 1, unit: "level"),
        SamplerParamSpec(name: "release", label: "Release",
                         range: SamplerParams.releaseRange,
                         defaultValue: SamplerParams().release, unit: "s"),
        SamplerParamSpec(name: "gain", label: "Gain",
                         range: SamplerZone.gainRange, defaultValue: 1, unit: "linear"),
    ]

    /// The grouped layout, OUTPUT always LAST — the hard strip rule from the
    /// SSL/Cubase/Pro-C3 precedent the poly-synth card follows.
    public static let zoneGroups: [(title: String, names: [String])] = [
        ("PITCH", ["tuneCents"]),
        ("ENVELOPE", ["attack", "decay", "sustain", "release"]),
        ("OUTPUT", ["pan", "gain"]),
    ]

    /// The loop modes a zone can be in, plus "no loop" (nil) — the picker's
    /// segments.
    public static let loopModes: [SamplerLoopMode?] = [nil, .sustain, .continuous]

    public static func loopModeLabel(_ mode: SamplerLoopMode?) -> String {
        switch mode {
        case nil: return "No Loop"
        case .sustain: return "Sustain"
        case .continuous: return "Continuous"
        }
    }

    /// What each loop mode actually does, in the beginner-readable register the
    /// design language asks for. These are the fields that make a held note
    /// SUSTAIN instead of decaying through the end of its sample.
    public static func loopModeDetail(_ mode: SamplerLoopMode?) -> String {
        switch mode {
        case nil:
            return "The sample plays straight through and stops when it runs out."
        case .sustain:
            return "Loops while the note is held, then plays on through the sample's "
                 + "natural tail when you let go."
        case .continuous:
            return "Loops for as long as the note sounds, including through the release."
        }
    }

    // MARK: - Global values + edits

    /// The current value for one global by field name (nil for an unknown name,
    /// structurally impossible from the spec table).
    public static func paramValue(_ name: String, in params: SamplerParams) -> Double? {
        switch name {
        case "attack": return params.attack
        case "release": return params.release
        case "gain": return params.gain
        default: return nil
        }
    }

    /// The current value for one global row (the spec default when unreadable).
    public func value(for spec: SamplerParamSpec) -> Double {
        Self.paramValue(spec.name, in: params) ?? spec.defaultValue
    }

    /// The live one-shot global.
    public var oneShot: Bool { params.oneShot }

    /// Applies one global edit: clamps to the spec range (this model's clamp is
    /// the ONLY clamp — the store passes a supplied `SamplerParams` through
    /// untouched), then read-modify-writes the whole struct.
    public func set(name: String, value: Double) {
        guard let spec = Self.specs.first(where: { $0.name == name }) else { return }
        let clamped = value.clamped(to: spec.range)
        mutate { params in
            switch name {
            case "attack": params.attack = clamped
            case "release": params.release = clamped
            case "gain": params.gain = clamped
            default: return false
            }
            return true
        }
    }

    /// Sets a global from a 0…1 knob travel fraction.
    public func setFraction(_ fraction: Double, for spec: SamplerParamSpec) {
        set(name: spec.name, value: Self.value(forFraction: fraction, spec: spec))
    }

    /// Double-click reset — back to the `SamplerParams()` default.
    public func resetToDefault(_ spec: SamplerParamSpec) {
        set(name: spec.name, value: spec.defaultValue)
    }

    /// Applies the one-shot toggle.
    public func setOneShot(_ on: Bool) {
        mutate { params in
            params.oneShot = on
            return true
        }
    }

    // MARK: - Selection

    /// Selects a zone by its own id (nil deselects). An id that is not in the
    /// live list is accepted and simply reads as no selection — the list can
    /// change under the card at any moment.
    public func select(zoneID: UUID?) {
        selectedZoneID = zoneID
        lastErrorMessage = nil
    }

    /// The live selected zone, or nil when nothing is selected OR the selected
    /// zone has VANISHED (a wire zones-replace under the open card). The card
    /// reads this, never a cached copy, so a vanished zone drops the per-zone
    /// controls instead of editing a ghost.
    public var selectedZone: SamplerZone? {
        guard let selectedZoneID else { return nil }
        return params.zones.first { $0.id == selectedZoneID }
    }

    /// The selected zone in render shape.
    public var selectedZoneRow: SamplerZoneRow? { selectedZone.map(SamplerZoneRow.init) }

    // MARK: - Per-zone values + edits

    /// The EFFECTIVE value of one per-zone field: the zone's explicit value
    /// when it has one, otherwise what the domain's `nil` resolves to.
    ///
    /// ⚠️ For `attack` and `release`, nil inherits the LIVE global — so this
    /// returns the global's current value, not the spec's static default. That
    /// is the number the engine will use, which is the number a knob must show.
    public static func zoneValue(_ name: String, in zone: SamplerZone,
                                 globals: SamplerParams) -> Double? {
        switch name {
        case "tuneCents": return zone.tuneCents ?? 0
        case "pan": return zone.pan ?? 0
        case "attack": return zone.attack ?? globals.attack
        case "decay": return zone.decay ?? 0
        case "sustain": return zone.sustain ?? 1
        case "release": return zone.release ?? globals.release
        case "gain": return zone.gain
        default: return nil
        }
    }

    /// The current value for one per-zone row (the spec default when there is
    /// no selection).
    public func zoneValue(for spec: SamplerParamSpec) -> Double {
        guard let zone = selectedZone else { return spec.defaultValue }
        return Self.zoneValue(spec.name, in: zone, globals: params) ?? spec.defaultValue
    }

    /// Whether the selected zone leaves this field UNSET, i.e. the knob is
    /// showing an inherited/implicit value rather than one this zone chose. The
    /// card dims those readouts — "0 cents because nobody set it" and "0 cents
    /// because someone set it" look identical otherwise.
    ///
    /// ⚠️ `pan` is the field where that distinction has TEETH: nil pan keeps the
    /// legacy unity dual-mono gains (1.0/1.0) while an explicit 0 sits at the
    /// pan law's −3 dB centre (0.7071). Touching a centred pan knob is
    /// therefore an audible −3 dB change, and it is not reversible by dragging
    /// back to 0 — only `resetZoneParam` restores nil.
    public func zoneParamIsUnset(_ name: String) -> Bool {
        guard let zone = selectedZone else { return true }
        switch name {
        case "tuneCents": return zone.tuneCents == nil
        case "pan": return zone.pan == nil
        case "attack": return zone.attack == nil
        case "decay": return zone.decay == nil
        case "sustain": return zone.sustain == nil
        case "release": return zone.release == nil
        case "gain": return false   // non-optional in the domain: always set
        default: return true
        }
    }

    /// Applies one per-zone edit to the SELECTED zone. Clamps to the spec range
    /// first (this model's clamp is the only clamp), then read-modify-writes.
    public func setZoneParam(name: String, value: Double) {
        guard let spec = Self.zoneSpecs.first(where: { $0.name == name }) else { return }
        let clamped = value.clamped(to: spec.range)
        mutateSelectedZone { zone in
            switch name {
            case "tuneCents": zone.tuneCents = clamped
            case "pan": zone.pan = clamped
            case "attack": zone.attack = clamped
            case "decay": zone.decay = clamped
            case "sustain": zone.sustain = clamped
            case "release": zone.release = clamped
            case "gain": zone.gain = clamped
            default: return false
            }
            return true
        }
    }

    /// Sets a per-zone row from a 0…1 knob travel fraction.
    public func setZoneFraction(_ fraction: Double, for spec: SamplerParamSpec) {
        setZoneParam(name: spec.name, value: Self.value(forFraction: fraction, spec: spec))
    }

    /// Double-click reset for a per-zone row: back to UNSET (nil), which is the
    /// domain's real default — not to the nil-equivalent NUMBER, because for
    /// `pan` those two are audibly different (see `zoneParamIsUnset`) and for
    /// `attack`/`release` an explicit number stops tracking the global.
    /// `gain` is non-optional in the domain, so it resets to its 1.0 unity.
    public func resetZoneParam(_ spec: SamplerParamSpec) {
        mutateSelectedZone { zone in
            switch spec.name {
            case "tuneCents": zone.tuneCents = nil
            case "pan": zone.pan = nil
            case "attack": zone.attack = nil
            case "decay": zone.decay = nil
            case "sustain": zone.sustain = nil
            case "release": zone.release = nil
            case "gain": zone.gain = 1
            default: return false
            }
            return true
        }
    }

    // MARK: - Per-zone LOOP (m20-g) — the fields that make a note sustain

    /// The selected zone's loop mode (nil = no loop, or no selection).
    public var selectedZoneLoopMode: SamplerLoopMode? { selectedZone?.loopMode }
    /// Loop start in SOURCE-FILE frames, INCLUSIVE. nil = frame 0.
    public var selectedZoneLoopStart: Int? { selectedZone?.loopStart }
    /// Loop end in SOURCE-FILE frames, EXCLUSIVE. nil = the zone's resolved end.
    public var selectedZoneLoopEnd: Int? { selectedZone?.loopEnd }

    // ⚠️ FRAMES, NOT SECONDS. `loopStart`/`loopEnd` are source-file frame
    // indices, and this model deliberately exposes them raw: converting to
    // seconds needs the sample FILE's own sample rate, which is not stored on
    // the zone (`SamplerZone` has no rate field) and can only be learned by
    // opening the file. That is disk I/O, it would run on the main actor, and
    // it would run once per zone — so this model does not do it, and the view
    // layer decides how to present a frame index.

    /// Sets the selected zone's loop mode. nil turns looping off.
    public func setLoopMode(_ mode: SamplerLoopMode?) {
        mutateSelectedZone { zone in
            zone.loopMode = mode
            return true
        }
    }

    /// Sets the loop start (nil = frame 0), re-clamping the whole span.
    public func setLoopStart(_ frames: Int?) {
        mutateSelectedZone { zone in
            let span = Self.clampedLoopSpan(
                start: frames, end: zone.loopEnd, fileURL: zone.audioFileURL)
            zone.loopStart = span.start
            zone.loopEnd = span.end
            return true
        }
    }

    /// Sets the loop end (nil = the zone's resolved end), re-clamping the span.
    public func setLoopEnd(_ frames: Int?) {
        mutateSelectedZone { zone in
            let span = Self.clampedLoopSpan(
                start: zone.loopStart, end: frames, fileURL: zone.audioFileURL)
            zone.loopStart = span.start
            zone.loopEnd = span.end
            return true
        }
    }

    /// The domain's OWN loop-span clamp — start ≥ 0, and end RAISED to
    /// start + 1 rather than SWAPPED (a swap would silently invert
    /// skip-vs-stop intent). Rather than restate that law, this runs the pair
    /// through a throwaway `SamplerZone.init` and reads the clamped values back
    /// off it, so the UI cannot diverge from the wire — which reaches the same
    /// law by building a `SamplerZone` out of its parsed fields
    /// (Commands.swift's `parseZoneFields` → `SamplerZone.init`,
    /// Model.swift:1804-1809). The throwaway is a struct with a discarded
    /// fresh id; nothing escapes.
    static func clampedLoopSpan(start: Int?, end: Int?,
                                fileURL: URL) -> (start: Int?, end: Int?) {
        let probe = SamplerZone(audioFileURL: fileURL, loopStart: start, loopEnd: end)
        return (probe.loopStart, probe.loopEnd)
    }

    /// Whether a zone's voices actually free themselves at the end of the
    /// sample, given the live global.
    ///
    /// ⛔ **LOOP MODE WINS OVER ONE SHOT.** A looping voice is NEVER one-shot —
    /// the engine forces the non-one-shot override on trigger
    /// (`SamplerInstrument.swift:826-828`: `voice.looping = zone.loopMode != 0;
    /// if voice.looping { voice.oneShotOverride = 0 }`), which beats BOTH the
    /// per-zone override and the live global. Without that rule a continuous
    /// loop under a global one-shot would drone until its voice was stolen.
    /// The card states this so nobody has to discover it by ear.
    public static func effectiveOneShot(zone: SamplerZone, globalOneShot: Bool) -> Bool {
        if zone.loopMode != nil { return false }
        return zone.oneShot ?? globalOneShot
    }

    /// The effective one-shot for the selected zone (nil = no selection).
    public var selectedZoneIsOneShot: Bool? {
        selectedZone.map { Self.effectiveOneShot(zone: $0, globalOneShot: params.oneShot) }
    }

    /// True when One Shot is switched ON somewhere that would apply, but this
    /// zone loops and therefore ignores it — the card's inline explanation
    /// trigger, so an ineffective toggle is never silent.
    public var selectedZoneLoopOverridesOneShot: Bool {
        guard let zone = selectedZone, zone.loopMode != nil else { return false }
        return zone.oneShot ?? params.oneShot
    }

    // MARK: - Knob geometry (fraction ↔ value)

    /// Every Sampler range is LINEAR: there is no Hz-unit parameter on this
    /// card, and the house rule gives the log taper only to those.
    public static func fraction(forValue value: Double, spec: SamplerParamSpec) -> Double {
        let lo = spec.range.lowerBound, hi = spec.range.upperBound
        guard hi > lo else { return 0 }
        return (value.clamped(to: spec.range) - lo) / (hi - lo)
    }

    /// The value at a 0…1 knob fraction.
    public static func value(forFraction fraction: Double, spec: SamplerParamSpec) -> Double {
        let lo = spec.range.lowerBound, hi = spec.range.upperBound
        return lo + fraction.clamped(to: 0...1) * (hi - lo)
    }

    /// The current global-row fraction.
    public func fraction(for spec: SamplerParamSpec) -> Double {
        Self.fraction(forValue: value(for: spec), spec: spec)
    }

    /// The current per-zone-row fraction.
    public func zoneFraction(for spec: SamplerParamSpec) -> Double {
        Self.fraction(forValue: zoneValue(for: spec), spec: spec)
    }

    /// Whether a row's knob sweeps from CENTRE rather than from its minimum —
    /// true for the ranges that straddle zero (tune, pan). Unlike the poly
    /// synth, this card genuinely has bipolar rows, so the fill anchor is not
    /// always 0.
    public static func isBipolar(_ spec: SamplerParamSpec) -> Bool {
        spec.range.lowerBound < 0
    }

    // MARK: - Presentation (readout / accent)

    /// The SF Mono readout for a value: `(text, unit)`. Same crossovers as the
    /// poly-synth card where the units coincide — envelope SECONDS read in ms
    /// below one second and cross to "s" at ≥ 1 s, linear gains read as their
    /// dB equivalent so every gain readout in the app speaks one unit, 0…1
    /// levels read as % — plus this card's two own units: cents read signed,
    /// and pan reads L/C/R. The stored values stay raw.
    public static func readout(value: Double, spec: SamplerParamSpec) -> (text: String, unit: String) {
        if spec.name == "gain" {
            guard value > 0 else { return ("-∞", "dB") }
            return (String(format: "%.1f", 20 * log10(value)), "dB")
        }
        switch spec.unit {
        case "s":
            let ms = value * 1_000
            if ms >= 1_000 { return (String(format: "%.2f", value), "s") }
            if ms < 10 {
                // Sub-10 ms ramps need the decimal — a 1 ms anti-click default
                // must never read as "1" next to a 1 s release.
                return (String(format: "%.1f", ms), "ms")
            }
            return (String(format: "%.0f", ms), "ms")
        case "cents":
            // Signed, because the sign IS the information — "+50" and "-50" are
            // opposite edits and an unsigned readout hides which one happened.
            // Zero is the one value with no direction, so it reads bare rather
            // than as a nonsensical "+0".
            if abs(value) < 0.5 { return ("0", "cents") }
            return (String(format: "%+.0f", value), "cents")
        case "pan":
            if abs(value) < 0.005 { return ("C", "") }
            return (String(format: "%.0f", abs(value) * 100), value < 0 ? "L" : "R")
        default:
            return (String(format: "%.0f", value * 100), "%")
        }
    }

    /// Whether a row earns the cyan level accent: only the genuinely
    /// level-flavored gains (the `PanKnob` precedent,
    /// docs/DESIGN-LANGUAGE.md Rule 3 — pan has its own treatment and tune,
    /// envelope and loop rows stay neutral).
    public static func isLevelParam(_ spec: SamplerParamSpec) -> Bool {
        spec.name == "gain"
    }

    /// "C1–C7", or "C4" for a single key. The note names come from DAWCore's
    /// SOLE note-name derivation.
    ///
    /// `nonisolated` because the `Sendable` row/summary value types above use
    /// it, and they are not main-actor bound — a zone list can be formatted off
    /// the main actor. It touches no state, so this is pure arithmetic on its
    /// arguments.
    nonisolated public static func pitchSpanLabel(min: Int, max: Int) -> String {
        min == max
            ? Fundamental.noteName(midiNote: min)
            : "\(Fundamental.noteName(midiNote: min))–\(Fundamental.noteName(midiNote: max))"
    }

    // MARK: - The read-modify-write funnel

    /// Reads the live params FRESH, hands them to `body` for one in-place
    /// mutation, and writes the whole struct back. `body` returns false to
    /// abort without writing.
    ///
    /// The freshness is the point: a snapshot taken when the card opened would
    /// let one knob drag write back a stale copy of every OTHER field, silently
    /// undoing a concurrent wire edit.
    private func mutate(_ body: (inout SamplerParams) -> Bool) {
        guard let trackID else { return }
        guard let descriptor = descriptorProvider(trackID) else {
            // The track is gone or is not an instrument track. Go through to
            // the store anyway so the USER reads the store's teaching refusal
            // rather than a message this model invented (the
            // `PolySynthEditorModel` precedent). Both of those cases write
            // NOTHING — an unknown id returns nil and a non-instrument track
            // throws — which is what makes this safe. ⚠️ It is safe ONLY
            // because of that: unlike the poly-synth path, a sampler write is
            // WHOLESALE, so an injector that returned nil for a live sampler
            // track would clear its zones here. `descriptor`'s contract (nil ⇒
            // gone or not an instrument track) is load-bearing, not advisory.
            var fallback = SamplerParams()
            guard body(&fallback) else { return }
            commit(fallback)
            return
        }
        guard descriptor.kind == .sampler else {
            // A wire kind-switch landed under the open card. Refusing loudly
            // beats writing sampler settings onto a track that will not use
            // them — an edit that appears to work and changes nothing audible
            // is this codebase's characteristic failure mode.
            lastErrorMessage = "This track no longer plays the built-in Sampler."
            return
        }
        var params = descriptor.resolvedSampler
        guard body(&params) else { return }
        commit(params)
    }

    /// The per-zone twin: finds the SELECTED zone by ID in the fresh read (never
    /// by a cached index — zones are wholesale-replaced, so an index can land on
    /// a different zone), mutates it in place, and writes back.
    private func mutateSelectedZone(_ body: (inout SamplerZone) -> Bool) {
        guard selectedZoneID != nil else { return }
        var vanished = false
        mutate { params in
            guard let zoneID = self.selectedZoneID,
                  let index = params.zones.firstIndex(where: { $0.id == zoneID }) else {
                vanished = true
                return false
            }
            return body(&params.zones[index])
        }
        if vanished {
            selectedZoneID = nil
            lastErrorMessage = "That zone is no longer in this sampler."
        }
    }

    private func commit(_ params: SamplerParams) {
        guard let trackID else { return }
        do {
            try applySampler(trackID, params)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }
}
