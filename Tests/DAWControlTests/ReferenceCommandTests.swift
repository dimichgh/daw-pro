import Foundation
import Testing
import DAWCore
@testable import DAWControl

// m22-g P1 (design-m22g-reference-tracks §6/§9 T9): the four reference.*
// wire verbs — registration (additive-at-END law), response shapes,
// rejectUnknownKeys teaching, the refusal ladder verbatim, undo restoration
// over the wire, and the transient-state law (no monitor state in the
// snapshot).

/// Engine fake whose ONLY capabilities are reference analysis + (P2) the
/// monitor seams (the FakeLiveLoudnessEngine idiom): `result` nil ⇒ analyze
/// throws, exercising the land-without-analysis warning path;
/// `monitorSupported` false keeps the throwing protocol default's honesty
/// (a monitor is never faked); the recorded pushes let the tests pin the
/// snapshot-basis law (trim = gain-only re-apply, never a re-anchor).
@MainActor
private final class FakeReferenceEngine: AudioEngineControlling {
    var result: ReferenceAnalysis?
    /// nil = no live meter (the −14 fallback basis path).
    var liveSnapshot: LiveLoudnessSnapshot?
    var masterSnapshot = MasterAnalysisSnapshot.floor
    var monitorSupported = true
    private(set) var monitorCalls: [(on: Bool, matchGainDb: Double)] = []
    private(set) var matchGainPushes: [Double] = []
    private(set) var slotPushes: [ReferenceSlot?] = []

    func analyzeReferenceFile(at url: URL) async throws -> ReferenceAnalysis {
        guard let result else { throw ProjectError.engineUnavailable }
        return result
    }

    func liveLoudness(reset: Bool) -> LiveLoudnessSnapshot? { liveSnapshot }
    func masterAnalysis() -> MasterAnalysisSnapshot { masterSnapshot }
    func referenceChanged(_ slot: ReferenceSlot?) { slotPushes.append(slot) }
    func setReferenceMonitor(on: Bool, matchGainDb: Double) throws {
        guard monitorSupported else { throw ProjectError.engineUnavailable }
        monitorCalls.append((on, matchGainDb))
    }
    func referenceMatchGainChanged(matchGainDb: Double) {
        matchGainPushes.append(matchGainDb)
    }

    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    func prepare() throws {}
    func shutdown() {}
    func tracksDidChange(_ tracks: [Track]) {}
    func startPlayback(_ transport: TransportState) {}
    func stopPlayback() {}
    func seek(_ transport: TransportState) {}
    func setTempo(_ transport: TransportState) {}
    func loopChanged(_ transport: TransportState) {}
    func masterVolumeChanged(_ volume: Double) {}
    func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor],
                       masterAutomation: [AutomationLane],
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL) async throws -> AudioFileInfo {
        throw ProjectError.engineUnavailable
    }
    var recordPermission: RecordPermission { .granted }
    func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {
        completion(true)
    }
    func availableInputDevices() -> [AudioInputDevice] { [] }
    func setInputDevice(uid: String?) throws {}
    func startRecording(_ transport: TransportState, to url: URL,
                        completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {
        throw ProjectError.engineUnavailable
    }
    func stopRecording() {}
}

private func cannedAnalysis() -> ReferenceAnalysis {
    ReferenceAnalysis(
        integratedLufs: -9.5,
        maxMomentaryLufs: -7.2,
        maxShortTermLufs: -8.1,
        truePeakDbtp: -0.6,
        loudnessRangeLu: 5.5,
        bandsDb: (0..<MasterAnalysisSnapshot.bandCount).map { Double($0) - 40 },
        correlation: 0.82,
        width: 0.4,
        balance: -0.05,
        durationSeconds: 212.5,
        sampleRateHz: 48_000,
        analyzerVersion: 1)
}

@MainActor
@Suite("Reference commands — control protocol (m22-g P1)")
struct ReferenceCommandTests {

    /// Router + store with a temp imports home and a real temp source file
    /// (the store checks existence and copies; FakeMedia never reads it).
    private func makeHarness(engine: FakeReferenceEngine?) throws
        -> (router: CommandRouter, store: ProjectStore, sourcePath: String) {
        let store = ProjectStore()
        store.media = FakeMedia()
        store.engine = engine
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ref-cmd-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let imports = base.appendingPathComponent("imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        store.referenceImportsDirectory = imports
        let source = base.appendingPathComponent("Night Drive.wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: source)
        return (CommandRouter(store: store), store, source.path)
    }

    @Test("the eight verbs are advertised at the END of allCommands, in order; count 144 -> 148 (P1) -> 152 (P2)")
    func advertisedAtEnd() {
        let tail = Array(CommandRouter.allCommands.suffix(8))
        #expect(tail == ["reference.import", "reference.remove",
                         "reference.status", "reference.analyze",
                         "reference.setMonitor", "reference.setOffset",
                         "reference.setTrim", "reference.compare"])
        #expect(CommandRouter.allCommands.count == 152)
        // Additive: earlier neighbors untouched.
        #expect(CommandRouter.allCommands.contains("mixer.liveLoudness"))
        #expect(CommandRouter.allCommands.contains("clip.analyzeAudio"))
    }

