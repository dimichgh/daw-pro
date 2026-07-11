# M9 (perf-c) — Load profiling pass: findings

**Date**: 2026-07-10 · **Method**: synthetic heavy session built live over the control WebSocket (staging port), measured with `engine.performanceStats` reset-windowed reads (perf-b). Machine: M5 Max (Mac17,6), output device at 44.1 kHz, engine graph at 48 kHz / 512-frame quanta.

## Verdict

**No engine DSP hotspot exists at v0 scale.** On a release (`-c release`) build, a 41-track session — 37 dense saw polySynth tracks (256 notes/clip, two-note stacks every 16th), full mixer-preset FX chains on every track, 3 FX buses with sends from every synth, 64-point volume+pan automation lanes on every synth — plays at **≈14 % of one core** total engine work, per-callback peaks under **1 % of the real-time budget**, and **zero budget overruns**. A 30 s offline mixdown of that session renders at **22.9× realtime**. No targeted optimization is warranted; these numbers are the regression baseline the telemetry seam exists to defend.

The pass did find two real defects — neither in the audio DSP:

1. **Telemetry undercount under parallel render (perf-b hardening needed).** AVAudioEngine renders independent graph branches on a worker-thread pool, so `EnginePerformanceContext`'s single-producer load→store increments (invariants exception 5) lose counts when multiple blocks are in flight simultaneously. Only material when blocks are slow (debug builds today; genuinely heavy DSP tomorrow): debug at 16 tracks measured **43 %** of the expected callback rate while `mixer.masterAnalysis` proved every track audibly rendering (+6 dB per track-count doubling, tap-based and immune to the counter race); release counts were exact through the whole campaign. Fix is small and RT-safe: `atomic_fetch_add_explicit` accumulators (lock-free on arm64) + a bounded CAS or documented-approximate max for the peak cell. Split to roadmap item (perf-d).
2. **The parked teardown crash reproduced with a full symbolicated stack** — see `docs/research/repro-teardown-crash.md`. Belongs to the M9 crash-safety item; repro is now in hand.

## Release-build campaign (the numbers that matter)

Window protocol per phase: `transport.play` → 600 ms spin-up → `engine.performanceStats {reset:true}` (opens a clean window) → 5 s → read → stop. `blocks` ≈ callbackCount / (86.13/s × 5 s window) — see "Callback-rate arithmetic" below.

| Phase | Session | Blocks | avgLoad | peak (ms / % of 10.67 ms budget) | Overruns |
|---|---|---|---|---|---|
| skeleton-8 | pop skeleton (5 instr + presets + arrangement) | 5 | 0.16 % | 0.051 / 0.5 % | 0 |
| synths+8 | +8 dense saw synths w/ presets | 13 | 0.29 % | 0.077 / 0.7 % | 0 |
| synths+16 | +8 more | 21 | 0.29 % | 0.081 / 0.8 % | 0 |
| +routing | +3 FX buses w/ presets, send/synth, 2×64-pt automation lanes/synth | 22 | 0.38 % | 0.095 / 0.9 % | 0 |
| synths+32 | +16 more (37 synths, 41 tracks total) | 38 | 0.37 % | 0.082 / 0.8 % | 0 |
| offline-30s | 30 s mixdown of the full session | — | 0.10 % | wall **1.31 s = 22.9× RT** | 0 |

Block counts scale exactly with the session inventory (see "One block per instrument track" below), loads are flat as tracks double (the per-block cost is constant; total work scales linearly and stays trivial), and automation + bus routing add ~0.1 pp of per-block load.

## Debug vs release: the first before/after

The same campaign on the debug build (the initial run) tells a completely different story — **profiling on debug builds is methodologically invalid**:

| Metric (41-track session) | debug | release | Δ |
|---|---|---|---|
| avgLoad per block (playing) | 10.3 % | 0.37 % | ~28× |
| Total engine work / wall (playing) | ~79 % of a core | ~14 % of a core | ~6× (undercounted on debug — see defect 1) |
| Offline 30 s mixdown | 103 s (0.29× RT) | 1.31 s (22.9× RT) | ~80× |
| Callback-count fidelity at 16+ tracks | ~43 % (losses) | exact | — |

Unoptimized Swift DSP is 20–30× slower per block, which both saturates wall-clock throughput offline **and** widens the in-flight overlap window that triggers defect 1's counter losses. All future perf work: measure release, always.

## Callback-rate arithmetic (the method contributions)

