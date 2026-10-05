import Foundation
import Testing
@testable import DAWCore

// m39-tpl-5 — `TemplateCapture` and the round trip of design §8.3
// (docs/design/2026-09-27-multi-instrument-templates.md §4.6, §5.7, §8.3).
// NO `@MainActor`: capture, the canonical form and the JSON writer are pure.
//
// The round trip is asserted in TWO INDEPENDENT HALVES, because a defect in a
// helper both sides share cannot be seen by comparing them with each other:
//   (a) `canonical(capture(apply(T))) == canonical(T)` — the design's statement;
//   (b) every READING of the band rebuilt from the capture equals the reading of
//       the band built from T: every effect setting through `paramValue`, the
//       active instrument whole, volume, pan, and every routing edge by position.
// Plus (c): the canonical JSON reads back, through the real codec, as exactly the
// canonical template.

/// SplitMix64 — deterministic, so a failing sample is reproducible from its seed.
struct TPL5RNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// What a band SOUNDS like, by position, with every id replaced by an index:
/// half (b) of the round trip compares two of these.
struct TPL5BandReading: Equatable, CustomStringConvertible {
    enum Instrument: Equatable {
        case none
        case testTone
        case polySynth(PolySynthParams)
        case drumSynth(DrumKitParams)
        case soundBank(source: String, program: Int, bankMSB: Int, bankLSB: Int)
        /// m39-tpl-5b: the globals (zones emptied, provenance names cleared) and
        /// each zone as `zoneReading` sees it — every field by `Mirror`, its
        /// FILE by path, its id left out: a zone's identity is not its sound,
        /// and since TPL-5b every apply gives zones new ids.
        case sampler(SamplerParams, zones: [[String]])
        case audioUnit(AudioUnitComponentID?, Data?)
    }

    /// One zone's reading, independent of the code under test: every stored
    /// field by `Mirror` (a field added tomorrow is read too), except `id`, with
    /// `audioFileURL` read as its path.
    static func zoneReading(_ zone: SamplerZone) -> [String] {
        Mirror(reflecting: zone).children.compactMap { child -> String? in
            guard let label = child.label, label != "id" else { return nil }
            if label == "audioFileURL" { return "file=\(zone.audioFileURL.path)" }
            return "\(label)=\(child.value)"
        }
    }
    struct Effect: Equatable {
        var kind: String
        var bypassed: Bool
        var values: [String: Double]
        var sidechainSource: Int?
        var unit: AudioUnitComponentID?
        var state: Data?
    }
    struct Route: Equatable {
        var source: Int
        var target: String
        var depth: Double
        var enabled: Bool
    }
    struct Strip: Equatable {
        var name: String
        var kind: TrackKind
        var volume: Double
        var pan: Double
        var instrument: Instrument
        var effects: [Effect]
        var output: Int?
        var sends: [[Double]]
        var sources: [String]
        var routes: [Route]
    }
    var strips: [Strip]

    init(_ tracks: [Track]) {
        let index = Dictionary(tracks.enumerated().map { ($0.element.id, $0.offset) },
                               uniquingKeysWith: { first, _ in first })
        strips = tracks.map { track in
            var instrument = Instrument.none
            if track.kind == .instrument {
                let descriptor = track.instrument ?? .default
                switch descriptor.kind {
                case .testTone: instrument = .testTone
                case .polySynth: instrument = .polySynth(descriptor.polySynth)
                case .drumSynth: instrument = .drumSynth(descriptor.resolvedDrumKit)
                case .soundBank:
                    let bank = descriptor.soundBank
                    instrument = .soundBank(source: bank?.source.rawString ?? "-",
                                            program: bank?.program ?? -1,
                                            bankMSB: bank?.bankMSB ?? -1, bankLSB: bank?.bankLSB ?? -1)
                case .sampler:
                    var sampler = descriptor.resolvedSampler
                    sampler.sourcePath = nil
                    sampler.displayName = nil
                    let zones = sampler.zones.map(Self.zoneReading)
                    sampler.zones = []
                    instrument = .sampler(sampler, zones: zones)
                case .audioUnit:
                    instrument = .audioUnit(descriptor.audioUnit?.component,
                                            descriptor.audioUnit?.stateData)
                }
            }
            let effects = track.effects.map { effect in
                var values: [String: Double] = [:]
                for spec in EffectParamSpec.specs(for: effect.kind) {
                    values[spec.name] = effect.paramValue(spec.name)
                }
                return Effect(kind: effect.kind.rawValue, bypassed: effect.isBypassed,
                              values: values,
                              sidechainSource: effect.sidechainSourceTrackID.flatMap { index[$0] },
                              unit: effect.audioUnit?.component, state: effect.audioUnit?.stateData)
            }
            let sourceIndex = Dictionary(track.modulationSources.enumerated().map {
                ($0.element.id, $0.offset)
            }, uniquingKeysWith: { first, _ in first })
            let routes = track.modulationRoutes.map { route -> Route in
                let target: String
                switch route.target {
                case .volume: target = "volume"
                case .pan: target = "pan"
                case .sendLevel: target = "sendLevel"
                case .instrumentParam(let param): target = "instrument.\(param)"
                case .effectParam(let effectID, let param):
                    let position = track.effects.firstIndex { $0.id == effectID } ?? -1
                    target = "effect[\(position)].\(param)"
                }
                return Route(source: sourceIndex[route.sourceID] ?? -1, target: target,
                             depth: route.depth, enabled: route.enabled)
            }
            return Strip(name: track.name, kind: track.kind, volume: track.volume, pan: track.pan,
                         instrument: instrument, effects: effects,
                         output: track.outputBusID.flatMap { index[$0] },
                         sends: track.sends.map { [Double(index[$0.destinationBusID] ?? -1), $0.level] },
                         sources: track.modulationSources.map {
                             "\($0.kind.rawValue)|\($0.name)|\($0.params)"
                         },
                         routes: routes)
        }
    }

