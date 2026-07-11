/**
 * DAW Pro MCP server — tool registration.
 *
 * Builds and exports the `McpServer` instance (all `registerTool` calls
 * live in this file) but does NOT connect a transport — that is
 * `src/index.ts`'s job. Splitting it this way lets tests (see
 * `test/audit-tools.test.ts`) import `server` and drive it over an
 * in-memory transport without spawning stdio or opening the DAW control
 * WebSocket.
 *
 * Bridges MCP tools to two things (docs/ARCHITECTURE.md):
 *  1. The DAW app's control-protocol WebSocket, via `DawBridge` — transport,
 *     track, and project tools.
 *  2. AI providers directly, via `src/ai.ts` — lyrics, song, and image
 *     generation.
 *
 * `DawBridge` connects lazily (on first `send()`), so merely constructing
 * it here and registering tools has no network side effects — see
 * `bridge.ts`.
 *
 * This process is a stdio MCP server (entry point `index.ts`): stdout is
 * the transport wire, so nothing may ever `console.log`. All diagnostics
 * go to `console.error` (stderr), which MCP clients treat as a log
 * stream, not protocol data.
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { DawBridge } from "./bridge.js";
import { generateImage, generateLyrics, generateSongSuno } from "./ai.js";

interface ToolTextContent {
  type: "text";
  text: string;
}

interface ToolResult {
  [key: string]: unknown;
  content: ToolTextContent[];
  isError?: boolean;
}

function textResult(value: unknown): ToolResult {
  // Commands with no result body resolve `undefined`; JSON.stringify(undefined)
  // returns the JS value `undefined` (not the string "undefined"), which would
  // produce an invalid MCP content item ({type:"text", text: undefined}) and
  // fail client-side validation even though the command executed successfully.
  const text =
    value === undefined ? "ok" : typeof value === "string" ? value : JSON.stringify(value, null, 2);
  return { content: [{ type: "text", text }] };
}

function errorResult(err: unknown): ToolResult {
  const message = err instanceof Error ? err.message : String(err);
  return { content: [{ type: "text", text: message }], isError: true };
}

/** Run `fn`, wrapping the outcome as MCP tool content either way (never throws). */
async function toToolResult(fn: () => Promise<unknown>): Promise<ToolResult> {
  try {
    return textResult(await fn());
  } catch (err) {
    return errorResult(err);
  }
}

const bridge = new DawBridge();

export const server = new McpServer({
  name: "daw-pro",
  version: "0.1.0",
});

// ---------------------------------------------------------------------------
// Transport
// ---------------------------------------------------------------------------

server.registerTool(
  "transport_play",
  {
    title: "Start playback",
    description:
      "Start playback of the DAW session from the current transport position. " +
      "Has no effect (still ok) if already playing.",
  },
  async () => toToolResult(() => bridge.send("transport.play"))
);

server.registerTool(
  "transport_stop",
  {
    title: "Stop playback",
    description:
      "Stop playback. The playhead stays at its current position (use " +
      "transport_seek to move it). Has no effect (still ok) if already stopped.",
  },
  async () => toToolResult(() => bridge.send("transport.stop"))
);

server.registerTool(
  "transport_seek",
  {
    title: "Move the playhead",
    description:
      "Move the transport playhead to an absolute position, given in beats " +
      "(quarter notes) from the start of the timeline, e.g. beat 0 is the " +
      "very start, beat 4 is the downbeat of bar 2 in 4/4 time. Must be >= 0.",
    inputSchema: {
      beats: z
        .number()
        .min(0)
        .describe("Absolute position in beats (quarter notes) from timeline start. Must be >= 0."),
    },
  },
  async ({ beats }) => toToolResult(() => bridge.send("transport.seek", { beats }))
);

server.registerTool(
  "transport_set_tempo",
  {
    title: "Set the project tempo",
    description:
      "Set the project tempo in BPM (beats per minute), i.e. quarter notes " +
      "per minute. Valid range 20-400 BPM (typical music ranges roughly " +
      "60-200 BPM; e.g. 60 = slow ballad, 120 = common pop/house tempo, " +
      "174 = drum & bass).",
    inputSchema: {
      bpm: z
        .number()
        .min(20)
        .max(400)
        .describe("Tempo in beats per minute (quarter notes/minute). Range 20-400."),
    },
  },
  async ({ bpm }) => toToolResult(() => bridge.send("transport.setTempo", { bpm }))
);

server.registerTool(
  "transport_record",
  {
    title: "Start recording",
    description:
      "Start recording onto ALL armed tracks while simultaneously starting " +
      "playback from the current transport position — record = capture + " +
      "play together, so you hear the existing session while you record " +
      "over it. Captures the Mac's default audio input into new takes on " +
      "armed AUDIO tracks, AND incoming live MIDI (from any online source, " +
      "see midi_list_inputs) into a new MIDI clip on armed INSTRUMENT " +
      "tracks — both kinds record together as one take, and stopping " +
      "produces a single undo step covering everything captured. Only " +
      "valid while stopped; arm at least one track first with " +
      "track_set_arm, or nothing will be captured. No params. Stop with " +
      "transport_stop. Note: an active punch window (transport_set_punch) " +
      "trims recorded AUDIO to [inBeat, outBeat] only — MIDI capture always " +
      "spans the full roll from the transport position where recording " +
      "started, regardless of the punch window. After stopping, check " +
      "project_snapshot's `lastRecordingError` field: null means the take " +
      "succeeded, a string explains what went wrong (e.g. microphone " +
      "permission denied, no armed tracks, or an empty take). Requires " +
      "macOS microphone permission for audio tracks — the first recording " +
      "may trigger the system permission prompt.",
  },
  async () => toToolResult(() => bridge.send("transport.record"))
);

server.registerTool(
  "transport_set_loop",
  {
    title: "Enable or disable loop playback",
    description:
      "Enable or disable loop-region playback between startBeat and endBeat " +
      "(beats/quarter notes). When looping is enabled, the playhead wraps from " +
      "the loop end back to the loop start during playback instead of playing " +
      "past it. endBeat must be greater than startBeat. When enabling the loop " +
      "for the first time, provide both startBeat and endBeat; if either is " +
      "omitted, the previously set value is kept. Returns the updated transport " +
      "state.",
    inputSchema: {
      enabled: z.boolean().describe("True to enable loop playback, false to disable it."),
      startBeat: z
        .number()
        .min(0)
        .optional()
        .describe(
          "Loop start position in beats (quarter notes) from timeline start. Must be >= 0. " +
            "Omit to keep the previously set loop start."
        ),
      endBeat: z
        .number()
        .gt(0)
        .optional()
        .describe(
          "Loop end position in beats (quarter notes) from timeline start. Must be > 0 and " +
            "greater than startBeat. Omit to keep the previously set loop end."
        ),
    },
  },
  async ({ enabled, startBeat, endBeat }) =>
    toToolResult(() => bridge.send("transport.setLoop", { enabled, startBeat, endBeat }))
);

server.registerTool(
  "transport_set_punch",
  {
    title: "Enable or disable punch recording",
    description:
      "Enable or disable a punch-recording window between inBeat and outBeat " +
      "(beats/quarter notes). When enabled, transport_record captures ONLY the " +
      "audio falling inside [inBeat, outBeat] — the resulting take clip lands " +
      "at inBeat with the window's length, letting you drop into an existing " +
      "take without re-recording the whole thing. outBeat must be greater than " +
      "inBeat. When enabling punch for the first time, provide both inBeat and " +
      "outBeat; if either is omitted, the previously set value is kept. Cannot " +
      "be changed while recording is in progress. Starting a recording with " +
      "the punch window entirely behind the current playhead position is an " +
      "error. Returns the updated transport state.",
    inputSchema: {
      enabled: z.boolean().describe("True to enable punch recording, false to disable it."),
      inBeat: z
        .number()
        .min(0)
        .optional()
        .describe(
          "Punch-in position in beats (quarter notes) from timeline start, where recording " +
            "starts capturing. Must be >= 0. Omit to keep the previously set punch-in point."
        ),
      outBeat: z
        .number()
        .gt(0)
        .optional()
        .describe(
          "Punch-out position in beats (quarter notes) from timeline start, where recording " +
            "stops capturing. Must be > 0 and greater than inBeat. Omit to keep the previously " +
            "set punch-out point."
        ),
    },
  },
  async ({ enabled, inBeat, outBeat }) =>
    toToolResult(() => bridge.send("transport.setPunch", { enabled, inBeat, outBeat }))
);

server.registerTool(
  "transport_set_metronome",
  {
    title: "Enable or disable the metronome click",
    description:
      "Toggle the metronome click heard during playback and recording (the " +
      "downbeat of each bar is accented). `countInBars` sets how many bars of " +
      "count-in clicks play immediately before recording starts (0 = no " +
      "count-in). Count-in clicks always sound, even if the metronome itself " +
      "is disabled — and the recorded take never includes the count-in audio. " +
      "Cannot be changed while recording is in progress. Returns the updated " +
      "transport state.",
    inputSchema: {
      enabled: z.boolean().describe("True to enable the metronome click, false to disable it."),
      countInBars: z
        .number()
        .int()
        .min(0)
        .max(4)
        .optional()
        .describe(
          "Number of bars of count-in clicks to play before recording starts, 0-4. " +
            "0 means no count-in. Count-in clicks sound even if the metronome is off, and " +
            "are never part of the recorded take. Omit to keep the previously set value."
        ),
    },
  },
  async ({ enabled, countInBars }) =>
    toToolResult(() => bridge.send("transport.setMetronome", { enabled, countInBars }))
);

// ---------------------------------------------------------------------------
// Tracks
// ---------------------------------------------------------------------------

server.registerTool(
  "track_add",
  {
    title: "Add a track",
    description:
      "Add a new track to the session. `kind` is one of: `audio` (records/plays " +
      "back audio clips), `instrument` (hosts a virtual instrument / MIDI), or " +
      "`bus` (creates a mix bus destination — a submix/aux track with no clips " +
      "of its own that other tracks route their output or sends into via " +
      "track_set_output / track_add_send; a bus track's own output always goes " +
      "to the master mix). Defaults to `audio`.",
    inputSchema: {
      name: z.string().min(1).describe("Display name for the new track, e.g. \"Lead Vocal\"."),
      kind: z
        .enum(["audio", "instrument", "bus"])
        .default("audio")
        .describe("Track type: audio, instrument, or bus. Defaults to audio."),
    },
  },
  async ({ name, kind }) => toToolResult(() => bridge.send("track.add", { name, kind }))
);

server.registerTool(
  "track_remove",
  {
    title: "Remove a track",
    description: "Permanently remove a track (and its clips) from the session by id.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track to remove, from project_snapshot."),
    },
  },
  async ({ trackId }) => toToolResult(() => bridge.send("track.remove", { trackId }))
);

server.registerTool(
  "track_rename",
  {
    title: "Rename a track",
    description:
      "Change a track's display name (the label shown in the track header " +
      "and mixer). Purely cosmetic — does not affect audio, routing, or ids.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track to rename, from project_snapshot."),
      name: z.string().min(1).describe("New display name for the track."),
    },
  },
  async ({ trackId, name }) => toToolResult(() => bridge.send("track.rename", { trackId, name }))
);

server.registerTool(
  "track_set_volume",
  {
    title: "Set track volume",
    description:
      "Set a track's fader volume as a linear gain multiplier, where 1.0 is " +
      "unity gain (0 dB, no change). Range 0-2: 0 is silence, 0.5 is roughly " +
      "-6 dB, 2.0 is roughly +6 dB. This is linear gain, not decibels.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track, from project_snapshot."),
      volume: z
        .number()
        .min(0)
        .max(2)
        .describe("Linear gain, 0-2, where 1 = unity gain (0 dB)."),
    },
  },
  async ({ trackId, volume }) => toToolResult(() => bridge.send("track.setVolume", { trackId, volume }))
);

server.registerTool(
  "track_set_pan",
  {
    title: "Set track pan",
    description:
      "Set a track's stereo pan position. Range -1 to 1: -1 is hard left, " +
      "0 is centered, 1 is hard right.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track, from project_snapshot."),
      pan: z.number().min(-1).max(1).describe("Pan position, -1 (hard left) to 1 (hard right), 0 = center."),
    },
  },
  async ({ trackId, pan }) => toToolResult(() => bridge.send("track.setPan", { trackId, pan }))
);

server.registerTool(
  "track_set_mute",
  {
    title: "Mute or unmute a track",
    description: "Mute (silence) or unmute a track's output without changing its volume/pan settings.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track, from project_snapshot."),
      muted: z.boolean().describe("True to mute the track, false to unmute it."),
    },
  },
  async ({ trackId, muted }) => toToolResult(() => bridge.send("track.setMute", { trackId, muted }))
);

server.registerTool(
  "track_set_solo",
  {
    title: "Solo or unsolo a track",
    description:
      "Solo or unsolo a track. When one or more tracks are soloed, only " +
      "soloed tracks are audible; this does not change any track's mute state.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track, from project_snapshot."),
      soloed: z.boolean().describe("True to solo the track, false to unsolo it."),
    },
  },
  async ({ trackId, soloed }) => toToolResult(() => bridge.send("track.setSolo", { trackId, soloed }))
);

server.registerTool(
  "track_set_arm",
  {
    title: "Arm or disarm a track for recording",
    description:
      "Arm or disarm a track for recording. Works on both AUDIO tracks " +
      "(captures the Mac's default microphone/input) and INSTRUMENT tracks " +
      "(feeds live MIDI thru from all online sources — see " +
      "midi_list_inputs — so an armed instrument track sounds its notes as " +
      "they're played; transport_record then captures that incoming MIDI " +
      "into a new MIDI clip). Multiple tracks of either kind can be armed at " +
      "once; a mix of armed audio and instrument tracks all record together " +
      "in the same transport_record take. Arming the first audio track may " +
      "trigger the macOS microphone-permission prompt. Bus tracks cannot be " +
      "armed.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the audio track to arm/disarm, from project_snapshot."),
      armed: z.boolean().describe("True to arm the track for recording, false to disarm it."),
    },
  },
  async ({ trackId, armed }) => toToolResult(() => bridge.send("track.setArm", { trackId, armed }))
);

const samplerZoneSchema = z.object({
  path: z
    .string()
    .min(1)
    .describe(
      "REQUIRED. Absolute file path to this zone's sample audio file (wav/aiff/etc.). The " +
        "file is copied into the project bundle on project_save, so the project stays " +
        "portable — always pass the original source path here, not a bundle-relative one."
    ),
  rootPitch: z
    .number()
    .int()
    .min(0)
    .max(127)
    .optional()
    .describe(
      "MIDI pitch, 0-127 (60 = middle C), at which this sample plays back at its original " +
        "recorded speed/pitch. Notes above or below are pitch-shifted relative to this root. " +
        "Defaults to 60."
    ),
  minPitch: z
    .number()
    .int()
    .min(0)
    .max(127)
    .optional()
    .describe(
      "Lowest MIDI pitch, 0-127, this zone covers (inclusive). Together with `maxPitch` this " +
        "defines the keyzone's range. Defaults to 0."
    ),
  maxPitch: z
    .number()
    .int()
    .min(0)
    .max(127)
    .optional()
    .describe(
      "Highest MIDI pitch, 0-127, this zone covers (inclusive). Together with `minPitch` this " +
        "defines the keyzone's range. Defaults to 127."
    ),
  gain: z
    .number()
    .min(0)
    .max(1)
    .optional()
    .describe(
      "This zone's own output level, 0-1, on top of the sampler's overall `gain`. Defaults to 1."
    ),
});

const samplerSchema = z
  .object({
    zones: z
      .array(samplerZoneSchema)
      .describe(
        "The sampler's keyzone map, checked in array order: for a played note, the FIRST " +
          "zone whose minPitch-maxPitch range contains that note's pitch is the one that " +
          "plays (zones are not layered — exactly one, if any, sounds per note). Use one " +
          "zone for a single mapped sample, or several zones with non-overlapping ranges to " +
          "split different samples across the keyboard (e.g. a multi-sampled drum kit or " +
          "instrument with per-register recordings)."
      ),
    oneShot: z
      .boolean()
      .optional()
      .describe(
        "If true, a triggered sample always plays to completion regardless of note-off — " +
          "use this for drum hits and other percussive one-shots. If false (default), the " +
          "sample stops following note-off, fading out over `release` seconds, like a " +
          "sustained instrument."
      ),
    attack: z
      .number()
      .optional()
      .describe(
        "Sampler amplitude envelope attack time in seconds — how long a triggered note takes " +
          "to reach full volume. Defaults to 0.001 (near-instant)."
      ),
    release: z
      .number()
      .optional()
      .describe(
        "Sampler amplitude envelope release time in seconds — how long the sample fades to " +
          "silence after note-off. Ignored when `oneShot` is true. Defaults to 0.05."
      ),
    gain: z
      .number()
      .min(0)
      .max(1)
      .optional()
      .describe(
        "The sampler's overall output level, 0-1, separate from each zone's own `gain` and " +
          "from the track fader set by track_set_volume. Defaults to 0.8."
      ),
  })
  .describe(
    "Sampler configuration, used only when `kind` is (or already is) `sampler`. Providing " +
      "this object REPLACES the sampler's entire configuration at once — `zones` is not " +
      "merged with any zones already on the track, so to add/remove/edit one zone you must " +
      "resend the complete `zones` array. Omit `sampler` entirely to leave the track's " +
      "current sampler configuration untouched (e.g. when this call only changes `kind` or " +
      "is switching a different track's instrument). Has no effect on `testTone`/`polySynth`."
  );

const audioUnitSchema = z
  .object({
    type: z
      .string()
      .length(4)
      .optional()
      .describe(
        "Audio Unit component type, a 4-character FourCC string. Defaults to \"aumu\" " +
          "(music device / instrument) — the only type track_set_instrument can host. " +
          "Omit unless instrument_list_audio_units reported a different type."
      ),
    subType: z
      .string()
      .length(4)
      .describe(
        "REQUIRED. Audio Unit component subType, a 4-character FourCC string EXACTLY as " +
          "returned by instrument_list_audio_units — trailing spaces are significant " +
          "(e.g. \"dls \" for Apple's DLSMusicDevice General MIDI synth)."
      ),
    manufacturer: z
      .string()
      .length(4)
      .describe(
        "REQUIRED. Audio Unit component manufacturer, a 4-character FourCC string EXACTLY " +
          "as returned by instrument_list_audio_units (e.g. \"appl\" for Apple)."
      ),
  })
  .describe(
    "Identifies one installed Audio Unit instrument by its component triple (type/subType/" +
      "manufacturer), used only when `kind` is (or is being set to) `audioUnit`. Call " +
      "instrument_list_audio_units first to discover installed AUs and copy their exact " +
      "FourCC strings verbatim, including significant trailing spaces. Selecting an " +
      "`audioUnit` implies `kind` `audioUnit` even if `kind` is omitted from this call. " +
      "An unknown/uninstalled component triple is rejected with a readable error pointing " +
      "you back to instrument_list_audio_units. The AU's own preset/parameter state " +
      "persists in the project automatically on project_save. If a project referencing an " +
      "AU is opened on a machine where that AU isn't installed, the track loads silently " +
      "with an instrument `status` of \"missing\" in project_snapshot rather than failing " +
      "to open. Omit `audioUnit` to leave the track's current instrument untouched."
  );

server.registerTool(
  "track_set_instrument",
  {
    title: "Select or edit an instrument track's instrument",
    description:
      "Select and/or tweak the instrument on an INSTRUMENT track — this is " +
      "what actually makes its MIDI clips (from clip_add_midi) audible. " +
      "`kind` picks the instrument: `testTone` (a simple fixed tone, mainly for " +
      "signal-chain testing), `polySynth` (a polyphonic subtractive synth with " +
      "an oscillator, ADSR envelope, and resonant low-pass filter — the default " +
      "instrument, good for pads, leads, and basic chords), `sampler` (plays " +
      "back your own audio files/samples across a keyboard range — configured " +
      "via the `sampler` param, good for drum kits, real-instrument recordings, " +
      "and one-shots), or `audioUnit` (hosts an installed Audio Unit instrument " +
      "plugin — third-party or Apple synths/samplers registered with the " +
      "system — selected via the `audioUnit` param; call " +
      "instrument_list_audio_units first to discover what's installed). This " +
      "is a PARTIAL update: any field you omit keeps its current value, so you " +
      "can change just one knob (e.g. only `cutoffHz`) without resending the " +
      "rest — EXCEPT `sampler`, which replaces the whole sampler configuration " +
      "at once when provided (see its own description). The synth params only " +
      "apply to `polySynth`: `waveform` is the oscillator shape (`saw`, " +
      "`square`, `triangle`, `sine` — saw is brightest/buzziest, sine is " +
      "purest/softest); `attack`/`decay`/`sustain`/`release` are the amplitude " +
      "envelope in seconds (attack: time to reach full volume after a note " +
      "starts, 0.0005-5s; decay: time to fall from peak to the sustain level, " +
      "0.001-5s; sustain: the held level while a note is down, 0-1, NOT a " +
      "time; release: time to fade to silence after note-off, 0.001-8s); " +
      "`cutoffHz` is the low-pass filter cutoff frequency, 40-18000 Hz (lower " +
      "= darker/muffled, higher = brighter/more open); `resonance` is filter " +
      "emphasis right at the cutoff, 0-1 (higher adds a resonant peak/whine, " +
      "0 is a plain filter); `gain` is the instrument's own output level, 0-1 " +
      "(separate from the track fader set by track_set_volume). All numeric " +
      "params are clamped to their safe range if you pass a value outside it. " +
      "`audioUnit` (see its own description) selects a specific installed AU " +
      "by component triple, is only meaningful for `kind` `audioUnit`, and " +
      "implies that kind even if `kind` is omitted. Default instrument (a " +
      "fresh instrument track) is polySynth with a saw wave. Audio and bus " +
      "tracks reject this — use track_add or project_snapshot to find/create " +
      "an instrument track first.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the instrument track, from project_snapshot."),
      kind: z
        .enum(["testTone", "polySynth", "sampler", "audioUnit"])
        .optional()
        .describe(
          "Which instrument to use: `testTone` (simple fixed test tone), `polySynth` " +
            "(polyphonic subtractive synth), `sampler` (plays back your own audio files, " +
            "configured via `sampler`), or `audioUnit` (hosts an installed Audio Unit " +
            "instrument plugin, selected via `audioUnit`; see instrument_list_audio_units " +
            "to discover installed AUs). Omit to keep the current instrument."
        ),
      waveform: z
        .enum(["saw", "square", "triangle", "sine"])
        .optional()
        .describe(
          "polySynth oscillator waveform: saw (bright/buzzy), square (hollow/reedy), " +
            "triangle (mellow), or sine (pure/soft). No effect on testTone. Omit to keep the " +
            "current value."
        ),
      attack: z
        .number()
        .optional()
        .describe(
          "polySynth amplitude envelope attack time in seconds — how long a note takes to " +
            "reach full volume after it starts. Clamped to 0.0005-5. Omit to keep the current value."
        ),
      decay: z
        .number()
        .optional()
        .describe(
          "polySynth amplitude envelope decay time in seconds — how long the note takes to " +
            "fall from its peak to the sustain level. Clamped to 0.001-5. Omit to keep the current value."
        ),
      sustain: z
        .number()
        .optional()
        .describe(
          "polySynth amplitude envelope sustain LEVEL (not a time), 0-1 — the volume held " +
            "while a note stays down, as a fraction of peak. Clamped to 0-1. Omit to keep the " +
            "current value."
        ),
      release: z
        .number()
        .optional()
        .describe(
          "polySynth amplitude envelope release time in seconds — how long the note takes to " +
            "fade to silence after note-off. Clamped to 0.001-8. Omit to keep the current value."
        ),
      cutoffHz: z
        .number()
        .optional()
        .describe(
          "polySynth low-pass filter cutoff frequency in Hz — lower is darker/muffled, higher " +
            "is brighter/more open. Clamped to 40-18000. Omit to keep the current value."
        ),
      resonance: z
        .number()
        .optional()
        .describe(
          "polySynth filter resonance, 0-1 — emphasis right at the cutoff frequency; higher " +
            "adds a resonant peak/whine, 0 is a plain filter. Clamped to 0-1. Omit to keep the " +
            "current value."
        ),
      gain: z
        .number()
        .optional()
        .describe(
          "polySynth output level, 0-1 — the instrument's own gain, separate from the track " +
            "fader (track_set_volume). Clamped to 0-1. Omit to keep the current value."
        ),
      sampler: samplerSchema.optional(),
      audioUnit: audioUnitSchema.optional(),
    },
  },
  async ({
    trackId,
    kind,
    waveform,
    attack,
    decay,
    sustain,
    release,
    cutoffHz,
    resonance,
    gain,
    sampler,
    audioUnit,
  }) =>
    toToolResult(() =>
      bridge.send("track.setInstrument", {
        trackId,
        kind,
        waveform,
        attack,
        decay,
        sustain,
        release,
        cutoffHz,
        resonance,
        gain,
        sampler,
        audioUnit,
      })
    )
);

