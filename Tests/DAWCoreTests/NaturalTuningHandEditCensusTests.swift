import Foundation
import Testing
@testable import DAWCore

// Natural tuning D4-1 (b) — THE HAND-EDIT CENSUS. Design
// `docs/design/2026-09-25-natural-tuning.md` §4.c D4-1, X4, Q-U1.
//
// The user ruled Q-U1 = (b) on 2026-09-26: "Update when I edit them: The first
// note you drag on an old vocal updates the whole vocal (also one Undo)."
// `PitchEditSet.handEditUpgradesLegacyVocal` is therefore true, and the rule
// reaches a vocal only through `afterHandEdit(from:)`, its ONE home. A
// per-note writer that forgets that call would leave the vocal legacy on its
// first edit, and the vocal would then update on the 2nd or 3rd edit
// depending on which tool came first: the unpredictable rule the ruling
// exists to avoid. The home also holds the 2026-09-27 no-op rule: an edit
// that changes no note leaves an old vocal exactly as it is. A writer that
// called the bare `afterHandEdit()` would skip it, so the census refuses one.
//
// ⭐ THE METHOD (the G-C8 `constructionSiteCensus` precedent in
// `PitchConsonantMaskTests`: a source scan with a listed exemption table, a
// reason per exemption, plus a behavioural leg):
//  1. Every `.swift` file under `Sources/` is scanned for a WRITE of a
//     `pitchEdits` value (`pitchEdits = …`, or a mutation through
//     `pitchEdits?.` / `pitchEdits!.`), comments cut.
//  2. Each write is attributed to its enclosing declaration (the nearest
//     `func name(` or `init(` above it), keyed `<file under Sources>:<name>`.
//  3. The set of writers found must EQUAL `handEditWriters` ∪ `exemptWriters`:
//     a NEW writer anywhere turns this red until it is classified.
//  4. A hand-edit writer must route: between its declaration and its write,
//     the text calls `afterHandEdit(from:` or one of `handEditTransforms`,
//     and NEVER the bare `afterHandEdit()`; each listed transform must exist
//     in `Sources/`, and its own body must call `afterHandEdit(from: self)`
//     (a transform passing anything else, e.g. its own edited table, would
//     compile and never update) and never the bare hook.
//  5. The behavioural leg here (pure) runs every transform on a legacy set;
//     the store leg (every writer on a legacy vocal, one undo step, exact undo)
//     is `PitchCorrectionWriterTests`' D4-1 (b) block, whose writer table must
//     name exactly `handEditWriters`.
//
// Pure and nonisolated (`MainActorOccupancySiteTests` Leg C caps `@MainActor`
// suites).
@Suite("Natural tuning D4-1 (b) — every per-note writer updates a legacy vocal through afterHandEdit (census)")
struct NaturalTuningHandEditCensusTests {

    // MARK: - The tables

    static let noteEdits = "DAWCore/ProjectStore+PitchNoteEdits.swift"
    static let presets = "DAWCore/ProjectStore+PitchCorrection.swift"

    /// Every store writer that changes NOTES by hand. Each must route through
    /// `afterHandEdit()` (directly, or through a `handEditTransforms` entry).
    static let handEditWriters: Set<String> = [
        "\(noteEdits):setClipNotePitchOffset",
        "\(noteEdits):splitClipNoteSegment",
        "\(noteEdits):setClipNotesCleared",
        "\(noteEdits):setClipNoteGain",
        "\(noteEdits):setClipNotePitchOffsets",
        "\(noteEdits):setClipNoteFormant",
        "\(noteEdits):setClipNoteTransition",
        "\(noteEdits):setClipNoteGlideFollow",
        "\(noteEdits):setClipNotesVibrato",
        "\(noteEdits):resetClipNoteVibrato",
        "\(noteEdits):setClipNoteShapes",
    ]

    /// The pure transforms a writer may route through instead of calling
    /// `afterHandEdit()` itself. Each one's body is checked to call it.
    static let handEditTransforms: Set<String> = [
        "applyingNotePitchOffsets",
        "applyingNoteTransition",
        "applyingNoteGlideFollow",
        "applyingNoteShapes",
        "applyingNoteVibratos",
    ]

