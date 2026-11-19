import Foundation
import Testing
@testable import AIServices
@testable import DAWControl
@testable import DAWCore

/// p2-sing-x7 part B (W8-X7B), S6 (design `docs/design/2026-10-06-p2-sing-expansion.md` §9.2): WITHOUT the new params,
/// `sing.render` (dry run and a real submit), `sing.jobStatus`, `sing.cancelJob` and `ai.writeLyrics` reply byte for
/// byte as they did before x7b, and the lyrics writer is handed the same request and the same prompts. Every pin was
/// captured on the UNCHANGED tree (`X7BPin`). Nonisolated (the tree is at its `@MainActor` suite cap).
@Suite("SingWire x7b S6 — sing.render / jobStatus / writeLyrics without the new params reply as before (p2-sing-x7b)")
struct SingWireX7BPinTests {

    @Test("S6: sing.render without parts — the dry-run plan, the submitted reply and the coordinator request are the pin-before ones")
    func s6RenderUnchanged() async throws {
        let root = try SingWireFixture.tempDir("x7b-s6")
        defer { try? FileManager.default.removeItem(at: root) }
        let (clipID, bare) = try await MainActor.run { () -> (UUID, CommandRouter) in
            let (store, clipID) = try SingWireFixture.store(root: root, lyrics: SingWireFixture.twoUnitLyrics)
            return (clipID, CommandRouter(store: store))
        }
        let clip = JSONValue.string(clipID.uuidString)
        let a = await bare.handle(SingWireFixture.request("sing.render", ["clipId": clip, "dryRun": .bool(true)]))
        #expect(a.error == nil)
        #expect(try X7APin.canonical(a.result) == X7BPin.renderDryRun)
        let b = await bare.handle(SingWireFixture.request("sing.render", [
            "clipId": clip, "dryRun": .bool(true), "octaveShift": .number(0),
            "lyrics": .string("one two three\nfive six seven eight")]))
        #expect(b.error == nil)
        #expect(try X7APin.canonical(b.result) == X7BPin.renderDryRunLyrics)

        let base = URL(string: "http://127.0.0.1:\(try SingWireFixture.unusedLoopbackPort())")!
        let lifecycle = await SingWireFixture.lifecycle(root, baseURL: base)
        let engine = SingWireFakeEngine(config: SingWireFixture.config(root: root, baseURL: base, lifecycle: lifecycle),
                                        state: .installedNotRunning)
        let jobs = SingWireFakeJobs()
        let probe = SingWireInstallProbe()
        let (clip2, router) = try await MainActor.run { () -> (UUID, CommandRouter) in
            let (store2, clip2) = try SingWireFixture.store(root: root, lyrics: SingWireFixture.twoUnitLyrics)
            let services = SingWireFixture.services(root: root, engine: engine, jobs: jobs,
                                                    installFunction: probe.function,
                                                    trash: SingWireFixture.trash(into: root))
            return (clip2, CommandRouter(store: store2, singServices: services))
        }
        let c = await router.handle(SingWireFixture.request("sing.render", [
            "clipId": .string(clip2.uuidString), "seed": .number(7), "trackName": .string("Lead vocal")]))
        #expect(c.error == nil)
        #expect(try X7APin.canonical(c.result) == X7BPin.renderSubmit)
        let request = try #require(await jobs.submitted.first)
        #expect(request.parts.isEmpty, "a render without parts asks the coordinator for no parts")
        #expect(request.key == nil, "a render without parts gives the coordinator no key")
        #expect(c.result?["plan"]?["parts"] == nil, "no parts key in the plan")
        #expect(c.result?["status"]?["parts"] == nil, "no parts key in the status")

        let d = await router.handle(SingWireFixture.request("sing.jobStatus", ["jobId": .string("sing-test-1")]))
        #expect(d.error == nil)
        #expect(try X7APin.canonical(d.result) == X7BPin.jobStatusByID)
        let e = await router.handle(SingWireFixture.request("sing.jobStatus", [:]))
        #expect(e.error == nil)
        #expect(try X7APin.canonical(e.result) == X7BPin.jobStatusList)
        let f = await router.handle(SingWireFixture.request("sing.cancelJob", ["jobId": .string("sing-test-1")]))
        #expect(f.error == nil)
        #expect(try X7APin.canonical(f.result) == X7BPin.cancelJob)
    }

