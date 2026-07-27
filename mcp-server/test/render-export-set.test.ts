/**
 * render-export-set.test.ts — wiring coverage for the m23-m1 export-set params:
 * `render_stems` += includeMasteredMixdown / masteredLufsTarget /
 * masteredTruePeakCeilingDb, and `render_bounce` + `render_mixdown` +=
 * excludeTrackIds.
 *
 * The track-reorder.test.ts pattern verbatim: monkeypatch
 * `DawBridge.prototype.send` before importing the real `McpServer`, drive the
 * tools over an in-memory transport, and assert:
 *   - each new param reaches the app under EXACTLY its wire name;
 *   - the DEFAULT call is unchanged ON THE WIRE — `bridge.send` JSON-stringifies
 *     its params, so an omitted optional never becomes a key. Every assertion
 *     here compares the JSON round-trip, not the raw JS object, because that is
 *     what the app actually receives (and `rejectUnknownKeys` actually sees);
 *   - the boundary rejects out-of-range loudness targets and malformed ids
 *     before the bridge, and an app-side refusal surfaces verbatim.
 *
 * m23-m1 adds PARAMS, never verbs: no tool is added or renamed here, so the
 * bijection audit in audit-tools.test.ts is untouched by design.
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
  client = new Client({ name: "render-export-set-test-client", version: "0.0.0" });
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

/** What the app actually receives: `DawBridge.send` JSON-stringifies, which
 * DROPS undefined-valued keys. Asserting on the raw JS object would let an
 * omitted optional look like a new wire key (or vice versa). */
