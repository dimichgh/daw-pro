/**
 * vc-convert-clips.test.ts — round-trip coverage for vc_convert_clips
 * (m24-m leg A), the SELECTION-driven per-clip voice conversion.
 *
 * Same stub-bridge pattern as vc-convert.test.ts: `DawBridge.prototype.send`
 * is monkeypatched before any tool call, so the REAL `McpServer` from
 * `src/server.ts` runs over an in-memory transport with no live app. Asserts:
 *   - the tool forwards `vc.convertClips` with the whole selection, omitted
 *     optionals passing through as `undefined` (dropped by JSON.stringify at
 *     the real wire boundary) rather than stray literals
 *   - a stubbed multi-clip result round-trips back unchanged
 *   - an EMPTY clipIds is rejected at the zod boundary and never reaches the
 *     bridge (the wire refuses it too — belt and braces, and the schema
 *     refusal is the one an agent sees first)
 *   - the m16-e strict-schema convention and the pitchSemitones range bound
 *   - the app's overlap refusal surfaces verbatim as an MCP tool error
 *   - THE m24-o PIN, and it is a NEGATIVE assertion: neither this tool's
 *     description nor `vc_convert_vocals`' may still promise the clip's FULL
 *     BACKING RECORDING. That claim was true and is now false; a description
 *     is the agent's only manual, so a stale one is a live defect.
 */

import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";

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
  client = new Client({ name: "vc-convert-clips-test-client", version: "0.0.0" });
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

const CLIP_A = "11111111-1111-1111-1111-111111111111";
const CLIP_B = "22222222-2222-2222-2222-222222222222";

// ---------------------------------------------------------------------------
// Forwarding + round-trip
// ---------------------------------------------------------------------------

test("vc_convert_clips forwards the whole selection and round-trips the per-clip result", async () => {
  const stubbedResult = {
    trackId: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    trackName: "Voice: ada",
    warnings: [],
    clips: [
      {
        sourceClipId: CLIP_A,
        sourceTrackId: "tttttttt-tttt-tttt-tttt-tttttttttttt",
        clipId: "cccccccc-cccc-cccc-cccc-cccccccccccc",
        startBeat: 0,
        lengthBeats: 4,
        extractedPath: "/tmp/DAWPro/voice-source-abcd1234.wav",
        file: "/tmp/media/gen-voice-1.wav",
        sourceSeconds: 2,
        convertedSeconds: 2,
        realConversion: false,
        inputSeconds: 2,
        inferSeconds: 0.05,
        rtf: 40,
        sampleRate: 40000,
        note: "base is the untrained generic target",
      },
      {
        sourceClipId: CLIP_B,
        sourceTrackId: "tttttttt-tttt-tttt-tttt-tttttttttttt",
        clipId: "dddddddd-dddd-dddd-dddd-dddddddddddd",
        startBeat: 8,
        lengthBeats: 4,
        extractedPath: "/tmp/DAWPro/voice-source-ef567890.wav",
        file: "/tmp/media/gen-voice-2.wav",
        sourceSeconds: 2,
        convertedSeconds: 2,
        realConversion: false,
        inputSeconds: 2,
        inferSeconds: 0.05,
        sampleRate: 40000,
      },
    ],
  };
  queuedResult = stubbedResult;

  const result = await client.callTool({
    name: "vc_convert_clips",
    arguments: {
      clipIds: [CLIP_A, CLIP_B],
      voiceId: "ada",
      pitchSemitones: -3,
      trackName: "Voice: ada",
    },
  });

  assert.equal(calls.length, 1, "exactly one bridge call for the whole set");
  assert.equal(calls[0]!.command, "vc.convertClips");
  assert.deepEqual(calls[0]!.params, {
    clipIds: [CLIP_A, CLIP_B],
    voiceId: "ada",
    pitchSemitones: -3,
    trackName: "Voice: ada",
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbedResult, "the app's response round-trips verbatim");
});

test("vc_convert_clips: omitted optionals arrive as undefined, not stray literals", async () => {
  queuedResult = { trackId: "t", trackName: "Voice: base", warnings: [], clips: [] };

  await client.callTool({
    name: "vc_convert_clips",
    arguments: { clipIds: [CLIP_A], voiceId: "base" },
  });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, {
    clipIds: [CLIP_A],
    voiceId: "base",
    pitchSemitones: undefined,
    trackName: undefined,
  });
});

// ---------------------------------------------------------------------------
// Schema refusals — none of these may reach the bridge
// ---------------------------------------------------------------------------

