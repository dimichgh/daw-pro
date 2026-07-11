import SwiftUI
import AppKit
import AIServices
import DAWAppKit
import DAWCore

/// The Settings → API Keys panel (M6): key management over the Keychain, shown
/// as a centered glass card over a dimmed scrim in the main window (so
/// `debug.captureUI` snapshots it). This is APP CHROME, not AI content — it
/// stays in the glass-cockpit neutral/cyan/green palette; violet is reserved for
/// AI-generated material and is deliberately absent here.
///
/// All logic lives in `DAWAppKit.SettingsModel`; this view is thin over it and
/// never sees a stored key value — it shows a source badge and, for a
/// just-saved key, the model's session-only mask.
struct SettingsOverlay: View {
    var model: SettingsModel
    /// The project store — drives the Beta row's "Save Feedback Bundle" action
    /// (M9 beta) over `ProjectStore.writeFeedbackBundle`, the SAME store path the
    /// `app.feedbackBundle` command uses.
    var store: ProjectStore
    /// Deep-link to the below-the-fold Beta row (M9 beta capture affordance).
    var revealBeta: Bool = false
    /// Replays the onboarding tour (M8 ob-b): resets it and starts from welcome.
    var onReplayTour: () -> Void
    var onClose: () -> Void

    var body: some View {
        ZStack {
            // Scrim: dim the workspace and catch a click-to-dismiss.
            Rectangle()
                .fill(Color.black.opacity(0.55))
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            SettingsPanel(model: model, store: store, revealBeta: revealBeta,
                          onReplayTour: onReplayTour, onClose: onClose)
                .frame(width: 480)
                .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        }
        .transition(.opacity)
    }
}

private struct SettingsPanel: View {
    var model: SettingsModel
    var store: ProjectStore
    var revealBeta: Bool
    var onReplayTour: () -> Void
    var onClose: () -> Void

    /// ScrollViewReader anchor for the Beta row (deep-link target).
    private static let betaAnchorID = "beta-feedback-row"

    /// Beta row: include the full project in the feedback bundle (default off —
    /// the privacy-lean default; on shares every track/clip/note + media paths).
    @State private var includeProjectInBundle = false
    /// One-line result of the last feedback-bundle save (the folder path, or an
    /// error). `feedbackIsError` picks the green success vs red error color.
    @State private var feedbackNotice: String?
    @State private var feedbackIsError = false

