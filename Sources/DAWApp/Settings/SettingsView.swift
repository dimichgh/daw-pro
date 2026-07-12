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
    /// Deep-link to the Agent Connection section (beta m10-l capture / guide jump).
    var revealConnection: Bool = false
    /// The ACTUAL bound control-server port (beta m10-l) — what agents connect to,
    /// so the URL row is honest even when a different port is pending in the field.
    var controlPort: UInt16
    /// The in-app port SETTING store (beta m10-l): the field reads/commits through it.
    var portStore: ControlPortStore
    /// The in-app Copilot round-budget SETTING store (beta m10-m): the Copilot
    /// section's field reads/commits through it.
    var copilotLimits: CopilotLimitsStore
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
                          revealConnection: revealConnection, controlPort: controlPort,
                          portStore: portStore, copilotLimits: copilotLimits,
                          onReplayTour: onReplayTour, onClose: onClose)
                .frame(width: 480)
                .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        }
        .transition(.opacity)
        // Re-run the non-blocking presence probe each time Settings opens (m10-t),
        // so a key added/removed elsewhere shows up and a `.checking` row resolves.
        // Cheap and off-main; a no-op for a capture's already-resolved in-memory model.
        .task { await model.refresh() }
    }
}

private struct SettingsPanel: View {
    var model: SettingsModel
    var store: ProjectStore
    var revealBeta: Bool
    var revealConnection: Bool
    var controlPort: UInt16
    var portStore: ControlPortStore
    var copilotLimits: CopilotLimitsStore
    var onReplayTour: () -> Void
    var onClose: () -> Void

    /// ScrollViewReader anchor for the Beta row (deep-link target).
    private static let betaAnchorID = "beta-feedback-row"
    /// ScrollViewReader anchor for the Agent Connection section (deep-link target).
    private static let connectionAnchorID = "agent-connection-row"

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

    /// Agent Connection (beta m10-l): the port field's editable draft (seeded from
    /// the persisted setting on appear), an inline error flag when a committed value
    /// is invalid, and a brief "Copied" confirmation after the URL copy button.
    @State private var portDraft: String = ""
    @State private var portError = false
    @State private var urlCopied = false
    @FocusState private var portFieldFocused: Bool