    @Test("S6: a status with a result and an error but no parts encodes as before (no parts key)")
    func s6JobJSONWithoutParts() async throws {
        var rich = SingWireFakeJobs.status(id: "sing-rich", clipID: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!,
                                           phase: .done)
        rich.unitIndex = 2
        rich.progress = 1
        rich.etaSeconds = 3
        rich.warnings = ["w1"]
        rich.notices = ["n1"]
        rich.retriedUnits = [2]
        rich.error = SingJobFailure(code: "singX", message: "m", detail: "d")
        rich.result = SingJobResult(trackID: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
                                    clipID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!,
                                    loudness: nil,
                                    gates: SingGateReport(failed: [], lengthSeconds: 4.5, plannedSeconds: 4.5,
                                                          allFinite: true, voicedCoverage: 0.9, truePeakDbtp: -3,
                                                          integratedLufs: -18, quieterThanUsual: false),
                                    melodyChanged: true, transposedSemitones: -2, noteAccuracy: nil, wordCheck: nil)
        rich.finishedAt = Date(timeIntervalSince1970: 1_800_000_100)
        #expect(rich.parts == nil)
        let json = await MainActor.run { SingWireHandlers.jobJSON(rich) }
        #expect(try X7APin.canonical(json) == X7BPin.jobJSONRich)
        #expect(json["parts"] == nil)
    }

    @Test("S6: ai.writeLyrics without fitClipId / language — the reply, the writer's request and its prompts are the pin-before ones")
    func s6WriteLyricsUnchanged() async throws {
        let writer = X7BPinWriter()
        let router = await MainActor.run { () -> CommandRouter in
            let store = ProjectStore()
            try? store.setTempo(96)
            return CommandRouter(store: store, lyricsWriter: { writer })
        }
        let h = await router.handle(SingWireFixture.request("ai.writeLyrics", [
            "prompt": .string("driving home"), "style": .string("synth-pop"),
            "structure": .array([.string("verse"), .string("chorus")])]))
        #expect(h.error == nil)
        #expect(try X7APin.canonical(h.result) == X7BPin.writeLyrics)
        let i = await router.handle(SingWireFixture.request("ai.writeLyrics", [
            "prompt": .string("rain"), "existingLyrics": .string("[verse]\nold line"),
            "instruction": .string("make it hopeful"), "context": .object(["keyScale": .string("A Minor")])]))
        #expect(i.error == nil)
        #expect(try X7APin.canonical(i.result) == X7BPin.writeLyricsRefine)
        let requests = await writer.requests
        try #require(requests.count == 2)
        #expect(requests[0] == LyricsWriteRequest(
            prompt: "driving home", style: "synth-pop", structure: ["verse", "chorus"],
            context: LyricsWriteContext(tempoBPM: 96, timeSignature: "4/4")))
        let prompts = requests.map {
            LyricsPromptBuilder.systemPrompt($0) + "\n=====USER=====\n" + LyricsPromptBuilder.userPrompt($0)
        }
        #expect(prompts[0] == X7BPin.prompt0)
        #expect(prompts[1] == X7BPin.prompt1)
    }
}

/// A lyrics writer that records every request and answers the same bracketed lyrics (no network, no key).
actor X7BPinWriter: LyricsGenerating {
    private(set) var requests: [LyricsWriteRequest] = []
    func generateLyrics(theme: String, style: String?) async throws -> String { "legacy" }
    func writeLyrics(_ request: LyricsWriteRequest) async throws -> LyricsWriteResult {
        requests.append(request)
        return LyricsWriteResult(lyrics: "[verse]\nCity lights\nhold me", provider: "anthropic")
    }
}

