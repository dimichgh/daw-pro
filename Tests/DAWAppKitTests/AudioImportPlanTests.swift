import Foundation
import Testing
import DAWCore
@testable import DAWAppKit

/// Headless coverage for the human audio-import routing/fan-out/naming/snap model
/// (beta m10-k) — the contract shared by the File→Import menu, the arrange
/// drag-drop, and `debug.importAudio`.
@Suite("AudioImportPlan")
struct AudioImportPlanTests {
    private let audioTrackID = UUID()

    /// m23-f: the plan no longer snaps — the landing beat arrives already
    /// resolved by `ArrangeDropSnap`, the one home the drop PREVIEW also uses.
    /// So these tests hand it an explicit beat and assert routing / fan-out /
    /// naming / rejection, which is all the plan still decides. The snap
    /// behaviour they used to cover moved WITH the behaviour, to
    /// `ArrangeDropSnapTests` — it was not dropped.
    ///
    /// Note the beat is built through `resolve` with snap OFF, so it passes
    /// through verbatim: these cases assert the beat the plan was GIVEN comes out
    /// unchanged, which would be a tautology if the helper re-snapped.
    private func context(target: UUID? = nil, kind: TrackKind? = nil,
                         atBeat: Double = 0) -> AudioImportContext {
        AudioImportContext(targetTrackID: target, targetTrackKind: kind,
                           startBeat: beat(atBeat))
    }

    private func beat(_ value: Double) -> ResolvedDropBeat {
        ArrangeDropSnap.resolve(rawBeat: value, snap: .off,
                                meterMap: MeterMap(constant: TimeSignature()),
                                pixelsPerBeat: 80)
    }

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

    // MARK: File-type gate

    @Test("audio extensions are recognized case-insensitively; others rejected")
    func audioTypeGate() {
        #expect(AudioImportPlan.isAudioFile(url("kick.wav")))
        #expect(AudioImportPlan.isAudioFile(url("Vocal.AIFF")))
        #expect(AudioImportPlan.isAudioFile(url("loop.mp3")))
        #expect(AudioImportPlan.isAudioFile(url("stem.flac")))
        #expect(!AudioImportPlan.isAudioFile(url("notes.txt")))
        #expect(!AudioImportPlan.isAudioFile(url("clip.mov")))
        #expect(!AudioImportPlan.isAudioFile(url("noext")))
    }

    // MARK: Single-file routing

    @Test("single file onto an existing audio track → clip on that track")
    func singleOntoAudioTrack() {
        let plan = AudioImportPlan(
            urls: [url("kick.wav")],
            context: context(target: audioTrackID, kind: .audio))
        #expect(plan.rejected.isEmpty)
        #expect(plan.actions.count == 1)
        guard case .existingTrack(let id, let beat, let u) = plan.actions[0] else {
            Issue.record("expected existingTrack, got \(plan.actions[0])"); return
        }
        #expect(id == audioTrackID)
        #expect(beat == 0)
        #expect(u == url("kick.wav"))
    }

    @Test("single file with no target → a new audio track")
    func singleNoTarget() {
        let plan = AudioImportPlan(urls: [url("Kick Loop.wav")], context: context())
        #expect(plan.actions.count == 1)
        guard case .newTrack(let name, _, _) = plan.actions[0] else {
            Issue.record("expected newTrack, got \(plan.actions[0])"); return
        }
        #expect(name == "Kick Loop")
    }

    @Test("single file onto a MIDI/instrument lane falls back to a new track")
    func singleOntoInstrumentFallsBack() {
        for kind in [TrackKind.instrument, .bus] {
            let plan = AudioImportPlan(
                urls: [url("vox.wav")],
                context: context(target: audioTrackID, kind: kind))
            #expect(plan.actions.count == 1)
            guard case .newTrack = plan.actions[0] else {
                Issue.record("kind \(kind): expected newTrack fallback, got \(plan.actions[0])"); return
            }
        }
    }

    // MARK: Multi-file fan-out (the stems case)

    @Test("multiple files → one new audio track per file, same start beat")
    func multiFanOut() {
        let plan = AudioImportPlan(
            urls: [url("drums.wav"), url("bass.aiff"), url("vox.mp3")],
            context: context(atBeat: 8))
        #expect(plan.actions.count == 3)
        let names = plan.actions.map { action -> String in
            guard case .newTrack(let name, _, _) = action else { return "?" }
            return name
        }
        #expect(names == ["drums", "bass", "vox"])
        // Every clip lands at the SAME (snapped) start beat.
        let beats = plan.actions.map { action -> Double in
            switch action {
            case .newTrack(_, let beat, _): return beat
            case .existingTrack(_, let beat, _): return beat
            }
        }
        #expect(beats == [8, 8, 8])
    }

