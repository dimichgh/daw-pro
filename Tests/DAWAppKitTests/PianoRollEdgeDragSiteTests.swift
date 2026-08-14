import Testing
import Foundation

/// m25-f-2 / m25-f-3 — THE WIRING, pinned at the SOURCE.
///
/// ⚠️ **WHY A SOURCE-SITE PIN AND NOT A BEHAVIOURAL TEST.** Both features are
/// reached only by dragging or pasting with a real pointer inside a real window,
/// and m23-g1 established that nothing in this tree can produce one: an
/// unbundled staging binary does not route real key or pointer events, so no
/// `.mjs` gate can see either gesture. The POLICY is pinned headlessly
/// (`PianoRollAutoScrollTests`, `NotePasteLandingTests`); what those cannot see
/// is whether the view still CALLS it. A silent unwiring — someone deletes the
/// `autoScroll` call, or the paste stops passing `pitchOffset` — would leave
/// every other test in this repo green. This reddens instead.
///
/// ⚠️⚠️ **EVERY ASSERTION HERE RUNS AGAINST A COMMENT-STRIPPED, BRACE-MATCHED
/// FUNCTION BODY, and that is not tidiness.** `EditorSurfaceOwnershipSiteTests`
/// shipped a `contains` assertion that a DIFFERENT symbol satisfied as a prefix,
/// so it passed whether or not the thing it named was wired at all. Bodies are
/// extracted by name (a rename fails rather than passing vacuously), prose
/// cannot satisfy a claim about what code CALLS, and every negative below is
/// paired with a positive control proving the needle is findable.
@Suite("Piano roll edge drag + paste wiring (m25-f-2, m25-f-3)")
struct PianoRollEdgeDragSiteTests {

