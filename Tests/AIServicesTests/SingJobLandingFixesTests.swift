import Foundation
import Testing
@testable import AIServices
@testable import DAWCore

// W8-X6F: the coordinator half of W8-RV6's review of p2-sing-x6 (design docs/design/2026-10-06-p2-sing-expansion.md
// §4.4, §16), on the SAME fakes as `SingJobPartsTests` (`SingPartsHarness`):
// - S1: a cancel that arrives while the take is going into the song is REFUSED (`jobFinished`), never accepted and
//   then ignored, in the parts path and in the single-part path.
// - S2: a harmony whose chords change while it is sung still lands, and the job's notices name it.
// - S3: the parts-landing branches the review found untested: a different project, a style pass that fails (and its
//   pre-air file), a cancel during the style pass.
// - N3: a take written but not readable back is removed; the startup sweep of `takes/`.
//
// Nonisolated on purpose (the tree is at its `@MainActor` suite cap): every store read goes through `MainActor.run`.
// ⚠️ No `Task.cancel()` anywhere: every wait polls.

// MARK: - Fakes

/// `SingWAVMedia`, except that its FIRST read parks the caller (the main actor, inside a landing) until `release()`:
/// bounded at 60 s, so a red can never hang the suite. Keep the park short: it holds the main actor.
final class X6FBlockingMedia: MediaImporting, @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    private var entered = false
    private let gate = DispatchSemaphore(value: 0)

    var hasEntered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entered
    }

    func release() { gate.signal() }

    func audioFileInfo(at url: URL) throws -> AudioFileInfo {
        lock.lock()
        let first = !used
        used = true
        if first { entered = true }
        lock.unlock()
        if first { _ = gate.wait(timeout: .now() + 60) }
        return try SingWAVMedia().audioFileInfo(at: url)
    }
}

/// Cancels a job from inside the coordinator's own detection (a cancel DURING the style pass), once.
actor X6FCancelBox {
    private var coordinator: SingJobCoordinator?
    private var jobID: String?
    private(set) var result: String?

    func arm(_ coordinator: SingJobCoordinator, jobID: String) {
        self.coordinator = coordinator
        self.jobID = jobID
    }

    func cancelOnce() async {
        guard result == nil, let coordinator, let jobID else { return }
        do {
            let status = try await coordinator.cancel(jobID: jobID)
            result = "accepted:\(status.cancelRequested)"
        } catch {
            result = "refused:\(error)"
        }
    }
}

struct X6FReadBackFailure: Error, LocalizedError {
    var errorDescription: String? { "The take could not be read back." }
}

extension SingPartsHarness {
    /// `make`, with two hooks: `beforeDetect` runs before every detection; `readTakeBack` replaces the read-back of
    /// a written take (`SingJobCoordinator.Configuration.readTakeBack`).
    static func makeX6F(_ label: String, beforeDetect: (@Sendable (URL) async -> Void)? = nil,
                        readTakeBack: (@Sendable (URL) throws -> [Float])? = nil) async throws -> SingPartsHarness {
        let root = try SingFixture.tempDir("x6f-\(label)")
        let (store, clipID) = try await MainActor.run { try SingFixture.store(root: root) }
        let lifecycle = ModelLifecycleCoordinator(
            storageDirectory: root.appendingPathComponent("lifecycle", isDirectory: true), settleSeconds: 0)
        var soulx = ModelRegistry.soulxSinger(baseURL: URL(string: "http://127.0.0.1:9")!)
        soulx.idleUnloadSeconds = nil
        var ace = ModelRegistry.aceStep(baseURL: URL(string: "http://127.0.0.1:9")!)
        ace.idleUnloadSeconds = nil
        await lifecycle.register(soulx, evictor: nil)
        await lifecycle.register(ace, evictor: nil)
        let engine = FakeSingEngine(state: .installedNotRunning, lifecycle: lifecycle)
        let synth = FakeSingSynth(engine: engine)
        let recorder = RecordingSingSynth(inner: synth)
        let detector = DetectorSpy()
        let transcriber = FakeTranscriber()
        let cache = SingPhraseCache(directory: root.appendingPathComponent("cache", isDirectory: true))
        let now = fixedNow
        let configuration = SingJobCoordinator.Configuration(
            queueCapacity: 4, outputSampleRate: 24_000, modelPollSeconds: 0.002, enginePollSeconds: 0.002,
            sleepSeconds: { seconds in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) },
            now: { now }, songGeneratorRunsOutside: { false }, readTakeBack: readTakeBack)
        let coordinator = SingJobCoordinator(
            store: store, engine: engine, synthesizer: recorder, lifecycle: lifecycle, cache: cache,
            detectPitch: { url in
                if let beforeDetect { await beforeDetect(url) }
                return try await detector.detect(url)
            },
            transcribe: { url in try await transcriber.transcribe(url) },
            configuration: configuration)
        return SingPartsHarness(root: root, store: store, clipID: clipID, lifecycle: lifecycle, engine: engine,
                                synth: synth, recorder: recorder, detector: detector, cache: cache,
                                coordinator: coordinator)
    }

    var takesFolder: URL { cache.directory.appendingPathComponent("takes", isDirectory: true) }

    /// Every file left in `takes/`.
    func takesLeft() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: takesFolder.path)) ?? []).sorted()
    }

    /// Sets the melody clip's singing style.
    func setStyle(_ style: SingStyle) async throws {
        try await MainActor.run {
            for t in store.tracks.indices {
                if let c = store.tracks[t].clips.firstIndex(where: { $0.id == clipID }) {
                    store.tracks[t].clips[c].singStyle = style
                    return
                }
            }
            throw ProjectError.clipNotFound(clipID)
        }
    }
}

