import Foundation

// SIXTEEN LEVELS (m39-levels) — one slice spread chromatically across the grid.
//
// ═══ WHY IT IS NEEDED, MEASURED ON A USER ═══
//
// 2026-09-20, after their first successful chop: *"it does not increase pitch
// when it is moved on the note scale. Is it expected?"* It is, and the reason is
// one line in the chopper: every slice is written `minPitch == maxPitch ==
// rootPitch` (`SliceToSampler.swift:321`), one key wide. The engine transposes
// perfectly well — `baseIncrement = exp2((pitch − rootPitch) / 12)` — but a
// one-key zone has no pitch above its own root to reach, so walking up the
// keyboard walks onto the NEXT SLICE and past the last one onto silence.
//
// That default is right: *"A slice is a fragment of a record; letting it sound
// across a whole keyboard by default makes overlapping garbage on a chord."*
// Sixteen pads, sixteen sounds. The chopper's own comment names the escape
// hatch — *"Chromatic play is one `sampler.zonePatches` call away (widen
// maxPitch) — the '16 Levels' pattern"* — and nothing had ever been built on it.
//
// ═══ ⛔⛔ THE DESIGN RULE: ADD A ZONE, NEVER EDIT ONE ═══
//
// The obvious build is to widen the chosen slice's `maxPitch` in place, or to
// swap the whole keymap for sixteen transposed copies and remember the original
// in the view model. **Both are data-loss shapes.** The keymap is the only home
// of a chop — 90 slices of hand-placed boundaries — and a "remembered" original
// that lives in a view model is gone when the window closes, the track changes,
// or the app quits. The user would have a project that saved successfully and
// opened with their chop replaced by sixteen copies of slice 7.
//
// So LEVELS **adds one new zone at a pitch range no existing zone occupies** and
// moves the grid's base note there. Nothing that already exists is touched:
// - the chop plays on exactly as before, on its own notes
// - the reconstruction MIDI clip still triggers its own slices
// - leaving LEVELS removes the one added zone; quitting inside LEVELS loses
//   nothing, because nothing was taken away
//
// ⚠️ **The free window is the whole reason this is safe, so it is a decidable
// function with its own tests rather than a hard-coded octave.** A 90-slice chop
// based at 36 reaches note 125; "just put it above" would silently fall off the
// top of MIDI.
public enum SixteenLevels {

    /// Keys a LEVELS spread occupies — one grid, so the whole thing is reachable
    /// without paging.
    ///
    /// ⚠️ **THIS MUST EQUAL `PadGridGeometry.padsPerBank`, AND A TEST SAYS SO.**
    /// It cannot be derived from it: `PadGridGeometry` is `DAWAppKit` (a surface
    /// module) and this file is `DAWCore`, which is deliberately UI-free so the
    /// headless demo harness — `DemoRender`, DAWCore + DAWEngine only — can
    /// build the same spread the grid builds instead of hand-rolling a second
    /// copy of it for the render. `SixteenLevelsTests.spanTracksTheGrid` pins
    /// the two together across that boundary; a future 4×8 grid reddens there
    /// rather than silently spreading across half the pads.
    public static let span = 16

    /// Is every key of the window `base ..< base + span` free of existing zones?
    ///
    /// ⚠️ **OVERLAP, NOT CONTAINMENT.** A zone that merely CLIPS the window is
    /// still a collision: `SamplerZone` layers across groups and first-match
    /// wins within one, so a partial overlap produces pads that sometimes play
    /// the spread and sometimes play a slice — which is far worse to diagnose
    /// than pads that plainly do the wrong thing.
    public static func windowIsFree(base: Int, zones: [SamplerZone]) -> Bool {
        let range = SamplerZone.pitchRange
        guard base >= range.lowerBound, base + span - 1 <= range.upperBound else {
            return false
        }
        let top = base + span - 1
        return !zones.contains { $0.minPitch <= top && base <= $0.maxPitch }
    }

    /// Where to put the spread, or nil when the keymap leaves no room.
    ///
    /// ⭐ **PREFERS THE WINDOW DIRECTLY BELOW THE CHOP, THEN DIRECTLY ABOVE.**
    /// Not for tidiness: the spread and the slices it came from end up adjacent
    /// on the keyboard, so a MIDI part written against one is a short transpose
    /// from the other. Falling back to "the lowest window that fits" keeps this
    /// total rather than refusing over a keymap with an awkward hole in it.
    ///
    /// ⚠️ nil is a REAL answer and the caller must say so out loud. A 96-slice
    /// chop from note 32 leaves no sixteen free keys anywhere, and inventing a
    /// window by overlapping something would be the plausible-looking-valid-
    /// answer failure this whole subsystem is arranged against.
    public static func freeBase(zones: [SamplerZone]) -> Int? {
        let range = SamplerZone.pitchRange
        if let lowest = zones.map(\.minPitch).min(),
           windowIsFree(base: lowest - span, zones: zones) {
            return lowest - span
        }
        if let highest = zones.map(\.maxPitch).max(),
           windowIsFree(base: highest + 1, zones: zones) {
            return highest + 1
        }
        for base in range.lowerBound...(range.upperBound - span + 1)
        where windowIsFree(base: base, zones: zones) {
            return base
        }
        return nil
    }

    /// The spread zone: `source`'s audio, its slice window, its envelope — sounding
    /// across `span` keys from `base`.
    ///
    /// ⭐ **`rootPitch == base`, so PAD 1 IS THE SLICE AS RECORDED** and each pad
    /// up is one semitone higher. Centring the spread (pad 9 = original) would
    /// buy downward pitch and cost the one sentence that makes the mode
    /// self-explanatory; downward is already reachable, per-zone, on the sampler
    /// card's **Tune** knob (±4800 cents).
    ///
    /// ⚠️ **`loopMode` IS DELIBERATELY NOT CARRIED.** A looping voice is never
    /// one-shot (the engine's `if voice.looping { voice.oneShotOverride = 0 }`
    /// rule), so a looped source would produce a spread that ignores the grid's
    /// own LET GO switch — a control silently overruled by a field copied
    /// without thinking about it.
    ///
    /// ⚠️ A FRESH `id`. Copying the struct would carry the source's identity,
    /// and then removing the spread on exit would take the slice with it.
    public static func zone(from source: SamplerZone, base: Int) -> SamplerZone {
        SamplerZone(
            audioFileURL: source.audioFileURL,
            rootPitch: base,
            minPitch: base,
            maxPitch: base + span - 1,
            gain: source.gain,
            tuneCents: source.tuneCents,
            pan: source.pan,
            ampVelTrack: source.ampVelTrack,
            startFrame: source.startFrame,
            endFrame: source.endFrame,
            attack: source.attack,
            decay: source.decay,
            sustain: source.sustain,
            release: source.release,
            reverse: source.reverse)
    }

    /// Semitones above the source pitch that a pad of the spread plays.
    /// Pad 1 → 0. ⚠️ Pad INDEX, which is already in MPC order, so this needs no
    /// second copy of the bottom-left inversion.
    public static func semitones(forPad padIndex: Int) -> Int? {
        (0..<span).contains(padIndex) ? padIndex : nil
    }

    /// "+3" / "0" — what the pad draws in place of its slice number.
    public static func offsetLabel(semitones: Int) -> String {
        semitones == 0 ? "0" : (semitones > 0 ? "+\(semitones)" : "\(semitones)")
    }
}
