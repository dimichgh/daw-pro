import AppKit
import Foundation
import Testing
import DAWAppKit

/// TB (2026-09-25) — **THE TRANSPORT BAR NEVER BREAKS A LABEL INSIDE A WORD.**
///
/// At the 1208 pt window floor the bar used to be handed less than its width and
/// SwiftUI squeezed whatever would squeeze: `KEY`/`S`, `LOO`/`PER`, `EXP`/`ORT`,
/// the tempo as `12…` and the mode chip as `S…`/`P…`. In Pro it was worse at
/// EVERY width — the 340 pt leading anchor squeezed LOOP, PUNCH and CLICK to
/// `L…`, `PU…`, `CL…` even at 2400 pt — and at the floor the whole Pro bar
/// overflowed the window, centred, so the return-to-zero button fell off the
/// LEFT edge.
///
/// The fix has two halves, and this suite pins both, because either alone is
/// worse than the bug (DESIGN-LANGUAGE m23-s): **the pin** (every label and
/// readout is `.fixedSize()`, so nothing can squeeze it) and **the room** (the
/// right region gives way in a fixed order — gaps, then whole words dropping to
/// glyphs through `ViewThatFits`). A pin without room OVERFLOWS and gets clipped
/// mid-glyph with no ellipsis, which no "is there an ellipsis" check can see.
///
/// ⚠️ `Sources/DAWApp` has no test target, so this reads the SOURCE, comment-
/// stripped (the `MusicalTypingSiteTests` idiom): prose must not be able to
/// satisfy a claim about what the code does. The staging captures
/// (`debug.explainFrames` at 1208…2400 pt, both densities) are the authority on
/// the drawn widths; this suite is what fails the day someone un-pins a label
/// or reorders a collapse, before anyone opens a narrow window.
@Suite("Transport bar labels at narrow widths (TB)")
struct TransportBarLabelSiteTests {

    // MARK: - Source access

    private static func sourcesDir() -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fm = FileManager.default
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent("Sources", isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        Issue.record("Could not locate Sources from \(#filePath)")
        return URL(fileURLWithPath: "/nonexistent")
    }

