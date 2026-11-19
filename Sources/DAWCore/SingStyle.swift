import Foundation

/// How a melody clip is SUNG: its vibrato, its breathiness ("air") and
/// whether note velocity sets each note's level (p2-sing-x5, design
/// `docs/design/2026-10-06-p2-sing-expansion.md` §5.3), stored as
/// `Clip.singStyle`.
///
/// ## nil is the default
///
/// `Clip.singStyle == nil` is the only "no style" state: nothing was chosen,
/// so every field sings at its DEFAULT. Every field is optional and its nil
/// is its default (`vibrato` nil = `defaultVibrato`, which is `.normal` since
/// the user's Sung Vocal Picks, p2-sing-x9-picks; `air` nil = 0;
/// `followVelocity` nil = false; `notes` nil = no per-note choice). A default
/// is resolved when a sing job PLANS a take (`resolved(_:)`), never at decode:
/// a saved clip keeps exactly the choices it was saved with, and a take that
/// was already sung is baked audio that nothing re-sings. `normalized` turns
/// a style that chooses nothing into nil, so "no style" has one spelling (the
/// `ClipLyrics.normalized` precedent); a NAMED clip-wide vibrato is a choice
/// and is kept, `.asSung` ("no added wobble") included. `Clip.init` and both
/// encoders that write a clip (`Clip.encode`, `ClipDocument.init(from:)`)
/// apply it, so a clip without a style encodes byte-identically to a build
/// that never had the field (design §9 S2).
///
/// ## Not render material
///
/// Nothing the engine plays reads it. A sing job reads it once, when it
/// plans the take; the post-render pass (`SungExpressionPlanner`, a later
/// lane) turns it into pitch-editor edits on the LANDED take
/// (`ProjectStore.landSungVocal(pitchEdits:)`), and the take's record keeps a
/// snapshot (`SungVocalProvenance.style`). `Clip.init` drops it from any clip
/// that is not MIDI, as it drops lyrics.
///
/// ## Per-note choices are keyed by note id
///
/// `notes` maps `MIDINote.id` to that note's own choice. That is a deliberate
/// exception to "derive, don't store" (design §5.3): the choice describes the
/// note ITSELF, like its velocity, not a relation between two things that
/// change. At the NOTE level, `.asSung` and an air of 0 are real choices
/// ("this note: no wobble / no air", whatever the clip says), so a per-note
/// entry is dropped only when it chooses nothing at all.
///
/// A choice whose note is gone (the note was deleted) is INERT: nothing
/// reads it, `orphanedNoteIDs(in:)` reports it, and the next write of the
/// style prunes it (TODO(p2-sing-x7): `clip.setSingStyle` prunes through
/// `keepingOverrides(for:)` and `clip.getSingStyle` reports
/// `orphanedNoteIds` from `orphanedNoteIDs(in:)`). Nothing prunes at load:
/// decoding never looks at the notes.
///
/// ## When a clip is rebuilt
///
/// Every edit that rebuilds a clip from its fields carries the style (the
/// census in W8-X5M's report). The rule is one sentence: **each clip that
/// comes out keeps the clip-wide choices, and the per-note choices of
/// exactly the notes it holds** (`keepingOverrides(for:)`). Every rebuild
/// site in this tree keeps note ids, so a note's choice simply goes with the
/// note: after a split each half has its own notes' choices, a comp member
/// has its window's, and a note a trim dropped takes its choice with it (undo
/// restores both). A note that a bar insert cuts in two sits in BOTH pieces
/// under one id, so both pieces keep its choice.
///
/// The decoder is lenient the `SungVocalProvenance` way: a missing key reads
/// as its default, and a vibrato name this build does not know (a file from
/// a later build) reads as nil (the default) instead of failing the clip. A
/// field of the wrong type still throws.
public struct SingStyle: Codable, Sendable, Equatable {

    /// The five vibrato choices (design §5.1), in the order the Expression
    /// card shows them. The raw values are the wire's spellings (design §5.6);
    /// `CaseIterable` so a refusal can list all five.
    public enum Vibrato: String, Codable, Sendable, CaseIterable {
        /// The singer's own wobble, untouched.
        case asSung
        /// The singer's wobble removed; its slow drift stays.
        case straight
        case gentle
        case normal
        case wide
    }