test("vc_convert_clips: an EMPTY clipIds is rejected at the schema boundary", async () => {
  const result = await client.callTool({
    name: "vc_convert_clips",
    arguments: { clipIds: [], voiceId: "base" },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError, "an empty selection is an error, not an empty success");
  assert.equal(calls.length, 0, "never reaches the bridge");
});

test("vc_convert_clips: a missing clipIds is rejected at the schema boundary", async () => {
  const result = await client.callTool({
    name: "vc_convert_clips",
    arguments: { voiceId: "base" },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError);
  assert.equal(calls.length, 0);
});

test("vc_convert_clips: an unrecognized argument is rejected before the bridge (m16-e strict)", async () => {
  const result = await client.callTool({
    name: "vc_convert_clips",
    // `atBeat` belongs to vc_convert_vocals; this tool places every clip at
    // its own source beat, so accepting it silently would be a lie.
    arguments: { clipIds: [CLIP_A], voiceId: "base", atBeat: 8 },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError);
  assert.equal(calls.length, 0);
});

test("vc_convert_clips: pitchSemitones outside -24..24 is rejected at the schema boundary", async () => {
  for (const bad of [25, -25, 1.5]) {
    const result = await client.callTool({
      name: "vc_convert_clips",
      arguments: { clipIds: [CLIP_A], voiceId: "base", pitchSemitones: bad },
    });
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    assert.ok((result as any).isError, `pitchSemitones ${bad} must be refused`);
  }
  assert.equal(calls.length, 0);
});

// ---------------------------------------------------------------------------
// App-side refusals surface verbatim
// ---------------------------------------------------------------------------

test("vc_convert_clips: the app's overlap refusal surfaces verbatim", async () => {
  queuedError = new Error(
    '"lead" (beats 0.0–8.0) and "double" (beats 4.0–12.0) overlap, so one track cannot hold ' +
      "both at their own beats — convert them in two passes (each conversion makes its own " +
      "track), or trim the overlap first"
  );

  const result = await client.callTool({
    name: "vc_convert_clips",
    arguments: { clipIds: [CLIP_A, CLIP_B], voiceId: "base" },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  const text = r.content[0].text as string;
  assert.match(text, /overlap/);
  assert.match(text, /two passes/);
});

// ---------------------------------------------------------------------------
// The descriptions are the agent's only manual — pin what they must teach.
// ---------------------------------------------------------------------------

test("vc_convert_clips' description teaches per-clip, same beats, one new track, one undo", async () => {
  const listed = await client.listTools();
  const tool = listed.tools.find((t) => t.name === "vc_convert_clips");
  assert.ok(tool, "vc_convert_clips is registered");
  const description = tool!.description ?? "";
  assert.match(description, /SEPARATELY/, "teaches that each clip converts on its own");
  assert.match(description, /SAME beats/, "teaches that the arrangement is preserved");
  assert.match(description, /ONE new AI-flagged audio track/, "teaches the one-new-track rule");
  assert.match(description, /edit_undo/, "teaches that one undo removes the whole set");
  assert.match(description, /ALL-OR-NOTHING/, "teaches that a partial failure lands nothing");
  assert.match(description, /overlap/, "teaches the overlap refusal");
  assert.match(
    description,
    /RIGHTS-RESPONSIBILITY POLICY/,
    "carries the rights-responsibility policy like every other vc_* tool"
  );
  assert.doesNotMatch(
    description,
    /own voice only|only the user's own voice/i,
    "the withdrawn own-voice-only prohibition must not reappear"
  );
});

test("m24-o: no vc_* description still promises the clip's FULL backing recording", async () => {
  const listed = await client.listTools();
  const offenders: string[] = [];
  for (const tool of listed.tools) {
    if (!tool.name.startsWith("vc_")) continue;
    const blob = `${tool.description ?? ""} ${JSON.stringify(tool.inputSchema ?? {})}`;
    if (/FULL backing recording/i.test(blob)) offenders.push(tool.name);
  }
  assert.deepEqual(
    offenders,
    [],
    "conversion feeds the converter the clip's OWN window since m24-o; a description that " +
      "still says 'FULL backing recording' documents a defect that was fixed"
  );
});

test("vc_convert_vocals still exists, unrenamed, and now points at its multi-clip sibling", async () => {
  const listed = await client.listTools();
  const tool = listed.tools.find((t) => t.name === "vc_convert_vocals");
  assert.ok(tool, "the single-clip verb is untouched — additive only");
  assert.match(tool!.description ?? "", /vc_convert_clips/, "and points at the set form");
});
