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

/// The single target evaluator both quantizers use: given a source beat and the
/// settings, returns the beat position the grid wants that onset to land on
/// (BEFORE the strength interpolation — callers do the lerp). Deterministic.
public enum QuantizeTarget {
    /// Nearest STRAIGHT grid slot to `beat`, with that slot's swing (or, later,
    /// groove) offset applied. Snapping picks the slot on the un-swung grid, then
    /// the slot's offset shifts the returned target — the spec's evaluation order
    /// (slot selection is grid-relative; swing/groove is a per-slot deviation).
    /// A grid `<= 0` returns `beat` unchanged.
    public static func nearest(toBeat beat: Double, settings: QuantizeSettings) -> Double {
        let grid = settings.gridBeats
        guard grid > 0 else { return beat }
        let slot = (beat / grid).rounded()
        return slot * grid + slotOffset(slot: slot, settings: settings)
    }

    /// Per-slot timing deviation from the straight grid, in beats. Today this is
    /// the MPC swing delay on odd (offbeat) slots; even slots stay put. When a
    /// GROOVE is set (M5 iii-g) its per-slot offset table (the slot folded into
    /// the groove cycle via `offset(forSlot:)`) substitutes here and WINS over
    /// swing — `nearest`'s signature and the wire shape never move, so the change
    /// is one internal branch.
    static func slotOffset(slot: Double, settings: QuantizeSettings) -> Double {
        // Groove wins over swing (spec §4): the resolved template's per-slot
        // offset replaces the swing delay entirely.
        if let groove = settings.groove {
            return groove.offset(forSlot: Int(slot))
        }
        // Odd (offbeat) slots swing late; even slots (downbeats) stay.
        guard !Int(slot).isMultiple(of: 2) else { return 0 }
        let swing = max(50, settings.swingPercent)
        return (2 * swing / 100 - 1) * settings.gridBeats
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
    public static func quantize(_ notes: [MIDINote], settings: QuantizeSettings) -> [MIDINote] {
        let strength = settings.strength.clamped(to: 0...1)
        let moved = notes.map { note -> MIDINote in
            let target = QuantizeTarget.nearest(toBeat: note.startBeat, settings: settings)
            let newStart = max(0, note.startBeat + strength * (target - note.startBeat))
            let newLength: Double
            if settings.quantizeEnds {
                let endTarget = QuantizeTarget.nearest(toBeat: note.endBeat, settings: settings)
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
