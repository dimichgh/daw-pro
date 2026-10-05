import AppKit
import CoreGraphics
import DAWCore
import Foundation
import Testing
@testable import DAWAppKit

/// Tune to Melody, M3 (W7-TTM3): every word of the card and its menu item, MEASURED with the
/// view's own fonts and dimensions (`TuneToMelodyCardLayout`, which `TuneToMelodyCardView`
/// draws with), and the whole card's worst case against the window floor's HEIGHT.
///
/// The `PitchEditorPaletteFitTests` pattern, for its reason: a string pin cannot see a width.
/// The card is 440 pt wide, so the 1208 pt floor's width is never the problem; its 640 pt
/// HEIGHT is, with a picker that could list every MIDI track in a song. So the picker scrolls
/// past `maxVisibleRows`, and this suite adds the card up row by row at its tallest (the longest
/// chip line, the longer octave line, a long melody name in the result, the far-move note with
/// its tip, or the store's longest refusal) and holds it inside the floor.
///
/// What it cannot see: SwiftUI's own line breaking (TextKit here, no padding) and the drawn
/// card. The looked-at gate (`scripts/gates/m23ap-ttm3-card.mjs`) is the drawn half.
///
/// Every string's width (one line) or line count (wrapped) is PRINTED as
/// `[measured] TTM3 …`, so the report quotes a measurement, not a guess.
///
/// NOT `@MainActor`: pure measurement.
@Suite("Tune to Melody M3 — every word fits the card, and the card fits the window floor (W7-TTM3)")
struct TuneToMelodyCardFitTests {
    typealias L = TuneToMelodyCardLayout
    typealias C = TuneToMelodyCopy

    static func width(_ string: String, _ font: NSFont, kern: CGFloat = 0) -> CGFloat {
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if kern != 0 { attributes[.kern] = kern }
        return ceil((string as NSString).size(withAttributes: attributes).width)
    }

    /// TextKit's line count for `text` wrapped at `width` (no padding).
    static func lines(_ text: String, _ font: NSFont, width: CGFloat) -> Int {
        let storage = NSTextStorage(string: text, attributes: [.font: font])
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

    static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(NSLayoutManager().defaultLineHeight(for: font))
    }

    static func height(_ text: String, _ font: NSFont, width: CGFloat) -> CGFloat {
        CGFloat(lines(text, font, width: width)) * lineHeight(font)
    }

    static var body: NSFont { NSFont.systemFont(ofSize: L.bodySize) }
    static var caption: NSFont { NSFont.systemFont(ofSize: L.captionSize) }
    static var fieldLabel: NSFont { NSFont.systemFont(ofSize: L.fieldLabelSize, weight: .semibold) }
    static var chip: NSFont { NSFont.systemFont(ofSize: L.chipLabelSize, weight: .semibold) }
    static var title: NSFont { NSFont.monospacedSystemFont(ofSize: L.titleSize, weight: .bold) }
    static var button: NSFont { NSFont.monospacedSystemFont(ofSize: L.buttonLabelSize, weight: .bold) }
    static var rowDetail: NSFont { NSFont.systemFont(ofSize: L.rowDetailSize) }
    static var menu: NSFont { NSFont.menuFont(ofSize: 0) }

    /// A melody name longer than any a generated song writes, for the worst-case result.
    static let longName = "Lead melody (verse and chorus) take 12"

    /// The result line's wrap width: the card's text width less the icon column.
    static var resultWidth: CGFloat { L.textWidth - L.resultIconColumn }
    /// The octave line's wrap width: indented past the checkbox.
    static var octaveWidth: CGFloat { L.textWidth - L.checkboxSize - L.checkboxSpacing }

    @Test("the measuring is real: a long line wraps, a short one does not, and the text width is 404 pt")
    func measuringIsReal() {
        #expect(L.textWidth == 404)
        #expect(Self.lines("Short.", Self.body, width: L.textWidth) == 1)
        #expect(Self.lines(String(repeating: "word ", count: 120), Self.body, width: L.textWidth) > 3)
        #expect(Self.width("Hard Tune", Self.chip) > 20)
        #expect(Self.lineHeight(Self.body) > 10)
    }

    @Test("F1 the four preset chips' names fit their equal quarter of the row")
    func chipsFit() {
        let chipWidth = L.textWidth / CGFloat(TuneToMelodyCard.presets.count)
        for preset in TuneToMelodyCard.presets {
            let w = Self.width(preset.displayName, Self.chip)
            print("[measured] TTM3 chip '\(preset.displayName)' \(w) pt of \(chipWidth)")
            #expect(w + 2 * 8 <= chipWidth, "\(preset.displayName) needs \(w) + 16 pt, the chip has \(chipWidth)")
        }
    }

