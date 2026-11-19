import Foundation
import Testing

/// m39-w4-3 — a SOURCE-SHAPE gate on the one place the entry velocity's
/// predicate can still be chosen wrong: the view.
///
/// `NoteEntryDefaults` takes the drum LANE LIST, and the headless tests prove
/// both editors read it. What no headless test can see is which value the view
/// hands it. `PianoRollView` holds BOTH `isDrumKit` (the export question, which
/// our `pads` drum machine answers "no") and `drumLanes` (the lane map), side by
/// side. This pins that every note-minting call in the view passes the lane
/// list, and that `isDrumKit` never reaches one. It is a source-shape gate, the
/// weaker kind: it reads text, not behaviour, and says so.
///
/// Deliberately NOT `@MainActor`: it reads files.
@Suite("Note entry sites (m39-w4-3)")
struct NoteEntrySiteTests {

    static let rollPath = "Sources/DAWApp/PianoRoll/PianoRollView.swift"

    static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DAWAppKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    /// The file with `//` comment lines dropped, so a comment that mentions
    /// `isDrumKit` cannot fail the gate and a commented-out call cannot pass it.
    static func code(_ relative: String) throws -> String {
        let text = try String(contentsOf: repoRoot().appendingPathComponent(relative), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The argument text of every call to `name(` in `code`, by paren depth.
    static func calls(_ name: String, in code: String) -> [String] {
        var found: [String] = []
        var search = code.startIndex
        while let open = code.range(of: name + "(", range: search..<code.endIndex) {
            var depth = 1
            var index = open.upperBound
            while index < code.endIndex, depth > 0 {
                switch code[index] {
                case "(": depth += 1
                case ")": depth -= 1
                default: break
                }
                index = code.index(after: index)
            }
            found.append(String(code[open.upperBound..<index]))
            search = index
        }
        return found
    }

    @Test("m39-w4-3 — every note the piano roll view mints asks the entry velocity with the drum LANE LIST, never with isDrumKit")
    func rollEntrySitesPassTheLaneList() throws {
        let roll = try Self.code(Self.rollPath)
        // ANTI-VACUITY: the census this gate rests on (2026-10-07): one roll
        // add (`model.addNote(`) and one step-grid geometry (`.make(`, fed to
        // the toggle and the Accent row). A walk that found none would pass.
        let adds = Self.calls("model.addNote", in: roll)
        #expect(adds.count == 1, "expected 1 `model.addNote(` call in PianoRollView, found \(adds.count)")
        let grids = Self.calls("StepSequencerGeometry.make", in: roll)
        #expect(grids.count == 1, "expected 1 `StepSequencerGeometry.make(` call, found \(grids.count)")
        for call in adds + grids {
            #expect(call.contains("drumLanes: drumLanes"), "a minting call lost the lane list: \(call)")
            #expect(!call.contains("isDrumKit"), "isDrumKit reached a minting call: \(call)")
        }
        // The toggle and the Accent row read the geometry the view built; they
        // must not be handed a velocity of their own.
        for call in Self.calls("StepSequencerEdit.toggle", in: roll)
            + Self.calls("StepAccent.toggle", in: roll) {
            #expect(!call.contains("entry:"), "the view overrode the entry velocity: \(call)")
            #expect(!call.contains("isDrumKit"), "isDrumKit reached a toggle: \(call)")
        }
        #expect(Self.calls("StepSequencerEdit.toggle", in: roll).count == 1)
        #expect(Self.calls("StepAccent.toggle", in: roll).count == 1)
    }
}