// ---------------------------------------------------------------------------
// Bus routing & sends
// ---------------------------------------------------------------------------

server.registerTool(
  "track_set_output",
  {
    title: "Route a track's output to a bus (or back to master)",
    description:
      "Route a track's main output either into a bus track (its signal joins " +
      "that bus's mix instead of going straight to the master bus) or back to " +
      "the master mix. This is the track's ONE main output — for an additional " +
      "parallel signal path (e.g. a shared reverb bus while the dry signal " +
      "still reaches its usual destination), use track_add_send instead. Bus " +
      "tracks themselves always output to the master bus (v0 has no nested/" +
      "sub-bus chains) and reject being given an outputBusId. Returns the " +
      "track's full routing state: `{trackId, outputBusId, sends}`.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track whose output to route, from project_snapshot."),
      busId: z
        .string()
        .min(1)
        .optional()
        .describe(
          "Id (UUID) of the bus track to route this track's output into, from " +
            "project_snapshot (a track with kind `bus`). Omit (or pass null) to " +
            "route the track's output back to the master mix."
        ),
    },
  },
  async ({ trackId, busId }) =>
    toToolResult(() => bridge.send("track.setOutput", { trackId, busId: busId ?? null }))
);

server.registerTool(
  "track_add_send",
  {
    title: "Add an effect send from a track to a bus",
    description:
      "Add a POST-FADER send from a track into a bus track — a parallel copy " +
      "of the track's signal, taken AFTER its own volume/mute/pan, mixed into " +
      "the destination bus alongside whatever else feeds it. This is the " +
      "standard FX-send pattern: e.g. give several tracks a send into one " +
      "\"Reverb\" bus so they share a single reverb effect placed on that bus, " +
      "instead of putting a separate reverb on every track. Unlike " +
      "track_set_output (which redirects the track's ONE main output), a send " +
      "is additional — the track keeps outputting wherever it already does " +
      "AND also feeds the bus. Only one send per destination bus per track is " +
      "allowed; adding a second send to the same busId is an error (use " +
      "track_set_send to change an existing send's level instead). `busId` " +
      "must refer to a track with kind `bus`. Returns the track's full " +
      "routing state: `{trackId, outputBusId, sends}`, where the new send " +
      "appears in `sends` with a server-minted `id`.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track to send from, from project_snapshot."),
      busId: z
        .string()
        .min(1)
        .describe(
          "Id (UUID) of the destination bus track (kind `bus`), from " +
            "project_snapshot. Required."
        ),
      level: z
        .number()
        .min(0)
        .max(2)
        .optional()
        .describe(
          "Send level as a linear gain multiplier, 0-2, where 1.0 is unity " +
            "gain (0 dB, the send passes the signal unchanged in level). " +
            "0 is silent (send exists but contributes nothing), 2.0 is " +
            "roughly +6 dB. Out-of-range values are clamped. Defaults to 1."
        ),
    },
  },
  async ({ trackId, busId, level }) =>
    toToolResult(() => bridge.send("track.addSend", { trackId, busId, level }))
);

server.registerTool(
  "track_set_send",
  {
    title: "Change an existing send's level",
    description:
      "Change an existing send's level in place, without interrupting " +
      "playback or recreating the send (its `id` and destination bus stay the " +
      "same) — the way to ride a send level, e.g. turning up how much of a " +
      "track goes into a shared reverb bus. Use track_add_send first to " +
      "create the send and learn its `id`. Returns the track's full routing " +
      "state: `{trackId, outputBusId, sends}`.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track that owns the send, from project_snapshot."),
      sendId: z
        .string()
        .min(1)
        .describe("Id of the send to change, from track_add_send's result or project_snapshot."),
      level: z
        .number()
        .min(0)
        .max(2)
        .describe(
          "New send level as a linear gain multiplier, 0-2, where 1.0 is " +
            "unity gain (0 dB). Out-of-range values are clamped. Required."
        ),
    },
  },
  async ({ trackId, sendId, level }) =>
    toToolResult(() => bridge.send("track.setSend", { trackId, sendId, level }))
);

server.registerTool(
  "track_remove_send",
  {
    title: "Remove a send",
    description:
      "Permanently remove an existing send from a track, by id — stops that " +
      "parallel feed into the destination bus entirely (the track's main " +
      "output, set via track_set_output, is unaffected). Returns the track's " +
      "full routing state: `{trackId, outputBusId, sends}`.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track that owns the send, from project_snapshot."),
      sendId: z
        .string()
        .min(1)
        .describe("Id of the send to remove, from track_add_send's result or project_snapshot."),
    },
  },
  async ({ trackId, sendId }) =>
    toToolResult(() => bridge.send("track.removeSend", { trackId, sendId }))
);

server.registerTool(
  "midi_list_inputs",
  {
    title: "List connected MIDI input devices",
    description:
      "List the MIDI input devices/sources currently visible to the DAW — " +
      "hardware MIDI keyboards/controllers (USB or DIN via an interface) and " +
      "virtual sources (e.g. IAC Driver buses, other apps' virtual outputs). " +
      "Each entry has `uniqueID` (stable Int32 identity for this source, " +
      "persists across reconnects of the same device), `name`, `isVirtual` " +
      "(true for a software/virtual source, false for physical hardware), " +
      "and `isOnline` (true if currently connected/available). No params. " +
      "All ONLINE sources feed every armed instrument track automatically " +
      "(omni — no per-track MIDI input selection yet): arm an instrument " +
      "track with track_set_arm to hear its live MIDI thru, and use " +
      "transport_record to capture incoming notes into a new MIDI clip. " +
      "Call this to confirm a keyboard is detected before expecting live " +
      "input to work.",
  },
  async () => toToolResult(() => bridge.send("midi.listInputs"))
);

server.registerTool(
  "instrument_list_audio_units",
  {
    title: "List installed Audio Unit instrument plugins",
    description:
      "List the Audio Unit instrument plugins (\"music devices\") installed on " +
      "this Mac — both Apple's built-in ones and any third-party AUv2/AUv3 " +
      "instruments registered with the system. Use this to discover what's " +
      "available before hosting one with track_set_instrument (`kind: " +
      "\"audioUnit\"`). No params. Each entry has: `name` (display name, e.g. " +
      "\"DLSMusicDevice\"); `manufacturerName` (display name, e.g. \"Apple\"); " +
      "`type`/`subType`/`manufacturer` — the component triple as 4-character " +
      "FourCC strings, e.g. \"aumu\"/\"dls \"/\"appl\" identifies Apple's " +
      "DLSMusicDevice General MIDI synth (note: FourCC strings can have " +
      "significant trailing spaces — copy them verbatim); `version` (the " +
      "component's numeric version); and `isV3` (true for an AUv3 " +
      "app-extension-based instrument, false for a legacy AUv2 component — " +
      "both host the same way from here). Pass the exact `type`/`subType`/" +
      "`manufacturer` strings from an entry as track_set_instrument's " +
      "`audioUnit` param to select it.",
  },
  async () => toToolResult(() => bridge.send("instrument.listAudioUnits"))
);

// ---------------------------------------------------------------------------
// FX insert chains
// ---------------------------------------------------------------------------

const fxKindSchema = z
  .enum([
    "gain",
    "eq",
    "compressor",
    "limiter",
    "reverb",
    "delay",
    "saturator",
    "gate",
    "chorus",
    "audioUnit",
  ])
  .describe(
    "Effect kind. `gain` is a simple linear gain stage. `eq` is a 4-band parametric " +
      "equalizer (low shelf, two peaking/bell bands, high shelf) — call fx_describe to see " +
      "its exact parameter names, e.g. `peak1Freq`/`peak1GainDb`/`peak1Q` for the first " +
      "peaking band (the second peaking band follows the same naming pattern). " +
      "`compressor` is a soft-knee, stereo-linked dynamics processor: `thresholdDb`, " +
      "`ratio`, `attackMs`, `releaseMs`, `kneeDb`, `makeupDb`. `limiter` is a lookahead " +
      "brick-wall limiter: `ceilingDb`, `releaseMs` — it adds 5 ms of processing latency, " +
      "reported per-effect as `latencySamples` in project_snapshot's `effects` array. " +
      "`reverb` is a Freeverb-style room simulation: `roomSize`, `damping`, `mix`, " +
      "`preDelayMs`, `width`. `delay` is a stereo echo: `timeMs`, `feedback`, `mix`, " +
      "`pingPong` (0 or 1 — 1 alternates repeats left/right), `highCutHz`. `saturator` " +
      "is a tanh-based drive/color stage: `driveDb`, `mix`, `outputDb`. `gate` is a " +
      "noise gate: `thresholdDb`, `attackMs`, `holdMs`, `releaseMs`. `chorus` is a " +
      "2-voice modulated thickener: `rateHz`, `depthMs`, `mix`. `audioUnit` hosts an " +
      "installed Audio Unit EFFECT plugin — third-party or Apple effects registered " +
      "with the system — selected via fx_add's `audioUnit` param (REQUIRED when this " +
      "kind is used); call fx_list_audio_units first to discover what's installed."
  );

const fxAudioUnitSchema = z
  .object({
    type: z
      .string()
      .length(4)
      .optional()
      .describe(
        "Audio Unit component type, a 4-character FourCC string. Defaults to \"aufx\" " +
          "(effect) — the only type fx_add can host. Omit unless fx_list_audio_units " +
          "reported a different type."
      ),
    subType: z
      .string()
      .length(4)
      .describe(
        "REQUIRED. Audio Unit component subType, a 4-character FourCC string EXACTLY as " +
          "returned by fx_list_audio_units — trailing spaces are significant."
      ),
    manufacturer: z
      .string()
      .length(4)
      .describe(
        "REQUIRED. Audio Unit component manufacturer, a 4-character FourCC string EXACTLY " +
          "as returned by fx_list_audio_units (e.g. \"appl\" for Apple)."
      ),
  })
  .describe(
    "Identifies one installed Audio Unit EFFECT by its component triple (type/subType/" +
      "manufacturer). REQUIRED when `kind` is `audioUnit`, ignored otherwise. Call " +
      "fx_list_audio_units first to discover installed AU effects and copy their exact " +
      "FourCC strings verbatim, including significant trailing spaces. An unknown/" +
      "uninstalled component triple is rejected with a readable error pointing you back " +
      "to fx_list_audio_units."
  );

server.registerTool(
  "fx_add",
  {
    title: "Add an effect to a track or bus's insert chain",
    description:
      "Insert a new effect into a track or bus's insert chain. Insert effects are " +
      "PRE-FADER — they process the signal before the track's own volume/pan " +
      "(track_set_volume/track_set_pan) — unlike sends (track_add_send), which tap the " +
      "signal POST-fader. The chain is an ordered array and ARRAY ORDER IS PROCESSING " +
      "ORDER: index 0 processes first, and reordering the chain later with fx_reorder " +
      "changes what the signal actually hears (e.g. EQ before vs. after a compressor " +
      "sounds different). `kind` selects which effect to insert; `index` is where it " +
      "lands in the chain (0 = processed first) — omit to append at the end, and " +
      "out-of-range values clamp into range rather than erroring. `params` seeds the " +
      "new effect's parameters by name (e.g. `{ gain: 1.5 }`); call fx_describe first " +
      "to see each kind's exact parameter names, ranges, defaults, and units — omitted " +
      "params start at their default, and out-of-range values clamp. `audioUnit` " +
      "(see its own description) selects a specific installed Audio Unit effect plugin " +
      "by component triple and is REQUIRED when `kind` is `audioUnit` (call " +
      "fx_list_audio_units first to discover what's installed); it's ignored for every " +
      "other kind. Each track/bus's insert chain is capped at 16 effects (adding a 17th " +
      "errors). Adding an effect never interrupts or glitches playback. Returns " +
      "`{effectId, effects}`: the new effect's server-minted id, and the track's full " +
      "updated insert chain (same shape as project_snapshot's per-track `effects` array).",
    inputSchema: {
      trackId: z
        .string()
        .min(1)
        .describe("Id of the track or bus to add the effect to, from project_snapshot."),
      kind: fxKindSchema.default("gain"),
      index: z
        .number()
        .int()
        .min(0)
        .optional()
        .describe(
          "Position to insert at in the chain, 0 = processed first. Omit to append after " +
            "every effect already in the chain. Out-of-range values clamp to the nearest " +
            "valid position."
        ),
      params: z
        .record(z.string(), z.number())
        .optional()
        .describe(
          "Initial parameter values by name, e.g. `{ gain: 1.5 }`. Call fx_describe to see " +
            "this kind's parameter names, ranges, defaults, and units. Omitted params start " +
            "at their default; out-of-range values clamp."
        ),
      audioUnit: fxAudioUnitSchema.optional(),
    },
  },
  async ({ trackId, kind, index, params, audioUnit }) =>
    toToolResult(() => bridge.send("fx.add", { trackId, kind, index, params, audioUnit }))
);

server.registerTool(
  "fx_list_audio_units",
  {
    title: "List installed Audio Unit effect plugins",
    description:
      "List the Audio Unit EFFECT plugins installed on this Mac — both Apple's " +
      "built-in ones and any third-party AUv2/AUv3 effects registered with the " +
      "system. Use this to discover what's available before hosting one with " +
      "fx_add (`kind: \"audioUnit\"`). No params. Each entry has: `name` (display " +
      "name, e.g. \"AUGraphicEQ\"); `manufacturerName` (display name, e.g. " +
      "\"Apple\"); `type`/`subType`/`manufacturer` — the component triple as " +
      "4-character FourCC strings, e.g. \"aufx\"/\"grEQ\"/\"appl\" identifies " +
      "Apple's Graphic EQ (note: FourCC strings can have significant trailing " +
      "spaces — copy them verbatim); `version` (the component's numeric " +
      "version); and `isV3` (true for an AUv3 app-extension-based effect, false " +
      "for a legacy AUv2 component — both host the same way from here). Pass " +
      "the exact `type`/`subType`/`manufacturer` strings from an entry as " +
      "fx_add's `audioUnit` param to select it.",
  },
  async () => toToolResult(() => bridge.send("fx.listAudioUnits"))
);

// ---------------------------------------------------------------------------
// Plugin UI windows (M3 vi-b)
// ---------------------------------------------------------------------------

server.registerTool(
  "plugin_open_ui",
  {
    title: "Open an Audio Unit plugin's window",
    description:
      "Open (or focus) the floating window of the LIVE Audio Unit plugin hosted " +
      "on a track — its instrument, or one of its insert effects. This is the " +
      "SAME sounding instance the graph is rendering, so any parameter you change " +
      "in the window affects the audio IMMEDIATELY (and shows up in project_save's " +
      "captured state). Plugin windows apply ONLY to Audio Units: pass a track " +
      "whose instrument is `kind:\"audioUnit\"` (omit effectId) or an insert whose " +
      "`kind` is `audioUnit` (pass its effectId) — a built-in instrument/effect is " +
      "rejected readably (built-ins have first-class in-app editors). If the unit " +
      "hasn't finished loading you get a readable not-ready error (retry once " +
      "prepared); a HEADLESS control session (the app has no UI) errors readably " +
      "too — check plugin_list_open_uis's `available`. `x`/`y` pin the window's " +
      "TOP-LEFT origin in screen points (omit for a deterministic cascade). " +
      "Reopening an already-open window just focuses it (`alreadyOpen:true`). " +
      "Returns {trackId, effectId?, title, component:{name, manufacturerName, " +
      "isV3}, body (\"generic\" = the system parameter view, normal for Apple " +
      "stock units; \"custom\" = the plugin's own vendor view), alreadyOpen, " +
      "frame:{x,y,width,height} (top-left-origin screen points — feed these to " +
      "debug.captureUI target:\"plugin\" for a deterministic screenshot), " +
      "warning?}.",
    inputSchema: {
      trackId: z
        .string()
        .uuid()
        .describe("Id of the track hosting the Audio Unit, from project_snapshot."),
      effectId: z
        .string()
        .uuid()
        .optional()
        .describe(
          "Id of the AU insert effect to open — from fx_add's result or " +
            "project_snapshot's per-track `effects`. Omit to open the track's AU " +
            "INSTRUMENT window instead."
        ),
      x: z
        .number()
        .optional()
        .describe("Window top-left X in screen points. Omit for a deterministic cascade."),
      y: z
        .number()
        .optional()
        .describe("Window top-left Y in screen points (measured down from the screen top)."),
    },
  },
  async ({ trackId, effectId, x, y }) =>
    toToolResult(() => bridge.send("plugin.openUI", { trackId, effectId, x, y }))
);

server.registerTool(
  "plugin_close_ui",
  {
    title: "Close an Audio Unit plugin's window",
    description:
      "Close the floating plugin window for a track's AU instrument (omit " +
      "effectId) or one AU insert effect (pass effectId). Idempotent and " +
      "syntax-only: closing a target whose window isn't open (or was already " +
      "auto-closed when the instrument/effect was removed) is NOT an error — it " +
      "returns {closed:false}. Returns {closed:true} when a window was open and " +
      "is now closed. A headless control session errors readably (no UI to close).",
    inputSchema: {
      trackId: z.string().uuid().describe("Id of the track hosting the Audio Unit."),
      effectId: z
        .string()
        .uuid()
        .optional()
        .describe("Id of the AU insert effect. Omit to close the AU instrument window."),
    },
  },
  async ({ trackId, effectId }) =>
    toToolResult(() => bridge.send("plugin.closeUI", { trackId, effectId }))
);

server.registerTool(
  "plugin_list_open_uis",
  {
    title: "List open Audio Unit plugin windows",
    description:
      "List every Audio Unit plugin window currently open. No params, never " +
      "errors. Returns {available, windows:[...]}: `available:false` (with an " +
      "empty `windows`) means THIS control session has no app UI — the DAW is " +
      "running headless, so plugin_open_ui can't materialize a window; launch " +
      "the app/DAWPro.app to get windows. Each `windows` entry is the same shape " +
      "plugin_open_ui returns (trackId, effectId?, title, component, body, " +
      "frame, warning?), ordered by open sequence.",
  },
  async () => toToolResult(() => bridge.send("plugin.listOpenUIs"))
);

server.registerTool(
  "fx_remove",
  {
    title: "Remove an effect from a track or bus's insert chain",
    description:
      "Permanently remove an effect from a track or bus's insert chain by id, shifting " +
      "later effects up to fill the gap. Reversible with edit_undo. Never interrupts or " +
      "glitches playback. Returns the track's full updated insert chain (`effects`, " +
      "same shape as project_snapshot).",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track or bus that owns the effect, from project_snapshot."),
      effectId: z
        .string()
        .min(1)
        .describe("Id of the effect to remove, from fx_add's result or project_snapshot."),
    },
  },
  async ({ trackId, effectId }) => toToolResult(() => bridge.send("fx.remove", { trackId, effectId }))
);

server.registerTool(
  "fx_reorder",
  {
    title: "Move an effect within a track or bus's insert chain",
    description:
      "Move an existing effect to a new position within its track or bus's insert " +
      "chain. Array order IS processing order, so reordering changes what the signal " +
      "actually hears — e.g. moving an EQ before vs. after a compressor sounds " +
      "different. `index` is the new zero-based position; out-of-range values clamp " +
      "into range rather than erroring. Never interrupts or glitches playback. Returns " +
      "the track's full updated insert chain (`effects`, same shape as project_snapshot).",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track or bus that owns the effect, from project_snapshot."),
      effectId: z
        .string()
        .min(1)
        .describe("Id of the effect to move, from fx_add's result or project_snapshot."),
      index: z
        .number()
        .int()
        .min(0)
        .describe(
          "New zero-based position for the effect in the chain, 0 = processed first. " +
            "Out-of-range values clamp to the nearest valid position. Required."
        ),
    },
  },
  async ({ trackId, effectId, index }) =>
    toToolResult(() => bridge.send("fx.reorder", { trackId, effectId, index }))
);

server.registerTool(
  "fx_set_bypass",
  {
    title: "Bypass or re-enable an effect",
    description:
      "Bypass (temporarily disable, passing audio through unprocessed) or re-enable an " +
      "effect already in a track or bus's insert chain, without removing it from the " +
      "chain or losing its parameter values — use this to A/B an effect's contribution. " +
      "Bypass takes effect INSTANTLY and never interrupts or glitches playback. Returns " +
      "the track's full updated insert chain (`effects`, same shape as project_snapshot).",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track or bus that owns the effect, from project_snapshot."),
      effectId: z
        .string()
        .min(1)
        .describe("Id of the effect to bypass/re-enable, from fx_add's result or project_snapshot."),
      bypassed: z.boolean().describe("True to bypass (disable) the effect, false to re-enable it."),
    },
  },
  async ({ trackId, effectId, bypassed }) =>
    toToolResult(() => bridge.send("fx.setBypass", { trackId, effectId, bypassed }))
);

