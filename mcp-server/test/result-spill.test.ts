/**
 * result-spill.test.ts — the size guard on every MCP tool reply
 * (`src/result-spill.ts`, wired into `server.ts`'s `textResult`).
 *
 * ⭐ THE GATES THIS FILE EXISTS FOR use the sizes a real tester actually
 * measured on a real 294-second project, not a toy payload:
 *
 *   • `clip_apply_effort_shape` on an EIGHT-note clip -> 146,744 characters /
 *     7,145 lines, because the reply echoes all 1,758 controller points.
 *   • `edit_undo` -> 2,222,508 characters / 72,791 lines, because it returns a
 *     full project snapshot. Their verdict: "effectively unusable".
 *
 * A gate built on a 200-byte payload proves nothing about either. So the two
 * fixtures below are asserted to BE at least that large before anything else
 * is checked — a fixture that quietly shrank would otherwise turn this whole
 * file green while testing nothing that matters.
 *
 * ⭐ AND THE GATE THAT STOPS THE LAZY FIX: every "small reply / scalars inline /
 * counts named / file complete" assertion here is ALSO satisfied by a guard
 * that dumps everything to a file and returns a bare path — the exact design
 * the task rejected. `below the limit the text is byte-identical …` is the one
 * that isn't: it fails the moment the guard touches a reply it should not.
 * Plant "always spill" and that test, alone, goes red.
 */