    /// The clip's vibrato; nil means `defaultVibrato`.
    public var vibrato: Vibrato?
    /// The clip's breathiness, `airRange` (0 = none, 1 = lots); nil means 0.
    public var air: Double?
    /// True: quieter notes (lower velocity) are sung quieter. nil means false.
    public var followVelocity: Bool?
    /// Per-note choices, keyed by `MIDINote.id`; nil means none.
    public var notes: [UUID: NoteSingStyle]?

    public init(vibrato: Vibrato? = nil, air: Double? = nil, followVelocity: Bool? = nil,
                notes: [UUID: NoteSingStyle]? = nil) {
        self.vibrato = vibrato
        self.air = air
        self.followVelocity = followVelocity
        self.notes = notes
    }

    /// Air runs from none (0) to lots (1).
    public static let airRange: ClosedRange<Double> = 0...1

    /// The vibrato a clip that names none is sung with: "Normal", a 45-cent
    /// wobble on long notes. The user's pick on the Sung Vocal Picks page,
    /// round V (take `normal-45c`, 2026-10-07; p2-sing-x9-picks); before it,
    /// a clip with no style was sung `.asSung`. ONE home: everything that
    /// resolves an unnamed vibrato reads it here.
    public static let defaultVibrato: Vibrato = .normal

    /// `air` clamped into `airRange`; nil for nil, NaN or an infinity (JSON
    /// cannot carry those, and an encoder would throw on them).
    static func clampedAir(_ air: Double?) -> Double? {
        guard let air, air.isFinite else { return nil }
        return min(max(air, airRange.lowerBound), airRange.upperBound)
    }

    /// The one "no style" state: a style that chooses nothing is nil. A named
    /// clip-wide vibrato is a choice and is KEPT, `.asSung` included (it is
    /// not the default, so folding it into nil would sing the default
    /// instead); an air of 0 and `followVelocity` false are defaults and
    /// become nil, air is clamped into `airRange`, a per-note entry that
    /// chooses nothing is dropped, and an empty `notes` map is nil. A
    /// per-note `.asSung` or air 0 is KEPT: at the note level it overrides
    /// the clip. Never looks at any clip's notes.
    public static func normalized(_ style: SingStyle?) -> SingStyle? {
        guard let style else { return nil }
        var out = SingStyle()
        out.vibrato = style.vibrato
        if let air = clampedAir(style.air), air != 0 { out.air = air }
        out.followVelocity = style.followVelocity == true ? true : nil
        if let notes = style.notes {
            var kept: [UUID: NoteSingStyle] = [:]
            for (id, choice) in notes {
                let note = NoteSingStyle(vibrato: choice.vibrato, air: clampedAir(choice.air))
                if !note.isEmpty { kept[id] = note }
            }
            out.notes = kept.isEmpty ? nil : kept
        }
        guard out.vibrato != nil || out.air != nil || out.followVelocity != nil || out.notes != nil else {
            return nil
        }
        return out
    }

    /// True when the style chooses nothing (`normalized` gives nil).
    public var isDefault: Bool { Self.normalized(self) == nil }

    /// What a sing job sings, resolved ONCE when the job plans the take (never
    /// at decode): `style` normalised, with its clip-wide vibrato filled in
    /// from `defaultVibrato` when it names none. Never nil, so the take's
    /// record (`SungVocalProvenance.style`) names the vibrato that was sung
    /// even for a clip with no style. Air, `followVelocity` and the per-note
    /// choices are kept as they are (their defaults did not move).
    public static func resolved(_ style: SingStyle?) -> SingStyle {
        var out = normalized(style) ?? SingStyle()
        if out.vibrato == nil { out.vibrato = defaultVibrato }
        return out
    }

    // MARK: - What one note gets

    /// The vibrato note `id` is sung with: its own choice, else the clip's,
    /// else `defaultVibrato`.
    public func resolvedVibrato(forNote id: UUID) -> Vibrato {
        notes?[id]?.vibrato ?? vibrato ?? Self.defaultVibrato
    }

    /// The air note `id` is sung with, in `airRange`: its own choice, else the
    /// clip's, else 0.
    public func resolvedAir(forNote id: UUID) -> Double {
        Self.clampedAir(notes?[id]?.air ?? air) ?? 0
    }