server.registerTool(
  "fx_set_param",
  {
    title: "Set an effect parameter",
    description:
      "Change one parameter, by name, of an effect already in a track or bus's insert " +
      "chain — the way to ride an FX knob (e.g. turning up a gain stage's `gain`, tightening " +
      "a compressor's `ratio`, or pulling down a limiter's `ceilingDb`). " +
      "Parameter names, ranges, defaults, and units are discoverable per effect kind via " +
      "fx_describe — pass the exact `name` it lists. Out-of-range `value`s clamp to the " +
      "parameter's valid range rather than erroring. Edits apply LIVE, in place, without " +
      "interrupting or glitching playback. Returns the track's full updated insert chain " +
      "(`effects`, same shape as project_snapshot).",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track or bus that owns the effect, from project_snapshot."),
      effectId: z
        .string()
        .min(1)
        .describe("Id of the effect to change, from fx_add's result or project_snapshot."),
      name: z
        .string()
        .min(1)
        .describe("Parameter name, exactly as listed by fx_describe for this effect's kind."),
      value: z
        .number()
        .describe(
          "New parameter value. Out-of-range values clamp to the parameter's valid range " +
            "— see fx_describe for that range."
        ),
    },
  },
  async ({ trackId, effectId, name, value }) =>
    toToolResult(() => bridge.send("fx.setParam", { trackId, effectId, name, value }))
);

server.registerTool(
  "fx_describe",
  {
    title: "List effect kinds and their parameters",
    description:
      "Look up the parameter schema for one or every available effect kind — the " +
      "reference for fx_add's `params` and fx_set_param's `name`/`value`. Returns, per " +
      "kind, its parameter list as `{name, min, max, default, unit}` (`unit` is a short " +
      "human label, e.g. \"linear gain\", \"dB\", \"Hz\", \"ms\", \"seconds\"). Omit `kind` " +
      "to list every available kind at once. Available kinds: `gain` (simple linear " +
      "gain stage), `eq` (4-band parametric — low shelf, two peaking bands, high shelf), " +
      "`compressor` (soft-knee, stereo-linked dynamics), `limiter` (lookahead " +
      "brick-wall, adds 5 ms latency — see project_snapshot's per-effect `latencySamples`), " +
      "`reverb` (Freeverb-style room — roomSize/damping/mix/preDelayMs/width), `delay` " +
      "(stereo echo — timeMs/feedback/mix/pingPong/highCutHz), `saturator` (tanh drive " +
      "color — driveDb/mix/outputDb), `gate` (noise gate — thresholdDb/attackMs/holdMs/" +
      "releaseMs), and `chorus` (2-voice modulated thickener — rateHz/depthMs/mix).",
    inputSchema: {
      kind: fxKindSchema.optional().describe("Effect kind to describe. Omit to list every available kind."),
    },
  },
  async ({ kind }) => toToolResult(() => bridge.send("fx.describe", { kind }))
);

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

server.registerTool(
  "input_list_devices",
  {
    title: "List audio input devices",
    description:
      "List the Mac's available audio input devices (built-in microphone, " +
      "USB microphones, audio interfaces, etc). Each entry has `uid` (stable " +
      "identifier to pass to input_set_device), `name`, `sampleRate` (Hz), " +
      "`channelCount`, and `isDefault` (true for the system's current default " +
      "input). No params. Call this before input_set_device to find a " +
      "device's uid, or just to check what's available for recording.",
  },
  async () => toToolResult(() => bridge.send("input.listDevices"))
);

server.registerTool(
  "input_set_device",
  {
    title: "Pin the recording input device",
    description:
      "Pin recording to a specific audio input device by uid (from " +
      "input_list_devices), overriding the system default input. Takes " +
      "effect on the next transport_record — it does not affect a recording " +
      "already in progress, and cannot be changed while recording. Omit " +
      "`uid` (or pass nothing) to clear the pin and go back to following the " +
      "Mac's system default input device.",
    inputSchema: {
      uid: z
        .string()
        .min(1)
        .optional()
        .describe(
          "Uid of the input device to pin, from input_list_devices. Omit to " +
            "revert to the system default input device."
        ),
    },
  },
  async ({ uid }) => toToolResult(() => bridge.send("input.setDevice", { uid: uid ?? null }))
);

// ---------------------------------------------------------------------------
// Clips
// ---------------------------------------------------------------------------

/**
 * Shared shape for a single MIDI note within a clip's `notes` array, used by
 * clip_add_midi and clip_set_notes. Every note lives on ONE clip; startBeat is
 * relative to the clip's own start, not the timeline.
 */
const noteSchema = z.object({
  pitch: z
    .number()
    .int()
    .min(0)
    .max(127)
    .describe("MIDI pitch number, 0-127 (60 = middle C, 69 = A4/440Hz)."),
  velocity: z
    .number()
    .int()
    .min(1)
    .max(127)
    .optional()
    .describe("Note-on velocity (loudness/intensity), 1-127. Defaults to 100."),
  startBeat: z
    .number()
    .min(0)
    .describe(
      "Note start position in beats (quarter notes), RELATIVE TO THE CLIP'S START " +
        "(not the timeline). Must be >= 0."
    ),
  lengthBeats: z
    .number()
    .positive()
    .optional()
    .describe("Note duration in beats. Must be > 0. Defaults to 1 beat."),
  id: z
    .string()
    .uuid()
    .optional()
    .describe(
      "Note id (uuid). Omit when creating new notes — the server mints one; " +
        "include an existing note's id when resubmitting it unchanged via clip_set_notes."
    ),
});

server.registerTool(
  "clip_add_audio",
  {
    title: "Import an audio file as a clip",
    description:
      "Import an audio file (wav, aiff, mp3, or m4a) as a new clip on an audio " +
      "track. The clip's length is computed automatically from the file's " +
      "duration at the current project tempo — you don't need to pass a length. " +
      "Instrument and bus tracks reject audio clips; use track_add or " +
      "project_snapshot to find/create an `audio` track first. Returns the " +
      "created clip (id, name, startBeat, lengthBeats).",
    inputSchema: {
      trackId: z
        .string()
        .min(1)
        .describe("Id of the audio track to add the clip to, from project_snapshot or track_add."),
      path: z
        .string()
        .min(1)
        .describe("Absolute path to an audio file on this Mac (wav, aiff, mp3, or m4a)."),
      atBeat: z
        .number()
        .min(0)
        .optional()
        .describe(
          "Timeline position in beats (quarter notes) to place the clip's start. " +
            "Must be >= 0. Omit to append the clip after the track's existing clips."
        ),
    },
  },
  async ({ trackId, path, atBeat }) =>
    toToolResult(() => bridge.send("clip.addAudio", { trackId, path, atBeat }))
);

server.registerTool(
  "clip_add_midi",
  {
    title: "Create a MIDI clip with notes",
    description:
      "Create a MIDI clip on an INSTRUMENT track (see track_add with " +
      "kind=instrument) and write its notes in one call — the way to " +
      "compose a whole melody, riff, or chord progression at once. Each " +
      "note carries `pitch` (MIDI number, 0-127; 60 = middle C), `velocity` " +
      "(1-127, defaults to 100), `startBeat` (RELATIVE TO THE CLIP'S START, " +
      "not the timeline), and `lengthBeats` (defaults to 1 beat). Audio and " +
      "bus tracks reject MIDI clips. Returns the created clip with " +
      "server-minted note ids and the notes normalized and sorted by " +
      "startBeat. NOTE: MIDI clips are silent until an instrument is wired " +
      "up (M3) — the data model and editing already work, so compose freely " +
      "now and expect sound once an instrument lands.",
    inputSchema: {
      trackId: z
        .string()
        .min(1)
        .describe("Id of the instrument track to add the clip to, from project_snapshot or track_add."),
      name: z.string().min(1).optional().describe("Display name for the clip. Defaults to a generic name."),
      atBeat: z
        .number()
        .min(0)
        .optional()
        .describe(
          "Timeline position in beats (quarter notes) to place the clip's start. " +
            "Must be >= 0. Omit to append the clip after the track's existing clips."
        ),
      lengthBeats: z
        .number()
        .positive()
        .optional()
        .describe(
          "Clip length in beats. Must be > 0. Omit to default to fit the notes " +
            "(spanning from the earliest note start to the latest note end)."
        ),
      notes: z
        .array(noteSchema)
        .max(4096)
        .optional()
        .describe(
          "Notes to write into the clip, up to 4096. Each note's startBeat is " +
            "relative to the clip's own start. Omit (or pass an empty array) to " +
            "create an empty MIDI clip."
        ),
    },
  },
  async ({ trackId, name, atBeat, lengthBeats, notes }) =>
    toToolResult(() => bridge.send("clip.addMIDI", { trackId, name, atBeat, lengthBeats, notes }))
);

server.registerTool(
  "clip_set_notes",
  {
    title: "Replace a MIDI clip's notes",
    description:
      "Replace a MIDI clip's ENTIRE note array — the only note-editing " +
      "primitive. There is no add/remove-single-note tool: read the " +
      "clip's current `notes` from project_snapshot, modify the array " +
      "(add, remove, or change notes) in your own code, then resubmit the " +
      "whole array here. One call = one undo step (edit_undo reverts the " +
      "entire replacement). `notes` may be empty to clear the clip. Errors " +
      "readably if `clipId` refers to an audio clip (audio clips have no " +
      "notes).",
    inputSchema: {
      clipId: z.string().uuid().describe("Id of the MIDI clip to edit, from project_snapshot."),
      notes: z
        .array(noteSchema)
        .max(4096)
        .describe(
          "The clip's complete new note array (replaces all existing notes), up " +
            "to 4096 entries. Pass an empty array to remove all notes."
        ),
    },
  },
  async ({ clipId, notes }) => toToolResult(() => bridge.send("clip.setNotes", { clipId, notes }))
);

server.registerTool(
  "clip_remove",
  {
    title: "Remove a clip",
    description:
      "Permanently remove a clip — audio or MIDI — from its track by id. " +
      "Reversible with edit_undo. Returns the removed clip.",
    inputSchema: {
      clipId: z.string().uuid().describe("Id of the clip to remove, from project_snapshot."),
    },
  },
  async ({ clipId }) => toToolResult(() => bridge.send("clip.remove", { clipId }))
);

const fadeCurveSchema = z
  .enum(["linear", "equalPower"])
  .describe(
    "`linear` ramps the fade straight (constant slope). `equalPower` shapes it as a " +
      "quarter sine/cosine — RECOMMENDED for crossfades (two adjacent, opposite " +
      "equalPower fades sum to unit power, avoiding the volume dip a linear crossfade " +
      "leaves at the midpoint) and generally more natural-sounding for audio fade-ins/" +
      "outs. Defaults to `linear` when omitted."
  );

server.registerTool(
  "clip_split",
  {
    title: "Split a clip in two at a beat",
    description:
      "Cut a clip into two independent clips at a TIMELINE beat — the core " +
      "arrangement-editing move for lifting out a section, tightening a phrase " +
      "boundary, or isolating a region to delete/move/re-gain on its own. `atBeat` " +
      "must fall STRICTLY inside the clip (not touching either edge) or the call " +
      "errors readably. The left half keeps the original clip's id; the right half " +
      "is a brand-new clip inserted immediately after it. For a MIDI clip, notes are " +
      "partitioned by start beat (a note straddling the cut is truncated into the " +
      "left half); for an audio clip, the right half's source offset advances so it " +
      "keeps playing the correct region of the file. Fades: the left half keeps its " +
      "fade-in and loses its fade-out; the right half gains a zero fade-in and keeps " +
      "the original fade-out. One call = one undo step (edit_undo restores the single " +
      "original clip). Returns `{first, second}`, the two resulting clips.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track that owns the clip, from project_snapshot."),
      clipId: z.string().uuid().describe("Id of the clip to split, from project_snapshot."),
      atBeat: z
        .number()
        .describe(
          "Timeline position in beats (quarter notes) to cut at. Must fall strictly " +
            "inside the clip's span [startBeat, startBeat + lengthBeats] — splitting at " +
            "or beyond either edge errors readably instead of producing an empty clip."
        ),
    },
  },
  async ({ trackId, clipId, atBeat }) =>
    toToolResult(() => bridge.send("clip.split", { trackId, clipId, atBeat }))
);

server.registerTool(
  "clip_trim",
  {
    title: "Trim a clip's start/end (ripple its visible window)",
    description:
      "Change a clip's visible timeline window to `[newStartBeat, newStartBeat + " +
      "newLengthBeats]` while its underlying content (audio source position or MIDI " +
      "note timing) stays fixed — the classic drag-the-clip-edge move, usable on " +
      "either end (move `newStartBeat` inward to trim the head, shrink " +
      "`newLengthBeats` to trim the tail). For audio, the source playback offset " +
      "shifts so the clip keeps sounding the right region of the file. For MIDI, " +
      "notes that fall wholly outside the new window are dropped and notes crossing " +
      "an edge are truncated. Fades re-clamp proportionally to the new (possibly " +
      "shorter) length. The clip id is preserved. Repeated calls while dragging the " +
      "same edge coalesce into one undo step. Returns the updated clip.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track that owns the clip, from project_snapshot."),
      clipId: z.string().uuid().describe("Id of the clip to trim, from project_snapshot."),
      newStartBeat: z
        .number()
        .describe("New timeline start in beats (quarter notes). Clamped to >= 0."),
      newLengthBeats: z
        .number()
        .describe(
          "New clip length in beats. Clamped to a minimum of 1/32 beat (a 128th note " +
            "in 4/4) — a clip can never collapse to zero length."
        ),
    },
  },
  async ({ trackId, clipId, newStartBeat, newLengthBeats }) =>
    toToolResult(() => bridge.send("clip.trim", { trackId, clipId, newStartBeat, newLengthBeats }))
);

server.registerTool(
  "clip_move",
  {
    title: "Move a clip to a new timeline position",
    description:
      "Slide a clip to a new timeline start beat WITHOUT changing its length or " +
      "content — same-track only in v0 (moving a clip onto a different track isn't " +
      "supported yet). Use this for rearranging a section without resizing it; use " +
      "clip_trim instead when you want to change what's audible at an edge. " +
      "Repeated calls while dragging the same clip coalesce into one undo step. " +
      "Returns the updated clip.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track that owns the clip, from project_snapshot."),
      clipId: z.string().uuid().describe("Id of the clip to move, from project_snapshot."),
      toStartBeat: z
        .number()
        .describe("New timeline start in beats (quarter notes). Clamped to >= 0."),
    },
  },
  async ({ trackId, clipId, toStartBeat }) =>
    toToolResult(() => bridge.send("clip.move", { trackId, clipId, toStartBeat }))
);

server.registerTool(
  "clip_set_gain",
  {
    title: "Set a clip's per-clip gain",
    description:
      "Set a clip's own gain trim in DECIBELS, applied on top of (in addition to) " +
      "its track's fader — use this to balance one clip against its neighbors on " +
      "the same track (e.g. quiet down one loud take, or push up a soft phrase) " +
      "without touching the track volume. Range -72..24 dB; 0 dB is unity (no " +
      "change). Repeated calls while scrubbing coalesce into one undo step. Returns " +
      "the updated clip.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track that owns the clip, from project_snapshot."),
      clipId: z.string().uuid().describe("Id of the clip to adjust, from project_snapshot."),
      gainDb: z
        .number()
        .describe("Clip gain in decibels. Clamped to -72..24; 0 = unity (no change)."),
    },
  },
  async ({ trackId, clipId, gainDb }) =>
    toToolResult(() => bridge.send("clip.setGain", { trackId, clipId, gainDb }))
);

server.registerTool(
  "clip_set_fades",
  {
    title: "Set a clip's fade-in/fade-out",
    description:
      "Set a clip's fade-in and fade-out lengths (in BEATS, measured from the " +
      "clip's own head/tail) and their curve shapes in one WHOLESALE call — the " +
      "way to soften a clip's edges, prevent clicks at a hard cut, or build a " +
      "crossfade against a neighboring clip (put a fade-OUT on the end of the " +
      "earlier clip and a matching fade-IN on the start of the later one, " +
      "overlapping their timeline spans). For crossfades, prefer `equalPower` on " +
      "both sides — it avoids the volume dip a `linear` crossfade leaves at the " +
      "midpoint. If `fadeInBeats + fadeOutBeats` exceeds the clip's length, both " +
      "are reduced proportionally (their ratio is preserved) so they never overlap. " +
      "Repeated calls while dragging a fade handle coalesce into one undo step. " +
      "Returns the updated clip.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track that owns the clip, from project_snapshot."),
      clipId: z.string().uuid().describe("Id of the clip to adjust, from project_snapshot."),
      fadeInBeats: z
        .number()
        .min(0)
        .describe("Fade-in length in beats, from the clip's start. Must be >= 0."),
      fadeOutBeats: z
        .number()
        .min(0)
        .describe("Fade-out length in beats, into the clip's end. Must be >= 0."),
      fadeInCurve: fadeCurveSchema.optional(),
      fadeOutCurve: fadeCurveSchema.optional(),
    },
  },
  async ({ trackId, clipId, fadeInBeats, fadeOutBeats, fadeInCurve, fadeOutCurve }) =>
    toToolResult(() =>
      bridge.send("clip.setFades", { trackId, clipId, fadeInBeats, fadeOutBeats, fadeInCurve, fadeOutCurve })
    )
);

server.registerTool(
  "clip_set_stretch",
  {
    title: "Set a clip's time-stretch / pitch-shift",
    description:
      "Set an audio clip's time-stretch and/or pitch-shift parameters DIRECTLY " +
      "(offline, non-destructive — the source file is never modified). `ratio` is " +
      "the ABSOLUTE, tempo-independent output-time multiplier: 2.0 makes the clip " +
      "play twice as long (half speed), 0.5 half as long (double speed), 1.0 = no " +
      "stretch. It does NOT change the clip's timeline length — it changes how much " +
      "source material that length reads; use clip_stretch_to_length instead when " +
      "you want to drag the clip to a specific number of beats. `semitones` shifts " +
      "pitch independently of time (+12 = up one octave, -12 = down). Set " +
      "`formantPreserve` true when pitch-shifting a VOICE so it doesn't chipmunk. " +
      "Ranges: ratio 0.25..4, semitones -24..24 (both clamped). QUALITY: stretching " +
      "is transparent-ish in the 0.75..1.5 ratio sweet spot; further out it still " +
      "works but smears transients. Every argument is OPTIONAL — an omitted field " +
      "keeps the clip's current value. AUDIO CLIPS ONLY (a MIDI clip is rejected). " +
      "Rendering is ASYNCHRONOUS: after a large change the clip may be briefly " +
      "SILENT while the engine renders — poll project_snapshot's per-clip " +
      "`stretchRendering` flag (this lands with the ii-d engine wire; the parameters " +
      "persist now). Returns the updated clip.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track that owns the clip, from project_snapshot."),
      clipId: z.string().uuid().describe("Id of the AUDIO clip to stretch, from project_snapshot."),
      ratio: z
        .number()
        .min(0.25)
        .max(4)
        .optional()
        .describe(
          "Absolute output-time multiplier (2.0 = twice as long / half speed, 0.5 = " +
            "half as long / double speed, 1.0 = none). Clamped to 0.25..4; the " +
            "0.75..1.5 band is the transparent sweet spot. Omit to keep the current ratio."
        ),
      semitones: z
        .number()
        .min(-24)
        .max(24)
        .optional()
        .describe(
          "Pitch shift in semitones, independent of time (+12 = up an octave). " +
            "Clamped to -24..24. Omit to keep the current pitch shift."
        ),
      formantPreserve: z
        .boolean()
        .optional()
        .describe(
          "Keep formants at the source position while pitch-shifting (vocal mode) so a " +
            "shifted voice stays natural. Omit to keep the current setting."
        ),
    },
  },
  async ({ trackId, clipId, ratio, semitones, formantPreserve }) =>
    toToolResult(() => bridge.send("clip.setStretch", { trackId, clipId, ratio, semitones, formantPreserve }))
);

server.registerTool(
  "clip_stretch_to_length",
  {
    title: "Stretch a clip to a new timeline length (handle drag)",
    description:
      "Time-stretch an AUDIO clip so it fills a new timeline length in BEATS while " +
      "reading the SAME source material — the classic drag-the-stretch-handle move. " +
      "This is the length-linked counterpart to clip_set_stretch: it sets the clip's " +
      "length to `lengthBeats` AND scales its stretch ratio by the same factor, so " +
      "the window of source audio the clip plays stays exactly the same (only its " +
      "speed changes). Contrast clip_trim, which changes the audible length at a " +
      "FIXED speed (revealing/hiding source). Doubling the length halves the speed " +
      "(ratio doubles); halving it doubles the speed. The resulting ratio is clamped " +
      "to 0.25..4 (if the clamp bites, the final length is re-derived to keep the " +
      "source window intact). Fades re-clamp to the new length. AUDIO CLIPS ONLY. " +
      "Like clip_set_stretch, rendering is asynchronous — the clip may be briefly " +
      "silent after a big change (poll project_snapshot's `stretchRendering` once the " +
      "ii-d engine wire lands). Returns the updated clip.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track that owns the clip, from project_snapshot."),
      clipId: z.string().uuid().describe("Id of the AUDIO clip to stretch, from project_snapshot."),
      lengthBeats: z
        .number()
        .describe(
          "New timeline length in beats (quarter notes). Floored at 1/32 beat. The " +
            "clip's stretch ratio scales to match so it reads the same source window."
        ),
    },
  },
  async ({ trackId, clipId, lengthBeats }) =>
    toToolResult(() => bridge.send("clip.stretchToLength", { trackId, clipId, lengthBeats }))
);

server.registerTool(
  "clip_quantize",
  {
    title: "Quantize a MIDI clip's timing to the grid",
    description:
      "Snap a MIDI clip's note onsets toward a rhythmic GRID (destructive, but one " +
      "undo step reverts it). `gridBeats` is the grid resolution in BEATS (quarter " +
      "notes): 1 = 1/4 note, 0.5 = 1/8, 0.25 = 1/16, 0.125 = 1/32; use 2/3-scaled " +
      "values for triplets (~0.3333 = 1/8 triplet, ~0.1667 = 1/16 triplet). " +
      "`strength` (0..1, default 1) is HOW FAR each note moves toward its target slot: " +
      "1 snaps fully to the grid, 0.5 moves it exactly halfway (tightens the feel while " +
      "keeping human timing), 0 leaves it untouched. `swing` (50..75, MPC convention, " +
      "default 50) shuffles the feel by DELAYING the offbeat slots: 50 = straight, " +
      "66 ~ classic MPC groove, 75 = maximum (a half-grid late, a triplet-ish shuffle); " +
      "it is applied to the grid targets BEFORE the strength move. `quantizeEnds` " +
      "(default false) also snaps each note's END to the grid — otherwise note LENGTHS " +
      "are preserved and only onsets move (a note is never shortened below the minimum). " +
      "MIDI CLIPS ONLY in v0: an audio clip is rejected verbatim (audio quantize is a " +
      "later, separate op); a take-comp member clip is rejected (change the comp with " +
      "take_set_comp/take_select, or take_flatten first). Rapid re-quantizes on the " +
      "same clip (e.g. scrubbing strength) fold into ONE undo step. Returns the updated clip.",
    inputSchema: {
      clipId: z.string().uuid().describe("Id of the MIDI clip to quantize, from project_snapshot."),
      gridBeats: z
        .number()
        .positive()
        .describe(
          "Grid resolution in beats (quarter notes): 1 = 1/4 note, 0.5 = 1/8, 0.25 = " +
            "1/16, 0.125 = 1/32; ~0.3333 = 1/8 triplet. Must be > 0."
        ),
      strength: z
        .number()
        .min(0)
        .max(1)
        .optional()
        .describe(
          "How far each note moves toward the grid, 0..1 (default 1). 1 = snap fully, " +
            "0.5 = halfway (tighten but keep feel), 0 = leave notes where they are."
        ),
      swing: z
        .number()
        .min(50)
        .max(75)
        .optional()
        .describe(
          "MPC swing percent, 50..75 (default 50). 50 = straight; higher DELAYS the " +
            "offbeat slots — 66 ~ classic groove, 75 = max (a half-grid late)."
        ),
      quantizeEnds: z
        .boolean()
        .optional()
        .describe(
          "Also snap each note's END to the grid (default false = preserve note lengths, " +
            "move onsets only). The minimum note length is always kept."
        ),
      groove: z
        .string()
        .optional()
        .describe(
          "Optional GROOVE to quantize to instead of the straight/swing grid. Pass a " +
            "built-in swing name (swing8:54..75 or swing16:54..75, e.g. \"swing8:66\"), or a " +
            "saved groove template's id or name (see groove_list / groove_extract). A groove " +
            "REPLACES `swing` (groove wins). Use gridBeats matching the groove's grid " +
            "(1/8 for swing8, 1/16 for swing16) for musically-correct targets."
        ),
    },
  },
  async ({ clipId, gridBeats, strength, swing, quantizeEnds, groove }) =>
    toToolResult(() => bridge.send("clip.quantize", { clipId, gridBeats, strength, swing, quantizeEnds, groove }))
);