import { test, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";

import { DawBridge } from "../src/bridge.js";
import { formatToolText } from "../src/result-spill.js";

// ---------------------------------------------------------------------------
// Fixtures at the measured sizes
// ---------------------------------------------------------------------------

/** The tester's case: an 8-note clip carrying 1,758 breath-controller points. */
const EFFORT_SHAPE_POINTS = 1758;
const EFFORT_SHAPE_MEASURED_CHARS = 146_744;
const UNDO_MEASURED_CHARS = 2_222_508;

function effortShapeReply(): Record<string, unknown> {
  return {
    clip: {
      id: "6E2C4F5A-1111-4A2B-9C3D-000000000001",
      trackId: "TRK-0007",
      name: "Tenor Sax — verse phrase",
      startBeat: 32,
      lengthBeats: 16,
      muted: false,
      color: "#7FD4FF",
      notes: Array.from({ length: 8 }, (_, i) => ({
        id: `N-${i}`,
        pitch: 60 + i,
        startBeat: 32 + i * 2,
        durationBeats: 1.75,
        velocity: 88 + i,
        channel: 0,
      })),
      controllerLanes: [
        {
          controller: 2,
          name: "Breath (CC2)",
          points: Array.from({ length: EFFORT_SHAPE_POINTS }, (_, i) => ({
            beat: Number((32 + (i * 16) / EFFORT_SHAPE_POINTS).toFixed(6)),
            value: Number((0.2 + 0.7 * Math.abs(Math.sin(i / 40))).toFixed(4)),
          })),
        },
      ],
    },
    notesTouched: 8,
    phraseCount: 2,
    minEffort: 0.18,
    maxEffort: 0.94,
    pattern: "messaDiVoce",
    air: { added: true, level: 0.22, noiseFloorDb: -48.5, lane: 11 },
  };
}

/** `edit_undo`'s reply: a label plus the entire project snapshot. */
function undoReply(): Record<string, unknown> {
  return {
    undone: "Apply Effort Shape",
    snapshot: {
      name: "Untitled Project",
      bpm: 96,
      timeSignature: { numerator: 4, denominator: 4 },
      lengthSeconds: 294,
      undoLabel: "Add Track",
      redoLabel: "Apply Effort Shape",
      tracks: Array.from({ length: 8 }, (_, t) => ({
        id: `TRK-${t}`,
        name: `Track ${t + 1}`,
        kind: t % 3 === 0 ? "audio" : "instrument",
        volume: 0.8,
        pan: 0,
        clips: Array.from({ length: 12 }, (_, c) => ({
          id: `CLP-${t}-${c}`,
          name: `Clip ${c + 1}`,
          startBeat: c * 16,
          notes: Array.from({ length: 101 }, (_, n) => ({
            id: `N-${t}-${c}-${n}`,
            pitch: 36 + (n % 48),
            startBeat: n * 0.25,
            durationBeats: 0.2,
            velocity: 70 + (n % 40),
            channel: 0,
          })),
        })),
      })),
    },
  };
}

// ---------------------------------------------------------------------------
// Environment
// ---------------------------------------------------------------------------

let spillRoot: string;

function useSpillDir(): string {
  const dir = mkdtempSync(join(tmpdir(), "dawpro-spill-test-"));
  process.env["DAWPRO_MCP_SPILL_DIR"] = dir;
  return dir;
}

before(() => {
  spillRoot = mkdtempSync(join(tmpdir(), "dawpro-spill-root-"));
});

beforeEach(() => {
  delete process.env["DAWPRO_MCP_MAX_RESULT_CHARS"];
  process.env["DAWPRO_MCP_SPILL_DIR"] = spillRoot;
});

type Dict = Record<string, unknown>;

function parseEnvelope(text: string): Record<string, unknown> {
  const parsed: unknown = JSON.parse(text);
  assert.ok(parsed !== null && typeof parsed === "object", "envelope must be a JSON object");
  return parsed as Record<string, unknown>;
}

function notice(env: Record<string, unknown>): Record<string, unknown> {
  const n = env["_elided"];
  assert.ok(n !== null && typeof n === "object", "envelope must carry an _elided notice");
  return n as Record<string, unknown>;
}

function at(root: unknown, path: readonly (string | number)[]): unknown {
  let cur: unknown = root;
  for (const step of path) {
    assert.ok(cur !== null && typeof cur === "object", `path stopped early at ${String(step)}`);
    cur = (cur as Record<string | number, unknown>)[step];
  }
  return cur;
}

// ---------------------------------------------------------------------------
// The pass-through gate — the one a "spill everything" guard cannot satisfy
// ---------------------------------------------------------------------------

test("below the limit the text is byte-identical to JSON.stringify(value, null, 2)", () => {
  // Grown to land JUST under the default 24,000-char limit: the interesting
  // side of the boundary, not a 200-byte toy.
  const rows: unknown[] = [];
  let text = "";
  for (let i = 0; i < 5000; i += 1) {
    rows.push({ id: `TRK-${i}`, name: `Track ${i}`, volume: 0.8 });
    const candidate = JSON.stringify({ tracks: rows }, null, 2);
    if (candidate.length > 23_900) {
      rows.pop();
      break;
    }
    text = candidate;
  }
  const value = { tracks: rows };
  const expected = JSON.stringify(value, null, 2);
  assert.equal(expected, text);
  assert.ok(expected.length > 20_000, `fixture must be near the limit, was ${expected.length}`);
  assert.ok(expected.length <= 24_000);

  assert.equal(formatToolText(value), expected);
});

test("exactly at the limit passes through; one character over is elided", () => {
  process.env["DAWPRO_MCP_MAX_RESULT_CHARS"] = "400";
  useSpillDir();

  // Build a value whose pretty JSON is exactly 400 chars.
  let pad = 1;
  let exact: string | null = null;
  for (; pad < 1000; pad += 1) {
    const candidate = JSON.stringify({ note: "x".repeat(pad) }, null, 2);
    if (candidate.length === 400) {
      exact = candidate;
      break;
    }
    if (candidate.length > 400) break;
  }
  assert.ok(exact !== null, "could not build a 400-char fixture");
  const atLimit = { note: "x".repeat(pad) };
  assert.equal(formatToolText(atLimit), exact);

  const over = { note: "x".repeat(pad + 1) };
  const overText = formatToolText(over);
  assert.notEqual(overText, JSON.stringify(over, null, 2));
  assert.ok(overText.includes("_elided"));
});

test("undefined and short strings keep their old behaviour", () => {
  assert.equal(formatToolText(undefined), "ok");
  assert.equal(formatToolText("nothing to undo"), "nothing to undo");
});

// ---------------------------------------------------------------------------
// Case A — clip_apply_effort_shape, 146,744 chars
// ---------------------------------------------------------------------------

test("effort-shape reply (>=146,744 chars) returns small, with every scalar inline", () => {
  const dir = useSpillDir();
  const value = effortShapeReply();
  const full = JSON.stringify(value, null, 2);
  assert.ok(
    full.length >= EFFORT_SHAPE_MEASURED_CHARS,
    `fixture must be at least the measured ${EFFORT_SHAPE_MEASURED_CHARS} chars, was ${full.length}`
  );

  const out = formatToolText(value);
  assert.ok(out.length <= 24_000, `reply must fit the limit, was ${out.length}`);
  assert.ok(out.length < full.length / 20, `expected a big reduction, got ${out.length}`);

  const env = parseEnvelope(out);

  // ⭐ The design point: the caller's own scalars are still where the tool's
  // documentation says they are — no file read needed for any of them.
  assert.equal(env["notesTouched"], 8);
  assert.equal(env["phraseCount"], 2);
  assert.equal(env["minEffort"], 0.18);
  assert.equal(env["maxEffort"], 0.94);
  assert.equal(env["pattern"], "messaDiVoce");
  assert.deepEqual(env["air"], { added: true, level: 0.22, noiseFloorDb: -48.5, lane: 11 });

  // Short arrays stay whole: all 8 notes, in full.
  const notes = at(env, ["clip", "notes"]);
  assert.ok(Array.isArray(notes));
  assert.equal(notes.length, 8);
  assert.deepEqual(notes, (value["clip"] as Record<string, unknown>)["notes"]);

  // Clip scalars survive too.
  assert.equal(at(env, ["clip", "id"]), "6E2C4F5A-1111-4A2B-9C3D-000000000001");
  assert.equal(at(env, ["clip", "name"]), "Tenor Sax — verse phrase");
  assert.equal(at(env, ["clip", "controllerLanes", 0, "controller"]), 2);
  assert.equal(at(env, ["clip", "controllerLanes", 0, "name"]), "Breath (CC2)");

  // Only the lane array was replaced, and it names its count and location.
  const points = at(env, ["clip", "controllerLanes", 0, "points"]) as Record<string, unknown>;
  assert.equal(points["_elided"], "array");
  assert.equal(points["elementCount"], EFFORT_SHAPE_POINTS);
  assert.equal(points["path"], "$.clip.controllerLanes[0].points");
  assert.ok(Array.isArray(points["fileLineRange"]));

  // Inline samples: "what is in this lane" needs no read at all.
  const head = points["head"];
  assert.ok(Array.isArray(head) && head.length > 0, "an elided array must carry a head sample");
  assert.deepEqual(head[0], at(value, ["clip", "controllerLanes", 0, "points", 0]));

  const n = notice(env);
  assert.equal(n["status"], "ELIDED_TO_FILE");
  assert.equal(n["fullChars"], full.length);
  assert.equal(n["elidedCount"], 1);
  assert.match(String(n["howToRead"]), /DO NOT re-run this tool call/);
  assert.match(String(n["reason"]), /THIS IS NOT THE COMPLETE REPLY/);

  // The file holds the reply IN FULL — not a truncation of it.
  const file = String(n["file"]);
  assert.ok(file.startsWith(dir), `spill file must live in the temp spill dir, got ${file}`);
  const onDisk = readFileSync(file, "utf8");
  assert.equal(onDisk.length, full.length);
  assert.deepEqual(JSON.parse(onDisk), value);
});

test("published line arithmetic reads points 500..600 out of the spill file exactly", () => {
  useSpillDir();
  const value = effortShapeReply();
  const env = parseEnvelope(formatToolText(value));
  const n = notice(env);
  assert.equal(n["lineRangesVerified"], true);

  const points = at(env, ["clip", "controllerLanes", 0, "points"]) as Record<string, unknown>;
  const range = points["fileLineRange"] as [number, number];
  const perElement = points["linesPerElement"] as number;
  assert.ok(Number.isInteger(perElement) && perElement > 0, "uniform elements must publish a stride");

  const fileLines = readFileSync(String(n["file"]), "utf8").split("\n");

  // The exact formula the envelope tells the agent to use.
  const first = 500;
  const last = 600;
  const startLine = range[0] + 1 + first * perElement;
  const endLine = range[0] + (last + 1) * perElement;
  const slice = fileLines.slice(startLine - 1, endLine).join("\n");
  const parsed: unknown = JSON.parse(`[${slice.trimEnd().replace(/,$/, "")}]`);

  const original = at(value, ["clip", "controllerLanes", 0, "points"]) as unknown[];
  assert.deepEqual(parsed, original.slice(first, last + 1));
});

test("every published line range really delimits its node in the spill file", () => {
  useSpillDir();
  const value = undoReply();
  const env = parseEnvelope(formatToolText(value));
  const n = notice(env);
  assert.equal(n["lineRangesVerified"], true);

  const fileLines = readFileSync(String(n["file"]), "utf8").split("\n");
  const entries = n["elided"] as { path: string; kind: string; fileLineRange: [number, number] }[];
  assert.ok(entries.length > 0);

  for (const e of entries) {
    assert.ok(e.fileLineRange !== null, `${e.path} should have a verified range`);
    const [s, f] = e.fileLineRange;
    const open = fileLines[s - 1] ?? "";
    const close = fileLines[f - 1] ?? "";
    const key = e.path.slice(e.path.lastIndexOf(".") + 1);
    assert.ok(open.includes(`"${key}":`), `${e.path}: start line must name the key, got ${open}`);
    assert.ok(open.trimEnd().endsWith(e.kind === "array" ? "[" : "{"), `${e.path}: start token`);
    assert.match(close.trim(), e.kind === "array" ? /^\],?$/ : /^\},?$/, `${e.path}: end token`);
    // And the delimited text really parses back to the node it claims to be.
    const body = fileLines.slice(s - 1, f).join("\n");
    const opened = body.slice(body.indexOf(e.kind === "array" ? "[" : "{"));
    JSON.parse(opened.trimEnd().replace(/,$/, ""));
  }
});

