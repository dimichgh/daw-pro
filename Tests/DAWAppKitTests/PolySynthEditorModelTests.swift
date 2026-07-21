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
}
