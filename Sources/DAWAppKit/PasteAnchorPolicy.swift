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
        /// see `resolveClipPaste`. Skipped rather than placed, because two
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
    /// switch states in one sentence — *"your tracks are still there, so it
    /// pastes in place; otherwise it places relative to where you are."*
    public enum ClipPasteTrackMode: String, Sendable, CaseIterable, Equatable {
        /// P1 — every `sourceTrackID` still exists, so each clip goes home.
        case inPlace = "in-place"
        /// P2 — at least one source track is gone, so the whole group places
        /// relative to a base track, keeping its vertical geometry.
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
    ///   - focusTrackID: the track owning `arrangeSelection.focusID`, if that
    ///     clip still exists. The base track for a RELOCATED paste — "where you
    ///     are". Ignored entirely by an in-place paste.
    public static func resolveClipPaste(
        payload: [ClipboardClip],
        anchorBeat: Double,
        tracks: [Track],
        focusTrackID: UUID?
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
        let mode: ClipPasteTrackMode =
            ordered.allSatisfy { liveTrackIDs.contains($0.sourceTrackID) } ? .inPlace : .relocated

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
            let baseIndex: Int
            if let focusTrackID,
               let index = tracks.firstIndex(where: { $0.id == focusTrackID }) {
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

    /// The CLIP-LOCAL beat a note paste anchors on.
    ///
    /// Inside the edited clip → the playhead's clip-local position. Outside →
    /// **0**, and that is not an invention: it is the roll's own shipped rule
    /// for playhead-relative operations. `PianoRollBarOps.targetBarStartBeat` is
    /// documented as "the bar under the playhead, ELSE BAR 0" and drives the
    /// whole bar-ops cluster. Parking at the nearer clip edge instead is refused
    /// by precedent — m23-c1 established that this roll never parks the playhead
    /// at an edge, it draws `OffClipEdgeCue` instead.
    ///
    /// ⚠️ THE INSIDE/OUTSIDE TEST IS `PianoRollPlayhead.isVisible`, CONSUMED not
    /// re-derived. That predicate is documented as the ONE home for "is the
    /// transport within this clip" — the playhead line draws iff it is true and
    /// the off-clip cue shows iff it is false, complementary by construction.
    /// A second spelling here could disagree with the line the user is looking
    /// at, which is the whole class of bug that comment exists to prevent.
    public static func noteLocalAnchor(playheadProjectBeat: Double,
                                       clipStartBeat: Double,
                                       clipLengthBeats: Double) -> Double {
        guard PianoRollPlayhead.isVisible(position: playheadProjectBeat,
                                          clipStartBeat: clipStartBeat,
                                          lengthBeats: clipLengthBeats) else { return 0 }
        return PianoRollPlayhead.localBeat(position: playheadProjectBeat,
                                           clipStartBeat: clipStartBeat)
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
    /// - Parameters:
    ///   - notes: the copied group, carrying clip-local starts.
    ///   - anchor: the clip-local beat the group's EARLIEST note moves to,
    ///     already snapped. Clamped to `>= 0` as a group (see the banner).
    /// - Returns: the translated notes in the input's order, under new ids.
    public static func translatedNotes(_ notes: [MIDINote], toAnchor anchor: Double) -> [MIDINote] {
        guard !notes.isEmpty else { return [] }
        // ⚠️ THE GROUP CLAMP AGAIN, and on this path it is LIVE code rather than
        // a defined-behaviour formality: `MIDINote.init` clamps `startBeat` to
        // `max(0, …)` per note, so a negative anchor reaching the store would
        // weld every early note onto beat 0 and quietly flatten the rhythm.
        let landing = max(0, anchor)
        let minStart = notes.map(\.startBeat).min() ?? 0
        return notes.map {
            MIDINote(id: UUID(), pitch: $0.pitch, velocity: $0.velocity,
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
