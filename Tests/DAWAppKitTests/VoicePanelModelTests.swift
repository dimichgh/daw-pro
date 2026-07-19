import Foundation
import Testing
import DAWCore
import AIServices
@testable import DAWAppKit

/// Headless coverage for the Voice panel model (m10-p-5): dataset CRUD with
/// the copy-never-move import law, the add-clip-as-sample resolution (+ MIDI
/// rejection verbatim), the sidecar-state → USER-copy banner mapping (never
/// wire-speak — the m10-q law), the honest train-501 state, and the
/// convert-clip action's counting-fake proofs that it rides the SAME
/// client/store seams as the wire's `vc.convertVocals` clipId-form. All
/// against injected fakes — no sidecar, no UI, no real app-support dir.

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

    func status() async -> VoiceConversionStatus { statusCalls += 1; return statusResult }
    func start() async throws -> VoiceConversionStatus { startCalls += 1; return try startResult.get() }
    func voices() async throws -> [VoiceDescriptor] { voicesCalls += 1; return try voicesResult.get() }
    func train(_ request: VoiceTrainRequest) async throws -> Data {
        trainCalls.append(request)
        return try trainResult.get()
    }
    func convert(_ request: VoiceConvertRequest) async throws -> VoiceConvertResult {
        convertCalls.append(request)
        return try convertResult.get()
    }

    func setStatus(_ status: VoiceConversionStatus) { statusResult = status }
    func setStart(_ result: Result<VoiceConversionStatus, Error>) { startResult = result }
    func setVoices(_ result: Result<[VoiceDescriptor], Error>) { voicesResult = result }
    func setTrain(_ result: Result<Data, Error>) { trainResult = result }
    func setConvert(_ result: Result<VoiceConvertResult, Error>) { convertResult = result }
}

/// MainActor recorder for the two store seams (`voiceConversionSource` /
/// `importConvertedVoice`) — the `SubmitRecorder`/`ImportRecorder` precedent.
@MainActor final class VoiceStoreRecorder {
    var sourceResult: Result<(url: URL, startBeat: Double), Error> =
        .success((url: URL(fileURLWithPath: "/tmp/source.wav"), startBeat: 0))
    var importError: Error?

    private(set) var sourceCalls: [UUID] = []
    private(set) var importCalls: [(url: URL, trackName: String, atBeat: Double)] = []

    func source(_ clipID: UUID) throws -> (url: URL, startBeat: Double) {
        sourceCalls.append(clipID)
        return try sourceResult.get()
    }

    func importConverted(_ url: URL, _ name: String, _ beat: Double) throws -> (trackID: UUID, clipID: UUID) {
        if let importError { throw importError }
        importCalls.append((url: url, trackName: name, atBeat: beat))
        return (trackID: UUID(), clipID: UUID())
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
        VoicePanelModel(
            datasetsRoot: root,
            sidecarStatus: { await fakes.status() },
            startSidecar: { try await fakes.start() },
            voices: { try await fakes.voices() },
            train: { try await fakes.train($0) },
            convert: { try await fakes.convert($0) },
            clipSource: { try store.source($0) },
            importConverted: { try store.importConverted($0, $1, $2) })
    }

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

    @Test("the own-voice-only policy line carries the REQUIRED verbatim fragment")
    func policyLineVerbatim() {
        #expect(VoicePanelModel.policyLine.contains("a voice you have the rights to use"))
        #expect(VoicePanelModel.policyDetail.contains("Never a celebrity voice"))
        #expect(VoicePanelModel.policyDetail.contains("anyone else's voice"))
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

    // MARK: - Convert to voice (the clip action — same seams as the wire)

    @Test("convertClip rides the SAME seams: source → convert → import at the clip's own beat, default name")
    func convertHappyPath() async throws {
        let fakes = VoiceFakes()
        let store = VoiceStoreRecorder()
        let backing = try writeSample("vocal.wav")
        store.sourceResult = .success((url: backing, startBeat: 8))
        let converted = try writeSample("out.wav")
        await fakes.setConvert(.success(VoiceConvertResult(
            outputPath: converted.path, voiceId: "base", inputSeconds: 5, engineLoadSeconds: 0.5,
            inferSeconds: 0.135, rtf: 37.0, sampleRate: 40000, realConversion: false,
            note: "base is the untrained generic target")))
        let model = makeModel(root: try makeTempRoot(), fakes: fakes, store: store)

        let clipID = UUID()
        let landed = await model.convertClip(clipID: clipID, voiceID: "base", pitchSemitones: 2)
        #expect(landed)
        #expect(model.convertError == nil)
        #expect(model.isConverting == false)

        // Counting-fake proofs: exactly one convert, exactly one import — the
        // same two calls the wire's vc.convertVocals clipId-form makes.
        let convertCalls = await fakes.convertCalls
        #expect(convertCalls.count == 1)
        #expect(convertCalls.first == VoiceConvertRequest(
            inputPath: backing.path, voiceId: "base", pitchSemitones: 2))
        #expect(store.sourceCalls == [clipID])
        #expect(store.importCalls.count == 1)
        #expect(store.importCalls.first?.url.path == converted.path)
        #expect(store.importCalls.first?.trackName == "Voice: base")   // the wire's default rule
        #expect(store.importCalls.first?.atBeat == 8)                  // the clip's own beat

