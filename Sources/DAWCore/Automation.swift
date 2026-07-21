import Foundation

/// The interpolation of the segment LEAVING a point toward the next one.
/// `linear` ramps; `hold` keeps the value flat until the next point steps it.
/// Persisted as its raw string; new shapes (e.g. bezier) are additive cases.
public enum AutomationCurve: String, Codable, Sendable, Equatable, CaseIterable {
    case linear
    case hold
}

/// What an automation lane drives on its track. The enum shape is
/// persistence-stable NOW even though v0's store rejects some cases
/// (`.sendLevel`, and `.effectParam` on an Audio Unit effect) — the wire/disk
/// contract never changes when the engine grows to support them.
///
/// Custom Codable to a FLAT object `{type, sendId?, effectId?, param?}` — the
/// exact wire and persistence shape agents and the bundle format depend on.
public enum AutomationTarget: Hashable, Sendable, Codable {
    /// The track fader gain; resolves to `Track.volumeRange`.
    case volume
    /// The track pan; resolves to `Track.panRange`.
    case pan
    /// One post-fader send's level; resolves to `Send.levelRange` (v0-deferred
    /// at the store, but the case persists so files round-trip).
    case sendLevel(sendID: UUID)
    /// One built-in effect parameter; resolves through `EffectParamSpec.specs`.
    case effectParam(effectID: UUID, paramName: String)

    private enum CodingKeys: String, CodingKey {
        case type, sendId, effectId, param
    }

    /// The discriminator written to `type`. A String raw enum so an unknown
    /// discriminator on decode is a hard error (not a silent misread).
    private enum Discriminator: String, Codable {
        case volume, pan, sendLevel, effectParam
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .volume:
            try c.encode(Discriminator.volume, forKey: .type)
        case .pan:
            try c.encode(Discriminator.pan, forKey: .type)
        case .sendLevel(let sendID):
            try c.encode(Discriminator.sendLevel, forKey: .type)
            try c.encode(sendID, forKey: .sendId)
        case .effectParam(let effectID, let paramName):
            try c.encode(Discriminator.effectParam, forKey: .type)
            try c.encode(effectID, forKey: .effectId)
            try c.encode(paramName, forKey: .param)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Discriminator.self, forKey: .type) {
        case .volume:
            self = .volume
        case .pan:
            self = .pan
        case .sendLevel:
            self = .sendLevel(sendID: try c.decode(UUID.self, forKey: .sendId))
        case .effectParam:
            self = .effectParam(
                effectID: try c.decode(UUID.self, forKey: .effectId),
                paramName: try c.decode(String.self, forKey: .param))
        }
    }

    /// Resolves the value range this target drives on `track`, reusing the
    /// SAME ranges the manual controls clamp through, or nil when the target
    /// does not resolve: an unknown send id, an unknown effect id, an unknown
    /// or empty effect-param name, or an `.audioUnit` effect (whose generic
    /// param surface is empty in v0). Pure — the store clamps points through it.
    public func valueRange(in track: Track) -> ClosedRange<Double>? {
        switch self {
        case .volume:
            return Track.volumeRange
        case .pan:
            return Track.panRange
        case .sendLevel(let sendID):
            guard track.sends.contains(where: { $0.id == sendID }) else { return nil }
            return Send.levelRange
        case .effectParam(let effectID, let paramName):
            guard !paramName.isEmpty,
                  let effect = track.effects.first(where: { $0.id == effectID })
            else { return nil }
            // m22-f: the delay's sync/division are control-plane-only (the
            // effective time derives from the tempo OFF the render thread,
            // which can't do tempo math) — a lane on them would be a silent
            // dead lane (`DelayEffect.storeAutomatedParam` guards slots 0…4),
            // so lane creation refuses them here like an unknown name.
            if effect.kind == .delay, paramName == "sync" || paramName == "division" {
                return nil
            }
            // `.audioUnit` yields an empty spec table → `first(where:)` is nil.
            return EffectParamSpec.specs(for: effect.kind)
                .first(where: { $0.name == paramName })?.range
        }
    }
}

/// One breakpoint in an automation lane. `beat` clamps to >= 0 at init (the
/// only way to build one, and the path Codable routes through — the `MIDINote`
/// pattern), so a negative time can never enter the model. `value` is stored
/// raw here; the store clamps it to the target's range at the edit boundary.
/// `curve` describes the segment LEAVING this point toward the next.
public struct AutomationPoint: Codable, Sendable, Equatable {
    /// Timeline position in beats from project start (>= 0).
    public var beat: Double
    /// Parameter value at this point (in the target's units; store-clamped).
    public var value: Double
    /// Interpolation of the segment leaving this point.
    public var curve: AutomationCurve

