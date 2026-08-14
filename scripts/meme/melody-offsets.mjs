#!/usr/bin/env node
/**
 * melody-offsets — turn a tune into the `clip_set_stretch` calls that play it
 * on a single voice fragment.
 *
 * WHY THIS EXISTS
 * ---------------
 * The Kiffness move is to take ONE syllable and pitch it into a melody. Because
 * `clip.detectPitch` does not ship yet, you do NOT know what pitch the source
 * fragment actually is — and you do not need to. A melody is a set of RELATIVE
 * intervals, so every offset here is measured **from the first note**, which
 * means note 1 is always `semitones: 0` = the fragment untouched.
 *
 * Feed the output straight into:
 *     clip_duplicate   { trackId, clipId, atBeat }
 *     clip_set_stretch { trackId, clipId, ratio, semitones, formantPreserve }
 *
 * USAGE
 *   node scripts/meme/melody-offsets.mjs --notes "C4 E4 G4 E4 C4"
 *   node scripts/meme/melody-offsets.mjs --preset twinkle --grid 0.5
 *   node scripts/meme/melody-offsets.mjs --scale minorPentatonic --octaves 1
 *   node scripts/meme/melody-offsets.mjs --degrees "1 3 5 3 1" --scale major
 *   node scripts/meme/melody-offsets.mjs --notes "C4 D4 E4" --transpose -5 --json
 *
 * OPTIONS
 *   --notes "<note...>"   Note names: C4 D#4 Eb5 F#3 ... (rests: "-" or "r")
 *   --degrees "<n...>"    Scale degrees 1-based, needs --scale
 *   --scale <name>        Scale for --degrees / --scale-only mode
 *   --preset <name>       A canned melody (see --list)
 *   --octaves <n>         With --scale alone: how many octaves to run (default 1)
 *   --grid <beats>        Beats per note (default 0.5 = eighths)
 *   --start <beat>        Beat of the first note (default 0)
 *   --swing <50..75>      Delay the offbeats, MPC style (default 50 = straight)
 *   --transpose <n>       Add a constant to every offset — moves the whole vocal
 *                         into the backing's key WITHOUT changing the melody
 *   --json                Emit JSON only (default prints a table too)
 *   --list                List presets and scales, then exit
 */

const SEMI = { c: 0, d: 2, e: 4, f: 5, g: 7, a: 9, b: 11 };

const SCALES = {
  major:            [0, 2, 4, 5, 7, 9, 11],
  minor:            [0, 2, 3, 5, 7, 8, 10],
  harmonicMinor:    [0, 2, 3, 5, 7, 8, 11],
  dorian:           [0, 2, 3, 5, 7, 9, 10],
  mixolydian:       [0, 2, 4, 5, 7, 9, 10],
  phrygian:         [0, 1, 3, 5, 7, 8, 10],
  majorPentatonic:  [0, 2, 4, 7, 9],
  minorPentatonic:  [0, 3, 5, 7, 10],
  blues:            [0, 3, 5, 6, 7, 10],
  chromatic:        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
};

// Canned melodies, written as offsets from the first note so they work on any source.
const PRESETS = {
  twinkle:    { offsets: [0, 0, 7, 7, 9, 9, 7, -1, 5, 5, 4, 4, 2, 2, 0], grid: 0.5,
                note: "Twinkle Twinkle — instantly readable, the safest meme melody" },
  scaleUp:    { offsets: [0, 2, 4, 5, 7, 9, 11, 12], grid: 0.25,
                note: "Major scale run — good for a riser or a fill" },
  pentaHook:  { offsets: [0, 3, 5, 7, 5, 3, 0], grid: 0.25,
                note: "Minor-pentatonic there-and-back — nothing can clash with it" },
  bassRiff:   { offsets: [0, 0, 12, 0, 0, 10, 0, 7], grid: 0.25,
                note: "Octave-jump bass riff — put the fragment down 12 first" },
  chantHook:  { offsets: [0, 0, 0, 5, 0, 0, -2, 0], grid: 0.5,
                note: "Football-chant shape — repetition with two answer notes" },
  sadTrombone:{ offsets: [0, -1, -2, -3], grid: 0.75,
                note: "Descending — the 'wah wah wah waaah' payoff" },
  airhorn:    { offsets: [0, 12, 0, 12, 0, 12], grid: 0.125,
                note: "Fast octave alternation — the drop stinger" },
};

