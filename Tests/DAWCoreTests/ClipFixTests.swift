import Foundation
import Testing
@testable import DAWCore

// MARK: - Fakes

/// Recording generation seam for the clip vocal-fix flow (M6 v-b): records the
/// `ClipRepaintRequest` handed to `submitRepaint` and returns a scripted
/// receipt (a fresh jobId per submit so multiple in-flight fixes never collide),
/// alongside a scripted `fetchGeneration` for the import side. An actor (the
/// `FakeSongGenerator` precedent) so it's Sendable without `@unchecked`.
actor FakeClipFixSource: GenerationImporting {
    var fetchResult: Result<GeneratedSongResult, Error>
    var queuePosition: Int?
    private(set) var lastRepaintRequest: ClipRepaintRequest?
    private(set) var submitCount = 0

    init(fetchResult: Result<GeneratedSongResult, Error> = .success(GeneratedSongResult(state: "running")),
         queuePosition: Int? = 3) {
        self.fetchResult = fetchResult
        self.queuePosition = queuePosition
    }

    func fetchGeneration(jobID: String) async throws -> GeneratedSongResult { try fetchResult.get() }
    func fetchGenerationStems(jobID: String) async throws -> GeneratedStemsResult {
        GeneratedStemsResult(state: "running")
    }

    func submitRepaint(_ request: ClipRepaintRequest) async throws -> ClipFixJobReceipt {
        submitCount += 1
        lastRepaintRequest = request
        return ClipFixJobReceipt(jobID: "fix-job-\(submitCount)", queuePosition: queuePosition)
    }

    func setFetchResult(_ result: Result<GeneratedSongResult, Error>) { fetchResult = result }
}

/// Buffer-out render engine that records the `renderOffline` invocation (tracks/
/// fromBeat/duration/masterVolume) and writes a stub bounce file — so the D1/D3
/// bounce contract is assertable headless (modelled on `FakeBufferEngine`).
@MainActor
final class FakeRenderEngine: AudioEngineControlling {
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var recordPermission: RecordPermission = .granted

    struct RenderCall {
        var tracks: [Track]
        var fromBeat: Double
        var duration: Double
        var masterVolume: Double
    }
    private(set) var renderCalls: [RenderCall] = []
    private(set) var written: [URL] = []

    func prepare() throws { isRunning = true }
    func shutdown() { isRunning = false }
    func tracksDidChange(_ tracks: [Track]) {}
    func startPlayback(_ transport: TransportState) {}
    func stopPlayback() {}
    func seek(_ transport: TransportState) {}
    func setTempo(_ transport: TransportState) {}
    func loopChanged(_ transport: TransportState) {}
    func masterVolumeChanged(_ volume: Double) {}
    func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {}
    func availableInputDevices() -> [AudioInputDevice] { [] }
    func setInputDevice(uid: String?) throws {}
    func startRecording(_ transport: TransportState, to url: URL,
                        completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {}
    func stopRecording() {}

    func renderMixdown(tracks: [Track], tempoBPM: Double, masterVolume: Double,
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL) async throws -> AudioFileInfo {
        AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000, channelCount: 2)
    }

    func renderOffline(tracks: [Track], tempoBPM: Double, masterVolume: Double,
                       fromBeat: Double, durationSeconds: Double,
                       forcedCompensationTargets: [UUID: Int]?) async throws -> RenderedAudio {
        renderCalls.append(RenderCall(tracks: tracks, fromBeat: fromBeat,
                                      duration: durationSeconds, masterVolume: masterVolume))
        // A small silent stereo buffer — the store never reads the samples,
        // only the call args and the on-disk write matter.
        return RenderedAudio(sampleRate: 48_000, channelData: [[0, 0], [0, 0]])
    }

    func writeAudioFile(_ audio: RenderedAudio, to url: URL) throws -> AudioFileInfo {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: url)  // "RIFF" — existence only
        written.append(url)
        return AudioFileInfo(
            durationSeconds: audio.sampleRate > 0 ? Double(audio.frameCount) / audio.sampleRate : 0,
            sampleRate: audio.sampleRate, channelCount: audio.channelData.count)
    }
}

// MARK: - Planner (pure)

