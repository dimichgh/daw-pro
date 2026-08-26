import CoreGraphics
import Foundation
import Testing
@testable import DAWAppKit

/// m25-i — pitch names on the piano-roll note blocks: the ink-polarity policy and
/// the fit rule.
///
/// The numbers pinned here are MEASURED, from a scratchpad `ImageRenderer`
/// harness that compiled the real `Theme.swift` and drew pills with the same
/// `Canvas` primitives `PianoRollGrid.drawLitPill` uses, sampling the result in
/// an explicit sRGB context. That harness carried a positive control in the same
/// pass — white-on-black measured 21.00:1 and black-on-white 21.00:1 — so a
/// sampler that could not see 21 was never trusted to report 4.
@Suite("Piano-roll note labels (m25-i)")
struct PianoRollNoteLabelTests {

    // The two tints, from the same literals `DAWTheme` holds.
    static let cyan = SRGBColor(hex: 0x3EE6FF)
    static let violet = SRGBColor(hex: 0xB48CFF)
    // The grid's two row backdrops: the panel, and the panel under the
    // black-key lane wash (black @ 22%).
    static let whiteRow = SRGBColor(hex: 0x12151D)
    static let blackRow = SRGBColor(hex: 0x000000)
        .blended(over: SRGBColor(hex: 0x12151D), alpha: 0.22)

    /// The lit pill's fill alpha, mirroring `PianoRollGrid.litFillOpacity`.
    static func alpha(velocity: Int, selected: Bool = false) -> Double {
        let a = 0.45 + 0.5 * (Double(velocity) / 127)
        return selected ? min(1, a + 0.2) : a
    }

    /// Hex string, for failure messages that can be compared to the harness.
    static func hex(_ c: SRGBColor) -> String {
        String(format: "#%02X%02X%02X",
               Int((c.red * 255).rounded()), Int((c.green * 255).rounded()),
               Int((c.blue * 255).rounded()))
    }

    // MARK: - The blend model, pinned to measured pixels

