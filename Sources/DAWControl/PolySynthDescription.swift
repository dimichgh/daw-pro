import DAWCore
import Foundation

/// m39-f — `instrument.describeSynth`'s payload, and the ONE HOME for what a
/// Poly Synth parameter MEANS on the wire.
///
/// ⭐ WHY THIS EXISTS AT ALL. Every other sound source in this app can describe
/// itself: effects have `fx.describe`, the Sampler has
/// `instrument.describeSampler`. The Poly Synth could not. Its legal ranges
/// lived only as Swift `static let`s an agent cannot read, and its prose lived
/// only in `mcp-server/src/server.ts` — a DIFFERENT PROCESS, which is exactly
/// the shape where a doc sentence and the arithmetic drift apart without
/// anything comparing them. With m39-g the instrument has **24 parameters**,
/// which makes guessing strictly worse than asking.
///
/// ⛔⛔ THE PROSE BELOW IS THE SAME PROSE `track.setInstrument` THROWS IN ITS
/// RANGE ERRORS. That is deliberate and it is the point: a caller who is told
/// "unisonDetuneCents must be between 0.0 and 50.0 — <meaning>" and then asks
/// this verb what the field is gets the SAME sentence, not a second one written
/// later that says something slightly different. Add a parameter and you edit
/// this table once; forget to, and `describeSynthListsEverySettableParameter`
/// fails, because it compares this list against the verb's OWN advertised
/// allow-list rather than against a second hand-written list.
///
/// ⚠️ EVERY RANGE AND CONSTANT IS READ FROM `PolySynthParams`, NEVER RE-TYPED.
/// `maxUnisonVoices` in particular is load-bearing beyond validation — the
/// engine allocates a fixed `16 × maxUnisonVoices` block of sub-voice state and
/// indexes it on the render thread — so a number spelled twice here is a number
/// that can eventually disagree with an allocation.
enum PolySynthDescription {

    /// The parameter names in the order a human would want to read them
    /// (oscillator, envelope, filter, output, then the m39-g richness groups),
    /// published as `order` because a JSON object has none.
    ///
    /// ⭐ m39-tpl-1 MOVED THE LIST to DAWCore, verbatim and in this order, as
    /// `PolySynthParams.settingNames`: a template is decoded in DAWCore, which
    /// cannot see this module, and a second hand-typed list of 24 names is the
    /// shape that drifts. This forwards, so the verb's reply is unchanged.
    static let order: [String] = PolySynthParams.settingNames

