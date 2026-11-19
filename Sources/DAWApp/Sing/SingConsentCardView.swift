import SwiftUI
import AIServices
import DAWAppKit

/// The consent card (p2-sing-f, design §5.3 and §2.5; the user's ruling `sing-consent` = "Ask me first"): the ONE
/// window that guards both installing and removing the singing engine, for an agent's request and for the
/// person's own. [Install] / [Remove] is `SingConsentBroker.approve(id:)`; [Not now] is `decline(id:)`. A click
/// beside the card does nothing: a yes or a no is a click on a button.
///
/// After Install the card stays and shows the download: the step, the bytes (SF Mono), [Cancel]; then the end
/// (§5.7 "Install stopped" with [Try again], or done).
struct SingConsentCardView: View {
    var model: SingConsentModel

    private var isInstalling: Bool {
        if case .installing = model.phase { return true }
        return false
    }

    var body: some View {
        SingModalCard(width: 440, onScrimTap: nil) {
            VStack(alignment: .leading, spacing: 12) {
                SingCardHeader(systemImage: "arrow.down.circle", title: SingCopy.installTitle, tint: DAWTheme.ai,
                               closeHelp: SingCopy.notNow, onClose: closeAction)
                Divider().overlay(DAWTheme.hairline)
                content
                if let error = model.errorText { PanelRefusalLine(message: error) }
            }
        }
        // The install's progress, polled at 1 Hz while it runs (the model owns every transition).
        .task(id: isInstalling) {
            while isInstalling {
                await model.pollInstall()
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    /// The ✕ (and Escape): Not now while asking, Done when ended; nothing while working.
    private var closeAction: (() -> Void)? {
        switch model.phase {
        case .asking: return { model.notNow() }
        case .finished: return { model.dismiss() }
        default: return nil
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .closed:
            EmptyView()
        case .asking:
            if let text = model.cardText {
                SingSentence(text: text.body, color: DAWTheme.textPrimary, size: 12)
                if let agent = text.agentLine {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(DAWTheme.ai)
                        SingSentence(text: agent, color: DAWTheme.ai, size: 11)
                    }
                }
                HStack(spacing: 8) {
                    Spacer()
                    SingButton(title: text.secondary) { model.notNow() }
                    SingButton(title: text.primary,
                               systemImage: text.primary == SingCopy.remove ? "trash" : "arrow.down.circle",
                               role: text.primary == SingCopy.remove ? .destructive : .neutral) {
                        Task { await model.approve() }
                    }
                }
            }
        case .working(let action):
            SingSentence(text: action == .installEngine ? SingCopy.installStarting : SingCopy.removing,
                         color: DAWTheme.textSecondary)
        case .installing(let status):
            let text = SingInstallProgressText(status: status)
            SingSentence(text: text.line, color: DAWTheme.textPrimary)
            SingProgressBar(fraction: text.fraction)
            HStack {
                if let bytes = text.bytes {
                    Text(bytes)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(DAWTheme.textSecondary)
                }
                Spacer()
                SingButton(title: text.cancelTitle, isEnabled: text.cancelEnabled) {
                    Task { await model.cancelInstall() }
                }
            }
        case .finished(let message, let retry):
            SingSentence(text: message, color: retry == nil ? DAWTheme.textPrimary : DAWTheme.record, size: 12)
            HStack(spacing: 8) {
                Spacer()
                if retry != nil {
                    SingButton(title: SingCopy.tryAgain, systemImage: "arrow.clockwise") {
                        Task { await model.tryAgain() }
                    }
                }
                SingButton(title: SingCopy.done) { model.dismiss() }
            }
        }
    }
}