    /// Inline per-provider action feedback (e.g. a Keychain error, or a saved
    /// confirmation). Keyed by provider raw value.
    @State private var notice: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(DAWTheme.hairline)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        intro
                        ForEach(model.rows) { row in
                            ProviderRowView(
                                row: row,
                                draft: draftBinding(row),
                                notice: notice[row.id],
                                onSave: { save(row) },
                                onClear: { clear(row) }
                            )
                            // One shared "API Key" card on every provider row —
                            // per-instance frames anchor it on whichever row is hovered.
                            // The copy never surfaces a key value (Keychain-stored).
                            .explainable(.settingsApiKey)
                        }
                        tourRow
                        betaRow
                            .id(Self.betaAnchorID)
                    }
                    .padding(18)
                }
                .frame(maxHeight: 520)
                // Deep-link the below-the-fold Beta row into view (capture staging);
                // normal opens leave revealBeta false and stay at the top.
                .onAppear { if revealBeta { proxy.scrollTo(Self.betaAnchorID, anchor: .bottom) } }
                .onChange(of: revealBeta) { _, now in
                    if now { withAnimation { proxy.scrollTo(Self.betaAnchorID, anchor: .bottom) } }
                }
            }
        }
        .background(DAWTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14).stroke(DAWTheme.hairline, lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DAWTheme.textDim)
            Text("SETTINGS")
                .font(.system(size: 12, weight: .heavy))
                .tracking(2.5)
                .foregroundStyle(DAWTheme.textPrimary)
            Text("API KEYS")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(DAWTheme.textDim)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DAWTheme.textDim)
            }
            .buttonStyle(.plain)
            .help("Close settings")
        }
        .padding(16)
    }

    private var intro: some View {
        Text("Keys are stored in your macOS Keychain and never leave this Mac. A key set by an environment variable takes precedence and is shown locked.")
            .font(.system(size: 10.5))
            .foregroundStyle(DAWTheme.textDim)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The "Replay tour" utility row (M8 ob-b): neutral app chrome (no violet), a
    /// raised glass row matching the provider rows. Resets + restarts the guided
    /// tour and closes Settings so the welcome card is in view.
    private var tourRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Guided Tour")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DAWTheme.textPrimary)
                Text("Walk through making your first song again, step by step.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DAWTheme.textDim)
            }
            Spacer(minLength: 8)
            Button {
                onClose()
                onReplayTour()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 9, weight: .bold))
                    Text("REPLAY TOUR")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1)
                }
                .foregroundStyle(DAWTheme.textPrimary)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(DAWTheme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(DAWTheme.textDim.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Replay the first-song guided tour")
        }
        .padding(12)
        .background(DAWTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DAWTheme.hairline, lineWidth: 1))
    }

    /// The "Beta" utility row (M9 beta): neutral app chrome — CYAN accent, NOT
    /// violet (this is diagnostics, not an AI feature). "Save Feedback Bundle"
    /// writes ONE local folder (manifest + engine health + a counts-only overview
    /// + recent crash reports, all on this Mac, nothing transmitted) via the same
    /// `ProjectStore.writeFeedbackBundle` the `app.feedbackBundle` command drives,
    /// then reveals it in Finder and echoes the path. The include-project toggle
    /// (default OFF) opts into sharing the full project content.
    private var betaRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Beta Feedback")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DAWTheme.textPrimary)
            Text("Save a diagnostics bundle to attach to a bug report. Everything stays on this Mac — nothing is uploaded.")
                .font(.system(size: 10.5))
                .foregroundStyle(DAWTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                includeProjectToggle
                Spacer(minLength: 8)
                saveBundleButton
            }

            if let feedbackNotice {
                Text(feedbackNotice)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(feedbackIsError ? DAWTheme.clip : DAWTheme.signal)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
                    .truncationMode(.middle)
            }
        }
        .padding(12)
        .background(DAWTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DAWTheme.hairline, lineWidth: 1))
    }

    private var includeProjectToggle: some View {
        Button {
            includeProjectInBundle.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: includeProjectInBundle ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(includeProjectInBundle ? DAWTheme.playback : DAWTheme.textDim)
                Text("INCLUDE PROJECT")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(DAWTheme.textDim)
            }
        }
        .buttonStyle(.plain)
        .help("Also include your full project — every track, clip, note, and the paths to your audio files")
    }

    private var saveBundleButton: some View {
        Button(action: saveFeedbackBundle) {
            HStack(spacing: 5) {
                Image(systemName: "ladybug.fill")
                    .font(.system(size: 9, weight: .bold))
                Text("SAVE FEEDBACK BUNDLE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1)
            }
            .foregroundStyle(DAWTheme.playback)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(DAWTheme.playback.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(DAWTheme.playback.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Write a diagnostics bundle and reveal it in Finder")
    }

    /// Writes the bundle on the main actor (a manual, user-initiated action),
    /// reveals the folder in Finder, and echoes the path; a filesystem failure
    /// shows its readable message in red.
    private func saveFeedbackBundle() {
        do {
            let summary = try store.writeFeedbackBundle(includeProject: includeProjectInBundle)
            let url = URL(fileURLWithPath: summary.path)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            feedbackIsError = false
            let crashes = summary.crashReportCount == 1 ? "1 crash report" : "\(summary.crashReportCount) crash reports"
            feedbackNotice = "Saved \(summary.fileCount) files (\(crashes)) → \(summary.path)"
        } catch {
            feedbackIsError = true
            feedbackNotice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func draftBinding(_ row: ProviderRow) -> Binding<String> {
        Binding(
            get: { row.provider.map { model.draft(for: $0) } ?? "" },
            set: { if let p = row.provider { model.setDraft($0, for: p) } }
        )
    }

    private func save(_ row: ProviderRow) {
        guard let provider = row.provider else { return }
        switch model.save(provider) {
        case .saved: notice[row.id] = "Saved to Keychain."
        case .invalid: notice[row.id] = "That doesn't look like a valid key — check for stray spaces or line breaks."
        case .locked: notice[row.id] = "Set by an environment variable — edit it there."
        case .failed(let message): notice[row.id] = message
        case .cleared: break
        }
    }

    private func clear(_ row: ProviderRow) {
        guard let provider = row.provider else { return }
        switch model.clear(provider) {
        case .cleared: notice[row.id] = "Removed."
        case .locked: notice[row.id] = "Set by an environment variable — remove it there."
        case .failed(let message): notice[row.id] = message
        case .saved, .invalid: break
        }
    }
}

/// One provider row: title + subtitle, a status badge, and — for an editable
/// key-backed provider — a secure entry field with Save/Clear.
private struct ProviderRowView: View {
    let row: ProviderRow
    @Binding var draft: String
    var notice: String?
    var onSave: () -> Void
    var onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DAWTheme.textPrimary)
                if row.dormant { tag("DORMANT", color: DAWTheme.textDim) }
                Spacer()
                statusBadge
            }
            Text(row.subtitle)
                .font(.system(size: 10.5))
                .foregroundStyle(DAWTheme.textDim)

            if row.isEditable {
                entryRow
            } else if row.provider != nil {
                lockedNote
            }

            if let notice {
                Text(notice)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DAWTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(DAWTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DAWTheme.hairline, lineWidth: 1))
    }

    // MARK: Status badge

    @ViewBuilder
    private var statusBadge: some View {
        switch (row.kind, row.source, row.configured) {
        case (.localKeyless, _, _):
            badge("NO KEY NEEDED", systemImage: "checkmark.seal.fill", color: DAWTheme.signal)
        case (.key, .env, _):
            badge("CONFIGURED · ENV", systemImage: "lock.fill", color: DAWTheme.signal)
        case (.key, .keychain, _):
            badge("CONFIGURED · KEYCHAIN", systemImage: "key.fill", color: DAWTheme.signal)
        default:
            badge("NOT SET", systemImage: "circle", color: DAWTheme.textDim)
        }
    }

    private func badge(_ text: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage).font(.system(size: 8, weight: .bold))
            Text(text)
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .tracking(0.8)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 1))
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: Entry

    private var entryRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let mask = row.savedMask {
                Text("Saved this session: \(mask)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DAWTheme.signal)
            }
            HStack(spacing: 8) {
                secureField
                Button(action: onSave) {
                    Text("SAVE")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(canSave ? DAWTheme.textPrimary : DAWTheme.textDim)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(canSave ? DAWTheme.panel : DAWTheme.panel.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(canSave ? DAWTheme.textDim.opacity(0.5) : DAWTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(!canSave)

                Button(action: onClear) {
                    Text("CLEAR")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(row.configured ? DAWTheme.clip : DAWTheme.textDim)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background((row.configured ? DAWTheme.clip : DAWTheme.textDim).opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke((row.configured ? DAWTheme.clip : DAWTheme.textDim).opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(!row.configured)
                .help("Remove the stored key")
            }
        }
    }

    private var canSave: Bool {
        SettingsPanelValidation.looksValid(draft)
    }

    private var secureField: some View {
        SecureField("Paste key…", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(DAWTheme.textPrimary)
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(DAWTheme.background)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(DAWTheme.hairline, lineWidth: 1))
            .frame(maxWidth: .infinity)
    }

    private var lockedNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill").font(.system(size: 9))
            Text("Set by \(row.provider?.environmentKey ?? "an environment variable"). Remove it there to manage the key in-app.")
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(DAWTheme.textDim)
    }
}

/// Mirror of the model's validation for the view's Save-enable state, so the
/// button greys out live without a round-trip. The model re-validates on save
/// (single source of truth); this only gates the button.
private enum SettingsPanelValidation {
    static func looksValid(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }
}
