import Foundation
import Testing
import DAWCore
@testable import DAWAppKit

/// Headless coverage for the empty-instrument-lane hint (m23-v) — the VISIBLE
/// half of m23-e's empty-lane double-click.
///
/// WHAT THIS SUITE PROVES AND WHAT IT CANNOT
///   Proves: the RULE and the WORDS. Which lanes earn a hint, that it survives a
///   clip appearing and coming back, ladder order, and the exact string.
///   Does NOT prove: that anything is drawn. `DAWApp` has no test target, so the
///   view that composes this into pixels is unreachable from here — m23-m3b
///   measured exactly that (a mutant breaking a `DAWApp`-only binding left the
///   whole Swift suite green at 3979 tests / 405 suites). "The hint is on
///   screen, at a visible ink" is the staging gate's `debug.captureUI` leg
///   (`scripts/gates/m23v-empty-lane-hint.mjs`), and "the drawing view is the
///   one that reported it" is the echo leg there. A green run HERE plus a green
///   echo is NOT sufficient evidence the feature exists; the pixel leg is.
@Suite("Arrange empty-lane hint (m23-v)")
struct ArrangeEmptyLaneHintTests {

    private func track(_ name: String, _ kind: TrackKind, clips: [Clip] = []) -> Track {
        Track(name: name, kind: kind, clips: clips)
    }

    private func midiClip(at beat: Double = 0) -> Clip {
        Clip(name: "Part", startBeat: beat, lengthBeats: 4, notes: [])
    }

    // MARK: - Eligibility

    @Test("an instrument track with zero clips gets the hint")
    func emptyInstrumentGetsHint() {
        let t = track("Lead", .instrument)
        let hint = ArrangeEmptyLaneHints.hint(for: t, laneIndex: 0)
        #expect(hint != nil)
        #expect(hint?.trackID == t.id)
        #expect(hint?.laneIndex == 0)
        #expect(hint?.text == ArrangeEmptyLaneHints.copy)
    }

