import Foundation

/// **The warning that fires when swapping a track's instrument changes what its
/// existing controller lanes MEAN** (m27-b).
///
/// ## The defect this exists to remove
///
/// A composer authored CC11 (expression) lanes while the track was on
/// `polySynth`, which honours CC64 and pitch bend and **nothing else** — so the
/// lanes were correctly-authored INERT data. Later a `.soundBank` was assigned,
/// which routes to a hosted AU that forwards EVERY controller byte. The
/// previously-dead lanes went live with no warning anywhere, and a FINISHED,
/// VERIFIED mix regressed by 1.25 LU.
///
/// ⚠️ **Why it CUTS rather than shapes: CC11's neutral default is 127**
/// (`MIDIControllerType.neutralDefault`). An ABSENT lane means FULL SCALE, so
/// lanes peaking 106–110 and dipping to 42 are a broad ATTENUATION, not a
/// gentle inflection. The same trap applies to CC7 (channel volume, neutral
/// **100**) and CC10 (pan, neutral 64): for these three, authoring a lane at
/// "normal-looking" values is quieter/off-centre than authoring none at all.
///
/// ## Where the answer comes from
///
/// ⭐ **This file owns NO table.** "Does this controller reach the sound?" has
/// exactly one definition in DAWCore — `MIDIControllerRouting` — and it says so
/// in its own header. Everything here is a question asked of that type. The
/// complementary half of this feature lives there too: `inertLaneWarning` warns
/// when a lane is AUTHORED against an instrument that will not play it; this
/// warns when the INSTRUMENT changes under lanes that already exist. Two
/// directions, one table, deliberately.
///
/// ## What this does NOT do
///
/// ⛔ **It never rewrites, mutes, or neutralises the user's controller data.**
/// The lanes are correct data; the defect was that nothing said their MEANING
/// changed. Silently neutralising them would be a worse bug than the one being
/// fixed. This type only ANSWERS QUESTIONS.

/// One controller lane whose meaning changed when the track's instrument was
/// swapped — the m27-b warning payload.
public struct InstrumentControllerLaneWarning: Sendable, Equatable {
    /// Which way the meaning moved.
    public enum Effect: String, Sendable, Equatable {
        /// The lane was INERT and is now audible. ⛔ The 1.25 LU regression:
        /// a CC11 lane that did nothing under `polySynth` starts attenuating
        /// the instant a `.soundBank` is assigned.
        case becameLive
        /// The lane was shaping the sound and is now inert. The mirror
        /// regression — an attenuation LIFTS and the track gets louder.
        case becameInert
    }

    public let type: MIDIControllerType
    public let effect: Effect
    /// Beginner-readable sentence naming the controller, the direction, and —
    /// for the full-scale-neutral controllers — WHY it changes level. Surfaced
    /// VERBATIM on the wire, the media-import warning idiom.
    public let message: String

    public init(type: MIDIControllerType, effect: Effect, message: String) {
        self.type = type
        self.effect = effect
        self.message = message
    }
}

public enum InstrumentControllerChangeWarnings {
    /// **THE PREDICATE.** Warn about a controller lane type `T` if and only if
    /// BOTH hold:
    ///  1. the track actually CARRIES a lane of type `T` with at least one
    ///     point (`carriedLaneTypes`), and
    ///  2. `MIDIControllerRouting.honors(T, old) != honors(T, new)`.
    ///
    /// ⚠️ **Both halves are load-bearing, and clause 1 is the one that keeps
    /// this feature from becoming noise.** Every instrument change moves SOME
    /// controller between honoured and ignored — `polySynth` → `.soundBank`
    /// changes the answer for all 128 CCs. Warning about a controller nobody
    /// authored is as useless as staying silent, and a warning that fires on
    /// every instrument change gets ignored, taking the one that MATTERED with
    /// it. So the difference is intersected with the data the track really has.
    ///
    /// Clause 2 is a MEMBERSHIP change, deliberately: "honours it differently
    /// in degree" is not decidable from here (a hosted AU's CC11 curve is the
    /// plug-in's business), and guessing would reintroduce the false confidence
    /// this item exists to remove. Sampler → soundBank with CC11 lanes
    /// therefore does NOT warn: both honour CC11.
    ///
    /// Returns [] when the track carries no controller data at all — the
    /// overwhelmingly common case, and the reason the wire field is emitted
    /// only when non-empty.
    public static func warnings(
        changingFrom oldDescriptor: InstrumentDescriptor?,
        to newDescriptor: InstrumentDescriptor,
        carriedLaneTypes: Set<MIDIControllerType>
    ) -> [InstrumentControllerLaneWarning] {
        guard !carriedLaneTypes.isEmpty else { return [] }
        // A track with no descriptor yet renders `.default` — the same
        // resolution `PlaybackGraph.instrumentFactory` performs.
        let old = oldDescriptor ?? InstrumentDescriptor()
        var result: [InstrumentControllerLaneWarning] = []
        for type in carriedLaneTypes.sorted(by: stableOrder) {
            let was = MIDIControllerRouting.honors(type, instrument: old)
            let now = MIDIControllerRouting.honors(type, instrument: newDescriptor)
            guard was != now else { continue }
            let effect: InstrumentControllerLaneWarning.Effect = now ? .becameLive : .becameInert
            result.append(InstrumentControllerLaneWarning(
                type: type, effect: effect,
                message: message(for: type, effect: effect, from: old, to: newDescriptor)))
        }
        return result
    }

