import Foundation
import Observation
import DAWCore

// MARK: - One target's row

/// Everything the panel draws for ONE mappable target (m28-knob-ui).
///
/// A pure value: built from the table, never from a device query. That is not a
/// style preference — see `BreathPadHardwareModel`'s header. Resolving a device
/// NAME the honest way would mean calling `availableMIDIInputs()`, and that call
/// **creates the CoreMIDI client and connects to every online source**. A row
/// that quietly did it would turn opening a panel into a real event on the
/// user's hardware.
///
/// So the row carries what it can prove and says so where it cannot: a device
/// seen during a learn is named, a device this session has never enumerated is
/// numbered, and "any device" is a THIRD state rather than a synonym for either.
public struct MIDIControlTargetRow: Sendable, Equatable, Identifiable {
    public var target: MIDIControlTarget
    public var id: String { target.rawValue }

    /// `MIDIControlTarget.displayName`, verbatim — composed, never restated.
    public var name: String { target.displayName }
    /// `MIDIControlTarget.summary`, verbatim.
    public var summary: String { target.summary }

    /// The binding driving this target, if any.
    public var binding: MIDIControlBinding?
    /// Whether LEARN is armed for this row right now.
    public var isLearning: Bool

    /// How the device half of the binding is known — the distinction the panel
    /// has to draw honestly.
    public enum DeviceIdentity: Sendable, Equatable {
        /// No binding at all.
        case unbound
        /// `sourceID == nil`: the binding accepts the CC from ANY device. Learn
        /// never produces this; an agent writing through `midi.setControlMap`
        /// can, and it is a deliberate wildcard, not a gap in our knowledge.
        case anyDevice
        /// A device this session has enumerated (learn returned it).
        case named(String)
        /// A `sourceID` we have never seen a name for — an agent bound it
        /// through the wire, or the endpoint went away. ⚠️ NOT resolvable
        /// without waking CoreMIDI, so it is reported as the number it is.
        case unknown(Int32)
    }

    public var device: DeviceIdentity

    public init(target: MIDIControlTarget, binding: MIDIControlBinding?,
                isLearning: Bool, device: DeviceIdentity) {
        self.target = target
        self.binding = binding
        self.isLearning = isLearning
        self.device = device
    }

    public var isBound: Bool { binding != nil }
    public var isInverted: Bool { binding?.inverted ?? false }

    /// `"CC 74"` — SF Mono in the view. Empty when nothing is bound.
    public var controllerLabel: String {
        guard let binding else { return "" }
        return "CC \(binding.controller)"
    }

    /// The device half, in the beginner's words.
    public var deviceLabel: String {
        switch device {
        case .unbound: return ""
        case .anyDevice: return "any device"
        case .named(let name): return name
        case .unknown(let id): return "device \(id)"
        }
    }

    /// The whole state of this row as one line — what the collapsed section
    /// shows, and what a screen reader reads.
    ///
    /// ⚠️ **"Learning" outranks "bound".** A row that is armed while already
    /// bound must not read as settled: the very next controller change REPLACES
    /// what it says, and a label that showed the old CC in that moment would be
    /// describing a mapping that is one knob-turn from gone.
    public var statusLine: String {
        if isLearning { return "Turn a knob…" }
        guard binding != nil else { return "Not mapped" }
        let inverted = isInverted ? " · flipped" : ""
        return "\(controllerLabel) · \(deviceLabel)\(inverted)"
    }
}

// MARK: - The whole section, as values

/// The hardware-mapping section's complete drawable state (m28-knob-ui).
///
/// Built by a pure initialiser from `(map, knownDevices, subscribed)` so every
/// sentence in the panel is asserted in a FREE (non-`@MainActor`) suite —
/// `MainActorOccupancySiteTests`' Leg C caps the tree's `@MainActor` suite count
/// at 330 and the tree is AT it, so a presentation layer must not buy a slot.
public struct MIDIControlPanelState: Sendable, Equatable {
    public var rows: [MIDIControlTargetRow]
    /// Whether the app is actually subscribed to the controller feed —
    /// `MIDIControlController.isSubscribed`, which describes REALITY (an engine
    /// is attached and the observer is installed) and not intent.
    public var isSubscribed: Bool
    /// The last controller change heard, mapped or not.
    public var lastEvent: MIDIControlChangeEvent?
    /// The name of the device `lastEvent` came from, when this session has seen
    /// it. nil is not an error — see `MIDIControlTargetRow.DeviceIdentity`.
    public var lastEventDeviceName: String?

