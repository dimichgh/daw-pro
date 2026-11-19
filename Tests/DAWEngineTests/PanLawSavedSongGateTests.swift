import AVFAudio
import CryptoKit
import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

// m39-panlaw-new (W9-PANLAW) — THE SAVED-SONG BYTE GATE.
//
// The user's pick (2026-10-07, "One rule for new songs only"): songs already made keep their sound EXACTLY. A song
// made before the pan rule existed has no pan-rule key in its file, so this gate builds such songs ONCE, on the tree
// BEFORE the change (PANLAW_PHASE=before), and keeps the bundles. Every later phase OPENS THOSE SAME BUNDLES through
// `ProjectStore.openProject` and renders them through the store and a real `AudioEngine` (`renderBounce`, and the
// stems of one project), then compares every file byte for byte with the before capture. It never rebuilds the
// fixtures, so a change in how a song is SAVED cannot hide a change in how it SOUNDS.
//
// Fixtures: the pan knob at -1.0/-0.4/+0.4/+1.0 on a one-channel file and on a true stereo file (different content
// left and right); a moving pan lane; a constant pan lane; a pan wobble (an LFO route on pan, knob 0.4 as its base);
// an instrument strip and a bus strip with the knob off centre; and one mix (audio + instrument + bus + a send) that
// also renders stems.
//
// Env-gated: PANLAW_GATE_DIR=<dir> PANLAW_PHASE=before|after|<plant label>. `before` refuses to run twice (the
// capture is the reference) and renders everything twice (a determinism control: the gate is worthless if a render
// is not reproducible). Any other phase renders into <dir>/<phase>/ and #expects every file equal to <dir>/before/.
// The BEFORE capture ran this file's fixture and render code on the tree without the pan rule (2026-10-11, W9-PANLAW
// `$S/w9/PANLAW/`); the only lines added since are the decoded-value asserts (`storeLaw` / `engineLaw`), which a
// byte gate cannot replace: it cannot see a decode default.

private enum PanLawGateError: Error {
    case setup(String)
}

@MainActor
enum PanLawGate {
    static let sampleRate = 48_000.0
    static let renderSeconds = 1.25
    static let sourceSeconds = 1.5

