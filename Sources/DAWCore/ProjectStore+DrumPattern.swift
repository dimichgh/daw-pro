import Foundation

// m39-w4-10 — write a ready-made drum beat onto a drum track, as ONE new MIDI clip
// (design `docs/design/2026-10-07-loop-drum-depth.md` §8). The wire verb is
// `clip.addDrumPattern`; the patterns are `DrumPatternLibrary`.
//
// ONE UNDO STEP: every check runs first and throws before anything changes; the
// clip is then made by the existing `addMIDIClip` funnel, which journals exactly
// one edit ("Add MIDI Clip '<pattern name>'").
//
// ⛔ OVERLAP: REFUSED, NOT TRIMMED. `addMIDIClip` resolves a landing over another
// clip by trimming or deleting that clip (the m13-b choke point). A beat dropped
// with an `atBeat` that lands on the user's own clip would therefore cut that
// clip silently. This verb follows `clip.addAudio` (m33-j) instead: the collision
// is made by THIS call, so it refuses, names the clip in the way, and says where
// the beat would fit. Omitting `atBeat` appends after the last clip (on the next
// bar line), which cannot collide. The oracle is `resolvingOverlaps` itself, as
// in `importAudio`, so takes (which stack legally) never trigger the refusal.
//
// ⛔ METER: the patterns are written in 4 beats to the bar. In a song (or the part
// of a song) with any other number of beats to the bar the beat would cross the
// bar lines and sound wrong while looking right, so it is refused with a sentence.

/// What `ProjectStore.addDrumPattern` wrote.
public struct DrumPatternWriteResult: Sendable, Equatable {
    /// The new clip, as stored.
    public let clip: Clip
    /// The pattern that was written.
    public let pattern: DrumPattern
    /// How many bars the clip holds.
    public let bars: Int
    /// The drums written, with their notes and hit counts, in `DrumVoice` order.
    public let written: [DrumPatternRoleUse]
    /// The drums this kit lacks, left out, in `DrumVoice` order.
    public let leftOut: [DrumPatternRoleUse]
    /// Plain sentences about anything the caller should know (a drum left out,
    /// a start that is not on a bar line). Empty on the ordinary path.
    public let warnings: [String]
}

/// Why a drum beat was not written. Every message is a sentence a beginner can
/// act on; the wire surfaces it verbatim.
public enum DrumPatternError: Error, LocalizedError {
    case unknownPattern(String)
    case barsOutOfRange(Int)
    case notAnInstrumentTrack(trackName: String, kind: TrackKind)
    case notADrumTrack(trackName: String, kind: InstrumentDescriptor.Kind)
    case meterNotFourBeats(beatsPerBar: Int, beatUnit: Int, atBeat: Double)
    case nothingToPlay(missing: [DrumVoice])
    case wouldOverlap(existingID: UUID, existingName: String, appendBeat: Double)

    public var errorDescription: String? {
        switch self {
        case .unknownPattern(let name):
            let all = DrumPatternLibrary.patterns.map { "\($0.name) (\($0.id))" }.joined(separator: ", ")
            return "There is no drum beat called '\(name)'. The beats are: \(all)."
        case .barsOutOfRange(let bars):
            return "A drum beat can fill \(DrumPatternLibrary.barsRange.lowerBound) to "
                + "\(DrumPatternLibrary.barsRange.upperBound) bars; \(bars) is outside that."
        case .notAnInstrumentTrack(let name, let kind):
            let what = kind == .bus ? "a bus" : "an audio track"
            return "'\(name)' is \(what), so it cannot hold a drum beat. Add the beat to an instrument "
                + "track that plays drums."
        case .notADrumTrack(let name, let kind):
            return "'\(name)' \(Self.plays(kind)), so a drum beat has nothing to play. Add the beat to a "
                + "drum track (the Drum Machine, a drum kit, or a sample sorted into a kit), or switch "
                + "this track to the Drum Machine first."
        case .meterNotFourBeats(let beatsPerBar, let beatUnit, let atBeat):
            return "These drum beats are written for 4 beats to a bar, but the song is in "
                + "\(beatsPerBar)/\(beatUnit) at beat \(formatPatternBeat(atBeat)), so the beat would "
                + "not line up with the bars. Nothing was added. Place it where the song is in 4/4, or "
                + "change the time signature there first."
        case .nothingToPlay(let missing):
            let names = missing.map(\.displayName)
            return "This kit has none of the drums this beat uses (\(Self.listed(names))), so nothing was "
                + "added. Pick a beat that uses the drums this kit has."
        case .wouldOverlap(let existingID, let existingName, let appendBeat):
            return "The beat would land on top of the clip '\(existingName)' (\(existingID.uuidString)) "
                + "on this track, and adding it there would cut that clip, so nothing was added. Leave "
                + "'atBeat' out to add the beat after the last clip (it would start at beat "
                + "\(formatPatternBeat(appendBeat))), choose a free spot, or move that clip first."
        }
    }