    /// Every other writer of a `pitchEdits` value in `Sources/`, with the
    /// reason it must NOT update a legacy vocal.
    static let exemptWriters: [String: String] = [
        "\(noteEdits):upgradeToNaturalTuning":
            "IS the upgrade (X4's one path); it calls `upgradedToNaturalTuning` itself",
        "\(noteEdits):setClipFormantCorrection":
            "a set-level switch, an explicit request: it writes its own field alone (X4)",
        "\(noteEdits):setClipConsonantProtection":
            "a set-level switch, an explicit request: it writes its own field alone (§2e)",
        "\(noteEdits):setClipPitchTransitionSmoothness":
            "a set-level switch, an explicit request: it writes its own field alone (§4.j)",
        "\(presets):autoCorrectClipPitchReport":
            "auto-correct builds a NEW set through `PitchEditSet.seeded`, never a legacy one",
        "\(presets):findUnpitchedSounds":
            "a detection merge, not a note edit: it adds untouched sounds and moves no note",
        "\(presets):clearClipPitchEdits":
            "removes the table (nil): there is no vocal left to update",
        "DAWCore/Model.swift:init":
            "`Clip.init` stores the set it is handed (construction, copies); not an edit",
        "DAWCore/ProjectDocument.swift:init":
            "the file format's own copy and decode: a saved vocal must reopen AS SAVED",
        "DAWEngine/Stretch/StretchRenderCache.swift:init":
            "the render key's copy of the set (`Params`), never stored back",
        // p2-sing-x6 (orchestrator, 2026-10-07): a NEW sung take's table, read at `PitchNoteTable.detected`
        // (seeds through `PitchEditSet.seeded`, the natural-tuning format) and `SungExpressionPlanner`.
        "AIServices/SingJobCoordinator.swift:finishPart":
            "a NEW sung take's table (`PitchEditSet.seeded` + the style planner's vibratos), landed on a NEW clip: no old vocal to update",
        "DAWCore/ProjectStore+SungVocal.swift:init":
            "`SungVocalTake.init` stores the set it is handed (construction, like `Clip.init`); not an edit",
    ]

    // MARK: - The instrument

