/**
 * speech-model-install.test.ts — wiring coverage for `ai_install_speech_model` /
 * `ai_speech_model_install_status` (m23-n3b: start-then-poll pair exposing the
 * m23-n3a WhisperKit model installer via the new `WhisperModelInstallCoordinator`).
 *
 * The clip-transcribe.test.ts pattern verbatim: monkeypatch
 * `DawBridge.prototype.send` before importing the real `McpServer`, drive both
 * tools over an in-memory transport, and assert:
 *   - ai_install_speech_model forwards exactly `ai.installSpeechModel {variant, overwrite}`
 *   - an omitted `overwrite` reaches the bridge as `undefined`, not a stray key
 *   - the app's response round-trips verbatim for BOTH tools
 *   - the strict wrapper rejects unknown arguments at the MCP boundary (never reaching the bridge)
 *   - a missing `variant` is rejected at the schema layer (never reaching the bridge)
 *   - ai_speech_model_install_status takes NO params and forwards with none
 *   - app-side teaching errors (already installing, unrecognised variant) surface verbatim
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
  client = new Client({ name: "speech-model-install-test-client", version: "0.0.0" });
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

// ---------------------------------------------------------------------------
// ai_install_speech_model
// ---------------------------------------------------------------------------

test("ai_install_speech_model forwards {variant, overwrite} to ai.installSpeechModel and returns the status verbatim", async () => {
  const stubbed = {
    state: "installing",
    variantDirectoryNameRequested: "tiny.en",
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "ai_install_speech_model",
    arguments: { variant: "tiny.en", overwrite: true },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "ai.installSpeechModel");
  assert.deepEqual(calls[0]!.params, { variant: "tiny.en", overwrite: true });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbed, "the app's status round-trips verbatim");
});

test("ai_install_speech_model: omitted overwrite reaches the bridge as undefined, not a stray key", async () => {
  queuedResult = { state: "installing", variantDirectoryNameRequested: "base" };

  await client.callTool({ name: "ai_install_speech_model", arguments: { variant: "base" } });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "ai.installSpeechModel");
  assert.equal(calls[0]!.params["variant"], "base");
  assert.equal(calls[0]!.params["overwrite"], undefined);
});

test("ai_install_speech_model requires variant (rejected at the schema layer, zero bridge calls)", async () => {
  const result = await client.callTool({ name: "ai_install_speech_model", arguments: {} });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError, "a missing required variant must be rejected");
  assert.equal(calls.length, 0);
});

test("ai_install_speech_model rejects an unrecognized argument at the MCP boundary (never reaches the bridge)", async () => {
  const result = await client.callTool({
    name: "ai_install_speech_model",
    arguments: { variant: "tiny.en", token: "secret" },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError, "the strict wrapper must reject unknown keys");
  assert.equal(calls.length, 0, "a rejected call never reaches the bridge");
});

test("ai_install_speech_model surfaces the already-installing teaching error verbatim", async () => {
  queuedError = new Error(
    'Already installing "openai_whisper-large-v3-v20240930_turbo" — poll ai.speechModelInstallStatus and ' +
      'wait for it to reach a terminal state (succeeded or failed) before starting "tiny.en". Only one ' +
      "speech-model install runs at a time."
  );

  const result = await client.callTool({
    name: "ai_install_speech_model",
    arguments: { variant: "tiny.en" },
  });

  assert.equal(calls.length, 1);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "the refusal must be a tool error, never a silent success");
  assert.match(r.content[0].text as string, /Already installing/, "the app's teaching message passes through verbatim");
  assert.match(r.content[0].text as string, /"tiny\.en"/);
});

// ---------------------------------------------------------------------------
// ai_speech_model_install_status
// ---------------------------------------------------------------------------

test("ai_speech_model_install_status takes no params and forwards to ai.speechModelInstallStatus with no arguments", async () => {
  const stubbed = { state: "idle" };
  queuedResult = stubbed;

  const result = await client.callTool({ name: "ai_speech_model_install_status", arguments: {} });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "ai.speechModelInstallStatus");
  assert.deepEqual(calls[0]!.params, {});
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbed);
});

test("ai_speech_model_install_status round-trips a mid-install progress snapshot verbatim", async () => {
  const stubbed = {
    state: "installing",
    variantDirectoryNameRequested: "openai_whisper-tiny.en",
    progress: {
      phase: "downloadingModel",
      variantDirectoryName: "openai_whisper-tiny.en",
      phaseFraction: 0.42,
      completedUnitCount: 42,
      totalUnitCount: 100,
    },
  };
  queuedResult = stubbed;

  const result = await client.callTool({ name: "ai_speech_model_install_status", arguments: {} });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbed);
});

test("ai_speech_model_install_status rejects an unrecognized argument at the MCP boundary (never reaches the bridge)", async () => {
  const result = await client.callTool({
    name: "ai_speech_model_install_status",
    arguments: { variant: "tiny.en" },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError, "the strict empty-schema wrapper must reject any key");
  assert.equal(calls.length, 0, "a rejected call never reaches the bridge");
});

test("ai_speech_model_install_status surfaces a bridge-side error as an MCP tool error, message verbatim", async () => {
  queuedError = new Error("app not running — start DAW Pro or run `swift run DAWApp`");

  const result = await client.callTool({ name: "ai_speech_model_install_status", arguments: {} });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /app not running/);
});