    /// What a non-drum instrument is, in words.
    static func plays(_ kind: InstrumentDescriptor.Kind) -> String {
        switch kind {
        case .testTone: return "plays a test tone, not drums"
        case .polySynth: return "plays the Poly Synth, not drums"
        case .sampler:
            return "plays the Sampler, and none of its pads is marked as a drum (kick, snare, hi-hat), "
                + "so the beat cannot tell which pad plays which drum"
        case .audioUnit:
            return "plays a plug-in instrument, and DAW Pro cannot tell which of its keys play which drum"
        case .soundBank: return "plays a sound bank instrument, not its drum kit"
        case .drumSynth: return "plays the Drum Machine"
        }
    }

    /// "A", "A and B", "A, B and C".
    static func listed(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
    }
}

extension ProjectStore {

    /// Writes the drum beat `patternName` onto the drum track `id` as one new
    /// MIDI clip: ONE undo step.
    ///
    /// - `bars`: how many bars to fill (1...64); nil writes the pattern's own
    ///   length (1 or 2 bars). Longer repeats it; shorter stops at a bar line.
    /// - `atBeat`: where the clip starts; nil appends after the track's last clip,
    ///   on the next bar line.
    ///
    /// Refuses, before changing anything: an unknown pattern, a track that is not
    /// a drum track, a song that is not 4 beats to the bar where the beat would
    /// go, a kit that has none of the beat's drums, and a landing on another clip.
    @discardableResult
    public func addDrumPattern(named patternName: String, toTrack id: UUID,
                               bars requestedBars: Int? = nil,
                               atBeat: Double? = nil) throws -> DrumPatternWriteResult {
        guard let pattern = DrumPatternLibrary.pattern(named: patternName) else {
            throw DrumPatternError.unknownPattern(patternName)
        }
        guard let index = tracks.firstIndex(where: { $0.id == id }) else {
            throw ProjectError.trackNotFound(id)
        }
        let track = tracks[index]
        guard track.kind == .instrument else {
            throw DrumPatternError.notAnInstrumentTrack(trackName: track.name, kind: track.kind)
        }
        let instrument = track.instrument ?? .default
        guard let roleNotes = DrumPatternLibrary.roleNotes(for: instrument) else {
            throw DrumPatternError.notADrumTrack(trackName: track.name, kind: instrument.kind)
        }
        let bars = requestedBars ?? pattern.bars
        guard DrumPatternLibrary.barsRange.contains(bars) else {
            throw DrumPatternError.barsOutOfRange(bars)
        }

        let meter = transport.meterMap
        let lastEnd = track.clips.map { $0.startBeat + $0.lengthBeats }.max() ?? 0
        let appendBeat = Self.drumPatternBarline(atOrAfter: lastEnd, meter: meter)
        let start = max(0, atBeat ?? appendBeat)
        let length = Double(bars * DrumPatternLibrary.beatsPerBar)
        if let problem = Self.drumPatternMeterProblem(meter, from: start, to: start + length) {
            throw DrumPatternError.meterNotFourBeats(beatsPerBar: problem.beatsPerBar,
                                                     beatUnit: problem.beatUnit, atBeat: problem.atBeat)
        }

        let built = DrumPatternLibrary.notes(for: pattern, bars: bars, roleNotes: roleNotes)
        guard !built.notes.isEmpty else {
            throw DrumPatternError.nothingToPlay(missing: built.leftOut.map(\.role))
        }

        // m33-j: the collision is made by this call, so refuse rather than trim.
        let resolved = Self.resolvingOverlaps(in: track.clips, activeIDs: [],
                                              start: start, end: start + length,
                                              tempoMap: transport.tempoMap)
        let touched = Set(resolved.trimmedIDs + resolved.removedIDs)
        if let resident = track.clips.first(where: { touched.contains($0.id) }) {
            throw DrumPatternError.wouldOverlap(existingID: resident.id, existingName: resident.name,
                                                appendBeat: appendBeat)
        }

        var warnings = built.leftOut.map(DrumPatternLibrary.leftOutSentence)
        if let offBar = Self.drumPatternOffBarSentence(start: start, meter: meter) {
            warnings.append(offBar)
        }
        let clip = try addMIDIClip(toTrack: id, name: pattern.name, atBeat: start,
                                   lengthBeats: length, notes: built.notes)
        return DrumPatternWriteResult(clip: clip, pattern: pattern, bars: bars, written: built.written,
                                      leftOut: built.leftOut, warnings: warnings)
    }