    /// ⭐ THE LOAD-BEARING TEST OF THE MODEL. Every contrast figure below is
    /// derived from `blended(over:alpha:)`, so if that composited in the wrong
    /// colour space every number would be internally consistent and wrong. These
    /// four are real sampled pixels from the harness; a linear-space blend misses
    /// the first by 46 counts of green (#2CA2B5 vs #267484).
    @Test("pill composites match pixels sampled from a real Canvas render")
    func compositeMatchesMeasuredPixels() {
        let cases: [(String, SRGBColor, Int, SRGBColor, String)] = [
            ("cyan v1 white row", Self.cyan, 1, Self.whiteRow, "#267484"),
            ("cyan v127 white row", Self.cyan, 127, Self.whiteRow, "#3CDCF4"),
            ("violet v64 white row", Self.violet, 64, Self.whiteRow, "#8468BC"),
            ("violet v1 black row", Self.violet, 1, Self.blackRow, "#594880"),
        ]
        for (name, tint, velocity, backdrop, measured) in cases {
            let pill = NotePillInk.pillColor(tint: tint, alpha: Self.alpha(velocity: velocity),
                                             backdrop: backdrop)
            // ±1 per channel, because the harness reports QUANTISED pixels and the
            // model reports continuous ones: violet v64 lands on 104.5, which the
            // renderer floors to 0x68 and `hex(_:)` rounds to 0x69. An exact-match
            // assertion here reddened on a model that is right — the tolerance is
            // the quantisation, and one count is far tighter than the ~46 counts a
            // linear-space blend would be off by.
            let delta = max(abs(pill.red * 255 - Double(Int(measured.dropFirst(1).prefix(2), radix: 16)!)),
                            abs(pill.green * 255 - Double(Int(measured.dropFirst(3).prefix(2), radix: 16)!)),
                            abs(pill.blue * 255 - Double(Int(measured.dropFirst(5).prefix(2), radix: 16)!)))
            #expect(delta <= 1.0,
                    "\(name): model \(Self.hex(pill)) vs measured \(measured), worst channel off by \(delta)")
        }
    }

    // MARK: - The ink policy

    /// ⭐ THE POLICY TEST, and it asserts the ink the policy ACTUALLY PICKED —
    /// not that a readable ink exists. `max(contrast(black), contrast(white))`
    /// would pass with `prefersDarkInk` returning the wrong branch every time;
    /// that shape pins the palette, this one pins the decision.
    @Test("the ink the policy picks clears Rule 5 on every pill the grid can draw")
    func pickedInkClearsContrastFloor() {
        var worst = (ratio: Double.infinity, detail: "")
        var checked = 0
        for (tintName, tint) in [("cyan", Self.cyan), ("violet", Self.violet)] {
            for (rowName, backdrop) in [("white", Self.whiteRow), ("black", Self.blackRow)] {
                for velocity in 0...127 {
                    for selected in [false, true] {
                        let a = Self.alpha(velocity: velocity, selected: selected)
                        let pill = NotePillInk.pillColor(tint: tint, alpha: a, backdrop: backdrop)
                        let ink = NotePillInk.ink(tint: tint, alpha: a, backdrop: backdrop)
                        let ratio = SRGBColor.contrast(ink, pill)
                        checked += 1
                        if ratio < worst.ratio {
                            worst = (ratio, "\(tintName) v\(velocity) \(rowName)Row "
                                     + "selected=\(selected) pill \(Self.hex(pill)) "
                                     + "ink \(Self.hex(ink))")
                        }
                    }
                }
            }
        }
        // ANTI-VACUITY: a loop that ran zero times would leave `worst` at
        // infinity and sail through the floor assertion below.
        #expect(checked == 2 * 2 * 128 * 2, "expected 1024 pills checked, ran \(checked)")
        #expect(worst.ratio >= 4.5,
                "DESIGN-LANGUAGE Rule 5 (>= 4.5:1) — worst pill was \(worst.ratio): \(worst.detail)")
    }

    /// The branch itself, at four points the harness measured, so a threshold
    /// that drifted would redden HERE with a readable reason rather than only in
    /// the aggregate above.
    @Test("polarity flips where the measurements say it does")
    func polarityMatchesMeasuredCrossovers() {
        // cyan v1: black 3.91 / white 5.37 -> light. cyan v64: black 7.46 -> dark.
        #expect(!NotePillInk.prefersDarkInk(tint: Self.cyan, alpha: Self.alpha(velocity: 1),
                                            backdrop: Self.whiteRow))
        #expect(NotePillInk.prefersDarkInk(tint: Self.cyan, alpha: Self.alpha(velocity: 64),
                                           backdrop: Self.whiteRow))
        // violet v32: black 3.64 / white 5.77 -> light. violet v96: black 6.01 -> dark.
        #expect(!NotePillInk.prefersDarkInk(tint: Self.violet, alpha: Self.alpha(velocity: 32),
                                            backdrop: Self.whiteRow))
        #expect(NotePillInk.prefersDarkInk(tint: Self.violet, alpha: Self.alpha(velocity: 96),
                                           backdrop: Self.whiteRow))
    }

    /// The two tints do NOT flip at the same velocity — which is the whole reason
    /// the polarity is computed from luminance instead of from a velocity
    /// constant. If this ever collapses to one crossover, the simpler rule the
    /// item rejected became available and this file should be revisited.
    @Test("cyan and violet cross over at different velocities")
    func tintsCrossAtDifferentVelocities() {
        func crossover(_ tint: SRGBColor) -> Int? {
            (0...127).first { NotePillInk.prefersDarkInk(tint: tint,
                                                         alpha: Self.alpha(velocity: $0),
                                                         backdrop: Self.whiteRow) }
        }
        let cyanAt = crossover(Self.cyan)
        let violetAt = crossover(Self.violet)
        #expect(cyanAt != nil && violetAt != nil,
                "both tints must reach dark ink somewhere in 0...127")
        #expect(cyanAt! < violetAt!, "cyan \(cyanAt!) should flip well before violet \(violetAt!)")
        let gap = violetAt! - cyanAt!
        #expect(gap > 20,
                "measured gap was ~48 velocity steps (cyan ~8, violet ~56); got \(gap)")
    }

    /// Pure black and pure white are not decoration: the softer inks the house
    /// text hierarchy offers cannot label this surface. Measured peaks —
    /// `keyLabelOnWhite` 3.80:1 on cyan v32, `background` crossing at 4.41:1.
    @Test("the softer house inks fail on a note pill, which is why the extremes are used")
    func softerInksCannotLabelAPill() {
        let pill = NotePillInk.pillColor(tint: Self.cyan, alpha: Self.alpha(velocity: 32),
                                         backdrop: Self.whiteRow)
        let soft = SRGBColor.contrast(SRGBColor(hex: 0x232833), pill)
        #expect(soft < 4.5, "keyLabelOnWhite on a cyan v32 pill measured 3.80:1; got \(soft)")
        #expect(SRGBColor.contrast(NotePillInk.dark, pill) >= 4.5,
                "pure black must clear the floor where the soft ink does not")
    }

    /// The crossover is the worst case by construction, and it is ~4.58:1 — the
    /// most ANY ink pair can promise on a mid-luminance object. Pinned so the
    /// margin is visible: this surface passes Rule 5 by 2 %, not comfortably.
    @Test("crossover luminance is the black/white break-even, worth 4.58:1")
    func crossoverIsBreakEven() {
        let l = NotePillInk.crossoverLuminance
        #expect(abs(l - 0.1791) < 0.001, "expected ~0.1791, got \(l)")
        #expect(abs((l + 0.05) / 0.05 - 1.05 / (l + 0.05)) < 1e-9, "not a break-even point")
        #expect(abs((l + 0.05) / 0.05 - 4.58) < 0.01)
    }

    // MARK: - The fit rule

    /// MEASURED type metrics for 8 pt SF Mono, reported by a real `Canvas` text
    /// resolution in the harness: advance 5.0 pt per glyph, line box 10.0 pt.
    /// Everything below is expressed in these rather than in guesses — the first
    /// draft of this file assumed 4.8/9.5 and would have pinned a fit ladder one
    /// note-length off.
    static let advance: CGFloat = 5.0
    static let lineBox: CGFloat = 10.0

    /// The pill a note of `beats` occupies at `pixelsPerBeat`, mirroring
    /// `PianoRollModel.noteRect` (floor of 3 pt) inset 0.5 pt each side.
    static func pillWidth(beats: Double, pixelsPerBeat: CGFloat) -> CGFloat {
        max(3, CGFloat(beats) * pixelsPerBeat) - 1
    }

    static func labelSize(_ name: String) -> CGSize {
        CGSize(width: PianoRollNoteLabel.width(glyphCount: name.count, advance: advance),
               height: lineBox)
    }

    @Test("a name that does not fit is suppressed, never truncated")
    func narrowPillSuppressesTheLabel() {
        let label = Self.labelSize("C#4")                 // 15 pt of glyphs
        // 32 pt/beat, a 1/16 note = 2 pt of pill: nothing is drawn.
        #expect(!PianoRollNoteLabel.fits(labelSize: label, pillWidth: 2, pillHeight: 11))
        // A hair short of fitting still draws NOTHING — there is no "draw what
        // fits" branch, because a partial pitch name is a valid, different one.
        #expect(!PianoRollNoteLabel.fits(labelSize: label, pillWidth: 19.9, pillHeight: 11))
        #expect(PianoRollNoteLabel.fits(labelSize: label, pillWidth: 20, pillHeight: 11))
    }

    /// The coverage ladder the inset choice buys, at the shipped geometry. This
    /// is the test that would redden if someone "tidied" the insets to a
    /// symmetric 3/3 — which measures the same on every unit test that only
    /// checks suppression, and silently costs the default session every eighth
    /// note's name.
    @Test("at the default zoom an eighth note carries a two-glyph name")
    func eighthNoteIsNamedAtDefaultZoom() {
        let ppb: CGFloat = 32                            // PianoRollModel default
        let pill = CGFloat(11)                           // 14 pt row inset 1.5 each side
        #expect(PianoRollNoteLabel.fits(labelSize: Self.labelSize("C4"),
                                        pillWidth: Self.pillWidth(beats: 0.5, pixelsPerBeat: ppb),
                                        pillHeight: pill),
                "an eighth note is 15 pt of pill and 'C4' is 10 pt of glyphs — it fits")
        #expect(PianoRollNoteLabel.fits(labelSize: Self.labelSize("C#4"),
                                        pillWidth: Self.pillWidth(beats: 1, pixelsPerBeat: ppb),
                                        pillHeight: pill))
        // A 1/16 note is 7 pt of pill: nothing fits, at any name length.
        #expect(!PianoRollNoteLabel.fits(labelSize: Self.labelSize("C4"),
                                         pillWidth: Self.pillWidth(beats: 0.25, pixelsPerBeat: ppb),
                                         pillHeight: pill))
        // ...until the roll is zoomed in, which is the whole zoom-adaptive claim.
        #expect(PianoRollNoteLabel.fits(labelSize: Self.labelSize("C4"),
                                        pillWidth: Self.pillWidth(beats: 0.25, pixelsPerBeat: 120),
                                        pillHeight: pill))
    }

    @Test("the pill must be tall enough too, and the shipped row is not break-even")
    func shortPillSuppressesTheLabel() {
        let label = Self.labelSize("C#4")
        // Shipped geometry: 14 pt row inset 1.5 top and bottom = 11 pt pill,
        // against a 10 pt line box — 1 pt of slack, NOT the 0 pt a nominal
        // "clearance" would have left.
        #expect(PianoRollNoteLabel.fits(labelSize: label, pillWidth: 60, pillHeight: 11))
        #expect(Self.lineBox < 11, "the shipped row must not sit on the height break-even")
        // A hypothetical vertical zoom taking rows to 10 pt (7 pt pill) drops the
        // labels rather than smearing glyphs across the neighbouring rows.
        #expect(!PianoRollNoteLabel.fits(labelSize: label, pillWidth: 60, pillHeight: 7))
    }

    @Test("a degenerate label measurement never draws")
    func zeroSizedLabelNeverDraws() {
        #expect(!PianoRollNoteLabel.fits(labelSize: .zero, pillWidth: 400, pillHeight: 40))
        #expect(!PianoRollNoteLabel.fits(labelSize: CGSize(width: 10, height: 0),
                                         pillWidth: 400, pillHeight: 40))
    }

    @Test("monospaced width scales with glyph count")
    func widthIsGlyphCountTimesAdvance() {
        #expect(PianoRollNoteLabel.width(glyphCount: 4, advance: Self.advance) == 20)
        #expect(PianoRollNoteLabel.width(glyphCount: 0, advance: Self.advance) == 0)
        #expect(PianoRollNoteLabel.width(glyphCount: -3, advance: Self.advance) == 0)
    }
}

