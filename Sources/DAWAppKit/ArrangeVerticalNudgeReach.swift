import Foundation
import DAWCore

// WHICH LANE A VERTICAL ARROW PRESS REACHES (m25-l-1 ④) — the KEYBOARD's half
// of the vertical resolve, and the deliberate sibling of
// `ArrangeVerticalDrag.effectiveDelta`.
//
// ═══ THE DEFECT THIS EXISTS FOR ═══
//
// Measured by the user, 2026-08-23: *"[cross-track clip drag] works when
// dragging by mouse over the audio, while if I use arrow keys, it gets stuck
// and does not jump over the audio track to the instrumental when it exists."*
//
// The valuable shape is that the SAME operation succeeded by mouse and failed
// by keyboard, so the defect was never in the move or in the legality rule —
// both routes share `ProjectStore.clampedTrackDelta` and `Track.canHold`. It
// was in WHAT THE KEYBOARD ASKED FOR. `ArrangeNudge.verticalStep` hands down a
// requested ±1; in `[instrument, AUDIO, instrument]` that ±1 lands on the audio
// row, `moveClips(ids:byTracks:)` phase 2b kind-checks it and throws
// `midiClipsRequireInstrumentTrack`. A wall. The mouse route reaches the far
// instrument lane only because the pointer resolves an ABSOLUTE row and so
// requests ±2, never asking about the row in between.
//
// ═══ ONE HOME, TWO INPUTS — WHY THIS IS NOT A SECOND COPY ═══
//
// There are exactly three questions on this axis, and each has ONE home:
//
//   • "IS THIS LANDING LEGAL?"        → `Track.canHold`, asked here, never
//                                       re-implemented.
//   • "IS THIS DELTA IN RANGE?"       → `ProjectStore.clampedTrackDelta`,
//                                       called here, never re-derived (the
//                                       m23-f finding: a second computation of
//                                       the same quantity is free to agree by
//                                       luck).
//   • "WHAT SHOULD THE INPUT ASK FOR?" → per input device, because the two
//                                       devices genuinely mean different
//                                       things.
//
// This file answers only the third, for the keyboard. `ArrangeVerticalDrag`
// answers it for the pointer, and the two answers are OPPOSITE ON PURPOSE:
//
//   • A DRAG LANDS WHERE YOU POINT. Blocked at the requested row it BACKS OFF
//     TO ZERO and never searches — a pointer-drag that quietly slid past the
//     lane under the cursor would be a new and worse bug than the one being
//     fixed here, and `ArrangeVerticalDrag.effectiveDelta`'s "IT NEVER SEARCHES"
//     paragraph is unchanged and stays true.
//   • AN ARROW PRESS MEANS "THE NEXT LANE I CAN USE". It carries no absolute
//     row — only a direction — so "the next one" is the whole of its meaning,
//     and a lane it can never land on is not a destination, it is scenery.
//
// ⚠️ THE INELIGIBLE ROW IS PASSED OVER, NEVER INTO. This never makes an audio
// track a legal home for a MIDI clip; it changes only which delta is REQUESTED.
// Legality is still decided, and still refused, by the store.
//
// ═══ WHAT IT DOES NOT DO ═══
//
// It NEVER widens what the store accepts and it NEVER silences a refusal. When
// no delta in the pressed direction works, it hands back the RAW ±1 the step
// asked for, so the user gets today's behaviour byte-for-byte: a clamp to a
// no-op at the ends of the track list, and the same thrown
// `midiClipsRequireInstrumentTrack` (with its amber bubble) against a wall.
// Returning 0 instead was rejected for the reason the store already states — a
// dead key is indistinguishable from a broken one, and a refusal that says why
// is strictly more informative.
//
// Headless (no SwiftUI, no AppKit) in the `ArrangeNudge` / `ArrangeVerticalDrag`
// tradition, because `DAWApp` has no test target and a rule decided inside a
// SwiftUI `body` is invisible to `Tests/`.
public enum ArrangeVerticalNudgeReach {

