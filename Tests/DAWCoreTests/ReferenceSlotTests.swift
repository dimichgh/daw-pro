import Foundation
import Testing
@testable import DAWCore

// m22-g P1 (design-m22g-reference-tracks §3-§5): the reference slot's domain
// truth — wire/disk Codable shapes (T1), the exact level-match law (T2), the
// whole-file stereo aggregates (T3), and the store verbs
// import/replace/remove/analyze/undo plus save/open persistence.

// MARK: - Fixtures

private func sampleAnalysis(
    integrated: Double? = -9.5, truePeak: Double? = -0.6
) -> ReferenceAnalysis {
    ReferenceAnalysis(
        integratedLufs: integrated,
        maxMomentaryLufs: -7.2,
        maxShortTermLufs: -8.1,
        truePeakDbtp: truePeak,
        loudnessRangeLu: 5.5,
        bandsDb: (0..<MasterAnalysisSnapshot.bandCount).map { Double($0) - 40 },
        correlation: 0.82,
        width: 0.4,
        balance: -0.05,
        durationSeconds: 212.5,
        sampleRateHz: 48_000,
        analyzerVersion: 1)
}

private func sine(frequency: Double, amplitude: Double, count: Int,
                  sampleRate: Double) -> [Float] {
    (0..<count).map {
        Float(amplitude * sin(2.0 * .pi * frequency * Double($0) / sampleRate))
    }
}

/// A minimal engine whose ONLY capability is reference analysis — every
/// other member is inert (the BareEngine idiom). `result` nil ⇒ the call
/// throws (exercises the land-without-analysis path).
@MainActor
private final class FakeReferenceEngine: AudioEngineControlling {
    var result: ReferenceAnalysis?
    private(set) var analyzedURLs: [URL] = []

    func analyzeReferenceFile(at url: URL) async throws -> ReferenceAnalysis {
        analyzedURLs.append(url)
        guard let result else { throw ProjectError.engineUnavailable }
        return result
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

private func makeTempDir(_ label: String) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ref-tests-\(label)-\(UUID().uuidString.prefix(8))",
                                isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Writes a small throwaway "audio" file (bytes only — FakeMedia never
/// reads it; the store only checks existence and copies).
private func makeSourceFile(in dir: URL, name: String = "My Reference.wav") throws -> URL {
    let url = dir.appendingPathComponent(name)
    try Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x01]).write(to: url)
    return url
}

// MARK: - T1: Codable shapes

@Suite("Reference slot — Codable shapes (m22-g T1)")
struct ReferenceCodableTests {

    @Test("slot wire shape: sourcePath rides as 'path'; analysis omitted when nil; round-trip")
    func slotWireShape() throws {
        let slot = ReferenceSlot(name: "Ref", sourcePath: "/tmp/ref.wav",
                                 offsetSeconds: 1.25, trimDb: -3)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(slot), as: UTF8.self)
        #expect(json.contains("\"path\":\"\\/tmp\\/ref.wav\""))
        #expect(!json.contains("sourcePath"))
        #expect(!json.contains("analysis"))
        let decoded = try JSONDecoder().decode(ReferenceSlot.self,
                                               from: Data(json.utf8))
        #expect(decoded == slot)

        // Populated analysis round-trips too, and trim re-clamps on decode.
        let full = ReferenceSlot(name: "Ref", sourcePath: "/tmp/ref.wav",
                                 analysis: sampleAnalysis())
        let fullDecoded = try JSONDecoder().decode(ReferenceSlot.self,
                                                   from: JSONEncoder().encode(full))
        #expect(fullDecoded == full)
        #expect(ReferenceSlot(name: "x", sourcePath: "p", trimDb: 99).trimDb == 24)
    }

