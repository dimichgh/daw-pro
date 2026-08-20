/**
 * DAW Pro MCP server — append-only session call logging (m23-ca).
 *
 * Motivating case: an agent's prose summary of a mix rebalance asserted a
 * BEFORE value for the master fader ("was 1.0097") that nothing could confirm
 * or refute. This module makes that answerable with one grep: every tool
 * call, its params, its response (or error), how long it took, and — for
 * tools we can cheaply do it for — the value it was about to change.
 *
 * ---------------------------------------------------------------------------
 * Where the seam is, and why
 * ---------------------------------------------------------------------------
 * `src/server.ts` has TWO registration paths into the same `McpServer`:
 * a local `registerTool` wrapper (151 tools, `.strict()` schemas — mostly
 * mutating, plus a few reads like this file's own `audio_profile_file`/
 * `clip_detect_pitch`/`clip_get_notes`/`instrument_describe_sampler` that
 * take real params worth typo-catching) and 34 direct
 * `server.registerTool(...)` calls (read-only tools). Patching the local
 * wrapper alone would miss every read — exactly the calls that answer "what
 * did the agent see when it decided that?" So this module patches
 * `McpServer.prototype`'s instance method `registerTool` ITSELF, once,
 * before any tool registers. Every one of the 188 registrations (154 wrapper + 34
 * direct, RE-MEASURED at breath-pad P1 by name-capturing regex rather than by
 * adding one — the previous figure said "152 + 34" beside a total of 186,
 * which does not add up, and the paragraph below said 151) — whichever path it
 * takes — funnels through the same patched function.
 *
 * `installMcpLogging` MUST run after `new McpServer(...)` but before the
 * first `registerTool(`/`server.registerTool(` call in server.ts. If it runs
 * later, it silently instruments zero tools rather than failing loudly — see
 * `test/mcp-log.test.ts`'s count assertion for the guard against that.
 *
 * ---------------------------------------------------------------------------
 * Mutating vs read-only, carried explicitly
 * ---------------------------------------------------------------------------
 * At the patched `server.registerTool` seam, both paths look identical — the
 * local wrapper is just another caller. To know which family a registration
 * belongs to (mutating tools are the ones worth a before-snapshot attempt;
 * read-only ones never mutate DAW state), server.ts's local wrapper brackets
 * its call to `server.registerTool` with `withMutatingRegistration(...)`,
 * which sets a synchronous module-level flag this file reads at the moment
 * `registerTool` actually runs. Registration is single-threaded, synchronous,
 * import-time work — there is no interleaving to race.
 *
 * The "mutating-wrapper" family is EVERY registration through the local
 * wrapper — currently 154 (MEASURED, breath-pad P6) — because the wrapper calls
 * `withMutatingRegistration` unconditionally; a few semantic reads that route
 * through it for `.strict()` (the `audio_profile_file`/`clip_detect_pitch`/
 * `clip_get_notes`/`instrument_describe_sampler` quartet named above) are
 * flagged mutating here too. That is harmless (a wasted before-read at
 * worst) but it means this denominator tracks the WRAPPER count, not a
 * hand-maintained "how many tools mutate" tally. Three of the 154
 * (`generate_lyrics`, `generate_song_suno`, `generate_image` — server.ts's
 * own comment names them as Table-B) have no backing wire command at all:
 * they call `src/ai.ts` directly. A before-read against the DAW would be
 * pure waste for them, so they're excluded by name from before-capture
 * (NO_WIRE_COMMAND_TOOLS below). 154 - 3 = 151 is the real
 * before-capture-eligible denominator.
 *
 * ⚠️ These two numbers rot silently: `test/mcp-log.test.ts` pins the 188 TOTAL,
 * so a new strict-wrapper registration reddens that assertion and gets the
 * total fixed — while this paragraph's 151/148 sail through untouched. They
 * were found stale at 142/139 (five behind) exactly that way, again at
 * 147/144 (three behind, m26-i) the same way, and again at 150/147 (one
 * behind, m26-k — the pair had already been found stale twice in one day).
 * Updated again at m27 leg D (150 -> 151 -> 152 wrapper, 186 total), and at
 * breath-pad P1 (152 -> 153 wrapper, 187 total), and at breath-pad P6
 * (153 -> 154 wrapper, 188 total — `pad_preview_effort`). ⭐ P1 did NOT trust the
 * running figure: it re-derived both halves with a regex and found the prose
 * had been internally inconsistent (151 in one paragraph, 152 in another,
 * against a pinned total of 186 that only 152 satisfies). RE-MEASURE BOTH
 * HALVES OF A PAIR; one of them is usually already wrong.
 *
 * ---------------------------------------------------------------------------
 * Before-snapshot: what it costs and why `project.overview`, not
 * `project.snapshot`
 * ---------------------------------------------------------------------------
 * Measured against a real, spawned DAWApp instance (not the user's live app —
 * a throwaway test-port instance, same pattern as test/integration.test.ts),
 * with a project holding 8 tracks and a 200-note MIDI clip:
 *
 *   project.overview  mean 0.72ms  p90 0.60ms  max  8.27ms   (~1.9 KB payload)
 *   project.snapshot  mean 5.39ms  p90 15.84ms max 29.80ms   (~24.7 KB payload)
 *   track.setVolume   mean 8.05ms  p90 12.17ms max 37.22ms   (an ordinary mutating call, for scale)
 *
 * `project.overview` is ~13x smaller and, on this measurement, cheaper than
 * the mutating call it would precede — adding it roughly doubles round trips
 * but not perceived latency in any way that matters. `project.snapshot` is a
 * real per-call cost (its own doc: full MIDI note data, automation
 * breakpoints, live meters) that grows with project size, unbounded; using it
 * as the generic before-source would make logging overhead scale with the
 * session, which is exactly the "silently double every agent's wire traffic"
 * the brief warned against. `project.overview` covers transport, tempo,
 * master volume/levels, and every track's volume/pan/mute/solo/routing/
 * sends/fx-bypass/clip-summary/automation-summary — which is to say: exactly
 * the master-fader question this item exists to answer, plus the large
 * majority of what the 148 before-capture-eligible tools touch.
 *
 * Before-capture is gated on `bridge.isConnected()` — a pure state read, never
 * a new connection attempt (see `DawBridge.isConnected`, bridge.ts). Two
 * reasons: (1) `server.ts`'s own header promises constructing `DawBridge` has
 * no network side effects, an invariant a dozen+ existing tests lean on by
 * monkeypatching `DawBridge.prototype.send` and asserting exact call counts —
 * an unconditional before-read would silently double those counts and turn
 * green tests red; (2) it means logging NEVER pays for or waits on a cold
 * connection on the app's behalf — the real tool call already owns that cost.
 * In practice this means the first mutating call of a session (before
 * anything has connected the bridge) logs `beforeCaptured: false`, and every
 * one after it gets a real value — which matches how sessions actually start
 * (`project_snapshot`/`project_overview`'s own descriptions tell an agent to
 * "call this first to orient yourself").
 *
 * Default is ON (`DAWPRO_MCP_LOG_BEFORE` unset or anything but `"0"`) given
 * the measured cost above; set `DAWPRO_MCP_LOG_BEFORE=0` to disable without
 * touching this file. Either way this is announced once on stderr at
 * startup — never silently doubling wire traffic without saying so.
 *
 * Coverage is NOT claimed to be complete or precise everywhere: for tools
 * whose `params` carry a `trackId` or `clipId`, before-capture narrows to
 * that track/clip's summary (real values). A short, explicit table
 * (`GLOBAL_SCOPE_TOOLS`) covers the transport/tempo/master-level tools that
 * take neither. Everything else still gets an honest
 * `beforeCaptured: true, narrowScope: "none"` (a hash + byte length of the
 * full overview, not a per-field value) — enough to prove SOMETHING was
 * captured and roughly how big it was, not enough to answer "what was field X
 * before". `fx_set_param`'s specific before-value is a known gap:
 * `project.overview`'s `fx` entries are `{name, bypassed}` only, no param
 * values (those live in the pricier `project.snapshot`) — narrow capture for
 * that tool covers the effect LIST, not the parameter being changed.
 *
 * ---------------------------------------------------------------------------
 * Redaction and truncation
 * ---------------------------------------------------------------------------
 * Two independent layers, since a key-name allowlist alone misses a secret
 * pasted into a free-text field (the real leak vector for an AI-facing tool
 * surface — a `prompt` param, a track `name`):
 *  - by KEY NAME: any object key matching /key|token|secret|password|
 *    credential|authorization/i is redacted wholesale, regardless of value
 *    shape.
 *  - by VALUE SHAPE: every string value (any key) is scanned for known
 *    provider-key shapes (`sk-ant-…`, `sk-proj-…`, `sk-…`, `Bearer …`) and
 *    those substrings are redacted in place, even inside an otherwise benign
 *    field.
 * Any string over 2000 chars is replaced with `{__truncated, sha256, length}`
 * rather than inlined (covers `stateData`, waveform payloads, base64 images —
 * none of today's schemas carry one literally, per a `mcp-server/src/`-wide
 * grep, but the shape is precautionary and general, not name-keyed, so it
 * survives a future field appearing under any name). The same cap applies to
 * an entire `params`/`result` value if it serializes past 20000 chars, so a
 * legitimately huge read (e.g. `project_snapshot` on a dense project) can't
 * blow up a single log line.
 *
 * ---------------------------------------------------------------------------
 * Failure handling
 * ---------------------------------------------------------------------------
 * This process is a stdio MCP server: stdout is the protocol wire, so this
 * file never calls `console.log`. If the log file can't be opened/appended,
 * it degrades to ONE `console.error` and continues serving tool calls
 * normally — logging failure must never fail a tool call or corrupt the
 * transport (the brief's own words).
 */

