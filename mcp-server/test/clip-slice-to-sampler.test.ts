/**
 * clip-slice-to-sampler.test.ts — wiring coverage for clip_slice_to_sampler
 * (m32-b2, THE SAMPLE FLIP: chop an audio clip into sampler pads plus a MIDI
 * clip that replays the original groove).
 *
 * The clip-detect-pitch.test.ts stub-bridge pattern verbatim: monkeypatch
 * `DawBridge.prototype.send` before importing the real `McpServer`, drive the
 * tool over an in-memory transport, and assert:
 *   - every parameter forwards to clip.sliceToSampler verbatim, and an
 *     OMITTED optional forwards as undefined rather than a fabricated default
 *     (the app owns every default; a default duplicated here is a default that
 *     will drift)
 *   - the app's response — including the honestly-ABSENT `endFrame` on a pad
 *     that reaches the file end, and the absent `strength`/`snapOffsetFrames`
 *     on a head pad — round-trips verbatim
 *   - clipId is required and must be a UUID (schema layer, zero bridge calls)
 *   - registered via the STRICT-SCHEMA wrapper, so an unrecognized argument
 *     IS rejected before the bridge
 *   - the range/enum guards fire at the schema layer
 *   - an app-side refusal (too many pads) surfaces as an MCP tool error,
 *     message verbatim — the REJECT-never-truncate contract crossing the
 *     boundary intact
 *   - ⭐ the DESCRIPTION names the chop use case, the velocity-127 ruling and
 *     the reject-never-truncate rule. A tool an agent cannot find is a tool
 *     that does not exist, and this one's whole value is being reached for by
 *     name when someone says "flip this record".
 */

import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

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
  client = new Client({ name: "clip-slice-to-sampler-test-client", version: "0.0.0" });
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

/**
 * A stub carrying BOTH shapes of honest absence — a HEAD pad with no
 * `strength`/`snapOffsetFrames`/`residualAmplitude` (no detector produced it,
 * and its start was never snapped) and a LAST pad with no `endFrame` (it
 * reaches the file's end). A stub where every field were present would let the
 * omission assertions pass trivially.
 */
function makeStubbedChop() {
  return {
    trackId: "6D6E6C41-0000-4000-8000-000000000001",
    createdTrackId: "6D6E6C41-0000-4000-8000-000000000001",
    midiClipId: "6D6E6C41-0000-4000-8000-000000000002",
    sampleRate: 48000,
    frameCount: 96000,
    sliceCount: 3,
    headSeconds: 0.5,
    slices: [
      { index: 0, pitch: 36, startFrame: 0, endFrame: 24000, sourceSeconds: 0, beat: 0 },
      {
        index: 1,
        pitch: 37,
        startFrame: 24000,
        endFrame: 48000,
        sourceSeconds: 0.5,
        beat: 1,
        strength: 0.82,
        snapOffsetFrames: -14,
        residualAmplitude: 0.0007,
      },
      {
        index: 2,
        pitch: 38,
        startFrame: 48000,
        sourceSeconds: 1,
        beat: 2,
        strength: 0.61,
        snapOffsetFrames: 3,
        residualAmplitude: 0.31,
      },
    ],
    warnings: [],
  };
}

