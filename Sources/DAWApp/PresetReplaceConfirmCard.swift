import DAWAppKit
import SwiftUI

/// m23-ap C-F3: **"Replace your hand edits?"** The card a preset click raises
/// when the clip carries notes the person moved or split by hand
/// (`PitchPresetReplaceGate`, one signal: `PitchEditSet.hasHandEditsSinceAutoCorrect`).
/// A clip holding only a preset's own output never raises it, so comparing
/// presets is never nagged.
///
/// The `RecoveryOfferView` shape: a centred dark-glass card over a dimmed scrim,
/// drawn INSIDE the window. An `NSAlert` or `.confirmationDialog` would be a
/// stock grey panel (the design language's one flat "no"), and it lives in its
/// own window where `debug.captureUI` cannot see it.
///
/// APP CHROME, not AI content, so there is NO violet. RED (`DAWTheme.clip`) marks
/// the one destructive answer, because red means destructive in this palette.
/// It does not glow: glow is earned by live state, and a button at rest is
/// static chrome.
///
/// ⭐ **CANCEL IS THE KEYBOARD ANSWER; THE DESTRUCTIVE ONE NEVER IS.** Esc
/// cancels. Return is bound to nothing, so a stray keypress cannot erase
/// anybody's work.
///
/// The words come from `PitchPresetReplaceCopy`, one home that the tests read.
/// This view never retypes them.
struct PresetReplaceConfirmCard: View {
    let request: PitchPresetReplaceRequest
    var onReplace: () -> Void
    var onCancel: () -> Void

    private var copy: PitchPresetReplaceCopy { PitchPresetReplaceCopy(request) }

    var body: some View {
        ZStack {
            // Scrim. No tap-to-dismiss: the person answers with a button, so
            // a click that misses the card can never count as either answer.
            Rectangle()
                .fill(Color.black.opacity(0.55))
                .ignoresSafeArea()

            card
                .frame(width: 440)
                .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        }
        .transition(.opacity)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                // Amber: the warning ink ("the measurement is in doubt / take
                // care"). The RED is saved for the button that does the damage.
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(DAWTheme.record)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 8) {
                    Text(copy.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DAWTheme.textPrimary)
                    Text(copy.body)
                        .font(.system(size: 13))
                        .foregroundStyle(DAWTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(copy.undoNote)
                        .font(.system(size: 12))
                        .foregroundStyle(DAWTheme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                Spacer()
                Button(action: onCancel) {
                    Text(copy.cancelLabel)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DAWTheme.textPrimary)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(DAWTheme.panelRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(DAWTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button(role: .destructive, action: onReplace) {
                    Text(copy.confirmLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DAWTheme.background)
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(DAWTheme.clip)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .background(DAWTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(DAWTheme.hairline, lineWidth: 1))
    }
}

extension View {
    /// Mounts the card over this view while `model`'s preset gate holds a
    /// request. `ContentView` calls this in place of an inline `.overlay`,
    /// because its modifier chain is at the type-checker's limit (see the
    /// comment at the call site).
    func presetReplaceConfirmOverlay(_ model: AppModel) -> some View {
        modifier(PresetReplaceConfirmOverlay(model: model))
    }
}

/// The binding: the gate's pending request, drawn, with both answers routed to
/// the `AppModel` funnels (`PitchCorrectionStaging.swift`). Those funnels are
/// the only road to the store.
private struct PresetReplaceConfirmOverlay: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content.overlay {
            if let request = model.pitchPresetReplaceGate.pending {
                PresetReplaceConfirmCard(
                    request: request,
                    onReplace: { model.confirmPresetReplace() },
                    onCancel: { model.cancelPresetReplace() }
                )
            }
        }
    }
}
