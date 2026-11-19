import AIServices
import DAWCore
import Foundation
import Observation

/// The words on the consent card for one request (design §5.3, §5.7; user ruling `sing-consent` = "Ask me first").
/// Pure: built from the broker's request, nothing else.
public struct SingConsentCardText: Equatable, Sendable {
    public var title: String
    public var body: String
    /// §5.7 "An AI agent asked for this." when an agent asked; nil when the user did.
    public var agentLine: String?
    /// [Install] or [Remove].
    public var primary: String
    /// [Not now].
    public var secondary: String

    public init(request: SingConsentRequest) {
        title = SingCopy.installTitle
        switch request.action {
        case .installEngine:
            // §5.7's install card body for BOTH askers, plus the agent line (the ruling's words). The broker's
            // own agent sentence (§2.5, "An AI agent wants to install…") stays the wire's: §5.7 is the copy.
            body = SingCopy.installCardBody
            primary = SingCopy.install
        case .uninstallEngine:
            // No §5.7 row: the broker's own PROVISIONAL sentence for a person, read from it (one home).
            body = SingConsentBroker.message(for: .uninstallEngine, fromAgent: false)
            primary = SingCopy.remove
        }
        agentLine = request.fromAgent ? SingCopy.agentAsked : nil
        secondary = SingCopy.notNow
    }
}

/// What the install part of the card says while the engine downloads (§5.3 "After Install: progress with the
/// step name and the bytes, and [Cancel]"). Pure.
public struct SingInstallProgressText: Equatable, Sendable {
    public var line: String
    /// "1.2 of 2.8 GB" (SF Mono), nil before the first byte count.
    public var bytes: String?
    /// 0...1 when the bytes are known.
    public var fraction: Double?
    public var cancelTitle: String
    public var cancelEnabled: Bool

    public init(status: SingingEngineInstallStatus) {
        if status.cancelRequested {
            line = SingCopy.installCancelling
        } else if let p = status.progress {
            line = SingCopy.installing(step: p.stepIndex, of: p.stepCount, name: p.stepName)
        } else {
            line = SingCopy.installStarting
        }
        if let done = status.progress?.bytesDone, let total = status.progress?.bytesTotal, total > 0 {
            bytes = Self.gigabytes(done) + " of " + Self.gigabytes(total) + " GB"
            fraction = min(1, max(0, Double(done) / Double(total)))
        } else {
            bytes = nil
            fraction = nil
        }
        cancelTitle = SingCopy.cancel
        cancelEnabled = !status.cancelRequested
    }

    public static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1_000_000_000)
    }

    /// §5.7 "Install stopped" for a failed install: the step it stopped at and the installer's own words.
    public static func stoppedSentence(_ status: SingingEngineInstallStatus) -> String {
        let step: String
        switch status.failure {
        case .step(let name): step = name
        default: step = status.progress?.stepName ?? "start"
        }
        var cause = status.errorMessage ?? "the installer gave no reason"
        // The coordinator words a step failure "step '<name>' failed: <install.sh's words>"; the card already names
        // the step, so it keeps only install.sh's own words.
        let prefix = "step '\(step)' failed: "
        if cause.hasPrefix(prefix) { cause = String(cause.dropFirst(prefix.count)) }
        return SingCopy.installStopped(step: step, cause: cause)
    }
}

/// The consent card (p2-sing-f): ONE card for both askers and both acts. Nothing downloads and nothing is deleted
/// until [Install] / [Remove] is pressed, and that press is `SingConsentBroker.approve(id:)`: the broker runs the
/// performer the WIRE installed (`SingWireHandlers.perform`), so the button and `sing.installEngine`'s approval
/// reach the same `SingingEngineInstallCoordinator.start()`.
///
/// - An agent's `sing.installEngine` / `sing.uninstallEngine` posts a request; the app hands it to `present` (it is
///   the broker's `onRequest`).
/// - The Sing sheet's first use asks through `ask(_:)`, which posts a request `fromAgent: false`; the broker then
///   calls `present` the same way. One window, never a second door.
/// - [Not now] is `broker.decline(id:)`.
/// - After an install is approved the card stays up and shows the install's progress, then its end.
@MainActor
@Observable
public final class SingConsentModel {

    public enum Phase: Equatable, Sendable {
        case closed
        /// Waiting for the user's click.
        case asking(SingConsentRequest)
        /// The yes is being carried out (the performer runs; a removal stops the engine and deletes).
        case working(SingConsentAction)
        /// The engine is downloading.
        case installing(SingingEngineInstallStatus)
        /// An end the user reads, with [Try again] when `retry` is set.
        case finished(message: String, retry: SingConsentAction?)
    }

    public let broker: SingConsentBroker
    private let install: SingingEngineInstallCoordinator
    /// p2-sing-x8 (part B): THE install pre-check (`SingInstallPreflight.check`, the one `sing.installEngine` makes
    /// before it asks), run before the window ever offers the download: the Mac, then the free disk. nil = no check
    /// (a test that is not about it).
    private let preflight: (@Sendable () -> SingInstallPreflight.Refusal?)?
    public private(set) var phase: Phase = .closed
    /// Requests that arrived while another was showing (an install and a removal, say).
    public private(set) var waiting: [SingConsentRequest] = []
    /// A refusal from the broker or the installer, in its own words, under the buttons.
    public private(set) var errorText: String?
    /// The text-only preview `debug.singScreens` stages for a screenshot: never in the broker, so its [Install]
    /// is refused by the broker ("no such request") and can never download.
    public private(set) var isPreview = false
    /// Told once an install has finished, so a sheet waiting on it can refresh.
    public var onInstalled: (@MainActor () -> Void)?

