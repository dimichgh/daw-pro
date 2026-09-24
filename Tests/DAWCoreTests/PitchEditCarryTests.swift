import Foundation
import Testing
@testable import DAWCore

// m23-q — THE CARRY GATE for `Clip.pitchEdits`.
//
// ═══════════════════════════════════════════════════════════════════════════
// WHY THIS SUITE EXISTS, AND WHY IT IS AN ASSERTION ABOUT *IDENTITY*
// ═══════════════════════════════════════════════════════════════════════════
//
// Seven `Clip(...)` construction sites in `Sources/DAWCore` REBUILD an existing
// clip field-by-field. Every one of them is a hand-maintained argument list the
// compiler cannot check: omit a field and it silently takes its default. That is
// exactly how `gainEnvelope` vanished from take lanes from m13-e until m16-b3,
// and how `controllerLanes` inherited the same gap.
//
// ⚠️⚠️ **THE ASSERTION IS "THE TIMES ARE UNCHANGED", NOT "A SET IS PRESENT".**
// `NoteSegment.startSeconds`/`endSeconds` are SOURCE-FILE-ABSOLUTE seconds — the
// domain `ClipPitchFrame.timeSeconds` documents as "geometry-free: trims/splits
// don't move these numbers", and the domain `PitchCorrection.swift`'s banner
// rules authoritative. So the correct carry at EVERY site is VERBATIM: no
// windowing, no filtering, and above all **no rebasing to the new clip's
// origin**.
//
// A nil-check would pass against a rebased carry, and a rebased carry is the
// MORE LIKELY bug — it is what "the second half starts at the split point" makes
// a reader want to write. `windowedGainEnvelope`/`windowedControllerLanes` sit
// three lines above every one of these sites doing exactly that re-anchoring,
// because THOSE fields are clip-relative BEATS. Copying their shape onto this
// field would corrupt every segment on the right-hand side of a split while
// leaving a non-nil set in place to look healthy.
//
// Each split/trim leg therefore pins the LITERAL second values, and names the
// number a rebasing implementation would have produced instead.
//
// ═══════════════════════════════════════════════════════════════════════════
// NO FILTER AT `CompFlattener.flatten` EITHER — AND THAT IS A CORRECTION
// ═══════════════════════════════════════════════════════════════════════════
//
// Design §7.5 says comping's mapping is "a filter, not a transform". The
// "not a transform" half is the load-bearing one and this suite pins it. The
// "filter" half is NOT implemented, deliberately: `CompFlattener.applyCrossfades`
// runs AFTER the member `Clip(...)` is built and WIDENS members (the left grows
// `lengthBeats`, the right moves `startBeat` back and reduces
// `startOffsetSeconds`). A filter computed from the pre-crossfade source window
// would drop segments the member then goes on to PLAY through its fade — audible
// as one side of a comp join tuned and the other side not. An unfiltered carry
// costs nothing: a segment outside the window the member plays is never
// evaluated, because the curve is only read over that window.
//
// Scope: this is a model-layer carry gate. It adds no user-facing operation, so
// there is no control-protocol verb and no MCP tool to expose.

// MARK: - Fixtures

/// Fixed ids so a failure message names a stable segment rather than a fresh
/// UUID, and so `PitchEditSet: Equatable` (which includes `NoteSegment.id`)
/// compares meaningfully across a rebuild.
private let segAID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-00000000000A")!
private let segBID = UUID(uuidString: "BBBBBBBB-0000-0000-0000-00000000000B")!

