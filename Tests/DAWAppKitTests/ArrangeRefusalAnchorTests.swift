import Foundation
import Testing
import DAWCore
@testable import DAWAppKit

// m23-am: the amber refusal bubble's anchor choice, as a truth table.
//
// WHY THIS SUITE EXISTS AT ALL. The choice used to be an inline expression in
// `AppModel.deleteArrangeSelection`, and `DAWApp` has NO test target — so the
// only thing that could observe it was a live staging gate. Moving the three-way
// precedence into a headless type (`EditorSurfaceRouter`'s shape) makes it
// machine-checkable here, and the gate then proves the app actually calls it.
//
// THE ROW THAT IS THE FIX is `errorNamedClipBeatsFocus`: before m23-am the focus
// came first and, on a track-header union, there was no focus at all so the
// anchor fell through to `Set.first`.

@Suite("Arrange refusal anchor (m23-am)")
struct ArrangeRefusalAnchorTests {
    private let offender = UUID()
    private let focused = UUID()
    private let firstTarget = UUID()

    private var takeGroupError: ProjectError {
        .clipInTakeGroup("PROBE TAKES", clipID: offender)
    }

    // 1. THE FIX. The store named a clip; that beats the focus, which is merely
    //    whatever the user last clicked.
    @Test("a clip named by the error outranks the selection focus")
    func errorNamedClipBeatsFocus() {
        let anchor = ArrangeRefusalAnchor.resolve(
            error: takeGroupError, focusID: focused,
            orderedTargets: [firstTarget, focused, offender])
        #expect(anchor == offender)
    }

    // 2. …and outranks the first target when there is no focus at all — the
    //    track-header union shape, which is the case the item was filed for.
    @Test("a clip named by the error outranks the first target when nothing is focused")
    func errorNamedClipBeatsFirstTargetWithNoFocus() {
        let anchor = ArrangeRefusalAnchor.resolve(
            error: takeGroupError, focusID: nil,
            orderedTargets: [firstTarget, offender])
        #expect(anchor == offender)
        #expect(anchor != firstTarget, "the pre-m23-am answer was firstTarget")
    }

    // 3. The single-clip case: the error names the clip the user acted on, so
    //    old and new answers COINCIDE. This is what makes the change safe for
    //    every pre-existing single-selection refusal.
    @Test("when the named clip IS the focus the answer is unchanged")
    func singleClipUnchanged() {
        let anchor = ArrangeRefusalAnchor.resolve(
            error: ProjectError.clipInTakeGroup("T", clipID: focused),
            focusID: focused, orderedTargets: [focused])
        #expect(anchor == focused)
    }

    // 4. An error that names NO clip falls back to the focus. `clipNotFound`
    //    carries a UUID and is still excluded on purpose: that clip is by
    //    definition absent from the project, so no block exists to draw on.
    @Test("an error naming no live clip falls back to the focus")
    func unnamedErrorFallsBackToFocus() {
        let ghost = UUID()
        let anchor = ArrangeRefusalAnchor.resolve(
            error: ProjectError.clipNotFound(ghost), focusID: focused,
            orderedTargets: [firstTarget, focused])
        #expect(anchor == focused)
        #expect(anchor != ghost)
    }

    // 5. …and with no focus either, to the first target in TRACK-THEN-CLIP order.
    //    This is the leg that keeps a refusal from ever being silent.
    @Test("no named clip and no focus falls back to the first ordered target")
    func unnamedErrorNoFocusFallsBackToFirstTarget() {
        let anchor = ArrangeRefusalAnchor.resolve(
            error: ProjectError.clipNotFound(UUID()), focusID: nil,
            orderedTargets: [firstTarget, offender])
        #expect(anchor == firstTarget)
    }

    // 6. A non-`ProjectError` cannot name a clip and must not crash the chain.
    @Test("a foreign error type falls through to the focus")
    func foreignErrorFallsThrough() {
        struct Other: Error {}
        #expect(ArrangeRefusalAnchor.resolve(error: Other(), focusID: focused,
                                             orderedTargets: [firstTarget]) == focused)
        #expect(ArrangeRefusalAnchor.resolve(error: Other(), focusID: nil,
                                             orderedTargets: [firstTarget]) == firstTarget)
    }

    // 7. Nothing to point at at all — nil, not a crash. Unreachable from the
    //    delete path (which guards a non-empty selection), asserted so the type
    //    stays honest for any future caller.
    @Test("nothing to anchor on returns nil")
    func emptyReturnsNil() {
        #expect(ArrangeRefusalAnchor.resolve(error: ProjectError.nothingToUndo,
                                             focusID: nil, orderedTargets: []) == nil)
    }
}
