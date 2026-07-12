import DAWCore
import Foundation
import Testing
@testable import DAWControl

/// M3 (vi-b) plugin-UI control surface: command taxonomy + routing through the
/// `PluginUIControlling` seam. A fake seam records calls and returns scripted
/// results — no AppKit, no engine. The validation taxonomy is asserted WITHOUT
/// the seam installed, proving validation runs BEFORE the seam check (so
/// headless sessions still reject malformed targets readably).
@MainActor
@Suite("CommandRouter — plugin UI windows")
struct PluginUICommandTests {
    /// Records every call and hands back scripted results.
    private final class FakePluginUI: PluginUIControlling {
        struct OpenCall { let target: PluginUITarget; let x: Double?; let y: Double? }
        var openCalls: [OpenCall] = []
        var closeCalls: [PluginUITarget] = []
        var listCallCount = 0

        var openError: (any Error)?
        var openResult: (info: PluginUIWindowInfo, alreadyOpen: Bool)?
        var closeReturns = false
        var listReturns: [PluginUIWindowInfo] = []

        func openUI(_ target: PluginUITarget, x: Double?, y: Double?) async throws
            -> (info: PluginUIWindowInfo, alreadyOpen: Bool) {
            openCalls.append(OpenCall(target: target, x: x, y: y))
            if let openError { throw openError }
            return openResult ?? (Self.sampleInfo(for: target), false)
        }

        func closeUI(_ target: PluginUITarget) -> Bool {
            closeCalls.append(target)
            return closeReturns
        }

        func listOpenUIs() -> [PluginUIWindowInfo] {
            listCallCount += 1
            return listReturns
        }

        static func sampleInfo(for target: PluginUITarget,
                               body: PluginUIWindowInfo.BodyKind = .generic,
                               warning: String? = nil) -> PluginUIWindowInfo {
            PluginUIWindowInfo(
                trackID: target.trackID, effectID: target.effectID,
                title: "AUDelay — Drums", componentName: "AUDelay",
                manufacturerName: "Apple", isV3: false, body: body,
                frame: .init(x: 140, y: 120, width: 480, height: 354), warning: warning)
        }
    }

    /// A store with every fixture the taxonomy needs.
    private struct Fixtures {
        let router: CommandRouter
        let store: ProjectStore
        let auInstrumentTrack: UUID     // instrument track hosting an AU
        let builtinInstrumentTrack: UUID // instrument track, built-in polySynth
        let soundBankInstrumentTrack: UUID // instrument track, GM sound bank
        let audioTrack: UUID            // audio track (no instrument)
        let auEffect: UUID              // AU insert on the audio track
        let builtinEffect: UUID         // built-in gain insert on the audio track
    }

    private func makeFixtures() throws -> Fixtures {
        let store = ProjectStore()
        let router = CommandRouter(store: store)

        let auInst = store.addTrack(kind: .instrument).id
        _ = try store.setInstrument(
            id: auInst, kind: .audioUnit,
            audioUnit: AudioUnitConfig(
                component: AudioUnitComponentID(subType: "dls ", manufacturer: "appl"),
                name: "DLSMusicDevice", manufacturerName: "Apple"))

        let builtinInst = store.addTrack(kind: .instrument).id  // default polySynth

        let sbInst = store.addTrack(kind: .instrument).id
        _ = try store.setInstrument(id: sbInst,
                                    soundBank: SoundBankConfig(source: .generalMIDI, program: 56))

        let audio = store.addTrack(kind: .audio).id
        let builtinFx = try store.addEffect(toTrack: audio, kind: .gain).id
        let auFx = try store.addEffect(
            toTrack: audio, kind: .audioUnit,
            audioUnit: AudioUnitConfig(
                component: AudioUnitComponentID(type: "aufx", subType: "dely", manufacturer: "appl"),
                name: "AUDelay", manufacturerName: "Apple")).id

        return Fixtures(router: router, store: store, auInstrumentTrack: auInst,
                        builtinInstrumentTrack: builtinInst,
                        soundBankInstrumentTrack: sbInst, audioTrack: audio,
                        auEffect: auFx, builtinEffect: builtinFx)
    }

