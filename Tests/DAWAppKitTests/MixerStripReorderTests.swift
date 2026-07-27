import CoreGraphics
import Foundation
import Testing
@testable import DAWAppKit
import DAWCore

/// m23-z — the pure drop-landing registry behind the MIXER strip reorder drag.
///
/// TWO FIXTURE SHAPES ARE REQUIRED HERE, and neither alone is enough:
///   • an ALL-CHANNELS-FIRST project cannot see the INDEX bug — the mixer's
///     visual position equals the array index for every such project, which is
///     what natural creation order and every default fixture produce;
///   • a BUS-FREE project cannot see the GAP bug — every gap is the `HStack`'s
///     10 pt, so a single sampled gap is right by luck.
/// So the suite carries a bus BETWEEN two channels for the index legs, and racks
/// whose divider gap sits at different indices for the gap legs.
@Suite("Mixer strip reorder (m23-z)")
struct MixerStripReorderTests {
    /// The strips' fixed frame; the rack's plain `HStack` gap; and the DIVIDER
    /// gap (`10 + dividerWidth + 10`), which is what makes the ladder
    /// non-uniform. `dividerWidth` is intrinsic in the app (the "BUSES"
    /// caption's text) — 6 here is just a value distinguishable from 10.
    private let W: CGFloat = 132
    private let g: CGFloat = 10
    private let D: CGFloat = 26

    private func track(_ name: String, _ kind: TrackKind) -> Track {
        Track(name: name, kind: kind)
    }

    /// Builds the MEASURED ladder the app would produce for a visual order,
    /// inserting the divider gap where the channel block ends.
    private func ladder(for tracks: [Track]) -> MixerStripLadder {
        let strips = MixerLayout.orderedStrips(tracks)
        let channels = MixerLayout.channelTracks(tracks).count
        var lefts: [CGFloat] = []
        var x: CGFloat = 0
        for (i, _) in strips.enumerated() {
            lefts.append(x)
            x += W + (i + 1 == channels && channels < strips.count ? D : g)
        }
        return MixerStripLadder(lefts: lefts, widths: Array(repeating: W, count: strips.count))
    }

    /// Centre of a visual slot, in rack space.
    private func centre(_ slot: Int, _ ladder: MixerStripLadder) -> CGFloat {
        ladder.lefts[slot] + ladder.widths[slot] / 2
    }

    // MARK: - THE INDEX TRANSLATION (a bus BETWEEN two channels)

    /// `[C0(chan), B1(bus), C2(chan), C3(chan)]` → the console shows
    /// `C0, C2, C3 | B1`. This is the ONE shape on which the correct reading and
    /// the naive one disagree.
    private func discriminator() -> [Track] {
        [track("C0", .audio), track("B1", .bus), track("C2", .audio), track("C3", .audio)]
    }

