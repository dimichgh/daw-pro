import Foundation
import Testing
@testable import AIServices
@testable import DAWCore

/// p2-sing-e part 1: THE one place a planned unit becomes a facade request
/// (`SingJobRequestBuilder.phraseRequest`), its v1 bytes pinned, and the phrase-cache key.
@Suite("SingJob request — the one builder, the v1 bytes, the cache key (p2-sing-e)")
struct SingJobRequestTests {

    /// A two-note unit sung as one word, built by hand so the pin depends on nothing but the builder.
    static func unit() -> SingUnit {
        SingUnit(
            notes: [SingNote(noteID: UUID(), startSeconds: 0, endSeconds: 0.5, midi: 60, sourcePitch: 60),
                    SingNote(noteID: UUID(), startSeconds: 0.5, endSeconds: 1, midi: 62, sourcePitch: 62)],
            words: [SingWord(text: "twinkle", typed: "twin-kle,", noteIndices: [0, 1])],
            offsetSeconds: 0, onsetSeconds: 2, spanSeconds: 1)
    }

    @Test("v1: the request a first take sends today, byte for byte (keys sorted)")
    func v1RequestBytesArePinned() throws {
        let request = SingJobRequestBuilder.phraseRequest(
            unit: Self.unit(), voice: .builtin(id: "builtin-1"), seed: SingJobRequestBuilder.firstTakeSeed,
            outputPath: "/tmp/sing-v1.wav")
        let data = try SingJobRequestBuilder.canonicalBody(request)
        let body = String(decoding: data, as: UTF8.self)
        // MEASURED 2026-10-06 (first run of this test): JSONSerialization prints the double 0.24 as
        // 0.23999999999999999. That is the same double (the facade's Python `json` reads it back as 0.24),
        // and it is what the client sends today, so it is what is pinned.
        #expect(body == #"{"cfg":3,"facadeVersion":1,"leadS":0.23999999999999999,"nSteps":32,"#
            + #""outputPath":"\/tmp\/sing-v1.wav","outputSampleRate":48000,"#
            + #""phrase":{"notes":[{"endS":0.5,"midi":60,"startS":0},{"endS":1,"midi":62,"startS":0.5}],"#
            + #""words":[{"noteIndices":[0,1],"text":"twinkle"}]},"#
            + #""seed":20260924,"trailS":0.23999999999999999,"voice":{"id":"builtin-1"}}"#)
        let decoded = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((decoded["leadS"] as? Double) == 0.24, "the printed digits are the same double")
        // The explicit default and the implicit one are the same request.
        let explicit = SingJobRequestBuilder.phraseRequest(
            unit: Self.unit(), voice: .builtin(id: "builtin-1"), seed: SingJobRequestBuilder.firstTakeSeed,
            outputPath: "/tmp/sing-v1.wav", outputSampleRate: 48_000, options: .v1)
        #expect(try SingJobRequestBuilder.canonicalBody(explicit) == SingJobRequestBuilder.canonicalBody(request))
    }

    @Test("v1: the top-level keys are exactly the facade's TOP_KEYS (it refuses any other)")
    func v1KeysAreTheFacadesKeys() {
        let request = SingJobRequestBuilder.phraseRequest(
            unit: Self.unit(), voice: .builtin(id: "builtin-1"), seed: 1, outputPath: "/tmp/x.wav")
        // `scripts/sing/singlib/schema.py` TOP_KEYS, read 2026-10-06.
        let topKeys: Set<String> = ["facadeVersion", "voice", "phrase", "leadS", "trailS", "seed", "nSteps", "cfg",
                                    "outputPath", "outputSampleRate"]
        #expect(Set(request.jsonObject().keys) == topKeys)
    }

    @Test("the builder sends the SUNG word, the target midi and the planner's lead and trail")
    func builderMapsTheUnit() {
        let request = SingJobRequestBuilder.phraseRequest(
            unit: Self.unit(), voice: .builtin(id: "builtin-1"), seed: 7, outputPath: "/tmp/x.wav",
            outputSampleRate: 24_000, options: SingRenderOptions(nSteps: 8, cfg: 1.5))
        #expect(request.words == [SingingPhraseWord(text: "twinkle", noteIndices: [0, 1])])
        #expect(request.notes.map { $0.midi } == [60, 62])
        #expect(request.leadS == SingPlanner.leadSeconds)
        #expect(request.trailS == SingPlanner.trailSeconds)
        #expect(request.nSteps == 8)
        #expect(request.cfg == 1.5)
        #expect(request.outputSampleRate == 24_000)
        #expect(request.seed == 7)
    }

