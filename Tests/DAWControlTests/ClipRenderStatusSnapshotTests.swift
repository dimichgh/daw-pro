import Foundation
import Testing
@testable import DAWCore  // `tracks` is internal(set): the fixture writes pitchEdits/stretchRatio directly
@testable import DAWControl

/// m23-ap-p2 **p2-snapshot**: `project.snapshot`'s transient per-clip render
/// fields (`stretchRendering` / `stretchError`) must reach the wire for EVERY
/// clip the engine renders through the stretch cache — a TUNED clip with no
/// time-stretch included. The gate used to ask `!clip.isStretchIdentity`
/// while the engine renders on `!isStretchIdentity || hasPitchEdits`, so a
/// pitch-only clip's render state, a FAILED render included, never left the
/// app. Both sides now ask `Clip.rendersThroughStretchCache`.
///
/// p2-ren **Stage B′** (`docs/design/2026-09-25-incremental-note-render.md`
/// §11 step 14) adds `renderAudible` (exact | preview | previous | silent) to
/// the same clips, from `store.renderAudible` (which forwards to
/// `AudioEngineControlling.renderAudible`, derived on the real engine from
/// `graph.clipPlays`). It says what the clip's node is ACTUALLY PLAYING right
/// now — a Stage B provisional, a Stage A bridge, honest silence, or the
/// clip's own exact render — distinct from `stretchRendering`, which is only
/// about the FINAL render job's own status and can be true at the same time
/// as any of the four.
///
/// The stub answers the SAME status for every clip it is asked about, so the
/// snapshot's gate — not the stub — decides which clips carry a field. The
/// invariance controls (an untouched clip, a clip whose note table is
/// detected but unedited) prove the gate still EXCLUDES clips that never
/// render; without them, deleting the gate outright would pass. Reuses
/// `FakeMedia` from ControlTests.swift (same target).
@MainActor
@Suite("Clip render status on project.snapshot — tuned clips (m23-ap-p2 p2-snapshot)")
struct ClipRenderStatusSnapshotTests {

    /// `EngineNoticeCommandTests.NoticeStubEngine`'s shape plus a
    /// configurable pull-based render status that records who asked.
    final class RenderStatusStubEngine: AudioEngineControlling {
        var isRunning = false
        var meteringHandler: ((MeterFrame) -> Void)?
        var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
        var playheadHandler: ((Double) -> Void)?
        var engineNoticeHandler: ((EngineNoticeEvent) -> Void)?

        /// What every `clipStretchStatus` query answers.
        var status: ClipStretchStatus = .rendering
        /// Every clip id the snapshot asked about, in order.
        private(set) var queried: [UUID] = []

        func clipStretchStatus(trackID: UUID, clipID: UUID) -> ClipStretchStatus? {
            queried.append(clipID)
            return status
        }

        /// p2-ren Stage B′: what every `renderAudible` query answers, nil
        /// meaning "this engine has no opinion" (the snapshot then omits the
        /// field, exactly like `.idle`/nil above).
        var audible: ClipRenderAudible? = .preview
        /// Every clip id `renderAudible` was asked about, in order.
        private(set) var audibleQueried: [UUID] = []