    @Test("analysis wire shape: nil loudness fields are OMITTED (nil = gated-silent, never 0)")
    func analysisNilOmission() throws {
        let silent = sampleAnalysis(integrated: nil, truePeak: nil)
        let json = String(decoding: try JSONEncoder().encode(silent), as: UTF8.self)
        #expect(!json.contains("integratedLufs"))
        #expect(!json.contains("truePeakDbtp"))
        #expect(json.contains("bandsDb"))
        #expect(json.contains("analyzerVersion"))
    }

    @Test("pre-m22-g document re-encodes BYTE-IDENTICAL (omit-when-nil, no reference key)")
    func legacyDocumentByteIdentical() throws {
        var track = Track(name: "Vox", kind: .audio)
        track.clips = [Clip(name: "Take", startBeat: 0, lengthBeats: 4)]
        let document = ProjectDocument(
            name: "Legacy", transport: TransportState(), tracks: [track],
            masterVolume: 0.9, mediaRefs: [:])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let first = try encoder.encode(document)
        #expect(!String(decoding: first, as: UTF8.self).contains("\"reference\""))
        let reencoded = try encoder.encode(
            try decoder.decode(ProjectDocument.self, from: first))
        #expect(first == reencoded)
    }

    @Test("tolerant decode: a corrupt reference value drops to nil + flag, open never fails")
    func tolerantDecodeCorruptReference() throws {
        // Wrong TYPE entirely.
        let wrongType = """
        {"schemaVersion": 1, "name": "X", "reference": 42}
        """
        let d1 = try JSONDecoder().decode(ProjectDocument.self, from: Data(wrongType.utf8))
        #expect(d1.reference == nil)
        #expect(d1.referenceDroppedOnLoad)

        // Right type, missing required id.
        let missingID = """
        {"schemaVersion": 1, "name": "X", "reference": {"name": "Ref", "media": "media/r.wav"}}
        """
        let d2 = try JSONDecoder().decode(ProjectDocument.self, from: Data(missingID.utf8))
        #expect(d2.reference == nil)
        #expect(d2.referenceDroppedOnLoad)

        // Absent key: nil, NOT flagged (a legacy project is not a warning).
        let absent = """
        {"schemaVersion": 1, "name": "X"}
        """
        let d3 = try JSONDecoder().decode(ProjectDocument.self, from: Data(absent.utf8))
        #expect(d3.reference == nil)
        #expect(!d3.referenceDroppedOnLoad)
    }

    @Test("runtimeState resolves media/ refs, keeps missing-FILE slots, sanitizes wrong-count bands")
    func runtimeStateResolution() throws {
        let id = UUID()
        let json = """
        {"schemaVersion": 1, "name": "X",
         "reference": {"id": "\(id.uuidString)", "name": "Ref",
                       "media": "media/ref.wav", "offsetSeconds": 2.5, "trimDb": -6,
                       "analysis": {"bandsDb": [1, 2, 3], "correlation": 1,
                                    "width": 0, "balance": 0, "durationSeconds": 1,
                                    "sampleRateHz": 48000, "analyzerVersion": 1}}}
        """
        let document = try JSONDecoder().decode(ProjectDocument.self, from: Data(json.utf8))
        let bundleURL = URL(fileURLWithPath: "/tmp/nonexistent-bundle.dawproj")
        let runtime = document.runtimeState(bundleURL: bundleURL)
        // The FILE is missing but the slot survives (honest absence surfaces
        // at analyze/monitor time), pointing at the resolved bundle path.
        let slot = try #require(runtime.reference)
        #expect(slot.id == id)
        #expect(slot.sourcePath == bundleURL.appendingPathComponent("media/ref.wav").path)
        #expect(slot.offsetSeconds == 2.5)
        #expect(slot.trimDb == -6)
        // Wrong band count sanitized to nil-analysis + a teaching warning.
        #expect(slot.analysis == nil)
        #expect(runtime.warnings.contains { $0.contains("re-run reference.analyze") })
        // The missing-media warning also landed (the clip policy).
        #expect(runtime.warnings.contains { $0.contains("missing media") })
    }
}

// MARK: - T2: the level-match law

