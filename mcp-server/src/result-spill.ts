/**
 * result-spill.ts — the size guard on EVERY MCP tool reply.
 *
 * ---------------------------------------------------------------------------
 * The measured problem
 * ---------------------------------------------------------------------------
 * A tester drove a real 294-second project through MCP and hit two replies
 * that overflow an agent's context outright:
 *
 *   • `clip_apply_effort_shape` on an EIGHT-note clip returned 146,744
 *     characters / 7,145 lines — the reply echoes the whole clip, and the clip
 *     now carries 1,758 controller-lane points.
 *   • `edit_undo` returned 2,222,508 characters / 72,791 lines, because
 *     `edit.undo` deliberately returns a full project snapshot
 *     (Sources/DAWControl/Commands.swift) "so agents re-orient in one round
 *     trip". Their words for the result: "effectively unusable".
 *
 * Both calls SUCCEED. It is the reply that is unusable, and a tool an agent
 * cannot read is a broken tool — which defeats the project's premise (full AI
 * control via MCP).
 *
 * ---------------------------------------------------------------------------
 * The shape of the fix — keep the small fields, replace only what is oversized
 * ---------------------------------------------------------------------------
 * The naive fix (dump the whole payload to a file, return the path) MOVES the
 * problem instead of fixing it: `clip_apply_effort_shape`'s caller wants
 * `notesTouched`, `phraseCount`, `minEffort`, `maxEffort` and the `air`
 * summary — a few hundred characters — and would now need a file read to get
 * them. So this module walks the reply and elides only the nodes that are
 * actually big, leaving every scalar and every short field inline. In the
 * common case the agent needs no file read at all.
 *
 * Under the threshold, `formatToolText` returns EXACTLY
 * `JSON.stringify(value, null, 2)` — byte-identical to the old behaviour, so
 * ~all of the 191 tools are untouched. `test/result-spill.test.ts` pins that
 * with a payload one character under the limit; a "spill everything" guard
 * fails it.
 *
 * ---------------------------------------------------------------------------
 * Where the elision line falls
 * ---------------------------------------------------------------------------
 * An oversized ARRAY is handled one of two ways, and picking wrong is the
 * whole design:
 *   • FEW-BUT-HUGE elements (a project snapshot's 8 tracks): recurse INTO the
 *     elements, so each track's `id`/`name`/`kind` survives inline and only
 *     the deep `notes[]`/`points[]` arrays inside them are replaced. Eliding
 *     at the outermost oversized node instead would return
 *     `{undone:"…", snapshot:{_elided:"array", elementCount:8}}` — a bare path
 *     with extra steps.
 *   • MANY-BUT-TINY elements (the 1,758 controller points): elide, with the
 *     element count, a head sample, a stride sample, and the exact line range
 *     to read in the spill file.
 *
 * The two knobs (`inlineMax`, `maxRecurseElements`) tighten over a fixed
 * ladder of PASSES until the rendered envelope fits. That is bounded work over
 * an already-measured tree, and it degrades in the right order: breadth first,
 * detail last.
 *
 * ---------------------------------------------------------------------------
 * Pagination — what it is and what it is NOT
 * ---------------------------------------------------------------------------
 * Index-exact access WITHOUT touching the file would need either a new MCP
 * tool (out of scope — the tool count is pinned at 191) or `detail`/`offset`
 * params on the Swift command (a separate later round). So this module ships
 * the two halves it can honestly deliver:
 *   • INLINE SAMPLES (head + stride) on every elided array, so "roughly what
 *     is in this lane" needs no read at all;
 *   • an exact `fileLineRange` per elided node, plus `linesPerElement` when
 *     every element occupies the same number of lines — which turns "points
 *     500..600" into a line-offset read of ONE region of the file rather than
 *     a 2 MB slurp. Agent file-reading tools take offset/limit in LINES, and
 *     the spill file is pretty-printed, so those line numbers are directly
 *     usable.
 *
 * ⭐ Line numbers are COMPUTED (a pure recursive function of the value that
 * mirrors `JSON.stringify(v, null, 2)`'s layout), never guessed — and then
 * CHECKED against the emitted text: the total line count must match, the start
 * line must carry the expected key/opening token, and the end line must be the
 * matching bracket. A wrong line number looks exactly like a right one, so a
 * range that fails its check is reported as `null` with a note, never as a
 * number.
 *
 * ---------------------------------------------------------------------------
 * Failing loudly
 * ---------------------------------------------------------------------------
 * If the spill file cannot be written, the reply still carries the digest (it
 * is the useful part) but its notice says `status: "ELIDED_NO_FILE"` and
 * states in words that the omitted content is NOT retrievable. `isError` stays
 * FALSE on purpose: the tool CALL succeeded — only the reporting of it failed.
 * Marking it an error would invite a retry, and a retried `edit_undo` undoes a
 * second edit. The notice tells the caller not to re-run.
 *
 * stdout is the stdio MCP transport wire: nothing in this module may ever
 * `console.log`.
 */

