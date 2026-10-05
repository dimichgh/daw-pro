import Foundation
import Testing
import AIServices
import DAWCore
@testable import DAWAppKit

/// m34-g — **PLAYBOX'S STATE MACHINE, against a scripted fake generator.**
///
/// ⛔ **NO NETWORK, NO KEY, NO `.env`.** The generator is injected, exactly as
/// `LyricsWorkshopModel`'s writer is, so this suite can assert the no-key story
/// and the bad-answer story without either one depending on what is configured
/// on the machine running it.
@Suite("Playbox model (m34-g)")
@MainActor
struct PlayboxModelTests {

    /// A generator that answers with whatever it was scripted with.
    private struct FakeGenerator: ChordProgressionGenerating {
        let degrees: [Int]
        let provider: String
        func generateProgression(_ request: PlayboxRequest) async throws -> PlayboxPlan {
            PlayboxPlan(degrees: degrees, name: "Playbox",
                        provenance: PlayboxProvenance(kind: .ai, detail: provider))
        }
    }

    /// A generator that fails the way a real one does.
    private struct ThrowingGenerator: ChordProgressionGenerating {
        let error: Error
        func generateProgression(_ request: PlayboxRequest) async throws -> PlayboxPlan {
            throw error
        }
    }

    /// Records the request it was asked with. An `actor` rather than a locked
    /// class: `ChordProgressionGenerating` is `Sendable` and its method is
    /// `async`, so the isolation is free and no `@unchecked` is needed.
    private actor RequestSpy: ChordProgressionGenerating {
        private(set) var seen: PlayboxRequest?
        func generateProgression(_ request: PlayboxRequest) async throws -> PlayboxPlan {
            seen = request
            return PlayboxPlan(degrees: [1, 5, 6, 4], name: "Playbox",
                               provenance: PlayboxProvenance(kind: .ai, detail: "anthropic"))
        }
    }

    /// Records what the model applied, standing in for the lit-key surface.
    @MainActor private final class Sink {
        var applied: [PlayboxPlan] = []
    }

    private func model(
        generator: (any ChordProgressionGenerating)? = nil,
        makeError: Error? = nil,
        request: PlayboxRequest = PlayboxRequest(),
        sink: Sink,
        seed: UInt64 = 42
    ) -> PlayboxModel {
        PlayboxModel(
            makeGenerator: {
                if let makeError { throw makeError }
                return generator ?? FakeGenerator(degrees: [1, 5, 6, 4], provider: "anthropic")
            },
            contextProvider: { request },
            applier: { sink.applied.append($0) },
            seedProvider: { seed })
    }

    // MARK: - The AI path

    @Test("a good AI answer is applied, and it is credited to the provider")
    func aiAnswerIsAppliedAndCredited() async {
        let sink = Sink()
        let playbox = model(generator: FakeGenerator(degrees: [1, 6, 4, 5],
                                                     provider: "anthropic"), sink: sink)
        #expect(playbox.state == .idle)
        let plan = await playbox.generate()
        #expect(plan.degrees == [1, 6, 4, 5])
        #expect(plan.provenance.kind == .ai)
        #expect(plan.provenance.detail == "anthropic")
        #expect(plan.provenance.reason == nil)
        #expect(playbox.state == .ready)
        #expect(playbox.plan == plan)
        #expect(sink.applied.count == 1, "the lights are set exactly once")
        #expect(sink.applied.first?.degrees == [1, 6, 4, 5])
    }

    // MARK: - The no-key story, which IS the feature for most people

