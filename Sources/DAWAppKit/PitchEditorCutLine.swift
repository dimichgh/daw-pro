import CoreGraphics
import Foundation

// m23-ap interaction batch, item I3 — THE CUT LINE.
//
// Design record: `docs/design/2026-09-24-pitch-editor-interaction-batch.md` §6
// (decision D3). The user's words: "when I activate cut mode, it should provide
// a vertical line for visual feedback when I want to cut it".
//
// ⭐⭐ **ONE VERDICT, TWO READERS.** The hover line and the knife are the SAME
// function's answer: `PitchEditorModel.cutVerdict(at:)` produces a
// `PitchEditorCutVerdict`, `PitchEditorModel.splitNote(at:)` is a `switch` over
// it, and the line the view draws (`PitchEditorModel.cutLine(at:)`) carries it
// verbatim. A preview computed by different arithmetic from the action is a
// preview that lies (docs/DESIGN-LANGUAGE.md, the hover ghost line), and on this
// surface it would lie exactly at the note edges, where the 60 ms floor decides.
// `PitchEditorModelTests` sweeps 200 points and requires the knife to split
// exactly where the line said "cut", at the same source second.
//
// This file holds the two VALUES (the verdict and the drawn line) and the one
// piece of drawing geometry that can be decided without a font: where the label
// goes once the view has measured it. SwiftUI-free, so the suite can reach it
// (`DAWApp` has no test target).

/// What the Split tool WOULD do at a point on the surface.
///
/// ⚠️ **DECIDED IN SECONDS, REPORTED IN MILLISECONDS.** The comparison against
/// `PitchAutoCorrect.minimumNoteSeconds` is made on the exact source seconds;
/// `leftMs`/`rightMs`/`minimumMs` are those same numbers ×1000, unrounded, for a
/// reader. Rounding happens only in `label`, for a person. A verdict decided on
/// rounded milliseconds would accept a 59.6 ms half the knife refuses.
public enum PitchEditorCutVerdict: Sendable, Equatable {
    /// The knife would cut the note `segmentID` at `atSourceSecond`, leaving a
    /// left half of `leftMs` and a right half of `rightMs` milliseconds.
    case cut(segmentID: UUID, atSourceSecond: Double, leftMs: Double, rightMs: Double)
    /// The pointer is on the note `segmentID`, but one half would be shorter than
    /// `minimumMs` (`PitchAutoCorrect.minimumNoteSeconds`), so a click is refused.
    /// This includes a point inside the note's hit slop but outside its time
    /// span, where one "half" would be negative.
    case tooCloseToEdge(segmentID: UUID, atSourceSecond: Double, minimumMs: Double)
    /// No note under the pointer.
    case noNote

    /// Stable machine tag for the `debug.pitchEditor` echo.
    public var key: String {
        switch self {
        case .cut: return "cut"
        case .tooCloseToEdge: return "tooCloseToEdge"
        case .noNote: return "noNote"
        }
    }

    /// The note the verdict is about, or `nil` for `.noNote`.
    public var segmentID: UUID? {
        switch self {
        case .cut(let id, _, _, _), .tooCloseToEdge(let id, _, _): return id
        case .noNote: return nil
        }
    }

    /// Where the knife would land, or `nil` for `.noNote`.
    public var atSourceSecond: Double? {
        switch self {
        case .cut(_, let second, _, _), .tooCloseToEdge(_, let second, _): return second
        case .noNote: return nil
        }
    }

    /// The words drawn at the line (design §6, verbatim): "Cut · 240 ms | 310 ms",
    /// "Too close to the edge", or nothing for `.noNote` — where the dim hairline
    /// alone says "move onto a note".
    ///
    /// SF Mono in the view: the two numbers are readouts (docs/DESIGN-LANGUAGE.md,
    /// "SF Mono for every numeric readout").
    public var label: String? {
        switch self {
        case .cut(_, _, let leftMs, let rightMs):
            return "Cut · \(Self.wholeMilliseconds(leftMs)) ms | \(Self.wholeMilliseconds(rightMs)) ms"
        case .tooCloseToEdge:
            return "Too close to the edge"
        case .noNote:
            return nil
        }
    }

