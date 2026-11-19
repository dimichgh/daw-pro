import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// W9-MIDIB: how well does the app's OWN "sung audio -> notes" path recover KNOWN notes?
//
// This file only RUNS the product path and writes what it found; the scoring (mir_eval, note-level P/R/F1) and the
// Basic Pitch yardstick live outside the repo, in the lane's scratch folder. The product path, call for call:
//   1. `ClipPitchAnalyzer.detect(fileAt:fromSeconds:durationSeconds:confidenceThreshold:silenceFloorDbfs:)` with the
//      product defaults `PitchDetectionDefaults.defaultConfidenceThreshold` (0.9) and `.defaultSilenceFloorDbfs` (-75),
//      the call `AudioEngine.detectPitch` makes, over the whole file;
//   2. `PitchNoteTable.build(from:)`, the table the pitch editor draws (`PitchEditorModel.apply` seeds it through
//      `PitchNoteTable.detected`, which forwards here): `PitchNoteSplitter.parts` plus the unpitched sounds.
// Nothing here re-decides where a note starts or what its pitch is.
//
// ENV-GATED: every test is skipped unless `MIDIB=1`.
//   - `MIDIB_OUT`: the output folder (required).
//   - `MIDIB_MANIFEST`: a JSON array of {"label": String, "path": String}; one product run per file.
//   - `MIDIB_REPEAT`: extra timed runs per file after the first (default 0). The first call is reported on its own.
//   - `MIDIB_RENDER=1`: also render the multi-instrument fixtures (known MIDI through the Mac's General MIDI bank).
// Deliberately NOT `@MainActor` (the suite cap): the render step hops to a `@MainActor` helper.

enum VocalNoteScoreRig {
    static let env = ProcessInfo.processInfo.environment
    static let enabled = env["MIDIB"] == "1"
    static let renders = env["MIDIB_RENDER"] == "1"

