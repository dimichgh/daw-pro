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
            tempoBPM: 120, ticksToSeconds: 1e-9)
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
}