    /// The repo root, from this file's path (the `repoSource` idiom).
    static func repoRoot() -> URL? {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// A line with its comment cut: a line that starts `//` is empty, and a
    /// trailing `//` comment is dropped, so a doc that NAMES a write is not one.
    static func code(_ raw: String) -> String {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("//") { return "" }
        if let comment = line.range(of: "//") { return String(line[..<comment.lowerBound]) }
        return line
    }

    /// The write shapes, on a member (`x.pitchEdits`) or a bare property at
    /// the start of a line (an `init` body): an assignment (never `==`), and
    /// a mutation through an optional or forced member
    /// (`pitchEdits?.segments[0].x = …`). A local `let pitchEdits = …` is a
    /// new name, not a write, and does not match.
    static let writeShapes = [#"(?:\.|^)pitchEdits\s*=(?!=)"#,
                              #"(?:\.|^)pitchEdits[?!]\s*\.[^=]*[^=!<>]=(?!=)"#]

    /// A DECLARATION line (modifiers and attributes, then `func name(` /
    /// `func name<` or `init(`), never a call such as `Foo.init(`.
    static let declarationShape =
        #"^(?:[@A-Za-z()]+\s+)*?(?:func\s+([A-Za-z_][A-Za-z0-9_]*)|init[?!]?)\s*[(<]"#

    static func isWrite(_ line: String) throws -> Bool {
        let range = NSRange(line.startIndex..., in: line)
        for shape in writeShapes {
            if try NSRegularExpression(pattern: shape).firstMatch(in: line, range: range) != nil {
                return true
            }
        }
        return false
    }

    /// The declaration's name on `line`, `"init"` for an initialiser, or nil.
    static func declaredName(_ line: String) throws -> String? {
        let expression = try NSRegularExpression(pattern: declarationShape)
        guard let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
        else { return nil }
        if let name = Range(match.range(at: 1), in: line) { return String(line[name]) }
        return "init"
    }

    struct Write {
        let writer: String
        /// The code from the declaration line up to and including the write.
        let lead: String
        let line: Int
    }

    struct Scan {
        var files = 0
        var writes: [Write] = []
        /// Each declared function's brace-matched body, by bare name.
        var bodies: [String: [String]] = [:]
    }

    /// The code from `start` to the line where its first `{` closes.
    static func body(from start: Int, in lines: [String]) -> String {
        var depth = 0
        var opened = false
        var out: [String] = []
        for index in start..<lines.count {
            let line = lines[index]
            out.append(line)
            for character in line {
                if character == "{" { depth += 1; opened = true }
                if character == "}" { depth -= 1 }
            }
            if opened && depth <= 0 { break }
        }
        return out.joined(separator: "\n")
    }

    static func scan() throws -> Scan {
        let root = try #require(repoRoot(), "could not locate the repo from \(#filePath)")
        let sources = root.appendingPathComponent("Sources")
        let enumerator = try #require(FileManager.default.enumerator(at: sources,
                                                                     includingPropertiesForKeys: nil))
        var result = Scan()
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            result.files += 1
            let parts = url.standardizedFileURL.pathComponents
            let from = (parts.lastIndex(of: "Sources") ?? 0) + 1
            let relative = parts[from...].joined(separator: "/")
            let lines = text.components(separatedBy: "\n").map(code)
            var declaration: (name: String, line: Int)?
            for (index, line) in lines.enumerated() {
                if let name = try declaredName(line) {
                    declaration = (name, index)
                    if handEditTransforms.contains(name) {
                        result.bodies[name, default: []].append(body(from: index, in: lines))
                    }
                }
                guard try isWrite(line) else { continue }
                let owner = declaration ?? (name: "<file scope>", line: 0)
                result.writes.append(Write(
                    writer: "\(relative):\(owner.name)",
                    lead: lines[owner.line...index].joined(separator: "\n"),
                    line: index + 1))
            }
        }
        return result
    }

    /// Routed through D4-1's home: `afterHandEdit(from:` or a listed
    /// transform, and never the bare `afterHandEdit()`, which skips the no-op
    /// rule.
    static func routes(_ lead: String) -> Bool {
        if lead.contains(".afterHandEdit()") { return false }
        if lead.contains(".afterHandEdit(from:") { return true }
        return handEditTransforms.contains { lead.contains(".\($0)(") }
    }

    // MARK: - The census

    @Test("D4-1 census: every pitchEdits writer in Sources/ is listed, and every hand-edit writer routes through afterHandEdit(from:), never the bare hook")
    func handEditWriterCensus() throws {
        // The instrument can see each shape (positive controls), and skips a
        // comparison, a declaration and a comment.
        #expect(try Self.isWrite("tracks[t].clips[c].pitchEdits = stored"))
        #expect(try Self.isWrite("clip.pitchEdits?.segments[0].isCleared = true"))
        #expect(try Self.isWrite("clip.pitchEdits!.retuneMs = 80"))
        #expect(try !Self.isWrite("guard clip.pitchEdits == nil else { return }"))
        #expect(try !Self.isWrite("if clip.pitchEdits?.segments.count == 3 {"))
        #expect(try !Self.isWrite("var pitchEdits: PitchEditSet? = nil"))
        #expect(try !Self.isWrite("let pitchEdits = clip.pitchEdits"))
        #expect(try Self.isWrite("pitchEdits = try c.decodeIfPresent(PitchEditSet.self, forKey: .pitchEdits)"))
        #expect(try !Self.isWrite(Self.code("/// pitchEdits = stored, in a doc")))
        #expect(try !Self.isWrite(Self.code("x = y // pitchEdits = z in a comment")))
        // The scan trims every line (`code`), so the controls go through it too.
        #expect(try Self.declaredName(Self.code("    public func setClipNoteGain(clipId: UUID,"))
                == "setClipNoteGain")
        #expect(try Self.declaredName(Self.code("        public init(ratio: Double, semitones: Double,"))
                == "init")
        #expect(try Self.declaredName("let f = setClipNoteGain(") == nil)
        #expect(try Self.declaredName("@discardableResult public func setClipNoteGain(") == "setClipNoteGain")
        #expect(try Self.declaredName("private nonisolated static func reidentified(_ s: NoteSegment,")
                == "reidentified")
        #expect(try Self.declaredName("return PitchEditSet.init(segments: notes)") == nil)
        #expect(try Self.declaredName("try self.init(from: decoder)") == nil)
        #expect(Self.routes("let stored = table.afterHandEdit(from: before)"))
        #expect(Self.routes("let stored = try table.applyingNoteShapes(shapes, clipId: clipId)"))
        #expect(!Self.routes("let stored = table.afterHandEdit()"), "the bare hook skips the no-op rule")
        #expect(!Self.routes("let s = try t.applyingNoteShapes(x, clipId: c).afterHandEdit()"))
        #expect(!Self.routes("let stored = table"))
        #expect(!Self.routes("let stored = table.upgradedToNaturalTuning()"))

        let scan = try Self.scan()
        #expect(scan.files > 200, "the census read only \(scan.files) files: it did not see the tree")
        let found = Set(scan.writes.map(\.writer))
        #expect(found.count >= Self.handEditWriters.count + 5,
                "the census found only \(found.count) writers: \(found.sorted())")
        #expect(Self.handEditWriters.isDisjoint(with: Self.exemptWriters.keys))
        let listed = Self.handEditWriters.union(Self.exemptWriters.keys)
        #expect(found == listed,
                """
                pitchEdits writers changed. Unlisted: \(found.subtracting(listed).sorted()). \
                Listed but gone: \(listed.subtracting(found).sorted()). A writer that changes \
                NOTES by hand belongs in `handEditWriters` and must end in `afterHandEdit(from:)` \
                (D4-1 (b), the user's ruling); any other goes in `exemptWriters` with the \
                reason it must not update an old vocal.
                """)
        for write in scan.writes where Self.handEditWriters.contains(write.writer) {
            #expect(Self.routes(write.lead),
                    """
                    \(write.writer) (line \(write.line)) stores notes without D4-1's home \
                    `afterHandEdit(from:)`, or calls the bare `afterHandEdit()`: on a vocal tuned \
                    before natural tuning its first edit would not update the vocal, or a no-op \
                    would (D4-1 (b)).
                    """)
        }
        for transform in Self.handEditTransforms.sorted() {
            let bodies = scan.bodies[transform] ?? []
            #expect(bodies.count == 1, "\(transform): \(bodies.count) declarations in Sources/")
            #expect(bodies.allSatisfy { $0.contains(".afterHandEdit(from: self)") && !$0.contains(".afterHandEdit()") },
                    "\(transform) no longer ends in `afterHandEdit(from: self)`: every writer routed through it is legacy, or a no-op updates")
        }
    }

    // MARK: - The behavioural leg (pure)

    static let clip = UUID(uuidString: "D41D41D4-0000-4000-8000-0000000000C1")!
    static let idA = UUID(uuidString: "D41D41D4-0000-4000-8000-00000000000A")!
    static let idB = UUID(uuidString: "D41D41D4-0000-4000-8000-00000000000B")!
    static let idS = UUID(uuidString: "D41D41D4-0000-4000-8000-00000000005A")!
    static let idC = UUID(uuidString: "D41D41D4-0000-4000-8000-00000000000C")!

    /// A vocal tuned BEFORE natural tuning: A (+150 c) and B abut (a soft
    /// join), an untouched sound S, then C after a gap. Formant nil,
    /// consonants off, slope 0: every set-level field legacy.
    static func legacyVocal(slope: Double = 0) -> PitchEditSet {
        PitchEditSet(segments: [
            NoteSegment(id: idA, startSeconds: 0.0, endSeconds: 0.4, detectedHz: 220,
                        detectedConfidence: 0.9, pitchOffsetCents: 150),
            NoteSegment(id: idB, startSeconds: 0.4, endSeconds: 0.8, detectedHz: 240,
                        detectedConfidence: 0.9),
            NoteSegment(id: idS, startSeconds: 0.8, endSeconds: 0.95, detectedHz: 240,
                        detectedConfidence: 0.3, origin: .unpitched),
            NoteSegment(id: idC, startSeconds: 1.0, endSeconds: 1.4, detectedHz: 260,
                        detectedConfidence: 0.9),
        ], retuneMs: 80, transitionSlopeCentsPerSecond: slope)
    }

    static func isUpdated(_ set: PitchEditSet, slope: Double = PitchEditSet.defaultTransitionSlope) -> Bool {
        !set.predatesNaturalTuning
            && set.formantCorrection == PitchEditSet.newSetFormantCorrection
            && set.keepsConsonantsUntuned
            && set.transitionSlopeCentsPerSecond == slope
    }

    @Test("D4-1 (b): the switch is ON, and afterHandEdit updates a legacy vocal and leaves every other set alone")
    func theSwitchIsOn() throws {
        #expect(PitchEditSet.handEditUpgradesLegacyVocal,
                "the user ruled Q-U1 = (b) on 2026-09-26: a hand edit updates an old vocal")
        let legacy = Self.legacyVocal()
        #expect(legacy.predatesNaturalTuning, "positive control: a tuned vocal from before the update")
        let updated = legacy.afterHandEdit()
        #expect(updated == legacy.upgradedToNaturalTuning(), "the hook is not X4's one upgrade")
        #expect(Self.isUpdated(updated))
        #expect(updated.segments == legacy.segments && updated.retuneMs == legacy.retuneMs,
                "the update moved a note")
        // Inert on a set that does not predate natural tuning: a new set, an
        // already-updated one, and an untuned (pitch-identity) one.
        let fresh = NaturalTuningFieldCarryTests.nonLegacy(legacy)
        #expect(fresh.afterHandEdit() == fresh)
        #expect(updated.afterHandEdit() == updated)
        var untuned = legacy
        untuned.segments[0].pitchOffsetCents = 0
        #expect(!untuned.predatesNaturalTuning && untuned.afterHandEdit() == untuned)
        // C4's ruling: an explicitly picked slope survives the update.
        let picked = Self.legacyVocal(slope: 6000)
        #expect(picked.predatesNaturalTuning)
        #expect(Self.isUpdated(picked.afterHandEdit(), slope: 6000),
                "the update threw away an explicit smoothness pick")
    }

    @Test("D4-1 (b): every hand-edit transform updates a legacy vocal; the set-level smoothness switch does not")
    func everyTransformUpdatesALegacyVocal() throws {
        let legacy = Self.legacyVocal()
        let b = legacy.segments[1]
        let transforms: [(String, PitchEditSet)] = [
            ("applyingNotePitchOffsets",
             try legacy.applyingNotePitchOffsets([NotePitchOffset(segmentId: Self.idB, offsetCents: 60)],
                                                 clipId: Self.clip)),
            ("applyingNoteTransition",
             try legacy.applyingNoteTransition(segmentId: Self.idA, widthMs: 120, clipId: Self.clip)),
            ("applyingNoteGlideFollow",
             try legacy.applyingNoteGlideFollow(segmentId: Self.idB, amount: 1, clipId: Self.clip)),
            ("applyingNoteShapes",
             try legacy.applyingNoteShapes(
                [Self.idB: NoteShapeSamples(startIndex: NoteShapeSamples.gridSpan(of: b).lowerBound + 4,
                                            tenthsOfCents: [200, 300])],
                clipId: Self.clip)),
            ("applyingNoteVibratos",
             try legacy.applyingNoteVibratos(
                [NoteVibratoItem(segmentId: Self.idB, edit: NoteVibratoEdit(driftScale: 0.3))],
                stretchRatio: 1, clipId: Self.clip).set),
        ]
        #expect(Set(transforms.map(\.0)) == Self.handEditTransforms,
                "the behavioural leg must run every transform the census lets a writer route through")
        for (name, edited) in transforms {
            #expect(edited.segments != legacy.segments, "\(name) wrote nothing, so this proves nothing")
            #expect(Self.isUpdated(edited), "\(name) left an old vocal legacy on its first edit")
            // Exactly the edit, then the update: the note fields are the
            // transform's, the set-level fields X4's.
            #expect(edited == legacy.withSegments(edited.segments).upgradedToNaturalTuning(),
                    "\(name) changed more than its note and the update")
        }
        // The set-level switch is an explicit request: its own field only.
        let smoother = try legacy.applyingTransitionSmoothness(centsPerSecond: nil)
        #expect(smoother.formantCorrection == nil && !smoother.keepsConsonantsUntuned
                && smoother.transitionSlopeCentsPerSecond == PitchEditSet.defaultTransitionSlope)
    }

    /// ⭐ THE NO-OP RULE (2026-09-27, on the user's words "the first note you
    /// DRAG"): the home updates an old vocal only when the edit changed a
    /// note. The same set back is a no-op, and a no-op has no side effect.
    @Test("D4-1 home: afterHandEdit(from:) leaves an old vocal alone when no note changed, and updates it when one did")
    func theHomeSkipsANoOp() throws {
        let legacy = Self.legacyVocal()
        #expect(legacy.predatesNaturalTuning, "positive control: a tuned vocal from before the update")
        #expect(legacy.afterHandEdit(from: legacy) == legacy, "a no-op updated an old vocal")
        var moved = legacy
        moved.segments[1].pitchOffsetCents = 60
        #expect(moved.afterHandEdit(from: legacy) == moved.upgradedToNaturalTuning(),
                "a real change did not update an old vocal")
        #expect(moved.afterHandEdit(from: legacy) == moved.afterHandEdit(),
                "a real change must take the bare hook's update exactly")
        // Inert on a set that is already new, changed or not.
        let fresh = NaturalTuningFieldCarryTests.nonLegacy(legacy)
        var freshMoved = fresh
        freshMoved.segments[1].pitchOffsetCents = 60
        #expect(fresh.afterHandEdit(from: fresh) == fresh)
        #expect(freshMoved.afterHandEdit(from: fresh) == freshMoved)
    }

    /// Every transform the census lets a writer route through, given an edit
    /// that changes NO note on an old vocal, returns the old vocal as it was.
    @Test("D4-1 no-op: every hand-edit transform leaves an old vocal exactly as it was when its edit changes no note")
    func everyTransformLeavesAnOldVocalAloneOnANoOp() throws {
        let legacy = Self.legacyVocal()
        #expect(legacy.segments[1].pitchOffsetCents == 0 && legacy.segments[0].transitionOutMs == 0
                && legacy.segments[1].glideFollow == 0 && !legacy.segments[1].hasShape
                && legacy.segments[1].vibratoScale == 1, "precondition: each no-op below writes a stored value")
        let noOps: [(String, PitchEditSet)] = [
            ("applyingNotePitchOffsets",
             try legacy.applyingNotePitchOffsets([NotePitchOffset(segmentId: Self.idB, offsetCents: 0)],
                                                 clipId: Self.clip)),
            ("applyingNoteTransition",
             try legacy.applyingNoteTransition(segmentId: Self.idA, widthMs: nil, clipId: Self.clip)),
            ("applyingNoteGlideFollow",
             try legacy.applyingNoteGlideFollow(segmentId: Self.idB, amount: 0, clipId: Self.clip)),
            ("applyingNoteShapes",
             try legacy.applyingNoteShapes([Self.idB: .clear], clipId: Self.clip)),
            ("applyingNoteVibratos",
             try legacy.applyingNoteVibratos(
                [NoteVibratoItem(segmentId: Self.idB, edit: NoteVibratoEdit(vibratoScale: 1))],
                stretchRatio: 1, clipId: Self.clip).set),
        ]
        #expect(Set(noOps.map(\.0)) == Self.handEditTransforms,
                "the no-op leg must run every transform the census lets a writer route through")
        for (name, edited) in noOps {
            #expect(edited == legacy, "\(name): an edit that changed no note changed the vocal")
            #expect(edited.predatesNaturalTuning, "\(name): a no-op updated an old vocal")
        }
    }

    /// The pitch drag's DRAFT (`ProjectStore.previewClipNotePitchDraft`
    /// span-renders `applyingNotePitchOffsets`) is the updated vocal, so the
    /// note a first drag PLAYS is the note its release STORES. A draft that
    /// skipped `afterHandEdit()` would play the old voice size, consonants and
    /// slides for the whole drag and switch on release.
    @Test("D4-1 (b): a first drag's draft on a legacy vocal is the updated vocal, byte for byte what the release stores")
    func theDraftIsTheUpdatedVocal() throws {
        let legacy = Self.legacyVocal()
        let offsets = [NotePitchOffset(segmentId: Self.idA, offsetCents: 250),
                       NotePitchOffset(segmentId: Self.idC, offsetCents: -40)]
        let draft = try legacy.applyingNotePitchOffsets(offsets, clipId: Self.clip)
        var byHand = legacy
        byHand.segments[0].pitchOffsetCents = 250
        byHand.segments[3].pitchOffsetCents = -40
        #expect(draft == byHand.upgradedToNaturalTuning())
        #expect(Self.isUpdated(draft))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(draft) == encoder.encode(byHand.upgradedToNaturalTuning()))
        // A second drag on the updated draft changes only its note.
        let second = try draft.applyingNotePitchOffsets(
            [NotePitchOffset(segmentId: Self.idB, offsetCents: 30)], clipId: Self.clip)
        var expected = draft
        expected.segments[1].pitchOffsetCents = 30
        #expect(second == expected, "a second edit touched the set-level fields again")
    }
}
