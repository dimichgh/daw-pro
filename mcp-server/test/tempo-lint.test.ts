/**
 * tempo-lint.test.ts — PERMANENT tempo-arithmetic lint (m12-b, design
 * condition 2: docs/research/design-m11f-tempo-map.md §10).
 *
 * `Sources/DAWCore/TempoMap.swift` is the ONE home of beat↔seconds
 * conversion. This suite mechanically scans every Swift source under
 * `Sources/` and FAILS on raw `60/tempo`-shaped arithmetic anywhere else,
 * so a new scalar conversion can never sneak in silently after the Phase-A
 * refactor. Precedent: audit-tools.test.ts already scans Swift sources from
 * the npm suite.
 *
 * What counts as a violation (comments stripped first): multiplicative
 * arithmetic that combines the literal 60 with a tempo-adjacent identifier —
 *   · `60 / <…tempo/bpm…>`            (seconds-per-beat)
 *   · `<…tempo/bpm…> / 60`            (beats-per-second)
 *   · `* 60 /` and `/ 60 *` shapes on a line that mentions tempo/bpm
 *     (the `fileRate * 60.0 / bpm` frames-per-beat idiom)
 *
 * Anchoring on tempo-adjacent identifiers keeps NON-tempo 60s quiet by
 * construction — these known benign sites never match and MUST stay that
 * way (do not "fix" them into the allowlist):
 *   · Sources/DAWCore/Model.swift `timeDisplay` — mm:ss clock math
 *     (`Int(total) / 60`, `% 60`): no tempo identifier on the line.
 *   · Sources/DAWApp/DiagnosticsReporter.swift:~158 — snapshot age in
 *     minutes: wall-clock, not tempo.
 *   · Sources/DAWApp/Components/VibeMeterView.swift:~193 — `1.0 / 60`
 *     frame-dt fallback: display refresh, not tempo.
 *
 * ALLOWLIST (every entry carries its removal phase; shrink-only):
 *   · Sources/DAWCore/TempoMap.swift — the sanctioned home for musical-time
 *     CONVERSION (permanent — the lint's end state per design §10
 *     condition 2 for project-timeline math; the estimator entry below is
 *     measurement, not conversion).
 *     Since m12-c this includes `framesPerBeat(atBeat:sampleRate:)`, the
 *     verbatim-op-order `rate * 60.0 / bpm` idiom ClipFadeBake's fast path
 *     uses (the former ClipFadeBake.swift entry died in Phase B as planned:
 *     fade baking is now piecewise across segment boundaries, and its
 *     constant-tempo fast path borrows the arithmetic from the map itself).
 *   · Sources/DAWEngine/Analysis/TempoEstimator.swift — m21-e tempo
 *     MEASUREMENT (permanent by nature): `envelopeRate * 60.0 / bpm`
 *     converts a candidate-BPM hypothesis to an ACF lag in onset-envelope
 *     bins while ESTIMATING the tempo of imported audio. The estimate is
 *     the input a project TempoMap might later be set from, so there is no
 *     map to route through — TempoMap describes the project timeline, not
 *     the audio being measured (design-clip-analyze-audio.md §4).
 *   · (m12-d Phase D removed the Sources/DAWApp/ContentView.swift entry — its
 *     waveform `60.0 / tempoBPM` now routes through
 *     `TempoMap.secondsPerBeat(atBeat:)`, so no UI consumer holds raw tempo
 *     arithmetic any more.)
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

// ---------------------------------------------------------------------------
// Repo discovery (same walk-up as audit-tools.test.ts — works from TS source
// and from dist-test/test/ compiled output).

function findMcpServerRoot(startDir: string): string {
  let dir = startDir;
  for (let i = 0; i < 12; i++) {
    const candidate = join(dir, "package.json");
    if (existsSync(candidate)) {
      try {
        const pkg = JSON.parse(readFileSync(candidate, "utf8")) as { name?: string };
        if (pkg.name === "daw-pro-mcp") return dir;
      } catch {
        // Not JSON, or unreadable — keep walking up.
      }
    }
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  throw new Error(`Could not locate mcp-server/ by walking up from ${startDir}.`);
}

function swiftFilesUnder(dir: string): string[] {
  const out: string[] = [];
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    const info = statSync(full);
    if (info.isDirectory()) out.push(...swiftFilesUnder(full));
    else if (entry.endsWith(".swift")) out.push(full);
  }
  return out;
}

// ---------------------------------------------------------------------------
// The scan. Allowlist paths are repo-relative (posix separators).

const ALLOWLIST = new Set<string>([
  "Sources/DAWCore/TempoMap.swift", // the one sanctioned CONVERSION home (permanent)
  // m21-e tempo MEASUREMENT (BPM hypothesis -> ACF lag) — see header block.
  "Sources/DAWEngine/Analysis/TempoEstimator.swift",
]);

/** Tempo-adjacent identifier: any identifier/member/subscript chain
 * containing tempo/bpm (`bpm` bare, `prev.bpm`, `segments[i].bpm`,
 * `transport.tempoBPM`, …), optionally a call suffix like `.bpm(atBeat: x)`.
 * Deliberately NOT matching bare numbers or non-tempo identifiers, so
 * clock/frame-rate 60s never false-positive. */
