import Foundation
import Testing
@testable import DAWCore

// Groove templates (M5 iii-g, spec §6): pure extraction/builtin math, the target
// application through BOTH quantize paths, the project-level store ops, and
// persistence (omit-when-empty byte-identical). Math tests need no engine; store
// tests run headless; the audio-extract test uses the shared FakeEngine stub.

private func gApprox(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) < tol }

// MARK: - Extraction

@Suite("GrooveTemplate — extraction")
struct GrooveExtractionTests {

    // 1. Fold into the cycle + per-slot averaging: a swung 8th pattern over two
    //    bars recovers offsets [0, swingOffset] regardless of how many cycles.
    @Test("onsets fold into the cycle and per-slot deviations average")
    func foldAndAverage() {
        // grid 0.5 (1/8), cycle 1.0 (2 slots). Onsets: downbeats straight, offbeats
        // late by 0.16 (swing 66), across two cycles.
        let onsets = [0.0, 0.66, 1.0, 1.66]
        let g = GrooveTemplate.extract(fromOnsetBeats: onsets, gridBeats: 0.5,
                                       cycleBeats: 1.0, name: "swung")
        #expect(g.offsets.count == 2)
        #expect(gApprox(g.offsets[0], 0.0))
        #expect(gApprox(g.offsets[1], 0.16))

        // Averaging: two offbeat onsets in the same folded slot with differing
        // deviations average (0.10 and 0.20 → 0.15).
        let avg = GrooveTemplate.extract(fromOnsetBeats: [0.60, 1.70], gridBeats: 0.5,
                                         cycleBeats: 1.0, name: "avg")
        #expect(gApprox(avg.offsets[1], 0.15))
    }

    // 2. Empty slots read 0.
    @Test("slots with no onsets get 0")
    func emptySlots() {
        // Only the offbeat slot has onsets; every other slot (0, and the 4-beat
        // fold's remaining slots) reads 0.
        let g = GrooveTemplate.extract(fromOnsetBeats: [0.55], gridBeats: 0.5,
                                       cycleBeats: 4.0, name: "sparse")
        #expect(g.offsets.count == 8)                 // round(4/0.5)
        #expect(gApprox(g.offsets[1], 0.05))          // 0.55 → slot 1, dev 0.05
        #expect(g.offsets.enumerated().allSatisfy { $0.offset == 1 || $0.element == 0 })
    }

    // 3. Nearest-slot snapping keeps every extracted deviation within ±grid/2,
    //    and the init clamps any out-of-range authored offset.
    @Test("extraction stays within ±grid/2; init clamps authored offsets")
    func clampBound() {
        // An onset 0.30 past slot 0 with grid 0.5 is closer to slot 1 (0.5): it
        // snaps to slot 1 with dev −0.20, never a >grid/2 deviation on slot 0.
        let g = GrooveTemplate.extract(fromOnsetBeats: [0.30], gridBeats: 0.5,
                                       cycleBeats: 1.0, name: "snap")
        #expect(gApprox(g.offsets[1], -0.20))
        #expect(g.offsets[0] == 0)
        #expect(g.offsets.allSatisfy { abs($0) <= 0.25 + 1e-12 })

        // Direct init clamp: a wild authored offset pins to ±grid/2 (0.25).
        let clamped = GrooveTemplate(name: "wild", gridBeats: 0.5, cycleBeats: 1.0,
                                     offsets: [0.9, -0.9])
        #expect(gApprox(clamped.offsets[0], 0.25) && gApprox(clamped.offsets[1], -0.25))
    }

    // 4. Init normalizes the offset count to round(cycle/grid): extra dropped,
    //    missing padded with 0.
    @Test("init normalizes offset count to round(cycle/grid)")
    func normalizeCount() {
        let padded = GrooveTemplate(name: "p", gridBeats: 0.25, cycleBeats: 1.0, offsets: [0.01])
        #expect(padded.offsets.count == 4)            // round(1/0.25)
        #expect(padded.offsets[1] == 0 && padded.offsets[2] == 0 && padded.offsets[3] == 0)
        let trimmed = GrooveTemplate(name: "t", gridBeats: 0.5, cycleBeats: 1.0,
                                     offsets: [0, 0.1, 0.2, 0.3])
        #expect(trimmed.offsets.count == 2)           // extra dropped
    }
}