    private func open(_ router: CommandRouter, _ params: [String: JSONValue]) async -> ControlResponse {
        await router.handle(ControlRequest(id: "1", command: "plugin.openUI", params: params))
    }

    // MARK: - 1. parity

    @Test("allCommands lists the three plugin.* commands")
    func allCommandsListsPluginCommands() {
        #expect(CommandRouter.allCommands.contains("plugin.openUI"))
        #expect(CommandRouter.allCommands.contains("plugin.closeUI"))
        #expect(CommandRouter.allCommands.contains("plugin.listOpenUIs"))
    }

    // MARK: - 2. validation taxonomy (seam NOT installed → validation precedes the seam)

    @Test("plugin.openUI validation taxonomy is exact and ordered, before the seam check")
    func openValidationTaxonomy() async throws {
        let f = try makeFixtures()
        // pluginUI seam deliberately nil the whole time.

        // 1. missing trackId
        var r = await open(f.router, [:])
        #expect(!r.ok)
        #expect(r.error?.contains("trackId") == true)

        // 2. malformed trackId
        r = await open(f.router, ["trackId": .string("not-a-uuid")])
        #expect(!r.ok)
        #expect(r.error?.contains("not a valid UUID") == true)

        // 3. unknown track
        r = await open(f.router, ["trackId": .string(UUID().uuidString)])
        #expect(!r.ok)
        #expect(r.error?.contains("no track with id") == true)

        // 4. built-in instrument track
        r = await open(f.router, ["trackId": .string(f.builtinInstrumentTrack.uuidString)])
        #expect(!r.ok)
        #expect(r.error?.contains("built-in polySynth instrument") == true)
        #expect(r.error?.contains("Audio Unit instruments") == true)

        // 4b. sound-bank instrument track — tailored copy (m10-q fold-in):
        // never "built-in soundBank"; points at the program-browsing path.
        r = await open(f.router, ["trackId": .string(f.soundBankInstrumentTrack.uuidString)])
        #expect(!r.ok)
        #expect(r.error?.contains("uses a sound-bank instrument") == true)
        #expect(r.error?.contains("instrument.listSoundBankPrograms") == true)
        #expect(r.error?.contains("built-in") == false)

        // 5. audio track, no effectId
        r = await open(f.router, ["trackId": .string(f.audioTrack.uuidString)])
        #expect(!r.ok)
        #expect(r.error?.contains("audio track") == true)
        #expect(r.error?.contains("Audio Unit instruments") == true)

        // 6. unknown effectId on a real track
        r = await open(f.router, [
            "trackId": .string(f.audioTrack.uuidString),
            "effectId": .string(UUID().uuidString),
        ])
        #expect(!r.ok)
        #expect(r.error?.contains("no effect with id") == true)

        // 7. built-in-kind effect
        r = await open(f.router, [
            "trackId": .string(f.audioTrack.uuidString),
            "effectId": .string(f.builtinEffect.uuidString),
        ])
        #expect(!r.ok)
        #expect(r.error?.contains("built-in gain") == true)
        #expect(r.error?.contains("Audio Unit effects") == true)

        // 8. valid target, seam nil → the headless error (proves validation passed FIRST)
        r = await open(f.router, ["trackId": .string(f.auInstrumentTrack.uuidString)])
        #expect(!r.ok)
        #expect(r.error?.contains("plugin UI unavailable") == true)
        #expect(r.error?.contains("headless") == true)
    }

    @Test("malformed effectId on a valid AU-effect path is rejected before the seam")
    func openMalformedEffectId() async throws {
        let f = try makeFixtures()
        let r = await open(f.router, [
            "trackId": .string(f.audioTrack.uuidString),
            "effectId": .string("nope"),
        ])
        #expect(!r.ok)
        #expect(r.error?.contains("not a valid UUID") == true)
    }

    // MARK: - 3. routing with the fake installed

