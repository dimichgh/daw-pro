import Foundation
import Testing
@testable import DAWCore

/// m25-a-2 — **TELLING THE USER WHEN AUTO-EXTEND REFUSES.**
///
/// The user's report: *"It should warn with signal or something and direct user
/// or give a clue to extend the clips or place note to the active clip zone."*
/// Auto-extend refuses rather than partially growing (a ratified decision), and
/// it did so in total silence — the note was written, stayed latent, and nothing
/// visible happened.
///
/// ⛔⛔ **THE TRAP THIS SUITE EXISTS TO PIN.** `extendedLength` returns `nil` on
/// FOUR distinct paths and only THREE are refusals. The fourth — *the notes
/// already fit* — is the ORDINARY case and fires on essentially every note edit
/// inside a clip. `if grownLength == nil { warn }` would therefore fire an amber
/// bubble on every ordinary edit, which is far worse than the silence being
/// fixed. Every `.notNeeded` row below is there to keep that from creeping back.
///
/// ⚠️ **THIS ITEM IS REPORT-ONLY.** It changes which words the user sees and not
/// one growth decision. `reportOnlyDifferential` is the proof: the shipped
/// `extendedLength` is replayed against a body-for-body copy of the pre-m25-a-2
/// arithmetic and must agree bit-exactly, nil-for-nil.
@Suite("m25-a-2 — the auto-extend outcome, NAMED")
struct ClipAutoExtendOutcomeTests {

    /// One row of the outcome table. Every beat value is a LITERAL, never
    /// derived from `ClipAutoExtend.maxGrowthBars` — see
    /// `failSetDiscrimination` for why a derived fixture would be vacuous.
    private struct Row {
        var label: String
        var current: Double = 4
        var onset: Double
        var end: Double
        var bpb: Int = 4
        var maxLength: Double?
        var expected: ClipAutoExtend.ExtendOutcome
    }