// MARK: - Built-ins

@Suite("GrooveTemplate — builtins")
struct GrooveBuiltinTests {

    // 5. Exact shape of a built-in swing: grid, cycle, offsets.
    @Test("swing8:62 has grid 0.5, cycle 1.0, offsets [0, 0.12]")
    func swing8Shape() {
        let g = GrooveTemplate.builtin(named: "swing8:62")!
        #expect(gApprox(g.gridBeats, 0.5) && gApprox(g.cycleBeats, 1.0))
        #expect(g.offsets.count == 2)
        #expect(gApprox(g.offsets[0], 0.0))
        #expect(gApprox(g.offsets[1], (2 * 0.62 - 1) * 0.5))   // 0.12
        // 1/16 variant: grid 0.25, cycle 0.5, offbeat scaled by grid.
        let g16 = GrooveTemplate.builtin(named: "swing16:66")!
        #expect(gApprox(g16.gridBeats, 0.25) && gApprox(g16.cycleBeats, 0.5))
        #expect(gApprox(g16.offsets[1], (2 * 0.66 - 1) * 0.25))  // 0.08
    }

    // 6. Name resolution: the 8 canonical names, the full 54…75 range, and
    //    rejections (out of range, unknown prefix).
    @Test("builtinNames lists 8 canonical; range 54…75 resolves; junk is nil")
    func nameResolution() {
        #expect(GrooveTemplate.builtinNames.count == 8)
        #expect(Set(GrooveTemplate.builtinNames) == Set([
            "swing8:54", "swing8:58", "swing8:62", "swing8:66",
            "swing16:54", "swing16:58", "swing16:62", "swing16:66",
        ]))
        #expect(GrooveTemplate.builtinNames.allSatisfy { GrooveTemplate.builtin(named: $0) != nil })
        // Full range: 54 and 75 resolve; 53 and 76 do not.
        #expect(GrooveTemplate.builtin(named: "swing8:54") != nil)
        #expect(GrooveTemplate.builtin(named: "swing8:75") != nil)
        #expect(GrooveTemplate.builtin(named: "swing8:53") == nil)
        #expect(GrooveTemplate.builtin(named: "swing8:76") == nil)
        #expect(GrooveTemplate.builtin(named: "swing32:66") == nil)
        #expect(GrooveTemplate.builtin(named: "nonsense") == nil)
        // A stable, deterministic id across calls (built-ins aren't persisted).
        #expect(GrooveTemplate.builtin(named: "swing8:66")!.id == GrooveTemplate.builtin(named: "swing8:66")!.id)
        // swing 75 reaches exactly grid/2 (the closed-bound ASSUMPTION).
        #expect(gApprox(GrooveTemplate.builtin(named: "swing8:75")!.offsets[1], 0.25))
    }

    // The full resolvable built-in range (`swing8:54…75` + `swing16:54…75`, 44
    // names), computed via `builtin(named:)`.
    private static var allBuiltinNames: [String] {
        (54...75).map { "swing8:\($0)" } + (54...75).map { "swing16:\($0)" }
    }

    // m11-g: every resolvable built-in id is DISTINCT. The original single-pass
    // FNV byte fold collapsed the whole `swing8:54…75` family onto ONE id
    // (`48C63252-293C-B111-D60F-9903BFCCE689`), so `groove.list` served duplicate
    // ids and an agent selecting a built-in by id could land on the wrong swing.
    @Test("m11-g: all 44 resolvable built-in ids are pairwise distinct")
    func builtinIDsUnique() {
        let names = Self.allBuiltinNames
        #expect(names.count == 44)
        let ids = names.compactMap { GrooveTemplate.builtin(named: $0)?.id }
        #expect(ids.count == 44)                 // all resolve
        #expect(Set(ids).count == 44)            // no collisions
    }

    // m11-g: the id is a pure function of the name — two independent computations
    // of the same name yield an identical id (the doc-comment contract: stable
    // across calls and processes, no RNG).
    @Test("m11-g: built-in ids are deterministic across computations")
    func builtinIDsDeterministic() {
        for name in Self.allBuiltinNames {
            let a = GrooveTemplate.builtin(named: name)!.id
            let b = GrooveTemplate.builtin(named: name)!.id
            #expect(a == b, "\(name) id changed between computations")
        }
    }

    // m11-g: a stability pin so a future refactor of `builtinID` can't silently
    // change the wire-visible ids again. The id is derived (not persisted), but it
    // must stay CONSTANT once fixed. If this fails, the derivation changed — that
    // is a wire-visible change requiring a deliberate note (as m11-g itself was).
    @Test("m11-g: swing8:66 has a pinned, stable id")
    func builtinIDStabilityPin() {
        #expect(GrooveTemplate.builtin(named: "swing8:66")!.id
                == UUID(uuidString: "0C5B2E4D-148B-4FA9-B8A1-31A0C07182EF"))
    }

    // m11-g: the pairs that COLLIDED under the old fold now differ. All four
    // canonical `swing8` presets shared one id before the fix; assert every
    // distinct pair among them (and a same-first-digit neighbour pair) is now
    // distinct — the concrete regression the bug demonstration surfaced.
    @Test("m11-g: previously-colliding swing8 built-ins now have distinct ids")
    func builtinIDPreviouslyCollidingPairsDiffer() {
        let previouslyColliding = ["swing8:54", "swing8:58", "swing8:62", "swing8:66"]
        let ids = previouslyColliding.map { GrooveTemplate.builtin(named: $0)!.id }
        #expect(Set(ids).count == previouslyColliding.count)
        // A same-first-digit neighbour pair (54 vs 58) — the tightest case, since
        // they differ only in the last digit — is also distinct.
        #expect(GrooveTemplate.builtin(named: "swing8:54")!.id
                != GrooveTemplate.builtin(named: "swing8:58")!.id)
        // Built-in ids never collide with a saved-template's random UUID either,
        // but that's covered by resolveGroove precedence — here we pin the family.
    }
}