    public init(map: MIDIControlMap, knownDevices: [MIDIInputDevice], isSubscribed: Bool) {
        func identity(_ binding: MIDIControlBinding?) -> MIDIControlTargetRow.DeviceIdentity {
            guard let binding else { return .unbound }
            guard let sourceID = binding.sourceID else { return .anyDevice }
            if let device = knownDevices.first(where: { $0.uniqueID == sourceID }) {
                return .named(device.name)
            }
            return .unknown(sourceID)
        }
        self.rows = MIDIControlTarget.allCases.map { target in
            MIDIControlTargetRow(target: target,
                                 binding: map.binding(for: target),
                                 isLearning: map.learningTarget == target,
                                 device: identity(map.binding(for: target)))
        }
        self.isSubscribed = isSubscribed
        self.lastEvent = map.lastEvent
        self.lastEventDeviceName = map.lastEvent.flatMap { event in
            knownDevices.first { $0.uniqueID == event.sourceID }?.name
        }
    }

    public var boundCount: Int { rows.filter(\.isBound).count }
    public var isLearning: Bool { rows.contains(where: \.isLearning) }

    /// The collapsed header's one line — **the diagnostic, not a teaser.**
    ///
    /// ⭐ The brief's actual requirement is that *a dead knob is diagnosable
    /// without leaving the panel*, so the state that answers "is my knob doing
    /// anything?" lives in the row you can see WITHOUT expanding: how many
    /// targets are mapped, and whether we are listening at all.
    public var summaryLine: String {
        if isLearning { return "Waiting for a knob…" }
        switch boundCount {
        case 0: return "No knobs mapped"
        case 1: return "1 knob mapped\(isSubscribed ? " · listening" : "")"
        default: return "\(boundCount) knobs mapped\(isSubscribed ? " · listening" : "")"
        }
    }

    /// Whether the app is listening, in the beginner's words. **This is the
    /// state that separates "your knob is not mapped" from "we are not even
    /// looking".**
    public var feedLine: String {
        if isSubscribed {
            return "Listening to your MIDI controllers."
        }
        if boundCount > 0 {
            return "Not listening — no audio engine is running, so nothing can reach the pad yet."
        }
        return "Not listening yet. Nothing is mapped, so DAW Pro leaves your MIDI gear alone until you press LEARN."
    }

    /// `"CC 74 = 96 · ch 1 · Keystation 49"` — the last controller change that
    /// arrived, mapped or not.
    ///
    /// ⭐⭐ **THE ONE READOUT THAT MAKES A DEAD KNOB DIAGNOSABLE.** "Nothing
    /// happens when I turn it" has two completely different causes — the knob is
    /// sending a CC we are not mapped to, or the knob is sending nothing at all
    /// — and they are indistinguishable from every other part of this panel.
    /// `MIDIControlMap.lastEvent` is read non-destructively, so surfacing it here
    /// never steals an event from the delivery pump.
    public var lastHeardLine: String {
        guard let event = lastEvent else {
            return isSubscribed
                ? "Nothing heard yet — turn a knob."
                : "Nothing heard yet."
        }
        let device = lastEventDeviceName ?? "device \(event.sourceID)"
        return "CC \(event.controller) = \(event.value) · ch \(event.channel + 1) · \(device)"
    }

    /// ⛔ The rule `MIDIControlMap`'s own header states, said to the user rather
    /// than only to the next programmer: the table is machine setup, not song
    /// content. A mapping that silently vanished on relaunch with no warning
    /// would read as a bug; said out loud it reads as a limit.
    public static let persistenceNote =
        "Knob mappings belong to this desk, not to the song — they are not saved into the "
        + "project, and they are forgotten when DAW Pro quits."
}

// MARK: - The panel's live model

