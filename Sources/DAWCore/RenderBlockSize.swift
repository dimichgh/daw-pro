import Foundation

/// The offline render block size — **one number, one home** (m28-bug).
///
/// ## Why this is in DAWCore and not in DAWEngine
///
/// DAWCore is engine-free and must stay so; a render block size is an engine
/// fact. But DAWCore *already* encoded this number, twice over, because the
/// controller-lane capability warnings are computed here:
/// `EffortField.hostedAUOfflineModulationSamplingHz` was written
/// `48_000.0 / 4_096.0`, and `MIDIControllerRouting`'s warning strings spelled
/// "4096-frame blocks" into user-facing prose. The coupling was already real —
/// it was just duplicated, in three modules, with no gate holding the copies
/// together. So this is not new coupling; it is the existing coupling given a
/// single source of truth that a test can pin.
///
/// `OfflineRenderer`'s initialiser default reads `offlineFrames`, and
/// `EffortField.hostedAUOfflineModulationSamplingHz` derives from it, so the
/// number a user is warned about is by construction the number the renderer
/// actually uses. `RenderBlockSizeTests` pins that agreement.
///
/// ## ⛔⛔ Why 512 and not 4096 — MEASURED, and the null MOVED
///
/// Until m28-bug this was 4096 frames, and `docs/research/measure-gm-sax-cc.md`
/// §2.3a measured what that did: on the hosted-AU path (every `.soundBank` and
/// `.audioUnit` track) AUSampler reads its MIDI inputs **once per render call**,
/// so every controller lane — pitch bend AND CC — is **sample-and-held at the
/// block rate**. 4096 frames at 48 kHz is an **11.719 Hz sampler with a Nyquist
/// of 5.86 Hz**, which sits underneath the entire musical modulation band. The
/// consequence was not a shallower vibrato but *a different one*: alias images
/// at `|f_s − f|`, several of them **louder than the fundamental**. A commanded
/// ±50 ¢ 11 Hz vibrato bounced as ±49.8 ¢ at **0.72 Hz**; a commanded 11.72 Hz
/// vibrato bounced as a **static −17.9 ¢ detune**.
///
/// §6 of that doc ran the falsifying test the earlier round could only write
/// down (the block size is not reachable from the wire, so it had to be done
/// from Swift — `BlockRateBounceProbeTests`). At 512 frames:
///
/// | authored | 4096 delivered | **512 delivers** |
/// |---|---|---|
/// | 5.5 Hz | 35.4 ¢ + a 30.0 ¢ alias at 6.22 Hz | **48.3 ¢, alias 3.1 ¢ at 88 Hz** |
/// | 8 Hz | 19.2 ¢ + a **41.7 ¢** alias at 3.72 Hz | **49.1 ¢, alias 4.7 ¢ at 86 Hz** |
/// | 11.72 Hz | **0 ¢ — a static −17.9 ¢ detune** | **47.6 ¢ at 11.72 Hz** |
///
/// ⭐ **The images did not vanish, they MOVED to exactly `|93.75 − f|`** and are
/// visible there in the scan — which is what makes this a confirmed mechanism
/// rather than an absence. They are attenuated ~7× on the way (worst case ~7 ¢
/// at 82 Hz, a sideband pair rather than a musical gesture), so this is a fix
/// that moves and shrinks the defect, not one that removes it.
///
/// ⚠️ **Honest about the two arguments.** The MEASURED argument for 512 is that
/// its sampler's Nyquist (46.875 Hz) clears the whole musical modulation band
/// while 1024's does not — at 1024 the detector still counts images at four of
/// five rates (5.1–12.5 ¢), and its rate ceiling of 9.375 Hz leaves half the
/// authorable tremor range aliasing. The *design* argument — that 512 is also
/// the typical live hardware buffer, so a bounce and a monitor agree by
/// construction — rests on a measurement that this file used to deny.
///
/// ⛔⛔ **CORRECTED 2026-09-19 (m39-d). THIS PARAGRAPH USED TO END "and live
/// playback has never been measured here." THAT WAS FALSE WHEN WRITTEN.**
/// `MIDIControllerRouting.swift` (~`:431-441`) records the measurement, taken at
/// breath-pad P6 on **2026-08-19** — earlier than this sentence: a real
/// `AudioEngine`, prepared against this machine's default output and left
/// rendering for 400 ms, reported **quantumFrames = 512 at 48 kHz ⇒ 93.75 Hz,
/// Nyquist 46.875 Hz**, with `renderedFrames` an exact multiple of 512
/// (38912 = 76 × 512) — every quantum the same size. `EnginePerformance`
/// already records `lastQuantumFrames` per quantum and it is surfaced as
/// `EnginePerformanceStats.quantumFrames`, so the number was free for the asking.
///
/// ⚠️ **Why this mattered enough to fix in place:** a 🚨 roadmap gate (m39-d)
/// was filed against the false sentence, proposing to measure something already
/// measured. **This tree's characteristic failure is exactly this shape — the
/// record says X, the source says Y, and nothing compares them.** Two files
/// disagreeing IS the signal; the fix is to make them agree, not to pick one.
///
/// ✅ **So ON THIS MACHINE, AT ITS DEFAULT DEVICE, live and offline now agree by
/// measurement, not by hope.** ⚠️ **What remains genuinely unmeasured is the
/// case where the hardware buffer is NOT 512** — it is device-dependent and
/// user-changeable, and nothing here has ever asked what happens at 64, 128 or
/// 1024 frames. That, and only that, is what m39-d should measure.
///
/// ⚠️ **COST, MEASURED, not estimated** (8 hosted sound-bank tracks, 120 s,
/// dense parts with bend lanes — the block-sensitive case): 4096 → **0.449 s**,
/// 1024 → 0.514 s, 512 → **0.587 s**. A **1.31×** bounce, 204× realtime instead
/// of 267×. Paid.
///
/// ⚠️ **This is a CALL SIZE, not a capacity.** `AUHostRegistry`'s
/// `maximumFramesToRender` (8192) is the largest block a hosted AU is told it
/// may be asked for; this is how much is actually asked for. They are different
/// numbers and 8192 is deliberately left alone.
public enum RenderBlockSize {

    /// Frames per `renderOffline` pull. See the type doc for the measurement.
    public static let offlineFrames = 512

    /// m39-d CR-1 (`docs/design/2026-10-07-effect-control-rate.md` §5.1): the
    /// EFFECT CONTROL CELL. Built-in effect parameters (automation lanes and
    /// modulation routes) are evaluated and stored once per cell, at the cell
    /// line, with cells counted from the ROLL start (`r = 0` at the play or
    /// render start) — in every path, live and offline, at any device buffer.
    /// A live render call that contains a cell line is split there; one that
    /// does not tells the automated effects to hold.
    ///
    /// ⛔ DEFINED AS `offlineFrames`, NOT AS A SECOND LITERAL. A production
    /// bounce pulls `offlineFrames` blocks from `r = 0`, so its blocks ARE the
    /// cells and it never splits or holds: that identity is why no saved song's
    /// bytes moved when the grid landed (G1). Change one and the other moves
    /// with it; `ControlGridTests` pins the equality.
    public static let controlFrames = offlineFrames

    /// The rate at which a hosted AU therefore samples its MIDI input during an
    /// offline bounce, in Hz, at `sampleRate`. This is the number every
    /// controller-lane capability warning is computed from.
    public static func modulationSamplingHz(sampleRate: Double = 48_000) -> Double {
        sampleRate / Double(offlineFrames)
    }
}
