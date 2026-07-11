import Foundation
import Testing
@testable import DAWAppKit

/// Headless coverage for the onboarding tour (M8 ob-a; design in
/// docs/research/design-onboarding.md). The state machine, the signal-driven
/// auto-advance (with its no-op rules), injected persistence (mid-tour resume +
/// terminal stickiness), and the copy-style rules over the whole catalog are all
/// proven without a running app — the `PanelDensityStore` + `ExplainCatalog`
/// precedents. The model NEVER reads `ProjectStore`, so the entire tour is testable
/// against `signal(_:)` alone.
@MainActor
@Suite("Onboarding tour — flow + catalog (M8 ob-a)")
struct OnboardingModelTests {

    /// A spy backing that records every write, so persistence can be asserted (and
    /// asserted to go ONLY through the backing).
    final class SpyBacking: OnboardingStateBacking {
        private(set) var stored: OnboardingState?
        private(set) var writes: [OnboardingState] = []

        init(_ initial: OnboardingState? = nil) { self.stored = initial }

        func loadState() -> OnboardingState? { stored }
        func storeState(_ state: OnboardingState) {
            writes.append(state)
            stored = state
        }
    }

    /// Drives a signal step to its next step using the step's OWN expected signal.
    private func expectedSignal(_ step: OnboardingStep) -> OnboardingSignal {
        OnboardingCatalog.info(for: step).signal!
    }

    // MARK: - Defaults / eligibility

    @Test("a fresh model is inactive and offers the tour")
    func freshDefaults() {
        let model = OnboardingModel(backing: SpyBacking())
        #expect(model.state == .inactive)
        #expect(model.shouldOfferTour)
        #expect(model.currentStep == nil)
        #expect(model.currentInfo == nil)
        #expect(model.stepIndex == nil)
    }

    @Test("a model with no injected backing still starts inactive")
    func defaultBackingInactive() {
        let model = OnboardingModel()
        #expect(model.state == .inactive)
        #expect(model.shouldOfferTour)
    }

    // MARK: - Happy path (all 7 steps via signals)

    @Test("the full happy path walks all seven steps to completed via signals")
    func happyPathThroughAllSteps() {
        let model = OnboardingModel(backing: SpyBacking())

        // 1. welcome — no signal; advances on Start.
        model.begin()
        #expect(model.currentStep == .welcome)
        #expect(model.stepIndex == 0)
        #expect(!model.shouldOfferTour)          // an in-progress tour is not offered
        model.advance()                          // Start

        // 2. generate → 3. listen → 4. shape → 5. mix → 6. export, each via its
        // own expected signal.
        for step in [OnboardingStep.generate, .listen, .shape, .mix, .export] {
            #expect(model.currentStep == step)
            model.signal(expectedSignal(step))
        }

        // 7. done — terminal step; Finish completes the tour.
        #expect(model.currentStep == .done)
        model.advance()                          // Finish
        #expect(model.state == .completed)
        #expect(model.currentStep == nil)
        #expect(!model.shouldOfferTour)          // never re-offered
    }

    @Test("every middle step advances on exactly its catalog signal, in order")
    func signalOrderMatchesCatalog() {
        // The five signal steps map one-to-one onto OnboardingSignal, in enum order.
        let model = OnboardingModel(backing: SpyBacking())
        model.begin()
        model.advance()  // → generate
        let expected: [(OnboardingStep, OnboardingSignal)] = [
            (.generate, .projectGainedContent),
            (.listen, .playbackStarted),
            (.shape, .editPerformed),
            (.mix, .mixerAdjusted),
            (.export, .renderCompleted),
        ]
        for (step, signal) in expected {
            #expect(model.currentStep == step)
            #expect(OnboardingCatalog.info(for: step).signal == signal)
            model.signal(signal)
        }
        #expect(model.currentStep == .done)
    }

    // MARK: - Signal no-op rules

