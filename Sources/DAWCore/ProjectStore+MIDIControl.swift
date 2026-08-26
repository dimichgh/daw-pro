import Foundation

// MARK: - One pump pass

/// What one pass of the controller feed delivered (m28-knob).
///
/// A pass happens ~30 Hz for as long as the feed is live, and **`updates` is
/// usually empty** — that is not noise, it is the idle tick a knob gesture uses
/// to notice the hand stopped. A knob has no "release".
public struct MIDIControlPump: Sendable, Equatable {
    /// Every target that moved this pass, in arrival order. Usually empty.
    public var updates: [MIDIControlUpdate]

    /// ⭐ **The feed just STOPPED** — the last binding was removed, learn was
    /// cancelled with nothing bound, or the engine went away. A subscriber
    /// holding an open gesture must release it NOW: the idle tick it is waiting
    /// for is never coming, and a gesture that never ends leaves a live
    /// controller preview parked on the instrument, which is precisely what
    /// `PadPreviewController`'s rule 3 exists to prevent.
    public var feedEnded: Bool

    public init(updates: [MIDIControlUpdate] = [], feedEnded: Bool = false) {
        self.updates = updates
        self.feedEnded = feedEnded
    }
}

// MARK: - The controller

/// Owns the CC→target table and the engine subscription (m28-knob).
///
/// **The `AuditionController` idiom, on purpose:** a small main-actor object the
/// store owns, holding the policy, ENGINE-FREE except for the engine it is
/// handed per call. So every rule here is testable headless, with no CoreMIDI
/// client, no hardware, and no device ever opened.
///
/// ## The chain, end to end
///
/// ```
/// CoreMIDI receive thread                      (realtime, untouched)
///   └─ MIDIUMPParser.parse → LiveMIDIEvent
///        └─ MIDIInputRTContext.captureRing      ← THE EXISTING SEAM (SPSC ring)
///             └─ MIDIInputManager.drainCaptureRing()   ~30 Hz, MAIN ACTOR
///                  └─ controlChangeObserver([MIDIControlChangeEvent])
///                       └─ MIDIControlController.pump(_:)   ← here
///                            └─ MIDIControlMap.ingest       (learn + resolve)
///                                 └─ pumpHandler(MIDIControlPump)
///                                      └─ BreathPadModel.pumpExternalControl
/// ```
///
/// **No new receive-thread seam was invented.** The capture ring already
/// crossed every parsed event to the main actor at ~30 Hz for MIDI recording,
/// and it runs whether or not a take is open — which is exactly why a mapped
/// knob works with the transport stopped.
///
/// ## Laziness is preserved
///
/// The engine subscription is installed only when there is something to route
/// (a binding exists, or learn is armed) and torn down when there is not. That
/// matters because installing it CREATES THE CoreMIDI CLIENT and connects to
/// every online source — a real side effect on the user's devices, which must
/// follow from the user asking for a mapping, never from the app launching.
@MainActor
public final class MIDIControlController {

    /// The table. Mutated only through the methods below, so the engine
    /// subscription can never drift out of step with it.
    public private(set) var map = MIDIControlMap()

    /// Called ONCE PER PUMP PASS, empty batch included, plus once more with
    /// `feedEnded` when the subscription is torn down. Installed by the app.
    public var pumpHandler: ((MIDIControlPump) -> Void)?

    /// Called after any call that CHANGES the table — `setBindings`, `armLearn`,
    /// `cancelLearn` (m28-knob-ui).
    ///
    /// ⭐ **Why this exists, measured rather than imagined.** A render probe
    /// wrote a mapping through `midi.setControlMap` with the breath pad's panel
    /// already open, and the panel went on reading "No knobs mapped" over a live
    /// binding. This type is a plain final class, not `@Observable`, so nothing
    /// invalidates a view when an AGENT edits the table — and the pump only
    /// speaks when a controller actually moves, which a wire write does not do.
    ///
    /// ⛔ Deliberately **not** fired from `ingest`: a learn completing there is
    /// already announced through `pumpHandler`, and firing both would deliver
    /// one change twice at 30 Hz cadence.
    public var mapChangedHandler: (() -> Void)?

    /// Whether the engine subscription is currently installed.
    public private(set) var isSubscribed = false

    public init() {}

    // MARK: Editing

    /// Replaces the WHOLE table. `[]` clears it.
    ///
    /// A full SET rather than add/remove verbs: it is idempotent, an agent can
    /// read the map and write it back unchanged, and there is exactly one shape
    /// on the wire instead of an action discriminator whose branches drift.
    public func setBindings(_ bindings: [MIDIControlBinding],
                            engine: (any AudioEngineControlling)?) {
        map = MIDIControlMap(bindings: bindings)
        refreshSubscription(engine: engine)
        mapChangedHandler?()
    }

    /// Arms learn for `target` and brings the MIDI client UP.
    ///
    /// ⚠️ **The bring-up is the point, not a side effect.** The client is
    /// created lazily on the first armed instrument track or the first
    /// `availableMIDIInputs()` call; learn armed against a client that never
    /// existed sees no events at all, and "turn the knob, nothing happens" is
    /// indistinguishable from a broken mapping. Returns the input devices the
    /// engine can see, so the caller can say *"no MIDI inputs are connected"*
    /// instead of waiting forever.
    @discardableResult
    public func armLearn(target: MIDIControlTarget,
                         engine: (any AudioEngineControlling)?) -> [MIDIInputDevice] {
        map.armLearn(target: target)
        refreshSubscription(engine: engine)
        mapChangedHandler?()
        return engine?.availableMIDIInputs() ?? []
    }