    /// What each parameter MEANS, in one sentence a beginner can act on. Reused
    /// verbatim by `track.setInstrument`'s range errors — see the type note.
    static let meanings: [String: String] = [
        "waveform":
            "the oscillator's shape — 'saw' is bright and buzzy (strings, leads), 'square' is "
            + "hollow and woody, 'triangle' is soft, 'sine' is a pure tone with no harmonics",
        "attack":
            "how long the note takes to reach full volume after the key goes down. Tiny values "
            + "are percussive; long values swell in like a pad",
        "decay":
            "how long the note takes to fall from full volume to the sustain level, while the "
            + "key is still held",
        "sustain":
            "the level the note holds at while you keep the key down, as a fraction of full "
            + "volume. 0 means the note dies away after the decay even if you hold it",
        "release":
            "how long the note takes to fade to silence after the key comes up",
        "cutoffHz":
            "the low-pass filter's corner frequency — everything above it is progressively "
            + "removed. Low values are dark and muffled, high values are open and bright",
        "resonance":
            "emphasis right at the cutoff frequency, which adds the vocal 'wah' character a "
            + "filter sweep has. Maps 0...1 onto a filter Q of 0.5...10",
        "gain":
            "the instrument's output level before the track fader",
        // ⚠️ m34-q's WORDING, MOVED HERE VERBATIM rather than paraphrased. This
        // string is what `track.setInstrument` throws on an out-of-range cap
        // and it has been that text since m34-q; the move is what makes the
        // error and this verb's answer the same sentence instead of two.
        "pedalHoldLimit":
            "how many notes the sustain pedal (CC 64) keeps ringing on the built-in Poly "
            + "Synth; omit for unlimited, which is what it has always done. The oldest "
            + "pedal-held note is RELEASED through the patch's own release when the cap "
            + "is exceeded; a key you are still holding is never taken. Any value above "
            + "the 16-voice pool is unreachable and so means unlimited",
        "unisonVoices":
            "how many detuned copies of the oscillator each note plays. 1 (the default) is one "
            + "clean oscillator; more makes the classic wide supersaw. This multiplies "
            + "OSCILLATOR cost per note, not the 16-note polyphony budget, and does nothing "
            + "audible on its own — pair it with unisonDetuneCents",
        "unisonDetuneCents":
            "the total pitch SPREAD across the unison stack, in cents (100 cents = one "
            + "semitone); the outermost copies sit at plus/minus half of it. INERT at one voice "
            + "— there is nothing to detune against",
        "unisonStereoSpread":
            "how wide the unison stack sits across the stereo field: 0 (the default) is dead "
            + "centre, 1 puts the outermost copies hard left and hard right. INERT at one voice",
        "subLevel":
            "level of the sub-oscillator mixed underneath the main one, for weight in the low "
            + "end. 0 (the default) means there is no sub-oscillator at all",
        "subOctave":
            "how far below the played note the sub-oscillator sounds: -1 (the default) is one "
            + "octave down, -2 is two. INERT while subLevel is 0",
        "subWaveform":
            "the SUB-oscillator's shape, not the main one's (that key is 'waveform'). Defaults "
            + "to sine, which adds weight without harmonics that fight the main oscillator. "
            + "INERT while subLevel is 0",
        "noiseLevel":
            "level of a noise layer mixed in BEFORE the filter, so the filter and its resonance "
            + "shape it — breath on a flute patch, air on a pad. 0 (the default) means there is "
            + "no noise source at all",
        "noiseColor":
            "the tilt of that noise: 0 is dark and rumbly, 0.5 (the default) is plain white "
            + "noise, 1 is bright and hissy. INERT while noiseLevel is 0",
        "drift":
            "analog-style pitch instability — each voice wanders slowly by up to plus/minus "
            + "\(PolySynthParams.driftMaxCents) cents at 1. 0 (the default) is perfectly "
            + "stable. It is a shimmer, not a vibrato",
        "resonanceBoost":
            "EXTRA filter resonance above the resonance knob's own ceiling, up to a Q of "
            + "\(PolySynthParams.maxBoostedQ), for screaming self-oscillating peaks. 0 (the "
            + "default) leaves the legacy resonance mapping bit-identical — this is a second "
            + "knob precisely so stored projects keep their sound",
        "drive":
            "waveshaper drive into the filter — grit and harmonic saturation. 0 (the default) "
            + "takes the waveshaper out of the signal path entirely",
        "velocityToCutoff":
            "how much harder playing opens the filter: at 1 a full-velocity note sits "
            + "\(PolySynthParams.cutoffTrackMaxOctaves) octaves brighter. Applied once at "
            + "note-on. 0 is the default",
        "keyToCutoff":
            "how much the filter follows the note's PITCH, so high notes stay as bright as low "
            + "ones instead of dulling. 1 is full 1:1 tracking measured from middle C (MIDI "
            + "\(Int(PolySynthParams.keyTrackCenterPitch))). 0 is the default",
        "voiceJitter":
            "per-note randomisation of pan, detune and cutoff, so no two notes sound quite "
            + "alike — the thing that stops a repeated chord sounding photocopied. 0 is the "
            + "default",
        "envelopeCurve":
            "the SHAPE of the attack/decay/release ramps, not their length. 0 (the default) is "
            + "the straight lines this synth has always drawn; positive bends toward the snappy "
            + "exponential curve real hardware envelopes have; negative bends the other way. A "
            + "0.15 s release still reaches exact silence at exactly 0.15 s either way",
    ]

    /// The meaning of one parameter, for a wire error message. The fallback is
    /// deliberately a POINTER rather than an empty string: a range error that
    /// trails off into nothing reads like a truncated message, and
    /// `everyParameterCarriesMeaningAndUnit` fails long before a caller sees
    /// this.
    static func meaning(_ name: String) -> String {
        meanings[name] ?? "see instrument.describeSynth for what this parameter does"
    }