// MARK: - Target application (both quantize paths)

@Suite("Groove — target application")
struct GrooveTargetTests {

    // 7. QuantizeTarget with a groove: target = i·grid + offsets[i mod count];
    //    groove WINS over swingPercent.
    @Test("groove targets are i·grid + offsets[i mod count] and win over swing")
    func grooveTargets() {
        let g = GrooveTemplate.builtin(named: "swing8:66")!   // grid 0.5, offsets [0, 0.16]
        // Deliberately pass a hot swing to prove the groove overrides it.
        let s = QuantizeSettings(gridBeats: 0.5, swingPercent: 75, groove: g)
        #expect(gApprox(QuantizeTarget.nearest(toBeat: 0.0, settings: s), 0.0))    // slot 0 → 0
        #expect(gApprox(QuantizeTarget.nearest(toBeat: 0.5, settings: s), 0.66))   // slot 1 → 0.5+0.16
        #expect(gApprox(QuantizeTarget.nearest(toBeat: 1.0, settings: s), 1.0))    // slot 2 folds to 0
        #expect(gApprox(QuantizeTarget.nearest(toBeat: 1.5, settings: s), 1.66))   // slot 3 folds to 1
        // A near-onset snaps to its nearest straight slot first, then the groove
        // offset applies: 0.45 → slot 1 → 0.66.
        #expect(gApprox(QuantizeTarget.nearest(toBeat: 0.45, settings: s), 0.66))
    }

    // 8. MIDIQuantizer through the groove: straight notes land on groove targets.
    @Test("MIDIQuantizer moves onsets onto groove targets")
    func midiGrooveApply() {
        let g = GrooveTemplate.builtin(named: "swing8:66")!
        let notes = [
            MIDINote(pitch: 60, startBeat: 0.0, lengthBeats: 0.5),
            MIDINote(pitch: 62, startBeat: 0.5, lengthBeats: 0.5),
            MIDINote(pitch: 64, startBeat: 1.0, lengthBeats: 0.5),
            MIDINote(pitch: 65, startBeat: 1.5, lengthBeats: 0.5),
        ]
        let q = MIDIQuantizer.quantize(notes, settings:
            QuantizeSettings(gridBeats: 0.5, strength: 1, groove: g))
        #expect(gApprox(q[0].startBeat, 0.0))
        #expect(gApprox(q[1].startBeat, 0.66))
        #expect(gApprox(q[2].startBeat, 1.0))
        #expect(gApprox(q[3].startBeat, 1.66))
    }

