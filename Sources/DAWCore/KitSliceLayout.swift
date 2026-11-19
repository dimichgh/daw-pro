import Foundation

// m39-w4-6 — kit-aware slicing: which note each sorted hit lands on.
// Design `docs/design/2026-10-07-loop-drum-depth.md` §5.2 step 3, §5.4, §10.3.

/// How `clip.sliceToSampler` numbers its pads.
public enum SliceMapping: String, Codable, Sendable, CaseIterable {
    /// One pad per note from `baseNote` up, in time order. The default, and exactly what a chop did before
    /// m39-w4-6.
    case chromatic
    /// Sort the hits into a General MIDI drum kit: kicks on 36, snares on 38, hats on 42/46, anything else on
    /// the extra pads from note 84.
    case kit
}

/// A role a caller may FORCE on one slice in `mapping: "kit"` (the `roles` override), applied before the
/// classifier. The same five a sorted kit uses; "other" is never folded into another role.
public enum KitSliceRole: String, Codable, Sendable, CaseIterable {
    case kick, snare, closedHat, openHat, other

    /// The drum machine voice this role is, or nil for "other".
    public var drumVoice: DrumVoice? {
        switch self {
        case .kick: return .kick
        case .snare: return .snare
        case .closedHat: return .closedHat
        case .openHat: return .openHat
        case .other: return nil
        }
    }

    /// The role a classifier verdict (or a stored zone role) maps to. A voice a sorted kit does not sort into
    /// (clap, tom, rim, cymbal) is "other", never the nearest of the four.
    public init(_ voice: DrumVoice?) {
        switch voice {
        case .kick: self = .kick
        case .snare: self = .snare
        case .closedHat: self = .closedHat
        case .openHat: self = .openHat
        case .clap, .tom, .rim, .cymbal, .none: self = .other
        }
    }
}

/// Pure layout: roles and loudness in, General MIDI notes out (DAWCore, no audio).
public enum KitSliceLayout {

    /// Each role's notes, General MIDI numbering, the loudest slice of the role first: kick 36 (Bass Drum 1)
    /// then 35 (Acoustic Bass Drum), snare 38 then 40, closed hat 42 then 44 (Pedal Hi-Hat), open hat 46.
    public static let roleNotes: [(role: KitSliceRole, notes: [Int])] = [
        (.kick, [36, 35]), (.snare, [38, 40]), (.closedHat, [42, 44]), (.openHat, [46]),
    ]

    /// Overflow and "other" go here and up, in time order: the first pad of bank 4 (36 + 48), where no
    /// General MIDI drum sits, so no extra is ever labelled as a General MIDI drum.
    public static let firstExtraNote = 84

    /// The hats' choke group: the drum machine's own hat default (`DrumKit.swift`, closed and open hat), so a
    /// closed hat cuts a ringing open hat, like on a real kit.
    public static let hatChokeGroup = 0

    /// The note for each slice. `roles[i]` and `loudness[i]` describe slice i (time order). Within a role the
    /// loudest slice takes the role's first note (ties go to the earlier slice); everything past a role's
    /// notes, and every "other", goes to the extras from `firstExtraNote`, in time order.
    ///
    /// ⛔ REFUSED, never truncated, when the extras would pass note 127.
    public static func notes(roles: [KitSliceRole], loudness: [Double], clipId: UUID) throws -> [Int] {
        guard roles.count == loudness.count else {
            throw ProjectError.invalidClipEdit(
                "sorting clip \(clipId.uuidString) into a drum kit got \(roles.count) roles for "
                + "\(loudness.count) slices. Nothing was changed")
        }
        var notes = [Int?](repeating: nil, count: roles.count)
        for (role, roleNotes) in roleNotes {
            let members = roles.indices.filter { roles[$0] == role }
                .sorted { loudness[$0] != loudness[$1] ? loudness[$0] > loudness[$1] : $0 < $1 }
            for (rank, slice) in members.enumerated() where rank < roleNotes.count {
                notes[slice] = roleNotes[rank]
            }
        }
        let extras = notes.indices.filter { notes[$0] == nil }
        let highest = firstExtraNote + extras.count - 1
        guard extras.isEmpty || highest <= SamplerZone.pitchRange.upperBound else {
            throw ProjectError.invalidClipEdit(
                "sorting clip \(clipId.uuidString) into a drum kit would put \(extras.count) hits on the "
                + "extra pads from note \(firstExtraNote), which needs note \(highest) — MIDI stops at 127. "
                + "Nothing was changed. Make fewer slices (maxSlices, or a shorter clip), or chop with "
                + "mapping \"chromatic\"")
        }
        for (offset, slice) in extras.enumerated() { notes[slice] = firstExtraNote + offset }
        return notes.map { $0 ?? firstExtraNote }
    }

