import Foundation
import Testing

/// m28-knob-ui — **the source-shape half of "opening the breath pad must not
/// bring the CoreMIDI client up."**
///
/// ## Why a site test, when a behavioural one already exists
///
/// `BreathPadHardwareModelTests.openingThePanelIsQuiet` drives the appear path
/// against a spy engine and proves the MODEL asks nothing. It cannot prove the
/// same of the VIEW: `DAWApp` is an `executableTarget` with no test target, so
/// nothing in this repo can instantiate `BreathPadHardwareSection` or evaluate
/// its body. A view that called `store.listMIDIInputs()` in an `onAppear` would
/// leave that behavioural test perfectly green.
///
/// What makes the pair sufficient is that the view was **designed so the
/// assertion is structural**: it takes a `BreathPadHardwareModel` and nothing
/// else, and that model holds closures rather than a `ProjectStore`. If the
/// panel files contain no route to the client-waking calls, and the model asks
/// nothing, then opening the panel cannot wake the client. This file pins the
/// first half.
///
/// ## The calls that are forbidden here, and why each one is dangerous
///
/// | call | what it does the moment it runs |
/// |---|---|
/// | `armMIDIControlLearn` | `refreshSubscription` → `setControlChangeObserver` → **creates the CoreMIDI client and connects to every online source** |
/// | `availableMIDIInputs` | **creates the same client** by a second route (it is the lazy bring-up trigger) |
/// | `listMIDIInputs` | `ProjectStore`'s wrapper for the above |
/// | `setControlChangeObserver` | the observer install itself |
///
/// ⚠️ **THE ONE PLACE THEY ARE ALLOWED IS THE APP'S WIRING**, where they sit
/// behind closures the LEARN button calls. That is why this file scans the three
/// panel files and not `DAWProApp.swift`.
///
/// Same idiom as `HumanizePanelSiteTests` / `DeleteKeySiteTests`: anchored to
/// the repo via `#filePath`, **comments stripped** so prose about a symbol
/// cannot satisfy an assertion about code — every file here discusses these
/// calls at length, and without stripping, the doc comments alone would fail
/// every check. Every extractor is POSITIVE-CONTROLLED, because a broken
/// path/matcher and a genuinely clean file produce the identical green.
@Suite("Breath pad hardware section — quiet until LEARN (m28-knob-ui)")
struct BreathPadHardwareSiteTests {

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

