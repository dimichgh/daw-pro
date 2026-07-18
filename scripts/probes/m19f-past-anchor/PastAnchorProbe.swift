// ============================================================================
// PROMOTED to scripts/probes/ from session scratchpad, m20-f (2026-07-16).
//
// What this measured: the AVAudioPlayerNode.h:323-324 past-anchor ambiguity
// (m19-f design doc §3.3, "R2′ leg 1") — when `play(at: F)` is called AFTER
// host time F has already passed, does the player (a) SHIFTED-ORIGIN: its
// timeline zero becomes its actual (late) start, so its whole
// player-relative schedule plays late by the lateness; or (b) RETROACTIVE:
// timeline zero maps back to F and elapsed content is silently skipped, so
// the late player joins the shared grid aligned?
//
// Verdict (already canonical, dated 2026-07-16, 5/5 runs — see
// final-runs.log in this directory): **SHIFTED-ORIGIN**. Every run's
// inter-player onset offset landed within IO-quantum rounding of the
// player's actual lateness (δ), never near zero — a late `play(at:)` never
// retroactively re-anchors. This is the measured basis for the anchor-lead
// law landed in m19-f R2′ leg 2 (player-count-scaled lead,
// `max(0.06, 0.02 + startablePlayers × 0.008)` s, capped 0.5 s).
//
// Canonical writeups (this file's results are archived there — do not
// re-derive, cite these):
//   - docs/research/2026-07-16-m19f-birth-latency-riders-design.md
//     §1.2 (the header ambiguity + plain reading), §3 (R2/R2′ analysis),
//     §3.3/§3.4 (this probe's design + verdict prescription)
//   - docs/ARCHITECTURE.md, "Sequencer clock: SETTLED" entry (~line 151),
//     the "anchor-lead law (m19-f R2′, 2026-07-16)" paragraph — the
//     SHIFTED-ORIGIN semantics and the resulting lead formula are recorded
//     there as settled architecture.
//
// How to re-run: this is a STANDALONE live-device CLI (m16-h
// standalone-matrix tradition), NEVER a suite member — hostTime anchors are
// ignored in manual (offline) rendering, so this question can only be
// answered against a REAL live output device. Compile and run directly
// under Command Line Tools, no Xcode project needed:
//   swift scripts/probes/m19f-past-anchor/PastAnchorProbe.swift
// (or `swiftc` it to a binary first if you want to run it more than once
// without paying recompilation each time). Do NOT add it to any test
// target or CI path.
//
// AUDIBLE: this probe PLAYS AUDIO BRIEFLY through the current default
// output device — two ~4 s trains of short impulses (amplitude 0.25 / 0.125,
// i.e. modest, well under full scale), hard-panned left/right, over a
// handful of seconds. It does not touch any device's settings. Do not run
// with the volume high or headphones already seated at volume if that
// would be unwelcome.
//
// This copy is a straight promotion — the probe logic below is byte-for-
// byte the same as the scratchpad original that produced final-runs.log;
// results are already canonical (see above) and this probe is NOT meant to
// be re-run to re-derive them. It is kept here so the source and its run
// log don't die with the session, per m20-f Part 3.
// ============================================================================

// m19-f R2′ leg 1 — the past-anchor semantics probe (design §3.3).
// STANDALONE live-device CLI (m16-h standalone-matrix tradition) — NEVER a
// suite member: hostTime anchors are ignored in manual rendering, so this
// question can only be answered against a live output device.
//
// Question (the AVAudioPlayerNode.h:323-324 ambiguity): when `play(at: F)`
// is called AFTER host time F has passed, does the player
//   (a) SHIFTED-ORIGIN — timeline zero = its actual (late) start, the whole
//       player-relative schedule plays late by the lateness; or
//   (b) RETROACTIVE — timeline zero maps back to F, elapsed content is
//       skipped, the player joins the shared grid aligned?
//
// Method: one live engine, two players, ONE shared future anchor F.
//   player L: play(at: F) ~500 ms BEFORE F   (the on-time control)
//   player R: play(at: F) at F + δ, δ ≈ 100 ms (the late starter)
// Both queue the IDENTICAL impulse train (impulse every 250 ms, first at
// player-sample 0, amplitude 0.25 ≈ −12 dBFS, mono at the OUTPUT rate so no
// SRC smears onsets), panned hard L / hard R. A mainMixerNode tap records
// both channels; the steady-state inter-channel onset offset is the answer:
//   offset ≈ δ (mod 250 ms)  → shifted-origin
//   offset ≈ 0               → retroactive
// No device settings are touched; content is short and quiet.

import AVFoundation
import Foundation

let delta = 0.100          // player R's lateness past F, seconds
let anchorLead = 0.5       // F = now + this, seconds
let periodSeconds = 0.25   // impulse period
// Distinct amplitudes per player (both ≤ −12 dBFS): the channel-isolation
// self-check — the right channel must only ever carry ~0.125-scale events,
// or the pan isolation failed and the run is an artifact (runs 1–5 lesson).
let amplitudeL: Float = 0.25
let amplitudeR: Float = 0.125
let trainSeconds = 4.0
let captureSeconds = 3.0

