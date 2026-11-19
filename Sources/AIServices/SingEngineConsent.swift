import Foundation

/// The two things only the user may say yes to (design §2.5 "Consent"; user ruling `sing-consent` = "Ask me
/// first"): downloading the singing engine (~7 GB) and deleting it.
public enum SingConsentAction: String, Codable, Sendable, CaseIterable {
    case installEngine
    case uninstallEngine
}

/// One question waiting for the user's click.
public struct SingConsentRequest: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var action: SingConsentAction
    /// True when an AI agent asked over the wire: the window adds §5.7's "An AI agent asked for this."
    public var fromAgent: Bool
    public var requestedAt: Date
    /// What the window says (§2.5's agent-window copy).
    public var message: String

    public init(id: String, action: SingConsentAction, fromAgent: Bool, requestedAt: Date, message: String) {
        self.id = id
        self.action = action
        self.fromAgent = fromAgent
        self.requestedAt = requestedAt
        self.message = message
    }
}

/// Why a consent call did nothing.
public enum SingConsentError: Error, Equatable, LocalizedError {
    case noSuchRequest(String)
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .noSuchRequest(let id):
            return "There is no install or removal waiting for an answer with id \"\(id)\"."
        case .notConnected:
            return "The singing engine's install and removal are not connected in this DAW Pro session."
        }
    }
}

/// THE seam between an agent's request and the user's click (p2-sing-e part 2).
///
/// - `sing.installEngine` / `sing.uninstallEngine` from the wire call `request(_:fromAgent:)`, which posts a
///   request (`onRequest` tells the window, item f) and returns `.awaitingUserConsent`. NOTHING is performed.
/// - The window's [Install] / [Remove] button calls `approve(id:)`: only then does `performer` run.
/// - [Not now] calls `decline(id:)`.
/// - `autoConsent` is the staging-E2E launch flag `DAWPRO_SING_TEST_AUTO_CONSENT=1`. It is read from the
///   process environment ONCE, by whoever builds the broker at launch; no wire verb can set it, because nothing
///   on the wire can reach this property (it is a `let`).
///
/// A second request for an action already waiting returns the SAME request (one window, never a stack of them).
@MainActor
public final class SingConsentBroker {

    public enum Outcome: Equatable, Sendable {
        /// Posted; nothing happens until the user clicks.
        case awaitingUserConsent(SingConsentRequest)
        /// Performed at once (`autoConsent`, the staging flag).
        case performed
    }

    /// §2.5's window text for an agent's request.
    /// `nonisolated`: pure (fixed sentences, no state), so a nonisolated caller (the consent card's
    /// text, `SingConsentCardText`) can read the ONE home of this copy (orchestrator, 2026-10-06).
    nonisolated public static func message(for action: SingConsentAction, fromAgent: Bool) -> String {
        let ask: String
        switch action {
        case .installEngine:
            ask = fromAgent
                ? "An AI agent wants to install the singing engine: about 7 GB, one time."
                : "To sing, DAW Pro needs its singing engine: a one-time download of about 7 GB. "
                    + "It runs on this Mac, and nothing you sing leaves it."
        case .uninstallEngine:
            // PROVISIONAL (§2.5 says only "works the same way"; no §5.7 row).
            ask = fromAgent
                ? "An AI agent wants to remove the singing engine from this Mac. Your voices and songs stay."
                : "Remove the singing engine from this Mac? Your voices and songs stay."
        }
        return ask
    }

    public let autoConsent: Bool
    public private(set) var pending: [SingConsentRequest] = []
    /// Told about every NEW request (the window, item f). Not told about a repeat of one already waiting.
    public var onRequest: (@MainActor (SingConsentRequest) -> Void)?
    /// What a yes does. Installed once by the component that owns the engine (the wire handlers); nil until
    /// then, and a click on a request then fails loudly rather than doing nothing.
    public var performer: (@MainActor (SingConsentAction) async throws -> Void)?
    private let now: () -> Date

    public init(autoConsent: Bool, now: @escaping () -> Date = { Date() }) {
        self.autoConsent = autoConsent
        self.now = now
    }

    /// The launch-time reading of the staging flag. The ONLY place it is read.
    public nonisolated static func autoConsentFromEnvironment(_ environment: [String: String]) -> Bool {
        environment["DAWPRO_SING_TEST_AUTO_CONSENT"] == "1"
    }

    public func pendingRequest(for action: SingConsentAction) -> SingConsentRequest? {
        pending.first { $0.action == action }
    }

    /// Asks the user (or, under the staging flag, performs at once).
    public func request(_ action: SingConsentAction, fromAgent: Bool) async throws -> Outcome {
        if autoConsent {
            guard let performer else { throw SingConsentError.notConnected }
            try await performer(action)
            return .performed
        }
        if let waiting = pendingRequest(for: action) { return .awaitingUserConsent(waiting) }
        let request = SingConsentRequest(
            id: "consent-" + UUID().uuidString.lowercased(), action: action, fromAgent: fromAgent,
            requestedAt: now(), message: Self.message(for: action, fromAgent: fromAgent))
        pending.append(request)
        onRequest?(request)
        return .awaitingUserConsent(request)
    }

    /// The user's yes. Removes the request, then performs it.
    public func approve(id: String) async throws {
        guard let index = pending.firstIndex(where: { $0.id == id }) else {
            throw SingConsentError.noSuchRequest(id)
        }
        guard let performer else { throw SingConsentError.notConnected }
        let request = pending.remove(at: index)
        try await performer(request.action)
    }

    /// The user's "Not now".
    public func decline(id: String) throws {
        guard let index = pending.firstIndex(where: { $0.id == id }) else {
            throw SingConsentError.noSuchRequest(id)
        }
        pending.remove(at: index)
    }

    /// Withdraws a waiting request for `action` (an agent's `sing.cancelInstall` before the user answered).
    @discardableResult
    public func withdraw(_ action: SingConsentAction) -> SingConsentRequest? {
        guard let index = pending.firstIndex(where: { $0.action == action }) else { return nil }
        return pending.remove(at: index)
    }
}
