import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// W9-DRUMDEF (m39-hat-default + m39-dm-gm-default) — THE BEFORE/AFTER FILE GATE.
//
// The user picked, from the listening sets: a NEW drum machine plays its hi-hats and
// cymbals as loud as the Mac's own drum kit (`kit.hatsLevelDb` 23.4, `kit.cymbalsLevelDb`
// 5.7) and answers the standard General MIDI drum keys (`noteLayout` `gm`). Saved songs
// keep their sound exactly. Two of the three claims need TWO TREES to check (a render
// from before the change and one from after), so this suite writes files and the
// comparison (`cmp`) and the true-peak measure happen outside it.
//
// ENV-GATED: runs only with `DRUMDEF_GATE=1`.
//   - `DRUMDEF_DIR`: the gate's folder. Renders go to `<dir>/out/<DRUMDEF_PHASE>/`.
//   - `DRUMDEF_MAKE_FIXTURES=1` (the BEFORE run only): saves the two saved-song fixtures
//     to `<dir>/fixtures/`. Every later run OPENS THOSE SAME FILES through the real
//     project-open path. A fixture rebuilt by the new code would prove nothing.
//
// Deliberately NOT `@MainActor` (no new MainActor suite): `ProjectStore` and
// `OfflineRenderer` are `@MainActor`, so every store and render step runs inside one
// `@MainActor` helper per render (the `DrumListeningW4LTests` shape).

/// The beats the gate plays. Notes are absolute MIDI numbers, written ONCE here.
enum DrumDefBeats {
    /// The 808 template's audition beat (DemoRender's `Audition.notes(for: .drums)`,
    /// GM notes 36 kick, 38 snare, 42 closed hat, 46 open hat, 49 crash), at that
    /// pattern's own velocities, or every note at `velocity` when one is given.
    static func templateBeat(bars: Int, velocity: Int? = nil) -> [MIDINote] {
        var notes: [MIDINote] = []
        for bar in 0..<bars {
            let o = Double(bar * 4)
            for beat in [0.0, 2.0] {
                notes.append(MIDINote(pitch: 36, velocity: velocity ?? 110, startBeat: o + beat,
                                      lengthBeats: 0.25))
            }
            for beat in [1.0, 3.0] {
                notes.append(MIDINote(pitch: 38, velocity: velocity ?? 105, startBeat: o + beat,
                                      lengthBeats: 0.25))
            }
            for step in 0..<7 {
                notes.append(MIDINote(pitch: 42, velocity: velocity ?? (step % 2 == 0 ? 90 : 75),
                                      startBeat: o + Double(step) * 0.5, lengthBeats: 0.25))
            }
            notes.append(MIDINote(pitch: 46, velocity: velocity ?? 85, startBeat: o + 3.5,
                                  lengthBeats: 0.5))
            if bar % 4 == 0 {
                notes.append(MIDINote(pitch: 49, velocity: velocity ?? 100, startBeat: o,
                                      lengthBeats: 1))
            }
        }
        return notes
    }

    /// A saved song's beat: every drum in PAD order (notes 36-43, one per eighth, mixed
    /// velocities with accents at 127), plus two General MIDI notes a `pads` kit leaves
    /// SILENT (46 open hat, 49 crash). If a saved drum machine ever starts reading the
    /// `gm` layout, those two notes sound and every pad note moves drum.
    static func savedSongBeat(bars: Int) -> [MIDINote] {
        let velocities = [127, 96, 110, 70, 127, 88, 100, 64]
        var notes: [MIDINote] = []
        for bar in 0..<bars {
            let o = Double(bar * 4)
            for step in 0..<8 {
                notes.append(MIDINote(pitch: 36 + step, velocity: velocities[step],
                                      startBeat: o + Double(step) * 0.5, lengthBeats: 0.25))
            }
            notes.append(MIDINote(pitch: 46, velocity: 120, startBeat: o + 0.25, lengthBeats: 0.25))
            notes.append(MIDINote(pitch: 49, velocity: 120, startBeat: o + 2.25, lengthBeats: 0.5))
        }
        return notes
    }

