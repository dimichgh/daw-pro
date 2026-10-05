import Foundation

/// Pure quantize math (M5 iii-d, spec §4), headless-testable and shared by the
/// MIDI quantizer, the future audio quantizer (iii-f), and the piano-roll UI.
/// No engine, no store, no I/O — just beats in, beats out.
///
/// `QuantizeSettings` carries the grid, an interpolation `strength`, and an
/// MPC-style `swingPercent`. The GROOVE field (a per-slot offset table) lands in
/// M5 (iii-g); it is a documented SEAM here (see `QuantizeTarget.slotOffset`) so
/// grooves plug in as an internal, additive branch WITHOUT changing this struct's
/// shape, `QuantizeTarget.nearest`'s signature, or the `clip.quantize` wire.
public struct QuantizeSettings: Sendable, Equatable {
    /// Grid resolution in beats; must be `> 0`. Musical mapping (x/4 meter):
    /// 1.0 = 1/4 note, 0.5 = 1/8, 0.25 = 1/16, 0.125 = 1/32, and 2/3-scaled
    /// values for triplets (e.g. 1/3 ≈ 0.3333 = 1/8 triplet). A grid `<= 0`
    /// makes every evaluator a no-op (targets equal the input).
    public var gridBeats: Double
    /// Interpolation amount toward the target, `0...1`:
    /// `new = old + strength·(target − old)`. 1 = snap fully to grid, 0 = leave
    /// the note where it is (identity), 0.5 = move exactly halfway. Clamped to
    /// `0...1` by every evaluator.
    public var strength: Double
    /// MPC-style swing percent, `50...75`. 50 = straight; a higher value delays
    /// the ODD (offbeat) grid slots by `(2·swing/100 − 1)·gridBeats` (75 = max,
    /// a half-grid late = the classic triplet-ish shuffle). Values below 50 read
    /// as straight (the lower bound is pinned to 50 at evaluation time).
    public var swingPercent: Double
    /// MIDI only: also snap note ENDS to the grid (min length preserved). When
    /// false (default) onsets move and lengths are kept verbatim.
    public var quantizeEnds: Bool

    /// When set, per-slot targets come from the GROOVE (M5 iii-g, spec §6)
    /// instead of the straight/swing grid: slot `i`'s deviation is the groove's
    /// `offsets[i mod count]` (the slot folded into the groove cycle). The
    /// groove WINS over `swingPercent` — documented, no error (spec §4). Additive
    /// with a `nil` default, so no existing call site or wire shape moves. The
    /// grid the groove was defined on (`groove.gridBeats`) is expected to match
    /// `gridBeats` for musically-correct targets (the store/command layer pass
    /// them together).
    public var groove: GrooveTemplate?

    public init(
        gridBeats: Double,
        strength: Double = 1,
        swingPercent: Double = 50,
        quantizeEnds: Bool = false,
        groove: GrooveTemplate? = nil
    ) {
        self.gridBeats = gridBeats
        self.strength = strength
        self.swingPercent = swingPercent
        self.quantizeEnds = quantizeEnds
        self.groove = groove
    }
}

/// **The values the quantize and groove verbs refuse** (m23-ap I5-F4, round 3):
/// ONE home, read by the store (`ProjectStore.extractGroove`) and by every wire
/// verb whose grid reaches the slot math (`clip.quantize`, `clip.quantizeAudio`,
/// `groove.extract`), so the refusal and the text that names it cannot drift.
///
/// Nothing musical is near either bound. The finest grid the app offers
/// anywhere is 1/64 note = 0.0625 beat (`QuantizeModel.grids`,
/// `SnapResolution.sixtyFourth`); `minimumGridBeats` is 64 times finer. The
/// default groove is 16 slots (4 beats at 1/16); `maximumGrooveSlots` is 4096
/// times that.
///
/// The quantize MATH does not rely on these: `QuantizeTarget` is total on every
/// input (see `slotOffset`). The bounds exist so a wire call gets a refusal in
/// words instead of a meaningless answer, and so `GrooveTemplate.extract`,
/// whose slot count is `cycle / grid` converted to `Int`, never sees a grid or
/// cycle that would trap it or allocate gigabytes.
public enum QuantizeLimits {
    /// The finest grid a verb accepts: 1/1024 beat (0.0009765625).
    public static let minimumGridBeats: Double = 1.0 / 1024
    /// The most slots one groove cycle may hold: `cycleBeats / gridBeats`,
    /// rounded (the count `GrooveTemplate` builds).
    public static let maximumGrooveSlots = 65_536

