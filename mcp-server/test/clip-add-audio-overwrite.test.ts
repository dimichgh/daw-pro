/**
 * clip-add-audio-overwrite.test.ts — wiring coverage for m33-j: `clip_add_audio`
 * no longer silently deletes the clip it lands on.
 *
 * ⛔ THE DEFECT THIS FILE GUARDS. Measured 2026-08-29 through the live router:
 * two `clip_add_audio` calls at `atBeat: 0` on one audio track left ONE clip,
 * the first id dead, and BOTH calls returned a normal success with an id. The
 * app now REFUSES that placement (naming the resident) unless the caller passes
 * `overwrite: true`, and reports `trimmedClipIDs`/`removedClipIDs` either way.
 * The refusal itself is enforced app-side and pinned in
 * `Tests/DAWControlTests/ClipAddAudioOverlapCommandTests.swift`; what this file
 * pins is that the MCP surface can EXPRESS and TRANSPORT that policy — the new
 * param reaches the wire, the receipt round-trips, the refusal is a tool error
 * with the app's wording intact, and the description tells an agent the rule
 * (an agent reads only the description).
 *
 * The clip-fit-to-content.test.ts pattern verbatim.
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
  client = new Client({ name: "clip-add-audio-overwrite-test-client", version: "0.0.0" });
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

test("clip_add_audio forwards overwrite:true to clip.addAudio and round-trips the receipt", async () => {
  const trackId = randomUUID();
  const clipId = randomUUID();
  const removedId = randomUUID();
  const stubbed = {
    id: clipId,
    name: "flip-pass-2",
    startBeat: 0,
    lengthBeats: 8,
    audioFileURL: "file:///tmp/flip-pass-2.wav",
    isAIGenerated: false,
    trimmedClipIDs: [],
    removedClipIDs: [removedId],
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "clip_add_audio",
    arguments: { trackId, path: "/tmp/flip-pass-2.wav", atBeat: 0, overwrite: true },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "clip.addAudio");
  assert.deepEqual(calls[0]!.params, {
    trackId,
    path: "/tmp/flip-pass-2.wav",
    atBeat: 0,
    overwrite: true,
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const parsed = parseJSON(result as any);
  assert.deepEqual(parsed.removedClipIDs, [removedId], "the receipt must survive the trip");
  assert.deepEqual(parsed.trimmedClipIDs, []);
});

test("omitting overwrite leaves it unset on the wire — the app supplies the refusing default", async () => {
  const trackId = randomUUID();
  queuedResult = { id: randomUUID(), name: "x", startBeat: 0, lengthBeats: 4, trimmedClipIDs: [], removedClipIDs: [] };

  await client.callTool({
    name: "clip_add_audio",
    arguments: { trackId, path: "/tmp/x.wav" },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.params.overwrite, undefined, "no invented default — refusing is the APP's default");
  assert.equal(calls[0]!.params.atBeat, undefined);
});

test("the overlap refusal surfaces as a tool error with the app's wording verbatim", async () => {
  const residentId = randomUUID();
  queuedError = new Error(
    `clip 'flip-pass' (${residentId}) is already on that track where this import would land ` +
      "— importing here would trim or delete it, so clip.addAudio refuses rather than silently " +
      "overwriting your clip (an import's length comes from the file, so 'atBeat' alone could not " +
      "tell you what it would cover). Omit 'atBeat' to append after everything already on the track " +
      "(beat 16), choose a free beat, import onto another track, or pass 'overwrite: true' to accept " +
      "the trim and read back trimmedClipIDs/removedClipIDs"
  );

  const result = await client.callTool({
    name: "clip_add_audio",
    arguments: { trackId: randomUUID(), path: "/tmp/flip-pass.wav", atBeat: 0 },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "a refusal must be a tool error, never a quiet success");
  const text = r.content[0].text as string;
  assert.ok(text.includes(residentId), "the agent must learn WHICH clip is in the way");
  assert.match(text, /beat 16/, "and the beat it can safely append at");
  assert.match(text, /overwrite: true/, "and the opt-in, if it really meant to replace");
});

test("a typo'd argument is still rejected at the MCP boundary — 'overwrite' widened the schema by one", async () => {
  const result = await client.callTool({
    name: "clip_add_audio",
    arguments: { trackId: randomUUID(), path: "/tmp/x.wav", overwite: true },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError, "the strict wrapper must reject unknown keys");
  assert.equal(calls.length, 0, "a rejected call never reaches the bridge");
});

test("the description states the refuse-by-default rule and names the resample loop", async () => {
  const { tools } = await client.listTools();
  const tool = tools.find((t) => t.name === "clip_add_audio");
  assert.ok(tool, "clip_add_audio must still be registered");
  const description = tool!.description ?? "";
  // An agent reads the description, not this repo. If the rule is not here, the
  // rule does not reach the agent — the same reason the sample-flip skill had
  // to carry the defect warning while the defect was live.
  assert.match(description, /REFUSED/, "refuse-by-default must be stated, not implied");
  assert.match(description, /resample loop/, "the workflow it protects must be named");
  assert.match(description, /OMIT atBeat/, "the escape must be spelled out");
  const overwrite = (tool!.inputSchema as { properties?: Record<string, { description?: string }> })
    .properties?.overwrite;
  assert.ok(overwrite, "the overwrite param must be advertised in the schema");
  assert.match(overwrite!.description ?? "", /Default false/);
});