    /// All eight drums struck at the same instant, once a bar, General MIDI notes
    /// (36 kick, 38 snare, 42 closed hat, 46 open hat, 39 clap, 45 tom, 37 rim, 49
    /// cymbal) — the loudest single moment the kit can make.
    static func allVoicesAtOnce(bars: Int, velocity: Int) -> [MIDINote] {
        var notes: [MIDINote] = []
        for bar in 0..<bars {
            for pitch in [36, 38, 42, 46, 39, 45, 37, 49] {
                notes.append(MIDINote(pitch: pitch, velocity: velocity, startBeat: Double(bar * 4),
                                      lengthBeats: 1))
            }
        }
        return notes
    }

    /// The kit the user picked, spelled out by hand: what a new drum machine must
    /// equal. Built from the factory kit with the three settings set explicitly, so it
    /// compiles and means the same thing on the tree before the change.
    static var explicitPickedKit: DrumKitParams {
        var kit = DrumKitParams()
        kit.noteLayout = .gm
        kit.hatsLevelDb = 23.4
        kit.cymbalsLevelDb = 5.7
        return kit
    }
}

/// Where the gate reads and writes.
struct DrumDefRig: Sendable {
    let dir: URL
    let phase: String

    var fixtures: URL { dir.appendingPathComponent("fixtures", isDirectory: true) }
    var out: URL { dir.appendingPathComponent("out/\(phase)", isDirectory: true) }
    var savedNilKit: URL { fixtures.appendingPathComponent("saved-nil-kit.dawproj") }
    var savedOldKit: URL { fixtures.appendingPathComponent("saved-old-kit.dawproj") }

    static func make() throws -> DrumDefRig {
        let env = ProcessInfo.processInfo.environment
        let dir = try #require(env["DRUMDEF_DIR"].flatMap { $0.isEmpty ? nil : $0 },
                               "DRUMDEF_DIR must name the gate's folder")
        let phase = try #require(env["DRUMDEF_PHASE"].flatMap { $0.isEmpty ? nil : $0 },
                                 "DRUMDEF_PHASE must name this run (before / after / a plant)")
        let rig = DrumDefRig(dir: URL(fileURLWithPath: dir, isDirectory: true), phase: phase)
        try FileManager.default.createDirectory(at: rig.out, withIntermediateDirectories: true)
        return rig
    }
}

/// What one saved-song render read back, beside its audio.
struct DrumDefOpened: Sendable {
    let instrument: InstrumentDescriptor?
    let audio: RenderedAudio
    /// The drum machine's OWN output (no mixer), interleaved L, R: separates a change in
    /// the kit from any change in the mixer path another lane might make.
    let raw: [Float]
}

@MainActor
enum DrumDefStage {
    nonisolated static let sampleRate = 48_000.0

    // MARK: Fixtures (BEFORE run only)

    /// A song saved with a drum machine that was never edited: `drumKit` is nil, so
    /// `project.json` carries NO `drumKit` key.
    static func makeSavedNilKitFixture(at url: URL) throws -> String {
        let store = ProjectStore(projectName: "DRUMDEF saved nil kit")
        let id = store.addTrack(name: "Drums", kind: .instrument).id
        _ = try store.setInstrument(id: id, kind: .drumSynth)
        let descriptor = try #require(store.tracks.first { $0.id == id }?.instrument)
        #expect(descriptor.drumKit == nil, "the BEFORE tree must save a never-edited drum machine with no kit")
        _ = try store.addMIDIClip(toTrack: id, name: "Beat", atBeat: 0, lengthBeats: 8,
                                  notes: DrumDefBeats.savedSongBeat(bars: 2))
        _ = try store.saveProject(to: url.path)
        return try String(contentsOf: url.appendingPathComponent("project.json"), encoding: .utf8)
    }