    @Test("the landing slot names a TARGET TRACK; the committed index is that track's ARRAY index")
    func visualSlotTranslatesToArrayIndex() throws {
        let tracks = discriminator()
        let rack = ladder(for: tracks)
        #expect(MixerLayout.orderedStrips(tracks).map(\.name) == ["C0", "C2", "C3", "B1"])

        // Drag C0 (visual 0, array 0) onto the LAST CHANNEL slot — visual 2,
        // which is C3, whose ARRAY index is 3.
        let drop = try #require(MixerStripReorder.resolve(
            pointerX: centre(2, rack), draggedID: tracks[0].id, tracks: tracks, ladder: rack))
        #expect(drop.from == 0)
        #expect(drop.fromSlot == 0)
        #expect(drop.targetSlot == 2)
        // THE TRANSLATION: visual 2 ≠ array 2 here. A pass-through would report 2.
        #expect(drop.targetIndex == 3)
        let landing = try #require(drop.landing)
        #expect(landing.arrayIndex == 3)

        // …and the result is the one the roadmap computed before any code existed.
        let correct = TrackOrder.applying(tracks, moving: tracks[0].id, to: landing.arrayIndex)
        #expect(correct.map(\.name) == ["B1", "C2", "C3", "C0"])
        #expect(MixerLayout.channelTracks(correct).map(\.name) == ["C2", "C3", "C0"])
    }

    @Test("the NAIVE reading — committing the visual index — produces a DIFFERENT order")
    func naiveVisualIndexIsWrong() throws {
        let tracks = discriminator()
        let rack = ladder(for: tracks)
        let drop = try #require(MixerStripReorder.resolve(
            pointerX: centre(2, rack), draggedID: tracks[0].id, tracks: tracks, ladder: rack))
        let landing = try #require(drop.landing)

        let naive = TrackOrder.applying(tracks, moving: tracks[0].id, to: drop.targetSlot)
        let correct = TrackOrder.applying(tracks, moving: tracks[0].id, to: landing.arrayIndex)
        // The two readings DISAGREE — which is the whole reason this item exists.
        #expect(naive.map(\.name) != correct.map(\.name))
        #expect(naive.map(\.name) == ["B1", "C2", "C0", "C3"])
        #expect(MixerLayout.channelTracks(naive).map(\.name) == ["C2", "C0", "C3"])
        // And the registry commits the correct one.
        #expect(landing.arrayIndex != drop.targetSlot)
    }

    @Test("on an ALL-CHANNELS-FIRST project the two readings agree — which is why this fixture can't gate")
    func allChannelsFirstCannotSeeTheBug() throws {
        let tracks = [track("C0", .audio), track("C1", .audio),
                      track("C2", .audio), track("B0", .bus)]
        let rack = ladder(for: tracks)
        for slot in 0..<3 {
            let drop = try #require(MixerStripReorder.resolve(
                pointerX: centre(slot, rack), draggedID: tracks[0].id,
                tracks: tracks, ladder: rack))
            #expect(drop.targetIndex == drop.targetSlot)   // the identity mapping
        }
    }

    // MARK: - THE NO-OP LANDING (visual order, not array index)

    @Test("dropping a channel on a bus slot changes the ARRAY but not the CONSOLE — so it is inert")
    func visuallyInertLandingHasNoLanding() throws {
        let tracks = discriminator()
        let rack = ladder(for: tracks)
        // C0 onto B1's slot (visual 3) → array index 1 → [B1, C0, C2, C3],
        // which the console still renders as C0, C2, C3 | B1.
        let drop = try #require(MixerStripReorder.resolve(
            pointerX: centre(3, rack), draggedID: tracks[0].id, tracks: tracks, ladder: rack))
        #expect(drop.targetSlot == 3)
        #expect(drop.targetIndex == 1)          // the translation DID run…
        #expect(drop.targetIndex != drop.from)  // …and `index != from` would say "moves"
        // …but the visible order does not change, so there is NO landing: no
        // line, no index to commit, no undo step. Structural, not a flag.
        #expect(drop.landing == nil)
        #expect(!drop.moves)
        #expect(MixerStripReorder.partingOffsets(drop: drop, ladder: rack).isEmpty)

        // The proof that `index != from` is the WRONG test here: the array move
        // it would have committed leaves the console byte-identical.
        let after = TrackOrder.applying(tracks, moving: tracks[0].id, to: drop.targetIndex)
        #expect(after.map(\.name) == ["B1", "C0", "C2", "C3"])       // the array moved…
        #expect(MixerLayout.orderedStrips(after).map(\.id)
                == MixerLayout.orderedStrips(tracks).map(\.id))       // …the console did not
    }

    @Test("moving the ONLY bus is inert wherever it is dropped")
    func theOnlyBusCanNeverMoveVisually() throws {
        let tracks = discriminator()
        let rack = ladder(for: tracks)
        for slot in 0..<4 {
            let drop = try #require(MixerStripReorder.resolve(
                pointerX: centre(slot, rack), draggedID: tracks[1].id,
                tracks: tracks, ladder: rack))
            #expect(!drop.moves, "bus drop on slot \(slot) claimed a visible move")
        }
    }

    // MARK: - THE INDICATOR MARKS WHERE THE STRIP WILL BE

    @Test("a DOWN move draws the line at the target's far edge; an UP move at its near edge")
    func indicatorMarksTheLandingEdge() throws {
        let tracks = discriminator()
        let rack = ladder(for: tracks)
        let down = try #require(MixerStripReorder.resolve(
            pointerX: centre(2, rack), draggedID: tracks[0].id, tracks: tracks, ladder: rack))
        #expect(down.landing?.indicatorX == rack.lefts[2] + rack.widths[2])

        // C3 (visual 2) back to C0's slot (visual 0): the line sits at slot 0's
        // left edge.
        let up = try #require(MixerStripReorder.resolve(
            pointerX: centre(0, rack), draggedID: tracks[3].id, tracks: tracks, ladder: rack))
        #expect(up.landing?.slot == 0)
        #expect(up.landing?.indicatorX == rack.lefts[0])
    }

    @Test("when a landing crosses the divider the line marks the RESULTING slot, not the pointer's")
    func indicatorFollowsTheResultingSlotNotThePointer() throws {
        // Two channels AND two buses: the one shape where an effective landing
        // and the pointer's slot come apart.
        let tracks = [track("C0", .audio), track("C1", .audio),
                      track("B0", .bus), track("B1", .bus)]
        let rack = ladder(for: tracks)
        #expect(MixerLayout.orderedStrips(tracks).map(\.name) == ["C0", "C1", "B0", "B1"])

        // Drag B1 (visual 3) onto C0's slot (visual 0). Array → [B1,C0,C1,B0],
        // console → C0, C1 | B1, B0: EFFECTIVE (the buses reverse), but B1 lands
        // at visual 2, not at the pointer's visual 0.
        let drop = try #require(MixerStripReorder.resolve(
            pointerX: centre(0, rack), draggedID: tracks[3].id, tracks: tracks, ladder: rack))
        #expect(drop.moves)
        #expect(drop.targetSlot == 0)
        let landing = try #require(drop.landing)
        #expect(landing.arrayIndex == 0)
        #expect(landing.slot == 2)
        // The line stands where the strip will BE (slot 2's left edge), not where
        // the pointer is (slot 0's). Marking the pointer would promise a position
        // the console never produces.
        #expect(landing.indicatorX == rack.lefts[2])
        #expect(landing.indicatorX != rack.lefts[0])

        let after = TrackOrder.applying(tracks, moving: tracks[3].id, to: landing.arrayIndex)
        #expect(MixerLayout.orderedStrips(after).map(\.name) == ["C0", "C1", "B1", "B0"])
    }

    // MARK: - THE PER-INDEX GAP (two shapes, each blind to the other's bug)

    @Test("the ladder reports the divider gap PER INDEX, not one sampled gap")
    func gapsAreReadPerIndex() {
        let tracks = discriminator()               // 3 channels, 1 bus → gaps 10, 10, 26
        let rack = ladder(for: tracks)
        #expect(rack.gap(after: 0) == g)
        #expect(rack.gap(after: 1) == g)
        #expect(rack.gap(after: 2) == D)
        #expect(rack.gap(after: 3) == 0)           // no slot after the last
        // A single sample (rows 0–1, the arrange's trick) would call every gap
        // 10 — right here and wrong on the fixture below.
        let oneChannel = ladder(for: [track("C0", .audio), track("B0", .bus), track("B1", .bus)])
        #expect(oneChannel.gap(after: 0) == D)     // sampling THIS one reports 26 everywhere
        #expect(oneChannel.gap(after: 1) == g)
    }

    /// KILLS A SINGLE SAMPLED GAP: with one channel and two buses the divider gap
    /// sits at index 0, so `TrackRowLadder.spacing`'s "sample rows 0–1" reads 26
    /// while the gap that actually closes is 10.
    @Test("a divider gap at index 0 does not inflate the parting distance")
    func samplingTheFirstGapWouldBeWrong() throws {
        let tracks = [track("C0", .audio), track("B0", .bus), track("B1", .bus)]
        let rack = ladder(for: tracks)
        #expect(rack.gap(after: 0) == D)

        // B0 (visual 1) onto B1's slot (visual 2): the buses swap.
        let drop = try #require(MixerStripReorder.resolve(
            pointerX: centre(2, rack), draggedID: tracks[1].id, tracks: tracks, ladder: rack))
        #expect(drop.moves)
        let offsets = MixerStripReorder.partingOffsets(drop: drop, ladder: rack)
        #expect(offsets == [0, 0, -(W + g)])
        #expect(offsets[2] != -(W + D))            // what a sampled gap would give
    }

    /// KILLS `gap(after: from)`: with two channels and one bus the divider gap
    /// sits AFTER the dragged strip, but the drag goes the other way — so the gap
    /// that closes is the one it departs from, not the one behind it.
    @Test("the vacated gap is the one on the side the strip departs from")
    func vacatedGapFollowsTheDirectionOfTravel() throws {
        let tracks = [track("C0", .audio), track("C1", .audio), track("B0", .bus)]
        let rack = ladder(for: tracks)
        #expect(rack.gap(after: 0) == g)
        #expect(rack.gap(after: 1) == D)

        // C1 (visual 1) up to slot 0. It departs to the LEFT, so the 10 pt gap
        // closes — the 26 pt divider gap behind it stays at the section boundary.
        let drop = try #require(MixerStripReorder.resolve(
            pointerX: centre(0, rack), draggedID: tracks[1].id, tracks: tracks, ladder: rack))
        #expect(drop.moves)
        let offsets = MixerStripReorder.partingOffsets(drop: drop, ladder: rack)
        #expect(offsets == [W + g, 0, 0])
        #expect(offsets[0] != W + D)               // what `gap(after: from)` would give
    }

    /// The invariant behind the direction rule, asserted exhaustively rather than
    /// argued: a reorder never changes how many channels or buses exist, so the
    /// divider never moves and every visually-effective landing is a permutation
    /// WITHIN one section. The divider gap therefore never participates in a
    /// parting distance — on ANY drag of ANY strip to ANY slot.
    @Test("the divider gap is never the vacated gap, for any strip and any landing")
    func theDividerGapNeverParts() throws {
        let tracks = [track("C0", .audio), track("C1", .audio),
                      track("B0", .bus), track("B1", .bus)]
        let rack = ladder(for: tracks)
        for dragged in tracks {
            for slot in 0..<rack.count {
                let drop = try #require(MixerStripReorder.resolve(
                    pointerX: centre(slot, rack), draggedID: dragged.id,
                    tracks: tracks, ladder: rack))
                for offset in MixerStripReorder.partingOffsets(drop: drop, ladder: rack) {
                    #expect(offset == 0 || abs(offset) == W + g,
                            "\(dragged.name) → slot \(slot) parted by \(offset)")
                }
            }
        }
    }

    // MARK: - BOTH DIRECTIONS (an up-only fixture half-passes this class of item)

    @Test("a DOWN move parts the strips it passes LEFT by exactly the vacated slot")
    func downMovePartsLeftward() throws {
        let tracks = discriminator()
        let rack = ladder(for: tracks)
        let drop = try #require(MixerStripReorder.resolve(
            pointerX: centre(2, rack), draggedID: tracks[0].id, tracks: tracks, ladder: rack))
        #expect(MixerStripReorder.partingOffsets(drop: drop, ladder: rack)
                == [0, -(W + g), -(W + g), 0])
    }

    @Test("an UP move parts the strips it passes RIGHT by the same slot")
    func upMovePartsRightward() throws {
        let tracks = discriminator()
        let rack = ladder(for: tracks)
        // C3 (visual 2) back to visual 0.
        let drop = try #require(MixerStripReorder.resolve(
            pointerX: centre(0, rack), draggedID: tracks[3].id, tracks: tracks, ladder: rack))
        #expect(drop.landing?.arrayIndex == 0)
        #expect(MixerStripReorder.partingOffsets(drop: drop, ladder: rack)
                == [W + g, W + g, 0, 0])
        let after = TrackOrder.applying(tracks, moving: tracks[3].id, to: 0)
        #expect(MixerLayout.orderedStrips(after).map(\.name) == ["C3", "C0", "C2", "B1"])
    }

    @Test("the slot that opens is exactly the slot that closes — the preview IS the result")
    func partingConservesTheRack() throws {
        let tracks = discriminator()
        let rack = ladder(for: tracks)
        let drop = try #require(MixerStripReorder.resolve(
            pointerX: centre(2, rack), draggedID: tracks[0].id, tracks: tracks, ladder: rack))
        let offsets = MixerStripReorder.partingOffsets(drop: drop, ladder: rack)
        // After C0 moves to visual 2 the console reads C2, C3, C0 | B1 — so C2
        // sits where C0 was, and C3 follows it one slot on.
        #expect(rack.lefts[1] + offsets[1] == rack.lefts[0])
        #expect(rack.lefts[2] + offsets[2] == rack.lefts[0] + W + g)
    }

    // MARK: - Refusals (bad geometry must produce NO landing, never slot 0)

    @Test("an unmeasured or mismatched ladder resolves to nil, not to the leftmost slot")
    func unusableLadderResolvesToNil() {
        let tracks = discriminator()
        #expect(MixerStripReorder.resolve(
            pointerX: 10, draggedID: tracks[0].id, tracks: tracks, ladder: .empty) == nil)
        // Right shape, wrong length — a stale ladder from before a track was added.
        let short = MixerStripLadder(lefts: [0, 142], widths: [132, 132])
        #expect(MixerStripReorder.resolve(
            pointerX: 10, draggedID: tracks[0].id, tracks: tracks, ladder: short) == nil)
        // Half-measured.
        #expect(!MixerStripLadder(lefts: [0, 142], widths: [132]).isWellFormed)
    }

    @Test("an unknown dragged id resolves to nil")
    func unknownStripResolvesToNil() {
        let tracks = discriminator()
        #expect(MixerStripReorder.resolve(
            pointerX: 10, draggedID: UUID(), tracks: tracks,
            ladder: ladder(for: tracks)) == nil)
    }

    @Test("past either end the landing clamps to the first / last strip")
    func clampsAtBothEnds() throws {
        let tracks = discriminator()
        let rack = ladder(for: tracks)
        let left = try #require(MixerStripReorder.resolve(
            pointerX: -900, draggedID: tracks[3].id, tracks: tracks, ladder: rack))
        #expect(left.targetSlot == 0)
        let right = try #require(MixerStripReorder.resolve(
            pointerX: 9_000, draggedID: tracks[0].id, tracks: tracks, ladder: rack))
        #expect(right.targetSlot == 3)
    }

    @Test("dragging further right never walks the landing back left (monotonic)")
    func landingIsMonotonic() throws {
        let tracks = discriminator()
        let rack = ladder(for: tracks)
        var previous = -1
        for x in stride(from: -50.0, through: 700.0, by: 4.0) {
            let drop = try #require(MixerStripReorder.resolve(
                pointerX: x, draggedID: tracks[0].id, tracks: tracks, ladder: rack))
            #expect(drop.targetSlot >= previous, "landing went backwards at x=\(x)")
            previous = drop.targetSlot
        }
        #expect(previous == 3)
    }

    @Test("a single-strip rack can only ever land on itself")
    func singleStripRack() throws {
        let tracks = [track("C0", .audio)]
        let rack = ladder(for: tracks)
        for x in [-100.0, 60.0, 500.0] {
            let drop = try #require(MixerStripReorder.resolve(
                pointerX: x, draggedID: tracks[0].id, tracks: tracks, ladder: rack))
            #expect(!drop.moves)
            #expect(drop.landing == nil)
        }
    }
}

