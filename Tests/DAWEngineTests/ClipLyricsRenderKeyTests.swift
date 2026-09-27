import Foundation
import Testing
@testable import DAWAppKit
@testable import DAWCore
@testable import DAWEngine

/// p2-sing-d1: lyrics are NOT render material (design §3.1).
///
/// Drafted by W7-SD1, installed by W7-SD2 (p2-sing-d1b). It lives in
/// `Tests/DAWEngineTests/`, the only test target that imports both
/// `ClipRenderSignature` (DAWAppKit) and `StretchRenderCache` (DAWEngine).
/// `Tests/DAWCoreTests/ClipLyricsCodableTests.swift` pins the DAWCore half
/// (every model-side render predicate and render input).
///
/// NOT `@MainActor`: values and one temp file.
@Suite("Clip lyrics never reach a render key or the render signature (p2-sing-d1)")
struct ClipLyricsRenderKeyTests {

    /// A clip that DOES render (stretched 1.5x), with lyrics FORCED on by
    /// direct assignment. `Clip.init` drops lyrics from any non-MIDI clip, so
    /// this is the worst case a future setter bug could produce, and the only
    /// way lyrics could ever sit on a clip the engine renders.
    private static func renderingClip(url: URL, lyrics: ClipLyrics?) -> Clip {
        var clip = Clip(id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!, name: "Vox",
                        startBeat: 0, lengthBeats: 4, audioFileURL: url, stretchRatio: 1.5)
        clip.lyrics = lyrics
        return clip
    }

    @Test("lyrics change neither StretchRenderCache.Params nor the render keys it derives")
    func renderKeysIgnoreLyrics() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2sd1-key-\(UUID().uuidString).wav")
        try Data([0x00]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let plain = Self.renderingClip(url: url, lyrics: nil)
        let sung = Self.renderingClip(url: url, lyrics: ClipLyrics(text: "twin-kle twin-kle +\nlit-tle star"))
        #expect(plain != sung, "control: the two clips differ, in lyrics only")
        #expect(sung.rendersThroughStretchCache, "control: this clip renders")

        let p0 = StretchRenderCache.Params(clip: plain)
        let p1 = StretchRenderCache.Params(clip: sung)
        #expect(p0 == p1)
        #expect(p0.hashValue == p1.hashValue)
        let k0 = try StretchRenderCache.renderKeys(source: url, params: p0, detector: .product)
        let k1 = try StretchRenderCache.renderKeys(source: url, params: p1, detector: .product)
        #expect(k0 == k1)

        // Positive control: a render-material change DOES re-key, so the
        // equality above is a finding, not a key builder that ignores clips.
        var faster = sung
        faster.stretchRatio = 1.25
        let k2 = try StretchRenderCache.renderKeys(source: url, params: .init(clip: faster), detector: .product)
        #expect(k2 != k1)
    }

    @Test("lyrics change nothing in the timeline's render signature")
    func renderSignatureIgnoresLyrics() {
        let url = URL(fileURLWithPath: "/tmp/p2sd1-signature.wav")
        func signature(_ clip: Clip, _ kind: TrackKind) -> ClipRenderSignature {
            ClipRenderSignature(tracks: [Track(name: "T", kind: kind, clips: [clip])])
        }
        // An audio clip that renders, lyrics forced on (see `renderingClip`).
        let plain = Self.renderingClip(url: url, lyrics: nil)
        let sung = Self.renderingClip(url: url, lyrics: ClipLyrics(text: "la la"))
        #expect(signature(plain, .audio) == signature(sung, .audio))
        // Positive control: a render input does change it.
        var transposed = sung
        transposed.pitchShiftSemitones = 2
        #expect(signature(transposed, .audio) != signature(sung, .audio))

        // The ordinary case: lyrics on a MIDI clip. A MIDI clip never enters
        // the signature, with or without lyrics.
        let midi = Clip(name: "Lead", lengthBeats: 4, notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)])
        var sungMIDI = midi
        sungMIDI.lyrics = ClipLyrics(text: "la")
        #expect(signature(midi, .instrument) == signature(sungMIDI, .instrument))
        #expect(signature(sungMIDI, .instrument) == ClipRenderSignature(tracks: []))
    }
}

