import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m39-w4-2 P1 — "A ROW LABELLED X PLAYS X", by render.
/// `docs/design/2026-10-07-loop-drum-depth.md` §9.2.
///
/// For both note layouts, every row of `DrumLaneMap.lanes(for:)` on our drum
/// machine is rendered ALONE through `DrumSynthInstrument`, and must be
/// bit-equal to a render of the voice its LABEL names, at that voice's known
/// note. Three choices make the gate able to fail:
///  - the voice is resolved FROM THE LABEL (`DrumVoice.displayName`), never
///    from `lane.voice`: a row whose label and note disagree is the defect;
///  - the known notes are HAND-TYPED here, never `primaryNote(in:)`;
///  - every reference must actually sound (peak above -40 dBFS), and the eight
///    references must be pairwise bit-distinct, so equality cannot be met by
///    two silent buffers or by a kit whose voices all sound alike.
///
/// MEASURED before this file (W8-W42, 2026-10-07, `DrumNoteLayoutRenderTests`
/// probe): all 22 GM notes render the very bits of their voice's pads render,
/// because a voice's noise seed keys on the note-on sample and the voice slot,
/// never on the note.
///
/// nonisolated: the harness (`DrumNoteLayoutRenderTests.render`) is.
@Suite("Drum lane map — P1: a row labelled X plays X (m39-w4-2)", .serialized)
struct DrumLaneMapRenderTests {

    /// The note each voice is KNOWN to answer, per layout. Hand-typed: pads is
    /// the drum machine's own order (36–43), gm the General MIDI names
    /// (Bass Drum 1, Side Stick, Acoustic Snare, Hand Clap, Closed Hi-Hat,
    /// Low Tom, Open Hi-Hat, Crash Cymbal 1).
    static let knownNote: [DrumNoteLayout: [DrumVoice: UInt8]] = [
        .pads: [.kick: 36, .snare: 37, .closedHat: 38, .openHat: 39,
                .clap: 40, .tom: 41, .rim: 42, .cymbal: 43],
        .gm: [.kick: 36, .rim: 37, .snare: 38, .clap: 39,
              .closedHat: 42, .tom: 45, .openHat: 46, .cymbal: 49],
    ]

    /// -40 dBFS: a reference quieter than this is treated as silence.
    static let silenceBar: Float = 0.01

    static func bits(_ samples: [Float]) -> [UInt32] { samples.map(\.bitPattern) }

    static func peak(_ samples: [Float]) -> Float { samples.map { abs($0) }.max() ?? 0 }

    /// One hit of `note` at sample 0 on `kit`, both channels concatenated, as bits.
    static func hitBits(_ note: UInt8, kit: DrumKitParams) async throws -> (bits: [UInt32], peak: Float) {
        let channels = try await DrumNoteLayoutRenderTests.render(
            DrumNoteLayoutRenderTests.makeDrums(kit),
            events: [DrumNoteLayoutRenderTests.noteOn(note, at: 0, id: 1)],
            frames: Int(1.0 * DrumNoteLayoutRenderTests.sampleRate))
        let both = channels[0] + channels[1]
        return (bits(both), peak(both))
    }

    @Test("P1: every row of a drum machine plays the drum its label names, in both layouts",
          arguments: DrumNoteLayout.allCases)
    func everyRowPlaysWhatItsLabelSays(layout: DrumNoteLayout) async throws {
        var kit = DrumKitParams()
        kit.noteLayout = layout
        let instrument = InstrumentDescriptor(kind: .drumSynth, drumKit: kit)
        let lanes = try #require(DrumLaneMap.lanes(for: instrument))
        let known = try #require(Self.knownNote[layout])
        #expect(lanes.count == 8)

        // References: each voice at its known note. Each must sound, and no
        // two may be alike (else equality below proves nothing).
        var references: [DrumVoice: [UInt32]] = [:]
        for voice in DrumVoice.allCases {
            let note = try #require(known[voice])
            let reference = try await Self.hitBits(note, kit: kit)
            #expect(reference.peak > Self.silenceBar,
                    "\(layout) \(voice) at \(note) is silent (peak \(reference.peak)): the gate could pass on silence")
            references[voice] = reference.bits
        }
        // ⚠️ Every array comparison is made OUTSIDE `#expect` and the macro
        // gets a Bool. Handed two 96 000-sample arrays, a failing `#expect`
        // diffs the collections for its message: MEASURED 2026-10-07 under the
        // label-swap plant, this suite took 479 s to fail instead of ~5 s.
        let voices = DrumVoice.allCases
        for i in voices.indices {
            for j in voices.indices where j > i {
                let alike = references[voices[i]] == references[voices[j]]
                #expect(!alike, "\(layout): \(voices[i]) and \(voices[j]) render the same bits")
            }
        }

        // The gate: the row's note, rendered alone, IS the labelled drum.
        var labelsSeen: Set<String> = []
        for lane in lanes {
            let named = DrumVoice.allCases.filter { $0.displayName == lane.label }
            #expect(named.count == 1, "\(layout) row \(lane.note) label \(lane.label) names no single drum")
            guard let labelled = named.first,
                  let reference = references[labelled],
                  let note = UInt8(exactly: lane.note) else { continue }
            labelsSeen.insert(lane.label)
            let candidate = try await Self.hitBits(note, kit: kit)
            let playsTheLabelledDrum = candidate.bits == reference
            #expect(playsTheLabelledDrum,
                    "\(layout): the row labelled \(lane.label) (note \(lane.note)) does not play the \(labelled)")
        }
        #expect(labelsSeen.count == 8, "\(layout): rows do not name all eight drums: \(labelsSeen.sorted())")
    }
}
