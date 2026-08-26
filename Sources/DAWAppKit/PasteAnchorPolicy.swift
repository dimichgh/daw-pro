import DAWCore
import Foundation

/// WHERE A PASTE LANDS (m23-ek-3) — pure, `nonisolated`, and the ONE home for
/// every rule in the paste-anchor decision.
///
/// It takes plain values (a payload, an anchor beat, the live tracks) and
/// returns resolved landings plus skips. **It touches no `ProjectStore`, no
/// SwiftUI and no AppKit**, which is what makes the arithmetic below testable
/// headlessly instead of only reachable through a menu click.
///
/// ═══ THE SETTLED DECISIONS THIS ENCODES ═══
///
/// **PASTE AT THE PLAYHEAD, preserving relative offsets.** The EARLIEST member
/// of the copied group lands on the playhead and every other member keeps its
/// offset from that member. "Preserving relative offsets" alone is
/// underdetermined — it does not say which member is the reference — so the
/// rule is stated as the earliest one, which is the Logic/Pro Tools behaviour a
/// user coming from either will predict.
///
/// **THE ANCHOR DOES NOT ADVANCE ON A REPEATED PASTE.** Nothing here holds
/// state, which is the implementation of that decision: two pastes at one
/// playhead position resolve to identical landings and stack. That matches
/// Logic; stacking is visible and undoable, whereas a silently-advancing anchor
/// is neither.
///
/// ⚠️⚠️ **A PASTE THAT WOULD LAND BEFORE BEAT 0 CLAMPS THE GROUP, NEVER ITS
/// MEMBERS.** One `max(0, anchorBeat)` on the ANCHOR, before any offset is
/// added — so the group slides right as a rigid body and every internal gap
/// survives. Clamping each member's absolute start instead would WELD the
/// early members together at beat 0 and silently destroy the rhythm the user
/// copied. That is the m23-g2 group-drag defect exactly, one layer up, and the
/// m23-ek-2 defect it was fixed as this morning.
///
/// ⚠️ **DO NOT DELETE THE CLAMP AS UNREACHABLE.** The design doc's D11 rule 3
/// argues it is dead code for clips (`anchorBeat >= 0` and every offset `>= 0`
/// by construction) and says to write the argument instead. That reasoning is
/// correct about the CLIP path and wrong about the rule, for two reasons.
/// (1) `PasteAnchorPolicy` is a pure public function whose behaviour at a
/// negative anchor is a defined, tested property, not an accident of its
/// callers. (2) On the NOTE path there is a live per-member welder sitting
/// directly downstream: `MIDINote.init` does `startBeat = max(0, startBeat)`
/// (`Model.swift:164`) and `ProjectStore.setClipNotes` reconstructs EVERY note
/// through it precisely so out-of-range fields cannot slip past. So a payload
/// reaching the store with negative starts does not error — it welds, quietly.
/// The group clamp here is what keeps it from getting there.
public enum PasteAnchorPolicy {

    // MARK: - Clips

    /// One clip's resolved landing: which source clip, which track, which beat.
    ///
    /// Carries the SOURCE clip rather than a rebuilt one because the id has to
    /// be re-minted at paste time and `ProjectStore.reidentified` is the ONE
    /// home for that rebuild (it re-mints, copies controller lanes verbatim and
    /// clears `takeGroupID` — exactly a paste's semantics). A policy that
    /// rebuilt the clip here would be a second home for it.
    public struct ResolvedClipLanding: Equatable, Sendable {
        /// The clip as copied. Its `id` is the SOURCE's — the store re-mints.
        public var clip: Clip
        /// The track this landing goes on.
        public var targetTrackID: UUID
        /// The project beat its start moves to.
        public var startBeat: Double

        public init(clip: Clip, targetTrackID: UUID, startBeat: Double) {
            self.clip = clip
            self.targetTrackID = targetTrackID
            self.startBeat = startBeat
        }
    }

    /// Why one member of a payload did not land. SKIP-AND-REPORT, never abort:
    /// the `importAudioBatch` precedent (validate outside the edit body, report
    /// the bad item, never let it take the good ones down with it).
    public enum ClipPasteSkipReason: String, Sendable, CaseIterable, Equatable {
        /// The target track cannot hold this clip's content — a MIDI clip onto
        /// an audio track, an audio clip onto an instrument track, either onto a
        /// bus. Decided by `Track.canHold(_:)`, never a local `kind ==` test
        /// (the m23-v / m23-aj one-home rule).
        case trackKindMismatch = "track-kind-mismatch"
        /// This landing would have overlapped ANOTHER MEMBER of the same paste
        /// on the same track. Only reachable under a relocated paste, where the
        /// mandatory index clamp can fold two source tracks onto one target —
        /// see `resolveClipPaste`.
        ///
        /// ⚠️ **m25-l-3 MADE THIS REACHABLE WITH NO DELETED TRACK AT ALL, and
        /// therefore reachable by an ordinary user for the first time.** Before
        /// that ruling, a copy whose source tracks were all still live was
        /// always `.inPlace`, and the in-place branch cannot fold (each clip
        /// goes to its own live source track, which are distinct by
        /// construction). Now an explicitly chosen destination relocates a
        /// live-source copy too — so copying a two-track group and pasting it
        /// onto the LAST track clamps both members onto that track and skips the
        /// second with this reason. That is the honest outcome the clamp's cost
        /// was always documented to have; it just used to be unreachable
        /// without deleting a track first.
        ///
        /// Skipped rather than placed, because two
        /// pasted clips silently stacking is the +6 dB defect m11-d/m13-b exist
        /// to prevent, and `resolvingOverlaps` will not save us here: every
        /// pasted clip is a CLAIMANT of the window, and claimants are exempt
        /// from trimming by construction.
        case overlapsPastedSibling = "overlaps-pasted-sibling"
    }

