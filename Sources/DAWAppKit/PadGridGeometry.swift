import Foundation
import DAWCore

// THE PAD GRID — the headless half of "this square is that slice" (m39-pads).
//
// ═══ WHY THIS FILE EXISTS ═══
//
// `clip.sliceToSampler` (m32-b2) chops a record into up to 96 `SamplerZone`s,
// one per MIDI note from `baseNote` 36 — C1, the MPC pad-1 note — upward, and
// writes a MIDI clip that replays the original groove. Measured 2026-09-19: an
// AI agent can chop and then play those pads over MCP, and **a human could
// reach none of it** (`grep -rniE 'padGrid|drumPad|padBank|fingerDrum' Sources/`
// → ZERO, positive-controlled against `breathPad` at 18 files). This file is
// the first half of the door; `PadGridModel` is the second and
// `DAWApp/Components/PadGridView` draws it.
//
// ═══ EVERYTHING HERE IS A PURE FUNCTION OF NUMBERS ═══
//
// `MusicalKeyboardGeometry` / `StepSequencerGeometry` / `MixerStripLayout`'s
// rule, and it earns its keep the same way: **a pad number somebody can be
// wrong about OUT LOUD is a pad number a test can pin.** Every mapping in this
// file — which square is pad 1, which pitch pad 1 fires, which bank a pitch
// falls in, which letter key drums which pad — is decided here and nowhere
// else, so the drawing, the hit test, the keyboard and the readouts cannot
// disagree about the same pad.
//
// No SwiftUI, no AppKit, no store. Non-isolated, so its suite costs nothing
// against the `@MainActor` suite cadence cap (380, and the tree is AT it).

/// The MPC-convention pad surface: 4 rows × 4 columns, pad 1 bottom-left.
///
/// ⭐⭐ **PAD 1 IS BOTTOM-LEFT AND THAT IS NOT A STYLE CHOICE — IT IS WHAT
/// NOTE 36 MEANS.** Every MPC since the 60 and every Ableton Drum Rack lays C1
/// (36) at the bottom-left square and counts left-to-right, bottom-to-top.
/// `SliceToSamplerSettings.defaultBaseNote` is 36 *because of that convention*
/// (its own comment says "C1, the MPC pad-1 note"), so drawing pad 1 at the
/// TOP-left would put the chop's first slice under the user's ring finger while
/// every piece of hardware and every tutorial they have ever seen puts it under
/// the index finger of the other hand. A grid that disagrees with the note
/// number is worse than no grid: it is a picture that lies about what a click
/// does.
///
/// ⚠️ **A 4×4 WAS CHOSEN OVER A 4×8, AND THE REASON IS THE HAND, NOT THE
/// SCREEN.** 4×8 fits — the strip is wide. But bank-switching 16 at a time is
/// what makes a pad's POSITION memorable: the kick stays bottom-left in every
/// bank of every kit the user will ever load, and one bank is one hand's span.
/// A 32-pad surface halves the bank count and destroys that, for a layout no
/// hand can cover without moving. 96 pads (the `maxSlicesHardCap`) is exactly
/// six banks of this grid.
public enum PadGridGeometry {

    /// Rows and columns of ONE bank.
    public static let rows = 4
    public static let columns = 4

    /// Pads in one bank — the bank stride in MIDI notes, too.
    ///
    /// ⚠️ **16, NOT 12, AND THE DIFFERENCE IS THE WHOLE BUG A REVIEWER SHOULD
    /// LOOK FOR.** Musical Typing's `baseOctave` steps the layout by TWELVE
    /// (`MusicalTypingRouting.baseNote(forOctave:)` = `(octave + 1) * 12`),
    /// because an octave is twelve semitones. A pad bank steps by SIXTEEN,
    /// because a bank is sixteen pads. Reusing `baseOctave` for banks — the
    /// obvious economy, and the first thing that looks like it should work —
    /// would make bank 2 start at pad 13 of bank 1, silently overlapping four
    /// pads and quietly hiding four slices. That is why the controller carries
    /// `padBaseNote` / `padBank` as their OWN state rather than reusing the
    /// octave it already has.
    public static let padsPerBank = rows * columns

