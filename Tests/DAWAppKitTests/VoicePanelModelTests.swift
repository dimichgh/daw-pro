import Foundation
import Testing
import DAWCore
import AIServices
@testable import DAWAppKit

/// Headless coverage for the Voice panel model (m10-p-5): dataset CRUD with
/// the copy-never-move import law, the add-clip-as-sample resolution (+ MIDI
/// rejection verbatim), the sidecar-state → USER-copy banner mapping (never
/// wire-speak — the m10-q law), the honest train-501 state, and — since m24-m
/// leg B — the Convert Voice… action's counting-fake proofs that it rides the
/// SAME store seam as the wire's `vc.convertClips`, that its progress names
/// which clip of how many while the run is live, and that a store refusal
/// reaches the panel VERBATIM. All against injected fakes — no sidecar, no UI,
/// no real app-support dir.

/// Actor fake for the `@Sendable` async providers (the `FakeStatus`
/// precedent in `ClipFixModelTests`): records calls, returns scripted
/// results.
actor VoiceFakes {
    var statusResult = VoiceConversionStatus(state: .healthy, message: "healthy (fake)")
    var startResult: Result<VoiceConversionStatus, Error> = .success(
        VoiceConversionStatus(state: .healthy, message: "healthy (fake)"))
    var voicesResult: Result<[VoiceDescriptor], Error> = .success([])
    var trainResult: Result<Data, Error> = .failure(VoiceConversionError.requestFailed(
        status: 501, code: "trainingNotYetAvailable",
        message: "contract reserved — training ships with the Voice panel (m10-p-5/p-6)"))
    var convertResult: Result<VoiceConvertResult, Error> = .success(VoiceConvertResult(
        outputPath: "/tmp/converted.wav", voiceId: "base", inputSeconds: 5, engineLoadSeconds: 0.5,
        inferSeconds: 0.135, rtf: 37.0, sampleRate: 40000, realConversion: false,
        note: "base is the untrained generic target"))

    private(set) var statusCalls = 0
    private(set) var startCalls = 0
    private(set) var voicesCalls = 0
    private(set) var trainCalls: [VoiceTrainRequest] = []
    private(set) var convertCalls: [VoiceConvertRequest] = []
    /// Scripted per-call results (m24-m leg B): a multi-clip run makes N
    /// converter calls, and a mixed real/not-real set is the only way to prove
    /// the outcome's honesty rule. Empty = every call gets `convertResult`.
    private var convertSequence: [Result<VoiceConvertResult, Error>] = []

    func status() async -> VoiceConversionStatus { statusCalls += 1; return statusResult }
    func start() async throws -> VoiceConversionStatus { startCalls += 1; return try startResult.get() }
    func voices() async throws -> [VoiceDescriptor] { voicesCalls += 1; return try voicesResult.get() }
    func train(_ request: VoiceTrainRequest) async throws -> Data {
        trainCalls.append(request)
        return try trainResult.get()
    }
    func convert(_ request: VoiceConvertRequest) async throws -> VoiceConvertResult {
        convertCalls.append(request)
        if !convertSequence.isEmpty { return try convertSequence.removeFirst().get() }
        return try convertResult.get()
    }

    func setStatus(_ status: VoiceConversionStatus) { statusResult = status }
    func setStart(_ result: Result<VoiceConversionStatus, Error>) { startResult = result }
    func setVoices(_ result: Result<[VoiceDescriptor], Error>) { voicesResult = result }
    func setTrain(_ result: Result<Data, Error>) { trainResult = result }
    func setConvert(_ result: Result<VoiceConvertResult, Error>) { convertResult = result }
    func setConvertSequence(_ results: [Result<VoiceConvertResult, Error>]) {
        convertSequence = results
    }
}

/// MainActor recorder for the two store seams the model holds:
/// `voiceConversionSource` (DATASET samples — a training sample is a file to
/// copy, so it wants the backing recording) and `convertClipsToVoice` (the
/// m24-m leg A action, which does its own per-clip extraction) — the
/// `SubmitRecorder`/`ImportRecorder` precedent.
@MainActor final class VoiceStoreRecorder {
    var sourceResult: Result<(url: URL, startBeat: Double), Error> =
        .success((url: URL(fileURLWithPath: "/tmp/source.wav"), startBeat: 0))
    /// The leg-A store seam's answer. `.failure` is how a test plays a store
    /// REFUSAL (empty set, MIDI clip, overlapping pair) — the same
    /// `ProjectError` the wire returns.
    var convertClipsResult: Result<ClipVoiceConversionResult, Error>?
    /// A per-clip fixture the stubbed `convertClipsToVoice` feeds to the
    /// injected converter, so a test can watch the model's progress advance.
    var convertClipsSources: [ClipConversionSource] = []

    private(set) var sourceCalls: [UUID] = []
    /// m24-n: `provenance` is recorded too, so a test can pin that the UI route
    /// composes and forwards it. A route that omitted it would convert
    /// perfectly and record nothing.
    private(set) var convertClipsCalls:
        [(clipIDs: [UUID], trackName: String, provenance: VoiceProvenance?)] = []
    /// Progress snapshots taken around the converter closure, one pair per clip
    /// — the only place a test can see the live state the panel renders.
    /// BEFORE the call the model has not yet entered that clip (so it still
    /// reads the PREVIOUS clip's `.preparing` state); AFTER it, the clip is
    /// finished. Both faces are load-bearing and neither can be derived from
    /// the other.
    private(set) var progressDuringConvert: [VoiceClipsConvertProgress] = []
    private(set) var progressAfterConvert: [VoiceClipsConvertProgress] = []

