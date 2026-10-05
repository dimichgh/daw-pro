import Foundation
import Testing

@testable import DAWCore

/// ⭐ THE TEST THAT EARNS ITS PLACE HERE IS THE CLAMP TEST, and it is worth
/// saying why, because it looks like a tautology and is not.
/// `PitchAutoCorrectOptions.init` silently clamps `strength` to 0…1 and
/// `retuneMs` to 30…500. So a preset author who writes `retuneMs: 600` gets a
/// preset that reads 600 in the source and behaves as 500 at runtime, with no
/// warning, no error, and a comment above it confidently describing 600. That
/// is this tree's characteristic failure exactly: something that fails by
/// returning a plausible answer, where the record says X, the code does Y, and
/// nothing compares them. Asserting the round-trip is the comparison.
@Suite("Pitch correction presets")
struct PitchCorrectionPresetTests {

    @Test("every preset survives its own constructor unclamped")
    func noSilentClamping() {
        // The literal table is restated here ON PURPOSE. A test that read the
        // numbers back out of `options()` and compared them to `options()`
        // would pass no matter what the preset said.
        let expected: [PitchCorrectionPreset: (strength: Double, retune: Double, vib: Bool)] = [
            .gentle:   (0.5,  200, true),
            .natural:  (0.85, 110, true),
            .tight:    (1.0,   40, true),
            .hardTune: (1.0,   30, false),
        ]
        #expect(expected.count == PitchCorrectionPreset.allCases.count,
                "a preset was added without a row here")
        for preset in PitchCorrectionPreset.allCases {
            let want = try! #require(expected[preset])
            let got = preset.options()
            #expect(got.strength == want.strength,
                    "\(preset.rawValue) strength clamped: asked \(want.strength), got \(got.strength)")
            #expect(got.retuneMs == want.retune,
                    "\(preset.rawValue) retuneMs clamped: asked \(want.retune), got \(got.retuneMs)")
            #expect(got.preserveVibrato == want.vib)
        }
    }

    /// The negative control for the test above: prove the clamp it is watching
    /// for is real and DOES fire, so a passing `noSilentClamping` means the
    /// values are in range rather than that clamping never happens.
    @Test("the clamp being guarded against genuinely fires")
    func clampIsReal() {
        let over = PitchAutoCorrectOptions(strength: 3, retuneMs: 6000)
        #expect(over.strength == 1)
        #expect(over.retuneMs == PitchEditSet.retuneMsRange.upperBound)
        #expect(over.retuneMs != 6000, "if this fails the clamp is gone and the guard above is blind")
    }

    @Test("the ladder is a ladder — stronger and faster, strictly, in order")
    func ladderIsOrdered() {
        let steps = PitchCorrectionPreset.ladder.map { $0.options() }
        #expect(steps.count == 3)
        for (a, b) in zip(steps, steps.dropFirst()) {
            #expect(b.strength >= a.strength, "strength went backwards up the ladder")
            #expect(b.retuneMs < a.retuneMs, "retune must get strictly faster up the ladder")
            #expect(b.preserveVibrato == a.preserveVibrato,
                    "the ladder must not change algorithm halfway — that is what hardTune is for")
        }
        #expect(!PitchCorrectionPreset.ladder.contains(.hardTune),
                "hardTune is not a stronger tight; keep it off the ladder")
    }

    @Test("hardTune is the only one that replaces the performance")
    func onlyHardTuneFlattens() {
        let flattening = PitchCorrectionPreset.allCases.filter { !$0.options().preserveVibrato }
        #expect(flattening == [.hardTune])
    }

    @Test("no two presets are the same setting under two names")
    func presetsAreDistinct() {
        let all = PitchCorrectionPreset.allCases.map { $0.options() }
        for i in all.indices {
            for j in all.indices where j > i {
                let a = PitchCorrectionPreset.allCases[i].rawValue
                let b = PitchCorrectionPreset.allCases[j].rawValue
                #expect(all[i] != all[j], "\(a) and \(b) are identical settings")
            }
        }
    }

    @Test("the scale passes through untouched — a preset never picks the key")
    func scaleIsOrthogonal() {
        let gMinor = PitchCorrectionScale(tonicPitchClass: 7, mode: .minor)
        for preset in PitchCorrectionPreset.allCases {
            let o = preset.options(scale: gMinor)
            #expect(o.scale == gMinor, "\(preset.rawValue) overrode the caller's scale")
            // and the rest of the preset is unaffected by which scale it got
            #expect(o.strength == preset.options().strength)
            #expect(o.retuneMs == preset.options().retuneMs)
        }
        #expect(gMinor.displayName == "G minor")
        #expect(PitchCorrectionPreset.tight.options().scale == .chromatic,
                "chromatic is the only honest default when nobody has said the key")
    }

    @Test("presets survive the wire — they are sent as commands and persisted")
    func codableRoundTrip() throws {
        for preset in PitchCorrectionPreset.allCases {
            let data = try JSONEncoder().encode(preset)
            let back = try JSONDecoder().decode(PitchCorrectionPreset.self, from: data)
            #expect(back == preset)
            // the raw value is the wire contract; pin it so a rename is loud
            #expect(String(data: data, encoding: .utf8) == "\"\(preset.rawValue)\"")
        }
        #expect(PitchCorrectionPreset.allCases.map(\.rawValue)
                == ["gentle", "natural", "tight", "hardTune"])
    }

    /// The UI door used to withhold `hardTune` because the render path built
    /// every curve with `contour: []` and so could not produce it. Since
    /// contour-to-render the render resolves a flattening set against the
    /// detected contour — `ContourToRenderTests.hardTuneFlattensThroughTheProductPath`
    /// measures it on the rendered audio, with a no-contour control that must
    /// come out the other way — so the reason is gone and the door offers all
    /// four.
    ///
    /// This pins BOTH halves of the old reasoning, so it cannot quietly come
    /// back: the one preset that needs the contour is offered, AND it is the
    /// one that needs the contour (so if a fifth, contour-free preset were
    /// hidden for no stated reason, or Hard Tune stopped needing the contour,
    /// this would say so).
    @Test("the UI door offers every preset the render honours — Hard Tune included, now that the contour reaches the render")
    func uiDoorOffersEveryPresetTheRenderHonours() {
        #expect(PitchCorrectionPreset.offeredInUI == PitchCorrectionPreset.allCases,
                "a preset is withheld from the UI — say why in `offeredInUI`'s doc and change this test with it")
        #expect(PitchCorrectionPreset.offeredInUI.last == .hardTune,
                "the ladder must read weakest → strongest before the different-algorithm stop")
        // The one offered preset that needs the contour is exactly the one
        // that used to be withheld for lacking it.
        let needsContour = PitchCorrectionPreset.offeredInUI.filter { !$0.options().preserveVibrato }
        #expect(needsContour == [.hardTune])
        // And a Hard Tune pass DOES ask the render for the contour — the thing
        // the render now supplies. If the policy stopped asking, the label
        // "with less vibrato" would be false again.
        let frames = (0..<40).map { i in
            ClipPitchFrame(timeSeconds: Double(i) * 0.016,
                           frequencyHz: 224 * pow(2, 40 * sin(Double(i) * 0.55) / 1200),
                           confidence: 0.95, levelDbfs: -20, absence: nil)
        }
        let set = PitchAutoCorrect.editSet(contour: frames, frameRateHz: 62.5,
                                           options: PitchCorrectionPreset.hardTune.options())
        #expect(set.needsDetectedContour)
        for preset in PitchCorrectionPreset.ladder {
            let ladderSet = PitchAutoCorrect.editSet(contour: frames, frameRateHz: 62.5,
                                                     options: preset.options())
            #expect(!ladderSet.needsDetectedContour,
                    "\(preset.rawValue) now needs the contour — it would re-key every cached render of it")
        }
    }

    @Test("every preset has a name and a sentence, and no two share either")
    func labelsAreUsable() {
        let names = PitchCorrectionPreset.allCases.map(\.displayName)
        let blurbs = PitchCorrectionPreset.allCases.map(\.summary)
        #expect(Set(names).count == names.count)
        #expect(Set(blurbs).count == blurbs.count)
        for (n, b) in zip(names, blurbs) {
            #expect(!n.isEmpty)
            #expect(b.count > 20, "a one-word summary helps nobody: \(b)")
            #expect(b.hasSuffix("."), "summaries are sentences: \(b)")
        }
    }
}