import { appendFileSync, mkdirSync } from "node:fs";
import { createHash } from "node:crypto";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { DawBridge } from "./bridge.js";

// ---------------------------------------------------------------------------
// Types (kept local/minimal — this module has no dependency on server.ts's
// internal ToolResult type, only on the SDK's actual runtime shape).
// ---------------------------------------------------------------------------

interface ToolContentItemLike {
  type?: string;
  text?: string;
  [key: string]: unknown;
}

interface ToolResultLike {
  content?: ToolContentItemLike[];
  isError?: boolean;
  [key: string]: unknown;
}

type AnyHandler = (...args: unknown[]) => Promise<unknown>;

interface RegisterToolConfigLike {
  title?: string;
  description?: string;
  inputSchema?: unknown;
  [key: string]: unknown;
}

/** Minimal shape this module needs from `McpServer` — avoids importing the
 * SDK's (generic, overloaded) type just to reassign one method. */
interface RegisterToolCapable {
  registerTool: (name: string, config: RegisterToolConfigLike, cb: AnyHandler) => unknown;
}

// ---------------------------------------------------------------------------
// Mutating-registration flag — see header comment.
// ---------------------------------------------------------------------------

let currentRegistrationIsMutating = false;

/** Wrap a `server.registerTool(...)` call so this module can tell, at the
 * patched seam, whether the registration came through the mutating (local
 * `registerTool`) wrapper or a direct read-only `server.registerTool` call.
 * Registration is synchronous import-time work, so a plain module flag is
 * safe — there is no concurrent registration to race. */