    /// The first bar line at or after `beat` (a beat already on one stays).
    static func drumPatternBarline(atOrAfter beat: Double, meter: MeterMap) -> Double {
        guard beat > 0 else { return 0 }
        let (bar, beatInBar) = meter.barBeat(atBeat: beat)
        return beatInBar < 1e-9 ? meter.beat(ofBar: bar) : meter.beat(ofBar: bar + 1)
    }

    /// The first meter that is not 4 beats to the bar anywhere in [start, end),
    /// or nil when the whole span is in 4.
    static func drumPatternMeterProblem(_ meter: MeterMap, from start: Double, to end: Double)
        -> (beatsPerBar: Int, beatUnit: Int, atBeat: Double)? {
        let changes = meter.changes
        for (i, change) in changes.enumerated() {
            let segmentStart = i == 0 ? -Double.infinity : change.startBeat
            let segmentEnd = i + 1 < changes.count ? changes[i + 1].startBeat : Double.infinity
            guard segmentStart < end, segmentEnd > start else { continue }
            if change.beatsPerBar != DrumPatternLibrary.beatsPerBar {
                return (change.beatsPerBar, change.beatUnit, max(start, change.startBeat))
            }
        }
        return nil
    }

    /// A warning when the beat starts partway through a bar, so its beat 1 is
    /// not the song's. nil on a bar line.
    static func drumPatternOffBarSentence(start: Double, meter: MeterMap) -> String? {
        let (bar, beatInBar) = meter.barBeat(atBeat: start)
        guard beatInBar >= 1e-9 else { return nil }
        let before = meter.beat(ofBar: bar)
        let after = meter.beat(ofBar: bar + 1)
        return "The beat starts at beat \(formatPatternBeat(start)), partway through bar \(bar + 1), so its "
            + "first beat does not land on the start of a bar. The nearest bar lines are beats "
            + "\(formatPatternBeat(before)) and \(formatPatternBeat(after))."
    }
}

/// A beat for a message, without a trailing `.0` on a whole beat (the file-private
/// `formatImportBeat` precedent: each refusal keeps its own copy).
private func formatPatternBeat(_ beat: Double) -> String {
    beat == beat.rounded() && abs(beat) < 1e15
        ? String(Int(beat.rounded()))
        : String(format: "%g", beat)
}

