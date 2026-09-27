/**
 * quantize-grid-floor.test.ts — m23-ap I5-F4 round 3: the GRID FLOOR on the
 * three tools whose `gridBeats` reaches the song-grid slot math
 * (clip_quantize, clip_quantize_audio, groove_extract).
 *
 * The app refuses a grid finer than 1/1024 beat (0.0009765625), or a
 * non-finite one, in words. The schema refuses the same values FIRST, so they
 * never cost a bridge round trip. The stub-bridge pattern of
 * clip-quantize-audio-divisions.test.ts: monkeypatch `DawBridge.prototype.send`
 * before importing the real `McpServer`, drive the tools over an in-memory
 * transport, and assert:
 *   - 0.0009, 1e-20, 1e-300 and Number.MIN_VALUE are refused with ZERO bridge
 *     calls, and so are 0 and -1 (the shipped `> 0` rule still holds)
 *   - ⭐ Infinity is refused by `.finite()`. It is reachable: `JSON.parse`
 *     reads a JSON-RPC `1e400` as Infinity, which `.min()` alone admits, and
 *     `JSON.stringify` would then forward it to the app as `null`, which
 *     groove.extract reads as "omitted" and replaces with its 0.25 default: a
 *     silent substitution, not an error.
 *   - POSITIVE CONTROL: 1/1024 itself and a normal 1/16 grid reach the bridge,
 *     forwarded verbatim. A schema that refused everything would pass every
 *     refusal above.
 *   - each tool's text and its gridBeats text name the floor (0.0009765625),
 *     and the listed JSON schema carries it as `minimum`, so an agent can read
 *     the bound before it trips it.
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
  client = new Client({ name: "quantize-grid-floor-test-client", version: "0.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
});

after(async () => {
  await client?.close();
});

beforeEach(() => {
  calls = [];
  queuedResult = {};
});

/** The finest grid the app accepts: 1/1024 beat. */
const FLOOR = 1 / 1024;

const TOOLS = [
  { name: "clip_quantize", command: "clip.quantize", base: () => ({ clipId: randomUUID() }) },
  {
    name: "clip_quantize_audio",
    command: "clip.quantizeAudio",
    base: () => ({ trackId: randomUUID(), clipId: randomUUID() }),
  },
  { name: "groove_extract", command: "groove.extract", base: () => ({ clipId: randomUUID(), name: "Feel" }) },
] as const;

test("the floor is 1/1024 beat, written 0.0009765625", () => {
  assert.equal(FLOOR, 0.0009765625);
  // The reachability claim behind `.finite()`: a JSON-RPC 1e400 parses to
  // Infinity, and would be forwarded to the app as null.
  assert.equal(JSON.parse('{"gridBeats":1e400}').gridBeats, Infinity);
  assert.equal(JSON.stringify({ gridBeats: Infinity }), '{"gridBeats":null}');
});

for (const tool of TOOLS) {
  test(`${tool.name} refuses a grid finer than 1/1024 beat, or not finite, at the schema: zero bridge calls`, async () => {
    const refused = [0.0009, 1e-20, 1e-300, Number.MIN_VALUE, Infinity, 0, -1];
    for (const gridBeats of refused) {
      const result = (await client.callTool({
        name: tool.name,
        arguments: { ...tool.base(), gridBeats },
      })) as any;
      assert.ok(result.isError, `${tool.name}: gridBeats ${gridBeats} must be refused`);
    }
    assert.equal(calls.length, 0, "schema refusals never reach the bridge");

    // The refusal NAMES the smallest grid allowed.
    const worded = (await client.callTool({
      name: tool.name,
      arguments: { ...tool.base(), gridBeats: 1e-20 },
    })) as any;
    assert.ok(worded.isError);
    assert.match(JSON.stringify(worded.content), /0\.0009765625/);

    // POSITIVE CONTROL: the floor itself and a normal 1/16 grid pass, verbatim.
    for (const gridBeats of [FLOOR, 0.25]) {
      const ok = (await client.callTool({
        name: tool.name,
        arguments: { ...tool.base(), gridBeats },
      })) as any;
      assert.ok(!ok.isError, `${tool.name}: gridBeats ${gridBeats} must pass: ${JSON.stringify(ok.content)}`);
    }
    assert.equal(calls.length, 2);
    assert.equal(calls[0]!.command, tool.command);
    assert.equal(calls[0]!.params["gridBeats"], FLOOR);
    assert.equal(calls[1]!.params["gridBeats"], 0.25);
  });

  test(`${tool.name}'s text names the finest grid, and its listed schema carries it`, async () => {
    const { tools } = (await client.listTools()) as any;
    const listed = tools.find((t: any) => t.name === tool.name);
    assert.ok(listed, `${tool.name} must be registered`);
    assert.match(listed.description as string, /1\/1024 beat \(0\.0009765625\)/);
    const grid = listed.inputSchema.properties.gridBeats;
    assert.match(grid.description as string, /1\/1024 beat \(0\.0009765625\)/);
    assert.equal(grid.minimum, FLOOR);
  });
}

test("groove_extract refuses a non-finite cycleBeats at the schema, and says how many slots a cycle holds", async () => {
  const refused = (await client.callTool({
    name: "groove_extract",
    arguments: { clipId: randomUUID(), name: "Feel", cycleBeats: Infinity },
  })) as any;
  assert.ok(refused.isError, "an infinite cycle must be refused");
  assert.equal(calls.length, 0);
  // POSITIVE CONTROL: a long but legal cycle reaches the app, which owns the
  // slot bound (cycleBeats / gridBeats at most 65536), refused there in words.
  const ok = (await client.callTool({
    name: "groove_extract",
    arguments: { clipId: randomUUID(), name: "Feel", cycleBeats: 64 },
  })) as any;
  assert.ok(!ok.isError, JSON.stringify(ok.content));
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.params["cycleBeats"], 64);
  const { tools } = (await client.listTools()) as any;
  const listed = tools.find((t: any) => t.name === "groove_extract");
  assert.match(listed.description as string, /65536/);
});