    @Test("import: the slot rides verbatim ({id, name, path, offsetSeconds, trimDb, analysis}); no warnings key on success")
    func importHappyPath() async throws {
        let engine = FakeReferenceEngine()
        engine.result = cannedAnalysis()
        let (router, store, sourcePath) = try makeHarness(engine: engine)

        let response = await router.handle(ControlRequest(
            id: "1", command: "reference.import",
            params: ["path": .string(sourcePath)]))
        #expect(response.ok, "reference.import failed: \(response.error ?? "?")")
        #expect(response.result?["id"]?.stringValue == store.reference?.id.uuidString)
        #expect(response.result?["name"]?.stringValue == "Night Drive")
        let wirePath = try #require(response.result?["path"]?.stringValue)
        #expect(wirePath == store.reference?.sourcePath)
        #expect(wirePath.hasPrefix(store.referenceImportsDirectory.path))
        #expect(response.result?["offsetSeconds"]?.doubleValue == 0)
        #expect(response.result?["trimDb"]?.doubleValue == 0)
        #expect(response.result?["warnings"] == nil)
        // The analysis threads the model's own Codable (can-never-drift).
        let analysis = try #require(response.result?["analysis"])
        #expect(analysis["integratedLufs"]?.doubleValue == -9.5)
        #expect(analysis["truePeakDbtp"]?.doubleValue == -0.6)
        #expect(analysis["bandsDb"]?.arrayValue?.count == MasterAnalysisSnapshot.bandCount)
        #expect(analysis["correlation"]?.doubleValue == 0.82)
        #expect(analysis["analyzerVersion"]?.doubleValue == 1)
    }

    @Test("import: analysis failure still lands the slot — analysis omitted, warnings name the retry verb")
    func importAnalysisFailureWarns() async throws {
        let engine = FakeReferenceEngine()  // result nil ⇒ analysis throws
        let (router, store, sourcePath) = try makeHarness(engine: engine)
        let response = await router.handle(ControlRequest(
            id: "1", command: "reference.import",
            params: ["path": .string(sourcePath), "name": .string("My Ref")]))
        #expect(response.ok)
        #expect(response.result?["name"]?.stringValue == "My Ref")
        #expect(response.result?["analysis"] == nil)
        let warnings = try #require(response.result?["warnings"]?.arrayValue)
        #expect(warnings.contains { $0.stringValue?.contains("reference.analyze") == true })
        #expect(store.reference != nil)
    }

    @Test("import refusals: missing file names the path; unknown keys teach; missing path param teaches")
    func importRefusals() async throws {
        let (router, _, sourcePath) = try makeHarness(engine: nil)

        let missing = await router.handle(ControlRequest(
            id: "1", command: "reference.import",
            params: ["path": .string("/tmp/not-there-\(UUID().uuidString).wav")]))
        #expect(!missing.ok)
        #expect(missing.error?.contains("no file at") == true)

        let unknown = await router.handle(ControlRequest(
            id: "2", command: "reference.import",
            params: ["path": .string(sourcePath), "replace": .bool(true)]))
        #expect(!unknown.ok)
        #expect(unknown.error?.contains("unknown parameter 'replace'") == true)
        #expect(unknown.error?.contains("'path'") == true)
        #expect(unknown.error?.contains("'name'") == true)

        let noPath = await router.handle(ControlRequest(
            id: "3", command: "reference.import"))
        #expect(!noPath.ok)
        #expect(noPath.error?.contains("path") == true)
    }

