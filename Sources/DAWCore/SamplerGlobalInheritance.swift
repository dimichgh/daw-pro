import Foundation

/// How one of the sampler's GLOBAL scalars is ACTUALLY used, once per-zone
/// overrides are accounted for.
///
/// The defect this exists to end (field report 2026-08-20): a sampler's global
/// `release` reads 3.4465 s over the wire while every note decays in 0.5 s,
/// because an SFZ import gave every zone its own `ampeg_release` and the engine
/// resolves a zone's own value FIRST — `SamplerInstrument` line ~1236:
///
///     voice.releaseSlope = zone.envRelease < 0 ? releaseSlope
///                          : 1 / (zone.envRelease * sampleRate)
///
/// The engine is right (a zone's explicit value winning over the instrument
/// global is both this codebase's documented design — see the
/// `SamplerInstrument` header §4.4 — and SFZ's own region-over-group-over-global
/// precedence). What was wrong was the REPORT: `instrument.describeSampler`
/// emitted the global with nothing to say it was inert, so an agent reading it
/// got a number that looks exactly like a valid answer and is not one. That is
/// this codebase's signature failure mode, and a describe verb is the worst
/// possible place for it.
///
/// ONE HOME: the arithmetic lives here, in `DAWCore`, for the same reason
/// `SamplerZoneCoverage` does — `DAWControl` shapes it into JSON and
/// `DAWAppKit`'s sampler card can dim an inert global readout, and DAWAppKit
/// cannot see DAWControl. `SamplerEditorModel.zoneValue` already resolves
/// `zone.release ?? globals.release` for the PER-ZONE knob and documents it as
/// "the number the engine will use, which is the number a knob must show";
/// this type is that same rule asked in the other direction — for the GLOBAL
/// knob, which zones (if any) still listen to it.
public struct SamplerGlobalUse: Equatable, Sendable {
    /// How many distinct effective values `effectiveValues` will carry before
    /// it truncates. A pathological library can author a different release per
    /// zone across hundreds of zones; `effectiveMin`/`effectiveMax` stay exact
    /// in that case, so the honest range survives truncation.
    public static let valueCap = 8

    /// The stored global — the number `instrument.describeSampler` reports at
    /// top level and `instrument.setSamplerParam` writes.
    public var global: Double
    /// Zones carrying their OWN value for this field. The global does not
    /// reach them.
    public var zonesOverriding: Int
    /// Zones leaving the field nil, which is what makes the global audible.
    public var zonesInheriting: Int
    /// Distinct values the engine will actually apply across every zone,
    /// ascending, capped at `valueCap`. Empty only when there are no zones.
    public var effectiveValues: [Double]
    /// True when more than `valueCap` distinct effective values exist.
    public var valuesTruncated: Bool
    /// The exact extremes of the effective values, truncation notwithstanding.
    /// nil only when there are no zones.
    public var effectiveMin: Double?
    public var effectiveMax: Double?

    /// The load-bearing flag: NO zone inherits this global, and zones exist —
    /// so the stored global is settable, readable, persisted, and never heard.
    ///
    /// Deliberately false for a zero-zone sampler: a sampler with no zones is
    /// silent for reasons that have nothing to do with inheritance, and
    /// calling its global "inert" would point a caller at the wrong problem.
    public var globalIsInert: Bool { zonesOverriding > 0 && zonesInheriting == 0 }

    public init(global: Double, zonesOverriding: Int, zonesInheriting: Int,
                effectiveValues: [Double], valuesTruncated: Bool,
                effectiveMin: Double?, effectiveMax: Double?) {
        self.global = global
        self.zonesOverriding = zonesOverriding
        self.zonesInheriting = zonesInheriting
        self.effectiveValues = effectiveValues
        self.valuesTruncated = valuesTruncated
        self.effectiveMin = effectiveMin
        self.effectiveMax = effectiveMax
    }

    /// Folds a global and one optional-per-zone field into the report above.
    /// `overrides` is one entry per zone, in zone order: the zone's own value,
    /// or nil where it inherits.
    public static func fold(global: Double, overrides: [Double?]) -> SamplerGlobalUse {
        let effective = overrides.map { $0 ?? global }
        let distinct = Array(Set(effective)).sorted()
        return SamplerGlobalUse(
            global: global,
            zonesOverriding: overrides.count { $0 != nil },
            zonesInheriting: overrides.count { $0 == nil },
            effectiveValues: Array(distinct.prefix(valueCap)),
            valuesTruncated: distinct.count > valueCap,
            effectiveMin: distinct.first,
            effectiveMax: distinct.last)
    }

    /// RELEASE — the field the 2026-08-20 report caught. Zone value wins; nil
    /// inherits the LIVE global at trigger time.
    public static func release(of params: SamplerParams) -> SamplerGlobalUse {
        fold(global: params.release, overrides: params.zones.map(\.release))
    }

    /// ATTACK — release's exact twin at the same trigger site (both carry the
    /// engine's `-1` inherit sentinel), and therefore silently wrong in exactly
    /// the same way. Fixed together because fixing only the reported one leaves
    /// an identical hole one field over.
    public static func attack(of params: SamplerParams) -> SamplerGlobalUse {
        fold(global: params.attack, overrides: params.zones.map(\.attack))
    }
}

/// One-shot's near-twin of `SamplerGlobalUse`. Separate because the field is a
/// FLAG, and because it carries a caveat the numeric fields do not.
///
/// ⚠️ The caveat: `SamplerInstrument` also forces a LOOPING voice to non-one-shot
/// (`if voice.looping { voice.oneShotOverride = 0 }`) — loop mode wins over
/// one-shot, so a continuous-loop voice cannot drone forever. That rule fires on
/// the loop the ENGINE resolved, and the engine drops loops whose bounds fall
/// outside the loaded file, which DAWCore cannot evaluate without the audio.
/// So `zonesWithLoopMode` is REPORTED rather than folded into the counts: this
/// type says exactly what it can prove and names the rest instead of guessing.
/// Silently folding it would have replaced one confident wrong number with
/// another, which is the whole defect being fixed here.
public struct SamplerOneShotUse: Equatable, Sendable {
    public var global: Bool
    /// Zones setting `oneShot` explicitly (true OR false — an explicit false
    /// overrides a global true just as firmly).
    public var zonesOverriding: Int
    public var zonesInheriting: Int
    /// Zones authoring a loop mode. Each is non-one-shot when its loop survives
    /// the engine's bounds check, whatever this field's inheritance says.
    public var zonesWithLoopMode: Int

    public var globalIsInert: Bool { zonesOverriding > 0 && zonesInheriting == 0 }

    public init(global: Bool, zonesOverriding: Int, zonesInheriting: Int,
                zonesWithLoopMode: Int) {
        self.global = global
        self.zonesOverriding = zonesOverriding
        self.zonesInheriting = zonesInheriting
        self.zonesWithLoopMode = zonesWithLoopMode
    }

    public static func oneShot(of params: SamplerParams) -> SamplerOneShotUse {
        SamplerOneShotUse(
            global: params.oneShot,
            zonesOverriding: params.zones.count { $0.oneShot != nil },
            zonesInheriting: params.zones.count { $0.oneShot == nil },
            zonesWithLoopMode: params.zones.count { $0.loopMode != nil })
    }
}