    /// The unit a caller should show next to the number. Spelled from the
    /// model's own constants wherever a constant is what makes the unit
    /// meaningful — the `glideRateReferenceSemitones` precedent.
    static let units: [String: String] = [
        "waveform": "enum",
        "attack": "seconds",
        "decay": "seconds",
        "sustain": "level 0-1",
        "release": "seconds",
        "cutoffHz": "Hz",
        "resonance": "0-1 (maps to filter Q 0.5-10)",
        "gain": "0-1",
        "pedalHoldLimit": "notes",
        "unisonVoices": "voices",
        "unisonDetuneCents": "cents (total spread)",
        "unisonStereoSpread": "0-1 (0 = centre, 1 = hard left/right)",
        "subLevel": "0-1 level",
        "subOctave": "octaves below the played note",
        "subWaveform": "enum",
        "noiseLevel": "0-1 level",
        "noiseColor": "0-1 (0 = dark, 0.5 = white, 1 = bright)",
        "drift": "0-1 depth (1 = plus/minus \(PolySynthParams.driftMaxCents) cents)",
        "resonanceBoost": "0-1 (extends filter Q up to \(PolySynthParams.maxBoostedQ))",
        "drive": "0-1 depth",
        "velocityToCutoff":
            "0-1 depth (1 = \(PolySynthParams.cutoffTrackMaxOctaves) octaves at full velocity)",
        "keyToCutoff":
            "0-1 tracking (1 = 1:1 from MIDI \(Int(PolySynthParams.keyTrackCenterPitch)))",
        "voiceJitter": "0-1 depth",
        "envelopeCurve": "-1 to 1 shape (0 = linear)",
    ]

    /// The whole payload. `kind` is the track's ACTIVE instrument kind, which
    /// is how a caller tells whether the patch described here is the one
    /// actually sounding — poly-synth settings are carried across kind switches
    /// (InstrumentDescriptor's own contract), exactly as the Sampler's are.
    static func payload(
        trackID: UUID, descriptor: InstrumentDescriptor
    ) -> [String: JSONValue] {
        let poly = descriptor.polySynth
        var parameters: [String: JSONValue] = [:]
        for name in order { parameters[name] = entry(name, poly) }

        var result: [String: JSONValue] = [
            "trackId": .string(trackID.uuidString),
            "kind": .string(descriptor.kind.rawValue),
            // The one bit a caller most needs and would otherwise have to infer
            // from `kind`: is this patch what the track will actually play?
            "isActiveInstrument": .bool(descriptor.kind == .polySynth),
            "parameterCount": .number(Double(order.count)),
            "order": .array(order.map(JSONValue.string)),
            "parameters": .object(parameters),
            // What the engine DERIVES from the above. Published rather than
            // left to be re-derived, because a caller re-deriving `effectiveQ`
            // from `resonance` alone gets the pre-m39-g answer and never learns
            // the boost knob exists.
            "derived": .object([
                "effectiveQ": .number(poly.effectiveQ),
                "unisonIsEffective": .bool(poly.unisonIsEffective),
                "stereoSpreadIsEffective": .bool(poly.stereoSpreadIsEffective),
                "subIsEffective": .bool(poly.subIsEffective),
                "noiseIsEffective": .bool(poly.noiseIsEffective),
                "driftIsEffective": .bool(poly.driftIsEffective),
                "driveIsEffective": .bool(poly.driveIsEffective),
                "envelopeCurveIsEffective": .bool(poly.envelopeCurveIsEffective),
                "cutoffIsPerVoice": .bool(poly.cutoffIsPerVoice),
            ]),
            // The engine constants a caller needs to turn a 0-1 depth into a
            // musical quantity. ONE HOME each, read from the model.
            "constants": .object([
                "maxUnisonVoices": .number(Double(PolySynthParams.maxUnisonVoices)),
                "driftMaxCents": .number(PolySynthParams.driftMaxCents),
                "cutoffTrackMaxOctaves": .number(PolySynthParams.cutoffTrackMaxOctaves),
                "keyTrackCenterPitch": .number(PolySynthParams.keyTrackCenterPitch),
                "maxBoostedQ": .number(PolySynthParams.maxBoostedQ),
                // ⛔ THE 16-NOTE POLYPHONY FIGURE IS DELIBERATELY NOT HERE.
                // `PolySynthInstrument.voiceCount` is a PRIVATE constant in
                // DAWEngine, which this module does not (and must not) import.
                // Re-typing a 16 to fill the gap is how a published figure ends
                // up disagreeing with the allocation it claims to describe —
                // the exact rot `maxUnisonVoices` is read from the model to
                // avoid. Absent is better than plausible.
            ]),
        ]
        let warnings = self.warnings(descriptor)
        // ONLY when non-empty — the A-imp-1 idiom this wire uses everywhere
        // else (reference.import, instrument.describeSampler,
        // clip.setControllerLane). An always-present empty array reads as a
        // field worth checking on every call, and noise gets ignored, taking
        // the one warning that mattered with it.
        if !warnings.isEmpty { result["warnings"] = .array(warnings.map(JSONValue.string)) }
        return result
    }

