import Foundation

/// The four one-click tunings, for the person who does not want to open a note
/// editor — which is most people, most of the time.
///
/// ## Why a preset carries no scale
/// A preset says **how the correction behaves**; the scale says **which notes
/// are allowed**. They are independent, and folding the scale into the preset
/// would make "Tight, in G minor" inexpressible — you would need one preset per
/// key per mode, 4 × 12 × 3. So `options(scale:)` takes the scale as an
/// argument and defaults it to chromatic, which is the only honest default when
/// nobody has told us the key.
///
/// ## Why four, and why these four
/// Three of them (`gentle`, `natural`, `tight`) are one ladder: the correction
/// gets stronger and arrives faster as you go up it. The fourth is not on that
/// ladder at all — `hardTune` flips `preserveVibrato`, which
/// `PitchAutoCorrectOptions` documents as a structurally different algorithm
/// rather than another turn of the same dial: the first three move a note's
/// CENTRE and leave the singing inside it alone, while `hardTune` replaces the
/// sung contour outright. That is why there is no fifth preset interpolating
/// between `tight` and `hardTune`: there is nothing in between.
///
/// ⚠️ **THESE NUMBERS ARE STARTING POINTS, NOT MEASURED TASTE.** They were
/// chosen to span the range in audible steps, and the only thing verified about
/// them so far is that they are distinct, ordered, and in range — which is what
/// `PitchCorrectionPresetTests` pins. Which of them actually sounds right on a
/// real voice is a listening question, and a listening question is answered by
/// a person picking, not by an author asserting. Until someone has listened,
/// treat the exact milliseconds as provisional.
public enum PitchCorrectionPreset: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Nudge the badly-out notes, leave everything else alone.
    case gentle
    /// Every note lands in tune, but it still sounds sung.
    case natural
    /// Notes arrive in tune immediately. The modern pop lead sound.
    case tight
    /// The pitch is replaced, not corrected. The robot effect.
    case hardTune

    public var id: String { rawValue }

    /// Beginner-readable, per `docs/DESIGN-LANGUAGE.md`. No "retune speed", no
    /// "correction depth" — a name and a plain sentence.
    public var displayName: String {
        switch self {
        case .gentle: return "Gentle"
        case .natural: return "Natural"
        case .tight: return "Tight"
        case .hardTune: return "Hard Tune"
        }
    }

    /// One line, written for someone who has never used a tuner. It says what
    /// happens to THEIR singing, not what the algorithm does.
    public var summary: String {
        switch self {
        case .gentle:
            return "Pulls notes halfway to pitch. Slides, scoops and vibrato stay."
        case .natural:
            return "Every note lands in tune, and it still sounds like singing."
        case .tight:
            return "Notes snap into tune the moment they start."
        case .hardTune:
            return "Replaces your pitch with the exact note. The robot effect."
        }
    }

    /// The knob positions. See the type-level note: provisional until listened to.
    ///
    /// `retuneMs` floors at 30 because that is `PitchEditSet.engineMinimumRetuneMs`
    /// — the renderer's one-hop limit (1440 frames at 48 kHz), not a taste
    /// decision. `tight` sits just above it at 40 so the ladder's top rung is a
    /// musical choice rather than an engine constraint wearing a name, and
    /// `hardTune` takes the floor itself because the robot sound IS the
    /// instantaneous one.
    public func options(scale: PitchCorrectionScale = .chromatic) -> PitchAutoCorrectOptions {
        switch self {
        case .gentle:
            return PitchAutoCorrectOptions(
                scale: scale, strength: 0.5, retuneMs: 200, preserveVibrato: true)
        case .natural:
            return PitchAutoCorrectOptions(
                scale: scale, strength: 0.85, retuneMs: 110, preserveVibrato: true)
        case .tight:
            return PitchAutoCorrectOptions(
                scale: scale, strength: 1.0, retuneMs: 40, preserveVibrato: true)
        case .hardTune:
            return PitchAutoCorrectOptions(
                scale: scale, strength: 1.0,
                retuneMs: PitchEditSet.engineMinimumRetuneMs, preserveVibrato: false)
        }
    }

    /// The three that share one ladder, weakest first. `hardTune` is
    /// deliberately absent: it is not a stronger `tight`, it is a different
    /// algorithm, and a UI that presents all four as one slider would be
    /// lying about what the last stop does. (Offered — `offeredInUI` — is not
    /// the same question as on-the-ladder.)
    public static let ladder: [PitchCorrectionPreset] = [.gentle, .natural, .tight]

    /// **WHAT THE UI MAY DRAW — ALL FOUR, since contour-to-render
    /// (2026-09-24).** Kept as a NAMED list rather than replaced by `allCases`
    /// at the draw sites, because the rule below is still the rule and this is
    /// where it is enforced.
    ///
    /// ⭐ THE RULE THIS SERVES: a control whose label promises one result and
    /// whose mechanism delivers another is worse than a missing control,
    /// because nothing in the product can tell the user they were lied to.
    /// This tree has shipped that shape before (`drumKit` without `kind` — a
    /// silent, inaudible success) and the cost was that nobody could see it.
    ///
    /// **WHY `hardTune` WAS WITHHELD, AND WHY IT NO LONGER IS — MEASURED BOTH
    /// TIMES.** Until 2026-09-24 the render built every curve with
    /// `contour: []`, so Hard Tune's flattening resolved to nothing and it
    /// rendered as a *stronger Tight* wearing the label "the robot effect" —
    /// on the real dry vocal the constant-offset render left each held note's
    /// within-note wander where it was, the same as Tight. The render now
    /// shapes against the detected whole-file contour (`PitchRenderContour`),
    /// and the phrase is split into notes first (`PitchNoteSplitter`, p2-seg).
    /// Through that product path, over the vocal's 19 measurable held notes,
    /// Hard Tune cuts the wander 37.6 → 15.2 cents (median 49 % per note,
    /// `PitchWanderMeter`; 18.8 → 8.1 cents, 68 %, by an independent YIN) and
    /// keeps every one of them on its own note. Tight reads 37.6 → 38.3 (−1 %),
    /// and so does the constant-offset fallback. The env-gated
    /// `ContourRenderListeningTests` is the measurement (p2-seg-F-metric,
    /// 2026-09-24). The label is now true, so the button is offered.
    ///
    /// ⚠️ RETRACTED: the figure first written here, "62.8 → 18.2 cents (median
    /// 70 % cut per note)", was scored per stored segment BEFORE note
    /// splitting. That render flattened 4 of the 19 held notes onto the WRONG
    /// note (97–460 cents off), so part of its "70 %" was flattening onto
    /// wrong notes. This doc is the ONE home of the figure; other comments
    /// point here and do not restate it.
    ///
    /// ⚠️ **WHAT IS STILL TRUE AND A UI SHOULD SAY:** if the pitch detector
    /// cannot run (a build missing the model), Hard Tune renders its fallback
    /// — notes on pitch, wobble kept — and the engine posts a
    /// `clip-pitch-contour-unavailable` notice. That is a failure the product
    /// reports, not the mechanism the label describes.
    ///
    /// If this ever diverges from `allCases` again, the reason belongs here in
    /// writing, and `PitchCorrectionPresetTests.uiDoorOffersEveryPresetTheRenderHonours`
    /// must be changed with it.
    public static let offeredInUI: [PitchCorrectionPreset] = [.gentle, .natural, .tight, .hardTune]
}