    @Test("plugin.openUI passes the instrument target and x/y through, mirrors the info JSON")
    func openInstrumentRoutesAndMirrors() async throws {
        let f = try makeFixtures()
        let fake = FakePluginUI()
        f.router.pluginUI = fake

        let r = await open(f.router, [
            "trackId": .string(f.auInstrumentTrack.uuidString),
            "x": .number(140), "y": .number(120),
        ])
        #expect(r.ok)
        // Target + coordinates reached the seam exactly.
        #expect(fake.openCalls.count == 1)
        #expect(fake.openCalls[0].target == .instrument(trackID: f.auInstrumentTrack))
        #expect(fake.openCalls[0].x == 140)
        #expect(fake.openCalls[0].y == 120)
        // Result JSON carries the mirrored fields.
        let obj = try #require(r.result?.objectValue)
        #expect(obj["trackId"]?.stringValue == f.auInstrumentTrack.uuidString)
        #expect(obj["effectId"] == nil)               // instrument window
        #expect(obj["title"]?.stringValue == "AUDelay — Drums")
        #expect(obj["body"]?.stringValue == "generic")
        #expect(obj["alreadyOpen"]?.boolValue == false)
        let component = try #require(obj["component"]?.objectValue)
        #expect(component["name"]?.stringValue == "AUDelay")
        #expect(component["manufacturerName"]?.stringValue == "Apple")
        #expect(component["isV3"]?.boolValue == false)
        let frame = try #require(obj["frame"]?.objectValue)
        #expect(frame["x"]?.doubleValue == 140)
        #expect(frame["y"]?.doubleValue == 120)
        #expect(frame["width"]?.doubleValue == 480)
        #expect(frame["height"]?.doubleValue == 354)
    }

    @Test("plugin.openUI passes the effect target through and carries a warning + alreadyOpen")
    func openEffectRoutesWarningAndAlreadyOpen() async throws {
        let f = try makeFixtures()
        let fake = FakePluginUI()
        let target = PluginUITarget.effect(trackID: f.audioTrack, effectID: f.auEffect)
        fake.openResult = (FakePluginUI.sampleInfo(for: target, warning: "custom view request timed out after 5s"), true)
        f.router.pluginUI = fake

        let r = await open(f.router, [
            "trackId": .string(f.audioTrack.uuidString),
            "effectId": .string(f.auEffect.uuidString),
        ])
        #expect(r.ok)
        #expect(fake.openCalls[0].target == target)
        #expect(fake.openCalls[0].x == nil)          // cascade
        #expect(fake.openCalls[0].y == nil)
        let obj = try #require(r.result?.objectValue)
        #expect(obj["effectId"]?.stringValue == f.auEffect.uuidString)
        #expect(obj["alreadyOpen"]?.boolValue == true)
        #expect(obj["warning"]?.stringValue == "custom view request timed out after 5s")
    }

    /// Stands in for the app-layer manager's `LocalizedError` taxonomy (the real
    /// `PluginWindowError` lives in DAWApp) — the router must surface its message
    /// verbatim, exactly as it does for ProjectError.
    private struct ManagerError: LocalizedError {
        let errorDescription: String?
    }

    @Test("a thrown manager error surfaces verbatim through the router")
    func openThrownErrorSurfaces() async throws {
        let f = try makeFixtures()
        let fake = FakePluginUI()
        fake.openError = ManagerError(
            errorDescription: "Audio Unit is not ready (status: pending) — retry once prepared")
        f.router.pluginUI = fake

        let r = await open(f.router, ["trackId": .string(f.auInstrumentTrack.uuidString)])
        #expect(!r.ok)
        #expect(r.error == "Audio Unit is not ready (status: pending) — retry once prepared")
    }

    // MARK: - 4. plugin.closeUI

