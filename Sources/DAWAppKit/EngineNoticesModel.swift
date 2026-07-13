import Foundation
import DAWCore

/// Headless presentation logic for the transport-bar ENGINE-NOTICES chip and
/// its popover (m15-e, audit F6). `ProjectStore` owns the coalesced
/// `[EngineNotice]` ring — the single source of truth the wire snapshot and the
/// UI both read; this value type turns that array into the chip's visibility +
/// badge math and the popover's ordered rows, so the view stays thin and the
/// logic is pinned WITHOUT a window (the `UndoHistoryModel` / `QuantizeModel`
/// precedent: all logic here, testable without SwiftUI OR a store).
///
/// NO VIOLET — engine notices are diagnostic STATUS chrome, not AI-generated
/// content (docs/DESIGN-LANGUAGE.md Rule 3: violet is AI identity only). The
/// only color it earns is semantic AMBER (`DAWTheme.record`, the accent system's
/// warning/clipping-adjacent hue); everything else is dark glass.
public struct EngineNoticesModel: Equatable, Sendable {
    public let notices: [EngineNotice]

    public init(notices: [EngineNotice]) {
        self.notices = notices
    }

    /// The chip shows ONLY when the ring is non-empty. A healthy session (the
    /// overwhelming common case) shows nothing at all, so the transport bar
    /// stays calm — the warning appears exactly when something degraded.
    public var isPresent: Bool { !notices.isEmpty }

    /// The chip's compact badge count.
    ///
    /// DECISION (load-bearing, documented): the badge counts DISTINCT problems
    /// = the number of COALESCED entries (`notices.count`), NOT the sum of each
    /// entry's `count`. A fade that fails once per loop wrap posts its code
    /// dozens of times; Σcount would flash "47" and read as 47 separate things
    /// wrong — alarming and dishonest, when it is really ONE problem that
    /// recurred. Entry-count understates repeats, but that fidelity is restored
    /// HONESTLY the instant the user opens the popover: each row carries a "×N"
    /// repeat badge (`repeatBadge`). So the split is: chip badge = "how many
    /// DISTINCT kinds of degradation happened", row badge = "how many times
    /// THIS one recurred".
    public var badgeCount: Int { notices.count }

    /// Popover rows, MOST-RECENT degradation first (largest `lastAt`), ties
    /// broken by `code` for a fully deterministic order. `lastAt` is the store's
    /// monotonic sequence token (never wall-clock), so this order is stable and
    /// reproducible — a diagnostic surface wants the freshest problem on top.
    public var rows: [EngineNotice] {
        notices.sorted { a, b in
            if a.lastAt != b.lastAt { return a.lastAt > b.lastAt }
            return a.code < b.code
        }
    }

    /// The per-row repeat badge: "×N" only when a code coalesced more than once;
    /// nil for a single occurrence (no badge clutter on the common case).
    public static func repeatBadge(for notice: EngineNotice) -> String? {
        notice.count > 1 ? "×\(notice.count)" : nil
    }

    /// Optional beat context for a row — a SF Mono numeric readout ("beat 8",
    /// design-language: every number is mono). Whole beats print without a
    /// decimal; fractional beats keep one place. nil when the site knew no beat.
    public static func beatLabel(for notice: EngineNotice) -> String? {
        guard let beat = notice.beat else { return nil }
        if beat == beat.rounded() {
            return "beat \(Int(beat))"
        }
        return "beat \(String(format: "%.1f", beat))"
    }

    /// The chip's hover tooltip: an honest one-liner naming the distinct count.
    public var chipHelp: String {
        badgeCount == 1
            ? "1 playback notice this session — click for details"
            : "\(badgeCount) playback notices this session — click for details"
    }
}
