import CoreGraphics

/// **The ruler's honest leading edge** (m23-ap I5-F3 addendum, 2026-09-26).
///
/// ## The defect
///
/// The scrub ruler is drawn ONCE at content width and slid under the viewport
/// (`PianoRollScrubRulerBand`'s `.geometryGroup()` strip — the fix for the
/// main-thread freeze, so it may not redraw per scroll). A label hangs
/// `labelGap` to the RIGHT of its tick, so when a tick scrolls off the leading
/// edge its label can straddle the edge, and the band's clip leaves only its
/// TAIL. Measured by the I5-F1-F lane in the pitch editor: 64 pt/beat, a clip at
/// song beat 3.1, scrolled 200 pt — the "2.3" tick sits at −14.4 pt, its text at
/// −11.4…4.8 pt, and the clip leaves a lone **"3" where bar 2 is**. A beginner
/// reads "3".
///
/// ## Why not a pinned "current bar" chip
///
/// A chip of fixed width `W` at the leading edge covers the fragment — and
/// becomes a new edge. Any tick UNDER the chip at screen x `t > W − gap −
/// labelWidth` hangs its text past the chip: at 64 pt/beat, offset 160, a 33 pt
/// chip saying "2" has the "2.3" tick under it at 25.6 pt and ".3" showing to
/// its right. A fixed opaque cover can move the fragment; it cannot remove it
/// (`PianoRollScrubRulerEdgeTests` measures it).
///
/// ## The invariant, and the one thing that enforces it
///
/// **A label shows exactly when its tick does.** `leadingEdgeCover` finds the
/// labels whose tick has left the viewport but whose text still reaches into it
/// (the ORPHANS), and returns the narrowest cover — measured from the band's
/// leading edge — that hides them, plus the VISIBLE ticks under that cover so the
/// view redraws them on top. A redrawn label that starts under the cover grows it
/// to that label's end, so a label is never split between the cover and the
/// strip. The cover is a small viewport-space overlay: it redraws on a scroll
/// (the strip does not), and it is empty whenever nothing straddles the edge.
///
/// Label widths come from the caller (`labelWidth`), because the only exact
/// width is the one the renderer measures: the band passes
/// `GraphicsContext.resolve(Text).measure`, the tests a monospaced model.
///
/// Everything is nonisolated value math, callable from a `@Sendable` Canvas
/// renderer.
extension PianoRollScrubRuler {

    /// Gap between a tick and the label hanging off its right — hoisted from the
    /// band's renderer so the ink and the cover arithmetic share one number.
    public static let labelGap: CGFloat = 3

    /// Extra ground past the last covered label, so antialiased glyph edges are
    /// covered too.
    public static let coverSlack: CGFloat = 1

    /// How far left of the leading edge a tick can sit and still reach into the
    /// viewport with its label — the bound on the backward scan, so a scroll
    /// measures a handful of labels, not the clip's. 80 pt is 14 characters of
    /// the ruler's 9 pt SF Mono (5.56 pt each); the longest label is `bar.beat`
    /// with a four-digit bar ("1024.4", 6 characters, ~33 pt).
    public static let maxLabelReach: CGFloat = 80

    /// What the band paints over its leading edge.
    public struct LeadingEdgeCover: Sendable, Equatable {
        /// Viewport points from the band's leading edge that the cover grounds;
        /// 0 when nothing straddles the edge.
        public let width: CGFloat
        /// The VISIBLE ticks under the cover (content x, ascending), each redrawn
        /// on top of the ground with its label when it has one.
        public let marks: [Tick]

        public init(width: CGFloat, marks: [Tick]) {
            self.width = width
            self.marks = marks
        }

        public static let none = LeadingEdgeCover(width: 0, marks: [])
    }

    /// Whether a tick is on screen at this scroll: its 1 pt line is centred at
    /// `x + 0.5`, so a line whose centre has left the viewport counts as gone.
    public static func isTickVisible(_ tick: Tick, scrollX: CGFloat) -> Bool {
        tick.x + 0.5 >= scrollX
    }

    /// The cover for `ticks` (content space, ascending — both producers' order)
    /// scrolled to `scrollX`. See the type's note for the rule.
    public static func leadingEdgeCover(ticks: [Tick], scrollX: CGFloat,
                                        labelWidth: (String) -> CGFloat) -> LeadingEdgeCover {
        // First visible tick, by binary search: ticks ascend in x.
        var lo = 0, hi = ticks.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if isTickVisible(ticks[mid], scrollX: scrollX) { hi = mid } else { lo = mid + 1 }
        }
        let firstVisible = lo
        // 1. The orphans: labelled ticks off the edge whose text reaches past it.
        var reach: CGFloat = 0
        var i = firstVisible - 1
        while i >= 0, ticks[i].x >= scrollX - maxLabelReach {
            if let text = ticks[i].label {
                let end = ticks[i].x + labelGap + labelWidth(text) - scrollX
                if end > 0 { reach = max(reach, end + coverSlack) }
            }
            i -= 1
        }
        guard reach > 0 else { return .none }
        // 2. The visible ticks under the cover are redrawn on it; one whose label
        //    starts under the cover grows it to the label's end (never a split).
        var marks: [Tick] = []
        var j = firstVisible
        while j < ticks.count {
            let x = ticks[j].x - scrollX
            guard x < reach else { break }
            marks.append(ticks[j])
            if let text = ticks[j].label {
                reach = max(reach, x + labelGap + labelWidth(text) + coverSlack)
            }
            j += 1
        }
        return LeadingEdgeCover(width: reach, marks: marks)
    }

    /// The labels a viewer would read WITHOUT their tick — text past the cover
    /// while the tick has left the viewport. Empty is the invariant; the tests
    /// sweep it, and a plant that drops the cover makes it non-empty.
    public static func strandedLabels(ticks: [Tick], scrollX: CGFloat, coverWidth: CGFloat,
                                      labelWidth: (String) -> CGFloat) -> [String] {
        var out: [String] = []
        for tick in ticks where !isTickVisible(tick, scrollX: scrollX) {
            guard let text = tick.label else { continue }
            let end = tick.x + labelGap + labelWidth(text) - scrollX
            if end > coverWidth { out.append(text) }
        }
        return out
    }
}
