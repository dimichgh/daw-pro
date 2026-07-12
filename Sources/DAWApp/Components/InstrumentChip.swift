import SwiftUI
import DAWCore
import DAWAppKit

/// The current-instrument chip (m10-n-3): a compact, status-aware affordance that
/// shows an instrument track's sound source ("Poly Synth", "Trumpet — General
/// MIDI", "DLSMusicDevice") and opens the shared instrument picker on click. ONE
/// reusable component, rendered in BOTH the track header (compact) and the mixer
/// instrument strip (full) so the two never drift.
///
/// NO VIOLET — the instrument picker is standard chrome, not AI content
/// (docs/DESIGN-LANGUAGE.md Rule 3: violet is AI identity only). The chip is
/// neutral at rest; it earns an amber warning tint ONLY when the hosted
/// instrument failed/went missing (amber = warning-adjacent), and dims subtly
/// while a sound-bank/AU load is `.pending` (a quiet loading affordance, never a
/// spinner takeover — design §7).
struct InstrumentChip: View {
    /// The track's current instrument (nil = the default poly synth).
    var descriptor: InstrumentDescriptor?
    /// The hosted-instrument lifecycle status for a soundBank/AU selection (nil for
    /// built-ins / when the engine tracks none). Drives the loading + failure cues.
    var status: AudioUnitTrackStatus?
    /// Compact = the tight track-header row (glyph + soft-truncating name, no hard
    /// minimum so it never inflates the 250 pt sidebar). Full = the roomy mixer
    /// strip (glyph + name + a quiet "change" chevron).
    var compact: Bool = false
    /// Opens the picker for this track.
    var onOpen: () -> Void

    private var name: String { InstrumentPickerModel.displayName(for: descriptor) }
    private var kind: InstrumentDescriptor.Kind { (descriptor ?? .default).kind }

    /// The instrument-family glyph: a synth wave for built-ins, keys for a sound
    /// bank, a plugin puzzle-piece for a hosted Audio Unit.
    private var glyph: String {
        switch kind {
        case .polySynth, .testTone: return "waveform.path"
        case .sampler: return "square.stack.3d.up"
        case .soundBank: return "pianokeys"
        case .audioUnit: return "puzzlepiece.extension.fill"
        }
    }

    /// A hosted instrument (soundBank/AU) whose status is failed/missing — the chip
    /// warns (amber) and surfaces the verbatim reason in its tooltip.
    private var failureReason: String? {
        switch status {
        case .failed(let reason): return reason
        case .missing: return "instrument not found — pick another"
        default: return nil
        }
    }
    /// True while the hosted instrument is still loading (soundBank/AU only).
    private var isPending: Bool {
        if case .pending = status { return true }
        return false
    }

    /// The glyph tint: amber warning on failure, dimmed while loading, else the
    /// neutral chip glyph color.
    private var iconColor: Color {
        if failureReason != nil { return DAWTheme.record }
        if isPending { return DAWTheme.textFaint }
        return DAWTheme.textDim
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: compact ? 4 : 6) {
                Image(systemName: failureReason != nil ? "exclamationmark.triangle.fill" : glyph)
                    .font(.system(size: compact ? 9 : 10, weight: .semibold))
                    .foregroundStyle(iconColor)
                // Compact (tight track-header row) is GLYPH-ONLY so it never steals
                // the track name's readable share — the stronger "icon+name is
                // ALWAYS readable" sidebar invariant (DESIGN-LANGUAGE "Track header
                // identity"). The full display name rides the tooltip here and shows
                // inline in the roomy mixer chip.
                if !compact {
                    Text(name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isPending ? DAWTheme.textDim : DAWTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if isPending { PendingDot() }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(DAWTheme.textFaint)
                } else if isPending {
                    // A subtle loading cue on the compact chip — a small breathing
                    // dot beside the glyph, never a spinner takeover (design §7).
                    PendingDot()
                }
            }
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 3 : 5)
            .frame(maxWidth: compact ? nil : .infinity, alignment: .leading)
            .background(DAWTheme.panelRaised.opacity(compact ? 0.7 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(failureReason != nil ? DAWTheme.record.opacity(0.5) : DAWTheme.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(helpText)
        // ONE shared Explain id across BOTH renders (track header + mixer strip);
        // per-instance frame anchoring lands the card on whichever the pointer is
        // over (ex-b shared-id rule).
        .explainable(.trackInstrumentChip)
    }

    private var helpText: String {
        if let failureReason { return "\(name) — \(failureReason). Click to pick another." }
        if isPending { return "\(name) — loading… Click to change the instrument." }
        return "\(name) — click to change this track's instrument."
    }
}

/// A subtle breathing dot for the chip's `.pending` load state — a quiet loading
/// affordance (design §7: never a spinner takeover). Neutral-colored so it makes
/// no semantic accent claim.
private struct PendingDot: View {
    @State private var dim = false
    var body: some View {
        Circle()
            .fill(DAWTheme.textFaint)
            .frame(width: 5, height: 5)
            .opacity(dim ? 0.3 : 0.9)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}