    /// ⛔⛔ **A FEATURE THAT IS DEAD WITHOUT A KEY IS DEAD FOR ANYONE WHO HAS NOT
    /// SET ONE UP.** With no provider configured, Playbox still lights something
    /// — and it stops claiming the AI wrote it.
    @Test("⛔ NO PROVIDER CONFIGURED still produces lights, credited to the LIBRARY")
    func noProviderFallsBackAndSaysSo() async {
        let sink = Sink()
        let playbox = model(
            makeError: AIServiceError.noProviderConfigured(capability: "chord-progression"),
            sink: sink)
        let plan = await playbox.generate()
        #expect(PlayboxProgression.validate(degrees: plan.degrees) != nil)
        #expect(plan.provenance.kind == .local)
        #expect(plan.provenance.isAI == false)
        #expect(!plan.provenance.summary.contains("AI"),
                "⛔ the fallback must never claim authorship it did not earn")
        #expect(plan.provenance.reason != nil, "…and it says WHY it ran")
        #expect(playbox.state == .ready, "there is no failure state — the operation succeeded")
        #expect(sink.applied.count == 1)
    }

    @Test("⛔ a TRANSPORT failure falls back the same way")
    func transportFailureFallsBack() async {
        let sink = Sink()
        let playbox = model(
            generator: ThrowingGenerator(
                error: AIServiceError.requestFailed(status: 529, body: "overloaded")),
            sink: sink)
        let plan = await playbox.generate()
        #expect(plan.provenance.kind == .local)
        #expect(plan.provenance.reason?.isEmpty == false)
        #expect(sink.applied.count == 1, "the user still gets lights")
    }

    /// ⛔ A model that answers with prose, Roman numerals or an out-of-range
    /// degree must not light a key that does not exist. The clients throw
    /// `malformedResponse` in exactly that case (pinned in
    /// `ChordProgressionProviderTests`); this is the model's half of the
    /// contract.
    @Test("⛔ an INVALID AI answer falls back rather than lighting nonsense")
    func invalidAnswerFallsBack() async {
        let sink = Sink()
        let playbox = model(
            generator: ThrowingGenerator(
                error: AIServiceError.malformedResponse("not a usable progression")),
            sink: sink)
        let plan = await playbox.generate()
        #expect(plan.provenance.kind == .local)
        #expect(PlayboxProgression.validate(degrees: plan.degrees) != nil)
    }

    /// ⛔⛔ **THE DEBUG SEAM IS COMPILED INTO THE SHIPPING APP.** A sticky
    /// `preferLocal` would let one `debug.musicalTyping {playbox:"local"}` call
    /// turn the user's NEW LIGHTS button into a library-only button until they
    /// relaunched — a setting nothing on screen offers and nothing could undo.
    @Test("⛔ preferLocal is ONE-SHOT — a debug call cannot reconfigure the button")
    func preferLocalIsConsumed() async {
        let sink = Sink()
        let playbox = model(generator: FakeGenerator(degrees: [1, 6, 4, 5],
                                                     provider: "anthropic"),
                            sink: sink)
        playbox.preferLocal = true
        let local = await playbox.generate()
        #expect(local.provenance.kind == .local, "the flag was honoured…")
        #expect(local.provenance.reason == nil,
                "…and choosing local deliberately is not a failure")
        #expect(playbox.preferLocal == false, "⛔ …and then consumed")

        let next = await playbox.generate()
        #expect(next.provenance.kind == .ai,
                "the NEXT press asks the model again, as the button always did")
        #expect(next.degrees == [1, 6, 4, 5])
    }

    // MARK: - The project's own facts are the inputs

    @Test("⚠️ the request carries the PROJECT's key, mode, tempo and section")
    func requestCarriesProjectContext() async {
        let sink = Sink()
        let spy = RequestSpy()
        let playbox = PlayboxModel(
            makeGenerator: { spy },
            contextProvider: {
                PlayboxRequest(keyTonic: 9, keyMode: .minor, tempoBPM: 140,
                               sectionName: "Bridge", bars: 4)
            },
            applier: { sink.applied.append($0) })
        playbox.bars = 8
        playbox.style = "  synthwave  "
        _ = await playbox.generate()
        let seen = await spy.seen
        #expect(seen?.keyTonic == 9)
        #expect(seen?.keyMode == .minor)
        #expect(seen?.tempoBPM == 140)
        #expect(seen?.sectionName == "Bridge")
        #expect(seen?.bars == 8, "the model's own bars override the context's")
        #expect(seen?.style == "synthwave", "trimmed")
    }

    @Test("a blank style contributes NOTHING rather than an empty string")
    func blankStyleIsDropped() async {
        let sink = Sink()
        let spy = RequestSpy()
        let playbox = PlayboxModel(makeGenerator: { spy },
                                   applier: { sink.applied.append($0) })
        playbox.style = "   "
        _ = await playbox.generate()
        #expect(await spy.seen?.style == nil)
    }

    @Test("an out-of-range bars request is clamped before it reaches the provider")
    func barsAreClamped() async {
        let sink = Sink()
        let spy = RequestSpy()
        let playbox = PlayboxModel(makeGenerator: { spy },
                                   applier: { sink.applied.append($0) })
        playbox.bars = 9_999
        _ = await playbox.generate()
        #expect(await spy.seen?.bars == PlayboxProgression.barsRange.upperBound)
    }

    /// ⛔⛔ **THE PROPERTY THAT MAKES THIS FEATURE WORTH HAVING.** Playbox
    /// produces an INVITATION, never a performance: nothing it does sounds or
    /// records a note. Asserted structurally — the applier is the ONLY output
    /// seam, and everything that crosses it is a scale degree.
    @Test("⛔ Playbox's only output is a list of DEGREES — never a note, never a take")
    func playboxNeverPlaysForYou() async {
        let sink = Sink()
        let playbox = model(sink: sink)
        _ = await playbox.generate()
        #expect(sink.applied.count == 1)
        #expect(sink.applied.first?.degrees
            .allSatisfy { PlayboxProgression.degreeRange.contains($0) } == true)
    }
}
