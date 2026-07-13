// CopilotCatalog.swift
// DAWControl
//
// The catalog of control-protocol commands exposed to the in-app AI Copilot
// (M6 rail-c; see docs/research/design-rail-a-copilot.md §3/§7). Each
// `CopilotTool` mirrors exactly one command from `Commands.swift` /
// `CommandRouter.allCommands`, translated into an AI-tool-safe name plus a
// JSON Schema written for a musician-facing AI: musical meaning, units, and
// ranges are spelled out in descriptions. Schemas and descriptions are
// transliterated from the matching tool in mcp-server/src/index.ts (the only
// other JSON-schema source in the repo), tightened to ~1-2 sentences.
//
// Wire-name <-> tool-name mapping: control-protocol commands are dotted
// ("track.setVolume"); Anthropic/OpenAI tool-use APIs forbid dots in tool
// names, so the Copilot-facing name substitutes underscores for dots
// ("track_setVolume"). The mapping is lossless and reversible because no
// control-protocol command name contains an underscore (asserted by
// CopilotCatalogTests). NOTE: these tool names intentionally differ from
// mcp-server's snake_case names ("track_add_send") — the copilot never talks
// to the MCP server, so no naming parity is required; only catalog<->
// CommandRouter.allCommands parity matters (also asserted by test).

import AIServices
import Foundation

/// One catalog entry: a control-protocol command exposed to the Copilot.
public struct CopilotTool: Sendable {
    /// Canonical control-protocol command name, e.g. "clip.addMIDI".
    public var command: String
    /// AI-facing description of what the command does, in musical terms.
    public var description: String
    /// JSON Schema (as a `JSONValue` object) describing the command's params.
    public var schema: JSONValue

    public init(command: String, description: String, schema: JSONValue) {
        self.command = command
        self.description = description
        self.schema = schema
    }

    /// Derives the wire `CopilotToolSpec` the AIServices provider seam
    /// actually sends: the tool-safe name, description, and `schema`
    /// pre-encoded to JSON `Data` (AIServices cannot see `JSONValue`).
    public func spec() -> CopilotToolSpec {
        let data = (try? JSONEncoder().encode(schema)) ?? Data()
        return CopilotToolSpec(
            name: CopilotTool.toolName(fromCommand: command),
            description: description,
            inputSchemaJSON: data
        )
    }

    /// "track.setVolume" -> "track_setVolume".
    public static func toolName(fromCommand command: String) -> String {
        command.replacingOccurrences(of: ".", with: "_")
    }

    /// "track_setVolume" -> "track.setVolume". The inverse of
    /// `toolName(fromCommand:)`; unambiguous because no control-protocol
    /// command name contains an underscore.
    public static func command(fromToolName toolName: String) -> String {
        toolName.replacingOccurrences(of: "_", with: ".")
    }
}

// MARK: - JSON Schema builders

/// `{"type": "object", "properties": {...}, "required": [...]}` — every
/// catalog schema is one of these at the top level (exhaustiveness test (e)).
private func schemaObject(_ properties: [(String, JSONValue)], required: [String] = []) -> JSONValue {
    var props: [String: JSONValue] = [:]
    for (key, value) in properties { props[key] = value }
    var object: [String: JSONValue] = [
        "type": .string("object"),
        "properties": .object(props),
    ]
    if !required.isEmpty {
        object["required"] = .array(required.map(JSONValue.string))
    }
    return .object(object)
}

private func stringSchema(_ description: String, enumValues: [String]? = nil) -> JSONValue {
    var object: [String: JSONValue] = [
        "type": .string("string"),
        "description": .string(description),
    ]
    if let enumValues {
        object["enum"] = .array(enumValues.map(JSONValue.string))
    }
    return .object(object)
}

private func numberSchema(_ description: String, minimum: Double? = nil, maximum: Double? = nil) -> JSONValue {
    var object: [String: JSONValue] = [
        "type": .string("number"),
        "description": .string(description),
    ]
    if let minimum { object["minimum"] = .number(minimum) }
    if let maximum { object["maximum"] = .number(maximum) }
    return .object(object)
}

private func integerSchema(_ description: String, minimum: Double? = nil, maximum: Double? = nil) -> JSONValue {
    var object: [String: JSONValue] = [
        "type": .string("integer"),
        "description": .string(description),
    ]
    if let minimum { object["minimum"] = .number(minimum) }
    if let maximum { object["maximum"] = .number(maximum) }
    return .object(object)
}

private func booleanSchema(_ description: String) -> JSONValue {
    .object(["type": .string("boolean"), "description": .string(description)])
}

private func arraySchema(_ description: String, items: JSONValue) -> JSONValue {
    .object([
        "type": .string("array"),
        "description": .string(description),
        "items": items,
    ])
}

/// Shared by clip.addMIDI/clip.setNotes — one MIDI note. Mirrors
/// mcp-server's `noteSchema` (index.ts): `pitch`/`startBeat` required,
/// `velocity`/`lengthBeats` optional with the store's own defaults
/// (100, 1 beat). `id` is deliberately omitted here — the copilot always
/// writes fresh notes; resubmitting an existing note's id is an mcp-server
/// affordance the catalog doesn't need.
private let noteItemSchema: JSONValue = schemaObject([
    ("pitch", integerSchema(
        "MIDI pitch number, 0-127 (60 = middle C, 69 = A4/440Hz).",
        minimum: 0, maximum: 127)),
    ("velocity", integerSchema(
        "Note-on velocity (loudness/intensity), 1-127. Defaults to 100 if omitted.",
        minimum: 1, maximum: 127)),
    ("startBeat", numberSchema(
        "Note start position in beats (quarter notes), RELATIVE TO THE CLIP'S START "
        + "(not the timeline). Must be >= 0.",
        minimum: 0)),
    ("lengthBeats", numberSchema(
        "Note duration in beats. Must be > 0. Defaults to 1 beat if omitted.",
        minimum: 0)),
], required: ["pitch", "startBeat"])