    /// Every pad index of one bank, 0-based and in MPC order.
    public static let bankPadIndices = 0..<padsPerBank

    // MARK: - Square ↔ pad

    /// The pad at a DRAWN square. `displayRow` 0 is the TOP row on screen.
    ///
    /// The inversion (`rows - 1 - displayRow`) is the bottom-left law, applied
    /// in exactly one place.
    public static func padIndex(displayRow: Int, column: Int) -> Int? {
        guard displayRow >= 0, displayRow < rows, column >= 0, column < columns else {
            return nil
        }
        return (rows - 1 - displayRow) * columns + column
    }

    /// Where a pad is DRAWN. Inverse of `padIndex(displayRow:column:)`.
    public static func square(forPad padIndex: Int) -> (displayRow: Int, column: Int)? {
        guard bankPadIndices.contains(padIndex) else { return nil }
        return (rows - 1 - padIndex / columns, padIndex % columns)
    }

    // MARK: - Pad ↔ pitch

    /// The MIDI note a pad of `bank` fires.
    ///
    /// Returns nil when the arithmetic leaves MIDI — a bank whose top pad would
    /// need note 128. ⚠️ **NIL, NEVER A CLAMP.** A clamped pad would fire a note
    /// that belongs to a DIFFERENT pad, and two squares sounding one slice is
    /// exactly the plausible-looking-valid-answer failure this tree keeps
    /// shipping. The view draws such a pad as out-of-range and says so.
    public static func pitch(forPad padIndex: Int, baseNote: Int, bank: Int) -> Int? {
        guard bankPadIndices.contains(padIndex), bank >= 0 else { return nil }
        let value = baseNote + bank * padsPerBank + padIndex
        guard SamplerZone.pitchRange.contains(value) else { return nil }
        return value
    }

    /// Which bank a pitch falls in, and its pad index there — nil below
    /// `baseNote` (a zone mapped under pad 1 is not ON the grid, and saying so
    /// is how the model reports "N slices are out of reach").
    public static func location(ofPitch pitch: Int, baseNote: Int)
        -> (bank: Int, padIndex: Int)? {
        let offset = pitch - baseNote
        guard offset >= 0 else { return nil }
        return (offset / padsPerBank, offset % padsPerBank)
    }

    /// How many banks it takes to reach `highestPitch` from `baseNote` — at
    /// least 1, so an EMPTY grid still draws one bank of empty pads rather than
    /// collapsing to nothing.
    ///
    /// ⚠️ A pitch BELOW `baseNote` contributes nothing (it has no location on
    /// the grid) rather than producing a negative bank count.
    public static func bankCount(highestPitch: Int?, baseNote: Int) -> Int {
        guard let highestPitch, highestPitch >= baseNote else { return 1 }
        return (highestPitch - baseNote) / padsPerBank + 1
    }

    // MARK: - The letter keys

