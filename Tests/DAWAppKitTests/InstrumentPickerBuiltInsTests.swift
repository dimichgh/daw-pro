import DAWCore
import Foundation
import Testing
@testable import DAWAppKit

/// m39-dm — THE PIN ON `InstrumentPickerModel.builtIns`, WHICH IS A HAND-BUILT
/// ARRAY LITERAL THAT NO COMPILER CHECKS.
///
/// ⛔ Adding a case to `InstrumentDescriptor.Kind` does NOT break that file. A
/// kind missing from the list is fully functional over the wire and INVISIBLE
/// IN THE UI — a wire-only feature, with no compile error, no runtime error,
/// and nothing to grep for. The design's site census calls this out as Class B1
/// for exactly that reason.
///
/// Derived from `Kind.allCases` so it cannot go stale: it fails the day a kind
/// is added without touching the picker, and needs no edit when one is added
/// correctly.
@MainActor
@Suite("Instrument picker — built-in coverage")
struct InstrumentPickerBuiltInsTests {

    private static func makeModel() -> InstrumentPickerModel {
        InstrumentPickerModel(
            soundBanks: { [] },
            programs: { _ in (programs: [], namesParsed: false) },
            audioUnits: { [] },
            importer: { _ in throw CancellationError() })
    }

    /// The kinds that are deliberately NOT offered as built-ins, each with a
    /// reason. Listing them here rather than filtering silently is the point:
    /// a future kind lands in the failure message, not in this set.
    private static let deliberatelyAbsent: Set<InstrumentDescriptor.Kind> = [
        // Hosted: chosen through the Audio Unit / Sound Bank sections of the
        // same picker, not through the built-in rows.
        .audioUnit, .soundBank,
    ]

    @Test("Every non-hosted instrument kind is offered as a built-in")
    func builtInsCoverEveryKind() {
        let model = Self.makeModel()
        model.density = .pro  // Simple hides Test Tone; Pro shows everything.
        let offered = Set(model.builtIns.map(\.kind))
        let expected = Set(InstrumentDescriptor.Kind.allCases)
            .subtracting(Self.deliberatelyAbsent)
        #expect(offered == expected,
                Comment(rawValue: "the picker offers \(offered.map(\.rawValue).sorted()) but "
                    + "the non-hosted kinds are \(expected.map(\.rawValue).sorted()) — a kind "
                    + "the picker cannot name is a kind a user can never select"))
        // NON-VACUITY: the list is not empty and the exclusions are real
        // rather than the subtraction being a no-op.
        #expect(offered.count >= 3)
        #expect(offered.isDisjoint(with: Self.deliberatelyAbsent))
    }

    @Test("The drum machine is offered with a beginner-readable name and detail")
    func drumMachineIsOffered() throws {
        let model = Self.makeModel()
        let entry = try #require(model.builtIns.first { $0.kind == .drumSynth })
        #expect(entry.name == "Drum Machine")
        // `docs/DESIGN-LANGUAGE.md`: beginner-readable labels. The detail line
        // must say what it DOES, in words a novice reads, not name a topology.
        #expect(entry.detail.isEmpty == false)
        #expect(entry.detail.lowercased().contains("kick"))
        #expect(entry.detail.lowercased().contains("snare"))
    }

    /// It must also survive the Simple density, which hides Test Tone — a
    /// beginner-facing product should reach a drum kit without switching to Pro.
    @Test("The drum machine is visible at Simple density")
    func drumMachineVisibleInSimple() {
        let model = Self.makeModel()
        model.density = .simple
        #expect(model.builtIns.contains { $0.kind == .drumSynth })
        #expect(model.builtIns.contains { $0.kind == .testTone } == false,
                "Simple density should still hide the engine-test instrument")
    }

    @Test("displayName answers for every kind, with no empty string")
    func displayNameCoversEveryKind() {
        for kind in InstrumentDescriptor.Kind.allCases {
            let name = InstrumentPickerModel.displayName(
                for: InstrumentDescriptor(kind: kind))
            #expect(name.isEmpty == false, "\(kind.rawValue) has no display name")
        }
        #expect(InstrumentPickerModel.displayName(
            for: InstrumentDescriptor(kind: .drumSynth)) == "Drum Machine")
    }
}