test("clip_slice_to_sampler forwards {clipId} (bare) and omits every unset optional", async () => {
  const clipId = randomUUID();
  const stubbed = makeStubbedChop();
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "clip_slice_to_sampler",
    arguments: { clipId },
  });

  assert.equal(calls.length, 1, "exactly one bridge call");
  assert.equal(calls[0]!.command, "clip.sliceToSampler");
  assert.equal(calls[0]!.params["clipId"], clipId);
  for (const key of [
    "targetTrackId",
    "mode",
    "sensitivity",
    "divisions",
    "gridBeats",
    "minSliceSeconds",
    "maxSlices",
    "includeHead",
    "baseNote",
    "snapWindowMs",
    "generateMIDI",
    "atBeat",
    "velocityFromStrength",
    // m39-pads. ⚠️ ESPECIALLY THIS ONE: a default duplicated here would mean a
    // bare call started muting a track the caller never named, which is the
    // exact behaviour change the app-side FALSE default exists to prevent.
    "muteSourceTrack",
    // m39-w4-7: "kit" is opt-in; a bare call must stay the chromatic chop.
    "mapping",
    "roles",
  ]) {
    assert.equal(
      calls[0]!.params[key],
      undefined,
      `${key} must forward as undefined, never a default duplicated here`
    );
  }

  const parsed = parseJSON(result as any);
  // The two honest-absence contracts, checked explicitly before the deepEqual
  // (which could pass even if BOTH sides encoded a wrong sentinel identically).
  const head = parsed.slices[0];
  assert.ok(!("strength" in head), "the head pad must OMIT strength — no detector produced it");
  assert.ok(!("snapOffsetFrames" in head), "the head pad's start was never snapped");
  assert.ok(!("residualAmplitude" in head));
  const last = parsed.slices[2];
  assert.ok(
    !("endFrame" in last),
    "a pad reaching the file end must OMIT endFrame, not report a rounded frame count"
  );
  assert.equal(last.residualAmplitude, 0.31, "an honest stereo residual survives the boundary");

  assert.deepEqual(parsed, stubbed, "the app's response round-trips verbatim");
});

test("clip_slice_to_sampler forwards every parameter explicitly", async () => {
  const clipId = randomUUID();
  const targetTrackId = randomUUID();
  queuedResult = makeStubbedChop();

  await client.callTool({
    name: "clip_slice_to_sampler",
    arguments: {
      clipId,
      targetTrackId,
      mode: "transients",
      sensitivity: 0.7,
      minSliceSeconds: 0.08,
      maxSlices: 16,
      includeHead: true,
      baseNote: 48,
      snapWindowMs: 5,
      generateMIDI: false,
      atBeat: 16,
      velocityFromStrength: true,
      muteSourceTrack: true,
    },
  });

  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0]!.params, {
    clipId,
    targetTrackId,
    mode: "transients",
    sensitivity: 0.7,
    divisions: undefined,
    gridBeats: undefined,
    minSliceSeconds: 0.08,
    maxSlices: 16,
    includeHead: true,
    baseNote: 48,
    snapWindowMs: 5,
    generateMIDI: false,
    atBeat: 16,
    velocityFromStrength: true,
    muteSourceTrack: true,
    mapping: undefined,
    roles: undefined,
  });
});

test("⭐ muteSourceTrack round-trips, and the response's TWO mute readings survive (m39-pads)", async () => {
  // The chop is read-only, so without this the original and the pad
  // reconstruction play together — measured +6.0 LU and comb-filtered.
  const clipId = randomUUID();
  const mutedTrackId = randomUUID();
  queuedResult = { ...makeStubbedChop(), mutedTrackId, sourceTrackMuted: true };

  const result = await client.callTool({
    name: "clip_slice_to_sampler",
    arguments: { clipId, muteSourceTrack: true },
  });

  assert.equal(calls[0]!.params["muteSourceTrack"], true);
  const parsed = parseJSON(result as any);
  // ⭐⭐ TWO FIELDS, NOT ONE SPELT TWICE. `mutedTrackId` answers "what did this
  // call change, and what will undo restore?"; `sourceTrackMuted` answers "will
  // the original be heard?". They diverge in BOTH directions — an already-muted
  // track gives null + true, a chop onto the source's own track gives null +
  // false — so an agent inferring audibility from `mutedTrackId` would tell a
  // user to go mute a track that is already silent.
  assert.equal(parsed.mutedTrackId, mutedTrackId);
  assert.equal(parsed.sourceTrackMuted, true);

  // The already-muted combination, verbatim across the boundary.
  calls.length = 0;
  queuedResult = {
    ...makeStubbedChop(),
    mutedTrackId: null,
    sourceTrackMuted: true,
    warnings: ["“Break” was already muted, so nothing changed there"],
  };
  const second = parseJSON((await client.callTool({
    name: "clip_slice_to_sampler",
    arguments: { clipId, muteSourceTrack: true },
  })) as any);
  assert.equal(second.mutedTrackId, null, "nothing was muted BY THIS CALL");
  assert.equal(second.sourceTrackMuted, true, "…and the original is still inaudible");
  assert.match(second.warnings[0], /already muted/);
});