    @Test("a wrong signal on an active step is an ignored no-op")
    func wrongSignalIgnored() {
        let model = OnboardingModel(backing: SpyBacking())
        model.begin(); model.advance()           // → generate (expects projectGainedContent)
        #expect(model.currentStep == .generate)
        model.signal(.playbackStarted)           // wrong signal for this step
        #expect(model.currentStep == .generate)  // did not advance
        model.signal(.renderCompleted)           // still wrong
        #expect(model.currentStep == .generate)
        model.signal(.projectGainedContent)      // the right one
        #expect(model.currentStep == .listen)
    }

    @Test("a duplicate signal after the step advanced is a no-op")
    func duplicateSignalIgnored() {
        let model = OnboardingModel(backing: SpyBacking())
        model.begin(); model.advance()           // → generate
        model.signal(.projectGainedContent)      // advances to listen
        #expect(model.currentStep == .listen)
        model.signal(.projectGainedContent)      // stale duplicate — listen expects playbackStarted
        #expect(model.currentStep == .listen)    // still on listen, unmoved
    }

    @Test("a signal on welcome (no expected signal) never advances it")
    func signalOnNoSignalStepIgnored() {
        let model = OnboardingModel(backing: SpyBacking())
        model.begin()
        #expect(model.currentStep == .welcome)
        for s in OnboardingSignal.allCases { model.signal(s) }
        #expect(model.currentStep == .welcome)   // welcome only advances on advance()
    }

    @Test("a signal while inactive is a no-op")
    func signalWhileInactiveIgnored() {
        let model = OnboardingModel(backing: SpyBacking())
        for s in OnboardingSignal.allCases { model.signal(s) }
        #expect(model.state == .inactive)
    }

    // MARK: - Manual advance / skip on signal steps

    @Test("a signal step can be advanced manually so a missed signal never traps")
    func manualAdvanceOnSignalStep() {
        let model = OnboardingModel(backing: SpyBacking())
        model.begin(); model.advance()           // → generate
        model.advance()                          // manual next, no signal
        #expect(model.currentStep == .listen)
        model.advance()                          // → shape
        #expect(model.currentStep == .shape)
    }

    @Test("skipStep moves a task step forward")
    func skipStepAdvancesTaskStep() {
        let model = OnboardingModel(backing: SpyBacking())
        model.begin(); model.advance()           // → generate
        model.skipStep()
        #expect(model.currentStep == .listen)
        model.skipStep()
        #expect(model.currentStep == .shape)
    }

    @Test("skipStep is a no-op on welcome and done (no signal — explicit CTAs)")
    func skipStepNoOpOnNonSignalSteps() {
        let model = OnboardingModel(backing: SpyBacking())
        model.begin()
        #expect(model.currentStep == .welcome)
        model.skipStep()
        #expect(model.currentStep == .welcome)   // welcome is not skippable

        // Walk to done, then confirm skipStep does nothing there either.
        model.advance()
        for step in [OnboardingStep.generate, .listen, .shape, .mix, .export] {
            model.signal(expectedSignal(step))
        }
        #expect(model.currentStep == .done)
        model.skipStep()
        #expect(model.currentStep == .done)      // done is finished, not skipped
        #expect(model.state != .completed)
    }

    @Test("advance from export lands on done, not completed")
    func advanceIntoDoneIsNotCompletion() {
        let model = OnboardingModel(backing: SpyBacking())
        model.begin(); model.advance()
        for step in [OnboardingStep.generate, .listen, .shape, .mix] {
            model.signal(expectedSignal(step))
        }
        #expect(model.currentStep == .export)
        model.advance()                          // export → done (still active)
        #expect(model.currentStep == .done)
        #expect(model.state == .active(stepIndex: OnboardingStep.done.index))
    }

    // MARK: - Dismiss (terminal, never re-offers, replayable)

    @Test("dismissTour is terminal, never re-offers, and ignores later signals")
    func dismissIsTerminal() {
        let model = OnboardingModel(backing: SpyBacking())
        model.begin(); model.advance()           // → generate
        model.dismissTour()
        #expect(model.state == .dismissed)
        #expect(!model.shouldOfferTour)
        // Signals after dismissal do nothing.
        for s in OnboardingSignal.allCases { model.signal(s) }
        #expect(model.state == .dismissed)
        // advance / skip / begin are inert on a terminal state too.
        model.advance(); model.skipStep(); model.begin()
        #expect(model.state == .dismissed)
    }

