import Foundation
import Testing
@testable import DAWCore

// Reuses fakes already defined in the DAWCoreTests target:
//   FakeMedia (ImportTests.swift), FakeEngine (CoreTests.swift).

@MainActor
@Suite("ProjectStore — instrument selection")
struct InstrumentStoreTests {
    private func projectError(_ body: () throws -> Void) -> ProjectError? {
        do { try body(); return nil }
        catch let error as ProjectError { return error }
        catch { Issue.record("unexpected error type: \(error)"); return nil }
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("instrument-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // 1.
    @Test("setInstrument overlays fields, returns the resolved descriptor, and stores it")
    func setStoresResolvedDescriptor() throws {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)
        #expect(store.tracks[0].instrument == nil)  // nil ⇒ default until set

        let resolved = try #require(try store.setInstrument(
            id: inst.id, kind: .polySynth, waveform: .square,
            attack: 0.02, cutoffHz: 5_000, gain: 0.5
        ))
        #expect(resolved.kind == .polySynth)
        #expect(resolved.polySynth.waveform == .square)
        #expect(resolved.polySynth.attack == 0.02)
        #expect(resolved.polySynth.cutoffHz == 5_000)
        #expect(resolved.polySynth.gain == 0.5)
        // Untouched fields fall back to the default descriptor's values.
        #expect(resolved.polySynth.decay == 0.08)
        #expect(resolved.polySynth.sustain == 0.7)
        #expect(resolved.polySynth.release == 0.15)
        #expect(resolved.polySynth.resonance == 0.1)
        // Stored on the track exactly as returned.
        #expect(store.tracks[0].instrument == resolved)
    }

    // 2.
    @Test("setInstrument undo/redo restores the prior descriptor under 'Change Instrument'")
    func undoRedo() throws {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)

        try store.setInstrument(id: inst.id, waveform: .triangle)
        #expect(store.undoLabel == "Change Instrument")
        #expect(store.tracks[0].instrument?.polySynth.waveform == .triangle)

        try store.undo()
        #expect(store.tracks[0].instrument == nil)  // back to "unset ⇒ default"

        try store.redo()
        #expect(store.tracks[0].instrument?.polySynth.waveform == .triangle)
    }

    // 3.
    @Test("rapid same-track instrument edits coalesce into one undo step")
    func coalescing() throws {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)  // one entry so far
        var clock = ContinuousClock.now
        store.journal.now = { clock }

        try store.setInstrument(id: inst.id, attack: 0.1)
        clock = clock.advanced(by: .milliseconds(200))
        try store.setInstrument(id: inst.id, attack: 0.2)
        clock = clock.advanced(by: .milliseconds(200))
        try store.setInstrument(id: inst.id, attack: 0.3)

        // addTrack + the three coalesced instrument edits (one step) = 2 entries.
        #expect(store.journal.undoStack.count == 2)
        #expect(store.undoLabel == "Change Instrument")

        // One undo restores the pre-edit (unset) descriptor.
        try store.undo()
        #expect(store.tracks[0].instrument == nil)
        #expect(store.undoLabel == "Add Track 'Inst 1'")
    }

    // 4.
    @Test("setInstrument rejects non-instrument tracks with the exact message")
    func rejectsNonInstrumentTracks() throws {
        let store = ProjectStore()
        let audio = store.addTrack(kind: .audio)
        let bus = store.addTrack(kind: .bus)

        let onAudio = projectError { _ = try store.setInstrument(id: audio.id, waveform: .sine) }
        guard case .instrumentRequiresInstrumentTrack(let k)? = onAudio, k == .audio else {
            Issue.record("expected instrumentRequiresInstrumentTrack(.audio), got \(String(describing: onAudio))")
            return
        }
        #expect(onAudio?.errorDescription
                == "track kind 'audio' cannot host an instrument — only instrument tracks carry an instrument (add one with track.add kind=instrument)")

        let onBus = projectError { _ = try store.setInstrument(id: bus.id, waveform: .sine) }
        guard case .instrumentRequiresInstrumentTrack(.bus)? = onBus else {
            Issue.record("expected instrumentRequiresInstrumentTrack(.bus), got \(String(describing: onBus))")
            return
        }
        // Nothing was stored on either track, and no undo entry was recorded.
        #expect(store.tracks[0].instrument == nil)
        #expect(store.tracks[1].instrument == nil)
        #expect(!store.canUndo || store.undoLabel?.hasPrefix("Add Track") == true)
    }

    // 5.
    @Test("unknown track id returns nil and records nothing")
    func unknownIDReturnsNil() throws {
        let store = ProjectStore()
        store.addTrack(kind: .instrument)
        let result = try store.setInstrument(id: UUID(), waveform: .sine)
        #expect(result == nil)
        #expect(store.tracks[0].instrument == nil)
    }

    // 6.
    @Test("partial overlay: setting one field leaves every other field untouched")
    func partialOverlay() throws {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)

        // Establish a fully customized descriptor.
        let base = try #require(try store.setInstrument(
            id: inst.id, kind: .polySynth, waveform: .square,
            attack: 0.03, decay: 0.4, sustain: 0.2, release: 1.0,
            cutoffHz: 3_000, resonance: 0.6, gain: 0.4
        ))

        // Overlay ONLY the waveform — everything else must survive verbatim.
        let after = try #require(try store.setInstrument(id: inst.id, waveform: .sine))
        #expect(after.polySynth.waveform == .sine)
        #expect(after.kind == base.kind)
        #expect(after.polySynth.attack == base.polySynth.attack)
        #expect(after.polySynth.decay == base.polySynth.decay)
        #expect(after.polySynth.sustain == base.polySynth.sustain)
        #expect(after.polySynth.release == base.polySynth.release)
        #expect(after.polySynth.cutoffHz == base.polySynth.cutoffHz)
        #expect(after.polySynth.resonance == base.polySynth.resonance)
        #expect(after.polySynth.gain == base.polySynth.gain)
    }

    // 7.
    @Test("out-of-range numeric params clamp silently through the model ranges")
    func clamping() throws {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)

        let low = try #require(try store.setInstrument(
            id: inst.id, attack: -1, decay: -1, sustain: -1, release: -1,
            cutoffHz: 1, resonance: -1, gain: -1
        ))
        #expect(low.polySynth.attack == PolySynthParams.attackRange.lowerBound)
        #expect(low.polySynth.decay == PolySynthParams.decayRange.lowerBound)
        #expect(low.polySynth.sustain == 0)
        #expect(low.polySynth.release == PolySynthParams.releaseRange.lowerBound)
        #expect(low.polySynth.cutoffHz == PolySynthParams.cutoffRange.lowerBound)
        #expect(low.polySynth.resonance == 0)
        #expect(low.polySynth.gain == 0)

        let high = try #require(try store.setInstrument(
            id: inst.id, attack: 99, decay: 99, sustain: 99, release: 99,
            cutoffHz: 99_999, resonance: 99, gain: 99
        ))
        #expect(high.polySynth.attack == PolySynthParams.attackRange.upperBound)
        #expect(high.polySynth.decay == PolySynthParams.decayRange.upperBound)
        #expect(high.polySynth.sustain == 1)
        #expect(high.polySynth.release == PolySynthParams.releaseRange.upperBound)
        #expect(high.polySynth.cutoffHz == PolySynthParams.cutoffRange.upperBound)
        #expect(high.polySynth.resonance == 1)
        #expect(high.polySynth.gain == 1)
    }

    // 8.
    @Test("snapshot resolves instrument tracks to a descriptor; audio/bus tracks omit it")
    func snapshotResolution() throws {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)
        store.addTrack(kind: .audio)
        store.addTrack(kind: .bus)
        try store.setInstrument(id: inst.id, waveform: .square)

        let snap = store.snapshot()
        // Instrument track: resolved to the stored descriptor.
        #expect(snap.tracks[0].instrument?.polySynth.waveform == .square)
        // Audio + bus: no instrument regardless of the live model.
        #expect(snap.tracks[1].instrument == nil)
        #expect(snap.tracks[2].instrument == nil)

        // An instrument track that was NEVER set still resolves to .default in
        // the snapshot (clients never see a null instrument on an inst track).
        let inst2 = store.addTrack(kind: .instrument)
        let snap2 = store.snapshot()
        let inst2Snap = try #require(snap2.tracks.first { $0.id == inst2.id })
        #expect(inst2Snap.instrument == .default)
        // The live model still carries nil (default is a wire convenience only).
        #expect(store.tracks.first { $0.id == inst2.id }?.instrument == nil)
    }

    // 9.
    @Test("a customized descriptor round-trips through save then open")
    func persistenceRoundTrip() throws {
        let dir = tempDir()
        let store = ProjectStore()
        let inst = store.addTrack(name: "Bass", kind: .instrument)
        store.addTrack(name: "Gtr", kind: .audio)  // never gains an instrument
        try store.setInstrument(
            id: inst.id, kind: .polySynth, waveform: .triangle,
            attack: 0.011, decay: 0.22, sustain: 0.33, release: 0.44,
            cutoffHz: 6_500, resonance: 0.55, gain: 0.66
        )

        let path = dir.appendingPathComponent("Synth Song").path
        try store.saveProject(to: path)

        let reopened = ProjectStore()
        try reopened.openProject(at: path)
        let bass = try #require(reopened.tracks.first { $0.name == "Bass" })
        let descriptor = try #require(bass.instrument)
        #expect(descriptor.kind == .polySynth)
        #expect(descriptor.polySynth.waveform == .triangle)
        #expect(descriptor.polySynth.attack == 0.011)
        #expect(descriptor.polySynth.decay == 0.22)
        #expect(descriptor.polySynth.sustain == 0.33)
        #expect(descriptor.polySynth.release == 0.44)
        #expect(descriptor.polySynth.cutoffHz == 6_500)
        #expect(descriptor.polySynth.resonance == 0.55)
        #expect(descriptor.polySynth.gain == 0.66)
        // The audio track never carries an instrument.
        let gtr = try #require(reopened.tracks.first { $0.name == "Gtr" })
        #expect(gtr.instrument == nil)
    }

    // 10.
    @Test("a v1 project.json without the instrument key opens with instrument == nil")
    func legacyProjectDecodesNil() throws {
        let dir = tempDir()
        let trackID = UUID().uuidString
        let json = """
        {
          "schemaVersion": 1,
          "name": "Legacy",
          "masterVolume": 1,
          "tracks": [
            { "id": "\(trackID)", "name": "Old Synth", "kind": "instrument", "clips": [] }
          ]
        }
        """
        let bundleURL = ProjectBundle.normalizedBundleURL(
            fromPath: dir.appendingPathComponent("Legacy").path)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: bundleURL.appendingPathComponent("project.json"))

        let store = ProjectStore()
        try store.openProject(at: bundleURL.path)
        #expect(store.tracks.count == 1)
        #expect(store.tracks[0].instrument == nil)  // additive: absent key ⇒ nil ⇒ default
        // And the snapshot still resolves it to the default descriptor.
        #expect(store.snapshot().tracks[0].instrument == .default)
    }

    // 11.
    @Test("TrackDocument decodes without the instrument key (additive-optional field)")
    func trackDocumentLegacyDecode() throws {
        let json = """
        { "id": "\(UUID().uuidString)", "name": "T", "kind": "instrument",
          "volume": 1, "pan": 0, "isMuted": false, "isSoloed": false,
          "isArmed": false, "isAIGenerated": false, "clips": [] }
        """
        let td = try JSONDecoder().decode(TrackDocument.self, from: Data(json.utf8))
        #expect(td.instrument == nil)
    }
}