    @Test("multiple files onto an audio track still fan out to new tracks")
    func multiOntoAudioTrackStillFansOut() {
        let plan = AudioImportPlan(
            urls: [url("a.wav"), url("b.wav")],
            context: context(target: audioTrackID, kind: .audio))
        #expect(plan.actions.count == 2)
        for action in plan.actions {
            guard case .newTrack = action else {
                Issue.record("expected fan-out to new tracks, got \(action)"); return
            }
        }
    }

    // MARK: Rejection reporting

    @Test("non-audio files are filtered out and reported, audio still planned")
    func mixedRejection() {
        let plan = AudioImportPlan(
            urls: [url("kick.wav"), url("notes.txt"), url("bass.flac"), url("clip.mov")],
            context: context())
        #expect(plan.actions.count == 2)  // kick + bass fan out
        #expect(plan.rejected.count == 2)
        #expect(plan.rejected.map(\.url) == [url("notes.txt"), url("clip.mov")])
        #expect(plan.rejected[0].reason.contains("notes.txt"))
        #expect(plan.rejected[0].reason.contains(".txt"))
    }

    @Test("all-non-audio → no actions, all reported")
    func allRejected() {
        let plan = AudioImportPlan(urls: [url("a.txt"), url("b.pdf")], context: context())
        #expect(plan.actions.isEmpty)
        #expect(plan.rejected.count == 2)
    }

    @Test("empty input → empty plan")
    func emptyInput() {
        let plan = AudioImportPlan(urls: [], context: context())
        #expect(plan.actions.isEmpty)
        #expect(plan.rejected.isEmpty)
    }

    // MARK: The resolved landing beat is USED VERBATIM (m23-f)

    @Test("the plan places the clip at exactly the beat it was handed")
    func landingBeatIsUsedVerbatim() {
        // 5.37 is deliberately OFF every grid the arrange offers. Before m23-f
        // the plan re-snapped its input, so a beat like this could not survive;
        // now the plan has no grid at all and must place it untouched.
        let plan = AudioImportPlan(urls: [url("a.wav")], context: context(atBeat: 5.37))
        guard case .newTrack(_, let beat, _) = plan.actions[0] else { Issue.record("shape"); return }
        #expect(beat == 5.37)
    }

    @Test("a magnetised landing beat survives into the action unchanged")
    func magnetisedBeatSurvives() {
        // The invariant m23-f exists for: the beat the drop LINE was drawn at is
        // the beat the clip lands on. A magnet target off the grid is the case
        // that would have been destroyed by a second snap downstream.
        let landing = ArrangeDropSnap.resolve(
            rawBeat: 7.45, snap: .bar,
            meterMap: MeterMap(constant: TimeSignature()),
            pixelsPerBeat: 80, clipEdgeBeats: [7.4])
        #expect(landing.beat == 7.4)
        #expect(landing.source == .magnetClipEdge)
        let plan = AudioImportPlan(
            urls: [url("a.wav")],
            context: AudioImportContext(targetTrackID: audioTrackID, targetTrackKind: .audio,
                                        startBeat: landing))
        guard case .existingTrack(_, let beat, _) = plan.actions[0] else { Issue.record("shape"); return }
        #expect(beat == 7.4, "a second snap downstream would have pulled this to 8")
    }

    @Test("negative landing beat clamps to zero")
    func negativeClamps() {
        let plan = AudioImportPlan(urls: [url("a.wav")], context: context(atBeat: -12))
        guard case .newTrack(_, let beat, _) = plan.actions[0] else { Issue.record("shape"); return }
        #expect(beat == 0)
    }

    // MARK: Naming

    @Test("track name is extension-stripped and whitespace-trimmed")
    func sanitizedNaming() {
        #expect(AudioImportPlan.sanitizedTrackName(from: url("Lead Vox.wav")) == "Lead Vox")
        #expect(AudioImportPlan.sanitizedTrackName(from: url("  spaced  .aiff")) == "spaced")
        #expect(AudioImportPlan.sanitizedTrackName(from: URL(fileURLWithPath: "/tmp/kick.loop.wav")) == "kick.loop")
    }

    @Test("a name that sanitizes to empty falls back")
    func emptyNameFallback() {
        // A whitespace-only base name strips to "" → the fallback.
        #expect(AudioImportPlan.sanitizedTrackName(from: URL(fileURLWithPath: "/tmp/   .wav")) == "Audio Track")
    }

    // MARK: Shared routing rule

    @Test("routesToExistingAudioTrack: only a single file onto an audio lane")
    func routingRule() {
        #expect(AudioImportPlan.routesToExistingAudioTrack(fileCount: 1, targetKind: .audio))
        #expect(!AudioImportPlan.routesToExistingAudioTrack(fileCount: 2, targetKind: .audio))
        #expect(!AudioImportPlan.routesToExistingAudioTrack(fileCount: 1, targetKind: .instrument))
        #expect(!AudioImportPlan.routesToExistingAudioTrack(fileCount: 1, targetKind: .bus))
        #expect(!AudioImportPlan.routesToExistingAudioTrack(fileCount: 1, targetKind: nil))
    }
}
