import Foundation

/// THE pressure axis (m34-f step ①) — the pure, hardware-free half of "press
/// harder on the breath pad and the note swells".
///
/// UI-free, engine-free, and deliberately tiny: it is the ONE part of "read
/// trackpad pressure" that can be tested without a Force Touch trackpad, so it
/// is the part that carries the rules.
///
/// ## The user's own framing, and why this is the physically correct mapping
///
/// > *"electric guitars have a special stick that can modulate the last played
/// > note … that mechanism or similar can be used to modulate wind instruments
/// > dynamic by keep pressing … for sax for example."*
///
/// A guitar's whammy bar changes string tension, so pitch is the honest
/// parameter there. A saxophone's pitch is set by FINGERING — a keyed,
/// quantised mechanism. The only continuously variable physical input a player
/// has during a held note is **breath pressure**, and that one variable drives
/// loudness, brightness and a slight sharpening together. So the trackpad's
/// Z axis drives the pad's existing expression lane (CC 11 by default —
/// `BreathContour.Settings.expressionCC`'s own default, measured on the stock
/// GM sax as exactly a gain), and NOT pitch bend.
///
/// ## The three axes, and what each one means
///
/// | Axis | Physical input | Musical meaning |
/// |---|---|---|
/// | angle | where the dot sits on the ring | WHICH breath gesture |
/// | radius | how far out the dot sits | HOW DEEP that gesture is |
/// | **pressure** | **how hard the finger presses** | **HOW HARD YOU ARE BLOWING, NOW** |
///
/// The first two are an AUTHORING choice — they describe a shape that gets baked
/// into a clip. The third is a PERFORMANCE: it has no shape, only a value, and
/// it is the only one of the three that a human drives in real time.
public enum PadPressure {
    /// `NSEvent.pressure`'s documented domain. Values outside it are clamped
    /// rather than trusted — the one secondary source claiming pressure can
    /// exceed 1.0 was traced to an unrelated JavaScript polyfill's 1–3 scale,
    /// not to AppKit (`docs/research/spike-trackpad-expression.md` §1.1), so the
    /// clamp is defence rather than a modelled case.
    public static let range = 0.0...1.0

    /// ⛔⛔ **THE DEGRADATION RULE, AND IT IS THE MOST IMPORTANT LINE IN THIS
    /// FILE: `nil` MEANS "NO PRESSURE INFORMATION", WHICH IS NOT 0 AND NOT 1.**
    ///
    /// Most Macs this app ships to do not have a Force Touch trackpad, and a
    /// mouse never produces a pressure event at all. The honest answer on those
    /// machines is not "pressure is 0" (which would silence the pad) and not
    /// "pressure is 1" (which would be a constant reported as if it were a
    /// measurement — the exact dishonesty this tree keeps finding). It is
    /// **absence**, and absence maps to *the pad behaving exactly as it did
    /// before this axis existed*.
    ///
    /// ⭐ **CAPABILITY IS OBSERVED, NEVER QUERIED.** There is no verified public
    /// API for "does this Mac have a Force Touch trackpad" callable from a
    /// running app; `ioreg`/`defaults` are shell-level. So the signal is the
    /// ARRIVAL of a real `NSEventTypePressure` event — a thing only a Force
    /// Touch trackpad emits. Until one arrives, this returns `nil` and nothing
    /// on screen claims a Z axis exists.
    ///
    /// ⚠️ **DO NOT KEY THIS OFF `mouseDown.pressure`.** A legacy mouse reports
    /// `1.0` while its button is down and a Force Touch pad reports its actual
    /// (near-zero) force at the actuation point, so the two ARE distinguishable
    /// — and that distinction is exactly the kind of undocumented coincidence
    /// that silently inverts one macOS release later. Event arrival is a
    /// documented fact; that inference is not.
    ///
    /// - Parameters:
    ///   - dotEffort: what the pad's angle/radius alone say, 0…1.
    ///   - pressure: the observed force, or `nil` when none has been observed.
    /// - Returns: the effort actually streamed to the instrument.
    public static func effort(dotEffort: Double, pressure: Double?) -> Double {
        let base = clampEffort(dotEffort)
        guard let pressure else { return base }
        return base * clamp(pressure)
    }

    /// A MULTIPLY, and the alternatives were considered and rejected — written
    /// down because this looks arbitrary and is not.
    ///
    /// * **`effort × pressure` (chosen).** The dot becomes the CEILING — "how
    ///   loud is a full breath on this part" — and the finger plays everything
    ///   below it. At full press the pad streams exactly what it streamed before
    ///   this axis existed, so the two behaviours meet rather than fight, and
    ///   the axis composes with a `radius` sweep instead of overriding it.
    /// * **`pressure` alone, ignoring the dot.** Rejected: it makes angle and
    ///   radius dead controls during a performance, and the pad's whole readout
    ///   (`blendReadout`, the lit spokes) would then be describing something the
    ///   instrument is not doing.
    /// * **`lerp(floor, effort, pressure)` for some floor > 0.** Rejected: the
    ///   floor is an invented constant with no physical referent, and it makes
    ///   "I stopped blowing" unreachable.
    ///
    /// ⛔ **AND THE CONSEQUENCE, STATED RATHER THAN DISCOVERED: AT ZERO PRESSURE
    /// THIS REACHES ZERO, AND THAT RETRACTS A PROMISE THE PAD PREVIOUSLY MADE.**
    /// `BreathPadModel.effort` documents *"it also never reaches 0: the pad
    /// cannot preview a silence"*, measured across the eight library patterns.
    /// That remains true of the DOT — and is now false of what the pad STREAMS,
    /// on a machine with a Force Touch trackpad. It is not a regression: a
    /// breath controller at zero breath is silent, and choosing not to blow is
    /// the single most expressive thing a wind player does. The retraction is
    /// written here, and beside the original claim, rather than the old sentence
    /// being quietly deleted.
    ///
    /// The curve is LINEAR, deliberately. Real breath controllers ship a
    /// user-settable response curve, but the shape of that curve is a taste
    /// decision about how playing FEELS — the one thing nobody on this side of
    /// the screen can judge — so shipping an invented default would be picking
    /// for the user rather than asking. Linear is the only choice that adds no
    /// opinion.
    public static func clamp(_ pressure: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, pressure))
    }

    /// Clamps an effort to the pad's own 0…1 domain.
    public static func clampEffort(_ effort: Double) -> Double {
        min(1.0, max(0.0, effort))
    }
}