    /// A reported skip — WHICH clip and WHY, so the app can name it in the amber
    /// refusal bubble and a gate can assert on the reason rather than on a count.
    public struct ClipPasteSkip: Equatable, Sendable {
        public var sourceClipID: UUID
        public var clipName: String
        public var reason: ClipPasteSkipReason

        public init(sourceClipID: UUID, clipName: String, reason: ClipPasteSkipReason) {
            self.sourceClipID = sourceClipID
            self.clipName = clipName
            self.reason = reason
        }
    }

    /// WHICH track rule the paste resolved under.
    ///
    /// ALL-OR-NOTHING, DELIBERATELY, rather than per-clip. A paste that landed
    /// two clips at home and one relocated is unexplainable to a user; this
    /// switch states in one sentence — *"you didn't point anywhere and your
    /// tracks are still there, so it pastes in place; otherwise it places
    /// relative to where you are."*
    ///
    /// ⚠️⚠️ **THE SENTENCE ABOVE CHANGED AT m25-l-3, BY USER RULING (2026-08-13).**
    /// It used to read *"your tracks are still there, so it pastes in place"*
    /// full stop, and an explicitly chosen track could not override it. The user
    /// tested the gesture and called that wrong: *"when I copy clip and then
    /// select track using header and try to paste using keyboard shortcut, it
    /// does not copy on selected track, it still copies to the source track."*
    /// A deliberately chosen destination now beats the in-place rule. **An
    /// INFERRED destination still does not** — see `resolveClipPaste`.
    ///
    /// ⚠️ **THESE ARE RULES, NOT TRIGGERS, and that is why there are still only
    /// two.** `.relocated` is now reachable two ways — a dead source track, or
    /// an explicit destination — and the two can co-occur. A third case would
    /// need a precedence rule between them, and there is no principled one; the
    /// enum answers *which arithmetic ran*, which is unambiguous. WHY it ran is
    /// carried by the caller's own `ArrangeActiveTrack.Resolution.origin`.
    public enum ClipPasteTrackMode: String, Sendable, CaseIterable, Equatable {
        /// P1 — every `sourceTrackID` still exists AND no track was explicitly
        /// chosen, so each clip goes home.
        case inPlace = "in-place"
        /// P2 — a source track is gone, or the user pointed at a track. Either
        /// way the whole group places relative to a base track, keeping its
        /// vertical geometry.
        case relocated = "relocated"
    }

    /// Why a paste placed NOTHING AT ALL. Distinct from a payload every member
    /// of which was skipped: a refusal means the plan never got as far as
    /// resolving landings. Carried rather than collapsed to an empty result for
    /// `DeleteMenuRefusal`'s reason — a bare "nothing happened" cannot tell a
    /// test that meant to prove the no-tracks branch from one whose payload had
    /// quietly emptied.
    public enum ClipPasteRefusal: String, Sendable, CaseIterable, Equatable {
        case emptyPayload = "empty-payload"
        case noTracks = "no-tracks"
        case noCompatibleTrack = "no-compatible-track"
    }

    /// The resolved plan for a clip paste.
    public struct ClipPastePlan: Equatable, Sendable {
        /// Landings in a deterministic order — source track index, then start
        /// beat, then id. Order matters: it is what makes the sibling-overlap
        /// skip below reproducible instead of `Set`-order roulette.
        public var landings: [ResolvedClipLanding]
        public var skipped: [ClipPasteSkip]
        /// Which track rule applied; nil when the plan refused.
        public var mode: ClipPasteTrackMode?
        /// Which guard refused; nil when a plan was produced (even one whose
        /// every member was then skipped).
        public var refusedBy: ClipPasteRefusal?
        /// The anchor actually used — i.e. `max(0, requestedAnchor)`. Echoed so
        /// a gate can assert the GROUP clamp fired without inferring it from
        /// the landings.
        public var anchorBeat: Double

        public init(landings: [ResolvedClipLanding] = [],
                    skipped: [ClipPasteSkip] = [],
                    mode: ClipPasteTrackMode? = nil,
                    refusedBy: ClipPasteRefusal? = nil,
                    anchorBeat: Double = 0) {
            self.landings = landings
            self.skipped = skipped
            self.mode = mode
            self.refusedBy = refusedBy
            self.anchorBeat = anchorBeat
        }

        /// True when the store should not be touched at all — so no `performEdit`
        /// is entered and no stray undo entry is left behind by a paste that
        /// placed nothing.
        public var isEmpty: Bool { landings.isEmpty }
    }

