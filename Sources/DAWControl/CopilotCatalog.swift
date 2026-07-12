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
    /// curated allow-list (design §3), now 44 commands: transport (6),
    /// marker (5, m11-c), track (7), clip (12), take (2), mixer (1), render (2),
    /// ai (6), discovery (2), edit (1).
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