    public init(beat: Double, value: Double, curve: AutomationCurve = .linear) {
        self.beat = max(0, beat)
        self.value = value
        self.curve = curve
    }

    private enum CodingKeys: String, CodingKey { case beat, value, curve }

    /// Decoding routes through the clamping init; `curve` tolerates absence
    /// (defaults to `.linear`), so a hand-authored payload can't smuggle in a
    /// negative beat and an older/terse point still decodes.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            beat: try c.decode(Double.self, forKey: .beat),
            value: try c.decode(Double.self, forKey: .value),
            curve: try c.decodeIfPresent(AutomationCurve.self, forKey: .curve) ?? .linear)
    }

    /// Writes all three keys explicitly (the full point shape on wire and disk).
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(beat, forKey: .beat)
        try c.encode(value, forKey: .value)
        try c.encode(curve, forKey: .curve)
    }
}

/// A per-target automation lane on a track: an ordered set of breakpoints plus
/// an enable flag. Points are stored CANONICALLY ordered (`canonicalize`), and
/// there is AT MOST ONE lane per target per track (store-enforced). Evaluation
/// lives in the single pure function `value(atBeat:)`, reused by the UI, the
/// engine's main-actor side, and headless tests.
public struct AutomationLane: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var target: AutomationTarget
    /// Breakpoints, canonically ordered by beat (see `canonicalize`).
    public var points: [AutomationPoint]
    /// When false the lane is inert: the engine reads the manual (fader/knob)
    /// value instead of the drawn curve. Enable/disable is the v0 read/manual
    /// switch (touch/latch/write recording is deferred).
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        target: AutomationTarget,
        points: [AutomationPoint] = [],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.target = target
        self.points = Self.canonicalize(points)
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey { case id, target, points, isEnabled }

    /// Decoding routes through the canonicalizing init, so a hand-authored or
    /// out-of-order payload heals on load (`id`/`points`/`isEnabled` tolerate
    /// absence; `target` is required — a lane with no target is meaningless).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            target: try c.decode(AutomationTarget.self, forKey: .target),
            points: try c.decodeIfPresent([AutomationPoint].self, forKey: .points) ?? [],
            isEnabled: try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(target, forKey: .target)
        try c.encode(points, forKey: .points)
        try c.encode(isEnabled, forKey: .isEnabled)
    }

    /// Canonical order: sorted ascending by beat, with equal-beat duplicates
    /// deduped LAST-WINS (a later point at the same beat overwrites an earlier
    /// one). Stable, order-independent — the `MIDINote.canonicallyOrdered`
    /// contract for a lane's points.
    public static func canonicalize(_ points: [AutomationPoint]) -> [AutomationPoint] {
        // Walk in input order into a beat-keyed map so a later point at the same
        // beat wins, then sort the survivors by beat.
        var byBeat: [Double: AutomationPoint] = [:]
        byBeat.reserveCapacity(points.count)
        for point in points { byBeat[point.beat] = point }
        return byBeat.values.sorted { $0.beat < $1.beat }
    }

    /// Evaluates the DRAWN curve at `beat`, or nil when the lane has no points
    /// (an empty lane is inert). Before the first point returns the first
    /// value; at/after the last returns the last value; a `.linear` segment
    /// interpolates; a `.hold` segment holds its value until the next point
    /// steps. `isEnabled` gating is the CALLER's responsibility (the engine
    /// reads only enabled lanes) — this stays a pure evaluator of the points.
    public func value(atBeat beat: Double) -> Double? {
        guard let first = points.first, let last = points.last else { return nil }
        if beat <= first.beat { return first.value }
        if beat >= last.beat { return last.value }
        // `beat` is strictly interior; find its segment (points are canonical,
        // so beats are distinct and ascending).
        for i in 0..<(points.count - 1) {
            let lo = points[i]
            let hi = points[i + 1]
            guard beat >= lo.beat, beat < hi.beat else { continue }
            switch lo.curve {
            case .hold:
                return lo.value
            case .linear:
                let span = hi.beat - lo.beat
                guard span > 0 else { return lo.value }
                let t = (beat - lo.beat) / span
                return lo.value + (hi.value - lo.value) * t
            }
        }
        return last.value  // unreachable given the guards, but keeps this total
    }
}