    private func check(_ row: Row, sourceLocation: SourceLocation = #_sourceLocation) {
        let got = ClipAutoExtend.outcome(
            currentLengthBeats: row.current, coveringOnsetBeat: row.onset,
            coveringEndBeat: row.end, beatsPerBar: row.bpb,
            maxLengthBeats: row.maxLength)
        #expect(got == row.expected,
                "\(row.label): expected \(row.expected), got \(got)",
                sourceLocation: sourceLocation)
    }

    // MARK: - The outcome table — ONE ROW PER OUTCOME

    /// A 4-beat (one bar, 4/4) clip throughout, so every row differs from its
    /// neighbours in as few inputs as possible.
    @Test("the five outcomes, one row each")
    func theOutcomeTable() {
        let rows: [Row] = [
            // ① NOT A REFUSAL. The note lands inside the clip; nothing is wrong.
            Row(label: "① notes already fit", onset: 2, end: 3,
                maxLength: nil, expected: .notNeeded),

            // ② The ordinary success: grow to the next bar line past the end.
            Row(label: "② grows to the next bar", onset: 5, end: 6,
                maxLength: nil, expected: .grew(8)),

            // ③ The neighbour is FLUSH — `maxLengthBeats <= current`, so no
            //    growth was EVER possible. This is the only way to reach the
            //    "ceilings squeezed it flat" refusal (see `ceilingsFlatIsAlways
            //    TheNeighbour`).
            Row(label: "③ flush neighbour, no room at all", onset: 5, end: 6,
                maxLength: 4, expected: .refusedByNeighbour),

            // ④ Room to grow, but only as far as the neighbour — and the onset
            //    lands exactly on that new edge, so it would still be silent.
            Row(label: "④ neighbour clamps below the onset", onset: 6, end: 7,
                maxLength: 6, expected: .refusedByNeighbour),

            // ⑤ Nothing on the track at all; the note is simply far past the
            //    end. 101 beats is ~24 bars out, beyond the 16-bar cap.
            //    ⚠️ `maxLength: nil` IS THE ANTI-VACUITY CONDITION — with a
            //    neighbour in the fixture this row would be testing the
            //    neighbour while claiming to test the cap (the m25-f-4 defect).
            Row(label: "⑤ far past the end, no neighbour", onset: 100, end: 101,
                maxLength: nil, expected: .refusedByGrowthCap),

            // ⑥ No ceiling in play: the bar-snapped end IS the target, and the
            //    onset sits exactly on it. Engine truth is a strict `<`.
            Row(label: "⑥ onset exactly at the grown end", onset: 8, end: 8,
                maxLength: nil, expected: .refusedOnsetStillLatent)
        ]
        for row in rows { check(row) }
    }

    // MARK: - Anti-vacuity controls: flip exactly ONE input, land in another case

    /// ⭐ **EACH CONTROL FLIPS EXACTLY ONE FIELD OF ITS ROW.** A control that
    /// changes two inputs proves only that two different fixtures differ; a
    /// control that lands in the SAME case proves nothing at all. m25-f-4 shipped
    /// a control whose fixture sat beyond the 16-bar cap, so it exercised the
    /// growth cap while claiming to test something else — these are written to
    /// make that mistake visible.
    @Test("every refusal row has a one-input control that lands elsewhere")
    func antiVacuityControls() {
        // ③ flush neighbour → REMOVE the neighbour (one field) → it grows.
        check(Row(label: "③ control: no neighbour", onset: 5, end: 6,
                  maxLength: nil, expected: .grew(8)))

        // ④ neighbour at 6 → move it to 8 (one field) → the onset fits.
        check(Row(label: "④ control: neighbour further out", onset: 6, end: 7,
                  maxLength: 8, expected: .grew(8)))

        // ⑤ cap → pull the ONSET back inside the cap, leaving the END where it
        //    is (one field). The cap STILL clamps the target to 68 — so this is
        //    not "the cap stopped applying", it is "the cap alone never refuses".
        //    That distinction is the whole content of the control.
        check(Row(label: "⑤ control: onset inside the capped target",
                  onset: 5, end: 101, maxLength: nil, expected: .grew(68)))

        // ⑥ onset exactly at the end → a hair earlier (one field) → audible.
        check(Row(label: "⑥ control: onset a hair before the end",
                  onset: 7.9, end: 8, maxLength: nil, expected: .grew(8)))

        // ① is the control for all of them: the same clip, a note inside it.
        check(Row(label: "① control: nothing to do", onset: 1, end: 2,
                  maxLength: 4, expected: .notNeeded))
    }

    // MARK: - The tiebreak, pinned

    /// ⭐⭐ **WHEN BOTH CEILINGS SIT AT THE SAME VALUE THE BLAME IS THE
    /// NEIGHBOUR** — it is the more actionable obstacle and the only one of the
    /// two the user can SEE (a clip on the track, which they can drag); the
    /// growth cap is an invisible policy constant.
    ///
    /// A one-beat sweep across the tie is what makes this a real pin rather than
    /// a restatement: at 67 and 68 the neighbour is the (weakly) lower ceiling,
    /// at 69 the cap is strictly lower and the verdict must flip.
    @Test("⚠️ equal ceilings blame the NEIGHBOUR — the boundary swept, not asserted")
    func theTiebreak() {
        // current 4, 4/4 → the growth ceiling is 4 + 16*4 = 68.
        // end 101 → bar-snapped ideal 104, so both ceilings are in play.
        check(Row(label: "neighbour strictly lower", onset: 100, end: 101,
                  maxLength: 67, expected: .refusedByNeighbour))
        check(Row(label: "⭐ THE TIE — both ceilings at 68", onset: 100, end: 101,
                  maxLength: 68, expected: .refusedByNeighbour))
        check(Row(label: "cap strictly lower", onset: 100, end: 101,
                  maxLength: 69, expected: .refusedByGrowthCap))
    }

    /// The other half of the neighbour's own coverage: `maxLengthBeats` at or
    /// below the current length means the neighbour is already flush and no
    /// growth was ever possible — unambiguously the neighbour, at every meter.
    @Test("a neighbour at or inside the current end is always the neighbour case")
    func flushNeighbourAtEveryMeter() {
        for bpb in [1, 2, 3, 4, 5, 7, 12] {
            check(Row(label: "flush at bpb \(bpb)", onset: 5, end: 6, bpb: bpb,
                      maxLength: 4, expected: .refusedByNeighbour))
            check(Row(label: "overlapping at bpb \(bpb)", onset: 5, end: 6, bpb: bpb,
                      maxLength: 3, expected: .refusedByNeighbour))
        }
    }

    /// ⚠️ **MEASURED, NOT ASSUMED (m25-a-2, 52,254,720-fixture sweep):** the
    /// "ceilings squeezed it flat" refusal can NEVER be caused by the growth cap.
    /// `currentLengthBeats + maxGrowthBars * bpb` with `bpb >= 1` is always more
    /// than epsilon above the current length, so only `maxLengthBeats` can push
    /// the target down to it. This test re-runs the discriminating slice of that
    /// sweep in the suite: with NO neighbour, no fixture anywhere reaches that
    /// refusal — the cap's bite lands on the audibility test instead.
    @Test("with no neighbour, the growth cap alone NEVER refuses for lack of room")
    func ceilingsFlatIsAlwaysTheNeighbour() {
        var sawCapRefusal = 0
        var sawSomething = 0
        for current in stride(from: 0.25, through: 32.0, by: 0.25) {
            for bpb in [1, 2, 3, 4, 5, 7, 12] {
                for end in stride(from: current + 0.001, through: current + 400, by: 3.7) {
                    sawSomething += 1
                    // Onset pinned inside so only the ROOM test can fire; the
                    // audibility test is deliberately taken out of the picture.
                    let o = ClipAutoExtend.outcome(
                        currentLengthBeats: current, coveringOnsetBeat: 0,
                        coveringEndBeat: end, beatsPerBar: bpb, maxLengthBeats: nil)
                    if o == .refusedByGrowthCap || o == .refusedByNeighbour { sawCapRefusal += 1 }
                }
            }
        }
        // Positive control: the sweep RAN and reached real fixtures. Without it a
        // loop that never executed would report the same clean zero.
        // MEASURED 97,664 fixtures; the floor is set below that rather than at a
        // round guess, because the first version of this line guessed 100_000 and
        // reddened on its own control — which is the control doing its job.
        print("[measured] m25-a-2 no-neighbour sweep: \(sawSomething) fixtures, \(sawCapRefusal) room refusals")
        #expect(sawSomething > 90_000, "the sweep did not run — the zero below proves nothing")
        #expect(sawCapRefusal == 0,
                "a no-neighbour fixture reached a room refusal — the arithmetic this feature's blame logic rests on has changed")
    }

    // MARK: - REPORT-ONLY: not one growth decision may move

    /// A body-for-body copy of `ClipAutoExtend.extendedLength` as it stood at
    /// HEAD before m25-a-2 (`git show HEAD:Sources/DAWCore/ClipAutoExtend.swift`,
    /// lines 134–158). Kept here rather than described, so the differential
    /// compares CODE against CODE.
    private enum PreM25A2 {
        static let epsilon: Double = 1e-9
        static let maxGrowthBars: Int = 16

        static func extendedLength(
            currentLengthBeats: Double, coveringOnsetBeat: Double,
            coveringEndBeat: Double, beatsPerBar: Int, maxLengthBeats: Double? = nil
        ) -> Double? {
            guard coveringEndBeat > currentLengthBeats + epsilon else { return nil }
            var target = barSnappedLength(coveringEndBeat, beatsPerBar: beatsPerBar)
            let bpb = Double(Swift.max(1, beatsPerBar))
            target = Swift.min(target, currentLengthBeats + Double(maxGrowthBars) * bpb)
            if let maxLengthBeats { target = Swift.min(target, maxLengthBeats) }
            guard target > currentLengthBeats + epsilon else { return nil }
            guard coveringOnsetBeat < target else { return nil }
            return target
        }

        static func barSnappedLength(_ endBeat: Double, beatsPerBar: Int) -> Double {
            let bpb = Double(Swift.max(1, beatsPerBar))
            guard endBeat > 0 else { return bpb }
            let bars = (endBeat / bpb).rounded(.up)
            let snapped = bars * bpb
            return snapped < endBeat - epsilon ? snapped + bpb : snapped
        }
    }

    /// ⭐⭐ **THE REPORT-ONLY ARGUMENT, MEASURED.** Every fixture must produce the
    /// SAME answer from the shipped wrapper and from the pre-m25-a-2 body —
    /// nil-for-nil and bit-exact where both return a value — and the wrapper must
    /// agree with its own `outcome(...)`.
    ///
    /// The exhaustive form of this ran once at 52,254,720 fixtures with 0
    /// disagreements (m25-a-2, compiling the shipped source directly); this is
    /// the permanent guard at a size the suite can carry.
    ///
    /// ⚠️ It carries its own NEGATIVE CONTROL: a deliberately wrong variant must
    /// be caught. A differential that cannot see a difference is indistinguish-
    /// able from one that never compared anything.
    @Test("⭐ report-only: the shipped rule agrees with the PRE-m25-a-2 rule on every fixture")
    func reportOnlyDifferential() {
        var compared = 0
        var disagreements = 0
        var wrapperVsOutcome = 0
        for current in [1.0, 4.0, 7.5, 16.0] {
            for bpb in [1, 3, 4, 7] {
                for endOffset in stride(from: -1.0, through: 90.0, by: 0.5) {
                    let end = current + endOffset
                    for onsetGap in [-0.5, -0.001, 0.0, 0.5, 40.0] {
                        let onset = end - onsetGap
                        for maxLength in [nil, 0.0, current, current + 4,
                                          current + 64, 1000.0] as [Double?] {
                            compared += 1
                            let old = PreM25A2.extendedLength(
                                currentLengthBeats: current, coveringOnsetBeat: onset,
                                coveringEndBeat: end, beatsPerBar: bpb,
                                maxLengthBeats: maxLength)
                            let new = ClipAutoExtend.extendedLength(
                                currentLengthBeats: current, coveringOnsetBeat: onset,
                                coveringEndBeat: end, beatsPerBar: bpb,
                                maxLengthBeats: maxLength)
                            switch (old, new) {
                            case (nil, nil): break
                            case (let a?, let b?) where a.bitPattern == b.bitPattern: break
                            default: disagreements += 1
                            }
                            let outcome = ClipAutoExtend.outcome(
                                currentLengthBeats: current, coveringOnsetBeat: onset,
                                coveringEndBeat: end, beatsPerBar: bpb,
                                maxLengthBeats: maxLength)
                            if case .grew(let length) = outcome {
                                if new != length { wrapperVsOutcome += 1 }
                            } else if new != nil {
                                wrapperVsOutcome += 1
                            }
                        }
                    }
                }
            }
        }
        #expect(compared > 20_000, "the differential did not run — the zeros below prove nothing")
        #expect(disagreements == 0, "m25-a-2 changed a GROWTH DECISION; it is report-only")
        #expect(wrapperVsOutcome == 0, "`extendedLength` disagrees with its own `outcome(...)`")

        // NEGATIVE CONTROL — the comparison CAN see a difference.
        var caught = 0
        for end in stride(from: 5.0, through: 200.0, by: 0.5) {
            let old = PreM25A2.extendedLength(
                currentLengthBeats: 4, coveringOnsetBeat: end - 0.5,
                coveringEndBeat: end, beatsPerBar: 4, maxLengthBeats: nil)
            // A wrong rule: the cap raised to 64 bars.
            var mutated = PreM25A2.barSnappedLength(end, beatsPerBar: 4)
            mutated = Swift.min(mutated, 4 + 64 * 4)
            let mutatedResult: Double? = (end - 0.5) < mutated ? mutated : nil
            if old != mutatedResult { caught += 1 }
        }
        #expect(caught > 0, "negative control failed — this differential cannot detect a changed rule")
    }

    // MARK: - The fail SET, not the fail COUNT

    /// ⭐⭐⭐ **HOW TO RUN THE DISCRIMINATION, AND WHY IT IS A SOURCE MUTATION.**
    /// `ClipAutoExtend.maxGrowthBars` is a `static let`, so this cannot be a
    /// runtime parameter (the m25-w precedent). Edit it 16 → **64**, run the full
    /// suite, revert.
    ///
    /// ⚠️ **MUTATE UPWARD.** Lowering the cap leaves the cap row still
    /// cap-refused — verdict unchanged, which proves nothing. Raising it flips
    /// the cap row to `.grew` while everything else must hold.
    ///
    /// ⚠️ **THE FIXTURES ARE LITERAL BEATS ON PURPOSE.** A row written as
    /// `current + Double(ClipAutoExtend.maxGrowthBars) * bpb + 1` MOVES WITH the
    /// constant, so raising the cap would not flip it — a vacuous discrimination
    /// that looks exactly like a passing one.
    ///
    /// **EXPECTED FAIL SET under 16 → 64 — derived BEFORE running it:**
    ///
    /// FLIPS (all of them cap-dependent, and nothing else):
    ///  - `theOutcomeTable` ⑤ — `.refusedByGrowthCap` → `.grew(104)`.
    ///  - `antiVacuityControls` ⑤ — `.grew(68)` → `.grew(260)`.
    ///  - `theTiebreak`, the **69 row only** — the cap at 260 is no longer the
    ///    strictly lower ceiling, so `.refusedByGrowthCap` → `.refusedBy
    ///    Neighbour`. The 67 and 68 rows are UNCHANGED, which is the point: the
    ///    TIE itself does not move, only the row that was leaning on the cap.
    ///  - `theCapConstant` — pins the constant being mutated.
    ///  - `reportOnlyDifferential` — `PreM25A2` pins 16 while the shipped rule
    ///    moves. **That is the differential working**, named here so it is not
    ///    miscounted as a surprise.
    ///
    /// UNCHANGED (the discriminating half — none of these is cap-dependent):
    ///  - `theOutcomeTable` ①②③④⑥ and `antiVacuityControls` ①③④⑥.
    ///  - `theTiebreak` rows 67 and 68.
    ///  - `flushNeighbourAtEveryMeter` — the neighbour binds, never the cap.
    ///  - `ceilingsFlatIsAlwaysTheNeighbour` — its proof depends on the cap
    ///    EXCEEDING epsilon, never on its value.
    ///  - the whole `ClipAutoExtendRefusalStoreTests` neighbour/ordinary/paste
    ///    set; only `capRefusalReported` flips.
    ///
    /// Collateral OUTSIDE this suite, expected and **not** part of the fail set:
    /// `ClipAutoExtendTests` pins the constant at `:100` and exercises the cap.
    @Test("the cap constant is 16 — the anchor the discrimination mutates")
    func theCapConstant() {
        #expect(ClipAutoExtend.maxGrowthBars == 16)
    }

    // MARK: - The message: composed at the store, exhaustively, ONE home

    @Test("⛔ the ORDINARY case says NOTHING — the trap this item exists to avoid")
    func ordinaryCasesAreSilent() {
        #expect(ProjectStore.autoExtendRefusalMessage(.notNeeded) == nil)
        #expect(ProjectStore.autoExtendRefusalMessage(.grew(8)) == nil)
    }

    @Test("each refusal names its OWN obstacle and its OWN remedy")
    func messagesNameTheObstacle() {
        let cap = ProjectStore.autoExtendRefusalMessage(.refusedByGrowthCap)
        let neighbour = ProjectStore.autoExtendRefusalMessage(.refusedByNeighbour)
        let latent = ProjectStore.autoExtendRefusalMessage(.refusedOnsetStillLatent)
        #expect(cap != nil)
        #expect(neighbour != nil)
        #expect(latent != nil)
        // The remedies differ, so naming the wrong obstacle sends the user to do
        // something that cannot work. All three must be DISTINCT strings.
        #expect(Set([cap!, neighbour!, latent!]).count == 3)
        // The cap message states the cap, from the constant (so it survives the
        // fail-set mutation above rather than flipping on wording).
        #expect(cap!.contains("\(ClipAutoExtend.maxGrowthBars) bars"))
        // The neighbour message points at the clip in the way, not at a policy.
        #expect(neighbour!.contains("clip"))
        #expect(neighbour!.contains("Move the next clip"))
        // Rule 6 — beginner-readable prose, not jargon or an error code.
        for message in [cap!, neighbour!, latent!] {
            #expect(message.hasSuffix("."), "a refusal is a sentence: \(message)")
            #expect(!message.contains("beat"), "no unglossed unit jargon: \(message)")
            #expect(message.count > 40, "a one-word refusal teaches nothing: \(message)")
        }
    }
}