function wireParams(call: RecordedCall): Record<string, unknown> {
  return JSON.parse(JSON.stringify(call.params)) as Record<string, unknown>;
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function parseJSON(result: any): any {
  const first = result.content[0];
  assert.ok(
    first && first.type === "text",
    `expected a text content item, got: ${JSON.stringify(result.content)}`
  );
  return JSON.parse(first.text as string);
}

// ---------------------------------------------------------------------------
// render_stems — the mastered sibling
// ---------------------------------------------------------------------------

test("render_stems forwards the three mastered params under their exact wire names", async () => {
  const stubbed = {
    directory: "/tmp/stems",
    sampleRate: 48000,
    durationSeconds: 4,
    channels: 2,
    stems: [],
    masteredMixdown: {
      path: "/tmp/stems/00 Mastered Mix.wav",
      report: { appliedGainDb: -3.2, limitedByCeiling: false },
    },
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "render_stems",
    arguments: {
      durationSeconds: 4,
      includeMasteredMixdown: true,
      masteredLufsTarget: -14,
      masteredTruePeakCeilingDb: -1.5,
    },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "render.stems");
  assert.deepEqual(wireParams(calls[0]!), {
    durationSeconds: 4,
    fromBeat: 0,
    includeMixdown: false,
    includeMasteredMixdown: true,
    masteredLufsTarget: -14,
    masteredTruePeakCeilingDb: -1.5,
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbed);
});

test("render_stems' default call is UNCHANGED on the wire — no mastered keys appear", async () => {
  queuedResult = { directory: "/tmp/stems", sampleRate: 48000, durationSeconds: 4, channels: 2, stems: [] };

  await client.callTool({ name: "render_stems", arguments: { durationSeconds: 4 } });

  assert.equal(calls.length, 1);
  const params = wireParams(calls[0]!);
  assert.deepEqual(params, { durationSeconds: 4, fromBeat: 0, includeMixdown: false });
  assert.ok(!("includeMasteredMixdown" in params) || params.includeMasteredMixdown === false);
  assert.ok(!("masteredLufsTarget" in params));
  assert.ok(!("masteredTruePeakCeilingDb" in params));
});

test("includeMixdown and includeMasteredMixdown are INDEPENDENT flags, both forwarded", async () => {
  queuedResult = {};
  await client.callTool({
    name: "render_stems",
    arguments: { durationSeconds: 1, includeMixdown: true, includeMasteredMixdown: true },
  });
  const params = wireParams(calls[0]!);
  assert.equal(params.includeMixdown, true);
  assert.equal(params.includeMasteredMixdown, true);
});

test("the boundary rejects out-of-range mastered loudness params before the bridge", async () => {
  const bad: Array<Record<string, unknown>> = [
    { durationSeconds: 1, includeMasteredMixdown: true, masteredLufsTarget: 5 },
    { durationSeconds: 1, includeMasteredMixdown: true, masteredLufsTarget: -80 },
    { durationSeconds: 1, includeMasteredMixdown: true, masteredTruePeakCeilingDb: -25 },
    { durationSeconds: 1, includeMasteredMixdown: true, masteredTruePeakCeilingDb: 3 },
    // The likeliest wrong keys: render_bounce's names, which do NOT normalize
    // the mastered sibling and must not be silently accepted here.
    { durationSeconds: 1, includeMasteredMixdown: true, lufsTarget: -14 },
    { durationSeconds: 1, includeMasteredMixdown: true, truePeakCeilingDb: -1 },
  ];
  for (const args of bad) {
    const result = await client.callTool({ name: "render_stems", arguments: args });
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    assert.ok((result as any).isError, `expected a boundary rejection for ${JSON.stringify(args)}`);
  }
  assert.equal(calls.length, 0, "no rejected call ever reached the bridge");
});

test("an app-side refusal of a mastered normalization surfaces verbatim", async () => {
  queuedError = new Error(
    "program is silent below the -70 LUFS gate — cannot loudness-normalize"
  );
  const result = await client.callTool({
    name: "render_stems",
    arguments: { durationSeconds: 1, includeMasteredMixdown: true, masteredLufsTarget: -14 },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const failed = result as any;
  assert.ok(failed.isError);
  assert.match(failed.content[0].text as string, /-70 LUFS gate/);
});

// ---------------------------------------------------------------------------
// render_bounce / render_mixdown — excludeTrackIds
// ---------------------------------------------------------------------------

for (const [tool, command] of [
  ["render_bounce", "render.bounce"],
  ["render_mixdown", "render.mixdown"],
] as const) {
  test(`${tool} forwards excludeTrackIds verbatim and round-trips excludedTracks`, async () => {
    const vocalId = randomUUID();
    queuedResult = {
      path: "/tmp/instrumental.wav",
      durationSeconds: 10,
      sampleRate: 48000,
      channels: 2,
      excludedTracks: ["Lead Vocal"],
    };

    const result = await client.callTool({
      name: tool,
      arguments: { path: "/tmp/instrumental.wav", excludeTrackIds: [vocalId] },
    });

    assert.equal(calls.length, 1, "exactly one bridge call");
    assert.equal(calls[0]!.command, command);
    assert.deepEqual(wireParams(calls[0]!).excludeTrackIds, [vocalId]);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    assert.deepEqual(parseJSON(result as any).excludedTracks, ["Lead Vocal"]);
  });

  test(`${tool}'s default call is UNCHANGED on the wire — no excludeTrackIds key`, async () => {
    queuedResult = { path: "/tmp/mix.wav", durationSeconds: 10, sampleRate: 48000, channels: 2 };

    await client.callTool({ name: tool, arguments: { path: "/tmp/mix.wav" } });

    const params = wireParams(calls[0]!);
    assert.ok(!("excludeTrackIds" in params), "the default path grew a wire key");
  });

  test(`${tool} rejects a malformed excludeTrackIds at the boundary`, async () => {
    const bad: Array<Record<string, unknown>> = [
      { excludeTrackIds: "not-an-array" },
      { excludeTrackIds: [""] },
      { excludeTrackIds: [123] },
      // The plausible wrong key: render_stems' selection param, which means
      // the OPPOSITE (which tracks to KEEP) and is not accepted here.
      { excludeTrackIds: [randomUUID()], trackIds: [randomUUID()] },
    ];
    for (const args of bad) {
      const result = await client.callTool({ name: tool, arguments: args });
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      assert.ok((result as any).isError, `expected a rejection for ${JSON.stringify(args)}`);
    }
    assert.equal(calls.length, 0, "no rejected call ever reached the bridge");
  });

  test(`${tool} surfaces the app's unknown-track refusal verbatim`, async () => {
    const stray = randomUUID();
    queuedError = new Error(`No track with id ${stray}.`);
    const result = await client.callTool({
      name: tool,
      arguments: { excludeTrackIds: [stray] },
    });
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const failed = result as any;
    assert.ok(failed.isError);
    assert.match(failed.content[0].text as string, new RegExp(`No track with id ${stray}`));
  });

  test(`${tool}'s excludeTrackIds description teaches what leaves with the track`, async () => {
    const tools = await client.listTools();
    const found = tools.tools.find((t) => t.name === tool);
    assert.ok(found, `${tool} must be registered`);
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const description = ((found!.inputSchema as any).properties?.excludeTrackIds?.description ??
      "") as string;
    // The three facts a caller cannot discover by trying it once.
    assert.match(description, /NOT MODIFIED/i);
    assert.match(description, /reverb|TAIL/i);
    assert.match(description, /sidechain/i);
  });
}
