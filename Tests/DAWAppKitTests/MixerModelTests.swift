import Foundation
import Testing
@testable import DAWAppKit
import DAWCore

/// Unit tests for the headless mixer view-model: strip ordering / bus grouping,
/// routing-menu derivation, and the digital-readout + fader-taper math. The
/// SwiftUI console (`MixerView`) is thin over this, so exercising it here covers
/// the mixer's logic without a display.
@Suite("MixerModel")
struct MixerModelTests {

    private func track(_ name: String, _ kind: TrackKind,
                       sends: [Send] = [], output: UUID? = nil) -> Track {
        Track(name: name, kind: kind, outputBusID: output, sends: sends)
    }

    // MARK: - Layout / ordering

    @Test("channels come first in project order, then buses grouped after")
    func stripOrdering() {
        let a = track("Drums", .audio)
        let bus = track("Reverb Bus", .bus)
        let inst = track("Synth", .instrument)
        let tracks = [a, bus, inst]   // deliberately interleaved

        #expect(MixerLayout.channelTracks(tracks).map(\.name) == ["Drums", "Synth"])
        #expect(MixerLayout.busTracks(tracks).map(\.name) == ["Reverb Bus"])
        // Ordered strips: channels (in order) then buses (in order).
        #expect(MixerLayout.orderedStrips(tracks).map(\.name) == ["Drums", "Synth", "Reverb Bus"])
    }

    @Test("output options are Master plus every bus")
    func outputOptions() {
        let busA = track("A Bus", .bus)
        let busB = track("B Bus", .bus)
        let tracks = [track("Vox", .audio), busA, busB]
        let options = MixerLayout.outputOptions(in: tracks)
        #expect(options.map(\.name) == ["Master", "A Bus", "B Bus"])
        #expect(options.first?.busID == nil)                 // Master is the nil route
        #expect(options[1].busID == busA.id)
    }

    @Test("output name resolves the current route")
    func outputName() {
        let bus = track("FX", .bus)
        let routed = track("Vox", .audio, output: bus.id)
        let dry = track("Kick", .audio)
        let tracks = [routed, dry, bus]
        #expect(MixerLayout.outputName(for: routed, in: tracks) == "FX")
        #expect(MixerLayout.outputName(for: dry, in: tracks) == "Master")
        // A dangling bus id falls back to Master rather than showing a UUID.
        let orphan = track("Ghost", .audio, output: UUID())
        #expect(MixerLayout.outputName(for: orphan, in: [orphan]) == "Master")
    }

    @Test("available send buses exclude ones already targeted")
    func availableSendBuses() {
        let busA = track("A", .bus)
        let busB = track("B", .bus)
        let source = track("Vox", .audio, sends: [Send(destinationBusID: busA.id)])
        let tracks = [source, busA, busB]
        #expect(MixerLayout.availableSendBuses(for: source, in: tracks).map(\.name) == ["B"])
        #expect(MixerLayout.sendDestinationName(source.sends[0], in: tracks) == "A")
    }

    // MARK: - dB formatting

    @Test("dbString maps gain to a signed decibel readout with a silence floor")
    func dbFormatting() {
        #expect(MixerFormat.dbString(forGain: 1.0) == "0.0")
        #expect(MixerFormat.dbString(forGain: 2.0) == "+6.0")
        #expect(MixerFormat.dbString(forGain: 0.5) == "-6.0")
        #expect(MixerFormat.dbString(forGain: 0.0) == "-∞")
        #expect(MixerFormat.dbString(forGain: -1.0) == "-∞")
        // Unity-adjacent gains fold to "0.0" (no -0.0 artifact).
        #expect(MixerFormat.dbString(forGain: 1.001) == "0.0")
    }

    @Test("panString reads C / L## / R##")
    func panFormatting() {
        #expect(MixerFormat.panString(0) == "C")
        #expect(MixerFormat.panString(-1) == "L100")
        #expect(MixerFormat.panString(1) == "R100")
        #expect(MixerFormat.panString(0.5) == "R50")
        #expect(MixerFormat.panString(-0.5) == "L50")
        #expect(MixerFormat.panString(0.002) == "C")   // center dead-zone
    }

    // MARK: - Effect naming

    @Test("effect display names are beginner-readable; hosted AU shows its name")
    func effectNaming() {
        #expect(MixerFormat.effectDisplayName(EffectDescriptor(kind: .eq)) == "EQ")
        #expect(MixerFormat.effectDisplayName(EffectDescriptor(kind: .compressor)) == "Compressor")
        let au = AudioUnitConfig(
            component: AudioUnitComponentID(type: "aufx", subType: "dcmp", manufacturer: "appl"),
            name: "AUDynamicsProcessor"
        )
        #expect(MixerFormat.effectDisplayName(EffectDescriptor(kind: .audioUnit, audioUnit: au))
                == "AUDynamicsProcessor")
        // A componentless / unnamed AU falls back to a readable label.
        #expect(MixerFormat.effectDisplayName(EffectDescriptor(kind: .audioUnit)) == "Audio Unit")
    }

    // MARK: - Fader / knob math

    @Test("fader taper puts unity at half travel over 0...2 and round-trips")
    func faderTaper() {
        #expect(MixerMath.fraction(forGain: 1.0) == 0.5)       // unity mid-travel
        #expect(MixerMath.fraction(forGain: 0.0) == 0.0)
        #expect(MixerMath.fraction(forGain: 2.0) == 1.0)
        #expect(MixerMath.unityFraction() == 0.5)
        // Round-trip fraction → gain → fraction.
        for f in [0.0, 0.25, 0.5, 0.8, 1.0] {
            let g = MixerMath.gain(forFraction: f)
            #expect(abs(MixerMath.fraction(forGain: g) - f) < 1e-9)
        }
        // Clamping past the ends.
        #expect(MixerMath.gain(forFraction: 1.5) == 2.0)
        #expect(MixerMath.gain(forFraction: -1) == 0.0)
    }

    @Test("adjustedFraction moves with the drag and clamps to 0...1")
    func dragMath() {
        // Dragging up (positive points) over a 200pt throw raises the fraction.
        #expect(abs(MixerMath.adjustedFraction(start: 0.5, dragPoints: 100, throwPoints: 200) - 1.0) < 1e-9)
        #expect(abs(MixerMath.adjustedFraction(start: 0.5, dragPoints: -50, throwPoints: 200) - 0.25) < 1e-9)
        // Clamps rather than overshooting.
        #expect(MixerMath.adjustedFraction(start: 0.9, dragPoints: 500, throwPoints: 200) == 1.0)
        #expect(MixerMath.adjustedFraction(start: 0.1, dragPoints: -500, throwPoints: 200) == 0.0)
    }

    @Test("knob sweep is 270 degrees with the gap at the bottom")
    func knobSweep() {
        #expect(MixerMath.knobAngleDegrees(forFraction: 0) == 135)
        #expect(MixerMath.knobAngleDegrees(forFraction: 0.5) == 270)   // straight up
        #expect(MixerMath.knobAngleDegrees(forFraction: 1) == 405)
    }
}
