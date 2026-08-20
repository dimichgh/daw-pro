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

/// Constants for the humanize LEGATO pass (m27-o ⓑ) that more than one layer
/// has to agree on. Deliberately a top-level, NON-ISOLATED enum rather than a
/// static on the `@MainActor extension` below: the wire, the panel model and any
/// future non-UI caller all read this, and a MainActor-isolated constant would
/// make the first nonisolated reader a compile error for no reason. The BOUNDS
/// are deliberately NOT here — `HumanizeModel` restates them verbatim beside its
/// `timingBounds`/`velocityBounds` (that file's standing precedent, pinned by a
/// test that compares them to the wire's guards); only the one number that
/// carries a musical JUSTIFICATION lives in a single home.
public enum HumanizeLegato {
    /// Default gap ceiling, in beats, for the legato pass: a gap at or below
    /// this is treated as articulation and closed; anything larger is a REST
    /// (most importantly a wind player's breath) and is left exactly as
    /// authored.
    ///
    /// **Why 0.125 (a thirty-second note at a quarter-note beat).**
    /// `docs/research/spike-wind-instrument-realism.md` §1.4/§6 could find no
    /// source willing to put a number on a breath and offers, as an explicit
    /// engineering estimate, 150–400 ms for a catch breath — ≈0.18–0.48 beats at
    /// the 72 BPM ballad tempo the spike works in. 0.125 sits BELOW the bottom
    /// of that band, so the default cannot swallow even the shortest breath the
    /// research is willing to name, while it does close the abutting (gap == 0)
    /// and near-abutting joins that are the measured defect (225/225 sax notes
    /// abutted or gapped, none overlapped). Erring small is the right direction
    /// here: a gap left open is a missed improvement, a rest closed by default
    /// is destroyed musical intent.
    ///
    /// ⚠️ The threshold is in BEATS and a breath is in MILLISECONDS, so the two
    /// only line up at one tempo. Below ≈45 BPM, 0.125 beat exceeds 150 ms and
    /// the default could close a very short breath; a caller working that slow
    /// should pass a smaller `maxGapBeats`.
    public static let defaultMaxGapBeats: Double = 0.125
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

