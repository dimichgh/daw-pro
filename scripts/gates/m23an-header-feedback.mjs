// m23-an GATE — A TRACK-HEADER CLICK THAT LANDS AND DRAWS NOTHING NOW SAYS SO,
// and — the half that is actually hard — a click that draws PLENTY still says
// nothing. Against a REAL app on staging (port 17695 ONLY; 17600 is the user's
// LIVE app and is never touched. Staging is killed PIDFILE-EXACT, never
// pkill/pgrep — at start AND at exit).
//
// IT BUILDS AND LAUNCHES ITS OWN BINARY (the m23-x/m23-am/m23-ak pattern), so
// the thing under test has KNOWN PROVENANCE. A gate that drives whatever
// instance happens to be on the port can pass against code that is minutes or
// days old, and it cannot tell you that it did (m23-ac).
//
// ══ THE ITEM AS FILED UNDERSTATED IT, AND THAT WAS MEASURED FIRST ═══════════
// m23-an says a ⇧ click on a zero-clip header "gives the user ZERO feedback"
// because the `.noClips` branch draws nothing, so the click "reads as if it did
// not register". Measured live before any code changed
// (`scripts/gates/_m23an-feedback-probe.mjs`) the premise HOLDS — and two things
// around it do not:
//
//   • THE CLICK IS NOT INERT (probe leg D4). It bumps `keyFocusNonce`, and with
//     the piano roll holding the zoom surface it flips `activeEditorSurface`
//     pianoRoll -> arrange. So it silently retargets ⌘+/⌘−/⌘0 (m23-al-1) and
//     moves where DELETE lands. It did not fail to register; it registered and
//     changed what the NEXT KEYSTROKE DOES, while showing nothing. That is why
//     the fix is to SURFACE the click, never to suppress the side effects — leg
//     E below pins that they survive.
//   • THE DEFECT SPANS TWO BRANCHES, not one (probe leg D2). A PLAIN click on a
//     zero-clip header with the selection already empty is `effect: "replace"`,
//     not `.noClips`, and it is equally silent. A predicate written as
//     `effect == .noClips` — the filing's own framing — goes green on the filed
//     case and misses this one entirely.
//
// ══ WHAT THIS GATE PROVES ══════════════════════════════════════════════════
//   • SOURCE (S): the sentence the user reads lives in ONE place and matches
//     docs/DESIGN-LANGUAGE.md verbatim. A gate carrying its own literal would go
//     green against a source that had changed under it (the m23-ah rule).
//   • CONTROL (C): the seam really answers with the new fields, and a click on a
//     POPULATED header is loud and unacknowledged. Without this, every null
//     result below is indistinguishable from a probe reading `undefined`.
//   • THE PREDICATE (D): all five measured rows, through the SAME
//     `AppModel.clickTrack` the `TrackRow` tap runs.
//   • ⚠️ THE MUTANT LEG (D1). The obvious wrong fix is "acknowledge on any
//     empty-track click" — i.e. drop the `!changedSelection` term. Under it, a
//     plain click that CLEARS a real selection and CLOSES the piano roll would
//     wear a "nothing to select" chip on top of the biggest visible change this
//     surface has. **D1 therefore asserts the ABSENCE of the acknowledgement,
//     not merely that the selection cleared.** A gate that only proved the word
//     appears where it should would be testing plumbing, not the rule.
//   • SIDE EFFECTS (E): the nonce bump and the surface engage SURVIVE on the
//     acknowledged click. The prohibition, machine-checked.
//   • DECAY (T): the word is TRANSIENT, and a click that selects something takes
//     it down at once. An acknowledgement that never left would read as state.
//   • PIXELS (P): ink actually appears and actually goes away, byte-exactly.
//     Per the empty-lane-hint law (DESIGN-LANGUAGE, m23-v): a build that keeps
//     the value and the echo but draws nothing leaves every headless test and
//     every echo leg GREEN. Only pixels catch it.
//
// ══ WHY D1's PRE-STATE IS ASSERTED AND NOT ASSUMED ═════════════════════════
// D1 is an ABSENCE leg, so it is only meaningful if no acknowledgement was
// standing when it ran — a leftover from an earlier leg would make it fail for
// the wrong reason, and (worse, under a mutant) a leftover that happened to be
// cleared would make it pass for the wrong reason. It is therefore preceded by a
// click on a POPULATED header (which clears) and the null pre-state is a CHECK.
// A failed precondition that certifies its dependents is the m23-bl trap.
//
// ══ THE PIXEL PROTOCOL, and the assumption it rests on ═════════════════════
// The resting image is captured AFTER a first identical click has expired, not
// before it — so the "rest" and "word standing" frames differ in the chip and in
// NOTHING ELSE. `keyFocusNonce` is a counter and draws nothing; `engage` is
// change-guarded, so the second click is a no-op there; the surface is asserted
// to be `arrange` and the selection empty on BOTH sides (leg P0). Without that,
// a first click that flips the surface and a second that does not would differ
// in whatever a surface change draws, and the pixel legs would be measuring it.
//
// Setup: none — run it.
//
//   node scripts/gates/m23an-header-feedback.mjs
import fs from "fs";
import zlib from "zlib";
import { execFileSync } from "child_process";
import { buildOrAbort, startStaging, stopStaging } from "./_staging.mjs";

