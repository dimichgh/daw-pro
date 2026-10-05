#!/usr/bin/env node
// Static check that every demo spec is EXECUTABLE before a build is spent on it.
//
// WHY THIS EXISTS. `render-variants.mjs` builds the whole Swift package before it
// runs a single command, so a spec naming a command `DemoRender` does not
// implement costs a full build to discover — and the error arrives after the
// build output, where it reads like a compiler problem. Worse, a spec that runs
// but varies nothing renders N byte-identical files, which is a *silent* failure
// of the thing the demo exists to show. Twice in one night an axis that reported
// success at every layer turned out to change no audio at all.
//
// This gate answers the cheap half of that question — "could this spec possibly
// do what it claims" — in milliseconds and with no build. The expensive half,
// "did the audio actually change", stays where it belongs: in the harness's
// byte-identity guard, which no static check can replace.
//
// SELF-POSITIVE-CONTROLLING, per this tree's rule that a probe returning nothing
// must first be shown capable of returning something: the supported-command set
// is asserted to contain a command that must exist and to exclude one that must
// not, and the gate exits 3 WITHOUT scoring if either control fails. A green run
// therefore means "checked", never "the parser quietly matched nothing".

import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

const SPEC_DIR = "scripts/demos/specs";
const RENDERER = "Sources/DemoRender/DemoRender.swift";

// The commands DemoRender actually implements, read from its own switch, so this
// can never drift from the renderer the way a hand-maintained list would.
const source = readFileSync(RENDERER, "utf8");
const supported = new Set(
  [...source.matchAll(/case "([a-zA-Z]+\.[a-zA-Z]+)":/g)].map((m) => m[1])
);

// ---- controls, before any scoring -----------------------------------------
const MUST_EXIST = "track.add";
const MUST_NOT_EXIST = "track.definitelyNotAVerb";
if (!supported.has(MUST_EXIST) || supported.has(MUST_NOT_EXIST)) {
  console.error(
    `control failed — the command parser matched ${supported.size} commands but ` +
      `${MUST_EXIST}=${supported.has(MUST_EXIST)} and ` +
      `${MUST_NOT_EXIST}=${supported.has(MUST_NOT_EXIST)}. ` +
      `Refusing to score: a broken parser would pass every spec.`
  );
  process.exit(3);
}
console.log(
  `positive control OK — the switch parser finds ${supported.size} commands, ` +
    `including ${MUST_EXIST}, and does not invent ${MUST_NOT_EXIST}\n`
);

// ---- score every spec ------------------------------------------------------
let failures = 0;
const specs = readdirSync(SPEC_DIR).filter((f) => f.endsWith(".json")).sort();

for (const file of specs) {
  let spec;
  try {
    spec = JSON.parse(readFileSync(join(SPEC_DIR, file), "utf8"));
  } catch (err) {
    console.log(`✘ ${file.padEnd(26)} INVALID JSON — ${err.message}`);
    failures++;
    continue;
  }

  const variants = spec.variants ?? [];
  const names = variants.map((v) => v.name ?? "<unnamed>");
  const used = new Set();
  for (const v of variants) for (const c of v.commands ?? []) used.add(c.command);

  const issues = [];
  const unknown = [...used].filter((c) => !supported.has(c)).sort();
  if (unknown.length) issues.push(`unsupported command(s): ${unknown.join(", ")}`);

  const dupes = [...new Set(names.filter((n, i) => names.indexOf(n) !== i))];
  if (dupes.length) issues.push(`duplicate variant name(s): ${dupes.join(", ")}`);

  // A one-variant set cannot demonstrate an axis: there is nothing to compare it
  // against, so nothing the byte-identity guard could ever catch.
  if (variants.length < 2) issues.push("fewer than 2 variants — no axis to hear");

  // Not fatal: a set with no control is legal but weaker, because "different
  // from what?" has no answer in the rendered output.
  const controls = variants.filter((v) => v.role === "control").length;
  const note = controls === 0 ? "  (no variant marked role:control)" : "";

  if (issues.length) {
    failures++;
    console.log(`✘ ${file.padEnd(26)} ${issues.join("; ")}`);
  } else {
    console.log(
      `✔ ${file.padEnd(26)} ${String(variants.length).padStart(2)} variants, ` +
        `${used.size} distinct command(s)${note}`
    );
  }
}

console.log();
if (failures) {
  console.error(
    `✘ ${failures} of ${specs.length} spec(s) would fail at render time — fix the ` +
      `spec, or add the missing case to ${RENDERER}.`
  );
  process.exit(1);
}
console.log(`✔ all ${specs.length} demo spec(s) are executable as written.`);
