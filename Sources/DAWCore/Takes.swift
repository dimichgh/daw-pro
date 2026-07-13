import Foundation

/// One lane of a take group (M5 iii-a). Its payload is a full `Clip` value
/// (audio or MIDI), so lanes reuse the clip Codable, the audio-vs-MIDI
/// unification via `notes`, and every gain/stretch/offset field for free.
///
/// The lane clip uses ABSOLUTE timeline coordinates — the same `startBeat`
/// space as any clip — so no relative math is ever needed; the group's range is
/// derived from the union of its lanes' extents.
///
/// Invariant (enforced in `init`): the payload clip never carries a
/// `takeGroupID` of its own — take payloads never nest. A lane clip is never a
/// member of `track.clips`.
public struct TakeLane: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    /// Display name, e.g. "Take 3".
    public var name: String
    /// Full take payload in ABSOLUTE timeline beats. Audio takes carry
    /// `audioFileURL` + `startOffsetSeconds` (+ optional stretch); MIDI takes
    /// carry `notes`.
    public var clip: Clip

    public init(id: UUID = UUID(), name: String, clip: Clip) {
        self.id = id
        self.name = name
        // Enforce the no-nesting invariant by construction: a lane payload can
        // never itself be a comp member.
        if clip.takeGroupID != nil {
            var stripped = clip
            stripped.takeGroupID = nil
            self.clip = stripped
        } else {
            self.clip = clip
        }
    }

    /// Decoding routes through the stripping `init` so a hand-authored payload
    /// can never smuggle in a nested `takeGroupID`.
    public init(from decoder: any Decoder) throws {
        enum K: String, CodingKey { case id, name, clip }
        let c = try decoder.container(keyedBy: K.self)
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "Take",
            clip: try c.decode(Clip.self, forKey: .clip)
        )
    }
}

/// One comp choice: "play lane `laneID` over `[startBeat, endBeat)`" in absolute
/// beats. A group's comp is a list of these — sorted, non-overlapping, each
/// inside the group range. GAPS ARE LEGAL (they read as silence).
public struct CompSegment: Codable, Sendable, Equatable {
    public var laneID: UUID
    public var startBeat: Double
    /// Strictly greater than `startBeat` (store-enforced).
    public var endBeat: Double

    public init(laneID: UUID, startBeat: Double, endBeat: Double) {
        self.laneID = laneID
        self.startBeat = startBeat
        self.endBeat = endBeat
    }

    private enum CodingKeys: String, CodingKey {
        case laneID = "laneId"
        case startBeat, endBeat
    }
}

/// A take group living out-of-band on `Track.takeGroups`. The comp result is
/// materialized ("flattened") into ordinary clips inside `track.clips`, marked
/// by `Clip.takeGroupID`; the engine, offline renderer, snapshot, and media
/// pipeline see only ordinary clips.
public struct TakeGroup: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    /// At least one (store-enforced). Ordered oldest-first (lane 0 = oldest).
    public var lanes: [TakeLane]
    /// The comp: sorted, non-overlapping segments inside the group range. Gaps
    /// are legal. Default on creation: the newest lane across the full range.
    public var comp: [CompSegment]
    /// Join crossfade width in SECONDS (fades are stored in beats on the
    /// flattened clips; the flattener converts at the project tempo). Clamped to
    /// `crossfadeSecondsRange`.
    public var crossfadeSeconds: Double

    /// Join-crossfade width bounds (seconds).
    public static let crossfadeSecondsRange: ClosedRange<Double> = 0...0.2
    /// Default join-crossfade width (seconds).
    public static let defaultCrossfadeSeconds: Double = 0.010
    /// Loop-cycle take recording floor (m15-b, design-m15b §6): the shortest
    /// loop cycle `record` accepts with a loop enabled — bounds lane creation
    /// at ≤ 60 lanes/minute (one 4/4 bar at 240 BPM). Below it, record
    /// refuses with a teaching error instead of spraying sliver lanes
    /// (a 0.25-beat loop at 400 BPM would land ~27 lanes/second).
    public static let minLoopRecordCycleSeconds: Double = 1.0

    public init(
        id: UUID = UUID(),
        name: String,
        lanes: [TakeLane],
        comp: [CompSegment] = [],
        crossfadeSeconds: Double = TakeGroup.defaultCrossfadeSeconds
    ) {
        self.id = id
        self.name = name
        self.lanes = lanes
        self.comp = comp
        self.crossfadeSeconds = crossfadeSeconds.clamped(to: Self.crossfadeSecondsRange)
    }

    /// Decoding routes through the clamping `init` (the `MIDINote`/`Clip`
    /// precedent), and tolerates an absent `crossfadeSeconds` (older/hand
    /// payloads read the default).
    public init(from decoder: any Decoder) throws {
        enum K: String, CodingKey { case id, name, lanes, comp, crossfadeSeconds }
        let c = try decoder.container(keyedBy: K.self)
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "Takes",
            lanes: try c.decodeIfPresent([TakeLane].self, forKey: .lanes) ?? [],
            comp: try c.decodeIfPresent([CompSegment].self, forKey: .comp) ?? [],
            crossfadeSeconds: try c.decodeIfPresent(Double.self, forKey: .crossfadeSeconds)
                ?? Self.defaultCrossfadeSeconds
        )
    }

    /// Derived, not stored: the union of the lanes' clip extents in absolute
    /// beats. An empty group (no lanes) reports `0...0`.
    public var rangeBeats: ClosedRange<Double> {
        guard !lanes.isEmpty else { return 0...0 }
        let lower = lanes.map(\.clip.startBeat).min() ?? 0
        let upper = lanes.map { $0.clip.startBeat + $0.clip.lengthBeats }.max() ?? lower
        return lower...max(lower, upper)
    }
}

