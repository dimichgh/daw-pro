import Foundation
import Testing
import DAWCore
import AIServices
@testable import DAWControl

/// Control-protocol coverage for m10-p-5 `vc.listVoices` — the one wire
/// addition the Voice panel item carries (the panel made voice-listing
/// user-facing, so the CLAUDE.md convention requires a command + MCP tool +
/// test). A thin passthrough onto `VoiceConverting.listVoices()` (a
/// `FakeVoiceConverting` here — declared in
/// `VoiceConversionConvertCommandTests.swift`), so this suite proves routing,
/// the no-params shape, VERBATIM descriptor encoding, and error surfacing —
/// no sidecar install or network needed. Real HTTP behavior lives in
/// AIServicesTests/VoiceConversionClientTests (stub facade).
@MainActor
@Suite("Voice list — control protocol (m10-p-5)")
struct VoiceListCommandTests {
    private func makeRouter(
        voiceConverting: FakeVoiceConverting = FakeVoiceConverting(),
        voiceConversion: FakeVoiceConversionManager = FakeVoiceConversionManager()
    ) -> (CommandRouter, FakeVoiceConverting) {
        let store = ProjectStore()
        store.media = FakeMedia()
        let router = CommandRouter(
            store: store,
            voiceConversionManager: voiceConversion,
            voiceConverting: voiceConverting)
        return (router, voiceConverting)
    }

    @Test("vc.listVoices is in the canonical command list; count moved 132 -> 133 (135 as of m10-p-6's ai.copilotGetModel/SetModel, 139 as of the chat-persist design's Phase C, 141 as of the au.* parameter surface, 142 as of m21-d's clip.fitToContent, 143 as of m21-e's clip.analyzeAudio, 144 as of m22-c's mixer.liveLoudness)")
    func commandIsCanonical() {
        #expect(CommandRouter.allCommands.contains("vc.listVoices"))
        #expect(CommandRouter.allCommands.count == 244)   // 159 -> 161 at m23-n3b -> 162 at m23-r4 -> 163 at m23-o1 -> 165 at m23-w -> 166 at m23-af -> 168 at m20-j -> 169 at m23-br-1 -> 171 at m23-aj-2 -> 173 at m23-dl -> 174 at m23-di-2a -> 175 at m25-d -> 176 at m25-z -> 177 at m23-ap-3 -> 178 (clip.getNotes) -> 179 (m26-i instrument.describeSampler) -> 180 (edit.pasteClips) -> 181 (m27 leg D clip.applyBreathContour, placed next to its controller-lane siblings, NOT at the tail) -> 182 (breath pad P1 clip.applyEffortShape, placed next to clip.applyBreathContour, NOT at the tail) -> 183 (breath pad P6 pad.previewEffort, placed next to note.audition — the other 'sounds now, outside the timeline, not an edit' verb — NOT at the tail) -> 186 (m28-knob midi.getControlMap/setControlMap/learnControl, placed next to midi.listInputs — their only sibling on this surface — and BEFORE transport.record, NOT at the tail) -> 187 (m31-f instrument.probeLiveness) -> 188 (m31-c clip.repeatNotes, placed next to clip.setNotes/clip.getNotes, NOT at the tail) -> 189 (m26-a/m27-n clip.patchNotes, placed next to clip.repeatNotes, NOT at the tail) -> 190 (m32-b2 clip.sliceToSampler, placed next to clip.detectTransients/clip.quantizeAudio, NOT at the tail) -> 191 (m24-m leg A vc.convertClips, placed next to vc.convertVocals — its single-clip sibling — NOT at the tail) -> 193 (m24-n project.embeddedVoices next to project.snapshot/project.open, and vc.installEmbeddedVoice next to vc.importVoiceModel, both at the tail per the additive-at-end law) -> 194 (m23-ct note.play, placed next to note.audition/pad.previewEffort — the other 'sounds now, outside the timeline' verbs — NOT at the tail; a tail append reddened 19 end-relative assertions across 7 files on this item's first run) -> 195 (m23-cv chord.voice, a PURE read-only computation, placed next to note.play and NOT at the tail: LivePlayCommandTests pins note.play to pad.previewEffort + 1, so an insertion BEFORE it would redden that instead) -> 202 (m34-c instrument.listDownloadableSoundBanks/downloadSoundBank/soundBankDownloadStatus/cancelSoundBankDownload — the one-click SoundFont download, all four placed next to instrument.importSoundBank — their nearest sibling — and NOT at the tail, so every dropLast(N) window above stays true by construction; a tail placement was tried first and reddened 14 tests) -> 211 (m34-h-1 LIVE LOOPING looper.begin/armLayer/finishLayer/undoLayer/setLayerMuted/status/end, all seven placed immediately after transport.recordLayer/finishLayer — the verbs whose machinery the deck drives — and ~71 entries from the END, NOT at the tail, so every dropLast(N) window and suffix assertion above stays true by construction) -> 215 (M35 view.capture/view.selectClip/view.panelLayout/view.openEditor, the agent-facing VIEW surface, all four placed immediately after plugin.listOpenUIs and ~70 entries from the END, NOT at the tail) -> 218 (m39-f instrument.describeSynth, placed next to instrument.describeSampler, NOT at the tail) -> 231 at m39-dm (instrument.setDrumParam/describeDrumKit/listDrumPresets/loadDrumPreset — the drum machine's four verbs, placed next to instrument.describeSynth/describeSampler, their only siblings on this surface, and NOT at the tail, so every dropLast(N) window and suffix assertion stays true by construction) -> 234 at m23-q (clip.autoCorrectPitch/clip.clearPitchEdits/clip.getPitchEdits, appended at the tail) -> 237 at p2-c (view.openPitchEditor next to view.openEditor; clip.setNotePitch/clip.splitNote next to clip.sliceToSampler, NOT at the tail) -> 239 at m39-levels-2 wire (instrument.spreadSlice/instrument.setSpreadDirection, placed next to instrument.describeSampler, NOT at the tail) -> 241 at I7a (clip.setNoteCleared, placed next to clip.getPlayedPitch in the per-note door cluster, NOT at the tail) -> 243 at the I4 wire leg (clip.setNotePitches, placed next to clip.setNoteGain in the same per-note pitch-editor door cluster beside clip.sliceToSampler, NOT at the tail; two added since I7a — U-D's clip.setNoteGain landed 242 without a matching entry appended here, so this suffix continues from 241, not 242) -> 244 at the I1 wire leg (clip.auditionNote, placed immediately after clip.setNotePitches — a deliberate departure from the tail-of-cluster rule, since this verb is not a per-note WRITER like its neighbours and no dropLast(N)/suffix-window pin anywhere depends on it landing at the tail — still beside clip.sliceToSampler)
        // -> 187 (m31-f instrument.probeLiveness, placed next to instrument.describeSampler — its read-only instrument.* sibling — NOT at the tail)
    }

