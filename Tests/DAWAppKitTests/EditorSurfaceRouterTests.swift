import Foundation
import Testing
@testable import DAWAppKit

/// m23-al-1 — the ONE home for "which editing surface is the user working in?".
///
/// WHY THE WHOLE 2×2×2 TABLE AND NOT A HANDFUL OF EXAMPLES. `resolve` has three
/// boolean-shaped inputs and four outcomes, so the table is EIGHT rows and a
/// suite that swept six of them would be leaving the untested pair to chance.
/// Specifically the four `workspaceIsArrange == false` rows are the ones that pin
/// the Mix-console term — the term the design names as "the easiest thing to
/// drop", because `openEditorClip` looks like it already means "the roll is on
/// screen" and does not (it carries no workspace term at all, so in the Mix
/// console a MIDI clip stays selected with no `PianoRollView` mounted).
///
/// THE SUITE IS NOT `@MainActor`, AND THAT IS A STRUCTURAL CLAIM RATHER THAN A
/// CONVENIENCE. `resolve` is `nonisolated` and pure, so the rule needs no app, no
/// view and no actor to state or to check — the `WidenedArrangeSelectionDropTests`
/// precedent. The engagement LATCH is `@MainActor` (it is an `@Observable` the
/// views report into), so its tests carry the annotation individually.
///
/// WHAT THESE TESTS CANNOT REACH, stated rather than implied: `DAWApp` has no test
/// target, so the ACCESSOR that feeds `resolve` (`AppModel.activeEditorSurface`),
/// the eight roll funnels R1–R8 and the five arrange ones are unreachable from
/// here. The wiring half is proven by `scripts/gates/m23al-editor-surface.mjs`
/// against a real app on staging, and the SOURCE-SHAPE half by
/// `EditorSurfaceOwnershipSiteTests`.
@Suite("Editor surface ownership — the router (m23-al-1)")
struct EditorSurfaceRouterTests {

    // MARK: - The full truth table

    /// One row of the table, written out longhand so a failure names the row.
    private struct Row {
        let workspaceIsArrange: Bool
        let rollOpen: Bool
        let lastEngaged: EditorSurface
        let surface: EditorSurface
        let reason: ActiveEditorSurface.Reason
    }

    /// ALL EIGHT ROWS. The order of the guards is part of the contract: the
    /// workspace term is checked FIRST, so rows 1–4 answer `notArrangeWorkspace`
    /// even when the roll is open and even when the latch says `pianoRoll` — a
    /// resolver that checked `rollOpen` first would report `noRollOpen` for row 1
    /// and `engagedRoll` for row 4, and only row 4 is a behaviour change. Both
    /// are pinned.
    private static let table: [Row] = [
        // The Mix console: no PianoRollView is MOUNTED, whatever else is true.
        Row(workspaceIsArrange: false, rollOpen: false, lastEngaged: .arrange,
            surface: .arrange, reason: .notArrangeWorkspace),
        Row(workspaceIsArrange: false, rollOpen: false, lastEngaged: .pianoRoll,
            surface: .arrange, reason: .notArrangeWorkspace),
        Row(workspaceIsArrange: false, rollOpen: true, lastEngaged: .arrange,
            surface: .arrange, reason: .notArrangeWorkspace),
        // ⭐ THE ROW THE WHOLE MIX TERM EXISTS FOR: a MIDI clip is still selected
        // (so `openEditorClip != nil`) and the latch still says the roll — but the
        // console is up and there is no roll to zoom.
        Row(workspaceIsArrange: false, rollOpen: true, lastEngaged: .pianoRoll,
            surface: .arrange, reason: .notArrangeWorkspace),

        // The arrange workspace with no clip open: the latch is not consulted.
        Row(workspaceIsArrange: true, rollOpen: false, lastEngaged: .arrange,
            surface: .arrange, reason: .noRollOpen),
        // ⭐ A CLOSED ROLL CAN NEVER BE THE ACTIVE SURFACE, however the latch reads.
        Row(workspaceIsArrange: true, rollOpen: false, lastEngaged: .pianoRoll,
            surface: .arrange, reason: .noRollOpen),

        // Roll on screen — now, and only now, the latch decides.
        Row(workspaceIsArrange: true, rollOpen: true, lastEngaged: .arrange,
            surface: .arrange, reason: .engagedArrange),
        Row(workspaceIsArrange: true, rollOpen: true, lastEngaged: .pianoRoll,
            surface: .pianoRoll, reason: .engagedRoll),
    ]