func hostTicks(_ seconds: Double) -> UInt64 {
    AVAudioTime.hostTime(forSeconds: seconds)
}

let engine = AVAudioEngine()
let playerL = AVAudioPlayerNode()
let playerR = AVAudioPlayerNode()

let outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
guard outputRate > 0 else {
    print("PROBE-ABORT: no output device (rate 0)")
    exit(2)
}
guard let monoFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 1) else {
    print("PROBE-ABORT: mono format failed")
    exit(2)
}

engine.attach(playerL)
engine.attach(playerR)
engine.connect(playerL, to: engine.mainMixerNode, format: monoFormat)
engine.connect(playerR, to: engine.mainMixerNode, format: monoFormat)

// The impulse train: single-period buffer looped is avoided — one long
// buffer, impulses 3 samples wide at every period start, first at frame 0.
let periodFrames = Int((periodSeconds * outputRate).rounded())
let trainFrames = Int((trainSeconds * outputRate).rounded())
func makeTrain(_ amplitude: Float) -> AVAudioPCMBuffer? {
    guard let train = AVAudioPCMBuffer(pcmFormat: monoFormat,
                                       frameCapacity: AVAudioFrameCount(trainFrames)),
          let samples = train.floatChannelData?[0] else { return nil }
    for frame in 0..<trainFrames {
        samples[frame] = frame % periodFrames < 3 ? amplitude : 0
    }
    train.frameLength = AVAudioFrameCount(trainFrames)
    return train
}
guard let trainL = makeTrain(amplitudeL), let trainR = makeTrain(amplitudeR) else {
    print("PROBE-ABORT: buffer alloc failed")
    exit(2)
}

// Tap capture (non-main callback: lock-guarded appends — probe-grade only).
final class Capture {
    let lock = NSLock()
    var left: [Float] = []
    var right: [Float] = []
}
let capture = Capture()

do {
    try engine.start()
} catch {
    print("PROBE-ABORT: engine.start failed: \(error)")
    exit(2)
}
usleep(150_000)  // let the render clock produce a few quanta

// Pan AFTER start — engine.start() (re)initializes mixer input-bus
// parameters and DISCARDS pre-start pan writes (the measured AVFAudio fact
// documented at AudioEngine.lastTracks; runs 1–5 of this probe re-measured
// it: pre-start pans rendered both players dead center and the two
// channels were identical). Verified below via channel isolation.
playerL.pan = -1
playerR.pan = 1

engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
    guard let data = buffer.floatChannelData else { return }
    let frames = Int(buffer.frameLength)
    capture.lock.lock()
    capture.left.append(contentsOf: UnsafeBufferPointer(start: data[0], count: frames))
    if buffer.format.channelCount > 1 {
        capture.right.append(contentsOf: UnsafeBufferPointer(start: data[1], count: frames))
    }
    capture.lock.unlock()
}

// Both players queue identical-shape content at player-relative time zero.
playerL.scheduleBuffer(trainL, at: nil, options: [], completionHandler: nil)
playerR.scheduleBuffer(trainR, at: nil, options: [], completionHandler: nil)
playerL.prepare(withFrameCount: 8_192)
playerR.prepare(withFrameCount: 8_192)

guard let renderTime = engine.outputNode.lastRenderTime, renderTime.isHostTimeValid else {
    print("PROBE-ABORT: no valid render host time")
    exit(2)
}
let anchorHost = renderTime.hostTime + hostTicks(anchorLead)
let anchor = AVAudioTime(hostTime: anchorHost)

// L: comfortably before F.
playerL.play(at: anchor)
let lLead = AVAudioTime.seconds(forHostTime: anchorHost &- mach_absolute_time())
print(String(format: "playerL play(at:F) returned %.1f ms BEFORE F", lLead * 1_000))

// Busy-wait to F + δ, then hand R the SAME, now-past anchor.
while mach_absolute_time() < anchorHost { usleep(2_000) }
usleep(UInt32(delta * 1_000_000))
let rCallHost = mach_absolute_time()
playerR.play(at: anchor)
let rLate = AVAudioTime.seconds(forHostTime: rCallHost &- anchorHost)
print(String(format: "playerR play(at:F) issued %.1f ms AFTER F (δ target %.0f ms)",
             rLate * 1_000, delta * 1_000))

Thread.sleep(forTimeInterval: captureSeconds)
engine.mainMixerNode.removeTap(onBus: 0)
playerL.stop()
playerR.stop()
engine.stop()

// Analysis: onset = first frame over threshold after ≥ period/4 of quiet;
// each onset carries its local peak so the caller can separate a player's
// own train (full pan gain) from the other player's residual bleed.
func onsets(_ samples: [Float]) -> [(frame: Int, peak: Float)] {
    var result: [(Int, Float)] = []
    var lastHit = -periodFrames
    var frame = 0
    while frame < samples.count {
        if abs(samples[frame]) > 0.03 {
            if frame - lastHit >= periodFrames / 4 {
                var peak: Float = 0
                for i in frame..<min(frame + 16, samples.count) {
                    peak = max(peak, abs(samples[i]))
                }
                result.append((frame, peak))
            }
            lastHit = frame
        }
        frame += 1
    }
    return result
}

