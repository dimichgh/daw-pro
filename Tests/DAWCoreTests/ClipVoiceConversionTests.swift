import Foundation
import Testing
@testable import DAWCore

/// Per-clip voice conversion (m24-m leg A / m24-o) at the DAWCore layer —
/// headless, engine-free-by-injection, AI-free by construction.
///
/// ⭐ **What these tests are actually for.** The m24-o defect was not a crash
/// or a missing feature: `voiceConversionSource` handed the converter a clip's
/// FULL BACKING RECORDING, so a trimmed take converted its whole untrimmed
/// source and landed it at the clip's beat — **silently wrong output that
/// looks like a valid answer**. A test that only checks "a track appeared"
/// would have passed on the defect. So the load-bearing assertions here are
/// SPY assertions on the render request the store hands the engine: WHICH
/// window it asks for, and WHICH clip geometry rides along. That is the only
/// place the fix exists.
///
/// The conversion itself is an injected closure (DAWCore never imports
/// AIServices), so nothing here needs a sidecar, a voice model, or a network.
/// Call counter usable from inside a `#expect(throws:)` closure (a captured
/// `var` cannot be mutated across the macro's closure boundary).
@MainActor
private final class Counter {
    var value = 0
}

/// ⚠️ `ProjectStore.engine` is **weak**. A test that lets its engine go out of
/// scope gets `engineUnavailable` from every call — and because that IS a
/// `ProjectError`, a `#expect(throws: ProjectError.self)` test would go GREEN
/// for entirely the wrong reason. Four tests here failed that way on the first
/// run and two more would have passed falsely, so liveness is not left to a
/// local binding: every engine this suite makes is pinned here for the
/// process.
@MainActor
private enum EngineKeepalive {
    static var engines: [FakeRenderEngine] = []
}

@MainActor
@Suite("Per-clip voice conversion (m24-m leg A / m24-o)")
struct ClipVoiceConversionTests {

    // MARK: - Fixtures

    /// A store with a hermetic media home, a deterministic media stand-in and
    /// the shared recording render engine. ⚠️ The engine is RETURNED and must
    /// be held by the caller: `ProjectStore.engine` is `weak`, so a temporary
    /// would deallocate and every call would throw `engineUnavailable`.
    private func makeStore(mediaDurationSeconds: Double = 2.0)
        -> (ProjectStore, FakeRenderEngine) {
        let store = ProjectStore()
        let engine = FakeRenderEngine()
        store.engine = engine
        store.media = FakeMedia(info: AudioFileInfo(
            durationSeconds: mediaDurationSeconds, sampleRate: 48_000, channelCount: 2))
        store.generationImportsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vc-clips-dest-\(UUID().uuidString)")
        try? store.setTempo(120)          // 1 beat = 0.5 s — every figure below
        EngineKeepalive.engines.append(engine)
        return (store, engine)
    }

    /// A stand-in for the converter's output file. The store only checks it
    /// EXISTS and asks `media` for its duration, so four bytes is honest.
    private func makeConverterOutput() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vc-clips-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("converted.wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: url)
        return url
    }

    private let sourceFile = URL(fileURLWithPath: "/tmp/vocal-take.wav")

    /// A track carrying `clips`, installed on the store.
    private func install(_ store: ProjectStore, _ clips: [Clip],
                         name: String = "Lead Vox") -> UUID {
        let track = Track(name: name, kind: .audio, clips: clips)
        store.tracks.append(track)
        return track.id
    }

