/**
 * embedded-voices.test.ts — wiring coverage for m24-n's two tools:
 * `project_embedded_voices` (what voice models does this project carry, what
 * do they cost, and is each usable here) and `vc_install_embedded_voice`
 * (copy a carried voice into this machine's voice store).
 *
 * The instrument-probe-liveness.test.ts stub-bridge pattern verbatim:
 * monkeypatch `DawBridge.prototype.send` before importing the real
 * `McpServer`, drive the tools over an in-memory transport, and assert
 *
 *   - each forwards to the right command with the right shape, and an omitted
 *     optional forwards as UNDEFINED rather than a fabricated default (a
 *     `false` invented here would silently disagree with the app's own rule)
 *   - `project_embedded_voices` is a pure READ: no params at all
 *   - `vc_install_embedded_voice` rides the STRICT-SCHEMA wrapper — an
 *     unrecognized key is rejected at the boundary, never reaching the bridge
 *   - the app's teaching refusals pass through VERBATIM; those sentences ARE
 *     the deliverable (they name project_embedded_voices as the way forward)
 *   - the descriptions teach the three things an agent must not get wrong:
 *     a missing voice is NOT an error and the audio still plays; `overwrite`
 *     can destroy a newer local voice, so ask first; and the reason a project
 *     is large is the embed, which is deliberate
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
// eslint-disable-next-line @typescript-eslint/no-explicit-any
let tools: any[];

before(async () => {
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  client = new Client({ name: "embedded-voices-test-client", version: "0.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
  tools = (await client.listTools()).tools;
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
  assert.ok(first && first.type === "text");
  return JSON.parse(first.text as string);
}

function reportPayload() {
  return {
    projectPath: "/Users/someone/Music/Ballad.dawproj",
    embeddedBytes: 84_000_000,
    orphanedVoiceIds: ["oldtake"],
    voices: [
      {
        voiceId: "ada",
        voiceName: "Ada (studio take)",
        tracks: ["Voice: ada"],
        embeddedInProject: true,
        embeddedBytes: 84_000_000,
        installedLocally: false,
        note:
          "carried inside this project but not installed on this machine — the converted " +
          "audio plays fine; install it (vc.installEmbeddedVoice) to convert anything new " +
          "with it",
      },
    ],
  };
}

// ---------------------------------------------------------------------------
// Registration + forwarding
// ---------------------------------------------------------------------------

test("both tools are registered exactly once", () => {
  assert.equal(tools.filter((t) => t.name === "project_embedded_voices").length, 1);
  assert.equal(tools.filter((t) => t.name === "vc_install_embedded_voice").length, 1);
});

test("project_embedded_voices forwards to project.embeddedVoices with no params", async () => {
  queuedResult = reportPayload();
  const result = await client.callTool({ name: "project_embedded_voices", arguments: {} });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "project.embeddedVoices");
  assert.deepEqual(calls[0]!.params, {});

  const parsed = parseJSON(result);
  assert.equal(parsed.voices[0].voiceId, "ada");
  assert.equal(parsed.voices[0].installedLocally, false);
  assert.deepEqual(parsed.orphanedVoiceIds, ["oldtake"]);
});

test("vc_install_embedded_voice forwards {voiceId}; an omitted overwrite stays UNDEFINED", async () => {
  queuedResult = {
    voiceId: "ada",
    voiceName: "Ada (studio take)",
    directoryPath: "/Users/someone/Library/Application Support/DAWPro/VoiceModels/ada",
    files: ["model.npz", "model.json", "model.index", "voice.json"],
    byteCount: 84_000_000,
    replacedExisting: false,
  };
  const result = await client.callTool({
    name: "vc_install_embedded_voice",
    arguments: { voiceId: "ada" },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "vc.installEmbeddedVoice");
  assert.equal(calls[0]!.params.voiceId, "ada");
  // NOT `false` — the app owns the default; inventing one here is how the two
  // sides quietly stop agreeing.
  assert.equal(calls[0]!.params.overwrite, undefined);
  assert.ok("overwrite" in calls[0]!.params);

  const parsed = parseJSON(result);
  assert.equal(parsed.replacedExisting, false);
  assert.equal(parsed.files.length, 4);
  // model.pth deliberately never travels — the converter does not read it.
  assert.ok(!parsed.files.includes("model.pth"));
});

test("vc_install_embedded_voice forwards overwrite when it is asked for", async () => {
  queuedResult = { voiceId: "ada", replacedExisting: true };
  await client.callTool({
    name: "vc_install_embedded_voice",
    arguments: { voiceId: "ada", overwrite: true },
  });
  assert.equal(calls[0]!.params.overwrite, true);
});

// ---------------------------------------------------------------------------
// Boundary + error surfacing
// ---------------------------------------------------------------------------

test("vc_install_embedded_voice rejects an unrecognized argument before the bridge", async () => {
  const result = await client.callTool({
    name: "vc_install_embedded_voice",
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    arguments: { voiceId: "ada", force: true } as any,
  });
  assert.equal((result as { isError?: boolean }).isError, true);
  assert.equal(calls.length, 0, "a rejected call must never reach the app");
});

test("vc_install_embedded_voice requires voiceId", async () => {
  const result = await client.callTool({
    name: "vc_install_embedded_voice",
    arguments: {},
  });
  assert.equal((result as { isError?: boolean }).isError, true);
  assert.equal(calls.length, 0);
});

test("the app's teaching refusal reaches the agent verbatim — it names the way forward", async () => {
  queuedError = new Error(
    "voice 'ada' is already in this machine's voice store — pass 'overwrite: true' to " +
      "replace it with this project's embedded copy, or convert with the voice you already have"
  );
  const result = await client.callTool({
    name: "vc_install_embedded_voice",
    arguments: { voiceId: "ada" },
  });
  assert.equal((result as { isError?: boolean }).isError, true);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const text = (result as any).content[0].text as string;
  assert.ok(text.includes("already in this machine's voice store"));
  assert.ok(text.includes("overwrite"));
});

// ---------------------------------------------------------------------------
// The descriptions are the contract an agent reads
// ---------------------------------------------------------------------------

test("project_embedded_voices teaches that a missing voice is NOT an error", () => {
  const tool = tools.find((t) => t.name === "project_embedded_voices");
  const d = tool.description as string;
  assert.ok(d.includes("NOTHING HERE IS AN ERROR"));
  assert.ok(d.includes("still plays"));
  // …and that it explains the size, which is the question it exists to answer.
  assert.ok(d.includes("240 MB"));
  assert.ok(d.includes("orphanedVoiceIds"));
  assert.ok(d.includes("installedLocally"));
  // A pure read: no input schema beyond the empty object.
  assert.deepEqual(Object.keys(tool.inputSchema.properties ?? {}), []);
});

test("vc_install_embedded_voice tells the agent to ASK before overwriting", () => {
  const d = tools.find((t) => t.name === "vc_install_embedded_voice").description as string;
  assert.ok(d.includes("ASK"));
  assert.ok(d.includes("retrained") || d.includes("newer"));
  assert.ok(d.includes("project_embedded_voices"));
  // It is NOT an edit — an agent must not expect to undo it.
  assert.ok(d.includes("NOT a project"));
  assert.ok(d.includes("rights"));
});

test("project_save's description now explains the voice-embed cost fields", () => {
  const d = tools.find((t) => t.name === "project_save").description as string;
  assert.ok(d.includes("voicesEmbedded"));
  assert.ok(d.includes("voiceBytesCopied"));
  assert.ok(d.includes("re-convertible on another machine"));
  // Absent for a project with no converted tracks — so an agent does not read
  // a missing key as an error.
  assert.ok(d.includes("absent entirely"));
});