    /// A song saved with an edited kit from BEFORE the trims and the layout existed in
    /// its file: the lofi kit, `kick.decay` 1.3, the hat choke cleared. The encoder of
    /// the BEFORE tree omits a trim at 0 dB and a `pads` layout, so neither key is
    /// in `project.json`.
    static func makeSavedOldKitFixture(at url: URL) throws -> String {
        let store = ProjectStore(projectName: "DRUMDEF saved old kit")
        let id = store.addTrack(name: "Drums", kind: .instrument).id
        var kit = try #require(DrumKitParams.preset(named: "lofi")).params
        kit.setValue(1.3, forParamName: "kick.decay")
        kit.closedHat.chokeGroup = nil
        kit.openHat.chokeGroup = nil
        kit.hatsLevelDb = 0
        kit.cymbalsLevelDb = 0
        kit.noteLayout = .pads
        _ = try store.setInstrument(id: id, kind: .drumSynth, drumKit: kit)
        _ = try store.addMIDIClip(toTrack: id, name: "Beat", atBeat: 0, lengthBeats: 8,
                                  notes: DrumDefBeats.savedSongBeat(bars: 2))
        _ = try store.saveProject(to: url.path)
        return try String(contentsOf: url.appendingPathComponent("project.json"), encoding: .utf8)
    }

    // MARK: Births

    /// The instrument a drum machine picked on a fresh instrument track gets: the
    /// picker's and `track.setInstrument {kind: "drumSynth"}`'s path.
    static func pickedDrumMachine() throws -> InstrumentDescriptor {
        let store = ProjectStore()
        let id = store.addTrack(name: "Drums", kind: .instrument).id
        _ = try store.setInstrument(id: id, kind: .drumSynth)
        return try #require(store.tracks.first { $0.id == id }?.instrument)
    }

    // MARK: Renders

    /// Opens a saved song through the real open path and renders it, plus the drum
    /// machine's own output.
    static func openAndRender(_ url: URL, seconds: Double) throws -> DrumDefOpened {
        let store = ProjectStore()
        _ = try store.openProject(at: url.path)
        let track = try #require(store.tracks.first { $0.name == "Drums" })
        let audio = try render(store, seconds: seconds)
        let notes = track.clips.flatMap { clip in
            (clip.notes ?? []).map { (note: $0, start: clip.startBeat) }
        }
        let raw = try renderInstrumentAlone(
            kit: (track.instrument ?? .default).resolvedDrumKit,
            notes: notes.map { ($0.note.pitch, $0.start + $0.note.startBeat, $0.note.velocity) },
            bpm: store.transport.tempoBPM, seconds: seconds)
        return DrumDefOpened(instrument: track.instrument, audio: audio, raw: raw)
    }

    /// A NEW drum machine, born the way the picker and `track.setInstrument {kind:
    /// "drumSynth"}` birth one, or (with `kit`) born with that kit spelled out.
    static func newDrumMachine(kit: DrumKitParams?, bpm: Double, notes: [MIDINote],
                               seconds: Double) throws -> (InstrumentDescriptor?, RenderedAudio) {
        let store = ProjectStore(projectName: "DRUMDEF new drum machine")
        try store.setTempo(bpm)
        let id = store.addTrack(name: "Drums", kind: .instrument).id
        if let kit {
            _ = try store.setInstrument(id: id, kind: .drumSynth, drumKit: kit)
        } else {
            _ = try store.setInstrument(id: id, kind: .drumSynth)
        }
        let length = (notes.map(\.endBeat).max() ?? 4).rounded(.up)
        _ = try store.addMIDIClip(toTrack: id, name: "Beat", atBeat: 0, lengthBeats: length,
                                  notes: notes)
        let instrument = store.tracks.first { $0.id == id }?.instrument
        return (instrument, try render(store, seconds: seconds))
    }

