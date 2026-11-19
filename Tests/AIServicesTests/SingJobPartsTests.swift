import CryptoKit
import Foundation
import Testing
@testable import AIServices
@testable import DAWCore

// p2-sing-x6 (design docs/design/2026-10-06-p2-sing-expansion.md §4.4-§4.8, §5.4, §8.4, §9.2 S5): the sing job
// learns parts, style and breath. The SAME fakes as `SingJobCoordinatorTests` (scripted engine, scripted synthesizer,
// the fixtures' sine tracker), plus a recorder that keeps every facade request and a counting detector.
//
// Nonisolated on purpose (the tree is at its `@MainActor` suite cap): every store read goes through `MainActor.run`.
// ⚠️ No `Task.cancel()` anywhere: every wait polls.

// MARK: - Recorders

/// Keeps every request the coordinator sends, then lets the scripted fake render it.
actor RecordingSingSynth: SingingSynthesizing {
    let inner: FakeSingSynth
    private(set) var requests: [SingingPhraseRequest] = []

    init(inner: FakeSingSynth) { self.inner = inner }

    func renderPhrase(_ request: SingingPhraseRequest) async throws -> SingingRenderResult {
        requests.append(request)
        return try await inner.renderPhrase(request)
    }
}

/// Counts every call on the coordinator's `detectPitch` seam, and answers with the fixtures' sine tracker.
///
/// `lowPass` runs that many passes of a 1 ms moving average before tracking. The fixtures' zero-crossing tracker is
/// thrown by band noise that a real pitch detector shrugs off: MEASURED 00:13 in W8-X6's S2 run, a take with "lots"
/// of air (−12 dB of 1.5-9 kHz noise) failed gate L2 under the raw tracker. A style test that is about the
/// coordinator's wiring, not about the tracker, smooths first; the raw tracker's result is reported, not hidden.
actor DetectorSpy {
    private(set) var files: [String] = []
    var count: Int { files.count }
    let lowPass: Int

    /// W8-XL: when set, the call on the pre-air sum (`…-preair.wav`) is counted, then throws, so the style pass
    /// fails through the `.failure` arm it shares with the planner (`SungExpressionPlanner.plan` has no seam).
    private(set) var failsPreAir = false
    struct PreAirFailure: Error {}

    init(lowPass: Int = 0) { self.lowPass = lowPass }

    func failPreAir() { failsPreAir = true }

    func detect(_ url: URL) throws -> [ClipPitchFrame] {
        files.append(url.lastPathComponent)
        if failsPreAir, url.lastPathComponent.hasSuffix("-preair.wav") { throw PreAirFailure() }
        guard lowPass > 0 else { return try SingFixture.frames(at: url) }
        let audio = try SingWAV.read(url)
        var samples = audio.mono
        let width = max(1, audio.sampleRate / 1_000)
        for _ in 0..<lowPass {
            var out = samples
            var sum: Float = 0
            for i in samples.indices {
                sum += samples[i]
                if i >= width { sum -= samples[i - width] }
                out[i] = sum / Float(min(i + 1, width))
            }
            samples = out
        }
        return SingFixture.frames(samples: samples, sampleRate: audio.sampleRate)
    }
}

// MARK: - The harness

struct SingPartsHarness {
    let root: URL
    let store: ProjectStore
    let clipID: UUID
    let lifecycle: ModelLifecycleCoordinator
    let engine: FakeSingEngine
    let synth: FakeSingSynth
    let recorder: RecordingSingSynth
    let detector: DetectorSpy
    let cache: SingPhraseCache
    let coordinator: SingJobCoordinator

    /// How long a wait may take under a loaded machine (a contention allowance, not a weakened assertion: every
    /// wait is on work the test itself releases). MEASURED 00:17: a three-part job took 21 s of a 57-test parallel
    /// run, past `waitUntil`'s 20 s default.
    static let patience: Double = 120

    /// The clock every provenance reads (`renderedAt`), fixed so a record can be pinned byte for byte.
    static let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    static func make(_ label: String, lyrics: String? = SingFixture.twoUnitLyrics,
                     onsets: [Double] = SingFixture.twoUnitOnsets, pitches: [Int]? = nil,
                     lowPass: Int = 0) async throws
        -> SingPartsHarness {
        let root = try SingFixture.tempDir("x6-\(label)")
        let (store, clipID) = try await MainActor.run {
            try SingFixture.store(root: root, onsets: onsets, pitches: pitches, lyrics: lyrics)
        }
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
        let detector = DetectorSpy(lowPass: lowPass)
        let transcriber = FakeTranscriber()
        let cache = SingPhraseCache(directory: root.appendingPathComponent("cache", isDirectory: true))
        let now = fixedNow
        let configuration = SingJobCoordinator.Configuration(
            queueCapacity: 4, outputSampleRate: 24_000, modelPollSeconds: 0.002, enginePollSeconds: 0.002,
            sleepSeconds: { seconds in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) },
            now: { now }, songGeneratorRunsOutside: { false })
        let coordinator = SingJobCoordinator(
            store: store, engine: engine, synthesizer: recorder, lifecycle: lifecycle, cache: cache,
            detectPitch: { url in try await detector.detect(url) },
            transcribe: { url in try await transcriber.transcribe(url) },
            configuration: configuration)
        return SingPartsHarness(root: root, store: store, clipID: clipID, lifecycle: lifecycle, engine: engine,
                                synth: synth, recorder: recorder, detector: detector, cache: cache,
                                coordinator: coordinator)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func status(_ id: String) async throws -> SingJobStatus { try await coordinator.status(jobID: id) }

    /// Runs `request` to a terminal phase and waits for the checks after landing to finish.
    func run(_ request: SingJobRequest) async throws -> SingJobStatus {
        let id = try await coordinator.submit(request).jobID
        let ended = try await SingFixture.waitUntil(Self.patience) { try await status(id).phase.isTerminal }
        let last = try await status(id)
        #expect(ended, "the job never ended: \(last.phase) \(last.stageText)")
        _ = await SingFixture.waitUntil(Self.patience) { !(await coordinator.isBusy()) }
        return try await status(id)
    }

    func track(_ id: UUID?) async -> Track? {
        guard let id else { return nil }
        return await MainActor.run { store.tracks.first { $0.id == id } }
    }