    @Test("status: empty → monitoring false, reference/preview omitted; loaded → slot + exact law preview")
    func statusShapes() async throws {
        let engine = FakeReferenceEngine()
        engine.result = cannedAnalysis()
        let (router, store, sourcePath) = try makeHarness(engine: engine)

        let empty = await router.handle(ControlRequest(id: "1", command: "reference.status"))
        #expect(empty.ok)
        #expect(empty.result?["monitoring"]?.boolValue == false)
        #expect(empty.result?["reference"] == nil)
        #expect(empty.result?["wouldMatchGainDb"] == nil)
        // The live match fields are P2's — never present un-monitored.
        #expect(empty.result?["matchGainDb"] == nil)
        #expect(empty.result?["matchBasis"] == nil)

        _ = await router.handle(ControlRequest(
            id: "2", command: "reference.import", params: ["path": .string(sourcePath)]))
        let loaded = await router.handle(ControlRequest(id: "3", command: "reference.status"))
        #expect(loaded.ok)
        #expect(loaded.result?["monitoring"]?.boolValue == false)
        let slot = try #require(loaded.result?["reference"])
        #expect(slot["id"]?.stringValue == store.reference?.id.uuidString)
        #expect(slot["analysis"]?["integratedLufs"]?.doubleValue == -9.5)
        // No live loudness on this fake → the −14 fallback basis:
        // (−14 − (−9.5)) + 0 = −4.5 (headroom −0.4 not limiting).
        #expect(loaded.result?["wouldMatchGainDb"]?.doubleValue == -4.5)

        let unknown = await router.handle(ControlRequest(
            id: "4", command: "reference.status", params: ["verbose": .bool(true)]))
        #expect(!unknown.ok)
        #expect(unknown.error?.contains("unknown parameter 'verbose'") == true)
    }

    @Test("remove: {removed, name}; empty-slot refusal verbatim; edit.undo restores the slot over the wire")
    func removeAndUndo() async throws {
        let engine = FakeReferenceEngine()
        engine.result = cannedAnalysis()
        let (router, store, sourcePath) = try makeHarness(engine: engine)
        _ = await router.handle(ControlRequest(
            id: "1", command: "reference.import", params: ["path": .string(sourcePath)]))
        let slot = try #require(store.reference)

        let removed = await router.handle(ControlRequest(id: "2", command: "reference.remove"))
        #expect(removed.ok)
        #expect(removed.result?["removed"]?.boolValue == true)
        #expect(removed.result?["name"]?.stringValue == "Night Drive")
        #expect(store.reference == nil)

        // Refusal ladder, verbatim wording (contract).
        let emptyRemove = await router.handle(ControlRequest(id: "3", command: "reference.remove"))
        #expect(!emptyRemove.ok)
        #expect(emptyRemove.error
                == "no reference track is loaded — import one with reference.import")

        // Undo over the wire restores the slot, analysis included.
        let undo = await router.handle(ControlRequest(id: "4", command: "edit.undo"))
        #expect(undo.ok)
        #expect(store.reference == slot)

        let unknown = await router.handle(ControlRequest(
            id: "5", command: "reference.remove", params: ["force": .bool(true)]))
        #expect(!unknown.ok)
        #expect(unknown.error?.contains("unknown parameter 'force'") == true)
    }

    @Test("analyze: fresh analysis rides verbatim; refusal ladder — empty slot, missing file, headless")
    func analyzeShapes() async throws {
        let engine = FakeReferenceEngine()
        let (router, store, sourcePath) = try makeHarness(engine: engine)

        // Empty slot → referenceNotSet verbatim.
        let empty = await router.handle(ControlRequest(id: "1", command: "reference.analyze"))
        #expect(!empty.ok)
        #expect(empty.error == "no reference track is loaded — import one with reference.import")

        // Import (analysis fails — engine result nil), then retry succeeds.
        _ = await router.handle(ControlRequest(
            id: "2", command: "reference.import", params: ["path": .string(sourcePath)]))
        #expect(store.reference?.analysis == nil)
        engine.result = cannedAnalysis()
        let analyzed = await router.handle(ControlRequest(id: "3", command: "reference.analyze"))
        #expect(analyzed.ok, "reference.analyze failed: \(analyzed.error ?? "?")")
        #expect(analyzed.result?["integratedLufs"]?.doubleValue == -9.5)
        #expect(analyzed.result?["bandsDb"]?.arrayValue?.count == MasterAnalysisSnapshot.bandCount)
        #expect(store.reference?.analysis == cannedAnalysis())

        // File vanished → referenceFileMissing names the path + fixing verb.
        let slotPath = try #require(store.reference?.sourcePath)
        try FileManager.default.removeItem(atPath: slotPath)
        let gone = await router.handle(ControlRequest(id: "4", command: "reference.analyze"))
        #expect(!gone.ok)
        #expect(gone.error?.contains("reference audio file is missing") == true)
        #expect(gone.error?.contains(slotPath) == true)
        #expect(gone.error?.contains("reference.import") == true)

        let unknown = await router.handle(ControlRequest(
            id: "5", command: "reference.analyze", params: ["force": .bool(true)]))
        #expect(!unknown.ok)
        #expect(unknown.error?.contains("unknown parameter 'force'") == true)
    }

    @Test("headless: import lands un-analyzed with a warning; analyze refuses engineUnavailable")
    func headlessHonesty() async throws {
        let (router, store, sourcePath) = try makeHarness(engine: nil)
        let imported = await router.handle(ControlRequest(
            id: "1", command: "reference.import", params: ["path": .string(sourcePath)]))
        #expect(imported.ok)
        #expect(imported.result?["analysis"] == nil)
        let warnings = try #require(imported.result?["warnings"]?.arrayValue)
        #expect(warnings.contains { $0.stringValue?.contains("no audio engine") == true })
        #expect(store.reference != nil)

        let analyze = await router.handle(ControlRequest(id: "2", command: "reference.analyze"))
        #expect(!analyze.ok)
        #expect(analyze.error == "audio engine not available")
    }

    @Test("project.snapshot mirrors the slot; monitor state NEVER rides the snapshot (transient-state law)")
    func snapshotMirror() async throws {
        let engine = FakeReferenceEngine()
        engine.result = cannedAnalysis()
        let (router, store, sourcePath) = try makeHarness(engine: engine)

        let before = await router.handle(ControlRequest(id: "1", command: "project.snapshot"))
        #expect(before.ok)
        #expect(before.result?["reference"] == nil)

        _ = await router.handle(ControlRequest(
            id: "2", command: "reference.import", params: ["path": .string(sourcePath)]))
        let after = await router.handle(ControlRequest(id: "3", command: "project.snapshot"))
        #expect(after.ok)
        let slot = try #require(after.result?["reference"])
        #expect(slot["id"]?.stringValue == store.reference?.id.uuidString)
        #expect(slot["path"]?.stringValue == store.reference?.sourcePath)
        // The transient A/B monitor state is reference.status-only.
        #expect(slot["monitoring"] == nil)
        #expect(after.result?["monitoring"] == nil)
    }
}

