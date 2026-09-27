import Foundation

/// TB-F1 (W7, 2026-09-27) — the words the COMPACT loop deck moves off the screen,
/// so they survive in its tooltip and its accessibility value.
///
/// The full `LoopDeckStrip` prints the loop's length beside its sweep ("LOOP /
/// 4 BAR") and each lamp's track name under it. The compact deck (the narrow-window
/// form `TransportBarFit` chooses) has room for neither, and the rule is that a
/// collapsed control keeps its words in a tooltip AND its accessibility label.
/// Headless so the sentences are pinned without a window.
///
/// ⚠️ The length arithmetic MIRRORS `LoopDeckStrip.lengthLabel` (whole bars within
/// 0.01, else two decimals; no length before press-to-end decides it). That label
/// is private to a file this lane does not own — a follow-up for its owner is to
/// read this one instead, so the two cannot drift.
public enum TransportDeckCopy {

    /// "4 bars", "1 bar", "2.50 bars" — or nil while a press-to-end loop has no
    /// length yet (the strip's em dash).
    public static func lengthPhrase(cycleBeats: Double?, beatsPerBar: Double) -> String? {
        guard let cycleBeats, beatsPerBar > 0 else { return nil }
        let bars = cycleBeats / beatsPerBar
        let whole = Int(bars.rounded())
        if abs(bars - Double(whole)) < 0.01 {
            return whole == 1 ? "1 bar" : "\(whole) bars"
        }
        return String(format: "%.2f bars", bars)
    }

    /// The compact deck's tooltip: what the lights are, and the loop's length.
    public static func compactDeckHelp(cycleBeats: Double?, beatsPerBar: Double) -> String {
        let length = lengthPhrase(cycleBeats: cycleBeats, beatsPerBar: beatsPerBar)
            .map { "The loop is \($0) long." }
            ?? "The loop's length is set when you finish the first layer."
        return "Looper. \(length) Each light is a layer: click one to mute it or bring it back."
    }

    /// The compact deck's accessibility value: the length, then the same state
    /// phrase the full strip speaks.
    public static func compactDeckAccessibilityValue(cycleBeats: Double?, beatsPerBar: Double,
                                                     layerCount: Int, pendingPhrase: String?) -> String {
        let length = lengthPhrase(cycleBeats: cycleBeats, beatsPerBar: beatsPerBar)
            .map { "loop of \($0)" } ?? "loop length not set yet"
        return "\(length), \(pendingPhrase ?? "\(layerCount) layers")"
    }
}