    /// The Hip-Hop 808 built-in template, applied as the template picker applies it,
    /// with `notes` on its drum track.
    static func template808(bpm: Double, notes: [MIDINote],
                            seconds: Double) throws -> (InstrumentDescriptor?, RenderedAudio) {
        let store = ProjectStore(projectName: "DRUMDEF 808 template")
        try store.setTempo(bpm)
        let entry = try #require(BuiltInTemplateCatalog.load().templates.first { $0.id == "hip-hop-808" })
        let result = try store.applyTemplate(entry.template)
        let drumsID = try #require(result.tracks.first { $0.key == "drums" }?.id)
        let length = (notes.map(\.endBeat).max() ?? 4).rounded(.up)
        _ = try store.addMIDIClip(toTrack: drumsID, name: "Beat", atBeat: 0, lengthBeats: length,
                                  notes: notes)
        let instrument = store.tracks.first { $0.id == drumsID }?.instrument
        return (instrument, try render(store, seconds: seconds))
    }

    /// The export path: `OfflineRenderer`, the song's own tempo, meter and master.
    static func render(_ store: ProjectStore, seconds: Double) throws -> RenderedAudio {
        try OfflineRenderer().render(tracks: store.tracks, tempoMap: store.transport.tempoMap,
                                     fromBeat: 0, durationSeconds: seconds,
                                     masterVolume: store.masterVolume,
                                     masterEffects: store.masterEffects,
                                     meterMap: store.transport.meterMap)
    }

    static func write(_ audio: RenderedAudio, to url: URL) throws {
        _ = try OfflineRenderer.writeAudioFile(audio, to: url)
    }

    /// The drum machine ALONE, in 512-frame quanta (the `InstrumentRenderer` slicing),
    /// both channels interleaved L, R. `notes` are (pitch, absolute beat, velocity).
    nonisolated static func renderInstrumentAlone(kit: DrumKitParams, notes: [(Int, Double, Int)],
                                                  bpm: Double, seconds: Double) throws -> [Float] {
        let drums = DrumSynthInstrument(params: kit)
        drums.prepare(sampleRate: sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let secondsPerBeat = 60.0 / bpm
        let events = notes.enumerated().map { index, note in
            ScheduledMIDIEvent(sampleTime: Int64((note.1 * secondsPerBeat * sampleRate).rounded()),
                               noteID: UInt64(index + 1), kind: ScheduledMIDIEvent.noteOn,
                               pitch: UInt8(note.0), velocity: UInt8(note.2))
        }.sorted { ($0.sampleTime, $0.noteID) < ($1.sampleTime, $1.noteID) }
        let total = Int(seconds * sampleRate)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        let channels = try #require(buffer.floatChannelData)
        var out: [Float] = []
        out.reserveCapacity(total * 2)
        var cursor = 0, rendered = 0
        while rendered < total {
            let frames = min(512, total - rendered)
            buffer.frameLength = AVAudioFrameCount(frames)
            var end = cursor
            while end < events.count, events[end].sampleTime < Int64(rendered + frames) { end += 1 }
            let output = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            events.withUnsafeBufferPointer { all in
                drums.render(events: UnsafeBufferPointer(rebasing: all[cursor..<end]),
                             renderStart: Int64(rendered), frameCount: frames, output: output)
            }
            cursor = end
            for index in 0..<frames {
                out.append(channels[0][index])
                out.append(channels[1][index])
            }
            rendered += frames
        }
        return out
    }
}

/// Plain numbers about a render, for the log and `measure-<phase>.json`.
enum DrumDefMeasure {
    static func samplePeakDb(_ audio: RenderedAudio) -> Double {
        var peak: Float = 0
        for channel in audio.channelData { for x in channel { peak = max(peak, abs(x)) } }
        return 20 * log10(max(Double(peak), 1e-30))
    }

    static func rmsDb(_ audio: RenderedAudio) -> Double {
        var sum = 0.0, count = 0
        for channel in audio.channelData { for x in channel { sum += Double(x) * Double(x); count += 1 } }
        return 10 * log10(max(sum / Double(max(count, 1)), 1e-30))
    }

    /// FNV-1a over every sample's bit pattern: equal digests, equal samples.
    static func digest(_ samples: [Float]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for x in samples {
            var bits = x.bitPattern
            for _ in 0..<4 {
                hash ^= UInt64(bits & 0xff)
                hash = hash &* 0x0000_0100_0000_01b3
                bits >>= 8
            }
        }
        return String(hash, radix: 16)
    }

