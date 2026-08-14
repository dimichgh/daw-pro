import Foundation
import Testing

/// m25-l-2 — the SOURCE-SHAPE half of cross-track clip drag.
///
/// **WHY A SITE TEST.** `ArrangeVerticalDragTests` proves the two DECISIONS are
/// one rule each. It cannot prove that the view actually ASKS them, and it
/// cannot prove the CADENCE — and cadence is precisely what this item was
/// briefed to protect. m25-k's defect was never a wrong policy; it was a
/// land-time policy invoked on every drag frame, which ate clips the user only
/// passed over. **A correct policy at the wrong cadence looks exactly like a
/// correct policy**, so no behavioural test in this tree can distinguish them:
/// `DAWApp` has no test target, and this file is the only thing in the repo that
/// can see inside `TimelineLanesView` or `AppModel`.
///
/// Same idiom as `DeleteKeySiteTests` / `EditorSurfaceOwnershipSiteTests` —
/// anchored to the repo via `#filePath`, comments stripped so prose about a call
/// cannot satisfy an assertion about the call.
///
/// ⚠️ **A TOKEN SEARCH FINDS THE TOKEN, NOT THE BEHAVIOUR.** If one of these
/// fails, do not "fix" it by rewording the source. Every assertion names the
/// failure it exists to catch; read that first.
@Suite("Cross-track drag — the call sites (m25-l-2)")
struct ArrangeVerticalDragSiteTests {

    // MARK: - Locating the tree

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