@Suite("SingJob x6 review fixes — cancel during landing, derived parts, untested branches, orphans (W8-X6F)")
struct SingJobLandingFixesTests {

    static let parts = [SingJobPartsTests.thirdAbove, SingJobPart(.double)]
    static let cMajor = SingJobPartsTests.cMajor

    // MARK: S1

    /// Submits `request`, waits until its landing is parked inside the store, cancels, releases. Returns the cancel's
    /// outcome and the job's final status.
    static func cancelDuringLanding(_ h: SingPartsHarness, _ request: SingJobRequest) async throws
        -> (refused: SingJobError?, ended: SingJobStatus) {
        let media = X6FBlockingMedia()
        await MainActor.run { h.store.media = media }
        let id = try await h.coordinator.submit(request).jobID
        let parked = await SingFixture.waitUntil(SingPartsHarness.patience) { media.hasEntered }
        var refused: SingJobError?
        if parked {
            do {
                _ = try await h.coordinator.cancel(jobID: id)
            } catch let error as SingJobError {
                refused = error
            }
        }
        media.release()
        #expect(parked, "the landing never reached the store")
        let ended = try await SingFixture.waitUntil(SingPartsHarness.patience) { try await h.status(id).phase.isTerminal }
        #expect(ended)
        _ = await SingFixture.waitUntil(SingPartsHarness.patience) { !(await h.coordinator.isBusy()) }
        return (refused, try await h.status(id))
    }

    @Test("S1: a cancel while a PARTS job is landing is refused (jobFinished); every part lands, the job reads done")
    func cancelDuringPartsLandingIsRefused() async throws {
        let h = try await SingPartsHarness.make("x6f-s1-parts")
        defer { h.cleanup() }
        let before = await MainActor.run { h.store.tracks.count }
        let (refused, done) = try await Self.cancelDuringLanding(
            h, SingJobRequest(clipID: h.clipID, parts: Self.parts, key: Self.cMajor))
        #expect(refused == .jobFinished(done.jobID), "\(String(describing: refused))")
        #expect(done.phase == .done, "\(done.error?.message ?? done.stageText)")
        #expect(done.cancelRequested == false, "a refused cancel leaves no request behind")
        #expect(done.parts?.map(\.state) == [.landed, .landed, .landed])
        #expect(await MainActor.run { h.store.tracks.count } == before + 3)
    }

    @Test("S1: a cancel while a SINGLE-PART job is landing is refused (jobFinished); the take lands, the job reads done")
    func cancelDuringSingleLandingIsRefused() async throws {
        let h = try await SingPartsHarness.make("x6f-s1-single")
        defer { h.cleanup() }
        let before = await MainActor.run { h.store.tracks.count }
        let (refused, done) = try await Self.cancelDuringLanding(h, SingJobRequest(clipID: h.clipID))
        #expect(refused == .jobFinished(done.jobID), "\(String(describing: refused))")
        #expect(done.phase == .done, "\(done.error?.message ?? done.stageText)")
        #expect(done.cancelRequested == false)
        #expect(await MainActor.run { h.store.tracks.count } == before + 1)
    }