    /// Resolves a clip paste: where every member lands, what got skipped, and
    /// under which track rule.
    ///
    /// - Parameters:
    ///   - payload: the copied clips, in any order.
    ///   - anchorBeat: the transport playhead in PROJECT beats. Clamped to `>= 0`
    ///     once, as the GROUP anchor (see the type's banner).
    ///   - tracks: the project's live tracks in store order. Only `id` and
    ///     `canHold(_:)` are read — the clips inside them are deliberately not
    ///     consulted, because overlap against RESIDENTS is the store's job
    ///     (`resolvingOverlaps`, the ONE no-silent-overlap choke point) and
    ///     re-deciding it here would be a second home for it.
    ///   - activeTrack: **"where you are", AND HOW WE KNOW** — the base track for
    ///     a RELOCATED paste, and (since m25-l-3) the input that can force one.
    ///     Resolved by `ArrangeActiveTrack.resolve` (m25-l-1): the explicitly
    ///     clicked track header if there is one, else the track owning
    ///     `arrangeSelection.focusID`, else nil.
    ///
    ///     ⚠️ **RENAMED FROM `focusTrackID` at m25-l-1, and again from
    ///     `activeTrackID` at m25-l-3.** The first rename fixed a name that
    ///     described the only INPUT that existed (the focused clip's owner) even
    ///     though a header click adopts no focus. The second changed the TYPE,
    ///     because an id alone cannot answer the question this function now has
    ///     to ask.
    ///
    ///     ⭐⭐ **THE QUESTION IS NOT "IS THERE AN ACTIVE TRACK", IT IS "DID THE
    ///     USER DELIBERATELY CHOOSE ONE".** Those look interchangeable and are
    ///     not: `ArrangeActiveTrack.resolve` answers non-nil for a merely
    ///     FOCUSED clip too, which is nearly always — so flipping the mode on a
    ///     non-nil test would relocate every ordinary paste and collapse
    ///     multi-track copies onto one track through the index clamp. That is a
    ///     worse bug than the one m25-l-3 fixes. `Resolution.origin` is what
    ///     keeps the two apart.
    ///
    ///     ⚠️ **`.inferred` IS IGNORED BY AN IN-PLACE PASTE, exactly as before.**
    ///     `.inPlace` still targets each clip's own source track, so an ordinary
    ///     copy → click a clip → paste lands home. Only `.explicit` overrides.
    public static func resolveClipPaste(
        payload: [ClipboardClip],
        anchorBeat: Double,
        tracks: [Track],
        activeTrack: ArrangeActiveTrack.Resolution?
    ) -> ClipPastePlan {
        // ⚠️ THE GROUP CLAMP. One `max` on the ANCHOR, before any offset is
        // added, so the group translates rigidly. Never per member.
        let anchor = max(0, anchorBeat)

        guard !payload.isEmpty else {
            return ClipPastePlan(refusedBy: .emptyPayload, anchorBeat: anchor)
        }
        guard !tracks.isEmpty else {
            return ClipPastePlan(refusedBy: .noTracks, anchorBeat: anchor)
        }

        // Deterministic order: source track, then start, then id. `id` last so
        // two clips at the same beat on the same track (impossible today under
        // the no-overlap invariant, but not the policy's business to assume)
        // still order reproducibly rather than by hash.
        let ordered = payload.sorted {
            if $0.sourceTrackIndex != $1.sourceTrackIndex {
                return $0.sourceTrackIndex < $1.sourceTrackIndex
            }
            if $0.clip.startBeat != $1.clip.startBeat {
                return $0.clip.startBeat < $1.clip.startBeat
            }
            return $0.clip.id.uuidString < $1.clip.id.uuidString
        }

        // The reference member: the group's EARLIEST start lands on the anchor.
        // `ordered` is sorted by TRACK first, so this is a fresh min over starts
        // and not `ordered.first` — a two-track copy whose upper clip starts
        // later would otherwise anchor on the wrong member and shift the whole
        // group left.
        let minStart = ordered.map(\.clip.startBeat).min() ?? 0

        let liveTrackIDs = Set(tracks.map(\.id))

        // ⭐ m25-l-3 — A DELIBERATELY CHOSEN DESTINATION OVERRIDES THE IN-PLACE
        // RULE. `.explicit` only: an `.inferred` destination is merely where the
        // focused clip happens to live and must leave every existing paste
        // alone (see the parameter's doc for why that distinction is the whole
        // change).
        //
        // ⚠️ **LIVENESS IS RE-CHECKED HERE, and that is the file's staleness
        // discipline rather than belt-and-braces.** `ArrangeActiveTrack`'s rule
        // is *"resolution, never invalidation"* — a stale id stops resolving
        // instead of being cleaned up — but `tracks` reaches this function as a
        // SEPARATE argument, so a `Resolution` built against a different track
        // list is representable. A dead explicit destination must therefore
        // degrade to the in-place rule (the pre-m25-l-3 answer), NOT relocate
        // the paste to whatever the fallback finds first.
        //
        // A `Bool` rather than the id: the `.relocated` branch below bases on
        // `activeTrack?.id` for BOTH origins (an inferred destination has always
        // based a relocation), so an id carried down from here would be a second
        // spelling of the same track that a later edit could let drift.
        let hasExplicitDestination = activeTrack.map {
            $0.origin == .explicit && liveTrackIDs.contains($0.id)
        } ?? false

        let sourcesAllLive = ordered.allSatisfy { liveTrackIDs.contains($0.sourceTrackID) }
        let mode: ClipPasteTrackMode =
            (sourcesAllLive && !hasExplicitDestination) ? .inPlace : .relocated

        // Resolve each member's TARGET TRACK INDEX under the chosen rule.
        var targetIndexFor: [UUID: Int] = [:]
        switch mode {
        case .inPlace:
            for entry in ordered {
                // Non-nil by the `allSatisfy` above; resolved rather than
                // force-unwrapped so a future change to that test degrades to a
                // skip instead of a crash.
                guard let index = tracks.firstIndex(where: { $0.id == entry.sourceTrackID })
                else { continue }
                targetIndexFor[entry.clip.id] = index
            }
        case .relocated:
            // ONE relocation path, whichever trigger got us here (m25-l-3). The
            // base is the active track REGARDLESS of provenance: an `.inferred`
            // destination has always based a relocated paste and still does, and
            // an `.explicit` one is the same arithmetic with a stronger reason.
            // Writing a second, override-only relocation would be two homes for
            // the offset/clamp rules below.
            let baseIndex: Int
            if let activeTrackID = activeTrack?.id,
               let index = tracks.firstIndex(where: { $0.id == activeTrackID }) {
                baseIndex = index
            } else if let index = tracks.firstIndex(where: { $0.canHold(ordered[0].clip) }) {
                // "The first track in store order that can hold the payload's
                // TOPMOST clip" — topmost meaning lowest source track index,
                // which `ordered[0]` is by construction.
                baseIndex = index
            } else {
                return ClipPastePlan(mode: mode, refusedBy: .noCompatibleTrack, anchorBeat: anchor)
            }
            let minSourceIndex = ordered.map(\.sourceTrackIndex).min() ?? 0
            for entry in ordered {
                // ⚠️ THE CLAMP IS MANDATORY. Without it a 3-track copy pasted
                // onto the last track indexes past the end — a crash, or (worse)
                // a silent drop if the caller filters instead. Its accepted cost
                // is that two source tracks can FOLD ONTO ONE, which is what the
                // sibling-overlap skip below then catches honestly.
                let offset = entry.sourceTrackIndex - minSourceIndex
                targetIndexFor[entry.clip.id] = min(max(0, baseIndex + offset), tracks.count - 1)
            }
        }

        var landings: [ResolvedClipLanding] = []
        var skipped: [ClipPasteSkip] = []
        // Windows already claimed by an ACCEPTED landing, per target track.
        var claimed: [UUID: [(start: Double, end: Double)]] = [:]

        for entry in ordered {
            guard let index = targetIndexFor[entry.clip.id] else { continue }
            let track = tracks[index]
            guard track.canHold(entry.clip) else {
                skipped.append(ClipPasteSkip(sourceClipID: entry.clip.id,
                                             clipName: entry.clip.name,
                                             reason: .trackKindMismatch))
                continue
            }
            let start = anchor + (entry.clip.startBeat - minStart)
            let end = start + entry.clip.lengthBeats
            // Half-open windows: a landing that STARTS exactly where another
            // ENDS is flush, not overlapping — the same `start < end && x < y`
            // form `resolvingOverlaps` uses, so the two agree at the boundary.
            let collides = claimed[track.id, default: []].contains { $0.start < end && start < $0.end }
            guard !collides else {
                skipped.append(ClipPasteSkip(sourceClipID: entry.clip.id,
                                             clipName: entry.clip.name,
                                             reason: .overlapsPastedSibling))
                continue
            }
            claimed[track.id, default: []].append((start, end))
            landings.append(ResolvedClipLanding(clip: entry.clip,
                                                targetTrackID: track.id,
                                                startBeat: start))
        }

        return ClipPastePlan(landings: landings, skipped: skipped,
                             mode: mode, anchorBeat: anchor)
    }

