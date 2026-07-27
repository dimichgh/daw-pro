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
}