    /// Whether quantize can use `gridBeats` as its grid (m23-ap I5-F4 round 4):
    /// finite, at least `minimumGridBeats`, and no longer than the timeline
    /// itself (`TimelineLimits.maximumBeats`; a grid that long puts every line
    /// at beat 0). The ONE test the wire's grid refusal (`gridFloorProblem`) and
    /// the quantize panel's saved-groove refusal (`QuantizeModel`) share; each
    /// words it for its own reader.
    public static func isUsableGrid(_ gridBeats: Double) -> Bool {
        gridBeats.isFinite && gridBeats >= minimumGridBeats
            && gridBeats <= TimelineLimits.maximumBeats
    }
}

/// **How far a clip's first beat sits past a line of the SONG's grid** (m23-ap
/// I5-F4) — the one home for "is this clip on the grid, and by how much is it
/// off".
///
/// ## Why quantize stopped counting from the clip's start
///
/// A note's beats are CLIP-LOCAL (`MIDINote.startBeat` counts from the clip's
/// first beat), and the quantizer rounded them on a grid that began at that
/// first beat. The piano roll draws its grid from the SONG's beat 0 (I5-F2,
/// `PianoRollSongGrid`) and snaps every note edit there (I5-F3). So on a clip
/// that does not start on a grid line — a clip at beat 2.1 under 1/16 —
/// "Quantize to 1/16" put every note BETWEEN the lines the user was looking at.
/// The phase is how far the quantizer shifts its grid so that its lines ARE the
/// drawn ones.
///
/// ## Exactly 0 on a line, never "tiny"
///
/// `phase = start mod step`, read as 0 within `onGridTolerance`: triplet steps
/// are not binary-exact (16 mod 1/3 is ~1e-15, not 0), and a nanobeat is far
/// below any editable resolution. ⭐ EXACTLY 0 is what lets every consumer run
/// its pre-I5-F4 expression verbatim for a clip that starts on a line — the
/// bit-identity the regression pins compare.
///
/// `PianoRollSongGrid.phase` forwards here, so the roll's snaps, the step
/// sequencer's columns and the quantizer agree about what "on a line" means
/// because there is one definition of it.
public enum SongGridPhase {
    /// Below this a clip's start counts as ON a grid line.
    public static let onGridTolerance = 1e-9

    /// How far `start` sits past the last grid line at or before it, or exactly
    /// 0 when it sits on one (within `onGridTolerance`, from either side). A
    /// non-finite start or a non-positive step reads as on the grid.
    public static func phase(of start: Double, step: Double) -> Double {
        guard start.isFinite, step > 0 else { return 0 }
        var phase = start.truncatingRemainder(dividingBy: step)
        if phase < 0 { phase += step }
        if phase < onGridTolerance || step - phase < onGridTolerance { return 0 }
        return phase
    }

    /// The SONG-grid index of the line at or before `start` — how many whole
    /// steps it is from the song's beat 0 (m23-ap I5-F4). A whole number, as a
    /// `Double` so it adds exactly to the quantizer's `Double` slots; a start a
    /// nanobeat short of a line counts as ON it (the `phase` tolerance). 0 for
    /// a non-finite start or a non-positive step.
    ///
    /// Swing and grooves read their per-slot deviation at `firstLineIndex +
    /// the clip's own slot`, so the offbeats that swing are the SONG's offbeats
    /// wherever the clip starts (the orchestrator's 2026-09-27 ruling).
    public static func firstLineIndex(of start: Double, step: Double) -> Double {
        guard start.isFinite, step > 0 else { return 0 }
        return ((start - phase(of: start, step: step)) / step).rounded()
    }
}

/// The single target evaluator both quantizers use: given a source beat and the
/// settings, returns the beat position the grid wants that onset to land on
/// (BEFORE the strength interpolation — callers do the lerp). Deterministic.
///
/// `nearest(toBeat:)` rounds on a grid that starts at the beat it is handed 0
/// for: the audio quantizer hands it TIMELINE beats, so its grid is the song's.
/// A MIDI clip's beats are clip-local, so the MIDI path goes through
/// `nearest(toLocalBeat:clipStartBeat:settings:)`, which shifts the grid onto
/// the song's lines (m23-ap I5-F4).
public enum QuantizeTarget {
    /// Nearest STRAIGHT grid slot to `beat`, with that slot's swing (or, later,
    /// groove) offset applied. Snapping picks the slot on the un-swung grid, then
    /// the slot's offset shifts the returned target — the spec's evaluation order
    /// (slot selection is grid-relative; swing/groove is a per-slot deviation).
    /// A grid `<= 0` returns `beat` unchanged.
    ///
    /// ⭐ TOTAL (m23-ap I5-F4 round 3): no input traps. A grid too fine to count
    /// at this beat (`beat / grid` overflows) puts every beat on a line, so the
    /// beat is its own target; so does a target that would not be finite. For
    /// every other input the arithmetic is the one it always was, bit for bit.
    public static func nearest(toBeat beat: Double, settings: QuantizeSettings) -> Double {
        let grid = settings.gridBeats
        guard grid > 0 else { return beat }
        let quotient = beat / grid
        guard quotient.isFinite else { return beat }
        let slot = quotient.rounded()
        let target = slot * grid + slotOffset(slot: slot, settings: settings)
        return target.isFinite ? target : beat
    }