/// The registry composed with the STORE — the legs that only exist once a real
/// `ProjectStore` is on the other end of the resolved index.
@MainActor
@Suite("Mixer strip reorder — store composition (m23-z)")
struct MixerStripReorderStoreTests {
    private let W: CGFloat = 132
    private let g: CGFloat = 10
    private let D: CGFloat = 26

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dawproj-mixerreorder-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `[C0(chan), B1(bus), C2(chan), C3(chan)]` in a live store.
    private func fixture() -> (ProjectStore, [Track]) {
        let store = ProjectStore()
        let tracks = [store.addTrack(name: "C0", kind: .audio),
                      store.addTrack(name: "B1", kind: .bus),
                      store.addTrack(name: "C2", kind: .audio),
                      store.addTrack(name: "C3", kind: .audio)]
        return (store, tracks)
    }

    private func ladder(for tracks: [Track]) -> MixerStripLadder {
        let strips = MixerLayout.orderedStrips(tracks)
        let channels = MixerLayout.channelTracks(tracks).count
        var lefts: [CGFloat] = []
        var x: CGFloat = 0
        for i in strips.indices {
            lefts.append(x)
            x += W + (i + 1 == channels && channels < strips.count ? D : g)
        }
        return MixerStripLadder(lefts: lefts, widths: Array(repeating: W, count: strips.count))
    }

