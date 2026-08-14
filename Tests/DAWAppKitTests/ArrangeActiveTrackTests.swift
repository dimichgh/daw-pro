import Testing
import Foundation
import DAWCore
@testable import DAWAppKit

/// m25-l-1 — THE ACTIVE TRACK: an explicitly settable "where I am", and the
/// paste targeting that honours it.
///
/// The user's report (m25-l): *"copy/pasting to other track is also not working
/// — missing feature is user should be able to select a track which becomes
/// active for any implicit or explicit actions."*
///
/// The diagnosed chain was: a header click deliberately adopts no focus
/// (`ArrangeTrackSelection`, *"SELECTING IS NOT OPENING"*) → the paste target
/// was DERIVED from the focused clip's owner → so nothing selected meant no
/// target → `PasteAnchorPolicy` fell back to the first compatible track.
///
/// ═══ m25-l-3 (2026-08-13) — THE SECOND HALF, BY USER RULING ═══
///
/// m25-l-1 closed the RELOCATED case only, and this suite's banner used to warn
/// that the headline case was still open. **It is now closed.** The user
/// re-reported it after hands-on testing — *"when I copy clip and then select
/// track using header and try to paste using keyboard shortcut, it does not
/// copy on selected track, it still copies to the source track"* — which is the
/// word the m25-l-1 code was explicitly waiting for. An EXPLICIT destination
/// (header click) now overrides the in-place rule.
///
/// **THE THREE STATES, and all three are pinned below, because two of them are
/// pre-existing behaviour this change could have broken:**
///
///   1. `.explicit`  → redirects  (`explicitDestinationRedirectsAnInPlacePaste`)
///   2. `.inferred`  → unchanged  (`inferredDestinationDoesNotRedirectAnInPlacePaste`)
///   3. none         → unchanged  (`noDestinationLeavesAnInPlacePasteAlone`)
///
/// ⚠️ The distinction between 1 and 2 is the ONLY thing keeping this from being
/// a worse bug than the one it fixes: `resolve` answers non-nil for a merely
/// focused clip, which is nearly always.
@Suite("Arrange active track (m25-l-1, m25-l-3)")
struct ArrangeActiveTrackTests {

    // MARK: - Fixtures

    private func midiClip(_ name: String, start: Double = 0, length: Double = 4) -> Clip {
        Clip(name: name, startBeat: start, lengthBeats: length, notes: [])
    }

    private func audioClip(_ name: String, start: Double = 0, length: Double = 4) -> Clip {
        Clip(name: name, startBeat: start, lengthBeats: length,
             audioFileURL: URL(fileURLWithPath: "/tmp/\(name).wav"))
    }

    private func midiTrack(_ name: String, clips: [Clip] = []) -> Track {
        Track(name: name, kind: .instrument, clips: clips)
    }

    private func audioTrack(_ name: String, clips: [Clip] = []) -> Track {
        Track(name: name, kind: .audio, clips: clips)
    }

    private func entry(_ clip: Clip, track: Track, index: Int) -> ClipboardClip {
        ClipboardClip(clip: clip, sourceTrackID: track.id, sourceTrackIndex: index)
    }

    // MARK: - THE BUG, as a resolution failure

    /// ⭐ THE ITEM'S HEADLINE CASE, at the resolution layer: an EMPTY track can
    /// be the active track.
    ///
    /// This is the one a focus-derived target can never express. An empty track
    /// owns no clip, so no `focusID` can ever resolve to it — which is exactly
    /// why "you cannot paste onto an empty track" was true. The explicit term
    /// has no clip predicate, so it answers where the derived one structurally
    /// could not.
    @Test("an EMPTY track can be the active track — the case a focus can never name")
    func emptyTrackResolves() {
        let full = midiTrack("Keys", clips: [midiClip("a")])
        let empty = midiTrack("Empty")
        let resolved = ArrangeActiveTrack.resolve(
            explicit: empty.id, focusClipID: nil, tracks: [full, empty])
        #expect(resolved?.id == empty.id)
        #expect(resolved?.origin == .explicit)
    }