test("muteSourceTrack is rejected at the schema layer when it is not a boolean", async () => {
  const result = (await client.callTool({
    name: "clip_slice_to_sampler",
    arguments: { clipId: randomUUID(), muteSourceTrack: "yes" },
  })) as any;
  assert.ok(result.isError);
  assert.equal(calls.length, 0, "the schema refused before the bridge");
});

test("clip_slice_to_sampler forwards the divisions and grid modes' own parameters", async () => {
  const clipId = randomUUID();
  queuedResult = makeStubbedChop();

  await client.callTool({
    name: "clip_slice_to_sampler",
    arguments: { clipId, mode: "divisions", divisions: 8 },
  });
  assert.equal(calls[0]!.params["mode"], "divisions");
  assert.equal(calls[0]!.params["divisions"], 8);
  assert.equal(calls[0]!.params["gridBeats"], undefined);

  calls = [];
  queuedResult = makeStubbedChop();
  await client.callTool({
    name: "clip_slice_to_sampler",
    arguments: { clipId, mode: "grid", gridBeats: 0.5 },
  });
  assert.equal(calls[0]!.params["mode"], "grid");
  assert.equal(calls[0]!.params["gridBeats"], 0.5);
  assert.equal(calls[0]!.params["divisions"], undefined);
});

test("clip_slice_to_sampler requires a UUID clipId (schema layer, zero bridge calls)", async () => {
  const missing = (await client.callTool({
    name: "clip_slice_to_sampler",
    arguments: {},
  })) as any;
  assert.ok(missing.isError, "a missing clipId must be rejected before the bridge call");

  const notAUuid = (await client.callTool({
    name: "clip_slice_to_sampler",
    arguments: { clipId: "not-a-uuid" },
  })) as any;
  assert.ok(notAUuid.isError);

  const badTarget = (await client.callTool({
    name: "clip_slice_to_sampler",
    arguments: { clipId: randomUUID(), targetTrackId: "nope" },
  })) as any;
  assert.ok(badTarget.isError);

  assert.equal(calls.length, 0);
});

test("clip_slice_to_sampler's range and enum guards fire at the schema layer", async () => {
  const clipId = randomUUID();
  const rejected: Array<Record<string, unknown>> = [
    { mode: "chop" }, // not one of the three modes
    { divisions: 1 }, // below 2
    { divisions: 129 }, // above 128
    { divisions: 4.5 }, // not an integer
    { gridBeats: 0 }, // not positive
    { sensitivity: 1.5 },
    { maxSlices: 0 },
    { maxSlices: 97 }, // above the hard cap
    { baseNote: -1 },
    { baseNote: 128 },
    { snapWindowMs: -1 },
    { snapWindowMs: 21 },
    { minSliceSeconds: 0 },
    { atBeat: -1 },
  ];
  for (const bad of rejected) {
    const result = (await client.callTool({
      name: "clip_slice_to_sampler",
      arguments: { clipId, ...bad },
    })) as any;
    assert.ok(result.isError, `expected ${JSON.stringify(bad)} to be rejected`);
  }
  assert.equal(calls.length, 0, "schema rejections never reach the bridge");

  // POSITIVE CONTROL: the boundary values these guards bracket are ACCEPTED —
  // a schema that rejected everything would pass every assertion above.
  queuedResult = makeStubbedChop();
  const ok = (await client.callTool({
    name: "clip_slice_to_sampler",
    arguments: {
      clipId,
      mode: "divisions",
      divisions: 128,
      maxSlices: 96,
      baseNote: 0,
      snapWindowMs: 20,
      minSliceSeconds: 0.001,
      atBeat: 0,
    },
  })) as any;
  assert.ok(!ok.isError, "the accepted boundary values must actually pass");
  assert.equal(calls.length, 1);
});

test("clip_slice_to_sampler is registered via the STRICT-SCHEMA wrapper: an unrecognized argument IS rejected", async () => {
  const result = (await client.callTool({
    name: "clip_slice_to_sampler",
    arguments: { clipId: randomUUID(), padCount: 8 },
  })) as any;
  assert.ok(result.isError, "an unrecognized argument must be rejected at the MCP boundary");
  assert.equal(calls.length, 0, "and must never reach the bridge");
});