/// Pure, headless flattener that turns a take group's comp into ordinary clips
/// (M5 iii-a, spec §2). Deterministic: the same group + tempo yields an
/// identical member list except for the freshly generated `Clip.id`s.
///
/// The engine is never involved — members are ordinary clips on the existing
/// `tracksDidChange` restart seam. Audio joins reuse the settled M5 (i-b)
/// representational crossfade: adjacent members overlap by the crossfade width
/// with equal-power fade-out/in, and the strip sumMixer's overlapping-clips sum
/// produces the constant-power crossfade. MIDI joins are clean cuts.
public enum CompFlattener {

    /// Intermediate record kept for the crossfade pass.
    private struct Member {
        var clip: Clip
        let segIndex: Int
        let segStart: Double
        let segEnd: Double
        let isAudio: Bool
        /// Absolute extent of the member BEFORE any crossfade extension.
        let memberStart: Double
        let memberEnd: Double
        /// The lane clip's absolute start (`Cs`), its consumed end (`Cs + Cl`),
        /// and its stretch ratio — for the source-material crossfade clamps.
        let laneStartBeat: Double
        let laneEndBeat: Double
        let laneStartOffsetSeconds: Double
        let stretchRatio: Double

        var originalLength: Double { memberEnd - memberStart }
    }

