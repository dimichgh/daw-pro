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
import { fileURLToPath } from "node:url";
import { statSync } from "node:fs";
import { DawBridge } from "./bridge.js";
import { generateImage, generateLyrics, generateSongSuno } from "./ai.js";
import { installMcpLogging, withMutatingRegistration } from "./mcp-log.js";
import { formatToolText } from "./result-spill.js";

/**
 * Build identity (m31-a). The MCP server PROCESS can be hours older than the
 * code it serves and nothing on the surface reveals it: a rebuilt
 * `dist/server.js` on disk proves the ARTIFACT changed, not that the running
 * process ever re-read it — a stdio MCP client only picks up a rebuild on
 * restart. `SERVER_MODULE_PATH` resolves to this module's OWN file
 * (`dist/server.js` once compiled — `import.meta.url` under NodeNext ESM),
 * so `serverBuildMtimeAtStartup` is captured once, at module load (i.e. at
 * process start), and `serverBuildMtimeNow()` re-stats the SAME path live on
 * every call. If a rebuild has landed since this process started, the two
 * disagree — THAT disagreement is the diagnosis (see app_connection_info).
 * Never throws: a stat failure (moved/deleted file) degrades to `null`
 * rather than breaking the tool.
 */
const SERVER_MODULE_PATH = fileURLToPath(import.meta.url);
const SERVER_PROCESS_STARTED_AT = new Date().toISOString();
function statMtimeIso(path: string): string | null {
  try {
    return statSync(path).mtime.toISOString();
  } catch {
    return null;
  }
}
const SERVER_BUILD_MTIME_AT_STARTUP = statMtimeIso(SERVER_MODULE_PATH);

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
  // `formatToolText` (src/result-spill.ts) IS the old one-liner below the size
  // limit — byte-identical `JSON.stringify(value, null, 2)`, and "ok" for the
  // commands with no result body (JSON.stringify(undefined) returns the JS
  // value `undefined`, not the string, which would produce an invalid MCP
  // content item and fail client-side validation even though the command
  // executed successfully). Above the limit it keeps every scalar/short field
  // inline and replaces only the oversized nodes with placeholders pointing at
  // a spill file — see that module's header for the two measured replies
  // (146,744 and 2,222,508 characters) this exists for. This is the ONE seam
  // every one of the 191 registrations passes through, via `toToolResult`.
  return { content: [{ type: "text", text: formatToolText(value) }] };
}

function errorResult(err: unknown): ToolResult {
  const message = err instanceof Error ? err.message : String(err);
  // The same size guard as the success path — an error is the other corner an
  // oversized payload can escape through (an app-side error that echoes the
  // payload it choked on would blow the caller's context just as effectively).
  // Below the limit `formatToolText` returns the message BYTE-IDENTICALLY, so
  // every actionable error sentence this server is built around is unchanged.
  return { content: [{ type: "text", text: formatToolText(message) }], isError: true };
}

/** Run `fn`, wrapping the outcome as MCP tool content either way (never throws). */
async function toToolResult(fn: () => Promise<unknown>): Promise<ToolResult> {
  try {
    return textResult(await fn());
  } catch (err) {
    return errorResult(err);
  }
}

/**
 * Strips a MIDI clip's `notes` array out of a tool result and replaces it
 * with `notesOmitted: true` + `noteCount`, so the response can never be
 * mistaken for a genuinely empty/note-less clip (m30-b's contract). Handles
 * all THREE shapes seen across the clip.* commands (m31-b, extended for the
 * clip_split follow-up): a single clip object (`notes` directly on `obj`);
 * a `{clips: [...]}` array (clip_remove_many / clip_move_many family) where
 * each entry is stripped independently; and a `{first, second}` pair
 * (clip_split) where both halves are stripped independently. Any other
 * additive field — including every id (`id`, `clipId`, `first.id`,
 * `second.id`, etc.) — passes through UNCHANGED in every shape; only the
 * `notes` array itself is ever removed. Non-MIDI results (no `notes` array
 * anywhere reachable) pass through unchanged too — this is a no-op on an
 * audio clip or an already-notes-free response.
 */
function stripNotesFromResult(result: unknown): unknown {
  if (!result || typeof result !== "object") return result;
  const stripOne = (obj: unknown): unknown => {
    if (!obj || typeof obj !== "object" || !Array.isArray((obj as any).notes)) return obj;
    const { notes, ...rest } = obj as Record<string, unknown>;
    return { ...rest, notesOmitted: true, noteCount: (notes as unknown[]).length };
  };
  const withClips = result as Record<string, unknown>;
  if (Array.isArray(withClips.clips)) {
    return { ...withClips, clips: withClips.clips.map(stripOne) };
  }
  if (withClips.first && typeof withClips.first === "object" && withClips.second && typeof withClips.second === "object") {
    return { ...withClips, first: stripOne(withClips.first), second: stripOne(withClips.second) };
  }
  return stripOne(result);
}

const bridge = new DawBridge();

export const server = new McpServer({
  name: "daw-pro",
  version: "0.1.0",
});

// Append-only call logging (m23-ca, src/mcp-log.ts) — MUST install before the
// first `registerTool(`/`server.registerTool(` call below, so every one of
// the 188 registrations (154 local wrapper + 34 direct, re-measured at
// breath-pad P1 by name-capturing regex — the figure here had been left at the
// m26-k value of 185 through two later additions)
// is instrumented. See that file's header for the full design (before-snapshot
// source/cost, redaction, seam choice).
installMcpLogging(server, bridge);

/**
 * Registers a MUTATING tool with a STRICT input schema (m16-e, audit F5's
 * MCP-side half). `server.registerTool` builds a permissive `z.object(shape)`
 * from a raw `ZodRawShape` — zod's default "strip" parse mode silently
 * DISCARDS any key not in the shape, before the handler (and therefore the
 * DAW's own wire-level `rejectUnknownKeys`) ever sees it. Verified directly
 * against this file's own `track_add` schema: `{name:"kind"}` was designed to
 * still create an audio track since 'kind' is optional, but
 * `{name:"x", type:"instrument"}` (the audit's measured typo) parses
 * successfully with `type` silently dropped and `kind` defaulting to
 * `"audio"` — the wire never even learns a `type` key was sent. A `.strict()`
 * schema turns that into a validation error AT THE MCP BOUNDARY instead,
 * closing the loop for the primary audience (an MCP-connected agent), not
 * just raw wire clients. Every MUTATING tool below registers through this
 * instead of `server.registerTool` directly, as do the three Table-B
 * provider-calling generation tools (`generate_lyrics`, `generate_song_suno`,
 * `generate_image`, m23-eh) — they have no backing wire command, so the DAW's
 * `rejectUnknownKeys` never runs for them either, making this wrapper their
 * ONLY unknown-key guard. Read-only tools (list/status/describe/snapshot)
 * are unaffected — an extra key on a pure read is not the hazard class this
 * closes (nothing it could silently misconfigure).
 */
function registerTool(
  name: string,
  config: {
    title: string;
    description: string;
    inputSchema?: Record<string, z.ZodTypeAny>;
  },
  handler: (...args: any[]) => Promise<ToolResult>
): void {
  const strictConfig = config.inputSchema
    ? { ...config, inputSchema: z.object(config.inputSchema).strict() }
    : config;
  // Marks this registration as MUTATING for mcp-log.ts's before-capture
  // decision (see that file's header) — the flag it reads is invisible at
  // the `server.registerTool` seam otherwise, since both this wrapper and
  // the 34 direct read-only registrations call the same patched method.
  withMutatingRegistration(() => {
    server.registerTool(name, strictConfig as any, handler as any);
  });
}

// ---------------------------------------------------------------------------
// Transport
// ---------------------------------------------------------------------------

registerTool(
  "transport_play",
  {
    title: "Start playback",
    description:
      "Start playback of the DAW session from the current transport position. " +
      "Has no effect (still ok) if already playing.",
    inputSchema: {},
  },
  async () => toToolResult(() => bridge.send("transport.play"))
);

registerTool(
  "transport_stop",
  {
    title: "Stop playback",
    description:
      "Stop playback. The playhead stays at its current position (use " +
      "transport_seek to move it). Has no effect (still ok) if already stopped.",
    inputSchema: {},
  },
  async () => toToolResult(() => bridge.send("transport.stop"))
);

registerTool(
  "transport_panic",
  {
    title: "Panic — silence stuck notes",
    description:
      "PANIC / all-notes-off. Silences a note that is stuck sounding — a key " +
      "whose note-off was lost because the cable was unplugged, the device was " +
      "removed, or the sending app crashed mid-note. Sends all-notes-off to " +
      "every instrument track and releases any held preview notes. Works while " +
      "stopped (transport_stop cannot clear a stuck note — it does nothing when " +
      "already stopped), and deliberately does NOT stop playback or recording, " +
      "so it is safe mid-take. Returns tracksFlushed, the number of instrument " +
      "renderers asked.",
    inputSchema: {},
  },
  async () => toToolResult(() => bridge.send("transport.panic"))
);

registerTool(
  "transport_seek",
  {
    title: "Move the playhead",
    description:
      "Move the transport playhead to a position, named EITHER as an absolute " +
      "`beats` value OR as a session `marker`. With `beats` (quarter notes from " +
      "the start of the timeline), beat 0 is the very start, beat 4 is the " +
      "downbeat of bar 2 in 4/4; must be >= 0. With `marker` (a marker's id or " +
      "its exact name, from marker_list), the playhead jumps to that section — " +
      "this is how you honor a request like \"drop at the second chorus\": call " +
      "marker_list, pick the right marker, then seek to it. Pass EXACTLY ONE of " +
      "`beats` or `marker` — passing both is rejected, and a `marker` that matches " +
      "no marker (or an ambiguous name shared by several) is an error naming the " +
      "field.",
    inputSchema: {
      beats: z
        .number()
        .min(0)
        .optional()
        .describe(
          "Absolute position in beats (quarter notes) from timeline start. Must be >= 0. " +
            "Omit when passing `marker`."
        ),
      marker: z
        .string()
        .optional()
        .describe(
          "A session marker's id or exact name (from marker_list) to seek to. Omit when " +
            "passing `beats`; passing both is rejected."
        ),
    },
  },
  async ({ beats, marker }) => toToolResult(() => bridge.send("transport.seek", { beats, marker }))
);

// ---------------------------------------------------------------------------
// Markers (m11-c) — named song-section anchors on the timeline
// ---------------------------------------------------------------------------

registerTool(
  "marker_add",
  {
    title: "Add a session marker",
    description:
      "Add a named marker at a beat on the timeline — a stable, human-meaningful " +
      "anchor for a song section like \"Intro\", \"Verse 1\", \"Chorus\", or \"Drop\". " +
      "Markers are how an agent and the musician navigate a song by MEANING rather " +
      "than raw beats: once placed, transport_seek can jump straight to one by id or " +
      "name. Adding a marker changes no audio or notes and is one undo step " +
      "(edit_undo). Returns the created marker {id, name, beat}.",
    inputSchema: {
      name: z
        .string()
        .optional()
        .describe('Marker name, e.g. "Chorus". Omit or pass empty for an auto name like "Marker 3".'),
      beat: z
        .number()
        .min(0)
        .describe("Absolute timeline position in beats (quarter notes) to place the marker. Must be >= 0."),
    },
  },
  async ({ name, beat }) => toToolResult(() => bridge.send("marker.add", { name, beat }))
);

registerTool(
  "marker_remove",
  {
    title: "Remove a session marker",
    description:
      "Remove a session marker by id (from marker_list / project_snapshot). This " +
      "deletes ONLY the marker anchor — never any audio, clips, or notes. Reversible " +
      "with edit_undo. Errors with a field-named message when no marker has that id. " +
      "Returns {removed: true}.",
    inputSchema: {
      markerId: z.string().describe("Id of the marker to remove, from marker_list or project_snapshot."),
    },
  },
  async ({ markerId }) => toToolResult(() => bridge.send("marker.remove", { markerId }))
);

registerTool(
  "marker_rename",
  {
    title: "Rename a session marker",
    description:
      "Rename an existing session marker (e.g. \"Marker 2\" -> \"Chorus\"). An empty " +
      "or unchanged name is a no-op and adds no undo step; otherwise it is one undo " +
      "step (edit_undo). Errors with a field-named message when no marker has that " +
      "id. Returns the updated marker {id, name, beat}.",
    inputSchema: {
      markerId: z.string().describe("Id of the marker to rename, from marker_list or project_snapshot."),
      name: z.string().describe("New marker name (non-empty after trimming whitespace)."),
    },
  },
  async ({ markerId, name }) => toToolResult(() => bridge.send("marker.rename", { markerId, name }))
);

registerTool(
  "marker_move",
  {
    title: "Move a session marker",
    description:
      "Move a session marker to a new beat on the timeline. A live scrub of several " +
      "moves within a moment coalesces into a single undo step (edit_undo). Errors " +
      "with a field-named message when no marker has that id. Returns the moved " +
      "marker {id, name, beat}.",
    inputSchema: {
      markerId: z.string().describe("Id of the marker to move, from marker_list or project_snapshot."),
      beat: z
        .number()
        .min(0)
        .describe("New absolute timeline position in beats (quarter notes). Clamped to >= 0."),
    },
  },
  async ({ markerId, beat }) => toToolResult(() => bridge.send("marker.move", { markerId, beat }))
);

server.registerTool(
  "marker_list",
  {
    title: "List session markers",
    description:
      "List every session marker, sorted by beat: {markers: [{id, name, beat}]}. This " +
      "is the lookup an agent uses to turn a section request into a position — e.g. " +
      "for \"drop at the second chorus\", call marker_list, find the second marker " +
      "named like a chorus, then transport_seek to it by id. No params. (marker data " +
      "also rides project_snapshot, but this is the focused call.)",
    inputSchema: {},
  },
  async () => toToolResult(() => bridge.send("marker.list", {}))
);

registerTool(
  "transport_set_tempo",
  {
    title: "Set the project tempo",
    description:
      "Set ONE project-wide tempo in BPM (beats per minute), i.e. quarter " +
      "notes per minute. Valid range 20-400 BPM (typical music ranges roughly " +
      "60-200 BPM; e.g. 60 = slow ballad, 120 = common pop/house tempo, " +
      "174 = drum & bass). This is the single-tempo fast path: on a project " +
      "that already has a MULTI-SEGMENT tempo map it is rejected with a message " +
      "pointing at tempo_set_map (which edits the map without flattening it).",
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
  "tempo_map",
  {
    title: "Read the tempo & meter maps",
    description:
      "Read the project's tempo map and time-signature (meter) map: " +
      "{segments: [{startBeat, bpm}], meterChanges: [{startBeat, beatsPerBar, beatUnit}], " +
      "mapRevision}. There is always at least one tempo segment (the base tempo " +
      "at beat 0) and one meter change, even for a single-tempo song. Call this " +
      "before tempo_set_map to see the current shape; combine with marker_list " +
      "to place tempo changes at section boundaries. No params.",
    inputSchema: {},
  },
  async () => toToolResult(() => bridge.send("tempo.map", {}))
);

registerTool(
  "tempo_set_map",
  {
    title: "Set the tempo & meter maps",
    description:
      "Replace the whole project tempo map, and — in the SAME call, via the " +
      "optional meterChanges param — the time-signature (meter) map too: " +
      "this is how you author tempo changes across a song (e.g. a slower " +
      "intro then a faster drop) AND/OR time-signature changes (e.g. a 3/4 " +
      "waltz section inside a 4/4 song). Pass the FULL ordered list of tempo " +
      "segments: each segment is a constant tempo that starts at a beat and " +
      "runs until the next segment. Segment 0 MUST start at beat 0 (the base " +
      "tempo); beats must be strictly increasing. To change time signature " +
      "as well, also pass meterChanges (see its param description below) — " +
      "omit meterChanges entirely to leave the current meter untouched. " +
      "Beats stay the source of truth — notes and clips keep their beat " +
      "positions, only their wall-clock timing changes. For one project-wide " +
      "tempo with no time-signature change use transport_set_tempo instead. " +
      "One undoable step (edit_undo). Returns the resolved maps.",
    inputSchema: {
      segments: z
        .array(
          z.object({
            startBeat: z
              .number()
              .min(0)
              .describe("Beat where this tempo begins. Segment 0 must be 0; later segments strictly increasing."),
            bpm: z
              .number()
              .min(20)
              .max(400)
              .describe("Tempo in BPM for this segment. Range 20-400."),
          })
            // `.strict()` (m30-c): a typo'd field (e.g. "bmp") inside one
            // `segments` element would otherwise be silently stripped
            // instead of rejected.
            .strict()
        )
        .min(1)
        .describe("Ordered tempo segments; segment 0 at beat 0 sets the base tempo."),
      meterChanges: z
        .array(
          z.object({
            startBeat: z
              .number()
              .min(0)
              .describe("Beat where this time signature begins. Change 0 must be 0."),
            beatsPerBar: z
              .number()
              .int()
              .min(1)
              .describe("Beats per bar — the top number (e.g. 3 for 3/4)."),
            beatUnit: z
              .number()
              .int()
              .min(1)
              .describe("Beat unit — the bottom number (e.g. 4 for 3/4)."),
          })
            // `.strict()` (m30-c): same hole, one `meterChanges` element.
            .strict()
        )
        .min(1)
        .optional()
        .describe(
          "Optional time-signature changes; omit to leave the meter unchanged. " +
            "Change 0 must be at beat 0; each later change must fall on a barline."
        ),
    },
  },
  async ({ segments, meterChanges }) =>
    toToolResult(() =>
      bridge.send("tempo.setMap", meterChanges ? { segments, meterChanges } : { segments })
    )
);

registerTool(
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
      "may trigger the system permission prompt. LOOP-CYCLE TAKES: if the " +
      "loop is enabled (transport_set_loop) when you call this, recording " +
      "jumps to the loop start first, plays the loop for real, and each " +
      "full pass through the loop lands as its own take lane on ONE take " +
      "group — comp with the existing take_* tools (the newest lane is " +
      "comped by default). Stopping mid-cycle still lands an honest partial " +
      "lane for whatever was captured — the take group keeps that partial " +
      "lane, and default comp selection plays it (the NEWEST lane, even " +
      "when it's a mid-cycle partial) exactly as it would any complete " +
      "lane; this is industry-consistent (matches Logic's take selection) " +
      "and intentional, not a bug — call take_select to comp an earlier, " +
      "complete lane instead. There is no separate flag for partial-take " +
      "behavior; it's entirely decided by whether the loop is on, so " +
      "disable the loop first if you want one plain linear take instead. " +
      "This is rejected if a punch window is ALSO enabled (see " +
      "transport_set_punch), or if the loop is shorter than 1 second per " +
      "cycle.",
    inputSchema: {},
  },
  async () => toToolResult(() => bridge.send("transport.record"))
);

registerTool(
  "transport_set_loop",
  {
    title: "Enable or disable loop playback",
    description:
      "Enable or disable loop-region playback between startBeat and endBeat " +
      "(beats/quarter notes). When looping is enabled, the playhead wraps from " +
      "the loop end back to the loop start during playback instead of playing " +
      "past it. endBeat must be greater than startBeat. When enabling the loop " +
      "for the first time, provide both startBeat and endBeat; if either is " +
      "omitted, the previously set value is kept. Enabling the loop before " +
      "calling transport_record changes what recording does: it turns into " +
      "loop-cycle take recording, where each pass through the loop lands as " +
      "its own take lane (see transport_record for the details). Refused " +
      "while a recording is in progress — the loop window is frozen for the " +
      "whole take, so stop recording first. Returns the updated transport " +
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

registerTool(
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
      "error. Punch and loop-cycle takes (see transport_set_loop, " +
      "transport_record) cannot be combined — recording is rejected if both " +
      "a punch window and the loop are enabled at once; disable one first. " +
      "Returns the updated transport state.",
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

registerTool(
  "transport_set_metronome",
  {
    title: "Enable or disable the metronome click",
    description:
      "Toggle the metronome click heard during playback and recording (the " +
      "downbeat of each bar is accented). `countInBars` sets how many bars of " +
      "count-in clicks play immediately before recording starts (0 = no " +
      "count-in). Count-in clicks always sound, even if the metronome itself " +
      "is disabled — and the recorded take never includes the count-in audio. " +
      "NEW PROJECTS DEFAULT TO 1 BAR (m23-cy); a project that stored a " +
      "different value, including 0, keeps it. " +
      "IMPORTANT — a count-in does NOT make an early note survive: it DELAYS " +
      "the take's anchor by that many bars, and notes played BEFORE the anchor " +
      "(i.e. during the count-in) are discarded, exactly like notes played in " +
      "the first instants of a take with no count-in. What it buys you is an " +
      "audible cue for when the take actually starts. Measured at 120 BPM 4/4: " +
      "with countInBars 1, a note struck 2321 ms after transport.record landed " +
      "at beat 0.488, while one struck at 428 ms recorded nothing. " +
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

registerTool(
  "transport_set_stop_at_content_end",
  {
    title: "Stop playback at the end of the song",
    description:
      "Control whether playback stops automatically when the playhead reaches " +
      "the end of the last clip (the end of the song). ON by default. Turn it " +
      "OFF to let the transport keep running into empty space past the last " +
      "clip, which is what Logic and Live do by default. A recording take " +
      "NEVER stops at the content end regardless of this setting — recording " +
      "past the end of existing material is the point of recording — and an " +
      "active loop takes precedence, cycling forever rather than stopping. " +
      "This is a session preference, not project data: it is not saved with " +
      "the project, edit_undo does not affect it, and it resets to on when the " +
      "app restarts. Returns `{stopAtContentEnd, contentEndBeat}`, where " +
      "`contentEndBeat` is the measured end of the last clip across all tracks " +
      "(0 when the project has no clips). On project_snapshot the setting " +
      "appears under the INVERTED name `runsPastContentEnd`, and only when it " +
      "has been turned off: absent means playback stops at the content end (the " +
      "default), `true` means it free-runs past the last clip. It is never " +
      "`false`. Read the snapshot key by its own name and it is never " +
      "misleading — do not look for `stopAtContentEnd` there.",
    inputSchema: {
      enabled: z
        .boolean()
        .describe(
          "True to stop playback at the end of the last clip, false to keep running past it."
        ),
    },
  },
  async ({ enabled }) =>
    toToolResult(() => bridge.send("transport.setStopAtContentEnd", { enabled }))
);

// ---------------------------------------------------------------------------
// Tracks
// ---------------------------------------------------------------------------

registerTool(
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

registerTool(
  "track_remove",
  {
    title: "Remove a track",
    description:
      "Permanently remove a track (and its clips) from the session by id. " +
      "Refused while a recording is in progress (it re-wires the audio graph, " +
      "which would truncate the take) — stop recording first.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track to remove, from project_snapshot."),
    },
  },
  async ({ trackId }) => toToolResult(() => bridge.send("track.remove", { trackId }))
);

registerTool(
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

registerTool(
  "track_reorder",
  {
    title: "Move a track up or down the track list",
    description:
      "Move a track to a different position in the track list — how you group " +
      "a session (all the drums together, the vocals under them) instead of " +
      "leaving tracks in whatever order they were created. `index` is the " +
      "FINAL position the track ends up at, counting from 0 at the TOP: with " +
      "tracks [Kick, Snare, Bass, Vox], moving Kick to index 2 gives [Snare, " +
      "Bass, Kick, Vox] (this is NOT an \"insert before\" offset — ask for the " +
      "slot you want the track to occupy afterwards). Out-of-range values " +
      "clamp: a huge index means \"last\", a negative one means \"first\". " +
      "Moving a track to the position it already holds changes nothing and " +
      "adds no undo step. Track order is organizational only: it never changes " +
      "what anything sounds like and never touches routing, sends, effects, " +
      "clips or automation — and because it cannot reach the audio graph, it " +
      "is allowed even while recording. One undoable step (edit_undo). " +
      "Returns {index, order} — the index the track landed at, and the ids of " +
      "every track in the resulting order.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track to move, from project_snapshot."),
      index: z
        .number()
        .int()
        .describe(
          "The FINAL position the track should end up at, 0 = top of the list. " +
            "Out-of-range values clamp to the first/last slot."
        ),
    },
  },
  async ({ trackId, index }: { trackId: string; index: number }) =>
    toToolResult(() => bridge.send("track.reorder", { trackId, index }))
);

registerTool(
  "track_set_volume",
  {
    title: "Set track volume",
    description:
      "Set a track's fader volume as a linear gain multiplier, where 1.0 is " +
      "unity gain (0 dB, no change). Range 0-2: 0 is silence, 0.5 is roughly " +
      "-6 dB, 2.0 is roughly +6 dB. This is linear gain, not decibels. " +
      "⚠️ CHECK THE REPLY: it normally reads \"ok\", but comes back as " +
      "`{automationControlled: true, automationPointCount}` when an active " +
      "VOLUME AUTOMATION LANE — not the value you just passed — governs what " +
      "is heard and what renders, so this call will NOT change the audible " +
      "level. (The keys are absent when nothing is overriding you.) " +
      "The write still lands: it is stored, undoable, moves " +
      "the fader, and takes effect the moment the lane is disabled " +
      "(automation_set_lane_enabled), emptied, or removed. To change an " +
      "automated level, edit the lane with automation_set_points instead.",
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

registerTool(
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

registerTool(
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

registerTool(
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

registerTool(
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

/** A zone's dynamic-layer crossfade (m27 leg B / SFZ pp/mf/ff-layer technique).
 * Nested rather than nine flat `sampler.zones[i].xf*` fields because the nine
 * bounds only mean anything together, and grouping them under one optional
 * key lets a zone with no crossfade omit all nine at once instead of nine
 * individual omissions. Mirrors `SamplerCrossfade` (Sources/DAWCore/Model.swift)
 * field-for-field. */
const samplerCrossfadeSchema = z
  .object({
    controller: z
      .number()
      .int()
      .min(0)
      .max(127)
      .optional()
      .describe(
        "CC number driving the CONTINUOUS crossfade domain (SFZ `xfin_locc<N>`/" +
          "`xfin_hicc<N>`/`xfout_locc<N>`/`xfout_hicc<N>`) — re-evaluated while a note " +
          "SOUNDS, so a held note really does change layer as this controller moves. " +
          "Omitted = the CC domain is off; the velocity-domain bounds below (if any) " +
          "still apply."
      ),
    ccInLo: z
      .number()
      .int()
      .min(0)
      .max(127)
      .optional()
      .describe(
        "CC value (raw MIDI 0-127, SFZ `xfin_locc`) where this zone starts fading IN. " +
          "Only meaningful with `controller` set. Together with `ccInHi` this zone's " +
          "gain ramps 0→1 (equal-power curve) as the controller rises through " +
          "[ccInLo, ccInHi]."
      ),
    ccInHi: z
      .number()
      .int()
      .min(0)
      .max(127)
      .optional()
      .describe(
        "CC value (raw MIDI 0-127, SFZ `xfin_hicc`) where this zone finishes fading " +
          "in. See `ccInLo`."
      ),
    ccOutLo: z
      .number()
      .int()
      .min(0)
      .max(127)
      .optional()
      .describe(
        "CC value (raw MIDI 0-127, SFZ `xfout_locc`) where this zone starts fading " +
          "OUT. Together with `ccOutHi` this zone's gain ramps 1→0 as the controller " +
          "rises through [ccOutLo, ccOutHi]."
      ),
    ccOutHi: z
      .number()
      .int()
      .min(0)
      .max(127)
      .optional()
      .describe(
        "CC value (raw MIDI 0-127, SFZ `xfout_hicc`) where this zone finishes fading " +
          "out. See `ccOutLo`."
      ),
    velInLo: z
      .number()
      .int()
      .min(0)
      .max(127)
      .optional()
      .describe(
        "Note-on velocity (raw MIDI 0-127, SFZ `xfin_lovel`) where this zone starts " +
          "fading IN. FIXED AT NOTE-ON, unlike the CC domain above — this smooths " +
          "layer choice ACROSS successive notes and cannot change anything within one " +
          "held note. Together with `velInHi` this zone's gain ramps 0→1 as note-on " +
          "velocity rises through [velInLo, velInHi]."
      ),
    velInHi: z
      .number()
      .int()
      .min(0)
      .max(127)
      .optional()
      .describe(
        "Note-on velocity (raw MIDI 0-127, SFZ `xfin_hivel`) where this zone finishes " +
          "fading in. See `velInLo`."
      ),
    velOutLo: z
      .number()
      .int()
      .min(0)
      .max(127)
      .optional()
      .describe(
        "Note-on velocity (raw MIDI 0-127, SFZ `xfout_lovel`) where this zone starts " +
          "fading OUT. Together with `velOutHi` this zone's gain ramps 1→0 as note-on " +
          "velocity rises through [velOutLo, velOutHi]."
      ),
    velOutHi: z
      .number()
      .int()
      .min(0)
      .max(127)
      .optional()
      .describe(
        "Note-on velocity (raw MIDI 0-127, SFZ `xfout_hivel`) where this zone " +
          "finishes fading out. See `velOutLo`."
      ),
  })
  // `.strict()` (m26/sax-team defect B precedent — see `samplerZonePatchSchema`
  // below): without it a typo'd field inside `crossfade` (e.g. "ccInL0") is
  // silently stripped by zod's default parse mode instead of rejected, and
  // the call still reports success with one fewer field than intended.
  .strict()
  .optional()
  .describe(
    "Dynamic-layer crossfade for THIS zone — the SFZ pp/mf/ff-layer technique: fade " +
      "this zone's gain in/out against a CC stream and/or note-on velocity instead of " +
      "a hard keyzone/velocity-range switch, so a library with separately-recorded " +
      "dynamic layers blends between them rather than clicking from one to the next. " +
      "Two INDEPENDENT domains, and a zone may use either or both (their gains " +
      "multiply): the CC domain (`controller` + `ccInLo`/`ccInHi`/`ccOutLo`/`ccOutHi`) " +
      "re-evaluates continuously while a note holds; the velocity domain " +
      "(`velInLo`/`velInHi`/`velOutLo`/`velOutHi`) is fixed at note-on. Any bound you " +
      "omit means \"no fade in that direction\" and resolves to a gain of exactly " +
      "1.0 — so a zone with every field omitted (the default) is bit-identical to " +
      "having no crossfade at all. Curve is SFZ's documented default, power " +
      "(equal-power / constant loudness through the fade); there is no way to select " +
      "a different curve. Typical use: give the LOUD/BRIGHT layer's zone `ccInLo`/" +
      "`ccInHi` (or `velInLo`/`velInHi`) to fade it IN as the controller/velocity " +
      "rises, and give the SOFT/DARK layer's zone the matching `ccOutLo`/`ccOutHi` " +
      "(or `velOutLo`/`velOutHi`) to fade it OUT over the same span."
  );

const samplerZoneSchema = z.object({
  path: z
    .string()
    .min(1)
    .describe(
      "REQUIRED. Absolute file path to this zone's sample audio file (wav/aiff/etc.), or " +
        "the name of a sample the app ships, written `builtin:<name>`. The file is copied " +
        "into the project bundle on project_save, so the project stays portable — always " +
        "pass the original source path here, not a bundle-relative one. " +
        "The only bundled sample today is `builtin:test-tone-a4` (m30-a): a 0.35 s A4 " +
        "one-shot whose root pitch is MIDI 69, there so the sampler can be played and " +
        "smoke-tested on a machine with no sample library of its own — e.g. to exercise " +
        "`bendRangeSemitones` or `voiceMode`. A `builtin:` name that does not exist is " +
        "REFUSED, and the error lists the ones that do; it is never silently accepted."
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
    .max(2)
    .optional()
    .describe(
      "This zone's own output level, 0-2, on top of the sampler's overall `gain`. Values " +
        "above 1 boost — 2.0 = +6 dB, matching what imported sample libraries can ask for. " +
        "Defaults to 1."
    ),
  minVelocity: z
    .number()
    .int()
    .min(0)
    .max(127)
    .optional()
    .describe(
      "Lowest MIDI velocity, 0-127, this zone responds to (inclusive). Together with " +
        "`maxVelocity` this selects the VELOCITY LAYER: give soft/loud recordings of the same " +
        "key adjacent velocity ranges (e.g. 0-62 and 63-127) and the played velocity picks " +
        "which sample sounds. Defaults to 0 (all velocities)."
    ),
  maxVelocity: z
    .number()
    .int()
    .min(0)
    .max(127)
    .optional()
    .describe(
      "Highest MIDI velocity, 0-127, this zone responds to (inclusive). Defaults to 127. " +
        "See `minVelocity` for how velocity ranges build layered instruments."
    ),
  group: z
    .number()
    .int()
    .min(0)
    .optional()
    .describe(
      "Layering identity (integer ≥ 0). Zones in DIFFERENT groups LAYER — one note-on fires " +
        "one voice per group, so put e.g. a close-mic and a room-mic sample in two groups to " +
        "hear both together. Zones in the SAME group ALTERNATE — at most one of them sounds " +
        "per note-on (velocity ranges, round-robin, and random gates decide which). Omitted " +
        "= group 0, matching all other omitted-group zones (the classic first-match keymap)."
    ),
  seqLength: z
    .number()
    .int()
    .min(1)
    .optional()
    .describe(
      "Round-robin cycle length N: this zone plays only on its `seqPosition`-th of every N " +
        "consecutive matching note-ons. Give 4 alternate takes of the same drum hit " +
        "seqLength 4 with seqPosition 1,2,3,4 and repeated hits rotate through them. " +
        "Omitted or 1 = no round-robin (the zone is always eligible)."
    ),
  seqPosition: z
    .number()
    .int()
    .min(1)
    .optional()
    .describe(
      "This zone's 1-based slot in its `seqLength` round-robin cycle, 1-seqLength. " +
        "Defaults to 1. Meaningless unless `seqLength` is 2 or more."
    ),
  randMin: z
    .number()
    .min(0)
    .max(1)
    .optional()
    .describe(
      "Lower edge, 0-1, of this zone's random-alternation window. Each note-on draws one " +
        "random number in [0,1) and the zone is eligible only when the draw falls in " +
        "[randMin, randMax). Split same-group zones over e.g. 0-0.5 and 0.5-1 for " +
        "humanized 50/50 sample alternation. Defaults to 0."
    ),
  randMax: z
    .number()
    .min(0)
    .max(1)
    .optional()
    .describe(
      "Upper edge, 0-1, of this zone's random-alternation window (exclusive, except 1.0 " +
        "which closes the interval so a full-span zone always qualifies). Defaults to 1. " +
        "See `randMin`."
    ),
  tuneCents: z
    .number()
    .min(-4800)
    .max(4800)
    .optional()
    .describe(
      "Fine/coarse pitch offset for this zone in CENTS (100 cents = 1 semitone), " +
        "-4800 to +4800. Use small values to tune slightly-off samples into pitch " +
        "(e.g. -12), or multiples of 100 to transpose a sample without changing its " +
        "keyzone. Omitted = 0 (no retune)."
    ),
  pan: z
    .number()
    .min(-1)
    .max(1)
    .optional()
    .describe(
      "Stereo placement for this zone, -1 (hard left) to +1 (hard right), constant-power " +
        "law. Place multi-sampled drums across the stereo field (hi-hat slightly left, " +
        "ride right) without extra tracks. NOTE: omitting pan keeps the zone's legacy " +
        "full-level dual-mono behavior; an EXPLICIT 0 engages the pan law's -3 dB center — " +
        "slightly quieter than omitted. Omit it unless you want panning."
    ),
  ampVelTrack: z
    .number()
    .min(0)
    .max(1)
    .optional()
    .describe(
      "How strongly velocity drives this zone's loudness, 0-1. 1 (default) = full " +
        "tracking (velocity 64 plays at ~half level); 0 = velocity ignored — every hit " +
        "plays at full level, useful for consistent drum samples or organs; between = " +
        "reduced dynamic range. Amplitude = (1 - t + t*velocity/127) * gain."
    ),
  oneShot: z
    .boolean()
    .optional()
    .describe(
      "Per-zone one-shot override. true = this zone's notes always play to the sample's " +
        "end, ignoring note-off — the drum/percussion behavior — even when the sampler's " +
        "global `oneShot` is false. false = this zone follows note-off (releases) even " +
        "under a global one-shot. Omitted = inherit the sampler's global `oneShot`."
    ),
  startFrame: z
    .number()
    .int()
    .min(0)
    .optional()
    .describe(
      "First SOURCE-FILE frame to play, in the sample file's own frames (at ITS sample " +
        "rate, e.g. frame 44100 = 1.0 s into a 44.1 kHz file). Use it to skip silence or " +
        "an unwanted transient at the head of a sample. Omitted = 0 (play from the start)."
    ),
  endFrame: z
    .number()
    .int()
    .min(1)
    .optional()
    .describe(
      "Last SOURCE-FILE frame (exclusive) to play — the voice ends there instead of at " +
        "the file's end. Must exceed `startFrame` (it is raised to startFrame+1 if not); " +
        "both clamp to the real file length. Use with startFrame to excerpt one hit from " +
        "a longer recording. Omitted = the file's end."
    ),
  attack: z
    .number()
    .min(0)
    .max(1)
    .optional()
    .describe(
      "Per-zone amplitude envelope ATTACK in seconds, 0-1: fade-in time from note-on to " +
        "full level. Overrides the sampler's global `attack` for this zone only. " +
        "Omitted = use the global attack."
    ),
  decay: z
    .number()
    .min(0)
    .max(8)
    .optional()
    .describe(
      "Per-zone amplitude envelope DECAY in seconds, 0-8: after the attack peak, how long " +
        "the level takes to fall to `sustain`. Together with sustain this shapes pluck/pad " +
        "character from the same sample (short decay + low sustain = plucky). Omitted or " +
        "0 = no decay stage (the level holds at peak — the classic sampler behavior)."
    ),
  sustain: z
    .number()
    .min(0)
    .max(1)
    .optional()
    .describe(
      "Per-zone amplitude envelope SUSTAIN level, 0-1: the level held after the decay " +
        "stage until note-off (1 = hold at full peak, 0.3 = held notes settle much " +
        "quieter, 0 = notes decay to silence even while held). Only audible when `decay` " +
        "is set. Omitted = 1."
    ),
  release: z
    .number()
    .min(0.001)
    .max(8)
    .optional()
    .describe(
      "Per-zone amplitude envelope RELEASE in seconds, 0.001-8: fade-out time after " +
        "note-off. Overrides the sampler's global `release` for this zone only — give a " +
        "piano-like zone a longer tail than the kit around it. Omitted = use the global " +
        "release."
    ),
  loopMode: z
    .enum(["sustain", "continuous"])
    .optional()
    .describe(
      "Loop this zone's playback across `loopStart`/`loopEnd` instead of playing the " +
        "sample once start-to-end. \"sustain\": loops while the note continues (held, " +
        "or held-by-sustain-pedal/CC64), then plays out past `loopEnd` to the sample's " +
        "real end on release — the classic library idiom for a stable middle plus a " +
        "natural tail. \"continuous\": loops straight through release as well, with no " +
        "tail. LOOPING WINS OVER ONE-SHOT: a zone with `loopMode` set is NEVER treated " +
        "as one-shot, even when the sampler's global `oneShot` or this zone's own " +
        "`oneShot` says otherwise — a loop needs a note-off (or held-through-release) " +
        "boundary to mean anything, so one-shot is simply not consulted once a loop is " +
        "set. Omitted = no loop (the pre-existing behavior): the zone plays its span " +
        "once per trigger."
    ),
  loopStart: z
    .number()
    .int()
    .min(0)
    .optional()
    .describe(
      "First SOURCE-FILE frame (inclusive) of the loop, in the sample file's own " +
        "frames — same convention as `startFrame`. Only takes effect when `loopMode` " +
        "is also set. Omitted = 0 (loop from the file's start, or from `startFrame` if " +
        "that's set — the engine further clamps into the zone's real playable span)."
    ),
  loopEnd: z
    .number()
    .int()
    .min(1)
    .optional()
    .describe(
      "Last SOURCE-FILE frame of the loop, EXCLUSIVE — matching `endFrame`'s " +
        "convention. Only takes effect when `loopMode` is also set. Must exceed " +
        "`loopStart`: a value at or below it is RAISED to loopStart+1 (never swapped, " +
        "matching `endFrame`'s own rule), and both clamp to the zone's real playable " +
        "span. Omitted = the zone's resolved end (its `endFrame`, or the sample's own " +
        "end)."
    ),
  crossfade: samplerCrossfadeSchema,
  reverse: z
    .boolean()
    .optional()
    .describe(
      "Play this zone BACKWARDS (m32-d): the note starts at the last frame of the zone's " +
        "span (`endFrame`, or the file's end) and reads toward `startFrame`, at the same " +
        "repitched speed a forward note would use. This is the classic reversed-cymbal / " +
        "reversed-vocal swell, and it costs no extra memory — the audio is read backwards " +
        "in place, never copied. REVERSED ZONES IGNORE LOOPS IN THIS VERSION: a zone with " +
        "both `reverse` and `loopMode` plays its span once, backwards, and the loop is " +
        "dropped with a note in the sampler's zone-load notes (backwards-loop behaviour is " +
        "deliberately not guessed at). `attack`/`release` are NOT swapped: they shape what " +
        "you HEAR, so a short release still trims the tail of the reversed sound. " +
        "Omitted or false = forward, exactly as before."
    ),
  chokeGroup: z
    .number()
    .int()
    .min(0)
    .max(63)
    .optional()
    .describe(
      "CHOKE group, 0-63 (m32-f). Playing any zone in this group ENDS whatever is already " +
        "sounding from the same group: the open/closed hi-hat rule, and the way you stop " +
        "chopped slices ringing into each other so a re-chop sounds tight instead of like " +
        "the original loose loop. Give every hat zone chokeGroup 1 and the closed hat cuts " +
        "the open one, while kicks and snares in the same instrument stay fully polyphonic. " +
        "NOT THE SAME FIELD AS `group`: `group` decides WHICH zone fires on a new note " +
        "(round-robin and alternate layers are built on it), while `chokeGroup` ends notes " +
        "that are ALREADY PLAYING. A zone can use both, independently. A choked note is not " +
        "cut dead — it goes into its own `release`, so a zone with a long `release` chokes " +
        "slowly; shorten that zone's `release` for a tight choke. Zones layered by the SAME " +
        "note-on never choke each other, and a note never chokes itself. " +
        "Omitted = no choke (unchanged behaviour)."
    ),
})
  // `.strict()` (sax-team defect B, 2026-08-20): closes the same hole one
  // level up from `samplerCrossfadeSchema` above — a typo'd field inside one
  // element of `track_set_instrument`'s wholesale `sampler.zones` array (e.g.
  // "minPtich") would otherwise be silently stripped instead of rejected.
  // `samplerZonePatchSchema` below reuses this schema's `.shape` (not this
  // schema itself), so its own independent `.strict()` is unaffected either
  // way — this fixes the SEPARATE `zones` (replace) path, not `zonePatches`
  // (merge), which was already closed.
  .strict();

const samplerSchema = z
  .object({
    zones: z
      .array(samplerZoneSchema)
      .optional()
      .describe(
        "OPTIONAL. Omit it to leave the track's CURRENT zones exactly as they are — that " +
          "is how you change a global (say `release`) on an imported 309-zone library " +
          "without reading back and resending every zone. When PRESENT this array " +
          "REPLACES the whole keyzone map, so `zones: []` is the deliberate way to clear " +
          "a sampler, and a partial list silently drops the zones you left out. A zone's " +
          "`id` (from a prior instrument_describe_sampler/project_snapshot) IS honoured " +
          "when it already names a zone on THIS track; an id that doesn't (including one " +
          "copied from a different track) is re-minted and the substitution is reported in " +
          "the response's `remintedZoneIDs` — but this array can still only REPLACE, never " +
          "MERGE. To edit a handful of zones by id and leave the rest of a large library " +
          "completely untouched, use instrument_set_sampler_zones instead. " +
          "The sampler's keyzone map. For a played note, each GROUP of zones fires at most " +
          "one voice: within a group, the first zone (array order) whose pitch AND velocity " +
          "ranges contain the note and whose round-robin/random gates pass is the one that " +
          "plays; zones in different `group`s layer simultaneously. Zones without the " +
          "optional selection fields all share group 0 with full ranges and no gates, so " +
          "the classic behavior holds: the FIRST zone containing the pitch plays, exactly " +
          "one voice per note. Use one zone for a single mapped sample; non-overlapping " +
          "pitch ranges to split samples across the keyboard; velocity ranges for " +
          "soft/loud layers; `seqLength`/`seqPosition` or `randMin`/`randMax` within a " +
          "group for round-robin/random alternation; different `group`s to stack sounds; " +
          "`reverse` to play one zone backwards for a swell; `chokeGroup` so one pad cuts " +
          "another off (the open/closed hi-hat rule)."
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
    expressionModDepth: z
      .number()
      .min(0)
      .max(1)
      .optional()
      .describe(
        "How far CC 1 (mod wheel) and CC 2 (breath) attenuate loudness, 0-1. NIL/0 IS " +
          "OFF, not neutral-at-full: at 0 the CC1/CC2 attenuator is skipped and CC 11 " +
          "(expression) alone drives continuous loudness on the built-in Sampler — " +
          "clip_set_controller_lane's own description explains why (CC1/CC2's rest " +
          "value is 0, so attenuating unconditionally would silence a clip until the " +
          "lane's first point). At 1, an untouched CC1/CC2 (or one driven fully open) " +
          "has no effect and a fully-closed one silences the voice. Set this above 0 " +
          "before a CC1/CC2 controller lane will audibly do anything on this track's " +
          "Sampler. Has no effect on `testTone`/`polySynth`."
      ),
    expressionFilterDepth: z
      .number()
      .min(0)
      .max(1)
      .optional()
      .describe(
        "How far the expression controller (CC 11 by default, or `expressionFilterCC`) " +
          "sweeps a per-voice low-pass filter, 0-1 — the BRIGHTNESS complement to CC " +
          "11's own LOUDNESS control, for making a held sax/string note read as a " +
          "player leaning into it rather than a flat sustain. NIL/0 MEANS THE FILTER " +
          "IS SKIPPED ENTIRELY, not run at unity/neutral — this is a real distinction: " +
          "a project that never sets this is byte-identical to the pre-existing " +
          "engine path, not merely 'filter wide open'. At depth 1 cutoff sweeps " +
          "logarithmically from a dark ~400 Hz at controller 0 up to ~20 kHz " +
          "(effectively unfiltered) at controller 127; intermediate depths compress " +
          "that sweep toward the open end. Has no effect on `testTone`/`polySynth`."
      ),
    expressionFilterCC: z
      .number()
      .int()
      .min(0)
      .max(127)
      .optional()
      .describe(
        "Which CC drives the `expressionFilterDepth` brightness sweep. Omitted = 11 " +
          "(expression) — the same controller that drives loudness, so a played " +
          "expression pedal/lane makes a note both louder AND brighter together. Set " +
          "to 1 or 2 to drive brightness from mod wheel/breath instead (that does NOT " +
          "require `expressionModDepth` to be set — the neutral-0 silencing hazard " +
          "that gates the loudness path does not apply here, because a filter sitting " +
          "at its low cutoff is dark, not silent). Only takes effect once " +
          "`expressionFilterDepth` is above 0."
      ),
    bendRangeSemitones: z
      .number()
      .min(0)
      .max(48)
      .optional()
      .describe(
        "How many semitones a FULL pitch-bend deflection (raw 0 or 16383 on a pitch-bend " +
          "controller lane; 8192 is centre) moves the note on the built-in Sampler. " +
          "OMITTED = 2, the General MIDI default — and it stays 2 on purpose: every bend " +
          "lane already written in every existing project was authored against ±2, so a " +
          "wider default would multiply all of them silently on load. Set it per " +
          "instrument instead. For a WIND library, measurement on 36 sax phrases (131 " +
          "note boundaries) says ±2 leaves 28 boundaries audibly rough, ±4 leaves 6, and " +
          "±6 leaves 0 — the curve SATURATES at 6, so 6 is the value to reach for; 12 " +
          "buys full-range portamento but no further smoothness. 0 makes bend inert. " +
          "⚠️ If you also generate vibrato with clip_apply_breath_contour or " +
          "clip_apply_effort_shape, pass the SAME figure to that tool's own " +
          "`bendRangeSemitones` — it converts cents to bend units and will scale every " +
          "vibrato by the ratio if the two disagree (you get a warning when they do)."
      ),
    voiceMode: z
      .enum(["poly", "mono"])
      .optional()
      .describe(
        "How many notes the Sampler lets sound at once. Omitted = `poly` (the existing " +
          "behaviour, 64 voices). `mono` is LAST-NOTE PRIORITY: a new note always takes " +
          "over from the one sounding, because a wind line is one airstream and the " +
          "newest note is the one being played. Use it for sax/flute/trumpet/solo-lead " +
          "parts. Under the slight note OVERLAPS that legato writing needs, mono " +
          "retriggers to the newest pitch — the overlap becomes the slur. A note-off for " +
          "a note that has already been superseded is discarded: releasing an older " +
          "still-held key does NOT fall back to it, because on a wind instrument that " +
          "note ended when the player moved."
      ),
  })
  // `.strict()` — DEFECT B (sax-team, 2026-08-20): `registerTool`'s wrapper
  // only applies `.strict()` at the TOP level of a tool's own inputSchema
  // (see that function's header comment), so a NESTED object like this one
  // fell back to zod's default "strip" parse mode. `track_set_instrument`
  // ({..., sampler: samplerSchema.optional()}) accepted `sampler.zonePatches`
  // — a real, working key one level down at the RAW control-protocol layer
  // (`Commands.swift`'s `parseSampler`) but NOT a key this schema ever
  // recognized — stripped it silently, and reported success having changed
  // nothing. `instrument_set_sampler_zones`'s own `zonePatches` path (via
  // `samplerZonePatchSchema`, already `.strict()`) was and remains the
  // supported MCP route to that merge; this schema deliberately does not
  // re-expose `zonePatches`, so it must now REJECT the key loudly instead of
  // eating it — additive-only in effect, since no caller had a WORKING call
  // that depended on this silent drop.
  .strict()
  .describe(
    "Sampler configuration, used only when `kind` is (or already is) `sampler`. Every field " +
      "here is independently a PARTIAL update — omit a field and it keeps its current value " +
      "— with ONE exception: a PRESENT `zones` array replaces the whole keyzone map at once " +
      "(see `zones`'s own description for what 'replaces' means for zone ids). Omit " +
      "`sampler` entirely to leave the track's current sampler configuration untouched (e.g. " +
      "when this call only changes `kind` or is switching a different track's instrument). " +
      "Has no effect on `testTone`/`polySynth`. For narrower, harder-to-misuse edits, prefer " +
      "instrument_set_sampler_param (one global) or instrument_set_sampler_zones (merge " +
      "zones by id) over building this object by hand."
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
  // `.strict()` (m30-c): closes the same nested-object hole for
  // track_set_instrument's `audioUnit` param — a typo'd field (e.g.
  // "subTyp") would otherwise be silently stripped instead of rejected.
  // Safe: this schema is a fixed component-triple IDENTITY, not a
  // parameter dictionary — the AU's own parameter surface is addressed
  // elsewhere (and is explicitly EMPTY for automation_add_lane's
  // `effectParam`, per this schema's own description below), so there is
  // no legitimate reason for an extra key here.
  .strict()
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

const soundBankSchema = z
  .object({
    source: z
      .string()
      .min(1)
      .describe(
        "Which sound bank to address: the string \"gm\" for the built-in General MIDI bank " +
          "(ships with every Mac — zero downloads, zero setup, the go-to default), or the " +
          "ABSOLUTE path to a .sf2/.dls file exactly as returned by instrument_list_sound_banks " +
          "(already-discovered) or instrument_import_sound_bank (freshly imported). An unknown " +
          "source, missing file, or wrong extension is rejected with a readable error pointing " +
          "you back to instrument_list_sound_banks."
      ),
    program: z
      .number()
      .int()
      .min(0)
      .max(127)
      .optional()
      .describe(
        "MIDI program number, 0-BASED 0-127 (e.g. on General MIDI, 0 = \"Acoustic Grand " +
          "Piano\", 56 = \"Trumpet\" — human GM charts are 1-based, this is the raw MIDI byte). " +
          "Call instrument_list_sound_bank_programs with this `source` first to see the exact " +
          "program numbers and names available. Defaults to 0."
      ),
    bankMSB: z
      .number()
      .int()
      .min(0)
      .max(127)
      .optional()
      .describe(
        "Bank select MSB, 0-127. Defaults to 121 (0x79), the General MIDI MELODIC convention " +
          "— 120 (0x78) addresses a percussion/drum kit program instead. " +
          "instrument_list_sound_bank_programs reports the exact bankMSB each program actually " +
          "needs; copy it from there rather than guessing."
      ),
    bankLSB: z
      .number()
      .int()
      .min(0)
      .max(127)
      .optional()
      .describe(
        "Bank select LSB, 0-127. Defaults to 0. Most banks (General MIDI included) never use " +
          "a nonzero LSB; instrument_list_sound_bank_programs reports it when a bank does."
      ),
  })
  // `.strict()` (m30-c): closes the same nested-object hole for
  // track_set_instrument's `soundBank` param — a typo'd field (e.g.
  // "progam") would otherwise be silently stripped instead of rejected.
  // Safe: this is a fixed source/program/bankMSB/bankLSB address, not an
  // arbitrary parameter dictionary — there is no legitimate reason for an
  // extra key here.
  .strict()
  .describe(
    "Addresses a SoundFont2 (.sf2) or DLS (.dls) bank program — General MIDI or any other " +
      "discovered/imported bank — used only when `kind` is (or is being set to) `soundBank`. " +
      "ZERO-SETUP flow: call instrument_list_sound_banks (General MIDI is always listed " +
      "first, no downloads required) to see available banks, instrument_list_sound_bank_programs " +
      "to see that bank's exact program numbers/names, then pass the chosen `source`/`program`/" +
      "`bankMSB`/`bankLSB` here — e.g. `{source: \"gm\", program: 56}` selects General MIDI's " +
      "Trumpet. Providing `soundBank` implies `kind` `soundBank` even if `kind` is omitted, and " +
      "is MUTUALLY EXCLUSIVE with `audioUnit` in the same call — providing both is rejected " +
      "with \"provide either audioUnit or soundBank, not both\" and nothing lands. The resolved " +
      "selection echoes back (and rides project_snapshot) as `soundBank: {source, path, " +
      "program, bankMSB, bankLSB, name, status}`: `name` is a server-derived display name " +
      "(e.g. \"Trumpet — General MIDI\"); `status` starts \"pending\" and becomes \"ready\" " +
      "once the bank finishes loading into the sampler, \"missing\" if the bank file can't be " +
      "found on this machine, or `failed: <reason>` (may include a low-level OSStatus code) if " +
      "loading it otherwise fails. Omit `soundBank` to leave the track's current instrument " +
      "untouched."
  );

registerTool(
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
      "and one-shots), `soundBank` (plays SoundFont2/DLS bank programs — " +
      "General MIDI ships with macOS with zero setup, or use an imported/" +
      "discovered .sf2/.dls library — selected via the `soundBank` param; " +
      "call instrument_list_sound_banks then instrument_list_sound_bank_programs " +
      "to pick one), or `audioUnit` (hosts an installed Audio Unit instrument " +
      "plugin — third-party or Apple synths/samplers registered with the " +
      "system — selected via the `audioUnit` param; call " +
      "instrument_list_audio_units first to discover what's installed). This " +
      "is a PARTIAL update: any field you omit keeps its current value, so you " +
      "can change just one knob (e.g. only `cutoffHz`) without resending the " +
      "rest. For a single sampler GLOBAL (oneShot/attack/release/gain), prefer " +
      "the narrower instrument_set_sampler_param — it wraps this same partial-" +
      "update contract so you don't have to know it's safe. `sampler` here is " +
      "partial too, at BOTH levels: omit `zones` and the track's existing " +
      "zones stand, so `{sampler: {release: 0.4}}` retunes a 309-zone imported " +
      "library without resending a single zone, and the globals you don't " +
      "mention keep their values rather than snapping back to defaults. The " +
      "one thing that is still wholesale is a PRESENT `zones` array — it " +
      "REPLACES the zone list entirely, and an explicit `zones: []` is " +
      "therefore how you deliberately clear a sampler. Zone ids ARE honoured " +
      "on this replace path (a zone whose `id` already names a zone on this " +
      "track keeps that identity; an id that doesn't is re-minted and the " +
      "substitution is reported in the response's `remintedZoneIDs` — this is " +
      "also how a zone map gets copied from one track onto another), but this " +
      "array can still only REPLACE, never MERGE — to edit a handful of zones " +
      "on a large library by id and leave the rest completely untouched, use " +
      "instrument_set_sampler_zones instead. The synth params only " +
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
      "implies that kind even if `kind` is omitted. `soundBank` (see its own " +
      "description) addresses a SoundFont2/DLS bank program by source/program/" +
      "bankMSB/bankLSB, is only meaningful for `kind` `soundBank`, implies " +
      "that kind even if `kind` is omitted, and is MUTUALLY EXCLUSIVE with " +
      "`audioUnit` in the same call (providing both errors, nothing lands). " +
      "Default instrument (a " +
      "fresh instrument track) is polySynth with a saw wave. Audio and bus " +
      "tracks reject this — use track_add or project_snapshot to find/create " +
      "an instrument track first. THE RESPONSE ANSWERS TWO THINGS ABOUT " +
      "PERFORMANCE CONTROLLER DATA. (1) `honoredControllers` — always " +
      "present — says which controllers THIS instrument actually acts on: " +
      "`{all, cc, pitchBend, channelPressure}`, where `all: true` (the " +
      "soundBank / audioUnit kinds) means every CC is forwarded to the plug-in " +
      "and `cc` is empty because there is nothing to enumerate, while for the " +
      "built-ins `cc` lists the exact CC numbers that will sound. Read it " +
      "BEFORE writing lanes with clip_set_controller_lane, and note it depends " +
      "on the SETTINGS too, not just the kind — a sampler honors CC 1 and CC 2 " +
      "only once `sampler.expressionModDepth` is above 0. Its " +
      "`neutralDefaults` map gives each controller its REST value, which is " +
      "127 for CC 11, 100 for CC 7 and 64 for CC 10 rather than 0. (2) " +
      "`warnings` — present ONLY when it matters — fires when this very call " +
      "CHANGED the meaning of controller lanes the track already carries: " +
      "lanes that were inert under the old instrument and now sound, or that " +
      "sounded and now do not. That is a real regression source: CC 11 lanes " +
      "authored against polySynth (which ignores them) became a broad " +
      "attenuation the moment a soundBank was assigned, and cost a finished " +
      "mix 1.25 LU. Your lanes are never rewritten or muted — the warning " +
      "just tells you the meaning moved, and names the controller.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the instrument track, from project_snapshot."),
      kind: z
        .enum(["testTone", "polySynth", "sampler", "audioUnit", "soundBank"])
        .optional()
        .describe(
          "Which instrument to use: `testTone` (simple fixed test tone), `polySynth` " +
            "(polyphonic subtractive synth), `sampler` (plays back your own audio files, " +
            "configured via `sampler`), `soundBank` (plays a SoundFont2/DLS bank program, " +
            "selected via `soundBank`; see instrument_list_sound_banks to discover banks — " +
            "General MIDI needs no setup), or `audioUnit` (hosts an installed Audio Unit " +
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
      soundBank: soundBankSchema.optional(),
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
    soundBank,
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
        soundBank,
      })
    )
);

// ---------------------------------------------------------------------------
// Bus routing & sends
// ---------------------------------------------------------------------------

registerTool(
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
      "sub-bus chains) and reject being given an outputBusId. Refused while a " +
      "recording is in progress (re-routing rebuilds the audio graph, which " +
      "would truncate the take) — stop recording first. Returns the " +
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

registerTool(
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
      "must refer to a track with kind `bus`. Refused while a recording is in " +
      "progress (adding a send rebuilds the audio graph, which would truncate " +
      "the take) — stop recording first; use track_set_send to ride an " +
      "EXISTING send's level mid-take instead. Returns the track's full " +
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

registerTool(
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

registerTool(
  "track_remove_send",
  {
    title: "Remove a send",
    description:
      "Permanently remove an existing send from a track, by id — stops that " +
      "parallel feed into the destination bus entirely (the track's main " +
      "output, set via track_set_output, is unaffected). Refused while a " +
      "recording is in progress (it rebuilds the audio graph, which would " +
      "truncate the take) — stop recording first. Returns the track's " +
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

// --- MIDI learn: map a hardware knob to something (m28-knob) ----------------
//
// Registered next to midi_list_inputs — its only sibling on this surface.
// midi_get_control_map is READ-ONLY (server.registerTool, no before-capture);
// the other two mutate.

server.registerTool(
  "midi_get_control_map",
  {
    title: "Read the hardware-knob mapping table",
    description:
      "Read which hardware MIDI controls (knobs, faders) are mapped to which " +
      "DAW parameters, and what CAN be mapped. No params. Returns `bindings` " +
      "(the mappings that exist), `targets` (the CATALOGUE — every parameter a " +
      "control may be bound to, each with a plain-English `summary`, plus the " +
      "`controller` number currently driving it if any), `learningTarget` " +
      "(present only while midi_learn_control is armed), `lastControlChange` " +
      "(the last controller message seen from ANY device, mapped or not) and " +
      "`subscribed` (whether the DAW is currently listening to the controller " +
      "feed). \n\n" +
      "USE `lastControlChange` TO DIAGNOSE A DEAD KNOB: it separates \"your " +
      "knob is not mapped\" from \"your knob is not sending anything\", which " +
      "look identical from the outside. \n\n" +
      "This call is PASSIVE — unlike midi_list_inputs it does not open the " +
      "user's MIDI devices. \n\n" +
      "⚠️ The mapping table is MACHINE SETUP, not part of the song: it is not " +
      "saved into the project and does not survive an app relaunch yet.",
  },
  async () => toToolResult(() => bridge.send("midi.getControlMap"))
);

registerTool(
  "midi_set_control_map",
  {
    title: "Map hardware knobs to parameters (whole table)",
    description:
      "Set the WHOLE hardware-control mapping table at once. `bindings` " +
      "replaces everything that was there, and `bindings: []` clears the map. " +
      "Read the current table with midi_get_control_map first, then write it " +
      "back with your change — this call is idempotent. \n\n" +
      "Each binding is {target, controller, channel?, sourceId?, inverted?}: " +
      "`target` is one of the ids from midi_get_control_map's `targets` " +
      "(currently `breathPadAngle` and `breathPadRadius`); `controller` is the " +
      "MIDI CC number 0-127 that the knob sends; `channel` 0-15 is optional " +
      "and OMITTING IT IS USUALLY RIGHT (omni — a controller's global channel " +
      "can change and a channel-pinned mapping then dies silently); " +
      "`sourceId` is a device's `uniqueID` from midi_list_inputs, and omitting " +
      "it accepts any device; `inverted` flips a knob that runs backwards. \n\n" +
      "ONE KNOB IS ENOUGH: bind a single knob to `breathPadAngle` and it walks " +
      "the breath pad's dot all the way around the ring of playing styles at " +
      "whatever depth it already has — that is the whole gesture. Add a second " +
      "on `breathPadRadius` for depth. \n\n" +
      "PREFER midi_learn_control when a human is present: turning the knob is " +
      "faster and more reliable than looking its CC number up. \n\n" +
      "⚠️ ABSOLUTE controls only (knobs and faders that send a POSITION). An " +
      "endless/relative encoder sends deltas and will read as a jump to one " +
      "end. \n\n" +
      "⚠️ A mapped CC is NOT swallowed: it still reaches armed instrument " +
      "tracks and is still recorded into a take. On a track hosting an Audio " +
      "Unit it may also move a plugin parameter — pick a CC the plugin does " +
      "not use.",
    inputSchema: {
      bindings: z
        .array(
          z.object({
            target: z
              .string()
              .describe("a target id from midi_get_control_map's `targets`"),
            controller: z
              .number()
              .int()
              .min(0)
              .max(127)
              .describe("the MIDI CC number the knob sends"),
            channel: z
              .number()
              .int()
              .min(0)
              .max(15)
              .optional()
              .describe("MIDI channel filter; omit for omni (usually right)"),
            sourceId: z
              .number()
              .int()
              .optional()
              .describe("a device `uniqueID` from midi_list_inputs; omit for any device"),
            inverted: z
              .boolean()
              .optional()
              .describe("flip the sweep for a knob wired backwards"),
          })
            // `.strict()` (m30-c): a typo'd field (e.g. "contoller") inside
            // one `bindings` element would otherwise be silently stripped
            // instead of rejected.
            .strict()
        )
        .describe("the WHOLE table — [] clears every mapping"),
    },
  },
  async ({ bindings }: { bindings: unknown[] }) =>
    toToolResult(() => bridge.send("midi.setControlMap", { bindings }))
);

registerTool(
  "midi_learn_control",
  {
    title: "MIDI learn — turn a knob to map it",
    description:
      "Arm MIDI learn for `target`, then ask the user to TURN THE KNOB they " +
      "want: the first controller message that arrives binds to that target " +
      "and moves it immediately, so the user sees it work at once. Pass " +
      "`cancel: true` instead to disarm without changing any mapping. \n\n" +
      "This is the verb that WAKES THE MIDI SYSTEM UP. The DAW connects to " +
      "MIDI inputs lazily, so a learn armed any other way can sit listening to " +
      "a system that was never started. The response carries `inputs` (what " +
      "the DAW can see right now) and a `hint` sentence — if the hint says no " +
      "online input is connected, tell the user that rather than waiting. \n\n" +
      "`target` is an id from midi_get_control_map's `targets` (currently " +
      "`breathPadAngle`, which walks the breath pad's dot around its ring of " +
      "playing styles, and `breathPadRadius`, which is depth). \n\n" +
      "The learned binding pins the DEVICE but leaves the MIDI CHANNEL open on " +
      "purpose, so changing the controller's global channel later does not " +
      "silently break the mapping. \n\n" +
      "⚠️ The FIRST controller message wins, whatever it is — a fader the user " +
      "brushes will take the binding. Re-arm and try again; " +
      "midi_get_control_map's `lastControlChange` shows what was heard.",
    inputSchema: {
      target: z
        .string()
        .optional()
        .describe("the target id to arm; omit only when passing cancel"),
      cancel: z.boolean().optional().describe("true to disarm, changing no mappings"),
    },
  },
  async ({ target, cancel }: { target?: string; cancel?: boolean }) =>
    toToolResult(() => {
      const params: Record<string, unknown> = {};
      if (target !== undefined) params.target = target;
      if (cancel !== undefined) params.cancel = cancel;
      return bridge.send("midi.learnControl", params);
    })
);

registerTool(
  "note_audition",
  {
    title: "Sound notes now (preview, not an edit)",
    description:
      "Sound notes RIGHT NOW on an instrument track so the user can hear a " +
      "pitch, a chord voicing, or how a patch responds. This is a PREVIEW, " +
      "not an edit: nothing is written to any clip, nothing is recorded, and " +
      "the notes release themselves after `durationMs` (default 500). It " +
      "returns immediately — it never blocks for the duration. Works with " +
      "the transport STOPPED and also WHILE PLAYING, and it never disturbs " +
      "notes already playing back (audition rides its own path into the " +
      "instrument, separate from the sequencer). Use it to answer 'what does " +
      "this voicing sound like' before writing it with clip_add_midi, or to " +
      "confirm an instrument actually makes sound. `audible:false` in the " +
      "reply is a REAL ANSWER, not an error: `reason` names why nothing will " +
      "be heard — `trackMuted` (unmute it, or it is excluded by another " +
      "track's solo), `instrumentNotReady` (a plugin is still loading — try " +
      "again in a moment), `engineStopped`, `engineRebuilding`. It " +
      "deliberately IGNORES the user's in-app 'audition while editing' " +
      "preference, because that preference means 'do not sound notes while I " +
      "drag', not 'never make sound'. Refused while a take is recording. " +
      "WHAT `audible:true` DOES AND DOES NOT MEAN: it is a signal-PATH check, " +
      "not a measurement. It says the strip isn't muted or solo-excluded, the " +
      "engine is running, and — for `soundBank`/`audioUnit` instruments — a " +
      "prepared instrument existed at that instant. It measures no level and no " +
      "spectrum: NOTHING here confirms a sound was actually produced, and " +
      "nothing describes its TIMBRE. Do not A/B two candidate patches with this " +
      "tool and report which sounded better — you would be inventing the " +
      "difference. The reply also carries `instrumentStatus` for `soundBank`/ " +
      "`audioUnit` tracks (\"pending\"/\"ready\"/\"missing\"/\"failed: …\", the " +
      "same string project_snapshot's instrument object reports): a patch you " +
      "set moments ago may still be loading, so a `pending` status means retry " +
      "before you trust what you heard — `audible:true` alongside `pending` " +
      "means the path is clear but THIS patch may not have been the thing that " +
      "sounded.",
    inputSchema: {
      trackId: z
        .string()
        .describe(
          "Id of the INSTRUMENT track to sound the notes on (from project_snapshot). " +
            "Audio and bus tracks carry no instrument and are refused."
        ),
      pitches: z
        .array(z.number().int().min(0).max(127))
        .min(1)
        .max(8)
        .describe(
          "MIDI note numbers to sound together, 1-8 of them (60 = middle C). " +
            "One entry is a single note; several make a chord."
        ),
      velocity: z
        .number()
        .int()
        .min(1)
        .max(127)
        .optional()
        .describe("How hard the notes are struck, 1-127. Defaults to 100."),
      durationMs: z
        .number()
        .int()
        .min(10)
        .max(5000)
        .optional()
        .describe(
          "How long to hold the notes, 10-5000 ms. Defaults to 500. The release is automatic."
        ),
    },
  },
  async ({
    trackId,
    pitches,
    velocity,
    durationMs,
  }: {
    trackId: string;
    pitches: number[];
    velocity?: number;
    durationMs?: number;
  }) =>
    toToolResult(() =>
      bridge.send("note.audition", { trackId, pitches, velocity, durationMs })
    )
);

registerTool(
  "note_play",
  {
    title: "Play notes live and HOLD them (recordable into a take)",
    description:
      "Play notes live on an instrument track and HOLD them until you say " +
      "otherwise. This is the musical-typing / on-screen-keyboard path, and " +
      "it is the ONE note tool whose sound can be RECORDED: unlike " +
      "note_audition, it is NOT refused while a take is rolling, because what " +
      "you play here goes into the take. " +
      "SET SEMANTICS, and this is the part to get right: each call says " +
      "'exactly these notes should be sounding NOW'. Send `pitches:[60]` to " +
      "press middle C, `pitches:[60,64,67]` to add two more fingers without " +
      "re-striking the first, and `pitches:[]` to LIFT EVERYTHING. Repeating " +
      "the same set is a no-op that keeps the notes alive — it never " +
      "re-triggers them and never adds anything to the take. " +
      "ALWAYS SEND `pitches:[]` WHEN YOU ARE DONE. Nothing releases the notes " +
      "for you (there is no durationMs here — that is what note_audition is " +
      "for). Three backstops exist so a forgotten release cannot wedge the " +
      "app — a 30-second hold ceiling, a 3-second liveness watchdog in the " +
      "audio engine, and transport_panic — but relying on them means the " +
      "notes land in the take with the wrong length. " +
      "TO RECORD A PERFORMANCE: track_set_arm the instrument track, " +
      "transport_record, then note_play the notes with real waits between " +
      "them, then note_play with `pitches:[]`, then transport_stop. The take " +
      "lands as a MIDI clip you can read back with clip_get_notes. " +
      "⚠️ WAIT ~300 ms AFTER transport_record BEFORE THE FIRST NOTE. A take's " +
      "anchor is scheduled slightly ahead of the record call and every note " +
      "struck before it is DROPPED (the same rule that makes count-in work) — " +
      "so a note played instantly after transport_record can be heard and " +
      "still be missing from the clip. " +
      "READ `recording` IN THE REPLY — IT IS THE HONESTY LIGHT. `true` means " +
      "these notes are going into the rolling take. `false` means they " +
      "SOUNDED AND WENT INTO NO TAKE: the transport is not recording, the " +
      "track is not armed, or MIDI capture is unavailable. Never tell the " +
      "user you recorded something when `recording` was false. " +
      "`capturedEdges` is how many note-ons/offs THIS call put into the take " +
      "(0 on a repeat, by design). `audible:false` with a `reason` " +
      "(`trackMuted`, `instrumentNotReady`, `engineStopped`, " +
      "`engineRebuilding`) is a REAL ANSWER, not an error, exactly as " +
      "note_audition reports it — and note that `audible` is a signal-PATH " +
      "check, not a measurement: it confirms no measured level and no timbre.",
    inputSchema: {
      trackId: z
        .string()
        .describe(
          "Id of the INSTRUMENT track to play on (from project_snapshot). " +
            "Audio and bus tracks carry no instrument and are refused."
        ),
      pitches: z
        .array(z.number().int().min(0).max(127))
        .max(8)
        .describe(
          "MIDI note numbers that should be sounding RIGHT NOW, 0-8 of them " +
            "(60 = middle C). This is the whole held set, not a delta. An EMPTY " +
            "array releases everything — always allowed, never refused. Above " +
            "8, the most recently pressed 8 win."
        ),
      velocity: z
        .number()
        .int()
        .min(1)
        .max(127)
        .optional()
        .describe("How hard the notes are struck, 1-127. Defaults to 100."),
    },
  },
  async ({
    trackId,
    pitches,
    velocity,
  }: {
    trackId: string;
    pitches: number[];
    velocity?: number;
  }) => toToolResult(() => bridge.send("note.play", { trackId, pitches, velocity }))
);

registerTool(
  "chord_voice",
  {
    title: "Work out well-voiced chord notes (read-only, sounds nothing)",
    description:
      "You do not have to do the music theory. Give a key and Roman-numeral " +
      "scale degrees and get back real, well-spaced MIDI pitch arrays you can " +
      "hand straight to clip_set_notes, clip_add_midi or note_play. " +
      "READ-ONLY AND SILENT: this computes and returns pitches. It plays " +
      "nothing, records nothing, edits no clip, and needs no track — it is " +
      "pure arithmetic over the arguments. " +
      "WHY USE IT INSTEAD OF STACKING THIRDS YOURSELF: it does the two things " +
      "that decide whether a chord part sounds like music or like a beginner. " +
      "(1) NEAREST-TONE VOICE LEADING — each chord is voiced to move the " +
      "smallest possible distance from the one before it, so a progression " +
      "holds its common tones instead of jumping around the keyboard. Pass " +
      "the whole progression in ONE call and this is done for you; that is " +
      "the main reason `degrees` is an array. (2) LOW-INTERVAL LIMITS — close " +
      "intervals are kept out of the bass register where they turn to mud. " +
      "`degrees` are 1-7 scale degrees: 1 is the key's own chord, 4 and 5 are " +
      "the two that surround it, 6 is its relative minor. [1,5,6,4] is the " +
      "four chords of pop; [1,6,4,5] is the '50s doo-wop turnaround; [2,5,1] " +
      "is the jazz cadence. Or pass `chords` with explicit symbols instead " +
      "(C, Am, F#m7, G7, Bdim, Csus4) when you already know what you want. " +
      "Give exactly one of the two. " +
      "PICK THE PRESET TO MATCH THE INSTRUMENT — it changes register, note " +
      "count and spacing, and it matters more than it sounds like it does. " +
      "`piano` puts a bass note low and a close triad in the middle. `pad` " +
      "and `strings` spread wide with 7ths. `guitar` stays in root position " +
      "in a guitar's range. `bass` RETURNS A SINGLE ROOT NOTE PER CHORD, and " +
      "that is deliberate, not a limitation: handing a bass part a full " +
      "stacked chord is the most common way an auto-harmonised arrangement " +
      "sounds wrong. " +
      "TO CONTINUE A PHRASE ACROSS CALLS, pass the previous call's last " +
      "`pitches` array as `previousVoicing`, or the voice leading restarts " +
      "from a home position and you get an audible jump. " +
      "This is the same engine behind the app's one-key chord mode, so what " +
      "you author here matches what the user plays by hand.",
    inputSchema: {
      key: z
        .union([z.string(), z.number().int().min(0).max(11)])
        .optional()
        .describe(
          "The key's tonic: a note name (C, F#, Bb) or a pitch class 0-11 " +
            "where 0 is C. Defaults to C."
        ),
      mode: z
        .enum(["major", "minor"])
        .optional()
        .describe(
          "major or natural minor. Defaults to major. In minor, degree 1 is " +
            "the minor tonic and [1,6,3,7] is the minor-key four-chord loop."
        ),
      degrees: z
        .array(z.number().int().min(1).max(7))
        .optional()
        .describe(
          "Scale degrees to voice, in playing order, e.g. [1,5,6,4]. Each " +
            "chord is voice-led from the one before it. Give this OR `chords`."
        ),
      chords: z
        .array(z.string())
        .optional()
        .describe(
          'Explicit chord symbols in playing order, e.g. ["C","Am","F","G7"]. ' +
            "Root then quality, one of: (nothing) m dim aug maj7 m7 7 m7b5 " +
            "sus4. Flats are accepted; replies always spell with sharps. " +
            "Give this OR `degrees`."
        ),
      preset: z
        .enum(["piano", "pad", "guitar", "bass", "strings"])
        .optional()
        .describe(
          "Which instrument the voicing is for. Defaults to piano. `bass` " +
            "returns ONE note per chord — the root."
        ),
      density: z
        .enum(["triad", "seventh"])
        .optional()
        .describe(
          "Override the preset's chord size. `seventh` is the lo-fi / " +
            "neo-soul / deep-house move: the same progression, richer chords."
        ),
      previousVoicing: z
        .array(z.number().int().min(0).max(127))
        .optional()
        .describe(
          "The pitches that were sounding just before the first chord here, " +
            "so voice leading continues smoothly across calls. Usually the " +
            "`pitches` of the last chord your previous call returned."
        ),
      octaveShift: z
        .number()
        .int()
        .min(-4)
        .max(4)
        .optional()
        .describe("Move the whole result by whole octaves. Defaults to 0."),
    },
  },
  async ({
    key,
    mode,
    degrees,
    chords,
    preset,
    density,
    previousVoicing,
    octaveShift,
  }: {
    key?: string | number;
    mode?: "major" | "minor";
    degrees?: number[];
    chords?: string[];
    preset?: "piano" | "pad" | "guitar" | "bass" | "strings";
    density?: "triad" | "seventh";
    previousVoicing?: number[];
    octaveShift?: number;
  }) =>
    toToolResult(() =>
      bridge.send("chord.voice", {
        key,
        mode,
        degrees,
        chords,
        preset,
        density,
        previousVoicing,
        octaveShift,
      })
    )
);

registerTool(
  "pad_preview_effort",
  {
    title: "Breath pad: stream an effort value live (preview, not an edit)",
    description:
      "Stream ONE breath-pad effort value (0-1, 'how hard is the player " +
      "blowing right now') to an instrument track as a live MIDI controller, " +
      "so it can be HEARD while a pad gesture is in progress. This is a " +
      "PREVIEW, not an edit: nothing is written to any clip, nothing is " +
      "recorded, there is no undo entry, and a bounce will not contain it. " +
      "The RECORD is the controller lane clip_apply_effort_shape writes — use " +
      "that to commit a shape. " +
      "GESTURE-SCOPED, AND THE SCOPING IS THE POINT: send `gesture:\"begin\"` " +
      "once, then `gesture:\"move\"` as the value changes, then " +
      "`gesture:\"end\"` exactly once, naming THE SAME trackId. A `move` or " +
      "`end` with no `begin` open — or naming a different track than the open " +
      "gesture — is REFUSED. The pad NEVER streams while the transport is " +
      "merely rolling — only while a gesture is open — which is what keeps " +
      "live playback, replay and an offline bounce agreeing sample-for-sample. " +
      "`end` DOES NOT LEAVE YOUR LAST VALUE ON THE STRIP: it restores the " +
      "controller to its neutral default (127 for CC 11, expression), because " +
      "a MIDI controller is sticky and nothing else would take it back — a " +
      "parked low value would quietly attenuate every later playback. If you " +
      "start a gesture, ALWAYS end it. " +
      "CAVEAT, MEASURED, DO NOT OVERSTATE THIS TOOL: neutral is not the same " +
      "as the track's committed lane. If the track already HAS a CC 11 lane " +
      "and you preview mid-playback, ending parks 127 and the strip stays " +
      "there until that lane's next point — so playback is louder than a " +
      "bounce over that span. It self-heals at the next point and cannot " +
      "happen on a track with no lane yet. Prefer previewing with the " +
      "transport stopped, or on a track you have not committed a shape to. " +
      "The reply carries `controller` (which CC was moved), `controllerValue` " +
      "(the raw 0-127 that went out), `streaming` (is a gesture open after " +
      "this call), `delivered` (false when the 30 Hz rate cap or the " +
      "unchanged-value filter coalesced this call away — normal during a fast " +
      "drag, not an error — and also false, on any phase including `end`, " +
      "when the value reached no instrument at all), and `audible` with a " +
      "`reason` when " +
      "false (`trackMuted`, `instrumentNotReady`, `engineStopped`, " +
      "`engineRebuilding`) exactly as note_audition does. " +
      "WHAT THIS DOES AND DOES NOT MOVE: effort rides CC 11 (expression). On " +
      "the built-in sampler that moves loudness always, and brightness only " +
      "when the track's sampler `expressionFilterDepth` is above 0. On a " +
      "hosted Audio Unit or sound bank — where a GM sax lives — CC 11 was " +
      "MEASURED to be exactly a gain and NOT a filter, so do not promise a " +
      "timbre change there. Refused while a take is recording, and on audio " +
      "or bus tracks.",
    inputSchema: {
      trackId: z
        .string()
        .describe(
          "Id of the INSTRUMENT track to preview on (from project_snapshot). " +
            "Audio and bus tracks carry no instrument and are refused."
        ),
      gesture: z
        .enum(["begin", "move", "end"])
        .describe(
          "Where this call sits in the drag. 'begin' opens streaming, 'move' " +
            "updates the value, 'end' closes it and restores the controller to " +
            "neutral. A 'move' with no 'begin' open is refused."
        ),
      value: z
        .number()
        .min(0)
        .max(1)
        .optional()
        .describe(
          "Effort, 0-1: 0 is barely blowing, 1 is full pressure. Required for " +
            "'begin' and 'move'; ignored for 'end', which always restores neutral."
        ),
      expressionCC: z
        .number()
        .int()
        .min(0)
        .max(127)
        .optional()
        .describe(
          "Which CC carries the preview. Defaults to 11 (expression) — the " +
            "same default clip_apply_effort_shape writes, so the preview and " +
            "the commit land on one lane. Set it only if you will also pass " +
            "the matching expressionCC when you commit."
        ),
    },
  },
  async ({
    trackId,
    gesture,
    value,
    expressionCC,
  }: {
    trackId: string;
    gesture: "begin" | "move" | "end";
    value?: number;
    expressionCC?: number;
  }) =>
    toToolResult(() =>
      bridge.send("pad.previewEffort", { trackId, gesture, value, expressionCC })
    )
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

server.registerTool(
  "instrument_list_sound_banks",
  {
    title: "List available SoundFont2/DLS sound banks",
    description:
      "List every sound bank this Mac can use as a track_set_instrument `soundBank` source " +
      "— the built-in General MIDI bank is ALWAYS FIRST (`source: \"gm\"`; ships with every " +
      "Mac, zero downloads, zero setup — the go-to default for realistic instrument sounds " +
      "without hunting for sample libraries), followed by every .sf2/.dls file found in the " +
      "central imported-bank library and the two standard macOS bank folders (deduplicated, " +
      "alphabetized within each folder). No params, never errors (an unreadable folder is " +
      "skipped silently). Each entry has: `source` (pass this straight into " +
      "instrument_list_sound_bank_programs's `source` or track_set_instrument's " +
      "`soundBank.source` — \"gm\" for the built-in bank, or the bank's absolute file path); " +
      "`name` (display name — \"General MIDI\" for the built-in bank, else the filename " +
      "without its extension); `path` (the resolved absolute file path, for reference); " +
      "`format` (the file's real extension — \"dls\", \"sf2\", or \"sf3\"); `builtin` (true " +
      "only for the General MIDI entry); `sizeBytes` (file size in bytes — some SF2 " +
      "libraries run into the gigabytes); `supported` (false for a bank that was FOUND but " +
      "cannot be played AS IT SITS — today that means MuseScore's Vorbis-compressed .sf3); " +
      "and `unsupportedReason` (null when supported, else a sentence telling the user what " +
      "to do about it). An entry with `supported: false` is listed so you can SEE it exists " +
      "rather than wonder why your file vanished — its `source` will be REJECTED by " +
      "track_set_instrument, so never offer it as a playable choice. For a .sf3 the way " +
      "forward is instrument_import_sound_bank, which CONVERTS it to a real .sf2 and " +
      "returns that bank; select the converted bank's `source`, not the .sf3's. Don't " +
      "see a bank you expect? Import it first with instrument_import_sound_bank. Next step: " +
      "call instrument_list_sound_bank_programs with a bank's `source` to see its exact " +
      "playable programs before selecting one on track_set_instrument.",
  },
  async () => toToolResult(() => bridge.send("instrument.listSoundBanks"))
);

server.registerTool(
  "instrument_list_sound_bank_programs",
  {
    title: "List a sound bank's programs (instrument presets)",
    description:
      "List every program (instrument preset) available on one sound bank, so you can pick " +
      "an exact `program`/`bankMSB`/`bankLSB` for track_set_instrument's `soundBank` param " +
      "instead of guessing. `source` is required — \"gm\" for the built-in General MIDI " +
      "bank, or the absolute path of a bank exactly as returned by instrument_list_sound_banks " +
      "or instrument_import_sound_bank; an unknown source, missing file, or wrong extension " +
      "is rejected with a readable error pointing you back to instrument_list_sound_banks. " +
      "Returns `{source, namesParsed, programs}`: for \"gm\" this is the full General MIDI " +
      "table — 128 melodic instruments (program 0-127, 0-BASED — e.g. 0 = \"Acoustic Grand " +
      "Piano\", 56 = \"Trumpet\") each with a `category` (e.g. \"Piano\", \"Brass\"), plus " +
      "one \"Standard Drum Kit\" entry at bankMSB 120 — 129 entries total, `namesParsed: " +
      "true`. For a .sf2 file whose preset names parse successfully, `namesParsed` is also " +
      "true and `name`/`category` reflect that file's actual presets. For any other .dls " +
      "(or a .sf2 whose names can't be parsed), this returns a generic \"Program 0\" … " +
      "\"Program 127\" list with `namesParsed: false` — the bank likely still sounds fine, " +
      "you just won't get friendly names; try programs by ear via track_set_instrument. Each " +
      "entry's `program`/`bankMSB`/`bankLSB` is exactly what to pass into " +
      "track_set_instrument's `soundBank` object to select that sound.",
    inputSchema: {
      source: z
        .string()
        .min(1)
        .describe(
          "Which bank to list: \"gm\" for the built-in General MIDI bank, or the absolute " +
            "file path of a bank exactly as returned by instrument_list_sound_banks or " +
            "instrument_import_sound_bank."
        ),
    },
  },
  async ({ source }) => toToolResult(() => bridge.send("instrument.listSoundBankPrograms", { source }))
);

registerTool(
  "instrument_import_sound_bank",
  {
    title: "Import a SoundFont2/DLS file into the sound bank library",
    description:
      "Copy a .sf2 or .dls sound bank file into DAW Pro's central sound bank library " +
      "(`~/Library/Application Support/DAWPro/SoundBanks/`) so it shows up in " +
      "instrument_list_sound_banks and can be selected on track_set_instrument going " +
      "forward. `path` must be the ABSOLUTE path to an existing, readable .sf2, .dls or " +
      ".sf3 file on this Mac — a relative path, wrong extension, or missing file is " +
      "rejected with a readable error. A .sf3 (MuseScore's Vorbis-compressed SoundFont, " +
      "which is what MuseScore ships) is CONVERTED to a real .sf2 as it is imported, so " +
      "the bank you get back is a normal .sf2 with a .sf2 path; expect it to take a few " +
      "seconds and to be roughly ten times the size of the .sf3. If any part of a .sf3 " +
      "cannot be decoded the whole import FAILS with a readable error rather than landing " +
      "a bank with silent gaps in it. This is always a COPY: the source file at `path` is left in place, " +
      "never moved or deleted. A name collision in the library is uniquified automatically " +
      "(e.g. \"Vintage-2\") rather than overwriting an existing bank. Returns `{bank: " +
      "{source, name, path, format, builtin, sizeBytes}}` — the freshly imported bank's " +
      "info, in the exact shape instrument_list_sound_banks returns; use its `source` (the " +
      "new library path) as-is on instrument_list_sound_bank_programs or " +
      "track_set_instrument. Skip this entirely for General MIDI (`source: \"gm\"`) — it " +
      "ships with macOS and needs no import.",
    inputSchema: {
      path: z
        .string()
        .min(1)
        .describe(
          "Absolute path to the .sf2, .dls or .sf3 file to import on this Mac. Copied into " +
            "the central library (a .sf3 is converted to .sf2 on the way in); the original " +
            "file at this path is left untouched."
        ),
    },
  },
  async ({ path }) => toToolResult(() => bridge.send("instrument.importSoundBank", { path }))
);

registerTool(
  "instrument_import_sample_library",
  {
    title: "Import a sample library onto a track's Sampler",
    description:
      "Import a sample LIBRARY file (a multi-sample instrument definition — key/velocity " +
      "zones mapped to audio files, e.g. a sampled piano or drum kit) and load it onto the " +
      "given INSTRUMENT track's built-in Sampler. Imports .sfz (documented subset) and " +
      ".dspreset sample-library files (see docs/SFZ-SUPPORT.md for exactly what each format " +
      "keeps, reports, and skips); a `.dslibrary` path is rejected with a hint to unzip it " +
      "first and import the `.dspreset` inside (it's a zip archive, not a library file " +
      "itself). RECOMMENDED WORKFLOW: call this once with `dryRun: true` first to inspect " +
      "the report before touching the project — its `skippedRegions` (reason -> count, e.g. " +
      "regions triggered by a release or a CC that this build doesn't map), `ignoredOpcodes` " +
      "(opcode -> count) and `degradations` (plain-English sentences, e.g. keyswitch " +
      "reduction to a default articulation) tell you exactly what will and won't survive the " +
      "import; once the report looks right, call again with `dryRun` omitted/false to apply " +
      "it for real. Sustain loops play for real: SFZ loop_mode/loop_start/loop_end, " +
      ".dspreset loopEnabled/loopStart/loopEnd, and loops embedded in a WAV's smpl chunk " +
      "when the text authored none — the report's `loopedZones` counts them. Unlike " +
      "instrument_import_sound_bank (which only copies a file into a " +
      "shared library and never touches any project), this call IS a project mutation when " +
      "applied: it replaces the track's instrument in ONE journaled \"Change Instrument\" " +
      "edit, undoable with edit_undo like any other edit — a dry run makes no project change " +
      "and creates no undo entry. `force` (default false) overrides ONLY the 4 GB total-" +
      "sample-size refusal for unusually large libraries; a 500 MB warning is always reported " +
      "regardless of `force` (it never blocks the import, just flags it). Returns " +
      "`{report: <SampleLibraryImportReport>, applied}` where `applied` is true only when the " +
      "import actually landed on the track (i.e. `dryRun` was false); the report shape is " +
      "identical on both dry runs and real applies so you can compare before/after. Missing " +
      "file, wrong extension, a preprocessor error (missing/cyclic #include, an undefined " +
      "$VAR macro), malformed .dspreset XML, zero zones surviving mapping, or the size " +
      "refusal all surface as readable errors naming the problem.",
    inputSchema: {
      trackId: z
        .string()
        .min(1)
        .describe("Id (UUID) of the INSTRUMENT track to load the sample library onto, from project_snapshot."),
      path: z
        .string()
        .min(1)
        .describe(
          "Absolute (or ~-prefixed) path to the .sfz or .dspreset sample-library file on " +
            "this Mac to import. A relative path is rejected."
        ),
      dryRun: z
        .boolean()
        .optional()
        .describe(
          "true: parse and map the library and return the full report WITHOUT touching the " +
            "project (no instrument change, no undo entry) — use this first to inspect what " +
            "will and won't survive the import. Omit or false: apply it for real. Default false."
        ),
      force: z
        .boolean()
        .optional()
        .describe(
          "true: override the 4 GB total-sample-size refusal so an unusually large library can " +
            "still be imported. Has no effect on the 500 MB warning, which is always reported " +
            "regardless of this flag. Omit or false: the 4 GB refusal stands. Default false."
        ),
    },
  },
  async ({ trackId, path, dryRun, force }) =>
    toToolResult(() =>
      bridge.send("instrument.importSampleLibrary", {
        trackId,
        path,
        ...(dryRun !== undefined ? { dryRun } : {}),
        ...(force !== undefined ? { force } : {}),
      })
    )
);

registerTool(
  "instrument_describe_sampler",
  {
    title: "Read a track's Sampler configuration (read-only)",
    description:
      "Read the built-in Sampler's configuration on an instrument track — the ANSWER to " +
      "'which library is loaded and how is it mapped' without paying for project_snapshot's " +
      "whole-project cost (measured 296,809 bytes on a real song). Mirrors " +
      "au_describe_params: a cheap describe you call BEFORE editing, so instrument_set_" +
      "sampler_param/instrument_set_sampler_zones don't have to guess a track's current " +
      "state. Works even when the track's ACTIVE instrument is something else right now — " +
      "sampler configuration is carried across kind switches (like soundBank/audioUnit), so " +
      "you can inspect a previously-built sampler map before switching back to it; the " +
      "response's own `kind` field tells you whether `sampler` is actually the SOUNDING " +
      "instrument or just preserved state. Refuses readably for an audio/bus track (only " +
      "instrument tracks carry an instrument), an unknown trackId, or an instrument track " +
      "that has never had a sampler configured at all (use instrument_import_sample_library " +
      "or track_set_instrument {kind:\"sampler\", sampler:{zones:[...]}} first; with no " +
      "sample library of your own, mount the bundled one-shot — " +
      "{path: \"builtin:test-tone-a4\", rootPitch: 69} — and you have a sound) — but a " +
      "sampler that IS configured with zero zones (the deliberate `zones: []` clear) is a " +
      "legal answer, not a refusal: you get `zoneSummary.count: 0` back. Returns {trackId, " +
      "kind, oneShot, attack, release, gain, sourcePath?, displayName?, zoneSummary, " +
      "effectiveGlobals?, warnings?}. " +
      "⚠️ READ `effectiveGlobals` BEFORE TRUSTING top-level `release`/`attack`/`oneShot`. " +
      "Those three are the STORED globals, and a zone that sets its own value WINS over " +
      "them — so on an imported library they are routinely numbers the engine never reads. " +
      "ANY per-zone value can do this, whichever way the sampler was built: a hand-authored " +
      "zone over the wire, a `.dspreset` region (whose `attack`/`release` attributes carry " +
      "no special prefix), or an SFZ region/group/global (whose native opcode names are " +
      "`ampeg_attack`/`ampeg_release`) — SFZ is not the only way in. (Field report 2026-08-20: " +
      "this verb answered `release: 3.4465` for an instrument that audibly released in 0.5 s, " +
      "because the imported SFZ authored `ampeg_release` in its `<global>` block and every " +
      "region inherited it. The engine was right; the answer was not.) `effectiveGlobals` is " +
      "{release, attack, oneShot}, each " +
      "{global, zonesOverriding, zonesInheriting, globalIsInert, effectiveValues, " +
      "effectiveMin?, effectiveMax?, effectiveValuesTruncated?, note?}. " +
      "`globalIsInert: true` means NO zone inherits that global: writing it with " +
      "instrument_set_sampler_param will be accepted and change nothing you can hear — " +
      "change the per-zone values instead (instrument_set_sampler_zones, patching `release` " +
      "/ `attack` / `oneShot` per zone). `note` (present only when `globalIsInert`) says so in " +
      "prose and, for `release`/`attack`, names the SFZ opcode (`ampeg_release`/`ampeg_attack`) " +
      "ONLY when `sourcePath` actually ends in `.sfz` — never for a hand-built sampler or a " +
      "`.dspreset` import, which would make the opcode name meaningless. Top-level `warnings` " +
      "(a string array, present only when at least one global is inert) restates the same " +
      "fact with BOTH the stored and the actually-applied number inline, so it is impossible " +
      "to miss even for a caller that only reads the top level and never descends into " +
      "`effectiveGlobals` at all. `effectiveValues` is the list of values the engine " +
      "will actually apply across the zones, ascending, and is the number to quote to a " +
      "user; it is meaningful in the MIXED case too (some zones overriding, some still " +
      "tracking the global), which no single boolean can describe. It caps at 8 distinct " +
      "values with `effectiveValuesTruncated: true`, but `effectiveMin`/`effectiveMax` stay " +
      "exact. `oneShot` additionally reports `zonesWithLoopMode` when any zone loops: a " +
      "looping voice is never one-shot regardless of the flag, provided its loop bounds are " +
      "valid for the loaded sample (which only the engine can confirm, so it is reported " +
      "rather than folded into the counts). `effectiveGlobals` is omitted entirely for a " +
      "zero-zone sampler — there is no inheritance to describe, and such a sampler is " +
      "silent for an unrelated reason. " +
      "`sourcePath`/`displayName` (provenance from an import; `displayName` is a file STEM " +
      "and therefore NOT unique — two different folders can both hold a \"Bass.sfz\", so " +
      "`sourcePath` is what actually disambiguates them) appear only when set — a hand-built " +
      "sampler has neither. `zoneSummary` is {count, pitchCoverage?, velocityCoverage?, " +
      "groupCount, distinctSampleFiles}: `pitchCoverage`/`velocityCoverage` are each " +
      "{min, max, gaps?} — the UNION of every zone's range, not a naive min/max, so a keymap " +
      "with a hole in the middle is visible as a `gaps` entry INSIDE the envelope instead of " +
      "silently reading as full 0-127 coverage (this is exactly the bug class the field " +
      "report hit twice: a bass silent below MIDI 35, a library silent above 45). Both are " +
      "omitted entirely when the sampler has zero zones. `groupCount` counts distinct " +
      "layering groups (an unset zone group counts as group 0, the classic first-match " +
      "default) and `distinctSampleFiles` counts unique sample audio files across all zones. " +
      "The zone list itself is a SEPARATE, opt-in page: omit both `offset` and `limit` and " +
      "the response has no `zones` key at all (just the summary); pass either one and you " +
      "get a paged `zones` array (the exact shape track_set_instrument echoes back, ids " +
      "included) plus `offset`, `limit`, `returnedZones`, and `truncated` so you know " +
      "whether to page further.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the instrument track to describe, from project_snapshot."),
      offset: z
        .number()
        .int()
        .min(0)
        .optional()
        .describe(
          "Zero-based index into the sampler's zone list to start a page from. Providing " +
            "EITHER `offset` or `limit` turns on paging and puts a `zones` array in the " +
            "response; omitting both returns the summary only. Default 0 when `limit` is " +
            "given alone. An offset past the end of the zone list is not an error — it " +
            "returns an empty, untruncated page."
        ),
      limit: z
        .number()
        .int()
        .min(1)
        .max(5000)
        .optional()
        .describe(
          "Max zones to return in the page. Providing EITHER `offset` or `limit` turns on " +
            "paging (see `offset`). Default 500 when `offset` is given alone; out-of-range " +
            "values clamp silently into 1-5000 rather than erroring. Compare the response's " +
            "`returnedZones` against `zoneSummary.count` (or check `truncated`) to know " +
            "whether to page further."
        ),
    },
  },
  async ({ trackId, offset, limit }) =>
    toToolResult(() => bridge.send("instrument.describeSampler", { trackId, offset, limit }))
);

registerTool(
  "instrument_probe_liveness",
  {
    title: "Measure whether velocity changes an instrument's TONE, not just its volume",
    description:
      "Renders a VELOCITY LADDER on an instrument track — the same pitch played at several " +
      "ascending velocities, one note each — and measures how far the spectral CENTROID " +
      "(brightness) moved against how far the RMS (level) moved. On a real acoustic " +
      "instrument, playing harder changes the SPECTRUM as well as the level: a saxophone " +
      "leaned on throws far more upper-harmonic energy. A single-sample patch just gets " +
      "louder. Big level spread + flat centroid = velocity is a volume knob, and the patch " +
      "will read as a toy on any exposed melodic line. " +
      "CALL THIS BEFORE BUILDING AN ARRANGEMENT ON A LEAD SOUND — that is the whole point: " +
      "a user listened to a finished render and said the sax 'sounded awful, like a toy', " +
      "and no automated check in this project can hear. This one can, for this one specific " +
      "question. " +
      "⚠️ IT MEASURES LIVELINESS, NOT QUALITY. It says nothing about tuning, articulation, " +
      "or whether the sound is pleasant — those still need a human. Do not quote a LIVE " +
      "verdict as 'the instrument sounds good'. " +
      "NOT AN EDIT: the ladder is rendered from a throwaway copy of the track. Nothing is " +
      "inserted, no undo step is created, the project is untouched. The copy is rendered DRY " +
      "— track effects, sends, automation, mute/solo, fader, bus routing and the whole master " +
      "chain are all stripped — so the reading describes the PATCH, not the mix around it. " +
      "It runs an offline render, so expect it to take a few seconds. " +
      "Returns {trackId, instrumentKind, instrumentDetail?, pitch, noteSeconds, sampleRate, " +
      "selfCheck, ladder, rmsSpreadDb?, centroidSpreadPercent?, distinctTimbreCount, " +
      "verdict, summary, thresholds, caveats}. " +
      "`verdict` is one of: `static` (level moved, timbre did not — one sample with a volume " +
      "knob), `live` (velocity changes the tone), `inconclusive` (the ladder did not move " +
      "the LEVEL enough to test the question at all — a velocity-insensitive patch, or a " +
      "compressor/limiter flattening it), or `silent` (at least one rung produced no " +
      "measurable signal). " +
      "⚠️ `silent` IS NOT `static`. 'The probe could not measure this' and 'the probe " +
      "measured it and found it flat' are different answers and are deliberately reported " +
      "differently — a silent result usually means the instrument is not loaded, does not " +
      "cover that pitch, or is muted upstream. Do not report it as a dead instrument. " +
      "`ladder` is the EVIDENCE — one entry per velocity, {velocity, rmsDb, centroidHz?, " +
      "timbreGroup?} — and `distinctTimbreCount` is the single most informative number: how " +
      "many distinct timbres (velocity layers) the ladder actually found. 1 means one " +
      "sample. It is a LOWER BOUND: four velocities cannot see a fifth layer, and two layers " +
      "that happen to share a brightness read as one. Prefer it to " +
      "`centroidSpreadPercent`, which is a crude min-to-max summary — layered banks step " +
      "between PLATEAUS and need not be monotonic (a soft layer can legitimately be brighter " +
      "than the one above it; a real GM piano measured 1856 / 1063 / 3662 / 3662 Hz). Rungs " +
      "sharing a `timbreGroup` share a layer. " +
      "`thresholds` echoes the numbers the verdict was computed with AND carries " +
      "`calibrated: false`, because they are a HYPOTHESIS derived from one instrument " +
      "family, not a calibrated rule. READ `ladder` AND FORM YOUR OWN VIEW rather than " +
      "inheriting the verdict silently. " +
      "`selfCheck` is the meter's proof, on this very run, that it can discriminate at all: " +
      "it measures a synthesised 440 Hz and 1760 Hz tone through the SAME code path and " +
      "requires the high one to read more than twice the low one. ⭐ IF THAT CONTROL FAILS " +
      "THE TOOL ERRORS OUT AND RETURNS NO VERDICT — never a `static` one. A flat centroid is " +
      "exactly the shape a BROKEN measurement produces, so a reading from a meter that " +
      "cannot tell those two tones apart is not evidence of anything. " +
      "Refuses readably for an audio/bus track (only instrument tracks carry an instrument), " +
      "an unknown trackId, a fewer-than-two-rung ladder, or when no audio engine is " +
      "available.",
    inputSchema: {
      trackId: z
        .string()
        .min(1)
        .describe("Id of the instrument track to probe, from project_snapshot."),
      pitch: z
        .number()
        .int()
        .min(0)
        .max(127)
        .optional()
        .describe(
          "MIDI note number every rung plays. Default 57 (A3) — the pitch the shipped " +
            "calibration figures were measured at, and a comfortable mid-register note for " +
            "most instruments. Choose one your instrument actually covers: a pitch outside " +
            "the keymap comes back `silent`, not `static`."
        ),
      velocities: z
        .array(z.number().int().min(1).max(127))
        .min(2)
        .optional()
        .describe(
          "ASCENDING MIDI velocities, one note each. Default [25, 60, 95, 127] — pp to ff. " +
            "At least two are required (one rung cannot show whether the timbre moves). More " +
            "rungs find more velocity layers: `distinctTimbreCount` is only ever a lower " +
            "bound over the velocities you actually sampled."
        ),
      noteSeconds: z
        .number()
        .min(0.05)
        .optional()
        .describe(
          "Length of each note in seconds. Default 1.0. The analysis window sits 0.30 s in " +
            "and runs 0.60 s — past the attack transient, inside the sustain — so shortening " +
            "this below ~1 s risks measuring the release instead of the tone."
        ),
    },
  },
  async ({ trackId, pitch, velocities, noteSeconds }) =>
    toToolResult(() =>
      bridge.send("instrument.probeLiveness", {
        trackId,
        ...(pitch !== undefined ? { pitch } : {}),
        ...(velocities !== undefined ? { velocities } : {}),
        ...(noteSeconds !== undefined ? { noteSeconds } : {}),
      })
    )
);

const samplerGlobalParamSchema = z
  .enum([
    "oneShot",
    "attack",
    "release",
    "gain",
    "expressionModDepth",
    "expressionFilterDepth",
    "expressionFilterCC",
    "bendRangeSemitones",
    "voiceMode",
  ])
  .describe(
    "Which Sampler GLOBAL to set — exactly one per call, matching one of the nine fields " +
      "track_set_instrument's own `sampler` object carries at this level (everything else " +
      "there, i.e. `zones`, is per-zone and out of reach of this narrower tool). `oneShot` " +
      "(boolean): true = every triggered sample always plays to completion regardless of " +
      "note-off (drum hits and other percussive one-shots); false = the sample follows " +
      "note-off, fading out over `release` seconds, like a sustained instrument. `attack` " +
      "(seconds, number, clamps 0-1): how long a triggered note takes to reach full volume. " +
      "`release` (seconds, number, clamps 0.001-8): how long the sample fades to silence " +
      "after note-off — ignored while `oneShot` is true. `gain` (0-1, number): the " +
      "sampler's overall output level, separate from each zone's own `gain` and from the " +
      "track fader (track_set_volume). `expressionModDepth` (0-1, number): how far CC 1 " +
      "(mod wheel) / CC 2 (breath) attenuate loudness — NIL/0 IS OFF (the attenuator is " +
      "skipped, not run at neutral), so a CC1/CC2 controller lane does nothing audible on " +
      "this track's Sampler until this is set above 0. `expressionFilterDepth` (0-1, " +
      "number): how far the expression controller sweeps a per-voice brightness (low-pass) " +
      "filter — NIL/0 IS OFF, the filter branch is skipped entirely, not run at unity. " +
      "`expressionFilterCC` (integer 0-127): which CC drives that filter sweep; omitted/nil " +
      "= 11 (expression, the same controller that already drives loudness) — set it to 1 " +
      "or 2 to drive brightness from mod wheel/breath instead. `bendRangeSemitones` " +
      "(number 0-48): how many semitones a full pitch-bend deflection moves the note; " +
      "omitted/nil = 2 (the General MIDI default, and what every already-authored bend " +
      "lane assumes) — 6 is the measured saturation point for expressive wind writing. " +
      "`voiceMode` (STRING, \"poly\" or \"mono\" — the one param here that takes a string): " +
      "`mono` is last-note priority, for sax/flute/solo-lead lines. See " +
      "track_set_instrument's `sampler` object for the full field-by-field description of " +
      "each."
  );

registerTool(
  "instrument_set_sampler_param",
  {
    title: "Set one Sampler global (oneShot/attack/release/gain/expression*/bend range/voice mode)",
    description:
      "Set exactly ONE global knob on a track's built-in Sampler — `oneShot`, `attack`, " +
      "`release`, `gain`, `expressionModDepth`, `expressionFilterDepth`, " +
      "`expressionFilterCC`, `bendRangeSemitones` or `voiceMode` — without touching " +
      "anything else on the sampler. This is a " +
      "thin, narrower wrapper around track_set_instrument {sampler: {<param>: value}}: the " +
      "whole reason it exists is so you don't have to know that a partial sampler update is " +
      "safe (added m26-g/h) — this call is GUARANTEED to leave the track's zones, " +
      "`sourcePath`, and `displayName` exactly as they were, no matter which global you set " +
      "or what an imported library's zone count is (tuning `release` on a 309-zone library " +
      "through this tool can never touch a single zone). Has no audible effect unless the " +
      "track's active instrument kind is `sampler` (see instrument_describe_sampler's " +
      "`kind` field), though the value is still stored and takes effect the next time it is. " +
      "Sending a boolean for a numeric param (or vice versa) is a readable error naming the " +
      "mismatch. Out-of-range numbers clamp silently for the six original numeric params, " +
      "through the same ranges track_set_instrument uses; `bendRangeSemitones` and " +
      "`voiceMode` instead REFUSE an out-of-range number / unrecognised mode with a " +
      "readable error, so a typo cannot land as a silently-different setting (see " +
      "`param`'s own description for each range). Returns the full resolved instrument " +
      "object, same shape as track_set_instrument.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the instrument track, from project_snapshot."),
      param: samplerGlobalParamSchema,
      value: z
        .union([z.number(), z.boolean(), z.string()])
        .describe(
          "The new value: a boolean for `param: \"oneShot\"`, the string \"poly\" or " +
            "\"mono\" for `param: \"voiceMode\"`, and a number for every other `param` " +
            "(seconds for `attack`/`release`, a 0-1 level for `gain`/" +
            "`expressionModDepth`/`expressionFilterDepth`, an integer CC 0-127 for " +
            "`expressionFilterCC`, semitones 0-48 for `bendRangeSemitones`). See " +
            "`param`'s description for which type and range applies."
        ),
    },
  },
  async ({ trackId, param, value }) =>
    toToolResult(() => {
      // `value` had to widen to include `z.string()` so `voiceMode` could take
      // "poly"/"mono" (m26-*, 2026-08-23). That widening SILENTLY re-admitted a
      // string for every OTHER param — {param:"gain", value:"loud"} began passing
      // schema validation and reaching the app, where it had previously been
      // refused at this boundary. Re-narrow here, BEFORE the bridge call, so the
      // boundary guarantee the union used to provide still holds.
      // Deliberately minimal: this restores exactly what was lost and tightens
      // nothing else (a boolean for a numeric param was accepted before and
      // still is), because the wire contract is additive-only.
      if (typeof value === "string" && param !== "voiceMode") {
        throw new Error(
          `sampler param "${param}" does not take a string — got ${JSON.stringify(value)}. ` +
            `Only "voiceMode" is a string param ("poly" or "mono").`
        );
      }
      if (param === "voiceMode" && typeof value !== "string") {
        throw new Error(
          `sampler param "voiceMode" takes the string "poly" or "mono" — got ${typeof value}.`
        );
      }
      return bridge.send("track.setInstrument", { trackId, sampler: { [param]: value } });
    })
);

/** Shared per-zone field shape (the samplerZoneSchema precedent) with `path`
 * made OPTIONAL and an `id` added and REQUIRED — a zonePatches element edits
 * an EXISTING zone by id, so it may change zero or more fields (including
 * swapping the sample file itself) rather than authoring a whole new zone.
 * Reuses samplerZoneSchema's own field schemas (not retyped) so the two
 * shapes cannot drift apart on range/default text. `.strict()` here is
 * load-bearing, not decoration: `registerTool`'s wrapper only applies
 * `.strict()` at the TOP level, so without this a typo'd field INSIDE one
 * patch element (e.g. "maxPtich") would be silently stripped by zod's
 * default parse mode, the patch would land with one fewer field than
 * intended, and the call would still report success. */
const samplerZonePatchSchema = z
  .object({
    id: z
      .string()
      .uuid()
      .describe(
        "REQUIRED. The zone to edit, by id — read it from a prior " +
          "instrument_describe_sampler or project_snapshot call " +
          "(instrument.sampler.zones[].id). Must already name a zone on THIS track: an id " +
          "copied from a DIFFERENT track is a readable error naming the id — this tool " +
          "never silently inserts a new zone or re-mints the id. To copy a zone map onto a " +
          "different track, use track_set_instrument's wholesale `zones` array instead, " +
          "which mints fresh ids automatically and reports the substitution in the " +
          "response's `remintedZoneIDs`."
      ),
    ...samplerZoneSchema.shape,
    path: samplerZoneSchema.shape.path
      .optional()
      .describe(
        "Absolute path to REPLACE this zone's sample audio file with. Omit to keep the " +
          "zone's CURRENT file — most patches touch only a mapping/envelope field and leave " +
          "the audio alone."
      ),
  })
  .strict();

registerTool(
  "instrument_set_sampler_zones",
  {
    title: "Edit existing Sampler zones by id, leaving every other zone standing",
    description:
      "Edit one or more of a track's EXISTING Sampler zones by id — a targeted MERGE, the " +
      "opposite of track_set_instrument's `sampler.zones`, which REPLACES the whole keyzone " +
      "map wholesale (and whose `zones: []` is the only way to CLEAR a sampler; that " +
      "replace-vs-merge choice is not available here). This is the tool for touching one " +
      "zone of a 309-zone imported library without resending the other 308: each entry in " +
      "`zones` below names an existing zone by `id` and changes only the fields it mentions " +
      "— everything else on that zone (and every zone not named at all) is left exactly as " +
      "it was, INCLUDING fields left nil (e.g. an unset `pan` stays unset, not reset to an " +
      "explicit 0). A patch can even swap a zone's sample file via `path` while keeping its " +
      "pitch/velocity mapping. Under the hood this wraps track_set_instrument's " +
      "`sampler.zonePatches` merge path (m26-g). Ids are per-track and this tool is STRICT " +
      "about them: an id from a prior instrument_describe_sampler/project_snapshot call on " +
      "a DIFFERENT track, or one that never existed, or one repeated twice in the same call, " +
      "is a readable error naming the id, and nothing lands — never a silent insert. " +
      "(track_set_instrument's OWN `zones` array behaves differently on an unrecognized id: " +
      "it mints a fresh one and reports the substitution in `remintedZoneIDs`, because that " +
      "path is also how a zone map gets copied from one track onto another — this tool is " +
      "narrower on purpose.) Returns the full resolved instrument object, same shape as " +
      "track_set_instrument.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the instrument track, from project_snapshot."),
      zones: z
        .array(samplerZonePatchSchema)
        .describe(
          "One or more zone edits, each naming the zone it applies to via `id` (required). " +
            "Every other field is optional and PATCHES that one zone: omit a field to keep " +
            "the zone's current value for it, unlike track_set_instrument's wholesale " +
            "`zones` array where an omitted field falls back to a fresh-zone DEFAULT. Zones " +
            "not named in this array are untouched. Zone ORDER on the track is preserved " +
            "(a patch replaces its zone in place; it never reorders or appends), which " +
            "matters because on an overlap the FIRST zone (array order) whose range " +
            "contains a note wins."
        ),
    },
  },
  async ({ trackId, zones }) =>
    toToolResult(() =>
      bridge.send("track.setInstrument", { trackId, sampler: { zonePatches: zones } })
    )
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
    "bassEnhancer",
    "bitCrusher",
    "audioUnit",
  ])
  .describe(
    "Effect kind. `gain` is a simple linear gain stage. `eq` is a parametric " +
      "equalizer (low shelf, two peaking/bell bands, high shelf, plus optional high-pass " +
      "and low-pass filters at 12 or 24 dB/oct, shelf Q, and per-band bypass) — call " +
      "fx_describe to see its exact parameter names and each one's teaching `note`, e.g. " +
      "`peak1Freq`/`peak1GainDb`/`peak1Q` for the first peaking band (the second peaking " +
      "band follows the same naming pattern), `highPassFreq`/`highPassSlopeDbPerOct`/" +
      "`highPassEnabled` for the high-pass (off until you set its frequency or enable it). " +
      "`compressor` is a soft-knee, stereo-linked dynamics processor: `thresholdDb`, " +
      "`ratio`, `attackMs`, `releaseMs`, `kneeDb`, `makeupDb`, and `mix` — the parallel " +
      "(New-York) compression blend, 0 = untouched dry signal, 1 = fully compressed " +
      "(the default, so an existing project is unchanged). Crush hard and blend a little " +
      "back with `mix` rather than duplicating the track. `limiter` is a lookahead " +
      "brick-wall limiter: `ceilingDb`, `releaseMs`, `truePeak` — it adds 5 ms of processing " +
      "latency, reported per-effect as `latencySamples` in project_snapshot's `effects` array. " +
      "MIND WHICH PEAK THE CEILING COUNTS (m23-ch): with `truePeak: 0` (the default) " +
      "`ceilingDb` is a hard dBFS SAMPLE-peak limit, and a true-peak meter — ffmpeg " +
      "ebur128, render_measure_loudness's `truePeakDbtp`, any delivery QC — will read " +
      "roughly 0.4-1 dB ABOVE it on dense material. That is arithmetic (the meter " +
      "reconstructs the waveform between samples), not a bug and not run-to-run " +
      "nondeterminism; do NOT chase it by walking the ceiling down over repeated renders. " +
      "Set `truePeak: 1` instead and `ceilingDb` becomes a dBTP TRUE-peak limit via 4x " +
      "oversampled detection, so a -1 dBTP delivery spec is met on the first render. It " +
      "limits ~0.3-1 dB harder — that reduction IS the inter-sample overshoot it removes. " +
      "The dynamics kinds (compressor/limiter/gate) also report a live `gainReductionDb` " +
      "meter there (positive dB, held-peak, −20 dB/s release) — poll project_snapshot " +
      "during playback to verify a compressor is actually working. " +
      "`reverb` is a Freeverb-style room simulation: `roomSize`, `damping`, `mix`, " +
      "`preDelayMs`, `width`. `delay` is a stereo echo: `timeMs`, `feedback`, `mix`, " +
      "`pingPong` (0 or 1 — 1 alternates repeats left/right), `highCutHz`, plus tempo " +
      "sync — `sync` (0 or 1; 1 derives the effective time from the project tempo, " +
      "tracking tempo changes, while `timeMs` stays stored as the unsync fallback) and " +
      "`division` (the synced note length as its duration in BEATS, snapped to the " +
      "nearest of 1/1…1/32 straight/dotted/triplet — e.g. 1 = 1/4, 0.75 = 1/8 dotted, " +
      "0.333 = 1/8 triplet; the snapshot echoes a human `divisionLabel` like \"1/8d\"). " +
      "`saturator` " +
      "is a tanh-based drive/color stage: `driveDb`, `mix`, `outputDb`. `gate` is a " +
      "noise gate: `thresholdDb`, `attackMs`, `holdMs`, `releaseMs`. `chorus` is a " +
      "2-voice modulated thickener: `rateHz`, `depthMs`, `mix`. " +
      "`bassEnhancer` is a psychoacoustic bass enhancer (RBass class): `crossoverHz`, " +
      "`amount`, `mix`. It low-passes the signal at `crossoverHz`, synthesizes the " +
      "2nd/3rd/4th harmonics OF THAT LOW BAND ONLY, high-passes them back at the same " +
      "corner, and ADDS them to an untouched dry path — so a speaker that cannot " +
      "reproduce a 50 Hz fundamental still hears its harmonic series and the ear infers " +
      "the missing fundamental. Reach for it when a mix has no low end on laptops or " +
      "phones. It is NOT the `saturator`: the shaper only ever sees the low band and the " +
      "series stops at the 4th partial. Be honest with users that it ADDS harmonics that " +
      "were not in the recording. `amount` 0 or `mix` 0 is bit-exact bypass. " +
      "`bitCrusher` is a bit-depth + sample-rate reducer - the lo-fi character of " +
      "a 1980s sampling drum machine: `bits` (1-16, whole numbers), `downsampleHz` " +
      "(1000-48000), `antiAlias`, `dither` (both 0 or 1), `mix`. ITS DEFAULTS ARE THE " +
      "POINT AND YOU SHOULD USUALLY LEAVE THEM: 12 bits at 26040 Hz is the E-mu " +
      "SP-1200, and `antiAlias: 0` / `dither: 0` are DELIBERATE. The SP-1200's " +
      "signature comes specifically from its converter OMITTING the reconstruction " +
      "filter, so content above the reduced Nyquist images back down as audible grit; " +
      "a politely filtered, dithered bit-crusher sounds clean-but-crunchy instead of " +
      "gritty and does NOT hit that reference. Turn `antiAlias: 1` on only when a " +
      "user asks for a tamer, modern crush, and `dither: 1` only when you are " +
      "reducing depth for DELIVERY rather than for character. `downsampleHz: 40000` " +
      "is the Akai MPC60, which is why MPC60 chops read as cleaner. Reach for it on a " +
      "chopped sample or a whole drum bus. `mix: 0` is a bit-exact bypass. " +
      "`audioUnit` hosts an " +
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

registerTool(
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
      "params start at their default, and out-of-range values clamp — when one does, " +
      "the response carries a `warnings` array saying which parameter was clamped, to " +
      "what, and why, so a seeded value that did not fit never passes for one that did. " +
      "(A `gain` insert's `gainLinear` seeds anywhere in 0-16, up to +24.08 dB.) " +
      "`audioUnit` " +
      "(see its own description) selects a specific installed Audio Unit effect plugin " +
      "by component triple and is REQUIRED when `kind` is `audioUnit` (call " +
      "fx_list_audio_units first to discover what's installed); it's ignored for every " +
      "other kind. Each track/bus's insert chain is capped at 16 effects (adding a 17th " +
      "errors). Adding an effect never interrupts or glitches playback. " +
      "MASTER CHAIN: pass `trackId` as the exact string \"master\" to insert on the whole " +
      "mix's master output chain (post-fader, the last stop before the speakers) instead " +
      "of a track/bus. The master chain hosts BUILT-IN effects only in v1 — `kind: " +
      "\"audioUnit\"` on \"master\" is rejected (pick one of gain|eq|compressor|limiter|" +
      "reverb|delay|saturator|gate|chorus|bassEnhancer|bitCrusher). Classic mastering move: fx_add {trackId: " +
      "\"master\", kind: \"eq\"} then {trackId: \"master\", kind: \"limiter\"}, then " +
      "render_measure_loudness to check the level. Returns " +
      "`{effectId, effects}`: the new effect's server-minted id, and the track's full " +
      "updated insert chain (same shape as project_snapshot's per-track `effects` array) " +
      "— plus `warnings` when a seeded `params` value had to be clamped (absent otherwise).",
    inputSchema: {
      trackId: z
        .string()
        .min(1)
        .describe("Id of the track or bus to add the effect to, from project_snapshot, OR the exact string \"master\" for the master output chain (built-in kinds only there)."),
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

registerTool(
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

registerTool(
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

// ---------------------------------------------------------------------------
// Hosted Audio Unit parameters (design-au-parameter-surface) — read/write the
// live AUParameterTree of a hosted AU instrument or effect, for turning a
// plugin's knobs without opening its window.
// ---------------------------------------------------------------------------

const auTrackIdSchema = z
  .string()
  .min(1)
  .describe(
    "Id of the track hosting the Audio Unit, from project_snapshot — targets its AU " +
      "INSTRUMENT (omit effectId) or one of its AU insert effects (pass effectId). Not " +
      "\"master\": the master chain hosts built-in effects only, never Audio Units."
  );

const auEffectIdSchema = z
  .string()
  .min(1)
  .optional()
  .describe(
    "Id of the AU insert effect on that track, from fx_add's result or " +
      "project_snapshot's per-track `effects`. Omit to target the track's own AU " +
      "INSTRUMENT instead."
  );

server.registerTool(
  "au_describe_params",
  {
    title: "Read a hosted Audio Unit's live parameters",
    description:
      "Read the live parameter tree of a hosted Audio Unit instrument or effect — " +
      "the FIRST step of the describe-then-set workflow: call this to discover a " +
      "plugin's parameters, then pass one of the returned `address` strings to " +
      "au_set_param to change it. Targets a track's AU INSTRUMENT (omit effectId) or " +
      "one of its AU insert effects (pass effectId, from fx_add's result or " +
      "project_snapshot). Every `address` is an OPAQUE, per-instance decimal string " +
      "(a UInt64 as text — JSON numbers lose precision above 2^53): copy it VERBATIM " +
      "from this tool's own output, never guess one, and never reuse one captured " +
      "from a different plugin instance (removing and re-adding the same AU can " +
      "renumber its whole tree). Large trees page: by default this returns up to 512 " +
      "parameters starting at `offset` 0 — check the response's `truncated` flag and " +
      "`totalCount` and re-call with a higher `offset` to walk the rest, or pass " +
      "`addresses` as an exact-get filter instead (mutually exclusive with " +
      "offset/maxParams; misses land in the response's `unknownAddresses`, never an " +
      "error). `hasParameterTree:false` (with `totalCount:0`) is a SUCCESSFUL answer " +
      "for an AU that simply publishes no parameter tree (an opaque-state plugin, " +
      "healthy but nothing to page or set here) — use plugin_open_ui to edit it " +
      "visually instead. Returns {trackId, effectId?, componentName, " +
      "hasParameterTree, totalCount, offset, truncated, parameters: [{address, " +
      "identifier, displayName, keyPath, unit, unitName, minValue, maxValue, value, " +
      "writable, readable, valueStrings}], unknownAddresses}.",
    inputSchema: {
      trackId: auTrackIdSchema,
      effectId: auEffectIdSchema,
      offset: z
        .number()
        .int()
        .min(0)
        .optional()
        .describe(
          "Zero-based index into the AU's flat parameter list to start this page " +
            "from, for paging through a large tree. Default 0. Mutually exclusive " +
            "with `addresses`."
        ),
      maxParams: z
        .number()
        .int()
        .min(1)
        .max(4096)
        .optional()
        .describe(
          "Max number of parameters to return in this page. Default 512, silently " +
            "clamped into 1-4096. Compare against the response's `totalCount` and " +
            "`truncated` to know whether to page further. Mutually exclusive with " +
            "`addresses`."
        ),
      addresses: z
        .array(z.string().min(1))
        .optional()
        .describe(
          "Exact-get filter: return only these specific parameter addresses " +
            "(decimal strings from a prior au_describe_params call) instead of " +
            "paging the whole tree. Mutually exclusive with offset/maxParams. Any " +
            "address not found in the AU's tree is reported in the response's " +
            "`unknownAddresses` array rather than erroring."
        ),
    },
  },
  async ({ trackId, effectId, offset, maxParams, addresses }) =>
    toToolResult(() =>
      bridge.send("au.describeParams", { trackId, effectId, offset, maxParams, addresses })
    )
);

registerTool(
  "au_set_param",
  {
    title: "Turn a hosted Audio Unit's knob",
    description:
      "Set ONE parameter of a hosted Audio Unit instrument or effect by its " +
      "`address` (from au_describe_params — call that first; addresses are opaque, " +
      "per-instance decimal strings that must never be guessed or reused across a " +
      "different plugin instance). Targets a track's AU INSTRUMENT (omit effectId) " +
      "or one of its AU insert effects (pass effectId). This is how you turn a " +
      "hosted plugin's knob without opening its window: the edit applies LIVE, " +
      "audible immediately, never interrupting or glitching playback. Out-of-range " +
      "`value`s clamp SILENTLY to the parameter's [minValue, maxValue] (the " +
      "fx_set_param precedent) rather than erroring — and because some AUs quantize " +
      "or step their values, the response's `parameter.value` is always the " +
      "plugin's ACTUAL post-set READ-BACK, not an echo of what you asked for, so " +
      "treat it as the truth. Setting a read-only parameter, an unknown address, or " +
      "a non-finite value is a readable error naming the problem; an AU with no " +
      "parameter tree at all (`hasParameterTree:false` from au_describe_params) " +
      "can't be set this way — use plugin_open_ui instead. Deliberately no undo " +
      "step (parity with edits made in the plugin's own window) — the value " +
      "persists via the project's normal save. Returns {trackId, effectId?, " +
      "parameter: {…the refreshed parameter, same shape as au_describe_params…}}.",
    inputSchema: {
      trackId: auTrackIdSchema,
      effectId: auEffectIdSchema,
      address: z
        .string()
        .min(1)
        .describe(
          "The parameter's address, EXACTLY as returned by au_describe_params's " +
            "`address` field (a decimal-string UInt64). Opaque and per-instance — " +
            "never guess one or reuse one captured from a different plugin instance."
        ),
      value: z
        .number()
        .describe(
          "New value for the parameter. Out-of-range values clamp silently to the " +
            "parameter's [minValue, maxValue] (see au_describe_params); NaN/Infinity " +
            "are rejected with a readable error."
        ),
    },
  },
  async ({ trackId, effectId, address, value }) =>
    toToolResult(() => bridge.send("au.setParam", { trackId, effectId, address, value }))
);

registerTool(
  "fx_remove",
  {
    title: "Remove an effect from a track or bus's insert chain",
    description:
      "Permanently remove an effect from a track or bus's insert chain by id, shifting " +
      "later effects up to fill the gap. Pass `trackId` as a track/bus id, or the exact " +
      "string \"master\" to remove from the master output chain (m13-d). Reversible with " +
      "edit_undo. Never interrupts or glitches playback. Returns the full updated insert " +
      "chain (`effects`, same shape as project_snapshot).",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track or bus that owns the effect, from project_snapshot, OR \"master\" for the master output chain."),
      effectId: z
        .string()
        .min(1)
        .describe("Id of the effect to remove, from fx_add's result or project_snapshot."),
    },
  },
  async ({ trackId, effectId }) => toToolResult(() => bridge.send("fx.remove", { trackId, effectId }))
);

registerTool(
  "fx_reorder",
  {
    title: "Move an effect within a track or bus's insert chain",
    description:
      "Move an existing effect to a new position within its track or bus's insert " +
      "chain. Array order IS processing order, so reordering changes what the signal " +
      "actually hears — e.g. moving an EQ before vs. after a compressor sounds " +
      "different. Pass `trackId` as a track/bus id, or the exact string \"master\" to " +
      "reorder the master output chain (m13-d). `index` is the new zero-based position; " +
      "out-of-range values clamp into range rather than erroring. Never interrupts or " +
      "glitches playback. Returns the full updated insert chain (`effects`, same shape " +
      "as project_snapshot).",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track or bus that owns the effect, from project_snapshot, OR \"master\" for the master output chain."),
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

registerTool(
  "fx_set_bypass",
  {
    title: "Bypass or re-enable an effect",
    description:
      "Bypass (temporarily disable, passing audio through unprocessed) or re-enable an " +
      "effect already in a track or bus's insert chain, without removing it from the " +
      "chain or losing its parameter values — use this to A/B an effect's contribution. " +
      "Pass `trackId` as a track/bus id, or the exact string \"master\" to bypass an " +
      "effect on the master output chain (m13-d). Bypass takes effect INSTANTLY and " +
      "never interrupts or glitches playback. Returns the full updated insert chain " +
      "(`effects`, same shape as project_snapshot).",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track or bus that owns the effect, from project_snapshot, OR \"master\" for the master output chain."),
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

registerTool(
  "fx_set_param",
  {
    title: "Set an effect parameter",
    description:
      "Change one parameter, by name, of an effect already in a track or bus's insert " +
      "chain — the way to ride an FX knob (e.g. turning up a gain stage's `gain`, tightening " +
      "a compressor's `ratio`, or pulling down a limiter's `ceilingDb`). Pass `trackId` as " +
      "a track/bus id, or the exact string \"master\" to ride a knob on the master output " +
      "chain (m13-d — e.g. a mastering limiter's `ceilingDb`). " +
      "Parameter names, ranges, defaults, and units are discoverable per effect kind via " +
      "fx_describe — pass the exact `name` it lists. Out-of-range `value`s clamp to the " +
      "parameter's valid range rather than erroring, and the clamp is NO LONGER SILENT: " +
      "when your value did not fit, the response carries a `warnings` array with a plain " +
      "sentence naming what you asked for, what was actually stored, and the range. That " +
      "key is ABSENT on an ordinary in-range call, so its presence always means the stored " +
      "value is not the one you sent — read it back rather than assuming your number took. " +
      "GAIN CEILING: the `gain` insert's `gainLinear` runs 0-16, i.e. up to +24.08 dB " +
      "(1 = unity, 2 = +6 dB, 4 = +12 dB; dB = 20*log10(gainLinear)). It is that wide on " +
      "purpose, because sound-bank / General-MIDI material is quiet: a solo GM piano part " +
      "measures about -28 LUFS at velocity 100 and near -35 LUFS at velocity 64, so a " +
      "-14 LUFS streaming target needs roughly +14 to +21 dB of makeup. ONE gain insert now " +
      "covers that range — chaining a second one, which used to be necessary, is not. The " +
      "headroom is not free: this is a plain multiply with no protection of its own, so a " +
      "big boost can drive the mix into hard clipping. Put a limiter AFTER the gain insert " +
      "when you push it hard, and check the result with render_measure_loudness rather than " +
      "trusting the multiplier. Edits apply LIVE, in place, without " +
      "interrupting or glitching playback. Returns the full updated insert chain " +
      "(`effects`, same shape as project_snapshot) plus `warnings` when a value was clamped.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track or bus that owns the effect, from project_snapshot, OR \"master\" for the master output chain."),
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
            "— see fx_describe for that range — and the response's `warnings` says so when " +
            "that happens. For a gain insert's `gainLinear` the range is 0-16 (+24.08 dB)."
        ),
    },
  },
  async ({ trackId, effectId, name, value }) =>
    toToolResult(() => bridge.send("fx.setParam", { trackId, effectId, name, value }))
);

registerTool(
  "fx_set_sidechain",
  {
    title: "Key a compressor or gate from another track (sidechain)",
    description:
      "Set (or clear) the SIDECHAIN KEY of a built-in compressor or gate — make it react " +
      "to ANOTHER track's signal instead of its own. This is how you get classic pumping: " +
      "add a compressor to the pad/bass track, then key it from the kick so the pad ducks on " +
      "every kick hit (`fx_set_sidechain {trackId: pad, effectId: comp, sourceTrackId: kick}`). " +
      "Pass `sourceTrackId: null` (or omit it) to CLEAR the key and return the effect to " +
      "self-keyed. Only compressor and gate inserts can be keyed (hosted Audio Unit sidechain " +
      "inputs are a later phase). WHERE THE PIECES MAY LIVE: the KEYED EFFECT must sit on an " +
      "AUDIO or BUS track — an instrument track cannot host one, so in an all-MIDI project " +
      "add a bus (track_add kind:\"bus\"), route the instrument into it with track_set_output, " +
      "and key the compressor ON THE BUS. The KEY SOURCE, by contrast, may be ANY NON-BUS " +
      "track — an INSTRUMENT track is a perfectly valid key source, so ducking off a MIDI kick " +
      "needs no audio bounce (only bus key sources are deferred). " +
      "A key that would form a feedback loop is rejected with the exact path. " +
      "The MASTER chain cannot host a sidechain-keyed effect and the master output cannot be a " +
      "key source: passing \"master\" as `trackId` or `sourceTrackId` is rejected — key an " +
      "effect on a track or bus instead (unlike fx_add/fx_remove/fx_reorder/fx_set_bypass/" +
      "fx_set_param, this tool takes NO \"master\" sentinel). " +
      "Refused while a recording is in progress (a key edge rewires the audio graph, which would " +
      "truncate the take) — stop recording first. " +
      "Returns the track's full updated insert chain (`effects` — the keyed effect carries " +
      "`sidechainSourceTrackId`) plus `sidechainSkewSamples` (how far the key is delayed by " +
      "plugin latency, usually 0).",
    inputSchema: {
      trackId: z
        .string()
        .min(1)
        .describe("Id of the track or bus whose compressor/gate is being keyed, from project_snapshot (not \"master\" — the master chain cannot be keyed)."),
      effectId: z
        .string()
        .min(1)
        .describe("Id of the compressor or gate effect to key, from fx_add's result or project_snapshot."),
      sourceTrackId: z
        .string()
        .min(1)
        .nullable()
        .optional()
        .describe(
          "Id of the track to key FROM (e.g. the kick) — any NON-BUS track, instrument tracks " +
            "included; it does NOT have to be an audio track. Pass null or omit to CLEAR the " +
            "key and return the effect to self-keyed."
        ),
    },
  },
  async ({ trackId, effectId, sourceTrackId }) =>
    toToolResult(() =>
      bridge.send("fx.setSidechain", { trackId, effectId, sourceTrackId: sourceTrackId ?? null })
    )
);

registerTool(
  "fx_spectrum",
  {
    title: "Read (and hold) an insert's own spectrum — not just the master mix",
    description:
      "Read the real-time analysis snapshot measured on ONE effect insert's own output — " +
      "the same shape mixer_master_analysis returns (bands/levelDB/peakDB/centroidHz/flux/" +
      "correlation/width/balance — see that tool's description for what each field means), " +
      "but scoped to a single insert instead of the whole mix, so you can see what an EQ or " +
      "compressor is actually PRODUCING rather than what the master bus receives overall. " +
      "Pass `trackId` as a track/bus id, or the exact string \"master\" for the master output " +
      "chain, plus the `effectId` of the insert to measure. `arm` (default true) arms — or, " +
      "on every subsequent call, RENEWS — a 3-second measurement lease and then reads; a call " +
      "with `arm: false` reads one last time and releases the tap immediately. Poll at 5-30 Hz " +
      "while you want the reading live: below roughly 12 Hz the underlying ring buffer drops " +
      "its oldest frames, so peak release and flux smoothing lag behind wall-clock. If you stop " +
      "polling, the lease simply expires on its own after 3 seconds — no separate cleanup call " +
      "is required, though an explicit `arm: false` releases it immediately and is more polite " +
      "if you know you are done. A freshly armed tap honestly reads the floor (-80 dB bands) " +
      "for its first ~43 ms, never a fabricated non-floor value. At most 8 inserts total — " +
      "shared with the app's own EQ meter, first-come-first-served — can be measured at once; " +
      "a 9th is refused (naming the cap and how to free a slot), never silently evicted. " +
      "Returns the snapshot fields plus `armed` (whether the lease is held as of this response), " +
      "`tapPoint` (\"postInsertPreFader\" for a track/bus insert — measured BEFORE that " +
      "track's own fader, so moving the fader does not move this curve — or " +
      "\"postInsertPostFader\" for a master insert, measured AFTER the master fader; comparing " +
      "a strip reading to a master reading without checking `tapPoint` is how you'd wrongly " +
      "conclude the meter is broken), and `leaseSeconds` (the full lease length, currently 3). " +
      "A refusal never carries analysis fields — an unarmed tap never masquerades as a live " +
      "silent meter.",
    inputSchema: {
      trackId: z
        .string()
        .min(1)
        .describe(
          "Id of the track or bus that owns the effect, from project_snapshot, OR \"master\" " +
            "for the master output chain."
        ),
      effectId: z
        .string()
        .min(1)
        .describe("Id of the effect to measure, from fx_add's result or project_snapshot."),
      arm: z
        .boolean()
        .optional()
        .describe(
          "Default true: arm (or renew) the 3-second measurement lease and read. False: read " +
            "one last time and release the tap immediately."
        ),
    },
  },
  async ({ trackId, effectId, arm }) =>
    toToolResult(() => bridge.send("fx.spectrum", { trackId, effectId, arm }))
);

server.registerTool(
  "fx_describe",
  {
    title: "List effect kinds and their parameters",
    description:
      "Look up the parameter schema for one or every available effect kind — the " +
      "reference for fx_add's `params` and fx_set_param's `name`/`value`. Returns, per " +
      "kind, its parameter list as `{name, min, max, default, unit}` (`unit` is a short " +
      "human label, e.g. \"linear gain\", \"dB\", \"Hz\", \"ms\", \"seconds\"), plus a " +
      "teaching `note` on parameters whose bare range hides semantics (the eq's " +
      "nil-means-off high/low-pass, 12/24 slope snapping, 0/1 per-band bypass). Omit `kind` " +
      "to list every available kind at once. Available kinds: `gain` (simple linear " +
      "gain stage), `eq` (parametric — low shelf, two peaking bands, high shelf, plus " +
      "optional high/low-pass filters, shelf Q, and per-band `*Enabled` bypass), " +
      "`compressor` (soft-knee, stereo-linked dynamics), `limiter` (lookahead " +
      "brick-wall, adds 5 ms latency — see project_snapshot's per-effect `latencySamples`), " +
      "`reverb` (Freeverb-style room — roomSize/damping/mix/preDelayMs/width), `delay` " +
      "(stereo echo — timeMs/feedback/mix/pingPong/highCutHz, plus m22-f tempo sync: " +
      "`sync` 0/1 and `division` in beats, snapped to 1/1…1/32 straight/dotted/triplet " +
      "— their `note`s teach the exact semantics; when synced the effective time is " +
      "division × 60000 / tempo BPM and follows tempo changes, `timeMs` staying the " +
      "unsync fallback), `saturator` (tanh drive " +
      "color — driveDb/mix/outputDb), `gate` (noise gate — thresholdDb/attackMs/holdMs/" +
      "releaseMs), `chorus` (2-voice modulated thickener — rateHz/depthMs/mix), and " +
      "`bassEnhancer` (psychoacoustic bass enhancer — crossoverHz/amount/mix: it " +
      "generates the 2nd/3rd/4th harmonics of the sub-crossover content and adds them " +
      "above the crossover so small speakers imply a fundamental they cannot play; the " +
      "params' `note`s teach the exact semantics), and `bitCrusher` (bit-depth + " +
      "sample-rate reduction - bits/downsampleHz/antiAlias/dither/mix, defaulting to " +
      "the SP-1200's 12 bits at 26040 Hz with anti-aliasing and dither deliberately " +
      "OFF because the aliasing IS the character; read its notes before turning " +
      "either switch on).",
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

registerTool(
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
// Output
// ---------------------------------------------------------------------------

server.registerTool(
  "output_list_devices",
  {
    title: "List audio output devices",
    description:
      "List the Mac's available audio output devices (built-in speakers, " +
      "headphones, USB/Thunderbolt audio interfaces, etc). Each entry has " +
      "`uid` (stable identifier to pass to output_set_device), `name`, " +
      "`sampleRate` (Hz), `channelCount`, `isDefault` (true for the " +
      "system's current default output — the macOS Sound setting), and " +
      "`isSelected` (true for the device DAW Pro has explicitly pinned). " +
      "The two are independent, and reading them together is what tells " +
      "you the actual state: all `isSelected` false means DAW Pro is " +
      "following the system default and will keep following it if the " +
      "user changes it; `isSelected` true with `isDefault` false means " +
      "playback is pinned somewhere other than the system default; both " +
      "true means it is pinned to the device that currently happens to BE " +
      "the default, and will stay on that device even if the default " +
      "moves. No params. Call this before output_set_device to find a " +
      "device's uid, or afterwards to confirm what is now selected.",
  },
  async () => toToolResult(() => bridge.send("output.listDevices"))
);

registerTool(
  "output_set_device",
  {
    title: "Pin the playback output device",
    description:
      "Pin DAW Pro's own playback to a specific audio output device by uid " +
      "(from output_list_devices), independent of the Mac's system default " +
      "output. This is app-local — it does NOT change the macOS default " +
      "output device (System Settings > Sound stays untouched), so other " +
      "apps and system sounds keep playing wherever they already were; it " +
      "only redirects what DAW Pro itself sends out, e.g. to send the mix " +
      "to an audio interface while notification sounds stay on the " +
      "speakers. Returns the device list reflecting the new selection — the " +
      "pinned device comes back with `isSelected: true` — so no follow-up " +
      "output_list_devices call is needed. Omit `uid` (or pass nothing) to " +
      "clear the pin and go back to following the Mac's system default " +
      "output device, which comes back as `isSelected` false on every entry.",
    inputSchema: {
      uid: z
        .string()
        .min(1)
        .optional()
        .describe(
          "Uid of the output device to pin, from output_list_devices. Omit " +
            "to revert to the system default output device."
        ),
    },
  },
  async ({ uid }) => toToolResult(() => bridge.send("output.setDevice", { uid: uid ?? null }))
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
})
  // `.strict()` (m30-c): `registerTool`'s wrapper only strictens the TOP
  // level of clip_add_midi/clip_set_notes's own inputSchema — a typo'd field
  // inside one element of the `notes` array (e.g. "velocty") would otherwise
  // be silently stripped instead of rejected.
  .strict();

registerTool(
  "clip_add_audio",
  {
    title: "Import an audio file as a clip",
    description:
      "Import an audio file (wav, aiff, mp3, or m4a) as a new clip on an audio " +
      "track. The clip's length is computed automatically from the file's " +
      "duration at the current project tempo — you don't need to pass a length. " +
      "Instrument and bus tracks reject audio clips; use track_add or " +
      "project_snapshot to find/create an `audio` track first. Returns the " +
      "created clip (id, name, startBeat, lengthBeats) plus trimmedClipIDs and " +
      "removedClipIDs (both empty unless you passed overwrite). " +
      "⛔ IT WILL NOT OVERWRITE A CLIP THAT IS ALREADY THERE: an atBeat that " +
      "would land this file on top of an existing clip is REFUSED with an error " +
      "naming that clip and a beat you can safely append at — nothing is " +
      "deleted or trimmed. This matters most in the resample loop (bounce, " +
      "re-import, chop the print, repeat): re-using atBeat: 0 for every pass is " +
      "the natural mistake, and it used to destroy the previous import silently. " +
      "OMIT atBeat to append after everything on the track (never refused), or " +
      "import each print onto its own track.",
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
            "Must be >= 0. Omit to append the clip after the track's existing clips " +
            "— the one placement that can never collide with a clip already there."
        ),
      overwrite: z
        .boolean()
        .optional()
        .describe(
          "Default false. Leave it out and an import that would land on top of an " +
            "existing clip is refused, changing nothing. Pass true only when you " +
            "MEAN to replace what is there: the clips underneath are trimmed, or " +
            "deleted outright where this file covers them completely, and their ids " +
            "come back in trimmedClipIDs / removedClipIDs so you can see what went."
        ),
    },
  },
  async ({ trackId, path, atBeat, overwrite }) =>
    toToolResult(() => bridge.send("clip.addAudio", { trackId, path, atBeat, overwrite }))
);

registerTool(
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
      "startBeat. A new instrument track already SOUNDS — it resolves to the " +
      "default poly synth even when nothing has been configured on it, so a " +
      "clip written here is audible immediately. Use track_set_instrument to " +
      "put it on a sound bank, sampler, or hosted Audio Unit instead. " +
      "`returnNotes` (default true, UNCHANGED from before this param existed) controls " +
      "whether the response echoes the notes array back at all: on the hot path of a " +
      "composing session this echo is often the single biggest cost in the call, since " +
      "the useful result is almost always just the new clip id, not per-note ids you " +
      "rarely edit immediately. Pass `returnNotes: false` to get the clip back WITHOUT " +
      "its `notes` array — the response instead carries `notesOmitted: true` and " +
      "`noteCount` (how many notes were actually written), so it can never be mistaken " +
      "for a genuinely empty clip. Nothing is lost: read the notes back any time with " +
      "clip_get_notes (read-only, no undo step, takes the returned clip's id). Note " +
      "this only trims what crosses back to YOU — the full payload still crosses the " +
      "app's own control connection either way, so it saves your context budget, not " +
      "wire bytes.",
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
      returnNotes: z
        .boolean()
        .optional()
        .describe(
          "Whether the response echoes the written notes back, each with its " +
            "server-minted id. Defaults to true (unchanged prior behavior). Pass " +
            "false to drop the notes array from the response and get back " +
            "`notesOmitted: true` plus `noteCount` instead — the notes are still " +
            "written and are always readable afterward via clip_get_notes; this " +
            "only shrinks what comes back to you, not what crosses the app's own " +
            "control connection."
        ),
    },
  },
  async ({ trackId, name, atBeat, lengthBeats, notes, returnNotes }) =>
    toToolResult(async () => {
      const result = await bridge.send("clip.addMIDI", { trackId, name, atBeat, lengthBeats, notes });
      if (returnNotes === false && result && typeof result === "object" && Array.isArray((result as any).notes)) {
        const { notes: writtenNotes, ...rest } = result as Record<string, unknown>;
        return { ...rest, notesOmitted: true, noteCount: (writtenNotes as unknown[]).length };
      }
      return result;
    })
);

registerTool(
  "clip_set_notes",
  {
    title: "Replace a MIDI clip's notes",
    description:
      "Replace a MIDI clip's ENTIRE note array — the tool for ADDING, " +
      "REMOVING, or reordering notes, or rewriting a clip's content " +
      "wholesale. If you are only CHANGING FIELDS (pitch/velocity/startBeat/" +
      "lengthBeats) on notes that already exist, and not adding or removing " +
      "any, use clip_patch_notes instead — it edits by id without " +
      "resubmitting notes you are not touching, and it can never drop a " +
      "note you didn't mean to. To add/remove/reorder here: read the " +
      "clip's current notes with clip_get_notes (preferred — one clip, not " +
      "the whole project) or from project_snapshot, modify the array " +
      "(add, remove, or change notes) in your own code, then resubmit the " +
      "whole array here. One call = one undo step (edit_undo reverts the " +
      "entire replacement). `notes` may be empty to clear the clip. Errors " +
      "readably if `clipId` refers to an audio clip (audio clips have no " +
      "notes). " +
      "⭐ THE CLIP ID SURVIVES: this edits the clip in place and never " +
      "creates a replacement, so `clipId` — and the clip's position, length " +
      "and every other field — stay valid across a full replace. That makes " +
      "RE-AUTHORING a clip wholesale a supported fallback when you cannot " +
      "read it first (e.g. clip_get_notes is unavailable) AND you are the " +
      "source of its content: rewrite the array you intended, and any ids " +
      "your later steps depend on still resolve. Reading first remains " +
      "preferred whenever the clip's notes came from anywhere else, since a " +
      "whole-array write drops whatever you did not include. " +
      "`returnNotes` (default true, UNCHANGED from before this param existed, m31-b/m30-g) " +
      "controls whether the response echoes the written notes back: since notes without an " +
      "id get one SERVER-MINTED on write, the echo is often needed to learn those new ids " +
      "before a follow-up edit, unlike the pure-mutation tools (clip_duplicate, " +
      "clip_remove_many, clip_humanize) where it defaults off. Pass `returnNotes: false` " +
      "to get the clip back WITHOUT its `notes` array when you already know you won't need " +
      "the ids this call — the response instead carries `notesOmitted: true` and " +
      "`noteCount`. Nothing is lost either way: read the notes back any time with " +
      "clip_get_notes.",
    inputSchema: {
      clipId: z.string().uuid().describe("Id of the MIDI clip to edit, from project_snapshot."),
      notes: z
        .array(noteSchema)
        .max(4096)
        .describe(
          "The clip's complete new note array (replaces all existing notes), up " +
            "to 4096 entries. Pass an empty array to remove all notes."
        ),
      returnNotes: z
        .boolean()
        .optional()
        .describe(
          "Whether the response echoes the written notes back, each with its " +
            "server-minted id (notes without one get one on write). Defaults to true " +
            "(unchanged prior behavior). Pass false to drop the notes array from the " +
            "response and get back `notesOmitted: true` plus `noteCount` instead — the " +
            "notes are still written and always readable afterward via clip_get_notes."
        ),
    },
  },
  async ({ clipId, notes, returnNotes }) =>
    toToolResult(async () => {
      const result = await bridge.send("clip.setNotes", { clipId, notes });
      return returnNotes === false ? stripNotesFromResult(result) : result;
    })
);

registerTool(
  "clip_get_notes",
  {
    title: "Read a MIDI clip's notes (read-only)",
    description:
      "Read a MIDI clip's notes back — the read half of the clip_set_notes / " +
      "clip_add_midi pair. Since clip_set_notes replaces the ENTIRE note " +
      "array, you need the CURRENT array (with its real note ids) before " +
      "you can edit a subset of notes and resubmit the whole thing; this " +
      "tool gets you that array. PREFER THIS over project_snapshot for note " +
      "data: project_snapshot serializes the WHOLE project and measured " +
      "~290 KB on a modest 6-track/38-clip/2367-note session (2026-08-17), " +
      "which can overflow your output budget — clip_get_notes returns just " +
      "one clip. `fromBeat`/`toBeat` are CLIP-RELATIVE beats (same frame as " +
      "a note's startBeat: 0 = the clip's own start, NOT the timeline) and " +
      "HALF-OPEN — a note is included when startBeat >= fromBeat AND < " +
      "toBeat, so adjacent windows never double-count a note sitting " +
      "exactly on the shared boundary. `pitchMin`/`pitchMax` are INCLUSIVE " +
      "on both ends. IMPORTANT: `totalNotes` in the response is always the " +
      "clip's UNFILTERED note count, while `returnedNotes` is how many " +
      "survived your filters (equal to notes.length) — if you filtered and " +
      "then call clip_set_notes with only the filtered array, you will " +
      "SILENTLY DESTROY every note you never saw, so always check " +
      "totalNotes === returnedNotes before doing a whole-array replace, or " +
      "merge your edits back into a full clip_get_notes {} read first — or, " +
      "better, if you are only changing FIELDS on notes that already exist " +
      "and not adding/removing any, skip this hazard entirely with " +
      "clip_patch_notes, which edits by id and cannot drop a note it wasn't " +
      "told about. Size " +
      "math: a note is roughly 90-120 bytes of JSON, so a 900-note drum " +
      "clip is ~80-110 KB — for big clips, filter by fromBeat/toBeat rather " +
      "than pulling the whole clip. This tool is STRICTLY READ-ONLY: no " +
      "undo entry, nothing dirtied, no engine call — unlike the old " +
      "clip_humanize-with-zero-jitter 'peek' trick, which still marks the " +
      "project dirty and still fires an engine refresh even though the " +
      "notes come back unchanged. Calling this is free.",
    inputSchema: {
      clipId: z.string().uuid().describe("Id of the MIDI clip to read, from project_snapshot or clip_add_midi."),
      fromBeat: z
        .number()
        .optional()
        .describe(
          "Only return notes whose startBeat is >= this (CLIP-RELATIVE beats, " +
            "not timeline beats). Half-open with toBeat: a note starting exactly " +
            "at fromBeat IS included. Omit for no lower bound."
        ),
      toBeat: z
        .number()
        .optional()
        .describe(
          "Only return notes whose startBeat is < this (CLIP-RELATIVE beats, " +
            "not timeline beats). Half-open: a note starting exactly at toBeat is " +
            "EXCLUDED (it belongs to the next window). Omit for no upper bound. " +
            "Must be >= fromBeat when both are given."
        ),
      pitchMin: z
        .number()
        .int()
        .min(0)
        .max(127)
        .optional()
        .describe("Only return notes with pitch >= this, 0-127 INCLUSIVE. Omit for no lower bound."),
      pitchMax: z
        .number()
        .int()
        .min(0)
        .max(127)
        .optional()
        .describe(
          "Only return notes with pitch <= this, 0-127 INCLUSIVE. Omit for no " +
            "upper bound. Must be >= pitchMin when both are given."
        ),
    },
  },
  async ({ clipId, fromBeat, toBeat, pitchMin, pitchMax }) =>
    toToolResult(() => bridge.send("clip.getNotes", { clipId, fromBeat, toBeat, pitchMin, pitchMax }))
);

registerTool(
  "clip_repeat_notes",
  {
    title: "Repeat a note pattern into the same clip",
    description:
      "Copy a clip-relative note window (or an explicit set of note ids) into the SAME clip, " +
      "`count` times, `periodBeats` apart — the write-surface answer to 'lay down one bar and " +
      "repeat it N times' without generating and sending every repeated note yourself. A " +
      "twelve-bar blues drum part is one bar (~13 notes) plus one clip_repeat_notes call " +
      "instead of 149 hand-authored notes. " +
      "`fromBeat`/`toBeat` are CLIP-RELATIVE beats (same frame as a note's startBeat, like " +
      "clip_get_notes) and HALF-OPEN: a note is selected when startBeat >= fromBeat AND < " +
      "toBeat. Omit both to select the whole clip. `noteIds` selects an explicit set of notes " +
      "instead, and is mutually exclusive with fromBeat/toBeat. `periodBeats` is an EXPLICIT " +
      "beat offset between copies — this tool is meter-blind BY DESIGN (it never guesses 'one " +
      "bar' across a meter change), so `meterChangesInSpan` in the response tells you when the " +
      "written span crosses a meter change; the copies are still exact beat translations either " +
      "way. `firstCopyAtBeat` (clip-relative) is where copy 1 starts; omit it to place copy 1 " +
      "immediately after the source window/selection, `periodBeats` later. `transposeSemitones` " +
      "shifts each copy's pitches — pass one number to apply it to every copy, or exactly " +
      "`count` numbers for one shift per copy. IMPORTANT: this is CHROMATIC transposition " +
      "(pitch + n), NOT diatonic and NOT key-aware — moving a blues riff up a fourth is a valid " +
      "parallel move, but transposing a diatonic melody this way will land in the wrong mode; " +
      "author the pitches yourself when you need harmonic correctness. `extendClip` (default " +
      "true) grows the clip when a copy lands past its end, exactly like clip_set_notes' " +
      "double-click-to-extend gesture — capped at the next clip on the track, which is never " +
      "trimmed or removed. " +
      "NO NOTES ARE RETURNED, ever — the whole point of this tool is to avoid paying for the " +
      "repeated notes twice (once to generate, once to receive back). Read the written notes " +
      "with clip_get_notes if you need their ids. The response also reports " +
      "`preExistingNotesInSpan` and `copiesOverlapEachOther`, since stacked notes are legal and " +
      "never deduped or trimmed, and `pitchesClamped` (a transposed pitch outside 0-127 is " +
      "clamped, not refused — check this to catch a silently-wrong interval). " +
      "This call COMPOUNDS on re-run: calling it twice produces twice the copies. If you " +
      "generated too many, undo (edit_undo) rather than calling it again to 'fix' the count — " +
      "the whole repeat is ONE undo step, so one edit_undo removes exactly the copies this call " +
      "added (and any clip-length extension it made), never folding into a note edit made just " +
      "before or after it.",
    inputSchema: {
      clipId: z.string().uuid().describe("Id of the MIDI clip to repeat notes within, from project_snapshot."),
      fromBeat: z
        .number()
        .optional()
        .describe(
          "Only select source notes whose startBeat is >= this (CLIP-RELATIVE beats). " +
            "Half-open with toBeat. Mutually exclusive with noteIds. Omit for no lower bound."
        ),
      toBeat: z
        .number()
        .optional()
        .describe(
          "Only select source notes whose startBeat is < this (CLIP-RELATIVE beats). " +
            "Half-open. Mutually exclusive with noteIds. Omit for no upper bound."
        ),
      noteIds: z
        .array(z.string().uuid())
        .optional()
        .describe(
          "An explicit set of note ids to repeat (from clip_get_notes), instead of a " +
            "fromBeat/toBeat window. Mutually exclusive with fromBeat/toBeat."
        ),
      periodBeats: z
        .number()
        .describe(
          "Beats between the start of each copy. Must be > 0. Explicit and meter-blind by " +
            "design — see the tool description for why."
        ),
      count: z
        .number()
        .int()
        .min(1)
        .max(512)
        .describe(
          "How many copies to make, 1-512. 512 is a judgment-call ceiling (not a measured " +
            "limit) so a typo like 100000 fails loudly instead of allocating."
        ),
      firstCopyAtBeat: z
        .number()
        .optional()
        .describe(
          "CLIP-RELATIVE start beat of copy 1. Omit to place it immediately after the source " +
            "window/selection, periodBeats later."
        ),
      transposeSemitones: z
        .array(z.number().int())
        .max(512)
        .optional()
        .describe(
          "Chromatic pitch shift per copy, in semitones. Pass ONE number to apply it to every " +
            "copy, or exactly `count` numbers for one shift per copy. Omit for no transpose. " +
            "NOT diatonic or key-aware — see the tool description."
        ),
      extendClip: z
        .boolean()
        .optional()
        .describe(
          "Whether a copy landing past the clip's current end grows the clip to cover it " +
            "(capped at the next clip on the track). Defaults to true."
        ),
    },
  },
  async ({ clipId, fromBeat, toBeat, noteIds, periodBeats, count, firstCopyAtBeat,
          transposeSemitones, extendClip }) =>
    toToolResult(() =>
      bridge.send("clip.repeatNotes", {
        clipId, fromBeat, toBeat, noteIds, periodBeats, count, firstCopyAtBeat,
        transposeSemitones, extendClip,
      })
    )
);

/**
 * One BY-ID field update for clip_patch_notes (m26-a / m27-n). Every field
 * but `id` is optional — an omitted field is left UNCHANGED, the entire
 * point of this tool. `.strict()` here (m30-c, "17 schemas not 2"):
 * `registerTool`'s wrapper only strictens the TOP level of its own
 * inputSchema, so a typo'd field INSIDE one element of `update` (e.g.
 * "velocty") would otherwise be silently stripped rather than rejected —
 * on a patch verb that means the field silently does not change while the
 * call still reports success, exactly the class of failure this tree keeps
 * paying for.
 */
const notePatchSchema = z
  .object({
    id: z
      .string()
      .uuid()
      .describe(
        "Id of an EXISTING note in this clip, from clip_get_notes. Must already exist — " +
          "clip_patch_notes can never create or remove a note."
      ),
    pitch: z
      .number()
      .int()
      .min(0)
      .max(127)
      .optional()
      .describe("New MIDI pitch number, 0-127 (60 = middle C). Omit to leave the pitch unchanged."),
    velocity: z
      .number()
      .int()
      .min(1)
      .max(127)
      .optional()
      .describe("New note-on velocity, 1-127. Omit to leave it unchanged."),
    startBeat: z
      .number()
      .min(0)
      .optional()
      .describe(
        "New start position in beats (quarter notes), RELATIVE TO THE CLIP'S START " +
          "(not the timeline). Omit to leave it unchanged."
      ),
    lengthBeats: z
      .number()
      .positive()
      .optional()
      .describe("New duration in beats. Must be > 0. Omit to leave it unchanged."),
  })
  .strict();

registerTool(
  "clip_patch_notes",
  {
    title: "Update specific notes in a MIDI clip by id",
    description:
      "Change pitch/velocity/startBeat/lengthBeats on SPECIFIC notes in a MIDI clip, addressed " +
      "by id, WITHOUT resubmitting the clip's other notes. This is the tool for 'raise the " +
      "velocity of these 48 notes' or 'shorten these 225 notes for legato' — before this tool, " +
      "either edit required reading and resending the clip's ENTIRE note array through " +
      "clip_set_notes even when only a handful of notes actually changed (the reports that " +
      "motivated this tool: a legato pass changing lengthBeats on 225 of a clip's notes, and a " +
      "velocity bump on 48 of a 907-note, ~80 KB clip). " +
      "NOT clip_set_notes: that replaces the clip's WHOLE note array (can add, remove, and " +
      "reorder notes — anything you don't include is GONE). clip_patch_notes can only ever " +
      "change fields on notes that ALREADY EXIST — there is no code path from calling it to a " +
      "note disappearing — and it leaves every note you don't name in `update` completely " +
      "untouched. Use clip_get_notes first to learn real note ids (or reuse ids you already " +
      "have from clip_add_midi/clip_set_notes). Reach for clip_set_notes instead when you're " +
      "adding/removing notes, or authoring/replacing a clip's content wholesale. " +
      "Each `update` entry needs `id` plus AT LEAST ONE of pitch/velocity/startBeat/lengthBeats " +
      "— an entry naming none of them is refused as an almost-certain mistake, not silently " +
      "accepted as a no-op. An id that isn't actually in this clip REFUSES THE WHOLE CALL and " +
      "names the offending id in the error; nothing is partially applied, and the SAME id " +
      "named twice in one call is refused the same way (which value should win is ambiguous, " +
      "so it's an error rather than a guess). " +
      "One call is ONE undo step (edit_undo reverts every note this call touched together), " +
      "and it never merges with a note edit made just before or after it — coalescing is " +
      "deliberately OFF for this tool, the clip_repeat_notes precedent. " +
      "The response is COUNTS ONLY (`updated`, `totalNotes`, `latentNotesPastClipEnd`) — never " +
      "a notes array, since you already know exactly which ids and fields you changed. Read " +
      "the result back with clip_get_notes if you need to see it. " +
      "This tool does NOT grow the clip: unlike clip_set_notes/clip_repeat_notes, there is no " +
      "auto-extend, so a patched startBeat/lengthBeats that lands past the clip's current end " +
      "stores fine but won't sound — `latentNotesPastClipEnd` in the response is your only " +
      "signal; use clip_set_notes or clip_fit_to_content if you need the clip itself to grow.",
    inputSchema: {
      clipId: z.string().uuid().describe("Id of the MIDI clip to edit, from project_snapshot or clip_get_notes."),
      update: z
        .array(notePatchSchema)
        .max(4096)
        .describe(
          "Notes to update, by id, up to 4096 entries. Each entry must include `id` and at " +
            "least one of pitch/velocity/startBeat/lengthBeats to change. May be empty (a no-op " +
            "— ok, zero updated, no undo entry)."
        ),
    },
  },
  async ({ clipId, update }) =>
    toToolResult(() => bridge.send("clip.patchNotes", { clipId, update }))
);

registerTool(
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

registerTool(
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
      "original clip). Returns `{first, second}`, the two resulting clips. " +
      "`returnNotes` (default true, UNCHANGED — deliberately NOT defaulted off like " +
      "clip_duplicate/clip_remove_many/clip_humanize/clip_move_many's family, m31-b): a " +
      "split TRUNCATES any note straddling the cut, so unlike a duplicate (verbatim copy) " +
      "or a humanize (same notes, nudged), the resulting `notes` are NEW information you " +
      "did not already have — you cannot predict exactly which note landed on which side " +
      "or how a straddling note got shortened without reading them back. `second` is also " +
      "a brand-new clip whose id you need immediately, the clip_add_midi precedent. Pass " +
      "`returnNotes: false` to drop both halves' `notes` arrays if you don't need them for " +
      "this call — `first`/`second`'s `id` (and every other field) always survive either " +
      "way; the response instead carries `notesOmitted: true` and `noteCount` on the half " +
      "that had notes. Nothing is lost: read either half's notes any time with clip_get_notes.",
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
      returnNotes: z
        .boolean()
        .optional()
        .describe(
          "Whether `first`/`second` echo their notes back. Defaults to true (unchanged " +
            "prior behavior) — a split truncates notes at the cut, so the result is new " +
            "information, unlike the pure-mutation clip tools that default this off. Pass " +
            "false to drop both halves' `notes` arrays; every id and other field is " +
            "unaffected either way."
        ),
    },
  },
  async ({ trackId, clipId, atBeat, returnNotes }) =>
    toToolResult(async () => {
      const result = await bridge.send("clip.split", { trackId, clipId, atBeat });
      return returnNotes === false ? stripNotesFromResult(result) : result;
    })
);

registerTool(
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

registerTool(
  "clip_fit_to_content",
  {
    title: "Fit a clip's length to its content",
    description:
      "Snap a clip's length to exactly match its content in ONE call — no length " +
      "math needed. A MIDI clip's trailing edge moves to the END OF ITS LAST NOTE " +
      "(clip-relative); an audio clip's to the end of its source recording (the " +
      "file's remaining duration from the clip's current playback offset, tempo- " +
      "and stretch-aware — never longer than the source). The clip's START never " +
      "moves. Prefer this over clip_trim when the goal is \"make the clip the size " +
      "of what's inside it\" (e.g. an AI-authored clip with an odd length); use " +
      "clip_trim to cut to an arbitrary window. An empty MIDI clip is a safe no-op. " +
      "Comp/take-group members are rejected readably. Returns the updated clip plus " +
      "a `changed` flag — false when the clip already fit its content exactly " +
      "(nothing was edited, so there is no undo step).",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track that owns the clip, from project_snapshot."),
      clipId: z.string().uuid().describe("Id of the clip to fit, from project_snapshot."),
    },
  },
  async ({ trackId, clipId }) =>
    toToolResult(() => bridge.send("clip.fitToContent", { trackId, clipId }))
);

registerTool(
  "clip_move",
  {
    title: "Move a clip to a new timeline position",
    description:
      "Slide a clip to a new timeline start beat WITHOUT changing its length or " +
      "content — same-track only in v0 (moving a clip onto a different track isn't " +
      "supported yet). Use this for rearranging a section without resizing it; use " +
      "clip_trim instead when you want to change what's audible at an edge. " +
      "OVERLAP POLICY: if the move lands the clip over an ordinary same-track clip, " +
      "the STATIONARY clip automatically yields the covered region (its edge is " +
      "trimmed, or it is removed if fully covered) so two clips never sound at once " +
      "with no crossfade — all inside the one undo step. To deliberately overlap " +
      "two audio clips with a smooth blend, use clip_crossfade instead. Repeated " +
      "calls while dragging the same clip coalesce into one undo step. Returns the " +
      "updated clip, plus additive `trimmed` and `removed` arrays listing the ids " +
      "of any stationary clips the overlap policy edited (empty on a clean move).",
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

registerTool(
  "clip_duplicate",
  {
    title: "Duplicate a clip",
    description:
      "Copy a clip, value-copying EVERYTHING it carries — audio media or MIDI " +
      "notes, gain, fades + curves, gain envelope, and stretch/pitch — under a " +
      "brand-new id. Use this to repeat a phrase, stash a variation to edit " +
      "separately, or seed a new section from an existing one, without re-building " +
      "it note by note. Omit `toStartBeat` to land the copy FLUSH right after the " +
      "source clip's own tail; omit `toTrackId` to duplicate onto the source's own " +
      "track. A cross-track duplicate is type-checked by content, same as any other " +
      "clip placement: a MIDI clip only lands on an instrument track, an audio clip " +
      "only on an audio track. OVERLAP POLICY: identical to clip_move's — a copy " +
      "dropped onto an occupied region TRIMS the ordinary resident clips it covers " +
      "(their edge is trimmed, or they're removed if fully covered) so two clips " +
      "never sound at once with no crossfade; use clip_crossfade instead to " +
      "deliberately blend two audio clips. A comp/take-group member source is " +
      "rejected — call take_flatten first, then duplicate the flattened clip. " +
      "NOTE IDS: the new clip gets a brand-new clip id, but for a MIDI clip its " +
      "individual notes keep their SOURCE note ids verbatim (not re-minted), so " +
      "the source clip and the duplicate end up with two different clips whose " +
      "notes share the same per-note ids. One " +
      "undo step. Returns the new clip's fields (unwrapped, the track_add/" +
      "clip_add_midi convention), plus additive `trimmed` and `removed` arrays " +
      "listing the ids of any stationary clips the overlap policy edited (empty on " +
      "a clean landing). " +
      "⚠️ NOTES ARE OMITTED BY DEFAULT (changed from earlier behavior, m31-b): a " +
      "duplicate is a pure mutation — the caller already knows the notes (they're " +
      "identical to the source, same per-note ids, per the NOTE IDS paragraph above), " +
      "so echoing them back a second time was pure cost with no new information. " +
      "Measured: duplicating a 149-note clip cost 24,702 chars just for the echo. The " +
      "response instead carries `notesOmitted: true` and `noteCount` (never mistakable " +
      "for a genuinely empty clip). Pass `returnNotes: true` to get the full array back " +
      "anyway, or read it anytime with clip_get_notes using the new clip's id.",
    inputSchema: {
      clipId: z.string().uuid().describe("Id of the clip to duplicate, from project_snapshot."),
      toStartBeat: z
        .number()
        .min(0)
        .optional()
        .describe(
          "New timeline start in beats (quarter notes) for the copy. Must be >= 0. Omit to " +
            "land the copy flush right after the source clip's own tail."
        ),
      toTrackId: z
        .string()
        .min(1)
        .optional()
        .describe(
          "Id of the track to land the copy on, from project_snapshot. Omit to duplicate onto " +
            "the source clip's own track. A MIDI source needs an instrument track; an audio " +
            "source needs an audio track — a mismatch errors readably."
        ),
      returnNotes: z
        .boolean()
        .optional()
        .describe(
          "Whether the response echoes the duplicated clip's notes back. Defaults to " +
            "FALSE (changed from earlier behavior, m31-b) since a duplicate's notes are " +
            "identical to the source's — pass true to get them back inline anyway, or " +
            "read them anytime with clip_get_notes. When omitted the response carries " +
            "`notesOmitted: true` plus `noteCount` instead of `notes`."
        ),
    },
  },
  async ({ clipId, toStartBeat, toTrackId, returnNotes }) =>
    toToolResult(async () => {
      const result = await bridge.send("clip.duplicate", { clipId, toStartBeat, toTrackId });
      return returnNotes === true ? result : stripNotesFromResult(result);
    })
);

registerTool(
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

registerTool(
  "clip_set_gain_envelope",
  {
    title: "Draw a clip's gain envelope",
    description:
      "Draw a per-clip GAIN ENVELOPE on an AUDIO clip — a curve of volume " +
      "breakpoints that rides the clip's level UP AND DOWN OVER TIME, stacked on " +
      "top of its fixed gain (clip_set_gain) and its fades (clip_set_fades). Use " +
      "this — not clip_set_gain, which sets ONE flat number — to swell a phrase " +
      "into a chorus, duck a word, or shape a build inside a single clip. Prefer a " +
      "track automation lane instead when the level moves belong to the whole track " +
      "and should follow it as you rearrange. Points are CLIP-RELATIVE beats (from " +
      "the clip's own start, not the timeline) paired with a gain in DECIBELS; the " +
      "curve interpolates in a straight line between adjacent points and holds flat " +
      "before the first and after the last. Beats must be sorted ascending with no " +
      "duplicates; each beat is clamped into 0..the clip's length and each gain to " +
      "-72..24 dB (0 = unity). Pass an EMPTY list (or omit points) to CLEAR the " +
      "envelope back to the plain gain-and-fades behavior. Repeated calls while " +
      "dragging a breakpoint coalesce into one undo step. Audio clips only — a MIDI " +
      "clip is rejected. Returns the updated clip.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track that owns the clip, from project_snapshot."),
      clipId: z.string().uuid().describe("Id of the AUDIO clip to shape, from project_snapshot."),
      points: z
        .array(
          z.object({
            beat: z
              .number()
              .min(0)
              .describe(
                "Breakpoint position in beats, RELATIVE TO THE CLIP'S START (not the " +
                  "timeline). Clamped into 0..the clip's length."
              ),
            gainDb: z
              .number()
              .describe("Gain at this breakpoint in decibels. Clamped to -72..24; 0 = unity."),
          })
            // `.strict()` (m30-c): a typo'd field (e.g. "gainDB") inside one
            // `points` element would otherwise be silently stripped instead
            // of rejected.
            .strict()
        )
        .optional()
        .describe(
          "Gain breakpoints, sorted by beat ascending with no duplicate beats. " +
            "Empty or omitted CLEARS the envelope."
        ),
    },
  },
  async ({ trackId, clipId, points }) =>
    toToolResult(() => bridge.send("clip.setGainEnvelope", { trackId, clipId, points: points ?? [] }))
);

registerTool(
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

registerTool(
  "clip_crossfade",
  {
    title: "Crossfade two adjacent/overlapping audio clips",
    description:
      "Blend the seam between two AUDIO clips on the same track so the earlier one " +
      "fades OUT exactly as the later one fades IN — the clean, click-free join. " +
      "This is the ONE way to legitimately overlap two same-track clips: it creates " +
      "the overlap with complementary EQUAL-POWER fades that sum to constant volume " +
      "(no dip, no doubling). The typical workflow: two clips sit side by side " +
      "(e.g. after clip_split, or two takes butted together) — call this with both " +
      "ids and a crossfade length in beats. The clips must be ADJACENT (the later " +
      "one starts exactly where the earlier one ends) OR already overlap by no more " +
      "than `lengthBeats`; if there is a gap, clip_move them together first. When " +
      "adjacent, the overlap is created by extending each clip into its surrounding " +
      "source audio — if a clip has no material to extend (e.g. its source file " +
      "ends right at the seam), the call fails naming that clip/side, so use a " +
      "shorter length. Pass the two ids in EITHER order (the earlier-starting clip " +
      "is chosen as the fade-out side). One undo step. Returns {left, right, " +
      "overlapBeats}.",
    inputSchema: {
      trackId: z.string().min(1).describe("Id of the track that owns both clips, from project_snapshot."),
      clipId: z.string().uuid().describe("Id of one of the two audio clips to crossfade."),
      otherClipId: z
        .string()
        .uuid()
        .describe("Id of the other audio clip — must be adjacent to or overlapping the first, on the same track."),
      lengthBeats: z
        .number()
        .positive()
        .describe(
          "Crossfade length in beats (quarter notes). Must be > 0. For adjacent clips " +
            "this is the overlap that gets created; for already-overlapping clips it is " +
            "the ceiling (the existing overlap is kept and faded)."
        ),
    },
  },
  async ({ trackId, clipId, otherClipId, lengthBeats }) =>
    toToolResult(() => bridge.send("clip.crossfade", { trackId, clipId, otherClipId, lengthBeats }))
);

registerTool(
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

registerTool(
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

registerTool(
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
      "same clip (e.g. scrubbing strength) fold into ONE undo step. Returns the updated clip. " +
      "⚠️ NOTES ARE OMITTED BY DEFAULT (changed from earlier behavior, m31-b): this is " +
      "shape-identical to clip_humanize (a seeded/parametric mutation of a note array you " +
      "already hold, ids and order preserved) and now behaves the same way. The response " +
      "instead carries `notesOmitted: true` and `noteCount`. Pass `returnNotes: true` to " +
      "get the quantized array back inline anyway, or read it anytime with clip_get_notes.",
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
      returnNotes: z
        .boolean()
        .optional()
        .describe(
          "Whether the response echoes the quantized notes back. Defaults to FALSE " +
            "(changed from earlier behavior, m31-b) — pass true to get the quantized array " +
            "back inline anyway, or read it anytime with clip_get_notes. When omitted the " +
            "response carries `notesOmitted: true` plus `noteCount` instead of `notes`."
        ),
    },
  },
  async ({ clipId, gridBeats, strength, swing, quantizeEnds, groove, returnNotes }) =>
    toToolResult(async () => {
      const result = await bridge.send("clip.quantize", {
        clipId,
        gridBeats,
        strength,
        swing,
        quantizeEnds,
        groove,
      });
      return returnNotes === true ? result : stripNotesFromResult(result);
    })
);

registerTool(
  "clip_humanize",
  {
    title: "Add human feel to a MIDI clip (seeded timing + velocity jitter, optional legato overlap)",
    description:
      "The inverse-spirited sibling of clip_quantize: instead of snapping a MIDI clip's " +
      "notes to the grid, nudge them slightly OFF it so they feel played rather than " +
      "programmed. Each note gets an INDEPENDENT random timing offset (up to ±`timingBeats` " +
      "beats) and an independent random velocity offset (up to ±`velocityRange`), applied " +
      "as ONE undoable step. Onsets are clamped to stay inside the clip and velocities to " +
      "1..127; note ids and array order are ALWAYS preserved, and so are note LENGTHS " +
      "UNLESS you pass `legatoOverlapBeats` > 0 — that is the one argument here that " +
      "rewrites lengths, and it is off by default. " +
      "LEGATO/GATE PASS (`legatoOverlapBeats` + `maxGapBeats`): every note followed within " +
      "`maxGapBeats` is lengthened to end `legatoOverlapBeats` PAST the following note's " +
      "start, so gaps close and joins overlap. A LARGER gap is a rest (for a wind part, a " +
      "breath) and is left exactly as authored; notes that already overlap are left alone " +
      "(the pass only ever extends, so running it twice with the same arguments changes " +
      "nothing the second time); the last note is never extended; nothing is extended past " +
      "the clip end; a note whose successor repeats its own PITCH abuts that successor " +
      "exactly instead of overlapping it, because MIDI note-off carries only a pitch and an " +
      "overlap there would cut the note that just started. " +
      "⚠️ WHAT OVERLAP ACTUALLY BUYS: this engine has NO legato-hold mode — every note-on " +
      "starts a brand-new voice with a fresh attack, on the built-in sampler and on a " +
      "hosted AUSampler alike. The overlap MASKS each new attack under the previous note's " +
      "decaying tail; it does NOT eliminate the retrigger and cannot produce true legato. " +
      "Use ~0.02-0.05 beats for a melodic wind/brass line. `maxGapBeats` on its own does " +
      "NOTHING: it is a ceiling on a pass that only runs when `legatoOverlapBeats` > 0. " +
      "The jitter is DETERMINISTIC and " +
      "SEEDED: pass a `seed` to get an exact, repeatable result, or omit it to draw a fresh " +
      "one. Either way the response includes `seedUsed` (the seed actually applied) alongside " +
      "the updated clip fields — feed that same value back as `seed` to reproduce this exact " +
      "take, or omit `seed` again to re-roll a different feel. MIDI CLIPS ONLY: an audio clip " +
      "is rejected. Returns the updated clip plus `seedUsed`. " +
      "NOT IDEMPOTENT — the jitter is added to each note's CURRENT position, not to a stored " +
      "quantized original, so calling this twice COMPOUNDS the feel (and repeated runs pile " +
      "onsets against the clip boundary, where they clamp). `seed` reproduces a result only " +
      "from the SAME starting state — same seed applied twice in a row does NOT give you the " +
      "same clip as applying it once. Nothing on the clip records that it was humanized, so " +
      "an agent picking up someone else's clip cannot tell: to re-roll a feel, edit_undo the " +
      "previous humanize FIRST, then re-apply. Prefer one pass with the right amount over " +
      "several nudges. " +
      "⚠️ NOTES ARE OMITTED BY DEFAULT (changed from earlier behavior, m31-b): humanize is " +
      "a pure mutation of an array you already hold (ids and order are preserved, so you " +
      "already know which note is which) — echoing the whole array back was pure cost. " +
      "Measured: humanizing one guitar clip cost 260,354 chars for the echo alone. The " +
      "response instead carries `notesOmitted: true` and `noteCount` alongside `seedUsed`. " +
      "Pass `returnNotes: true` to get the jittered array back inline anyway, or read it " +
      "anytime with clip_get_notes.",
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
      legatoOverlapBeats: z
        .number()
        .min(0)
        .max(0.25)
        .optional()
        .describe(
          "How far each note is stretched PAST the start of the note that follows it, in BEATS, " +
            "0..0.25 (default 0 = OFF, note lengths untouched). This is the only argument that " +
            "changes note LENGTHS. ~0.024-0.048 beats is 20-40 ms at 72 BPM, a good range for a " +
            "melodic wind/brass line. It masks each note's fresh attack under the previous note's " +
            "tail — it does NOT eliminate the retrigger (no legato-hold mode exists in this " +
            "engine), so bigger is not smoother: past ~0.06 beats it starts to read as two " +
            "players. Deterministic and RNG-free, so a seeded result is unchanged by it."
        ),
      maxGapBeats: z
        .number()
        .min(0)
        .max(4)
        .optional()
        .describe(
          "The largest gap the legato pass will close, in BEATS, 0..4 (default 0.125 — a " +
            "thirty-second note). A gap WIDER than this is treated as a rest — a breath in a " +
            "wind part — and is preserved exactly, which is what keeps the pass musical rather " +
            "than destructive. Raise it to close written rests too (1 = a quarter-note rest); " +
            "lower it at very slow tempos, where 0.125 beat is more milliseconds. Does NOTHING " +
            "on its own: it only bounds the pass that `legatoOverlapBeats` > 0 turns on."
        ),
      returnNotes: z
        .boolean()
        .optional()
        .describe(
          "Whether the response echoes the humanized notes back. Defaults to FALSE " +
            "(changed from earlier behavior, m31-b) since ids and order are unchanged so " +
            "you already know which note is which — pass true to get the jittered array " +
            "back inline anyway, or read it anytime with clip_get_notes. When omitted the " +
            "response carries `notesOmitted: true` plus `noteCount` instead of `notes`."
        ),
    },
  },
  async ({ clipId, timingBeats, velocityRange, seed, legatoOverlapBeats, maxGapBeats, returnNotes }) =>
    toToolResult(async () => {
      const result = await bridge.send("clip.humanize", {
        clipId,
        timingBeats,
        velocityRange,
        seed,
        legatoOverlapBeats,
        maxGapBeats,
      });
      return returnNotes === true ? result : stripNotesFromResult(result);
    })
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
  "clip_analyze_audio",
  {
    title: "Analyze an audio clip's key, tempo, and spectral balance",
    description:
      "THE FIRST MOVE after importing a full song, before composing or arranging " +
      "anything to match it: measure the imported audio clip's key, tempo, and " +
      "spectral balance instead of guessing. Read-only — analyzes the clip's CURRENT " +
      "SOURCE WINDOW (the file region the clip currently plays), content-cached by " +
      "(file, window), so a repeat call on the same clip is instant. Returns " +
      "`analysis.key` {tonic, mode, confidence 0..1, tonal, alternatives (up to 3)} " +
      "from a chroma + Krumhansl-Kessler correlation — honestly probabilistic: about " +
      "70% exact on real commercial mixes, about 90% within the top-3 alternatives, so " +
      "treat a modest confidence or a runner-up in `alternatives` as a real answer, not " +
      "noise. `tonal:false` means the material read as percussion-only or atonal — do " +
      "NOT trust `tonic`/`mode` when that's set, even though a ranked guess is still " +
      "returned. `analysis.tempo` {bpm, confidence, steady, beatOffsetSeconds, " +
      "alternates} folds the estimate into the practical 70-180 BPM range (a true 60 " +
      "BPM pulse reports bpm:120 with 60 listed in `alternates` — treat such a pair as " +
      "one tempo at two framings; half/double readings are included the same way). " +
      "`bpm` is `null` when there is no periodic evidence or the analyzed window is " +
      "under 6 seconds — that null IS the honest answer (nothing to lock a project " +
      "tempo to), not a failed call. `steady:false` means the pulse drifts (rubato, " +
      "free time, or a tempo change partway through), so no single fixed project tempo " +
      "will track the whole clip. `analysis.spectral` gives the 24-band (40 Hz-16 kHz) " +
      "balance plus a `centroidHz` brightness figure and a 6-band verbal `summary` " +
      "(sub/bass/lowMid/mid/highMid/air, all dB) for quick mix-matching. " +
      "`analysis.samplePeakDb`/`rmsDb`/`durationSeconds` round out the read (this is " +
      "sample peak and plain RMS, NOT LUFS — use render_measure_loudness for gated " +
      "loudness). Every measurement is in the SOURCE file's own domain, from BEFORE " +
      "this clip's stretch/pitch; when the clip is time-stretched or pitch-shifted a " +
      "`playback` block is added with the derived on-timeline `bpm`/`keyTonic`/" +
      "`keyMode` (omitted entirely for an untouched clip) — read `playback` for what " +
      "the clip actually sounds like now on the timeline, `analysis` for what the " +
      "recording itself contains. AUDIO CLIPS ONLY — a MIDI clip is rejected readably " +
      "(read its notes directly for key/timing instead).",
    inputSchema: {
      clipId: z.string().uuid().describe("Id of the AUDIO clip to analyze, from project_snapshot."),
    },
  },
  async ({ clipId }) => toToolResult(() => bridge.send("clip.analyzeAudio", { clipId }))
);

registerTool(
  "clip_quantize_audio",
  {
    title: "Quantize OR CHOP an audio clip on the timeline (slice + nudge)",
    description:
      "QUANTIZE or CHOP an AUDIO clip on the TIMELINE. **With `strength: 0` this is a " +
      "pure CHOP** — the clip is cut at its transients (or, with `divisions`, into N " +
      "equal parts) into slices that stay EXACTLY where they were, in ONE undo step, " +
      "with clean sample-exact joins and no crossfades. That is the tool to reach for " +
      "when you want to chop a loop, break, or sample into separate clips you can " +
      "rearrange, delete, or reverse. (To chop into SAMPLER PADS you can play from a " +
      "keyboard instead, use clip_slice_to_sampler.) With `strength` above 0 it also " +
      "tightens the rhythm to a GRID: the clip is detected for onsets (same engine as " +
      "clip_detect_transients), cut into slices at each onset, and every slice is moved " +
      "so its onset lands on the grid; the gaps at the joins are filled by the source " +
      "continuing (NO time-stretch in v0 — slices play at natural speed) with short " +
      "equal-power CROSSFADES so the joins are seamless. Destructive, but ONE undo step " +
      "reverts it. `gridBeats` is the grid in beats (1 = 1/4 note, 0.5 = 1/8, 0.25 = " +
      "1/16) and may be OMITTED when `strength` is 0, where nothing is nudged and a " +
      "pure chop needs no grid. `strength` (0..1, default 1) is how far each slice moves " +
      "toward its slot (1 = snap fully, 0.5 = halfway, 0 = chop only). `swing` (50..75, " +
      "default 50) delays the offbeat slots (MPC groove). `sensitivity` (0..1, default " +
      "0.5) tunes onset detection (low = strong hits only, high = more onsets). " +
      "`divisions` (2..128) cuts into that many EQUAL parts instead of at transients — " +
      "the fallback for material whose transients are wrong or absent (drones, ambient " +
      "beds, already-quantized loops); it does not run the detector, so `sensitivity` " +
      "alongside it is REJECTED rather than ignored. `crossfadeMs` (0..50, default 10) " +
      "is the join crossfade width in milliseconds. AUDIO CLIPS ONLY (a MIDI clip is " +
      "rejected — use clip_quantize); a time-STRETCHED clip is rejected (un-stretch or " +
      "bounce it first — per-slice stretch is a future feature); a take-comp member is " +
      "rejected (change the comp or take_flatten first); a clip with fewer than 2 " +
      "detectable onsets is rejected (nothing to quantize — raise sensitivity, pass " +
      "`divisions` instead, or pick a more percussive clip). Slices never reorder. " +
      "Returns {clips} — the head + slice clips that replaced the original.",
    inputSchema: {
      trackId: z.string().uuid().describe("Id of the track holding the clip, from project_snapshot."),
      clipId: z.string().uuid().describe("Id of the AUDIO clip to quantize, from project_snapshot."),
      gridBeats: z
        .number()
        .positive()
        .optional()
        .describe(
          "Grid resolution in beats: 1 = 1/4 note, 0.5 = 1/8, 0.25 = 1/16, 0.125 = 1/32. " +
            "Must be > 0. REQUIRED unless strength is 0 — at strength 0 nothing is nudged, " +
            "so a pure chop needs no grid and this may be omitted."
        ),
      divisions: z
        .number()
        .int()
        .min(2)
        .max(128)
        .optional()
        .describe(
          "Cut the clip into this many EQUAL parts instead of at its transients, 2..128. " +
            "The fallback when transients are wrong or absent (drones, pads, ambient beds, " +
            "already-quantized loops): divisions: 8 on a one-bar loop gives eight 1/8-note " +
            "slices. No detector runs, so `sensitivity` sent alongside is rejected. " +
            "Orthogonal to gridBeats/strength/swing/groove — divisions picks where the clip " +
            "is CUT, those pick where each slice MOVES TO. Parts thinner than the minimum " +
            "slice width (50 ms) are refused with the arithmetic, never silently thinned."
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
  async ({
    trackId,
    clipId,
    gridBeats,
    divisions,
    strength,
    swing,
    sensitivity,
    crossfadeMs,
    groove,
  }) =>
    toToolResult(() =>
      bridge.send("clip.quantizeAudio", {
        trackId,
        clipId,
        gridBeats,
        divisions,
        strength,
        swing,
        sensitivity,
        crossfadeMs,
        groove,
      })
    )
);

registerTool(
  "clip_slice_to_sampler",
  {
    title: "Chop an audio clip into sampler pads (the sample flip)",
    description:
      "THE SAMPLE FLIP: turn a record into an instrument. Chops an AUDIO clip at its " +
      "TRANSIENTS (or at equal divisions, or on the musical grid) into SAMPLER PADS -- " +
      "one zone per slice, all pointing at the SAME source file, one pad per MIDI note " +
      "from `baseNote` up -- and, by default, writes a MIDI clip that REPLAYS THE " +
      "ORIGINAL GROOVE. That is the whole point of the workflow: you start from a " +
      "reconstruction that plays back identically to the record, then reorder, mute, " +
      "retune and rearrange the pads to make something new. This is the MPC / SP-1200 / " +
      "Recycle chop, and it is how a break becomes a beat. " +
      "The SOURCE CLIP IS NOT TOUCHED -- it is not sliced, moved or replaced. (To cut " +
      "the clip itself into slices ON THE TIMELINE instead, use clip_quantize_audio with " +
      "strength 0.) " +
      "`targetTrackId` picks an existing INSTRUMENT track; omit it and a new one named " +
      "\"<clip> chops\" is created and returned as `createdTrackId`. Chopping onto a " +
      "track that already has zones REPLACES them (a zones array is wholesale) and says " +
      "so in `warnings`. " +
      "`mode`: \"transients\" (default -- detected onsets, tuned by `sensitivity`), " +
      "\"divisions\" (N equal parts, needs `divisions` 2..128), or \"grid\" (musical " +
      "grid lines, needs `gridBeats`). Parameters that do not belong to the chosen mode " +
      "are REJECTED by name rather than silently ignored. " +
      "`includeHead` (default false) keeps the audio BEFORE the first slice point as pad " +
      "1 -- off by default because that material is usually pre-roll, but `headSeconds` " +
      "is always reported and a large discarded head is warned about, so a missed " +
      "downbeat can never vanish quietly. " +
      "Each boundary is SNAPPED once (within +/-`snapWindowMs`, default 3) to the " +
      "quietest nearby frame and shared by both adjacent pads, so a pad played on its own " +
      "does not click; every pad also gets a 0 ms attack (keeps the transient) and a 10 " +
      "ms release (the real fix for the click at the END of a slice). On a stereo file " +
      "there is often no simultaneous zero crossing, so each slice reports " +
      "`residualAmplitude` -- how quiet the cut actually is -- rather than implying a " +
      "clean one. " +
      "Reconstruction notes are VELOCITY 127, not the detector's strength: the sampler's " +
      "amp law is velocity/127 x zone gain and the slice already carries its own recorded " +
      "level, so a ghost note fired at velocity 13 would land about 20 dB below itself. " +
      "127/127 is exactly 1.0 -- a level-faithful replay -- while velocity stays live for " +
      "any NEW pattern you write. Set `velocityFromStrength` to opt into the detector's " +
      "dynamics (deliberately quieter than the source); `strength` is in the response " +
      "either way. " +
      "REFUSALS, all of which change nothing: a MIDI clip; a time-STRETCHED or " +
      "PITCH-SHIFTED clip (pads read RAW source frames, so the reconstruction would not " +
      "match what you hear -- un-stretch, clear the pitch, or bounce first); mode " +
      "\"grid\" on a clip spanning a tempo change (\"transients\" and \"divisions\" are " +
      "fine there); a non-instrument `targetTrackId`; no usable boundary; and -- " +
      "importantly -- MORE PADS THAN `maxSlices`, or a pad past MIDI note 127. Those two " +
      "REJECT rather than truncate, because a chop quietly missing its last bar still " +
      "looks like a successful chop. " +
      "AFTERWARDS: tweak ONE pad without resending the rest with " +
      "instrument_set_sampler_zones, the merge-by-id tool (widen a pad's maxPitch for " +
      "chromatic \"16 Levels\" play, tune it with tuneCents, play it backwards with " +
      "reverse, or give the hats a chokeGroup). Do NOT try to reach that merge through " +
      "track_set_instrument: `sampler.zonePatches` is a RAW-WIRE field that " +
      "instrument_set_sampler_zones wraps for you, and this tool's own schema REJECTS the " +
      "key. Remember a `zones` array sent to track_set_instrument replaces the whole pad " +
      "map wholesale and re-mints every id. " +
      "Set the sampler to mono voice mode (instrument_set_sampler_param) for the classic " +
      "chopped-soul global choke, or per-pad chokeGroup for independent groups. " +
      "Everything lands in ONE undo step. Returns {trackId, createdTrackId?, midiClipId?, " +
      "sampleRate, frameCount, sliceCount, headSeconds, slices: [{index, pitch, " +
      "startFrame, endFrame?, sourceSeconds, beat, strength?, snapOffsetFrames?, " +
      "residualAmplitude?}], warnings} -- `sampleRate`/`frameCount` are the SOURCE FILE's " +
      "own, and every frame number is in those units.",
    inputSchema: {
      clipId: z
        .string()
        .uuid()
        .describe(
          "Id of the AUDIO clip to chop, from project_snapshot. The clip's CURRENT " +
            "SOURCE WINDOW is the chop region -- trim the clip to the passage you want first."
        ),
      targetTrackId: z
        .string()
        .uuid()
        .optional()
        .describe(
          "Existing INSTRUMENT track to receive the pads. Omit to create a new one " +
            "(returned as `createdTrackId`; one undo removes it, its pads and the MIDI clip together)."
        ),
      mode: z
        .enum(["transients", "divisions", "grid"])
        .optional()
        .describe(
          "Where the slice points come from (default \"transients\"). \"divisions\" needs " +
            "`divisions`; \"grid\" needs `gridBeats`. Parameters belonging to another mode are rejected."
        ),
      sensitivity: z
        .number()
        .min(0)
        .max(1)
        .optional()
        .describe(
          "Onset-detection sensitivity 0..1 (default 0.5), mode \"transients\" ONLY. " +
            "Lower = strong hits only; higher = more (and weaker) slice points."
        ),
      divisions: z
        .number()
        .int()
        .min(2)
        .max(128)
        .optional()
        .describe(
          "Number of EQUAL parts to cut the clip window into, 2..128. Required by (and " +
            "only valid in) mode \"divisions\" -- the fallback when transients are absent " +
            "or wrong (drones, pads, already-quantized material)."
        ),
      gridBeats: z
        .number()
        .positive()
        .optional()
        .describe(
          "Grid resolution in beats (1 = 1/4 note, 0.5 = 1/8, 0.25 = 1/16). Required by " +
            "(and only valid in) mode \"grid\"."
        ),
      minSliceSeconds: z
        .number()
        .min(0.001)
        .max(10)
        .optional()
        .describe(
          "Minimum pad width in seconds (default 0.05). Slice points closer together " +
            "than this merge -- raise it to get fewer, longer pads from busy material."
        ),
      maxSlices: z
        .number()
        .int()
        .min(1)
        .max(96)
        .optional()
        .describe(
          "Refusal ceiling on the number of pads (default 32, hard cap 96). Exceeding it " +
            "REJECTS the whole chop and changes nothing -- pads are never silently dropped."
        ),
      includeHead: z
        .boolean()
        .optional()
        .describe(
          "Keep the audio BEFORE the first slice point as pad 1 (default false). Turn it " +
            "on when `headSeconds` shows the detector missed the downbeat."
        ),
      baseNote: z
        .number()
        .int()
        .min(0)
        .max(127)
        .optional()
        .describe(
          "MIDI note of pad 1 (default 36 = C1, the MPC pad-1 note). Pad i sits at " +
            "baseNote + i; running past 127 is rejected."
        ),
      snapWindowMs: z
        .number()
        .min(0)
        .max(20)
        .optional()
        .describe(
          "Half-width of the boundary snap search in milliseconds (default 3; 0 disables " +
            "snapping). Automatically limited to half of minSliceSeconds so slices cannot reorder."
        ),
      generateMIDI: z
        .boolean()
        .optional()
        .describe(
          "Write the reconstruction MIDI clip that replays the original groove (default " +
            "true). Set false to build only the pads."
        ),
      atBeat: z
        .number()
        .min(0)
        .optional()
        .describe(
          "Where the reconstruction clip lands (default: the source clip's own start, so " +
            "it lines up for A/B). The groove moves intact; it is not re-timed."
        ),
      velocityFromStrength: z
        .boolean()
        .optional()
        .describe(
          "Map detector strength to note velocity instead of using 127 (default false), " +
            "mode \"transients\" ONLY. Deliberately QUIETER than the source -- the slice " +
            "already carries its own recorded level."
        ),
    },
  },
  async ({
    clipId,
    targetTrackId,
    mode,
    sensitivity,
    divisions,
    gridBeats,
    minSliceSeconds,
    maxSlices,
    includeHead,
    baseNote,
    snapWindowMs,
    generateMIDI,
    atBeat,
    velocityFromStrength,
  }) =>
    toToolResult(() =>
      bridge.send("clip.sliceToSampler", {
        clipId,
        targetTrackId,
        mode,
        sensitivity,
        divisions,
        gridBeats,
        minSliceSeconds,
        maxSlices,
        includeHead,
        baseNote,
        snapWindowMs,
        generateMIDI,
        atBeat,
        velocityFromStrength,
      })
    )
);

registerTool(
  "clip_detect_pitch",
  {
    title: "Detect the pitch of an audio clip, frame by frame",
    description:
      "Analyze an AUDIO clip's current source window for PITCH, frame by frame (~62.5 " +
      "frames/second) -- fundamental frequency, confidence, level, and (for a silent or " +
      "unvoiced frame) WHY no pitch was named. This is the wiring for the app's pitch " +
      "detector (SwiftF0, run on-device via ONNX Runtime) -- the first tool that lets you " +
      "hear, in numbers, what note someone actually sang. Feeds Kiffness-style workflows " +
      "(chop a vocal phrase into fragments with clip_detect_transients + clip_split, then " +
      "learn each fragment's pitch here before pitch-shifting it with clip_set_stretch) " +
      "and any 'is this take in tune' question. Read-only: nothing is edited, no undo entry, " +
      "and nothing is cached -- a repeat call re-runs the detector. AUDIO CLIPS ONLY -- a " +
      "MIDI clip is rejected (its notes already have a definite pitch). Returns " +
      "`{pitch: {frames, frameCount, voicedFrameCount, voicedFraction, frameRateHz, " +
      "analysisSampleRateHz, sourceSampleRateHz, windowStartSeconds, windowDurationSeconds, " +
      "confidenceThreshold, silenceFloorDbfs, minFrequencyHz, maxFrequencyHz}, " +
      "clipWindowDurationSeconds, stretchRatio, pitchShiftSemitones}`. Each entry in " +
      "`frames` is `{timeSeconds, frequencyHz?, confidence, levelDbfs?, absence?}` -- " +
      "`timeSeconds` is a SOURCE-FILE-absolute second (the SAME numbers clip_detect_transients' " +
      "`sourceSeconds` and clip_analyze_audio's `windowStartSeconds` use, so you can line " +
      "pitch frames up against transient markers with no arithmetic). HONEST ABSENCE: an " +
      "unvoiced frame OMITS `frequencyHz` ENTIRELY (never 0, never a fabricated value) and " +
      "instead carries `absence`, one of `belowConfidence` (the model wasn't sure enough), " +
      "`belowLevel` (too quiet to trust -- SwiftF0 is confidence-blind to level, so this " +
      "catches near-silence confidence alone would miss), or `outOfRange` (a real pitch " +
      "outside `[minFrequencyHz, maxFrequencyHz]`). Frames are never dropped, so the array " +
      "is a uniform time grid you can read holes out of directly -- 'the singer stopped " +
      "here' and 'this frame is unreliable' are DIFFERENT reasons and stay distinguishable. " +
      "`voicedFraction` (0..1) is a quick 'how much of this actually has a pitch' summary " +
      "before you look at individual frames. `confidenceThreshold` (0..1, default 0.9) and " +
      "`silenceFloorDbfs` (default -75) are the two tuning knobs that decide voicing -- " +
      "`silenceFloorDbfs` in particular is UNTUNED against real vocal recordings (only " +
      "synthetic fixtures so far), so if real-take results look wrong, retune it here rather " +
      "than assuming the detector is broken. `fromSeconds`/`durationSeconds` narrow the " +
      "analyzed range (both SOURCE-FILE-absolute, like clip_analyze_audio's window); omit " +
      "both to analyze the clip's WHOLE current window -- for a multi-minute clip that can " +
      "be a large response (roughly 60 KB per 10 seconds of audio), so pass an explicit " +
      "range for a long clip if you only need part of it. `stretchRatio`/`pitchShiftSemitones` " +
      "echo the clip's current state (results are measured on the SOURCE audio, before " +
      "either is applied) so you can derive the sounding pitch yourself " +
      "(`frequencyHz * 2^(pitchShiftSemitones/12)`) if the clip is pitch-shifted.",
    inputSchema: {
      clipId: z.string().uuid().describe("Id of the AUDIO clip to analyze, from project_snapshot."),
      fromSeconds: z
        .number()
        .min(0)
        .optional()
        .describe(
          "Where to start, in SOURCE-FILE-absolute seconds (the clip_detect_transients/" +
            "clip_analyze_audio domain) -- must fall inside the clip's current window. " +
            "Omit to start at the clip's own window start."
        ),
      durationSeconds: z
        .number()
        .gt(0)
        .optional()
        .describe(
          "How many seconds to analyze from fromSeconds. Must be > 0 when given. Omit for " +
            "the rest of the clip's current window; a value that would run past the window " +
            "end is clamped (never rejected) and the response's `pitch.windowDurationSeconds` " +
            "reports what was actually analyzed."
        ),
      confidenceThreshold: z
        .number()
        .min(0)
        .max(1)
        .optional()
        .describe(
          "Voicing confidence gate, 0..1 (default 0.9, SwiftF0's own documented default). " +
            "A frame under this reads as unvoiced with absence:'belowConfidence'."
        ),
      silenceFloorDbfs: z
        .number()
        .optional()
        .describe(
          "RMS level gate in dBFS (default -75). A frame quieter than this reads as unvoiced " +
            "with absence:'belowLevel', regardless of confidence -- needed because the " +
            "detector can report high confidence on near-silence. UNTUNED against real vocal " +
            "recordings; adjust this while listening if real-take results look wrong."
        ),
    },
  },
  async ({ clipId, fromSeconds, durationSeconds, confidenceThreshold, silenceFloorDbfs }) =>
    toToolResult(() =>
      bridge.send("clip.detectPitch", {
        clipId,
        fromSeconds,
        durationSeconds,
        confidenceThreshold,
        silenceFloorDbfs,
      })
    )
);

registerTool(
  "clip_delete_time_range",
  {
    title: "Delete a time range from a MIDI clip (excise + close the gap)",
    description:
      "Cut `[startBeat, startBeat + lengthBeats)` OUT of a MIDI clip and close the " +
      "gap — the \"remove a bar/phrase and ripple everything after it left\" move. " +
      "`startBeat`/`lengthBeats` are CLIP-LOCAL beats, the SAME space as " +
      "clip_set_notes's note `startBeat` (relative to the clip's own start, not " +
      "the timeline). A note whose onset falls INSIDE the deleted range is REMOVED " +
      "entirely, however far it extends; a note crossing IN from before the range " +
      "keeps its outside part — its start is unchanged and only the overlapping " +
      "portion inside the cut is spliced out of its length; a note at or after the " +
      "range is shifted left by `lengthBeats` to close the gap, length unchanged. " +
      "The clip's own length shrinks by the excised amount (floored at one beat, or " +
      "at the furthest surviving note's end, whichever is longer — a clip never " +
      "strands a note past its own end). One call = one undo step (edit_undo " +
      "restores the exact prior notes and length). MIDI CLIPS ONLY: an audio clip " +
      "is rejected; a take-comp member clip is rejected (change the comp with " +
      "take_set_comp/take_select, or take_flatten first — the clip_quantize " +
      "precedent). Errors readably if `startBeat` falls outside [0, clip length) or " +
      "`lengthBeats` is not positive. Returns the updated clip.",
    inputSchema: {
      clipId: z.string().uuid().describe("Id of the MIDI clip to edit, from project_snapshot."),
      startBeat: z
        .number()
        .min(0)
        .describe(
          "CLIP-LOCAL start of the range to delete, in beats (quarter notes), relative to " +
            "the clip's own start (not the timeline). Must fall inside [0, clip length)."
        ),
      lengthBeats: z
        .number()
        .positive()
        .describe(
          "Length of the range to delete, in beats. Must be > 0. A range extending past the " +
            "clip's end is truncated at the clip's end (the clip can't shrink past what exists)."
        ),
    },
  },
  async ({ clipId, startBeat, lengthBeats }) =>
    toToolResult(() => bridge.send("clip.deleteTimeRange", { clipId, startBeat, lengthBeats }))
);

registerTool(
  "clip_insert_time_range",
  {
    title: "Insert silence into a MIDI clip (open a gap, shift later notes right)",
    description:
      "Insert `lengthBeats` of SILENCE at clip-local `atBeat` in a MIDI clip, " +
      "pushing later material right — the \"add a bar/rest here\" move, and the " +
      "inverse of clip_delete_time_range. `atBeat`/`lengthBeats` are CLIP-LOCAL " +
      "beats, the SAME space as clip_set_notes's note `startBeat` (relative to the " +
      "clip's own start, not the timeline). A note starting AT OR AFTER `atBeat` is " +
      "shifted right by `lengthBeats`, length unchanged; a note starting BEFORE " +
      "`atBeat` (crossing the insert point, still sounding) keeps BOTH its start " +
      "and its length exactly as-is — the new silence lands after its onset and it " +
      "simply sustains through the gap; no note is ever split. The clip's own " +
      "length grows by `lengthBeats`. `atBeat` may equal the clip's current length " +
      "to append silence at the tail. One call = one undo step (edit_undo restores " +
      "the exact prior notes and length). MIDI CLIPS ONLY: an audio clip is " +
      "rejected; a take-comp member clip is rejected (change the comp with " +
      "take_set_comp/take_select, or take_flatten first — the clip_quantize " +
      "precedent). Errors readably if `atBeat` falls outside [0, clip length] or " +
      "`lengthBeats` is not positive. Returns the updated clip.",
    inputSchema: {
      clipId: z.string().uuid().describe("Id of the MIDI clip to edit, from project_snapshot."),
      atBeat: z
        .number()
        .min(0)
        .describe(
          "CLIP-LOCAL position to insert silence at, in beats (quarter notes), relative to " +
            "the clip's own start (not the timeline). Must fall inside [0, clip length] — " +
            "equal to the clip's length appends silence at the tail."
        ),
      lengthBeats: z
        .number()
        .positive()
        .describe("Length of silence to insert, in beats. Must be > 0. The clip grows by exactly this amount."),
    },
  },
  async ({ clipId, atBeat, lengthBeats }) =>
    toToolResult(() => bridge.send("clip.insertTimeRange", { clipId, atBeat, lengthBeats }))
);

/**
 * Shared shape for a single point in a MIDI clip's controller lane, used by
 * clip_set_controller_lane. Identity-free (no id, no curve) and STEPWISE — a
 * value holds until the next point; a ramp is a dense run of points.
 */
const controllerPointSchema = z.object({
  beat: z
    .number()
    .min(0)
    .describe(
      "Point position in beats, RELATIVE TO THE CLIP'S START (not the timeline). Must " +
        "be >= 0."
    ),
  value: z
    .number()
    .int()
    .min(0)
    .max(16383)
    .describe(
      "Raw MIDI value at this point. 0-16383 for a pitchBend lane (8192 = center, no " +
        "bend); 0-127 for cc / channelPressure lanes — a value outside the OWNING lane's " +
        "domain errors readably, naming the exact range."
    ),
})
  // `.strict()` (m30-c): closes the same per-element hole for
  // clip_set_controller_lane's `points` array — a typo'd field (e.g.
  // "vlaue") would otherwise be silently stripped instead of rejected.
  .strict();

registerTool(
  "clip_set_controller_lane",
  {
    title: "Write a MIDI clip's controller lane (mod wheel, sustain, pitch bend, ...)",
    description:
      "Create or WHOLESALE-REPLACE one controller lane on a MIDI clip — mod wheel, " +
      "sustain pedal, pitch bend, expression, channel pressure, or any other numbered " +
      "MIDI CC — the performance data that rides ALONGSIDE a clip's notes " +
      "(clip_set_notes), not instead of them. Points are STEPWISE: a value HOLDS until " +
      "the next point, so two points make a flat STEP, not a ramp — draw a smooth ramp " +
      "as a dense run of points (exactly what a live recording produces). `points` " +
      "REPLACES the lane's entire point list wholesale — there is no add/remove-single-" +
      "point tool: read the clip's current lanes from project_snapshot's " +
      "`controllerLanes` array (there each lane is `{type: {type, controller?}, " +
      "points}` — NOTE the NESTED `type` object on read-back, unlike the FLAT " +
      "`type`/`controller` params this tool takes as input), modify the array yourself, " +
      "then resubmit the whole thing here. Values are RAW MIDI: 0-16383 for a " +
      "`pitchBend` lane (8192 = the center/no-bend position; built-in instruments apply " +
      "it as +/-2 semitones), 0-127 for `cc`/`channelPressure` lanes (CC 1 = mod wheel, " +
      "CC 64 = sustain pedal — a value >= 64 counts as pedal-down). CAUTION, THE " +
      "REST VALUE IS NOT ALWAYS 0: a controller with NO lane sits at its MIDI neutral, " +
      "and for three of them that is FULL or CENTRE, not off — CC 11 (expression) rests " +
      "at 127, CC 7 (channel volume) at 100, CC 10 (pan) at 64; everything else rests " +
      "at 0. So a CC 11 lane drawn at ordinary-looking values (say 106 down to 42) is a " +
      "broad ATTENUATION of the track relative to having no lane at all, not a gentle " +
      "shaping — that mistake cost a finished mix 1.25 LU. Write CC 11 near 127 for " +
      "\"full\", and use lower values only where you actually want the track quieter. " +
      "WHAT ACTUALLY " +
      "SOUNDS depends on the track's instrument, and this tool now TELLS you: a lane " +
      "the instrument cannot consume still succeeds and is still stored, but the " +
      "response carries a `warnings` array naming the controller and why it will be " +
      "silent — read it. The built-in SAMPLER honors pitch bend, CC 64 (sustain) and, " +
      "for continuous breath/air expression, CC 11 (expression, unconditional), plus " +
      "CC 1 (mod wheel) and CC 2 (breath) once `sampler.expressionModDepth` is set " +
      "above 0 on the instrument — those two are gated because their neutral value is " +
      "0, so routing them unconditionally would silence a clip until its lane's first " +
      "point. The built-in POLY SYNTH honors pitch bend and CC 64 only. Hosted Audio " +
      "Unit and sound-bank instruments receive every CC as raw MIDI. Note that CC 11 " +
      "on the sampler scales LOUDNESS; for continuous BRIGHTNESS set " +
      "`sampler.expressionFilterDepth` (and optionally `expressionFilterCC`), which " +
      "sweeps a per-voice low-pass (that CC then counts as honored too) — that is " +
      "what makes a long held sax or string note " +
      "read as a player leaning into it rather than a flat sustain. Controller values " +
      "CHASE at play and at seek: the latest value " +
      "at or before the playhead stays in effect, so a pedal held or a bend applied " +
      "earlier in the clip is still sounding after a jump — you don't need to re-state a " +
      "value at every seek target. clip_quantize/clip_humanize move only NOTES, never " +
      "these lanes. Per-note (poly) aftertouch is not supported yet — only channel-wide " +
      "values. A clip may hold at most 16 controller lanes (one per type/CC number) and " +
      "each lane at most 16384 points. MIDI clips only — an audio clip is rejected " +
      "readably. Repeated calls to the SAME lane (e.g. while drawing) coalesce into one " +
      "undo step. Returns the updated clip (the stored lane echoes back in its " +
      "`controllerLanes`).",
    inputSchema: {
      clipId: z.string().uuid().describe("Id of the MIDI clip to edit, from project_snapshot."),
      type: z
        .enum(["cc", "pitchBend", "channelPressure"])
        .describe(
          "Which controller stream this lane carries: `cc` (a numbered Control Change " +
            "— REQUIRES `controller`), `pitchBend` (0-16383, center 8192), or " +
            "`channelPressure` (mono/channel aftertouch, 0-127 — per-note aftertouch " +
            "isn't supported yet)."
        ),
      controller: z
        .number()
        .int()
        .min(0)
        .max(127)
        .optional()
        .describe(
          "The CC number, 0-127 — REQUIRED when `type` is \"cc\" (1 = mod wheel, " +
            "7 = channel volume, 10 = pan, 11 = expression, 64 = sustain pedal). Ignored " +
            "(omit it) for `pitchBend` / `channelPressure`."
        ),
      points: z
        .array(controllerPointSchema)
        .min(1)
        .max(16384)
        .describe(
          "The lane's COMPLETE new point list, replacing any existing lane of this type " +
            "wholesale. Must be non-empty — an empty lane isn't a valid state; call " +
            "clip_remove_controller_lane to delete a lane instead. Up to 16384 points (a " +
            "thinned ~200Hz capture of an ~80s continuous gesture still fits)."
        ),
    },
  },
  async ({ clipId, type, controller, points }) =>
    toToolResult(() => bridge.send("clip.setControllerLane", { clipId, type, controller, points }))
);

registerTool(
  "clip_remove_controller_lane",
  {
    title: "Remove a MIDI clip's controller lane",
    description:
      "Remove one controller lane (mod wheel, sustain, pitch bend, channel pressure, or " +
      "any other numbered CC) from a MIDI clip, identified by `type` (+ `controller` " +
      "for `cc`) — the counterpart to clip_set_controller_lane. Removing a lane the clip " +
      "does NOT have errors readably, LISTING the clip's existing lanes so you can " +
      "correct the type/controller. MIDI clips only — an audio clip is rejected " +
      "readably. One call = one undo step. Returns the updated clip: the removed lane is " +
      "simply absent from its `controllerLanes` array, which itself disappears from the " +
      "response once the clip has no lanes left.",
    inputSchema: {
      clipId: z.string().uuid().describe("Id of the MIDI clip to edit, from project_snapshot."),
      type: z
        .enum(["cc", "pitchBend", "channelPressure"])
        .describe(
          "Which controller lane to remove: `cc` (a numbered Control Change — REQUIRES " +
            "`controller`), `pitchBend`, or `channelPressure`."
        ),
      controller: z
        .number()
        .int()
        .min(0)
        .max(127)
        .optional()
        .describe(
          "The CC number, 0-127 — REQUIRED when `type` is \"cc\" (e.g. 1 = mod wheel, " +
            "64 = sustain). Ignored (omit it) for `pitchBend` / `channelPressure`."
        ),
    },
  },
  async ({ clipId, type, controller }) =>
    toToolResult(() => bridge.send("clip.removeControllerLane", { clipId, type, controller }))
);

/**
 * m27 leg D — the authoring primitive on top of clip_set_controller_lane.
 *
 * ⚠️ EVERY parameter named in the description below is also a key of
 * `inputSchema` AND is forwarded in the handler's `bridge.send` payload. That
 * is not a style note: `registerTool`'s `.strict()` wrapper rejects unknown
 * keys, but a key the DESCRIPTION advertises and the SCHEMA omits is stripped
 * by the SDK before the handler runs, and the tool then returns a perfectly
 * successful result computed from the default. Three parameters shipped that
 * way earlier in this round. If you add one here, add it in all three places.
 */
registerTool(
  "clip_apply_breath_contour",
  {
    title: "Make a MIDI clip's held notes breathe (expression swell + delayed vibrato)",
    description:
      "Make held notes BREATHE — the single highest-value fix for a wind, brass, string " +
      "or sustained-vocal part that sounds like a synthesizer holding a key down. In ONE " +
      "call it writes the correlated performance contour a real player puts on a " +
      "sustained note, which is otherwise dozens of hand-placed points per note via " +
      "clip_set_controller_lane:\n" +
      "• an EXPRESSION (CC 11) swell — a small dip just after the attack as the air " +
      "column settles, a rise to a peak about two-thirds through the note, then a taper. " +
      "On the built-in sampler CC 11 moves LOUDNESS always, and BRIGHTNESS too whenever " +
      "the track's `sampler.expressionFilterDepth` is above 0 — that pairing is what " +
      "reads as a player leaning in, and it is why this beats a volume-automation swell, " +
      "which can only ever sound like a fader move.\n" +
      "• DELAYED VIBRATO on the pitch-bend lane — straight for the first half second, " +
      "then blooming from nothing to about ±12 cents at 5.5 Hz, and relaxing back to " +
      "exact centre before the note ends. Constant vibrato from the attack is the classic " +
      "MIDI giveaway; the delay is the whole point.\n" +
      "• a few cents of MICRO-SHARPENING at the top of the swell, resolving as it falls " +
      "(blowing harder pushes a wind instrument sharp).\n" +
      "Shapes EVERY note in the clip by default, or only the ones in `noteIds`. It MERGES " +
      "with whatever is already on those two lanes: points outside the shaped notes' spans " +
      "survive exactly as authored, so you can run it note by note across a phrase, or " +
      "after hand-drawing something else, without wiping your earlier work — unlike " +
      "clip_set_controller_lane, which replaces a lane wholesale by contract. Notes too " +
      "short for the straight opening plus one whole vibrato cycle get the expression " +
      "contour ONLY and no pitch-bend lane at all; that is the intended shape for short " +
      "notes, not a failure, and the response says how many. ⚠️ Pitch bend is CHANNEL-WIDE " +
      "in MIDI, so the vibrato bends every voice sounding on that track — correct for the " +
      "monophonic wind or vocal line this is built for, wrong for a chordal part (pass " +
      "`vibratoDepthCents: 0` there and keep just the swell). Every parameter is optional " +
      "and the defaults are a complete, musical result — reach for them only when the " +
      "default shape is not what the part needs. One call = one undo step. MIDI clips " +
      "only. Returns the updated clip (both lanes echo back in `controllerLanes`) plus " +
      "`notesTouched`, `notesWithVibrato`, `expressionPointCount`, `pitchBendPointCount`, " +
      "`perNotePointBudget`, and a `warnings` array — READ THE WARNINGS: they are how a " +
      "contour that will only be half audible (e.g. brightness off, or no note long " +
      "enough for vibrato) tells you so.",
    inputSchema: {
      clipId: z.string().uuid().describe("Id of the MIDI clip to shape, from project_snapshot."),
      noteIds: z
        .array(z.string().uuid().describe("A note id from clip_get_notes."))
        .optional()
        .describe(
          "Ids of the notes to shape, from clip_get_notes. OMIT to shape EVERY note in " +
            "the clip (the usual call). An id that is not in the clip is refused outright " +
            "and nothing is written — a partly-applied contour would leave you unable to " +
            "tell which notes got one."
        ),
      depth: z
        .number()
        .min(0)
        .max(1)
        .optional()
        .describe(
          "How far the swell falls below its peak, as a fraction of `peakValue`. Default " +
            "0.25 — about 2.5 dB from peak to trough, which is the INVOLUNTARY contour of " +
            "a note held steady rather than a written crescendo. Raise toward 0.5 for a " +
            "hairpin. 0 turns the swell off (a flat lane at `peakValue`)."
        ),
      peakValue: z
        .number()
        .int()
        .min(0)
        .max(127)
        .optional()
        .describe(
          "Raw CC value at the top of the swell, 0-127. Default 127, which is the " +
            "expression lane's own neutral: the loudest instant of the note comes out " +
            "exactly as loud as it would with no contour at all, so applying this can " +
            "never quietly drop the level of a part you already balanced. Lower it to " +
            "leave headroom above the peak for a later hand edit."
        ),
      peakPosition: z
        .number()
        .min(0.05)
        .max(0.95)
        .optional()
        .describe(
          "Where the peak of the swell sits, as a fraction of the note's length. Default " +
            "0.65 — past the middle, so the note takes longer arriving than leaving, which " +
            "is the asymmetry that reads as effort rather than as a tremolo."
        ),
      attackSettleSeconds: z
        .number()
        .min(0)
        .max(1)
        .optional()
        .describe(
          "Seconds from the attack to the bottom of the settling dip. Default 0.05. " +
            "Automatically clamped to a quarter of the note, so a staccato note gets a " +
            "scaled-down version of the same curve instead of being all dip."
        ),
      expressionCC: z
        .number()
        .int()
        .min(0)
        .max(127)
        .optional()
        .describe(
          "Which CC number carries the swell. Default 11 (expression) — the one the " +
            "built-in sampler routes to amplitude with no opt-in, and the default target " +
            "of its brightness filter, so one lane moves both. Change it only if you have " +
            "pointed `sampler.expressionFilterCC` somewhere else."
        ),
      expressionSpacingSeconds: z
        .number()
        .min(0.001)
        .max(1)
        .optional()
        .describe(
          "Seconds between emitted expression points. Default 0.02. Controller lanes are " +
            "STEPWISE (a value holds until the next point), so a dense run is what makes a " +
            "smooth swell instead of a staircase. Note this sets the finest step TIMING, " +
            "not the point count: redundant points are dropped, so the run is only ever as " +
            "long as the number of distinct CC values the contour passes through."
        ),
      vibratoOnsetSeconds: z
        .number()
        .min(0)
        .max(10)
        .optional()
        .describe(
          "Seconds of STRAIGHT playing before vibrato begins. Default 0.5. A note shorter " +
            "than this plus one whole vibrato cycle gets no pitch-bend lane at all — lower " +
            "this to bring vibrato to shorter notes."
        ),
      vibratoRateHz: z
        .number()
        .min(0.2)
        .max(20)
        .optional()
        .describe(
          "Vibrato rate in Hz. Default 5.5, the middle of the 5-7 Hz band conventionally " +
            "quoted for instrumental vibrato."
        ),
      vibratoDepthCents: z
        .number()
        .min(0)
        .max(200)
        .optional()
        .describe(
          "Peak vibrato width in CENTS — a ± figure, so 12 spans 24 cents. Default 12, " +
            "deliberately conservative: pitch bend is channel-wide and will bend any " +
            "overlapping neighbouring note's tail too. 0 turns vibrato off entirely and " +
            "writes no pitch-bend lane beyond the micro-sharpening."
        ),
      vibratoBloomSeconds: z
        .number()
        .min(0)
        .max(10)
        .optional()
        .describe(
          "Seconds over which the vibrato widens from nothing to full depth after it " +
            "starts. Default 0.7 (about four cycles at the default rate)."
        ),
      vibratoReleaseSeconds: z
        .number()
        .min(0)
        .max(10)
        .optional()
        .describe(
          "Seconds before the note's end over which the vibrato relaxes back to centre. " +
            "Default 0.08. Players do ease off, and it guarantees the lane lands on exact " +
            "centre so the NEXT note cannot start detuned by this one's last vibrato phase."
        ),
      sharpenCents: z
        .number()
        .min(-200)
        .max(200)
        .optional()
        .describe(
          "Peak micro-sharpening in CENTS at the top of the swell, resolving to nothing as " +
            "the contour falls. Default 4 — on its own that is below the ear's pitch " +
            "threshold, but it is CORRELATED with the loudness swell, and that correlation " +
            "is what is heard as effort. Negative values flatten instead."
        ),
      bendSpacingSeconds: z
        .number()
        .min(0.001)
        .max(1)
        .optional()
        .describe(
          "Seconds between emitted pitch-bend points. Default 0.008. Unlike expression, " +
            "the bend run IS the vibrato waveform (nothing smooths it), so this is its " +
            "sample rate — about 23 points per cycle at the default. Coarsening it much " +
            "past 0.02 stops sounding like vibrato."
        ),
      bendRangeSemitones: z
        .number()
        .min(0.01)
        .max(48)
        .optional()
        .describe(
          "The instrument's pitch-bend range in semitones for a full ±8192 deflection, so " +
            "the cents figures above land correctly. Default 2, which is exactly what the " +
            "built-in sampler uses. A hosted Audio Unit may differ — if the vibrato comes " +
            "out wider or narrower than asked, this is the parameter to correct it with."
        ),
    },
  },
  async ({
    clipId,
    noteIds,
    depth,
    peakValue,
    peakPosition,
    attackSettleSeconds,
    expressionCC,
    expressionSpacingSeconds,
    vibratoOnsetSeconds,
    vibratoRateHz,
    vibratoDepthCents,
    vibratoBloomSeconds,
    vibratoReleaseSeconds,
    sharpenCents,
    bendSpacingSeconds,
    bendRangeSemitones,
  }) =>
    toToolResult(() =>
      bridge.send("clip.applyBreathContour", {
        clipId,
        noteIds,
        depth,
        peakValue,
        peakPosition,
        attackSettleSeconds,
        expressionCC,
        expressionSpacingSeconds,
        vibratoOnsetSeconds,
        vibratoRateHz,
        vibratoDepthCents,
        vibratoBloomSeconds,
        vibratoReleaseSeconds,
        sharpenCents,
        bendSpacingSeconds,
        bendRangeSemitones,
      })
    )
);

/**
 * Breath pad P1 — the COMPOSING verb on top of `clip_apply_breath_contour`.
 *
 * ⚠️ EVERY parameter named in the description below is also a key of
 * `inputSchema` AND is forwarded in the handler's `bridge.send` payload — the
 * same three-place rule the sibling above carries, and for the same reason:
 * `registerTool`'s `.strict()` rejects unknown keys, but a key the DESCRIPTION
 * advertises and the SCHEMA omits is silently stripped by the SDK before the
 * handler runs, and the tool then returns a perfectly successful result
 * computed from the default. That has already happened once in this file.
 *
 * ⚠️ `depth`, `peakPosition`, `onsetLevel` and `releaseLevel` are deliberately
 * ABSENT: those four ARE the pattern. `clip_apply_breath_contour` remains the
 * verb for hand-authored shapes and its contract is untouched.
 */
registerTool(
  "clip_apply_effort_shape",
  {
    title: "Shape how hard the player is blowing, with one named musical gesture",
    description:
      "Apply a NAMED effort gesture to a MIDI part — the composing verb on top of " +
      "clip_apply_breath_contour. Instead of choosing a dozen numbers, pick the shape a " +
      "musician would name, and every note gets the right contour for its place in the " +
      "music:\n" +
      "• `messaDiVoce` — grow to a peak in the MIDDLE of the note, then fade. The anchor " +
      "gesture for a held wind or vocal note.\n" +
      "• `lateBloom` — steady, then swell in the last third. The difference between singing " +
      "a note and leaning into it.\n" +
      "• `sforzandoPiano` — hit it hard, drop immediately to soft, then grow back (sfp).\n" +
      "• `subToneEntry` — start almost breath-only and rise into full tone. The tenor-ballad " +
      "gesture.\n" +
      "• `flat` — no shaping. The identity; use it to hear the part with expression off.\n" +
      "• `hairpinCrescendo` / `hairpinDiminuendo` — the whole PHRASE grows or falls away, " +
      "note by note.\n" +
      "• `terraced` — step to one level and hold it for the phrase (the baroque contrast to " +
      "the hairpins).\n" +
      "\n" +
      "\n" +
      "TWO WAYS TO CHOOSE, and you must use exactly one. `pattern` names ONE gesture. " +
      "`ringAngle` puts a DOT on a circle of all eight and blends the two it sits between — " +
      "which is how you get a gesture that has no name, like 'mostly a late bloom but leaning " +
      "toward a phrase crescendo' (ringAngle 112). The blend is nearest-two and equal-gain: " +
      "landing on a pattern's own angle gives that pattern exactly, nothing else leaks in, and " +
      "two identical patterns blend to themselves rather than to something louder. " +
      "`ringRadius` is how far out the dot is, 0-1, where 0 changes nothing at all. Passing " +
      "both forms, or neither, or ringRadius/ring without ringAngle, is REFUSED with a " +
      "sentence — none of those is silently resolved for you.\n" +
      "\n" +
      "THE PHRASE-SCOPED PATTERNS (the last three) are what clip_apply_breath_contour " +
      "structurally cannot do: they split the part into phrases at the BREATHS — rests " +
      "bigger than `maxGapBeats`, the same rule clip_humanize's legato pass uses — and place " +
      "each note at its own point of the arc. A written crescendo is a property of the " +
      "phrase, not of any one note.\n" +
      "\n" +
      "Everything else is the sibling verb's, unchanged: the two lanes are MERGED (points " +
      "outside the shaped notes survive as authored), the clip-wide point budget applies, " +
      "and it is ONE undo step.\n" +
      "\n" +
      "⛔ ON A TRACK HOSTING AN AUDIO UNIT — which includes EVERY sound-bank instrument, so " +
      "the GM saxophone, flute, strings and so on — two limits were MEASURED on 2026-08-19 " +
      "and are enforced here rather than hoped about:\n" +
      "1. Bend VIBRATO is SUPPRESSED, not written. Pitch bend there is sampled at the " +
      "offline render block rate, so an authored 5.5 Hz vibrato bounces as two vibratos " +
      "beating. `notesWithVibrato` comes back 0 and a warning names the route that DOES " +
      "work: the instrument's own vibrato on a CC 1 (mod wheel) lane, about 2.4 + 0.30 x CC1 " +
      "cents at a fixed 5.4 Hz, which you author with clip_set_controller_lane.\n" +
      "2. The shape moves LOUDNESS ONLY, never brightness. CC 11 on that path is exactly a " +
      "gain. Brightness shaping is a built-in Sampler capability — it is not a setting to " +
      "turn on here.\n" +
      "\n" +
      "MAKE THE DOT MOVE — this is what turns a setting into a performance. `path: \"drift\"` " +
      "with a `pathSeed` sends the dot wandering from one gesture into the next and back, so " +
      "note 9 is shaped differently from note 2 the way a player's effort is never twice the " +
      "same. `path: \"orbit\"` travels the ring steadily instead. The wander is REPRODUCIBLE: " +
      "it is a pure function of the clip beat and the seed, with nothing accumulating anywhere, " +
      "so playback, replay, a looped cycle and a bounce that starts in the middle of the song " +
      "all agree exactly. Same seed, same performance — change the seed for a different one.\n" +
      "⚠️ The dot is read ONCE PER NOTE, at the note's start. It chooses each note's gesture and " +
      "cannot shape inside one.\n" +
      "\n" +
      "THE AIR BUDGET — a wind player has a finite lungful. `airEnforced: true` makes a phrase " +
      "that runs past it SAG toward the ground rather than hold, the way a real player does. " +
      "⛔ IT DEFAULTS TO FALSE, deliberately: an air budget OVERRIDES what you wrote, and " +
      "anything that does that is switched on once, on purpose, rather than assumed. Tune it " +
      "with `airCapacitySeconds` (how long the player can sustain the part as authored — 6 s), " +
      "`airConsumptionExponent` (how much faster loud playing burns air), " +
      "`airRefillSecondsPerSecond` (how much a rest gives back), `airMinBreathSeconds` (a rest " +
      "shorter than this is an articulation, not a breath) and `airReserveFraction` (when the " +
      "sag begins). Every one of those is an ESTIMATE, which is exactly why it is a parameter.\n" +
      "⭐ THE RESPONSE ALWAYS CARRIES `air`, whether or not you enforced it, because that is " +
      "what answers \"why did this get quiet?\". Read `air.applied` first: false means the lane " +
      "was NOT changed and the rest is a prediction of what enforcing would do — so you can ask " +
      "the question without mutating anything. `air.constrainedNoteCount` is how many notes " +
      "lost something, `air.lowestAir` how close the player came to empty, and when anything " +
      "was constrained `air.phrases[].constrainedNotes` names each note with `effortRequested` " +
      "beside `effortAllowed`, the two peak CC values, and the dB between them. " +
      "`air.neverRecovered` means the rests are too short to keep up and the sag accumulates. " +
      "⛔ A part can also get quiet because YOU asked for it — a hairpin diminuendo. Only the " +
      "budget produces effortAllowed < effortRequested, which is why \"air runs out\" is " +
      "deliberately NOT one of the patterns you can pick: one symptom, one cause.\n" +
      "\n" +
      "PHYSIOLOGICAL HUMANISATION — the involuntary layer. `driftDepth` is a slow 1/f sag in " +
      "the effort baseline (period `driftScaleBeats`, default 8 beats); `tremorDepth` is a " +
      "4-8 Hz micro-tremor INSIDE each note, at `tremorRateHz`, deepening with effort by " +
      "`tremorEffortExponent`. ⛔ BOTH DEFAULT TO 0 — off, and off renders BYTE-IDENTICALLY to " +
      "never mentioning them, which is what makes each one individually declinable after you " +
      "hear it. Suggested starting values: driftDepth 0.05, tremorDepth 0.03 (about 0.29 dB). " +
      "The drift is DOWNWARD ONLY: effort 1 means 'as authored', so it is a ceiling and there " +
      "is nothing above it to drift into.\n" +
      "⭐ THE TREMOR NOW LANDS ON HOSTED-AU TRACKS TOO (m28-bug, 2026-08-20). It used to be " +
      "refused on every soundBank instrument including the GM sax, and that refusal was " +
      "correct at the time: an offline bounce fed hosted AUs MIDI in 4096-frame blocks — an " +
      "11.719 Hz sampler — so a tremor returned with a sample-and-hold copy at " +
      "|11.719 - rate| Hz of depth rate/(11.719 - rate), which at 8 Hz was 2.14x LOUDER than " +
      "the tremor itself and still 52% at 4 Hz. The offline block is now 512 frames, a " +
      "93.75 Hz sampler, so that copy sits at |93.75 - rate| Hz — 3% of the tremor at 8 Hz, " +
      "measured from rendered audio — and the whole 4-8 Hz band is delivered at about 88% of " +
      "authored depth. ⛔ THE LIMIT STILL EXISTS, IT MOVED: rates above 18.75 Hz are still " +
      "SUPPRESSED rather than quietly retuned, and the response says so when it happens. " +
      "The DRIFT (three orders of magnitude slower) was never affected and lands everywhere.\n" +
      "\n" +
      "READ THE RESPONSE. `minEffort` and `maxEffort` equal means the shape ran and varied " +
      "nothing (usually a phrase-scoped pattern on notes that all sit at one point of one " +
      "phrase). `phraseCount` says how many arcs were drawn. `warnings` says what will and " +
      "will not be audible. On the ring form there is also `ring`, carrying the resolved " +
      "`angleDegrees`, `radius`, `patternIds`, per-pattern `weights`, and the `noteWeight` / " +
      "`phraseWeight` split — read the weights rather than `patternId`, which names only the " +
      "NEAREST gesture and not the only one that played. On a moving dot that `ring` block " +
      "describes the ORIGIN, and a `path` block describes the journey: `moved` says whether the " +
      "dot travelled at all, `patternIds` lists every gesture it actually reached, and " +
      "`outrunsNotes` says the motion was faster than the notes could sample it. A wander that " +
      "reports one entry in `patternIds` ran and did nothing musical. MIDI clips only.",
    inputSchema: {
      clipId: z.string().describe("Id of the MIDI clip to shape, from project_snapshot."),
      pattern: z
        .enum([
          "flat",
          "messaDiVoce",
          "lateBloom",
          "hairpinCrescendo",
          "hairpinDiminuendo",
          "terraced",
          "sforzandoPiano",
          "subToneEntry",
        ])
        .optional()
        .describe(
          "ONE named gesture — the simple form. An unknown name is REFUSED naming the valid " +
            "ones; it is never silently defaulted to a shape you did not ask for. Pass EITHER " +
            "this OR `ringAngle`, never both, and never neither — the app refuses each of those " +
            "with a sentence rather than guessing."
        ),
      ringAngle: z
        .number()
        .min(0)
        .max(360)
        .optional()
        .describe(
          "THE RING — where the dot sits, in DEGREES, on a circle of the 8 gestures. This is " +
            "the blending form: instead of one gesture you get the two the dot sits between, " +
            "mixed by how close it is to each. The default ring is 45° apart starting at 0: " +
            "0=flat, 45=messaDiVoce, 90=lateBloom, 135=hairpinCrescendo, 180=hairpinDiminuendo, " +
            "225=terraced, 270=sforzandoPiano, 315=subToneEntry. So 157.5 is halfway between " +
            "the crescendo and the diminuendo (which cancel to a steady mid-level), and 67.5 is " +
            "part messa di voce, part late bloom. Landing exactly on a number above gives that " +
            "gesture EXACTLY — the blend is nearest-two, so a pattern you are not near " +
            "contributes nothing at all. Only two things ever mix."
        ),
      ringRadius: z
        .number()
        .min(0)
        .max(1)
        .optional()
        .describe(
          "How far out the dot sits, 0-1. Default 1 (the full gesture). 0 is a TRUE no-op — the " +
            "shape is not applied at all and nothing changes level — not 'half as loud'. ⚠️ Not " +
            "independent of `amount`: both scale the same thing, so only the PRODUCT survives " +
            "(radius 0.5 with amount 1 is identical to radius 1 with amount 0.5). Requires " +
            "`ringAngle`; on its own it is refused rather than defaulted."
        ),
      ring: z
        .array(z.string())
        .optional()
        .describe(
          "Your own ring, as pattern ids in ring order — replaces the default eight. They are " +
            "spaced evenly, so N ids sit 360/N apart with the first at 0°. Duplicates are " +
            "allowed (a ring of copies of one pattern is a legitimate way to pin the dot). " +
            "Max 32. Requires `ringAngle`; on its own it is refused rather than defaulted."
        ),
      path: z
        .enum(["fixed", "orbit", "drift"])
        .optional()
        .describe(
          "HOW THE DOT MOVES while the part plays. Default 'fixed' — it stays where you put " +
            "it, which is the behaviour every earlier call had.\n" +
            "• 'orbit' — a steady revolution round the ring, so the part travels through every " +
            "gesture in turn. Set `revolutionBeats`.\n" +
            "• 'drift' — a seeded wander that flows from one gesture into the next and back. " +
            "This is the one that sounds like a player rather than a setting. Set `pathSeed`, " +
            "and optionally `scaleBeats` / `momentum` / `angleSwing`.\n" +
            "With a path, `ringAngle` and `ringRadius` stop being where the dot IS and become " +
            "where you PUT it — the path is an offset from there, so nudging the origin moves " +
            "the whole journey instead of cancelling it.\n" +
            "⚠️ THE DOT IS READ ONCE PER NOTE, at the note's start. It chooses each note's " +
            "gesture; it cannot shape INSIDE a note (that is what the note-scoped patterns " +
            "are for). A path that moves faster than the notes arrive comes back with a " +
            "warning saying so rather than aliasing quietly.\n" +
            "⚠️ Parameters belonging to another path are REFUSED, not ignored: " +
            "`revolutionBeats` on a drift is an error with a sentence. Requires `ringAngle`."
        ),
      pathSeed: z
        .number()
        .int()
        .min(0)
        .max(4294967295)
        .optional()
        .describe(
          "WHICH wander you get, 0-4294967295. Default 0. The same seed always produces the " +
            "same performance at the same clip beats — in playback, on replay, and in a bounce " +
            "alike, including one that starts in the middle of the song. Change it to audition " +
            "a different take of the same idea. ⚠️ Capped at 32 bits deliberately: a JSON " +
            "number is a double, so a larger seed would not survive the round trip and you " +
            "would silently get a different wander back. Only means anything with path 'drift'."
        ),
      revolutionBeats: z
        .number()
        .min(0.25)
        .max(4096)
        .optional()
        .describe(
          "ORBIT ONLY. How many BEATS one full trip round the ring takes. Default 16. On the " +
            "default 8-pattern ring that is one gesture every 2 beats. Long values are the " +
            "useful ones: the dot is read once per note, so a revolution shorter than a few " +
            "notes is heard as an alias rather than as motion, and is warned about."
        ),
      pathDirection: z
        .enum(["clockwise", "counterclockwise"])
        .optional()
        .describe(
          "ORBIT ONLY. Which way round. Default 'clockwise', which is the order you listed " +
            "the patterns in (or the default ring's order: flat → messaDiVoce → lateBloom → …)."
        ),
      scaleBeats: z
        .number()
        .min(0.25)
        .max(1024)
        .optional()
        .describe(
          "DRIFT ONLY. How many BEATS one unit of the wander spans. Default 8 — about two bars " +
            "of 4/4, which reads as phrasing rather than as wobble. Bigger is slower."
        ),
      octaves: z
        .number()
        .int()
        .min(1)
        .max(8)
        .optional()
        .describe(
          "DRIFT ONLY. How many layers of detail the wander has. Default 4: one slow sway plus " +
            "three progressively faster and quieter layers on top. 1 is a single pure sway."
        ),
      momentum: z
        .number()
        .min(0)
        .max(1)
        .optional()
        .describe(
          "DRIFT ONLY. How LAZY the wander is, 0-1. Default 0.5. 1 is one long unhurried sway; " +
            "0 is twitchy; 0.5 is the 1/f middle that human drift tends to sit near. ⚠️ It is " +
            "the spectral tilt of the noise, not a stored velocity — nothing in this feature " +
            "accumulates, which is why a bounce from bar 33 matches playing through to it."
        ),
      angleSwing: z
        .number()
        .min(0)
        .max(360)
        .optional()
        .describe(
          "DRIFT ONLY. The furthest the dot ever wanders from `ringAngle`, in DEGREES either " +
            "side. Default 45 — one pattern spacing on the default ring, so it reaches each " +
            "neighbour and no further. This is an exact bound, not a typical value. A swing " +
            "much smaller than the gap between gestures comes back with a warning that the " +
            "dot moved and never left the gesture it started on."
        ),
      radiusSwing: z
        .number()
        .min(0)
        .max(1)
        .optional()
        .describe(
          "DRIFT ONLY. How far the dot also wanders IN AND OUT, 0-1. Default 0 — the wander " +
            "changes WHICH gesture is playing, not how strongly it is applied, so one control " +
            "has one visible outcome. Raise it to let the intensity breathe too."
        ),
      noteIds: z
        .array(z.string())
        .optional()
        .describe(
          "Ids of the notes to shape (from clip_get_notes). OMIT to shape every note in the " +
            "clip. Phrases are still measured over the WHOLE clip, so shaping the middle " +
            "three notes of a phrase places them where they really sit in it rather than " +
            "renormalising them into a phrase of their own. An id not in the clip is refused " +
            "outright — nothing is written."
        ),
      amount: z
        .number()
        .min(0)
        .max(1)
        .optional()
        .describe(
          "How strongly the pattern is applied, 0-1. Default 1. 0 is a VALID no-op on the " +
            "shaping axis — a flat lane at peakValue — not an error, and it says so in warnings."
        ),
      maxGapBeats: z
        .number()
        .min(0)
        .max(16)
        .optional()
        .describe(
          "A gap larger than this counts as a BREATH and splits the phrase, so a hairpin " +
            "starts over after it. Default 0.125 (a thirty-second note at a quarter-note " +
            "beat) — the same threshold, and the same reasoning, as clip_humanize's " +
            "maxGapBeats. Only the phrase-scoped patterns consult it."
        ),
      loudnessDepth: z
        .number()
        .min(0)
        .max(1)
        .optional()
        .describe(
          "How far a phrase-scoped shape may pull a quiet note's peak down, 0-1. Default " +
            "0.55, which is about 9 dB across a full hairpin. ⚠️ Not linear in dB: CC 11 is " +
            "a square law, so halving it is -12 dB, not -6."
        ),
      swellDepth: z
        .number()
        .min(0)
        .max(1)
        .optional()
        .describe(
          "How much a quiet note's own internal swell shrinks along with its level, 0-1. " +
            "Default 0.5, on the reasoning that a player at low pressure has less to shape " +
            "with. Set 0 to vary only the level and keep every note's internal shape identical."
        ),
      airEnforced: z
        .boolean()
        .optional()
        .describe(
          "THE AIR BUDGET SWITCH. ⛔ Default FALSE, and that is a decision, not an oversight: " +
            "turning it on lets the model OVERRIDE what you wrote, pulling a phrase down when " +
            "the simulated player runs out of breath, so it is opted into rather than assumed. " +
            "With it false you still get the full `air` report saying what it WOULD have done — " +
            "which is the cheapest way to find out whether a part is over-long before changing " +
            "anything. A note is never taken to silence and no note's length or existence ever " +
            "changes; the phrase sags, it does not stop."
        ),
      airCapacitySeconds: z
        .number()
        .min(0.25)
        .max(3600)
        .optional()
        .describe(
          "How many SECONDS the player can sustain the part AS AUTHORED before the lungful is " +
            "gone. Default 6. This is an estimate and it is the first knob to reach for when " +
            "the budget is firing more than you want — raise it. (There is no separate " +
            "`referenceEffort`: it would be algebraically the same axis as this number.)"
        ),
      airConsumptionExponent: z
        .number()
        .min(0)
        .max(8)
        .optional()
        .describe(
          "How much faster loud playing burns air: rate = effort^this. Default 1.5, superlinear " +
            "because blowing pressure rises steeply into fortissimo. At 1.5 a phrase at half the " +
            "authored level lasts about 2.8x longer. 0 makes the level irrelevant."
        ),
      airRefillSecondsPerSecond: z
        .number()
        .min(0)
        .max(100)
        .optional()
        .describe(
          "How much of a lungful one second of rest gives back. Default 0.5, so a 2-second rest " +
            "refills completely. ⚠️ If the part's rests are shorter than this can keep up with, " +
            "the sag ACCUMULATES across the part instead of resetting at each breath — the " +
            "response reports that as `air.neverRecovered` rather than leaving you to hear it."
        ),
      airMinBreathSeconds: z
        .number()
        .min(0)
        .max(60)
        .optional()
        .describe(
          "A rest shorter than this many SECONDS is an articulation, not a breath, and refills " +
            "nothing. Default 0.15. ⚠️ This is in SECONDS while `maxGapBeats` is in BEATS, so at " +
            "a fast tempo a gap can split the phrase and still be too quick to breathe in. That " +
            "is not a contradiction, it is a player whose rest was too short — the response says " +
            "so with breath.kind 'tooShort', which is a different answer from 'none' (the first " +
            "phrase, which has nothing before it)."
        ),
      airReserveFraction: z
        .number()
        .min(0)
        .max(1)
        .optional()
        .describe(
          "Below this fraction of a lungful the player starts running out, and effort is scaled " +
            "toward it so the phrase SAGS rather than stopping. Default 0.25. A note starting " +
            "exactly AT the reserve is left alone; only notes below it lose anything."
        ),
      driftDepth: z
        .number()
        .min(0)
        .max(1)
        .optional()
        .describe(
          "How far a slow 1/f drift may pull the effort baseline BELOW what you wrote, as a " +
            "fraction. Default 0 — off, and off is byte-identical to not mentioning it. 0.05 is " +
            "the design's suggested starting value. DOWNWARD ONLY: effort 1 means 'as authored'."
        ),
      driftScaleBeats: z
        .number()
        .min(0.01)
        .max(4096)
        .optional()
        .describe(
          "The drift's period in BEATS. Default 8 (two bars of 4/4). Deliberately far slower " +
            "than any note rate: effort is sampled once per note, so a fast drift would be " +
            "aliased by the note grid rather than heard."
        ),
      driftOctaves: z
        .number()
        .int()
        .min(1)
        .max(8)
        .optional()
        .describe(
          "How many fBm octaves the drift is built from. Default 4, persistence fixed at 0.5, " +
            "which is the 1/f spectrum. ⚠️ '1/f breath pressure' is a MODELLING CHOICE this " +
            "design made, not a measured finding — no measurement of 1/f structure in " +
            "wind-instrument breath pressure was found."
        ),
      tremorDepth: z
        .number()
        .min(0)
        .max(1)
        .optional()
        .describe(
          "Peak-to-trough depth of the involuntary micro-tremor INSIDE each note, as a fraction " +
            "of the contour level it rides on. Default 0 — off, and off is byte-identical. 0.03 " +
            "is the suggested value and measures about 0.29 dB peak-to-trough; the line is " +
            "0.0755 dB per CC of travel, MEASURED on the built-in sampler at ±1, ±2, ±4 and ±8 " +
            "CC. ⛔ SUPPRESSED on hosted-AU tracks — read the warnings."
        ),
      tremorRateHz: z
        .number()
        .min(0.2)
        .max(20)
        .optional()
        .describe(
          "Tremor rate in Hz, 0.2-20. Default 4.565 = the vibrato rate x 0.83, so tremor and " +
            "vibrato are not one oscillator at one rate summing into a single deeper vibrato. " +
            "At the BOTTOM of the 4-8 Hz physiological band. On a hosted AU an offline bounce " +
            "re-samples this lane at 93.75 Hz, so anything up to 18.75 Hz is written; above " +
            "that it is suppressed and the response says so. The band is the vibrato " +
            "band: below 0.2 Hz a tremor is a drift, which is what driftDepth is for, and a " +
            "rate outside it is REJECTED rather than clamped so you are never handed a " +
            "different gesture under the name you asked for."
        ),
      tremorEffortExponent: z
        .number()
        .min(0)
        .max(8)
        .optional()
        .describe(
          "How the tremor deepens with effort: depth is scaled by effort^this. Default 1 " +
            "(linear). 0 makes the tremor the same depth however hard the player is blowing."
        ),
      peakValue: z
        .number()
        .int()
        .min(0)
        .max(127)
        .optional()
        .describe(
          "CC value at FULL effort, 0-127. Default 127 — the lane's neutral, so the loudest " +
            "instant is exactly as loud as the note with no contour at all, and applying this " +
            "can never quietly drop the level of a part you already balanced."
        ),
      expressionCC: z
        .number()
        .int()
        .min(0)
        .max(127)
        .optional()
        .describe(
          "Which CC carries the shape. Default 11 (expression) — the one the built-in " +
            "sampler routes to amplitude with no opt-in."
        ),
      attackSettleSeconds: z
        .number()
        .min(0)
        .max(1)
        .optional()
        .describe(
          "Seconds from the attack to the settling dip. Default 0.05. A pattern that has its " +
            "own early dip (sforzandoPiano) overrides this per note so its accent lands where " +
            "the gesture says."
        ),
      expressionSpacingSeconds: z
        .number()
        .min(0.001)
        .max(1)
        .optional()
        .describe(
          "Seconds between expression points. Default 0.02. Controller lanes are STEPWISE, " +
            "so a dense run is what makes a curve instead of a staircase."
        ),
      vibratoOnsetSeconds: z
        .number()
        .min(0)
        .max(10)
        .optional()
        .describe(
          "Seconds of STRAIGHT playing before vibrato starts. Default 0.5. A note shorter " +
            "than this plus one cycle gets no vibrato at all."
        ),
      vibratoRateHz: z.number().min(0.2).max(20).optional().describe("Vibrato rate in Hz. Default 5.5."),
      vibratoDepthCents: z
        .number()
        .min(0)
        .max(200)
        .optional()
        .describe(
          "Peak vibrato width in CENTS (a ± figure). Default 12; 0 turns vibrato off. " +
            "IGNORED on a track hosting an Audio Unit, where vibrato is suppressed for the " +
            "measured aliasing reason above — the response reports 0 notes with vibrato " +
            "rather than pretending."
        ),
      vibratoBloomSeconds: z
        .number()
        .min(0)
        .max(10)
        .optional()
        .describe("Seconds for the vibrato to widen from nothing to full depth. Default 0.7."),
      vibratoReleaseSeconds: z
        .number()
        .min(0)
        .max(10)
        .optional()
        .describe(
          "Seconds before the note's end over which vibrato relaxes back to centre. Default " +
            "0.08, which also guarantees the next note cannot start detuned by this one."
        ),
      sharpenCents: z
        .number()
        .min(-200)
        .max(200)
        .optional()
        .describe(
          "Peak micro-sharpening in CENTS at full effort, resolving as the shape falls. " +
            "Default 4. It rides the pitch-bend lane on EVERY instrument kind, including " +
            "hosted Audio Units, because it is a seconds-scale curve far below the block-rate " +
            "limit that forbids vibrato there."
        ),
      bendSpacingSeconds: z
        .number()
        .min(0.001)
        .max(1)
        .optional()
        .describe(
          "Seconds between emitted pitch-bend points. Default 0.008 — about 23 points per " +
            "cycle at the default vibrato rate."
        ),
      bendRangeSemitones: z
        .number()
        .min(0.01)
        .max(48)
        .optional()
        .describe(
          "The instrument's pitch-bend range in semitones for a full ±8192 deflection, so " +
            "the cents figures land correctly. Default 2 — exactly the built-in sampler, and " +
            "a hosted AUSampler was MEASURED at 2.0155, so the default is right to 0.78% " +
            "there too."
        ),
    },
  },
  async ({
    clipId,
    pattern,
    ringAngle,
    ringRadius,
    ring,
    path,
    pathSeed,
    revolutionBeats,
    pathDirection,
    scaleBeats,
    octaves,
    momentum,
    angleSwing,
    radiusSwing,
    noteIds,
    amount,
    maxGapBeats,
    airEnforced,
    driftDepth,
    driftScaleBeats,
    driftOctaves,
    tremorDepth,
    tremorRateHz,
    tremorEffortExponent,
    airCapacitySeconds,
    airConsumptionExponent,
    airRefillSecondsPerSecond,
    airMinBreathSeconds,
    airReserveFraction,
    loudnessDepth,
    swellDepth,
    peakValue,
    expressionCC,
    attackSettleSeconds,
    expressionSpacingSeconds,
    vibratoOnsetSeconds,
    vibratoRateHz,
    vibratoDepthCents,
    vibratoBloomSeconds,
    vibratoReleaseSeconds,
    sharpenCents,
    bendSpacingSeconds,
    bendRangeSemitones,
  }) =>
    toToolResult(() =>
      bridge.send("clip.applyEffortShape", {
        clipId,
        pattern,
        ringAngle,
        ringRadius,
        ring,
        path,
        pathSeed,
        revolutionBeats,
        pathDirection,
        scaleBeats,
        octaves,
        momentum,
        angleSwing,
        radiusSwing,
        noteIds,
        amount,
        maxGapBeats,
        airEnforced,
        driftDepth,
        driftScaleBeats,
        driftOctaves,
        tremorDepth,
        tremorRateHz,
        tremorEffortExponent,
        airCapacitySeconds,
        airConsumptionExponent,
        airRefillSecondsPerSecond,
        airMinBreathSeconds,
        airReserveFraction,
        loudnessDepth,
        swellDepth,
        peakValue,
        expressionCC,
        attackSettleSeconds,
        expressionSpacingSeconds,
        vibratoOnsetSeconds,
        vibratoRateHz,
        vibratoDepthCents,
        vibratoBloomSeconds,
        vibratoReleaseSeconds,
        sharpenCents,
        bendSpacingSeconds,
        bendRangeSemitones,
      })
    )
);

// ---------------------------------------------------------------------------
// Project-wide arrangement bar edits (m15-d) — insert/delete whole bars
// across the ENTIRE session, not just one clip. Meter-aware (a bar's length
// in beats depends on which meter region it falls in) and touch every
// timeline-anchored thing at once: clips, markers, the tempo AND meter maps,
// automation, and the loop/punch regions.
// ---------------------------------------------------------------------------

registerTool(
  "arrange_insert_bars",
  {
    title: "Insert empty bars across the whole project",
    description:
      "Insert `count` empty bars PROJECT-WIDE at a 1-based bar number, pushing " +
      "everything from that point rightward — the \"add space here\" move for " +
      "restructuring a whole arrangement (opening up a section, adding a build), as " +
      "opposed to clip_insert_time_range which only opens a gap inside one clip. " +
      "METER-AWARE: bar length in beats depends on the meter in force there (a bar " +
      "inside a 6/8 region is 6 beats, not 4) — the inserted bars continue the " +
      "meter of the bar right before the insertion point. Shifts EVERY track's " +
      "clips, every marker, the tempo map AND the meter map, every automation " +
      "lane, and the loop/punch regions together, so local musical relationships " +
      "are preserved (content governed by a given tempo/meter is still governed by " +
      "it after the shift). A clip straddling the insertion point SPLITS rather " +
      "than being torn. One undo step reverts the entire shift. Refused while a " +
      "recording is in progress (it would re-anchor the timeline under a rolling " +
      "capture) and refused if it would cut across a take group (flatten it first " +
      "— v1 does not re-anchor comps). Returns `{atBeat, insertedBeats, " +
      "beatsPerBar}` — the absolute beat the insertion happened at, how many beats " +
      "were inserted, and the beats-per-bar used for that insertion.",
    inputSchema: {
      atBar: z
        .number()
        .int()
        .min(1)
        .describe(
          "1-based bar number to insert before (bar 1 is the very start of the timeline, " +
            "beat 0). The new bars land immediately before this bar; everything at or after " +
            "it shifts right."
        ),
      count: z.number().int().min(1).describe("How many bars to insert. Whole number, >= 1."),
    },
  },
  async ({ atBar, count }) => toToolResult(() => bridge.send("arrange.insertBars", { atBar, count }))
);

registerTool(
  "arrange_delete_bars",
  {
    title: "Delete bars across the whole project",
    description:
      "Remove `count` bars PROJECT-WIDE starting at a 1-based bar number and close " +
      "the gap — the whole-arrangement counterpart to arrange_insert_bars (and, " +
      "unlike clip_delete_time_range, operates on the ENTIRE session rather than " +
      "one clip). METER-AWARE, same as arrange_insert_bars. Clips fully inside the " +
      "removed range are deleted outright (their ids come back in " +
      "`removedClipIds`); a clip straddling either edge is trimmed or split-and-" +
      "closed so it never leaves a hole. Markers inside the removed range are " +
      "deleted (`removedMarkerIds`); tempo/meter map changes inside the range are " +
      "removed and the rest pulls left; a loop or punch region swallowed by the " +
      "delete is disabled at the splice point rather than left dangling. A delete " +
      "that would leave a meter change sitting off its barline is REFUSED with a " +
      "teaching error naming the conflict (tempo changes have no barline " +
      "constraint and always splice cleanly). One undo step reverts the whole " +
      "delete. Refused while a recording is in progress and refused if it would " +
      "cut across a take group (flatten it first). Returns `{fromBeat, " +
      "deletedBeats, removedClipIds, removedMarkerIds}`.",
    inputSchema: {
      fromBar: z
        .number()
        .int()
        .min(1)
        .describe(
          "1-based bar number to start deleting from (bar 1 is the very start of the " +
            "timeline, beat 0)."
        ),
      count: z.number().int().min(1).describe("How many bars to delete. Whole number, >= 1."),
    },
  },
  async ({ fromBar, count }) => toToolResult(() => bridge.send("arrange.deleteBars", { fromBar, count }))
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
// clip_set_gain_envelope, clip_set_fades, clip_set_stretch,
// clip_stretch_to_length, clip_set_notes, clip_remove, clip_quantize) with a
// readable error telling you to change the
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
})
  // `.strict()` (m30-c): closes the same per-element hole for
  // take_set_comp's `segments` array — a typo'd field (e.g. "laneld") would
  // otherwise be silently stripped instead of rejected.
  .strict();

registerTool(
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

registerTool(
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

registerTool(
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

registerTool(
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

registerTool(
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

registerTool(
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

registerTool(
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

registerTool(
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

registerTool(
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

registerTool(
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

registerTool(
  "mixer_set_master_volume",
  {
    title: "Set master volume",
    description:
      "Set the master output gain of the whole mix, as a linear gain multiplier, " +
      "where 1.0 is unity gain (0 dB, no change). Range 0-2: 0 is silence, 1 is " +
      "unity, 2 is roughly +6 dB. This is linear gain, not decibels. To set an " +
      "individual track's gain instead, use track_set_volume. " +
      "2.0 is a HARD CEILING, not a soft one: a value above 2 is REJECTED by this " +
      "tool's schema (it is not silently clamped), and 2.0 itself is the loudest " +
      "this fader goes. Note the layer that refusal lives in — the SCHEMA. The " +
      "underlying `mixer.setMasterVolume` control command clamps to 0-2 rather than " +
      "erroring, exactly like an effect parameter, and answers a clamped call with a " +
      "`warnings` sentence; this tool refuses first so you never get that far. " +
      "When a mix needs more than +6 dB of makeup to reach a " +
      "loudness target — common with quiet General-MIDI-sourced material — do NOT " +
      "keep pushing here: add a `gain` insert at the FRONT of the master chain " +
      "(fx_add with trackId \"master\", kind \"gain\", index 0, ahead of the eq/limiter) and " +
      "take the remaining makeup there — its `gainLinear` param runs 0-16 (+24.08 dB), " +
      "which is enough to lift even a quiet solo GM part to a streaming level in ONE " +
      "stage (measured: solo GM piano is about -28 LUFS at velocity 100, near -35 LUFS " +
      "at velocity 64, so -14 LUFS needs roughly +14 to +21 dB). Chaining two gain " +
      "inserts used to be necessary for this and no longer is. Follow a large boost " +
      "with a limiter — the gain stage has no protection of its own. " +
      "Returns `{masterVolume}` — and, ONLY when a master volume automation lane is " +
      "actually governing (enabled and holding at least one point), also " +
      "`{automationControlled: true, automationPointCount}`. Those two keys are ABSENT " +
      "in the ordinary case. When they appear, your value was stored (it is undoable and " +
      "rules again the moment the lane is disabled or emptied) but the LANE, not this " +
      "fader, decides what is heard and what renders — edit the lane with " +
      "automation_set_points (trackId \"master\"), or disable it with " +
      "automation_set_lane_enabled, if you meant this level to be audible.",
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
    "bass-round",
    "guitar-crunch",
    "acoustic-sparkle",
    "horn-section",
    "drum-room",
    "lofi-tape",
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
      "with no tone change — a clean level lift. `bass-round`: the deliberate OPPOSITE of " +
      "bass-tight — a low-shelf lift for weight, then a LOW ~2.5:1 ratio with a SLOW 20 ms " +
      "attack so each note blooms before it is caught; pick it for blues, jazz, soul and " +
      "anything played with feel, and pick bass-tight when the bass must sit rock-steady under " +
      "a dense mix. `guitar-crunch`: saturator grit then an EQ scooping low-mid mud and lifting " +
      "bite — a driven electric guitar that cuts through a band. `acoustic-sparkle`: EQ only — " +
      "takes out the boxy honk and brings back string shimmer and air on an acoustic guitar. " +
      "`horn-section`: lifts the brassy core, softens the harsh edge, then ~3:1 compression so " +
      "the loud stabs stop jumping out. `drum-room`: a short, damped reverb at a modest 18% mix " +
      "— the kit breathes without the mix going wet. `lofi-tape`: gentle saturation plus a " +
      "high-shelf cut for the warm, dulled sound of old tape or vinyl."
  );

registerTool(
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
      "clean-boost (a clean ~+3 dB level lift), bass-round (warm, blooming bass — the opposite of " +
      "bass-tight), guitar-crunch (driven electric guitar), acoustic-sparkle (open, shimmering " +
      "acoustic guitar), horn-section (bold, even brass), drum-room (a small live room around the " +
      "kit), lofi-tape (warm, dulled tape/vinyl character). To fine-tune afterwards, nudge individual effects " +
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
      "No params. Returns `{bands, levelDB, peakDB, centroidHz, flux, correlation, width, " +
      "balance}`: `bands` is 24 " +
      "log-spaced frequency bands from 40 Hz to 16 kHz, each an energy value in dB with a " +
      "floor of -80 (band 0 is the lowest sub-bass, band 23 the highest treble — useful to " +
      "judge tonal balance, e.g. too much low end vs. not enough air). `levelDB` is the " +
      "short-term RMS level in dB (floor -80) — a quick 'how loud right now' reading, NOT " +
      "gated LUFS; for mastering-grade loudness use render_measure_loudness instead. " +
      "`peakDB` is the held sample peak in dB (-80 floor, ~20 dB/s release). `centroidHz` " +
      "is the spectral centroid in Hz — perceived brightness (higher = brighter/harsher, " +
      "lower = darker/warmer; 0 when silent). `flux` is normalized spectral flux 0-1 — how " +
      "much the spectrum is MOVING between frames (0 = silence or a steady drone, higher = " +
      "busy, percussive, changing material). The STEREO IMAGE trio (~300 ms integration) " +
      "is how you catch phase and mono problems: `correlation` is the L/R correlation " +
      "coefficient -1..+1 — +1 means the channels agree (mono-SAFE), around 0 means wide/" +
      "decorrelated content, and NEGATIVE values are a red flag: anti-phase energy that " +
      "will partially or fully CANCEL when the mix is played in mono (club PA, phone " +
      "speaker, broadcast). If a stereo widener or a flipped-polarity mic drives " +
      "correlation toward -1, the mix collapses in mono — fix the source, don't ship it. " +
      "`width` is 0..1 side-vs-mid energy (0 = pure mono, 0.5 = uncorrelated or a hard-" +
      "panned single channel, 1 = pure anti-phase — width near 1 with negative correlation " +
      "means almost NO mono-compatible content). `balance` is the L/R energy balance " +
      "-1..+1 (-1 = everything left, 0 = centered, +1 = everything right — sustained " +
      "readings far from 0 mean the mix leans to one side). Silence/stopped/mono sessions " +
      "read the stereo floors: correlation +1 (nothing out of phase — honest 'no phase " +
      "problem', never a fake 0), width 0, balance 0; a dead channel (hard-panned mono " +
      "source) also reads correlation +1 because mono-summing it cancels nothing. The " +
      "snapshot refreshes at roughly 30-60 Hz " +
      "while the engine runs; poll it repeatedly (e.g. once a second during playback) to " +
      "watch the mix evolve, and every field is always a finite number. NEEDS LIVE " +
      "PLAYBACK: this reads the master bus AS IT PLAYS, so call transport_play first " +
      "(transport_seek to a marker or beat before that, to meter one section in " +
      "isolation) — if the transport is stopped, this tool refuses with a teaching error " +
      "instead of a reading. The underlying floor (-80 dB bands/levels, centroid 0, flux " +
      "0, correlation +1, width 0, balance 0) is honest data when the mix genuinely is " +
      "that quiet DURING PLAYBACK, but with the transport stopped it is indistinguishable " +
      "from 'no signal was ever generated' — so a stopped transport is refused rather " +
      "than silently handed back as if it were a measurement of your mix. Feeds the app's " +
      "session vibe meter (unaffected by this refusal — it polls the engine directly); as " +
      "an agent, use it to sanity-check a mix's energy, tonal balance, and mono " +
      "compatibility while it plays without rendering anything to disk.",
  },
  async () =>
    toToolResult(async () => {
      const result = await bridge.send("mixer.masterAnalysis");
      // m27-d: refuse when we can PROVE there is no live signal — the
      // transport is not rolling — rather than silently forwarding the
      // honest `.floor` reading, which is indistinguishable from a
      // legitimately quiet mix once it reaches an agent with no other
      // context (docs/ROADMAP.md m27-d). Strict `=== false` so a missing
      // key (an app built before this change shipped `transportPlaying` on
      // this response) is treated as "unknown" and never refused — this
      // refusal only activates once the CONNECTED app binary is new enough
      // to report the field. Any other value (including `true`, i.e.
      // genuinely playing-but-quiet, muted master, or a headless/fake
      // engine that never produces real signal even while "playing")
      // passes the reading through UNCHANGED: those causes are not
      // independently verifiable from here, and this tool must not claim a
      // cause it has not established.
      if (
        result &&
        typeof result === "object" &&
        (result as Record<string, unknown>).transportPlaying === false
      ) {
        throw new Error(
          "the transport is stopped — mixer_master_analysis reads the live master bus, " +
            "and a stopped session reads only its decayed floor (-80 dB bands, 0 Hz " +
            "centroid), not the mix. Call transport_play, let playback run a moment, then " +
            "poll mixer_master_analysis again (transport_seek first to meter a specific " +
            "section)."
        );
      }
      return result;
    })
);

server.registerTool(
  "mixer_live_loudness",
  {
    title: "Read the live loudness meter on the master output",
    description:
      "Read the LIVE loudness meter running on the master output — streaming BS.1770-4 " +
      "loudness of whatever is actually playing right now, measured AFTER the master fader " +
      "(what the listener hears is what is metered). Returns `{momentaryLufs, shortTermLufs, " +
      "maxMomentaryLufs, maxShortTermLufs, integratedLufs, loudnessRangeLu, truePeakDbtp, " +
      "dcOffset, crestFactorDb, secondsAnalyzed}`. `momentaryLufs` is the current 400 ms " +
      "loudness (EBU 3341 'M'), `shortTermLufs` the current 3 s loudness ('S'), with their " +
      "since-reset maxima alongside; `integratedLufs` is the RUNNING gated integrated " +
      "loudness ('I', re-gated over the whole program so far — compare to -14 LUFS " +
      "streaming / -23 LUFS broadcast targets); `loudnessRangeLu` is the running EBU 3342 " +
      "loudness range (LRA, LU — how dynamic the program is; statistically thin under ~1 " +
      "minute, so read it with `secondsAnalyzed`); `truePeakDbtp` is the running 4x " +
      "oversampled true peak in dBTP (keep under -1 for streaming); `dcOffset` (signed " +
      "linear mean, ~0 is healthy) and `crestFactorDb` (sample-peak-to-RMS, low = heavily " +
      "limited) ride along. HONESTY: a missing field means NOT ENOUGH AUDIO ANALYZED YET " +
      "(momentary needs 0.4 s, short-term 3 s, integrated/LRA gated evidence above -70 " +
      "LUFS) — treat absence as 'no evidence', never as zero. The measurement is " +
      "transport-independent: it keeps accumulating across stop/start like a hardware " +
      "meter left running; pass `reset: true` to restart it (the response is then the " +
      "fresh, empty snapshot) — e.g. reset, play the chorus, read again to measure just " +
      "the chorus. Poll it (e.g. once a second) during playback. NOT a substitute for " +
      "render_measure_loudness: that renders offline and is the mastering-grade ground " +
      "truth for a finished mix/bounce; this meter tells you what the live session is " +
      "doing while it plays. Errors with 'audio engine not available' when no live audio " +
      "engine is attached (headless session).",
    inputSchema: {
      reset: z
        .boolean()
        .optional()
        .describe(
          "Optional, default false. true = restart the running measurement (integrated/" +
            "LRA/maxima/true peak/DC/crest all start over) and return the fresh snapshot; " +
            "false/omitted = plain read."
        ),
    },
  },
  async ({ reset }) => toToolResult(() => bridge.send("mixer.liveLoudness", { reset }))
);

// ---------------------------------------------------------------------------
// Reference track (m22-g) — compare the mix against a finished song
// ---------------------------------------------------------------------------

registerTool(
  "reference_import",
  {
    title: "Import a reference track to compare the mix against",
    description:
      "Import an audio file as the project's REFERENCE TRACK — a finished song you trust, " +
      "to compare the mix against. The file is COPIED (never moved) into the app's " +
      "References library, and a one-time analysis runs immediately: loudness (integrated / " +
      "max momentary / max short-term LUFS, true peak dBTP, loudness range LU — the same " +
      "BS.1770 math as render_measure_loudness), a 24-band average spectrum (40 Hz-16 kHz, " +
      "dB, floor -80), and whole-file stereo image (correlation -1..+1, width 0..1, balance " +
      "-1..+1). The reference lives in a dedicated project slot — it is NOT a track, never " +
      "plays in bounces/stems/mixdowns, and travels with the saved .dawproj. A project holds " +
      "ONE reference: importing over an existing slot REPLACES it in a single undoable edit " +
      "(one undo restores the previous reference, analysis included). Returns the slot " +
      "verbatim: `{id, name, path, offsetSeconds, trimDb, analysis?}` — `analysis` is " +
      "omitted (plus a `warnings` array naming the cause) when analysis failed; the slot " +
      "still lands and reference_analyze retries. Errors readably when the file is missing " +
      "or not audio. After importing, play a representative section of your mix and call " +
      "reference_status to see the level-match preview.",
    inputSchema: {
      path: z
        .string()
        .describe(
          "Required. Absolute filesystem path of the audio file to import (WAV/AIFF/MP3/M4A " +
            "— anything CoreAudio reads); ~ expands. The file is copied, never moved."
        ),
      name: z
        .string()
        .optional()
        .describe(
          "Optional display name for the reference (shown in the UI and status). Defaults " +
            "to the file's basename without extension."
        ),
    },
  },
  async ({ path, name }) => toToolResult(() => bridge.send("reference.import", { path, name }))
);

registerTool(
  "reference_remove",
  {
    title: "Remove the reference track",
    description:
      "Remove the project's reference track slot in one undoable edit (undo restores the " +
      "slot with its analysis). The imported audio copy stays on disk — only the project's " +
      "slot is cleared. Returns `{removed: true, name}`. Errors with the teaching message " +
      "'no reference track is loaded — import one with reference.import' when the project " +
      "has no reference.",
    inputSchema: {},
  },
  async () => toToolResult(() => bridge.send("reference.remove"))
);

registerTool(
  "reference_status",
  {
    title: "Read the reference-track slot and level-match preview",
    description:
      "Read the project's reference-track state — read-only, never errors. Returns " +
      "`{reference?, monitoring, wouldMatchGainDb?}`: `reference` is the slot verbatim " +
      "(`{id, name, path, offsetSeconds, trimDb, analysis?}`, with the stored one-time " +
      "analysis — loudness/spectrum/stereo — inside) and is OMITTED when no reference is " +
      "loaded; `monitoring` is the transient A/B monitor state (false until the monitor " +
      "lane ships; never persisted); `wouldMatchGainDb` previews the level-match law — the " +
      "gain in dB that would be applied to the reference so it auditions at the MIX's " +
      "loudness (mix live integrated LUFS, or the -14 LUFS streaming target when the mix " +
      "has no reading yet, minus the reference's integrated, plus the user trim, clamped so " +
      "the reference's true peak never exceeds -1 dBTP) — present only when the slot " +
      "carries a computable analysis. Call this first in any compare workflow: is a " +
      "reference loaded and analyzed?",
    inputSchema: {},
  },
  async () => toToolResult(() => bridge.send("reference.status"))
);

registerTool(
  "reference_analyze",
  {
    title: "Re-run the reference track's one-time analysis",
    description:
      "Re-run the one-time analysis of the project's reference track and store the fresh " +
      "result in the slot (one undoable edit). Use it when an import landed without " +
      "analysis (see the import response's `warnings`), after restoring a missing file, or " +
      "when a newer app version bumped `analyzerVersion`. Returns the fresh analysis " +
      "verbatim: `{integratedLufs?, maxMomentaryLufs?, maxShortTermLufs?, truePeakDbtp?, " +
      "loudnessRangeLu?, bandsDb, correlation, width, balance, durationSeconds, " +
      "sampleRateHz, analyzerVersion}` — `bandsDb` is the 24-band average spectrum " +
      "(40 Hz-16 kHz, dB, floor -80); nil loudness fields are OMITTED and mean the program " +
      "is gated-silent or too short (honest absence, never 0). Errors readably: no " +
      "reference loaded (import one with reference_import), the audio file missing from " +
      "disk (names the path), or no audio engine attached (an analysis is never fabricated).",
    inputSchema: {},
  },
  async () => toToolResult(() => bridge.send("reference.analyze"))
);

registerTool(
  "reference_set_monitor",
  {
    title: "A/B the mix against the reference, level-matched",
    description:
      "Toggle the reference A/B monitor. on=true mutes the MIX at the speakers (post-master-" +
      "chain gate) and auditions the REFERENCE level-matched instead: the match gain is " +
      "computed ONCE at toggle-on — mix live integrated LUFS (or the -14 LUFS streaming " +
      "target when the mix has no reading yet) minus the reference's integrated, plus the " +
      "user trim, clamped so the reference's true peak never exceeds -1 dBTP — and " +
      "snapshotted for the whole audition (louder-sounds-better bias removed; toggle again " +
      "to re-match against a newer mix reading). The reference follows the timeline " +
      "(offset-mapped, latency-aligned); toggling mid-play re-anchors the reference player " +
      "only — the transport and the mix keep rolling. Master meters and mixer_live_loudness " +
      "KEEP reading the MIX while auditioning (the meter tap sits upstream of the gate). " +
      "on=false returns to the mix (idempotent, never errors). Transient state: never " +
      "saved, never undoable, off project_snapshot. Returns `{monitoring, matchGainDb?, " +
      "matchBasis? ('liveIntegrated'|'fallbackTarget'), mixIntegratedLufs?, " +
      "referenceIntegratedLufs?, ceilingLimited?}` — match fields only while on; " +
      "ceilingLimited=true means the gain was reduced to protect the -1 dBTP ceiling. " +
      "Errors readably: no reference (import with reference_import), not analyzed (run " +
      "reference_analyze), gated-silent reference (cannot be level-matched), audio file " +
      "missing (names the path), or no audio engine (a monitor is never faked).",
    inputSchema: {
      on: z
        .boolean()
        .describe(
          "Required. true = audition the reference (mix mutes, level-matched); false = " +
            "back to the mix."
        ),
    },
  },
  async ({ on }) => toToolResult(() => bridge.send("reference.setMonitor", { on }))
);

registerTool(
  "reference_set_offset",
  {
    title: "Set the reference track's timeline offset",
    description:
      "Set the reference's timeline offset in seconds: reference file time = timeline " +
      "seconds + offsetSeconds. Use it to line the reference's chorus/drop up with yours " +
      "(e.g. your chorus at 60 s, the reference's at 45 s -> offset -15). Negative offsets " +
      "defer the reference's start until file time reaches 0. One coalesced undoable edit; " +
      "while monitoring during playback the reference player re-anchors at the newly " +
      "mapped position immediately (player-local — the transport never moves). Returns the " +
      "slot verbatim `{id, name, path, offsetSeconds, trimDb, analysis?}`. Errors with the " +
      "teaching message when no reference is loaded.",
    inputSchema: {
      seconds: z
        .number()
        .describe(
          "Required. Offset in seconds (any sign). Reference file time = timeline seconds " +
            "+ this value."
        ),
    },
  },
  async ({ seconds }) => toToolResult(() => bridge.send("reference.setOffset", { seconds }))
);

registerTool(
  "reference_set_trim",
  {
    title: "Trim the reference's audition level",
    description:
      "Set the user trim in dB (clamped to ±24) applied ON TOP of the automatic level " +
      "match when auditioning the reference. One coalesced undoable edit. While monitoring, " +
      "the match law recomputes against the SNAPSHOTTED toggle-on basis (the gain never " +
      "chases the evolving live reading) and only the gain re-applies — no dropout, no " +
      "re-anchor; the -1 dBTP true-peak ceiling still clamps. Returns the slot verbatim " +
      "(trimDb reveals the clamp) plus `{matchGainDb}` — the re-applied total gain — when " +
      "monitoring. Errors with the teaching message when no reference is loaded.",
    inputSchema: {
      db: z
        .number()
        .describe("Required. Trim in dB, clamped to -24..+24. 0 = pure level match."),
    },
  },
  async ({ db }) => toToolResult(() => bridge.send("reference.setTrim", { db }))
);

registerTool(
  "reference_compare",
  {
    title: "Compare the mix's live numbers against the reference",
    description:
      "Compare the CURRENT MIX against the reference's stored whole-file analysis. Returns " +
      "`{mix, reference, delta}`: mix = `{integratedLufs?, maxTruePeakDbtp?, " +
      "loudnessRangeLu?, width?, correlation?, bandsDb?}` from the live master meters " +
      "(loudness fields are the running gated measurement; bandsDb/width/correlation are " +
      "the RECENT LIVE ballistic reading, NOT a whole-song average — call during steady " +
      "playback of a representative section); reference = the stored analysis verbatim; " +
      "delta = reference − mix per field (`{lufs?, truePeakDb?, lra?, width?, " +
      "correlation?, bandsDb?}`), each omitted when either side lacks evidence — honest " +
      "nils, never fabricated zeros. Reading deltas: delta.lufs +2.1 means your mix is " +
      "2.1 LU QUIETER than the reference; positive low-band bandsDb deltas mean the " +
      "reference carries more low-end energy. Workflow: reference_status -> play a " +
      "representative section -> reference_compare -> suggest concrete moves (EQ bands, " +
      "the built-in limiter for loudness) -> offer reference_set_monitor so the human " +
      "hears the A/B level-matched. Errors readably: no reference, not analyzed, or no " +
      "live meter (headless engine) — deltas are never faked from floor values.",
    inputSchema: {},
  },
  async () => toToolResult(() => bridge.send("reference.compare"))
);

registerTool(
  "audio_profile_file",
  {
    title: "Windowed peak/RMS profile of a file on disk",
    description:
      "Read an ARBITRARY audio file on disk (any absolute path -- not a project track, not " +
      "a clip, not the reference slot) and report SAMPLE peak + RMS per consecutive time " +
      "window, plus a file-header block (duration, sample rate, channel count, on-disk bit " +
      "depth/float-ness -- the ffprobe readback). This answers \"what is the peak level " +
      "between 53s and 54s of this WAV\" -- a WINDOWING question. It is NOT a loudness " +
      "meter and NOT a substitute for one: `peakDb` is the raw inter-sample maximum, NOT " +
      "the 4x-oversampled BS.1770 true peak render_measure_loudness/reference_analyze " +
      "report as `truePeakDbtp` -- a window can read under 0 dBFS sample peak here and " +
      "still exceed 0 dBTP true peak between samples. Use render_measure_loudness (the " +
      "rendered SESSION, before quantization) or reference_analyze (a whole file, occupying " +
      "the project's one reference slot) for LUFS/true-peak questions; use this tool when " +
      "you need to see what a specific stretch of a file on disk actually contains -- e.g. " +
      "verifying a bounce/render landed correctly, or checking exactly where a tail decays " +
      "to silence, without leaving the app. Returns `{durationSeconds, sampleRateHz, " +
      "channelCount, bitDepth?, isFloat?, windows: [{startSeconds, durationSeconds, " +
      "peakDb?, rmsDb?}]}`. The header `durationSeconds` is the WHOLE file, independent of " +
      "any fromSeconds/durationSeconds sub-range requested; `bitDepth`/`isFloat` are " +
      "omitted for formats with no fixed PCM bit depth (compressed codecs) -- never " +
      "fabricated. Each window's own `durationSeconds` is usually the requested " +
      "`windowSeconds`, except the LAST window of the profiled range, which truncates at " +
      "EOF (or at fromSeconds+durationSeconds) and reads shorter -- read it rather than " +
      "assuming every window is the same width. `rmsDb` combines all channels using the " +
      "same rule as `peakDb` (max-abs peak across channels, combined-channel RMS -- " +
      "deliberately never a mono downmix first, which would under-report anti-phase " +
      "content, i.e. a loud-but-opposite-polarity L/R pair). A digitally-silent window " +
      "OMITS `peakDb`/`rmsDb` rather than reporting 0 -- honest absence (JSON has no " +
      "'-infinity dB'), the same convention render_measure_loudness/reference_analyze use " +
      "for gated-silent audio; treat a missing field as silence, never as a number. " +
      "Read-only: never writes anything, never copies the file, and never touches the " +
      "project's reference slot or the References library -- call this as often as you " +
      "like without side effects. Errors readably: no file at path (names the path); no " +
      "audio engine attached (a profile is never fabricated, so this needs the app running).",
    inputSchema: {
      path: z
        .string()
        .describe(
          "Required. Absolute (or ~-prefixed) path to ANY audio file on disk -- not a " +
            "project track, clip id, or the reference slot. Read-only: never copied, " +
            "never modified, never imported anywhere."
        ),
      windowSeconds: z
        .number()
        .gt(0)
        .describe(
          "Required, > 0. Width of each analysis window in seconds -- e.g. 1.0 for one " +
            "peak/RMS reading per second of audio. Smaller windows give finer time " +
            "resolution at the cost of more windows in the response."
        ),
      fromSeconds: z
        .number()
        .min(0)
        .optional()
        .default(0)
        .describe(
          "Start of the profiled range, in seconds from the start of the FILE itself (not " +
            "the project timeline). Must be >= 0. Defaults to 0 (the start of the file). " +
            "Every window's `startSeconds` is an ABSOLUTE file position, so fromSeconds=53 " +
            "with windowSeconds=1 yields windows starting at 53, 54, 55, ..."
        ),
      durationSeconds: z
        .number()
        .gt(0)
        .optional()
        .describe(
          "Length of the profiled range in seconds, starting at fromSeconds. Must be > 0 " +
            "when given. Defaults to the rest of the file (everything from fromSeconds to " +
            "EOF). The final window truncates at this boundary (or at EOF) and reports its " +
            "own, shorter `durationSeconds`."
        ),
    },
  },
  async ({ path, windowSeconds, fromSeconds, durationSeconds }) =>
    toToolResult(() =>
      bridge.send("audio.profileFile", { path, windowSeconds, fromSeconds, durationSeconds })
    )
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

server.registerTool(
  "engine_au_prepare_stats",
  {
    title: "Read how many times plug-ins have been (re)loaded by the audio engine",
    description:
      "Read the audio engine's plug-in LOADING ledger — how many times hosted Audio Unit " +
      "instruments and effects have been prepared (loaded/configured) and released (torn down) " +
      "since the app's engine came up. This is a diagnostic, not a mix control: it never " +
      "changes anything. No params. Returns `{instrumentPrepares, instrumentReleases, " +
      "effectPrepares, effectReleases, tracks: [{trackId, keyDigest?, status?}], effects: " +
      "[{effectId, keyDigest?, status?}]}`. HOW TO USE IT: the four counters only ever go UP " +
      "and there is deliberately NO reset — read them, do the thing you are testing (change " +
      "the output device, change the sample rate, switch a preset, recover from a stall), read " +
      "them again, and SUBTRACT. A difference of exactly 0 is a hard proof that nothing was " +
      "reloaded; that is far stronger than listening for a glitch. `instrumentPrepares` counts " +
      "load ATTEMPTS that actually did work, so a plug-in that failed or was missing still " +
      "counts (a storm of failing loads is the worst kind); repeated no-op passes over an " +
      "unchanged project count nothing. `instrumentReleases` counts only real teardowns of a " +
      "live plug-in instance. Swapping a track's plug-in (or its sample rate) bumps BOTH by " +
      "one; loading a plug-in for the first time bumps only the prepare counter. " +
      "`keyDigest` is a short opaque fingerprint of the exact configuration each track/effect " +
      "was last loaded with — compare it between two reads to see WHICH slot changed, but " +
      "never try to parse or decode it. `status` reads 'pending', 'ready', 'missing' (no such " +
      "plug-in installed) or 'failed: <reason>'; both `keyDigest` and `status` are omitted when " +
      "the engine holds nothing for that slot. The counters survive an engine restart (a " +
      "device change or an automatic stall recovery), so they stay comparable across one; only " +
      "live playback is counted, never an offline bounce. Always safe: read-only, never " +
      "throws, and with no engine (headless) everything reads zero. " +
      "ALSO RETURNS `inFlight`: plug-in loads that have STARTED and not yet finished — " +
      "`[{slot: 'instrument'|'effect', id, component?: {type, subType, manufacturer}, " +
      "startedSecondsAgo, deadlineSeconds, overdue}]`, sorted by (slot, id) and almost always " +
      "empty. This is the ONLY way to find out which plug-in is hanging the app WHILE it is " +
      "hanging it. `overdue: true` means that load has already blown its time budget. " +
      "READ IT CAREFULLY: overdue does NOT mean the plug-in failed (the load keeps running and " +
      "may still succeed), does NOT by itself mean the app is frozen (a load can be slow on a " +
      "busy but perfectly healthy machine — check `mainActor` for that), and says NOTHING about " +
      "audio: sound that is already playing keeps playing even while the UI is frozen. A slot " +
      "that is absent just means no load is in progress for it, not that it is healthy. " +
      "AND `mainActor`: `{responsive: true}` on a normal reply. If the app's UI is frozen you " +
      "get a REDUCED reply instead — `{mainActor: {responsive: false, wedgedForSeconds}, " +
      "inFlight: [...]}` with the four counters and the `tracks`/`effects` arrays OMITTED " +
      "(not zeroed), because those can only be produced by the frozen part of the app and " +
      "reporting stale ones as current would be a lie. Check `mainActor.responsive` to know " +
      "which of the two shapes you got; during a freeze this is one of only two commands that " +
      "answers at all — the other is engine_watchdog_status.",
  },
  async () => toToolResult(() => bridge.send("engine.auPrepareStats"))
);

// ---------------------------------------------------------------------------
// Beta feedback (M9 beta)
// ---------------------------------------------------------------------------

registerTool(
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

server.registerTool(
  "app_connection_info",
  {
    title: "Read the control endpoint this agent is connected through",
    description:
      "Read-only introspection of the LIVE control WebSocket endpoint this bridge reached the " +
      "app on — the bound port, and where that port came from. No params, never throws. Returns " +
      "`{url, port, source, defaultPort}`: `url` is the loopback WebSocket URL (`ws://127.0.0.1:" +
      "<port>`) — the same value the app's Settings > Agent Connection section shows and lets a " +
      "human copy; `port` is the currently bound port; `source` is one of `\"environment\"` (the " +
      "`DAW_CONTROL_PORT` env var overrode everything for this launch — always wins), " +
      "`\"settings\"` (an operator changed the port field in the app's Settings), or `\"default\"` " +
      "(the built-in 17600, untouched); `defaultPort` is that built-in 17600 for reference, so a " +
      "caller can tell at a glance whether the endpoint has been customized. Useful for " +
      "diagnostics (confirming exactly which app instance/port this session is bridged to before " +
      "reporting a bug) and for agents that manage multiple DAW Pro instances or non-default " +
      "setups. The port is deliberately READ-only here: changing it can sever the caller's own " +
      "connection mid-session, so re-pointing the control server stays a human decision in the " +
      "app's Settings, not something this tool can do. " +
      "⭐ ALSO reports this MCP SERVER PROCESS's own build identity (m31-a), separate from the " +
      "app it's bridged to — the two `serverBuildMtime*` fields never touch the app or the wire " +
      "at all, they are computed locally from this process's own file on disk: " +
      "`serverProcessStartedAt` (when THIS process launched), `serverBuildMtimeAtStartup` (the " +
      "mtime of `dist/server.js` captured ONCE, at that launch), and `serverBuildMtimeNow` (the " +
      "SAME file's mtime re-read live, on THIS call). MEASURED: a rebuild landed 6h10m after a " +
      "process launched, and the artifact-side grep check (grep dist/server.js for the new code) " +
      "passed — the process had simply never read the rebuild, and nothing else visible said so. " +
      "`serverBuildMayBeStale` is `true` exactly when `serverBuildMtimeNow` differs from " +
      "`serverBuildMtimeAtStartup` — that disagreement IS the diagnosis: it means a build has " +
      "landed on disk since this process started, and this process is STILL SERVING THE OLD ONE " +
      "(an MCP stdio server only picks up a rebuild on restart, never live). If it reads true, " +
      "the fix is to restart the MCP server process — not just rebuild — and re-call this tool " +
      "to confirm `serverBuildMtimeAtStartup` moved to match. Any field reading `null` means the " +
      "file could not be stat'd (moved/deleted) rather than a hard failure.",
  },
  async () =>
    toToolResult(async () => {
      const connectionInfo = await bridge.send("app.connectionInfo");
      const buildIdentity = {
        serverProcessStartedAt: SERVER_PROCESS_STARTED_AT,
        serverBuildMtimeAtStartup: SERVER_BUILD_MTIME_AT_STARTUP,
        serverBuildMtimeNow: statMtimeIso(SERVER_MODULE_PATH),
      };
      return {
        ...(connectionInfo && typeof connectionInfo === "object" ? connectionInfo : {}),
        ...buildIdentity,
        serverBuildMayBeStale:
          buildIdentity.serverBuildMtimeAtStartup !== null &&
          buildIdentity.serverBuildMtimeNow !== null &&
          buildIdentity.serverBuildMtimeAtStartup !== buildIdentity.serverBuildMtimeNow,
      };
    })
);

// ---------------------------------------------------------------------------
// Composition macros (M7 macro-c)
// ---------------------------------------------------------------------------

const songSkeletonGenreSchema = z
  .enum([
    "pop",
    "house",
    "hip-hop",
    "rock",
    "ballad",
    "blues",
    "jazz",
    "country",
    "r-and-b",
    "funk",
    "metal",
    "folk",
    "reggae",
    "lo-fi",
  ])
  .describe(
    "Which genre skeleton to scaffold — each sets a default tempo and a ready-made track roster. " +
      "⚠️ TRACK KIND MATTERS: every track below is `instrument` (takes MIDI clips) EXCEPT the " +
      "ones marked `[audio]` (takes recordings/imports ONLY — a MIDI clip is rejected with " +
      "'track kind audio cannot host an instrument'). This is NOT only a vocal-track thing: " +
      "`lo-fi` has no vocal at all and STILL carries two `[audio]` tracks (Samples, Vinyl FX) — " +
      "notably, `lo-fi`'s \"Samples\" track is audio-only and canNOT host the Sampler instrument " +
      "(the Sampler goes on an INSTRUMENT track; use track_add kind=instrument for a sample-" +
      "playback part, or clip_add_audio on the roster's \"Samples\" track for actual audio " +
      "recordings/loops). Check the `[audio]` tags below before writing a MIDI clip to a roster " +
      "track by name. " +
      "`pop` (120 BPM): Drums, Bass (bass-tight preset), Keys (warm-keys), Lead, Vocals [audio] " +
      "(vocal-presence). `house` (124 BPM): Drums, Bass (bass-tight), Synth, Pads (warm-keys), " +
      "FX [audio]. " +
      "`hip-hop` (90 BPM): Drums, 808 Bass (bass-tight), Samples [audio], Lead, Vocals [audio] " +
      "(vocal-presence). " +
      "`rock` (140 BPM): Drums, Bass (bass-tight), Rhythm Guitar, Lead Guitar, Vocals [audio] " +
      "(vocal-presence). `ballad` (72 BPM): Piano (warm-keys), Strings, Bass (bass-tight), " +
      "Vocals [audio] (vocal-presence). `blues` (84 BPM): Drums (drum-room), Bass (bass-round), " +
      "Rhythm Guitar, Lead Guitar (guitar-crunch), Organ (warm-keys), Vocals [audio] " +
      "(vocal-presence) — and a genuine TWELVE-BAR form (Intro 4, Head 12, Verse 12, Solo 12, " +
      "Verse 12, Outro 4). " +
      "`jazz` (132 BPM): Drums (drum-room), Upright Bass (bass-round), Piano (warm-keys), Horn " +
      "(horn-section), Guitar — ALL instrument, a combo with no vocal track, in head/solos/head " +
      "form with 32-bar choruses. `country` (100 BPM): Drums (drum-bus-glue), Bass (bass-round), " +
      "Acoustic Guitar (acoustic-sparkle), Electric Guitar, Pedal Steel, Vocals [audio] " +
      "(vocal-presence). " +
      "`r-and-b` (88 BPM): Drums (drum-bus-glue), Bass (bass-round), Keys (warm-keys), Pads, Lead " +
      "Vocal [audio] (vocal-presence), Backing Vocals [audio] — with a Pre-Chorus in the form. " +
      "`funk` (108 BPM): Drums (drum-bus-glue), Bass (bass-tight — funk's bass wants the clamp), " +
      "Rhythm Guitar, Clavinet (warm-keys), Horns (horn-section), Vocals [audio] (vocal-presence), " +
      "with 16-bar verses and a Breakdown. `metal` (170 BPM): Drums (drum-bus-glue), Bass " +
      "(bass-tight), Rhythm Guitar L and Rhythm Guitar R (both guitar-crunch, for the hard-panned " +
      "double-track), Lead Guitar (guitar-crunch), Vocals [audio] (vocal-presence). " +
      "`folk` (96 BPM): Acoustic Guitar (acoustic-sparkle), Vocals [audio] (vocal-presence), Bass " +
      "(bass-round), Fiddle, Percussion. `reggae` (76 BPM): Drums (drum-bus-glue), Bass " +
      "(bass-round), Skank Guitar, Organ (warm-keys), Vocals [audio] (vocal-presence), with a Dub " +
      "Break. " +
      "`lo-fi` (78 BPM): Drums (lofi-tape), Bass (bass-round), Keys (warm-keys), Samples [audio] " +
      "(lofi-tape), Vinyl FX [audio] — NO vocal track, a loop-based form (Intro, Loop A, Loop B, " +
      "Loop A, Outro) rather than verse/chorus. " +
      "Instrument tracks host built-in instruments (including the Sampler) and take MIDI clips; " +
      "`[audio]` tracks take recordings or imports only. Named mixer presets are applied to the " +
      "strips shown in parentheses. " +
      "If none of these fits, keep the nearest `genre` and pass your own `tracks` roster and " +
      "`sections` — both override the genre's defaults outright, and there you choose `kind` " +
      "explicitly instead of reading it off this list."
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

const songSkeletonTrackSchema = z
  .object({
    name: z
      .string()
      .min(1)
      .max(40)
      .describe("Track name, e.g. \"Drums\", \"Rhodes\", \"Lead Vocal\" (1-40 characters)."),
    kind: z
      .enum(["instrument", "audio"])
      .describe(
        "\"instrument\" hosts a built-in instrument and takes MIDI clips (use it for every playable part); " +
          "\"audio\" takes recordings and imported files. Skeletons never create buses — add one afterwards with track_add if you need it."
      ),
    mixerPreset: z
      .string()
      .optional()
      .describe(
        "Optional mixer preset applied to this strip as a fresh insert chain, by name (see mixer_apply_preset " +
          "for the catalog — e.g. \"bass-tight\", \"vocal-presence\", \"warm-keys\"). Omit for an empty chain. " +
          "An unknown name is a field-named error listing every valid preset."
      ),
  })
  .describe("One roster track: a name, its kind, and an optional mixer preset.");

registerTool(
  "macro_song_skeleton",
  {
    title: "Scaffold a whole song: tempo, tracks, sections, and loop in one step",
    description:
      "Scaffold a working session for a genre in ONE undoable step. Sets the tempo, adds the genre's " +
      "named tracks (instrument and audio, with curated mixer presets pre-applied where noted), lays " +
      "the song's sections out as named EMPTY MIDI clips on a dedicated instrument \"Arrangement\" " +
      "guide track (each clip positioned back-to-back: its start = the running sum of prior section " +
      "lengths, its length = bars x 4 beats), DROPS A REAL SESSION MARKER at every section start " +
      "(so marker_list returns the song's beat map immediately — you do NOT have to lay the section " +
      "map by hand or re-derive it for a later composer/mix step; each marker is named exactly like " +
      "its section, repeats included, so disambiguate by beat, and each is addressable by " +
      "marker_rename / marker_move / marker_remove), and enables the loop region over the whole " +
      "arrangement " +
      "(start 0 to the total length). This is ADDITIVE — it never wipes the project: everything is " +
      "appended to whatever is already there (use project_new first if you want a clean slate), and " +
      "markers that already existed survive, merged into beat order. A " +
      "single edit_undo reverts the ENTIRE scaffold at once. Pass `genre` (required) to use its " +
      "defaults, or override the tempo with `tempoBPM` (20-400), the layout with `sections`, and/or " +
      "the track roster with `tracks`. `tracks` replaces THE GENRE ROSTER ONLY: the \"Arrangement\" " +
      "guide track is ALWAYS added last, with its section clips and markers, no matter what you pass " +
      "— you cannot suppress, reorder, or displace it (and a roster track of your own named " +
      "\"Arrangement\" is allowed, it just sits in the roster with the real guide track after it). " +
      "`genre` stays required even with a full roster override — it supplies the default tempo. " +
      "An unknown genre returns an error listing every valid genre; a bad tempo, section, or roster " +
      "track is a " +
      "field-named error. Returns `{genre, tempoBPM, tracks: [{id, name}], sectionClips: [{name, " +
      "startBeat, lengthBeats}], markers: [{id, name, beat}], loopStart, loopEnd, " +
      "arrangementTrackId}` with real ids — `tracks` " +
      "lists every created track (the roster then the Arrangement track last), and `markers` lists " +
      "just the ones this call created (marker_list returns the whole project's).",
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
      tracks: z
        .array(songSkeletonTrackSchema)
        .min(1)
        .max(24)
        .optional()
        .describe(
          "Optional custom track roster (1-24 tracks), replacing the genre's default roster. Tracks are " +
            "created in the order given, each {name, kind, mixerPreset?}. The \"Arrangement\" guide track " +
            "is ALWAYS appended after this roster regardless — the section clips and beat-map markers are " +
            "what this macro exists for, so an override can never remove or move them. Omit to use the " +
            "genre's default roster."
        ),
    },
  },
  async ({ genre, tempoBPM, sections, tracks }) =>
    toToolResult(() => bridge.send("macro.songSkeleton", { genre, tempoBPM, sections, tracks }))
);

// ---------------------------------------------------------------------------
// Automation
// ---------------------------------------------------------------------------

const automationTargetSchema = z
  .discriminatedUnion("type", [
    // `.strict()` on each discriminated-union member (m30-c): closes the
    // same per-element hole for automation_add_lane's `target` — a typo'd
    // field (e.g. "sendld") would otherwise be silently stripped instead of
    // rejected. `.strict()` still returns a ZodObject, so discriminatedUnion
    // accepts it unchanged.
    z
      .object({
        type: z.literal("volume").describe("Automate the track's fader volume (linear gain multiplier)."),
      })
      .strict(),
    z
      .object({
        type: z.literal("pan").describe("Automate the track's pan position."),
      })
      .strict(),
    z
      .object({
        type: z
          .literal("sendLevel")
          .describe("Automate one send's level (see `sendId`). Rejected in v0 — no render path yet."),
        sendId: z
          .string()
          .min(1)
          .describe("Id of the send to automate, from track_add_send's result or project_snapshot."),
      })
      .strict(),
    z
      .object({
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
      })
      .strict(),
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
      "compressor, limiter, reverb, delay, saturator, gate, chorus, bassEnhancer, " +
      "bitCrusher) work today. " +
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
})
  // `.strict()` (m30-c): closes the same per-element hole for
  // automation_set_points's `points` array — a typo'd field (e.g. "vlaue")
  // would otherwise be silently stripped instead of rejected.
  .strict();

registerTool(
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
      "own description). " +
      "MASTER VOLUME: pass `trackId` as the exact string \"master\" (m15-c) to automate the " +
      "whole mix's master output volume instead of a track. The master lane accepts the " +
      "`volume` target ONLY — a `pan`, `sendLevel`, or `effectParam` target on \"master\" is " +
      "rejected with a readable error (those lanes live on tracks — pass a track UUID). A " +
      "master volume lane is how you draw a final fade-out/fade-in or a level ride across the " +
      "whole mix; it applies PRE-limiter (the fade feeds the master insert chain, so the " +
      "limiter rides ABOVE the fade — the professionally-correct order). WHAT RENDERS IT: " +
      "render_mixdown and render_bounce DO bake the master fade — it lands in the " +
      "deliverable, and you do NOT need to rebuild it as per-track lanes. render_stems " +
      "deliberately EXCLUDES it (a fade is master performance, not material — baking it into " +
      "every stem would destroy the re-mixable partition), and that exclusion also covers " +
      "render_stems{includeMixdown}, whose file is confusingly named \"00 Mixdown.wav\" but " +
      "is NOT a render_mixdown — use render_stems{includeMasteredMixdown} (\"00 Mastered " +
      "Mix.wav\"), which DOES carry the fade. " +
      "MIND THE WINDOW: a render's DEFAULT length comes from CLIP extents alone (+ a " +
      "fixed 2.0 s tail) and never from automation, so points drawn past the last clip " +
      "need an explicit render `durationSeconds` covering them or they are cut off. " +
      "The master lane rides project_snapshot's top-level `masterAutomation` " +
      "array (same lane shape), absent when empty. " +
      "Returns `{lane: {id, target, points, isEnabled}}`.",
    inputSchema: {
      trackId: z
        .string()
        .min(1)
        .describe(
          "Id of the track to add the lane to, from project_snapshot, OR the exact string " +
            "\"master\" for the whole-mix master volume lane (the `volume` target only there)."
        ),
      target: automationTargetSchema,
    },
  },
  async ({ trackId, target }) => toToolResult(() => bridge.send("automation.addLane", { trackId, target }))
);

registerTool(
  "automation_remove_lane",
  {
    title: "Remove an automation lane",
    description:
      "Permanently delete an automation lane — and the curve drawn into it — from a " +
      "track by id. Reversible with edit_undo. Pass `trackId` as the exact string " +
      "\"master\" (m15-c) to delete the whole-mix master VOLUME lane instead of a track lane.",
    inputSchema: {
      trackId: z
        .string()
        .min(1)
        .describe(
          "Id of the track that owns the lane, from project_snapshot, OR the exact string " +
            "\"master\" for the master volume lane."
        ),
      laneId: z
        .string()
        .min(1)
        .describe(
          "Id of the lane to remove, from project_overview's per-track `automation[].id`, " +
            "project_snapshot, or automation_add_lane's result."
        ),
    },
  },
  async ({ trackId, laneId }) =>
    toToolResult(() => bridge.send("automation.removeLane", { trackId, laneId }))
);

registerTool(
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
      "inert. " +
      "MASTER: pass `trackId` as the exact string \"master\" (m15-c) to draw the whole-mix " +
      "master VOLUME curve — a final fade or level ride; values clamp to 0-2 (the master " +
      "fader range) exactly like a track volume lane. The master fade applies pre-limiter, and " +
      "it IS baked into render_mixdown and render_bounce (it lands in the deliverable). Only " +
      "render_stems excludes it — including that call's \"00 Mixdown.wav\", which despite the " +
      "name is a stem-class file; \"00 Mastered Mix.wav\" carries the fade. " +
      "MIND THE WINDOW: a render's DEFAULT length comes from CLIP extents alone (+ a " +
      "fixed 2.0 s tail) and never from automation, so points drawn past the last clip " +
      "need an explicit render `durationSeconds` covering them or they are cut off. " +
      "Returns `{lane: {id, target, points, isEnabled}}` with the lane exactly as " +
      "stored (reordered/clamped/capped).",
    inputSchema: {
      trackId: z
        .string()
        .min(1)
        .describe(
          "Id of the track that owns the lane, from project_snapshot, OR the exact string " +
            "\"master\" for the master volume lane."
        ),
      laneId: z
        .string()
        .min(1)
        .describe(
          "Id of the lane to edit, from project_overview's per-track `automation[].id`, " +
            "project_snapshot, or automation_add_lane's result."
        ),
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

registerTool(
  "automation_set_lane_enabled",
  {
    title: "Enable or disable an automation lane",
    description:
      "Toggle a lane between READ (its drawn curve drives the target — the default " +
      "after automation_add_lane) and MANUAL (the target follows its ordinary control " +
      "instead, e.g. track_set_volume/track_set_pan for a `volume`/`pan` lane; the " +
      "drawn curve is left untouched and simply ignored while disabled, so re-enabling " +
      "restores it exactly). Use this to A/B a drawn automation move without deleting " +
      "it. Never touches the lane's points. Pass `trackId` as the exact string \"master\" " +
      "(m15-c) to toggle the whole-mix master VOLUME lane between its drawn fade and the " +
      "manual master fader. Returns `{lane: {id, target, points, isEnabled}}`.",
    inputSchema: {
      trackId: z
        .string()
        .min(1)
        .describe(
          "Id of the track that owns the lane, from project_snapshot, OR the exact string " +
            "\"master\" for the master volume lane."
        ),
      laneId: z
        .string()
        .min(1)
        .describe(
          "Id of the lane to toggle, from project_overview's per-track `automation[].id`, " +
            "project_snapshot, or automation_add_lane's result."
        ),
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

registerTool(
  "render_mixdown",
  {
    title: "Render (bounce) the session to a WAV file",
    description:
      "Bounce the current session to a stereo 48 kHz WAV file, rendered offline " +
      "— much faster than realtime and without needing audio hardware or " +
      "realtime playback. Returns `{path, durationSeconds, sampleRate, " +
      "channels}`; use the returned absolute `path` to reference the bounced " +
      "audio afterwards (e.g. to import it elsewhere or ship it as a " +
      "deliverable). Pass `excludeTrackIds` to bounce an INSTRUMENTAL / " +
      "minus-vocal version — the full session with those tracks silenced for " +
      "this render only, leaving the project itself completely untouched. " +
      "Errors only if the render range holds no clips at all — " +
      "of ANY kind, audio or MIDI — and no explicit `durationSeconds` was " +
      "given, since there would be nothing to render and no way to infer a " +
      "render length. " +
      "MASTER MOVES ARE INCLUDED: the master fader, the master insert chain, " +
      "and any MASTER VOLUME AUTOMATION LANE (a fade-out/fade-in or level " +
      "ride) are all baked into this file, as is every per-track automation " +
      "lane. You do NOT need to rebuild a master fade as per-track lanes to " +
      "make it survive. (Only render_stems excludes master moves — including " +
      "its \"00 Mixdown.wav\", which despite the name is a stem-class file " +
      "and is NOT what this tool produces.) " +
      "BUT ONLY WITHIN THE RENDER WINDOW, and the DEFAULT window is computed " +
      "from CLIP extents alone (+ a fixed 2.0 s tail) — automation extent is " +
      "never consulted. So anything drawn past the last clip, or ringing " +
      "longer than 2.0 s after it (a long fade-out, a reverb/delay tail), is " +
      "CUT OFF unless you pass a `durationSeconds` that covers it.",
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
            "tempo — through the end of the last clip of ANY kind, audio or " +
            "MIDI — plus a 2.0 s tail (the same default window as " +
            "render_bounce, render_measure_loudness, and render_stems)."
        ),
      excludeTrackIds: z
        .array(z.string().min(1))
        .optional()
        .describe(
          "Ids of tracks to SILENCE for this render only — e.g. pass the lead " +
            "vocal's track id to get an instrumental / minus-vocal mix (ids " +
            "come from project_snapshot). The whole session still renders, at " +
            "full length and with plugin-delay compensation intact; only these " +
            "tracks are gated to silence. The PROJECT IS NOT MODIFIED: its own " +
            "mute/solo flags, its unsaved-changes state and its undo history " +
            "are left exactly as they were, so this is safe to call while " +
            "someone is working in the app — never mute/bounce/un-mute by hand. " +
            "Know what leaves with an excluded track: everything it feeds a " +
            "SEND leaves too, so its reverb/delay TAIL disappears (that is what " +
            "makes the instrumental genuinely clean, and it equally means you " +
            "CANNOT ask for 'instrumental but keep the vocal's reverb' here), " +
            "and so does its sidechain key signal, so a compressor ducking to " +
            "that vocal stops ducking. Its solo flag leaves with it as well, so " +
            "excluding the only soloed track gives the instrumental rather than " +
            "silence. An unknown id is an error. The result echoes the silenced " +
            "names in `excludedTracks`."
        ),
      bitDepth: z
        .union([z.literal(16), z.literal(24), z.literal(32)])
        .optional()
        .describe(
          "Bit depth of the written file: 16 (CD / small files), 24 (the " +
            "standard delivery depth for mixes and stems) or 32 (integer). " +
            "OMIT IT unless you have a reason — the default is 32-bit FLOAT, " +
            "which is lossless, is what the engine renders internally, and is " +
            "the only choice that preserves peaks above 0 dBFS. Every integer " +
            "depth CLAMPS at full scale, and the loudness numbers in the " +
            "response describe the buffer BEFORE quantization, so a render " +
            "that peaks above 0 dBFS will be clipped on disk without the " +
            "report saying so — normalize first (lufsTarget/truePeakCeilingDb) " +
            "or stay on the default. Quantization is undithered in v0 and the " +
            "response says so (`ditherApplied: false`). Echoed back as " +
            "`bitDepth` only when you asked for one."
        ),
      container: z
        .enum(["wav", "aiff"])
        .optional()
        .describe(
          "File container: 'wav' (default) or 'aiff'. The FILE EXTENSION is " +
            "what actually selects the container, so the extension of `path` " +
            "is made to agree with this — always use the `path` the response " +
            "returns rather than the one you sent. AIFF is written in the " +
            "AIFF-C form (big-endian, uncompressed) that macOS produces; every " +
            "DAW reads it. Echoed back as `container` only when you asked for " +
            "a non-default one."
        ),
    },
  },
  async ({ path, fromBeat, durationSeconds, excludeTrackIds, bitDepth, container }) =>
    toToolResult(() =>
      bridge.send("render.mixdown", {
        path,
        fromBeat,
        durationSeconds,
        excludeTrackIds,
        bitDepth,
        container,
      })
    )
);

registerTool(
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
      "instead of a number — usually that means the program sits at or below " +
      "the -70 LUFS absolute silence gate (JSON has no value for '-infinity " +
      "dB'); treat a missing field as gated silence, not zero. The " +
      "WINDOWED fields have a second, independent omission reason: a program " +
      "shorter than the window has no value at all — 400 ms for " +
      "maxMomentaryLufs, 3 s for maxShortTermLufs and loudnessRangeLu — so " +
      "on a short excerpt those can be absent while integratedLufs and " +
      "truePeakDbtp are perfectly healthy numbers. " +
      "Returns `{measurement: {integratedLufs?, truePeakDbtp?, " +
      "maxMomentaryLufs?, maxShortTermLufs?, loudnessRangeLu?}, " +
      "durationSeconds, sampleRate}`. `loudnessRangeLu` is EBU Tech 3342 " +
      "loudness range in LU — the 95th-minus-10th percentile spread of the " +
      "gated short-term loudness distribution, i.e. how much the loudness " +
      "MOVES rather than where it sits. It is the same figure " +
      "reference_analyze reports under the same name, so a mix and a " +
      "reference track are directly comparable on it. " +
      "Errors if the project has no clips in the requested window and no " +
      "explicit `durationSeconds` was given. " +
      "TWO THINGS THIS TOOL IS NOT. (1) It measures a FRESH RENDER OF THE " +
      "SESSION, never a file on disk — it cannot take a `path` (passing one is " +
      "a hard error), so it verifies the MIX, not the artifact a render_bounce/" +
      "render_mixdown wrote. To check a file that already exists, use " +
      "audio_profile_file (windowed sample peak/RMS + real header — proves a " +
      "bounce isn't silence-padded and where the tail decays) or, for true " +
      "BS.1770 LUFS of a file, reference_import (which analyzes on import, but " +
      "copies the file, occupies the project's single reference slot, and lands " +
      "as an undoable edit). (2) A WINDOWED measurement is not an excerpt of the " +
      "full render: a MIDI note whose note-ON falls BEFORE `fromBeat` is dropped " +
      "entirely from the render (no note-on and no note-off), so measuring a " +
      "window that starts mid-note reports gated silence for a passage that " +
      "sounds perfectly fine from the top. A straddling AUDIO clip does NOT " +
      "behave this way — it is entered mid-file and sounds. So an unexpectedly " +
      "silent window over sustained MIDI (pads, held strings, long tails) is " +
      "far more likely to be this scheduling rule than a real hole in your " +
      "arrangement: re-measure from beat 0, or from the start of the clip in " +
      "question, before reporting silence. Note the MIXED UNITS in one call: " +
      "`fromBeat` is BEATS, `durationSeconds` is SECONDS, and there is no " +
      "beat-range form.",
    inputSchema: {
      fromBeat: z
        .number()
        .min(0)
        .optional()
        .default(0)
        .describe(
          "Timeline position, in BEATS (quarter notes), to start measuring " +
            "from. Must be >= 0. Defaults to 0 (the very start of the timeline). " +
            "A non-zero value does NOT give you an excerpt of the whole render: " +
            "MIDI notes already sounding at this beat (note-on earlier) are " +
            "omitted from the render entirely, so a window starting mid-note " +
            "under-reports, sometimes as total silence. Measure from 0 when the " +
            "number has to be trustworthy."
        ),
      durationSeconds: z
        .number()
        .gt(0)
        .optional()
        .describe(
          "How many SECONDS of audio to measure (not beats — this tool mixes " +
            "units deliberately), starting at fromBeat. Must " +
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

registerTool(
  "render_bounce",
  {
    title: "Bounce the session to a loudness-measured, optionally normalized WAV",
    description:
      "Render the session offline to a stereo 48 kHz WAV and report its " +
      "loudness — the measured/normalizing sibling of render_mixdown (which " +
      "stays the raw, fast bounce with no loudness report and no gain). " +
      "Like render_mixdown, this BAKES IN every master move: the master " +
      "fader, the master insert chain, and any MASTER VOLUME AUTOMATION LANE " +
      "— a fade-out lands in the bounce and needs no per-track workaround. " +
      "It lands only WITHIN THE RENDER WINDOW, though, and the DEFAULT window " +
      "comes from CLIP extents alone (+ a fixed 2.0 s tail), never from " +
      "automation: a fade or tail extending past the last clip is CUT OFF " +
      "unless you pass a `durationSeconds` that covers it. " +
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
      "⚠️ `report.limitedByCeiling` DOES NOT TELL YOU WHETHER THE CLAMP ACTUALLY " +
      "COST YOU LOUDNESS — it reads `true` in BOTH a near-miss and a bounce that " +
      "landed far under target; the field that discriminates is `report.output." +
      "integratedLufs` against your `lufsTarget`. ⚠️ ADDING A MASTER LIMITER DOES " +
      "NOT FIX A SHORTFALL BY ITSELF (MEASURED: with a limiter at truePeak/" +
      "ceilingDb -1 already on the master chain, a bounce still landed -18.34 " +
      "LUFS against a -14 target, appliedGainDb 3.90, limitedByCeiling true — " +
      "unchanged). MECHANISM: this tool's normalizing gain is applied AFTER the " +
      "whole master insert chain, and its clamp is computed from the POST-chain " +
      "true peak — so a limiter sitting later in that same chain has nothing " +
      "left to protect; it never sees the un-normalized signal at a level where " +
      "clamping would bite less. What actually works is putting a `gain` insert " +
      "at the FRONT of the master chain, index 0, AHEAD of the limiter (fx_add " +
      "with trackId \"master\", kind \"gain\", same move mixer_set_master_volume's " +
      "own description recommends past its +6 dB ceiling) — MEASURED: gainLinear " +
      "2.5 ahead of the limiter landed -14.83 LUFS / -1.0000 dBTP, on target. " +
      "`report.input` is the " +
      "pre-gain measurement; `report.output` is RE-MEASURED from the gained " +
      "audio (never derived from input + gain), so it is ground truth for " +
      "the file written to disk. Any loudness field — in either input or " +
      "output — can come back OMITTED (null): that means the signal sits " +
      "at/below the -70 LUFS silence gate. A gated-silent program WITH a " +
      "requested `lufsTarget` errors (there is nothing to normalize toward); " +
      "silence without a target still succeeds, with all-null " +
      "measurements. Pass `excludeTrackIds` to bounce an INSTRUMENTAL / " +
      "minus-vocal version — the full session with those tracks silenced for " +
      "this render only, project untouched; note that normalization then " +
      "measures the instrumental's OWN loudness, not the full mix's, so a " +
      "mix and its instrumental normalized to the same target end up at the " +
      "same LUFS as each other rather than at the same relative level. " +
      "Returns `{path, durationSeconds, sampleRate, " +
      "channels, report: {input, output, appliedGainDb, lufsTarget?, " +
      "truePeakCeilingDbtp, limitedByCeiling}, excludedTracks?}`.",
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
      excludeTrackIds: z
        .array(z.string().min(1))
        .optional()
        .describe(
          "Ids of tracks to SILENCE for this render only — e.g. pass the lead " +
            "vocal's track id to get an instrumental / minus-vocal mix (ids " +
            "come from project_snapshot). The whole session still renders, at " +
            "full length and with plugin-delay compensation intact; only these " +
            "tracks are gated to silence. The PROJECT IS NOT MODIFIED: its own " +
            "mute/solo flags, its unsaved-changes state and its undo history " +
            "are left exactly as they were, so this is safe to call while " +
            "someone is working in the app — never mute/bounce/un-mute by hand. " +
            "Know what leaves with an excluded track: everything it feeds a " +
            "SEND leaves too, so its reverb/delay TAIL disappears (that is what " +
            "makes the instrumental genuinely clean, and it equally means you " +
            "CANNOT ask for 'instrumental but keep the vocal's reverb' here), " +
            "and so does its sidechain key signal, so a compressor ducking to " +
            "that vocal stops ducking. Its solo flag leaves with it as well, so " +
            "excluding the only soloed track gives the instrumental rather than " +
            "silence. An unknown id is an error. The result echoes the silenced " +
            "names in `excludedTracks`."
        ),
      bitDepth: z
        .union([z.literal(16), z.literal(24), z.literal(32)])
        .optional()
        .describe(
          "Bit depth of the written file: 16 (CD / small files), 24 (the " +
            "standard delivery depth for mixes and stems) or 32 (integer). " +
            "OMIT IT unless you have a reason — the default is 32-bit FLOAT, " +
            "which is lossless, is what the engine renders internally, and is " +
            "the only choice that preserves peaks above 0 dBFS. Every integer " +
            "depth CLAMPS at full scale, and the loudness numbers in the " +
            "response describe the buffer BEFORE quantization, so a render " +
            "that peaks above 0 dBFS will be clipped on disk without the " +
            "report saying so — normalize first (lufsTarget/truePeakCeilingDb) " +
            "or stay on the default. Quantization is undithered in v0 and the " +
            "response says so (`ditherApplied: false`). Echoed back as " +
            "`bitDepth` only when you asked for one."
        ),
      container: z
        .enum(["wav", "aiff"])
        .optional()
        .describe(
          "File container: 'wav' (default) or 'aiff'. The FILE EXTENSION is " +
            "what actually selects the container, so the extension of `path` " +
            "is made to agree with this — always use the `path` the response " +
            "returns rather than the one you sent. AIFF is written in the " +
            "AIFF-C form (big-endian, uncompressed) that macOS produces; every " +
            "DAW reads it. Echoed back as `container` only when you asked for " +
            "a non-default one."
        ),
    },
  },
  async ({
    path,
    fromBeat,
    durationSeconds,
    lufsTarget,
    truePeakCeilingDb,
    excludeTrackIds,
    bitDepth,
    container,
  }) =>
    toToolResult(() =>
      bridge.send("render.bounce", {
        path,
        fromBeat,
        durationSeconds,
        lufsTarget,
        truePeakCeilingDb,
        excludeTrackIds,
        bitDepth,
        container,
      })
    )
);

registerTool(
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
      "settings as every stem, handy for verifying the sum yourself. Pass " +
      "`includeMasteredMixdown: true` for a SEPARATE, additional `00 " +
      "Mastered Mix.wav` — the real mastered mix (full session THROUGH the " +
      "master effect chain, master automation and master fader, exactly what " +
      "render_bounce produces), optionally loudness-normalized via " +
      "`masteredLufsTarget`. That mastered file is a SIBLING of the stems, " +
      "never a version of them: 'mastered stems' in the sense of printing " +
      "the shared master chain onto each stem individually is deliberately " +
      "NOT offered, because a nonlinear master chain (a compressor, limiter " +
      "or saturator) does not distribute over the stems — the individually " +
      "processed stems would no longer add back up to the actual mix. So you " +
      "get true pre-master stems that sum exactly, PLUS the mastered mix as " +
      "its own file, which is how a mastering/mixing handoff is normally " +
      "packaged. `includeMixdown` and `includeMasteredMixdown` are " +
      "independent: the first is the chain-EXCLUDED sum reference, the " +
      "second is the chain-INCLUDED deliverable, and you can ask for both. " +
      "Files " +
      "are named `NN Name.wav` (1-based partition order, sanitized, " +
      "collision-suffixed with ' 2', ' 3', ...). Returns `{directory, " +
      "sampleRate, durationSeconds, channels, stems: [{trackId, name, " +
      "kind: \"track\"|\"bus\", path, measurement}], mixdown?: {path, " +
      "measurement}, masteredMixdown?: {path, report}}`. Errors if " +
      "`trackIds` names a track that is routed " +
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
            "same window as the stems, for spot-checking the sum. This file is " +
            "the stems' own reference: like the stems, it EXCLUDES the master " +
            "effect chain and master automation, which is exactly why the " +
            "stems sum to it. Defaults to false."
        ),
      // Deliberately `.optional()` WITHOUT `.default(false)`, unlike its
      // `includeMixdown` twin above: a defaulted flag is always present in the
      // outgoing params, so an app build older than m23-m1 would see an
      // unknown key and reject the whole call. Omitting it keeps the default
      // request byte-identical to what every shipped app already accepts; the
      // app's own default is false either way.
      includeMasteredMixdown: z
        .boolean()
        .optional()
        .describe(
          "If true, also write `00 Mastered Mix.wav` alongside the stems: the " +
            "real MASTERED mix — the whole session through the master effect " +
            "chain, master automation lane and master fader, identical to what " +
            "render_bounce produces. Independent of `includeMixdown` (that one " +
            "is the chain-EXCLUDED sum reference; this one is the " +
            "chain-INCLUDED deliverable) — ask for either, both, or neither. " +
            "The stems themselves are unaffected either way: they stay " +
            "pre-master and keep summing to `00 Mixdown.wav`. Defaults to false."
        ),
      masteredLufsTarget: z
        .number()
        .min(-70)
        .max(0)
        .optional()
        .describe(
          "Integrated-loudness target in LUFS (-70 to 0) for the mastered " +
            "mix ONLY — the stems are never normalized. -14 is the common " +
            "streaming convention, -23 is EBU R128 broadcast. Applies the " +
            "same single static, true-peak-clamped gain render_bounce " +
            "applies, and the returned `masteredMixdown.report` says what was " +
            "actually achieved. Requires `includeMasteredMixdown: true` " +
            "(passing it without that is an error rather than a silent no-op). " +
            "Omit for a measured but un-normalized mastered mix."
        ),
      masteredTruePeakCeilingDb: z
        .number()
        .min(-20)
        .max(0)
        .optional()
        .describe(
          "True-peak ceiling in dBTP (-20 to 0, default -1.0) that the " +
            "mastered mix's normalizing gain will never push past. Clamps the " +
            "gain rather than limiting the audio, exactly like render_bounce's " +
            "`truePeakCeilingDb`. Requires `includeMasteredMixdown: true`."
        ),
      bitDepth: z
        .union([z.literal(16), z.literal(24), z.literal(32)])
        .optional()
        .describe(
          "Bit depth of the written file: 16 (CD / small files), 24 (the " +
            "standard delivery depth for mixes and stems) or 32 (integer). " +
            "OMIT IT unless you have a reason — the default is 32-bit FLOAT, " +
            "which is lossless, is what the engine renders internally, and is " +
            "the only choice that preserves peaks above 0 dBFS. Every integer " +
            "depth CLAMPS at full scale, and the loudness numbers in the " +
            "response describe the buffer BEFORE quantization, so a render " +
            "that peaks above 0 dBFS will be clipped on disk without the " +
            "report saying so — normalize first (lufsTarget/truePeakCeilingDb) " +
            "or stay on the default. Quantization is undithered in v0 and the " +
            "response says so (`ditherApplied: false`). Echoed back as " +
            "`bitDepth` only when you asked for one."
        ),
      container: z
        .enum(["wav", "aiff"])
        .optional()
        .describe(
          "File container: 'wav' (default) or 'aiff'. Applies to EVERY file of " +
            "the set — the stems and any `00 Mixdown` / `00 Mastered Mix` " +
            "sibling — since they have to sum; their names carry the matching " +
            "extension, so read the returned `path`s rather than assuming " +
            "'.wav'. AIFF is written in the AIFF-C form (big-endian, " +
            "uncompressed) that macOS produces; every DAW reads it. Echoed " +
            "back as `container` only when you asked for a non-default one."
        ),
    },
  },
  async ({
    trackIds,
    directory,
    fromBeat,
    durationSeconds,
    includeMixdown,
    includeMasteredMixdown,
    masteredLufsTarget,
    masteredTruePeakCeilingDb,
    bitDepth,
    container,
  }) =>
    toToolResult(() =>
      bridge.send("render.stems", {
        trackIds,
        directory,
        fromBeat,
        durationSeconds,
        includeMixdown,
        includeMasteredMixdown,
        masteredLufsTarget,
        masteredTruePeakCeilingDb,
        bitDepth,
        container,
      })
    )
);

registerTool(
  "track_bounce_in_place",
  {
    title: "Bounce a track to a new audio track (commit it to audio)",
    description:
      "Render ONE track offline and land the result as a brand-new audio " +
      "track + clip, in a single undo step. This 'commits' a track to plain " +
      "audio: reach for it to freeze a software-instrument part into a WAV " +
      "so it always plays the same and frees the CPU that instrument was " +
      "using, to lock in an effect-heavy chain before an edit, or to prep a " +
      "clean stem for exchange with someone else. The bounce is the track's " +
      "own dry, post-fader signal, rendered under the full-session " +
      "plugin-delay compensation exactly like render_stems for that track — " +
      "in fact the file is byte-identical to `render_stems {trackIds:[id]}` " +
      "over the same window, and is NEVER loudness-normalized. Eligibility " +
      "matches render_stems: the target must be a MASTER INPUT (a track " +
      "routed directly to master, or a bus). A track routed INTO a bus has " +
      "no stem of its own and errors with stemNotMasterInput (bounce the bus " +
      "instead); an unknown id errors, and a session with no clips in the " +
      "window errors with nothing-to-render. By default the SOURCE track is " +
      "muted (muteSource=true) so the bounce replaces it in the mix rather " +
      "than doubling it — pass muteSource=false to keep the original audible " +
      "alongside the bounce. This is a plain render-and-land, NOT a " +
      "reversible freeze: undo removes the new track+clip and un-mutes the " +
      "source, but the rendered file stays on disk (undo un-references it, it " +
      "does not delete media). Returns `{track, clip, file, sourceTrackId, " +
      "sourceMuted, measurement}` where `track`/`clip` are the new objects, " +
      "`file` is the WAV path, and `measurement` is the same un-normalized " +
      "loudness report a render_stems stem carries.",
    inputSchema: {
      trackId: z
        .string()
        .min(1)
        .describe(
          "Id of the track (or bus) to bounce — a master input (see " +
            "project_snapshot). A track routed into a bus cannot be bounced " +
            "directly; bounce the bus instead."
        ),
      fromBeat: z
        .number()
        .min(0)
        .optional()
        .default(0)
        .describe(
          "Timeline position, in beats (quarter notes), to start rendering " +
            "from. Must be >= 0. Defaults to 0 (the very start). The landed " +
            "clip is placed at this beat."
        ),
      durationSeconds: z
        .number()
        .gt(0)
        .optional()
        .describe(
          "How many seconds to render, starting at fromBeat. Must be > 0. " +
            "When omitted, defaults to the same window as render_stems: the " +
            "extent of every track's clips at the current tempo, plus a 2.0 s " +
            "tail."
        ),
      muteSource: z
        .boolean()
        .optional()
        .default(true)
        .describe(
          "Mute the source track after bouncing so the new audio replaces it " +
            "in the mix (recommended, and the default). Pass false to keep " +
            "the original track audible alongside the bounce."
        ),
      name: z
        .string()
        .min(1)
        .optional()
        .describe(
          "Optional name for the new audio track and its clip. Defaults to " +
            "'<source name> (Bounced)'."
        ),
    },
  },
  async ({ trackId, fromBeat, durationSeconds, muteSource, name }) =>
    toToolResult(() =>
      bridge.send("track.bounceInPlace", { trackId, fromBeat, durationSeconds, muteSource, name })
    )
);

// ---------------------------------------------------------------------------
// Project files
// ---------------------------------------------------------------------------

registerTool(
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
      "warnings, discardedRecovery?}` — `discardedRecovery` (m16-e) appears " +
      "ONLY when this save just cleared a pending crash-recovery offer " +
      "(see project_recovery_status): saving supersedes it, since the work " +
      "is now safely on disk. If the project has any voice-converted " +
      "tracks, the response also carries `voicesEmbedded`, `voiceBytes` and " +
      "`voiceBytesCopied`: a save embeds a copy of each voice those tracks " +
      "were made with (about 80 MB each) so the project stays " +
      "re-convertible on another machine. `voiceBytesCopied` is what THIS " +
      "save actually wrote — 0 on a re-save, since the copies are already " +
      "there. Those keys are absent entirely for a project with no " +
      "converted tracks. See project_embedded_voices for the full picture. " +
      "Cannot save while recording.",
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

registerTool(
  "project_open",
  {
    title: "Open a .dawproj bundle",
    description:
      "Open a .dawproj bundle, replacing the current session entirely. " +
      "Unless `discardChanges` is true, unsaved changes in the current " +
      "session are automatically saved first — to its existing file, or to " +
      "a recovery bundle if the current session was never saved (untitled) " +
      "— before the new project is opened. Returns `{warnings, snapshot, " +
      "discardedRecovery?}`: `warnings` lists any media files the project " +
      "references but that are missing on disk; `snapshot` is the full new " +
      "session state (same shape as project_snapshot); `discardedRecovery` " +
      "(m16-e) appears ONLY when opening this project just cleared a " +
      "pending crash-recovery offer (see project_recovery_status) — opening " +
      "another project supersedes it. Refuses while recording. Refuses to " +
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

registerTool(
  "project_new",
  {
    title: "Start a new empty session",
    description:
      "Start a fresh, empty, untitled session, replacing the current one. " +
      "Unless `discardChanges` is true, unsaved changes in the current " +
      "session are automatically saved first — to its existing file, or to " +
      "a recovery bundle if it was never saved. Returns the new (empty) " +
      "session snapshot (same shape as project_snapshot), plus an additive " +
      "`discardedRecovery` field (m16-e) that appears ONLY when this call " +
      "just cleared a pending crash-recovery offer (see " +
      "project_recovery_status) — a fresh session supersedes it, and this " +
      "is the offer's own facts echoed back so nothing is lost silently. " +
      "Refuses while recording.",
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
      "is when the snapshot was last written, as an ISO-8601 string (e.g. " +
      "\"2026-07-15T09:41:00Z\"); `sourcePath` is the .dawproj file the crashed " +
      "session was editing (absent for a never-saved/untitled session); `editCount` is how many " +
      "edits the snapshot captured. When `available` is false there is nothing to restore. Safe " +
      "to call anytime; never modifies the session. Follow up with project_recover to accept or " +
      "discard the offer. This describes the ONE rolling crash-recovery snapshot only — see " +
      "project_recovery_bundles for the separate per-session untitled-recovery bundles.",
    inputSchema: {},
  },
  async () => toToolResult(() => bridge.send("project.recoveryStatus", {}))
);

server.registerTool(
  "project_recovery_bundles",
  {
    title: "List recoverable per-session untitled-project snapshots",
    description:
      "List the per-session 'untitled recovery' bundles the app writes whenever a DIRTY, " +
      "never-saved (untitled) session is abandoned via project_new / project_open (m16-e, audit " +
      "F3) — distinct from the single rolling crash-recovery snapshot project_recovery_status " +
      "describes. Each entry is an ordinary .dawproj bundle already directly openable with " +
      "project_open — this tool exists ONLY because nothing else on the wire names where these " +
      "live, so without it they are invisible even though they are on disk. Returns `{bundles: " +
      "[{path, savedAt, isCurrentSession}]}`, newest first: `path` is the absolute .dawproj " +
      "bundle path (pass straight to project_open); `savedAt` is an ISO-8601 timestamp (the " +
      "bundle's file modification time); `isCurrentSession` flags the ONE entry (if any) that is " +
      "THIS running app's own in-progress safety copy, not a past session's abandoned work — " +
      "recovering that one is unnecessary (it is the current session). Never errors; reads an " +
      "empty list if nothing has been abandoned yet.",
    inputSchema: {},
  },
  async () => toToolResult(() => bridge.send("project.recoveryBundles", {}))
);

registerTool(
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

registerTool(
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
    inputSchema: {},
  },
  async () => toToolResult(() => bridge.send("edit.undo"))
);

registerTool(
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
    inputSchema: {},
  },
  async () => toToolResult(() => bridge.send("edit.redo"))
);

server.registerTool(
  "edit_history",
  {
    title: "Read the undo / redo history",
    description:
      "Read the full labeled undo and redo history in one call — the backing " +
      "for the app's history panel. No params. Returns `{undo: [string], " +
      "redo: [string], canUndo: boolean, canRedo: boolean}`. Both lists are " +
      "NEWEST-FIRST: `undo[0]` is the label edit_undo would revert NEXT, and " +
      "each later item is a progressively OLDER edit; `redo[0]` is the label " +
      "edit_redo would reapply NEXT, and each later item was undone EARLIER. " +
      "Empty lists mirror canUndo/canRedo === false (nothing to undo/redo). " +
      "This is READ-ONLY and adds no new way to change the project: to STEP to " +
      "a specific point in history, call edit_undo repeatedly to reach undo[i] " +
      "(i+1 calls) or edit_redo repeatedly to reach redo[j] (j+1 calls) — the " +
      "same one-step-at-a-time path the panel and Cmd-Z use, so recording " +
      "guards and edit coalescing still apply. Richer than " +
      "project_snapshot's single `undoLabel`/`redoLabel` (which show only the " +
      "top of each stack).",
  },
  async () => toToolResult(() => bridge.send("edit.history"))
);

registerTool(
  "edit_paste_clips",
  {
    title: "Paste the app's clipboard as clips",
    description:
      "Paste whatever CLIPS are currently on the DAW APP'S OWN clipboard — " +
      "the same clipboard Cmd-C/Cmd-V use in the arrange view. This tool " +
      "cannot PUT anything on that clipboard: there is no wire route to " +
      "populate it, so a call only fires whatever the human user last " +
      "copied in the app itself; if nothing has been copied (or the last " +
      "copy was cleared by a later cut/copy elsewhere), there is nothing " +
      "to paste. `trackId` is optional and overrides the destination for " +
      "THIS paste only, without moving the app's own paste cursor — omit " +
      "it to land on the same resolved active track a bare Cmd-V would " +
      "use. One call is one undo step, reversible with edit_undo. The " +
      "response NAMES which of four outcomes happened rather than a bare " +
      "ok/fail, because 'nothing happened' has three different causes an " +
      "agent needs to react to differently: (1) success — " +
      "`{pasted:true, landings:[{clipId,trackId,startBeat}], skipped:[" +
      "{sourceClipId,clipName,reason}], trimmedClipIDs:[string], " +
      "removedClipIDs:[string]}` (`skipped`/`trimmedClipIDs`/" +
      "`removedClipIDs` are usually empty — they only fill in when some " +
      "pasted clips overlapped and had to be trimmed, removed, or dropped " +
      "to make room, per the same placement policy Cmd-V uses); (2) " +
      "`{pasted:false, reason:\"empty-clipboard\"}` — nothing has been " +
      "copied yet; ask the user to copy a clip first, retrying will not " +
      "help; (3) `{pasted:false, reason:\"wrong-payload-kind\", " +
      "clipboardKind:\"notes\"}` — the clipboard holds copied MIDI NOTES " +
      "(from inside the piano roll), not clips; there is no note-paste " +
      "wire route, so read them with clip_get_notes and write them with " +
      "clip_set_notes instead; (4) `{pasted:false, reason:<string>, " +
      "skipped:[...]}` — the app deliberately refused the paste (e.g. no " +
      "track can hold the payload, or every copied clip individually " +
      "mismatched its destination, such as a MIDI clip landing on an " +
      "audio track); `skipped` names each refused clip and why. Errors " +
      "(distinct from all four outcomes above) only when this control " +
      "session has no app UI attached (a headless session) — start " +
      "DAWPro.app and retry.",
    inputSchema: {
      trackId: z
        .string()
        .uuid()
        .optional()
        .describe(
          "Track to paste into, from project_snapshot. Overrides the " +
            "resolved active track for THIS paste only. Omit to use the " +
            "same active-track resolution a bare Cmd-V would use."
        ),
      atBeat: z
        .number()
        .optional()
        .describe(
          "Project beat to anchor the paste on. The EARLIEST copied clip " +
            "lands here and the rest keep their offsets from it. Overrides " +
            "the transport playhead for THIS paste only and does NOT move " +
            "the playhead. Omit to anchor on the playhead, exactly as a " +
            "bare Cmd-V does. A negative value slides the whole group to " +
            "beat 0 rather than erroring."
        ),
    },
  },
  async ({ trackId, atBeat }) =>
    toToolResult(() => bridge.send("edit.pasteClips", { trackId, atBeat }))
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
      "order = processing order) of `{id, kind, bypassed, params, latencySamples, " +
      "gainReductionDb?}` " +
      "(`latencySamples` is the processing delay that effect adds, in samples — 0 for " +
      "most kinds; `limiter`'s lookahead adds some). `gainReductionDb` (m22-e) is the " +
      "LIVE gain-reduction meter of the built-in dynamics kinds — compressor, limiter, " +
      "gate — in POSITIVE dB of reduction (0 = currently untouched; a fully closed gate " +
      "caps at 80): held-peak with a −20 dB/s release, so a poll can't miss a brief " +
      "clamp. Poll this snapshot while audio plays to SEE how hard a compressor is " +
      "working (e.g. aim ~3-6 dB on a vocal); the key is ABSENT on kinds that don't " +
      "measure gain reduction, on bypassed-and-idle chains running headless, and on " +
      "hosted AU effects — never fabricated. The same field rides `masterEffects` " +
      "entries and every fx_* mutation result. Chains are capped at " +
      "16 entries — see fx_add/fx_remove/fx_reorder/fx_set_bypass/fx_set_param " +
      "to edit it and fx_describe for each kind's parameter names/ranges/units. " +
      "May also include `masterAutomation` (m15-c): the whole-mix master VOLUME " +
      "automation lanes as a top-level `[{id, target, points, isEnabled}]` array (same " +
      "lane shape as a track's, driven by automation_add_lane/_set_points/_set_lane_" +
      "enabled/_remove_lane with `trackId: \"master\"`) — ABSENT when there is no master " +
      "lane; the master fade it draws is pre-limiter, IS baked into render_mixdown and " +
      "render_bounce, and is excluded only from render_stems (see automation_add_lane). " +
      "May also include `engineNotices` (m15-e): a top-level array of schedule-time " +
      "DEGRADATION reports — cases where playback proceeded on time but not exactly as " +
      "the project describes (e.g. a fade or gain envelope that couldn't be prepared in " +
      "time so the clip played without it, or a clip still time-stretching that played as " +
      "silence). Each entry is `{code, message, beat, count, lastAt}`: `code` is a stable " +
      "machine key naming the degradation family (the current ones are " +
      "`clip-fades-skipped`, `clip-envelope-skipped`, `clip-stretch-pending`) that events " +
      "are COALESCED by — a recurrence increments `count` and refreshes the entry rather " +
      "than appending; `message` is a human-readable description naming the clip; `beat` " +
      "is the affected clip's start beat (may be null); `count` is how many times this " +
      "code has occurred; `lastAt` is a monotonic sequence token (bigger = more recent, " +
      "NOT a wall-clock time) for ordering. The notices are SESSION-TRANSIENT diagnostics: " +
      "never saved to disk, not touched by undo/redo, and CLEARED on project_new / " +
      "project_open. The KEY IS ABSENT when there are no notices — its absence means " +
      "playback has been healthy, so poll it after transport_play to check whether " +
      "anything sounded off. " +
      "MIDI clips (from " +
      "clip_add_midi) carry a `notes` array (pitch, velocity, startBeat relative " +
      "to the clip, lengthBeats); audio clips do not. MIDI clips may also carry a " +
      "`controllerLanes` array (m16-b) — mod wheel, sustain, pitch bend, and other " +
      "performance controller data set via clip_set_controller_lane/clip_remove_" +
      "controller_lane, ridden ALONGSIDE `notes` on the same clip. KEY IS ABSENT when " +
      "the clip has no controller data. Each entry is `{type: {type: \"cc\"|" +
      "\"pitchBend\"|\"channelPressure\", controller?}, points: [{beat, value}]}` — " +
      "note the NESTED `type` object here, unlike the flat `type`/`controller` params " +
      "clip_set_controller_lane/clip_remove_controller_lane take as input. Also includes a " +
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
      "is `{volume, peakDb?, rmsDb?}` (`volume` is linear gain, 0-2, 1 = " +
      "unity; the two level fields are the MASTER BUS's, with exactly the " +
      "same meaning, floor and omit-when-never-heard rule as the per-track " +
      "ones described below — read them as the REFERENCE the track levels sit " +
      "against, which is what turns \"the kick is -14 dBFS\" into \"the kick " +
      "is 8 dB under the master\"). `tracks` is an array of " +
      "`{id, name, kind, muted, soloed, armed, volume, pan, output?, " +
      "instrument?, sends, fx, clips, automation, peakDb?, rmsDb?}` — `id` is the FULL uuid " +
      "(use it verbatim in follow-up commands like track_set_volume or " +
      "clip_move; there is no id-shortening machinery on this path). " +
      "`output` is the destination bus track's id, omitted for master. " +
      "`instrument` is the hosted instrument's display name, present only on " +
      "instrument tracks (it resolves to the default poly synth even when " +
      "unconfigured), omitted on audio/bus tracks. `sends` is each " +
      "`{destinationBusID, level, preFader}` (preFader is always false today " +
      "— v0 sends are post-fader only). `fx` is each `{id, name, bypassed}` in " +
      "chain order (use fx_describe or project_snapshot for actual parameter " +
      "values). That `id` is the ADDRESSABLE effect id — pass it straight to " +
      "fx_set_param / fx_set_bypass / fx_reorder / fx_remove. It means you can " +
      "tune a chain you INHERITED (from a mixer preset, a genre skeleton, or " +
      "another agent) without calling fx_add first purely to make the ids " +
      "appear in a reply — reading no longer requires writing. `clips` " +
      "summarizes every clip as `{id, name, startBeat, " +
      "lengthBeats, kind: \"audio\"|\"midi\", noteCount?, takeLaneCount?, " +
      "activeLane?, hasStretch?, hasFades?, gainDb?}` — COUNTS, never the " +
      "actual MIDI notes, and no file paths (fetch a clip's real note data or " +
      "source file via project_snapshot/clip tools when you need it). " +
      "`automation` summarizes every lane as `{id, target, enabled, " +
      "pointCount}` — never the breakpoints themselves. That `id` is the " +
      "ADDRESSABLE lane id — pass it straight to automation_set_points / " +
      "automation_set_lane_enabled / automation_remove_lane. Exactly like the " +
      "effect ids above, it means you can drive a lane you INHERITED without " +
      "calling automation_add_lane first purely to make its id appear in a " +
      "reply — reading no longer requires writing. (MASTER volume lanes are " +
      "not carried here; read their ids from project_snapshot's top-level " +
      "`masterAutomation`, which has always included them.) " +
      "`peakDb`/`rmsDb` are LEVELS in " +
      "dBFS (floor -80, always finite; a POSITIVE peakDb means it clipped), " +
      "carried BOTH per-track and on `master` — this is how you compare " +
      "loudness between tracks, and against the mix as a whole, without " +
      "paying for project_snapshot. They report the last frame that track (or " +
      "the master bus) was actually HEARD producing and are RETAINED after " +
      "the transport stops, so you can read them between actions; play the " +
      "session (or a section) once and they stay readable afterwards. The " +
      "keys are OMITTED wherever nothing has produced sound this " +
      "session — absent means \"no signal observed\", which is deliberately " +
      "different from a measured silence, so do not read a missing peakDb as " +
      "-80. Note they describe what the ENGINE played, not a rendered file: " +
      "use render_measure_loudness for gated LUFS/dBTP on a bounce. Every " +
      "optional field is simply " +
      "omitted when it doesn't apply (never emitted as null), which is what " +
      "keeps the payload small.",
  },
  async () => toToolResult(() => bridge.send("project.overview"))
);

server.registerTool(
  "project_embedded_voices",
  {
    title: "See which voice models this project carries",
    description:
      "Report the voice-conversion models this project carries, what they " +
      "cost on disk, and whether each one is usable on THIS machine. No " +
      "params. This is the answer to \"why is my project 240 MB\": a " +
      "converted vocal track records WHICH VOICE made it, and every save " +
      "embeds a copy of exactly those voices (about 80 MB each) inside the " +
      ".dawproj bundle so the project stays self-contained and " +
      "re-convertible on another machine. Returns `{projectPath, " +
      "embeddedBytes, orphanedVoiceIds, voices: [{voiceId, voiceName, " +
      "tracks, embeddedInProject, embeddedBytes, installedLocally, " +
      "note}]}`. `installedLocally` is the one to read before converting " +
      "again: it means a copy is in this machine's voice store, where the " +
      "conversion engine looks. `orphanedVoiceIds` names voices still in " +
      "the bundle that no track uses any more (a save never deletes media, " +
      "so deleting a converted track leaves its voice behind) — that is " +
      "where unexplained size usually comes from. NOTHING HERE IS AN " +
      "ERROR: a voice that exists nowhere is a normal state — the converted " +
      "audio is ordinary audio and still plays; only converting AGAIN with " +
      "that voice is unavailable, and the per-voice `note` says so in plain " +
      "words you can pass straight to the user. Everything is read live " +
      "from the project and the filesystem, so it can never be stale. To " +
      "make a carried voice usable here, call vc_install_embedded_voice.",
  },
  async () => toToolResult(() => bridge.send("project.embeddedVoices"))
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

registerTool(
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
    inputSchema: {},
  },
  async () => toToolResult(() => bridge.send("ai.sidecarStart"))
);

registerTool(
  "ai_sidecar_stop",
  {
    title: "Stop the local ACE-Step song-generation sidecar",
    description:
      "Stop the local ACE-Step-1.5 sidecar to free the memory/GPU its " +
      "loaded models hold (tens of GB — useful before a demanding DAW " +
      "session). Graceful SIGTERM, escalating to a forced kill if it " +
      "doesn't exit promptly, and the child process the sidecar spawned " +
      "is stopped with it — that child is where the loaded models' memory " +
      "actually lives. The target is resolved from the sidecar's pidfile " +
      "when that points at a live process, and otherwise from whichever " +
      "process holds the listening socket on the sidecar's port, so a " +
      "stale pidfile no longer hides a running sidecar. No params. " +
      "Succeeds as a no-op (not an error) if it genuinely wasn't running. " +
      "ERRORS — rather than reporting success — if the sidecar is still " +
      "answering its health check afterwards, or if the only process " +
      "found on its port cannot be identified as ACE-Step (it is never " +
      "signalled in that case); the error message says what is still up " +
      "and what to run. On success returns the same `{state, message, " +
      "version?, ditModel?, lmModel?, pid?}` shape as ai_sidecar_status " +
      "(state settles to `installedNotRunning`).",
    inputSchema: {},
  },
  async () => toToolResult(() => bridge.send("ai.sidecarStop"))
);

// ---------------------------------------------------------------------------
// Model lifecycle (m23-dl)
// ---------------------------------------------------------------------------
//
// One read and one verb over BOTH local sidecars at once. ⚠️ Read this before
// writing an agent policy around them: **DAW Pro does not check memory before
// loading a model.** An earlier design gated boots on available RAM and refused
// when a model would not fit; the user removed that on 2026-08-05 — if a model
// does not fit, the load fails the way it always did. So there is no `force`
// flag anywhere, and nothing below will ever say "not enough memory". What DOES
// happen automatically: booting one model unloads the other first, a model whose
// last job finished ten minutes ago is unloaded, and everything is unloaded when
// DAW Pro quits.

server.registerTool(
  "ai_model_residency",
  {
    title: "See which local AI models are loaded and what they hold",
    description:
      "Which local model sidecars are loaded right now, how much memory each " +
      "is holding, and what would happen if you started one. Use this before " +
      "and after any load/unload — it is the read that makes the others " +
      "checkable.\n\n" +
      "⚠️ READ THIS BEFORE BUILDING A POLICY ON THE NUMBERS: **DAW Pro does " +
      "not check memory before loading a model.** Every byte figure here is " +
      "reporting, never a gate — nothing will refuse a load because it would " +
      "not fit, and there is no `force` flag anywhere to override such a " +
      "refusal. If a model does not fit, the load fails. What DOES happen " +
      "automatically: starting one model unloads the other first, ACE-Step " +
      "unloads itself ten idle minutes after its last generation job finishes, " +
      "and quitting DAW Pro unloads everything.\n\n" +
      "Returns `{generation, sampledAt, memory, policy, inFlight?, models[]}`. " +
      "`generation` is a counter that moves on EVERY residency change: two " +
      "reads with the same value describe the same world, and an unload that " +
      "did not move it did not happen. `memory.availableBytes` is what " +
      "Activity Monitor calls free (total minus \"Memory Used\"), for the whole " +
      "machine, in BYTES.\n\n" +
      "Per model: `resident` (true = DAW Pro booted it and is tracking it), " +
      "`holdBytes` + `holdConfidence` (`measured` = observed on this machine, " +
      "`estimated` = derived from on-disk size and could be wrong in either " +
      "direction), `activeJobs` (a model with a job running is NEVER unloaded " +
      "automatically), `idleUnloadSeconds` (600 for ACE-Step, null for the " +
      "voice-conversion sidecar, which has no idle timer), `idleUnloadAt` (when " +
      "the idle unload will fire, or null if none is armed), and " +
      "`nextBootWouldUnload` — what starting THIS model would unload first.\n\n" +
      "⚠️ The response key is `modelID` (capital ID, the model's own field " +
      "name); the PARAMETER on ai_model_unload is `modelId`. Both are live and " +
      "neither is a typo.\n\n" +
      "⚠️ `resident: false` does NOT mean nothing is loaded: a sidecar someone " +
      "started outside DAW Pro still holds its memory. Pass " +
      "`includeProcessDetail: true` to also get `portBusy` (something really is " +
      "listening on that model's port), `pids`, `treeResidentBytes` and " +
      "`treeFootprintBytes`. That flag costs two helper-process spawns per " +
      "model, so leave it off when polling.",
    inputSchema: {
      includeProcessDetail: z
        .boolean()
        .optional()
        .describe(
          "Also inspect the real processes: portBusy, pids and per-tree memory. " +
            "Costs a `ps` and an `lsof` spawn per model — off by default, and " +
            "you should keep it off if you are polling."
        ),
    },
  },
  async ({ includeProcessDetail }) =>
    toToolResult(() =>
      bridge.send(
        "ai.modelResidency",
        includeProcessDetail === undefined ? {} : { includeProcessDetail }
      )
    )
);

registerTool(
  "ai_model_unload",
  {
    title: "Unload a local AI model and prove it actually stopped",
    description:
      "Unload one local model sidecar, or all of them, and get EVIDENCE that " +
      "it stopped rather than a bare success. Use it to hand back the memory a " +
      "loaded model holds — ACE-Step's song-generation models measure about " +
      "80 GB on the machine this was built on, which is why the sidecar is " +
      "worth unloading between sessions.\n\n" +
      "Pass exactly ONE of `modelId` (\"ace-step\" or \"rvc\") or `all: true`. " +
      "Both, or neither, is an error that lists the valid ids.\n\n" +
      "\"Unloaded\" means three things had to be true, and if any one of them " +
      "is false this tool ERRORS instead of reporting success: the model's " +
      "port is free, its health check no longer answers, and no process from " +
      "the tree captured before the signal is still alive. `memoryReturnedBytes` " +
      "and `memoryVerdict` (`returned`/`partial`/`inconclusive`/`notAHold`) are " +
      "reported alongside, but they never decide the outcome — system memory is " +
      "a shared, noisy number and gating on it would report failures that did " +
      "not happen.\n\n" +
      "You usually do NOT need this: starting the other model unloads this one, " +
      "ACE-Step unloads itself ten idle minutes after its last job finishes, and " +
      "quitting DAW Pro unloads everything. A model with a generation job " +
      "running is never unloaded automatically — but this tool WILL stop it, so " +
      "check `activeJobs` in ai_model_residency first. Returns `{generation, " +
      "models: [{modelID, reason, stopped, detail, evidence}]}` — note the " +
      "response key is `modelID` with a capital ID while the parameter is " +
      "`modelId`.",
    inputSchema: {
      modelId: z
        .string()
        .min(1)
        .optional()
        .describe(
          "Which model to unload: \"ace-step\" (song generation) or \"rvc\" " +
            "(voice conversion). Mutually exclusive with `all`."
        ),
      all: z
        .boolean()
        .optional()
        .describe(
          "Unload every local model sidecar. Mutually exclusive with `modelId`."
        ),
    },
  },
  async ({ modelId, all }) =>
    toToolResult(() => {
      const params: Record<string, unknown> = {};
      if (modelId !== undefined) params.modelId = modelId;
      if (all !== undefined) params.all = all;
      return bridge.send("ai.modelUnload", params);
    })
);

// ---------------------------------------------------------------------------
// Voice-conversion sidecar (m10-p-3)
// ---------------------------------------------------------------------------
//
// A SECOND, SEPARATE local sidecar (a Python FastAPI facade over the pinned
// Acelogic/Retrieval-based-Voice-Conversion-MLX fork, on 127.0.0.1:8002,
// loopback only — see scripts/rvc/README.md) — additive alongside the
// ai_sidecar_* trio above, which is untouched. Same shape/discipline as
// ai_sidecar_status/start/stop (thin passthroughs over bridge.send, never a
// direct provider HTTP call): process lifecycle only. The convert/train pair
// (vc_convert_vocals/vc_train_voice, m10-p-4) is registered right after this
// trio, below. Policy note carried in every description in both groups:
// the product supports third-party voice models, and the USER is
// responsible for having the rights to any voice they train or convert
// with; none of this implies a product-compatibility claim about the
// underlying engine. m23-n2d retargeted this from a prohibition — the user
// explicitly WITHDREW the old own-voice-only rule; do not reintroduce it.

server.registerTool(
  "vc_sidecar_status",
  {
    title: "Check the local voice-conversion sidecar",
    description:
      "Check the status of the local RVC voice-conversion sidecar — the " +
      "offline engine that will convert vocals to a voice the user trained " +
      "or supplied (the user is responsible for having the rights to it; " +
      "training arrives with a later roadmap item — this tool is " +
      "lifecycle/health only for now). No params. Always succeeds (never " +
      "throws) and returns one of five states: `notInstalled` (run " +
      "scripts/rvc/install.sh first), `installedNotRunning` (call " +
      "vc_sidecar_start), `starting` (a vc_sidecar_start call is in " +
      "flight — poll again shortly), `healthy` (ready — `version`/`engine`/" +
      "`baseModelPresent`/`voiceCount` report what's loaded; `voiceCount` " +
      "is 0 until a voice has been trained), or `error` (the sidecar " +
      "responded but unexpectedly — check scripts/rvc/runtime/logs/" +
      "rvc-facade.log). Returns `{state, message, version?, engine?, " +
      "baseModelPresent?, voiceCount?, pid?}` — `message` is always a " +
      "human-actionable next step, never a bare code. This is a SEPARATE " +
      "sidecar from ai_sidecar_status (song generation) — call this before " +
      "vc_sidecar_start to avoid an unnecessary spawn attempt, and after " +
      "it to confirm readiness.",
  },
  async () => toToolResult(() => bridge.send("vc.sidecarStatus"))
);

registerTool(
  "vc_sidecar_start",
  {
    title: "Start the local voice-conversion sidecar",
    description:
      "Start the local RVC voice-conversion sidecar (spawns " +
      "scripts/rvc/run.sh, a FastAPI facade bound to 127.0.0.1:8002 only) " +
      "if it isn't already healthy, then waits for it to report ready. No " +
      "params — safe to call even if it's already starting or healthy " +
      "(idempotent: a healthy sidecar returns immediately, a boot already " +
      "in flight is simply observed). Errors with an actionable message if " +
      "the sidecar was never installed (points at scripts/rvc/install.sh) " +
      "or if the process exits during startup (points at the log). A slow " +
      "load is NOT an error — if the health check doesn't succeed within " +
      "the startup timeout, this still returns ok with `state: " +
      "\"starting\"`; call vc_sidecar_status again a little later rather " +
      "than retrying vc_sidecar_start. Returns the same `{state, message, " +
      "version?, engine?, baseModelPresent?, voiceCount?, pid?}` shape as " +
      "vc_sidecar_status.",
    inputSchema: {},
  },
  async () => toToolResult(() => bridge.send("vc.sidecarStart"))
);

registerTool(
  "vc_sidecar_stop",
  {
    title: "Stop the local voice-conversion sidecar",
    description:
      "Stop the local RVC voice-conversion sidecar to free the memory its " +
      "loaded voice models hold. Graceful SIGTERM, escalating to a forced " +
      "kill if it doesn't exit promptly. The target is resolved from the " +
      "sidecar's pidfile when that points at a live process, and otherwise " +
      "from whichever process holds the listening socket on the sidecar's " +
      "port, so a stale pidfile no longer hides a running sidecar. No " +
      "params. Succeeds as a no-op (not an error) if it genuinely wasn't " +
      "running. ERRORS — rather than reporting success — if the sidecar is " +
      "still answering its health check afterwards, or if the only process " +
      "found on its port cannot be identified as the RVC facade (it is " +
      "never signalled in that case); the error message says what is still " +
      "up and what to run. On success returns the same `{state, message, " +
      "version?, engine?, baseModelPresent?, voiceCount?, pid?}` shape as " +
      "vc_sidecar_status (state settles to `installedNotRunning`).",
    inputSchema: {},
  },
  async () => toToolResult(() => bridge.send("vc.sidecarStop"))
);

// ---------------------------------------------------------------------------
// Voice conversion pipeline (m10-p-4)
// ---------------------------------------------------------------------------
//
// The convert/train pair the trio above deferred. `vc_convert_vocals` BLOCKS
// (the facade's convert endpoint is synchronous, unlike ACE-Step's async job
// queue) — start the sidecar first (vc_sidecar_start), then call this
// directly; there is no separate poll/import step, the result is already
// landed as a new track + clip when this returns. `vc_train_voice` always
// answers a reserved "not yet available" error today (training ships with a
// later roadmap item) — call it anyway if asked; the error IS the honest
// answer. RIGHTS-RESPONSIBILITY POLICY (every description below carries
// this): the product supports third-party voice models, and the USER is
// responsible for having the rights to any voice they train or convert
// with. This pair implies no product-compatibility claim about the
// underlying engine. m23-n2d retargeted this from a prohibition — the
// user explicitly WITHDREW the old own-voice-only rule, so do not
// reintroduce it here or in any description below.

registerTool(
  "vc_convert_vocals",
  {
    title: "Convert vocals to a voice",
    description:
      "Convert an existing vocal recording to a target voice with the local " +
      "RVC voice-conversion sidecar. BLOCKS until the conversion finishes " +
      "(no separate poll/import step — unlike generate_song, this is a " +
      "render_mixdown-class call, not an async job) and lands the result as " +
      "a NEW AI-flagged audio track + clip in the project automatically, in " +
      "one undoable edit (edit_undo removes it). Call vc_sidecar_start first " +
      "if vc_sidecar_status isn't healthy. TYPICAL FLOW for \"turn this " +
      "vocal into voice X\": generate or import a song, extract_stems with " +
      "trackNames:[\"vocals\"] (or import an existing a cappella recording), " +
      "then convert_vocals the resulting vocal clip/file to the target " +
      "voice. RIGHTS-RESPONSIBILITY POLICY: voiceId may be a voice trained " +
      "from the user's own recordings (vc_train_voice) OR a user-supplied " +
      "third-party voice model; the USER is responsible for having the " +
      "rights to it. The reserved id " +
      "\"base\" is a legitimate SMOKE-TEST target: it exercises the full " +
      "pipeline honestly WITHOUT a real trained voice, and its result always " +
      "carries realConversion:false plus a note explaining why — use it to " +
      "prove the pipeline works end-to-end before any real voice exists. " +
      "Pass EXACTLY ONE of clipId or path to name the source audio: clipId " +
      "converts EXACTLY THE AUDIO THAT CLIP PRESENTS \u2014 its trim, its offset " +
      "into the recording, its time-stretch and its pitch shift are all " +
      "honoured, so a comped or trimmed take converts the region you can hear " +
      "and nothing else \u2014 and defaults atBeat to that clip's own start beat; " +
      "path converts a local audio file directly (absolute or ~-expanded) and " +
      "defaults atBeat to 0. To convert SEVERAL clips and keep the " +
      "arrangement, use vc_convert_clips instead: this tool always lands ONE " +
      "clip. Returns {trackId, clipId, " +
      "outputPath, realConversion, inputSeconds, inferSeconds, rtf?, " +
      "sampleRate, note?} — realConversion is false only for the \"base\" " +
      "smoke target, true for a real trained voice.",
    inputSchema: {
      clipId: z
        .string()
        .optional()
        .describe(
          "Id of an existing AUDIO clip; what gets converted is exactly the audio that clip " +
            "presents \u2014 trim, offset into the recording, time-stretch and pitch shift all " +
            "honoured (from project_snapshot or a prior clip_add_audio/import result). Pass " +
            "EXACTLY ONE of clipId or path — passing both, or neither, is rejected. A MIDI " +
            "clip's id is rejected (no audio to convert)."
        ),
      path: z
        .string()
        .optional()
        .describe(
          "Absolute or ~-expanded local path to an audio file to convert directly. Pass " +
            "EXACTLY ONE of clipId or path — passing both, or neither, is rejected."
        ),
      voiceId: z
        .string()
        .min(1)
        .describe(
          "The target voice's id: either a real voice the user trained or supplied " +
            "(vc_train_voice, or an imported third-party model — the user is responsible " +
            "for the rights to it), or the reserved smoke-test id \"base\" (untrained generic synthesizer — " +
            "proves the pipeline runs, NOT a real voice conversion; its result always carries " +
            "realConversion:false plus an explanatory note)."
        ),
      pitchSemitones: z
        .number()
        .int()
        .min(-24)
        .max(24)
        .optional()
        .describe(
          "Pitch shift applied during conversion, in semitones (+12 = up an octave). Integer, " +
            "-24..24. Omit for no shift (0)."
        ),
      trackName: z
        .string()
        .optional()
        .describe('Name for the new track/clip. Omit for a default like "Voice: <voiceId>".'),
      atBeat: z
        .number()
        .min(0)
        .optional()
        .describe(
          "Where the converted clip lands, in beats (quarter notes) from timeline start. " +
            "Omit to default to the source clip's own start beat (clipId form) or 0 (path form)."
        ),
    },
  },
  async ({ clipId, path, voiceId, pitchSemitones, trackName, atBeat }) =>
    toToolResult(() =>
      bridge.send("vc.convertVocals", { clipId, path, voiceId, pitchSemitones, trackName, atBeat })
    )
);

// vc_convert_clips (m24-m leg A) — the SELECTION-driven form of the tool
// above, and the one to reach for whenever more than one clip is involved.
// It converts each selected clip SEPARATELY and lands the whole set at the
// same beats on ONE new track, so the arrangement survives; converting a
// merged render would destroy it, and calling vc_convert_vocals N times
// would make N tracks and N undo steps. BLOCKS for roughly N times as long
// as vc_convert_vocals (the bridge budgets one convert timeout per clip id).
registerTool(
  "vc_convert_clips",
  {
    title: "Convert several clips to a voice, keeping the arrangement",
    description:
      "Convert a SET of selected vocal clips to a target voice with the local " +
      "RVC voice-conversion sidecar, each clip converted SEPARATELY, and land " +
      "the whole set at the SAME beats on ONE new AI-flagged audio track \u2014 so " +
      "the arrangement survives the conversion. THIS IS THE TOOL FOR MORE THAN " +
      "ONE CLIP: vc_convert_vocals lands a single clip, and calling it N times " +
      "would make N tracks and N undo steps. BLOCKS until every conversion " +
      "finishes (no separate poll/import step) and lands the result in ONE " +
      "undoable edit \u2014 a single edit_undo removes the whole converted set. " +
      "Call vc_sidecar_start first if vc_sidecar_status isn't healthy. Each " +
      "conversion is fed exactly the audio its clip presents: trim, offset " +
      "into the recording, time-stretch and pitch shift are honoured, so " +
      "comped and trimmed takes convert the region you can actually hear. " +
      "Clip gain, fades and the gain envelope are NOT baked into what the " +
      "voice engine hears \u2014 they are carried onto the converted clip, which " +
      "keeps it editable and keeps a fade-to-silence head out of the pitch " +
      "estimator. ALWAYS A NEW TRACK: there is no cache and no binding back " +
      "to the voice model, and the result is a plain audio track you can edit " +
      "freely. ALL-OR-NOTHING: every clip id is checked before the first " +
      "conversion, and a failure part-way lands nothing. Two SELECTED clips " +
      "that overlap in beats are refused (one track cannot hold both at their " +
      "own beats) \u2014 convert them in two passes. RIGHTS-RESPONSIBILITY POLICY: " +
      "voiceId may be a voice trained from the user's own recordings " +
      "(vc_train_voice) OR a user-supplied third-party voice model; the USER " +
      "is responsible for having the rights to it. The reserved id \"base\" is " +
      "a legitimate SMOKE-TEST target that exercises the pipeline without a " +
      "real trained voice; its results always carry realConversion:false plus " +
      "a note explaining why. Returns {trackId, trackName, warnings:[...], " +
      "clips:[{sourceClipId, sourceTrackId, clipId, startBeat, lengthBeats, " +
      "extractedPath, file, sourceSeconds, convertedSeconds, realConversion, " +
      "inputSeconds, inferSeconds, rtf?, sampleRate, note?}]} \u2014 one entry per " +
      "converted clip, in timeline order.",
    inputSchema: {
      clipIds: z
        .array(z.string())
        .min(1)
        .describe(
          "Ids of the AUDIO clips to convert \u2014 the user's selection (from project_snapshot " +
            "or a prior import result). Order does not matter; the result comes back in " +
            "timeline order. Each clip converts on its own and lands at its own beat. A MIDI " +
            "clip's id, an unknown id, a repeated id, or two clips that overlap in beats are " +
            "all rejected before any conversion runs."
        ),
      voiceId: z
        .string()
        .min(1)
        .describe(
          "The target voice's id: either a real voice the user trained or supplied " +
            "(vc_train_voice, or an imported third-party model — the user is responsible " +
            "for the rights to it), or the reserved smoke-test id \"base\" (untrained generic " +
            "synthesizer — proves the pipeline runs, NOT a real voice conversion; its " +
            "results always carry realConversion:false plus an explanatory note)."
        ),
      pitchSemitones: z
        .number()
        .int()
        .min(-24)
        .max(24)
        .optional()
        .describe(
          "Pitch shift applied during every conversion in this set, in semitones (+12 = up " +
            "an octave). Integer, -24..24. Omit for no shift (0)."
        ),
      trackName: z
        .string()
        .optional()
        .describe(
          'Name for the new track carrying the converted set. Omit for a default like ' +
            '"Voice: <voiceId>". The converted CLIPS keep their source clips\' own names.'
        ),
    },
  },
  async ({ clipIds, voiceId, pitchSemitones, trackName }) =>
    toToolResult(() =>
      bridge.send("vc.convertClips", { clipIds, voiceId, pitchSemitones, trackName })
    )
);

registerTool(
  "vc_train_voice",
  {
    title: "Train a new voice from a user-supplied recording set",
    description:
      "Train a new voice for vc_convert_vocals from a local directory of " +
      "clean, dry vocal recordings. RIGHTS-RESPONSIBILITY POLICY: datasetDir " +
      "must contain recordings the USER is responsible for having the rights " +
      "to use; the product does not restrict whose voice that is. This tool " +
      "implies no product-compatibility claim about the underlying engine. " +
      "TODAY this always " +
      "answers a reserved \"training not yet available\" error (the facade " +
      "validates the request shape, then answers that the feature ships " +
      "with a later roadmap item, the in-app Voice panel) — call it anyway " +
      "if a user asks to train a voice; the error IS the honest, actionable " +
      "answer, not a bug. Use the \"base\" smoke-test target on " +
      "vc_convert_vocals in the meantime to prove the pipeline itself " +
      "works.",
    inputSchema: {
      name: z.string().min(1).describe("Display name for the new voice."),
      datasetDir: z
        .string()
        .min(1)
        .describe(
          "Absolute or ~-expanded local directory of clean, dry vocal recordings to " +
            "train from — the user is responsible for having the rights to them."
        ),
      voiceId: z
        .string()
        .optional()
        .describe("Specific id for the new voice. Omit to let the facade derive one from name."),
      epochs: z
        .number()
        .int()
        .positive()
        .optional()
        .describe("Training-length override, in epochs. Omit for the facade's default."),
    },
  },
  async ({ name, datasetDir, voiceId, epochs }) =>
    toToolResult(() => bridge.send("vc.trainVoice", { name, datasetDir, voiceId, epochs }))
);

registerTool(
  "vc_list_voices",
  {
    title: "List the available conversion voices",
    description:
      "List every voice the local RVC voice-conversion sidecar can convert " +
      "to (for vc_convert_vocals's voiceId). No params. Returns `{voices: " +
      "[{id, name, state, hasIndex?, createdAt?, kind?, trained?, note?}]}` " +
      "— the sidecar's own descriptors verbatim. The reserved id \"base\" " +
      "is ALWAYS listed (kind \"builtin\", trained false, plus a note): it " +
      "is the pipeline SMOKE-TEST target, not a real voice — converting to " +
      "it proves the pipeline runs and always carries realConversion:false. " +
      "Real voices appear here once trained (vc_train_voice — arriving with " +
      "a later update). `state` is \"ready\" (usable now), " +
      "\"needsConversion\" (trained but not yet prepared for this engine), " +
      "or \"incomplete\". Requires the sidecar to be running — call " +
      "vc_sidecar_start first if vc_sidecar_status isn't healthy; an " +
      "unreachable sidecar errors with the actionable next step, never a " +
      "bare connection failure. RIGHTS-RESPONSIBILITY POLICY: a real voice " +
      "listed here may be one the user trained from their own recordings or " +
      "a third-party model they supplied; the user is responsible for " +
      "having the rights to it.",
    inputSchema: {},
  },
  async () => toToolResult(() => bridge.send("vc.listVoices"))
);

registerTool(
  "vc_import_voice_model",
  {
    title: "Import a third-party RVC voice model",
    description:
      "Import a user-supplied third-party RVC voice-conversion model (a " +
      "`.pth` checkpoint, optionally with its companion `.index`) so it " +
      "appears in vc_list_voices as a real voice, ready for `voiceId` on " +
      "vc_convert_vocals. A PURE LOCAL FILE COPY into the app's own voice " +
      "store — no sidecar call, so it works even while vc_sidecar_status " +
      "isn't healthy. `modelPath` (required) is the absolute or `~`-expanded " +
      "path to the `.pth` file on the user's disk. `indexPath` (optional) is " +
      "the absolute or `~`-expanded path to a companion FAISS `.index` file, " +
      "which raises conversion quality when present. `voiceId` (optional) " +
      "sets the id this voice is listed under; omit to derive one from " +
      "`name` (or the model file's own name) sanitised to letters/digits/" +
      "`-`/`_` — the reserved smoke-test id \"base\" is refused. `name` " +
      "(optional) is the display name; omit to reuse the same text `voiceId` " +
      "is derived from. `overwrite` (optional, default false) replaces an " +
      "existing voice at that id instead of refusing. IMPORTANT — THIS DOES " +
      "NOT MAKE THE VOICE IMMEDIATELY USABLE: the RVC engine needs an MLX-" +
      "converted `.npz`, which this tool does not produce (no conversion " +
      "step exists yet), so the imported voice lands honestly in " +
      "`needsConversion` state — the SAME state vc_list_voices already " +
      "reports for a voice with a `.pth` but no `.npz`. Calling " +
      "vc_convert_vocals with this voiceId before that conversion exists " +
      "will fail; check vc_list_voices' `state` field, and tell the user " +
      "conversion support is coming rather than implying the voice is ready " +
      "now. Returns `{voiceId, name, hasIndex, state, directoryPath}`. " +
      "RIGHTS-RESPONSIBILITY POLICY: third-party voice models are " +
      "supported; the user is responsible for having the rights to " +
      "whatever model they import — this tool implies no ownership or " +
      "compatibility claim of its own.",
    inputSchema: {
      modelPath: z
        .string()
        .min(1)
        .describe(
          "Absolute or ~-expanded local path to the third-party RVC .pth checkpoint to import."
        ),
      indexPath: z
        .string()
        .optional()
        .describe(
          "Absolute or ~-expanded local path to the model's companion FAISS .index file, if " +
            "the user has one. Omit if there isn't one — the voice still imports, just " +
            "without the quality boost an index gives."
        ),
      voiceId: z
        .string()
        .optional()
        .describe(
          "The store id this voice is listed under (what vc_convert_vocals's voiceId will " +
            "name). Omit to derive one from name/the model file's own name. The reserved id " +
            "\"base\" is refused (it names the built-in smoke-test target)."
        ),
      name: z
        .string()
        .optional()
        .describe("Display name for the voice. Omit to reuse the text voiceId is derived from."),
      overwrite: z
        .boolean()
        .optional()
        .describe(
          "true: replace an existing voice already at this id. Omit or false (default): " +
            "refuse instead, naming the conflicting id."
        ),
    },
  },
  async ({ modelPath, indexPath, voiceId, name, overwrite }) =>
    toToolResult(() =>
      bridge.send("vc.importVoiceModel", { modelPath, indexPath, voiceId, name, overwrite })
    )
);

registerTool(
  "vc_install_embedded_voice",
  {
    title: "Install a voice the project carries into this machine",
    description:
      "Copy a voice model that THIS PROJECT carries into this machine's " +
      "voice store, so the conversion engine can find it and you can " +
      "convert with it again. Use this when project_embedded_voices shows " +
      "a voice with `embeddedInProject: true` but `installedLocally: " +
      "false` — the usual case for a project made on someone else's " +
      "machine. A PURE LOCAL FILE COPY: no sidecar call, so it works even " +
      "while vc_sidecar_status isn't healthy, and it is NOT a project " +
      "edit (nothing to undo, the session does not become unsaved). " +
      "`voiceId` (required) is the id from project_embedded_voices. " +
      "`overwrite` (optional, default false) replaces a voice already " +
      "installed under that id; without it an existing voice is REFUSED " +
      "rather than silently replaced, because the local one may be a newer " +
      "or retrained version the user would not want overwritten — ASK " +
      "before passing true. Returns `{voiceId, voiceName, directoryPath, " +
      "files, byteCount, replacedExisting}`. Requires the project to have " +
      "been SAVED (voices are embedded on save) and to actually carry that " +
      "voice; both refusals name project_embedded_voices as the way to see " +
      "what is there. RIGHTS-RESPONSIBILITY POLICY: the voice may be one " +
      "the user trained or a third-party model they supplied; the user is " +
      "responsible for having the rights to it.",
    inputSchema: {
      voiceId: z
        .string()
        .min(1)
        .describe(
          "The voice id to install, exactly as project_embedded_voices lists it."
        ),
      overwrite: z
        .boolean()
        .optional()
        .describe(
          "true: replace a voice already installed under this id (ask the user first — " +
            "theirs may be newer). Omit or false (default): refuse instead, naming the " +
            "conflict."
        ),
    },
  },
  async ({ voiceId, overwrite }) =>
    toToolResult(() => bridge.send("vc.installEmbeddedVoice", { voiceId, overwrite }))
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
      "panel), or `\"none\"` (not set). An entry may also carry " +
      "`consentRequired: true` — the key IS stored (configured=true, source " +
      "keychain) but macOS will show a one-time access prompt the first time " +
      "it is actually used. ACE-Step is the LOCAL, KEYLESS song " +
      "sidecar and never appears here — use ai_sidecar_status for it. " +
      "IMPORTANT: this is STATUS ONLY. Key VALUES are never exposed and can " +
      "NOT be set over MCP or the control protocol (this traffic is logged in " +
      "your conversation, so a secret must never cross it). If a provider is " +
      "`none`, tell the user to set it via the app's Settings panel (⌘,) or " +
      "an environment variable — do not ask them to paste a key to you.",
  },
  async () => toToolResult(() => bridge.send("ai.providerStatus"))
);

registerTool(
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

registerTool(
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

registerTool(
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

registerTool(
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

registerTool(
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
            // `.strict()` (m30-c): a typo'd field (e.g. "trackNam") inside
            // one `tracks` element would otherwise be silently stripped
            // instead of rejected.
            .strict()
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

registerTool(
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

registerTool(
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

registerTool(
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

registerTool(
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
// These nine tools drive the DAW app's OWN in-app AI copilot — a chat rail
// that executes control-protocol commands itself, through the same
// CommandRouter every other tool here goes through, in-process (never a
// second hop back out over this WebSocket). Depth is 1 by construction: MCP
// -> copilot -> in-process dispatch. The copilot's own tool catalog
// deliberately excludes ai_copilot_*, so it can never call itself.
// ai_copilot_get_model/ai_copilot_set_model (M10-p-6) are the model-selection
// pair — meta/settings commands like ai_copilot_reset, not part of the
// copilot's own driven task surface. ai_copilot_chats/resume_chat/
// delete_chat/rename_chat (the chat-persist design,
// docs/research/design-copilot-chat-persistence.md §9) manage the SAVED
// conversation history that lives inside the project file — also
// meta/settings tools, also excluded from the copilot's own catalog for the
// same recursion-hygiene reason.

registerTool(
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
      maxRounds: z
        .number()
        .int()
        .min(1)
        .max(32)
        .optional()
        .describe(
          "Bound THIS reply's tool-call rounds, 1-32 (clamped), overriding the in-app " +
            "copilot setting for this turn only — the app's own default is 8. Lower it " +
            "(e.g. 2-3) for a cheap, single-step ask so a wandering turn can't run long; " +
            "raise it (e.g. 16-32) for a complex multi-track arrangement that needs many " +
            "rounds of tool calls to finish. Omit to use the user's configured setting. " +
            "See ai_copilot_state's `limits` for the effective value and the full policy."
        ),
    },
  },
  async ({ message, maxRounds }) => toToolResult(() => bridge.send("ai.copilotSend", { message, maxRounds }))
);

server.registerTool(
  "ai_copilot_state",
  {
    title: "Poll the in-app AI copilot's state",
    description:
      "Poll the in-app copilot's session state (the ai_generate_song / " +
      "ai_generation_status poll precedent). Returns `{status, currentTurnId?, " +
      "transcript, limits}` where `status` is one of \"idle\", \"running\", \"done\", " +
      "\"failed\", \"cancelled\", and `transcript` is an array of entries " +
      "`{id, turnId, kind, text?, command?, ok?, summary?}` — `kind` is one of " +
      "\"user\" (your message), \"assistant\" (the copilot's reply text), " +
      "\"toolCall\" (a DAW command it invoked), \"toolResult\" (that command's " +
      "outcome), or \"failure\" (a turn-level error). `limits` is " +
      "`{maxRounds, defaultMaxRounds, validMin, validMax}` — the effective per-turn " +
      "tool-round budget (the app setting, or the last ai_copilot_send call's " +
      "`maxRounds` override) alongside the app's built-in default (8) and the valid " +
      "range (1-32), so you can introspect the budget without guessing. Also carries " +
      "the CURRENT conversation's identity (chat-persist design): `chatId` (always " +
      "present — the id this conversation would archive under), `chatTitle` (present " +
      "once derived from the first message, or after a rename), and `droppedEntries` " +
      "(present only when a resumed conversation had earlier messages trimmed to fit " +
      "the project file, > 0). Call ai_copilot_send first to get a turnId.",
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

registerTool(
  "ai_copilot_reset",
  {
    title: "Reset the in-app AI copilot",
    description:
      "Cancel any in-flight copilot turn, ARCHIVE the current conversation into " +
      "the project's saved chat history (it is never destroyed — see " +
      "ai_copilot_chats/ai_copilot_resume_chat), and start a fresh empty chat. " +
      "No params. Use this to start a fresh conversation, or to recover from a " +
      "stuck/looping turn. Returns `{archivedChatId?, evictedChatId?}` — " +
      "`archivedChatId` is present when there was a conversation to archive; " +
      "`evictedChatId` is present only on the rare occasion archiving pushed the " +
      "project past its saved-chat cap and the oldest one had to be dropped " +
      "(never silent). Both absent (an empty result) is normal for a chat that " +
      "was already empty.",
    inputSchema: {},
  },
  async () => toToolResult(() => bridge.send("ai.copilotReset"))
);

server.registerTool(
  "ai_copilot_get_model",
  {
    title: "Read the in-app AI copilot's current model + the curated model catalog",
    description:
      "Reads which Anthropic model the in-app copilot currently targets, plus " +
      "the full curated picker it's chosen from. Returns `{model, catalog}` " +
      "where `catalog` is an array of `{id, name, note}` — pass any `id` from " +
      "it to ai_copilot_set_model. `model` defaults to \"claude-sonnet-5\" " +
      "(balanced) until changed.",
    inputSchema: {},
  },
  async () => toToolResult(() => bridge.send("ai.copilotGetModel"))
);

registerTool(
  "ai_copilot_set_model",
  {
    title: "Set the in-app AI copilot's model",
    description:
      "Sets which Anthropic model the in-app copilot targets for SUBSEQUENT " +
      "turns (an in-flight turn already resolved its provider, so this never " +
      "retargets one mid-flight). `model` must be one of the curated ids from " +
      "ai_copilot_get_model's `catalog` (e.g. \"claude-sonnet-5\" for balanced " +
      "default use, \"claude-opus-5\" for the highest-reasoning flagship, " +
      "\"claude-haiku-4-5\" for the fastest/cheapest option) — an unrecognized " +
      "id errors with the full list of valid ids rather than silently falling " +
      "back. Returns `{model}` echoing the now-effective model.",
    inputSchema: {
      model: z
        .string()
        .min(1)
        .describe(
          "A curated model id from ai_copilot_get_model's `catalog`, e.g. \"claude-sonnet-5\"."
        ),
    },
  },
  async ({ model }) => toToolResult(() => bridge.send("ai.copilotSetModel", { model }))
);

server.registerTool(
  "ai_copilot_chats",
  {
    title: "List the in-app AI copilot's saved conversations",
    description:
      "List every saved copilot conversation in the OPEN project — conversations " +
      "live INSIDE the project file (chat-persist design), so this always reflects " +
      "the current project, not a global history. No params. Returns `{chats: " +
      "[{chatId, title, createdAt, updatedAt, entryCount, model?, active?, " +
      "droppedEntries?}], activeChatId}`, sorted newest-first by `updatedAt`. " +
      "`active: true` marks the copilot's CURRENT conversation and is only present " +
      "on that row (it's also only listed once it has at least one message — a " +
      "brand-new empty chat isn't noise-listed); `activeChatId` is always present, " +
      "even if the active chat isn't in `chats` yet. `droppedEntries` appears only " +
      "when earlier messages of that conversation were trimmed to keep the project " +
      "file a reasonable size (an honesty counter, never silent). Pass any `chatId` " +
      "from here to ai_copilot_resume_chat / ai_copilot_delete_chat / " +
      "ai_copilot_rename_chat.",
    inputSchema: {},
  },
  async () => toToolResult(() => bridge.send("ai.copilotChats"))
);

registerTool(
  "ai_copilot_resume_chat",
  {
    title: "Resume a saved copilot conversation",
    description:
      "Resume a previously saved copilot conversation so you can continue it with " +
      "ai_copilot_send. RESUME IS ALWAYS EXPLICIT — the copilot never auto-resumes: " +
      "ai_copilot_reset and reopening a project both leave it on a fresh empty " +
      "chat, and it stays there until this tool is called. The CURRENT " +
      "conversation is archived first if it holds any messages (never lost — its " +
      "id comes back as `archivedChatId` when that happened). Safe to do after " +
      "switching models: a saved conversation never carries hidden chain-of-" +
      "thought, so any curated model can pick it back up. Returns `{chatId, title, " +
      "entryCount, droppedEntries?, status: \"idle\", archivedChatId?}` " +
      "(`droppedEntries`/`archivedChatId` present only when non-zero/applicable). " +
      "Fails with a teaching error if a turn is currently running (finish it or " +
      "call ai_copilot_reset first) or for an unrecognized chatId — list current " +
      "ones with ai_copilot_chats.",
    inputSchema: {
      chatId: z
        .string()
        .uuid()
        .describe("The conversation to resume — a `chatId` from ai_copilot_chats."),
    },
  },
  async ({ chatId }) => toToolResult(() => bridge.send("ai.copilotResumeChat", { chatId }))
);

registerTool(
  "ai_copilot_delete_chat",
  {
    title: "Permanently delete a saved copilot conversation",
    description:
      "Permanently deletes one saved copilot conversation — the ONLY destructive " +
      "chat-history operation (resuming and renaming never destroy anything). " +
      "Deleting the CURRENTLY ACTIVE conversation is allowed only while no turn is " +
      "running: it drops that conversation for good and starts a fresh empty chat " +
      "(`wasActive: true` in the result). Deleting an archived (not currently " +
      "active) conversation is allowed at any time. Returns `{deleted: true, " +
      "chatId, wasActive}`. Fails with a teaching error for an unrecognized chatId " +
      "(list current ones with ai_copilot_chats), or when targeting the active " +
      "chat while a turn is running (cancel it first with ai_copilot_reset, or " +
      "wait for it to finish).",
    inputSchema: {
      chatId: z
        .string()
        .uuid()
        .describe(
          "The conversation to delete — a `chatId` from ai_copilot_chats. This cannot be undone."
        ),
    },
  },
  async ({ chatId }) => toToolResult(() => bridge.send("ai.copilotDeleteChat", { chatId }))
);

registerTool(
  "ai_copilot_rename_chat",
  {
    title: "Rename a saved copilot conversation",
    description:
      "Renames a saved copilot conversation, active or archived. Titles longer " +
      "than 120 characters are clamped, never rejected. Returns `{chatId, title}` " +
      "echoing the stored (possibly clamped) title. Fails with a teaching error " +
      "for an unrecognized chatId (list current ones with ai_copilot_chats), or " +
      "for a title that's empty (or only whitespace).",
    inputSchema: {
      chatId: z
        .string()
        .uuid()
        .describe("The conversation to rename — a `chatId` from ai_copilot_chats."),
      title: z
        .string()
        .min(1)
        .describe(
          "New title for the conversation, e.g. \"funky bassline idea\". Over 120 " +
            "characters is clamped, not rejected; whitespace-only is rejected."
        ),
    },
  },
  async ({ chatId, title }) => toToolResult(() => bridge.send("ai.copilotRenameChat", { chatId, title }))
);

// ---------------------------------------------------------------------------
// AI generation
// ---------------------------------------------------------------------------

registerTool(
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

registerTool(
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

registerTool(
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

// ---------------------------------------------------------------------------
// MIDI file import (m23-k3)
// ---------------------------------------------------------------------------

registerTool(
  "project_import_midi",
  {
    title: "Import a Standard MIDI File as new tracks",
    description:
      "Import a Standard MIDI File (.mid/.midi) as new INSTRUMENT tracks, one MIDI clip per " +
      "imported part, in ONE journaled \"Import MIDI File\" edit — undo removes every created " +
      "track and reverts any tempo/meter adoption together. RECOMMENDED WORKFLOW: call once " +
      "with `dryRun: true` first — it parses the file and returns the full report, including " +
      "the `parts` array (every part in the file, even ones that would be skipped, so an index " +
      "means the same thing on the dry run and the real one) and the RESOLVED tempo policy, " +
      "WITHOUT touching the project or creating an undo entry; inspect it, then call again for " +
      "real, narrowing `parts` to just what you want — a call with no `parts` filter imports " +
      "every part as its own track, which can be dozens for a full arrangement. `atBeat` " +
      "(default 0) is the TIMELINE beat that file tick 0 lands on; every created clip starts " +
      "there and notes stay clip-relative regardless. `tempoPolicy` controls the project's " +
      "tempo and time-signature maps: `\"auto\"` (default) adopts the file's tempo/meter maps " +
      "ONLY when the project has no clips yet, so a first import sets the grid and a later one " +
      "never silently retimes existing material; `\"adopt\"` always replaces the project's " +
      "maps with the file's (refused when combined with a non-zero `atBeat` — the maps are " +
      "absolute, so there's no honest offset adoption); `\"ignore\"` never touches them. Note " +
      "positions land on the same beats under every policy — a MIDI file's beats come from its " +
      "ticks, not its tempo. `instruments` is `\"gm\"` (THE DEFAULT: assigns General MIDI " +
      "sound-bank programs from the file's program changes, channel 10 as the standard drum " +
      "kit, so the import sounds like the instruments the file names) or `\"none\"` (the " +
      "explicit opt-out, leaving new tracks on the default instrument) — the program each part " +
      "asks for is reported either way. EACH PART REPORTS TWO NAMES: `name` is the file's " +
      "LITERAL name and `trackName` is what the track was actually called. They differ whenever " +
      "the file's own name does not distinguish the parts — a format-0 file carries ONE chunk " +
      "name for every channel, so `name` can be the song title 13 times while `trackName` reads " +
      "\"Acoustic Grand Piano\", \"Standard Drum Kit\", \"Distortion Guitar (ch 9)\"… Read " +
      "`trackName` when you need to find or describe a track you just imported. `force` " +
      "(default false) overrides the 32-track import-count " +
      "refusal. The returned report is where every fidelity loss surfaces, never applied " +
      "silently: clamped out-of-range tempos, dropped or conflicting tempo/meter events, " +
      "controller lanes dropped or decimated past their cap, dropped release velocities and " +
      "program changes, plus a plain-English `degradations` list. Response `{report: " +
      "<MIDIImportReport>, applied}`, where `applied` is true only when `dryRun` was false. " +
      "Errors readably for a non-.mid/.midi extension, a missing file, any SMF decode problem, " +
      "a recording in progress, the `\"adopt\"` + non-zero `atBeat` combination, the 32-track " +
      "limit (raise it with `force`), and a file whose import would do literally nothing.",
    inputSchema: {
      path: z
        .string()
        .min(1)
        .describe(
          "Absolute (or ~-prefixed) path to the .mid/.midi Standard MIDI File to import on " +
            "this Mac. A relative path or wrong extension is rejected."
        ),
      atBeat: z
        .number()
        .min(0)
        .optional()
        .describe(
          "Timeline beat (quarter notes) that file tick 0 lands on — every created clip " +
            "starts here. Must be >= 0. Omit to default to 0."
        ),
      tempoPolicy: z
        .enum(["auto", "adopt", "ignore"])
        .optional()
        .describe(
          "What to do with the file's tempo/time-signature maps. \"auto\" (default) adopts " +
            "them only when the project has no clips yet. \"adopt\" always replaces the " +
            "project's maps with the file's (refused with a non-zero atBeat). \"ignore\" never " +
            "touches them. Note positions are the same under every policy — only playback " +
            "speed and the grid are affected."
        ),
      instruments: z
        .enum(["none", "gm"])
        .optional()
        .describe(
          "\"gm\" (DEFAULT) assigns General MIDI sound-bank programs from the file's program " +
            "changes (channel 10 = the standard drum kit), so the imported tracks sound like " +
            "the instruments the file names. \"none\" is the opt-out and leaves new tracks on " +
            "the default instrument. The requested program is reported either way. Omitting " +
            "this gets \"gm\"."
        ),
      parts: z
        .array(z.number().int())
        .optional()
        .describe(
          "Which of the file's parts to import, as indices into the report's `parts` array " +
            "(run with dryRun: true first to see them — the array lists every part, including " +
            "ones that would be skipped, so an index means the same thing on a dry run and a " +
            "real import). Omit to import every part; an explicit empty array imports nothing. " +
            "An out-of-range index (including negative) is passed through and rejected by the " +
            "app with a message naming the file's actual part count — not clamped or " +
            "pre-validated here."
        ),
      dryRun: z
        .boolean()
        .optional()
        .describe(
          "true: parse the file and return the full report WITHOUT creating any tracks/clips " +
            "or touching the project's tempo — use this first to inspect the file. Omit or " +
            "false: apply it for real. Default false."
        ),
      force: z
        .boolean()
        .optional()
        .describe(
          "true: override the 32-track import-count refusal so a large file can still be " +
            "imported in full. Omit or false: the limit stands (narrow with `parts` instead). " +
            "Default false."
        ),
    },
  },
  async ({ path, atBeat, tempoPolicy, instruments, parts, dryRun, force }) =>
    toToolResult(() =>
      bridge.send("project.importMIDI", { path, atBeat, tempoPolicy, instruments, parts, dryRun, force })
    )
);

registerTool(
  "clip_import_midi",
  {
    title: "Import a Standard MIDI File into an existing MIDI clip",
    description:
      "Import one part of a Standard MIDI File (.mid/.midi) into an EXISTING MIDI clip, " +
      "replacing its notes AND controller lanes wholesale with that part's content (the " +
      "clip_set_notes whole-array precedent) in ONE journaled \"Import MIDI into Clip\" edit. " +
      "Deliberately narrow in two ways: it NEVER touches the project's tempo or time-signature " +
      "maps — that is project_import_midi's job, so there is no `tempoPolicy` param here — and " +
      "it NEVER changes the clip's length; content landing past the clip's end is imported " +
      "anyway and reported via `notesPastClipEnd`/`controllerPointsPastClipEnd` rather than " +
      "silently dropped (grow the clip first with clip_fit_to_content to make it all audible). " +
      "`part` selects which of the file's parts to import, indexing the report's `parts` " +
      "array; omit it to default to the lowest-indexed part with notes, or failing that the " +
      "lowest with controller data. `atBeat` (default 0) here is CLIP-RELATIVE — an offset " +
      "from the clip's own start, NOT a timeline beat (use project_import_midi to place " +
      "content on the timeline). `dryRun: true` (default false) returns the full report " +
      "without touching the clip or creating an undo entry — inspect a file's parts before " +
      "committing. Response `{report: <MIDIImportReport>, applied}`, where `applied` is true " +
      "only when `dryRun` was false. Errors readably for an unknown `clipId`, a non-MIDI clip, " +
      "a take-group/comp member clip (flatten it first), a non-.mid/.midi extension, a missing " +
      "file, any SMF decode problem, a recording in progress, an out-of-range `part` index, and " +
      "a part with no content to import.",
    inputSchema: {
      clipId: z.string().uuid().describe("Id of the existing MIDI clip to import into, from project_snapshot."),
      path: z
        .string()
        .min(1)
        .describe(
          "Absolute (or ~-prefixed) path to the .mid/.midi Standard MIDI File to import on " +
            "this Mac. A relative path or wrong extension is rejected."
        ),
      part: z
        .number()
        .int()
        .optional()
        .describe(
          "Which part of the file to import, as an index into the report's `parts` array (run " +
            "with dryRun: true first to see them). Omit to default to the lowest-indexed part " +
            "with notes, or failing that the lowest with controller data. An out-of-range index " +
            "(including negative) is passed through and rejected by the app with a message " +
            "naming the file's actual part count — not clamped or pre-validated here."
        ),
      atBeat: z
        .number()
        .min(0)
        .optional()
        .describe(
          "CLIP-RELATIVE beat offset applied to the imported content — an offset from the " +
            "clip's own start, NOT a timeline beat. Must be >= 0. Omit to default to 0."
        ),
      dryRun: z
        .boolean()
        .optional()
        .describe(
          "true: parse the file and return the full report WITHOUT touching the clip — use " +
            "this first to inspect a file's parts. Omit or false: apply it for real. Default " +
            "false."
        ),
    },
  },
  async ({ clipId, path, part, atBeat, dryRun }) =>
    toToolResult(() => bridge.send("clip.importMIDI", { clipId, path, part, atBeat, dryRun }))
);

// ---------------------------------------------------------------------------
// MIDI file export (m23-k4a)
// ---------------------------------------------------------------------------

registerTool(
  "project_export_midi",
  {
    title: "Export the project (or a track selection) as a Standard MIDI File",
    description:
      "Export instrument tracks as a Standard MIDI File (.mid), one MTrk part per exported " +
      "track plus a conductor chunk carrying the project name and the WHOLE tempo/time-" +
      "signature map. Non-instrument tracks (audio, bus) are SKIPPED, not refused — each is " +
      "still listed in the report's per-track ledger with a `skipReason`. Muted tracks ARE " +
      "exported at their authored content (export serializes the model, not what you'd hear " +
      "played back) — an agent that wants a muted track left out must filter `trackIds` " +
      "itself. RECOMMENDED WORKFLOW: call once with `dryRun: true` first — it runs the full " +
      "export in memory (including encoding) and returns the complete report, with the exact " +
      "`byteCount` the real write would produce, WITHOUT creating or touching any file; inspect " +
      "it, then call again for real. `path` (optional, absolute or ~-prefixed) is where to " +
      "write the file; a non-.mid/.midi extension gets `.mid` appended. Omit it and the file " +
      "goes to a fresh path under the system temp directory — always read `report.path` (filled " +
      "on a dry run too) rather than assuming a location. `trackIds` (optional array of track " +
      "ids) selects which tracks to export, in PROJECT order regardless of the order given; " +
      "omit it to export every track in the project (still skipping non-instrument ones). An " +
      "unknown id in `trackIds` is refused rather than silently dropped. `division` (default " +
      "9600 ticks per quarter note) is DERIVED, not the industry-standard 480: it is exact for " +
      "every dyadic subdivision to 1/128 of a beat, every triplet/quintuplet, and every DAW Pro " +
      "swing preset, so round-trip re-imports land bit-exact; lower it only to match a specific " +
      "target reader, and expect more content to need quantizing (reported, never silent) as a " +
      "result. `format` is 1 (default: one track per part — keeps every track name) or 0 (all " +
      "parts merged into a single track, which can carry only one name; the report's " +
      "`trackNamesLostToFormat0` counts the casualties). IMPORTANT: the exported bytes carry NO " +
      "General MIDI program-change events in this version, even for tracks on a GM sound bank — " +
      "the instrument each track asks for is only reported (`program`/`programName` per track, " +
      "and the total in `programChangesNotWritten`), never written into the file, so a receiving " +
      "program will use its own default sound for every part. The report is where every other " +
      "fidelity loss surfaces too: quantized notes/controller points, notes widened to one tick, " +
      "truncated or dropped same-pitch overlaps, dropped or colliding tempo/meter changes, and a " +
      "plain-English `degradations` list — a clean project reports all of that as zero/empty. " +
      "Response `{report: <MIDIExportReport>, written}`, where `written` is false on a dry run. " +
      "Errors readably for a non-absolute `path`, an out-of-range `division` or invalid " +
      "`format`, an unknown id in `trackIds`, content too far from the start of the file at the " +
      "chosen `division` (raise the division or move content earlier), a write failure, and a " +
      "selection with nothing exportable (only surfaced on a REAL export — a dry run on an " +
      "all-audio/all-bus selection still returns its report, with `tracksExported: 0`).",
    inputSchema: {
      path: z
        .string()
        .min(1)
        .optional()
        .describe(
          "Absolute (or ~-prefixed) path to write the .mid file to. A relative path is " +
            "rejected; a non-.mid/.midi extension has .mid appended. Omit to export to a fresh " +
            "path under the system temp directory — read the returned report's `path` field " +
            "either way."
        ),
      trackIds: z
        .array(z.string().uuid())
        .optional()
        .describe(
          "Track ids to export, from project_snapshot. Exported in PROJECT order regardless " +
            "of the order given here. Omit to export every track (non-instrument tracks are " +
            "still skipped and reported). An id that doesn't match any track is refused."
        ),
      division: z
        .number()
        .int()
        .min(1)
        .max(32767)
        .optional()
        .describe(
          "Ticks per quarter note for the file's MThd header, 1-32767. Omit for the default " +
            "9600 — exact for every dyadic subdivision to 1/128 beat, every triplet/quintuplet, " +
            "and every DAW Pro swing preset, so a re-import lands bit-exact. The industry-common " +
            "480 quantizes swung or humanized material; content off the chosen grid is " +
            "quantized to the nearest tick and reported, never silently dropped."
        ),
      format: z
        .number()
        .int()
        .min(0)
        .max(1)
        .optional()
        .describe(
          "SMF format: 1 (default) writes one track chunk per exported part, keeping every " +
            "track name. 0 merges everything into a single chunk, which can carry only one " +
            "name — the report's trackNamesLostToFormat0 counts the names that were lost."
        ),
      dryRun: z
        .boolean()
        .optional()
        .describe(
          "true: run the export fully in memory (including encoding, so byteCount is exact) " +
            "and return the report WITHOUT creating or writing any file. Omit or false: write " +
            "the file for real. Default false."
        ),
    },
  },
  async ({ path, trackIds, division, format, dryRun }) =>
    toToolResult(() => bridge.send("project.exportMIDI", { path, trackIds, division, format, dryRun }))
);

registerTool(
  "track_export_midi",
  {
    title: "Export one instrument track as a Standard MIDI File",
    description:
      "Export a single INSTRUMENT track as a Standard MIDI File (.mid): a conductor chunk " +
      "carrying the project name and the project's WHOLE tempo/time-signature map, plus one " +
      "track chunk for that track's notes and controller data — the file still carries the " +
      "full musical grid, it is only the note content that is narrowed to one track. " +
      "Identical file shape and options to project_export_midi with `trackIds` narrowed to " +
      "this one track; the two commands differ only in selection. Unlike project_export_midi, " +
      "which SKIPS a non-instrument track and reports it, this one REFUSES outright if " +
      "`trackId` names an audio or bus track — naming a specific track that cannot carry MIDI " +
      "is a mistake worth surfacing, not silently producing a note-less file (use " +
      "project_export_midi with `trackIds` to export several tracks, including a mix of kinds, " +
      "into one file). The track is exported at its authored content even if muted. " +
      "RECOMMENDED WORKFLOW: call once with `dryRun: true` first — it runs the full export in " +
      "memory (including encoding, so `byteCount` is exact) and returns the complete report " +
      "WITHOUT creating or touching any file; inspect it, then call again for real. `path` " +
      "(optional, absolute or ~-prefixed) is where to write the file; a non-.mid/.midi " +
      "extension gets `.mid` appended, and omitting it writes to a fresh path under the system " +
      "temp directory — always read `report.path` (filled on a dry run too). `division` " +
      "(default 9600 ticks per quarter note, DERIVED to be exact for dyadic subdivisions to " +
      "1/128 beat, every triplet/quintuplet, and every DAW Pro swing preset) and `format` (1 " +
      "default = keeps the track name; 0 merges into a single chunk) work exactly as in " +
      "project_export_midi. IMPORTANT: the exported bytes carry NO General MIDI program-change " +
      "event in this version even when the track is on a GM sound bank — the requested " +
      "instrument is only reported (`program`/`programName`, and counted in " +
      "`programChangesNotWritten`), never written into the file. The report is where every " +
      "other fidelity loss surfaces: quantized notes/controller points, notes widened to one " +
      "tick, truncated or dropped same-pitch overlaps, dropped tempo/meter changes, and a " +
      "plain-English `degradations` list — a clean track reports all of that as zero/empty. " +
      "Response `{report: <MIDIExportReport>, written}`, where `written` is false on a dry run. " +
      "Errors readably for an unknown `trackId`, a `trackId` naming an audio or bus track, a " +
      "non-absolute `path`, an out-of-range `division` or invalid `format`, content too far " +
      "from the start of the file at the chosen `division`, and a write failure.",
    inputSchema: {
      trackId: z.string().uuid().describe("Id of the instrument track to export, from project_snapshot."),
      path: z
        .string()
        .min(1)
        .optional()
        .describe(
          "Absolute (or ~-prefixed) path to write the .mid file to. A relative path is " +
            "rejected; a non-.mid/.midi extension has .mid appended. Omit to export to a fresh " +
            "path under the system temp directory — read the returned report's `path` field " +
            "either way."
        ),
      division: z
        .number()
        .int()
        .min(1)
        .max(32767)
        .optional()
        .describe(
          "Ticks per quarter note for the file's MThd header, 1-32767. Omit for the default " +
            "9600 — exact for every dyadic subdivision to 1/128 beat, every triplet/quintuplet, " +
            "and every DAW Pro swing preset, so a re-import lands bit-exact. The industry-common " +
            "480 quantizes swung or humanized material; content off the chosen grid is " +
            "quantized to the nearest tick and reported, never silently dropped."
        ),
      format: z
        .number()
        .int()
        .min(0)
        .max(1)
        .optional()
        .describe(
          "SMF format: 1 (default) writes the track as its own chunk, keeping its name. 0 " +
            "merges it with the conductor into a single chunk, which loses the track name."
        ),
      dryRun: z
        .boolean()
        .optional()
        .describe(
          "true: run the export fully in memory (including encoding, so byteCount is exact) " +
            "and return the report WITHOUT creating or writing any file. Omit or false: write " +
            "the file for real. Default false."
        ),
    },
  },
  async ({ trackId, path, division, format, dryRun }) =>
    toToolResult(() => bridge.send("track.exportMIDI", { trackId, path, division, format, dryRun }))
);

// ---------------------------------------------------------------------------
// Speech-to-text (m23-n2b)
// ---------------------------------------------------------------------------

registerTool(
  "clip_transcribe",
  {
    title: "Transcribe an audio clip to text with word/segment timings on its beats",
    description:
      "Run on-device speech-to-text (WhisperKit, Apple Neural Engine) over an AUDIO clip's " +
      "backing recording and return the text plus every segment and WORD placed on the " +
      "PROJECT's beat grid, not just in seconds — read `startBeat`/`endBeat` to place lyrics " +
      "or align edits without doing any seconds-to-beats math yourself. Nothing leaves the " +
      "machine. BLOCKS until finished (like render_bounce/render_mixdown, not a pollable job — " +
      "there is no job registry for it): the FIRST call on a given Mac pays a one-time ~90 " +
      "second model-compile cost that the OS then caches, so expect the very first transcription " +
      "on a fresh install to take a minute or two and every one after that to be close to real " +
      "time. `clipId` (required) must name an existing AUDIO clip — a MIDI clip has no backing " +
      "recording and is refused (read its notes directly instead). `language` (optional, a " +
      "BCP-47-ish code like \"en\") forces a spoken language; omit it to let the recogniser " +
      "detect one automatically. A TIME-STRETCHED clip (stretchRatio != 1, from clip_set_stretch) " +
      "is REFUSED rather than transcribed with wrong timings — word placement assumes one second " +
      "of the source recording equals one second of project time, which a stretch breaks; " +
      "un-stretch the clip first (clip_set_stretch ratio 1) if you need its words on the grid. " +
      "Response: {text, language, modelVariantDirectoryName, rangeStartSeconds, anchorBeat, " +
      "supportsWordTimestamps, wordTimestampSupport, wordTimestampsUnavailable?, " +
      "wordTimestampsUnverified?, " +
      "segments: [{text, startSeconds, endSeconds, startBeat, endBeat, words: [{text, " +
      "startSeconds, endSeconds, startBeat, endBeat, confidence}]}]} — seconds are measured from " +
      "the start of the SOURCE FILE (rangeStartSeconds is where the read began), while beats are " +
      "measured on the PROJECT timeline from `anchorBeat` (the clip's own start beat); confidence " +
      "is 0-1 per word. BEFORE TRUSTING AN EMPTY `words` ARRAY, READ " +
      "`supportsWordTimestamps`: word timings come from a tensor that only SOME compiled " +
      "Whisper variants expose, and when the installed one does not, every `words` array comes " +
      "back empty with no error at all. `supportsWordTimestamps: false` means exactly that, and " +
      "`wordTimestampsUnavailable` (present only then) is a readable explanation naming the " +
      "variant, the decoder inspected, and what to install instead — say that to the user " +
      "instead of reporting that the singer sang nothing. FOR THE FULL PICTURE READ " +
      "`wordTimestampSupport` (\"supported\" | \"unsupported\" | \"unknown\") INSTEAD: the boolean " +
      "reads TRUE for \"unknown\" deliberately, so it cannot tell a variant that DECLARED the " +
      "tensor from one whose capability could not be read at all (some variants ship in a " +
      "layout with no metadata to inspect, and warning about every one of them would be noise). " +
      "When the state is \"unknown\" AND the run came back with segments but no words, " +
      "`wordTimestampsUnverified` carries a hedged caution — mention it as a possible cause of " +
      "the missing words rather than as a verdict about the model. It is ABSENT (not null) " +
      "whenever it does not apply, including when words DID come back and when the recogniser " +
      "heard nothing at all; the two message fields are never both present. The text and the " +
      "SEGMENT beats are " +
      "correct either way, so the call still succeeds. Errors readably for an unknown `clipId`, " +
      "a MIDI clip, and a stretched clip; when no speech model is installed the error names the " +
      "directory it looked in.",
    inputSchema: {
      clipId: z.string().uuid().describe("Id of the existing AUDIO clip to transcribe, from project_snapshot."),
      language: z
        .string()
        .optional()
        .describe(
          "Force a spoken language with a BCP-47-ish code (e.g. \"en\"). Omit to let the " +
            "recogniser detect the language automatically, exactly as it does by default."
        ),
    },
  },
  async ({ clipId, language }) => toToolResult(() => bridge.send("clip.transcribe", { clipId, language }))
);

// ---------------------------------------------------------------------------
// Speech-to-text model install (m23-n3b)
// ---------------------------------------------------------------------------

registerTool(
  "ai_install_speech_model",
  {
    title: "Start installing a WhisperKit speech-to-text model",
    description:
      "Start downloading and installing an on-device WhisperKit speech-recognition MODEL " +
      "(a set of CoreML weights) into Application Support, in the layout `clip_transcribe` " +
      "looks for. RETURNS IMMEDIATELY — this does NOT wait for the (often multi-hundred-MB " +
      "to multi-GB) download to finish. Poll `ai_speech_model_install_status` for progress " +
      "and the terminal outcome, INCLUDING a FAST failure: an unrecognised `variant` name or " +
      "an already-installed variant without `overwrite` both still return `ok` here (the " +
      "request was accepted) and only report their failure once polled — never treat a " +
      "successful response from THIS tool as \"the model is installed\", only `succeeded` " +
      "from the status tool means that. `variant` (required) is a WhisperKit size such as " +
      "\"tiny.en\", \"base\", \"small\", \"medium\", or \"large-v3\" (WhisperKit also publishes " +
      "\"-turbo\" and \".en\" English-only variants of several of these) or the full on-disk " +
      "directory name (e.g. \"openai_whisper-tiny.en\"); smaller models install faster and use " +
      "less disk but transcribe less accurately. `overwrite` (optional, default false) " +
      "replaces an existing install of the SAME variant — omit it to keep whatever is already " +
      "there rather than risk deleting a multi-hundred-MB install by mistake. ONLY ONE " +
      "INSTALL RUNS AT A TIME across the whole app: a second call while one is in flight is " +
      "REFUSED (never queued, never merged), naming the variant already installing — wait for " +
      "`ai_speech_model_install_status` to reach a terminal state (`succeeded` or `failed`) " +
      "before starting another. Response (the SAME shape `ai_speech_model_install_status` " +
      "returns): {state: \"installing\", variantDirectoryNameRequested}.",
    inputSchema: {
      variant: z
        .string()
        .describe(
          "A WhisperKit model size (\"tiny.en\", \"base\", \"small\", \"medium\", \"large-v3\", " +
            "etc.) or a full on-disk directory name (\"openai_whisper-tiny.en\"). Determines " +
            "both the CoreML weights fetched and the matching tokenizer — WhisperKit rejects a " +
            "name that doesn't contain a known size."
        ),
      overwrite: z
        .boolean()
        .optional()
        .describe(
          "true: replace an existing install of this SAME variant, discarding it first. Omit " +
            "or false (default): refuse instead — discoverable via " +
            "ai_speech_model_install_status's errorMessage, never a silent deletion of an " +
            "existing multi-hundred-MB install."
        ),
    },
  },
  async ({ variant, overwrite }) =>
    toToolResult(() => bridge.send("ai.installSpeechModel", { variant, overwrite }))
);

registerTool(
  "ai_speech_model_install_status",
  {
    title: "Poll the current or most recently finished speech-model install",
    description:
      "Poll the status of the speech-model install started by `ai_install_speech_model`. " +
      "There is exactly ONE install slot for the whole app (in flight, or the most recently " +
      "finished one) — nothing to name, so this tool takes no parameters. Response: {state: " +
      "\"idle\"|\"installing\"|\"succeeded\"|\"failed\", variantDirectoryNameRequested?: " +
      "string (what was passed to ai_install_speech_model — NOT necessarily the canonical " +
      "on-disk directory name; that only exists once `descriptor` does), progress?: {phase: " +
      "\"preparing\"|\"downloadingModel\"|\"downloadingTokenizer\"|\"installing\"|\"finished\", " +
      "variantDirectoryName, phaseFraction (0-1 WITHIN the current phase, not overall progress " +
      "of the whole install), completedUnitCount, totalUnitCount} — may be ABSENT even while " +
      "`state` is \"installing\" if nothing has ticked yet, and a silent download (zero " +
      "progress callbacks) still reaches a terminal state, so do not treat a missing " +
      "`progress` as a hang. descriptor?: {variantDirectoryName, displayName, modelFolder, " +
      "tokenizerFolder, modelSizeBytes, tokenizerSizeBytes, hasContextPrefill, " +
      "supportsWordTimestamps, wordTimestampSupport} — present only once `state` " +
      "is \"succeeded\"; this is the model clip_transcribe will use. " +
      "`supportsWordTimestamps: false` means the variant you just installed CANNOT produce " +
      "word-level timings (its compiled decoder declares no alignment tensor), so " +
      "clip_transcribe will return segments but every `words` array empty — check it here " +
      "rather than discovering it after a transcription comes back wordless. " +
      "`wordTimestampSupport` (\"supported\" | \"unsupported\" | \"unknown\") is the field to " +
      "branch on: the boolean reads TRUE for \"unknown\", so only this one distinguishes a " +
      "variant that declared the tensor from one whose capability could not be read. " +
      "(`totalSizeBytes` / `formattedTotalSize` were listed here until m23-ef and were never " +
      "actually sent — they are computed app-side; use modelSizeBytes + tokenizerSizeBytes.) " +
      "errorMessage?: string — present only once " +
      "`state` is \"failed\" (an unrecognised variant name, an already-installed variant " +
      "without overwrite, or a download/tokenizer failure all surface here, readably). " +
      "`state: \"idle\"` means nothing has ever been started on this app instance.",
    inputSchema: {},
  },
  async () => toToolResult(() => bridge.send("ai.speechModelInstallStatus"))
);

// ---------------------------------------------------------------------------
// Instrument frequency reference (m23-o1)
// ---------------------------------------------------------------------------

registerTool(
  "frequency_reference",
  {
    title: "Cited instrument frequency reference — fundamentals, bands, HP/LP advice",
    description:
      "Look up a cited frequency reference for a recognized instrument family: its " +
      "fundamental pitch range (as MIDI notes, with derived Hz and note names), 2-5 " +
      "presence/problem bands (each with a plain-language effect and a source citation), " +
      "and a recommended high-pass corner (always present) plus a low-pass corner (only " +
      "when the source supports one — some instruments, e.g. hi-hats, have useful content " +
      "to the top of the audible band and carry `recommendedLowPass.kind: " +
      "\"noneRecommended\"` instead of a fake number). Pass `family` directly — call with " +
      "NO arguments first to see the full vocabulary under the response's `families` " +
      "array — or pass `trackId` to resolve the family from that track's own instrument; " +
      "`family` wins when both are given (`resolvedFrom: \"argument\"` in the response " +
      "says so). A track that cannot be resolved (a recorded audio track, an unconfigured " +
      "instrument, a hosted plugin, a bus) returns `resolution: \"unresolved\"` with " +
      "`reason`/`explanation`/`remedy` — NEVER infer a family from the track's name " +
      "yourself either; ask the user, or pick a `family` from the enumerated list. A " +
      "percussion-kit track queried with no `note` returns `resolution: \"drumKit\"` plus " +
      "`coveredNotes` (the GM percussion notes this table knows); with an uncovered note, " +
      "`unresolved` still carries `coveredNotes` so \"not this one\" never reads as \"no " +
      "data\". To ACT on a recommendation, call `fx_set_param` on an \"eq\" insert with " +
      "`name: \"highPassFreq\"` (the corner, in Hz) and `name: \"highPassSlopeDbPerOct\"` " +
      "(12 or 24) — the same fields `fx_describe` documents for the eq kind.",
    inputSchema: {
      family: z
        .string()
        .optional()
        .describe(
          "An instrument family id to look up directly, e.g. \"electricBass\", \"kick\", " +
            "\"snare\". Wins over trackId when both are given. Call with no arguments to " +
            "see every valid id under the response's `families` array — an unrecognized " +
            "value is refused (naming the valid ids), never silently treated as unresolved."
        ),
      trackId: z
        .string()
        .optional()
        .describe(
          "Id of a track to resolve a family from, from project_snapshot. Not a bus and " +
            "not \"master\" — a bus carries no instrument identity."
        ),
      note: z
        .number()
        .int()
        .min(0)
        .max(127)
        .optional()
        .describe(
          "A General MIDI percussion note (0-127) to resolve within a drum-kit track. " +
            "Only meaningful together with trackId, on a track whose instrument addresses " +
            "the GM percussion kit; passed against a melodic-bank track it is ignored " +
            "(with `noteIgnored: true` in the response) rather than rejected, since you " +
            "cannot know the bank before asking."
        ),
    },
  },
  async ({ family, trackId, note }: { family?: string; trackId?: string; note?: number }) =>
    toToolResult(() => bridge.send("frequency.reference", { family, trackId, note }))
);

// ---------------------------------------------------------------------------
// Group clip edit (m23-w) — the wire half of the group delete (m23-g1) and
// group drag (m23-g2), both of which shipped their ProjectStore side under a
// zero-wire-growth preference. Strictly additive: clip_remove/clip_move are
// unchanged; use these instead of a per-clip loop to collapse a multi-clip
// selection edit into ONE undo step.
// ---------------------------------------------------------------------------

registerTool(
  "clip_remove_many",
  {
    title: "Remove several clips as one undo step",
    description:
      "Permanently remove SEVERAL clips — audio or MIDI, on one or several tracks — " +
      "in ONE undo step. Prefer this over calling clip_remove in a loop: N separate " +
      "clip_remove calls cost N undo steps, so edit_undo would only restore the last " +
      "one. ALL-OR-NOTHING: every id must resolve to a live clip and must not belong " +
      "to a take group (the clip_remove contract) or the WHOLE call is refused and " +
      "the project is left untouched — never a partial delete. Duplicate ids " +
      "collapse. `ids` may be empty, which is a safe no-op. WHICH refusal you get " +
      "is deterministic (m23-am): an unknown id is reported before any take-group " +
      "member, and when several ids are take-group members the error names the " +
      "first one in arrangement order — track order, then the clip's position in " +
      "its track — never the order you happened to pass them in. Returns `{clips}`, " +
      "the removed clips. " +
      "⚠️ EACH REMOVED MIDI CLIP'S NOTES ARE OMITTED BY DEFAULT (changed from earlier " +
      "behavior, m31-b): a deletion is a pure mutation — you almost never need the " +
      "content of what you just deleted, and it is gone anyway (recoverable only via " +
      "edit_undo, which restores it whole, not by copying notes out of this response). " +
      "Measured: removing ten clips cost 199,858 chars / 7,332 lines to report a " +
      "deletion. Each entry in `clips` instead carries `notesOmitted: true` and " +
      "`noteCount`. Pass `returnNotes: true` to get every removed clip's notes back " +
      "inline anyway.",
    inputSchema: {
      ids: z
        .array(z.string().uuid())
        .describe(
          "Ids of the clips to remove, from project_snapshot. May be empty (a no-op). " +
            "Order does not matter; duplicates collapse."
        ),
      returnNotes: z
        .boolean()
        .optional()
        .describe(
          "Whether each removed MIDI clip's notes are echoed back in `clips`. Defaults " +
            "to FALSE (changed from earlier behavior, m31-b) — pass true to get them back " +
            "inline anyway. When omitted each clip in the response carries `notesOmitted: " +
            "true` plus `noteCount` instead of `notes`."
        ),
    },
  },
  async ({ ids, returnNotes }) =>
    toToolResult(async () => {
      const result = await bridge.send("clip.removeMany", { ids });
      return returnNotes === true ? result : stripNotesFromResult(result);
    })
);

registerTool(
  "clip_move_many",
  {
    title: "Move several clips together, rigidly, as one undo step",
    description:
      "Translate SEVERAL clips — possibly on different tracks — by the SAME beat " +
      "delta in ONE undo step, so every gap between them survives the move exactly. " +
      "Prefer this over calling clip_move in a loop: a per-clip loop applies " +
      "`toStartBeat`'s own `>= 0` clamp to EACH clip independently, which can weld " +
      "gaps shut the moment any one clip would cross beat 0 while the others still " +
      "have room. `byBeats` is signed (positive = later, negative = earlier) and " +
      "applies identically to every listed clip. WHOLE-GROUP CLAMP: if translating " +
      "the group by the full `byBeats` would carry its leftmost clip past beat 0, " +
      "the delta actually applied is reduced (never per-clip) so that clip lands " +
      "exactly on 0 and every other clip's offset from it is preserved — check the " +
      "response's `clamped`/`effectiveDeltaBeats` rather than assuming the requested " +
      "`byBeats` fully applied, since it can legitimately be less. Same ALL-OR-" +
      "NOTHING validation as clip_remove_many (an unknown id or a take-group member " +
      "refuses the whole call). `ids` may be empty, or the clamp may reduce the " +
      "effective delta to exactly 0 (e.g. the group is already at beat 0 and " +
      "`byBeats` is negative) — both are safe no-ops with no undo step recorded. " +
      "Landing on another same-track clip trims or removes it, same overlap policy " +
      "as clip_move. Returns `{requestedDeltaBeats, effectiveDeltaBeats, clamped, " +
      "trimmedClipIDs, removedClipIDs, clips}` — `clips` is every moved clip's " +
      "current fields; `trimmedClipIDs`/`removedClipIDs` name any OTHER (stationary) " +
      "clips the overlap policy edited. " +
      "⚠️ EACH MOVED MIDI CLIP'S NOTES ARE OMITTED BY DEFAULT (changed from earlier " +
      "behavior, m31-b): a rigid group move is a pure mutation — the notes are " +
      "unchanged by it, so echoing them back was pure cost, same class of defect as " +
      "clip_duplicate/clip_remove_many/clip_humanize. Each entry in `clips` instead " +
      "carries `notesOmitted: true` and `noteCount`. Pass `returnNotes: true` to get " +
      "every moved clip's notes back inline anyway.",
    inputSchema: {
      ids: z
        .array(z.string().uuid())
        .describe(
          "Ids of the clips to move together, from project_snapshot. May be empty " +
            "(a no-op). Order does not matter; duplicates collapse."
        ),
      byBeats: z
        .number()
        .describe(
          "Signed beat delta applied identically to every listed clip. Positive moves " +
            "later, negative moves earlier. May be reduced (never per-clip) if it would " +
            "carry the group's leftmost clip past beat 0 — see `clamped` in the response."
        ),
      returnNotes: z
        .boolean()
        .optional()
        .describe(
          "Whether each moved MIDI clip's notes are echoed back in `clips`. Defaults " +
            "to FALSE (changed from earlier behavior, m31-b) — pass true to get them " +
            "back inline anyway. When omitted each clip carries `notesOmitted: true` " +
            "plus `noteCount` instead of `notes`."
        ),
    },
  },
  async ({ ids, byBeats, returnNotes }) =>
    toToolResult(async () => {
      const result = await bridge.send("clip.moveMany", { ids, byBeats });
      return returnNotes === true ? result : stripNotesFromResult(result);
    })
);

// ---------------------------------------------------------------------------
// Cross-track group move (m23-aj) — the vertical twins of clip_move_many.
// Two tools, not one either/or param: the design rejected a single
// `clip_move_many_across` because neither this schema surface nor the
// control-protocol one can express "exactly one of byTracks/toTrackId", and
// advertising a call shape the router would then refuse is worse than never
// advertising it at all.
// ---------------------------------------------------------------------------

registerTool(
  "clip_move_many_by_tracks",
  {
    title: "Move several clips down or up the track list, rigidly, as one undo step",
    description:
      "Move SEVERAL clips DOWN or UP the track list by the SAME whole number of tracks, " +
      "rigidly, in ONE undo step — a selection spanning several tracks keeps its shape " +
      "(vertical offsets between the clips are preserved). A move onto a track that " +
      "cannot hold the clip REFUSES THE WHOLE CALL: a MIDI clip needs an instrument " +
      "track, an audio clip needs an audio track, and bus tracks hold no clips at all — " +
      "nothing is skipped and nothing is partially applied. Running off the top or " +
      "bottom of the track list is CLAMPED, not refused (the whole group, never per " +
      "clip) — read `effectiveTrackDelta`/`clampedTracks` rather than assuming " +
      "`byTracks` fully applied, the same precedent as clip_move_many's `clamped`. " +
      "`byBeats` optionally rides along in the SAME undo step, so one call can move " +
      "down AND along at once (same whole-group beat-0 clamp as clip_move_many). " +
      "`landings` is the per-clip truth: a move of a selection spanning several tracks " +
      "lands on several tracks, so there is no single destination to report. Prefer " +
      "clip_move_many_to_track when you know the destination track by id rather than a " +
      "relative offset — an agent choosing the wrong one of these two is the most " +
      "likely misuse. Returns `{requestedTrackDelta, effectiveTrackDelta, " +
      "clampedTracks, requestedDeltaBeats, effectiveDeltaBeats, clamped, landings: " +
      "[{clipId, fromTrackId, toTrackId}], trimmedClipIDs, removedClipIDs, clips}`. " +
      "⚠️ EACH MOVED MIDI CLIP'S NOTES ARE OMITTED BY DEFAULT (changed from earlier " +
      "behavior, m31-b) — same reasoning as clip_move_many: the notes are unchanged " +
      "by a move. Each entry in `clips` instead carries `notesOmitted: true` and " +
      "`noteCount`. Pass `returnNotes: true` to get them back inline anyway.",
    inputSchema: {
      ids: z
        .array(z.string().uuid())
        .describe(
          "Ids of the clips to move together, from project_snapshot. May be empty " +
            "(a no-op). Order does not matter; duplicates collapse."
        ),
      byTracks: z
        .number()
        .describe(
          "Signed WHOLE number of tracks to move every listed clip by. Negative = up " +
            "the track list, positive = down. Every clip moves the SAME number of " +
            "tracks, so a selection spanning several tracks keeps its shape. A NON-" +
            "INTEGRAL value (e.g. 1.5) is REFUSED outright — it is never rounded or " +
            "truncated for you. Reduced (never per-clip) if it would carry the group " +
            "past the first or last track — check `clampedTracks`/`effectiveTrackDelta`."
        ),
      byBeats: z
        .number()
        .optional()
        .describe(
          "Optional signed beat delta applied at the same time, so one call can move " +
            "down AND along in ONE undo step. Same whole-group beat-0 clamp as " +
            "clip_move_many. Defaults to 0."
        ),
      returnNotes: z
        .boolean()
        .optional()
        .describe(
          "Whether each moved MIDI clip's notes are echoed back in `clips`. Defaults " +
            "to FALSE (changed from earlier behavior, m31-b) — pass true to get them " +
            "back inline anyway. When omitted each clip carries `notesOmitted: true` " +
            "plus `noteCount` instead of `notes`."
        ),
    },
  },
  async ({ ids, byTracks, byBeats, returnNotes }) =>
    toToolResult(async () => {
      const result = await bridge.send("clip.moveManyByTracks", { ids, byTracks, byBeats });
      return returnNotes === true ? result : stripNotesFromResult(result);
    })
);

registerTool(
  "clip_move_many_to_track",
  {
    title: "Move several clips onto one named destination track, as one undo step",
    description:
      "Move SEVERAL clips onto ONE NAMED destination track, in ONE undo step. This " +
      "COLLAPSES a multi-track selection by construction: relative BEAT offsets " +
      "survive, relative TRACK offsets do not (there is nowhere for them to go — " +
      "everything lands on one track). Use this when you know the destination by id " +
      "(\"move these to the Drums track\"); use clip_move_many_by_tracks instead when " +
      "the goal is a shape-preserving relative move — an agent choosing the wrong one " +
      "of these two is the most likely misuse. A move onto a track that cannot hold a " +
      "clip REFUSES THE WHOLE CALL (a MIDI clip needs an instrument track, an audio " +
      "clip needs an audio track, bus tracks hold no clips at all). An unknown " +
      "`toTrackId` is refused EVEN WHEN `ids` is empty — a typo'd track id must be " +
      "caught immediately, not silently ignored. Because several source tracks can " +
      "collapse onto one, two of the listed clips ending up on the same beats on the " +
      "destination is ALSO refused whole (move them one at a time, or use " +
      "clip_move_many_by_tracks to keep them on separate tracks); two clips that " +
      "already overlapped each other on the SAME source track — a sanctioned crossfade " +
      "— are unaffected by this check. `byBeats` optionally rides along in the SAME " +
      "undo step. Returns the SAME shape as clip_move_many_by_tracks MINUS " +
      "`requestedTrackDelta`/`effectiveTrackDelta` (a destination-shaped move has no " +
      "delta to report — they are omitted, not null): `{clampedTracks, " +
      "requestedDeltaBeats, effectiveDeltaBeats, clamped, landings: [{clipId, " +
      "fromTrackId, toTrackId}], trimmedClipIDs, removedClipIDs, clips}`. " +
      "⚠️ EACH MOVED MIDI CLIP'S NOTES ARE OMITTED BY DEFAULT (changed from earlier " +
      "behavior, m31-b) — same reasoning as clip_move_many. Each entry in `clips` " +
      "instead carries `notesOmitted: true` and `noteCount`. Pass `returnNotes: true` " +
      "to get them back inline anyway.",
    inputSchema: {
      ids: z
        .array(z.string().uuid())
        .describe(
          "Ids of the clips to move together, from project_snapshot. May be empty — " +
            "toTrackId is still validated even so. Order does not matter; duplicates " +
            "collapse."
        ),
      toTrackId: z
        .string()
        .uuid()
        .describe(
          "Id of the track every listed clip lands on, from project_snapshot. An " +
            "unknown id is refused even when `ids` is empty."
        ),
      byBeats: z
        .number()
        .optional()
        .describe(
          "Optional signed beat delta applied at the same time, so one call can move " +
            "down AND along in ONE undo step. Defaults to 0."
        ),
      returnNotes: z
        .boolean()
        .optional()
        .describe(
          "Whether each moved MIDI clip's notes are echoed back in `clips`. Defaults " +
            "to FALSE (changed from earlier behavior, m31-b) — pass true to get them " +
            "back inline anyway. When omitted each clip carries `notesOmitted: true` " +
            "plus `noteCount` instead of `notes`."
        ),
    },
  },
  async ({ ids, toTrackId, byBeats, returnNotes }) =>
    toToolResult(async () => {
      const result = await bridge.send("clip.moveManyToTrack", { ids, toTrackId, byBeats });
      return returnNotes === true ? result : stripNotesFromResult(result);
    })
);
