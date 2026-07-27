/**
 * track-reorder.test.ts — wiring coverage for track_reorder
 * (m23-h: the ONE track-ordering verb behind the arrange header drag).
 *
 * The note-audition.test.ts pattern verbatim: monkeypatch
 * `DawBridge.prototype.send` before importing the real `McpServer`, drive the
 * tool over an in-memory transport, and assert:
 *   - the tool forwards exactly `track.reorder {trackId, index}`
 *   - the app's {index, order} answer round-trips verbatim
 *   - FINAL-index semantics are what the DESCRIPTION teaches, in both
 *     directions (an agent that assumed SwiftUI's "insert before" offset would
 *     drop tracks one slot short on every down-move)
 *   - the Zod bounds + the strict wrapper reject at the MCP boundary, never at
 *     the app: a non-integer index, a missing index, and the `toIndex` typo
 *     (the Swift parameter label, the most plausible wrong key)
 *   - an app-side refusal (unknown track) surfaces verbatim
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
  client = new Client({ name: "track-reorder-test-client", version: "0.0.0" });
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

test("track_reorder forwards {trackId, index} and round-trips the order verbatim", async () => {
  const ids = [randomUUID(), randomUUID(), randomUUID(), randomUUID()];
  // A DOWN move under FINAL-index semantics: ids[0] -> 2 gives 1, 2, 0, 3.
  const stubbed = { index: 2, order: [ids[1], ids[2], ids[0], ids[3]] };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "track_reorder",
    arguments: { trackId: ids[0], index: 2 },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "track.reorder");
  assert.deepEqual(calls[0]!.params, { trackId: ids[0], index: 2 });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbed);
});

test("an UP move forwards the same shape (no direction-dependent translation)", async () => {
  const ids = [randomUUID(), randomUUID(), randomUUID(), randomUUID()];
  queuedResult = { index: 1, order: [ids[0], ids[3], ids[1], ids[2]] };

  await client.callTool({ name: "track_reorder", arguments: { trackId: ids[3], index: 1 } });

  assert.equal(calls.length, 1);
  // The tool is a pass-through: it must NOT adjust the index for direction.
  assert.deepEqual(calls[0]!.params, { trackId: ids[3], index: 1 });
});

test("index 0 (move to the top) reaches the app as 0, not as a falsy omission", async () => {
  const trackId = randomUUID();
  queuedResult = { index: 0, order: [trackId] };

  await client.callTool({ name: "track_reorder", arguments: { trackId, index: 0 } });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, { trackId, index: 0 });
});

test("the boundary rejects a bad index / a missing index / the toIndex typo", async () => {
  const trackId = randomUUID();
  const bad: Array<Record<string, unknown>> = [
    { trackId }, // index is required
    { trackId, index: 1.5 }, // not an integer
    { trackId, index: "2" }, // not a number
    { trackId, toIndex: 2 }, // the Swift label, not the wire key
    { trackId, index: 2, above: true }, // unknown key (strict wrapper)
    { index: 2 }, // trackId is required
    { trackId: "", index: 2 }, // empty id
  ];

  for (const args of bad) {
    const result = await client.callTool({ name: "track_reorder", arguments: args });
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    assert.ok((result as any).isError, `expected a boundary rejection for ${JSON.stringify(args)}`);
  }
  assert.equal(calls.length, 0, "no rejected call ever reached the bridge");
});

test("a negative index is PASSED THROUGH — the app clamps it, the boundary must not guess", async () => {
  const trackId = randomUUID();
  queuedResult = { index: 0, order: [trackId] };

  const result = await client.callTool({
    name: "track_reorder",
    arguments: { trackId, index: -5 },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok(!(result as any).isError, "clamping is the app's job, not a boundary rejection");
  assert.deepEqual(calls[0]!.params, { trackId, index: -5 });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.equal(parseJSON(result as any).index, 0);
});

test("an app-side refusal surfaces as an MCP tool error, message verbatim", async () => {
  queuedError = new Error("track not found: 00000000-0000-0000-0000-000000000000");

  const result = await client.callTool({
    name: "track_reorder",
    arguments: { trackId: randomUUID(), index: 1 },
  });

  assert.equal(calls.length, 1);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "an app refusal is a tool error");
  assert.match(r.content[0].text as string, /track not found/);
});

test("the description teaches FINAL-index semantics with a worked example", async () => {
  const listed = await client.listTools();
  const tool = listed.tools.find((t) => t.name === "track_reorder");
  assert.ok(tool, "track_reorder is listed");
  const description = tool!.description ?? "";
  // An agent that assumed "insert before this index" would land every down-move
  // one slot short, so the description must say which convention this is AND
  // show it — a pinned example is what makes the teaching checkable.
  assert.match(description, /FINAL position/);
  assert.match(description, /\[Snare, Bass, Kick, Vox\]/);
});