    /// The physical keys that drum the 16 pads of the current bank, in pad
    /// order (pad 1 first).
    ///
    /// ⭐⭐⭐ **A SPATIALLY ALIGNED 4×4 BLOCK — THE KEYS SIT UNDER THE HAND THE
    /// WAY THE PADS SIT ON SCREEN.** `Z X C V` are the BOTTOM row of the grid
    /// (pads 1-4, notes 36-39), `A S D F` the next, `Q W E R` the next, and
    /// `1 2 3 4` the TOP row (pads 13-16). The keyboard's bottom row drives the
    /// grid's bottom row, because pad 1 is bottom-left on every MPC, Maschine
    /// and Drum Rack — invert that and the surface is upside down against every
    /// instrument the user has played, in a way they will feel but not be able
    /// to name.
    ///
    /// ⛔⛔ **THIS REPLACED A LINEAR RE-READ OF THE PIANO ROW (m39-pads-2).**
    /// The first cut mapped the 17 note keys in piano order — Ableton's own
    /// answer and defensible on paper, but it is a LINEAR mapping onto a SQUARE
    /// surface, so a pad's screen position told you nothing about which key
    /// plays it: "row 2, column 3" was reachable only by knowing it was
    /// semitone 6 and that semitone 6 is `T`. That is transposition-by-lookup,
    /// not finger drumming, and finger drumming is the whole point of the
    /// surface. **Spatial correspondence is the feature, not a nicety.**
    ///
    /// ⚠️ The land-grab objection that blocked this is answered by MODE rather
    /// than avoidance — see `MusicalTypingRouting.padCaps`. Pads mode adds
    /// exactly six keycodes (`Q R 1 2 3 4`) and only while it is on.
    ///
    /// ⚠️ **THE PIANO ROW IS DEAD IN PADS MODE except for the four controls**
    /// (`K`/`L` bank, `O`/`P` velocity). A note key that silently did something
    /// here would be a surprise mid-take; it is simply not claimed.

    /// The US-ANSI legend drummed onto a pad, or nil when no key reaches it.
    ///
    /// ⚠️ Comes from `MusicalTypingRouting.padCaps` — the ONE key table — so a
    /// re-ordered block moves the pad legends with it. A second hard-coded list
    /// of letters here is exactly the drift `cap(forLabel:)` exists to prevent.
    /// (The legends are US-ANSI; on another layout the POSITIONS hold and the
    /// printed letters may not — the same cost `MusicalTypingRouting` documents
    /// for the keyboard, inherited verbatim rather than re-litigated.)
    public static func keyLabel(forPad padIndex: Int) -> String? {
        cap(forPad: padIndex)?.label
    }

    /// The key CODE that drums a pad — for the seam and for tests, so neither
    /// has to hard-code `0x06`.
    public static func keyCode(forPad padIndex: Int) -> UInt16? {
        cap(forPad: padIndex)?.keyCode
    }

    /// The pad block's cap for a pad, straight out of the one table.
    ///
    /// ⛔ INDEXED BY ROLE, NEVER BY ARRAY POSITION. `padCaps` happens to be
    /// written in pad order, but a surface that relied on that would break
    /// silently the first time somebody grouped the table by keyboard row.
    public static func cap(forPad padIndex: Int) -> MusicalTypingKeyCap? {
        guard bankPadIndices.contains(padIndex) else { return nil }
        return MusicalTypingRouting.padCaps.first { $0.role == .pad(index: padIndex) }
    }

    // MARK: - Velocity from where the pad was struck

    /// Velocity for a click at `normalizedY` (0 = the pad's TOP edge, 1 = its
    /// bottom), mapped onto the audition path's own 1…127.
    ///
    /// ⭐ **TOP IS LOUD, BOTTOM IS SOFT — the MPC/Maschine "pad position"
    /// convention**, and the direction matters: every hardware pad surface that
    /// maps position to level puts the hard hits at the far edge, away from the
    /// hand.
    ///
    /// ⚠️ **A FLOOR OF 1, NEVER 0.** `AuditionController.velocityRange` starts
    /// at 1 and a MIDI velocity of 0 is a NOTE-OFF — a pad struck at its very
    /// bottom edge must play quietly, not silently release itself.
    ///
    /// ⚠️⚠️ **THIS SETS THE ONE SHARED VELOCITY, AND THAT IS A CONSTRAINT OF
    /// THE SEAM RATHER THAN A CHOICE.** `LiveNoteSink.setHeldPitches` is
    /// SET-SHAPED: it carries a pitch set and ONE velocity for all of it. A
    /// per-hit velocity therefore cannot be represented while another pad is
    /// still held — the push would re-apply the newest velocity to every
    /// ringing note. So a pad strike moves the same velocity the `C`/`V` keys
    /// move and the strip's VELOCITY readout shows it, which at least makes the
    /// shared value VISIBLE instead of secretly wrong.
    public static func velocity(atNormalizedY normalizedY: Double) -> Int {
        let fromBottom = 1 - min(1, max(0, normalizedY))
        // ⚠️ `MIDINote.velocityRange`, NOT `AuditionController.velocityRange` —
        // they are the SAME 1…127 (verified, and `LivePlayController.velocityRange`
        // is literally an alias of the audition one), but `AuditionController` is
        // `@MainActor`-isolated and this file is deliberately not, so reaching for
        // it would force a pure geometry table onto the main actor for a constant.
        let range = MIDINote.velocityRange
        let span = Double(range.upperBound - range.lowerBound)
        let value = Double(range.lowerBound) + (fromBottom * span).rounded()
        return Int(value).clamped(to: range)
    }
}

