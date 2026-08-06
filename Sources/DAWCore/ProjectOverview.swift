import Foundation

/// Agent-facing project snapshot (M7): a structured, aggressively summarized
/// projection of the session — "what is in this session and what are the ids
/// I need to act", in a few KB. Unlike `ProjectStore.snapshot()` (full
/// fidelity: every MIDI note, every automation point, file paths),
/// `ProjectOverview` reports COUNTS instead of lists wherever a list can grow
/// unbounded, and never carries a file path (basename at most). It is a pure,
/// read-only, side-effect-free projection — safe to call at any time, never
/// mutates the store, never touches the engine.
///
/// IDs are full UUIDs (not the copilot-catalog's prefix-shortened form):
/// agents need them verbatim to issue follow-up commands like
/// `track.setVolume` or `clip.move` without a resolution round trip.
public struct ProjectOverview: Codable, Sendable, Equatable {
    public struct Loop: Codable, Sendable, Equatable {
        public var enabled: Bool
        public var startBeat: Double
        public var endBeat: Double
    }

    public struct Metronome: Codable, Sendable, Equatable {
        public var enabled: Bool
        public var countInBars: Int
    }

    public struct Punch: Codable, Sendable, Equatable {
        public var enabled: Bool
        public var inBeat: Double
        public var outBeat: Double
    }

    public struct Transport: Codable, Sendable, Equatable {
        public var tempoBPM: Double
        public var isPlaying: Bool
        public var isRecording: Bool
        public var positionBeats: Double
        public var loop: Loop
        public var metronome: Metronome
        public var punch: Punch
    }

    public struct Master: Codable, Sendable, Equatable {
        public var volume: Double
        /// Peak level of the last frame the MASTER BUS was HEARD producing, in
        /// dBFS (m23-dm). Floor −80, always finite; a POSITIVE value means the
        /// mix clipped.
        ///
        /// Identical semantics and identical naming to ``Track/peakDb``, and
        /// deliberately so: it is the REFERENCE those per-track numbers are
        /// read against ("the kick is 8 dB under the master" is a judgement,
        /// "the kick is −14 dBFS" is a number that still needs one).
        ///
        /// Present only when the master has actually produced a non-silent
        /// frame at some point this session — `nil` means "no signal
        /// observed", which is honestly different from "measured silent", and
        /// −80 would claim a measurement that never happened.
        ///
        /// RETAINED ACROSS A STOP, and that is the whole point of the field:
        /// an agent reads this projection BETWEEN actions, i.e. while the
        /// transport is stopped, and the live `masterMeter` is deliberately
        /// zeroed at that moment. The source is
        /// `ProjectStore.lastNonSilentMasterMeter` — see its doc comment.
        public var peakDb: Double?
        /// RMS of that same frame in dBFS — "how loud is this mix sitting",
        /// where ``peakDb`` is "did it clip". Same floor, same finiteness
        /// guarantee, same present-only-if-ever-heard rule.
        public var rmsDb: Double?
    }

    public struct Send: Codable, Sendable, Equatable {
        public var destinationBusID: UUID
        public var level: Double
        /// Always `false` in v0 — `Send` has no pre-fader concept today (all
        /// sends are post-fader); the field is carried so the wire contract
        /// doesn't have to change if pre-fader sends ever land.
        public var preFader: Bool
    }

    public struct Effect: Codable, Sendable, Equatable {
        public var name: String
        public var bypassed: Bool
    }

    public struct AutomationLane: Codable, Sendable, Equatable {
        public var target: String
        public var enabled: Bool
        public var pointCount: Int
    }

    public struct Clip: Codable, Sendable, Equatable {
        public var id: UUID
        public var name: String
        public var startBeat: Double
        public var lengthBeats: Double
        /// "audio" or "midi" — mirrors the clip's content, not a display label.
        public var kind: String
        /// MIDI clips only: number of notes (never the notes themselves).
        public var noteCount: Int?
        /// Grouped (take-lane) clips only.
        public var takeLaneCount: Int?
        public var activeLane: Int?
        /// Audio clips only: true when the clip carries a non-identity
        /// time-stretch.
        public var hasStretch: Bool?
        /// Audio clips only: true when the clip has fade-in and/or fade-out.
        public var hasFades: Bool?
        /// Audio clips only: present only when non-zero (the "gain-if-
        /// nonzero" rule from the v1 contract).
        public var gainDb: Double?
    }

