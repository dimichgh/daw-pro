import Foundation
import Testing

/// m23-ap Phase 2 — **THE PRESET DOOR IS ACTUALLY CLICKABLE, AND ACTUALLY
/// BOUND.**
///
/// The preset actions existed as data (`PitchCorrectionPreset`), as a store op
/// (`ProjectStore.autoCorrectClipPitch`), as a wire verb
/// (`clip.autoCorrectPitch`) and as an MCP tool — and as nothing a person could
/// click. This suite pins the click.
///
/// ⚠️⚠️ `Sources/DAWApp` has no test target, and this door's failure mode is the
/// quiet one: a `Button` wired to a closure whose default is `{ _ in }` draws
/// perfectly, highlights perfectly, dismisses the menu perfectly and does
/// NOTHING — a plausible-looking valid answer, which is this tree's
/// characteristic failure rendered in pixels. Nothing in a build, a warning
/// count or a headless test would say so.
///
/// `PadGridSiteTests`' shape verbatim, including the rule that matters most
/// here: assertions run against **comment-stripped** source, because the menu
/// entry below documents its own wiring in prose that would satisfy a naive
/// grep — including the literal words `allCases` and `offeredInUI`, which one
/// assertion here is specifically about.
@Suite("Tune Vocal door wiring (m23-ap Phase 2)")
struct PitchTuneDoorSiteTests {

    // MARK: - Source access (PadGridSiteTests' reader, verbatim)

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