// ---------------------------------------------------------------------------
// Case B — edit_undo, 2,222,508 chars
// ---------------------------------------------------------------------------

test("undo reply (>=2,222,508 chars) returns small, keeps the label and snapshot scalars", () => {
  useSpillDir();
  const value = undoReply();
  const full = JSON.stringify(value, null, 2);
  assert.ok(
    full.length >= UNDO_MEASURED_CHARS,
    `fixture must be at least the measured ${UNDO_MEASURED_CHARS} chars, was ${full.length}`
  );

  const out = formatToolText(value);
  assert.ok(out.length <= 24_000, `reply must fit the limit, was ${out.length}`);

  const env = parseEnvelope(out);
  // The field the tool's documentation promises stays at the top level.
  assert.equal(env["undone"], "Apply Effort Shape");
  assert.equal(at(env, ["snapshot", "bpm"]), 96);
  assert.equal(at(env, ["snapshot", "lengthSeconds"]), 294);
  assert.equal(at(env, ["snapshot", "undoLabel"]), "Add Track");
  assert.deepEqual(at(env, ["snapshot", "timeSignature"]), { numerator: 4, denominator: 4 });

  // ⭐ NOT a bare path: per-track identity survived the walk, so an agent can
  // still act on the result without reading anything.
  const tracks = at(env, ["snapshot", "tracks"]);
  assert.ok(Array.isArray(tracks), "tracks must be recursed into, not elided wholesale");
  assert.equal(tracks.length, 8);
  assert.equal(at(tracks, [0, "id"]), "TRK-0");
  assert.equal(at(tracks, [0, "name"]), "Track 1");
  assert.equal(at(tracks, [0, "kind"]), "audio");
  assert.equal(at(tracks, [7, "id"]), "TRK-7");

  // ⭐ The clips array IS too big to quote element-for-element, and this is the
  // boundary the design turns on: without the scalar OUTLINE the agent loses
  // every clip id and the envelope becomes a bare path with extra steps.
  const clips = at(tracks, [0, "clips"]) as Record<string, unknown>;
  assert.equal(clips["_elided"], "array");
  assert.equal(clips["elementCount"], 12);
  const outline = clips["outline"] as { note: string; covered: string; items: Dict[] };
  assert.ok(outline, "an array of too-big elements must still outline them");
  assert.match(outline.note, /PARTIAL/, "an outline must never look complete");
  assert.match(outline.covered, /^(all 12|first \d+ of 12)$/);
  assert.equal(outline.items.length > 0, true);
  assert.equal(outline.items[0]?.["id"], "CLP-0-0");
  assert.equal(outline.items[0]?.["name"], "Clip 1");
  // …and the dropped container inside each outlined element is named + counted.
  assert.equal(outline.items[0]?.["notes"], "<array of 101, omitted>");
  // The count claimed by `covered` is the count actually delivered.
  const claimed = outline.covered.startsWith("all")
    ? 12
    : Number(outline.covered.replace(/^first (\d+) of 12$/, "$1"));
  assert.equal(outline.items.length, claimed, "covered must match what was delivered");

  const n = notice(env);
  assert.equal(n["status"], "ELIDED_TO_FILE");
  assert.equal(n["fullChars"], full.length);
  const entries = n["elided"] as { path: string; elementCount?: number }[];
  assert.ok(entries.length > 0, "the notice must index what it replaced");
  for (const e of entries) {
    assert.ok(typeof e.elementCount === "number" && e.elementCount > 0, `${e.path}: needs a count`);
  }

  const onDisk = readFileSync(String(n["file"]), "utf8");
  assert.equal(onDisk.length, full.length);
  assert.deepEqual(JSON.parse(onDisk), value);
});

