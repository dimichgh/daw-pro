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
/// construction — is a design argument only: the hardware buffer is
/// device-dependent and user-changeable, and live playback has never been
/// measured here.
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

    /// The rate at which a hosted AU therefore samples its MIDI input during an
    /// offline bounce, in Hz, at `sampleRate`. This is the number every
    /// controller-lane capability warning is computed from.
    public static func modulationSamplingHz(sampleRate: Double = 48_000) -> Double {
        sampleRate / Double(offlineFrames)
    }
}
