import DAWCore
import Foundation
import Testing
@testable import DAWControl

/// M35 — the agent-facing VIEW surface (`view.capture` / `view.selectClip` /
/// `view.panelLayout` / `view.openEditor`): command taxonomy + routing through
/// the `ViewUIControlling` seam. A fake seam records calls and returns scripted
/// results — no AppKit, no window, no engine (the `PluginUICommandTests`
/// fixture shape, verbatim).
///
/// ⭐ **THE HEADLESS REFUSALS ARE ASSERTED WITHOUT THE SEAM INSTALLED, AND THAT
/// IS THE POINT OF THE SUITE.** The design's headless contract is that all four
/// fail LOUDLY rather than returning a success that means nothing — a
/// `plugin.listOpenUIs`-style `{available:false}` was deliberately NOT copied,
/// because "list the windows" has a true empty answer and "show me the app"
/// does not. A test that only exercised the happy path with a fake installed
/// could not tell a loud throw from a quiet empty success.
@MainActor
@Suite("CommandRouter — view.* agent-facing VIEW surface (M35)")
struct ViewSurfaceCommandTests {

    /// Records every call and hands back scripted results.
    private final class FakeViewUI: ViewUIControlling {
        var captureCalls: [String?] = []
        var selectCalls: [UUID] = []
        var layoutCalls: [(workspace: String?, editorMaximized: Bool?)] = []
        var editorCalls: [ViewEditorTarget] = []

        var captureError: (any Error)?
        var selectResult: ViewSelectClipResult?
        var selectError: (any Error)?
        var editorResult: ViewEditorResult?
        var editorError: (any Error)?
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

    // MARK: - 1. parity

    @Test("allCommands lists the four view.* commands, right after the plugin.* block")
    func allCommandsListsViewCommands() throws {
        for name in ["view.capture", "view.selectClip", "view.panelLayout", "view.openEditor"] {
            #expect(CommandRouter.allCommands.contains(name))
        }
        // The PLACEMENT is load-bearing, not cosmetic: ~51 assertions across the
        // suite read end-relative windows of this array, so the block sits after
        // `plugin.listOpenUIs` rather than at the tail. Pinning it here means a
        // future "just append it" edit reddens THIS test — which names the
        // reason — instead of fifty that do not.
        let all = CommandRouter.allCommands
        let anchor = try #require(all.firstIndex(of: "plugin.listOpenUIs"))
        #expect(Array(all[(anchor + 1)...(anchor + 4)])
            == ["view.capture", "view.selectClip", "view.panelLayout", "view.openEditor"])
        #expect(all.last != "view.openEditor")
    }

    // MARK: - 2. the headless contract — all four fail LOUDLY

    @Test("every view.* verb throws a readable, actionable error when the seam is absent")
    func headlessRefusals() async throws {
        let f = try makeFixtures()
        // viewUI deliberately nil the whole time.
        let calls: [(String, [String: JSONValue])] = [
            ("view.capture", [:]),
            ("view.selectClip", ["clipId": .string(f.midiClip.uuidString)]),
            ("view.panelLayout", ["workspace": .string("mix")]),
            ("view.openEditor", ["trackId": .string(f.midiTrack.uuidString)]),
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

    @Test("view.selectClip's three reasons each encode as their raw value")
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
