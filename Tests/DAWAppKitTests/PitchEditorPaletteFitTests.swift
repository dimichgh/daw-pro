import AppKit
import CoreGraphics
import DAWCore
import Foundation
import Testing
@testable import DAWAppKit

/// W7-NTU — the pitch editor's tool palette at the 1208 pt window floor: the
/// engaged tool's HELP shows IN FULL beside every readout the Wobble tool shows
/// at rest (a hover), measured with the view's own fonts and metrics
/// (`PitchEditorPaletteLayout`, which `PitchEditorToolPalette` draws with).
///
/// ⚠️ **WHY A MEASUREMENT AND NOT A STRING PIN.** C5a-F11 made the Wobble help
/// fit at the floor and pinned it with exact strings and ONE looked-at capture
/// (`c5a4b-6-floor-1208`). C5b-4b then added "Hold ⌘ to draw instead." to that
/// help, every pin was updated to the new string, every test stayed green, and
/// the help no longer fit: MEASURED on that capture, the one-line help ended
/// ~31 pt before the hover readout, and the new sentence needs ~105. A string
/// pin cannot see a width; this suite does.
///
/// What it cannot see: SwiftUI's own line breaking (TextKit here, with a 4 pt
/// margin) and the drawn row. The looked-at gate (`m23ap-ntu-header.mjs`,
/// the Wobble leg at 1208) is the drawn half.
///
/// W7-NTU U3 (round 2): the Voice tool is a FOURTH slot, so every help here
/// is measured beside four slots, and the Voice help has its own leg
/// (`voiceHelpFitsAtTheFloor`; `m23ap-ntu-voice.mjs` draws it at 1208).
///
/// NOT `@MainActor`: pure measurement (the review-cadence slots are bounded).
@Suite("PitchEditorPaletteFit — the tool help shows in full at the 1208 pt floor (W7-NTU)")
struct PitchEditorPaletteFitTests {
    typealias P = PitchEditorPaletteLayout

    /// The pane at the floor: the window less its 12 pt padding each side.
    static let floorPane = WindowFloor.minWidth - WindowFloor.outerHorizontalPadding

    static func textWidth(_ string: String, _ font: NSFont) -> CGFloat {
        ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }

    static func symbolWidth(_ tool: PitchEditorTool) -> CGFloat? {
        let config = NSImage.SymbolConfiguration(pointSize: P.slotIconSize, weight: .medium)
        return NSImage(systemSymbolName: tool.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)?.size.width
    }

    /// A slot's drawn width: the symbol, the gap, the name, the capsule's
    /// padding each side.
    static func slotWidth(_ tool: PitchEditorTool) -> CGFloat {
        ceil(symbolWidth(tool) ?? 0) + P.slotInnerSpacing
            + textWidth(tool.label, NSFont.systemFont(ofSize: P.slotLabelSize, weight: .medium))
            + 2 * P.slotHorizontalPadding
    }

    static func readoutWidth(_ readout: String) -> CGFloat {
        textWidth(readout, NSFont.monospacedSystemFont(ofSize: P.readoutFontSize, weight: .semibold))
    }

    /// TextKit's line count for the help at `width` (no padding).
    static func helpLines(_ text: String, width: CGFloat) -> Int {
        let storage = NSTextStorage(string: text,
                                    attributes: [.font: NSFont.systemFont(ofSize: P.helpFontSize)])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        var count = 0
        var index = 0
        while index < manager.numberOfGlyphs {
            var range = NSRange()
            manager.lineFragmentRect(forGlyphAt: index, effectiveRange: &range)
            count += 1
            index = NSMaxRange(range)
        }
        return count
    }

    static var slots: [CGFloat] { PitchEditorTool.allCases.map(slotWidth) }

    /// The readouts the Wobble tool draws at REST, hovering a note
    /// (`PitchWobbleGesture.ownWords` at keep 1): C5a-F11's own, the widest
    /// numbers, the speed alone, and the three sentences.
    static let atRestReadouts: [String?] = [
        nil,
        PitchWobbleCopy.yourWobble(heardRateHz: 5.5, depthCents: 55),
        PitchWobbleCopy.yourWobble(heardRateHz: 12, depthCents: 200),
        PitchWobbleCopy.yourWobble(heardRateHz: 5.5, depthCents: nil),
        PitchWobbleCopy.tooShortToMeasure,
        PitchWobbleCopy.tooUnevenToMeasure,
        PitchWobbleCopy.noWobbleToMeasure,
    ]