    @Test("plugin.closeUI validates SYNTAX only — unknown-but-well-formed ids reach the seam")
    func closeSyntaxOnly() async throws {
        let f = try makeFixtures()
        let fake = FakePluginUI()
        fake.closeReturns = false
        f.router.pluginUI = fake

        // An unknown (never-added) track + effect — no store lookup, idempotent close.
        let unknownTrack = UUID()
        let unknownEffect = UUID()
        let r = await f.router.handle(ControlRequest(id: "1", command: "plugin.closeUI", params: [
            "trackId": .string(unknownTrack.uuidString),
            "effectId": .string(unknownEffect.uuidString),
        ]))
        #expect(r.ok)
        #expect(r.result?.objectValue?["closed"]?.boolValue == false)
        #expect(fake.closeCalls == [.effect(trackID: unknownTrack, effectID: unknownEffect)])
    }

    @Test("plugin.closeUI returns closed:true when the seam reports a real close")
    func closeReturnsTrue() async throws {
        let f = try makeFixtures()
        let fake = FakePluginUI()
        fake.closeReturns = true
        f.router.pluginUI = fake
        let r = await f.router.handle(ControlRequest(id: "1", command: "plugin.closeUI", params: [
            "trackId": .string(f.auInstrumentTrack.uuidString),
        ]))
        #expect(r.ok)
        #expect(r.result?.objectValue?["closed"]?.boolValue == true)
        #expect(fake.closeCalls == [.instrument(trackID: f.auInstrumentTrack)])
    }

    @Test("plugin.closeUI errors readably when the seam is nil (headless)")
    func closeHeadlessErrors() async throws {
        let f = try makeFixtures()
        let r = await f.router.handle(ControlRequest(id: "1", command: "plugin.closeUI", params: [
            "trackId": .string(f.auInstrumentTrack.uuidString),
        ]))
        #expect(!r.ok)
        #expect(r.error?.contains("plugin UI unavailable") == true)
    }

    @Test("plugin.closeUI still validates a malformed trackId (syntax)")
    func closeMalformedTrackId() async throws {
        let f = try makeFixtures()
        // Hold the fake strongly for the whole test — `pluginUI` is weak, and the
        // point is that syntax validation fires even when the seam IS present.
        let fake = FakePluginUI()
        f.router.pluginUI = fake
        let r = await f.router.handle(ControlRequest(id: "1", command: "plugin.closeUI",
                                                     params: ["trackId": .string("bad")]))
        #expect(!r.ok)
        #expect(r.error?.contains("not a valid UUID") == true)
        withExtendedLifetime(fake) {}
    }

    // MARK: - 5. plugin.listOpenUIs

    @Test("plugin.listOpenUIs answers available:false with an empty list when headless")
    func listHeadless() async throws {
        let f = try makeFixtures()
        let r = await f.router.handle(ControlRequest(id: "1", command: "plugin.listOpenUIs"))
        #expect(r.ok)
        let obj = try #require(r.result?.objectValue)
        #expect(obj["available"]?.boolValue == false)
        #expect(obj["windows"]?.arrayValue?.isEmpty == true)
    }

    @Test("plugin.listOpenUIs maps the seam's windows, ordered, with available:true")
    func listWithFake() async throws {
        let f = try makeFixtures()
        let fake = FakePluginUI()
        let instTarget = PluginUITarget.instrument(trackID: f.auInstrumentTrack)
        let fxTarget = PluginUITarget.effect(trackID: f.audioTrack, effectID: f.auEffect)
        fake.listReturns = [
            FakePluginUI.sampleInfo(for: instTarget),
            FakePluginUI.sampleInfo(for: fxTarget),
        ]
        f.router.pluginUI = fake

        let r = await f.router.handle(ControlRequest(id: "1", command: "plugin.listOpenUIs"))
        #expect(r.ok)
        #expect(fake.listCallCount == 1)
        let obj = try #require(r.result?.objectValue)
        #expect(obj["available"]?.boolValue == true)
        let windows = try #require(obj["windows"]?.arrayValue)
        #expect(windows.count == 2)
        #expect(windows[0].objectValue?["trackId"]?.stringValue == f.auInstrumentTrack.uuidString)
        #expect(windows[0].objectValue?["effectId"] == nil)
        #expect(windows[1].objectValue?["effectId"]?.stringValue == f.auEffect.uuidString)
    }
}
