import CoreGraphics
import Foundation
import DAWCore

/// Which console lane a strip represents. Channels (audio + instrument) come
/// first in project order, then the visually-grouped buses, then the single
/// pinned master. UI-free so the console's ordering + section rules unit-test
/// headless (Sources/DAWAppKit) while `MixerView` stays thin over it.
public enum MixerStripKind: String, Sendable, Equatable {
    case channel
    case bus
    case master
}

/// One entry in a source track's output-routing picker.
public struct MixerOutputOption: Identifiable, Sendable, Equatable {
    /// Destination bus id, or nil for the main mix ("Master").
    public let busID: UUID?
    public let name: String
    public var id: String { busID?.uuidString ?? "master" }

    public init(busID: UUID?, name: String) {
        self.busID = busID
        self.name = name
    }
}

/// Console layout derivation: turns the flat `tracks` array into the ordered
/// strip lanes and resolves the routing menus. Pure functions over value inputs
/// so previews, the live app, and the test suite share one source of truth.
public enum MixerLayout {
    /// Audio + instrument tracks in project order — the left block of strips.
    public static func channelTracks(_ tracks: [Track]) -> [Track] {
        tracks.filter { $0.kind == .audio || $0.kind == .instrument }
    }

    /// Bus tracks in project order — the visually-distinct middle group.
    public static func busTracks(_ tracks: [Track]) -> [Track] {
        tracks.filter { $0.kind == .bus }
    }

    /// The console lanes, left to right: channels, then buses. Master is drawn
    /// separately (pinned) since it has no backing `Track`.
    public static func orderedStrips(_ tracks: [Track]) -> [Track] {
        channelTracks(tracks) + busTracks(tracks)
    }

    /// Output-routing options for a source track: "Master" plus every bus
    /// (buses can't be re-routed, so this is only meaningful for channels).
    public static func outputOptions(in tracks: [Track]) -> [MixerOutputOption] {
        [MixerOutputOption(busID: nil, name: "Master")]
            + busTracks(tracks).map { MixerOutputOption(busID: $0.id, name: $0.name) }
    }

    /// Display name of a track's current output ("Master" or the bus name).
    public static func outputName(for track: Track, in tracks: [Track]) -> String {
        guard let busID = track.outputBusID else { return "Master" }
        return tracks.first { $0.id == busID }?.name ?? "Master"
    }

    /// Buses a track can still send to: every bus it isn't already sending to.
    public static func availableSendBuses(for track: Track, in tracks: [Track]) -> [Track] {
        let taken = Set(track.sends.map(\.destinationBusID))
        return busTracks(tracks).filter { !taken.contains($0.id) }
    }

    /// Destination bus name for a send row.
    public static func sendDestinationName(_ send: Send, in tracks: [Track]) -> String {
        tracks.first { $0.id == send.destinationBusID }?.name ?? "Bus"
    }
}

/// Numeric formatting for the digital readouts (SF Mono, glowing) under the
/// fader, pan knob, and sends — all beginner-readable per DESIGN-LANGUAGE rule 6.
public enum MixerFormat {
    /// Linear gain → a decibel string: `1.0` → `"0.0"`, `2.0` → `"+6.0"`,
    /// `0.5` → `"-6.0"`, and anything at/below the silence floor → `"-∞"`.
    /// One decimal, explicit `+` above unity. Used for both faders and sends.
    public static func dbString(forGain gain: Double) -> String {
        guard gain > 0.0001 else { return "-∞" }
        let db = 20 * log10(gain)
        let rounded = (db * 10).rounded() / 10
        if rounded == 0 { return "0.0" }          // fold -0.0 → "0.0"
        let sign = rounded > 0 ? "+" : ""
        return sign + String(format: "%.1f", rounded)
    }

    /// Pan → a compact side/percent readout: `0` → `"C"`, `-1` → `"L100"`,
    /// `1` → `"R100"`, `0.5` → `"R50"`. Center dead-zone avoids a jittery
    /// "L0"/"R0" around the detent.
    public static func panString(_ pan: Double) -> String {
        if abs(pan) < 0.005 { return "C" }
        let magnitude = Int((abs(pan) * 100).rounded())
        return (pan < 0 ? "L" : "R") + String(magnitude)
    }

    /// Beginner-readable insert name. Built-ins spell out in full; a hosted
    /// Audio Unit shows its own display name (falling back to "Audio Unit").
    public static func effectDisplayName(_ effect: EffectDescriptor) -> String {
        switch effect.kind {
        case .gain: return "Gain"
        case .eq: return "EQ"
        case .compressor: return "Compressor"
        case .limiter: return "Limiter"
        case .reverb: return "Reverb"
        case .delay: return "Delay"
        case .saturator: return "Saturator"
        case .gate: return "Gate"
        case .chorus: return "Chorus"
        case .audioUnit:
            let name = effect.audioUnit?.name ?? ""
            return name.isEmpty ? "Audio Unit" : name
        }
    }

    /// Small kind badge text (color-coded elsewhere; violet is never used for a
    /// kind — it is reserved for AI-generated content).
    public static func kindBadge(_ kind: TrackKind) -> String {
        switch kind {
        case .audio: return "AUDIO"
        case .instrument: return "INSTRUMENT"
        case .bus: return "BUS"
        }
    }
}

/// Fader / knob / meter geometry. Linear gain ↔ travel mapping matches the
/// existing `MasterVolumeFader` (unity at half-travel over `Track.volumeRange`
/// 0…2), so the whole app shares one taper.
public enum MixerMath {
    /// The gain range the volume faders drive (matches the store's clamp).
    public static let volumeRange = Track.volumeRange

    /// Travel fraction (0 = bottom, 1 = top) for a linear gain in `range`.
    public static func fraction(forGain gain: Double,
                                in range: ClosedRange<Double> = Track.volumeRange) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return ((gain - range.lowerBound) / span).clamped(to: 0...1)
    }

    /// Linear gain for a travel fraction, clamped into `range`.
    public static func gain(forFraction fraction: Double,
                            in range: ClosedRange<Double> = Track.volumeRange) -> Double {
        let f = fraction.clamped(to: 0...1)
        return (range.lowerBound + f * (range.upperBound - range.lowerBound)).clamped(to: range)
    }

    /// Travel fraction of the unity (1.0) detent within `range` — where the
    /// fader draws its "0 dB" tick.
    public static func unityFraction(in range: ClosedRange<Double> = Track.volumeRange) -> Double {
        fraction(forGain: 1, in: range)
    }

    /// New travel fraction after dragging `dragPoints` (positive = up) over a
    /// fader/knob whose full throw is `throwPoints` tall. Clamped 0…1.
    public static func adjustedFraction(start: Double, dragPoints: Double,
                                        throwPoints: Double) -> Double {
        guard throwPoints > 0 else { return start.clamped(to: 0...1) }
        return (start + dragPoints / throwPoints).clamped(to: 0...1)
    }

    /// Knob arc angle in degrees for a fraction over a 270° sweep with a gap at
    /// the bottom: `0` → 135°, `0.5` → 270° (straight up), `1` → 405°.
    public static func knobAngleDegrees(forFraction fraction: Double) -> Double {
        135 + fraction.clamped(to: 0...1) * 270
    }
}