    @Test("seeds: the first take's is the picked renders' seed; a retry is the take's + 1")
    func seeds() {
        #expect(SingJobRequestBuilder.firstTakeSeed == 20_260_924)
        #expect(SingJobRequestBuilder.retrySeed(after: 20_260_924) == 20_260_925)
        #expect(SingJobRequestBuilder.retrySeed(after: .max) == 0, "wraps, never traps")
        let another = SingJobRequestBuilder.anotherTakeSeed()
        #expect(another >= 1)
    }

    @Test("cache key: not the output path, not the reference path; everything the render depends on")
    func cacheKey() throws {
        let engine = SingEngineIdentity(commit: "abc", weightsRevision: "w1", weightsBytes: 10, facadeVersion: 1)
        let base = SingJobRequestBuilder.phraseRequest(
            unit: Self.unit(), voice: .builtin(id: "builtin-1"), seed: 7, outputPath: "/tmp/a.wav")
        let key = try SingJobRequestBuilder.cacheKey(for: base, engine: engine)
        #expect(key.count == 64)

        var moved = base
        moved.outputPath = "/tmp/b.wav"
        #expect(try SingJobRequestBuilder.cacheKey(for: moved, engine: engine) == key, "the path is not content")

        var reseeded = base
        reseeded.seed = 8
        #expect(try SingJobRequestBuilder.cacheKey(for: reseeded, engine: engine) != key)
        var renoted = base
        renoted.notes[1].midi = 63
        #expect(try SingJobRequestBuilder.cacheKey(for: renoted, engine: engine) != key)
        var reworded = base
        reworded.words[0].text = "twinkles"
        #expect(try SingJobRequestBuilder.cacheKey(for: reworded, engine: engine) != key)
        var rerated = base
        rerated.outputSampleRate = 24_000
        #expect(try SingJobRequestBuilder.cacheKey(for: rerated, engine: engine) != key)
        var newEngine = engine
        newEngine.commit = "abd"
        #expect(try SingJobRequestBuilder.cacheKey(for: base, engine: newEngine) != key)
        newEngine = engine
        newEngine.weightsRevision = "w2"
        #expect(try SingJobRequestBuilder.cacheKey(for: base, engine: newEngine) != key)

        // An own voice: its reference's PATH is not content, its sha256 is.
        func own(path: String, sha: String) -> SingingPhraseRequest {
            var request = base
            request.voice = .own(id: "v1", referencePath: path, referenceSha256: sha, windowStartS: 0,
                                 windowEndS: 4, notes: [], promptLabelOffset: 0)
            return request
        }
        let ownKey = try SingJobRequestBuilder.cacheKey(for: own(path: "/a/ref.wav", sha: "s1"), engine: engine)
        #expect(try SingJobRequestBuilder.cacheKey(for: own(path: "/b/ref.wav", sha: "s1"), engine: engine) == ownKey)
        #expect(try SingJobRequestBuilder.cacheKey(for: own(path: "/a/ref.wav", sha: "s2"), engine: engine) != ownKey)
        #expect(ownKey != key)
    }

    @Test("voices: the built-in singer's id, name and kind; an own voice's facade object")
    func voices() {
        let builtIn = SingJobVoice.builtIn
        #expect(builtIn.id == "builtin-1")
        #expect(builtIn.name == "Built-in singer")
        #expect(builtIn.kind == SungVocalProvenance.VoiceKind.builtIn)
        #expect(builtIn.reference == .builtin(id: "builtin-1"))
        #expect(builtIn.wordCheckIsReliable)
        let own = SingJobVoice.own(SingOwnVoice(
            id: "me", name: "My voice", referencePath: "/v/me.wav", referenceSha256: "abc", windowStartS: 1,
            windowEndS: 5, promptNotes: [], promptLabelOffset: 0, wordCheckIsReliable: false))
        #expect(own.kind == SungVocalProvenance.VoiceKind.own)
        #expect(!own.wordCheckIsReliable)
        #expect(own.reference == .own(id: "me", referencePath: "/v/me.wav", referenceSha256: "abc",
                                      windowStartS: 1, windowEndS: 5, notes: [], promptLabelOffset: 0))
    }
}