    static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// A fixed UUID per name, so the fixtures are reproducible (the CR0 recipe).
    static func id(_ key: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data("dawpro-panlaw/\(key)".utf8)))
        var b = Array(digest.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x40
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    // MARK: Source media

    /// One-channel 1 kHz sine (amp 0.5) or a true stereo pair (left 440 Hz amp 0.5, right 660 Hz amp 0.3).
    static func writeSource(_ url: URL, channels: Int) throws {
        let count = Int(sourceSeconds * sampleRate)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels)),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let data = buffer.floatChannelData else { throw PanLawGateError.setup("source buffer") }
        buffer.frameLength = AVAudioFrameCount(count)
        for frame in 0..<count {
            let t = Double(frame) / sampleRate
            if channels == 1 {
                data[0][frame] = Float(0.5 * sin(2 * Double.pi * 1_000 * t))
            } else {
                data[0][frame] = Float(0.5 * sin(2 * Double.pi * 440 * t))
                data[1][frame] = Float(0.3 * sin(2 * Double.pi * 660 * t))
            }
        }
        try file.write(from: buffer)
    }

    // MARK: Fixture songs (built once, by the BEFORE phase)

    static func clip(_ key: String, _ url: URL) -> Clip {
        Clip(id: id("\(key).clip"), name: "\(key) clip", startBeat: 0, lengthBeats: 2.5, audioFileURL: url)
    }

    static func notes(_ key: String) -> [MIDINote] {
        let pitches = [48, 55, 60, 64, 67]
        return (0..<5).map { i in
            MIDINote(id: id("\(key).note\(i)"), pitch: pitches[i], velocity: 96,
                     startBeat: Double(i) * 0.5, lengthBeats: 0.45)
        }
    }

    static func songs(mono: URL, stereo: URL) -> [(name: String, tracks: [Track])] {
        var songs: [(name: String, tracks: [Track])] = []
        for (label, url) in [("mono", mono), ("stereo", stereo)] {
            for pan in [-1.0, -0.4, 0.4, 1.0] {
                let key = "knob-\(label)-\(pan < 0 ? "m" : "p")\(String(format: "%.1f", abs(pan)))"
                songs.append((key, [Track(id: id("\(key).track"), name: key, kind: .audio, pan: pan,
                                          clips: [clip(key, url)])]))
            }
        }
        // A moving pan lane (left → 0.4 → right) over a knob the lane overrides while the song plays.
        let movingLane = AutomationLane(id: id("lane-moving.lane"), target: .pan, points: [
            AutomationPoint(beat: 0, value: -1.0), AutomationPoint(beat: 1.0, value: 0.4),
            AutomationPoint(beat: 2.5, value: 1.0)])
        songs.append(("lane-moving-mono", [Track(id: id("lane-moving.track"), name: "lane moving", kind: .audio,
                                                 pan: 0.25, clips: [clip("lane-moving", mono)],
                                                 automation: [movingLane])]))
        let constLane = AutomationLane(id: id("lane-const.lane"), target: .pan, points: [
            AutomationPoint(beat: 0, value: 0.4), AutomationPoint(beat: 2.5, value: 0.4)])
        songs.append(("lane-const-stereo", [Track(id: id("lane-const.track"), name: "lane const", kind: .audio,
                                                  clips: [clip("lane-const", stereo)], automation: [constLane])]))
        // A pan wobble: an LFO route on pan, the knob (0.4) as its base.
        let lfo = ModulationSource(id: id("wobble.lfo"), kind: .lfo,
                                   params: .lfo(LFOSourceParams(waveform: .sine, rateHz: 3)))
        let route = ModulationRoute(id: id("wobble.route"), sourceID: lfo.id, target: .pan, depth: 0.5)
        songs.append(("wobble-mono", [Track(id: id("wobble.track"), name: "wobble", kind: .audio, pan: 0.4,
                                            clips: [clip("wobble", mono)],
                                            modulationSources: [lfo], modulationRoutes: [route])]))
        // An instrument strip with the knob off centre.
        songs.append(("instrument-knob", [Track(id: id("instrument.track"), name: "synth", kind: .instrument,
                                                pan: -0.4,
                                                clips: [Clip(id: id("instrument.clip"), name: "notes",
                                                             startBeat: 0, lengthBeats: 2.5,
                                                             notes: notes("instrument"))],
                                                instrument: InstrumentDescriptor(kind: .polySynth))]))
        // A bus strip with the knob off centre, fed by an audio strip that is panned too.
        let busID = id("bus.track")
        songs.append(("bus-knob", [
            Track(id: id("bus.feed"), name: "feed", kind: .audio, pan: 0.4, clips: [clip("bus-feed", stereo)],
                  outputBusID: busID),
            Track(id: busID, name: "bus", kind: .bus, pan: -1.0),
        ]))
        // The mix: audio + instrument + bus + a send, every knob off centre. Also renders stems.
        let mixBus = id("mix.bus")
        songs.append(("mix-all", [
            Track(id: id("mix.vox"), name: "vox", kind: .audio, volume: 0.8, pan: -0.4,
                  clips: [clip("mix-vox", mono)],
                  sends: [Send(id: id("mix.send"), destinationBusID: mixBus, level: 0.5)]),
            Track(id: id("mix.gtr"), name: "gtr", kind: .audio, pan: 1.0, clips: [clip("mix-gtr", stereo)]),
            Track(id: id("mix.synth"), name: "synth", kind: .instrument, pan: 0.4,
                  clips: [Clip(id: id("mix.synth.clip"), name: "notes", startBeat: 0, lengthBeats: 2.5,
                               notes: notes("mix"))],
                  instrument: InstrumentDescriptor(kind: .polySynth)),
            Track(id: mixBus, name: "fx bus", kind: .bus, pan: -1.0),
        ]))
        return songs
    }

    static func makeFixtures(in fixtures: URL) throws -> [String] {
        let media = fixtures.deletingLastPathComponent().appendingPathComponent("source-media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        let mono = media.appendingPathComponent("mono-1k.wav")
        let stereo = media.appendingPathComponent("stereo-440-660.wav")
        try writeSource(mono, channels: 1)
        try writeSource(stereo, channels: 2)
        var names: [String] = []
        for song in songs(mono: mono, stereo: stereo) {
            let store = ProjectStore(projectName: song.name)
            store.tracks = song.tracks
            _ = try store.saveProject(to: fixtures.appendingPathComponent("\(song.name).dawproj").path)
            names.append(song.name)
        }
        return names
    }

    // MARK: Render one saved song through the store and a real engine

    struct Rendered {
        var files: [URL]
        var peaks: [Float]
        /// The DECODED pan rule after the open (a byte gate cannot see a decode default), store and engine.
        var storeLaw: PanLaw
        var engineLaw: PanLaw
    }

    static func render(bundle: URL, into directory: URL) async throws -> Rendered {
        let name = bundle.deletingPathExtension().lastPathComponent
        let engine = AudioEngine()
        let store = ProjectStore()
        store.engine = engine
        _ = try store.openProject(at: bundle.path, discardChanges: true)
        let laws = (store.panLaw, engine.panLaw)
        var files: [URL] = []
        let bounce = directory.appendingPathComponent("\(name).wav")
        _ = try await store.renderBounce(toPath: bounce.path, fromBeat: 0, durationSeconds: renderSeconds)
        files.append(bounce)
        if name == "mix-all" {
            let stems = directory.appendingPathComponent("\(name)-stems", isDirectory: true)
            let result = try await store.renderStems(toDirectory: stems.path, durationSeconds: renderSeconds,
                                                     includeMixdown: true)
            files += result.stems.map { URL(fileURLWithPath: $0.path) }
            if let mixdown = result.mixdown { files.append(URL(fileURLWithPath: mixdown.path)) }
        }
        withExtendedLifetime(engine) {}
        var peaks: [Float] = []
        for file in files {
            let channels = try TestSignals.readFile(file)
            peaks.append(channels.map { $0.map(abs).max() ?? 0 }.max() ?? 0)
        }
        return Rendered(files: files, peaks: peaks, storeLaw: laws.0, engineLaw: laws.1)
    }

    static func renderAll(fixtures: URL, into directory: URL) async throws -> [(String, Rendered)] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bundles = try FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "dawproj" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var out: [(String, Rendered)] = []
        for bundle in bundles {
            out.append((bundle.deletingPathExtension().lastPathComponent,
                        try await render(bundle: bundle, into: directory)))
        }
        return out
    }

    /// Relative path of `file` under `root` (stems live one folder down).
    static func relative(_ file: URL, to root: URL) -> String {
        String(file.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
    }

    static func run() async throws {
        guard let dirPath = environment["PANLAW_GATE_DIR"], !dirPath.isEmpty else { return }
        let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
        let phase = environment["PANLAW_PHASE"] ?? "check"
        let fixtures = dir.appendingPathComponent("fixtures", isDirectory: true)
        let before = dir.appendingPathComponent("before", isDirectory: true)
        var manifest: [String] = ["phase \(phase)"]
        if phase == "before" {
            #expect(!FileManager.default.fileExists(atPath: fixtures.path),
                    "the BEFORE capture runs once; \(fixtures.path) already exists")
            guard !FileManager.default.fileExists(atPath: fixtures.path) else { return }
            let names = try makeFixtures(in: fixtures)
            manifest.append("fixtures \(names.count): \(names.joined(separator: " "))")
        } else {
            #expect(FileManager.default.fileExists(atPath: before.path), "no BEFORE capture at \(before.path)")
        }
        // Decoded-shape control: no fixture's project.json carries a pan-rule key (they are saved songs).
        let bundles = try FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "dawproj" }
        #expect(bundles.count == 14, "fixture count \(bundles.count)")
        for bundle in bundles {
            let json = try String(contentsOf: bundle.appendingPathComponent("project.json"), encoding: .utf8)
            #expect(!json.contains("panLaw"), "\(bundle.lastPathComponent) carries a pan-rule key")
            #expect(json.contains("\"pan\""), "control: \(bundle.lastPathComponent) has no pan key at all")
        }
        let target = dir.appendingPathComponent(phase, isDirectory: true)
        let rendered = try await renderAll(fixtures: fixtures, into: target)
        for (name, r) in rendered {
            #expect(r.storeLaw == .balance && r.engineLaw == .balance,
                    "\(name): a saved song opened on \(r.storeLaw) / engine \(r.engineLaw), not the original rule")
            manifest.append("decoded \(name): store \(r.storeLaw), engine \(r.engineLaw)")
            for (file, peak) in zip(r.files, r.peaks) {
                #expect(peak > 0.01, "\(name): \(file.lastPathComponent) is silent (peak \(peak))")
                manifest.append("render \(relative(file, to: target)) peak \(peak)")
            }
        }
        if phase == "before" {
            // Determinism control: a second render of every song must be byte-identical to the first.
            let repeatDir = dir.appendingPathComponent("before-repeat", isDirectory: true)
            let again = try await renderAll(fixtures: fixtures, into: repeatDir)
            var nondeterministic: [String] = []
            for (_, r) in again {
                for file in r.files {
                    let rel = relative(file, to: repeatDir)
                    if try Data(contentsOf: file) != Data(contentsOf: target.appendingPathComponent(rel)) {
                        nondeterministic.append(rel)
                    }
                }
            }
            manifest.append("determinism control: \(nondeterministic.isEmpty ? "all identical" : nondeterministic.joined(separator: " "))")
            #expect(nondeterministic.isEmpty, "renders are not reproducible: \(nondeterministic)")
        } else {
            var differ: [String] = []
            var same = 0
            for (_, r) in rendered {
                for file in r.files {
                    let rel = relative(file, to: target)
                    let reference = before.appendingPathComponent(rel)
                    guard FileManager.default.fileExists(atPath: reference.path) else {
                        differ.append("\(rel) (no before file)")
                        continue
                    }
                    if try Data(contentsOf: file) == Data(contentsOf: reference) { same += 1 } else { differ.append(rel) }
                }
            }
            manifest.append("byte-identical to before: \(same); differ: \(differ.isEmpty ? "none" : differ.joined(separator: " "))")
            #expect(differ.isEmpty, "saved songs changed sound: \(differ)")
            #expect(same >= 14, "compared only \(same) files")
        }
        try (manifest.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent("manifest-\(phase).txt"), atomically: true, encoding: .utf8)
        print("[PANLAW] " + manifest.joined(separator: "\n[PANLAW] "))
    }
}

@Suite("m39-panlaw-new: saved songs keep their sound (PANLAW_GATE_DIR)", .serialized)
struct PanLawSavedSongGateTests {
    @Test("Saved songs render byte-identical before vs after the pan-rule change (PANLAW_GATE_DIR, PANLAW_PHASE)",
          .enabled(if: ProcessInfo.processInfo.environment["PANLAW_GATE_DIR"] != nil))
    func savedSongByteGate() async throws {
        try await PanLawGate.run()
    }
}
