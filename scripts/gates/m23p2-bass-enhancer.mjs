// m23-p2 GATE — the bass enhancer's editor and its DRAWN honesty disclosure.
//
// The audio half of this cycle's gate is `Tests/DAWEngineTests/
// BassEnhancerPlaybackTests.swift` (the high-passed-playback A/B). This script
// is the other half: does the card the user actually opens carry the
// disclosure, at the width the effect editor really gets?
//
// `DAWApp` is the one target with no test suite, so the plumbing this cycle
// added there — `effectEditorHonestyNote`, the ContentView hand-off, the
// `debug.effectEditor` field — is invisible to everything in `Tests/`. Only a
// live staging run can see it.
//
// ⚠️ BUILD FIRST. `spawn(".build/debug/DAWApp")` with no build step tests the
// PREVIOUS build; restoring a mutated source leaves the mutant binary on disk
// for the next run to adopt. This script builds and aborts on failure.
//
// Staging 17695 ONLY. 17600 is the user's LIVE app and is never touched.
// Kill by EXACT pid from the pidfile — never pkill/pgrep.
import { mkdirSync, writeFileSync, readFileSync, existsSync, rmSync, statSync } from "node:fs";

// The build/launch/pidfile-kill lifecycle lives in ONE place (m23-ac-1) —
// `_staging.mjs`. It used to be copy-pasted into every gate that had it at all.
import { launchStaging, stopStaging, sleep, STAGING_PORT } from "./_staging.mjs";

const GATE = "m23p2";
const OUT = "/tmp/daw-gate-out/m23p2";
mkdirSync(OUT, { recursive: true });
let ws, seq = 0, pass = 0, fail = 0;
const failures = [];
function cmd(command, params = {}, timeoutMs = 30000) {
  return new Promise((res, rej) => {
    const id = `p2-${++seq}`;
    const timer = setTimeout(() => rej(new Error(`timeout ${command}`)), timeoutMs);
    const onMsg = (ev) => {
      let m; try { m = JSON.parse(ev.data); } catch { return; }
      if (m.id !== id) return;
      clearTimeout(timer); ws.removeEventListener("message", onMsg); res(m);
    };
    ws.addEventListener("message", onMsg);
    ws.send(JSON.stringify({ id, command, params }));
  });
}
function ck(label, cond, detail = "") {
  if (cond) { pass++; console.log(`PASS ${label}`); }
  else { fail++; failures.push(label); console.log(`FAIL ${label} :: ${detail}`); }
}

// The same discriminating shape the Swift pin uses: a DIGIT NEXT TO A UNIT is
// what makes a string read as a measurement of the user's own signal.
const READOUT = /\d+\s*(Hz|kHz|dB|dBFS|ms|%|x)\b/i;

