#!/usr/bin/env node
// render-variants.mjs — the reusable audio demo render harness.
//
// WHY THIS EXISTS: this repo ships plugin/instrument/effect work in waves,
// and the standing rule for review is "ship 3-4 OPTIONS differing on ONE
// axis each, never a single result — the pick IS the feedback" (the user is
// not a musician; their words describe, they do not diagnose). This script
// turns ONE spec file into a SET of listenable .wav variants, measures every
// one of them, and refuses to call a render "audible" on vibes — it proves
// its own gate can fail by measuring a KNOWN-SILENT file through the exact
// same code path first (the `doc-count-drift.mjs` positive-control shape).
//
// TWO RENDER PATHS, chosen by --mode:
//   headless (DEFAULT, PRIMARY) — shells out to the `DemoRender` Swift
//     executable (Sources/DemoRender/DemoRender.swift), which renders
//     through `ProjectStore` + a real `AudioEngine` + `OfflineRenderer`
//     directly. No window server, no control port, no staging app. This is
//     what makes the harness safe to run unattended overnight: a SwiftUI
//     app wants a window server (screen lock / no GUI session can wedge it),
//     an offline render through the same engine class every
//     Tests/DAWEngineTests render gate already uses headlessly does not.
//     `DemoRender` depends on DAWCore + DAWEngine ONLY (never DAWControl),
//     so it keeps building even while DAWControl is mid-edit.
//   app (opt-in, secondary) — launches a STAGING app instance (port 17695,
//     NEVER 17600 — that is the user's live app) via the shared
//     `scripts/gates/_staging.mjs` home (never hand-rolled — see its own
//     header for why a bypass here is a known failure mode) and drives the
//     SAME spec over the real control-protocol wire. This is the path that
//     proves the real user-facing render; it is not required for tonight's
//     deliverable and is skipped by default.
//
// SPEC FORMAT — see README.md for the full worked examples. Summary:
//   {
//     "set": "<name>",                         // renders land in out/<name>/
//     "description": "<optional prose>",
//     "measurement": { "type": "periodicDucking", ... },   // OPTIONAL, see README
//     "variants": [
//       { "name": "<variant>", "axis": "<one line: what differs>",
//         "role": "control",                    // OPTIONAL, marks the baseline
//         "commands": [
//           { "command": "track.add", "params": {...}, "as": "lead" },
//           { "command": "track.setInstrument", "params": {"trackId": "$lead", ...} },
//           ...
//         ] }
//     ]
//   }
// `params` values that are strings beginning with "$" resolve against a
// prior command's `"as"` binding IN THE SAME VARIANT — both render paths
// bind the SAME way (headless from the Swift return value, app-mode from
// the real wire response), so one spec drives either path identically.
//
// PROJECT NAMING (standing rule): every render gets its own project named
// `demo-<set>-<variant>` — in headless mode that name exists only in the
// in-memory ProjectStore (nothing touches disk beyond the .wav, so there is
// no ownership ambiguity to begin with); in app-mode the session is
// additionally saved to a `.dawproj` under the run's own out/ directory so
// it is unambiguously named and owned, never left as an untitled recovery
// bundle in the user's real Autosave directory.
//
// USAGE:
//   node scripts/demos/render-variants.mjs <specPath.json> [options]
//     --mode=headless|app   (default: headless)
//     --out=<dir>           (default: scripts/demos/out/<set>)
//     --skip-build          (default: false — ALWAYS rebuild explicitly;
//                             `swift build`/`swift test` can relink the
//                             binary underneath a stale assumption, so this
//                             harness treats "build first" as the safe
//                             default, not an optimization to skip)
//     --scratch-path=<dir>  (default: the repo's shared `.build`)
//
// ⛔⛔ WHY `--scratch-path` EXISTS (m39-ac). Headless mode builds `DemoRender`
// into the SHARED `.build`, which is also where `swift build` and
// `./scripts/test.sh` put their objects. Several agents work this tree
// concurrently, and "never build while another build is running" is a standing
// rule here precisely because that directory is shared — but until now a demo
// render had NO WAY to comply: rendering REQUIRED touching `.build`. Pointing
// `swift build --scratch-path` at an isolated directory removes the conflict
// entirely.
// ⚠️ A FRESH SCRATCH PATH REBUILDS EVERYTHING (several minutes, and it does not
// share a module cache with the main tree). Start it early, and never while
// timing the suite. The manifest records `binaryPath`, so every downstream gate
// that hashes the binary for freshness follows the scratch build automatically.
// ⚠️ It changes nothing by default: with the flag absent the harness uses
// `.build/debug/DemoRender` exactly as before, byte for byte.
//
// EXIT CODES: 0 all variants rendered, were audible, and were DISTINCT ·
//             1 a variant failed to render, failed the audibility gate, or
//               rendered BYTE-IDENTICAL to another (the axis did not take —
//               a hard failure since 2026-09-20; it used to only warn, which
//               meant a set whose axis did nothing exited 0) ·
//             2 spec/argument/infrastructure error ·
//             3 the silence POSITIVE CONTROL did not report silence —
//               nothing was scored (the doc-count-drift.mjs shape)

import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, "..", "..");

// ═══════════════════════════════════════════════════════════════════════════
// CLI
// ═══════════════════════════════════════════════════════════════════════════

