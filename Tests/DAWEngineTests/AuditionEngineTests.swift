import AVFAudio
import CAtomics
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m23-d note-audition ENGINE SEAM: renderer-identity addressing, the diff, the
/// heartbeat, the audibility report, and the stuck-note sweep (§13 C5's engine
/// half, C12, C13). Headless — `AudioEngine` is built but never started, which
/// is itself part of the contract: audition must work with the transport
/// stopped, so the seam may not require a running graph to accept events.
@MainActor
@Suite("Note audition engine seam (m23-d)", .serialized)
struct AuditionEngineTests {

    private func queuedAuditionEvents(_ renderer: InstrumentRenderer) -> [LiveMIDIEvent] {
        var events: [LiveMIDIEvent] = []
        while let event = renderer.auditionRing.pop() { events.append(event) }
        return events
    }

    private func heartbeat(_ renderer: InstrumentRenderer) -> UInt32 {
        daw_atomic_u32_load(renderer.auditionHeartbeat)
    }

    @Test("an audition pushes note-ons to the track's OWN renderer and bumps the heartbeat")
    func pushesToTheTracksRenderer() throws {
        let engine = AudioEngine()
        let track = Track(name: "Keys", kind: .instrument)
        let other = Track(name: "Bass", kind: .instrument)
        engine.tracksDidChange([track, other])
        let renderer = try #require(engine.graph.instrumentRenderer(forTrack: track.id))
        let otherRenderer = try #require(engine.graph.instrumentRenderer(forTrack: other.id))
        let beatBefore = heartbeat(renderer)

        let outcome = engine.setAuditionPitches(trackID: track.id, pitches: [60, 64],
                                                velocity: 88)

        #expect(outcome != .noRenderer && outcome != .unsupported)
        let events = queuedAuditionEvents(renderer)
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.kind == ScheduledMIDIEvent.noteOn && $0.velocity == 88 })
        #expect(events.map(\.pitch).sorted() == [60, 64])
        #expect(heartbeat(renderer) == beatBefore &+ 1)
        // Addressed by TRACK, not broadcast: the sibling instrument got nothing.
        #expect(queuedAuditionEvents(otherRenderer).isEmpty)
        // …and nothing went near the hardware-thru ring.
        #expect(renderer.thruRing.count == 0)
    }

    @Test("the diff releases only what left the set and triggers only what arrived")
    func diffsTheHeldSet() throws {
        let engine = AudioEngine()
        let track = Track(name: "Keys", kind: .instrument)
        engine.tracksDidChange([track])
        let renderer = try #require(engine.graph.instrumentRenderer(forTrack: track.id))

        engine.setAuditionPitches(trackID: track.id, pitches: [60, 64], velocity: 100)
        _ = queuedAuditionEvents(renderer)

        // Same set again: a pure heartbeat, ZERO events.
        let beatBefore = heartbeat(renderer)
        engine.setAuditionPitches(trackID: track.id, pitches: [64, 60], velocity: 100)
        #expect(queuedAuditionEvents(renderer).isEmpty)
        #expect(heartbeat(renderer) == beatBefore &+ 1)

        // 64 → 67: one off, one on.
        engine.setAuditionPitches(trackID: track.id, pitches: [60, 67], velocity: 100)
        let events = queuedAuditionEvents(renderer)
        #expect(events.count == 2)
        #expect(events.contains { $0.kind == ScheduledMIDIEvent.noteOff && $0.pitch == 64 })
        #expect(events.contains { $0.kind == ScheduledMIDIEvent.noteOn && $0.pitch == 67 })

        // Empty set releases everything still held.
        engine.setAuditionPitches(trackID: track.id, pitches: [], velocity: 0)
        let offs = queuedAuditionEvents(renderer)
        #expect(offs.count == 2)
        #expect(offs.allSatisfy { $0.kind == ScheduledMIDIEvent.noteOff })
        #expect(Set(offs.map(\.pitch)) == [60, 67])
        #expect(engine.auditionPitchesForTesting[track.id] == nil)
    }

    @Test("C12/F9 the OFF follows the ON across a node rebuild — never to a fresh renderer")
    func offFollowsTheOnAcrossANodeRebuild() throws {
        let engine = AudioEngine()
        let track = Track(name: "Keys", kind: .instrument)
        engine.tracksDidChange([track])
        let original = try #require(engine.graph.instrumentRenderer(forTrack: track.id))
        engine.setAuditionPitches(trackID: track.id, pitches: [60], velocity: 100)
        _ = queuedAuditionEvents(original)

        // An instrument change rebuilds the node — a DIFFERENT renderer object.
        engine.graph.invalidateInstrumentNode(trackID: track.id)
        engine.tracksDidChange([track])
        let rebuilt = try #require(engine.graph.instrumentRenderer(forTrack: track.id))
        #expect(rebuilt !== original)

        engine.setAuditionPitches(trackID: track.id, pitches: [60], velocity: 100)

        // The release went to the OLD object (whose ring our strong ref keeps
        // alive, so the push is memory-safe even though nothing will drain it),
        // and the held note re-triggered on the NEW one.
        let oldEvents = queuedAuditionEvents(original)
        #expect(oldEvents.count == 1)
        #expect(oldEvents[0].kind == ScheduledMIDIEvent.noteOff && oldEvents[0].pitch == 60)
        let newEvents = queuedAuditionEvents(rebuilt)
        #expect(newEvents.count == 1)
        #expect(newEvents[0].kind == ScheduledMIDIEvent.noteOn && newEvents[0].pitch == 60)
    }

    @Test("a track that lost its renderer releases on the remembered one and reports noRenderer")
    func lostRendererReleasesOnTheRememberedObject() throws {
        let engine = AudioEngine()
        let track = Track(name: "Keys", kind: .instrument)
        engine.tracksDidChange([track])
        let renderer = try #require(engine.graph.instrumentRenderer(forTrack: track.id))
        engine.setAuditionPitches(trackID: track.id, pitches: [60], velocity: 100)
        _ = queuedAuditionEvents(renderer)

        engine.tracksDidChange([])   // the track is gone
        let outcome = engine.setAuditionPitches(trackID: track.id, pitches: [60], velocity: 100)

        #expect(outcome == .noRenderer)
        let events = queuedAuditionEvents(renderer)
        #expect(events.count == 1)
        #expect(events[0].kind == ScheduledMIDIEvent.noteOff)
        #expect(engine.auditionPitchesForTesting[track.id] == nil)
    }

    @Test("audio, bus, and unknown tracks report noRenderer and deliver nothing")
    func nonInstrumentTracksReportNoRenderer() {
        let engine = AudioEngine()
        let audio = Track(name: "Vox", kind: .audio)
        let bus = Track(name: "Verb", kind: .bus)
        engine.tracksDidChange([audio, bus])

        #expect(engine.setAuditionPitches(trackID: audio.id, pitches: [60], velocity: 100)
                == .noRenderer)
        #expect(engine.setAuditionPitches(trackID: bus.id, pitches: [60], velocity: 100)
                == .noRenderer)
        #expect(engine.setAuditionPitches(trackID: UUID(), pitches: [60], velocity: 100)
                == .noRenderer)
        #expect(engine.auditionPitchesForTesting.isEmpty)
    }

    // MARK: - Breath pad P6: the ANTI-VACUITY gate for `previewController`
    //
    // ⚠️ `AudioEngineControlling.previewController` carries a `.unsupported`
    // default so fakes and headless engines compile unchanged. That default is
    // exactly the `availableOutputDevices` vacuity risk the protocol warns about
    // — and WORSE here, because the symptom is SILENCE rather than an empty
    // list. A real `AudioEngine` that forgot to override it would preview
    // nothing, forever, and every model-layer test would still pass, because
    // `PadPreviewController` is deliberately written to keep working against an
    // engine that cannot preview.
    //
    // This is `OutputDeviceTests`' shape applied to that method: assert the REAL
    // engine answers something other than `.unsupported` for a track that has an
    // instrument node. ⛔ THE PLANT: delete `AudioEngine.previewController` (the
    // protocol default then takes over and the code still compiles) and this
    // goes red while nothing else in the tree does.

    @Test("P6 the REAL engine implements previewController — it does not inherit .unsupported")
    func theRealEngineImplementsTheControllerPreview() throws {
        let engine = AudioEngine()
        let track = Track(name: "Sax", kind: .instrument)
        engine.tracksDidChange([track])
        let renderer = try #require(engine.graph.instrumentRenderer(forTrack: track.id))

        let outcome = engine.previewController(trackID: track.id, controller: 11, value: 90)

        #expect(outcome != .unsupported,
                "the real engine must OVERRIDE the protocol's .unsupported default")
        #expect(outcome != .noRenderer)
        // …and it must have actually pushed, not merely reported well. The
        // outcome alone is not proof: a setter's return is not proof it took.
        let events = queuedAuditionEvents(renderer)
        #expect(events.count == 1)
        // `.first?` rather than a subscript: when the engine override is
        // deleted (the vacuity plant) this must FAIL, not trap.
        #expect(events.first?.kind == ScheduledMIDIEvent.controlChange)
        #expect(events.first?.pitch == 11)
        #expect(events.first?.velocity == 90)
        // Nothing went near the hardware-thru ring, and no voice was opened.
        #expect(renderer.thruRing.count == 0)
        #expect(engine.auditionPitchesForTesting.isEmpty)
    }

    @Test("P6 the preview is NOT a heartbeat, and files no entry in the voice ledger")
    func previewIsNeitherHeartbeatNorVoice() throws {
        let engine = AudioEngine()
        let track = Track(name: "Sax", kind: .instrument)
        engine.tracksDidChange([track])
        let renderer = try #require(engine.graph.instrumentRenderer(forTrack: track.id))
        let beatBefore = heartbeat(renderer)

        engine.previewController(trackID: track.id, controller: 11, value: 64)

        // Bumping the counter would keep a genuinely stuck piano-roll audition
        // note alive past the render side's 3 s watchdog.
        #expect(heartbeat(renderer) == beatBefore)
        // And `auditionVoices` is keyed by PITCH: an entry for CC 11 would come
        // back out of `stopAllAudition`/`allNotesOff` as a note-off on pitch 11.
        #expect(engine.auditionPitchesForTesting[track.id] == nil)
    }

    @Test("P6 an unchanged value pushes nothing; a changed one pushes again")
    func previewFiltersUnchangedValues() throws {
        let engine = AudioEngine()
        let track = Track(name: "Sax", kind: .instrument)
        engine.tracksDidChange([track])
        let renderer = try #require(engine.graph.instrumentRenderer(forTrack: track.id))

        engine.previewController(trackID: track.id, controller: 11, value: 64)
        #expect(queuedAuditionEvents(renderer).count == 1)

        // A dot held still costs zero ring traffic — but the OUTCOME is still
        // reported honestly, because the strip really is at that value.
        let repeatOutcome = engine.previewController(trackID: track.id, controller: 11, value: 64)
        #expect(repeatOutcome != .unsupported && repeatOutcome != .noRenderer)
        #expect(queuedAuditionEvents(renderer).isEmpty)

        engine.previewController(trackID: track.id, controller: 11, value: 65)
        #expect(queuedAuditionEvents(renderer).count == 1)
        // A different CC is a different lane, never de-duplicated against 11.
        engine.previewController(trackID: track.id, controller: 74, value: 65)
        #expect(queuedAuditionEvents(renderer).count == 1)
    }

    @Test("P6 a reset invalidates the remembered value, so the next identical push lands")
    func previewLedgerIsClearedByAResetPath() throws {
        let engine = AudioEngine()
        let track = Track(name: "Sax", kind: .instrument)
        engine.tracksDidChange([track])
        let renderer = try #require(engine.graph.instrumentRenderer(forTrack: track.id))

        engine.previewController(trackID: track.id, controller: 11, value: 30)
        _ = queuedAuditionEvents(renderer)
        #expect(engine.controllerPreviewForTesting[track.id]?.value == 30)

        // Panic resets every instrument, which restores its OWN controller
        // defaults — so a remembered 30 would be a lie that suppressed the next
        // push of 30 and left the strip at full expression.
        _ = engine.allNotesOff()
        #expect(engine.controllerPreviewForTesting.isEmpty)

        engine.previewController(trackID: track.id, controller: 11, value: 30)
        #expect(queuedAuditionEvents(renderer).count == 1)
    }

    @Test("P6 audio, bus and unknown tracks report noRenderer and deliver no controller")
    func previewOnNonInstrumentTracksReportsNoRenderer() {
        let engine = AudioEngine()
        let audio = Track(name: "Vox", kind: .audio)
        let bus = Track(name: "Verb", kind: .bus)
        engine.tracksDidChange([audio, bus])

        #expect(engine.previewController(trackID: audio.id, controller: 11, value: 64)
                == .noRenderer)
        #expect(engine.previewController(trackID: bus.id, controller: 11, value: 64)
                == .noRenderer)
        #expect(engine.previewController(trackID: UUID(), controller: 11, value: 64)
                == .noRenderer)
        #expect(engine.controllerPreviewForTesting.isEmpty)
    }

    @Test("a muted track still RECEIVES the events and reports inaudibleMuted")
    func mutedReportsWithoutSuppressing() throws {
        let engine = AudioEngine()
        var track = Track(name: "Keys", kind: .instrument)
        track.isMuted = true
        engine.tracksDidChange([track])
        let renderer = try #require(engine.graph.instrumentRenderer(forTrack: track.id))

        let outcome = engine.setAuditionPitches(trackID: track.id, pitches: [60], velocity: 100)

        #expect(outcome == .inaudibleMuted)
        // Reporting, not policy: the strip is the mute authority, so nothing is
        // special-cased on the render thread.
        #expect(queuedAuditionEvents(renderer).count == 1)
    }

    @Test("a solo elsewhere excludes this track — same inaudibleMuted report")
    func soloExclusionReports() throws {
        let engine = AudioEngine()
        let track = Track(name: "Keys", kind: .instrument)
        var soloed = Track(name: "Lead", kind: .instrument)
        soloed.isSoloed = true
        engine.tracksDidChange([track, soloed])

        #expect(engine.setAuditionPitches(trackID: track.id, pitches: [60], velocity: 100)
                == .inaudibleMuted)
        // The soloed track itself is audible-if-running.
        #expect(engine.setAuditionPitches(trackID: soloed.id, pitches: [67], velocity: 100)
                != .inaudibleMuted)
    }

    @Test("C12 stopAllAudition releases every track's voices AND flushes their renderers")
    func stopAllAuditionSweeps() throws {
        let engine = AudioEngine()
        let first = Track(name: "Keys", kind: .instrument)
        let second = Track(name: "Bass", kind: .instrument)
        engine.tracksDidChange([first, second])
        let firstRenderer = try #require(engine.graph.instrumentRenderer(forTrack: first.id))
        let secondRenderer = try #require(engine.graph.instrumentRenderer(forTrack: second.id))
        engine.setAuditionPitches(trackID: first.id, pitches: [60], velocity: 100)
        engine.setAuditionPitches(trackID: second.id, pitches: [43, 45], velocity: 100)
        _ = queuedAuditionEvents(firstRenderer)
        _ = queuedAuditionEvents(secondRenderer)

        engine.stopAllAudition()

        #expect(queuedAuditionEvents(firstRenderer).count == 1)
        #expect(queuedAuditionEvents(secondRenderer).count == 2)
        #expect(engine.auditionPitchesForTesting.isEmpty)
        engine.stopAllAudition()   // idempotent
        #expect(queuedAuditionEvents(firstRenderer).isEmpty)
    }

    @Test("C12 shutdown() and projectWillReplace() both release held audition voices")
    func teardownPathsRelease() throws {
        let engine = AudioEngine()
        let track = Track(name: "Keys", kind: .instrument)
        engine.tracksDidChange([track])
        let renderer = try #require(engine.graph.instrumentRenderer(forTrack: track.id))

        engine.setAuditionPitches(trackID: track.id, pitches: [60], velocity: 100)
        _ = queuedAuditionEvents(renderer)
        engine.shutdown()
        #expect(queuedAuditionEvents(renderer).count == 1)
        #expect(engine.auditionPitchesForTesting.isEmpty)

        // A NEVER-RUN engine still holds voices (audition works stopped), so the
        // project-boundary release must run BEFORE the engineHasRun gate.
        let boundary = AudioEngine()
        boundary.tracksDidChange([track])
        let boundaryRenderer = try #require(
            boundary.graph.instrumentRenderer(forTrack: track.id))
        boundary.setAuditionPitches(trackID: track.id, pitches: [60], velocity: 100)
        _ = queuedAuditionEvents(boundaryRenderer)
        boundary.projectWillReplace()
        #expect(queuedAuditionEvents(boundaryRenderer).count == 1)
        #expect(boundary.auditionPitchesForTesting.isEmpty)
    }

    @Test("C13 an offline render builds FRESH renderers — a held audition cannot be baked in")
    func offlineRenderersAreIsolatedFromAudition() throws {
        // The structural half of C13, which is the half that actually closes the
        // class: `OfflineRenderer` constructs its own `AVAudioEngine` +
        // `PlaybackGraph` per render, so its `InstrumentRenderer`s — and their
        // audition rings and pitch maps — are new and EMPTY by construction. A
        // bounce therefore cannot observe a live renderer's held voice at all.
        //
        // NOT PROVEN HERE, and deliberately: the doc's C13 wording is "the
        // rendered buffer is bit-identical to the same render with no audition
        // held". That comparison is not run. The isolation argument below is
        // what makes it unnecessary — the two renderers are different objects,
        // so there is no channel for a held voice to reach the bounce at all.
        //
        // What is ALSO not asserted, and must not be: the LIVE ring's count.
        // `setAuditionPitches` starts the engine when it is stopped, so the live
        // render thread is genuinely running and drains its own ring on its own
        // schedule — a count there is a race with the audio device, not a
        // contract (it read 2 unloaded and 0 under full-suite load). The live
        // side's honest, main-actor-owned witness is its voice bookkeeping.
        let live = AudioEngine()
        let track = Track(name: "Keys", kind: .instrument)
        live.tracksDidChange([track])
        let liveRenderer = try #require(live.graph.instrumentRenderer(forTrack: track.id))
        live.setAuditionPitches(trackID: track.id, pitches: [60, 64], velocity: 100)
        #expect(live.auditionPitchesForTesting[track.id] == [60, 64])   // held

        // The offline path's graph, built the way OfflineRenderer builds it.
        let offlineEngine = AVAudioEngine()
        let offlineGraph = PlaybackGraph(engine: offlineEngine)
        offlineGraph.reconcile(tracks: [track])
        let offlineRenderer = try #require(
            offlineGraph.instrumentRenderer(forTrack: track.id))

        #expect(offlineRenderer !== liveRenderer)
        #expect(offlineRenderer.auditionRing.count == 0)
        #expect(offlineRenderer.openAuditionCount == 0)
        // And building the offline graph did not disturb the live engine's
        // held voices — the two graphs share no audition state whatsoever.
        #expect(live.auditionPitchesForTesting[track.id] == [60, 64])
    }

    @Test("C14 audition never reaches the capture ring (structural)")
    func auditionIsUnreachableFromCapture() throws {
        // The capture ring is fed ONLY by `MIDIInputRTContext.deliver` on the
        // CoreMIDI receive thread. The audition ring is per-renderer and is not
        // reachable from `deliver` — there is no code path from
        // `setAuditionPitches` to a capture ring, so an audition can never be
        // recorded into a take. This pins the observable half: a full audition
        // round trip leaves the capture ring at zero.
        let engine = AudioEngine()
        let track = Track(name: "Keys", kind: .instrument)
        engine.tracksDidChange([track])
        let context = MIDIInputRTContext()
        #expect(context.captureRing.count == 0)

        engine.setAuditionPitches(trackID: track.id, pitches: [60, 64, 67], velocity: 100)
        engine.setAuditionPitches(trackID: track.id, pitches: [], velocity: 0)

        #expect(context.captureRing.count == 0)
        #expect(daw_atomic_u32_load(context.eventCounter) == 0)
    }

    @Test("velocity is clamped to a sounding value before it reaches the ring")
    func velocityIsClamped() throws {
        let engine = AudioEngine()
        let track = Track(name: "Keys", kind: .instrument)
        engine.tracksDidChange([track])
        let renderer = try #require(engine.graph.instrumentRenderer(forTrack: track.id))

        // 0 would be a note-off in MIDI's running-status convention — an
        // audition asked to sound something must never emit a silent on.
        engine.setAuditionPitches(trackID: track.id, pitches: [60], velocity: 0)
        let events = queuedAuditionEvents(renderer)
        #expect(events.count == 1)
        #expect(events[0].kind == ScheduledMIDIEvent.noteOn)
        #expect(events[0].velocity == 1)
    }

    // MARK: - I1: the clip-note audition voice (hear the note while editing it)
    //
    // Design `2026-09-24-pitch-editor-interaction-batch.md` §4, decision (c).
    // ⛔ NONE OF THESE STARTS THE AUDIO HARDWARE. `clipAuditionDeliveryForTesting`
    // receives exactly the buffer the voice would schedule, INSTEAD of the
    // engine starting and scheduling it; every test ends by asserting the
    // engine never ran. (This suite's older tests are not like that:
    // `setAuditionPitches` with a non-empty set calls `prepare()`, which starts
    // the engine. Filter to `clipSpan` to run only these.)
    // In this EXISTING `@MainActor` suite so MainActorOccupancy Leg C stays put.

    /// Every buffer the voice would have scheduled, and when it arrived.
    private final class I1Deliveries {
        var buffers: [AVAudioPCMBuffer] = []
        var arrivals: [ContinuousClock.Instant] = []
        func append(_ buffer: AVAudioPCMBuffer) {
            buffers.append(buffer)
            arrivals.append(ContinuousClock.now)
        }
    }

    private final class I1Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    /// Polls `condition` on the main actor (yielding it between polls, so the
    /// engine's own main-actor tasks run) until it holds or `seconds` pass.
    private func i1Wait(seconds: Double, _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    /// A stereo 48 kHz WAV of `pieces` (see `I1Signals.tone`), and its samples.
    private func i1Tone(_ label: String, pieces: [(seconds: Double, hz: Double)],
                        ramp: Bool = false) throws -> (url: URL, samples: [Float]) {
        let url = try I1Signals.tempDir(label).appendingPathComponent("vox.wav")
        let samples = I1Signals.tone(pieces: pieces, ramp: ramp)
        try I1Signals.write([samples, samples], sampleRate: 48_000, to: url)
        return (url, samples)
    }

    @Test("I1 clipSpan: the real engine overrides the protocol default, builds the voice with the graph, and refuses what it cannot play")
    func clipSpanRealEngineOverridesTheDefault() async throws {
        let (source, _) = try i1Tone("override", pieces: [(1.0, 220)])
        let engine = AudioEngine()
        let deliveries = I1Deliveries()
        engine.clipAuditionDeliveryForTesting = { deliveries.append($0) }
        let clip = Clip(name: "v", startBeat: 0, lengthBeats: 2, audioFileURL: source)
        let vox = Track(name: "Vox", kind: .audio, clips: [clip])
        let midi = Clip(name: "k", startBeat: 0, lengthBeats: 2,
                        notes: [MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1)])
        let keys = Track(name: "Keys", kind: .instrument, clips: [midi])
        engine.tracksDidChange([vox, keys])

        // The voice is part of every live graph, built with it.
        #expect(engine.graph.clipAuditionLaneEnabled)
        #expect(engine.graph.clipAuditionPlayer != nil)
        #expect(engine.graph.clipAuditionMixer != nil)

        // THROUGH THE PROTOCOL: a requirement the engine failed to witness
        // would answer the extension default, `.unsupported`, right here.
        let asProtocol: any AudioEngineControlling = engine
        #expect(asProtocol.auditionClipSpan(trackID: UUID(), clipID: clip.id,
                                            startSourceSeconds: 0.1, endSourceSeconds: 0.3)
            == .noRenderer)
        #expect(engine.auditionClipSpan(trackID: keys.id, clipID: midi.id,
                                        startSourceSeconds: 0.1, endSourceSeconds: 0.3) == .noRenderer)
        #expect(engine.auditionClipSpan(trackID: vox.id, clipID: UUID(),
                                        startSourceSeconds: 0.1, endSourceSeconds: 0.3) == .noRenderer)
        #expect(engine.auditionClipSpan(trackID: vox.id, clipID: clip.id,
                                        startSourceSeconds: 0.3, endSourceSeconds: 0.1) == .noRenderer)
        #expect(engine.auditionClipSpan(trackID: vox.id, clipID: clip.id,
                                        startSourceSeconds: .nan, endSourceSeconds: 0.3) == .noRenderer)

        // A playable span sounds, and exactly one buffer arrives.
        #expect(asProtocol.auditionClipSpan(trackID: vox.id, clipID: clip.id,
                                            startSourceSeconds: 0.1, endSourceSeconds: 0.3)
            == .sounded)
        #expect(try await i1Wait(seconds: 10) { deliveries.buffers.count == 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(deliveries.buffers.count == 1)
        #expect(deliveries.buffers.first?.frameLength == 9_600)

        // The render-complete sink is a witnessed requirement too.
        let reported = I1Box<[UUID]>([])
        asProtocol.setClipRenderCompleteHandler { reported.value.append($0) }
        engine.stretchCache.onRenderComplete?(clip.id)
        #expect(reported.value == [clip.id])
        #expect(!engine.isRunning, "an audition gate started the audio hardware")
    }

    @Test("I1 clipSpan: the voice reads the file playback opened — the source for an untouched clip, the committed render for a tuned one — and nothing while that render is in flight")
    func clipSpanPlaysTheFilePlaybackOpened() async throws {
        let (source, _) = try i1Tone("same-file", pieces: [(1.2, 220)])
        let engine = AudioEngine()
        let deliveries = I1Deliveries()
        engine.clipAuditionDeliveryForTesting = { deliveries.append($0) }
        let reported = I1Box<[UUID]>([])
        // Handler FIRST, cache replaced AFTER: the replacement must be re-wired.
        engine.setClipRenderCompleteHandler { reported.value.append($0) }
        engine.stretchCache = StretchRenderCache(
            directory: try I1Signals.tempDir("same-file-cache"))
        let untouched = Clip(name: "u", startBeat: 0, lengthBeats: 2.4, audioFileURL: source)
        let tuned = Clip(name: "t", startBeat: 0, lengthBeats: 2.4, audioFileURL: source,
                         pitchEdits: PitchEditSet(segments: [
                             NoteSegment(startSeconds: 0.2, endSeconds: 0.8, detectedHz: 220,
                                         detectedConfidence: 0.9, pitchOffsetCents: 200),
                         ]))
        let plain = Track(name: "Plain", kind: .audio, clips: [untouched])
        let vox = Track(name: "Vox", kind: .audio, clips: [tuned])
        engine.tracksDidChange([plain, vox])

        // In flight: playback gives the tuned clip no node (silence), and the
        // voice refuses rather than play the untuned source.
        #expect(engine.graph.clipFileURLForTesting(clipID: tuned.id) == nil)
        #expect(engine.planClipSpanAudition(trackID: vox.id, clipID: tuned.id,
                                            startSourceSeconds: 0.2, endSourceSeconds: 0.8)
            == .refused(.inaudibleNotReady))
        #expect(engine.auditionClipSpan(trackID: vox.id, clipID: tuned.id,
                                        startSourceSeconds: 0.2, endSourceSeconds: 0.8)
            == .inaudibleNotReady)

        #expect(try await i1Wait(seconds: 30) {
            engine.graph.clipFileURLForTesting(clipID: tuned.id) != nil
        }, "the tuned clip's render never reached playback")
        #expect(reported.value == [tuned.id],
                "render-complete reported \(reported.value), expected exactly the tuned clip")

        let playedTuned = try #require(engine.graph.clipFileURLForTesting(clipID: tuned.id))
        guard case .ready(let tunedRequest) = engine.planClipSpanAudition(
            trackID: vox.id, clipID: tuned.id, startSourceSeconds: 0.2, endSourceSeconds: 0.8) else {
            Issue.record("the tuned clip's audition did not resolve once its render landed")
            return
        }
        #expect(tunedRequest.fileURL.resolvingSymlinksInPath()
            == playedTuned.resolvingSymlinksInPath(),
                "the voice reads \(tunedRequest.fileURL.lastPathComponent), playback plays \(playedTuned.lastPathComponent)")
        #expect(tunedRequest.fileURL.pathExtension == "caf")
        #expect(tunedRequest.ratio == 1)

        let playedPlain = try #require(engine.graph.clipFileURLForTesting(clipID: untouched.id))
        guard case .ready(let plainRequest) = engine.planClipSpanAudition(
            trackID: plain.id, clipID: untouched.id, startSourceSeconds: 0.2,
            endSourceSeconds: 0.8) else {
            Issue.record("the untouched clip's audition did not resolve")
            return
        }
        #expect(plainRequest.fileURL.resolvingSymlinksInPath()
            == playedPlain.resolvingSymlinksInPath())
        #expect(plainRequest.fileURL.resolvingSymlinksInPath() == source.resolvingSymlinksInPath())
        #expect(plainRequest.ratio == 1)
        #expect(deliveries.buffers.isEmpty, "a refused audition delivered a buffer")
        #expect(!engine.isRunning, "an audition gate started the audio hardware")
    }

    @Test("I1 clipSpan: a muted strip, or one a solo leaves out, refuses with inaudibleMuted; the soloed strip plays")
    func clipSpanMutedAndSoloRefuse() async throws {
        let (source, _) = try i1Tone("mute", pieces: [(1.0, 220)])
        let engine = AudioEngine()
        let deliveries = I1Deliveries()
        engine.clipAuditionDeliveryForTesting = { deliveries.append($0) }
        func clip() -> Clip { Clip(name: "c", startBeat: 0, lengthBeats: 2, audioFileURL: source) }
        let muted = Track(name: "Muted", kind: .audio, isMuted: true, clips: [clip()])
        let other = Track(name: "Other", kind: .audio, clips: [clip()])
        var soloed = Track(name: "Soloed", kind: .audio, isSoloed: true, clips: [clip()])
        engine.tracksDidChange([muted, other, soloed])

        func play(_ track: Track) -> AuditionOutcome {
            engine.auditionClipSpan(trackID: track.id, clipID: track.clips[0].id,
                                    startSourceSeconds: 0.1, endSourceSeconds: 0.3)
        }
        #expect(play(muted) == .inaudibleMuted)
        #expect(play(other) == .inaudibleMuted, "a solo elsewhere must leave this strip out")
        #expect(play(soloed) == .sounded)

        // Control: without the solo, the other strip plays; mute still refuses.
        soloed.isSoloed = false
        engine.tracksDidChange([muted, other, soloed])
        #expect(play(other) == .sounded)
        #expect(try await i1Wait(seconds: 10) { deliveries.buffers.count == 1 })
        #expect(play(muted) == .inaudibleMuted)
        #expect(!engine.isRunning, "an audition gate started the audio hardware")
    }

    @Test("I1 clipSpan: the level is clip gain × fader, baked into the buffer (−6 dB × 0.5), bit for bit")
    func clipSpanLevelIsClipGainTimesFader() async throws {
        let (source, samples) = try i1Tone("level", pieces: [(1.0, 220)])
        let engine = AudioEngine()
        let deliveries = I1Deliveries()
        engine.clipAuditionDeliveryForTesting = { deliveries.append($0) }
        let clip = Clip(name: "c", startBeat: 0, lengthBeats: 2, audioFileURL: source, gainDb: -6)
        let track = Track(name: "Vox", kind: .audio, volume: 0.5, clips: [clip])
        engine.tracksDidChange([track])

        #expect(engine.auditionClipSpan(trackID: track.id, clipID: clip.id,
                                        startSourceSeconds: 0.25, endSourceSeconds: 0.45) == .sounded)
        #expect(try await i1Wait(seconds: 10) { deliveries.buffers.count == 1 })
        let out = I1Signals.planar(try #require(deliveries.buffers.first))
        let gain = Float(pow(10.0, -6.0 / 20.0) * 0.5)
        try #require(out[0].count == 9_600, "0.2 s at 48 kHz, got \(out[0].count)")
        var mismatched = 0
        for frame in 240..<(9_600 - 240) where out[0][frame] != samples[12_000 + frame] * gain {
            mismatched += 1
        }
        let measured = I1Signals.rms(out[0][240..<9_360]) / I1Signals.rms(samples[12_240..<21_360])
        print("[measured] I1 voice level: buffer/source RMS \(measured), expected \(gain) "
              + "(−6 dB × fader 0.5); \(mismatched) mismatched samples")
        #expect(mismatched == 0)
        #expect(!engine.isRunning, "an audition gate started the audio hardware")
    }

    @Test("I1 clipSpan: on a ratio-1.5 render the span lands where playback plays that source second (file frame 72000 for source 1.0 s)")
    func clipSpanAlignsWithPlaybackOnAStretchedRender() async throws {
        // An amplitude-RAMPED tone: a pure periodic tone would let a wrong
        // offset hide; the ramp makes the file position observable.
        let (source, _) = try i1Tone("align", pieces: [(2.0, 440)], ramp: true)
        let engine = AudioEngine()
        let deliveries = I1Deliveries()
        engine.clipAuditionDeliveryForTesting = { deliveries.append($0) }
        engine.stretchCache = StretchRenderCache(directory: try I1Signals.tempDir("align-cache"))
        let clip = Clip(name: "s", startBeat: 0, lengthBeats: 6, audioFileURL: source,
                        stretchRatio: 1.5)
        let track = Track(name: "Vox", kind: .audio, clips: [clip])
        engine.tracksDidChange([track])
        #expect(try await i1Wait(seconds: 30) {
            engine.graph.clipFileURLForTesting(clipID: clip.id) != nil
        }, "the stretched render never reached playback")

        guard case .ready(let request) = engine.planClipSpanAudition(
            trackID: track.id, clipID: clip.id, startSourceSeconds: 1.0,
            endSourceSeconds: 1.2) else {
            Issue.record("the stretched clip's audition did not resolve")
            return
        }
        #expect(request.ratio == 1.5)
        #expect(engine.auditionClipSpan(trackID: track.id, clipID: clip.id,
                                        startSourceSeconds: 1.0, endSourceSeconds: 1.2) == .sounded)
        #expect(try await i1Wait(seconds: 10) { deliveries.buffers.count == 1 })
        let out = I1Signals.planar(try #require(deliveries.buffers.first))
        let render = try I1Signals.read(request.fileURL).planar
        // 1.0 s × 1.5 × 48 kHz, a literal: where playback reads source second
        // 1.0 of this clip (`startOffsetSeconds × ratio` in the schedule).
        let first = 72_000
        // Lengths first, as requirements: a wrong mapping must fail here by
        // name, not crash the process on an index further down.
        try #require(out[0].count == 14_400,
                     "0.2 source seconds at ratio 1.5 is 14400 frames, got \(out[0].count)")
        try #require(render[0].count >= first + 14_400)
        var mismatched = 0
        for frame in 240..<(14_400 - 240)
        where out[0][frame].bitPattern != render[0][first + frame].bitPattern {
            mismatched += 1
        }
        print("[measured] I1 ratio-1.5 alignment: \(mismatched) of \(14_400 - 480) mid-span samples "
              + "differ from the render at frame \(first)+")
        #expect(mismatched == 0, "the voice did not read the render at the frame playback plays")
        #expect(!engine.isRunning, "an audition gate started the audio hardware")
    }

    @Test("I1 clipSpan physics: after a +2 st edit the audition BUFFER reads the new pitch (independent YIN, ±30 c); before the edit, and an untouched note of the same render, read the old (I1-F1: the release plays the committed SPAN at once)")
    func clipSpanPhysicsHearsTheEdit() async throws {
        let (source, _) = try i1Tone("physics", pieces: [(1.6, 220)])
        let a = NoteSegment(startSeconds: 0.2, endSeconds: 0.7, detectedHz: 220,
                            detectedConfidence: 0.9)
        let b = NoteSegment(startSeconds: 0.9, endSeconds: 1.4, detectedHz: 220,
                            detectedConfidence: 0.9)
        let clip = Clip(name: "vox", startBeat: 0, lengthBeats: 3.2, audioFileURL: source,
                        pitchEdits: PitchEditSet(segments: [a, b]))
        let track = Track(name: "Vox", kind: .audio, clips: [clip])
        let store = ProjectStore(tracks: [track])
        let engine = AudioEngine()
        engine.stretchCache = StretchRenderCache(directory: try I1Signals.tempDir("physics-cache"))
        let deliveries = I1Deliveries()
        engine.clipAuditionDeliveryForTesting = { deliveries.append($0) }
        store.engine = engine
        engine.tracksDidChange(store.tracks)

        // BEFORE: the note as it sounds now — the source.
        let before = try store.auditionClipNotes(clipId: clip.id, segmentIds: [a.id])
        #expect(before.isAudible && before.source == .source)
        try #require(try await i1Wait(seconds: HangGuard.seconds) { deliveries.buffers.count == 1 })

        // THE EDIT, then the release door.
        try store.setClipNotePitchOffset(clipId: clip.id, segmentId: a.id, offsetCents: 200)
        let committedAt = ContinuousClock.now
        let after = try store.auditionClipNotesAfterEdit(.pitch, clipId: clip.id,
                                                         segmentIds: [a.id], enabled: true)
        // I1-F1: the release no longer waits for the whole-file render; it
        // plays a span render of the COMMITTED edits at once. (I1's contract
        // here was `.waitingForRender` from `.render`.)
        #expect(after.isAudible && after.reason == nil, "the release door did not play at once")
        #expect(after.source == .spanRender)
        try #require(try await i1Wait(seconds: HangGuard.seconds) { deliveries.buffers.count == 2 },
                "the edited notes never played")
        let waited = deliveries.arrivals.count == 2 ? deliveries.arrivals[1] - committedAt : .zero

        // CONTROL: an untouched note of the SAME edited render, once that
        // render has landed (the press then plays the whole-file render).
        try #require(try await i1Wait(seconds: HangGuard.seconds) {
            if case .ready = engine.planClipSpanAudition(
                trackID: track.id, clipID: clip.id, startSourceSeconds: b.startSeconds,
                endSourceSeconds: b.endSeconds) { return true }
            return false
        }, "the whole-file render never landed")
        let control = try store.auditionClipNotes(clipId: clip.id, segmentIds: [b.id])
        #expect(control.isAudible && control.source == .render)
        try #require(try await i1Wait(seconds: HangGuard.seconds) { deliveries.buffers.count == 3 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(deliveries.buffers.count == 3, "a request played more than once")
        try #require(deliveries.buffers.count == 3)

        let yinStarted = Date()
        let readings = await Self.i1YinPitchesOffMain(
            [deliveries.buffers[0], deliveries.buffers[1], deliveries.buffers[2]].map { Self.i1YinInterior($0) })
        RepointDiagYin.report("clipSpanPhysicsHearsTheEdit (3 buffers)", from: yinStarted,
                              ranOn: "on a .utility detached task")
        let beforeHz = try #require(readings[0])
        let afterHz = try #require(readings[1])
        let controlHz = try #require(readings[2])
        let shift = I1Signals.cents(afterHz, from: 220)
        print("[measured] I1 physics (YIN on the audition buffers): before \(beforeHz) Hz "
              + "(\(I1Signals.cents(beforeHz, from: 220)) c), after +200 c edit \(afterHz) Hz "
              + "(\(shift) c), untouched note of the edited render \(controlHz) Hz "
              + "(\(I1Signals.cents(controlHz, from: 220)) c); commit → edited buffer \(waited)")
        #expect(abs(I1Signals.cents(beforeHz, from: 220)) <= 30)
        #expect(abs(shift - 200) <= 30, "the audition played \(shift) c, not the +200 c edit")
        #expect(abs(I1Signals.cents(controlHz, from: 220)) <= 30)
        #expect(!engine.isRunning, "an audition gate started the audio hardware")
    }

    @Test("I1 clipSpan: the latest request wins, and a stop, stopAllAudition or a graph rebuild discards a read still in flight")
    func clipSpanLatestWinsAndStopsDiscard() async throws {
        let (source, _) = try i1Tone("latest", pieces: [(2.0, 220)])
        let engine = AudioEngine()
        let deliveries = I1Deliveries()
        engine.clipAuditionDeliveryForTesting = { deliveries.append($0) }
        let busID = UUID()
        let bus = Track(id: busID, name: "FX", kind: .bus)
        let clip = Clip(name: "c", startBeat: 0, lengthBeats: 4, audioFileURL: source)
        let vox = Track(name: "Vox", kind: .audio, clips: [clip],
                        sends: [Send(destinationBusID: busID, level: 0.5)])
        engine.tracksDidChange([vox, bus])
        @discardableResult
        func play(_ start: Double, _ end: Double) -> AuditionOutcome {
            engine.auditionClipSpan(trackID: vox.id, clipID: clip.id,
                                    startSourceSeconds: start, endSourceSeconds: end)
        }

        // Latest wins: two requests back to back deliver ONE buffer, the second.
        play(0.1, 0.3)
        play(0.5, 0.9)
        #expect(try await i1Wait(seconds: 10) { !deliveries.buffers.isEmpty })
        try await Task.sleep(for: .milliseconds(300))
        #expect(deliveries.buffers.count == 1)
        #expect(deliveries.buffers.first?.frameLength == 19_200, "the superseded span played")

        // A stop discards a read in flight.
        play(0.1, 0.3)
        engine.stopClipSpanAudition()
        try await Task.sleep(for: .milliseconds(300))
        #expect(deliveries.buffers.count == 1, "a stopped audition still played")

        // So does stopAllAudition (shutdown, project boundary, resign-active).
        play(0.1, 0.3)
        engine.stopAllAudition()
        try await Task.sleep(for: .milliseconds(300))
        #expect(deliveries.buffers.count == 1, "stopAllAudition left the audition playing")

        // A REFUSED request is still the latest one: it silences the voice
        // (after an edit, the pre-edit sound must not keep playing while the
        // render is pending).
        play(0.1, 0.3)
        #expect(engine.auditionClipSpan(trackID: vox.id, clipID: UUID(), startSourceSeconds: 0.1,
                                        endSourceSeconds: 0.3) == .noRenderer)
        try await Task.sleep(for: .milliseconds(300))
        #expect(deliveries.buffers.count == 1, "a refused request left the previous audition playing")

        // And a graph rebuild: the "once-rendered" precondition without
        // hardware (what prepare() sets), then a routing change.
        engine.graph.engineHasRun = true
        let graphBefore = ObjectIdentifier(engine.graph)
        play(0.1, 0.3)
        var rewired = vox
        rewired.sends = []
        engine.tracksDidChange([rewired, bus])
        #expect(ObjectIdentifier(engine.graph) != graphBefore,
                "no rebuild happened, so the gate below would prove nothing")
        try await Task.sleep(for: .milliseconds(300))
        #expect(deliveries.buffers.count == 1, "an audition started before a rebuild played after it")

        // Control: the same request with nothing in between still delivers,
        // on the rebuilt graph, which carries its own voice.
        #expect(engine.graph.clipAuditionPlayer != nil)
        let askedAt = ContinuousClock.now
        #expect(play(0.1, 0.3) == .sounded)
        #expect(try await i1Wait(seconds: 10) { deliveries.buffers.count == 2 })
        if deliveries.arrivals.count == 2 {
            print("[measured] I1 press → buffer ready (0.2 s span, detached read): "
                  + "\(deliveries.arrivals[1] - askedAt)")
        }
        #expect(!engine.isRunning, "an audition gate started the audio hardware")
    }

    // MARK: - I1-F1: span renders through the real engine (the seam; no device)
    //
    // Filter `clipSpanRender` runs only these. Each ends by asserting the
    // engine never ran: the delivery seam receives the buffer the voice would
    // schedule, and no device is touched.

    /// Every completion one test's auditions reported, in order.
    @MainActor
    private final class I1F1Reports {
        var values: [ClipSpanAuditionDelivery] = []
        func append(_ delivery: ClipSpanAuditionDelivery) { values.append(delivery) }
    }

    /// A 48 kHz stereo 220 Hz tone of `seconds`, one audio clip on it carrying
    /// `edits`, an engine with its own render cache, the delivery seam wired.
    private func i1f1Engine(_ label: String, seconds: Double, edits: [NoteSegment])
        throws -> (AudioEngine, Track, Clip, I1Deliveries, URL) {
        let (source, _) = try i1Tone(label, pieces: [(seconds, 220)])
        let engine = AudioEngine()
        engine.stretchCache = StretchRenderCache(directory: try I1Signals.tempDir("\(label)-cache"))
        let deliveries = I1Deliveries()
        engine.clipAuditionDeliveryForTesting = { deliveries.append($0) }
        let clip = Clip(name: "v", startBeat: 0, lengthBeats: (seconds * 2).rounded(.up),
                        audioFileURL: source,
                        pitchEdits: edits.isEmpty ? nil : PitchEditSet(segments: edits))
        let vox = Track(name: "Vox", kind: .audio, clips: [clip])
        engine.tracksDidChange([vox])
        return (engine, vox, clip, deliveries, source)
    }

    /// A span's interior, for YIN: the buffer's first channel minus its 60 ms
    /// context and 50 ms more on each side (the renderer's ramps and the
    /// voice's fades); nil when that leaves too little to read.
    private static func i1YinInterior(_ buffer: AVAudioPCMBuffer) -> ArraySlice<Float>? {
        let samples = I1Signals.planar(buffer)[0]
        let margin = Int(0.110 * 48_000)
        guard samples.count > 2 * margin + 4_096 else { return nil }
        return samples[margin..<(samples.count - margin)]
    }

    /// `I1Signals.medianYinHz` (120–500 Hz) over each interior, computed OFF
    /// the main actor; nil where an interior is nil or reads unvoiced. The
    /// same function on the same slices, so the same numbers as before
    /// (I1-F2 follow-up). This suite is `@MainActor`: computed on it, the
    /// physics test's three readings held the main thread 4.8–5.0 s and the
    /// span test's two about 3.0 s, and every other main-actor test in the
    /// process waited that long. A real-engine render job in
    /// `EngineNoticeEngineTests` missed its 5 s window that way (measured:
    /// `REPOINT_DIAG=1`'s main-queue watch). `.utility` is neither the tests'
    /// priority nor the renders'.
    private static func i1YinPitchesOffMain(_ interiors: [ArraySlice<Float>?]) async -> [Double?] {
        await Task.detached(priority: .utility) {
            interiors.map { interior in
                interior.flatMap { I1Signals.medianYinHz($0, sampleRate: 48_000, minHz: 120, maxHz: 500) }
            }
        }.value
    }

    @Test("I1-F1 clipSpanRender: through the PROTOCOL on the real engine, the STORED and a DRAFT edit set render just the span, each at its own pitch (YIN ±30 c), and the completion reports what played")
    func clipSpanRenderPlaysStoredAndDraftSpans() async throws {
        let note = NoteSegment(startSeconds: 1.0, endSeconds: 2.0, detectedHz: 220,
                               detectedConfidence: 0.9, pitchOffsetCents: 200)
        let (engine, vox, clip, deliveries, _) = try i1f1Engine("span-stored-draft", seconds: 3,
                                                                edits: [note])
        let asProtocol: any AudioEngineControlling = engine
        let reports = I1F1Reports()

        #expect(asProtocol.auditionClipSpan(trackID: vox.id, clipID: clip.id,
                                            startSourceSeconds: 1.2, endSourceSeconds: 1.8,
                                            source: .storedSpanRender,
                                            completion: { reports.append($0) }) == .sounded)
        try #require(try await i1Wait(seconds: HangGuard.seconds) { reports.values.count == 1 })
        var draftNote = note
        draftNote.pitchOffsetCents = -300
        #expect(asProtocol.auditionClipSpan(trackID: vox.id, clipID: clip.id,
                                            startSourceSeconds: 1.2, endSourceSeconds: 1.8,
                                            source: .draftSpanRender(PitchEditSet(segments: [draftNote])),
                                            completion: { reports.append($0) }) == .sounded)
        try #require(try await i1Wait(seconds: HangGuard.seconds) { reports.values.count == 2 })
        try await Task.sleep(for: .milliseconds(100))
        try #require(deliveries.buffers.count == 2)
        #expect(reports.values == [.played(seconds: 0.6), .played(seconds: 0.6)])
        #expect(deliveries.buffers.allSatisfy { $0.frameLength == 28_800 })
        #expect(deliveries.buffers.allSatisfy { $0.format.channelCount == 2 })

        let yinStarted = Date()
        let readings = await Self.i1YinPitchesOffMain(
            [deliveries.buffers[0], deliveries.buffers[1]].map { Self.i1YinInterior($0) })
        RepointDiagYin.report("clipSpanRenderPlaysStoredAndDraftSpans (2 buffers)", from: yinStarted,
                              ranOn: "on a .utility detached task")
        let storedHz = try #require(readings[0])
        let draftHz = try #require(readings[1])
        let storedCents = I1Signals.cents(storedHz, from: 220)
        let draftCents = I1Signals.cents(draftHz, from: 220)
        print("[measured] I1-F1 span render via the engine (YIN): stored +200 c set → "
              + "\(storedCents) c; draft −300 c set → \(draftCents) c")
        #expect(abs(storedCents - 200) <= 30, "the stored span played \(storedCents) c")
        #expect(abs(draftCents + 300) <= 30, "the DRAFT span played \(draftCents) c, not −300 c")
        #expect(!engine.isRunning, "an audition gate started the audio hardware")
    }

    @Test("I1-F1 clipSpanRender R8: a span render while the clip's whole-file render is in flight is delivered first, neither cancels nor restarts that render, and matches it (−90 dB, pre-roll in untransposed history) once it lands")
    func clipSpanRenderLeavesTheWholeFileRenderAlone() async throws {
        let note = NoteSegment(startSeconds: 10.0, endSeconds: 11.0, detectedHz: 220,
                               detectedConfidence: 0.9, pitchOffsetCents: 200)
        let (engine, vox, clip, deliveries, _) = try i1f1Engine("span-r8", seconds: 20,
                                                                edits: [note])
        let completed = I1Box<[ContinuousClock.Instant]>([])
        engine.setClipRenderCompleteHandler { id in
            if id == clip.id { completed.value.append(.now) }
        }
        try #require(try await i1Wait(seconds: HangGuard.seconds) {
            engine.stretchCache.status(forClip: clip.id) == .rendering
        }, "the whole-file render never started, so this proves nothing")

        let reports = I1F1Reports()
        // The span starts 0.3 s BEFORE the edited note, so its pre-roll lies in
        // untransposed history at ratio 1: the one place a waveform match is
        // physically reachable (see `StretchWindow.swift`'s banner).
        #expect(engine.auditionClipSpan(trackID: vox.id, clipID: clip.id,
                                        startSourceSeconds: 9.7, endSourceSeconds: 10.5,
                                        source: .storedSpanRender,
                                        completion: { reports.append($0) }) == .sounded)
        try #require(try await i1Wait(seconds: HangGuard.seconds) { reports.values.count == 1 })
        let deliveredAt = deliveries.arrivals.first
        let renderingAtDelivery = engine.stretchCache.status(forClip: clip.id) == .rendering
        try #require(try await i1Wait(seconds: HangGuard.seconds) { !completed.value.isEmpty },
                "the whole-file render never completed")
        try await Task.sleep(for: .milliseconds(200))
        #expect(completed.value.count == 1, "the whole-file render completed \(completed.value.count)×")
        #expect(engine.stretchCache.renderCount == 1,
                "the whole-file render ran \(engine.stretchCache.renderCount)× (restarted?)")
        if let deliveredAt, let done = completed.value.first {
            #expect(deliveredAt < done, "the span waited for the whole-file render")
        }
        print("[measured] I1-F1 R8: span delivered while the whole-file render was "
              + "\(renderingAtDelivery ? "still rendering" : "already done")")

        // The span IS the whole-file render there: an untransposed history at
        // ratio 1 converges, so the fade-free middle matches to float noise.
        guard case .ready(let request) = engine.planClipSpanAudition(
            trackID: vox.id, clipID: clip.id, startSourceSeconds: 9.7, endSourceSeconds: 10.5)
        else {
            Issue.record("the whole-file render is not playable after it completed")
            return
        }
        let whole = try I1Signals.read(request.fileURL).planar[0]
        let played = I1Signals.planar(try #require(deliveries.buffers.first))[0]
        let first = StretchCurvePlan.outputFrame(forSourceSecond: 9.7, ratio: 1, sampleRate: 48_000)
        let fade = Int((ClipNoteAuditionPolicy.fadeSeconds * 48_000).rounded())
        var diff: [Float] = []
        for i in fade..<(played.count - fade) { diff.append(played[i] - whole[first + i]) }
        let residual = 20 * log10(max(1e-12, I1Signals.rms(diff[...]))
                                  / max(1e-12, I1Signals.rms(whole[(first + fade)..<(first + played.count - fade)])))
        print("[measured] I1-F1 R8 span vs whole-file render, fade-free middle: \(residual) dB")
        #expect(residual < -90, "the span render differs from the whole-file render by \(residual) dB")
        #expect(!engine.isRunning, "an audition gate started the audio hardware")
    }

    @Test("I1-F1 clipSpanRender: latest wins, the superseded render's WORK is aborted (H4 ledger) and its completion says dropped; a stale result that lands anyway never plays")
    func clipSpanRenderLatestWinsAndStaleNeverPlays() async throws {
        let note = NoteSegment(startSeconds: 2.0, endSeconds: 8.0, detectedHz: 220,
                               detectedConfidence: 0.9, pitchOffsetCents: 200)
        let (engine, vox, clip, deliveries, _) = try i1f1Engine("span-latest", seconds: 10,
                                                                edits: [note])
        let reports = I1F1Reports()
        let before = engine.clipAuditionWork.snapshot
        // Two back-to-back 6 s span renders: the first is cancelled mid-work.
        engine.auditionClipSpan(trackID: vox.id, clipID: clip.id, startSourceSeconds: 2.0,
                                endSourceSeconds: 8.0, source: .storedSpanRender,
                                completion: { reports.append($0) })
        var draftNote = note
        draftNote.pitchOffsetCents = 400
        engine.auditionClipSpan(trackID: vox.id, clipID: clip.id, startSourceSeconds: 2.5,
                                endSourceSeconds: 3.1,
                                source: .draftSpanRender(PitchEditSet(segments: [draftNote])),
                                completion: { reports.append($0) })
        try #require(try await i1Wait(seconds: HangGuard.seconds) { reports.values.count == 2 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(reports.values == [.dropped, .played(seconds: 0.6)])
        #expect(deliveries.buffers.count == 1)
        #expect(deliveries.buffers.first?.frameLength == 28_800, "the superseded span played")
        let work = engine.clipAuditionWork.snapshot
        print("[measured] I1-F1 H4 ledger after two back-to-back renders: \(work) (before \(before))")
        #expect(work.started - before.started == 2)
        #expect(work.aborted - before.aborted == 1, "the superseded render ran to the end")
        #expect(work.finished - before.finished == 1)

        // THE STALE-BUFFER GUARD ALONE: the render has FINISHED (cancellation
        // can no longer stop it) when a stop lands, just before delivery.
        let stopAt = I1Box(false)
        engine.clipAuditionBeforeDeliveryForTesting = { [weak engine] in
            if stopAt.value { engine?.stopClipSpanAudition() }
        }
        stopAt.value = true
        engine.auditionClipSpan(trackID: vox.id, clipID: clip.id, startSourceSeconds: 2.5,
                                endSourceSeconds: 3.1, source: .storedSpanRender,
                                completion: { reports.append($0) })
        try #require(try await i1Wait(seconds: HangGuard.seconds) { reports.values.count == 3 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(reports.values.last == .dropped)
        #expect(deliveries.buffers.count == 1, "a buffer superseded after its work finished still played")
        // Control: the same request with no stop in between plays.
        stopAt.value = false
        engine.auditionClipSpan(trackID: vox.id, clipID: clip.id, startSourceSeconds: 2.5,
                                endSourceSeconds: 3.1, source: .storedSpanRender,
                                completion: { reports.append($0) })
        try #require(try await i1Wait(seconds: HangGuard.seconds) { reports.values.count == 4 })
        #expect(reports.values.last == .played(seconds: 0.6))
        #expect(deliveries.buffers.count == 2)
        #expect(!engine.isRunning, "an audition gate started the audio hardware")
    }

    @Test("I1-F1 clipSpanRender: a stop, a recovery (H3) or stopAllAudition mid-render plays nothing and says dropped; a rolling transport is refused at the engine (H6)")
    func clipSpanRenderStopsRecoveryAndTransportGuard() async throws {
        let note = NoteSegment(startSeconds: 2.0, endSeconds: 8.0, detectedHz: 220,
                               detectedConfidence: 0.9, pitchOffsetCents: 200)
        let (engine, vox, clip, deliveries, _) = try i1f1Engine("span-stops", seconds: 10,
                                                                edits: [note])
        let reports = I1F1Reports()
        func request() -> AuditionOutcome {
            engine.auditionClipSpan(trackID: vox.id, clipID: clip.id, startSourceSeconds: 2.0,
                                    endSourceSeconds: 8.0, source: .storedSpanRender,
                                    completion: { reports.append($0) })
        }
        // Each stop is ISOLATED: the request, the stop, then THAT request's
        // completion and the end of its work, before anything else is asked. A
        // following request cancels the job by latest-wins and would hide a
        // stop that never happened: when this test chained the three, a plant
        // that took the stop out of `recoverEngine()` stayed green.
        // `startPlayback`/`beginTake` open with `stopClipSpanAudition()` (the
        // transport start itself needs the hardware, so it is not driven here).
        let stops: [(name: String, stop: () -> Void)] = [
            ("stopClipSpanAudition", { engine.stopClipSpanAudition() }),
            // RT review H3: a configuration change with the transport stopped.
            ("recoverEngine", { engine.recoverEngine() }),
            ("stopAllAudition", { engine.stopAllAudition() }),
        ]
        for (index, entry) in stops.enumerated() {
            let before = engine.clipAuditionWork.snapshot
            #expect(request() == .sounded, "\(entry.name)")
            entry.stop()
            try #require(try await i1Wait(seconds: HangGuard.seconds) { reports.values.count == index + 1 },
                    "\(entry.name): the request's completion never came")
            try #require(try await i1Wait(seconds: HangGuard.seconds) {
                let work = engine.clipAuditionWork.snapshot
                return work.finished + work.aborted == before.finished + before.aborted + 1
            }, "\(entry.name): the request's work never ended")
            // A result that lands anyway is delivered on a later main-actor turn.
            try await Task.sleep(for: .milliseconds(200))
            let work = engine.clipAuditionWork.snapshot
            #expect(reports.values.last == .dropped,
                    "\(entry.name) let the render play: \(reports.values)")
            #expect(work.aborted - before.aborted == 1,
                    "\(entry.name) let the render's work run to the end: \(work) (before \(before))")
            #expect(deliveries.buffers.isEmpty, "\(entry.name): a stopped render still played")
        }

        // RT review H6: the engine refuses on its own while the transport rolls.
        let startedBefore = engine.clipAuditionWork.snapshot.started
        engine.clipAuditionTransportRollingForTesting = true
        #expect(request() == .noRenderer)
        engine.clipAuditionTransportRollingForTesting = nil
        try await Task.sleep(for: .milliseconds(200))
        #expect(engine.clipAuditionWork.snapshot.started == startedBefore,
                "a refused request started work")
        #expect(reports.values.count == 3, "a refused request reported a completion")
        // Control: the same request with the transport stopped plays.
        #expect(request() == .sounded)
        try #require(try await i1Wait(seconds: HangGuard.seconds) { reports.values.count == 4 })
        #expect(reports.values.last == .played(seconds: 6.0))
        #expect(!engine.isRunning, "an audition gate started the audio hardware")
    }

    @Test("I1-F1 clipSpanRender H1: a read or render that fails is never silent — .sounded meant accepted, the completion says failed, an engine notice is posted, and nothing plays")
    func clipSpanRenderFailureIsReported() async throws {
        let note = NoteSegment(startSeconds: 0.5, endSeconds: 1.5, detectedHz: 220,
                               detectedConfidence: 0.9, pitchOffsetCents: 200)
        let (engine, vox, clip, deliveries, source) = try i1f1Engine("span-fail", seconds: 2,
                                                                     edits: [note])
        let notices = I1Box<[EngineNoticeEvent]>([])
        engine.engineNoticeHandler = { notices.value.append($0) }
        let reports = I1F1Reports()

        // 1. A span wholly past the file's end: accepted, then fails honestly,
        //    on both sources.
        #expect(engine.auditionClipSpan(trackID: vox.id, clipID: clip.id, startSourceSeconds: 5,
                                        endSourceSeconds: 5.5, source: .storedSpanRender,
                                        completion: { reports.append($0) }) == .sounded)
        try #require(try await i1Wait(seconds: HangGuard.seconds) { reports.values.count == 1 })
        var plainClip = clip
        plainClip.pitchEdits = nil
        let plain = Track(id: vox.id, name: "Vox", kind: .audio, clips: [plainClip])
        engine.tracksDidChange([plain])
        #expect(engine.auditionClipSpan(trackID: vox.id, clipID: clip.id, startSourceSeconds: 5,
                                        endSourceSeconds: 5.5, source: .playbackFile,
                                        completion: { reports.append($0) }) == .sounded)
        try #require(try await i1Wait(seconds: HangGuard.seconds) { reports.values.count == 2 })

        // 2. The source deleted after the plan: the render cannot read it.
        engine.tracksDidChange([vox])
        try FileManager.default.removeItem(at: source)
        #expect(engine.auditionClipSpan(trackID: vox.id, clipID: clip.id, startSourceSeconds: 0.6,
                                        endSourceSeconds: 1.2, source: .storedSpanRender,
                                        completion: { reports.append($0) }) == .sounded)
        try #require(try await i1Wait(seconds: HangGuard.seconds) { reports.values.count == 3 })
        try await Task.sleep(for: .milliseconds(200))

        print("[measured] I1-F1 H1 reports: \(reports.values); notices: "
              + notices.value.map { "\($0.code): \($0.message)" }.joined(separator: " | "))
        #expect(reports.values.allSatisfy { if case .failed = $0 { return true } else { return false } },
                "a failed audition reported \(reports.values)")
        #expect(notices.value.filter { $0.code == "clip-audition-failed" }.count == 3)
        #expect(notices.value.allSatisfy { $0.message.hasPrefix("That note could not be played: ") })
        #expect(deliveries.buffers.isEmpty)
        #expect(!engine.isRunning, "an audition gate started the audio hardware")
    }

    // MARK: I1-F2 (RT re-review of I1-F1: NH-A, NH-B, NH-F, the reason gap, the cap)
    //
    // Same rules as the I1-F1 gates above: filter `clipSpan` runs them, and
    // each ends by asserting the engine never ran.

    /// A 220 Hz stereo tone of `seconds` and one audio clip on it at `ratio`,
    /// carrying `edits`; an engine with its own render cache (and `detector`),
    /// its notices collected from BEFORE the graph is built.
    private func i1f2Engine(_ label: String, seconds: Double, ratio: Double = 1,
                            edits: PitchEditSet? = nil,
                            detector: PitchContourCache.Detector = .product)
        throws -> (engine: AudioEngine, track: Track, clip: Clip, source: URL,
                   notices: I1Box<[EngineNoticeEvent]>) {
        let (source, _) = try i1Tone(label, pieces: [(seconds, 220)])
        let engine = AudioEngine()
        engine.stretchCache = StretchRenderCache(directory: try I1Signals.tempDir("\(label)-cache"),
                                                 contourDetector: detector)
        let notices = I1Box<[EngineNoticeEvent]>([])
        engine.engineNoticeHandler = { notices.value.append($0) }
        // At 120 bpm a beat is 0.5 s, and the clip plays `seconds × ratio` of timeline.
        let clip = Clip(name: "lead vocal", startBeat: 0, lengthBeats: (seconds * ratio * 2).rounded(.up),
                        audioFileURL: source, stretchRatio: ratio, pitchEdits: edits)
        let track = Track(name: "Vox", kind: .audio, clips: [clip])
        return (engine, track, clip, source, notices)
    }

    @Test("I1-F2 clipSpan NH-B: on a STOPPED engine, recoverEngine(), stopClipSpanAudition() and stopAllAudition() stop the voice AT ONCE: no fade, no delayed stop scheduled")
    func clipSpanStoppedEngineStopsTheVoiceAtOnce() async throws {
        let (engine, track, _, _, _) = try i1f2Engine("nhb", seconds: 1)
        engine.tracksDidChange([track])
        let x = (0..<48_000).map { Float(0.5 * sin(2 * Double.pi * 220 * Double($0) / 48_000)) }
        let buffer = try ClipSpanAuditionReader.shape(
            [x, x], sampleRate: 48_000, gain: 1, fadeSeconds: ClipNoteAuditionPolicy.fadeSeconds,
            outputFormat: engine.graph.clipAuditionFormat, isCancelled: { false })
        let silencers: [(name: String, silence: () -> Void)] = [
            // RT review H3's path: a configuration change with the transport stopped.
            ("recoverEngine", { engine.recoverEngine() }),
            ("stopClipSpanAudition", { engine.stopClipSpanAudition() }),
            ("stopAllAudition", { engine.stopAllAudition() }),
        ]
        var started: [Bool] = []
        for entry in silencers {
            // A voice holding a buffer while the engine is stopped: a device
            // change stopped it mid-audition. The ledger is raised BEFORE
            // `play()`, so it holds whether or not `play()` raises here.
            started.append(engine.graph.playClipAudition(buffer))
            try #require(engine.graph.clipAuditionScheduled,
                         "\(entry.name): the voice holds nothing, so this proves nothing")
            let reaps = engine.clipAuditionReapsScheduledForTesting
            entry.silence()
            #expect(!engine.graph.clipAuditionScheduled, "\(entry.name) left the voice holding its buffer")
            #expect(!engine.graph.clipAuditionIsFading, "\(entry.name) faded a voice on a stopped engine")
            #expect(engine.clipAuditionReapsScheduledForTesting == reaps,
                    "\(entry.name) scheduled a delayed stop on a stopped engine")
        }
        print("[measured] I1-F2 NH-B: playClipAudition on the never-started engine returned \(started) "
              + "(true: play() did not raise; false: AVFAudio raised, caught by the barrier)")
        #expect(!engine.isRunning, "an audition gate started the audio hardware")
    }

    /// RT re-review NH-F, H1's and H3's start-side guards, with NO delivery
    /// seam: the finished buffer meets the guards a live delivery meets.
    /// ⚠️ MEASURED here first (`clipSpanStoppedEngineStopsTheVoiceAtOnce`):
    /// on an engine that never started, `play()` does NOT raise, so a voice
    /// handed a buffer on a stopped engine ACCEPTS it. H3's guard is what
    /// keeps it off; a start that fails is reached through a graph built
    /// without the voice (`playClipAudition` answers false for it exactly as
    /// for a raise).
    @Test("I1-F2 clipSpan NH-F (H3, H1): with no delivery seam a finished audition meets the live start-side guards: an engine that stopped fails 'stopped before it could play' and the voice is never handed the buffer; a voice that cannot start fails 'could not start'; each is reported and posts its notice")
    func clipSpanStartSideGuardsAreReached() async throws {
        let (engine, track, clip, _, notices) = try i1f2Engine("start-guards", seconds: 1)
        engine.tracksDidChange([track])
        let reports = I1F1Reports()
        func request(_ engine: AudioEngine) -> AuditionOutcome {
            engine.auditionClipSpan(trackID: track.id, clipID: clip.id, startSourceSeconds: 0.1,
                                    endSourceSeconds: 0.4, source: .playbackFile,
                                    completion: { reports.append($0) })
        }
        // H3: the engine stopped between the request and the delivery.
        engine.clipAuditionEngineRunningForTesting = false
        #expect(request(engine) == .sounded)
        try #require(try await i1Wait(seconds: HangGuard.seconds) { reports.values.count == 1 })
        #expect(reports.values.last == .failed(reason: "the audio engine stopped before it could play"),
                "H3: \(reports.values)")
        #expect(!engine.graph.clipAuditionScheduled, "H3: the voice was handed a buffer on a stopped engine")
        #expect(engine.clipAuditionReapsScheduledForTesting == 0,
                "a failure on a stopped engine scheduled a delayed stop")

        // H1: the engine runs, but the voice does not start: a graph built
        // without it (the override skips the request-time lane check, as it
        // skips the hardware start).
        let (laneless, _, _, _, lanelessNotices) = try i1f2Engine("start-guards-laneless", seconds: 1)
        laneless.graph.clipAuditionLaneEnabled = false
        laneless.tracksDidChange([track])
        try #require(laneless.graph.clipAuditionPlayer == nil, "the graph built the voice anyway")
        laneless.clipAuditionEngineRunningForTesting = true
        #expect(request(laneless) == .sounded)
        try #require(try await i1Wait(seconds: HangGuard.seconds) { reports.values.count == 2 })
        #expect(reports.values.last == .failed(reason: "the audition voice could not start"),
                "H1: \(reports.values)")
        let failures = (notices.value + lanelessNotices.value)
            .filter { $0.code == "clip-audition-failed" }.map(\.message)
        #expect(failures == [
            "That note could not be played: the audio engine stopped before it could play.",
            "That note could not be played: the audition voice could not start.",
        ])

        // Control: the same request through the delivery seam plays.
        engine.clipAuditionEngineRunningForTesting = nil
        let deliveries = I1Deliveries()
        engine.clipAuditionDeliveryForTesting = { deliveries.append($0) }
        #expect(request(engine) == .sounded)
        try #require(try await i1Wait(seconds: HangGuard.seconds) { reports.values.count == 3 })
        #expect(reports.values.last == .played(seconds: 0.3))
        #expect(deliveries.buffers.count == 1)
        #expect(!engine.isRunning && !laneless.isRunning, "an audition gate started the audio hardware")
    }

    @Test("I1-F2 clipSpanRender NH-A: five drag steps on a cold contour while the whole-file render detects it share ONE detection; each superseded step, already WAITING for it, ends its work while it still runs (H4 ledger), and the last plays once it lands")
    func clipSpanRenderSharesOneDetection() async throws {
        let spy = GatedContourDetector()
        defer { spy.open() }
        let set = ContourToRenderTests.hardTuneSet()
        let (engine, track, clip, source, _) = try i1f2Engine("span-nha", seconds: 1, edits: set,
                                                              detector: spy.detector())
        let deliveries = I1Deliveries()
        engine.clipAuditionDeliveryForTesting = { deliveries.append($0) }
        engine.tracksDidChange([track])
        // The whole-file render leads the detection and is held at the gate.
        try #require(try await i1Wait(seconds: HangGuard.seconds) { spy.runCount == 1 },
                "the whole-file render never started detecting, so this proves nothing")
        let entry = PitchContourCache.directory(inRenderCacheDirectory: engine.stretchCache.directory)
            .appendingPathComponent(try PitchContourCache.key(source: source, detector: spy.detector()) + ".json")
        let before = engine.clipAuditionWork.snapshot
        let reports = I1F1Reports()
        // Each step is WAITING on the held detection before the next one
        // supersedes it: the one before it has ended its work, and this one has
        // joined the flight. Bounded, never required: without the single
        // flight no step ever waits, and without a follower's cancellation no
        // superseded step ends; the counts below fail either way.
        var joined: [Bool] = []
        for step in 0..<5 {
            var draft = set
            draft.segments[0].pitchOffsetCents = -35 + Double(step) * 5
            #expect(engine.auditionClipSpan(trackID: track.id, clipID: clip.id, startSourceSeconds: 0.1,
                                            endSourceSeconds: 0.4, source: .draftSpanRender(draft),
                                            completion: { reports.append($0) }) == .sounded)
            joined.append(try await i1Wait(seconds: HangGuard.seconds) {
                let work = engine.clipAuditionWork.snapshot
                return work.started - before.started == step + 1
                    && work.aborted - before.aborted == step
                    && PitchContourCache.waiterCountForTesting(entry: entry) == 1
            })
        }
        let freed = joined.allSatisfy { $0 }
        let heldRuns = spy.runCount
        let heldWork = engine.clipAuditionWork.snapshot
        let heldReports = reports.values
        spy.open()
        try #require(try await i1Wait(seconds: HangGuard.seconds) { reports.values.count == 5 })
        try #require(try await i1Wait(seconds: HangGuard.seconds) { engine.stretchCache.status(forClip: clip.id) == .idle },
                "the whole-file render never finished")
        try await Task.sleep(for: .milliseconds(200))
        let work = engine.clipAuditionWork.snapshot
        print("[measured] I1-F2 NH-A through the engine: each step waiting before the next \(joined); "
              + "while the detection was held, \(heldRuns) detection(s), ledger \(heldWork) "
              + "(before \(before)), reports \(heldReports); after it landed \(spy.runCount) "
              + "detection(s), ledger \(work), reports \(reports.values)")
        #expect(freed, "a step never waited on the one detection, or a superseded one never ended its wait: \(joined)")
        #expect(heldRuns == 1)
        #expect(heldReports == [.dropped, .dropped, .dropped, .dropped])
        #expect(spy.runCount == 1, "the whole-file render and five drag steps ran \(spy.runCount) detections")
        #expect(reports.values == [.dropped, .dropped, .dropped, .dropped, .played(seconds: 0.3)])
        #expect(deliveries.buffers.count == 1)
        #expect(work.started - before.started == 5)
        #expect(work.aborted - before.aborted == 4)
        #expect(work.finished - before.finished == 1)
        #expect(engine.stretchCache.renderCount == 1)
        #expect(!engine.isRunning, "an audition gate started the audio hardware")
    }

    @Test("I1-F2 clipSpanRender: a span render that played its contour FALLBACK says so through the one notice the final render posts, with the same reason and the same words")
    func clipSpanRenderReportsItsContourFallback() async throws {
        let set = ContourToRenderTests.hardTuneSet()
        let (engine, track, clip, source, notices) = try i1f2Engine(
            "span-fallback", seconds: 1, edits: set, detector: ContourToRenderTests.failing)
        let deliveries = I1Deliveries()
        engine.clipAuditionDeliveryForTesting = { deliveries.append($0) }
        let completed = I1Box(0)
        engine.setClipRenderCompleteHandler { if $0 == clip.id { completed.value += 1 } }
        engine.tracksDidChange([track])
        func contourNotices() -> [EngineNoticeEvent] {
            notices.value.filter { $0.code == "clip-pitch-contour-unavailable" }
        }
        // The final render falls back, and playback says so, once.
        try #require(try await i1Wait(seconds: HangGuard.seconds) { completed.value == 1 }, "the whole-file render never landed")
        let playbackSaid = try await i1Wait(seconds: HangGuard.seconds) { contourNotices().count == 1 }
        try #require(playbackSaid, "playback never reported its fallback, so there is nothing to agree with")
        let reason = try #require(engine.stretchCache.contourShortfall(
            source: source, params: StretchRenderCache.Params(clip: clip)))
        #expect(reason.contains("planted detector failure"))
        let before = contourNotices().count

        // The span render of the same stored edits, then a draft: each played
        // its fallback, and each says so (every time, like a bounce).
        let reports = I1F1Reports()
        #expect(engine.auditionClipSpan(trackID: track.id, clipID: clip.id, startSourceSeconds: 0.1,
                                        endSourceSeconds: 0.4, source: .storedSpanRender,
                                        completion: { reports.append($0) }) == .sounded)
        try #require(try await i1Wait(seconds: HangGuard.seconds) { reports.values.count == 1 })
        var draft = set
        draft.segments[0].pitchOffsetCents = -20
        #expect(engine.auditionClipSpan(trackID: track.id, clipID: clip.id, startSourceSeconds: 0.1,
                                        endSourceSeconds: 0.4, source: .draftSpanRender(draft),
                                        completion: { reports.append($0) }) == .sounded)
        try #require(try await i1Wait(seconds: HangGuard.seconds) { reports.values.count == 2 })
        try await Task.sleep(for: .milliseconds(100))
        let posted = contourNotices()
        print("[measured] I1-F2 reason gap: playback posted \(before) contour notice(s) "
              + "(\(playbackSaid ? "as expected" : "NOT within \(Int(HangGuard.seconds)) s")); after two span renders "
              + "\(posted.count): " + posted.map(\.message).joined(separator: " | "))
        #expect(reports.values == [.played(seconds: 0.3), .played(seconds: 0.3)])
        #expect(posted.count == before + 2, "a span render that played its fallback said nothing")
        #expect(Set(posted.map(\.message)).count == 1,
                "the span and the final render say different things: \(posted.map(\.message))")
        #expect(posted.last?.message.contains(reason) == true)
        #expect(posted.last?.message.contains("'lead vocal'") == true)
        #expect(!engine.isRunning, "an audition gate started the audio hardware")
    }

    @Test("I1-F2 clipSpan cap: the 6 s cap bounds what is HEARD: through the protocol 6 heard seconds are 6 / 1.5 / 24 source seconds at ratio 1 / 4 / 0.25; at ratio 1 the audition is what it was, byte for byte; at ratio 4 a long span plays 6.0 s, not 9.6; the store reports the span that plays")
    func clipSpanCapBoundsWhatIsHeard() async throws {
        // Ratio 1: an untouched clip, 8 s.
        let (engine, plainTrack, plain, plainSource, _) = try i1f2Engine("cap-plain", seconds: 8)
        // Ratio 4: a clip with a stored note (no edit), 3 s of source.
        let (slowSource, _) = try i1Tone("cap-slow", pieces: [(3.0, 220)])
        let note = NoteSegment(startSeconds: 0.5, endSeconds: 2.8, detectedHz: 220,
                               detectedConfidence: 0.9)
        let slow = Clip(name: "slow", startBeat: 0, lengthBeats: 24, audioFileURL: slowSource,
                        stretchRatio: 4, pitchEdits: PitchEditSet(segments: [note]))
        let slowTrack = Track(name: "Slow", kind: .audio, clips: [slow])
        let store = ProjectStore(tracks: [plainTrack, slowTrack])
        store.engine = engine
        let deliveries = I1Deliveries()
        engine.clipAuditionDeliveryForTesting = { deliveries.append($0) }
        engine.tracksDidChange(store.tracks)

        // THROUGH THE PROTOCOL: a requirement the engine failed to witness
        // would answer the extension default, nil, right here.
        let asProtocol: any AudioEngineControlling = engine
        #expect(asProtocol.clipAuditionSourceSeconds(heardSeconds: 6, ratio: 1) == 6.0)
        #expect(asProtocol.clipAuditionSourceSeconds(heardSeconds: 6, ratio: 4) == 1.5)
        #expect(asProtocol.clipAuditionSourceSeconds(heardSeconds: 6, ratio: 0.25) == 24.0)
        #expect(asProtocol.clipAuditionSourceSeconds(heardSeconds: 6, ratio: 0) == nil)
        #expect(asProtocol.clipAuditionSourceSeconds(heardSeconds: .nan, ratio: 1) == nil)

        // RATIO 1, UNCHANGED: the plan is the pre-I1-F2 arithmetic bit for bit,
        // and the buffer is the pre-I1-F2 audition byte for byte.
        let reports = I1F1Reports()
        guard case .ready(let request) = engine.planClipSpanAudition(
            trackID: plainTrack.id, clipID: plain.id, startSourceSeconds: 1.0,
            endSourceSeconds: 7.9, source: .playbackFile) else {
            Issue.record("an untouched clip did not plan a read")
            return
        }
        #expect(request.endSourceSeconds.bitPattern == (1.0 + ClipNoteAuditionPolicy.maxSpanSeconds).bitPattern)
        #expect(engine.auditionClipSpan(trackID: plainTrack.id, clipID: plain.id, startSourceSeconds: 1.0,
                                        endSourceSeconds: 7.9, source: .playbackFile,
                                        completion: { reports.append($0) }) == .sounded)
        try #require(try await i1Wait(seconds: HangGuard.seconds) { reports.values.count == 1 })
        let old = try ClipSpanAuditionReader.makeBuffer(
            ClipSpanAuditionRequest(fileURL: plainSource, ratio: 1, startSourceSeconds: 1.0,
                                    endSourceSeconds: 1.0 + ClipNoteAuditionPolicy.maxSpanSeconds,
                                    gain: request.gain, fadeSeconds: ClipNoteAuditionPolicy.fadeSeconds),
            outputFormat: engine.graph.clipAuditionFormat, isCancelled: { false })
        let played = try #require(deliveries.buffers.first)
        #expect(reports.values == [.played(seconds: 6.0)])
        #expect(I1Signals.planar(played).map { $0.map(\.bitPattern) }
                == I1Signals.planar(old).map { $0.map(\.bitPattern) },
                "a ratio-1 audition is not the audition it was before the cap moved")

        // RATIO 4: 2.4 source seconds asked; 1.5 of them are 6 s heard.
        #expect(engine.auditionClipSpan(trackID: slowTrack.id, clipID: slow.id, startSourceSeconds: 0.5,
                                        endSourceSeconds: 2.9, source: .storedSpanRender,
                                        completion: { reports.append($0) }) == .sounded)
        try #require(try await i1Wait(seconds: HangGuard.seconds) { reports.values.count == 2 })
        #expect(reports.values.last == .played(seconds: 6.0),
                "at ratio 4 the audition played \(String(describing: reports.values.last))")
        #expect(deliveries.buffers.last?.frameLength == 288_000)

        // THE STORE asks the same function, so the span it reports is the span
        // that plays: the note ± 60 ms from 0.44 s, 1.5 source seconds.
        let press = try store.auditionClipNotes(clipId: slow.id, segmentIds: [note.id])
        engine.stopClipSpanAudition()
        print("[measured] I1-F2 cap: ratio 4 press span \(press.startSeconds)…\(press.endSeconds) s "
              + "(\(press.endSeconds - press.startSeconds) source s), outcome "
              + "\(String(describing: press.outcome)), reason \(String(describing: press.reason))")
        #expect(abs(press.startSeconds - 0.44) < 1e-12)
        #expect(abs((press.endSeconds - press.startSeconds) - 1.5) < 1e-12,
                "the store reported \(press.endSeconds - press.startSeconds) source seconds at ratio 4")
        #expect(!engine.isRunning, "an audition gate started the audio hardware")
    }

    // MARK: I1 latency on the user's recording (env-gated harness)

    /// MEASURED LATENCY on a real take: commit → the buffer the voice would
    /// schedule, and commit → the whole-file render complete. Env-gated: the
    /// recording is the user's and never enters the tree.
    ///
    ///     I1_LATENCY_TAKE=/path/dry.wav I1_LATENCY_OUT=/path/outdir \
    ///       ./scripts/test.sh --filter clipSpanLatencyOnTheUsersTake
    ///
    /// Builds the note table the editor would draw for the take, then edits
    /// single notes (+200 c each) through the store, the way the editor's
    /// release door does. Since I1-F1 the release does not wait for the
    /// whole-file render: it plays a SPAN RENDER of the committed note at once
    /// (`source == .spanRender`). This harness times that and the render
    /// behind it, and checks I1's own claim on the path that still makes it:
    /// a press once the render has landed plays the render, sample for sample.
    /// Each note is also measured so a fast wrong answer cannot pass: the
    /// release buffer against the press before the edit, frame by frame, each
    /// frame folded by whole octaves toward the ask (a creaky tail YIN reads
    /// an octave off is the instrument, not the render: the measurement
    /// lane's finding of 2026-09-25 against I1's median-of-YIN statistic).
    /// Writes `latency.json` and one before/after WAV pair per edited note
    /// into the out dir. Nothing plays.
    @Test("I1 latency harness on the user's take: commit → span buffer (I1-F1) and → whole-file render complete; a press after the render lands plays it byte for byte; ≥5 single-note edits (env-gated)",
          .enabled(if: ProcessInfo.processInfo.environment["I1_LATENCY_TAKE"] != nil
                   && ProcessInfo.processInfo.environment["I1_LATENCY_OUT"] != nil))
    func clipSpanLatencyOnTheUsersTake() async throws {
        let env = ProcessInfo.processInfo.environment
        let take = URL(fileURLWithPath: try #require(env["I1_LATENCY_TAKE"]))
        let outDir = URL(fileURLWithPath: try #require(env["I1_LATENCY_OUT"]))
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let wanted = max(5, Int(env["I1_LATENCY_EDITS"] ?? "") ?? 7)

        let detection = try PitchContourCache.detectWholeFile(take, .product)
        let table = PitchNoteTable.detected(from: detection)
        let takeAudio = try I1Signals.read(take)
        let takeFile = try AVAudioFile(forReading: take)
        let duration = Double(takeFile.length) / takeFile.processingFormat.sampleRate
        let clip = Clip(name: "take", startBeat: 0, lengthBeats: (duration * 4).rounded(.up),
                        audioFileURL: take, pitchEdits: table)
        let track = Track(name: "Vox", kind: .audio, clips: [clip])
        let store = ProjectStore(tracks: [track])
        let engine = AudioEngine()
        let cacheDir = outDir.appendingPathComponent("render-cache", isDirectory: true)
        try? FileManager.default.removeItem(at: cacheDir)
        engine.stretchCache = StretchRenderCache(directory: cacheDir)
        let deliveries = I1Deliveries()
        engine.clipAuditionDeliveryForTesting = { deliveries.append($0) }
        store.engine = engine
        // Timestamp the cache's commit signal, keeping the engine's forwarding.
        let renders = I1Box<[(UUID, ContinuousClock.Instant)]>([])
        let forward = engine.stretchCache.onRenderComplete
        engine.stretchCache.onRenderComplete = { id in
            renders.value.append((id, ContinuousClock.now))
            forward?(id)
        }
        engine.tracksDidChange(store.tracks)

        // Long, confident notes, spread evenly across the take.
        let candidates = table.segments.filter {
            $0.durationSeconds >= 0.30 && $0.detectedConfidence >= 0.5 && $0.detectedHz > 0
        }
        try #require(candidates.count >= 5,
                     "only \(candidates.count) notes ≥ 0.30 s in \(table.segments.count)")
        let count = min(wanted, candidates.count)
        let picked = (0..<count).map { candidates[$0 * (candidates.count - 1) / max(1, count - 1)] }

        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        let loadAtStart = loads
        func ms(_ d: Duration) -> Double {
            Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15
        }
        /// A span buffer's note interior: minus the context and 50 ms more at
        /// each end. That also leaves out the retune's ramps, which are there
        /// by design (the plan asks +1 st at a note's first frame, the full
        /// step 15 ms in, and leaves it 15 ms before the end).
        func interior(_ buffer: AVAudioPCMBuffer) -> ArraySlice<Float> {
            let samples = I1Signals.planar(buffer)[0]
            let margin = Int((ClipNoteAuditionPolicy.contextSeconds + 0.05) * 48_000)
            guard samples.count > 2 * margin + 4_096 else { return [] }
            return samples[margin..<(samples.count - margin)]
        }
        let asked = 200.0

        var rows: [[String: Any]] = []
        var commitToRender: [Double] = []
        var commitToBuffer: [Double] = []
        var shifts: [Double] = []
        var pressMismatches: [Int] = []
        var spanReleases = 0
        for (index, note) in picked.enumerated() {
            // BEFORE: press — the note as it sounds now.
            let pressAt = ContinuousClock.now
            let press = try store.auditionClipNotes(clipId: clip.id, segmentIds: [note.id])
            try #require(press.isAudible, "note \(index) press answered \(String(describing: press.reason))")
            let pressCount = deliveries.buffers.count
            try #require(try await i1Wait(seconds: 10) { deliveries.buffers.count == pressCount + 1 })
            let beforeBuffer = deliveries.buffers[pressCount]
            let pressMs = ms(deliveries.arrivals[pressCount] - pressAt)

            // COMMIT, then the release door, timed from the commit.
            let rendersBefore = renders.value.count
            let committedAt = ContinuousClock.now
            try store.setClipNotePitchOffset(clipId: clip.id, segmentId: note.id, offsetCents: asked)
            let release = try store.auditionClipNotesAfterEdit(.pitch, clipId: clip.id,
                                                               segmentIds: [note.id], enabled: true)
            if release.isAudible && release.source == .spanRender { spanReleases += 1 }
            let bufferCount = deliveries.buffers.count
            let delivered = try await i1Wait(seconds: 10) { deliveries.buffers.count > bufferCount }
            let rendered = try await i1Wait(seconds: 60) { renders.value.count > rendersBefore }
            let renderMs = rendered ? ms(renders.value[rendersBefore].1 - committedAt) : .nan
            let bufferMs = delivered ? ms(deliveries.arrivals[bufferCount] - committedAt) : .nan
            let releaseBuffer = delivered ? deliveries.buffers[bufferCount] : nil
            // One YIN band for both readings: the note before, the ask after.
            let bandLo = note.detectedHz * 0.6
            let bandHi = note.detectedHz * pow(2, asked / 1_200) * 1.7
            var heard: (median: Double, frames: Int) = (.nan, 0)
            if let releaseBuffer, releaseBuffer.frameLength == beforeBuffer.frameLength {
                heard = SpanRenderMetrics.signedShift(
                    interior(beforeBuffer), interior(releaseBuffer), sampleRate: 48_000,
                    minHz: bandLo, maxHz: bandHi, around: asked)
            }
            if rendered { commitToRender.append(renderMs) }
            if delivered { commitToBuffer.append(bufferMs) }
            if heard.median.isFinite { shifts.append(heard.median) }

            // SECOND INSTRUMENT, once the render has landed: (1) a press plays
            // the render, and that buffer IS what playback plays, byte for
            // byte in the fade-free middle (the level is unity here); (2) the
            // release's span render against that render over the same span,
            // recorded; (3) the same note read straight off the source and off
            // the render, frame by frame; (4) what the product ASKED for across
            // the same interior (the contour-free curve form).
            var renderMismatches = -1
            var releaseVsRenderDb = Double.nan
            var direct: (median: Double, frames: Int) = (.nan, 0)
            var askedMedian = Double.nan
            var askedMin = Double.nan
            let lo = Int(((note.startSeconds + 0.05) * takeAudio.sampleRate).rounded())
            let hi = Int(((note.endSeconds - 0.05) * takeAudio.sampleRate).rounded())
            if rendered, case .ready(let request) = engine.planClipSpanAudition(
                trackID: track.id, clipID: clip.id, startSourceSeconds: release.startSeconds,
                endSourceSeconds: release.endSeconds) {
                let renderAudio = try I1Signals.read(request.fileURL)
                let renderMono = renderAudio.planar[0]
                let againCount = deliveries.buffers.count
                let again = try store.auditionClipNotes(clipId: clip.id, segmentIds: [note.id])
                if renderAudio.sampleRate == 48_000, again.isAudible, again.source == .render,
                   try await i1Wait(seconds: 10, { deliveries.buffers.count > againCount }) {
                    let first = StretchCurvePlan.outputFrame(
                        forSourceSecond: again.startSeconds, ratio: request.ratio,
                        sampleRate: renderAudio.sampleRate)
                    let fade = Int((ClipNoteAuditionPolicy.fadeSeconds * 48_000).rounded())
                    let played = I1Signals.planar(deliveries.buffers[againCount])[0]
                    renderMismatches = 0
                    for i in fade..<max(fade, played.count - fade) {
                        if first + i >= renderMono.count
                            || played[i].bitPattern != renderMono[first + i].bitPattern {
                            renderMismatches += 1
                        }
                    }
                    if let releaseBuffer {
                        let spanned = I1Signals.planar(releaseBuffer)[0]
                        let from = StretchCurvePlan.outputFrame(
                            forSourceSecond: release.startSeconds, ratio: request.ratio,
                            sampleRate: renderAudio.sampleRate)
                        let end = min(spanned.count - fade, renderMono.count - from)
                        if end > fade {
                            releaseVsRenderDb = SpanRenderMetrics.residualDb(
                                Array(spanned[fade..<end]), Array(renderMono[(from + fade)..<(from + end)]))
                        }
                    }
                }
                if hi - lo > 4_096, hi <= renderMono.count, hi <= takeAudio.planar[0].count {
                    direct = SpanRenderMetrics.signedShift(
                        takeAudio.planar[0][lo..<hi], renderMono[lo..<hi],
                        sampleRate: takeAudio.sampleRate, minHz: bandLo, maxHz: bandHi,
                        around: asked)
                }
            }
            if let set = store.tracks[0].clips[0].pitchEdits, hi > lo,
               let plan = StretchCurvePlan.make(editSet: set, clipPitchShiftSemitones: 0,
                                                sampleRate: takeAudio.sampleRate, ratio: 1) {
                let askedCurve = stride(from: lo, to: hi, by: 48)
                    .map { plan.semitones(atOutputFrame: $0) }.sorted()
                if !askedCurve.isEmpty {
                    askedMedian = askedCurve[askedCurve.count / 2]
                    askedMin = askedCurve[0]
                }
            }
            if renderMismatches >= 0 { pressMismatches.append(renderMismatches) }

            let name = String(format: "note-%02d", index)
            try I1Signals.write([I1Signals.planar(beforeBuffer)[0]], sampleRate: 48_000,
                                to: outDir.appendingPathComponent("\(name)-before.wav"))
            if let releaseBuffer {
                try I1Signals.write([I1Signals.planar(releaseBuffer)[0]], sampleRate: 48_000,
                                    to: outDir.appendingPathComponent("\(name)-after.wav"))
            }
            let line = String(format: "note %d %.3f-%.3f s (%.1f Hz): release %@ (%@) | commit→buffer %.0f ms | commit→render %.0f ms | press→buffer %.1f ms | heard %+.1f c over %d frames (release vs press, octave-folded) | direct source→render %+.1f c over %d frames | asked median %+.3f st (min %+.3f) | release span vs render %.1f dB | press-after-render ≠ render samples %d",
                              index, note.startSeconds, note.endSeconds, note.detectedHz,
                              (release.reason?.rawValue ?? "sounded") as NSString,
                              release.source.rawValue as NSString, bufferMs, renderMs, pressMs,
                              heard.median, heard.frames, direct.median, direct.frames,
                              askedMedian, askedMin, releaseVsRenderDb, renderMismatches)
            print("i1-latency| \(line)")
            func num(_ x: Double?) -> Any {
                if let x, x.isFinite { return x }
                return NSNull()
            }
            rows.append([
                "note": index, "startSeconds": note.startSeconds, "endSeconds": note.endSeconds,
                "detectedHz": note.detectedHz, "release": release.reason?.rawValue ?? "sounded",
                "releaseSource": release.source.rawValue,
                "commitToRenderMs": num(renderMs), "commitToBufferMs": num(bufferMs),
                "pressToBufferMs": pressMs,
                "shiftCents": num(heard.median), "shiftFrames": heard.frames,
                "directSourceToRenderCents": num(direct.median), "directFrames": direct.frames,
                "askedSemitonesMedian": num(askedMedian), "askedSemitonesMin": num(askedMin),
                "releaseSpanVsRenderDb": num(releaseVsRenderDb),
                "pressAfterRenderMismatchedSamples": renderMismatches,
                "files": releaseBuffer != nil ? ["\(name)-before.wav", "\(name)-after.wav"]
                                             : ["\(name)-before.wav"],
            ])
        }

        func median(_ x: [Double]) -> Double {
            let s = x.sorted()
            return s.isEmpty ? .nan : (s.count % 2 == 1 ? s[s.count / 2]
                                       : (s[s.count / 2 - 1] + s[s.count / 2]) / 2)
        }
        getloadavg(&loads, 3)
        func finite(_ x: Double) -> Any { x.isFinite ? x : NSNull() }
        let summary: [String: Any] = [
            "take": take.path, "takeSeconds": duration,
            "notesInTable": table.segments.count, "notesEdited": picked.count,
            "renderedEdits": commitToRender.count, "deliveredEdits": commitToBuffer.count,
            "spanRenderReleases": spanReleases,
            // JSONSerialization raises on NaN: every summary number goes through
            // `finite`, which writes null instead.
            "commitToRenderMs": ["median": finite(median(commitToRender)),
                                 "worst": finite(commitToRender.max() ?? .nan),
                                 "all": commitToRender],
            "commitToBufferMs": ["median": finite(median(commitToBuffer)),
                                 "worst": finite(commitToBuffer.max() ?? .nan),
                                 "all": commitToBuffer],
            "shiftCents": ["median": finite(median(shifts)), "all": shifts],
            "renderWaitSeconds": ClipNoteAuditionPolicy.renderWaitSeconds,
            "debounceMilliseconds": StretchRenderCache.debounceMilliseconds,
            "loadAverageAtStart": loadAtStart, "loadAverageAtEnd": loads,
            "edits": rows,
        ]
        let json = try JSONSerialization.data(withJSONObject: summary,
                                              options: [.prettyPrinted, .sortedKeys])
        try json.write(to: outDir.appendingPathComponent("latency.json"))
        print(String(format: "i1-latency| SUMMARY %d edits of a %.1f s take (%d released as span renders): commit→buffer median %.0f ms, worst %.0f ms; commit→render median %.0f ms, worst %.0f ms; heard median %+.1f c; load %.2f → %.2f",
                     picked.count, duration, spanReleases, median(commitToBuffer),
                     commitToBuffer.max() ?? .nan, median(commitToRender),
                     commitToRender.max() ?? .nan, median(shifts), loadAtStart[0], loads[0]))

        #expect(commitToRender.count == picked.count, "an edit's render never completed")
        #expect(commitToBuffer.count == picked.count, "an edit's audition never played")
        #expect(spanReleases == picked.count,
                "\(picked.count - spanReleases) releases did not play a span render")
        // I1's claim, per note, on the path that still makes it: what a press
        // plays once the render has landed IS what playback plays, sample for
        // sample. The pitch is asserted on the MEDIAN edit (a real voice's
        // per-note reading also carries the singer's glides), and every note's
        // reading is recorded.
        #expect(pressMismatches.count == picked.count,
                "\(picked.count - pressMismatches.count) edits could not be byte-compared")
        #expect(pressMismatches.allSatisfy { $0 == 0 },
                "a press after the render differed from what playback plays: \(pressMismatches)")
        #expect(shifts.count == picked.count, "an edit could not be read: \(shifts)")
        #expect(abs(median(shifts) - asked) <= 30, "the edits were heard at \(median(shifts)) c, not +200 c")
        #expect(!engine.isRunning, "an audition gate started the audio hardware")
    }

    // MARK: I1-F1 latency through the engine (env-gated harness)

    /// MEASURED, through the store and the real engine (the delivery seam; no
    /// device): a DRAG STEP (`previewClipNotePitchDraft`, snapped) → the
    /// buffer the voice would schedule, p50/p95/max over ≥ 50 steps; a
    /// continuous free (⌥) drag's update rate; and a RELEASE (commit, then
    /// `auditionClipNotesAfterEdit`) → buffer, next to the whole-file render's
    /// own commit → complete. Then, off the clock, what each step and release
    /// PLAYED (octave-folded YIN against the note at 0 c), and R11: ms of
    /// render per second of span at the primitive, mono and stereo. On the
    /// user's take (`I1F1_TAKE`, optional) and a synthetic 300 s voice-like
    /// take (generated in a temp dir).
    ///
    ///     I1F1_TAKE="$DUR/take/dry-norm.wav" I1F1_LATENCY_OUT="$DUR/I1-F1" \
    ///       ./scripts/test.sh --filter spanRenderLatencyThroughTheEngine
    @Test("I1-F1 latency harness through the engine: drag step → buffer (≥50 steps), free-drag update rate, release → buffer vs whole-file render, what each played, R11 per second of span; on the user's take and a synthetic 300 s take (env-gated)",
          .enabled(if: ProcessInfo.processInfo.environment["I1F1_LATENCY_OUT"] != nil))
    func spanRenderLatencyThroughTheEngine() async throws {
        let env = ProcessInfo.processInfo.environment
        let outDir = URL(fileURLWithPath: try #require(env["I1F1_LATENCY_OUT"]))
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let scratch = try I1Signals.tempDir("i1f1-latency")
        defer { try? FileManager.default.removeItem(at: scratch) }
        func ms(_ d: Duration) -> Double {
            Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15
        }
        func stats(_ x: [Double]) -> [String: Double] {
            let s = x.sorted()
            func q(_ p: Double) -> Double {
                s.isEmpty ? .nan : s[min(s.count - 1, Int((p * Double(s.count - 1)).rounded()))]
            }
            return ["n": Double(s.count), "p50": q(0.5), "p95": q(0.95), "max": s.last ?? .nan]
        }

        var takes: [(label: String, url: URL, table: PitchEditSet)] = []
        if let path = env["I1F1_TAKE"] {
            let url = URL(fileURLWithPath: path)
            let detection = try PitchContourCache.detectWholeFile(url, .product)
            takes.append(("user-33s", url, PitchNoteTable.detected(from: detection)))
        }
        let synthetic = scratch.appendingPathComponent("synthetic-300s.wav")
        let voice = SpanRenderSignals.voice(seconds: 300, sampleRate: 48_000)
        try I1Signals.write([voice.samples], sampleRate: 48_000, to: synthetic)
        takes.append(("synthetic-300s", synthetic, PitchEditSet(segments: voice.notes)))

        var report: [String: Any] = [:]
        var stepP95: [String: Double] = [:]
        for (label, url, table) in takes {
            var loads = [Double](repeating: 0, count: 3)
            getloadavg(&loads, 3)
            let loadAtStart = loads
            let file = try AVAudioFile(forReading: url)
            let seconds = Double(file.length) / file.processingFormat.sampleRate
            let clip = Clip(name: label, startBeat: 0, lengthBeats: (seconds * 2).rounded(.up),
                            audioFileURL: url, pitchEdits: table)
            let track = Track(name: "Vox", kind: .audio, clips: [clip])
            let store = ProjectStore(tracks: [track])
            let engine = AudioEngine()
            engine.stretchCache = StretchRenderCache(
                directory: scratch.appendingPathComponent("cache-\(label)", isDirectory: true))
            let deliveries = I1Deliveries()
            engine.clipAuditionDeliveryForTesting = { deliveries.append($0) }
            store.engine = engine
            let renders = I1Box<[ContinuousClock.Instant]>([])
            let forward = engine.stretchCache.onRenderComplete
            engine.stretchCache.onRenderComplete = { id in
                renders.value.append(.now)
                forward?(id)
            }
            engine.tracksDidChange(store.tracks)
            let candidates = table.segments.filter {
                $0.durationSeconds >= 0.30 && $0.detectedConfidence >= 0.5 && $0.detectedHz > 0
            }
            try #require(candidates.count >= 8)
            let notes = (0..<8).map { candidates[$0 * (candidates.count - 1) / 7] }

            // DRAG: 8 snapped steps on each of 8 notes spread across the take.
            var steps: [Double] = []
            var stepBuffer: [UUID: [Int: AVAudioPCMBuffer]] = [:]
            for note in notes {
                for (step, cents) in [100.0, 200, 300, 200, 100, 0, -100, 0].enumerated() {
                    let before = deliveries.buffers.count
                    let t0 = ContinuousClock.now
                    let result = try store.previewClipNotePitchDraft(
                        clipId: clip.id, offsets: [NotePitchOffset(segmentId: note.id, offsetCents: cents)],
                        snapped: true, enabled: true)
                    try #require(result.isAudible, "\(label): a step answered \(String(describing: result.reason))")
                    try #require(try await i1Wait(seconds: 10) { deliveries.buffers.count > before })
                    steps.append(ms(deliveries.arrivals[before] - t0))
                    stepBuffer[note.id, default: [:]][step] = deliveries.buffers[before]
                }
            }

            // FREE DRAG: 3 s of 120 Hz pointer ticks, +2 c per tick.
            let freeNote = notes[3]
            let freeBefore = deliveries.buffers.count
            let freeStart = ContinuousClock.now
            var tick = 0
            while ContinuousClock.now - freeStart < .seconds(3) {
                tick += 1
                _ = try store.previewClipNotePitchDraft(
                    clipId: clip.id,
                    offsets: [NotePitchOffset(segmentId: freeNote.id, offsetCents: Double(tick) * 2)],
                    snapped: false, enabled: true)
                try await Task.sleep(for: .milliseconds(8))
            }
            let freeSeconds = Double(ms(ContinuousClock.now - freeStart)) / 1_000
            _ = try await i1Wait(seconds: 5) { !store.clipNoteAudition.hasQueuedDraft }
            try await Task.sleep(for: .milliseconds(300))
            let freeDeliveries = deliveries.buffers.count - freeBefore
            let freeArrivals = Array(deliveries.arrivals[freeBefore...])
            let gaps = zip(freeArrivals.dropFirst(), freeArrivals).map { ms($0 - $1) }

            // RELEASE: commit +200 c on 5 notes; span buffer vs whole-file render.
            var releases: [Double] = []
            var wholeFile: [Double] = []
            var releaseBuffer: [UUID: AVAudioPCMBuffer] = [:]
            for note in notes.prefix(5) {
                let before = deliveries.buffers.count
                let rendersBefore = renders.value.count
                let t0 = ContinuousClock.now
                try store.setClipNotePitchOffset(clipId: clip.id, segmentId: note.id, offsetCents: 200)
                let result = try store.auditionClipNotesAfterEdit(.pitch, clipId: clip.id,
                                                                  segmentIds: [note.id], enabled: true)
                try #require(result.source == .spanRender && result.isAudible,
                             "\(label): the release answered \(result)")
                try #require(try await i1Wait(seconds: 10) { deliveries.buffers.count > before })
                releases.append(ms(deliveries.arrivals[before] - t0))
                releaseBuffer[note.id] = deliveries.buffers[before]
                // Let the whole-file render finish before the next release, and time it.
                if try await i1Wait(seconds: 120, { renders.value.count > rendersBefore }) {
                    wholeFile.append(ms(renders.value[rendersBefore] - t0))
                }
            }
            getloadavg(&loads, 3)

            // WHAT PLAYED, after the clock stops (so it cannot slow a step): a
            // fast wrong answer must not pass. Per note, the +300 c and the
            // −100 c steps against the first 0 c step, and each release against
            // the last 0 c step, frame by frame over the note's interior (the
            // context and 50 ms more trimmed, which also drops the retune's
            // 15 ms ramps), each frame folded by octaves toward the ask.
            func interior(_ buffer: AVAudioPCMBuffer) -> ArraySlice<Float> {
                let samples = I1Signals.planar(buffer)[0]
                let margin = Int((ClipNoteAuditionPolicy.contextSeconds + 0.05) * 48_000)
                guard samples.count > 2 * margin + 4_096 else { return [] }
                return samples[margin..<(samples.count - margin)]
            }
            func heard(_ reference: AVAudioPCMBuffer?, _ test: AVAudioPCMBuffer?, _ note: NoteSegment,
                       around cents: Double) -> Double {
                guard let reference, let test, reference.frameLength == test.frameLength else { return .nan }
                return SpanRenderMetrics.signedShift(
                    interior(reference), interior(test), sampleRate: 48_000,
                    minHz: note.detectedHz * pow(2, -100.0 / 1_200) * 0.6,
                    maxHz: note.detectedHz * pow(2, 300.0 / 1_200) * 1.7, around: cents).median
            }
            var heardUp: [Double] = []
            var heardDown: [Double] = []
            var heardRelease: [Double] = []
            for note in notes {
                let buffers = stepBuffer[note.id] ?? [:]
                heardUp.append(heard(buffers[5], buffers[2], note, around: 300))
                heardDown.append(heard(buffers[5], buffers[6], note, around: -100))
                if let released = releaseBuffer[note.id] {
                    heardRelease.append(heard(buffers[7], released, note, around: 200))
                }
            }
            func middle(_ x: [Double]) -> Double {
                let s = x.filter(\.isFinite).sorted()
                return s.isEmpty ? .nan : s[s.count / 2]
            }
            func rounded(_ x: [Double]) -> String {
                x.map { $0.isFinite ? String(format: "%+.0f", $0) : "nan" }.joined(separator: " ")
            }
            print("i1f1-latency| \(label) heard (octave-folded YIN, per note): +300 c steps \(rounded(heardUp)); −100 c steps \(rounded(heardDown)); +200 c releases \(rounded(heardRelease))")
            #expect(abs(middle(heardUp) - 300) <= 30, "\(label): the +300 c steps played \(heardUp)")
            #expect(abs(middle(heardDown) + 100) <= 30, "\(label): the −100 c steps played \(heardDown)")
            #expect(abs(middle(heardRelease) - 200) <= 30, "\(label): the releases played \(heardRelease)")
            func finite(_ x: [Double]) -> [Any] { x.map { $0.isFinite ? $0 as Any : NSNull() } }

            // R11: ms of render per second of span at the primitive, mono and
            // stereo, at the 5th note (deep in the take), median of 5 each.
            let takeAudio = try I1Signals.read(url)
            let stereoURL = scratch.appendingPathComponent("\(label)-stereo.wav")
            try I1Signals.write([takeAudio.planar[0], takeAudio.planar[0]],
                                sampleRate: takeAudio.sampleRate, to: stereoURL)
            let deep = notes[4]
            var edited = table
            if let i = edited.segments.firstIndex(where: { $0.id == deep.id }) {
                edited.segments[i].pitchOffsetCents = 200
            }
            let r11Params = StretchRenderCache.Params(ratio: 1, semitones: 0, formantPreserve: false,
                                                      pitchEdits: edited)
            var r11: [String: Double] = [:]
            for (kind, sourceURL) in [("mono", url), ("stereo", stereoURL)] {
                let spanSource = try StretchRenderCache.SpanSource.open(sourceURL)
                for spanSeconds in [0.6, 6.0] {
                    let start = Int((deep.startSeconds * takeAudio.sampleRate).rounded())
                    let frames = start..<min(spanSource.frames,
                                             start + Int(spanSeconds * takeAudio.sampleRate))
                    var times: [Double] = []
                    for _ in 0..<5 {
                        let t0 = ContinuousClock.now
                        _ = try StretchRenderCache.renderOutputFrames(
                            frames, of: spanSource, params: r11Params,
                            renderCacheDirectory: engine.stretchCache.directory,
                            detector: .product, isCancelled: { false })
                        times.append(ms(ContinuousClock.now - t0))
                    }
                    r11["\(kind) \(spanSeconds) s"] = SpanRenderMetrics.percentile(times, 0.5)
                        / (Double(frames.count) / takeAudio.sampleRate)
                }
            }
            print("i1f1-latency| \(label) R11 ms of render per second of span at \(deep.startSeconds) s (median of 5): \(r11.sorted { $0.key < $1.key })")

            let row: [String: Any] = [
                "takeSeconds": seconds, "dragStepMs": stats(steps), "dragStepsAll": steps,
                "r11MsPerSecondOfSpan": r11,
                "heardCents": ["plus300Steps": finite(heardUp), "minus100Steps": finite(heardDown),
                               "plus200Releases": finite(heardRelease)],
                "freeDrag": ["seconds": freeSeconds, "ticks": tick, "buffers": freeDeliveries,
                             "updatesPerSecond": Double(freeDeliveries) / freeSeconds,
                             "gapBetweenBuffersMs": stats(gaps)],
                "releaseToBufferMs": stats(releases), "releaseAll": releases,
                "commitToWholeFileRenderMs": stats(wholeFile),
                "loadAverageAtStart": loadAtStart, "loadAverageAtEnd": loads,
            ]
            report[label] = row
            let s = stats(steps)
            stepP95[label] = s["p95"] ?? .nan
            let r = stats(releases)
            let w = stats(wholeFile)
            print(String(format: "i1f1-latency| %@ (%.1f s): drag step → buffer p50 %.1f / p95 %.1f / max %.1f ms over %d steps; free drag %d buffers in %.1f s (%.1f /s, gap p50 %.0f ms); release → buffer p50 %.1f / max %.1f ms vs commit → whole-file render p50 %.0f ms; load %.2f → %.2f",
                         label, seconds, s["p50"] ?? .nan, s["p95"] ?? .nan, s["max"] ?? .nan,
                         steps.count, freeDeliveries, freeSeconds, Double(freeDeliveries) / freeSeconds,
                         stats(gaps)["p50"] ?? .nan, r["p50"] ?? .nan, r["max"] ?? .nan,
                         w["p50"] ?? .nan, loadAtStart[0], loads[0]))
            #expect(!engine.isRunning, "an audition gate started the audio hardware")
        }
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: outDir.appendingPathComponent("latency.json"))
        for (label, p95) in stepP95 {
            #expect(p95 < 150, "\(label): drag step p95 \(p95) ms")
        }
    }
}

/// REPOINT_DIAG (I1-F2 follow-up): when one of this file's YIN tails ran,
/// how long it took and where. Off by default, and then it prints nothing.
private enum RepointDiagYin {
    static let enabled = ProcessInfo.processInfo.environment["REPOINT_DIAG"] != nil

    static func report(_ label: String, from start: Date, ranOn place: String) {
        guard enabled else { return }
        let end = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        print(String(format: "repoint-diag| YIN tail %@: %.1f ms %@, %@ → %@", label,
                     end.timeIntervalSince(start) * 1_000, place,
                     formatter.string(from: start), formatter.string(from: end)))
    }
}
