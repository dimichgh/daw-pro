import Foundation

// MARK: - The event

/// One hardware controller change, as the MAPPING layer sees it (m28-knob).
///
/// Deliberately NOT `LiveMIDIEvent` (DAWEngine-internal, 16-byte POD, "kind" as
/// a raw `UInt8`): this crosses the engine boundary into DAWCore, so it names
/// its fields the way a mapping table needs them — a controller NUMBER and a
/// VALUE, not `pitch`/`velocity` under the §4.1 one-data-rule.
///
/// `hostTime` is carried but unused by the map; it exists so a later ordering
/// or velocity-of-turn feature does not need a new type.
public struct MIDIControlChangeEvent: Sendable, Equatable {
    /// The source endpoint's `kMIDIPropertyUniqueID` — the same identity
    /// `MIDIInputDevice.uniqueID` reports, stable across reconnects.
    public var sourceID: Int32
    /// 0…15.
    public var channel: Int
    /// The controller number, 0…127.
    public var controller: Int
    /// The controller value, 0…127.
    public var value: Int
    /// mach ticks, as the receive thread stamped it.
    public var hostTime: UInt64

    public init(sourceID: Int32, channel: Int, controller: Int, value: Int,
                hostTime: UInt64 = 0) {
        self.sourceID = sourceID
        self.channel = channel
        self.controller = controller
        self.value = value
        self.hostTime = hostTime
    }

    /// The value as 0…1. **`/ 127`, not `/ 128`**, so a controller at its
    /// maximum reads exactly 1.0 — a radius that could never quite reach the rim
    /// would be a control with an unreachable end, and the pad's `canApply`
    /// turns on `radius > 0` at the other end.
    public var normalized: Double {
        min(1, max(0, Double(value) / 127))
    }
}

// MARK: - What a controller can drive

/// The things a mapped hardware control can move (m28-knob).
///
/// ⭐ **The table is not hard-wired to the breath pad.** A target is a name plus
/// a 0…1 contract; the map resolves any of them and the DELIVERY of an update is
/// the subscriber's business (`ProjectStore.midiControlHandler`). Adding a
/// target later is one case here and one branch at the delivery site — no new
/// routing, no new wire verb, no second table.
///
/// The two that exist are the breath pad's two dimensions, and they were chosen
/// because they are exactly what a hardware knob is good at:
///
/// - **one knob on `breathPadAngle` walks the dot around the ring** at whatever
///   depth it currently sits — the vector-synth gesture, and the single-knob
///   case is the GOOD case here rather than a degraded two-knob one;
/// - **a second knob on `breathPadRadius`** adds depth, and the pair covers the
///   pad completely.
public enum MIDIControlTarget: String, Sendable, CaseIterable, Codable {
    /// Walks the breath pad's dot around the ring. 0 → the top of the circle
    /// (ring index 0), 1 → all the way round to the top again.
    case breathPadAngle
    /// The breath pad's depth, 0 (centre — "exactly as written") … 1 (the rim).
    case breathPadRadius

    /// A beginner-readable name (docs/DESIGN-LANGUAGE.md).
    public var displayName: String {
        switch self {
        case .breathPadAngle: return "Breath pad — travel around the ring"
        case .breathPadRadius: return "Breath pad — depth"
        }
    }

    /// One sentence on what turning the control will do.
    public var summary: String {
        switch self {
        case .breathPadAngle:
            return "Turns the pad's dot around the circle of effort gestures, at whatever depth "
                + "it is already at. One knob on this is the whole gesture."
        case .breathPadRadius:
            return "Moves the pad's dot in and out. Fully in means \"exactly as written\" and "
                + "nothing is shaped; fully out is the gesture at full strength."
        }
    }
}

// MARK: - One binding

/// "Controller N on this device drives that target." (m28-knob)
///
/// ⚠️ **ABSOLUTE controllers only.** The value is read as a POSITION (0…127 →
/// 0…1), which is what a potentiometer sends. An endless/relative encoder sends
/// deltas (typically 1 and 127, or 65/63) and would read as a jump to either end
/// of the range — so this map does not support one yet, and says so instead of
/// half-working. Relative modes are an additive field on this struct.
public struct MIDIControlBinding: Sendable, Equatable, Codable {
    public var target: MIDIControlTarget
    /// The controller number, 0…127.
    public var controller: Int
    /// The MIDI channel to accept, or nil for OMNI.
    ///
    /// ⭐ **LEARN LEAVES THIS NIL ON PURPOSE.** A knob is identified by its CC
    /// number and the box it is on; the channel is an accident of that box's
    /// global setting, and binding to it is the classic MIDI-learn footgun —
    /// the user changes the controller's global channel months later and the
    /// mapping dies silently. An agent that genuinely wants a channel filter
    /// sets one explicitly through `midi.setControlMap`.
    public var channel: Int?
    /// The source endpoint to accept, or nil for ANY device. Learn fills this
    /// in: two controllers with the same CC number on the same knob is common,
    /// and `uniqueID` is stable across reconnects.
    public var sourceID: Int32?
    /// Flips the sweep, for a control wired backwards or mounted upside down.
    public var inverted: Bool

