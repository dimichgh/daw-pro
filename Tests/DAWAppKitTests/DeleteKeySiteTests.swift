import Foundation
import Testing
import DAWAppKit

/// m23-cf (second pass) — the SOURCE-SHAPE half of DELETE-key ownership.
///
/// **WHY A SITE TEST.** `DeleteKeyRoutingTests` proves the DECISION is one rule.
/// It cannot prove that the three views which claim the key actually ASK it —
/// and "a claimant quietly went back to deciding for itself" is precisely the
/// regression this item exists to prevent, because its symptom is not a crash or
/// a red assertion but an INTERMITTENT one: the wrong thing gets deleted only on
/// the presses where SwiftUI happened to focus that claimant. `DAWApp` has no
/// test target, so this file is the only thing in the repo that can see it.
///
/// Same idiom as `EditorSurfaceOwnershipSiteTests` / `PollDisciplinePinTests` /
/// `CanvasContractPinTests`: anchored to the repo via `#filePath`, comments
/// stripped so prose about a banned token cannot fail an assertion about code.
///
/// ⚠️ **A TOKEN SEARCH FINDS THE TOKEN, NOT THE BEHAVIOUR.** If one of these
/// fails, do not "fix" it by rewording the source. Every assertion names the
/// failure it exists to catch; read that first.
@Suite("DELETE key — the three claimants all route (m23-cf, second pass)")
struct DeleteKeySiteTests {

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
    /// the call. Every file touched by this item discusses the other two
    /// claimants at length; without this, "the roll routes" would pass off a
    /// sentence in `ContentView`.
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

    /// Comment-stripped code with every newline and run of whitespace collapsed
    /// to one space.
    ///
    /// **WHY (m23-fk).** The three delete mounts no longer fit on one line, so
    /// the exact-spelling pins below would otherwise have had to be weakened to
    /// a prefix or a fixed-width window — a pin whose verdict depends on
    /// formatting, which `rollRoutes` already rejected once for the same reason.
    /// Collapsing whitespace pins the SAME characters as before, in the same
    /// order, and merely stops caring where the line breaks fall.
    private static func normalized(_ content: String) -> String {
        content.split(whereSeparator: { $0 == "\n" || $0 == " " || $0 == "\t" })
            .joined(separator: " ")
    }