    // MARK: S2 (end to end: the coordinator hands the planned notes to the landing)

    static let otherTracksThird = SingJobPart(.harmony(HarmonySpec(interval: .third, direction: .above,
                                                                    chordSource: .otherTracks)))
    static let drifted =
        "The chords changed while 'third above' was being sung, so it may not fit now. Sing it again to match."

    /// Lead + third above (over the other tracks' chords) with a C major chord under the whole melody; while the
    /// lead's second line is held, the chord becomes F major when `change` is set.
    static func harmonyJob(_ label: String, change: Bool) async throws -> SingJobStatus {
        let h = try await SingPartsHarness.make(label)
        defer { h.cleanup() }
        let chordTrack = try await MainActor.run { () throws -> UUID in
            let track = h.store.addTrack(kind: .instrument)
            _ = try h.store.addMIDIClip(toTrack: track.id, name: "Chords", atBeat: 0, lengthBeats: 48,
                                        notes: [48, 52, 55].map { MIDINote(pitch: $0, startBeat: 0, lengthBeats: 48) })
            return track.id
        }
        let leadFive = SingLatch()
        await h.synth.hold("five", leadFive)
        let id = try await h.coordinator.submit(SingJobRequest(clipID: h.clipID, parts: [otherTracksThird],
                                                               key: cMajor)).jobID
        #expect(try await SingFixture.waitUntil(SingPartsHarness.patience) { try await h.status(id).unitIndex == 2 })
        if change {
            await MainActor.run {
                for t in h.store.tracks.indices where h.store.tracks[t].id == chordTrack {
                    h.store.tracks[t].clips[0].notes = [53, 57, 60].map {
                        MIDINote(pitch: $0, startBeat: 0, lengthBeats: 48)
                    }
                }
            }
        }
        await leadFive.release()
        #expect(try await SingFixture.waitUntil(SingPartsHarness.patience) { try await h.status(id).phase.isTerminal })
        _ = await SingFixture.waitUntil(SingPartsHarness.patience) { !(await h.coordinator.isBusy()) }
        return try await h.status(id)
    }

    @Test("S2: the chords under a harmony change mid-job: it still lands, and the job's notices name it; unchanged: no notice")
    func chordChangeMidJobNamesThePart() async throws {
        let changed = try await Self.harmonyJob("x6f-s2-changed", change: true)
        #expect(changed.phase == .done, "\(changed.error?.message ?? "")")
        #expect(changed.parts?.map(\.state) == [.landed, .landed])
        #expect(changed.notices.contains(Self.drifted), "\(changed.notices)")
        let melodyChanged = await MainActor.run { ProjectStore.sungVocalMelodyChangedNotice }
        #expect(!changed.notices.contains(melodyChanged), "the melody itself did not change")
        let same = try await Self.harmonyJob("x6f-s2-same", change: false)
        #expect(same.phase == .done, "\(same.error?.message ?? "")")
        #expect(!same.notices.contains(Self.drifted), "\(same.notices)")
    }

    // MARK: S3

    @Test("S3a: a different project opened mid-job (parts): nothing lands; EVERY part's take is kept; the job names one")
    func partsProjectChangedKeepsEveryTake() async throws {
        let h = try await SingPartsHarness.make("x6f-s3a")
        defer { h.cleanup() }
        let leadFive = SingLatch()
        await h.synth.hold("five", leadFive)
        let id = try await h.coordinator.submit(SingJobRequest(clipID: h.clipID, parts: Self.parts,
                                                               key: Self.cMajor)).jobID
        #expect(try await SingFixture.waitUntil(SingPartsHarness.patience) { try await h.status(id).unitIndex == 2 })
        try await MainActor.run { try h.store.newProject(discardChanges: true) }
        await leadFive.release()
        #expect(try await SingFixture.waitUntil(SingPartsHarness.patience) { try await h.status(id).phase.isTerminal })
        _ = await SingFixture.waitUntil(SingPartsHarness.patience) { !(await h.coordinator.isBusy()) }
        let failed = try await h.status(id)
        #expect(failed.phase == .failed)
        #expect(failed.error?.code == "singProjectChanged")
        let kept = try #require(failed.keptTakePath)
        #expect(FileManager.default.fileExists(atPath: kept))
        let generations = h.root.appendingPathComponent("generations")
        #expect(kept.hasPrefix(generations.path))
        let copies = (try? FileManager.default.contentsOfDirectory(atPath: generations.path)) ?? []
        #expect(copies.count == 3, "one kept copy per part: \(copies)")
        #expect(failed.parts?.map(\.state) == [.failed, .failed, .failed])
        #expect(await MainActor.run { h.store.tracks.allSatisfy { $0.sungVocalProvenance == nil } })
        #expect(h.takesLeft().isEmpty, "\(h.takesLeft())")
    }