function parseArgs(argv) {
  const args = { mode: "headless", skipBuild: false, out: null, specPath: null,
                 scratchPath: null };
  for (const a of argv) {
    if (a === "--skip-build") args.skipBuild = true;
    else if (a.startsWith("--mode=")) args.mode = a.slice("--mode=".length);
    else if (a.startsWith("--out=")) args.out = a.slice("--out=".length);
    else if (a.startsWith("--scratch-path=")) {
      args.scratchPath = a.slice("--scratch-path=".length);
      if (!args.scratchPath) {
        console.error("--scratch-path needs a directory"); process.exit(2);
      }
    }
    else if (!a.startsWith("--")) args.specPath = a;
    else { console.error(`unknown flag: ${a}`); process.exit(2); }
  }
  if (!args.specPath) {
    console.error("usage: render-variants.mjs <specPath.json> [--mode=headless|app] "
      + "[--out=<dir>] [--scratch-path=<dir>] [--skip-build]");
    process.exit(2);
  }
  if (!["headless", "app"].includes(args.mode)) {
    console.error(`--mode must be "headless" or "app", got "${args.mode}"`);
    process.exit(2);
  }
  return args;
}

function loadSpec(specPath) {
  let raw;
  try { raw = readFileSync(specPath, "utf8"); }
  catch (e) { console.error(`could not read spec file '${specPath}': ${e.message}`); process.exit(2); }
  let spec;
  try { spec = JSON.parse(raw); }
  catch (e) { console.error(`spec file '${specPath}' is not valid JSON: ${e.message}`); process.exit(2); }
  if (typeof spec.set !== "string" || !spec.set) {
    console.error("spec must have a non-empty string 'set'"); process.exit(2);
  }
  if (!Array.isArray(spec.variants) || spec.variants.length === 0) {
    console.error("spec must have a non-empty 'variants' array"); process.exit(2);
  }
  for (const v of spec.variants) {
    if (typeof v.name !== "string" || !v.name) { console.error("every variant needs a 'name'"); process.exit(2); }
    if (!Array.isArray(v.commands) || v.commands.length === 0) {
      console.error(`variant '${v.name}' needs a non-empty 'commands' array`); process.exit(2);
    }
  }
  return spec;
}

// ═══════════════════════════════════════════════════════════════════════════
// sha256 — for build/render PROVENANCE. "A render whose provenance is not
// named is not evidence" — `swift build`/`swift test` can relink the binary
// underneath a run in flight (several agents share this tree concurrently),
// so every manifest entry names the exact bytes that produced it.
// ═══════════════════════════════════════════════════════════════════════════

