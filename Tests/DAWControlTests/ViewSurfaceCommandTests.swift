import DAWCore
import Foundation
import Testing
@testable import DAWControl

/// M35 — the agent-facing VIEW surface (`view.capture` / `view.selectClip` /
/// `view.panelLayout` / `view.openEditor`) plus the pitch-editor
/// command-surface door's `view.openPitchEditor` (m23-ap Phase 2, item p2-c,
/// `docs/design/2026-09-22-pitch-editor-ui.md` §9.1): command taxonomy +
/// routing through the `ViewUIControlling` seam. A fake seam records calls and
/// returns scripted results — no AppKit, no window, no engine (the
/// `PluginUICommandTests` fixture shape, verbatim).
///
/// ⭐ **THE HEADLESS REFUSALS ARE ASSERTED WITHOUT THE SEAM INSTALLED, AND THAT
/// IS THE POINT OF THE SUITE.** The design's headless contract is that all five
/// fail LOUDLY rather than returning a success that means nothing — a
/// `plugin.listOpenUIs`-style `{available:false}` was deliberately NOT copied,
/// because "list the windows" has a true empty answer and "show me the app"
/// does not. A test that only exercised the happy path with a fake installed
/// could not tell a loud throw from a quiet empty success.
///
/// ⚠️ **`view.openPitchEditor` IS THE ONE VERB HERE WHOSE CLIP LOOKUP AND MIDI
/// REFUSAL ARE ROUTER-SIDE, NOT BEHIND THE FAKE SEAM** (`Commands.swift`'s own
/// comment on the case). That means its MIDI-clip and unknown-clip refusals are
/// provable with `viewUI` left `nil` — headless AND seam-absent at once — and
/// its headless-only refusal needs a REAL audio clip in the store (the other
/// four verbs never touch the store, so `f.midiClip`'s placeholder id is
/// enough for them even headless).
@MainActor
@Suite("CommandRouter — view.* agent-facing VIEW surface (M35)")
struct ViewSurfaceCommandTests {

    /// Records every call and hands back scripted results.
    private final class FakeViewUI: ViewUIControlling {
        var captureCalls: [String?] = []
        var selectCalls: [UUID] = []
        var layoutCalls: [(workspace: String?, editorMaximized: Bool?)] = []
        var editorCalls: [ViewEditorTarget] = []

        var openPitchEditorCalls: [UUID] = []

        var captureError: (any Error)?
        var selectResult: ViewSelectClipResult?
        var selectError: (any Error)?
        var editorResult: ViewEditorResult?
        var editorError: (any Error)?
        var openPitchEditorResult: ViewOpenPitchEditorResult?
        var openPitchEditorError: (any Error)?
        var workspace = "arrange"
        var editorMaximized = false

        func captureView(path: String?) async throws -> ViewCaptureResult {
            captureCalls.append(path)
            if let captureError { throw captureError }
            return ViewCaptureResult(
                path: path ?? "/tmp/DAWPro/ui-capture-0.png",
                width: 2560, height: 1600, method: "window",
                rect: ViewRect(x: 0, y: 0, width: 1280, height: 800),
                scale: 2, appActive: true)
        }

        func selectClipForView(_ clipID: UUID) throws -> ViewSelectClipResult {
            selectCalls.append(clipID)
            if let selectError { throw selectError }
            return selectResult ?? ViewSelectClipResult(
                clipID: clipID, trackID: UUID(), clipKind: "midi",
                editorOpen: true, reason: .pianoRollOpened, workspace: workspace)
        }

        func applyViewPanelLayout(workspace requested: String?,
                                  editorMaximized maximized: Bool?) -> ViewPanelLayoutResult {
            layoutCalls.append((requested, maximized))
            if let requested { workspace = requested }
            if let maximized { editorMaximized = maximized }
            return ViewPanelLayoutResult(workspace: workspace,
                                         editorMaximized: editorMaximized,
                                         editorFraction: 0.35)
        }

        func openViewEditor(_ target: ViewEditorTarget) async throws -> ViewEditorResult {
            editorCalls.append(target)
            if let editorError { throw editorError }
            return editorResult ?? ViewEditorResult(
                editor: .polySynth, trackID: target.trackIDForTest,
                effectID: target.effectIDForTest, title: "Poly Synth on Synth 1")
        }