    private static func raw(_ relativePath: String) -> String {
        let url = sourcesDir().appendingPathComponent(relativePath)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("Could not read \(relativePath) under \(sourcesDir().path)")
            return ""
        }
        return content
    }

    /// Comments removed, so prose ABOUT a call cannot satisfy an assertion about
    /// the call. Both files touched by this item discuss the m25-k defect at
    /// length; without this, "the preview does not move the store" would be
    /// satisfied by a doc comment saying so.
    private static func code(_ relativePath: String) -> String {
        raw(relativePath).split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let text = String(line)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                return ""
            }
            return text.range(of: "//").map { String(text[..<$0.lowerBound]) } ?? text
        }.joined(separator: "\n")
    }

    /// Comment-stripped code with every run of whitespace collapsed to one
    /// space, so a pin on an exact call spelling does not depend on where the
    /// line breaks happen to fall.
    private static func flat(_ relativePath: String) -> String {
        code(relativePath).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The text BETWEEN the braces of `func <name>`, by brace matching. Comments
    /// stripped first. Nil when the function cannot be found, which every caller
    /// treats as a FAILURE — "renamed" and "clean" must never look the same here.
    private static func body(of name: String, in content: String) -> String? {
        guard let decl = content.range(of: "func \(name)(") else { return nil }
        guard let open = content.range(of: "{", range: decl.upperBound..<content.endIndex) else {
            return nil
        }
        var depth = 0
        var out = ""
        var i = open.lowerBound
        while i < content.endIndex {
            let ch = content[i]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 { return out }
            }
            if depth >= 1 { out.append(ch) }
            i = content.index(after: i)
        }
        return nil
    }

    private static let timeline = "DAWApp/Timeline/TimelineLanesView.swift"
    private static let appModel = "DAWApp/DAWProApp.swift"

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var index = haystack.startIndex
        while let found = haystack.range(of: needle, range: index..<haystack.endIndex) {
            count += 1
            index = found.upperBound
        }
        return count
    }

    // MARK: - The cadence

    /// ⚠️⚠️ **THE m25-k TRAP, ON THE SECOND AXIS.** The per-frame handler must
    /// PREVIEW. If it ever calls the commit — or reaches the store directly —
    /// a cross-lane drag resolves the land-time overlap policy against every
    /// lane it passes over, which is the original defect with a wider blast
    /// radius: the user loses a clip on each lane, not just on one.
    @Test("the per-frame body handler previews and never commits")
    func perFrameHandlerPreviewsAndNeverCommits() {
        guard let apply = Self.body(of: "applyDrag", in: Self.code(Self.timeline)) else {
            Issue.record("TimelineLanesView.applyDrag not found — renamed? Re-derive this pin.")
            return
        }
        #expect(apply.contains("onMovePreview("),
                "the body branch must run the PREVIEW callback")
        #expect(!apply.contains("onMoveCommit"),
                "a commit inside the per-frame handler IS the m25-k defect")
        #expect(!apply.contains("store."),
                "the per-frame handler must reach no store at all")
    }

    /// The preview's structural no-write guarantee, in `AppModel` this time.
    /// `ArrangeBodyDrag` makes it unreachable BY TYPE (its update returns Void and
    /// it holds no store); this pins the one function that does hold a store.
    @Test("previewArrangeDrag moves no clips — neither along nor across")
    func previewArrangeDragMovesNothing() {
        guard let preview = Self.body(of: "previewArrangeDrag", in: Self.code(Self.appModel)) else {
            Issue.record("AppModel.previewArrangeDrag not found — renamed? Re-derive this pin.")
            return
        }
        #expect(preview.contains("ArrangeVerticalDrag.effectiveDelta"),
                "the ghost's row must come from the same producer the commit uses")
        #expect(!preview.contains("store.moveClips"),
                "the preview must never call a move — that is the whole of m25-k")
    }

    // MARK: - Threading the vertical axis

    /// ⚠️ `stretchDrag` falls through to `applyDrag` whenever ⌥ is held over a
    /// non-stretch zone, so feeding the pointer's y from `clipDrag` alone would
    /// leave ⌥-held body drags silently same-track-only — a partial feature that
    /// looks like a whole one.
    ///
    /// ⚠️ SCOPE, so this pin is not read as more than it is: only the `.body`
    /// zone crosses lanes. `ClipStretch.isStretchDrag` is
    /// `zone == .trimEnd && optionHeld && isAudio`, so ⌥ on a MIDI clip's right
    /// edge reaches `applyDrag` and then takes the TRIM branch, which has no
    /// vertical axis and should not have one.
    @Test("BOTH drag gestures feed the pointer's y to the body handler")
    func bothGesturesFeedThePointerY() {
        let flat = Self.flat(Self.timeline)
        let sites = Self.occurrences(of: "pointerContentY: Double(value.location.y)", in: flat)
        #expect(sites == 2,
                "expected exactly 2 gesture sites (clipDrag + stretchDrag), found \(sites)")
    }

    /// ONE home for "which row is this y". The file-drop path and the drag must
    /// not answer the same question twice — two vertical axes disagreeing about
    /// the same visible row is what the store's own axis rule forbids.
    @Test("the lanes resolve a row through ArrangeVerticalDrag, not by hand")
    func lanesResolveRowsThroughTheOneHome() {
        let source = Self.code(Self.timeline)
        guard let trackIndex = Self.body(of: "trackIndex", in: source),
              let delta = Self.body(of: "verticalTrackDelta", in: source) else {
            Issue.record("trackIndex / verticalTrackDelta not found — renamed? Re-derive this pin.")
            return
        }
        #expect(trackIndex.contains("ArrangeVerticalDrag.row"))
        #expect(delta.contains("ArrangeVerticalDrag.requestedDelta"))
        // NEITHER may reach for a fallback row: off the lane stack means NO
        // vertical change, and a `?? 0` here flings clips to the top track.
        #expect(!trackIndex.contains("?? 0"))
        #expect(!delta.contains("?? 0"))
    }

    /// ⚠️ `laneTop` subscripts `tracks[i]`. A track removed mid-drag leaves a
    /// delta clamped against a longer array, so an unclamped ghost row is a
    /// TRAP, not a cosmetic glitch.
    @Test("the ghost's row is clamped into the live track array")
    func ghostRowIsClamped() {
        guard let ghost = Self.body(of: "ghostRow", in: Self.code(Self.timeline)) else {
            Issue.record("TimelineLanesView.ghostRow not found — renamed? Re-derive this pin.")
            return
        }
        #expect(ghost.contains("min(") && ghost.contains("max("),
                "an unclamped row indexes past the end of tracks[]")
        #expect(ghost.contains("tracks.count - 1"))
    }

    // MARK: - The commit branch

    /// ⚠️⚠️ **THE GUARD MUST KEY ON THE ACHIEVED DELTA, NOT THE REQUESTED ONE.**
    /// A vertical request the clamp or the compatibility back-off reduces to zero
    /// IS a same-track move, and routing it through the cross-track verb anyway
    /// would change the undo label on the ordinary drag path that
    /// `m23g2-group-drag.mjs` pins — for a gesture that moved nothing vertically.
    @Test("the commit branches on the ACHIEVED vertical delta")
    func commitBranchesOnTheAchievedDelta() {
        guard let drag = Self.body(of: "dragArrangeClips", in: Self.code(Self.appModel)) else {
            Issue.record("AppModel.dragArrangeClips not found — renamed? Re-derive this pin.")
            return
        }
        #expect(drag.contains("ArrangeVerticalDrag.effectiveDelta"),
                "the commit must resolve the vertical through the same producer as the preview")
        #expect(drag.contains("byTracks:"), "the cross-track verb must actually be reachable")
        #expect(drag.contains("trackDelta != 0"),
                "the branch must test the ACHIEVED delta — `requestedTrackDelta != 0` would send a backed-off drag through the cross-track verb")
    }

    /// The release is still the ONE move, and it must carry BOTH axes. A commit
    /// that dropped the vertical would preview a cross-lane landing and then quietly
    /// perform a same-lane one — the ghost lying about the drop.
    @Test("the release hands the vertical request on to the one move")
    func releaseCarriesTheVerticalRequest() {
        guard let commit = Self.body(of: "commitArrangeDrag", in: Self.code(Self.appModel)) else {
            Issue.record("AppModel.commitArrangeDrag not found — renamed? Re-derive this pin.")
            return
        }
        #expect(commit.contains("requestedTrackDelta: commit.requestedTrackDelta"))
    }
}