    private func centre(_ slot: Int, _ rack: MixerStripLadder) -> CGFloat {
        rack.lefts[slot] + rack.widths[slot] / 2
    }

    /// The registry PREDICTS the store's permutation to decide whether a landing
    /// is visible at all. If the two ever disagreed, the console would draw a
    /// line for a landing the store resolves differently — so they are the same
    /// function, and this pins it.
    @Test("the predicted order is byte-identical to what the store actually does")
    func predictionMatchesTheStore() throws {
        for from in 0..<4 {
            for to in 0..<4 {
                let (store, tracks) = fixture()
                let predicted = TrackOrder.applying(store.tracks, moving: tracks[from].id, to: to)
                try store.reorderTrack(id: tracks[from].id, toIndex: to)
                #expect(store.tracks.map(\.id) == predicted.map(\.id),
                        "from \(from) to \(to)")
            }
        }
    }

    @Test("a mixer drag and an arrange drag of the same track produce the same array")
    func bothSurfacesShareOneOrdering() throws {
        let (mixerStore, mixerTracks) = fixture()
        let rack = ladder(for: mixerStore.tracks)
        let drop = try #require(MixerStripReorder.resolve(
            pointerX: centre(2, rack), draggedID: mixerTracks[0].id,
            tracks: mixerStore.tracks, ladder: rack))
        let landing = try #require(drop.landing)
        try mixerStore.reorderTrack(id: mixerTracks[0].id, toIndex: landing.arrayIndex)

        // The arrange resolves the SAME landing from its own (raw) ladder: row 3
        // is the array's index 3, no translation involved.
        let (arrangeStore, arrangeTracks) = fixture()
        let rows = TrackRowLadder(tops: [0, 40, 80, 120], heights: [34, 34, 34, 34])
        let rowDrop = try #require(
            TrackReorderDrag.resolve(pointerY: 130, from: 0, ladder: rows))
        #expect(rowDrop.index == 3)
        try arrangeStore.reorderTrack(id: arrangeTracks[0].id, toIndex: rowDrop.index)

        #expect(mixerStore.tracks.map(\.name) == arrangeStore.tracks.map(\.name))
        #expect(mixerStore.tracks.map(\.name) == ["B1", "C2", "C3", "C0"])
    }

    @Test("one committed gesture is ONE undo step, asserted by history depth")
    func oneGestureIsOneUndoStep() throws {
        let (store, tracks) = fixture()
        let rack = ladder(for: store.tracks)
        let before = store.undoHistory().undo.count

        let drop = try #require(MixerStripReorder.resolve(
            pointerX: centre(2, rack), draggedID: tracks[0].id,
            tracks: store.tracks, ladder: rack))
        let landing = try #require(drop.landing)
        try store.reorderTrack(id: tracks[0].id, toIndex: landing.arrayIndex)

        #expect(store.undoHistory().undo.count == before + 1)
        #expect(store.tracks.map(\.name) == ["B1", "C2", "C3", "C0"])
        _ = try store.undo()
        #expect(store.tracks.map(\.name) == ["C0", "B1", "C2", "C3"])
        #expect(store.undoHistory().undo.count == before)
    }

    @Test("a visually-inert landing spends NO undo step — because it is never committed")
    func inertLandingCostsNothing() throws {
        let (store, tracks) = fixture()
        let rack = ladder(for: store.tracks)
        let before = store.undoHistory().undo.count
        // Creating the fixture already dirtied the project, so the leg is "no
        // CHANGE", not "clean" — asserting `false` here would be a fixture
        // artefact rather than a fact about the landing.
        let dirtyBefore = store.isDirty

        // C0 onto B1's slot: the array index exists, the visible order does not
        // change, so there is no landing and the console's commit path — which
        // is TYPED on the landing — has nothing to call.
        let drop = try #require(MixerStripReorder.resolve(
            pointerX: centre(3, rack), draggedID: tracks[0].id,
            tracks: store.tracks, ladder: rack))
        #expect(drop.landing == nil)
        #expect(store.undoHistory().undo.count == before)
        #expect(store.isDirty == dirtyBefore)

        // And this is the cost that avoids: committing the raw target index
        // WOULD burn an undo step for a console that looks identical afterwards.
        let visualBefore = MixerLayout.orderedStrips(store.tracks).map(\.id)
        try store.reorderTrack(id: tracks[0].id, toIndex: drop.targetIndex)
        #expect(store.undoHistory().undo.count == before + 1)
        #expect(MixerLayout.orderedStrips(store.tracks).map(\.id) == visualBefore)
    }

    @Test("a mixer-resolved reorder survives a save/open round trip")
    func orderRoundTripsThroughDawproj() throws {
        let dir = tempDir()
        let (store, tracks) = fixture()
        let rack = ladder(for: store.tracks)
        let drop = try #require(MixerStripReorder.resolve(
            pointerX: centre(2, rack), draggedID: tracks[0].id,
            tracks: store.tracks, ladder: rack))
        try store.reorderTrack(id: tracks[0].id, toIndex: #require(drop.landing).arrayIndex)

        let path = dir.appendingPathComponent("MixerReordered").path
        try store.saveProject(to: path)

        let reopened = ProjectStore()
        try reopened.openProject(at: path)
        #expect(reopened.tracks.map(\.name) == ["B1", "C2", "C3", "C0"])
        #expect(reopened.tracks.map(\.id) == [tracks[1].id, tracks[2].id,
                                              tracks[3].id, tracks[0].id])
        // The console reads the reopened array the same way it read the live one.
        #expect(MixerLayout.orderedStrips(reopened.tracks).map(\.name)
                == ["C2", "C3", "C0", "B1"])
    }

    @Test("an UP move through the mixer lands and round-trips too")
    func upMoveComposesWithTheStore() throws {
        let dir = tempDir()
        let (store, tracks) = fixture()
        let rack = ladder(for: store.tracks)
        // C3 (visual 2) back to visual 0 = C0, array index 0.
        let drop = try #require(MixerStripReorder.resolve(
            pointerX: centre(0, rack), draggedID: tracks[3].id,
            tracks: store.tracks, ladder: rack))
        let landing = try #require(drop.landing)
        #expect(landing.arrayIndex == 0)
        try store.reorderTrack(id: tracks[3].id, toIndex: landing.arrayIndex)
        #expect(store.tracks.map(\.name) == ["C3", "C0", "B1", "C2"])
        #expect(MixerLayout.orderedStrips(store.tracks).map(\.name) == ["C3", "C0", "C2", "B1"])

        let path = dir.appendingPathComponent("MixerUp").path
        try store.saveProject(to: path)
        let reopened = ProjectStore()
        try reopened.openProject(at: path)
        #expect(reopened.tracks.map(\.name) == ["C3", "C0", "B1", "C2"])
    }
}
