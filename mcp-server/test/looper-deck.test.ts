/**
 * looper-deck.test.ts — wiring coverage for the seven `looper_*` tools
 * (m34-h-1: LIVE LOOPING, the loop deck — build a song by stacking layers in
 * real time).
 *
 * The transport-layer.test.ts pattern verbatim: monkeypatch
 * `DawBridge.prototype.send` before importing the real `McpServer`, drive the
 * tools over an in-memory transport, and assert each forwards exactly its wire
 * verb with exactly the params it was given, round-trips the answer, and
 * rejects a stray argument at the MCP BOUNDARY rather than at the app.
 *
 * ⛔⛔ AND FOUR THINGS THAT ARE NOT WIRING, PINNED HERE BECAUSE NOTHING ELSE CAN
 * SEE THEM — every one is a wrong reading an agent would otherwise make from
 * the tool list alone, and every one of them would produce a session that looks
 * like it worked:
 *
 *   1. `looper_begin` must keep saying THE TRANSPORT DOES NOT LOOP. An agent
 *      that reaches for `transport_set_loop` first gets a refusal, and — worse
 *      — an agent that believes the two compose will build take-comping
 *      (several attempts at ONE part) while believing it is building layers.
 *      Identical gesture, opposite intent.
 *   2. `looper_begin` must keep explaining how the FIRST loop's length is set,
 *      because everything else in the session follows from it and it is the one
 *      decision that cannot be revised later.
 *   3. `looper_arm_layer` must keep saying THE CALL DOES NOT START THE
 *      RECORDING — the quantize boundary does. An agent that calls it and
 *      immediately plays notes will lose them to the pre-roll and conclude the
 *      capture is broken.
 *   4. `looper_undo_layer` must keep saying it is NOT `edit_undo`. An agent
 *      that substitutes the general journal will reverse whatever happened
 *      last — a fader move, a rename — instead of peeling the bad layer.
 */

import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";

import { DawBridge } from "../src/bridge.js";

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
  client = new Client({ name: "looper-deck-test-client", version: "0.0.0" });
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

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function parseJSON(result: any): any {
  const first = result.content[0];
  assert.ok(
    first && first.type === "text",
    `expected a text content item, got: ${JSON.stringify(result.content)}`
  );
  return JSON.parse(first.text as string);
}

async function descriptionOf(name: string): Promise<string> {
  const listed = await client.listTools();
  const tool = listed.tools.find((t) => t.name === name);
  assert.ok(tool, `${name} is not registered`);
  return tool!.description ?? "";
}

const TOOLS = [
  "looper_begin",
  "looper_arm_layer",
  "looper_finish_layer",
  "looper_undo_layer",
  "looper_set_layer_muted",
  "looper_status",
  "looper_end",
];

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

test("all seven looper tools are registered exactly once", async () => {
  const listed = await client.listTools();
  for (const name of TOOLS) {
    const hits = listed.tools.filter((t) => t.name === name);
    assert.equal(hits.length, 1, `${name} should be registered exactly once`);
  }
});

// ---------------------------------------------------------------------------
// Forwarding
// ---------------------------------------------------------------------------

