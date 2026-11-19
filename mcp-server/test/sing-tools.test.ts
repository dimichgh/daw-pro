/**
 * sing-tools.test.ts — p2-sing-e: the 17 singing MCP tools (design
 * docs/design/2026-09-27-p2-sing-integration.md §6), one per new wire verb.
 *
 * Same stub-bridge / InMemoryTransport pattern as template-tools.test.ts:
 * `DawBridge.prototype.send` is replaced, so no app and no socket are needed.
 * Pinned here, per tool:
 *   - the mechanical name -> verb mapping, and that the arguments reach the
 *     bridge unchanged;
 *   - the JSON-Schema `required` list, EXACTLY as §6 writes the params (an
 *     optional param turning required, or the reverse, reds the table test);
 *   - mutating tools are strict (an unknown key is refused at the MCP boundary,
 *     before the bridge), read-only ones register directly (an extra key is
 *     stripped, by behaviour: tools/list shows the same schema for both);
 *   - the bridge's wait for each verb (`bridgeTimeoutMs`), §6's tier column
 *     plus the two reported deviations (`sing.sidecarStatus {verify: true}`
 *     and `sing.sidecarStop` on the long tier);
 *   - an app refusal ("<code>: <sentence>") comes back verbatim as `isError`.
 */

import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";

import { DawBridge, bridgeTimeoutMs } from "../src/bridge.js";

interface RecordedCall {
  command: string;
  params: Record<string, unknown>;
}

let calls: RecordedCall[];
let queuedResult: unknown;
let queuedError: Error | undefined;

DawBridge.prototype.send = async function (
  command: string,
  params: Record<string, unknown> = {}
): Promise<unknown> {
  calls.push({ command, params });
  if (queuedError) {
    const err = queuedError;
    queuedError = undefined;
    throw err;
  }
  return queuedResult;
};

const { server } = await import("../src/server.js");

let client: Client;

