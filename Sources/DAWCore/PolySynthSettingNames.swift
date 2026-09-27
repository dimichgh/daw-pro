import Foundation

// m39-tpl-1 (docs/design/2026-09-27-multi-instrument-templates.md §4.5, §5.2):
// the Poly Synth's 24 setting names, and what each name is, in DAWCore.
//
// ⭐ The names list MOVED HERE from DAWControl's `PolySynthDescription.order`,
// VERBATIM and in the same order (oscillator, envelope, filter, output, then the
// m39-g richness groups). `instrument.describeSynth` still publishes it as
// `order`, which now forwards here, so its reply is unchanged. A template file
// is decoded in DAWCore, which cannot see DAWControl, and a second hand-typed
// list of 24 names is exactly the shape that drifts.
//
// The ranges were already here (`PolySynthParams.attackRange` …); this file adds
// only the name → property table that joins a name to its range and field.

public extension PolySynthParams {
    /// ⭐ THE 24 SETTING NAMES, in the order a human would want to read them.
    /// Each is also the stored property's name and the flat key
    /// `track.setInstrument` takes.
    static let settingNames: [String] = [
        "waveform", "attack", "decay", "sustain", "release",
        "cutoffHz", "resonance", "gain", "pedalHoldLimit",
        "unisonVoices", "unisonDetuneCents", "unisonStereoSpread",
        "subLevel", "subOctave", "subWaveform",
        "noiseLevel", "noiseColor", "drift",
        "resonanceBoost", "drive", "velocityToCutoff", "keyToCutoff",
        "voiceJitter", "envelopeCurve",
    ]

    /// What kind of value one named setting holds.
    enum SettingKind: Sendable, Equatable {
        /// A number in this range.
        case number(ClosedRange<Double>)
        /// A whole number in this range. The wire refuses a fractional value
        /// rather than truncating it (`Int(2.9)` is 2, silently).
        case integer(ClosedRange<Int>)
        /// One of `Waveform`'s names.
        case waveform
    }

    /// The name → property table: what `name` holds, or nil for a name that is
    /// not a Poly Synth setting. Every range is read from the model's own
    /// `static let`, never re-typed.
    static func settingKind(named name: String) -> SettingKind? {
        switch name {
        case "waveform", "subWaveform": return .waveform
        case "attack": return .number(attackRange)
        case "decay": return .number(decayRange)
        case "sustain": return .number(sustainRange)
        case "release": return .number(releaseRange)
        case "cutoffHz": return .number(cutoffRange)
        case "resonance": return .number(resonanceRange)
        case "gain": return .number(gainRange)
        case "pedalHoldLimit": return .integer(pedalHoldLimitRange)
        case "unisonVoices": return .integer(unisonVoicesRange)
        case "unisonDetuneCents": return .number(unisonDetuneCentsRange)
        case "unisonStereoSpread": return .number(unisonStereoSpreadRange)
        case "subLevel": return .number(subLevelRange)
        case "subOctave": return .integer(subOctaveRange)
        case "noiseLevel": return .number(noiseLevelRange)
        case "noiseColor": return .number(noiseColorRange)
        case "drift": return .number(driftRange)
        case "resonanceBoost": return .number(resonanceBoostRange)
        case "drive": return .number(driveRange)
        case "velocityToCutoff": return .number(velocityToCutoffRange)
        case "keyToCutoff": return .number(keyToCutoffRange)
        case "voiceJitter": return .number(voiceJitterRange)
        case "envelopeCurve": return .number(envelopeCurveRange)
        default: return nil
        }
    }

    /// Writes one named NUMBER or INTEGER setting, as given: no clamp, no
    /// rounding. Callers check the value against `settingKind(named:)` first.
    /// Returns false, changing nothing, for a name that holds a waveform, for
    /// an unknown name, or for a fractional value on an integer setting.
    @discardableResult
    mutating func setSetting(_ name: String, number value: Double) -> Bool {
        switch Self.settingKind(named: name) {
        case .number:
            break
        case .integer:
            guard value.isFinite, value.rounded() == value,
                  let whole = Int(exactly: value) else { return false }
            switch name {
            case "pedalHoldLimit": pedalHoldLimit = whole
            case "unisonVoices": unisonVoices = whole
            case "subOctave": subOctave = whole
            default: return false
            }
            return true
        case .waveform, nil:
            return false
        }
        switch name {
        case "attack": attack = value
        case "decay": decay = value
        case "sustain": sustain = value
        case "release": release = value
        case "cutoffHz": cutoffHz = value
        case "resonance": resonance = value
        case "gain": gain = value
        case "unisonDetuneCents": unisonDetuneCents = value
        case "unisonStereoSpread": unisonStereoSpread = value
        case "subLevel": subLevel = value
        case "noiseLevel": noiseLevel = value
        case "noiseColor": noiseColor = value
        case "drift": drift = value
        case "resonanceBoost": resonanceBoost = value
        case "drive": drive = value
        case "velocityToCutoff": velocityToCutoff = value
        case "keyToCutoff": keyToCutoff = value
        case "voiceJitter": voiceJitter = value
        case "envelopeCurve": envelopeCurve = value
        default: return false
        }
        return true
    }

    /// Writes one named WAVEFORM setting (`waveform` or `subWaveform`). Returns
    /// false, changing nothing, for any other name.
    @discardableResult
    mutating func setSetting(_ name: String, waveform value: Waveform) -> Bool {
        switch name {
        case "waveform": waveform = value
        case "subWaveform": subWaveform = value
        default: return false
        }
        return true
    }

    /// Reads one named NUMBER or INTEGER setting back as stored: nil for an
    /// optional setting that is not set, a waveform name, or an unknown name.
    func settingNumber(_ name: String) -> Double? {
        switch name {
        case "attack": return attack
        case "decay": return decay
        case "sustain": return sustain
        case "release": return release
        case "cutoffHz": return cutoffHz
        case "resonance": return resonance
        case "gain": return gain
        case "pedalHoldLimit": return pedalHoldLimit.map(Double.init)
        case "unisonVoices": return unisonVoices.map(Double.init)
        case "unisonDetuneCents": return unisonDetuneCents
        case "unisonStereoSpread": return unisonStereoSpread
        case "subLevel": return subLevel
        case "subOctave": return subOctave.map(Double.init)
        case "noiseLevel": return noiseLevel
        case "noiseColor": return noiseColor
        case "drift": return drift
        case "resonanceBoost": return resonanceBoost
        case "drive": return drive
        case "velocityToCutoff": return velocityToCutoff
        case "keyToCutoff": return keyToCutoff
        case "voiceJitter": return voiceJitter
        case "envelopeCurve": return envelopeCurve
        default: return nil
        }
    }

    /// Reads one named WAVEFORM setting back as stored: nil for an unset
    /// `subWaveform` or any other name.
    func settingWaveform(_ name: String) -> Waveform? {
        switch name {
        case "waveform": return waveform
        case "subWaveform": return subWaveform
        default: return nil
        }
    }
}
