import Foundation

// Space-bar transport toggle (m17-d, user request #6): the headless decision
// funnel behind the app's key-down monitor. ONE pure predicate answers "does
// this key press drive the transport, or does it belong to whatever has
// focus?" so the focus guard — the hard requirement (a space typed into a
// rename field must insert a space, never touch the transport) — is unit-
// testable without AppKit (the `ArrangePointerModel` precedent). The view
// layer (AppModel's NSEvent local monitor) maps the live event/responder/
// window facts into these value types and obeys the verdict; it adds no
// policy of its own.

/// What a key press should do, per the predicate. Raw values are stable
/// strings so the `debug.keySpace` seam can echo the decision verbatim.
public enum TransportKeyDecision: String, Equatable, Sendable {
    /// Drive the transport toggle (and swallow the event — it never reaches
    /// the responder chain, so nothing beeps or types).
    case toggleTransport
    /// Not ours: hand the event back untouched so focused text fields, menu
    /// key equivalents, and every other responder see exactly what they would
    /// have seen without the monitor.
    case passThrough
}

/// Device-independent modifier keys, mirrored from `NSEvent.ModifierFlags`
/// WITHOUT importing AppKit (DAWAppKit stays headless). The app maps only the
/// four chord modifiers — caps lock / fn / numeric-pad flags deliberately do
/// NOT block the toggle (caps lock being on must not kill the space bar).
public struct TransportKeyModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = TransportKeyModifiers(rawValue: 1 << 0)
    public static let option = TransportKeyModifiers(rawValue: 1 << 1)
    public static let control = TransportKeyModifiers(rawValue: 1 << 2)
    public static let shift = TransportKeyModifiers(rawValue: 1 << 3)
}

/// What kind of responder currently owns keyboard focus. The app classifies
/// the key window's `firstResponder`; the predicate only needs the verdict.
public enum TransportKeyResponder: String, Equatable, Sendable {
    /// No text editing is active — the space bar is free to drive the transport.
    case none
    /// A text-input surface is first responder (the shared field editor behind
    /// every rename `TextField`, an `NSTextView`, the Copilot rail input, any
    /// `NSTextInputClient`) — space belongs to the text, unconditionally.
    case textEditing = "text-editing"
}

/// Which window the key event targets. The toggle is MAIN-WINDOW-ONLY (the
/// documented safe default): floating plugin windows and any future secondary
/// panels keep their own key handling — a space typed into an AU's search box
/// must never start playback behind it.
public enum TransportKeyWindow: String, Equatable, Sendable {
    /// The content window (the one WindowGroup window hosting ContentView).
    case main
    /// Anything else: a floating plugin window, a panel, or no window at all
    /// (a synthesized event with an unresolvable window number).
    case secondary
}

/// Which transport funnel a granted toggle should drive. The play/pause
/// button's exact ternary (`isPlaying ? stop() : play()`) lifted into a pure,
/// testable value: recording sets `isPlaying` true (`ProjectStore.record()`),
/// so a mid-record space resolves to `.stop` — byte-identical semantics to
/// both the play/pause button's stop branch and the record button's.
public enum TransportToggleIntent: String, Equatable, Sendable {
    case play
    case stop
}

/// The pure decisions behind the m17-d space-bar toggle.
public enum TransportKeyRouting {
    /// The space bar's virtual key code (kVK_Space — layout-independent, the
    /// same constant on every keyboard layout).
    public static let spaceKeyCode: UInt16 = 49

    /// The decision funnel: space toggles the transport ONLY when it is a
    /// fresh, chord-free press aimed at the main window while nothing is
    /// editing text. Every other combination — any other key, a key-repeat,
    /// any command/option/control/shift chord (⌘Space is Spotlight's;
    /// ⇧/⌥/⌃-space stay free for future bindings and system input methods),
    /// an active text field, a secondary window — passes through untouched.
    public static func decide(
        keyCode: UInt16,
        modifiers: TransportKeyModifiers,
        isRepeat: Bool,
        responder: TransportKeyResponder,
        window: TransportKeyWindow
    ) -> TransportKeyDecision {
        guard keyCode == spaceKeyCode else { return .passThrough }
        guard modifiers.isEmpty else { return .passThrough }
        guard !isRepeat else { return .passThrough }
        guard responder == .none else { return .passThrough }
        guard window == .main else { return .passThrough }
        return .toggleTransport
    }

    /// Maps the live transport state to the funnel a granted toggle drives —
    /// the play/pause button's exact ternary. `isPlaying` is true while
    /// recording too, so `.stop` covers the record-stop case with the SAME
    /// `ProjectStore.stop()` the transport buttons call.
    public static func toggleIntent(isPlaying: Bool) -> TransportToggleIntent {
        isPlaying ? .stop : .play
    }
}
