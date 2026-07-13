import CoreGraphics
import Foundation
import Observation
import DAWCore

/// Direct-manipulation TEMPO LANE for the arrange ruler (m12-d, design
/// docs/research/design-m11f-tempo-map.md §3.8). The tempo/meter maps
/// (`DAWCore.TempoMap`/`MeterMap`) already persist and drive the engine; the
/// wire command `tempo.setMap` and `ProjectStore.setTempoMap` are the ONE
/// mutation path (coalescing key "tempo.map" — a drag folds to a single undo).
/// This namespace is the pure geometry + edit math + orchestration for the
/// missing MOUSE surface: render the map's segments (bpm labels, boundary
/// handles) and meter flags, drag a boundary, scrub a segment's bpm, add/remove
/// a segment, edit a meter at a barline.
///
/// Structure mirrors the loop-ruler / marker-lane precedent: a pure `Geometry`
/// value, pure static `Edit` math (value-in → value-out), and an `@Observable`
/// model that reads the map through an injected provider and applies every
/// mutation through an injected `apply` closure wired to `ProjectStore.setTempoMap`
/// (the `QuantizeModel`/`InstrumentPickerModel` idiom — all logic testable
/// without a window). NO VIOLET anywhere: the tempo lane is standard timeline
/// chrome, not AI-generated content (docs/DESIGN-LANGUAGE.md Rule 3). Neutral
/// dark glass; cyan marks only earned active state (the selected segment).

// MARK: - Geometry

/// Beat↔x mapping and boundary/segment hit-classification for the arrange tempo
/// lane, aligned to the timeline's fixed pixels-per-beat so a handle lines up
/// with the grid. A value type carrying only geometry — pure, `Equatable`,
/// headless-testable (the `MarkerLaneGeometry` precedent). Content-space x
/// (x = 0 at the timeline origin, `beat · pixelsPerBeat` elsewhere).
public struct TempoLaneGeometry: Sendable, Equatable {
    /// Horizontal scale — matches `TimelineLanesView.pixelsPerBeat`.
    public var pixelsPerBeat: CGFloat
    /// Grab strip (points) around a segment boundary within which a press lands
    /// on that boundary handle (a generous strip so a thin divider is grabbable).
    public var grabWidth: CGFloat

    public init(pixelsPerBeat: CGFloat = 16, grabWidth: CGFloat = 12) {
        self.pixelsPerBeat = pixelsPerBeat
        self.grabWidth = grabWidth
    }

    /// Content-space x for a project beat.
    public func x(forBeat beat: Double) -> CGFloat { CGFloat(beat) * pixelsPerBeat }

    /// Project beat at a content x, floored at 0.
    public func beat(forX x: CGFloat) -> Double { max(0, Double(x / pixelsPerBeat)) }

    /// The segment index (≥ 1) whose START boundary handle is nearest `contentX`
    /// AND within half the grab width, or nil for an empty part of the lane.
    /// Segment 0's boundary (beat 0) is fixed and NOT grabbable. The NEAREST wins
    /// when two boundaries overlap (segments packed close), so a press grabs the
    /// closest one deterministically.
    public func boundaryIndex(atContentX contentX: CGFloat, segments: [TempoMap.Segment]) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for i in 1..<max(1, segments.count) {
            let d = abs(contentX - x(forBeat: segments[i].startBeat))
            guard d <= grabWidth / 2 else { continue }
            if best == nil || d < best!.distance { best = (i, d) }
        }
        return best?.index
    }

    /// The segment index containing `contentX` (the LAST segment whose start x is
    /// ≤ contentX). Always valid for a non-empty map (segment 0 governs the left).
    public func segmentIndex(atContentX contentX: CGFloat, segments: [TempoMap.Segment]) -> Int {
        let beat = beat(forX: contentX)
        var result = 0
        for i in segments.indices where segments[i].startBeat <= beat { result = i }
        return result
    }
}

// MARK: - Edit math