test("clip_slice_to_sampler surfaces the app's REJECT-never-truncate refusal verbatim", async () => {
  queuedError = new Error(
    "chopping clip 11111111-1111-4111-8111-111111111111 would make 40 pads, over the " +
      "maxSlices limit of 32 — nothing was changed. Raise maxSlices (hard cap 96), lower " +
      "sensitivity, raise minSliceSeconds, or trim the clip window."
  );
  const result = (await client.callTool({
    name: "clip_slice_to_sampler",
    arguments: { clipId: randomUUID() },
  })) as any;
  assert.ok(result.isError);
  const text = result.content[0].text as string;
  assert.match(text, /would make 40 pads/);
  assert.match(text, /nothing was changed/);
  assert.equal(calls.length, 1, "the refusal came from the app, not the schema");
});

test("⭐ clip_slice_to_sampler's description names the CHOP use case, the velocity ruling and the reject-never-truncate rule", async () => {
  const { tools } = (await client.listTools()) as any;
  const tool = tools.find((t: any) => t.name === "clip_slice_to_sampler");
  assert.ok(tool, "clip_slice_to_sampler must be registered");
  const description = tool.description as string;

  // The use case, in the words an agent would be given by a person.
  assert.match(description, /sample flip/i);
  assert.match(description, /chop/i);
  assert.match(description, /MPC/);
  assert.match(description, /groove/i);
  // The velocity ruling, with its arithmetic — this is the one an agent would
  // otherwise "fix" by mapping strength to velocity.
  assert.match(description, /127/);
  assert.match(description, /velocityFromStrength/);
  // The two refusals that would otherwise look like a successful chop.
  assert.match(description, /REJECT|rejects?/i);
  assert.match(description, /truncate/i);
  // m39-pads: the +6 LU surprise, and the two readings that answer it. An
  // agent that cannot find `muteSourceTrack` will chop, listen, and hear a
  // comb-filtered double with nothing to attribute it to.
  assert.match(description, /muteSourceTrack/);
  assert.match(description, /sourceTrackMuted/);
  // Where the caller goes next. m32-c: this used to assert only /zonePatches/,
  // which the description satisfied by telling the agent to call
  // `track_set_instrument {sampler: {zonePatches}}` — a call the MCP schema
  // REJECTS (Defect B, samplerSchema is `.strict()` and deliberately does not
  // re-expose the key; see sampler-describe-and-edit.test.ts's own pin). The
  // description pointed at a rejected call and the assertion could not see it,
  // because a bare /zonePatches/ match is true of both the right answer and the
  // wrong one. Pin the ACTIONABLE tool name, and pin that the raw-wire key is
  // named as something NOT to route through track_set_instrument.
  assert.match(description, /instrument_set_sampler_zones/);
  assert.match(description, /zonePatches/);
  assert.match(
    description,
    /REJECTS the key/,
    "the description must say the track_set_instrument route is rejected, not merely mention zonePatches"
  );
  // And the neighbour it must not be confused with.
  assert.match(description, /clip_quantize_audio/);
});

// ---------------------------------------------------------------------------
// m39-w4-7 — kit-aware slicing: `mapping: "kit"` + `roles`
// ---------------------------------------------------------------------------

/** A kit-mapped reply: the extra per-slice `role`/`confidence` and `kitSummary`. */
function makeStubbedKitChop() {
  const base = makeStubbedChop();
  return {
    ...base,
    slices: [
      { ...base.slices[0]!, pitch: 36, role: "kick", confidence: 0.93 },
      { ...base.slices[1]!, pitch: 38, role: "snare", confidence: 1 },
      { ...base.slices[2]!, pitch: 42, role: "closedHat", confidence: 0.61 },
    ],
    kitSummary: "Sorted into 1 kick, 1 snare and 1 closed hat.",
  };
}

