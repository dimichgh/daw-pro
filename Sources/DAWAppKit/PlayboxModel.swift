import Foundation
import AIServices
import DAWCore

/// m34-g — **PLAYBOX: the AI produces the INVITATION, the human produces the
/// performance.**
///
/// Headless state machine for the generate button on the Musical Typing strip.
/// No SwiftUI, no network, no store — the view is thin over this and the tests
/// drive it against a scripted fake generator (the `LyricsWorkshopModel`
/// precedent, which this deliberately copies rather than re-inventing: injected
/// factory that either yields a configured provider or THROWS the actionable
/// no-key error, injected context provider read fresh on every call, injected
/// applier so DAWAppKit never reaches the store).
///
/// ⛔⛔ **IT NEVER PLAYS OR RECORDS A NOTE.** Its entire output is a list of
/// scale degrees that light keys. **The take is genuinely the user's** — played
/// on the keys, captured through the same live path as any other take — and that
/// is the one property that makes this feature worth having. If you are about to
/// add a "play it for me" button here, you are deleting the feature.
///
/// ⛔⛔ **IT ALWAYS PRODUCES A SEQUENCE, AND IT ALWAYS SAYS WHO WROTE IT.** With
/// no API key configured the local variation path runs (`PlayboxProgression
/// .localVariation`) — a feature that is dead without a key is dead for anyone
/// who has not set one up. But *"the AI wrote this"* and *"we picked a stock
/// progression"* are different claims and only one of them is true at a time, so
/// every result carries a `PlayboxProvenance` and the strip paints and names it.
@MainActor
@Observable
public final class PlayboxModel {

    // MARK: - Inputs

    /// Optional free-text style hint, e.g. "dreamy indie". Blank contributes
    /// nothing to the prompt.
    public var style: String = ""

    /// How many chords to ask for — one per bar. Clamped by
    /// `PlayboxProgression.clampBars` at request time.
    public var bars: Int = 4

    /// Skip the AI leg and take the local variation path directly.
    ///
    /// ⛔⛔ **THIS IS WHAT KEEPS A TEST RUN OFF THE NETWORK AND OFF THE USER'S
    /// API BUDGET.** A staging app inherits the machine's environment, so a gate
    /// that drove the ordinary button would spend a real Anthropic call on every
    /// run — and would take a DIFFERENT branch on a machine with no key, which
    /// is the worst property a gate can have. The seam sets this; the UI never
    /// does.
    ///
    /// ⚠️ It is NOT a failure and carries no `reason`: choosing the library
    /// deliberately is a different event from falling back to it.
    ///
    /// ⛔⛔ **ONE-SHOT: `generate()` CONSUMES IT.** The debug seam that sets this
    /// is compiled into the SHIPPING app, so a sticky flag would let one debug
    /// call quietly turn the user's NEW LIGHTS button into a library-only button
    /// until they relaunched — a setting nothing on screen offers and nothing on
    /// screen could undo. Consuming it makes "this ONE generation skips the
    /// model" the only thing it can ever mean.
    public var preferLocal: Bool = false

    // MARK: - Output

    /// The last plan produced, whichever path produced it. Nil until the first
    /// generate.
    public private(set) var plan: PlayboxPlan?

    /// The lifecycle.
    ///
    /// ⚠️ **THERE IS NO `.failed` CASE, AND THAT IS DELIBERATE RATHER THAN
    /// OPTIMISTIC.** Every failure of the AI leg — no key, HTTP error, a model
    /// answering with prose — resolves to the local variation path, so the
    /// operation itself cannot fail from the user's chair. What changes is the
    /// PROVENANCE, which carries the reason and is shown. A `.failed` state here
    /// would be a second, quieter way of saying the same thing, and the two would
    /// drift.
    public enum State: Equatable, Sendable {
        case idle
        case generating
        case ready
    }
    public private(set) var state: State = .idle

    /// True while a generation is in flight — the view dims the button.
    public var isBusy: Bool { state == .generating }

    // MARK: - Injected seams

    /// Yields a configured progression generator, or THROWS the actionable
    /// no-provider error. A FACTORY, not a resolved generator, so the app
    /// re-resolves against the live key chain on each press (a key pasted into
    /// Settings must work without a relaunch) and so the no-key case is
    /// discovered at generate time.
    private let makeGenerator: @MainActor () throws -> any ChordProgressionGenerating