@Suite("Reference level-match law (m22-g T2)")
struct ReferenceLevelMatchTests {

    @Test("no mix reading: basis is the -14 LUFS fallback, surfaced as fallbackTarget")
    func fallbackBasis() {
        let r = ReferenceLevelMatch.compute(
            mixIntegratedLufs: nil, refIntegratedLufs: -9.5,
            refTruePeakDbtp: -0.6, trimDb: 0)
        // requested = −14 − (−9.5) = −4.5; headroom = −1 − (−0.6) = −0.4.
        #expect(r.matchGainDb == -4.5)
        #expect(r.matchBasis == "fallbackTarget")
        #expect(!r.ceilingLimited)
        #expect(abs(r.linearGain - pow(10, -4.5 / 20)) <= 1e-12)
    }

    @Test("live basis + trim composition")
    func liveBasisAndTrim() {
        let r = ReferenceLevelMatch.compute(
            mixIntegratedLufs: -18, refIntegratedLufs: -9.5,
            refTruePeakDbtp: -0.6, trimDb: 2)
        // requested = (−18 − (−9.5)) + 2 = −6.5.
        #expect(r.matchGainDb == -6.5)
        #expect(r.matchBasis == "liveIntegrated")
        #expect(!r.ceilingLimited)
        // Trim re-clamps to ±24 inside the law.
        let clamped = ReferenceLevelMatch.compute(
            mixIntegratedLufs: -18, refIntegratedLufs: -9.5,
            refTruePeakDbtp: -60, trimDb: 99)
        #expect(clamped.matchGainDb == (-18 - (-9.5)) + 24)
    }

    @Test("ceiling clamp exact: refTP + gain == -1.0 dBTP when limited")
    func ceilingClampExact() {
        let r = ReferenceLevelMatch.compute(
            mixIntegratedLufs: -6, refIntegratedLufs: -20,
            refTruePeakDbtp: -3, trimDb: 0)
        // requested = +14; headroom = −1 − (−3) = +2 → limited.
        #expect(r.ceilingLimited)
        #expect(r.matchGainDb == 2)
        #expect(-3 + r.matchGainDb == ReferenceLevelMatch.ceilingDbtp)
        #expect(abs(r.linearGain - pow(10, 2.0 / 20)) <= 1e-12)
    }

    @Test("nil true peak assumes 0 dBTP (conservative: clamps harder, never louder)")
    func nilTruePeakConservative() {
        let r = ReferenceLevelMatch.compute(
            mixIntegratedLufs: nil, refIntegratedLufs: -20,
            refTruePeakDbtp: nil, trimDb: 0)
        // requested = +6; headroom = −1 − 0 = −1 → limited to −1.
        #expect(r.ceilingLimited)
        #expect(r.matchGainDb == -1)
    }
}

// MARK: - T3: stereo aggregates

@Suite("StereoImage whole-file aggregates (m22-g T3)")
struct StereoImageTests {
    private let tone = sine(frequency: 440, amplitude: 0.5, count: 48_000,
                            sampleRate: 48_000)

    @Test("mono: correlation EXACTLY +1, width EXACTLY 0, balance EXACTLY 0")
    func mono() {
        let a = StereoImage.measure(left: tone, right: tone)
        #expect(a.correlation == 1)
        #expect(a.width == 0)
        #expect(a.balance == 0)
    }

    @Test("anti-phase: correlation EXACTLY -1, width EXACTLY 1")
    func antiPhase() {
        let a = StereoImage.measure(left: tone, right: tone.map { -$0 })
        #expect(a.correlation == -1)
        #expect(a.width == 1)
        #expect(a.balance == 0)
    }

