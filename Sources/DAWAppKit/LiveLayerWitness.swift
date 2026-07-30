import Foundation
import DAWCore

/// The **live-layer tick witness** (m23-r3b) — the seam that turns "this meter
/// is still ticking" into a MEASURABLE claim instead of a visual impression.
///
/// ## Why this exists
///
/// The m22-e poll-discipline law (`ReferencePanelView.swift:26`) forbids
/// `TimelineView(.animation(paused: controlActiveState == .inactive))`: that
/// idiom freezes a live meter whenever the app is not frontmost, and THIS app
/// is driven over a control socket by agents, so its window routinely is not.
/// m23-r3 measured the freeze on the EQ card's spectrum; m23-r3b fixed the
/// three sites that remained — the transport-bar vibe orb, the goniometer
/// trail, and the correlation readouts.
///
/// A frozen meter and a live one are PIXEL-IDENTICAL until the data changes,
/// and two of those three layers keep no smoothed state of their own — so
/// there was nothing downstream to read (the `EQCurveEditorModel
/// .spectrumHeights` trick m23-r3 leaned on does not generalize). This witness
/// is that missing downstream: each live layer reports, once per rendered
/// frame, the values it RESOLVED FOR DRAWING. `debug.liveLayers` publishes
/// them, so a gate can hold focus elsewhere, change the data, and prove the
/// drawn value followed — the only way this bug class is visible at all.
///
/// **Report the resolved value, never a re-derivation** (the m23-r3 M9
/// lesson): the `zone` fields are the zone the VIEW picked, handed in, not
/// recomputed here. A witness that recomputed would stay green through a
/// mis-wired view — it would be describing a branch the view never took.
///
/// ## Cost
///
/// Scalar stores and one `&+=` per frame: **no allocation, no observation**.
/// Held `@ObservationIgnored` (the `VibeSmoother` / `EQSpectrumClock`
/// scratch-object pattern), so recording from inside a `TimelineView` closure
/// schedules no view invalidation — the timeline alone drives the next frame.
///
/// ## Discrimination
///
/// A stopped counter alone is ambiguous: frozen layer, removed layer, and
/// hidden panel all read the same. That is why every reading carries the drawn
/// VALUE beside its count — the gate seeds distinct data and asserts the drawn
/// value followed, which only a ticking layer can do — and why presence is
/// reported separately (`debug.liveLayers` reports the mixer/goniometer gates
/// the views themselves read).
@MainActor
public final class LiveLayerWitness {

    /// What the session vibe orb drew on its last frame — the SMOOTHED state,
    /// i.e. downstream of `VibeSmoother.advance`, so a frozen timeline shows as
    /// a value that never converges on freshly seeded data.
    public struct VibeReading: Equatable, Sendable {
        public var ticks: Int = 0
        public var brightness: Double = 0
        public var hue: Double = 0
        public var motion: Double = 0
        public var isDormant: Bool = true
        public init() {}
    }

    /// What the goniometer trail drew on its last frame. `points` is the
    /// COUNT, never the buffer — copying an array per frame would allocate in
    /// drawing code, which the design language forbids.
    public struct TrailReading: Equatable, Sendable {
        public var ticks: Int = 0
        public var points: Int = 0
        public var calm: Bool = true
        public var zone: StereoScopeModel.CorrelationZone = .inPhase
        public init() {}
    }

    /// What the mono-safety readouts drew on their last frame.
    public struct ReadoutReading: Equatable, Sendable {
        public var ticks: Int = 0
        public var correlation: Double = 0
        public var width: Double = 0
        public var balance: Double = 0
        public var zone: StereoScopeModel.CorrelationZone = .inPhase
        public init() {}
    }

    public private(set) var vibe = VibeReading()
    public private(set) var trail = TrailReading()
    public private(set) var readouts = ReadoutReading()

    public init() {}

    /// One vibe-orb frame. Takes the whole smoothed model rather than loose
    /// scalars: there is no argument order to get wrong, and the reported
    /// values are by construction the ones handed to the Canvas.
    public func recordVibeFrame(_ state: VibeMeterModel) {
        vibe.ticks &+= 1
        vibe.brightness = state.brightness
        vibe.hue = state.hue
        vibe.motion = state.motion
        vibe.isDormant = state.isDormant
    }

    /// One goniometer-trail frame. `zone` is the zone the VIEW resolved (it
    /// tints the trail with it); `calm`/`points` are the drawing decisions the
    /// view already made, so the reading cannot describe a different frame
    /// than the one on screen.
    public func recordTrailFrame(points: Int, calm: Bool,
                                 zone: StereoScopeModel.CorrelationZone) {
        trail.ticks &+= 1
        trail.points = points
        trail.calm = calm
        trail.zone = zone
    }

    /// One mono-safety readout frame: the snapshot the row polled plus the
    /// zone it resolved from it (handed in, not recomputed — see the M9 note).
    public func recordReadoutFrame(_ snapshot: MasterAnalysisSnapshot,
                                   zone: StereoScopeModel.CorrelationZone) {
        readouts.ticks &+= 1
        readouts.correlation = Double(snapshot.correlation)
        readouts.width = Double(snapshot.width)
        readouts.balance = Double(snapshot.balance)
        readouts.zone = zone
    }

    /// Zeroes the tick COUNTS and keeps the last drawn values — so a caller can
    /// measure "frames drawn since now" without losing what is on screen. The
    /// values are deliberately retained: a reading of `ticks == 0` next to a
    /// live value is exactly the freeze signature this witness exists to catch.
    public func resetTicks() {
        vibe.ticks = 0
        trail.ticks = 0
        readouts.ticks = 0
    }
}