    /// ⛔ THE POINT OF THE VERB, NOT A DECORATION. This tree's characteristic
    /// failure is a setting that is accepted, stored, reported back — and does
    /// nothing, because a SECOND field gates it. `instrument.describeSampler`
    /// grew exactly these warnings for glide; the Poly Synth has four such
    /// pairs, and the model already answers each one (`unisonIsEffective` and
    /// friends), so publishing the comparison costs nothing and ends the
    /// "I set detune and heard no difference" report.
    static func warnings(_ descriptor: InstrumentDescriptor) -> [String] {
        let poly = descriptor.polySynth
        var warnings: [String] = []
        if descriptor.kind != .polySynth {
            warnings.append(
                "this track's active instrument is '\(descriptor.kind.rawValue)', so NONE of "
                + "these Poly Synth settings are sounding right now. They are kept (settings "
                + "survive a kind switch) and will apply again the moment you set kind to "
                + "'polySynth'.")
        }
        if !poly.unisonIsEffective {
            if poly.effectiveUnisonDetuneCents > 0 {
                warnings.append(
                    "unisonDetuneCents is \(poly.effectiveUnisonDetuneCents) but unisonVoices is "
                    + "\(poly.effectiveUnisonVoices), and there is nothing to detune AGAINST at "
                    + "one voice — the setting does nothing. Raise unisonVoices to 2 or more "
                    + "(up to \(PolySynthParams.maxUnisonVoices)) to hear it.")
            }
            if poly.effectiveUnisonStereoSpread > 0 {
                warnings.append(
                    "unisonStereoSpread is \(poly.effectiveUnisonStereoSpread) but unisonVoices "
                    + "is \(poly.effectiveUnisonVoices), and one voice has nothing to spread "
                    + "across the stereo field — the setting does nothing. Raise unisonVoices to "
                    + "2 or more to hear it.")
            }
        }
        if !poly.subIsEffective {
            if poly.subOctave != nil || poly.subWaveform != nil {
                warnings.append(
                    "subOctave/subWaveform are set but subLevel is 0, so there is no "
                    + "sub-oscillator to shape and they do nothing. Raise subLevel above 0 "
                    + "(0.3-0.5 adds weight without muddying the low end) to hear them.")
            }
        }
        if !poly.noiseIsEffective, poly.noiseColor != nil {
            warnings.append(
                "noiseColor is set but noiseLevel is 0, so there is no noise layer to colour and "
                + "it does nothing. Raise noiseLevel above 0 to hear it.")
        }
        return warnings
    }

    // MARK: - One parameter