    static func digest(_ audio: RenderedAudio) -> String { digest(audio.channelData.flatMap { $0 }) }

    static func writeRaw(_ samples: [Float], to url: URL) throws {
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: url)
    }
}

@Suite("W9-DRUMDEF new drum machine defaults — before/after file gate (DRUMDEF_GATE=1 only)")
struct DrumNewKitDefaultGateTests {
    static let enabled = ProcessInfo.processInfo.environment["DRUMDEF_GATE"] == "1"
    static let makeFixtures = ProcessInfo.processInfo.environment["DRUMDEF_MAKE_FIXTURES"] == "1"

    @Test("DRUMDEF: saved songs, a new drum machine, and the true-peak renders, written for cmp",
          .enabled(if: DrumNewKitDefaultGateTests.enabled))
    func writeGateRenders() async throws {
        let rig = try DrumDefRig.make()
        var report: [String: Any] = ["phase": rig.phase]

        // ---- The two saved-song fixtures: written ONCE, by the BEFORE run.
        if Self.makeFixtures {
            try FileManager.default.createDirectory(at: rig.fixtures, withIntermediateDirectories: true)
            for url in [rig.savedNilKit, rig.savedOldKit] {
                #expect(FileManager.default.fileExists(atPath: url.path) == false,
                        "\(url.lastPathComponent) exists: fixtures are made ONCE, by the before run")
            }
            let nilKitJSON = try await DrumDefStage.makeSavedNilKitFixture(at: rig.savedNilKit)
            #expect(nilKitJSON.contains("\"drumSynth\""), "the fixture has a drum machine")
            #expect(nilKitJSON.contains("drumKit") == false, "the never-edited fixture saved a drumKit key")
            let oldKitJSON = try await DrumDefStage.makeSavedOldKitFixture(at: rig.savedOldKit)
            #expect(oldKitJSON.contains("\"drumKit\""), "the edited fixture saved its kit")
            for key in ["hatsLevelDb", "cymbalsLevelDb", "noteLayout"] {
                #expect(oldKitJSON.contains(key) == false, "the old-kit fixture carries \(key)")
            }
        }
        for url in [rig.savedNilKit, rig.savedOldKit] {
            try #require(FileManager.default.fileExists(atPath: url.appendingPathComponent("project.json").path),
                         "missing fixture \(url.lastPathComponent): run the before phase with DRUMDEF_MAKE_FIXTURES=1")
        }

        // ---- Saved songs: open, render, write. (The cmp against the before run is the gate.)
        var rows: [[String: Any]] = []
        func row(_ name: String, _ audio: RenderedAudio, _ instrument: InstrumentDescriptor?,
                 raw: [Float]? = nil) async throws {
            try await DrumDefStage.write(audio, to: rig.out.appendingPathComponent("\(name).wav"))
            // The app's own BS.1770 meter: 4x oversampled true peak (`Loudness.truePeakLinear`).
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
            }
            if let raw {
                try DrumDefMeasure.writeRaw(raw, to: rig.out.appendingPathComponent("\(name).raw.f32"))
                entry["rawDigest"] = DrumDefMeasure.digest(raw)
            }
            #expect(DrumDefMeasure.samplePeakDb(audio) > -60, "\(name) is silent")
            rows.append(entry)
        }

        let nilKit = try await DrumDefStage.openAndRender(rig.savedNilKit, seconds: 6)
        try await row("saved-nil-kit", nilKit.audio, nilKit.instrument, raw: nilKit.raw)
        let oldKit = try await DrumDefStage.openAndRender(rig.savedOldKit, seconds: 6)
        try await row("saved-old-kit", oldKit.audio, oldKit.instrument, raw: oldKit.raw)
        // ⛔ A byte gate is blind to a decode default: the decoded VALUES, read back.
        #expect(nilKit.instrument?.kind == .drumSynth && nilKit.instrument?.drumKit == nil,
                "the never-edited fixture opened with a kit")
        for (name, opened) in [("saved-nil-kit", nilKit), ("saved-old-kit", oldKit)] {
            let kit = (opened.instrument ?? .default).resolvedDrumKit
            #expect(kit.hatsLevelDb == 0 && kit.cymbalsLevelDb == 0, "\(name): trims \(kit.hatsLevelDb)/\(kit.cymbalsLevelDb)")
            #expect(kit.noteLayout == .pads, "\(name): layout \(kit.noteLayout)")
        }

        // ---- A NEW drum machine, and the same machine with the picked kit spelled out.
        let beat = DrumDefBeats.templateBeat(bars: 2)
        let newborn = try await DrumDefStage.newDrumMachine(kit: nil, bpm: 120, notes: beat, seconds: 6)
        try await row("newborn-beat", newborn.1, newborn.0)
        let explicit = try await DrumDefStage.newDrumMachine(kit: DrumDefBeats.explicitPickedKit, bpm: 120,
                                                             notes: beat, seconds: 6)
        try await row("explicit-beat", explicit.1, explicit.0)

        // ---- True peak: velocity 127 (accents on: the kit's threshold is 100), 90 BPM.
        let loud = DrumDefBeats.templateBeat(bars: 8, velocity: 127)
        let seconds = 8 * 4 * 60.0 / 90 + 2
        let tpTemplate = try await DrumDefStage.template808(bpm: 90, notes: loud, seconds: seconds)
        try await row("tp-808-template-v127", tpTemplate.1, tpTemplate.0)
        let tpNewborn = try await DrumDefStage.newDrumMachine(kit: nil, bpm: 90, notes: loud,
                                                              seconds: seconds)
        try await row("tp-plain-newborn-v127", tpNewborn.1, tpNewborn.0)
        let tpExplicit = try await DrumDefStage.newDrumMachine(kit: DrumDefBeats.explicitPickedKit, bpm: 90,
                                                               notes: loud, seconds: seconds)
        try await row("tp-plain-explicit-v127", tpExplicit.1, tpExplicit.0)
        let all = DrumDefBeats.allVoicesAtOnce(bars: 4, velocity: 127)
        let allSeconds = 4 * 4 * 60.0 / 90 + 2
        let tpAllNewborn = try await DrumDefStage.newDrumMachine(kit: nil, bpm: 90, notes: all,
                                                                 seconds: allSeconds)
        try await row("tp-all-voices-newborn-v127", tpAllNewborn.1, tpAllNewborn.0)
        let tpAllExplicit = try await DrumDefStage.newDrumMachine(kit: DrumDefBeats.explicitPickedKit, bpm: 90,
                                                                  notes: all, seconds: allSeconds)
        try await row("tp-all-voices-explicit-v127", tpAllExplicit.1, tpAllExplicit.0)
        // Controls: the SAME General MIDI kit with both trims at 0 dB, so the trims' own share of any
        // overshoot is a measured difference, never a guess.
        var gmTrims0 = DrumDefBeats.explicitPickedKit
        gmTrims0.hatsLevelDb = 0
        gmTrims0.cymbalsLevelDb = 0
        let tpPlainControl = try await DrumDefStage.newDrumMachine(kit: gmTrims0, bpm: 90, notes: loud,
                                                                   seconds: seconds)
        try await row("tp-plain-gm-trims0-v127", tpPlainControl.1, tpPlainControl.0)
        let tpAllControl = try await DrumDefStage.newDrumMachine(kit: gmTrims0, bpm: 90, notes: all,
                                                                 seconds: allSeconds)
        try await row("tp-all-voices-gm-trims0-v127", tpAllControl.1, tpAllControl.0)

        report["renders"] = rows
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: rig.out.appendingPathComponent("measure.json"))
    }
}

