import Foundation
import DAWCore

/// The DRAWN disclosure an effect owes when its stated benefit is *revelation*
/// and its mechanism is *synthesis* (m23-p2).
///
/// ## Why this type exists, and the line it draws
///
/// The bass enhancer's whole selling point — "makes bass audible on small
/// speakers" — is a claim about HEARING SOMETHING THAT IS ALREADY THERE. Its
/// mechanism is the opposite: it manufactures 2nd/3rd/4th partials from the
/// sub-crossover content and injects them above the corner, so the listener
/// infers a fundamental the speaker never reproduced. A beginner who reads the
/// benefit and never learns the mechanism believes they are UNCOVERING their
/// recording when they are ADDING to it — and the addition prints into the
/// bounce.
///
/// **The disclosure closes the gap between the promise and the mechanism; it is
/// not a tax on harmonic generation.** That is the whole criterion, and it is
/// what keeps this from being owed by every effect that creates new frequency
/// content:
///
/// - `saturator` also emits partials the source did not contain — but its name,
///   its knob (DRIVE) and its benefit all say "it distorts". There is no gap:
///   the user asked for the change they get.
/// - `reverb` re-emits the same spectrum later in time; `chorus` plays detuned
///   copies. Both are framed as what they are.
/// - `bassEnhancer` is the only built-in whose benefit is phrased as an
///   improvement in AUDIBILITY of the existing part.
///
/// So the table below returns exactly one note today. That is a claim about
/// today's eleven kinds, not a claim that no other kind could ever earn one:
/// a future "vocal clarity", "tape width" or "punch restore" would owe one on
/// the same test — *does the copy a user reads promise revelation while the
/// code performs synthesis?* The switch is EXHAUSTIVE so a new kind cannot be
/// added without someone answering that question.
///
/// ## The ink rules (docs/DESIGN-LANGUAGE.md)
///
/// The strings here carry NO readout-shaped token (a digit next to Hz/dB/ms/%),
/// pinned by test. A number in this block would sit inches from the card's real
/// SF Mono readouts and read as a MEASUREMENT of the user's signal — the
/// m23-o2 `HP 35 Hz` failure reached through a different door. The view draws
/// them in the label register (never SF Mono), in neutral ink (never violet —
/// this is DSP, not AI-touched content; never amber — a disclosure is not a
/// fault), and never dimmer than the knob labels it sits above.
///
/// Plain values with no dependencies: previews, tests and the app all read the
/// same strings from here, and `debug.effectEditor` reports the resolved value
/// so a capture can prove the words reached a pixel.
public struct EffectHonestyNote: Sendable, Equatable {
    /// The one-line admission, in the group-micro-header register. States the
    /// mechanism, not the benefit — the benefit is what brought the user here.
    public let headline: String
    /// The plain-language explanation: BOTH truths in the order a beginner can
    /// use them — why you want it, then what it actually does to your audio.
    public let body: String
    /// What the knob RANGES cannot teach, for every knob the card draws:
    /// CROSSOVER is a fact about the listener's speaker rather than about the
    /// music, `amount` is level AND brightness (not a plain "more"), and the
    /// character is level-independent by design.
    public let footnote: String

    public init(headline: String, body: String, footnote: String) {
        self.headline = headline
        self.body = body
        self.footnote = footnote
    }

    /// Every drawn string, in drawing order — the one place a test or a probe
    /// enumerates the copy, so a fourth field cannot slip past the no-readout
    /// pin by not being listed.
    public var drawnStrings: [String] { [headline, body, footnote] }

    /// The disclosure for one effect kind, or nil when the kind's copy already
    /// says what the kind does. See the type's doc comment for the criterion.
    ///
    /// EXHAUSTIVE on purpose: a new `Effect.Kind` stops the build here and its
    /// author has to decide whether the effect promises revelation.
    public static func note(for kind: EffectDescriptor.Kind?) -> EffectHonestyNote? {
        guard let kind else { return nil }
        switch kind {
        case .bassEnhancer:
            return bassEnhancer
        case .gain, .eq, .compressor, .limiter, .reverb, .delay, .saturator,
             .gate, .chorus, .audioUnit:
            // No gap between promise and mechanism — see the criterion above.
            // `saturator`/`reverb`/`chorus` DO create content the source did
            // not contain; they are excluded because nothing in this app tells
            // the user they are revealing it.
            return nil
        }
    }

    /// The bass enhancer's disclosure.
    ///
    /// Wording notes, each load-bearing:
    /// - "are not in your recording" is the headline because it is the fact the
    ///   benefit hides. It leads; the benefit follows in the body.
    /// - "prints into your bounce" answers the question a beginner asks next —
    ///   is this only a monitoring aid? It is not.
    /// - MIX is described as "how much of the new harmonics you hear", NEVER as
    ///   dry/wet: `BassEnhancerParams` never attenuates the dry path, so a user
    ///   reading "dry/wet" would expect 0.5 to halve their bass. It does not.
    /// - CROSSOVER leads the footnote because it is the one knob on this card
    ///   whose right value is not a taste decision: it is a fact about the
    ///   SPEAKER you are worried about, not about the music. The good sentence
    ///   already existed in `EffectParamSpec.note` — but that travels on the
    ///   wire and lands in a `.help` tooltip, which `debug.captureUI` cannot
    ///   photograph and a beginner may never hover. Drawn here, it is on the
    ///   card. A test derives the knob labels from
    ///   `EffectEditorModel.groups(for: .bassEnhancer)` and requires every one
    ///   of them to appear in this copy, so a fourth knob cannot arrive
    ///   untaught.
    /// - the level-independence sentence is a genuine virtue and belongs to the
    ///   honest side of the ledger, not the marketing side: the amplitude
    ///   normalization inside the generator is why a quiet passage and a loud
    ///   one get the same character instead of the part getting harsher as it
    ///   gets louder.
    public static let bassEnhancer = EffectHonestyNote(
        headline: "ADDS HARMONICS THAT ARE NOT IN YOUR RECORDING",
        body: "Small speakers cannot play the lowest notes, so this builds new "
            + "overtones from your low end for them to play — and your ear supplies "
            + "the note it never heard. Nothing is uncovered here: this is new "
            + "sound, and it prints into your bounce.",
        footnote: "Set CROSSOVER to the lowest note your speaker plays. AMOUNT "
            + "sets how loud and bright the harmonics are, and that holds whether "
            + "the part is quiet or loud. MIX sets how much of them you hear; your "
            + "own signal is never turned down.")
}