    @Test("dead channel: correlation snaps +1 (the m22-d rule); hard-pan balance EXACTLY ±1, width 0.5")
    func deadChannelAndHardPan() {
        let silence = [Float](repeating: 0, count: tone.count)
        let leftOnly = StereoImage.measure(left: tone, right: silence)
        #expect(leftOnly.correlation == 1)
        #expect(leftOnly.balance == -1)
        #expect(leftOnly.width == 0.5)
        let rightOnly = StereoImage.measure(left: silence, right: tone)
        #expect(rightOnly.correlation == 1)
        #expect(rightOnly.balance == 1)
    }

    @Test("decorrelated tones: correlation near 0, width near 0.5")
    func decorrelated() {
        let other = sine(frequency: 1_499, amplitude: 0.5, count: 48_000,
                         sampleRate: 48_000)
        let a = StereoImage.measure(left: tone, right: other)
        #expect(abs(a.correlation) <= 0.02)
        #expect(abs(a.width - 0.5) <= 0.02)
        #expect(abs(a.balance) <= 0.02)
    }

    @Test("NaN-poisoned chunk skipped WHOLE: aggregate identical to clean-only feed")
    func nanChunkSkipped() {
        var clean = StereoImage.Accumulator()
        clean.process(left: tone, right: tone.map { -$0 })

        var poisoned = StereoImage.Accumulator()
        poisoned.process(left: tone, right: tone.map { -$0 })
        var bad = tone
        bad[100] = .nan
        bad[200] = .infinity
        poisoned.process(left: bad, right: bad)

        #expect(poisoned.aggregate() == clean.aggregate())
    }

    @Test("silence/empty reads the floors: +1 / 0 / 0")
    func silenceFloors() {
        let empty = StereoImage.Accumulator().aggregate()
        #expect(empty == StereoImage.Aggregate(correlation: 1, width: 0, balance: 0))
        let silent = StereoImage.measure(
            left: [Float](repeating: 0, count: 4_800),
            right: [Float](repeating: 0, count: 4_800))
        #expect(silent == StereoImage.Aggregate(correlation: 1, width: 0, balance: 0))
    }
}

// MARK: - Store verbs + persistence

@MainActor
@Suite("Reference store verbs — import/replace/remove/analyze/undo + save/open (m22-g)")
struct ReferenceStoreTests {

    private func makeStore(engine: FakeReferenceEngine?) throws
        -> (ProjectStore, sourceDir: URL) {
        let store = ProjectStore()
        store.media = FakeMedia()
        store.engine = engine
        store.referenceImportsDirectory = try makeTempDir("imports")
        let sourceDir = try makeTempDir("sources")
        return (store, sourceDir)
    }

    @Test("import copies into the References home, analyzes, sets the slot, journals ONE edit")
    func importHappyPath() async throws {
        let engine = FakeReferenceEngine()
        engine.result = sampleAnalysis()
        let (store, sourceDir) = try makeStore(engine: engine)
        let source = try makeSourceFile(in: sourceDir)

        let outcome = try await store.importReference(path: source.path)
        #expect(outcome.warnings.isEmpty)
        let slot = try #require(store.reference)
        #expect(slot == outcome.slot)
        #expect(slot.name == "My Reference")          // basename sans extension
        #expect(slot.offsetSeconds == 0)
        #expect(slot.trimDb == 0)
        #expect(slot.analysis == sampleAnalysis())
        // Copied (never moved) into the imports home; the original survives.
        #expect(slot.sourcePath.hasPrefix(store.referenceImportsDirectory.path))
        #expect(FileManager.default.fileExists(atPath: slot.sourcePath))
        #expect(FileManager.default.fileExists(atPath: source.path))
        // The engine analyzed the COPY, not the original.
        #expect(engine.analyzedURLs.map(\.path) == [slot.sourcePath])
        #expect(store.isDirty)
        #expect(store.undoLabel == "Import Reference")
    }