    // MARK: - Notes

    /// The CLIP-LOCAL beat a note paste anchors on, or **nil when there is no
    /// insertion point in this clip at all** (the transport sits outside it).
    ///
    /// ⚠️⚠️ **THIS RETURNED `0` INSTEAD OF nil UNTIL m25-f-2, AND THE OLD
    /// RATIONALE IS KEPT HERE ON PURPOSE — do not "restore" the 0.** It read:
    /// *outside → 0, and that is not an invention; it is the roll's own shipped
    /// rule for playhead-relative operations —`PianoRollBarOps.targetBarStartBeat`
    /// is documented as "the bar under the playhead, ELSE BAR 0" and drives the
    /// whole bar-ops cluster.* That argument is still SOUND, and bar ops still
    /// keep the rule. It was replaced here for a reason specific to PASTE: a bar
    /// op with no playhead has no other sensible referent, whereas a paste has
    /// two much better ones — the notes it was copied from, and the region the
    /// user is actually looking at. Falling back to bar 0 sent a paste to a
    /// place the user very often could not even see, which is precisely what
    /// m25-f-2 was filed to fix. `resolveNotePaste` now owns that decision;
    /// this function's ONLY job is the inside/outside question, and nil is how
    /// it declines to answer a question it has no business answering.
    ///
    /// ⚠️ THE INSIDE/OUTSIDE TEST IS `PianoRollPlayhead.isVisible`, CONSUMED not
    /// re-derived. That predicate is documented as the ONE home for "is the
    /// transport within this clip" — the playhead line draws iff it is true and
    /// the off-clip cue shows iff it is false, complementary by construction.
    /// A second spelling here could disagree with the line the user is looking
    /// at, which is the whole class of bug that comment exists to prevent.
    /// Parking at the nearer clip edge is likewise still refused by m23-c1: this
    /// roll never parks the playhead at an edge, it draws `OffClipEdgeCue`.
    public static func noteInsertionPoint(playheadProjectBeat: Double,
                                          clipStartBeat: Double,
                                          clipLengthBeats: Double) -> Double? {
        guard PianoRollPlayhead.isVisible(position: playheadProjectBeat,
                                          clipStartBeat: clipStartBeat,
                                          lengthBeats: clipLengthBeats) else { return nil }
        return PianoRollPlayhead.localBeat(position: playheadProjectBeat,
                                           clipStartBeat: clipStartBeat)
    }

