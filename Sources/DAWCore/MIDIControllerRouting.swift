import Foundation

/// Which controller lanes a given instrument will actually CONSUME, and a
/// readable sentence for the ones it will not (m27).
///
/// Why this exists. `clip.setControllerLane` used to accept any lane on any
/// track and store it silently; a user authored SEVEN CC11 lanes that produced
/// byte-identical audio, because the built-in sampler dropped every CC but 64
/// at the voice. Accepting data we discard — with a success response — is the
/// defect that produced that whole thread. The engine half is fixed (the
/// sampler now routes CC1/CC2/CC11); this is the other half: whatever we
/// STILL do not route must say so at the moment it is accepted.
///
/// This type is pure DAWCore: no engine, no UI, no AVFoundation. It is the ONE
/// definition of "does this controller reach the sound?", so the wire, the
/// panel, and any future agent-facing surface cannot drift apart. It is a
/// WARNING, never a refusal — the lane is still stored, because the user may
/// be authoring for an instrument they have not chosen yet, and because a
/// controller lane survives an instrument switch.
public enum MIDIControllerRouting {
    /// The CCs the built-in SAMPLER consumes (m16-b2 CC64 + m27 expression).
    /// Anything outside this set is dropped at the voice.
    public static let samplerRoutedCCs: Set<Int> = [1, 2, 11, 64]
    /// The CCs the built-in POLY SYNTH consumes — sustain only (m16-b2).
    public static let polySynthRoutedCCs: Set<Int> = [64]

    /// How a lane of `type` fares on `instrument`.
    public enum Routing: Equatable, Sendable {
        /// The instrument consumes it and it will be audible.
        case routed
        /// The instrument consumes it, but a parameter currently set to zero
        /// makes it inaudible — a lane that is wired but turned down.
        case routedButDisabled(reason: String)
        /// Nothing consumes it; the lane is stored and inert.
        case inert(reason: String)
    }

    /// The routing verdict. `instrument == nil` is an instrument-less track:
    /// nothing consumes anything, which is worth saying out loud rather than
    /// letting the lane look accepted.
    public static func routing(for type: MIDIControllerType,
                               instrument: InstrumentDescriptor?) -> Routing {
        guard let instrument else {
            return .inert(reason: "this track has no instrument yet, so nothing will play it")
        }
        switch instrument.kind {
        case .audioUnit, .soundBank:
            // Hosted AUs receive every controller as raw MIDI (0xB0 …) —
            // whether the PLUGIN acts on it is the plugin's business and not
            // something we can honestly claim either way.
            return .routed

        case .testTone:
            return .inert(reason: "the test-tone instrument plays notes only and consumes no "
                + "controllers at all")

        case .polySynth:
            switch type {
            case .pitchBend:
                // PolySynthInstrument bends every voice's frequency (±2 st).
                return .routed
            case .channelPressure:
                return .inert(reason: "the built-in poly synth consumes no channel pressure "
                    + "(aftertouch)")
            case .cc(let controller):
                guard polySynthRoutedCCs.contains(controller) else {
                    return .inert(reason: "the built-in poly synth consumes only CC64 (sustain) "
                        + "and pitch bend")
                }
                return .routed
            }

        case .sampler:
            switch type {
            case .pitchBend:
                return .routed
            case .channelPressure:
                return .inert(reason: "the built-in sampler consumes no channel pressure "
                    + "(aftertouch)")
            case .cc(let controller):
                guard samplerRoutedCCs.contains(controller) else {
                    return .inert(reason: "the built-in sampler consumes only CC1 (mod wheel), "
                        + "CC2 (breath), CC11 (expression), CC64 (sustain) and pitch bend")
                }
                // CC1/CC2 are wired but gated by a depth that defaults to 0 —
                // see `SamplerParams.expressionModDepth` for why they cannot
                // be unconditional (their MIDI neutral is 0, so an
                // unconditional reading renders silence before the first
                // authored point). A lane on them with depth 0 is exactly the
                // "accepted but inaudible" case this type exists to name.
                if controller == 1 || controller == 2 {
                    let depth = instrument.resolvedSampler.expressionModDepth ?? 0
                    if depth <= 0 {
                        let name = controller == 1 ? "CC1 (mod wheel)" : "CC2 (breath)"
                        return .routedButDisabled(reason:
                            "the built-in sampler reaches \(name) only through "
                            + "sampler.expressionModDepth, which is 0 (off) on this track — set "
                            + "it above 0 to make the lane audible. CC11 (expression) needs no "
                            + "such switch")
                    }
                }
                return .routed
            }
        }
    }

    /// One sentence for a lane that will not sound, or nil when it will.
    /// Names the CONTROLLER and the REASON, so the caller can act without
    /// reading source. Shape follows the media-import warning idiom: a plain
    /// sentence, surfaced verbatim, alongside a SUCCESSFUL result.
    public static func inertLaneWarning(for type: MIDIControllerType,
                                        instrument: InstrumentDescriptor?) -> String? {
        switch routing(for: type, instrument: instrument) {
        case .routed:
            return nil
        case .routedButDisabled(let reason), .inert(let reason):
            return "\(describe(type)) is stored but will not sound: \(reason)"
        }
    }

    /// Human name for a lane type, matching the copy users see elsewhere
    /// ("CC11 (expression)", not "cc:11").
    public static func describe(_ type: MIDIControllerType) -> String {
        switch type {
        case .pitchBend: return "pitch bend"
        case .channelPressure: return "channel pressure (aftertouch)"
        case .cc(let controller):
            switch controller {
            case 1: return "CC1 (mod wheel)"
            case 2: return "CC2 (breath)"
            case 7: return "CC7 (channel volume)"
            case 10: return "CC10 (pan)"
            case 11: return "CC11 (expression)"
            case 64: return "CC64 (sustain)"
            case 74: return "CC74 (brightness)"
            default: return "CC\(controller)"
            }
        }
    }
}