        func renderAudible(trackID: UUID, clipID: UUID) -> ClipRenderAudible? {
            audibleQueried.append(clipID)
            return audible
        }

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
            AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000, channelCount: 2)
        }
        var recordPermission: RecordPermission = .granted
        func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {
            completion(true)
        }
        func setInputDevice(uid: String?) throws {}
        func availableInputDevices() -> [AudioInputDevice] { [] }
        func startRecording(_ transport: TransportState, to url: URL,
                            completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {}
        func stopRecording() {}
    }

    private struct Fixture {
        let router: CommandRouter
        let store: ProjectStore
        let engine: RenderStatusStubEngine
        let trackID: UUID
        /// Pitch edits that bend the curve, no stretch — the p2-snapshot case.
        let tuned: UUID
        /// No edits, no stretch — never renders.
        let untouched: UUID
        /// A detected note table with NO edit on it — renders as nothing.
        let detectedOnly: UUID
        /// A plain time-stretch — the case the old gate already covered.
        let stretched: UUID
    }

    private static func note(cents: Double) -> NoteSegment {
        NoteSegment(startSeconds: 0.1, endSeconds: 0.6, detectedHz: 220,
                    detectedConfidence: 0.9, pitchOffsetCents: cents)
    }

    /// One audio track, four clips side by side (FakeMedia: 2 s = 4 beats at
    /// 120 BPM; 8 beats apart so `clip.addAudio`'s overlap refusal never
    /// bites), each then given its identity-relevant fields directly.
    private func makeFixture() async throws -> Fixture {
        let store = ProjectStore()
        store.media = FakeMedia()
        let engine = RenderStatusStubEngine()
        store.engine = engine
        let router = CommandRouter(store: store)

        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("audio")]))
        let trackID = try #require(UUID(uuidString: addTrack.result?["id"]?.stringValue ?? ""))
        var clipIDs: [UUID] = []
        for (i, name) in ["Tuned", "Untouched", "Detected", "Stretched"].enumerated() {
            let addClip = await router.handle(ControlRequest(
                id: "c\(i)", command: "clip.addAudio",
                params: ["trackId": .string(trackID.uuidString),
                         "path": .string("/tmp/\(name).wav"),
                         "atBeat": .number(Double(i * 8))]))
            #expect(addClip.ok, "clip.addAudio \(name): \(String(describing: addClip.error))")
            clipIDs.append(try #require(UUID(uuidString: addClip.result?["id"]?.stringValue ?? "")))
        }
        let t = try #require(store.tracks.firstIndex { $0.id == trackID })
        func index(_ id: UUID) throws -> Int {
            try #require(store.tracks[t].clips.firstIndex { $0.id == id })
        }
        store.tracks[t].clips[try index(clipIDs[0])].pitchEdits =
            PitchEditSet(segments: [Self.note(cents: 25)])
        store.tracks[t].clips[try index(clipIDs[2])].pitchEdits =
            PitchEditSet(segments: [Self.note(cents: 0)])
        store.tracks[t].clips[try index(clipIDs[3])].stretchRatio = 1.5

        // Fixture premises, asserted rather than assumed.
        let clips = store.tracks[t].clips
        let tuned = try #require(clips.first { $0.id == clipIDs[0] })
        #expect(tuned.hasPitchEdits && tuned.isStretchIdentity, "tuned = pitch-only")
        let detected = try #require(clips.first { $0.id == clipIDs[2] })
        #expect(detected.pitchEdits != nil && !detected.hasPitchEdits, "detected-only renders nothing")
        let stretched = try #require(clips.first { $0.id == clipIDs[3] })
        #expect(!stretched.isStretchIdentity && !stretched.hasPitchEdits, "stretched = stretch-only")

        return Fixture(router: router, store: store, engine: engine, trackID: trackID,
                       tuned: clipIDs[0], untouched: clipIDs[1],
                       detectedOnly: clipIDs[2], stretched: clipIDs[3])
    }

    /// The snapshot's clip objects on the fixture track, keyed by clip id.
    private func snapshotClips(_ f: Fixture) async throws -> [UUID: JSONValue] {
        let response = await f.router.handle(ControlRequest(id: "s", command: "project.snapshot"))
        #expect(response.ok)
        let tracks = try #require(response.result?["tracks"]?.arrayValue)
        let track = try #require(tracks.first { $0["id"]?.stringValue == f.trackID.uuidString })
        let clips = try #require(track["clips"]?.arrayValue)
        var byID: [UUID: JSONValue] = [:]
        for clip in clips {
            if let id = UUID(uuidString: clip["id"]?.stringValue ?? "") { byID[id] = clip }
        }
        #expect(byID.count == 4)
        return byID
    }

    @Test("project.snapshot reports stretchRendering:true for a TUNED clip whose render is pending (p2-snapshot)")
    func tunedClipRenderingReachesTheWire() async throws {
        let f = try await makeFixture()
        f.engine.status = .rendering
        let clips = try await snapshotClips(f)

        #expect(clips[f.tuned]?["stretchRendering"]?.boolValue == true,
                "a tuned clip renders through the stretch cache — its pending render must be visible")
        // Control: the case the old gate already covered still works.
        #expect(clips[f.stretched]?["stretchRendering"]?.boolValue == true)
        // Invariance: clips that never render are never queried and never
        // carry the field, even though the stub would say `.rendering`.
        #expect(clips[f.untouched]?["stretchRendering"] == nil)
        #expect(clips[f.detectedOnly]?["stretchRendering"] == nil)
        #expect(Set(f.engine.queried) == [f.tuned, f.stretched],
                "queried \(f.engine.queried.map(\.uuidString))")
        for id in [f.tuned, f.untouched, f.detectedOnly, f.stretched] {
            #expect(clips[id]?["stretchError"] == nil)
        }
    }

    @Test("project.snapshot reports stretchError for a TUNED clip whose render FAILED (p2-snapshot)")
    func tunedClipFailureReachesTheWire() async throws {
        let f = try await makeFixture()
        let reason = "the tuned render could not read its source file"
        f.engine.status = .failed(reason)
        let clips = try await snapshotClips(f)

        #expect(clips[f.tuned]?["stretchError"]?.stringValue == reason,
                "a FAILED tuned render leaves the clip silent — the wire must say why")
        #expect(clips[f.tuned]?["stretchRendering"] == nil)
        #expect(clips[f.stretched]?["stretchError"]?.stringValue == reason)
        #expect(clips[f.untouched]?["stretchError"] == nil)
        #expect(clips[f.detectedOnly]?["stretchError"] == nil)
        #expect(Set(f.engine.queried) == [f.tuned, f.stretched])
    }

    @Test("project.snapshot reports renderAudible: preview/previous/silent for a TUNED clip (p2-ren Stage B′)")
    func tunedClipRenderAudibleReachesTheWire() async throws {
        let f = try await makeFixture()

        for (audible, wire) in [(ClipRenderAudible.preview, "preview"),
                                 (.previous, "previous"),
                                 (.silent, "silent")] {
            f.engine.audible = audible
            let clips = try await snapshotClips(f)
            #expect(clips[f.tuned]?["renderAudible"]?.stringValue == wire,
                    "a tuned clip renders through the stretch cache — what it is actually playing must be visible (\(audible))")
            // Control: the case the old gate already covered still works.
            #expect(clips[f.stretched]?["renderAudible"]?.stringValue == wire)
            // Invariance: clips that never render are never queried and never
            // carry the field, even though the stub would answer for them too.
            #expect(clips[f.untouched]?["renderAudible"] == nil)
            #expect(clips[f.detectedOnly]?["renderAudible"] == nil)
        }
        #expect(Set(f.engine.audibleQueried) == [f.tuned, f.stretched],
                "queried \(f.engine.audibleQueried.map(\.uuidString))")
    }

    @Test("project.snapshot OMITS renderAudible when the clip plays exactly, or the engine has no opinion (p2-ren Stage B′)")
    func exactOrUnsupportedRenderAudibleOmitsTheField() async throws {
        let f = try await makeFixture()

        f.engine.audible = .exact
        var clips = try await snapshotClips(f)
        #expect(clips[f.tuned]?["renderAudible"] == nil,
                "`.exact` is the common case — it must not cost every poll a field agents would mostly ignore")
        #expect(clips[f.stretched]?["renderAudible"] == nil)

        f.engine.audible = nil
        clips = try await snapshotClips(f)
        #expect(clips[f.tuned]?["renderAudible"] == nil,
                "an engine with no opinion (headless, or one that predates this capability) must omit the field, never fabricate `.exact`")
    }
}