    @Test("resolve sweeps the full 2×2×2 table, asserting BOTH the surface and the reason")
    func fullTruthTable() {
        // Fixture check first: the table really is the whole product space, not
        // seven rows plus a duplicate. A sweep with a missing row passes exactly
        // as loudly as a complete one.
        #expect(Self.table.count == 8)
        let keys = Set(Self.table.map { "\($0.workspaceIsArrange)/\($0.rollOpen)/\($0.lastEngaged)" })
        #expect(keys.count == 8, "the table must cover each input triple exactly once")

        for row in Self.table {
            let got = EditorSurfaceRouter.resolve(
                workspaceIsArrange: row.workspaceIsArrange,
                rollOpen: row.rollOpen,
                lastEngaged: row.lastEngaged)
            let label = "workspaceIsArrange=\(row.workspaceIsArrange) "
                + "rollOpen=\(row.rollOpen) lastEngaged=\(row.lastEngaged)"
            // Field-by-field, NOT against a constructed expectation: the
            // `fileprivate init` on `ActiveEditorSurface` means a test cannot mint
            // one, and widening it to make `==` convenient would destroy the very
            // mechanism that keeps a divergent verdict unrepresentable.
            #expect(got.surface == row.surface, "surface — \(label)")
            #expect(got.reason == row.reason, "reason — \(label)")
        }
    }

    @Test("the piano roll is the active surface in EXACTLY ONE of the eight rows")
    func exactlyOneRollRow() {
        // The anti-vacuity twin of the sweep above: a resolver hardwired to
        // `.arrange` passes every `.arrange` row, and a resolver that returned
        // `.pianoRoll` whenever the roll is open would pass row 8 too. Counting
        // the rows pins both mutants at once.
        var rollRows = 0
        for workspace in [true, false] {
            for open in [true, false] {
                for engaged in EditorSurface.allCases {
                    let got = EditorSurfaceRouter.resolve(
                        workspaceIsArrange: workspace, rollOpen: open, lastEngaged: engaged)
                    if got.surface == .pianoRoll { rollRows += 1 }
                }
            }
        }
        #expect(rollRows == 1)
    }

    @Test("every Reason case is reachable — no term is dead")
    func everyReasonIsReachable() {
        var seen: Set<ActiveEditorSurface.Reason> = []
        for workspace in [true, false] {
            for open in [true, false] {
                for engaged in EditorSurface.allCases {
                    seen.insert(EditorSurfaceRouter.resolve(
                        workspaceIsArrange: workspace, rollOpen: open,
                        lastEngaged: engaged).reason)
                }
            }
        }
        // A resolver that dropped a term would still answer, and would still be
        // TOTAL — it would simply never produce that term's reason again. This is
        // the assertion that notices.
        #expect(seen == Set(ActiveEditorSurface.Reason.allCases))
    }

    @Test("the reason is never inconsistent with the surface it accompanies")
    func reasonAndSurfaceAgree() {
        for workspace in [true, false] {
            for open in [true, false] {
                for engaged in EditorSurface.allCases {
                    let got = EditorSurfaceRouter.resolve(
                        workspaceIsArrange: workspace, rollOpen: open, lastEngaged: engaged)
                    switch got.reason {
                    case .engagedRoll: #expect(got.surface == .pianoRoll)
                    case .notArrangeWorkspace, .noRollOpen, .engagedArrange:
                        #expect(got.surface == .arrange)
                    }
                }
            }
        }
    }

    @Test("resolve is a pure function — the same inputs answer the same way every time")
    func resolveIsPure() {
        for _ in 0..<3 {
            for row in Self.table {
                let got = EditorSurfaceRouter.resolve(
                    workspaceIsArrange: row.workspaceIsArrange,
                    rollOpen: row.rollOpen, lastEngaged: row.lastEngaged)
                #expect(got.surface == row.surface)
                #expect(got.reason == row.reason)
            }
        }
    }

    // MARK: - The wire contract

    @Test("EditorSurface round-trips its rawValue — the wire depends on it")
    func surfaceRoundTrips() {
        for surface in EditorSurface.allCases {
            #expect(EditorSurface(rawValue: surface.rawValue) == surface)
        }
        // Byte-exact, because `debug.viewZoom` and the `debug.arrangeSelection`
        // echo publish these strings and `act:"engage"` PARSES them. Renaming a
        // case silently is a wire break, so the spellings are contract.
        #expect(EditorSurface.arrange.rawValue == "arrange")
        #expect(EditorSurface.pianoRoll.rawValue == "pianoRoll")
        #expect(EditorSurface.allCases.count == 2)
    }