import { AsyncLocalStorage } from "node:async_hooks";
import { randomBytes } from "node:crypto";
import { mkdirSync, readdirSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/**
 * Replies at or under this many characters pass through untouched.
 *
 * 24,000 characters is roughly 6–8k tokens — big for a single tool result but
 * still readable, and it sits just above `mcp-log.ts`'s established 20,000-char
 * cap for logging a single value, so the two ceilings agree in spirit. It is
 * ~6x under the smaller of the two measured failures (146,744) and ~93x under
 * the larger (2,222,508), so both are caught with room to spare, while every
 * ordinary reply in this server (a track list, a transport status, an FX
 * chain) is orders of magnitude below it and is not affected at all.
 */
const DEFAULT_MAX_RESULT_CHARS = 24_000;

/** Env override, read at CALL time (not import time) so tests can set it. */
export function maxResultChars(): number {
  const raw = process.env["DAWPRO_MCP_MAX_RESULT_CHARS"];
  if (raw !== undefined && raw !== "") {
    const n = Number(raw);
    if (Number.isFinite(n) && n > 0) return Math.floor(n);
  }
  return DEFAULT_MAX_RESULT_CHARS;
}

/**
 * Where spill files go. NEVER inside the user's project tree: the default is
 * the OS temp directory (on macOS a per-user `/var/folders/.../T/` path), in a
 * dedicated subdirectory so the prune below can never touch anything else.
 */
export function spillDir(): string {
  const raw = process.env["DAWPRO_MCP_SPILL_DIR"];
  if (raw !== undefined && raw !== "") return raw;
  return join(tmpdir(), "dawpro-mcp-results");
}

/** Spill files older than this are pruned, best-effort, on the next spill. */
const SPILL_TTL_MS = 24 * 60 * 60 * 1000;

const SPILL_FILE_PREFIX = "dawpro-mcp-";
const SPILL_FILE_RE = /^dawpro-mcp-[A-Za-z0-9_.-]+\.(json|txt)$/;

/** How the digest degrades when the first attempt is still too big. */
interface Pass {
  /** Nodes whose compact JSON is at most this many chars stay inline verbatim. */
  inlineMax: number;
  /** Oversized arrays with at most this many elements are recursed into
   *  (few-but-huge); anything wider is elided with samples. */
  maxRecurseElements: number;
  /** How many leading elements to sample inline on an elided array. */
  headSamples: number;
  /** How many stride-spaced elements to sample inline on an elided array. */
  strideSamples: number;
  /** Char budget for OUTLINES — the scalar-only skeletons used when elements
   *  are individually too big to sample verbatim (see `outlineElements`). */
  outlineBudget: number;
}

const PASSES: readonly Pass[] = [
  { inlineMax: 4096, maxRecurseElements: 64, headSamples: 3, strideSamples: 4, outlineBudget: 1200 },
  { inlineMax: 2048, maxRecurseElements: 32, headSamples: 3, strideSamples: 4, outlineBudget: 1000 },
  { inlineMax: 1024, maxRecurseElements: 16, headSamples: 2, strideSamples: 3, outlineBudget: 700 },
  { inlineMax: 512, maxRecurseElements: 8, headSamples: 2, strideSamples: 2, outlineBudget: 400 },
  { inlineMax: 256, maxRecurseElements: 4, headSamples: 1, strideSamples: 1, outlineBudget: 200 },
  { inlineMax: 128, maxRecurseElements: 0, headSamples: 1, strideSamples: 0, outlineBudget: 0 },
];

/** An object wider than this is elided rather than recursed into, at any pass. */
const MAX_RECURSE_KEYS = 128;
/** A sampled element bigger than this is not worth inlining. */
const MAX_SAMPLE_ELEMENT_CHARS = 300;
/** Total inline sample budget per elided array. */
const MAX_SAMPLE_CHARS = 1200;
/** The notice's `elided` index is capped so it cannot itself overflow. */
const MAX_INDEX_ENTRIES = 50;
/** Guard against pathological nesting blowing the stack. */
const MAX_DEPTH = 200;
/** How much of an elided string to show inline. */
const STRING_PREVIEW_CHARS = 160;
/** A whole reply that IS one huge string (or an error message) shows more:
 *  for an error the actionable sentence is at the front, and cutting it at 160
 *  characters would hide the very thing the caller has to act on. */
const ROOT_STRING_PREVIEW_CHARS = 600;

// ---------------------------------------------------------------------------
// Which tool is running (for a distinguishable spill file name)
// ---------------------------------------------------------------------------

const toolNameStore = new AsyncLocalStorage<string>();

/**
 * Runs `fn` with `name` recorded as the tool currently executing, so a spill
 * file written deep inside it can be named after it. `mcp-log.ts` wraps every
 * one of the 191 registrations and is the only caller.
 */
export function runWithToolName<T>(name: string, fn: () => T): T {
  return toolNameStore.run(name, fn);
}

/** The tool whose handler is currently on the stack, if any. */
export function currentToolName(): string | undefined {
  return toolNameStore.getStore();
}

// ---------------------------------------------------------------------------
// JSON shape helpers — these must agree with JSON.stringify, not merely look
// like they do.
// ---------------------------------------------------------------------------

type Dict = Record<string, unknown>;

function isDict(v: unknown): v is Dict {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

/** `JSON.stringify` calls `toJSON()` first (Date, and anything else that has
 *  one), so the layout we compute has to see the same value it does. */
function normalize(node: unknown): unknown {
  if (node !== null && typeof node === "object") {
    const maybe = (node as { toJSON?: unknown }).toJSON;
    if (typeof maybe === "function") {
      try {
        return (maybe as (key?: string) => unknown).call(node, "");
      } catch {
        return node;
      }
    }
  }
  return node;
}

/** Own enumerable keys `JSON.stringify` will actually emit — it DROPS
 *  properties whose value is `undefined`, a function, or a symbol. */
function emittedKeys(obj: Dict): string[] {
  const out: string[] = [];
  for (const k of Object.keys(obj)) {
    const v = obj[k];
    if (v === undefined || typeof v === "function" || typeof v === "symbol") continue;
    out.push(k);
  }
  return out;
}

/** Array elements: `undefined`/function/symbol serialize as `null`. */
function arrayElement(v: unknown): unknown {
  if (v === undefined || typeof v === "function" || typeof v === "symbol") return null;
  return v;
}

/**
 * Size of `JSON.stringify(node)` (COMPACT, no indent), computed bottom-up and
 * memoized per node.
 *
 * Calling `JSON.stringify(node).length` at every node during the walk is
 * quadratic — on the 2.2 MB `edit_undo` case that reads as a hang. This is one
 * pass over the tree, reused across every degradation pass.
 */
class Sizer {
  private readonly memo = new WeakMap<object, number>();

  size(node: unknown, depth = 0): number {
    const v = normalize(node);
    if (v === null || v === undefined) return 4; // "null"
    switch (typeof v) {
      case "string":
        return JSON.stringify(v).length;
      case "number":
        return Number.isFinite(v) ? String(v).length : 4;
      case "boolean":
        return v ? 4 : 5;
      case "bigint":
      case "function":
      case "symbol":
        return 4;
    }
    if (depth > MAX_DEPTH) return 4;
    const obj = v as object;
    const hit = this.memo.get(obj);
    if (hit !== undefined) return hit;
    let n: number;
    if (Array.isArray(v)) {
      n = 2 + Math.max(0, v.length - 1);
      for (const el of v) n += this.size(arrayElement(el), depth + 1);
    } else {
      const keys = emittedKeys(v as Dict);
      n = 2 + Math.max(0, keys.length - 1);
      for (const k of keys) n += JSON.stringify(k).length + 1 + this.size((v as Dict)[k], depth + 1);
    }
    this.memo.set(obj, n);
    return n;
  }
}

/**
 * How many LINES `node` occupies in `JSON.stringify(value, null, 2)`.
 *
 * The layout rules this mirrors: a scalar is one line; `[]` and `{}` are one
 * line; a non-empty container is `[`/`{` on its own line, then its children,
 * then the closing bracket on its own line. An object property shares its
 * first line with its key (`"k": <first line of value>`), so a property
 * contributes exactly `lines(value)`.
 *
 * Depth overflow flips `overflowed`, which disables the whole line index —
 * reporting no ranges is correct; reporting wrong ones is not.
 */
class LineCounter {
  private readonly memo = new WeakMap<object, number>();
  overflowed = false;

  lines(node: unknown, depth = 0): number {
    const v = normalize(node);
    if (v === null || typeof v !== "object") return 1;
    if (depth > MAX_DEPTH) {
      this.overflowed = true;
      return 1;
    }
    const obj = v as object;
    const hit = this.memo.get(obj);
    if (hit !== undefined) return hit;
    let n: number;
    if (Array.isArray(v)) {
      if (v.length === 0) n = 1;
      else {
        n = 2;
        for (const el of v) n += this.lines(arrayElement(el), depth + 1);
      }
    } else {
      const keys = emittedKeys(v as Dict);
      if (keys.length === 0) n = 1;
      else {
        n = 2;
        for (const k of keys) n += this.lines((v as Dict)[k], depth + 1);
      }
    }
    this.memo.set(obj, n);
    return n;
  }
}

// ---------------------------------------------------------------------------
// Line-range verification — a computed range is not a verified one
// ---------------------------------------------------------------------------

type LineRange = [number, number];

interface RangeCheckContext {
  lines: readonly string[];
  enabled: boolean;
  failures: number;
}

/**
 * Confirms a computed `[start, end]` actually delimits `node` in the emitted
 * text: the start line must open the right token (and name the right key when
 * the node is a property value), and the end line must be the matching close.
 * Returns null — never a number — when the check does not hold.
 */
function verifiedRange(
  ctx: RangeCheckContext,
  start: number,
  end: number,
  node: unknown,
  key: string | undefined
): LineRange | null {
  if (!ctx.enabled) return null;
  if (start < 1 || end < start || end > ctx.lines.length) {
    ctx.failures += 1;
    return null;
  }
  const first = ctx.lines[start - 1];
  const last = ctx.lines[end - 1];
  if (first === undefined || last === undefined) {
    ctx.failures += 1;
    return null;
  }
  if (key !== undefined && !first.includes(`${JSON.stringify(key)}:`)) {
    ctx.failures += 1;
    return null;
  }
  const v = normalize(node);
  const isArr = Array.isArray(v);
  const isObj = isDict(v);
  if (isArr || isObj) {
    const open = isArr ? "[" : "{";
    const close = isArr ? "]" : "}";
    const emptyToken = isArr ? "[]" : "{}";
    const firstTrimmed = first.trimEnd();
    const lastTrimmed = last.trim();
    if (start === end) {
      // Empty container: rendered on one line as `[]` / `{}`.
      if (!firstTrimmed.endsWith(emptyToken) && !firstTrimmed.endsWith(`${emptyToken},`)) {
        ctx.failures += 1;
        return null;
      }
    } else {
      if (!firstTrimmed.endsWith(open)) {
        ctx.failures += 1;
        return null;
      }
      if (lastTrimmed !== close && lastTrimmed !== `${close},`) {
        ctx.failures += 1;
        return null;
      }
    }
  } else if (start !== end) {
    ctx.failures += 1;
    return null;
  }
  return [start, end];
}

// ---------------------------------------------------------------------------
// The digest walk
// ---------------------------------------------------------------------------

/** One entry of the notice's at-a-glance index of what was replaced. */
interface ElidedEntry {
  path: string;
  kind: "array" | "object" | "string";
  elementCount?: number;
  keyCount?: number;
  chars?: number;
  fileLineRange: LineRange | null;
}

interface WalkContext {
  pass: Pass;
  sizer: Sizer;
  liner: LineCounter;
  ranges: RangeCheckContext;
  elided: ElidedEntry[];
  /**
   * Whether the spill file actually got written. ⛔ When it did NOT, no
   * placeholder may hand out a line offset into it or tell the caller to read
   * it — a reply that says NOT RETRIEVABLE at the top and then publishes
   * "read lines 21 + N*815" is internally contradictory, and a contradictory
   * reply is exactly the looks-valid-but-isn't failure this guard exists to
   * stop. Kept SEPARATE from `ranges.enabled`, which means something else
   * entirely (the computed layout failed to verify against a file that does
   * exist).
   */
  fileAvailable: boolean;
}

function childStartLines(ctx: WalkContext, start: number, children: readonly unknown[]): number[] {
  // The container's own `[`/`{` sits on `start`; the first child begins on the
  // next line, and each subsequent child begins after the previous one's block.
  const out: number[] = [];
  let cursor = start + 1;
  for (const c of children) {
    out.push(cursor);
    cursor += ctx.liner.lines(c);
  }
  return out;
}

/** Inline samples that show what an elided array holds without a file read. */
function sampleArray(ctx: WalkContext, arr: readonly unknown[]): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  let budget = MAX_SAMPLE_CHARS;
  const take = (i: number): unknown | undefined => {
    const el = arrayElement(arr[i]);
    const sz = ctx.sizer.size(el);
    if (sz > MAX_SAMPLE_ELEMENT_CHARS || sz > budget) return undefined;
    budget -= sz;
    return el;
  };

  const head: unknown[] = [];
  for (let i = 0; i < Math.min(ctx.pass.headSamples, arr.length); i += 1) {
    const el = take(i);
    if (el === undefined) break;
    head.push(el);
  }
  if (head.length > 0) out["head"] = head;

  const strideCount = ctx.pass.strideSamples;
  if (strideCount > 0 && arr.length > head.length + 1) {
    const stride = Math.max(1, Math.floor(arr.length / (strideCount + 1)));
    const items: { index: number; value: unknown }[] = [];
    for (let n = 1; n <= strideCount; n += 1) {
      const idx = Math.min(arr.length - 1, n * stride);
      if (idx < head.length) continue;
      const el = take(idx);
      if (el === undefined) break;
      items.push({ index: idx, value: el });
    }
    if (items.length > 0) out["sampled"] = { stride, items };
  }

  if (head.length === 0 && out["sampled"] === undefined) {
    // ⭐ Elements individually too big to quote (a project snapshot's clips:
    // each carries hundreds of notes). Quoting none of them is what makes an
    // envelope a bare path with extra steps — the agent loses every clip id.
    // So fall back to an OUTLINE: each element reduced to its SCALAR fields,
    // with the containers it dropped named and counted. That is the identity
    // an agent needs to act (`id`, `name`, `startBeat`) at a few dozen chars
    // apiece, and it is marked partial so nothing looks complete that isn't.
    const outline = outlineElements(ctx, arr);
    if (outline !== null) out["outline"] = outline;
    else {
      const first = arrayElement(arr[0]);
      if (isDict(first)) out["elementKeys"] = Object.keys(first).slice(0, 40);
      else out["elementType"] = first === null ? "null" : typeof first;
    }
  }
  return out;
}

/** One element reduced to scalars; container fields become `"<array of N>"`
 *  markers so the outline can never be mistaken for the whole element. */
function outlineOf(ctx: WalkContext, el: unknown): unknown {
  const v = normalize(el);
  if (!isDict(v)) return undefined;
  const out: Dict = {};
  for (const k of emittedKeys(v)) {
    const child = normalize(v[k]);
    if (child === null || typeof child !== "object") {
      if (typeof child === "string" && child.length > 64) out[k] = `${child.slice(0, 64)}…`;
      else out[k] = child;
    } else if (Array.isArray(child)) {
      out[k] = `<array of ${child.length}, omitted>`;
    } else {
      out[k] = `<object, ${emittedKeys(child as Dict).length} keys, omitted>`;
    }
  }
  return Object.keys(out).length > 0 ? out : undefined;
}

interface Outline {
  note: string;
  covered: string;
  items: unknown[];
}

function outlineElements(ctx: WalkContext, arr: readonly unknown[]): Outline | null {
  let budget = ctx.pass.outlineBudget;
  if (budget <= 0 || arr.length === 0) return null;
  const items: unknown[] = [];
  for (let i = 0; i < arr.length; i += 1) {
    const o = outlineOf(ctx, arrayElement(arr[i]));
    if (o === undefined) break;
    const sz = ctx.sizer.size(o);
    if (sz > budget) break;
    budget -= sz;
    items.push(o);
  }
  if (items.length === 0) return null;
  return {
    note:
      "PARTIAL — each element reduced to its scalar fields; every array/object " +
      "field inside it was dropped and is marked as such. " +
      (ctx.fileAvailable
        ? "Read the file for full elements."
        : "The full elements were NOT saved anywhere — see the warning above."),
    covered: items.length === arr.length ? `all ${arr.length}` : `first ${items.length} of ${arr.length}`,
    items,
  };
}

function elideArray(
  ctx: WalkContext,
  arr: readonly unknown[],
  path: string,
  range: LineRange | null
): Dict {
  const approxChars = ctx.sizer.size(arr);
  ctx.elided.push({ path, kind: "array", elementCount: arr.length, fileLineRange: range });

  // Uniform elements make index-exact paging arithmetic possible.
  let linesPerElement: number | null = null;
  if (arr.length > 0) {
    const firstLines = ctx.liner.lines(arrayElement(arr[0]));
    linesPerElement = firstLines;
    for (let i = 1; i < arr.length; i += 1) {
      if (ctx.liner.lines(arrayElement(arr[i])) !== firstLines) {
        linesPerElement = null;
        break;
      }
    }
  }

  const out: Dict = {
    _elided: "array",
    elementCount: arr.length,
    approxChars,
    path,
    fileLineRange: range,
  };
  if (range !== null && linesPerElement !== null) {
    out["linesPerElement"] = linesPerElement;
    out["readElements"] =
      `To read elements N..M from the spill file: read lines ` +
      `${range[0] + 1} + N*${linesPerElement} through ${range[0]} + (M+1)*${linesPerElement} ` +
      `(1-based, inclusive). Element 0 starts at line ${range[0] + 1}.`;
  }
  Object.assign(out, sampleArray(ctx, arr));
  return out;
}

function elideObject(ctx: WalkContext, obj: Dict, path: string, range: LineRange | null): Dict {
  const keys = emittedKeys(obj);
  ctx.elided.push({ path, kind: "object", keyCount: keys.length, fileLineRange: range });
  return {
    _elided: "object",
    keyCount: keys.length,
    keys: keys.slice(0, 40),
    approxChars: ctx.sizer.size(obj),
    path,
    fileLineRange: range,
  };
}

function elideString(ctx: WalkContext, s: string, path: string, range: LineRange | null): Dict {
  ctx.elided.push({ path, kind: "string", chars: s.length, fileLineRange: range });
  return {
    _elided: "string",
    chars: s.length,
    preview: `${s.slice(0, STRING_PREVIEW_CHARS)}${s.length > STRING_PREVIEW_CHARS ? "…" : ""}`,
    path,
    fileLineRange: range,
  };
}

/**
 * Returns `node` itself when it is small enough to keep verbatim, otherwise a
 * structure with the same shape whose oversized parts are placeholders.
 *
 * `start` is the 1-based line in the spill file where this node begins;
 * `key` is the property name that introduced it (used to verify the range).
 */
function digest(
  ctx: WalkContext,
  node: unknown,
  path: string,
  start: number,
  key: string | undefined,
  depth: number
): unknown {
  const v = normalize(node);
  if (ctx.sizer.size(v) <= ctx.pass.inlineMax) return node;
  if (depth > MAX_DEPTH) return node;

  // No file written => no line offsets into it, at all. (See `fileAvailable`.)
  const range = ctx.fileAvailable
    ? verifiedRange(ctx.ranges, start, start + ctx.liner.lines(v) - 1, v, key)
    : null;

  /**
   * A placeholder that is BIGGER than what it replaces is strictly worse than
   * the content: it costs more context AND says less. That can happen for a
   * medium-sized node (a 300-char string becomes `_elided` + `chars` +
   * `preview` + `path` + `fileLineRange`), so every substitution below is
   * measured against the original and abandoned if it does not shrink.
   */
  const shrinkOrKeep = (make: () => Dict): unknown => {
    const before = ctx.elided.length;
    const placeholder = make();
    if (ctx.sizer.size(placeholder) < ctx.sizer.size(v)) return placeholder;
    ctx.elided.length = before; // un-index the node we are not replacing
    return node;
  };

  if (typeof v === "string") return shrinkOrKeep(() => elideString(ctx, v, path, range));

  if (Array.isArray(v)) {
    if (v.length > 0 && v.length <= ctx.pass.maxRecurseElements) {
      const elements = v.map(arrayElement);
      const starts = childStartLines(ctx, start, elements);
      return elements.map((el, i) =>
        digest(ctx, el, `${path}[${i}]`, starts[i] ?? start, undefined, depth + 1)
      );
    }
    return shrinkOrKeep(() => elideArray(ctx, v, path, range));
  }

  if (isDict(v)) {
    const keys = emittedKeys(v);
    if (keys.length > 0 && keys.length <= MAX_RECURSE_KEYS) {
      const values = keys.map((k) => v[k]);
      const starts = childStartLines(ctx, start, values);
      const out: Dict = {};
      keys.forEach((k, i) => {
        out[k] = digest(ctx, v[k], `${path}.${k}`, starts[i] ?? start, k, depth + 1);
      });
      return out;
    }
    return shrinkOrKeep(() => elideObject(ctx, v, path, range));
  }

  return node;
}

// ---------------------------------------------------------------------------
// Spill file
// ---------------------------------------------------------------------------

function sanitizeToolName(name: string | undefined): string {
  if (!name) return "tool";
  const cleaned = name.replace(/[^A-Za-z0-9_-]/g, "-").slice(0, 60);
  return cleaned.length > 0 ? cleaned : "tool";
}

function spillFileName(extension: "json" | "txt"): string {
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const salt = randomBytes(3).toString("hex");
  return `${SPILL_FILE_PREFIX}${sanitizeToolName(currentToolName())}-${stamp}-${salt}.${extension}`;
}

/** Best-effort removal of our OWN stale spill files. Never looks outside
 *  `spillDir()`, never touches a name that is not ours. */
function pruneStaleSpills(dir: string): void {
  try {
    const now = Date.now();
    for (const name of readdirSync(dir)) {
      if (!SPILL_FILE_RE.test(name)) continue;
      const full = join(dir, name);
      try {
        const st = statSync(full);
        if (st.isFile() && now - st.mtimeMs > SPILL_TTL_MS) unlinkSync(full);
      } catch {
        /* a file that vanished or is unreadable is not our problem */
      }
    }
  } catch {
    /* pruning is never worth failing a reply over */
  }
}

interface SpillOutcome {
  path: string | null;
  bytes: number | null;
  error: string | null;
}

function writeSpill(body: string, extension: "json" | "txt"): SpillOutcome {
  const dir = spillDir();
  try {
    mkdirSync(dir, { recursive: true });
    pruneStaleSpills(dir);
    const path = join(dir, spillFileName(extension));
    writeFileSync(path, body, "utf8");
    return { path, bytes: Buffer.byteLength(body, "utf8"), error: null };
  } catch (err) {
    return { path: null, bytes: null, error: err instanceof Error ? err.message : String(err) };
  }
}

// ---------------------------------------------------------------------------
// The notice
// ---------------------------------------------------------------------------

const DO_NOT_RERUN =
  "DO NOT re-run this tool call to recover the omitted content: the call ALREADY " +
  "SUCCEEDED, and re-running a mutating tool (edit_undo, clip_apply_effort_shape, …) " +
  "repeats the edit.";

function buildNotice(args: {
  fullChars: number;
  fullLines: number;
  limit: number;
  spill: SpillOutcome;
  elided: ElidedEntry[];
  lineRangesVerified: boolean;
  kind: "json" | "string";
}): Dict {
  const { fullChars, fullLines, limit, spill, elided, lineRangesVerified, kind } = args;
  const notice: Dict = {
    status: spill.path ? "ELIDED_TO_FILE" : "ELIDED_NO_FILE",
    reason:
      `This reply was ${fullChars} characters (${fullLines} lines) — over the ` +
      `${limit}-character inline limit. THIS IS NOT THE COMPLETE REPLY. ` +
      (kind === "json"
        ? "Every scalar and short field is inline below, unchanged; only oversized " +
          'nodes were replaced, each by a placeholder object carrying "_elided", its ' +
          "element/key count, and where to read it."
        : "The reply was a single large text value."),
    fullChars,
    fullLines,
    inlineLimit: limit,
  };

  if (spill.path) {
    notice["file"] = spill.path;
    notice["fileBytes"] = spill.bytes;
    notice["howToRead"] =
      `The COMPLETE reply was written to the file above. Read it with your ` +
      `file-reading tool (Read, cat, …) — it is ${kind === "json" ? "pretty-printed JSON" : "plain text"}, ` +
      `${fullLines} lines. Read only the line range you need (see fileLineRange on each ` +
      `placeholder) rather than the whole file. ${DO_NOT_RERUN}`;
  } else {
    notice["file"] = null;
    notice["writeError"] = spill.error;
    notice["warning"] =
      "THE OMITTED CONTENT IS NOT RETRIEVABLE. The spill file could not be written " +
      `(${spill.error ?? "unknown error"}), so the elided nodes below exist nowhere else. ` +
      "Work from the inline fields, or re-read the state with a READ-ONLY tool " +
      `(project_snapshot, clip_get_notes, controller_lane_get). ${DO_NOT_RERUN}`;
  }

  if (kind === "json") {
    // Only claim anything about line ranges when there IS a file to index.
    if (spill.path) notice["lineRangesVerified"] = lineRangesVerified;
    if (spill.path && !lineRangesVerified) {
      notice["lineRangeNote"] =
        "Computed line ranges did not verify against the emitted file, so all " +
        "fileLineRange values are null. The file content itself is complete and correct; " +
        "only the line-offset shortcut is unavailable — search the file for the path instead.";
    }
    notice["elidedCount"] = elided.length;
    notice["elided"] = elided.slice(0, MAX_INDEX_ENTRIES);
    if (elided.length > MAX_INDEX_ENTRIES) {
      notice["elidedIndexTruncated"] = elided.length - MAX_INDEX_ENTRIES;
    }
  }
  return notice;
}

/** Puts the notice FIRST so it is the first thing in the rendered text, and
 *  keeps the caller's own top-level keys where the tool's docs say they are. */
function envelope(notice: Dict, body: unknown): unknown {
  if (isDict(body) && !("_elided" in body)) return { _elided: notice, ...body };
  return { _elided: notice, result: body };
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/**
 * The single serialization seam for MCP tool replies. Under the limit this is
 * exactly `JSON.stringify(value, null, 2)`.
 */
export function formatToolText(value: unknown): string {
  if (value === undefined) return "ok";

  const limit = maxResultChars();

  if (typeof value === "string") {
    if (value.length <= limit) return value;
    const spill = writeSpill(value, "txt");
    const notice = buildNotice({
      fullChars: value.length,
      fullLines: value.split("\n").length,
      limit,
      spill,
      elided: [],
      lineRangesVerified: false,
      kind: "string",
    });
    notice["preview"] = `${value.slice(0, ROOT_STRING_PREVIEW_CHARS)}…`;
    return JSON.stringify({ _elided: notice }, null, 2);
  }

  // A throw here (circular structure, BigInt) propagates to `toToolResult`'s
  // catch and becomes a structured tool error, exactly as before this guard.
  const full = JSON.stringify(value, null, 2);
  if (full === undefined) return "ok"; // e.g. a bare function/symbol
  if (full.length <= limit) return full;

  const lines = full.split("\n");
  const sizer = new Sizer();
  const liner = new LineCounter();

  // ⭐ Global positive control on the whole line index: if our computed layout
  // does not reproduce the emitted line count, every range we would report is
  // suspect, so we report none.
  const computedTotal = liner.lines(value);
  const lineIndexOk = !liner.overflowed && computedTotal === lines.length;
  const ranges: RangeCheckContext = { lines, enabled: lineIndexOk, failures: 0 };

  const spill = writeSpill(full, "json");

  let rendered: string | null = null;
  let notice: Dict | null = null;
  for (const pass of PASSES) {
    ranges.failures = 0;
    const ctx: WalkContext = {
      pass,
      sizer,
      liner,
      ranges,
      elided: [],
      fileAvailable: spill.path !== null,
    };
    const body = digest(ctx, value, "$", 1, undefined, 0);
    const candidateNotice = buildNotice({
      fullChars: full.length,
      fullLines: lines.length,
      limit,
      spill,
      elided: ctx.elided,
      lineRangesVerified: lineIndexOk && ranges.failures === 0,
      kind: "json",
    });
    const text = JSON.stringify(envelope(candidateNotice, body), null, 2);
    if (text.length <= limit) {
      rendered = text;
      notice = candidateNotice;
      break;
    }
    rendered = text;
    notice = candidateNotice;
  }

  if (rendered !== null && rendered.length <= limit) return rendered;

  // Last resort: even the tightest digest overflowed. Say so plainly rather
  // than returning a payload that looks complete.
  const fallbackNotice = notice ?? {};
  fallbackNotice["status"] = spill.path ? "ELIDED_TO_FILE_SUMMARY_ONLY" : "ELIDED_NO_FILE";
  fallbackNotice["summaryOnly"] =
    "Even the field-by-field summary exceeded the inline limit, so only this " +
    "notice is returned. Read the file for anything you need.";
  fallbackNotice["elided"] = [];
  const topLevelKeys = isDict(value)
    ? emittedKeys(value).slice(0, 100)
    : Array.isArray(value)
      ? [`<array of ${value.length}>`]
      : [];
  return JSON.stringify({ _elided: fallbackNotice, topLevelKeys }, null, 2);
}
