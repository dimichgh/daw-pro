import Foundation
import Testing
@testable import DAWCore
@testable import DAWControl

// Tune to Melody, M2 (W7-TTM2): the wire half of `clip.autoCorrectPitch` — the three additive
// keys `melodyClipId` | `melodyTrackId` (exactly one) and `octaveMatch`, and the `melody{}`
// echo (design `2026-09-24-unpitched-notes-presets-midi-targets.md` §3.4, §3.6).
//
// An EXTENSION of the existing `@MainActor` suite `PitchCorrectionCommandTests`, not a new
// suite (the @MainActor census has one slot left). Every test name starts with
// `tuneToMelodyWire`. The host's helpers are `private` to its file, so these are their own.
//
// Fixture: 120 bpm (the project default), the vocal added at beat 0 (FakeMedia: 2 s, so
// 4 beats), and a stub contour sung 40 c flat of the melody:
//   sung    56.6 @ [0.1, 0.5)  59.6 @ [0.7, 1.1)  63.6 @ [1.3, 1.7)
//   melody  57 beats 0.2-1.0   60 beats 1.4-2.2   64 beats 2.6-3.4    (the same seconds)
extension PitchCorrectionCommandTests {

    private static let wireSung: [(start: Double, end: Double, midi: Double)] = [
        (0.1, 0.5, 56.6), (0.7, 1.1, 59.6), (1.3, 1.7, 63.6),
    ]

    private static func wireMelodyNotes(_ shift: Double = 0) -> JSONValue {
        .array([(57, 0.2), (60, 1.4), (64, 2.6)].map { pitch, start in
            .object(["pitch": .number(Double(pitch)), "startBeat": .number(start + shift),
                     "lengthBeats": .number(0.8)])
        })
    }

    private static func wireMelodyEngine() -> FakePitchDetectionEngine {
        let engine = FakePitchDetectionEngine()
        let period = 1 / 62.5
        let frames = (0..<125).map { i -> ClipPitchFrame in
            let t = Double(i) * period
            if let note = wireSung.first(where: { t >= $0.start && t < $0.end }) {
                return ClipPitchFrame(timeSeconds: t, frequencyHz: 440 * pow(2, (note.midi - 69) / 12),
                                      confidence: 0.97, levelDbfs: -12, absence: nil)
            }
            return ClipPitchFrame(timeSeconds: t, frequencyHz: nil, confidence: 0.1,
                                  levelDbfs: -70, absence: .belowConfidence)
        }
        let voiced = frames.filter { $0.frequencyHz != nil }.count
        engine.stubResult = PitchDetectionResult(
            frames: frames, frameCount: frames.count, voicedFrameCount: voiced,
            voicedFraction: Double(voiced) / Double(frames.count),
            frameRateHz: 62.5, analysisSampleRateHz: 16_000, sourceSampleRateHz: 44_100,
            windowStartSeconds: 0, windowDurationSeconds: 2.0,
            confidenceThreshold: 0.9, silenceFloorDbfs: -75,
            minFrequencyHz: 46.875, maxFrequencyHz: 2_093.75)
        return engine
    }

    /// A router with a vocal clip and a lead track holding one MIDI clip with the melody
    /// (`melodyShift` beats later, to build a melody that misses the vocal).
    private func melodyWireFixture(melodyShift: Double = 0) async throws
        -> (router: CommandRouter, store: ProjectStore, engine: FakePitchDetectionEngine,
            url: URL, vocalID: String, leadTrackID: String, leadClipID: String) {
        let store = ProjectStore()
        store.media = FakeMedia()
        let engine = Self.wireMelodyEngine()
        store.engine = engine
        let router = CommandRouter(store: store)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-ttm2-wire-\(UUID().uuidString).wav")
        try Data([0x00]).write(to: url)
        let vocalTrack = await router.handle(ControlRequest(
            id: "t1", command: "track.add", params: ["kind": .string("audio")]))
        let vocalTrackID = try #require(vocalTrack.result?["id"]?.stringValue)
        let vocal = await router.handle(ControlRequest(
            id: "c1", command: "clip.addAudio",
            params: ["trackId": .string(vocalTrackID), "path": .string(url.path),
                     "atBeat": .number(0)]))
        let vocalID = try #require(vocal.result?["id"]?.stringValue)
        let leadTrack = await router.handle(ControlRequest(
            id: "t2", command: "track.add", params: ["kind": .string("instrument")]))
        let leadTrackID = try #require(leadTrack.result?["id"]?.stringValue)
        let lead = await router.handle(ControlRequest(
            id: "c2", command: "clip.addMIDI",
            params: ["trackId": .string(leadTrackID), "atBeat": .number(0),
                     "lengthBeats": .number(24), "notes": Self.wireMelodyNotes(melodyShift)]))
        let leadClipID = try #require(lead.result?["id"]?.stringValue)
        return (router, store, engine, url, vocalID, leadTrackID, leadClipID)
    }