    /// Every request's body, keys sorted (`SingJobRequestBuilder.canonicalBody`), with the cache folder in the
    /// output path replaced by "CACHE" (the folder is a fresh temp path per run).
    func bodies() async throws -> [String] {
        let requests = await recorder.requests
        return try requests.map { request in
            var normalised = request
            normalised.outputPath = "CACHE/" + URL(fileURLWithPath: request.outputPath).lastPathComponent
            return String(decoding: try SingJobRequestBuilder.canonicalBody(normalised), as: UTF8.self)
        }
    }

    /// The phrase-cache key each request was rendered under (its output file is named after the key).
    func cacheKeys() async -> [String] {
        await recorder.requests.map { URL(fileURLWithPath: $0.outputPath).deletingPathExtension().lastPathComponent }
    }

    /// The landed record, keys sorted, with the melody clip's id (fresh per run) replaced by "CLIP".
    static func provenanceJSON(_ record: SungVocalProvenance, clipID: UUID) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(record), as: UTF8.self)
            .replacingOccurrences(of: clipID.uuidString, with: "CLIP")
    }
}

// MARK: - S5: a default job is byte for byte what it was

@Suite("SingJob x6 — parts, style and air at assembly, the double (p2-sing-x6)")
struct SingJobPartsTests {

    // S5 goldens, captured on the UNCHANGED tree (W8-X6 PREDICTIONS P0). An empty golden records the actual value
    // as an issue instead of comparing, so a capture run cannot pass silently.
    static let goldenBodies: [String] = [
        #"{"cfg":3,"facadeVersion":1,"leadS":0.23999999999999999,"nSteps":32,"outputPath":"CACHE\/59ade2c865a0577a83aa24742a7997240626691f663dfc2b2e621565b3a6bd92.wav","outputSampleRate":24000,"phrase":{"notes":[{"endS":0.5,"midi":60,"startS":0},{"endS":1,"midi":62,"startS":0.5},{"endS":1.5,"midi":64,"startS":1},{"endS":2,"midi":65,"startS":1.5}],"words":[{"noteIndices":[0],"text":"one"},{"noteIndices":[1],"text":"two"},{"noteIndices":[2],"text":"three"},{"noteIndices":[3],"text":"four"}]},"seed":20260924,"trailS":0.23999999999999999,"voice":{"id":"builtin-1"}}"#,
        #"{"cfg":3,"facadeVersion":1,"leadS":0.23999999999999999,"nSteps":32,"outputPath":"CACHE\/3c0e658d8622a8ed37b43b1925c3e1df35256aabc38ce58b27fdfa4aefcb3bd4.wav","outputSampleRate":24000,"phrase":{"notes":[{"endS":0.5,"midi":67,"startS":0},{"endS":1,"midi":65,"startS":0.5},{"endS":1.5,"midi":64,"startS":1},{"endS":2,"midi":62,"startS":1.5}],"words":[{"noteIndices":[0],"text":"five"},{"noteIndices":[1],"text":"six"},{"noteIndices":[2],"text":"seven"},{"noteIndices":[3],"text":"eight"}]},"seed":20260924,"trailS":0.23999999999999999,"voice":{"id":"builtin-1"}}"#,
    ]
    static let goldenKeys: [String] = [
        "59ade2c865a0577a83aa24742a7997240626691f663dfc2b2e621565b3a6bd92",
        "3c0e658d8622a8ed37b43b1925c3e1df35256aabc38ce58b27fdfa4aefcb3bd4",
    ]
    static let goldenProvenance =
        #"{"cfg":3,"engineCommit":"fakecommit","engineId":"soulx-singer","facadeVersion":1,"loudness":{"appliedGainDb":6.324710824500787,"input":{"integratedLufs":-24.324710824500787,"loudnessRangeLu":9.178181746752106,"maxMomentaryLufs":-23.67489696549873,"maxShortTermLufs":-25.586111093280895,"truePeakDbtp":-19.99741464842447},"limitedByCeiling":false,"lufsTarget":-18,"output":{"integratedLufs":-17.999999566830272,"loudnessRangeLu":9.178181750190024,"maxMomentaryLufs":-17.350185707500994,"maxShortTermLufs":-19.261399835723232,"truePeakDbtp":-13.672703388776302},"truePeakCeilingDbtp":-1},"lyricsText":"one two three four\nfive six seven eight","nSteps":32,"noteAccuracy":{"hitRate":1,"inTune":true,"meanAbsErrorCents":6.428740928945575e-05,"offBars":[],"voicedCoverage":0.9325000000000732},"octaveShift":0,"renderedAt":821692800,"seed":20260924,"songTransposeSemitones":0,"sourceClipId":"CLIP","style":{"vibrato":"normal"},"voiceId":"builtin-1","voiceKind":"builtIn","voiceName":"Built-in singer","weightsRevision":"fakeweights","wordCheck":{"heard":"one two three four five six seven eight","state":"checked","verdict":"clear","wer":0}}"#