    // 9. Audio path parity: AudioQuantizePlan forwards the groove through
    //    targetSettings, so its slice onsets land on the SAME targets the MIDI
    //    path computes for identical onset beats.
    @Test("AudioQuantizePlan groove targets match the MIDI path for identical onsets")
    func audioGrooveParity() throws {
        let g = GrooveTemplate.builtin(named: "swing8:66")!
        // 120 BPM → spb 0.5. Source onsets at 0.25/0.5/0.75 s → beats 0.5/1.0/1.5.
        let clip = Clip(name: "a", startBeat: 0, lengthBeats: 4,
                        audioFileURL: URL(fileURLWithPath: "/tmp/a.wav"))
        let settings = AudioQuantizeSettings(gridBeats: 0.5, strength: 1, groove: g)
        let slices = try AudioQuantizePlan.compute(
            clip: clip, transientsSourceSeconds: [0.25, 0.5, 0.75],
            tempoMap: TempoMap(constantBPM: 120), settings: settings)
        #expect(slices.count == 4)   // head + 3 onset slices
        let spb = 0.5
        // Each onset slice's onset lands on the groove target (the AudioQuantize
        // onset-lands-on-target invariant).
        func onsetBeat(_ i: Int, source: Double) -> Double {
            slices[i].startBeat + (source - slices[i].startOffsetSeconds) / spb
        }
        #expect(gApprox(onsetBeat(1, source: 0.25), 0.66))
        #expect(gApprox(onsetBeat(2, source: 0.5), 1.0))
        #expect(gApprox(onsetBeat(3, source: 0.75), 1.66))
        // Parity: identical to the MIDI-path evaluator on the same onset beats.
        let qs = QuantizeSettings(gridBeats: 0.5, strength: 1, groove: g)
        #expect(gApprox(QuantizeTarget.nearest(toBeat: 0.5, settings: qs), 0.66))
        #expect(gApprox(QuantizeTarget.nearest(toBeat: 1.0, settings: qs), 1.0))
        #expect(gApprox(QuantizeTarget.nearest(toBeat: 1.5, settings: qs), 1.66))
    }
}

// MARK: - Store ops

@MainActor
@Suite("ProjectStore — groove ops")
struct GrooveStoreTests {

    private func projectError(_ body: () async throws -> Void) async -> ProjectError? {
        do { try await body(); return nil }
        catch let e as ProjectError { return e }
        catch { Issue.record("unexpected error type: \(error)"); return nil }
    }

    // 10. extractGroove from a MIDI clip appends to the palette; undo removes,
    //     redo re-adds (single step each).
    @Test("extractGroove (MIDI) appends and is undoable/redoable")
    func extractMIDI() async throws {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)
        // Swung 8ths: offbeats late by 0.16.
        let clip = try store.addMIDIClip(toTrack: inst.id, notes: [
            MIDINote(pitch: 60, startBeat: 0.0, lengthBeats: 0.5),
            MIDINote(pitch: 62, startBeat: 0.66, lengthBeats: 0.5),
            MIDINote(pitch: 64, startBeat: 1.0, lengthBeats: 0.5),
            MIDINote(pitch: 65, startBeat: 1.66, lengthBeats: 0.5),
        ])
        let g = try await store.extractGroove(fromClipId: clip.id, name: "Feel",
                                              gridBeats: 0.5, cycleBeats: 1.0)
        #expect(g.name == "Feel")
        #expect(gApprox(g.offsets[0], 0.0) && gApprox(g.offsets[1], 0.16))
        #expect(store.grooveTemplates.count == 1)
        #expect(store.grooveTemplates[0].id == g.id)