    // MARK: - Source access

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
        // A pin test that silently finds no files reports the cleanest possible
        // green, which is the most dangerous kind. Say so loudly instead.
        Issue.record("Could not locate Sources from \(#filePath)")
        return URL(fileURLWithPath: "/nonexistent")
    }

    private static func text(_ relativePath: String) -> String {
        let url = sourcesDir().appendingPathComponent(relativePath)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("Could not read \(relativePath) under \(sourcesDir().path)")
            return ""
        }
        return content
    }

    /// Every line with comments removed, so a body's own prose can neither
    /// satisfy nor violate an assertion about what it CALLS.
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

    /// The text BETWEEN the braces of `func <name>` — or of `var <name>`, since
    /// half the things worth pinning in a SwiftUI view are computed properties —
    /// by brace matching.
    ///
    /// Returns nil when the declaration cannot be found — treated by every
    /// caller as a FAILURE, because "renamed" and "clean" must never look the
    /// same. ⭐ That is not hypothetical: this suite's first run reddened
    /// because `visiblePitchWindow` is a `var` and the extractor only knew
    /// `func`. It failed LOUDLY instead of quietly asserting nothing, which is
    /// the entire reason the nil is treated as a failure rather than skipped.
    private static func body(of name: String, in content: String) -> String? {
        let code = codeOnly(content)
        guard let decl = code.range(of: "func \(name)")
                ?? code.range(of: "var \(name)") else { return nil }
        guard let open = code.range(of: "{", range: decl.upperBound..<code.endIndex) else {
            return nil
        }
        var depth = 0
        var index = open.lowerBound
        while index < code.endIndex {
            let ch = code[index]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return String(code[code.index(after: open.lowerBound)..<index])
                }
            }
            index = code.index(after: index)
        }
        return nil
    }

    private static let rollPath = "DAWApp/PianoRoll/PianoRollView.swift"

    private func rollBody(_ name: String) -> String {
        let found = Self.body(of: name, in: Self.text(Self.rollPath))
        #expect(found != nil, "`\(name)` not found in \(Self.rollPath) — renamed?")
        #expect(found?.isEmpty == false, "`\(name)` body is empty")
        return found ?? ""
    }

    private func occurrences(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    // MARK: - m25-f-3 — auto-scroll

    @Test("the live drag calls auto-scroll on every branch that drags content")
    func advanceGestureAutoScrolls() {
        let advance = rollBody("advanceGesture")
        // A COUNT, not "at least one". A resize dragged to the right edge is
        // exactly the gesture that most needs the grid to come with it, and it
        // is the one an author would forget: `.move` is the case the item was
        // written about. The count is what catches a half-wiring.
        //
        // ⭐ RE-MEASURED 2026-08-13 (m25-g), 2 -> 3: the group compress/extend
        // handle adds a third content-dragging branch (`.groupScale`), and a
        // STRETCH is the single gesture on this surface most likely to run off
        // the right edge of the viewport — its whole purpose can be to push the
        // last note past where the clip used to end. If this number ever drops
        // back to 2 because a branch was folded away, the stretch stopped
        // scrolling. The two branches that must NOT be here are `.click` and
        // `.marquee`: a rubber band scrolling the grid under itself would
        // re-decide the selection from a moving origin.
        let found = occurrences("autoScroll(towards:", in: advance)
        let note = "expected the .move, .resize AND .groupScale branches of advanceGesture to "
            + "auto-scroll, found \(found)"
        #expect(found == 3, "\(note)")
        // ANTI-VACUITY: the body really is the gesture funnel, not some empty
        // string that trivially contains nothing.
        #expect(advance.contains("model.moveSelection("))
        #expect(advance.contains("model.resizeNote("))
        #expect(advance.contains("model.scaleSelection("))
    }

    @Test("⚠️ auto-scroll travels the MANUAL-SCROLL seam, and never the persisted enable")
    func autoScrollUsesTheManualSeam() {
        let scroll = rollBody("autoScroll")
        // THE PRECEDENCE DECISION. `scrollExternally` is the seam a minimap jump
        // uses (m25-b-2), and taking it means an edge drag IS a manual scroll,
        // so follow stands down on this surface for the rest of the take.
        #expect(scroll.contains("follow.scrollExternally("),
                "the edge drag must deliver its scroll through the manual-scroll seam")
        // ⚠️ AND MUST NOT WRITE `layout.followPlayhead`: that flag is the single
        // PERSISTED enable the arrange lanes read too, so winning a piano-roll
        // gesture with it would stand follow down on a surface the user never
        // touched and outlive the gesture by every future session.
        #expect(!scroll.contains("setFollowPlayhead"))
        #expect(!scroll.contains("layout.followPlayhead"))
        // POSITIVE CONTROL for the two negatives above — without it, a typo in
        // either needle would make them pass forever. Both spellings ARE
        // findable in this tree, so their absence here is a fact about this
        // function rather than about my pattern.
        let layout = Self.text("DAWAppKit/PanelLayoutModel.swift")
        #expect(layout.contains("setFollowPlayhead"))
        #expect(layout.contains("followPlayhead"))
    }

    @Test("auto-scroll asks the pure policy and does no geometry of its own")
    func autoScrollDelegatesToThePolicy() {
        let scroll = rollBody("autoScroll")
        #expect(scroll.contains("PianoRollAutoScroll.nextOffset("))
        // A `guard let … else { return }` on the policy's nil is what keeps the
        // nonce quiet on the ~90 % of drag ticks nowhere near an edge.
        #expect(scroll.contains("else { return }"))
    }

    // MARK: - m25-f-3 — auto-extend

    @Test("a drag that moved commits with the ids it touched, so the clip can grow")
    func endGestureRequestsAutoExtend() {
        let end = rollBody("endGesture")
        #expect(end.contains("commit(extendToCover: autoExtendIDs(for: outgoing))"),
                "the ending drag must name the notes that may grow the clip")
        // ⚠️ ONE `commit(` IN THIS FUNCTION, DELIBERATELY.
        // `EditorSurfaceOwnershipSiteTests` pins the file-wide count of `commit(`
        // as its R6 false-engage guard; splitting the move/resize switch across
        // two calls would have moved that number for a reason that has nothing
        // to do with engagement. Pinned here so the reason survives.
        #expect(occurrences("commit(", in: end) == 1)
    }

    @Test("a MOVE extends for the selection, a RESIZE only for the note being resized")
    func autoExtendIDsAreTheTouchedNotes() {
        let ids = rollBody("autoExtendIDs")
        // A move translates the whole selection rigidly, so every selected note
        // is a note this gesture moved.
        #expect(ids.contains("case .move: return model.moveIDsStartingAudible()"))
        // A resize moves ONE note's end. The rest of the selection did not move,
        // and m25-a's rule is that a stationary note must not move the clip edge.
        #expect(ids.contains("note.startBeat < model.clipLengthBeats else { return [] }"))
        // Everything else contributes nothing — a click, a marquee, a playhead
        // scrub and a cancelled gesture must never grow a clip.
        //
        // ⚠️ **`.playheadDrag` JOINED THIS LIST IN m25-o-2, and the pin was
        // updated rather than loosened.** Dragging the playhead moves the
        // transport, which is not an edit and cannot make a note audible, so it
        // belongs exactly here. The list is still spelled out in full rather
        // than replaced with a `default:` — an exhaustive list forces every new
        // gesture to make this decision explicitly, whereas a `default` would
        // let the next one inherit "extends nothing" by silence, which is the
        // wrong default to inherit accidentally.
        #expect(ids.contains("case .none, .click, .marquee, .playheadDrag, .cancelled: return []"))
    }

    // MARK: - m25-f-2 — paste

    @Test("the paste asks the policy where to land, and honours BOTH of its answers")
    func pasteConsultsTheLandingPolicy() {
        let paste = rollBody("applyClipboardRequest")
        #expect(paste.contains("PasteAnchorPolicy.resolveNotePaste("))
        // BOTH axes must reach `translatedNotes`, or the nudge is computed and
        // silently dropped — which would look exactly like the old behaviour.
        #expect(paste.contains("pitchOffset: landing.pitchOffset"))
        // The snap decision is the policy's, not this view's: an above-source
        // paste must NOT be re-snapped or a swung figure lands off its source.
        #expect(paste.contains("landing.snap"))
        // ⚠️ AND THE VISIBLE-AREA BRANCH MUST USE `snapUp`, not `snap`: rounding
        // to nearest puts the group off the LEFT EDGE of the screen.
        #expect(paste.contains("model.snapUp(beat: landing.localBeat"))
        // ANTI-VACUITY: this really is the clipboard funnel.
        #expect(paste.contains("case .paste:"))
        #expect(paste.contains("case .copy:"))
    }

    @Test("the pasted group is left SELECTED — that is most of 'drag-ready'")
    func pastedNotesBecomeTheSelection() {
        // Pre-existing (m23-ek-3) and pinned end-to-end by the shipped
        // `m23ek-clipboard.mjs` leg N2e. Re-pinned here because m25-f-2's whole
        // premise is that the group arrives ready to drag: if a later change
        // dropped the selection, the offset would become pointless rather than
        // wrong, and nothing would say so.
        //
        // ⚠️ **THE SPELLING CHANGED WHEN THE m25-f-2 GAP LANDED, THE CLAIM DID
        // NOT.** This used to pin the literal `model.selection =
        // Set(pasted.map(\.id))`. The auto-extend leg needs that same set a
        // second time (to tell the store which notes may move the clip's edge),
        // so it is now a named local — and the pin follows it, deliberately in
        // TWO halves: the set is still derived from `pasted` and nothing else,
        // and the selection is still exactly that set. A source-site pin that
        // reddens on a rename it was never built to police is measuring
        // spelling; these two measure the claim.
        let paste = rollBody("applyClipboardRequest")
        #expect(paste.contains("let pastedIDs = Set(pasted.map(\\.id))"))
        #expect(paste.contains("model.selection = pastedIDs"))
    }

    /// ⭐ **THE m25-f-2 GAP — the user's report: pasting notes past a short
    /// clip's end did not grow the clip.** `ProjectStore.pasteNotes` now takes
    /// `extendToCover:` and `PasteAutoExtendTests` pins what it does with it —
    /// but a store parameter nothing passes is dead code, and the paste is
    /// reachable only by a real ⌘V, so no headless test and no `.mjs` gate can
    /// observe the threading. This is the only instrument that can.
    ///
    /// ⚠️⚠️ **IT MUST BE THE PASTED IDS, NOT `model.selection`.** They are equal
    /// on the line above and that is a coincidence of ordering, not a contract:
    /// the invariant the store needs is "the notes THIS GESTURE placed", because
    /// the array it is handed is the whole draft and may already hold
    /// legal-but-latent notes far past the clip end (m18-f) that must NOT drag
    /// the clip's edge with them. Reading the selection back would work today
    /// and break the first time anything else touched the selection first.
    @Test("m25-f-2: the paste hands the store the ids it PLACED, so the clip can grow")
    func pasteThreadsAutoExtendIDs() {
        let paste = rollBody("applyClipboardRequest")
        #expect(paste.contains("onPasteNotes(model.buildSubmission(), pastedIDs)"))
        // NEGATIVE, with its positive control below: the cover set must not be
        // read back off the selection.
        #expect(!paste.contains("onPasteNotes(model.buildSubmission(), model.selection)"))
        // POSITIVE CONTROL for that negative — `model.selection` IS present in
        // this body, so the absence above is a real absence and not a needle
        // that could never have been found.
        #expect(paste.contains("model.selection"))
    }

    /// ⚠️ **THE PASTE MUST NOT ACQUIRE A `commit(`.** m25-f-2 gives paste the
    /// auto-extend rule that note creation and note drags already get through
    /// `commit(extendToCover:)`, and the tempting "simplification" is to route
    /// paste through that same call. It would fold the paste into a note edit
    /// made within 800 ms (`setClipNotes` journals under `clip.notes:<id>`) and
    /// ONE ⌘Z would undo both — the exact trap `pasteNotes` exists to close.
    /// `EditorSurfaceOwnershipSiteTests` pins the file-wide `commit(` count as
    /// its R6 false-engage guard; this pins the narrower, more direct claim.
    @Test("m25-f-2: the paste branch stays on the UNCOALESCED store route")
    func pasteDoesNotRouteThroughCommit() {
        let paste = rollBody("applyClipboardRequest")
        #expect(!paste.contains("commit("))
        // POSITIVE CONTROL: `commit(` is findable in this file — the negative
        // above is about this body, not about a pattern that never matches.
        #expect(Self.codeOnly(Self.text(Self.rollPath)).contains("commit("))
    }

    @Test("the paste bounds its nudge by what is on screen")
    func pasteBoundsTheNudgeByVisibility() {
        let paste = rollBody("applyClipboardRequest")
        #expect(paste.contains("visiblePitches: visiblePitchWindow"))
        // And the window is derived from the model's own affine mapping rather
        // than re-spelled here, so it cannot disagree with the rows being drawn.
        let window = rollBody("visiblePitchWindow")
        #expect(occurrences("model.pitch(forY:", in: window) == 2)
    }
}