    private func approx(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool {
        abs(a - b) < tol
    }

    // MARK: - extractClipAudioForConversion: THE m24-o DEFECT GATE

    @Test("extraction renders the CLIP's own window, not the whole backing file")
    func extractionWindowIsTheClipNotTheFile() async throws {
        let (store, engine) = makeStore()
        // A trimmed clip: it presents 4 beats (2 s at 120 bpm) starting 7.25 s
        // into a source recording that is minutes long. The defect converted
        // the whole recording; the fix converts these 2 s.
        let clip = Clip(name: "verse 2", startBeat: 16, lengthBeats: 4,
                        audioFileURL: sourceFile, startOffsetSeconds: 7.25)
        _ = install(store, [clip])

        let source = try await store.extractClipAudioForConversion(clipId: clip.id)

        #expect(engine.renderCalls.count == 1)
        let call = try #require(engine.renderCalls.first)
        // The window IS the clip's timeline span — start and length both.
        #expect(approx(call.fromBeat, 16))
        #expect(approx(call.duration, 2.0))          // 4 beats @ 120 bpm
        #expect(approx(source.seconds, 2.0))
        #expect(approx(source.startBeat, 16))
        #expect(approx(source.lengthBeats, 4))
        // ...and the clip handed to the renderer still carries the offset, so
        // the 2 s it renders are the RIGHT 2 s.
        let rendered = try #require(call.tracks.first?.clips.first)
        #expect(approx(rendered.startOffsetSeconds, 7.25))
        #expect(rendered.id == clip.id)              // WYSIWYG stretch-await key
        #expect(rendered.audioFileURL == sourceFile)
        #expect(call.tracks.count == 1)              // synthetic, single track
        #expect(approx(call.masterVolume, 1))
        // The extraction is transient scratch, NOT project media.
        #expect(source.url.path.contains("DAWPro"))
        #expect(FileManager.default.fileExists(atPath: source.url.path))
    }

    @Test("extraction bakes stretch and pitch, and asks for the TIMELINE duration")
    func extractionCarriesStretchAndPitch() async throws {
        let (store, engine) = makeStore()
        // stretchRatio 0.5 = half as long: 8 timeline beats consume 8 s of
        // source. The render window is the TIMELINE span (4 s), and the ratio
        // rides along so the renderer consumes the right source material.
        let clip = Clip(name: "chorus", startBeat: 0, lengthBeats: 8,
                        audioFileURL: sourceFile, startOffsetSeconds: 1,
                        stretchRatio: 0.5, pitchShiftSemitones: -3,
                        formantPreserve: true)
        _ = install(store, [clip])

        _ = try await store.extractClipAudioForConversion(clipId: clip.id)

        let call = try #require(engine.renderCalls.first)
        #expect(approx(call.duration, 4.0))          // 8 beats @ 120 bpm
        let rendered = try #require(call.tracks.first?.clips.first)
        #expect(approx(rendered.stretchRatio, 0.5))
        #expect(approx(rendered.pitchShiftSemitones, -3))
        #expect(rendered.formantPreserve)
        // Sanity on the model's own derivation, so the ratio is not decorative.
        #expect(approx(rendered.sourceWindowSeconds(tempoMap: store.transport.tempoMap), 8.0))
    }

    @Test("extraction STRIPS level shaping (fades, clip gain, envelope) but carries it out")
    func extractionStripsLevelShaping() async throws {
        let (store, engine) = makeStore()
        let clip = Clip(name: "bridge", startBeat: 4, lengthBeats: 4,
                        audioFileURL: sourceFile,
                        gainDb: -6, fadeInBeats: 1, fadeOutBeats: 2,
                        fadeInCurve: .equalPower, fadeOutCurve: .equalPower,
                        gainEnvelope: [ClipGainPoint(beat: 0, gainDb: -3),
                                       ClipGainPoint(beat: 2, gainDb: 0)])
        _ = install(store, [clip])

        let source = try await store.extractClipAudioForConversion(clipId: clip.id)

        // BAKED would hand the converter a fade-to-silence head and a −6 dB
        // signal; the f0 estimator gets neither.
        let rendered = try #require(engine.renderCalls.first?.tracks.first?.clips.first)
        #expect(approx(rendered.gainDb, 0))
        #expect(approx(rendered.fadeInBeats, 0))
        #expect(approx(rendered.fadeOutBeats, 0))
        #expect(rendered.fadeInCurve == .linear)
        #expect(rendered.fadeOutCurve == .linear)
        #expect(rendered.gainEnvelope.isEmpty)
        // ...but nothing is LOST: it is carried out for the landed clip.
        #expect(approx(source.gainDb, -6))
        #expect(approx(source.fadeInBeats, 1))
        #expect(approx(source.fadeOutBeats, 2))
        #expect(source.fadeInCurve == .equalPower)
        #expect(source.gainEnvelope.count == 2)
    }

    @Test("extraction renders DRY: no master chain, no master automation")
    func extractionIsDry() async throws {
        let (store, engine) = makeStore()
        let clip = Clip(name: "take", startBeat: 0, lengthBeats: 4, audioFileURL: sourceFile)
        _ = install(store, [clip])
        _ = try await store.extractClipAudioForConversion(clipId: clip.id)
        // The synthetic track is bare: unity volume/pan, no inserts or sends.
        let track = try #require(engine.renderCalls.first?.tracks.first)
        #expect(track.effects.isEmpty)
        #expect(track.sends.isEmpty)
        #expect(track.automation.isEmpty)
        #expect(approx(track.volume, 1))
        #expect(approx(track.pan, 0))
        #expect(!track.isMuted)
    }

    @Test("extraction drops takeGroupID — a comp member converts, the copy is not a member")
    func extractionDropsTakeGroupMembership() async throws {
        let (store, engine) = makeStore()
        var clip = Clip(name: "comped", startBeat: 0, lengthBeats: 4, audioFileURL: sourceFile)
        clip.takeGroupID = UUID()
        _ = install(store, [clip])

        // Converting a comp member is ALLOWED (read-only, the sliceToSampler
        // posture) — it must not be refused.
        let source = try await store.extractClipAudioForConversion(clipId: clip.id)
        #expect(approx(source.seconds, 2.0))
        let rendered = try #require(engine.renderCalls.first?.tracks.first?.clips.first)
        #expect(rendered.takeGroupID == nil)
    }

    @Test("extraction refuses a MIDI clip, an unknown id, and a headless store")
    func extractionRejections() async throws {
        let (store, engine) = makeStore()
        let midi = Clip(name: "notes", startBeat: 0, lengthBeats: 4, notes: [])
        let track = Track(name: "Synth", kind: .instrument, clips: [midi])
        store.tracks.append(track)

        await #expect(throws: ProjectError.self) {
            _ = try await store.extractClipAudioForConversion(clipId: midi.id)
        }
        await #expect(throws: ProjectError.self) {
            _ = try await store.extractClipAudioForConversion(clipId: UUID())
        }
        #expect(engine.renderCalls.isEmpty, "a rejection must never pay for a render")