/// THE planted set. **Load-bearing shape, do not simplify:**
///  * TWO segments with DISTINCT times, so a carry that kept only one, or that
///    re-ordered them, is visible.
///  * Segment A spans source 0.25…0.90 s, which at 120 BPM ratio 1 is timeline
///    beat 0.5…1.8 — it STRADDLES the beat-1 split point every split leg uses.
///    A "keep only what falls in this half" implementation has to decide
///    something about it, and this pins that the answer is "both halves keep it
///    whole".
///  * Segment B starts at source 1.10 s. After a split at beat 1 (= 0.50 s) a
///    REBASED implementation would write 0.60. That number is asserted against
///    by name below.
///  * Non-zero `pitchOffsetCents` on both, and a non-default `vibratoScale` on
///    B, so `isIdentity` is false and `Clip.init`'s empty→nil normalisation
///    cannot be what makes a leg pass.
///  * `retuneMs: 120`, NOT the 30 ms floor, because `PitchEditSet.encode` omits
///    the key at the floor — a set-level field that defaults on a lossy path
///    would be invisible at the default.
private func plantedSet() -> PitchEditSet {
    PitchEditSet(
        analysisVersion: PitchEditSet.currentAnalysisVersion,
        segments: [
            NoteSegment(id: segAID, startSeconds: 0.25, endSeconds: 0.90,
                        detectedHz: 220.0, detectedConfidence: 0.91,
                        pitchOffsetCents: -18.5),
            NoteSegment(id: segBID, startSeconds: 1.10, endSeconds: 1.80,
                        detectedHz: 246.94, detectedConfidence: 0.83,
                        pitchOffsetCents: 11.25, vibratoScale: 0.5),
        ],
        retuneMs: 120)
}

/// A 4-beat audio clip carrying the planted set. At 120 BPM with ratio 1 its
/// source window is exactly [0, 2) seconds, so every planted segment lies inside
/// the material the clip actually reads.
private func plantedClip(id: UUID = UUID(), startBeat: Double = 0,
                         lengthBeats: Double = 4) -> Clip {
    Clip(id: id, name: "Vocal",
         startBeat: startBeat, lengthBeats: lengthBeats,
         audioFileURL: URL(fileURLWithPath: "/tmp/daw-pro-m23q-carry.wav"),
         gainDb: -3,
         gainEnvelope: [ClipGainPoint(beat: 0, gainDb: 0),
                        ClipGainPoint(beat: 4, gainDb: -12)],
         pitchEdits: plantedSet())
}

private let bpm120 = TempoMap(constantBPM: 120)

// MARK: - The suite

@MainActor
@Suite("Pitch edits survive every clip rebuild (m23-q)")
struct PitchEditCarryTests {

    /// FIXTURE PIN. If this reddens, every other leg below is reasoning about
    /// the wrong numbers — read this one first.
    @Test("FIXTURE PIN: the planted set survives `Clip.init` byte-for-byte")
    func fixturePin() {
        let planted = plantedSet()
        let clip = plantedClip()
        #expect(clip.pitchEdits == planted)
        #expect(clip.pitchEdits?.segments.count == 2)
        #expect(clip.pitchEdits?.segments[0].startSeconds == 0.25)
        #expect(clip.pitchEdits?.segments[0].endSeconds == 0.90)
        #expect(clip.pitchEdits?.segments[1].startSeconds == 1.10)
        #expect(clip.pitchEdits?.segments[1].endSeconds == 1.80)
        #expect(clip.pitchEdits?.retuneMs == 120)
        #expect(clip.hasPitchEdits)
        // The clip's own source window is [0, 2) s — the planted segments are
        // material it really reads, not decoration outside it.
        #expect(clip.sourceWindowSeconds(tempoMap: bpm120) == 2.0)
    }

    // MARK: - 1 + 2. `ProjectStore.splitClip` — TWO sites, one per half