    private func autoCorrect(_ router: CommandRouter, _ params: [String: JSONValue]) async
        -> ControlResponse {
        await router.handle(ControlRequest(id: "ac", command: "clip.autoCorrectPitch",
                                           params: params))
    }

    @Test("tuneToMelodyWire W1: melodyClipId tunes to the melody and echoes melody{} with every §3.3 field; appliedOptions says strength 1")
    func tuneToMelodyWireEchoesMelodyBlock() async throws {
        let f = try await melodyWireFixture()
        defer { try? FileManager.default.removeItem(at: f.url) }
        let response = await autoCorrect(f.router, [
            "clipId": .string(f.vocalID), "preset": .string("natural"),
            "melodyClipId": .string(f.leadClipID),
        ])
        #expect(response.ok, "\(response.error ?? "")")
        let melody = try #require(response.result?["melody"]?.objectValue)
        for key in ["source", "octaveMatch", "unmatched", "notesConsidered", "notesUsed",
                    "matchedParts", "unmatchedParts", "unsungNotes", "outvotedNotes", "cutsAdded",
                    "chordsReduced", "octaveFolded", "farMoves"] {
            #expect(melody[key] != nil, "melody.\(key) missing")
        }
        #expect(melody["source"]?["kind"]?.stringValue == "clip")
        #expect(melody["source"]?["clipId"]?.stringValue == f.leadClipID)
        #expect(melody["octaveMatch"]?.stringValue == "nearestOctave")
        #expect(melody["unmatched"]?.stringValue == "asSung")
        #expect(melody["matchedParts"]?.doubleValue == 3)
        #expect(melody["notesUsed"]?.doubleValue == 3)
        #expect(response.result?["appliedOptions"]?["strength"]?.doubleValue == 1)
        let segments = try #require(response.result?["segments"]?.arrayValue)
        let held = segments.filter { $0["origin"]?.stringValue == "detected" }
        #expect(held.count == 3)
        for segment in held {
            let cents = segment["pitchOffsetCents"]?.doubleValue ?? .nan
            #expect(abs(cents - 40) < 0.01, "\(cents)")
        }
    }

    @Test("tuneToMelodyWire W2: sending BOTH melodyClipId and melodyTrackId is refused, before any detection")
    func tuneToMelodyWireBothIdsRefused() async throws {
        let f = try await melodyWireFixture()
        defer { try? FileManager.default.removeItem(at: f.url) }
        let response = await autoCorrect(f.router, [
            "clipId": .string(f.vocalID), "melodyClipId": .string(f.leadClipID),
            "melodyTrackId": .string(f.leadTrackID),
        ])
        #expect(!response.ok)
        #expect(response.error?.contains("melodyClipId") == true)
        #expect(response.error?.contains("melodyTrackId") == true)
        #expect(f.engine.detectCalls == 0)
    }

    @Test("tuneToMelodyWire W3: octaveMatch must be nearestOctave or exact, and is refused without a melody")
    func tuneToMelodyWireOctaveMatchRules() async throws {
        let f = try await melodyWireFixture()
        defer { try? FileManager.default.removeItem(at: f.url) }
        let bad = await autoCorrect(f.router, [
            "clipId": .string(f.vocalID), "melodyClipId": .string(f.leadClipID),
            "octaveMatch": .string("loudest"),
        ])
        #expect(!bad.ok)
        #expect(bad.error?.contains("nearestOctave") == true && bad.error?.contains("exact") == true)
        let alone = await autoCorrect(f.router, [
            "clipId": .string(f.vocalID), "octaveMatch": .string("exact"),
        ])
        #expect(!alone.ok)
        #expect(alone.error?.contains("melodyClipId") == true, "\(alone.error ?? "")")
        #expect(f.engine.detectCalls == 0)
        let exact = await autoCorrect(f.router, [
            "clipId": .string(f.vocalID), "melodyTrackId": .string(f.leadTrackID),
            "octaveMatch": .string("exact"),
        ])
        #expect(exact.ok, "\(exact.error ?? "")")
        #expect(exact.result?["melody"]?["octaveMatch"]?.stringValue == "exact")
    }

    @Test("tuneToMelodyWire W4: an unknown key is still rejected by rejectUnknownKeys, which now lists the three melody keys")
    func tuneToMelodyWireUnknownKeyStillRejected() async throws {
        let f = try await melodyWireFixture()
        defer { try? FileManager.default.removeItem(at: f.url) }
        let response = await autoCorrect(f.router, [
            "clipId": .string(f.vocalID), "melodyId": .string(f.leadClipID),
        ])
        #expect(!response.ok)
        let error = response.error ?? ""
        #expect(error.contains("melodyId"), "\(error)")
        for key in ["melodyClipId", "melodyTrackId", "octaveMatch"] {
            #expect(error.contains(key), "valid keys should list \(key): \(error)")
        }
    }

