/**
 * clip-quantize-audio-divisions.test.ts — m32-b1 wiring coverage for the two
 * additive params on clip_quantize_audio (CHOP-TO-TIMELINE): `divisions` and
 * the now-optional `gridBeats`.
 *
 * The clip-slice-to-sampler.test.ts stub-bridge pattern verbatim: monkeypatch
 * `DawBridge.prototype.send` before importing the real `McpServer`, drive the
 * tool over an in-memory transport, and assert:
 *   - `divisions` forwards to clip.quantizeAudio verbatim, and an OMITTED
 *     optional forwards as undefined rather than a fabricated default (the app
 *     owns every default; a default duplicated here is one that will drift)
 *   - ⭐ `gridBeats` is now OPTIONAL AT THE SCHEMA LAYER, and the call reaches
 *     the bridge without it — the strength-0 rule is the APP's to enforce, and
 *     a zod `.optional()` that still blocked the call would make the app-side
 *     relaxation unreachable. A GREEN SWIFT RUN SAYS NOTHING ABOUT THIS.
 *   - the divisions range guard fires at the schema layer, with a positive
 *     control that its boundary values are accepted
 *   - the app's mode-scoped refusal (sensitivity alongside divisions) crosses
 *     the boundary as an MCP tool error, message intact
 *   - ⭐ the DESCRIPTION names the chop use case. Discoverability here is a
 *     DESCRIPTION problem — a `clip.chop` alias was DEFERRED precisely because
 *     this is meant to buy it at description cost, so this assertion is the
 *     feature, not decoration.
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
  client = new Client({ name: "clip-quantize-audio-divisions-test-client", version: "0.0.0" });
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

/** Four butt-joined slices — what a `divisions: 4` chop returns. */
function makeStubbedChop() {
  return {
    clips: [
      { id: "7A000000-0000-4000-8000-000000000001", startBeat: 0, lengthBeats: 1 },
      {
        id: "7A000000-0000-4000-8000-000000000002",
        startBeat: 1,
        lengthBeats: 1,
        startOffsetSeconds: 0.5,
      },
      {
        id: "7A000000-0000-4000-8000-000000000003",
        startBeat: 2,
        lengthBeats: 1,
        startOffsetSeconds: 1,
      },
      {
        id: "7A000000-0000-4000-8000-000000000004",
        startBeat: 3,
        lengthBeats: 1,
        startOffsetSeconds: 1.5,
      },
    ],
  };
}

test("clip_quantize_audio forwards divisions and omits every unset optional", async () => {
  const trackId = randomUUID();
  const clipId = randomUUID();
  queuedResult = makeStubbedChop();

  const result = (await client.callTool({
    name: "clip_quantize_audio",
    arguments: { trackId, clipId, divisions: 8, strength: 0 },
  })) as any;

  assert.ok(!result.isError, JSON.stringify(result.content));
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.quantizeAudio");
  assert.deepEqual(calls[0]!.params, {
    trackId,
    clipId,
    gridBeats: undefined,
    divisions: 8,
    strength: 0,
    swing: undefined,
    sensitivity: undefined,
    crossfadeMs: undefined,
    groove: undefined,
  });
});

test("⭐ gridBeats is OPTIONAL at the schema layer — a strength-0 chop reaches the bridge", async () => {
  const trackId = randomUUID();
  const clipId = randomUUID();
  queuedResult = makeStubbedChop();

  const result = (await client.callTool({
    name: "clip_quantize_audio",
    arguments: { trackId, clipId, strength: 0 },
  })) as any;

  assert.ok(!result.isError, "strength-0 with no gridBeats must reach the app");
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.params["gridBeats"], undefined);

  // POSITIVE CONTROL: the schema still REQUIRES trackId/clipId, so "it reached
  // the bridge" is not simply "this tool validates nothing".
  calls = [];
  const missing = (await client.callTool({
    name: "clip_quantize_audio",
    arguments: { clipId, strength: 0 },
  })) as any;
  assert.ok(missing.isError, "a missing trackId must still be rejected before the bridge");
  assert.equal(calls.length, 0);
});

test("clip_quantize_audio still forwards the full quantize surface unchanged", async () => {
  const trackId = randomUUID();
  const clipId = randomUUID();
  queuedResult = makeStubbedChop();

  await client.callTool({
    name: "clip_quantize_audio",
    arguments: {
      trackId,
      clipId,
      gridBeats: 0.25,
      strength: 0.5,
      swing: 62,
      sensitivity: 0.7,
      crossfadeMs: 20,
      groove: "swing16:62",
    },
  });

  assert.deepEqual(calls[0]!.params, {
    trackId,
    clipId,
    gridBeats: 0.25,
    divisions: undefined,
    strength: 0.5,
    swing: 62,
    sensitivity: 0.7,
    crossfadeMs: 20,
    groove: "swing16:62",
  });
});