const TEMPO_ID = String.raw`[\w.\[\]]*(?:[Tt]empo|bpm|BPM)[\w.\[\]]*(?:\([^)]*\))?`;
const SIXTY = String.raw`60(?:\.0)?`;

const VIOLATION_PATTERNS: { name: string; regex: RegExp }[] = [
  {
    name: "seconds-per-beat (60 / tempo)",
    regex: new RegExp(String.raw`\b${SIXTY}\s*/\s*${TEMPO_ID}`),
  },
  {
    name: "beats-per-second (tempo / 60)",
    regex: new RegExp(String.raw`${TEMPO_ID}\s*/\s*${SIXTY}\b`),
  },
  {
    name: "frames-per-beat shape (* 60 / or / 60 * on a tempo line)",
    regex: new RegExp(
      String.raw`(?:\*\s*${SIXTY}\s*/|/\s*${SIXTY}\s*\*)`
    ),
    // Applied only to lines that also mention a tempo identifier — see scan().
  },
];

/** Strip `//`-comments (incl. doc comments) so prose describing the old
 * formulas — e.g. "placement formula `recordStart + offset × tempo/60`" —
 * can never trip the lint. String literals are rare in DSP code and a 60/
 * tempo inside one would still deserve a look, so they are NOT stripped. */
function stripLineComment(line: string): string {
  const idx = line.indexOf("//");
  return idx >= 0 ? line.slice(0, idx) : line;
}

test("raw tempo arithmetic exists nowhere outside TempoMap.swift (+ documented allowlist)", () => {
  const here = dirname(fileURLToPath(import.meta.url));
  const repoRoot = join(findMcpServerRoot(here), "..");
  const sourcesDir = join(repoRoot, "Sources");
  assert.ok(existsSync(sourcesDir), `Sources/ not found at ${sourcesDir}`);

  const violations: string[] = [];
  const allowlistHits = new Set<string>();

  for (const file of swiftFilesUnder(sourcesDir)) {
    const rel = relative(repoRoot, file).split("\\").join("/");
    const lines = readFileSync(file, "utf8").split("\n");
    for (let i = 0; i < lines.length; i++) {
      const rawLine = lines[i] ?? "";
      const code = stripLineComment(rawLine);
      const mentionsTempo = new RegExp(TEMPO_ID).test(code);
      for (const { name, regex } of VIOLATION_PATTERNS) {
        const needsTempoOnLine = name.startsWith("frames-per-beat");
        if (needsTempoOnLine && !mentionsTempo) continue;
        if (!regex.test(code)) continue;
        if (ALLOWLIST.has(rel)) {
          allowlistHits.add(rel);
        } else {
          violations.push(`${rel}:${i + 1} [${name}] ${rawLine.trim()}`);
        }
      }
    }
  }

  assert.deepEqual(
    violations,
    [],
    "Raw beat<->seconds tempo arithmetic found outside Sources/DAWCore/TempoMap.swift.\n" +
      "Route it through the TempoMap API (seconds(from:to:), beat(from:elapsedSeconds:), " +
      "secondsPerBeat(atBeat:)) instead — see design-m11f-tempo-map.md section 10.\n" +
      violations.join("\n")
  );

  // The allowlist is shrink-only: an entry that no longer matches anything
  // is stale and must be deleted (so it can't quietly shield future code).
  // TempoMap.swift itself hosts the arithmetic, so it always hits.
  for (const entry of ALLOWLIST) {
    assert.ok(
      allowlistHits.has(entry),
      `Allowlist entry no longer matches anything and must be removed: ${entry}`
    );
  }
});

test("the lint patterns themselves catch the known violation shapes (self-test)", () => {
  const shapes: { line: string; shouldMatch: boolean }[] = [
    { line: "let spb = 60.0 / tempoBPM", shouldMatch: true },
    { line: "let spb = 60 / transport.tempoBPM", shouldMatch: true },
    { line: "let bps = tempoBPM / 60.0", shouldMatch: true },
    { line: "let b = start + seconds * pending.tempoBPM / 60.0", shouldMatch: true },
    { line: "let fpb = fileRate * 60.0 / tempoMap.bpm(atBeat: beat)", shouldMatch: true },
    { line: "let fpb = fileRate * 60.0 / bpm", shouldMatch: true },
    // Benign 60s (clock, frame-dt, wall-age) MUST NOT match:
    { line: "let minutes = Int(total) / 60", shouldMatch: false },
    { line: "let seconds = Int(total) % 60", shouldMatch: false },
    { line: "let dt = 1.0 / 60", shouldMatch: false },
    { line: "let ageMinutes = age / 60.0", shouldMatch: false },
    // Map-API usage MUST NOT match:
    { line: "let s = tempoMap.seconds(from: a, to: b)", shouldMatch: false },
    { line: "let spb = tempoMap.secondsPerBeat(atBeat: clip.startBeat)", shouldMatch: false },
  ];
  for (const { line, shouldMatch } of shapes) {
    const mentionsTempo = new RegExp(TEMPO_ID).test(line);
    const matched = VIOLATION_PATTERNS.some(({ name, regex }) => {
      if (name.startsWith("frames-per-beat") && !mentionsTempo) return false;
      return regex.test(line);
    });
    assert.equal(matched, shouldMatch, `pattern self-test failed for: ${line}`);
  }
});