    /// What one kit sort produced.
    public struct Outcome: Sendable, Equatable {
        public var plan: SliceToSamplerPlan.Result
        public var roles: [KitSliceRole]
        /// "Sorted into 4 kicks, 3 snares, 8 closed hats, 1 open hat and 2 other hits."
        public var summary: String
    }

    /// Re-lays a CHROMATIC plan as a kit: every zone, note and report keeps its timing, length and velocity
    /// and moves only to its kit note. `timbres` is index-aligned with `plan.slices`; `overrides` (slice index
    /// → role) win over the classifier.
    ///
    /// Zones: `rootPitch` = `minPitch` = `maxPitch` = the kit note (one pad, one note, nothing transposed),
    /// `drumRole` set (nil for "other"), and the hats in `hatChokeGroup`. Nothing else changes.
    public static func apply(to plan: SliceToSamplerPlan.Result, timbres: [SliceTimbre],
                             overrides: [Int: KitSliceRole], clipId: UUID) throws -> Outcome {
        let count = plan.slices.count
        guard timbres.count == count, plan.zones.count == count else {
            throw ProjectError.invalidClipEdit(
                "the engine measured \(timbres.count) of the \(count) slices of clip \(clipId.uuidString), "
                + "so they cannot be sorted into a drum kit. Nothing was changed. Chop with mapping "
                + "\"chromatic\" instead")
        }
        if let bad = overrides.keys.sorted().first(where: { !(0..<count).contains($0) }) {
            throw ProjectError.invalidClipEdit(
                "roles names slice \(bad), but this chop made \(count) slice\(count == 1 ? "" : "s") "
                + "(0–\(count - 1)). Nothing was changed")
        }
        var roles: [KitSliceRole] = []
        var confidences: [Double] = []
        for index in 0..<count {
            if let forced = overrides[index] {
                roles.append(forced)
                confidences.append(1)              // a caller's word is certain
            } else {
                let verdict = DrumHitClassifier.classify(timbres[index])
                roles.append(KitSliceRole(verdict.role))
                confidences.append(verdict.confidence)
            }
        }
        let notes = try Self.notes(roles: roles, loudness: timbres.map(\.peak), clipId: clipId)

        var result = plan
        var pitchMap: [Int: Int] = [:]
        for index in 0..<count {
            let note = notes[index]
            let role = roles[index]
            pitchMap[plan.slices[index].pitch] = note
            var zone = result.zones[index]
            zone.rootPitch = note
            zone.minPitch = note
            zone.maxPitch = note
            zone.drumRole = role.drumVoice
            zone.chokeGroup = (role == .closedHat || role == .openHat) ? hatChokeGroup : nil
            result.zones[index] = zone
            result.slices[index].pitch = note
            result.slices[index].role = role
            result.slices[index].confidence = confidences[index]
        }
        for index in result.notes.indices {
            if let note = pitchMap[result.notes[index].pitch] { result.notes[index].pitch = note }
        }
        return Outcome(plan: result, roles: roles, summary: summary(roles))
    }

    /// "Sorted into 4 kicks, 3 snares, 8 closed hats, 1 open hat and 2 other hits." Roles with no hit are
    /// left out; the order is the kit's.
    public static func summary(_ roles: [KitSliceRole]) -> String {
        let names: [(KitSliceRole, String, String)] = [
            (.kick, "kick", "kicks"), (.snare, "snare", "snares"), (.closedHat, "closed hat", "closed hats"),
            (.openHat, "open hat", "open hats"), (.other, "other hit", "other hits"),
        ]
        let parts = names.compactMap { role, one, many -> String? in
            let n = roles.filter { $0 == role }.count
            return n == 0 ? nil : "\(n) \(n == 1 ? one : many)"
        }
        guard let last = parts.last else { return "There were no hits to sort." }
        let list = parts.count == 1 ? last : parts.dropLast().joined(separator: ", ") + " and " + last
        return "Sorted into \(list)."
    }
}