@Suite("Clip fix — planner (M6 v-b)")
struct ClipFixPlannerTests {
    private func approx(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    // 1. window
    @Test("window: interior region applies both context pads")
    func windowInterior() {
        let w = ClipFixPlanner.window(regionStart: 40, regionEnd: 50, spanStart: 0, spanEnd: 100, contextBeats: 20)
        #expect(approx(w.start, 20) && approx(w.end, 70))
    }

    @Test("window: region at span start left-clamps")
    func windowLeftClamp() {
        let w = ClipFixPlanner.window(regionStart: 0, regionEnd: 10, spanStart: 0, spanEnd: 100, contextBeats: 20)
        #expect(approx(w.start, 0) && approx(w.end, 30))
    }

    @Test("window: region at span end right-clamps")
    func windowRightClamp() {
        let w = ClipFixPlanner.window(regionStart: 90, regionEnd: 100, spanStart: 0, spanEnd: 100, contextBeats: 20)
        #expect(approx(w.start, 70) && approx(w.end, 100))
    }

    @Test("window: region == span yields window == span")
    func windowEqualsSpan() {
        let w = ClipFixPlanner.window(regionStart: 0, regionEnd: 100, spanStart: 0, spanEnd: 100, contextBeats: 20)
        #expect(approx(w.start, 0) && approx(w.end, 100))
    }

    @Test("window: context larger than the clip clamps to the whole span")
    func windowContextLargerThanClip() {
        let w = ClipFixPlanner.window(regionStart: 40, regionEnd: 60, spanStart: 0, spanEnd: 100, contextBeats: 200)
        #expect(approx(w.start, 0) && approx(w.end, 100))
    }

    // 2. splice
    private let laneA = UUID()
    private let laneB = UUID()
    private let fix = UUID()

    @Test("splice: into a single full-range segment → 3 segments (orig | fix | orig)")
    func spliceFullRangeIntoThree() {
        let comp = [CompSegment(laneID: laneA, startBeat: 0, endBeat: 100)]
        let out = ClipFixPlanner.splice(comp, regionStart: 40, regionEnd: 50, laneID: fix)
        #expect(out.count == 3)
        #expect(out[0].laneID == laneA && approx(out[0].startBeat, 0) && approx(out[0].endBeat, 40))
        #expect(out[1].laneID == fix && approx(out[1].startBeat, 40) && approx(out[1].endBeat, 50))
        #expect(out[2].laneID == laneA && approx(out[2].startBeat, 50) && approx(out[2].endBeat, 100))
    }

    @Test("splice: at the segment start edge → 2 segments (fix | orig)")
    func spliceStartEdge() {
        let comp = [CompSegment(laneID: laneA, startBeat: 0, endBeat: 100)]
        let out = ClipFixPlanner.splice(comp, regionStart: 0, regionEnd: 20, laneID: fix)
        #expect(out.count == 2)
        #expect(out[0].laneID == fix && approx(out[0].endBeat, 20))
        #expect(out[1].laneID == laneA && approx(out[1].startBeat, 20))
    }

    @Test("splice: at the segment end edge → 2 segments (orig | fix)")
    func spliceEndEdge() {
        let comp = [CompSegment(laneID: laneA, startBeat: 0, endBeat: 100)]
        let out = ClipFixPlanner.splice(comp, regionStart: 80, regionEnd: 100, laneID: fix)
        #expect(out.count == 2)
        #expect(out[0].laneID == laneA && approx(out[0].endBeat, 80))
        #expect(out[1].laneID == fix && approx(out[1].startBeat, 80) && approx(out[1].endBeat, 100))
    }

    @Test("splice: region covering the whole comp → just the fix")
    func spliceCoversWhole() {
        let comp = [CompSegment(laneID: laneA, startBeat: 0, endBeat: 100)]
        let out = ClipFixPlanner.splice(comp, regionStart: 0, regionEnd: 100, laneID: fix)
        #expect(out.count == 1)
        #expect(out[0].laneID == fix)
    }

    @Test("splice: across two abutting segments trims both and inserts the fix")
    func spliceAcrossTwo() {
        let comp = [CompSegment(laneID: laneA, startBeat: 0, endBeat: 50),
                    CompSegment(laneID: laneB, startBeat: 50, endBeat: 100)]
        let out = ClipFixPlanner.splice(comp, regionStart: 40, regionEnd: 60, laneID: fix)
        #expect(out.count == 3)
        #expect(out[0].laneID == laneA && approx(out[0].startBeat, 0) && approx(out[0].endBeat, 40))
        #expect(out[1].laneID == fix && approx(out[1].startBeat, 40) && approx(out[1].endBeat, 60))
        #expect(out[2].laneID == laneB && approx(out[2].startBeat, 60) && approx(out[2].endBeat, 100))
    }

    @Test("splice: into an empty comp yields just the fix")
    func spliceIntoEmpty() {
        let out = ClipFixPlanner.splice([], regionStart: 10, regionEnd: 20, laneID: fix)
        #expect(out.count == 1 && out[0].laneID == fix)
    }

    @Test("splice: region beyond the comp keeps a legal gap + the new segment")
    func spliceBeyondCompLeavesGap() {
        let comp = [CompSegment(laneID: laneA, startBeat: 0, endBeat: 10)]
        let out = ClipFixPlanner.splice(comp, regionStart: 20, regionEnd: 30, laneID: fix)
        #expect(out.count == 2)
        #expect(out[0].laneID == laneA && approx(out[0].endBeat, 10))
        #expect(out[1].laneID == fix && approx(out[1].startBeat, 20))
    }

    @Test("splice: float-edge empty remainders are dropped")
    func spliceDropsEmpties() {
        let comp = [CompSegment(laneID: laneA, startBeat: 0, endBeat: 10)]
        // Region starts a sub-epsilon sliver past the segment start: the left
        // remainder is thinner than emptyBeats and must be dropped.
        let out = ClipFixPlanner.splice(comp, regionStart: 1e-12, regionEnd: 10, laneID: fix)
        #expect(out.count == 1 && out[0].laneID == fix)
    }
}

// MARK: - Store: submit + import

@MainActor
@Suite("Clip fix — store (M6 v-b)")
struct ClipFixStoreTests {
    private func approx(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }

    private func writeTinyWAV(name: String = "fix.wav") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-fix-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: url)  // "RIFF" — copyable, existence only
        return url
    }

    private func makeStore(source: FakeClipFixSource, engine: FakeRenderEngine,
                           tracks: [Track]) -> ProjectStore {
        let store = ProjectStore(tracks: tracks)
        store.engine = engine
        store.generationSource = source
        store.generationImportsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-fix-dest-\(UUID().uuidString)")
        return store
    }

    private func audioClip(_ name: String, start: Double, length: Double,
                           file: String = "/src.wav", gainDb: Double = 0,
                           stretchRatio: Double = 1, fadeIn: Double = 0, fadeOut: Double = 0) -> Clip {
        Clip(name: name, startBeat: start, lengthBeats: length,
             audioFileURL: URL(fileURLWithPath: file),
             gainDb: gainDb, fadeInBeats: fadeIn, fadeOutBeats: fadeOut, stretchRatio: stretchRatio)
    }

    // MARK: Submit — 3

    @Test("submit plain clip: one dry synthetic-track bounce, fades zeroed, gain/stretch kept, D3 seconds, .clip pending, echo")
    func submitPlainClip() async throws {
        let clip = audioClip("Vox", start: 0, length: 100, gainDb: -3, stretchRatio: 1.5, fadeIn: 2, fadeOut: 2)
        let track = Track(name: "Vox", kind: .audio, clips: [clip])
        let source = FakeClipFixSource()
        let engine = FakeRenderEngine()
        let store = makeStore(source: source, engine: engine, tracks: [track])

        let submission = try await store.fixClipRegion(
            trackId: track.id, clipId: clip.id, startBeat: 40, endBeat: 50, contextSeconds: 10)

        // Exactly one dry synthetic-track render.
        #expect(engine.renderCalls.count == 1)
        let call = engine.renderCalls[0]
        #expect(call.tracks.count == 1)
        let synth = call.tracks[0]
        #expect(synth.volume == 1 && synth.pan == 0)
        #expect(synth.effects.isEmpty && synth.sends.isEmpty && synth.automation.isEmpty)
        #expect(synth.outputBusID == nil)
        #expect(synth.clips.count == 1)
        let bounced = synth.clips[0]
        // Fades STRIPPED (post-grouping equivalence), gain + stretch PRESERVED.
        #expect(bounced.fadeInBeats == 0 && bounced.fadeOutBeats == 0)
        #expect(bounced.gainDb == -3)
        #expect(bounced.stretchRatio == 1.5)
        // Window [20,70]; from the window start, exact seconds, NO +2 s tail.
        #expect(approx(call.fromBeat, 20))
        #expect(approx(call.duration, 25))   // (70-20) beats * 60/120
        #expect(call.masterVolume == 1)

        // ClipRepaintRequest seconds (D3): (40-20)/2 = 10, (50-20)/2 = 15.
        let request = try #require(await source.lastRepaintRequest)
        #expect(request.sourceAudioPath == submission.bouncePath)
        #expect(approx(request.startSeconds, 10))
        #expect(approx(request.endSeconds, 15))

        // Pending registered with a .clip target.
        let pending = try #require(store.pendingClipFixes[submission.jobID])
        if case .clip(let id, _) = pending.target { #expect(id == clip.id) }
        else { Issue.record("expected a .clip pending target") }

        // Echo fields.
        #expect(submission.jobID == "fix-job-1")
        #expect(submission.state == "queued")
        #expect(submission.queuePosition == 3)
        #expect(approx(submission.windowStartBeat, 20) && approx(submission.windowEndBeat, 70))
        #expect(approx(submission.regionStartBeat, 40) && approx(submission.regionEndBeat, 50))
        #expect(approx(submission.repaintStartSeconds, 10) && approx(submission.repaintEndSeconds, 15))
        #expect(submission.bouncePath.contains("fix-bounce"))
        #expect(FileManager.default.fileExists(atPath: submission.bouncePath))
    }

    // MARK: Submit — 4

    @Test("submit stretched clip: bounce duration + request seconds are ratio-independent (timeline seconds)")
    func submitStretchRatioIndependent() async throws {
        func run(ratio: Double) async throws -> (duration: Double, start: Double, end: Double) {
            let clip = audioClip("V", start: 0, length: 100, stretchRatio: ratio)
            let track = Track(name: "V", kind: .audio, clips: [clip])
            let source = FakeClipFixSource()
            let engine = FakeRenderEngine()
            let store = makeStore(source: source, engine: engine, tracks: [track])
            _ = try await store.fixClipRegion(trackId: track.id, clipId: clip.id, startBeat: 40, endBeat: 50)
            let req = try #require(await source.lastRepaintRequest)
            return (engine.renderCalls[0].duration, req.startSeconds, req.endSeconds)
        }
        let a = try await run(ratio: 1.0)
        let b = try await run(ratio: 2.5)
        #expect(approx(a.duration, b.duration))
        #expect(approx(a.start, b.start) && approx(a.end, b.end))
    }

    // MARK: Submit — 5

    @Test("submit member target: synthetic track holds ALL group members, span clamps to group range, .group pending")
    func submitMemberTarget() async throws {
        let a = audioClip("A", start: 0, length: 8, file: "/a.wav")
        let b = audioClip("B", start: 0, length: 8, file: "/b.wav")
        let track = Track(name: "Vox", kind: .audio, clips: [a, b])
        let source = FakeClipFixSource()
        let engine = FakeRenderEngine()
        let store = makeStore(source: source, engine: engine, tracks: [track])

        let group = try store.groupTakes(trackId: track.id, clipIds: [a.id, b.id])
        // Two comp segments → two materialized members.
        _ = try store.setCompSegments(trackId: track.id, groupId: group.id, segments: [
            CompSegment(laneID: group.lanes[0].id, startBeat: 0, endBeat: 4),
            CompSegment(laneID: group.lanes[1].id, startBeat: 4, endBeat: 8),
        ])
        let memberID = try #require(store.tracks[0].clips.first?.id)

        let submission = try await store.fixClipRegion(
            trackId: track.id, clipId: memberID, startBeat: 1, endBeat: 3)

        let expectedMemberCount = store.tracks[0].clips.filter { $0.takeGroupID == group.id }.count
        #expect(engine.renderCalls.count == 1)
        #expect(engine.renderCalls[0].tracks[0].clips.count == expectedMemberCount)
        #expect(expectedMemberCount == 2)
        // Span clamps to the group range [0,8] → window == full range.
        #expect(approx(submission.windowStartBeat, 0) && approx(submission.windowEndBeat, 8))

        let pending = try #require(store.pendingClipFixes[submission.jobID])
        if case .group(let id, let s, let e) = pending.target {
            #expect(id == group.id && approx(s, 0) && approx(e, 8))
        } else { Issue.record("expected a .group pending target") }
    }

    // MARK: Submit — 6 (rejections; no bounce for early guards)

    @Test("submit rejects a MIDI clip with clipFixRequiresAudioClip and never bounces")
    func rejectMIDI() async throws {
        let midi = Clip(name: "M", startBeat: 0, lengthBeats: 8, notes: [])
        let track = Track(name: "Inst", kind: .instrument, clips: [midi])
        let source = FakeClipFixSource()
        let engine = FakeRenderEngine()
        let store = makeStore(source: source, engine: engine, tracks: [track])
        await #expect(throws: ProjectError.self) {
            _ = try await store.fixClipRegion(trackId: track.id, clipId: midi.id, startBeat: 1, endBeat: 4)
        }
        #expect(engine.renderCalls.isEmpty)
    }

    @Test("submit rejects region outside span / end<=start / <0.1s with invalidClipEdit and never bounces")
    func rejectBadRegions() async throws {
        let clip = audioClip("V", start: 0, length: 100)
        let track = Track(name: "V", kind: .audio, clips: [clip])
        let source = FakeClipFixSource()
        let engine = FakeRenderEngine()
        let store = makeStore(source: source, engine: engine, tracks: [track])

        // Outside span.
        await #expect(throws: ProjectError.self) {
            _ = try await store.fixClipRegion(trackId: track.id, clipId: clip.id, startBeat: 40, endBeat: 200)
        }
        // end <= start.
        await #expect(throws: ProjectError.self) {
            _ = try await store.fixClipRegion(trackId: track.id, clipId: clip.id, startBeat: 50, endBeat: 40)
        }
        // < 0.1 s (0.05 beats at 120 bpm = 0.025 s).
        await #expect(throws: ProjectError.self) {
            _ = try await store.fixClipRegion(trackId: track.id, clipId: clip.id, startBeat: 40, endBeat: 40.05)
        }
        #expect(engine.renderCalls.isEmpty)
    }

    @Test("submit rejects unknown track/clip, nil engine, nil generationSource")
    func rejectMissingPlumbing() async throws {
        let clip = audioClip("V", start: 0, length: 100)
        let track = Track(name: "V", kind: .audio, clips: [clip])

        // Unknown track / clip.
        let s1 = makeStore(source: FakeClipFixSource(), engine: FakeRenderEngine(), tracks: [track])
        await #expect(throws: ProjectError.self) {
            _ = try await s1.fixClipRegion(trackId: UUID(), clipId: clip.id, startBeat: 1, endBeat: 4)
        }
        await #expect(throws: ProjectError.self) {
            _ = try await s1.fixClipRegion(trackId: track.id, clipId: UUID(), startBeat: 1, endBeat: 4)
        }

        // Engine nil (generationSource present → engineUnavailable).
        let engine2 = FakeRenderEngine()
        let s2 = makeStore(source: FakeClipFixSource(), engine: engine2, tracks: [track])
        s2.engine = nil
        await #expect(throws: ProjectError.self) {
            _ = try await s2.fixClipRegion(trackId: track.id, clipId: clip.id, startBeat: 1, endBeat: 4)
        }

        // generationSource nil → generationSourceUnavailable, no bounce.
        let engine3 = FakeRenderEngine()
        let s3 = ProjectStore(tracks: [track])
        s3.engine = engine3
        await #expect(throws: ProjectError.self) {
            _ = try await s3.fixClipRegion(trackId: track.id, clipId: clip.id, startBeat: 1, endBeat: 4)
        }
        #expect(engine3.renderCalls.isEmpty)
    }

    // MARK: Import — 7

    @Test("import plain clip: group with original + AI Fix 1 lane, comp splice, 3 members, one-step undo/redo")
    func importPlainClipHappyPath() async throws {
        let wav = try writeTinyWAV()
        let clip = audioClip("Vox", start: 0, length: 100)
        let track = Track(name: "Vox", kind: .audio, clips: [clip])
        let source = FakeClipFixSource()
        let engine = FakeRenderEngine()
        let store = makeStore(source: source, engine: engine, tracks: [track])

        let submission = try await store.fixClipRegion(
            trackId: track.id, clipId: clip.id, startBeat: 40, endBeat: 50, contextSeconds: 10)
        await source.setFetchResult(.success(GeneratedSongResult(state: "succeeded", audioPath: wav.path)))

        let result = try await store.importClipFix(jobID: submission.jobID)
        #expect(result.laneName == "AI Fix 1")

        let group = try #require(store.tracks[0].takeGroups.first { $0.id == result.groupID })
        #expect(group.lanes.count == 2)
        // Lane 0 == original: id + geometry preserved, no nested takeGroupID.
        #expect(group.lanes[0].clip.id == clip.id)
        #expect(approx(group.lanes[0].clip.startBeat, 0) && approx(group.lanes[0].clip.lengthBeats, 100))
        #expect(group.lanes[0].clip.takeGroupID == nil)
        // Lane 1 == AI Fix 1: violet, ratio 1 / offset 0 / gain 0, at the window.
        let fixLane = try #require(group.lanes.first { $0.id == result.laneID })
        #expect(fixLane.name == "AI Fix 1")
        #expect(fixLane.clip.isAIGenerated)
        #expect(fixLane.clip.stretchRatio == 1 && fixLane.clip.startOffsetSeconds == 0 && fixLane.clip.gainDb == 0)
        #expect(approx(fixLane.clip.startBeat, 20) && approx(fixLane.clip.lengthBeats, 50))
        // Comp == [orig 0-40 | fix 40-50 | orig 50-100] (lane ids, not clip ids).
        let originalLaneID = group.lanes[0].id
        #expect(group.comp.count == 3)
        #expect(group.comp[0].laneID == originalLaneID)
        #expect(approx(group.comp[0].startBeat, 0) && approx(group.comp[0].endBeat, 40))
        #expect(group.comp[1].laneID == fixLane.id)
        #expect(approx(group.comp[1].startBeat, 40) && approx(group.comp[1].endBeat, 50))
        #expect(group.comp[2].laneID == originalLaneID)
        // Members rebuilt (3), the fix member violet.
        let members = store.tracks[0].clips.filter { $0.takeGroupID == group.id }
        #expect(members.count == 3)
        #expect(members.contains { $0.isAIGenerated })
        // Pending consumed on success.
        #expect(store.pendingClipFixes[submission.jobID] == nil)

        // One undo restores the plain clip; redo restores the group.
        #expect(try store.undo() == "AI Fix Take")
        #expect(store.tracks[0].takeGroups.isEmpty)
        #expect(store.tracks[0].clips.count == 1 && store.tracks[0].clips[0].id == clip.id)
        _ = try store.redo()
        #expect(store.tracks[0].takeGroups.count == 1)
    }

    // MARK: Import — 8

    @Test("import member target: fix lane appended, comp outside the region untouched, existing lanes intact")
    func importMemberTarget() async throws {
        let wav = try writeTinyWAV()
        let a = audioClip("A", start: 0, length: 8, file: "/a.wav")
        let b = audioClip("B", start: 0, length: 8, file: "/b.wav")
        let track = Track(name: "Vox", kind: .audio, clips: [a, b])
        let source = FakeClipFixSource()
        let engine = FakeRenderEngine()
        let store = makeStore(source: source, engine: engine, tracks: [track])

        let group = try store.groupTakes(trackId: track.id, clipIds: [a.id, b.id])
        _ = try store.setCompSegments(trackId: track.id, groupId: group.id, segments: [
            CompSegment(laneID: group.lanes[0].id, startBeat: 0, endBeat: 4),
            CompSegment(laneID: group.lanes[1].id, startBeat: 4, endBeat: 8),
        ])
        let memberID = try #require(store.tracks[0].clips.first?.id)

        let submission = try await store.fixClipRegion(
            trackId: track.id, clipId: memberID, startBeat: 1, endBeat: 3)
        await source.setFetchResult(.success(GeneratedSongResult(state: "succeeded", audioPath: wav.path)))

        let result = try await store.importClipFix(jobID: submission.jobID)
        let after = try #require(store.tracks[0].takeGroups.first { $0.id == group.id })
        #expect(after.id == result.groupID)          // same group, appended
        #expect(after.lanes.count == 3)              // A, B, AI Fix 1
        // The far-side segment (lane B over the back half) is still there.
        #expect(after.comp.contains { $0.laneID == group.lanes[1].id && approx($0.endBeat, 8) })
        // The fix segment replaced [1,3].
        #expect(after.comp.contains { $0.laneID == result.laneID
            && approx($0.startBeat, 1) && approx($0.endBeat, 3) })
    }

    // MARK: Import — 9

    @Test("two pending fixes on the same plain clip land as AI Fix 1 + AI Fix 2 in ONE group")
    func twoFixesSameClip() async throws {
        let wav = try writeTinyWAV()
        let clip = audioClip("Vox", start: 0, length: 100)
        let track = Track(name: "Vox", kind: .audio, clips: [clip])
        let source = FakeClipFixSource()
        let engine = FakeRenderEngine()
        let store = makeStore(source: source, engine: engine, tracks: [track])

        // Both submitted while the plain clip is still plain.
        let sub1 = try await store.fixClipRegion(trackId: track.id, clipId: clip.id, startBeat: 10, endBeat: 20)
        let sub2 = try await store.fixClipRegion(trackId: track.id, clipId: clip.id, startBeat: 60, endBeat: 70)
        #expect(sub1.jobID != sub2.jobID)
        await source.setFetchResult(.success(GeneratedSongResult(state: "succeeded", audioPath: wav.path)))

        let r1 = try await store.importClipFix(jobID: sub1.jobID)
        let r2 = try await store.importClipFix(jobID: sub2.jobID)
        #expect(r1.groupID == r2.groupID)            // one group
        #expect(r1.laneName == "AI Fix 1" && r2.laneName == "AI Fix 2")
        let group = try #require(store.tracks[0].takeGroups.first { $0.id == r1.groupID })
        #expect(group.lanes.count == 3)              // original + 2 fixes
        // Second splice wins inside its region.
        #expect(group.comp.contains { $0.laneID == r2.laneID
            && approx($0.startBeat, 60) && approx($0.endBeat, 70) })
    }

    // MARK: Import — 10

    @Test("comp edited between submit and import (group target) still lands — group anchor")
    func compEditedMidJob() async throws {
        let wav = try writeTinyWAV()
        let a = audioClip("A", start: 0, length: 8, file: "/a.wav")
        let b = audioClip("B", start: 0, length: 8, file: "/b.wav")
        let track = Track(name: "Vox", kind: .audio, clips: [a, b])
        let source = FakeClipFixSource()
        let engine = FakeRenderEngine()
        let store = makeStore(source: source, engine: engine, tracks: [track])

        let group = try store.groupTakes(trackId: track.id, clipIds: [a.id, b.id])
        let memberID = try #require(store.tracks[0].clips.first?.id)
        let submission = try await store.fixClipRegion(trackId: track.id, clipId: memberID, startBeat: 1, endBeat: 3)

        // Rebuild members (fresh UUIDs) via a comp edit while the job runs.
        _ = try store.selectTake(trackId: track.id, groupId: group.id, laneId: group.lanes[0].id)
        await source.setFetchResult(.success(GeneratedSongResult(state: "succeeded", audioPath: wav.path)))

        let result = try await store.importClipFix(jobID: submission.jobID)
        #expect(result.groupID == group.id)
        #expect(store.tracks[0].takeGroups.first { $0.id == group.id }?.lanes.count == 3)
    }

    // MARK: Import — 11 (move rebase + stale matrix)

    @Test("move rebase: a +4-beat clip move shifts the landed take + comp splice by +4")
    func moveRebase() async throws {
        let wav = try writeTinyWAV()
        let clip = audioClip("Vox", start: 0, length: 100)
        let track = Track(name: "Vox", kind: .audio, clips: [clip])
        let source = FakeClipFixSource()
        let engine = FakeRenderEngine()
        let store = makeStore(source: source, engine: engine, tracks: [track])

        let submission = try await store.fixClipRegion(trackId: track.id, clipId: clip.id, startBeat: 40, endBeat: 50)
        _ = try store.moveClip(trackId: track.id, clipId: clip.id, toStartBeat: 4)  // +4 beats
        await source.setFetchResult(.success(GeneratedSongResult(state: "succeeded", audioPath: wav.path)))

        let result = try await store.importClipFix(jobID: submission.jobID)
        let group = try #require(store.tracks[0].takeGroups.first { $0.id == result.groupID })
        let fixLane = try #require(group.lanes.first { $0.id == result.laneID })
        #expect(approx(fixLane.clip.startBeat, 24))   // windowStart 20 + 4
        #expect(group.comp.contains { $0.laneID == result.laneID
            && approx($0.startBeat, 44) && approx($0.endBeat, 54) })
    }

    @Test("stale matrix: trim/re-stretch/re-gain/tempo/deleted target all reject with clipFixStale")
    func staleMatrix() async throws {
        let wav = try writeTinyWAV()
        func submittedStore() async throws -> (ProjectStore, FakeClipFixSource, Clip, Track, String) {
            let clip = audioClip("Vox", start: 0, length: 100)
            let track = Track(name: "Vox", kind: .audio, clips: [clip])
            let source = FakeClipFixSource()
            let engine = FakeRenderEngine()
            let store = makeStore(source: source, engine: engine, tracks: [track])
            let sub = try await store.fixClipRegion(trackId: track.id, clipId: clip.id, startBeat: 40, endBeat: 50)
            withExtendedLifetime(engine) {}  // engine is weak on the store — pin it through the submit
            await source.setFetchResult(.success(GeneratedSongResult(state: "succeeded", audioPath: wav.path)))
            return (store, source, clip, track, sub.jobID)
        }
        func expectStale(_ store: ProjectStore, _ jobID: String) async {
            await #expect(throws: ProjectError.self) { _ = try await store.importClipFix(jobID: jobID) }
        }

        // Trim (length change).
        var (store, _, _, _, jobID) = try await submittedStore()
        store.tracks[0].clips[0].lengthBeats = 80
        await expectStale(store, jobID)

        // Re-stretch.
        (store, _, _, _, jobID) = try await submittedStore()
        store.tracks[0].clips[0].stretchRatio = 1.5
        await expectStale(store, jobID)

        // Re-gain.
        (store, _, _, _, jobID) = try await submittedStore()
        store.tracks[0].clips[0].gainDb = -6
        await expectStale(store, jobID)

        // Tempo change.
        (store, _, _, _, jobID) = try await submittedStore()
        try store.setTempo(140)
        await expectStale(store, jobID)

        // Deleted target.
        (store, _, _, _, jobID) = try await submittedStore()
        store.tracks[0].clips.removeAll()
        await expectStale(store, jobID)
    }

    @Test("stale: a shrunk group range (non-uniform) rejects with clipFixStale")
    func staleShrunkGroupRange() async throws {
        let wav = try writeTinyWAV()
        let a = audioClip("A", start: 0, length: 8, file: "/a.wav")
        let b = audioClip("B", start: 0, length: 6, file: "/b.wav")
        let track = Track(name: "Vox", kind: .audio, clips: [a, b])
        let source = FakeClipFixSource()
        let engine = FakeRenderEngine()
        let store = makeStore(source: source, engine: engine, tracks: [track])

        let group = try store.groupTakes(trackId: track.id, clipIds: [a.id, b.id])
        let memberID = try #require(store.tracks[0].clips.first?.id)
        let submission = try await store.fixClipRegion(trackId: track.id, clipId: memberID, startBeat: 1, endBeat: 3)
        withExtendedLifetime(engine) {}  // engine is weak on the store — pin it through the submit
        await source.setFetchResult(.success(GeneratedSongResult(state: "succeeded", audioPath: wav.path)))

        // Shorten lane A (the upper bound) → group range length changes.
        let gi = try #require(store.tracks[0].takeGroups.firstIndex { $0.id == group.id })
        let li = try #require(store.tracks[0].takeGroups[gi].lanes.firstIndex { $0.clip.audioFileURL?.lastPathComponent == "a.wav" })
        store.tracks[0].takeGroups[gi].lanes[li].clip.lengthBeats = 4
        await #expect(throws: ProjectError.self) {
            _ = try await store.importClipFix(jobID: submission.jobID)
        }
    }

    // MARK: Import — 12 (job-state errors + registry lifecycle)

    @Test("import job-state errors: unknown job / still-running / missing file; pending survives failure, dies on new")
    func jobStateErrorsAndLifecycle() async throws {
        let wav = try writeTinyWAV()
        let clip = audioClip("Vox", start: 0, length: 100)
        let track = Track(name: "Vox", kind: .audio, clips: [clip])
        let source = FakeClipFixSource()
        let engine = FakeRenderEngine()
        let store = makeStore(source: source, engine: engine, tracks: [track])

        // Unknown job → clipFixJobNotFound (nothing pending).
        await #expect(throws: ProjectError.self) { _ = try await store.importClipFix(jobID: "nope") }

        let submission = try await store.fixClipRegion(trackId: track.id, clipId: clip.id, startBeat: 40, endBeat: 50)

        // Still-running fetch → generationNotReady; pending SURVIVES (retryable).
        await source.setFetchResult(.success(GeneratedSongResult(state: "running", audioPath: nil)))
        await #expect(throws: ProjectError.self) { _ = try await store.importClipFix(jobID: submission.jobID) }
        #expect(store.pendingClipFixes[submission.jobID] != nil)

        // Missing file → generationAudioMissing; pending still SURVIVES.
        await source.setFetchResult(.success(GeneratedSongResult(
            state: "succeeded", audioPath: "/tmp/gone-\(UUID().uuidString).wav")))
        await #expect(throws: ProjectError.self) { _ = try await store.importClipFix(jobID: submission.jobID) }
        #expect(store.pendingClipFixes[submission.jobID] != nil)

        // Success consumes the pending record.
        await source.setFetchResult(.success(GeneratedSongResult(state: "succeeded", audioPath: wav.path)))
        _ = try await store.importClipFix(jobID: submission.jobID)
        #expect(store.pendingClipFixes[submission.jobID] == nil)

        // project.new clears the registry. (The first import consumed the plain
        // clip into a group, so submit against a current materialized member.)
        let memberID = try #require(store.tracks[0].clips.first { $0.takeGroupID != nil }?.id)
        let submission2 = try await store.fixClipRegion(trackId: track.id, clipId: memberID, startBeat: 10, endBeat: 20)
        #expect(store.pendingClipFixes[submission2.jobID] != nil)
        try store.newProject(discardChanges: true)
        #expect(store.pendingClipFixes.isEmpty)
        withExtendedLifetime(engine) {}  // engine is weak on the store — pin it through both submits
    }
}