const GATE = "m23an";
const PORT = process.env.DAW_CONTROL_PORT || "17695";
const OUT = process.env.M23AN_OUT || "/tmp/m23an";
const PIDFILE = process.env.M23AN_PIDFILE || "/tmp/m23an-staging.pid";
const BINARY = process.env.M23AN_BINARY || ".build/debug/DAWApp";
const REPO = process.env.M23AN_REPO || process.cwd();
const COPY_SRC = `${REPO}/Sources/DAWApp/TrackListView.swift`;
const DOC_SRC = `${REPO}/docs/DESIGN-LANGUAGE.md`;
fs.mkdirSync(OUT, { recursive: true });

const killer = setTimeout(() => { console.error("TIMEOUT"); process.exit(2); }, 600_000);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Fixture: FOUR tracks. The acknowledged one is at index 2 — not 0 and not last
// — so "the word appeared on the right row" is a real assertion rather than a
// coincidence an off-by-one or a `first` would also satisfy.
const I_FULL = 0, I_TARGET = 2;
const N_CLIPS = 3;
const LEN = 4;

// ── build FIRST: a gate that tests the previous binary proves nothing ───────
buildOrAbort({ root: REPO });

async function connect() {
  for (let i = 0; i < 60; i++) {
    try {
      const ws = new WebSocket(`ws://127.0.0.1:${PORT}`);
      await new Promise((res, rej) => { ws.onopen = res; ws.onerror = () => rej(new Error("x")); });
      let nextId = 1; const pending = new Map();
      ws.onmessage = (ev) => {
        let m; try { m = JSON.parse(ev.data); } catch { return; }
        const e = pending.get(m.id); if (!e) return; pending.delete(m.id);
        if (m.ok === false || m.error) e.reject(new Error(`${e.command}: ${JSON.stringify(m.error)}`));
        else e.resolve(m.result ?? m);
      };
      const req = (command, params = {}) => {
        const id = String(nextId++);
        return new Promise((resolve, reject) => {
          pending.set(id, { resolve, reject, command });
          ws.send(JSON.stringify({ id, command, params }));
          setTimeout(() => {
            if (pending.has(id)) { pending.delete(id); reject(new Error(`timeout ${command}`)); }
          }, 25000);
        });
      };
      return { ws, req };
    } catch { await sleep(500); }
  }
  throw new Error("no connect");
}

const staging = startStaging({
  gate: GATE, root: REPO, port: PORT, binary: BINARY,
  detached: true, pidfile: PIDFILE, outDir: OUT,
});
console.log(`staging pid ${staging.pid} on :${PORT}`);
await sleep(4500);

const { ws, req } = await connect();
const checks = [];
const check = (name, ok, detail) => {
  checks.push({ name, ok, detail });
  console.log(`  ${ok ? "ok  " : "!!  "} ${name}\n        ${detail}`);
};
const skips = [];
const skip = (name, why) => { skips.push({ name, why }); console.log(`  --  SKIP ${name}\n        ${why}`); };
const short = (s) => (typeof s === "string" ? s.slice(0, 8) : String(s));

const teardown = () => { try { stopStaging(GATE, PIDFILE); } catch {} };
for (const ev of ["uncaughtException", "unhandledRejection"]) {
  process.on(ev, (e) => { console.error(`${ev}:`, e && e.message); teardown(); process.exit(2); });
}

const sel = (p = {}) => req("debug.arrangeSelection", p);

/** Selection STATE, normalised so two reads compare as one string (the probe's). */
function snap(s) {
  if (!Array.isArray(s.selectedIds)) throw new Error("seam has no selectedIds array");
  const ids = s.selectedIds.slice().sort();
  return {
    n: ids.length, ids: ids.map(short).join(","),
    focus: short(s.focusClipId ?? null), open: short(s.editorClipId ?? null),
    nonce: s.keyFocusNonce, surface: s.activeEditorSurface,
    ack: s.trackClickAck ?? null, ackTrack: s.trackClickAckTrackId ?? null,
  };
}
const same = (a, b) => a.n === b.n && a.ids === b.ids && a.focus === b.focus && a.open === b.open;

let capSeq = 0;
async function capture(tag) {
  const path = `${OUT}/${tag}-${capSeq++}.png`;
  const r = await req("debug.captureUI", { path });
  return { path, width: r.width, height: r.height, sha: shaOf(path) };
}
function shaOf(p) {
  return execFileSync("/usr/bin/shasum", ["-a", "256", p]).toString().split(" ")[0];
}
/// A STABLE capture: two consecutive byte-identical frames (the m23-g3 law — a
/// single unlucky pair can make a pixel leg meaningless). Failing to stabilise is
/// a FAILURE, never a skip (the m23-ah rule).
async function stableCapture(tag) {
  let prev = await capture(tag);
  for (let i = 0; i < 12; i++) {
    await sleep(150);
    const next = await capture(tag);
    if (next.sha === prev.sha) return next;
    prev = next;
  }
  return null;
}