    @Test("S3b: the style pass fails in a parts job: every part lands as sung, each is named, and no pre-air file is left")
    func partsStyleFailureNamesEachPart() async throws {
        let h = try await SingPartsHarness.make("x6f-s3b")
        defer { h.cleanup() }
        try await h.setStyle(SingStyle(vibrato: .wide))
        await h.detector.failPreAir()
        let done = try await h.run(SingJobRequest(clipID: h.clipID, parts: Self.parts, key: Self.cMajor))
        #expect(done.phase == .done, "\(done.error?.message ?? "")")
        #expect(done.parts?.map(\.state) == [.landed, .landed, .landed])
        for name in ["lead", "third above", "double"] {
            #expect(done.warnings.contains(SingJobCoordinator.Copy.styleNotApplied(part: name)), "\(done.warnings)")
        }
        let files = await h.detector.files
        #expect(files.filter { $0.hasSuffix("-preair.wav") }.count == 3, "one failed pre-air detection per part: \(files)")
        let ids = (done.parts ?? []).compactMap(\.trackID)
        let landed = await MainActor.run { h.store.tracks.filter { ids.contains($0.id) } }
        #expect(landed.count == 3)
        #expect(landed.allSatisfy { $0.clips.first?.pitchEdits == nil }, "landed without a table")
        #expect(landed.allSatisfy { $0.sungVocalProvenance?.style == nil }, "the record says no style was sung")
        #expect(!h.takesLeft().contains { $0.hasSuffix("-preair.wav") }, "the pre-air files are removed: \(h.takesLeft())")
    }

    @Test("S3c: a cancel during the style pass: the job ends cancelled, nothing lands, nothing is left in takes/")
    func cancelDuringStylePass() async throws {
        let box = X6FCancelBox()
        let h = try await SingPartsHarness.makeX6F("x6f-s3c", beforeDetect: { url in
            if url.lastPathComponent.hasSuffix("-preair.wav") { await box.cancelOnce() }
        })
        defer { h.cleanup() }
        try await h.setStyle(SingStyle(vibrato: .wide))
        let before = await MainActor.run { h.store.tracks }
        let leadFive = SingLatch()
        await h.synth.hold("five", leadFive)
        let id = try await h.coordinator.submit(SingJobRequest(clipID: h.clipID, parts: Self.parts,
                                                               key: Self.cMajor)).jobID
        await box.arm(h.coordinator, jobID: id)
        await leadFive.release()
        #expect(try await SingFixture.waitUntil(SingPartsHarness.patience) { try await h.status(id).phase.isTerminal })
        _ = await SingFixture.waitUntil(SingPartsHarness.patience) { !(await h.coordinator.isBusy()) }
        let ended = try await h.status(id)
        let cancel = await box.result
        #expect(cancel == "accepted:true", "the cancel came during the style pass: \(String(describing: cancel))")
        #expect(ended.phase == .cancelled, "\(ended.phase) \(ended.error?.message ?? "")")
        #expect(await MainActor.run { h.store.tracks } == before)
        #expect(h.takesLeft().isEmpty, "no pre-air sum, no take: \(h.takesLeft())")
    }

    // MARK: N3

    @Test("N3: a take written but not readable back is removed, and the job fails in words")
    func unreadableTakeIsRemoved() async throws {
        let h = try await SingPartsHarness.makeX6F("x6f-n3-read", readTakeBack: { _ in throw X6FReadBackFailure() })
        defer { h.cleanup() }
        let done = try await h.run(SingJobRequest(clipID: h.clipID))
        #expect(done.phase == .failed)
        #expect(done.error?.code == "singTakeWriteFailed")
        #expect(h.takesLeft().isEmpty, "\(h.takesLeft())")
    }

