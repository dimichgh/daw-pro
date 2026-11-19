import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// W9-HEAD (m39-dm-headroom) — THE HEADROOM MEASURE, AND THE BEFORE/AFTER TEMPLATE GATE.
//
// W9-DRUMDEF made the user's picks a NEW drum machine's defaults (hats +23.4 dB, cymbals
// +5.7 dB, General MIDI keys) and stopped on true peak: a plain new drum machine on a new
// song (no master chain) peaks above 0 dBTP. This suite writes the numbers that decide
// the fix, and the renders a byte comparison (`cmp`) between two trees needs.
//
// ENV-GATED: runs only with `DRUMHEAD_GATE=1`.
//   - `DRUMHEAD_DIR`: the gate's folder. Everything goes to `<dir>/out/<DRUMHEAD_PHASE>/`.
//   - `DRUMHEAD_QUICK=1`: skips the kit-gain sweep and the Mac GM kit (a plant window).
//
// Deliberately NOT `@MainActor` (no new MainActor suite): the store and render steps run
// inside `@MainActor` helpers (`DrumDefStage`, `DrumHeadStage`).

/// Where the headroom gate writes.
struct DrumHeadRig: Sendable {
    let out: URL
    let phase: String

    static func make() throws -> DrumHeadRig {
        let env = ProcessInfo.processInfo.environment
        let dir = try #require(env["DRUMHEAD_DIR"].flatMap { $0.isEmpty ? nil : $0 },
                               "DRUMHEAD_DIR must name the gate's folder")
        let phase = try #require(env["DRUMHEAD_PHASE"].flatMap { $0.isEmpty ? nil : $0 },
                                 "DRUMHEAD_PHASE must name this run")
        let out = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("out/\(phase)", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return DrumHeadRig(out: out, phase: phase)
    }
}

@MainActor
enum DrumHeadStage {
    /// EVERY built-in template that births a drum machine (with its drum track's key),
    /// read from the catalog rather than typed, so a fourth one joins the gate by itself.
    nonisolated static func drumTemplates() -> [(id: String, key: String)] {
        BuiltInTemplateCatalog.load().templates.flatMap { entry in
            entry.template.tracks.filter { $0.instrument?.kind == .drumSynth }.map { (id: entry.id, key: $0.key) }
        }
    }

    /// A built-in template, applied as the template picker applies it, with `notes` on its
    /// drum track. Returns the drum track's instrument, its fader, and the export render.
    static func template(_ id: String, key: String, bpm: Double, notes: [MIDINote],
                         seconds: Double) throws -> (InstrumentDescriptor?, Double, RenderedAudio) {
        let store = ProjectStore(projectName: "DRUMHEAD \(id)")
        try store.setTempo(bpm)
        let entry = try #require(BuiltInTemplateCatalog.load().templates.first { $0.id == id })
        let result = try store.applyTemplate(entry.template)
        let drumsID = try #require(result.tracks.first { $0.key == key }?.id)
        let length = (notes.map(\.endBeat).max() ?? 4).rounded(.up)
        _ = try store.addMIDIClip(toTrack: drumsID, name: "Beat", atBeat: 0, lengthBeats: length, notes: notes)
        let track = store.tracks.first { $0.id == drumsID }
        return (track?.instrument, track?.volume ?? -1, try DrumDefStage.render(store, seconds: seconds))
    }

    /// The Mac's own General MIDI drum kit (gs_instruments.dls through AUSampler, bank MSB
    /// 120 program 0) on one track at fader 1.0, through the same offline renderer. nil when
    /// the sound bank did not reach `.ready` (then nothing was measured).
    static func macGMKit(bpm: Double, notes: [MIDINote], seconds: Double) async throws -> RenderedAudio? {
        let kit = GMProgramCatalog.standardDrumKit
        let descriptor = InstrumentDescriptor(kind: .soundBank, soundBank: SoundBankConfig(
            source: .generalMIDI, program: kit.program, bankMSB: kit.bankMSB))
        let length = (notes.map(\.endBeat).max() ?? 4).rounded(.up)
        let track = Track(name: "DRUMHEAD Mac GM kit", kind: .instrument,
                          clips: [Clip(name: "Beat", startBeat: 0, lengthBeats: length, notes: notes)],
                          instrument: descriptor)
        let renderer = OfflineRenderer()
        await renderer.prepareAudioUnits(tracks: [track])
        guard renderer.auRegistry.status[track.id] == .ready else { return nil }
        return try renderer.render(tracks: [track], tempoMap: TempoMap(constantBPM: bpm),
                                   fromBeat: 0, durationSeconds: seconds)
    }
}

