import CoreGraphics
import Foundation

/// Pure bookkeeping for the plugin-window layer (M3 vi-b): open/focus/close
/// transitions, per-key `ObjectIdentifier` instance stamps, deterministic
/// cascade-frame math, and open-ordered snapshots. It lives in DAWAppKit (not
/// DAWApp) so ALL the decision-shaped window logic is testable headless — the
/// AppKit `PluginPanelController`/`PluginWindowManager` slab stays thin and
/// defensive around it. No AppKit import; all geometry is CoreGraphics
/// (top-left-origin screen points throughout — the agent-friendly convention
/// the wire uses).
public struct PluginWindowLedger {
    /// Uniquely identifies one plugin window. Instrument windows key by the
    /// track; effect windows key by the (globally unique) effect id — the exact
    /// shape of DAWEngine's `HostedAUEndpoint`, so the manager maps the release
    /// callback onto a ledger key without loss.
    public enum Key: Hashable, Sendable {
        case instrument(trackID: UUID)
        case effect(effectID: UUID)
    }

    /// One tracked window: its instance stamp, current frame, and the open
    /// sequence that fixes list ordering.
    public struct Record: Sendable {
        public var key: Key
        /// Identity of the live `AUAudioUnit` the window bound to — an opaque
        /// stamp (the manager passes `ObjectIdentifier(au)`); the ledger only
        /// compares it, never dereferences it.
        public var stamp: ObjectIdentifier
        /// Top-left-origin screen-point frame (what the wire returns).
        public var frame: CGRect
        /// Monotonic open order — stable across focus, preserved across a
        /// same-key replace.
        public var sequence: Int

        public init(key: Key, stamp: ObjectIdentifier, frame: CGRect, sequence: Int) {
            self.key = key
            self.stamp = stamp
            self.frame = frame
            self.sequence = sequence
        }
    }

    /// Cascade geometry (design §4.2): the nth simultaneously-open window sits
    /// 140/120 pt in from the visible top-left, stepping 28 pt down-right, wrapping
    /// every 10.
    public static let cascadeInsetX: CGFloat = 140
    public static let cascadeInsetY: CGFloat = 120
    public static let cascadeStep: CGFloat = 28
    public static let cascadeWrap = 10

    private var records: [Key: Record] = [:]
    private var nextSequence = 0

    public init() {}

    public var count: Int { records.count }
    public func contains(_ key: Key) -> Bool { records[key] != nil }
    public func stamp(for key: Key) -> ObjectIdentifier? { records[key]?.stamp }
    public func frame(for key: Key) -> CGRect? { records[key]?.frame }

    /// The deterministic top-left origin for the NEXT window, given the visible
    /// area (top-left-origin) and how many windows are already open. `n` is the
    /// current open count mod 10 — the caller opens right after, so the count is
    /// the pre-open one.
    public func cascadeOrigin(visibleTopLeft: CGRect) -> CGPoint {
        let n = CGFloat(records.count % Self.cascadeWrap)
        return CGPoint(
            x: visibleTopLeft.minX + Self.cascadeInsetX + Self.cascadeStep * n,
            y: visibleTopLeft.minY + Self.cascadeInsetY + Self.cascadeStep * n)
    }

    /// Registers (or replaces) the window for `key`; returns its sequence. A
    /// replace keeps the original sequence so ordering never churns on a
    /// stamp/frame refresh.
    @discardableResult
    public mutating func open(_ key: Key, stamp: ObjectIdentifier, frame: CGRect) -> Int {
        let sequence: Int
        if let existing = records[key] {
            sequence = existing.sequence
        } else {
            sequence = nextSequence
            nextSequence += 1
        }
        records[key] = Record(key: key, stamp: stamp, frame: frame, sequence: sequence)
        return sequence
    }

    /// True when the key has no window, OR the live instance's stamp differs
    /// from the recorded one (the instance was swapped underneath — the reopen
    /// belt-and-braces check), OR there is no live instance at all (`nil`).
    public func isStale(_ key: Key, liveStamp: ObjectIdentifier?) -> Bool {
        guard let record = records[key] else { return true }
        guard let liveStamp else { return true }
        return record.stamp != liveStamp
    }

    /// Unregisters the window for `key`; returns whether one was present (the
    /// `closed:` bool the wire reports).
    @discardableResult
    public mutating func close(_ key: Key) -> Bool {
        records.removeValue(forKey: key) != nil
    }

    /// Every tracked window, sorted by open sequence — the deterministic
    /// ordering `plugin.listOpenUIs` returns.
    public var orderedRecords: [Record] {
        records.values.sorted { $0.sequence < $1.sequence }
    }

    /// The keys of `orderedRecords`, in the same open order.
    public var orderedKeys: [Key] { orderedRecords.map(\.key) }
}