server.registerTool(
  "clip_humanize",
  {
    title: "Add human feel to a MIDI clip (seeded timing + velocity jitter)",
    description:
      "The inverse-spirited sibling of clip_quantize: instead of snapping a MIDI clip's " +
      "notes to the grid, nudge them slightly OFF it so they feel played rather than " +
      "programmed. Each note gets an INDEPENDENT random timing offset (up to ±`timingBeats` " +
      "beats) and an independent random velocity offset (up to ±`velocityRange`), applied " +
      "as ONE undoable step. Onsets are clamped to stay inside the clip and velocities to " +
      "1..127; note LENGTHS, ids, and order are preserved. The jitter is DETERMINISTIC and " +
      "SEEDED: pass a `seed` to get an exact, repeatable result, or omit it to draw a fresh " +
      "one. Either way the response includes `seedUsed` (the seed actually applied) alongside " +
      "the updated clip fields — feed that same value back as `seed` to reproduce this exact " +
      "take, or omit `seed` again to re-roll a different feel. MIDI CLIPS ONLY: an audio clip " +
      "is rejected. Returns the updated clip plus `seedUsed`.",
    inputSchema: {
      clipId: z.string().uuid().describe("Id of the MIDI clip to humanize, from project_snapshot."),
      timingBeats: z
        .number()
        .min(0)
        .max(0.25)
        .optional()
        .describe(
          "Maximum timing jitter in BEATS, 0..0.25 (default 0.02). Each note's onset shifts " +
            "by a uniform random amount in [-timingBeats, +timingBeats]. 0 = leave timing " +
            "untouched (velocity-only). 0.02 ~ a tight, natural feel; 0.05+ is looser."
        ),
      velocityRange: z
        .number()
        .int()
        .min(0)
        .max(64)
        .optional()
        .describe(
          "Maximum velocity jitter, an integer 0..64 (default 8). Each note's velocity shifts " +
            "by a uniform random integer in [-velocityRange, +velocityRange], clamped to 1..127. " +
            "0 = leave velocities untouched (timing-only). 8 ~ subtle dynamics; 20+ is dramatic."
        ),
      seed: z
        .number()
        .int()
        .min(0)
        .optional()
        .describe(
          "Optional non-negative integer seed for the deterministic jitter. Pass the same seed " +
            "(and same params) to reproduce an exact result; omit it to draw a random seed. The " +
            "seed actually used is always returned as `seedUsed` so you can reproduce or re-roll."
        ),
    },
  },
  async ({ clipId, timingBeats, velocityRange, seed }) =>
    toToolResult(() => bridge.send("clip.humanize", { clipId, timingBeats, velocityRange, seed }))
);

server.registerTool(
  "clip_detect_transients",
  {
    title: "Detect transient onsets in an audio clip",
    description:
      "Analyze an AUDIO clip's source file for TRANSIENTS (drum hits, note attacks, " +
      "word onsets) via offline spectral-flux detection. Read-only: nothing is edited, " +
      "no undo entry. Returns {transients: [{sourceSeconds, beat, strength}], count} — " +
      "only onsets inside the clip's current window, where `sourceSeconds` is the " +
      "onset's position within the SOURCE FILE (geometry-free: trimming/splitting the " +
      "clip never moves it), `beat` is the same onset mapped onto the timeline at the " +
      "current tempo/stretch, and `strength` (0..1) is the onset's prominence relative " +
      "to the file's strongest. `sensitivity` (0..1, default 0.5) tunes the detector: " +
      "low = only strong hits (clean drums), high = many onsets (ghost notes, legato " +
      "phrases; quiet/sustained material yields few onsets at any setting — that is " +
      "honest, not a bug). Results are cached per (file, sensitivity), so repeat calls " +
      "are instant until the file changes. AUDIO CLIPS ONLY — a MIDI clip is rejected " +
      "(its notes already carry onsets). Feeds the upcoming clip_quantize_audio and " +
      "groove extraction; also useful directly for finding slice points and hit timings.",
    inputSchema: {
      clipId: z.string().uuid().describe("Id of the AUDIO clip to analyze, from project_snapshot."),
      sensitivity: z
        .number()
        .min(0)
        .max(1)
        .optional()
        .describe(
          "Detector sensitivity 0..1 (default 0.5). Lower finds only strong hits; " +
            "higher finds more (and weaker) onsets."
        ),
    },
  },
  async ({ clipId, sensitivity }) =>
    toToolResult(() => bridge.send("clip.detectTransients", { clipId, sensitivity }))
);

server.registerTool(
  "clip_quantize_audio",
  {
    title: "Quantize an audio clip's timing to the grid (slice + nudge)",
    description:
      "Tighten an AUDIO clip's rhythm to a GRID by slicing it at its transients and " +
      "nudging each slice onto the grid (destructive, but ONE undo step reverts it). " +
      "This is the audio counterpart of clip_quantize: the clip is detected for onsets " +
      "(same engine as clip_detect_transients), cut into slices at each onset, and every " +
      "slice is moved so its onset lands on the grid; the gaps at the joins are filled " +
      "by the source continuing (NO time-stretch in v0 — slices play at natural speed) " +
      "with short equal-power CROSSFADES so the joins are seamless. `gridBeats` is the " +
      "grid in beats (1 = 1/4 note, 0.5 = 1/8, 0.25 = 1/16). `strength` (0..1, default 1) " +
      "is how far each slice moves toward its slot (1 = snap fully, 0.5 = halfway). " +
      "`swing` (50..75, default 50) delays the offbeat slots (MPC groove). `sensitivity` " +
      "(0..1, default 0.5) tunes onset detection (low = strong hits only, high = more " +
      "onsets). `crossfadeMs` (0..50, default 10) is the join crossfade width in " +
      "milliseconds. AUDIO CLIPS ONLY (a MIDI clip is rejected — use clip_quantize); a " +
      "time-STRETCHED clip is rejected (un-stretch or bounce it first — per-slice stretch " +
      "is a future feature); a take-comp member is rejected (change the comp or " +
      "take_flatten first); a clip with fewer than 2 detectable onsets is rejected " +
      "(nothing to quantize — raise sensitivity or pick a more percussive clip). Slices " +
      "never reorder. Returns {clips} — the head + slice clips that replaced the original.",
    inputSchema: {
      trackId: z.string().uuid().describe("Id of the track holding the clip, from project_snapshot."),
      clipId: z.string().uuid().describe("Id of the AUDIO clip to quantize, from project_snapshot."),
      gridBeats: z
        .number()
        .positive()
        .describe(
          "Grid resolution in beats: 1 = 1/4 note, 0.5 = 1/8, 0.25 = 1/16, 0.125 = 1/32. Must be > 0."
        ),
      strength: z
        .number()
        .min(0)
        .max(1)
        .optional()
        .describe(
          "How far each slice moves toward the grid, 0..1 (default 1). 1 = snap fully, " +
            "0.5 = halfway (tighten but keep feel), 0 = leave slices in place."
        ),
      swing: z
        .number()
        .min(50)
        .max(75)
        .optional()
        .describe(
          "MPC swing percent, 50..75 (default 50). 50 = straight; higher delays the offbeat slots."
        ),
      sensitivity: z
        .number()
        .min(0)
        .max(1)
        .optional()
        .describe(
          "Onset-detection sensitivity 0..1 (default 0.5). Lower = strong hits only; higher = more onsets."
        ),
      crossfadeMs: z
        .number()
        .min(0)
        .max(50)
        .optional()
        .describe("Join crossfade width in milliseconds, 0..50 (default 10)."),
      groove: z
        .string()
        .optional()
        .describe(
          "Optional GROOVE to quantize to instead of the straight/swing grid. Pass a " +
            "built-in swing name (swing8:54..75 / swing16:54..75, e.g. \"swing8:66\") or a " +
            "saved template's id or name (see groove_list / groove_extract). Replaces `swing` " +
            "(groove wins); use gridBeats matching the groove's grid."
        ),
    },
  },
  async ({ trackId, clipId, gridBeats, strength, swing, sensitivity, crossfadeMs, groove }) =>
    toToolResult(() =>
      bridge.send("clip.quantizeAudio", {
        trackId,
        clipId,
        gridBeats,
        strength,
        swing,
        sensitivity,
        crossfadeMs,
        groove,
      })
    )
);

// ---------------------------------------------------------------------------
// Take comping (M5 iii-b)
//
// The model, in brief (see docs/ARCHITECTURE.md for the full spec): a TAKE
// GROUP lives on a track, out-of-band from its ordinary clips. It holds one
// or more LANES — each lane is a full alternate take (audio or MIDI) — plus a
// COMP: an ordered list of non-overlapping segments, each saying "play lane X
// from beat A to beat B". Gaps between segments are legal and read as
// silence. Every comp edit deterministically REBUILDS the group's MEMBER
// CLIPS (ordinary ids in project_snapshot's `clips`, marked with
// `takeGroupID`) — that's what actually plays. Member clips REJECT the
// normal per-clip edit tools (clip_trim, clip_move, clip_set_gain,
// clip_set_fades, clip_set_stretch, clip_stretch_to_length, clip_set_notes,
// clip_remove, clip_quantize) with a readable error telling you to change the
// comp (take_set_comp / take_select) or call take_flatten first — flattening
// dissolves the group, turning the CURRENT members into ordinary, fully
// editable clips (any non-comped lane material is discarded). Recording a
// take over an existing take's range auto-groups them (newest take wins the
// default comp) — this tool surface is how an agent then edits that group.
// ---------------------------------------------------------------------------

const compSegmentSchema = z.object({
  laneId: z
    .string()
    .uuid()
    .describe("Id of the lane (take) this segment plays, from take_group's result or project_snapshot."),
  startBeat: z.number().describe("Segment start, in ABSOLUTE timeline beats (not lane-relative)."),
  endBeat: z
    .number()
    .describe("Segment end, in ABSOLUTE timeline beats. Must be greater than startBeat."),
});

server.registerTool(
  "take_group",
  {
    title: "Group overlapping clips into a take group",
    description:
      "Turn >= 2 EXISTING, OVERLAPPING clips on one track into a take group so you " +
      "can comp between them instead of hearing them all sum together. All the " +
      "clips must be the same kind (all audio or all MIDI — mixed is rejected) and " +
      "must overlap in a connected chain (each one overlaps the running cluster). " +
      "The source clips are consumed: they're removed from the track's ordinary " +
      "clip list and become LANES inside the new group, oldest first. The comp " +
      "defaults to the NEWEST lane across the group's full range (the last-recorded " +
      "or last-listed take wins by default — the classic 'latest take is the keeper " +
      "until you say otherwise' behavior). Use take_set_comp/take_select afterward " +
      "to pick different lanes for different ranges, take_move to reposition the " +
      "whole group, take_set_crossfade to tune join smoothness, and take_flatten " +
      "when you're done comping and want ordinary clips back. Reversible with " +
      "edit_undo (one undo step). Returns `{group}`.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track that owns the clips, from project_snapshot."),
      clipIds: z
        .array(z.string().uuid())
        .min(2)
        .describe(
          "Ids of >= 2 existing, mutually overlapping clips on this track (all audio or " +
            "all MIDI) to consume into lanes, from project_snapshot."
        ),
      name: z
        .string()
        .optional()
        .describe("Display name for the group, e.g. \"Vocals Takes\". Defaults to \"<track name> Takes\"."),
    },
  },
  async ({ trackId, clipIds, name }) =>
    toToolResult(() => bridge.send("take.group", { trackId, clipIds, name }))
);

server.registerTool(
  "take_set_comp",
  {
    title: "Replace a take group's comp (which lane plays where)",
    description:
      "Replace a take group's ENTIRE comp — the ordered list of `{laneId, " +
      "startBeat, endBeat}` segments that says which lane (take) plays over which " +
      "ABSOLUTE-beat range — in one WHOLESALE call (the clip_set_notes precedent: " +
      "no add/remove-single-segment tool). Segments must be non-overlapping and " +
      "each `endBeat` must exceed its `startBeat`; every `laneId` must belong to " +
      "this group. Segments are clamped to the group's range (the union of its " +
      "lanes' extents) and GAPS ARE LEGAL — a beat range with no covering segment " +
      "plays as silence, which is how you carve out a bad phrase from every take. " +
      "This is the paint-a-comp primitive: read the group from project_snapshot " +
      "(or take_group's/a previous take_*'s result), decide which lane sounds best " +
      "over which range, and submit the full segment list. Every call REBUILDS the " +
      "group's member clips from scratch (fresh clip ids each time — expected " +
      "churn, not a bug). Repeated calls while comp-painting a drag coalesce into " +
      "one undo step. Returns `{group, clips}` — the group and its freshly " +
      "rebuilt member clips.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track that owns the group, from project_snapshot."),
      groupId: z
        .string()
        .uuid()
        .describe("Id of the take group to edit, from take_group's result or project_snapshot."),
      segments: z
        .array(compSegmentSchema)
        .describe(
          "The comp's complete new segment list (WHOLE-ARRAY replace), sorted or not " +
            "(the store sorts them) but non-overlapping once sorted."
        ),
    },
  },
  async ({ trackId, groupId, segments }) =>
    toToolResult(() => bridge.send("take.setComp", { trackId, groupId, segments }))
);

server.registerTool(
  "take_select",
  {
    title: "Swap a take group's comp to one whole lane (quick take pick)",
    description:
      "Sugar for the common case of auditioning or committing to ONE lane across " +
      "the group's whole range: sets the comp to a single full-range segment on " +
      "`laneId`, equivalent to calling take_set_comp with one segment spanning the " +
      "group's entire extent. Use this for 'just play take 3 all the way through' " +
      "before reaching for take_set_comp's per-range picking. Shares take_set_comp's " +
      "undo-coalescing, so repeated quick swaps while auditioning collapse into one " +
      "undo step. Returns `{group, clips}`.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track that owns the group, from project_snapshot."),
      groupId: z
        .string()
        .uuid()
        .describe("Id of the take group, from take_group's result or project_snapshot."),
      laneId: z
        .string()
        .uuid()
        .describe("Id of the lane (take) to select for the whole group range."),
    },
  },
  async ({ trackId, groupId, laneId }) =>
    toToolResult(() => bridge.send("take.select", { trackId, groupId, laneId }))
);

server.registerTool(
  "take_remove_lane",
  {
    title: "Delete an unused take from a group",
    description:
      "Permanently delete one lane (take) from a group — for discarding a take you " +
      "know you'll never use. REJECTED while any comp segment still references the " +
      "lane (change the comp first with take_set_comp/take_select) and when it's " +
      "the LAST lane in the group (use take_flatten to dissolve the group instead " +
      "of trying to empty it). Reversible with edit_undo. Returns `{group}`.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track that owns the group, from project_snapshot."),
      groupId: z
        .string()
        .uuid()
        .describe("Id of the take group, from take_group's result or project_snapshot."),
      laneId: z.string().uuid().describe("Id of the lane (take) to delete. Must be unused by the comp."),
    },
  },
  async ({ trackId, groupId, laneId }) =>
    toToolResult(() => bridge.send("take.removeLane", { trackId, groupId, laneId }))
);

server.registerTool(
  "take_flatten",
  {
    title: "Dissolve a take group into ordinary clips",
    description:
      "The escape hatch out of take comping: dissolve the group entirely. Its " +
      "CURRENT member clips (whatever the comp currently plays) stay in place as " +
      "ORDINARY clips — full editability restored, so clip_trim/clip_move/" +
      "clip_set_gain/clip_set_fades/clip_set_stretch/clip_set_notes/clip_remove/" +
      "clip_quantize all work on them again. Any lane material NOT currently in " +
      "the comp is discarded (its audio files remain on disk; only the take-group " +
      "bookkeeping goes away). Do this once you've settled on a comp and want to " +
      "keep editing the result normally, or before applying an edit tool that a " +
      "member clip would otherwise reject. Reversible with edit_undo (restores the " +
      "group and every lane). Returns `{clips}`, the freed clips.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track that owns the group, from project_snapshot."),
      groupId: z
        .string()
        .uuid()
        .describe("Id of the take group to dissolve, from take_group's result or project_snapshot."),
    },
  },
  async ({ trackId, groupId }) => toToolResult(() => bridge.send("take.flatten", { trackId, groupId }))
);

server.registerTool(
  "take_move",
  {
    title: "Move a whole take group to a new timeline position",
    description:
      "Shift an ENTIRE take group — every lane, the comp's segment beats, and the " +
      "resulting member clips — together, so its range starts at `toStartBeat`. " +
      "Use this to reposition a comped section as one rigid unit instead of moving " +
      "clips individually (which member clips would reject anyway). Clamped to >= " +
      "0. Repeated calls while dragging coalesce into one undo step. Returns " +
      "`{group, clips}`.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track that owns the group, from project_snapshot."),
      groupId: z
        .string()
        .uuid()
        .describe("Id of the take group to move, from take_group's result or project_snapshot."),
      toStartBeat: z
        .number()
        .describe("New timeline start in beats (quarter notes) for the group's range. Clamped to >= 0."),
    },
  },
  async ({ trackId, groupId, toStartBeat }) =>
    toToolResult(() => bridge.send("take.move", { trackId, groupId, toStartBeat }))
);

server.registerTool(
  "take_set_crossfade",
  {
    title: "Set a take group's comp-join crossfade width",
    description:
      "Set how wide (in SECONDS) the equal-power crossfade is at each place two " +
      "comp segments abut back-to-back (e.g. lane A ends exactly where lane B " +
      "begins) — smooths the splice so a take switch isn't an audible click or " +
      "hard cut. Clamped to 0..0.2 s; a wider request auto-clamps down further per " +
      "join if the neighboring segments or source material are too short to fit " +
      "it. Has no audible effect at gaps (silence) or MIDI joins (clean cuts, no " +
      "crossfade concept). Rebuilds the group's member clips. Returns `{group, " +
      "clips}`.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track that owns the group, from project_snapshot."),
      groupId: z
        .string()
        .uuid()
        .describe("Id of the take group, from take_group's result or project_snapshot."),
      seconds: z
        .number()
        .describe("Join crossfade width in seconds at abutting comp-segment boundaries. Clamped to 0..0.2."),
    },
  },
  async ({ trackId, groupId, seconds }) =>
    toToolResult(() => bridge.send("take.setCrossfade", { trackId, groupId, seconds }))
);

server.registerTool(
  "take_auto_align",
  {
    title: "Auto-align a take's onsets to the group's reference lane",
    description:
      "Onset-based micro-alignment: measure how far a take lane's note/word " +
      "onsets sit early or late versus the group's FIRST lane (the reference — " +
      "the original material; AI-fix lanes from ai_import_clip_fix land in " +
      "groups built that way), and nudge the take by MINUS that offset so its " +
      "phrasing locks to the reference. Detects onsets with the same detector " +
      "clip_detect_transients uses, over the overlap of the two lanes, searches " +
      "±searchWindowMs, and refines to sub-millisecond precision. Set apply=false " +
      "for a dry-run measurement (no change, no undo entry). INCONCLUSIVE cases " +
      "(fewer than 2 matching onsets, or non-overlapping lanes) error instead of " +
      "guessing — widen searchWindowMs or use take_move. Aligning lane 0 against " +
      "itself is rejected (it IS the reference). An apply that would push the " +
      "take before beat 0 (not enough timeline headroom for the earlier move) " +
      "errors instead of clamping — take_move the group later first, then " +
      "align. Applying is one undo step. " +
      "Returns the report: `{offsetMs, offsetBeats, matchedOnsets, " +
      "referenceOnsets, candidateOnsets, confidence, applied}` (positive " +
      "offsetMs = the take was late).",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track that owns the group, from project_snapshot."),
      groupId: z
        .string()
        .uuid()
        .describe("Id of the take group, from take_group's result or project_snapshot."),
      laneId: z
        .string()
        .uuid()
        .describe(
          "Id of the lane (take) to align — e.g. an 'AI Fix N' lane from " +
            "ai_import_clip_fix. Must not be the group's first (reference) lane."
        ),
      searchWindowMs: z
        .number()
        .min(10)
        .max(500)
        .optional()
        .describe(
          "± search window in milliseconds around the take's current position " +
            "(10..500, default 150). Widen it if alignment comes back inconclusive."
        ),
      apply: z
        .boolean()
        .optional()
        .describe(
          "true (default) moves the take by the measured offset in one undo step; " +
            "false only measures and reports."
        ),
    },
  },
  async ({ trackId, groupId, laneId, searchWindowMs, apply }) =>
    toToolResult(() => bridge.send("take.autoAlign", { trackId, groupId, laneId, searchWindowMs, apply }))
);

// ---------------------------------------------------------------------------
// Groove templates (M5 iii-g)
//
// A GROOVE is a small per-slot TIMING-OFFSET table — how far, in beats, each
// grid slot deviates from the straight grid — extracted from the feel of a
// performance (a MIDI clip's note onsets, or an audio clip's detected
// transients). Save a groove, then quantize other clips TO it via the `groove`
// param on clip_quantize / clip_quantize_audio (it replaces the straight/swing
// grid; groove wins over `swing`). Grooves are stored per project and applied
// BY VALUE, so deleting one never breaks a clip you already quantized. Built-in
// MPC swing presets (swing8:54..75, swing16:54..75) are always available by
// name without extracting anything.
// ---------------------------------------------------------------------------