- **Expected live callback rate = instrumented blocks × device rate.** The device pulls at its own sample rate: 44.1 kHz / 512 = **86.13 callbacks/s per block** (measured 87/s at N=1, exact), not the graph-rate 93.75/s. `framesPerCb = renderedFrames / callbackCount` stays 512 (the graph quantum); the *rate* belongs to the device. Measured-vs-expected callback rate is a wire-visible fidelity/saturation check — the derived metric that exposed defect 1.
- **One block per instrument track.** Instrument tracks process their insert chain *inline* inside `InstrumentRenderer.renderQuantum` (step 10, the M4 ii design) — `ChainHostAU` blocks exist only on audio/bus strips. A 37-synth + 3-bus + 1-audio session ≈ 37 + ~4 blocks, matching the measured 38.
- **Offline renders in 4096-frame slices.** Net offline callbacks (total minus the stopped live-thru rate × wall) ÷ (30 s × 48000 / 4096 = 351 slices) ≈ 40 blocks — every track renders offline and is counted correctly. The mixdown artifact is a full-length 30 s stereo float WAV.
- **Stopped ≠ idle.** The live graph keeps pulling every node while the transport is stopped (live-thru); on debug the stopped session still burned ~51 % of a core. Release: negligible. Also means any offline-render telemetry window includes concurrent live-thru callbacks — subtract the stopped-rate × wall, or read the offline share via slice arithmetic.

## Scaling experiment (counter-fidelity onset, debug vs release)

N dense synth tracks, expected = N × 86.13/s (one block each); `masterLevelDB` from `mixer.masterAnalysis` proves audible rendering independent of the counters:

| N | debug measured (fidelity) | release measured (fidelity) | masterLevelDB (both) |
|---|---|---|---|
| 1 | 87/s (100 %) | 87/s (100 %) | −30.3 |
| 2 | 174/s (100 %) | 174/s (100 %) | −24 |
| 4 | 348/s (100 %) | 348/s (100 %) | −18 |
| 8 | 697/s (100 %) | 697/s (100 %) | −12 |
| 16 | 595/s (**43 %**, absolute drop) | 1394/s (100 %) | −7 |

Losses appear exactly when per-block cost × concurrency makes blocks overlap in the render pool — the single-producer premise breaks. Defect 1's fix restores fidelity regardless of block cost.

## perf-d addendum (2026-07-10, post-fix): corrected attribution for defect 1

With the fetch_add/CAS-max hardening landed (perf-d), the fidelity-onset experiment was re-run on the fixed debug build: **N=16 still measures ~597/s — statistically identical to the pre-fix 595/s.** Since the perf-d contention test proves `record()` now counts exactly (and an in-process falsification showed the old code losing 45 % under 8-thread contention), those 597 callbacks/s are REAL: at 16 dense debug tracks the device is genuinely **dropping IO cycles** (per-block work × 16 ≈ over one core's quantum budget on debug; CoreAudio skips late cycles rather than queueing them). The pre/post identity also shows the live graph renders **single-threaded** here — the original perf-b premise held for pure live playback; the real multi-producer overlap is the live render thread plus concurrent **offline manual renders** sharing one context (directly evidenced by in-block time exceeding wall time in the offline windows above).

Consequences, all favorable:
- **Defect 1 reattributed, fix unchanged and still required**: the accumulator race is real (falsified in-process; live+offline overlap is real), and exact counters are what made this correction possible at all.
- **The expected-rate check is a saturation detector, not just a fidelity check**: with exact counters, measured < blocks × device-rate now MEANS dropped device cycles — audible-glitch territory — visible over the wire with zero extra instrumentation. Debug builds saturate at ~16 dense tracks on this machine; release measured exact at every scale tested.
- The per-block `overrunCount` proxy stays blind to this by design (each block is individually fast; the SUM blows the cycle) — the rate check is the complementary signal the docs promised.

## Artifacts

Harness scripts (session scratchpad, this session): `profile-perf-c.mjs` (phased campaign), `experiment-blocks.mjs` (fidelity-onset scaling), `diagnose-perf-c.mjs` (quantum/rate diagnostics). Crash report copy + mixdown WAVs alongside. Wire-shape notes for future harnesses: responses are `{id, ok, result?, error?: string}` (error is a **string**); `track.add`/`clip.addMIDI` return the object bare; `automation.addLane` wraps in `{lane}`; `transport.seek` takes `beats`.