    public init(broker: SingConsentBroker, install: SingingEngineInstallCoordinator,
                preflight: (@Sendable () -> SingInstallPreflight.Refusal?)? = nil) {
        self.broker = broker
        self.install = install
        self.preflight = preflight
    }

    public var isOpen: Bool { phase != .closed }

    public var cardText: SingConsentCardText? {
        if case .asking(let request) = phase { return SingConsentCardText(request: request) }
        return nil
    }

    // MARK: - Asking

    /// THE broker's `onRequest`: show this request (or queue it behind the one showing).
    public func present(_ request: SingConsentRequest) {
        switch phase {
        case .closed, .finished:
            errorText = nil
            isPreview = false
            phase = .asking(request)
        case .asking(let showing) where showing.id == request.id:
            break
        default:
            if !waiting.contains(where: { $0.id == request.id }) { waiting.append(request) }
        }
    }

    /// The person asked from inside the app (the Sing sheet's first use, a Remove door). Posts through the
    /// broker, which calls `present`. Under the staging flag the broker performs at once.
    public func ask(_ action: SingConsentAction) async {
        errorText = nil
        // An install is checked BEFORE anyone is asked (design §2.5 step 1): a Mac that cannot run the engine, or a
        // disk that cannot hold it, gets the pre-check's own sentence and [Try again], and the broker hears nothing.
        // [Try again] comes back through here, so it is checked again.
        if action == .installEngine, let refused = preflight?() {
            errorText = refused.sentence
            if case .closed = phase { phase = .finished(message: refused.sentence, retry: action) }
            return
        }
        do {
            switch try await broker.request(action, fromAgent: false) {
            case .awaitingUserConsent(let request):
                present(request)   // idempotent: the broker already called `present` through `onRequest`
            case .performed:
                await afterPerformed(action)
            }
        } catch {
            errorText = Self.words(error)
            if case .closed = phase { phase = .finished(message: Self.words(error), retry: action) }
        }
    }

    /// A screenshot-only card (`debug.singScreens`): not in the broker, so [Install] cannot download.
    public func stagePreview(_ request: SingConsentRequest) {
        errorText = nil
        isPreview = true
        phase = .asking(request)
    }

    // MARK: - The two answers

    /// [Install] / [Remove]: the user's yes, through the broker and nothing else.
    public func approve() async {
        guard case .asking(let request) = phase else { return }
        errorText = nil
        phase = .working(request.action)
        do {
            try await broker.approve(id: request.id)
        } catch {
            // The broker removed the request before running the performer, so a failed yes leaves nothing to
            // approve again: [Try again] asks afresh.
            phase = .finished(message: Self.words(error), retry: request.action)
            errorText = Self.words(error)
            return
        }
        await afterPerformed(request.action)
    }

    /// [Not now].
    public func notNow() {
        guard case .asking(let request) = phase else { return }
        errorText = nil
        if isPreview {
            isPreview = false
            showNextOrClose()
            return
        }
        do {
            try broker.decline(id: request.id)
        } catch {
            // Already withdrawn (an agent's sing.cancelInstall): nothing waits, so closing is the truth; say why.
            errorText = Self.words(error)
        }
        showNextOrClose()
    }

    /// [Try again] after a failed install or a refused yes: a fresh request from the person.
    public func tryAgain() async {
        guard case .finished(_, let retry?) = phase else { return }
        phase = .closed
        await ask(retry)
    }

    /// [Done] / closing an ended card.
    public func dismiss() {
        switch phase {
        case .finished, .closed: showNextOrClose()
        case .asking: notNow()
        case .working, .installing: break   // a running install is ended by [Cancel], never by closing
        }
    }

    // MARK: - The install's progress

    /// [Cancel] during the download: `SingingEngineInstallCoordinator.cancel()`, the call `sing.cancelInstall`
    /// makes once nothing is waiting for consent.
    public func cancelInstall() async {
        guard case .installing = phase else { return }
        do {
            phase = .installing(try await install.cancel())
        } catch {
            errorText = Self.words(error)
        }
    }

    /// One poll of the install (the view drives it at 1 Hz while the card shows progress).
    public func pollInstall() async {
        guard case .installing = phase else { return }
        let status = await install.status()
        guard case .installing = phase else { return }
        switch status.state {
        case .idle, .installing:
            phase = .installing(status)
        case .succeeded:
            phase = .finished(message: SingCopy.installDone, retry: nil)
            onInstalled?()
        case .failed:
            phase = .finished(message: SingInstallProgressText.stoppedSentence(status), retry: .installEngine)
        case .cancelled:
            phase = .finished(message: SingCopy.installCancelled, retry: .installEngine)
        }
    }

    // MARK: - Helpers

    private func afterPerformed(_ action: SingConsentAction) async {
        switch action {
        case .installEngine:
            phase = .installing(await install.status())
        case .uninstallEngine:
            phase = .finished(message: SingCopy.removed, retry: nil)
        }
    }

    private func showNextOrClose() {
        if waiting.isEmpty {
            phase = .closed
        } else {
            phase = .asking(waiting.removeFirst())
        }
    }

    /// An error's own sentence (`LocalizedError` first), never a paraphrase.
    static func words(_ error: any Error) -> String { SingScreenWords.sentence(error) }
}