server.registerTool(
  "groove_extract",
  {
    title: "Extract a groove template from a clip's feel",
    description:
      "Capture the TIMING FEEL of a clip as a reusable GROOVE (a per-slot offset " +
      "table) and save it to the project. From a MIDI clip it reads the note onsets; " +
      "from an AUDIO clip it detects the transients first (same engine as " +
      "clip_detect_transients). Each onset snaps to its nearest grid slot; the offsets " +
      "you played (ahead of / behind the grid) are AVERAGED per slot and folded into " +
      "the cycle, so the result is the characteristic push/lay-back of the take. Slots " +
      "with no onset read 0 (straight). `gridBeats` (default 0.25 = 1/16) is the slot " +
      "resolution the offsets are measured on; `cycleBeats` (default 4 = one bar at x/4) " +
      "is the pattern length that repeats. Onsets are read relative to the clip start, " +
      "so the groove is independent of where the clip sits. Reversible with edit_undo. " +
      "Then apply it via the `groove` param on clip_quantize / clip_quantize_audio " +
      "(pass the returned id or name). Returns {groove}.",
    inputSchema: {
      clipId: z
        .string()
        .uuid()
        .describe("Id of the clip (MIDI or audio) whose feel to capture, from project_snapshot."),
      name: z.string().min(1).describe("Display name for the saved groove, e.g. \"Verse drums feel\"."),
      gridBeats: z
        .number()
        .positive()
        .optional()
        .describe(
          "Slot resolution in beats the offsets are measured on (default 0.25 = 1/16; " +
            "0.5 = 1/8). Must be > 0."
        ),
      cycleBeats: z
        .number()
        .positive()
        .optional()
        .describe("Pattern length in beats that the groove repeats over (default 4 = one bar at x/4). Must be > 0."),
    },
  },
  async ({ clipId, name, gridBeats, cycleBeats }) =>
    toToolResult(() => bridge.send("groove.extract", { clipId, name, gridBeats, cycleBeats }))
);

server.registerTool(
  "groove_list",
  {
    title: "List saved groove templates and built-in swings",
    description:
      "List every GROOVE available for quantizing: the project's SAVED templates " +
      "(from groove_extract) plus the BUILT-IN MPC swing presets. Use a groove's id " +
      "or name as the `groove` param on clip_quantize / clip_quantize_audio. Built-in " +
      "swings are named swing8:P (1/8 grid) and swing16:P (1/16 grid) where P is the " +
      "swing percent 54..75 (50 = straight, 66 ~ classic MPC, 75 = max); the eight " +
      "canonical presets (54|58|62|66 x 8th|16th) are returned, and the full 54..75 " +
      "range resolves on demand by name. Returns {templates, builtins}.",
    inputSchema: {},
  },
  async () => toToolResult(() => bridge.send("groove.list", {}))
);

server.registerTool(
  "groove_remove",
  {
    title: "Delete a saved groove template",
    description:
      "Delete a SAVED groove template from the project by id (from groove_list / " +
      "groove_extract). Built-in swing presets aren't stored and can't be removed. " +
      "Clips you already quantized to this groove are unaffected — grooves apply by " +
      "value, so nothing dangles. Reversible with edit_undo. Returns {removed: true}.",
    inputSchema: {
      grooveId: z.string().uuid().describe("Id of the saved groove template to delete, from groove_list."),
    },
  },
  async ({ grooveId }) => toToolResult(() => bridge.send("groove.remove", { grooveId }))
);

// ---------------------------------------------------------------------------
// Mixer
// ---------------------------------------------------------------------------

server.registerTool(
  "mixer_set_master_volume",
  {
    title: "Set master volume",
    description:
      "Set the master output gain of the whole mix, as a linear gain multiplier, " +
      "where 1.0 is unity gain (0 dB, no change). Range 0-2: 0 is silence, 1 is " +
      "unity, 2 is roughly +6 dB. This is linear gain, not decibels. To set an " +
      "individual track's gain instead, use track_set_volume.",
    inputSchema: {
      volume: z
        .number()
        .min(0)
        .max(2)
        .describe("Linear master gain, 0-2, where 0 = silence, 1 = unity gain (0 dB), 2 = +6 dB."),
    },
  },
  async ({ volume }) => toToolResult(() => bridge.send("mixer.setMasterVolume", { volume }))
);

const mixerPresetSchema = z
  .enum([
    "drum-bus-glue",
    "vocal-presence",
    "bass-tight",
    "master-glue",
    "warm-keys",
    "clean-boost",
  ])
  .describe(
    "Which curated mixer preset to apply — each is a small, ready-made insert chain of " +
      "built-in effects. `drum-bus-glue`: gentle ~4:1 compression plus a touch of low-end " +
      "weight and upper-mid snap, to glue a drum group into one punchy kit. `vocal-presence`: " +
      "an EQ that cuts low rumble, lifts presence around 3 kHz and adds air, then ~3:1 " +
      "compression — makes a lead vocal sit forward and clear. `bass-tight`: an EQ trimming " +
      "sub rumble and low-mid mud, then firm ~4:1 fast compression — keeps a bass part steady " +
      "and defined. `master-glue`: light ~2:1 compression then a -1 dB brick-wall limiter — " +
      "ties a whole mix together and holds the peaks just under clipping (use on the master or " +
      "a mix bus). `warm-keys`: EQ only — eases off the top end and adds a little low-end body " +
      "for a warmer keyboard/synth tone. `clean-boost`: a single gain stage at about +3 dB " +
      "with no tone change — a clean level lift."
  );

server.registerTool(
  "mixer_apply_preset",
  {
    title: "Apply a curated mixer preset to a track or bus",
    description:
      "Apply a named, ready-made mixer preset to one track or bus strip. The preset's insert " +
      "chain REPLACES the strip's current insert chain wholesale (any effects already there are " +
      "removed) as ONE undoable step — a single undo restores the exact previous chain. Presets " +
      "shape TONE only: the strip's volume, pan, and sends are left untouched. Works on audio, " +
      "instrument, and bus tracks. Choose `preset` from: drum-bus-glue (glue a drum group), " +
      "vocal-presence (forward, clear lead vocal), bass-tight (steady, defined bass), master-glue " +
      "(tie a whole mix together and stop it clipping), warm-keys (warmer, softer synth/keys tone), " +
      "clean-boost (a clean ~+3 dB level lift). To fine-tune afterwards, nudge individual effects " +
      "with fx_set_param, or build a chain by hand with fx_add. Returns `{trackId, effects}`: the " +
      "strip's full new insert chain (same shape as project_snapshot's per-track `effects` array), " +
      "so you can see exactly what the preset laid down.",
    inputSchema: {
      trackId: z
        .string()
        .min(1)
        .describe("Id of the track or bus to apply the preset to, from project_snapshot."),
      preset: mixerPresetSchema,
    },
  },
  async ({ trackId, preset }) =>
    toToolResult(() => bridge.send("mixer.applyPreset", { trackId, preset }))
);

server.registerTool(
  "mixer_master_analysis",
  {
    title: "Read the master-mix analysis snapshot (vibe meter)",
    description:
      "Read the latest real-time analysis snapshot of the WHOLE mix, measured on the master " +
      "bus AFTER the master fader — what the listener hears is exactly what is analyzed. " +
      "No params. Returns `{bands, levelDB, peakDB, centroidHz, flux}`: `bands` is 24 " +
      "log-spaced frequency bands from 40 Hz to 16 kHz, each an energy value in dB with a " +
      "floor of -80 (band 0 is the lowest sub-bass, band 23 the highest treble — useful to " +
      "judge tonal balance, e.g. too much low end vs. not enough air). `levelDB` is the " +
      "short-term RMS level in dB (floor -80) — a quick 'how loud right now' reading, NOT " +
      "gated LUFS; for mastering-grade loudness use render_measure_loudness instead. " +
      "`peakDB` is the held sample peak in dB (-80 floor, ~20 dB/s release). `centroidHz` " +
      "is the spectral centroid in Hz — perceived brightness (higher = brighter/harsher, " +
      "lower = darker/warmer; 0 when silent). `flux` is normalized spectral flux 0-1 — how " +
      "much the spectrum is MOVING between frames (0 = silence or a steady drone, higher = " +
      "busy, percussive, changing material). The snapshot refreshes at roughly 30-60 Hz " +
      "while the engine runs; poll it repeatedly (e.g. once a second during playback) to " +
      "watch the mix evolve. When the transport is stopped or the session is silent, every " +
      "value decays to its floor (-80 dB bands/levels, centroid 0, flux 0) — never an " +
      "error, and every field is always a finite number. Feeds the app's session vibe " +
      "meter; as an agent, use it to sanity-check a mix's energy and tonal balance while " +
      "it plays without rendering anything to disk.",
  },
  async () => toToolResult(() => bridge.send("mixer.masterAnalysis"))
);

server.registerTool(
  "engine_performance_stats",
  {
    title: "Read the audio engine's render-performance counters",
    description:
      "Read the audio engine's render-load and overrun telemetry — how hard the engine's own " +
      "DSP is working. Counters accumulate per render callback inside the engine's instrument " +
      "source nodes and per-strip effect-chain hosts; both live playback and offline renders " +
      "(bounces, stems) count. Returns `{callbackCount, renderedFrames, renderTimeNs, " +
      "peakCallbackNs, overrunCount, averageLoad, recentLoad, sampleRate, quantumFrames, " +
      "sinceResetSeconds}`. `callbackCount` is render callbacks observed (scales with track " +
      "count — each instrumented block counts once per audio quantum); `renderedFrames` is " +
      "frames rendered summed across those blocks; `renderTimeNs` is total wall-clock " +
      "nanoseconds spent inside them; `peakCallbackNs` is the single slowest callback. " +
      "`overrunCount` counts callbacks that exceeded their own real-time budget " +
      "(frames/sampleRate) — a budget-overrun proxy, NOT a CoreAudio xrun count, and one " +
      "block alone eating a whole quantum is already trouble, so any nonzero value deserves " +
      "attention. `averageLoad` is the average fraction of its budget each callback consumed " +
      "(0 = idle, 1.0 = callbacks on average ate their whole quantum); `recentLoad` is a ~1 s " +
      "moving average of the same — the 'load right now' feel. `sampleRate` and " +
      "`quantumFrames` describe the most recent callback; `sinceResetSeconds` is how long " +
      "this measurement window has been open. Every field is always a finite number; a " +
      "stopped engine freezes the counters but stays readable, and with no engine everything " +
      "reads zero. For windowed profiling (e.g. before/after adding an effect), call with " +
      "`reset: true` to close and return the current window and start a fresh one, do the " +
      "work, then read again — the second reading covers exactly that window.",
    inputSchema: {
      reset: z
        .boolean()
        .optional()
        .describe(
          "Optional, default false. true = read-then-reset: the response carries the CLOSING " +
            "window's counters and a fresh window starts immediately — the windowed-profiling " +
            "idiom. false/omitted = plain read, counters keep accumulating."
        ),
    },
  },
  async ({ reset }) =>
    toToolResult(() => bridge.send("engine.performanceStats", { reset }))
);

server.registerTool(
  "engine_watchdog_status",
  {
    title: "Read the audio engine's watchdog (stall detector) state",
    description:
      "Read the engine watchdog's state — the stall detector that keeps the audio engine from " +
      "dying silently. While the engine claims to be running, the watchdog checks (about every " +
      "2 seconds) that the engine's render-callback heartbeat is still advancing; a heartbeat " +
      "frozen across two consecutive checks means the render side is dead (a silent hardware " +
      "stall or a device that died without any notification), and the watchdog automatically " +
      "restarts the engine through the same recovery routine a device/format change uses — " +
      "position preserved, mixer state restored, playback resumed. No params. Returns " +
      "`{state, restartCount, consecutiveFailures, lastHeartbeat, engineRunning}`. `state` is " +
      "one of: 'idle' (engine intentionally stopped, or no heartbeat signal expected — e.g. an " +
      "empty session; NOT a problem), 'ok' (engine running and the heartbeat advancing — " +
      "healthy), 'recovering' (a stall was declared and an automatic restart is in progress or " +
      "retrying), 'failed' (three consecutive restart attempts failed — the watchdog has " +
      "stopped retrying and the engine needs manual intervention: check the output device, " +
      "then start playback again to re-arm). `restartCount` is the lifetime count of " +
      "successful self-heals — any nonzero value means the engine DIED at some point this " +
      "session and recovered on its own, worth mentioning to the user. `consecutiveFailures` " +
      "counts failed restart attempts in the current stall. `lastHeartbeat` is the raw " +
      "render-callback count at the last check. `engineRunning` is the engine's own running " +
      "claim. Read-only and always safe: never throws, and with no engine (headless) " +
      "everything reads idle/zero. As an agent, poll this after audio dropouts or before " +
      "long renders: 'ok' with restartCount 0 is a clean bill of health; 'failed' explains " +
      "silence better than any mix parameter will.",
  },
  async () => toToolResult(() => bridge.send("engine.watchdogStatus"))
);

// ---------------------------------------------------------------------------
// Beta feedback (M9 beta)
// ---------------------------------------------------------------------------

server.registerTool(
  "app_feedback_bundle",
  {
    title: "Write a local diagnostics bundle for a bug report",
    description:
      "Write ONE local diagnostics FOLDER that makes a bug report actionable, and return where " +
      "it landed. Run this when the user reports a bug, a crash, an audio dropout, or anything " +
      "weird, then tell them to attach the returned folder to their report. The folder " +
      "(`feedback-<timestamp>/` under ~/Library/Application Support/DAWPro/Feedback/) contains: " +
      "a manifest (app version, build, macOS version, hardware model — NO API keys or secrets), " +
      "`engine.json` (the audio engine's watchdog state and render-performance snapshot — did " +
      "it stall or self-heal, how heavy is the CPU load), `overview.json` (a counts-only " +
      "summary of the session: how many tracks/clips/effects and their ids, but NO note content " +
      "and NO file paths), and copies of any recent app crash reports. Everything stays LOCAL — " +
      "nothing is uploaded or transmitted anywhere. Returns " +
      "`{path, fileCount, byteCount, crashReportCount, includesProject}`. By default the full " +
      "project is NOT included (privacy-lean). Set `includeProject: true` ONLY if the user " +
      "agrees to share their full project content (every track, clip, MIDI note, and the paths " +
      "to their audio files) — ask them first. Safe to call anytime; never changes the project.",
    inputSchema: {
      includeProject: z
        .boolean()
        .optional()
        .describe(
          "Optional, default false. false/omitted = privacy-lean: only the counts-only overview " +
            "is shared, not the project itself. true = also fold in the FULL project snapshot " +
            "(all tracks, clips, MIDI notes, and absolute paths to the user's audio files) — only " +
            "do this with the user's explicit consent, since it shares their actual work."
        ),
    },
  },
  async ({ includeProject }) =>
    toToolResult(() => bridge.send("app.feedbackBundle", { includeProject }))
);

// ---------------------------------------------------------------------------
// Composition macros (M7 macro-c)
// ---------------------------------------------------------------------------

const songSkeletonGenreSchema = z
  .enum(["pop", "house", "hip-hop", "rock", "ballad"])
  .describe(
    "Which genre skeleton to scaffold — each sets a default tempo and a ready-made track roster. " +
      "`pop` (120 BPM): Drums, Bass (bass-tight preset), Keys (warm-keys), Lead, Vocals " +
      "(vocal-presence). `house` (124 BPM): Drums, Bass (bass-tight), Synth, Pads (warm-keys), FX. " +
      "`hip-hop` (90 BPM): Drums, 808 Bass (bass-tight), Samples, Lead, Vocals (vocal-presence). " +
      "`rock` (140 BPM): Drums, Bass (bass-tight), Rhythm Guitar, Lead Guitar, Vocals " +
      "(vocal-presence). `ballad` (72 BPM): Piano (warm-keys), Strings, Bass (bass-tight), Vocals " +
      "(vocal-presence). Instrument tracks host built-in instruments; audio tracks take recordings " +
      "or imports. Named mixer presets are applied to the strips shown in parentheses."
  );

const songSkeletonSectionSchema = z
  .object({
    name: z
      .string()
      .min(1)
      .max(40)
      .describe("Section label, e.g. \"Verse\", \"Chorus\", \"Drop\" (1-40 characters). Becomes the guide clip's name."),
    bars: z
      .number()
      .int()
      .min(1)
      .max(64)
      .describe("Section length in bars (whole number, 1-64). 4/4 is assumed, so one bar = 4 beats."),
  })
  .describe("One arrangement section: a named span measured in bars.");

server.registerTool(
  "macro_song_skeleton",
  {
    title: "Scaffold a whole song: tempo, tracks, sections, and loop in one step",
    description:
      "Scaffold a working session for a genre in ONE undoable step. Sets the tempo, adds the genre's " +
      "named tracks (instrument and audio, with curated mixer presets pre-applied where noted), lays " +
      "the song's sections out as named EMPTY MIDI clips on a dedicated instrument \"Arrangement\" " +
      "guide track (each clip positioned back-to-back: its start = the running sum of prior section " +
      "lengths, its length = bars x 4 beats), and enables the loop region over the whole arrangement " +
      "(start 0 to the total length). This is ADDITIVE — it never wipes the project: everything is " +
      "appended to whatever is already there (use project_new first if you want a clean slate). A " +
      "single edit_undo reverts the ENTIRE scaffold at once. Pass `genre` (required) to use its " +
      "defaults, or override the tempo with `tempoBPM` (20-400) and/or the layout with `sections`. " +
      "An unknown genre returns an error listing every valid genre; a bad tempo or section is a " +
      "field-named error. Returns `{genre, tempoBPM, tracks: [{id, name}], sectionClips: [{name, " +
      "startBeat, lengthBeats}], loopStart, loopEnd, arrangementTrackId}` with real ids — `tracks` " +
      "lists every created track (the roster then the Arrangement track last).",
    inputSchema: {
      genre: songSkeletonGenreSchema,
      tempoBPM: z
        .number()
        .min(20)
        .max(400)
        .optional()
        .describe("Optional tempo in BPM (20-400). Omit to use the genre's default tempo."),
      sections: z
        .array(songSkeletonSectionSchema)
        .min(1)
        .max(16)
        .optional()
        .describe(
          "Optional custom section layout (1-16 sections), replacing the genre's default arrangement. " +
            "Each section is {name, bars}; sections are laid out contiguously in order. Omit to use the " +
            "genre's default sections."
        ),
    },
  },
  async ({ genre, tempoBPM, sections }) =>
    toToolResult(() => bridge.send("macro.songSkeleton", { genre, tempoBPM, sections }))
);

// ---------------------------------------------------------------------------
// Automation
// ---------------------------------------------------------------------------

const automationTargetSchema = z
  .discriminatedUnion("type", [
    z.object({
      type: z.literal("volume").describe("Automate the track's fader volume (linear gain multiplier)."),
    }),
    z.object({
      type: z.literal("pan").describe("Automate the track's pan position."),
    }),
    z.object({
      type: z
        .literal("sendLevel")
        .describe("Automate one send's level (see `sendId`). Rejected in v0 — no render path yet."),
      sendId: z
        .string()
        .min(1)
        .describe("Id of the send to automate, from track_add_send's result or project_snapshot."),
    }),
    z.object({
      type: z
        .literal("effectParam")
        .describe("Automate one parameter of a built-in effect (see `effectId`/`param`)."),
      effectId: z
        .string()
        .min(1)
        .describe("Id of the effect to automate, from fx_add's result or project_snapshot."),
      param: z
        .string()
        .min(1)
        .describe("Exact parameter name, as listed by fx_describe for the effect's kind."),
    }),
  ])
  .describe(
    "What this lane drives on the track, by discriminator `type`. `volume`: the track " +
      "fader gain — while the lane is enabled it REPLACES manual fader control " +
      "(track_set_volume), the way to draw fades, swells, and rides — no other fields. " +
      "`pan`: the track pan, same override behavior as volume — no other fields. " +
      "`sendLevel` (needs `sendId`, from track_add_send/project_snapshot): one send's " +
      "level — REJECTED in v0 (automation_add_lane errors: send-level automation has no " +
      "render path yet; the shape is accepted now so projects stay forward-compatible). " +
      "`effectParam` (needs `effectId` from fx_add/project_snapshot, and `param` — the " +
      "EXACT name from fx_describe for that effect's kind): one parameter of a " +
      "BUILT-IN effect already in the track's insert chain — use it for filter sweeps, " +
      "reverb-mix rises, delay-feedback build-ups, etc.; built-in kinds (gain, eq, " +
      "compressor, limiter, reverb, delay, saturator, gate, chorus) work today. " +
      "`effectParam` is REJECTED in v0 when the effect is a hosted Audio Unit " +
      "(`kind: \"audioUnit\"` from fx_add), since its generic parameter surface is empty."
  );

const automationPointSchema = z.object({
  beat: z
    .number()
    .describe(
      "Timeline position in beats (quarter notes) from project start. Negative values " +
        "clamp to 0."
    ),
  value: z
    .number()
    .describe(
      "Parameter value at this point, in the target's own units/range — e.g. 0-2 linear " +
        "gain for a `volume` lane, -1..1 for `pan`, or an effect parameter's own range " +
        "(see fx_describe) for `effectParam`. Out-of-range values clamp to the target's " +
        "current range when the lane is saved."
    ),
  curve: z
    .enum(["linear", "hold"])
    .optional()
    .describe(
      "Interpolation of the segment LEAVING this point toward the next one. `linear` " +
        "(the default when omitted) ramps smoothly; `hold` stays flat at this point's " +
        "value until the next point steps. Has no effect on the lane's last point " +
        "(nothing follows it)."
    ),
});

server.registerTool(
  "automation_add_lane",
  {
    title: "Add an automation lane to a track",
    description:
      "Create an automation lane on a track for one target (see `target`), so you can " +
      "then draw a curve into it with automation_set_points — the primitive behind " +
      "volume/pan rides, fades, and (for built-in effects already in the track's insert " +
      "chain) parameter sweeps, e.g. a filter cutoff opening across a build or a reverb " +
      "mix rising into a chorus. A track holds AT MOST ONE lane per target: calling " +
      "this again for a target that already has a lane is a safe no-op that returns the " +
      "EXISTING lane unchanged (fine to call defensively before automation_set_points). " +
      "A new lane starts EMPTY (no points) and enabled; an empty lane is INERT — it has " +
      "no audible effect until points are added. `target: {type: \"sendLevel\", ...}` " +
      "and `{type: \"effectParam\", ...}` on a hosted Audio Unit effect are rejected in " +
      "v0 with a readable error (no render path/parameter surface yet — see `target`'s " +
      "own description). Returns `{lane: {id, target, points, isEnabled}}`.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track to add the lane to, from project_snapshot."),
      target: automationTargetSchema,
    },
  },
  async ({ trackId, target }) => toToolResult(() => bridge.send("automation.addLane", { trackId, target }))
);

server.registerTool(
  "automation_remove_lane",
  {
    title: "Remove an automation lane",
    description:
      "Permanently delete an automation lane — and the curve drawn into it — from a " +
      "track by id. Reversible with edit_undo.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track that owns the lane, from project_snapshot."),
      laneId: z
        .string()
        .min(1)
        .describe("Id of the lane to remove, from automation_add_lane's result or project_snapshot."),
    },
  },
  async ({ trackId, laneId }) =>
    toToolResult(() => bridge.send("automation.removeLane", { trackId, laneId }))
);