    /// **The target for a CLIP-LOCAL beat, on the SONG's grid** (m23-ap I5-F4):
    /// `local` counts from the clip's first beat and `clipStartBeat` is where
    /// that beat sits on the song timeline. The returned target is clip-local
    /// too, and lands on a line the piano roll draws.
    ///
    /// ⭐ **SWING AND GROOVE COUNT FROM THE SONG'S BEAT 0** (the orchestrator's
    /// 2026-09-27 ruling), exactly as `AudioQuantizePlan` always has (it
    /// quantizes timeline beats): a note's target — straight, swung or grooved
    /// — depends only on where it sits in the song. Counting from the clip's
    /// first grid line instead swung the song's DOWNBEATS on a clip that starts
    /// on an offbeat, disagreed with `clip.quantizeAudio`, and landed a groove
    /// on different song beats in different clips.
    public static func nearest(toLocalBeat local: Double, clipStartBeat: Double,
                               settings: QuantizeSettings) -> Double {
        let grid = settings.gridBeats
        return nearest(toLocalBeat: local,
                       phase: SongGridPhase.phase(of: clipStartBeat, step: grid),
                       firstLine: SongGridPhase.firstLineIndex(of: clipStartBeat, step: grid),
                       settings: settings)
    }

    /// `nearest(toLocalBeat:clipStartBeat:settings:)` with the placement already
    /// taken (the quantizer takes it once per clip, not once per note):
    /// `phase` is how far the clip's first beat sits past the song line at or
    /// before it, and `firstLine` is that line's song-grid index.
    ///
    /// The slot is picked on the clip's own terms and kept in small numbers —
    /// `(local / grid).rounded()` when the clip starts on a line (the pre-I5-F4
    /// expression), `((local + phase) / grid).rounded()` with its line at
    /// `slot · grid − phase` otherwise — rather than as `nearest(start + local)
    /// − start`, which loses bits at a large start and can flip a tie. Only the
    /// DEVIATION is read at the song slot, `firstLine + slot`. So a clip that
    /// starts on a line whose song slot is EVEN, and on the groove's period,
    /// quantizes bit for bit as before I5-F4; a straight quantize (no swing, no
    /// groove) does on every clip that starts on a line.
    ///
    /// TOTAL like `nearest(toBeat:)`: an overflowing quotient or a non-finite
    /// target returns `local`. `firstLine` may be huge or infinite (a clip far
    /// out, or a grid far finer than any the app offers); `slotOffset` takes
    /// the song slot in Double, so neither traps.
    static func nearest(toLocalBeat local: Double, phase: Double, firstLine: Double,
                        settings: QuantizeSettings) -> Double {
        let grid = settings.gridBeats
        guard grid > 0 else { return local }
        if phase == 0 {
            let quotient = local / grid
            guard quotient.isFinite else { return local }
            let slot = quotient.rounded()
            let target = slot * grid + slotOffset(slot: firstLine + slot, settings: settings)
            return target.isFinite ? target : local
        }
        let quotient = (local + phase) / grid
        guard quotient.isFinite else { return local }
        let slot = quotient.rounded()
        let target = slot * grid - phase + slotOffset(slot: firstLine + slot, settings: settings)
        return target.isFinite ? target : local
    }

    /// Per-slot timing deviation from the straight grid, in beats. Today this is
    /// the MPC swing delay on odd (offbeat) slots; even slots stay put. When a
    /// GROOVE is set (M5 iii-g) its per-slot offset table (the slot folded into
    /// the groove cycle via `offset(forSlot:)`) substitutes here and WINS over
    /// swing — `nearest`'s signature and the wire shape never move, so the change
    /// is one internal branch.
    ///
    /// ⭐ TOTAL (m23-ap I5-F4 round 3): the slot is NEVER converted to `Int`.
    /// It was, and `Int(slot)` traps once `|slot|` reaches 2^63: a 1e-19 grid
    /// with a note one beat in, or (since the song slot counts the clip's start)
    /// a clip past 2.3e18 beats on a 1/16 grid, crashed the app from one wire
    /// call. Parity and the groove fold are now taken in Double, which is exact
    /// for every whole-number Double, so every in-range slot gets the same
    /// answer bit for bit. Past 2^53 every Double is even, so swing reads as
    /// straight there; a non-finite slot reads as slot 0.
    static func slotOffset(slot: Double, settings: QuantizeSettings) -> Double {
        // Groove wins over swing (spec §4): the resolved template's per-slot
        // offset replaces the swing delay entirely.
        if let groove = settings.groove {
            // A saved template decoded with no offsets has nothing to add (and
            // `offset(forSlot:)` would index an empty table).
            guard !groove.offsets.isEmpty else { return 0 }
            return groove.offset(forSlot: foldedSlot(slot, count: groove.slotCount))
        }
        // Odd (offbeat) slots swing late; even slots (downbeats) stay.
        let parity = slot.truncatingRemainder(dividingBy: 2)
        guard parity.isFinite, parity != 0 else { return 0 }
        let swing = max(50, settings.swingPercent)
        return (2 * swing / 100 - 1) * settings.gridBeats
    }