    @Test("adding vc.listVoices left every existing vc.*/ai.sidecar* name untouched")
    func siblingNamesUnchanged() {
        for name in ["vc.sidecarStatus", "vc.sidecarStart", "vc.sidecarStop",
                     "vc.convertVocals", "vc.trainVoice",
                     "ai.sidecarStatus", "ai.sidecarStart", "ai.sidecarStop"] {
            #expect(CommandRouter.allCommands.contains(name), "\(name) missing")
        }
    }

    @Test("composes base (from its own status endpoint) FIRST + the real list, descriptors verbatim")
    func returnsDescriptorsVerbatim() async throws {
        let converting = FakeVoiceConverting()
        // The facade's REAL split (m10-p-2 design): /v1/voice/list is
        // real-user-voices-only; "base" comes from /v1/voice/base/status.
        await converting.setVoiceStatusResult(.success(
            VoiceDescriptor(id: "base", name: "Base (untrained)", state: "ready",
                            kind: "builtin", trained: false,
                            note: "pipeline smoke target — not a real voice")))
        await converting.setListVoicesResult(.success([
            VoiceDescriptor(id: "my-voice", name: "My Voice", state: "ready",
                            hasIndex: true, createdAt: "2026-07-19T00:00:00Z"),
        ]))
        let (router, fake) = makeRouter(voiceConverting: converting)

        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.listVoices", params: [:]))

        #expect(response.ok, "vc.listVoices failed: \(response.error ?? "?")")
        let voices = try #require(response.result?["voices"]?.arrayValue)
        #expect(voices.count == 2)
        // The reserved "base" smoke target FIRST, verbatim (its distinct fields).
        #expect(voices[0]["id"]?.stringValue == "base")
        #expect(voices[0]["name"]?.stringValue == "Base (untrained)")
        #expect(voices[0]["state"]?.stringValue == "ready")
        #expect(voices[0]["kind"]?.stringValue == "builtin")
        #expect(voices[0]["trained"]?.boolValue == false)
        #expect(voices[0]["note"]?.stringValue == "pipeline smoke target — not a real voice")
        // A real voice's distinct fields, verbatim; absent optionals are
        // OMITTED (Codable nil-skip), never fabricated.
        #expect(voices[1]["id"]?.stringValue == "my-voice")
        #expect(voices[1]["hasIndex"]?.boolValue == true)
        #expect(voices[1]["createdAt"]?.stringValue == "2026-07-19T00:00:00Z")
        #expect(voices[1]["kind"] == nil)
        #expect(voices[1]["note"] == nil)
        #expect(voices[0]["hasIndex"] == nil)
        // Exactly one call to each endpoint, base's from ITS status route.
        let listCalls = await fake.listVoicesCalls
        let statusCalls = await fake.voiceStatusCalls
        #expect(listCalls == 1)
        #expect(statusCalls == ["base"])
    }