    /// WHICH RULE a note paste landed under (m25-f-2). Carried out of
    /// `resolveNotePaste` so a test can assert the BRANCH rather than infer it
    /// from coordinates that two different branches could coincidentally agree
    /// on — the `ClipPasteTrackMode` precedent, one surface over.
    public enum NotePasteMode: String, Sendable, CaseIterable, Equatable {
        /// P1 — the transport is inside the edited clip, so it IS an insertion
        /// point and the group lands on it. The shipped m23-ek-3 behaviour,
        /// unchanged by m25-f-2.
        case playhead = "playhead"
        /// P2 — no insertion point, and the copied notes are STILL IN THIS CLIP.
        /// The group lands at the same TIME, nudged up in PITCH so it sits above
        /// the notes it came from, selected and ready to drag.
        case aboveSource = "above-source"
        /// P3 — no insertion point and nothing to sit above: the payload came
        /// from a different clip, or its sources were CUT out of this one. The
        /// group lands at the start of what the user can currently see.
        case visibleStart = "visible-start"
    }

    /// A resolved note-paste landing: where in time, how far in pitch, under
    /// which rule, and whether the caller must snap.
    public struct NotePasteLanding: Equatable, Sendable {
        /// The clip-local beat the group's EARLIEST note moves to.
        public var localBeat: Double
        /// Semitones to shift the WHOLE group by. Positive is up (visually
        /// above). `translatedNotes` applies it as a group clamp.
        public var pitchOffset: Int
        public var mode: NotePasteMode
        /// HOW the caller must snap `localBeat` before translating.
        public var snap: NotePasteSnap

        public init(localBeat: Double, pitchOffset: Int,
                    mode: NotePasteMode, snap: NotePasteSnap) {
            self.localBeat = localBeat
            self.pitchOffset = pitchOffset
            self.mode = mode
            self.snap = snap
        }
    }

    /// WHICH WAY a resolved note-paste anchor snaps. Three branches, three
    /// different right answers — a single `Bool` cannot express it, and the one
    /// this replaced shipped a real defect for a day (see `.upward`).
    public enum NotePasteSnap: String, Sendable, CaseIterable, Equatable {
        /// NEAREST grid line — `PianoRollModel.snap`. For an anchor that means
        /// "the closest grid line to where the user pointed", which is what a
        /// playhead paste is.
        case nearest = "nearest"
        /// NO SNAP AT ALL.
        ///
        /// ⚠️⚠️ **THE `.aboveSource` ANSWER, AND IT IS LOAD-BEARING.** That
        /// branch moves the group in PITCH ONLY and re-uses the payload's own
        /// start as the anchor, so snapping would drag a swung or triplet figure
        /// onto the grid — the m23-g2 weld applied to the group instead of its
        /// members, and just as silent. A copy that arrives a 32nd away from the
        /// notes it copied is not a copy.
        case none = "none"
        /// UP to the next grid line at or after the anchor —
        /// `PianoRollModel.snapUp`.
        ///
        /// ⚠️⚠️ **THIS CASE EXISTS BECAUSE `.nearest` SHIPPED A DEFECT HERE.**
        /// The `.visibleStart` anchor is the viewport's LEADING EDGE, and
        /// `snap` rounds to nearest — so at `.bar` in 4/4 it rounds BACKWARD by
        /// up to 2 beats, putting the group partly or wholly OFF THE LEFT EDGE
        /// of the screen. That is the one branch whose entire purpose is that
        /// the user can see and grab the group, so rounding backward defeats it
        /// completely. "At or after the visible edge" is the actual requirement,
        /// and `snapUp` is the verb for it.
        case upward = "upward"
    }

    /// The furthest a paste will nudge a group in pitch, in semitones.
    ///
    /// ONE OCTAVE, and the bound is the argument. The user asked for a
    /// *"slightly repositioned"* group; an octave is the largest displacement
    /// that still reads as the same material moved rather than different
    /// material, it is the interval this editor already thinks in, and it keeps
    /// the nudge inside a single screen of pitch at every row height the roll
    /// offers. The search below stops there and takes the best candidate it
    /// found rather than continuing — a copy 20 semitones up would satisfy
    /// "doesn't overlap" while failing "slightly repositioned" and, worse,
    /// "immediately capturable".
    public static let maxNudgeSemitones: Int = 12

