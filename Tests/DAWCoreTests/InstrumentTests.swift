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

    // 12. m39-g PLUMBING — THE DATA-LOSS TRAP, PINNED.
    //
    // ⛔⛔ THE FAILURE THIS EXISTS TO PREVENT, IN ONE SENTENCE: a user brightens
    // a filter and their unison collapses. `setInstrument` rebuilds
    // `PolySynthParams` through an EXPLICIT initialiser call, so every field it
    // does not name takes that field's `nil` default on EVERY call — silently,
    // reporting success. That was harmless while the fifteen richness fields
    // were unsettable (nothing could put a value there to lose); the moment
    // they became settable it turned into m33-j's shape, where `clip.addAudio`
    // deleted the clips it overlapped and answered OK.
    //
    // ⭐ THIS TEST WAS WRITTEN BEFORE THE FIX AND WATCHED TO FAIL against the
    // nine-field initialiser — MEASURED, not asserted: all fifteen `#expect`s
    // below reddened, e.g. `unisonVoices → nil` and `envelopeCurve → nil`,
    // while the `cutoffHz` control passed. A preservation test that has never
    // failed is indistinguishable from one that asserts nothing.
    //
    // The seed is written straight onto the track rather than through
    // `setInstrument`, deliberately: that is the state a PROJECT FILE ON DISK
    // produces (`Codable` assigns stored properties directly — see
    // `PolySynthRichnessCodableTests`), and it keeps this test honest about
    // what it measures even if the writing path changes.
    @Test("m39-g: a one-knob edit preserves ALL fifteen richness fields (the overlay rule)")
    func richnessSurvivesAnUnrelatedKnobEdit() throws {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)
        // Every richness field NON-DEFAULT and distinguishable from its own
        // nil-resolution, so "preserved" cannot be confused with "re-defaulted".
        let seeded = PolySynthParams(
            waveform: .square, attack: 0.02, decay: 0.2, sustain: 0.4, release: 0.5,
            cutoffHz: 3_000, resonance: 0.3, gain: 0.6, pedalHoldLimit: 6,
            unisonVoices: 5, unisonDetuneCents: 18, unisonStereoSpread: 0.8,
            subLevel: 0.4, subOctave: -2, subWaveform: .square,
            noiseLevel: 0.2, noiseColor: 0.9, drift: 0.35,
            resonanceBoost: 0.7, drive: 0.45, velocityToCutoff: 0.6,
            keyToCutoff: 0.25, voiceJitter: 0.15, envelopeCurve: -0.5)
        store.tracks[0].instrument = InstrumentDescriptor(kind: .polySynth, polySynth: seeded)

        // The unrelated knob edit: brighten the filter, say nothing else.
        let after = try #require(try store.setInstrument(id: inst.id, cutoffHz: 9_000))

        // CONTROL FIRST: the edit that WAS sent landed. Without this, fifteen
        // preserved fields could mean "setInstrument did nothing at all".
        #expect(after.polySynth.cutoffHz == 9_000, "control: the requested edit must land")

        // Field by field, so a regression NAMES the field it dropped rather
        // than printing two opaque struct descriptions.
        #expect(after.polySynth.unisonVoices == 5)
        #expect(after.polySynth.unisonDetuneCents == 18)
        #expect(after.polySynth.unisonStereoSpread == 0.8)
        #expect(after.polySynth.subLevel == 0.4)
        #expect(after.polySynth.subOctave == -2)
        #expect(after.polySynth.subWaveform == .square)
        #expect(after.polySynth.noiseLevel == 0.2)
        #expect(after.polySynth.noiseColor == 0.9)
        #expect(after.polySynth.drift == 0.35)
        #expect(after.polySynth.resonanceBoost == 0.7)
        #expect(after.polySynth.drive == 0.45)
        #expect(after.polySynth.velocityToCutoff == 0.6)
        #expect(after.polySynth.keyToCutoff == 0.25)
        #expect(after.polySynth.voiceJitter == 0.15)
        #expect(after.polySynth.envelopeCurve == -0.5)
        // m34-q's field rides the same rule and is re-pinned here, because a
        // rewrite of this initialiser could drop it and every pedal test would
        // still pass (they all SET the cap in the same call).
        #expect(after.polySynth.pedalHoldLimit == 6)

        // WHOLE-STRUCT equality: catches a field added to `PolySynthParams`
        // tomorrow and forgotten in the overlay, which the per-field list above
        // structurally cannot.
        var expected = seeded
        expected.cutoffHz = 9_000
        #expect(after.polySynth == expected,
                "every field except the one edited must come through untouched")
        // And what was STORED is what was returned — a setter's return is not
        // proof it took.
        #expect(store.tracks[0].instrument?.polySynth == expected)
    }

    // 13. The same rule the other way round: setting a richness field must not
    // disturb the legacy eight, and must not disturb a DIFFERENT richness
    // field.
    @Test("m39-g: setting one richness field leaves every other field alone")
    func settingOneRichnessFieldDisturbsNothingElse() throws {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)
        let seeded = PolySynthParams(
            waveform: .triangle, attack: 0.03, decay: 0.3, sustain: 0.5, release: 0.6,
            cutoffHz: 4_000, resonance: 0.4, gain: 0.7, pedalHoldLimit: 9,
            unisonVoices: 3, unisonDetuneCents: 12, drift: 0.2, envelopeCurve: 0.8)
        store.tracks[0].instrument = InstrumentDescriptor(kind: .polySynth, polySynth: seeded)

        let after = try #require(try store.setInstrument(id: inst.id, drive: 0.9))
        var expected = seeded
        expected.drive = 0.9
        #expect(after.polySynth == expected)
        // Fields never set stay nil — "preserved" must not quietly mean
        // "resolved to its neutral value and written back", which would destroy
        // the unset/explicit-zero distinction the whole design rests on.
        #expect(after.polySynth.noiseLevel == nil,
                "an untouched optional must stay nil, not become an explicit 0")
        #expect(after.polySynth.subWaveform == nil)
    }

    // 14. Out-of-range richness values re-clamp through the init on overlay,
    // the same way the legacy eight do (test 7 above pins that for gain). The
    // unison clamp in particular is a memory-safety boundary: the engine
    // allocates `16 × maxUnisonVoices` sub-voice slots and indexes them on the
    // render thread.
    @Test("m39-g: an out-of-range richness overlay re-clamps at the store boundary")
    func richnessOverlayReclamps() throws {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)
        let clamped = try #require(try store.setInstrument(
            id: inst.id, unisonVoices: 99, unisonDetuneCents: 500, subOctave: -9,
            drift: 4, envelopeCurve: -7))
        #expect(clamped.polySynth.unisonVoices == PolySynthParams.maxUnisonVoices,
                "the unison clamp is a memory-safety boundary, not a niceness")
        #expect(clamped.polySynth.unisonDetuneCents == 50)
        #expect(clamped.polySynth.subOctave == -2)
        #expect(clamped.polySynth.drift == 1)
        #expect(clamped.polySynth.envelopeCurve == -1)
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