    @Test("no params: an unknown key is rejected with the teaching error, client never called")
    func rejectsUnknownParams() async throws {
        let (router, fake) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.listVoices", params: ["bogus": .bool(true)]))
        #expect(!response.ok)
        #expect(response.error?.contains("bogus") == true, "the unknown key is named verbatim")
        let calls = await fake.listVoicesCalls
        #expect(calls == 0, "a rejected request must never reach the client")
    }

    /// m23-n2e: `vc.listVoices` is one of the two verbs measured live on
    /// staging returning the dangling `"… valid keys are "` sentence (the
    /// other was `transport.play`). `rejectUnknownKeys([])` now takes a
    /// distinct zero-param branch — pin the FULL corrected message as a
    /// literal so the empty-`allowed` case has a direct guard, not just the
    /// generic `contains("bogus")` check above.
    @Test("no params: the teaching error for a zero-param verb says so, verbatim, not a dangling 'valid keys are'")
    func rejectsUnknownParamsWithZeroParamTeachingMessage() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.listVoices", params: ["bogus": .bool(true)]))
        #expect(!response.ok)
        #expect(response.error == "vc.listVoices: unknown parameter 'bogus' — vc.listVoices takes no parameters")
    }

    @Test("the zero-param teaching message pluralizes — TWO unknown keys read 'parameters', sorted")
    func zeroParamTeachingMessagePluralizes() async throws {
        // m23-n2e follow-up. The singular pin above cannot see this: it passes
        // ONE key, so deleting the `unknown.count > 1` conditional from the
        // empty branch leaves it — and the entire 4103-test suite — green
        // (verified by mutation). Plural is a genuinely separate property of
        // the branch this item introduced, so it needs its own literal.
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.listVoices",
            params: ["zebra": .bool(true), "alpha": .bool(true)]))
        #expect(!response.ok)
        // Also pins the SORT: 'alpha' precedes 'zebra' regardless of dict order.
        #expect(response.error
            == "vc.listVoices: unknown parameters 'alpha', 'zebra' — vc.listVoices takes no parameters")
    }

    @Test("unreachable sidecar surfaces the manager's actionable message, never a bare connection error")
    func unreachableSurfacesManagerMessage() async throws {
        let converting = FakeVoiceConverting()
        await converting.setVoiceStatusResult(.failure(
            VoiceConversionError.sidecarUnreachable("Could not connect to the server.")))
        await converting.setListVoicesResult(.failure(
            VoiceConversionError.sidecarUnreachable("Could not connect to the server.")))
        let manager = FakeVoiceConversionManager()
        await manager.setStatusForList(VoiceConversionStatus(
            state: .installedNotRunning,
            message: "RVC voice-conversion sidecar is installed but not running — call vc.sidecarStart."))
        let (router, _) = makeRouter(voiceConverting: converting, voiceConversion: manager)

        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.listVoices", params: [:]))

        #expect(!response.ok)
        #expect(response.error == "RVC voice-conversion sidecar is installed but not running — call vc.sidecarStart.")
    }

    @Test("a facade teaching error (non-connection) passes through verbatim")
    func facadeErrorPassesThroughVerbatim() async throws {
        let converting = FakeVoiceConverting()
        await converting.setListVoicesResult(.failure(VoiceConversionError.requestFailed(
            status: 500, code: "voiceStoreUnreadable", message: "voice store directory is unreadable")))
        let (router, _) = makeRouter(voiceConverting: converting)

        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.listVoices", params: [:]))

        #expect(!response.ok)
        #expect(response.error?.contains("voiceStoreUnreadable") == true)
        #expect(response.error?.contains("voice store directory is unreadable") == true)
    }

    @Test("the at-rest truth (no trained voices yet) is exactly the base smoke target, not an empty lie")
    func atRestListIsJustBase() async throws {
        // The fakes' defaults ARE the facade's at-rest shapes: an empty real
        // list + the base status descriptor.
        let (router, _) = makeRouter()

        let response = await router.handle(ControlRequest(
            id: "1", command: "vc.listVoices", params: [:]))

        #expect(response.ok)
        let voices = try #require(response.result?["voices"]?.arrayValue)
        #expect(voices.count == 1)
        #expect(voices[0]["id"]?.stringValue == "base")
        #expect(voices[0]["kind"]?.stringValue == "builtin")
    }
}

/// File-scoped setters (the `stubStatus` precedent in
/// `VoiceConversionConvertCommandTests.swift` — that file's helpers are
/// `private`, so this file carries its own thin same-module wrappers).
private extension FakeVoiceConverting {
    func setListVoicesResult(_ result: Result<[VoiceDescriptor], Error>) { listVoicesResult = result }
    func setVoiceStatusResult(_ result: Result<VoiceDescriptor, Error>) { voiceStatusResult = result }
}

private extension FakeVoiceConversionManager {
    func setStatusForList(_ status: VoiceConversionStatus) { statusToReturn = status }
}