/// Pure tempo/meter-map edit math for the tempo-lane gesture layer: snapped
/// boundary move, bpm scrub, segment add/remove, meter edit. Every op returns a
/// NEW value-type map (or the original on a no-op), so an on-screen preview never
/// disagrees with what `ProjectStore.setTempoMap` will persist. Static,
/// value-in/value-out — the model is thin over these and tests exercise them
/// headless (the `LoopEdit`/`MarkerLaneEdit` precedent).
public enum TempoLaneEdit {
    /// Minimum beats between two adjacent tempo-segment boundaries — keeps a drag
    /// (or an add) from collapsing two boundaries onto the same beat (which the
    /// map's strictly-increasing invariant would reject).
    public static let minSegmentBeats: Double = 0.25

    /// Move segment `index`'s boundary to a snapped beat, clamped strictly
    /// between its neighbors (so the map stays sorted + unique). Segment 0's
    /// boundary is fixed at beat 0 (index < 1 is a no-op). A collapse onto a
    /// neighbor clamps to `minSegmentBeats` away, never flips.
    public static func movedBoundary(
        map: TempoMap, index: Int, toBeat: Double, snap: ClipSnap, meterMap: MeterMap
    ) -> TempoMap {
        guard index >= 1, index < map.segments.count else { return map }
        var segs = map.segments
        let lower = segs[index - 1].startBeat + minSegmentBeats
        let upper = (index + 1 < segs.count ? segs[index + 1].startBeat : .infinity) - minSegmentBeats
        let snapped = snap.snap(beat: toBeat, meterMap: meterMap)
        segs[index].startBeat = min(max(snapped, lower), upper)
        return (try? TempoMap(segments: segs)) ?? map
    }

    /// Set segment `index`'s bpm (clamped to the transport range via `Segment.init`).
    /// Segment 0 IS scrubbable — it is the base tempo. Out-of-range index no-ops.
    public static func scrubbedBPM(map: TempoMap, index: Int, toBPM: Double) -> TempoMap {
        guard index >= 0, index < map.segments.count else { return map }
        var segs = map.segments
        segs[index] = TempoMap.Segment(startBeat: segs[index].startBeat, bpm: toBPM)
        return (try? TempoMap(segments: segs)) ?? map
    }

    /// Insert a new tempo segment at a snapped beat (> 0; segment 0 is fixed).
    /// Its bpm defaults to the tempo already governing that beat, so an insert is
    /// a no-audible-change SPLIT the user then scrubs. A snap that lands on an
    /// existing boundary (or before `minSegmentBeats` of one) is a no-op.
    public static func addedSegment(
        map: TempoMap, atBeat: Double, bpm: Double? = nil, snap: ClipSnap, meterMap: MeterMap
    ) -> TempoMap {
        let snapped = snap.snap(beat: atBeat, meterMap: meterMap)
        guard snapped > 0 else { return map }
        for seg in map.segments where abs(seg.startBeat - snapped) < minSegmentBeats { return map }
        var segs = map.segments
        segs.append(TempoMap.Segment(startBeat: snapped, bpm: bpm ?? map.bpm(atBeat: snapped)))
        segs.sort { $0.startBeat < $1.startBeat }
        return (try? TempoMap(segments: segs)) ?? map
    }

    /// Remove segment `index` (≥ 1; segment 0 is the base tempo and stays). The
    /// tempo of the removed span reverts to the preceding segment's.
    public static func removedSegment(map: TempoMap, index: Int) -> TempoMap {
        guard index >= 1, index < map.segments.count else { return map }
        var segs = map.segments
        segs.remove(at: index)
        return (try? TempoMap(segments: segs)) ?? map
    }

    /// Add or edit a meter change at the barline nearest `atBeat`. Snapping to a
    /// barline of the CURRENT map makes the new change's own barline constraint
    /// hold by construction; a later change orphaned by the edit (its beat no
    /// longer a whole number of bars past this one) surfaces the map's
    /// `changeOffBarline` teaching error — validated by `MeterMap`'s throwing
    /// init, the SAME validation the store/wire enforce (design §3.2).
    public static func meterEdited(
        meterMap: MeterMap, atBeat: Double, beatsPerBar: Int, beatUnit: Int
    ) throws -> MeterMap {
        let barBeat = meterMap.nearestBarline(toBeat: max(0, atBeat))
        var changes = meterMap.changes
        let change = MeterMap.Change(startBeat: barBeat, beatsPerBar: beatsPerBar, beatUnit: beatUnit)
        if let i = changes.firstIndex(where: { abs($0.startBeat - barBeat) < 1e-9 }) {
            changes[i] = change
        } else {
            changes.append(change)
            changes.sort { $0.startBeat < $1.startBeat }
        }
        return try MeterMap(changes: changes)
    }

