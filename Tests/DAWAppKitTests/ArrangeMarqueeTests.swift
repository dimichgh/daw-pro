import CoreGraphics
import Foundation
import Testing
@testable import DAWAppKit

/// m23-g3 — the arrange RUBBER BAND's geometry, and its composition with
/// `ArrangeSelection`.
///
/// THE DEFECT THESE TESTS EXIST TO CATCH is not "the band misses a clip" — it
/// is that **the lane ladder is NON-UNIFORM**. `TimelineLanesView.laneTop`
/// accumulates `rowHeight + extraHeight(track) + laneSpacing`, and
/// `extraHeight` grows by 64 pt for a track whose automation row is expanded
/// (plus its takes section). A uniform `y / pitch` reading is therefore RIGHT
/// for every default project and WRONG for any project with an expanded row —
/// which is precisely why a careless fixture cannot see it.
///
/// So the two ladder tests below carry a permanent VALIDITY LEG (the m23-g2
/// tradition): each runs the REJECTED uniform mapping on the SAME fixture and
/// asserts the two id sets DIFFER, before asserting `ArrangeMarquee` returns
/// the real one. A green test whose fixture cannot tell the two apart is
/// decorative.
@Suite("Arrange rubber band (m23-g3)")
struct ArrangeMarqueeTests {

    // MARK: - Fixture, computed (FIXTURE LAW: arithmetic BEFORE the assertion)

    /// The live defaults these fixtures are computed from — restated here so the
    /// arithmetic in each test is checkable by reading, not by running.
    /// `TimelineLanesView.laneHeight` = 34, `.laneSpacing` = 6,
    /// `.automationLaneHeight` = 64, and `rulerInset` = 0 in the `.lanes`
    /// instance the live arrange renders.
    private static let rowHeight: CGFloat = 34
    private static let laneSpacing: CGFloat = 6
    private static let automationRow: CGFloat = 64
    private static let ppb: CGFloat = 16