    private static func entry(_ name: String, _ poly: PolySynthParams) -> JSONValue {
        var object: [String: JSONValue] = [
            "unit": .string(units[name] ?? ""),
            "meaning": .string(meanings[name] ?? ""),
        ]
        let fresh = PolySynthParams()
        switch name {
        // ── The eight that have always been here: plain values, never nil. ──
        case "waveform":
            object["value"] = .string(poly.waveform.rawValue)
            object["effective"] = .string(poly.waveform.rawValue)
            object["default"] = .string(fresh.waveform.rawValue)
            object["values"] = .array(
                PolySynthParams.Waveform.allCases.map { .string($0.rawValue) })
            object["optional"] = .bool(false)
        case "attack":
            fill(&object, poly.attack, fresh.attack, PolySynthParams.attackRange)
        case "decay":
            fill(&object, poly.decay, fresh.decay, PolySynthParams.decayRange)
        case "sustain":
            fill(&object, poly.sustain, fresh.sustain, PolySynthParams.sustainRange)
        case "release":
            fill(&object, poly.release, fresh.release, PolySynthParams.releaseRange)
        case "cutoffHz":
            fill(&object, poly.cutoffHz, fresh.cutoffHz, PolySynthParams.cutoffRange)
        case "resonance":
            fill(&object, poly.resonance, fresh.resonance, PolySynthParams.resonanceRange)
        case "gain":
            fill(&object, poly.gain, fresh.gain, PolySynthParams.gainRange)

        // ── m34-q. THE ONE FIELD WHOSE nil IS NOT A NUMBER. `effective` is a
        // STRING ("unlimited") when no cap is set, and a number when one is;
        // `nilResolvesTo` says so too. Reporting Int.max as a JSON number
        // would be a lie a caller could do arithmetic on. ──
        case "pedalHoldLimit":
            object["optional"] = .bool(true)
            object["isSet"] = .bool(poly.pedalHoldLimit != nil)
            object["min"] = .number(Double(PolySynthParams.pedalHoldLimitRange.lowerBound))
            object["max"] = .number(Double(PolySynthParams.pedalHoldLimitRange.upperBound))
            object["integer"] = .bool(true)
            object["nilResolvesTo"] = .string("unlimited")
            object["default"] = .string("unlimited")
            if let limit = poly.pedalHoldLimit {
                object["value"] = .number(Double(limit))
                object["effective"] = .number(Double(limit))
            } else {
                object["effective"] = .string("unlimited")
            }

        // ── m39-g, all optional, all nil = musically neutral. Every
        // `nilResolvesTo` below is `fresh.effectiveX` — the SAME accessor the
        // engine reads, evaluated on an untouched struct. ──
        case "unisonVoices":
            fillInt(&object, poly.unisonVoices, poly.effectiveUnisonVoices,
                    fresh.effectiveUnisonVoices, PolySynthParams.unisonVoicesRange)
        case "unisonDetuneCents":
            fillOptional(&object, poly.unisonDetuneCents, poly.effectiveUnisonDetuneCents,
                         fresh.effectiveUnisonDetuneCents,
                         PolySynthParams.unisonDetuneCentsRange)
        case "unisonStereoSpread":
            fillOptional(&object, poly.unisonStereoSpread, poly.effectiveUnisonStereoSpread,
                         fresh.effectiveUnisonStereoSpread,
                         PolySynthParams.unisonStereoSpreadRange)
        case "subLevel":
            fillOptional(&object, poly.subLevel, poly.effectiveSubLevel,
                         fresh.effectiveSubLevel, PolySynthParams.subLevelRange)
        case "subOctave":
            fillInt(&object, poly.subOctave, poly.effectiveSubOctave,
                    fresh.effectiveSubOctave, PolySynthParams.subOctaveRange)
        case "subWaveform":
            object["optional"] = .bool(true)
            object["isSet"] = .bool(poly.subWaveform != nil)
            if let waveform = poly.subWaveform { object["value"] = .string(waveform.rawValue) }
            object["effective"] = .string(poly.effectiveSubWaveform.rawValue)
            object["nilResolvesTo"] = .string(fresh.effectiveSubWaveform.rawValue)
            object["default"] = .string(fresh.effectiveSubWaveform.rawValue)
            object["values"] = .array(
                PolySynthParams.Waveform.allCases.map { .string($0.rawValue) })
        case "noiseLevel":
            fillOptional(&object, poly.noiseLevel, poly.effectiveNoiseLevel,
                         fresh.effectiveNoiseLevel, PolySynthParams.noiseLevelRange)
        // ⚠️ ONE OF THE TWO THAT DO NOT RESOLVE TO ZERO — white noise is 0.5.
        case "noiseColor":
            fillOptional(&object, poly.noiseColor, poly.effectiveNoiseColor,
                         fresh.effectiveNoiseColor, PolySynthParams.noiseColorRange)
        case "drift":
            fillOptional(&object, poly.drift, poly.effectiveDrift,
                         fresh.effectiveDrift, PolySynthParams.driftRange)
        case "resonanceBoost":
            fillOptional(&object, poly.resonanceBoost, poly.effectiveResonanceBoost,
                         fresh.effectiveResonanceBoost, PolySynthParams.resonanceBoostRange)
        case "drive":
            fillOptional(&object, poly.drive, poly.effectiveDrive,
                         fresh.effectiveDrive, PolySynthParams.driveRange)
        case "velocityToCutoff":
            fillOptional(&object, poly.velocityToCutoff, poly.effectiveVelocityToCutoff,
                         fresh.effectiveVelocityToCutoff,
                         PolySynthParams.velocityToCutoffRange)
        case "keyToCutoff":
            fillOptional(&object, poly.keyToCutoff, poly.effectiveKeyToCutoff,
                         fresh.effectiveKeyToCutoff, PolySynthParams.keyToCutoffRange)
        case "voiceJitter":
            fillOptional(&object, poly.voiceJitter, poly.effectiveVoiceJitter,
                         fresh.effectiveVoiceJitter, PolySynthParams.voiceJitterRange)
        case "envelopeCurve":
            fillOptional(&object, poly.envelopeCurve, poly.effectiveEnvelopeCurve,
                         fresh.effectiveEnvelopeCurve, PolySynthParams.envelopeCurveRange)
        default:
            // Unreachable while `order` and this switch agree, and
            // `describeSynthDescribesEveryParameterFully` fails loudly if they
            // ever stop agreeing (an entry with no `effective` key).
            break
        }
        return .object(object)
    }