/// The render half of "a new drum machine starts with the picks", ALWAYS ON (no env): a drum machine born the
/// way the picker births one renders bit-identically to the picked kit spelled out, and against the factory kit
/// the picks move exactly what they name. PHYSICS, never distinctness.
@Suite("W9-DRUMDEF a new drum machine renders the picks (always on)")
struct DrumNewKitDefaultRenderTests {

    private static func level(_ samples: [Float]) -> Double {
        var sum = 0.0
        for x in samples { sum += Double(x) * Double(x) }
        return 10 * log10(max(sum / Double(max(samples.count, 1)), 1e-30))
    }

    /// One note, alone, as (pitch, beat, velocity).
    private static func hit(_ pitch: Int, velocity: Int = 110) -> [(Int, Double, Int)] { [(pitch, 0.25, velocity)] }

    @Test("A drum machine picked on a fresh track renders bit-identically to 23.4 / 5.7 / gm / kit gain 0.7 spelled out")
    func bornRendersAsThePicks() async throws {
        let born = try await DrumDefStage.pickedDrumMachine()
        #expect(born.drumKit != nil, "the new kit was not written into the track")
        let beat = DrumDefBeats.templateBeat(bars: 2).map { ($0.pitch, $0.startBeat, $0.velocity) }
        // W9-HEAD: a new drum machine also starts at kit gain 0.7 (headroom).
        var picked = DrumDefBeats.explicitPickedKit
        picked.gain = 0.7
        let a = try DrumDefStage.renderInstrumentAlone(kit: born.resolvedDrumKit, notes: beat, bpm: 120, seconds: 5)
        let b = try DrumDefStage.renderInstrumentAlone(kit: picked, notes: beat,
                                                       bpm: 120, seconds: 5)
        let same = a.count == b.count && zip(a, b).allSatisfy { $0.bitPattern == $1.bitPattern }
        #expect(same, "a new drum machine does not render as the picked kit")
        #expect(Self.level(a) > -60, "control: the beat sounds")
    }