    var description: String { "\(strips.count) strips" }

    /// The first difference, in words, for a failure message.
    func firstDifference(from other: TPL5BandReading) -> String {
        guard strips.count == other.strips.count else {
            return "strip count \(strips.count) vs \(other.strips.count)"
        }
        for (index, (a, b)) in zip(strips, other.strips).enumerated() where a != b {
            if a.instrument != b.instrument { return "strip \(index) instrument: \(a.instrument) vs \(b.instrument)" }
            if a.effects != b.effects {
                for (j, (x, y)) in zip(a.effects, b.effects).enumerated() where x != y {
                    let names = Set(x.values.keys).union(y.values.keys).sorted()
                        .filter { x.values[$0] != y.values[$0] }
                    return "strip \(index) effect \(j) \(x.kind): \(names.map { "\($0) \(x.values[$0] ?? .nan) vs \(y.values[$0] ?? .nan)" }) side \(String(describing: x.sidechainSource)) vs \(String(describing: y.sidechainSource)) bypass \(x.bypassed) vs \(y.bypassed)"
                }
                return "strip \(index) effect count \(a.effects.count) vs \(b.effects.count)"
            }
            return "strip \(index): \(a) vs \(b)"
        }
        return "none"
    }
}

/// Builds the random templates of §8.3: every effect kind, every instrument kind
/// a built-in may use (plus test tone and Audio Units), every modulation source
/// kind, random in-range settings. Every setting value is one the effect can
/// HOLD (written to a fresh effect and read back), so the builder's read-back
/// rule judges the template, not the generator.
struct TPL5TemplateGenerator {
    var rng: TPL5RNG

    static let names = ["Drums", "Bass", "Keys", "Pad", "Lead Vocal", "FX", "Room", "Echo",
                        "Drums", "808 Bass", "Café Piano", "Synth #2", "  Strings  "]
    static let auInstruments = [
        AudioUnitComponentID(type: "aumu", subType: "dls ", manufacturer: "appl"),
        AudioUnitComponentID(type: "aumu", subType: "samp", manufacturer: "appl"),
    ]
    static let auEffects = [
        AudioUnitComponentID(type: "aufx", subType: "dely", manufacturer: "appl"),
        AudioUnitComponentID(type: "aufx", subType: "rvb2", manufacturer: "appl"),
    ]

    mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < p }
    mutating func pick<T>(_ items: [T]) -> T { items[Int.random(in: 0..<items.count, using: &rng)] }
    mutating func value(in range: ClosedRange<Double>) -> Double {
        Double.random(in: range, using: &rng)
    }
    /// A setting value: a quarter of the time EXACTLY a bound or the default, the
    /// values a uniform draw never hits and the ones a wrong "fresh" reference
    /// shares (a no-params clipper reads exactly 4, the top of its range). Added
    /// after plant PL1c passed a uniform-only generator (P3).
    mutating func setting(in range: ClosedRange<Double>, default fallback: Double) -> Double {
        chance(0.25) ? pick([range.lowerBound, range.upperBound, fallback]) : value(in: range)
    }
    mutating func state() -> Data? {
        guard chance(0.7) else { return nil }
        return Data((0..<Int.random(in: 1...2048, using: &rng)).map { _ in
            UInt8.random(in: 0...255, using: &rng)
        })
    }

    mutating func template() -> TrackSetTemplate {
        let count = Int.random(in: 1...8, using: &rng)
        var tracks: [TemplateTrack] = []
        for index in 0..<count {
            let kind: TrackKind = pick([.instrument, .instrument, .audio, .bus])
            var track = TemplateTrack(key: "t\(index)", name: pick(Self.names), kind: kind,
                                      volume: chance(0.5) ? value(in: Track.volumeRange) : 1,
                                      pan: chance(0.5) ? value(in: Track.panRange) : 0)
            if kind == .instrument, chance(0.85) { track.instrument = instrument() }
            if chance(0.2) { track.mixerPreset = pick(MixerPresetCatalog.names) }
            for position in 0..<Int.random(in: 0...4, using: &rng) {
                track.inserts.append(insert(key: "fx\(position)"))
            }
            if chance(0.35) { modulation(&track) }
            tracks.append(track)
        }
        // Routing, by key, among the template's own tracks.
        let buses = tracks.filter { $0.kind == .bus }.map(\.key)
        let players = tracks.filter { $0.kind != .bus }.map(\.key)
        for index in tracks.indices where tracks[index].kind != .bus && !buses.isEmpty {
            if chance(0.3) { tracks[index].output = pick(buses) }
            for bus in buses where chance(0.3) {
                tracks[index].sends.append(TemplateSend(
                    bus: bus, level: chance(0.3) ? 1 : value(in: Send.levelRange)))
            }
        }
        for index in tracks.indices where tracks[index].kind != .instrument {
            guard chance(0.5), !players.isEmpty,
                  let insert = tracks[index].inserts.firstIndex(where: {
                      $0.kind == .compressor || $0.kind == .gate
                  }) else { continue }
            tracks[index].inserts[insert].sidechainSource = pick(players)
        }
        return TrackSetTemplate(id: "random", name: "Random", tracks: tracks)
    }

    /// m39-tpl-5b: a Sampler with 0–4 zones, every global and zone field drawn
    /// some of the time (bounds and defaults a quarter of the time, as
    /// `setting` does). Every zone is BUILT through `SamplerZone.init`, so its
    /// values are ones a zone holds (spans in order, ends after starts); the
    /// paths are absolute and never touched (the round trip never reaches a
    /// store).
    mutating func sampler() -> SamplerParams {
        var zones: [SamplerZone] = []
        for index in 0..<Int.random(in: 0...4, using: &rng) {
            let low = Int.random(in: SamplerZone.pitchRange, using: &rng)
            let high = Int.random(in: low...127, using: &rng)
            let start = chance(0.3) ? Int.random(in: 0...44_100, using: &rng) : nil
            let loopStart = chance(0.3) ? Int.random(in: 0...44_100, using: &rng) : nil
            var crossfade: SamplerCrossfade?
            if chance(0.25) {
                crossfade = SamplerCrossfade(
                    controller: chance(0.7) ? Int.random(in: 0...127, using: &rng) : nil,
                    ccInLo: chance(0.5) ? Int.random(in: 0...63, using: &rng) : nil,
                    ccInHi: chance(0.5) ? Int.random(in: 64...127, using: &rng) : nil,
                    velInLo: chance(0.3) ? Int.random(in: 0...63, using: &rng) : nil,
                    velOutHi: chance(0.3) ? Int.random(in: 64...127, using: &rng) : nil)
            }
            let randLow = chance(0.2) ? value(in: 0...0.5) : nil
            let length = chance(0.2) ? Int.random(in: 1...4, using: &rng) : nil
            zones.append(SamplerZone(
                audioFileURL: URL(fileURLWithPath: "/tpl5b-random/\(pick(["kick", "snare", "Café pad"])) \(index).wav"),
                rootPitch: chance(0.7) ? Int.random(in: SamplerZone.pitchRange, using: &rng) : 60,
                minPitch: chance(0.7) ? low : 0,
                maxPitch: chance(0.7) ? high : 127,
                gain: chance(0.5) ? setting(in: SamplerZone.gainRange, default: 1) : 1,
                minVelocity: chance(0.2) ? Int.random(in: 0...63, using: &rng) : nil,
                maxVelocity: chance(0.2) ? Int.random(in: 64...127, using: &rng) : nil,
                group: chance(0.2) ? Int.random(in: 0...3, using: &rng) : nil,
                seqLength: length,
                seqPosition: length.flatMap { length in chance(0.7) ? Int.random(in: 1...length, using: &rng) : nil },
                randMin: randLow,
                randMax: randLow.map { _ in value(in: 0.5...1) },
                tuneCents: chance(0.3) ? setting(in: SamplerZone.tuneCentsRange, default: 0) : nil,
                pan: chance(0.3) ? setting(in: SamplerZone.panRange, default: 0) : nil,
                ampVelTrack: chance(0.2) ? setting(in: SamplerZone.ampVelTrackRange, default: 1) : nil,
                oneShot: chance(0.2) ? chance(0.5) : nil,
                startFrame: start,
                endFrame: chance(0.3) ? (start ?? 0) + Int.random(in: 1...88_200, using: &rng) : nil,
                attack: chance(0.2) ? setting(in: SamplerParams.attackRange, default: 0.001) : nil,
                decay: chance(0.2) ? setting(in: SamplerZone.decayRange, default: 0) : nil,
                sustain: chance(0.2) ? setting(in: SamplerZone.sustainRange, default: 1) : nil,
                release: chance(0.2) ? setting(in: SamplerParams.releaseRange, default: 0.05) : nil,
                loopMode: chance(0.2) ? pick([SamplerLoopMode.sustain, .continuous]) : nil,
                loopStart: loopStart,
                loopEnd: chance(0.3) ? (loopStart ?? 0) + Int.random(in: 1...44_100, using: &rng) : nil,
                crossfade: crossfade,
                reverse: chance(0.15) ? chance(0.5) : nil,
                chokeGroup: chance(0.2) ? Int.random(in: SamplerZone.chokeGroupRange, using: &rng) : nil))
        }
        let fresh = SamplerParams()
        return SamplerParams(
            zones: zones, oneShot: chance(0.3),
            attack: chance(0.3) ? setting(in: SamplerParams.attackRange, default: fresh.attack) : fresh.attack,
            release: chance(0.3) ? setting(in: SamplerParams.releaseRange, default: fresh.release) : fresh.release,
            gain: chance(0.3) ? setting(in: SamplerParams.gainRange, default: fresh.gain) : fresh.gain,
            // Provenance a template never carries: capture must drop it.
            sourcePath: chance(0.3) ? "/tpl5b-random/library.sfz" : nil,
            expressionModDepth: chance(0.2) ? value(in: SamplerParams.expressionModDepthRange) : nil,
            expressionFilterDepth: chance(0.2) ? value(in: SamplerParams.expressionFilterDepthRange) : nil,
            expressionFilterCC: chance(0.2) ? Int.random(in: 0...127, using: &rng) : nil,
            bendRangeSemitones: chance(0.2)
                ? setting(in: SamplerParams.bendRangeSemitonesRange, default: 2) : nil,
            voiceMode: chance(0.3) ? pick(SamplerVoiceMode.allCases) : nil,
            decay: chance(0.2) ? value(in: SamplerZone.decayRange) : nil,
            sustain: chance(0.2) ? value(in: SamplerZone.sustainRange) : nil,
            pedalHoldLimit: chance(0.2) ? Int.random(in: SamplerParams.pedalHoldLimitRange, using: &rng) : nil,
            glideTime: chance(0.2) ? setting(in: SamplerParams.glideTimeRange, default: 0) : nil,
            glideMode: chance(0.2) ? pick(SamplerGlideMode.allCases) : nil)
    }

    mutating func instrument() -> InstrumentDescriptor {
        switch Int.random(in: 0...6, using: &rng) {
        case 5:
            return InstrumentDescriptor(kind: .sampler, sampler: chance(0.1) ? nil : sampler())
        case 0:
            var synth = PolySynthParams()
            for name in PolySynthParams.settingNames where chance(0.3) {
                switch PolySynthParams.settingKind(named: name) {
                case .waveform: synth.setSetting(name, waveform: pick(PolySynthParams.Waveform.allCases))
                case .number(let range): synth.setSetting(name, number: value(in: range))
                case .integer(let range):
                    synth.setSetting(name, number: Double(Int.random(in: range, using: &rng)))
                case nil: break
                }
            }
            return InstrumentDescriptor(kind: .polySynth, polySynth: synth)
        case 1:
            var kit = chance(0.5) ? pick(DrumKitParams.presets).params : DrumKitParams()
            for spec in DrumKitParams.paramSpecs where chance(0.05) {
                kit.setValue(setting(in: spec.range, default: spec.defaultValue), forParamName: spec.name)
            }
            for voice in DrumVoice.allCases where chance(0.1) {
                kit[voice].chokeGroup = chance(0.3) ? nil : Int.random(in: SamplerZone.chokeGroupRange,
                                                                         using: &rng)
            }
            if chance(0.5) { kit.noteLayout = .gm }
            return InstrumentDescriptor(kind: .drumSynth, drumKit: chance(0.1) ? nil : kit)
        case 2:
            let drums = chance(0.2)
            return InstrumentDescriptor(kind: .soundBank, soundBank: SoundBankConfig(
                source: .generalMIDI, program: drums ? 0 : Int.random(in: 0...127, using: &rng),
                bankMSB: drums ? 120 : 121, bankLSB: 0, displayName: "whatever the wire said"))
        case 3:
            return InstrumentDescriptor(kind: .testTone)
        case 4:
            return InstrumentDescriptor(kind: .audioUnit, audioUnit: AudioUnitConfig(
                component: pick(Self.auInstruments), name: "Display Name",
                manufacturerName: "Apple", stateData: state()))
        default:
            // Inactive-kind blocks ride along on a real descriptor; the template
            // must ignore them.
            var descriptor = InstrumentDescriptor(kind: .polySynth)
            descriptor.drumKit = DrumKitParams.presets.first?.params
            descriptor.polySynth.cutoffHz = 1234
            return descriptor
        }
    }

    mutating func insert(key: String) -> TemplateInsert {
        let kind = pick(EffectDescriptor.Kind.allCases)
        if kind == .audioUnit {
            return TemplateInsert(key: key, kind: .audioUnit, bypassed: chance(0.2),
                                  audioUnit: AudioUnitConfig(component: pick(Self.auEffects),
                                                             name: "Delay", stateData: state()))
        }
        let specs = EffectParamSpec.specs(for: kind)
        var chosen: [String: Double] = [:]
        for spec in specs where chance(0.35) {
            chosen[spec.name] = setting(in: spec.range, default: spec.defaultValue)
        }
        // Keep only values the effect can hold: what it reads back.
        let effect = TemplateCapture.built(kind, chosen)
        var params: [String: Double] = [:]
        for name in chosen.keys { params[name] = effect.paramValue(name) }
        return TemplateInsert(key: key, kind: kind, bypassed: chance(0.2), params: params)
    }

    mutating func modulation(_ track: inout TemplateTrack) {
        var keys: [String] = []
        for position in 0..<Int.random(in: 1...3, using: &rng) {
            let kind = pick(ModulationSourceKind.allCases)
            var values: [String: ModulationParamValue] = [:]
            switch kind {
            case .lfo:
                if chance(0.5) { values["waveform"] = .string(pick(LFOWaveform.allCases).rawValue) }
                if chance(0.5) { values["rateHz"] = .number(value(in: 0.01...20)) }
                if chance(0.3) { values["phaseDeg"] = .number(value(in: LFOSourceParams.phaseRange)) }
                if chance(0.3) { values["pulseWidth"] = .number(value(in: LFOSourceParams.pulseWidthRange)) }
                if chance(0.3) { values["edgeMs"] = .number(value(in: LFOSourceParams.edgeRange)) }
                if chance(0.3) { values["bipolar"] = .bool(chance(0.5)) }
                if chance(0.3) { values["seed"] = .number(Double(Int.random(in: 0...65_535, using: &rng))) }
            case .stepSequencer:
                if chance(0.7) {
                    values["steps"] = .numbers((0..<Int.random(in: 1...16, using: &rng)).map { _ in
                        value(in: StepSequencerSourceParams.stepValueRange)
                    })
                }
                if chance(0.5) { values["rateHz"] = .number(value(in: 0.01...20)) }
                if chance(0.3) { values["edgeMs"] = .number(value(in: StepSequencerSourceParams.edgeRange)) }
            case .envelopeFollower:
                if chance(0.5) { values["detector"] = .string(pick(EnvelopeDetector.allCases).rawValue) }
                if chance(0.5) { values["attackMs"] = .number(value(in: EnvelopeFollowerSourceParams.attackRange)) }
                if chance(0.5) { values["releaseMs"] = .number(value(in: EnvelopeFollowerSourceParams.releaseRange)) }
                if chance(0.3) { values["floorDb"] = .number(value(in: EnvelopeFollowerSourceParams.floorRange)) }
                if chance(0.3) { values["gainDb"] = .number(value(in: EnvelopeFollowerSourceParams.gainRange)) }
            case .macro:
                if chance(0.7) { values["value"] = .number(value(in: MacroSourceParams.valueRange)) }
            }
            let params = (try? ModulationSourceParams.apply(values, to: .defaults(for: kind)))?.params
                ?? .defaults(for: kind)
            let key = "src\(position)"
            keys.append(key)
            track.modulationSources.append(TemplateModSource(
                key: key, kind: kind, name: chance(0.3) ? pick(["Wobble", "LFO", "Sweep"]) : nil,
                params: params))
        }
        for _ in 0..<Int.random(in: 0...3, using: &rng) {
            var targets: [TemplateTarget] = [.volume, .pan]
            if track.kind == .instrument {
                let kind = (track.instrument ?? .default).kind
                for spec in InstrumentParamSpec.specs(for: kind) where spec.modulatable != .refused {
                    targets.append(.instrumentParam(param: spec.name))
                }
            }
            for insert in track.inserts where insert.key != nil {
                for spec in EffectParamSpec.specs(for: insert.kind) where spec.modulatable != .refused {
                    targets.append(.effectParam(insert: insert.key!, param: spec.name))
                }
            }
            track.modulationRoutes.append(TemplateModRoute(
                source: pick(keys), target: pick(targets),
                depth: value(in: ModulationRoute.depthRange), enabled: chance(0.8)))
        }
    }
}

