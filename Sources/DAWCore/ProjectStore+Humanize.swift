import Foundation

/// A tiny, seedable pseudo-random generator (splitmix64) for DETERMINISTIC
/// humanize jitter. Swift's `SystemRandomNumberGenerator` is not seedable, so a
/// reproducible "human feel" needs its own stream: the same seed always yields
/// the same sequence, which is what lets an agent re-roll or reproduce a take
/// (`clip.humanize`'s `seedUsed` contract). The mix constants are the canonical
/// splitmix64 values; conforming to `RandomNumberGenerator` lets the standard
/// `Double.random`/`Int.random` uniform mappings ride on top of it.
///
/// Internal (not private) so the humanize store method can use it; it stays
/// tested THROUGH the public method — determinism/difference assertions pin the
/// stream without exposing the generator on the wire.
struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        // Any seed (including 0) is valid — splitmix64's increment guarantees a
        // full-period walk regardless of the starting state.
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Humanize store operation (M7 macro-a): the inverse-spirited sibling of
/// `clip.quantize`. Where quantize pulls onsets TOWARD the grid, humanize
/// nudges them (and velocities) OFF it by small seeded random amounts, for a
/// less-mechanical feel — applied as ONE undoable edit on the same
/// `tracksDidChange` restart seam `setClipNotes`/`quantizeClipNotes` use (the
/// engine never learns about humanize). New domain, its own extension file (the
/// ProjectStore.swift-is-2.3k-lines rule).
@MainActor
extension ProjectStore {

    /// Applies deterministic, seeded "human feel" jitter to a MIDI clip's notes.
    ///
    /// Each note gets an INDEPENDENT uniform timing offset in
    /// `[-timingBeats, +timingBeats]` beats and an independent uniform integer
    /// velocity offset in `[-velocityRange, +velocityRange]`, drawn in array
    /// order from a `SeededRandomNumberGenerator`. Clamps: a note's resulting
    /// onset never falls before the clip start (clip-local 0) nor at/after the
    /// clip end (`lengthBeats`, less a `minLengthBeats` sliver so the note keeps
    /// a foothold inside the clip); velocity clamps to 1...127. Note LENGTHS are
    /// untouched, and note IDs and ARRAY ORDER are preserved (unlike quantize,
    /// this does NOT re-canonicalize — index `i` in maps 1:1 to index `i` out,
    /// so an agent can correlate the jittered notes with what it sent).
    ///
    /// Determinism: same `seed` → identical result. `seed == nil` draws a fresh
    /// seed internally (in `[0, 2^53)` so it round-trips exactly through the
    /// JSON number wire); the drawn value is RETURNED as `seedUsed` so a caller
    /// can reproduce or re-roll the exact take. `timingBeats == 0` and
    /// `velocityRange == 0` are valid no-ops on their axis (the draw is skipped,
    /// not consumed); both zero round-trips the clip bit-identically.
    ///
    /// Rejections, verbatim: an AUDIO clip → `notAMIDIClip` (same mapping as
    /// `clip.setNotes`); an unknown id → `clipNotFound`.
    ///
    /// `performEdit("Humanize")` — one undo step restoring the exact prior
    /// notes. NO coalescing: a re-run compounds the jitter (undo first, or pass
    /// the returned seed to reproduce). Returns the updated clip and the seed
    /// actually used.
    @discardableResult
    public func humanizeClipNotes(clipID: UUID,
                                  timingBeats: Double,
                                  velocityRange: Int,
                                  seed: UInt64?) throws -> (clip: Clip, seedUsed: UInt64) {
        guard let (t, c) = locateClipIndex(clipID) else {
            throw ProjectError.clipNotFound(clipID)
        }
        // Comp members are store-managed — reject before touching notes, the
        // same invariant quantizeClipNotes/setClipNotes enforce (edit the comp
        // with take.setComp, or take.flatten first).
        try requireNotCompMember(trackIndex: t, clipIndex: c)
        // MIDI only — an audio clip has no notes to feel-shift.
        guard let notes = tracks[t].clips[c].notes else {
            throw ProjectError.notAMIDIClip(clipID)
        }

        // Resolve the seed: a nil request draws one in the Double-exact range so
        // `seedUsed` survives the JSON number wire unchanged (reproducibility).
        let seedUsed = seed ?? UInt64.random(in: 0 ..< (1 << 53))
        var rng = SeededRandomNumberGenerator(seed: seedUsed)

        // Upper timing bound: strictly inside the clip. A note may legally have
        // been authored past the clip end (an overhang start); humanize pulls
        // the RESULTING onset back to just under the end rather than emitting a
        // note that starts at/after it.
        let clipEnd = tracks[t].clips[c].lengthBeats
        let maxStart = max(0, clipEnd - MIDINote.minLengthBeats)

        var humanized = notes
        for i in humanized.indices {
            if timingBeats > 0 {
                let offset = Double.random(in: -timingBeats...timingBeats, using: &rng)
                let raw = humanized[i].startBeat + offset
                humanized[i].startBeat = min(max(0, raw), maxStart)
            }
            if velocityRange > 0 {
                let vOffset = Int.random(in: -velocityRange...velocityRange, using: &rng)
                humanized[i].velocity = (humanized[i].velocity + vOffset)
                    .clamped(to: MIDINote.velocityRange)
            }
        }

        performEdit("Humanize") {
            tracks[t].clips[c].notes = humanized
            engine?.tracksDidChange(tracks)
        }
        return (tracks[t].clips[c], seedUsed)
    }

    /// Locates a clip by id across every track (extension-local; the private
    /// `locateClip(_:)` in ProjectStore.swift is not visible cross-file — the
    /// same reason ProjectStore+Quantize.swift keeps its own copy).
    private func locateClipIndex(_ id: UUID) -> (t: Int, c: Int)? {
        for (t, track) in tracks.enumerated() {
            if let c = track.clips.firstIndex(where: { $0.id == id }) {
                return (t, c)
            }
        }
        return nil
    }
}
