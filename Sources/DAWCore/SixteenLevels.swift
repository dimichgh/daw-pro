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
//
// ═══ WHICH WAY THE SPREAD RUNS (m39-levels-2) — THE USER'S RULING ═══
//
// Offered on the handoff page 2026-09-20 (and unread for three days): keep it
// climbing, centre it, or *"let me choose per spread — a small up/centred toggle
// beside LEVELS."* They chose the toggle. So a spread runs one of two ways:
//
//   UP (the shipped behaviour, and still the default): pad 1 is the slice as
//   recorded, each pad up one semitone higher, the top pad +15.
//   CENTRED: pad 9 is the slice as recorded, pads 1–8 are −8…−1, pads 10–16 are
//   +1…+7 — the trade the card named: pitched-down versions, at the cost of
//   "pad 1 is the thing itself".
//
// ⭐⭐ **THE DIRECTION IS NOT A FLAG. IT IS THE SPREAD ZONE'S OWN `rootPitch`.**
// Both directions occupy the same sixteen keys `base…base+15`; they differ ONLY
// in which of those keys is the root — `base` for UP, `base + 8` for CENTRED.
// That makes three things true by construction rather than by care:
//  · **it persists with the spread.** `SamplerZoneDocument` already round-trips
//    root/min/max verbatim, so a saved-and-reopened project plays exactly the
//    same pitch on every key. No new field, no schema change, and — the point —
//    no SECOND copy of the fact that could come back disagreeing with the first.
//    A spread whose meaning silently changed on reload would be a lie, and the
//    only way to make that impossible is to have nothing to disagree with.
//  · **the labels cannot lie.** The pad grid derives each pad's "+3" from the
//    LIVE zone's root (`semitones(atPitch:on:)`), never from what the toggle
//    last said — so if a write bounced, or an agent moved the root over the
//    wire, the numbers still describe what the pads play.
//  · **flipping a live spread edits ONE zone, LEVELS' own**, and only its root
//    (`keymap(_:respreading:to:)`). The user's chop is untouched in both
//    directions and across any number of flips — the rule above, extended.
public enum SixteenLevels {

    /// Which way a spread runs. See the file header for the ruling.
    ///
    /// ⚠️ **`centered`, US spelling, IN CODE AND ON THE WIRE** — the house split
    /// (`PhaserParams.centerHz` in code, "Centre" on screen). The on-screen word
    /// is "CENTRED", the card's spelling, and lives with the other pad-grid words in
    /// `DAWAppKit`. The raw values are a future wire contract: never rename.
    public enum Direction: String, Codable, Sendable, CaseIterable {
        /// Pad 1 = the slice as recorded, +1 … +15 above it. THE DEFAULT — the
        /// behaviour that shipped, so nobody who never touches the toggle hears
        /// or sees anything change.
        case up
        /// Pad 9 = the slice as recorded, −8 … +7 around it.
        case centered

        /// The 0-based pad that plays the slice UNSHIFTED — the one pad whose
        /// label reads "0". Pad 1 for UP; pad 9 (index 8) for CENTRED.
        public var unshiftedPadIndex: Int {
            switch self {
            case .up: return 0
            // `span / 2`, not a literal 8: sixteen keys have no middle key, and
            // this picks the upper-middle one, which is what gives −8…+7 (more
            // room DOWN, the side UP could never reach).
            case .centered: return SixteenLevels.span / 2
            }
        }
    }

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

    /// The root a spread from `base` gets when it runs `direction` — `base` for
    /// UP (pad 1 unshifted), `base + 8` for CENTRED (pad 9 unshifted). The ONE
    /// place the two directions differ.
    public static func rootPitch(base: Int, direction: Direction) -> Int {
        base + direction.unshiftedPadIndex
    }

