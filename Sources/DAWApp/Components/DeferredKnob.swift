import SwiftUI
import DAWAppKit

/// A `KnobControl` that moves at 60 fps under the hand but writes the model
/// EXACTLY ONCE, on release (m26-i).
///
/// ## Why this exists — and when to reach for it
///
/// The house knob idiom applies on every drag tick (`PolySynthEditorOverlay`),
/// and for a cheap apply path that is right: the value is live, the store
/// coalesces the whole drag into one undo step, and the user hears the change
/// as they make it. **That cadence is only free when the apply is free.**
///
/// The built-in SAMPLER's is not, for two independent reasons that both sit on
/// its apply path and were MEASURED, not assumed:
///
/// 1. `ProjectStore.setInstrument` validates the zone list on EVERY sampler
///    apply — the guard is `if let sampler`, not "if the zones changed" — and
///    that validation walks every zone doing a `FileManager.fileExists` plus a
///    media open. Turning a GLOBAL knob re-opens every sample file in the
///    library, on the main actor: 46 for the user's saxophone, 309 for a large
///    one.
/// 2. `instrumentNodeIdentityChanged` compares the two zone ARRAYS, and
///    `SamplerZone` is `Equatable` — so any per-zone scalar edit flips node
///    identity and, on a non-trivially-routed strip, forces an instrument-node
///    teardown and an engine rebuild.
///
/// Neither cost exists for the poly synth (`case .testTone, .polySynth: return
/// false`), so the card this one is cloned from is SILENT about both. That is
/// the m25-k shape exactly — a correct land-time policy invoked at drag cadence
/// — and "a correct policy at the wrong cadence looks exactly like a correct
/// policy."
///
/// ## The mechanism, and why the state lives HERE
///
/// While the drag is live the knob renders an optimistic LOCAL fraction and
/// formats its own readout from it, so the cap and the number track the pointer
/// with no model involvement at all. On release the local value goes to
/// `onCommit` once, then clears.
///
/// **The `@State` is deliberately in this leaf and not in the owning card.** A
/// `@State` write invalidates the view that owns it: on the card it would
/// re-evaluate the whole card body per drag frame, which re-maps every
/// `SamplerZoneRow` and re-runs the coverage gap analysis — a 300-zone library
/// would rebuild 300 rows per frame. Here it invalidates one knob.
///
/// ⚠️ **Clearing the local value on commit is what keeps the knob HONEST.** If
/// the apply is refused — one moved sample file makes the whole sampler
/// read-only, globals included — the cap visibly springs back to the value the
/// model actually holds, next to the card's inline error. A knob that kept
/// showing the value it failed to write would be the silent-plausible failure
/// this codebase keeps closing.
///
/// Plain value inputs (fraction + closures) so previews and the live app share
/// it; the owner maps value ↔ fraction and owns the formatter.
struct DeferredKnob: View {
    /// The micro-label drawn above the knob (rendered uppercase).
    var label: String
    /// The COMMITTED value's travel fraction 0…1 — what the model holds. Read
    /// only while no drag is in flight.
    var fraction: Double
    /// The travel fraction the value arc fills from: 0 = unipolar min-start,
    /// 0.5 = the bipolar centre detent (tune, pan).
    var fillAnchor: Double = 0
    /// Arc/pointer/readout tint — neutral white unless the param genuinely
    /// earns a semantic accent (cyan for level/gain).
    var accent: Color = DAWTheme.textPrimary
    /// Whether the readout carries a soft glow (the level params).
    var glowsReadout: Bool = false
    /// Formats a travel fraction into `(text, unit)`. Called for the LIVE
    /// fraction during a drag, so it must be a pure function of its argument —
    /// reading the model here would defeat the whole point of this view.
    var readout: (Double) -> (text: String, unit: String)
    /// The single apply, called ONCE on release with the final fraction.
    var onCommit: (Double) -> Void
    /// Double-click reset (nil = no reset affordance). Already a single apply,
    /// so it writes through immediately.
    var onReset: (() -> Void)? = nil

    /// The optimistic value under the hand (nil = not dragging, show the model).
    @State private var live: Double?

    var body: some View {
        let shown = live ?? fraction
        let text = readout(shown)
        return KnobControl(
            label: label,
            fraction: shown,
            fillAnchor: fillAnchor,
            readout: text.text,
            unit: text.unit,
            accent: accent,
            glowsReadout: glowsReadout,
            onChange: { live = $0 },
            onReset: {
                // Drop any optimistic value first: the reset is authoritative,
                // and a stale local would paint over the value it just wrote.
                live = nil
                onReset?()
            },
            onCommit: {
                if let live { onCommit(live) }
                live = nil
            }
        )
    }
}