    // W9-PICKS (round V): the default vibrato is Normal. The facade bodies and cache keys are UNCHANGED (vibrato is a
    // table on the landed clip, never part of the request); the record gains `"style":{"vibrato":"normal"}` and nothing
    // else (MEASURED 17:09: the old golden == the new record minus that key), and the take now carries a table.
    @Test("S5: a default job's facade bodies, cache keys and provenance equal the pin-before goldens; one track, one undo, the default vibrato's table, Track defaults")
    func s5DefaultJobIsUnchanged() async throws {
        let h = try await SingPartsHarness.make("s5")
        defer { h.cleanup() }
        let undoBefore = await MainActor.run { h.store.undoHistory().undo.count }
        let tracksBefore = await MainActor.run { h.store.tracks.count }

        let done = try await h.run(SingJobRequest(clipID: h.clipID))
        #expect(done.phase == .done, "\(done.error?.message ?? "")")

        let bodies = try await h.bodies()
        let keys = await h.cacheKeys()
        #expect(bodies.count == 2)
        for body in bodies {
            #expect(body.contains("\"facadeVersion\":1"), "a default job is a v1 body")
            for v2 in ["\"lang\"", "\"control\"", "\"vibrato\""] { #expect(!body.contains(v2), "no \(v2) in a v1 body") }
        }
        if Self.goldenBodies.isEmpty {
            for (i, body) in bodies.enumerated() { Issue.record("GOLDEN-BODY-\(i) \(body)") }
        } else {
            #expect(bodies == Self.goldenBodies, "S5: the facade request bodies changed")
        }
        if Self.goldenKeys.isEmpty {
            Issue.record("GOLDEN-KEYS \(keys.joined(separator: ","))")
        } else {
            #expect(keys == Self.goldenKeys, "S5: the phrase-cache keys changed")
        }

        let trackID = try #require(done.result?.trackID)
        let track = try #require(await h.track(trackID))
        let record = try #require(track.sungVocalProvenance)
        #expect(record.facadeVersion == 1)
        let json = try SingPartsHarness.provenanceJSON(record, clipID: h.clipID)
        if Self.goldenProvenance.isEmpty {
            Issue.record("GOLDEN-PROVENANCE \(json)")
        } else {
            #expect(json == Self.goldenProvenance, "S5: the landed provenance changed")
        }

        // One track, one undo step, no pitch table, Track's own init defaults for pan and volume.
        #expect(await MainActor.run { h.store.tracks.count } == tracksBefore + 1)
        #expect(await MainActor.run { h.store.undoHistory().undo.count } == undoBefore + 1)
        #expect(await MainActor.run { h.store.undoHistory().undo.first } == "Land Sung Vocal")
        #expect(track.clips.count == 1)
        #expect(track.clips.first?.pitchEdits != nil, "the default Normal vibrato lands a table")
        let defaults = Track(name: "")
        #expect(track.pan == defaults.pan)
        #expect(track.volume == defaults.volume)
        // TWO detections per default job since the round-V pick: the pre-air pass, then post-gain (gates L2 and the
        // note check). The pin-before count was one.
        let detected = await h.detector.files
        #expect(detected.count == 2, "detector calls: \(detected)")
    }
}

// MARK: - Fixtures with longer notes and a style

enum SingPartsFixture {
    /// One phrase of four 2-beat notes (1 s each at 120 BPM) at beats 4, 6, 8, 10: long enough for the
    /// Gentle/Normal/Wide wobble (segments of at least 0.45 s).
    static let longLyrics = "one two three four"
    static let longNotes: [(start: Double, pitch: Int)] = [(4, 60), (6, 62), (8, 64), (10, 65)]

    /// Rebuilds the harness's melody clip with long notes, `velocities`, and `style`; returns the note ids.
    @MainActor
    static func lengthen(_ store: ProjectStore, clipID: UUID, style: (([UUID]) -> SingStyle?)? = nil,
                         velocities: [Int] = [100, 100, 100, 100]) throws -> [UUID] {
        let ids = longNotes.map { _ in UUID() }
        for t in store.tracks.indices {
            guard let c = store.tracks[t].clips.firstIndex(where: { $0.id == clipID }) else { continue }
            store.tracks[t].clips[c].notes = zip(ids, longNotes).enumerated().map { i, pair in
                MIDINote(id: pair.0, pitch: pair.1.pitch, velocity: velocities[i], startBeat: pair.1.start,
                         lengthBeats: 2)
            }
            store.tracks[t].clips[c].lyrics = ClipLyrics(text: longLyrics)
            store.tracks[t].clips[c].singStyle = style?(ids)
            return ids
        }
        throw ProjectError.clipNotFound(clipID)
    }
}

extension SingJobPartsTests {

    // MARK: Style and air at assembly (design §5.4)

    @Test("as sung (a style that asks for nothing): ONE detection, no table — the pin-before count")
    func asSungDetectsOnce() async throws {
        let h = try await SingPartsHarness.make("as-sung")
        defer { h.cleanup() }
        let ids = try await MainActor.run {
            try SingPartsFixture.lengthen(h.store, clipID: h.clipID) { ids in
                SingStyle(vibrato: .asSung, notes: [ids[0]: NoteSingStyle(vibrato: .asSung)])
            }
        }
        let done = try await h.run(SingJobRequest(clipID: h.clipID))
        #expect(done.phase == .done, "\(done.error?.message ?? "")")
        #expect(await h.detector.count == 1, "isNoOp: no pre-air detection")
        let track = try #require(await h.track(done.result?.trackID))
        #expect(track.clips.first?.pitchEdits == nil)
        // The record keeps the clip's style as planned (here: the clip's and one note's explicit "as sung"; a named
        // As sung is kept since the default became Normal, W9-PICKS).
        #expect(track.sungVocalProvenance?.style
                == SingStyle(vibrato: .asSung, notes: [ids[0]: NoteSingStyle(vibrato: .asSung)]))
        #expect(done.warnings.isEmpty)
    }

