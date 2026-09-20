import Foundation
import Testing
@testable import DAWAppKit
import DAWCore

/// Unit tests for the headless POLY SYNTH editor model (the
/// `EffectEditorModelTests` twin for instruments): the spec table sourced from
/// `PolySynthParams` (ranges/defaults can never fork the domain clamps), the
/// grouped OSC/ENVELOPE/FILTER/OUTPUT layout (OUTPUT last — the hard strip
/// rule), the fraction↔value knob mapping (log taper for the cutoff), the
/// readout crossovers (ms↔s, Hz↔kHz, % amounts, dB-equivalent gain), and —
/// the load-bearing part — APPLY-PATH IDENTITY with the wire: driven against
/// a REAL `ProjectStore`, every edit round-trips through `setInstrument` (the
/// exact method `track.setInstrument` calls) and a knob drag coalesces to ONE
/// undo step.
///
/// ⚠️ THIS SUITE ALSO OWNS THE `SamplerEditorModel` TESTS (the "Sampler —"
/// sections in the second half). That is a STRUCTURAL fold, not a topical
/// merge: `MainActorOccupancySiteTests`'s Leg C caps the tree's `@MainActor`
/// `@Suite` count at 330 and the tree is AT 330, so the sampler's editor tests
/// could not have their own suite. The reasoning, and why the bound cannot
/// legitimately be raised, is recorded at the section MARK below. A failure
/// report from this suite may therefore be about the SAMPLER, not the poly
/// synth — read the test name, not this header.
@Suite("PolySynthEditorModel")
@MainActor
struct PolySynthEditorModelTests {

    // MARK: - Fixtures

    /// A model bound to a real store's `setInstrument` — the same closures
    /// `AppModel` injects (UI == wire by construction).
    private static func makeStoreBacked(_ store: ProjectStore) -> PolySynthEditorModel {
        PolySynthEditorModel(
            descriptor: { trackID in
                guard let track = store.tracks.first(where: { $0.id == trackID }),
                      track.kind == .instrument else { return nil }
                return track.instrument ?? .default
            },
            apply: { trackID, name, value in
                _ = try store.setInstrument(
                    id: trackID,
                    attack: name == "attack" ? value : nil,
                    decay: name == "decay" ? value : nil,
                    sustain: name == "sustain" ? value : nil,
                    release: name == "release" ? value : nil,
                    cutoffHz: name == "cutoffHz" ? value : nil,
                    resonance: name == "resonance" ? value : nil,
                    gain: name == "gain" ? value : nil)
            },
            setWaveform: { trackID, waveform in
                _ = try store.setInstrument(id: trackID, waveform: waveform)
            })
    }

    private static func spec(_ name: String) -> PolySynthParamSpec {
        PolySynthEditorModel.specs.first { $0.name == name }!
    }

    // MARK: - Spec table (single source of truth: PolySynthParams)