// ══ WHERE DID IT LAND? — a PNG reader, because no seam can answer this ═══════
// The chip carries no `.explainable` tag (it must not hit-test), so the only
// instrument that can say WHERE it was drawn is the frame itself. `zlib` is in
// the standard library; the captures are 8-bit non-interlaced RGBA.
//
// This exists because build 1 SHIPPED THE WRONG ANSWER and every non-pixel leg
// certified it: the chip hung 2 pt below the row and its body landed across the
// NEXT row, so the app named track i in the seam and blamed track i+1 on screen
// (the m23-am defect). P5 below is that bug, written as an assertion.
function readPNG(path) {
  const d = fs.readFileSync(path);
  let i = 8, idat = [], w = 0, h = 0, color = 6;
  while (i < d.length) {
    const ln = d.readUInt32BE(i), typ = d.toString("ascii", i + 4, i + 8);
    if (typ === "IHDR") {
      w = d.readUInt32BE(i + 8); h = d.readUInt32BE(i + 12);
      if (d[i + 16] !== 8 || d[i + 20] !== 0) throw new Error("unexpected PNG form");
      color = d[i + 17];
    } else if (typ === "IDAT") idat.push(d.subarray(i + 8, i + 8 + ln));
    else if (typ === "IEND") break;
    i += 12 + ln;
  }
  const bpp = { 0: 1, 2: 3, 4: 2, 6: 4 }[color];
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const stride = w * bpp, out = Buffer.alloc(h * stride);
  let pos = 0;
  for (let y = 0; y < h; y++) {
    const f = raw[pos++], o = y * stride, p = o - stride;
    for (let x = 0; x < stride; x++) {
      const a = x >= bpp ? out[o + x - bpp] : 0;
      const b = y ? out[p + x] : 0;
      const c = (y && x >= bpp) ? out[p + x - bpp] : 0;
      let v = raw[pos + x];
      if (f === 1) v += a;
      else if (f === 2) v += b;
      else if (f === 3) v += (a + b) >> 1;
      else if (f === 4) {
        const pp = a + b - c, pa = Math.abs(pp - a), pb = Math.abs(pp - b), pc = Math.abs(pp - c);
        v += (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c);
      } else if (f !== 0) throw new Error(`filter ${f}`);
      out[o + x] = v & 0xFF;
    }
    pos += stride;
  }
  return { w, h, bpp, data: out };
}
/** Bounding box of the pixels where two same-size frames differ, or null. */
function diffBox(pathA, pathB) {
  const A = readPNG(pathA), B = readPNG(pathB);
  if (A.w !== B.w || A.h !== B.h) throw new Error("frame size changed mid-gate");
  const stride = A.w * A.bpp;
  let minX = A.w, minY = A.h, maxX = -1, maxY = -1, n = 0;
  for (let y = 0; y < A.h; y++) {
    const o = y * stride;
    if (A.data.compare(B.data, o, o + stride, o, o + stride) === 0) continue;
    for (let x = 0; x < A.w; x++) {
      const p = o + x * A.bpp;
      if (A.data.compare(B.data, p, p + A.bpp, p, p + A.bpp) !== 0) {
        n++;
        if (x < minX) minX = x; if (x > maxX) maxX = x;
        if (y < minY) minY = y; if (y > maxY) maxY = y;
      }
    }
  }
  return maxY < 0 ? null : { minX, minY, maxX, maxY, n };
}
const overlapsY = (a, b) => a && b && a.minY <= b.maxY && b.minY <= a.maxY;
const boxStr = (b) => (b ? `y=${b.minY}..${b.maxY} x=${b.minX}..${b.maxX} px=${b.n}` : "(no ink)");

/**
 * Capture repeatedly until the frame actually DIFFERS from `base`, or give up.
 *
 * ⚠️ MEASURED, not defensive: a single capture 400 ms after the click came back
 * byte-identical to the resting frame in roughly one run in three — the window
 * had not redrawn yet — which reads EXACTLY like "the feature drew nothing".
 * Polling waits for the DRAW, not for a pass: if the frame never changes within
 * the chip's 3 s life, this returns null and the leg fails, which is the correct
 * verdict for a build that really does draw nothing.
 */
async function captureWhenChanged(tag, base, refresh = null, tries = 10) {
  let shot = await capture(tag);
  for (let i = 0; i < tries && shot.sha === base.sha; i++) {
    // ⚠️ RE-CLICK, don't just wait. `debug.captureUI` costs enough that a
    // dozen polls outlive the chip's 3 s window: the first version drifted past
    // the expiry and then reported "the frame never changed", which is the
    // draws-nothing verdict — arrived at by TIMING rather than by drawing. The
    // refresh is the SAME seam click the leg is about, and on an empty track
    // with an empty selection it is a genuine no-op (`effect: "replace"`,
    // `changedSelection: false`), so it restarts the word without touching
    // anything the leg measures.
    if (refresh) await refresh();
    await sleep(120);
    shot = await capture(tag);
  }
  return shot.sha === base.sha ? null : shot;
}

/** The y-band of a row, MEASURED: toggle its mute and see which pixels move. */
async function rowBand(trackId, rest, tag) {
  await req("track.setMute", { trackId, muted: true });
  await sleep(300);
  const on = await stableCapture(tag);
  await req("track.setMute", { trackId, muted: false });
  await sleep(300);
  return on ? diffBox(rest.path, on.path) : null;
}