    /// Whether velocity sets each note's level (nil is false).
    public var followsVelocity: Bool { followVelocity ?? false }

    // MARK: - Notes that come and go

    /// The ids of per-note choices whose note `notes` no longer holds (INERT
    /// choices), sorted by `uuidString` so a reply is stable.
    public func orphanedNoteIDs(in notes: [MIDINote]?) -> [UUID] {
        guard let overrides = self.notes else { return [] }
        let held = Set((notes ?? []).map(\.id))
        return overrides.keys.filter { !held.contains($0) }.sorted { $0.uuidString < $1.uuidString }
    }

    /// The style a clip rebuilt to hold `notes` carries (the rebuild rule in
    /// the type's note): the clip-wide choices unchanged, and the per-note
    /// choices of exactly the notes in `notes`, by id. Normalised, so a piece
    /// left with no choice at all carries nil.
    public func keepingOverrides(for notes: [MIDINote]?) -> SingStyle? {
        var out = self
        if let overrides = self.notes {
            let held = Set((notes ?? []).map(\.id))
            let kept = overrides.filter { held.contains($0.key) }
            out.notes = kept.isEmpty ? nil : kept
        }
        return Self.normalized(out)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey { case vibrato, air, followVelocity, notes }

    /// A note id written as a JSON object key (its `uuidString`).
    struct NoteKey: CodingKey {
        let stringValue: String
        init(_ id: UUID) { stringValue = id.uuidString }
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    /// Lenient (see the type's note): a missing key is its default, an unknown
    /// vibrato name is nil, and a per-note key that is not a note id is
    /// skipped. Not normalised here: `Clip.init` does that.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vibrato = try c.decodeIfPresent(String.self, forKey: .vibrato).flatMap(Vibrato.init(rawValue:))
        air = try c.decodeIfPresent(Double.self, forKey: .air)
        followVelocity = try c.decodeIfPresent(Bool.self, forKey: .followVelocity)
        if c.contains(.notes), !(try c.decodeNil(forKey: .notes)) {
            let byKey = try c.nestedContainer(keyedBy: NoteKey.self, forKey: .notes)
            var out: [UUID: NoteSingStyle] = [:]
            for key in byKey.allKeys {
                guard let id = UUID(uuidString: key.stringValue) else { continue }
                out[id] = try byKey.decode(NoteSingStyle.self, forKey: key)
            }
            notes = out
        } else {
            notes = nil
        }
    }

    /// Writes only the fields that are set, and the per-note choices as ONE
    /// JSON object keyed by note id (`uuidString`), in sorted order. (A
    /// `[UUID: …]` dictionary would otherwise be written as a flat
    /// key, value, key, value array.)
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(vibrato, forKey: .vibrato)
        if let air = Self.clampedAir(air) { try c.encode(air, forKey: .air) }
        try c.encodeIfPresent(followVelocity, forKey: .followVelocity)
        if let notes {
            var byKey = c.nestedContainer(keyedBy: NoteKey.self, forKey: .notes)
            for (id, choice) in notes.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                try byKey.encode(choice, forKey: NoteKey(id))
            }
        }
    }
}

/// One note's own singing choice (design §5.3), inside `SingStyle.notes`. A
/// nil field follows the clip's choice; `.asSung` and an air of 0 are choices
/// of their own ("no wobble / no air on this note").
public struct NoteSingStyle: Codable, Sendable, Equatable {
    public var vibrato: SingStyle.Vibrato?
    /// In `SingStyle.airRange`.
    public var air: Double?

    public init(vibrato: SingStyle.Vibrato? = nil, air: Double? = nil) {
        self.vibrato = vibrato
        self.air = air
    }

    /// True when this entry chooses nothing (it follows the clip entirely).
    public var isEmpty: Bool { vibrato == nil && air == nil }

    private enum CodingKeys: String, CodingKey { case vibrato, air }

    /// Lenient, as `SingStyle`'s: a missing key is nil, and so is a vibrato
    /// name this build does not know.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vibrato = try c.decodeIfPresent(String.self, forKey: .vibrato).flatMap(SingStyle.Vibrato.init(rawValue:))
        air = try c.decodeIfPresent(Double.self, forKey: .air)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(vibrato, forKey: .vibrato)
        if let air = SingStyle.clampedAir(air) { try c.encode(air, forKey: .air) }
    }
}