    /// One of the eight non-optional scalars: stored IS effective, and the
    /// default is `PolySynthParams()`'s.
    private static func fill(
        _ object: inout [String: JSONValue], _ value: Double, _ fresh: Double,
        _ range: ClosedRange<Double>
    ) {
        object["value"] = .number(value)
        object["effective"] = .number(value)
        object["default"] = .number(fresh)
        object["min"] = .number(range.lowerBound)
        object["max"] = .number(range.upperBound)
        object["optional"] = .bool(false)
    }

    /// One additive-optional scalar: `value` appears ONLY when set, and
    /// `nilResolvesTo` is the neutral the engine uses when it is not.
    ///
    /// ⛔ `neutral` IS ALWAYS PASSED AS `PolySynthParams().effectiveX` BY THE
    /// CALLER — the model's own accessor evaluated on a fresh struct, never a
    /// literal repeated here. Two of the fifteen do not resolve to zero
    /// (`noiseColor` → 0.5, `subOctave` → -1), so a hand-written "0" would be
    /// right thirteen times and quietly wrong twice, which is worse than being
    /// wrong every time.
    private static func fillOptional(
        _ object: inout [String: JSONValue], _ value: Double?, _ effective: Double,
        _ neutral: Double, _ range: ClosedRange<Double>
    ) {
        object["optional"] = .bool(true)
        object["isSet"] = .bool(value != nil)
        if let value { object["value"] = .number(value) }
        object["effective"] = .number(effective)
        object["nilResolvesTo"] = .number(neutral)
        object["default"] = .number(neutral)
        object["min"] = .number(range.lowerBound)
        object["max"] = .number(range.upperBound)
    }

    /// The integer twin. `integer: true` tells a caller the wire REFUSES a
    /// fractional value here rather than truncating it.
    private static func fillInt(
        _ object: inout [String: JSONValue], _ value: Int?, _ effective: Int,
        _ neutral: Int, _ range: ClosedRange<Int>
    ) {
        object["optional"] = .bool(true)
        object["isSet"] = .bool(value != nil)
        if let value { object["value"] = .number(Double(value)) }
        object["effective"] = .number(Double(effective))
        object["nilResolvesTo"] = .number(Double(neutral))
        object["default"] = .number(Double(neutral))
        object["min"] = .number(Double(range.lowerBound))
        object["max"] = .number(Double(range.upperBound))
        object["integer"] = .bool(true)
    }
}