    private static func text(_ relativePath: String) -> String {
        let url = sourcesDir().appendingPathComponent(relativePath)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("Could not read \(relativePath) under \(sourcesDir().path)")
            return ""
        }
        return content
    }

    private static func codeOnly(_ content: String) -> String {
        content.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                return ""
            }
            return line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
        }.joined(separator: "\n")
    }

    private static let barPath = "DAWApp/TransportBar.swift"
    private static let deckPath = "DAWApp/Components/LoopDeckControls.swift"

    private static var bar: String { codeOnly(text(barPath)) }
    private static var deck: String { codeOnly(text(deckPath)) }

    /// The code from the FIRST `start` to the first `end` after it — the
    /// modifier chain of one call site. nil (and a recorded issue) if either
    /// marker is missing, so a rename fails loudly instead of passing vacuously.
    private static func site(in source: String, from start: String, to end: String) -> String? {
        guard let startRange = source.range(of: start) else {
            Issue.record("marker not found: \(start)"); return nil
        }
        guard let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
            Issue.record("marker not found after \(start): \(end)"); return nil
        }
        return String(source[startRange.lowerBound..<endRange.upperBound])
    }

    /// Index of `needle` in `haystack`, or nil.
    private static func offset(of needle: String, in haystack: String) -> Int? {
        haystack.range(of: needle).map { haystack.distance(from: haystack.startIndex, to: $0.lowerBound) }
    }

    /// Every `if isPro { … }` block's body, brace-matched.
    private static func proOnlyBlocks(in source: String) -> [String] {
        var blocks: [String] = []
        var searchFrom = source.startIndex
        while let open = source.range(of: "if isPro {", range: searchFrom..<source.endIndex) {
            var depth = 1
            var index = open.upperBound
            while index < source.endIndex, depth > 0 {
                if source[index] == "{" { depth += 1 }
                if source[index] == "}" { depth -= 1 }
                index = source.index(after: index)
            }
            blocks.append(String(source[open.upperBound..<index]))
            searchFrom = index
        }
        return blocks
    }

    // MARK: - The harness

    @Test("fixture check: the reader and the comment stripper both work")
    func harnessWorks() {
        let stripped = Self.bar
        #expect(!stripped.isEmpty, "TransportBar.swift read as empty")
        #expect(stripped.contains("struct TransportChipFace"),
                "the stripper ate a real declaration")
        #expect(!stripped.contains("A LABEL MAY NOT BREAK INSIDE A WORD"),
                "the stripper left prose behind, so a pin here could pass on a comment")
        #expect(Self.proOnlyBlocks(in: stripped).count >= 2,
                "the brace matcher found no `if isPro` blocks — the gating test would pass vacuously")
    }

    // MARK: - ① The pin: a number never shrinks, a control label never truncates

    @Test("every readout is pinned AFTER its minWidth frame")
    func readoutsArePinned() {
        let bar = Self.bar
        for (label, explain) in [("label: \"Position\"", ".explainable(.transportPosition)"),
                                 ("label: \"Time\"", ".explainable(.transportTime)")] {
            guard let site = Self.site(in: bar, from: label, to: explain) else { continue }
            #expect(site.contains(".fixedSize()"), "\(label) is not pinned: \(site)")
            // ORDER matters: `.fixedSize()` BEFORE the minWidth frame would let a
            // too-narrow proposal shrink the frame under a pinned child, which then
            // draws over its neighbour.
            if let frame = Self.offset(of: ".frame(minWidth:", in: site),
               let pin = Self.offset(of: ".fixedSize()", in: site) {
                #expect(frame < pin, "\(label): the pin must come after the minWidth frame")
            } else {
                Issue.record("\(label): no minWidth frame found — the anchor width is gone")
            }
        }
        guard let tempo = Self.site(in: bar, from: "tempoCluster", to: ".explainable(.transportTempo)")
        else { return }
        #expect(tempo.contains(".fixedSize()"), "the tempo readout can be squeezed to `12…` again")
    }

    @Test("the leading chips, the count-in readout and the mode chip are pinned")
    func controlLabelsArePinned() {
        let bar = Self.bar
        for word in ["LOOP", "PUNCH", "CLICK"] {
            guard let site = Self.site(in: bar, from: "Text(\"\(word)\")", to: ".buttonStyle(.plain)")
            else { continue }
            #expect(site.contains(".fixedSize()"), "the \(word) chip can be squeezed again")
        }
        if let countIn = Self.site(in: bar, from: "Text(\"IN \\(bars)\")",
                                  to: "CountInNudgeButton(label: \"+\")") {
            #expect(countIn.contains(".fixedSize()"), "the IN n readout can be squeezed")
        }
        if let toggle = Self.site(in: bar, from: "SimpleProToggle(", to: ".explainable(.panelDensity)") {
            #expect(toggle.contains(".fixedSize()"),
                    "the mode chip is unpinned — it read `S…`/`P…` at the window floor")
        }
    }

    @Test("the chip face pins its OUTER stack and keeps its word on one line")
    func chipFaceIsPinned() {
        guard let face = Self.site(in: Self.bar, from: "struct TransportChipFace",
                                   to: "struct TransportGap") else { return }
        #expect(face.contains(".lineLimit(1)"), "a chip word may wrap again")
        // m22-g: an inner `Text` pin still lets the padding compress, so the pin
        // must follow the chrome (the overlay is the chip's last layer).
        if let overlay = Self.offset(of: ".overlay(", in: face),
           let pin = face.range(of: ".fixedSize()", options: .backwards)
            .map({ face.distance(from: face.startIndex, to: $0.lowerBound) }) {
            #expect(overlay < pin, "the pin is on an inner view, not the chip's outer stack")
        } else {
            Issue.record("the chip face has no overlay or no pin")
        }
    }

    // MARK: - ② The room: whole words give way, widest form first

    @Test("KEYS, EXPORT and the LOOPER door each offer a wide form BEFORE a narrow one")
    func collapseIsWideFirst() {
        let bar = Self.bar
        let deck = Self.deck
        // `ViewThatFits` takes the FIRST child that fits, so the order IS the rule:
        // narrow-first would draw the glyph-only chip at every width.
        let cases: [(String, String, String, String)] = [
            (bar, "private var musicalTypingToggle", "musicalTypingChip(compact: false)",
             "musicalTypingChip(compact: true)"),
            (bar, "private var exportButton", "exportChip(compact: false)", "exportChip(compact: true)"),
            (deck, "private var startControls", "startChip(compact: false)", "startChip(compact: true)"),
            (deck, "private var startControls", "freeChip(mini: false)", "freeChip(mini: true)"),
        ]
        for (source, owner, wide, narrow) in cases {
            guard let start = source.range(of: owner) else {
                Issue.record("\(owner) not found"); continue
            }
            let body = String(source[start.lowerBound...].prefix(1400))
            #expect(body.contains("ViewThatFits(in: .horizontal)"), "\(owner) has no ViewThatFits")
            guard let w = Self.offset(of: wide, in: body), let n = Self.offset(of: narrow, in: body) else {
                Issue.record("\(owner): missing \(wide) or \(narrow)"); continue
            }
            #expect(w < n, "\(owner): the narrow form is offered first")
        }
    }

    @Test("a chip that drops its word keeps it in the tooltip and the accessibility label")
    func droppedWordSurvives() {
        let bar = Self.bar
        let deck = Self.deck
        for (source, owner, label) in [
            (bar, "private func musicalTypingChip", ".accessibilityLabel(\"Keys, Musical Typing\")"),
            (bar, "private func exportChip", ".accessibilityLabel(\"Export\")"),
            (deck, "private func startChip", ".accessibilityLabel(\"Start looper session\")"),
        ] {
            guard let start = source.range(of: owner) else { Issue.record("\(owner) not found"); continue }
            let body = String(source[start.lowerBound...].prefix(1200))
            #expect(body.contains(label), "\(owner) lost its accessibility label")
            #expect(body.contains(".help("), "\(owner) lost its tooltip")
        }
    }

    @Test("the give-way order: a give that loses no word goes first; the LOOPER word goes last in Simple")
    func collapseOrder() {
        let bar = Self.bar
        #expect(bar.contains(".explainable(.musicalTyping)\n                .layoutPriority(collapsePriority.keys)"))
        #expect(bar.contains(".explainable(.loopDeck)\n            .layoutPriority(collapsePriority.deck)"))
        #expect(bar.contains(".explainable(.transportExport)\n                .layoutPriority(collapsePriority.export)"))
        // Parse the two tuples rather than pin the literal, so the RELATION is
        // what is tested: lower priority gives way first.
        let pattern = #"isPro \? \(keys: (\d+), deck: (\d+), export: (\d+)\) : \(keys: (\d+), deck: (\d+), export: (\d+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: bar, range: NSRange(bar.startIndex..., in: bar)),
              match.numberOfRanges == 7 else {
            Issue.record("collapsePriority's two tuples were not found"); return
        }
        let n: [Int] = (1...6).compactMap { i in
            Range(match.range(at: i), in: bar).flatMap { Int(bar[$0]) }
        }
        guard n.count == 6 else { Issue.record("unparseable priorities"); return }
        let pro = (keys: n[0], deck: n[1], export: n[2])
        let simple = (keys: n[3], deck: n[4], export: n[5])
        // Pro: the deck only re-stacks (no word lost), so it gives first.
        #expect(pro.deck < pro.export && pro.export < pro.keys)
        // Simple: EXPORT (the share arrow reads alone), then KEYS, the LOOPER word last.
        #expect(simple.export < simple.keys && simple.keys < simple.deck)
    }

    @Test("the gaps give way before any chip, and cannot grow the bar")
    func gapsGiveFirst() {
        let bar = Self.bar
        guard let gap = Self.site(in: bar, from: "struct TransportGap", to: "struct CountInNudgeButton")
        else { return }
        #expect(gap.contains("static let full: CGFloat = 20"))
        #expect(gap.contains("static let tightest: CGFloat = 8"))
        #expect(gap.contains("maxHeight: 0"), "a gap with height could grow the 64 pt bar")
        // A gap with a priority would compete with the chips instead of paying first.
        #expect(!bar.contains("TransportGap()\n                .layoutPriority")
                && !bar.contains("TransportGap().layoutPriority"))
    }

    @Test("KEYS, the loop deck and EXPORT stay in BOTH densities")
    func nothingNewIsProGated() {
        for block in Self.proOnlyBlocks(in: Self.bar) {
            for name in ["musicalTypingToggle", "LoopDeckControls(", "exportButton"] {
                #expect(!block.contains(name), "\(name) is inside an `if isPro` block")
            }
        }
    }

    @Test("an over-wide bar overflows to the RIGHT, never off the left edge")
    func overflowIsLeadingAnchored() {
        guard let body = Self.site(in: Self.bar, from: "var body: some View", to: ".glassPanel()")
        else { return }
        #expect(body.contains(".frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)"),
                "a centred over-wide bar cuts the return-to-zero button off the left edge")
    }

    // MARK: - ③ The leading anchor: Pro must fit 340 by arithmetic

    /// ⛔ **THE REGRESSION THIS PINS: an anchor that stopped fitting and nobody
    /// noticed for months.** PANIC and the count-in stepper arrived after the
    /// 340 pt anchor was set; Pro's row became 369 and squeezed its own labels at
    /// every window width. This recomputes Pro's row from the fonts the chips draw
    /// with, at the spacing the source ships, over the buttons the source
    /// actually places — so a FIFTH round button, a longer chip word or a wider
    /// stepper fails here. (MEASURED on staging, 2026-09-25: 339.3 of 340 at 5 pt.)
    @Test("Pro's leading cluster fits the 340 pt anchor at the shipped spacing")
    func proLeadingClusterFits() {
        let bar = Self.bar
        #expect(bar.contains("static let leadingAnchorWidth: CGFloat = 340"))
        // The Pro spacing is READ from the source, not restated, so the
        // arithmetic below checks what ships.
        let spacingPattern = #"private var leadingSpacing: CGFloat \{ isPro \? (\d+(?:\.\d+)?) : 10 \}"#
        guard let spacingRegex = try? NSRegularExpression(pattern: spacingPattern),
              let spacingMatch = spacingRegex.firstMatch(in: bar, range: NSRange(bar.startIndex..., in: bar)),
              let spacingRange = Range(spacingMatch.range(at: 1), in: bar),
              let proSpacing = Double(bar[spacingRange]) else {
            Issue.record("leadingSpacing's Pro value was not found"); return
        }
        guard let cluster = Self.site(in: bar, from: "private var transportButtons",
                                      to: "private var recordHelp") else { return }
        let buttons = cluster.components(separatedBy: "TransportButton(").count - 1
        #expect(buttons == 4, "the cluster's round-button count changed — re-measure the anchor")

        let chipFace = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        let microFace = NSFont.monospacedSystemFont(ofSize: 9, weight: .bold)
        func advance(_ s: String, _ font: NSFont, tracking: CGFloat) -> CGFloat {
            (s as NSString).size(withAttributes: [.font: font]).width + tracking * CGFloat(s.count)
        }
        func chip(_ word: String) -> CGFloat { advance(word, chipFace, tracking: 0.8) + 2 * 9 }
        let stepper = 14 + 3 + max(24, advance("IN 4", microFace, tracking: 0.5)) + 3 + 14
        let clickColumn = max(chip("CLICK"), stepper)
        let items = CGFloat(buttons) * 38 + chip("LOOP") + chip("PUNCH") + clickColumn
        let gaps = CGFloat(buttons + 3 - 1)
        let pro = items + gaps * CGFloat(proSpacing)
        let proAtTen = items + gaps * 10
        #expect(pro <= 340,
                "Pro's leading cluster is \(pro) pt at \(proSpacing) pt spacing — it overflows the 340 pt anchor")
        // The control: the spacing the anchor could not afford really does not
        // fit, so this test can fail.
        #expect(proAtTen > 340, "control: at 10 pt spacing Pro measured \(proAtTen) — expected > 340")
    }

    // MARK: - ④ TB-F1: the fit rule's compact forms (2026-09-27)

    private static let stripPath = "DAWApp/Components/LoopDeckStrip.swift"

    /// ⛔ THE FEEDBACK TRAP: a probe on the right region reports its OVERFLOWING
    /// width once it stops fitting, and a rule fed that number never compacts.
    /// The two probes must measure things the plan cannot move.
    @Test("TB-F1: two probes the plan cannot move feed the rule, and none sits on the right region")
    func fitProbesFeedTheRule() {
        let bar = Self.bar
        #expect(bar.components(separatedBy: ".onGeometryChange(for: CGFloat.self)").count - 1 == 2,
                "the bar should measure exactly two widths: its own and its leading cluster's")
        #expect(bar.contains("TransportBarFit.regionWidth(barWidth: barWidth,"))
        #expect(bar.contains("TransportBarFit.plan("))
        if let body = Self.site(in: bar, from: "var body: some View", to: ".glassPanel()") {
            // The bar probe follows the proposal-sized frame, so its width is the bar's.
            if let frame = Self.offset(of: ".frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)", in: body),
               let probe = body.range(of: ".onGeometryChange(for: CGFloat.self)", options: .backwards)
                .map({ body.distance(from: body.startIndex, to: $0.lowerBound) }) {
                #expect(frame < probe, "the bar probe measures content, not the proposal")
            } else {
                Issue.record("the bar's frame or its probe is missing")
            }
            #expect(body.contains("leadingClusterWidth = $0") && body.contains("barWidth = $0"))
        }
        if let region = Self.site(in: bar, from: "private var rightRegion", to: "private var leadingSpacing") {
            #expect(!region.contains("onGeometryChange"),
                    "a probe on the right region reads its overflow and the rule never compacts")
            #expect(region.contains("let plan = fitPlan"))
        }
    }

    @Test("TB-F1: the looper's compact forms are the rule's choice, never a ViewThatFits")
    func compactLooperIsTheRulesChoice() {
        let deck = Self.deck
        for (from, to) in [("private func compactStrip", "private enum CompactDeckLight"),
                           ("private var tightStartControls", "private func startChip"),
                           ("private var compactSessionControls", "private func finishButton")] {
            guard let site = Self.site(in: deck, from: from, to: to) else { continue }
            #expect(!site.contains("ViewThatFits"),
                    "\(from) wraps a stateful surface in a ViewThatFits (DESIGN-LANGUAGE forbids it)")
        }
        if let body = Self.site(in: deck, from: "var body: some View", to: ".accessibilityLabel(\"Looper\")") {
            #expect(body.contains("form == .compact"), "the body no longer obeys the rule's form")
            #expect(body.contains("compactStrip(status)") && body.contains("tightStartControls"))
        }
        // The bar hands the deck the rule's form and lamp box.
        #expect(Self.bar.contains("form: plan.looper,") && Self.bar.contains("lampBoxWidth: plan.lampBoxWidth,"))
    }

    @Test("TB-F1: every compact form keeps its words in a tooltip AND an accessibility label")
    func compactFormsKeepTheirWords() {
        let bar = Self.bar
        let deck = Self.deck
        let cases: [(String, String, String, [String])] = [
            (bar, "private func noticesChip", "EngineNoticesChip(model: model",
             [".help(model.chipHelp)", ".accessibilityLabel(model.badgeCount == 1"]),
            (bar, "private func testToneButton", "private func noticesChip",
             [".help(\"Test tone (verifies audio output)\")", ".accessibilityLabel(\"Test tone\")"]),
            (deck, "private func compactStrip", "private func compactSweep",
             [".help(TransportDeckCopy.compactDeckHelp(", ".accessibilityLabel(\"Loop deck\")",
              ".accessibilityValue(TransportDeckCopy.compactDeckAccessibilityValue("]),
            (deck, "private func compactLamp", "private enum CompactDeckLight",
             [".accessibilityLabel(\"\\(lamp.trackName) loop layer, \\(lamp.state.rawValue)\")",
              ".help(lamp.isMuted"]),
        ]
        for (source, from, to, needles) in cases {
            guard let site = Self.site(in: source, from: from, to: to) else { continue }
            for needle in needles {
                #expect(site.contains(needle), "\(from) lost \(needle)")
            }
        }
        // ⛔ The full chip is pinned, so its count can never be squeezed out again
        // (after TB it read as a bare triangle at every window width).
        if let full = Self.site(in: bar, from: "EngineNoticesChip(model: model", to: "struct TransportButton") {
            #expect(full.contains("EngineNoticesChip(model: model, isOpen: isOpen, action: toggle)\n                .fixedSize()"),
                    "the notices chip is unpinned — its count shrinks to nothing when the bar is short")
        }
        // The tight door drops only the door's word: FREE and the stepper stay on
        // screen, and the glyph door is `startChip`, whose label and tooltip say "looper".
        if let tight = Self.site(in: deck, from: "private var tightStartControls", to: "private func startChip") {
            for needle in ["startChip(compact: true)", "freeChip(mini: false)", "barsStepper"] {
                #expect(tight.contains(needle), "the tight door lost \(needle)")
            }
        }
    }

    @Test("TB-F1: the compact forms draw from the rule's own constants")
    func compactGeometryIsRead() {
        let deck = Self.deck
        for needle in ["TransportBarFit.CompactDeck.controlSide", "TransportBarFit.CompactDeck.controlSpacing",
                       "TransportBarFit.CompactDeck.armGlyphSize", "TransportBarFit.CompactDeck.controlGlyphSize",
                       "TransportBarFit.CompactDeck.armColumnWidth",
                       "deck.capsulePadding", "deck.sweepSpacing", "deck.sweepWidth", "deck.lampHeight",
                       "TransportBarFit.compactLampLayout(count: status.lamps.count, boxWidth: lampBoxWidth)",
                       "TransportBarFit.LengthChoice.stepperSpacing",
                       "TransportBarFit.LengthChoice.barsReadoutMinWidth",
                       "TransportBarFit.TightDoor.rowSpacing", "TransportBarFit.TightDoor.rowGap",
                       "TransportBarFit.FullDeck.controlSide", "TransportBarFit.FullDeck.controlSpacing",
                       "TransportBarFit.FullDeck.stripToControls", "TransportBarFit.CompactDeck.capsuleToControls"] {
            #expect(deck.contains(needle), "LoopDeckControls restates \(needle) instead of reading it")
        }
        #expect(!deck.contains(".frame(width: 26, height: 26)"), "a deck button hard-codes its side again")
        let bar = Self.bar
        #expect(bar.contains("static let compactSide: CGFloat = TransportBarFit.chipSide"))
        #expect(bar.contains(".frame(width: TransportBarFit.vibeMeterWidth, height: 44)"))
        #expect(bar.contains("side: compact ? TransportBarFit.chipSide : TransportBarFit.testToneWidth"))
    }

    /// ⛔ macOS draws a `.borderlessButton` menu's label as a flat template glyph, so a
    /// fill, stroke or glow INSIDE the label never reaches the screen: the ARM showed a
    /// bare grey ◉ in TB's 1600 pt capture and in TB-F1's recording probe, under a
    /// comment promising an amber chip. The chip and its light must be drawn OUTSIDE
    /// the label, behind the menu — and the menu framed to a known column, because the
    /// platform lays it out at its own box (25 pt at the compact size, measured).
    @Test("TB-F1: the ARM's chip and light are drawn outside its menu's label, in a framed column")
    func armLightIsOutsideTheMenuLabel() {
        guard let arm = Self.site(in: Self.deck, from: "private func armButton", to: "private var pulse") else { return }
        guard let label = Self.site(in: arm, from: "} label: {", to: "} primaryAction: {") else { return }
        for needle in [".fill(armFill)", "armStroke", ".glow("] {
            #expect(!label.contains(needle), "the ARM's \(needle) is back inside the menu's label — macOS flattens it away")
            #expect(arm.contains(needle), "the ARM lost \(needle)")
        }
        #expect(arm.contains(".menuStyle(.borderlessButton)") && arm.contains("primaryAction: {"),
                "the ARM's menu changed — its click and hold were verified only as they were")
        if let frame = Self.offset(of: ".frame(width: columnWidth ?? side, height: side)", in: arm),
           let fixed = Self.offset(of: ".fixedSize()", in: arm),
           let chip = Self.offset(of: ".background(", in: arm) {
            #expect(fixed < frame && frame < chip,
                    "the ARM must be fixed-size, THEN framed to its column, THEN drawn over its chip")
        } else {
            Issue.record("the ARM lost its fixed size, its column frame or its chip background")
        }
        // The compact grid gives the ARM its measured column, and TAKE BACK the same.
        if let grid = Self.site(in: Self.deck, from: "private var compactSessionControls", to: "private func finishButton") {
            #expect(grid.contains("columnWidth: armColumn)"))
            #expect(grid.contains(".frame(width: armColumn)"), "TAKE BACK no longer lines up under the ARM")
        }
    }

    /// The rule models the widths of views it cannot read (TB's literals and a
    /// strip this lane does not own). "The record says X, the source says Y, and
    /// nothing compares them" is this tree's characteristic failure — so compare.
    @Test("TB-F1: the rule's mirrored widths match the literals in the sources they mirror")
    func mirroredWidthsMatchTheirSources() {
        let bar = Self.bar
        func literal(_ pattern: String, in source: String) -> Double? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
                  let range = Range(match.range(at: 1), in: source) else { return nil }
            return Double(source[range])
        }
        #expect(literal(#"static let tightest: CGFloat = (\d+(?:\.\d+)?)"#, in: bar)
                == Double(TransportBarFit.gapTightest), "TransportGap and the rule disagree on the tightest gap")
        #expect(literal(#"struct CountInNudgeButton[\s\S]*?\.frame\(width: (\d+(?:\.\d+)?), height: 11\)"#, in: bar)
                == Double(TransportBarFit.LengthChoice.nudgeWidth))
        #expect(literal(#"struct TransportButton[\s\S]*?var side: CGFloat = (\d+(?:\.\d+)?)"#, in: bar)
                == Double(TransportBarFit.testToneWidth))
        if let master = Self.site(in: bar, from: "private var masterCluster", to: "private var exportButton") {
            #expect(master.contains("HStack(spacing: 6)"))
            #expect(master.components(separatedBy: ".frame(width: 10, height: 44)").count - 1 == 2)
            let masterParts: [CGFloat] = [10, 6, 10]
            #expect(TransportBarFit.masterClusterWidth == masterParts.reduce(0, +))
        }
        #expect(bar.contains("static let leadingAnchorWidth: CGFloat = 340")
                && bar.contains(".frame(minWidth: 76, alignment: .leading)")
                && bar.contains(".frame(minWidth: 104, alignment: .leading)"))
        // anchor + divider + Position + Time + the measured tempo (88), four spacings.
        let leadingParts: [CGFloat] = [340, 1, 76, 104, 88, 20, 20, 20, 20]
        #expect(TransportBarFit.leadingClusterRestingWidth == leadingParts.reduce(0, +))

        // The strip (read-only to TB-F1): its padding, sweep, spacings and lamp column.
        let strip = Self.codeOnly(Self.text(Self.stripPath))
        #expect(strip.contains(".padding(.horizontal, 10)"))
        #expect(strip.contains(".frame(width: 4, height: 30)"))
        #expect(strip.contains("HStack(spacing: 10) {\n            cycleSweep"))
        #expect(strip.contains("HStack(spacing: 6) {\n            ZStack(alignment: .bottom)"))
        #expect(strip.contains(".frame(width: 42)"), "the lamp caption column moved — re-measure FullDeck.lampWidth")
        #expect(strip.contains("HStack(spacing: 8) {\n                    ForEach(status.lamps"))
        #expect(strip.contains(".frame(width: 26, height: 30)"))
        let chromeParts: [CGFloat] = [10, 4, 6, 10, 10]
        #expect(TransportBarFit.FullDeck.stripChrome == chromeParts.reduce(0, +))
        #expect(TransportBarFit.FullDeck.lampWidth == 42 && TransportBarFit.FullDeck.lampSpacing == 8
                && TransportBarFit.FullDeck.emptyHintWidth == 26)
    }
}