@Suite("m39-tpl-5: TemplateCapture, the canonical form, the round trip")
struct TemplateCaptureTests {
    // MARK: - Helpers

    func tpl5Built(_ template: TrackSetTemplate) throws -> [Track] {
        try TemplateBuilder.plan(template).tracks
    }

    func tpl5CaptureAll(_ tracks: [Track], name: String = "Round Trip") throws -> TemplateCapture.Result {
        try TemplateCapture.capture(tracks: tracks, selected: tracks.map(\.id), name: name)
    }

    /// Halves (a), (b) and (c) for one template. Returns a failure sentence, or nil.
    func tpl5RoundTripFailure(_ template: TrackSetTemplate) throws -> String? {
        let first = try tpl5Built(template)
        // The template-level labels are not in the tracks: capture is TOLD them,
        // exactly as `template.save` is.
        let captured = try TemplateCapture.capture(
            tracks: first, selected: first.map(\.id), name: template.name, id: template.id,
            summary: template.summary, songForm: template.songForm, genres: template.genres)
        let expected = try TemplateCapture.canonical(template)
        let got = try TemplateCapture.canonical(captured.template)
        if got != expected {
            for (index, (a, b)) in zip(got.tracks, expected.tracks).enumerated() where a != b {
                return "(a) canonical differs at tracks[\(index)]:\n  got      \(a)\n  expected \(b)"
            }
            return "(a) canonical differs at the top level (\(got.tracks.count) vs "
                + "\(expected.tracks.count) tracks)"
        }
        let again = TPL5BandReading(try tpl5Built(captured.template))
        let original = TPL5BandReading(first)
        if again != original { return "(b) readings differ: \(again.firstDifference(from: original))" }
        // (c) — for EVERY template since m39-tpl-5b: a Sampler with its sound
        // files is written and read back too (it was skipped while the codec
        // refused a `sampler` block).
        let data = try TemplateCapture.canonicalJSON(captured.template)
        let decoded = try TrackSetTemplateCodec.decode(data, origin: .inline).template
        let canonical = try TemplateCapture.canonical(captured.template)
        if decoded != canonical {
            for (index, (a, b)) in zip(decoded.tracks, canonical.tracks).enumerated() where a != b {
                return "(c) JSON reads back differently at tracks[\(index)]:\n  read  \(a)\n  wrote \(b)"
            }
            return "(c) JSON reads back differently at the top level"
        }
        return nil
    }