    /// The text between the braces of the closure that FOLLOWS `marker`.
    ///
    /// ⚠️ SEARCHES FROM THE END OF `marker`, never from its start, because the
    /// key list itself contains braces: `KeyEquivalent("\u{7F}")`. A scan for
    /// "the first `{`" from the start of the mount would find the one inside the
    /// unicode escape and brace-match into nonsense. Nil when the marker or its
    /// closure cannot be found, which every caller treats as a FAILURE.
    private static func closureBody(after marker: String, in content: String) -> String? {
        guard let mount = content.range(of: marker) else { return nil }
        guard let open = content.range(of: "{", range: mount.upperBound..<content.endIndex) else {
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

    /// ⭐⭐ THE KEY LIST EVERY CLAIMANT MUST SPELL (m23-fk), and the reason it is
    /// a constant here rather than three literals: the three mounts must not
    /// drift apart, and this file is the only thing in the repo that can see
    /// them at all (`DAWApp` has no test target).
    ///
    /// **`\u{7F}` IS THE WHOLE FIX AND IT IS A MEASUREMENT.** `.onKeyPress`
    /// matches on the event's CHARACTERS. `KeyEquivalent.delete` is **0x08**
    /// (BACKSPACE — read out of SwiftUI itself by `KeyPressProbe.echo`), while
    /// `NSEvent.characters` for `kVK_Delete` (51) is **0x7F** (DELETE), so
    /// `.onKeyPress(.delete)` could never fire for the ⌫ key. Measured on the
    /// live app before the fix (`_m23fk-delete-character-probe.mjs`): an event
    /// carrying 0x7F entered NO mount, the SAME key code carrying 0x08 entered
    /// one and deleted a clip. `.deleteForward` (0xF728) is what ⌦ really sends
    /// and no mount spelled it before.
    ///
    /// ⚠️⚠️ **`phases: [.down]` IS PART OF THIS PIN AND IS NOT DECORATION.**
    /// SwiftUI's documented default for this overload is `.down`; MEASURED ON
    /// THE LIVE APP IT DOES NOT BEHAVE AS ONE — with the argument omitted the
    /// mount receives presses whose `KeyPress.phase` reads `.repeat` (read out
    /// of SwiftUI inside that very closure). That matters because the m23-cf-3
    /// monitor REFUSES an auto-repeat and RETURNS the event, so a HELD ⌫ reaches
    /// these mounts — and a mount cannot re-derive repeat-ness for itself: the
    /// monitor swallowed the initial key-down, so SwiftUI's own key-state
    /// tracking never saw it. MEASURED SEQUENCE with the argument omitted, piano
    /// roll open on a clip with three notes selected: key-down → notes 3→0 (the
    /// monitor owned it and swallowed); FIRST AUTO-REPEAT → **the clip itself
    /// was deleted**. That is the exact loss `DeleteKeyMonitorRouting`'s
    /// `keyRepeat` doc calls "the ONE guard with teeth". With `[.down]`: funnel
    /// +0, notes stay deleted, clip alive. DO NOT DROP IT TO SHORTEN A LINE.
    private static let deleteMount =
        ".onKeyPress(keys: [KeyEquivalent(\"\\u{7F}\"), .delete, .deleteForward], "
        + "phases: [.down])"

    /// The spelling that CANNOT WORK — pinned as a negative so it cannot come
    /// back in a new corner of the app.
    private static let deadSpelling = ".onKeyPress(.delete"

    private static let appPath = "DAWApp/DAWProApp.swift"
    private static let rollPath = "DAWApp/PianoRoll/PianoRollView.swift"
    private static let contentPath = "DAWApp/ContentView.swift"
    private static let lanePath = "DAWApp/Timeline/AutomationLaneEditor.swift"
    private static let mixerPath = "DAWApp/Mixer/MixerStripView.swift"
    private static let claimantPaths = [rollPath, contentPath, lanePath]

    // MARK: - The census: how many claimants there are

    @Test("there are EXACTLY three DELETE-claiming `.onKeyPress` sites, and none uses the dead spelling")
    func claimantCountIsPinned() {
        // ⚠️ THE ORIGINAL DIAGNOSIS OF THIS BUG NAMED TWO CLAIMANTS AND THERE ARE
        // THREE — `AutomationLaneEditor` was missed, and it is focusable, mounted
        // once per EXPANDED TRACK, and was deciding DELETE for itself. That near
        // miss is the whole reason this count is pinned: a FOURTH deletable
        // surface added later would reintroduce the bug in its own corner of the
        // app, silently and intermittently, and nothing else in this repo would
        // notice.
        //
        // ⚠️⚠️ m23-fk WIDENED THIS FROM ONE TOKEN TO TWO COUNTS, AND NARROWING IT
        // BACK WOULD BE THE WEAKENING THIS FILE'S BANNER WARNS ABOUT. The census
        // used to count the literal `.onKeyPress(.delete`, which after m23-fk is
        // 0 everywhere — so retargeting it to the NEW spelling alone would stop
        // seeing a future mount written the OLD way, and a mount written the old
        // way is a CHARACTER-DEAD mount, i.e. exactly this bug reintroduced. So
        // both are counted:
        //   • CLAIMANTS — any `.onKeyPress(` line that names a delete key at all,
        //     however spelled. Must be 3.
        //   • THE DEAD SPELLING — `.onKeyPress(.delete`. Must be 0, everywhere.
        //
        // MEASURED against this tree (2026-08-10), comment-stripped:
        //   PianoRollView 1, AutomationLaneEditor 1, ContentView 1 (ArrangeDeleteKey)
        let fm = FileManager.default
        let dir = Self.sourcesDir().appendingPathComponent("DAWApp", isDirectory: true)
        guard let walk = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            Issue.record("could not enumerate \(dir.path)")
            return
        }
        var perFile: [String: Int] = [:]
        var deadPerFile: [String: Int] = [:]
        var filesSeen = 0
        for case let url as URL in walk where url.pathExtension == "swift" {
            filesSeen += 1
            let relative = "DAWApp/" + url.path
                .replacingOccurrences(of: dir.path + "/", with: "")
            let source = Self.code(relative)
            // Any mount that names a delete key, whatever spelling it uses —
            // `.onKeyPress(.delete)`, `.onKeyPress(.deleteForward)`, or a
            // `keys:` list carrying either name or the raw character.
            let claiming = source.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { line in
                    guard line.contains(".onKeyPress(") else { return false }
                    return line.lowercased().contains("delete") || line.contains("\\u{7F}")
                }.count
            if claiming > 0 { perFile[url.lastPathComponent] = claiming }
            let dead = source.components(separatedBy: Self.deadSpelling).count - 1
            if dead > 0 { deadPerFile[url.lastPathComponent] = dead }
        }
        // ANTI-VACUITY: a walk that found no files would report a clean 0 and
        // pass any "== 3" check only by luck, and a clean 0 on the file count is
        // the failure mode that looks most like success.
        #expect(filesSeen > 20, "walked only \(filesSeen) Swift files under Sources/DAWApp")
        let total = perFile.values.reduce(0, +)
        let breakdown = perFile.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let note = "expected 3 DELETE-claiming `.onKeyPress` sites under Sources/DAWApp "
            + "(PianoRollView, AutomationLaneEditor, ContentView's ArrangeDeleteKey), found "
            + "\(total) (\(breakdown)). A NEW claimant MUST call `AppModel.handleDeleteKey()` "
            + "rather than decide for itself — three focus-gated handlers each answering "
            + "'do I own DELETE?' their own way IS the m23-cf bug, and its symptom is "
            + "intermittent (wrong deletion only on the presses SwiftUI focused that view)."
        #expect(total == 3, "\(note)")
        #expect(perFile["PianoRollView.swift"] == 1)
        #expect(perFile["AutomationLaneEditor.swift"] == 1)
        #expect(perFile["ContentView.swift"] == 1)
        // ⭐ THE m23-fk HALF. `.onKeyPress(.delete)` matches `KeyEquivalent.delete`
        // == 0x08 (BACKSPACE); the ⌫ key's `NSEvent.characters` is 0x7F (DELETE).
        // The two never meet, so a mount spelled that way is DEAD ON ARRIVAL and
        // fails silently — no crash, no red, just a key that does nothing. It
        // shipped that way for three mounts and cost the Mix console's master
        // lane its only delete path.
        let deadTotal = deadPerFile.values.reduce(0, +)
        let deadBreakdown = deadPerFile.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        let deadNote = "found \(deadTotal) `\(Self.deadSpelling))` site(s) (\(deadBreakdown)). "
            + "That spelling CANNOT FIRE for the ⌫ key: `.onKeyPress` matches on the event's "
            + "CHARACTERS, `KeyEquivalent.delete` is 0x08 and ⌫ sends 0x7F (both measured — see "
            + "`KeyPressProbe`). Spell it `\(Self.deleteMount)` instead."
        #expect(deadTotal == 0, "\(deadNote)")
    }

    /// m23-fk — every claimant spells the character the ⌫ key actually sends.
    ///
    /// **WHY A SECOND TEST AND NOT ANOTHER LINE IN THE CENSUS.** The census
    /// above answers "how many claimants are there"; this one answers "do the
    /// three we know about agree". They fail for different reasons and a reader
    /// of a red run needs to know which — a fourth deletable surface appearing
    /// is a design question, one of three key lists drifting is a typo that
    /// silently kills a key on one surface only.
    @Test("all three claimants spell the character the ⌫ key actually sends (m23-fk)")
    func everyClaimantSpellsTheCharacterTheKeySends() {
        for path in Self.claimantPaths {
            let source = Self.code(path)
            #expect(!source.isEmpty, "could not read \(path)")
            let n = Self.normalized(source).components(separatedBy: Self.deleteMount).count - 1
            let why = "\(path) must mount DELETE as `\(Self.deleteMount)` exactly once, found "
                + "\(n). `KeyEquivalent.delete` is 0x08 (BACKSPACE) and the ⌫ key sends 0x7F "
                + "(DELETE) — both read off the live app, not off documentation — so a list "
                + "without `KeyEquivalent(\"\\u{7F}\")` is a mount the ⌫ key cannot reach. "
                + "`.deleteForward` (0xF728) is the ⌦ key, which no mount claimed before "
                + "m23-fk. `.delete` stays because it costs nothing and covers a future "
                + "SwiftUI that normalises the character."
            #expect(n == 1, "\(why)")
        }
    }

    // MARK: - Each claimant routes

    @Test("the PIANO ROLL asks the app instead of deciding — and keeps no local rule")
    func rollRoutes() {
        let roll = Self.code(Self.rollPath)
        #expect(!roll.isEmpty)
        let wired = "PianoRollView's DELETE handler must be `onDeleteKey() ? .handled : .ignored`"
        // m23-fk: the SAME characters as before, matched against whitespace-
        // collapsed source. The mount no longer fits on one line; nothing about
        // what is pinned has been relaxed — `_ in` is the `keys:` form's
        // `KeyPress` argument and the decision is byte-identical.
        #expect(Self.normalized(roll).contains(
            Self.deleteMount + " { _ in onDeleteKey() ? .handled : .ignored }"), "\(wired)")
        // THE NEGATIVE HALF, and it is the one that matters. The handler used to
        // read `guard !model.selection.isEmpty else { return .ignored }` and then
        // delete inline. That local rule was one of three competing answers; if it
        // comes back, the roll silently stops agreeing with the Edit menu and with
        // the other two claimants on the states where they differ.
        // THE HANDLER'S OWN CLOSURE, brace-matched, not a fixed-width window: a
        // character budget would silently start or stop covering the neighbouring
        // `.onChange(of: model.selection.isEmpty)` as unrelated lines move, which
        // is a pin whose verdict depends on formatting. (Before m23-fk this was
        // the handler LINE; the mount is now three lines, and a line-based lookup
        // would have had to be dropped rather than made precise.)
        // NORMALIZED INPUT, because the mount now spans two source lines and a
        // raw search for the marker would miss it — and `closureBody` returning
        // nil is reported as "renamed", which would read as a completely
        // different failure than the one that actually happened.
        guard let handler = Self.closureBody(
            after: Self.deleteMount, in: Self.normalized(roll)) else {
            Issue.record("could not find PianoRollView's `\(Self.deleteMount)` closure")
            return
        }
        let localRule = "PianoRollView's DELETE handler decides for itself again (it mentions "
            + "`model.selection`). The roll still EXECUTES the delete — via the "
            + "`noteSelection.deleteNonce` handler, where its own `guard !model.selection.isEmpty` "
            + "belongs — but it must not DECIDE. Two computations of one rule is m23-x -> m23-al."
        #expect(!handler.contains("model.selection"), "\(localRule)")
        #expect(!handler.contains("deleteSelection"), "\(localRule)")
        // ...and the executing half must still be there, or the routing lands
        // nowhere and DELETE goes quietly dead in the roll — a failure that would
        // look exactly like the bug being fixed.
        let executes = "the roll must still APPLY a routed delete through `deleteNonce`"
        #expect(roll.contains("noteSelection.deleteNonce"), "\(executes)")
    }

    @Test("the ARRANGE mount asks the app — `handleDeleteKey`, not `handleArrangeDeleteKey`")
    func arrangeRoutes() {
        let view = Self.code(Self.contentPath)
        let wired = "ArrangeDeleteKey's DELETE mount must call `model.handleDeleteKey()`. "
            + "Calling `handleArrangeDeleteKey()` directly is the ORIGINAL BUG: that method has "
            + "no piano-roll term among its four guards, so on the focus parity where this mount "
            + "wins it deletes the CLIP while the user has NOTES selected."
        // m23-fk: whitespace-collapsed for the `rollRoutes` reason — same
        // characters pinned, indifferent to where the line breaks fall.
        #expect(Self.normalized(view).contains(
            Self.deleteMount + " { _ in model.handleDeleteKey() ? .handled : .ignored }"),
                "\(wired)")
        #expect(!view.contains("model.handleArrangeDeleteKey()"), "\(wired)")
        // Both DAWApp consumers of the routing closure are wired from here: the
        // roll's `onDeleteKey:` and the lanes'. Two, and exactly two — a third
        // would mean a new claimant that `claimantCountIsPinned` should have seen.
        let wires = view.components(separatedBy: "onDeleteKey: { model.handleDeleteKey() }").count - 1
        let note = "expected 2 `onDeleteKey: { model.handleDeleteKey() }` wirings in ContentView "
            + "(PianoRollView and TimelineLanesView), found \(wires)"
        #expect(wires == 2, "\(note)")
    }

    @Test("the AUTOMATION LANE routes when wired, and keeps its own delete when not")
    func laneRoutesWhereItIsAClaimant() {
        let lane = Self.code(Self.lanePath)
        let wired = "AutomationLaneEditor's DELETE handler must prefer the routed `onDeleteKey`"
        #expect(lane.contains("guard let onDeleteKey else { return deleteSelection() }"), "\(wired)")
        #expect(lane.contains("return onDeleteKey() ? .handled : .ignored"), "\(wired)")
        // ⭐ m23-fk — AND IT MUST BE MOUNTED ON THE CHARACTER THE KEY SENDS. This
        // is the ONE mount with no monitor behind it: `handleDeleteKey` refuses
        // the Mix workspace by design, so `handleKeyDownEvent` returns the event
        // there and this closure is the master lane's ONLY delete path. Spelled
        // `.onKeyPress(.delete)` it could never fire, and ⌫ on a selected
        // master-volume breakpoint did nothing at all.
        let character = "AutomationLaneEditor must mount DELETE as `\(Self.deleteMount)`. It is "
            + "the only claimant the m23-cf-3 NSEvent monitor does not cover (the monitor hands "
            + "the Mix console's DELETE straight back), so a mount spelled with the 0x08 "
            + "`KeyEquivalent.delete` leaves the master automation lane with NO delete key. "
            + "`phases: [.down]` is part of the spelling — without it a HELD ⌫ walks down the "
            + "breakpoint list one point per auto-repeat tick (see `deleteMount`)."
        #expect(Self.normalized(lane).contains(Self.deleteMount), "\(character)")
        // THE MIXER MOUNT MUST STAY UNROUTED, and this is not laxity — it is the
        // one place routing would REMOVE a working operation. `handleDeleteKey`
        // opens with `workspaceMode == .arrange`, and the master lane lives in
        // the MIX workspace, so a routed mount would refuse its own DELETE key
        // outright. There is also nothing to arbitrate there: in the Mix console
        // that editor is the only claimant (`ContentView`'s root is a `switch
        // model.workspaceMode` with mutually exclusive branches).
        let mixer = Self.code(Self.mixerPath)
        let mix = "MixerStripView's master-lane mount must pass `onDeleteKey: nil` — routing it "
            + "would make `handleDeleteKey`'s workspace guard refuse the master lane's DELETE key "
            + "in the only workspace that lane exists in"
        #expect(mixer.contains("onDeleteKey: nil"), "\(mix)")
        #expect(!mixer.contains("handleDeleteKey"), "\(mix)")
    }

    // MARK: - The app-side entry point

    @Test("`handleDeleteKey` consumes the DAWAppKit decision and invents nothing")
    func handlerConsumesThePolicy() {
        let app = Self.code(Self.appPath)
        guard let routing = Self.body(of: "handleDeleteKey", in: app) else {
            let missing = "could not find `func handleDeleteKey(` in \(Self.appPath) — if it was "
                + "renamed, RENAME IT HERE TOO. A missing function must never read as a clean "
                + "pass on this assertion"
            Issue.record("\(missing)")
            return
        }
        let consumes = "`handleDeleteKey` must dispatch on `deleteKeyRouting`, the property that "
            + "asks `DeleteMenuPolicy.keyPress`. A rule spelled inline here would be untestable "
            + "forever (DAWApp has no test target) and would be a SECOND computation of the "
            + "decision the Edit menu already ships."
        #expect(routing.contains("deleteKeyRouting"), "\(consumes)")
        // FOCUS MUST NEVER BE A TERM. It is measurably a coin flip
        // (`pianoRollEditorFocused` alternates 6 true / 6 false across 12
        // consecutive clip selections), and the entire design is that the routing
        // does not depend on who won it.
        let focus = "`handleDeleteKey` reads a SwiftUI focus flag. That is the m23-al bug with "
            + "more steps: the flag is a REPORT of arbitration between competing @FocusState "
            + "owners and was measured non-deterministic. The routing must not depend on it."
        #expect(!routing.contains("pianoRollEditorFocused"), "\(focus)")
        #expect(!routing.contains("isFocused"), "\(focus)")
        // Every branch must be dispatched. A `default:` that swallowed a
        // surface would silently send it to the arrange — the exact reason
        // `DeleteSurface` is a sum type. ⚠️ m23-ap I7b added the fourth: the
        // note editor's selected notes, handed to the pane's bridge as a CASE of
        // the surface switch (it was a refusal's side effect at I4).
        for branch in ["pianoRollNoteSelection.requestDelete()",
                       "automationPointSelection.requestDelete()",
                       "handleArrangeDeleteKey()",
                       "case .pitchEditorNotes:",
                       "pitchEditorInteraction.requestDelete()"] {
            #expect(routing.contains(branch),
                    "`handleDeleteKey` no longer routes to `\(branch)`")
        }
        // THE POLICY CALL ITSELF lives on `deleteKeyRouting`, one property over.
        guard let property = app.range(of: "var deleteKeyRouting: DeleteMenuItem") else {
            Issue.record("could not find `var deleteKeyRouting: DeleteMenuItem` in \(Self.appPath)")
            return
        }
        let propertyBody = String(app[property.lowerBound...].prefix(600))
        #expect(propertyBody.contains("DeleteMenuPolicy.keyPress"), "\(consumes)")
        // ...fed the SAME predicate the nudge guard and the Edit-menu item read,
        // never a second spelling of "would the roll have consumed this key".
        let oneHome = "`deleteKeyRouting` must read `pianoRollWouldConsumeKey`, the ONE home for "
            + "the roll's consume test — a second spelling is free to drift from the nudge "
            + "guard's fifth term and from `deleteMenuItem`"
        #expect(propertyBody.contains("pianoRollWouldConsumeKey"), "\(oneHome)")
        let m17d = "`deleteKeyRouting` must pass the m17-d responder classifier "
            + "(`isArrangeTextEditingFocused`) — without it a Backspace typed into a rename "
            + "field deletes the user's clips"
        #expect(propertyBody.contains("isArrangeTextEditingFocused"), "\(m17d)")
    }

    /// m23-cf-3 — the mechanism behind the `keyDelete` probe's DELIVERY signal.
    ///
    /// **WHY A SITE TEST AND NOT A GATE LEG.** No gate in this tree can drive
    /// `keyReachedFunnel` TRUE: an unbundled staging binary does not route real
    /// key events (the m23-bw wall), so the gate can only ever observe the false
    /// arm. That makes the ORDER of the bump — before any guard — unobservable
    /// from the wire, and it is the whole property: a keystroke the text-editing
    /// guard refuses WAS delivered, and a counter bumped after the guard would
    /// report it as never having arrived. This file is the only thing in the
    /// repo that can see it (`DAWApp` has no test target).
    @Test("the DELETE funnel counts its own runs, BEFORE any guard (m23-cf-3)")
    func funnelCounterIsBumpedFirst() {
        let app = Self.code(Self.appPath)
        guard let fn = Self.body(of: "handleDeleteKey", in: app) else {
            let missing = "could not find `func handleDeleteKey(` in \(Self.appPath) — a missing "
                + "function must never read as a clean pass"
            Issue.record("\(missing)")
            return
        }
        let why = "`handleDeleteKey` must bump `deleteKeyFunnelSeq`. It is the ONLY signal that "
            + "answers \"did a DELETE keystroke reach this app at all?\", which the `keyDelete` "
            + "probe reports as `keyReachedFunnel`. Without it the probe falls back to "
            + "`arrangeSelection.ids != before`, which is FALSE for a successful note delete."
        guard let bump = fn.range(of: "deleteKeyFunnelSeq += 1") else {
            Issue.record("\(why)")
            return
        }
        let order = "`deleteKeyFunnelSeq` must be bumped BEFORE `deleteKeyRouting` is read — i.e. "
            + "before any guard can refuse. A key the text-editing guard declines WAS delivered; "
            + "a counter bumped after the routing would report it as never having arrived, which "
            + "is exactly the conflation m23-cf-3 exists to remove."
        guard let routed = fn.range(of: "deleteKeyRouting") else {
            let gone = order + " — and `deleteKeyRouting` is no longer read here at all"
            Issue.record("\(gone)")
            return
        }
        #expect(bump.lowerBound < routed.lowerBound, "\(order)")

        // AND THE PROBE MUST READ IT AS A DELTA. The raw total counts SEAM-driven
        // funnel runs too (`act:"deleteKey"` IS the funnel), so a probe that
        // compared it against zero — or reported it bare as delivery — would count
        // a gate's own calls as key presses.
        guard let seam = Self.body(of: "arrangeSelectionDebug", in: app) else {
            Issue.record("could not find `func arrangeSelectionDebug(` in \(Self.appPath)")
            return
        }
        let delta = "`act:\"keyDelete\"` must compute its delivery verdict as a BEFORE/AFTER pair "
            + "around the synthesized event (`deleteKeyFunnelSeq != funnelBefore`). The raw total "
            + "also counts seam-driven runs, so reading it bare would report a gate's own "
            + "`act:\"deleteKey\"` calls as delivered keystrokes."
        #expect(seam.contains("let funnelBefore = deleteKeyFunnelSeq"), "\(delta)")
        #expect(seam.contains("deleteKeyFunnelSeq != funnelBefore"), "\(delta)")
    }

    @Test("`handleArrangeDeleteKey` survives as the ARRANGE BRANCH — the seam still drives a live path")
    func arrangeBranchIsStillLive() {
        // Kept deliberately rather than folded away. `debug.arrangeSelection
        // {act:"keyHandler"}` drives it, and existing gates prove the
        // text-editing guard through it; if it were reachable only from the seam
        // those gates would be proving a path the user never takes — the failure
        // `presentTrackClickAcknowledgement`'s doc calls out in another corner of
        // this app. `handleDeleteKey`'s `.arrangeClips` branch calling it is what
        // keeps that honest.
        let app = Self.code(Self.appPath)
        guard let fn = Self.body(of: "handleArrangeDeleteKey", in: app) else {
            Issue.record("could not find `func handleArrangeDeleteKey(` in \(Self.appPath)")
            return
        }
        for term in ["workspaceMode", "isModalPresented", "isArrangeTextEditingFocused",
                     "arrangeSelection.isEmpty", "deleteArrangeSelection()"] {
            #expect(fn.contains(term), "`handleArrangeDeleteKey` lost its `\(term)` guard/funnel")
        }
    }

    // MARK: - m23-ap p2-del — the note editor's refusal, wired end to end

    private static let pitchPanePath = "DAWApp/PitchEditor/PitchEditorView.swift"

    /// `DeleteKeyRoutingTests` proves the RULE (the pane open refuses ⌫ by name
    /// and swallows it). This proves the APP feeds that rule and obeys it —
    /// which no pure test can see, because `DAWApp` has no test target. Each leg
    /// names the one failure it exists to catch.
    @Test("the note editor's ⌫ refusal is wired end to end — the openness verdict in, the pane's hint out")
    func noteEditorRefusalIsWired() {
        let app = Self.code(Self.appPath)

        // 1. THE ONE HOME READS THE OPENNESS VERDICT — the one ⌘A's
        // `.pitchEditorOpen` arm reads — and nothing that can flip under it.
        guard let home = Self.closureBody(after: "var pitchEditorPaneOpen: Bool", in: app) else {
            let missing = "could not find `var pitchEditorPaneOpen: Bool` in \(Self.appPath) — if "
                + "it was renamed, RENAME IT HERE TOO; a missing home must never read as a pass"
            Issue.record("\(missing)")
            return
        }
        let verdict = "`pitchEditorPaneOpen` must be the OPENNESS verdict "
            + "(`openEditorSurface.reason == .pitchEditorOpen`, the m34-d ruling ⌘A reads) — a raw "
            + "`openPitchEditorClip != nil` drops the workspace term the router folds in"
        #expect(home.contains("openEditorSurface.reason == .pitchEditorOpen"), "\(verdict)")
        for banned in ["activeEditorSurface", "lastEngaged", "pianoRollEditorFocused", "isFocused",
                       "openPitchEditorClip"] {
            #expect(!home.contains(banned),
                    "`pitchEditorPaneOpen` reads `\(banned)` — the predicate is PANE OPEN, never engagement or focus (design P6)")
        }

        // 2. BOTH DOORS FEED IT — the key route AND Edit ▸ Delete. The policy
        // parameter has no default, so omitting it cannot compile; this catches
        // the other omission, a literal `false` passed "for now".
        for property in ["var deleteKeyRouting: DeleteMenuItem", "var deleteMenuItem: DeleteMenuItem"] {
            guard let body = Self.closureBody(after: property, in: app) else {
                Issue.record("could not find `\(property)` in \(Self.appPath)")
                continue
            }
            #expect(body.contains("pitchEditorOpen: pitchEditorPaneOpen"),
                    "`\(property)` does not pass the note-editor term from its one home — that door would still delete the vocal clip")
        }

        // 3. THE FUNNEL SWALLOWS ON THE POLICY'S WORD AND ASKS THE PANE TO SAY WHY.
        guard let funnel = Self.body(of: "handleDeleteKey", in: app) else {
            Issue.record("could not find `func handleDeleteKey(` in \(Self.appPath)")
            return
        }
        let swallow = "`handleDeleteKey` must return `routing.consumesKeystroke` for a refusal — "
            + "returning `false` hands the ⌫ back, the three `.onKeyPress` mounts re-run the funnel "
            + "and AppKit beeps"
        #expect(funnel.contains("return routing.consumesKeystroke"), "\(swallow)")
        let ask = "`handleDeleteKey` must bump `pitchEditorDeleteKeyNonce` on the `.pitchEditorOpen` "
            + "refusal — without it the key is swallowed in SILENCE, and a refusal that looks like "
            + "nothing happened is the failure the hint exists to prevent"
        #expect(funnel.contains("if routing.refusedBy == .pitchEditorOpen { pitchEditorDeleteKeyNonce &+= 1 }"),
                "\(ask)")

        // 4. THE MOUNT HANDS THE NONCE TO THE PANE.
        let content = Self.normalized(Self.code(Self.contentPath))
        #expect(content.contains("deleteKeyHintNonce: model.pitchEditorDeleteKeyNonce"),
                "`ContentView` does not pass the hint nonce to `PitchEditorView` — the pane would never hear it")

        // 5. THE PANE ANSWERS WITH THE MODEL'S NAMED WRITER. (That it claims no
        // ⌫ of its own is already pinned: `claimantCountIsPinned` walks
        // every file under `Sources/DAWApp`.)
        let pane = Self.code(Self.pitchPanePath)
        guard let answer = Self.closureBody(after: ".onChange(of: deleteKeyHintNonce)", in: pane) else {
            Issue.record("`PitchEditorView` does not watch `deleteKeyHintNonce` — the hint can never be drawn")
            return
        }
        #expect(answer.contains("model.refuseDeleteKey()"))

        // 6. THE HINT'S WAY OUT IS THE PANE'S OWN CLOSE CONTROL, BY THE WORDS
        // THAT CONTROL CARRIES. Rename the pane or its close help and this
        // reddens, instead of the hint quietly telling a novice to close a thing
        // the app no longer calls by that name.
        #expect(pane.contains(".help(\"Close the note editor\")"),
                "the pane's close control no longer reads \"Close the note editor\" — re-word `DeleteMenuPolicy.pitchEditorOpenHint` to match")
        #expect(DeleteMenuPolicy.pitchEditorOpenHint.contains("Close the note editor"))
    }

    // MARK: - m23-ap p2-del-2 — the same refusal on the CUT door

    /// `ClipboardMenuPolicyTests` proves the RULE (the pane open refuses Cut by
    /// name and leaves Copy alone). This proves the APP feeds that rule from
    /// the SAME home, re-resolves it at click time, and leaves the right-click
    /// escape hatch alone. That last point is the ruling's: "the right-click
    /// Cut stays working".
    @Test("the note editor's Cut refusal is wired — Edit ▸ Cut and ⌘X read the same openness verdict, the right-click Cut does not")
    func noteEditorCutRefusalIsWired() {
        let app = Self.code(Self.appPath)

        // 1. THE CUT DOOR FEEDS THE ONE HOME. `clipboardItem` resolves Edit ▸
        // Cut, and `ClipboardResponder.validateMenuItem` reads it for the native
        // item whose key equivalent is ⌘X. The parameter has no default, so
        // omitting it cannot compile; this catches a literal `false` passed
        // "for now".
        guard let item = Self.body(of: "clipboardItem", in: app) else {
            let missing = "could not find `func clipboardItem(` in \(Self.appPath) — if it was "
                + "renamed, RENAME IT HERE TOO; a missing door must never read as a pass"
            Issue.record("\(missing)")
            return
        }
        #expect(item.contains("pitchEditorOpen: pitchEditorPaneOpen"),
                "`clipboardItem` does not pass the note-editor term from its one home — ⌘X would still cut the vocal clip")

        // 2. THE CLICK RE-RESOLVES THROUGH THAT ITEM, so a menu drawn before the
        // pane opened still cannot cut under it.
        guard let perform = Self.body(of: "performMenuCut", in: app) else {
            Issue.record("could not find `func performMenuCut(` in \(Self.appPath)")
            return
        }
        #expect(perform.contains("switch cutMenuItem.surface"),
                "`performMenuCut` no longer re-resolves `cutMenuItem` at click time — a stale item could cut under the pane")

        // 3. THE ESCAPE HATCH STAYS OPEN. The clip's right-click Cut and Delete,
        // and the two actions they share with the menu, read no openness term.
        // A guard in any of these would lock the user out of removing the clip
        // on purpose while the note editor is open.
        for door in ["clipboardClipFromContextMenu", "deleteClipFromContextMenu",
                     "cutArrangeSelection", "deleteArrangeSelection"] {
            guard let body = Self.body(of: door, in: app) else {
                Issue.record("could not find `func \(door)(` in \(Self.appPath)")
                continue
            }
            for term in ["pitchEditorPaneOpen", "openEditorSurface", "openPitchEditorClip",
                         "cutMenuItem", "deleteMenuItem"] {
                #expect(!body.contains(term),
                        "`\(door)` reads `\(term)` — the right-click door is the ESCAPE HATCH and must stay live with the note editor open")
            }
        }

        // 4. THE ONE SENTENCE NAMES BOTH DOORS. ⌘X raises no hint of its own (a
        // greyed item runs no action, and the key-down monitor leaves ⌘ chords
        // to the menu), so the line ⌫ shows is the only place the app says why
        // ⌘X did nothing.
        #expect(DeleteMenuPolicy.pitchEditorOpenHint.contains("Cut"),
                "the note editor's hint no longer mentions Cut — nothing in the app would say why ⌘X does nothing")
    }

    // MARK: - m23-ap I4 — notes selected in the open note editor

    /// `DeleteKeyRoutingTests` proves the RULE (with notes selected in the open
    /// pane, ⌫ and Edit ▸ Delete are a LIVE Clear of the notes — the clip never
    /// the target — and the arm sits IN FRONT of p2-del's guard). This proves the
    /// APP feeds that rule from one home and hands BOTH doors to the pane, which
    /// no pure test can see. Each leg names the one failure it catches.
    ///
    /// ⚠️ RENAMED AND REWRITTEN at m23-ap I7b from "I4 — notes selected in the
    /// open note editor: ⌫ is theirs — one home, both doors, the funnel asks the
    /// pane" (`noteEditorSelectionRefusalIsWired`): the I4 funnel asked the pane
    /// from inside the REFUSAL arm (`if routing.refusedBy == .pitchEditorNotes`),
    /// and Edit ▸ Delete was greyed. Now it is a surface, dispatched by BOTH
    /// funnels, and the pane answers with the clear
    /// (`PitchEditorInteractionSiteTests` pins that half).
    @Test("I7b — notes selected in the open note editor: ⌫ and Edit ▸ Delete CLEAR them — one home, both doors, both funnels ask the pane")
    func noteEditorSelectionClearIsWired() {
        let app = Self.code(Self.appPath)

        // 1. THE ONE HOME: the pane is OPEN (p2-del's openness verdict,
        // verbatim) AND its bridge reports a selection — the
        // `pianoRollWouldConsumeKey` shape, never engagement or focus.
        guard let home = Self.closureBody(after: "var pitchEditorWouldConsumeKey: Bool", in: app) else {
            let missing = "could not find `var pitchEditorWouldConsumeKey: Bool` in \(Self.appPath) — if "
                + "it was renamed, RENAME IT HERE TOO; a missing home must never read as a pass"
            Issue.record("\(missing)")
            return
        }
        #expect(home.contains("pitchEditorPaneOpen && pitchEditorInteraction.hasNoteSelection"),
                "the ⌫ home must be PANE OPEN and the pane's own selection report, nothing else")
        for banned in ["activeEditorSurface", "lastEngaged", "pianoRollEditorFocused", "isFocused"] {
            #expect(!home.contains(banned),
                    "`pitchEditorWouldConsumeKey` reads `\(banned)` — the predicate is never engagement or focus (design P6)")
        }

        // 2. BOTH DOORS FEED IT — the key route AND Edit ▸ Delete. A literal
        // `false` passed "for now" compiles; this catches it.
        for property in ["var deleteKeyRouting: DeleteMenuItem", "var deleteMenuItem: DeleteMenuItem"] {
            guard let body = Self.closureBody(after: property, in: app) else {
                Issue.record("could not find `\(property)` in \(Self.appPath)")
                continue
            }
            #expect(body.contains("pitchEditorHasNoteSelection: pitchEditorWouldConsumeKey"),
                    "`\(property)` does not pass the notes term from its one home — ⌫ with notes selected would fall through to p2-del's close-the-editor line")
        }

        // 3. BOTH FUNNELS DISPATCH THE SURFACE TO THE PANE'S BRIDGE — the key's
        // and the Edit menu's. Each is a `case` of its surface switch, so the
        // compiler forces it; what this catches is a case that does something
        // ELSE (a refusal line, the arrange's delete, nothing).
        for funnelName in ["handleDeleteKey", "performMenuDelete"] {
            guard let funnel = Self.body(of: funnelName, in: app) else {
                Issue.record("could not find `func \(funnelName)(` in \(Self.appPath)")
                continue
            }
            guard let arm = funnel.range(of: "case .pitchEditorNotes:") else {
                Issue.record("`\(funnelName)` has no `case .pitchEditorNotes:` — the notes' Clear is not dispatched by that door")
                continue
            }
            let armBody = String(funnel[arm.upperBound...].prefix(220))
            #expect(armBody.contains("pitchEditorInteraction.requestDelete()"),
                    "`\(funnelName)`'s notes arm does not hand the ⌫ to the pane — the Clear would never run")
            // It is a SURFACE now: nothing may still treat it as I4's refusal.
            #expect(!funnel.contains("refusedBy == .pitchEditorNotes"),
                    "`\(funnelName)` still reads the retired `.pitchEditorNotes` REFUSAL")
        }
        // The key funnel still swallows a refusal on the policy's word (p2-del's
        // open-pane refusal is the one left that consumes).
        if let funnel = Self.body(of: "handleDeleteKey", in: app) {
            #expect(funnel.contains("return routing.consumesKeystroke"))
        }

        // 4. THE WORDS. I4's refusal sentence is retired with its refusal: the
        // pane no longer answers ⌫ with a line, it clears. The one line left on
        // this path is the all-already-cleared one, and it points at Restore.
        let policy = Self.code("DAWAppKit/DeleteMenuPolicy.swift")
        #expect(!policy.contains("pitchEditorNotesHint"),
                "`DeleteMenuPolicy.pitchEditorNotesHint` outlived the refusal it explained")
    }
}