    /// The pre-m25-l-1 state of the world, kept as the contrast: with NO explicit
    /// term there is nothing to resolve, and this is the nil that sent a paste to
    /// the first compatible track.
    @Test("with no explicit track and no focus, there is no answer — the old fallback path")
    func nothingStatedResolvesToNil() {
        let full = midiTrack("Keys", clips: [midiClip("a")])
        let empty = midiTrack("Empty")
        #expect(ArrangeActiveTrack.resolve(
            explicit: nil, focusClipID: nil, tracks: [full, empty]) == nil)
    }

    // MARK: - Precedence: one home, two inputs

    @Test("an explicit track BEATS the focused clip's owner")
    func explicitBeatsFocus() {
        let a = midiClip("a")
        let one = midiTrack("One", clips: [a])
        let two = midiTrack("Two")
        let resolved = ArrangeActiveTrack.resolve(
            explicit: two.id, focusClipID: a.id, tracks: [one, two])
        #expect(resolved?.id == two.id)
        #expect(resolved?.origin == .explicit)
    }

    /// The SECOND precedence term, unchanged from before the item. Pinned so a
    /// future edit cannot quietly drop the behaviour every existing paste relies
    /// on while "adding" the explicit one.
    @Test("with no explicit track, the focused clip's OWNER answers — behaviour preserved")
    func focusStillResolvesWhenNothingExplicit() {
        let b = midiClip("b")
        let one = midiTrack("One", clips: [midiClip("a")])
        let two = midiTrack("Two", clips: [b])
        let resolved = ArrangeActiveTrack.resolve(
            explicit: nil, focusClipID: b.id, tracks: [one, two])
        #expect(resolved?.id == two.id)
        // ⭐ AND IT IS `.inferred` — nobody nominated this track, it is merely
        // where the focused clip lives. m25-l-3 turns on that word.
        #expect(resolved?.origin == .inferred)
    }

    /// ⭐ THE TWO-STEP SEQUENCE THAT MAKES THE RELEASE NECESSARY, at the layer
    /// this suite can reach.
    ///
    /// Click track A's header, then click a clip on track B. `AppModel.clickClip`
    /// RELEASES the explicit term precisely so this resolves to B — the pre-
    /// m25-l-1 answer. Had the explicit term stayed sticky, "where I am" would
    /// still be A: the rail would sit on A while the user works on B, and a
    /// relocated paste would follow it. **That would be a REGRESSION on an
    /// existing flow, not merely a missing feature.**
    ///
    /// ⚠️ The release itself is one line in `AppModel.clickClip` and is app-tier,
    /// so it is not reachable from `Tests/` (`DAWApp` has no test target); it is
    /// observable on `debug.arrangeSelection` as `explicitActiveTrackId`. What is
    /// pinned here is the resolution the release depends on.
    @Test("after a clip click releases the explicit term, the clicked clip's track answers")
    func releasedExplicitLetsTheClickedClipsTrackAnswer() {
        let trackA = midiTrack("A")
        let b = midiClip("b")
        let trackB = midiTrack("B", clips: [b])
        // Step 1 made trackA explicit; step 2 released it and focused b.
        let resolved = ArrangeActiveTrack.resolve(
            explicit: nil, focusClipID: b.id, tracks: [trackA, trackB])
        #expect(resolved?.id == trackB.id)
        #expect(resolved?.origin == .inferred)
        // And WITHOUT the release the cursor would have stayed on A — the
        // regression this pins, stated as the contrasting measurement.
        let sticky = ArrangeActiveTrack.resolve(
            explicit: trackA.id, focusClipID: b.id, tracks: [trackA, trackB])
        #expect(sticky?.id == trackA.id)
        #expect(sticky?.origin == .explicit)
    }

    // MARK: - Staleness is resolved, never invalidated

    /// ⚠️ Deleting the active track must not leave a dangling pointer. It is
    /// handled at READ time, which is why `removeTrack` gained no obligation.
    @Test("an explicit id naming a REMOVED track falls through to the focus term")
    func staleExplicitFallsThroughToFocus() {
        let b = midiClip("b")
        let two = midiTrack("Two", clips: [b])
        let removed = midiTrack("Deleted")
        let resolved = ArrangeActiveTrack.resolve(
            explicit: removed.id, focusClipID: b.id, tracks: [two])
        #expect(resolved?.id == two.id)
        // The dead explicit id did not merely lose — it left NO trace, so the
        // answer is honestly `.inferred` and cannot redirect a paste.
        #expect(resolved?.origin == .inferred)
    }

    @Test("a stale explicit id with no focus either resolves to nil, never to the dead id")
    func staleExplicitWithNoFocusIsNil() {
        let two = midiTrack("Two", clips: [midiClip("b")])
        let removed = midiTrack("Deleted")
        #expect(ArrangeActiveTrack.resolve(
            explicit: removed.id, focusClipID: nil, tracks: [two]) == nil)
    }

    @Test("a stale FOCUS id resolves to nil — the pre-existing rule, unchanged")
    func staleFocusIsNil() {
        let one = midiTrack("One", clips: [midiClip("a")])
        #expect(ArrangeActiveTrack.resolve(
            explicit: nil, focusClipID: UUID(), tracks: [one]) == nil)
    }

    @Test("no tracks at all resolves to nil however confidently the caller states a track")
    func emptyProjectIsNil() {
        #expect(ArrangeActiveTrack.resolve(
            explicit: UUID(), focusClipID: UUID(), tracks: []) == nil)
    }

    // MARK: - What a header click sets

    /// ⭐ EVERY header click names the cursor — the rule stated on
    /// `ArrangeTrackSelection.apply`, pinned across the whole chord table and
    /// both clip-count cases in one sweep.
    ///
    /// It matters that this is TOTAL. If a chord or an empty track were excluded
    /// there would be no way to make an empty track active, and the item's whole
    /// case would still be broken.
    ///
    /// ⛔ **AND SINCE m25-l-1 DEFECT ② THIS IS THE PIN FOR THE CONSTRAINT THAT MUST
    /// NOT BREAK.** A plain header click now selects nothing — its ONLY remaining
    /// job is naming the cursor, which is what paste-to-selected-track (m25-l-3,
    /// the user's own reported bug) resolves against. Degrade the plain branch to
    /// a true no-op and this test is the one that reddens. Passes UNCHANGED across
    /// the ruling, which is itself the evidence that the ruling touched only the
    /// selection half.
    @Test("every header click makes its track active — plain, ⇧, ⌘, populated and empty")
    func everyHeaderClickSetsTheCursor() {
        let populated = midiTrack("Full", clips: [midiClip("a"), midiClip("b", start: 8)])
        let empty = midiTrack("Empty")
        let chords: [ArrangeClickModifiers] = [[], .shift, .command, [.shift, .command]]
        for track in [populated, empty] {
            for mods in chords {
                var selection = ArrangeSelection()
                let outcome = ArrangeTrackSelection.apply(
                    click: track, modifiers: mods, to: &selection)
                #expect(outcome.activeTrackID == track.id)
            }
        }
    }

    /// A REPEATED click changes nothing about the selection and must still name
    /// the cursor — the `arrangeKeyFocusNonce` argument, applied to this field.
    @Test("a click that changes NOTHING still names the cursor")
    func noOpClickStillSetsTheCursor() {
        let track = midiTrack("Full", clips: [midiClip("a")])
        var selection = ArrangeSelection()
        ArrangeTrackSelection.apply(click: track, modifiers: [], to: &selection)
        let again = ArrangeTrackSelection.apply(click: track, modifiers: [], to: &selection)
        #expect(again.changedSelection == false)
        #expect(again.activeTrackID == track.id)
    }

    /// ⚠️ THE REGRESSION GUARD FOR `scripts/gates/m23y-track-select.mjs`' Y4 leg,
    /// and for `ArrangeTrackSelection`'s rewritten banner: naming a cursor must
    /// not leak into the SELECTION or the FOCUS.
    ///
    /// A plain click on a zero-clip track must still clear everything (which is
    /// what closes the piano roll) *while* establishing the active track. The
    /// two live side by side; that is the entire design.
    @Test("naming the cursor does NOT leak into selection or focus — the m23-y Y4 contract")
    func cursorDoesNotLeakIntoSelection() {
        let populated = midiTrack("Full", clips: [midiClip("a")])
        let empty = midiTrack("Empty")
        var selection = ArrangeSelection()
        // Arrange: a real selection with a focus, on the populated track.
        // (⚠️ Since m25-l-1 defect ② the plain click below contributes nothing to
        // the selection — `focus` is what establishes it. The click is kept
        // because the fixture is "a header was clicked AND a clip is focused",
        // which is the state the leak would show up in.)
        ArrangeTrackSelection.apply(click: populated, modifiers: [], to: &selection)
        selection.focus(populated.clips[0].id)
        #expect(selection.isEmpty == false)

        let outcome = ArrangeTrackSelection.apply(click: empty, modifiers: [], to: &selection)
        // The cursor moved…
        #expect(outcome.activeTrackID == empty.id)
        // …and the selection is EMPTY and the focus is NIL, exactly as before.
        #expect(selection.ids.isEmpty)
        #expect(selection.focusID == nil)
        // The clicked track contributed no ids — the cursor is not one of them.
        #expect(outcome.clipIDs.isEmpty)
    }

    /// ⚠️ The `.noClips` branch (m23-y Y4b, the vacuous-subset trap) is untouched
    /// by the cursor field. Pinned because the active-track work is the kind of
    /// change that invites "simplifying" the toggle branch on the way past.
    @Test("⇧ on a zero-clip track still reports .no-clips, and still names the cursor")
    func chordOnEmptyTrackKeepsItsEffect() {
        let empty = midiTrack("Empty")
        var selection = ArrangeSelection()
        let outcome = ArrangeTrackSelection.apply(
            click: empty, modifiers: .shift, to: &selection)
        #expect(outcome.effect == .noClips)
        #expect(outcome.changedSelection == false)
        #expect(outcome.activeTrackID == empty.id)
    }

    // MARK: - The paste, end to end through the real policy

    /// ⭐⭐ THE ACCEPTANCE TEST — a relocated paste lands on the EMPTY track the
    /// user made active, instead of on the first compatible track.
    ///
    /// ⚠️ THE FIXTURE DELETES A SOURCE TRACK, and at m25-l-1 that was not
    /// incidental — it was the ONLY way to reach `.relocated`. **Since m25-l-3
    /// an explicit destination reaches it too**, so this fixture is no longer
    /// the only route; it is kept exactly as it was because it pins the
    /// dead-source-track trigger specifically, which m25-l-3 did not touch.
    @Test("a relocated paste lands on the EMPTY active track, not the first compatible one")
    func relocatedPasteHonoursTheActiveTrack() {
        let first = midiTrack("First")
        let empty = midiTrack("Target")
        // The clip was copied from a track that has since been deleted — the
        // only way to reach `.relocated`.
        let goneTrack = midiTrack("Gone")
        let payload = [entry(midiClip("copied", start: 4), track: goneTrack, index: 0)]

        let target = ArrangeActiveTrack.resolve(
            explicit: empty.id, focusClipID: nil, tracks: [first, empty])
        let plan = PasteAnchorPolicy.resolveClipPaste(
            payload: payload, anchorBeat: 16, tracks: [first, empty],
            activeTrack: target)

        #expect(plan.mode == .relocated)
        #expect(plan.landings.count == 1)
        #expect(plan.landings.first?.targetTrackID == empty.id)
        #expect(plan.landings.first?.startBeat == 16)
    }

    /// THE SAME FIXTURE WITH NO ACTIVE TRACK — the bug, pinned. Without this the
    /// test above proves only that a paste lands somewhere plausible; with it,
    /// the two differ in exactly one input and land on different tracks.
    @Test("…and with NO active track the same paste lands on the FIRST compatible track")
    func withoutAnActiveTrackThePasteFallsBack() {
        let first = midiTrack("First")
        let empty = midiTrack("Target")
        let goneTrack = midiTrack("Gone")
        let payload = [entry(midiClip("copied", start: 4), track: goneTrack, index: 0)]

        let plan = PasteAnchorPolicy.resolveClipPaste(
            payload: payload, anchorBeat: 16, tracks: [first, empty],
            activeTrack: nil)

        #expect(plan.mode == .relocated)
        #expect(plan.landings.first?.targetTrackID == first.id)
    }

    /// An active track that cannot HOLD the payload is still the target, and the
    /// clip is skipped WITH A NAMED REASON rather than silently redirected.
    ///
    /// This pins the "do not add a `canHold` guard to `resolve`" decision: the
    /// honest outcome is a reported skip the app can put in the amber bubble,
    /// not a paste that quietly went somewhere the user did not point.
    @Test("an active track that can't hold the payload SKIPS with a reason, never redirects")
    func incompatibleActiveTrackSkipsHonestly() {
        let midi = midiTrack("Keys")
        let audio = audioTrack("Vox")
        let goneTrack = midiTrack("Gone")
        let payload = [entry(midiClip("copied"), track: goneTrack, index: 0)]

        let plan = PasteAnchorPolicy.resolveClipPaste(
            payload: payload, anchorBeat: 0, tracks: [midi, audio],
            activeTrack: .init(id: audio.id, origin: .explicit))

        #expect(plan.landings.isEmpty)
        #expect(plan.skipped.map(\.reason) == [.trackKindMismatch])
        #expect(plan.skipped.first?.clipName == "copied")
    }

    /// The multi-clip vertical geometry still rides the active track as its BASE,
    /// unchanged — the active track feeds the same `baseIndex` the focus term
    /// used to, so nothing about relocated layout changed shape.
    @Test("a two-track group keeps its vertical geometry, based on the active track")
    func relocatedGroupKeepsItsShapeFromTheActiveTrack() {
        let t0 = midiTrack("T0")
        let t1 = midiTrack("T1")
        let t2 = midiTrack("T2")
        let gone = midiTrack("Gone")
        let payload = [entry(midiClip("upper"), track: gone, index: 0),
                       entry(midiClip("lower"), track: gone, index: 1)]

        let plan = PasteAnchorPolicy.resolveClipPaste(
            payload: payload, anchorBeat: 0, tracks: [t0, t1, t2],
            activeTrack: .init(id: t1.id, origin: .inferred))

        #expect(plan.mode == .relocated)
        // Based at t1, the group keeps its 1-track internal offset: t1 then t2.
        #expect(plan.landings.map(\.targetTrackID) == [t1.id, t2.id])
    }

    // MARK: - ⚠️ THE INFERRED HALF — the boundary that SURVIVED m25-l-3

    /// ⭐⭐ **THIS TEST WAS THE SCOPE BOUNDARY AND IS NOW HALF THE RULE. READ THE
    /// HISTORY BEFORE CHANGING IT.**
    ///
    /// It shipped at m25-l-1 asserting that NO active track redirects an
    /// in-place paste, and its banner said that changing that *"needs the user's
    /// word"*. **On 2026-08-13 the user gave that word** — they performed the
    /// gesture and called the behaviour wrong: *"when I copy clip and then
    /// select track using header and try to paste using keyboard shortcut, it
    /// does not copy on selected track, it still copies to the source track."*
    /// m25-l-3 is that ruling; `explicitDestinationRedirectsAnInPlacePaste`
    /// below is its acceptance test.
    ///
    /// **What is pinned HERE is the half that deliberately did NOT change**, and
    /// it is load-bearing rather than a leftover. `ArrangeActiveTrack.resolve`
    /// answers non-nil for a merely FOCUSED clip, which is nearly always — so a
    /// redirect keyed on "is there an active track" instead of "did the user
    /// choose one" would relocate EVERY ordinary paste and fold multi-track
    /// copies onto one track through the index clamp. That is a worse bug than
    /// the one m25-l-3 fixes, and this test is what makes it fail loudly.
    ///
    /// ⚠️ THE FIXTURE IS A REAL GESTURE, not a contrivance: copy a clip on
    /// "Source", then click a CLIP on the other track (which `AppModel.clickClip`
    /// releases the explicit term for, leaving an `.inferred` destination), then
    /// paste. It still lands home.
    @Test("an INFERRED destination does NOT redirect an in-place paste — unchanged by m25-l-3")
    func inferredDestinationDoesNotRedirectAnInPlacePaste() {
        let source = midiTrack("Source", clips: [midiClip("a")])
        let other = midiClip("theirs")
        let wanted = midiTrack("Where a clip is focused", clips: [other])
        // A copy from a LIVE track — which is what the clipboard always stamps.
        let payload = [entry(midiClip("copied"), track: source, index: 0)]

        // Resolved through the REAL rule with no explicit term, so the
        // `.inferred` origin is produced rather than asserted into existence.
        let destination = ArrangeActiveTrack.resolve(
            explicit: nil, focusClipID: other.id, tracks: [source, wanted])
        #expect(destination?.origin == .inferred)

        let plan = PasteAnchorPolicy.resolveClipPaste(
            payload: payload, anchorBeat: 8, tracks: [source, wanted],
            activeTrack: destination)

        // The mode is in-place BECAUSE the source track is alive and nobody
        // pointed anywhere…
        #expect(plan.mode == .inPlace)
        // …and the paste therefore lands on the SOURCE, not where the focus is.
        #expect(plan.landings.first?.targetTrackID == source.id)
        #expect(plan.landings.first?.targetTrackID != wanted.id)
    }

    /// The same boundary from the other side: an AUDIO in-place paste ignores an
    /// inferred destination too, so the rule is a property of the MODE and the
    /// ORIGIN, never of clip kind.
    @Test("the inferred rule is about the MODE and the ORIGIN, not the clip kind")
    func inPlaceIgnoresAnInferredCursorForAudioToo() {
        let source = audioTrack("Source")
        let wanted = audioTrack("Where a clip is focused")
        let payload = [entry(audioClip("copied"), track: source, index: 0)]

        let plan = PasteAnchorPolicy.resolveClipPaste(
            payload: payload, anchorBeat: 0, tracks: [source, wanted],
            activeTrack: .init(id: wanted.id, origin: .inferred))

        #expect(plan.mode == .inPlace)
        #expect(plan.landings.first?.targetTrackID == source.id)
    }

    // MARK: - ⭐⭐ m25-l-3 — AN EXPLICIT CHOICE OVERRIDES THE IN-PLACE RULE

    /// ⭐⭐⭐ **THE ACCEPTANCE TEST FOR THE USER'S TWICE-REPORTED BUG.**
    ///
    /// Their gesture, exactly: copy a clip from a LIVE track, click ANOTHER
    /// track's header, press ⌘V. Every source track is still alive, so this is
    /// the case that used to be `.inPlace` and land back on "Source". Under the
    /// 2026-08-13 ruling the explicit choice wins.
    ///
    /// ⚠️ THE DESTINATION IS PRODUCED BY THE REAL RESOLUTION RULE, not
    /// hand-built: `resolve(explicit: wanted.id, …)` is what a header click
    /// feeds, so this test fails if the provenance is lost anywhere between the
    /// click and the policy — which is precisely the defect being fixed.
    @Test("m25-l-3: an EXPLICIT destination redirects an in-place paste to the chosen track")
    func explicitDestinationRedirectsAnInPlacePaste() {
        let source = midiTrack("Source", clips: [midiClip("a")])
        let wanted = midiTrack("Where I clicked")
        let payload = [entry(midiClip("copied"), track: source, index: 0)]

        let destination = ArrangeActiveTrack.resolve(
            explicit: wanted.id, focusClipID: nil, tracks: [source, wanted])
        #expect(destination?.origin == .explicit)

        let plan = PasteAnchorPolicy.resolveClipPaste(
            payload: payload, anchorBeat: 8, tracks: [source, wanted],
            activeTrack: destination)

        // The rule that ran is the relocation arithmetic — reached here by the
        // CHOICE rather than by a dead source track.
        #expect(plan.mode == .relocated)
        #expect(plan.landings.count == 1)
        #expect(plan.landings.first?.targetTrackID == wanted.id)
        // The time anchor is untouched by the redirect: still the playhead.
        #expect(plan.landings.first?.startBeat == 8)
    }

    /// ⚠️ THE MINIMAL PAIR that makes the test above mean something. Same
    /// fixture, same payload, ONE input different — the origin — and the clip
    /// lands on a different track. Without this, "it landed on `wanted`" could
    /// be explained by any number of accidents.
    @Test("m25-l-3 MINIMAL PAIR: only the ORIGIN differs, and the landing track differs")
    func originAloneDecidesTheLandingTrack() {
        let source = midiTrack("Source")
        let wanted = midiTrack("Where I clicked")
        let payload = [entry(midiClip("copied"), track: source, index: 0)]
        let tracks = [source, wanted]

        let asExplicit = PasteAnchorPolicy.resolveClipPaste(
            payload: payload, anchorBeat: 0, tracks: tracks,
            activeTrack: .init(id: wanted.id, origin: .explicit))
        let asInferred = PasteAnchorPolicy.resolveClipPaste(
            payload: payload, anchorBeat: 0, tracks: tracks,
            activeTrack: .init(id: wanted.id, origin: .inferred))

        #expect(asExplicit.landings.first?.targetTrackID == wanted.id)
        #expect(asInferred.landings.first?.targetTrackID == source.id)
        #expect(asExplicit.mode == .relocated)
        #expect(asInferred.mode == .inPlace)
    }

    /// A THIRD input state, pinned because it is the one an implementation is
    /// most likely to break while "simplifying": NO destination at all still
    /// pastes in place. `?? false` on the origin test, not `?? true`.
    @Test("m25-l-3: NO destination leaves an in-place paste alone")
    func noDestinationLeavesAnInPlacePasteAlone() {
        let source = midiTrack("Source")
        let other = midiTrack("Other")
        let payload = [entry(midiClip("copied"), track: source, index: 0)]

        let plan = PasteAnchorPolicy.resolveClipPaste(
            payload: payload, anchorBeat: 4, tracks: [source, other], activeTrack: nil)

        #expect(plan.mode == .inPlace)
        #expect(plan.landings.first?.targetTrackID == source.id)
    }

    /// ⚠️ **A STALE EXPLICIT DESTINATION MUST DEGRADE TO IN-PLACE, NEVER RELOCATE
    /// TO THE FALLBACK.** `resolve` cannot produce one against the same track
    /// list, but `resolveClipPaste` takes `tracks` as a SEPARATE argument, so the
    /// state is representable and its behaviour is therefore a defined property
    /// rather than an accident of the caller (the rule this file's banner states
    /// for the negative anchor).
    ///
    /// Getting this wrong is not cosmetic: relocating on a dead destination would
    /// send the paste to "the first track in store order that can hold the
    /// payload's topmost clip", i.e. somewhere the user never pointed, on a
    /// gesture that used to land home.
    @Test("m25-l-3: an explicit destination naming a REMOVED track falls back to in-place")
    func staleExplicitDestinationFallsBackToInPlace() {
        let source = midiTrack("Source")
        let alsoLive = midiTrack("Also live")
        let removed = midiTrack("Deleted")
        let payload = [entry(midiClip("copied"), track: source, index: 0)]

        let plan = PasteAnchorPolicy.resolveClipPaste(
            payload: payload, anchorBeat: 0, tracks: [alsoLive, source],
            activeTrack: .init(id: removed.id, origin: .explicit))

        #expect(plan.mode == .inPlace)
        #expect(plan.landings.first?.targetTrackID == source.id)
        // The anti-vacuity control: had it relocated, the fallback base would be
        // index 0 — a DIFFERENT track — so this assertion can actually fail.
        #expect(plan.landings.first?.targetTrackID != alsoLive.id)
    }

    /// ⭐ A MULTI-TRACK copy redirected by an explicit choice keeps its vertical
    /// geometry RIGID, through the same offset arithmetic the relocated path has
    /// always used. No second relocation path was written for the override.
    @Test("m25-l-3: a two-track live copy keeps its shape when redirected")
    func explicitRedirectKeepsMultiTrackGeometry() {
        let s0 = midiTrack("S0")
        let s1 = midiTrack("S1")
        let d0 = midiTrack("D0")
        let d1 = midiTrack("D1")
        let payload = [entry(midiClip("upper"), track: s0, index: 0),
                       entry(midiClip("lower"), track: s1, index: 1)]

        let plan = PasteAnchorPolicy.resolveClipPaste(
            payload: payload, anchorBeat: 0, tracks: [s0, s1, d0, d1],
            activeTrack: .init(id: d0.id, origin: .explicit))

        #expect(plan.mode == .relocated)
        // Based at d0, the pair keeps its 1-track internal offset: d0 then d1.
        #expect(plan.landings.map(\.targetTrackID) == [d0.id, d1.id])
        #expect(plan.skipped.isEmpty)
    }

    /// ⚠️⚠️ **A NEWLY REACHABLE SKIP, AND THE HONEST COST OF THE RULING.** The
    /// relocated path's index clamp can fold two source tracks onto one target,
    /// which `overlapsPastedSibling` reports. Before m25-l-3 that was unreachable
    /// for a copy whose source tracks were all alive (such a paste was always
    /// `.inPlace`, and in-place cannot fold — each clip goes to its own distinct
    /// live track). Now a user can reach it with no deleted track at all, simply
    /// by pasting a two-track group onto the LAST track.
    ///
    /// Pinned as a NAMED skip rather than a silent stack, because two pasted
    /// clips overlapping silently is the +6 dB defect m11-d/m13-b exist to
    /// prevent and `resolvingOverlaps` cannot catch it (both are claimants).
    @Test("m25-l-3: redirecting a two-track copy onto the LAST track folds and skips honestly")
    func explicitRedirectOntoTheLastTrackFoldsAndReportsIt() {
        let s0 = midiTrack("S0")
        let s1 = midiTrack("S1")
        let last = midiTrack("Last")
        // Overlapping windows once folded: 0…4 and 2…6.
        let payload = [entry(midiClip("upper", start: 0, length: 4), track: s0, index: 0),
                       entry(midiClip("lower", start: 2, length: 4), track: s1, index: 1)]

        let plan = PasteAnchorPolicy.resolveClipPaste(
            payload: payload, anchorBeat: 0, tracks: [s0, s1, last],
            activeTrack: .init(id: last.id, origin: .explicit))

        #expect(plan.mode == .relocated)
        #expect(plan.landings.count == 1)
        #expect(plan.landings.first?.targetTrackID == last.id)
        #expect(plan.skipped.map(\.reason) == [.overlapsPastedSibling])
        #expect(plan.skipped.first?.clipName == "lower")
    }

    /// ⚠️ **A BEHAVIOUR CHANGE ON A PREVIOUSLY-WORKING FLOW, STATED AS A TEST
    /// RATHER THAN LEFT TO BE DISCOVERED.** Copy a MIDI clip, click an AUDIO
    /// track's header, paste: this used to land home in place, and now refuses
    /// with a named skip.
    ///
    /// That is the correct reading of the ruling — the user pointed at a track
    /// that cannot hold the clip, and `incompatibleActiveTrackSkipsHonestly`
    /// already establishes that the honest answer is a REPORTED skip rather than
    /// a silent redirect to somewhere they did not point. It is nonetheless a
    /// regression in the narrow sense that a gesture which used to place a clip
    /// now places none, so it is pinned where a reviewer will see it.
    @Test("m25-l-3: an explicit destination that CAN'T HOLD the clip skips — was land-home")
    func explicitRedirectToAnIncompatibleTrackSkipsHonestly() {
        let source = midiTrack("Source")
        let audio = audioTrack("Vox")
        let payload = [entry(midiClip("copied"), track: source, index: 0)]

        let plan = PasteAnchorPolicy.resolveClipPaste(
            payload: payload, anchorBeat: 0, tracks: [source, audio],
            activeTrack: .init(id: audio.id, origin: .explicit))

        #expect(plan.mode == .relocated)
        #expect(plan.landings.isEmpty)
        #expect(plan.skipped.map(\.reason) == [.trackKindMismatch])
        #expect(plan.skipped.first?.clipName == "copied")
    }

    /// Redirecting onto the track the clip CAME FROM is a legal no-op in space:
    /// the relocation arithmetic bases on that same track and offset 0, so the
    /// landing is identical to what in-place would have produced. Pinned so the
    /// override cannot be "optimised" into a special case that behaves
    /// differently from the general one.
    @Test("m25-l-3: explicitly choosing the SOURCE track lands exactly where in-place would")
    func explicitRedirectToTheSourceTrackIsANoOpInSpace() {
        let source = midiTrack("Source")
        let other = midiTrack("Other")
        let payload = [entry(midiClip("copied", start: 12), track: source, index: 0)]

        let redirected = PasteAnchorPolicy.resolveClipPaste(
            payload: payload, anchorBeat: 6, tracks: [source, other],
            activeTrack: .init(id: source.id, origin: .explicit))
        let inPlace = PasteAnchorPolicy.resolveClipPaste(
            payload: payload, anchorBeat: 6, tracks: [source, other], activeTrack: nil)

        #expect(redirected.mode == .relocated)
        #expect(inPlace.mode == .inPlace)
        #expect(redirected.landings.map(\.targetTrackID) == inPlace.landings.map(\.targetTrackID))
        #expect(redirected.landings.map(\.startBeat) == inPlace.landings.map(\.startBeat))
    }
}
