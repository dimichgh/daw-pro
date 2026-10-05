import AppKit
import Foundation
import Testing
@testable import DAWAppKit
import DAWCore

/// m39-ag — **the discrete CHOICE params, and the census that keeps them off the
/// knob.**
///
/// ## The defect this suite was filed for
///
/// The `.dynamicEQ` insert card was captured on staging and READ. It labels
/// `band1Mode` **`LISTEN`** and draws a rotary knob whose readout is **`0.00`**.
/// That param is a three-way switch — 0 off, 1 above, 2 below — and it is the
/// single most important control in the effect: from the card a user could not
/// tell which of the three it was. Four of them appear on that one card.
///
/// The mechanism was a missing arm. `EffectEditorOverlay`'s per-param dispatch
/// ran toggle → slope → division → syncedTime → **knob**, with no choice arm, so
/// every discrete param fell through to `knobCell`. The snapped truth already
/// existed on the wire (`fx.add` / `fx.setParam` echo `band1ModeLabel` …
/// `band4ModeLabel` as `"off"`/`"above"`/`"below"`); only the card did not show it.
///
/// ## The three legs, and why they are different questions
///
/// 1. `choiceLabelsAgreeWithTheSnap` — for every choice param × every legal
///    value, the label the card draws is the one the KIND'S OWN snapping
///    function in `DAWCore` selects. Table-driven, with the literal spellings
///    pinned so a re-wording is visible.
/// 2. `everyDiscreteParamAvoidsTheKnob` — the CENSUS, and the leg that can
///    actually catch the next one. It derives "which params are discrete" from
///    `EffectParamSpec.modulatable == .refused`, a field maintained in
///    `Modulation.swift` for a completely unrelated reason, and asserts every
///    one of them reaches a non-knob arm. **It must never be rewritten in terms
///    of `isChoiceParam`** — that is the m32-e trap documented on
///    `EffectEditorModel.isToggleParam`, where the pinning test restated the
///    source expression and two binary params shipped as knobs with the suite
///    green.
/// 3. `choiceChipLabelsFitTheCell` — the chip uses `.fixedSize()`, so an
///    over-long label OVERFLOWS the 94 pt cell rather than truncating. The
///    `InsertLabelBudgetTests` arithmetic idiom holds the budget instead.
@Suite("m39-ag effect choice params")
@MainActor
struct EffectChoiceParamTests {

    /// Every built-in (non-AU) kind — AU params are not on this surface (M3 vi-b).
    private static let builtInKinds = EffectDescriptor.Kind.allCases.filter { $0 != .audioUnit }

    private static func spec(_ kind: EffectDescriptor.Kind, _ name: String) -> EffectParamSpec {
        EffectParamSpec.specs(for: kind).first { $0.name == name }!
    }

    // MARK: - Leg 1: the label is the SNAP's own answer