    @Test("F2 a picker row's detail fits beside the name's reserved width, on a clip row (indented) at 9999 notes")
    func rowFits() {
        let worst = TuneToMelodyChoice(source: .clip(UUID()), name: Self.longName, trackName: "Lead",
                                       notesUnderVocal: 9999)
        let detail = Self.width(C.choiceDetail(worst), Self.rowDetail)
        // dot 9, gap 8, the reserved name, spacer 8, the detail, the clip indent and both paddings.
        let total = 9 + 8 + L.rowMinNameWidth + 8 + detail + (L.rowHorizontalPadding + 14)
            + L.rowHorizontalPadding
        print("[measured] TTM3 row detail '\(C.choiceDetail(worst))' \(detail) pt; row total \(total) of \(L.textWidth)")
        #expect(total <= L.textWidth)
    }

    @Test("F3 the header, the footer (the longer of APPLY / TUNING… with its spinner) and the field labels fit one line")
    func oneLinersFit() {
        let titleW = Self.width(C.title, Self.title, kern: 1.6)
        print("[measured] TTM3 title '\(C.title)' \(titleW) pt (+ close 20, gap 8) of \(L.textWidth)")
        #expect(titleW + 8 + 20 <= L.textWidth)
        let undoW = Self.width(C.undoNote, Self.caption)
        let applyW = max(Self.width(C.applyLabel, Self.button, kern: 1),
                         Self.width(C.tuningLabel, Self.button, kern: 1) + 10 + 6) + 2 * 18
        print("[measured] TTM3 footer '\(C.undoNote)' \(undoW) pt + button \(applyW) pt (+ gap 10) of \(L.textWidth)")
        #expect(undoW + 10 + applyW <= L.textWidth)
        for label in [C.melodyLabel, C.soundLabel] {
            let w = Self.width(label.uppercased(), Self.fieldLabel, kern: 1.3)
            print("[measured] TTM3 field label '\(label.uppercased())' \(w) pt")
            #expect(w <= L.textWidth)
        }
        let octaveW = Self.width(C.octaveLabel, Self.body)
        print("[measured] TTM3 switch '\(C.octaveLabel)' \(octaveW) pt (+ box 21)")
        #expect(L.checkboxSize + L.checkboxSpacing + octaveW <= L.textWidth)
    }

    @Test("F4 the menu item and its greyed reason, measured in the menu font (no wider than the menu's own longest entry needs)")
    func menuWordsMeasured() {
        let title = Self.width(C.menuTitle, Self.menu)
        let reason = Self.width(C.noMelodyUnderVocal, Self.menu)
        let neighbour = Self.width("Open Note Editor…", Self.menu)
        print("[measured] TTM3 menu '\(C.menuTitle)' \(title) pt; reason '\(C.noMelodyUnderVocal)' \(reason) pt; "
              + "neighbour 'Open Note Editor…' \(neighbour) pt (menu font \(Self.menu.pointSize) pt)")
        #expect(title <= neighbour + 20, "the item should read as a sibling of Open Note Editor…")
        // A greyed line wider than ~320 pt would stretch the whole submenu into a slab.
        #expect(reason <= 320)
    }