test("a placeholder is never substituted for a node it would not shrink", () => {
  useSpillDir();
  // Force the degradation ladder down to its tightest passes, where a medium
  // string would otherwise be "replaced" by a placeholder BIGGER than itself —
  // more context spent to say less.
  process.env["DAWPRO_MCP_MAX_RESULT_CHARS"] = "2000";
  const points = Array.from({ length: 4000 }, (_, i) => ({ beat: i * 0.25, value: i % 128 }));

  // 200 chars: a placeholder for it (preview + chars + path + line range) comes
  // to ~247, so replacing it would COST context and say LESS. It must survive.
  const short = "x".repeat(200);
  const kept = parseEnvelope(formatToolText({ summary: short, points }));
  assert.equal(kept["summary"], short, "a node a placeholder cannot shrink must stay verbatim");
  const keptPoints = kept["points"] as Record<string, unknown>;
  assert.equal(keptPoints["_elided"], "array", "the array that IS oversized is still replaced");
  assert.equal(keptPoints["elementCount"], 4000);
  // The notice must not claim to have elided the node it kept.
  const paths = (notice(kept)["elided"] as { path: string }[]).map((e) => e.path);
  assert.ok(!paths.includes("$.summary"), `kept node must not be indexed as elided: ${paths}`);

  // …and the complement, so this is not just "never elide strings": at 400
  // chars the placeholder DOES shrink the reply, so it is used.
  process.env["DAWPRO_MCP_MAX_RESULT_CHARS"] = "2500";
  const long = "y".repeat(400);
  const replaced = parseEnvelope(formatToolText({ summary: long, points }));
  const ph = replaced["summary"] as Record<string, unknown>;
  assert.equal(ph["_elided"], "string");
  assert.equal(ph["chars"], 400);
  assert.ok(
    JSON.stringify(ph).length < JSON.stringify(long).length,
    "a substitution must actually be smaller than what it replaced"
  );
});