before(async () => {
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  client = new Client({ name: "sing-tools-test-client", version: "0.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
});

after(async () => {
  await client?.close();
});

beforeEach(() => {
  calls = [];
  queuedResult = undefined;
  queuedError = undefined;
});

const CLIP = "7C70224C-A6A0-47BF-B905-55769739D1BA";
const TRACK = "1B4E28BA-2FA1-11D2-883F-0016D3CCA427";

interface ToolRow {
  tool: string;
  verb: string;
  /** §6's params column: exactly these are required. */
  required: string[];
  /** Every param §6 names (required and optional). */
  params: string[];
  /** A full, valid argument set (every param present). */
  args: Record<string, unknown>;
  mutating: boolean;
  /** The bridge's wait for a plain call, ms. */
  timeoutMs: number;
}

const DEFAULT = 5000;
const LONG = 180000;
const DETECT_PITCH = 60000;

/** Design §6, in its order. */
const TABLE: ToolRow[] = [
  { tool: "sing_sidecar_status", verb: "sing.sidecarStatus", required: [], params: ["verify"],
    args: { verify: false }, mutating: false, timeoutMs: DEFAULT },
  { tool: "sing_sidecar_start", verb: "sing.sidecarStart", required: [], params: [],
    args: {}, mutating: true, timeoutMs: LONG },
  { tool: "sing_sidecar_stop", verb: "sing.sidecarStop", required: [], params: ["cancelJobs"],
    args: { cancelJobs: true }, mutating: true, timeoutMs: LONG },
  { tool: "sing_install_engine", verb: "sing.installEngine", required: [], params: [],
    args: {}, mutating: true, timeoutMs: DEFAULT },
  { tool: "sing_cancel_install", verb: "sing.cancelInstall", required: [], params: [],
    args: {}, mutating: true, timeoutMs: DEFAULT },
  { tool: "sing_uninstall_engine", verb: "sing.uninstallEngine", required: [], params: ["dryRun"],
    args: { dryRun: true }, mutating: true, timeoutMs: LONG },
  { tool: "sing_list_voices", verb: "sing.listVoices", required: [], params: [],
    args: {}, mutating: false, timeoutMs: DEFAULT },
  { tool: "sing_add_voice", verb: "sing.addVoice", required: [], params: ["path", "clipId", "name"],
    args: { path: "/tmp/voice.wav", name: "Lead voice" }, mutating: true, timeoutMs: DETECT_PITCH },
  { tool: "sing_remove_voice", verb: "sing.removeVoice", required: ["voiceId"], params: ["voiceId"],
    args: { voiceId: "voice-abc" }, mutating: true, timeoutMs: DEFAULT },
  { tool: "sing_open_voice_recorder", verb: "sing.openVoiceRecorder", required: [], params: [],
    args: {}, mutating: true, timeoutMs: DEFAULT },
  { tool: "sing_propose_key", verb: "sing.proposeKey", required: ["clipId"], params: ["clipId", "voiceId"],
    args: { clipId: CLIP, voiceId: "builtin-1" }, mutating: false, timeoutMs: DEFAULT },
  // p2-sing-x7 part A: `text` turned optional (`wordless` replaces it) and three optional params arrived; the
  // ONE deliberate required-list change of the round, pinned against every other tool's pin-before list in
  // sing-expansion-tools.test.ts.
  { tool: "clip_set_lyrics", verb: "clip.setLyrics", required: ["clipId"],
    params: ["clipId", "text", "dryRun", "language", "wordless", "wordlessPerNote"],
    args: { clipId: CLIP, text: "row row row your boat", dryRun: true }, mutating: true, timeoutMs: DEFAULT },
  { tool: "clip_get_lyrics", verb: "clip.getLyrics", required: ["clipId"], params: ["clipId"],
    args: { clipId: CLIP }, mutating: false, timeoutMs: DEFAULT },
  // p2-sing-x7 part B: three optional params arrived (`parts`, `key`, `mode`); `required` is unchanged (S6, pinned in
  // sing-x7b-tools.test.ts).
  { tool: "sing_render", verb: "sing.render", required: ["clipId"],
    params: ["clipId", "lyrics", "voiceId", "octaveShift", "seed", "trackName", "dryRun", "parts", "key", "mode"],
    args: { clipId: CLIP, lyrics: "la la", voiceId: "builtin-1", octaveShift: -1, seed: 42, trackName: "Lead vocal",
            dryRun: true },
    mutating: true, timeoutMs: DEFAULT },
  { tool: "sing_job_status", verb: "sing.jobStatus", required: [], params: ["jobId"],
    args: { jobId: "sing-1" }, mutating: false, timeoutMs: DEFAULT },
  { tool: "sing_cancel_job", verb: "sing.cancelJob", required: ["jobId"], params: ["jobId"],
    args: { jobId: "sing-1" }, mutating: true, timeoutMs: DEFAULT },
  { tool: "project_transpose", verb: "project.transpose", required: ["semitones"],
    params: ["semitones", "excludeTrackIds", "dryRun"],
    args: { semitones: -3, excludeTrackIds: [TRACK], dryRun: true }, mutating: true, timeoutMs: DEFAULT },
];

async function listed(name: string) {
  const tool = (await client.listTools()).tools.find((t) => t.name === name);
  assert.ok(tool, `${name} must be listed`);
  return tool!;
}

test("all 17 singing tools are listed, in §6's set, each one explaining what singing is", async () => {
  assert.equal(TABLE.length, 17);
  assert.equal(new Set(TABLE.map((r) => r.verb)).size, 17);
  for (const row of TABLE) {
    const tool = await listed(row.tool);
    if (row.tool !== "project_transpose") {
      assert.match(tool.description ?? "", /DAW Pro can SING a melody/, `${row.tool} explains singing`);
    }
    assert.ok((tool.title ?? "").length > 0, `${row.tool} has a title`);
  }
});

test("each tool's `required` list and params are EXACTLY §6's", async () => {
  for (const row of TABLE) {
    const tool = await listed(row.tool);
    const schema = tool.inputSchema as { required?: string[]; properties?: Record<string, unknown> };
    assert.deepEqual([...(schema.required ?? [])].sort(), [...row.required].sort(), `${row.tool} required`);
    assert.deepEqual(Object.keys(schema.properties ?? {}).sort(), [...row.params].sort(), `${row.tool} params`);
  }
});

test("read-only tools register directly: an extra key is dropped by zod, never refused (the mutating ones refuse it, below)", async () => {
  // tools/list cannot tell the two paths apart (both list `additionalProperties: false`), so this is pinned by
  // behaviour: the strict wrapper refuses an unknown key at the boundary, a direct registration strips it.
  for (const row of TABLE.filter((r) => !r.mutating)) {
    calls = [];
    queuedResult = { ok: true };
    const result = (await client.callTool({ name: row.tool, arguments: { ...row.args, extraKey: 1 } })) as any;
    assert.ok(!result.isError, `${row.tool} is read-only and registers directly`);
    assert.equal(calls.length, 1, row.tool);
    assert.ok(!("extraKey" in calls[0]!.params), `${row.tool}: the extra key never reaches the app`);
  }
});

test("each tool forwards to its verb with the arguments unchanged", async () => {
  for (const row of TABLE) {
    calls = [];
    queuedResult = { ok: true };
    const result = (await client.callTool({ name: row.tool, arguments: row.args })) as any;
    assert.ok(!result.isError, `${row.tool}: ${JSON.stringify(result.content)}`);
    assert.equal(calls.length, 1, row.tool);
    assert.equal(calls[0]!.command, row.verb, row.tool);
    assert.deepEqual(JSON.parse(JSON.stringify(calls[0]!.params)), row.args, `${row.tool} params`);
  }
});

test("a mutating tool refuses an unknown key before the bridge (the agent's typo never reaches the app)", async () => {
  for (const row of TABLE.filter((r) => r.mutating)) {
    calls = [];
    const result = (await client.callTool({
      name: row.tool,
      arguments: { ...row.args, langauge: "en" },
    })) as any;
    assert.ok(result.isError, `${row.tool} must refuse the unknown key`);
    assert.equal(calls.length, 0, `${row.tool} must not reach the bridge`);
  }
});

test("x7 added `language` to clip_set_lyrics (pinned in sing-expansion-tools.test.ts); clip_get_lyrics still takes none", async () => {
  const set = await listed("clip_set_lyrics");
  const get = await listed("clip_get_lyrics");
  const setProperties = (set.inputSchema as { properties?: Record<string, unknown> }).properties ?? {};
  const getProperties = (get.inputSchema as { properties?: Record<string, unknown> }).properties ?? {};
  assert.ok("language" in setProperties);
  assert.ok(!("language" in getProperties), "clip_get_lyrics only ECHOES a clip's language");
  const result = (await client.callTool({
    name: "clip_set_lyrics",
    arguments: { clipId: CLIP, text: "la", language: "en" },
  })) as any;
  assert.ok(!result.isError);
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.params.language, "en");
});

test("the bridge waits per §6's tier column for every singing verb", () => {
  for (const row of TABLE) {
    assert.equal(bridgeTimeoutMs(row.verb, {}), row.timeoutMs, `${row.verb} tier`);
  }
  // A verify re-hashes the multi-GB model file: the long tier, and only then.
  assert.equal(bridgeTimeoutMs("sing.sidecarStatus", { verify: true }), LONG);
  assert.equal(bridgeTimeoutMs("sing.sidecarStatus", { verify: false }), DEFAULT);
  // The existing tiers are unchanged by the refactor into bridgeTimeoutMs.
  assert.equal(bridgeTimeoutMs("render.mixdown", {}), LONG);
  assert.equal(bridgeTimeoutMs("clip.detectPitch", {}), DETECT_PITCH);
  assert.equal(bridgeTimeoutMs("clip.transcribe", {}), 300000);
  assert.equal(bridgeTimeoutMs("vc.convertVocals", {}), 330000);
  assert.equal(bridgeTimeoutMs("vc.convertClips", { clipIds: ["a", "b", "c"] }), 3 * 330000);
  assert.equal(bridgeTimeoutMs("transport.play", {}), DEFAULT);
});

test("sing_render: octaveShift takes \"auto\" or a whole number; the app judges the range and teaches project_transpose", async () => {
  for (const octaveShift of ["auto", 2, -2, 5]) {
    calls = [];
    const result = (await client.callTool({ name: "sing_render", arguments: { clipId: CLIP, octaveShift } })) as any;
    assert.ok(!result.isError, `${octaveShift} reaches the app`);
    assert.equal(calls[0]!.params.octaveShift, octaveShift);
  }
  calls = [];
  const fractional = (await client.callTool({
    name: "sing_render",
    arguments: { clipId: CLIP, octaveShift: 1.5 },
  })) as any;
  assert.ok(fractional.isError, "a fractional octave is refused at the boundary");
  assert.equal(calls.length, 0);
});

test("an app refusal comes back verbatim as isError (code, colon, the sentence)", async () => {
  const refusals: Array<[string, Record<string, unknown>, string]> = [
    ["sing_render", { clipId: CLIP },
     "singNeedsLyrics: Type the words you want me to sing."],
    ["sing_install_engine", {},
     "singInstallInProgress: Already installing the singing engine — poll sing.sidecarStatus and wait for it to " +
       "reach a terminal state (succeeded, failed or cancelled) before starting again. Only one singing-engine " +
       "install runs at a time."],
    ["sing_open_voice_recorder", {},
     "singNoWindow: No DAW Pro window can show the voice recorder right now. Open DAW Pro's main window and try " +
       "again, or add a recording you already have with sing.addVoice."],
    ["project_transpose", { semitones: 3, excludeTrackIds: [TRACK] },
     `trackNotFound: No track with id ${TRACK}.`],
  ];
  for (const [tool, args, message] of refusals) {
    calls = [];
    queuedError = new Error(message);
    const result = (await client.callTool({ name: tool, arguments: args })) as any;
    assert.ok(result.isError, tool);
    assert.equal(result.content[0].text, message, tool);
    assert.equal(calls.length, 1, tool);
  }
});

test("install and uninstall describe the ask-first contract an agent must relay", async () => {
  const install = await listed("sing_install_engine");
  assert.match(install.description!, /awaitingUserConsent/);
  assert.match(install.description!, /nothing downloads until someone clicks Install/);
  const uninstall = await listed("sing_uninstall_engine");
  assert.match(uninstall.description!, /nothing is deleted until someone/);
  const recorder = await listed("sing_open_voice_recorder");
  assert.match(recorder.description!, /Only the user/);
});