// ---------------------------------------------------------------- arg parsing
function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) continue;
    const key = a.slice(2);
    const next = argv[i + 1];
    if (next === undefined || next.startsWith("--")) out[key] = true;
    else { out[key] = next; i++; }
  }
  return out;
}

function die(msg) {
  console.error(`error: ${msg}\n\nRun with --help for usage.`);
  process.exit(1);
}

/** "C4" | "D#5" | "Eb3" -> absolute semitone number. Rests -> null. */
function noteToSemitone(tok) {
  const t = tok.trim();
  if (t === "-" || t.toLowerCase() === "r") return null;
  const m = /^([A-Ga-g])([#b]*)(-?\d+)$/.exec(t);
  if (!m) die(`cannot parse note "${tok}" (expected like C4, D#5, Eb3, or - for a rest)`);
  const [, letter, accidentals, octave] = m;
  let v = SEMI[letter.toLowerCase()];
  for (const ch of accidentals) v += ch === "#" ? 1 : -1;
  return v + (parseInt(octave, 10) + 1) * 12;
}

// ---------------------------------------------------------------- main
const args = parseArgs(process.argv.slice(2));

if (args.help) {
  console.log(`
melody-offsets — turn a tune into the clip_set_stretch calls that play it on one
                 voice fragment. Offsets are RELATIVE to the first note, so you
                 never need to know the source fragment's actual pitch.

USAGE
  --notes "C4 E4 G4"     Note names; "-" or "r" is a rest
  --degrees "1 3 5"      Scale degrees (1-based), used with --scale
  --scale <name>         Scale for --degrees, or on its own to run the scale
  --preset <name>        A canned melody            (--list to see them)
  --octaves <n>          With --scale alone (default 1)
  --grid <beats>         Beats per note             (default 0.5 = eighths)
  --start <beat>         Beat of the first note     (default 0)
  --swing <50..75>       Delay the offbeat slots    (default 50 = straight)
  --transpose <n>        Constant added to every offset — moves the whole vocal
                         into the backing's key WITHOUT changing the melody
  --json                 Machine-readable output
  --list                 Show presets and scales

FEEDING THE RESULT BACK
  each step -> clip_duplicate   { clipId, toStartBeat: <beat>, toTrackId }
               clip_set_stretch { trackId, clipId, ratio, semitones, formantPreserve }
`);
  process.exit(0);
}

if (args.list) {
  console.log("PRESETS");
  for (const [name, p] of Object.entries(PRESETS)) {
    console.log(`  ${name.padEnd(12)} ${p.offsets.length} notes  — ${p.note}`);
  }
  console.log("\nSCALES");
  for (const [name, s] of Object.entries(SCALES)) {
    console.log(`  ${name.padEnd(18)} [${s.join(", ")}]`);
  }
  process.exit(0);
}

let offsets = null;
let grid = args.grid !== undefined ? Number(args.grid) : null;

if (args.preset) {
  const p = PRESETS[args.preset];
  if (!p) die(`unknown preset "${args.preset}" — run --list to see them`);
  offsets = [...p.offsets];
  if (grid === null) grid = p.grid;
} else if (args.notes) {
  const toks = String(args.notes).trim().split(/\s+/);
  const abs = toks.map(noteToSemitone);
  const first = abs.find((v) => v !== null);
  if (first === undefined) die("--notes contained only rests");
  // Relative to the FIRST SOUNDING note — that note becomes semitones: 0.
  offsets = abs.map((v) => (v === null ? null : v - first));
} else if (args.degrees) {
  const scaleName = args.scale || "major";
  const scale = SCALES[scaleName];
  if (!scale) die(`unknown scale "${scaleName}" — run --list to see them`);
  offsets = String(args.degrees).trim().split(/\s+/).map((d) => {
    if (d === "-" || d.toLowerCase() === "r") return null;
    const n = parseInt(d, 10);
    if (!Number.isFinite(n) || n < 1) die(`degree "${d}" must be a positive integer`);
    const idx = (n - 1) % scale.length;
    const oct = Math.floor((n - 1) / scale.length);
    return scale[idx] + 12 * oct;
  });
} else if (args.scale) {
  const scale = SCALES[args.scale];
  if (!scale) die(`unknown scale "${args.scale}" — run --list to see them`);
  const octaves = args.octaves ? parseInt(args.octaves, 10) : 1;
  offsets = [];
  for (let o = 0; o < octaves; o++) for (const s of scale) offsets.push(s + 12 * o);
  offsets.push(12 * octaves); // land on the octave
} else {
  die("give one of --notes, --degrees, --preset or --scale (or --list)");
}

if (grid === null) grid = 0.5;
if (!Number.isFinite(grid) || grid <= 0) die("--grid must be a positive number of beats");

const start = args.start !== undefined ? Number(args.start) : 0;
if (!Number.isFinite(start)) die("--start must be a number");

const swing = args.swing !== undefined ? Number(args.swing) : 50;
if (!Number.isFinite(swing) || swing < 50 || swing > 75) die("--swing must be 50..75");

const transpose = args.transpose !== undefined ? Number(args.transpose) : 0;
if (!Number.isFinite(transpose)) die("--transpose must be a number");

// ---------------------------------------------------------------- build steps
// Swing delays every odd-indexed slot by a fraction of the grid, MPC style.
const swingShift = ((swing - 50) / 100) * grid * 2;

const steps = [];
const warnings = [];
offsets.forEach((off, i) => {
  if (off === null) return; // rest: emit nothing, the beat just stays empty
  const semitones = off + transpose;
  const beat = start + i * grid + (i % 2 === 1 ? swingShift : 0);
  if (semitones < -24 || semitones > 24) {
    warnings.push(
      `note ${i + 1}: ${semitones} semitones is outside clip_set_stretch's -24..24 range ` +
      `and WILL BE CLAMPED — use a different --transpose or drop the note`
    );
  }
  steps.push({
    index: i + 1,
    beat: Number(beat.toFixed(6)),
    semitones,
    ratio: 1,
    // Formants drift audibly once you shift more than a few semitones up.
    // Below ~-3 the voice gets 'boomy' rather than chipmunky, so preserve there too.
    formantPreserve: Math.abs(semitones) > 3,
  });
});

if (!steps.length) die("melody produced no sounding notes");

const result = {
  count: steps.length,
  gridBeats: grid,
  swing,
  transpose,
  lengthBeats: Number((steps.length * grid).toFixed(6)),
  note:
    "semitones are RELATIVE to the source fragment — note 1 is the fragment untouched. " +
    "For each step: clip_duplicate {clipId, toStartBeat: <beat>, toTrackId} then " +
    "clip_set_stretch {trackId, clipId, ratio, semitones, formantPreserve}. " +
    "NOTE `toStartBeat` — clip_duplicate does NOT take `atBeat`.",
  steps,
  warnings,
};

if (args.json) {
  console.log(JSON.stringify(result, null, 2));
} else {
  console.log(
    `\n${result.count} notes · grid ${grid} beats · ` +
    `${result.lengthBeats} beats long` +
    (transpose ? ` · transposed ${transpose > 0 ? "+" : ""}${transpose}` : "") +
    (swing !== 50 ? ` · swing ${swing}` : "") + "\n"
  );
  console.log("  #    beat   semitones   formantPreserve");
  console.log("  ---------------------------------------");
  for (const s of steps) {
    console.log(
      `  ${String(s.index).padStart(2)}  ${String(s.beat).padStart(6)}   ` +
      `${(s.semitones > 0 ? "+" : "") + s.semitones}`.padStart(9) +
      `   ${s.formantPreserve}`
    );
  }
  for (const w of warnings) console.log(`\n  ⚠️  ${w}`);
  console.log("\n  (--json for machine-readable output)\n");
}