    /// WHERE A NOTE PASTE LANDS (m25-f-2) — the ONE home for the whole decision.
    ///
    /// ═══ THE RULE ═══
    ///
    ///  1. **Playhead inside the target clip → paste on it.** Unchanged; this is
    ///     the m23-ek-3 behaviour and the case the shipped gate pins.
    ///  2. **Otherwise, if the copied notes are still in this clip → sit ABOVE
    ///     them**, at the same time, nudged up in pitch. This is the user's
    ///     case verbatim: *"when there is no playhead positioned, it should
    ///     create a slightly repositioned selected group of notes above the
    ///     source ones so that user can immediately capture them with mouse and
    ///     drag where he wants them to go."*
    ///  3. **Otherwise → the start of the visible area.** Their cross-clip
    ///     sentence: *"paste it to the other at playhead when positioned or in
    ///     visible area in selected state ready to be dragged."*
    ///
    /// ⭐ **THE ONE GOAL THAT ORDERS THE OTHERS IS VISIBILITY.** The user's
    /// stated purpose is that they can *immediately capture the group with the
    /// mouse*, and a group they cannot see cannot be captured at all — so every
    /// no-insertion-point branch lands somewhere on screen, and the pitch nudge
    /// is bounded by the visible pitch window rather than by musical taste.
    /// Where the three goals conflict — visible, non-overlapping, slight — this
    /// sacrifices NON-OVERLAPPING first (the failure is a merely ambiguous
    /// click) and SLIGHTNESS second; visibility is never traded.
    ///
    /// ⚠️⚠️ **THE DISCRIMINATOR FOR RULE 2 IS ID PRESENCE, NOT
    /// `ClipboardNotes.sourceClipID`, AND THAT IS A CORRECTNESS CHOICE.**
    /// `sourceClipID` is recorded and would look like the natural test, but it
    /// cannot tell a COPY from a CUT — after a cut it still names this clip
    /// while the notes it names are gone, and "sit above the source ones" is
    /// meaningless with no source ones. Id presence answers the question that is
    /// actually being asked — *are the notes I would sit above still here?* — so
    /// a cut-then-paste falls to rule 3 and lands where the user is looking,
    /// which is where they were about to drag it anyway.
    ///
    /// ⚠️ **ONE HONEST LIMIT, MEASURED RATHER THAN ASSUMED.** An earlier draft
    /// of this comment claimed a payload's ids "can never be found in a clip
    /// other than the one it was copied from", on the grounds that every paste
    /// mints fresh ids. **That is FALSE and I checked:
    /// `ProjectStore.reidentified` re-mints the CLIP's id and copies
    /// `notes: clip.notes` verbatim** — so a duplicated CLIP carries identical
    /// note ids, and a note copied from the original will find its ids in the
    /// duplicate. The BEHAVIOUR is still right there (the duplicate holds
    /// visually identical notes at identical positions, so sitting above them is
    /// exactly what rule 2 should do); it is the soundness ARGUMENT that was
    /// wrong, and a claim this file cannot back is worse than a narrower one.
    ///
    /// ⚠️ **A REPEATED ⌘V STACKS, and that is the file's existing rule rather
    /// than a defect.** The payload never changes, so rule 2 re-resolves to the
    /// same offset and the second paste lands on the first. The banner's
    /// "THE ANCHOR DOES NOT ADVANCE ON A REPEATED PASTE" decision covers this
    /// exactly: stacking is visible and undoable, a silently-advancing anchor is
    /// neither.
    ///
    /// - Parameters:
    ///   - payload: the copied group, carrying CLIP-LOCAL starts and their
    ///     ORIGINAL ids (the copy is taken straight off the roll's draft).
    ///   - existingNotes: the target clip's notes as the roll currently holds
    ///     them — the draft, not the store's copy, so an unsaved edit counts.
    ///   - visibleStartLocalBeat: the clip-local beat at the viewport's leading
    ///     edge. Clamped to `>= 0` here.
    ///   - visiblePitches: the pitch rows currently on screen, or nil when the
    ///     view cannot say yet (before first layout). nil means only the
    ///     0...127 wall bounds the nudge.
    public static func resolveNotePaste(
        payload: [MIDINote],
        playheadProjectBeat: Double,
        clipStartBeat: Double,
        clipLengthBeats: Double,
        existingNotes: [MIDINote],
        visibleStartLocalBeat: Double,
        visiblePitches: ClosedRange<Int>?
    ) -> NotePasteLanding {
        if let insertion = noteInsertionPoint(playheadProjectBeat: playheadProjectBeat,
                                              clipStartBeat: clipStartBeat,
                                              clipLengthBeats: clipLengthBeats) {
            return NotePasteLanding(localBeat: insertion, pitchOffset: 0,
                                    mode: .playhead, snap: .nearest)
        }
        let payloadIDs = Set(payload.map(\.id))
        let sourcesPresent = existingNotes.contains { payloadIDs.contains($0.id) }
        guard sourcesPresent, let minStart = payload.map(\.startBeat).min() else {
            return NotePasteLanding(localBeat: max(0, visibleStartLocalBeat), pitchOffset: 0,
                                    mode: .visibleStart, snap: .upward)
        }
        return NotePasteLanding(
            localBeat: minStart,
            pitchOffset: nudgePitchOffset(payload: payload, existing: existingNotes,
                                          visiblePitches: visiblePitches),
            mode: .aboveSource,
            snap: .none)
    }

