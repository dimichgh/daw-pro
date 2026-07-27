import CoreGraphics
import Foundation
import DAWCore

/// The ONE home for "where does a dragged audio file land on the arrange
/// timeline" (m23-f) — grid snap plus magnetic snap to bar 1 and to the target
/// lane's clip edges. Headless and tested, in the `MixerStripLayout` /
/// `KnobGeometry` / `PianoRollPlayhead` / `EQFilterResponse` tradition: exactly
/// one place computes it, so the drop LINE the user sees and the beat the clip
/// LANDS on cannot drift apart.
///
/// Before m23-f the preview and the landing were two independent computations
/// (`TimelineLanesView.resolveDropHover` snapped, then `AudioImportPlan` snapped
/// the raw beat a second time) that happened to agree because they used the same
/// inputs. Magnetic snap breaks that agreement by construction — the view knows
/// where clip edges are and the import plan does not — so the resolved beat is
/// now produced HERE, once, and carried as a `ResolvedDropBeat` through
/// `AudioImportContext` to the store. `AudioImportContext` deliberately no
/// longer carries `snap`/`meterMap`: with the beat already resolved there is
/// nothing left downstream that could re-derive it differently.

/// A landing beat that has ALREADY been resolved against the grid + magnets.
/// The initializer is `fileprivate`, so the only way to obtain one is
/// `ArrangeDropSnap.resolve(...)` — that is what makes "one call, not two
/// computations that agree" a compile-time property rather than a convention.
public struct ResolvedDropBeat: Sendable, Equatable {
    /// Which rule decided the beat — carried for the debug echo and gates, so a
    /// test can assert WHY a drop landed where it did, not just where.
    public enum Source: String, Sendable, Equatable {
        /// `ClipSnap.off`: the user asked for no snapping, so the raw beat
        /// stands (floored at 0) and no magnet is applied.
        case raw
        /// The nearest grid line of the effective snap.
        case grid
        /// Magnetised to bar 1 (beat 0).
        case magnetBarOne
        /// Magnetised to the start or end edge of a clip on the target lane.
        case magnetClipEdge
    }

    public let beat: Double
    public let source: Source

    fileprivate init(beat: Double, source: Source) {
        self.beat = beat
        self.source = source
    }

    /// True when a magnet (not the plain grid) decided this landing.
    public var isMagnetised: Bool {
        source == .magnetBarOne || source == .magnetClipEdge
    }
}

public enum ArrangeDropSnap {
    /// How near (in POINTS on screen) the pointer must be to a magnet target for
    /// the magnet to take it.
    ///
    /// Points, not beats, so the feel is zoom-invariant: "within about a pointer
    /// width of the target" means the same thing at every zoom. Value chosen
    /// against the two numbers already in this codebase rather than invented:
    /// it is strictly larger than `ArrangePointer.playheadGrabTolerance` (4 pt)
    /// — a magnet is a coarse placement assist, not a precision hit-test, so it
    /// must not be as tight as a grab target — and small enough that at the
    /// DEFAULT zoom (`ArrangeZoom.defaultPixelsPerBeat` = 16 pt/beat) it spans
    /// 0.625 beat, i.e. a magnet can never pull a drop across a whole beat at
    /// the default scale, nor across a 4/4 bar at any legal zoom down to
    /// 4 pt/beat (10/4 = 2.5 beats < 4).
    ///
    /// The zoom consequence is deliberate and worth naming: because the radius
    /// is fixed in points, zooming OUT makes it cover more musical time. At the
    /// 4 pt/beat floor a magnet reaches 2.5 beats. That is the intended
    /// screen-invariance — at that scale 2.5 beats IS a pointer width — but it
    /// is the kind of behaviour a user notices, so it is documented here rather
    /// than discovered.
    public static let magnetThresholdPoints: Double = 10

    /// Bar 1 (beat 0) — always a magnet candidate. A drop near the very start of
    /// the song should land exactly at the start.
    public static let barOneBeat: Double = 0

    /// The magnet beats a lane contributes: the START and END of each of its
    /// clips. These are frequently OFF the grid (a trimmed clip, an odd
    /// AI-authored length), which is exactly why the magnet exists.
    public static func clipEdgeBeats(startBeats: [Double], lengthBeats: [Double]) -> [Double] {
        var edges: [Double] = []
        edges.reserveCapacity(startBeats.count * 2)
        for (start, length) in zip(startBeats, lengthBeats) {
            edges.append(start)
            edges.append(start + length)
        }
        return edges
    }