/// Commands that must never be exposed to the Copilot, even though they are
/// valid control-protocol commands — asserted disjoint from `v1` by test so
/// future catalog growth cannot re-add them. These are either destructive/
/// irreversible (project.new, project.open, track.remove), a persistence
/// side-effect that should stay under explicit user control (project.save —
/// the copilot proposes, the human clicks), or the Copilot's own plumbing
/// commands, which would let the model recursively drive itself.
public enum CopilotToolCatalog {
    public static let neverInclude: Set<String> = [
        "project.new",
        "project.open",
        "project.save",
        "track.remove",
        "ai.copilotSend",
        "ai.copilotState",
        "ai.copilotReset",
    ]

    /// The versioned catalog of commands exposed to the Copilot. `v1` is the
    /// curated allow-list (design §3), now 55 commands: transport (6),
    /// tempo (2, m12-d), marker (5, m11-c), track (7), clip (14, m15-d added
    /// duplicate), arrange (2, m15-d), take (2), mixer (1), fx (5, m13-d master
    /// chain), render (2), ai (6), discovery (2), edit (1).
    public static let v1: [CopilotTool] = [
        // MARK: transport (6)

        CopilotTool(
            command: "transport.play",
            description: "Start playback from the current transport position. No effect if already playing.",
            schema: schemaObject([])
        ),
        CopilotTool(
            command: "transport.stop",
            description: "Stop playback; the playhead stays where it is (use transport.seek to move it).",
            schema: schemaObject([])
        ),
        CopilotTool(
            command: "transport.seek",
            description: "Move the playhead to an absolute position in beats (quarter notes) from the start of the timeline, OR to a named session marker. Pass `beats` for an absolute jump, or `marker` (a marker's id or exact name from marker_list) to jump to that section — e.g. \"go to the second chorus\": marker_list, then seek with that marker. Pass exactly one of the two.",
            schema: schemaObject([
                ("beats", numberSchema(
                    "Absolute position in beats (quarter notes) from timeline start. Must be >= 0. Omit when passing `marker`.",
                    minimum: 0)),
                ("marker", stringSchema(
                    "A session marker's id or exact name (from marker_list) to seek to. Omit when passing `beats`; passing both is rejected.")),
            ])
        ),
        CopilotTool(
            command: "transport.setTempo",
            description: "Set the project tempo in BPM (beats per minute). Typical music ranges roughly 60-200 BPM.",
            schema: schemaObject([
                ("bpm", numberSchema("Tempo in beats per minute. Range 20-400.", minimum: 20, maximum: 400)),
            ], required: ["bpm"])
        ),
        CopilotTool(
            command: "transport.setLoop",
            description: "Enable or disable loop playback between startBeat and endBeat; when enabled, the playhead wraps from the loop end back to the loop start.",
            schema: schemaObject([
                ("enabled", booleanSchema("True to enable loop playback, false to disable it.")),
                ("startBeat", numberSchema(
                    "Loop start position in beats. Must be >= 0. Omit to keep the current loop start.",
                    minimum: 0)),
                ("endBeat", numberSchema(
                    "Loop end position in beats. Must be greater than startBeat. Omit to keep the current loop end.")),
            ], required: ["enabled"])
        ),
        CopilotTool(
            command: "transport.setMetronome",
            description: "Enable or disable the metronome click; countInBars sets how many bars of count-in click play before recording starts.",
            schema: schemaObject([
                ("enabled", booleanSchema("True to enable the metronome click, false to disable it.")),
                ("countInBars", integerSchema(
                    "Number of bars of count-in clicks before recording starts, 0-4. Omit to keep the current value.",
                    minimum: 0, maximum: 4)),
            ], required: ["enabled"])
        ),

        // MARK: tempo (2, m12-d)

        CopilotTool(
            command: "tempo.map",
            description: "Read the project's tempo map and time-signature (meter) map: {segments: [{startBeat, bpm}], meterChanges: [{startBeat, beatsPerBar, beatUnit}], mapRevision}. There is always at least one segment (the base tempo at beat 0) and one meter change, even for a single-tempo song. Use this before tempo.setMap to see the current shape, and to place tempo changes at section boundaries (marker.list gives the beats).",
            schema: schemaObject([])
        ),
        CopilotTool(
            command: "tempo.setMap",
            description: "Replace the whole project tempo map (and optionally the meter map) — how you author tempo changes across a song (e.g. a slower intro, a faster drop). Pass the FULL list of segments, each a constant tempo starting at a beat; segment 0 MUST start at beat 0 and sets the base tempo. beats must be sorted and unique. Beats are the source of truth: notes and clips keep their beat positions, only their wall-clock timing changes. To set one project-wide tempo use transport.setTempo instead. One undoable step (edit.undo). Returns the resolved maps.",
            schema: schemaObject([
                ("segments", arraySchema(
                    "Ordered tempo segments. Segment 0 must have startBeat 0. Each segment's tempo governs from its startBeat until the next segment's startBeat.",
                    items: schemaObject([
                        ("startBeat", numberSchema("Beat (quarter notes from timeline start) where this tempo begins. Segment 0 must be 0; later segments strictly increasing.", minimum: 0)),
                        ("bpm", numberSchema("Tempo in beats per minute for this segment. Range 20-400.", minimum: 20, maximum: 400)),
                    ], required: ["startBeat", "bpm"]))),
                ("meterChanges", arraySchema(
                    "Optional time-signature changes. Omit to leave the current meter unchanged. Change 0 must have startBeat 0; each later change must fall on a barline of the meter before it.",
                    items: schemaObject([
                        ("startBeat", numberSchema("Beat where this time signature begins. Change 0 must be 0.", minimum: 0)),
                        ("beatsPerBar", integerSchema("Beats per bar (the top number, e.g. 3 for 3/4).", minimum: 1)),
                        ("beatUnit", integerSchema("Beat unit (the bottom number, e.g. 4 for 3/4).", minimum: 1)),
                    ], required: ["startBeat", "beatsPerBar", "beatUnit"]))),
            ], required: ["segments"])
        ),

        // MARK: marker (5)

        CopilotTool(
            command: "marker.add",
            description: "Add a named song-section marker at a beat, so you (and the musician) can jump there later with transport.seek. Use it to anchor sections like \"Verse 1\", \"Chorus\", \"Drop\". Reversible with edit.undo. Returns the created marker {id, name, beat}.",
            schema: schemaObject([
                ("name", stringSchema("Marker name, e.g. \"Chorus\". Omit for an auto name like \"Marker 3\".")),
                ("beat", numberSchema("Absolute timeline beat (quarter notes) to place the marker. Must be >= 0.", minimum: 0)),
            ], required: ["beat"])
        ),
        CopilotTool(
            command: "marker.remove",
            description: "Remove a session marker by id. Markers are lightweight anchors — this only deletes the marker, never any audio or notes. Reversible with edit.undo. Returns {removed: true}.",
            schema: schemaObject([
                ("markerId", stringSchema("Id of the marker to remove, from marker.list / project.snapshot.")),
            ], required: ["markerId"])
        ),
        CopilotTool(
            command: "marker.rename",
            description: "Rename an existing session marker. An empty or unchanged name is a no-op (no undo step). Reversible with edit.undo. Returns the updated marker.",
            schema: schemaObject([
                ("markerId", stringSchema("Id of the marker to rename, from marker.list / project.snapshot.")),
                ("name", stringSchema("New marker name (non-empty).")),
            ], required: ["markerId", "name"])
        ),
        CopilotTool(
            command: "marker.move",
            description: "Move a session marker to a new beat (a live scrub coalesces into one undo step). Reversible with edit.undo. Returns the moved marker.",
            schema: schemaObject([
                ("markerId", stringSchema("Id of the marker to move, from marker.list / project.snapshot.")),
                ("beat", numberSchema("New absolute timeline beat (quarter notes). Clamped to >= 0.", minimum: 0)),
            ], required: ["markerId", "beat"])
        ),
        CopilotTool(
            command: "marker.list",
            description: "List every session marker, sorted by beat — {markers: [{id, name, beat}]}. Use it to find a section's beat before transport.seek (e.g. \"drop at the second chorus\": list markers, pick the right one, seek to it).",
            schema: schemaObject([])
        ),

        // MARK: track (7)

        CopilotTool(
            command: "track.add",
            description: "Add a new track to the project. kind is \"audio\" (records/plays audio clips), \"instrument\" (hosts a virtual instrument for MIDI clips), or \"bus\" (a submix destination other tracks route into); defaults to \"audio\".",
            schema: schemaObject([
                ("name", stringSchema("Display name for the new track, e.g. \"Lead Vocal\".")),
                ("kind", stringSchema(
                    "Track type: audio, instrument, or bus. Defaults to audio.",
                    enumValues: ["audio", "instrument", "bus"])),
            ], required: ["name"])
        ),
        CopilotTool(
            command: "track.rename",
            description: "Rename an existing track.",
            schema: schemaObject([
                ("trackId", stringSchema("Id of the track to rename, from project.snapshot.")),
                ("name", stringSchema("New display name for the track.")),
            ], required: ["trackId", "name"])
        ),
        CopilotTool(
            command: "track.setVolume",
            description: "Set a track's fader volume as a linear gain multiplier, where 1.0 is unity gain (0 dB). 0.5 is roughly -6 dB, 2.0 is roughly +6 dB.",
            schema: schemaObject([
                ("trackId", stringSchema("Id of the track, from project.snapshot.")),
                ("volume", numberSchema(
                    "Linear gain, 0-2, where 1 = unity gain (0 dB). This is linear gain, not decibels.",
                    minimum: 0, maximum: 2)),
            ], required: ["trackId", "volume"])
        ),
        CopilotTool(
            command: "track.setPan",
            description: "Set a track's stereo pan position: -1 is hard left, 0 is centered, 1 is hard right.",
            schema: schemaObject([
                ("trackId", stringSchema("Id of the track, from project.snapshot.")),
                ("pan", numberSchema("Pan position, -1 (hard left) to 1 (hard right), 0 = center.", minimum: -1, maximum: 1)),
            ], required: ["trackId", "pan"])
        ),
        CopilotTool(
            command: "track.setMute",
            description: "Mute (silence) or unmute a track's output without changing its volume/pan.",
            schema: schemaObject([
                ("trackId", stringSchema("Id of the track, from project.snapshot.")),
                ("muted", booleanSchema("True to mute the track, false to unmute it.")),
            ], required: ["trackId", "muted"])
        ),
        CopilotTool(
            command: "track.setSolo",
            description: "Solo or unsolo a track. When any track is soloed, only soloed tracks are audible.",
            schema: schemaObject([
                ("trackId", stringSchema("Id of the track, from project.snapshot.")),
                ("soloed", booleanSchema("True to solo the track, false to unsolo it.")),
            ], required: ["trackId", "soloed"])
        ),
        CopilotTool(
            command: "track.setInstrument",
            description: "Select or tweak the instrument on an instrument track — this is what makes its MIDI clips audible. kind picks the instrument; omitted fields keep their current value. (Sampler/Audio-Unit configuration is not available through the copilot — use the app UI for those.)",
            schema: schemaObject([
                ("trackId", stringSchema("Id of the instrument track, from project.snapshot.")),
                ("kind", stringSchema(
                    "Which instrument to use. Omit to keep the current instrument.",
                    enumValues: ["testTone", "polySynth", "audioUnit"])),
                ("waveform", stringSchema(
                    "polySynth oscillator waveform: saw (bright/buzzy), square (hollow), triangle (mellow), sine (pure/soft). Omit to keep the current value.",
                    enumValues: ["saw", "square", "triangle", "sine"])),
                ("attack", numberSchema("polySynth envelope attack time in seconds (time to reach full volume). Clamped to 0.0005-5.")),
                ("decay", numberSchema("polySynth envelope decay time in seconds (time to fall from peak to sustain level). Clamped to 0.001-5.")),
                ("sustain", numberSchema(
                    "polySynth envelope sustain LEVEL (not a time), 0-1 — the volume held while a note stays down.",
                    minimum: 0, maximum: 1)),
                ("release", numberSchema("polySynth envelope release time in seconds (time to fade to silence after note-off). Clamped to 0.001-8.")),
                ("cutoffHz", numberSchema(
                    "polySynth low-pass filter cutoff in Hz — lower is darker/muffled, higher is brighter/more open.",
                    minimum: 40, maximum: 18000)),
                ("resonance", numberSchema(
                    "polySynth filter resonance, 0-1 — emphasis right at the cutoff frequency.",
                    minimum: 0, maximum: 1)),
                ("gain", numberSchema(
                    "Instrument's own output level, 0-1, separate from the track fader (track.setVolume).",
                    minimum: 0, maximum: 1)),
            ], required: ["trackId"])
        ),

        // MARK: clip (12)

        CopilotTool(
            command: "clip.addAudio",
            description: "Import an audio file (wav, aiff, mp3, or m4a) as a new clip on an audio track; the clip's length is computed automatically from the file's duration at the current tempo.",
            schema: schemaObject([
                ("trackId", stringSchema("Id of the audio track to add the clip to, from project.snapshot.")),
                ("path", stringSchema("Absolute path to an audio file on this Mac (wav, aiff, mp3, or m4a).")),
                ("atBeat", numberSchema(
                    "Timeline position in beats to place the clip's start. Must be >= 0. Omit to append after the track's existing clips.",
                    minimum: 0)),
            ], required: ["trackId", "path"])
        ),
        CopilotTool(
            command: "clip.addMIDI",
            description: "Create a MIDI clip on an instrument track and optionally write its notes in one call — the way to compose a melody, riff, or chord progression at once.",
            schema: schemaObject([
                ("trackId", stringSchema("Id of the instrument track to add the clip to, from project.snapshot.")),
                ("name", stringSchema("Display name for the clip. Defaults to a generic name.")),
                ("atBeat", numberSchema(
                    "Timeline position in beats to place the clip's start. Must be >= 0. Omit to append after the track's existing clips.",
                    minimum: 0)),
                ("lengthBeats", numberSchema(
                    "Clip length in beats. Must be > 0. Omit to default to fit the notes.",
                    minimum: 0)),
                ("notes", arraySchema(
                    "Notes to write into the clip, up to 4096. Each note's startBeat is relative to the clip's own start. Omit (or pass an empty array) for an empty clip.",
                    items: noteItemSchema)),
            ], required: ["trackId"])
        ),
        CopilotTool(
            command: "clip.setNotes",
            description: "Replace a MIDI clip's ENTIRE note array — the only note-editing primitive. Pass an empty array to clear the clip.",
            schema: schemaObject([
                ("clipId", stringSchema("Id of the MIDI clip to edit, from project.snapshot.")),
                ("notes", arraySchema(
                    "The clip's complete new note array (replaces all existing notes), up to 4096 entries.",
                    items: noteItemSchema)),
            ], required: ["clipId", "notes"])
        ),
        CopilotTool(
            command: "clip.move",
            description: "Slide a clip to a new timeline start beat without changing its length or content (same-track only).",
            schema: schemaObject([
                ("trackId", stringSchema("Id of the track that owns the clip, from project.snapshot.")),
                ("clipId", stringSchema("Id of the clip to move, from project.snapshot.")),
                ("toStartBeat", numberSchema("New timeline start in beats. Clamped to >= 0.")),
            ], required: ["trackId", "clipId", "toStartBeat"])
        ),
        CopilotTool(
            command: "clip.duplicate",
            description: "Copy a clip — audio or MIDI — to a new spot, keeping everything about it (its notes or audio, gain, fades, gain envelope, stretch). Omit toStartBeat to drop the copy flush after the source clip (the fast way to repeat a riff or loop a bar); omit toTrackId to copy on the same track, or pass another track's id to copy across (a MIDI clip needs an instrument track, an audio clip an audio track). If the copy lands over existing clips it trims them (no silent overlap). Reversible with edit.undo. Returns the new clip.",
            schema: schemaObject([
                ("clipId", stringSchema("Id of the clip to duplicate, from project.snapshot.")),
                ("toStartBeat", numberSchema(
                    "Timeline start beat for the copy. Must be >= 0. Omit to append flush after the source clip's end.",
                    minimum: 0)),
                ("toTrackId", stringSchema(
                    "Id of the track to copy onto. Omit to copy on the source's own track. Must match the clip's kind (instrument track for MIDI, audio track for audio).")),
            ], required: ["clipId"])
        ),
        CopilotTool(
            command: "clip.trim",
            description: "Change a clip's visible timeline window (start + length) while its underlying content stays fixed — drag either edge without moving the clip's content.",
            schema: schemaObject([
                ("trackId", stringSchema("Id of the track that owns the clip, from project.snapshot.")),
                ("clipId", stringSchema("Id of the clip to trim, from project.snapshot.")),
                ("newStartBeat", numberSchema("New timeline start in beats. Clamped to >= 0.")),
                ("newLengthBeats", numberSchema("New clip length in beats. Clamped to a minimum of 1/32 beat.")),
            ], required: ["trackId", "clipId", "newStartBeat", "newLengthBeats"])
        ),
        CopilotTool(
            command: "clip.split",
            description: "Cut a clip into two independent clips at a timeline beat that must fall STRICTLY inside the clip; the left half keeps the original clip's id.",
            schema: schemaObject([
                ("trackId", stringSchema("Id of the track that owns the clip, from project.snapshot.")),
                ("clipId", stringSchema("Id of the clip to split, from project.snapshot.")),
                ("atBeat", numberSchema("Timeline beat to split at. Must fall strictly inside the clip.")),
            ], required: ["trackId", "clipId", "atBeat"])
        ),
        CopilotTool(
            command: "clip.remove",
            description: "Permanently remove a clip — audio or MIDI — from its track. Reversible with edit.undo.",
            schema: schemaObject([
                ("clipId", stringSchema("Id of the clip to remove, from project.snapshot.")),
            ], required: ["clipId"])
        ),
        CopilotTool(
            command: "clip.setGain",
            description: "Set a clip's own gain trim in decibels, applied on top of its track's fader — use to balance one clip against its neighbors without touching the track volume.",
            schema: schemaObject([
                ("trackId", stringSchema("Id of the track that owns the clip, from project.snapshot.")),
                ("clipId", stringSchema("Id of the clip to adjust, from project.snapshot.")),
                ("gainDb", numberSchema(
                    "Clip gain in decibels. Clamped to -72..24; 0 = unity (no change).",
                    minimum: -72, maximum: 24)),
            ], required: ["trackId", "clipId", "gainDb"])
        ),
        CopilotTool(
            command: "clip.setGainEnvelope",
            description: "Draw a per-clip gain ENVELOPE — a curve of volume breakpoints along an AUDIO clip that fades and swells its level over time, on top of its fixed gain and fades. Reach for this (not clip.setGain, which is one flat number) to ride a vocal louder in the chorus, duck a phrase, or shape a build; use a track automation lane instead when the moves should follow the clip as you rearrange the whole track. Points are clip-relative beats in decibels, interpolated straight-line between them and held flat before the first / after the last. Pass an empty list (or omit points) to clear it. Audio clips only.",
            schema: schemaObject([
                ("trackId", stringSchema("Id of the track that owns the clip, from project.snapshot.")),
                ("clipId", stringSchema("Id of the AUDIO clip to shape, from project.snapshot.")),
                ("points", arraySchema(
                    "Gain breakpoints, sorted by beat ascending with no duplicate beats. Empty (or omitted) CLEARS the envelope.",
                    items: schemaObject([
                        ("beat", numberSchema(
                            "Breakpoint position in beats, RELATIVE TO THE CLIP'S START (not the timeline). Clamped into 0..the clip's length.",
                            minimum: 0)),
                        ("gainDb", numberSchema(
                            "Gain at this breakpoint in decibels. Clamped to -72..24; 0 = unity.",
                            minimum: -72, maximum: 24)),
                    ], required: ["beat", "gainDb"]))),
            ], required: ["trackId", "clipId"])
        ),
        CopilotTool(
            command: "clip.setControllerLane",
            description: "Add MIDI controller moves — mod wheel, sustain pedal, pitch bend, expression, channel pressure — to a MIDI clip's performance, on top of its notes. Creates or REPLACES the clip's lane of one controller type wholesale. Points are STEPWISE: each value holds until the next point, so two points make a STEP, not a ramp — a ramp is a dense run of points. Values are RAW MIDI: pitchBend is 0-16383 (8192 = center, ±2 semitones on built-in instruments); everything else is 0-127 (CC 64 >= 64 = sustain pedal down). Built-in instruments honor pitch bend and sustain (CC 64); every other CC affects Audio Unit instruments only. Controller values chase at play/seek (a value set earlier keeps its effect). quantize/humanize/groove move only NOTES, never these lanes. Per-note (poly) aftertouch is not supported yet. MIDI clips only.",
            schema: schemaObject([
                ("clipId", stringSchema("Id of the MIDI clip to edit, from project.snapshot.")),
                ("type", stringSchema(
                    "Which controller stream this lane carries.",
                    enumValues: ["cc", "pitchBend", "channelPressure"])),
                ("controller", integerSchema(
                    "The CC number 0-127, REQUIRED when type is \"cc\" (1 = mod wheel, 7 = volume, 10 = pan, 11 = expression, 64 = sustain). Ignored for pitchBend / channelPressure.",
                    minimum: 0, maximum: 127)),
                ("points", arraySchema(
                    "The lane's complete new point list (replaces this type's existing lane), non-empty, up to 16384 entries. To DELETE a lane use clip.removeControllerLane.",
                    items: schemaObject([
                        ("beat", numberSchema(
                            "Point position in beats, RELATIVE TO THE CLIP'S START (not the timeline). Clamped to >= 0.",
                            minimum: 0)),
                        ("value", integerSchema(
                            "Raw MIDI value at this point. 0-16383 for pitchBend (8192 = center); 0-127 for cc / channelPressure.",
                            minimum: 0, maximum: 16383)),
                    ], required: ["beat", "value"]))),
            ], required: ["clipId", "type", "points"])
        ),
        CopilotTool(
            command: "clip.crossfade",
            description: "Crossfade two ADJACENT (or already-overlapping) audio clips on one track: creates a sanctioned overlap of the given beats with complementary equal-power fades so one clip fades out as the next fades in, with no click or volume bump. Pass the two clip ids in any order.",
            schema: schemaObject([
                ("trackId", stringSchema("Id of the track that owns both clips, from project.snapshot.")),
                ("clipId", stringSchema("Id of one of the two audio clips to crossfade.")),
                ("otherClipId", stringSchema("Id of the other audio clip — must be adjacent to or overlapping the first, on the same track.")),
                ("lengthBeats", numberSchema("Crossfade length in beats. Must be > 0. The clips must be adjacent, or already overlap by no more than this.")),
            ], required: ["trackId", "clipId", "otherClipId", "lengthBeats"])
        ),
        CopilotTool(
            command: "clip.stretchToLength",
            description: "Time-stretch an AUDIO clip so it fills a new timeline length in beats while reading the same source material (the drag-the-stretch-handle move). Audio clips only.",
            schema: schemaObject([
                ("trackId", stringSchema("Id of the track that owns the clip, from project.snapshot.")),
                ("clipId", stringSchema("Id of the AUDIO clip to stretch, from project.snapshot.")),
                ("lengthBeats", numberSchema("New timeline length in beats. The clip's stretch ratio scales to match so it reads the same source window.")),
            ], required: ["trackId", "clipId", "lengthBeats"])
        ),
        CopilotTool(
            command: "clip.deleteTimeRange",
            description: "Cut a beat range out of a MIDI clip and close the gap (the 'delete a bar' edit): notes after the range move earlier, notes starting inside it are removed, and a note held from before keeps its head. Beats are CLIP-LOCAL (same as clip.setNotes). MIDI clips only.",
            schema: schemaObject([
                ("clipId", stringSchema("Id of the MIDI clip to edit, from project.snapshot.")),
                ("startBeat", numberSchema("Clip-local beat where the excised range begins. Must be within the clip.")),
                ("lengthBeats", numberSchema("How many beats to remove. To delete one bar, pass the project's beats-per-bar.")),
            ], required: ["clipId", "startBeat", "lengthBeats"])
        ),
        CopilotTool(
            command: "clip.insertTimeRange",
            description: "Insert empty beats into a MIDI clip and push later notes right (the 'insert a bar' edit): notes at or after the insert point move later; a note held across it keeps sounding. Beats are CLIP-LOCAL (same as clip.setNotes). MIDI clips only.",
            schema: schemaObject([
                ("clipId", stringSchema("Id of the MIDI clip to edit, from project.snapshot.")),
                ("atBeat", numberSchema("Clip-local beat where the silence is inserted. 0 to the clip's length.")),
                ("lengthBeats", numberSchema("How many empty beats to insert. To insert one bar, pass the project's beats-per-bar.")),
            ], required: ["clipId", "atBeat", "lengthBeats"])
        ),

        // MARK: arrange (2, m15-d)

        CopilotTool(
            command: "arrange.insertBars",
            description: "Insert empty bars across the WHOLE arrangement and push everything after them later, in one undoable step — the way to open up space (e.g. \"add 4 bars before the chorus for a build\"). Bars are 1-based (bar 1 is the first bar) and meter-aware (a bar in a 6/8 section is 6 beats). Every track's clips, the markers, the tempo and time-signature maps, and the loop all shift together; a clip straddling the insertion point is split. Use marker.list / tempo.map to find the bar of a section first. Returns {atBeat, insertedBeats, beatsPerBar}.",
            schema: schemaObject([
                ("atBar", integerSchema(
                    "1-based bar number to insert BEFORE (bar 1 = the first bar). The empty bars appear here and everything from this bar onward moves later.",
                    minimum: 1)),
                ("count", integerSchema("How many empty bars to insert.", minimum: 1)),
            ], required: ["atBar", "count"])
        ),
        CopilotTool(
            command: "arrange.deleteBars",
            description: "Delete a range of bars across the WHOLE arrangement and pull everything after them earlier, in one undoable step — the way to cut a section out (e.g. \"drop the 4-bar intro\"). Bars are 1-based and meter-aware. Clips fully inside the range are removed, ones straddling an edge are trimmed or split, markers inside are removed, and the tempo/meter maps close the gap. A delete that would leave a time-signature change off its barline is refused with a teaching error — delete within one meter region. Returns {fromBeat, deletedBeats, removedClipIds, removedMarkerIds}.",
            schema: schemaObject([
                ("fromBar", integerSchema(
                    "1-based bar number where the deletion starts (bar 1 = the first bar).",
                    minimum: 1)),
                ("count", integerSchema("How many bars to delete.", minimum: 1)),
            ], required: ["fromBar", "count"])
        ),

        // MARK: take (2)

        CopilotTool(
            command: "take.select",
            description: "Sugar for picking one take across a whole take group's range: sets the comp to a single full-range segment on laneId.",
            schema: schemaObject([
                ("trackId", stringSchema("Id of the track that owns the group, from project.snapshot.")),
                ("groupId", stringSchema("Id of the take group.")),
                ("laneId", stringSchema("Id of the lane (take) to select for the whole group range.")),
            ], required: ["trackId", "groupId", "laneId"])
        ),
        CopilotTool(
            command: "take.flatten",
            description: "Dissolve a take group: its currently-comped members stay as ordinary, fully editable clips. Reversible with edit.undo.",
            schema: schemaObject([
                ("trackId", stringSchema("Id of the track that owns the group, from project.snapshot.")),
                ("groupId", stringSchema("Id of the take group to dissolve.")),
            ], required: ["trackId", "groupId"])
        ),

        // MARK: mixer (1)

        CopilotTool(
            command: "mixer.setMasterVolume",
            description: "Set the master output gain of the whole mix as a linear gain multiplier, where 1.0 is unity gain (0 dB).",
            schema: schemaObject([
                ("volume", numberSchema(
                    "Linear master gain, 0-2, where 1 = unity gain (0 dB). This is linear gain, not decibels.",
                    minimum: 0, maximum: 2)),
            ], required: ["volume"])
        ),

        // MARK: fx (5, m13-d)

        CopilotTool(
            command: "fx.add",
            description: "Add a built-in effect to a track, a bus, OR the master output's insert chain. Pass trackId as a track/bus id from project.snapshot to insert on that strip, or the EXACT string \"master\" to insert on the master output chain — the whole mix's final stage, after the master fader, the last stop before the speakers. Effects process in array order (index 0 first); omit index to append at the end. The master chain hosts BUILT-IN effects only in v1 (no hosted plugins there). The go-to mastering recipe: add an eq then a limiter to \"master\", set the limiter's ceilingDb near -1, then call render.measureLoudness to check the level (aim for -14 LUFS for streaming). Adding an effect never interrupts playback. Returns {effectId, effects}. Reversible with edit.undo.",
            schema: schemaObject([
                ("trackId", stringSchema("Id of the track or bus to add the effect to, OR the string \"master\" for the master output chain.")),
                ("kind", stringSchema(
                    "Which built-in effect to add. On the master chain only these built-ins are allowed.",
                    enumValues: ["gain", "eq", "compressor", "limiter", "reverb", "delay", "saturator", "gate", "chorus"])),
                ("index", integerSchema("Position in the chain, 0 = processed first. Omit to append at the end; out-of-range values clamp.", minimum: 0)),
            ], required: ["trackId", "kind"])
        ),
        CopilotTool(
            command: "fx.remove",
            description: "Remove an effect from a track, a bus, or the master output chain by id, shifting later effects up. Pass trackId as a track/bus id from project.snapshot, or the string \"master\" for the master output chain. Never interrupts playback. Returns the updated insert chain. Reversible with edit.undo.",
            schema: schemaObject([
                ("trackId", stringSchema("Id of the track or bus that owns the effect, OR the string \"master\" for the master output chain.")),
                ("effectId", stringSchema("Id of the effect to remove, from fx.add's result or project.snapshot.")),
            ], required: ["trackId", "effectId"])
        ),
        CopilotTool(
            command: "fx.setParam",
            description: "Change one named parameter of an effect on a track, a bus, or the master output chain — the way to ride an FX knob (e.g. a limiter's ceilingDb, a compressor's ratio, an eq band's gain). Pass trackId as a track/bus id from project.snapshot, or the string \"master\" for the master output chain. Call fx.describe first to see each kind's exact parameter names, ranges, defaults, and units. Out-of-range values clamp. Applies live without interrupting playback. Returns the updated insert chain.",
            schema: schemaObject([
                ("trackId", stringSchema("Id of the track or bus that owns the effect, OR the string \"master\" for the master output chain.")),
                ("effectId", stringSchema("Id of the effect to change, from fx.add's result or project.snapshot.")),
                ("name", stringSchema("Parameter name, exactly as listed by fx.describe for this effect's kind.")),
                ("value", numberSchema("New parameter value; out-of-range values clamp to the parameter's range (see fx.describe).")),
            ], required: ["trackId", "effectId", "name", "value"])
        ),
        CopilotTool(
            command: "fx.setBypass",
            description: "Bypass (temporarily disable, passing audio through unprocessed) or re-enable an effect on a track, a bus, or the master output chain — keeps its parameters, so use it to A/B the effect's contribution. Pass trackId as a track/bus id from project.snapshot, or the string \"master\" for the master output chain. Takes effect instantly without interrupting playback. Returns the updated insert chain.",
            schema: schemaObject([
                ("trackId", stringSchema("Id of the track or bus that owns the effect, OR the string \"master\" for the master output chain.")),
                ("effectId", stringSchema("Id of the effect to bypass/re-enable, from fx.add's result or project.snapshot.")),
                ("bypassed", booleanSchema("True to bypass (disable) the effect, false to re-enable it.")),
            ], required: ["trackId", "effectId", "bypassed"])
        ),
        CopilotTool(
            command: "fx.setSidechain",
            description: "Key a built-in compressor or gate off ANOTHER track's signal — the classic sidechain pump. Add a compressor to the pad/bass, then key it from the kick so it ducks on every kick hit: fx.setSidechain {trackId: pad, effectId: comp, sourceTrackId: kick}. Pass sourceTrackId null (or omit it) to clear the key. Only compressor and gate inserts can be keyed; the keyed effect must be on an audio or bus track; the key source is another audio track; a key that would loop back on itself is rejected. The MASTER chain cannot host a sidechain-keyed effect and the master output cannot be a key source — key an effect on a track or bus instead. Returns the track's updated insert chain plus how far the key is delayed by latency (usually 0). Reversible with edit.undo.",
            schema: schemaObject([
                ("trackId", stringSchema("Id of the track or bus whose compressor/gate is being keyed, from project.snapshot.")),
                ("effectId", stringSchema("Id of the compressor or gate effect to key, from fx.add's result or project.snapshot.")),
                ("sourceTrackId", stringSchema("Id of the audio track to key FROM (e.g. the kick). Omit or pass null to clear the key.")),
            ], required: ["trackId", "effectId"])
        ),

        // MARK: render (2)

        CopilotTool(
            command: "render.mixdown",
            description: "Bounce the current session to a stereo 48 kHz WAV file, rendered offline (much faster than realtime, no audio hardware needed).",
            schema: schemaObject([
                ("path", stringSchema("Absolute path (or ~-prefixed) to write the rendered .wav file to. Omit for a temp file location.")),
                ("fromBeat", numberSchema("Timeline position in beats to start rendering from. Must be >= 0. Defaults to 0.", minimum: 0)),
                ("durationSeconds", numberSchema("Seconds of audio to render, starting at fromBeat. Must be > 0. Omit to default to the project's length plus a short tail.")),
            ])
        ),
        CopilotTool(
            command: "render.measureLoudness",
            description: "Render the session offline and measure its loudness (BS.1770-4 integrated LUFS, max momentary/short-term LUFS, true peak dBTP) without writing a file. -14 LUFS is the streaming convention, -23 LUFS is EBU R128 broadcast.",
            schema: schemaObject([
                ("fromBeat", numberSchema("Timeline position in beats to start measuring from. Must be >= 0. Defaults to 0.", minimum: 0)),
                ("durationSeconds", numberSchema("Seconds of audio to measure, starting at fromBeat. Must be > 0. Omit to default to the extent of every track's clips plus a tail.")),
            ])
        ),

        // MARK: ai (6)

        CopilotTool(
            command: "ai.sidecarStart",
            description: "Start the local ACE-Step song-generation sidecar (spawns the FastAPI process on 127.0.0.1:8001) if it isn't already healthy, then waits for it to report ready. A slow model load is not an error — it may return state \"starting\"; call this again a little later, or just proceed to submit a generation job.",
            schema: schemaObject([])
        ),
        CopilotTool(
            command: "ai.generateSong",
            description: "Submit an async full-song generation job to the local ACE-Step sidecar — sung vocals + instrumentation from a style prompt and optional lyrics, fully offline. Returns immediately with a jobId; poll ai.generationStatus until it succeeds, then ai.importGeneration to land it.",
            schema: schemaObject([
                ("prompt", stringSchema("Style/caption text: genre, mood, instrumentation, era, vocal character, e.g. \"80s synth-pop, anthemic, driving bassline, female vocals\".")),
                ("lyrics", stringSchema("Section-labeled lyrics in bracketed-structure format (e.g. \"[Verse 1]\\n...\\n[Chorus]\\n...\"). Omit/blank for an instrumental.")),
                ("durationSeconds", numberSchema(
                    "Target length in seconds, roughly 30-240 for best structural stability. Omit for the default (30s).",
                    minimum: 10, maximum: 600)),
                ("seed", integerSchema("Deterministic seed for reproducible output. Omit for a fresh random seed each call.", minimum: 0)),
                ("bpm", numberSchema("Target tempo in beats per minute. Omit to let the model choose one that fits the prompt.", minimum: 30, maximum: 300)),
                ("keyScale", stringSchema("Free-text key/scale hint, e.g. \"C Major\", \"A Minor\".")),
                ("timeSignature", stringSchema("Free-text time-signature hint, e.g. \"4/4\", \"3/4\".")),
                ("vocalLanguage", stringSchema("Language code for sung vocals, e.g. \"en\", \"ja\", \"es\". Defaults to \"en\".")),
                ("guidanceScale", numberSchema(
                    "Classifier-free-guidance scale — higher follows the prompt/lyrics more strictly. Omit for the default (7.0).",
                    minimum: 1, maximum: 20)),
                ("inferenceSteps", integerSchema(
                    "Diffusion sampling steps — more steps can improve quality at the cost of generation time. Omit for the default (8).",
                    minimum: 1, maximum: 100)),
            ], required: ["prompt"])
        ),
        CopilotTool(
            command: "ai.generationStatus",
            description: "Poll a song-generation job previously submitted by ai.generateSong or ai.fixClipRegion. Returns state (queued/running/succeeded) and, once succeeded, an audioPath ready to import.",
            schema: schemaObject([
                ("jobId", stringSchema("The jobId returned by the submitting command.")),
            ], required: ["jobId"])
        ),
        CopilotTool(
            command: "ai.importGeneration",
            description: "Turn a FINISHED song-generation job into project material: a new AI-flagged audio track + clip, optionally adopting the project tempo from the generation's detected BPM — one undoable step.",
            schema: schemaObject([
                ("jobId", stringSchema("The jobId returned by ai.generateSong. Must have reached state \"succeeded\" (check with ai.generationStatus).")),
                ("trackName", stringSchema("Name for the new track. Omit to default to \"AI: <first words of the prompt>\".")),
                ("atBeat", numberSchema("Beat position where the clip lands. Omit for 0.", minimum: 0)),
                ("setProjectTempo", booleanSchema("Whether to adopt the generation's detected BPM as the project tempo. Omit to auto-adopt only when the project has no other clips yet.")),
            ], required: ["jobId"])
        ),
        CopilotTool(
            command: "ai.fixClipRegion",
            description: "Submit an AI repaint of a region of an existing timeline AUDIO clip (\"fix this phrase\") to the local sidecar. SUBMIT-ONLY — does not change the project. Poll ai.generationStatus, then ai.importClipFix to land the result as a take.",
            schema: schemaObject([
                ("trackId", stringSchema("Id of the track holding the clip to fix.")),
                ("clipId", stringSchema("Id of the AUDIO clip to fix, from project.snapshot. A MIDI clip is rejected.")),
                ("startBeat", numberSchema("Start of the region to repaint, in ABSOLUTE timeline beats. Must lie inside the target clip's span.")),
                ("endBeat", numberSchema("End of the region to repaint, in ABSOLUTE timeline beats. Must be greater than startBeat.")),
                ("prompt", stringSchema("Style/caption text guiding the repainted region, e.g. \"clearer vocal, on pitch\". Omit to keep the source's own context.")),
                ("lyrics", stringSchema("Section-labeled lyrics for the region, when it carries vocals. Omit to leave vocal content to the model.")),
                ("mode", stringSchema(
                    "How strongly to regenerate: conservative stays closest to the original, balanced (default) is the standard trade-off, aggressive most freely reimagines it.",
                    enumValues: ["conservative", "balanced", "aggressive"])),
                ("strength", numberSchema(
                    "0-1 — how far a balanced-mode fix may depart from the original. Only consulted when mode is balanced.",
                    minimum: 0, maximum: 1)),
                ("seed", integerSchema(
                    "Deterministic seed. Omit for a fresh random seed each call — this is how you RETAKE the same region.",
                    minimum: 0)),
                ("contextSeconds", numberSchema(
                    "Seconds of surrounding audio rendered each side of the region for boundary continuity. Default 10.",
                    minimum: 1, maximum: 60)),
                ("model", stringSchema("DiT model name override. Normally best left unset.")),
            ], required: ["trackId", "clipId", "startBeat", "endBeat"])
        ),
        CopilotTool(
            command: "ai.importClipFix",
            description: "Land a FINISHED clip fix as a violet take lane comped in over exactly the region requested by ai.fixClipRegion. The original audio is never replaced.",
            schema: schemaObject([
                ("jobId", stringSchema("The jobId returned by ai.fixClipRegion. Must have reached state \"succeeded\" (check with ai.generationStatus).")),
            ], required: ["jobId"])
        ),

        // MARK: discovery (2)

        CopilotTool(
            command: "project.snapshot",
            description: "Get the full current state of the session: transport, tempo, master volume, all tracks with their settings, clips, effects, and routing. Call this first to orient before making other changes.",
            schema: schemaObject([])
        ),
        CopilotTool(
            command: "instrument.listAudioUnits",
            description: "List the Audio Unit instrument plugins installed on this Mac. Use this to discover what's available before hosting one with track.setInstrument (kind \"audioUnit\").",
            schema: schemaObject([])
        ),

        // MARK: edit (1)

        CopilotTool(
            command: "edit.undo",
            description: "Revert the most recent document edit (track, clip, mixer, tempo, loop, punch, or metronome change), one step at a time. Does not affect playback position.",
            schema: schemaObject([])
        ),
    ]

    /// All catalog command names, for tests and for enforcing that
    /// `neverInclude` entries never sneak in.
    public static var allCommands: [String] {
        v1.map(\.command)
    }

    private static let byCommand: [String: CopilotTool] = Dictionary(
        uniqueKeysWithValues: v1.map { ($0.command, $0) })
    private static let byToolName: [String: CopilotTool] = Dictionary(
        uniqueKeysWithValues: v1.map { (CopilotTool.toolName(fromCommand: $0.command), $0) })

    public static func tool(command: String) -> CopilotTool? { byCommand[command] }
    public static func tool(toolName: String) -> CopilotTool? { byToolName[toolName] }
}