@Suite("W9-HEAD drum machine headroom — measure + template gate (DRUMHEAD_GATE=1 only)")
struct DrumHeadroomGateTests {
    static let enabled = ProcessInfo.processInfo.environment["DRUMHEAD_GATE"] == "1"
    static let quick = ProcessInfo.processInfo.environment["DRUMHEAD_QUICK"] == "1"

    /// A kit, by its three picks and an explicit kit gain.
    static func kit(layout: DrumNoteLayout, hats: Double, cymbals: Double, gain: Double) -> DrumKitParams {
        var kit = DrumKitParams()
        kit.noteLayout = layout
        kit.hatsLevelDb = hats
        kit.cymbalsLevelDb = cymbals
        kit.gain = gain
        return kit
    }

    @Test("DRUMHEAD: the missing control, the newborn re-measured, a kit-gain sweep, the templates, the Mac kit",
          .enabled(if: DrumHeadroomGateTests.enabled))
    func measureAndWrite() async throws {
        let rig = try DrumHeadRig.make()
        var rows: [[String: Any]] = []

        func row(_ name: String, _ audio: RenderedAudio, _ instrument: InstrumentDescriptor?,
                 wav: Bool = true, extra: [String: Any] = [:]) async throws {
            if wav { try await DrumDefStage.write(audio, to: rig.out.appendingPathComponent("\(name).wav")) }
            // The app's own BS.1770 meter: 4x oversampled true peak.
            let loudness = Loudness.measure(audio)
            var entry: [String: Any] = [
                "name": name, "frames": audio.frameCount,
                "samplePeakDb": DrumDefMeasure.samplePeakDb(audio),
                "truePeakDbtp": loudness.truePeakDbtp ?? -999,
                "integratedLufs": loudness.integratedLufs ?? -999,
                "rmsDb": DrumDefMeasure.rmsDb(audio),
                "digest": DrumDefMeasure.digest(audio),
            ]
            if let instrument {
                let kit = instrument.resolvedDrumKit
                entry["kind"] = instrument.kind.rawValue
                entry["kitStored"] = instrument.drumKit != nil
                entry["noteLayout"] = kit.noteLayout.rawValue
                entry["hatsLevelDb"] = kit.hatsLevelDb
                entry["cymbalsLevelDb"] = kit.cymbalsLevelDb
                entry["kitGain"] = kit.gain
            }
            for (key, value) in extra { entry[key] = value }
            #expect(DrumDefMeasure.samplePeakDb(audio) > -60, "\(name) is silent")
            rows.append(entry)
        }

        // The beats. `normal` is the 808 template's audition beat at its own velocities
        // (kick 110, snare 105, hats 90/75, open hat 85, crash 100: no accent but the kick's
        // and the snare's, the kit's accent threshold being 100) — DRUMDEF's "newborn-beat".
        let normal = DrumDefBeats.templateBeat(bars: 2)
        let at100 = DrumDefBeats.templateBeat(bars: 2, velocity: 100)
        let loud = DrumDefBeats.templateBeat(bars: 8, velocity: 127)
        let loudSeconds = 8 * 4 * 60.0 / 90 + 2
        let all = DrumDefBeats.allVoicesAtOnce(bars: 4, velocity: 127)
        let allSeconds = 4 * 4 * 60.0 / 90 + 2

        // ---- 1. THE MISSING CONTROL: General MIDI layout, trims 0, kit gain 1, the SAME beats.
        let control = Self.kit(layout: .gm, hats: 0, cymbals: 0, gain: 1)
        let c1 = try await DrumDefStage.newDrumMachine(kit: control, bpm: 120, notes: normal, seconds: 6)
        try await row("control-gm-trims0-normal", c1.1, c1.0)
        let c2 = try await DrumDefStage.newDrumMachine(kit: control, bpm: 120, notes: at100, seconds: 6)
        try await row("control-gm-trims0-v100", c2.1, c2.0)
        let c3 = try await DrumDefStage.newDrumMachine(kit: control, bpm: 90, notes: loud, seconds: loudSeconds)
        try await row("control-gm-trims0-v127", c3.1, c3.0)
        let c4 = try await DrumDefStage.newDrumMachine(kit: control, bpm: 90, notes: all, seconds: allSeconds)
        try await row("control-gm-trims0-all-v127", c4.1, c4.0)

        // ---- 2. A NEW drum machine as THIS tree births it (no kit given), the same beats.
        let n1 = try await DrumDefStage.newDrumMachine(kit: nil, bpm: 120, notes: normal, seconds: 6)
        try await row("newborn-normal", n1.1, n1.0)
        let n2 = try await DrumDefStage.newDrumMachine(kit: nil, bpm: 120, notes: at100, seconds: 6)
        try await row("newborn-v100", n2.1, n2.0)
        let n3 = try await DrumDefStage.newDrumMachine(kit: nil, bpm: 90, notes: loud, seconds: loudSeconds)
        try await row("newborn-v127", n3.1, n3.0)
        let n4 = try await DrumDefStage.newDrumMachine(kit: nil, bpm: 90, notes: all, seconds: allSeconds)
        try await row("newborn-all-v127", n4.1, n4.0)

        // ---- 3. The picks (23.4 / 5.7 / gm) at an explicit KIT GAIN: a sweep, numbers only.
        for gain in Self.quick ? [] : [1.0, 0.8, 0.75, 0.7, 0.65, 0.6, 0.5] {
            let swept = Self.kit(layout: .gm, hats: DrumKitParams.newKitHatsLevelDb,
                                 cymbals: DrumKitParams.newKitCymbalsLevelDb, gain: gain)
            let label = String(format: "%.2f", gain)
            let s1 = try await DrumDefStage.newDrumMachine(kit: swept, bpm: 120, notes: normal, seconds: 6)
            try await row("sweep-g\(label)-normal", s1.1, s1.0, wav: false)
            let s2 = try await DrumDefStage.newDrumMachine(kit: swept, bpm: 120, notes: at100, seconds: 6)
            try await row("sweep-g\(label)-v100", s2.1, s2.0, wav: false)
            let s3 = try await DrumDefStage.newDrumMachine(kit: swept, bpm: 90, notes: loud, seconds: loudSeconds)
            try await row("sweep-g\(label)-v127", s3.1, s3.0, wav: false)
            let s4 = try await DrumDefStage.newDrumMachine(kit: swept, bpm: 90, notes: all, seconds: allSeconds)
            try await row("sweep-g\(label)-all-v127", s4.1, s4.0, wav: false)
        }

        // ---- 3b. Each factory preset loaded onto a NEW drum machine (`applyingPreset`, the one home
        //          `instrument.loadDrumPreset` calls), at fader 1.0; and, for context, the same kit as it was
        //          before the headroom (`presetsBeforeHeadroom`).
        for (index, preset) in DrumKitParams.presets.enumerated() {
            let onNew = DrumKitParams.newDrumMachineKit.applyingPreset(preset)
            let old = DrumKitParams.newDrumMachineKit.applyingPreset(DrumKitParams.presetsBeforeHeadroom[index])
            let p1 = try await DrumDefStage.newDrumMachine(kit: onNew, bpm: 120, notes: normal, seconds: 6)
            try await row("preset-\(preset.name)-normal", p1.1, p1.0)
            let p2 = try await DrumDefStage.newDrumMachine(kit: onNew, bpm: 90, notes: loud, seconds: loudSeconds)
            try await row("preset-\(preset.name)-v127", p2.1, p2.0)
            let p3 = try await DrumDefStage.newDrumMachine(kit: onNew, bpm: 90, notes: all, seconds: allSeconds)
            try await row("preset-\(preset.name)-all-v127", p3.1, p3.0)
            let o1 = try await DrumDefStage.newDrumMachine(kit: old, bpm: 120, notes: normal, seconds: 6)
            try await row("preset-\(preset.name)-beforeheadroom-normal", o1.1, o1.0, wav: false)
            let o2 = try await DrumDefStage.newDrumMachine(kit: old, bpm: 90, notes: loud, seconds: loudSeconds)
            try await row("preset-\(preset.name)-beforeheadroom-v127", o2.1, o2.0, wav: false)
        }

        // ---- 4. Every built-in template with a drum machine: the drum track's kit (as saved JSON), its fader,
        //         and the export render, written for `cmp` between two trees.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let drumTemplates = DrumHeadStage.drumTemplates()
        #expect(!drumTemplates.isEmpty, "control: the catalog has drum templates")
        for (id, key) in drumTemplates {
            let t1 = try await DrumHeadStage.template(id, key: key, bpm: 120, notes: normal, seconds: 6)
            try await row("template-\(id)-normal", t1.2, t1.0, extra: ["fader": t1.1])
            let kitJSON = try encoder.encode(try #require(t1.0, "\(id) has no drum instrument"))
            try kitJSON.write(to: rig.out.appendingPathComponent("template-\(id)-instrument.json"))
            let t2 = try await DrumHeadStage.template(id, key: key, bpm: 90, notes: loud, seconds: loudSeconds)
            try await row("template-\(id)-v127", t2.2, t2.0, extra: ["fader": t2.1])
        }

        // ---- 5. Context only: the Mac's GM drum kit at fader 1.0, the same beats.
        for (name, notes, bpm, seconds) in Self.quick ? [] : [("macgm-normal", normal, 120.0, 6.0),
                                            ("macgm-v100", at100, 120.0, 6.0),
                                            ("macgm-v127", loud, 90.0, loudSeconds)] {
            if let audio = try await DrumHeadStage.macGMKit(bpm: bpm, notes: notes, seconds: seconds) {
                try await row(name, audio, nil)
            } else {
                rows.append(["name": name, "status": "the GM sound bank did not reach ready: CANNOT TELL"])
            }
        }

        let report: [String: Any] = ["phase": rig.phase, "renders": rows,
                                     "drumTemplates": drumTemplates.map { "\($0.id)/\($0.key)" }]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: rig.out.appendingPathComponent("measure.json"))
    }
}