test("⭐ clip_slice_to_sampler forwards mapping \"kit\" and roles verbatim, and the kit reply round-trips (m39-w4-7)", async () => {
  const clipId = randomUUID();
  const stubbed = makeStubbedKitChop();
  queuedResult = stubbed;

  const result = await client.callTool({
    name: "clip_slice_to_sampler",
    arguments: { clipId, mapping: "kit", roles: { "1": "snare", "12": "openHat" }, muteSourceTrack: true },
  });

  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.command, "clip.sliceToSampler");
  assert.equal(calls[0]!.params["mapping"], "kit");
  assert.deepEqual(calls[0]!.params["roles"], { "1": "snare", "12": "openHat" });
  assert.equal(calls[0]!.params["baseNote"], undefined, "kit never gets a baseNote from this layer");

  const parsed = parseJSON(result as any);
  assert.equal(parsed.slices[1].role, "snare");
  assert.equal(parsed.slices[1].confidence, 1);
  assert.match(parsed.kitSummary, /^Sorted into/);
  assert.deepEqual(parsed, stubbed, "role, confidence and kitSummary survive the boundary");
});

test("clip_slice_to_sampler forwards mapping \"chromatic\" explicitly and a default call stays free of kit keys", async () => {
  const clipId = randomUUID();
  queuedResult = makeStubbedChop();
  const result = await client.callTool({
    name: "clip_slice_to_sampler",
    arguments: { clipId, mapping: "chromatic", baseNote: 48 },
  });
  assert.equal(calls[0]!.params["mapping"], "chromatic");
  assert.equal(calls[0]!.params["baseNote"], 48);
  assert.equal(calls[0]!.params["roles"], undefined);
  const parsed = parseJSON(result as any);
  for (const slice of parsed.slices) {
    assert.ok(!("role" in slice) && !("confidence" in slice), "a chromatic reply carries no role fields");
  }
  assert.ok(!("kitSummary" in parsed), "a chromatic reply carries no kitSummary");
});

test("clip_slice_to_sampler's mapping and roles guards fire at the schema layer, before the bridge", async () => {
  const clipId = randomUUID();
  const bad: Array<[string, Record<string, unknown>]> = [
    ["an unknown mapping", { mapping: "drumkit" }],
    ["a non-string mapping", { mapping: 1 }],
    ["an unknown role", { mapping: "kit", roles: { "0": "tom" } }],
    ["a non-numeric slice key", { mapping: "kit", roles: { first: "kick" } }],
    ["a negative slice key", { mapping: "kit", roles: { "-1": "kick" } }],
    ["a zero-padded slice key (the app counts \"01\" as not a slice number)", { mapping: "kit", roles: { "01": "kick" } }],
    ["roles as an array", { mapping: "kit", roles: ["kick"] }],
  ];
  for (const [label, extra] of bad) {
    const result = (await client.callTool({
      name: "clip_slice_to_sampler",
      arguments: { clipId, ...extra },
    })) as any;
    assert.ok(result.isError, `${label} must be rejected`);
  }
  assert.equal(calls.length, 0, "every one refused before the bridge");
});

test("clip_slice_to_sampler surfaces the app's kit refusals verbatim (baseNote with kit, roles outside kit, bad index, overflow)", async () => {
  const messages = [
    "clip.sliceToSampler: 'baseNote' only applies to mapping 'chromatic' — mapping 'kit' puts each hit on its General MIDI drum note",
    "clip.sliceToSampler: 'roles' only applies to mapping 'kit' — pass mapping: \"kit\" to sort the hits into a drum kit",
    "roles names slice 9, but this chop made 4 slices (0–3). Nothing was changed",
    "sorting clip 11111111-1111-4111-8111-111111111111 into a drum kit would put 50 hits on the extra pads from note 84, which needs note 133 — MIDI stops at 127. Nothing was changed.",
  ];
  const argsList: Array<Record<string, unknown>> = [
    { mapping: "kit", baseNote: 36 },
    { roles: { "0": "kick" } }, // the schema lets this through: only the app knows the mapping default
    { mapping: "kit", roles: { "9": "kick" } },
    { mapping: "kit", maxSlices: 96 },
  ];
  for (let i = 0; i < messages.length; i++) {
    calls = [];
    queuedError = new Error(messages[i]!);
    const result = (await client.callTool({
      name: "clip_slice_to_sampler",
      arguments: { clipId: randomUUID(), ...argsList[i]! },
    })) as any;
    assert.ok(result.isError, `refusal ${i} must be a tool error`);
    assert.ok((result.content[0].text as string).includes(messages[i]!), `refusal ${i} must arrive verbatim`);
    assert.equal(calls.length, 1, `refusal ${i} came from the app, so the call reached the bridge`);
  }
});