    /// Whole milliseconds for a person. A `.cut` half is ≥ the floor in exact
    /// seconds, so it never reads below "60 ms" here.
    static func wholeMilliseconds(_ ms: Double) -> Int {
        ms.isFinite ? Int(ms.rounded()) : 0
    }
}

/// Everything the cut line draws, resolved at ONE home
/// (`PitchEditorModel.cutLine(at:)`). A `nil` line means nothing is drawn: the
/// Split tool is not engaged, the surface has no notes, or the pointer is off it.
public struct PitchEditorCutLine: Sendable, Equatable {
    /// The pointer's x in content space: where the hairline is drawn and where
    /// the knife lands.
    public let x: CGFloat
    /// The source-file second at `x`, through the ONE coordinate home. For
    /// `.cut` and `.tooCloseToEdge` it equals the verdict's `atSourceSecond`.
    public let sourceSecond: Double
    /// THE verdict, verbatim from `PitchEditorModel.cutVerdict(at:)`.
    public let verdict: PitchEditorCutVerdict
    /// The note's drawn rectangle, which the glowing segment spans. `nil` for
    /// `.noNote`.
    public let noteRect: CGRect?

    public init(x: CGFloat, sourceSecond: Double, verdict: PitchEditorCutVerdict,
                noteRect: CGRect?) {
        self.x = x
        self.sourceSecond = sourceSecond
        self.verdict = verdict
        self.noteRect = noteRect
    }

    /// How far the glowing segment reaches past the note, top and bottom
    /// (design §6: "a 2 pt segment (blob ±6 pt)").
    public static let segmentOverhang: CGFloat = 6

    /// The gap between the segment's end and the label's plate.
    ///
    /// ⚠️ **6, NOT 2 — A LOOKED-AT FINDING.** The note's own NAME is drawn just
    /// above it (`PitchEditorSurface.drawBlobLabels`: an 8 pt face anchored 1 pt
    /// over the note, so its glyphs reach ~9 pt up). With a 2 pt gap the plate's
    /// bottom sat 8 pt above the note and covered the top of that name — seen
    /// in the offscreen captures on every verdict at both widths, worst on the
    /// amber one, where the segment also crosses it. 6 + the 6 pt overhang puts
    /// the plate 12 pt clear of the note, above the name.
    public static let labelGap: CGFloat = 6

    /// The glowing segment's vertical span in content space, clamped to the
    /// content, or `nil` when there is no note (`.noNote`: the hairline only).
    public func segmentSpan(contentHeight: CGFloat) -> ClosedRange<CGFloat>? {
        guard let rect = noteRect else { return nil }
        let top = max(0, rect.minY - Self.segmentOverhang)
        let bottom = max(top, min(max(0, contentHeight), rect.maxY + Self.segmentOverhang))
        return top...bottom
    }

    /// Where the label (with its backing plate) goes, as a frame in content
    /// space, or `nil` when there is nothing to label.
    ///
    /// ⭐ **ABOVE THE NOTE, NOT AT THE TOP OF THE CONTENT — A DELIBERATE
    /// DEPARTURE FROM §6, RULED BY THE ORCHESTRATOR 2026-09-24.** The pane
    /// scrolls vertically with no offset reader (design F7), and its content
    /// (12–36 rows) is usually taller than the viewport, so a label pinned to
    /// the content's top edge would often be scrolled out of sight. Above the
    /// note is where the eye already is.
    ///
    /// ⚠️ **IT MUST NEVER CLIP.** A note in the top rows has no room above it,
    /// so the label drops BELOW the segment; horizontally it is centred on the
    /// line and clamped into the content, so a cut near either end of the clip
    /// stays readable. `labelSize` is the MEASURED size of the label and its
    /// plate (the view resolves the text; this target has no fonts).
    public func labelFrame(labelSize: CGSize, contentSize: CGSize) -> CGRect? {
        guard verdict.label != nil,
              let span = segmentSpan(contentHeight: contentSize.height) else { return nil }
        let width = max(0, labelSize.width)
        let height = max(0, labelSize.height)
        var y = span.lowerBound - Self.labelGap - height
        if y < 0 { y = span.upperBound + Self.labelGap }
        y = min(max(0, y), max(0, contentSize.height - height))
        let originX = min(max(0, x - width / 2), max(0, contentSize.width - width))
        return CGRect(x: originX, y: y, width: width, height: height)
    }
}