    @Test("tuneToMelodyWire W5: a request that names a scale sends rests to the scale; one that does not keeps them as sung")
    func tuneToMelodyWireScaleKeysMeanToScale() async throws {
        let f = try await melodyWireFixture()
        defer { try? FileManager.default.removeItem(at: f.url) }
        let withScale = await autoCorrect(f.router, [
            "clipId": .string(f.vocalID), "melodyClipId": .string(f.leadClipID),
            "tonicPitchClass": .number(0), "mode": .string("major"),
        ])
        #expect(withScale.ok, "\(withScale.error ?? "")")
        #expect(withScale.result?["melody"]?["unmatched"]?.stringValue == "toScale")
        let modeOnly = await autoCorrect(f.router, [
            "clipId": .string(f.vocalID), "melodyClipId": .string(f.leadClipID),
            "mode": .string("chromatic"),
        ])
        #expect(modeOnly.result?["melody"]?["unmatched"]?.stringValue == "toScale")
        let without = await autoCorrect(f.router, [
            "clipId": .string(f.vocalID), "melodyClipId": .string(f.leadClipID),
        ])
        #expect(without.result?["melody"]?["unmatched"]?.stringValue == "asSung")
    }

    @Test("tuneToMelodyWire W6: no melody key answers exactly as before: no melody block, the preset's own strength")
    func tuneToMelodyWireAbsentMeansNoBlock() async throws {
        let f = try await melodyWireFixture()
        defer { try? FileManager.default.removeItem(at: f.url) }
        let response = await autoCorrect(f.router, [
            "clipId": .string(f.vocalID), "preset": .string("natural"),
        ])
        #expect(response.ok)
        #expect(response.result?["melody"] == nil)
        #expect(response.result?["appliedOptions"]?["strength"]?.doubleValue == 0.85)
        let segments = try #require(response.result?["segments"]?.arrayValue)
        for segment in segments where segment["origin"]?.stringValue == "detected" {
            let cents = segment["pitchOffsetCents"]?.doubleValue ?? .nan
            #expect(abs(cents - 34) < 0.01, "Natural's 0.85 of 40 c: \(cents)")
        }
    }

    @Test("tuneToMelodyWire W7: melodyTrackId reads every MIDI clip on the track and echoes source.kind track")
    func tuneToMelodyWireTrackSource() async throws {
        let f = try await melodyWireFixture()
        defer { try? FileManager.default.removeItem(at: f.url) }
        let response = await autoCorrect(f.router, [
            "clipId": .string(f.vocalID), "melodyTrackId": .string(f.leadTrackID),
        ])
        #expect(response.ok, "\(response.error ?? "")")
        #expect(response.result?["melody"]?["source"]?["kind"]?.stringValue == "track")
        #expect(response.result?["melody"]?["source"]?["trackId"]?.stringValue == f.leadTrackID)
        #expect(response.result?["melody"]?["matchedParts"]?.doubleValue == 3)
    }

    @Test("tuneToMelodyWire W8: a strength the caller sends wins over rule 5's 1, and is echoed")
    func tuneToMelodyWireStrengthSent() async throws {
        let f = try await melodyWireFixture()
        defer { try? FileManager.default.removeItem(at: f.url) }
        let response = await autoCorrect(f.router, [
            "clipId": .string(f.vocalID), "preset": .string("natural"),
            "melodyClipId": .string(f.leadClipID), "strength": .number(0.5),
        ])
        #expect(response.ok, "\(response.error ?? "")")
        #expect(response.result?["appliedOptions"]?["strength"]?.doubleValue == 0.5)
        let zero = await autoCorrect(f.router, [
            "clipId": .string(f.vocalID), "melodyClipId": .string(f.leadClipID),
            "strength": .number(0),
        ])
        #expect(!zero.ok)
        #expect(zero.error?.contains("above 0") == true, "\(zero.error ?? "")")
    }

    @Test("tuneToMelodyWire W9: a melody with no note under the vocal is refused in words naming both spans")
    func tuneToMelodyWireRefusesWithoutOverlap() async throws {
        let f = try await melodyWireFixture(melodyShift: 16)
        defer { try? FileManager.default.removeItem(at: f.url) }
        let response = await autoCorrect(f.router, [
            "clipId": .string(f.vocalID), "melodyClipId": .string(f.leadClipID),
        ])
        #expect(!response.ok)
        let error = response.error ?? ""
        #expect(error.contains("beats 0 to 4"), "\(error)")
        #expect(error.contains("from beat 16.2 to beat 19.4"), "\(error)")
        #expect(f.engine.detectCalls == 0)
        #expect(f.store.tracks.flatMap(\.clips).allSatisfy { $0.pitchEdits == nil })
    }
}