    private func id(_ n: Int) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02d", n))")!
    }

    /// One lane at `top` holding clips `(id index, startBeat, lengthBeats)`.
    private func lane(top: CGFloat, _ clips: [(Int, Double, Double)]) -> ArrangeMarqueeLane {
        ArrangeMarqueeLane(
            clipTop: top, clipBottom: top + Self.rowHeight,
            clips: clips.map { ArrangeMarqueeClip(id: id($0.0), startBeat: $0.1, lengthBeats: $0.2) })
    }

    /// The REJECTED implementation, kept runnable on purpose: a uniform row
    /// pitch (`rowHeight + laneSpacing`), which is what `floor(y / pitch)` and
    /// every other "just multiply it out" reading amounts to. Used only to prove
    /// a fixture can tell the two apart.
    private func uniformLadder(_ lanes: [ArrangeMarqueeLane]) -> [ArrangeMarqueeLane] {
        let pitch = Self.rowHeight + Self.laneSpacing
        return lanes.enumerated().map { i, lane in
            ArrangeMarqueeLane(clipTop: CGFloat(i) * pitch,
                               clipBottom: CGFloat(i) * pitch + Self.rowHeight,
                               clips: lane.clips)
        }
    }

    private func hits(_ band: CGRect, _ lanes: [ArrangeMarqueeLane],
                      ppb: CGFloat = ArrangeMarqueeTests.ppb) -> Set<UUID> {
        ArrangeMarquee.hits(band: band, lanes: lanes, pixelsPerBeat: ppb)
    }

    // MARK: - (1) Horizontal correctness

    /// Three clips on ONE lane; the band is computed to include two and exclude
    /// the third. At ppb 16: clip 1 spans beats 0…2 → x [0, 32); clip 2 spans
    /// 4…6 → x [64, 96); clip 3 spans 10…12 → x [160, 192). A band x ∈ [20, 70]
    /// overlaps 1 (20 < 32) and 2 (64 < 70), and stops 90 pt short of 3.
    @Test("A band across empty space selects exactly the clips it touches")
    func horizontalTouch() {
        let lanes = [lane(top: 0, [(1, 0, 2), (2, 4, 2), (3, 10, 2)])]
        let band = CGRect(x: 20, y: 8, width: 50, height: 18)   // x 20…70, y 8…26
        #expect(hits(band, lanes) == [id(1), id(2)])
    }

    /// TOUCH, not containment: a band far narrower than the clip still grabs it.
    /// Requiring containment would make a clip wider than the viewport
    /// unselectable by any gesture.
    @Test("Touch, not containment — a band inside one clip selects it")
    func touchNotContainment() {
        let lanes = [lane(top: 0, [(1, 0, 64)])]        // x [0, 1024)
        #expect(hits(CGRect(x: 500, y: 4, width: 6, height: 6), lanes) == [id(1)])
    }

    /// The m17-b zoom law: x↔beat runs through the LIVE `pixelsPerBeat`, so the
    /// same band in points means different beats at different zooms. Clip 2 at
    /// beats 4…6 is x [64, 96) at ppb 16 and x [256, 384) at ppb 64 — a band at
    /// x 60…70 catches it at 16 and misses it entirely at 64.
    @Test("Beats come from the live pixelsPerBeat, never a hardcoded scale")
    func zoomDependence() {
        let lanes = [lane(top: 0, [(2, 4, 2)])]
        let band = CGRect(x: 60, y: 4, width: 10, height: 20)
        #expect(hits(band, lanes, ppb: 16) == [id(2)])
        #expect(hits(band, lanes, ppb: 64).isEmpty)
    }

    // MARK: - (2) The NON-UNIFORM ladder discriminator

    /// THE HEADLINE LEG. 4 tracks, track 0's automation row expanded.
    ///
    /// REAL ladder (`laneTop` accumulating `rowHeight + extraHeight + spacing`):
    ///   t0 = 0, t1 = 0+34+64+6 = 104, t2 = 104+34+6 = 144, t3 = 144+34+6 = 184
    ///   clip bands: [0,34) [104,138) [144,178) [184,218)
    /// UNIFORM ladder (pitch 40): 0, 40, 80, 120 → [0,34) [40,74) [80,114) [120,154)
    ///
    /// A band at y ∈ [150, 170] lies wholly inside t2's real band, and wholly
    /// inside t3's uniform band. The two id sets DIFFER — which is the entire
    /// point of the leg, and is asserted first so the test cannot go quietly
    /// vacuous if the fixture is ever edited.
    @Test("The ladder is NON-UNIFORM: an expanded row above the band shifts every lane below it")
    func nonUniformLadderDiscriminator() {
        let real = [
            lane(top: 0, [(1, 0, 4)]),
            lane(top: 104, [(2, 0, 4)]),
            lane(top: 144, [(3, 0, 4)]),
            lane(top: 184, [(4, 0, 4)]),
        ]
        let band = CGRect(x: 10, y: 150, width: 40, height: 20)   // y 150…170

        // VALIDITY: the fixture can tell the two implementations apart.
        let uniform = hits(band, uniformLadder(real))
        #expect(uniform == [id(4)], "the rejected uniform reading must land on track 3")
        #expect(uniform != hits(band, real), "fixture is vacuous — both readings agree")

        // The real ladder: track 2's lane spans [144, 178), and only that.
        #expect(hits(band, real) == [id(3)])
    }

    /// A band that STARTS in an expanded track's clip lane and ends in the next
    /// track's must select both — and nothing else. The 64 pt automation row it
    /// crosses holds no clips, so crossing it selects nothing extra and, more
    /// importantly, does not shift what "the next lane" means.
    ///
    /// Real bands: t0 [0,34), t1 [104,138), t2 [144,178). A band y ∈ [20, 110]
    /// overlaps t0 (20 < 34) and t1 (104 < 110) and stops 34 pt short of t2.
    /// Uniform bands [0,34) [40,74) [80,114): the same band overlaps THREE.
    @Test("A band spanning an expanded automation row lands on both clip lanes and nothing else")
    func bandSpanningAnExpandedRow() {
        let real = [
            lane(top: 0, [(1, 0, 4)]),
            lane(top: 104, [(2, 0, 4)]),
            lane(top: 144, [(3, 0, 4)]),
        ]
        let band = CGRect(x: 10, y: 20, width: 40, height: 90)   // y 20…110

        let uniform = hits(band, uniformLadder(real))
        #expect(uniform == [id(1), id(2), id(3)],
                "the rejected uniform reading must over-select into track 2")
        #expect(uniform != hits(band, real), "fixture is vacuous — both readings agree")

        #expect(hits(band, real) == [id(1), id(2)])
    }

    /// The take-lane half of the same hazard, and the reason `ArrangeMarqueeLane`
    /// carries the CLIP band only: a band dipping BELOW a lane's clips — into its
    /// takes/automation extras — selects nothing from a row whose clip band it
    /// never reached. Lane 0's clips end at y 34; a band at y ∈ [40, 60] is
    /// inside that row's extras and above the next lane's clips.
    @Test("A band inside a row's extras (below its clips) selects nothing")
    func bandInRowExtras() {
        let lanes = [lane(top: 0, [(1, 0, 4)]), lane(top: 104, [(2, 0, 4)])]
        #expect(hits(CGRect(x: 10, y: 40, width: 40, height: 20), lanes).isEmpty)
    }

    // MARK: - (3) Normalization

    /// A drag right-to-left and bottom-to-top must produce the SAME band as the
    /// forward drag between the same two points — negative extents normalize at
    /// the ONE producer, so no consumer can be handed a negative width.
    @Test("A band dragged right-to-left and bottom-to-top normalizes")
    func normalization() {
        let a = CGPoint(x: 20, y: 8), b = CGPoint(x: 70, y: 26)
        let forward = ArrangeMarquee.band(from: a, to: b)
        let backward = ArrangeMarquee.band(from: b, to: a)
        #expect(forward == backward)
        #expect(backward.width == 50 && backward.height == 18)
        #expect(backward.minX == 20 && backward.minY == 8)
        // THE RAW STORAGE, and it is the only assertion here that can see the
        // normalization at all — MEASURED, not assumed. `CGRect`'s `==`,
        // `width`, `height`, `minX` and `minY` ALL standardize internally, so
        // every line above passes verbatim against a `band` that stores a
        // negative width (a calibration mutation proved exactly that: gate
        // 38/38 and this suite 15/15, both green, against the unnormalized
        // implementation). A consumer reading `size.width` directly — a Canvas
        // path, a JSON echo — would get the negative, so the guarantee is
        // pinned where it is actually observable.
        #expect(backward.origin.x == 20 && backward.origin.y == 8)
        #expect(backward.size.width == 50 && backward.size.height == 18)

        // And the selection it produces is identical in both directions.
        let lanes = [lane(top: 0, [(1, 0, 2), (2, 4, 2), (3, 10, 2)])]
        #expect(hits(forward, lanes) == hits(backward, lanes))
        #expect(hits(backward, lanes) == [id(1), id(2)])
    }

    /// Mixed direction — right-to-left horizontally, top-to-bottom vertically.
    @Test("One axis reversed normalizes just as well")
    func mixedDirection() {
        let band = ArrangeMarquee.band(from: CGPoint(x: 70, y: 8), to: CGPoint(x: 20, y: 26))
        #expect(band == CGRect(x: 20, y: 8, width: 50, height: 18))
    }

    // MARK: - (4) Degenerate bands

    /// A press that never swept any AREA selects nothing. This is what keeps a
    /// click from silently replacing the selection with a lucky hit — and it is
    /// the platform's own answer (`CGRect.intersects` is false for empty rects),
    /// not a second rule invented here.
    @Test("A zero-area band selects nothing")
    func zeroAreaBand() {
        let lanes = [lane(top: 0, [(1, 0, 8)])]     // x [0, 128), y [0, 34)
        // A point squarely INSIDE the clip.
        #expect(hits(CGRect(x: 40, y: 17, width: 0, height: 0), lanes).isEmpty)
        // Zero width only (a drag straight down), still inside the clip's x span.
        #expect(hits(CGRect(x: 40, y: 4, width: 0, height: 20), lanes).isEmpty)
        // Zero height only (a drag straight across).
        #expect(hits(CGRect(x: 10, y: 17, width: 60, height: 0), lanes).isEmpty)
        // The same rects via the producer, from coincident / colinear points.
        #expect(ArrangeMarquee.band(from: CGPoint(x: 40, y: 17),
                                    to: CGPoint(x: 40, y: 17)).isEmpty)
        #expect(hits(ArrangeMarquee.band(from: CGPoint(x: 40, y: 17),
                                         to: CGPoint(x: 40, y: 17)), lanes).isEmpty)
    }

    /// A zero-length clip is never hit — the same rule
    /// `ArrangePointer.clipIndex` applies, so degenerate spans behave
    /// identically across the whole pointer layer.
    @Test("A zero-length clip is never hit")
    func zeroLengthClip() {
        let lanes = [lane(top: 0, [(1, 4, 0), (2, 4, 2)])]
        #expect(hits(CGRect(x: 0, y: 0, width: 200, height: 34), lanes) == [id(2)])
    }

    /// STRICT overlap: a band whose edge merely coincides with a lane's top, or
    /// with a clip's start x, has swept none of it. Clip 2 starts at beat 4 =
    /// x 64; lane 1's clips start at y 104.
    @Test("Edge-coincident bands select nothing (strict overlap)")
    func edgeCoincidence() {
        let lanes = [lane(top: 0, [(1, 0, 2)]), lane(top: 104, [(2, 4, 2)])]
        // Band's maxX lands exactly on clip 2's start x; its minY lands exactly
        // on lane 1's clipTop. Neither is an overlap.
        #expect(hits(CGRect(x: 30, y: 104, width: 34, height: 20), lanes).isEmpty)
        // One point past either edge and it is.
        #expect(hits(CGRect(x: 30, y: 104, width: 35, height: 20), lanes) == [id(2)])
    }

    // MARK: - (5) laneIndices agrees with hits

    /// `laneIndices` is exposed so the view/echo never needs a second answer to
    /// "which rows did the band reach". Pin that it agrees with `hits`.
    @Test("laneIndices and hits apply the same vertical rule")
    func laneIndicesAgreeWithHits() {
        let lanes = [
            lane(top: 0, [(1, 0, 4)]),
            lane(top: 104, [(2, 0, 4)]),
            lane(top: 144, [(3, 0, 4)]),
        ]
        let band = CGRect(x: 10, y: 20, width: 40, height: 90)   // t0 + t1
        #expect(ArrangeMarquee.laneIndices(band: band, lanes: lanes) == [0, 1])
        #expect(hits(band, lanes) == [id(1), id(2)])
        // Degenerate bands reach no rows at all.
        #expect(ArrangeMarquee.laneIndices(
            band: CGRect(x: 10, y: 20, width: 0, height: 90), lanes: lanes).isEmpty)
    }

    // MARK: - (6) Composition with ArrangeSelection

    /// The composition `AppModel.applyArrangeMarquee` runs, exercised headlessly.
    ///
    /// STATED HONESTLY: this proves the two mutators compose to the documented
    /// result; it does NOT prove `AppModel` calls them this way (that is the
    /// staging gate's job). It exists because the additive path has a failure
    /// mode arithmetic alone would not reveal — unioning onto the LIVE selection
    /// instead of the frozen base, which makes a shrinking shift-band unable to
    /// give a clip back.
    private func applyMarquee(_ selection: inout ArrangeSelection,
                              hits: Set<UUID>, base: Set<UUID>, additive: Bool) {
        if additive {
            selection.replace(with: base)
            selection.formUnion(hits)
        } else {
            selection.replace(with: hits)
        }
    }

    @Test("A plain band REPLACES the selection; a shift band UNIONS onto the pre-drag base")
    func replaceVersusUnion() {
        let lanes = [lane(top: 0, [(1, 0, 2), (2, 4, 2), (3, 10, 2)])]
        var selection = ArrangeSelection()
        selection.selectOnly(id(3))                       // pre-drag: clip 3, focused

        let band = CGRect(x: 20, y: 8, width: 50, height: 18)   // touches 1 and 2
        let touched = hits(band, lanes)
        #expect(touched == [id(1), id(2)])

        // Plain: the band's hits become the whole selection, and the focus —
        // which is NOT among them — is dropped rather than re-pointed.
        var plain = selection
        applyMarquee(&plain, hits: touched, base: selection.ids, additive: false)
        #expect(plain.ids == [id(1), id(2)])
        #expect(plain.focusID == nil)

        // Shift: base ∪ hits, focus untouched (still a member).
        var additive = selection
        applyMarquee(&additive, hits: touched, base: selection.ids, additive: true)
        #expect(additive.ids == [id(1), id(2), id(3)])
        #expect(additive.focusID == id(3))
    }

    /// A SHRINKING band must give clips back — on both paths. This is the leg
    /// that fails if the additive path unions onto the live selection instead of
    /// the frozen base.
    @Test("A shrinking band gives clips back, plain and additive alike")
    func shrinkingBandGivesClipsBack() {
        let lanes = [lane(top: 0, [(1, 0, 2), (2, 4, 2), (3, 10, 2)])]
        var base = ArrangeSelection()
        base.selectOnly(id(3))

        let wide = CGRect(x: 20, y: 8, width: 50, height: 18)     // 1 and 2
        let narrow = CGRect(x: 20, y: 8, width: 8, height: 18)    // 1 only
        #expect(hits(narrow, lanes) == [id(1)])

        var plain = base
        applyMarquee(&plain, hits: hits(wide, lanes), base: base.ids, additive: false)
        applyMarquee(&plain, hits: hits(narrow, lanes), base: base.ids, additive: false)
        #expect(plain.ids == [id(1)])

        var additive = base
        applyMarquee(&additive, hits: hits(wide, lanes), base: base.ids, additive: true)
        #expect(additive.ids == [id(1), id(2), id(3)])
        applyMarquee(&additive, hits: hits(narrow, lanes), base: base.ids, additive: true)
        #expect(additive.ids == [id(1), id(3)], "the shift band must give clip 2 back")
        #expect(additive.focusID == id(3))

        // VALIDITY LEG — the rejected "union onto the live selection" shape,
        // run on the same fixture, cannot give clip 2 back.
        var live = base
        live.formUnion(hits(wide, lanes))
        live.formUnion(hits(narrow, lanes))
        #expect(live.ids == [id(1), id(2), id(3)])
        #expect(live.ids != additive.ids, "fixture is vacuous — both shapes agree")
    }

    /// A band that ends on empty space clears the selection outright (plain),
    /// and leaves the base exactly as it was (additive).
    @Test("A band that touches nothing clears a plain selection and no-ops an additive one")
    func emptyBand() {
        let lanes = [lane(top: 0, [(1, 0, 2)])]
        var base = ArrangeSelection()
        base.selectOnly(id(1))
        let miss = CGRect(x: 400, y: 8, width: 40, height: 18)
        #expect(hits(miss, lanes).isEmpty)

        var plain = base
        applyMarquee(&plain, hits: hits(miss, lanes), base: base.ids, additive: false)
        #expect(plain.isEmpty)
        #expect(plain.focusID == nil)

        var additive = base
        applyMarquee(&additive, hits: hits(miss, lanes), base: base.ids, additive: true)
        #expect(additive.ids == [id(1)])
        #expect(additive.focusID == id(1))
    }
}
