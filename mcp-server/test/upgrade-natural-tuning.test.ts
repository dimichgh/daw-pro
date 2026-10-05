/**
 * upgrade-natural-tuning.test.ts — wiring coverage for X4's ONE upgrade path
 * (docs/design/2026-09-25-natural-tuning.md §X4): clip_upgrade_natural_tuning
 * over `ProjectStore.upgradeToNaturalTuning`.
 *
 * The clip-detect-pitch.test.ts / natural-tuning.test.ts / note-shape.test.ts
 * stub-bridge pattern verbatim: monkeypatch `DawBridge.prototype.send` before
 * importing the real `McpServer`, drive the tool over an in-memory transport,
 * and assert:
 *   - clip_upgrade_natural_tuning forwards {clipId} verbatim, response round-trips
 *   - a no-op success (already-natural vocal) round-trips too -- the tool
 *     text's own "harmless to call... nothing changes" claim, checked at the
 *     schema/wire boundary (the APP decides whether a given call is a no-op;
 *     this file only proves the plumbing does not get in the way of a bare
 *     success either way)
 *   - requires clipId (UUID) at the schema layer, zero bridge calls
 *   - registered via the STRICT-SCHEMA wrapper: an unrecognized argument IS
 *     rejected
 *   - an app-side no-table refusal surfaces as an MCP tool error, verbatim
 *   - the tool's own description explains the no-op and the narrower-than-
 *     predatesNaturalTuning nuance; clip_get_pitch_edits' description names
 *     which per-note verbs upgrade a legacy vocal and points at this tool
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
  client = new Client({ name: "upgrade-natural-tuning-test-client", version: "0.0.0" });
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

function makeStubbedResponse(extra: Record<string, unknown> = {}) {
  return {
    clipId: randomUUID(),
    hasPitchEdits: true,
    hasTuningEdits: true,
    formantCorrection: 1.0,
    keepConsonantsUntuned: true,
    transitionSlopeCentsPerSecond: 3000,
    predatesNaturalTuning: false,
    segments: [],
    ...extra,
  };
}

test("clip_upgrade_natural_tuning forwards {clipId} verbatim, response round-trips", async () => {
  const clipId = randomUUID();
  const stubbed = makeStubbedResponse({ clipId });
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "clip_upgrade_natural_tuning",
    arguments: { clipId },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.upgradeNaturalTuning");
  assert.deepEqual(calls[0]!.params, { clipId });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.equal(r.isError, undefined);
  assert.deepEqual(JSON.parse(r.content[0].text as string), stubbed);
});

test("clip_upgrade_natural_tuning: a no-op success (already-natural vocal) round-trips too, unchanged", async () => {
  const clipId = randomUUID();
  // predatesNaturalTuning already false, fields already at the seed values --
  // exactly what the app returns on the documented no-op path. Nothing at
  // this layer distinguishes it from the happy path: the no-op-ness is an
  // app-side fact, not a wire-shape difference.
  const stubbed = makeStubbedResponse({ clipId });
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "clip_upgrade_natural_tuning",
    arguments: { clipId },
  });

  assert.equal(calls.length, 1);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.equal(r.isError, undefined);
  assert.deepEqual(JSON.parse(r.content[0].text as string), stubbed);
});

test("clip_upgrade_natural_tuning requires a UUID clipId at the schema layer, zero bridge calls", async () => {
  const missingClipId = await client.callTool({
    name: "clip_upgrade_natural_tuning",
    arguments: {},
  });
  const badClipId = await client.callTool({
    name: "clip_upgrade_natural_tuning",
    arguments: { clipId: "not-a-uuid" },
  });
  for (const response of [missingClipId, badClipId]) {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    assert.ok((response as any).isError, JSON.stringify(response));
  }
  assert.equal(calls.length, 0);
});

test("clip_upgrade_natural_tuning is registered via the STRICT-SCHEMA wrapper: an unrecognized argument IS rejected", async () => {
  const result = await client.callTool({
    name: "clip_upgrade_natural_tuning",
    arguments: { clipId: randomUUID(), bogus: true },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError);
  assert.equal(calls.length, 0);
});

test("clip_upgrade_natural_tuning surfaces the app's no-tuning refusal as an MCP tool error, message verbatim", async () => {
  queuedError = new Error(
    "This clip has no tuning to update. Tune it first (the note editor or `clip.autoCorrectPitch`); new tuning already keeps the singer's voice size, consonants and slides."
  );
  const result = await client.callTool({
    name: "clip_upgrade_natural_tuning",
    arguments: { clipId: randomUUID() },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /has no tuning to update/);
});

test("clip_upgrade_natural_tuning's description explains the no-op and the narrower-than-predatesNaturalTuning nuance", async () => {
  const listed = await client.listTools();
  const tool = listed.tools.find((t) => t.name === "clip_upgrade_natural_tuning");
  assert.ok(tool, "clip_upgrade_natural_tuning is registered");
  const description = tool!.description ?? "";
  assert.match(description, /already fully natural/);
  assert.match(description, /nothing changes and no undo step is added/);
  assert.match(description, /clip_set_pitch_transition_smoothness/);
  assert.match(description, /predatesNaturalTuning/);
});

test("clip_get_pitch_edits' description explains which per-note verbs upgrade a legacy vocal and names clip_upgrade_natural_tuning", async () => {
  const listed = await client.listTools();
  const tool = listed.tools.find((t) => t.name === "clip_get_pitch_edits");
  assert.ok(tool, "clip_get_pitch_edits is registered");
  const description = tool!.description ?? "";
  assert.match(description, /the first per-note edit/);
  assert.match(description, /the set-level verbs do not/);
  assert.match(description, /clip_upgrade_natural_tuning/);
});

// --- W7-WIRE2 (the wire round after W7-D2): a chosen consonant OFF is kept,
// and the D41 no-op wording fix -----------------------------------------

test("clip_upgrade_natural_tuning says a consonant switch-off is kept, like a slide smoothness you chose", async () => {
  const listed = await client.listTools();
  const tool = listed.tools.find((t) => t.name === "clip_upgrade_natural_tuning");
  assert.ok(tool, "clip_upgrade_natural_tuning is registered");
  const description = tool!.description ?? "";
  assert.match(description, /unless you switched that off with clip_set_consonant_protection/);
  assert.match(description, /a switch you made is kept, like a slide smoothness you chose/);
});

test("clip_upgrade_natural_tuning says the SAME update is the first per-note edit THAT CHANGES A NOTE", async () => {
  const listed = await client.listTools();
  const tool = listed.tools.find((t) => t.name === "clip_upgrade_natural_tuning");
  assert.ok(tool, "clip_upgrade_natural_tuning is registered");
  const description = tool!.description ?? "";
  assert.match(description, /the SAME update the first per-note edit THAT CHANGES A NOTE on such a vocal/);
  assert.match(
    description,
    /but only when the edit actually changes something -- one that changes nothing leaves an old vocal exactly as it is/
  );
});