/// S6 pins (design `2026-10-06-p2-sing-expansion.md` §9.2 S6), captured 2026-10-07 01:14 by W8-X7B on the UNCHANGED
/// tree (the main tree at 01:05, rsynced into the lane's snapshot) through `X7APin.canonical` (sorted keys, every UUID
/// replaced by its first-appearance placeholder). Files: `$S/w8/X7B/pins-before-backup/*.txt`.
enum X7BPin {
    /// `pins/A-render-dryRun.txt`.
    static let renderDryRun = #"{"dryRun":true,"plan":{"assignment":{"lines":2,"phrases":2,"unsungNoteIds":[],"words":[{"endBeat":5,"held":false,"noteIds":["<id1>"],"startBeat":4,"text":"one"},{"endBeat":6,"held":false,"noteIds":["<id2>"],"startBeat":5,"text":"two"},{"endBeat":7,"held":false,"noteIds":["<id3>"],"startBeat":6,"text":"three"},{"endBeat":8,"held":false,"noteIds":["<id4>"],"startBeat":7,"text":"four"},{"endBeat":37,"held":false,"noteIds":["<id5>"],"startBeat":36,"text":"five"},{"endBeat":38,"held":false,"noteIds":["<id6>"],"startBeat":37,"text":"six"},{"endBeat":39,"held":false,"noteIds":["<id7>"],"startBeat":38,"text":"seven"},{"endBeat":40,"held":false,"noteIds":["<id8>"],"startBeat":39,"text":"eight"}]},"clipId":"<id9>","engine":null,"estimatedSeconds":23,"octaveChoice":{"auto":true,"octaveShift":0,"sentence":"Fits your voice."},"octaveShift":0,"units":[{"index":1,"notes":4,"onsetSeconds":2,"spanSeconds":2,"sung":["one","two","three","four"],"words":["one","two","three","four"]},{"index":2,"notes":4,"onsetSeconds":18,"spanSeconds":2,"sung":["five","six","seven","eight"],"words":["five","six","seven","eight"]}],"voice":{"id":"builtin-1","name":"Built-in singer"},"warnings":[]}}"#
    /// `pins/B-render-dryRun-lyrics.txt`.
    static let renderDryRunLyrics = #"{"dryRun":true,"plan":{"assignment":{"lines":2,"phrases":2,"unsungNoteIds":[],"words":[{"endBeat":5,"held":false,"noteIds":["<id1>"],"startBeat":4,"text":"one"},{"endBeat":6,"held":false,"noteIds":["<id2>"],"startBeat":5,"text":"two"},{"endBeat":8,"held":true,"noteIds":["<id3>","<id4>"],"startBeat":6,"text":"three"},{"endBeat":37,"held":false,"noteIds":["<id5>"],"startBeat":36,"text":"five"},{"endBeat":38,"held":false,"noteIds":["<id6>"],"startBeat":37,"text":"six"},{"endBeat":39,"held":false,"noteIds":["<id7>"],"startBeat":38,"text":"seven"},{"endBeat":40,"held":false,"noteIds":["<id8>"],"startBeat":39,"text":"eight"}]},"clipId":"<id9>","engine":null,"estimatedSeconds":23,"octaveChoice":{"auto":false,"octaveShift":0,"sentence":null},"octaveShift":0,"units":[{"index":1,"notes":4,"onsetSeconds":2,"spanSeconds":2,"sung":["one","two","three"],"words":["one","two","three"]},{"index":2,"notes":4,"onsetSeconds":18,"spanSeconds":2,"sung":["five","six","seven","eight"],"words":["five","six","seven","eight"]}],"voice":{"id":"builtin-1","name":"Built-in singer"},"warnings":["The tune has 1 more note than your words need. I held 'three' across it. Add words, or drag a word to cover different notes."]}}"#
    /// `pins/C-render-submit.txt`.
    static let renderSubmit = #"{"jobId":"sing-test-1","plan":{"assignment":{"lines":2,"phrases":2,"unsungNoteIds":[],"words":[{"endBeat":5,"held":false,"noteIds":["<id1>"],"startBeat":4,"text":"one"},{"endBeat":6,"held":false,"noteIds":["<id2>"],"startBeat":5,"text":"two"},{"endBeat":7,"held":false,"noteIds":["<id3>"],"startBeat":6,"text":"three"},{"endBeat":8,"held":false,"noteIds":["<id4>"],"startBeat":7,"text":"four"},{"endBeat":37,"held":false,"noteIds":["<id5>"],"startBeat":36,"text":"five"},{"endBeat":38,"held":false,"noteIds":["<id6>"],"startBeat":37,"text":"six"},{"endBeat":39,"held":false,"noteIds":["<id7>"],"startBeat":38,"text":"seven"},{"endBeat":40,"held":false,"noteIds":["<id8>"],"startBeat":39,"text":"eight"}]},"clipId":"<id9>","engine":{"needsInstall":false,"needsStart":true,"state":"installedNotRunning"},"estimatedSeconds":23,"octaveChoice":{"auto":true,"octaveShift":0,"sentence":"Fits your voice."},"octaveShift":0,"units":[{"index":1,"notes":4,"onsetSeconds":2,"spanSeconds":2,"sung":["one","two","three","four"],"words":["one","two","three","four"]},{"index":2,"notes":4,"onsetSeconds":18,"spanSeconds":2,"sung":["five","six","seven","eight"],"words":["five","six","seven","eight"]}],"voice":{"id":"builtin-1","name":"Built-in singer"},"warnings":[]},"status":{"cachedUnits":0,"cancelRequested":false,"clipId":"<id9>","engineRestarts":0,"error":null,"etaSeconds":null,"finishedAt":null,"fromAgent":true,"gates":null,"jobId":"sing-test-1","keptTakePath":null,"notices":[],"phase":"queued","progress":0,"renderedUnits":0,"result":null,"retriedUnits":[],"seed":20260924,"stageText":"stage queued","state":"queued","submittedAt":"2027-01-15T08:00:00Z","unit":{"count":2,"index":null},"waitingFor":null,"warnings":[],"yields":0}}"#
    /// `pins/D-jobStatus-id.txt`.
    static let jobStatusByID = #"{"cachedUnits":0,"cancelRequested":false,"clipId":"<id1>","engineRestarts":0,"error":null,"etaSeconds":null,"finishedAt":null,"fromAgent":true,"gates":null,"jobId":"sing-test-1","keptTakePath":null,"notices":[],"phase":"queued","progress":0,"renderedUnits":0,"result":null,"retriedUnits":[],"seed":20260924,"stageText":"stage queued","state":"queued","submittedAt":"2027-01-15T08:00:00Z","unit":{"count":2,"index":null},"waitingFor":null,"warnings":[],"yields":0}"#
    /// `pins/E-jobStatus-list.txt`.
    static let jobStatusList = #"{"jobs":[{"cachedUnits":0,"cancelRequested":false,"clipId":"<id1>","engineRestarts":0,"error":null,"etaSeconds":null,"finishedAt":null,"fromAgent":true,"gates":null,"jobId":"sing-test-1","keptTakePath":null,"notices":[],"phase":"queued","progress":0,"renderedUnits":0,"result":null,"retriedUnits":[],"seed":20260924,"stageText":"stage queued","state":"queued","submittedAt":"2027-01-15T08:00:00Z","unit":{"count":2,"index":null},"waitingFor":null,"warnings":[],"yields":0}]}"#
    /// `pins/F-cancelJob.txt`.
    static let cancelJob = #"{"cancelRequested":true,"jobId":"sing-test-1","status":{"cachedUnits":0,"cancelRequested":true,"clipId":"<id1>","engineRestarts":0,"error":null,"etaSeconds":null,"finishedAt":null,"fromAgent":true,"gates":null,"jobId":"sing-test-1","keptTakePath":null,"notices":[],"phase":"queued","progress":0,"renderedUnits":0,"result":null,"retriedUnits":[],"seed":20260924,"stageText":"stage queued","state":"queued","submittedAt":"2027-01-15T08:00:00Z","unit":{"count":2,"index":null},"waitingFor":null,"warnings":[],"yields":0}}"#
    /// `pins/G-jobJSON-rich.txt`.
    static let jobJSONRich = #"{"cachedUnits":0,"cancelRequested":false,"clipId":"<id1>","engineRestarts":0,"error":{"code":"singX","detail":"d","message":"m"},"etaSeconds":3,"finishedAt":"2027-01-15T08:01:40Z","fromAgent":true,"gates":null,"jobId":"sing-rich","keptTakePath":null,"notices":["n1"],"phase":"done","progress":1,"renderedUnits":0,"result":{"clipId":"<id2>","gates":{"allFinite":true,"failed":[],"integratedLufs":-18,"lengthSeconds":4.5,"plannedSeconds":4.5,"quieterThanUsual":false,"truePeakDbtp":-3,"voicedCoverage":0.9},"loudness":null,"melodyChanged":true,"noteAccuracy":null,"trackId":"<id3>","transposedSemitones":-2,"wordCheck":null},"retriedUnits":[2],"seed":20260924,"stageText":"stage done","state":"done","submittedAt":"2027-01-15T08:00:00Z","unit":{"count":2,"index":2},"waitingFor":null,"warnings":["w1"],"yields":0}"#
    /// `pins/H-writeLyrics.txt`.
    static let writeLyrics = #"{"lyrics":"[verse]\nCity lights\nhold me","provider":"anthropic"}"#
    /// `pins/I-writeLyrics-refine.txt`.
    static let writeLyricsRefine = #"{"lyrics":"[verse]\nCity lights\nhold me","provider":"anthropic"}"#
    /// `pins/J-prompt-0.txt`: the system prompt, a marker line, the user prompt.
    static let prompt0 = #"""
You are a professional lyricist working inside a digital audio workstation. Write complete, singable song lyrics a producer will drop straight into a session and feed to a vocal-synthesis engine.

FORMAT: use ACE-Step's bracketed-structure format. Put each section tag on its own line in lowercase square brackets — [verse], [chorus], [bridge], [outro] — followed by that section's lyric lines, one lyric per line. Use only these bracketed tags for structure and add no other markup.

SINGABILITY: keep lines economical (roughly 6-10 syllables) and hold a CONSISTENT syllable count across lines of the same section type, so verses scan against each other and every chorus lands the same way. Favor natural word stress and open vowels on the held notes.

PROJECT CONTEXT: the track is in tempo 96 BPM, 4/4 time. Shape phrasing, line length, and mood to fit.

Return ONLY the lyrics — no title, commentary, or explanation.
=====USER=====
Theme: driving home
Style: synth-pop
Song structure, in order: [verse] [chorus]
Write the full lyrics now, following that structure.
"""#
    /// `pins/J-prompt-1.txt`: the system prompt, a marker line, the user prompt.
    static let prompt1 = #"""
You are a professional lyricist working inside a digital audio workstation. Write complete, singable song lyrics a producer will drop straight into a session and feed to a vocal-synthesis engine.

FORMAT: use ACE-Step's bracketed-structure format. Put each section tag on its own line in lowercase square brackets — [verse], [chorus], [bridge], [outro] — followed by that section's lyric lines, one lyric per line. Use only these bracketed tags for structure and add no other markup.

SINGABILITY: keep lines economical (roughly 6-10 syllables) and hold a CONSISTENT syllable count across lines of the same section type, so verses scan against each other and every chorus lands the same way. Favor natural word stress and open vowels on the held notes.

PROJECT CONTEXT: the track is in key/scale A Minor, tempo 96 BPM, 4/4 time. Shape phrasing, line length, and mood to fit.

You are REVISING the lyrics the user provides according to their instruction. Preserve the bracketed section structure unless the instruction explicitly asks you to change it.

Return ONLY the lyrics — no title, commentary, or explanation.
=====USER=====
Here are the current lyrics to revise:
[verse]
old line
Revision instruction: make it hopeful
Keep them about: rain
"""#
}