        // The honest outcome for "base": realConversion false + note, kept
        // for the sheet's result state.
        let outcome = try #require(model.lastConversion)
        #expect(outcome.realConversion == false)
        #expect(outcome.note == "base is the untrained generic target")
        #expect(outcome.trackName == "Voice: base")
    }

    @Test("a custom track name passes through instead of the default")
    func convertCustomTrackName() async throws {
        let fakes = VoiceFakes()
        let store = VoiceStoreRecorder()
        let converted = try writeSample("out.wav")
        await fakes.setConvert(.success(VoiceConvertResult(
            outputPath: converted.path, voiceId: "base", inputSeconds: 1, engineLoadSeconds: 0,
            inferSeconds: 0.1, sampleRate: 40000, realConversion: false)))
        let model = makeModel(root: try makeTempRoot(), fakes: fakes, store: store)

        _ = await model.convertClip(clipID: UUID(), voiceID: "base", trackName: "Lead Vox (base)")
        #expect(store.importCalls.first?.trackName == "Lead Vox (base)")
    }

    @Test("a MIDI clip short-circuits: store error verbatim, converter and importer NEVER called")
    func convertRejectsMIDI() async throws {
        let fakes = VoiceFakes()
        let store = VoiceStoreRecorder()
        let clipID = UUID()
        let storeError = ProjectError.voiceConversionRequiresAudioClip(clipID)
        store.sourceResult = .failure(storeError)
        let model = makeModel(root: try makeTempRoot(), fakes: fakes, store: store)

        let landed = await model.convertClip(clipID: clipID, voiceID: "base")
        #expect(!landed)
        #expect(model.convertError == storeError.errorDescription)
        let convertCalls = await fakes.convertCalls
        #expect(convertCalls.isEmpty, "a MIDI clip must never reach the converter")
        #expect(store.importCalls.isEmpty)
    }

    @Test("a facade teaching error surfaces verbatim and nothing is imported")
    func convertFacadeError() async throws {
        let fakes = VoiceFakes()
        let store = VoiceStoreRecorder()
        await fakes.setConvert(.failure(VoiceConversionError.requestFailed(
            status: 404, code: "unknownVoice", message: "no voice with id 'nope'")))
        let model = makeModel(root: try makeTempRoot(), fakes: fakes, store: store)

        let landed = await model.convertClip(clipID: UUID(), voiceID: "nope")
        #expect(!landed)
        #expect(model.convertError?.contains("unknownVoice") == true)
        #expect(model.convertError?.contains("no voice with id 'nope'") == true)
        #expect(store.importCalls.isEmpty)
        #expect(model.isConverting == false, "the busy flag resets on failure")
        #expect(model.lastConversion == nil)
    }

    @Test("unreachable sidecar during convert → the press-Start user copy")
    func convertUnreachable() async throws {
        let fakes = VoiceFakes()
        await fakes.setConvert(.failure(VoiceConversionError.sidecarUnreachable("refused")))
        let model = makeModel(root: try makeTempRoot(), fakes: fakes)

        _ = await model.convertClip(clipID: UUID(), voiceID: "base")
        #expect(model.convertError?.contains("press Start") == true)
        #expect(model.convertError?.contains("vc.sidecarStart") == false)
    }

    @Test("resetConvertState clears the sheet's transient state")
    func resetConvertState() async throws {
        let fakes = VoiceFakes()
        await fakes.setConvert(.failure(VoiceConversionError.sidecarUnreachable("refused")))
        let model = makeModel(root: try makeTempRoot(), fakes: fakes)
        _ = await model.convertClip(clipID: UUID(), voiceID: "base")
        #expect(model.convertError != nil)
        model.resetConvertState()
        #expect(model.convertError == nil)
        #expect(model.lastConversion == nil)
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