        func openPitchEditorForView(_ clipID: UUID) throws -> ViewOpenPitchEditorResult {
            openPitchEditorCalls.append(clipID)
            if let openPitchEditorError { throw openPitchEditorError }
            return openPitchEditorResult ?? ViewOpenPitchEditorResult(
                clipID: clipID, trackID: UUID(), opened: true,
                reason: .pitchEditorOpened, workspace: "arrange")
        }
    }

    private struct Fixtures {
        let router: CommandRouter
        let store: ProjectStore
        let midiTrack: UUID
        let midiClip: UUID
        let audioTrack: UUID
    }

    private func makeFixtures() throws -> Fixtures {
        let store = ProjectStore()
        let router = CommandRouter(store: store)
        let midiTrack = store.addTrack(kind: .instrument).id
        let clip = try store.addMIDIClip(toTrack: midiTrack, atBeat: 0, lengthBeats: 4)
        let audioTrack = store.addTrack(kind: .audio).id
        return Fixtures(router: router, store: store, midiTrack: midiTrack,
                        midiClip: clip.id, audioTrack: audioTrack)
    }

    private func send(_ router: CommandRouter, _ command: String,
                      _ params: [String: JSONValue] = [:]) async -> ControlResponse {
        await router.handle(ControlRequest(id: "1", command: command, params: params))
    }

