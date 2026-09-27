import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for m23-h's `track.reorder` — the ONE
/// track-ordering verb the arrange header drag, the mixer drag (m23-z) and any
/// agent all commit through.
///
/// Covers: FINAL-index semantics in BOTH directions (the `fx.reorder`
/// convention, deliberately NOT SwiftUI's `onMove` pre-removal offset), the
/// ground-truth echo, clamping, the same-index no-op, the error taxonomy
/// (unknown track, missing/typo'd keys), one undo step read back through
/// `edit.history`, and the additive-at-END command-list law.
@MainActor
@Suite("Track reorder — control protocol")
struct TrackReorderCommandTests {
    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    /// Four audio tracks A…D, returning their wire ids in order.
    private func addTracks(_ router: CommandRouter) async throws -> [String] {
        var ids: [String] = []
        for name in ["A", "B", "C", "D"] {
            let response = await router.handle(ControlRequest(
                id: "t\(name)", command: "track.add",
                params: ["name": .string(name), "kind": .string("audio")]))
            ids.append(try #require(response.result?["id"]?.stringValue))
        }
        return ids
    }

    private func reorder(_ router: CommandRouter, _ trackID: String,
                         _ index: Double) async -> ControlResponse {
        await router.handle(ControlRequest(
            id: "r", command: "track.reorder",
            params: ["trackId": .string(trackID), "index": .number(index)]))
    }

    // MARK: - Semantics + echo

    @Test("a DOWN move uses FINAL-index semantics and echoes the resulting order")
    func downMoveEchoesGroundTruth() async throws {
        let (router, store) = makeRouter()
        let ids = try await addTracks(router)

        // A (0) -> 2 lands A AT index 2: B, C, A, D. Under the `onMove`
        // pre-removal convention this same call would land A at 1, so this is
        // the assert that discriminates the two conventions on the wire.
        let response = await reorder(router, ids[0], 2)
        #expect(response.ok)
        #expect(response.result?["index"]?.doubleValue == 2)
        let order = try #require(response.result?["order"]?.arrayValue)
        #expect(order.compactMap(\.stringValue) == [ids[1], ids[2], ids[0], ids[3]])
        // The echo is GROUND TRUTH, not a restatement of the request: it agrees
        // with the store read back independently.
        #expect(store.tracks.map(\.name) == ["B", "C", "A", "D"])
    }

    @Test("an UP move lands at the same final index (the half-pass an up-only fixture hides)")
    func upMoveEchoesGroundTruth() async throws {
        let (router, store) = makeRouter()
        let ids = try await addTracks(router)

        let response = await reorder(router, ids[3], 1)
        #expect(response.ok)
        #expect(response.result?["index"]?.doubleValue == 1)
        let order = try #require(response.result?["order"]?.arrayValue)
        #expect(order.compactMap(\.stringValue) == [ids[0], ids[3], ids[1], ids[2]])
        #expect(store.tracks.map(\.name) == ["A", "D", "B", "C"])
    }

    @Test("an out-of-range index clamps; a same-index move is an ok no-op")
    func clampsAndNoOps() async throws {
        let (router, store) = makeRouter()
        let ids = try await addTracks(router)

        let past = await reorder(router, ids[0], 99)
        #expect(past.ok)
        #expect(past.result?["index"]?.doubleValue == 3)
        #expect(store.tracks.map(\.name) == ["B", "C", "D", "A"])

        let negative = await reorder(router, ids[0], -5)
        #expect(negative.ok)
        #expect(negative.result?["index"]?.doubleValue == 0)
        #expect(store.tracks.map(\.name) == ["A", "B", "C", "D"])

        // Same index: ok, echoes the (unchanged) order, journals nothing.
        let history = await router.handle(ControlRequest(id: "h0", command: "edit.history"))
        let depthBefore = try #require(history.result?["undo"]?.arrayValue).count
        let same = await reorder(router, ids[1], 1)
        #expect(same.ok)
        #expect(same.result?["index"]?.doubleValue == 1)
        let after = await router.handle(ControlRequest(id: "h1", command: "edit.history"))
        #expect(try #require(after.result?["undo"]?.arrayValue).count == depthBefore)
        #expect(store.tracks.map(\.name) == ["A", "B", "C", "D"])
    }

    // MARK: - Atomicity, read back through the wire

    @Test("one reorder is ONE undo step — asserted by edit.history DEPTH, not by looks")
    func oneUndoStepOverTheWire() async throws {
        let (router, store) = makeRouter()
        let ids = try await addTracks(router)
        let before = await router.handle(ControlRequest(id: "h0", command: "edit.history"))
        let depthBefore = try #require(before.result?["undo"]?.arrayValue).count

        #expect(await reorder(router, ids[0], 3).ok)

        let after = await router.handle(ControlRequest(id: "h1", command: "edit.history"))
        let undo = try #require(after.result?["undo"]?.arrayValue)
        #expect(undo.count == depthBefore + 1)
        #expect(undo.first?.stringValue == "Move Track 'A'")

        // …and ONE undo puts the order back.
        #expect(await router.handle(ControlRequest(id: "u", command: "edit.undo")).ok)
        #expect(store.tracks.map(\.name) == ["A", "B", "C", "D"])
    }

    // MARK: - Error taxonomy

    @Test("an unknown track id is refused with a readable error and moves nothing")
    func unknownTrackRefused() async throws {
        let (router, store) = makeRouter()
        _ = try await addTracks(router)
        let response = await reorder(router, UUID().uuidString, 0)
        #expect(!response.ok)
        #expect(response.error?.lowercased().contains("track") == true)
        #expect(store.tracks.map(\.name) == ["A", "B", "C", "D"])
    }

    @Test("a malformed trackId, a missing index, and an unknown key are each refused")
    func parameterHardening() async throws {
        let (router, store) = makeRouter()
        let ids = try await addTracks(router)

        let badID = await router.handle(ControlRequest(
            id: "1", command: "track.reorder",
            params: ["trackId": .string("not-a-uuid"), "index": .number(0)]))
        #expect(!badID.ok)

        let noIndex = await router.handle(ControlRequest(
            id: "2", command: "track.reorder", params: ["trackId": .string(ids[0])]))
        #expect(!noIndex.ok)
        #expect(noIndex.error?.contains("index") == true)

        // The F5 hardening convention: a plausible typo (`toIndex`, the Swift
        // parameter label) must be REFUSED, never silently treated as "index
        // omitted" — which here would otherwise look like an accepted no-op.
        let typo = await router.handle(ControlRequest(
            id: "3", command: "track.reorder",
            params: ["trackId": .string(ids[0]), "toIndex": .number(2)]))
        #expect(!typo.ok)
        #expect(typo.error?.contains("toIndex") == true)

        // Nothing moved through any of the three refusals.
        #expect(store.tracks.map(\.name) == ["A", "B", "C", "D"])
    }

    // MARK: - Wire law

    @Test("track.reorder is advertised at the END of allCommands; count 153 -> 154")
    func advertisedAtEnd() {
        #expect(CommandRouter.allCommands.contains("track.reorder"))
        // m23-k3's import pair and m23-k4a's export pair landed after it,
        // under the same law; count 154 -> 156 -> 158. m23-n2b's
        // clip.transcribe landed after that; count 158 -> 159. m23-n3b's
        // install/status pair landed after THAT; count 159 -> 161 —
        // clip.transcribe is no longer last (see
        // SpeechModelInstallCommandTests for that leg).
        #expect(CommandRouter.allCommands.count == 256)   // 159 -> 161 at m23-n3b -> 162 at m23-r4 -> 163 at m23-o1 -> 165 at m23-w -> 166 at m23-af -> 168 at m20-j -> 169 at m23-br-1 -> 171 at m23-aj-2 -> 173 at m23-dl -> 174 at m23-di-2a -> 175 at m25-d -> 176 at m25-z -> 177 at m23-ap-3 -> 178 (clip.getNotes) -> 179 (m26-i instrument.describeSampler) -> 180 (edit.pasteClips) -> 181 (m27 leg D clip.applyBreathContour, placed next to its controller-lane siblings, NOT at the tail) -> 182 (breath pad P1 clip.applyEffortShape, placed next to clip.applyBreathContour, NOT at the tail) -> 183 (breath pad P6 pad.previewEffort, placed next to note.audition — the other 'sounds now, outside the timeline, not an edit' verb — NOT at the tail) -> 186 (m28-knob midi.getControlMap/setControlMap/learnControl, placed next to midi.listInputs — their only sibling on this surface — and BEFORE transport.record, NOT at the tail) -> 187 (m31-f instrument.probeLiveness) -> 188 (m31-c clip.repeatNotes, placed next to clip.setNotes/clip.getNotes, NOT at the tail) -> 189 (m26-a/m27-n clip.patchNotes, placed next to clip.repeatNotes, NOT at the tail) -> 190 (m32-b2 clip.sliceToSampler, placed next to clip.detectTransients/clip.quantizeAudio, NOT at the tail) -> 191 (m24-m leg A vc.convertClips, placed next to vc.convertVocals — its single-clip sibling — NOT at the tail) -> 193 (m24-n project.embeddedVoices next to project.snapshot/project.open, and vc.installEmbeddedVoice next to vc.importVoiceModel, both at the tail per the additive-at-end law) -> 194 (m23-ct note.play, placed next to note.audition/pad.previewEffort — the other 'sounds now, outside the timeline' verbs — NOT at the tail; a tail append reddened 19 end-relative assertions across 7 files on this item's first run) -> 195 (m23-cv chord.voice, a PURE read-only computation, placed next to note.play and NOT at the tail: LivePlayCommandTests pins note.play to pad.previewEffort + 1, so an insertion BEFORE it would redden that instead) -> 202 (m34-c instrument.listDownloadableSoundBanks/downloadSoundBank/soundBankDownloadStatus/cancelSoundBankDownload — the one-click SoundFont download, all four placed next to instrument.importSoundBank — their nearest sibling — and NOT at the tail, so every dropLast(N) window above stays true by construction; a tail placement was tried first and reddened 14 tests) -> 211 (m34-h-1 LIVE LOOPING looper.begin/armLayer/finishLayer/undoLayer/setLayerMuted/status/end, all seven placed immediately after transport.recordLayer/finishLayer — the verbs whose machinery the deck drives — and ~71 entries from the END, NOT at the tail, so every dropLast(N) window and suffix assertion above stays true by construction) -> 215 (M35 view.capture/view.selectClip/view.panelLayout/view.openEditor, the agent-facing VIEW surface, all four placed immediately after plugin.listOpenUIs and ~70 entries from the END, NOT at the tail) -> 218 (m39-f instrument.describeSynth, placed next to instrument.describeSampler, NOT at the tail) -> 231 at m39-dm (instrument.setDrumParam/describeDrumKit/listDrumPresets/loadDrumPreset — the drum machine's four verbs, placed next to instrument.describeSynth/describeSampler, their only siblings on this surface, and NOT at the tail, so every dropLast(N) window and suffix assertion stays true by construction) -> 234 at m23-q (clip.autoCorrectPitch/clip.clearPitchEdits/clip.getPitchEdits, appended at the tail) -> 237 at p2-c (view.openPitchEditor next to view.openEditor; clip.setNotePitch/clip.splitNote next to clip.sliceToSampler, NOT at the tail) -> 239 at m39-levels-2 wire (instrument.spreadSlice/instrument.setSpreadDirection, placed next to instrument.describeSampler, NOT at the tail) -> 241 at I7a (clip.setNoteCleared, placed next to clip.getPlayedPitch in the per-note door cluster, NOT at the tail) -> 243 at the I4 wire leg (clip.setNotePitches, placed next to clip.setNoteGain in the same per-note pitch-editor door cluster beside clip.sliceToSampler, NOT at the tail; two added since I7a — U-D's clip.setNoteGain landed 242 without a matching entry appended here, so this suffix continues from 241, not 242) -> 244 at the I1 wire leg (clip.auditionNote, placed immediately after clip.setNotePitches — a deliberate departure from the tail-of-cluster rule, since this verb is not a per-note WRITER like its neighbours and no dropLast(N)/suffix-window pin anywhere depends on it landing at the tail — still beside clip.sliceToSampler) -> 245 at UB-2 (clip.findUnpitchedSounds, placed immediately after clip.auditionNote, in the same per-note pitch-editor door cluster beside clip.sliceToSampler, NOT at the tail) -> 247 at C5a-3/NT-L3 (clip.setNoteVibrato/clip.setNoteVibratos, placed immediately after clip.findUnpitchedSounds, in the same per-note pitch-editor door cluster beside clip.sliceToSampler, NOT at the tail; two verbs land together) -> 252 at NT-W (clip.setNoteFormant/clip.setFormantCorrection/clip.setNoteTransition/clip.setPitchTransitionSmoothness/clip.setNoteGlideFollow, placed immediately after clip.setNoteVibratos, in the same per-note pitch-editor door cluster beside clip.sliceToSampler, NOT at the tail; five verbs land together) -> 253 at NT-W over NT-C C2 (clip.setConsonantProtection, placed immediately after clip.setNoteGlideFollow, in the same per-note pitch-editor door cluster beside clip.sliceToSampler, NOT at the tail; NT-E2 has since landed (2026-09-26) -- the render mix is live)
        // -> 187 (m31-f instrument.probeLiveness, placed next to instrument.describeSampler — its read-only instrument.* sibling — NOT at the tail)
        // Additive: every pre-existing track.* verb is untouched, in place.
        for name in ["track.add", "track.remove", "track.rename", "track.setVolume",
                     "track.setPan", "track.setMute", "track.setSolo", "track.setOutput",
                     "track.addSend", "track.setSend", "track.removeSend",
                     "track.setInstrument", "track.bounceInPlace", "track.setArm"] {
            #expect(CommandRouter.allCommands.contains(name), "\(name) missing")
        }
    }

    @Test("the copilot can see it: track.reorder is a catalog tool with both params required")
    func inCopilotCatalog() throws {
        let tool = try #require(CopilotToolCatalog.tool(command: "track.reorder"))
        let required = try #require(tool.schema["required"]?.arrayValue).compactMap(\.stringValue)
        #expect(Set(required) == ["trackId", "index"])
        // The catalog teaches FINAL-index semantics explicitly — an agent that
        // assumed the `onMove` convention would move tracks to the wrong slot.
        #expect(tool.description.contains("FINAL position"))
    }
}