    /// How far to nudge a pasted group in pitch so it sits clear of what it was
    /// copied from — **the SMALLEST offset that does**, searched upward first.
    ///
    /// Smallest-that-works, rather than a fixed interval, is what makes this
    /// both *"slight"* and unambiguous at the same time. A single note needs one
    /// semitone; a four-note chord with gaps in it often needs one too; only a
    /// dense chromatic cluster needs many. A fixed +12 would throw every paste
    /// an octave for a problem most pastes do not have.
    ///
    /// ⚠️ **"CLEAR" MEANS NO SHARED (ROW, TIME WINDOW), which is the honest
    /// definition of what makes a click ambiguous.** Two notes at different
    /// pitches never overlap on screen at all — the roll's rows are disjoint by
    /// construction — so only a pasted note landing on an EXISTING note's row
    /// with an overlapping time window can steal its click. Half-open windows
    /// (`a.start < b.end && b.start < a.end`), the same form `resolvingOverlaps`
    /// and `resolveClipPaste` use, so a copy that abuts its source exactly is
    /// flush rather than colliding.
    ///
    /// ⚠️ **ROOM IS COMPUTED OVER THE GROUP, NEVER PER NOTE** — the same rule
    /// `PianoRollModel.moveSelection` states as *"per-note pitch clamp: drag a
    /// chord up into 127 and the top note stops while the rest keep rising —
    /// INTERVALS COLLAPSE, a chord becomes a cluster"*. Here that would be
    /// worse, because the user did not even ask for the move.
    ///
    /// ⚠️ **THE PRIORITY ORDER, EXACTLY — and it was corrected by its own test.**
    /// Candidates are tried up 1…N first, then down 1…N, and the FIRST that
    /// clears wins. So a non-colliding nudge DOWNWARD beats a colliding one
    /// upward: "above" is the user's word and the preferred direction, but their
    /// stated *purpose* is that the copy can be grabbed, and a copy sharing rows
    /// with its source is ambiguous to click whichever side of it you put it on.
    /// Direction is a preference; capturability is the goal. (I first wrote a
    /// test asserting the opposite — that the upward candidate wins even when it
    /// collides — and the implementation was right and the expectation wrong.)
    ///
    /// Only when NOTHING clears in either direction does the first candidate win
    /// by default, which puts the copy one row above its source.
    ///
    /// Returns 0 — a pure stack — only when the group has no room in EITHER
    /// direction, i.e. it already spans the whole visible pitch window. The
    /// paste still happens (fresh ids, selected, drag-ready); it just lands on
    /// its source, which is the same outcome a repeated ⌘V already produces.
    public static func nudgePitchOffset(payload: [MIDINote],
                                        existing: [MIDINote],
                                        visiblePitches: ClosedRange<Int>?) -> Int {
        guard let lowest = payload.map(\.pitch).min(),
              let highest = payload.map(\.pitch).max() else { return 0 }
        var up = MIDINote.pitchRange.upperBound - highest
        var down = lowest - MIDINote.pitchRange.lowerBound
        if let visiblePitches {
            up = Swift.min(up, visiblePitches.upperBound - highest)
            down = Swift.min(down, lowest - visiblePitches.lowerBound)
        }
        up = Swift.min(Swift.max(0, up), maxNudgeSemitones)
        down = Swift.min(Swift.max(0, down), maxNudgeSemitones)

        // Up before down, small before large: the candidate ORDER is where
        // "above" and "slightly" actually live.
        var candidates: [Int] = []
        if up >= 1 { candidates.append(contentsOf: 1...up) }
        if down >= 1 { candidates.append(contentsOf: (1...down).map { -$0 }) }

        for offset in candidates
        where !collidesWithExisting(payload: payload, offset: offset, existing: existing) {
            return offset
        }
        // Nothing clears. Take the first candidate anyway: it is visible and one
        // row off its source, which still gives the user somewhere to click that
        // the source does not occupy on most material.
        return candidates.first ?? 0
    }

    /// Whether `payload` shifted by `offset` semitones would land any note on an
    /// existing note's row with an overlapping time window.
    private static func collidesWithExisting(payload: [MIDINote], offset: Int,
                                             existing: [MIDINote]) -> Bool {
        payload.contains { note in
            let pitch = note.pitch + offset
            return existing.contains {
                $0.pitch == pitch && $0.startBeat < note.endBeat && note.startBeat < $0.endBeat
            }
        }
    }