    // MARK: - Censuses (MEASURED, printed; they inform the plant predictions)

    @Test("Census: where a setting's spec default differs from a brand-new effect's reading")
    func censusSpecDefaultVersusFreshReading() {
        var differences: [String] = []
        for kind in EffectDescriptor.Kind.allCases {
            let fresh = EffectDescriptor.newlyAdded(kind: kind)
            for spec in EffectParamSpec.specs(for: kind) {
                let reading = fresh.paramValue(spec.name)
                if reading != spec.defaultValue {
                    differences.append("\(kind.rawValue).\(spec.name): spec \(spec.defaultValue), "
                        + "fresh \(reading.map { "\($0)" } ?? "nil")")
                }
            }
        }
        print("[measured] spec-default ≠ fresh-reading: \(differences.count) settings: "
            + differences.joined(separator: "; "))
        // Positive control: the census reads real specs (22 built-in kinds have some).
        #expect(EffectDescriptor.Kind.allCases.reduce(0) { $0 + EffectParamSpec.specs(for: $1).count } > 100)
    }

    @Test("Census: drum presets the named surface can rebuild exactly")
    func censusDrumPresetsThroughNames() {
        var lossy: [String] = []
        for preset in DrumKitParams.presets {
            let rebuilt = TemplateCapture.normalizedKit(preset.params) ?? DrumKitParams()
            if rebuilt != preset.params { lossy.append(preset.name) }
        }
        print("[measured] drum presets NOT rebuilt exactly by name: \(lossy.count) of "
            + "\(DrumKitParams.presets.count): \(lossy)")
        #expect(DrumKitParams.presets.count == 5)
        #expect(lossy.isEmpty, "a preset holds a value no drum setting name can reach: \(lossy)")
    }

    // MARK: - Keys

