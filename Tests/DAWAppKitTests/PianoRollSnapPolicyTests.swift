import Testing
import Foundation
import DAWCore
@testable import DAWAppKit

/// m25-ab — **THE NOTE EDITOR'S SNAP HAS ONE HOME AGAIN.**
///
/// The user reported (2026-08-16): *"when placing playhead in node editor with
/// snap:off, it still places at the start or end of the note grid instead of
/// where I mouse click or drag the play head while it works well if I do this in
/// clip/track area."*
///
/// ⚠️⚠️ **THAT WAS NEVER A SNAP-MATH BUG — IT WAS TWO HOMES WEARING ONE LABEL.**
/// The toolbar `SNAP:` chip writes `AppModel.clipSnap` (a `ClipSnap`); the roll
/// header's `SNAP:` chip wrote a `@State private var snap: SnapResolution` that
/// nothing else could see, and the roll read only the latter. Both rendered the
/// identical string `"SNAP: \(label)"`. Turning snap OFF therefore left the roll
/// on its own `.beat` default and the playhead kept rounding to whole beats —
/// which is exactly *"the start or end of the note grid"*.
///
/// The fix is a POLICY, not a conditional: `SnapResolution.effective` is the one
/// place that answers "which grid does the note editor apply", the way
/// `ClipSnap.effective(density:picked:)` already answers it for the arrange.
/// These tests pin the policy; `PianoRollSnapPolicySiteTests` pins the wiring
/// that feeds it, because a correct policy nothing calls is the defect this item
/// is about.
@Suite("m25-ab — SnapResolution.effective (the roll's ONE snap policy)")
struct PianoRollSnapPolicyTests {

    /// Every resolution the roll's picker offers, so the sweeps below are
    /// exhaustive by construction rather than by a hand-kept list.
    private static let allPicked = SnapResolution.allCases
    /// Every app-level snap the toolbar picker offers.
    private static let allApp = ClipSnap.allCases

    // MARK: - The pre-existing contract, unchanged