const staging = await launchStaging({ gate: GATE });
try {
  ws = staging.ws;

  // ---- G1: a clean project with one track ----------------------------------
  let r = await cmd("project.new", { discardChanges: true });
  ck("G1 project.new", r.ok, JSON.stringify(r.error));
  r = await cmd("track.add", { name: "Bass", kind: "audio" });
  ck("G2 track.add", r.ok, JSON.stringify(r.error));
  const trackId = r.result?.id;
  ck("G3 track id returned", typeof trackId === "string", JSON.stringify(r.result));

  // ---- G4: the "+" menu funnel adds the bass enhancer and opens its card ----
  // `add:` drives `addBuiltInInsert` — verbatim what the strip's "+" menu runs.
  r = await cmd("debug.effectEditor", { trackId, add: "bassEnhancer" });
  ck("G4 add bassEnhancer through the UI funnel", r.ok, JSON.stringify(r.error));
  let s = r.result ?? {};
  ck("G5 card is open", s.visible === true, JSON.stringify(s.visible));
  ck("G6 card kind is bassEnhancer", s.kind === "bassEnhancer", String(s.kind));
  ck("G7 the three params are on the card",
     s.values && "crossoverHz" in s.values && "amount" in s.values && "mix" in s.values,
     JSON.stringify(s.values));
  ck("G8 defaults land (80 / 0.5 / 1)",
     s.values?.crossoverHz === 80 && s.values?.amount === 0.5 && s.values?.mix === 1,
     JSON.stringify(s.values));

  // ---- G9…G15: the DISCLOSURE reached the card -----------------------------
  const note = s.honestyNote;
  ck("G9 honestyNote is present", note && typeof note === "object", JSON.stringify(note));
  ck("G10 it has all three drawn fields",
     !!note?.headline && !!note?.body && !!note?.footnote, JSON.stringify(note));
  ck("G11 the headline admits the harmonics are added",
     /adds/i.test(note?.headline ?? "") && /harmonics/i.test(note?.headline ?? "")
       && /not in your recording/i.test(note?.headline ?? ""),
     note?.headline);
  ck("G12 the body keeps the benefit", /small speakers/i.test(note?.body ?? ""), note?.body);
  ck("G13 the body says it prints", /bounce/i.test(note?.body ?? ""), note?.body);
  ck("G14 the footnote teaches amount + level independence",
     /loud/i.test(note?.footnote ?? "") && /bright/i.test(note?.footnote ?? "")
       && /quiet/i.test(note?.footnote ?? ""),
     note?.footnote);
  ck("G14b the footnote teaches CROSSOVER — the one knob whose right value is not taste",
     /crossover/i.test(note?.footnote ?? "")
       && /lowest note your speaker plays/i.test(note?.footnote ?? ""),
     note?.footnote);
  // The probe's own `drawn` array (EffectHonestyNote.drawnStrings), NOT three
  // fields re-listed here: a fourth drawn string is swept by this regex the day
  // it is added, instead of the day someone remembers to add it to this line.
  const drawn = note?.drawn ?? [];
  ck("G15 no drawn string reads as a measurement",
     drawn.length === 3 && drawn.every((t) => !READOUT.test(t)),
     `${drawn.length} drawn | ${drawn.filter((t) => READOUT.test(t)).join(" | ")}`);
  ck("G15b the swept array really is the drawn copy",
     drawn.includes(note?.headline) && drawn.includes(note?.body)
       && drawn.includes(note?.footnote),
     JSON.stringify(drawn));

  // ---- G34…G40: THE INK. Added in the review round, numbered last, run here
  // because the card is open.
  //
  // Everything above this block pins WHICH WORDS EXIST and WHERE THEY SIT.
  // None of it could see the ink, and the design language makes four claims
  // about it. A reviewer proved the gap by redrawing the prose in DAWTheme.ai
  // — violet, which in this app means AI-generated content, so a disclosure
  // about synthesized harmonics would have been claiming the disclosure itself
  // was machine-written — and the gate stayed 42/42 GREEN.
  //
  // The drawn side is MEASURED (EffectEditorOverlay reports the face and ink
  // its own Text modifiers consumed, resolved through NSColor). The reference
  // side is NAMED (`inkTokens`), so no hex is hardcoded here.
  // RE-QUERY, for the same reason G29b does: `honestyStyle` is filled by the
  // card's own modifiers during layout, so reading it out of the response that
  // OPENED the card returns an empty object. That is exactly how this block
  // first failed — and an empty report reads as "no violet found", which is a
  // vacuous pass waiting to happen, so G34 fails on an empty object rather
  // than skipping.
  await sleep(400);
  const styled = (await cmd("debug.effectEditor", {})).result ?? {};
  const style = styled.honestyStyle ?? {};
  const tokens = styled.inkTokens ?? {};
  const textRoles = ["headline", "body", "footnote"];
  ck("G34 every drawn role reports its face and ink",
     textRoles.every((r) => typeof style[r]?.ink === "string"
                         && /^#[0-9A-F]{6}$/.test(style[r].ink)
                         && typeof style[r]?.face === "string")
       && /^#[0-9A-F]{6}$/.test(style.background?.ink ?? ""),
     JSON.stringify(style));
  // Anti-vacuity: a probe reporting one value for everything would satisfy
  // several legs below by accident. The headline is a DIFFERENT ink from the
  // prose by design, so this also pins that the report is per-role.
  ck("G34b the report is per-role, not one value echoed three times",
     style.headline?.ink !== style.body?.ink
       && style.body?.ink === style.footnote?.ink,
     JSON.stringify([style.headline?.ink, style.body?.ink, style.footnote?.ink]));
  ck("G35 no drawn role uses a monospaced face",
     textRoles.every((r) => style[r]?.face === "default"),
     JSON.stringify(textRoles.map((r) => `${r}:${style[r]?.face}`)));
  ck("G36 no drawn role uses the AI token — violet would claim the COPY is machine-written",
     !!tokens.ai && textRoles.every((r) => style[r]?.ink !== tokens.ai),
     `ai=${tokens.ai} drawn=${JSON.stringify(textRoles.map((r) => style[r]?.ink))}`);
  ck("G36b no drawn role uses the record/amber token — a disclosure is not a fault",
     !!tokens.record && textRoles.every((r) => style[r]?.ink !== tokens.record),
     `record=${tokens.record} drawn=${JSON.stringify(textRoles.map((r) => style[r]?.ink))}`);
  // WCAG relative luminance, so "dimmer" is a measurement rather than a guess
  // at which hex looks darker.
  const lum = (hex) => {
    const c = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255)
      .map((v) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4));
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
  };
  const contrast = (a, b) => {
    const [hi, lo] = [lum(a), lum(b)].sort((x, y) => y - x);
    return (hi + 0.05) / (lo + 0.05);
  };
  ck("G37 the headline is brighter than the prose — fine print is its own honesty failure",
     !!style.headline?.ink && !!style.body?.ink && lum(style.headline.ink) > lum(style.body.ink),
     `${style.headline?.ink} vs ${style.body?.ink}`);
  ck("G38 the prose is never drawn below the knob labels it sits above",
     !!tokens.knobLabel && !!style.body?.ink && lum(style.body.ink) >= lum(tokens.knobLabel),
     `prose ${style.body?.ink} vs knob label ${tokens.knobLabel}`);
  // Rule 5, against the background this block ACTUALLY draws on (reported from
  // the same value that fills the shape, not the panel token a gate assumed).
  const proseContrast = (style.body?.ink && style.background?.ink)
    ? contrast(style.body.ink, style.background.ink) : 0;
  console.log(`      prose contrast ${proseContrast.toFixed(2)}:1 on ${style.background?.ink}`);
  ck("G39 the prose clears Rule 5 contrast on the panel it is drawn on",
     proseContrast >= 4.5, `${proseContrast.toFixed(2)}:1`);
  ck("G40 the drawn inks ARE the intended tokens",
     !!style.headline?.ink && style.headline.ink === tokens.textSecondary
       && style.body?.ink === tokens.knobLabel,
     `headline ${style.headline?.ink} vs ${tokens.textSecondary}, prose ${style.body?.ink} vs ${tokens.knobLabel}`);

  // ---- G16: the params drive the OPEN card's apply path --------------------
  for (const [name, value] of [["crossoverHz", 150], ["amount", 0.8], ["mix", 0.6]]) {
    r = await cmd("debug.effectEditor", { param: name, value });
    ck(`G16 set ${name}=${value}`, r.ok, JSON.stringify(r.error));
  }
  r = await cmd("debug.effectEditor", {});
  s = r.result ?? {};
  ck("G17 the card reads back what was set",
     s.values?.crossoverHz === 150 && s.values?.amount === 0.8 && s.values?.mix === 0.6,
     JSON.stringify(s.values));
  ck("G18 the disclosure survives a param change", !!s.honestyNote, JSON.stringify(s.honestyNote));

  // ---- G19: the CAPTURE, at the width the effect editor really gets --------
  // The card is a floating 340 pt strip (560 only when an EQ curve shows), NOT
  // constrained by the mixer strip's budget. A capture is the only instrument
  // that can see whether the disclosure block fits it.
  r = await cmd("debug.captureUI", { path: `${OUT}/bass-enhancer-card.png` });
  ck("G19 captureUI succeeded", r.ok, JSON.stringify(r.error));
  const shot = r.result?.path;
  ck("G20 capture file exists and is non-trivial",
     !!shot && existsSync(shot) && statSync(shot).size > 20000,
     `${shot} ${shot && existsSync(shot) ? statSync(shot).size : "missing"}`);
  console.log(`      capture: ${shot} (${r.result?.width}×${r.result?.height}, ${r.result?.method})`);

  // ---- G21…G24: the card still FITS, measured at the window FLOOR ----------
  // The disclosure is the first thing on this card whose height is a function
  // of prose, and the card is a modal with no scroll of its own. Assert the
  // MEASURED height (reported from the card's own GeometryReader) against the
  // floor the probe also reports — never a hardcoded number, so a change to
  // `WindowFloor.minHeight` moves the assertion with it.
  r = await cmd("debug.windowFrame", { width: 1208, height: 640 });
  ck("G21 window shrunk to the floor", r.ok, JSON.stringify(r.error));
  const floorH = r.result?.height;
  ck("G22 the window really is at the floor",
     floorH === r.result?.minHeight, JSON.stringify([floorH, r.result?.minHeight]));
  await sleep(500);
  r = await cmd("debug.effectEditor", {});
  s = r.result ?? {};
  const cardH = s.cardHeight;
  console.log(`      card height ${cardH} pt in a ${s.windowMinHeight} pt floor window`);
  ck("G23 the card reports a measured height", typeof cardH === "number" && cardH > 100,
     JSON.stringify(cardH));
  // 32 pt of scrim on each side of a centered modal is the visual minimum that
  // still reads as a card floating over the app rather than a full-screen sheet.
  ck("G24 the card fits the window floor with room to breathe",
     typeof cardH === "number" && cardH + 64 <= s.windowMinHeight,
     `card ${cardH} + 64 vs floor ${s.windowMinHeight}`);
  // And it fits the modal's OWN declared cap — a card whose intrinsic height
  // outgrows `maxCardHeight` overflows that frame silently, which is how a
  // future longer sentence would go unnoticed until someone read a screenshot.
  ck("G24b the card fits its own declared cap",
     typeof cardH === "number" && cardH <= s.cardMaxHeight,
     `card ${cardH} vs cap ${s.cardMaxHeight}`);
  // The WIDTH the roadmap line actually asked about. This card is a FLOATING
  // modal, so it is not constrained by the mixer strip's width budget — it is
  // the 340 pt house strip for a knob kind. Asserted from the card's own
  // GeometryReader rather than from the view's constant, because a probe that
  // restates a constant the view might have stopped using is self-consistent
  // and blind (the m23-o2 widthSource lesson). Every line-count assumption
  // behind the disclosure's fit is a claim about THIS number.
  console.log(`      card width ${s.cardWidth} pt (the 340 pt house strip, floating)`);
  ck("G24c the card reports a measured width, and it is the knob strip",
     typeof s.cardWidth === "number" && Math.abs(s.cardWidth - 340) < 1,
     JSON.stringify(s.cardWidth));
  r = await cmd("debug.captureUI", { path: `${OUT}/bass-enhancer-card-floor.png` });
  ck("G25 captureUI at the floor", r.ok, JSON.stringify(r.error));
  r = await cmd("debug.windowFrame", { width: 1440, height: 900 });
  ck("G26 window restored", r.ok, JSON.stringify(r.error));
  await sleep(300);
  r = await cmd("debug.effectEditor", {});
  const enhancerCardH = r.result?.cardHeight;

  // ---- the field MIRRORS the view -----------------------------------------
  // Reported for every kind, null when the kind has no note. A field nested
  // inside a `kind == bassEnhancer` block could not catch the card drawing a
  // disclosure for the WRONG kind, which is the wiring error that matters.
  r = await cmd("debug.effectEditor", { trackId, add: "saturator" });
  ck("G27 add a saturator (a near neighbour that also creates harmonics)",
     r.ok, JSON.stringify(r.error));
  s = r.result ?? {};
  ck("G28 the saturator card is open", s.kind === "saturator" && s.visible === true,
     JSON.stringify([s.kind, s.visible]));
  ck("G29 the saturator carries NO disclosure",
     s.honestyNote === null, JSON.stringify(s.honestyNote));

  // THE HAND-ASSIGNMENT HOLE, closed on the DRAWN side. Every check above
  // reads `honestyNote` out of the app model — the same property ContentView
  // reads. Pass `nil` at that call site and the probe keeps reporting the note
  // while the card draws nothing, and every leg above stays green. So compare
  // MEASURED card heights: a disclosure occupies real space.
  //
  // ⚠️ THE CONTROL HAS TO BE STRUCTURALLY IDENTICAL, and the first version of
  // this leg was not. Against the SATURATOR it read 558 vs 310 and passed a
  // `> 100` threshold — but the saturator card has TWO knob groups to the bass
  // enhancer's three, so 105 pt of that gap is group structure, not
  // disclosure. A mutation blanking the ContentView hand-off left it GREEN at
  // 415 vs 310. `reverb` is the right control: CHARACTER(3 items, one row) +
  // TIME(1) + OUTPUT(1) is the same three-groups-one-row-each shape, so
  // `sectionsHeight` is identical and the ONLY difference between the two
  // cards is the block this cycle added.
  //
  // Re-query after a beat: `cardHeight` is reported by the card's own layout
  // pass, which has not run yet in the response to the command that opened it.
  // Reading it out of that response returns the PREVIOUS card's height — which
  // is how this leg first failed with two identical numbers.
  r = await cmd("debug.effectEditor", { trackId, add: "reverb" });
  ck("G29b the reverb control card opens", r.ok && r.result?.kind === "reverb",
     JSON.stringify(r.error ?? r.result?.kind));
  await sleep(400);
  const controlCardH = (await cmd("debug.effectEditor", {})).result?.cardHeight;
  console.log(`      bass enhancer card ${enhancerCardH} pt vs reverb control ${controlCardH} pt`);
  ck("G29c the disclosure occupies real space on the drawn card",
     typeof enhancerCardH === "number" && typeof controlCardH === "number"
       && enhancerCardH - controlCardH > 100,
     `enhancer ${enhancerCardH} vs reverb ${controlCardH} — same knob structure, so this gap IS the disclosure`);

  r = await cmd("debug.captureUI", { path: `${OUT}/saturator-card.png` });
  ck("G30 captureUI (saturator, for the visual A/B)", r.ok, JSON.stringify(r.error));

  // ---- G25: closing the card clears the field ------------------------------
  r = await cmd("debug.effectEditor", { close: true });
  s = r.result ?? {};
  ck("G31 closing the card drops the disclosure",
     s.visible === false && s.honestyNote === null,
     JSON.stringify([s.visible, s.honestyNote]));
  ck("G31b closing the card drops the measured size too",
     s.cardHeight === null && s.cardWidth === null,
     JSON.stringify([s.cardHeight, s.cardWidth]));

  // ---- G26: the wire surface is unchanged (additive-only, nothing added) ---
  r = await cmd("fx.describe", { kind: "bassEnhancer" });
  ck("G32 fx.describe still teaches the kind", r.ok && r.result?.kinds?.length === 1,
     JSON.stringify(r.error ?? r.result));
  const specs = r.result?.kinds?.[0]?.params ?? [];
  ck("G33 all three params carry their wire teaching note",
     specs.length === 3 && specs.every((p) => typeof p.note === "string" && p.note.length > 40),
     JSON.stringify(specs.map((p) => p.name)));
} catch (e) {
  fail++; failures.push(`EXCEPTION ${e.message}`);
  console.log(`FAIL exception :: ${e.stack}`);
} finally {
  stopStaging(GATE);
}

console.log(`\n${pass}/${pass + fail} checks passed`);
if (fail) { console.log(`failures: ${failures.join(", ")}`); process.exit(1); }