    static func stubConversionSource(url: URL, startBeat: Double,
                                     clipID: UUID = UUID(),
                                     name: String = "take") -> ClipConversionSource {
        ClipConversionSource(
            clipId: clipID, trackId: UUID(), url: url,
            startBeat: startBeat, lengthBeats: 4, seconds: 2,
            gainDb: 0, fadeInBeats: 0, fadeOutBeats: 0,
            fadeInCurve: .linear, fadeOutCurve: .linear,
            gainEnvelope: [], name: name)
    }

    func source(_ clipID: UUID) throws -> (url: URL, startBeat: Double) {
        sourceCalls.append(clipID)
        return try sourceResult.get()
    }

    /// Stands in for `ProjectStore.convertClipsToVoice`: calls the injected
    /// converter once per fixture source (leg A's own per-clip order), snapshots
    /// the model's progress at each call, and returns the seeded result.
    func convertClips(
        _ clipIDs: [UUID], _ trackName: String, _ provenance: VoiceProvenance?,
        _ convert: ClipVoiceConverting,
        observing model: @autoclosure () -> VoicePanelModel?
    ) async throws -> ClipVoiceConversionResult {
        convertClipsCalls.append(
            (clipIDs: clipIDs, trackName: trackName, provenance: provenance))
        guard let seeded = convertClipsResult else {
            throw ProjectError.invalidClipEdit("no convertClipsResult seeded")
        }
        switch seeded {
        case .failure(let error):
            throw error
        case .success(let result):
            let sources = convertClipsSources.isEmpty
                ? clipIDs.map { VoiceStoreRecorder.stubConversionSource(
                    url: URL(fileURLWithPath: "/tmp/extracted.wav"), startBeat: 0, clipID: $0) }
                : convertClipsSources
            for source in sources {
                if let progress = model()?.clipsConvertProgress {
                    progressDuringConvert.append(progress)
                }
                _ = try await convert(source.clipId, source)
                if let progress = model()?.clipsConvertProgress {
                    progressAfterConvert.append(progress)
                }
            }
            return result
        }
    }
}

@MainActor
@Suite("Voice panel model (m10-p-5)")
struct VoicePanelModelTests {
    // MARK: - Harness

    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-panel-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeModel(
        root: URL, fakes: VoiceFakes = VoiceFakes(), store: VoiceStoreRecorder = VoiceStoreRecorder()
    ) -> VoicePanelModel {
        let box = ModelBox()
        let model = VoicePanelModel(
            datasetsRoot: root,
            sidecarStatus: { await fakes.status() },
            startSidecar: { try await fakes.start() },
            voices: { try await fakes.voices() },
            train: { try await fakes.train($0) },
            convert: { try await fakes.convert($0) },
            clipSource: { try store.source($0) },
            // `box` is captured STRONGLY on purpose: it is a local, so a weak
            // capture dies the moment `makeModel` returns (measured — every
            // progress snapshot came back empty). No cycle: model → closure →
            // box → WEAK model.
            convertClips: { ids, name, provenance, convert in
                try await store.convertClips(
                    ids, name, provenance, convert, observing: box.model)
            })
        box.model = model
        return model
    }

    /// Lets the stubbed store seam observe the very model it is driving — the
    /// only way to snapshot the live progress the panel renders, since the model
    /// does not exist yet when its own dependencies are built.
    @MainActor private final class ModelBox { weak var model: VoicePanelModel? }

