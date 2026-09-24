import Foundation
import Testing
@testable import DAWCore

// Reuses FakeMedia (ImportTests.swift) and the always-present system alert
// sound as real, readable zone media — the `SamplerZonePersistenceTests` recipe.

/// m39-levels-2 — **SIXTEEN LEVELS AT THE STORE: the direction a wire verb will
/// set, and the proof that it persists with the spread.**
///
/// ⚠️ NON-ISOLATED SUITE, `@MainActor` TESTS (the `BitCrusherTests` shape): the
/// store is main-actor, but `MainActorOccupancySiteTests` Leg C counts
/// main-actor SUITES against a cadence cap with one slot of slack, and this
/// file must not spend it.
///
/// The three claims, each with the control that makes it mean something:
///  1. **ADD edits nothing** — every original zone comes back as the same VALUE
///     (`SamplerZone` is `Equatable`, so the whole struct is compared, not the
///     two fields a hand-written check would remember).
///  2. **FLIP edits one field of one zone** — the spread's `rootPitch`, and a
///     zone the spread did not make is REFUSED rather than re-rooted.
///  3. **The direction survives save → reopen** — because it IS the zone's
///     root, read back through `SamplerZoneDocument`, with no flag to lose.
@Suite("Sixteen Levels — the store API and the direction's persistence (m39-levels-2)")
struct SixteenLevelsStoreTests {

    private static let ping = URL(fileURLWithPath: "/System/Library/Sounds/Ping.aiff")

    /// A 9-slice chop from note 36, one key wide each — `SliceToSampler`'s shape.
    private static func chop(_ count: Int = 9) -> [SamplerZone] {
        (0..<count).map { i in
            SamplerZone(audioFileURL: ping, rootPitch: 36 + i, minPitch: 36 + i,
                        maxPitch: 36 + i, startFrame: i * 1_000, endFrame: i * 1_000 + 900)
        }
    }

    @MainActor
    private static func sampledStore() throws -> (ProjectStore, UUID, [SamplerZone]) {
        let store = ProjectStore()
        store.media = FakeMedia()
        let track = store.addTrack(name: "Vocal chops", kind: .instrument)
        let zones = chop()
        try store.setInstrument(id: track.id, kind: .sampler,
                                sampler: SamplerParams(zones: zones))
        return (store, track.id, zones)
    }

    @MainActor
    private static func zones(_ store: ProjectStore, _ trackID: UUID) -> [SamplerZone] {
        store.tracks.first { $0.id == trackID }?.instrument?.sampler?.zones ?? []
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m39-levels-2-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 1. ADD

    @Test("⛔⛔ adding a spread adds ONE zone, in either direction, and every slice is byte-identical")
    @MainActor
    func addEditsNothing() throws {
        for direction in SixteenLevels.Direction.allCases {
            let (store, trackID, before) = try Self.sampledStore()
            let source = before[2]
            let spread = try store.addSixteenLevelsSpread(trackID: trackID,
                                                          sourceZoneID: source.id,
                                                          direction: direction)
            let after = Self.zones(store, trackID)
            #expect(after.count == before.count + 1, "\(direction): not exactly one zone added")
            // ⭐ THE WHOLE KEYMAP, IN ORDER: the chop, untouched, then the spread.
            #expect(Array(after.prefix(before.count)) == before,
                    "\(direction): an original zone was altered or reordered")
            #expect(after.last == spread)
            // The spread is where `freeBase` says, sixteen keys, rooted by direction.
            #expect(spread.minPitch == 20)
            #expect(spread.maxPitch == 35)
            #expect(spread.rootPitch == 20 + direction.unshiftedPadIndex)
            #expect(SixteenLevels.direction(of: spread) == direction)
            #expect(spread.id != source.id)
            #expect(spread.startFrame == source.startFrame)
        }
    }

