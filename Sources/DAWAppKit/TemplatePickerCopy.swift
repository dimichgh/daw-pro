import Foundation
import DAWCore

// m39-tpl-8 — EVERY WORD THE TEMPLATE PICKER SAYS, in one home
// (docs/design/2026-09-27-multi-instrument-templates.md §9.2, §9.3).
//
// The card, the Save as Template card, the menu items and the fading notice all
// read their words from here, and `TemplatePickerModelTests` reads the same
// constants, so a test can never pass against a sentence the screen does not
// show. ⚠️ A REFUSAL IS NEVER WRITTEN HERE: the store's own `errorDescription`
// is shown verbatim (the wire sends exactly that text, `Commands.swift`'s
// `LocalizedError` catch), so a person and an agent read one sentence.

/// The picker's words. Plain, active voice, never naming the person.
public enum TemplatePickerCopy {
    // MARK: The card (§9.2)

    public static let title = "Start with a band"
    public static let subtitle = "Pick a sound to start from. You can change every part later."

    public static let startSongTitle = "Start a song"
    public static let startSongExplanation = "Adds this band and a song outline: tempo, sections and a loop."
    public static let addToSongTitle = "Add to my song"
    public static let addToSongExplanation = "Adds these tracks. Nothing you already have changes."

    // MARK: Pro (§9.2)

    public static let builtInTab = "Built-in"
    public static let savedTab = "My Templates"
    public static let importButton = "Import…"
    public static let exportButton = "Export…"
    public static let removeButton = "Remove"
    public static let saveAsTemplateButton = "Save as Template…"
    public static let detailHeader = "WHAT YOU GET"
    public static let noSavedTemplates =
        "No saved templates yet. Save as Template… keeps the tracks you choose, with their sounds, effects and routing."

    // MARK: The menu items (§9.1)

    /// The add-track (+) menu's item.
    public static let addBandMenuItem = "Add a Band from a Template…"
    /// The track-header menu's item. NOT "Save Selected Tracks…" (§9.1's wording):
    /// this app has no track selection — a header click moves a cursor and selects
    /// clips (`ArrangeTrackSelection`'s banner) — so the item names the track it is
    /// on, and the card it opens lets you tick more.
    public static let saveTrackMenuItem = "Save Track as Template…"

    // MARK: States the card must show (§9.3)

    /// While recording, a template that connects its tracks (§9.3, verbatim).
    public static let stopRecording = "Stop recording to add this band."
    /// Nothing selected — only reachable when no template can be read at all.
    public static let pickOne = "Pick a band first."
    public static let songStyleLabel = "Song style"

    /// §9.3 for a song that already has tracks. ⚠️ When the song is ALREADY at
    /// the style's tempo the tempo half would be false, so it is dropped — a
    /// sentence names what the press does now, not what it did in the example.
    public static func startSongAlsoChanges(tempoBPM: Double, currentTempoBPM: Double) -> String {
        if abs(tempoBPM - currentTempoBPM) < 0.0005 {
            return "This also adds song sections and a loop. Your tracks stay."
        }
        return "This also sets the tempo to \(bpm(tempoBPM)) BPM and adds song sections and a loop. Your "
            + "tracks stay. Notes will play at the new speed, and recordings may no longer line up with the beat."
    }

    /// §9.3: a plug-in that is installed.
    public static func usesPlugIn(_ name: String) -> String {
        "Uses a plug-in: \(name). Plug-ins can take a while to load."
    }

    /// §9.3: a plug-in this Mac does not have (the store's dry run says which).
    public static func plugInMissing(_ name: String) -> String {
        "\(name) isn't installed on this Mac. The track will be added without its sound."
    }

    // MARK: Tiles

    public static func trackCount(_ count: Int) -> String {
        count == 1 ? "1 track" : "\(count) tracks"
    }

    /// The tile's line for a file that could not be read: its own words come
    /// from the library (`TemplateLibrary.Unreadable.message`), shown verbatim.
    public static let unreadableTitle = "Can't be opened"

    // MARK: The fading notice (§9.2)

    public static let emptyTracksTail =
        "The tracks are empty: add notes, record, or ask the Copilot to write a part. Press ⌘Z to undo."

    /// After "Add to my song" lands (§9.2's sentence, verbatim for one template).
    public static func addedNotice(name: String, trackCount: Int) -> String {
        "Added \(name): \(self.trackCount(trackCount)). \(emptyTracksTail)"
    }

    /// After "Start a song" lands: §9.2's sentence, naming the song outline too —
    /// the press also set the tempo and added sections and a loop, and a notice
    /// that only counted tracks would leave that out.
    public static func startedNotice(name: String, trackCount: Int, tempoBPM: Double) -> String {
        "Added \(name): \(self.trackCount(trackCount)), and a song outline at \(bpm(tempoBPM)) BPM. "
            + emptyTracksTail
    }

    // MARK: Save as Template (§7.2)