    @Test("the spec table carries every numeric setInstrument field, in wire order")
    func specTableNames() {
        #expect(PolySynthEditorModel.specs.map(\.name) ==
                ["attack", "decay", "sustain", "release", "cutoffHz", "resonance", "gain"])
    }

    @Test("ranges and reset defaults are PolySynthParams's own, verbatim")
    func specTableSourcedFromDomain() {
        let d = PolySynthParams()
        #expect(Self.spec("attack").range == PolySynthParams.attackRange)
        #expect(Self.spec("decay").range == PolySynthParams.decayRange)
        #expect(Self.spec("sustain").range == PolySynthParams.sustainRange)
        #expect(Self.spec("release").range == PolySynthParams.releaseRange)
        #expect(Self.spec("cutoffHz").range == PolySynthParams.cutoffRange)
        #expect(Self.spec("resonance").range == PolySynthParams.resonanceRange)
        #expect(Self.spec("gain").range == PolySynthParams.gainRange)
        #expect(Self.spec("attack").defaultValue == d.attack)
        #expect(Self.spec("decay").defaultValue == d.decay)
        #expect(Self.spec("sustain").defaultValue == d.sustain)
        #expect(Self.spec("release").defaultValue == d.release)
        #expect(Self.spec("cutoffHz").defaultValue == d.cutoffHz)
        #expect(Self.spec("resonance").defaultValue == d.resonance)
        #expect(Self.spec("gain").defaultValue == d.gain)
        // Every default sits inside its range — a knob can always reset.
        for spec in PolySynthEditorModel.specs {
            #expect(spec.range.contains(spec.defaultValue), "\(spec.name) default out of range")
        }
    }

    // MARK: - Grouped layout (OSC picker + three knob sections, OUTPUT last)

    @Test("groups are ENVELOPE → FILTER → OUTPUT, with OUTPUT last (the hard strip rule)")
    func groupLayout() {
        let groups = PolySynthEditorModel.groups
        #expect(groups.map(\.title) == ["ENVELOPE", "FILTER", "OUTPUT"])
        #expect(groups.last?.title == "OUTPUT")
        #expect(groups[0].items.map(\.name) == ["attack", "decay", "sustain", "release"])
        #expect(groups[1].items.map(\.name) == ["cutoffHz", "resonance"])
        #expect(groups[2].items.map(\.name) == ["gain"])
    }

    @Test("every numeric spec appears in exactly one group (waveform is the OSC picker, not a knob)")
    func groupCoverage() {
        let grouped = PolySynthEditorModel.groups.flatMap { $0.items.map(\.name) }
        #expect(grouped.sorted() == PolySynthEditorModel.specs.map(\.name).sorted())
        #expect(Set(grouped).count == grouped.count, "no spec may render twice")
        #expect(!grouped.contains("waveform"))
    }

    @Test("the OSC picker offers the domain's waveforms, saw (the default) first")
    func waveformCatalog() {
        #expect(PolySynthEditorModel.waveforms == PolySynthParams.Waveform.allCases)
        #expect(PolySynthEditorModel.waveforms.first == .saw)
        #expect(PolySynthEditorModel.waveforms.first == PolySynthParams().waveform)
        #expect(PolySynthEditorModel.waveformLabel(.saw) == "Saw")
        #expect(PolySynthEditorModel.waveformLabel(.square) == "Square")
        #expect(PolySynthEditorModel.waveformLabel(.triangle) == "Triangle")
        #expect(PolySynthEditorModel.waveformLabel(.sine) == "Sine")
    }

    // MARK: - Knob geometry (log cutoff, linear everything else)

    @Test("the cutoff is logarithmic; times and levels are linear")
    func scales() {
        #expect(PolySynthEditorModel.scale(for: Self.spec("cutoffHz")) == .logarithmic)
        for name in ["attack", "decay", "sustain", "release", "resonance", "gain"] {
            #expect(PolySynthEditorModel.scale(for: Self.spec(name)) == .linear, "\(name)")
        }
    }

    @Test("the log taper puts the geometric mean at half travel")
    func logTaperMidpoint() {
        let cutoff = Self.spec("cutoffHz")
        let geometricMean = (cutoff.range.lowerBound * cutoff.range.upperBound).squareRoot()
        let f = PolySynthEditorModel.fraction(forValue: geometricMean, spec: cutoff)
        #expect(abs(f - 0.5) < 1e-9)
        // And the inverse lands back on the mean.
        let v = PolySynthEditorModel.value(forFraction: 0.5, spec: cutoff)
        #expect(abs(v - geometricMean) < 1e-6)
    }

    @Test("fraction ↔ value round-trips across every spec's travel")
    func fractionRoundTrip() {
        for spec in PolySynthEditorModel.specs {
            for f in [0.0, 0.25, 0.5, 0.75, 1.0] {
                let value = PolySynthEditorModel.value(forFraction: f, spec: spec)
                #expect(spec.range.contains(value), "\(spec.name) value at f=\(f)")
                let back = PolySynthEditorModel.fraction(forValue: value, spec: spec)
                #expect(abs(back - f) < 1e-9, "\(spec.name) round-trip at f=\(f)")
            }
        }
    }

    /// m39-a — the poly-synth half of the taper-lift conformance proof.
    ///
    /// The card's knob geometry no longer infers `unit == "Hz"`; it reads the
    /// spec's DECLARED curve. This re-computes the pre-lift inline formula —
    /// the arithmetic that stood at `PolySynthEditorModel.swift:287,299` — and
    /// requires bit-for-bit equality at eleven points of travel on all seven
    /// knobs, so a lift that moved a knob cannot pass.
    ///
    /// ⚠️ It also pins that the ENVELOPE TIMES are still LINEAR. The modulation
    /// design (`docs/design/2026-09-19-modulation-layer.md` §4) proposes
    /// `.logarithmic` for attack/decay/release on the future
    /// `InstrumentParamSpec`; that is a real change to three shipping knobs and
    /// is m39-b's deliberate call, not a refactor's side effect. If m39-b
    /// adopts it, this test is the thing that must be updated ON PURPOSE.
    @Test("m39-a: every knob lands on the same value it did before the taper lift")
    func taperLiftMovesNoKnob() {
        func legacyValue(_ f: Double, _ spec: PolySynthParamSpec) -> Double {
            let lo = spec.range.lowerBound, hi = spec.range.upperBound
            let f = f.clamped(to: 0...1)
            if spec.unit == "Hz" && lo > 0 { return lo * pow(hi / lo, f) }
            return lo + f * (hi - lo)
        }
        func legacyFraction(_ v: Double, _ spec: PolySynthParamSpec) -> Double {
            let lo = spec.range.lowerBound, hi = spec.range.upperBound
            guard hi > lo else { return 0 }
            let v = v.clamped(to: spec.range)
            if spec.unit == "Hz" && lo > 0 {
                return (log(v / lo) / log(hi / lo)).clamped(to: 0...1)
            }
            return (v - lo) / (hi - lo)
        }

        #expect(PolySynthEditorModel.specs.count == 7)
        var checked = 0
        for spec in PolySynthEditorModel.specs {
            // Declared == what the old string heuristic produced.
            let inferred: PolySynthEditorModel.Scale =
                spec.unit == "Hz" && spec.range.lowerBound > 0 ? .logarithmic : .linear
            #expect(spec.curve == inferred, "\(spec.name) declared \(spec.curve)")
            for step in 0...10 {
                let f = Double(step) / 10
                let lifted = PolySynthEditorModel.value(forFraction: f, spec: spec)
                #expect(lifted == legacyValue(f, spec), "\(spec.name) at f=\(f)")
                #expect(PolySynthEditorModel.fraction(forValue: lifted, spec: spec)
                        == legacyFraction(lifted, spec), "\(spec.name) inverse at f=\(f)")
                checked += 1
            }
        }
        #expect(checked == 77, "only \(checked) travel points compared")
        // Named, so the envelope-taper question cannot be closed by accident.
        #expect(Self.spec("attack").curve == .linear)
        #expect(Self.spec("decay").curve == .linear)
        #expect(Self.spec("release").curve == .linear)
        #expect(Self.spec("cutoffHz").curve == .logarithmic)
    }

    // MARK: - Readouts (deterministic strings, so captures pin exactly)

    @Test("envelope seconds read in ms and cross to s at one second")
    func timeReadouts() {
        let attack = Self.spec("attack")
        let release = Self.spec("release")
        #expect(PolySynthEditorModel.readout(value: 0.005, spec: attack) == ("5.0", "ms"))
        #expect(PolySynthEditorModel.readout(value: 0.0005, spec: attack) == ("0.5", "ms"))
        #expect(PolySynthEditorModel.readout(value: 0.15, spec: release) == ("150", "ms"))
        #expect(PolySynthEditorModel.readout(value: 0.999, spec: release) == ("999", "ms"))
        #expect(PolySynthEditorModel.readout(value: 1.0, spec: release) == ("1.00", "s"))
        #expect(PolySynthEditorModel.readout(value: 2.5, spec: release) == ("2.50", "s"))
    }

    @Test("the cutoff reads in Hz and crosses to kHz at 1000")
    func cutoffReadouts() {
        let cutoff = Self.spec("cutoffHz")
        #expect(PolySynthEditorModel.readout(value: 40, spec: cutoff) == ("40", "Hz"))
        #expect(PolySynthEditorModel.readout(value: 999, spec: cutoff) == ("999", "Hz"))
        #expect(PolySynthEditorModel.readout(value: 1_000, spec: cutoff) == ("1.00", "kHz"))
        #expect(PolySynthEditorModel.readout(value: 8_000, spec: cutoff) == ("8.00", "kHz"))
        #expect(PolySynthEditorModel.readout(value: 18_000, spec: cutoff) == ("18.00", "kHz"))
    }

    @Test("sustain and resonance read as percentages (wire stays the raw fraction)")
    func amountReadouts() {
        #expect(PolySynthEditorModel.readout(value: 0.7, spec: Self.spec("sustain")) == ("70", "%"))
        #expect(PolySynthEditorModel.readout(value: 0.0, spec: Self.spec("sustain")) == ("0", "%"))
        #expect(PolySynthEditorModel.readout(value: 0.1, spec: Self.spec("resonance")) == ("10", "%"))
        #expect(PolySynthEditorModel.readout(value: 1.0, spec: Self.spec("resonance")) == ("100", "%"))
    }

    @Test("the linear gain reads as its dB equivalent, -∞ at silence")
    func gainReadouts() {
        let gain = Self.spec("gain")
        #expect(PolySynthEditorModel.readout(value: 1.0, spec: gain) == ("0.0", "dB"))
        #expect(PolySynthEditorModel.readout(value: 0.8, spec: gain) == ("-1.9", "dB"))
        #expect(PolySynthEditorModel.readout(value: 0.5, spec: gain) == ("-6.0", "dB"))
        #expect(PolySynthEditorModel.readout(value: 0.0, spec: gain) == ("-∞", "dB"))
    }

    @Test("only the gain earns the level accent")
    func levelAccent() {
        for spec in PolySynthEditorModel.specs {
            #expect(PolySynthEditorModel.isLevelParam(spec) == (spec.name == "gain"), "\(spec.name)")
        }
    }

    // MARK: - Apply-path identity (a REAL store — UI == wire)

    @Test("a fresh instrument track reads every default; edits round-trip through setInstrument")
    func storeRoundTrip() {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let model = Self.makeStoreBacked(store)
        model.prepare(trackID: track.id, targetLabel: "on \(track.name)")
        #expect(model.targetIsPolySynth)
        for spec in PolySynthEditorModel.specs {
            #expect(model.value(for: spec) == spec.defaultValue,
                    "\(spec.name) fresh value must be the domain default")
        }
        // One knob edit lands on the stored descriptor AND reads back live.
        model.set(name: "attack", value: 0.5)
        #expect(model.lastErrorMessage == nil)
        #expect(model.value(for: Self.spec("attack")) == 0.5)
        let stored = store.tracks.first { $0.id == track.id }?.instrument
        #expect(stored?.polySynth.attack == 0.5)
        // The partial update disturbed nothing else.
        #expect(stored?.polySynth.decay == PolySynthParams().decay)
        #expect(stored?.polySynth.waveform == .saw)
        #expect(stored?.kind == .polySynth)
    }

    @Test("set clamps out-of-range values to the domain range before applying")
    func setClamps() {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let model = Self.makeStoreBacked(store)
        model.prepare(trackID: track.id, targetLabel: "on Synth")
        model.set(name: "cutoffHz", value: 999_999)
        #expect(model.value(for: Self.spec("cutoffHz")) == PolySynthParams.cutoffRange.upperBound)
        model.set(name: "cutoffHz", value: 1)
        #expect(model.value(for: Self.spec("cutoffHz")) == PolySynthParams.cutoffRange.lowerBound)
        #expect(model.lastErrorMessage == nil)
        // An unknown name is a silent no-op model-side (the knob list can
        // never offer one — the spec table is the single source of truth).
        model.set(name: "nope", value: 1)
        #expect(model.lastErrorMessage == nil)
    }

    @Test("the waveform picker applies through the same setInstrument funnel")
    func waveformRoundTrip() {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let model = Self.makeStoreBacked(store)
        model.prepare(trackID: track.id, targetLabel: "on Synth")
        #expect(model.waveform == .saw)
        model.setWaveform(.square)
        #expect(model.lastErrorMessage == nil)
        #expect(model.waveform == .square)
        #expect(store.tracks.first { $0.id == track.id }?.instrument?.polySynth.waveform == .square)
        // Numeric settings survive a waveform change (the partial-update law).
        model.set(name: "resonance", value: 0.6)
        model.setWaveform(.sine)
        #expect(model.value(for: Self.spec("resonance")) == 0.6)
    }

    @Test("a knob drag (many rapid sets of one param) lands as ONE undo step")
    func dragCoalesces() {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let model = Self.makeStoreBacked(store)
        model.prepare(trackID: track.id, targetLabel: "on Synth")
        let before = store.undoHistory().undo.count
        // Simulate a drag: many per-tick applies of the same track's cutoff.
        for step in 1...20 {
            model.set(name: "cutoffHz", value: 400 + Double(step) * 100)
        }
        let after = store.undoHistory().undo.count
        #expect(after == before + 1, "a drag must coalesce to exactly one undo entry")
        // Undo restores the pre-drag value (the domain default).
        #expect((try? store.undo()) != nil)
        #expect(model.value(for: Self.spec("cutoffHz")) == Self.spec("cutoffHz").defaultValue)
    }

    @Test("reset-to-default applies the domain default through the same path")
    func resetToDefault() {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let model = Self.makeStoreBacked(store)
        model.prepare(trackID: track.id, targetLabel: "on Synth")
        model.set(name: "gain", value: 0.2)
        #expect(model.value(for: Self.spec("gain")) == 0.2)
        model.resetToDefault(Self.spec("gain"))
        #expect(model.value(for: Self.spec("gain")) == PolySynthParams().gain)
    }

    // MARK: - Honest gates (vanished / retyped / wrong-kind targets)

    @Test("a closed or vanished target reads nothing and never renders")
    func closedYieldsNothing() {
        let store = ProjectStore()
        let model = Self.makeStoreBacked(store)
        #expect(model.descriptor == nil)
        #expect(model.targetIsPolySynth == false)
        // A never-existing track: still honest nothing, and values fall back
        // to defaults so the (gated-away) card could never show garbage.
        model.prepare(trackID: UUID(), targetLabel: "on Ghost")
        #expect(model.descriptor == nil)
        #expect(model.targetIsPolySynth == false)
        #expect(model.value(for: Self.spec("gain")) == PolySynthParams().gain)
        model.clear()
        #expect(model.trackID == nil)
        #expect(model.targetLabel.isEmpty)
    }

    @Test("a wire instrument swap mid-open drops the render gate honestly")
    func kindSwapDropsGate() {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let model = Self.makeStoreBacked(store)
        model.prepare(trackID: track.id, targetLabel: "on Synth")
        #expect(model.targetIsPolySynth)
        // The wire switches the track to the sampler while the card is open.
        _ = try? store.setInstrument(id: track.id, kind: .sampler)
        #expect(model.targetIsPolySynth == false, "the card must not ghost a non-polySynth kind")
    }

    @Test("a non-instrument track surfaces the store's refusal inline")
    func wrongTrackKindSurfacesError() {
        let store = ProjectStore()
        let track = store.addTrack(kind: .audio)
        let model = Self.makeStoreBacked(store)
        // The injected descriptor contract already reads nil for a non-
        // instrument track (the affordance never offers it), but a direct set
        // must surface the store's teaching error, never crash or silently drop.
        model.prepare(trackID: track.id, targetLabel: "on Audio")
        #expect(model.targetIsPolySynth == false)
        model.set(name: "gain", value: 0.5)
        #expect(model.lastErrorMessage != nil)
    }

    // MARK: - SamplerEditorModel (m26-i's UI half)
    //
    // ⚠️ THESE LIVE HERE FOR A STRUCTURAL REASON, NOT A TOPICAL ONE — though
    // the topic is adjacent: `SamplerEditorModel` is the OTHER built-in
    // instrument's editor, the exact `PolySynthEditorModel` shape pointed at
    // the sampler, and it is proven the same way (a REAL `ProjectStore`, so
    // UI == wire by construction).
    //
    // `MainActorOccupancySiteTests`'s Leg C caps the tree's `@MainActor`
    // `@Suite` count at 330 as a REVIEW CADENCE, and the tree is sitting at
    // exactly 330 — so a new `@MainActor` `@Suite` would turn that gate RED at
    // 331. Leg C's own doc says raising the bound requires pasting a passing
    // `scripts/gates/m23aw-prepare-headroom.mjs` campaign, and records that no
    // passing campaign exists to paste (the m23-aw-4 calibration gap). The
    // bound therefore cannot legitimately be raised, and raising it anyway is
    // named there as "the same act as raising the horizon".
    //
    // ⭐ THIS IS THE THIRD CONSECUTIVE ITEM FORCED INTO THIS SHAPE (m26-i, then
    // m26-k's `edit.pasteClips` in `EditHistoryCommandTests.swift:108-125`, now
    // m26-i's UI half). The pressure is real and it is bending test layout;
    // that belongs in m23-aw-4's record, not in another workaround.

    /// Disk-free media stand-in — `setInstrument` validates every zone file
    /// through the media service before committing, so a sampler test cannot
    /// run without one. The FILES themselves must still really exist (DAWCore
    /// does its own `fileExists` first), hence the system-sound fixtures below.
    private struct SamplerStubMedia: MediaImporting {
        func audioFileInfo(at url: URL) throws -> AudioFileInfo {
            AudioFileInfo(durationSeconds: 2.0, sampleRate: 48_000, channelCount: 2)
        }
    }

    // Real, readable audio files present on every macOS install — the
    // `Tests/DAWCoreTests/SamplerTests.swift:15-17` precedent.
    private static let ping = URL(fileURLWithPath: "/System/Library/Sounds/Ping.aiff")
    private static let tink = URL(fileURLWithPath: "/System/Library/Sounds/Tink.aiff")
    private static let glass = URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff")

    /// A model bound to a real store's `setInstrument` — the same closure shape
    /// the app injects, and the same method `track.setInstrument` calls.
    private static func makeSamplerBacked(_ store: ProjectStore) -> SamplerEditorModel {
        SamplerEditorModel(
            descriptor: { trackID in
                guard let track = store.tracks.first(where: { $0.id == trackID }),
                      track.kind == .instrument else { return nil }
                return track.instrument ?? .default
            },
            applySampler: { trackID, params in
                _ = try store.setInstrument(id: trackID, sampler: params)
            })
    }

    private static func samplerZone(
        _ url: URL, root: Int = 60, lo: Int = 0, hi: Int = 127,
        vLo: Int? = nil, vHi: Int? = nil, loop: SamplerLoopMode? = nil
    ) -> SamplerZone {
        SamplerZone(audioFileURL: url, rootPitch: root, minPitch: lo, maxPitch: hi,
                    minVelocity: vLo, maxVelocity: vHi, loopMode: loop)
    }

    /// A store with a `.sampler` instrument track carrying `params`, plus the
    /// media stand-in, and a model already pointed at it.
    private static func samplerFixture(
        _ params: SamplerParams
    ) throws -> (store: ProjectStore, trackID: UUID, model: SamplerEditorModel) {
        let store = ProjectStore()
        store.media = SamplerStubMedia()
        let track = store.addTrack(kind: .instrument)
        try store.setInstrument(id: track.id, kind: .sampler, sampler: params)
        let model = makeSamplerBacked(store)
        model.prepare(trackID: track.id, targetLabel: "on \(track.name)")
        return (store, track.id, model)
    }

    private static func storedSampler(_ store: ProjectStore, _ trackID: UUID) -> SamplerParams? {
        store.tracks.first { $0.id == trackID }?.instrument?.sampler
    }

    private static func samplerSpec(_ name: String) -> SamplerParamSpec {
        SamplerEditorModel.specs.first { $0.name == name }!
    }

    private static func samplerZoneSpec(_ name: String) -> SamplerParamSpec {
        SamplerEditorModel.zoneSpecs.first { $0.name == name }!
    }

    // MARK: Sampler — spec tables (single source of truth: the domain clamps)

    @Test("the sampler's global spec table is SamplerParams's own ranges and defaults")
    func samplerGlobalSpecsSourcedFromDomain() {
        let d = SamplerParams()
        #expect(SamplerEditorModel.specs.map(\.name) == ["attack", "release", "gain"])
        #expect(Self.samplerSpec("attack").range == SamplerParams.attackRange)
        #expect(Self.samplerSpec("release").range == SamplerParams.releaseRange)
        #expect(Self.samplerSpec("gain").range == SamplerParams.gainRange)
        #expect(Self.samplerSpec("attack").defaultValue == d.attack)
        #expect(Self.samplerSpec("release").defaultValue == d.release)
        #expect(Self.samplerSpec("gain").defaultValue == d.gain)
        for spec in SamplerEditorModel.specs {
            #expect(spec.range.contains(spec.defaultValue), "\(spec.name) default out of range")
        }
        // The boolean global is modelled apart from the knob table.
        #expect(SamplerEditorModel.oneShotSpec.defaultValue == d.oneShot)
        #expect(!SamplerEditorModel.specs.contains { $0.name == "oneShot" })
    }

    @Test("the per-zone spec table is SamplerZone's own ranges — including the two that differ from the globals")
    func samplerZoneSpecsSourcedFromDomain() {
        #expect(SamplerEditorModel.zoneSpecs.map(\.name) ==
                ["tuneCents", "pan", "attack", "decay", "sustain", "release", "gain"])
        #expect(Self.samplerZoneSpec("tuneCents").range == SamplerZone.tuneCentsRange)
        #expect(Self.samplerZoneSpec("pan").range == SamplerZone.panRange)
        #expect(Self.samplerZoneSpec("decay").range == SamplerZone.decayRange)
        #expect(Self.samplerZoneSpec("sustain").range == SamplerZone.sustainRange)
        #expect(Self.samplerZoneSpec("gain").range == SamplerZone.gainRange)
        // ⚠️ A zone's attack/release clamp to SamplerParams's ranges —
        // SamplerZone has none of its own (Model.swift:1800, 1803).
        #expect(Self.samplerZoneSpec("attack").range == SamplerParams.attackRange)
        #expect(Self.samplerZoneSpec("release").range == SamplerParams.releaseRange)
        // ⚠️ Same field NAME, different range: per-zone gain reaches +6 dB
        // (m19-b A5) where the global stops at unity. A shared table would have
        // silently taken one of them.
        #expect(Self.samplerZoneSpec("gain").range != Self.samplerSpec("gain").range)
        #expect(Self.samplerZoneSpec("gain").range.upperBound == 2)
        #expect(Self.samplerSpec("gain").range.upperBound == 1)
        // Per-zone decay must keep a present 0 legal (it equals the nil default).
        #expect(Self.samplerZoneSpec("decay").range.lowerBound == 0)
        for spec in SamplerEditorModel.zoneSpecs {
            #expect(spec.range.contains(spec.defaultValue), "\(spec.name) default out of range")
        }
        // Every zone spec appears in exactly one group, OUTPUT last.
        let grouped = SamplerEditorModel.zoneGroups.flatMap(\.names)
        #expect(grouped.sorted() == SamplerEditorModel.zoneSpecs.map(\.name).sorted())
        #expect(Set(grouped).count == grouped.count)
        #expect(SamplerEditorModel.zoneGroups.last?.title == "OUTPUT")
    }

    // MARK: Sampler — read-modify-write preserves everything it did not touch

    @Test("a global edit leaves every zone byte-identical and keeps the import provenance")
    func samplerGlobalEditPreservesZonesAndProvenance() throws {
        let zones = [Self.samplerZone(Self.ping, root: 36, lo: 24, hi: 47, loop: .continuous),
                     Self.samplerZone(Self.tink, root: 72, lo: 60, hi: 96)]
        let f = try Self.samplerFixture(SamplerParams(
            zones: zones, oneShot: false, attack: 0.01, release: 0.2, gain: 0.6,
            sourcePath: "/Libraries/Upright Bass.sfz", displayName: "Upright Bass"))
        f.model.set(name: "gain", value: 0.3)
        #expect(f.model.lastErrorMessage == nil)
        let stored = try #require(Self.storedSampler(f.store, f.trackID))
        #expect(stored.gain == 0.3)
        // Every zone survived, byte-identical.
        #expect(stored.zones == zones)
        // Untouched globals survived.
        #expect(stored.attack == 0.01)
        #expect(stored.release == 0.2)
        #expect(stored.oneShot == false)
        // ⚠️ m26-h provenance survived. A read-modify-write that rebuilt
        // SamplerParams through its initialiser instead of mutating in place
        // would NIL both of these on every knob turn, and every other
        // assertion here would still pass.
        #expect(stored.sourcePath == "/Libraries/Upright Bass.sfz")
        #expect(stored.displayName == "Upright Bass")
    }

    @Test("editing ONE zone leaves the other 45 byte-identical, and changes only that field")
    func samplerZoneEditTouchesExactlyOneZone() throws {
        // A 46-zone library, the shape of the imported saxophone that motivated
        // this editor.
        let files = [Self.ping, Self.tink, Self.glass]
        let zones = (0..<46).map { i in
            Self.samplerZone(files[i % 3], root: 24 + i * 2,
                             lo: 24 + i * 2, hi: 25 + i * 2, loop: .continuous)
        }
        let f = try Self.samplerFixture(SamplerParams(
            zones: zones, gain: 0.7,
            sourcePath: "/Libraries/Sax.sfz", displayName: "Tenor Sax"))
        #expect(f.model.zoneCount == 46)

        let target = zones[3]
        f.model.select(zoneID: target.id)
        f.model.setZoneParam(name: "tuneCents", value: -25)
        #expect(f.model.lastErrorMessage == nil)

        let stored = try #require(Self.storedSampler(f.store, f.trackID))
        #expect(stored.zones.count == 46)
        var expected = target
        expected.tuneCents = -25
        #expect(stored.zones[3] == expected, "the edited zone changed in tuneCents and nothing else")
        for i in 0..<46 where i != 3 {
            #expect(stored.zones[i] == zones[i], "zone \(i) must be byte-identical")
        }
        // Globals and provenance untouched by a per-zone edit.
        #expect(stored.gain == 0.7)
        #expect(stored.sourcePath == "/Libraries/Sax.sfz")
        #expect(stored.displayName == "Tenor Sax")
        #expect(f.model.zoneValue(for: Self.samplerZoneSpec("tuneCents")) == -25)
    }

    @Test("every apply re-reads the descriptor, so a concurrent wire edit is not clobbered")
    func samplerApplyReadsFresh() throws {
        let z1 = Self.samplerZone(Self.ping, root: 60)
        let f = try Self.samplerFixture(SamplerParams(zones: [z1], gain: 0.5))
        // The wire changes the sampler out from under the open card.
        let z2 = Self.samplerZone(Self.tink, root: 48)
        _ = try f.store.setInstrument(
            id: f.trackID,
            sampler: SamplerParams(zones: [z1, z2], oneShot: true, attack: 0.4, gain: 0.5))
        // Now the card's gain knob moves. A model that had cached a snapshot at
        // open time would write back the OLD one-zone, non-one-shot config.
        f.model.set(name: "gain", value: 0.9)
        let stored = try #require(Self.storedSampler(f.store, f.trackID))
        #expect(stored.gain == 0.9)
        #expect(stored.zones == [z1, z2], "the concurrent zone change survived")
        #expect(stored.oneShot == true, "the concurrent one-shot change survived")
        #expect(stored.attack == 0.4)
    }

    // MARK: Sampler — clamping (this model's clamp is the ONLY clamp)

    @Test("global and per-zone edits clamp to their own domain ranges before applying")
    func samplerClamps() throws {
        let zone = Self.samplerZone(Self.ping)
        let f = try Self.samplerFixture(SamplerParams(zones: [zone]))
        f.model.select(zoneID: zone.id)

        f.model.set(name: "gain", value: 5)
        #expect(Self.storedSampler(f.store, f.trackID)?.gain == SamplerParams.gainRange.upperBound)
        f.model.set(name: "release", value: 0)
        #expect(Self.storedSampler(f.store, f.trackID)?.release
                == SamplerParams.releaseRange.lowerBound)

        // ⚠️ The SAME field name clamps differently per zone: +6 dB is legal
        // here and is not legal on the global above.
        f.model.setZoneParam(name: "gain", value: 5)
        #expect(Self.storedSampler(f.store, f.trackID)?.zones[0].gain
                == SamplerZone.gainRange.upperBound)
        #expect(SamplerZone.gainRange.upperBound == 2)

        f.model.setZoneParam(name: "tuneCents", value: 99_999)
        #expect(Self.storedSampler(f.store, f.trackID)?.zones[0].tuneCents
                == SamplerZone.tuneCentsRange.upperBound)
        f.model.setZoneParam(name: "pan", value: -5)
        #expect(Self.storedSampler(f.store, f.trackID)?.zones[0].pan
                == SamplerZone.panRange.lowerBound)
        f.model.setZoneParam(name: "decay", value: 100)
        #expect(Self.storedSampler(f.store, f.trackID)?.zones[0].decay
                == SamplerZone.decayRange.upperBound)
        #expect(f.model.lastErrorMessage == nil)

        // An unknown name is a silent no-op on both tables (the spec tables are
        // the only source of names, so a control can never offer one).
        f.model.set(name: "nope", value: 1)
        f.model.setZoneParam(name: "nope", value: 1)
        #expect(f.model.lastErrorMessage == nil)
    }

    @Test("a per-zone reset returns the field to UNSET, not to the nil-equivalent number")
    func samplerZoneResetUnsets() throws {
        let zone = Self.samplerZone(Self.ping)
        let f = try Self.samplerFixture(SamplerParams(zones: [zone], attack: 0.02))
        f.model.select(zoneID: zone.id)
        #expect(f.model.zoneParamIsUnset("pan"))
        // A zone that inherits its attack shows the LIVE global, not the spec's
        // static default.
        #expect(f.model.zoneValue(for: Self.samplerZoneSpec("attack")) == 0.02)

        f.model.setZoneParam(name: "pan", value: 0)
        #expect(f.model.zoneParamIsUnset("pan") == false,
                "an explicit 0 pan is NOT the same as nil — it sits at the -3 dB centre")
        #expect(Self.storedSampler(f.store, f.trackID)?.zones[0].pan == 0)

        f.model.resetZoneParam(Self.samplerZoneSpec("pan"))
        #expect(Self.storedSampler(f.store, f.trackID)?.zones[0].pan == nil)
        #expect(f.model.zoneParamIsUnset("pan"))
        // gain is non-optional in the domain, so it resets to unity instead.
        f.model.setZoneParam(name: "gain", value: 1.8)
        f.model.resetZoneParam(Self.samplerZoneSpec("gain"))
        #expect(Self.storedSampler(f.store, f.trackID)?.zones[0].gain == 1)
        #expect(f.model.zoneParamIsUnset("gain") == false)
    }

    // MARK: Sampler — zone list, coverage, and the interior-hole case

    @Test("the zone list renders resolved spans, and a zero-zone sampler is legal, not an error")
    func samplerZoneRowsAndEmptySampler() throws {
        // Zero zones needs NO media service — the documented silent sampler.
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        try store.setInstrument(id: track.id, kind: .sampler, sampler: SamplerParams(zones: []))
        let model = Self.makeSamplerBacked(store)
        model.prepare(trackID: track.id, targetLabel: "on Sampler")
        #expect(model.targetIsSampler)
        #expect(model.zoneCount == 0)
        #expect(model.zoneRows.isEmpty)
        #expect(model.coverage.pitch == nil)
        #expect(model.coverage.velocity == nil)
        #expect(model.coverage.gapCount == 0)
        #expect(model.coverage.pitchLabel == nil)
        #expect(model.coverage.headline == "0 zones")
        // And it is EDITABLE: a global edit on an empty sampler needs no media
        // and must not error.
        model.set(name: "gain", value: 0.4)
        #expect(model.lastErrorMessage == nil)
        #expect(Self.storedSampler(store, track.id)?.gain == 0.4)

        // A populated list resolves nil velocity bounds to the FULL span.
        let zone = Self.samplerZone(Self.ping, root: 60, lo: 48, hi: 72)
        let f = try Self.samplerFixture(SamplerParams(zones: [zone]))
        let row = try #require(f.model.zoneRows.first)
        #expect(row.id == zone.id)
        #expect(row.fileName == "Ping.aiff")
        #expect(row.rootLabel == "C4")
        #expect(row.pitchSpanLabel == "C3–C5")
        #expect(row.minVelocity == 0 && row.maxVelocity == 127)
        #expect(row.velocitySpanLabel == "0–127")
        #expect(row.group == 0)
    }

    @Test("coverage reports an INTERIOR pitch hole a naive min/max would hide")
    func samplerInteriorCoverageGap() throws {
        // Two zone islands: 24–47 and 60–96. A naive envelope says "24–96,
        // covered"; MIDI 48…59 plays nothing.
        let low = Self.samplerZone(Self.ping, root: 36, lo: 24, hi: 47)
        let high = Self.samplerZone(Self.tink, root: 72, lo: 60, hi: 96)
        let f = try Self.samplerFixture(SamplerParams(zones: [low, high]))
        let coverage = f.model.coverage
        #expect(coverage.zoneCount == 2)
        #expect(coverage.pitch?.lowerBound == 24)
        #expect(coverage.pitch?.upperBound == 96)
        #expect(coverage.pitchGapCount == 1)
        #expect(coverage.pitch?.gaps == [SamplerZoneCoverage.Gap(lowerBound: 48, upperBound: 59)])
        #expect(coverage.pitchLabel == "C1–C7")
        // Both zones leave velocity nil, so velocity is solid — folding nil to
        // 0 would invent a hole here.
        #expect(coverage.velocityGapCount == 0)
        #expect(coverage.velocityLabel == "0–127")
        #expect(coverage.headline == "2 zones · C1–C7 · ⚠ 1 pitch gap")
    }

    @Test("the shared DAWCore coverage function merges, reports interior gaps, and treats adjacency as contiguous")
    func samplerZoneCoverageArithmetic() {
        // ONE HOME: this is the function `instrument.describeSampler` reports,
        // reached from the UI layer.
        #expect(SamplerZoneCoverage.coverage(of: []) == nil)
        let touching = SamplerZoneCoverage.coverage(of: [(0, 59), (60, 127)])
        #expect(touching?.gaps.isEmpty == true)
        #expect(touching?.lowerBound == 0 && touching?.upperBound == 127)
        let overlapping = SamplerZoneCoverage.coverage(of: [(60, 90), (0, 70)])
        #expect(overlapping?.lowerBound == 0 && overlapping?.upperBound == 90)
        #expect(overlapping?.gaps.isEmpty == true)
        let holed = SamplerZoneCoverage.coverage(of: [(60, 96), (24, 47)])
        #expect(holed?.gaps == [SamplerZoneCoverage.Gap(lowerBound: 48, upperBound: 59)])
        // Velocity: nil bounds read as the FULL span, never 0.
        let zones = [Self.samplerZone(Self.ping, vLo: nil, vHi: nil)]
        #expect(SamplerZoneCoverage.velocityCoverage(of: zones)?.lowerBound == 0)
        #expect(SamplerZoneCoverage.velocityCoverage(of: zones)?.upperBound == 127)
        // A real velocity hole IS reported.
        let layered = [Self.samplerZone(Self.ping, vLo: 0, vHi: 40),
                       Self.samplerZone(Self.tink, vLo: 80, vHi: 127)]
        #expect(SamplerZoneCoverage.velocityCoverage(of: layered)?.gaps
                == [SamplerZoneCoverage.Gap(lowerBound: 41, upperBound: 79)])
    }

    // MARK: Sampler — VOICE MODE + GLIDE (m34-u, the UI half of m34-t)

    @Test("the voice picker offers every domain case, in declaration order")
    func samplerVoiceModesCoverTheDomain() {
        // ⛔ THE POINT IS COVERAGE, NOT THE LIST. m34-t added `.legato` as a
        // THIRD case; a picker built from a retyped two-or-three-element literal
        // is exactly how a shipped engine feature stays unreachable from the UI,
        // which is the defect m34-u exists to close. Sourcing from
        // `CaseIterable` makes a FOURTH case appear in the picker by
        // construction — and this asserts the order that comes with it, because
        // the card renders the array as it stands.
        #expect(SamplerEditorModel.voiceModes == SamplerVoiceMode.allCases)
        #expect(SamplerEditorModel.voiceModes == [.poly, .mono, .legato])
        #expect(SamplerEditorModel.voiceModes.count == 3,
                "a two-state control cannot express three modes")
    }

    @Test("every voice-mode label is beginner-readable, distinct, and jargon-free")
    func samplerVoiceModeLabelsAreBeginnerReadable() {
        let labels = SamplerEditorModel.voiceModes.map(SamplerEditorModel.voiceModeLabel)
        #expect(labels == ["Chords", "One Note", "Slurred"])
        #expect(Set(labels).count == labels.count, "two segments must never read alike")
        // Rule 6: the wire's own words are correct for an agent and useless on a
        // chip. None of them may leak into the label.
        let jargon = ["poly", "mono", "legato", "portamento", "glide"]
        for label in labels {
            for word in jargon {
                #expect(!label.lowercased().contains(word),
                        "\(label) leaks the wire word '\(word)' onto a human control")
            }
        }
        // The detail text carries the RE-ATTACK distinction the two monophonic
        // labels cannot fit — that difference is the whole reason `.legato`
        // exists, so it must be said somewhere a user can reach.
        let mono = SamplerEditorModel.voiceModeDetail(.mono).lowercased()
        let legato = SamplerEditorModel.voiceModeDetail(.legato).lowercased()
        #expect(mono.contains("fresh") || mono.contains("own attack"))
        #expect(legato.contains("no new") && legato.contains("attack"))
        #expect(SamplerEditorModel.voiceModeDetail(.poly).lowercased().contains("at once"))
    }

    @Test("the voice mode round-trips through the same setInstrument funnel")
    func samplerVoiceModeRoundTrip() throws {
        let zone = Self.samplerZone(Self.ping)
        let f = try Self.samplerFixture(SamplerParams(zones: [zone], gain: 0.5))
        // An untouched sampler lights CHORDS — never nothing. A three-way picker
        // with no lit segment claims a state the engine does not have.
        #expect(Self.storedSampler(f.store, f.trackID)?.voiceMode == nil)
        #expect(f.model.voiceMode == .poly)

        f.model.setVoiceMode(.legato)
        #expect(Self.storedSampler(f.store, f.trackID)?.voiceMode == .legato)
        #expect(f.model.voiceMode == .legato)
        #expect(f.model.lastErrorMessage == nil)

        // Pressing CHORDS stores the EXPLICIT case rather than clearing to nil.
        f.model.setVoiceMode(.poly)
        #expect(Self.storedSampler(f.store, f.trackID)?.voiceMode == .poly)
        #expect(f.model.voiceMode == .poly)

        // The read-modify-write left everything else alone.
        #expect(Self.storedSampler(f.store, f.trackID)?.zones == [zone])
        #expect(Self.storedSampler(f.store, f.trackID)?.gain == 0.5)

        // A WIRE edit under the open card moves the picker — the card reads the
        // live descriptor, never a snapshot taken at open time.
        _ = try f.store.setInstrument(
            id: f.trackID, sampler: SamplerParams(zones: [zone], gain: 0.5, voiceMode: .mono))
        #expect(f.model.voiceMode == .mono)
    }

    @Test("glide round-trips, clamps to the domain, and resets to UNSET not to 0")
    func samplerGlideRoundTrip() throws {
        let zone = Self.samplerZone(Self.ping)
        let f = try Self.samplerFixture(SamplerParams(zones: [zone], gain: 0.5))
        #expect(f.model.glideTime == 0)
        #expect(SamplerEditorModel.glideSpec.range == SamplerParams.glideTimeRange,
                "the spec table must never fork the domain clamp")

        f.model.setGlideTime(0.4)
        #expect(Self.storedSampler(f.store, f.trackID)?.glideTime == 0.4)
        #expect(f.model.glideTime == 0.4)

        // This model's clamp is the ONLY clamp on the sampler path — the store
        // passes a supplied `SamplerParams` through untouched.
        f.model.setGlideTime(99)
        #expect(Self.storedSampler(f.store, f.trackID)?.glideTime
                == SamplerParams.glideTimeRange.upperBound)
        f.model.setGlideTime(-5)
        #expect(Self.storedSampler(f.store, f.trackID)?.glideTime == 0)

        // ⚠️ RESET GOES TO nil, NOT TO AN EXPLICIT 0. Sound-identical, but only
        // nil keeps a project that never asked for glide byte-identical on a
        // JSON round trip and out of describeSampler's only-when-SET output.
        f.model.setGlideTime(1)
        #expect(Self.storedSampler(f.store, f.trackID)?.glideTime == 1)
        f.model.resetGlide()
        #expect(Self.storedSampler(f.store, f.trackID)?.glideTime == nil)
        #expect(f.model.glideTime == 0, "nil still READS as 0 — that is what the engine uses")

        // The knob fraction maps over the domain range, linearly.
        f.model.setGlideFraction(0.5)
        #expect(Self.storedSampler(f.store, f.trackID)?.glideTime == 2)
        #expect(abs(f.model.glideFraction - 0.5) < 1e-9)
    }

    @Test("GLIDE's zero reads OFF, never a very fast glide")
    func samplerGlideZeroReadsOff() {
        // ⛔ THE SINGLE MOST LIKELY WAY TO GET THIS CONTROL WRONG. The card's
        // ordinary seconds formatter renders 0 as "0.0 ms", which reads as a
        // glide that is merely very quick. The bottom of this range is the
        // ABSENCE of glide.
        #expect(SamplerEditorModel.glideReadout(0).text == "OFF")
        #expect(SamplerEditorModel.glideReadout(0).unit == "")
        // Positive control: the formatter it delegates to really would have said
        // that, so the guard above is doing work rather than agreeing by luck.
        #expect(SamplerEditorModel.readout(value: 0, spec: SamplerEditorModel.glideSpec).text
                == "0.0")
        #expect(SamplerEditorModel.readout(value: 0, spec: SamplerEditorModel.glideSpec).unit
                == "ms")
        // Above zero it speaks the card's ordinary ms/s crossover.
        #expect(SamplerEditorModel.glideReadout(0.25).text == "250")
        #expect(SamplerEditorModel.glideReadout(0.25).unit == "ms")
        #expect(SamplerEditorModel.glideReadout(2).text == "2.00")
        #expect(SamplerEditorModel.glideReadout(2).unit == "s")
    }

    @Test("the honest light: a glide stored under CHORDS reads inert, and only then")
    func samplerGlideInertUnderPoly() throws {
        let zone = Self.samplerZone(Self.ping)
        let f = try Self.samplerFixture(SamplerParams(zones: [zone]))

        // (a) No glide, chords — the DEFAULT. Not a warning state: lighting one
        // on the default would teach nothing.
        #expect(f.model.glideIsInert == false)
        #expect(f.model.glideIsEffective == false)

        // (b) A glide set while the sampler plays chords is STRUCTURALLY inert —
        // the engine resolves it away at the ScalarParams boundary — and this is
        // the state the card must show rather than draw a live-looking knob.
        f.model.setGlideTime(0.3)
        #expect(f.model.glideIsInert)
        #expect(f.model.glideIsEffective == false)

        // (c) Both monophonic modes make it live. `.mono` too, not just
        // `.legato`: the slide happens either way, the difference is the attack.
        for mode in [SamplerVoiceMode.mono, .legato] {
            f.model.setVoiceMode(mode)
            #expect(f.model.glideIsEffective, "\(mode) must make a stored glide live")
            #expect(f.model.glideIsInert == false)
        }

        // (d) Switching back to chords re-lights the warning.
        f.model.setVoiceMode(.poly)
        #expect(f.model.glideIsInert)

        // (e) The card's verdict is the DOMAIN's, never a local re-derivation —
        // so it cannot disagree with the `glideEffective` key
        // `instrument.describeSampler` publishes to an agent.
        let stored = try #require(Self.storedSampler(f.store, f.trackID))
        #expect(f.model.glideIsEffective == stored.glideIsEffective)
    }

    @Test("the inert-glide note speaks to a human, not to an agent")
    func samplerGlideInertNoteIsBeginnerReadable() {
        let note = SamplerEditorModel.glideInertNote
        // Rule 6: the person reading this card has never seen "poly"; they have
        // seen the three chips. The note must name what they can see.
        #expect(note.contains("CHORDS"))
        #expect(note.contains("One Note") && note.contains("Slurred"))
        for word in ["poly", "mono", "legato", "voiceMode"] {
            #expect(!note.contains(word),
                    "the note leaks the wire word '\(word)' at a human")
        }
        // It says what is wrong AND what to do — a warning that only names the
        // fault leaves the repair to guesswork.
        #expect(note.lowercased().contains("ignores"),
                "the note must name the FAULT, not merely the repair")
        #expect(note.lowercased().contains("use "),
                "a warning that names only the fault leaves the repair to guesswork")
        // ⚠️ It must stay SHORT enough to draw on ONE line: it lives in the
        // card's fixed chrome, so a second line costs a zone row off the list —
        // measured in pixels, twice, before the number settled (see
        // `glideInertNote`'s own doc). 51 is what the card's width actually
        // fits at 9 pt beside the warning glyph.
        #expect(note.count <= 51, "\(note.count) chars will wrap and cost a zone row")
    }

    @Test("voice mode and glide obey the same honest gates as every other global")
    func samplerVoiceAndGlideRefuseOnAWrongKind() throws {
        let store = ProjectStore()
        store.media = SamplerStubMedia()
        let track = store.addTrack(kind: .instrument)
        let model = Self.makeSamplerBacked(store)
        model.prepare(trackID: track.id, targetLabel: "on Synth")
        #expect(model.targetIsSampler == false)

        // A poly-synth track: both edits refuse loudly and write nothing. An
        // edit that appears to work and changes nothing audible is this
        // codebase's characteristic failure mode.
        model.setVoiceMode(.legato)
        #expect(model.lastErrorMessage != nil)
        #expect(store.tracks.first { $0.id == track.id }?.instrument?.sampler == nil)
        // `select(zoneID:)` clears the inline error — the card's own reset — so
        // the second edit is proven to raise its OWN refusal rather than
        // inheriting the first one's.
        model.select(zoneID: nil)
        #expect(model.lastErrorMessage == nil)
        model.setGlideTime(1)
        #expect(model.lastErrorMessage != nil)
        #expect(store.tracks.first { $0.id == track.id }?.instrument?.sampler == nil)
    }

    // MARK: Sampler — loop fields (m20-g), the ones that make a note sustain

    @Test("the loop mode, start and end round-trip through the same setInstrument funnel")
    func samplerLoopRoundTrip() throws {
        let zone = Self.samplerZone(Self.ping)
        let f = try Self.samplerFixture(SamplerParams(zones: [zone]))
        f.model.select(zoneID: zone.id)
        #expect(f.model.selectedZoneLoopMode == nil)

        f.model.setLoopMode(.continuous)
        #expect(Self.storedSampler(f.store, f.trackID)?.zones[0].loopMode == .continuous)
        #expect(f.model.selectedZoneLoopMode == .continuous)
        #expect(f.model.zoneRows[0].loopMode == .continuous)

        f.model.setLoopStart(1_000)
        f.model.setLoopEnd(40_000)
        #expect(f.model.selectedZoneLoopStart == 1_000)
        #expect(f.model.selectedZoneLoopEnd == 40_000)

        f.model.setLoopMode(nil)
        #expect(Self.storedSampler(f.store, f.trackID)?.zones[0].loopMode == nil)
        // Turning the loop OFF leaves the points alone, so turning it back on
        // does not lose them.
        #expect(Self.storedSampler(f.store, f.trackID)?.zones[0].loopStart == 1_000)
        #expect(SamplerEditorModel.loopModes == [nil, .sustain, .continuous])
        #expect(SamplerEditorModel.loopModeLabel(nil) == "No Loop")
    }

    @Test("the loop span clamps exactly as SamplerZone's own initialiser does — RAISED, never swapped")
    func samplerLoopClampMatchesTheDomain() throws {
        let zone = Self.samplerZone(Self.ping)
        let f = try Self.samplerFixture(SamplerParams(zones: [zone]))
        f.model.select(zoneID: zone.id)

        // A negative start floors at 0 — pinned against the domain initialiser
        // rather than against a restated rule, so the UI cannot drift from the
        // wire (which reaches this law the same way).
        f.model.setLoopStart(-50)
        f.model.setLoopEnd(10)
        var reference = SamplerZone(audioFileURL: Self.ping, loopStart: -50, loopEnd: 10)
        #expect(f.model.selectedZoneLoopStart == reference.loopStart)
        #expect(f.model.selectedZoneLoopEnd == reference.loopEnd)

        // A start that passes the end RAISES the end to start + 1; a swap would
        // silently invert the user's skip-vs-stop intent.
        f.model.setLoopStart(100)
        reference = SamplerZone(audioFileURL: Self.ping, loopStart: 100, loopEnd: 10)
        #expect(f.model.selectedZoneLoopStart == 100)
        #expect(f.model.selectedZoneLoopEnd == reference.loopEnd)
        #expect(f.model.selectedZoneLoopEnd == 101)
    }

    @Test("LOOP MODE WINS OVER ONE SHOT — a looping zone is never one-shot, whatever the global says")
    func samplerLoopBeatsOneShot() throws {
        let looping = Self.samplerZone(Self.ping, lo: 0, hi: 63, loop: .continuous)
        let plain = Self.samplerZone(Self.tink, lo: 64, hi: 127)
        let f = try Self.samplerFixture(
            SamplerParams(zones: [looping, plain], oneShot: true))
        #expect(f.model.oneShot)

        // The engine forces the non-one-shot override on a looping voice
        // (SamplerInstrument.swift:826-828), beating BOTH the per-zone override
        // and the live global.
        #expect(SamplerEditorModel.effectiveOneShot(zone: looping, globalOneShot: true) == false)
        #expect(SamplerEditorModel.effectiveOneShot(zone: plain, globalOneShot: true) == true)
        // A per-zone override still decides for a NON-looping zone.
        var overridden = plain
        overridden.oneShot = false
        #expect(SamplerEditorModel.effectiveOneShot(zone: overridden, globalOneShot: true) == false)
        // ...and is itself beaten by a loop.
        var loopingButOneShot = looping
        loopingButOneShot.oneShot = true
        #expect(SamplerEditorModel.effectiveOneShot(zone: loopingButOneShot,
                                                    globalOneShot: false) == false)

        // The card's inline explanation fires exactly when the toggle is lit and
        // the selected zone ignores it — so an ineffective toggle is never silent.
        f.model.select(zoneID: looping.id)
        #expect(f.model.selectedZoneIsOneShot == false)
        #expect(f.model.selectedZoneLoopOverridesOneShot)
        f.model.select(zoneID: plain.id)
        #expect(f.model.selectedZoneIsOneShot == true)
        #expect(f.model.selectedZoneLoopOverridesOneShot == false)
    }

    // MARK: Sampler — honest gates (vanished zone / wrong kind / closed)

    @Test("a zone that vanished under the open card drops the selection and writes nothing")
    func samplerVanishedZone() throws {
        let z1 = Self.samplerZone(Self.ping, root: 60)
        let z2 = Self.samplerZone(Self.tink, root: 48)
        let f = try Self.samplerFixture(SamplerParams(zones: [z1, z2], gain: 0.5))
        f.model.select(zoneID: z2.id)
        #expect(f.model.selectedZone?.id == z2.id)

        // The wire replaces the zone map wholesale; z2 is gone.
        let z3 = Self.samplerZone(Self.glass, root: 72)
        _ = try f.store.setInstrument(id: f.trackID, sampler: SamplerParams(zones: [z1, z3],
                                                                           gain: 0.5))
        #expect(f.model.selectedZone == nil, "a vanished zone must never read as selected")
        #expect(f.model.selectedZoneRow == nil)

        f.model.setZoneParam(name: "tuneCents", value: 50)
        #expect(f.model.selectedZoneID == nil, "the stale selection is dropped")
        #expect(f.model.lastErrorMessage != nil, "and the drop is stated, not silent")
        let stored = try #require(Self.storedSampler(f.store, f.trackID))
        #expect(stored.zones == [z1, z3], "nothing was written")
        // With nothing selected, a per-zone edit is a plain no-op.
        f.model.setZoneParam(name: "pan", value: 1)
        #expect(Self.storedSampler(f.store, f.trackID)?.zones == [z1, z3])
    }

    @Test("a track that is not a sampler refuses honestly and writes nothing")
    func samplerWrongKindRefuses() throws {
        // (a) An instrument track playing the POLY SYNTH: the gate drops and the
        // refusal is stated. Writing sampler settings onto a track that will not
        // use them is the silent-plausible failure this refuses to commit.
        let store = ProjectStore()
        store.media = SamplerStubMedia()
        let track = store.addTrack(kind: .instrument)
        let model = Self.makeSamplerBacked(store)
        model.prepare(trackID: track.id, targetLabel: "on Synth")
        #expect(model.targetIsSampler == false)
        model.set(name: "gain", value: 0.2)
        #expect(model.lastErrorMessage != nil)
        #expect(store.tracks.first { $0.id == track.id }?.instrument?.sampler == nil)

        // (b) A kind swap MID-OPEN drops the gate the same way.
        try store.setInstrument(id: track.id, kind: .sampler, sampler: SamplerParams(zones: []))
        #expect(model.targetIsSampler)
        try store.setInstrument(id: track.id, kind: .polySynth)
        #expect(model.targetIsSampler == false)

        // (c) A non-instrument track surfaces the STORE's teaching refusal,
        // not one this model invented.
        let audio = store.addTrack(kind: .audio)
        let audioModel = Self.makeSamplerBacked(store)
        audioModel.prepare(trackID: audio.id, targetLabel: "on Audio")
        #expect(audioModel.targetIsSampler == false)
        audioModel.set(name: "gain", value: 0.5)
        #expect(audioModel.lastErrorMessage != nil)

        // (d) Closed / never-existing target: honest nothing, defaults, no crash.
        let idle = Self.makeSamplerBacked(store)
        #expect(idle.descriptor == nil)
        #expect(idle.targetIsSampler == false)
        #expect(idle.zoneCount == 0)
        idle.prepare(trackID: UUID(), targetLabel: "on Ghost")
        #expect(idle.value(for: Self.samplerSpec("gain")) == SamplerParams().gain)
        idle.clear()
        #expect(idle.trackID == nil)
        #expect(idle.selectedZoneID == nil)
    }

    @Test("a sampler whose sample file has vanished is READ-ONLY, and a refused edit changes nothing")
    func samplerMissingFileMakesEveryEditFail() throws {
        // setInstrument validates EVERY zone file before committing, so one
        // moved sample locks the whole instrument — including its globals.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sampler-editor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let temp = dir.appendingPathComponent("zone.aiff")
        try Data(contentsOf: Self.ping).write(to: temp)
        defer { try? FileManager.default.removeItem(at: dir) }

        let zone = Self.samplerZone(temp)
        let f = try Self.samplerFixture(SamplerParams(zones: [zone], gain: 0.5))
        try FileManager.default.removeItem(at: temp)

        f.model.set(name: "gain", value: 0.9)
        #expect(f.model.lastErrorMessage != nil,
                "the store's refusal must surface — this state is reachable, not theoretical")
        let stored = try #require(Self.storedSampler(f.store, f.trackID))
        #expect(stored.gain == 0.5, "a refused edit writes NOTHING, not a partial update")
        #expect(stored.zones == [zone])
    }

    // MARK: Sampler — knob geometry and readouts

    @Test("sampler knob travel is linear, bipolar only where the range straddles zero")
    func samplerKnobGeometry() {
        for spec in SamplerEditorModel.specs + SamplerEditorModel.zoneSpecs {
            for f in [0.0, 0.25, 0.5, 0.75, 1.0] {
                let value = SamplerEditorModel.value(forFraction: f, spec: spec)
                #expect(spec.range.contains(value), "\(spec.name) value at f=\(f)")
                let back = SamplerEditorModel.fraction(forValue: value, spec: spec)
                #expect(abs(back - f) < 1e-9, "\(spec.name) round-trip at f=\(f)")
            }
        }
        #expect(SamplerEditorModel.isBipolar(Self.samplerZoneSpec("tuneCents")))
        #expect(SamplerEditorModel.isBipolar(Self.samplerZoneSpec("pan")))
        #expect(SamplerEditorModel.isBipolar(Self.samplerZoneSpec("gain")) == false)
        #expect(SamplerEditorModel.isBipolar(Self.samplerSpec("attack")) == false)
        // A bipolar range's centre sits at half travel.
        #expect(SamplerEditorModel.value(forFraction: 0.5,
                                         spec: Self.samplerZoneSpec("pan")) == 0)
    }

    @Test("sampler readouts: ms↔s ramps, dB gains, signed cents, L/C/R pan, % levels")
    func samplerReadouts() {
        let attack = Self.samplerSpec("attack")
        #expect(SamplerEditorModel.readout(value: 0.001, spec: attack) == ("1.0", "ms"))
        #expect(SamplerEditorModel.readout(value: 0.05, spec: attack) == ("50", "ms"))
        #expect(SamplerEditorModel.readout(value: 1.0, spec: attack) == ("1.00", "s"))

        let gain = Self.samplerSpec("gain")
        #expect(SamplerEditorModel.readout(value: 1.0, spec: gain) == ("0.0", "dB"))
        #expect(SamplerEditorModel.readout(value: 0.0, spec: gain) == ("-∞", "dB"))
        // The per-zone gain shares the dB treatment across its wider range.
        #expect(SamplerEditorModel.readout(value: 2.0, spec: Self.samplerZoneSpec("gain"))
                == ("6.0", "dB"))

        let tune = Self.samplerZoneSpec("tuneCents")
        #expect(SamplerEditorModel.readout(value: 50, spec: tune) == ("+50", "cents"))
        #expect(SamplerEditorModel.readout(value: -50, spec: tune) == ("-50", "cents"))
        #expect(SamplerEditorModel.readout(value: 0, spec: tune) == ("0", "cents"))

        let pan = Self.samplerZoneSpec("pan")
        #expect(SamplerEditorModel.readout(value: 0, spec: pan) == ("C", ""))
        #expect(SamplerEditorModel.readout(value: -0.5, spec: pan) == ("50", "L"))
        #expect(SamplerEditorModel.readout(value: 0.75, spec: pan) == ("75", "R"))

        #expect(SamplerEditorModel.readout(value: 0.7, spec: Self.samplerZoneSpec("sustain"))
                == ("70", "%"))

        // Only the gains earn the level accent.
        for spec in SamplerEditorModel.specs + SamplerEditorModel.zoneSpecs {
            #expect(SamplerEditorModel.isLevelParam(spec) == (spec.name == "gain"), "\(spec.name)")
        }
    }

    @Test("a sampler knob drag never lands one undo step per tick (the store's per-track coalescing)")
    func samplerDragCoalesces() throws {
        let zone = Self.samplerZone(Self.ping)
        let f = try Self.samplerFixture(SamplerParams(zones: [zone], gain: 0.8))
        let before = f.store.undoHistory().undo.count
        for step in 1...20 {
            f.model.set(name: "gain", value: Double(step) / 25.0)
        }
        let after = f.store.undoHistory().undo.count
        // ⚠️ The bound is `+ 1`, not `== + 1`, and the reason is worth stating:
        // every edit here coalesces under "track.instrument:<id>", and the
        // FIXTURE's own `setInstrument` carries that same key — so a drag that
        // starts inside the coalescing window folds into the fixture's entry
        // and adds ZERO. Either outcome proves the property that matters; only
        // "one entry per tick" would falsify it. (The poly-synth twin above can
        // assert `== + 1` because a fresh instrument track has no prior
        // instrument edit to fold into.)
        #expect(after <= before + 1,
                "20 ticks produced \(after - before) undo entries — a drag must coalesce")
        #expect(f.model.value(for: Self.samplerSpec("gain")) == 20.0 / 25.0)
    }

    /// Counts trips through the apply injector — the seam the card's commit
    /// cadence is defined against.
    private final class SamplerApplyCounter {
        var count = 0
    }

    @Test("every sampler model call is EXACTLY ONE apply — why the card commits on release, not per frame")
    func samplerAppliesOncePerCall() throws {
        // ⛔ THIS IS THE COUNTERPART TO A VIEW RULE, AND IT IS THE HALF A TEST
        // CAN REACH. `SamplerEditorOverlay` drives its knobs through
        // `DeferredKnob`, which holds an optimistic LOCAL value while the drag
        // is live and calls the model exactly ONCE, on release. That deferral
        // is only worth anything if the model itself is one-apply-per-call —
        // if a single `set` fanned out into several writes, deferring the
        // gesture would fix nothing. This pins that half.
        //
        // Undo coalescing (the test above) CANNOT see this: 20 ticks fold into
        // one undo entry either way, which is exactly how a per-frame cadence
        // hides. The cost being avoided is not undo pollution — it is that
        // EVERY apply re-validates the whole zone list (`ProjectStore.swift`'s
        // `if let sampler { try validateSamplerZones(...) }` — a `fileExists`
        // plus a media open PER ZONE, on the main actor) and flips
        // `instrumentNodeIdentityChanged` for any per-zone scalar, which can
        // force an engine rebuild. Both are invisible to an undo counter.
        let store = ProjectStore()
        store.media = SamplerStubMedia()
        let track = store.addTrack(kind: .instrument)
        let zone = Self.samplerZone(Self.ping)
        try store.setInstrument(id: track.id, kind: .sampler,
                                sampler: SamplerParams(zones: [zone]))

        let counter = SamplerApplyCounter()
        let model = SamplerEditorModel(
            descriptor: { trackID in
                guard let track = store.tracks.first(where: { $0.id == trackID }),
                      track.kind == .instrument else { return nil }
                return track.instrument ?? .default
            },
            applySampler: { trackID, params in
                counter.count += 1
                _ = try store.setInstrument(id: trackID, sampler: params)
            })
        model.prepare(trackID: track.id, targetLabel: "on \(track.name)")
        model.select(zoneID: zone.id)

        // Every edit shape the card offers: one call, one apply.
        let edits: [(String, () -> Void)] = [
            ("global set", { model.set(name: "release", value: 0.4) }),
            ("one shot", { model.setOneShot(true) }),
            ("global reset", { model.resetToDefault(Self.samplerSpec("attack")) }),
            ("zone set", { model.setZoneParam(name: "tuneCents", value: 25) }),
            ("zone reset", { model.resetZoneParam(Self.samplerZoneSpec("pan")) }),
            ("loop mode", { model.setLoopMode(.sustain) }),
        ]
        for (label, edit) in edits {
            counter.count = 0
            edit()
            #expect(counter.count == 1, "\(label) made \(counter.count) applies, expected 1")
        }

        // An unknown field name must not reach the store at all — the guard in
        // front of the funnel, positive-controlled by the six above (a probe
        // that can only ever return 0 proves nothing).
        counter.count = 0
        model.set(name: "notAParam", value: 1)
        model.setZoneParam(name: "notAZoneParam", value: 1)
        #expect(counter.count == 0, "an unknown field name must never write")

        // ⭐ AND THE NUMBER THAT MOTIVATES THE VIEW DESIGN: the model applies
        // per CALL, so a knob wired at drag cadence would apply per FRAME. At
        // 60 fps on the user's 46-zone saxophone that is ~2,760 file opens a
        // second on the main actor, and ~18,540 on a 309-zone library. The
        // model is right to be simple here; the VIEW is where the cadence is
        // chosen, and it chooses release.
        counter.count = 0
        for step in 1...60 {
            model.setZoneFraction(Double(step) / 60.0, for: Self.samplerZoneSpec("gain"))
        }
        #expect(counter.count == 60,
                "the model applies once per call — a per-frame view cadence pays this 60 times")
    }

    @Test("a zero-distance drag returns the START fraction — the premise the knob's click guard rests on")
    func knobClickGuardPremise() {
        // ⛔ WHAT THIS PROTECTS. `KnobControl` commits to `onCommit` only when a
        // drag actually MOVED the value (`if next != start { … }`), because its
        // gesture is `DragGesture(minimumDistance: 0)` — so a plain CLICK is a
        // complete drag sequence with zero translation and a double-click reset
        // is two of them, and an ungated commit would make every stray click on
        // a sampler knob re-open every sample file in the library.
        //
        // That guard is a comparison against `MixerMath.adjustedFraction`, and
        // it has TWO ways to be wrong, only one of which is loud:
        //   · too eager  → a click commits (slow, but visible/attributable);
        //   · too shy    → the latch never fires and the knob is SILENTLY INERT
        //                  — the cap moves, the readout moves, nothing is
        //                  written. A screenshot looks perfect and every other
        //                  test on this card still passes.
        // The second is this tree's characteristic failure mode, and neither
        // the model-side apply count above nor a grep of the view can see it.
        // The gesture closure itself lives in the untestable app target; its
        // PREMISE does not, so the premise is pinned here.
        let throwPoints = 120.0   // the knob's own travel, verbatim

        // A click: zero translation must land EXACTLY on the start fraction, so
        // `next != start` is false and nothing commits.
        #expect(MixerMath.adjustedFraction(start: 0.5, dragPoints: 0,
                                           throwPoints: throwPoints) == 0.5)

        // A real drag must NOT land on the start fraction, or the guard would
        // swallow every commit and the knob would be inert. Both directions.
        #expect(MixerMath.adjustedFraction(start: 0.5, dragPoints: 12,
                                           throwPoints: throwPoints) != 0.5)
        #expect(MixerMath.adjustedFraction(start: 0.5, dragPoints: -12,
                                           throwPoints: throwPoints) != 0.5)

        // At a rail, dragging FURTHER into the rail is genuinely no change — so
        // not committing there is correct rather than a missed edit. (Pinned so
        // a future reader does not "fix" it into an unconditional commit.)
        #expect(MixerMath.adjustedFraction(start: 1.0, dragPoints: 30,
                                           throwPoints: throwPoints) == 1.0)
        #expect(MixerMath.adjustedFraction(start: 0.0, dragPoints: -30,
                                           throwPoints: throwPoints) == 0.0)
        // …but dragging OFF a rail does change, and must commit.
        #expect(MixerMath.adjustedFraction(start: 1.0, dragPoints: -30,
                                           throwPoints: throwPoints) != 1.0)
    }

    // MARK: - SamplerCardLayout (the collapsed-zone-list regression)

    /// The window heights that matter: the app's default and its floor.
    private static let defaultWindowHeight: CGFloat = 900
    private static let floorWindowHeight: CGFloat = 640

    @Test("REGRESSION: opening the per-zone inspector must not collapse the zone list")
    func zoneListSurvivesTheInspector() {
        // ⛔ THE DEFECT, MEASURED IN PIXELS ON STAGING 2026-08-18: with a zone
        // selected the list showed ONE full row plus a sliced second — ~1.7
        // rows — and the third zone was not visible at all. It was IDENTICAL at
        // 3 zones and at 46, because the collapse was driven by the card's
        // fixed height ceiling and not by the library: the ceiling was smaller
        // than the card's own content once the inspector opened, and a
        // `ScrollView` is the child a `VStack` compresses first, so the list
        // absorbed the entire shortfall. The card measured ~615 pt inside a
        // ~900 pt window — it was never the display that was short.
        //
        // ⭐ EVERY HEADLESS CHECK IN THE ORIGINAL ROUND STAYED GREEN THROUGH
        // ALL OF THAT. This is the pin that would not have.
        let rows46 = 46      // the user's real saxophone library
        for rowCount in [rows46, 309, 8] {
            let height = SamplerCardLayout.zoneListHeight(
                rowCount: rowCount, inspectorOpen: true,
                availableHeight: Self.defaultWindowHeight)
            let visible = SamplerCardLayout.visibleRows(inHeight: height)
            #expect(visible >= 6,
                    "\(rowCount) zones: inspector open shows \(visible) rows, need ≥ 6")
            // ⭐ m34-u MOVED THIS NUMBER, AND THE MOVE IS THE POINT OF THE
            // ASSERTION. Until m34-u the 8-row CAP bound at the default window;
            // the VOICE chip row plus the stored-but-inert GLIDE warning spend
            // ~71 pt of chrome, so the BUDGET now binds first and the list draws
            // 6. Pinned as a BAND, not as the cap: the cap is an upper bound the
            // budget may legitimately sit under, and asserting equality with it
            // would redden on every honest chrome change while saying nothing
            // about the defect. What must never happen again is the slide toward
            // ~1.7, and 6 is 3.5× that.
            #expect(visible <= SamplerCardLayout.maxRowsWithInspector,
                    "\(rowCount) zones: \(visible) rows exceeds the \(SamplerCardLayout.maxRowsWithInspector)-row cap")
        }

        // The state that was already fine must stay fine.
        let noSelection = SamplerCardLayout.zoneListHeight(
            rowCount: rows46, inspectorOpen: false,
            availableHeight: Self.defaultWindowHeight)
        #expect(SamplerCardLayout.visibleRows(inHeight: noSelection)
                == SamplerCardLayout.maxRowsWithoutInspector)

        // A SHORT window may show fewer rows, but never fewer than the floor —
        // that is the whole difference between "degrades" and "collapses".
        for windowHeight in [Self.floorWindowHeight, 560, 480] as [CGFloat] {
            let height = SamplerCardLayout.zoneListHeight(
                rowCount: rows46, inspectorOpen: true, availableHeight: windowHeight)
            let visible = SamplerCardLayout.visibleRows(inHeight: height)
            #expect(visible >= SamplerCardLayout.minVisibleRows,
                    "window \(windowHeight): list fell to \(visible) rows, floor is \(SamplerCardLayout.minVisibleRows)")
        }

        // Negative control: the floor is not satisfied by a constant — a list
        // with FEWER rows than the floor draws only the rows it has, never a
        // padded-out empty well.
        let three = SamplerCardLayout.zoneListHeight(
            rowCount: 3, inspectorOpen: true, availableHeight: Self.defaultWindowHeight)
        #expect(SamplerCardLayout.visibleRows(inHeight: three) == 3,
                "a 3-zone library must draw 3 rows, not a padded well")
        #expect(SamplerCardLayout.zoneListHeight(
            rowCount: 0, inspectorOpen: false,
            availableHeight: Self.defaultWindowHeight) == 0)
    }

    @Test("the card is window-responsive and never outgrows the room it was given")
    func cardStaysInsideItsWindow() {
        // The card's real height is chrome + list + whatever the inspector
        // hugs, and the inspector is capped at `inspectorRoom` — so this sum is
        // the tightest statement of "it fits" available without pixels.
        for windowHeight in [420, 480, 560, 640, 800, 900, 1200, 1800] as [CGFloat] {
            for inspectorOpen in [true, false] {
                let ceiling = SamplerCardLayout.cardCeiling(availableHeight: windowHeight)
                let list = SamplerCardLayout.zoneListHeight(
                    rowCount: 46, inspectorOpen: inspectorOpen, availableHeight: windowHeight)
                let room = SamplerCardLayout.inspectorRoom(
                    rowCount: 46, inspectorOpen: inspectorOpen, availableHeight: windowHeight)
                let content = inspectorOpen ? SamplerCardLayout.inspectorOpenHeight
                                            : SamplerCardLayout.inspectorClosedHeight
                let cardHeight = SamplerCardLayout.chromeHeight + list + min(content, room)
                #expect(cardHeight <= ceiling + 0.5,
                        "window \(windowHeight) open=\(inspectorOpen): card \(cardHeight) exceeds ceiling \(ceiling)")
                #expect(room >= 0)
            }
        }

        // Responsive in the direction that failed: a TALLER window must buy a
        // taller card, not leave ~280 pt of the window empty under a constant.
        #expect(SamplerCardLayout.cardCeiling(availableHeight: 900)
                > SamplerCardLayout.cardCeiling(availableHeight: 640))
        // …but not without limit, and never below its own floor.
        #expect(SamplerCardLayout.cardCeiling(availableHeight: 4000)
                == SamplerCardLayout.maxCardHeight)
        #expect(SamplerCardLayout.cardCeiling(availableHeight: 100)
                == SamplerCardLayout.minCardHeight)
        // The floor is DERIVED, not picked: it is exactly the chrome plus the
        // zone list's own row floor. A picked constant (it was 320) let the row
        // floor outrank the ceiling and overflow a small window — caught by the
        // loop above, so this pins the relationship that fixed it.
        #expect(SamplerCardLayout.minCardHeight
                == SamplerCardLayout.chromeHeight
                   + SamplerCardLayout.height(rows: SamplerCardLayout.minVisibleRows))
    }

    @Test("row height and visible-row count are exact inverses (a sliced row is not a row)")
    func rowArithmeticRoundTrips() {
        for rows in 0...20 {
            #expect(SamplerCardLayout.visibleRows(
                inHeight: SamplerCardLayout.height(rows: rows)) == rows)
        }
        // A viewport one point short of the next row shows the LOWER count —
        // the defect was reported as "one full row plus a sliced second", and a
        // counter that rounded up would have called that two.
        let three = SamplerCardLayout.height(rows: 3)
        #expect(SamplerCardLayout.visibleRows(inHeight: three + SamplerCardLayout.rowHeight - 1) == 3)
        #expect(SamplerCardLayout.visibleRows(inHeight: 0) == 0)
        #expect(SamplerCardLayout.visibleRows(inHeight: -40) == 0)
    }
}
