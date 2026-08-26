/**
 * edit-paste-clips.test.ts — wiring coverage for edit_paste_clips
 * (m26-k: fire the app's OWN Cmd-V clipboard paste over the wire, routed
 * through the new TYPED `EditPasteControlling` app-layer seam — the
 * `plugin.*` precedent, not `appCommandHandler`).
 *
 * The track-reorder.test.ts pattern verbatim: monkeypatch
 * `DawBridge.prototype.send` before importing the real `McpServer`, drive the
 * tool over an in-memory transport, and assert:
 *   - the tool forwards `edit.pasteClips {trackId}`, with `trackId` reaching
 *     the bridge as `undefined` (not a stray key) when omitted
 *   - each of the four outcome shapes the wire distinguishes round-trips
 *     verbatim (pasted / emptyClipboard / wrongPayloadKind / blocked)
 *   - an unrecognized argument is rejected at the MCP boundary, never
 *     reaches the bridge
 *   - a headless-session refusal (no app UI attached) surfaces verbatim
 *   - the description states plainly that this is the APP'S OWN clipboard
 *     (nothing populates it over the wire) and that `trackId` overrides the
 *     active track for this paste only
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
  client = new Client({ name: "edit-paste-clips-test-client", version: "0.0.0" });
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

test("omitted trackId reaches the bridge as undefined, not a stray key", async () => {
  queuedResult = { pasted: false, reason: "empty-clipboard" };

  await client.callTool({ name: "edit_paste_clips", arguments: {} });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "edit.pasteClips");
  // m25-f-4 added `atBeat` ADDITIVELY: an omitted optional forwards as
  // `undefined` (JSON.stringify drops it on the wire), exactly as `trackId`
  // always has.
  assert.deepEqual(calls[0]!.params, { trackId: undefined, atBeat: undefined });
});

test("a given trackId forwards verbatim", async () => {
  const trackId = randomUUID();
  queuedResult = { pasted: false, reason: "empty-clipboard" };

  await client.callTool({ name: "edit_paste_clips", arguments: { trackId } });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, { trackId, atBeat: undefined });
});

test("an atBeat forwards verbatim, alongside the trackId (m25-f-4)", async () => {
  const trackId = randomUUID();
  queuedResult = { pasted: false, reason: "empty-clipboard" };

  await client.callTool({ name: "edit_paste_clips", arguments: { trackId, atBeat: 37.5 } });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, { trackId, atBeat: 37.5 });
});

test("a NEGATIVE atBeat is forwarded, not rejected — the app's group clamp owns it", async () => {
  queuedResult = { pasted: false, reason: "empty-clipboard" };

  await client.callTool({ name: "edit_paste_clips", arguments: { atBeat: -5 } });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, { trackId: undefined, atBeat: -5 });
});

test("a non-numeric atBeat is rejected at the MCP boundary, never reaches the bridge", async () => {
  const result = await client.callTool({
    name: "edit_paste_clips",
    arguments: { atBeat: "bar 3" },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError);
  assert.equal(calls.length, 0);
});

test("a non-UUID trackId is rejected at the MCP boundary, never reaches the bridge", async () => {
  const result = await client.callTool({
    name: "edit_paste_clips",
    arguments: { trackId: "not-a-uuid" },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError);
  assert.equal(calls.length, 0);
});

// ⚠️ THIS TEST USED `atBeat: 4` AS ITS UNKNOWN KEY UNTIL m25-f-4 MADE `atBeat`
// REAL. The key had to be replaced, not the assertion: the strict-schema
// property being pinned is that an argument this tool does not declare is
// refused at the boundary, and a key the tool now DECLARES cannot demonstrate
// it. (It went red exactly as it should have when the param landed.)
test("an unrecognized argument is rejected at the MCP boundary (never reaches the bridge)", async () => {
  const result = await client.callTool({
    name: "edit_paste_clips",
    arguments: { trackId: randomUUID(), atBar: 4 },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError);
  assert.equal(calls.length, 0);
});

test("outcome 1/4 — pasted: landings/skipped/trimmedClipIDs/removedClipIDs round-trip verbatim", async () => {
  const stubbed = {
    pasted: true,
    landings: [{ clipId: randomUUID(), trackId: randomUUID(), startBeat: 8 }],
    skipped: [{ sourceClipId: randomUUID(), clipName: "Vox Take 2", reason: "overlaps-pasted-sibling" }],
    trimmedClipIDs: [randomUUID()],
    removedClipIDs: [],
  };
  queuedResult = stubbed;

  const result = await client.callTool({ name: "edit_paste_clips", arguments: {} });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbed);
});

test("outcome 2/4 — emptyClipboard round-trips verbatim", async () => {
  queuedResult = { pasted: false, reason: "empty-clipboard" };

  const result = await client.callTool({ name: "edit_paste_clips", arguments: {} });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), { pasted: false, reason: "empty-clipboard" });
});

test("outcome 3/4 — wrongPayloadKind (notes, not clips) round-trips verbatim", async () => {
  queuedResult = { pasted: false, reason: "wrong-payload-kind", clipboardKind: "notes" };

  const result = await client.callTool({ name: "edit_paste_clips", arguments: {} });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), {
    pasted: false,
    reason: "wrong-payload-kind",
    clipboardKind: "notes",
  });
});

test("outcome 4/4 — blocked (destination refusal) round-trips verbatim, skipped may be non-empty", async () => {
  const stubbed = {
    pasted: false,
    reason: "track-kind-mismatch",
    skipped: [{ sourceClipId: randomUUID(), clipName: "Drums 1", reason: "track-kind-mismatch" }],
  };
  queuedResult = stubbed;

  const result = await client.callTool({ name: "edit_paste_clips", arguments: {} });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbed);
});

test("a headless-session refusal (no app UI attached) surfaces as an MCP tool error, verbatim", async () => {
  queuedError = new Error(
    "edit paste unavailable — this control session has no app UI (headless). Launch DAWApp/DAWPro.app and retry."
  );

  const result = await client.callTool({ name: "edit_paste_clips", arguments: {} });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "a headless refusal is a tool error");
  assert.match(r.content[0].text as string, /no app UI \(headless\)/);
});

test("the description names the clipboard as the APP'S OWN and states trackId overrides the active track for this paste only", async () => {
  const listed = await client.listTools();
  const tool = listed.tools.find((t) => t.name === "edit_paste_clips");
  assert.ok(tool, "edit_paste_clips is listed");
  const description = tool!.description ?? "";
  assert.match(description, /APP'S OWN clipboard/);
  assert.match(description, /cannot PUT anything on that clipboard/);
  assert.match(description, /overrides the destination for\s+THIS paste only/);
  // Teaches the note-vs-clip fork toward the actual note-paste path.
  assert.match(description, /clip_get_notes/);
  assert.match(description, /clip_set_notes/);
});
