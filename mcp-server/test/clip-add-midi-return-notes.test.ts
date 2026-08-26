/**
 * clip-add-midi-return-notes.test.ts — m30-b: `clip_add_midi` echoes every
 * written note (each with a freshly-minted id) back on the hot path of every
 * composing session; a 64-note clip measured ~6 KB, and the documented max
 * is 4096 notes. The useful result is almost always just the clip id.
 *
 * Adds an OPT-OUT param, `returnNotes` (default true — the pre-existing
 * behavior is UNCHANGED byte-for-byte when the caller doesn't pass it).
 * `returnNotes: false` drops the `notes` array from the response and adds
 * `notesOmitted: true` + `noteCount` instead, so it can never be confused
 * with a genuinely empty clip (`notes: []`, no `notesOmitted` key). The
 * omitted notes are always recoverable via clip_get_notes.
 *
 * This only shapes what the MCP layer hands back to the calling agent — the
 * app's own `clip.addMIDI` response still crosses the WebSocket in full
 * either way (Swift-side change, not made here — see the close-out report).
 *
 * Same stub-bridge / InMemoryTransport pattern as nested-strict-gap.test.ts.
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
  client = new Client({ name: "clip-add-midi-return-notes-test-client", version: "0.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
});

after(async () => {
  await client?.close();
});

beforeEach(() => {
  calls = [];
  queuedResult = undefined;
});

function parsed(result: any): unknown {
  return JSON.parse(result.content[0].text);
}

const threeNotes = [
  { id: randomUUID(), pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1 },
  { id: randomUUID(), pitch: 64, velocity: 100, startBeat: 1, lengthBeats: 1 },
  { id: randomUUID(), pitch: 67, velocity: 100, startBeat: 2, lengthBeats: 1 },
];

// ---------------------------------------------------------------------------
// Default unchanged (requirement 1)
// ---------------------------------------------------------------------------

test("clip_add_midi with returnNotes omitted echoes notes back byte-for-byte (default unchanged)", async () => {
  const trackId = randomUUID();
  const bridgeResponse = { id: randomUUID(), trackId, name: "Clip", startBeat: 0, lengthBeats: 3, notes: threeNotes };
  queuedResult = bridgeResponse;
  const result = (await client.callTool({
    name: "clip_add_midi",
    arguments: { trackId, notes: [{ pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1 }] },
  })) as any;
  assert.ok(!result.isError);
  assert.deepStrictEqual(parsed(result), bridgeResponse);
  // `returnNotes` must never leak into the bridge call — the app's own
  // clip.addMIDI does not know this param and rejects unknown keys.
  assert.equal(calls.length, 1);
  assert.deepStrictEqual(Object.keys(calls[0]!.params).sort(), [
    "atBeat",
    "lengthBeats",
    "name",
    "notes",
    "trackId",
  ]);
});

test("clip_add_midi with returnNotes: true explicitly echoes notes back byte-for-byte", async () => {
  const trackId = randomUUID();
  const bridgeResponse = { id: randomUUID(), trackId, notes: threeNotes };
  queuedResult = bridgeResponse;
  const result = (await client.callTool({
    name: "clip_add_midi",
    arguments: { trackId, notes: [], returnNotes: true },
  })) as any;
  assert.ok(!result.isError);
  assert.deepStrictEqual(parsed(result), bridgeResponse);
  assert.ok(!("returnNotes" in calls[0]!.params));
});

// ---------------------------------------------------------------------------
// Opt-out honoured (requirement 1/2/3)
// ---------------------------------------------------------------------------

test("clip_add_midi with returnNotes: false omits notes and reports notesOmitted + noteCount", async () => {
  const trackId = randomUUID();
  const clipId = randomUUID();
  queuedResult = { id: clipId, trackId, name: "Clip", startBeat: 0, lengthBeats: 3, notes: threeNotes };
  const result = (await client.callTool({
    name: "clip_add_midi",
    arguments: { trackId, notes: [{ pitch: 60, startBeat: 0 }], returnNotes: false },
  })) as any;
  assert.ok(!result.isError);
  const body = parsed(result) as any;
  assert.equal(body.id, clipId);
  assert.equal(body.trackId, trackId);
  assert.equal("notes" in body, false, "notes array must be absent, not just empty");
  assert.equal(body.notesOmitted, true);
  assert.equal(body.noteCount, 3);
  // returnNotes must not leak to the bridge either.
  assert.ok(!("returnNotes" in calls[0]!.params));
});

test("clip_add_midi returnNotes: false never reaches the bridge with the extra param (proves boundary-side handling)", async () => {
  const trackId = randomUUID();
  queuedResult = { id: randomUUID(), trackId, notes: [] };
  await client.callTool({
    name: "clip_add_midi",
    arguments: { trackId, notes: [], returnNotes: false },
  });
  assert.equal(calls.length, 1);
  assert.deepStrictEqual(Object.keys(calls[0]!.params).sort(), [
    "atBeat",
    "lengthBeats",
    "name",
    "notes",
    "trackId",
  ]);
});

// ---------------------------------------------------------------------------
// Omitted-vs-empty distinction (requirement 3) — the characteristic failure
// mode this project watches for: a response that LOOKS like a valid answer
// while being something else. A suppressed-notes clip must never read like
// a genuinely empty clip, in either direction.
// ---------------------------------------------------------------------------

test("a genuinely empty clip (default) still carries notes: [] with no notesOmitted key", async () => {
  const trackId = randomUUID();
  queuedResult = { id: randomUUID(), trackId, notes: [] };
  const result = (await client.callTool({
    name: "clip_add_midi",
    arguments: { trackId, notes: [] },
  })) as any;
  const body = parsed(result) as any;
  assert.deepStrictEqual(body.notes, []);
  assert.equal("notesOmitted" in body, false);
});

test("a suppressed EMPTY clip (returnNotes: false, 0 notes) is still distinguishable: notesOmitted true, noteCount 0, no notes key", async () => {
  const trackId = randomUUID();
  queuedResult = { id: randomUUID(), trackId, notes: [] };
  const result = (await client.callTool({
    name: "clip_add_midi",
    arguments: { trackId, notes: [], returnNotes: false },
  })) as any;
  const body = parsed(result) as any;
  assert.equal("notes" in body, false);
  assert.equal(body.notesOmitted, true);
  assert.equal(body.noteCount, 0);
});

// ---------------------------------------------------------------------------
// Wrong type rejected at the boundary (requirement — never reaches the bridge)
// ---------------------------------------------------------------------------

test("clip_add_midi rejects a non-boolean returnNotes at the MCP boundary (never reaches the bridge)", async () => {
  const trackId = randomUUID();
  const result = (await client.callTool({
    name: "clip_add_midi",
    arguments: { trackId, notes: [], returnNotes: "false" },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0);
});