    /// Remove a meter change at the barline nearest `atBeat` (change 0 at beat 0
    /// is the project meter and stays). No matching change is a no-op.
    public static func meterRemoved(meterMap: MeterMap, atBeat: Double) -> MeterMap {
        let barBeat = meterMap.nearestBarline(toBeat: max(0, atBeat))
        guard barBeat > 0,
              let i = meterMap.changes.firstIndex(where: { abs($0.startBeat - barBeat) < 1e-9 })
        else { return meterMap }
        var changes = meterMap.changes
        changes.remove(at: i)
        return (try? MeterMap(changes: changes)) ?? meterMap
    }

    /// Beginner-readable message for a meter `ValidationError` (the tempo lane
    /// surfaces it inline; mirrors the store's `meterChangeOffBarline` teaching).
    public static func meterValidationMessage(_ error: MeterMap.ValidationError) -> String {
        switch error {
        case .emptyChanges:
            return "a project always keeps its base time signature at bar 1."
        case .firstChangeNotAtZero:
            return "the first time signature must sit at bar 1."
        case .unsortedOrDuplicateStartBeat:
            return "two time-signature changes can't land on the same bar."
        case .changeOffBarline:
            return "a later time-signature change no longer lands on a bar of this meter — remove or move it first."
        }
    }
}

// MARK: - Amber boundary hint (§3.5)

/// The design's honesty hint (§3.5): an AUDIO clip whose span crosses a
/// non-trivial tempo boundary gets an amber tint — its material streams at its
/// natural rate through the boundary (no time-stretch; `AudioQuantize` rejects
/// across boundaries per m12-c), so beat-alignment inside the clip after the
/// change shifts. MIDI clips NEVER hint (their events are beat-scheduled through
/// the map exactly). A trivial single-segment map never hints (nothing to cross).
public enum TempoLaneHint {
    /// True when an audio clip [startBeat, startBeat+lengthBeats) contains a tempo
    /// boundary STRICTLY inside it. A clip ending exactly on a boundary does NOT
    /// hint (its audible material lives entirely in the earlier segment) — tested
    /// via the last-material beat `end.nextDown`.
    public static func audioClipCrossesBoundary(
        startBeat: Double, lengthBeats: Double, isMIDI: Bool, tempoMap: TempoMap
    ) -> Bool {
        guard !isMIDI, tempoMap.segments.count > 1, lengthBeats > 0 else { return false }
        let lastMaterialBeat = (startBeat + lengthBeats).nextDown
        return !tempoMap.isConstant(from: startBeat, to: lastMaterialBeat)
    }
}

// MARK: - Model

/// Headless orchestration for the tempo lane: reads the resolved tempo/meter
/// maps through an injected provider, applies every edit through an injected
/// closure wired to `ProjectStore.setTempoMap` (so the wire/UI stay equivalent
/// by construction and a drag coalesces to ONE undo), and holds the small amount
/// of UI state the SwiftUI lane binds to (focus + selection + the last teaching
/// error). No SwiftUI, no store reference — the `QuantizeModel` idiom.
@MainActor
@Observable
public final class TempoLaneModel {
    /// Reads the RESOLVED maps (always ≥ 1 entry each — a single-tempo project
    /// reports its synthesized single segment/change). Read fresh each access so
    /// a wire `tempo.setMap` shows up live.
    private let mapProvider: () -> (tempo: TempoMap, meter: MeterMap)
    /// Applies a full-replace map (wired to `ProjectStore.setTempoMap`; a recorder
    /// in tests). `meter == nil` leaves the meter untouched (a tempo-only edit).
    private let applyClosure: (TempoMap, MeterMap?) throws -> Void

