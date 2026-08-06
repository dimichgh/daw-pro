// m23-do GATE — the PERMANENT menu-enumeration gate. `Sources/DAWApp` has no
// test target, so every menu item this app ships has, until now, been
// verified either not at all or by a throwaway shell one-liner: `grep -rln
// 'mainMenu' scripts/gates/` finds NOTHING, which means m23-cf's Edit-menu
// check and m23-dd's File-menu check were both run once by hand and
// discarded. This makes that recipe permanent so a menu regression is caught
// by `./scripts/gates` corpus runs, not by a user reporting a dead item.
//
// Staging 17695 ONLY; 17600 is the user's LIVE app and is never touched
// (`assertStagingPort` enforces this, not caller discipline). Staging is
// killed PIDFILE-EXACT via `stopStaging`, never pkill/pgrep.
//
// ── THE RECIPE (proven end-to-end at m23-dd, 2026-08-05) ─────────────────────
// Ask the macOS accessibility API, through System Events, for the names of
// every item in a menu:
//
//   osascript -e 'tell application "System Events" to tell process "DAWApp"
//     to get name of every menu item of menu 1 of menu bar item "File" of
//     menu bar 1'
//
// Separators come back as the literal text `missing value`. This is the ONLY
// way to prove a menu item is actually mounted by SwiftUI — everything else
// in this tree (`EditorSurfaceOwnershipSiteTests`-style tests) reads the
// `Commands` source as TEXT and proves the code SAYS the right thing, never
// that it RENDERS.
//
// ── ⚠️⚠️ WHY THIS IS A GATE AND NOT A SCRIPT ─────────────────────────────────
// A broken accessibility query and an absent menu item return THE SAME
// nothing. If AX permission is denied, the process name is wrong, or a menu
// bar item's title changed, the query errors or comes back empty — which
// reads exactly like "the item under test is missing" (a red that means
// something completely different) or, depending on how sloppily the assertion
// is written, exactly like a clean pass (a query that can't find anything
// passes every "is X absent" check for free). This project has shipped that
// mistake before (see the gate-laws memory on synthetic probes the tool never
// reads). So this gate carries BOTH controls, and both are asserted checks
// that can go RED on their own:
//
//   POSITIVE CONTROL (AX0) — known-shipping File items ("New Project",
//   "Save As…") must come back in the SAME query used for everything else
//   below. If this fails, every downstream check is reported as "AX
//   enumeration failed", NOT as "item missing" — those are different defects
//   with different fixes, and the gate throws immediately after AX0/AX1/AX2
//   rather than let a broken query manufacture N more misleading reds.
//
//   NEGATIVE CONTROL (AX1, AX2) — a menu bar item that does not exist
//   ("Nonexistent"), and an item name that does not exist inside a REAL menu,
//   must both report `exists = false`. `exists` is used here rather than
//   catching a thrown error from `get name of …`, because it is the query
//   shape every absence assertion below actually uses — proving the SAME
//   primitive discriminates presence from absence, not a different one that
//   merely happens to also fail.
//
// A gate that cannot fail is worse than no gate — this one is proven to fail
// at the bottom of this file's history (see the m23-do close-out report for
// the deliberate-failure run).
//
// ── WHAT IS ASSERTED, AND WHY EACH IS STABLE ─────────────────────────────────
//   FILE — Export Audio… and Export MIDI… (m23-dd, `FileCommands.swift`)
//   present and ADJACENT with nothing between them, and the whole 2×2 import/
//   export block (Import Audio…, Import MIDI…, Export Audio…, Export MIDI…)
//   in that exact consecutive order — this is the block `FileCommands.swift`'s
//   own comment describes as "reads as a 2×2" with neither a Divider nor any
//   other item allowed to land inside it.
//
//   EDIT — the m23-cf Delete item. Its title is DYNAMIC (folds in a live
//   count: "Delete 3 Clips"), so this gate does not chase that — it asserts
//   `DeleteMenuPolicy.inertTitle` ("Delete Selection"), the title the item
//   carries when nothing is selected. That is exactly the state a freshly
//   launched, freshly-`project.new`'d staging instance is in, so it is
//   reachable without building any selection fixture, and it will not drift
//   under a count that this gate never manufactures. Its DISABLED state is
//   asserted alongside it for the same reason: "greyed with nothing selected"
//   is the other half of the same stable default.
//
// ⚠️ NO KEYBOARD SHORTCUTS ARE ASSERTED, ANYWHERE. m23-g1: an unbundled
// staging binary does not route real key events, so a shortcut's PRESENCE
// cannot be verified this way, and m23-dd deliberately shipped Export
// Audio… with NO shortcut — asserting one would encode a false expectation.
//
// Usage:
//   node scripts/gates/m23do-menubar.mjs
import fs from "fs";
import { execFileSync } from "node:child_process";
import { launchStaging, stopStaging } from "./_staging.mjs";

