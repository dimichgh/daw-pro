/**
 * m31-b-note-array-audit.test.ts — m31-b: audits every clip.* tool that can
 * carry a MIDI clip's `notes` array in its response, not just the one
 * site m30-b fixed (clip_add_midi). Sites covered here: clip_set_notes
 * (fold-in of m30-g, default UNCHANGED true), clip_duplicate,
 * clip_remove_many, clip_humanize, clip_move_many, clip_move_many_by_tracks,
 * clip_move_many_to_track (all default CHANGED to false — pure mutations
 * where the notes are near-useless echoed back), and — added in the
 * coordinator follow-up pass — clip_quantize (default CHANGED to false,
 * closing the inconsistency with its shape-identical sibling
 * clip_humanize) and clip_split (default UNCHANGED true — a split
 * TRUNCATES notes at the cut, so the result is new information the caller
 * doesn't already have, unlike a duplicate/humanize/move; ids always
 * survive stripping regardless of default).
 *
 * Shared helper under test: `stripNotesFromResult` in src/server.ts, which
 * handles all THREE response shapes — a bare clip object (notes directly
 * on it), a `{clips: [...]}` array (the *_many tools), and a
 * `{first, second}` pair (clip_split) — stripping `notes` and adding
 * `notesOmitted: true` + `noteCount` per clip, while leaving every other
 * additive field (`seedUsed`, `trimmed`, `removed`, `clamped`, every id)
 * untouched.
 *
 * Same stub-bridge / InMemoryTransport pattern as
 * clip-add-midi-return-notes.test.ts.
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
  client = new Client({ name: "m31-b-note-array-audit-test-client", version: "0.0.0" });
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

const twoNotes = [
  { id: randomUUID(), pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1 },
  { id: randomUUID(), pitch: 64, velocity: 100, startBeat: 1, lengthBeats: 1 },
];

// ---------------------------------------------------------------------------
// clip_set_notes — default UNCHANGED (true), the m30-g fold-in
// ---------------------------------------------------------------------------

test("clip_set_notes with returnNotes omitted echoes notes back (default unchanged)", async () => {
  const clipId = randomUUID();
  queuedResult = { id: clipId, notes: twoNotes };
  const result = (await client.callTool({
    name: "clip_set_notes",
    arguments: { clipId, notes: twoNotes },
  })) as any;
  assert.ok(!result.isError);
  const body = parsed(result) as any;
  assert.deepStrictEqual(body.notes, twoNotes);
  assert.equal("notesOmitted" in body, false);
});

test("clip_set_notes with returnNotes: false omits notes and reports notesOmitted + noteCount", async () => {
  const clipId = randomUUID();
  queuedResult = { id: clipId, notes: twoNotes };
  const result = (await client.callTool({
    name: "clip_set_notes",
    arguments: { clipId, notes: twoNotes, returnNotes: false },
  })) as any;
  const body = parsed(result) as any;
  assert.equal("notes" in body, false);
  assert.equal(body.notesOmitted, true);
  assert.equal(body.noteCount, 2);
  // returnNotes must never leak to the bridge.
  assert.ok(!("returnNotes" in calls[0]!.params));
});

// ---------------------------------------------------------------------------
// clip_duplicate — default CHANGED to false
// ---------------------------------------------------------------------------

test("clip_duplicate with returnNotes omitted OMITS notes by default (changed behavior)", async () => {
  const clipId = randomUUID();
  queuedResult = { id: randomUUID(), trackId: randomUUID(), notes: twoNotes, trimmed: [], removed: [] };
  const result = (await client.callTool({
    name: "clip_duplicate",
    arguments: { clipId },
  })) as any;
  const body = parsed(result) as any;
  assert.equal("notes" in body, false);
  assert.equal(body.notesOmitted, true);
  assert.equal(body.noteCount, 2);
  // Other additive fields pass through untouched.
  assert.deepStrictEqual(body.trimmed, []);
  assert.deepStrictEqual(body.removed, []);
});

test("clip_duplicate with returnNotes: true echoes notes back", async () => {
  const clipId = randomUUID();
  queuedResult = { id: randomUUID(), notes: twoNotes };
  const result = (await client.callTool({
    name: "clip_duplicate",
    arguments: { clipId, returnNotes: true },
  })) as any;
  const body = parsed(result) as any;
  assert.deepStrictEqual(body.notes, twoNotes);
  assert.equal("notesOmitted" in body, false);
  assert.ok(!("returnNotes" in calls[0]!.params));
});

test("clip_duplicate on an audio clip (no notes array) is unaffected by the strip", async () => {
  const clipId = randomUUID();
  queuedResult = { id: randomUUID(), trackId: randomUUID(), gainDb: 0 };
  const result = (await client.callTool({
    name: "clip_duplicate",
    arguments: { clipId },
  })) as any;
  const body = parsed(result) as any;
  assert.equal("notesOmitted" in body, false);
  assert.equal(body.gainDb, 0);
});

// ---------------------------------------------------------------------------
// clip_remove_many — default CHANGED to false; {clips: [...]} shape
// ---------------------------------------------------------------------------

test("clip_remove_many with returnNotes omitted OMITS notes per clip by default (changed behavior)", async () => {
  const ids = [randomUUID(), randomUUID()];
  queuedResult = {
    clips: [
      { id: ids[0], notes: twoNotes },
      { id: ids[1], notes: [] },
    ],
  };
  const result = (await client.callTool({
    name: "clip_remove_many",
    arguments: { ids },
  })) as any;
  const body = parsed(result) as any;
  assert.equal(body.clips.length, 2);
  assert.equal("notes" in body.clips[0], false);
  assert.equal(body.clips[0].notesOmitted, true);
  assert.equal(body.clips[0].noteCount, 2);
  assert.equal(body.clips[1].notesOmitted, true);
  assert.equal(body.clips[1].noteCount, 0);
});

test("clip_remove_many with returnNotes: true echoes notes back per clip", async () => {
  const ids = [randomUUID()];
  queuedResult = { clips: [{ id: ids[0], notes: twoNotes }] };
  const result = (await client.callTool({
    name: "clip_remove_many",
    arguments: { ids, returnNotes: true },
  })) as any;
  const body = parsed(result) as any;
  assert.deepStrictEqual(body.clips[0].notes, twoNotes);
});

// ---------------------------------------------------------------------------
// clip_humanize — default CHANGED to false; `seedUsed` must survive
// ---------------------------------------------------------------------------

test("clip_humanize with returnNotes omitted OMITS notes by default and keeps seedUsed", async () => {
  const clipId = randomUUID();
  queuedResult = { id: clipId, notes: twoNotes, seedUsed: 42 };
  const result = (await client.callTool({
    name: "clip_humanize",
    arguments: { clipId },
  })) as any;
  const body = parsed(result) as any;
  assert.equal("notes" in body, false);
  assert.equal(body.notesOmitted, true);
  assert.equal(body.noteCount, 2);
  assert.equal(body.seedUsed, 42);
});

test("clip_humanize with returnNotes: true echoes notes back", async () => {
  const clipId = randomUUID();
  queuedResult = { id: clipId, notes: twoNotes, seedUsed: 7 };
  const result = (await client.callTool({
    name: "clip_humanize",
    arguments: { clipId, returnNotes: true },
  })) as any;
  const body = parsed(result) as any;
  assert.deepStrictEqual(body.notes, twoNotes);
  assert.equal(body.seedUsed, 7);
});

// ---------------------------------------------------------------------------
// clip_move_many family — default CHANGED to false; {clips: [...]} shape
// ---------------------------------------------------------------------------

test("clip_move_many with returnNotes omitted OMITS notes per clip by default", async () => {
  const ids = [randomUUID()];
  queuedResult = {
    requestedDeltaBeats: 4,
    effectiveDeltaBeats: 4,
    clamped: false,
    trimmedClipIDs: [],
    removedClipIDs: [],
    clips: [{ id: ids[0], notes: twoNotes }],
  };
  const result = (await client.callTool({
    name: "clip_move_many",
    arguments: { ids, byBeats: 4 },
  })) as any;
  const body = parsed(result) as any;
  assert.equal("notes" in body.clips[0], false);
  assert.equal(body.clips[0].notesOmitted, true);
  assert.equal(body.clips[0].noteCount, 2);
  // Non-clips fields pass through untouched.
  assert.equal(body.effectiveDeltaBeats, 4);
  assert.equal(body.clamped, false);
});

test("clip_move_many_by_tracks with returnNotes omitted OMITS notes per clip by default", async () => {
  const ids = [randomUUID()];
  queuedResult = {
    requestedTrackDelta: 1,
    effectiveTrackDelta: 1,
    clampedTracks: false,
    landings: [{ clipId: ids[0], fromTrackId: randomUUID(), toTrackId: randomUUID() }],
    trimmedClipIDs: [],
    removedClipIDs: [],
    clips: [{ id: ids[0], notes: twoNotes }],
  };
  const result = (await client.callTool({
    name: "clip_move_many_by_tracks",
    arguments: { ids, byTracks: 1 },
  })) as any;
  const body = parsed(result) as any;
  assert.equal("notes" in body.clips[0], false);
  assert.equal(body.clips[0].notesOmitted, true);
  assert.equal(body.landings.length, 1);
});

test("clip_move_many_to_track with returnNotes: true echoes notes back per clip", async () => {
  const ids = [randomUUID()];
  const toTrackId = randomUUID();
  queuedResult = {
    clampedTracks: false,
    landings: [{ clipId: ids[0], fromTrackId: randomUUID(), toTrackId }],
    trimmedClipIDs: [],
    removedClipIDs: [],
    clips: [{ id: ids[0], notes: twoNotes }],
  };
  const result = (await client.callTool({
    name: "clip_move_many_to_track",
    arguments: { ids, toTrackId, returnNotes: true },
  })) as any;
  const body = parsed(result) as any;
  assert.deepStrictEqual(body.clips[0].notes, twoNotes);
});

// ---------------------------------------------------------------------------
// clip_quantize — default CHANGED to false (closes the inconsistency with
// its shape-identical sibling clip_humanize)
// ---------------------------------------------------------------------------

test("clip_quantize with returnNotes omitted OMITS notes by default (changed behavior, matches clip_humanize)", async () => {
  const clipId = randomUUID();
  queuedResult = { id: clipId, notes: twoNotes };
  const result = (await client.callTool({
    name: "clip_quantize",
    arguments: { clipId, gridBeats: 0.25 },
  })) as any;
  const body = parsed(result) as any;
  assert.equal("notes" in body, false);
  assert.equal(body.notesOmitted, true);
  assert.equal(body.noteCount, 2);
});

test("clip_quantize with returnNotes: true echoes notes back", async () => {
  const clipId = randomUUID();
  queuedResult = { id: clipId, notes: twoNotes };
  const result = (await client.callTool({
    name: "clip_quantize",
    arguments: { clipId, gridBeats: 0.25, returnNotes: true },
  })) as any;
  const body = parsed(result) as any;
  assert.deepStrictEqual(body.notes, twoNotes);
  assert.ok(!("returnNotes" in calls[0]!.params));
});

// ---------------------------------------------------------------------------
// clip_split — default UNCHANGED true (the {first, second} shape); ids of
// BOTH halves must always survive, whichever way `notes` is stripped.
// ---------------------------------------------------------------------------

const oneNote = [{ id: randomUUID(), pitch: 62, velocity: 90, startBeat: 0, lengthBeats: 0.5 }];

test("clip_split with returnNotes omitted echoes both halves' notes back (default unchanged)", async () => {
  const trackId = randomUUID();
  const clipId = randomUUID();
  const firstId = clipId; // left half keeps the original id
  const secondId = randomUUID();
  queuedResult = {
    first: { id: firstId, trackId, notes: oneNote },
    second: { id: secondId, trackId, notes: twoNotes },
  };
  const result = (await client.callTool({
    name: "clip_split",
    arguments: { trackId, clipId, atBeat: 2 },
  })) as any;
  const body = parsed(result) as any;
  assert.deepStrictEqual(body.first.notes, oneNote);
  assert.deepStrictEqual(body.second.notes, twoNotes);
  assert.equal("notesOmitted" in body.first, false);
  assert.equal("notesOmitted" in body.second, false);
});

test("clip_split with returnNotes: false strips notes from BOTH halves but every id and other field survives", async () => {
  const trackId = randomUUID();
  const clipId = randomUUID();
  const firstId = clipId;
  const secondId = randomUUID();
  queuedResult = {
    first: { id: firstId, trackId, startBeat: 0, lengthBeats: 2, notes: oneNote },
    second: { id: secondId, trackId, startBeat: 2, lengthBeats: 4, notes: twoNotes },
  };
  const result = (await client.callTool({
    name: "clip_split",
    arguments: { trackId, clipId, atBeat: 2, returnNotes: false },
  })) as any;
  const body = parsed(result) as any;

  // The ids are the whole point of a split response — they must ALWAYS
  // survive, regardless of whether notes are stripped.
  assert.equal(body.first.id, firstId);
  assert.equal(body.second.id, secondId);
  assert.equal(body.first.trackId, trackId);
  assert.equal(body.second.trackId, trackId);
  assert.equal(body.first.startBeat, 0);
  assert.equal(body.second.startBeat, 2);

  // notes stripped independently on each half, with an accurate per-half count.
  assert.equal("notes" in body.first, false);
  assert.equal("notes" in body.second, false);
  assert.equal(body.first.notesOmitted, true);
  assert.equal(body.first.noteCount, 1);
  assert.equal(body.second.notesOmitted, true);
  assert.equal(body.second.noteCount, 2);

  assert.ok(!("returnNotes" in calls[0]!.params));
});

test("clip_split on an audio clip split (no notes on either half) is unaffected by the strip", async () => {
  const trackId = randomUUID();
  const clipId = randomUUID();
  queuedResult = {
    first: { id: clipId, trackId, sourceOffsetSeconds: 0 },
    second: { id: randomUUID(), trackId, sourceOffsetSeconds: 4.2 },
  };
  const result = (await client.callTool({
    name: "clip_split",
    arguments: { trackId, clipId, atBeat: 2 },
  })) as any;
  const body = parsed(result) as any;
  assert.equal("notesOmitted" in body.first, false);
  assert.equal("notesOmitted" in body.second, false);
  assert.equal(body.second.sourceOffsetSeconds, 4.2);
});

// ---------------------------------------------------------------------------
// Boundary: returnNotes never leaks to the bridge on any of the audited tools
// ---------------------------------------------------------------------------

test("returnNotes never leaks to the bridge on any audited tool", async () => {
  const clipId = randomUUID();
  const trackId = randomUUID();
  const ids = [randomUUID()];
  queuedResult = {
    id: clipId,
    notes: [],
    clips: [{ id: ids[0], notes: [] }],
    first: { id: clipId, notes: [] },
    second: { id: randomUUID(), notes: [] },
  };

  await client.callTool({ name: "clip_duplicate", arguments: { clipId, returnNotes: false } });
  await client.callTool({ name: "clip_remove_many", arguments: { ids, returnNotes: false } });
  await client.callTool({ name: "clip_humanize", arguments: { clipId, returnNotes: false } });
  await client.callTool({ name: "clip_set_notes", arguments: { clipId, notes: [], returnNotes: false } });
  await client.callTool({ name: "clip_move_many", arguments: { ids, byBeats: 1, returnNotes: false } });
  await client.callTool({ name: "clip_quantize", arguments: { clipId, gridBeats: 0.25, returnNotes: false } });
  await client.callTool({ name: "clip_split", arguments: { trackId, clipId, atBeat: 2, returnNotes: false } });

  assert.equal(calls.length, 7);
  for (const call of calls) {
    assert.ok(!("returnNotes" in call.params), `${call.command} leaked returnNotes to the bridge`);
  }
});