    /// Resolves a raw drop beat into the ONE landing beat.
    ///
    /// Rules, in order:
    ///  1. The beat is floored at 0 — nothing lands before the start of the song.
    ///  2. `ClipSnap.off` means the user asked for NO snapping: the raw beat
    ///     stands and NO magnet is applied. Magnetising an explicitly
    ///     snap-disabled drop would be the app overruling a setting the user
    ///     turned off on purpose.
    ///  3. Otherwise a magnet target WITHIN `magnetThresholdPoints` takes the
    ///     drop, in preference to the grid; among magnets, the nearest wins,
    ///     ties going to the lower beat (deterministic, and bar 1 — being beat
    ///     0 — therefore wins any tie it is in).
    ///  4. With no magnet in range, the effective grid decides.
    ///
    /// WHY MAGNET PRECEDENCE AND NOT NEAREST-WINS-OVERALL. Beat 0 is a grid line
    /// for EVERY `ClipSnap` division, and `ClipSnap.snap` rounds to the NEAREST
    /// grid line, so `distance(grid, raw) <= distance(0, raw)` always holds. A
    /// nearest-wins rule that includes the grid as a peer candidate therefore
    /// makes the bar-1 magnet provably dead — it can tie but never win — and a
    /// clip-edge magnet dies too whenever the grid is fine. Precedence within a
    /// bounded radius is what makes a magnet a magnet; the radius is what keeps
    /// it from overriding the grid everywhere else.
    public static func resolve(rawBeat: Double,
                               snap: ClipSnap,
                               meterMap: MeterMap,
                               pixelsPerBeat: Double,
                               clipEdgeBeats: [Double] = []) -> ResolvedDropBeat {
        let raw = max(0, rawBeat.isFinite ? rawBeat : 0)

        guard snap != .off else {
            return ResolvedDropBeat(beat: raw, source: .raw)
        }

        // A degenerate scale would make the threshold infinite; treat it as "no
        // magnet" rather than "magnet everywhere".
        let ppb = pixelsPerBeat.isFinite ? pixelsPerBeat : 0
        if ppb > 0 {
            let thresholdBeats = magnetThresholdPoints / ppb
            var best: (beat: Double, distance: Double, source: ResolvedDropBeat.Source)?
            func consider(_ beat: Double, _ source: ResolvedDropBeat.Source) {
                let target = max(0, beat)
                let distance = abs(target - raw)
                guard distance <= thresholdBeats else { return }
                guard let current = best else {
                    best = (target, distance, source)
                    return
                }
                // Nearest wins; an exact tie goes to the LOWER beat so the
                // result never depends on candidate ordering.
                if distance < current.distance
                    || (distance == current.distance && target < current.beat) {
                    best = (target, distance, source)
                }
            }
            consider(barOneBeat, .magnetBarOne)
            for edge in clipEdgeBeats where edge.isFinite {
                consider(edge, .magnetClipEdge)
            }
            if let best {
                return ResolvedDropBeat(beat: best.beat, source: best.source)
            }
        }

        return ResolvedDropBeat(beat: snap.snap(beat: raw, meterMap: meterMap), source: .grid)
    }
}

/// The arrange drop's DRAG-SESSION state (m23-f). A `DropDelegate` hover is an
/// overlay with no owner: it is armed by drag callbacks and cleared only by
/// other drag callbacks, so if a terminating callback never arrives the overlay
/// is stranded — a full-`contentHeight`, hit-test-inert, glowing line the user
/// cannot grab, move, or dismiss. That is the m23-f report (2) defect, measured
/// at 224 px (= 112 pt = `contentHeight`) against a 100 px `rowHeight`.
///
/// This type is the headless half of the fix. It exists so the two rules below
/// are testable without SwiftUI and without a real drag (which cannot be
/// synthesized: `DropInfo` has no public initializer, and the unbundled staging
/// binary has no Accessibility grant).
public struct ArrangeDropSession: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable {
        /// No drag in flight. An `update` here is treated as an implicit enter,
        /// so a drag whose `dropEntered` was never delivered still previews.
        case idle
        /// A drag is over the lanes.
        case dragging
        /// A drop was performed and the session is CLOSED. An `update` here is
        /// refused: it is the ordering that re-arms a hover nothing will clear
        /// again. Only a fresh `enter` (or an `exit`) reopens the session.
        case dropped
    }

    public private(set) var phase: Phase

    public init(phase: Phase = .idle) {
        self.phase = phase
    }

    /// The drag entered the lanes. Always arms the preview.
    @discardableResult
    public mutating func entered() -> Bool {
        phase = .dragging
        return true
    }

    /// The drag moved. Returns whether the preview may be armed.
    @discardableResult
    public mutating func updated() -> Bool {
        switch phase {
        case .dropped:
            // Post-drop: refuse. Re-arming here strands the overlay, because the
            // drag is already over and no further callback is coming.
            return false
        case .idle, .dragging:
            phase = .dragging
            return true
        }
    }

    /// The drag was released over the lanes. Closes the session.
    public mutating func dropped() {
        phase = .dropped
    }

    /// The drag left the lanes (or was cancelled). Reopens for the next drag.
    public mutating func exited() {
        phase = .idle
    }

    /// An ORDINARY pointer event reached the lanes. Returns whether a standing
    /// drop hover should be dismissed.
    ///
    /// This is the rule that makes the artifact removable no matter which drag
    /// callback the OS withheld: the user's very next mouse move over the
    /// timeline clears a stranded line. It is guarded on the mouse button
    /// because a Finder drag holds the primary button down for its whole
    /// duration — so if hover events ever WERE delivered mid-drag, this could
    /// still never cancel a live preview. `pressedMouseButtons` is the AppKit
    /// bitmask (`NSEvent.pressedMouseButtons`); 0 means nothing is held.
    public static func pointerMayDismissHover(hoverPresent: Bool,
                                              pressedMouseButtons: Int) -> Bool {
        hoverPresent && pressedMouseButtons == 0
    }
}
