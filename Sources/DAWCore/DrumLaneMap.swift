import Foundation

// m39-w4-2 — WHICH ROWS A DRUM INSTRUMENT HAS, in one home.
// `docs/design/2026-10-07-loop-drum-depth.md` §3.2–§3.3.
//
// Before this file the step grid asked ONE yes/no question
// (`SMFProjectExporter.isDrumKit`) and, on a yes, drew the 17 General MIDI
// percussion rows. Our own drum machine answers that question "no" in its
// default `pads` layout, so a new Drum Machine opened in the piano roll, and
// flipped to Steps its rows were C3–B4, which play nothing on a kit that only
// answers notes 36–43 (design C12–C14).
//
// ⛔ TWO QUESTIONS, TWO PREDICATES. `SMFProjectExporter.isDrumKit` also picks
// MIDI export channel 10 (`ProjectMIDIExportMapper.swift`, `allocateChannel`).
// A `pads` drum machine is NOT a General MIDI kit: exporting it on channel 10
// would make every other program play the wrong drums. So the export predicate
// stays exactly as it is, and the step grid asks THIS map instead: "does this
// instrument have drum rows, and which?" A non-nil answer opens the step grid.

/// One row of a drum instrument: the note it writes and the name a beginner
/// reads for it.
public struct DrumLane: Sendable, Equatable {
    /// The MIDI note this row writes.
    public let note: Int
    /// What a beginner reads ("Kick", "Open Hat", "Acoustic Snare").
    public let label: String
    /// The drum machine voice this row plays, when the instrument is our drum
    /// machine; nil for a kit whose sounds we do not model (the General MIDI
    /// percussion bank).
    public let voice: DrumVoice?

    public init(note: Int, label: String, voice: DrumVoice?) {
        self.note = note
        self.label = label
        self.voice = voice
    }
}

/// THE ONE HOME for "which rows does a drum instrument have?" (m39-w4-2).
///
/// Pure and headless: it reads an `InstrumentDescriptor` and nothing else, so
/// every surface that wants drum rows (the step grid today; the pad grid and
/// drum patterns in later wave-4 items) asks the same table.
public enum DrumLaneMap {

    /// The rows for `instrument`, or nil when it is not a drum instrument (the
    /// step grid then keeps its melodic window and opens in the piano roll).
    ///
    /// - `.drumSynth`: eight rows, one per voice in `DrumVoice` order, at
    ///   `DrumVoice.primaryNote(in:)` for the kit's own note layout, labelled
    ///   with `DrumVoice.displayName`. A never-configured drum machine is the
    ///   factory kit (`resolvedDrumKit`), which is `pads`.
    /// - `.soundBank` on the General MIDI percussion bank (bank MSB 120): the
    ///   17 covered General MIDI rows, unchanged (`generalMIDIPercussionLanes`).
    /// - everything else: nil. The switch lists every kind, so the next kind
    ///   has to decide (the `SMFProjectExporter.isDrumKit` shape). The kind is
    ///   what is heard: a drum kit carried under the poly synth is not a kit.
    public static func lanes(for instrument: InstrumentDescriptor?) -> [DrumLane]? {
        guard let instrument else { return nil }
        switch instrument.kind {
        case .drumSynth:
            let layout = instrument.resolvedDrumKit.noteLayout
            return DrumVoice.allCases.map { voice in
                DrumLane(note: Int(voice.primaryNote(in: layout)),
                         label: voice.displayName,
                         voice: voice)
            }
        case .soundBank:
            // The same bank test `SMFProjectExporter.isDrumKit` makes for a
            // sound bank (kind-gated, not source-gated: an SF2 on bank 120 is
            // a drum kit too). `DrumLaneMapTests` pins that the two agree on
            // every sound-bank fixture, so they cannot drift apart unseen.
            guard let bank = instrument.soundBank,
                  bank.bankMSB == GMProgramCatalog.percussionBankMSB else { return nil }
            return generalMIDIPercussionLanes
        case .sampler:
            // m39-w4-6: a sampler's rows come from its zones' `drumRole`
            // (a kit-sorted chop, or a person's relabel). No role, no rows: a
            // melodic sampler keeps the melodic window.
            return samplerLanes(instrument.sampler?.zones ?? [])
        case .testTone, .polySynth, .audioUnit:
            return nil
        }
    }

    /// A sampler's drum rows (m39-w4-6), or nil when no zone names a drum.
    ///
    /// One row per zone with a `drumRole`, at the key the zone answers (its
    /// root, clamped into its key span), labelled with the role's name; a
    /// role's second and later rows read "Kick 2", "Kick 3"… Rows follow the
    /// drum machine's voice order (kick first), and within a role the
    /// `KitSliceLayout` order (its loudest hit's note first, then the rest by
    /// note). Then, once the sampler IS a drum instrument, every single-key
    /// zone with no role gets an "Other" row: a sorted kit's unrecognised hits
    /// (note 84 up) stay playable from the grid. A key two zones share is one
    /// row (the first zone's).
    static func samplerLanes(_ zones: [SamplerZone]) -> [DrumLane]? {
        guard zones.contains(where: { $0.drumRole != nil }) else { return nil }
        func key(_ zone: SamplerZone) -> Int {
            min(max(zone.rootPitch, zone.minPitch), zone.maxPitch)
        }
        var lanes: [DrumLane] = []
        var used = Set<Int>()
        for voice in DrumVoice.allCases {
            let order = KitSliceLayout.roleNotes.first { $0.role.drumVoice == voice }?.notes ?? []
            func rank(_ note: Int) -> Int { order.firstIndex(of: note) ?? (order.count + note) }
            let notes = zones.filter { $0.drumRole == voice }.map(key).sorted { rank($0) < rank($1) }
            var count = 0
            for note in notes where used.insert(note).inserted {
                count += 1
                lanes.append(DrumLane(note: note,
                                      label: count == 1 ? voice.displayName : "\(voice.displayName) \(count)",
                                      voice: voice))
            }
        }
        let others = zones.filter { $0.drumRole == nil && $0.minPitch == $0.maxPitch }.map(key).sorted()
        var count = 0
        for note in others where used.insert(note).inserted {
            count += 1
            lanes.append(DrumLane(note: note, label: count == 1 ? "Other" : "Other \(count)", voice: nil))
        }
        return lanes
    }

    /// The General MIDI percussion bank's rows: the 17 covered notes of
    /// `InstrumentFamilyResolver.percussionNotes`, with their General MIDI
    /// names. Read from that table, never restated. Computed (not a
    /// `static let`) so it is never a lazily initialised global.
    public static var generalMIDIPercussionLanes: [DrumLane] {
        InstrumentFamilyResolver.percussionNotes.map {
            DrumLane(note: $0.note, label: $0.gmName, voice: nil)
        }
    }
}