    @Test("the store's default direction is UP — the shipped behaviour")
    @MainActor
    func addDefaultsToUp() throws {
        let (store, trackID, before) = try Self.sampledStore()
        let spread = try store.addSixteenLevelsSpread(trackID: trackID,
                                                      sourceZoneID: before[0].id)
        #expect(spread.rootPitch == spread.minPitch)
        #expect(SixteenLevels.direction(of: spread) == .up)
    }

    // MARK: - 2. FLIP

    /// ⛔⛔ The toggle's ONLY edit. Flipped both ways, twice, and after every
    /// flip the chop must be the same VALUES in the same ORDER, and the spread
    /// must differ from what it was in `rootPitch` and nothing else.
    @Test("⛔⛔ flipping a spread moves ONE field of ONE zone — the chop is byte-identical after every flip")
    @MainActor
    func flipEditsOneField() throws {
        let (store, trackID, chop) = try Self.sampledStore()
        let spread = try store.addSixteenLevelsSpread(trackID: trackID,
                                                      sourceZoneID: chop[4].id)
        for direction in [SixteenLevels.Direction.centered, .up, .centered, .up] {
            let before = Self.zones(store, trackID)
            let moved = try store.setSixteenLevelsDirection(trackID: trackID,
                                                            spreadZoneID: spread.id,
                                                            direction: direction)
            let after = Self.zones(store, trackID)
            #expect(Array(after.prefix(chop.count)) == chop,
                    "flipping to \(direction) edited the chop")
            #expect(after.count == before.count)
            #expect(moved.id == spread.id, "the flip must keep the spread's identity")
            #expect(moved.rootPitch == moved.minPitch + direction.unshiftedPadIndex)
            // ONLY the root: put it back and the zone is the zone it was.
            var restored = moved
            restored.rootPitch = spread.rootPitch
            #expect(restored == spread, "the flip changed something other than rootPitch")
            #expect(after.last == moved)
        }
    }

    @Test("a flip to the direction a spread already runs writes NOTHING")
    @MainActor
    func redundantFlipWritesNothing() throws {
        let dir = tempDir()
        let (store, trackID, chop) = try Self.sampledStore()
        let spread = try store.addSixteenLevelsSpread(trackID: trackID,
                                                      sourceZoneID: chop[1].id,
                                                      direction: .centered)
        _ = try store.saveProject(to: dir.appendingPathComponent("Redundant").path)
        #expect(store.isDirty == false)
        // ⚠️ Read the keymap AFTER the save: saving relocates media into the
        // bundle, so every zone's `audioFileURL` now names the bundle's copy.
        let keymapBefore = Self.zones(store, trackID)
        let savedSpread = try #require(keymapBefore.first { $0.id == spread.id })
        #expect(savedSpread.rootPitch == spread.rootPitch)
        let echoed = try store.setSixteenLevelsDirection(trackID: trackID,
                                                         spreadZoneID: spread.id,
                                                         direction: .centered)
        #expect(echoed == savedSpread)
        #expect(Self.zones(store, trackID) == keymapBefore)
        // ⭐ `isDirty` is the probe, not the undo history: `setInstrument`
        // COALESCES per track, so a second write can hide inside the first
        // undo step. Any write at all would have dirtied the session.
        #expect(store.isDirty == false, "a no-op flip wrote the sampler anyway")
        // POSITIVE CONTROL: a real flip does dirty it.
        _ = try store.setSixteenLevelsDirection(trackID: trackID, spreadZoneID: spread.id,
                                                direction: .up)
        #expect(store.isDirty == true)
    }

    /// ⛔ A one-key slice named by mistake must be REFUSED. Re-rooting it would
    /// edit the user's chop — the one thing Sixteen Levels promises never to do.
    @Test("⛔ a zone the spread did not make is REFUSED, never re-rooted")
    @MainActor
    func flipRefusesANonSpread() throws {
        let (store, trackID, chop) = try Self.sampledStore()
        #expect(throws: SixteenLevelsError.notASpread(chop[3].id)) {
            try store.setSixteenLevelsDirection(trackID: trackID, spreadZoneID: chop[3].id,
                                                direction: .centered)
        }
        #expect(Self.zones(store, trackID) == chop, "a refused flip still wrote")

        let ghost = UUID()
        #expect(throws: SixteenLevelsError.zoneNotFound(ghost)) {
            try store.setSixteenLevelsDirection(trackID: trackID, spreadZoneID: ghost,
                                                direction: .up)
        }
        #expect(throws: SixteenLevelsError.zoneNotFound(ghost)) {
            try store.addSixteenLevelsSpread(trackID: trackID, sourceZoneID: ghost)
        }
        // Every refusal is a sentence a person can act on.
        #expect(SixteenLevelsError.notASpread(chop[3].id).errorDescription?
                    .contains("was not changed") == true)
    }

    @Test("⛔ a track that is not playing the Sampler is refused BY NAME")
    @MainActor
    func nonSamplerIsRefused() throws {
        let store = ProjectStore()
        let synth = store.addTrack(name: "Lead Synth", kind: .instrument)
        #expect(throws: SixteenLevelsError.notASampler(trackName: "Lead Synth")) {
            try store.addSixteenLevelsSpread(trackID: synth.id, sourceZoneID: UUID())
        }
        let audio = store.addTrack(name: "Vox", kind: .audio)
        #expect(throws: SixteenLevelsError.notASampler(trackName: "Vox")) {
            try store.setSixteenLevelsDirection(trackID: audio.id, spreadZoneID: UUID(),
                                                direction: .up)
        }
        #expect(throws: ProjectError.self) {
            try store.addSixteenLevelsSpread(trackID: UUID(), sourceZoneID: UUID())
        }
    }

    @Test("⛔ a keymap with no sixteen free keys refuses rather than overlapping")
    @MainActor
    func fullKeymapRefuses() throws {
        let store = ProjectStore()
        store.media = FakeMedia()
        let track = store.addTrack(name: "Wall", kind: .instrument)
        let full = (0...127).map {
            SamplerZone(audioFileURL: Self.ping, rootPitch: $0, minPitch: $0, maxPitch: $0)
        }
        try store.setInstrument(id: track.id, kind: .sampler, sampler: SamplerParams(zones: full))
        #expect(throws: SixteenLevelsError.noFreeWindow) {
            try store.addSixteenLevelsSpread(trackID: track.id, sourceZoneID: full[60].id)
        }
        #expect(Self.zones(store, track.id) == full)
    }

    // MARK: - 3. PERSISTENCE

    /// ⭐⭐ **THE DIRECTION PERSISTS WITH THE SPREAD, AND THIS IS THE PROOF.**
    /// A CENTRED spread and an UP spread in one kit, saved and reopened: each
    /// comes back with its own root, reads back as its own direction, and — the
    /// claim a user would actually notice — every key of it plays the same
    /// interval it played before the save. A spread whose meaning silently
    /// changed on reload would fail the last loop.
    @Test("⭐⭐ a CENTRED spread survives save → reopen as CENTRED, key for key")
    @MainActor
    func directionSurvivesSaveAndReopen() throws {
        let dir = tempDir()
        let (store, trackID, chop) = try Self.sampledStore()
        let centred = try store.addSixteenLevelsSpread(trackID: trackID,
                                                       sourceZoneID: chop[2].id,
                                                       direction: .centered)
        let up = try store.addSixteenLevelsSpread(trackID: trackID,
                                                  sourceZoneID: chop[5].id, direction: .up)
        // Two distinct windows: `freeBase` prefers directly below the LOWEST
        // zone, and after the first spread that zone is the spread itself.
        #expect(centred.minPitch == 20)
        #expect(up.minPitch == 4)
        let saved = Self.zones(store, trackID)

        let path = dir.appendingPathComponent("Levels Kit").path
        _ = try store.saveProject(to: path)
        let reopened = ProjectStore()
        reopened.media = FakeMedia()
        let warnings = try reopened.openProject(at: path)
        #expect(warnings.isEmpty, "unexpected load warnings: \(warnings)")
        let loaded = reopened.tracks.first?.instrument?.sampler?.zones ?? []

        #expect(loaded.count == saved.count)
        for (label, original, expected) in [("centred", centred, SixteenLevels.Direction.centered),
                                            ("up", up, .up)] {
            let back = try #require(loaded.first { $0.id == original.id },
                                    "the \(label) spread did not come back")
            #expect(SixteenLevels.direction(of: back) == expected,
                    "the \(label) spread reopened as \(String(describing: SixteenLevels.direction(of: back)))")
            #expect(back.rootPitch == original.rootPitch)
            #expect(back.minPitch == original.minPitch)
            #expect(back.maxPitch == original.maxPitch)
            for pitch in original.minPitch...original.maxPitch {
                #expect(SixteenLevels.semitones(atPitch: pitch, on: back)
                        == SixteenLevels.semitones(atPitch: pitch, on: original),
                        "the \(label) spread's key \(pitch) plays a different interval after reopen")
            }
        }
        // The chop itself round-trips untouched beside them.
        for slice in chop {
            let back = try #require(loaded.first { $0.id == slice.id })
            #expect(back.rootPitch == slice.rootPitch)
            #expect(back.minPitch == slice.minPitch)
            #expect(back.maxPitch == slice.maxPitch)
            #expect(back.startFrame == slice.startFrame)
            #expect(back.endFrame == slice.endFrame)
        }
        // CONTROL: the centred key that plays the recording unshifted is pad 9's.
        let centredBack = try #require(loaded.first { $0.id == centred.id })
        #expect(SixteenLevels.semitones(atPitch: centredBack.minPitch + 8, on: centredBack) == 0)
        #expect(SixteenLevels.semitones(atPitch: centredBack.minPitch, on: centredBack) == -8)
        #expect(SixteenLevels.semitones(atPitch: centredBack.maxPitch, on: centredBack) == 7)
    }

    // MARK: - 4. RECOGNITION AFTER A REOPEN (m39-levels-3)

    /// ⭐⭐ **THE PAD GRID NAMES A REOPENED SPREAD'S SLICE THROUGH THIS, AND IT
    /// ONLY WORKS BECAUSE OF THE BUNDLE.** `sourceSlice(of:in:)` matches on
    /// `sourceFileKey` + frame window. A save RELOCATES every zone's file into
    /// the bundle's `media/`, so the claim that a spread and its source still
    /// share a file after a reopen is a claim about `ProjectBundle`'s dedupe
    /// (keyed by `sourceFileKey`), not about `SixteenLevels`. This asserts it on
    /// the real save → open path, and that the relocation really happened —
    /// an equality between two un-relocated paths would pass without proving it.
    @Test("⭐⭐ after save → reopen, the spread still finds its source slice, and only spreads read as spreads")
    @MainActor
    func sourceIsRecoveredAfterReopen() throws {
        let dir = tempDir()
        let (store, trackID, chop) = try Self.sampledStore()
        let spread = try store.addSixteenLevelsSpread(trackID: trackID,
                                                      sourceZoneID: chop[2].id,
                                                      direction: .centered)
        let path = dir.appendingPathComponent("Levels Recognise").path
        _ = try store.saveProject(to: path)
        let reopened = ProjectStore()
        reopened.media = FakeMedia()
        let warnings = try reopened.openProject(at: path)
        #expect(warnings.isEmpty, "unexpected load warnings: \(warnings)")
        let loaded = reopened.tracks.first?.instrument?.sampler?.zones ?? []

        let spreadBack = try #require(loaded.first { $0.id == spread.id })
        let sourceBack = try #require(loaded.first { $0.id == chop[2].id })
        // The relocation happened — both now name the bundle's copy, not Ping.
        #expect(spreadBack.audioFileURL != Self.ping)
        #expect(spreadBack.sourceFileKey == sourceBack.sourceFileKey)
        #expect(SixteenLevels.sourceSlice(of: spreadBack, in: loaded)?.id == chop[2].id)
        // Exactly one zone of ten is a spread, by the one predicate.
        #expect(loaded.filter(SixteenLevels.isSpread).map(\.id) == [spread.id])
    }
}
