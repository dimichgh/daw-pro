/**
 * transport-layer.test.ts — wiring coverage for `transport_record_layer` and
 * `transport_finish_layer` (m34-h phase 1: LIVE LOOPING — close a take and
 * deliver its result WITHOUT tearing down playback, then record the next layer
 * without ever stopping).
 *
 * The chord-voice.test.ts pattern verbatim: monkeypatch `DawBridge.prototype.send`
 * before importing the real `McpServer`, drive the tools over an in-memory
 * transport, and assert that each forwards exactly its wire verb with no
 * parameters, round-trips the answer, and rejects a stray argument at the MCP
 * BOUNDARY rather than at the app.
 *
 * ⛔⛔ AND THREE THINGS THAT ARE NOT WIRING, PINNED HERE BECAUSE NOTHING ELSE CAN
 * SEE THEM — every one of them is a wrong reading an agent would otherwise make
 * from the tool list alone:
 *
 *   1. `transport_record_layer` must keep saying it is the MIRROR IMAGE of
 *      `transport_record`, not a replacement. The two have OPPOSITE
 *      preconditions (stopped vs already playing); an agent that reads them as
 *      interchangeable will call the wrong one and get a refusal it cannot
 *      diagnose.
 *   2. It must keep naming the LOOP TRAP. `transport_set_loop` +
 *      `transport_record` records ALTERNATE TAKES of one part for comping —
 *      several attempts, pick the best. Live looping is several DIFFERENT
 *      parts, keep them all. Identical gesture, opposite intent, and the
 *      roadmap flags this as the single most likely way to build the wrong
 *      feature. The tool refuses under a loop; the description must say why.
 *   3. `transport_finish_layer` must keep saying the clip is NOT on the
 *      timeline the moment it returns. The take finalizes asynchronously, so an
 *      agent that reads the snapshot immediately sees nothing and concludes the
 *      layer was lost. That is this tree's characteristic failure mode — a
 *      result that LOOKS like a valid answer.
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
  client = new Client({ name: "transport-layer-test-client", version: "0.0.0" });
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

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

test("both layer tools are registered exactly once", async () => {
  const listed = await client.listTools();
  for (const name of ["transport_record_layer", "transport_finish_layer"]) {
    const hits = listed.tools.filter((t) => t.name === name);
    assert.equal(hits.length, 1, `${name} should be registered exactly once`);
  }
});

// ---------------------------------------------------------------------------
// Forwarding
// ---------------------------------------------------------------------------

test("transport_record_layer takes no params and forwards to transport.recordLayer", async () => {
  queuedResult = { isPlaying: true, isRecording: true, positionBeats: 8 };
  const result = await client.callTool({ name: "transport_record_layer", arguments: {} });
  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "transport.recordLayer");
  assert.deepEqual(calls[0]!.params, {});
  assert.deepEqual(parseJSON(result), queuedResult);
});

test("⭐ transport_finish_layer forwards to transport.finishLayer and the answer shows the music still running", async () => {
  // The response shape IS the proof a caller reads: isPlaying stays true while
  // isRecording goes false. A tool that reported isPlaying:false here would be
  // describing transport_stop.
  queuedResult = { isPlaying: true, isRecording: false, positionBeats: 12.5 };
  const result = await client.callTool({ name: "transport_finish_layer", arguments: {} });
  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "transport.finishLayer");
  assert.deepEqual(calls[0]!.params, {});
  const answer = parseJSON(result);
  assert.equal(answer.isPlaying, true);
  assert.equal(answer.isRecording, false);
});

test("both tools reject an unrecognized argument at the MCP boundary (never reaches the bridge)", async () => {
  for (const name of ["transport_record_layer", "transport_finish_layer"]) {
    calls = [];
    const result = await client.callTool({ name, arguments: { bogus: true } });
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const r = result as any;
    assert.ok(r.isError, `${name}: an unrecognized key must be rejected before the bridge call`);
    assert.equal(calls.length, 0, `${name}: the strict schema rejects before bridge.send is invoked`);
  }
});

test("an app-side refusal surfaces verbatim through both tools", async () => {
  for (const [name, message] of [
    ["transport_record_layer", "nothing is playing — press play first, or use transport.record to record from a stop"],
    ["transport_finish_layer", "not recording — start a layer with transport.recordLayer (or transport.record) first"],
  ] as const) {
    calls = [];
    queuedError = new Error(message);
    const result = await client.callTool({ name, arguments: {} });
    const text = JSON.stringify(result);
    assert.ok(
      text.includes(message),
      `${name} should surface the app's teaching error verbatim; got ${text}`
    );
  }
});

// ---------------------------------------------------------------------------
// Descriptions — the three traps (see the file header)
// ---------------------------------------------------------------------------

test("⛔ transport_record_layer's description names it the MIRROR of transport_record, not a replacement", async () => {
  const d = await descriptionOf("transport_record_layer");
  assert.match(d, /MIRROR IMAGE OF transport_record, NOT A REPLACEMENT/);
  // Both preconditions stated, so an agent can pick correctly without trying.
  assert.match(d, /requires a STOPPED transport/);
  assert.match(d, /ALREADY be\s+PLAYING/);
});

test("⛔ transport_record_layer's description names the LOOP TRAP: alternate takes vs stacked layers", async () => {
  const d = await descriptionOf("transport_record_layer");
  assert.match(d, /REFUSED WHILE THE LOOP IS ENABLED/);
  // The distinction itself, not merely the refusal — the refusal alone would
  // read as an arbitrary limitation instead of two different features.
  assert.match(d, /ALTERNATE TAKES/);
  assert.match(d, /OPPOSITE of layering/);
  assert.match(d, /overdub/);
});

test("⛔ transport_finish_layer's description warns the clip is NOT on the timeline yet", async () => {
  const d = await descriptionOf("transport_finish_layer");
  assert.match(d, /NOT ON THE TIMELINE THE MOMENT THIS RETURNS/);
  assert.match(d, /poll project_snapshot/);
  // And that a bad layer costs exactly one undo — the roadmap calls a
  // two-undo layer a bug outright.
  assert.match(d, /ONE\s+undo step/);
});

test("transport_finish_layer's description explains why transport_stop is not a substitute", async () => {
  const d = await descriptionOf("transport_finish_layer");
  assert.match(d, /transport_stop would end the take AND stop the music/);
});

test("transport_record_layer's description states that count-in does NOT apply to a layer", async () => {
  // Ignored by design, not by accident — an agent that assumed a count-in
  // would wait for one that never comes.
  const d = await descriptionOf("transport_record_layer");
  assert.match(d, /COUNT-IN DOES NOT APPLY/);
});
