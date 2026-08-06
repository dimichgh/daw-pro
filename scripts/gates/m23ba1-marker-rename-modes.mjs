// m23-ba-1 gate — the arrange marker-rename staging seam's THREE resolution
// paths, end to end, plus the validation floor.
//
// ═══ WHY THIS GATE EXISTS ═══
//
// `TrackRename.committedName` is unit-tested as a pure function, but until
// m23-ba-1 the marker-rename WIRING was tested NOWHERE: `grep -rln committedName
// Tests` returned only the pure-rule test. So nothing anywhere proved that
// finishing a rename through the UI path actually renames the marker.
//
// ⚠️ THE ASSERTION THAT MATTERS READS `marker.list`, NEVER THE SEAM'S OWN ECHO.
// A seam that reported "committed 'Padded'" while the store still held "Anchor"
// would pass any check written against `resolution.committedName` alone. The
// echo is asserted too, but only as corroboration.
//
// ═══ HOW A DISTINCT DRAFT IS PRODUCED WITHOUT A KEYBOARD ═══
//
// Real keystrokes are not injectable on the unbundled staging binary (the m17-b
// Accessibility measurement), and `debug.keySpace` can only type SPACES. So the
// draft is made to differ from the model by renaming the marker OVER THE WIRE
// while the field is open: `.onAppear` seeded the draft once, and `marker.rename`
// does not touch it. `debug.keySpace {}` reads the LIVE field editor's text, so
// every leg carries its own positive control that the draft really is distinct
// before it claims anything about what a resolution did with it.
//
// ⚠️ ⚠️ THE OBVIOUS EXPERIMENT CANNOT DISCRIMINATE, and leg T below is here to
// keep the next person from re-deriving that the hard way: type two spaces (the
// m17-d shape), and the draft is "  ", which `TrackRename.committedName` trims
// to empty and DROPS. The marker's name is then unchanged whether the resolution
// committed or discarded. Only a draft that would SURVIVE the commit rule proves
// anything about which path ran.
//
// ═══ THE MEASUREMENT THIS GATE PINS ═══
//
// `{clear:true}` unmounts the TextField, and that DISCARDS the draft — neither
// `onCommitRename` nor `onCancelRename` runs. Measured live 2026-08-05 and
// pinned by leg C, precisely so it cannot silently become a commit under some
// future SwiftUI release without a gate turning red.
//
// Staging: DAW_CONTROL_PORT=17695 (17600 is the user's LIVE app and is never a
// target — enforced in _staging.mjs).
import { sleep, buildOrAbort, startStaging, stopStaging, connect } from "./_staging.mjs";

const GATE = "m23ba1-marker-rename-modes";
buildOrAbort({ label: "building staging binary (m23ba1)…" });
startStaging({ gate: GATE });
const ws = await connect();
let n = 0;
function cmd(command, params = {}) {
  return new Promise((res, rej) => {
    const i = `ba${++n}`;
    const t = setTimeout(() => rej(new Error("TIMEOUT " + command)), 25000);
    const h = ev => {
      const m = JSON.parse(ev.data);
      if (m.id !== i) return;
      clearTimeout(t); ws.removeEventListener("message", h); res(m);
    };
    ws.addEventListener("message", h);
    ws.send(JSON.stringify({ id: i, command, params }));
  });
}
let pass = 0, fail = 0;
const ck = (name, cond, extra) => {
  if (cond) { pass++; console.log("PASS " + name); }
  else { fail++; console.log("FAIL " + name + (extra !== undefined ? " :: " + extra : "")); }
};
const names = async () => ((await cmd("marker.list", {})).result?.markers ?? []).map(m => m.name);
const field = async () => { await sleep(250); return (await cmd("debug.keySpace", {})).result ?? {}; };

// ───────────────────────────────────────────────────────────────────────────
// LEG A — COMMIT (the Return path, and the click-away path: they are the same
// handler). End to end, with trimming.
// ───────────────────────────────────────────────────────────────────────────
let r = await cmd("project.new");
ck("A0 project.new", r.ok, r.error);

// The name carries deliberate padding: `ProjectStore.addMarker` does NOT trim
// (only `renameMarker` does), so this is the one way to get whitespace into a
// draft without a keyboard — and it is what makes the trim assertion real.
r = await cmd("marker.add", { beat: 16, name: "  Padded  " });
const idA = r.result?.id;
ck("A1 marker added with an untrimmed name", r.ok && (await names())[0] === "  Padded  ",
  JSON.stringify(await names()));

r = await cmd("debug.markerRename", { markerId: idA });
ck("A2 open ok, action=open, view reports THAT field open",
  r.ok && r.result?.action === "open" && r.result?.fieldOpenMarkerId === idA,
  JSON.stringify(r.result ?? r.error));

let s = await field();
ck("A3 POSITIVE CONTROL: the live field editor carries the untrimmed draft",
  s.firstResponder === "text-editing" && s.fieldText === "  Padded  ", JSON.stringify(s));