    @Test("import over an existing slot REPLACES in one edit; undo restores the prior slot")
    func importReplaceUndo() async throws {
        let engine = FakeReferenceEngine()
        engine.result = sampleAnalysis()
        let (store, sourceDir) = try makeStore(engine: engine)
        let first = try makeSourceFile(in: sourceDir, name: "First.wav")
        let second = try makeSourceFile(in: sourceDir, name: "Second.wav")

        try await store.importReference(path: first.path)
        let firstSlot = try #require(store.reference)
        engine.result = sampleAnalysis(integrated: -12)
        try await store.importReference(path: second.path, name: "Custom Name")
        let secondSlot = try #require(store.reference)
        #expect(secondSlot.name == "Custom Name")
        #expect(secondSlot.id != firstSlot.id)

        // ONE undo restores the replaced slot, analysis included.
        try store.undo()
        #expect(store.reference == firstSlot)
        // A second undo reverses the first import entirely.
        try store.undo()
        #expect(store.reference == nil)
        // Redo brings the first slot back.
        try store.redo()
        #expect(store.reference == firstSlot)
    }

    @Test("analysis failure lands the slot WITHOUT analysis plus a warning (never fatal)")
    func importAnalysisFailure() async throws {
        let engine = FakeReferenceEngine()  // result nil ⇒ analyze throws
        let (store, sourceDir) = try makeStore(engine: engine)
        let source = try makeSourceFile(in: sourceDir)

        let outcome = try await store.importReference(path: source.path)
        #expect(outcome.slot.analysis == nil)
        #expect(outcome.warnings.contains { $0.contains("reference.analyze") })
        #expect(store.reference?.analysis == nil)
    }

    @Test("headless import (no engine) lands the slot un-analyzed with a warning")
    func importHeadless() async throws {
        let (store, sourceDir) = try makeStore(engine: nil)
        let source = try makeSourceFile(in: sourceDir)
        let outcome = try await store.importReference(path: source.path)
        #expect(outcome.slot.analysis == nil)
        #expect(outcome.warnings.contains { $0.contains("no audio engine") })
    }