    /// Disarms learn. Bindings are untouched.
    public func cancelLearn(engine: (any AudioEngineControlling)?) {
        map.cancelLearn()
        refreshSubscription(engine: engine)
        mapChangedHandler?()
    }

    // MARK: The pump

    /// One pass of the controller feed: ingest, then deliver.
    ///
    /// Public so the whole routing layer is drivable with NO hardware and no
    /// CoreMIDI client — tests synthesise events and call this directly. A gate
    /// that needs a physical knob is a flake generator, and this feature would
    /// otherwise have no gate at all.
    public func pump(_ events: [MIDIControlChangeEvent]) {
        let ingestion = map.ingest(events)
        pumpHandler?(MIDIControlPump(updates: ingestion.updates))
    }

    // MARK: The engine subscription

    /// The engine reference CHANGED — a new engine, or none at all. Re-points a
    /// wanted subscription at whatever is there now.
    ///
    /// ⚠️ Separate from `refreshSubscription` because that one is LATCHED on
    /// `isSubscribed`, and the latch describes a subscription on an engine that
    /// is no longer the engine. After a swap it says "subscribed" while the new
    /// engine has never heard of us: every state variable insists the feed is
    /// live and the knob is dead. That is the "the setter returned, so it took"
    /// shape. Clearing the latch first makes `refreshSubscription` re-derive it
    /// against the engine actually in hand.
    ///
    /// ⛔ It does NOT short-circuit on `isSubscribed`. It used to, and that hid a
    /// second bug: a table set with no engine attached must read `subscribed:
    /// false` (below), so the arriving engine would have found the latch already
    /// false and never subscribed at all — "bind before the engine exists" would
    /// be a permanently dead knob. Both directions are gated in
    /// `MIDIControlTests`.
    ///
    /// ⚠️ **KNOWN LIMIT, stated rather than papered over.** `ProjectStore.engine`
    /// is `weak`, and a weak reference going nil by DEALLOCATION does not fire
    /// `didSet` — so this is not called when the engine simply dies, and the
    /// latch would read stale until the next explicit assignment. Harmless in
    /// practice (the engine owns the observer closure, which dies with it, and
    /// the closure captures `self` weakly so nothing leaks either way), and it
    /// is the same limit every other handler in that `didSet` already has.
    public func reattach(engine: (any AudioEngineControlling)?) {
        let wasSubscribed = isSubscribed
        isSubscribed = false
        refreshSubscription(engine: engine)
        if wasSubscribed && !isSubscribed {
            // The engine we were subscribed to is gone and nothing replaced it.
            // `refreshSubscription` cannot announce this — it saw false==false
            // and returned — so say it here: anyone mid-gesture must release NOW
            // rather than wait for an idle tick from a feed that no longer
            // exists. See `MIDIControlPump.feedEnded`.
            pumpHandler?(MIDIControlPump(feedEnded: true))
        }
    }

    /// (Re)installs or tears down the engine subscription to match the table.
    /// Idempotent — safe to call after every mutation.
    ///
    /// ⛔ **`engine != nil` is part of "wanted", not a convenience.** With no
    /// engine there is nothing to subscribe to, so latching `isSubscribed = true`
    /// would make `midi.getControlMap` report a live feed to an agent while
    /// nothing whatsoever is listening — a working-looking answer for a
    /// subscription that does not exist. The latch must describe reality, not
    /// intent; the intent is already fully described by `map.bindings`.
    public func refreshSubscription(engine: (any AudioEngineControlling)?) {
        let wanted = (!map.bindings.isEmpty || map.isLearning) && engine != nil
        guard wanted != isSubscribed else { return }
        isSubscribed = wanted
        if wanted {
            engine?.setControlChangeObserver { [weak self] events in
                self?.pump(events)
            }
        } else {
            engine?.setControlChangeObserver(nil)
            // The feed is gone: anyone mid-gesture must release NOW. See
            // `MIDIControlPump.feedEnded`.
            pumpHandler?(MIDIControlPump(feedEnded: true))
        }
    }
}

// MARK: - Store surface

extension ProjectStore {

    /// The CC→target table and its engine subscription (m28-knob).
    ///
    /// ⛔ **Session state, NOT project state.** It is not in `ProjectDocument`
    /// and does not survive a relaunch — a controller mapping describes the
    /// hardware on THIS desk, and opening someone else's song must not re-point
    /// your knobs. See `MIDIControlMap`.
    public var midiControlMap: MIDIControlMap { midiControl.map }

    /// Replaces the whole CC→target table. `[]` clears it.
    public func setMIDIControlBindings(_ bindings: [MIDIControlBinding]) {
        midiControl.setBindings(bindings, engine: engine)
    }

    /// Arms MIDI learn for `target` and brings the MIDI client up; returns the
    /// inputs the engine can see, so a caller can report "nothing is plugged
    /// in" rather than leaving a learn armed against silence.
    @discardableResult
    public func armMIDIControlLearn(target: MIDIControlTarget) -> [MIDIInputDevice] {
        midiControl.armLearn(target: target, engine: engine)
    }

    /// Disarms MIDI learn, changing no bindings.
    public func cancelMIDIControlLearn() {
        midiControl.cancelLearn(engine: engine)
    }

    /// Drives one pump pass by hand — the headless test seam, and the reason
    /// this feature ships with a gate that needs no hardware.
    public func pumpMIDIControl(_ events: [MIDIControlChangeEvent]) {
        midiControl.pump(events)
    }
}