    /// Applies deterministic, seeded "human feel" jitter to a MIDI clip's notes,
    /// and — only when asked — a deterministic LEGATO/gate pass on top.
    ///
    /// Each note gets an INDEPENDENT uniform timing offset in
    /// `[-timingBeats, +timingBeats]` beats and an independent uniform integer
    /// velocity offset in `[-velocityRange, +velocityRange]`, drawn in array
    /// order from a `SeededRandomNumberGenerator`. Clamps: a note's resulting
    /// onset never falls before the clip start (clip-local 0) nor at/after the
    /// clip end (`lengthBeats`, less a `minLengthBeats` sliver so the note keeps
    /// a foothold inside the clip); velocity clamps to 1...127. Note IDs and
    /// ARRAY ORDER are always preserved (unlike quantize, this does NOT
    /// re-canonicalize — index `i` in maps 1:1 to index `i` out, so an agent can
    /// correlate the results with what it sent), and so are PITCHES and the
    /// (possibly jittered) START beats. **Note LENGTHS are preserved too UNLESS
    /// `legatoOverlapBeats > 0`** — that is the one thing this method changes
    /// about lengths, and only on request.
    ///
    /// ## The legato pass (m27-o ⓑ)
    ///
    /// **What it does, precisely — and what it cannot do.** With
    /// `legatoOverlapBeats > 0`, every note that is followed closely enough is
    /// lengthened so that it ends `legatoOverlapBeats` AFTER the following
    /// onset: gaps close, and joins overlap. **That MASKS the attack transient
    /// of the next note under the decaying tail of the previous one. It does NOT
    /// produce true legato and cannot**: there is no legato-hold or
    /// voice-steal-and-glide mode anywhere in this engine — the built-in
    /// `SamplerInstrument` fires a brand-new voice with a fresh envelope on
    /// every note-on, and a hosted AUSampler does the same
    /// (`docs/research/spike-wind-instrument-realism.md` §3.1, code-read). Every
    /// retrigger still happens; it is merely less exposed. Anything that claims
    /// otherwise is wrong about this engine.
    ///
    /// Per note, ordered by start beat:
    /// - `gap = nextOnset - (startBeat + lengthBeats)`.
    /// - `0 <= gap <= maxGapBeats` → the length is set so the note ends
    ///   `legatoOverlapBeats` past `nextOnset`.
    /// - `gap > maxGapBeats` → LEFT ALONE. That gap is a rest — for a wind part,
    ///   a breath — and closing it is destroying musical intent, not improving
    ///   articulation. This is the parameter that makes the pass musical.
    /// - `gap < 0` (the notes ALREADY overlap) → LEFT ALONE, never normalised
    ///   down to `legatoOverlapBeats`. The pass only ever EXTENDS. Shortening
    ///   here would chop a deliberately held note (a pad under a melody is the
    ///   ordinary case) in the name of a "legato" the user asked for on the
    ///   melody, and no user pressing a legato control expects notes to get
    ///   shorter. It also buys idempotence: after one pass every touched note
    ///   has `gap == -legatoOverlapBeats < 0`, so a second pass with the same
    ///   arguments is a no-op — unlike the jitter above, which compounds.
    /// - The LAST onset in the clip is never extended: nothing follows it.
    ///
    /// **"The following note" when notes are simultaneous (chords).** The
    /// successor is the earliest onset STRICTLY GREATER than this note's own, so
    /// notes that share an onset are one attack point and never truncate each
    /// other — a chord extends as a block into the next attack. This is exactly
    /// Logic's "Force Legato" and Ableton's Legato note transform (spike §1.2,
    /// §5), it is exact for the monophonic wind line this feature was built for,
    /// and on genuinely polyphonic material it stays conservative (a note is
    /// never lengthened beyond the next attack plus the overlap). The rejected
    /// alternative — successor = next element in start order regardless of ties
    /// — extends only ONE voice of each chord and leaves the rest, which is
    /// arbitrary. Simultaneity is exact `startBeat` equality; after timing
    /// jitter, notes authored together are no longer simultaneous and are
    /// treated as the separate attacks they have become.
    ///
    /// **Same-pitch repeats abut instead of overlapping — a deliberate
    /// exception, and it is about MIDI, not taste.** If the following onset
    /// contains a note of the SAME pitch, the extension stops exactly AT that
    /// onset (zero overlap). A hosted AU receives plain MIDI 1.0 channel
    /// messages, where note-off carries only a pitch
    /// (`HostedAUInstrument.render`, `0x80 pitch 0`): overlapping two same-pitch
    /// notes would make the first note's off arrive after the second note's on
    /// and silence the note that just started — a dropped note, in the exact
    /// direction this feature exists to fix. Abutting is safe because the
    /// schedule's canonical order puts off BEFORE on at an equal time
    /// (`MIDISchedule.swift` — "the off-before-on tie rule is load-bearing").
    /// The built-in sampler pairs off events by `noteID` and would tolerate the
    /// overlap, but DAWCore cannot see which instrument a track carries, so the
    /// rule that is correct everywhere wins.
    ///
    /// **Clip bounds.** A note is never EXTENDED past the clip end: the target
    /// end clamps to `clip.lengthBeats`. A note that already overhangs the end
    /// (legal, and authored that way) keeps its length — the clamp bounds the
    /// extension, it does not trim what was already there, because this pass
    /// never shortens anything.
    ///
    /// **The legato pass consumes NO random numbers.** It runs after the jitter
    /// loop, reads only start beats and lengths, and draws nothing — so a seeded
    /// timing/velocity result is bit-identical whether or not the legato
    /// arguments are supplied. It runs LAST on purpose: overlaps have to be
    /// measured against the onsets the notes actually ended up with.
    ///
    /// Determinism: same `seed` → identical result. `seed == nil` draws a fresh
    /// seed internally (in `[0, 2^53)` so it round-trips exactly through the
    /// JSON number wire); the drawn value is RETURNED as `seedUsed` so a caller
    /// can reproduce or re-roll the exact take. `timingBeats == 0` and
    /// `velocityRange == 0` are valid no-ops on their axis (the draw is skipped,
    /// not consumed); all three amounts zero (the default for
    /// `legatoOverlapBeats`) round-trips the clip bit-identically.
    ///
    /// `maxGapBeats` alone does NOTHING: it is a ceiling ON the legato pass, and
    /// the pass runs only when `legatoOverlapBeats > 0`.
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
                                  seed: UInt64?,
                                  legatoOverlapBeats: Double = 0,
                                  maxGapBeats: Double = HumanizeLegato.defaultMaxGapBeats) throws -> (clip: Clip, seedUsed: UInt64) {
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

        // The legato/gate pass — LAST (it measures against the onsets the notes
        // actually ended up with) and RNG-FREE (so the seeded jitter above is
        // bit-identical with or without it). `<= 0` is OFF, which is what makes
        // omitting the arguments a true no-op.
        if legatoOverlapBeats > 0 {
            applyLegatoPass(&humanized,
                            overlapBeats: legatoOverlapBeats,
                            maxGapBeats: maxGapBeats,
                            clipEnd: clipEnd)
        }

        performEdit("Humanize") {
            tracks[t].clips[c].notes = humanized
            engine?.tracksDidChange(tracks)
        }
        return (tracks[t].clips[c], seedUsed)
    }

    /// The legato/gate pass: lengthens notes so small gaps close and joins
    /// overlap by `overlapBeats`, leaving rests (gaps above `maxGapBeats`),
    /// already-overlapping notes, and the final onset alone. Pure and
    /// deterministic — no store access, no randomness, no engine (the semantics
    /// and every rejected alternative are argued on `humanizeClipNotes`).
    ///
    /// `nonisolated` because none of it needs the main actor: it is a function
    /// of the array it is handed. Kept on the extension (rather than as a free
    /// function) so it reads as part of this one operation.
    private nonisolated func applyLegatoPass(_ notes: inout [MIDINote],
                                             overlapBeats: Double,
                                             maxGapBeats: Double,
                                             clipEnd: Double) {
        guard notes.count > 1 else { return }

        // Group INDICES by onset, in start order. Indices — not notes — because
        // the array order is part of the method's contract: every write below
        // lands on the note's ORIGINAL index. `sorted(by:)` is not documented as
        // stable, which is harmless here: tied notes land in the same group and
        // every member of a group sees the same successor onset, so their
        // relative order inside it cannot change any result.
        let order = notes.indices.sorted { notes[$0].startBeat < notes[$1].startBeat }
        var groups: [(onset: Double, indices: [Int])] = []
        for index in order {
            let onset = notes[index].startBeat
            if var last = groups.last, last.onset == onset {
                last.indices.append(index)
                groups[groups.count - 1] = last
            } else {
                groups.append((onset: onset, indices: [index]))
            }
        }
        guard groups.count > 1 else { return }   // one attack point: nothing follows it

        for groupIndex in 0..<(groups.count - 1) {
            let nextOnset = groups[groupIndex + 1].onset
            // Which pitches sound AT the next attack — a same-pitch successor
            // forces an exact abut instead of an overlap (MIDI note-off carries
            // only a pitch on the hosted-AU path).
            let nextPitches = Set(groups[groupIndex + 1].indices.map { notes[$0].pitch })

            for index in groups[groupIndex].indices {
                let note = notes[index]
                let gap = nextOnset - (note.startBeat + note.lengthBeats)
                // The gap test now lives in `PhraseDetection.classify` — the ONE
                // definition of "is this gap a breath?", shared with the breath
                // pad's phrase splitter so the two cannot drift apart. The
                // behaviour is unchanged and the classifier's doc comment
                // records why its branch order is what it is (including the NaN
                // path the old `guard gap >= 0, gap <= maxGapBeats` had):
                // `.overlap` (gap < 0) is already joined and is never shortened,
                // `.breath` (gap > maxGapBeats) is a rest and is preserved
                // untouched, and only `.articulation` is closed.
                guard PhraseDetection.classify(gapBeats: gap,
                                               maxGapBeats: maxGapBeats) == .articulation else {
                    continue
                }

                let overlap = nextPitches.contains(note.pitch) ? 0 : overlapBeats
                let targetEnd = min(nextOnset + overlap, clipEnd)
                // `max` with the current length is the never-shorten invariant:
                // it also means a note authored to overhang the clip end keeps
                // its length instead of being trimmed by the bound.
                notes[index].lengthBeats = max(note.lengthBeats, targetEnd - note.startBeat)
            }
        }
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