    @Test("import refusals: missing file; no media service")
    func importRefusals() async throws {
        let (store, sourceDir) = try makeStore(engine: nil)
        await #expect(throws: ProjectError.self) {
            try await store.importReference(
                path: sourceDir.appendingPathComponent("nope.wav").path)
        }
        store.media = nil
        let source = try makeSourceFile(in: sourceDir)
        await #expect(throws: ProjectError.self) {
            try await store.importReference(path: source.path)
        }
    }

    @Test("remove clears the slot; undo restores it with analysis; empty slot refuses")
    func removeAndUndo() async throws {
        let engine = FakeReferenceEngine()
        engine.result = sampleAnalysis()
        let (store, sourceDir) = try makeStore(engine: engine)
        let source = try makeSourceFile(in: sourceDir)
        try await store.importReference(path: source.path)
        let slot = try #require(store.reference)

        let removed = try store.removeReference()
        #expect(removed == slot)
        #expect(store.reference == nil)
        #expect(store.undoLabel == "Remove Reference")
        // The imported copy is NOT deleted (no GC — undo resurrection).
        #expect(FileManager.default.fileExists(atPath: slot.sourcePath))

        try store.undo()
        #expect(store.reference == slot)

        _ = try store.removeReference()
        #expect(throws: ProjectError.self) { try store.removeReference() }
    }

    @Test("analyzeReference: refreshes the slot; refuses readably on empty/missing/headless")
    func analyzeVerb() async throws {
        let engine = FakeReferenceEngine()
        let (store, sourceDir) = try makeStore(engine: engine)

        // Empty slot → referenceNotSet.
        await #expect(throws: ProjectError.self) { try await store.analyzeReference() }

        let source = try makeSourceFile(in: sourceDir)
        try await store.importReference(path: source.path)  // analysis fails (result nil)
        #expect(store.reference?.analysis == nil)

        engine.result = sampleAnalysis()
        let fresh = try await store.analyzeReference()
        #expect(fresh == sampleAnalysis())
        #expect(store.reference?.analysis == sampleAnalysis())
        #expect(store.undoLabel == "Analyze Reference")

        // File vanishes → referenceFileMissing (the honest-absence contract).
        let slotPath = try #require(store.reference?.sourcePath)
        try FileManager.default.removeItem(atPath: slotPath)
        await #expect(throws: ProjectError.self) { try await store.analyzeReference() }

        // Headless → engineUnavailable.
        store.engine = nil
        await #expect(throws: ProjectError.self) { try await store.analyzeReference() }
    }

    @Test("status: empty → monitoring false, no preview; analyzed slot → exact law preview")
    func statusPreview() async throws {
        let engine = FakeReferenceEngine()
        engine.result = sampleAnalysis()  // integrated −9.5, TP −0.6
        let (store, sourceDir) = try makeStore(engine: engine)

        let empty = store.referenceStatus()
        #expect(empty.reference == nil)
        #expect(!empty.monitoring)
        #expect(empty.wouldMatchGainDb == nil)

        let source = try makeSourceFile(in: sourceDir)
        try await store.importReference(path: source.path)
        let status = store.referenceStatus()
        #expect(status.reference == store.reference)
        #expect(!status.monitoring)
        // FakeReferenceEngine has no liveLoudness → the −14 fallback basis:
        // (−14 − (−9.5)) + 0 = −4.5, headroom −0.4 → −4.5.
        #expect(status.wouldMatchGainDb == -4.5)
    }

    @Test("save folds the file into the bundle media/, rewrites sourcePath; open restores the slot")
    func saveOpenRoundTrip() async throws {
        let engine = FakeReferenceEngine()
        engine.result = sampleAnalysis()
        let (store, sourceDir) = try makeStore(engine: engine)
        let source = try makeSourceFile(in: sourceDir)
        try await store.importReference(path: source.path)
        let imported = try #require(store.reference)

        let bundleDir = try makeTempDir("bundles")
        let bundlePath = bundleDir.appendingPathComponent("Song.dawproj").path
        let result = try store.saveProject(to: bundlePath)
        #expect(result.warnings.isEmpty)

        // In-memory sourcePath repointed at the self-contained media/ copy.
        let saved = try #require(store.reference)
        #expect(saved.id == imported.id)
        #expect(saved.sourcePath.contains("/media/"))
        #expect(saved.sourcePath.hasPrefix(ProjectBundle.normalizedBundleURL(fromPath: bundlePath).path))
        #expect(FileManager.default.fileExists(atPath: saved.sourcePath))

        // A fresh store opens the bundle and restores the slot verbatim
        // (id, name, analysis) with the bundle-resolved path.
        let reopened = ProjectStore()
        reopened.media = FakeMedia()
        let warnings = try reopened.openProject(at: bundlePath)
        #expect(warnings.isEmpty)
        let restored = try #require(reopened.reference)
        #expect(restored.id == imported.id)
        #expect(restored.name == imported.name)
        #expect(restored.analysis == imported.analysis)
        #expect(restored.sourcePath == saved.sourcePath)

        // project.new clears the slot.
        try reopened.newProject(discardChanges: true)
        #expect(reopened.reference == nil)
    }

    @Test("snapshot mirrors the slot; monitor state is NEVER in the snapshot encoding")
    func snapshotMirror() async throws {
        let engine = FakeReferenceEngine()
        engine.result = sampleAnalysis()
        let (store, sourceDir) = try makeStore(engine: engine)

        // No slot → the key is omitted (pre-m22-g snapshots byte-identical).
        let emptyJSON = String(
            decoding: try JSONEncoder().encode(store.snapshot()), as: UTF8.self)
        #expect(!emptyJSON.contains("\"reference\""))

        let source = try makeSourceFile(in: sourceDir)
        try await store.importReference(path: source.path)
        let snapshot = store.snapshot()
        #expect(snapshot.reference == store.reference)
        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        #expect(json.contains("\"reference\""))
        // The transient-state law: no monitor state anywhere in the snapshot.
        #expect(!json.contains("monitoring"))
    }
}