/// The store half: BOTH call sites report, through the SAME message helper.
@MainActor
@Suite("m25-a-2 — the store reports the refusal at both call sites")
struct ClipAutoExtendRefusalStoreTests {

    private func midiClip(lengthBeats: Double = 4, atBeat: Double = 0)
        throws -> (store: ProjectStore, trackID: UUID, clip: Clip) {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(
            toTrack: track.id, atBeat: atBeat, lengthBeats: lengthBeats,
            notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)])
        return (store, track.id, clip)
    }

    // MARK: - setClipNotes

    /// ⛔⛔ **THE REGRESSION THIS SUITE EXISTS FOR.** The roll's DELETE key and
    /// its velocity lane both commit through `setClipNotes` with an EMPTY
    /// `extendToCover` on every single press. If "no coverage" ever collapses
    /// into the same answer as a refusal, every one of those presses pops an
    /// amber bubble.
    @Test("⛔ an ordinary edit — and an empty extendToCover — report NOTHING")
    func ordinaryEditsAreSilent() throws {
        let (store, _, clip) = try midiClip()
        let inside = MIDINote(pitch: 62, startBeat: 2, lengthBeats: 1)

        // (a) the DELETE / velocity-lane shape: no ids named at all.
        _ = try store.setClipNotes(clipID: clip.id, notes: (clip.notes ?? []) + [inside])
        #expect(store.lastAutoExtendOutcome == .notNeeded)
        #expect(store.lastAutoExtendRefusal == nil)

        // (b) ids named, but the note lands inside — the ordinary case.
        _ = try store.setClipNotes(clipID: clip.id, notes: (clip.notes ?? []) + [inside],
                                   extendToCover: [inside.id])
        #expect(store.lastAutoExtendOutcome == .notNeeded)
        #expect(store.lastAutoExtendRefusal == nil)

        // (c) ids that name nothing in the submission — `coverage` returns nil.
        _ = try store.setClipNotes(clipID: clip.id, notes: (clip.notes ?? []) + [inside],
                                   extendToCover: [UUID()])
        #expect(store.lastAutoExtendOutcome == .notNeeded)
        #expect(store.lastAutoExtendRefusal == nil)
    }

    @Test("a SUCCESSFUL grow reports the length and says nothing to the user")
    func successIsSilentToo() throws {
        let (store, _, clip) = try midiClip()
        let added = MIDINote(pitch: 62, startBeat: 5, lengthBeats: 1)
        let out = try store.setClipNotes(clipID: clip.id,
                                         notes: (clip.notes ?? []) + [added],
                                         extendToCover: [added.id])
        #expect(out.lengthBeats == 8)
        #expect(store.lastAutoExtendOutcome == .grew(8))
        #expect(store.lastAutoExtendRefusal == nil)
    }

    @Test("the GROWTH CAP refusal reaches the channel, and names the cap")
    func capRefusalReported() throws {
        let (store, _, clip) = try midiClip()
        // 100 beats out with nothing else on the track — the ONLY obstacle is
        // the cap. (Anti-vacuity: no neighbour exists in this fixture.)
        let far = MIDINote(pitch: 62, startBeat: 100, lengthBeats: 1)
        let out = try store.setClipNotes(clipID: clip.id,
                                         notes: (clip.notes ?? []) + [far],
                                         extendToCover: [far.id])
        #expect(out.lengthBeats == 4)                     // refused, not partial
        #expect(store.lastAutoExtendOutcome == .refusedByGrowthCap)
        #expect(store.lastAutoExtendRefusal?.contains("\(ClipAutoExtend.maxGrowthBars) bars") == true)
    }

    @Test("the NEIGHBOUR refusal reaches the channel, and names the neighbour")
    func neighbourRefusalReported() throws {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let first = try store.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: 4,
                                          notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)])
        // Flush against the first clip: zero headroom, so no growth is possible.
        let neighbour = try store.addMIDIClip(toTrack: track.id, atBeat: 4, lengthBeats: 4)
        let added = MIDINote(pitch: 62, startBeat: 5, lengthBeats: 1)

        let out = try store.setClipNotes(clipID: first.id,
                                         notes: (first.notes ?? []) + [added],
                                         extendToCover: [added.id])
        #expect(out.lengthBeats == 4)
        #expect(store.lastAutoExtendOutcome == .refusedByNeighbour)
        #expect(store.lastAutoExtendRefusal?.contains("Move the next clip") == true)
        // The neighbour is untouched — the refusal is what protects it.
        #expect(store.tracks.flatMap(\.clips).first { $0.id == neighbour.id } == neighbour)

        // ⭐ ANTI-VACUITY CONTROL, ONE INPUT FLIPPED: the same note on a track
        // with NO neighbour grows instead. Without this the assertion above
        // could be passing on the note's position rather than on the neighbour.
        let (lone, _, loneClip) = try midiClip()
        let same = MIDINote(pitch: 62, startBeat: 5, lengthBeats: 1)
        let grown = try lone.setClipNotes(clipID: loneClip.id,
                                          notes: (loneClip.notes ?? []) + [same],
                                          extendToCover: [same.id])
        #expect(grown.lengthBeats == 8)
        #expect(lone.lastAutoExtendOutcome == .grew(8))
        #expect(lone.lastAutoExtendRefusal == nil)
    }

    /// A throw must not leave the PREVIOUS call's refusal standing — the channel
    /// is cleared before the guards, so a caller reading it after a `try?` that
    /// threw is handed nothing rather than a stale sentence.
    @Test("a THROWN call clears the channel rather than leaving a stale refusal")
    func aThrowClearsTheChannel() throws {
        let (store, _, clip) = try midiClip()
        let far = MIDINote(pitch: 62, startBeat: 100, lengthBeats: 1)
        _ = try store.setClipNotes(clipID: clip.id, notes: (clip.notes ?? []) + [far],
                                   extendToCover: [far.id])
        #expect(store.lastAutoExtendRefusal != nil)       // standing …

        _ = try? store.setClipNotes(clipID: UUID(), notes: [])   // … then a throw
        #expect(store.lastAutoExtendOutcome == .notNeeded)
        #expect(store.lastAutoExtendRefusal == nil)
    }

    // MARK: - pasteNotes — THE CALL SITE IT IS EASIEST TO LEAVE SILENT

    @Test("PASTE reports its refusal too, with the SAME words as the note edit")
    func pasteRefusalReported() throws {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let first = try store.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: 4,
                                          notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)])
        _ = try store.addMIDIClip(toTrack: track.id, atBeat: 4, lengthBeats: 4)
        let pasted = MIDINote(pitch: 64, startBeat: 5, lengthBeats: 1)

        let out = try store.pasteNotes(clipID: first.id,
                                       notes: (first.notes ?? []) + [pasted],
                                       extendToCover: [pasted.id])
        #expect(out.lengthBeats == 4)
        #expect(store.lastAutoExtendOutcome == .refusedByNeighbour)

        // ONE message home: paste and note-edit must produce IDENTICAL words for
        // the identical obstacle. Two vocabularies would be two homes.
        #expect(store.lastAutoExtendRefusal
                == ProjectStore.autoExtendRefusalMessage(.refusedByNeighbour))
    }

    @Test("an ordinary PASTE inside the clip reports nothing")
    func pasteInsideIsSilent() throws {
        let (store, _, clip) = try midiClip()
        let pasted = MIDINote(pitch: 64, startBeat: 2, lengthBeats: 1)
        _ = try store.pasteNotes(clipID: clip.id, notes: (clip.notes ?? []) + [pasted],
                                 extendToCover: [pasted.id])
        #expect(store.lastAutoExtendOutcome == .notNeeded)
        #expect(store.lastAutoExtendRefusal == nil)
    }

    @Test("a PASTE that grows reports the grow and stays silent")
    func pasteGrowIsSilent() throws {
        let (store, _, clip) = try midiClip()
        let pasted = MIDINote(pitch: 64, startBeat: 5, lengthBeats: 1)
        let out = try store.pasteNotes(clipID: clip.id, notes: (clip.notes ?? []) + [pasted],
                                       extendToCover: [pasted.id])
        #expect(out.lengthBeats == 8)
        #expect(store.lastAutoExtendOutcome == .grew(8))
        #expect(store.lastAutoExtendRefusal == nil)
    }
}