    static func outDir() throws -> URL {
        let path = try #require(env["MIDIB_OUT"].flatMap { $0.isEmpty ? nil : $0 }, "MIDIB_OUT must name a folder")
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func writeJSON(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    static func nanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    static func fileSeconds(_ url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// One product run: the detection, then the table, each timed on the wall clock.
    static func productRun(_ url: URL) throws -> (json: [String: Any], detectSeconds: Double, buildSeconds: Double) {
        let seconds = try fileSeconds(url)
        let t0 = nanos()
        let result = try ClipPitchAnalyzer.detect(
            fileAt: url, fromSeconds: 0, durationSeconds: seconds,
            confidenceThreshold: PitchDetectionDefaults.defaultConfidenceThreshold,
            silenceFloorDbfs: PitchDetectionDefaults.defaultSilenceFloorDbfs)
        let t1 = nanos()
        let table = PitchNoteTable.build(from: result)
        let t2 = nanos()
        let detectSeconds = Double(t1 - t0) / 1e9
        let buildSeconds = Double(t2 - t1) / 1e9
        let frames: [[Any]] = result.frames.map { frame in
            let hz: Any = frame.frequencyHz.map { $0 as Any } ?? NSNull()
            let level: Any = frame.levelDbfs.map { $0 as Any } ?? NSNull()
            return [frame.timeSeconds, hz, frame.confidence, level]
        }
        let segments: [[String: Any]] = table.editSet.segments.map { segment in
            ["start": segment.startSeconds, "end": segment.endSeconds, "hz": segment.detectedHz,
             "confidence": segment.detectedConfidence, "origin": segment.origin.rawValue]
        }
        let json: [String: Any] = [
            "file": url.path, "fileSeconds": seconds,
            "frameRateHz": result.frameRateHz, "frameCount": result.frameCount,
            "voicedFrameCount": result.voicedFrameCount, "voicedFraction": result.voicedFraction,
            "confidenceThreshold": result.confidenceThreshold, "silenceFloorDbfs": result.silenceFloorDbfs,
            "minFrequencyHz": result.minFrequencyHz, "maxFrequencyHz": result.maxFrequencyHz,
            "detectSeconds": detectSeconds, "buildSeconds": buildSeconds,
            "frameColumns": ["timeSeconds", "frequencyHz", "confidence", "levelDbfs"],
            "frames": frames, "segments": segments,
        ]
        return (json, detectSeconds, buildSeconds)
    }
}

/// The multi-instrument fixtures' notes (pure data, no actor).
enum VocalNoteScoreFixtures {
    static let bpm = 100.0
    static let seconds = 21.0

    /// "Light On" (the voice film's lead, the MF lane's `MFSong`), moved 8 beats earlier: the first note at beat 0.5.
    static func melody() -> [MIDINote] {
        MFSong.notes().map { MIDINote(pitch: $0.pitch, velocity: 96, startBeat: $0.startBeat - 8,
                                      lengthBeats: $0.lengthBeats) }
    }

    /// One chord every 2 beats (16 over 32 beats), struck as a 3-note block, 1.9 beats long.
    static let chordNames = ["D", "Bm", "G", "A", "D", "Bm", "G", "A", "Bm", "G", "D", "A", "G", "A", "D", "D"]
    static let voicing: [String: [Int]] = ["D": [50, 54, 57], "Bm": [47, 50, 54], "G": [47, 50, 55], "A": [49, 52, 57]]
    static let root: [String: Int] = ["D": 38, "Bm": 35, "G": 31, "A": 33]

    static func chords() -> [MIDINote] {
        chordNames.enumerated().flatMap { index, name in
            (voicing[name] ?? []).map { MIDINote(pitch: $0, velocity: 84, startBeat: Double(index) * 2, lengthBeats: 1.9) }
        }
    }

    /// Two bass notes per chord (beats 0 and 1 of its 2), 0.9 beats long.
    static func bass() -> [MIDINote] {
        chordNames.enumerated().flatMap { index, name in
            [0.0, 1.0].map { MIDINote(pitch: root[name] ?? 38, velocity: 100, startBeat: Double(index) * 2 + $0,
                                      lengthBeats: 0.9) }
        }
    }

    /// GM drums: kick on beats 0 and 2 of each bar, snare on 1 and 3, closed hat on every eighth.
    static func drums() -> [MIDINote] {
        var out: [MIDINote] = []
        for bar in 0..<8 {
            let b = Double(bar) * 4
            for k in [0.0, 2.0] { out.append(MIDINote(pitch: 36, velocity: 110, startBeat: b + k, lengthBeats: 0.25)) }
            for s in [1.0, 3.0] { out.append(MIDINote(pitch: 38, velocity: 100, startBeat: b + s, lengthBeats: 0.25)) }
            for h in 0..<8 {
                out.append(MIDINote(pitch: 42, velocity: 80, startBeat: b + Double(h) * 0.5, lengthBeats: 0.2))
            }
        }
        return out
    }

    static func track(_ name: String, _ notes: [MIDINote], program: Int, bankMSB: Int) -> Track {
        let descriptor = InstrumentDescriptor(kind: .soundBank, soundBank: SoundBankConfig(
            source: .generalMIDI, program: program, bankMSB: bankMSB))
        return Track(name: "MIDIB \(name)", kind: .instrument,
                     clips: [Clip(name: name, startBeat: 0, lengthBeats: 34, notes: notes)], instrument: descriptor)
    }

    static func notesJSON(_ notes: [MIDINote], part: String) -> [[String: Any]] {
        notes.map { ["part": part, "pitch": $0.pitch, "startBeat": $0.startBeat, "lengthBeats": $0.lengthBeats,
                     "onsetSeconds": $0.startBeat * 60 / bpm,
                     "offsetSeconds": ($0.startBeat + $0.lengthBeats) * 60 / bpm] }
    }

    static func peakDb(_ audio: RenderedAudio) -> Double {
        let peak = audio.channelData.map { $0.map { abs(Double($0)) }.max() ?? 0 }.max() ?? 0
        return peak > 0 ? 20 * log10(peak) : -999
    }

    static func write(_ audio: RenderedAudio, to url: URL) throws {
        let channels = audio.channelData.count
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: audio.sampleRate,
                                                channels: AVAudioChannelCount(channels), interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format,
                                                   frameCapacity: AVAudioFrameCount(audio.frameCount)))
        buffer.frameLength = AVAudioFrameCount(audio.frameCount)
        for c in 0..<channels {
            let dst = try #require(buffer.floatChannelData?[c])
            audio.channelData[c].withUnsafeBufferPointer { src in
                for i in 0..<audio.frameCount { dst[i] = src[i] }
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        try file.write(from: buffer)
    }
}

/// The offline render (the engine's own offline renderer, the Mac's General MIDI bank through AUSampler).
@MainActor
enum VocalNoteScoreRender {
    /// Renders `tracks`; nil plus the names of the tracks whose sound bank did not come up.
    static func render(_ tracks: [Track]) async throws -> (RenderedAudio?, [String]) {
        let renderer = OfflineRenderer()
        await renderer.prepareAudioUnits(tracks: tracks)
        let notReady = tracks.filter { renderer.auRegistry.status[$0.id] != .ready }.map(\.name)
        guard notReady.isEmpty else { return (nil, notReady) }
        return (try renderer.render(tracks: tracks, tempoMap: TempoMap(constantBPM: VocalNoteScoreFixtures.bpm),
                                    fromBeat: 0, durationSeconds: VocalNoteScoreFixtures.seconds), [])
    }
}

@Suite("W9-MIDIB vocal -> notes, the product path on known notes (MIDIB=1 only)")
struct VocalNoteScoreTests {

    @Test("MIDIB: the known notes (truth) and the product's notes for every file in the manifest",
          .enabled(if: VocalNoteScoreRig.enabled))
    func productNotes() async throws {
        let out = try VocalNoteScoreRig.outDir()
        let env = VocalNoteScoreRig.env

        // The truth the singer was given: `MFSong.notes()` at `MFSong.tempo`, in timeline beats (the scorer moves it
        // to each take's own clock from the take's saved clip position).
        let truth: [[String: Any]] = MFSong.notes().map {
            ["pitch": $0.pitch, "startBeat": $0.startBeat, "lengthBeats": $0.lengthBeats]
        }
        try VocalNoteScoreRig.writeJSON(["tempoBPM": MFSong.tempo, "notes": truth],
                                        to: out.appendingPathComponent("truth-lighton.json"))
        #expect(truth.count == 32)

        let manifestPath = try #require(env["MIDIB_MANIFEST"].flatMap { $0.isEmpty ? nil : $0 },
                                        "MIDIB_MANIFEST must name the manifest")
        let manifestData = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
        let manifest = try #require(try JSONSerialization.jsonObject(with: manifestData) as? [[String: String]])
        try #require(!manifest.isEmpty, "the manifest lists no files")
        let repeats = max(0, Int(env["MIDIB_REPEAT"] ?? "0") ?? 0)
        let ours = out.appendingPathComponent("ours", isDirectory: true)
        try FileManager.default.createDirectory(at: ours, withIntermediateDirectories: true)

        var timing: [[String: Any]] = []
        for entry in manifest {
            let label = try #require(entry["label"])
            let url = URL(fileURLWithPath: try #require(entry["path"]))
            let first = try VocalNoteScoreRig.productRun(url)
            var json = first.json
            let firstSegments = (json["segments"] as? [[String: Any]]) ?? []
            var detects: [Double] = []
            var builds: [Double] = []
            for _ in 0..<repeats {
                let again = try VocalNoteScoreRig.productRun(url)
                detects.append(again.detectSeconds)
                builds.append(again.buildSeconds)
                // The product is deterministic: the same file gives the same table every time.
                #expect(((again.json["segments"] as? [[String: Any]]) ?? []).count == firstSegments.count,
                        "\(label): a repeat built a different table")
            }
            json["label"] = label
            json["repeatDetectSeconds"] = detects
            json["repeatBuildSeconds"] = builds
            try VocalNoteScoreRig.writeJSON(json, to: ours.appendingPathComponent("\(label).json"))
            let held = firstSegments.filter { ($0["origin"] as? String) == NoteOrigin.detected.rawValue }.count
            let fileSeconds = (json["fileSeconds"] as? Double) ?? 0
            print("[MIDIB] \(label): \(firstSegments.count) segments, \(held) held notes, detect \(first.detectSeconds) s, "
                  + "build \(first.buildSeconds) s, file \(fileSeconds) s")
            timing.append(["label": label, "fileSeconds": fileSeconds, "firstDetectSeconds": first.detectSeconds,
                           "firstBuildSeconds": first.buildSeconds, "repeatDetectSeconds": detects,
                           "repeatBuildSeconds": builds])
            #expect(held > 0, "\(label): the product found no notes")
        }
        try VocalNoteScoreRig.writeJSON(["repeats": repeats, "files": timing],
                                        to: out.appendingPathComponent("ours-timing.json"))
    }

    @Test("MIDIB: render the multi-instrument fixtures (known MIDI, GM bank) and write their truth",
          .enabled(if: VocalNoteScoreRig.enabled && VocalNoteScoreRig.renders))
    func renderFixtures() async throws {
        let out = try VocalNoteScoreRig.outDir().appendingPathComponent("inst", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let melodic = GMProgramCatalog.melodicBankMSB
        let kit = GMProgramCatalog.standardDrumKit
        let melody = VocalNoteScoreFixtures.melody()
        let bass = VocalNoteScoreFixtures.bass()
        let chords = VocalNoteScoreFixtures.chords()
        let drums = VocalNoteScoreFixtures.drums()
        #expect(melody.count == 32 && bass.count == 32 && chords.count == 48)
        typealias Part = (name: String, notes: [MIDINote], program: Int, bankMSB: Int)
        let fixtures: [(String, [Part])] = [
            ("melody-piano", [("melody", melody, 0, melodic)]),
            ("band-nodrums", [("melody", melody, 0, melodic), ("bass", bass, 33, melodic),
                              ("chords", chords, 4, melodic)]),
            ("band-drums", [("melody", melody, 0, melodic), ("bass", bass, 33, melodic),
                            ("chords", chords, 4, melodic), ("drums", drums, kit.program, kit.bankMSB)]),
        ]
        var rows: [[String: Any]] = []
        for (name, parts) in fixtures {
            let tracks = parts.map { VocalNoteScoreFixtures.track($0.name, $0.notes, program: $0.program,
                                                                  bankMSB: $0.bankMSB) }
            let (audio, notReady) = try await VocalNoteScoreRender.render(tracks)
            guard let audio else {
                rows.append(["name": name, "rendered": false, "notReady": notReady])
                Issue.record("\(name): the sound bank did not come up for \(notReady)")
                continue
            }
            let wav = out.appendingPathComponent("\(name).wav")
            try VocalNoteScoreFixtures.write(audio, to: wav)
            let peak = VocalNoteScoreFixtures.peakDb(audio)
            #expect(peak > -40, "\(name) is (nearly) silent: \(peak) dBFS")
            let truth = parts.flatMap { VocalNoteScoreFixtures.notesJSON($0.notes, part: $0.name) }
            let programs: [[String: Any]] = parts.map { ["part": $0.name, "program": $0.program, "bankMSB": $0.bankMSB] }
            try VocalNoteScoreRig.writeJSON(["name": name, "tempoBPM": VocalNoteScoreFixtures.bpm,
                                             "programs": programs, "notes": truth],
                                            to: out.appendingPathComponent("\(name)-truth.json"))
            rows.append(["name": name, "rendered": true, "wav": wav.path, "peakDbfs": peak,
                         "frames": audio.frameCount, "sampleRate": audio.sampleRate])
            print("[MIDIB] rendered \(name): peak \(peak) dBFS, \(audio.frameCount) frames")
        }
        try VocalNoteScoreRig.writeJSON(rows, to: out.appendingPathComponent("renders.json"))
    }
}