    /// Flattens `group` under `tempoMap` into ordinary member clips (each with
    /// `takeGroupID == group.id`). Source-window offsets integrate over each
    /// member's timeline span (m12-b; trivial-map arithmetic identical to the
    /// old fixed `secPerBeat` by the map's same-segment fast path).
    public static func flatten(_ group: TakeGroup, tempoMap: TempoMap) -> [Clip] {
        let laneByID = Dictionary(group.lanes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let sortedComp = group.comp.sorted { $0.startBeat < $1.startBeat }

        var members: [Member] = []
        for (idx, seg) in sortedComp.enumerated() {
            guard let lane = laneByID[seg.laneID] else { continue }
            let source = lane.clip
            let laneStart = source.startBeat
            let laneEnd = source.startBeat + source.lengthBeats
            let memberStart = max(seg.startBeat, laneStart)
            let memberEnd = min(seg.endBeat, laneEnd)
            // Empty intersection → no clip (a segment can reach beyond its lane's
            // material — that part is honest silence).
            guard memberEnd > memberStart else { continue }
            let memberLength = memberEnd - memberStart
            let ratio = source.stretchRatio > 0 ? source.stretchRatio : 1
            // Windowing = the splitClip math, generalized for stretch (spec §2):
            // the source-domain offset advances by the timeline span
            // [laneStart, memberStart] integrated through the map, scaled by
            // the lane's ratio.
            let memberOffset = source.startOffsetSeconds
                + tempoMap.seconds(from: laneStart, to: memberStart) / ratio

            let isAudio = source.notes == nil
            let windowedNotes = source.notes.map {
                windowNotes($0, laneStartBeat: laneStart,
                            memberStart: memberStart, memberEnd: memberEnd)
            }

            var member = Clip(
                id: UUID(),
                name: lane.name,
                startBeat: memberStart,
                lengthBeats: memberLength,
                audioFileURL: isAudio ? source.audioFileURL : nil,
                notes: windowedNotes,
                isAIGenerated: source.isAIGenerated,
                startOffsetSeconds: memberOffset,
                gainDb: source.gainDb,
                // Fades default clean; the crossfade pass sets audio joins.
                fadeInBeats: 0, fadeOutBeats: 0,
                fadeInCurve: .linear, fadeOutCurve: .linear,
                stretchRatio: source.stretchRatio,
                pitchShiftSemitones: source.pitchShiftSemitones,
                formantPreserve: source.formantPreserve,
                // Window the envelope with the same split/trim discipline the
                // arrange edits use (ProjectStore.swift:2426/2512/2623): a
                // materialized member plays only [memberStart, memberEnd] of the
                // lane, so re-anchor at delta = memberStart − laneStart. Empty
                // source envelope windows to empty (MIDI lanes stay clean).
                gainEnvelope: Clip.windowedGainEnvelope(
                    source.gainEnvelope,
                    delta: memberStart - laneStart,
                    newLength: memberLength),
                // Controller lanes (m16-b, design-m16b §11 take-comping row):
                // window with the same split/trim discipline so a comp window
                // carries honest lane state (the new head opens with the value in
                // effect there). A MIDI lane source windows to real lanes; an
                // audio lane source has none, so this stays [].
                controllerLanes: Clip.windowedControllerLanes(
                    source.controllerLanes,
                    delta: memberStart - laneStart,
                    newLength: memberLength)
            )
            member.takeGroupID = group.id

            members.append(Member(
                clip: member, segIndex: idx,
                segStart: seg.startBeat, segEnd: seg.endBeat,
                isAudio: isAudio, memberStart: memberStart, memberEnd: memberEnd,
                laneStartBeat: laneStart, laneEndBeat: laneEnd,
                laneStartOffsetSeconds: source.startOffsetSeconds, stretchRatio: ratio))
        }

        applyCrossfades(&members, group: group, tempoMap: tempoMap)
        return members.map(\.clip)
    }

    /// Applies representational equal-power crossfades at abutting audio joins.
    private static func applyCrossfades(_ members: inout [Member], group: TakeGroup,
                                        tempoMap: TempoMap) {
        guard members.count >= 2, group.crossfadeSeconds > 0 else { return }
        for i in 1..<members.count {
            let left = members[i - 1]
            let right = members[i]
            guard left.isAudio, right.isAudio else { continue }
            // Adjacent in the SORTED comp and abutting (gap == 0 at the join).
            guard left.segIndex + 1 == right.segIndex else { continue }
            let boundary = left.segEnd
            guard right.segStart == boundary else { continue }
            // Both members must actually reach the boundary (no missing material).
            guard left.memberEnd == boundary, right.memberStart == boundary else { continue }

            // Stored SECONDS → beats via the inverse integral AT the join
            // beat (design row 6): the crossfade stays the same wall-clock
            // width wherever the join sits on the map.
            var xfBeats = tempoMap.beat(from: boundary, elapsedSeconds: group.crossfadeSeconds)
                - boundary
            // Fit the join: never wider than half the shorter member.
            xfBeats = min(xfBeats, min(left.originalLength, right.originalLength) / 2)
            // Left tail extension (xf/2 past b) must not read past the left lane's
            // consumed source end.
            xfBeats = min(xfBeats, 2 * (left.laneEndBeat - boundary))
            // Right head extension (xf/2 before b) must not push the offset below
            // the right lane clip's own offset (i.e. before the lane clip start).
            xfBeats = min(xfBeats, 2 * (boundary - right.laneStartBeat))
            guard xfBeats > 0 else { continue }
            let half = xfBeats / 2

            // Left member extends xf/2 past the boundary, equal-power fade-out.
            members[i - 1].clip.lengthBeats = left.clip.lengthBeats + half
            members[i - 1].clip.fadeOutBeats = xfBeats
            members[i - 1].clip.fadeOutCurve = .equalPower

            // Right member starts xf/2 before the boundary (offset reduced by the
            // source-domain equivalent — the integral over the head-extension
            // span), equal-power fade-in.
            let offsetReduction = tempoMap.seconds(from: boundary - half, to: boundary)
                / right.stretchRatio
            members[i].clip.startBeat = right.clip.startBeat - half
            members[i].clip.lengthBeats = right.clip.lengthBeats + half
            members[i].clip.startOffsetSeconds = max(0, right.clip.startOffsetSeconds - offsetReduction)
            members[i].clip.fadeInBeats = xfBeats
            members[i].clip.fadeInCurve = .equalPower
        }
    }

    /// Windows a lane's MIDI notes to the member's absolute `[start, end)`,
    /// rebased to the member start, with overhang truncation (the splitClip /
    /// trimClip partition math). Notes thinner than `minLengthBeats` after
    /// truncation are dropped. Output is canonically ordered.
    static func windowNotes(_ notes: [MIDINote], laneStartBeat: Double,
                            memberStart: Double, memberEnd: Double) -> [MIDINote] {
        var out: [MIDINote] = []
        for note in notes {
            let absStart = laneStartBeat + note.startBeat
            let absEnd = laneStartBeat + note.endBeat
            guard absEnd > memberStart, absStart < memberEnd else { continue }
            let clampedStart = max(absStart, memberStart)
            let clampedEnd = min(absEnd, memberEnd)
            let length = clampedEnd - clampedStart
            guard length >= MIDINote.minLengthBeats else { continue }
            out.append(MIDINote(id: note.id, pitch: note.pitch, velocity: note.velocity,
                                startBeat: clampedStart - memberStart, lengthBeats: length))
        }
        return MIDINote.canonicallyOrdered(out)
    }
}