test("⭐ clip_slice_to_sampler's description teaches the kit sort: notes, best-guess, measured limits, roles", async () => {
  const { tools } = (await client.listTools()) as any;
  const tool = tools.find((t: any) => t.name === "clip_slice_to_sampler");
  const description = tool.description as string;
  assert.match(description, /mapping: "kit"/);
  for (const note of ["36", "38", "42", "46", "84"]) assert.match(description, new RegExp(`\\b${note}\\b`));
  assert.match(description, /best guess/i);
  assert.match(description, /confidence/);
  assert.match(description, /kitSummary/);
  assert.match(description, /CLOSED hat can be sorted as\s+OPEN|CLOSED hat can be sorted as OPEN/);
  assert.match(description, /velocity 100 only/);
  assert.match(description, /roles/);
  assert.match(description, /choke group 0/);
  assert.match(description, /baseNote.*REFUSED|REFUSED together/);
  const props = tool.inputSchema.properties;
  assert.ok(props.mapping && props.roles, "mapping and roles are in the advertised schema");
  assert.deepEqual(props.mapping.enum, ["chromatic", "kit"]);
});

/**
 * DRIFT: the MCP tool's parameter names are exactly the wire's. The wire's list
 * is the `rejectUnknownKeys` array of the `clip.sliceToSampler` case in
 * Commands.swift (the app refuses any other key, so it IS the contract); read
 * here from source and compared with (a) the advertised MCP schema and (b) the
 * keys the tool really forwards when every parameter is supplied.
 */
test("⭐ DRIFT: clip_slice_to_sampler's parameters equal the wire's accepted keys, advertised and forwarded", async () => {
  const swift = readFileSync(
    fileURLToPath(new URL("../../../Sources/DAWControl/Commands.swift", import.meta.url)),
    "utf8"
  );
  const caseStart = swift.indexOf('case "clip.sliceToSampler":');
  assert.ok(caseStart > 0, "the wire case must be found (a moved case fails loudly, not silently)");
  const after = swift.slice(caseStart);
  const match = /rejectUnknownKeys\(\s*\[([^\]]*)\]/.exec(after);
  assert.ok(match, "the wire's accepted-key list must be found");
  const wireKeys = [...match![1]!.matchAll(/"([A-Za-z]+)"/g)].map((m) => m[1]!).sort();
  assert.ok(wireKeys.includes("clipId") && wireKeys.includes("mapping") && wireKeys.includes("roles"));

  const { tools } = (await client.listTools()) as any;
  const tool = tools.find((t: any) => t.name === "clip_slice_to_sampler");
  assert.deepEqual(Object.keys(tool.inputSchema.properties).sort(), wireKeys, "advertised schema == wire keys");

  const clipId = randomUUID();
  queuedResult = makeStubbedChop();
  await client.callTool({
    name: "clip_slice_to_sampler",
    arguments: {
      clipId, targetTrackId: randomUUID(), mode: "transients", sensitivity: 0.5, divisions: undefined,
      minSliceSeconds: 0.05, maxSlices: 8, includeHead: false, snapWindowMs: 3, generateMIDI: true,
      atBeat: 0, velocityFromStrength: false, muteSourceTrack: false, mapping: "kit", roles: { "0": "kick" },
    },
  });
  const forwarded = Object.keys(calls[0]!.params).sort();
  for (const key of forwarded) assert.ok(wireKeys.includes(key), `forwarded key ${key} is not a wire key`);
  // every wire key except the mode-scoped / kit-exclusive ones is forwarded when supplied
  for (const key of wireKeys) assert.ok(forwarded.includes(key), `wire key ${key} is never forwarded by the tool`);
});
