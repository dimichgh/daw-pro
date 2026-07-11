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
    }

    public var transport: Transport
    public var master: Master
    public var tracks: [Track]
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
            master: ProjectOverview.Master(volume: masterVolume),
            tracks: tracks.map(Self.overviewTrack)
        )
    }

    private static func overviewTrack(_ track: Track) -> ProjectOverview.Track {
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
            }
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