capture.lock.lock()
let left = capture.left
let right = capture.right
capture.lock.unlock()

guard !right.isEmpty else {
    print("PROBE-ABORT: tap delivered mono — cannot separate players")
    exit(2)
}

// Channel-isolation self-check: hard pans + distinct amplitudes mean the
// left channel peaks at ~amplitudeL and the right at ~amplitudeR. A
// center-panned mixture (the pre-start-pan artifact) shows ~0.7·amplitudeL
// in BOTH channels — abort rather than misread L-vs-L alignment.
let leftPeak = left.map(abs).max() ?? 0
let rightPeak = right.map(abs).max() ?? 0
print(String(format: "channel peaks: L %.4f (want ≈ %.3f), R %.4f (want ≈ %.3f)",
             leftPeak, amplitudeL, rightPeak, amplitudeR))
guard rightPeak < (amplitudeL + amplitudeR) * 0.707 * 0.9,
      leftPeak > amplitudeL * 0.9 else {
    print("PROBE-ABORT: pan isolation failed — channels are a mixture; "
          + "no verdict from this run")
    exit(2)
}
let lRaw = onsets(left)
let rRaw = onsets(right)
// Bleed rejection: a player's OWN events carry the full pan gain (≈ its
// train amplitude); the opposite player's residual rides well below its
// own amplitude. Split each channel's detections at the midpoint between
// the two trains' expected peaks.
let lSplit = amplitudeL * 0.6
let rSplit = amplitudeR * 0.6
let lOnsets = lRaw.filter { $0.peak > lSplit }.map(\.frame)
let rOnsets = rRaw.filter { $0.peak > rSplit && $0.peak < lSplit }.map(\.frame)
func fmtRaw(_ list: [(frame: Int, peak: Float)]) -> String {
    list.prefix(4).map {
        String(format: "%.4f s @ %.3f", Double($0.frame) / outputRate, $0.peak)
    }.joined(separator: ", ")
}
print("captured \(left.count) frames @ \(Int(outputRate)) Hz; "
      + "raw detections L \(lRaw.count) / R \(rRaw.count), "
      + "own-train onsets L \(lOnsets.count) / R \(rOnsets.count)")
// First onsets, capture-relative: under RETROACTIVE semantics R's first
// audible impulse lands ON L's grid (elapsed content skipped); under
// SHIFTED-ORIGIN it lands at R's actual late start, off the grid.
print("first L detections: [\(fmtRaw(lRaw))]")
print("first R detections: [\(fmtRaw(rRaw))]")
guard lOnsets.count >= 4, rOnsets.count >= 4 else {
    print("PROBE-ABORT: too few own-train onsets (L \(lOnsets.count), R \(rOnsets.count))")
    exit(2)
}

// Steady state: skip each side's first onset, pair every remaining R onset
// with its nearest L onset, report the signed R−L offset. NOTE the mod-
// period ambiguity: a true offset > period/2 reads as (offset − period).
var diffs: [Double] = []
for r in rOnsets.dropFirst() {
    guard let nearest = lOnsets.min(by: { abs($0 - r) < abs($1 - r) }) else { continue }
    diffs.append(Double(r - nearest) / outputRate * 1_000)
}
let sorted = diffs.sorted()
let median = sorted[sorted.count / 2]
let formatted = diffs.map { String(format: "%.2f", $0) }.joined(separator: ", ")
print("R−L onset offsets (ms): [\(formatted)]  median \(String(format: "%.2f", median)) ms")

let deltaMs = rLate * 1_000
let quantumMs = 2_048.0 / outputRate * 1_000  // generous IO-quantum bound
let periodMs = periodSeconds * 1_000
// Un-alias the nearest-neighbor pairing: a true offset past period/2 reads
// as offset − period.
let unaliased = median < -periodMs / 2 + 1 ? median + periodMs
    : (median < 0 ? median + periodMs : median)
print(String(format: "inter-player onset offset: %.2f ms (un-aliased %.2f ms; "
             + "δ actual %.1f ms; period %.0f ms)", median, unaliased, deltaMs, periodMs))
if abs(median) < 15 {
    print("VERDICT: RETROACTIVE — late starter joined the grid aligned "
          + "(offset ≈ 0 despite a \(String(format: "%.0f", deltaMs)) ms late play(at:))")
} else if unaliased > deltaMs - 30, unaliased < deltaMs + quantumMs + 30 {
    print("VERDICT: SHIFTED-ORIGIN — offset ≈ lateness "
          + "(\(String(format: "%.2f", unaliased)) ms vs δ \(String(format: "%.1f", deltaMs)) ms"
          + " + IO-quantum roundup): timeline zero = actual start; "
          + "late players break lockstep")
} else {
    print("VERDICT: UNCLASSIFIED — median \(String(format: "%.2f", median)) ms "
          + "matches neither ≈0 nor ≈δ; inspect the offsets above")
}