export function withMutatingRegistration<T>(fn: () => T): T {
  currentRegistrationIsMutating = true;
  try {
    return fn();
  } finally {
    currentRegistrationIsMutating = false;
  }
}

// ---------------------------------------------------------------------------
// Tool classification for before-capture
// ---------------------------------------------------------------------------

/** Mutating tools with NO backing wire command (server.ts's own "Table-B"
 * comment) — direct provider calls via src/ai.ts. A before-read against the
 * DAW would be pure waste for these. */
const NO_WIRE_COMMAND_TOOLS: ReadonlySet<string> = new Set([
  "generate_lyrics",
  "generate_song_suno",
  "generate_image",
]);

/** Mutating tools whose relevant state is transport/tempo/master-level and
 * whose params carry neither `trackId` nor `clipId` (those two are handled
 * generically — see `extractNarrow`). Extend this table when a new
 * transport/master-scope mutating tool is added; nothing breaks if it's
 * missed, it just falls back to hash-only before-capture. */
const GLOBAL_SCOPE_TOOLS: ReadonlySet<string> = new Set([
  "transport_play",
  "transport_stop",
  "transport_panic",
  "transport_seek",
  "transport_record",
  "transport_set_tempo",
  "tempo_set_map",
  "transport_set_loop",
  "transport_set_punch",
  "transport_set_metronome",
  "mixer_set_master_volume",
]);