    @Test("one clip anywhere on the lane silences it — and removing that clip brings it back")
    func clipSuppressesAndRemovalRestores() {
        var t = track("Lead", .instrument)
        #expect(ArrangeEmptyLaneHints.hint(for: t, laneIndex: 0) != nil)

        t.clips = [midiClip()]
        #expect(ArrangeEmptyLaneHints.hint(for: t, laneIndex: 0) == nil)

        t.clips = []
        #expect(ArrangeEmptyLaneHints.hint(for: t, laneIndex: 0) != nil,
                "the empty state is a state, not a one-shot first-run flag")
    }

    @Test("ANY clip counts — not 'no clip in the visible window'")
    func anyClipAnywhereCounts() {
        // A clip parked 500 beats out is off screen at every zoom the app allows,
        // and the lane still has content. A viewport-relative rule would flicker
        // the hint on and off as the user scrolled, which is why the predicate
        // reads `clips.isEmpty` and nothing about geometry.
        var t = track("Lead", .instrument)
        t.clips = [midiClip(at: 500)]
        #expect(ArrangeEmptyLaneHints.hint(for: t, laneIndex: 0) == nil)
    }

    @Test("never on audio or bus lanes — empty or not")
    func neverOnNonInstrumentLanes() {
        for kind in [TrackKind.audio, .bus] {
            let empty = track("T", kind)
            #expect(ArrangeEmptyLaneHints.hint(for: empty, laneIndex: 0) == nil,
                    "\(kind) lane REFUSES the double-click (midiClipsRequireInstrumentTrack), so advertising it would be worse than silence")
            var filled = track("T", kind)
            filled.clips = [midiClip()]
            #expect(ArrangeEmptyLaneHints.hint(for: filled, laneIndex: 0) == nil)
        }
    }

    @Test("eligibility is Track.canHoldMIDIClips — the store's own guard, over every kind")
    func eligibilityIsTheStoreGuard() {
        // The DISCRIMINATING form: asserting `canHoldMIDIClips` alone would not
        // show the hint CONSULTS it. This walks every kind and requires the two
        // to agree on an empty lane, so a hint that hardcoded `.instrument`
        // locally would still pass — but a hint keyed on a DIFFERENT rule (say
        // `canExportMIDI`, or `kind != .bus`) fails the moment either diverges.
        for kind in TrackKind.allCases {
            let t = track("T", kind)
            let hinted = ArrangeEmptyLaneHints.hint(for: t, laneIndex: 0) != nil
            #expect(hinted == t.canHoldMIDIClips,
                    "\(kind): hint=\(hinted) canHoldMIDIClips=\(t.canHoldMIDIClips)")
        }
    }

    @Test("the rule reads NOTHING but the tracks — no transport in scope")
    func contentKeyedOnly() {
        // A track added while the transport is rolling or recording still has no
        // clips and still looks inert, so it still gets the hint. This is proven
        // structurally rather than by a flag sweep: `hints(for:)` takes `[Track]`
        // and nothing else, so there is no transport state it COULD read. This
        // test's job is to fail loudly if that signature ever grows one.
        var armedRolling = track("Live", .instrument)
        armedRolling.isArmed = true
        #expect(ArrangeEmptyLaneHints.hints(for: [armedRolling]).count == 1)
        var muted = track("Muted", .instrument)
        muted.isMuted = true
        #expect(ArrangeEmptyLaneHints.hints(for: [muted]).count == 1)
    }

    // MARK: - The ladder

    @Test("hints come back in ladder order, carrying each track's lane index")
    func ladderOrderAndIndices() {
        var withClip = track("Has A Part", .instrument)
        withClip.clips = [midiClip()]
        let tracks = [
            track("Empty A", .instrument),      // 0 — hint
            track("Vox", .audio),               // 1 — never
            withClip,                           // 2 — silenced
            track("Reverb Bus", .bus),          // 3 — never
            track("Empty B", .instrument),      // 4 — hint
        ]
        let hints = ArrangeEmptyLaneHints.hints(for: tracks)
        #expect(hints.count == 2)
        #expect(hints.map(\.laneIndex) == [0, 4],
                "laneIndex is the position in the ladder the view lays out, NOT the position in the hint array — the drawing view offsets by laneTop(index)")
        #expect(hints.map(\.trackID) == [tracks[0].id, tracks[4].id])
    }

    @Test("no tracks, and no eligible tracks, both give an empty set (not a placeholder)")
    func emptySets() {
        #expect(ArrangeEmptyLaneHints.hints(for: []).isEmpty)
        #expect(ArrangeEmptyLaneHints.hints(for: [track("Vox", .audio),
                                                 track("Bus", .bus)]).isEmpty)
    }

    // MARK: - Copy

    @Test("the copy is the pinned string — a change here must be deliberate")
    func copyIsPinned() {
        #expect(ArrangeEmptyLaneHints.copy == "Double-click to add a clip")
    }

    @Test("the copy reads for a beginner: plain, short, no jargon, no shouting")
    func copyStyle() {
        let copy = ArrangeEmptyLaneHints.copy
        #expect(!copy.isEmpty)
        // It sits on EVERY empty instrument lane at once, so length is a design
        // constraint, not taste: at the S row height and a narrow window several
        // of these are on screen together.
        #expect(copy.count <= 32, "too long for a lane label: \(copy.count)")
        #expect(!copy.contains("!"), "a quiet invitation, never a call to action")
        #expect(copy == copy.trimmingCharacters(in: .whitespacesAndNewlines))
        // The same banned-unit rule the Explain catalogue enforces — a hint is
        // the first words a new user reads on an empty project.
        for jargon in ["MIDI", "dB", "Hz", "ms", "clip region", "instantiate"] {
            #expect(!copy.contains(jargon), "hint copy uses jargon: \(jargon)")
        }
        // It names the GESTURE, which is the entire point of the item: the
        // mechanism m23-e shipped is invisible until something says it out loud.
        #expect(copy.lowercased().contains("double-click"))
    }

    @Test("the Explain card that teaches this gesture still teaches it")
    func explainCardStillCoversTheGesture() {
        // The hint carries no ExplainID of its own, deliberately: it must not
        // hit-test (a hit-testable label would swallow the double-click it
        // advertises), so a card of its own could never be hovered — and the
        // catalogue forbids two entries with near-identical copy. Its card is
        // `.arrangePlayhead`, anchored on the pointer surface the hint sits over.
        // Pinned here so deleting that sentence from the card fails loudly
        // instead of quietly stranding the hint without an explanation.
        let body = ExplainCatalog.entry(for: .arrangePlayhead)?.body ?? ""
        #expect(body.contains("Double-click empty space on an instrument track"))
        #expect(body.contains("note editor"))
    }

    // MARK: - The value seam

    @Test("a hint can only be MINTED by the resolver — the drawn value is the reported value")
    func hintsAreResolverOnly() {
        // `ArrangeEmptyLaneHint.init` is fileprivate (the `ResolvedDropBeat`
        // pattern), so `hints(for:)` is the only producer in the program. That is
        // what makes "the view draws and reports ONE value" a compile-time
        // property: no call site — view, AppModel, or debug seam — can fabricate
        // a hint to report for pixels it never drew. This test documents the
        // guarantee; the COMPILER enforces it (adding a public init would not
        // fail here, it would fail review — and the echo gate would still catch
        // a fabricated report, because the fabricator would have to live in the
        // drawing layer to be reported at all).
        let lead = track("Lead", .instrument)
        let hints = ArrangeEmptyLaneHints.hints(for: [lead])
        #expect(hints.count == 1)
        #expect(hints[0] == ArrangeEmptyLaneHints.hint(for: lead, laneIndex: 0),
                "the batch resolver and the single-track resolver are ONE rule")
        // Equatable/Identifiable are load-bearing: the view's `.onChange(of:)`
        // reporter and its `ForEach` both depend on them. A hint compares equal
        // only to the same track at the same lane index with the same words, so
        // reordering tracks re-fires the report.
        #expect(hints[0].id == hints[0].trackID)
        #expect(hints[0] != ArrangeEmptyLaneHints.hint(for: lead, laneIndex: 3))
    }
}