// m22-g P2 (design §5.4/§5.6/§6, T9 remainder): the four monitor-era verbs —
// registration is pinned by `advertisedAtEnd` above; here: the setMonitor
// refusal ladder VERBATIM, the exact level-match law over the wire (fallback
// + live basis + ceiling clamp), the toggle-ON snapshot law (trim re-applies
// gain only, against the frozen basis), slot echoes, compare's honest-nil
// delta block, and monitor-transience across remove/undo/snapshot.
@MainActor
@Suite("Reference monitor commands — control protocol (m22-g P2)")
struct ReferenceMonitorCommandTests {

    private func makeHarness(engine: FakeReferenceEngine?) throws
        -> (router: CommandRouter, store: ProjectStore, sourcePath: String) {
        let store = ProjectStore()
        store.media = FakeMedia()
        store.engine = engine
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ref-mon-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let imports = base.appendingPathComponent("imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        store.referenceImportsDirectory = imports
        let source = base.appendingPathComponent("Night Drive.wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: source)
        return (CommandRouter(store: store), store, source.path)
    }

    /// Harness with the canned slot already imported + analyzed.
    private func makeLoadedHarness(
        analysis: ReferenceAnalysis? = nil
    ) async throws -> (router: CommandRouter, store: ProjectStore,
                       engine: FakeReferenceEngine) {
        let engine = FakeReferenceEngine()
        engine.result = analysis ?? cannedAnalysis()
        let (router, store, sourcePath) = try makeHarness(engine: engine)
        let imported = await router.handle(ControlRequest(
            id: "setup", command: "reference.import",
            params: ["path": .string(sourcePath)]))
        try #require(imported.ok, "setup import failed: \(imported.error ?? "?")")
        return (router, store, engine)
    }

    // MARK: setMonitor — refusal ladder (verbatim teaching errors)

    @Test("setMonitor on: the §5.6 refusal ladder, each teaching error verbatim")
    func setMonitorRefusalLadder() async throws {
        // 1. Empty slot.
        let (router1, _, _) = try makeHarness(engine: FakeReferenceEngine())
        let noSlot = await router1.handle(ControlRequest(
            id: "1", command: "reference.setMonitor", params: ["on": .bool(true)]))
        #expect(!noSlot.ok)
        #expect(noSlot.error == "no reference track is loaded — import one with reference.import")

        // 2. Slot without analysis (import with a failing analyzer).
        let engine2 = FakeReferenceEngine()  // result nil ⇒ analysis fails
        let (router2, _, source2) = try makeHarness(engine: engine2)
        _ = await router2.handle(ControlRequest(
            id: "2a", command: "reference.import", params: ["path": .string(source2)]))
        let notAnalyzed = await router2.handle(ControlRequest(
            id: "2b", command: "reference.setMonitor", params: ["on": .bool(true)]))
        #expect(!notAnalyzed.ok)
        #expect(notAnalyzed.error
                == "the reference has not been analyzed yet — run reference.analyze first")

        // 3. Gated-silent reference (integratedLufs nil).
        var silent = cannedAnalysis()
        silent.integratedLufs = nil
        let (router3, _, _) = try await makeLoadedHarness(analysis: silent)
        let silentRefusal = await router3.handle(ControlRequest(
            id: "3", command: "reference.setMonitor", params: ["on": .bool(true)]))
        #expect(!silentRefusal.ok)
        #expect(silentRefusal.error?.contains("gated-silent") == true)
        #expect(silentRefusal.error?.contains("cannot be level-matched") == true)

        // 4. File missing on disk.
        let (router4, store4, _) = try await makeLoadedHarness()
        let slotPath = try #require(store4.reference?.sourcePath)
        try FileManager.default.removeItem(atPath: slotPath)
        let gone = await router4.handle(ControlRequest(
            id: "4", command: "reference.setMonitor", params: ["on": .bool(true)]))
        #expect(!gone.ok)
        #expect(gone.error?.contains("reference audio file is missing") == true)
        #expect(gone.error?.contains(slotPath) == true)

        // 5. Headless (no engine): slot present but nothing to monitor with.
        let (router5, store5, _) = try await makeLoadedHarness()
        store5.engine = nil
        let headless = await router5.handle(ControlRequest(
            id: "5", command: "reference.setMonitor", params: ["on": .bool(true)]))
        #expect(!headless.ok)
        #expect(headless.error == "audio engine not available")

        // 6. Engine without monitor capability (the throwing default's
        // honesty — a monitor is never faked).
        let (router6, _, engine6) = try await makeLoadedHarness()
        engine6.monitorSupported = false
        let unsupported = await router6.handle(ControlRequest(
            id: "6", command: "reference.setMonitor", params: ["on": .bool(true)]))
        #expect(!unsupported.ok)
        #expect(unsupported.error == "audio engine not available")

        // Param teaching: unknown key + missing required `on`.
        let unknown = await router6.handle(ControlRequest(
            id: "7", command: "reference.setMonitor",
            params: ["on": .bool(true), "gain": .number(0)]))
        #expect(!unknown.ok)
        #expect(unknown.error?.contains("unknown parameter 'gain'") == true)
        let missing = await router6.handle(ControlRequest(
            id: "8", command: "reference.setMonitor"))
        #expect(!missing.ok)
        #expect(missing.error?.contains("on") == true)

        // OFF never refuses — even with no slot at all (idempotent).
        let offEmpty = await router1.handle(ControlRequest(
            id: "9", command: "reference.setMonitor", params: ["on": .bool(false)]))
        #expect(offEmpty.ok)
        #expect(offEmpty.result?["monitoring"]?.boolValue == false)
        #expect(offEmpty.result?["matchGainDb"] == nil)
    }

    // MARK: setMonitor — the exact law over the wire

    @Test("setMonitor on, no mix reading: fallbackTarget basis, exact gain, status carries the live fields")
    func setMonitorFallbackBasis() async throws {
        let (router, store, engine) = try await makeLoadedHarness()
        // liveSnapshot nil ⇒ the −14 fallback: (−14 − (−9.5)) + 0 = −4.5;
        // headroom −1 − (−0.6) = −0.4 not limiting.
        let on = await router.handle(ControlRequest(
            id: "1", command: "reference.setMonitor", params: ["on": .bool(true)]))
        #expect(on.ok, "setMonitor failed: \(on.error ?? "?")")
        #expect(on.result?["monitoring"]?.boolValue == true)
        #expect(on.result?["matchGainDb"]?.doubleValue == -4.5)
        #expect(on.result?["matchBasis"]?.stringValue == "fallbackTarget")
        #expect(on.result?["mixIntegratedLufs"] == nil)  // no reading → omitted
        #expect(on.result?["referenceIntegratedLufs"]?.doubleValue == -9.5)
        #expect(on.result?["ceilingLimited"]?.boolValue == false)
        // The engine saw exactly one toggle with the store-computed gain.
        #expect(engine.monitorCalls.map(\.on) == [true])
        #expect(engine.monitorCalls.first?.matchGainDb == -4.5)
        #expect(store.referenceMonitor != nil)

        // status while monitoring: the reserved fields ride now.
        let status = await router.handle(ControlRequest(id: "2", command: "reference.status"))
        #expect(status.result?["monitoring"]?.boolValue == true)
        #expect(status.result?["matchGainDb"]?.doubleValue == -4.5)
        #expect(status.result?["matchBasis"]?.stringValue == "fallbackTarget")
        #expect(status.result?["ceilingLimited"]?.boolValue == false)

        // OFF: idempotent end; the reserved fields vanish again.
        let off = await router.handle(ControlRequest(
            id: "3", command: "reference.setMonitor", params: ["on": .bool(false)]))
        #expect(off.ok)
        #expect(off.result?["monitoring"]?.boolValue == false)
        #expect(off.result?["matchGainDb"] == nil)
        #expect(engine.monitorCalls.map(\.on) == [true, false])
        let statusOff = await router.handle(ControlRequest(id: "4", command: "reference.status"))
        #expect(statusOff.result?["monitoring"]?.boolValue == false)
        #expect(statusOff.result?["matchGainDb"] == nil)
        #expect(statusOff.result?["matchBasis"] == nil)
        #expect(statusOff.result?["ceilingLimited"] == nil)
        #expect(store.referenceMonitor == nil)
    }

    @Test("setMonitor on with a live mix reading: liveIntegrated basis, exact gain")
    func setMonitorLiveBasis() async throws {
        let (router, _, engine) = try await makeLoadedHarness()
        engine.liveSnapshot = LiveLoudnessSnapshot(
            integratedLufs: -18, secondsAnalyzed: 12)
        // (−18 − (−9.5)) + 0 = −8.5; headroom −0.4 not limiting.
        let on = await router.handle(ControlRequest(
            id: "1", command: "reference.setMonitor", params: ["on": .bool(true)]))
        #expect(on.ok)
        #expect(on.result?["matchGainDb"]?.doubleValue == -8.5)
        #expect(on.result?["matchBasis"]?.stringValue == "liveIntegrated")
        #expect(on.result?["mixIntegratedLufs"]?.doubleValue == -18)
        #expect(on.result?["ceilingLimited"]?.boolValue == false)
    }

    @Test("setMonitor ceiling clamp: a quiet reference matching UP is limited to the −1 dBTP ceiling")
    func setMonitorCeilingClamp() async throws {
        var quiet = cannedAnalysis()
        quiet.integratedLufs = -30  // requested (fallback): −14 + 30 = +16
        // NOTE: `store.engine` is WEAK — the engine binding must stay live.
        let (router, _, engine) = try await makeLoadedHarness(analysis: quiet)
        // headroom = −1 − (−0.6) = −0.4 → clamped, honestly flagged.
        let on = await router.handle(ControlRequest(
            id: "1", command: "reference.setMonitor", params: ["on": .bool(true)]))
        #expect(on.ok, "setMonitor failed: \(on.error ?? "?")")
        #expect(on.result?["matchGainDb"]?.doubleValue == -0.4)
        #expect(on.result?["ceilingLimited"]?.boolValue == true)
        #expect(engine.monitorCalls.first?.matchGainDb == -0.4)
    }

    // MARK: setTrim / setOffset

    @Test("setTrim while monitoring: recomputes against the FROZEN toggle-ON basis, gain-only re-apply (no re-anchor)")
    func setTrimSnapshotLaw() async throws {
        let (router, store, engine) = try await makeLoadedHarness()
        engine.liveSnapshot = LiveLoudnessSnapshot(
            integratedLufs: -18, secondsAnalyzed: 12)
        _ = await router.handle(ControlRequest(
            id: "1", command: "reference.setMonitor", params: ["on": .bool(true)]))
        // The live reading moves AFTER toggle-ON — the law must NOT chase it.
        engine.liveSnapshot = LiveLoudnessSnapshot(
            integratedLufs: -10, secondsAnalyzed: 20)
        let trim = await router.handle(ControlRequest(
            id: "2", command: "reference.setTrim", params: ["db": .number(2)]))
        #expect(trim.ok, "setTrim failed: \(trim.error ?? "?")")
        #expect(trim.result?["trimDb"]?.doubleValue == 2)
        // Frozen basis −18: (−18 + 9.5) + 2 = −6.5 — NOT (−10 + 9.5) + 2.
        #expect(trim.result?["matchGainDb"]?.doubleValue == -6.5)
        #expect(engine.matchGainPushes == [-6.5])
        // Gain-only: no second monitor toggle (no re-anchor).
        #expect(engine.monitorCalls.map(\.on) == [true])
        #expect(store.referenceMonitor?.match.matchGainDb == -6.5)

        // Un-monitored trim: slot echo only, no matchGainDb, clamp reveals.
        _ = await router.handle(ControlRequest(
            id: "3", command: "reference.setMonitor", params: ["on": .bool(false)]))
        let clamped = await router.handle(ControlRequest(
            id: "4", command: "reference.setTrim", params: ["db": .number(40)]))
        #expect(clamped.ok)
        #expect(clamped.result?["trimDb"]?.doubleValue == 24)
        #expect(clamped.result?["matchGainDb"] == nil)

        // Teaching: unknown key; empty-slot refusal verbatim.
        let unknown = await router.handle(ControlRequest(
            id: "5", command: "reference.setTrim",
            params: ["db": .number(0), "sneaky": .bool(true)]))
        #expect(!unknown.ok)
        #expect(unknown.error?.contains("unknown parameter 'sneaky'") == true)
        _ = await router.handle(ControlRequest(id: "6", command: "reference.remove"))
        let noSlot = await router.handle(ControlRequest(
            id: "7", command: "reference.setTrim", params: ["db": .number(0)]))
        #expect(!noSlot.ok)
        #expect(noSlot.error == "no reference track is loaded — import one with reference.import")
    }

    @Test("setOffset: slot echo, engine push, coalesced undo restores; empty-slot refusal verbatim")
    func setOffsetShapes() async throws {
        let (router, store, engine) = try await makeLoadedHarness()
        let pushesBefore = engine.slotPushes.count
        let set = await router.handle(ControlRequest(
            id: "1", command: "reference.setOffset", params: ["seconds": .number(12.5)]))
        #expect(set.ok, "setOffset failed: \(set.error ?? "?")")
        #expect(set.result?["offsetSeconds"]?.doubleValue == 12.5)
        #expect(set.result?["id"]?.stringValue == store.reference?.id.uuidString)
        #expect(store.reference?.offsetSeconds == 12.5)
        // The engine cache saw the moved slot (re-anchor rides this push).
        #expect(engine.slotPushes.count == pushesBefore + 1)
        #expect(engine.slotPushes.last??.offsetSeconds == 12.5)

        // Undoable (coalesced key): one undo restores offset 0.
        let undo = await router.handle(ControlRequest(id: "2", command: "edit.undo"))
        #expect(undo.ok)
        #expect(store.reference?.offsetSeconds == 0)

        let unknown = await router.handle(ControlRequest(
            id: "3", command: "reference.setOffset",
            params: ["seconds": .number(0), "beats": .number(1)]))
        #expect(!unknown.ok)
        #expect(unknown.error?.contains("unknown parameter 'beats'") == true)

        _ = await router.handle(ControlRequest(id: "4", command: "reference.remove"))
        let noSlot = await router.handle(ControlRequest(
            id: "5", command: "reference.setOffset", params: ["seconds": .number(1)]))
        #expect(!noSlot.ok)
        #expect(noSlot.error == "no reference track is loaded — import one with reference.import")
    }

    // MARK: compare

    @Test("compare: mix/reference/delta block with exact deltas; honest nils where the mix lacks evidence")
    func compareShapes() async throws {
        let (router, _, engine) = try await makeLoadedHarness()
        // Live evidence: integrated + true peak, deliberately NO LRA — the
        // lra delta must be omitted (honest nil), never fabricated.
        engine.liveSnapshot = LiveLoudnessSnapshot(
            integratedLufs: -18, truePeakDbtp: -1.2, secondsAnalyzed: 30)
        engine.masterSnapshot = .floor  // width 0, correlation +1, bands −80

        let compare = await router.handle(ControlRequest(id: "1", command: "reference.compare"))
        #expect(compare.ok, "compare failed: \(compare.error ?? "?")")
        let mix = try #require(compare.result?["mix"])
        #expect(mix["integratedLufs"]?.doubleValue == -18)
        #expect(mix["maxTruePeakDbtp"]?.doubleValue == -1.2)
        #expect(mix["loudnessRangeLu"] == nil)
        #expect(mix["width"]?.doubleValue == 0)
        #expect(mix["correlation"]?.doubleValue == 1)
        #expect(mix["bandsDb"]?.arrayValue?.count == MasterAnalysisSnapshot.bandCount)
        // The reference side is the stored analysis verbatim.
        let ref = try #require(compare.result?["reference"])
        #expect(ref["integratedLufs"]?.doubleValue == -9.5)
        #expect(ref["bandsDb"]?.arrayValue?.count == MasterAnalysisSnapshot.bandCount)
        // delta = reference − mix, per field.
        let delta = try #require(compare.result?["delta"])
        #expect(delta["lufs"]?.doubleValue == 8.5)  // −9.5 − (−18)
        #expect(delta["truePeakDb"]?.doubleValue == (-0.6) - (-1.2))
        #expect(delta["lra"] == nil)  // mix side had no evidence
        #expect(delta["width"]?.doubleValue == 0.4)  // 0.4 − 0
        #expect(delta["correlation"]?.doubleValue == 0.82 - 1.0)
        let bandDelta = try #require(delta["bandsDb"]?.arrayValue)
        #expect(bandDelta.count == MasterAnalysisSnapshot.bandCount)
        // band 0: ref −40 − mix floor −80 = +40.
        #expect(bandDelta.first?.doubleValue == 40)

        let unknown = await router.handle(ControlRequest(
            id: "2", command: "reference.compare", params: ["verbose": .bool(true)]))
        #expect(!unknown.ok)
        #expect(unknown.error?.contains("unknown parameter 'verbose'") == true)
    }

    @Test("compare refusals verbatim: no slot; not analyzed; no live meter (engineUnavailable — deltas are never faked)")
    func compareRefusals() async throws {
        // No slot.
        let (router1, _, _) = try makeHarness(engine: FakeReferenceEngine())
        let noSlot = await router1.handle(ControlRequest(id: "1", command: "reference.compare"))
        #expect(!noSlot.ok)
        #expect(noSlot.error == "no reference track is loaded — import one with reference.import")

        // Slot without analysis.
        let engine2 = FakeReferenceEngine()  // analysis fails at import
        let (router2, _, source2) = try makeHarness(engine: engine2)
        _ = await router2.handle(ControlRequest(
            id: "2a", command: "reference.import", params: ["path": .string(source2)]))
        let notAnalyzed = await router2.handle(ControlRequest(id: "2b", command: "reference.compare"))
        #expect(!notAnalyzed.ok)
        #expect(notAnalyzed.error
                == "the reference has not been analyzed yet — run reference.analyze first")

        // Analyzed slot but NO live meter (fake reports nil): floors would
        // fake deltas — refuse instead.
        let (router3, _, engine3) = try await makeLoadedHarness()
        engine3.liveSnapshot = nil
        let noMeter = await router3.handle(ControlRequest(id: "3", command: "reference.compare"))
        #expect(!noMeter.ok)
        #expect(noMeter.error == "audio engine not available")
    }