        let headless = ProjectStore()
        let audio = Clip(name: "a", startBeat: 0, lengthBeats: 4, audioFileURL: sourceFile)
        headless.tracks.append(Track(name: "A", kind: .audio, clips: [audio]))
        await #expect(throws: ProjectError.self) {
            _ = try await headless.extractClipAudioForConversion(clipId: audio.id)
        }
    }

    // MARK: - convertClipsToVoice: the arrangement survives

    @Test("N selected clips → N clips at the SAME beats on ONE new violet track")
    func perClipConversionPreservesTheArrangement() async throws {
        let (store, engine) = makeStore()
        let a = Clip(name: "verse", startBeat: 0, lengthBeats: 4,
                     audioFileURL: sourceFile, startOffsetSeconds: 1)
        let b = Clip(name: "chorus", startBeat: 8, lengthBeats: 4,
                     audioFileURL: sourceFile, startOffsetSeconds: 12)
        let c = Clip(name: "outro", startBeat: 16, lengthBeats: 4, audioFileURL: sourceFile)
        let trackA = install(store, [a, b])
        let trackB = install(store, [c], name: "Double")
        let tracksBefore = store.tracks.count

        var seenIDs: [UUID] = []
        var seenWindows: [(Double, Double)] = []
        // Deliberately UNSORTED input — the set is a selection, not a sequence.
        let result = try await store.convertClipsToVoice(
            clipIds: [c.id, a.id, b.id], trackName: "Voice: ada"
        ) { id, source in
            seenIDs.append(id)
            seenWindows.append((source.startBeat, source.seconds))
            return try makeConverterOutput()
        }

        // Each clip converted SEPARATELY, in timeline order, over its own window.
        #expect(seenIDs == [a.id, b.id, c.id])
        #expect(seenWindows.map(\.0) == [0, 8, 16])
        #expect(seenWindows.allSatisfy { approx($0.1, 2.0) })
        #expect(engine.renderCalls.count == 3)

        // ONE new track, and only one.
        #expect(store.tracks.count == tracksBefore + 1)
        let landedTrack = try #require(store.tracks.last)
        #expect(landedTrack.id == result.trackId)
        #expect(landedTrack.name == "Voice: ada")
        #expect(landedTrack.kind == .audio)
        #expect(landedTrack.isAIGenerated)              // violet
        #expect(landedTrack.instrument == nil)          // a PLAIN audio track

        // The arrangement, clip for clip.
        #expect(landedTrack.clips.count == 3)
        #expect(landedTrack.clips.map(\.startBeat) == [0, 8, 16])
        #expect(landedTrack.clips.map(\.lengthBeats) == [4, 4, 4])
        #expect(landedTrack.clips.map(\.name) == ["verse", "chorus", "outro"])
        #expect(landedTrack.clips.allSatisfy { $0.isAIGenerated })
        #expect(landedTrack.clips.allSatisfy { $0.takeGroupID == nil })
        #expect(landedTrack.clips.allSatisfy { $0.audioFileURL != nil })
        // Every converted file lives in the STABLE media home, not the temp
        // scratch the extraction used (it must survive undo/redo and a save).
        #expect(landedTrack.clips.allSatisfy {
            $0.audioFileURL!.path.hasPrefix(store.generationImportsDirectory.path)
        })

        // The report ties each landed clip back to the clip it came from.
        #expect(result.clips.map(\.sourceClipId) == [a.id, b.id, c.id])
        #expect(result.clips.map(\.sourceTrackId) == [trackA, trackA, trackB])
        #expect(result.clips.map(\.clipId) == landedTrack.clips.map(\.id))
        #expect(result.warnings.isEmpty)
        #expect(result.clips.allSatisfy {
            FileManager.default.fileExists(atPath: $0.extractedPath)
        })

        // The SOURCES are untouched — a conversion reads, it never edits.
        #expect(store.tracks[0].clips.map(\.id) == [a.id, b.id])
        #expect(store.tracks[1].clips.map(\.id) == [c.id])
    }

    @Test("the whole set is ONE undoable edit")
    func wholeSetIsOneUndoStep() async throws {
        let (store, engine) = makeStore()
        _ = engine
        let a = Clip(name: "a", startBeat: 0, lengthBeats: 4, audioFileURL: sourceFile)
        let b = Clip(name: "b", startBeat: 8, lengthBeats: 4, audioFileURL: sourceFile)
        _ = install(store, [a, b])
        let before = store.tracks.count

        _ = try await store.convertClipsToVoice(
            clipIds: [a.id, b.id], trackName: "Voice: ada"
        ) { _, _ in try makeConverterOutput() }
        #expect(store.tracks.count == before + 1)

        let label = try store.undo()
        #expect(label == "Convert Voice")
        #expect(store.tracks.count == before, "ONE undo removes the whole converted set")
    }

    @Test("level shaping lands on the converted clip instead of being baked in")
    func levelShapingLandsOnTheClip() async throws {
        let (store, engine) = makeStore()
        _ = engine
        let clip = Clip(name: "shaped", startBeat: 0, lengthBeats: 4,
                        audioFileURL: sourceFile,
                        gainDb: -4.5, fadeInBeats: 1, fadeOutBeats: 1,
                        fadeInCurve: .equalPower, fadeOutCurve: .equalPower,
                        gainEnvelope: [ClipGainPoint(beat: 1, gainDb: -2)])
        _ = install(store, [clip])

        _ = try await store.convertClipsToVoice(
            clipIds: [clip.id], trackName: "Voice: ada"
        ) { _, _ in try makeConverterOutput() }

        let landed = try #require(store.tracks.last?.clips.first)
        #expect(approx(landed.gainDb, -4.5))
        #expect(approx(landed.fadeInBeats, 1))
        #expect(approx(landed.fadeOutBeats, 1))
        #expect(landed.fadeInCurve == .equalPower)
        #expect(landed.fadeOutCurve == .equalPower)
        #expect(landed.gainEnvelope.count == 1)
    }

    // MARK: - Refusals, all-or-nothing

    @Test("overlapping selected clips are refused, naming both — nothing lands")
    func overlappingSelectionRefused() async throws {
        let (store, engine) = makeStore()
        let a = Clip(name: "lead", startBeat: 0, lengthBeats: 8, audioFileURL: sourceFile)
        let b = Clip(name: "double", startBeat: 4, lengthBeats: 8, audioFileURL: sourceFile)
        _ = install(store, [a])
        _ = install(store, [b], name: "Double")
        let before = store.tracks.count

        var converterCalls = 0
        var message = ""
        do {
            _ = try await store.convertClipsToVoice(
                clipIds: [a.id, b.id], trackName: "Voice: ada"
            ) { _, _ in
                converterCalls += 1
                return try makeConverterOutput()
            }
            Issue.record("expected overlapping clips to be refused")
        } catch let error as ProjectError {
            message = error.errorDescription ?? ""
        }
        #expect(message.contains("lead") && message.contains("double"),
                "the refusal must name both clips: \(message)")
        #expect(message.contains("two passes"), "and say what to do instead: \(message)")
        #expect(converterCalls == 0, "refuse BEFORE paying for a conversion")
        #expect(engine.renderCalls.isEmpty, "refuse BEFORE paying for a render")
        #expect(store.tracks.count == before)
    }

    @Test("abutting clips are NOT an overlap")
    func abuttingClipsAreFine() async throws {
        let (store, _) = makeStore()
        let a = Clip(name: "a", startBeat: 0, lengthBeats: 4, audioFileURL: sourceFile)
        let b = Clip(name: "b", startBeat: 4, lengthBeats: 4, audioFileURL: sourceFile)
        _ = install(store, [a, b])

        let result = try await store.convertClipsToVoice(
            clipIds: [a.id, b.id], trackName: "Voice: ada"
        ) { _, _ in try makeConverterOutput() }
        #expect(result.clips.count == 2)
    }

    @Test("empty selection, a duplicate id, a MIDI clip and an unknown id all refuse early")
    func selectionValidation() async throws {
        let (store, engine) = makeStore()
        let a = Clip(name: "a", startBeat: 0, lengthBeats: 4, audioFileURL: sourceFile)
        _ = install(store, [a])
        let midi = Clip(name: "m", startBeat: 8, lengthBeats: 4, notes: [])
        store.tracks.append(Track(name: "Synth", kind: .instrument, clips: [midi]))
        let before = store.tracks.count
        let converterCalls = Counter()

        for selection in [[], [a.id, a.id], [a.id, midi.id], [a.id, UUID()]] {
            await #expect(throws: ProjectError.self) {
                _ = try await store.convertClipsToVoice(
                    clipIds: selection, trackName: "V"
                ) { _, _ in
                    converterCalls.value += 1
                    return try self.makeConverterOutput()
                }
            }
        }
        #expect(converterCalls.value == 0)
        // Every rejection lands before the first render: the whole selection
        // is validated up front.
        #expect(engine.renderCalls.isEmpty)
        #expect(store.tracks.count == before)
    }

    @Test("a converter failure on clip 2 of 3 lands NOTHING")
    func partialFailureLandsNothing() async throws {
        let (store, engine) = makeStore()
        _ = engine
        let a = Clip(name: "a", startBeat: 0, lengthBeats: 4, audioFileURL: sourceFile)
        let b = Clip(name: "b", startBeat: 8, lengthBeats: 4, audioFileURL: sourceFile)
        let c = Clip(name: "c", startBeat: 16, lengthBeats: 4, audioFileURL: sourceFile)
        _ = install(store, [a, b, c])
        let before = store.tracks.count
        let historyBefore = store.canUndo

        struct ConverterFailed: Error {}
        var calls = 0
        await #expect(throws: ConverterFailed.self) {
            _ = try await store.convertClipsToVoice(
                clipIds: [a.id, b.id, c.id], trackName: "Voice: ada"
            ) { _, _ in
                calls += 1
                if calls == 2 { throw ConverterFailed() }
                return try makeConverterOutput()
            }
        }
        #expect(calls == 2, "it stops at the failure rather than pressing on")
        #expect(store.tracks.count == before, "no partial track")
        #expect(store.canUndo == historyBefore, "and no journalled half-edit")
    }

    @Test("a converter that returns a missing file fails the whole call")
    func missingConverterOutputFails() async throws {
        let (store, _) = makeStore()
        let a = Clip(name: "a", startBeat: 0, lengthBeats: 4, audioFileURL: sourceFile)
        _ = install(store, [a])
        let before = store.tracks.count

        var thrown: ProjectError?
        do {
            _ = try await store.convertClipsToVoice(
                clipIds: [a.id], trackName: "V"
            ) { _, _ in URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).wav") }
            Issue.record("expected a missing converter output to fail the call")
        } catch let error as ProjectError {
            thrown = error
        }
        // Named, not just "some ProjectError": `engineUnavailable` is also a
        // ProjectError, so a loose assertion here would go green on a dead
        // engine instead of on the behaviour under test.
        if case .generationAudioMissing = thrown {} else {
            Issue.record("expected generationAudioMissing, got \(String(describing: thrown))")
        }
        #expect(store.tracks.count == before)
    }

    // MARK: - Honest reporting

    @Test("a converter that changed the length warns — the arrangement does not move")
    func lengthDriftWarnsButDoesNotMoveTheClip() async throws {
        // The clip presents 2 s; the converter hands back 2.4 s.
        let (store, _) = makeStore(mediaDurationSeconds: 2.4)
        let a = Clip(name: "verse", startBeat: 8, lengthBeats: 4, audioFileURL: sourceFile)
        _ = install(store, [a])

        let result = try await store.convertClipsToVoice(
            clipIds: [a.id], trackName: "Voice: ada"
        ) { _, _ in try makeConverterOutput() }

        let landed = try #require(store.tracks.last?.clips.first)
        // Geometry is the SOURCE's — on-disk duration must not move the
        // arrangement (the importConvertedVoice rule is deliberately not
        // inherited here).
        #expect(approx(landed.startBeat, 8))
        #expect(approx(landed.lengthBeats, 4))
        #expect(approx(result.clips[0].sourceSeconds, 2.0))
        #expect(approx(result.clips[0].convertedSeconds, 2.4))
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].contains("verse"))
    }

    @Test("a length match within the 10 ms tolerance does not warn")
    func smallDriftIsSilent() async throws {
        let (store, _) = makeStore(mediaDurationSeconds: 2.004)
        let a = Clip(name: "verse", startBeat: 0, lengthBeats: 4, audioFileURL: sourceFile)
        _ = install(store, [a])
        let result = try await store.convertClipsToVoice(
            clipIds: [a.id], trackName: "Voice: ada"
        ) { _, _ in try makeConverterOutput() }
        #expect(result.warnings.isEmpty)
    }

    @Test("a source clip moved mid-conversion warns and lands where it was")
    func geometryChangedMidFlightWarns() async throws {
        let (store, _) = makeStore()
        let a = Clip(name: "wanderer", startBeat: 4, lengthBeats: 4, audioFileURL: sourceFile)
        let trackID = install(store, [a])

        let result = try await store.convertClipsToVoice(
            clipIds: [a.id], trackName: "Voice: ada"
        ) { _, _ in
            // The user drags the source clip while the convert call is in
            // flight — the audio was captured at beat 4, so it lands at beat 4.
            let t = store.tracks.firstIndex(where: { $0.id == trackID })!
            store.tracks[t].clips[0].startBeat = 32
            return try makeConverterOutput()
        }

        let landed = try #require(store.tracks.last?.clips.first)
        #expect(approx(landed.startBeat, 4))
        #expect(result.warnings.count == 1)
        #expect(result.warnings[0].contains("wanderer"))
    }

    @Test("a source clip deleted mid-conversion fails the whole call")
    func sourceDeletedMidFlightFails() async throws {
        let (store, _) = makeStore()
        let a = Clip(name: "a", startBeat: 0, lengthBeats: 4, audioFileURL: sourceFile)
        let trackID = install(store, [a])
        let before = store.tracks.count

        var thrown: ProjectError?
        do {
            _ = try await store.convertClipsToVoice(
                clipIds: [a.id], trackName: "V"
            ) { _, _ in
                let t = store.tracks.firstIndex(where: { $0.id == trackID })!
                store.tracks[t].clips.removeAll()
                return try self.makeConverterOutput()
            }
            Issue.record("expected a deleted source clip to fail the call")
        } catch let error as ProjectError {
            thrown = error
        }
        if case .clipNotFound = thrown {} else {
            Issue.record("expected clipNotFound, got \(String(describing: thrown))")
        }
        #expect(store.tracks.count == before)
    }

    @Test("headless and media-less stores refuse before any work")
    func serviceGuards() async throws {
        let a = Clip(name: "a", startBeat: 0, lengthBeats: 4, audioFileURL: sourceFile)

        let headless = ProjectStore()
        headless.media = FakeMedia()
        headless.tracks.append(Track(name: "A", kind: .audio, clips: [a]))
        await #expect(throws: ProjectError.self) {
            _ = try await headless.convertClipsToVoice(
                clipIds: [a.id], trackName: "V") { _, _ in URL(fileURLWithPath: "/tmp/x.wav") }
        }

        let engine = FakeRenderEngine()
        let noMedia = ProjectStore()
        noMedia.engine = engine
        noMedia.tracks.append(Track(name: "A", kind: .audio, clips: [a]))
        await #expect(throws: ProjectError.self) {
            _ = try await noMedia.convertClipsToVoice(
                clipIds: [a.id], trackName: "V") { _, _ in URL(fileURLWithPath: "/tmp/x.wav") }
        }
        #expect(engine.renderCalls.isEmpty)
    }
}