    /// The card at its tallest: every section with its longest possible words.
    @Test("F5 the card at its tallest fits inside the 640 pt window floor (with a 24 pt margin above and below)")
    func cardFitsTheFloorHeight() {
        let lh = Self.lineHeight
        // Header group: title row, source line, the intro.
        let introH = Self.height(C.intro, Self.body, width: L.textWidth)
        let header = L.headerHeight + L.innerSpacing + lh(Self.body) + L.innerSpacing + introH
        // The picker at its cap (it scrolls past `maxVisibleRows`).
        let melody = lh(Self.fieldLabel) + L.innerSpacing + L.pickerHeight(rows: 50)
        // The chips and the longest chip line.
        let chipLines = TuneToMelodyCard.presets.map {
            Self.height(C.presetLine($0), Self.caption, width: L.textWidth)
        }
        let sound = lh(Self.fieldLabel) + L.innerSpacing + L.chipHeight + L.innerSpacing
            + (chipLines.max() ?? 0)
        // The switch and the longer of its two lines.
        let octaveLine = max(Self.height(C.octaveOnLine, Self.caption, width: Self.octaveWidth),
                             Self.height(C.octaveOffLine, Self.caption, width: Self.octaveWidth))
        let octave = max(L.checkboxSize, lh(Self.body)) + L.innerSpacing + octaveLine
        // The result at its longest: a long name, both counts in the hundreds, and the far-move
        // note with its tip; or the store's longest refusal (no melody note under the vocal,
        // with two long names), whichever is taller.
        let worst = TuneToMelodyOutcome(melodyName: Self.longName, melodyIsClip: true,
                                        foundSinging: true, tunedNotes: 999, untouchedNotes: 999,
                                        farMoves: 999, matchedOctave: false)
        let summaryH = Self.height(C.summary(worst), Self.body, width: Self.resultWidth)
        let farH = Self.height(C.farMoveNote(worst) ?? "", Self.caption, width: Self.resultWidth)
        let refusal = "No note of the melody \u{201C}\(Self.longName)\u{201D} plays under the vocal "
            + "\u{201C}\(Self.longName)\u{201D} (beats 128 to 256): its notes play from beat 512 to beat "
            + "640. Move the melody under the vocal, or pick another melody. Nothing was changed."
        let refusalH = Self.height(refusal, Self.caption, width: L.textWidth - 16)
        let result = max(summaryH + L.innerSpacing + farH, refusalH,
                         Self.height(C.foundNoSinging, Self.body, width: Self.resultWidth))
        let sections = [header, melody, sound, octave, result, L.footerHeight]
        let total = 2 * L.padding + sections.reduce(0, +)
            + CGFloat(sections.count - 1) * L.sectionSpacing
        let budget = WindowFloor.minHeight - 2 * L.verticalMargin
        print("[measured] TTM3 card worst case: header \(header), picker \(melody), sound \(sound), "
              + "octave \(octave), result \(result) (summary \(summaryH) + far \(farH); refusal \(refusalH)), "
              + "footer \(L.footerHeight) -> \(total) pt of \(budget) (floor \(WindowFloor.minHeight))")
        #expect(total <= budget, "the card is \(total) pt at its tallest; the floor leaves \(budget)")
    }

    /// Every wrapped line the card draws, with its line count at its own width: printed for the
    /// report, and each held to a sane maximum so one sentence cannot swallow the card.
    @Test("F6 every wrapped line, measured at its own width (printed), none longer than 4 lines")
    func everyWrappedLineMeasured() {
        let worst = TuneToMelodyOutcome(melodyName: "Lead", melodyIsClip: false, foundSinging: true,
                                        tunedNotes: 31, untouchedNotes: 4, farMoves: 3,
                                        matchedOctave: false)
        var measured: [(String, String, NSFont, CGFloat)] = [
            ("intro", C.intro, Self.body, L.textWidth),
            ("octaveOn", C.octaveOnLine, Self.caption, Self.octaveWidth),
            ("octaveOff", C.octaveOffLine, Self.caption, Self.octaveWidth),
            ("summary", C.summary(worst), Self.body, Self.resultWidth),
            ("farMove", C.farMoveNote(worst) ?? "", Self.caption, Self.resultWidth),
            ("foundNoSinging", C.foundNoSinging, Self.body, Self.resultWidth),
            ("noReport", C.noReport, Self.caption, L.textWidth - 16),
            ("noMelody", C.noMelodyUnderVocal, Self.caption, L.textWidth - 16),
        ]
        for preset in TuneToMelodyCard.presets {
            measured.append(("preset \(preset.rawValue)", C.presetLine(preset), Self.caption, L.textWidth))
        }
        for (name, text, font, width) in measured {
            let n = Self.lines(text, font, width: width)
            print("[measured] TTM3 \(name): \(n) line(s) at \(width) pt, one-line width "
                  + "\(Self.width(text, font)) pt: \(text)")
            #expect(n >= 1 && n <= 4, "\(name) takes \(n) lines")
        }
    }

    /// Each preset's OWN one-line summary, drawn at 9 pt under its chip in the Note Editor's
    /// preset column (Hard Tune's was rewritten by this lane's follow-up). The height rule is
    /// `PitchEditorSingerGroupTests.groupHeightAndTheNarrowestPresetColumn`; this measures and
    /// prints each line at the narrowest column for the report, and holds the same ceiling
    /// (5 lines: the 108 pt group less the caption row, gap and chip).
    @Test("F7 every preset's own summary, at the Note Editor's narrowest chip column (9 pt), measured")
    func presetSummariesMeasured() {
        let column = (PitchEditorSingerLayout.presetsMinWidth - 3 * 10) / 4
        let font = NSFont.systemFont(ofSize: 9)
        for preset in PitchCorrectionPreset.offeredInUI {
            let n = Self.lines(preset.summary, font, width: column)
            print("[measured] TTM3 summary \(preset.rawValue): \(n) line(s) at \(column) pt (9 pt), "
                  + "one-line width \(Self.width(preset.summary, font)) pt: \(preset.summary)")
            #expect(n >= 1 && n <= 5, "\(preset.rawValue) takes \(n) lines")
        }
    }
}