    /// A tiny real file (contents irrelevant — the model checks existence/
    /// extension, never decodes audio).
    private func writeSample(_ name: String, in dir: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let container = dir.appendingPathComponent("voice-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let url = container.appendingPathComponent(name)
        try Data("fake audio".utf8).write(to: url)
        return url
    }

    // MARK: - Policy copy (standing constraint — verbatim pins)

    @Test("the rights-responsibility policy line carries the REQUIRED verbatim fragment")
    func policyLineVerbatim() {
        // This fragment is REQUIRED by the m10-p-5 brief and SURVIVED the
        // m23-n2d policy change unchanged — the user withdrew the
        // own-voice-only prohibition, not the rights requirement.
        #expect(VoicePanelModel.policyLine.contains("a voice you have the rights to use"))
        // m23-n2d re-point: these two used to pin "Never a celebrity voice"
        // and "anyone else's voice". The user WITHDREW that policy, so the
        // prohibition had to go — but the copy stays guarded rather than
        // unpinned. Literals, never `VoicePanelModel.policyDetail` compared
        // against itself (a pin that reads its own source is tautological).
        #expect(VoicePanelModel.policyDetail.contains("You are responsible for the rights"))
        #expect(VoicePanelModel.policyDetail.contains("including third-party voices"))
    }

    @Test("the withdrawn own-voice-only prohibition is GONE from the rendered copy")
    func withdrawnProhibitionIsAbsent() {
        // The failure this guards is re-propagation: the prohibition lived at
        // seven-plus sites and memory twice under-counted them, so a future
        // edit restoring "never a celebrity voice" anywhere in the panel copy
        // must go red rather than quietly contradict the user's decision.
        let rendered = VoicePanelModel.policyLine + " " + VoicePanelModel.policyDetail
        #expect(!rendered.lowercased().contains("celebrity"))
        #expect(!rendered.lowercased().contains("only with your own voice"))
    }

    @Test("the record-path hint teaches the track-record route (mic capture is deferred, said out loud)")
    func recordHintTeachesTrackRoute() {
        #expect(VoicePanelModel.recordHint.contains("record on a track"))
        #expect(VoicePanelModel.recordHint.contains("add it here as a sample"))
    }

    // MARK: - Sidecar banner (user copy, never wire-speak)

    @Test("no status yet → a neutral checking banner")
    func bannerBeforeFirstProbe() throws {
        let model = makeModel(root: try makeTempRoot())
        let banner = try #require(model.banner)
        #expect(banner.tone == .neutral)
        #expect(banner.canStart == false)
        #expect(banner.message == "Checking the voice engine…")
    }

    @Test("healthy → no banner (the panel is ready)")
    func bannerHealthy() throws {
        let model = makeModel(root: try makeTempRoot())
        model.updateSidecar(VoiceConversionStatus(state: .healthy, message: "healthy"))
        #expect(model.banner == nil)
    }

    @Test("installedNotRunning → the exact user line + a Start button; NEVER wire-speak")
    func bannerInstalledNotRunning() throws {
        let model = makeModel(root: try makeTempRoot())
        // The manager's own message is agent-register ("call vc.sidecarStart") —
        // the banner must translate, not parrot (the m10-q law).
        model.updateSidecar(VoiceConversionStatus(
            state: .installedNotRunning,
            message: "RVC voice-conversion sidecar is installed but not running — call vc.sidecarStart."))
        let banner = try #require(model.banner)
        #expect(banner.message == "The voice engine isn't running — press Start.")
        #expect(banner.canStart == true)
        #expect(banner.tone == .warning)
        #expect(!banner.message.contains("vc.sidecarStart"))
    }

    @Test("starting → truthful progress tone with elapsed seconds, never a Start button")
    func bannerStarting() throws {
        let model = makeModel(root: try makeTempRoot())
        model.updateSidecar(VoiceConversionStatus(
            state: .starting, message: "starting", startingForSeconds: 12))
        let banner = try #require(model.banner)
        #expect(banner.message == "Starting the voice engine… (12s)")
        #expect(banner.tone == .progress)
        #expect(banner.canStart == false)

        // Elapsed unknown (a dry-run/fresh status) → the plain sentence, no
        // invented number.
        model.updateSidecar(VoiceConversionStatus(state: .starting, message: "starting"))
        #expect(model.banner?.message == "Starting the voice engine…")
    }

    @Test("notInstalled → names the install script; error → the manager's message verbatim")
    func bannerNotInstalledAndError() throws {
        let model = makeModel(root: try makeTempRoot())
        model.updateSidecar(VoiceConversionStatus(state: .notInstalled, message: "wire message"))
        #expect(model.banner?.message.contains("scripts/rvc/install.sh") == true)
        #expect(model.banner?.canStart == false)

        let errorMessage = "RVC voice-conversion sidecar responded, but its /health response could not be parsed."
        model.updateSidecar(VoiceConversionStatus(state: .error, message: errorMessage))
        #expect(model.banner?.message == errorMessage)
        #expect(model.banner?.tone == .error)
    }

    @Test("startSidecar lands the manager's result and refreshes voices once healthy")
    func startSidecarRefreshesVoices() async throws {
        let fakes = VoiceFakes()
        await fakes.setVoices(.success([VoiceDescriptor(
            id: "base", name: "Base", state: "ready", kind: "builtin", trained: false)]))
        let model = makeModel(root: try makeTempRoot(), fakes: fakes)
        await model.startSidecar()
        #expect(model.sidecarStatus?.state == .healthy)
        #expect(model.voices.count == 1)
        let startCalls = await fakes.startCalls
        #expect(startCalls == 1)
    }

    // MARK: - Facade voice list

    @Test("refreshVoices lands descriptors verbatim; the smoke-target test spots base")
    func refreshVoices() async throws {
        let fakes = VoiceFakes()
        let base = VoiceDescriptor(id: "base", name: "Base (untrained)", state: "ready",
                                   kind: "builtin", trained: false, note: "smoke target")
        let real = VoiceDescriptor(id: "me", name: "My Voice", state: "ready", hasIndex: true)
        await fakes.setVoices(.success([base, real]))
        let model = makeModel(root: try makeTempRoot(), fakes: fakes)

        await model.refreshVoices()
        #expect(model.voices == [base, real])
        #expect(model.voicesError == nil)
        #expect(model.hasLoadedVoices)
        #expect(VoicePanelModel.isSmokeTarget(base))
        #expect(!VoicePanelModel.isSmokeTarget(real))
    }

    @Test("an unreachable sidecar surfaces the press-Start user copy, not wire-speak")
    func refreshVoicesUnreachable() async throws {
        let fakes = VoiceFakes()
        await fakes.setVoices(.failure(VoiceConversionError.sidecarUnreachable("connection refused")))
        let model = makeModel(root: try makeTempRoot(), fakes: fakes)

        await model.refreshVoices()
        let error = try #require(model.voicesError)
        #expect(error.contains("press Start"))
        #expect(!error.contains("vc.sidecarStart"))
    }

    // MARK: - Dataset CRUD

    @Test("createVoice makes the directory (root created lazily) and lists it")
    func createVoice() throws {
        let root = try makeTempRoot().appendingPathComponent("nested-not-yet-created")
        let model = makeModel(root: root)
        #expect(model.localVoices.isEmpty)

        #expect(model.createVoice(named: "  My Voice  "))
        #expect(model.datasetError == nil)
        #expect(model.localVoices.map(\.name) == ["My Voice"])   // trimmed
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("My Voice").path, isDirectory: &isDir))
        #expect(isDir.boolValue)
    }

    @Test("createVoice collision (case-insensitive) is refused with user copy")
    func createVoiceCollision() throws {
        let model = makeModel(root: try makeTempRoot())
        #expect(model.createVoice(named: "My Voice"))
        #expect(!model.createVoice(named: "my voice"))
        #expect(model.datasetError?.contains("already exists") == true)
        #expect(model.localVoices.count == 1)
    }

    @Test("createVoice rejects blank, path-separator, and the reserved base names")
    func createVoiceValidation() throws {
        let model = makeModel(root: try makeTempRoot())
        #expect(!model.createVoice(named: "   "))
        #expect(model.datasetError == "Give the voice a name first.")
        #expect(!model.createVoice(named: "a/b"))
        #expect(model.datasetError?.contains("can't contain") == true)
        #expect(!model.createVoice(named: "Base"))
        #expect(model.datasetError?.contains("reserved") == true)
        #expect(model.localVoices.isEmpty)
    }

    @Test("deleteVoice removes the dataset directory only")
    func deleteVoice() throws {
        let root = try makeTempRoot()
        let model = makeModel(root: root)
        #expect(model.createVoice(named: "Gone"))
        #expect(model.deleteVoice(named: "Gone"))
        #expect(model.localVoices.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Gone").path))
    }

    // MARK: - Sample import (copy-never-move law)

    @Test("importSamples COPIES the file — the source survives (the importBank law)")
    func importCopiesNeverMoves() throws {
        let model = makeModel(root: try makeTempRoot())
        #expect(model.createVoice(named: "V"))
        let source = try writeSample("take.wav")

        #expect(model.importSamples([source], intoVoice: "V") == 1)
        #expect(model.datasetError == nil)
        // Source untouched.
        #expect(FileManager.default.fileExists(atPath: source.path))
        // Copy landed under the voice's dataset.
        let voice = try #require(model.localVoices.first)
        #expect(voice.samples.map(\.name) == ["take.wav"])
    }

    @Test("name collision uniquifies (take-2.wav) — both samples survive, nothing overwritten")
    func importCollisionUniquifies() throws {
        let model = makeModel(root: try makeTempRoot())
        #expect(model.createVoice(named: "V"))
        let first = try writeSample("take.wav")
        let second = try writeSample("take.wav")

        #expect(model.importSamples([first], intoVoice: "V") == 1)
        #expect(model.importSamples([second], intoVoice: "V") == 1)
        let voice = try #require(model.localVoices.first)
        #expect(voice.samples.map(\.name) == ["take-2.wav", "take.wav"])
    }

    @Test("a non-audio file is refused with user copy; a missing file and an unknown voice too")
    func importValidation() throws {
        let model = makeModel(root: try makeTempRoot())
        #expect(model.createVoice(named: "V"))

        let text = try writeSample("lyrics.txt")
        #expect(model.importSamples([text], intoVoice: "V") == 0)
        #expect(model.datasetError?.contains("isn't an audio file") == true)

        let ghost = URL(fileURLWithPath: "/nonexistent/take.wav")
        #expect(model.importSamples([ghost], intoVoice: "V") == 0)
        #expect(model.datasetError?.contains("No audio file") == true)

        let real = try writeSample("take.wav")
        #expect(model.importSamples([real], intoVoice: "Nope") == 0)
        #expect(model.datasetError?.contains("create it first") == true)
    }

    @Test("removeSample deletes exactly that file")
    func removeSample() throws {
        let model = makeModel(root: try makeTempRoot())
        #expect(model.createVoice(named: "V"))
        _ = model.importSamples([try writeSample("a.wav"), try writeSample("b.wav")], intoVoice: "V")
        #expect(model.removeSample(named: "a.wav", fromVoice: "V"))
        #expect(model.localVoices.first?.samples.map(\.name) == ["b.wav"])
    }

    // MARK: - Add selected clip as sample

    @Test("addClipAsSample resolves through the store seam and imports a COPY of the backing file")
    func addClipAsSample() throws {
        let store = VoiceStoreRecorder()
        let backing = try writeSample("clip-take.wav")
        store.sourceResult = .success((url: backing, startBeat: 4))
        let model = makeModel(root: try makeTempRoot(), store: store)
        #expect(model.createVoice(named: "V"))

        let clipID = UUID()
        #expect(model.addClipAsSample(clipID: clipID, intoVoice: "V"))
        #expect(store.sourceCalls == [clipID])
        #expect(FileManager.default.fileExists(atPath: backing.path))   // copy, not move
        #expect(model.localVoices.first?.samples.map(\.name) == ["clip-take.wav"])
    }

    @Test("a MIDI clip is rejected with the store's teaching error VERBATIM (one vocabulary)")
    func addClipAsSampleRejectsMIDI() throws {
        let store = VoiceStoreRecorder()
        let clipID = UUID()
        let storeError = ProjectError.voiceConversionRequiresAudioClip(clipID)
        store.sourceResult = .failure(storeError)
        let model = makeModel(root: try makeTempRoot(), store: store)
        #expect(model.createVoice(named: "V"))

        #expect(!model.addClipAsSample(clipID: clipID, intoVoice: "V"))
        #expect(model.datasetError == storeError.errorDescription)
        #expect(model.localVoices.first?.samples.isEmpty == true)
    }

    // MARK: - Train (honest 501, no fake progress, local validation first)

    @Test("an empty dataset fails locally with user copy — the client is NEVER called")
    func trainValidatesLocally() async throws {
        let fakes = VoiceFakes()
        let model = makeModel(root: try makeTempRoot(), fakes: fakes)
        #expect(model.createVoice(named: "V"))

        await model.train(voiceNamed: "V")
        guard case .failed(let message) = model.trainState(forVoice: "V") else {
            Issue.record("expected .failed, got \(model.trainState(forVoice: "V"))")
            return
        }
        #expect(message.contains("Add at least one recording"))
        let trainCalls = await fakes.trainCalls
        #expect(trainCalls.isEmpty, "an empty dataset must never reach the client")
    }

    @Test("the facade's 501 lands the designed comingSoon state with the teaching message verbatim")
    func trainComingSoon() async throws {
        let fakes = VoiceFakes()   // default train result IS the 501
        let model = makeModel(root: try makeTempRoot(), fakes: fakes)
        #expect(model.createVoice(named: "V"))
        _ = model.importSamples([try writeSample("take.wav")], intoVoice: "V")

        await model.train(voiceNamed: "V")
        guard case .comingSoon(let message) = model.trainState(forVoice: "V") else {
            Issue.record("expected .comingSoon, got \(model.trainState(forVoice: "V"))")
            return
        }
        #expect(message == "contract reserved — training ships with the Voice panel (m10-p-5/p-6)")
        // The request named this voice and ITS dataset dir.
        let calls = await fakes.trainCalls
        #expect(calls.count == 1)
        #expect(calls.first?.name == "V")
        #expect(calls.first?.datasetDir.hasSuffix("/V") == true)
        // The headline the view renders above the verbatim message.
        #expect(VoicePanelModel.trainingComingSoonHeadline == "Real training arrives with a coming update.")
    }

    @Test("an unexpected 2xx today reads as honest INDETERMINATE progress — never a fake number")
    func trainUnexpectedSuccessIsIndeterminate() async throws {
        let fakes = VoiceFakes()
        await fakes.setTrain(.success(Data("{}".utf8)))
        let model = makeModel(root: try makeTempRoot(), fakes: fakes)
        #expect(model.createVoice(named: "V"))
        _ = model.importSamples([try writeSample("take.wav")], intoVoice: "V")

        await model.train(voiceNamed: "V")
        guard case .progress(let fraction, let detail) = model.trainState(forVoice: "V") else {
            Issue.record("expected .progress, got \(model.trainState(forVoice: "V"))")
            return
        }
        #expect(fraction == nil, "nothing today may invent a progress fraction (p-6 feeds it)")
        #expect(detail == nil)
    }

    @Test("unreachable sidecar → user copy naming Start; a dismiss clears the card")
    func trainUnreachableAndDismiss() async throws {
        let fakes = VoiceFakes()
        await fakes.setTrain(.failure(VoiceConversionError.sidecarUnreachable("refused")))
        let model = makeModel(root: try makeTempRoot(), fakes: fakes)
        #expect(model.createVoice(named: "V"))
        _ = model.importSamples([try writeSample("take.wav")], intoVoice: "V")

        await model.train(voiceNamed: "V")
        guard case .failed(let message) = model.trainState(forVoice: "V") else {
            Issue.record("expected .failed, got \(model.trainState(forVoice: "V"))")
            return
        }
        #expect(message.contains("press Start"))
        #expect(!message.contains("vc.sidecarStart"))

        model.dismissTrainState(forVoice: "V")
        #expect(model.trainState(forVoice: "V") == .idle)
    }

    // MARK: - Convert Voice (the selection-driven action, m24-m leg B)

    /// Two clips' worth of fixture: distinct names so the progress detail line
    /// is attributable to a specific clip.
    private func twoSources(_ a: UUID, _ b: UUID) -> [ClipConversionSource] {
        [VoiceStoreRecorder.stubConversionSource(
            url: URL(fileURLWithPath: "/tmp/verse.wav"), startBeat: 0, clipID: a, name: "Verse"),
         VoiceStoreRecorder.stubConversionSource(
            url: URL(fileURLWithPath: "/tmp/chorus.wav"), startBeat: 8, clipID: b, name: "Chorus")]
    }

    private func seededResult(trackName: String, clipCount: Int,
                              warnings: [String] = []) -> ClipVoiceConversionResult {
        ClipVoiceConversionResult(
            trackId: UUID(), trackName: trackName,
            clips: (0..<clipCount).map { index in
                ConvertedClipReport(
                    sourceClipId: UUID(), sourceTrackId: UUID(), clipId: UUID(),
                    startBeat: Double(index * 8), lengthBeats: 8,
                    extractedPath: "/tmp/x.wav", file: "/tmp/y.wav",
                    sourceSeconds: 16, convertedSeconds: 16)
            },
            warnings: warnings)
    }

    @Test("convertClips rides the leg-A store seam: every clip converted once, default track name")
    func convertClipsHappyPath() async throws {
        let fakes = VoiceFakes()
        let store = VoiceStoreRecorder()
        let a = UUID(), b = UUID()
        store.convertClipsSources = twoSources(a, b)
        store.convertClipsResult = .success(seededResult(trackName: "Voice: base", clipCount: 2))
        await fakes.setConvert(.success(VoiceConvertResult(
            outputPath: "/tmp/out.wav", voiceId: "base", inputSeconds: 5, engineLoadSeconds: 0.5,
            inferSeconds: 0.135, rtf: 37.0, sampleRate: 40000, realConversion: false,
            note: "base is the untrained generic target")))
        let model = makeModel(root: try makeTempRoot(), fakes: fakes, store: store)

        let landed = await model.convertClips(clipIDs: [a, b], voiceID: "base", pitchSemitones: 2)
        #expect(landed)
        #expect(model.clipsConvertError == nil)
        #expect(model.isConvertingClips == false, "the busy flag clears on the way out")

        // ONE store call carrying BOTH ids — never two single-clip calls (that
        // would land two tracks, which is the whole thing leg A prevents).
        #expect(store.convertClipsCalls.count == 1)
        #expect(store.convertClipsCalls.first?.clipIDs == [a, b])
        #expect(store.convertClipsCalls.first?.trackName == "Voice: base")   // the wire's rule
        // The extraction is what the converter hears, one call per clip.
        let convertCalls = await fakes.convertCalls
        #expect(convertCalls.count == 2)
        #expect(convertCalls.first == VoiceConvertRequest(
            inputPath: "/tmp/verse.wav", voiceId: "base", pitchSemitones: 2))
        #expect(convertCalls.last?.inputPath == "/tmp/chorus.wav")
        // The backing-recording seam belongs to TRAINING samples and must stay
        // untouched by a conversion (m24-o).
        #expect(store.sourceCalls.isEmpty)

        let outcome = try #require(model.lastClipsConversion)
        #expect(outcome.result.trackName == "Voice: base")
        #expect(outcome.result.clips.count == 2)
        #expect(outcome.realConversion == false)
        #expect(outcome.note == "base is the untrained generic target")
    }

    @Test("progress names WHICH CLIP OF HOW MANY while the run is live — never a bare busy flag")
    func convertClipsProgressIsLegible() async throws {
        let fakes = VoiceFakes()
        let store = VoiceStoreRecorder()
        let a = UUID(), b = UUID()
        store.convertClipsSources = twoSources(a, b)
        store.convertClipsResult = .success(seededResult(trackName: "Voice: mine", clipCount: 2))
        await fakes.setConvert(.success(VoiceConvertResult(
            outputPath: "/tmp/out.wav", voiceId: "mine", inputSeconds: 5, engineLoadSeconds: 0,
            inferSeconds: 0.2, sampleRate: 40000, realConversion: true)))
        let model = makeModel(root: try makeTempRoot(), fakes: fakes, store: store)

        _ = await model.convertClips(clipIDs: [a, b], voiceID: "mine")

        // Snapshots taken INSIDE the converter, one per clip.
        #expect(store.progressDuringConvert.count == 2)
        let first = try #require(store.progressDuringConvert.first)
        #expect(first.total == 2)
        #expect(first.completed == 0)
        #expect(first.stepText == "CLIP 1/2")
        #expect(first.fraction == 0)
        let second = try #require(store.progressDuringConvert.last)
        #expect(second.completed == 1, "clip one FINISHED before clip two started")
        #expect(second.stepText == "CLIP 2/2")
        #expect(second.fraction == 0.5)
        // Between clips the line is honest about WHAT it is doing — rendering
        // the next clip's audio — and names the one just finished rather than
        // claiming to be converting something it has not started.
        #expect(second.phase == .preparing)
        #expect(second.detailText == "Preparing the clip after \u{201C}Verse\u{201D}…")

        // AFTER each converter call: the model really did call
        // `beginConverting` with THAT clip's name, and the count advanced.
        #expect(store.progressAfterConvert.count == 2)
        #expect(store.progressAfterConvert.first?.currentClipName == "Verse")
        #expect(store.progressAfterConvert.first?.completed == 1)
        #expect(store.progressAfterConvert.last?.currentClipName == "Chorus")
        #expect(store.progressAfterConvert.last?.completed == 2)
        #expect(store.progressAfterConvert.last?.phase == .landing)
        // And it clears on the way out: progress belongs to a live run.
        #expect(model.clipsConvertProgress == nil)
    }

    @Test("progress phases are honest: preparing → converting → landing, and the fraction never guesses")
    func progressPhasesAreHonest() {
        var progress = VoiceClipsConvertProgress(
            total: 2, completed: 0, currentClipName: nil,
            phase: .preparing, startedAt: Date(timeIntervalSince1970: 100))
        #expect(progress.detailText == "Preparing the first clip…")
        #expect(progress.fraction == 0)

        progress.beginConverting(clipNamed: "Verse")
        #expect(progress.phase == .converting)
        #expect(progress.detailText.contains("Verse"))
        #expect(progress.fraction == 0, "a clip in flight is NOT completed work")

        progress.finishOne()
        #expect(progress.phase == .preparing)
        #expect(progress.fraction == 0.5)
        #expect(progress.stepText == "CLIP 2/2")

        progress.beginConverting(clipNamed: "Chorus")
        progress.finishOne()
        #expect(progress.phase == .landing, "every clip done → the track is landing")
        #expect(progress.fraction == 1)
        #expect(progress.detailText == "Adding the new track…")
        #expect(progress.stepText == "CLIP 2/2", "never \"clip 3 of 2\"")

        // The elapsed readout is the "still alive" signal — whole seconds,
        // never negative.
        #expect(progress.elapsedSeconds(at: Date(timeIntervalSince1970: 137)) == 37)
        #expect(progress.elapsedSeconds(at: Date(timeIntervalSince1970: 90)) == 0)
    }

    @Test("a custom track name passes through instead of the default")
    func convertClipsCustomTrackName() async throws {
        let fakes = VoiceFakes()
        let store = VoiceStoreRecorder()
        let a = UUID()
        store.convertClipsSources = [VoiceStoreRecorder.stubConversionSource(
            url: URL(fileURLWithPath: "/tmp/a.wav"), startBeat: 0, clipID: a)]
        store.convertClipsResult = .success(seededResult(trackName: "Lead Vox (base)", clipCount: 1))
        await fakes.setConvert(.success(VoiceConvertResult(
            outputPath: "/tmp/out.wav", voiceId: "base", inputSeconds: 1, engineLoadSeconds: 0,
            inferSeconds: 0.1, sampleRate: 40000, realConversion: false)))
        let model = makeModel(root: try makeTempRoot(), fakes: fakes, store: store)

        _ = await model.convertClips(clipIDs: [a], voiceID: "base", trackName: "Lead Vox (base)")
        #expect(store.convertClipsCalls.first?.trackName == "Lead Vox (base)")
    }

    @Test("a store refusal (MIDI clip) surfaces VERBATIM and the converter is NEVER called")
    func convertClipsRefusalVerbatim() async throws {
        let fakes = VoiceFakes()
        let store = VoiceStoreRecorder()
        let clipID = UUID()
        let storeError = ProjectError.voiceConversionRequiresAudioClip(clipID)
        store.convertClipsResult = .failure(storeError)
        let model = makeModel(root: try makeTempRoot(), fakes: fakes, store: store)

        let landed = await model.convertClips(clipIDs: [clipID], voiceID: "base")
        #expect(!landed)
        // The refusal-bubble law: the store's own words, character for
        // character — the same string an agent gets from vc.convertClips.
        #expect(model.clipsConvertError == storeError.errorDescription)
        let convertCalls = await fakes.convertCalls
        #expect(convertCalls.isEmpty, "a refused selection must never reach the voice engine")
        #expect(model.lastClipsConversion == nil)
        #expect(model.clipsConvertProgress == nil, "a refusal leaves no phantom progress")
    }

    @Test("the OVERLAP refusal reaches the panel verbatim, naming both clips")
    func convertClipsOverlapRefusalVerbatim() async throws {
        let fakes = VoiceFakes()
        let store = VoiceStoreRecorder()
        // Leg A's own wording — a pin that fails loudly if the store's teaching
        // message is ever re-phrased on the way to the panel.
        let storeError = ProjectError.invalidClipEdit(
            "\"Verse\" (beats 0.0–8.0) and \"Chorus\" (beats 4.0–12.0) overlap, so one track "
            + "cannot hold both at their own beats")
        store.convertClipsResult = .failure(storeError)
        let model = makeModel(root: try makeTempRoot(), fakes: fakes, store: store)

        _ = await model.convertClips(clipIDs: [UUID(), UUID()], voiceID: "base")
        let message = try #require(model.clipsConvertError)
        #expect(message == storeError.errorDescription)
        #expect(message.contains("Verse") && message.contains("Chorus"))
    }

    @Test("leg A's non-fatal warnings ride the outcome — a warning is not a failure")
    func convertClipsWarningsAreNonFatal() async throws {
        let fakes = VoiceFakes()
        let store = VoiceStoreRecorder()
        let a = UUID()
        store.convertClipsSources = [VoiceStoreRecorder.stubConversionSource(
            url: URL(fileURLWithPath: "/tmp/a.wav"), startBeat: 0, clipID: a)]
        store.convertClipsResult = .success(seededResult(
            trackName: "Voice: mine", clipCount: 1,
            warnings: ["the converted audio for \"take\" is 16.4 s but the clip presents 16 s"]))
        await fakes.setConvert(.success(VoiceConvertResult(
            outputPath: "/tmp/out.wav", voiceId: "mine", inputSeconds: 16, engineLoadSeconds: 0,
            inferSeconds: 0.4, sampleRate: 40000, realConversion: true)))
        let model = makeModel(root: try makeTempRoot(), fakes: fakes, store: store)

        let landed = await model.convertClips(clipIDs: [a], voiceID: "mine")
        #expect(landed, "a warning does not fail the run")
        #expect(model.clipsConvertError == nil, "a warning is NEVER an error strip")
        let outcome = try #require(model.lastClipsConversion)
        #expect(outcome.result.warnings.count == 1)
        #expect(outcome.result.warnings[0].contains("16.4 s"))
        #expect(outcome.realConversion == true)
    }

    @Test("ONE not-real conversion makes the whole set not-real — never a majority vote")
    func convertClipsMixedRealityIsHonest() async throws {
        let fakes = VoiceFakes()
        let store = VoiceStoreRecorder()
        let a = UUID(), b = UUID()
        store.convertClipsSources = twoSources(a, b)
        store.convertClipsResult = .success(seededResult(trackName: "Voice: base", clipCount: 2))
        // First clip converts for real, second falls back to the smoke target.
        await fakes.setConvertSequence([
            .success(VoiceConvertResult(
                outputPath: "/tmp/1.wav", voiceId: "mine", inputSeconds: 4, engineLoadSeconds: 0,
                inferSeconds: 0.2, sampleRate: 40000, realConversion: true)),
            .success(VoiceConvertResult(
                outputPath: "/tmp/2.wav", voiceId: "base", inputSeconds: 4, engineLoadSeconds: 0,
                inferSeconds: 0.3, sampleRate: 40000, realConversion: false,
                note: "base is the untrained generic target")),
        ])
        let model = makeModel(root: try makeTempRoot(), fakes: fakes, store: store)

        _ = await model.convertClips(clipIDs: [a, b], voiceID: "base")
        let outcome = try #require(model.lastClipsConversion)
        #expect(outcome.realConversion == false)
        #expect(outcome.note == "base is the untrained generic target")
        // The engine total is the SUM, never one clip's number wearing the
        // whole set's label.
        #expect(abs(outcome.totalInferSeconds - 0.5) < 1e-9)
    }

    @Test("unreachable sidecar during convert → the press-Start user copy, never wire-speak")
    func convertClipsUnreachable() async throws {
        let fakes = VoiceFakes()
        let store = VoiceStoreRecorder()
        let a = UUID()
        store.convertClipsSources = [VoiceStoreRecorder.stubConversionSource(
            url: URL(fileURLWithPath: "/tmp/a.wav"), startBeat: 0, clipID: a)]
        store.convertClipsResult = .success(seededResult(trackName: "Voice: base", clipCount: 1))
        await fakes.setConvert(.failure(VoiceConversionError.sidecarUnreachable("refused")))
        let model = makeModel(root: try makeTempRoot(), fakes: fakes, store: store)

        _ = await model.convertClips(clipIDs: [a], voiceID: "base")
        #expect(model.clipsConvertError?.contains("press Start") == true)
        #expect(model.clipsConvertError?.contains("vc.sidecarStart") == false)
        #expect(model.clipsConvertProgress == nil)
    }

    @Test("resetClipsConvertState clears the panel's transient state")
    func resetClipsConvertStateClears() async throws {
        let fakes = VoiceFakes()
        let store = VoiceStoreRecorder()
        store.convertClipsResult = .failure(ProjectError.invalidClipEdit("nope"))
        let model = makeModel(root: try makeTempRoot(), fakes: fakes, store: store)
        _ = await model.convertClips(clipIDs: [UUID()], voiceID: "base")
        #expect(model.clipsConvertError != nil)
        model.resetClipsConvertState()
        #expect(model.clipsConvertError == nil)
        #expect(model.lastClipsConversion == nil)
    }

    @Test("the picked voice and pitch live on the MODEL, and a fresh open clears them")
    func convertChoiceLivesOnTheModel() throws {
        let model = makeModel(root: try makeTempRoot())
        #expect(model.selectedConvertVoiceID == nil, "nothing picked disarms the primary")
        #expect(model.convertPitchSemitones == 0)

        model.selectedConvertVoiceID = "dmitry"
        model.convertPitchSemitones = 2

        // The panel's `.task` runs on EVERY appearance and must not wipe a pick.
        model.resetClipsConvertState()
        #expect(model.selectedConvertVoiceID == "dmitry")
        #expect(model.convertPitchSemitones == 2)

        // Opening on a new set of clips does clear it — a fresh run never
        // inherits the last one's parameters.
        model.resetConvertChoice()
        #expect(model.selectedConvertVoiceID == nil)
        #expect(model.convertPitchSemitones == 0)
    }

    @Test("an EMPTY staged refusal clears the strip — never a blank warning")
    func emptyStagedRefusalClears() throws {
        let model = makeModel(root: try makeTempRoot())
        model.setClipsConvertErrorForCapture("something real")
        #expect(model.clipsConvertError == "something real")
        // Measured on staging: an empty string drew a warning triangle with no
        // words — a claim that something went wrong, and a refusal to say what.
        model.setClipsConvertErrorForCapture("")
        #expect(model.clipsConvertError == nil)
    }

    @Test("capture staging plants the converting and result faces without a sidecar")
    func captureStagingPlantsBothFaces() throws {
        let model = makeModel(root: try makeTempRoot())
        model.setClipsConvertProgressForCapture(VoiceClipsConvertProgress(
            total: 5, completed: 1, currentClipName: "Verse 2",
            phase: .converting, startedAt: Date()))
        #expect(model.isConvertingClips)
        #expect(model.clipsConvertProgress?.stepText == "CLIP 2/5")

        model.setClipsConvertProgressForCapture(nil)
        #expect(!model.isConvertingClips)

        model.setClipsConversionForCapture(VoiceClipsConvertOutcome(
            voiceID: "base",
            result: seededResult(trackName: "Voice: base", clipCount: 3,
                                 warnings: ["one thing worth knowing"]),
            realConversion: false, note: "not a real voice", totalInferSeconds: 2.1))
        #expect(model.lastClipsConversion?.result.warnings.count == 1)

        model.setClipsConvertErrorForCapture("a refusal, staged")
        #expect(model.clipsConvertError == "a refusal, staged")
    }

    // MARK: - Small pure helpers

    @Test("uniqueName mirrors ProjectBundle's law")
    func uniqueNamePins() {
        #expect(VoicePanelModel.uniqueName(for: "a.wav", taken: []) == "a.wav")
        #expect(VoicePanelModel.uniqueName(for: "a.wav", taken: ["a.wav"]) == "a-2.wav")
        #expect(VoicePanelModel.uniqueName(for: "a.wav", taken: ["a.wav", "a-2.wav"]) == "a-3.wav")
        #expect(VoicePanelModel.uniqueName(for: "noext", taken: ["noext"]) == "noext-2")
    }

    @Test("the wire's default track-name rule is shared verbatim")
    func defaultTrackNameRule() {
        #expect(VoicePanelModel.defaultTrackName(voiceID: "base") == "Voice: base")
    }
}
