import SwiftUI
import DAWCore

/// Launch-time crash-recovery offer (M9 crash-b): a small neutral-glass sheet the
/// app floats when the last session ended unexpectedly AND a rolling autosave
/// snapshot survives. APP CHROME, not AI content — so it stays in the glass-cockpit
/// neutral palette with a CYAN accent (docs/DESIGN-LANGUAGE Rule 3: violet is
/// reserved for AI material and is deliberately absent here). RESTORE and DISCARD
/// call the SAME `ProjectStore.recoverFromAutosave` path the `project.recover`
/// command uses — one implementation, two entry points.
struct RecoveryOfferView: View {
    /// The offer facts (savedAt / sourcePath) surfaced by `recoveryStatus()`.
    let status: AutosaveRecoveryStatus
    var onRestore: () -> Void
    var onDiscard: () -> Void

    var body: some View {
        ZStack {
            // Scrim: dim the workspace behind the offer. No tap-to-dismiss — the
            // user must make an explicit choice (restore or discard).
            Rectangle()
                .fill(Color.black.opacity(0.55))
                .ignoresSafeArea()

            card
                .frame(width: 420)
                .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        }
        .transition(.opacity)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(DAWTheme.playback)
                    .glow(DAWTheme.playback, radius: 6, intensity: 0.5)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Restore unsaved work?")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DAWTheme.textPrimary)
                    Text("Your last session ended unexpectedly.")
                        .font(.system(size: 12))
                        .foregroundStyle(DAWTheme.textSecondary)
                }
            }

            // The autosave timestamp + which file it belongs to, as a SF-Mono
            // readout (the glass-cockpit numeric token).
            HStack(spacing: 18) {
                DigitalReadout(label: "Autosaved", value: savedAtText, color: DAWTheme.playback)
                if let source = sourceName {
                    DigitalReadout(label: "Project", value: source, color: DAWTheme.textPrimary, valueSize: 14)
                }
            }

            HStack(spacing: 10) {
                Spacer()
                Button(action: onDiscard) {
                    Text("Discard")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DAWTheme.textSecondary)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(DAWTheme.panelRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(DAWTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Button(action: onRestore) {
                    Text("Restore")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DAWTheme.background)
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(DAWTheme.playback)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .glow(DAWTheme.playback, radius: 6, intensity: 0.45)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .background(DAWTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(DAWTheme.hairline, lineWidth: 1))
    }

    /// "HH:MM" for the autosave stamp; "—" when unknown (never blank).
    private var savedAtText: String {
        guard let savedAt = status.savedAt else { return "—" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: savedAt)
    }

    /// The recovered project's file basename (no extension), or nil for an
    /// untitled session (the readout is simply omitted).
    private var sourceName: String? {
        guard let path = status.sourcePath else { return nil }
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }
}