    @Test("dismissTour from inactive is allowed; dismiss is idempotent on terminals")
    func dismissFromInactiveAndIdempotent() {
        let model = OnboardingModel(backing: SpyBacking())
        model.dismissTour()                      // skip before even starting
        #expect(model.state == .dismissed)
        model.dismissTour()                      // idempotent
        #expect(model.state == .dismissed)
    }

    @Test("a completed tour is not re-dismissed")
    func completedNotOverwrittenByDismiss() {
        let model = OnboardingModel(backing: SpyBacking())
        model.begin(); model.advance()
        for step in [OnboardingStep.generate, .listen, .shape, .mix, .export] {
            model.signal(expectedSignal(step))
        }
        model.advance()                          // Finish → completed
        #expect(model.state == .completed)
        model.dismissTour()                      // no-op on a finished tour
        #expect(model.state == .completed)
    }

    // MARK: - Completed terminal / reset

    @Test("completed never re-offers, and reset restores eligibility")
    func completedThenReset() {
        let model = OnboardingModel(backing: SpyBacking())
        model.begin(); model.advance()
        for step in [OnboardingStep.generate, .listen, .shape, .mix, .export] {
            model.signal(expectedSignal(step))
        }
        model.advance()
        #expect(model.state == .completed)
        #expect(!model.shouldOfferTour)
        model.reset()                            // the "Replay tour" seam
        #expect(model.state == .inactive)
        #expect(model.shouldOfferTour)
        // And it can run again after reset.
        model.begin()
        #expect(model.currentStep == .welcome)
    }

    @Test("reset restores eligibility from a dismissed tour too")
    func resetFromDismissed() {
        let model = OnboardingModel(backing: SpyBacking())
        model.dismissTour()
        model.reset()
        #expect(model.state == .inactive)
        #expect(model.shouldOfferTour)
    }

    // MARK: - begin() guard

    @Test("begin only starts from inactive")
    func beginOnlyFromInactive() {
        let model = OnboardingModel(backing: SpyBacking())
        model.begin()
        model.advance()                          // → generate
        model.begin()                            // no restart mid-tour
        #expect(model.currentStep == .generate)
    }

    // MARK: - Persistence

    @Test("every transition writes through the injected backing")
    func writeThrough() {
        let backing = SpyBacking()
        let model = OnboardingModel(backing: backing)
        model.begin()
        #expect(backing.stored == .active(stepIndex: 0))
        model.advance()
        #expect(backing.stored == .active(stepIndex: 1))
        model.dismissTour()
        #expect(backing.stored == .dismissed)
        #expect(backing.writes.contains(.active(stepIndex: 0)))
        #expect(backing.writes.contains(.dismissed))
    }

    @Test("mid-tour progress survives a fresh model over the same backing (relaunch)")
    func midTourResumeRoundTrip() {
        let backing = SpyBacking()
        let first = OnboardingModel(backing: backing)
        first.begin(); first.advance()           // → generate
        first.signal(.projectGainedContent)      // → listen (index 2)
        #expect(first.currentStep == .listen)

        // Simulate relaunch: a brand-new model over the SAME backing resumes.
        let second = OnboardingModel(backing: backing)
        #expect(second.state == .active(stepIndex: OnboardingStep.listen.index))
        #expect(second.currentStep == .listen)
        #expect(!second.shouldOfferTour)
    }

    @Test("terminal states persist across a new model instance")
    func terminalResumeRoundTrip() {
        let backing = SpyBacking()
        let first = OnboardingModel(backing: backing)
        first.dismissTour()
        let second = OnboardingModel(backing: backing)
        #expect(second.state == .dismissed)
        #expect(!second.shouldOfferTour)
    }

    // MARK: - OnboardingState serialization