        #expect(try store.undo() == "Extract Groove")
        #expect(store.grooveTemplates.isEmpty)
        #expect(try store.redo() == "Extract Groove")
        #expect(store.grooveTemplates.count == 1)
    }

    // 11. removeGrooveTemplate removes; undo restores; unknown id → grooveNotFound.
    @Test("removeGrooveTemplate deletes (undoable); unknown id → grooveNotFound")
    func remove() async throws {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: inst.id, notes: [
            MIDINote(pitch: 60, startBeat: 0.0), MIDINote(pitch: 62, startBeat: 0.5),
        ])
        let g = try await store.extractGroove(fromClipId: clip.id, name: "G",
                                              gridBeats: 0.5, cycleBeats: 1.0)
        try store.removeGrooveTemplate(id: g.id)
        #expect(store.grooveTemplates.isEmpty)
        #expect(try store.undo() == "Remove Groove")
        #expect(store.grooveTemplates.count == 1)

        let bogus = UUID()
        let err = await projectError { try store.removeGrooveTemplate(id: bogus) }
        guard case .grooveNotFound(let id)? = err, id == bogus else {
            Issue.record("expected grooveNotFound, got \(String(describing: err))"); return
        }
        #expect(err?.errorDescription
                == "no groove template with id \(bogus.uuidString) — use groove.list to see saved templates and built-in swings")
    }

    // 12. extractGroove from an AUDIO clip uses the engine transient stub.
    @Test("extractGroove (audio) detects transients then builds the table")
    func extractAudio() async throws {
        let clip = Clip(name: "Loop", startBeat: 0, lengthBeats: 4,
                        audioFileURL: URL(fileURLWithPath: "/tmp/loop.wav"))
        let track = Track(name: "Drums", kind: .audio, clips: [clip])
        let store = ProjectStore(tracks: [track])
        let engine = FakeEngine()
        // 120 BPM → spb 0.5. Source seconds 0.0/0.33/0.5/0.83 → beats 0/0.66/1.0/1.66.
        engine.detectTransientsStub = [
            TransientMarker(timeSeconds: 0.0, strength: 1),
            TransientMarker(timeSeconds: 0.33, strength: 0.9),
            TransientMarker(timeSeconds: 0.5, strength: 0.9),
            TransientMarker(timeSeconds: 0.83, strength: 0.8),
        ]
        store.engine = engine
        let g = try await store.extractGroove(fromClipId: clip.id, name: "Drum feel",
                                              gridBeats: 0.5, cycleBeats: 1.0)
        #expect(engine.detectTransientsCalls.count == 1)
        #expect(g.offsets.count == 2)
        #expect(gApprox(g.offsets[0], 0.0))
        #expect(gApprox(g.offsets[1], 0.16))
        #expect(store.grooveTemplates.count == 1)
    }

    // 13. resolveGroove precedence: built-in beats a project-name collision;
    //     then id, then name; unknown → nil.
    @Test("resolveGroove: builtin wins, then id, then name; unknown → nil")
    func resolvePrecedence() async throws {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: inst.id, notes: [
            MIDINote(pitch: 60, startBeat: 0.0), MIDINote(pitch: 62, startBeat: 0.5),
        ])
        // A project template deliberately NAMED like a built-in.
        let collide = try await store.extractGroove(fromClipId: clip.id, name: "swing8:66",
                                                    gridBeats: 0.5, cycleBeats: 1.0)
        let byName = store.resolveGroove("swing8:66")
        // The built-in wins the name collision: its id is the deterministic
        // built-in id, NOT the stored template's.
        #expect(byName?.id == GrooveTemplate.builtin(named: "swing8:66")!.id)
        #expect(byName?.id != collide.id)
        // Resolve the stored one by its id string.
        #expect(store.resolveGroove(collide.id.uuidString)?.id == collide.id)
        // A distinctly-named template resolves by name.
        let named = try await store.extractGroove(fromClipId: clip.id, name: "My Feel",
                                                  gridBeats: 0.5, cycleBeats: 1.0)
        #expect(store.resolveGroove("My Feel")?.id == named.id)
        // Unknown → nil.
        #expect(store.resolveGroove("does-not-exist") == nil)
    }

    // 14. Groove-driven quantizeClipNotes: a straight clip lands on groove targets.
    @Test("quantizeClipNotes with a groove lands onsets on groove targets")
    func quantizeWithGroove() async throws {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: inst.id, notes: [
            MIDINote(pitch: 60, startBeat: 0.02, lengthBeats: 0.5),
            MIDINote(pitch: 62, startBeat: 0.48, lengthBeats: 0.5),
            MIDINote(pitch: 64, startBeat: 1.03, lengthBeats: 0.5),
            MIDINote(pitch: 65, startBeat: 1.47, lengthBeats: 0.5),
        ])
        let g = GrooveTemplate.builtin(named: "swing8:66")!
        let updated = try store.quantizeClipNotes(
            clipId: clip.id, settings: QuantizeSettings(gridBeats: 0.5, strength: 1, groove: g))
        let starts = updated.notes!.map(\.startBeat)
        #expect(gApprox(starts[0], 0.0))
        #expect(gApprox(starts[1], 0.66))
        #expect(gApprox(starts[2], 1.0))
        #expect(gApprox(starts[3], 1.66))
    }
}