    /// `slot mod count` in `0..<count`, taken in Double so no slot is converted
    /// to `Int` (the value handed to `Int` is already below `count`). The same
    /// fold `GrooveTemplate.offset(forSlot:)` applies to an `Int`, whose own
    /// re-fold of this in-range index is the identity. A non-finite slot folds
    /// to 0.
    static func foldedSlot(_ slot: Double, count: Int) -> Int {
        guard count > 1 else { return 0 }
        var folded = slot.truncatingRemainder(dividingBy: Double(count))
        guard folded.isFinite else { return 0 }
        if folded < 0 { folded += Double(count) }
        return min(count - 1, max(0, Int(folded)))
    }
}

/// Destructive MIDI note quantizer (M5 iii-d). Onsets move toward their grid
/// targets by `strength`; note LENGTHS are preserved verbatim (ends follow the
/// onset) unless `quantizeEnds`, in which case ends snap too (never below
/// `MIDINote.minLengthBeats`). Output is canonically ordered; every note is
/// rebuilt through `MIDINote.init` so the model invariants (startBeat ≥ 0,
/// min length, canonical order) hold. Pure and deterministic: same notes +
/// settings → identical output.
public enum MIDIQuantizer {
    /// A clip whose first beat is the SONG's beat 0 — the pre-I5-F4 entry point,
    /// kept for every caller that means exactly that. It forwards with
    /// `clipStartBeat: 0` (phase 0, first line 0), so it runs the unchanged
    /// expression.
    public static func quantize(_ notes: [MIDINote], settings: QuantizeSettings) -> [MIDINote] {
        quantize(notes, settings: settings, clipStartBeat: 0)
    }

    /// **Quantize a clip's notes on the SONG's grid** (m23-ap I5-F4): `notes`
    /// are the clip's (clip-local beats) and `clipStartBeat` is where the clip
    /// starts on the song timeline, so every target is a line the piano roll
    /// draws — for a clip at 2.1 under 1/16, song 2.25, 2.5, …, never 2.1 + n/16
    /// — and swing and grooves count from the song's beat 0, so the notes that
    /// swing are the song's offbeats wherever the clip starts.
    ///
    /// Bit-identical to the pre-I5-F4 clip-local quantizer for a clip that
    /// starts on a line whose song slot is EVEN and on the groove's period, and
    /// for a straight quantize on any clip that starts on a line.
    ///
    /// Notes clamp at the clip's first beat (0) only, never at its end — the
    /// I5-F3 ruling for every roll edit. A note whose nearest line is before an
    /// off-grid clip's start lands ON the clip's start.
    public static func quantize(_ notes: [MIDINote], settings: QuantizeSettings,
                                clipStartBeat: Double) -> [MIDINote] {
        let strength = settings.strength.clamped(to: 0...1)
        let grid = settings.gridBeats
        let phase = SongGridPhase.phase(of: clipStartBeat, step: grid)
        let firstLine = SongGridPhase.firstLineIndex(of: clipStartBeat, step: grid)
        let moved = notes.map { note -> MIDINote in
            let target = QuantizeTarget.nearest(toLocalBeat: note.startBeat, phase: phase,
                                                firstLine: firstLine, settings: settings)
            let newStart = max(0, note.startBeat + strength * (target - note.startBeat))
            let newLength: Double
            if settings.quantizeEnds {
                let endTarget = QuantizeTarget.nearest(toLocalBeat: note.endBeat, phase: phase,
                                                       firstLine: firstLine, settings: settings)
                let newEnd = note.endBeat + strength * (endTarget - note.endBeat)
                newLength = max(MIDINote.minLengthBeats, newEnd - newStart)
            } else {
                newLength = note.lengthBeats
            }
            return MIDINote(
                id: note.id,
                pitch: note.pitch,
                velocity: note.velocity,
                startBeat: newStart,
                lengthBeats: newLength
            )
        }
        return MIDINote.canonicallyOrdered(moved)
    }
}
