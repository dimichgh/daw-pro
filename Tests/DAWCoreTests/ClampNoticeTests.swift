import Foundation
import Testing
@testable import DAWCore

/// m27-c — the one home for "your value did not fit, so it was clamped".
/// Pinned here because three verbs share it (`fx.setParam`, `fx.add`'s seeded
/// params, `mixer.setMasterVolume`) and they must not drift into three
/// different ways of saying the same thing.
@Suite("Clamp notice wording (m27-c)")
struct ClampNoticeTests {
    @Test("an in-range value produces NO sentence — silence is the ordinary case")
    func inRangeIsSilent() {
        #expect(ClampNotice.sentence(control: "gainLinear", requested: 5.045,
                                     stored: 5.045, range: 0...16) == nil)
        // Both bounds are inclusive: exactly at the ceiling is not a clamp.
        #expect(ClampNotice.sentence(control: "gainLinear", requested: 16,
                                     stored: 16, range: 0...16) == nil)
        #expect(ClampNotice.sentence(control: "gainLinear", requested: 0,
                                     stored: 0, range: 0...16) == nil)
    }

    @Test("above the ceiling names the maximum, the request, and the range")
    func aboveCeiling() {
        #expect(ClampNotice.sentence(control: "gainLinear", requested: 20,
                                     stored: 16, range: 0...16)
            == "gainLinear was clamped to its maximum 16 — you asked for 20, "
            + "and this control accepts 0 to 16.")
    }

    @Test("below the floor names the MINIMUM — the sentence is not hard-coded to one side")
    func belowFloor() {
        #expect(ClampNotice.sentence(control: "volume", requested: -0.5,
                                     stored: 0, range: 0...2)
            == "volume was clamped to its minimum 0 — you asked for -0.5, "
            + "and this control accepts 0 to 2.")
    }

    @Test("advice is appended verbatim when given, and absent when not")
    func adviceIsOptional() {
        let bare = ClampNotice.sentence(control: "volume", requested: 3,
                                        stored: 2, range: 0...2)
        #expect(bare?.hasSuffix("accepts 0 to 2.") == true)
        let guided = ClampNotice.sentence(control: "volume", requested: 3, stored: 2,
                                          range: 0...2, advice: "Use a gain insert.")
        #expect(guided == (bare ?? "") + " Use a gain insert.")
    }

    @Test("a non-finite request yields nothing — it is a different failure, not a clamp")
    func nonFiniteIsNotAClamp() {
        // NaN fails every comparison, so a naive `range.contains` would emit a
        // sentence containing the word "nan". Guarded instead.
        #expect(ClampNotice.sentence(control: "gainLinear", requested: .nan,
                                     stored: 1, range: 0...16) == nil)
        #expect(ClampNotice.sentence(control: "gainLinear", requested: .infinity,
                                     stored: 16, range: 0...16) == nil)
    }

    @Test("numbers read like numbers, not like floats")
    func numberFormatting() {
        #expect(ClampNotice.number(16) == "16")
        #expect(ClampNotice.number(0) == "0")
        #expect(ClampNotice.number(-3) == "-3")
        #expect(ClampNotice.number(2.5) == "2.5")
        #expect(ClampNotice.number(1.386) == "1.386")
        // Trailing zeros trimmed — "0.50" reads as float noise in a sentence.
        #expect(ClampNotice.number(0.5) == "0.5")
        #expect(ClampNotice.number(5.0450) == "5.045")
    }
}