    @Test("OnboardingState round-trips its persisted form; bad values fall back")
    func stateSerialization() {
        for state: OnboardingState in [.inactive, .active(stepIndex: 0),
                                       .active(stepIndex: 3), .completed, .dismissed] {
            #expect(OnboardingState(persisted: state.persistedValue) == state)
        }
        #expect(OnboardingState(persisted: "active:2") == .active(stepIndex: 2))
        // Out-of-range / malformed → nil (model then falls back to .inactive).
        #expect(OnboardingState(persisted: "active:99") == nil)
        #expect(OnboardingState(persisted: "active:-1") == nil)
        #expect(OnboardingState(persisted: "active:") == nil)
        #expect(OnboardingState(persisted: "active") == nil)
        #expect(OnboardingState(persisted: "bogus") == nil)
        #expect(OnboardingState(persisted: "") == nil)
    }

    @Test("a corrupt stored index resolves to inactive, not a crash")
    func corruptStoredIndexFallsBackToInactive() {
        // A backing holding an out-of-range index (stale build). loadState parses
        // it to nil, so the model reads inactive.
        final class BadBacking: OnboardingStateBacking {
            func loadState() -> OnboardingState? { OnboardingState(persisted: "active:999") }
            func storeState(_ state: OnboardingState) {}
        }
        let model = OnboardingModel(backing: BadBacking())
        #expect(model.state == .inactive)
        #expect(model.shouldOfferTour)
    }

    @Test("InMemory + UserDefaults backings both round-trip; key is onboarding.state")
    func backingsRoundTrip() {
        let mem = InMemoryOnboardingStateBacking()
        #expect(mem.loadState() == nil)
        mem.storeState(.active(stepIndex: 4))
        #expect(mem.loadState() == .active(stepIndex: 4))

        let suite = "OnboardingModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let ud = UserDefaultsOnboardingStateBacking(defaults: defaults)
        #expect(ud.loadState() == nil)
        ud.storeState(.completed)
        #expect(ud.loadState() == .completed)
        #expect(defaults.string(forKey: "onboarding.state") == "completed")  // keyed onboarding.state
        ud.storeState(.active(stepIndex: 2))
        #expect(defaults.string(forKey: "onboarding.state") == "active:2")
    }

    // MARK: - Signal / step raw-value parsing (ob-b staging command contract)

    @Test("OnboardingSignal and OnboardingStep round-trip their raw values")
    func rawValueParsing() {
        #expect(OnboardingSignal(rawValue: "projectGainedContent") == .projectGainedContent)
        #expect(OnboardingSignal(rawValue: "renderCompleted") == .renderCompleted)
        #expect(OnboardingSignal(rawValue: "bogus") == nil)
        #expect(OnboardingStep(rawValue: "welcome") == .welcome)
        #expect(OnboardingStep(rawValue: "done") == .done)
        #expect(OnboardingStep(rawValue: "Welcome") == nil)   // case-sensitive wire value
    }

    // MARK: - Catalog completeness + copy style rules

    @Test("the catalog has exactly one entry per step, in tour order")
    func catalogCompleteAndOrdered() {
        #expect(OnboardingCatalog.steps.count == OnboardingStep.allCases.count)
        #expect(OnboardingCatalog.steps.map(\.step) == OnboardingStep.allCases)
        for step in OnboardingStep.allCases {
            #expect(OnboardingCatalog.info(for: step).step == step)
        }
    }

    @Test("exactly welcome and done carry no signal; the five middle steps each do")
    func signalPresenceMatchesDesign() {
        for info in OnboardingCatalog.steps {
            switch info.step {
            case .welcome, .done:
                #expect(info.signal == nil, "\(info.step.rawValue) should have no signal")
            default:
                #expect(info.signal != nil, "\(info.step.rawValue) needs a completion signal")
            }
        }
        // The five middle signals are exactly OnboardingSignal, no dupes.
        let signals = OnboardingCatalog.steps.compactMap(\.signal)
        #expect(Set(signals).count == 5)
        #expect(Set(signals) == Set(OnboardingSignal.allCases))
    }