server.registerTool(
  "automation_set_points",
  {
    title: "Draw an automation lane's breakpoints",
    description:
      "Replace an automation lane's ENTIRE breakpoint array — the only point-editing " +
      "primitive (the clip_set_notes precedent: no add/remove-single-point tool). Read " +
      "the lane's current `points` from project_snapshot or automation_add_lane's " +
      "result, modify the array in your own code (add, remove, or move points), then " +
      "resubmit the whole array here. One call = one undo step. During playback: before " +
      "the first point the target holds that point's value; after the last point it " +
      "holds ITS value; between two points a `linear` segment ramps smoothly and a " +
      "`hold` segment stays flat until the next point steps. Typical uses: a fade (two " +
      "points — the start and end value), a volume/pan ride (several points tracing the " +
      "move), or — via an `effectParam` lane on a built-in effect — a filter sweep, " +
      "reverb-mix rise, or similar parameter move over time. Values clamp to the lane's " +
      "target range (e.g. 0-2 for volume, -1..1 for pan, an effect parameter's own range " +
      "from fx_describe); points are automatically reordered by `beat` (equal-beat " +
      "duplicates keep the later one) and the array is capped at 4096 points (oldest " +
      "points beyond the cap are dropped). Pass an empty array to clear the lane back to " +
      "inert. Returns `{lane: {id, target, points, isEnabled}}` with the lane exactly as " +
      "stored (reordered/clamped/capped).",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track that owns the lane, from project_snapshot."),
      laneId: z
        .string()
        .min(1)
        .describe("Id of the lane to edit, from automation_add_lane's result or project_snapshot."),
      points: z
        .array(automationPointSchema)
        .max(4096)
        .describe(
          "The lane's complete new breakpoint array (WHOLE-ARRAY replace of all " +
            "existing points), up to 4096 entries. Pass an empty array to clear the lane."
        ),
    },
  },
  async ({ trackId, laneId, points }) =>
    toToolResult(() => bridge.send("automation.setPoints", { trackId, laneId, points }))
);

server.registerTool(
  "automation_set_lane_enabled",
  {
    title: "Enable or disable an automation lane",
    description:
      "Toggle a lane between READ (its drawn curve drives the target — the default " +
      "after automation_add_lane) and MANUAL (the target follows its ordinary control " +
      "instead, e.g. track_set_volume/track_set_pan for a `volume`/`pan` lane; the " +
      "drawn curve is left untouched and simply ignored while disabled, so re-enabling " +
      "restores it exactly). Use this to A/B a drawn automation move without deleting " +
      "it. Never touches the lane's points. Returns `{lane: {id, target, points, " +
      "isEnabled}}`.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track that owns the lane, from project_snapshot."),
      laneId: z
        .string()
        .min(1)
        .describe("Id of the lane to toggle, from automation_add_lane's result or project_snapshot."),
      enabled: z
        .boolean()
        .describe(
          "True = read the drawn curve (the default when a lane is created); false = " +
            "ignore it and follow the target's ordinary manual control instead."
        ),
    },
  },
  async ({ trackId, laneId, enabled }) =>
    toToolResult(() => bridge.send("automation.setLaneEnabled", { trackId, laneId, enabled }))
);

// ---------------------------------------------------------------------------
// Render
// ---------------------------------------------------------------------------

server.registerTool(
  "render_mixdown",
  {
    title: "Render (bounce) the session to a WAV file",
    description:
      "Bounce the current session to a stereo 48 kHz WAV file, rendered offline " +
      "— much faster than realtime and without needing audio hardware or " +
      "realtime playback. Returns `{path, durationSeconds, sampleRate, " +
      "channels}`; use the returned absolute `path` to reference the bounced " +
      "audio afterwards (e.g. to import it elsewhere or ship it as a " +
      "deliverable). Errors if the project has no audio clips and no explicit " +
      "`durationSeconds` was given, since there would be nothing to render and " +
      "no way to infer a render length.",
    inputSchema: {
      path: z
        .string()
        .min(1)
        .optional()
        .describe(
          "Absolute path (or a path starting with ~ for the home directory) to " +
            "write the rendered .wav file to. When omitted, the app picks a " +
            "temp file location and returns it in the result's `path`."
        ),
      fromBeat: z
        .number()
        .min(0)
        .optional()
        .default(0)
        .describe(
          "Timeline position, in beats (quarter notes), to start rendering " +
            "from. Must be >= 0. Defaults to 0 (the very start of the timeline)."
        ),
      durationSeconds: z
        .number()
        .gt(0)
        .optional()
        .describe(
          "How many seconds of audio to render, starting at fromBeat. Must be " +
            "> 0. When omitted, defaults to the project's length at the current " +
            "tempo (through the end of the last clip) plus a 0.5 s tail."
        ),
    },
  },
  async ({ path, fromBeat, durationSeconds }) =>
    toToolResult(() => bridge.send("render.mixdown", { path, fromBeat, durationSeconds }))
);

server.registerTool(
  "render_measure_loudness",
  {
    title: "Measure the session's loudness without writing anything to disk",
    description:
      "Render the session offline and measure its loudness — BS.1770-4 " +
      "integrated LUFS, max momentary/short-term LUFS, and 4x-oversampled " +
      "true peak in dBTP — WITHOUT writing a file. Use this to see where a " +
      "mix stands before deciding whether/how hard to normalize with " +
      "render_bounce. Common reference targets: -14 LUFS integrated is the " +
      "usual streaming-platform convention (Spotify/YouTube/Apple " +
      "Music-style loudness normalization), -23 LUFS is EBU R128 broadcast " +
      "delivery. Any measurement field can come back OMITTED (absent/null) " +
      "instead of a number — that means the program sits at or below the " +
      "-70 LUFS absolute silence gate (JSON has no value for '-infinity " +
      "dB'); always treat a missing field as gated silence, not zero. " +
      "Returns `{measurement: {integratedLufs?, truePeakDbtp?, " +
      "maxMomentaryLufs?, maxShortTermLufs?}, durationSeconds, sampleRate}`. " +
      "Errors if the project has no clips in the requested window and no " +
      "explicit `durationSeconds` was given.",
    inputSchema: {
      fromBeat: z
        .number()
        .min(0)
        .optional()
        .default(0)
        .describe(
          "Timeline position, in beats (quarter notes), to start measuring " +
            "from. Must be >= 0. Defaults to 0 (the very start of the timeline)."
        ),
      durationSeconds: z
        .number()
        .gt(0)
        .optional()
        .describe(
          "How many seconds of audio to measure, starting at fromBeat. Must " +
            "be > 0. When omitted, defaults to the extent of every track's " +
            "clips (audio AND instrument — broader than render_mixdown's " +
            "audio-only default) at the current tempo, plus a 2.0 s tail for " +
            "bus reverb/release."
        ),
    },
  },
  async ({ fromBeat, durationSeconds }) =>
    toToolResult(() => bridge.send("render.measureLoudness", { fromBeat, durationSeconds }))
);

server.registerTool(
  "render_bounce",
  {
    title: "Bounce the session to a loudness-measured, optionally normalized WAV",
    description:
      "Render the session offline to a stereo 48 kHz WAV and report its " +
      "loudness — the measured/normalizing sibling of render_mixdown (which " +
      "stays the raw, fast bounce with no loudness report and no gain). " +
      "Pass `lufsTarget` to normalize toward a delivery target — -14 LUFS " +
      "integrated is the usual streaming-platform convention (Spotify/" +
      "YouTube/Apple Music-style), -23 LUFS is EBU R128 broadcast; OMIT it " +
      "for a measured but UN-normalized bounce (the loudness report is still " +
      "included, nothing about the audio changes). Normalization applies " +
      "ONE static gain toward the target, CLAMPED so the true peak never " +
      "exceeds `truePeakCeilingDb` (default -1.0 dBTP) — there is NO " +
      "limiter in v0, so when the clamp bites, the bounce lands QUIETER " +
      "than asked and `report.limitedByCeiling` is true; `report.output` is " +
      "the loudness ACTUALLY achieved (compare it to your target to see the " +
      "shortfall — never assume the target was hit without checking this). " +
      "If you need to close that gap, add the built-in limiter effect to " +
      "the master bus (or the track/bus feeding it) and call render_bounce " +
      "again: the limiter does real dynamics control, letting a subsequent " +
      "gain push closer to the ceiling safely. `report.input` is the " +
      "pre-gain measurement; `report.output` is RE-MEASURED from the gained " +
      "audio (never derived from input + gain), so it is ground truth for " +
      "the file written to disk. Any loudness field — in either input or " +
      "output — can come back OMITTED (null): that means the signal sits " +
      "at/below the -70 LUFS silence gate. A gated-silent program WITH a " +
      "requested `lufsTarget` errors (there is nothing to normalize toward); " +
      "silence without a target still succeeds, with all-null " +
      "measurements. Returns `{path, durationSeconds, sampleRate, " +
      "channels, report: {input, output, appliedGainDb, lufsTarget?, " +
      "truePeakCeilingDbtp, limitedByCeiling}}`.",
    inputSchema: {
      path: z
        .string()
        .min(1)
        .optional()
        .describe(
          "Absolute path (or a path starting with ~ for the home directory) " +
            "to write the rendered .wav file to. When omitted, the app " +
            "picks a temp file location and returns it in the result's `path`."
        ),
      fromBeat: z
        .number()
        .min(0)
        .optional()
        .default(0)
        .describe(
          "Timeline position, in beats (quarter notes), to start rendering " +
            "from. Must be >= 0. Defaults to 0 (the very start of the timeline)."
        ),
      durationSeconds: z
        .number()
        .gt(0)
        .optional()
        .describe(
          "How many seconds of audio to render, starting at fromBeat. Must " +
            "be > 0. When omitted, defaults to the extent of every track's " +
            "clips (audio AND instrument — broader than render_mixdown's " +
            "audio-only default) at the current tempo, plus a 2.0 s tail."
        ),
      lufsTarget: z
        .number()
        .min(-70)
        .max(0)
        .optional()
        .describe(
          "Integrated-loudness target in LUFS, between -70 and 0. -14 is " +
            "the common streaming convention, -23 is EBU R128 broadcast. " +
            "Omit for a measured, UN-normalized bounce — a bounce that " +
            "silently changes loudness un-asked would be surprising, so " +
            "there is no default target."
        ),
      truePeakCeilingDb: z
        .number()
        .min(-20)
        .max(0)
        .optional()
        .describe(
          "The true-peak ceiling in dBTP (-20 to 0, default -1.0) that the " +
            "normalizing gain will never push the bounce past. This CLAMPS " +
            "the gain rather than limiting the audio — see the tool " +
            "description for what to do when the clamp bites."
        ),
    },
  },
  async ({ path, fromBeat, durationSeconds, lufsTarget, truePeakCeilingDb }) =>
    toToolResult(() =>
      bridge.send("render.bounce", { path, fromBeat, durationSeconds, lufsTarget, truePeakCeilingDb })
    )
);

server.registerTool(
  "render_stems",
  {
    title: "Export the session as individual stem WAV files",
    description:
      "Export the session's MASTER-INPUT PARTITION as separate WAV files: " +
      "one file per track routed directly to master (its dry, post-fader " +
      "signal — sends stripped) and one file per bus (carrying everything " +
      "routed AND sent into it, through that bus's effect chain and " +
      "fader — send contributions live in the DESTINATION bus's stem, never " +
      "the source track's). A track routed INTO a bus therefore has no stem " +
      "of its own; request the bus instead if you want that signal. The " +
      "normative guarantee: summing every returned stem reproduces " +
      "render_mixdown's/render_bounce's raw output sample-for-sample " +
      "(within roughly 1e-4 peak, ordinary float summation-order slop) — " +
      "stems are mix-ready building blocks, not an approximation. Stems are " +
      "NEVER loudness-normalized — an independent gain per stem would break " +
      "both the mix balance and that summing guarantee — so instead each " +
      "file ships its own full, honest loudness measurement " +
      "(integratedLufs/truePeakDbtp/maxMomentaryLufs/maxShortTermLufs; any " +
      "field can come back OMITTED/null, meaning that particular stem sits " +
      "at/below the -70 LUFS silence gate — e.g. a track that's silent for " +
      "this whole song section). Pass `includeMixdown: true` to also render " +
      "a `00 Mixdown.wav` reference file under the exact same window/" +
      "settings as every stem, handy for verifying the sum yourself. Files " +
      "are named `NN Name.wav` (1-based partition order, sanitized, " +
      "collision-suffixed with ' 2', ' 3', ...). Returns `{directory, " +
      "sampleRate, durationSeconds, channels, stems: [{trackId, name, " +
      "kind: \"track\"|\"bus\", path, measurement}], mixdown?: {path, " +
      "measurement}}`. Errors if `trackIds` names a track that is routed " +
      "into a bus (pass the bus's id instead), an unknown id, or if there " +
      "is nothing to render in the requested window.",
    inputSchema: {
      trackIds: z
        .array(z.string().min(1))
        .optional()
        .describe(
          "Ids of the master-input tracks/buses to export (see " +
            "project_snapshot) — omit to export every master input in the " +
            "session. A track routed into a bus is not a master input " +
            "itself; pass the bus's id to get its (combined) stem instead."
        ),
      directory: z
        .string()
        .min(1)
        .optional()
        .describe(
          "Absolute path (or a path starting with ~) of the directory to " +
            "write stem files into; created if it doesn't exist. When " +
            "omitted, the app picks a temp directory and returns it in the " +
            "result's `directory`."
        ),
      fromBeat: z
        .number()
        .min(0)
        .optional()
        .default(0)
        .describe(
          "Timeline position, in beats (quarter notes), to start rendering " +
            "from. Must be >= 0. Defaults to 0 (the very start of the timeline)."
        ),
      durationSeconds: z
        .number()
        .gt(0)
        .optional()
        .describe(
          "How many seconds of audio to render, starting at fromBeat — " +
            "every stem file gets exactly this length, since summing them " +
            "requires identical lengths. Must be > 0. When omitted, " +
            "defaults to the extent of every track's clips (audio AND " +
            "instrument) at the current tempo, plus a 2.0 s tail."
        ),
      includeMixdown: z
        .boolean()
        .optional()
        .default(false)
        .describe(
          "If true, also render a `00 Mixdown.wav` reference file under the " +
            "same window as the stems, for spot-checking the sum. Defaults to false."
        ),
    },
  },
  async ({ trackIds, directory, fromBeat, durationSeconds, includeMixdown }) =>
    toToolResult(() =>
      bridge.send("render.stems", { trackIds, directory, fromBeat, durationSeconds, includeMixdown })
    )
);

// ---------------------------------------------------------------------------
// Project files
// ---------------------------------------------------------------------------

server.registerTool(
  "project_save",
  {
    title: "Save the session as a .dawproj bundle",
    description:
      "Save the current session as a self-contained .dawproj bundle: a " +
      "project.json file plus copies of every referenced audio file under " +
      "media/. `.dawproj` is appended to `path` automatically if missing. " +
      "Omit `path` to save in place (to the project's current file); if the " +
      "project has never been saved, omitting `path` errors with guidance " +
      "to supply one. Re-saving is incremental — media already copied into " +
      "the bundle is not re-copied. Returns `{path, mediaFilesCopied, " +
      "warnings}`. Cannot save while recording.",
    inputSchema: {
      path: z
        .string()
        .min(1)
        .optional()
        .describe(
          "Absolute path (or a path starting with ~ for the home directory) " +
            "to save the .dawproj bundle to; \".dawproj\" is appended if " +
            "missing. Omit to save in place, to the project's current file."
        ),
    },
  },
  async ({ path }) => toToolResult(() => bridge.send("project.save", { path }))
);

server.registerTool(
  "project_open",
  {
    title: "Open a .dawproj bundle",
    description:
      "Open a .dawproj bundle, replacing the current session entirely. " +
      "Unless `discardChanges` is true, unsaved changes in the current " +
      "session are automatically saved first — to its existing file, or to " +
      "a recovery bundle if the current session was never saved (untitled) " +
      "— before the new project is opened. Returns `{warnings, snapshot}`: " +
      "`warnings` lists any media files the project references but that " +
      "are missing on disk; `snapshot` is the full new session state (same " +
      "shape as project_snapshot). Refuses while recording. Refuses to " +
      "open a project saved by a newer version of the app, with a readable " +
      "error explaining why.",
    inputSchema: {
      path: z
        .string()
        .min(1)
        .describe("Absolute path (or a path starting with ~) to the .dawproj bundle to open."),
      discardChanges: z
        .boolean()
        .optional()
        .default(false)
        .describe(
          "If true, discard unsaved changes in the current session instead " +
            "of auto-saving them first. Defaults to false."
        ),
    },
  },
  async ({ path, discardChanges }) =>
    toToolResult(() => bridge.send("project.open", { path, discardChanges }))
);

server.registerTool(
  "project_new",
  {
    title: "Start a new empty session",
    description:
      "Start a fresh, empty, untitled session, replacing the current one. " +
      "Unless `discardChanges` is true, unsaved changes in the current " +
      "session are automatically saved first — to its existing file, or to " +
      "a recovery bundle if it was never saved. Returns the new (empty) " +
      "session snapshot (same shape as project_snapshot). Refuses while " +
      "recording.",
    inputSchema: {
      discardChanges: z
        .boolean()
        .optional()
        .default(false)
        .describe(
          "If true, discard unsaved changes in the current session instead " +
            "of auto-saving them first. Defaults to false."
        ),
    },
  },
  async ({ discardChanges }) => toToolResult(() => bridge.send("project.new", { discardChanges }))
);

server.registerTool(
  "project_recovery_status",
  {
    title: "Check for unsaved work left by a crashed session",
    description:
      "Check whether the app has recoverable unsaved work from a previous session that ended " +
      "unexpectedly (a crash or a force-quit). While a project is open, the app keeps a rolling " +
      "autosave snapshot in Application Support and drops a lock file that a clean exit removes; " +
      "at the next launch a surviving lock plus a snapshot means the last session crashed with " +
      "unsaved work. Returns `{available, savedAt?, sourcePath?, editCount?}`: `available` is " +
      "true only when both a crash was detected AND a restorable snapshot is present. `savedAt` " +
      "is when the snapshot was last written; `sourcePath` is the .dawproj file the crashed " +
      "session was editing (absent for a never-saved/untitled session); `editCount` is how many " +
      "edits the snapshot captured. When `available` is false there is nothing to restore. Safe " +
      "to call anytime; never modifies the session. Follow up with project_recover to accept or " +
      "discard the offer.",
    inputSchema: {},
  },
  async () => toToolResult(() => bridge.send("project.recoveryStatus", {}))
);

server.registerTool(
  "project_recover",
  {
    title: "Restore or discard unsaved work from a crashed session",
    description:
      "Act on the crash-recovery offer surfaced by project_recovery_status. With `accept: true`, " +
      "the autosaved snapshot is loaded as the current session — the recovered work becomes the " +
      "open project, kept marked as unsaved (dirty) with its original file path restored so a " +
      "later project_save writes back to the right place — and the snapshot is then cleared; the " +
      "response is `{recovered: true, warnings, snapshot}` (`snapshot` matches project_snapshot, " +
      "`warnings` lists any media the snapshot referenced that is now missing). With " +
      "`accept: false`, the snapshot is discarded and the offer cleared, leaving the current " +
      "session untouched — response `{discarded: true}`. Calling with `accept: true` when nothing " +
      "is available errors; check project_recovery_status first.",
    inputSchema: {
      accept: z
        .boolean()
        .describe(
          "true = restore the autosaved work as the current session; false = discard the " +
            "snapshot and keep the current session."
        ),
    },
  },
  async ({ accept }) => toToolResult(() => bridge.send("project.recover", { accept }))
);

// ---------------------------------------------------------------------------
// Edit
// ---------------------------------------------------------------------------

server.registerTool(
  "edit_undo",
  {
    title: "Undo the last edit",
    description:
      "Revert the most recent document edit — track, clip, mixer, tempo, loop, " +
      "punch, or metronome changes — one step at a time. Does NOT affect " +
      "playback position or other transport state (play/stop/seek are not " +
      "edits and are never undone). No params. Returns `{undone: \"<label>\", " +
      "snapshot}`: `undone` is a short label describing what was reverted " +
      "(e.g. \"Add Track\", \"Set Tempo\"), and `snapshot` is the full " +
      "post-undo session state (same shape as project_snapshot). Errors with " +
      "\"nothing to undo\" when the undo history is empty, and refuses while " +
      "recording. Check `project_snapshot`'s `undoLabel` field beforehand " +
      "(null = nothing to undo) to preview what edit_undo would revert.",
  },
  async () => toToolResult(() => bridge.send("edit.undo"))
);

server.registerTool(
  "edit_redo",
  {
    title: "Redo the last undone edit",
    description:
      "Reapply the most recently undone edit (the inverse of edit_undo), one " +
      "step at a time. No params. Returns `{redone: \"<label>\", snapshot}`: " +
      "`redone` is a short label describing what was reapplied, and " +
      "`snapshot` is the full post-redo session state (same shape as " +
      "project_snapshot). Errors with \"nothing to redo\" when the redo " +
      "history is empty. Check `project_snapshot`'s `redoLabel` field " +
      "beforehand (null = nothing to redo) to preview what edit_redo would " +
      "reapply. The redo history is cleared as soon as a new edit is made " +
      "after an undo, so redoing is only possible immediately after undoing.",
  },
  async () => toToolResult(() => bridge.send("edit.redo"))
);

// ---------------------------------------------------------------------------
// Project
// ---------------------------------------------------------------------------

server.registerTool(
  "project_snapshot",
  {
    title: "Get the full session state",
    description:
      "Get the full current state of the DAW session: transport (playing/stopped, " +
      "playhead position in beats), tempo (BPM), master volume, and all tracks " +
      "with their settings (volume, pan, mute, solo) and clips. Each track also " +
      "carries its routing: `outputBusId` (the id of the bus track its output " +
      "feeds, or null for the master mix — see track_set_output) and `sends` " +
      "(its post-fader sends into other buses, each `{id, busId, level}` — see " +
      "track_add_send/track_set_send/track_remove_send). Each track/bus also " +
      "carries its `effects` insert chain: a PRE-FADER, ORDERED array (array " +
      "order = processing order) of `{id, kind, bypassed, params, latencySamples}` " +
      "(`latencySamples` is the processing delay that effect adds, in samples — 0 for " +
      "most kinds; `limiter`'s lookahead adds some), capped at " +
      "16 entries — see fx_add/fx_remove/fx_reorder/fx_set_bypass/fx_set_param " +
      "to edit it and fx_describe for each kind's parameter names/ranges/units. " +
      "MIDI clips (from " +
      "clip_add_midi) carry a `notes` array (pitch, velocity, startBeat relative " +
      "to the clip, lengthBeats); audio clips do not. Also includes a " +
      "`meters` object with live peak/RMS levels (linear 0-1) for the master bus " +
      "(`meters.master`) and each track (`meters.tracks`, keyed by track id — " +
      "bus tracks meter here too, like any other track, reflecting their " +
      "summed input) — check meters after transport_play to confirm audio is " +
      "actually rendering. " +
      "Also includes `lastRecordingError`: null after a successful " +
      "transport_record take, or a string explaining what went wrong (e.g. " +
      "microphone permission denied, no armed tracks, empty take) — check it " +
      "after transport_stop following a recording. Also includes `undoLabel` " +
      "and `redoLabel`: a short label describing the edit that edit_undo / " +
      "edit_redo would apply next (e.g. \"Add Track\", \"Set Tempo\"), or " +
      "null when there is nothing to undo/redo. May also include " +
      "`midiInputs` (the same list midi_list_inputs returns, for " +
      "convenience) and `midiEventCount`: a monotonically increasing " +
      "counter of MIDI events received from any online input source — " +
      "poll it across two snapshots and see if it changed to detect live " +
      "MIDI activity (e.g. confirm a keyboard is actually sending notes) " +
      "without needing a dedicated streaming channel. Call this first to " +
      "orient yourself before making other changes.",
  },
  async () => toToolResult(() => bridge.send("project.snapshot"))
);