    /// Writes `name` into `takes/`, last modified `age` seconds ago.
    static func seed(_ h: SingPartsHarness, _ name: String, age: Double) throws -> URL {
        try FileManager.default.createDirectory(at: h.takesFolder, withIntermediateDirectories: true)
        let url = h.takesFolder.appendingPathComponent(name)
        try Data("RIFF-x6f".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)],
                                              ofItemAtPath: url.path)
        return url
    }

    @Test("N3 sweep: an old take no record names and no clip plays is deleted; a younger one is kept")
    func sweepDeletesAnOldStray() async throws {
        let h = try await SingPartsHarness.make("x6f-sweep")
        defer { h.cleanup() }
        let stray = try Self.seed(h, "sing-dead-0.wav", age: 7_200)
        let preAir = try Self.seed(h, "sing-dead-0-preair.wav", age: 7_200)
        let young = try Self.seed(h, "sing-other-app.wav", age: 1_800)
        let other = try Self.seed(h, "notes.txt", age: 7_200)
        let deleted = await h.coordinator.sweepOrphanTakes()
        #expect(!FileManager.default.fileExists(atPath: stray.path))
        #expect(!FileManager.default.fileExists(atPath: preAir.path))
        #expect(Set(deleted.map(\.lastPathComponent)).isSubset(of: ["sing-dead-0.wav", "sing-dead-0-preair.wav"]))
        #expect(FileManager.default.fileExists(atPath: young.path), "younger than an hour: another app's job may own it")
        #expect(FileManager.default.fileExists(atPath: other.path), "only takes (.wav) are swept")
    }

    @Test("N3 sweep: a file a landed clip plays is NEVER deleted, nor one a job record names (and a stray beside them is)")
    func sweepKeepsReferencedAndRecorded() async throws {
        let h = try await SingPartsHarness.make("x6f-sweep-keep")
        defer { h.cleanup() }
        // The coordinator's startup sweep (`SingJobCoordinator.init`) runs unawaited and may read the clips at any
        // moment. It lists `takes/` BEFORE it reads the clips, so the clip must be in the store BEFORE the file
        // exists: any sweep that can see the file then also sees the clip that plays it. (Seeding first left a
        // window where the sweep read the clips before the append, and deleted the file. p2-sing-x6-sweeprace.)
        let played = h.takesFolder.appendingPathComponent("sing-landed-0.wav")
        await MainActor.run {
            let clip = Clip(name: "Kept take", startBeat: 0, lengthBeats: 4, audioFileURL: played, isAIGenerated: true)
            h.store.tracks.append(Track(name: "Kept", kind: .audio, isAIGenerated: true, clips: [clip]))
        }
        _ = try Self.seed(h, "sing-landed-0.wav", age: 7_200)
        let leadFive = SingLatch()
        await h.synth.hold("five", leadFive)
        let id = try await h.coordinator.submit(SingJobRequest(clipID: h.clipID)).jobID
        let recorded = try Self.seed(h, "\(id)-preair.wav", age: 7_200)
        let stray = try Self.seed(h, "sing-dead-1.wav", age: 7_200)
        _ = await h.coordinator.sweepOrphanTakes()
        #expect(FileManager.default.fileExists(atPath: played.path), "a landed clip plays it")
        #expect(FileManager.default.fileExists(atPath: recorded.path), "a job record names it")
        #expect(!FileManager.default.fileExists(atPath: stray.path), "the positive control: the sweep ran")
        await leadFive.release()
        _ = try await SingFixture.waitUntil(SingPartsHarness.patience) { try await h.status(id).phase.isTerminal }
        _ = await SingFixture.waitUntil(SingPartsHarness.patience) { !(await h.coordinator.isBusy()) }
    }
}

// MARK: - Plan only, and a chord-notes part through the job (W8-X6F, on the orchestrator's word)

extension SingJobLandingFixesTests {