    public struct Track: Codable, Sendable, Equatable {
        public var id: UUID
        public var name: String
        public var kind: String
        public var muted: Bool
        public var soloed: Bool
        public var armed: Bool
        public var volume: Double
        public var pan: Double
        /// Destination track id, or nil for master.
        public var output: UUID?
        /// Display name of the hosted instrument, if this is an instrument
        /// track with one configured.
        public var instrument: String?
        public var sends: [Send]
        public var fx: [Effect]
        public var clips: [Clip]
        public var automation: [AutomationLane]
        /// Peak level of the last frame this track was HEARD producing, in
        /// dBFS (m23-cv). Floor −80, always finite; a POSITIVE value means the
        /// track clipped.
        ///
        /// Present only when the track has actually produced a non-silent
        /// frame at some point this session — the "gain-if-nonzero" rule
        /// applied to levels: `nil` means "no signal observed", which is
        /// honestly different from "measured silent", and −80 would claim a
        /// measurement that never happened.
        ///
        /// RETAINED ACROSS A STOP, and that is the whole point of the field:
        /// an agent reads this projection BETWEEN actions, i.e. while the
        /// transport is stopped, and the live `trackMeters` are deliberately
        /// zeroed at that moment. The source is
        /// `ProjectStore.lastNonSilentTrackMeters` — see its doc comment.
        public var peakDb: Double?
        /// RMS of that same frame in dBFS — "how loud does this sit in the
        /// mix", where ``peakDb`` is "did it clip". Same floor, same finiteness
        /// guarantee, same present-only-if-ever-heard rule.
        public var rmsDb: Double?
    }

    public var transport: Transport
    public var master: Master
    public var tracks: [Track]
    /// How many session markers exist (m11-c) — a COUNT, not the list (the
    /// overview's count-not-lists rule). Additive; the full id/name/beat set
    /// rides `project.snapshot` and `marker.list`. Zero when there are none.
    public var markerCount: Int
}

extension ProjectStore {
    /// Builds the agent-facing overview projection (M7). Pure read: no
    /// mutation, no engine calls. See `ProjectOverview` for the shape
    /// rationale (counts, not lists; no file paths).
    public func overview() -> ProjectOverview {
        ProjectOverview(
            transport: ProjectOverview.Transport(
                tempoBPM: transport.tempoBPM,
                isPlaying: transport.isPlaying,
                isRecording: transport.isRecording,
                positionBeats: transport.positionBeats,
                loop: ProjectOverview.Loop(
                    enabled: transport.isLoopEnabled,
                    startBeat: transport.loopStartBeat,
                    endBeat: transport.loopEndBeat
                ),
                metronome: ProjectOverview.Metronome(
                    enabled: transport.isMetronomeEnabled,
                    countInBars: transport.countInBars
                ),
                punch: ProjectOverview.Punch(
                    enabled: transport.isPunchEnabled,
                    inBeat: transport.punchInBeat,
                    outBeat: transport.punchOutBeat
                )
            ),
            master: Self.overviewMaster(volume: masterVolume,
                                        heard: lastNonSilentMasterMeter),
            // The retained (stop-surviving) meter, not the live one — see
            // `ProjectOverview.Track.peakDb` for why (m23-cv).
            tracks: tracks.map { Self.overviewTrack($0, heard: lastNonSilentTrackMeters[$0.id]) },
            markerCount: markers.count
        )
    }

    /// - Parameter heard: the MASTER bus's last SIGNAL-carrying meter frame,
    ///   or nil if it has never been heard this session (m23-dm) — the
    ///   RETAINED (stop-surviving) frame, never the live `masterMeter`, for
    ///   the reason spelled out on `ProjectOverview.Master.peakDb`. Passed in
    ///   rather than read here so this stays a pure function of its inputs,
    ///   exactly like `overviewTrack`.
    private static func overviewMaster(volume: Double,
                                       heard: MeterFrame?) -> ProjectOverview.Master {
        ProjectOverview.Master(
            volume: volume,
            // dB via `MeterLevel` — the ONE meter-amplitude → dBFS conversion
            // in the project, the same one the per-track fields use. Both keys
            // are omitted together when the master has never been heard.
            peakDb: heard?.peakDb,
            rmsDb: heard?.rmsDb
        )
    }