/// p2-sing-d2: `SingPlanner` sings the notes the clip PLAYS. DAWCore cannot
/// call the playback evaluator (`MIDIEventSchedule.buildEvents`, DAWEngine),
/// so `SingPlanner.played` restates its window rule; this suite pins the
/// restatement to the evaluator itself. For seeded clips (notes before, at and
/// past the clip's end, chords, overlaps, a tempo change, a clip that does not
/// start at 0), the planner's notes are exactly the note-on/off pairs playback
/// schedules: the same notes, in the same order, with the same pitches, and
/// the same on and off frames.
///
/// ⚠️ Design §3.4 says "loop repeats are expanded by the evaluator playback
/// uses". A clip has no loop of its own in this tree: the evaluator's only
/// repeat is the transport cycle (`onsetEndBeat` plus per-cycle blocks), which
/// replays the landed vocal with the melody, so the planner must NOT expand
/// it. This suite compares a single pass (no `onsetEndBeat`, no chase).
///
/// NOT `@MainActor`: pure values.
@Suite("SingPlanner plays what playback plays (p2-sing-d2)")
struct SingPlannerPlaybackParityTests {

    @Test("seeded clips: the same notes, pitches and on/off frames as MIDIEventSchedule.buildEvents")
    func plannerMatchesTheEvaluator() throws {
        let sampleRate = 48_000.0
        let maps = [TempoMap(constantBPM: 120),
                    try TempoMap(segments: [.init(startBeat: 0, bpm: 90), .init(startBeat: 6, bpm: 140)])]
        var rng = ParityRNG(seed: 0xD2_5EED)
        var notesCompared = 0
        var notesDropped = 0
        var endsCut = 0
        for trial in 0..<200 {
            let map = maps[trial % maps.count]
            var notes: [MIDINote] = []
            for _ in 0..<Int.random(in: 1...16, using: &rng) {
                notes.append(MIDINote(pitch: Int.random(in: 40...90, using: &rng),
                                      velocity: Int.random(in: 1...127, using: &rng),
                                      startBeat: Double(Int.random(in: 0...80, using: &rng)) * 0.25,
                                      lengthBeats: Double(Int.random(in: 1...16, using: &rng)) * 0.25))
            }
            let clip = Clip(name: "Melody", startBeat: Double(Int.random(in: 0...16, using: &rng)) * 0.25,
                            lengthBeats: Double(Int.random(in: 4...32, using: &rng)) * 0.5, notes: notes)

            let played = SingPlanner.played(clip)
            let (events, _) = MIDIEventSchedule.buildEvents(clips: [clip], fromBeat: 0, tempoMap: map,
                                                            sampleRate: sampleRate)
            // Pair each note-on with its note-off; note ids count up in the
            // order the evaluator walked the clip's notes.
            let ons = events.filter { $0.kind == ScheduledMIDIEvent.noteOn }.sorted { $0.noteID < $1.noteID }
            var offs: [UInt64: Int64] = [:]
            for event in events where event.kind == ScheduledMIDIEvent.noteOff { offs[event.noteID] = event.sampleTime }

            #expect(ons.count == played.count, "trial \(trial)")
            guard ons.count == played.count else { continue }
            for (on, voice) in zip(ons, played) {
                let onFrame = Int64((map.seconds(from: 0, to: clip.startBeat + voice.startBeat) * sampleRate).rounded())
                let offRaw = Int64((map.seconds(from: 0, to: clip.startBeat + voice.endBeat) * sampleRate).rounded())
                #expect(Int(on.pitch) == voice.pitch, "trial \(trial)")
                #expect(on.sampleTime == onFrame, "trial \(trial)")
                #expect(offs[on.noteID] == max(onFrame + 1, offRaw), "trial \(trial)")
                notesCompared += 1
            }
            notesDropped += (clip.notes?.count ?? 0) - played.count
            for voice in played {
                if let written = clip.notes?.first(where: { $0.id == voice.id }), written.endBeat > voice.endBeat {
                    endsCut += 1
                }
            }
        }
        #expect(notesCompared > 500, "control: many notes compared (\(notesCompared))")
        #expect(notesDropped > 50, "control: notes at or past the clip's end were exercised (\(notesDropped))")
        #expect(endsCut > 20, "control: notes cut at the clip's end were exercised (\(endsCut))")
    }
}

/// SplitMix64, seeded: the same clips on every run.
private struct ParityRNG: RandomNumberGenerator {
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