    @Test("plan(_:) gives what submit's first status carries (parts byte for byte, warnings), queues nothing, refuses alike")
    func planOnlyMatchesSubmit() async throws {
        let h = try await SingPartsHarness.make("x6f-plan")
        defer { h.cleanup() }
        let request = SingJobRequest(clipID: h.clipID, parts: Self.parts, key: Self.cMajor)
        let preview = try await h.coordinator.plan(request)
        #expect(await h.coordinator.statuses().isEmpty, "plan queues nothing")
        #expect(await h.coordinator.isBusy() == false)
        let lead = try await MainActor.run { try h.store.planSungVocal(clipId: h.clipID, octaveShift: 0) }
        #expect(preview.plan == lead.plan)
        let submitted = try await h.coordinator.submit(request)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let planned = String(decoding: try encoder.encode(preview.parts), as: UTF8.self)
        let queued = String(decoding: try encoder.encode(submitted.parts), as: UTF8.self)
        #expect(preview.parts?.count == 3)
        #expect(planned == queued)
        #expect(preview.warnings == submitted.warnings)
        _ = try await SingFixture.waitUntil(SingPartsHarness.patience) {
            try await h.status(submitted.jobID).phase.isTerminal
        }
        _ = await SingFixture.waitUntil(SingPartsHarness.patience) { !(await h.coordinator.isBusy()) }

        func refusal(_ parts: [SingJobPart], submit: Bool) async -> SingJobError? {
            let bad = SingJobRequest(clipID: h.clipID, parts: parts, key: Self.cMajor)
            do {
                if submit { _ = try await h.coordinator.submit(bad) } else { _ = try await h.coordinator.plan(bad) }
                return nil
            } catch let error as SingJobError {
                return error
            } catch {
                return nil
            }
        }
        for parts in [[SingJobPart(.double, pan: 2)], [SingJobPart(.clip(UUID()))],
                      Array(repeating: SingJobPart(.double), count: 4)] {
            let byPlan = await refusal(parts, submit: false)
            let bySubmit = await refusal(parts, submit: true)
            #expect(byPlan != nil)
            #expect(byPlan == bySubmit)
        }
    }

    @Test("a chord-notes part renders through the fake synthesizer and lands with the lead in ONE undo")
    func chordTonesPartLandsInOneUndo() async throws {
        let h = try await SingPartsHarness.make("x6f-chord-notes")
        defer { h.cleanup() }
        // ONE chord note, G3, under the first lead note (C4 at beat 4), in the melody clip itself.
        try await MainActor.run {
            for t in h.store.tracks.indices {
                if let c = h.store.tracks[t].clips.firstIndex(where: { $0.id == h.clipID }) {
                    h.store.tracks[t].clips[c].notes?.append(MIDINote(pitch: 55, startBeat: 4, lengthBeats: 1))
                    return
                }
            }
            throw ProjectError.clipNotFound(h.clipID)
        }
        let tracksBefore = await MainActor.run { h.store.tracks }
        let undoBefore = await MainActor.run { h.store.undoHistory().undo.count }
        let chordNotes = SingJobPart(.chordTones(rank: .second, fillInterval: .sixth, fillChordSource: .none))
        let done = try await h.run(SingJobRequest(clipID: h.clipID, parts: [chordNotes], key: Self.cMajor))
        #expect(done.phase == .done, "\(done.error?.message ?? "")")
        #expect(done.parts?.map(\.state) == [.landed, .landed])
        #expect(done.parts?.map(\.name) == ["lead", "chord notes"])
        #expect(!done.notices.contains { $0.hasPrefix("The chords changed") }, "its landing re-derivation matched")
        let requests = await h.recorder.requests
        #expect(requests.count == 4)
        let leadMidi = requests.prefix(2).flatMap { $0.notes.map(\.midi) }
        let partMidi = requests.dropFirst(2).flatMap { $0.notes.map(\.midi) }
        #expect(leadMidi == SingFixture.twoUnitPitches, "the chord note is not sung by the lead")
        #expect(partMidi.count == leadMidi.count)
        #expect(partMidi.first.map { (($0 % 12) + 12) % 12 } == 7, "the clip's own chord note, a G: \(partMidi)")
        for (l, p) in zip(leadMidi.dropFirst(), partMidi.dropFirst()) {
            #expect([8, 9].contains((((l - p) % 12) + 12) % 12), "a sixth below fills in: \(l) → \(p)")
        }
        let ids = (done.parts ?? []).compactMap(\.trackID)
        let part = try #require(await h.track(ids.last))
        #expect(part.sungVocalProvenance?.partRole == "harmony")
        #expect(part.sungVocalProvenance?.harmony?.chordToneRank == 2)
        #expect(await MainActor.run { h.store.undoHistory().undo.count } == undoBefore + 1)
        #expect(try await MainActor.run { try h.store.undo() } == "Land Sung Harmony")
        #expect(await MainActor.run { h.store.tracks } == tracksBefore)
    }
}