/// W9-HEAD — the render half, ALWAYS ON (no env). A new drum machine's headroom is ONE
/// kit-wide level: every voice moves by exactly the same number of dB, so the hats-vs-snare
/// balance the user picked does not move; and a plain beat on a new song stays under
/// −1 dBTP through the export path, where the same kit at gain 1.0 did not. PHYSICS, never
/// distinctness.
@Suite("W9-HEAD a new drum machine has headroom (always on)")
struct DrumHeadroomRenderTests {
    /// The literal pick of this lane: kit gain 0.7, −3.098 dB.
    static let headroomDb = 20 * log10(0.7)

    private static func level(_ samples: [Float]) -> Double {
        var sum = 0.0
        for x in samples { sum += Double(x) * Double(x) }
        return 10 * log10(max(sum / Double(max(samples.count, 1)), 1e-30))
    }

    @Test("Every voice of a new drum machine sits exactly 3.1 dB under the picks at gain 1.0; the hats-vs-snare balance does not move")
    func everyVoiceMovesAlike() async throws {
        let born = try await DrumDefStage.pickedDrumMachine().resolvedDrumKit
        #expect(born.gain == 0.7)
        // The picks at kit gain 1.0: what a new drum machine was before the headroom.
        let unity = DrumDefBeats.explicitPickedKit
        #expect(unity.gain == 1.0)
        var bornLevels: [Double] = []
        var unityLevels: [Double] = []
        for voice in DrumVoice.allCases {
            let hit = [(Int(voice.primaryNote(in: .gm)), 0.25, 110)]
            let a = Self.level(try DrumDefStage.renderInstrumentAlone(kit: born, notes: hit, bpm: 120, seconds: 2))
            let b = Self.level(try DrumDefStage.renderInstrumentAlone(kit: unity, notes: hit, bpm: 120, seconds: 2))
            #expect(abs((a - b) - Self.headroomDb) < 0.01, "\(voice): moved \(a - b) dB, the headroom is \(Self.headroomDb)")
            #expect(b > -80, "control: \(voice) sounds")
            bornLevels.append(a)
            unityLevels.append(b)
        }
        // The balance the user picked: each hat and the cymbal against the snare, unchanged.
        let snare = try #require(DrumVoice.allCases.firstIndex(of: .snare))
        for voice in [DrumVoice.closedHat, .openHat, .cymbal] {
            let index = try #require(DrumVoice.allCases.firstIndex(of: voice))
            let newGap = bornLevels[index] - bornLevels[snare]
            let oldGap = unityLevels[index] - unityLevels[snare]
            #expect(abs(newGap - oldGap) < 0.01, "\(voice) vs snare: \(oldGap) dB became \(newGap) dB")
        }
    }