const GATE = "m23do";
const PORT = process.env.DAW_CONTROL_PORT || "17695";
const OUT = process.env.M23DO_OUT || "/tmp/m23do";
const PIDFILE = process.env.M23DO_PIDFILE || "/tmp/m23do-staging.pid";
const BINARY = process.env.M23DO_BINARY || ".build/debug/DAWApp";
const PROCESS_NAME = "DAWApp"; // the executable name, NOT "DAWPro" — measured at m23-bx-1

fs.mkdirSync(OUT, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const killer = setTimeout(() => { console.error("TIMEOUT"); process.exit(2); }, 300_000);

const checks = [];
const check = (name, ok, detail) => {
  checks.push({ name, ok, detail });
  console.log(`  ${ok ? "ok  " : "!!  "} ${name}\n        ${detail}`);
};

// ── the ONE osascript primitive every check below is built from ────────────
// Never throws: a thrown AppleScript error and a clean empty result are two
// DIFFERENT failure shapes and callers need to be able to tell them apart, so
// both are captured and returned rather than one being swallowed into the
// other.
function osa(script) {
  try {
    const out = execFileSync("/usr/bin/osascript", ["-e", script], { encoding: "utf8" });
    return { ok: true, out: out.replace(/\n$/, ""), error: null };
  } catch (e) {
    const stderr = (e.stderr ?? "").toString().trim();
    return { ok: false, out: (e.stdout ?? "").toString().trim(), error: stderr || e.message };
  }
}

/// Every item NAME in one menu-bar menu, in order. Separators come back as
/// the literal string "missing value". Splits on ", " — safe here because no
/// item title in this app contains a comma; a future title that did would
/// need a different query shape (e.g. `count` + indexed `item n`), not a
/// smarter split.
function axMenuItems(menuBarTitle) {
  const script = `tell application "System Events" to tell process "${PROCESS_NAME}" `
    + `to get name of every menu item of menu 1 of menu bar item "${menuBarTitle}" of menu bar 1`;
  const r = osa(script);
  if (!r.ok) return { ok: false, items: [], error: r.error };
  const items = r.out.length ? r.out.split(", ") : [];
  return { ok: true, items, error: null };
}

/// `exists` for a top-level menu-bar item. Deliberately the SAME primitive
/// shape (`exists …`) that `axItemExists` below uses for an item nested
/// inside a real menu — the negative controls must exercise the identical
/// query family that a real absence assertion would use.
function axMenuBarItemExists(title) {
  const script = `tell application "System Events" to tell process "${PROCESS_NAME}" `
    + `to exists menu bar item "${title}" of menu bar 1`;
  return osa(script);
}

/// `exists` for a named item inside a real menu.
function axItemExists(menuBarTitle, itemTitle) {
  const script = `tell application "System Events" to tell process "${PROCESS_NAME}" to exists `
    + `menu item "${itemTitle}" of menu 1 of menu bar item "${menuBarTitle}" of menu bar 1`;
  return osa(script);
}

/// `enabled` of a named item inside a real menu — "true"/"false" text.
function axItemEnabled(menuBarTitle, itemTitle) {
  const script = `tell application "System Events" to tell process "${PROCESS_NAME}" to get `
    + `enabled of menu item "${itemTitle}" of menu 1 of menu bar item "${menuBarTitle}" of menu bar 1`;
  return osa(script);
}

/// True iff `needle` occurs as a CONSECUTIVE run inside `haystack`, at the
/// SAME relative order — used for the "2x2 block, nothing between" claim,
/// which a plain `includes()` per item cannot express (four items can all be
/// present and still have a Divider or a fifth item wedged inside the block).
function hasConsecutiveRun(haystack, needle) {
  for (let i = 0; i + needle.length <= haystack.length; i++) {
    if (needle.every((v, j) => haystack[i + j] === v)) return true;
  }
  return false;
}

let staging = null;
try {
  staging = await launchStaging({
    gate: GATE, port: Number(PORT), binary: BINARY, pidfile: PIDFILE, outDir: OUT,
    detached: true, settleMs: 1500,
  });
  console.log(`staging pid ${staging.pid} on :${PORT}`);

  // Fresh, deterministic model state: no undo history (Undo/Redo read bare),
  // no selection (Edit's Delete item reads its INERT default). Nothing else
  // below depends on tracks or clips existing.
  let nextId = 1;
  const pending = new Map();
  staging.ws.onmessage = (ev) => {
    let m; try { m = JSON.parse(ev.data); } catch { return; }
    const e = pending.get(m.id); if (!e) return; pending.delete(m.id);
    if (m.ok === false || m.error) e.reject(new Error(`${e.command}: ${JSON.stringify(m.error)}`));
    else e.resolve(m.result ?? m);
  };
  const req = (command, params = {}) => {
    const id = String(nextId++);
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject, command });
      staging.ws.send(JSON.stringify({ id, command, params }));
      setTimeout(() => { if (pending.has(id)) { pending.delete(id); reject(new Error(`timeout ${command}`)); } }, 15000);
    });
  };
  await req("project.new", { discardChanges: true });
  await sleep(1000); // let the @Observable menu bodies re-evaluate

  // Defensive, not part of the proven recipe: bring the process frontmost so
  // this is robust on a machine where staging launched behind something else.
  // The m23-dd recipe worked without this; it is added because it can only
  // help and costs one extra osascript call.
  osa(`tell application "System Events" to set frontmost of process "${PROCESS_NAME}" to true`);
  await sleep(300);

  // ══ AX0/AX1/AX2 — the controls. If ANY of these fail, everything below is ═
  // ══ reported as "AX enumeration failed", not "item missing".            ═══
  const file = axMenuItems("File");
  const ax0ok = file.ok && file.items.includes("New Project") && file.items.includes("Save As…");
  check("AX0 POSITIVE CONTROL: known-shipping File items come back in the SAME query "
        + "every assertion below reuses — a failure here means the accessibility query "
        + "itself is broken (permission, process name, menu title), NOT that a menu item "
        + "is missing",
        ax0ok,
        file.ok ? `items=${JSON.stringify(file.items)}` : `AX QUERY THREW: ${file.error}`);

  const ax1 = axMenuBarItemExists("Nonexistent");
  const ax1ok = ax1.ok && ax1.out === "false";
  check("AX1 NEGATIVE CONTROL: a menu-bar item that does not exist ('Nonexistent') reports "
        + "exists=false — proves the query can tell absence from presence at the top level; "
        + "without this a query that always answers 'yes' would pass every positive check for "
        + "free",
        ax1ok, `raw=${JSON.stringify(ax1.out)} ok=${ax1.ok} error=${ax1.error ?? "none"}`);

  const ax2 = axItemExists("File", "ThisMenuItemDoesNotExist12345");
  const ax2ok = ax2.ok && ax2.out === "false";
  check("AX2 NEGATIVE CONTROL: a nonexistent item name INSIDE the real File menu also reports "
        + "exists=false — same primitive the FILE/EDIT checks below use for absence, exercised "
        + "on a menu we know is real rather than a fabricated menu-bar title",
        ax2ok, `raw=${JSON.stringify(ax2.out)} ok=${ax2.ok} error=${ax2.error ?? "none"}`);

  if (!ax0ok || !ax1ok || !ax2ok) {
    throw new Error("AX ENUMERATION FAILED — one or more controls did not discriminate "
      + "presence from absence. Every check below would be meaningless (a missing item and a "
      + "broken query look identical), so the gate stops here rather than reporting misleading "
      + "reds for FILE/EDIT. Check: accessibility permission for the process running this gate "
      + "(System Settings > Privacy & Security > Accessibility), that a DAWApp process is "
      + `actually running on :${PORT}, and that "${PROCESS_NAME}" is still the AX process name `
      + "(it is the bare executable name, not the .app bundle name — see m23-bx-1).");
  }

  // ══ FILE — m23-dd (Export Audio…) + the pre-existing Export MIDI… ══════════
  check("FILE1 Export Audio… and Export MIDI… are BOTH present in the File menu",
        file.items.includes("Export Audio…") && file.items.includes("Export MIDI…"),
        `items=${JSON.stringify(file.items)}`);

  const exportAudioIdx = file.items.indexOf("Export Audio…");
  const exportMidiIdx = file.items.indexOf("Export MIDI…");
  check("FILE2 Export Audio… and Export MIDI… sit ADJACENT with nothing between them "
        + "(source has no Divider or other item between the two Buttons)",
        exportAudioIdx >= 0 && exportMidiIdx === exportAudioIdx + 1,
        `Export Audio… at index ${exportAudioIdx}, Export MIDI… at index ${exportMidiIdx}`);

  const importExportBlock = ["Import Audio…", "Import MIDI…", "Export Audio…", "Export MIDI…"];
  check("FILE3 the whole 2×2 import/export block reads as FOUR CONSECUTIVE items in that exact "
        + "order — FileCommands.swift's own comment describes this shape; a Divider, a reorder, "
        + "or a fifth item landing inside it would break this without breaking FILE1/FILE2",
        hasConsecutiveRun(file.items, importExportBlock),
        `expected consecutive run ${JSON.stringify(importExportBlock)} in ${JSON.stringify(file.items)}`);

  check("FILE4 New Project and Save As… are still present (re-asserted as a substantive claim, "
        + "not just AX0's control — a menu missing its own core items while still answering the "
        + "control query is a real, distinct regression)",
        file.items.includes("New Project") && file.items.includes("Save As…"),
        `items=${JSON.stringify(file.items)}`);

  // ══ EDIT — m23-cf's Delete item, asserted at its STABLE default ═══════════
  const edit = axMenuItems("Edit");
  check("EDIT1 the Edit menu enumerates at all (second AX0-shaped sanity check, on a different "
        + "menu bar item — File answering does not guarantee Edit does)",
        edit.ok && edit.items.length > 0,
        edit.ok ? `items=${JSON.stringify(edit.items)}` : `AX QUERY THREW: ${edit.error}`);

  const { inertTitle } = { inertTitle: "Delete Selection" }; // see note below
  check(`EDIT2 Edit menu contains ${JSON.stringify(inertTitle)} — DeleteMenuPolicy.inertTitle `
        + "(Sources/DAWAppKit/DeleteMenuPolicy.swift), the title m23-cf's Delete item carries "
        + "with NOTHING selected. Asserted rather than the live-count titles ('Delete 3 Clips') "
        + "because this is the one state reachable with no selection fixture, and it is the "
        + "state a fresh project.new leaves the app in — genuinely stable, not merely convenient",
        edit.ok && edit.items.includes(inertTitle),
        `items=${JSON.stringify(edit.items)}`);

  const enabledR = axItemEnabled("Edit", inertTitle);
  check(`EDIT3 ${JSON.stringify(inertTitle)} is DISABLED with nothing selected — the other half `
        + "of the same stable default (DeleteMenuPolicy.editMenuItem returns refusedBy: "
        + ".emptySelection when arrangeClipCount is 0), cheap to check and would catch a policy "
        + "regression that left the title right but the item live",
        enabledR.ok && enabledR.out === "false",
        `raw=${JSON.stringify(enabledR.out)} ok=${enabledR.ok} error=${enabledR.error ?? "none"}`);

  check("EDIT4 the native pasteboard Delete item ('Delete') is ALSO present and distinct from "
        + "'Delete Selection' — DeleteMenuPolicy's own doc comment records this as a MEASURED "
        + "collision reason (a bare 'Delete' title would have produced two adjacent items both "
        + "reading 'Delete'); this checks the disambiguation actually shipped, not just that our "
        + "own item exists",
        edit.ok && edit.items.includes("Delete") && edit.items.includes(inertTitle)
        && edit.items.indexOf("Delete") !== edit.items.indexOf(inertTitle),
        `items=${JSON.stringify(edit.items)}`);

  check("EDIT5 Undo reads bare 'Undo' (no history yet, right after project.new) — a cheap "
        + "sanity check on the OTHER CommandGroup this file replaces; a menu that lost its "
        + "Undo/Redo group entirely would still pass EDIT1/EDIT2 without this",
        edit.ok && edit.items.includes("Undo") && edit.items.includes("Redo"),
        `items=${JSON.stringify(edit.items)}`);

} catch (e) {
  check("GATE did not throw", false, e?.stack ?? e?.message ?? String(e));
} finally {
  clearTimeout(killer);
  try { staging?.ws?.close(); } catch { /* best effort */ }
  await sleep(300);
  try { stopStaging(GATE, PIDFILE); } catch (e) { console.log("stopStaging: " + e?.message); }
  await sleep(300);
}

fs.writeFileSync(`${OUT}/results.json`, JSON.stringify(checks, null, 2));
const pass = checks.filter((c) => c.ok).length;
console.log(`\nM23DO ${pass}/${checks.length}`);
process.exit(pass === checks.length ? 0 : 1);
