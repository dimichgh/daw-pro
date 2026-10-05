import Foundation
import Testing
import AIServices
import DAWCore
@testable import DAWControl

/// Wire-level gate for `playbox.generate` (m34-g).
///
/// ⛔⛔ **THE VERB IS AN ANSWER, NOT AN ACTION, AND THE FIRST ASSERTIONS SAY SO.**
/// Playbox produces the INVITATION; the human produces the performance. This
/// route lights nothing, sounds nothing, records nothing and mutates nothing —
/// it returns scale degrees. That property is what keeps it from growing into a
/// second, competing "the AI writes your part" feature, which is the one thing
/// this item exists NOT to be.
///
/// ⛔ **NO NETWORK AND NO KEYS.** The generator is injected on every router here,
/// so which branch a test takes never depends on what is configured on the
/// machine running it.
@MainActor
@Suite("playbox.generate wire command (m34-g)")
struct PlayboxCommandTests {

    private struct FakeGenerator: ChordProgressionGenerating {
        let degrees: [Int]
        func generateProgression(_ request: PlayboxRequest) async throws -> PlayboxPlan {
            PlayboxPlan(degrees: degrees, name: "Playbox",
                        provenance: PlayboxProvenance(kind: .ai, detail: "anthropic"))
        }
    }

    private struct ThrowingGenerator: ChordProgressionGenerating {
        let error: Error
        func generateProgression(_ request: PlayboxRequest) async throws -> PlayboxPlan {
            throw error
        }
    }

    /// Records the request the route built, so "the project's own facts are the
    /// defaults" is asserted rather than assumed.
    private actor RequestSpy: ChordProgressionGenerating {
        private(set) var seen: PlayboxRequest?
        func generateProgression(_ request: PlayboxRequest) async throws -> PlayboxPlan {
            seen = request
            return PlayboxPlan(degrees: [1, 5, 6, 4], name: "Playbox",
                               provenance: PlayboxProvenance(kind: .ai, detail: "anthropic"))
        }
    }