/// One pad, as the view draws it and the seam reports it.
///
/// ⭐ **A VALUE, NOT A VIEW-MODEL REFERENCE.** The grid takes `[PadState]` by
/// value, so a SwiftUI preview, a unit test and the running app all render the
/// identical surface from identical inputs (the Components rule).
public struct PadState: Equatable, Sendable, Identifiable {
    /// 0-based index INSIDE THE CURRENT BANK, 0…15. `id` for the view.
    public let id: Int
    /// The MIDI note this pad fires, or nil when the bank runs past MIDI 127.
    public let pitch: Int?
    /// Human note name for `pitch` ("C1"), or "—" when there is none.
    public let noteName: String
    /// The letter key that drums it, or nil for the pads no key reaches (never,
    /// at 16 pads and 17 note keys — kept optional so a future 4×8 cannot
    /// fabricate a legend).
    public let keyLabel: String?
    /// Does a sampler zone answer this note?
    public let isLoaded: Bool
    /// Is it sounding RIGHT NOW? Read from the controller's `soundingPitches`,
    /// never from "was clicked" — a lit pad always means audible sound, the law
    /// `soundingPitches` itself is named for.
    public let isPlaying: Bool
    /// 1-based ordinal of the slice this pad holds among ALL loaded pads
    /// ("slice 7"), or nil when the pad is empty. ⚠️ Counted over the whole
    /// keymap, not the bank, so bank 2's first pad reads "slice 17" and not
    /// "slice 1".
    public let sliceOrdinal: Int?
    /// Where this pad's slice starts in the source file, in FRAMES — the unit
    /// `SamplerZone` actually stores.
    ///
    /// ⚠️ **FRAMES, AND SECONDS ARE DELIBERATELY ABSENT.** Converting needs the
    /// file's sample rate, and reading that means main-actor file I/O on a
    /// surface that redraws — the exact cost the m26-i ruling refused for the
    /// sampler card's loop points. The view shows a position BAR (frames as a
    /// fraction of the loaded span, which needs no rate) rather than a
    /// fabricated "0:02.4".
    public let startFrame: Int?
    /// Was this pad's audio produced by AI? Violet, always.
    public let isAITouched: Bool

    public init(id: Int, pitch: Int?, noteName: String, keyLabel: String?,
                isLoaded: Bool, isPlaying: Bool, sliceOrdinal: Int?,
                startFrame: Int?, isAITouched: Bool) {
        self.id = id
        self.pitch = pitch
        self.noteName = noteName
        self.keyLabel = keyLabel
        self.isLoaded = isLoaded
        self.isPlaying = isPlaying
        self.sliceOrdinal = sliceOrdinal
        self.startFrame = startFrame
        self.isAITouched = isAITouched
    }

    /// Where this pad is drawn on screen.
    public var square: (displayRow: Int, column: Int)? {
        PadGridGeometry.square(forPad: id)
    }
}