test("clip_quantize_audio's divisions range guard fires at the schema layer", async () => {
  const trackId = randomUUID();
  const clipId = randomUUID();
  const rejected: Array<Record<string, unknown>> = [
    { divisions: 1 }, // below 2
    { divisions: 0 },
    { divisions: 129 }, // above 128
    { divisions: 4.5 }, // not an integer
    { gridBeats: 0 }, // still not positive when supplied
    { gridBeats: -1 },
    { strength: 1.5 },
    { swing: 80 },
    { sensitivity: -1 },
    { crossfadeMs: 51 },
  ];
  for (const bad of rejected) {
    const result = (await client.callTool({
      name: "clip_quantize_audio",
      arguments: { trackId, clipId, ...bad },
    })) as any;
    assert.ok(result.isError, `expected ${JSON.stringify(bad)} to be rejected`);
  }
  assert.equal(calls.length, 0, "schema rejections never reach the bridge");

  // POSITIVE CONTROL: the boundary values these guards bracket are ACCEPTED —
  // a schema that rejected everything would pass every assertion above.
  queuedResult = makeStubbedChop();
  const ok = (await client.callTool({
    name: "clip_quantize_audio",
    arguments: { trackId, clipId, divisions: 2, strength: 0 },
  })) as any;
  assert.ok(!ok.isError, "divisions 2 must actually pass");
  queuedResult = makeStubbedChop();
  const ok128 = (await client.callTool({
    name: "clip_quantize_audio",
    arguments: { trackId, clipId, divisions: 128, strength: 0 },
  })) as any;
  assert.ok(!ok128.isError, "divisions 128 must actually pass");
  assert.equal(calls.length, 2);
});

test("clip_quantize_audio is registered via the STRICT-SCHEMA wrapper: an unrecognized argument IS rejected", async () => {
  const result = (await client.callTool({
    name: "clip_quantize_audio",
    arguments: { trackId: randomUUID(), clipId: randomUUID(), division: 8 },
  })) as any;
  assert.ok(result.isError, "an unrecognized argument must be rejected at the MCP boundary");
  assert.equal(calls.length, 0, "and must never reach the bridge");
});

test("the app's mode-scoped refusal (sensitivity + divisions) surfaces verbatim", async () => {
  queuedError = new Error(
    "'sensitivity' only applies to transient slicing — it is the detector knob, and " +
      "'divisions' cuts the window into equal parts without running the detector; send one " +
      "or the other, not both"
  );
  const result = (await client.callTool({
    name: "clip_quantize_audio",
    arguments: {
      trackId: randomUUID(),
      clipId: randomUUID(),
      divisions: 8,
      strength: 0,
      sensitivity: 0.7,
    },
  })) as any;
  assert.ok(result.isError);
  const text = result.content[0].text as string;
  assert.match(text, /only applies to transient slicing/);
  assert.match(text, /not both/);
  assert.equal(calls.length, 1, "the refusal came from the app, not the schema");
});

test("⭐ clip_quantize_audio's description names the CHOP use case and the divisions fallback", async () => {
  const { tools } = (await client.listTools()) as any;
  const tool = tools.find((t: any) => t.name === "clip_quantize_audio");
  assert.ok(tool, "clip_quantize_audio must be registered");
  const description = tool.description as string;
  const title = tool.title ?? tool.annotations?.title ?? "";

  // ⭐ THE ITEM'S ACTUAL DELIVERABLE. An agent told "chop this loop into eight
  // pieces" must find THIS tool; a `clip.chop` alias was deferred on the
  // premise that these words do the job.
  assert.match(description, /pure CHOP/);
  assert.match(description, /strength/);
  assert.match(description, /rearrange/i);
  assert.match(`${title} ${description}`, /chop/i);
  // The divisions fallback, and WHEN to reach for it.
  assert.match(description, /divisions/);
  assert.match(description, /equal parts/i);
  assert.match(description, /drones|ambient|already-quantized/i);
  // The gridBeats relaxation, so an agent does not invent a grid it does not need.
  assert.match(description, /OMITTED|omitted/);
  // Mode-scoping stated, not left to be discovered by a silent no-op.
  assert.match(description, /REJECTED|rejected/);
  // And the neighbour it must not be confused with.
  assert.match(description, /clip_slice_to_sampler/);
});