    @Test("every Reason rawValue is the exact string the seams echo")
    func reasonRawValues() {
        #expect(ActiveEditorSurface.Reason.notArrangeWorkspace.rawValue == "notArrangeWorkspace")
        #expect(ActiveEditorSurface.Reason.noRollOpen.rawValue == "noRollOpen")
        #expect(ActiveEditorSurface.Reason.engagedArrange.rawValue == "engagedArrange")
        #expect(ActiveEditorSurface.Reason.engagedRoll.rawValue == "engagedRoll")
        #expect(ActiveEditorSurface.Reason.allCases.count == 4)
    }

    // MARK: - The latch

    @MainActor
    @Test("a fresh engagement latch starts on the ARRANGE with a zero transition count")
    func latchStartsInTheArrange() {
        let latch = EditorSurfaceEngagement()
        #expect(latch.lastEngaged == .arrange)
        #expect(latch.transitionSeq == 0)
    }

    @MainActor
    @Test("engage is CHANGE-GUARDED: two identical engages count ONE transition, not two")
    func engageIsChangeGuarded() {
        let latch = EditorSurfaceEngagement()
        latch.engage(.pianoRoll)
        #expect(latch.lastEngaged == .pianoRoll)
        #expect(latch.transitionSeq == 1)

        // The load-bearing half. `beginGesture` and `scrubDrag.onChanged` fire on
        // EVERY tick of a drag; without the guard each tick would bump the seq and
        // invalidate every observer of this object at pointer rate.
        for _ in 0..<25 { latch.engage(.pianoRoll) }
        #expect(latch.lastEngaged == .pianoRoll)
        #expect(latch.transitionSeq == 1, "a repeat engage is not a transition")
    }

    @MainActor
    @Test("engaging the SAME surface the latch already starts on is not a transition either")
    func engagingTheInitialSurfaceIsNotATransition() {
        // The boundary the guard is easiest to get wrong at: the app starts in
        // the arrange, and the very first arrange click must not count.
        let latch = EditorSurfaceEngagement()
        latch.engage(.arrange)
        #expect(latch.transitionSeq == 0)
        #expect(latch.lastEngaged == .arrange)
    }

    @MainActor
    @Test("alternating engagements count TRANSITIONS, one per crossing")
    func alternatingEngagementsCount() {
        let latch = EditorSurfaceEngagement()
        latch.engage(.pianoRoll)                      // +1
        latch.engage(.arrange)                        // +1
        #expect(latch.transitionSeq == 2)
        #expect(latch.lastEngaged == .arrange)

        // The m23-ak law, restated in this type's terms: A DESYNCHRONISED LATCH
        // CAN NEVER BE RE-CLAIMED. Losing the roll to an arrange click and taking
        // it back must work, indefinitely — this is the `m23al` gate's leg F.
        latch.engage(.pianoRoll)                      // +1
        #expect(latch.transitionSeq == 3)
        #expect(latch.lastEngaged == .pianoRoll)
    }

    @MainActor
    @Test("the latch feeds resolve, and a closed roll overrides it rather than clearing it")
    func latchSurvivesARollThatCloses() {
        // The separation of concerns this whole design rests on: `engage` records
        // WHERE THE USER ACTED and never asks whether the surface exists; the
        // resolver applies the visibility terms. So closing the roll must NOT
        // reset the latch — reopening the same clip has to find it still there.
        let latch = EditorSurfaceEngagement()
        latch.engage(.pianoRoll)

        let closed = EditorSurfaceRouter.resolve(
            workspaceIsArrange: true, rollOpen: false, lastEngaged: latch.lastEngaged)
        #expect(closed.surface == .arrange)
        #expect(closed.reason == .noRollOpen)
        #expect(latch.lastEngaged == .pianoRoll, "resolving must not mutate the latch")
        #expect(latch.transitionSeq == 1)

        let reopened = EditorSurfaceRouter.resolve(
            workspaceIsArrange: true, rollOpen: true, lastEngaged: latch.lastEngaged)
        #expect(reopened.surface == .pianoRoll)
        #expect(reopened.reason == .engagedRoll)
    }
}
