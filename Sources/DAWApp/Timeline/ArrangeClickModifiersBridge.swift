import AppKit
import DAWAppKit

// The AppKit → headless bridge for arrange click chords (m23-g1). DAWAppKit
// stays headless (the `TransportKeyModifiers` law), so the NSEvent mapping lives
// app-side, in ONE place, and is a pure function of the flags it is handed.

extension ArrangeClickModifiers {
    /// Maps device-independent chord flags into the headless option set. Only
    /// shift and command are mapped, because only they change the selection
    /// intent — caps lock, fn, and the numeric-pad flag must never turn a plain
    /// click into a toggle (the `transportKeyModifiers` reasoning, one surface
    /// over). ⌥ and ⌃ are deliberately not mapped: ⌥-click already belongs to
    /// the fade-curve toggle, and neither is a selection chord.
    static func from(_ flags: NSEvent.ModifierFlags) -> ArrangeClickModifiers {
        let device = flags.intersection(.deviceIndependentFlagsMask)
        var mods: ArrangeClickModifiers = []
        if device.contains(.shift) { mods.insert(.shift) }
        if device.contains(.command) { mods.insert(.command) }
        return mods
    }

    /// The chord held RIGHT NOW.
    ///
    /// NOT PROVEN HEADLESSLY, and stated here rather than left to be discovered:
    /// SwiftUI's `TapGesture` hands its handler no event, so the modifiers must
    /// be read from the global state at the instant the tap ends — the same
    /// `NSEvent.modifierFlags` read `ClipBlock.startFlagsMonitor` already relies
    /// on for its ⌥ cue. That read is accurate while the user is still holding
    /// the key (which they are, at mouse-up), but no staging seam can prove it:
    /// a synthesized tap carries no real chord. The gate therefore drives
    /// `AppModel.clickClip(id:modifiers:)` with EXPLICIT modifiers — proving the
    /// decision and the selection, not this one line of plumbing.
    static var current: ArrangeClickModifiers { from(NSEvent.modifierFlags) }
}