// ---------------------------------------------------------------------------
// Failing loudly
// ---------------------------------------------------------------------------

test("an unwritable spill dir is reported, never silently swallowed", () => {
  // Point the spill dir at a regular FILE so mkdir cannot succeed.
  const blocker = join(spillRoot, `blocker-${Date.now()}`);
  writeFileSync(blocker, "not a directory", "utf8");
  process.env["DAWPRO_MCP_SPILL_DIR"] = blocker;

  const value = effortShapeReply();
  const env = parseEnvelope(formatToolText(value));
  const n = notice(env);

  assert.equal(n["status"], "ELIDED_NO_FILE");
  assert.equal(n["file"], null);
  assert.ok(typeof n["writeError"] === "string" && String(n["writeError"]).length > 0);
  assert.match(String(n["warning"]), /NOT RETRIEVABLE/);
  assert.equal(n["howToRead"], undefined);

  // The useful half still arrives, and what is missing is still named.
  assert.equal(env["notesTouched"], 8);
  const points = at(env, ["clip", "controllerLanes", 0, "points"]) as Record<string, unknown>;
  assert.equal(points["elementCount"], EFFORT_SHAPE_POINTS);

  // ⛔ …and NOTHING may point at the file that does not exist. A reply that
  // says NOT RETRIEVABLE at the top and then publishes "read lines 21 + N*815"
  // is internally contradictory — the looks-valid-but-isn't failure this guard
  // exists to stop.
  const text = formatToolText(effortShapeReply());
  assert.ok(!text.includes("readElements"), "no read-the-file arithmetic without a file");
  assert.ok(!text.includes("Read the file"), "no read-the-file instruction without a file");
  assert.ok(!text.includes("linesPerElement"), "no per-element stride without a file");
  assert.equal(points["fileLineRange"], null);
  assert.equal(n["lineRangesVerified"], undefined, "no claim about ranges into a missing file");
  for (const e of n["elided"] as { path: string; fileLineRange: unknown }[]) {
    assert.equal(e.fileLineRange, null, `${e.path} must not carry a range into a missing file`);
  }
});

test("a huge plain-text reply spills to .txt and says so", () => {
  const dir = useSpillDir();
  const big = "lyric line\n".repeat(20_000);
  const out = formatToolText(big);
  assert.ok(out.length < 24_000);
  const n = notice(parseEnvelope(out));
  assert.equal(n["fullChars"], big.length);
  const file = String(n["file"]);
  assert.ok(file.startsWith(dir) && file.endsWith(".txt"), `expected a .txt spill, got ${file}`);
  assert.equal(readFileSync(file, "utf8"), big);
});