    /// - Parameter heard: the track's last SIGNAL-carrying meter frame, or nil
    ///   if it has never been heard this session (m23-cv). Passed in rather
    ///   than read here so this stays a pure function of its inputs.
    private static func overviewTrack(_ track: Track,
                                      heard: MeterFrame?) -> ProjectOverview.Track {
        ProjectOverview.Track(
            id: track.id,
            name: track.name,
            kind: track.kind.rawValue,
            muted: track.isMuted,
            soloed: track.isSoloed,
            armed: track.isArmed,
            volume: track.volume,
            pan: track.pan,
            output: track.outputBusID,
            // Only instrument tracks carry an instrument at all; an
            // unconfigured one still PLAYS `InstrumentDescriptor.default`
            // (the "RESOLVED" house pattern — see `snapshotJSON`'s
            // `instrumentJSON`), so resolve nil to the default rather than
            // reporting a synth track as instrument-less.
            instrument: track.kind == .instrument
                ? overviewInstrumentName(track.instrument ?? .default)
                : nil,
            sends: track.sends.map {
                ProjectOverview.Send(
                    destinationBusID: $0.destinationBusID,
                    level: $0.level,
                    preFader: false
                )
            },
            fx: track.effects.map {
                ProjectOverview.Effect(name: $0.kind.rawValue, bypassed: $0.isBypassed)
            },
            clips: track.clips.map { overviewClip($0, takeGroups: track.takeGroups) },
            automation: track.automation.map {
                ProjectOverview.AutomationLane(
                    target: overviewTargetName($0.target),
                    enabled: $0.isEnabled,
                    pointCount: $0.points.count
                )
            },
            // dB via `MeterLevel` — the ONE meter-amplitude → dBFS conversion
            // in the project. Both keys are omitted together when the track has
            // never been heard.
            peakDb: heard?.peakDb,
            rmsDb: heard?.rmsDb
        )
    }

    /// Display name for a track's instrument: the hosted Audio Unit's own
    /// name when configured, else the built-in kind's raw case name
    /// ("polySynth", "sampler", "testTone").
    private static func overviewInstrumentName(_ descriptor: InstrumentDescriptor) -> String {
        if descriptor.kind == .audioUnit, let name = descriptor.audioUnit?.name, !name.isEmpty {
            return name
        }
        return descriptor.kind.rawValue
    }

    /// Compact string form of an automation target, matching the wire
    /// discriminator vocabulary used by `AutomationTarget`'s own Codable
    /// (`volume`, `pan`, `sendLevel:<id>`, `effectParam:<id>:<param>`) rather
    /// than Swift's debug description.
    private static func overviewTargetName(_ target: AutomationTarget) -> String {
        switch target {
        case .volume: return "volume"
        case .pan: return "pan"
        case .sendLevel(let sendID): return "sendLevel:\(sendID.uuidString)"
        case .effectParam(let effectID, let paramName):
            return "effectParam:\(effectID.uuidString):\(paramName)"
        }
    }

    private static func overviewClip(_ clip: Clip, takeGroups: [TakeGroup]) -> ProjectOverview.Clip {
        let isMIDI = clip.notes != nil
        // "Grouped" facts (M5 iii-a): a materialized clip carries its parent
        // group's id in `takeGroupID`. `takeLaneCount` is the group's lane
        // count; `activeLane` is that lane's index ONLY when every comp
        // segment overlapping this clip's range agrees on a single lane —
        // a clip stitched from more than one lane (a comp join) reports nil
        // rather than guess.
        var takeLaneCount: Int?
        var activeLane: Int?
        if let groupID = clip.takeGroupID,
           let group = takeGroups.first(where: { $0.id == groupID }) {
            takeLaneCount = group.lanes.count
            let clipEnd = clip.startBeat + clip.lengthBeats
            let overlappingLaneIDs = Set(group.comp
                .filter { $0.startBeat < clipEnd && $0.endBeat > clip.startBeat }
                .map(\.laneID))
            if overlappingLaneIDs.count == 1, let laneID = overlappingLaneIDs.first,
               let index = group.lanes.firstIndex(where: { $0.id == laneID }) {
                activeLane = index
            }
        }
        return ProjectOverview.Clip(
            id: clip.id,
            name: clip.name,
            startBeat: clip.startBeat,
            lengthBeats: clip.lengthBeats,
            kind: isMIDI ? "midi" : "audio",
            noteCount: isMIDI ? clip.notes?.count : nil,
            takeLaneCount: takeLaneCount,
            activeLane: activeLane,
            hasStretch: isMIDI ? nil : !clip.isStretchIdentity,
            hasFades: isMIDI ? nil : (clip.fadeInBeats > 0 || clip.fadeOutBeats > 0),
            gainDb: (!isMIDI && clip.gainDb != 0) ? clip.gainDb : nil
        )
    }
}