    // MARK: transience

    @Test("remove/replace while monitoring ends the audition; undo restores the slot but NEVER the monitor; snapshot stays monitor-free")
    func monitorTransience() async throws {
        let (router, store, engine) = try await makeLoadedHarness()
        _ = await router.handle(ControlRequest(
            id: "1", command: "reference.setMonitor", params: ["on": .bool(true)]))
        #expect(store.referenceMonitor != nil)

        // project.snapshot never carries monitor state, even while ON.
        let snapshot = await router.handle(ControlRequest(id: "2", command: "project.snapshot"))
        #expect(snapshot.ok)
        #expect(snapshot.result?["monitoring"] == nil)
        #expect(snapshot.result?["reference"]?["monitoring"] == nil)

        // Removing the slot mid-audition turns the monitor OFF (the engine
        // sees the off toggle; the mix un-gates).
        let removed = await router.handle(ControlRequest(id: "3", command: "reference.remove"))
        #expect(removed.ok)
        #expect(store.referenceMonitor == nil)
        #expect(engine.monitorCalls.map(\.on) == [true, false])
        let status = await router.handle(ControlRequest(id: "4", command: "reference.status"))
        #expect(status.result?["monitoring"]?.boolValue == false)

        // Undo restores the SLOT — the monitor is transient and stays off.
        let undo = await router.handle(ControlRequest(id: "5", command: "edit.undo"))
        #expect(undo.ok)
        #expect(store.reference != nil)
        #expect(store.referenceMonitor == nil)
        let statusAfterUndo = await router.handle(ControlRequest(id: "6", command: "reference.status"))
        #expect(statusAfterUndo.result?["monitoring"]?.boolValue == false)

        // Project boundary mid-audition: the monitor ends THROUGH the
        // engine (the mix un-gates — never a silently stuck gate), and the
        // fresh session carries neither slot nor monitor.
        _ = await router.handle(ControlRequest(
            id: "7", command: "reference.setMonitor", params: ["on": .bool(true)]))
        #expect(store.referenceMonitor != nil)
        let fresh = await router.handle(ControlRequest(
            id: "8", command: "project.new", params: ["discardChanges": .bool(true)]))
        #expect(fresh.ok)
        #expect(store.reference == nil)
        #expect(store.referenceMonitor == nil)
        #expect(engine.monitorCalls.map(\.on) == [true, false, true, false])
    }
}