    @Test("A new drum machine on a new song plays the 808 audition beat under -1 dBTP, also with every hit at 127; at gain 1.0 it did not")
    func newSongBeatHasHeadroom() async throws {
        let normal = DrumDefBeats.templateBeat(bars: 2)
        let born = try await DrumDefStage.newDrumMachine(kit: nil, bpm: 120, notes: normal, seconds: 6)
        let unity = try await DrumDefStage.newDrumMachine(kit: DrumDefBeats.explicitPickedKit, bpm: 120,
                                                          notes: normal, seconds: 6)
        #expect(born.0?.drumKit?.gain == 0.7)
        // The app's own meter: BS.1770, 4x oversampled true peak.
        let tpBorn = try #require(Loudness.measure(born.1).truePeakDbtp)
        let tpUnity = try #require(Loudness.measure(unity.1).truePeakDbtp)
        #expect(tpBorn <= -1.0, "a new drum machine's beat peaks \(tpBorn) dBTP")
        #expect(tpUnity > -1.0, "control: the picks at gain 1.0 peak \(tpUnity) dBTP, so this gate could not fail")
        // One kit-wide gain: the true peak moves by exactly the headroom.
        #expect(abs((tpBorn - tpUnity) - Self.headroomDb) < 0.05, "moved \(tpBorn - tpUnity) dB")
        let loud = DrumDefBeats.templateBeat(bars: 8, velocity: 127)
        let bornLoud = try await DrumDefStage.newDrumMachine(kit: nil, bpm: 90, notes: loud,
                                                             seconds: 8 * 4 * 60.0 / 90 + 2)
        let tpLoud = try #require(Loudness.measure(bornLoud.1).truePeakDbtp)
        #expect(tpLoud <= -1.0, "with every hit at 127 a new drum machine peaks \(tpLoud) dBTP")
    }