    private func makeRouter(
        generator: (any ChordProgressionGenerating)? = nil,
        makeError: Error? = nil
    ) -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        let router = CommandRouter(store: store, chordProgressionGenerator: {
            if let makeError { throw makeError }
            return generator ?? FakeGenerator(degrees: [1, 5, 6, 4])
        })
        return (router, store)
    }

    private func generate(_ router: CommandRouter,
                          _ params: [String: JSONValue] = [:]) async -> ControlResponse {
        await router.handle(ControlRequest(id: "1", command: "playbox.generate", params: params))
    }

    private func payload(_ response: ControlResponse) -> [String: JSONValue] {
        guard case .object(let object)? = response.result else { return [:] }
        return object
    }

    private func degrees(_ response: ControlResponse) -> [Int] {
        guard case .array(let list)? = payload(response)["degrees"] else { return [] }
        return list.compactMap { $0.doubleValue.map(Int.init) }
    }

    // MARK: - Registration

    /// ⚠️ **THE NEIGHBOURHOOD IS PINNED, AND FOR A MEASURED REASON.** A tail
    /// append shifts every `dropLast(N)` window in this suite tree — 19
    /// end-relative assertions reddened that way at m23-ct. Sitting next to
    /// `macro.songSkeleton` (the other verb that builds musical structure from
    /// the project's own facts) leaves all of them true by construction.
    @Test("playbox.generate is registered next to macro.songSkeleton and NOT at the tail")
    func verbIsRegistered() {
        #expect(CommandRouter.allCommands.contains("playbox.generate"))
        let index = try? #require(CommandRouter.allCommands.firstIndex(of: "playbox.generate"))
        let skeleton = try? #require(CommandRouter.allCommands.firstIndex(of: "macro.songSkeleton"))
        #expect(index == (skeleton.map { $0 + 1 } ?? -1))
        #expect(index != CommandRouter.allCommands.count - 1, "must NOT be at the tail")
        // m23-q Phase 2 appended clip.autoCorrectPitch/clip.clearPitchEdits/
        // clip.getPitchEdits AFTER vc.installEmbeddedVoice, at the new END —
        // it is no longer literally last, still exactly where it was.
        #expect(CommandRouter.allCommands.dropLast(3).last == "vc.installEmbeddedVoice",
                "…and the old tail is exactly where it was before this item")
        #expect(CommandRouter.allCommands.last == "clip.getPitchEdits")
    }

    @Test("it rejects unknown parameter keys with a teaching error")
    func rejectsUnknownKeys() async {
        let (router, _) = makeRouter()
        let response = await generate(router, ["nonsense": .bool(true)])
        #expect(response.error != nil)
        #expect(response.error?.contains("nonsense") == true)
    }

    // MARK: - ⛔ An answer, never an action

    /// ⛔⛔ **THE PROPERTY THAT MAKES THIS FEATURE WORTH HAVING.** The AI produces
    /// the invitation; the human produces the performance. A verb that added a
    /// clip or sounded a note would have quietly replaced the feature with the
    /// thing it was built to avoid.
    @Test("⛔⛔ it MUTATES NOTHING — no clip, no track, no transport, no undo entry")
    func generateIsPure() async {
        let (router, store) = makeRouter()
        let track = store.addTrack(name: "Keys", kind: .instrument).id
        let clipCountBefore = store.tracks.first { $0.id == track }?.clips.count ?? -1
        let historyBefore = store.undoHistory().undo.count
        let positionBefore = store.transport.positionBeats
        let response = await generate(router)
        #expect(response.error == nil)
        #expect(!degrees(response).isEmpty, "positive control: it DID answer")
        #expect(store.tracks.first { $0.id == track }?.clips.count == clipCountBefore)
        #expect(store.tracks.count == 1)
        #expect(store.undoHistory().undo.count == historyBefore, "generating is not an edit")
        #expect(store.transport.positionBeats == positionBefore)
        #expect(store.transport.isPlaying == false)
        #expect(store.transport.isRecording == false)
    }

    // MARK: - The AI path and its credit

    @Test("a good AI answer is returned and credited to the provider")
    func aiAnswerIsCredited() async {
        let (router, _) = makeRouter(generator: FakeGenerator(degrees: [1, 6, 4, 5]))
        let response = await generate(router)
        #expect(degrees(response) == [1, 6, 4, 5])
        #expect(payload(response)["source"]?.stringValue == "ai")
        #expect(payload(response)["detail"]?.stringValue == "anthropic")
        #expect(payload(response)["reason"] == nil, "a successful AI answer has nothing to explain")
    }

    // MARK: - ⛔ The no-key story

    /// ⛔⛔ **A FEATURE THAT IS DEAD WITHOUT AN API KEY IS DEAD FOR ANYONE WHO HAS
    /// NOT SET ONE UP.** The verb answers anyway — and stops claiming the AI
    /// wrote it.
    @Test("⛔ NO PROVIDER CONFIGURED still answers, credited to the LIBRARY, with a reason")
    func noProviderStillAnswers() async {
        let (router, _) = makeRouter(
            makeError: AIServiceError.noProviderConfigured(capability: "chord-progression"))
        let response = await generate(router)
        #expect(response.error == nil, "⛔ an unconfigured provider is a STATE, not a failure")
        #expect(PlayboxProgression.validate(degrees: degrees(response)) != nil)
        #expect(payload(response)["source"]?.stringValue == "local")
        #expect(payload(response)["reason"]?.stringValue?.isEmpty == false)
        #expect(payload(response)["detail"]?.stringValue?.contains("AI") != true,
                "⛔ the fallback must never claim authorship it did not earn")
    }

    /// ⛔ **AND THE REASON NEVER CARRIES KEY MATERIAL.** `AIServiceError` reports
    /// provider names and HTTP statuses; this asserts the wire agrees.
    @Test("⛔ the reason names the capability, never a key")
    func reasonCarriesNoSecret() async {
        let (router, _) = makeRouter(
            makeError: AIServiceError.notConfigured("ANTHROPIC_API_KEY"))
        let response = await generate(router)
        let reason = payload(response)["reason"]?.stringValue ?? ""
        #expect(reason.contains("ANTHROPIC_API_KEY"), "the VARIABLE NAME is actionable")
        #expect(!reason.contains("sk-"), "…and no value ever appears")
    }

    @Test("⛔ a provider ERROR falls back the same way a missing key does")
    func providerErrorFallsBack() async {
        let (router, _) = makeRouter(
            generator: ThrowingGenerator(
                error: AIServiceError.malformedResponse("not a usable progression")))
        let response = await generate(router)
        #expect(response.error == nil)
        #expect(payload(response)["source"]?.stringValue == "local")
        #expect(PlayboxProgression.validate(degrees: degrees(response)) != nil)
    }

    /// ⭐ The gate's own escape hatch: a run that must never spend a real API
    /// call takes the local branch deliberately rather than by accident.
    @Test("⭐ preferLocal skips the AI leg entirely")
    func preferLocalSkipsTheProvider() async {
        let (router, _) = makeRouter(generator: FakeGenerator(degrees: [7, 7, 7, 7]))
        let response = await generate(router, ["preferLocal": .bool(true)])
        #expect(payload(response)["source"]?.stringValue == "local")
        #expect(degrees(response) != [7, 7, 7, 7], "the scripted AI answer was never asked for")
        #expect(payload(response)["reason"] == nil,
                "choosing local is not a failure and has nothing to explain")
    }

    // MARK: - ⚠️ The project's own facts are the defaults

    /// ⚠️ `macro.songSkeleton` establishes tempo and section markers; a Playbox
    /// sequence that ignored them would fight the arrangement the user has.
    @Test("⚠️ tempo and SECTION default from the project, not from a constant")
    func projectFactsAreTheDefaults() async {
        let store = ProjectStore()
        try? store.setTempo(92)
        _ = try? store.addMarker(name: "Intro", beat: 0)
        _ = try? store.addMarker(name: "Chorus", beat: 32)
        _ = try? store.addMarker(name: "Outro", beat: 96)
        try? store.seek(toBeats: 40)
        let spy = RequestSpy()
        let router = CommandRouter(store: store, chordProgressionGenerator: { spy })
        _ = await router.handle(
            ControlRequest(id: "1", command: "playbox.generate", params: [:]))
        let seen = await spy.seen
        #expect(seen?.tempoBPM == 92)
        #expect(seen?.sectionName == "Chorus",
                "the marker at or before the playhead — not the first, not the last")
        #expect(seen?.bars == 4, "the default length is one four-bar phrase")
        #expect(seen?.keyMode == .major)
    }

    @Test("explicit params override the project's defaults")
    func explicitParamsWin() async {
        let store = ProjectStore()
        try? store.setTempo(92)
        let spy = RequestSpy()
        let router = CommandRouter(store: store, chordProgressionGenerator: { spy })
        _ = await router.handle(ControlRequest(id: "1", command: "playbox.generate", params: [
            "keyTonic": .number(7), "keyMode": .string("minor"), "bars": .number(8),
            "tempoBPM": .number(140), "section": .string("Bridge"),
            "style": .string("dreamy indie"),
        ]))
        let seen = await spy.seen
        #expect(seen?.keyTonic == 7)
        #expect(seen?.keyMode == .minor)
        #expect(seen?.bars == 8)
        #expect(seen?.tempoBPM == 140)
        #expect(seen?.sectionName == "Bridge")
        #expect(seen?.style == "dreamy indie")
    }

    @Test("out-of-range inputs are clamped or refused, never passed through")
    func inputsAreBounded() async {
        let (router, _) = makeRouter()
        let long = await generate(router, ["bars": .number(9_999), "preferLocal": .bool(true)])
        #expect(degrees(long).count == PlayboxProgression.barsRange.upperBound)
        let short = await generate(router, ["bars": .number(0), "preferLocal": .bool(true)])
        #expect(degrees(short).count == PlayboxProgression.barsRange.lowerBound)
        // A tonic outside 0-11 wraps rather than indexing off the end.
        let wrapped = await generate(router, ["keyTonic": .number(-5), "preferLocal": .bool(true)])
        #expect(wrapped.error == nil)
        // …but a nonsense SCALE is a teaching error, since guessing is worse.
        let badMode = await generate(router, ["keyMode": .string("lydian")])
        #expect(badMode.error?.contains("major") == true)
        #expect(badMode.error?.contains("lydian") == true)
    }

    /// ⛔ Whatever path ran, the answer is playable on the seven degrees the
    /// chord row actually has.
    @Test("⛔ every answer is a valid diatonic progression, on BOTH paths")
    func everyAnswerIsPlayable() async {
        let (localRouter, _) = makeRouter(
            makeError: AIServiceError.noProviderConfigured(capability: "chord-progression"))
        let (aiRouter, _) = makeRouter(generator: FakeGenerator(degrees: [2, 5, 1]))
        for router in [localRouter, aiRouter] {
            for _ in 0..<20 {
                let out = degrees(await generate(router))
                #expect(PlayboxProgression.validate(degrees: out) != nil)
                #expect(out.allSatisfy { PlayboxProgression.degreeRange.contains($0) })
            }
        }
    }
}