    /// Copilot (beta m10-m): the max-rounds field's editable draft (seeded from the
    /// persisted setting on appear) and an inline error flag when a committed value is
    /// out of range — the port field's validate/revert idiom, reused.
    @State private var roundsDraft: String = ""
    @State private var roundsError = false
    @FocusState private var roundsFieldFocused: Bool

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
                        copilotSection
                            .explainable(.copilotMaxRounds)
                        tourRow
                        connectionSection
                            .id(Self.connectionAnchorID)
                            .explainable(.settingsConnection)
                        betaRow
                            .id(Self.betaAnchorID)
                    }
                    .padding(18)
                }
                .frame(maxHeight: 520)
                // Deep-link a below-the-fold section into view (capture staging /
                // guide jump); normal opens leave both flags false and stay at the top.
                .onAppear {
                    // Seed the port field from the persisted setting (blank shows
                    // the "17600" placeholder).
                    portDraft = portStore.configuredPort.map(String.init) ?? ""
                    // Seed the Copilot rounds field (blank shows the "8" placeholder).
                    roundsDraft = copilotLimits.configuredMaxRounds.map(String.init) ?? ""
                    if revealBeta { proxy.scrollTo(Self.betaAnchorID, anchor: .bottom) }
                    if revealConnection { proxy.scrollTo(Self.connectionAnchorID, anchor: .center) }
                }
                .onChange(of: revealBeta) { _, now in
                    if now { withAnimation { proxy.scrollTo(Self.betaAnchorID, anchor: .bottom) } }
                }
                .onChange(of: revealConnection) { _, now in
                    if now { withAnimation { proxy.scrollTo(Self.connectionAnchorID, anchor: .center) } }
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

    /// The "Copilot" section (beta m10-m): governs the in-app AI Copilot's per-turn
    /// budget. This configures an AI behavior, so the section icon carries a VIOLET
    /// accent (docs/DESIGN-LANGUAGE.md Rule 3 — violet = AI). One validated field caps
    /// how many tool ROUNDS a single reply may take (1–32); a change applies to the
    /// Copilot's NEXT reply, with no restart (contrast the port field, which is
    /// restart-scoped).
    private var copilotSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DAWTheme.ai)   // violet: this configures an AI behavior
                Text("Copilot")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DAWTheme.textPrimary)
            }
            Text("The Copilot works in rounds: each round it reads your project, thinks, then makes a batch of changes. This caps how many rounds one reply may take.")
                .font(.system(size: 10.5))
                .foregroundStyle(DAWTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)

            copilotRoundsRow
        }
        .padding(12)
        .background(DAWTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DAWTheme.hairline, lineWidth: 1))
    }

    /// The persisted max-rounds field: shows the current setting (or the "8"
    /// placeholder), commits through the validator on Return or focus loss, flags an
    /// inline error on out-of-range input, and reminds that a change applies to the
    /// next reply. Mirrors `connectionPortRow` (the validate/revert idiom).
    private var copilotRoundsRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("MAX ROUNDS")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(DAWTheme.textDim)
                TextField("8", text: $roundsDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DAWTheme.textPrimary)
                    .focused($roundsFieldFocused)
                    .onSubmit(commitRounds)
                    .onChange(of: roundsFieldFocused) { _, focused in
                        if !focused { commitRounds() }   // commit on focus loss
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(width: 72)
                    .background(DAWTheme.background)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(roundsError ? DAWTheme.clip.opacity(0.7) : DAWTheme.hairline, lineWidth: 1))
                Spacer(minLength: 0)
            }
            if roundsError {
                Text("Enter a whole number from 1 to 32.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DAWTheme.clip)
            } else {
                Text("Applies to the Copilot's next reply.")
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.textDim)
            }
        }
    }

    /// Commits the rounds field through the validator (beta m10-m). A valid value is
    /// persisted (applies to the next reply); an empty field reverts to the current
    /// setting without error (nothing persisted); any other invalid input flags the
    /// inline error and persists nothing — the `commitPort` behavior, reused.
    private func commitRounds() {
        let trimmed = roundsDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            roundsError = false
            roundsDraft = copilotLimits.configuredMaxRounds.map(String.init) ?? ""
            return
        }
        if let committed = copilotLimits.commit(roundsDraft) {
            roundsError = false
            roundsDraft = String(committed)
        } else {
            roundsError = true
        }
    }

    /// The "Agent Connection" section (beta m10-l): the control-plane hookup
    /// surface a beginner reaches for when wiring an AI agent to the app. This IS
    /// the AI-agent identity surface, so the section icon carries a VIOLET accent
    /// (docs/DESIGN-LANGUAGE.md Rule 3 — violet = AI); cyan is reserved for the
    /// earned "Copied" confirmation. Shows the LIVE bound URL (copyable), the
    /// persisted port field (commit-validated; restart to apply), and — under an
    /// env override — an honesty note so the field never looks broken.
    private var connectionSection: some View {
        let resolution = portStore.resolution()
        let overridden = resolution.source == .environment
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DAWTheme.ai)   // violet: this is the AI hookup surface
                Text("Agent Connection")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DAWTheme.textPrimary)
            }
            Text("AI agents control this app over a local connection. Copy the address into your agent or MCP setup; nothing leaves this Mac.")
                .font(.system(size: 10.5))
                .foregroundStyle(DAWTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)

            connectionURLRow
            connectionPortRow

            if overridden {
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill").font(.system(size: 9))
                    Text("Overridden by DAW_CONTROL_PORT for this session.")
                        .font(.system(size: 10, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(DAWTheme.textDim)
            }
        }
        .padding(12)
        .background(DAWTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DAWTheme.hairline, lineWidth: 1))
    }

    /// The live, copyable control URL — always the ACTUAL bound port so agents copy
    /// what really works, even while a different port sits pending in the field.
    private var connectionURLRow: some View {
        HStack(spacing: 8) {
            Text(controlURL)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DAWTheme.textPrimary)
                .textSelection(.enabled)
                .padding(.horizontal, 8).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DAWTheme.background)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(DAWTheme.hairline, lineWidth: 1))

            Button(action: copyURL) {
                HStack(spacing: 5) {
                    Image(systemName: urlCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9, weight: .bold))
                    Text(urlCopied ? "COPIED" : "COPY")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1)
                }
                // Cyan only on the EARNED confirmation; neutral otherwise.
                .foregroundStyle(urlCopied ? DAWTheme.playback : DAWTheme.textPrimary)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(urlCopied ? DAWTheme.playback.opacity(0.12) : DAWTheme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke((urlCopied ? DAWTheme.playback : DAWTheme.textDim).opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Copy the control URL to the clipboard")
        }
    }

    /// The persisted port field: shows the current setting (or the 17600
    /// placeholder), commits through the validator on Return or focus loss, flags an
    /// inline error on bad input, and reminds that a change applies next launch.
    private var connectionPortRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("PORT")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(DAWTheme.textDim)
                TextField("17600", text: $portDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DAWTheme.textPrimary)
                    .focused($portFieldFocused)
                    .onSubmit(commitPort)
                    .onChange(of: portFieldFocused) { _, focused in
                        if !focused { commitPort() }   // commit on focus loss
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(width: 96)
                    .background(DAWTheme.background)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(portError ? DAWTheme.clip.opacity(0.7) : DAWTheme.hairline, lineWidth: 1))
                Spacer(minLength: 0)
            }
            if portError {
                Text("Enter a whole number from 1024 to 65535.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DAWTheme.clip)
            } else {
                Text("Takes effect the next time DAW Pro starts.")
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.textDim)
            }
        }
    }

    /// The live bound control URL (m10-l) — the real endpoint agents connect to.
    private var controlURL: String { "ws://127.0.0.1:\(controlPort)" }

    /// Copies the live control URL and shows a brief cyan "Copied" confirmation.
    private func copyURL() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(controlURL, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { urlCopied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeOut(duration: 0.2)) { urlCopied = false }
        }
    }

    /// Commits the port field through the validator (beta m10-l). A valid value is
    /// persisted (applies next launch); an empty field reverts to the current
    /// setting without error (nothing persisted); any other invalid input flags the
    /// inline error and persists nothing. Deviation from the brief noted in the
    /// report: empty reverts quietly rather than showing the error state.
    private func commitPort() {
        let trimmed = portDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            portError = false
            portDraft = portStore.configuredPort.map(String.init) ?? ""
            return
        }
        if let committed = portStore.commit(portDraft) {
            portError = false
            portDraft = String(committed)
        } else {
            portError = true
        }
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
        switch row.kind {
        case .localKeyless:
            badge("NO KEY NEEDED", systemImage: "checkmark.seal.fill", color: DAWTheme.signal)
        case .key:
            switch row.status {
            case .checking:
                // Honest transient state while the non-blocking presence probe runs
                // (m10-t) — never a premature "NOT SET".
                badge("CHECKING…", systemImage: "hourglass", color: DAWTheme.textDim)
            case .env:
                badge("CONFIGURED · ENV", systemImage: "lock.fill", color: DAWTheme.signal)
            case .keychain:
                badge("CONFIGURED · KEYCHAIN", systemImage: "key.fill", color: DAWTheme.signal)
            case .keychainConsentRequired:
                // Still configured (a key IS stored), but macOS will ask on first
                // use — the detail is spelled out in the entry area below.
                badge("STORED · NEEDS ACCESS", systemImage: "key.fill", color: DAWTheme.signal)
            case .notSet:
                badge("NOT SET", systemImage: "circle", color: DAWTheme.textDim)
            }
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
            if row.consentRequired {
                // Truthful, beginner-readable (docs/DESIGN-LANGUAGE): the key IS
                // there; macOS just guards reading it after a rebuild/identity change.
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield").font(.system(size: 9))
                    Text("Key stored — macOS will ask for access the first time it's used.")
                        .font(.system(size: 10))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(DAWTheme.textDim)
            }
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
