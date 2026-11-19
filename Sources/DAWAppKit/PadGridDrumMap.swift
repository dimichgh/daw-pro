import Foundation
import DAWCore

// m39-w4-8 — THE PAD GRID PLAYS THE DRUM MACHINE.
// `docs/design/2026-10-07-loop-drum-depth.md` §7 and §9 (`m39-w4-8`).
//
// ═══ WHY THIS FILE EXISTS ═══
//
// Before this item the pad grid was a SAMPLER surface: every pad played
// `padBaseNote + bank × 16 + index` and drew whatever sampler zone answered that
// note. Our drum machine has no zones, so its pads drew sixteen "Empty" squares
// over a kit that sounds — and in its `gm` note layout pad 2 sent note 37, which
// is the RIM, under a grid that would (once labelled) say "Snare". A picture
// that lies about what a click does.
//
// ═══ EVERYTHING HERE IS A PURE FUNCTION OF THE INSTRUMENT ═══
//
// The `PadGridGeometry` rule: no SwiftUI, no store, non-isolated, so its suite
// costs nothing against the `@MainActor` suite cap. `PadGridModel` (drawing and
// the mouse) and `MusicalTypingController` (the letter keys, through
// `padNoteMap`) both read the SAME answer from here, so a pad cannot be labelled
// one drum and play another.
//
// ⛔ NOT A SECOND NOTE MAP. Which note plays which drum has ONE home,
// `DrumVoice.voice(forNote:layout:)`, and which note a drum ROW writes has one
// home, `DrumLaneMap.lanes(for:)` (via `DrumVoice.primaryNote(in:)`). This file
// only decides WHERE ON THE GRID each lane sits: pad i is the voice whose render
// slot is i (`DrumVoice.voice(forSlot:)`), so the eight drums sit on pads 1–8 in
// either layout and Z X C V still put kick, snare, closed hat and open hat under
// the left hand (design §7).

/// One pad of a drum-machine target: the note it sends, the drum a beginner
/// reads on it, and the choke group that drum is in.
public struct PadDrum: Equatable, Sendable {
    /// The MIDI note this pad sends — the drum's lane note (`DrumLaneMap`).
    public let note: Int
    /// "Kick", "Open Hat" — `DrumVoice.displayName`, through the lane.
    public let label: String
    /// The drum machine voice the pad plays.
    public let voice: DrumVoice
    /// The voice's RESOLVED choke group (0…63), or nil for "cuts nothing".
    /// Read through `DrumVoiceParams.resolvedChokeGroup`, the same resolution
    /// the render applies at load, so the glyph follows what you will hear.
    public let chokeGroup: Int?

    public init(note: Int, label: String, voice: DrumVoice, chokeGroup: Int?) {
        self.note = note
        self.label = label
        self.voice = voice
        self.chokeGroup = chokeGroup
    }
}

/// The link between pads that cut each other off (a choke group) — what the
/// pad's small link glyph and its tooltip say.
///
/// ⛔ KEYED ON THE GROUP NUMBER, NEVER ON THE DRUM'S NAME. "Draw the link on
/// the two hats" would be right for the factory kit and wrong for every kit a
/// person or an agent has edited: clear the hat choke and the hats ring over
/// each other, put the clap and the rim in a group and they cut each other.
/// The glyph must follow the setting the render reads.
public struct PadChokeLink: Equatable, Sendable {
    /// The shared choke group, 0…63.
    public let group: Int
    /// The OTHER pads in the group, in the words their own pads show ("Open
    /// Hat", "slice 7"). Never empty: a pad alone in its group cuts nothing
    /// and gets no link at all.
    public let partners: [String]

    public init(group: Int, partners: [String]) {
        self.group = group
        self.partners = partners
    }

    /// The tooltip sentence, in plain words. "Linked with" names the glyph the
    /// pointer is over; the rest is the design's own sentence (§7).
    public var sentence: String {
        "Linked with \(PadGridDrumMap.list(partners)): these cut each other off, like a real hi-hat."
    }
}