    /// Every controller lane type carried by these clips, counting only lanes
    /// with at least one point — an empty lane cannot change any sound, so it
    /// must not raise a warning.
    public static func carriedLaneTypes(in clips: [Clip]) -> Set<MIDIControllerType> {
        var types: Set<MIDIControllerType> = []
        for clip in clips {
            for lane in clip.controllerLanes where !lane.points.isEmpty {
                types.insert(lane.type)
            }
        }
        return types
    }

    /// Deterministic ordering so the wire payload is stable across runs:
    /// CCs by number, then pitch bend, then channel pressure.
    static func stableOrder(_ a: MIDIControllerType, _ b: MIDIControllerType) -> Bool {
        func rank(_ t: MIDIControllerType) -> (Int, Int) {
            switch t {
            case .cc(let controller): return (0, controller)
            case .pitchBend: return (1, 0)
            case .channelPressure: return (2, 0)
            }
        }
        return rank(a) < rank(b)
    }

    /// A one-kind label for a descriptor, used inside warning sentences.
    static func kindLabel(_ descriptor: InstrumentDescriptor) -> String {
        switch descriptor.kind {
        case .testTone: return "the test-tone instrument"
        case .polySynth: return "the built-in poly synth"
        case .sampler: return "the built-in sampler"
        case .audioUnit: return "the hosted Audio Unit"
        case .soundBank: return "the sound bank"
        case .drumSynth: return "the drum machine"
        }
    }

    static func message(for type: MIDIControllerType,
                        effect: InstrumentControllerLaneWarning.Effect,
                        from oldDescriptor: InstrumentDescriptor,
                        to newDescriptor: InstrumentDescriptor) -> String {
        // ONE name for a controller across every surface — the same
        // `describe` the inert-lane warning uses, so the two halves of this
        // feature cannot call CC11 two different things.
        let name = MIDIControllerRouting.describe(type)
        let oldLabel = kindLabel(oldDescriptor)
        let newLabel = kindLabel(newDescriptor)
        // The full-scale-neutral controllers are the dangerous ones: an
        // authored lane at "normal-looking" values is a CUT relative to no
        // lane at all, so the sentence must say so rather than leave the
        // reader to discover it in a loudness measurement.
        let neutralNote: String
        switch type {
        case .cc(11):
            neutralNote = " Expression rests at 127 (full) when no lane exists,"
                + " so a lane below 127 ATTENUATES this track rather than shaping it —"
                + " expect the level to drop."
        case .cc(7):
            neutralNote = " Channel volume rests at 100 when no lane exists,"
                + " so a lane below 100 lowers this track's level."
        case .cc(10):
            neutralNote = " Pan rests at 64 (centre) when no lane exists,"
                + " so a lane away from 64 moves this track in the stereo field."
        default:
            neutralNote = ""
        }
        switch effect {
        case .becameLive:
            return "\(name) data on this track was inert under \(oldLabel)"
                + " but \(newLabel) acts on it — the same notes will now sound different."
                + neutralNote
                + " The lane is unchanged; remove it with clip.removeControllerLane"
                + " if that was not intended."
        case .becameInert:
            return "\(name) data on this track shaped the sound under \(oldLabel)"
                + " but \(newLabel) ignores it — that shaping is gone and the track"
                + " will sound flatter or louder than before."
                + " The data is untouched and applies again on an instrument that honours it."
        }
    }
}
