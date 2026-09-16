import Foundation
import Testing
@testable import DAWAppKit

/// m35-h — the roll must not open on an EMPTY GRID for a clip written low.
///
/// The RULES half (pure policy) plus, at the bottom, the SOURCE-SHAPE half: the
/// `PianoRollMinimapSiteTests` idiom, because `DAWApp` has no test target and a
/// perfect policy can sit beside a view that never calls it.
@Suite("Piano roll — open focus on the clip's own pitch range (m35-h)")
struct PianoRollOpenFocusTests {

    // A believable default: ~560 pt of grid at the 14 pt default row height, so
    // 40 rows are visible. Written as a helper rather than as a literal range so
    // the strip inset is exercised by every case, not just by its own test.
    private static func window(scrollY: CGFloat = 0,
                               viewportHeight: CGFloat = 560,
                               rowHeight: CGFloat = 14) -> ClosedRange<Int>? {
        PianoRollOpenFocus.visiblePitchWindow(scrollY: scrollY,
                                              viewportHeight: viewportHeight,
                                              topInset: 18,
                                              rowHeight: rowHeight)
    }

    // MARK: - The window

    @Test("The window excludes the row hidden under the frozen scrub strip")
    func stripCoveredRowIsNotInFrame() throws {
        // Scrolled to the very top: row 0 (pitch 127) spans y 0...14 and the strip
        // covers y 0...18, so pitch 127 is NOT readable — and 126 (14...28) is only
        // partly clear, so the first FULLY visible pitch is 125 (28...42).
        let w = try #require(Self.window())
        #expect(w.upperBound == 125)

        // ⚠️ THE POINT OF THIS TEST: `PianoRollView.visiblePitchWindow` — the OTHER
        // window on this surface — would answer 127 here, because it measures
        // against the raw scroller height. Its doc calls that error safe, and for
        // the paste nudge it bounds it is. For m35-h it is the bug: a note under the
        // strip counted as in-frame suppresses the scroll and the user looks at an
        // invisible note. Pinned as a NUMBER so a future "tidy" that reuses the
        // other window fails here.
        #expect(w.upperBound != 127)

        // The bottom edge is strict too: 560 / 14 = 40 whole rows from the top, so
        // the last fully visible row is index 39 = pitch 88.
        #expect(w.lowerBound == 88)
    }