public enum PadGridDrumMap {

    /// The drum machine's pads in PAD ORDER (pad 1 first), or nil when
    /// `instrument` is not our drum machine — the grid then keeps today's
    /// base-note arithmetic, untouched.
    ///
    /// Pad i plays the voice whose render slot is i (kick, snare, closed hat,
    /// open hat, clap, tom, rim, cymbal), at the note `DrumLaneMap` gives that
    /// voice for the kit's own layout: `pads` → 36 + i (exactly today's
    /// geometry at the default base), `gm` → 36, 38, 42, 46, 39, 45, 37, 49.
    ///
    /// ⚠️ nil if any voice has no lane — impossible today (`DrumLaneMap` lists
    /// every voice), and a half-built map would put drums on the wrong pads,
    /// so the whole map is withheld rather than shifted.
    public static func drumMachinePads(for instrument: InstrumentDescriptor?) -> [PadDrum]? {
        guard let instrument, instrument.kind == .drumSynth,
              let lanes = DrumLaneMap.lanes(for: instrument) else { return nil }
        let kit = instrument.resolvedDrumKit
        var pads: [PadDrum] = []
        for slot in 0..<Int32(DrumVoice.allCases.count) {
            guard let voice = DrumVoice.voice(forSlot: slot),
                  let lane = lanes.first(where: { $0.voice == voice }) else { return nil }
            let group = Int(kit[voice].resolvedChokeGroup)
            pads.append(PadDrum(note: lane.note, label: lane.label, voice: voice,
                                chokeGroup: group >= 0 ? group : nil))
        }
        return pads
    }

    /// A SAMPLER's drum names by note — what a kit-sorted chop (`mapping:
    /// "kit"`) shows on its pads: "Kick", "Kick 2", "Snare", "Other"…
    ///
    /// ⭐ THE STEP GRID'S OWN ROWS, NOT A SECOND LABELLER. `DrumLaneMap` builds
    /// a sampler's rows from its zones' `drumRole`; asking it about these zones
    /// is how a pad labelled X is guaranteed to be the row labelled X. Empty for
    /// a sampler no zone of which names a drum (every chromatic chop), so a
    /// plain chop draws exactly what it drew before this item.
    public static func samplerDrumLabels(zones: [SamplerZone]) -> [Int: String] {
        let probe = InstrumentDescriptor(kind: .sampler, sampler: SamplerParams(zones: zones))
        var labels: [Int: String] = [:]
        for lane in DrumLaneMap.lanes(for: probe) ?? [] where labels[lane.note] == nil {
            labels[lane.note] = lane.label
        }
        return labels
    }

    /// For each member, the choke link it shows, or nil. `groups[i]` is member
    /// i's choke group (nil = none), `names[i]` its name, `keys[i]` the note it
    /// answers. A member is linked with every OTHER member in its group that
    /// sits on a DIFFERENT note; one alone in its group (or sharing it only
    /// with layers on its own note) cuts nothing anyone can hear, and shows no
    /// link.
    public static func chokeLinks(groups: [Int?], names: [String], keys: [Int]) -> [PadChokeLink?] {
        groups.indices.map { i in
            guard let group = groups[i] else { return nil }
            var seen = Set<Int>()
            var partners: [String] = []
            for j in groups.indices where j != i && groups[j] == group && keys[j] != keys[i] {
                if seen.insert(keys[j]).inserted { partners.append(names[j]) }
            }
            return partners.isEmpty ? nil : PadChokeLink(group: group, partners: partners)
        }
    }

    /// "Open Hat", "Closed Hat and Open Hat", "Kick, Snare and Rim".
    static func list(_ names: [String]) -> String {
        guard let last = names.last else { return "" }
        guard names.count > 1 else { return last }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }
}
