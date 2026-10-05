/**
 * instrument-controller-warnings.test.ts — m27-b.
 *
 * `track_set_instrument` gained two ADDITIVE response fields, and the whole
 * point of them is that an agent READS them, so this suite proves they survive
 * the MCP layer rather than being reshaped or stripped on the way out:
 *   - `warnings` — plain sentences, present only when swapping the instrument
 *     changed the meaning of controller lanes the track already carries. The
 *     reported defect: CC 11 lanes authored under polySynth (which ignores
 *     them) became a broad attenuation the moment a soundBank was assigned,
 *     and cost a finished, verified mix 1.25 LU.
 *   - `honoredControllers` — which controllers this instrument acts on, plus
 *     each one's REST value, so a caller can know BEFORE authoring lanes.
 *
 * Also pins the teaching copy those fields depend on, because a field nobody
 * is told about is a field nobody reads: `clip_set_controller_lane`'s
 * description must state the non-zero neutrals (CC 11 = 127, CC 7 = 100,
 * CC 10 = 64) — the mechanism that makes an ordinary-looking CC 11 lane a CUT.
 *
 * Same stub-bridge pattern as controller-lane.test.ts: the REAL `McpServer`
 * over an in-memory transport, no live app.
 */

import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";

import { DawBridge } from "../src/bridge.js";

interface RecordedCall {
  command: string;
  params: Record<string, unknown>;
}

let calls: RecordedCall[];
let queuedResult: unknown;

DawBridge.prototype.send = async function (
  command: string,
  params: Record<string, unknown> = {}
): Promise<unknown> {
  calls.push({ command, params });
  return queuedResult;
};

const { server } = await import("../src/server.js");

let client: Client;

before(async () => {
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  client = new Client({ name: "m27b-warnings-test-client", version: "0.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
});

after(async () => {
  await client?.close();
});

beforeEach(() => {
  calls = [];
  queuedResult = undefined;
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

// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function toolDescription(name: string): Promise<string> {
  const listed = (await client.listTools()) as any;
  const tool = listed.tools.find((t: any) => t.name === name);
  assert.ok(tool, `${name} is not registered`);
  return tool.description as string;
}

// ---------------------------------------------------------------------------
// warnings — the reported defect
// ---------------------------------------------------------------------------

test("track_set_instrument surfaces the `warnings` array verbatim", async () => {
  const trackId = randomUUID();
  const warning =
    "CC11 (expression) data on this track was inert under the built-in poly synth " +
    "but the sound bank acts on it — the same notes will now sound different. " +
    "Expression rests at 127 (full) when no lane exists, so a lane below 127 " +
    "ATTENUATES this track rather than shaping it — expect the level to drop.";
  queuedResult = {
    kind: "soundBank",
    warnings: [warning],
    honoredControllers: { all: true, cc: [], pitchBend: true, channelPressure: true },
  };

  const result = await client.callTool({
    name: "track_set_instrument",
    arguments: { trackId, soundBank: { source: "gm" } },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "track.setInstrument");

  const parsed = parseJSON(result as any);
  assert.deepEqual(
    parsed.warnings,
    [warning],
    "the warning must reach the agent unaltered — a stripped field is the defect"
  );
});

test("track_set_instrument surfaces honoredControllers, including neutralDefaults", async () => {
  const trackId = randomUUID();
  queuedResult = {
    kind: "sampler",
    honoredControllers: {
      all: false,
      cc: [11, 64],
      pitchBend: true,
      channelPressure: false,
      neutralDefaults: { "1": 0, "2": 0, "7": 100, "10": 64, "11": 127, "64": 0 },
    },
  };

  const result = await client.callTool({
    name: "track_set_instrument",
    arguments: { trackId, kind: "sampler" },
  });

  const parsed = parseJSON(result as any);
  assert.deepEqual(parsed.honoredControllers.cc, [11, 64]);
  assert.equal(parsed.honoredControllers.all, false);
  // ⚠️ CC 7's rest value is 100, NOT 127 — the pair is often quoted wrong.
  assert.equal(parsed.honoredControllers.neutralDefaults["11"], 127);
  assert.equal(parsed.honoredControllers.neutralDefaults["7"], 100);
  assert.equal(parsed.honoredControllers.neutralDefaults["10"], 64);
});

test("a response with NO warnings key round-trips without one being invented", async () => {
  // The only-when-non-empty contract: an always-present empty array reads as a
  // field worth checking on every call, and then nobody checks any of them.
  const trackId = randomUUID();
  queuedResult = {
    kind: "polySynth",
    honoredControllers: { all: false, cc: [64], pitchBend: true, channelPressure: false },
  };
  const result = await client.callTool({
    name: "track_set_instrument",
    arguments: { trackId, kind: "polySynth" },
  });
  const parsed = parseJSON(result as any);
  assert.equal("warnings" in parsed, false, "no warnings key when nothing changed meaning");
});

// ---------------------------------------------------------------------------
// The teaching copy (m27-b ⓑ and ⓒ)
// ---------------------------------------------------------------------------

test("clip_set_controller_lane teaches the non-zero neutral defaults", async () => {
  const description = await toolDescription("clip_set_controller_lane");
  // The mechanism, not just the numbers: an absent lane means FULL for CC 11.
  assert.match(description, /CC 11 \(expression\) rests/);
  assert.match(description, /127/);
  assert.match(description, /CC 7 \(channel volume\) at 100/);
  assert.match(description, /CC 10 \(pan\) at 64/);
  assert.match(description, /ATTENUATION/);
});

test("track_set_instrument documents honoredControllers and warnings", async () => {
  const description = await toolDescription("track_set_instrument");
  assert.match(description, /honoredControllers/);
  assert.match(description, /warnings/);
  // It must say the data is NOT rewritten — silently neutralising a
  // correct-but-newly-live lane would be a worse bug than the one fixed.
  assert.match(description, /never rewritten or muted/);
});