server.registerTool(
  "project_overview",
  {
    title: "Get a compact session overview",
    description:
      "Get a compact, aggressively summarized snapshot of the session — " +
      "everything you need to orient (what tracks exist, their ids, routing, " +
      "and roughly what's on them) without the token cost of " +
      "project_snapshot's full fidelity. PREFER THIS over project_snapshot " +
      "when starting a session, re-orienting after a batch of changes, or " +
      "any time you need ids and session shape rather than note-level detail " +
      "— it typically encodes 5x+ smaller than project_snapshot for the same " +
      "session, staying in the low KBs even on a dense multi-track project. " +
      "Reach for project_snapshot instead when you actually need MIDI note " +
      "data, automation breakpoint curves, live meters, resolved per-effect " +
      "parameter values, or other full-fidelity detail this tool summarizes " +
      "away. No params. Returns `{transport, master, tracks}` directly (no " +
      "wrapping envelope). `transport` is `{tempoBPM, isPlaying, isRecording, " +
      "positionBeats, loop: {enabled, startBeat, endBeat}, metronome: " +
      "{enabled, countInBars}, punch: {enabled, inBeat, outBeat}}`. `master` " +
      "is `{volume}` (linear gain, 0-2, 1 = unity). `tracks` is an array of " +
      "`{id, name, kind, muted, soloed, armed, volume, pan, output?, " +
      "instrument?, sends, fx, clips, automation}` — `id` is the FULL uuid " +
      "(use it verbatim in follow-up commands like track_set_volume or " +
      "clip_move; there is no id-shortening machinery on this path). " +
      "`output` is the destination bus track's id, omitted for master. " +
      "`instrument` is the hosted instrument's display name, present only on " +
      "instrument tracks (it resolves to the default poly synth even when " +
      "unconfigured), omitted on audio/bus tracks. `sends` is each " +
      "`{destinationBusID, level, preFader}` (preFader is always false today " +
      "— v0 sends are post-fader only). `fx` is each `{name, bypassed}` in " +
      "chain order (use fx_describe or project_snapshot for actual parameter " +
      "values). `clips` summarizes every clip as `{id, name, startBeat, " +
      "lengthBeats, kind: \"audio\"|\"midi\", noteCount?, takeLaneCount?, " +
      "activeLane?, hasStretch?, hasFades?, gainDb?}` — COUNTS, never the " +
      "actual MIDI notes, and no file paths (fetch a clip's real note data or " +
      "source file via project_snapshot/clip tools when you need it). " +
      "`automation` summarizes every lane as `{target, enabled, pointCount}` " +
      "— never the breakpoints themselves. Every optional field is simply " +
      "omitted when it doesn't apply (never emitted as null), which is what " +
      "keeps the payload small.",
  },
  async () => toToolResult(() => bridge.send("project.overview"))
);

// ---------------------------------------------------------------------------
// AI sidecar (local song-generation engine)
// ---------------------------------------------------------------------------
//
// These three tools manage the LOCAL ACE-Step-1.5 process (a Python FastAPI
// sidecar on 127.0.0.1:8001, loopback only — see docs/AI-INTEGRATIONS.md and
// docs/research/2026-07-05-ace-step-local-song-generation.md). M6 (i) shipped
// install/health/start/stop management; M6 (ii), just below, adds the actual
// generation tools (`generate_song`/`generation_status`) against
// `ACEStepClient: SongGenerating`; M6 (iii-a) adds `import_generation`, which
// lands a finished job as an AI-flagged track + clip with tempo adoption.
// Unlike generate_lyrics/generate_song_suno/
// generate_image further down, ALL of these route through the DAW app's
// control WebSocket (bridge.send), not a direct provider HTTP call — the
// sidecar (both its lifecycle AND its generation jobs) is owned by the
// running app, same as any other control command.

server.registerTool(
  "ai_sidecar_status",
  {
    title: "Check the local ACE-Step song-generation sidecar",
    description:
      "Check the status of the local ACE-Step-1.5 sidecar — the offline, " +
      "MIT-licensed song-generation engine that will produce full songs " +
      "with sung vocals from lyrics/style prompts (once the generation " +
      "tools land; this tool is lifecycle/health only). No params. Always " +
      "succeeds (never throws) and returns one of five states: " +
      "`notInstalled` (run scripts/ace-step/install.sh first — a one-time " +
      "~55-70 GB download of the XL DiT + 4B LM model tier), " +
      "`installedNotRunning` (call ai_sidecar_start), `starting` (an " +
      "ai_sidecar_start call is in flight — poll again shortly), `healthy` " +
      "(ready — `version`/`ditModel`/`lmModel` report what's loaded), or " +
      "`error` (the sidecar responded but unexpectedly — check the log at " +
      "~/Library/Logs/DAWPro/ace-step.log). Returns `{state, message, " +
      "version?, ditModel?, lmModel?, pid?}` — `message` is always a " +
      "human-actionable next step, never a bare code. Call this before " +
      "ai_sidecar_start to avoid an unnecessary spawn attempt, and after " +
      "it to confirm readiness.",
  },
  async () => toToolResult(() => bridge.send("ai.sidecarStatus"))
);

server.registerTool(
  "ai_sidecar_start",
  {
    title: "Start the local ACE-Step song-generation sidecar",
    description:
      "Start the local ACE-Step-1.5 sidecar (spawns scripts/ace-step/run.sh, " +
      "a FastAPI server bound to 127.0.0.1:8001 only) if it isn't already " +
      "healthy, then waits for it to report ready. No params. Errors with " +
      "an actionable message if the sidecar was never installed (points at " +
      "scripts/ace-step/install.sh) or if the process exits during " +
      "startup (points at the log file). A slow model load is NOT an " +
      "error — if the health check doesn't succeed within the startup " +
      "timeout, this still returns ok with `state: \"starting\"`; call " +
      "ai_sidecar_status again a little later rather than retrying " +
      "ai_sidecar_start. Returns the same `{state, message, version?, " +
      "ditModel?, lmModel?, pid?}` shape as ai_sidecar_status. Remember: " +
      "Once healthy, use generate_song to start writing a track.",
  },
  async () => toToolResult(() => bridge.send("ai.sidecarStart"))
);

server.registerTool(
  "ai_sidecar_stop",
  {
    title: "Stop the local ACE-Step song-generation sidecar",
    description:
      "Stop the local ACE-Step-1.5 sidecar (graceful SIGTERM via its " +
      "pidfile, escalating to a forced kill if it doesn't exit promptly) " +
      "to free the memory/GPU its loaded models hold — useful before a " +
      "demanding DAW session. No params. Succeeds as a no-op (not an " +
      "error) if it wasn't running. Returns the same `{state, message, " +
      "version?, ditModel?, lmModel?, pid?}` shape as ai_sidecar_status " +
      "(state settles to `installedNotRunning`).",
  },
  async () => toToolResult(() => bridge.send("ai.sidecarStop"))
);

server.registerTool(
  "ai_provider_status",
  {
    title: "Check which cloud AI providers have a key configured",
    description:
      "Report whether each cloud AI provider (anthropic, openai, suno) has a " +
      "usable API key in the running app, and where it comes from. No params. " +
      "Returns `{providers: [{provider, configured, source}]}` where `source` " +
      "is `\"env\"` (an environment variable — takes precedence and is " +
      "read-only from the app), `\"keychain\"` (set in the app's Settings " +
      "panel), or `\"none\"` (not set). ACE-Step is the LOCAL, KEYLESS song " +
      "sidecar and never appears here — use ai_sidecar_status for it. " +
      "IMPORTANT: this is STATUS ONLY. Key VALUES are never exposed and can " +
      "NOT be set over MCP or the control protocol (this traffic is logged in " +
      "your conversation, so a secret must never cross it). If a provider is " +
      "`none`, tell the user to set it via the app's Settings panel (⌘,) or " +
      "an environment variable — do not ask them to paste a key to you.",
  },
  async () => toToolResult(() => bridge.send("ai.providerStatus"))
);

server.registerTool(
  "ai_write_lyrics",
  {
    title: "Write or refine lyrics in the app (project-aware)",
    description:
      "Write (or REFINE) section-labeled lyrics in ACE-Step's bracketed-structure " +
      "format ([verse]/[chorus]/[bridge]/[outro] on their own line, lyric lines " +
      "beneath) using the RUNNING APP's configured provider and its LIVE project " +
      "context. This routes through the DAW (bridge.send), so it uses the keys " +
      "managed in the app's Settings panel (Anthropic preferred, OpenAI fallback) " +
      "and, when you omit `context`, defaults the key/tempo/time-signature from the " +
      "current project — the words come back fit to the session. This is different " +
      "from `generate_lyrics`, which calls Anthropic/OpenAI DIRECTLY from the MCP " +
      "server's OWN process environment and knows nothing about the open project; " +
      "prefer THIS tool when a DAW project is open, and feed its `lyrics` output " +
      "straight into `generate_song`. Returns `{lyrics, provider}` (provider is " +
      "\"anthropic\" or \"openai\"). If NEITHER provider has a key in the app, it " +
      "errors with an actionable message pointing at the app's Settings panel (⌘,) " +
      "and ai_provider_status — key values are never sent over this channel, so ask " +
      "the user to set one there rather than pasting it to you.",
    inputSchema: {
      prompt: z
        .string()
        .min(1)
        .describe("The theme — what the song is about, e.g. \"missing someone after they moved away\"."),
      style: z
        .string()
        .optional()
        .describe("Optional style/genre guidance, e.g. \"90s pop-punk\", \"slow R&B ballad\"."),
      structure: z
        .array(z.string())
        .optional()
        .describe(
          "Optional ordered section tags, e.g. [\"verse\",\"chorus\",\"verse\",\"chorus\",\"bridge\",\"chorus\"]. " +
            "Defaults to a familiar pop structure when omitted."
        ),
      context: z
        .object({
          keyScale: z.string().optional().describe("Key/scale, e.g. \"C Major\", \"A Minor\"."),
          tempoBPM: z.number().optional().describe("Tempo in BPM."),
          timeSignature: z.string().optional().describe("Time signature, e.g. \"4/4\", \"3/4\"."),
          genre: z.string().optional().describe("Genre/feel hint."),
        })
        .optional()
        .describe(
          "Optional project-musical context. ANY field you omit defaults from the current project " +
            "(tempoBPM/timeSignature from the transport), so a bare call still fits the session."
        ),
      existingLyrics: z
        .string()
        .optional()
        .describe(
          "REFINE mode: the current lyrics to revise. Provide this together with `instruction` to " +
            "revise rather than write from scratch."
        ),
      instruction: z
        .string()
        .optional()
        .describe("REFINE mode: how to revise, e.g. \"make the chorus more hopeful\"."),
    },
  },
  async (params) => toToolResult(() => bridge.send("ai.writeLyrics", params))
);

// ---------------------------------------------------------------------------
// AI sidecar (local song generation jobs — M6 ii)
// ---------------------------------------------------------------------------
//
// generate_song submits an ASYNC job (POST /release_task on the sidecar) and
// returns immediately with a jobId; generation itself commonly takes minutes
// (ACE-Step's own docs / community reports on Apple Silicon: roughly 2-10
// minutes per track depending on duration/hardware — there is no official
// Apple-Silicon benchmark yet, so treat this as a rough expectation, not a
// promise). Poll generation_status every 5-10s (NOT a tight loop) until
// `state` is `"succeeded"` — its `audioPath` then points at a local WAV file
// ready to import with clip_add_audio (create a track first with track_add
// if needed). A job that fails upstream (e.g. an OOM) surfaces as a TOOL
// ERROR from generation_status, not a silent `"failed"` state, so treat any
// non-ok generation_status call after a valid jobId as exactly that.

server.registerTool(
  "generate_song",
  {
    title: "Generate a full song locally (ACE-Step)",
    description:
      "Submit an async full-song generation job to the LOCAL ACE-Step-1.5 " +
      "sidecar — sung vocals + instrumentation together from a style prompt " +
      "and optional lyrics, fully offline (no API key, no cloud). Returns " +
      "immediately with `{jobId, state, queuePosition?}` (state is always " +
      "\"queued\"); the song is NOT ready yet — poll generation_status with " +
      "the returned jobId until it reports \"succeeded\", then import the " +
      "resulting audioPath with clip_add_audio. REQUIRES the sidecar to be " +
      "healthy first — call ai_sidecar_status (and ai_sidecar_start if " +
      "needed) before this, or expect an actionable error pointing at " +
      "whichever of those two you skipped.",
    inputSchema: {
      prompt: z
        .string()
        .min(1)
        .describe(
          "Style/caption text: genre, mood, instrumentation, era, production style, vocal " +
            "character — e.g. \"80s synth-pop, anthemic, driving bassline, female vocals\"."
        ),
      lyrics: z
        .string()
        .optional()
        .describe(
          "Section-labeled lyrics in ACE-Step's bracketed-structure format — bracketed tags " +
            "on their own line (e.g. [Verse 1], [Pre-Chorus], [Chorus], [Bridge], [Outro]), " +
            "optionally with a style qualifier like [Chorus - anthemic] or [whispered], " +
            "followed by the lyric lines for that section (parentheses mark backing vocals). " +
            "6-10 syllables/line reads most naturally. Example:\n" +
            "[Verse 1]\nWalking home in the rain\nThinking of you again\n" +
            "[Chorus]\nWe rise together (together)\nThrough the storm and the weather\n" +
            "Omit (or leave blank) for an INSTRUMENTAL track — generate_lyrics can write " +
            "this for you first."
        ),
      durationSeconds: z
        .number()
        .min(10)
        .max(600)
        .optional()
        .describe(
          "Target length in seconds. Omit to use ACE-Step's own default (30s). The " +
            "documented \"stable\" range is roughly 30-240s — longer generations show more " +
            "structural drift/repetition per ACE-Step's own docs."
        ),
      seed: z
        .number()
        .int()
        .min(0)
        .optional()
        .describe(
          "Deterministic seed for reproducible output. Omit for a fresh random seed each " +
            "call; reuse the same seed + inputs later to reproduce a prior render."
        ),
      bpm: z
        .number()
        .min(30)
        .max(300)
        .optional()
        .describe("Target tempo in beats per minute. Omit to let ACE-Step choose one that fits the prompt."),
      keyScale: z
        .string()
        .optional()
        .describe("Free-text key/scale hint, e.g. \"C Major\", \"A Minor\"."),
      timeSignature: z
        .string()
        .optional()
        .describe("Free-text time-signature hint, e.g. \"4/4\", \"3/4\"."),
      vocalLanguage: z
        .string()
        .optional()
        .describe("Language code for sung vocals, e.g. \"en\", \"ja\", \"es\". Defaults to \"en\"."),
      guidanceScale: z
        .number()
        .min(1)
        .max(20)
        .optional()
        .describe(
          "Classifier-free-guidance scale — higher follows the prompt/lyrics more strictly, " +
            "at some cost to naturalness. Omit to use ACE-Step's default (7.0)."
        ),
      inferenceSteps: z
        .number()
        .int()
        .min(1)
        .max(100)
        .optional()
        .describe(
          "Diffusion sampling steps — more steps can improve quality at the cost of " +
            "generation time. Omit to use ACE-Step's turbo-model default (8)."
        ),
    },
  },
  async (params) => toToolResult(() => bridge.send("ai.generateSong", params))
);

server.registerTool(
  "generation_status",
  {
    title: "Poll a local song-generation job",
    description:
      "Poll a song-generation job previously submitted with generate_song. " +
      "Returns `{jobId, state, progress?, stage?, statusText?, audioPath?}` " +
      "— `state` is one of \"queued\", \"running\", or \"succeeded\" (a job " +
      "that failed upstream surfaces as a TOOL ERROR here instead, with the " +
      "sidecar's own failure detail, e.g. an out-of-memory message — it is " +
      "never returned as a quiet \"failed\" state). `progress` (0-1) and " +
      "`stage`/`statusText` are best-effort informational detail from the " +
      "sidecar, when it reports them. The FIRST poll that observes " +
      "`state == \"succeeded\"` fetches the finished audio to a local file " +
      "and reports it as `audioPath`; later polls of the same jobId reuse " +
      "that same cached path (no repeated downloads). Once `audioPath` is " +
      "present, import it onto a track with clip_add_audio (create the " +
      "track first with track_add if you don't already have one). Poll " +
      "every 5-10 seconds, not in a tight loop — generation commonly takes " +
      "minutes.",
    inputSchema: {
      jobId: z.string().min(1).describe("The jobId returned by generate_song."),
    },
  },
  async ({ jobId }) => toToolResult(() => bridge.send("ai.generationStatus", { jobId }))
);

server.registerTool(
  "import_generation",
  {
    title: "Import a finished generation into the project",
    description:
      "Turn a FINISHED song-generation job into project material: creates a " +
      "new AI-flagged audio track + clip (violet in the UI) from the " +
      "generated audio, and optionally adopts the project tempo from the " +
      "generation's detected BPM — all as ONE undoable step (edit_undo " +
      "removes the track AND restores the tempo together). This is the final " +
      "step of the generation flow: generate_song -> poll generation_status " +
      "until it reports state \"succeeded\" (an audioPath is present) -> " +
      "import_generation -> then arrange/edit with the normal clip_* / " +
      "track_* commands. Do NOT call this before the job succeeds: a " +
      "still-running job returns an actionable error telling you to keep " +
      "polling generation_status; an unknown/expired jobId returns the same " +
      "expired-job error generation_status would. Returns `{trackId, clipId, " +
      "adoptedTempoBPM?}` (adoptedTempoBPM is present only when the tempo was " +
      "actually changed).",
    inputSchema: {
      jobId: z
        .string()
        .min(1)
        .describe(
          "The jobId returned by generate_song. The job must have reached state \"succeeded\" " +
            "(check with generation_status) — otherwise this errors."
        ),
      trackName: z
        .string()
        .optional()
        .describe(
          "Name for the new track. Omit to default to \"AI: <first words of the prompt>\"."
        ),
      atBeat: z
        .number()
        .min(0)
        .optional()
        .describe("Beat position where the clip lands. Omit for 0 (the start of the timeline)."),
      setProjectTempo: z
        .boolean()
        .optional()
        .describe(
          "Whether to set the project tempo to the generation's detected BPM. Omit to " +
            "auto-adopt ONLY when the project has no other clips yet (so the first imported " +
            "track establishes the grid, but a later import never silently moves everything). " +
            "true forces adoption; false forbids it. Adoption also requires the generation to " +
            "report a BPM."
        ),
    },
  },
  async (params) => toToolResult(() => bridge.send("ai.importGeneration", params))
);

// ---------------------------------------------------------------------------
// AI sidecar (stem extraction / Lego per-track generation — M6 iii-c)
// ---------------------------------------------------------------------------
//
// ACE-Step's upstream job-queue API extracts/generates ONE named track per
// job (task_type "extract"/"lego" — verified against
// scripts/ace-step/runtime/src/acestep source, never guessed). extract_stems
// and lego_generate each fan that out into one upstream job PER requested
// track name, all against the SAME source audio, and hand back a single
// COMPOSITE jobId grouping them. Poll that composite jobId with the SAME
// generation_status tool used for generate_song (one status surface, not a
// parallel one) — a succeeded poll's `stems` array carries every named
// result (`{trackName, audioPath, bpm?, durationSeconds?}`). Flow: confirm
// ai_sidecar_status is healthy -> extract_stems or lego_generate -> poll
// generation_status with the returned jobId until every stem has succeeded
// -> import_generated_stems lands N violet AI tracks (one per stem) in ONE
// undoable step. NOTE: extract/lego are BASE-model-only upstream capabilities
// (ACE-Step's turbo tier — the sidecar's default load — does not officially
// serve them, and unlike most rejections, upstream does NOT error on a
// mismatched job -- it silently runs it on turbo anyway). `model` (M6
// iii-c-real) is OPTIONAL for exactly this reason: leaving it unset does NOT
// risk that silent turbo fallback -- the app-side client defaults it to a
// base/SFT model (currently "acestep-v15-xl-sft") and auto-loads that model
// into a second handler slot before submitting if it isn't already resident
// (can take minutes the first time; the tool call blocks until it's ready or
// reports an actionable error). Pass `model` explicitly only to request a
// different DiT model.

server.registerTool(
  "extract_stems",
  {
    title: "Separate an existing audio file into named stems (ACE-Step)",
    description:
      "Submit an async stem-SEPARATION job to the LOCAL ACE-Step-1.5 " +
      "sidecar: pulls the requested named tracks (e.g. vocals, drums, " +
      "bass) out of an existing mixed-down audio file, fully offline. " +
      "Internally submits one upstream job per requested track name " +
      "(ACE-Step's `extract` task type separates one track per call) and " +
      "returns a single COMPOSITE `{jobId, state, trackNames}` grouping " +
      "them (state is always \"queued\"). Poll with generation_status " +
      "using the returned jobId exactly like generate_song; a succeeded " +
      "poll's `stems` array carries every separated track's local " +
      "audioPath. Then call import_generated_stems to land them as N " +
      "violet AI tracks in one step. REQUIRES the sidecar to be healthy " +
      "first — call ai_sidecar_status (and ai_sidecar_start if needed).",
    inputSchema: {
      sourceAudioPath: z
        .string()
        .min(1)
        .describe(
          "Local filesystem path to the existing mixed-down audio file to separate " +
            "(e.g. a rendered mixdown from render_mixdown, or any readable audio file on " +
            "this machine). The sidecar only accepts source audio it can read via its own " +
            "temp-directory allowlist; the tool stages a copy for you, so any readable local " +
            "path works."
        ),
      trackNames: z
        .array(z.string().min(1))
        .min(1)
        .describe(
          "Stem names to extract, e.g. [\"vocals\", \"drums\", \"bass\"]. ACE-Step's fixed " +
            "vocabulary: woodwinds, brass, fx, synth, strings, percussion, keyboard, guitar, " +
            "bass, drums, backing_vocals, vocals. An unrecognized name is rejected by the " +
            "sidecar with its own error."
        ),
      model: z
        .string()
        .optional()
        .describe(
          "DiT model name to use, e.g. \"acestep-v15-xl-sft\". OPTIONAL and normally best left " +
            "unset (M6 iii-c-real): extraction is a BASE-model-only capability, but omitting this " +
            "does NOT fall back to turbo — the app defaults it to its own stems model and " +
            "auto-loads that model into a handler slot before submitting if needed (can take " +
            "minutes the first time a given model loads). Pass this explicitly only to request a " +
            "different DiT model."
        ),
    },
  },
  async (params) => toToolResult(() => bridge.send("ai.extractStems", params))
);