    @Test("a styled clip adds EXACTLY one detection (the pre-air sum), lands the planner's table and the air in ONE undo")
    func styledClipLandsTableAndAirInOneUndo() async throws {
        let plain = try await SingPartsHarness.make("styled-plain", lowPass: 2)
        defer { plain.cleanup() }
        _ = try await MainActor.run {
            try SingPartsFixture.lengthen(plain.store, clipID: plain.clipID) { _ in SingStyle(vibrato: .wide) }
        }
        let aired = try await SingPartsHarness.make("styled-air", lowPass: 2)
        defer { aired.cleanup() }
        _ = try await MainActor.run {
            try SingPartsFixture.lengthen(aired.store, clipID: aired.clipID) { _ in SingStyle(vibrato: .wide, air: 1) }
        }
        let tracksBefore = await MainActor.run { aired.store.tracks }
        let undoBefore = await MainActor.run { aired.store.undoHistory().undo.count }

        let a = try await plain.run(SingJobRequest(clipID: plain.clipID))
        let b = try await aired.run(SingJobRequest(clipID: aired.clipID))
        #expect(a.phase == .done && b.phase == .done, "\(a.error?.message ?? "") \(b.error?.message ?? "")")
        #expect(b.warnings.isEmpty, "\(b.warnings)")
        for h in [plain, aired] {
            let files = await h.detector.files
            #expect(files.count == 2, "\(files)")
            #expect(files.first?.hasSuffix("-preair.wav") == true, "the FIRST detection is on the pre-air sum")
            #expect(files.last?.hasSuffix("-preair.wav") == false)
            let takes = h.cache.directory.appendingPathComponent("takes").path
            let left = (try? FileManager.default.contentsOfDirectory(atPath: takes)) ?? []
            #expect(!left.contains { $0.hasSuffix("-preair.wav") }, "the pre-air file is removed: \(left)")
        }
        let trackA = try #require(await plain.track(a.result?.trackID))
        let trackB = try #require(await aired.track(b.result?.trackID))
        // The planner's table: Wide (70 cents) on the long notes' segments, on the landed clip, in the landing step.
        let table = try #require(trackB.clips.first?.pitchEdits)
        let wobbled = table.segments.filter { $0.vibratoDepthCents == 70 && $0.vibratoScale == 0 }
        #expect(wobbled.count >= 4, "Wide on each long note: \(table.segments.map(\.vibratoDepthCents))")
        #expect(trackA.clips.first?.pitchEdits != nil)
        #expect(trackB.sungVocalProvenance?.style == SingStyle(vibrato: .wide, air: 1))
        // The air is in the take BEFORE the gain: the loudness stage measured more energy going in.
        let inA = try #require(trackA.sungVocalProvenance?.loudness?.input.integratedLufs)
        let inB = try #require(trackB.sungVocalProvenance?.loudness?.input.integratedLufs)
        #expect(inB > inA + 0.01, "air adds energy before the gain: \(inA) vs \(inB)")
        // ONE undo step lands the track, its table and its record; undo removes all of it.
        #expect(await MainActor.run { aired.store.undoHistory().undo.count } == undoBefore + 1)
        #expect(try await MainActor.run { try aired.store.undo() } == "Land Sung Vocal")
        #expect(await MainActor.run { aired.store.tracks } == tracksBefore)
    }

    // W8-XL: this test pinned the defect W8-X6 MEASURED ("as wired", 2 detections). The coordinator now prunes the
    // orphans (`SingStyle.keepingOverrides(for:)`) before it asks `isNoOp`, so the style reads as "as sung": ONE
    // detection, X6's own pin-before count. The record still keeps the style exactly as planned, ghost and all.
    @Test("a style whose per-note choices are ALL orphans: pruned before isNoOp, it detects ONCE (as sung) and lands no table")
    func orphanStyleIsPrunedBeforeNoOp() async throws {
        let h = try await SingPartsHarness.make("orphans")
        defer { h.cleanup() }
        let ghost = UUID()
        _ = try await MainActor.run {
            // W9-PICKS: the clip names As sung (an unnamed vibrato is Normal now, which would run the pass anyway).
            try SingPartsFixture.lengthen(h.store, clipID: h.clipID) { _ in
                SingStyle(vibrato: .asSung, notes: [ghost: NoteSingStyle(vibrato: .wide, air: 1)])
            }
        }
        let done = try await h.run(SingJobRequest(clipID: h.clipID))
        #expect(done.phase == .done, "\(done.error?.message ?? "")")
        #expect(await h.detector.count == 1, "the orphans are pruned before isNoOp: no pre-air pass")
        let track = try #require(await h.track(done.result?.trackID))
        #expect(track.clips.first?.pitchEdits == nil, "every note resolves to as sung: no table")
        #expect(track.sungVocalProvenance?.style
                == SingStyle(vibrato: .asSung, notes: [ghost: NoteSingStyle(vibrato: .wide, air: 1)]))
    }

    @Test("velocities: a duplicate note id keeps the first (no trap); the frame rate is the frames' own")
    func velocitiesAndFrameRate() {
        let id = UUID()
        let notes = [MIDINote(id: id, pitch: 60, velocity: 40, startBeat: 0, lengthBeats: 1),
                     MIDINote(id: id, pitch: 62, velocity: 120, startBeat: 1, lengthBeats: 1)]
        #expect(SingJobCoordinator.velocities(of: notes) == [id: 40])
        func frames(_ step: Double) -> [ClipPitchFrame] {
            (0..<50).map { ClipPitchFrame(timeSeconds: Double($0) * step, frequencyHz: 220, confidence: 1,
                                          levelDbfs: -20, absence: nil) }
        }
        #expect(abs(SingJobCoordinator.detectionResult(frames(0.01), sampleRate: 24_000, durationSeconds: 1)
            .frameRateHz - 100) < 1e-6)
        #expect(abs(SingJobCoordinator.detectionResult(frames(0.016), sampleRate: 24_000, durationSeconds: 1)
            .frameRateHz - 62.5) < 1e-6)
        let none = SingJobCoordinator.detectionResult([], sampleRate: 24_000, durationSeconds: 1)
        #expect(none.frameRateHz == 62.5 && none.frameCount == 0 && none.voicedFraction == 0)
    }
}

extension SingJobPartsTests {

    static let cMajor = SongKey(tonicPitchClass: 0, mode: .major)
    static let thirdAbove = SingJobPart(.harmony(HarmonySpec(interval: .third, direction: .above, chordSource: .none)))

    // MARK: Parts (design §4.4-§4.6, §8.4)