    public init(target: MIDIControlTarget, controller: Int, channel: Int? = nil,
                sourceID: Int32? = nil, inverted: Bool = false) {
        self.target = target
        self.controller = controller
        self.channel = channel
        self.sourceID = sourceID
        self.inverted = inverted
    }

    /// Does `event` belong to this binding?
    public func matches(_ event: MIDIControlChangeEvent) -> Bool {
        guard event.controller == controller else { return false }
        if let channel, event.channel != channel { return false }
        if let sourceID, event.sourceID != sourceID { return false }
        return true
    }

    /// The 0…1 the target receives for this event.
    public func value(for event: MIDIControlChangeEvent) -> Double {
        let v = event.normalized
        return inverted ? 1 - v : v
    }
}

// MARK: - One resolved move

/// "This target just moved to this value." The delivery-side POD.
public struct MIDIControlUpdate: Sendable, Equatable {
    public var target: MIDIControlTarget
    /// 0…1, already inverted if the binding says so.
    public var value: Double
    /// Which controller produced it — carried so a panel can say WHICH knob
    /// moved without a second lookup.
    public var controller: Int
    public var sourceID: Int32

    public init(target: MIDIControlTarget, value: Double, controller: Int, sourceID: Int32) {
        self.target = target
        self.value = value
        self.controller = controller
        self.sourceID = sourceID
    }
}

// MARK: - The table

/// **THE ONE HOME for "which hardware control drives what" (m28-knob).**
///
/// ## Why this exists
///
/// Hardware CC input was already fully plumbed before this type: the CoreMIDI
/// receive thread parses status `0xB` (`MIDIUMPParser`), the events cross to the
/// main actor on the capture ring, and live thru fans every CC out to armed
/// instrument tracks **while the transport is stopped**. So a knob sending CC 11
/// ALREADY rides an armed sax part's expression today with no code at all.
///
/// What was missing is only this: a knob's CC lands in a lane of that same CC
/// NUMBER, and there was no way to say "CC 74 → the pad's ring angle". This is
/// that layer, and nothing else.
///
/// ## ⛔ THE MAPPED CC IS NOT SWALLOWED
///
/// A CC bound here **still** reaches every armed instrument track through live
/// thru, and **still** lands in the take's controller lanes if you are
/// recording. Filtering it would mean reading this table on the CoreMIDI receive
/// thread, which needs an atomically published snapshot and is a render-path
/// change; that is not worth it to hide a controller the built-in sampler
/// already ignores (`MIDIControllerRouting.samplerRoutedCCs` is `[1, 2, 11,
/// 64]`, so CC 74 is inert there). ⚠️ On a HOSTED AU track it is not inert —
/// hosted AUs receive every controller raw, so a knob mapped to the pad may also
/// wiggle a plugin parameter. Pick a CC the plugin does not use, or map a knob
/// on a device you do not play through.
///
/// ## ⛔ NOT PROJECT STATE
///
/// This map is **machine setup, not project content**, so it is deliberately not
/// part of `ProjectDocument`: opening someone else's song must not re-point your
/// knobs, and moving a project between machines must not carry a mapping for a
/// controller that is not there. It is session-scoped — a mapping does not
/// survive a relaunch yet, and persisting it is an additive step that belongs
/// with the other machine preferences, not in the song.
///
/// Pure value type: no engine, no UI, no actor. Every rule below is asserted in
/// a free (non-`@MainActor`) suite.
///
/// ⭐ **Deliberately NOT `Codable`, while `MIDIControlBinding` is.** The "not
/// project state" paragraph above is a rule, and a rule that lives only in a
/// comment is one refactor from being broken by someone who sees a `Codable`
/// conformance and reasonably concludes the type was meant to be saved. The
/// BINDINGS are encodable — that is the part a future machine-preferences file
/// would write — but the live table, with its armed-learn state and its
/// last-seen event, is session state and cannot be round-tripped by accident.
public struct MIDIControlMap: Sendable, Equatable {

    /// What one ingested event did.
    public struct Ingestion: Sendable, Equatable {
        /// The binding LEARN just created, if this event completed a learn.
        public var learned: MIDIControlBinding?
        /// Every target this event moved. Empty is the common case — most CCs
        /// are not mapped to anything.
        public var updates: [MIDIControlUpdate]