r = await cmd("marker.rename", { markerId: idA, name: "Anchor" });
ck("A4 wire rename moved the MODEL to Anchor", r.ok && (await names())[0] === "Anchor",
  JSON.stringify(r.result ?? r.error));

s = await field();
ck("A5 POSITIVE CONTROL: draft is now genuinely DISTINCT from the model",
  s.fieldText === "  Padded  " && (await names())[0] === "Anchor", JSON.stringify(s.fieldText));

r = await cmd("debug.markerRename", { commit: true });
ck("A6 commit ok, action=commit", r.ok && r.result?.action === "commit",
  JSON.stringify(r.result ?? r.error));
ck("A7 the flag's OWN handler ran, and reported the draft it ran on",
  r.result?.resolution?.action === "commit" && r.result?.resolution?.draft === "  Padded  " &&
  r.result?.resolution?.markerId === idA,
  JSON.stringify(r.result?.resolution));
ck("A8 the TESTED commit rule trimmed it on the way to the store",
  r.result?.resolution?.committedName === "Padded", JSON.stringify(r.result?.resolution));
ck("A9 the field closed through the handler (view reports none open)",
  r.result?.fieldOpenMarkerId === null, JSON.stringify(r.result));

// ⭐ THE END-TO-END ASSERTION. Read from the MODEL, not the seam's echo.
ck("A10 ⭐ marker.list shows the marker was ACTUALLY renamed, trimmed",
  (await names())[0] === "Padded", JSON.stringify(await names()));

s = await field();
ck("A11 focus really left the field", s.firstResponder === "none", JSON.stringify(s));

// ───────────────────────────────────────────────────────────────────────────
// LEG B — CANCEL (the Escape path). Same divergence, opposite outcome.
// ───────────────────────────────────────────────────────────────────────────
r = await cmd("debug.markerRename", { markerId: idA });
ck("B1 reopened the same marker (the staged override was released after A)",
  r.ok && r.result?.fieldOpenMarkerId === idA, JSON.stringify(r.result ?? r.error));
s = await field();
ck("B2 draft seeded from the current name", s.fieldText === "Padded", JSON.stringify(s.fieldText));

await cmd("marker.rename", { markerId: idA, name: "Verse" });
s = await field();
ck("B3 POSITIVE CONTROL: draft 'Padded' vs model 'Verse'",
  s.fieldText === "Padded" && (await names())[0] === "Verse", JSON.stringify(s.fieldText));

r = await cmd("debug.markerRename", { cancel: true });
ck("B4 cancel ok, action=cancel, handler ran on that draft",
  r.ok && r.result?.action === "cancel" && r.result?.resolution?.action === "cancel" &&
  r.result?.resolution?.draft === "Padded", JSON.stringify(r.result ?? r.error));
ck("B5 cancel committed NOTHING", r.result?.resolution?.committedName === null,
  JSON.stringify(r.result?.resolution));
ck("B6 ⭐ marker.list still reads Verse — the draft was reverted, not applied",
  (await names())[0] === "Verse", JSON.stringify(await names()));
s = await field();
ck("B7 focus really left the field", s.firstResponder === "none", JSON.stringify(s));

// ───────────────────────────────────────────────────────────────────────────
// LEG C — CLEAR. Pins the MEASURED behaviour: teardown DISCARDS the draft, and
// runs NEITHER handler. If a future SwiftUI ever delivers the focus-loss
// .onChange during teardown, this leg is what notices.
// ───────────────────────────────────────────────────────────────────────────
r = await cmd("debug.markerRename", { markerId: idA });
ck("C1 reopened", r.ok && r.result?.fieldOpenMarkerId === idA, JSON.stringify(r.result ?? r.error));
await cmd("marker.rename", { markerId: idA, name: "Chorus" });
s = await field();
ck("C2 POSITIVE CONTROL: draft 'Verse' vs model 'Chorus'",
  s.fieldText === "Verse" && (await names())[0] === "Chorus", JSON.stringify(s.fieldText));

r = await cmd("debug.markerRename", { clear: true });
ck("C3 clear ok, action=clear", r.ok && r.result?.action === "clear",
  JSON.stringify(r.result ?? r.error));
ck("C4 ⭐ NO handler ran at all — resolution is null, not a commit and not a cancel",
  r.result?.resolution === null, JSON.stringify(r.result?.resolution));
ck("C5 ⭐ marker.list still reads Chorus — the draft was DISCARDED",
  (await names())[0] === "Chorus", JSON.stringify(await names()));
s = await field();
ck("C6 clear still resigns the field editor (the m23-ba property)",
  s.firstResponder === "none", JSON.stringify(s));

