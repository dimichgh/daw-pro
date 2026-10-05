/**
 * sixteen-levels.test.ts — wiring coverage for m39-levels-2's deferred wire
 * legs: instrument_spread_slice (instrument.spreadSlice) and
 * instrument_set_spread_direction (instrument.setSpreadDirection).
 *
 * The clip-fit-to-content.test.ts pattern verbatim: monkeypatch
 * `DawBridge.prototype.send` before importing the real `McpServer`, drive the
 * tools over an in-memory transport, and assert:
 *   - each tool forwards exactly the params it received to the right command
 *   - an omitted optional `direction` on instrument_spread_slice arrives as
 *     undefined (no stray key), never a synthesized "up"
 *   - the app's response (the zone, plus `changed` on the direction setter)
 *     round-trips verbatim
 *   - the strict wrapper rejects unknown arguments, a missing required
 *     `direction` on the setter, and a bad `direction` enum value — all at
 *     the MCP boundary, never reaching the bridge
 *   - an app-side error (e.g. SixteenLevelsError's teaching text) surfaces as
 *     an MCP tool error, message verbatim
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
  client = new Client({ name: "sixteen-levels-test-client", version: "0.0.0" });
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
  assert.ok(first && first.type === "text", `expected a text content item, got: ${JSON.stringify(result.content)}`);
  return JSON.parse(first.text as string);
}

// ---------------------------------------------------------------------------
// instrument_spread_slice
// ---------------------------------------------------------------------------

test("instrument_spread_slice forwards {trackId, zoneId} with no direction key when omitted", async () => {
  const trackId = randomUUID();
  const zoneId = randomUUID();
  const spreadZoneId = randomUUID();
  const stubbed = {
    id: spreadZoneId,
    path: "/tmp/kick.wav",
    rootPitch: 36,
    minPitch: 36,
    maxPitch: 51,
    gain: 1,
    spreadDirection: "up",
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "instrument_spread_slice",
    arguments: { trackId, zoneId },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "instrument.spreadSlice");
  assert.deepEqual(
    calls[0]!.params,
    { trackId, zoneId },
    "an omitted direction must not arrive as a stray key (e.g. undefined) on the wire"
  );
  assert.deepEqual(parseJSON(result as any), stubbed, "the app's new zone round-trips verbatim");
});

test("instrument_spread_slice forwards an explicit direction", async () => {
  const trackId = randomUUID();
  const zoneId = randomUUID();
  queuedResult = { id: randomUUID(), spreadDirection: "centered" };

  await client.callTool({
    name: "instrument_spread_slice",
    arguments: { trackId, zoneId, direction: "centered" },
  });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, { trackId, zoneId, direction: "centered" });
});

test("instrument_spread_slice rejects an unrecognized argument at the MCP boundary (never reaches the bridge)", async () => {
  const result = await client.callTool({
    name: "instrument_spread_slice",
    arguments: { trackId: randomUUID(), zoneId: randomUUID(), sourceZoneId: randomUUID() },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError, "the strict wrapper must reject unknown keys");
  assert.equal(calls.length, 0, "a rejected call never reaches the bridge");
});

test("instrument_spread_slice rejects a direction outside 'up'/'centered' at the schema layer", async () => {
  const result = await client.callTool({
    name: "instrument_spread_slice",
    arguments: { trackId: randomUUID(), zoneId: randomUUID(), direction: "down" },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError, "an out-of-enum direction must be rejected before the bridge");
  assert.equal(calls.length, 0);
});

test("instrument_spread_slice requires both trackId and zoneId", async () => {
  const missingZone = await client.callTool({
    name: "instrument_spread_slice",
    arguments: { trackId: randomUUID() },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((missingZone as any).isError);

  const missingTrack = await client.callTool({
    name: "instrument_spread_slice",
    arguments: { zoneId: randomUUID() },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((missingTrack as any).isError);
  assert.equal(calls.length, 0, "neither incomplete call reaches the bridge");
});

test("instrument_spread_slice surfaces an app-side error (e.g. noFreeWindow) as an MCP tool error, message verbatim", async () => {
  queuedError = new Error(
    "This kit fills the keyboard, so there is no room for a spread. Chop fewer pieces, or move the chop up to free some low keys."
  );

  const result = await client.callTool({
    name: "instrument_spread_slice",
    arguments: { trackId: randomUUID(), zoneId: randomUUID() },
  });

  assert.equal(calls.length, 1);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an app-side error must be a tool error, never a silent success");
  assert.match(r.content[0].text as string, /no room for a spread/, "the app's teaching message passes through verbatim");
});

test("instrument_spread_slice's description teaches what a spread is and what up/centered mean in plain words", async () => {
  const { tools } = await client.listTools();
  const registered = tools.find((t) => t.name === "instrument_spread_slice");
  assert.ok(registered, "instrument_spread_slice is registered");
  const description: string = registered!.description ?? "";
  assert.match(description, /slice/i, "explains what is being spread");
  assert.match(description, /sixteen/i, "names the sixteen pads");
  assert.match(description, /lowest/i, "explains 'up' in plain words (lowest of the sixteen)");
  assert.match(description, /middle/i, "explains 'centered' in plain words (sits in the middle)");
});

// ---------------------------------------------------------------------------
// instrument_set_spread_direction
// ---------------------------------------------------------------------------

test("instrument_set_spread_direction forwards {trackId, spreadZoneId, direction} and round-trips the zone + changed flag", async () => {
  const trackId = randomUUID();
  const spreadZoneId = randomUUID();
  const stubbed = {
    id: spreadZoneId,
    rootPitch: 44,
    minPitch: 36,
    maxPitch: 51,
    spreadDirection: "centered",
    changed: true,
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "instrument_set_spread_direction",
    arguments: { trackId, spreadZoneId, direction: "centered" },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "instrument.setSpreadDirection");
  assert.deepEqual(calls[0]!.params, { trackId, spreadZoneId, direction: "centered" });
  assert.deepEqual(parseJSON(result as any), stubbed, "the zone plus changed round-trips verbatim");
});

test("instrument_set_spread_direction requires direction — no default, unlike instrument_spread_slice", async () => {
  const result = await client.callTool({
    name: "instrument_set_spread_direction",
    arguments: { trackId: randomUUID(), spreadZoneId: randomUUID() },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError, "direction is required on the setter — there is no 'up' default");
  assert.equal(calls.length, 0);
});

test("instrument_set_spread_direction rejects an unrecognized argument at the MCP boundary (never reaches the bridge)", async () => {
  const result = await client.callTool({
    name: "instrument_set_spread_direction",
    arguments: { trackId: randomUUID(), spreadZoneId: randomUUID(), direction: "up", zoneId: randomUUID() },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError, "the strict wrapper must reject unknown keys (zoneId is not this tool's id key)");
  assert.equal(calls.length, 0);
});

test("instrument_set_spread_direction rejects a direction outside 'up'/'centered' at the schema layer", async () => {
  const result = await client.callTool({
    name: "instrument_set_spread_direction",
    arguments: { trackId: randomUUID(), spreadZoneId: randomUUID(), direction: "sideways" },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError);
  assert.equal(calls.length, 0);
});

test("instrument_set_spread_direction surfaces an app-side error (e.g. notASpread) as an MCP tool error, message verbatim", async () => {
  queuedError = new Error(
    "Zone 11111111-1111-1111-1111-111111111111 is not a Sixteen Levels spread (a spread is exactly 16 keys wide, rooted on its first or ninth key), so its direction was not changed — that would edit a zone the spread did not make."
  );

  const result = await client.callTool({
    name: "instrument_set_spread_direction",
    arguments: { trackId: randomUUID(), spreadZoneId: randomUUID(), direction: "up" },
  });

  assert.equal(calls.length, 1);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /not a Sixteen Levels spread/, "the app's teaching message passes through verbatim");
});

test("instrument_set_spread_direction's description teaches the no-op case and which tool reads zone ids first", async () => {
  const { tools } = await client.listTools();
  const registered = tools.find((t) => t.name === "instrument_set_spread_direction");
  assert.ok(registered, "instrument_set_spread_direction is registered");
  const description: string = registered!.description ?? "";
  assert.match(description, /no-op/i, "explains that re-requesting the same direction is a harmless no-op");
  assert.match(description, /instrument_describe_sampler/, "names the tool that reads zone ids first");
  assert.match(description, /changed/, "explains the changed flag");
});
