import CoreMIDI
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// One serialized in-process integration pass over the REAL CoreMIDI stack:
/// a virtual source (`MIDISourceCreateWithProtocol`) is enumerated by the
/// manager's hot-plug path, `MIDIReceivedEventList` drives the UMP receive
/// block, and events land in the capture ring / capture session. Gracefully
/// skips when CoreMIDI is unavailable (sandboxed CI without a MIDI server).
@MainActor
@Suite("MIDI input manager — CoreMIDI integration", .serialized)
struct MIDIInputManagerTests {
    /// Polls `condition` on the main actor until true or ~2 s elapse.
    private func poll(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func noteWord(on: Bool, pitch: UInt32, velocity: UInt32) -> UInt32 {
        (0x2 << 28) | ((on ? 0x90 : 0x80) << 16) | (pitch << 8) | velocity
    }

    private func send(words: [UInt32], from source: MIDIEndpointRef) {
        var eventList = MIDIEventList()
        let packet = MIDIEventListInit(&eventList, ._1_0)
        _ = MIDIEventListAdd(&eventList, MemoryLayout<MIDIEventList>.size,
                             packet, mach_absolute_time(), words.count, words)
        MIDIReceivedEventList(source, &eventList)
    }

    @Test("virtual source: hot-plug enumeration, UMP receive, capture delivery")
    func virtualSourceEndToEnd() async throws {
        let manager = MIDIInputManager()
        guard manager.start() else {
            // Sandboxed/CI environment without a MIDI server — nothing to test.
            print("SKIP: MIDIClientCreate failed — CoreMIDI unavailable in this environment")
            return
        }
        defer { manager.dispose() }

        // Our own client owns the virtual source (unique name per run).
        var sourceClient = MIDIClientRef()
        guard MIDIClientCreateWithBlock("DAWProTest" as CFString, &sourceClient, nil) == noErr else {
            print("SKIP: test MIDIClientCreate failed")
            return
        }
        defer { MIDIClientDispose(sourceClient) }
        let sourceName = "DAWProTest-\(ProcessInfo.processInfo.processIdentifier)"
        var source = MIDIEndpointRef()
        guard MIDISourceCreateWithProtocol(sourceClient, sourceName as CFString,
                                           ._1_0, &source) == noErr else {
            print("SKIP: MIDISourceCreateWithProtocol failed")
            return
        }
        defer { MIDIEndpointDispose(source) }

        // (1) Hot-plug: the notify block re-enumerates on the main actor and
        // the manager omni-connects the new source.
        await poll { manager.devices.contains { $0.name == sourceName } }
        let device = try #require(manager.devices.first { $0.name == sourceName })
        #expect(device.isVirtual)
        #expect(device.isOnline)

        // (2) Receive path: UMP words → parser → capture ring → session.
        let session = MIDICaptureSession(
            anchorHostTime: mach_absolute_time(), anchorBeats: 0,
            tempoMap: TempoMap(constantBPM: 120), ticksToSeconds: 1e-9)
        manager.captureSession = session
        let countBefore = manager.eventCount
        send(words: [noteWord(on: true, pitch: 60, velocity: 100)], from: source)
        send(words: [noteWord(on: false, pitch: 60, velocity: 0)], from: source)
        await poll { manager.eventCount >= countBefore + 2 }
        #expect(manager.eventCount >= countBefore + 2)

        manager.drainCaptureRing()
        let result = session.finish(atBeat: 4)
        manager.captureSession = nil
        #expect(result.notes.count == 1)
        #expect(result.notes.first?.pitch == 60)
        #expect(result.notes.first?.velocity == 100)
        #expect(!result.droppedEvents)
    }

    // MARK: - The m28-knob controller feed

    /// ⭐ **THE SEAM, ASSERTED ON THE REAL TYPE, WITH NO CoreMIDI AT ALL.**
    ///
    /// The manager is built but never `start()`ed, so no client is created and
    /// **no MIDI device of the user's is opened, claimed or reconfigured**.
    /// Events are pushed straight onto `rtContext.captureRing` — the same ring
    /// the receive thread is the single producer of — and `drainCaptureRing()`
    /// is called by hand, which is exactly what the ~30 Hz task does. So this
    /// covers the whole receive-thread → main-actor hop without a knob, and a
    /// gate that needed a physical knob would be a flake generator.
    ///
    /// Three things are pinned here, and every one of them was a way to ship
    /// something that looked fine and did nothing:
    ///
    /// 1. controller changes reach the observer, translated (`pitch` ≡
    ///    controller number, `velocity` ≡ value, under the §4.1 one-data-rule);
    /// 2. NOTES do not — the pad must not be steered by playing a key;
    /// 3. **the observer is still called when nothing arrived.** That empty call
    ///    is the idle tick a knob gesture releases on. Without it a mapped
    ///    gesture never ends and a live preview stays parked on the instrument.
    @Test("controller feed: CC reaches the observer, notes do not, and idle still ticks")
    func controlChangeObserverDeliveryNeedsNoMIDIClient() {
        let manager = MIDIInputManager()
        var passes: [[MIDIControlChangeEvent]] = []
        manager.controlChangeObserver = { passes.append($0) }

        // An EMPTY drain still ticks — the idle beat.
        manager.drainCaptureRing()
        #expect(passes == [[]])

        // A note and a controller change, in that order, on the one ring.
        manager.rtContext.captureRing.push(
            LiveMIDIEvent(hostTime: 7, source: 42, kind: ScheduledMIDIEvent.noteOn,
                          pitch: 60, velocity: 100, channel: 0))
        manager.rtContext.captureRing.push(
            LiveMIDIEvent(hostTime: 9, source: 42, kind: ScheduledMIDIEvent.controlChange,
                          pitch: 74, velocity: 96, channel: 5))
        manager.drainCaptureRing()

        #expect(passes.count == 2)
        // `dropFirst().first ?? []` rather than `passes[1]`: when the idle tick
        // is deleted (the plant) this must FAIL, not TRAP — a trapping test
        // takes the whole run down with it and the other assertions never
        // report. Learned the hard way while planting exactly that defect.
        let delivered = passes.dropFirst().first ?? []
        #expect(delivered.count == 1, "the note must not reach the mapping layer")
        #expect(delivered.first?.controller == 74)
        #expect(delivered.first?.value == 96)
        #expect(delivered.first?.channel == 5)
        #expect(delivered.first?.sourceID == 42)
        #expect(delivered.first?.hostTime == 9)

        // Disposal kills the feed: a disposed manager must not keep an external
        // gesture believing the hand is still on the knob.
        manager.dispose()
        #expect(manager.controlChangeObserver == nil)
    }

    /// ⛔ **THE MAPPED CC IS NOT SWALLOWED, AND THAT IS DOCUMENTED POLICY.**
    ///
    /// A CC routed to a pad target STILL reaches the take's controller lanes and
    /// still fans out to armed instrument tracks through live thru. Filtering it
    /// would mean reading the mapping table on the CoreMIDI RECEIVE THREAD — an
    /// atomically published snapshot and a render-path change — to hide a
    /// controller the built-in sampler already ignores.
    ///
    /// This pins the ORDER that makes it true: the capture session ingests
    /// first, the observer is fed second, from the same pop.
    @Test("a mapped CC still lands in the take — the observer is a tap, not a filter")
    func theControllerObserverDoesNotSwallowTheEvent() {
        let manager = MIDIInputManager()
        var observed: [MIDIControlChangeEvent] = []
        manager.controlChangeObserver = { observed.append(contentsOf: $0) }
        let session = MIDICaptureSession(
            anchorHostTime: 0, anchorBeats: 0,
            tempoMap: TempoMap(constantBPM: 120), ticksToSeconds: 1e-9)
        manager.captureSession = session
        defer { manager.dispose() }

        manager.rtContext.captureRing.push(
            LiveMIDIEvent(hostTime: 1, source: 42, kind: ScheduledMIDIEvent.controlChange,
                          pitch: 74, velocity: 96, channel: 0))
        manager.drainCaptureRing()

        // The mapping layer saw it…
        #expect(observed.map(\.controller) == [74])
        // …AND the take recorded it. Both, from one event.
        let result = session.finish(atBeat: 4)
        manager.captureSession = nil
        let lane = result.controllerLanes.first { $0.type == .cc(controller: 74) }
        #expect(lane != nil, "the take must still carry the controller the pad is mapped to")
        #expect(lane?.points.contains { $0.value == 96 } == true)
    }

    /// ⚠️ **THE VACUITY GUARD** (the `theRealEngineImplementsTheControllerPreview`
    /// precedent). `setControlChangeObserver` has a SILENT default on
    /// `AudioEngineControlling`: an `AudioEngine` that forgot to override it
    /// would discard every event, mapped controls would do nothing, and every
    /// map- and pad-layer test in this milestone would still pass, because both
    /// of those layers are written to work against an engine with no MIDI.
    ///
    /// Passes with zero MIDI devices connected and never sends to hardware; the
    /// engine is torn down immediately.
    @Test("the REAL engine overrides the silent controller-observer default")
    func theRealEngineImplementsTheControlChangeObserver() {
        let engine = AudioEngine()
        defer { engine.shutdown() }
        #expect(!engine.hasControlChangeObserverForTesting)

        engine.setControlChangeObserver { _ in }
        #expect(engine.hasControlChangeObserverForTesting,
                "the real engine must OVERRIDE the protocol's discarding default")

        engine.setControlChangeObserver(nil)
        #expect(!engine.hasControlChangeObserverForTesting)
    }
}