        public init(learned: MIDIControlBinding? = nil, updates: [MIDIControlUpdate] = []) {
            self.learned = learned
            self.updates = updates
        }

        public static let none = Ingestion()
    }

    /// The bindings, at most one per target (see `bind`).
    public private(set) var bindings: [MIDIControlBinding] = []

    /// The target LEARN is armed for, or nil. The next controller change binds.
    public private(set) var learningTarget: MIDIControlTarget?

    /// The last controller change seen, mapped or not — **non-destructively**,
    /// so a panel can say "we are seeing CC 74 from Keystation" without stealing
    /// the event from the delivery pump, and so an armed learn that never fires
    /// can be told apart from a controller that is sending nothing at all. That
    /// distinction is the whole difference between "your knob is not mapped" and
    /// "your knob is not plugged in".
    public private(set) var lastEvent: MIDIControlChangeEvent?

    public init() {}

    public init(bindings: [MIDIControlBinding]) {
        for binding in bindings { bind(binding) }
    }

    // MARK: Editing

    /// Binds `binding`, REPLACING any existing binding for the same target.
    ///
    /// One control per target, because the alternative — two knobs fighting over
    /// the pad's angle — is a control that does something different depending on
    /// which hand moved last. A single controller MAY drive several targets
    /// (map CC 74 to both angle and radius and it sweeps a spiral); that is a
    /// macro, and it is deliberate rather than accidental.
    public mutating func bind(_ binding: MIDIControlBinding) {
        bindings.removeAll { $0.target == binding.target }
        bindings.append(binding)
        bindings.sort { $0.target.rawValue < $1.target.rawValue }
    }

    /// Removes the binding for `target`. Returns whether there was one.
    @discardableResult
    public mutating func unbind(target: MIDIControlTarget) -> Bool {
        let before = bindings.count
        bindings.removeAll { $0.target == target }
        if learningTarget == target { learningTarget = nil }
        return bindings.count != before
    }

    /// Forgets every binding and cancels any armed learn.
    public mutating func removeAll() {
        bindings.removeAll()
        learningTarget = nil
    }

    /// The binding driving `target`, if any.
    public func binding(for target: MIDIControlTarget) -> MIDIControlBinding? {
        bindings.first { $0.target == target }
    }

    // MARK: Learn

    /// Arms learn: the NEXT controller change binds to `target`.
    ///
    /// ⚠️ **The first event wins, whatever it is.** A control surface that
    /// spews an unrelated CC (a fader you are not touching, a device sending its
    /// state on connect) will win the race. That is how every MIDI-learn works,
    /// and the honest mitigation is the one this type provides: `lastEvent`
    /// names what was heard, and re-arming is one call.
    public mutating func armLearn(target: MIDIControlTarget) {
        learningTarget = target
    }

    /// Disarms learn, changing no bindings.
    public mutating func cancelLearn() {
        learningTarget = nil
    }

    public var isLearning: Bool { learningTarget != nil }

    // MARK: The resolve

    /// Feeds one controller change through the table.
    ///
    /// When learn is armed this BINDS and **also emits the update for the very
    /// same event** — deliberately. The alternative is a knob that binds and
    /// then visibly does nothing until you turn it again, which is
    /// indistinguishable from a learn that failed; this tree's characteristic
    /// defect is exactly that shape.
    @discardableResult
    public mutating func ingest(_ event: MIDIControlChangeEvent) -> Ingestion {
        lastEvent = event
        var learned: MIDIControlBinding?
        if let target = learningTarget {
            let binding = MIDIControlBinding(target: target, controller: event.controller,
                                             channel: nil, sourceID: event.sourceID)
            bind(binding)
            learningTarget = nil
            learned = binding
        }
        var updates: [MIDIControlUpdate] = []
        for binding in bindings where binding.matches(event) {
            updates.append(MIDIControlUpdate(target: binding.target,
                                             value: binding.value(for: event),
                                             controller: event.controller,
                                             sourceID: event.sourceID))
        }
        return Ingestion(learned: learned, updates: updates)
    }

    /// Feeds a whole pump pass. Returns every update in arrival order — the
    /// delivery site coalesces per target, because two values for one target in
    /// one 33 ms pass are a knob mid-turn, not two gestures.
    @discardableResult
    public mutating func ingest(_ events: [MIDIControlChangeEvent]) -> Ingestion {
        var learned: MIDIControlBinding?
        var updates: [MIDIControlUpdate] = []
        for event in events {
            let step = ingest(event)
            if let l = step.learned { learned = l }
            updates.append(contentsOf: step.updates)
        }
        return Ingestion(learned: learned, updates: updates)
    }
}