function sha256File(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

// ═══════════════════════════════════════════════════════════════════════════
// ffmpeg measurement — ebur128 (integrated LUFS + true peak) + astats.
//
// ⚠️ `-v error` SUPPRESSES both summaries — they log at INFO, not ERROR.
// This exact mistake has produced a confident wrong answer in this repo
// before. `-hide_banner` instead: quiets the banner without touching the
// log level, so the Summary block still prints. Everything lands on
// STDERR, not stdout — ffmpeg's filter/mux logging always does.
// ═══════════════════════════════════════════════════════════════════════════

function ffprobeDuration(path) {
  const r = spawnSync("ffprobe", [
    "-v", "error", // safe HERE: `-show_entries` writes its answer to STDOUT,
                   // never the INFO log a filter summary would use — the
                   // trap this repo's law warns about does not apply to
                   // ffprobe's plain "print one field" mode.
    "-show_entries", "format=duration", "-of", "csv=p=0", path,
  ], { encoding: "utf8" });
  const v = parseFloat((r.stdout || "").trim());
  return Number.isFinite(v) ? v : null;
}

function ffprobeSampleRate(path) {
  const r = spawnSync("ffprobe", [
    "-v", "error", // safe HERE, same reasoning as ffprobeDuration above:
                   // `-show_entries` prints its answer to STDOUT, not the
                   // INFO-level log a filter summary would use.
    "-select_streams", "a:0", "-show_entries", "stream=sample_rate",
    "-of", "csv=p=0", path,
  ], { encoding: "utf8" });
  const v = parseInt((r.stdout || "").trim(), 10);
  return Number.isFinite(v) && v > 0 ? v : null;
}

function parseDb(token) {
  if (token === undefined) return null;
  if (token === "-inf" || token === "-Inf" || token === "-INF") return -Infinity;
  const v = parseFloat(token);
  return Number.isFinite(v) ? v : null;
}

function measureLoudness(path) {
  const r = spawnSync("ffmpeg", [
    "-hide_banner", "-nostats",
    "-i", path,
    "-af", "ebur128=peak=true,astats=metadata=0",
    "-f", "null", "-",
  ], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  const log = `${r.stdout || ""}${r.stderr || ""}`;
  const integrated = parseDb(log.match(/Integrated loudness:\s*\n\s*I:\s*(-?[\d.]+|-inf)\s*LUFS/)?.[1]);
  const truePeak = parseDb(log.match(/True peak:\s*\n\s*Peak:\s*(-?[\d.]+|-inf)\s*dBFS/)?.[1]);
  const peakDbMatches = [...log.matchAll(/Peak level dB:\s*(-?[\d.]+|-inf)/g)];
  const rmsDbMatches = [...log.matchAll(/RMS level dB:\s*(-?[\d.]+|-inf)/g)];
  const astatsPeakDb = peakDbMatches.length ? parseDb(peakDbMatches.at(-1)[1]) : null;
  const astatsRmsDb = rmsDbMatches.length ? parseDb(rmsDbMatches.at(-1)[1]) : null;
  if (integrated === null || truePeak === null) {
    console.error(`  ⚠ measureLoudness(${path}): could not parse an ebur128 Summary block. Raw tail:`);
    console.error(log.slice(-1500).split("\n").map((l) => `    ${l}`).join("\n"));
  }
  return {
    integratedLufs: integrated, truePeakDbtp: truePeak,
    astatsPeakDb, astatsRmsDb,
    durationSeconds: ffprobeDuration(path),
  };
}

// ═══════════════════════════════════════════════════════════════════════════
// Periodic-ducking measurement — decodes to raw mono float32 PCM via ffmpeg
// (no resampling: aliasing an envelope through a resample is exactly the
// kind of measurement-shaped bug this repo's laws warn about) and computes
// short-window RMS in dB directly in JS, then compares a TROUGH window
// (right after each cycle's onset) against a PEAK window (right before the
// next cycle) across many cycles. Generic — the concrete offsets/periods
// come from the spec's own "measurement" object, not hardcoded here.
// ═══════════════════════════════════════════════════════════════════════════

function decodeMonoFloat32(path) {
  const r = spawnSync("ffmpeg", [
    "-hide_banner", "-loglevel", "error", // pure PCM stdout — no summary needed here
    "-i", path, "-ac", "1", "-f", "f32le", "-acodec", "pcm_f32le", "pipe:1",
  ], { encoding: "buffer", maxBuffer: 512 * 1024 * 1024 });
  if (r.status !== 0) {
    throw new Error(`ffmpeg PCM decode failed for ${path}: ${(r.stderr || "").toString().slice(0, 500)}`);
  }
  const buf = r.stdout;
  const samples = new Float32Array(buf.buffer, buf.byteOffset, Math.floor(buf.length / 4));
  return samples;
}

/** RMS in dBFS of samples[startSec, startSec+windowSec), floored at -120 dB. */
function windowRmsDb(samples, sampleRate, startSec, windowSec) {
  const start = Math.max(0, Math.round(startSec * sampleRate));
  const end = Math.min(samples.length, Math.round((startSec + windowSec) * sampleRate));
  if (end <= start) return -120;
  let sumSq = 0;
  for (let i = start; i < end; i++) sumSq += samples[i] * samples[i];
  const rms = Math.sqrt(sumSq / (end - start));
  return rms > 0 ? Math.max(-120, 20 * Math.log10(rms)) : -120;
}

function measurePeriodicDucking(path, m) {
  const samples = decodeMonoFloat32(path);
  // Read the sample rate off THIS file via ffprobe rather than assuming the
  // project default — `decodeMonoFloat32` passes no `-ar` to ffmpeg, so the
  // PCM comes out at the file's own native rate, and a stem is not
  // guaranteed to share the full mixdown's rate in every future spec. A
  // hardcoded number here was a comment describing a check that never ran.
  const sampleRate = ffprobeSampleRate(path);
  if (!sampleRate) throw new Error(`could not determine sample rate of ${path} via ffprobe`);
  const cycles = [];
  for (let i = m.skipEdgeCycles ?? 0; i < m.cycleCount - (m.skipEdgeCycles ?? 0); i++) {
    const hitTime = m.cycleStartSeconds + i * m.periodSeconds;
    const trough = windowRmsDb(samples, sampleRate, hitTime + m.troughOffsetSeconds, m.troughWindowSeconds);
    const peak = windowRmsDb(samples, sampleRate, hitTime + m.peakOffsetSeconds, m.peakWindowSeconds);
    cycles.push({ cycle: i, troughDb: trough, peakDb: peak, depthDb: peak - trough });
  }
  const mean = (xs) => xs.reduce((a, b) => a + b, 0) / (xs.length || 1);
  return {
    cycles: cycles.length,
    meanTroughDb: mean(cycles.map((c) => c.troughDb)),
    meanPeakDb: mean(cycles.map((c) => c.peakDb)),
    meanDepthDb: mean(cycles.map((c) => c.depthDb)),
    perCycle: cycles,
  };
}

// ═══════════════════════════════════════════════════════════════════════════
// Mono-compatibility measurement (m23-dj) — SHIPS A NUMBER ALONGSIDE THE AUDIO,
// because a stereo-width demo is the one case the audibility rule was written
// for: four width variants can be COMPLETELY INAUDIBLE on a phone or a laptop
// speaker, by construction, since what they hold constant is exactly the mono
// fold-down. Design §9.6: "a width demo ships a measurement alongside the
// audio, not audio alone — a mono-sum-difference figure per variant."
//
// Per variant this reports, against the set's control:
//   · monoSumDeltaDb     — how much the fold-down's LEVEL moved. A Haas
//                          widener or a level-normalised one moves it; this
//                          effect must not.
//   · monoSumResidualDb  — RMS of (this fold-down − the control's), relative
//                          to the control's. The strong form: a level match
//                          alone could hide a spectral change, a residual
//                          cannot.
//   · stereoWidth        — S²/(M²+S²), the m22-d figure the app's own
//                          goniometer shows. THIS is what must move.
//   · correlation        — L/R Pearson correlation, +1 for mono.
// ═══════════════════════════════════════════════════════════════════════════

function decodeStereoFloat32(path) {
  // `-ac 2` so a mono file is still delivered as two channels, and NO `-ar`,
  // so nothing is resampled (the `decodeMonoFloat32` reasoning, unchanged).
  const r = spawnSync("ffmpeg", [
    "-hide_banner", "-loglevel", "error",
    "-i", path, "-ac", "2", "-f", "f32le", "-acodec", "pcm_f32le", "pipe:1",
  ], { encoding: "buffer", maxBuffer: 512 * 1024 * 1024 });
  if (r.status !== 0) {
    throw new Error(`ffmpeg stereo PCM decode failed for ${path}: ${(r.stderr || "").toString().slice(0, 500)}`);
  }
  const buf = r.stdout;
  const interleaved = new Float32Array(buf.buffer, buf.byteOffset, Math.floor(buf.length / 4));
  const frames = Math.floor(interleaved.length / 2);
  const left = new Float64Array(frames);
  const right = new Float64Array(frames);
  for (let i = 0; i < frames; i++) {
    left[i] = interleaved[2 * i];
    right[i] = interleaved[2 * i + 1];
  }
  return { left, right, frames };
}

function measureStereoImage(path) {
  const { left, right, frames } = decodeStereoFloat32(path);
  const mono = new Float64Array(frames);
  let midEnergy = 0, sideEnergy = 0, lr = 0, ll = 0, rr = 0, monoSq = 0;
  for (let i = 0; i < frames; i++) {
    const l = left[i], r = right[i];
    mono[i] = l + r;
    const m = (l + r) * 0.5, s = (l - r) * 0.5;
    midEnergy += m * m;
    sideEnergy += s * s;
    lr += l * r; ll += l * l; rr += r * r;
    monoSq += mono[i] * mono[i];
  }
  const denom = Math.sqrt(ll * rr);
  return {
    frames,
    mono,
    monoRms: Math.sqrt(monoSq / Math.max(frames, 1)),
    stereoWidth: midEnergy + sideEnergy > 0 ? sideEnergy / (midEnergy + sideEnergy) : 0,
    correlation: denom > 0 ? lr / denom : 1,
  };
}

function compareMonoFoldDown(variant, control) {
  const db = (x) => (x > 0 ? 20 * Math.log10(x) : -Infinity);
  const n = Math.min(variant.frames, control.frames);
  let residualSq = 0, controlSq = 0;
  for (let i = 0; i < n; i++) {
    const d = variant.mono[i] - control.mono[i];
    residualSq += d * d;
    controlSq += control.mono[i] * control.mono[i];
  }
  const residualRms = Math.sqrt(residualSq / Math.max(n, 1));
  const controlRms = Math.sqrt(controlSq / Math.max(n, 1));
  return {
    monoSumDeltaDb: db(variant.monoRms) - db(control.monoRms),
    monoSumResidualDb: db(residualRms) - db(controlRms),
    comparedFrames: n,
  };
}

// ═══════════════════════════════════════════════════════════════════════════
// HEADLESS mode — build DemoRender, run it, parse its stdout protocol.
// ═══════════════════════════════════════════════════════════════════════════

function buildOrAbort(product, skip, scratchPath) {
  if (skip) {
    console.log(`# build SKIPPED for ${product} by request — this run may test an older binary`);
    return;
  }
  const flags = ["build", "--product", product];
  if (scratchPath) flags.push("--scratch-path", scratchPath);
  console.log(`# swift ${flags.join(" ")} …`);
  const r = spawnSync("swift", flags, { cwd: ROOT, stdio: "inherit" });
  if (r.status !== 0) {
    console.error(`ABORT: swift build --product ${product} failed — refusing to run a render against` +
      ` whatever binary happens to be on disk`);
    process.exit(2);
  }
}

async function runHeadless(spec, outDir, skipBuild, scratchPath) {
  buildOrAbort("DemoRender", skipBuild, scratchPath);
  // The scratch path's layout mirrors `.build`'s, so only the ROOT differs.
  const buildRoot = scratchPath ? resolve(process.cwd(), scratchPath) : resolve(ROOT, ".build");
  const binaryPath = resolve(buildRoot, "debug/DemoRender");
  if (!existsSync(binaryPath)) {
    console.error(`ABORT: ${binaryPath} does not exist after a successful build — build graph changed?`);
    process.exit(2);
  }
  const binarySha256 = sha256File(binaryPath);
  console.log(`# DemoRender binary sha256=${binarySha256}`);

  const specTmpPath = resolve(outDir, "_spec-used.json");
  mkdirSync(outDir, { recursive: true });
  writeFileSync(specTmpPath, JSON.stringify(spec, null, 2));

  const results = await new Promise((resolvePromise, reject) => {
    const child = spawn(binaryPath, [specTmpPath, outDir], { cwd: ROOT });
    let buf = "";
    const out = [];
    const onData = (chunk) => {
      buf += chunk.toString("utf8");
      let idx;
      while ((idx = buf.indexOf("\n")) !== -1) {
        const line = buf.slice(0, idx);
        buf = buf.slice(idx + 1);
        if (line.startsWith("RESULT ")) {
          try { out.push(JSON.parse(line.slice("RESULT ".length))); }
          catch { console.error(`  could not parse RESULT line: ${line}`); }
        } else if (line.length) {
          console.log(`  ${line}`);
        }
      }
    };
    child.stdout.on("data", onData);
    child.stderr.on("data", (c) => process.stderr.write(c));
    child.on("error", reject);
    child.on("close", (code) => {
      if (buf.trim()) console.log(`  ${buf}`);
      resolvePromise({ out, code });
    });
  });

  return {
    renderPath: "headless", buildSha256: binarySha256, binaryPath,
    exitCode: results.code, variants: results.out,
  };
}

// ═══════════════════════════════════════════════════════════════════════════
// APP mode (secondary, opt-in) — drives the real control-protocol wire
// against a STAGING app instance via the shared `scripts/gates/_staging.mjs`
// home. Reused, never hand-rolled (its own header explains why a bypass
// here is a known near-miss shape in this repo).
// ═══════════════════════════════════════════════════════════════════════════

async function runApp(spec, outDir) {
  const staging = await import(resolve(ROOT, "scripts/gates/_staging.mjs"));
  const { launchStaging, stopStaging, STAGING_PORT, LIVE_PORT, assertStagingPort } = staging;
  assertStagingPort(STAGING_PORT);
  if (STAGING_PORT === LIVE_PORT) {
    console.error("ABORT: staging port equals the live port — refusing to touch the user's app");
    process.exit(2);
  }

  const gate = `demo-render-${spec.set}`;
  let ws, stop;
  const variantResults = [];
  let buildSha256 = null, binaryPath = null;
  try {
    const s = await launchStaging({ gate, settleMs: 1200 });
    ws = s.ws; stop = s.stop;
    binaryPath = resolve(ROOT, s.binary || ".build/debug/DAWApp");
    if (existsSync(binaryPath)) buildSha256 = sha256File(binaryPath);
    console.log(`# staging pid=${s.pid} port=${STAGING_PORT} binary sha256=${buildSha256}`);

    let id = 0;
    const cmd = (command, params = {}) => new Promise((res, rej) => {
      const i = `demo${++id}`;
      const t = setTimeout(() => rej(new Error(`TIMEOUT ${command}`)), 30000);
      const h = (ev) => {
        const m = JSON.parse(ev.data);
        if (m.id !== i) return;
        clearTimeout(t); ws.removeEventListener("message", h); res(m);
      };
      ws.addEventListener("message", h);
      ws.send(JSON.stringify({ id: i, command, params }));
    });
    const sendOK = async (command, params) => {
      const r = await cmd(command, params);
      if (!r.ok) throw new Error(`${command} REFUSED :: ${JSON.stringify(r.error)}`);
      return r;
    };

    const resolveParam = (value, bindings) => {
      if (typeof value === "string" && value.startsWith("$")) {
        const key = value.slice(1);
        if (!(key in bindings)) throw new Error(`unbound reference "${value}"`);
        return bindings[key];
      }
      if (Array.isArray(value)) return value.map((v) => resolveParam(v, bindings));
      if (value && typeof value === "object") {
        const out = {};
        for (const [k, v] of Object.entries(value)) out[k] = resolveParam(v, bindings);
        return out;
      }
      return value;
    };
    const bindingFromResult = (result) => result?.id ?? result?.effectId ?? result?.sendId ?? null;

    for (const variant of spec.variants) {
      const projectName = `demo-${spec.set}-${variant.name}`;
      console.log(`# variant '${variant.name}' (${projectName}): starting — axis: ${variant.axis ?? ""}`);
      const bindings = {};
      try {
        await sendOK("project.new", { discardChanges: true });
        for (const c of variant.commands) {
          const params = resolveParam(c.params ?? {}, bindings);
          const r = await sendOK(c.command, params);
          if (c.as) {
            const bound = bindingFromResult(r.result);
            if (!bound) throw new Error(`command '${c.command}' had "as":"${c.as}" but no id-shaped field in its response`);
            bindings[c.as] = bound;
          }
        }
        const outPath = resolve(outDir, `demo-${spec.set}-${variant.name}.wav`);
        mkdirSync(outDir, { recursive: true });
        const render = variant.render ?? {};
        const mix = await sendOK("render.mixdown", { path: outPath, ...render });
        // Name the project unambiguously ON DISK too (standing rule) — a
        // `.dawproj` beside the render, never an untitled Autosave bundle.
        await sendOK("project.save", { path: resolve(outDir, `${projectName}.dawproj`) });
        console.log(`# variant '${variant.name}': rendered -> ${mix.result.path}`);
        variantResults.push({
          variant: variant.name, axis: variant.axis ?? "", ok: true,
          path: mix.result.path, durationSeconds: mix.result.durationSeconds,
          sampleRate: mix.result.sampleRate, channels: mix.result.channels,
        });
      } catch (e) {
        console.log(`# variant '${variant.name}': FAILED — ${e.message}`);
        variantResults.push({ variant: variant.name, axis: variant.axis ?? "", ok: false, error: e.message });
      }
    }
  } finally {
    try { ws?.close(); } catch { /* ignore */ }
    if (stop) stop(); // SIGTERM by EXACT pid from the pidfile; never pkill — see _staging.mjs
  }

  return {
    renderPath: "app", buildSha256, binaryPath,
    exitCode: variantResults.every((v) => v.ok) ? 0 : 1, variants: variantResults,
  };
}

// ═══════════════════════════════════════════════════════════════════════════
// Silence + sine POSITIVE CONTROLS — "a gate that cannot fail is not a
// gate." Measured through the IDENTICAL `measureLoudness` code path as
// every real variant, independent of the DAW entirely (pure ffmpeg lavfi).
// ═══════════════════════════════════════════════════════════════════════════

function synthControl(outDir, name, lavfiSource, seconds) {
  const path = resolve(outDir, `_control-${name}.wav`);
  const r = spawnSync("ffmpeg", [
    "-y", "-hide_banner", "-loglevel", "error",
    "-f", "lavfi", "-i", `${lavfiSource}`, "-t", String(seconds),
    "-ar", "48000", "-ac", "2", path,
  ]);
  if (r.status !== 0) {
    console.error(`ABORT: could not synthesize the ${name} control file: ${(r.stderr || "").toString()}`);
    process.exit(2);
  }
  return path;
}

function runPositiveControls(outDir) {
  console.log("# positive controls: measuring a KNOWN-SILENT and a KNOWN-AUDIBLE file through the same measureLoudness() path");
  const silencePath = synthControl(outDir, "silence", "anullsrc=r=48000:cl=stereo", 2);
  const silence = measureLoudness(silencePath);
  console.log(`#   silence: I=${silence.integratedLufs} LUFS, peak=${silence.truePeakDbtp} dBTP`);
  const silenceOK = silence.integratedLufs !== null && silence.integratedLufs <= -60
    && (silence.truePeakDbtp === -Infinity || (silence.truePeakDbtp !== null && silence.truePeakDbtp <= -60));
  if (!silenceOK) {
    console.error("\n✘✘ SILENCE POSITIVE CONTROL FAILED — a KNOWN-SILENT file did not measure as silent through");
    console.error("   measureLoudness(). Nothing below has been scored: a gate that cannot fail is not a gate,");
    console.error(`   and a clean run from a blind checker is worse than no run. Measured: I=${silence.integratedLufs}` +
      ` LUFS, truePeak=${silence.truePeakDbtp} dBTP (need I<=-60 and peak<=-60 or -inf).`);
    process.exit(3);
  }
  console.log("#   ok — silence measures as silence");

  const sinePath = synthControl(outDir, "sine", "sine=frequency=440:duration=2", 2);
  const sine = measureLoudness(sinePath);
  console.log(`#   sine(440Hz): I=${sine.integratedLufs} LUFS, peak=${sine.truePeakDbtp} dBTP`);
  const sineOK = sine.integratedLufs !== null && sine.integratedLufs > -40;
  if (!sineOK) {
    console.error("\n✘✘ SINE POSITIVE CONTROL FAILED — a KNOWN-AUDIBLE 440 Hz tone did not measure as audible.");
    console.error("   The gate cannot only ever say no; that is as blind as never failing. Nothing scored.");
    console.error(`   Measured: I=${sine.integratedLufs} LUFS (need > -40).`);
    process.exit(3);
  }
  console.log("#   ok — a known-audible tone measures as audible\n");

  return { silence, sine };
}

// ═══════════════════════════════════════════════════════════════════════════
// Main
// ═══════════════════════════════════════════════════════════════════════════

// `JSON.stringify` silently turns +/-Infinity into `null` — indistinguishable
// from "measurement failed" in a manifest a human or agent reads later. A
// true-peak of -inf dBTP (digital silence) is a real, meaningful measurement,
// so it is written as the STRING "-inf" (ffmpeg's own vocabulary for it),
// never collapsed into the same `null` a parse failure would produce.
const jsonDb = (v) => (v === -Infinity ? "-inf" : v === Infinity ? "inf" : v);

const AUDIBILITY_LUFS_FLOOR = -45; // clearly above the -70 LUFS silence gate
// used elsewhere in this repo, clearly below any real musical content.

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const specPath = resolve(process.cwd(), args.specPath);
  const spec = loadSpec(specPath);
  const outDir = args.out ? resolve(process.cwd(), args.out) : resolve(ROOT, "scripts/demos/out", spec.set);
  mkdirSync(outDir, { recursive: true });

  console.log(`# demo-render: set='${spec.set}' mode=${args.mode} variants=${spec.variants.length} out=${outDir}`);
  console.log(`# ${new Date().toISOString()}`);

  const controls = runPositiveControls(outDir);

  if (args.scratchPath && args.mode !== "headless") {
    console.error("--scratch-path only applies to --mode=headless (app mode launches a "
      + "staging binary through scripts/gates/_staging.mjs)");
    process.exit(2);
  }
  const run = args.mode === "headless"
    ? await runHeadless(spec, outDir, args.skipBuild, args.scratchPath)
    : await runApp(spec, outDir);

  console.log(`\n# measuring ${run.variants.length} rendered variant(s)…`);
  const measured = [];
  for (const v of run.variants) {
    if (!v.ok) { measured.push({ ...v, audible: false, sha256: null }); continue; }
    const loud = measureLoudness(v.path);
    const sha256 = sha256File(v.path);
    const audible = loud.integratedLufs !== null && loud.integratedLufs > AUDIBILITY_LUFS_FLOOR
      && loud.truePeakDbtp !== null && loud.truePeakDbtp !== -Infinity;
    let ducking = null;
    if (spec.measurement?.type === "periodicDucking") {
      // Measure on the isolated stem when the variant asked for one
      // (`measureStem` in the spec) — the SHIPPED file (`v.path`) stays the
      // full mix; the ducking analysis runs on whatever signal the spec
      // says is the one actually being tested, which may be a narrower
      // stem free of unrelated tracks playing at the same moment.
      const measurePath = v.measureStemPath ?? v.path;
      try { ducking = { ...measurePeriodicDucking(measurePath, spec.measurement), measuredPath: measurePath }; }
      catch (e) { console.error(`  ⚠ ducking measurement failed for '${v.variant}': ${e.message}`); }
    }
    let stereoImage = null;
    if (spec.measurement?.type === "monoCompatibility") {
      try { stereoImage = measureStereoImage(v.path); }
      catch (e) { console.error(`  ⚠ stereo-image measurement failed for '${v.variant}': ${e.message}`); }
    }
    measured.push({ ...v, ...loud, sha256, audible, ducking, stereoImage });
    console.log(`  ${v.variant}: I=${loud.integratedLufs?.toFixed?.(1) ?? loud.integratedLufs} LUFS, ` +
      `peak=${loud.truePeakDbtp === -Infinity ? "-inf" : loud.truePeakDbtp?.toFixed?.(1)} dBTP, ` +
      `${loud.durationSeconds?.toFixed?.(1)}s, audible=${audible}` +
      (ducking ? `, meanDuckDepth=${ducking.meanDepthDb.toFixed(2)}dB (${ducking.cycles} cycles, ` +
        `measured on ${ducking.measuredPath === v.path ? "full mix" : "isolated stem"})` : ""));
  }

  // Distinctness check: three plausible-looking LUFS numbers do not prove
  // the axis actually moved. Identical bytes prove it didn't.
  // ⚠️⚠️ **READ THIS BEFORE TRUSTING A PASS: THE IMPLICATION RUNS ONE WAY.**
  // Identical bytes prove the axis did NOTHING. **Distinct bytes prove NOTHING
  // AT ALL.** Measured 2026-09-20: planting `shapedFraction → 0` in the
  // transient shaper — the shaper never shapes, a completely inert effect —
  // still produced four DISTINCT renders, because the variants' per-variant
  // `outputDb` loudness trims differ. This check exited 0 on a dead feature.
  // Any residual gain, dither or seed does the same. So a demo set whose claim
  // matters needs a gate that asserts the PHYSICS (see
  // `scripts/gates/m39y-transient-shaper-bytes.mjs`: loudness constant within
  // 1 LU AND true peak monotonic along the axis). This check is a floor, not a
  // verdict.
  //
  // ⛔⛔ **THIS IS A GATE, NOT A WARNING — CORRECTED 2026-09-20.** It printed
  // `⚠ WARNING` to stderr and touched nothing that set the exit code, so a demo
  // set whose axis did NOTHING exited 0 and read as a pass. That is precisely
  // the failure this check was written for: m39-e shipped an LFO on
  // `.volume`/`.pan` that was completely inert, live and offline, with 24 unit
  // tests green, and THIS check is what caught it — by being READ by a human,
  // not by failing anything. A guard whose verdict depends on somebody scrolling
  // is not a guard. An audible-but-unchanged render is the most dangerous result
  // this harness can produce, because every other number on the page looks fine.
  const hashes = measured.filter((m) => m.sha256).map((m) => m.sha256);
  const uniqueHashes = new Set(hashes);
  const identicalCount = hashes.length > 1 ? hashes.length - uniqueHashes.size : 0;
  if (identicalCount > 0) {
    // Name the actual pairs: "2 variants are identical" sends the reader back
    // to the manifest to work out WHICH, and the answer is the whole diagnosis.
    const byHash = new Map();
    for (const m of measured) {
      if (!m.sha256) continue;
      if (!byHash.has(m.sha256)) byHash.set(m.sha256, []);
      byHash.get(m.sha256).push(m.variant);
    }
    const groups = [...byHash.values()].filter((names) => names.length > 1);
    console.error(`\n✘ ${identicalCount} variant(s) rendered BYTE-IDENTICAL to another — ` +
      `the axis this set claims to differ on did NOT take effect:`);
    for (const names of groups) console.error(`    identical: ${names.join(" == ")}`);
    console.error(`  Three renders with plausible LUFS numbers do not prove an axis moved. ` +
      `Identical bytes prove it did not.`);
  }

  // Ducking-hypothesis comparison against the control (if the spec asked for
  // one). THE LOAD-BEARING NUMBER IS `troughAttenuationVsControlDb`, not
  // `meanDepthDb`: `meanDepthDb` (peak-window minus trough-window WITHIN one
  // file) is confounded whenever the trough window sits close enough to a
  // transient key source (here, the kick's OWN direct un-ducked sound) that
  // the transient itself — present identically in every variant — dominates
  // the window. `troughAttenuationVsControlDb` instead compares the SAME
  // absolute window, at the SAME relative timing, ACROSS variants against
  // the un-keyed control — so anything the kick's own sound contributes
  // cancels out (it is identical in every variant), and what is left is
  // whatever the sidechain actually did to the reverb bus.
  let duckingReport = null;
  if (spec.measurement?.type === "periodicDucking") {
    const controlRole = spec.measurement.compareToRole ?? "control";
    const controlVariant = spec.variants.find((v) => v.role === controlRole)?.name;
    const controlMeasured = measured.find((m) => m.variant === controlVariant);
    duckingReport = measured
      .filter((m) => m.ducking)
      .map((m) => ({
        variant: m.variant,
        meanTroughDb: m.ducking.meanTroughDb,
        meanPeakDb: m.ducking.meanPeakDb,
        meanDepthDb: m.ducking.meanDepthDb,
        troughAttenuationVsControlDb: controlMeasured?.ducking
          ? controlMeasured.ducking.meanTroughDb - m.ducking.meanTroughDb : null,
        peakAttenuationVsControlDb: controlMeasured?.ducking
          ? controlMeasured.ducking.meanPeakDb - m.ducking.meanPeakDb : null,
      }));
    console.log(`\n# ducking hypothesis (control='${controlVariant}'):`);
    console.log(`#   troughAttenuationVsControlDb: how many dB QUIETER this variant's post-kick window`);
    console.log(`#   is than the control's, at the SAME relative timing — positive = measurable ducking.`);
    for (const r of duckingReport) {
      console.log(`  ${r.variant}: trough=${r.meanTroughDb.toFixed(2)}dB peak=${r.meanPeakDb.toFixed(2)}dB ` +
        `withinFileDepth=${r.meanDepthDb.toFixed(2)}dB ` +
        `troughVsControl=${r.troughAttenuationVsControlDb === null ? "n/a" : r.troughAttenuationVsControlDb.toFixed(2) + "dB"} ` +
        `peakVsControl=${r.peakAttenuationVsControlDb === null ? "n/a" : r.peakAttenuationVsControlDb.toFixed(2) + "dB"}`);
    }
    // ── Two findings that this measurement does NOT cover, stated loudly
    // rather than left to be inferred from the numbers above. ──────────────
    console.log(`\n# ⚠ FINDING — this measurement is on the ISOLATED REVERB-BUS STEM, not the`);
    console.log(`#   shipped mixdown. In the full mix the dry pad + kick dilute the wet bus, so`);
    console.log(`#   audible pumping in what a listener actually hears is UNMEASURED here and`);
    console.log(`#   is likely subtle for every variant except the deepest one. The stem files`);
    console.log(`#   themselves ARE listenable and unambiguous — see each variant's`);
    console.log(`#   "ducking.measuredPath" in manifest.json (under "_stems-<set>-<variant>/").`);
    console.log(`# ⚠ FINDING — the control ('${controlVariant}') has its compressor wired but its`);
    console.log(`#   sidechain cleared, so it self-keys off the reverb's OWN constantly-above-`);
    console.log(`#   threshold signal and applies a flat, continuous ~7dB reduction — it is not`);
    console.log(`#   a "compressor bypassed" baseline. The within-file meanDepthDb comparison`);
    console.log(`#   above is still valid (control ≈ 0dB, ducked variants > 0dB), but a listener`);
    console.log(`#   A/B-ing control vs. duck-fast will also hear a level difference that is NOT`);
    console.log(`#   the pumping effect. A true bypassed-compressor baseline is a follow-up, not`);
    console.log(`#   built here — the spec asked for "sidechain cleared," and that is what shipped.`);
  }

  // Mono-compatibility report (m23-dj, design §9.6). The load-bearing pair is
  // monoSumResidualDb NEAR SILENCE while stereoWidth MOVES: together they say
  // "the image changed and the fold-down did not", which is the whole claim of
  // a mid/side widener and the thing a listener on one speaker cannot check.
  let monoReport = null;
  if (spec.measurement?.type === "monoCompatibility") {
    const controlRole = spec.measurement.compareToRole ?? "control";
    const controlVariant = spec.variants.find((v) => v.role === controlRole)?.name;
    const controlMeasured = measured.find((m) => m.variant === controlVariant);
    monoReport = measured
      .filter((m) => m.stereoImage)
      .map((m) => ({
        variant: m.variant,
        stereoWidth: m.stereoImage.stereoWidth,
        correlation: m.stereoImage.correlation,
        ...(controlMeasured?.stereoImage
          ? compareMonoFoldDown(m.stereoImage, controlMeasured.stereoImage)
          : { monoSumDeltaDb: null, monoSumResidualDb: null, comparedFrames: null }),
      }));
    console.log(`\n# mono compatibility (control='${controlVariant}'):`);
    console.log(`#   monoSumResidualDb: how loud (this file's L+R) minus (the control's L+R) is,`);
    console.log(`#   relative to the control's own L+R. Near -inf = the fold-down is UNCHANGED.`);
    console.log(`#   stereoWidth: S^2/(M^2+S^2) — 0 is mono. This is what is SUPPOSED to move.`);
    for (const r of monoReport) {
      console.log(`  ${r.variant}: width=${r.stereoWidth.toFixed(4)} corr=${r.correlation.toFixed(4)} ` +
        `monoSumDelta=${r.monoSumDeltaDb === null ? "n/a" : jsonDb(r.monoSumDeltaDb) === "-inf" ? "-inf" : r.monoSumDeltaDb.toFixed(3) + "dB"} ` +
        `monoSumResidual=${r.monoSumResidualDb === null ? "n/a" : jsonDb(r.monoSumResidualDb) === "-inf" ? "-inf" : r.monoSumResidualDb.toFixed(1) + "dB"}`);
    }
  }

  const manifest = {
    generatedAt: new Date().toISOString(),
    set: spec.set, description: spec.description ?? null,
    specPath, mode: args.mode, renderPath: run.renderPath,
    buildSha256: run.buildSha256, binaryPath: run.binaryPath,
    control: {
      silence: { integratedLufs: controls.silence.integratedLufs, truePeakDbtp: jsonDb(controls.silence.truePeakDbtp) },
      sine: { integratedLufs: controls.sine.integratedLufs, truePeakDbtp: jsonDb(controls.sine.truePeakDbtp) },
    },
    audibilityLufsFloor: AUDIBILITY_LUFS_FLOOR,
    measurement: spec.measurement ?? null,
    monoReport: monoReport
      ? monoReport.map((r) => ({
          ...r,
          monoSumDeltaDb: r.monoSumDeltaDb === null ? null : jsonDb(r.monoSumDeltaDb),
          monoSumResidualDb: r.monoSumResidualDb === null ? null : jsonDb(r.monoSumResidualDb),
        }))
      : null,
    duckingReport,
    duckingFindings: duckingReport ? [
      "Measured on the isolated reverb-bus stem (ducking.measuredPath per variant), not the " +
      "shipped mixdown. Full-mix audibility of the pumping is UNMEASURED and likely subtle " +
      "except for the deepest variant; the stem .wav files are directly listenable and unambiguous.",
      "The control has its compressor wired with the sidechain cleared, so it self-keys off the " +
      "reverb's own constantly-above-threshold signal and applies a flat ~7dB continuous " +
      "reduction rather than acting as a bypassed-compressor baseline. The within-file " +
      "meanDepthDb comparison (control ≈ 0dB, ducked variants > 0dB) is unaffected, but an " +
      "A/B listen of control vs. any ducked variant will also hear a level difference that is " +
      "not the pumping effect itself.",
    ] : null,
    variants: measured.map((m) => ({
      name: m.variant, axis: m.axis, role: spec.variants.find((v) => v.name === m.variant)?.role ?? null,
      ok: m.ok, path: m.path ?? null, sha256: m.sha256 ?? null,
      durationSeconds: m.durationSeconds ?? null, sampleRate: m.sampleRate ?? null,
      integratedLufs: m.integratedLufs ?? null, truePeakDbtp: jsonDb(m.truePeakDbtp) ?? null,
      audible: m.audible, error: m.error ?? null,
      ducking: m.ducking ? {
        measuredPath: m.ducking.measuredPath,
        meanTroughDb: m.ducking.meanTroughDb, meanPeakDb: m.ducking.meanPeakDb,
        meanDepthDb: m.ducking.meanDepthDb, cycles: m.ducking.cycles,
      } : null,
      // ⚠️ The raw `mono` PCM is deliberately NOT carried into the manifest —
      // it is tens of megabytes of samples. The derived figures are in
      // `monoReport` above.
      stereoImage: m.stereoImage ? {
        frames: m.stereoImage.frames,
        stereoWidth: m.stereoImage.stereoWidth,
        correlation: m.stereoImage.correlation,
      } : null,
    })),
  };
  const manifestPath = resolve(outDir, "manifest.json");
  writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));
  console.log(`\n# manifest written to ${manifestPath}`);

  const anyRenderFailed = run.variants.some((v) => !v.ok);
  const anyInaudible = measured.some((m) => m.ok && !m.audible);
  if (anyRenderFailed) console.error("✘ at least one variant FAILED TO RENDER — see above");
  if (anyInaudible) console.error("✘ at least one variant rendered but FAILED THE AUDIBILITY GATE (looks like silence)");
  // ⛔ `identicalCount` joins the exit condition (2026-09-20). There is
  // deliberately NO spec-level opt-out: a set that legitimately wants two
  // identical renders is a set whose axis is not an axis, and an escape hatch
  // here would be used to silence exactly the defect the check exists to find.
  if (identicalCount > 0) console.error("✘ at least one variant is BYTE-IDENTICAL to another — the axis did not take");
  process.exit(anyRenderFailed || anyInaudible || identicalCount > 0 ? 1 : 0);
}

main().catch((e) => {
  console.error(`FATAL: ${e.stack || e}`);
  process.exit(2);
});