    @Test("split: BOTH halves keep the WHOLE set, with source times UNMOVED")
    func splitCarriesBothHalves() throws {
        let planted = plantedSet()
        let clip = plantedClip()
        let track = Track(name: "V", kind: .audio, clips: [clip])
        let store = ProjectStore(tracks: [track])

        let (first, second) = try store.splitClip(
            trackId: track.id, clipId: clip.id, atBeat: 1)

        // The geometry really did split (otherwise a carry proves nothing).
        #expect(first.lengthBeats == 1)
        #expect(second.lengthBeats == 3)
        #expect(second.startOffsetSeconds == 0.5)

        #expect(first.pitchEdits == planted)
        #expect(second.pitchEdits == planted)

        // NO REBASE. Segment B sits at source 1.10 s on BOTH halves. A rebased
        // second half would read 1.10 − 0.50 = 0.60; a filtered one would have
        // dropped it from the first half entirely.
        #expect(first.pitchEdits?.segments.count == 2)
        #expect(second.pitchEdits?.segments.count == 2)
        #expect(second.pitchEdits?.segments[1].startSeconds == 1.10)
        #expect(second.pitchEdits?.segments[1].endSeconds == 1.80)
        #expect(second.pitchEdits?.segments[1].startSeconds != 0.60)
        // Segment A STRADDLES the split (source 0.25…0.90, cut at 0.50): both
        // halves keep it whole and untruncated.
        #expect(first.pitchEdits?.segments[0].endSeconds == 0.90)
        #expect(second.pitchEdits?.segments[0].startSeconds == 0.25)
        // Set-level state rides along too.
        #expect(first.pitchEdits?.retuneMs == 120)
        #expect(second.pitchEdits?.retuneMs == 120)
        #expect(second.pitchEdits?.segments[1].pitchOffsetCents == 11.25)
        #expect(second.pitchEdits?.segments[1].vibratoScale == 0.5)

        // And the stored clips agree with the returned values.
        #expect(store.tracks[0].clips[0].pitchEdits == planted)
        #expect(store.tracks[0].clips[1].pitchEdits == planted)
    }

    // MARK: - 3. `ProjectStore.applyTrimWindow` (the live `trimClip` path)

    @Test("trim: the moved leading edge does not move the segments")
    func trimCarries() throws {
        let planted = plantedSet()
        let clip = plantedClip()
        let track = Track(name: "V", kind: .audio, clips: [clip])
        let store = ProjectStore(tracks: [track])

        // Pull the head in by 1 beat: window [1,3], length 2, source offset 0.5.
        let trimmed = try store.trimClip(trackId: track.id, clipId: clip.id,
                                         newStartBeat: 1, newLengthBeats: 2)
        #expect(trimmed.lengthBeats == 2)
        #expect(trimmed.startOffsetSeconds == 0.5)

        #expect(trimmed.pitchEdits == planted)
        // Segment B is at 1.10 s, NOT 0.60 — the trim advanced
        // `startOffsetSeconds`, which is precisely what makes rebasing wrong.
        #expect(trimmed.pitchEdits?.segments[1].startSeconds == 1.10)
        #expect(trimmed.pitchEdits?.segments[1].startSeconds != 0.60)
        // Segment A now lies partly BEFORE the trimmed head (0.25 < 0.5) and is
        // still kept whole — a trim is reversible, so discarding it would be
        // losing tuning the user can drag back into view.
        #expect(trimmed.pitchEdits?.segments[0].startSeconds == 0.25)
        #expect(trimmed.pitchEdits?.segments.count == 2)
        #expect(store.tracks[0].clips[0].pitchEdits == planted)
    }

    // MARK: - 4. `ProjectStore.clipTrimmedToWindow` (pure, no journaling)