test("looper_begin forwards bars/quantize/mode/horizonCycles and omits what was not given", async () => {
  queuedResult = { cycleBeats: 16, lengthMode: "fixedBars", lamps: [] };
  const result = await client.callTool({
    name: "looper_begin",
    arguments: { bars: 4, quantize: "cycle" },
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "looper.begin");
  // ⚠️ Unset optionals ride along as `undefined` and are dropped by
  // `JSON.stringify` on the way to the socket, so the app never sees them —
  // the same shape every other multi-optional tool in this server has.
  assert.deepEqual(calls[0]!.params,
    { bars: 4, quantize: "cycle", mode: undefined, horizonCycles: undefined });
  assert.deepEqual(parseJSON(result), queuedResult);
});

test("⭐ looper_begin with NO bars is press-to-end — the omission is the setting, so it must not be defaulted here", async () => {
  // If the tool silently substituted a bar count, press-to-end would be
  // unreachable from an agent and the session would quietly get a length the
  // performer never chose.
  queuedResult = { cycleBeats: null, lengthMode: "pressToEnd", lamps: [] };
  await client.callTool({ name: "looper_begin", arguments: {} });
  assert.equal(calls[0]!.command, "looper.begin");
  assert.equal(calls[0]!.params.bars, undefined,
    "a defaulted bar count here would make press-to-end unreachable from an agent");
});

test("looper_arm_layer forwards trackId and the optional per-pass mode", async () => {
  queuedResult = { pendingPhase: "queued", pendingLaunchBeat: 12 };
  await client.callTool({
    name: "looper_arm_layer",
    arguments: { trackId: "1E1D2C3B-4A59-4687-9012-ABCDEF012345", mode: "replace" },
  });
  assert.equal(calls[0]!.command, "looper.armLayer");
  assert.deepEqual(calls[0]!.params, {
    trackId: "1E1D2C3B-4A59-4687-9012-ABCDEF012345",
    mode: "replace",
  });
  calls = [];
  await client.callTool({
    name: "looper_arm_layer",
    arguments: { trackId: "1E1D2C3B-4A59-4687-9012-ABCDEF012345" },
  });
  assert.equal(calls[0]!.params.mode, undefined, "an unset mode inherits the session default");
});

test("looper_finish_layer forwards `immediate` and defaults to the quantized close", async () => {
  queuedResult = { pendingPhase: "closing" };
  await client.callTool({ name: "looper_finish_layer", arguments: {} });
  assert.deepEqual(calls[0]!.params, { immediate: undefined });
  await client.callTool({ name: "looper_finish_layer", arguments: { immediate: true } });
  assert.deepEqual(calls[1]!.params, { immediate: true });
});

test("looper_undo_layer takes no params and forwards to looper.undoLayer", async () => {
  queuedResult = { layerId: "x", trackId: "y", removedLayer: true, remainingNotes: 0 };
  const result = await client.callTool({ name: "looper_undo_layer", arguments: {} });
  assert.equal(calls[0]!.command, "looper.undoLayer");
  assert.deepEqual(calls[0]!.params, {});
  assert.deepEqual(parseJSON(result), queuedResult);
});

test("looper_set_layer_muted forwards layerId and muted", async () => {
  queuedResult = { lamps: [{ state: "muted" }] };
  await client.callTool({
    name: "looper_set_layer_muted",
    arguments: { layerId: "9F1C6A1E-0000-4000-8000-000000000001", muted: true },
  });
  assert.equal(calls[0]!.command, "looper.setLayerMuted");
  assert.deepEqual(calls[0]!.params, {
    layerId: "9F1C6A1E-0000-4000-8000-000000000001",
    muted: true,
  });
});

test("looper_status takes no params, forwards to looper.status, and round-trips a null deck", async () => {
  // A closed session answers null rather than an empty object: an agent must be
  // able to tell "no session" from "a session with no layers".
  queuedResult = null;
  const result = await client.callTool({ name: "looper_status", arguments: {} });
  assert.equal(calls[0]!.command, "looper.status");
  assert.deepEqual(calls[0]!.params, {});
  assert.equal(parseJSON(result), null);
});

test("looper_end takes no params and forwards to looper.end", async () => {
  queuedResult = { isPlaying: true };
  await client.callTool({ name: "looper_end", arguments: {} });
  assert.equal(calls[0]!.command, "looper.end");
  assert.deepEqual(calls[0]!.params, {});
});

// ---------------------------------------------------------------------------
// Boundary rejection — never reaches the app
// ---------------------------------------------------------------------------

test("every looper tool rejects a stray argument at the MCP boundary", async () => {
  for (const name of TOOLS) {
    calls = [];
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const r = (await client.callTool({ name, arguments: { bogus: 1 } })) as any;
    assert.ok(r.isError, `${name}: an unrecognized key must be rejected before the bridge call`);
    assert.equal(calls.length, 0, `${name}: the strict schema rejects before bridge.send runs`);
  }
});

test("looper_arm_layer requires trackId, and looper_set_layer_muted requires both of its params", async () => {
  for (const [name, args] of [
    ["looper_arm_layer", {}],
    ["looper_set_layer_muted", { muted: true }],
    ["looper_set_layer_muted", { layerId: "x" }],
  ] as const) {
    calls = [];
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const r = (await client.callTool({ name, arguments: args })) as any;
    assert.ok(r.isError, `${name} must require its params`);
    assert.equal(calls.length, 0);
  }
});

test("the enum params refuse a value the app would have to reject later", async () => {
  for (const [name, args] of [
    ["looper_begin", { quantize: "sometimes" }],
    ["looper_begin", { mode: "sideways" }],
    ["looper_arm_layer", { trackId: "t", mode: "sideways" }],
    ["looper_begin", { bars: 0 }],
    ["looper_begin", { bars: 65 }],
  ] as const) {
    calls = [];
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const r = (await client.callTool({ name, arguments: args })) as any;
    assert.ok(r.isError, `${name} ${JSON.stringify(args)} must be refused at the boundary`);
    assert.equal(calls.length, 0);
  }
});

test("a bridge error surfaces verbatim rather than being flattened", async () => {
  queuedError = new Error(
    "cannot open a live-looping session while the transport loop is enabled"
  );
  const result = await client.callTool({ name: "looper_begin", arguments: { bars: 4 } });
  const text = (result as { content: { text: string }[] }).content[0]!.text;
  assert.match(text, /transport loop is enabled/);
});

// ---------------------------------------------------------------------------
// The four descriptions that are load-bearing, not decoration
// ---------------------------------------------------------------------------

test("⛔ looper_begin still says THE TRANSPORT DOES NOT LOOP, and names the take-comping trap", async () => {
  const d = await descriptionOf("looper_begin");
  assert.match(d, /TRANSPORT DOES NOT LOOP/);
  assert.match(d, /transport_set_loop/);
  assert.match(d, /comping/i);
});

test("⭐ looper_begin still explains how the FIRST loop's length is set — the decision everything follows from", async () => {
  const d = await descriptionOf("looper_begin");
  assert.match(d, /PRESS-TO-END/);
  assert.match(d, /FIXED-BAR/);
  assert.match(d, /nearest whole bar/);
});

test("⭐ looper_arm_layer still says the call does NOT start the recording — the boundary does", async () => {
  const d = await descriptionOf("looper_arm_layer");
  assert.match(d, /DOES NOT START THE RECORDING/);
  assert.match(d, /pendingLaunchBeat/);
  // And that placement does not depend on the agent's timing, which is what
  // stops an agent "fixing" a non-problem by trying to call on the beat.
  assert.match(d, /WITHIN the cycle/);
});

test("⛔ looper_undo_layer still says it is NOT edit_undo", async () => {
  const d = await descriptionOf("looper_undo_layer");
  assert.match(d, /NOT edit_undo/);
  assert.match(d, /scoped to ONE layer/);
});

test("looper_finish_layer still warns the layer is not on the timeline when it returns", async () => {
  const d = await descriptionOf("looper_finish_layer");
  assert.match(d, /NOT ON THE TIMELINE/);
  assert.match(d, /asynchronously/);
});

test("looper_status still says it reports the DECK, not the timeline", async () => {
  // This tree's characteristic failure is a result that LOOKS like a valid
  // answer. A deck status is not proof material landed.
  const d = await descriptionOf("looper_status");
  assert.match(d, /REPORTS THE DECK, NOT THE TIMELINE/);
  assert.match(d, /clip_get_notes/);
});

test("looper_end still says the layers STAY on the timeline", async () => {
  const d = await descriptionOf("looper_end");
  assert.match(d, /LAYERS STAY/);
});