// MARK: - "Start from a beat": fill an EMPTY clip (m39-w4-10 UI)
//
// The step grid's menu on an empty drum clip (design §8, last bullet). It fills
// the clip the user already has open, so `addDrumPattern` (which makes a NEW
// clip and refuses to land on one) is the wrong funnel. The drums resolve
// exactly as that verb resolves them (`DrumPatternLibrary.roleNotes(for:)`, the
// track's own instrument), so the same beat on the same kit writes the same
// notes either way (`StartFromABeatStoreTests`, twin-track equality).
//
// ⛔ ONE UNDO STEP THAT NEVER FOLDS INTO A NOTE EDIT. The write is one
// `performEdit` with NO coalescing key, the `pasteNotes` rule. `setClipNotes`
// journals under `clip.notes:<id>` and folds same-key edits inside 800 ms, so a
// beat picked right after the last step was clicked off would join that click
// and one ⌘Z would bring the old step back instead of emptying the clip.
//
// ⛔ ONLY AN EMPTY CLIP. A clip that holds any note (latent ones past its end
// included) is refused, so nothing the user wrote is ever mixed into or lost.
//
// ⭐ HOW MANY BARS: the clip's own length. A longer clip repeats the beat from
// its first bar; a shorter one cuts it at a bar line (a two-bar beat in a
// one-bar clip keeps bar 1). A clip that ends partway through a bar is filled
// up to its end: a hit at or past the end is not written, because it would
// never sound. The beat starts on the clip's first beat; a clip that starts
// partway through a bar gets the off-bar warning `addDrumPattern` gives.
//
// The wire reaches this through `clip.addDrumPattern {clipId}` (MCP
// `clip_add_drum_pattern` with `clipId`), count-neutral — W9-PATF.

/// What `ProjectStore.fillDrumPattern` wrote into an empty clip.
public struct DrumPatternFillResult: Sendable, Equatable {
    /// The clip, as stored after the fill.
    public let clip: Clip
    /// The beat that was written.
    public let pattern: DrumPattern
    /// How many bars the beat spans (the last one may be partial).
    public let bars: Int
    /// The drums written, with their notes and hit counts, in `DrumVoice` order.
    public let written: [DrumPatternRoleUse]
    /// The drums this kit lacks, left out, in `DrumVoice` order.
    public let leftOut: [DrumPatternRoleUse]
    /// Plain sentences about anything the person should know (a drum left out,
    /// a clip that starts partway through a bar). Empty on the ordinary path.
    public let warnings: [String]

    public init(clip: Clip, pattern: DrumPattern, bars: Int, written: [DrumPatternRoleUse],
                leftOut: [DrumPatternRoleUse], warnings: [String]) {
        self.clip = clip
        self.pattern = pattern
        self.bars = bars
        self.written = written
        self.leftOut = leftOut
        self.warnings = warnings
    }

    /// One plain sentence: what was added, and on which drums.
    public var summary: String {
        let hits = written.reduce(0) { $0 + $1.hits }
        let drums = DrumPatternError.listed(written.map(\.role.displayName))
        return "Added the \(pattern.name) beat: \(hits == 1 ? "1 hit" : "\(hits) hits") on \(drums)."
    }
}

/// Why "Start from a beat" wrote nothing, for the cases `DrumPatternError`'s
/// sentences do not fit (they talk about adding a NEW clip). Every message is a
/// sentence a beginner can act on.
public enum DrumPatternFillError: Error, LocalizedError, Equatable {
    case clipNotEmpty(clipName: String, noteCount: Int)
    case meterNotFourBeats(clipName: String, beatsPerBar: Int, beatUnit: Int, atBeat: Double)
    case clipTooShort(clipName: String)

    public var errorDescription: String? {
        switch self {
        case .clipNotEmpty(let name, let count):
            let notes = count == 1 ? "1 note" : "\(count) notes"
            return "'\(name)' already has \(notes). A ready-made beat only goes into an empty clip, so "
                + "nothing you wrote is changed. Nothing was added."
        case .meterNotFourBeats(let name, let beatsPerBar, let beatUnit, let atBeat):
            return "These drum beats are written for 4 beats to a bar, but '\(name)' is where the song is in "
                + "\(beatsPerBar)/\(beatUnit) (at beat \(formatPatternBeat(atBeat))), so the beat would not "
                + "line up with the bars. Nothing was added. Use a clip where the song is in 4/4, or change "
                + "the time signature there first."
        case .clipTooShort(let name):
            return "'\(name)' is too short to hold any of the beat's hits. Nothing was added. Make the clip "
                + "longer first."
        }
    }
}