    /// The spread zone: `source`'s audio, its slice window, its envelope — sounding
    /// across `span` keys from `base`.
    ///
    /// ⭐ **`direction` DECIDES ONLY `rootPitch`.** UP (the default, and the
    /// shipped behaviour): `rootPitch == base`, so PAD 1 IS THE SLICE AS
    /// RECORDED and each pad up is one semitone higher. CENTRED:
    /// `rootPitch == base + 8`, so pad 9 is the slice as recorded and pads 1–8
    /// play it LOWER — the downward pitch the user chose to have on the grid
    /// rather than only on the sampler card's per-zone **Tune** knob. The keys
    /// the spread occupies are identical either way, so `freeBase` never has
    /// to know which way it runs.
    ///
    /// ⚠️ **`loopMode` IS DELIBERATELY NOT CARRIED.** A looping voice is never
    /// one-shot (the engine's `if voice.looping { voice.oneShotOverride = 0 }`
    /// rule), so a looped source would produce a spread that ignores the grid's
    /// own LET GO switch — a control silently overruled by a field copied
    /// without thinking about it.
    ///
    /// ⚠️ A FRESH `id`. Copying the struct would carry the source's identity,
    /// and then removing the spread on exit would take the slice with it.
    public static func zone(from source: SamplerZone, base: Int,
                            direction: Direction = .up) -> SamplerZone {
        SamplerZone(
            audioFileURL: source.audioFileURL,
            rootPitch: rootPitch(base: base, direction: direction),
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

    /// Semitones from the recording that a pad of a spread running `direction`
    /// plays. UP: pad 1 → 0 … pad 16 → +15. CENTRED: pad 1 → −8, pad 9 → 0,
    /// pad 16 → +7. ⚠️ Pad INDEX, which is already in MPC order, so this needs
    /// no second copy of the bottom-left inversion.
    ///
    /// This is the CONTRACT — what each direction promises. The grid does not
    /// draw from it; it draws from the live zone through `semitones(atPitch:on:)`,
    /// and `SixteenLevelsTests` pins the two to agree on every pad.
    public static func semitones(forPad padIndex: Int, direction: Direction = .up) -> Int? {
        (0..<span).contains(padIndex) ? padIndex - direction.unshiftedPadIndex : nil
    }

    /// What `pitch` plays on `zone`, in semitones from the recording — the
    /// engine's own transposition (`pitch − rootPitch`), or nil when the zone
    /// does not answer that key.
    ///
    /// ⭐ **THE GRID'S LABELS COME FROM HERE, NOT FROM THE TOGGLE.** Read off
    /// the zone the engine actually plays, a label cannot describe a direction
    /// the zone does not have — a refused write, a reload, or an agent moving
    /// the root over the wire all leave the numbers true.
    public static func semitones(atPitch pitch: Int, on zone: SamplerZone) -> Int? {
        (zone.minPitch...zone.maxPitch).contains(pitch) ? pitch - zone.rootPitch : nil
    }

    /// The direction a zone ENCODES, read off its own geometry, or nil when it
    /// is not spread-shaped (not exactly `span` keys wide, or rooted anywhere
    /// but pad 1 or pad 9).
    ///
    /// ⭐ This is what "the direction persists with the spread" means in code:
    /// there is no stored flag to reload, because the zone IS the record.
    public static func direction(of zone: SamplerZone) -> Direction? {
        guard zone.maxPitch - zone.minPitch + 1 == span else { return nil }
        return Direction.allCases.first {
            zone.rootPitch == rootPitch(base: zone.minPitch, direction: $0)
        }
    }

    /// Is `zone` a spread? **THE ONE PREDICATE** (m39-levels-3) — literally
    /// `direction(of:) != nil`, named so the pad grid, the store and the wire
    /// cannot grow three ideas of "is a spread". `setSixteenLevelsDirection`
    /// refuses what this refuses; `instrument.describeSampler` reports
    /// `spreadDirection` off the same function; the grid keeps every zone this
    /// accepts out of its slice numbering and its slice count.
    ///
    /// ⛔ **WHY SHAPE AND NOT A SAVED MARKER.** The grid used to know a spread
    /// only through its own session (`PadGridModel`'s remembered zone id), so a
    /// relaunch — or a spread made over the wire — left the spread numbered as
    /// slice 1 and the whole chop shifted one up. A new saved flag would not
    /// have repaired a project ALREADY saved during LEVELS (absence would read
    /// as "not a spread"), and it would be a second record of a fact the zone
    /// already carries.
    ///
    /// ⚠️ **SHAPE IS NOT PROVENANCE, AND THE GAP IS REAL, NOT THEORETICAL.** A
    /// zone nobody made with LEVELS reads as a spread if it happens to be exactly
    /// sixteen keys wide and rooted on its first or ninth key. That is reachable:
    /// `SampleLibraryMapper` maps SFZ `lokey`/`hikey` verbatim and defaults a
    /// missing `pitch_keycenter` to 60, so `lokey=52 hikey=67` reads CENTRED and
    /// `lokey=60 hikey=75` reads UP; `instrument.setSamplerZones` and the
    /// sampler card can build one by hand. No in-tree fixture does (checked
    /// 2026-09-24). What such a zone costs: its pads read intervals instead of a
    /// slice number (true of a sixteen-key zone anyway — each pad plays a
    /// different pitch), and a person standing on it and pressing EXIT LEVELS
    /// removes it — one undo step. The store and the wire already carried the
    /// same gap before the grid joined them (`setSixteenLevelsDirection` will
    /// re-root such a zone).
    public static func isSpread(_ zone: SamplerZone) -> Bool {
        direction(of: zone) != nil
    }

    /// The slice `spread` was made from, found among `zones` by what it PLAYS —
    /// the same source file (`sourceFileKey`, the one "same file?" home) and the
    /// same frame window, which `zone(from:base:direction:)` copies verbatim —
    /// or nil when no slice matches.
    ///
    /// ⭐ **DERIVED, NEVER REMEMBERED.** A spread made by the pad grid, by the
    /// store, over the wire, or reopened from disk all answer through this one
    /// function, so a header naming "slice 3" cannot be true for a hand-made
    /// spread and false for the same spread after a relaunch. It survives a
    /// save: `ProjectBundle` relocates zone media keyed by `sourceFileKey`, so a
    /// spread and its source come back pointing at the SAME bundled file.
    ///
    /// ⚠️ nil is an honest answer and the caller must say so: the source slice
    /// was deleted, or its window was edited after the spread was made (the
    /// spread still plays the OLD window, so no current slice IS its source).
    /// Several matches — a slice duplicated by hand — resolve to the LOWEST in
    /// the grid's own numbering order (root pitch, then id), never to a guess.
    /// Spreads are never candidates: a spread is not a slice.
    public static func sourceSlice(of spread: SamplerZone,
                                   in zones: [SamplerZone]) -> SamplerZone? {
        zones.filter { candidate in
            candidate.id != spread.id && !isSpread(candidate)
                && candidate.sourceFileKey == spread.sourceFileKey
                && candidate.startFrame == spread.startFrame
                && candidate.endFrame == spread.endFrame
        }
        .min { a, b in
            a.rootPitch == b.rootPitch ? a.id.uuidString < b.id.uuidString
                                       : a.rootPitch < b.rootPitch
        }
    }

    /// `zones` with ONE zone — the spread `spreadZoneID` — re-pointed at
    /// `direction`, or nil when there is no such zone or it is not spread-shaped.
    ///
    /// ⛔⛔ **THE TOGGLE'S ONLY EDIT, AND IT TOUCHES ONE FIELD OF ONE ZONE.**
    /// Every other zone comes back as the SAME VALUE in the SAME ORDER, and the
    /// spread keeps its `id`, its keys, its audio, its window and any edit made
    /// to it on the sampler card; only `rootPitch` moves. The pad grid and the
    /// store both go through this one function, so neither can grow a second
    /// idea of what flipping a spread writes.
    ///
    /// ⚠️ nil for a zone that is not spread-shaped is a REFUSAL, not a
    /// convenience: a one-key slice named here by mistake must never be
    /// "re-rooted" — that would be editing the user's chop, which is the one
    /// thing this whole subsystem promises never to do.
    public static func keymap(_ zones: [SamplerZone], respreading spreadZoneID: UUID,
                              to direction: Direction) -> [SamplerZone]? {
        guard let spread = zones.first(where: { $0.id == spreadZoneID }),
              Self.direction(of: spread) != nil else { return nil }
        let root = rootPitch(base: spread.minPitch, direction: direction)
        return zones.map { zone in
            guard zone.id == spreadZoneID else { return zone }
            var moved = zone
            moved.rootPitch = root
            return moved
        }
    }

    /// "+3" / "0" / "-8" — what the pad draws in place of its slice number.
    public static func offsetLabel(semitones: Int) -> String {
        semitones == 0 ? "0" : (semitones > 0 ? "+\(semitones)" : "\(semitones)")
    }
}

/// Why a spread could not be made or moved, at the STORE — the refusals a wire
/// verb returns. Each sentence says what to do, not only what went wrong.
public enum SixteenLevelsError: Error, LocalizedError, Equatable, Sendable {
    /// The track exists but is not playing the built-in Sampler.
    case notASampler(trackName: String)
    /// No zone with that id on this track's sampler.
    case zoneNotFound(UUID)
    /// The zone exists but is not spread-shaped, so it was not made by LEVELS
    /// and will not be re-rooted.
    case notASpread(UUID)
    /// The keymap leaves no sixteen free keys anywhere.
    case noFreeWindow

    public var errorDescription: String? {
        switch self {
        case .notASampler(let name):
            return "“\(name)” is not playing the built-in Sampler, so it has no slices to spread."
        case .zoneNotFound(let id):
            return "No zone \(id.uuidString) on this sampler — read the zones with "
                + "instrument.describeSampler and pass one of theirs."
        case .notASpread(let id):
            return "Zone \(id.uuidString) is not a Sixteen Levels spread (a spread is exactly "
                + "\(SixteenLevels.span) keys wide, rooted on its first or ninth key), so its "
                + "direction was not changed — that would edit a zone the spread did not make."
        case .noFreeWindow:
            return "This kit fills the keyboard, so there is no room for a spread. Chop fewer "
                + "pieces, or move the chop up to free some low keys."
        }
    }
}

/// SIXTEEN LEVELS AT THE STORE — the model API a wire verb calls in ONE line.
///
/// ⭐ **NOT A SECOND IMPLEMENTATION.** Both methods build their keymap through
/// the same pure functions the pad grid uses (`zone(from:base:direction:)`,
/// `freeBase`, `keymap(_:respreading:to:)`) and write through
/// `setInstrument(id:sampler:)` — the one home the grid's own write reaches too
/// (`AppModel.padGridSetZones`). So a spread made over the wire and one made by
/// a hand on the pads are the same zone, and one undo step each.
///
/// ⚠️ The wire and MCP legs are DEFERRED (another lane holds `DAWControl` and
/// `mcp-server`). TODO(m39-levels-2 wire): `instrument.spreadSlice` →
/// `addSixteenLevelsSpread`, `instrument.setSpreadDirection` →
/// `setSixteenLevelsDirection`; MCP tools `instrument_spread_slice` and
/// `instrument_set_spread_direction`.
extension ProjectStore {

    /// Adds a spread of `sourceZoneID` running `direction`, at the first free
    /// sixteen-key window (`SixteenLevels.freeBase`), and returns the new zone.
    ///
    /// ⛔⛔ **ADDS ONE ZONE; EDITS NONE** — the keymap written is exactly
    /// `existing + [spread]`.
    @discardableResult
    public func addSixteenLevelsSpread(trackID: UUID, sourceZoneID: UUID,
                                       direction: SixteenLevels.Direction = .up) throws
        -> SamplerZone {
        var params = try sixteenLevelsSampler(trackID)
        guard let source = params.zones.first(where: { $0.id == sourceZoneID }) else {
            throw SixteenLevelsError.zoneNotFound(sourceZoneID)
        }
        guard let base = SixteenLevels.freeBase(zones: params.zones) else {
            throw SixteenLevelsError.noFreeWindow
        }
        let spread = SixteenLevels.zone(from: source, base: base, direction: direction)
        params.zones.append(spread)
        try setInstrument(id: trackID, sampler: params)
        return spread
    }

    /// Re-points the spread `spreadZoneID` at `direction` and returns it.
    ///
    /// ⛔⛔ **ONE FIELD OF ONE ZONE** — see `SixteenLevels.keymap(_:respreading:to:)`.
    /// A zone that is not spread-shaped is REFUSED (`notASpread`) rather than
    /// re-rooted. A no-op when it already runs that way: nothing is written and
    /// no undo step is spent.
    @discardableResult
    public func setSixteenLevelsDirection(trackID: UUID, spreadZoneID: UUID,
                                          direction: SixteenLevels.Direction) throws
        -> SamplerZone {
        var params = try sixteenLevelsSampler(trackID)
        guard let current = params.zones.first(where: { $0.id == spreadZoneID }) else {
            throw SixteenLevelsError.zoneNotFound(spreadZoneID)
        }
        guard let zones = SixteenLevels.keymap(params.zones, respreading: spreadZoneID,
                                               to: direction),
              let moved = zones.first(where: { $0.id == spreadZoneID }) else {
            throw SixteenLevelsError.notASpread(spreadZoneID)
        }
        guard moved != current else { return current }
        params.zones = zones
        try setInstrument(id: trackID, sampler: params)
        return moved
    }

    /// The track's sampler, or the named refusal. The same guard chain as the
    /// pad grid's `padGridSampler()`.
    private func sixteenLevelsSampler(_ trackID: UUID) throws -> SamplerParams {
        guard let track = tracks.first(where: { $0.id == trackID }) else {
            throw ProjectError.trackNotFound(trackID)
        }
        guard track.kind == .instrument, let instrument = track.instrument,
              instrument.kind == .sampler else {
            throw SixteenLevelsError.notASampler(trackName: track.name)
        }
        return instrument.resolvedSampler
    }
}