    /// The table. Each row is (kind, param, [(raw value written, label drawn)]),
    /// and the raw values deliberately include OFF-GRID numbers — 0.4, 1.7, 3,
    /// 5 — because `fx.setParam` CLAMPS these without rounding (the documented
    /// `phaser.stages` precedent), so a stored 0.4 is a real reachable state and
    /// the card must name what is in force, not what is in the field.
    @Test("every choice param × every legal value draws the snapped setting's name")
    func choiceLabelsAgreeWithTheSnap() {
        let table: [(EffectDescriptor.Kind, String, [(Double, String)])] = [
            // ⭐ THE REPORTED DEFECT. Was a knob reading "0.00".
            (.dynamicEQ, "band1Mode", [(0, "Off"), (1, "Above"), (2, "Below"),
                                       (0.4, "Off"), (1.6, "Below"), (-5, "Off"), (99, "Below")]),
            (.dynamicEQ, "band2Mode", [(0, "Off"), (1, "Above"), (2, "Below")]),
            (.dynamicEQ, "band3Mode", [(0, "Off"), (1, "Above"), (2, "Below")]),
            (.dynamicEQ, "band4Mode", [(0, "Off"), (1, "Above"), (2, "Below")]),
            // The de-esser's mode — 0 off, 1 band-pass, 2 high-pass. Out of
            // range CLAMPS rather than falling back to off (deliberate; see
            // `CompressorParams.detectorMode(at:)`).
            (.compressor, "detectorMode", [(0, "Off"), (1, "Band-Pass"), (2, "High-Pass"),
                                           (1.4, "Band-Pass"), (99, "High-Pass")]),
            (.clipper, "mode", [(0, "Hard"), (1, "Soft"), (0.4, "Hard"), (0.6, "Soft")]),
            // 1/2/4 only, and ⚠️ 3 rounds UP to 4 — the tie is broken upward on
            // purpose so an agent gets more alias rejection than it asked for.
            (.clipper, "oversampling", [(1, "1×"), (2, "2×"), (4, "4×"),
                                        (1.5, "2×"), (3, "4×")]),
            (.saturator, "oversampling", [(1, "1×"), (2, "2×"), (4, "4×"),
                                          (1.5, "2×"), (3, "4×")]),
            (.ringMod, "waveform", [(0, "Sine"), (1, "Triangle"), (2, "Square"), (3, "Saw"),
                                    (1.7, "Square")]),
            // Even-only 2…12, and an odd input is an exact tie that goes UP.
            (.phaser, "stages", [(2, "2"), (4, "4"), (6, "6"), (8, "8"), (10, "10"), (12, "12"),
                                 (5, "6"), (9, "10")]),
            (.hallReverb, "freeze", [(0, "Off"), (1, "Hold"), (0.4, "Off"), (0.5, "Hold")]),
        ]

        var checked = 0
        for (kind, name, rows) in table {
            let spec = Self.spec(kind, name)
            #expect(EffectEditorModel.isChoiceParam(spec),
                    "\(kind).\(name) is in the label table but is not routed to the choice cell")
            for (raw, expected) in rows {
                let drawn = EffectEditorModel.choiceLabel(value: raw, spec: spec)
                #expect(drawn == expected,
                        "\(kind).\(name) at \(raw) drew \"\(drawn)\", expected \"\(expected)\"")
                // The card's READOUT path must agree with the chip — the knob
                // formatter used to answer "0.00" / "0 %" here.
                let readout = EffectEditorModel.readout(value: raw, spec: spec)
                #expect(readout == (expected, ""),
                        "\(kind).\(name) readout at \(raw) was \(readout)")
                checked += 1
            }
        }
        // Non-vacuity: a table that silently emptied would pass every loop above.
        // ⚠️ 52 is MEASURED, not counted by hand — the first draft asserted 56
        // from a hand tally and this line failed on the first run. An unmeasured
        // number is not a measured one, even in a test.
        #expect(checked == 52, "the label table covered \(checked) (kind, value) pairs")
        print("[measured] choice label table covered \(checked) (kind, value) pairs "
              + "across \(table.count) params")
    }

    /// The `choices(for:)` menus are exactly the snap's own domain: every option
    /// is a FIXED POINT of the snap (writing it back draws the same label), and
    /// the options' labels are all distinct — so no menu offers the same setting
    /// twice or an entry the engine would silently move.
    @Test("every menu option is a fixed point of the snap, and options are distinct")
    func choiceMenusAreTheSnapsOwnDomain() {
        var counts: [String: Int] = [:]
        for kind in Self.builtInKinds {
            for spec in EffectParamSpec.specs(for: kind) where EffectEditorModel.isChoiceParam(spec) {
                let options = EffectEditorModel.choices(for: spec)
                #expect(!options.isEmpty, "\(kind).\(spec.name) offers no choices")
                for option in options {
                    // Legal: inside the declared range.
                    #expect(spec.range.contains(option.value),
                            "\(kind).\(spec.name) offers \(option.value), outside \(spec.range)")
                    // A FIXED POINT: the snap leaves it alone.
                    let relabelled = EffectEditorModel.choiceLabel(value: option.value, spec: spec)
                    #expect(relabelled == option.label,
                            "\(kind).\(spec.name) offers \(option.value) as \"\(option.label)\" but the snap calls it \"\(relabelled)\"")
                }
                let labels = options.map(\.label)
                #expect(Set(labels).count == labels.count,
                        "\(kind).\(spec.name) offers a duplicate label: \(labels)")
                counts["\(kind).\(spec.name)"] = options.count
            }
        }
        print("[measured] choice menu sizes: \(counts.sorted { $0.key < $1.key })")
        // The sweep saw the real vocabulary, not an empty one.
        #expect(counts.count == 11, "expected 11 choice params, saw \(counts.count): \(counts.keys.sorted())")
        #expect(counts["dynamicEQ.band1Mode"] == 3)
        #expect(counts["phaser.stages"] == 6)
        #expect(counts["ringMod.waveform"] == 4)
        #expect(counts["clipper.oversampling"] == 3)
    }

    /// `choiceLabel`'s `oversampling` arm answers for BOTH the clipper and the
    /// saturator through `ClipperParams.oversamplingFactor`, which is only
    /// correct while `SaturatorParams.oversamplingFactor` forwards to it (it
    /// does, deliberately — the snap is a property of the shared filter family).
    /// If the two ever fork, the saturator's chip would start lying; this is the
    /// guard that reddens first.
    @Test("the saturator's oversampling snap is still the clipper's, over a dense sweep")
    func oversamplingSnapIsSharedWithTheSaturator() {
        var disagreements = 0
        for step in 0...400 {
            let value = 0.5 + Double(step) * 0.01   // 0.5 … 4.5, past both ends
            if SaturatorParams.oversamplingFactor(at: value)
                != ClipperParams.oversamplingFactor(at: value) {
                disagreements += 1
            }
        }
        #expect(disagreements == 0,
                "the two kinds' oversampling snaps have forked — the saturator chip now lies")
        // Non-vacuity: the sweep really did cross both thresholds.
        #expect(ClipperParams.oversamplingFactor(at: 1.0) == 1)
        #expect(ClipperParams.oversamplingFactor(at: 2.0) == 2)
        #expect(ClipperParams.oversamplingFactor(at: 4.0) == 4)
    }

    // MARK: - Leg 2: THE CENSUS

    /// ⭐⭐ **THE LEG THAT CAN CATCH THE NEXT ONE.**
    ///
    /// `Modulation.swift` documents `.refused` as the marker of a discrete
    /// param: *"modulation additionally refuses DISCRETE params, because an LFO
    /// cannot meaningfully drive a boolean or a topology switch."* That field is
    /// maintained for render-safety reasons that have nothing to do with
    /// drawing, which is exactly what makes it a usable oracle here.
    ///
    /// ⛔ **DO NOT REWRITE THIS IN TERMS OF `isChoiceParam`.** The expected
    /// answer must keep coming from `.refused`, or this test restates the source
    /// and can never fail — the m32-e failure, verbatim.
    ///
    /// The one documented exception is `delay.sync`/`delay.division`, which are
    /// refused by AUTOMATION rather than for discreteness; both already have
    /// their own non-knob cells, so the assertion is uniform.
    @Test("CENSUS: every discrete param in every built-in kind avoids the knob")
    func everyDiscreteParamAvoidsTheKnob() {
        var refused: [String] = []
        var routed: [String: String] = [:]
        var offenders: [String] = []

        for kind in Self.builtInKinds {
            for spec in EffectParamSpec.specs(for: kind) {
                // The four non-knob arms of `EffectEditorOverlay.groupSection`,
                // in dispatch order. `timeMs` under delay sync is a STATE, not a
                // param property, so it is not part of this classification.
                let arm: String?
                if EffectEditorModel.isToggleParam(spec) { arm = "toggleCell" }
                else if EffectEditorModel.isSlopeParam(spec) { arm = "slopeCell" }
                else if EffectEditorModel.isDivisionParam(spec) { arm = "divisionCell" }
                else if EffectEditorModel.isChoiceParam(spec) { arm = "choiceCell" }
                else { arm = nil }

                let label = "\(kind).\(spec.name)"
                if spec.modulatable == .refused {
                    refused.append(label)
                    if let arm {
                        routed[label] = arm
                    } else {
                        offenders.append(label)
                    }
                } else if arm == "choiceCell" {
                    // THE CONVERSE. A continuous param wrongly routed to a chip
                    // would offer a menu over a continuum — the same dishonesty
                    // in the other direction, and the failure mode a name-keyed
                    // `isChoiceParam` invites (a future kind with a continuous
                    // param called `mode`).
                    offenders.append("\(label) is CONTINUOUS but draws a choice chip")
                }
            }
        }

        #expect(offenders.isEmpty,
                "these discrete params still render as KNOBS with meaningless numeric readouts: \(offenders)")

        // Non-vacuity, MEASURED rather than assumed: the sweep must have seen a
        // real population, or "they all avoid the knob" is an empty claim.
        print("[measured] \(refused.count) discrete params across "
              + "\(Self.builtInKinds.count) built-in kinds")
        print("[measured] routing: \(routed.sorted { $0.key < $1.key })")
        #expect(refused.count == 27, "the refused sweep saw \(refused.count): \(refused)")
        // Every arm is actually exercised — a census in which nothing reached
        // the new cell would pass while the defect stood.
        let arms = Set(routed.values)
        #expect(arms == ["toggleCell", "slopeCell", "divisionCell", "choiceCell"],
                "the census did not exercise every arm: \(arms)")
        #expect(routed.values.filter { $0 == "choiceCell" }.count == 11)
        // The four params the defect was reported against, named explicitly so a
        // regression reads as the bug it is rather than as an anonymous sweep.
        for band in 1...DynamicEQParams.bandCount {
            #expect(routed["dynamicEQ.band\(band)Mode"] == "choiceCell")
        }
    }

    // MARK: - Leg 3: the chip fits the cell

    /// The card is 340 pt wide and a row fits three 94 pt cells. The chip is
    /// `.fixedSize()`, so a label too wide does not truncate — it OVERFLOWS and
    /// pushes the row. The budget is held here instead, with the
    /// `InsertLabelBudgetTests` NSFont idiom.
    @Test("every choice label fits the 94 pt cell at the chip's own face")
    func choiceChipLabelsFitTheCell() {
        // `choiceCell`'s literals: SF Mono 9 pt bold, 10 pt padding each side,
        // 5 pt gap, and a 7 pt chevron glyph.
        let face = NSFont.monospacedSystemFont(ofSize: 9, weight: .bold)
        let cellWidth: CGFloat = 94
        let chrome: CGFloat = 10 + 10 + 5 + 9   // padding ×2 + gap + chevron
        let budget = cellWidth - chrome
        var widest = (label: "", width: CGFloat.zero, param: "")

        for kind in Self.builtInKinds {
            for spec in EffectParamSpec.specs(for: kind) where EffectEditorModel.isChoiceParam(spec) {
                for option in EffectEditorModel.choices(for: spec) {
                    // `.tracking(0.6)` adds 0.6 pt per character beyond the
                    // measured string width, and AppKit metrics do not model it.
                    let base = (option.label as NSString).size(withAttributes: [.font: face]).width
                    let width = base + 0.6 * CGFloat(option.label.count)
                    #expect(width <= budget,
                            "\(kind).\(spec.name) option \"\(option.label)\" draws at \(width) pt, over the \(budget) pt chip budget — it would overflow the cell")
                    if width > widest.width {
                        widest = (option.label, width, "\(kind).\(spec.name)")
                    }
                }
            }
        }
        print("[measured] widest choice label: \"\(widest.label)\" (\(widest.param)) at "
              + "\(widest.width) pt against a \(budget) pt budget "
              + "(\(budget - widest.width) pt spare)")
        // The sweep is not vacuous, and the holder is named so a future option
        // that displaces it is a deliberate decision rather than a surprise.
        #expect(widest.label == "Band-Pass" || widest.label == "High-Pass",
                "the widest choice label moved to \"\(widest.label)\"")
        #expect(widest.width > 40, "the measurement collapsed — is the font resolving?")
    }

    // MARK: - The apply path is the knob's, unchanged

    /// m17-a: a burst of card edits is exactly ONE undo entry. The chip writes
    /// through the same `set(name:value:)` the knob uses, so the store's
    /// per-(chain, effect, name) coalescing still carries it.
    @Test("a burst of chip edits lands as exactly ONE undo entry")
    func chipEditsCoalesceLikeAKnob() throws {
        let store = ProjectStore()
        let track = store.addTrack(kind: .audio)
        let fx = try store.addEffect(toTrack: track.id, kind: .dynamicEQ)
        let model = EffectEditorModel(
            descriptor: { trackID, effectID in
                store.tracks.first { $0.id == trackID }?.effects.first { $0.id == effectID }
            },
            apply: { trackID, effectID, name, value in
                _ = try store.setEffectParam(
                    trackID: trackID!, effectID: effectID, name: name, value: value)
            },
            setBypassed: { _, _, _ in })
        model.prepare(trackID: track.id, effectID: fx.id, targetLabel: "on Test")

        let spec = Self.spec(.dynamicEQ, "band1Mode")
        let before = store.undoHistory().undo.count
        for option in EffectEditorModel.choices(for: spec) {
            model.set(name: spec.name, value: option.value)
        }
        #expect(store.undoHistory().undo.count == before + 1,
                "chip edits must coalesce exactly as knob drags do")
        // And the value that landed is the last option, read back through the
        // SAME reader the card draws from.
        let last = EffectEditorModel.choices(for: spec).last!
        #expect(model.value(for: spec) == last.value)
        #expect(EffectEditorModel.choiceLabel(value: model.value(for: spec), spec: spec)
                == last.label)
    }

    // MARK: - The seventh one, which the brief did not name

    /// `hallReverb.freeze` is `0…1`, unit `"linear"`, and NOT in
    /// `isToggleParam` — so it satisfied every clause of `isPercentParam` and
    /// the card drew an INFINITE-HOLD SWITCH as a knob reading **`0 %`**: a
    /// percentage of a binary.
    ///
    /// ⚠️ It is not in `isToggleParam` for a good reason, and the fix must not
    /// put it there: the store CLAMPS freeze without rounding, so
    /// `binaryModelParamsRenderAsToggles` — which derives its answer from a real
    /// 0.4 write — correctly classifies it as non-binary at the STORE. Its
    /// discreteness lives one layer down, in `HallReverbParams.isFrozen`
    /// ("DISCRETE on a continuous surface"). That is the choice family.
    @Test("hallReverb.freeze no longer reads as a percentage of a switch")
    func freezeIsASwitchNotAPercentage() throws {
        let spec = Self.spec(.hallReverb, "freeze")
        #expect(!EffectEditorModel.isPercentParam(spec),
                "freeze is a switch; a percentage readout is the defect")
        #expect(EffectEditorModel.readout(value: 0, spec: spec) == ("Off", ""))
        #expect(EffectEditorModel.readout(value: 1, spec: spec) == ("Hold", ""))
        // The store really does keep 0.4 — which is why it is NOT a toggle param
        // and why the old percent path produced "40 %" for a switch that is off.
        let store = ProjectStore()
        let track = store.addTrack(kind: .audio)
        let fx = try store.addEffect(toTrack: track.id, kind: .hallReverb)
        let updated = try store.setEffectParam(
            trackID: track.id, effectID: fx.id, name: "freeze", value: 0.4)
        #expect(EffectEditorModel.paramValue("freeze", in: updated) == 0.4)
        #expect(!EffectEditorModel.isToggleParam(spec),
                "freeze must stay out of the toggle family — the store does not round it")
        // …and the card names the setting actually in force at that value.
        #expect(EffectEditorModel.choiceLabel(value: 0.4, spec: spec) == "Off")
    }
}