    @Test("lead + third above + double: in order, part-aware progress and lifecycle ids, three tracks in ONE undo")
    func threePartsInOrderOneUndo() async throws {
        let h = try await SingPartsHarness.make("parts")
        defer { h.cleanup() }
        let leadFive = SingLatch(), harmonyOne = SingLatch()
        await h.synth.hold("five", leadFive)
        let tracksBefore = await MainActor.run { h.store.tracks }
        let undoBefore = await MainActor.run { h.store.undoHistory().undo.count }
        let request = SingJobRequest(clipID: h.clipID, parts: [Self.thirdAbove, SingJobPart(.double)],
                                     key: Self.cMajor)
        let submitted = try await h.coordinator.submit(request)
        let id = submitted.jobID
        #expect(submitted.parts?.map(\.role) == ["lead", "harmony", "double"])
        #expect(submitted.parts?.map(\.name) == ["lead", "third above", "double"])
        #expect(submitted.unitCount == 2)

        let leadLine2 = try await SingFixture.waitUntil(SingPartsHarness.patience) { try await h.status(id).unitIndex == 2 }
        #expect(leadLine2)
        #expect(try await h.status(id).stageText == "Singing part 1 of 3 · line 2 of 2…")
        #expect(await h.lifecycle.openJobIDs(.soulxSinger) == ["\(id)#0.1"], "R5 with the part: <jobId>#<part>.<unit>")
        await h.synth.hold("one", harmonyOne)
        await leadFive.release()
        let part2 = try await SingFixture.waitUntil(SingPartsHarness.patience) {
            try await h.status(id).stageText == "Singing part 2 of 3 · line 1 of 2…"
        }
        let mid = try await h.status(id)
        #expect(part2, "\(mid.stageText)")
        #expect(mid.progress > 0.30 && mid.progress < 0.36, "2 of 6 equal units done: \(mid.progress)")
        #expect(await h.lifecycle.openJobIDs(.soulxSinger) == ["\(id)#1.0"])
        #expect(mid.parts?.map(\.state) == [.sung, .singing, .waiting])
        await harmonyOne.release()

        let ended = try await SingFixture.waitUntil(SingPartsHarness.patience) { try await h.status(id).phase == .done }
        let final = try await h.status(id)
        #expect(ended, "\(final.phase): \(final.error?.message ?? final.stageText)")
        #expect(final.parts?.map(\.state) == [.landed, .landed, .landed])
        let landedIDs = (final.parts ?? []).compactMap(\.trackID)
        #expect(landedIDs.count == 3)
        let tracks = await MainActor.run { h.store.tracks.filter { landedIDs.contains($0.id) } }
        let byRole = Dictionary(tracks.map { ($0.sungVocalProvenance?.partRole ?? "?", $0) },
                                uniquingKeysWith: { a, _ in a })
        let lead = try #require(byRole["lead"]), harmony = try #require(byRole["harmony"])
        let double = try #require(byRole["double"])
        #expect(lead.name == "Vocals — Built-in singer" && lead.pan == 0 && lead.volume == 1)
        #expect(harmony.name == "Harmony — third above · Built-in singer")
        #expect(harmony.pan == 0.3 && abs(harmony.volume - 0.630957) < 1e-5)
        #expect(double.name == "Vocals — double · Built-in singer")
        #expect(double.pan == 0.4 && abs(double.volume - 0.630957) < 1e-5)
        #expect(harmony.sungVocalProvenance?.harmony?.spec?.name == "third above")
        #expect(harmony.sungVocalProvenance?.harmony?.key == Self.cMajor)
        #expect(lead.sungVocalProvenance?.harmony == nil && double.sungVocalProvenance?.harmony == nil)
        #expect(double.sungVocalProvenance?.seed == Int(SingHarness.take + 7_919))
        #expect(harmony.sungVocalProvenance?.seed == Int(SingHarness.take + 2))
        // Seeds as sung: the lead's on the take seed, the harmony's on seed + 2 (its own performance: the user's
        // round-H3 pick, W9-PICKS; it was the lead's before), the double's on seed + 7919.
        let seeds = await h.recorder.requests.map(\.seed)
        #expect(seeds == [SingHarness.take, SingHarness.take, SingHarness.take + 2, SingHarness.take + 2,
                          SingHarness.take + 7_919, SingHarness.take + 7_919])
        // The harmony's notes are a third above the lead's, plus whole octaves only (§4.5, §4.8 "Range").
        let requests = await h.recorder.requests
        let leadMidi = requests[0...1].flatMap { $0.notes.map(\.midi) }
        let harmonyMidi = requests[2...3].flatMap { $0.notes.map(\.midi) }
        let doubleMidi = requests[4...5].flatMap { $0.notes.map(\.midi) }
        #expect(doubleMidi == leadMidi)
        for (l, p) in zip(leadMidi, harmonyMidi) {
            #expect([3, 4].contains(((p - l) % 12 + 12) % 12), "a diatonic third: \(l) → \(p)")
        }
        // ONE undo step lands all three; ONE undo removes all three.
        #expect(await MainActor.run { h.store.undoHistory().undo.count } == undoBefore + 1)
        #expect(try await MainActor.run { try h.store.undo() } == "Land Sung Harmony")
        #expect(await MainActor.run { h.store.tracks } == tracksBefore)
    }
}

extension SingJobPartsTests {

    @Test("a part that fails L2 does not land and is named; the others land together in ONE undo")
    func failingPartIsNamedOthersLand() async throws {
        let h = try await SingPartsHarness.make("part-l2")
        defer { h.cleanup() }
        // Calls per word go lead, harmony, double: the harmony (2nd) sings noise on both of its lines.
        await h.synth.plan("one", [.sung(.sine), .sung(.noise)])
        await h.synth.plan("five", [.sung(.sine), .sung(.noise)])
        let tracksBefore = await MainActor.run { h.store.tracks }
        let done = try await h.run(SingJobRequest(clipID: h.clipID, parts: [Self.thirdAbove, SingJobPart(.double)],
                                                  key: Self.cMajor))
        #expect(done.phase == .done, "\(done.error?.message ?? "")")
        #expect(done.parts?.map(\.state) == [.landed, .failed, .landed])
        let failed = try #require(done.parts?[1])
        #expect(failed.error?.code == "singGateL2")
        #expect(failed.error?.message == "The part 'third above' didn't come out right.")
        #expect(failed.gates?.failed == [.singingPresent])
        #expect(failed.trackID == nil)
        #expect(done.notices.contains("The part 'third above' didn't come out right."))
        #expect(done.result?.trackID == done.parts?[0].trackID, "the job's result is the lead's")
        #expect(await MainActor.run { h.store.tracks.count } == tracksBefore.count + 2)
        #expect(try await MainActor.run { try h.store.undo() } == "Land Sung Harmony")
        #expect(await MainActor.run { h.store.tracks } == tracksBefore)
    }

