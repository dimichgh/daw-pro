import DAWCore
import Foundation
import Testing
@testable import DAWAppKit

// W9-DRUMDEF (m39-dm-gm-default) — the pick was `gm-pads`: a NEW drum machine plays
// the General MIDI keys, AND its pads 1–8 still play the eight drums in order.
//
// The drum machine here is BORN the way the picker births one
// (`ProjectStore.setInstrument(kind: .drumSynth)`), never hand-built, so the test
// covers the chain a person actually takes: pick Drum Machine → open the pads.
// The SEAM is spied: the mouse (`padDown`) and the letter keys (Z X C V A S D F,
// through `padNoteMap`) are two code paths, and both must send the drum the pad
// is labelled with.
//
// ⛔ AN EXTENSION OF `MusicalTypingControllerTests`, NOT A NEW SUITE (no new
// `@MainActor` suite; `PadGridTests.swift` records why). That file's helpers are
// `fileprivate`, so this file carries its own.
extension MusicalTypingControllerTests {

    fileprivate final class W9PadSpy: LiveNoteSink {
        var sets: [[Int]] = []
        var last: [Int] { sets.last ?? [] }
        func setHeldPitches(_ pitches: [Int], velocity: Int) { sets.append(pitches) }
    }

    @Test("W9-DRUMDEF: a drum machine picked from the picker plays pads 1–8 as the eight drums, on the GM keys")
    func w9PickedDrumMachinePadsAreTheEightDrums() throws {
        let store = ProjectStore()
        let id = store.addTrack(name: "Drums", kind: .instrument).id
        _ = try store.setInstrument(id: id, kind: .drumSynth)
        let born = try #require(store.tracks.first { $0.id == id }?.instrument)
        #expect(born.resolvedDrumKit.noteLayout == .gm, "the picked drum machine is not on the GM keys")

        let order: [DrumVoice] = [.kick, .snare, .closedHat, .openHat, .clap, .tom, .rim, .cymbal]
        let gmNotes = [36, 38, 42, 46, 39, 45, 37, 49]
        // The pure map.
        let pads = try #require(PadGridDrumMap.drumMachinePads(for: born))
        let padVoices = pads.map { $0.voice }
        let padNotes = pads.map { $0.note }
        #expect(padVoices == order)
        #expect(padNotes == gmNotes)

        // The model, the mouse and the keys, with a spy on the seam.
        let sink = W9PadSpy()
        let controller = MusicalTypingController(sink: sink)
        controller.targetState = .ready
        controller.setEnabled(true)
        controller.setPlayMode(.pads)
        let model = PadGridModel(typing: controller, zones: { [] }, targetName: { "Drums" },
                                 instrument: { born })
        var mouse: [Int] = []
        var keys: [Int] = []
        withExtendedLifetime(model) {
            for index in 0..<8 {
                model.padDown(index: index, normalizedY: 0.5)
                mouse.append(sink.last.first ?? -1)
                model.padUp()
            }
            for label in ["Z", "X", "C", "V", "A", "S", "D", "F"] {
                guard let cap = MusicalTypingRouting.padAllCaps.first(where: { $0.label == label }) else {
                    Issue.record("'\(label)' is not a pads-mode key")
                    continue
                }
                _ = controller.handleKeyDown(keyCode: cap.keyCode, modifiers: [], isRepeat: false,
                                             responder: .none, window: .main)
                keys.append(sink.last.first ?? -1)
                _ = controller.releaseKey(keyCode: cap.keyCode)
            }
        }
        #expect(mouse == gmNotes, "the mouse sent \(mouse)")
        #expect(keys == gmNotes, "the keys sent \(keys)")
        let heardVoices = mouse.map { DrumVoice.voice(forNote: UInt8(clamping: $0), layout: .gm) }
        #expect(heardVoices == order.map { Optional($0) }, "control: each GM note really is that drum")
        let labels = model.pads.prefix(8).map { $0.drumLabel }
        #expect(labels == order.map { Optional($0.displayName) },
                "a pad is labelled with a different drum than it plays")
    }
}