    @Test("clipTrimmedToWindow: the un-journalled trim carries the set verbatim")
    func clipTrimmedToWindowCarries() throws {
        let planted = plantedSet()
        let clip = plantedClip()
        let out = try #require(ProjectStore.clipTrimmedToWindow(
            clip, newStart: 2, newLength: 2, tempoMap: bpm120))
        #expect(out.startOffsetSeconds == 1.0)
        #expect(out.pitchEdits == planted)
        #expect(out.pitchEdits?.segments.count == 2)
        #expect(out.pitchEdits?.segments[0].startSeconds == 0.25)
        #expect(out.pitchEdits?.segments[1].startSeconds == 1.10)
        #expect(out.pitchEdits?.retuneMs == 120)
    }

    @Test("overlap resolution routes through it live — a trimmed resident keeps its tuning")
    func overlapTrimCarries() throws {
        let planted = plantedSet()
        let resident = plantedClip(startBeat: 0, lengthBeats: 4)
        let mover = Clip(name: "Other", startBeat: 8, lengthBeats: 4,
                         audioFileURL: URL(fileURLWithPath: "/tmp/daw-pro-m23q-other.wav"))
        let track = Track(name: "V", kind: .audio, clips: [resident, mover])
        let store = ProjectStore(tracks: [track])

        // Land the mover over the resident's tail: the resident trims to [0,2]
        // through the ONE no-silent-overlap choke point.
        _ = try store.moveClip(trackId: track.id, clipId: mover.id, toStartBeat: 2)
        let trimmed = try #require(store.tracks[0].clips.first { $0.id == resident.id })
        #expect(trimmed.lengthBeats == 2)
        #expect(trimmed.pitchEdits == planted)
        #expect(trimmed.pitchEdits?.segments.count == 2)
        #expect(trimmed.pitchEdits?.segments[1].startSeconds == 1.10)
    }

    // MARK: - 5. `ProjectStore.reidentified` (duplicate / paste / insert+deleteBars tails)

    @Test("reidentified: a fresh identity is not a fresh performance")
    func reidentifiedCarries() {
        let planted = plantedSet()
        let clip = plantedClip()
        let out = ProjectStore.reidentified(clip, id: UUID(), startBeat: 16)
        #expect(out.id != clip.id)          // it really did re-mint
        #expect(out.takeGroupID == nil)     // and really did drop the group marker
        #expect(out.pitchEdits == planted)
        #expect(out.pitchEdits?.segments.count == 2)
        #expect(out.pitchEdits?.segments[0].pitchOffsetCents == -18.5)
        #expect(out.pitchEdits?.segments[1].startSeconds == 1.10)
        #expect(out.pitchEdits?.retuneMs == 120)
    }

    @Test("duplicateClip: the copy of a tuned vocal is tuned")
    func duplicateCarries() throws {
        let planted = plantedSet()
        let clip = plantedClip()
        let track = Track(name: "V", kind: .audio, clips: [clip])
        let store = ProjectStore(tracks: [track])

        _ = try store.duplicateClip(clipId: clip.id, toStartBeat: 16)
        let copy = try #require(store.tracks[0].clips.first { $0.id != clip.id })
        #expect(copy.startBeat == 16)
        #expect(copy.pitchEdits == planted)
        #expect(copy.pitchEdits?.segments[1].startSeconds == 1.10)
    }

    // MARK: - 6. `CompFlattener.flatten` — comp materialisation

    @Test("flatten: a comp member carries its lane's set, unfiltered and unmoved")
    func flattenCarries() {
        let planted = plantedSet()
        let lane = TakeLane(name: "Take 1", clip: plantedClip(startBeat: 0, lengthBeats: 4))
        var group = TakeGroup(id: UUID(), name: "G", lanes: [lane])
        // A comp window over the SECOND half only: source [1, 2) s. Segment A
        // (0.25…0.90 s) lies wholly OUTSIDE it — the leg that would redden under
        // a window filter.
        group.comp = [CompSegment(laneID: lane.id, startBeat: 2, endBeat: 4)]

        let members = CompFlattener.flatten(group, tempoMap: bpm120)
        #expect(members.count == 1)
        guard let member = members.first else {
            Issue.record("flatten produced no member for a non-empty comp")
            return
        }
        #expect(member.takeGroupID == group.id)
        #expect(member.startOffsetSeconds == 1.0)
        #expect(member.pitchEdits == planted)
        #expect(member.pitchEdits?.segments.count == 2)
        #expect(member.pitchEdits?.segments[0].startSeconds == 0.25)
        #expect(member.pitchEdits?.segments[1].startSeconds == 1.10)
        #expect(member.pitchEdits?.retuneMs == 120)
    }

    @Test("flatten across a crossfaded join: BOTH members keep the set")
    func flattenCrossfadedJoinCarries() {
        let planted = plantedSet()
        let laneA = TakeLane(name: "Take 1", clip: plantedClip(startBeat: 0, lengthBeats: 4))
        let laneB = TakeLane(name: "Take 2", clip: plantedClip(startBeat: 0, lengthBeats: 4))
        var group = TakeGroup(id: UUID(), name: "G", lanes: [laneA, laneB])
        group.crossfadeSeconds = 0.02
        group.comp = [
            CompSegment(laneID: laneA.id, startBeat: 0, endBeat: 2),
            CompSegment(laneID: laneB.id, startBeat: 2, endBeat: 4),
        ]
        let members = CompFlattener.flatten(group, tempoMap: bpm120)
        #expect(members.count == 2)
        // The join really was crossfaded — this is the geometry a pre-crossfade
        // window filter would have computed against and got wrong.
        #expect(members.first?.fadeOutBeats ?? 0 > 0)
        #expect(members.last?.fadeInBeats ?? 0 > 0)
        for member in members {
            #expect(member.pitchEdits == planted)
            #expect(member.pitchEdits?.segments.count == 2)
        }
    }

    // MARK: - 7. `AudioQuantize.makeSlice` — the chop

    @Test("audio quantize: every slice keeps the whole set at its original times")
    func audioQuantizeSlicesCarry() throws {
        let planted = plantedSet()
        let clip = plantedClip()
        // `divisions` chops without consulting the detector, so this leg needs no
        // transient fixture (and `transientsSourceSeconds` is ignored on it).
        let settings = AudioQuantizeSettings(gridBeats: 1, strength: 0, divisions: 2)
        let slices = try AudioQuantizePlan.compute(
            clip: clip, transientsSourceSeconds: [], tempoMap: bpm120, settings: settings)

        #expect(slices.count == 2)
        // The slices really do read different source windows — so a carry here
        // is a decision, not an accident of them all being the same clip.
        #expect(slices[0].startOffsetSeconds != slices[1].startOffsetSeconds)
        for slice in slices {
            #expect(slice.pitchEdits == planted)
            #expect(slice.pitchEdits?.segments.count == 2)
            #expect(slice.pitchEdits?.segments[0].startSeconds == 0.25)
            #expect(slice.pitchEdits?.segments[1].startSeconds == 1.10)
            #expect(slice.pitchEdits?.retuneMs == 120)
        }
    }

    // MARK: - 8. REGRESSION GUARD — the site that was NEVER broken

    /// `moveClips(ids:byTracks:)` was named in the original hazard census as a
    /// site that drops this field. **It is not one, and the census was wrong.**
    /// It never calls `Clip(...)`: the whole VALUE travels
    /// (`var landed = moving[i]`, `ProjectStore.swift`) and only `startBeat` is
    /// written. This leg exists so a future refactor that "tidies" that into an
    /// explicit rebuild reddens instead of silently joining the other seven.
    @Test("REGRESSION GUARD: cross-track move carries for free (no rebuild on the path)")
    func crossTrackMoveCarries() throws {
        let planted = plantedSet()
        let clip = plantedClip()
        let store = ProjectStore(tracks: [
            Track(name: "A", kind: .audio, clips: [clip]),
            Track(name: "B", kind: .audio),
        ])
        _ = try store.moveClips(ids: [clip.id], byTracks: 1)
        let moved = try #require(store.tracks[1].clips.first { $0.id == clip.id })
        #expect(moved.pitchEdits == planted)
        #expect(moved.pitchEdits?.segments[1].startSeconds == 1.10)
        #expect(store.tracks[0].clips.isEmpty)
    }

    // MARK: - 9. The persistence pair (already threaded — pinned so it stays)

    @Test("save → reopen: both ClipDocument reconstructions keep the set")
    func persistenceCarries() throws {
        let planted = plantedSet()
        let clip = plantedClip()
        // The ordinary-clip reconstruction.
        let doc = ClipDocument(from: clip, media: nil)
        let rebuilt = try JSONDecoder().decode(
            ClipDocument.self, from: JSONEncoder().encode(doc))
        #expect(rebuilt.pitchEdits == planted)
        #expect(rebuilt.pitchEdits?.segments[1].startSeconds == 1.10)

        // An EMPTY set must still write no key — a project with no tuning stays
        // byte-identical to one saved before this field existed.
        let plain = Clip(name: "plain", lengthBeats: 4,
                         audioFileURL: URL(fileURLWithPath: "/tmp/x.wav"))
        let plainObj = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(ClipDocument(from: plain, media: nil))) as? [String: Any]
        #expect(plainObj?["pitchEdits"] == nil)
    }
}