    @Test("Pro honours the roll's own pick while the app-level snap is on")
    func proHonoursThePick() {
        for picked in Self.allPicked {
            #expect(SnapResolution.effective(appSnap: .bar, density: .pro, picked: picked) == picked,
                    "Pro must pass the picked resolution through untouched (picked: \(picked))")
        }
    }

    @Test("Simple still locks the roll to whole beats while the app-level snap is on")
    func simpleLocksToBeat() {
        for picked in Self.allPicked {
            for app in Self.allApp where app != .off {
                #expect(SnapResolution.effective(appSnap: app, density: .simple, picked: picked) == .beat,
                        "Simple's beginner lock must survive (app: \(app), picked: \(picked))")
            }
        }
    }

    @Test("a non-off app snap never leaks its own RESOLUTION into the roll")
    func theRollKeepsItsOwnResolution() {
        // ⭐ THE POINT OF ROUTE ⓐ, PINNED. 16ths for notes while the arrange sits
        // on bars is a legitimate and useful independence — the toolbar's chosen
        // DIVISION must not follow the user into the note editor. Only OFF
        // crosses the boundary.
        #expect(SnapResolution.effective(appSnap: .bar, density: .pro, picked: .sixteenth) == .sixteenth)
        #expect(SnapResolution.effective(appSnap: .sixteenth, density: .pro, picked: .bar) == .bar)
        #expect(SnapResolution.effective(appSnap: .eighth, density: .pro, picked: .sixteenthTriplet)
                == .sixteenthTriplet)
    }

    // MARK: - The fix: global OFF wins

    @Test("⚠️ app-level OFF disables the roll's grid — the user's reported case")
    func appOffWinsInPro() {
        for picked in Self.allPicked {
            #expect(SnapResolution.effective(appSnap: .off, density: .pro, picked: picked) == .off,
                    "SNAP: OFF must mean off in the note editor too (picked: \(picked))")
        }
    }

    @Test("⚠️⚠️ app-level OFF beats Simple's beat lock — THIS IS THE DESIGN DECISION")
    func appOffWinsOverTheSimpleLock() {
        // ⭐ THE ORDERING IS DELIBERATE AND THIS TEST IS WHY IT IS NOT AN ACCIDENT.
        // Simple's `.beat` lock is beginner scaffolding; a VISIBLE chip reading
        // "SNAP: Off" that still snaps is the exact defect the user reported. The
        // roll's own picker is Pro-only, so in Simple the app-level chip is the
        // ONLY snap control on screen — letting the density override it would
        // leave a beginner with a control that does nothing.
        #expect(SnapResolution.effective(appSnap: .off, density: .simple, picked: .sixteenth) == .off)
        for picked in Self.allPicked {
            #expect(SnapResolution.effective(appSnap: .off, density: .simple, picked: picked) == .off,
                    "OFF is checked BEFORE the density lock (picked: \(picked))")
        }
    }

    @Test("the override never mutates the pick — flipping the app snap back restores it")
    func theOverrideIsNotDestructive() {
        // The `ClipSnap.effective` rule, inherited: this is a pure function of
        // three inputs, so the roll's picked resolution is still sitting there
        // untouched and returns the moment the app-level snap comes back on.
        let picked = SnapResolution.sixteenthTriplet
        #expect(SnapResolution.effective(appSnap: .off, density: .pro, picked: picked) == .off)
        #expect(SnapResolution.effective(appSnap: .bar, density: .pro, picked: picked) == picked)
    }

    @Test("OFF is the ONLY app-level value that crosses into the roll")
    func onlyOffCrosses() {
        // Negative control for the sweep above: if the override were written as
        // "app snap wins whenever it differs", this would fail.
        for app in Self.allApp where app != .off {
            #expect(SnapResolution.effective(appSnap: app, density: .pro, picked: .sixteenth) == .sixteenth,
                    "\(app) must not override the roll's pick — only OFF does")
        }
    }

    // MARK: - m23-ap I5 — the arithmetic's one home

    /// `PianoRollModel.snap(beat:resolution:)` now FORWARDS here (the pitch
    /// editor's placement has no roll model to ask). The literals are
    /// `PianoRollModelTests`' own snap literals, so the two cannot drift apart,
    /// plus the two the pitch editor's placement truth table leans on.
    @Test("m23-ap I5 — SnapResolution.snapped is the roll's rounding: nearest line, floored at 0, off passes through")
    func snappedIsTheOneRoundingRule() {
        #expect(SnapResolution.off.snapped(2.37) == 2.37)
        #expect(SnapResolution.off.snapped(-5) == 0)
        #expect(SnapResolution.bar.snapped(5.9) == 4)
        #expect(SnapResolution.bar.snapped(6.1) == 8)
        #expect(SnapResolution.beat.snapped(2.4) == 2)
        #expect(SnapResolution.sixteenth.snapped(2.37) == 2.25)
        #expect(SnapResolution.sixteenth.snapped(1.425) == 1.5)
        for resolution in Self.allPicked {
            #expect(resolution.snapped(-0.3) == 0, "\(resolution) must floor at 0")
            guard let grid = resolution.beats else { continue }
            let landed = resolution.snapped(3.337)
            #expect(abs((landed / grid).rounded() * grid - landed) < 1e-9,
                    "\(resolution): \(landed) is not on its own grid")
            #expect(abs(landed - 3.337) <= grid / 2 + 1e-9,
                    "\(resolution): \(landed) is not the NEAREST line to 3.337")
        }
    }

    // MARK: - The symptom, composed with the arithmetic that produced it

    @Test("⚠️ the playhead beat the user clicked survives the roll's snap math")
    @MainActor
    func placementBeatIsNoLongerRoundedToTheGrid() {
        let model = PianoRollModel(notes: [], clipLengthBeats: 16)
        let clicked = 2.37   // nothing near a grid line

        // BEFORE the fix the roll asked `.beat` here and the playhead landed on 2.0
        // — "the start or end of the note grid". Pinned as the thing that must not
        // come back.
        #expect(model.snap(beat: clicked, resolution: .beat) == 2.0,
                "positive control — `.beat` DOES round 2.37 to 2.0, so the assertion below is a real one")

        let effective = SnapResolution.effective(appSnap: .off, density: .pro, picked: .beat)
        #expect(model.snap(beat: clicked, resolution: effective) == clicked,
                "with SNAP: OFF the playhead must land where the user pointed")
    }

    @Test("with the app snap ON the roll still snaps the placement to ITS OWN grid")
    @MainActor
    func placementStillSnapsWhenTheAppSnapIsOn() {
        let model = PianoRollModel(notes: [], clipLengthBeats: 16)
        let effective = SnapResolution.effective(appSnap: .bar, density: .pro, picked: .sixteenth)
        #expect(effective == .sixteenth)
        // 2.37 → nearest 1/16 (0.25 beats) = 2.25, NOT the arrange's bar grid.
        #expect(model.snap(beat: 2.37, resolution: effective) == 2.25)
    }

    // MARK: - `.off` is now on the HIGHWAY, not a Pro-only back road

    /// ⚠️⚠️ **WHY THESE TWO EXIST, AND THEY ARE NOT ABOUT THE POLICY.**
    /// `.off` was always a legal resolution here — but it was reachable only from
    /// the roll's own Pro-gated picker, i.e. rare and deliberate. This item routes
    /// the MAIN toolbar chip into the same value, so every consumer of the roll's
    /// grid now meets `.off` on the common path. A consumer that used the
    /// resolution as a SIZE rather than as a rounding step would have no grid to
    /// use and no guard — a double-tap could add a zero-length note.
    ///
    /// **AUDITED, and both size-users are guarded** (`defaultLength` → 1 beat,
    /// `minResizeLength` → the store's own floor). These pin that, because the
    /// guards are what make the highway safe and nothing else was watching them.
    /// The rounding-step users (`snap`, `snapUp`, `ControllerLaneStrip`,
    /// `PianoRollGrid`'s `beats ?? 1`) are guarded at their own sites.
    @Test("⚠️ a note added with SNAP: OFF gets a real length, not a zero-width note")
    @MainActor
    func addWithSnapOffStillProducesARealNote() {
        let model = PianoRollModel(notes: [], clipLengthBeats: 16)
        let off = SnapResolution.effective(appSnap: .off, density: .pro, picked: .sixteenth)
        #expect(off == .off)
        #expect(model.defaultLength(for: off) == 1.0,
                "an OFF grid has no cell to size a new note by — the fallback is what stops a double-tap adding nothing")
        // Discriminator: a real grid DOES size the note by its cell, so the
        // assertion above is not just "some positive number".
        #expect(model.defaultLength(for: .sixteenth) == 0.25)
    }

    @Test("⚠️ a resize with SNAP: OFF floors at the store's minimum, not at a beat")
    @MainActor
    func resizeFloorWithSnapOffIsTheHonestOne() {
        let model = PianoRollModel(notes: [], clipLengthBeats: 16)
        let off = SnapResolution.effective(appSnap: .off, density: .pro, picked: .sixteenth)
        #expect(model.minResizeLength(for: off) == MIDINote.minLengthBeats,
                "snap off must expose the store's real floor (m21-c) — short AI-authored notes stay editable")
        #expect(MIDINote.minLengthBeats > 0,
                "positive control — a zero floor would make the assertion above vacuous")
        #expect(model.minResizeLength(for: .sixteenth) == 0.25)
    }
}