// ---------------------------------------------------------------------------
// Redaction / truncation
// ---------------------------------------------------------------------------

const SECRET_KEY_PATTERN = /key|token|secret|password|credential|authorization/i;

const SECRET_VALUE_PATTERNS: RegExp[] = [
  /sk-ant-[A-Za-z0-9_-]{8,}/g,
  /sk-proj-[A-Za-z0-9_-]{8,}/g,
  /sk-[A-Za-z0-9]{16,}/g,
  /Bearer\s+[A-Za-z0-9._-]{8,}/gi,
];

const LARGE_BLOB_THRESHOLD_CHARS = 2000;
const OVERALL_VALUE_CAP_CHARS = 20000;

function sha256Hex(input: string): string {
  return createHash("sha256").update(input, "utf8").digest("hex");
}

function redactSecretPatterns(value: string): string {
  let out = value;
  for (const pattern of SECRET_VALUE_PATTERNS) {
    out = out.replace(pattern, "[REDACTED]");
  }
  return out;
}

/** Recursively redact (by key name AND by value shape) and truncate large
 * string blobs. `key` is the field name this value was found under (""` for
 * array elements / the top-level call). */
function redactValue(key: string, value: unknown): unknown {
  if (SECRET_KEY_PATTERN.test(key)) {
    return "[REDACTED]";
  }
  if (value === null || value === undefined || typeof value === "number" || typeof value === "boolean") {
    return value;
  }
  if (typeof value === "string") {
    if (value.length > LARGE_BLOB_THRESHOLD_CHARS) {
      return { __truncated: true, sha256: sha256Hex(value), length: value.length };
    }
    return redactSecretPatterns(value);
  }
  if (Array.isArray(value)) {
    return value.map((v) => redactValue("", v));
  }
  if (typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      out[k] = redactValue(k, v);
    }
    return out;
  }
  return String(value);
}

/** Backstop after redaction: if the whole value still serializes past
 * `OVERALL_VALUE_CAP_CHARS`, replace it with hash + length rather than a
 * giant inlined structure (e.g. `project_snapshot` on a dense project). */
function capOverallSize(value: unknown, label: string): unknown {
  let str: string;
  try {
    str = JSON.stringify(value) ?? "";
  } catch {
    return value;
  }
  if (str.length > OVERALL_VALUE_CAP_CHARS) {
    return { __truncated: true, sha256: sha256Hex(str), length: str.length, reason: `${label} exceeded ${OVERALL_VALUE_CAP_CHARS} chars` };
  }
  return value;
}

function redactAndCap(label: string, value: unknown): unknown {
  if (value === undefined) return undefined;
  return capOverallSize(redactValue(label, value), label);
}

// ---------------------------------------------------------------------------
// Log file
// ---------------------------------------------------------------------------

let resolvedLogPath: string | undefined;
let logDirEnsured = false;
let loggingDegraded = false;