    @Test("a cancel at a unit boundary of a parts job lands nothing; every part reads cancelled")
    func cancelLandsNothing() async throws {
        let h = try await SingPartsHarness.make("part-cancel")
        defer { h.cleanup() }
        let leadFive = SingLatch()
        await h.synth.hold("five", leadFive)
        let tracks = await MainActor.run { h.store.tracks.count }
        let id = try await h.coordinator.submit(SingJobRequest(clipID: h.clipID, parts: [SingJobPart(.double)])).jobID
        #expect(try await SingFixture.waitUntil(SingPartsHarness.patience) { try await h.status(id).unitIndex == 2 })
        _ = try await h.coordinator.cancel(jobID: id)
        await leadFive.release()
        #expect(try await SingFixture.waitUntil(SingPartsHarness.patience) { try await h.status(id).phase.isTerminal })
        let ended = try await h.status(id)
        #expect(ended.phase == .cancelled)
        #expect(ended.parts?.map(\.state) == [.cancelled, .cancelled])
        #expect(await h.recorder.requests.count == 2, "the double never started")
        #expect(await MainActor.run { h.store.tracks.count } == tracks)
    }

    @Test("the song transposed mid-job (+2): EVERY part lands moved by the same +2, in the one step")
    func transposedPartsMoveTogether() async throws {
        let h = try await SingPartsHarness.make("part-transpose")
        defer { h.cleanup() }
        let leadFive = SingLatch()
        await h.synth.hold("five", leadFive)
        let id = try await h.coordinator.submit(SingJobRequest(clipID: h.clipID,
                                                               parts: [Self.thirdAbove, SingJobPart(.double)],
                                                               key: Self.cMajor)).jobID
        #expect(try await SingFixture.waitUntil(SingPartsHarness.patience) { try await h.status(id).unitIndex == 2 })
        try await MainActor.run { _ = try h.store.transposeProject(semitones: 2) }
        await leadFive.release()
        #expect(try await SingFixture.waitUntil(SingPartsHarness.patience) { try await h.status(id).phase == .done })
        let done = try await h.status(id)
        let ids = (done.parts ?? []).compactMap(\.trackID)
        #expect(ids.count == 3)
        let shifts = await MainActor.run {
            h.store.tracks.filter { ids.contains($0.id) }.map { $0.clips.first?.pitchShiftSemitones }
        }
        #expect(shifts == [2, 2, 2])
        #expect(done.notices.contains(
            "The song moved up 2 half-steps while I was singing, so I moved this take up 2 half-steps to match."))
    }

    @Test("a part from another clip with no words borrows the lead's, lands with ITS clip as the source")
    func clipPartBorrowsWords() async throws {
        let h = try await SingPartsHarness.make("part-clip")
        defer { h.cleanup() }
        let otherID = try await MainActor.run { () throws -> UUID in
            let track = h.store.addTrack(kind: .instrument)
            let notes = SingFixture.twoUnitOnsets.enumerated().map { i, onset in
                MIDINote(pitch: [55, 57, 59, 60, 62, 60, 59, 57][i], startBeat: onset, lengthBeats: 1)
            }
            return try h.store.addMIDIClip(toTrack: track.id, name: "Low line", atBeat: 0, lengthBeats: 42,
                                           notes: notes).id
        }
        let done = try await h.run(SingJobRequest(clipID: h.clipID, parts: [SingJobPart(.clip(otherID), octaveShift: 0)]))
        #expect(done.phase == .done, "\(done.error?.message ?? "")")
        let partTrack = try #require(await h.track(done.parts?[1].trackID))
        #expect(partTrack.name == "Harmony — Low line · Built-in singer")
        #expect(partTrack.pan == -0.3, "it sits lower than the lead: the left side")
        #expect(partTrack.sungVocalProvenance?.sourceClipId == otherID)
        #expect(partTrack.sungVocalProvenance?.lyricsText == SingFixture.twoUnitLyrics)
        #expect(partTrack.sungVocalProvenance?.harmony == nil)
        #expect(!done.notices.contains("The melody changed while I was singing; this take follows the earlier version."),
                "its own replan (with the borrowed words) matched: \(done.notices)")
        let other = await MainActor.run { h.store.tracks.flatMap(\.clips).first { $0.id == otherID } }
        #expect(other?.lyrics == nil, "the borrowed words were never stored on the clip")
    }

    @Test("submit refuses a parts job at once, in words: too many, a double on the lead's seed, a missing clip, a bad pan")
    func partRefusals() async throws {
        let h = try await SingPartsHarness.make("part-refusals")
        defer { h.cleanup() }
        func code(_ parts: [SingJobPart]) async -> String? {
            do {
                _ = try await h.coordinator.submit(SingJobRequest(clipID: h.clipID, parts: parts, key: Self.cMajor))
                return nil
            } catch let error as SingJobError {
                return error.code
            } catch {
                return "\(error)"
            }
        }
        #expect(await code(Array(repeating: SingJobPart(.double), count: 4)) == "singTooManyParts")
        #expect(SingJobError.tooManyParts(maximum: 3).errorDescription == "You can add up to 3 harmony parts.")
        #expect(await code([SingJobPart(.double, seed: SingHarness.take)]) == "singPartInvalid")
        #expect(await code([SingJobPart(.clip(UUID()))]) == "singPartClipNotFound")
        #expect(await code([SingJobPart(.clip(h.clipID))]) == "singPartInvalid")
        #expect(await code([SingJobPart(.double, pan: 2)]) == "singPartInvalid")
        #expect(await code([SingJobPart(.double, volumeDb: .nan)]) == "singPartInvalid")
        #expect(SingJobError.harmony(.needsKey).code == "singHarmonyNeedsKey")
        #expect(await h.coordinator.statuses().isEmpty, "nothing was queued")
    }

    @Test("a harmony part sings the lead's per-note style on ITS notes (the leadNoteID remap reaches the job)")
    func harmonyStyleFollowsTheNotes() async throws {
        let h = try await SingPartsHarness.make("part-style")
        defer { h.cleanup() }
        let ids = try await MainActor.run {
            try SingPartsFixture.lengthen(h.store, clipID: h.clipID) { ids in
                SingStyle(notes: [ids[1]: NoteSingStyle(vibrato: .wide)])
            }
        }
        let done = try await h.run(SingJobRequest(clipID: h.clipID, parts: [Self.thirdAbove], key: Self.cMajor))
        #expect(done.phase == .done, "\(done.error?.message ?? "")")
        let harmony = try #require(await h.track(done.parts?[1].trackID))
        let partNote = HarmonyPlanner.partNoteID(leadNoteID: ids[1], partIndex: 1)
        // The record names the vibrato the job resolved (W9-PICKS: the clip names none, so Normal) and the note's own.
        #expect(harmony.sungVocalProvenance?.style
                == SingStyle(vibrato: .normal, notes: [partNote: NoteSingStyle(vibrato: .wide)]))
        let table = try #require(harmony.clips.first?.pitchEdits, "the part's own note got its Wide wobble")
        #expect(table.segments.contains { $0.vibratoDepthCents == 70 })
        #expect(await h.detector.count == 4, "two parts, each: one pre-air pass + one gate pass")
    }
}