    /// The orchestrator's rulings (B-prime, then acoustic's step): every factory preset carries the headroom, so
    /// LOADING one onto a new drum machine keeps the beat under −1 dBTP, and each sits exactly its gain step under
    /// the same kit as it was (3.1 dB; acoustic 4.0 dB, its 0.63 against its old 1.0).
    @Test("Each factory preset loaded onto a new drum machine plays the audition beat under -1 dBTP, its gain step under its old self")
    func presetsOnANewDrumMachineHaveHeadroom() async throws {
        let normal = DrumDefBeats.templateBeat(bars: 2)
        #expect(DrumKitParams.presets.count == 5)
        for (index, preset) in DrumKitParams.presets.enumerated() {
            let onNew = DrumKitParams.newDrumMachineKit.applyingPreset(preset)
            let old = DrumKitParams.newDrumMachineKit.applyingPreset(DrumKitParams.presetsBeforeHeadroom[index])
            let now = try await DrumDefStage.newDrumMachine(kit: onNew, bpm: 120, notes: normal, seconds: 6)
            let then = try await DrumDefStage.newDrumMachine(kit: old, bpm: 120, notes: normal, seconds: 6)
            let tpNow = try #require(Loudness.measure(now.1).truePeakDbtp)
            let tpThen = try #require(Loudness.measure(then.1).truePeakDbtp)
            #expect(tpNow <= -1.0, "\(preset.name) on a new drum machine peaks \(tpNow) dBTP")
            // One kit-wide gain: the true peak moves by exactly the gain step.
            let step = 20 * log10(onNew.gain / old.gain)
            #expect(step <= Self.headroomDb + 1e-9, "\(preset.name): a step of \(step) dB is not headroom")
            #expect(abs((tpNow - tpThen) - step) < 0.05,
                    "\(preset.name): moved \(tpNow - tpThen) dB, its gain step is \(step) dB")
        }
    }
}