/// The breath pad's hardware-mapping section, as a model the view binds to
/// (m28-knob-ui).
///
/// ## ⛔⛔ THE ONE HARD RULE: THIS OBJECT NEVER WAKES CoreMIDI
///
/// Two calls on `ProjectStore` bring the MIDI client up, and **both** of them
/// connect to every online source on the user's desk:
///
/// - `armMIDIControlLearn(target:)` → `refreshSubscription` → the engine's
///   `setControlChangeObserver`, **and** `availableMIDIInputs()` for its return;
/// - anything that enumerates inputs at all (`listMIDIInputs`).
///
/// So this model is built from **values and closures only**. It holds no
/// `ProjectStore`, and the section view holds no store either — which is what
/// makes "opening the panel is quiet" a structural fact rather than a promise.
/// `refresh(map:isSubscribed:)` takes the table it is told about; it cannot go
/// and get one. The only path to `arm` is the LEARN button's closure.
///
/// Device NAMES are cached from what `arm` returned, and from nowhere else: a
/// learn is a moment when the user has already asked for the client to come up,
/// so enumerating there costs nothing new. Bindings created by an agent through
/// `midi.setControlMap` therefore show a NUMBER, and that is the honest answer
/// rather than a name we would have had to wake the hardware to obtain.
///
/// ## Why a mirror at all
///
/// `MIDIControlController` is a plain final class, NOT `@Observable`, so a view
/// reading `store.midiControlMap` would never be invalidated when a hardware
/// turn completes a learn — the mapping section would sit there showing "Turn a
/// knob…" forever while the binding it was waiting for already existed. The app
/// pushes the table in on every pump pass instead.
///
/// ⚠️ **The push is equality-guarded, and that guard is load-bearing.** The pump
/// runs at ~30 Hz *including empty passes* (that empty pass is the idle tick the
/// pad releases on). An unguarded write to an `@Observable` property would
/// invalidate the whole card 30 times a second for as long as any binding
/// exists, redrawing a dial the file header deliberately keeps idle between
/// gestures.
@MainActor
@Observable
public final class BreathPadHardwareModel {

    /// Arms learn for a target and returns the inputs the engine can see.
    /// Wired to `ProjectStore.armMIDIControlLearn`. **The only thing in this
    /// file that may wake CoreMIDI, and it runs from a button.**
    public typealias ArmLearn = (MIDIControlTarget) -> [MIDIInputDevice]
    /// Wired to `ProjectStore.cancelMIDIControlLearn`.
    public typealias CancelLearn = () -> Void
    /// Wired to `ProjectStore.setMIDIControlBindings` — a whole-table set.
    public typealias SetBindings = ([MIDIControlBinding]) -> Void
    /// Reads back `(map, isSubscribed)` after a mutation, so the panel reflects
    /// what the store actually holds rather than what it asked for.
    public typealias ReadBack = () -> (map: MIDIControlMap, isSubscribed: Bool)

    private let armClosure: ArmLearn
    private let cancelClosure: CancelLearn
    private let setBindingsClosure: SetBindings
    private let readBack: ReadBack

    public init(arm: @escaping ArmLearn,
                cancel: @escaping CancelLearn,
                setBindings: @escaping SetBindings,
                readBack: @escaping ReadBack) {
        self.armClosure = arm
        self.cancelClosure = cancel
        self.setBindingsClosure = setBindings
        self.readBack = readBack
    }

    /// The table as last pushed in. **Starts EMPTY and is never fetched on
    /// construction** — a model that pulled its own initial state would be one
    /// refactor away from pulling the device list too.
    public private(set) var map = MIDIControlMap()
    /// Whether the store says the feed is live.
    public private(set) var isSubscribed = false
    /// Devices seen during a learn. Grows; never queried.
    public private(set) var knownDevices: [MIDIInputDevice] = []

    /// Whether the section is expanded. Collapsed by DEFAULT, and the reason is
    /// arithmetic rather than taste: the pad's card already scrolls below a
    /// ~689 pt window, and an always-expanded editor would push that to ~860 —
    /// i.e. the card would scroll at almost every real window size. The row that
    /// stays visible carries the diagnostic (`summaryLine`), so what is behind
    /// the disclosure is the EDITOR, never the state.
    ///
    /// ⭐ **THE ONE HOME, deliberately not mirrored onto `BreathPadModel`.** The
    /// height budget needs this flag, and the obvious move was to keep a copy
    /// where `BreathPadLayout` is — which would be two properties for one fact,
    /// and the pad's own history says a layout input that can drift is exactly
    /// how a card ends up drawing something its budget cannot see. The view
    /// holds both models and passes this ONE value into
    /// `BreathPadLayout.regions(…)`; `debug.breathPad` reads the same property.
    public var isExpanded = false