    private static func code(_ relativePath: String) -> String {
        let url = sourcesDir().appendingPathComponent(relativePath)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("Could not read \(relativePath) under \(sourcesDir().path)")
            return ""
        }
        return content.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                return ""
            }
            return line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
        }.joined(separator: "\n")
    }

    /// ⭐ **THE POSITIVE CONTROL FOR THE WHOLE SUITE.** Every assertion below is
    /// a `contains` over stripped source, and a stripper that returned "" would
    /// make each of them fail loudly — but a PATH typo would too, and for a
    /// different reason. This proves the reader reaches real code first, and
    /// that it really does strip.
    @Test("the source reader reaches real code (positive control)")
    func readerWorks() {
        let strip = Self.code("DAWApp/PitchCorrectionStaging.swift")
        #expect(strip.contains("extension AppModel"))
        #expect(strip.count > 500)
        // These phrases exist ONLY in comments there.
        #expect(strip.contains("leaves their selection theirs") == false)
        #expect(strip.contains("only the pixels have no room to explain") == false)
        // ⚠️ THIS IS NOT A BAD-PATH PROBE, AND THE `PadGridSiteTests` LINE IT WAS
        // COPIED FROM CLAIMED TO BE ONE WHILE RE-READING THE SAME FILE. A real
        // negative control would read a path that does not exist — which
        // `code(_:)` answers by calling `Issue.record`, i.e. by failing this
        // test, so it cannot be asserted here without `withKnownIssue`. What
        // this second read actually shows is that the reader is deterministic:
        // the same path twice gives the same non-empty answer. Said plainly,
        // because a suite whose whole thesis is that prose lies must not open
        // with prose that does.
        #expect(Self.code("DAWApp/PitchCorrectionStaging.swift").count > 500)
    }

    // MARK: - What the menu draws

    @Test("⛔ the Tune Vocal entry exists, is AUDIO-ONLY, and sits OUTSIDE the Pro block")
    func tuneVocalIsInTheClipMenuAndNotProGated() {
        let lanes = Self.code("DAWApp/Timeline/TimelineLanesView.swift")

        #expect(lanes.contains("Menu(\"Tune Vocal\")"))
        #expect(lanes.contains("Button(preset.displayName) { onTuneVocal(preset) }"))
        #expect(lanes.contains("onTuneVocal: { preset in onTuneVocal(clip, preset) }"))

        // AUDIO ONLY, and hidden rather than offered-then-errored (design §6.5:
        // "no preset chip on a MIDI clip, even greyed"). It SHARES Chop to Pads'
        // gate, so this is the same literal predicate that entry already had.
        #expect(lanes.contains("if !clip.isMIDI, clip.audioFileURL != nil {"))

        // ⛔ THE LOAD-BEARING ONE: the entry must sit BEFORE the `if pro {`
        // block, or it vanishes in the density built for beginners — the exact
        // shape of the bug m23-cf fixed for Delete, and design §6.2's explicit
        // instruction ("tuning a vocal is not expert chrome").
        // ⚠️ Anchored INSIDE `contextMenu`: `if pro {` appears several times in
        // this 4k-line view, and comparing against the first one in the file
        // measures a position in an unrelated builder and "passes" nothing.
        let menuStart = try! #require(
            lanes.range(of: "private var contextMenu: some View {"))
        let menu = String(lanes[menuStart.upperBound...])
        let entry = try! #require(menu.range(of: "Menu(\"Tune Vocal\")"))
        let proBlock = try! #require(menu.range(of: "\n        if pro {"))
        #expect(entry.lowerBound < proBlock.lowerBound,
                "Tune Vocal fell inside the Pro-only block — invisible in Simple, which is the density the beginner who most needs a one-click tuning is in")
    }

    /// ⛔ **THREE, NOT FOUR — and the list is READ, never retyped.**
    ///
    /// `PitchCorrectionPreset.offeredInUI` is `[.gentle, .natural, .tight]`
    /// today and `allCases` is four. A view drawing `allCases` would offer Hard
    /// Tune, which the render path cannot honour (it calls
    /// `StretchCurvePlan.make` with `contour: []`, so the only preset that flips
    /// `preserveVibrato` degrades to a constant per-note offset — a control
    /// whose label promises one result and whose mechanism delivers another).
    /// A view retyping the three as literals would keep offering three on the
    /// day the property is removed.
    ///
    /// `PitchCorrectionPresetTests.uiDoorWithholdsHardTune` pins the VALUE of
    /// the list and the reason it exists; this pins that the pixels read it.
    @Test("⛔ the menu draws offeredInUI — three presets, not allCases' four")
    func theMenuDrawsOfferedInUINotAllCases() {
        let lanes = Self.code("DAWApp/Timeline/TimelineLanesView.swift")
        #expect(lanes.contains("ForEach(PitchCorrectionPreset.offeredInUI)"))
        #expect(lanes.contains("PitchCorrectionPreset.allCases") == false,
                "the clip menu is drawing every preset — Hard Tune would be offered, and the render path cannot produce it")
        // And no hand-typed twin of the list: the three names must NOT appear as
        // literal button labels beside the ForEach.
        #expect(lanes.contains("Button(\"Hard Tune\")") == false)
        #expect(lanes.contains("Button(\"Gentle\")") == false,
                "the presets are typed out as literal buttons — the list has a second home and they will disagree")
    }

    @Test("⛔ each preset carries its own novice sentence, and Remove Tuning is offered only when there IS tuning")
    func labelsAndRemoveTuningAreHonest() {
        let lanes = Self.code("DAWApp/Timeline/TimelineLanesView.swift")
        // Design §6.1: "use these strings verbatim" — the label is the preset's
        // own `displayName` and the tooltip its own `summary`, never re-worded
        // at the draw site.
        #expect(lanes.contains(".help(preset.summary)"))
        // Offered ONLY when the clip carries edits. A "Remove Tuning" over a
        // never-tuned clip is a control whose only possible outcome is nothing
        // happening — and, until the note view lands, its presence is the one
        // thing on screen that says the tuning took.
        #expect(lanes.contains("if clip.pitchEdits != nil {"))
        #expect(lanes.contains("Button(\"Remove Tuning\") { onClearPitchEdits() }"))
    }

    // MARK: - What the menu calls

    @Test("⛔ the door calls the store method the WIRE calls — no parallel path, no second policy")
    func theDoorUsesTheWiresOwnFunnel() {
        let staging = Self.code("DAWApp/PitchCorrectionStaging.swift")
        #expect(staging.contains("func tuneVocalFromContextMenu(clipID: UUID, preset: PitchCorrectionPreset)"))
        #expect(staging.contains("func clearClipTuningFromContextMenu(clipID: UUID)"))

        // ⭐ ONE STORE METHOD (design §6.2). Not a re-implementation of the
        // policy, not a hand-built PitchAutoCorrectOptions: the preset's OWN
        // `options()`, whose scale defaults to chromatic — which is exactly what
        // `clip.autoCorrectPitch` builds when no key is named.
        #expect(staging.contains("self.store.autoCorrectClipPitch("))
        #expect(staging.contains("options: preset.options()"))
        #expect(staging.contains("store.clearClipPitchEdits(clipId: clipID)"))
        // No second scale resolution in the view tier.
        #expect(staging.contains("PitchCorrectionScale") == false,
                "the app tier is resolving a scale — design §6.2 puts that in the store so all three doors inherit one answer")
        #expect(staging.contains("PitchAutoCorrectOptions(") == false,
                "the app tier is building its own options — the preset's own options() is the only home for those numbers")
    }

    @Test("⛔ a refusal is SHOWN, and a success that did nothing is shown too")
    func refusalsAndSilentSuccessesReachTheUser() {
        let staging = Self.code("DAWApp/PitchCorrectionStaging.swift")
        // `try?` here would turn engineUnavailable, a file that vanished, a comp
        // member and a clip deleted mid-detection into a click that does nothing
        // and says nothing.
        #expect(staging.contains("try? store.") == false)
        #expect(staging.contains("try? self.store.") == false)
        #expect(staging.contains("presentArrangeSplitRefusal(error, clipID: clipID)"))
        // ⛔ AND THE SILENT SUCCESS. `autoCorrectClipPitch` returns normally with
        // `pitchEdits == nil` when the detector found no voiced runs at all. A
        // door that only handled `catch` would show nothing for the single most
        // likely disappointing outcome: tuning an instrumental.
        #expect(staging.contains("if clip.pitchEdits == nil {"),
                "a correction that found nothing to correct returns normally — without this branch the user clicks Natural on an instrumental and the app says nothing at all")
    }

    // MARK: - The binding

    /// ⛔⛔ **THE ASSERTION THE REST OF THIS SUITE CANNOT MAKE: THE BUTTON IS
    /// PLUGGED IN.**
    ///
    /// `TimelineLanesView.onTuneVocal` / `onClearPitchEdits` follow the
    /// `onChopToPads` precedent, which means they default to a no-op closure.
    /// That default is the right shape for previews and headless callers and the
    /// WRONG shape to ship: unbound, the menu entry draws, highlights, dismisses
    /// and does nothing — and every other assertion in this file passes anyway,
    /// because every other assertion is about a file that is not `ContentView`.
    ///
    /// This test was written RED, on purpose, while `ContentView.swift` was
    /// owned by a concurrent agent: the two lines below did not exist yet and
    /// the failure message named them verbatim. They landed. Keep the message
    /// that way — the next person to delete the binding should be handed the
    /// patch, not a diff.
    @Test("⛔ ContentView binds the door to the AppModel funnels — without this the menu entry does nothing")
    func contentViewBindsTheDoor() {
        let content = Self.code("DAWApp/ContentView.swift")
        #expect(content.contains("model.openChopToPads(clipID: clip.id)"),
                "POSITIVE CONTROL FAILED: this reader cannot even see the binding NEXT to the missing one, so the assertions below would fail for the wrong reason")
        #expect(content.contains("model.tuneVocalFromContextMenu(clipID: clip.id, preset: preset)"),
                "ContentView does not bind onTuneVocal — the Tune Vocal menu entry draws and does NOTHING. Add `onTuneVocal: { clip, preset in model.tuneVocalFromContextMenu(clipID: clip.id, preset: preset) },` to the TimelineLanesView( call, beside onChopToPads.")
        #expect(content.contains("model.clearClipTuningFromContextMenu(clipID: clip.id)"),
                "ContentView does not bind onClearPitchEdits — Remove Tuning draws and does NOTHING. Add `onClearPitchEdits: { clip in model.clearClipTuningFromContextMenu(clipID: clip.id) },` to the TimelineLanesView( call, beside onChopToPads.")
        #expect(content.contains("model.openPitchEditor(clipID: clip.id)"),
                "ContentView does not bind onOpenPitchEditor — the note editor pane exists and NOTHING CAN OPEN IT. Add `onOpenPitchEditor: { clip in model.openPitchEditor(clipID: clip.id) },` to the TimelineLanesView( call.")
    }

    /// ⭐ THE PANE SHIPPED WITH NO WAY IN, AND THAT IS WHY THIS TEST EXISTS.
    /// p2-b built and rendered the whole note-editor surface;
    /// `AppModel.openPitchEditor(clipID:)` was written and waiting; the ONLY
    /// missing piece was one `Button` in a file that agent had been told to
    /// stay out of. **A capability nobody can reach is indistinguishable from
    /// one that was never built** — it reads as "the editor is not done" in
    /// every summary after it, including to the people who built it.
    ///
    /// This walks the whole chain, because a break at ANY link is the same
    /// silent nothing on screen: the menu item, the `ClipBlock` seam, the
    /// outer `TimelineLanesView` parameter, and the pass-through between them.
    @Test("the note editor has a human door, end to end")
    func noteEditorIsReachable() {
        let lanes = Self.code("DAWApp/Timeline/TimelineLanesView.swift")
        #expect(lanes.contains("Menu(\"Tune Vocal\")"),
                "POSITIVE CONTROL FAILED: this reader cannot see the menu that holds the item, so the assertions below would fail for the wrong reason")
        #expect(lanes.contains("Button(\"Open Note Editor…\") { onOpenPitchEditor() }"),
                "no menu item opens the note editor — the pane can only be reached by a wire command")
        #expect(lanes.contains("var onOpenPitchEditor: (_ clip: Clip) -> Void = { _ in }"),
                "TimelineLanesView has no onOpenPitchEditor parameter, so ContentView cannot bind one")
        #expect(lanes.contains("onOpenPitchEditor: { onOpenPitchEditor(clip) },"),
                "ClipBlock's onOpenPitchEditor is never passed through from TimelineLanesView — the button draws and does nothing")
    }
}