// ---------------------------------------------------------------------------
// End-to-end through the real server: the guard is in the live path
// ---------------------------------------------------------------------------

let calls: { command: string; params: Record<string, unknown> }[] = [];
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
  client = new Client({ name: "result-spill-test-client", version: "0.0.0" });
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
});

after(async () => {
  await client?.close();
});

test("edit_undo through the real server returns the small envelope, not an error", async () => {
  const dir = useSpillDir();
  calls = [];
  queuedResult = undoReply();

  const res = (await client.callTool({ name: "edit_undo", arguments: {} })) as {
    content: { type: string; text: string }[];
    isError?: boolean;
  };

  assert.equal(calls.length, 1);
  assert.equal(calls[0]?.command, "edit.undo");

  // ⛔ The call SUCCEEDED — only its reporting was shortened. Marking this an
  // error would invite a retry, and a retried undo undoes a second edit.
  assert.notEqual(res.isError, true);

  const text = res.content[0]?.text ?? "";
  assert.ok(text.length <= 24_000, `tool result must fit the limit, was ${text.length}`);
  const env = parseEnvelope(text);
  assert.equal(env["undone"], "Apply Effort Shape");

  const n = notice(env);
  // The spill file is named after the tool that produced it.
  const file = String(n["file"]);
  assert.ok(file.startsWith(dir));
  assert.match(file, /dawpro-mcp-edit_undo-/);
  assert.deepEqual(JSON.parse(readFileSync(file, "utf8")), queuedResult);

  // Exactly one spill file for one oversized call.
  assert.equal(readdirSync(dir).length, 1);
});

test("the ERROR path is guarded too, and ordinary error sentences are verbatim", async () => {
  const dir = useSpillDir();

  // The corner: an app-side error that echoes the payload it choked on would
  // overflow the caller exactly like an oversized success does.
  // ⚠️ This MUST go through the real server, not `formatToolText` directly:
  // calling the formatter here would pass whether or not `errorResult` uses it,
  // which is the vacuous-guard trap. (Measured — an earlier draft of this test
  // did exactly that and stayed green with the guard removed.)
  const huge = `clip.applyEffortShape failed: ${"controller point rejected; ".repeat(4000)}`;
  assert.ok(huge.length > 24_000);

  const restore = DawBridge.prototype.send;
  DawBridge.prototype.send = async function (): Promise<unknown> {
    throw new Error(huge);
  };
  try {
    const res = (await client.callTool({ name: "edit_undo", arguments: {} })) as {
      content: { type: string; text: string }[];
      isError?: boolean;
    };
    assert.equal(res.isError, true, "an error must still be an error");
    const text = res.content[0]?.text ?? "";
    assert.ok(text.length < 24_000, `guarded error was ${text.length}`);
    const n = notice(parseEnvelope(text));
    // The actionable sentence at the front still arrives inline.
    assert.match(String(n["preview"]), /^clip\.applyEffortShape failed: /);
    assert.equal(readFileSync(String(n["file"]), "utf8"), huge);
  } finally {
    DawBridge.prototype.send = restore;
  }

  // …and a normal error is untouched, byte for byte, through the real server.
  calls = [];
  const actionable = "app not running — start DAW Pro or run `swift run DAWApp`";
  DawBridge.prototype.send = async function (): Promise<unknown> {
    throw new Error(actionable);
  };
  try {
    const res = (await client.callTool({ name: "edit_undo", arguments: {} })) as {
      content: { type: string; text: string }[];
      isError?: boolean;
    };
    assert.equal(res.isError, true);
    assert.equal(res.content[0]?.text, actionable);
  } finally {
    DawBridge.prototype.send = async function (
      command: string,
      params: Record<string, unknown> = {}
    ): Promise<unknown> {
      calls.push({ command, params });
      return queuedResult;
    };
  }
  assert.ok(dir.length > 0);
});

test("a normal-sized tool reply is untouched end to end", async () => {
  useSpillDir();
  calls = [];
  queuedResult = { undone: "Set Tempo", snapshot: { bpm: 120, tracks: [] } };

  const res = (await client.callTool({ name: "edit_undo", arguments: {} })) as {
    content: { type: string; text: string }[];
  };
  assert.equal(res.content[0]?.text, JSON.stringify(queuedResult, null, 2));
});