    /// The drawable state. Recomputed on demand from the three stored values —
    /// cheap (two targets), pure, and impossible to get stale.
    public var state: MIDIControlPanelState {
        MIDIControlPanelState(map: map, knownDevices: knownDevices,
                              isSubscribed: isSubscribed)
    }

    // MARK: The push

    /// The app hands the table in. **Equality-guarded**: at ~30 Hz an
    /// unconditional write would invalidate the whole card forever.
    ///
    /// Returns whether anything changed, so a caller can tell a real update from
    /// the idle case without comparing again.
    @discardableResult
    public func refresh(map newMap: MIDIControlMap, isSubscribed newSubscribed: Bool) -> Bool {
        guard newMap != map || newSubscribed != isSubscribed else { return false }
        map = newMap
        isSubscribed = newSubscribed
        return true
    }

    // MARK: The actions

    /// LEARN. **This is the call that brings the CoreMIDI client up, and it runs
    /// only from the user's press** — never from `onAppear`, never from a
    /// preview, never from a refresh.
    ///
    /// Re-arming an already-armed row CANCELS instead, so the button is its own
    /// escape: a learn armed by accident must not need a second control to get
    /// out of, and there is no release to abandon it with.
    public func toggleLearn(_ target: MIDIControlTarget) {
        if map.learningTarget == target {
            cancelClosure()
        } else {
            let devices = armClosure(target)
            mergeDevices(devices)
        }
        sync()
    }

    /// Cancels an armed learn, whatever it was armed for.
    public func cancelLearn() {
        guard map.isLearning else { return }
        cancelClosure()
        sync()
    }

    /// Flips a bound control's direction — for a knob wired backwards or mounted
    /// upside down. A no-op when nothing is bound.
    public func toggleInverted(_ target: MIDIControlTarget) {
        guard var binding = map.binding(for: target) else { return }
        binding.inverted.toggle()
        var next = map.bindings.filter { $0.target != target }
        next.append(binding)
        write(next)
    }

    /// Forgets one mapping. A no-op when nothing is bound, so a stray press on
    /// an unbound row cannot spend a store write (and, with it, a subscription
    /// teardown/rebuild).
    public func unbind(_ target: MIDIControlTarget) {
        guard map.binding(for: target) != nil else { return }
        write(map.bindings.filter { $0.target != target })
    }

    /// Forgets every mapping. A no-op when the table is already empty.
    ///
    /// ⛔ This tears the subscription down (`refreshSubscription` sees nothing
    /// wanted), which is deliberate: clearing the table is the user saying "stop
    /// listening to my gear", and leaving the client connected afterwards would
    /// be exactly the silent side effect this whole design avoids.
    public func clearAll() {
        guard !map.bindings.isEmpty else { return }
        write([])
    }

    // MARK: Plumbing

    private func write(_ bindings: [MIDIControlBinding]) {
        setBindingsClosure(bindings)
        sync()
    }

    /// Reads the store's own table back.
    ///
    /// After a mutation this is **not a query for new information** — it is the
    /// same table we just wrote, read back so the panel shows what the store
    /// HOLDS rather than what it was handed. "The setter returned, so it took"
    /// is this tree's signature mistake.
    ///
    /// It is also what the app calls when the panel OPENS, because an agent may
    /// have written the table through `midi.setControlMap` while the panel was
    /// closed and a section that showed "No knobs mapped" over a live mapping
    /// would be lying.
    ///
    /// ⛔ **QUIET BY CONSTRUCTION.** `readBack` reads two stored properties —
    /// `ProjectStore.midiControlMap` and `MIDIControlController.isSubscribed` —
    /// and touches no engine. It is emphatically NOT a device enumeration:
    /// `availableMIDIInputs()` would create the CoreMIDI client, which is the
    /// one thing opening a panel must never do.
    public func sync() {
        let result = readBack()
        _ = refresh(map: result.map, isSubscribed: result.isSubscribed)
    }

    private func mergeDevices(_ devices: [MIDIInputDevice]) {
        guard !devices.isEmpty else { return }
        var merged = knownDevices
        for device in devices {
            if let index = merged.firstIndex(where: { $0.uniqueID == device.uniqueID }) {
                merged[index] = device
            } else {
                merged.append(device)
            }
        }
        knownDevices = merged
    }
}