extension ProjectStore {

    /// Writes the drum beat `patternName` into the EMPTY MIDI clip `clipID` on a
    /// drum track: ONE undo step ("Add Beat '<name>'"), never folded into a note
    /// edit. The beat fills the clip's own length (see the banner above).
    ///
    /// Refuses, before changing anything: an unknown beat, an unknown or audio
    /// clip, a take-comp member, a track that is not a drum track, a clip that
    /// already holds notes, a clip longer than 64 bars, a clip where the song is
    /// not 4 beats to the bar, and a kit with none of the beat's drums.
    @discardableResult
    public func fillDrumPattern(named patternName: String, intoClip clipID: UUID) throws -> DrumPatternFillResult {
        guard let pattern = DrumPatternLibrary.pattern(named: patternName) else {
            throw DrumPatternError.unknownPattern(patternName)
        }
        guard let t = tracks.firstIndex(where: { $0.clips.contains { $0.id == clipID } }),
              let c = tracks[t].clips.firstIndex(where: { $0.id == clipID }) else {
            throw ProjectError.clipNotFound(clipID)
        }
        let track = tracks[t]
        let clip = track.clips[c]
        guard let existing = clip.notes else {
            throw ProjectError.notAMIDIClip(clipID, verb: "Start from a beat")
        }
        try requireNotCompMember(trackIndex: t, clipIndex: c)
        guard track.kind == .instrument else {
            throw DrumPatternError.notAnInstrumentTrack(trackName: track.name, kind: track.kind)
        }
        let instrument = track.instrument ?? .default
        guard let roleNotes = DrumPatternLibrary.roleNotes(for: instrument) else {
            throw DrumPatternError.notADrumTrack(trackName: track.name, kind: instrument.kind)
        }
        guard existing.isEmpty else {
            throw DrumPatternFillError.clipNotEmpty(clipName: clip.name, noteCount: existing.count)
        }
        let length = clip.lengthBeats
        guard length > 0, length.isFinite else {
            throw DrumPatternFillError.clipTooShort(clipName: clip.name)
        }
        let bars = Int((length / Double(DrumPatternLibrary.beatsPerBar)).rounded(.up))
        guard DrumPatternLibrary.barsRange.contains(bars) else {
            throw DrumPatternError.barsOutOfRange(bars)
        }
        let meter = transport.meterMap
        if let problem = Self.drumPatternMeterProblem(meter, from: clip.startBeat, to: clip.startBeat + length) {
            throw DrumPatternFillError.meterNotFourBeats(clipName: clip.name, beatsPerBar: problem.beatsPerBar,
                                                         beatUnit: problem.beatUnit, atBeat: problem.atBeat)
        }

        let built = DrumPatternLibrary.notes(for: pattern, bars: bars, roleNotes: roleNotes, before: length)
        guard !built.notes.isEmpty else {
            if built.leftOut.isEmpty { throw DrumPatternFillError.clipTooShort(clipName: clip.name) }
            throw DrumPatternError.nothingToPlay(missing: built.leftOut.map(\.role))
        }

        var warnings = built.leftOut.map(DrumPatternLibrary.leftOutSentence)
        if let offBar = Self.drumPatternOffBarSentence(start: clip.startBeat, meter: meter) {
            warnings.append(offBar)
        }
        // The `setClipNotes` write, minus its coalescing key: re-clamped through
        // the clamping init, canonically ordered, the engine told inside the edit.
        let ordered = MIDINote.canonicallyOrdered(built.notes.map {
            MIDINote(id: $0.id, pitch: $0.pitch, velocity: $0.velocity,
                     startBeat: $0.startBeat, lengthBeats: $0.lengthBeats)
        })
        performEdit("Add Beat '\(pattern.name)'") {
            tracks[t].clips[c].notes = ordered
            engine?.tracksDidChange(tracks)
        }
        return DrumPatternFillResult(clip: tracks[t].clips[c], pattern: pattern, bars: bars,
                                     written: built.written, leftOut: built.leftOut, warnings: warnings)
    }
}