try {
  // ══ S — THE COPY, READ FROM THE SOURCE OF TRUTH ════════════════════════════
  console.log("\n── S: the sentence lives in ONE place ──");
  const src = fs.readFileSync(COPY_SRC, "utf8");
  const hits = src.match(/static let noClipsToSelectNotice = "([^"]*)"/g) ?? [];
  const COPY = hits.length === 1
    ? src.match(/static let noClipsToSelectNotice = "([^"]*)"/)[1] : null;
  check("S1 the copy is READ FROM SOURCE (TrackListView.noClipsToSelectNotice), matched "
        + "EXACTLY ONCE — a copy change re-aims this gate instead of leaving it asserting "
        + "a stale literal",
        hits.length === 1 && !!COPY && COPY.length > 8,
        `matches=${hits.length} copy=${JSON.stringify(COPY)}`);
  if (!COPY) throw new Error("could not read the pinned copy from source");

  const doc = fs.readFileSync(DOC_SRC, "utf8");
  const docHits = doc.split(COPY).length - 1;
  check("S2 docs/DESIGN-LANGUAGE.md carries that sentence VERBATIM, exactly once — the "
        + "design contract and the shipped string cannot drift apart silently",
        docHits === 1, `occurrences in DESIGN-LANGUAGE.md = ${docHits}`);

  // The register, asserted at the source. Amber IS this app's refusal ink
  // (`ArrangeRefusalBubble`, `deleteBarBlockedReason`) and nothing was refused
  // here; the chip must not wear it, and must not glow.
  // ⚠️ Anchored FORWARD from the declaration, never between two named members:
  // the first version sliced to `private func partingOffset`, and when the chip
  // moved from `TrackRowsList` into `TrackRow` that name ended up EARLIER in the
  // file — a backwards slice, which is the empty string, which passes an
  // `!includes(accent)` test while failing the `includes(textSecondary)` one for
  // a reason that has nothing to do with colour.
  const b0 = src.indexOf("private var trackClickAckBubble");
  const bubbleSrc = b0 < 0 ? "" : src.slice(b0, src.indexOf("var body: some View {", b0));
  check("S3 the chip's REGISTER is neutral at the source: textSecondary ink, no accent "
        + "token, no .glow — amber is the refusal register and nothing was refused",
        bubbleSrc.length > 200
          && bubbleSrc.includes("DAWTheme.textSecondary")
          && !/DAWTheme\.(record|playback|signal|clip|ai)\b/.test(bubbleSrc)
          && !/\.glow\(/.test(bubbleSrc),
        `slice=${bubbleSrc.length}B textSecondary=${bubbleSrc.includes("DAWTheme.textSecondary")} `
        + `accentToken=${/DAWTheme\.(record|playback|signal|clip|ai)\b/.test(bubbleSrc)} `
        + `glow=${/\.glow\(/.test(bubbleSrc)}`);

  // S4 — the chip must be a CHILD of the row it names, not a free-floating
  // overlay positioned by arithmetic. This is the structural form of the bug
  // measured at build 1 (see P4/P5): with `row.overlay`, "drawn on the wrong
  // row" is not expressible; with `ladder.tops[index]` it is one sign error away.
  check("S4 the chip is drawn as an overlay ON THE ROW ITSELF (`row.overlay`), and reads "
        + "NO row-position arithmetic — correct attribution is structural, not computed",
        /row\.overlay\(alignment: \.trailing\) \{ trackClickAckBubble \}/.test(src)
          && !/ladder\.(tops|heights)\[[^\]]*\][^\n]*ackChip/.test(src)
          && !bubbleSrc.includes("ladder."),
        `rowOverlay=${/row\.overlay\(alignment: \.trailing\) \{ trackClickAckBubble \}/.test(src)} `
        + `bubbleReadsLadder=${bubbleSrc.includes("ladder.")}`);

  // ══ FIXTURE ════════════════════════════════════════════════════════════════
  await req("project.new", { discardChanges: true });
  const ids = [];
  for (const name of ["AN-FULL", "AN-EMPTY-1", "AN-TARGET", "AN-EMPTY-3"]) {
    ids.push((await req("track.add", { name, kind: "instrument" })).id);
  }
  const tFull = ids[I_FULL], tTarget = ids[I_TARGET];
  for (let i = 0; i < N_CLIPS; i++) {
    // ⚠️ `atBeat`, NOT `startBeat` — the standing trap.
    await req("clip.addMIDI", { trackId: tFull, atBeat: i * LEN, lengthBeats: LEN });
  }
  const ov = await req("project.overview", {});
  const counts = (ov.tracks ?? []).map((t) => (t.clips ?? []).length);
  console.log(`\nfixture clipCounts=${JSON.stringify(counts)}  target=${short(tTarget)} (index ${I_TARGET})`);

  // ══ C — CONTROL ════════════════════════════════════════════════════════════
  console.log("\n── C: the instrument can see a change, and knows the new field names ──");
  const shape = await sel({});
  check("C1 the seam answers with the m23-an fields — a probe that guesses a name reads "
        + "undefined and reports EXACTLY like a measurement that found nothing",
        Object.hasOwn(shape, "trackClickAck") && Object.hasOwn(shape, "trackClickAckTrackId"),
        `keys: ${Object.keys(shape).filter((k) => k.startsWith("trackClick")).join(" ") || "(none)"}`);

  check("C2 the FIXTURE is 3 clips / 0 clips on the two tracks under test",
        counts[I_FULL] === N_CLIPS && counts[I_TARGET] === 0,
        `counts=${JSON.stringify(counts)}`);

  await sel({ act: "clear" });
  const bC = snap(await sel({}));
  const rC = await sel({ act: "clickTrack", trackId: tFull, shift: true });
  const aC = snap(rC);
  check("C3 (probe D5) ⇧ on a 3-clip header is LOUD and takes NO acknowledgement — the "
        + "control that makes every null below mean something",
        aC.n === N_CLIPS && !same(bC, aC) && aC.ack === null
          && rC.trackClickChangedSelection === true,
        `n ${bC.n}->${aC.n} effect=${rC.trackClickEffect} `
        + `changed=${rC.trackClickChangedSelection} ack=${JSON.stringify(aC.ack)}`);

  // ══ D — THE PREDICATE, five measured rows ══════════════════════════════════
  console.log("\n── D: the predicate, on the rows it was fitted to ──");

  // D3 — the FILED case: ⇧ on a zero-clip header.
  const b3 = snap(await sel({}));
  const r3 = await sel({ act: "clickTrack", trackId: tTarget, shift: true });
  const a3 = snap(r3);
  check("D3 ⇧ on a 0-clip header: selection byte-identical, effect \"no-clips\", and the "
        + "row IS acknowledged",
        same(b3, a3) && r3.trackClickEffect === "no-clips"
          && r3.trackClickChangedSelection === false
          && a3.ack === "no-clips-to-select",
        `effect=${r3.trackClickEffect} changed=${r3.trackClickChangedSelection} `
        + `n ${b3.n}->${a3.n} ack=${JSON.stringify(a3.ack)}`);

  check("D3b the word is hung on THE ROW THAT WAS CLICKED (index 2 of 4 — not the first "
        + "track, not the last, so an off-by-one or a `.first` cannot pass this)",
        a3.ackTrack === tTarget,
        `ackTrackId=${short(a3.ackTrack)} expected=${short(tTarget)} `
        + `(track index ${I_TARGET}; tracks=${ids.map(short).join(",")})`);

  // E — the SIDE EFFECTS survive on the very click that is acknowledged. The
  // standing prohibition: they are the REASON feedback is owed, so "fixing" the
  // silence by removing them would be the wrong repair.
  check("E1 the acknowledged click STILL bumps the arrange key-focus nonce (DELETE keeps "
        + "reaching the arrange) — the feedback is added BESIDE the side effects, never "
        + "instead of them",
        a3.nonce > b3.nonce, `keyFocusNonce ${b3.nonce} -> ${a3.nonce}`);
  check("E2 the acknowledged click STILL engages the ARRANGE surface (⌘+/⌘−/⌘0 routing, "
        + "m23-al-1)",
        a3.surface === "arrange", `activeEditorSurface ${b3.surface} -> ${a3.surface}`);

  // D2 — THE WIDENING the filing missed: a PLAIN click on an empty header with
  // an already-empty selection. `effect` is "replace", NOT "no-clips".
  await sel({ act: "clear" });
  const b2 = snap(await sel({}));
  const r2 = await sel({ act: "clickTrack", trackId: tTarget });
  const a2 = snap(r2);
  check("D2 PLAIN on a 0-clip header with an EMPTY selection is equally silent and is "
        + "ALSO acknowledged — and its effect is \"replace\", so a predicate written as "
        + "`effect == .noClips` would miss it",
        same(b2, a2) && r2.trackClickEffect === "replace"
          && r2.trackClickChangedSelection === false
          && a2.ack === "no-clips-to-select" && a2.ackTrack === tTarget,
        `effect=${r2.trackClickEffect} changed=${r2.trackClickChangedSelection} `
        + `ack=${JSON.stringify(a2.ack)} row=${short(a2.ackTrack)}`);

  // ══ D1 — ⚠️ THE MUTANT LEG ═════════════════════════════════════════════════
  // Pre-state first: an ABSENCE assertion is worthless if a stale word was
  // standing. A click on the POPULATED header clears it (`.notNeeded` clears).
  await sel({ act: "clear" });
  await sel({ act: "clickTrack", trackId: tFull });     // selects 3, clears any ack
  const pre1 = snap(await sel({}));
  check("D1-pre NO acknowledgement is standing before the absence leg runs — a leftover "
        + "would make D1 fail (or, under a mutant, pass) for the wrong reason",
        pre1.ack === null, `ack=${JSON.stringify(pre1.ack)}`);

  const midi = (await req("project.overview", {})).tracks[I_FULL].clips;
  await sel({ act: "click", clipId: midi[0].id });      // one clip selected + FOCUSED
  const b1 = snap(await sel({}));
  const r1 = await sel({ act: "clickTrack", trackId: tTarget });   // PLAIN
  const a1 = snap(r1);
  check("D1-loud the plain click really did make a LARGE visible change: the selection "
        + "cleared and the note editor closed",
        b1.n === 1 && a1.n === 0 && b1.open !== "null" && a1.open === "null",
        `n ${b1.n}->${a1.n} focus ${b1.focus}->${a1.focus} editorClip ${b1.open}->${a1.open}`);
  check("⚠️ D1 THE MUTANT LEG — that same click takes NO acknowledgement. Drop the "
        + "`!changedSelection` term (\"acknowledge on any empty-track click\") and a "
        + "\"nothing to select\" chip lands on top of a cleared selection and a closed "
        + "piano roll. This asserts the ABSENCE, which is the only form that can redden.",
        a1.ack === null && a1.ackTrack === null && r1.trackClickChangedSelection === true,
        `ack=${JSON.stringify(a1.ack)} row=${JSON.stringify(a1.ackTrack)} `
        + `changed=${r1.trackClickChangedSelection} effect=${r1.trackClickEffect}`);

  // D6 — the row that kills the ONE-term predicate the other way round.
  await sel({ act: "clear" });
  await sel({ act: "clickTrack", trackId: tFull });
  const b6 = snap(await sel({}));
  const r6 = await sel({ act: "clickTrack", trackId: tFull });     // the SAME header again
  const a6 = snap(r6);
  check("⚠️ D6 THE OTHER MUTANT LEG — a repeated plain click on a POPULATED header "
        + "changes nothing, yet must stay silent: three blocks are visibly selected and "
        + "the state matches the intent. A bare \"did the selection change?\" predicate "
        + "fires HERE.",
        same(b6, a6) && r6.trackClickChangedSelection === false && a6.ack === null,
        `n ${b6.n}->${a6.n} changed=${r6.trackClickChangedSelection} `
        + `ack=${JSON.stringify(a6.ack)}`);

  // ══ T — TRANSIENCE, and never selection state ══════════════════════════════
  console.log("\n── T: the word leaves, and a real selection takes it down at once ──");
  await sel({ act: "clear" });
  await sel({ act: "clickTrack", trackId: tTarget, shift: true });
  const t0 = snap(await sel({}));
  await sleep(1000);
  const t1 = snap(await sel({}));
  await sleep(3000);            // total ~4.0 s > the 3 s hold + 0.3 s fade
  const t2 = snap(await sel({}));
  check("T1 the acknowledgement is TRANSIENT: standing at t=0 and t=1 s, GONE by t≈4 s. "
        + "A word that never left would read as state, which is exactly what "
        + "ArrangeTrackSelection's standing prohibition forbids.",
        t0.ack === "no-clips-to-select" && t1.ack === "no-clips-to-select" && t2.ack === null,
        `t0=${JSON.stringify(t0.ack)} t1s=${JSON.stringify(t1.ack)} t4s=${JSON.stringify(t2.ack)}`);

  await sel({ act: "clickTrack", trackId: tTarget, shift: true });
  const s0 = snap(await sel({}));
  await sel({ act: "clickTrack", trackId: tFull, shift: true });    // selects something
  const s1 = snap(await sel({}));
  check("T2 a click that DOES select something takes a standing word down immediately — "
        + "an acknowledgement can never outlive the condition that produced it",
        s0.ack === "no-clips-to-select" && s1.ack === null && s1.n === N_CLIPS,
        `standing=${JSON.stringify(s0.ack)} after=${JSON.stringify(s1.ack)} n=${s1.n}`);

  // ══ P — PIXELS ═════════════════════════════════════════════════════════════
  // The empty-lane-hint law: a build that keeps the value and the echo but draws
  // nothing leaves every leg above GREEN.
  console.log("\n── P: ink appears, and ink goes away byte-exactly ──");
  await sel({ act: "clear" });
  // FIRST click, then let it expire — the resting frame is taken AFTER a click
  // identical to the one under test, so rest and word-standing differ in the
  // chip and in nothing else (nonce is a counter and draws nothing; engage is
  // change-guarded, so the second click is a no-op there).
  await sel({ act: "clickTrack", trackId: tTarget, shift: true });
  await sleep(4500);
  const p0 = snap(await sel({}));
  check("P0 precondition — at REST the selection is empty, the surface is already "
        + "\"arrange\", and NO word is standing. Without this the two pixel frames could "
        + "differ in a surface transition rather than in the chip.",
        p0.n === 0 && p0.surface === "arrange" && p0.ack === null,
        `n=${p0.n} surface=${p0.surface} ack=${JSON.stringify(p0.ack)}`);

  const rest = await stableCapture("rest");
  check("P1 a STABLE resting image could be established (two consecutive byte-identical "
        + "frames) — without one, no pixel claim below is readable. A FAILURE, never a skip.",
        rest !== null, rest ? `sha=${rest.sha.slice(0, 12)} ${rest.width}x${rest.height}` : "never stabilised");
  if (!rest) throw new Error("no stable resting image");

  await sel({ act: "clickTrack", trackId: tTarget, shift: true });
  await sleep(400);
  // A waits for the window to actually redraw (see `captureWhenChanged`); B is a
  // plain capture taken after it, by which point the frame is settled. A null A
  // means the frame never changed inside the chip's life — which is precisely
  // the draws-nothing failure P2 exists to catch, so it fails the leg.
  const reclickTarget = () => sel({ act: "clickTrack", trackId: tTarget, shift: true });
  const shotA = await captureWhenChanged("word", rest, reclickTarget);
  const midAck = snap(await sel({}));
  await sleep(250);
  const shotB = await capture("word");
  // ⚠️ WHAT P2 PROVES AND WHAT IT DOES NOT — MEASURED, not reasoned. Three
  // mutants were run against this gate:
  //   • predicate neutered to always `.notNeeded` (the PRE-FIX behaviour)
  //       -> 15/21, and P2 is one of the six that redden.
  //   • the chip's `Text` replaced by an EMPTY string, everything else intact
  //       -> 21/21 GREEN. The padding, background, border and shadow still
  //          rasterize, so P2 sees a difference and cannot tell an empty chip
  //          from a lettered one.
  //   • the whole chip replaced by transparent zero-size layout
  //       -> 19/21: P2 reddens (and S3, since the ink token goes with it), while
  //          EVERY echo leg above stays green — the m23-v class, caught.
  // So P2's claim is exactly "INK APPEARED AND IT WENT AWAY", not "the sentence
  // was drawn". Proving the GLYPHS needs the m23-ah NCC probe; the honest scope
  // is recorded as a skip below rather than implied by a stronger-sounding name.
  check("P2 INK EXISTS — two frames taken while the word stands BOTH differ from the "
        + "resting frame. This is the leg a build that computes the verdict, echoes it, "
        + "and draws nothing cannot pass (DESIGN-LANGUAGE, empty-lane-hint law).",
        !!shotA && shotA.sha !== rest.sha && shotB.sha !== rest.sha
          && midAck.ack === "no-clips-to-select",
        `rest=${rest.sha.slice(0, 12)} A=${shotA ? shotA.sha.slice(0, 12) : "(never changed)"} `
        + `B=${shotB.sha.slice(0, 12)} ack-at-capture=${JSON.stringify(midAck.ack)}`);

  await sleep(4500);
  const after = await stableCapture("after");
  check("P3 the ink GOES AWAY BYTE-EXACTLY: the frame after expiry is identical to the "
        + "resting frame, so the chip left no residue on the row. This is the pixel form "
        + "of \"it must never read as selection state\".",
        after !== null && after.sha === rest.sha,
        after ? `rest=${rest.sha.slice(0, 12)} after=${after.sha.slice(0, 12)}` : "never stabilised");

  // ══ G — WHERE THE WORD LANDED, IN PIXELS ═══════════════════════════════════
  // ⚠️ THE LEGS THAT WOULD HAVE CAUGHT BUILD 1. Everything above was green while
  // the chip was painted across the WRONG ROW: the model named track i, the seam
  // echoed track i, the ink appeared and left byte-exactly — and a user reading
  // the screen saw the sentence sitting on track i+1, over its icon and the top
  // of its name. Measured, not supposed: chip body y 298.5…319.5 pt against a
  // next-row band of 302.5…336.5 pt. That is the m23-am defect, one cycle later,
  // in a feature whose whole purpose is telling the user WHICH row said nothing.
  //
  // The row's band is MEASURED, never computed from `rowHeight` (which is
  // user-adjustable, so a computed band would agree with the layout only by
  // luck): muting a track repaints inside that track's row and nowhere else, so
  // the diff box of a mute toggle IS that row, read off the same frames.
  // ⚠️ THIS SECTION TAKES ITS OWN FRAMES. The first version reused P2's `shotA`,
  // captured ~10 s and four mute toggles earlier, and it went null once in three
  // runs while P2 — which compares the same two files by SHA — stayed green. A
  // stale frame is not worth diagnosing when a fresh one costs 3 s, but the
  // MISMATCH itself is worth reporting, so G0 says so explicitly rather than
  // failing as a mystery.
  const bandTarget = await rowBand(tTarget, rest, "band-target");
  const bandNext = await rowBand(ids[I_TARGET + 1], rest, "band-next");

  await sleep(4500);
  const restG = await stableCapture("rest-geo");
  await sel({ act: "clickTrack", trackId: tTarget, shift: true });
  await sleep(400);
  const shotG = restG ? await captureWhenChanged("word-geo", restG, reclickTarget) : null;
  const ackG = snap(await sel({}));
  const chipBox = restG && shotG ? diffBox(restG.path, shotG.path) : null;
  const shaSaysInk = !!(restG && shotG && restG.sha !== shotG.sha);

  check("G0 precondition — both row bands measured and DISJOINT, the word was standing "
        + "at capture, and the frame really changed. A leg that compares against an "
        + "unmeasured band certifies itself (the m23-bl trap); and if the SHA says the "
        + "frame changed while the pixel diff finds nothing, that is reported HERE "
        + "rather than surfacing as an unexplained null downstream.",
        !!restG && !!bandTarget && !!bandNext && !!chipBox
          && ackG.ack === "no-clips-to-select"
          && shaSaysInk === !!chipBox
          && !overlapsY(bandTarget, bandNext),
        `target=${boxStr(bandTarget)} next=${boxStr(bandNext)} chip=${boxStr(chipBox)} `
        + `ack=${JSON.stringify(ackG.ack)} shaDiffers=${shaSaysInk}`);

  check("G1 the chip's ink lands IN THE CLICKED ROW's own band — the sentence is on the "
        + "track it is about",
        !!chipBox && overlapsY(chipBox, bandTarget),
        `chip ${boxStr(chipBox)} vs clicked row ${boxStr(bandTarget)}`);

  // ⚠️ `!!chipBox &&` is load-bearing, not defensive noise: without it this leg
  // reads GREEN when there is no ink at all — "the chip did not reach the next
  // row" is trivially true of a chip that was never drawn. An absence leg that
  // passes on absence is the m23-am mistake in miniature.
  check("G2 ⚠️ MISATTRIBUTION — the chip's ink exists and does NOT reach the NEXT row's "
        + "band. This is build 1's shipped bug written as an assertion; it reddens if "
        + "the chip is ever hung below the row again, which every other leg tolerates.",
        !!chipBox && !overlapsY(chipBox, bandNext),
        `chip ${boxStr(chipBox)} vs next row ${boxStr(bandNext)}`);

  // G3 — the LAST row. `tops[last] + heights[last]` is the row stack's own bottom
  // edge, so the old geometry drew outside it and was at the scroll view's mercy;
  // a newly added track lands last and has no clips, which is the likeliest way a
  // user meets this feature at all. The fixture's target is deliberately NOT last,
  // so nothing above covers this.
  await sleep(4500);
  const restL = await stableCapture("rest-last");
  await sel({ act: "clickTrack", trackId: ids[ids.length - 1], shift: true });
  await sleep(400);
  const reclickLast = () => sel({ act: "clickTrack", trackId: ids[ids.length - 1], shift: true });
  const lastShot = restL ? await captureWhenChanged("word-last", restL, reclickLast) : null;
  const lastAck = snap(await sel({}));
  const lastBox = restL && lastShot ? diffBox(restL.path, lastShot.path) : null;
  const bandLast = restL ? await rowBand(ids[ids.length - 1], restL, "band-last") : null;
  check("G3 the LAST row gets the word too, and in its OWN band — not clipped away by "
        + "the scroll view, which is what the old outside-the-stack geometry risked",
        lastAck.ack === "no-clips-to-select" && !!lastBox && overlapsY(lastBox, bandLast),
        `ack=${JSON.stringify(lastAck.ack)} chip=${boxStr(lastBox)} band=${boxStr(bandLast)}`);

  // ══ Recorded as SKIPS, never as passes ═════════════════════════════════════
  skip("that a REAL MOUSE CLICK on the header (rather than the seam) reaches this path",
       "The seam drives the SAME `AppModel.clickTrack` the `TrackRow` "
       + "`.simultaneousGesture` calls — that is the documented contract on the method, "
       + "and it is why the chip is MODEL-owned rather than row-`@State`. But the final "
       + "hop (an NSEvent through SwiftUI's gesture arbitration, including the chord read "
       + "from `NSEvent.modifierFlags` at mouse-up) needs a human at a real window; "
       + "m23-y records the same hop as a skip for the same reason.");
  skip("that the SENTENCE — rather than merely a chip — is what got drawn",
       "MEASURED, not assumed: replacing the chip's `Text` with an EMPTY string leaves "
       + "this gate at 21/21, because the padding/background/border/shadow still "
       + "rasterize and P2 only compares whole-frame hashes. S1/S2 pin the literal in "
       + "source and against DESIGN-LANGUAGE.md, and the true draws-nothing mutant DOES "
       + "redden P2 (19/21) — but proving the GLYPHS on screen needs the m23-ah NCC "
       + "probe (`scripts/probes/m23ah-hint-glyph-probe.swift`) aimed at this chip's "
       + "rect, which it cannot be until the chip reports a rect. Filed rather than "
       + "overstated.");
  skip("that the chip is NOTICED — that a user's eye actually catches it",
       "WHERE it lands is no longer a skip: G1/G2/G3 measure the chip's ink against the "
       + "clicked row's own MEASURED band and against its neighbour's. What stays out of "
       + "reach is whether 9 pt of neutral prose, appearing for three seconds at the "
       + "trailing edge of a 34 pt row, is SEEN by someone whose attention is on the "
       + "arrange grid to the right. That is a human judgement, and deliberately not one "
       + "a passing gate should be read as having made.");
  skip("that covering the row's M/S/R chips for three seconds is the right trade",
       "MEASURED at the 250 pt sidebar floor (`scripts/gates/_m23an-geometry-probe.mjs`): "
       + "the chip sits at the row's trailing edge with the track NAME fully legible and "
       + "the automation button and M/S/R behind it. `.allowsHitTesting(false)` means "
       + "those controls still take a click while occluded, so the cost is visual only "
       + "and lasts 3 s — but whether a user reaches for Mute in that window and is "
       + "confused by not seeing it is a human check, not a machine one.");

  // ══ SUMMARY ════════════════════════════════════════════════════════════════
  const failed = checks.filter((c) => !c.ok);
  console.log(`\n${checks.length - failed.length}/${checks.length} assertions passed`
    + `  (${skips.length} skipped)`);
  for (const c of failed) console.log(`  FAILED: ${c.name} — ${c.detail}`);
  fs.writeFileSync(`${OUT}/result.json`, JSON.stringify({ checks, skips }, null, 2));
  clearTimeout(killer);
  ws.close();
  teardown();
  process.exit(failed.length ? 1 : 0);
} catch (err) {
  console.error("GATE ERROR:", err);
  clearTimeout(killer);
  try { ws.close(); } catch {}
  teardown();
  process.exit(2);
}