// MARK: - W9-PICKS (p2-sing-x9-picks): the user's Sung Vocal Picks as the singer's defaults

/// What a landed pitch table says, as numbers only (segment ids are not compared), hashed: the byte pin for a take's
/// vibrato table.
enum PicksTableDigest {
    static func of(_ table: PitchEditSet?) -> String {
        guard let table else { return "no table" }
        let rows = table.segments.map { s in
            [s.startSeconds, s.endSeconds, s.detectedHz, s.pitchOffsetCents, s.driftScale, s.vibratoScale,
             s.vibratoRateHz, s.vibratoDepthCents, s.vibratoOnsetSeconds, s.vibratoPhaseAnchorSeconds]
                .map { String($0.bitPattern, radix: 16) }.joined(separator: ",")
        }
        let text = "\(rows.count)|" + rows.joined(separator: ";")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension SingJobPartsTests {

    // The takes the user picked were built by `Tests/DAWEngineTests/SingListeningRoundsX9RTests.swift`: V `normal-45c`
    // = `SingStyle(vibrato: .normal)`; H1 `third-above`; H2 `minus-4db` = `volumeDb: -4`; H3 `seed-3` = the part on
    // `firstTakeSeed + 2`; D `pan-0.4` = a double at pan 0.4.

    @Test("PICKS pin (captured before the edit): H2 −4 dB and D pan 0.4 were already the defaults; the side pans, the double's seed and the first take's seed stay")
    func picksKeptDefaults() {
        #expect(SingJobPart.firstOnASideDb == -4, "H2 minus-4db: the first part on a side")
        #expect(SingJobPart.doublePan == 0.4, "D pan-0.4")
        #expect(SingJobPart.doubleDb == -4)
        #expect(SingJobPart.firstOnASidePan == 0.3)
        #expect(SingJobPart.moreOnASidePan == 0.5 && SingJobPart.moreOnASideDb == -6)
        #expect(SingJobPart.doubleSeedOffset == 7_919)
        #expect(SingJobRequestBuilder.firstTakeSeed == 20_260_924)
    }

    @Test("PICKS pin (captured before the edit): a part's EXPLICIT seed is sung as given, the lead's own and 7")
    func explicitPartSeedIsHonoured() async throws {
        let h = try await SingPartsHarness.make("picks-explicit-seed")
        defer { h.cleanup() }
        var onLead = Self.thirdAbove
        onLead.seed = SingHarness.take
        let below = SingJobPart(.harmony(HarmonySpec(interval: .sixth, direction: .below, chordSource: .none)), seed: 7)
        let done = try await h.run(SingJobRequest(clipID: h.clipID, parts: [onLead, below], key: Self.cMajor))
        #expect(done.phase == .done, "\(done.error?.message ?? "")")
        #expect(done.parts?.map(\.seed) == [SingHarness.take, SingHarness.take, 7])
        let seeds = await h.recorder.requests.map(\.seed)
        #expect(seeds == [SingHarness.take, SingHarness.take, SingHarness.take, SingHarness.take, 7, 7], "\(seeds)")
        let partIDs = (done.parts ?? []).dropFirst().compactMap(\.trackID)
        #expect(partIDs.count == 2)
        var landed: [Int?] = []
        for id in partIDs { landed.append(await h.track(id)?.sungVocalProvenance?.seed) }
        #expect(landed == [Int(SingHarness.take), 7])
    }

    // Captured on the UNCHANGED tree, 2026-10-11 16:54 (`filter-baseline.log`: the run recorded both as issues).
    static let explicitNormalTableGolden = "e0c2d2f70ad03676292ca235945991914a6f2205e630c79db014b03a807a9b12"
    static let explicitNormalProvenanceGolden =
        #"{"cfg":3,"engineCommit":"fakecommit","engineId":"soulx-singer","facadeVersion":1,"loudness":{"appliedGainDb":5.966961406374587,"input":{"integratedLufs":-23.966961406374587,"loudnessRangeLu":0.22827975308489457,"maxMomentaryLufs":-23.70191352684367,"maxShortTermLufs":-23.782348368510387,"truePeakDbtp":-19.9978421507659},"limitedByCeiling":false,"lufsTarget":-18,"output":{"integratedLufs":-17.999999933762403,"loudnessRangeLu":0.22827975315478,"maxMomentaryLufs":-17.734952053241088,"maxShortTermLufs":-17.815386895466137,"truePeakDbtp":-14.030880756140498},"truePeakCeilingDbtp":-1},"lyricsText":"one two three four","nSteps":32,"noteAccuracy":{"hitRate":1,"inTune":true,"meanAbsErrorCents":2.5378519622287394e-05,"offBars":[],"voicedCoverage":0.9749999999999888},"octaveShift":0,"renderedAt":821692800,"seed":20260924,"songTransposeSemitones":0,"sourceClipId":"CLIP","style":{"vibrato":"normal"},"voiceId":"builtin-1","voiceKind":"builtIn","voiceName":"Built-in singer","weightsRevision":"fakeweights","wordCheck":{"heard":"one two three four five six seven eight","state":"checked","verdict":"unclear","wer":1}}"#

    @Test("PICKS pin (captured before the edit): an EXPLICIT Normal style lands this exact table and record")
    func explicitNormalIsPinned() async throws {
        let h = try await SingPartsHarness.make("picks-explicit-normal", lowPass: 2)
        defer { h.cleanup() }
        _ = try await MainActor.run {
            try SingPartsFixture.lengthen(h.store, clipID: h.clipID) { _ in SingStyle(vibrato: .normal) }
        }
        let done = try await h.run(SingJobRequest(clipID: h.clipID))
        #expect(done.phase == .done, "\(done.error?.message ?? "")")
        #expect(done.warnings.isEmpty, "\(done.warnings)")
        let track = try #require(await h.track(done.result?.trackID))
        let table = try #require(track.clips.first?.pitchEdits, "Normal on 1 s notes lands a table")
        #expect(table.segments.contains { $0.vibratoDepthCents == 45 && $0.vibratoScale == 0 })
        let digest = PicksTableDigest.of(table)
        let record = try SingPartsHarness.provenanceJSON(try #require(track.sungVocalProvenance), clipID: h.clipID)
        if Self.explicitNormalTableGolden.isEmpty {
            Issue.record("GOLDEN-PICKS-TABLE \(digest)")
        } else {
            #expect(digest == Self.explicitNormalTableGolden, "an explicit Normal take's table changed")
        }
        if Self.explicitNormalProvenanceGolden.isEmpty {
            Issue.record("GOLDEN-PICKS-PROVENANCE \(record)")
        } else {
            #expect(record == Self.explicitNormalProvenanceGolden, "an explicit Normal take's record changed")
        }
    }
}

extension SingJobPartsTests {

    @Test("PICKS V: a clip with NO style sings the round-V pick: the SAME table and record as an explicit Normal job, and the clip stays unstyled")
    func defaultVibratoIsThePick() async throws {
        #expect(SingStyle.defaultVibrato == .normal)
        let h = try await SingPartsHarness.make("picks-default-vibrato", lowPass: 2)
        defer { h.cleanup() }
        _ = try await MainActor.run { try SingPartsFixture.lengthen(h.store, clipID: h.clipID) }
        func stored() async -> SingStyle? {
            await MainActor.run { h.store.tracks.flatMap(\.clips).first { $0.id == h.clipID }?.singStyle }
        }
        #expect(await stored() == nil, "control: the melody clip has no style")
        let done = try await h.run(SingJobRequest(clipID: h.clipID))
        #expect(done.phase == .done, "\(done.error?.message ?? "")")
        #expect(done.warnings.isEmpty, "\(done.warnings)")
        let track = try #require(await h.track(done.result?.trackID))
        #expect(PicksTableDigest.of(track.clips.first?.pitchEdits) == Self.explicitNormalTableGolden,
                "the default take's table is the explicit Normal take's, bit for bit")
        let record = try SingPartsHarness.provenanceJSON(try #require(track.sungVocalProvenance), clipID: h.clipID)
        #expect(record == Self.explicitNormalProvenanceGolden, "the record names the vibrato that was sung: normal")
        #expect(await h.detector.count == 2, "a default job now runs the pre-air pass (one more detection)")
        #expect(await stored() == nil, "resolved when the job plans: nothing is written back to the clip")
    }

    @Test("PICKS H3: a harmony part with no seed sings on the lead's + 2, byte for byte the requests of the X9R seed-3 take")
    func defaultHarmonySeedIsThePick() async throws {
        #expect(SingJobPart.harmonySeedOffset == 2)
        let byDefault = try await SingPartsHarness.make("picks-h3-default")
        defer { byDefault.cleanup() }
        let asPicked = try await SingPartsHarness.make("picks-h3-seed3")
        defer { asPicked.cleanup() }
        // The X9R harness's seed-3: `SingJobPart(.harmony(thirdAbove), seed: firstTakeSeed + 2)`, no job seed.
        var seed3 = Self.thirdAbove
        seed3.seed = SingJobRequestBuilder.firstTakeSeed + 2
        let a = try await byDefault.run(SingJobRequest(clipID: byDefault.clipID, parts: [Self.thirdAbove],
                                                       key: Self.cMajor))
        let b = try await asPicked.run(SingJobRequest(clipID: asPicked.clipID, parts: [seed3], key: Self.cMajor))
        #expect(a.phase == .done && b.phase == .done, "\(a.error?.message ?? "") \(b.error?.message ?? "")")
        #expect(a.parts?.map(\.seed) == [SingHarness.take, SingHarness.take + 2])
        let bodies = try await byDefault.bodies()
        let pickedBodies = try await asPicked.bodies()
        #expect(bodies.count == 4)
        #expect(bodies == pickedBodies, "the default part's facade requests are seed-3's")
        let keys = await byDefault.cacheKeys()
        let pickedKeys = await asPicked.cacheKeys()
        #expect(keys == pickedKeys)
        try #require(keys.count == 4, "\(keys)")
        #expect(await byDefault.recorder.requests.map(\.seed)
                    == [SingHarness.take, SingHarness.take, SingHarness.take + 2, SingHarness.take + 2])
        #expect(Set(keys[0...1]).isDisjoint(with: Set(keys[2...3])), "its own performance: never the lead's cached line")
        let part = try #require(await byDefault.track(a.parts?[1].trackID))
        #expect(part.sungVocalProvenance?.seed == Int(SingHarness.take + 2))
    }

    @Test("PICKS H3: a chord-notes part and a part from another clip take the same default seed; a double keeps + 7919")
    func everyHarmonyKindTakesTheDefaultSeed() async throws {
        let h = try await SingPartsHarness.make("picks-h3-kinds")
        defer { h.cleanup() }
        let otherID = try await MainActor.run { () throws -> UUID in
            let track = h.store.addTrack(kind: .instrument)
            let notes = SingFixture.twoUnitOnsets.enumerated().map { i, onset in
                MIDINote(pitch: [55, 57, 59, 60, 62, 60, 59, 57][i], startBeat: onset, lengthBeats: 1)
            }
            return try h.store.addMIDIClip(toTrack: track.id, name: "Low line", atBeat: 0, lengthBeats: 42,
                                           notes: notes).id
        }
        let chord = SingJobPart(.chordTones(rank: .second, fillInterval: .third, fillChordSource: .none))
        let done = try await h.run(SingJobRequest(
            clipID: h.clipID, parts: [chord, SingJobPart(.clip(otherID), octaveShift: 0), SingJobPart(.double)],
            key: Self.cMajor))
        #expect(done.phase == .done, "\(done.error?.message ?? "")")
        #expect(done.parts?.map(\.seed)
                    == [SingHarness.take, SingHarness.take + 2, SingHarness.take + 2, SingHarness.take + 7_919])
    }
}