    /// The readouts the Voice tool draws at REST, hovering a note
    /// (`PitchEditorModel.voiceReadout(hover:)`): none, as sung, the UI's
    /// deepest, the wire's brightest (the widest number), and R11's line.
    static let voiceReadouts: [String?] = [
        nil,
        PitchEditorFormantCopy.voiceToolReadout(0),
        PitchEditorFormantCopy.voiceToolReadout(-6),
        PitchEditorFormantCopy.voiceToolReadout(24),
        PitchEditorFormantCopy.voiceTooShort,
    ]

    @Test("the measuring is real: every slot's symbol loads, and the floor pane is 1184 pt")
    func measuringIsReal() {
        #expect(Self.floorPane == 1184)
        for tool in PitchEditorTool.allCases {
            let width = Self.symbolWidth(tool)
            // A symbol that failed to load would measure 0 and let every fit pass.
            #expect((width ?? 0) > 5, "\(tool.symbolName) measured \(String(describing: width))")
        }
        #expect(Self.readoutWidth("Your wobble") > 50)
    }

    /// Planted and seen red (W7-NTU P-help1): `helpLineLimit` back to 1.
    @Test("⭐ the Wobble help fits in its TWO lines beside every at-rest readout at the 1208 pt floor — and ONE line would not (C5a-F11's own readout)")
    func wobbleHelpFitsAtTheFloor() {
        let help = PitchEditorTool.wobble.help
        #expect(help.contains("Hold ⌘ to draw instead."), "the sentence this suite exists for is gone")
        #expect(Self.atRestReadouts[1] == "Your wobble: about 5.5 per second, about 55 cents each way",
                "C5a-F11's captured readout changed; re-derive this suite's case")
        for readout in Self.atRestReadouts {
            let width = P.helpWidth(rowWidth: Self.floorPane, slotWidths: Self.slots,
                                    readoutWidth: readout.map(Self.readoutWidth))
            // A 4 pt margin: SwiftUI's line breaker is not TextKit's.
            let lines = Self.helpLines(help, width: width - 4)
            #expect(lines <= P.helpLineLimit,
                    "beside \"\(readout ?? "no readout")\": \(lines) lines in \(width) pt")
        }
        // CONTROL — the reason for two: beside C5a-F11's readout ONE line is
        // not enough (were it, the two-line box would be chrome for nothing).
        let captured = P.helpWidth(rowWidth: Self.floorPane, slotWidths: Self.slots,
                                   readoutWidth: Self.atRestReadouts[1].map(Self.readoutWidth))
        #expect(Self.helpLines(help, width: captured) > 1,
                "one line holds the help in \(captured) pt — the two-line box is unneeded")
    }

    /// Planted and seen red (W7-NTU P-v-fit): one more sentence in the Voice
    /// help ("The note keeps its pitch while its voice changes."), which makes
    /// it three lines beside R11's line.
    @Test("⭐ W7-NTU U3 — the Voice help fits its TWO lines beside every Voice readout at the 1208 pt floor, beside FOUR slots — and ONE line would not hold it even alone")
    func voiceHelpFitsAtTheFloor() {
        let help = PitchEditorTool.voice.help
        #expect(help.contains("Double-click"), "the sentence this leg measures is gone")
        #expect(Self.slots.count == 4, "the palette's slot count changed: re-read this suite")
        #expect(Self.voiceReadouts[3] == "Voice: brighter 24.0")
        for readout in Self.voiceReadouts {
            let width = P.helpWidth(rowWidth: Self.floorPane, slotWidths: Self.slots,
                                    readoutWidth: readout.map(Self.readoutWidth))
            // A 4 pt margin: SwiftUI's line breaker is not TextKit's.
            let lines = Self.helpLines(help, width: width - 4)
            #expect(lines <= P.helpLineLimit,
                    "beside \"\(readout ?? "no readout")\": \(lines) lines in \(width) pt")
        }
        // CONTROL — the measuring can say NO: with no readout at all, ONE line
        // does not hold the Voice help (so the two-line box is what holds it).
        let alone = P.helpWidth(rowWidth: Self.floorPane, slotWidths: Self.slots, readoutWidth: nil)
        #expect(Self.helpLines(help, width: alone) > 1,
                "one line holds the Voice help in \(alone) pt")
    }

    @Test("every tool's help fits its two lines at the floor with no readout; Move and Split fit in one")
    func everyToolsHelpFits() {
        let width = P.helpWidth(rowWidth: Self.floorPane, slotWidths: Self.slots, readoutWidth: nil)
        for tool in PitchEditorTool.allCases {
            #expect(Self.helpLines(tool.help, width: width - 4) <= P.helpLineLimit, "\(tool)")
        }
        #expect(Self.helpLines(PitchEditorTool.pointer.help, width: width - 4) == 1)
        #expect(Self.helpLines(PitchEditorTool.scissors.help, width: width - 4) == 1)
        // The brush's help (⌘ held) takes the same slot.
        #expect(Self.helpLines(PitchShapeBrush.help, width: width - 4) <= P.helpLineLimit)
    }

    @Test("the help's box holds two lines of its font, one height for one line or two")
    func helpBoxHeight() {
        let line = NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: P.helpFontSize))
        #expect(CGFloat(P.helpLineLimit) * line <= P.helpHeight,
                "\(P.helpLineLimit) lines need \(CGFloat(P.helpLineLimit) * line) pt")
        #expect(P.helpLineLimit == 2)
    }

    @Test("the fit rule's arithmetic: the readout and the gaps come off the row before the help")
    func helpWidthRule() {
        // 3 slots of 60, a 300 pt readout, in a 1184 pt row: 1184 − 24 − 180
        // − 300 − 5 × 8 = 640.
        #expect(P.helpWidth(rowWidth: 1184, slotWidths: [60, 60, 60], readoutWidth: 300) == 640)
        // No readout: one gap fewer.
        #expect(P.helpWidth(rowWidth: 1184, slotWidths: [60, 60, 60], readoutWidth: nil) == 948)
        #expect(P.helpWidth(rowWidth: 100, slotWidths: [60, 60, 60], readoutWidth: 300) == 0)
    }

    // MARK: - The view draws with these, read off the source

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

    /// Comment-stripped source (`PitchEditorInteractionSiteTests`' reader).
    private static func code(_ relativePath: String) -> String {
        let url = sourcesDir().appendingPathComponent(relativePath)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("Could not read \(relativePath) under \(sourcesDir().path)")
            return ""
        }
        return content.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                return ""
            }
            return line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
        }.joined(separator: "\n")
    }

    /// Planted and seen red (W7-NTU P-help1, view side): the palette's help
    /// back to `.lineLimit(1)`.
    @Test("the palette draws its help with these metrics: two lines, a fixed box, the slots' own numbers")
    func paletteDrawsWithTheLayout() {
        let view = Self.code("DAWApp/PitchEditor/PitchEditorView.swift")
        // The palette's struct, up to the next declaration in the file.
        guard let start = view.range(of: "struct PitchEditorToolPalette: View"),
              let end = view.range(of: "enum PitchEditorZoomCommand", range: start.upperBound..<view.endIndex)
        else {
            Issue.record("the palette's source was not found")
            return
        }
        let palette = String(view[start.lowerBound..<end.lowerBound])
        #expect(palette.contains(".lineLimit(PitchEditorPaletteLayout.helpLineLimit)"))
        #expect(palette.contains(".frame(height: PitchEditorPaletteLayout.helpHeight, alignment: .leading)"))
        #expect(palette.contains(".font(.system(size: PitchEditorPaletteLayout.helpFontSize))"))
        #expect(palette.contains("HStack(spacing: PitchEditorPaletteLayout.spacing)"))
        #expect(palette.contains(".padding(.horizontal, PitchEditorPaletteLayout.slotHorizontalPadding)"))
        #expect(palette.contains(".padding(.horizontal, PitchEditorPaletteLayout.horizontalPadding)"))
        #expect(!palette.contains(".lineLimit(1)\n                Spacer(minLength: 0)"),
                "the help is back on one line")
    }
}