    /// A real AUDIO clip in the store, via the router — `PitchCorrectionCommandTests`'s
    /// `addAudioClip` shape, needed only by `view.openPitchEditor` (the one verb
    /// here whose clip lookup is router-side rather than behind the fake seam).
    /// Callers must set `f.store.media = FakeMedia()` first — the other tests in
    /// this file never add an audio clip and so never needed it.
    private func addAudioClip(_ router: CommandRouter) async throws -> (trackID: UUID, clipID: UUID) {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-view-pitch-\(UUID().uuidString).wav")
        try Data([0x00]).write(to: fileURL)
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("audio")]))
        let trackIDString = try #require(addTrack.result?["id"]?.stringValue)
        let addClip = await router.handle(ControlRequest(
            id: "c", command: "clip.addAudio",
            params: ["trackId": .string(trackIDString), "path": .string(fileURL.path),
                     "atBeat": .number(0)]))
        let clipIDString = try #require(addClip.result?["id"]?.stringValue)
        let trackID = try #require(UUID(uuidString: trackIDString))
        let clipID = try #require(UUID(uuidString: clipIDString))
        return (trackID, clipID)
    }

    // MARK: - 1. parity

    @Test("allCommands lists the five view.* commands, right after the plugin.* block")
    func allCommandsListsViewCommands() throws {
        for name in ["view.capture", "view.selectClip", "view.panelLayout", "view.openEditor",
                     "view.openPitchEditor"] {
            #expect(CommandRouter.allCommands.contains(name))
        }
        // The PLACEMENT is load-bearing, not cosmetic: ~51 assertions across the
        // suite read end-relative windows of this array, so the block sits after
        // `plugin.listOpenUIs` rather than at the tail. Pinning it here means a
        // future "just append it" edit reddens THIS test — which names the
        // reason — instead of fifty that do not. `view.openPitchEditor` landed
        // directly after `view.openEditor` (the pitch-editor command-surface
        // door, m23-ap Phase 2 p2-c) — extending the same contiguous window by
        // one rather than opening a second one.
        let all = CommandRouter.allCommands
        let anchor = try #require(all.firstIndex(of: "plugin.listOpenUIs"))
        #expect(Array(all[(anchor + 1)...(anchor + 5)])
            == ["view.capture", "view.selectClip", "view.panelLayout", "view.openEditor",
                "view.openPitchEditor"])
        #expect(all.last != "view.openEditor")
        #expect(all.last != "view.openPitchEditor")
    }

    // MARK: - 2. the headless contract — all four fail LOUDLY

    @Test("every view.* verb throws a readable, actionable error when the seam is absent")
    func headlessRefusals() async throws {
        let f = try makeFixtures()
        f.store.media = FakeMedia()
        let (_, audioClipID) = try await addAudioClip(f.router)
        // viewUI deliberately nil the whole time.
        let calls: [(String, [String: JSONValue])] = [
            ("view.capture", [:]),
            ("view.selectClip", ["clipId": .string(f.midiClip.uuidString)]),
            ("view.panelLayout", ["workspace": .string("mix")]),
            ("view.openEditor", ["trackId": .string(f.midiTrack.uuidString)]),
            // AUDIO, not `f.midiClip` — this verb's MIDI refusal is router-side
            // and would fire BEFORE the headless guard, masking exactly the
            // refusal this test wants to prove.
            ("view.openPitchEditor", ["clipId": .string(audioClipID.uuidString)]),
        ]
        for (command, params) in calls {
            let r = await send(f.router, command, params)
            // LOUD: a failure, not a success carrying an empty body.
            #expect(!r.ok, "\(command) must fail headless, not succeed emptily")
            #expect(r.result == nil, "\(command) must not return a result body headless")
            let error = try #require(r.error)
            #expect(error.contains(command), "\(command)'s error must name the verb")
            #expect(error.contains("headless"), "\(command)'s error must say why")
            // Actionable: it tells the caller what to DO about it.
            #expect(error.contains("DAWApp") || error.contains("DAWPro.app"))
        }
    }

    // MARK: - 3. rejectUnknownKeys — one call site per verb, and the layout fence

    @Test("every view.* verb rejects an unknown key, naming it, BEFORE the seam check")
    func unknownKeyRejection() async throws {
        let f = try makeFixtures()
        // Seam nil: a key error must still win, which is what proves the
        // rejectUnknownKeys site runs first.
        let calls: [(String, [String: JSONValue])] = [
            ("view.capture", ["bogus": .bool(true)]),
            ("view.selectClip", ["clipId": .string(f.midiClip.uuidString), "bogus": .bool(true)]),
            ("view.panelLayout", ["bogus": .bool(true)]),
            ("view.openEditor", ["trackId": .string(f.midiTrack.uuidString), "bogus": .bool(true)]),
            // `f.midiClip` here is fine even though this verb refuses MIDI
            // clips: `rejectUnknownKeys` is the FIRST check in the case body,
            // before the clip lookup ever runs.
            ("view.openPitchEditor", ["clipId": .string(f.midiClip.uuidString), "bogus": .bool(true)]),
        ]
        for (command, params) in calls {
            let r = await send(f.router, command, params)
            #expect(!r.ok)
            let error = try #require(r.error)
            #expect(error.contains("bogus"), "\(command) must name the bad key: \(error)")
            #expect(!error.contains("headless"),
                    "\(command)'s key error must win over the headless guard: \(error)")
        }
    }

    /// ⛔ THE NARROWED-RULE FENCE (m35-d). `docs/DESIGN-LANGUAGE.md` records
    /// adjustable layout as a NON-INVOKABLE preference; M35 narrows that to two
    /// named exceptions. This asserts the fence is ENFORCED rather than merely
    /// written down — a debug-tier key is REFUSED by name, not silently ignored,
    /// which is the difference between a boundary and a comment.
    @Test("view.panelLayout REFUSES every debug-tier layout key by name")
    func panelLayoutRefusesDebugTierKeys() async throws {
        let f = try makeFixtures()
        let fake = FakeViewUI()
        f.router.viewUI = fake
        for key in ["pianoRollRowHeight", "sidebarWidth", "rowHeight", "editorFraction",
                    "pianoRollPPB", "pianoRollMinimap", "pianoRollCenterPitch",
                    "mixerInsertsCollapsed", "waveformNormalize", "waveformVerticalZoom",
                    "followPlayhead", "auditionEnabled", "reset"] {
            let r = await send(f.router, "view.panelLayout", [key: .number(24)])
            #expect(!r.ok, "\(key) must be refused by view.panelLayout")
            let error = try #require(r.error)
            #expect(error.contains(key), "the refusal must name \(key): \(error)")
        }
        // …and it never reached the seam.
        #expect(fake.layoutCalls.isEmpty)
        withExtendedLifetime(fake) {}
    }

    // MARK: - 4. view.capture

    @Test("view.capture routes path through and mirrors debug.captureUI's window keys")
    func captureRoutes() async throws {
        let f = try makeFixtures()
        let fake = FakeViewUI()
        f.router.viewUI = fake
        let r = await send(f.router, "view.capture", ["path": .string("/tmp/shot.png")])
        #expect(r.ok)
        #expect(fake.captureCalls == ["/tmp/shot.png"])
        let obj = try #require(r.result?.objectValue)
        #expect(obj["path"]?.stringValue == "/tmp/shot.png")
        #expect(obj["width"]?.doubleValue == 2560)
        #expect(obj["height"]?.doubleValue == 1600)
        // ⚠️ ALWAYS "window". `view.capture` does NOT inherit debug.captureUI's
        // ImageRenderer fallback — a 1280x800 PNG whose every ScrollView is
        // blank is a success that means nothing.
        #expect(obj["method"]?.stringValue == "window")
        #expect(obj["scale"]?.doubleValue == 2)
        #expect(obj["appActive"]?.boolValue == true)
        let rect = try #require(obj["rect"]?.objectValue)
        #expect(rect["width"]?.doubleValue == 1280)
        #expect(rect["height"]?.doubleValue == 800)
        withExtendedLifetime(fake) {}
    }

    @Test("view.capture has NO selectClip param — that capability's one home is view.selectClip")
    func captureRejectsSelectClip() async throws {
        let f = try makeFixtures()
        f.router.viewUI = FakeViewUI()
        let r = await send(f.router, "view.capture",
                           ["selectClip": .string(f.midiClip.uuidString)])
        #expect(!r.ok)
        #expect(r.error?.contains("selectClip") == true)
    }

    @Test("view.capture surfaces the seam's error verbatim instead of a blank success")
    func captureSurfacesSeamError() async throws {
        let f = try makeFixtures()
        let fake = FakeViewUI()
        struct NoWindow: LocalizedError {
            var errorDescription: String? { "no drawable app window to capture" }
        }
        fake.captureError = NoWindow()
        f.router.viewUI = fake
        let r = await send(f.router, "view.capture")
        #expect(!r.ok)
        #expect(r.error == "no drawable app window to capture")
        #expect(r.result == nil)
        withExtendedLifetime(fake) {}
    }

    // MARK: - 5. view.selectClip — the honest reason enum (m35-c)

    @Test("view.selectClip requires a well-formed clipId")
    func selectClipValidatesID() async throws {
        let f = try makeFixtures()
        f.router.viewUI = FakeViewUI()
        var r = await send(f.router, "view.selectClip")
        #expect(!r.ok)
        #expect(r.error?.contains("clipId") == true)
        r = await send(f.router, "view.selectClip", ["clipId": .string("nope")])
        #expect(!r.ok)
        #expect(r.error?.contains("not a valid UUID") == true)
    }

    /// ⭐ m35-c's WHOLE POINT: an AUDIO clip SELECTS and opens no piano roll,
    /// and the reply SAYS SO rather than reporting a bare success an agent
    /// would then photograph and be unable to explain.
    @Test("view.selectClip reports audio-clip-has-no-editor with editorOpen:false")
    func selectClipAudioReason() async throws {
        let f = try makeFixtures()
        let fake = FakeViewUI()
        let clipID = UUID()
        fake.selectResult = ViewSelectClipResult(
            clipID: clipID, trackID: f.audioTrack, clipKind: "audio",
            editorOpen: false, reason: .audioClipHasNoEditor, workspace: "arrange")
        f.router.viewUI = fake

        let r = await send(f.router, "view.selectClip", ["clipId": .string(clipID.uuidString)])
        #expect(r.ok)                              // it SELECTED — not an error.
        let obj = try #require(r.result?.objectValue)
        #expect(obj["clipId"]?.stringValue == clipID.uuidString)
        #expect(obj["trackId"]?.stringValue == f.audioTrack.uuidString)
        #expect(obj["clipKind"]?.stringValue == "audio")
        #expect(obj["editorOpen"]?.boolValue == false)
        #expect(obj["reason"]?.stringValue == "audio-clip-has-no-editor")
        #expect(obj["workspace"]?.stringValue == "arrange")
        withExtendedLifetime(fake) {}
    }

    @Test("view.selectClip's three MIDI/workspace reasons each encode as their raw value")
    func selectClipReasonVocabulary() async throws {
        let cases: [(ViewSelectClipResult.Reason, String, Bool)] = [
            (.pianoRollOpened, "piano-roll-opened", true),
            (.audioClipHasNoEditor, "audio-clip-has-no-editor", false),
            (.workspaceIsNotArrange, "workspace-is-not-arrange", false),
        ]
        for (reason, raw, editorOpen) in cases {
            let f = try makeFixtures()
            let fake = FakeViewUI()
            let clipID = UUID()
            fake.selectResult = ViewSelectClipResult(
                clipID: clipID, trackID: f.midiTrack, clipKind: "midi",
                editorOpen: editorOpen, reason: reason,
                workspace: reason == .workspaceIsNotArrange ? "mix" : "arrange")
            f.router.viewUI = fake
            let r = await send(f.router, "view.selectClip", ["clipId": .string(clipID.uuidString)])
            #expect(r.ok)
            #expect(r.result?.objectValue?["reason"]?.stringValue == raw)
            #expect(r.result?.objectValue?["editorOpen"]?.boolValue == editorOpen)
            withExtendedLifetime(fake) {}
        }
    }

    /// m23-ap Phase 2, item p2-c — design §9.2: `view.selectClip` starts lying
    /// (about an audio clip having "no editor") unless it also carries the
    /// FOURTH reason and the `pitchEditorOpen` field. This is the fourth case
    /// `selectClipReasonVocabulary` deliberately does not fold in: its table
    /// pins `editorOpen` per case, and `pitchEditorOpen` is a SEPARATE field
    /// that is never true at the same time as `editorOpen` — folding it in
    /// would need a second column nobody else reads, for one case.
    @Test("view.selectClip's fourth reason, pitch-editor-open, carries pitchEditorOpen:true and editorOpen:false")
    func selectClipPitchEditorOpenReason() async throws {
        let f = try makeFixtures()
        let fake = FakeViewUI()
        let clipID = UUID()
        fake.selectResult = ViewSelectClipResult(
            clipID: clipID, trackID: f.audioTrack, clipKind: "audio",
            editorOpen: false, pitchEditorOpen: true, reason: .pitchEditorOpen,
            workspace: "arrange")
        f.router.viewUI = fake

        let r = await send(f.router, "view.selectClip", ["clipId": .string(clipID.uuidString)])
        #expect(r.ok, "an audio clip with its pitch editor open is a SUCCESS")
        let obj = try #require(r.result?.objectValue)
        #expect(obj["reason"]?.stringValue == "pitch-editor-open")
        #expect(obj["editorOpen"]?.boolValue == false)
        #expect(obj["pitchEditorOpen"]?.boolValue == true)
        withExtendedLifetime(fake) {}
    }

    @Test("view.selectClip's pitchEditorOpen defaults false when a fake omits it — the m23-ap-era call sites")
    func selectClipPitchEditorOpenDefaultsFalse() async throws {
        // `ViewSelectClipResult`'s `pitchEditorOpen` parameter carries a
        // default (`= false`) specifically so call sites written before this
        // item — inside this very file, e.g. `selectClipAudioReason` above —
        // keep compiling unchanged. This test pins that default itself,
        // independent of any one call site continuing to omit the argument.
        let f = try makeFixtures()
        let fake = FakeViewUI()
        let clipID = UUID()
        fake.selectResult = ViewSelectClipResult(
            clipID: clipID, trackID: f.audioTrack, clipKind: "audio",
            editorOpen: false, reason: .audioClipHasNoEditor, workspace: "arrange")
        f.router.viewUI = fake
        let r = await send(f.router, "view.selectClip", ["clipId": .string(clipID.uuidString)])
        #expect(r.ok)
        #expect(r.result?.objectValue?["pitchEditorOpen"]?.boolValue == false)
        withExtendedLifetime(fake) {}
    }

    // MARK: - 6. view.panelLayout

    @Test("view.panelLayout applies exactly the two production-tier keys and echoes them")
    func panelLayoutApplies() async throws {
        let f = try makeFixtures()
        let fake = FakeViewUI()
        f.router.viewUI = fake
        let r = await send(f.router, "view.panelLayout",
                           ["workspace": .string("mix"), "editorMaximized": .bool(true)])
        #expect(r.ok)
        #expect(fake.layoutCalls.count == 1)
        #expect(fake.layoutCalls[0].workspace == "mix")
        #expect(fake.layoutCalls[0].editorMaximized == true)
        let obj = try #require(r.result?.objectValue)
        #expect(obj["workspace"]?.stringValue == "mix")
        #expect(obj["editorMaximized"]?.boolValue == true)
        // editorFraction rides along READ-ONLY: it is independent of
        // editorMaximized, so one round trip proves the restore contract.
        #expect(obj["editorFraction"]?.doubleValue == 0.35)
        withExtendedLifetime(fake) {}
    }

    @Test("view.panelLayout with no keys is READ-ONLY (the m11-a bare-call law)")
    func panelLayoutBareCallIsRead() async throws {
        let f = try makeFixtures()
        let fake = FakeViewUI()
        fake.workspace = "mix"
        fake.editorMaximized = true
        f.router.viewUI = fake
        let r = await send(f.router, "view.panelLayout")
        #expect(r.ok)
        #expect(fake.layoutCalls.count == 1)
        #expect(fake.layoutCalls[0].workspace == nil)
        #expect(fake.layoutCalls[0].editorMaximized == nil)
        #expect(r.result?.objectValue?["workspace"]?.stringValue == "mix")
        #expect(r.result?.objectValue?["editorMaximized"]?.boolValue == true)
        withExtendedLifetime(fake) {}
    }

    @Test("view.panelLayout validates the workspace vocabulary before the seam")
    func panelLayoutValidatesWorkspace() async throws {
        let f = try makeFixtures()
        let fake = FakeViewUI()
        f.router.viewUI = fake
        let r = await send(f.router, "view.panelLayout", ["workspace": .string("sketchpad")])
        #expect(!r.ok)
        let error = try #require(r.error)
        #expect(error.contains("arrange"))
        #expect(error.contains("mix"))
        #expect(error.contains("sketchpad"))
        #expect(fake.layoutCalls.isEmpty)
        withExtendedLifetime(fake) {}
    }

    // MARK: - 7. view.openEditor

    @Test("view.openEditor resolves an instrument target and encodes the editor discriminator")
    func openEditorInstrument() async throws {
        let f = try makeFixtures()
        let fake = FakeViewUI()
        f.router.viewUI = fake
        let r = await send(f.router, "view.openEditor",
                           ["trackId": .string(f.midiTrack.uuidString)])
        #expect(r.ok)
        #expect(fake.editorCalls.count == 1)
        #expect(fake.editorCalls[0].effectIDForTest == nil)
        #expect(fake.editorCalls[0].trackIDForTest == f.midiTrack)
        let obj = try #require(r.result?.objectValue)
        #expect(obj["editor"]?.stringValue == "poly-synth")
        #expect(obj["effectId"] == .null)
        #expect(obj["alreadyOpen"]?.boolValue == false)
        withExtendedLifetime(fake) {}
    }

    @Test("view.openEditor decodes the \"master\" sentinel only WITH an effectId")
    func openEditorMasterSentinel() async throws {
        let f = try makeFixtures()
        let fake = FakeViewUI()
        fake.editorResult = ViewEditorResult(
            editor: .builtInEffect, trackID: nil, effectID: UUID(),
            title: "eq on Master")
        f.router.viewUI = fake

        // master + effectId → a master-chain effect target (nil trackID).
        let effectID = UUID()
        var r = await send(f.router, "view.openEditor",
                           ["trackId": .string("master"),
                            "effectId": .string(effectID.uuidString)])
        #expect(r.ok)
        #expect(fake.editorCalls.count == 1)
        #expect(fake.editorCalls[0].trackIDForTest == nil)
        #expect(fake.editorCalls[0].effectIDForTest == effectID)
        #expect(r.result?.objectValue?["editor"]?.stringValue == "built-in-effect")
        #expect(r.result?.objectValue?["trackId"] == .null)

        // master WITHOUT effectId → refused: the master chain has no instrument.
        r = await send(f.router, "view.openEditor", ["trackId": .string("master")])
        #expect(!r.ok)
        #expect(r.error?.contains("instrument") == true)
        #expect(fake.editorCalls.count == 1)
        withExtendedLifetime(fake) {}
    }

    @Test("view.openEditor validates trackId/effectId syntax before the seam")
    func openEditorValidatesIDs() async throws {
        let f = try makeFixtures()
        let fake = FakeViewUI()
        f.router.viewUI = fake
        var r = await send(f.router, "view.openEditor")
        #expect(!r.ok)
        #expect(r.error?.contains("trackId") == true)
        r = await send(f.router, "view.openEditor", ["trackId": .string("nope")])
        #expect(!r.ok)
        #expect(r.error?.contains("not \"master\" or a valid UUID") == true)
        r = await send(f.router, "view.openEditor",
                       ["trackId": .string(f.midiTrack.uuidString), "effectId": .string("nope")])
        #expect(!r.ok)
        #expect(r.error?.contains("effectId is not a valid UUID") == true)
        #expect(fake.editorCalls.isEmpty)
        withExtendedLifetime(fake) {}
    }

    /// The AU case DELEGATES to the `plugin.*` seam, and the proof it did is
    /// that the reply nests `plugin.openUI`'s EXACT payload rather than a second
    /// spelling of the same keys.
    @Test("view.openEditor's plugin-window result nests the plugin.openUI payload")
    func openEditorPluginWindowPayload() async throws {
        let f = try makeFixtures()
        let fake = FakeViewUI()
        let trackID = f.midiTrack
        fake.editorResult = ViewEditorResult(
            editor: .pluginWindow, trackID: trackID, effectID: nil,
            title: "DLSMusicDevice — Keys",
            pluginWindow: PluginUIWindowInfo(
                trackID: trackID, effectID: nil, title: "DLSMusicDevice — Keys",
                componentName: "DLSMusicDevice", manufacturerName: "Apple",
                isV3: false, body: .generic,
                frame: .init(x: 140, y: 120, width: 480, height: 354)),
            alreadyOpen: true)
        f.router.viewUI = fake

        let r = await send(f.router, "view.openEditor", ["trackId": .string(trackID.uuidString)])
        #expect(r.ok)
        let obj = try #require(r.result?.objectValue)
        #expect(obj["editor"]?.stringValue == "plugin-window")
        #expect(obj["alreadyOpen"]?.boolValue == true)
        let window = try #require(obj["pluginWindow"]?.objectValue)
        #expect(window["title"]?.stringValue == "DLSMusicDevice — Keys")
        #expect(window["body"]?.stringValue == "generic")
        #expect(window["frame"]?.objectValue?["width"]?.doubleValue == 480)
        withExtendedLifetime(fake) {}
    }

    @Test("a non-plugin-window result omits pluginWindow entirely")
    func openEditorOmitsPluginWindowForBuiltIns() async throws {
        let f = try makeFixtures()
        let fake = FakeViewUI()
        f.router.viewUI = fake
        let r = await send(f.router, "view.openEditor",
                           ["trackId": .string(f.midiTrack.uuidString)])
        #expect(r.ok)
        #expect(r.result?.objectValue?["pluginWindow"] == nil)
        withExtendedLifetime(fake) {}
    }

    // MARK: - 8. view.openPitchEditor (m23-ap Phase 2, item p2-c)

    @Test("view.openPitchEditor forwards clipId to the seam and round-trips its result")
    func openPitchEditorHappyPath() async throws {
        let f = try makeFixtures()
        f.store.media = FakeMedia()
        let (_, clipID) = try await addAudioClip(f.router)
        let fake = FakeViewUI()
        let resultTrackID = UUID()
        fake.openPitchEditorResult = ViewOpenPitchEditorResult(
            clipID: clipID, trackID: resultTrackID, opened: true,
            reason: .pitchEditorOpened, workspace: "arrange")
        f.router.viewUI = fake

        let r = await send(f.router, "view.openPitchEditor", ["clipId": .string(clipID.uuidString)])
        #expect(r.ok)
        #expect(fake.openPitchEditorCalls == [clipID])
        let obj = try #require(r.result?.objectValue)
        #expect(obj["clipId"]?.stringValue == clipID.uuidString)
        #expect(obj["trackId"]?.stringValue == resultTrackID.uuidString)
        #expect(obj["opened"]?.boolValue == true)
        #expect(obj["reason"]?.stringValue == "pitch-editor-opened")
        #expect(obj["workspace"]?.stringValue == "arrange")
        withExtendedLifetime(fake) {}
    }

    /// ⭐ `opened:false` with `workspace-is-not-arrange` is still `r.ok` — the
    /// pane is latched open, just not on screen. Only a clip-kind mismatch
    /// throws (below); this is the ORTHOGONAL "which workspace" axis, the
    /// `view.selectClip` shape.
    @Test("view.openPitchEditor's workspace-is-not-arrange is a SUCCESS with opened:false, not an error")
    func openPitchEditorWorkspaceIsNotArrange() async throws {
        let f = try makeFixtures()
        f.store.media = FakeMedia()
        let (trackID, clipID) = try await addAudioClip(f.router)
        let fake = FakeViewUI()
        fake.openPitchEditorResult = ViewOpenPitchEditorResult(
            clipID: clipID, trackID: trackID, opened: false,
            reason: .workspaceIsNotArrange, workspace: "mix")
        f.router.viewUI = fake

        let r = await send(f.router, "view.openPitchEditor", ["clipId": .string(clipID.uuidString)])
        #expect(r.ok, "latched-but-not-visible is success carrying an honest reason, not an error")
        let obj = try #require(r.result?.objectValue)
        #expect(obj["opened"]?.boolValue == false)
        #expect(obj["reason"]?.stringValue == "workspace-is-not-arrange")
        #expect(obj["workspace"]?.stringValue == "mix")
        withExtendedLifetime(fake) {}
    }

    /// ⭐ THE CLIP LOOKUP AND MIDI REFUSAL ARE ROUTER-SIDE, PROVABLE WITH NO
    /// SEAM INSTALLED AT ALL (`f.router.viewUI` stays nil the whole test) —
    /// exactly the property `Commands.swift`'s own comment on this case
    /// claims: "`DAWApp` has no test target, so a refusal written only in
    /// `ViewUIWireSurface.swift` would be untestable." A PLANTED defect that
    /// inverted or deleted this guard (letting a MIDI clip through) would
    /// fail HERE, headless, not only in an app that has no tests.
    @Test("view.openPitchEditor refuses a MIDI clip, headless, with no seam installed — the error names the clip")
    func openPitchEditorMIDIRefused() async throws {
        let f = try makeFixtures()
        // viewUI deliberately nil — this must fail on the MIDI check, not on
        // a missing seam, so it must never even reach that guard.
        let r = await send(f.router, "view.openPitchEditor", ["clipId": .string(f.midiClip.uuidString)])
        #expect(!r.ok)
        let error = try #require(r.error)
        #expect(error.contains(f.midiClip.uuidString), "the refusal must name the clip id: \(error)")
        #expect(error.contains("MIDI clip"), "the refusal must say why: \(error)")
        #expect(error.contains("SUNG OR PLAYED AUDIO") || error.contains("sung or played audio"),
                "the refusal must explain what the pitch editor is FOR: \(error)")
        #expect(error.contains("view.selectClip"), "the refusal must teach the fix: \(error)")
        #expect(!error.contains("headless"),
                "a MIDI clip must be refused on its own terms, not by falling through to the seam guard")
    }

    @Test("view.openPitchEditor: an unknown clip surfaces clipNotFound, headless, with no seam installed")
    func openPitchEditorUnknownClipRejected() async throws {
        let f = try makeFixtures()
        let r = await send(f.router, "view.openPitchEditor", ["clipId": .string(UUID().uuidString)])
        #expect(!r.ok)
        #expect(r.error?.contains("no clip with id") == true)
    }

    @Test("view.openPitchEditor requires a well-formed clipId and rejects unknown params")
    func openPitchEditorValidatesParams() async throws {
        let f = try makeFixtures()
        var r = await send(f.router, "view.openPitchEditor")
        #expect(!r.ok)
        #expect(r.error?.contains("clipId") == true)

        r = await send(f.router, "view.openPitchEditor", ["clipId": .string("nope")])
        #expect(!r.ok)
        #expect(r.error?.contains("not a valid UUID") == true)

        r = await send(f.router, "view.openPitchEditor",
                       ["clipId": .string(f.midiClip.uuidString), "bogus": .bool(true)])
        #expect(!r.ok)
        #expect(r.error?.contains("bogus") == true)
    }
}

/// Test-only readers for `ViewEditorTarget`'s associated values. Deliberately
/// NOT members of the shipped enum: the router is the only production code that
/// builds one and the app is the only code that destructures it, so a public
/// accessor pair would be surface nobody needs.
private extension ViewEditorTarget {
    var trackIDForTest: UUID? {
        switch self {
        case .instrument(let trackID): return trackID
        case .effect(let trackID, _): return trackID
        }
    }

    var effectIDForTest: UUID? {
        switch self {
        case .instrument: return nil
        case .effect(_, let effectID): return effectID
        }
    }
}