server.registerTool(
  "lego_generate",
  {
    title: "Generate new tracks that fit existing audio (ACE-Step Lego)",
    description:
      "Submit an async per-track GENERATION job to the LOCAL ACE-Step-1.5 " +
      "sidecar: writes NEW instrument/vocal tracks (e.g. a bass line, a " +
      "synth pad) so each fits an existing source audio's musical context " +
      "— ACE-Step's \"Lego\" task, building a song up one layer at a time. " +
      "Each requested track carries its own local `prompt` (that track's " +
      "specific description) alongside a shared `globalCaption` (the " +
      "full song's description) — both feed the same generation. " +
      "Internally submits one upstream job per requested track (same " +
      "one-job-per-track shape as extract_stems) and returns a single " +
      "COMPOSITE `{jobId, state, trackNames}`. Poll with generation_status " +
      "exactly like generate_song/extract_stems; a succeeded poll's " +
      "`stems` array carries every generated track's local audioPath. " +
      "Then call import_generated_stems to land them as N violet AI " +
      "tracks in one step. REQUIRES the sidecar to be healthy first — " +
      "call ai_sidecar_status (and ai_sidecar_start if needed).",
    inputSchema: {
      sourceAudioPath: z
        .string()
        .min(1)
        .describe(
          "Local filesystem path to the existing audio the new tracks must musically fit " +
            "(e.g. a mixdown of the tracks so far). Same staging semantics as extract_stems."
        ),
      globalCaption: z
        .string()
        .min(1)
        .describe(
          "Shared, song-level description used for every requested track, e.g. \"warm lofi " +
            "hip-hop, 90 bpm, dusty vinyl texture\"."
        ),
      tracks: z
        .array(
          z.object({
            trackName: z
              .string()
              .min(1)
              .describe(
                "The track to generate, from ACE-Step's fixed vocabulary: woodwinds, brass, " +
                  "fx, synth, strings, percussion, keyboard, guitar, bass, drums, " +
                  "backing_vocals, vocals."
              ),
            prompt: z
              .string()
              .optional()
              .describe(
                "This track's OWN local description, e.g. \"round sub bass, laid back, " +
                  "syncopated\". Omit for a bare generic instruction."
              ),
          })
        )
        .min(1)
        .describe("The tracks to generate — one entry per new track, each with its own local prompt."),
      model: z
        .string()
        .optional()
        .describe(
          "DiT model name to use, e.g. \"acestep-v15-xl-sft\". OPTIONAL — same default-model + " +
            "auto-load behavior as extract_stems' `model` note; leave unset for the normal case."
        ),
    },
  },
  async (params) => toToolResult(() => bridge.send("ai.legoGenerate", params))
);

server.registerTool(
  "import_generated_stems",
  {
    title: "Import a finished stems/Lego job as N tracks",
    description:
      "Turn a FINISHED extract_stems or lego_generate job into project " +
      "material: creates N new AI-flagged audio tracks + clips (violet in " +
      "the UI), one per named stem/track, all at the same beat position, " +
      "and optionally adopts the project tempo from the first track (in " +
      "submission order) that reports a BPM — all as ONE undoable step " +
      "(edit_undo removes EVERY imported track, and restores the tempo, " +
      "together). This is the final step of the stems/Lego flow: " +
      "extract_stems or lego_generate -> poll generation_status until it " +
      "reports state \"succeeded\" with a non-empty `stems` array -> " +
      "import_generated_stems -> then arrange/edit the new tracks with the " +
      "normal clip_* / track_* commands. Do NOT call this before every " +
      "track has succeeded: a still-running job returns an actionable " +
      "error telling you to keep polling generation_status; an unknown/ " +
      "expired jobId returns the same expired-job error generation_status " +
      "would. Returns `{tracks: [{trackId, clipId, trackName}, ...], " +
      "adoptedTempoBPM?}` (adoptedTempoBPM is present only when the tempo " +
      "was actually changed).",
    inputSchema: {
      jobId: z
        .string()
        .min(1)
        .describe(
          "The composite jobId returned by extract_stems or lego_generate. Every underlying " +
            "track must have reached state \"succeeded\" (check with generation_status) — " +
            "otherwise this errors."
        ),
      atBeat: z
        .number()
        .min(0)
        .optional()
        .describe(
          "Beat position where every imported clip lands (they share one start — stems are " +
            "meant to play together). Omit for 0 (the start of the timeline)."
        ),
      setProjectTempo: z
        .boolean()
        .optional()
        .describe(
          "Whether to set the project tempo to the detected BPM. Omit to auto-adopt ONLY " +
            "when the project has no other clips yet. true forces adoption; false forbids it. " +
            "Adoption also requires at least one imported track to report a BPM."
        ),
    },
  },
  async (params) => toToolResult(() => bridge.send("ai.importGeneratedStems", params))
);

// ---------------------------------------------------------------------------
// AI sidecar (repaint — M6 v-a)
// ---------------------------------------------------------------------------
//
// Repaint re-renders a WINDOW of an EXISTING audio file in place (ACE-Step's
// "repaint" task type — a "part swap"/inpainting job): everything outside
// [start, end) stays untouched. Unlike extract_stems/lego_generate this is a
// SINGLE upstream job — no per-track fan-out, no composite jobId — so it
// returns a plain jobId polled with generation_status exactly like
// generate_song. Repaint also works on the sidecar's DEFAULT turbo tier
// (unlike extract/lego, which are base-model-only), so `model` needs no
// auto-load step and is normally best left unset. There is NO separate
// "retake" task/tool upstream: to get a different take of the SAME window,
// call ai_repaint_audio again with the same sourcePath/start/end and omit
// `seed` (a fresh random seed each call).

server.registerTool(
  "ai_repaint_audio",
  {
    title: "Repaint a window of existing audio in place (ACE-Step)",
    description:
      "Submit an async REPAINT job to the LOCAL ACE-Step-1.5 sidecar: " +
      "re-renders a WINDOW of an EXISTING audio file in place (a 'part " +
      "swap'/inpainting job) — everything outside [start, end) stays " +
      "untouched, fully offline. Unlike extract_stems/lego_generate this " +
      "is a SINGLE upstream job (no per-track fan-out, no composite " +
      "jobId). Returns immediately with `{jobId, state, queuePosition?}` " +
      "(state is always \"queued\"); poll generation_status with the " +
      "returned jobId exactly like generate_song until it reports " +
      "\"succeeded\" — its audioPath is then the FULL-LENGTH file with " +
      "the window repainted (import with clip_add_audio, or use it to " +
      "replace the source). There is NO separate retake tool: to get a " +
      "different take of the SAME window, call ai_repaint_audio again " +
      "with the same sourcePath/start/end and OMIT seed (a fresh random " +
      "seed each call). REQUIRES the sidecar to be healthy first — call " +
      "ai_sidecar_status (and ai_sidecar_start if needed).",
    inputSchema: {
      sourcePath: z
        .string()
        .min(1)
        .describe(
          "Local filesystem path to the existing audio file whose window gets repainted " +
            "(e.g. a rendered mixdown from render_mixdown, or any readable audio file on this " +
            "machine). Must exist on disk. The sidecar only accepts source audio it can read " +
            "via its own temp-directory allowlist; the tool stages a copy for you, so any " +
            "readable local path works."
        ),
      start: z
        .number()
        .min(0)
        .describe("Start of the window to repaint, in seconds from the top of the file."),
      end: z
        .number()
        .optional()
        .describe(
          "End of the window, in seconds. Must be greater than start. Omit to repaint from " +
            "start through the end of the file."
        ),
      prompt: z
        .string()
        .optional()
        .describe(
          "Style/caption text guiding the repainted window, e.g. \"driving rock drums, " +
            "tighter groove\". Omit to keep the source's own musical context."
        ),
      lyrics: z
        .string()
        .optional()
        .describe(
          "Section-labeled lyrics (ACE-Step bracketed-structure format) for the repainted " +
            "window, when it carries vocals. Omit/blank leaves the window's vocal content to " +
            "the model."
        ),
      mode: z
        .enum(["conservative", "balanced", "aggressive"])
        .optional()
        .describe(
          "How strongly to regenerate the window: \"conservative\" stays closest to the " +
            "original audio, \"balanced\" (default) is the standard trade-off and the ONLY " +
            "mode where `strength` has any effect, \"aggressive\" most freely reimagines the " +
            "window."
        ),
      strength: z
        .number()
        .min(0)
        .max(1)
        .optional()
        .describe(
          "0-1 — how far a \"balanced\"-mode repaint is allowed to depart from the original " +
            "audio in the window. Only consulted when mode is \"balanced\" (the default). " +
            "Omit to use the sidecar's own default."
        ),
      wavCrossfadeSec: z
        .number()
        .min(0)
        .optional()
        .describe(
          "Crossfade applied at the window edges in the rendered WAV, in seconds, to smooth " +
            "the seam. Omit for the sidecar's own default (0.0 — no crossfade)."
        ),
      seed: z
        .number()
        .int()
        .min(0)
        .optional()
        .describe(
          "Deterministic seed for reproducible output. Omit for a fresh random seed each " +
            "call — this is how you RETAKE the same window: call again with the same " +
            "sourcePath/start/end and no seed."
        ),
      model: z
        .string()
        .optional()
        .describe(
          "DiT model name override, e.g. \"acestep-v15-xl-sft\". OPTIONAL and normally best " +
            "left unset: unlike extract_stems/lego_generate, repaint also works on the " +
            "sidecar's default turbo tier, so omitting this needs no auto-load step."
        ),
    },
  },
  async (params) => toToolResult(() => bridge.send("ai.repaintAudio", params))
);

// ---------------------------------------------------------------------------
// AI clip vocal-fix flow (M6 v-b)
// ---------------------------------------------------------------------------
//
// "Fix this phrase with AI" for a region of an existing TIMELINE clip. Three
// explicit steps, exactly like generate_song -> generation_status ->
// import_generation:
//   1. ai_fix_clip_region {trackId, clipId, startBeat, endBeat, ...} — bounces
//      a dry, as-heard window of the target material (region +/- context,
//      clamped), submits the repaint, and returns a jobId + a placement echo.
//      It does NOT touch the project.
//   2. ai_generation_status {jobId} — poll until state "succeeded" (the SAME
//      status surface as every other generation job — minutes on a local MPS
//      sidecar).
//   3. ai_import_clip_fix {jobId} — lands the result as a violet take LANE
//      comped in over EXACTLY the region (a comp SPLICE): the original audio is
//      never replaced, and the comp elsewhere is untouched. One undoable step.
// Then comp between the takes with the take_* tools. Regions are in ABSOLUTE
// timeline beats (the same space as clip_split/clip_move/take_set_comp — read
// project_snapshot, no unit conversion). A RETAKE is ai_fix_clip_region again
// with the SAME region and no seed (a fresh random seed). Pending fixes are
// in-memory only: they DIE with the app process (and on a project switch) — an
// import for an unknown/expired job tells you to submit again.

server.registerTool(
  "ai_fix_clip_region",
  {
    title: "Fix a region of a clip with AI (submit)",
    description:
      "Submit an AI REPAINT of a REGION of an existing timeline clip (M6 v-b, " +
      "the 'fix this phrase with AI' flow) to the LOCAL ACE-Step-1.5 sidecar. " +
      "SUBMIT-ONLY: this bounces a dry, as-heard window of the target material " +
      "(the region plus contextSeconds of padding each side, clamped to the " +
      "clip/comp span), submits it, and returns IMMEDIATELY — it does NOT " +
      "change the project. This is step 1 of a three-step flow: " +
      "ai_fix_clip_region -> poll ai_generation_status with the returned jobId " +
      "until state \"succeeded\" -> ai_import_clip_fix to land it. The result " +
      "lands as a VIOLET take LANE comped in over EXACTLY [startBeat, endBeat) " +
      "— the original audio is never replaced and the comp elsewhere is " +
      "untouched (a comp splice); use the take_* tools to comp further between " +
      "the takes afterwards. To RETAKE, call this again with the SAME region " +
      "and OMIT seed (a fresh random seed each call). Pending fixes are " +
      "in-memory only and DIE with the app process (and on a project switch). " +
      "REQUIRES the sidecar to be healthy — call ai_sidecar_status (and " +
      "ai_sidecar_start if needed). Returns a placement echo {jobId, state, " +
      "queuePosition?, windowStartBeat, windowEndBeat, regionStartBeat, " +
      "regionEndBeat, repaintStartSeconds, repaintEndSeconds, bouncePath}.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track holding the clip to fix."),
      clipId: z
        .string()
        .min(1)
        .describe(
          "Id of the AUDIO clip to fix (from project_snapshot). A MIDI clip is rejected. " +
            "The clip may be a plain clip or an existing comp member — either works."
        ),
      startBeat: z
        .number()
        .describe(
          "Start of the region to repaint, in ABSOLUTE timeline beats (the same space as " +
            "clip_split/clip_move). Must lie inside the target clip/comp span."
        ),
      endBeat: z
        .number()
        .describe(
          "End of the region to repaint, in ABSOLUTE timeline beats. Must be greater than " +
            "startBeat and inside the span. The region must be at least 0.1 s long."
        ),
      prompt: z
        .string()
        .optional()
        .describe(
          "Style/caption text guiding the repainted region, e.g. \"clearer vocal, on pitch\". " +
            "Omit to keep the source's own musical context."
        ),
      lyrics: z
        .string()
        .optional()
        .describe(
          "Section-labeled lyrics (ACE-Step bracketed-structure format) for the region, when it " +
            "carries vocals. Omit/blank leaves the vocal content to the model."
        ),
      mode: z
        .enum(["conservative", "balanced", "aggressive"])
        .optional()
        .describe(
          "How strongly to regenerate the region: \"conservative\" stays closest to the original, " +
            "\"balanced\" (default) is the standard trade-off and the ONLY mode where strength has " +
            "any effect, \"aggressive\" most freely reimagines the region."
        ),
      strength: z
        .number()
        .min(0)
        .max(1)
        .optional()
        .describe(
          "0-1 — how far a \"balanced\"-mode fix may depart from the original in the region. Only " +
            "consulted when mode is \"balanced\". Omit for the sidecar's own default."
        ),
      seed: z
        .number()
        .int()
        .min(0)
        .optional()
        .describe(
          "Deterministic seed. OMIT for a fresh random seed each call — this is how you RETAKE " +
            "the same region: call again with the same startBeat/endBeat and no seed."
        ),
      contextSeconds: z
        .number()
        .min(1)
        .max(60)
        .optional()
        .describe(
          "Seconds of surrounding audio rendered each side of the region for boundary continuity " +
            "(clamped to the clip/comp span). Default 10. Larger = more context but a longer job."
        ),
      model: z
        .string()
        .optional()
        .describe(
          "DiT model name override. OPTIONAL and normally best left unset (repaint works on the " +
            "sidecar's default turbo tier, like ai_repaint_audio)."
        ),
    },
  },
  async (params) => toToolResult(() => bridge.send("ai.fixClipRegion", params))
);

server.registerTool(
  "ai_import_clip_fix",
  {
    title: "Import a finished clip fix (land the take)",
    description:
      "Land a FINISHED clip fix (M6 v-b) as a VIOLET take LANE comped in over " +
      "EXACTLY the region requested by ai_fix_clip_region. This is step 3 of " +
      "the flow: ai_fix_clip_region -> poll ai_generation_status until " +
      "\"succeeded\" -> ai_import_clip_fix. The original audio is NEVER " +
      "replaced and the comp elsewhere is untouched (a comp splice of the fix " +
      "region only) — one undoable \"AI Fix Take\" edit (edit_undo restores the " +
      "plain clip / previous comp). Comp between the takes afterwards with the " +
      "take_* tools. Do NOT call before the job has succeeded: a still-running " +
      "job returns an actionable error telling you to keep polling " +
      "ai_generation_status; an unknown jobId (pending fixes die with the app " +
      "process or on a project switch) returns an error telling you to submit " +
      "again with ai_fix_clip_region; a target that drifted beyond a pure move " +
      "(re-trimmed/re-stretched/re-gained, or the tempo changed) returns a " +
      "\"stale\" error naming what changed. Returns {trackId, groupId, laneId, " +
      "laneName (\"AI Fix N\"), group} — the take group with its lanes and comp.",
    inputSchema: {
      jobId: z
        .string()
        .min(1)
        .describe(
          "The jobId returned by ai_fix_clip_region. The job must have reached state " +
            "\"succeeded\" (check with ai_generation_status) — otherwise this errors."
        ),
    },
  },
  async (params) => toToolResult(() => bridge.send("ai.importClipFix", params))
);

// ---------------------------------------------------------------------------
// AI Copilot (in-app chat rail, M6 rail-c)
// ---------------------------------------------------------------------------
//
// These three tools drive the DAW app's OWN in-app AI copilot — a chat rail
// that executes control-protocol commands itself, through the same
// CommandRouter every other tool here goes through, in-process (never a
// second hop back out over this WebSocket). Depth is 1 by construction: MCP
// -> copilot -> in-process dispatch. The copilot's own tool catalog
// deliberately excludes ai_copilot_*, so it can never call itself.

server.registerTool(
  "ai_copilot_send",
  {
    title: "Send a message to the in-app AI copilot",
    description:
      "Drives the IN-APP copilot, which executes DAW commands itself against " +
      "a curated subset of this same command surface (tracks, clips, transport, " +
      "mixer, takes, rendering, AI generation, undo — NOT project open/save/new " +
      "or track removal, which stay human-initiated). Prefer the DIRECT tools " +
      "above for direct edits; use this to delegate a whole musical task in one " +
      "instruction (e.g. \"add a drum track and program a 2-bar house beat\") or " +
      "to test the copilot itself. The copilot CANNOT call itself — its catalog " +
      "excludes ai_copilot_send/state/reset, so recursion is impossible. Returns " +
      "immediately with `{turnId, status: \"running\"}`; the turn runs " +
      "asynchronously — poll ai_copilot_state with the returned turnId until its " +
      "status is done/failed/cancelled. Errors if a turn is already running " +
      "(poll or ai_copilot_reset first) or if the app has no AI provider " +
      "configured (points at the app's Settings panel).",
    inputSchema: {
      message: z
        .string()
        .min(1)
        .describe("The instruction to send to the copilot, e.g. \"add a bassline on the Bass track\"."),
    },
  },
  async ({ message }) => toToolResult(() => bridge.send("ai.copilotSend", { message }))
);

server.registerTool(
  "ai_copilot_state",
  {
    title: "Poll the in-app AI copilot's state",
    description:
      "Poll the in-app copilot's session state (the ai_generate_song / " +
      "ai_generation_status poll precedent). Returns `{status, currentTurnId?, " +
      "transcript}` where `status` is one of \"idle\", \"running\", \"done\", " +
      "\"failed\", \"cancelled\", and `transcript` is an array of entries " +
      "`{id, turnId, kind, text?, command?, ok?, summary?}` — `kind` is one of " +
      "\"user\" (your message), \"assistant\" (the copilot's reply text), " +
      "\"toolCall\" (a DAW command it invoked), \"toolResult\" (that command's " +
      "outcome), or \"failure\" (a turn-level error). Call ai_copilot_send first " +
      "to get a turnId.",
    inputSchema: {
      turnId: z
        .string()
        .optional()
        .describe(
          "Filter the transcript to one turn, from ai_copilot_send. Omit for the " +
            "whole session's transcript. An unknown/expired turnId is not an error " +
            "— it returns the copilot's current status with an empty transcript."
        ),
    },
  },
  async ({ turnId }) => toToolResult(() => bridge.send("ai.copilotState", { turnId }))
);

server.registerTool(
  "ai_copilot_reset",
  {
    title: "Reset the in-app AI copilot",
    description:
      "Cancel any in-flight copilot turn and clear its transcript/history back " +
      "to idle. No params. Use this to start a fresh conversation, or to " +
      "recover from a stuck/looping turn.",
  },
  async () => toToolResult(() => bridge.send("ai.copilotReset"))
);

// ---------------------------------------------------------------------------
// AI generation
// ---------------------------------------------------------------------------

server.registerTool(
  "generate_lyrics",
  {
    title: "Generate song lyrics",
    description:
      "Generate section-labeled song lyrics (e.g. [Verse 1], [Chorus], [Bridge]) " +
      "from a theme, optional style/genre, and optional structure. Uses Anthropic " +
      "(Claude) if ANTHROPIC_API_KEY is set, otherwise falls back to OpenAI if " +
      "OPENAI_API_KEY is set. Requires at least one of those keys in the " +
      "environment/.env.",
    inputSchema: {
      theme: z.string().min(1).describe("What the song is about, e.g. \"missing someone after they moved away\"."),
      style: z
        .string()
        .optional()
        .describe("Optional style/genre guidance, e.g. \"90s pop-punk\" or \"slow R&B ballad\"."),
      structure: z
        .string()
        .optional()
        .describe("Optional structure guidance, e.g. \"verse, chorus, verse, chorus, bridge, chorus\"."),
    },
  },
  async ({ theme, style, structure }) =>
    toToolResult(() => generateLyrics({ theme, style, structure }))
);

server.registerTool(
  "generate_song_suno",
  {
    title: "Generate a full song via Suno",
    description:
      "Generate a full song (music + optionally vocals) from a text prompt via " +
      "the Suno API, optionally supplying your own lyrics or requesting an " +
      "instrumental-only render. Requires SUNO_API_KEY in the environment/.env. " +
      "NOTE: the Suno API integration shape is not yet verified against Suno's " +
      "official current API — treat results/errors accordingly.",
    inputSchema: {
      prompt: z.string().min(1).describe("Description of the song to generate, e.g. mood, genre, instrumentation."),
      lyrics: z.string().optional().describe("Optional pre-written lyrics to sing (e.g. from generate_lyrics)."),
      instrumental: z
        .boolean()
        .optional()
        .describe("If true, generate an instrumental (no vocals). Defaults to false."),
    },
  },
  async ({ prompt, lyrics, instrumental }) =>
    toToolResult(() => generateSongSuno({ prompt, lyrics, instrumental }))
);

server.registerTool(
  "generate_image",
  {
    title: "Generate an image",
    description:
      "Generate an image from a text prompt using OpenAI's image API (model " +
      "from OPENAI_IMAGE_MODEL, default gpt-image-2) and save it as a PNG under " +
      "assets/generated/ in the repo. Returns the absolute file path of the " +
      "saved image. Requires OPENAI_API_KEY in the environment/.env.",
    inputSchema: {
      prompt: z.string().min(1).describe("Description of the image to generate."),
      size: z
        .string()
        .optional()
        .describe("Optional image size, e.g. \"1024x1024\" (provider-specific). Defaults to 1024x1024."),
    },
  },
  async ({ prompt, size }) => toToolResult(() => generateImage({ prompt, size }))
);
