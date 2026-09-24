/**
 * view-surface.test.ts — round-trip coverage for the M35 `view.*` tools
 * (`view_capture`, `view_select_clip`, `view_panel_layout`, `view_open_editor`)
 * plus the pitch-editor command-surface door's `view_open_pitch_editor`
 * (`docs/design/2026-09-22-pitch-editor-ui.md` §9 — `view_select_clip`'s
 * sibling for the second bottom pane).
 *
 * Same stub-bridge pattern as `vc.test.ts` (itself following
 * `connection-info.test.ts` / `clip-time-range.test.ts`): the REAL `McpServer`
 * from `src/server.ts` is driven over an in-memory transport with
 * `DawBridge.prototype.send` monkeypatched, so no live app is required.
 *
 * What it pins, and why each one:
 *   - each tool forwards to its EXACT wire command with the exact param names
 *     (a verified NAME is not a verified SIGNATURE — this suite is the
 *     signature half);
 *   - the strict schema rejects an unrecognized argument at the MCP boundary,
 *     so it never reaches the bridge;
 *   - `view_panel_layout` accepts ONLY `workspace` and `editorMaximized` — the
 *     two named exceptions M35 carved out of the non-invokable-layout rule —
 *     and refuses every debug-tier layout key, which is what makes that rule a
 *     fence rather than a sentence in a document;
 *   - the app's headless refusal surfaces as an MCP tool ERROR carrying the
 *     app's own message, never a silent empty success. That contract is the
 *     entire reason `view.capture` has no ImageRenderer fallback, so it is
 *     asserted here at the boundary an agent actually calls.
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
  client = new Client({ name: "view-surface-test-client", version: "0.0.0" });
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

const CLIP_ID = "3f1a5e2c-7b6d-4a90-9c31-2f8e4d5b6a70";
const TRACK_ID = "8c2b7d41-59ae-4f03-b6d2-1e7c9a3f5b04";
const EFFECT_ID = "b41d6e08-2c5f-4a17-93be-6d0f8a2c1e35";

// ---------------------------------------------------------------------------
// view_capture
// ---------------------------------------------------------------------------

test("view_capture forwards an explicit path to view.capture", async () => {
  const stubbed = {
    path: "/tmp/shot.png",
    width: 2560,
    height: 1600,
    method: "window",
    rect: { x: 0, y: 0, width: 1280, height: 800 },
    scale: 2,
    appActive: true,
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "view_capture",
    arguments: { path: "/tmp/shot.png" },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "view.capture");
  assert.deepEqual(calls[0]!.params, { path: "/tmp/shot.png" });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.deepEqual(parseJSON(result as any), stubbed);
});

test("view_capture takes no required params — a bare call still reaches the wire", async () => {
  queuedResult = { path: "/tmp/DAWPro/ui-capture-0.png", method: "window" };
  await client.callTool({ name: "view_capture", arguments: {} });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "view.capture");
});

test("view_capture has NO selectClip param — that capability's home is view_select_clip", async () => {
  const result = await client.callTool({
    name: "view_capture",
    arguments: { selectClip: CLIP_ID },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError);
  assert.equal(calls.length, 0, "a rejected key must never reach the bridge");
});

test("view_capture's headless refusal surfaces as a tool ERROR, not a blank success", async () => {
  queuedError = new Error(
    "view.capture needs the app UI — this control session is headless (no window to rasterize). " +
      "Launch DAWApp/DAWPro.app and retry."
  );
  const result = await client.callTool({ name: "view_capture", arguments: {} });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "a headless app must be an error — a blank PNG reported as success is worse");
  assert.match(r.content[0].text as string, /headless/);
  assert.match(r.content[0].text as string, /DAWApp/);
});

// ---------------------------------------------------------------------------
// view_select_clip
// ---------------------------------------------------------------------------

test("view_select_clip forwards clipId and round-trips the honest reason", async () => {
  const stubbed = {
    clipId: CLIP_ID,
    trackId: TRACK_ID,
    clipKind: "audio",
    editorOpen: false,
    reason: "audio-clip-has-no-editor",
    workspace: "arrange",
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "view_select_clip",
    arguments: { clipId: CLIP_ID },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "view.selectClip");
  assert.deepEqual(calls[0]!.params, { clipId: CLIP_ID });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(!r.isError, "selecting an AUDIO clip is a SUCCESS carrying a reason, not an error");
  assert.deepEqual(parseJSON(r), stubbed);
});

test("view_select_clip requires clipId and rejects extras at the MCP boundary", async () => {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let r = (await client.callTool({ name: "view_select_clip", arguments: {} })) as any;
  assert.ok(r.isError);
  r = (await client.callTool({
    name: "view_select_clip",
    arguments: { clipId: CLIP_ID, bogus: true },
  })) as any;
  assert.ok(r.isError);
  assert.equal(calls.length, 0);
});

test("view_select_clip's description teaches all four reason values", async () => {
  const { tools } = await client.listTools();
  const tool = tools.find((t) => t.name === "view_select_clip");
  assert.ok(tool, "view_select_clip is registered");
  for (const reason of [
    "piano-roll-opened",
    "pitch-editor-open",
    "audio-clip-has-no-editor",
    "workspace-is-not-arrange",
  ]) {
    assert.match(
      tool!.description as string,
      new RegExp(reason),
      `the description must teach the ${reason} branch`
    );
  }
});

test("view_select_clip's response shape carries pitchEditorOpen alongside editorOpen", async () => {
  const stubbed = {
    clipId: CLIP_ID,
    trackId: TRACK_ID,
    clipKind: "audio",
    editorOpen: false,
    pitchEditorOpen: true,
    reason: "pitch-editor-open",
    workspace: "arrange",
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "view_select_clip",
    arguments: { clipId: CLIP_ID },
  });

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(!r.isError);
  assert.deepEqual(parseJSON(r), stubbed);
});

// ---------------------------------------------------------------------------
// view_panel_layout — the narrowed-rule fence
// ---------------------------------------------------------------------------

test("view_panel_layout forwards both production-tier keys", async () => {
  queuedResult = { workspace: "mix", editorMaximized: true, editorFraction: 0.35 };
  await client.callTool({
    name: "view_panel_layout",
    arguments: { workspace: "mix", editorMaximized: true },
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "view.panelLayout");
  assert.deepEqual(calls[0]!.params, { workspace: "mix", editorMaximized: true });
});

test("view_panel_layout with no arguments is a READ (the bare-call law)", async () => {
  queuedResult = { workspace: "arrange", editorMaximized: false, editorFraction: 0.35 };
  await client.callTool({ name: "view_panel_layout", arguments: {} });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "view.panelLayout");
});

test("view_panel_layout REFUSES every debug-tier layout key at the MCP boundary", async () => {
  for (const key of [
    "pianoRollRowHeight",
    "sidebarWidth",
    "rowHeight",
    "editorFraction",
    "pianoRollPPB",
    "pianoRollMinimap",
    "pianoRollCenterPitch",
    "mixerInsertsCollapsed",
    "waveformNormalize",
    "waveformVerticalZoom",
    "followPlayhead",
    "auditionEnabled",
    "reset",
  ]) {
    const result = await client.callTool({
      name: "view_panel_layout",
      arguments: { [key]: 24 },
    });
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    assert.ok((result as any).isError, `${key} must be refused — it is debug-tier chrome`);
  }
  assert.equal(calls.length, 0, "no refused key may reach the bridge");
});

test("view_panel_layout's workspace enum rejects anything but arrange|mix", async () => {
  const result = await client.callTool({
    name: "view_panel_layout",
    arguments: { workspace: "sketchpad" },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.ok((result as any).isError);
  assert.equal(calls.length, 0);
});

// ---------------------------------------------------------------------------
// view_open_pitch_editor
// ---------------------------------------------------------------------------

test("view_open_pitch_editor forwards clipId and round-trips the response", async () => {
  const stubbed = {
    clipId: CLIP_ID,
    trackId: TRACK_ID,
    opened: true,
    reason: "pitch-editor-opened",
    workspace: "arrange",
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "view_open_pitch_editor",
    arguments: { clipId: CLIP_ID },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "view.openPitchEditor");
  assert.deepEqual(calls[0]!.params, { clipId: CLIP_ID });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(!r.isError, "opening the pitch editor on an audio clip is a SUCCESS");
  assert.deepEqual(parseJSON(r), stubbed);
});

test("view_open_pitch_editor: opened:false with workspace-is-not-arrange is still a SUCCESS, not an error", async () => {
  const stubbed = {
    clipId: CLIP_ID,
    trackId: TRACK_ID,
    opened: false,
    reason: "workspace-is-not-arrange",
    workspace: "mix",
  };
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "view_open_pitch_editor",
    arguments: { clipId: CLIP_ID },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(!r.isError, "latched-but-not-visible is a success carrying an honest reason, not an error");
  assert.deepEqual(parseJSON(r), stubbed);
});

test("view_open_pitch_editor requires clipId and rejects extras at the MCP boundary", async () => {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let r = (await client.callTool({ name: "view_open_pitch_editor", arguments: {} })) as any;
  assert.ok(r.isError);
  r = (await client.callTool({
    name: "view_open_pitch_editor",
    arguments: { clipId: "not-a-uuid" },
  })) as any;
  assert.ok(r.isError);
  r = (await client.callTool({
    name: "view_open_pitch_editor",
    arguments: { clipId: CLIP_ID, bogus: true },
  })) as any;
  assert.ok(r.isError);
  assert.equal(calls.length, 0);
});

test("view_open_pitch_editor surfaces the app's MIDI-clip refusal as an MCP tool error, message verbatim", async () => {
  queuedError = new Error(
    `clip "Lead Vocal" (${CLIP_ID}) is a MIDI clip — the pitch editor tunes a SUNG OR ` +
      "PLAYED AUDIO recording; a MIDI clip is already notes with a definite pitch. Open " +
      "its piano roll instead with view.selectClip."
  );

  const result = await client.callTool({
    name: "view_open_pitch_editor",
    arguments: { clipId: CLIP_ID },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "view.openPitchEditor");
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError, "a MIDI clip must be a loud error, never a soft reply");
  assert.match(r.content[0].text as string, /is a MIDI clip/);
});

test("view_open_pitch_editor's headless refusal surfaces as a tool ERROR, not a blank success", async () => {
  queuedError = new Error(
    "view.openPitchEditor needs the app UI — this control session is headless (there is " +
      "no pitch editor pane to open). Launch DAWApp/DAWPro.app and retry."
  );
  const result = await client.callTool({
    name: "view_open_pitch_editor",
    arguments: { clipId: CLIP_ID },
  });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = result as any;
  assert.ok(r.isError);
  assert.match(r.content[0].text as string, /headless/);
});

// ---------------------------------------------------------------------------
// view_open_editor
// ---------------------------------------------------------------------------

test("view_open_editor forwards trackId alone for an instrument editor", async () => {
  queuedResult = {
    editor: "poly-synth",
    trackId: TRACK_ID,
    effectId: null,
    title: "Poly Synth on Synth 1",
    alreadyOpen: false,
  };
  const result = await client.callTool({
    name: "view_open_editor",
    arguments: { trackId: TRACK_ID },
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "view.openEditor");
  assert.equal(calls[0]!.params.trackId, TRACK_ID);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  assert.equal(parseJSON(result as any).editor, "poly-synth");
});

test('view_open_editor accepts the "master" sentinel with an effectId', async () => {
  queuedResult = {
    editor: "built-in-effect",
    trackId: null,
    effectId: EFFECT_ID,
    title: "eq on Master",
    alreadyOpen: false,
  };
  await client.callTool({
    name: "view_open_editor",
    arguments: { trackId: "master", effectId: EFFECT_ID },
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.params.trackId, "master");
  assert.equal(calls[0]!.params.effectId, EFFECT_ID);
});

test("view_open_editor requires trackId and rejects extras at the MCP boundary", async () => {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let r = (await client.callTool({ name: "view_open_editor", arguments: {} })) as any;
  assert.ok(r.isError);
  r = (await client.callTool({
    name: "view_open_editor",
    arguments: { trackId: TRACK_ID, bogus: true },
  })) as any;
  assert.ok(r.isError);
  assert.equal(calls.length, 0);
});

test("all five view_* tools are registered with beginner-readable descriptions", async () => {
  const { tools } = await client.listTools();
  const names = tools.map((t) => t.name);
  for (const name of [
    "view_capture",
    "view_select_clip",
    "view_panel_layout",
    "view_open_editor",
    "view_open_pitch_editor",
  ]) {
    assert.ok(names.includes(name), `${name} must be registered`);
    const tool = tools.find((t) => t.name === name)!;
    assert.ok(
      (tool.description as string).length > 200,
      `${name}'s description must teach, not label`
    );
  }
  // Positive control: the reader really can tell a missing tool from a present
  // one — a listTools() that silently returned nothing would pass every
  // includes() above only if this line also passed, and it would not.
  assert.ok(!names.includes("view_definitely_not_a_tool"));
});