function defaultLogDir(): string {
  return join(homedir(), "Library", "Logs", "DAWPro", "mcp");
}

/** Resolve (and memoize) this process's session log file path. Reads
 * `DAWPRO_MCP_LOG_DIR` lazily, at first use — not at module import — so a
 * test can set the env var before the first tool call without needing to
 * reload this module. */
export function mcpLogFilePath(): string {
  if (resolvedLogPath) return resolvedLogPath;
  const dir = process.env["DAWPRO_MCP_LOG_DIR"] || defaultLogDir();
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  resolvedLogPath = join(dir, `mcp-session-${stamp}-${process.pid}.jsonl`);
  return resolvedLogPath;
}

function writeLogLineSafely(entry: Record<string, unknown>): void {
  let line: string;
  try {
    line = JSON.stringify(entry) + "\n";
  } catch (err) {
    if (!loggingDegraded) {
      loggingDegraded = true;
      console.error(
        `[daw-pro-mcp] call logging degraded: could not serialize a log entry (${err instanceof Error ? err.message : String(err)}). Continuing without call logs.`
      );
    }
    return;
  }
  try {
    const filePath = mcpLogFilePath();
    if (!logDirEnsured) {
      mkdirSync(dirname(filePath), { recursive: true });
      logDirEnsured = true;
    }
    appendFileSync(filePath, line, "utf8");
  } catch (err) {
    if (!loggingDegraded) {
      loggingDegraded = true;
      console.error(
        `[daw-pro-mcp] call logging degraded: could not write to "${mcpLogFilePath()}" (${err instanceof Error ? err.message : String(err)}). Continuing without call logs.`
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Before-snapshot capture
// ---------------------------------------------------------------------------

interface BeforeCaptured {
  captured: true;
  source: "project.overview";
  fullHash: string;
  fullBytes: number;
  narrowScope: string;
  narrow: unknown;
  captureMs: number;
}

interface BeforeNotCaptured {
  captured: false;
  reason: string;
}

type BeforeInfo = BeforeCaptured | BeforeNotCaptured;

function beforeCaptureEnabled(): boolean {
  return process.env["DAWPRO_MCP_LOG_BEFORE"] !== "0";
}

function extractNarrow(name: string, params: unknown, overview: unknown): { scope: string; value: unknown } | undefined {
  const p = params && typeof params === "object" ? (params as Record<string, unknown>) : {};
  const ov = overview && typeof overview === "object" ? (overview as Record<string, unknown>) : {};

  const trackId = p["trackId"];
  if (typeof trackId === "string") {
    if (trackId === "master") {
      return { scope: "master", value: ov["master"] };
    }
    const tracks = Array.isArray(ov["tracks"]) ? (ov["tracks"] as Array<Record<string, unknown>>) : [];
    const track = tracks.find((t) => t && t["id"] === trackId);
    return track ? { scope: "track", value: track } : { scope: "track-not-found", value: undefined };
  }

  const clipId = p["clipId"];
  if (typeof clipId === "string") {
    const tracks = Array.isArray(ov["tracks"]) ? (ov["tracks"] as Array<Record<string, unknown>>) : [];
    for (const t of tracks) {
      const clips = Array.isArray(t["clips"]) ? (t["clips"] as Array<Record<string, unknown>>) : [];
      const clip = clips.find((c) => c && c["id"] === clipId);
      if (clip) return { scope: "clip", value: clip };
    }
    return { scope: "clip-not-found", value: undefined };
  }

  if (GLOBAL_SCOPE_TOOLS.has(name)) {
    return { scope: "transport+master", value: { transport: ov["transport"], master: ov["master"] } };
  }

  return undefined;
}

async function captureBefore(
  name: string,
  isMutating: boolean,
  params: unknown,
  bridge: DawBridge
): Promise<BeforeInfo> {
  if (!isMutating) return { captured: false, reason: "read-only tool" };
  if (NO_WIRE_COMMAND_TOOLS.has(name)) {
    return { captured: false, reason: "no backing wire command (direct AI-provider call)" };
  }
  if (!beforeCaptureEnabled()) return { captured: false, reason: "disabled via DAWPRO_MCP_LOG_BEFORE=0" };
  // Never initiate a connection on logging's behalf — see header comment and
  // DawBridge.isConnected's own doc.
  if (!bridge.isConnected()) return { captured: false, reason: "bridge not connected" };

  const startedAt = performance.now();
  try {
    // Calls the bridge directly — NOT the registered `project_overview` MCP
    // tool — so this can never re-enter the patched `registerTool` handler
    // and log itself (see test/mcp-log.test.ts's re-entrance test).
    const overview = await bridge.send("project.overview");
    const overviewStr = JSON.stringify(overview) ?? "null";
    const narrow = extractNarrow(name, params, overview);
    return {
      captured: true,
      source: "project.overview",
      fullHash: sha256Hex(overviewStr),
      fullBytes: Buffer.byteLength(overviewStr, "utf8"),
      narrowScope: narrow ? narrow.scope : "none",
      narrow: narrow ? redactAndCap("before.narrow", narrow.value) : null,
      captureMs: Math.round((performance.now() - startedAt) * 1000) / 1000,
    };
  } catch (err) {
    return {
      captured: false,
      reason: `project.overview read failed: ${err instanceof Error ? err.message : String(err)}`,
    };
  }
}

// ---------------------------------------------------------------------------
// Result extraction
// ---------------------------------------------------------------------------

function extractResultForLog(result: unknown): { ok: boolean; body: unknown } {
  if (result && typeof result === "object" && "content" in (result as Record<string, unknown>)) {
    const r = result as ToolResultLike;
    const first = Array.isArray(r.content) ? r.content[0] : undefined;
    const text = first && first.type === "text" ? first.text : undefined;
    let body: unknown = text;
    if (typeof text === "string") {
      try {
        body = JSON.parse(text);
      } catch {
        body = text;
      }
    }
    return { ok: !r.isError, body };
  }
  return { ok: true, body: result };
}

function round(ms: number): number {
  return Math.round(ms * 1000) / 1000;
}

// ---------------------------------------------------------------------------
// The patched handler
// ---------------------------------------------------------------------------

function wrapHandler(name: string, hasInputSchema: boolean, isMutating: boolean, original: AnyHandler, bridge: DawBridge): AnyHandler {
  return async (...callArgs: unknown[]) => {
    const startedAt = performance.now();
    // SDK calls `handler(args, extra)` when the tool has an inputSchema, and
    // `handler(extra)` when it doesn't (mcp.js `executeToolHandler`) — so
    // `callArgs[0]` is real params only in the first case. `extra` (the
    // second/only arg) is NEVER logged: it can carry `authInfo`/tokens.
    const params = hasInputSchema ? callArgs[0] : undefined;

    const before = await captureBefore(name, isMutating, params, bridge);

    let threw = false;
    let rawError: unknown;
    let rawResult: unknown;
    try {
      rawResult = await original(...callArgs);
    } catch (err) {
      threw = true;
      rawError = err;
    }

    const durationMs = round(performance.now() - startedAt);
    const { ok, body } = threw
      ? { ok: false, body: rawError instanceof Error ? rawError.message : String(rawError) }
      : extractResultForLog(rawResult);

    writeLogLineSafely({
      ts: new Date().toISOString(),
      tool: name,
      mutating: isMutating,
      params: redactAndCap("params", params),
      before,
      ok,
      ...(ok
        ? { result: redactAndCap("result", body) }
        : { error: typeof body === "string" ? redactSecretPatterns(body) : redactAndCap("error", body) }),
      durationMs,
    });

    if (threw) throw rawError;
    return rawResult;
  };
}

// ---------------------------------------------------------------------------
// Installation
// ---------------------------------------------------------------------------

interface InstrumentedMeta {
  name: string;
  mutating: boolean;
}

const instrumentedNames: string[] = [];
const instrumentedMeta: InstrumentedMeta[] = [];
let installed = false;

/** Returns the names of every tool registration this module has instrumented
 * so far, in registration order. Used by tests to assert an empty symmetric
 * difference against the server's real `tools/list` output — proof both
 * registration paths are covered, not just a headline count. */
export function instrumentedToolNames(): string[] {
  return [...instrumentedNames];
}

/** Same as `instrumentedToolNames`, plus the mutating/read-only classification
 * each registration carried. Exists for coverage reporting (what fraction of
 * mutating tools can before-capture ever narrow for), not runtime logging. */
export function instrumentedToolMeta(): InstrumentedMeta[] {
  return instrumentedMeta.map((m) => ({ ...m }));
}

/** Static classification of what `extractNarrow` would do for a tool GIVEN
 * its input schema's key names — independent of any particular call's actual
 * params. Exported for coverage reporting/tests, not used on the hot path
 * (the real `extractNarrow` above re-derives this per-call from real params,
 * since a `trackId`/`clipId` key existing in the schema doesn't guarantee a
 * given call population it, e.g. an optional one left undefined). */
export function classifyNarrowCoverage(name: string, schemaKeys: readonly string[]): "trackId" | "clipId" | "global" | "none" {
  if (schemaKeys.includes("trackId")) return "trackId";
  if (schemaKeys.includes("clipId")) return "clipId";
  if (GLOBAL_SCOPE_TOOLS.has(name)) return "global";
  return "none";
}

/**
 * Patch `server.registerTool` so every future registration — whichever of
 * server.ts's two paths it comes through — is wrapped with call logging.
 * Must run before the first `registerTool(`/`server.registerTool(` call.
 *
 * Takes the real `McpServer` type (not the minimal `RegisterToolCapable`
 * shape) so callers don't need an `as unknown as` cast at the call site;
 * `registerTool`'s own type is a generic, overloaded SDK signature that
 * doesn't structurally match a plain `(name, config, cb) => unknown` — the
 * cast happens once, here, rather than at every call site.
 */
export function installMcpLogging(server: McpServer, bridge: DawBridge): void {
  if (installed) {
    // A throw here would crash the whole module load (stdout is the wire —
    // there is no safe way to surface this to a client). Logging failure
    // must never fail the server, install-time included, so this degrades
    // the same way a failed log write does: one stderr line, then continue
    // with the first install still in effect.
    console.error("[daw-pro-mcp] call logging: installMcpLogging called twice — ignoring the second call.");
    return;
  }
  installed = true;

  console.error(
    `[daw-pro-mcp] call logging: writing to "${mcpLogFilePath()}"; before-snapshot capture is ` +
      `${beforeCaptureEnabled() ? "ON (set DAWPRO_MCP_LOG_BEFORE=0 to disable)" : "OFF (DAWPRO_MCP_LOG_BEFORE=0)"}.`
  );

  const target = server as unknown as RegisterToolCapable;
  const original = target.registerTool.bind(target);
  target.registerTool = (name: string, config: RegisterToolConfigLike, cb: AnyHandler): unknown => {
    const isMutating = currentRegistrationIsMutating;
    const hasInputSchema = Boolean(config && config.inputSchema);
    instrumentedNames.push(name);
    instrumentedMeta.push({ name, mutating: isMutating });
    return original(name, config, wrapHandler(name, hasInputSchema, isMutating, cb, bridge));
  };
}

/** Test-only: reset all module state so a fresh `installMcpLogging` (in a
 * fresh test file's own module registry) starts clean. Each `.test.js` file
 * runs in its own subprocess under `node --test`, so this is normally
 * unnecessary — it exists for tests that need it explicit rather than
 * implicit process isolation. */
export function _resetForTests(): void {
  instrumentedNames.length = 0;
  instrumentedMeta.length = 0;
  installed = false;
  resolvedLogPath = undefined;
  logDirEnsured = false;
  loggingDegraded = false;
}
