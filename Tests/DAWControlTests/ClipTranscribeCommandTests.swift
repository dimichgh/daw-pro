import Foundation
import Testing
import DAWCore
import AIServices
@testable import DAWControl

// Control-protocol coverage for m23-n2b `clip.transcribe` — wire shape,
// registration/wire-count, the MIDI/unknown-clip/unknown-key rejections
// verbatim, and the m23-n2b stretch trap (a stretched clip is REFUSED, never
// silently mis-mapped). None of these legs touch the real model: every
// rejection here fires in `ProjectStore.transcriptionSource` (see
// `ClipTranscriptionSourceTests`, DAWCoreTests) BEFORE the router ever calls
// `WhisperTranscriber.transcribe`, so this suite runs in milliseconds
// regardless of whether Whisper weights are installed on the machine. The
// real end-to-end transcription (word text + beat placement over a genuine
// audio file) is its own suite, `ClipTranscribeRealFixtureTests` below,
// mirroring `AIServicesTests/WhisperTranscriberTests.swift`'s own `say`
// fixture — that suite does not re-derive the beat-mapping math (m23-n2a's
// `TranscriptionBeatMappingTests` already discriminate at 90/140 BPM and
// across a tempo change); it proves the WIRE forwards a clip's properties
// into that math correctly, end to end.
@MainActor
@Suite("clip.transcribe — control protocol, fast legs (m23-n2b)")
struct ClipTranscribeCommandTests {
    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    private func addAudioClip(_ router: CommandRouter, atBeat: Double = 0) async throws
        -> (trackID: String, clipID: String) {
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("audio")]))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)
        let addClip = await router.handle(ControlRequest(
            id: "c", command: "clip.addAudio",
            params: ["trackId": .string(trackID), "path": .string("/tmp/Loop.wav"),
                     "atBeat": .number(atBeat)]))
        let clipID = try #require(addClip.result?["id"]?.stringValue)
        return (trackID, clipID)
    }

    private func addMIDIClip(_ router: CommandRouter) async throws
        -> (trackID: String, clipID: String) {
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("instrument")]))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)
        let addClip = await router.handle(ControlRequest(
            id: "c", command: "clip.addMIDI",
            params: ["trackId": .string(trackID), "lengthBeats": .number(4)]))
        let clipID = try #require(addClip.result?["id"]?.stringValue)
        return (trackID, clipID)
    }

    // MARK: - Wire law

    @Test("clip.transcribe is registered, additive; wire count 158 -> 159 -> 161 at m23-n3b")
    func commandRegistered() {
        let all = CommandRouter.allCommands
        #expect(all.contains("clip.transcribe"))
        // m23-n3b appended `ai.installSpeechModel`/`ai.speechModelInstallStatus`
        // AFTER this, so `clip.transcribe` is no longer last — see
        // SpeechModelInstallCommandTests for the new tail assertion. This
        // suite keeps the ordering leg (still precedes the newer verbs)
        // rather than deleting it, per the wire-count-pin law: a hand-updated
        // count is a premise that must be re-pointed deliberately, not erased.
        #expect(all.count == 166)   // 158 -> 159 at m23-n2b -> 161 at m23-n3b -> 162 at m23-r4 -> 163 at m23-o1 -> 165 at m23-w -> 166 at m23-af
        // Additive: neighboring clip.* / the just-landed MIDI export verbs
        // are untouched, in place.
        #expect(all.contains("clip.analyzeAudio"))
        #expect(all.contains("track.exportMIDI"))
        if let exportIndex = all.firstIndex(of: "track.exportMIDI"),
           let transcribeIndex = all.firstIndex(of: "clip.transcribe") {
            #expect(exportIndex < transcribeIndex)
        } else {
            Issue.record("track.exportMIDI or clip.transcribe missing from allCommands")
        }
        if let transcribeIndex = all.firstIndex(of: "clip.transcribe"),
           let installIndex = all.firstIndex(of: "ai.installSpeechModel") {
            #expect(transcribeIndex < installIndex)
        } else {
            Issue.record("clip.transcribe or ai.installSpeechModel missing from allCommands")
        }
    }

    // MARK: - Rejections (no model touched)

    @Test("MIDI clip surfaces transcriptionRequiresAudioClip verbatim, no partial mutation")
    func rejectsMIDIClip() async throws {
        let (router, store) = makeRouter()
        let (_, clipID) = try await addMIDIClip(router)
        let before = store.tracks

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.transcribe", params: ["clipId": .string(clipID)]))

        #expect(!response.ok)
        #expect(response.error == "clip \(clipID) is a MIDI clip — clip.transcribe applies only to "
            + "audio clips (read MIDI notes directly for lyrics and timing)")
        #expect(store.tracks == before)
    }

    @Test("unknown clip surfaces clipNotFound; missing clipId is field-named; no partial mutation")
    func rejectsUnknownClip() async throws {
        let (router, store) = makeRouter()
        _ = try await addAudioClip(router)
        let before = store.tracks

        let unknown = await router.handle(ControlRequest(
            id: "1", command: "clip.transcribe",
            params: ["clipId": .string(UUID().uuidString)]))
        #expect(!unknown.ok)
        #expect(unknown.error?.contains("no clip with id") == true)

        let missing = await router.handle(ControlRequest(id: "2", command: "clip.transcribe"))
        #expect(!missing.ok)
        #expect(missing.error?.contains("clipId") == true)

        #expect(store.tracks == before)
    }

    @Test("unknown params are rejected with the teaching key list, no partial mutation")
    func rejectsUnknownKeys() async throws {
        let (router, store) = makeRouter()
        let (_, clipID) = try await addAudioClip(router)
        let before = store.tracks

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.transcribe",
            params: ["clipId": .string(clipID), "sensitivity": .number(0.5)]))
        #expect(!response.ok)
        #expect(response.error?.contains("unknown parameter 'sensitivity'") == true)
        #expect(response.error?.contains("valid keys are 'clipId', 'language'") == true)
        #expect(store.tracks == before)
    }

    // THE STRETCH TRAP (m23-n2b): a stretched clip is REFUSED at the wire,
    // never silently mis-mapped. There is no code path that would transcribe
    // a stretched clip at all — correctly or not — so this pins the refusal
    // rather than mutation-testing the (absent) beat math.
    @Test("a stretched clip (stretchRatio != 1) is refused, naming the ratio, no partial mutation")
    func rejectsStretchedClip() async throws {
        let (router, store) = makeRouter()
        let (trackID, clipID) = try await addAudioClip(router)
        let stretch = await router.handle(ControlRequest(
            id: "s", command: "clip.setStretch",
            params: ["trackId": .string(trackID), "clipId": .string(clipID), "ratio": .number(1.5)]))
        #expect(stretch.ok)
        let before = store.tracks

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.transcribe", params: ["clipId": .string(clipID)]))

        #expect(!response.ok)
        #expect(response.error?.contains("non-identity time-stretch") == true)
        #expect(response.error?.contains("ratio 1.500") == true)
        #expect(response.error?.contains("clip.setStretch ratio 1") == true)
        #expect(store.tracks == before)
    }
}