    /// The delta one vertical arrow press should hand
    /// `ProjectStore.moveClips(ids:byTracks:)`.
    ///
    /// ═══ THE RULE, AND WHY IT IS GROUP-WIDE ═══
    ///
    /// **The smallest |delta| ≥ 1 in the pressed direction such that EVERY
    /// mover lands on a track that can hold it** — or the raw ±1 when no such
    /// delta exists before the group runs off the end of the track list.
    ///
    /// ONE delta for the whole selection, never one per clip. `byTracks` is
    /// RIGID by design (`ClipTrackLanding`, `Model.swift`): a keyboard press
    /// that collapsed a multi-track selection while a drag preserved its shape
    /// would give one surface two vertical semantics. So with a selection
    /// spanning several lanes, "the next eligible track" is not well defined per
    /// clip and is not attempted; the group moves as a rigid block or not at
    /// all. In `[instrument, audio, instrument, audio]` a MIDI clip on row 0
    /// selected together with an audio clip on row 1 reaches +2 — where BOTH
    /// land legally — and skips +1, where neither does.
    ///
    /// ═══ PHASE ORDER, MIRRORING BOTH SIBLINGS ═══
    ///
    /// Per candidate: **CLAMP FIRST** (`ProjectStore.clampedTrackDelta`, its one
    /// home), **KIND-CHECK THE CLAMPED LANDING SECOND** — the store's own
    /// load-bearing order, for the store's own reason: the reverse would make
    /// the kind check a function of an out-of-range index.
    ///
    /// ⚠️ **A CLAMP ENDS THE SEARCH, IT DOES NOT FILTER IT.** The moment
    /// `clampedTrackDelta` reports it engaged, the group has reached the end of
    /// the track list in this direction and every larger magnitude clamps to the
    /// same place — so the loop stops and falls back. Continuing would spin over
    /// magnitudes that all resolve to one already-rejected landing. This is also
    /// what makes the search TERMINATE without trusting the loop bound: reading
    /// range from its one home means there is no second opinion about where the
    /// list ends.
    ///
    /// ═══ THE ZERO-SKIP CASE IS THE COMMON ONE ═══
    ///
    /// Magnitude 1 is tried FIRST and returned unchanged when it is legal, so
    /// every press that worked before this existed still asks for exactly ±1 and
    /// still produces the identical `ClipsTrackMoveResult`. The search is only
    /// reachable on a press that used to hit the wall.
    ///
    /// - Parameters:
    ///   - step: the press, from its one producer (`ArrangeNudge.verticalStep`).
    ///     Taken whole rather than as a bare sign so this cannot be handed a
    ///     direction the keyboard cannot produce.
    ///   - movingClipIDs: the resolved arrange selection — every clip that will
    ///     travel with the press.
    ///   - tracks: the project's live tracks, in store order.
    public static func delta(step: ArrangeVerticalNudgeStep,
                             movingClipIDs: Set<UUID>,
                             tracks: [Track]) -> Int {
        let fallback = step.trackDelta
        guard fallback != 0, !tracks.isEmpty, !movingClipIDs.isEmpty else { return fallback }

        // The mover collection is `ArrangeVerticalDrag.effectiveDelta`'s, walked
        // the same way for the same reason: iterating TRACKS and filtering by
        // id-set membership makes a duplicate id — or a stale one — structurally
        // unable to produce a second, phantom mover.
        var movers: [(source: Int, clip: Clip)] = []
        for (index, track) in tracks.enumerated() {
            for clip in track.clips where movingClipIDs.contains(clip.id) {
                movers.append((index, clip))
            }
        }
        guard let lo = movers.map(\.source).min(),
              let hi = movers.map(\.source).max() else { return fallback }

        let sign = fallback < 0 ? -1 : 1
        // BOUNDED BY THE TRACK COUNT. A group cannot travel more rows than the
        // list has, so this cannot spin even if the clamp below never fired.
        for magnitude in 1..<max(2, tracks.count) {
            let (effective, didClamp) = ProjectStore.clampedTrackDelta(
                requested: sign * magnitude,
                minTrackIndex: lo, maxTrackIndex: hi, trackCount: tracks.count)
            // Off the end of the list — see "A CLAMP ENDS THE SEARCH" above.
            guard !didClamp, effective != 0 else { break }
            let everyMoverLands = movers.allSatisfy { mover in
                let destination = mover.source + effective
                guard destination >= 0, destination < tracks.count else { return false }
                return tracks[destination].canHold(mover.clip)
            }
            if everyMoverLands { return effective }
        }
        // NO REACHABLE LANE. Hand back the raw press so the store refuses it
        // exactly as it does today — this function's job is to choose the
        // request, never to invent an outcome.
        return fallback
    }
}