    /// Whether the lane has editing focus (a segment selected / hovered). Drives
    /// the selection ring; not persisted.
    public var selectedSegmentIndex: Int?
    /// The last teaching error a rejected edit produced (recording lock, meter
    /// barline), surfaced inline; cleared on the next successful edit.
    public private(set) var lastErrorMessage: String?

    public init(
        map: @escaping () -> (tempo: TempoMap, meter: MeterMap),
        apply: @escaping (TempoMap, MeterMap?) throws -> Void
    ) {
        self.mapProvider = map
        self.applyClosure = apply
    }

    // MARK: Reads (fresh from the provider)

    public var tempoMap: TempoMap { mapProvider().tempo }
    public var meterMap: MeterMap { mapProvider().meter }
    /// True when the project has a single project-wide tempo AND a single meter —
    /// the lane must NOT nag in this case (it shows the scalar affordance instead).
    public var isTrivial: Bool {
        let (tempo, meter) = mapProvider()
        return tempo.segments.count == 1 && meter.changes.count == 1
    }

    public func selectSegment(_ index: Int?) {
        guard let index else { selectedSegmentIndex = nil; return }
        let count = mapProvider().tempo.segments.count
        selectedSegmentIndex = (index >= 0 && index < count) ? index : nil
    }

    // MARK: Mutations (every path funnels through `apply`)

    private func apply(_ tempo: TempoMap, meter: MeterMap? = nil) {
        do {
            try applyClosure(tempo, meter)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// Move segment `index`'s boundary to a snapped beat (index ≥ 1).
    public func dragBoundary(index: Int, toBeat: Double, snap: ClipSnap) {
        let (tempo, meter) = mapProvider()
        apply(TempoLaneEdit.movedBoundary(map: tempo, index: index, toBeat: toBeat, snap: snap, meterMap: meter))
    }

    /// Scrub segment `index`'s bpm to `toBPM` (clamped to the transport range).
    public func scrubBPM(index: Int, toBPM: Double) {
        apply(TempoLaneEdit.scrubbedBPM(map: mapProvider().tempo, index: index, toBPM: toBPM))
    }

    /// Insert a tempo segment at a snapped beat (a no-audible-change split).
    public func addSegment(atBeat: Double, snap: ClipSnap, bpm: Double? = nil) {
        let (tempo, meter) = mapProvider()
        let updated = TempoLaneEdit.addedSegment(map: tempo, atBeat: atBeat, bpm: bpm, snap: snap, meterMap: meter)
        apply(updated)
        if updated.segments.count > tempo.segments.count,
           let i = updated.segments.firstIndex(where: { seg in !tempo.segments.contains(where: { abs($0.startBeat - seg.startBeat) < 1e-9 }) }) {
            selectedSegmentIndex = i
        }
    }

    /// Remove tempo segment `index` (≥ 1).
    public func removeSegment(index: Int) {
        apply(TempoLaneEdit.removedSegment(map: mapProvider().tempo, index: index))
        if selectedSegmentIndex == index { selectedSegmentIndex = nil }
    }

    /// Add/edit a meter change at the barline nearest `atBeat`. A barline-invalid
    /// edit sets `lastErrorMessage` and touches nothing.
    public func setMeter(atBeat: Double, beatsPerBar: Int, beatUnit: Int) {
        let (tempo, meter) = mapProvider()
        do {
            let newMeter = try TempoLaneEdit.meterEdited(
                meterMap: meter, atBeat: atBeat, beatsPerBar: beatsPerBar, beatUnit: beatUnit)
            apply(tempo, meter: newMeter)
        } catch let error as MeterMap.ValidationError {
            lastErrorMessage = TempoLaneEdit.meterValidationMessage(error)
        } catch {
            lastErrorMessage = "\(error)"
        }
    }

    /// Remove a meter change at the barline nearest `atBeat`.
    public func removeMeter(atBeat: Double) {
        let (tempo, meter) = mapProvider()
        apply(tempo, meter: TempoLaneEdit.meterRemoved(meterMap: meter, atBeat: atBeat))
    }
}