    /// Comments removed. **Load-bearing here more than anywhere**: all three
    /// files name every forbidden call in their doc comments, precisely because
    /// the rule is worth explaining. Without stripping, this suite would fail on
    /// its own documentation.
    private static func codeOnly(_ content: String) -> String {
        content.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let raw = String(line)
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                return ""
            }
            return raw.range(of: "//").map { String(raw[..<$0.lowerBound]) } ?? raw
        }.joined(separator: "\n")
    }

    private static func code(_ relativePath: String) -> String {
        codeOnly(text(relativePath))
    }

    /// The three files that make up the panel. `DAWProApp.swift` is deliberately
    /// NOT here: it is where the closures are wired, and it is allowed — indeed
    /// required — to name these calls.
    private static let panelFiles = [
        "DAWApp/BreathPad/BreathPadHardwareSection.swift",
        "DAWApp/BreathPad/BreathPadView.swift",
        "DAWApp/Components/MIDIMappingRow.swift",
    ]

    // MARK: - The positive control, first

    /// ⚠️ A grep that cannot match anything reports the cleanest possible green.
    /// Before asserting any ABSENCE, show that this exact path + reader +
    /// stripper can find things that ARE there.
    @Test("positive control: the files are found, read, and stripped correctly")
    func positiveControl() {
        for path in Self.panelFiles {
            let raw = Self.text(path)
            #expect(!raw.isEmpty, "read nothing from \(path)")
        }
        let section = Self.code(Self.panelFiles[0])
        #expect(section.contains("BreathPadHardwareSection"),
                "the extractor cannot even find the type it is scanning")
        #expect(section.contains("hardware.toggleLearn"),
                "the extractor cannot find the LEARN action")
        // And the stripper really strips: the header discusses `onAppear` at
        // length, and the code contains none. If this fails, every absence
        // below is being asserted against uncommented prose.
        #expect(Self.text(Self.panelFiles[0]).contains("onAppear"),
                "the doc comment that this test relies on has been reworded")
        #expect(!section.contains("onAppear"),
                "the comment stripper is not stripping")
    }

    // MARK: - ⛔⛔ The rule

    /// **No panel file may name a call that brings the CoreMIDI client up.**
    ///
    /// This is what makes the design's safety structural rather than a promise:
    /// there is no route from a body evaluation to the user's hardware.
    @Test("no panel file can reach a call that wakes CoreMIDI")
    func panelCannotWakeCoreMIDI() {
        let forbidden = [
            "armMIDIControlLearn",
            "availableMIDIInputs",
            "listMIDIInputs",
            "setControlChangeObserver",
        ]
        for path in Self.panelFiles {
            let source = Self.code(path)
            for call in forbidden {
                #expect(!source.contains(call), """
                    \(path) names `\(call)` in CODE. That call creates the CoreMIDI \
                    client and connects to every online source on the user's desk, and \
                    it must follow from the user pressing LEARN — never from a panel \
                    appearing. Wire it through a closure in DAWProApp instead.
                    """)
            }
        }
    }

    /// **No panel file holds a `ProjectStore`.** A view that could reach the
    /// store could reach `listMIDIInputs()` next week without touching this
    /// file's forbidden list — so the containment is asserted at the type level
    /// too, not only call by call.
    @Test("no panel file takes a ProjectStore")
    func panelHoldsNoStore() {
        for path in Self.panelFiles {
            let source = Self.code(path)
            #expect(!source.contains("ProjectStore"), """
                \(path) mentions `ProjectStore` in CODE. The breath pad's panel takes \
                values and closures; a store reference is a route to the MIDI client \
                that no forbidden-call list can keep closed.
                """)
        }
    }

    /// **No `onAppear` anywhere on the panel.** The rule is about a panel
    /// APPEARING, so the lifecycle hook that fires on exactly that is barred
    /// outright — cheaper to keep out than to audit each time.
    @Test("the panel has no onAppear / task lifecycle hook at all")
    func panelHasNoAppearHook() {
        for path in Self.panelFiles {
            let source = Self.code(path)
            #expect(!source.contains("onAppear"), "\(path) has an onAppear")
            #expect(!source.contains(".task"), "\(path) has a .task modifier")
        }
    }

    // MARK: - The section is actually wired in

    /// A quiet panel that is never shown would pass everything above. These
    /// pin that the section EXISTS on the card and that the app hands it the
    /// model — the m26-i lesson: verified, never seen.
    @Test("the hardware section is on the card, and the app hands it a model")
    func sectionIsReachable() {
        let card = Self.code("DAWApp/BreathPad/BreathPadView.swift")
        #expect(card.contains("BreathPadHardwareSection(hardware: hardware)"))
        #expect(card.contains("hardwareExpanded: hardwareExpanded"),
                "the height budget is not being told whether the section is open")
        let content = Self.code("DAWApp/ContentView.swift")
        #expect(content.contains("hardware: model.breathPadHardware"),
                "ContentView does not hand the panel its hardware model")
    }

    // MARK: - The section must be ONE height, not a sample of one state

    /// ⛔⛔ **`hardwareExpandedChrome` IS A SINGLE NUMBER MEASURED IN A SINGLE
    /// STATE, SO THE SECTION HAS TO BE A SINGLE HEIGHT.**
    ///
    /// The first version of this section was not. The feed line's longest
    /// variant wraps to two lines while the other two fit on one, and FORGET ALL
    /// MAPPINGS appeared only once something was bound — so the state that was
    /// measured was the state the panel leaves the moment the feature is used.
    /// That is the m28-p7 defect by another road: the budget says it fits, the
    /// card draws taller, the overhang lands on WRITE THE SHAPE, and every unit
    /// test stays green because they all consume the same constant. The scroll
    /// cascade hides it on this display, so no capture can find it either.
    ///
    /// The render probe compares the section's own reported height across four
    /// bound/inverted states. That leaves ONE state the probe cannot reach,
    /// because this round deliberately added no wire verb for it: an **armed
    /// learn**. So the armed state is held invariant STRUCTURALLY — every branch
    /// of the row's status is `lineLimit(1)`, and so is the header summary — and
    /// that is what this test pins. Without it, someone drops the line limit,
    /// "TURN A KNOB" wraps on a narrow card, and the section is a different
    /// height in exactly the state a human is looking at it hardest.
    @Test("every status branch is lineLimit(1), so arming cannot change a height")
    func armedStateCannotChangeHeight() {
        let row = Self.code("DAWApp/Components/MIDIMappingRow.swift")
        // Positive control: the strings this test reasons about are really here.
        #expect(row.contains("TURN A KNOB"))
        #expect(row.contains("NOT MAPPED"))
        // Counted, not matched positionally. FIVE texts live in the row's single
        // status line — `name`, `TURN A KNOB`, `controllerLabel`, `deviceLabel`,
        // `NOT MAPPED` — and every one of them must be single-line. (The row's
        // `summary` below is deliberately NOT counted: it is allowed to wrap,
        // because it is fixed per target and so cannot vary with state.)
        //
        // ⭐ This assertion was written at `>= 5` from the RULE and went red at 4
        // against the code — `controllerLabel` had no limit. The fix was to add
        // the modifier, not to lower the number to what the code happened to do.
        // A site test edited down to whatever it found is a test that can only
        // ever agree with the source it reads.
        let limits = row.components(separatedBy: ".lineLimit(1)").count - 1
        #expect(limits >= 5, """
            MIDIMappingRow has \(limits) `.lineLimit(1)` modifiers; all 5 texts in the \
            status line need one (name, TURN A KNOB, controllerLabel, deviceLabel, \
            NOT MAPPED). A status branch that can WRAP makes the section a different \
            height in the armed state than in the one `hardwareExpandedChrome` was \
            measured in.
            """)
        let section = Self.code("DAWApp/BreathPad/BreathPadHardwareSection.swift")
        #expect(section.contains("hardwareFeedReservation"), """
            The footer's feed line is not reserving its worst case. It has three variants \
            and the longest wraps to two lines, so without the reservation the section is \
            one height when nothing is mapped and another when something is.
            """)
        // The destructive button is PRESENT-BUT-DISABLED rather than conditional
        // — the destructive-action rule and the height budget agreeing.
        #expect(!section.contains("if state.boundCount > 0 {"), """
            FORGET ALL MAPPINGS is conditional again. That changes the section's height \
            at runtime, and it hides the escape hatch until after the user needs it.
            """)
        #expect(section.contains(".disabled(state.boundCount == 0)"))
    }

    /// ⛔⛔ **THE SCROLL INSTRUMENT, PINNED — because the probe check that uses
    /// it CANNOT SEE IT BREAK.**
    ///
    /// The probe does `debug.breathPad {scrollTo:"bottom"}`, captures, and checks
    /// `r.ok`. But `r.ok` means *the capture succeeded*, not *the card scrolled*:
    /// break the anchor id to a typo and `scrollTo` silently matches nothing,
    /// the capture still succeeds, and the check stays green over exactly the
    /// photograph-of-an-absence the instrument was built to prevent. **Planted
    /// and confirmed: nothing goes red.** That is the finding, not a surprise —
    /// a `ScrollViewReader` has no failure mode to observe, and no wire response
    /// carries a scroll offset.
    ///
    /// So the realistic failure — a rename that decouples the three parts — is
    /// pinned as source shape instead. This is the only gate on the instrument.
    @Test("the scroll-to-bottom instrument's three parts still refer to each other")
    func scrollInstrumentIsWiredEndToEnd() {
        let card = Self.code("DAWApp/BreathPad/BreathPadView.swift")
        // Positive control: this extractor can find things in this file.
        #expect(card.contains("ScrollView(.vertical)"), "the card's scroller is gone")
        #expect(card.contains("ScrollViewReader"), """
            The card's scroller is no longer instrumented. With the hardware section \
            expanded the card is taller than the tallest window this display grants, so \
            its bottom cannot be photographed without this — and a plain capture of the \
            window then PASSES while showing none of the section.
            """)
        #expect(card.contains("scrollTo(BreathPadView.bottomAnchor"),
                "the reader no longer targets the anchor constant")
        #expect(card.contains(".id(BreathPadView.bottomAnchor)"), """
            The anchor is not attached to the card's last row. `scrollTo` an id that is \
            not in the hierarchy is a SILENT no-op — no error, no log, and the probe's \
            capture check goes right on passing.
            """)
        #expect(card.contains("model.scrollToBottomRequest"),
                "the scroller no longer observes the request counter")
        let app = Self.code("DAWApp/DAWProApp.swift")
        #expect(app.contains("scrollToBottomRequest"), """
            `debug.breathPad {scrollTo:"bottom"}` no longer bumps the counter, so the \
            probe's scroll step does nothing and its captures silently revert to \
            photographing the top of a card whose new content is at the bottom.
            """)
    }

    /// ⛔ The app's wiring is the ONE place the waking calls live, and it must
    /// keep living there — a `breathPadHardware` built without `arm:` would
    /// compile and leave LEARN doing nothing at all.
    @Test("the app wires arm/cancel/setBindings/readBack, and syncs on open")
    func appWiresTheClosures() {
        let app = Self.code("DAWApp/DAWProApp.swift")
        #expect(app.contains("BreathPadHardwareModel("))
        // ⚠️ Matched on the CALL, not on a transcription of the call site. The
        // first draft of this test asserted `store.armMIDIControlLearn(target:
        // $0)` and went red against a working wiring that spells it
        // `store?.armMIDIControlLearn(target: target)` — a site test that
        // encodes one formatting of the code it reads is a maintenance trap that
        // fails on a rename of a closure parameter.
        #expect(app.contains("armMIDIControlLearn(target:"))
        #expect(app.contains("cancelMIDIControlLearn()"))
        #expect(app.contains("setMIDIControlBindings("))
        #expect(app.contains("breathPadHardware.sync()"),
                "the panel would open showing a stale table")
        #expect(app.contains("mapChangedHandler"),
                "an agent's `midi.setControlMap` would not reach an open panel")
        // An armed learn is modal-scoped: closing the pad must disarm it, or the
        // next stray controller nudge silently re-points the pad with nothing on
        // screen saying so.
        #expect(app.contains("breathPadHardware.cancelLearn()"))
    }
}