    /// Translates a copied note group to `anchor`, RIGIDLY, under fresh ids.
    ///
    /// ⚠️⚠️ **THE ANCHOR IS SNAPPED ONCE BY THE CALLER; NOTHING HERE SNAPS.**
    /// That division is the point of this function's signature. Snapping each
    /// note's absolute start instead WELDS TOGETHER notes sitting at different
    /// sub-grid phases — a swung or triplet figure pasted onto a 1/16 grid comes
    /// out straight, silently. That is the m23-g2 defect verbatim
    /// (`ArrangeGroupDrag.swift:11-19`): snapping is a property of the GESTURE,
    /// not of each element. Taking the anchor pre-snapped means this function
    /// cannot make that mistake and a caller that forgets to snap gets a free
    /// paste rather than a deformed one.
    ///
    /// ⚠️ FRESH UUIDs FOR EVERY NOTE, always. Pasting into the SOURCE clip while
    /// reusing ids yields duplicate ids in one clip, which breaks
    /// `MIDINote.canonicallyOrdered`'s id tiebreak (used by the roll's
    /// `needsReseed`) and makes the selection ambiguous — click one, both
    /// respond.
    ///
    /// NO CLAMP AT THE CLIP END, deliberately. A note pasted past
    /// `clipLengthBeats` is legal-but-latent and the app ALREADY RENDERS IT
    /// HONESTLY — `PianoRollModel.playableEndBeat` returns nil and `drawNotes`
    /// gives it the m19-g ghost pill, with the velocity lane matching. The
    /// honest behaviour has a visual vocabulary already; inventing a clamp would
    /// destroy pasted material to avoid a state the app can draw.
    ///
    /// ⚠️⚠️ **`pitchOffset` IS CLAMPED OVER THE GROUP TOO (m25-f-2), AND THE
    /// HAZARD IS MEASURED, NOT ARGUED: `MIDINote.init` does
    /// `pitch.clamped(to: 0...127)` PER NOTE** (`Model.swift`, alongside the
    /// `startBeat` floor the banner already names). So a nudge that pushed a
    /// chord's top note past 127 would stop that note while the rest kept
    /// rising — **intervals collapse and a chord silently becomes a cluster**.
    /// `PianoRollModel.moveSelection` states this defect in exactly those words
    /// for the DRAG path and fixes it with `deltaPitch.clamped(to:
    /// (-minPitch)...(127 - maxPitch))`; this is the same clamp on the paste
    /// path, deliberately spelled the same way. It is a wall the GROUP stops
    /// against, never a per-note ceiling.
    ///
    /// - Parameters:
    ///   - notes: the copied group, carrying clip-local starts.
    ///   - anchor: the clip-local beat the group's EARLIEST note moves to,
    ///     already snapped. Clamped to `>= 0` as a group (see the banner).
    ///   - pitchOffset: semitones to shift the whole group, positive = up.
    ///     Defaults to 0, so every pre-m25-f-2 caller is byte-identical.
    /// - Returns: the translated notes in the input's order, under new ids.
    public static func translatedNotes(_ notes: [MIDINote], toAnchor anchor: Double,
                                       pitchOffset: Int = 0) -> [MIDINote] {
        guard !notes.isEmpty else { return [] }
        // ⚠️ THE GROUP CLAMP AGAIN, and on this path it is LIVE code rather than
        // a defined-behaviour formality: `MIDINote.init` clamps `startBeat` to
        // `max(0, …)` per note, so a negative anchor reaching the store would
        // weld every early note onto beat 0 and quietly flatten the rhythm.
        let landing = max(0, anchor)
        let minStart = notes.map(\.startBeat).min() ?? 0
        // The pitch wall, once, over the whole group — see the note above.
        let lowest = notes.map(\.pitch).min() ?? 0
        let highest = notes.map(\.pitch).max() ?? 0
        let lowestShift = MIDINote.pitchRange.lowerBound - lowest      // <= 0
        let highestShift = MIDINote.pitchRange.upperBound - highest    // >= 0
        let pitchDelta = pitchOffset.clamped(to: lowestShift...highestShift)
        return notes.map {
            MIDINote(id: UUID(), pitch: $0.pitch + pitchDelta, velocity: $0.velocity,
                     startBeat: landing + ($0.startBeat - minStart),
                     lengthBeats: $0.lengthBeats)
        }
    }
}

/// A paste that placed NOTHING, phrased for the amber refusal bubble.
///
/// AN `Error` RATHER THAN A STRING because that is what
/// `AppModel.presentArrangeSplitRefusal` takes — the ONE refusal-copy path in
/// the arrange (m17-c/m23-e), which every other refusal in that surface already
/// travels down. Inventing a second presentation for the clipboard would be a
/// second home for "how does the arrange say no".
///
/// THE COPY NAMES WHAT TO DO NEXT, never just what failed — the design
/// language's rule for refusals, and the reason each case reads as an
/// instruction rather than a diagnosis.
public struct ClipboardPasteRefusal: LocalizedError, Equatable, Sendable {
    public let reason: PasteAnchorPolicy.ClipPasteRefusal

    public init(_ reason: PasteAnchorPolicy.ClipPasteRefusal) { self.reason = reason }

    public var errorDescription: String? {
        switch reason {
        case .emptyPayload:
            return "Nothing to paste — copy or cut something first."
        case .noTracks:
            return "Nothing to paste onto — add a track first."
        case .noCompatibleTrack:
            return "No track can hold these clips — add an instrument or audio track first."
        }
    }
}

/// A paste that placed SOME of its clips and skipped others.
///
/// SKIPS ARE REPORTED, NEVER SWALLOWED. The `importAudioBatch` rule is that a
/// bad item never aborts the good ones — but the other half of that rule is that
/// the user is told, or a paste of three clips quietly becomes a paste of two.
public struct ClipboardPasteSkipReport: LocalizedError, Equatable, Sendable {
    public let skipped: [PasteAnchorPolicy.ClipPasteSkip]

    public init(_ skipped: [PasteAnchorPolicy.ClipPasteSkip]) { self.skipped = skipped }

    public var errorDescription: String? {
        guard let first = skipped.first else { return nil }
        let reason: String
        switch first.reason {
        case .trackKindMismatch:
            // Names the KIND rule in the user's terms, not the predicate's.
            reason = "that track can't hold it"
        case .overlapsPastedSibling:
            reason = "it would land on top of another pasted clip"
        }
        if skipped.count == 1 {
            return "Couldn't paste “\(first.clipName)” — \(reason)."
        }
        return "Couldn't paste \(skipped.count) clips — starting with “\(first.clipName)”, "
            + "\(reason)."
    }
}