    @Test("Against the factory kit at the same kit gain: the kick does not move a bit; the hats rise 23.4 dB, the cymbal 5.7 dB")
    func picksMoveOnlyWhatTheyName() async throws {
        let born = try await DrumDefStage.pickedDrumMachine().resolvedDrumKit
        // W9-HEAD: the factory kit at a new drum machine's kit gain (0.7), so this still isolates the PICKS;
        // the gain's own move, on every voice alike, is `DrumHeadroomRenderTests.everyVoiceMovesAlike`.
        var factory = DrumKitParams()
        factory.gain = 0.7
        // The kick is note 36 in both layouts and no trim reaches it: bit-identical.
        let kickNew = try DrumDefStage.renderInstrumentAlone(kit: born, notes: Self.hit(36), bpm: 120, seconds: 1.5)
        let kickOld = try DrumDefStage.renderInstrumentAlone(kit: factory, notes: Self.hit(36), bpm: 120, seconds: 1.5)
        #expect(kickNew.count == kickOld.count
                    && zip(kickNew, kickOld).allSatisfy { $0.bitPattern == $1.bitPattern },
                "the kick changed")
        // Each trimmed drum, at ITS note in each kit's own layout: louder by exactly the pick.
        for (voice, pick) in [(DrumVoice.closedHat, 23.4), (.openHat, 23.4), (.cymbal, 5.7)] {
            let newNote = Int(voice.primaryNote(in: born.noteLayout))
            let oldNote = Int(voice.primaryNote(in: factory.noteLayout))
            let louder = try DrumDefStage.renderInstrumentAlone(kit: born, notes: Self.hit(newNote),
                                                                bpm: 120, seconds: 2)
            let today = try DrumDefStage.renderInstrumentAlone(kit: factory, notes: Self.hit(oldNote),
                                                               bpm: 120, seconds: 2)
            let rise = Self.level(louder) - Self.level(today)
            #expect(abs(rise - pick) < 0.01, "\(voice): rose \(rise) dB, the pick is \(pick)")
            #expect(Self.level(today) > -80, "control: \(voice) sounds in the factory kit")
        }
        // The layout: General MIDI 38 is the SNARE on a new drum machine (on the factory kit it is the closed hat).
        #expect(DrumVoice.voice(forNote: 38, layout: born.noteLayout) == .snare)
        #expect(DrumVoice.voice(forNote: 38, layout: factory.noteLayout) == .closedHat)
    }
}