    @Test("every non-nil anchor is a registered ExplainID with catalog copy")
    func anchorsAreRegisteredExplainIDs() {
        for info in OnboardingCatalog.steps {
            guard let anchor = info.anchor else { continue }
            // Registered in the enum, and actually carries Explain copy — so the
            // ob-b card points at a real, explainable control.
            #expect(ExplainID.allCases.contains(anchor),
                    "\(info.step.rawValue) anchors an unregistered id")
            #expect(ExplainCatalog.entry(for: anchor) != nil,
                    "\(info.step.rawValue) anchor \(anchor.rawValue) has no explain entry")
        }
    }

    @Test("every title is a short, non-empty header (≤ 28 chars)")
    func titleLength() {
        for info in OnboardingCatalog.steps {
            let title = info.title.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(!title.isEmpty, "\(info.step.rawValue) has an empty title")
            #expect(info.title.count <= 28,
                    "\(info.step.rawValue) title too long: \"\(info.title)\" (\(info.title.count))")
        }
    }

    @Test("every body is 40–280 chars and ends on a full stop")
    func bodyShapeAndLength() {
        for info in OnboardingCatalog.steps {
            #expect(info.body.count >= 40, "\(info.step.rawValue) body too short: \(info.body.count)")
            #expect(info.body.count <= 280, "\(info.step.rawValue) body too long: \(info.body.count)")
            let last = info.body.trimmingCharacters(in: .whitespacesAndNewlines).last
            #expect(last == "." || last == "!" || last == "?",
                    "\(info.step.rawValue) body doesn't end cleanly: …\(String(info.body.suffix(12)))")
        }
    }

    @Test("every cta is a short, non-empty label")
    func ctaLabels() {
        for info in OnboardingCatalog.steps {
            let cta = info.cta.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(!cta.isEmpty, "\(info.step.rawValue) has an empty CTA")
            #expect(info.cta.count <= 20, "\(info.step.rawValue) CTA too long: \"\(info.cta)\"")
        }
    }

    @Test("no step body carries raw unit jargon a newcomer wouldn't know")
    func bodyAvoidsRawUnitJargon() {
        // The ExplainCatalog beginner rule, applied to the tour copy: bare units
        // (dB / Hz / …) are meaningless to a beginner, so the copy spells concepts
        // out ("louder or quieter", "the tempo faster or slower"). Longer tokens
        // lead so dBFS isn't half-matched as dB; letter look-arounds keep real words
        // safe ("terms" ≠ a bare "ms").
        let bannedUnits = ["dBFS", "LUFS", "kHz", "RMS", "dB", "Hz", "ms"]
        let pattern = "(?<![A-Za-z])(" + bannedUnits.joined(separator: "|") + ")(?![A-Za-z])"
        let regex = try! NSRegularExpression(pattern: pattern)
        for info in OnboardingCatalog.steps {
            let range = NSRange(info.body.startIndex..., in: info.body)
            #expect(regex.firstMatch(in: info.body, range: range) == nil,
                    "\(info.step.rawValue) body uses raw jargon")
        }
    }

    @Test("titles read as distinct steps")
    func titlesAreDistinct() {
        let titles = OnboardingCatalog.steps.map(\.title)
        #expect(Set(titles).count == titles.count, "two steps share a title")
    }

    // MARK: - Reference copy pins (a change here should be deliberate)

    @Test("reference copy pins the promise, the keyless fallback, and the payoff")
    func referenceCopyPins() {
        #expect(OnboardingCatalog.info(for: .welcome).title == "Your First Song")
        #expect(OnboardingCatalog.info(for: .welcome).cta == "Start")
        // The generate step names the instant-template fallback (keyless/offline path).
        #expect(OnboardingCatalog.info(for: .generate).body.contains("template"))
        #expect(OnboardingCatalog.info(for: .generate).anchor == .aiSketchpad)
        // The listen step sells the Vibe Meter.
        #expect(OnboardingCatalog.info(for: .listen).body.contains("Vibe Meter"))
        #expect(OnboardingCatalog.info(for: .done).cta == "Finish")
    }
}