// ───────────────────────────────────────────────────────────────────────────
// LEG T — the TRAP, kept as a passing leg so nobody re-derives it the hard way:
// a WHITESPACE-ONLY draft leaves the marker's name unchanged whether the
// resolution committed or discarded, so an experiment built on one proves
// nothing about which path ran. Here the commit handler demonstrably RAN
// (resolution.action === "commit") and still changed nothing, because the
// trim/empty-cancel rule dropped the draft.
//
// ⚠️ NO POSTED KEYSTROKES. The first cut of this leg typed two spaces (the
// m17-d shape) and asserted the draft was "  " — m17-d's own measurement. It
// came back " " on the very first run in this same session: whether the second
// posted space appends or replaces depends on where the field editor's
// selection sits when it lands, which is TIMING, not product behaviour, and a
// nondeterministic leg in a deterministic corpus is a future red for no reason.
// `ProjectStore.addMarker` does not trim and `"   ".isEmpty == false`, and the
// wire's `marker.add` has no whitespace guard (only `marker.rename` does), so a
// whitespace-only draft is available with ZERO events. T1 proves that.
// ───────────────────────────────────────────────────────────────────────────
r = await cmd("marker.add", { beat: 48, name: "   " });
const idT = r.result?.id;
let markerNames = await names();
ck("T1 a whitespace-only marker name survives marker.add verbatim (no typing needed)",
  r.ok && markerNames.includes("   "), JSON.stringify(markerNames));

r = await cmd("debug.markerRename", { markerId: idT });
ck("T2 opened on it", r.ok && r.result?.fieldOpenMarkerId === idT,
  JSON.stringify(r.result ?? r.error));
s = await field();
ck("T3 the draft is whitespace-only", s.fieldText === "   ", JSON.stringify(s.fieldText));

r = await cmd("debug.markerRename", { commit: true });
ck("T4 the commit handler RAN on that draft",
  r.result?.resolution?.action === "commit" && r.result?.resolution?.draft === "   ",
  JSON.stringify(r.result?.resolution));
ck("T5 …and the commit rule DROPPED it (empty after trim)",
  r.result?.resolution?.committedName === null, JSON.stringify(r.result?.resolution));
markerNames = await names();
ck("T6 ⚠️ the name is unchanged even though commit RAN — this is why a whitespace draft cannot discriminate",
  markerNames.includes("   ") && markerNames[0] === "Chorus", JSON.stringify(markerNames));

// ───────────────────────────────────────────────────────────────────────────
// LEG V — validation floor (m23-ah: a misspelled request must never get a
// success-shaped response), and the m23-ah-6 half-application check.
// ───────────────────────────────────────────────────────────────────────────
const refuse = async (name, params, needle) => {
  const res = await cmd("debug.markerRename", params);
  const err = String(res.error ?? "");
  ck(name, res.ok !== true && err.includes(needle), JSON.stringify(res.error ?? res.result));
};

// Nothing is open right now (T committed).
await refuse("V1 commit with no field open is refused", { commit: true }, "'commit'");
await refuse("V2 cancel with no field open is refused", { cancel: true }, "'cancel'");
await refuse("V3 unknown key refused by name", { commmit: true }, "'commmit'");
await refuse("V4 unknown key teaches the valid set", { nope: 1 }, "valid keys are");
await refuse("V5 a recognized key with the wrong TYPE is refused, not read as absent",
  { clear: "true" }, "must be true or false");
await refuse("V6 a non-string markerId is refused", { markerId: 7 }, "must be a marker-id string");
await refuse("V7 an unknown markerId is refused", { markerId: "00000000-0000-0000-0000-000000000000" },
  "no marker with id");

r = await cmd("debug.markerRename", { markerId: idA });
ck("V8 opened for the conflict checks", r.ok && r.result?.fieldOpenMarkerId === idA,
  JSON.stringify(r.result ?? r.error));
await refuse("V9 two modes at once refused", { commit: true, cancel: true }, "different outcomes");
await refuse("V10 markerId + a mode refused", { markerId: idA, commit: true }, "separate calls");

// ⭐ m23-ah-6: VALIDATE EVERY INPUT BEFORE MUTATING ON ANY OF THEM. The two
// refusals above were issued while a field was open; if the seam had staged
// anything before refusing, the field would now be gone.
r = await cmd("debug.markerRename", {});
ck("V11 ⭐ no half-application: the field refused-against is STILL open, unchanged",
  r.ok && r.result?.fieldOpenMarkerId === idA, JSON.stringify(r.result ?? r.error));
await cmd("debug.markerRename", { clear: true });

// `{}` on a project with no markers used to answer ok with renamingMarkerId:null
// — a success-shaped failure for a request that opened nothing.
r = await cmd("project.new");
ck("V12 project.new", r.ok, r.error);
await refuse("V13 a bare request with no markers is refused", {}, "marker.add");

// clear stays idempotent with nothing open — four gates rely on that.
r = await cmd("debug.markerRename", { clear: true });
ck("V14 clear is still legal with nothing open", r.ok && r.result?.action === "clear",
  JSON.stringify(r.result ?? r.error));

r = await cmd("project.new");
ck("V15 normalized", r.ok, r.error);
console.log(`M23BA1_MARKER_RENAME_GATE pass=${pass} fail=${fail}`);
ws.close();
stopStaging(GATE);
process.exit(fail ? 1 : 0);