    /// The project's own musical facts — key, mode, tempo, section — read FRESH
    /// on every generate so a tempo change or a modulation lands.
    private let contextProvider: @MainActor () -> PlayboxRequest

    /// Hands the finished plan to the lit-key surface (the app calls
    /// `MusicalTypingController.applyPlaybox`). A closure so DAWAppKit's model
    /// layer never reaches the controller directly.
    private let applier: @MainActor (PlayboxPlan) -> Void

    /// Seeds the local variation. Injectable so a test can pin the fallback's
    /// output exactly; the default varies per press so pressing the button twice
    /// is not a do-nothing control.
    private let seedProvider: @MainActor () -> UInt64

    public init(
        makeGenerator: @escaping @MainActor () throws -> any ChordProgressionGenerating,
        contextProvider: @escaping @MainActor () -> PlayboxRequest = { PlayboxRequest() },
        applier: @escaping @MainActor (PlayboxPlan) -> Void,
        seedProvider: @escaping @MainActor () -> UInt64 = {
            UInt64(DispatchTime.now().uptimeNanoseconds)
        }
    ) {
        self.makeGenerator = makeGenerator
        self.contextProvider = contextProvider
        self.applier = applier
        self.seedProvider = seedProvider
    }

    // MARK: - Generate

    /// Build the request from the project, ask the model, validate, apply.
    ///
    /// ⭐ **THE FALLBACK IS DECIDED HERE, NOT IN THE PROVIDER**, because only
    /// this layer can tell the user which path ran. `ChordProgressionGenerating`
    /// conformers throw; a fallback hidden behind a successful return would be
    /// the record-says-X-source-says-Y defect wearing a feature's clothes.
    ///
    /// ⚠️ **THE MODEL IS ASKED FOR THE PROJECT'S CURRENT MODE AND THE RESULT IS
    /// APPLIED IN IT.** `MusicalTypingController.setProgression` switches the
    /// scale to a preset's mode; a generated sequence must never yank the key the
    /// user chose, so the request carries `keyMode` and `applyPlaybox` rebuilds
    /// the wrapper in the controller's own mode regardless of what came back.
    @discardableResult
    public func generate() async -> PlayboxPlan {
        state = .generating
        var request = contextProvider()
        request.bars = PlayboxProgression.clampBars(bars)
        let trimmedStyle = style.trimmingCharacters(in: .whitespacesAndNewlines)
        request.style = trimmedStyle.isEmpty ? nil : trimmedStyle

        let result = await resolvePlan(for: request)
        // ⛔ CONSUMED. See `preferLocal`'s own doc for why it cannot be sticky.
        preferLocal = false
        plan = result
        applier(result)
        state = .ready
        return result
    }

    /// The two paths, in one place, so "which generator ran and why" is a single
    /// readable decision rather than a nest.
    private func resolvePlan(for request: PlayboxRequest) async -> PlayboxPlan {
        // Deliberate local: not a failure, so no `reason`.
        if preferLocal {
            return PlayboxProgression.localVariation(request: request, seed: seedProvider())
        }
        do {
            return try await makeGenerator().generateProgression(request)
        } catch {
            // ⛔ THE MESSAGE IS THE ERROR'S OWN, WHICH IS KEY-FREE BY
            // CONSTRUCTION (`AIServiceError` reports provider NAMES and HTTP
            // statuses, never key material — see `KeyStore.swift`). Nothing here
            // reads, prints or interpolates a key.
            return PlayboxProgression.localVariation(
                request: request,
                seed: seedProvider()
            ).withReason(error.localizedDescription)
        }
    }
}

private extension PlayboxPlan {
    /// Re-stamps a local plan with WHY the local path ran, so the surface can
    /// distinguish "you have no key" from "the model's answer was unusable"
    /// without anybody reading a log.
    func withReason(_ reason: String) -> PlayboxPlan {
        PlayboxPlan(
            degrees: degrees,
            name: name,
            provenance: PlayboxProvenance(kind: provenance.kind,
                                          detail: provenance.detail,
                                          reason: reason))
    }
}
