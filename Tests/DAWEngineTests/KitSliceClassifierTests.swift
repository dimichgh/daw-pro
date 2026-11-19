import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

// m39-w4-6 — gate C4, design `docs/design/2026-10-07-loop-drum-depth.md` §9.2: OUR DRUM MACHINE AS GROUND
// TRUTH. Every voice of all five factory kits, one hit per fresh offline render at velocity 100, sliced at
// 0.5 s, measured by `SliceTimbreAnalyzer` and judged by the frozen `DrumHitClassifier`. Pre-registered bar:
// kick 5/5, snare 5/5, closed hat ≥ 4/5, open hat ≥ 4/5; clap, tom, rim and cymbal may land on their nearest
// role or on "other", and a cymbal NEVER on kick. The full confusion matrix is printed (`W46-C4` lines).
//
// Nonisolated suite; the renderer is reached through `KitSliceFitW46Tests.render` (`@MainActor static`).
@Suite("Kit slicing — C4: our drum machine as ground truth (m39-w4-6)", .serialized)
struct KitSliceClassifierTests {

    @Test("C4: kick 5/5, snare 5/5, closed hat ≥ 4/5, open hat ≥ 4/5 over the five kits; a cymbal is never a kick")
    func drumMachineIsSortedRight() async throws {
        var matrix: [DrumVoice: [KitSliceRole: Int]] = [:]
        var kits = 0
        for preset in DrumKitParams.presets {
            kits += 1
            var kit = preset.params
            kit.noteLayout = .gm
            for (voice, note) in KitSliceFitW46Tests.gmNote {
                let mono = try await KitSliceFitW46Tests.render(
                    InstrumentDescriptor(kind: .drumSynth, drumKit: kit), note: note)
                let timbre = KitSliceFitW46Tests.measure(mono, seconds: 0.5)
                #expect(timbre.peak > 0.01, "control: \(preset.name) \(voice) sounded (peak \(timbre.peak))")
                let verdict = DrumHitClassifier.classify(timbre)
                let role = KitSliceRole(verdict.role)
                matrix[voice, default: [:]][role, default: 0] += 1
                print("W46-C4 \(preset.name)\t\(voice.rawValue)\t→ \(role.rawValue)\t"
                      + String(format: "%.3f", verdict.confidence))
            }
        }
        #expect(kits == 5, "control: five factory kits")
        for voice in DrumVoice.allCases {
            let row = KitSliceRole.allCases.map { "\($0.rawValue)=\(matrix[voice]?[$0] ?? 0)" }
            print("W46-C4 matrix \(voice.rawValue): \(row.joined(separator: " "))")
        }
        #expect(matrix[.kick]?[.kick] == 5)
        #expect(matrix[.snare]?[.snare] == 5)
        #expect((matrix[.closedHat]?[.closedHat] ?? 0) >= 4)
        #expect((matrix[.openHat]?[.openHat] ?? 0) >= 4)
        #expect(matrix[.cymbal]?[.kick] == nil, "a cymbal must never be sorted onto the kick")
    }
}