    @Test("Track keys come from names: lowercased, hyphenated, -2 and -3 for repeats")
    func keysFromNames() {
        #expect(TemplateCapture.key(fromName: "Lead Vocal") == "lead-vocal")
        #expect(TemplateCapture.key(fromName: "808 Bass") == "808-bass")
        #expect(TemplateCapture.key(fromName: "Café Piano") == "cafe-piano")
        #expect(TemplateCapture.key(fromName: "  Synth #2!! ") == "synth-2")
        #expect(TemplateCapture.key(fromName: "🎹🎹") == "")
        let long = TemplateCapture.key(fromName: String(repeating: "abcdefghi ", count: 4))
        #expect(long.count <= TrackSetTemplateCodec.maxKeyLength)
        #expect(!long.hasSuffix("-"))
        #expect(TemplateCapture.uniqueKeys(["Drums", "Drums", "Drums 2", "Drums", "🎹"],
                                           fallback: "track")
            == ["drums", "drums-2", "drums-2-2", "drums-3", "track"])
        for key in TemplateCapture.uniqueKeys(Array(repeating: String(repeating: "x", count: 40),
                                                    count: 12), fallback: "track") {
            #expect(TemplateReader.isValidKey(key), "\(key)")
        }
    }

    // MARK: - §8.3 over every built-in

    @Test("§8.3: every built-in survives apply → capture, by all three halves")
    func everyBuiltInRoundTrips() throws {
        let listing = BuiltInTemplateCatalog.load()
        #expect(listing.unreadable.isEmpty, "\(listing.unreadable)")
        #expect(listing.templates.count == BuiltInTemplateCatalog.ids.count)
        for entry in listing.templates {
            let failure = try tpl5RoundTripFailure(entry.template)
            #expect(failure == nil, "\(entry.id): \(failure ?? "")")
            // Capturing EVERY track never drops a key or adds a bus.
            let captured = try tpl5CaptureAll(try tpl5Built(entry.template))
            #expect(captured.warnings.isEmpty, "\(entry.id): \(captured.warnings)")
            // Already canonical as it comes out of capture.
            #expect(try TemplateCapture.canonical(captured.template) == captured.template, "\(entry.id)")
        }
    }

    @Test("The canonical JSON is the same bytes every time, starts with the format, and reads back")
    func canonicalJSONIsStable() throws {
        let entry = try #require(BuiltInTemplateCatalog.load().templates.first { $0.id == "lofi-chill" })
        let first = try TemplateCapture.canonicalJSON(entry.template)
        let second = try TemplateCapture.canonicalJSON(try TemplateCapture.canonical(entry.template))
        #expect(first == second)
        let text = String(decoding: first, as: UTF8.self)
        #expect(text.hasPrefix("{\n  \"format\": \"dawpro.template\",\n"))
        #expect(text.hasSuffix("}\n"))
        // Keys are re-derived from names: "Keys Duck" is `keys-duck`, never `duck`.
        #expect(text.contains("\"output\": \"keys-duck\""))
        #expect(!text.contains("\"mixerPreset\""))
        let decoded = try TrackSetTemplateCodec.decode(first, origin: .file)
        #expect(decoded.template == (try TemplateCapture.canonical(entry.template)))
        #expect(decoded.warnings.isEmpty)
    }

    // MARK: - §8.3 over 500 random templates

    @Test("§8.3: 500 random templates survive apply → capture, by all three halves")
    func randomTemplatesRoundTrip() throws {
        let seed = ProcessInfo.processInfo.environment["TPL5_SEED"].flatMap { UInt64($0) }
            ?? 0x7E3D_5A11_2026_1005
        var generator = TPL5TemplateGenerator(rng: TPL5RNG(seed: seed))
        var passed = 0
        var refusedByBuilder = 0
        var kindsSeen: Set<String> = []
        var zonedSamplers = 0
        var samplerZones = 0
        var sample = 0
        while passed < 500, sample < 5_000 {
            sample += 1
            let template = generator.template()
            do {
                _ = try TemplateBuilder.plan(template)
            } catch {
                refusedByBuilder += 1
                continue
            }
            for track in template.tracks {
                track.inserts.forEach { kindsSeen.insert("fx." + $0.kind.rawValue) }
                if let instrument = track.instrument { kindsSeen.insert("in." + instrument.kind.rawValue) }
                if let zones = track.instrument?.sampler?.zones, !zones.isEmpty {
                    zonedSamplers += 1
                    samplerZones += zones.count
                }
                track.modulationSources.forEach { kindsSeen.insert("mod." + $0.kind.rawValue) }
            }
            let failure = try tpl5RoundTripFailure(template)
            #expect(failure == nil, "seed \(seed) sample \(sample): \(failure ?? "")")
            if failure != nil { break }
            passed += 1
        }
        print("[measured] random round trip: seed \(seed), \(passed) passed, \(refusedByBuilder) "
            + "drawn templates refused by the builder, \(sample) drawn, \(kindsSeen.count) kinds, "
            + "\(zonedSamplers) Samplers holding \(samplerZones) zones")
        #expect(passed == 500, "seed \(seed)")
        // m39-tpl-5b: the draw must reach Samplers WITH zones, or half (c) never saw one.
        #expect(zonedSamplers >= 20, "only \(zonedSamplers) Samplers with zones were drawn")
        // Every effect kind, every instrument kind drawn, every source kind.
        for kind in EffectDescriptor.Kind.allCases {
            #expect(kindsSeen.contains("fx." + kind.rawValue), "never drew \(kind.rawValue)")
        }
        for kind in ["polySynth", "drumSynth", "soundBank", "sampler", "testTone", "audioUnit"] {
            #expect(kindsSeen.contains("in." + kind), "never drew \(kind)")
        }
        for kind in ModulationSourceKind.allCases {
            #expect(kindsSeen.contains("mod." + kind.rawValue), "never drew \(kind.rawValue)")
        }
    }

    // MARK: - Named readings, not spec defaults (§4.6)

    @Test("A legacy clipper keeps its 4× oversampling through capture and apply")
    func legacyClipperKeepsItsFour() throws {
        let legacy = EffectDescriptor(kind: .clipper)          // saved before 2026-09-20: no params
        #expect(legacy.paramValue("oversampling") == 4)
        #expect(EffectDescriptor.newlyAdded(kind: .clipper).paramValue("oversampling") == 1)
        let track = Track(name: "Vocal", kind: .audio, effects: [legacy])
        let captured = try tpl5CaptureAll([track])
        #expect(captured.template.tracks[0].inserts[0].params["oversampling"] == 4)
        let rebuilt = try tpl5Built(captured.template)
        #expect(rebuilt[0].effects[0].paramValue("oversampling") == 4)
        // A NEW clipper's 1 is a fresh reading: not written, and still 1 after.
        let fresh = Track(name: "Vocal", kind: .audio, effects: [.newlyAdded(kind: .clipper)])
        let freshCapture = try tpl5CaptureAll([fresh])
        #expect(freshCapture.template.tracks[0].inserts[0].params["oversampling"] == nil)
        #expect(try tpl5Built(freshCapture.template)[0].effects[0].paramValue("oversampling") == 1)
    }

    @Test("A switched-off EQ filter beside a stored corner stays off (coupled settings)")
    func coupledEQFilterStaysOff() throws {
        var eq = EffectDescriptor.newlyAdded(kind: .eq)
        eq.applySetting("highPassFreq", 120)
        eq.applySetting("highPassEnabled", 0)
        #expect(eq.paramValue("highPassFreq") == 120)
        #expect(eq.paramValue("highPassEnabled") == 0)
        let track = Track(name: "Bass", kind: .audio, effects: [eq])
        let captured = try tpl5CaptureAll([track])
        let rebuilt = try tpl5Built(captured.template)
        #expect(rebuilt[0].effects[0].paramValue("highPassFreq") == 120)
        #expect(rebuilt[0].effects[0].paramValue("highPassEnabled") == 0)
        #expect(TPL5BandReading(rebuilt) == TPL5BandReading([track]))
    }

    // MARK: - What capture includes, drops and never reads (§5.7)

    /// Piano sends to Reverb; Drums play into Drum Bus; Keys play into Keys
    /// Duck, whose compressor listens to Drums.
    func tpl5Song() -> [Track] {
        let reverb = Track(name: "Reverb", kind: .bus, effects: [.newlyAdded(kind: .reverb)])
        let drumBus = Track(name: "Drum Bus", kind: .bus)
        let drums = Track(name: "Drums", kind: .instrument,
                          instrument: InstrumentDescriptor(kind: .drumSynth), outputBusID: drumBus.id)
        let duck = Track(name: "Keys Duck", kind: .bus,
                         effects: [EffectDescriptor(kind: .compressor,
                                                    sidechainSourceTrackID: drums.id)])
        let keys = Track(name: "Keys", kind: .instrument, outputBusID: duck.id)
        let piano = Track(name: "Piano", kind: .instrument,
                          sends: [Send(destinationBusID: reverb.id, level: 0.4)])
        return [drums, keys, piano, reverb, drumBus, duck]
    }

    @Test("The buses a chosen track plays or sends into come along, in song order, and are reported")
    func busesComeAlong() throws {
        let song = tpl5Song()
        let piano = song[2]
        let result = try TemplateCapture.capture(tracks: song, selected: [piano.id], name: "Piano")
        #expect(result.template.tracks.map(\.name) == ["Piano", "Reverb"])
        #expect(result.template.tracks[0].sends == [TemplateSend(bus: "reverb", level: 0.4)])
        #expect(result.warnings == [TemplateWarning(
            code: .busIncluded, path: "tracks",
            message: "The bus 'Reverb' was saved too, because 'Piano' sends to it.")])
        let drums = try TemplateCapture.capture(tracks: song, selected: [song[0].id], name: "Drums")
        #expect(drums.template.tracks.map(\.name) == ["Drums", "Drum Bus"])
        #expect(drums.template.tracks[0].output == "drum-bus")
        #expect(drums.warnings.map(\.message)
            == ["The bus 'Drum Bus' was saved too, because 'Drums' plays into it."])
    }

    @Test("A sidechain from a track you didn't choose is dropped with §5.7's sentence; the source is not pulled in")
    func unchosenSidechainSourceIsDropped() throws {
        let song = tpl5Song()
        let result = try TemplateCapture.capture(tracks: song, selected: [song[1].id], name: "Keys")
        #expect(result.template.tracks.map(\.name) == ["Keys", "Keys Duck"])
        #expect(result.template.tracks[1].inserts[0].sidechainSource == nil)
        #expect(result.warnings.contains(TemplateWarning(
            code: .sidechainDropped, path: "tracks[1].inserts[0].sidechainSource",
            message: "The Keys Duck compressor listened to Drums, which you didn't save, so it "
                + "will not duck.")))
        // Choose Drums too: the key is kept, by key.
        let both = try TemplateCapture.capture(tracks: song, selected: [song[1].id, song[0].id],
                                               name: "Keys and Drums")
        #expect(both.template.tracks.map(\.name) == ["Drums", "Keys", "Drum Bus", "Keys Duck"])
        #expect(both.template.tracks[3].inserts[0].sidechainSource == "drums")
        #expect(!both.warnings.contains { $0.code == .sidechainDropped })
        _ = try tpl5Built(both.template)
    }

    @Test("Capture never reads clips, automation, mute, solo, arm, the AI-made flag or takes")
    func sessionStateIsNeverRead() throws {
        let plain = Track(name: "Keys", kind: .instrument)
        var busy = plain
        busy.isMuted = true
        busy.isSoloed = true
        busy.isArmed = true
        busy.isAIGenerated = true
        busy.clips = [Clip(name: "riff", startBeat: 0, lengthBeats: 4,
                           notes: [MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1)])]
        busy.automation = [AutomationLane(target: .volume, points: [AutomationPoint(beat: 0, value: 0.5)])]
        let a = try tpl5CaptureAll([plain])
        let b = try tpl5CaptureAll([busy])
        #expect(a == b)
        #expect(try TemplateCapture.canonicalJSON(a.template) == TemplateCapture.canonicalJSON(b.template))
    }

    @Test("An Audio Unit's saved sound travels as base64 and comes back byte for byte")
    func audioUnitStateTravels() throws {
        let state = Data((0..<3_000).map { UInt8(truncatingIfNeeded: $0 &* 37) })
        let unit = AudioUnitConfig(component: AudioUnitComponentID(subType: "dls ", manufacturer: "appl"),
                                   name: "DLSMusicDevice", manufacturerName: "Apple", stateData: state)
        let effectState = Data([0, 1, 2, 255])
        let track = Track(name: "Keys", kind: .instrument,
                          instrument: InstrumentDescriptor(kind: .audioUnit, audioUnit: unit),
                          effects: [.newlyAdded(kind: .audioUnit, audioUnit: AudioUnitConfig(
                              component: AudioUnitComponentID(type: "aufx", subType: "dely",
                                                              manufacturer: "appl"),
                              stateData: effectState))])
        let captured = try tpl5CaptureAll([track])
        let data = try TemplateCapture.canonicalJSON(captured.template)
        #expect(String(decoding: data, as: UTF8.self).contains(state.base64EncodedString()))
        let decoded = try TrackSetTemplateCodec.decode(data, origin: .inline).template
        #expect(decoded.tracks[0].instrument?.audioUnit?.stateData == state)
        #expect(decoded.tracks[0].inserts[0].audioUnit?.stateData == effectState)
        let rebuilt = try tpl5Built(decoded)
        #expect(rebuilt[0].instrument?.audioUnit?.stateData == state)
        #expect(rebuilt[0].effects[0].audioUnit?.stateData == effectState)
    }

    @Test("Capture refuses what no template can be: nothing chosen, a stranger's id, too many tracks, a bad name")
    func captureRefusals() throws {
        let song = tpl5Song()
        func refusal(_ body: () throws -> Void) -> TemplateRefusal? {
            do { try body() } catch let refusal as TemplateRefusal { return refusal } catch { return nil }
            return nil
        }
        #expect(refusal { _ = try TemplateCapture.capture(tracks: song, selected: [], name: "X") }?
            .message == "Choose at least one track to save as a template.")
        let stranger = UUID()
        #expect(refusal { _ = try TemplateCapture.capture(tracks: song, selected: [stranger], name: "X") }?
            .path == "trackIds[0]")
        let long = String(repeating: "n", count: TrackSetTemplateCodec.maxNameLength + 1)
        #expect(refusal { _ = try TemplateCapture.capture(tracks: song, selected: [song[0].id], name: long) }?
            .code == .outOfRange)
        #expect(refusal { _ = try TemplateCapture.capture(tracks: song, selected: [song[0].id], name: "  ") }?
            .code == .invalidValue)
        #expect(refusal { _ = try TemplateCapture.capture(tracks: song, selected: [song[0].id], name: "X",
                                                          genres: ["polka"]) }?.code == .unknownKind)
        // 23 chosen tracks that send into 2 buses: 25 once the buses come along.
        let busA = Track(name: "A", kind: .bus)
        let busB = Track(name: "B", kind: .bus)
        let players = (0..<23).map { index in
            Track(name: "P\(index)", kind: .audio,
                  sends: [Send(destinationBusID: busA.id), Send(destinationBusID: busB.id)])
        }
        let crowd = players + [busA, busB]
        let tooMany = refusal {
            _ = try TemplateCapture.capture(tracks: crowd, selected: players.map(\.id), name: "Crowd")
        }
        #expect(tooMany?.message == "A template can hold at most 24 tracks, and this one would hold "
            + "25: the 23 you chose plus 2 buses they play or send into.")
        // 22 players + 2 buses = 24: allowed.
        let fits = try TemplateCapture.capture(tracks: crowd, selected: players.dropLast().map(\.id),
                                               name: "Crowd")
        #expect(fits.template.tracks.count == 24)
    }

    @Test("m39-tpl-5b: a Sampler with sound files is WRITTEN to JSON and reads back exactly; an empty one is just its kind")
    func samplerWithZonesIsWrittenToJSON() throws {
        let zone = SamplerZone(audioFileURL: URL(fileURLWithPath: "/nowhere/a.wav"), rootPitch: 48,
                               pan: 0)
        var sampler = SamplerParams(zones: [zone], release: 0.4, sourcePath: "/nowhere/kit.sfz",
                                    displayName: "Kit")
        sampler.markSliceKit()
        let track = Track(name: "Kit", kind: .instrument,
                          instrument: InstrumentDescriptor(kind: .sampler, sampler: sampler))
        let captured = try tpl5CaptureAll([track])
        let held = try #require(captured.template.tracks[0].instrument?.sampler)
        #expect(held.zones.count == 1)
        #expect(held.sourcePath == nil && held.displayName == nil && held.sliceKit == nil,
                "provenance is never carried")
        #expect(held.zones.allSatisfy { TemplateReader.isSamplerZonePlaceholder($0.id) })
        #expect(captured.warnings.map(\.code) == [.valueChanged], "the slice-kit mark is dropped in words")
        let data = try TemplateCapture.canonicalJSON(captured.template)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"path\": \"/nowhere/a.wav\""))
        #expect(text.contains("\"pan\": 0"), "an explicit pan 0 is the -3 dB centre, not nil: written")
        #expect(!text.contains("\"id\": \"\(held.zones[0].id.uuidString)\""), "no zone id is written")
        #expect(!text.contains("sourcePath") && !text.contains("sliceKit"))
        let decoded = try TrackSetTemplateCodec.decode(data, origin: .inline)
        #expect(decoded.template == (try TemplateCapture.canonical(captured.template)))
        #expect(decoded.warnings.isEmpty)
        // An EMPTY Sampler is just its kind, and reads back.
        let empty = Track(name: "Empty", kind: .instrument, instrument: InstrumentDescriptor(kind: .sampler))
        let emptyData = try TemplateCapture.canonicalJSON(try tpl5CaptureAll([empty]).template)
        let emptyDecoded = try TrackSetTemplateCodec.decode(emptyData, origin: .inline).template
        #expect(emptyDecoded.tracks[0].instrument == InstrumentDescriptor(kind: .sampler))
    }
}
