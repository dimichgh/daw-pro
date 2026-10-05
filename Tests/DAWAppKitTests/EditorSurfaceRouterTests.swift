import Foundation
import Testing
@testable import DAWAppKit

/// m23-al-1 — the ONE home for "which editing surface is the user working in?".
///
/// WHY THE WHOLE 2×2×2×3 TABLE AND NOT A HANDFUL OF EXAMPLES. `resolve` has
/// three boolean-shaped inputs and a three-case latch, so the table is
/// TWENTY-FOUR rows (m23-ap p2-b grew it from eight) and a suite that swept
/// twenty of them would be leaving the untested four to chance.
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
        let pitchEditorOpen: Bool
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
        // ═══ THE MIX CONSOLE — no editor pane is MOUNTED, whatever else is true.
        Row(workspaceIsArrange: false, rollOpen: false, pitchEditorOpen: false,
            lastEngaged: .arrange, surface: .arrange, reason: .notArrangeWorkspace),
        Row(workspaceIsArrange: false, rollOpen: false, pitchEditorOpen: false,
            lastEngaged: .pianoRoll, surface: .arrange, reason: .notArrangeWorkspace),
        Row(workspaceIsArrange: false, rollOpen: false, pitchEditorOpen: false,
            lastEngaged: .pitchEditor, surface: .arrange, reason: .notArrangeWorkspace),
        Row(workspaceIsArrange: false, rollOpen: false, pitchEditorOpen: true,
            lastEngaged: .arrange, surface: .arrange, reason: .notArrangeWorkspace),
        Row(workspaceIsArrange: false, rollOpen: false, pitchEditorOpen: true,
            lastEngaged: .pianoRoll, surface: .arrange, reason: .notArrangeWorkspace),
        // ⭐ THE PITCH-EDITOR TWIN OF THE ROW THE WHOLE MIX TERM EXISTS FOR: an
        // audio clip is still latched open AND the latch still says the pitch
        // editor — but the console is up and there is no pane to zoom.
        Row(workspaceIsArrange: false, rollOpen: false, pitchEditorOpen: true,
            lastEngaged: .pitchEditor, surface: .arrange, reason: .notArrangeWorkspace),
        Row(workspaceIsArrange: false, rollOpen: true, pitchEditorOpen: false,
            lastEngaged: .arrange, surface: .arrange, reason: .notArrangeWorkspace),
        // ⭐ THE ROW THE WHOLE MIX TERM EXISTS FOR: a MIDI clip is still selected
        // (so `openEditorClip != nil`) and the latch still says the roll.
        Row(workspaceIsArrange: false, rollOpen: true, pitchEditorOpen: false,
            lastEngaged: .pianoRoll, surface: .arrange, reason: .notArrangeWorkspace),
        Row(workspaceIsArrange: false, rollOpen: true, pitchEditorOpen: false,
            lastEngaged: .pitchEditor, surface: .arrange, reason: .notArrangeWorkspace),
        Row(workspaceIsArrange: false, rollOpen: true, pitchEditorOpen: true,
            lastEngaged: .arrange, surface: .arrange, reason: .notArrangeWorkspace),
        Row(workspaceIsArrange: false, rollOpen: true, pitchEditorOpen: true,
            lastEngaged: .pianoRoll, surface: .arrange, reason: .notArrangeWorkspace),
        Row(workspaceIsArrange: false, rollOpen: true, pitchEditorOpen: true,
            lastEngaged: .pitchEditor, surface: .arrange, reason: .notArrangeWorkspace),

        // ═══ THE ARRANGE WORKSPACE WITH NOTHING OPEN: the latch is not consulted.
        Row(workspaceIsArrange: true, rollOpen: false, pitchEditorOpen: false,
            lastEngaged: .arrange, surface: .arrange, reason: .noRollOpen),
        // ⭐ A CLOSED PANE CAN NEVER BE THE ACTIVE SURFACE, however the latch reads
        // — and that is now TWO mutants this pair of rows kills, not one.
        Row(workspaceIsArrange: true, rollOpen: false, pitchEditorOpen: false,
            lastEngaged: .pianoRoll, surface: .arrange, reason: .noRollOpen),
        Row(workspaceIsArrange: true, rollOpen: false, pitchEditorOpen: false,
            lastEngaged: .pitchEditor, surface: .arrange, reason: .noRollOpen),

        // ═══ THE PITCH EDITOR ON SCREEN — now, and only now, the latch decides.
        Row(workspaceIsArrange: true, rollOpen: false, pitchEditorOpen: true,
            lastEngaged: .arrange, surface: .arrange, reason: .engagedArrange),
        // ⚠️ A STALE `.pianoRoll` LATCH MUST NOT CLAIM THE PITCH EDITOR. `resolve`
        // compares the latch against the pane that is ACTUALLY open, never
        // merely against "is it non-arrange" — otherwise ⌘+ would zoom a roll
        // that is not on screen, which is the failure the workspace term exists
        // to prevent, one surface over.
        Row(workspaceIsArrange: true, rollOpen: false, pitchEditorOpen: true,
            lastEngaged: .pianoRoll, surface: .arrange, reason: .engagedArrange),
        Row(workspaceIsArrange: true, rollOpen: false, pitchEditorOpen: true,
            lastEngaged: .pitchEditor, surface: .pitchEditor, reason: .engagedPitchEditor),

        // ═══ THE ROLL ON SCREEN.
        Row(workspaceIsArrange: true, rollOpen: true, pitchEditorOpen: false,
            lastEngaged: .arrange, surface: .arrange, reason: .engagedArrange),
        Row(workspaceIsArrange: true, rollOpen: true, pitchEditorOpen: false,
            lastEngaged: .pianoRoll, surface: .pianoRoll, reason: .engagedRoll),
        // ⚠️ AND THE MIRROR: a `.pitchEditor` latch must not claim the ROLL.
        Row(workspaceIsArrange: true, rollOpen: true, pitchEditorOpen: false,
            lastEngaged: .pitchEditor, surface: .arrange, reason: .engagedArrange),

        // ═══ BOTH PANES "OPEN" — UNREACHABLE IN THE APP, PINNED ANYWAY.
        // `AppModel.openEditorClip` requires `isMIDI` and `openPitchEditorClip`
        // requires `!isMIDI` of the SAME `selectedClipID`, so these three rows
        // cannot occur (design §3.6, property 1). A pure rule must still answer
        // them, and the ROLL wins: it is the older surface, and a tie-break
        // nobody can reach must not be a new behaviour. ⭐ If the app ever DOES
        // reach one, this is the pin that makes the answer a decision rather
        // than whichever guard happened to be written first.
        Row(workspaceIsArrange: true, rollOpen: true, pitchEditorOpen: true,
            lastEngaged: .arrange, surface: .arrange, reason: .engagedArrange),
        Row(workspaceIsArrange: true, rollOpen: true, pitchEditorOpen: true,
            lastEngaged: .pianoRoll, surface: .pianoRoll, reason: .engagedRoll),
        Row(workspaceIsArrange: true, rollOpen: true, pitchEditorOpen: true,
            lastEngaged: .pitchEditor, surface: .arrange, reason: .engagedArrange),
    ]

    @Test("resolve sweeps the full 2×2×2×3 table, asserting BOTH the surface and the reason")
    func fullTruthTable() {
        // Fixture check first: the table really is the whole product space, not
        // seven rows plus a duplicate. A sweep with a missing row passes exactly
        // as loudly as a complete one.
        #expect(Self.table.count == 24)
        let keys = Set(Self.table.map {
            "\($0.workspaceIsArrange)/\($0.rollOpen)/\($0.pitchEditorOpen)/\($0.lastEngaged)"
        })
        #expect(keys.count == 24, "the table must cover each input tuple exactly once")

        for row in Self.table {
            let got = EditorSurfaceRouter.resolve(
                workspaceIsArrange: row.workspaceIsArrange,
                rollOpen: row.rollOpen,
                pitchEditorOpen: row.pitchEditorOpen,
                lastEngaged: row.lastEngaged)
            let label = "workspaceIsArrange=\(row.workspaceIsArrange) "
                + "rollOpen=\(row.rollOpen) pitchEditorOpen=\(row.pitchEditorOpen) "
                + "lastEngaged=\(row.lastEngaged)"
            // Field-by-field, NOT against a constructed expectation: the
            // `fileprivate init` on `ActiveEditorSurface` means a test cannot mint
            // one, and widening it to make `==` convenient would destroy the very
            // mechanism that keeps a divergent verdict unrepresentable.
            #expect(got.surface == row.surface, "surface — \(label)")
            #expect(got.reason == row.reason, "reason — \(label)")
        }
    }

    @Test("each editor pane is the active surface in EXACTLY the rows it should be")
    func eachPaneWinsExactlyItsOwnRows() {
        // The anti-vacuity twin of the sweep above: a resolver hardwired to
        // `.arrange` passes every `.arrange` row, and a resolver that returned a
        // pane whenever that pane was open would pass its winning row too.
        // Counting the rows pins both mutants at once, now on both panes.
        //
        // ⭐ THE ROLL'S COUNT IS **2**, NOT 1, AND THE SECOND ONE IS NOT A BUG:
        // it is the unreachable both-open row that the table above decides in
        // the roll's favour. Writing 1 here would be the "I expected the old
        // number" fix that hides a real decision.
        var rollRows: [String] = []
        var pitchRows: [String] = []
        for workspace in [true, false] {
            for open in [true, false] {
                for pitch in [true, false] {
                    for engaged in EditorSurface.allCases {
                        let got = EditorSurfaceRouter.resolve(
                            workspaceIsArrange: workspace, rollOpen: open,
                            pitchEditorOpen: pitch, lastEngaged: engaged)
                        let key = "\(workspace)/\(open)/\(pitch)/\(engaged)"
                        if got.surface == .pianoRoll { rollRows.append(key) }
                        if got.surface == .pitchEditor { pitchRows.append(key) }
                    }
                }
            }
        }
        #expect(rollRows == ["true/true/true/pianoRoll", "true/true/false/pianoRoll"],
                "the roll wins exactly its own rows; got \(rollRows)")
        #expect(pitchRows == ["true/false/true/pitchEditor"],
                "the pitch editor wins exactly its own row; got \(pitchRows)")
    }

    @Test("every Reason case is reachable — no term is dead")
    func everyReasonIsReachable() {
        var seen: Set<ActiveEditorSurface.Reason> = []
        for workspace in [true, false] {
            for open in [true, false] {
                for pitch in [true, false] {
                    for engaged in EditorSurface.allCases {
                        seen.insert(EditorSurfaceRouter.resolve(
                            workspaceIsArrange: workspace, rollOpen: open,
                            pitchEditorOpen: pitch, lastEngaged: engaged).reason)
                    }
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
                for pitch in [true, false] {
                    for engaged in EditorSurface.allCases {
                        let got = EditorSurfaceRouter.resolve(
                            workspaceIsArrange: workspace, rollOpen: open,
                            pitchEditorOpen: pitch, lastEngaged: engaged)
                        switch got.reason {
                        case .engagedRoll: #expect(got.surface == .pianoRoll)
                        case .engagedPitchEditor: #expect(got.surface == .pitchEditor)
                        case .notArrangeWorkspace, .noRollOpen, .engagedArrange:
                            #expect(got.surface == .arrange)
                        }
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
                    rollOpen: row.rollOpen, pitchEditorOpen: row.pitchEditorOpen,
                    lastEngaged: row.lastEngaged)
                #expect(got.surface == row.surface)
                #expect(got.reason == row.reason)
            }
        }
    }

    // MARK: - openSurface — the OPEN-ness verdict (m34-d)

    /// ⭐ **THE SECOND VERDICT, AND WHY IT EXISTS.** The user ruled on ⌘A
    /// 2026-08-30, verbatim: ***"Make it work whenever the editor is open."***
    /// `resolve` answers "which surface is the user WORKING IN"; this answers
    /// "which surface is OPEN IN FRONT OF THEM", and the two deliberately
    /// disagree in exactly the state the user reported as a bug.
    @Test("openSurface sweeps its full 2×2×2 table, asserting BOTH the surface and the reason")
    func openSurfaceTruthTable() {
        let rows: [(workspaceIsArrange: Bool, rollOpen: Bool, pitchEditorOpen: Bool,
                    surface: EditorSurface, reason: OpenEditorSurface.Reason)] = [
            // The MIX CONSOLE first — the term `EditorSurfaceRouter` calls the
            // easiest thing to drop, and the one a bare `openEditorClip != nil`
            // silently loses. It outranks BOTH pane terms.
            (false, false, false, .arrange, .notArrangeWorkspace),
            (false, false, true, .arrange, .notArrangeWorkspace),
            (false, true, false, .arrange, .notArrangeWorkspace),
            (false, true, true, .arrange, .notArrangeWorkspace),
            // Arrange workspace, nothing open.
            (true, false, false, .arrange, .noRollOpen),
            // ⭐ m23-ap p2-b: the pitch editor is open and the roll is not.
            (true, false, true, .pitchEditor, .pitchEditorOpen),
            // ⭐ THE m34-d ROW: open is open, with no engagement asked for.
            (true, true, false, .pianoRoll, .rollOpen),
            // ⚠️ UNREACHABLE IN THE APP (the two accessors filter opposite sides
            // of `isMIDI` on one `selectedClipID`) — and pinned so the tie-break
            // is a decision rather than an accident of guard order.
            (true, true, true, .pianoRoll, .rollOpen),
        ]
        #expect(rows.count == 8)
        let keys = Set(rows.map { "\($0.workspaceIsArrange)/\($0.rollOpen)/\($0.pitchEditorOpen)" })
        #expect(keys.count == 8, "the table must cover each input triple exactly once")

        for row in rows {
            let got = EditorSurfaceRouter.openSurface(
                workspaceIsArrange: row.workspaceIsArrange, rollOpen: row.rollOpen,
                pitchEditorOpen: row.pitchEditorOpen)
            let label = "workspaceIsArrange=\(row.workspaceIsArrange) "
                + "rollOpen=\(row.rollOpen) pitchEditorOpen=\(row.pitchEditorOpen)"
            // Field-by-field, for `fullTruthTable`'s reason: `OpenEditorSurface`'s
            // init is `fileprivate` and widening it to make `==` convenient would
            // destroy the mechanism keeping a divergent verdict unrepresentable.
            #expect(got.surface == row.surface, "surface — \(label)")
            #expect(got.reason == row.reason, "reason — \(label)")
        }
    }

    /// ⭐⭐ **THE DISAGREEMENT IS THE FEATURE, AND IT IS PINNED IN BOTH
    /// DIRECTIONS.** In exactly one state — arrange workspace, roll open, arrange
    /// most recently engaged — the two verdicts must differ: that is the first
    /// press the user reported. In every other state they must AGREE, because a
    /// second point of divergence would be a bug nobody ruled on.
    @Test("openSurface and resolve differ in EXACTLY the m34-d state, and nowhere else")
    func theTwoVerdictsDivergeOnlyOnTheFirstPress() {
        var divergences: [String] = []
        for workspace in [true, false] {
            for open in [true, false] {
                for pitch in [true, false] {
                    for engaged in EditorSurface.allCases {
                        let active = EditorSurfaceRouter.resolve(
                            workspaceIsArrange: workspace, rollOpen: open,
                            pitchEditorOpen: pitch, lastEngaged: engaged)
                        let mounted = EditorSurfaceRouter.openSurface(
                            workspaceIsArrange: workspace, rollOpen: open,
                            pitchEditorOpen: pitch)
                        if active.surface != mounted.surface {
                            divergences.append("\(workspace)/\(open)/\(pitch)/\(engaged)")
                        }
                    }
                }
            }
        }
        // ⚠️ ANTI-VACUITY: a `openSurface` hardwired to `.arrange` would produce
        // ZERO divergences and pass a "they never disagree" test. Requiring the
        // exact set makes that mutant red.
        //
        // ⭐ SIX ROWS SINCE m23-ap p2-b, AND EVERY ONE IS THE SAME PHENOMENON —
        // "a pane is open and the user has not acted in it yet" — not a second
        // divergence nobody ruled on. Four are the roll's (its first press, ×
        // both values of the unreachable `pitchEditorOpen` term, × the two
        // latches that are not `.pianoRoll`); two are the pitch editor's, and
        // they are the roll's row read one surface over.
        #expect(divergences == [
            "true/true/true/arrange",
            "true/true/true/pitchEditor",
            "true/true/false/arrange",
            "true/true/false/pitchEditor",
            "true/false/true/arrange",
            "true/false/true/pianoRoll",
        ], "expected divergence in exactly the first-press states; got \(divergences)")
    }

    @Test("every openSurface Reason is reachable — no term is dead")
    func everyOpenReasonIsReachable() {
        var seen: Set<OpenEditorSurface.Reason> = []
        for workspace in [true, false] {
            for open in [true, false] {
                for pitch in [true, false] {
                    seen.insert(EditorSurfaceRouter.openSurface(
                        workspaceIsArrange: workspace, rollOpen: open,
                        pitchEditorOpen: pitch).reason)
                }
            }
        }
        #expect(seen == Set(OpenEditorSurface.Reason.allCases))
    }

    @Test("openSurface's reason is never inconsistent with the surface it accompanies")
    func openReasonAndSurfaceAgree() {
        for workspace in [true, false] {
            for open in [true, false] {
                for pitch in [true, false] {
                    let got = EditorSurfaceRouter.openSurface(
                        workspaceIsArrange: workspace, rollOpen: open,
                        pitchEditorOpen: pitch)
                    switch got.reason {
                    case .rollOpen: #expect(got.surface == .pianoRoll)
                    case .pitchEditorOpen: #expect(got.surface == .pitchEditor)
                    case .notArrangeWorkspace, .noRollOpen: #expect(got.surface == .arrange)
                    }
                }
            }
        }
    }

    /// ⭐ **`resolve` IS IMPLEMENTED ON TOP OF `openSurface`, AND THIS IS THE
    /// BEHAVIOURAL PIN ON THAT REFACTOR** — the two share their first two terms
    /// by construction, so a change to either must move both. Stated as an
    /// invariant rather than as a source-shape check: what matters is that the
    /// answers cannot drift, not how the file is spelled.
    @Test("the two verdicts agree on the shared terms — one computation, two questions")
    func theSharedTermsCannotDrift() {
        for workspace in [true, false] {
            for open in [true, false] {
                for pitch in [true, false] {
                    let mounted = EditorSurfaceRouter.openSurface(
                        workspaceIsArrange: workspace, rollOpen: open, pitchEditorOpen: pitch)
                    for engaged in EditorSurface.allCases {
                        let active = EditorSurfaceRouter.resolve(
                            workspaceIsArrange: workspace, rollOpen: open,
                            pitchEditorOpen: pitch, lastEngaged: engaged)
                        switch mounted.reason {
                        case .notArrangeWorkspace:
                            #expect(active.reason == .notArrangeWorkspace)
                        case .noRollOpen:
                            #expect(active.reason == .noRollOpen)
                        case .rollOpen:
                            // Only here may the latch speak at all.
                            #expect(active.reason == .engagedArrange
                                    || active.reason == .engagedRoll)
                        case .pitchEditorOpen:
                            #expect(active.reason == .engagedArrange
                                    || active.reason == .engagedPitchEditor)
                        }
                    }
                }
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
        #expect(EditorSurface.pitchEditor.rawValue == "pitchEditor")
        #expect(EditorSurface.allCases.count == 3)
    }

    @Test("every Reason rawValue is the exact string the seams echo")
    func reasonRawValues() {
        #expect(ActiveEditorSurface.Reason.notArrangeWorkspace.rawValue == "notArrangeWorkspace")
        #expect(ActiveEditorSurface.Reason.noRollOpen.rawValue == "noRollOpen")
        #expect(ActiveEditorSurface.Reason.engagedArrange.rawValue == "engagedArrange")
        #expect(ActiveEditorSurface.Reason.engagedRoll.rawValue == "engagedRoll")
        #expect(ActiveEditorSurface.Reason.engagedPitchEditor.rawValue == "engagedPitchEditor")
        #expect(ActiveEditorSurface.Reason.allCases.count == 5)
    }

    /// ⚠️ **NOT ON THE WIRE TODAY, AND PINNED ANYWAY (m34-d).** Nothing echoes
    /// `OpenEditorSurface.Reason` yet — this item added ZERO wire commands and no
    /// new echo field. The spellings are pinned so that the day a seam does
    /// publish them, the strings are already contract rather than whatever a
    /// later rename left behind; the two shared with `ActiveEditorSurface.Reason`
    /// are deliberately IDENTICAL so a reader can line the two verdicts up.
    @Test("openSurface Reason rawValues are stable, and share the two names they mean to")
    func openReasonRawValues() {
        #expect(OpenEditorSurface.Reason.notArrangeWorkspace.rawValue == "notArrangeWorkspace")
        #expect(OpenEditorSurface.Reason.noRollOpen.rawValue == "noRollOpen")
        #expect(OpenEditorSurface.Reason.rollOpen.rawValue == "rollOpen")
        #expect(OpenEditorSurface.Reason.pitchEditorOpen.rawValue == "pitchEditorOpen")
        #expect(OpenEditorSurface.Reason.allCases.count == 4)
        // The shared pair really is shared, spelling for spelling.
        #expect(OpenEditorSurface.Reason.notArrangeWorkspace.rawValue
                == ActiveEditorSurface.Reason.notArrangeWorkspace.rawValue)
        #expect(OpenEditorSurface.Reason.noRollOpen.rawValue
                == ActiveEditorSurface.Reason.noRollOpen.rawValue)
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

    // MARK: - The pitch editor's own terms (m23-ap p2-b)

    /// ⭐⭐ **THE LATCH IS COMPARED AGAINST THE PANE THAT IS ACTUALLY OPEN, NOT
    /// AGAINST "IS IT NON-ARRANGE".** With three cases the tempting shape is
    /// `lastEngaged != .arrange ? lastEngaged : .arrange`, which is *shorter*,
    /// *total*, and **wrong**: it hands ⌘+ to a piano roll that is not on screen
    /// the moment the user opens a pitch editor after editing a MIDI clip. That
    /// is the same class as the workspace term's failure (zooming a roll behind
    /// the Mix console), which this file's banner calls "the easiest thing to
    /// drop", so it gets its own named leg rather than relying on two rows of a
    /// 24-row sweep to notice.
    @Test("a latch pointing at the OTHER pane never claims the one that is open")
    func aStaleLatchNeverClaimsTheOpenPane() {
        let rollLatchOnPitchPane = EditorSurfaceRouter.resolve(
            workspaceIsArrange: true, rollOpen: false, pitchEditorOpen: true,
            lastEngaged: .pianoRoll)
        #expect(rollLatchOnPitchPane.surface == .arrange,
                "a `.pianoRoll` latch must not make the PITCH EDITOR active — the roll is not on screen to zoom")
        #expect(rollLatchOnPitchPane.reason == .engagedArrange)

        let pitchLatchOnRoll = EditorSurfaceRouter.resolve(
            workspaceIsArrange: true, rollOpen: true, pitchEditorOpen: false,
            lastEngaged: .pitchEditor)
        #expect(pitchLatchOnRoll.surface == .arrange,
                "a `.pitchEditor` latch must not make the ROLL active")
        #expect(pitchLatchOnRoll.reason == .engagedArrange)
    }

    /// ⚠️ **THE `noRollOpen` SPELLING NOW MEANS "NEITHER PANE IS OPEN", AND IT
    /// WAS DELIBERATELY NOT RENAMED.** It is echoed by `debug.editorSurface` and
    /// the standing wire rule is additive-only — never rename a live string. A
    /// reader who needs the distinction reads `OpenEditorSurface.Reason`, which
    /// carries a case per pane. This leg pins the meaning so a later "tidy-up"
    /// rename is a red test rather than a silent wire break.
    @Test("`noRollOpen` is reached only when NEITHER pane is open")
    func noRollOpenMeansNeitherPane() {
        for pitch in [true, false] {
            for engaged in EditorSurface.allCases {
                let got = EditorSurfaceRouter.resolve(
                    workspaceIsArrange: true, rollOpen: false, pitchEditorOpen: pitch,
                    lastEngaged: engaged)
                if pitch {
                    #expect(got.reason != .noRollOpen,
                            "a pitch editor IS open — `noRollOpen` would tell a red gate 'nothing is on screen' about a pane the user is looking at")
                } else {
                    #expect(got.reason == .noRollOpen)
                }
            }
        }
        #expect(EditorSurfaceRouter.openSurface(
            workspaceIsArrange: true, rollOpen: false, pitchEditorOpen: false).reason
                == .noRollOpen)
    }

    /// ⭐ **REWRITTEN ON PURPOSE AT m23-ap I4** — it was "Select All refuses the
    /// pitch editor under its OWN reason" (`selectAllRefusesThePitchEditorByName`),
    /// pinning p2-b's `SelectAllRefusal.pitchEditorOpen`: the pane was read-only,
    /// held no selection, and design §3.6 left ⌘A to the interaction model. I4
    /// IS that model (§7): the pane holds a note selection, so the arm went LIVE
    /// on the openness verdict (the m34-d ruling) and the refusal it pinned was
    /// retired. MEASURED RED before this rewrite: the old assertions read a live
    /// `.pitchEditorNotes` item where they expected `"pitch-editor-open"`.
    ///
    /// What survives of the old pin is its point: the pane is never folded into
    /// `noRollOpen` or the ROLL's `emptyRoll` — an empty pane refuses under its
    /// OWN name.
    @Test("Select All targets the open note editor's notes, and an EMPTY one refuses under its OWN reason")
    func selectAllTargetsTheOpenNoteEditor() {
        let open = EditorSurfaceRouter.openSurface(
            workspaceIsArrange: true, rollOpen: false, pitchEditorOpen: true)
        let live = SelectAllMenuPolicy.editMenuItem(
            openSurface: open, isModalPresented: false, rollNoteCount: 0,
            pitchEditorNoteCount: 12)
        #expect(live.isEnabled)
        #expect(live.surface == .pitchEditorNotes)
        #expect(live.title == "Select All")
        // ⚠️ ANTI-VACUITY: the ROLL's count is ZERO above and the item is still
        // live, so it is the PANE's count doing the work; and below the pane's
        // count is zero with the roll's NON-zero, so a policy that read the
        // wrong count would be red in one leg or the other.
        let empty = SelectAllMenuPolicy.editMenuItem(
            openSurface: open, isModalPresented: false, rollNoteCount: 12,
            pitchEditorNoteCount: 0)
        #expect(!empty.isEnabled)
        #expect(empty.refusedBy == .emptyPitchEditor)
        #expect(empty.refusedBy != .emptyRoll)
        #expect(empty.refusedBy != .noRollOpen)
        // A modal still refuses first, as it does for the roll.
        #expect(SelectAllMenuPolicy.editMenuItem(
            openSurface: open, isModalPresented: true, rollNoteCount: 0,
            pitchEditorNoteCount: 12).refusedBy == .modal)
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
            workspaceIsArrange: true, rollOpen: false, pitchEditorOpen: false,
            lastEngaged: latch.lastEngaged)
        #expect(closed.surface == .arrange)
        #expect(closed.reason == .noRollOpen)
        #expect(latch.lastEngaged == .pianoRoll, "resolving must not mutate the latch")
        #expect(latch.transitionSeq == 1)

        let reopened = EditorSurfaceRouter.resolve(
            workspaceIsArrange: true, rollOpen: true, pitchEditorOpen: false,
            lastEngaged: latch.lastEngaged)
        #expect(reopened.surface == .pianoRoll)
        #expect(reopened.reason == .engagedRoll)
    }
}