/// m25-i source pin: where pitch NAMES come from, and that the gutter's labels
/// are no longer gated to C.
///
/// `DAWApp` has no test target, so the drawing itself is unreachable from here;
/// what IS reachable is the text of the two views, and the two properties worth
/// pinning are exactly the two this item could regress by a one-line edit — a
/// private name table growing back, and the label draw sliding back inside the
/// octave `if`. Anchored to the repo by `#filePath` (the `CanvasContractPinTests`
/// idiom), so it runs headless under `./scripts/test.sh`.
@Suite("Piano-roll pitch-name source pin (m25-i)")
struct PianoRollPitchNameSourcePinTests {

    private static func dawAppSourceDir() -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fm = FileManager.default
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent("Sources/DAWApp", isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        Issue.record("Could not locate Sources/DAWApp from \(#filePath)")
        return URL(fileURLWithPath: "/nonexistent")
    }

    private static func text(_ relative: String) -> String {
        (try? String(contentsOf: dawAppSourceDir().appendingPathComponent(relative),
                     encoding: .utf8)) ?? ""
    }

    /// Lines with `//` comments stripped — every needle below appears in prose in
    /// these same files (this file's own suite documents `"C#"`), so a raw
    /// `contains` would pin the comments instead of the code.
    private static func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { raw -> String in
            let line = String(raw)
            guard let marker = line.range(of: "//") else { return line }
            return String(line[line.startIndex..<marker.lowerBound])
        }.joined(separator: "\n")
    }

    /// The body of `if pitch % 12 == 0 { … }`, by BRACE COUNTING from the `if`.
    ///
    /// ⚠️ Deliberately not "slice to the next `var body:`" — that shape
    /// overshot a neighbouring view by 3.4 kB in m25-y and reddened on the
    /// neighbour's legitimate code. Counting braces ends exactly where the block
    /// does, and returns nil (a loud failure) if it never closes.
    private static func octaveBlock(in source: String) -> String? {
        guard let start = source.range(of: "if pitch % 12 == 0 {") else { return nil }
        var depth = 0
        var index = start.upperBound
        depth = 1
        while index < source.endIndex {
            let ch = source[index]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 { return String(source[start.upperBound..<index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }

    @Test("the gutter names keys through Fundamental.noteName, and octaveLabel is gone")
    func gutterUsesTheOnePitchNameHome() {
        let code = Self.codeOnly(Self.text("PianoRoll/KeyboardSidebar.swift"))
        // Scan guard: an empty read would pass every "does not contain" below.
        #expect(code.contains("struct KeyboardSidebar"),
                "KeyboardSidebar.swift did not read — the path walk broke, and every absence assertion in this suite would be vacuous")
        #expect(code.contains("Fundamental.noteName(midiNote: pitch)"),
                "the gutter must name keys through DAWCore's one scientific-pitch home")
        #expect(!code.contains("octaveLabel"),
                "the C-only octaveLabel must be DELETED, not kept alongside noteName — two name functions in one view is the drift this item removed")
        // A private twelve-string table is the other way the one home gets forked.
        #expect(!code.contains("\"C#\""), "no pitch-class table may live in the view layer")
    }

    @Test("the key label is NOT gated to C")
    func keyLabelIsDrawnForEveryPitch() {
        let code = Self.codeOnly(Self.text("PianoRoll/KeyboardSidebar.swift"))
        guard let block = Self.octaveBlock(in: code) else {
            Issue.record("could not find/close `if pitch % 12 == 0 {` — the octave marker block is expected to survive this item")
            return
        }
        // The block still exists and still draws the octave marker...
        #expect(block.contains("keyOctaveOnWhite"),
                "the octave marker line at every C is part of the landmark grammar")
        // ...but the NAME is drawn outside it, once per row.
        //
        // ⚠️ ANCHORED ON THE CALL `Self.keyLabel(`, NOT on the bare identifier:
        // this block legitimately mentions `DAWTheme.keyLabelOnWhite` (the middle-C
        // anchor bar), and a substring test for "keyLabel" therefore FAILED on the
        // correct implementation. That is the same prefix-matching vacuity that
        // once let `onCommit: commit` pass against `onCommit: commitControllerLane`
        // — in the other direction, and caught only because the assertion was a
        // negative one that reddened loudly.
        #expect(!block.contains("Self.keyLabel("),
                "the pitch name must be drawn for every key, not inside the `% 12` gate")
        #expect(!block.contains("context.draw("),
                "no text may be drawn inside the octave gate — that is the C-only shape")
        #expect(code.contains("Self.keyLabel(pitch)"),
                "the row loop must draw the name for the pitch it is on")
    }

    @Test("note blocks take their name from the same home the keys do")
    func noteBlocksUseTheOnePitchNameHome() {
        let code = Self.codeOnly(Self.text("PianoRoll/PianoRollView.swift"))
        #expect(code.contains("private struct PianoRollGrid"),
                "PianoRollView.swift did not read — absence assertions would be vacuous")
        #expect(code.contains("Fundamental.noteName(midiNote: note.pitch)"),
                "a note block's name must come from DAWCore's one scientific-pitch home")
        #expect(code.contains("PianoRollNoteLabel.fits("),
                "the label must be gated on the headless fit rule (suppress, never truncate)")
        #expect(code.contains("NotePillInk.prefersDarkInk("),
                "the on-pill ink polarity must come from the headless policy")
        #expect(!code.contains("\"C#\""), "no pitch-class table may live in the view layer")
    }

    /// ⭐ THE COUPLING, and it is the load-bearing invariant of the entire measured
    /// contrast argument: the ink is picked from the alpha the FILL uses. Every
    /// other test in this file would stay green if those two drifted — the
    /// headless suites never see the view, and a `contains` pin sees the call but
    /// not the argument. Only a COUNT catches the failure that actually happens:
    /// someone re-inlines `min(1, opacity + 0.2)` in `drawLitPill`, the pill gets
    /// brighter, and the ink keeps being computed from the extracted helper.
    @Test("the pill's fill alpha and the label's ink alpha are ONE expression")
    func fillAndInkReadTheSameAlpha() {
        let code = Self.codeOnly(Self.text("PianoRoll/PianoRollView.swift"))
        #expect(code.contains("private struct PianoRollGrid"),
                "PianoRollView.swift did not read — this count would be vacuously 0")
        // ⚠️ NOT `litFillOpacity(velocity:` — the DECLARATION reads
        // `litFillOpacity(velocity: Int, selected: Bool)` and matches that
        // needle too, so the count would be 3 and the test would encode the
        // wrong invariant while looking right. Anchor on the CALL form.
        #expect(code.contains("func litFillOpacity("),
                "the shared alpha helper must exist")
        let calls = code.components(separatedBy: "litFillOpacity(velocity: note.velocity").count - 1
        #expect(calls == 2,
                "expected exactly 2 call sites — the lit pill's fill and the label's ink — found \(calls)")
        // The velocity curve itself may exist in exactly one place: the helper.
        let curves = code.components(separatedBy: "0.45 + 0.5").count - 1
        #expect(curves == 1,
                "the 0.45 + 0.5·velocity curve must have ONE home; found \(curves) copies")
    }
}