// MARK: - Persistence

@MainActor
@Suite("Persistence — grooveTemplates")
struct GroovePersistenceTests {

    private func bundleEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
    private func bundleDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // 15. A pre-groove project never gains a grooveTemplates key, and decode →
    //     re-encode is byte-identical.
    @Test("a project without grooves stays byte-identical (no grooveTemplates key)")
    func omitWhenEmpty() throws {
        let document = ProjectDocument(
            name: "t", transport: TransportState(),
            tracks: [Track(name: "A", kind: .audio,
                           clips: [Clip(name: "c", startBeat: 0, lengthBeats: 4)])],
            masterVolume: 1, mediaRefs: [:])   // no grooveTemplates arg → default []
        let encoder = bundleEncoder()
        let first = try encoder.encode(document)
        #expect(!String(data: first, encoding: .utf8)!.contains("grooveTemplates"))
        let decoded = try bundleDecoder().decode(ProjectDocument.self, from: first)
        let second = try encoder.encode(decoded)
        #expect(first == second)
    }

    // 16. A project WITH grooves round-trips through the document Codable.
    @Test("grooveTemplates round-trip through the document (values preserved)")
    func grooveRoundTrip() throws {
        let groove = GrooveTemplate(name: "Feel", gridBeats: 0.5, cycleBeats: 1.0, offsets: [0, 0.16])
        let document = ProjectDocument(
            name: "t", transport: TransportState(), tracks: [], masterVolume: 1,
            mediaRefs: [:], grooveTemplates: [groove])
        let data = try bundleEncoder().encode(document)
        #expect(String(data: data, encoding: .utf8)!.contains("grooveTemplates"))
        let decoded = try bundleDecoder().decode(ProjectDocument.self, from: data)
        #expect(decoded.grooveTemplates?.count == 1)
        #expect(decoded.grooveTemplates?[0] == groove)
    }

    // 17. Full store save → reopen restores the palette.
    @Test("save then open restores the groove palette")
    func saveOpen() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("groove-persist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("Song.dawproj").path

        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: inst.id, notes: [
            MIDINote(pitch: 60, startBeat: 0.0), MIDINote(pitch: 62, startBeat: 0.66),
            MIDINote(pitch: 64, startBeat: 1.0), MIDINote(pitch: 65, startBeat: 1.66),
        ])
        let g = try await store.extractGroove(fromClipId: clip.id, name: "Verse feel",
                                              gridBeats: 0.5, cycleBeats: 1.0)
        try store.saveProject(to: path)

        let reopened = ProjectStore()
        try reopened.openProject(at: path)
        #expect(reopened.grooveTemplates.count == 1)
        #expect(reopened.grooveTemplates[0] == g)
        // Snapshot carries the palette too.
        #expect(reopened.snapshot().grooveTemplates?.count == 1)
    }
}
