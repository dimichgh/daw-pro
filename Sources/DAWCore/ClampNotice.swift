import Foundation

/// m27-c: the one place that words "you asked for a value this control cannot
/// hold, so it was clamped".
///
/// The defect this exists for: `fx.setParam`, `fx.add`'s initial `params`, and
/// `mixer.setMasterVolume` all clamp silently. Asking a gain insert for +18 dB
/// returned `ok` and a value you did not request, with nothing anywhere saying
/// so — a plausible-looking valid answer, which is this tree's characteristic
/// failure mode. Raising the ceiling alone would only move that silent lie to a
/// new number, so the clamp had to start speaking too.
///
/// WARN, NOT REJECT. `fx_set_param`'s shipped MCP description already promises
/// "Out-of-range `value`s clamp to the parameter's valid range rather than
/// erroring"; rejecting would break a documented contract on a live verb, and
/// every caller that today sends a deliberately-saturating value (a UI slider
/// dragged to its stop, a preset written against an older range) would start
/// failing. The notice is additive — a `warnings` array of plain sentences,
/// present ONLY when something was actually clamped, matching every other
/// `warnings` field on this wire (`track.setInstrument`,
/// `clip.setControllerLane`, `instrument.describeSampler`, media import,
/// `project.open`).
public enum ClampNotice {
    /// A plain sentence naming the control, what you asked for, what was
    /// stored, and the range — or nil when `requested` was in range and
    /// nothing was clamped.
    ///
    /// ONLY range clamping earns a sentence. Value SNAPPING that stays inside
    /// the range (the EQ's 12/24 dB-per-octave slopes, the delay's note
    /// divisions) is deliberately silent: it is not a refusal to hold your
    /// value, and warning on it would make the field noise — and noise is
    /// ignored, taking the warning that mattered with it (the m27-b lesson).
    ///
    /// - Parameters:
    ///   - control: the wire-visible name of the knob (`gainLinear`, `volume`).
    ///   - requested: the value the caller sent.
    ///   - stored: the value actually held after clamping.
    ///   - range: the control's accepted range.
    ///   - advice: an optional extra sentence pointing at the way to get what
    ///     the caller evidently wanted (master volume points at the gain
    ///     insert). Appended verbatim.
    public static func sentence(control: String,
                                requested: Double,
                                stored: Double,
                                range: ClosedRange<Double>,
                                advice: String? = nil) -> String? {
        // A non-finite request is a different failure (it is not "too big"),
        // and NaN fails every comparison — guard it rather than emitting a
        // sentence containing the word "nan".
        guard requested.isFinite else { return nil }
        guard !range.contains(requested) else { return nil }
        let bound = requested > range.upperBound ? "maximum" : "minimum"
        var text = "\(control) was clamped to its \(bound) \(number(stored)) — "
            + "you asked for \(number(requested)), and this control accepts "
            + "\(number(range.lowerBound)) to \(number(range.upperBound))."
        if let advice { text += " " + advice }
        return text
    }

    /// Compact, human-readable number: integers print without a decimal point
    /// (`16`, not `16.0`), everything else keeps up to three decimals with
    /// trailing zeros trimmed (`1.386`, `0.5`). A wire sentence an agent reads
    /// back to a person should not carry float noise.
    static func number(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e15 {
            return String(Int64(value))
        }
        var text = String(format: "%.3f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