    @Test("A box too short for one whole row has no window")
    func degenerateViewportHasNoWindow() {
        #expect(Self.window(viewportHeight: 20) == nil)          // 20 − 18 < 14
        #expect(Self.window(viewportHeight: 0) == nil)
        #expect(PianoRollOpenFocus.visiblePitchWindow(scrollY: 0, viewportHeight: 560,
                                                      topInset: 18, rowHeight: 0) == nil)
    }

    // MARK: - Do nothing

    @Test("An EMPTY clip leaves the anchor alone")
    func emptyClipDoesNotScroll() {
        // ⭐ STATED, NOT FALLEN OUT OF THE CODE: there is no range to centre on, so
        // the roll's default `.center` anchor (near middle C) stands — which is
        // where a user about to draw wants to start.
        #expect(PianoRollOpenFocus.focusPitch(notePitches: [], visible: Self.window()) == nil)
    }

    @Test("No window (not laid out yet) means no decision")
    func noWindowMeansNoScroll() {
        #expect(PianoRollOpenFocus.focusPitch(notePitches: [24, 25], visible: nil) == nil)
    }

    @Test("Notes already in frame are never yanked")
    func alreadyInFrameDoesNotScroll() throws {
        let w = try #require(Self.window())   // 88...125
        #expect(PianoRollOpenFocus.focusPitch(notePitches: [90, 100, 110], visible: w) == nil)
        // Both edges exactly on the boundary still counts as in frame.
        #expect(PianoRollOpenFocus.focusPitch(notePitches: [88, 125], visible: w) == nil)
    }

    // MARK: - Ranges that FIT → midpoint, so every note lands

    @Test("A LOW clip (C1 sub, F1 808) is centred — the reported defect")
    func lowClipIsCentred() throws {
        // The roll opens near middle C; measured, a clip at MIDI 24/29 sits below
        // the viewport with its notes visible only in the minimap and velocity lane.
        let openWindow = try #require(Self.window(scrollY: 128 * 14 / 2 - 280))
        #expect(!openWindow.contains(24))
        #expect(PianoRollOpenFocus.focusPitch(notePitches: [24, 29, 24, 36],
                                              visible: openWindow) == 30)   // (24 + 36) / 2
    }

    @Test("A HIGH clip is centred too — the direction discriminator")
    func highClipIsCentred() throws {
        // ⚠️ This is the case that catches an in-frame test computed against a
        // stale scroll offset of 0: such a window claims the TOP of the stack, so a
        // C7+ clip would read as already-in-frame and the fix would silently apply
        // to low clips only.
        let w = try #require(Self.window())   // 88...125, i.e. scrolled to the top
        #expect(PianoRollOpenFocus.focusPitch(notePitches: [50, 60], visible: w) == 55)
    }

    @Test("A range only PARTLY in frame still scrolls")
    func partialOverlapScrolls() throws {
        let w = try #require(Self.window())   // 88...125
        #expect(PianoRollOpenFocus.focusPitch(notePitches: [80, 100], visible: w) == 90)
    }

    // MARK: - Ranges too WIDE to fit → the median NOTE

    @Test("A wide clip lands on the music, not on the empty middle")
    func wideRangeCentresOnMedianNotMidpoint() throws {
        // A bass part at C1...G1 with a handful of high ornaments: span 41 rows at a
        // 40-row window, so nothing can frame it all.
        let pitches = [24, 26, 24, 27, 31, 25, 29, 24, 60, 62, 64]
        let w = try #require(Self.window())
        let target = try #require(PianoRollOpenFocus.focusPitch(notePitches: pitches, visible: w))

        // ⭐ THE WIDE-RANGE CHOICE, MADE VISIBLE. The midpoint of the EXTREMES is
        // (24 + 64) / 2 = 44 — a region of this clip containing NO NOTES AT ALL,
        // i.e. the blank grid reproduced by the fix meant to cure it.
        #expect(target != 44)
        // The median is an ACTUAL ELEMENT of the sorted list, so a real note sits on
        // the centre row and the grid can never open blank.
        #expect(target == 27)
        #expect(pitches.contains(target))
    }

    @Test("A wide clip whose median is already in frame does not move")
    func wideRangeWithVisibleMedianDoesNotScroll() throws {
        let pitches = [30, 95, 100, 100, 105, 110, 120]   // span 91 rows, median 100
        let w = try #require(Self.window())                   // 88...125
        #expect(PianoRollOpenFocus.focusPitch(notePitches: pitches, visible: w) == nil)
        // ⚠️ And the deliberate consequence, stated as a test rather than left to
        // taste: the low outlier at 30 stays off screen. "Already fine" means the
        // MUSIC is in frame, not that every pixel of it is.
        #expect(!w.contains(30))
    }

    @Test("Duplicates weight the median toward the dense region")
    func medianFollowsNoteDensity() throws {
        // Same extremes, opposite mass: the target must follow the notes.
        let w = try #require(Self.window())
        let lowHeavy = Array(repeating: 24, count: 9) + [26, 100, 101]
        let highHeavy = [24, 26] + Array(repeating: 100, count: 9) + [101]
        #expect(PianoRollOpenFocus.focusPitch(notePitches: lowHeavy, visible: w) == 24)
        #expect(PianoRollOpenFocus.focusPitch(notePitches: highHeavy, visible: w) == nil)  // 100 is in frame
    }

    // MARK: - The wiring (source shape — `DAWApp` has no test target)

    private static func sourcesDir() -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fm = FileManager.default
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent("Sources", isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        Issue.record("Could not locate Sources from \(#filePath)")
        return URL(fileURLWithPath: "/nonexistent")
    }

    /// Comments stripped — this file's subject is discussed at length in the view's
    /// prose, so without this a doc comment would satisfy a pin about a CALL.
    private static func codeOnly(_ content: String) -> String {
        content.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                return ""
            }
            return line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
        }.joined(separator: "\n")
    }

    @Test("PianoRollView actually runs the open-focus policy, on the right seam")
    func theViewIsWired() {
        let url = Self.sourcesDir().appendingPathComponent("DAWApp/PianoRoll/PianoRollView.swift")
        let raw = try? String(contentsOf: url, encoding: .utf8)
        let source = Self.codeOnly(raw ?? "")
        // Positive control: the file was found and stripped to real code.
        #expect(source.contains("private func focusPitchAxis(on pitch: Int)"))

        // It calls the policy at all.
        #expect(source.contains("PianoRollOpenFocus.focusPitch("))
        #expect(source.contains("PianoRollOpenFocus.visiblePitchWindow("))

        // ⚠️ THE ONCE-PER-OPEN LATCH. Without it the auto-centre becomes per-frame
        // behaviour and fights every user scroll — the failure requirement 1 names.
        #expect(source.contains("guard !didAutoFocusPitchOnOpen, editorViewportHeight > 0 else { return }"))
        #expect(source.contains("didAutoFocusPitchOnOpen = true"))

        // ⚠️ AND IT MUST NOT RIDE THE EXTERNAL-MUTATION SEAM. `reseedFromExternalMutation`
        // fires under the SAME clip identity (wire-side trim/move/split, undo/redo);
        // auto-centring there would re-frame the roll on every such edit.
        let mutationSeam = source.range(of: ".onChange(of: clip) { _, newValue in")
        if let mutationSeam {
            let tail = source[mutationSeam.upperBound...].prefix(200)
            #expect(!tail.contains("attemptOpenPitchFocus"))
        } else {
            Issue.record("The m18-i external-mutation seam moved — re-check the m35-h seam choice.")
        }
    }
}
