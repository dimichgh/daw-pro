import Foundation

/// A groove template (M5 iii-g, spec §6): a small per-slot TIMING-OFFSET table
/// that replaces the straight/swing grid targets in both quantize paths. A
/// groove is extracted from onsets (MIDI note onsets OR the iii-e transient map,
/// both fed as beat positions to the same pure function), stored project-level
/// as a palette, and applied BY VALUE at quantize time (`QuantizeSettings.groove`
/// / `AudioQuantizeSettings.groove` carry the resolved template, so deleting a
/// template never dangles a reference).
///
/// v0 cut: timing offsets only — no velocity/accent maps (additive later). The
/// built-in MPC-style swing presets are computed on demand and never persisted.
///
/// Pure and headless: no engine, no store, no I/O — beats in, offsets out. The
/// offset table is defined on `gridBeats` slots that fold into a `cycleBeats`
/// pattern; slot `i`'s target is `i·gridBeats + offsets[i mod count]`, where
/// `count == round(cycleBeats/gridBeats)`.
public struct GrooveTemplate: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    /// Display name — a user-authored string for an extracted groove, or the
    /// reserved built-in name (e.g. `"swing8:66"`) for a preset.
    public var name: String
    /// Slot size the offsets are defined on, in beats (`> 0`; the init clamps a
    /// non-positive value to a tiny floor so `count`/lookups never divide by 0).
    public var gridBeats: Double
    /// Pattern length the slots fold into, in beats (e.g. 4 = one bar at x/4).
    public var cycleBeats: Double
    /// Per-slot deviation from the straight grid, in beats. `count ==
    /// round(cycleBeats/gridBeats)`; each entry is clamped to
    /// `-gridBeats/2 ... gridBeats/2` (the closed half-grid bound — swing 75
    /// reaches exactly `gridBeats/2`). Slot `i` target = `i·gridBeats +
    /// offsets[i mod count]`.
    public var offsets: [Double]

    /// The number of distinct slots in the fold (`round(cycle/grid)`, floored at
    /// 1). The stored `offsets` array is normalized to exactly this length by the
    /// init, so a lookup never runs off the end.
    public var slotCount: Int { max(1, offsets.count) }

    /// Builds a groove, normalizing `offsets` to the fold length and clamping
    /// each entry to the half-grid bound. A non-positive `gridBeats` is floored;
    /// `cycleBeats` defaults to `gridBeats` when non-positive (a one-slot cycle).
    /// Extra offsets are dropped and missing ones padded with 0 so the stored
    /// count always equals `round(cycle/grid)` (the model invariant).
    public init(id: UUID = UUID(), name: String, gridBeats: Double,
                cycleBeats: Double, offsets: [Double]) {
        self.id = id
        self.name = name
        let grid = gridBeats > 0 ? gridBeats : 0.0001
        self.gridBeats = grid
        let cycle = cycleBeats > 0 ? cycleBeats : grid
        self.cycleBeats = cycle
        let count = max(1, Int((cycle / grid).rounded()))
        let bound = grid / 2
        var normalized = [Double](repeating: 0, count: count)
        for i in 0..<min(count, offsets.count) {
            normalized[i] = offsets[i].clamped(to: -bound...bound)
        }
        self.offsets = normalized
    }

    /// The per-slot offset applied by `QuantizeTarget.slotOffset` when this
    /// groove is set. `slot` is the target evaluator's straight-grid slot index
    /// (`round(beat/gridBeats)`); it folds into the groove cycle by `slot mod
    /// count` (a proper modulo, so a negative slot still lands in range). This is
    /// the whole groove branch — the returned value REPLACES the swing delay.
    public func offset(forSlot slot: Int) -> Double {
        let count = slotCount
        let folded = ((slot % count) + count) % count
        return offsets[folded]
    }

    // MARK: - Extraction

    /// Extracts a groove from onset positions in BEATS (spec §6). Each onset
    /// snaps to its NEAREST straight-grid slot; the onset's deviation from that
    /// slot is folded into the cycle (`slot mod count`) and AVERAGED per folded
    /// slot; slots with no onsets get 0. Works identically for MIDI note onsets
    /// (already in beats) and audio transients mapped to beats — one function.
    /// Pure and deterministic.
    public static func extract(fromOnsetBeats onsets: [Double], gridBeats: Double,
                               cycleBeats: Double, name: String) -> GrooveTemplate {
        let grid = gridBeats > 0 ? gridBeats : 0.0001
        let cycle = cycleBeats > 0 ? cycleBeats : grid
        let count = max(1, Int((cycle / grid).rounded()))
        var sums = [Double](repeating: 0, count: count)
        var hits = [Int](repeating: 0, count: count)
        for onset in onsets {
            let slot = Int((onset / grid).rounded())
            let folded = ((slot % count) + count) % count
            let deviation = onset - Double(slot) * grid
            sums[folded] += deviation
            hits[folded] += 1
        }
        let offsets = (0..<count).map { hits[$0] > 0 ? sums[$0] / Double(hits[$0]) : 0 }
        return GrooveTemplate(name: name, gridBeats: grid, cycleBeats: cycle, offsets: offsets)
    }

    // MARK: - Built-ins (MPC swing presets)

    /// The 8 canonical built-in swing grooves (54|58|62|66 × 8th|16th), by
    /// reserved name. These are the presets `groove.list` advertises; the full
    /// `"swing8:54"`…`"swing8:75"` / `"swing16:54"`…`"swing16:75"` range resolves
    /// on demand via `builtin(named:)`.
    public static let builtinNames: [String] = [
        "swing8:54", "swing8:58", "swing8:62", "swing8:66",
        "swing16:54", "swing16:58", "swing16:62", "swing16:66",
    ]

    /// Resolves a reserved built-in name to a computed groove (never persisted).
    /// `"swing8:P"` → grid 0.5 (1/8), `"swing16:P"` → grid 0.25 (1/16), with
    /// `cycle = 2·grid` (a 2-slot pair) and `offsets = [0, (2P/100 − 1)·grid]`
    /// (the even/downbeat slot stays, the odd/offbeat slot delays by the MPC
    /// swing amount). `P` is 54…75 (below 54 or above 75, or any other prefix,
    /// returns nil). Returns nil for an unrecognized name.
    public static func builtin(named raw: String) -> GrooveTemplate? {
        let grid: Double
        let body: Substring
        if raw.hasPrefix("swing8:") {
            grid = 0.5
            body = raw.dropFirst("swing8:".count)
        } else if raw.hasPrefix("swing16:") {
            grid = 0.25
            body = raw.dropFirst("swing16:".count)
        } else {
            return nil
        }
        guard let percent = Int(body), (54...75).contains(percent) else { return nil }
        let cycle = 2 * grid
        let offbeat = (2 * Double(percent) / 100 - 1) * grid
        return GrooveTemplate(id: builtinID(raw), name: raw, gridBeats: grid,
                              cycleBeats: cycle, offsets: [0, offbeat])
    }

    /// Deterministic, collision-free UUID for a built-in name so the same preset
    /// carries a stable id across calls and processes — built-ins aren't
    /// persisted, but a stable id keeps `groove.list` output consistent and lets
    /// clients cache by id if they choose.
    ///
    /// Two INDEPENDENT 64-bit FNV-1a passes over distinctly-salted strings fill
    /// the high (bytes 0–7) and low (bytes 8–15) halves, giving a full 128-bit
    /// value that's a pure function of the name — no RNG, no `Foundation.UUID()`.
    /// This replaces the original single-pass byte fold (`bytes[i % 16] ^= …`),
    /// which collapsed the ENTIRE `swing8:54…75` family onto one id (the last two
    /// digit bytes landed in the same two fold slots for every percentage), so
    /// `groove.list` served duplicate built-in ids. Version/variant bits are set
    /// to RFC-4122 v4 so the string is a well-formed UUID (cosmetic — the value is
    /// derived, not random).
    private static func builtinID(_ name: String) -> UUID {
        func fnv1a(_ string: String) -> UInt64 {
            var hash: UInt64 = 0xcbf29ce484222325
            for byte in string.utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x100000001b3
            }
            return hash
        }
        let hi = fnv1a("groove.builtin.hi:\(name)")
        let lo = fnv1a("groove.builtin.lo:\(name)")
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            bytes[i]     = UInt8(truncatingIfNeeded: hi >> UInt64(56 - i * 8))
            bytes[8 + i] = UInt8(truncatingIfNeeded: lo >> UInt64(56 - i * 8))
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40   // RFC-4122 version 4
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC-4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