    public static let saveTitle = "Save as Template"
    public static let saveSubtitle =
        "Keeps the chosen tracks' sounds, effects and routing. Notes and recordings are not saved."
    public static let saveNameLabel = "NAME"
    public static let saveNamePlaceholder = "My Band"
    public static let saveTracksLabel = "TRACKS"
    public static let saveBusNote = "A bus these tracks play into is saved with them."
    public static let saveButton = "Save Template"
    public static let saveCancel = "Cancel"
    public static let saveNeedsName = "Give the template a name."
    public static let saveNeedsTrack = "Choose at least one track."
    public static let saveNoTracksInSong = "This song has no tracks to save yet."

    public static func savedNotice(name: String, trackCount: Int) -> String {
        "Saved \"\(name)\": \(self.trackCount(trackCount)). Find it under My Templates in "
            + "\(addBandMenuItem)"
    }

    public static func exportedLine(path: String) -> String { "Exported to \(path)." }
    public static func importedLine(name: String) -> String { "Added \"\(name)\" to My Templates." }
    public static func removeConfirm(name: String) -> String {
        "Remove \"\(name)\"? This deletes its file, and Undo can't bring it back."
    }
    public static let removeConfirmButton = "Remove for Good"
    public static let removeKeepButton = "Keep"
    public static func removedLine(name: String) -> String { "Removed \"\(name)\"." }

    // MARK: Pro detail lines (§9.2: "Keys: Electric Piano. Plays into Keys Duck. Sends to Tape Room.")

    /// One line per track, in the template's order.
    public static func detailLines(for template: TrackSetTemplate) -> [String] {
        let names = Dictionary(template.tracks.map { ($0.key, $0.name) }, uniquingKeysWith: { first, _ in first })
        return template.tracks.map { track in
            var line: String
            switch track.kind {
            case .instrument:
                line = "\(track.name): \(InstrumentPickerModel.displayName(for: track.instrument))."
            case .audio:
                line = "\(track.name): an audio track, for recording."
            case .bus:
                let feeders = template.tracks.filter { other in
                    other.output == track.key || other.sends.contains { $0.bus == track.key }
                }.map(\.name)
                line = feeders.isEmpty
                    ? "\(track.name): a shared bus."
                    : "\(track.name): a shared bus that \(list(feeders)) \(feeders.count == 1 ? "plays" : "play") into."
                let keys = track.inserts.compactMap(\.sidechainSource).compactMap { names[$0] }
                if let source = keys.first {
                    line += " It ducks when \(source) plays."
                }
            }
            if let output = track.output, let bus = names[output] {
                line += " Plays into \(bus)."
            }
            let sends = track.sends.compactMap { names[$0.bus] }
            if !sends.isEmpty {
                line += " Sends to \(list(sends))."
            }
            return line
        }
    }

    // MARK: Helpers

    /// "90" for a whole tempo, "92.5" otherwise.
    public static func bpm(_ value: Double) -> String {
        if value.rounded() == value { return String(Int(value)) }
        return String(format: "%.1f", value)
    }

    /// "A", "A and B", "A, B and C".
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}

/// The small instrument glyph a tile draws per track (§9.2: "a row of small
/// instrument glyphs"). Decided headless from the template's own data; the view
/// only maps it to `systemImage`. Every symbol name is checked to exist by
/// `TemplatePickerModelTests` (an unknown SF Symbol name draws NOTHING, silently).
public enum TemplateTrackGlyph: String, Sendable, CaseIterable, Equatable {
    case drums, bass, keys, guitar, strings, winds, synth, voice, audio, plugIn, instrument

    public var systemImage: String {
        switch self {
        case .drums: return "metronome"
        case .bass: return "guitars"
        case .keys: return "pianokeys"
        case .guitar: return "guitars"
        case .strings: return "tuningfork"
        case .winds: return "wind"
        case .synth: return "dial.medium"
        case .voice: return "music.mic"
        case .audio: return "waveform"
        case .plugIn: return "puzzlepiece.extension"
        case .instrument: return "music.note"
        }
    }

    /// The glyph for one track, or nil for a bus (a bus is not an instrument).
    public static func glyph(for track: TemplateTrack) -> TemplateTrackGlyph? {
        switch track.kind {
        case .bus:
            return nil
        case .audio:
            let name = track.name.lowercased()
            return ["vocal", "vox", "voice", "sing"].contains { name.contains($0) } ? .voice : .audio
        case .instrument:
            guard let instrument = track.instrument else { return .synth }  // the default is the Poly Synth
            switch instrument.kind {
            case .drumSynth: return .drums
            case .polySynth: return .synth
            case .audioUnit: return .plugIn
            case .sampler, .testTone: return .instrument
            case .soundBank:
                guard let bank = instrument.soundBank else { return .instrument }
                if bank.bankMSB == GMProgramCatalog.percussionBankMSB { return .drums }
                switch bank.program / 8 {
                case 0, 1, 2: return .keys          // piano, chromatic percussion, organ
                case 3: return .guitar
                case 4: return .bass
                case 5, 6: return .strings          // strings, ensemble
                case 7, 8, 9: return .winds         // brass, reed, pipe
                case 10, 11, 12: return .synth
                case 14: return .drums              // percussive
                default: return .instrument
                }
            }
        }
    }
}
