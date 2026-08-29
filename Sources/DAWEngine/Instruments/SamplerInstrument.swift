import AVFAudio
import CAtomics
import DAWCore
import Foundation

/// The built-in sampler (M3 v): pitched multisample + one-shot playback.
/// 64 voices (m19-a: 16 → 64 for velocity-layered content under the pedal),
/// oldest stolen when full; noteOff pairs by noteID (same policies as
/// `PolySynthInstrument`).
///
/// m16-b2 controllers (design-m16b §4.3): honors PITCH BEND (playback-rate
/// factor 2^(semitones/12) on every voice) and SUSTAIN (CC64 ≥ 64: noteOffs
/// defer until pedal-up; one-shot mode is unaffected).
///
/// Bend RANGE is per-instrument (`SamplerParams.bendRangeSemitones`) and rides
/// the scalar snapshot; **nil = 2.0, the GM default the engine used to
/// hard-wire**, so a project that never sets it renders byte-identically. See
/// that field for why the default may not be widened.
///
/// VOICE MODE (`SamplerParams.voiceMode`): poly (nil/default, unchanged) or
/// MONO with LAST-NOTE priority — a new note chokes the sounding one into its
/// release ramp, and a note-off for an already-superseded note is discarded
/// rather than falling back to a note still held. See `monoChoke` and the
/// note-off branch of `apply(_:)` for the wind-instrument reasoning.
///
/// m27 continuous expression: CC11 (expression), CC2 (breath) and CC1 (mod
/// wheel) now reach the voice as a SMOOTHED per-voice amplitude multiplier —
/// the thing a wind player actually does mid-note, which no amount of
/// per-note velocity can express. CC11 attenuates unconditionally; CC1/CC2
/// only as far as `SamplerParams.expressionModDepth` allows, because their
/// MIDI neutral is 0 and an unconditional reading would render silence until
/// a lane's first authored point (see that field's doc). Channel pressure and
/// every other CC remain safely ignored (documented, and now WARNED at the
/// lane-accept path rather than silently swallowed — see
/// `MIDIControllerRouting`). `reset()` re-centers bend, lifts the pedal, and
/// neutralises the expression controllers.
///
/// Zone audio is loaded FULLY in init — reconcile time, never the render
/// thread — into immutable deinterleaved Float32 buffers at each file's
/// native rate. Zone SELECTION (m19-a, design 2026-07-16 §4.2): zones are
/// stable-sorted by `group` in init; a note-on makes ONE random draw, then one
/// pass over the sorted array fires ONE voice per group — the first zone in
/// each group that matches the pitch AND velocity spans and passes its
/// round-robin (`seqLength`/`seqPosition`, per-zone counters advancing on
/// every range match — the ARIA convention) and random (`randMin`/`randMax`
/// vs the draw) gates. Legacy zones all land in implicit group 0 with full
/// spans and no gates, so the loop degenerates to the original first-match
/// scan exactly (no zone → the note is silently ignored). A voice advances a
/// fractional playhead through the source at
///
///     2^((pitch − rootPitch)/12) × fileRate / graphRate
///
/// with linear interpolation, freeing itself at the zone's end frame (m19-b:
/// `startFrame`/`endFrame` trim the source span; nil = the whole file). Mono
/// files play on both output channels, scaled by the zone's constant-power
/// pan gains (nil pan = unity 1.0/1.0 — the legacy dual-mono law, see
/// `LoadedZone`). Amplitude (m19-b, design §4.5):
///
///     (1 − vt + vt × velocity/127) × zone.gain × params.gain
///
/// with vt = ampVelTrack (nil → 1 ⇒ the original velocity/127 law,
/// bit-for-bit). `tuneCents` multiplies a precomputed `exp2(cents/1200)`
/// factor into the playback increment.
///
/// Envelope (m19-b, design §4.4): per-voice linear 4-stage ADSR — the
/// `PolySynthInstrument` stage machine — with coefficients computed at
/// TRIGGER time from the zone's attack/decay/sustain/release, falling back to
/// the LIVE global coefficients for nil fields. Nil defaults (decay 0,
/// sustain 1) collapse to the original attack→hold→release law byte-for-byte.
/// The release ramp reaches EXACTLY 0 after `release` seconds and frees the
/// voice (true zeros from then on). One-shot (global, or per-zone override —
/// zone wins, nil inherits the LIVE global at noteOff time) ignores noteOff —
/// every trigger plays to the zone's end.
///
/// Known accepted semantic shift (design §4.4): because envelope coefficients
/// are captured per voice at trigger, a GLOBAL attack/release hot-swap now
/// affects only NEWLY triggered voices without a zone override — negligible
/// at anti-click time scales.
///
/// Sustain loops (m20-g): a zone with `loopMode` loops `[loopStart, loopEnd)`
/// — `.sustain` while the note (or the CC64 pedal) holds, disarming at true
/// release start so playback continues linearly past the loop end into the
/// natural tail; `.continuous` loops through the release and frees ONLY at
/// envelope zero. The seam is a render-time equal-gain (linear) crossfade
/// over the final min(512, loopStart, loopLength) source frames of each
/// pass, blending in the pre-loop-start material `[loopStart − X, loopStart)`
/// time-aligned to land exactly on loopStart at the wrap — zero per-voice
/// crossfade state, pure arithmetic on the fractional playhead. loopStart 0
/// degrades to a raw wrap (no pre-start material exists). A looping voice is
/// NEVER one-shot (loopMode wins over `oneShot` — a continuous voice under
/// global one-shot would otherwise drone until stolen). Nil loop fields
/// render byte-identically to the pre-m20-g path.
///
/// Parameter split: ZONES are structural — a zones change rebuilds the whole
/// instrument via `PlaybackGraph.InstrumentTrackKey` (fresh init reloads the
/// files). The SCALARS (oneShot/attack/release/gain) update in place:
/// `apply(params:)` publishes an immutable POD snapshot through a
/// heap-allocated `daw_atomic_ptr` with the same ≥ 1 s retire-bin pattern as
/// `PolySynthInstrument`; the render thread adopts it at the top of the next
/// quantum without cutting held voices.
///
/// Render-path contract: `render()`/`reset()` allocate nothing, take no
/// locks, log nothing, and touch no ObjC — voices and zone descriptors live
/// in fixed heap blocks allocated in init; sample memory is immutable after
/// init; the snapshot is borrowed via `takeUnretainedValue` (the retire bin
/// guarantees its lifetime).
final class SamplerInstrument: InstrumentRendering, @unchecked Sendable {
    // MARK: - Loaded zone data (immutable after init)

    /// POD descriptor of one successfully loaded zone. `left`/`right` point
    /// into buffers owned by `ownedChannelBuffers`; for mono files both point
    /// at the same buffer. m19-a selection and m19-b playback fields are
    /// resolved from the model zone's optionals ONCE in init (nil → the
    /// legacy-law values) so the render path never touches an Optional.
    ///
    /// Pan bit-compat rule (m19-b): `pan == nil` resolves to
    /// `panL = panR = 1.0` EXACTLY — the legacy unity dual-mono gains, so a
    /// nil-field zone renders byte-identically to pre-m19-b (×1.0 is a float
    /// identity). A PRESENT pan engages the constant-power law
    /// `panL = cos((p+1)·π/4)`, `panR = sin((p+1)·π/4)`, which puts an
    /// EXPLICIT center (pan 0) at 0.7071 (−3 dB) per channel — the standard
    /// pan law. nil ≠ 0.0 here by design: the legacy suite forbids a −3 dB
    /// shift on nil zones.
    private struct LoadedZone {
        var left: UnsafePointer<Float>
        var right: UnsafePointer<Float>
        var frameCount: Int
        var fileRate: Double
        var rootPitch: Int32
        var minPitch: Int32
        var maxPitch: Int32
        var gain: Float
        var minVel: Int32            // nil → 0
        var maxVel: Int32            // nil → 127
        var group: Int32             // nil → 0 (implicit legacy group)
        var seqLength: Int32         // nil/≤1 → 1 (no round-robin gate)
        var seqPosition: Int32       // nil → 1; clamped into 1...seqLength
        var randLo: Float            // nil → 0
        var randHi: Float            // nil → 1
        // m19-b playback scalars (design §4.1) —
        var tuneFactor: Double       // exp2(tuneCents/1200), init-time; nil → 1.0
        var panL: Float              // nil → 1.0 EXACTLY (see pan rule above)
        var panR: Float
        var ampVelTrack: Float       // nil → 1 (the velocity/127 law)
        var oneShotOverride: Int8    // -1 = inherit the LIVE global / 0 / 1
        var startFrame: Int          // resolved into 0..<frameCount; nil → 0
        var endFrame: Int            // resolved into (startFrame+1)...frameCount; nil → frameCount
        /// `Double(startFrame)`, precomputed (the `loopLen` idiom) so the
        /// render loop's low-side span check is a plain Double compare rather
        /// than an Int→Double conversion per frame.
        var startFrameD: Double
        // m32-d reverse (§7) — resolved ONCE here, and the render loop never
        // sees this Bool: it reads the per-voice `readBase`/`readDir` scalars
        // `trigger` derives from it, so the hot loop gains no branch.
        var reverse: Bool
        /// m32-f choke group, −1 = none. ⚠️ NOT `group` above: that one selects
        /// WHICH zone fires at note-on (round-robin / alternate layers); this
        /// one ends voices that are ALREADY SOUNDING. Resolved into −1...63
        /// here so the trigger path's `1 << chokeGroup` can never shift out of
        /// range — a raw `Codable` decode bypasses the model's clamping init
        /// (the same reason `startFrame`/`endFrame` are re-clamped above), and
        /// an over-wide shift traps ON THE RENDER THREAD.
        var chokeGroup: Int32
        // Per-zone envelope, seconds/level. attack/release carry a -1
        // sentinel = "inherit the LIVE global coefficient at trigger time"
        // (design §4.4); decay/sustain have constant nil-defaults (0 / 1) and
        // are resolved here.
        var envAttack: Float         // seconds; -1 → global attackStep
        var envDecay: Float          // seconds; nil → 0 (no decay stage)
        var envSustain: Float        // level 0...1; nil → 1 (hold at peak)
        var envRelease: Float        // seconds; -1 → global releaseSlope
        // m20-g loops (§3.2) — all resolved once in init, POD stays POD.
        var loopMode: UInt8          // 0 = none, 1 = sustain, 2 = continuous
        var loopStart: Int           // resolved into 0..<frames (valid loops only)
        var loopEndExcl: Int         // resolved into (loopStart+1)...endFrame
        var loopLen: Double          // Double(loopEndExcl - loopStart), precomputed
        var loopXfade: Int           // min(512, loopStart, loopEndExcl - loopStart); 0 = raw wrap
        var invLoopXfade: Float      // loopXfade > 0 ? 1/Float(loopXfade) : 0
        // m27 leg B dynamic-layer crossfade, RESOLVED AT LOAD (design: the
        // render path must never recompute a range from the model zone).
        // Bounds carry SFZ's OWN defaults — xfin 0/0 and xfout 127/127 — which
        // make both fades evaluate to exactly 1.0, so a zone without the
        // opcodes needs no flag to be bit-identical. The flags exist only to
        // skip the arithmetic.
        var xfCC: Int32              // controller driving the CC fade; -1 = none
        var hasCcXfade: Bool
        var xfCcInLo: Float
        var xfCcInHi: Float
        var xfCcOutLo: Float
        var xfCcOutHi: Float
        var hasVelXfade: Bool
        var xfVelInLo: Float
        var xfVelInHi: Float
        var xfVelOutLo: Float
        var xfVelOutHi: Float
    }

    // MARK: - Published scalar snapshot

    /// The in-place-updatable subset of `SamplerParams` (everything but
    /// zones). POD, so render-thread reads do no ARC or bridging work.
    private struct ScalarParams: Equatable {
        var oneShot: Bool
        var attack: Double
        var release: Double
        var gain: Double
        /// m27: CC1/CC2 amplitude depth, 0 = off (see `SamplerParams`).
        var expressionModDepth: Double
        /// m27 leg C: filter sweep depth, 0 = off (filter SKIPPED, not run at
        /// unity — that is what keeps an opted-out project byte-identical).
        var expressionFilterDepth: Double
        var expressionFilterCC: Int
        /// Semitones per full bend deflection; nil in the model resolves HERE,
        /// once, to the GM default — the render thread never sees an Optional.
        var bendRangeSemitones: Double
        /// `SamplerVoiceMode` flattened to a Bool so the snapshot stays POD and
        /// the render thread branches on a plain load.
        var monoVoiceMode: Bool

        init(_ params: SamplerParams) {
            oneShot = params.oneShot
            attack = params.attack
            release = params.release
            gain = params.gain
            expressionModDepth = params.expressionModDepth ?? 0
            expressionFilterDepth = params.expressionFilterDepth ?? 0
            expressionFilterCC = params.expressionFilterCC ?? 11
            bendRangeSemitones = params.effectiveBendRangeSemitones
            monoVoiceMode = params.effectiveVoiceMode == .mono
        }
    }

    /// Immutable box crossing main actor → render thread through `paramsSlot`.
    private final class ParamSnapshot {
        let generation: UInt64
        let params: ScalarParams

        init(generation: UInt64, params: ScalarParams) {
            self.generation = generation
            self.params = params
        }
    }

    // MARK: - Voice

    /// The 4-stage envelope state machine (m19-b) — the exact
    /// `PolySynthInstrument.Stage` pattern.
    private enum Stage {
        static let attack: UInt8 = 1
        static let decay: UInt8 = 2
        static let sustain: UInt8 = 3
        static let release: UInt8 = 4
    }

    private struct Voice {
        var active = false
        var noteID: UInt64 = 0
        var serial: UInt64 = 0       // steal order: lowest serial = oldest voice
        var zoneIndex: Int32 = 0
        var stage: UInt8 = 0         // m19-b: Stage.attack...release
        var sustained = false        // noteOff deferred by the pedal (m16-b2, CC64)
        // m19-b one-shot tri-state, copied from the zone at trigger: -1 =
        // inherit — noteOff resolves it against the LIVE global `oneShot`, so
        // a mid-note global toggle changes noteOff handling exactly as it did
        // pre-m19-b; 0/1 = the zone's override wins over the global.
        var oneShotOverride: Int8 = -1
        /// Fractional playhead in source-file frames — the LOCAL coordinate.
        /// It always starts at the zone's `startFrame` and always ADVANCES by
        /// `increment`, whichever way the zone plays; the direction lives in
        /// `readBase`/`readDir` below, never in the sign of `increment`.
        /// (`applyBendFactor` overwrites `increment` on every sounding voice
        /// mid-note, so a negative increment would be silently undone by the
        /// first pitch-bend event.)
        var position = 0.0
        var increment = 0.0          // baseIncrement × bendFactor
        var baseIncrement = 0.0      // unbent source frames per output frame (m16-b2)
        // m32-d (design §7): the per-voice DIRECTION SCALAR. The frame actually
        // read is `readBase + readDir × position`.
        //
        // ⭐ FORWARD IS AN IEEE IDENTITY, and that is the whole reason this
        // shape was chosen over two specialised loop bodies or an inner-loop
        // branch: `0 + 1.0 × x` is EXACTLY `x` for every finite x, so a forward
        // voice reads the same frames, in the same order, with the same
        // rounding, as it did before this field existed.
        //
        // Reversed: `readBase = endFrame − 1 + startFrame`, `readDir = −1`, so
        // the first read is at `endFrame − 1` and the last at `startFrame` —
        // the exact mirror of the forward span.
        var readBase = 0.0
        var readDir = 1.0
        var gainL: Float = 0         // amp × zone.panL (amp = velocity law × zone.gain)
        var gainR: Float = 0         // amp × zone.panR
        var level: Float = 0         // envelope, 0...1
        var releaseFrom: Float = 0   // level captured at noteOff (release anchor)
        // m19-b per-voice envelope coefficients, computed at TRIGGER time
        // (design §4.4) — zone fields, or the then-live globals for nil.
        var attackStep: Float = 0    // level units per sample
        var decayStep: Float = 0
        var sustainLevel: Float = 0
        var releaseSlope: Float = 0  // fraction of releaseFrom per sample
        // m20-g loops (§3.2), both copied from the zone at trigger:
        var looping = false          // armed at trigger when zone.loopMode != 0;
                                     // disarmed at release start for sustain mode
        var loopMode: UInt8 = 0      // zone.loopMode copy — the disarm rule reads
                                     // it without a zones deref in the noteOff path
        /// m32-f: the zone's choke group, copied at trigger for the same reason
        /// `loopMode` is — the choke sweep tests it once per voice and must not
        /// dereference `zones` to do it. −1 (the `Voice()` default, and every
        /// freed slot) never matches a real group, so a voice from a zone with
        /// no choke group is structurally unchokable.
        var chokeGroup: Int32 = -1
        // m27 continuous expression (design: breath/air §A). A SEPARATE
        // multiplier from `gainL`/`gainR` ON PURPOSE: those are trigger-time
        // constants and the release anchor (`releaseFrom`/`releaseSlope`) is
        // written against a stable gain, so mutating them mid-note would
        // corrupt every release ramp. This one rides the SAME product but is
        // free to move.
        //
        // `expGainTarget` is recomputed at CC-EVENT rate (a handful of times
        // per quantum) and at trigger; `expGain` chases it with a one-pole
        // ramp per frame because controller lanes are STEPWISE — an
        // unsmoothed multiply is one click per lane point, i.e. zipper noise
        // on exactly the long held notes this feature exists to improve.
        //
        // Both default to 1.0 so a freed voice (`voices[i] = Voice()`) and an
        // instrument that never sees a CC carry an exact IEEE identity.
        var expGain: Float = 1
        var expGainTarget: Float = 1
        // m27 leg C: one-pole low-pass state, one per output channel. This is
        // the ONLY genuinely per-voice piece of the filter — the coefficient
        // is shared (the controller is instrument-wide, there being exactly
        // one controller stream per instrument track), so 64 voices cost 2
        // floats each and no per-voice coefficient math whatsoever.
        var lpZ1L: Float = 0
        var lpZ1R: Float = 0
        // m27 leg B: the VELOCITY half of the crossfade is fixed at note-on
        // (velocity is), so it is resolved once here and folded into every
        // later target recompute. 1.0 = no velocity crossfade.
        var velXfade: Float = 1
    }

    private static let voiceCount = 64

    private let voices: UnsafeMutablePointer<Voice>
    private let paramsSlot: UnsafeMutablePointer<daw_atomic_ptr>

    /// Zone descriptors — written once in init, immutable thereafter, read by
    /// the render thread with no Array machinery.
    private let zones: UnsafeMutablePointer<LoadedZone>
    private let zoneCount: Int
    /// Owned sample memory backing `zones` (freed in deinit).
    ///
    /// ⚠️ OWNERSHIP LAW (m32-a) — this is the SOLE allocation ledger. Every
    /// entry is freed exactly once, in `deinit`. `LoadedZone.left`/`.right`
    /// are BORROWED aliases into this ledger and are never freed through a
    /// zone. Two zones whose `SamplerZone.sourceFileKey` matches alias the
    /// SAME pair of pointers. Positively stated, and pinned by
    /// `SamplerZoneBufferDedupTests`: this array contains no two entries with
    /// the same `baseAddress`, and every `LoadedZone.left`/`.right` equals the
    /// `baseAddress` of exactly one entry.
    ///
    /// This is a widening of an alias relationship the loader ALREADY relied
    /// on — a mono file has always pointed a zone's `right` at its `left`, and
    /// `deinit` has always freed the ledger rather than the zones.
    private var ownedChannelBuffers: [UnsafeMutableBufferPointer<Float>] = []

    /// Human-readable notes for zones skipped at load (missing/unreadable/
    /// empty files). Populated in init — reconcile time — and never touched
    /// by the render path.
    private(set) var zoneLoadNotes: [String] = []

    /// m32-a gate seam: how many times `init` actually opened an audio file.
    /// Counts open ATTEMPTS that reached `AVAudioFile(forReading:)`, so a
    /// fixture that fails a load guard (empty/unreadable) is re-opened — and
    /// re-counted — per zone, because failures are deliberately NOT cached.
    /// Secondary to the ledger reading below; it measures the "skip the open"
    /// half of the dedup, which byte counts cannot see.
    private(set) var audioFileOpenCount: Int = 0

    /// m32-a gate seam: total sample bytes ACTUALLY held, summed from the
    /// allocation ledger ITSELF — so a loader that forgot to dedup cannot
    /// report otherwise. A ledger reading, not a setter's return value.
    var loadedSampleBytes: Int {
        ownedChannelBuffers.reduce(0) { $0 + $1.count * MemoryLayout<Float>.size }
    }

    /// m32-a gate seam: channel buffers on the ledger — 2 per distinct STEREO
    /// source file, 1 per distinct MONO source file (mono aliases L into R).
    var ownedSampleBufferCount: Int { ownedChannelBuffers.count }

    /// m32-a gate seam: base addresses of loaded zone `index`'s channel
    /// pointers as integers — the aliasing invariant, observable without
    /// dereferencing anything. ⚠️ `index` is into the GROUP-SORTED zone array,
    /// not `params.zones`; with all-nil groups the sort is an identity.
    func zoneBufferBaseAddresses(_ index: Int) -> (left: UInt, right: UInt)? {
        guard index >= 0, index < zoneCount else { return nil }
        return (UInt(bitPattern: UnsafeRawPointer(zones[index].left)),
                UInt(bitPattern: UnsafeRawPointer(zones[index].right)))
    }

    /// One source file's decoded PCM, as the m32-a init-local dedup cache
    /// stores it. The pointers BORROW from `ownedChannelBuffers`; this struct
    /// owns nothing and is discarded when `init` returns.
    private struct LoadedFileBuffers {
        let left: UnsafePointer<Float>
        let right: UnsafePointer<Float>
        let frameCount: Int
        let fileRate: Double
    }

    // Render-thread-only state.
    private var sampleRate: Double
    private var nextSerial: UInt64 = 0
    private var lastParamsGeneration = UInt64.max  // .max forces first-quantum adoption
    // Controller state (m16-b2, design-m16b §4.3): plain render-thread
    // scalars, mutated only by applied schedule events. Bend range is the GM
    // default ±2 semitones; `bendFactor` = 2^(semitones/12) multiplies every
    // voice's playback-rate increment (recomputed per applied bend event —
    // one exp2, no allocation).
    private var bendFactor = 1.0
    private var pedalDown = false
    /// Semitones per FULL deflection. Was a `static let 2.0`; it is now a
    /// per-instrument setting (`SamplerParams.bendRangeSemitones`) that crosses
    /// into the render thread through the SAME `ScalarParams` snapshot the
    /// other scalars ride — no new mechanism, no second writer. Written only in
    /// `init` and in `recomputeCoefficients` (render thread, once per adopted
    /// generation); read only here.
    ///
    /// ⚠️ NOT RAMPED, deliberately. The `expGain` one-pole exists because
    /// amplitude lanes are stepwise and a stepwise multiply is one CLICK per
    /// lane point — a stream of them, which is what zipper noise is. This is
    /// neither: it is a configuration value, not a controller lane, so it
    /// cannot produce a stream of steps at all; and the quantity it moves is
    /// PITCH, which the bend path itself already applies unsmoothed on purpose
    /// (a pitch step detunes, it does not click — see
    /// `BreathContour.Options.bendSpacingSeconds`). Changing the range while a
    /// DEFLECTED note sounds retunes it in one step, exactly as moving the bend
    /// wheel that far would have.
    private var bendRangeSemitones = SamplerParams.defaultBendRangeSemitones
    /// The last raw 14-bit bend value applied (8192 = centre). Kept so a
    /// mid-note RANGE change can re-derive `bendFactor` without waiting for the
    /// next bend event — otherwise a deflected note would keep the old range's
    /// pitch until the lane's next point, which on a held note is forever.
    private var lastBendRaw = 8_192
    /// m30 mono (last-note priority). Render-thread scalars under the same
    /// single-writer discipline as `bendFactor`/`pedalDown`.
    private var monoVoiceMode = false
    /// The noteID of the note mono last actually SOUNDED. Never cleared on
    /// note-off — see the note-off rule in `apply(_:)`.
    private var monoActiveNoteID: UInt64 = 0
    /// False until mono has triggered its first note, so a note-off for a voice
    /// that started under POLY (mono switched on mid-flight) still releases
    /// normally instead of being discarded as "superseded".
    private var monoStarted = false
    /// Set at each mono note-on, cleared by the first `trigger` that note
    /// causes. Makes the choke LAZY: a note-on that selects no zone (out of
    /// every span) must not silence the note that IS sounding, and a note-on
    /// that fires several zones (one voice per group, m19-a) must choke the
    /// PREVIOUS note once — not choke itself on its own second group.
    private var monoPendingChoke = false
    /// m32-f: which CHOKE GROUPS this note-on has already fired, one bit per
    /// group (hence the model's 0...63 range). Reset once per note-on, tested
    /// and set inside `trigger`.
    ///
    /// ⭐ IT EXISTS FOR THE LAYERING CASE. Mono needs no such memory because it
    /// disarms after the first zone that sounds; choke groups do, because ONE
    /// note-on can legitimately fire several zones (one per m19-a `group`) that
    /// share a choke group — an open hat layered with its own noise tail, say.
    /// Without the mask the second layer would choke the first, and the user
    /// would hear one of the two sounds they authored.
    private var chokeFiredMask: UInt64 = 0
    // m19-a RR/RNG runtime state (design §4.3): per-zone round-robin counters
    // and one xorshift64* state var — allocated/seeded in init (main actor),
    // mutated ONLY inside `apply(event:)` on the render thread, the same
    // single-writer discipline as `bendFactor`/`pedalDown`. Never model,
    // params, snapshot, or wire state; a zones change is structural, so the
    // rebuild resets counters (matches instrument-reload behavior). `reset()`
    // deliberately does NOT touch them — flush ≠ round-robin restart; offline
    // determinism comes from fresh init + the `randomSeed` test seam.
    private let rrCounters: UnsafeMutablePointer<UInt32>
    private var rngState: UInt64
    // Coefficients derived from the adopted snapshot — recomputed per
    // GENERATION change, never per sample.
    private var oneShot = false
    private var attackStep: Float = 0              // level units per sample
    private var releaseSlope: Float = 0            // fraction of releaseFrom per sample
    private var outputGain: Float = 0

    // MARK: - m27 continuous expression (render-thread scalars)

    /// Raw controller values, normalised 0...1, single-writer in
    /// `apply(event:)` exactly like `bendFactor`/`pedalDown`.
    ///
    /// ⚠️ Each defaults to FULL (1.0), NOT to `MIDIControllerType.neutral-
    /// Default`. That enum's neutral is 127 for CC11 but **0 for CC1 and
    /// CC2**, and it describes what the SCHEDULE injects at a block anchor
    /// when a lane of that type EXISTS. Here the question is different: what
    /// does an instrument that has never been sent this controller do? The
    /// only safe answer for an attenuator is "do not attenuate" — an
    /// untouched controller is not a closed one. A track with no CC lane at
    /// all therefore renders byte-identically to pre-m27.
    /// 128 controller values, normalised 0...1, allocated in init and never
    /// resized. ONE source of truth: the amplitude path (CC11/CC2/CC1), the
    /// leg-C filter's selected controller, and every zone's leg-B crossfade
    /// controller all read the same table, so they cannot drift apart.
    ///
    /// ⚠️ This DIVERGES from SFZ, deliberately: SFZ's `set_ccN` default is 0,
    /// which would make a zone that fades IN with a rising controller silent
    /// until the user touches that controller. Full is the safe default for an
    /// attenuator (see the note above) and it is the safe default here too —
    /// with a properly authored pp/ff pair it means the ff layer sounds until
    /// the controller moves, rather than nothing sounding at all.
    private let ccValues: UnsafeMutablePointer<Float>
    /// Which controllers are worth a target recompute — CC1/CC2/CC11, the
    /// filter's controller, and every controller some zone crossfades on.
    /// Without it a dense unrelated lane (CC7, say) would drive an O(64) voice
    /// sweep per point for no reason. Allocated in init; 128 bytes.
    private let ccInteresting: UnsafeMutablePointer<Bool>
    /// The combined amplitude multiplier the voices chase — recomputed only
    /// when a routed CC arrives or a new snapshot lands, never per frame.
    private var ampMultiplier: Float = 1
    /// CC1/CC2 depth from the live snapshot; 0 (the default) makes the
    /// CC1/CC2 factor exactly 1.0. See `SamplerParams.expressionModDepth`.
    private var expressionModDepth: Float = 0
    /// One-pole coefficient per sample for the `expGain` chase, derived from
    /// `expressionSmoothingSeconds` and the graph rate in `prepare()`/
    /// `recomputeCoefficients`. Never recomputed per frame.
    private var expressionRampCoeff: Float = 1
    /// Controller smoothing time constant. ~12 ms de-zippers a stepwise lane
    /// without audibly lagging a breath gesture (a real player's fastest
    /// useful dynamic inflection is far slower than this).
    private static let expressionSmoothingSeconds = 0.012
    /// Below this distance the exponential chase is snapped to its target,
    /// once per quantum — an exponential approach never arrives, and letting
    /// the difference decay forever is how a denormal tail is born.
    private static let expressionSnapEpsilon: Float = 1e-6

    // m27 leg C — per-voice low-pass driven by the expression controller.
    /// False (the default) SKIPS the filter branch entirely, which is the
    /// byte-identity guarantee for every project that never opts in.
    private var filterEnabled = false
    private var filterDepth: Float = 0
    private var filterCC: Int32 = 11
    /// One-pole coefficient `g` in `y += g × (x − y)`. Smoothed toward
    /// `filterGTarget` once per FRAME (not per voice) for the same
    /// stepwise-lane reason the amplitude is smoothed: an abrupt cutoff jump
    /// on a sustaining voice is an audible thump.
    private var filterG: Float = 1
    private var filterGTarget: Float = 1
    /// Below this magnitude the filter memory is flushed to true zero once per
    /// quantum. A one-pole fed silence decays geometrically forever, which is
    /// precisely the denormal tail the pre-m27 comment could truthfully say
    /// this instrument did not have.
    private static let denormalFloor: Float = 1e-20

    // Main-actor-only publish state (same retire-bin contract as
    // PolySynthInstrument / InstrumentRenderer).
    private var publishedGeneration: UInt64 = 0
    private var lastAppliedScalars: ScalarParams
    private var retired: [(snapshot: ParamSnapshot, retiredAt: ContinuousClock.Instant)] = []

    /// Loads every zone's audio file synchronously. Construction happens at
    /// reconcile time on the main actor (PlaybackGraph's instrument factory) —
    /// NEVER on the render thread. `sampleRate` is a provisional graph rate;
    /// `prepare()` overrides it before the node ever renders. `randomSeed` is
    /// the m19-a TEST SEAM: nil (production) seeds the selection RNG from
    /// `SystemRandomNumberGenerator`; a fixed seed makes random-gate zone
    /// selection — and therefore whole renders — deterministic.
    init(params: SamplerParams, sampleRate: Double = 48_000, randomSeed: UInt64? = nil) {
        self.sampleRate = sampleRate
        lastAppliedScalars = ScalarParams(params)
        // Seed the two render-thread settings from the SAME resolved snapshot
        // the first quantum will adopt, so they are already right for any event
        // that lands before that adoption. (Adoption then finds them equal and
        // does nothing — see `recomputeCoefficients`.)
        bendRangeSemitones = lastAppliedScalars.bendRangeSemitones
        monoVoiceMode = lastAppliedScalars.monoVoiceMode
        // xorshift64* has one degenerate state: 0 sticks at 0. Substitute a
        // fixed odd constant so a (vanishingly unlikely) zero seed still runs.
        var systemGenerator = SystemRandomNumberGenerator()
        let seed = randomSeed ?? systemGenerator.next()
        rngState = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed

        // m32-a: one decode per DISTINCT source file per load pass, keyed by
        // `SamplerZone.sourceFileKey`. Chopping points many zones at one long
        // file; before this, a 4-minute stereo rip cost 80.7 MiB PER ZONE (64
        // zones = 5.05 GB) and never errored — it just allocated. The cache is
        // LOCAL to `init` deliberately: a process-wide refcounted cache would
        // put a mutable global's lifetime in the hands of a `deinit` running
        // on an arbitrary thread while the retire bin may still let the render
        // thread read those exact bytes. See the `ownedChannelBuffers`
        // ownership law — the ledger owns, zones borrow.
        var loadedFiles: [String: LoadedFileBuffers] = [:]
        var loaded: [LoadedZone] = []
        for zone in params.zones {
            do {
                let source: LoadedFileBuffers
                if let cached = loadedFiles[zone.sourceFileKey] {
                    // HIT — skip the open and BOTH allocations. Every per-zone
                    // field below still resolves independently, against this
                    // file's cached frame count and rate.
                    source = cached
                } else {
                    let file = try AVAudioFile(forReading: zone.audioFileURL)
                    audioFileOpenCount += 1
                    // processingFormat is deinterleaved Float32 at the file's
                    // native rate, so floatChannelData below is always valid.
                    guard file.length > 0,
                          let buffer = AVAudioPCMBuffer(
                            pcmFormat: file.processingFormat,
                            frameCapacity: AVAudioFrameCount(file.length))
                    else {
                        zoneLoadNotes.append(
                            "zone skipped (empty file): \(zone.audioFileURL.lastPathComponent)")
                        continue
                    }
                    // ⚠️ m32-h: NOT a bare `file.read(into: buffer)`. A single
                    // read silently short-reads MONO files to a 1024-aligned
                    // position, taking up to 1023 frames (23.2 ms at 44.1 kHz)
                    // off the tail with no error — a drum one-shot's decay
                    // stopping early. Drum one-shots are usually mono, so this
                    // landed on exactly this loader. See `AudioFileFullRead`
                    // for the measurements and for why the intuitive
                    // "loop until frameLength == file.length" is worse.
                    try AudioFileFullRead.fill(buffer, from: file,
                                               frameCount: AVAudioFrameCount(file.length))
                    guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
                        zoneLoadNotes.append(
                            "zone skipped (no readable frames): "
                            + "\(zone.audioFileURL.lastPathComponent)")
                        continue
                    }
                    let frames = Int(buffer.frameLength)
                    // Honest-absence convention: a file that delivers fewer
                    // frames than its header claims is a real short file (the
                    // 1024 artefact can no longer cause this), and the user is
                    // told rather than left with a silently clipped tail.
                    if frames < Int(file.length) {
                        zoneLoadNotes.append(
                            "loaded short: \(frames) of \(file.length) frames from "
                            + "\(zone.audioFileURL.lastPathComponent)")
                    }
                    let left = UnsafeMutableBufferPointer<Float>.allocate(capacity: frames)
                    _ = left.initialize(from: UnsafeBufferPointer(start: channels[0], count: frames))
                    ownedChannelBuffers.append(left)
                    let rightBase: UnsafePointer<Float>
                    if Int(buffer.format.channelCount) >= 2 {
                        let right = UnsafeMutableBufferPointer<Float>.allocate(capacity: frames)
                        _ = right.initialize(
                            from: UnsafeBufferPointer(start: channels[1], count: frames))
                        ownedChannelBuffers.append(right)
                        rightBase = UnsafePointer(right.baseAddress!)
                    } else {
                        rightBase = UnsafePointer(left.baseAddress!)  // mono → both channels
                    }
                    source = LoadedFileBuffers(
                        left: UnsafePointer(left.baseAddress!),
                        right: rightBase,
                        frameCount: frames,
                        fileRate: file.processingFormat.sampleRate)
                    // Recorded only on SUCCESS. A file that fails a load guard
                    // above is retried (and re-noted) per zone — that keeps
                    // today's one-note-per-skipped-zone behaviour verbatim,
                    // and a failed open allocates nothing.
                    loadedFiles[zone.sourceFileKey] = source
                }
                let frames = source.frameCount
                // m19-a: resolve the optional selection fields ONCE, here —
                // nil collapses to the full-span/no-gate values so a legacy
                // zone is exactly the pre-m19 degenerate case.
                let seqLength = Int32(clamping: max(1, zone.seqLength ?? 1))
                // m19-b: playback scalars, resolved once (nil → the legacy
                // law — see the LoadedZone doc, especially the pan rule).
                let panL: Float
                let panR: Float
                if let pan = zone.pan {
                    let angle = (pan + 1) * Double.pi / 4
                    panL = Float(cos(angle))
                    panR = Float(sin(angle))
                } else {
                    panL = 1.0  // EXACT unity — the nil bit-compat contract
                    panR = 1.0
                }
                // start into 0..<frames, end into (start+1)...frames so at
                // least one frame always survives. The model init guarantees
                // start ≥ 0 and end > start, but a raw Codable decode
                // bypasses it — and these two bound POINTER reads, so the
                // engine re-clamps defensively; degenerate inputs get a note.
                let startFrame = min(max(0, zone.startFrame ?? 0), frames - 1)
                let endFrame = min(max(startFrame + 1, zone.endFrame ?? frames), frames)
                if zone.startFrame.map({ $0 != startFrame }) == true
                    || zone.endFrame.map({ $0 != endFrame }) == true {
                    zoneLoadNotes.append(
                        "zone start/end clamped to \(startFrame)..\(endFrame) "
                        + "(\(zone.audioFileURL.lastPathComponent) has \(frames) frames)")
                }
                // m20-g: loop resolution — model optionals collapse ONCE, defensively
                // re-clamped against the REAL file length (raw Codable decode bypasses the
                // model init, and these bound POINTER reads — the startFrame/endFrame rule).
                // loopEndExcl clamps to the resolved endFrame (not frames): an `end=` trim
                // bounds the loop too, and loopEndExcl ≤ endFrame is the invariant that
                // lets a looping voice never trip the `idx >= zone.endFrame` free check.
                // m32-d: a REVERSED zone plays its span once and ignores loops
                // entirely (design §7 — reversed-loop interaction is a real
                // design question v1 does not answer). Forcing the mode off
                // HERE, at load, is what keeps the render loop free of a
                // reverse branch: a reversed voice can never be `looping`, so
                // only the non-looping branch ever sees a direction scalar.
                let reverse = zone.reverse ?? false
                var loopMode: UInt8 = 0
                var loopStart = 0
                var loopEndExcl = endFrame
                if reverse, zone.loopMode != nil {
                    // Noted only when a loop was actually AUTHORED — a plain
                    // reversed zone must not spam a note about a loop it never
                    // had.
                    zoneLoadNotes.append(
                        "zone loop ignored (reverse zones play their span once in v1): "
                        + "\(zone.audioFileURL.lastPathComponent)")
                }
                if let mode = zone.loopMode, !reverse {             // .sustain / .continuous
                    loopStart = min(max(0, zone.loopStart ?? 0), frames - 1)
                    loopEndExcl = min(max(loopStart + 1, zone.loopEnd ?? endFrame), endFrame)
                    if loopEndExcl <= loopStart {                   // loop outside the span
                        zoneLoadNotes.append(
                            "zone loop disabled (loop \(zone.loopStart ?? 0)..\(zone.loopEnd ?? endFrame) "
                            + "outside the playable span \(startFrame)..\(endFrame) of "
                            + "\(zone.audioFileURL.lastPathComponent))")
                    } else {
                        loopMode = mode == .sustain ? 1 : 2
                        if (zone.loopStart.map { $0 != loopStart } == true)
                            || (zone.loopEnd.map { $0 != loopEndExcl } == true) {
                            zoneLoadNotes.append(
                                "zone loop clamped to \(loopStart)..\(loopEndExcl) "
                                + "(\(zone.audioFileURL.lastPathComponent) has \(frames) frames)")
                        }
                    }
                }
                let loopXfade = loopMode == 0 ? 0
                    : min(512, loopStart, loopEndExcl - loopStart)
                loaded.append(LoadedZone(
                    // m32-a: BORROWED from `ownedChannelBuffers`, never freed
                    // through the zone. Zones sharing a `sourceFileKey` share
                    // this exact pointer pair.
                    left: source.left,
                    right: source.right,
                    frameCount: frames,
                    fileRate: source.fileRate,
                    rootPitch: Int32(zone.rootPitch),
                    minPitch: Int32(zone.minPitch),
                    maxPitch: Int32(zone.maxPitch),
                    gain: Float(zone.gain),
                    minVel: Int32(zone.minVelocity ?? 0),
                    maxVel: Int32(zone.maxVelocity ?? 127),
                    group: Int32(clamping: zone.group ?? 0),
                    seqLength: seqLength,
                    seqPosition: min(Int32(clamping: max(1, zone.seqPosition ?? 1)), seqLength),
                    randLo: Float(zone.randMin ?? 0),
                    randHi: Float(zone.randMax ?? 1),
                    tuneFactor: zone.tuneCents.map { exp2($0 / 1_200.0) } ?? 1.0,
                    panL: panL,
                    panR: panR,
                    ampVelTrack: Float(zone.ampVelTrack ?? 1),
                    oneShotOverride: zone.oneShot.map { $0 ? 1 : 0 } ?? -1,
                    startFrame: startFrame,
                    endFrame: endFrame,
                    startFrameD: Double(startFrame),
                    reverse: reverse,
                    // Defensive clamp, not decoration: see the field's doc.
                    chokeGroup: zone.chokeGroup.map {
                        Int32(min(max(0, $0), 63))
                    } ?? -1,
                    envAttack: zone.attack.map { Float($0) } ?? -1,
                    envDecay: Float(zone.decay ?? 0),
                    envSustain: Float(zone.sustain ?? 1),
                    envRelease: zone.release.map { Float($0) } ?? -1,
                    loopMode: loopMode,
                    loopStart: loopStart,
                    loopEndExcl: loopEndExcl,
                    loopLen: Double(loopEndExcl - loopStart),
                    loopXfade: loopXfade,
                    invLoopXfade: loopXfade > 0 ? 1 / Float(loopXfade) : 0,
                    // m27 leg B — RESOLVED HERE, at load, never per frame.
                    // SFZ's own defaults (in 0/0, out 127/127) make an
                    // unauthored fade evaluate to exactly 1.0.
                    xfCC: Int32(zone.crossfade?.controller ?? -1),
                    hasCcXfade: zone.crossfade.map {
                        $0.controller != nil && ($0.ccInLo != nil || $0.ccInHi != nil
                            || $0.ccOutLo != nil || $0.ccOutHi != nil)
                    } ?? false,
                    xfCcInLo: Float(zone.crossfade?.ccInLo ?? 0),
                    xfCcInHi: Float(zone.crossfade?.ccInHi ?? 0),
                    xfCcOutLo: Float(zone.crossfade?.ccOutLo ?? 127),
                    xfCcOutHi: Float(zone.crossfade?.ccOutHi ?? 127),
                    hasVelXfade: zone.crossfade.map {
                        $0.velInLo != nil || $0.velInHi != nil
                            || $0.velOutLo != nil || $0.velOutHi != nil
                    } ?? false,
                    xfVelInLo: Float(zone.crossfade?.velInLo ?? 0),
                    xfVelInHi: Float(zone.crossfade?.velInHi ?? 0),
                    xfVelOutLo: Float(zone.crossfade?.velOutLo ?? 127),
                    xfVelOutHi: Float(zone.crossfade?.velOutHi ?? 127)))
            } catch {
                zoneLoadNotes.append(
                    "zone skipped (\(zone.audioFileURL.lastPathComponent)): "
                    + error.localizedDescription)
            }
        }
        // m19-a (design §4.1): stable-sort by group — explicit original-index
        // tiebreaker, so legacy zones (all group 0) keep their relative order
        // and today's first-match behavior byte-for-byte.
        let sorted = loaded.enumerated()
            .sorted { a, b in
                a.element.group != b.element.group
                    ? a.element.group < b.element.group
                    : a.offset < b.offset
            }
            .map(\.element)
        zoneCount = sorted.count
        zones = .allocate(capacity: max(1, sorted.count))
        for (index, zone) in sorted.enumerated() {
            zones.advanced(by: index).initialize(to: zone)
        }
        // Round-robin counters, one per (sorted) zone — zeroed at build, so a
        // structural rebuild restarts every cycle (design §4.3).
        rrCounters = .allocate(capacity: max(1, sorted.count))
        rrCounters.initialize(repeating: 0, count: max(1, sorted.count))
        // Init runs at reconcile time — stderr here is fine (same convention
        // as PlaybackGraph's unopenable-clip note), and never the render path.
        for note in zoneLoadNotes {
            FileHandle.standardError.write(Data("SamplerInstrument: \(note)\n".utf8))
        }

        voices = .allocate(capacity: Self.voiceCount)
        voices.initialize(repeating: Voice(), count: Self.voiceCount)
        // m27: the controller table and its interest mask — fixed 128-entry
        // blocks allocated HERE, at reconcile time, so the render path only
        // ever indexes them.
        ccValues = .allocate(capacity: 128)
        ccValues.initialize(repeating: 1, count: 128)
        ccInteresting = .allocate(capacity: 128)
        ccInteresting.initialize(repeating: false, count: 128)
        ccInteresting[1] = true    // mod wheel  → amplitude (depth-gated)
        ccInteresting[2] = true    // breath     → amplitude (depth-gated)
        ccInteresting[11] = true   // expression → amplitude, unconditional
        // Every controller some zone crossfades on. `zones` is fully built
        // above, so this sees the final set.
        for index in 0..<zoneCount {
            let controller = zones[index].xfCC
            if zones[index].hasCcXfade, controller >= 0, controller < 128 {
                ccInteresting[Int(controller)] = true
            }
        }
        paramsSlot = .allocate(capacity: 1)
        daw_atomic_ptr_init(paramsSlot)
        // Initial publish: nothing renders yet, so a plain exchange is safe.
        let snapshot = ParamSnapshot(generation: 0, params: lastAppliedScalars)
        _ = daw_atomic_ptr_exchange(
            paramsSlot, UnsafeMutableRawPointer(Unmanaged.passRetained(snapshot).toOpaque()))
    }

    deinit {
        if let raw = daw_atomic_ptr_exchange(paramsSlot, nil) {
            Unmanaged<ParamSnapshot>.fromOpaque(raw).release()
        }
        paramsSlot.deallocate()
        voices.deinitialize(count: Self.voiceCount)
        voices.deallocate()
        ccValues.deinitialize(count: 128)
        ccValues.deallocate()
        ccInteresting.deinitialize(count: 128)
        ccInteresting.deallocate()
        zones.deinitialize(count: zoneCount)
        zones.deallocate()
        rrCounters.deinitialize(count: max(1, zoneCount))
        rrCounters.deallocate()
        for buffer in ownedChannelBuffers {
            buffer.deallocate()
        }
    }

    // MARK: - Main-actor surface

    /// Publishes new SCALAR parameters (oneShot/attack/release/gain) for
    /// pickup at the top of the next render quantum. Held voices are NOT
    /// interrupted. The zones array is deliberately ignored here — zone
    /// changes are structural and rebuild the instrument via
    /// `PlaybackGraph.InstrumentTrackKey`. No-op when nothing changed, so
    /// callers may invoke this on every parameter pass.
    @MainActor
    func apply(params: SamplerParams) {
        let scalars = ScalarParams(params)
        guard scalars != lastAppliedScalars else { return }
        lastAppliedScalars = scalars
        publishedGeneration &+= 1
        let snapshot = ParamSnapshot(generation: publishedGeneration, params: scalars)
        let now = ContinuousClock.now
        let raw = UnsafeMutableRawPointer(Unmanaged.passRetained(snapshot).toOpaque())
        if let old = daw_atomic_ptr_exchange(paramsSlot, raw) {
            retired.append((Unmanaged<ParamSnapshot>.fromOpaque(old).takeRetainedValue(), now))
        }
        retired.removeAll { $0.retiredAt.duration(to: now) > .seconds(1) }
    }

    // MARK: - InstrumentRendering

    func prepare(sampleRate: Double, maxFramesPerQuantum: Int, channelCount: Int) {
        self.sampleRate = sampleRate
        lastParamsGeneration = .max  // ramp steps depend on the rate — readopt
    }

    func render(events: UnsafeBufferPointer<ScheduledMIDIEvent>,
                renderStart: Int64,
                frameCount: Int,
                output: UnsafeMutableAudioBufferListPointer) {
        guard let first = output.first, let firstData = first.mData else { return }
        let channel0 = firstData.assumingMemoryBound(to: Float.self)
        var channel1: UnsafeMutablePointer<Float>?
        if output.count > 1, let data = output[1].mData {
            channel1 = data.assumingMemoryBound(to: Float.self)
        }

        // Adopt a newly published scalar snapshot (borrowed — no
        // retain/release; the retire bin guarantees its lifetime).
        if let raw = daw_atomic_ptr_load(paramsSlot) {
            let snapshot = Unmanaged<ParamSnapshot>.fromOpaque(raw).takeUnretainedValue()
            if snapshot.generation != lastParamsGeneration {
                lastParamsGeneration = snapshot.generation
                recomputeCoefficients(snapshot.params)
            }
        }

        var eventIndex = 0
        for frame in 0..<frameCount {
            // Same delivery rule as PolySynthInstrument: apply every event
            // whose clamped in-quantum offset is this frame BEFORE rendering.
            while eventIndex < events.count {
                let event = events[eventIndex]
                let offset = max(0, Int(event.sampleTime - renderStart))
                guard offset <= frame else { break }
                apply(event)
                eventIndex += 1
            }
            let (left, right) = renderFrame()
            channel0[frame] = left * outputGain
            channel1?[frame] = right * outputGain
        }

        // NaN/Inf guard, once per quantum: a blown-up voice is hard-killed.
        // The envelope frees voices at exact 0, so IT has no denormal tail —
        // but the m27 expression chase is an exponential approach that never
        // arrives, so its residual difference IS a denormal source and is
        // snapped here. `expGain` joins the finiteness sweep for the same
        // reason `level` is in it: a NaN in a multiplier propagates forever
        // and nothing downstream would ever catch it.
        for index in 0..<Self.voiceCount where voices[index].active {
            if !(voices[index].level.isFinite && voices[index].position.isFinite
                 && voices[index].expGain.isFinite
                 && voices[index].lpZ1L.isFinite && voices[index].lpZ1R.isFinite) {
                voices[index] = Voice()
                continue
            }
            if abs(voices[index].expGainTarget - voices[index].expGain)
                < Self.expressionSnapEpsilon {
                voices[index].expGain = voices[index].expGainTarget
            }
            if filterEnabled {
                if abs(voices[index].lpZ1L) < Self.denormalFloor { voices[index].lpZ1L = 0 }
                if abs(voices[index].lpZ1R) < Self.denormalFloor { voices[index].lpZ1R = 0 }
            }
        }

        // Channels beyond stereo mirror the right channel.
        if output.count > 2 {
            let byteCount = frameCount * MemoryLayout<Float>.stride
            let source = channel1.map { UnsafeRawPointer($0) } ?? UnsafeRawPointer(firstData)
            for buffer in output.dropFirst(2) {
                guard let data = buffer.mData else { continue }
                memcpy(data, source, min(Int(buffer.mDataByteSize), byteCount))
            }
        }
    }

    /// All-notes-off NOW (flush contract): immediate hard silence. Output is
    /// true zeros until the next noteOn.
    /// m16-b2: controller state neutralizes with the voice wipe — bend to
    /// center, pedal up (design-m16b §4.3).
    /// m19-a: round-robin counters and the RNG deliberately SURVIVE — a
    /// mid-song stop/seek must not restart every alternation cycle (flush ≠
    /// RR restart, design §4.3); determinism comes from fresh structural init
    /// plus the `randomSeed` seam.
    func reset() {
        for index in 0..<Self.voiceCount {
            voices[index] = Voice()
        }
        bendFactor = 1.0
        lastBendRaw = 8_192
        pedalDown = false
        // Mono's note identity is PERFORMANCE state, not configuration, so it
        // neutralises with the voice wipe exactly like the bend re-centre
        // above. Surviving it would let a post-flush note-off be discarded as
        // "superseded" by a note that no longer exists. `monoVoiceMode` itself
        // is configuration and deliberately SURVIVES, like oneShot.
        monoActiveNoteID = 0
        monoStarted = false
        monoPendingChoke = false
        chokeFiredMask = 0
        // m27: controller state neutralises with the voice wipe, exactly like
        // the bend re-centre above. A stale attenuator surviving a stop/seek
        // would quietly duck the next notes; if a lane really is present, the
        // schedule's chase prefix re-delivers its true value at the next block
        // anchor before any note sounds.
        for controller in 0..<128 { ccValues[controller] = 1 }
        ampMultiplier = 1
        // The voice wipe above already zeroed every filter memory (`Voice()`),
        // so the cutoff just returns to its neutral-controller position.
        refreshFilterTarget()
        filterG = filterGTarget
    }

    // MARK: - Per-sample playback (render thread)

    @inline(__always)
    private func renderFrame() -> (left: Float, right: Float) {
        var left: Float = 0
        var right: Float = 0
        // m27 leg C: the cutoff coefficient is INSTRUMENT-wide (one controller
        // stream per instrument track), so it is smoothed ONCE per frame here
        // rather than 64 times inside the voice loop.
        if filterEnabled {
            filterG += (filterGTarget - filterG) * expressionRampCoeff
        }
        for index in 0..<Self.voiceCount where voices[index].active {
            // 1. Envelope — linear segments through the m19-b 4-stage machine
            //    (the PolySynthInstrument pattern), per-voice coefficients
            //    captured at trigger. Nil-field zones carry decayStep 0 /
            //    sustainLevel 1, which reproduces the original
            //    attack→hold→release level sequence sample-for-sample. The
            //    release ramp subtracts a fixed fraction of the level
            //    captured at noteOff, so it reaches EXACTLY 0 after `release`
            //    seconds and frees the voice (true zeros from then on).
            switch voices[index].stage {
            case Stage.attack:
                voices[index].level += voices[index].attackStep
                if voices[index].level >= 1 {
                    voices[index].level = 1
                    voices[index].stage = Stage.decay
                }
            case Stage.decay:
                voices[index].level -= voices[index].decayStep
                if voices[index].level <= voices[index].sustainLevel {
                    voices[index].level = voices[index].sustainLevel
                    voices[index].stage = Stage.sustain
                }
            case Stage.sustain:
                // Holds the PER-VOICE sustain level captured at trigger — no
                // live tracking (there is no global sustain to track).
                voices[index].level = voices[index].sustainLevel
            default:  // Stage.release
                voices[index].level -= voices[index].releaseFrom * voices[index].releaseSlope
                if voices[index].level <= 0 {
                    voices[index] = Voice()  // freed — contributes nothing
                    continue
                }
            }

            // 1b. m27 expression chase — ONE one-pole step per voice per
            //     frame (sub, mul, add). Placed here so BOTH the looping and
            //     non-looping branches below see the same updated value
            //     exactly once. When target == current == 1.0 this is
            //     `1 + 0 × c = 1`, bit-exact, which is what keeps a
            //     lane-free project byte-identical to pre-m27.
            voices[index].expGain += (voices[index].expGainTarget
                - voices[index].expGain) * expressionRampCoeff

            // 2. Source read at the CURRENT playhead with linear
            //    interpolation, then advance. The looping branch (m20-g §3.5)
            //    wraps sample-accurately and crossfades the seam; the
            //    non-looping branch is the pre-m20-g path kept VERBATIM — the
            //    byte-identity guarantee for every non-looping voice (old
            //    projects, no-loop zones, sustain voices after disarm).
            let zone = zones[Int(voices[index].zoneIndex)]
            if voices[index].looping {
                var position = voices[index].position
                // 2a. Sample-accurate wrap BEFORE the read, so idx < loopEndExcl
                //     always. One truncatingRemainder handles ANY overshoot (a
                //     tiny loop under a huge pitch-up increment can overshoot by
                //     multiples of loopLen) — constant-time libm, no allocation
                //     (render-thread precedent: exp2 in the bend path).
                if position >= Double(zone.loopEndExcl) {
                    position = Double(zone.loopStart)
                        + (position - Double(zone.loopStart))
                            .truncatingRemainder(dividingBy: zone.loopLen)
                    voices[index].position = position
                }
                let idx = Int(position)
                let frac = Float(position - Double(idx))
                // 2b. Seam interpolation: the frame AFTER loopEndExcl−1 is
                //     loopStart — never 0, never left[loopEndExcl].
                let next = idx + 1 >= zone.loopEndExcl ? zone.loopStart : idx + 1
                let l0 = zone.left[idx], r0 = zone.right[idx]
                var sL = l0 + (zone.left[next] - l0) * frac
                var sR = r0 + (zone.right[next] - r0) * frac
                // 2c. Equal-gain seam crossfade over the final loopXfade frames
                //     of the pass: blend toward the pre-loop-start material,
                //     time-aligned to land exactly on loopStart at the wrap.
                if zone.loopXfade > 0 {
                    let into = position - Double(zone.loopEndExcl - zone.loopXfade)
                    if into >= 0 {
                        let g = Float(into) * zone.invLoopXfade      // 0 → 1 across the window
                        let inPos = position - zone.loopLen          // ∈ [loopStart−X, loopStart)
                        let inIdx = Int(inPos)                       // ≥ 0 because X ≤ loopStart
                        let inFrac = Float(inPos - Double(inIdx))
                        let inNext = inIdx + 1                       // ≤ loopStart ≤ frames−1: in bounds
                        let i0 = zone.left[inIdx], j0 = zone.right[inIdx]
                        let iL = i0 + (zone.left[inNext] - i0) * inFrac
                        let iR = j0 + (zone.right[inNext] - j0) * inFrac
                        sL += (iL - sL) * g                          // (1−g)·current + g·incoming
                        sR += (iR - sR) * g
                    }
                }
                // m27 leg C: filter the SOURCE, before the amplitude product —
                // the gain is no longer constant, so filter-after-amp would
                // not be the same system. Skipped entirely when disabled.
                if filterEnabled {
                    voices[index].lpZ1L += (sL - voices[index].lpZ1L) * filterG
                    sL = voices[index].lpZ1L
                    voices[index].lpZ1R += (sR - voices[index].lpZ1R) * filterG
                    sR = voices[index].lpZ1R
                }
                // m27: expGain multiplies LAST, so at 1.0 the product is the
                // pre-m27 one bit-for-bit (×1.0 is an IEEE identity).
                left += sL * (voices[index].level * voices[index].gainL * voices[index].expGain)
                right += sR * (voices[index].level * voices[index].gainR * voices[index].expGain)
                voices[index].position = position + voices[index].increment
            } else {
                // m32-d: the read frame is `readBase + readDir × position`.
                // Forward voices carry base 0 / dir +1, so this is `0 + 1.0 × x`
                // — an IEEE identity, the same Double the loop used before this
                // item, bit for bit. Reversed voices walk the same span
                // backwards. Interpolation is UNCHANGED and direction-agnostic:
                // a fractional position always sits between `idx` and `idx + 1`
                // of the underlying signal, whichever way the playhead travels.
                let position = voices[index].readBase
                    + voices[index].readDir * voices[index].position
                let idx = Int(position)
                // The span check is two-sided now. The high half is the shipped
                // check, VERBATIM and first, so a forward voice frees itself on
                // exactly the frame it always did. The low half can only ever
                // fire for a REVERSED voice — a forward one starts at
                // `startFrame` and `increment` is always > 0 — and it is a
                // Double compare, not `idx < startFrame`: `Int` truncates
                // TOWARD ZERO, so on a zone with `startFrame == 0` a reversed
                // playhead at −0.5 would give idx 0, pass an integer check, and
                // read a NEGATIVE fraction (an extrapolated sample). This is
                // the whole-file reversed zone, i.e. the common case.
                if idx >= zone.endFrame || position < zone.startFrameD {
                    voices[index] = Voice()
                    continue
                }
                let frac = Float(position - Double(idx))
                let next = idx + 1
                let l0 = zone.left[idx]
                let r0 = zone.right[idx]
                let l1 = next < zone.endFrame ? zone.left[next] : 0
                let r1 = next < zone.endFrame ? zone.right[next] : 0
                // Hoisted into locals so leg C's filter can sit between the
                // source read and the amplitude product; the arithmetic and
                // its ORDER are unchanged from pre-m27, which is what keeps
                // the filter-disabled path bit-exact.
                var sL = l0 + (l1 - l0) * frac
                var sR = r0 + (r1 - r0) * frac
                if filterEnabled {
                    voices[index].lpZ1L += (sL - voices[index].lpZ1L) * filterG
                    sL = voices[index].lpZ1L
                    voices[index].lpZ1R += (sR - voices[index].lpZ1R) * filterG
                    sR = voices[index].lpZ1R
                }
                left += sL * (voices[index].level * voices[index].gainL * voices[index].expGain)
                right += sR * (voices[index].level * voices[index].gainR * voices[index].expGain)
                // ⚠️ m32-d: the LOCAL coordinate advances, not the read frame.
                // `position` above is now `base + dir × local`, so re-adding
                // the increment to IT would run a reversed voice forwards
                // (and, worse, would be invisible on every forward voice).
                // For a forward voice `local == position`, so this is the same
                // arithmetic on the same value as before the item.
                voices[index].position += voices[index].increment
            }
        }
        return (left, right)
    }

    /// Render thread, once per adopted snapshot generation — pure float math,
    /// no allocation. `max(1, …)` makes attack = 0 a single-frame jump to
    /// full level rather than a divide-by-zero. The global attackStep/
    /// releaseSlope stay hot-swappable and are the trigger-time fallback for
    /// zones without their own envelope fields (design §4.4).
    private func recomputeCoefficients(_ params: ScalarParams) {
        oneShot = params.oneShot
        attackStep = Float(1.0 / max(1.0, params.attack * sampleRate))
        releaseSlope = Float(1.0 / max(1.0, params.release * sampleRate))
        outputGain = Float(params.gain)
        // m27: the ramp coefficient is rate-dependent, so it belongs here (and
        // `prepare()` already forces a re-adopt on a rate change). One `exp`
        // per SNAPSHOT — never per frame, never per event.
        expressionRampCoeff = Float(
            1.0 - exp(-1.0 / max(1.0, Self.expressionSmoothingSeconds * sampleRate)))
        // Voice mode takes effect on the NEXT note-on: switching poly → mono
        // does not choke what is already sounding. Chopping held voices at a
        // snapshot boundary would be a gain step on every one of them — the
        // click `expGain` exists to prevent — for a mode change the user made
        // between notes anyway.
        monoVoiceMode = params.monoVoiceMode
        // A range change must retune a note that is CURRENTLY deflected, or a
        // held note keeps the old range until the lane's next point. One
        // compare per generation; the sweep is the bend branch's own shape and
        // only runs when the number actually moved (so the common
        // snapshot-with-unchanged-range costs nothing and, critically, an
        // unchanged range cannot perturb `bendFactor`'s bits).
        if params.bendRangeSemitones != bendRangeSemitones {
            bendRangeSemitones = params.bendRangeSemitones
            applyBendFactor()
        }
        expressionModDepth = Float(params.expressionModDepth)
        filterDepth = Float(params.expressionFilterDepth)
        filterCC = Int32(params.expressionFilterCC)
        let wasEnabled = filterEnabled
        filterEnabled = params.expressionFilterDepth > 0
        if filterEnabled, filterCC >= 0, filterCC < 128 {
            ccInteresting[Int(filterCC)] = true
        }
        if filterEnabled, !wasEnabled {
            // Turning the filter ON mid-flight starts every voice's memory
            // from silence rather than from stale garbage.
            for index in 0..<Self.voiceCount {
                voices[index].lpZ1L = 0
                voices[index].lpZ1R = 0
            }
            filterG = 1          // start open; the chase takes it down
        }
        refreshExpressionTargets()
        refreshFilterTarget()
    }

    /// Maps the driving controller to a one-pole coefficient. ALL the
    /// expensive math — one `exp`, one `pow` — happens HERE, at CC-event and
    /// snapshot rate, never per frame and never per voice. The render loop
    /// sees only `y += g × (x − y)`.
    ///
    /// The precedent for a libm call on this thread is the pitch-bend branch's
    /// `exp2` (one per applied bend event); this is the same bounded shape.
    @inline(__always)
    private func refreshFilterTarget() {
        guard filterEnabled else {
            filterGTarget = 1
            return
        }
        let driver = ccValues[Int(filterCC)]
        // cutoff = low × (high/low)^(1 − depth × (1 − driver)), log-interpolated.
        let low = SamplerParams.expressionFilterLowHz
        let high = SamplerParams.expressionFilterHighHz
        let exponent = Double(1 - filterDepth * (1 - driver))
        let cutoff = low * pow(high / low, exponent)
        // g = 1 − e^(−2π fc / fs), the standard one-pole. Clamped to ≤ 1 so a
        // cutoff above Nyquist can never make the filter unstable.
        let g = 1.0 - exp(-2.0 * Double.pi * cutoff / max(1.0, sampleRate))
        filterGTarget = Float(min(1.0, max(0.0, g)))
    }

    /// Recomputes the amplitude multiplier and pushes it to every sounding
    /// voice. Called at CC-event rate and on a snapshot change — NOT per
    /// frame. The O(64) in-place sweep is the SAME shape the pitch-bend branch
    /// has always used (see `apply(_:)`, the `voices[index].increment` loop):
    /// bounded, allocation-free, no locks, no ObjC.
    @inline(__always)
    private func refreshExpressionTargets() {
        // min(), not a product: CC1 and CC2 are alternative spellings of the
        // same gesture ("how hard am I blowing"), and multiplying two
        // attenuators that both mean it would double-attenuate a player who
        // sends both. Each sits at 1.0 until its first event, so a lane on
        // only one of them is that one's value exactly.
        let dynamics = min(ccValues[2], ccValues[1])
        // depth 0 → (1 − 0 × x) = 1.0 exactly → ampMultiplier == CC11.
        ampMultiplier = ccValues[11] * (1 - expressionModDepth * (1 - dynamics))
        for index in 0..<Self.voiceCount where voices[index].active {
            // m27 leg B: the CONTINUOUS half of the crossfade re-evaluates
            // here, so a held note really does change layer as the controller
            // moves; the VELOCITY half was fixed at note-on. Both are exactly
            // 1.0 for a zone without crossfade opcodes.
            voices[index].expGainTarget = ampMultiplier * voices[index].velXfade
                * ccCrossfadeGain(zones[Int(voices[index].zoneIndex)])
        }
    }

    /// Equal-power fade-in × fade-out for the CC domain. SFZ's documented
    /// DEFAULT curve is `power` (verified at sfzformat.com), i.e. the square
    /// root of the linear ramp; `xf_cccurve`/`xf_velcurve` are not read, and
    /// the importer reason-codes them so a file asking for `gain` is never
    /// silently given `power`. Returns EXACTLY 1.0 for a zone with no
    /// crossfade, because the resolved defaults (in 0/0, out 127/127) make
    /// both halves saturate — `sqrt(1) == 1`, an IEEE identity.
    @inline(__always)
    private func ccCrossfadeGain(_ zone: LoadedZone) -> Float {
        guard zone.hasCcXfade, zone.xfCC >= 0 else { return 1 }
        let value = ccValues[Int(zone.xfCC)] * 127
        return Self.fadeIn(value, zone.xfCcInLo, zone.xfCcInHi)
            * Self.fadeOut(value, zone.xfCcOutLo, zone.xfCcOutHi)
    }

    /// The velocity domain, evaluated once at note-on.
    @inline(__always)
    private func velocityCrossfadeGain(_ zone: LoadedZone, velocity: Float) -> Float {
        guard zone.hasVelXfade else { return 1 }
        return Self.fadeIn(velocity, zone.xfVelInLo, zone.xfVelInHi)
            * Self.fadeOut(velocity, zone.xfVelOutLo, zone.xfVelOutHi)
    }

    /// 0 below `lo`, 1 at/above `hi`, equal-power between. `hi <= lo` is a
    /// hard step at `lo` — which is exactly what SFZ's default 0/0 gives, and
    /// why an unauthored fade-in is 1.0 everywhere.
    @inline(__always)
    private static func fadeIn(_ value: Float, _ lo: Float, _ hi: Float) -> Float {
        if value >= hi { return 1 }
        if value <= lo || hi <= lo { return 0 }
        return ((value - lo) / (hi - lo)).squareRoot()
    }

    /// 1 at/below `lo`, 0 at/above `hi`, equal-power between. SFZ's default
    /// 127/127 makes it 1.0 for every legal value.
    @inline(__always)
    private static func fadeOut(_ value: Float, _ lo: Float, _ hi: Float) -> Float {
        if value <= lo { return 1 }
        if value >= hi || hi <= lo { return 0 }
        return ((hi - value) / (hi - lo)).squareRoot()
    }

    // MARK: - Voice allocation (render thread)

    private func apply(_ event: ScheduledMIDIEvent) {
        if event.kind == ScheduledMIDIEvent.noteOn {
            // m19-a selection (design §4.2): ONE random draw per note-on (SFZ
            // semantics), then one pass over the group-sorted zone array
            // firing ONE voice per group — the first zone in each group that
            // matches both spans and passes its round-robin + random gates.
            // Legacy zones (all group 0, full spans, no gates) degenerate to
            // the original first-match scan; no eligible zone → the note is
            // silently ignored. O(zoneCount) compares, no allocation.
            // MONO, last-note priority: arm the choke. It fires inside
            // `trigger` — the first zone this note-on actually sounds — never
            // here, so a note that selects no zone leaves the sounding note
            // alone rather than opening a hole.
            monoPendingChoke = monoVoiceMode
            // m32-f: ARM here, FIRE in `trigger` — the exact `monoPendingChoke`
            // discipline, for the exact same reason. Choking in this selection
            // loop would let a note-on that ultimately selects NO zone (out of
            // every pitch/velocity span, or gated out by round-robin) silence
            // the note that IS sounding, opening a hole nobody asked for.
            chokeFiredMask = 0
            let pitch = Int32(event.pitch)
            let velocity = Int32(event.velocity)
            let draw = nextRandom01()
            var lastFiredGroup = Int32.min  // sentinel: no group fired yet
            for index in 0..<zoneCount {
                let zone = zones[index]
                guard pitch >= zone.minPitch, pitch <= zone.maxPitch,
                      velocity >= zone.minVel, velocity <= zone.maxVel else { continue }
                // The round-robin counter advances on EVERY range match (the
                // ARIA per-region convention) — even when a later gate or the
                // one-per-group rule skips the zone this time.
                rrCounters[index] &+= 1
                let count = rrCounters[index] &- 1
                if zone.seqLength > 1,
                   Int32(count % UInt32(zone.seqLength)) != zone.seqPosition - 1 {
                    continue
                }
                // Random gate: [randLo, randHi), closed at the top when
                // randHi ≥ 1 so a hirand=1 zone can never lose the draw.
                guard zone.randLo <= draw, draw < zone.randHi || zone.randHi >= 1 else {
                    continue
                }
                if zone.group == lastFiredGroup { continue }  // group already fired
                trigger(zoneIndex: index, event: event)
                lastFiredGroup = zone.group
            }
        } else if event.kind == ScheduledMIDIEvent.noteOff {
            // MONO, and this is the decision the mode turns on: a note-off for
            // a note mono has already SUPERSEDED is DISCARDED — there is no
            // fall-back to a note still held underneath.
            //
            // Both behaviours are defensible on a keyboard synth; on a wind
            // instrument only this one is. The overlap that triggers the case
            // at all is the LEGATO idiom — write A, start B before A ends, so
            // the two slur — and in that idiom A's note-off arrives AFTER B has
            // started. Falling back would fire a phantom backwards slur to A on
            // every slurred pair in the part, which is both wrong and the exact
            // thing the writing was trying to express. The keyboard convention
            // exists so a player can trill by holding a low note with the other
            // hand; a sax player has one airstream and cannot do that. The
            // earlier note ended when the player moved, and it cannot come back
            // without a new articulation — i.e. without a new note-on.
            //
            // Identity, not liveness: `monoActiveNoteID` is never cleared on
            // note-off, so a superseded note stays superseded after the current
            // note has also ended. `monoStarted` keeps the rule off voices that
            // began under poly.
            if monoVoiceMode, monoStarted, event.noteID != monoActiveNoteID { return }
            for index in 0..<Self.voiceCount
            where voices[index].active && voices[index].noteID == event.noteID {
                // m19-b per-voice one-shot: the zone override (0/1) wins; the
                // inherit sentinel (-1) resolves against the LIVE global at
                // noteOff time — exactly the pre-m19-b semantics, where a
                // mid-note global toggle changed noteOff handling. A one-shot
                // voice ignores its noteOff and never marks `sustained`, so
                // the pedal-up sweep stays a structural no-op for it.
                let oneShotState = voices[index].oneShotOverride
                if oneShotState < 0 ? oneShot : oneShotState == 1 { continue }
                if pedalDown {
                    // Sustain (m16-b2): the pedal DEFERS the release — the
                    // voice keeps sounding, marked for the pedal-up sweep.
                    voices[index].sustained = true
                } else if voices[index].level <= 0 {
                    voices[index] = Voice()  // off before the first audible sample
                } else {
                    // m20-g: a sustain loop disarms at true release start —
                    // the voice plays THROUGH the loop end into the tail.
                    if voices[index].loopMode == 1 { voices[index].looping = false }
                    voices[index].stage = Stage.release
                    voices[index].releaseFrom = voices[index].level
                }
            }
        } else if event.kind == ScheduledMIDIEvent.controlChange {
            // m16-b2 (design-m16b §4.3): the built-in honors CC64 (sustain)
            // only; every other CC is deliberately ignored here (documented —
            // hosted AUs receive them all). One-shot voices never mark
            // `sustained`, so the pedal-up sweep is a structural no-op there.
            if event.pitch == 64 {
                let down = event.velocity >= 64
                if pedalDown, !down {
                    // Pedal up: release every pedal-held voice — the deferred
                    // noteOffs, delivered now.
                    for index in 0..<Self.voiceCount
                    where voices[index].active && voices[index].sustained {
                        voices[index].sustained = false
                        if voices[index].level <= 0 {
                            voices[index] = Voice()
                        } else {
                            // m20-g: the pedal-up sweep is the OTHER true
                            // release start — sustain loops disarm here too.
                            if voices[index].loopMode == 1 { voices[index].looping = false }
                            voices[index].stage = Stage.release
                            voices[index].releaseFrom = voices[index].level
                        }
                    }
                }
                pedalDown = down
            } else if event.pitch < 128 {
                // m27: every controller lands in the table (one source of
                // truth), but only an INTERESTING one — CC1/CC2/CC11, the
                // leg-C filter's controller, or a controller some zone
                // crossfades on — pays for a target recompute. THE ONE DATA
                // RULE: pitch is the controller number, velocity the value.
                // Nothing here allocates, locks, or logs; the O(64) sweep
                // inside `refreshExpressionTargets` is the pitch-bend
                // branch's shape.
                let controller = Int(event.pitch)
                ccValues[controller] = Float(min(event.velocity, 127)) * (1.0 / 127.0)
                if ccInteresting[controller] {
                    refreshExpressionTargets()
                    refreshFilterTarget()
                }
            }
        } else if event.kind == ScheduledMIDIEvent.pitchBend {
            // m16-b2: data1 = LSB, data2 = MSB (THE ONE DATA RULE); center
            // 8192 → factor 1. Playback-rate bend, applied to every sounding
            // voice in place — releasing tails bend too.
            lastBendRaw = Int(event.pitch & 0x7F) | (Int(event.velocity & 0x7F) << 7)
            applyBendFactor()
        }
        // Channel pressure (kind 4) and any future kind fall through
        // silently — the C4 unknown-kind contract.
    }

    /// Re-derives `bendFactor` from the last raw bend value and the live range,
    /// then pushes it onto every sounding voice. Render thread: one `exp2` and
    /// an O(64) sweep — the shape the pitch-bend branch has always had — with
    /// no allocation, no lock and no ObjC.
    ///
    /// ⚠️ The arithmetic is character-for-character what the pitch-bend branch
    /// used to inline, in the same associativity: `(raw − 8192)/8192 × range`
    /// THEN `/ 12`. Refactoring it into `range/12` first would change the
    /// rounding and break the byte-identity guarantee at the default.
    @inline(__always)
    private func applyBendFactor() {
        bendFactor = exp2(Double(lastBendRaw - 8_192) / 8_192.0
                          * bendRangeSemitones / 12.0)
        for index in 0..<Self.voiceCount where voices[index].active {
            voices[index].increment = voices[index].baseIncrement * bendFactor
        }
    }

    /// MONO choke: the previous note ends because the player moved.
    ///
    /// Every sounding voice is put into its RELEASE stage rather than hard-
    /// killed — a hard kill is a gain step, i.e. a click, on exactly the held
    /// notes this mode exists to serve; the release ramp is the same anti-click
    /// ramp a note-off uses, and the brief overlap it leaves IS the slur.
    ///
    /// Two deliberate departures from the note-off path, both because mono is a
    /// stronger statement than either thing it overrides:
    ///  · the SUSTAIN PEDAL does not defer this. A pedal-held voice is still a
    ///    sounding voice, and "one note at a time" would be a lie if CC64 could
    ///    suspend it.
    ///  · ONE-SHOT voices are choked too. One-shot says "ignore note-OFF"; this
    ///    is not a note-off. A one-shot sampler set to mono is a choke group —
    ///    the hi-hat convention — which is the only reading of that combination
    ///    that does anything at all.
    /// Render thread; one O(64) sweep, no allocation.
    @inline(__always)
    private func monoChoke() {
        choke(group: Self.chokeEveryVoice)
    }

    /// `choke(group:)`'s "no filter" sentinel — the mono law, where every
    /// sounding voice is a candidate. Deliberately outside 0...63, the model's
    /// own choke-group range, so it can never collide with a real group.
    private static let chokeEveryVoice: Int32 = -1

    /// THE ONE CHOKE IN THIS INSTRUMENT (m32-f). Mono voice mode and per-zone
    /// choke groups differ ONLY in which voices are candidates; what happens to
    /// a chosen voice is one body, so the two can never drift into sounding
    /// different. The body below is `monoChoke`'s, unchanged — no new ramp, no
    /// hard cut, no invented constant.
    ///
    /// `group == chokeEveryVoice` is mono's sweep; `group >= 0` chokes only
    /// voices whose ZONE carries that choke group. The filter costs one compare
    /// per voice in an event-rate O(64) sweep — never per frame.
    ///
    /// ⭐ Called from `trigger` BEFORE the new voice's slot is written, so a
    /// note can never choke itself, and (via the per-note-on fired mask) two
    /// same-group zones LAYERED by one note-on cannot choke each other.
    @inline(__always)
    private func choke(group: Int32) {
        for index in 0..<Self.voiceCount where voices[index].active {
            if group >= 0, voices[index].chokeGroup != group { continue }
            if voices[index].level <= 0 {
                voices[index] = Voice()  // never audible; free the slot outright
                continue
            }
            // m20-g: a sustain loop disarms at true release start, exactly as
            // in the note-off and pedal-up paths. A continuous loop keeps
            // looping through its release, also as there.
            if voices[index].loopMode == 1 { voices[index].looping = false }
            voices[index].sustained = false
            voices[index].stage = Stage.release
            voices[index].releaseFrom = voices[index].level
        }
    }

    /// Starts one voice on `zoneIndex` — the same slot-scan/oldest-steal
    /// policy as ever, factored out so the m19-a selection loop can fire one
    /// voice per GROUP on a single note-on. Render thread; no allocation.
    @inline(__always)
    private func trigger(zoneIndex: Int, event: ScheduledMIDIEvent) {
        // MONO: the armed choke fires HERE, at the first zone this note-on
        // actually sounds, and disarms itself — so a multi-group note-on chokes
        // the previous note once and never its own earlier group.
        if monoPendingChoke {
            monoPendingChoke = false
            monoChoke()
            monoActiveNoteID = event.noteID
            monoStarted = true
        }
        let zone = zones[zoneIndex]
        // m32-f: the per-zone choke, fired HERE — before this voice's slot is
        // written, so the note can never choke itself — and at most ONCE per
        // choke group per note-on, so same-group layers do not choke each
        // other. `chokeGroup` is resolved into −1...63 at load, so the shift
        // below cannot overflow.
        if zone.chokeGroup >= 0 {
            let bit = UInt64(1) << UInt64(zone.chokeGroup)
            if chokeFiredMask & bit == 0 {
                chokeFiredMask |= bit
                choke(group: zone.chokeGroup)
            }
        }
        var slot = -1
        var oldestSerial = UInt64.max
        var oldestIndex = 0
        for index in 0..<Self.voiceCount {
            if !voices[index].active {
                slot = index
                break
            }
            if voices[index].serial < oldestSerial {
                oldestSerial = voices[index].serial
                oldestIndex = index
            }
        }
        if slot < 0 { slot = oldestIndex }  // steal the oldest voice

        var voice = Voice()
        voice.active = true
        voice.noteID = event.noteID
        voice.serial = nextSerial
        voice.zoneIndex = Int32(zoneIndex)
        voice.stage = Stage.attack
        voice.oneShotOverride = zone.oneShotOverride
        // m20-g (§3.4): arm the loop; a looping voice is NEVER one-shot —
        // forcing the explicit non-one-shot override beats both the zone
        // override and the live global (§2.1: loopMode wins over oneShot).
        voice.loopMode = zone.loopMode
        voice.looping = zone.loopMode != 0
        if voice.looping { voice.oneShotOverride = 0 }
        // m32-f: copied so the choke sweep never dereferences `zones`.
        voice.chokeGroup = zone.chokeGroup
        voice.position = Double(zone.startFrame)
        // m32-d: the direction scalar. Forward keeps `Voice()`'s defaults
        // (base 0, dir +1) UNTOUCHED, so the read expression collapses to the
        // IEEE identity `0 + 1.0 × position` and a forward voice is
        // bit-identical to pre-m32-d. A reversed voice starts at `endFrame − 1`
        // and walks down to `startFrame`: with `position` starting at
        // `startFrame` and rising, `base − position` runs endFrame−1 … start.
        if zone.reverse {
            voice.readBase = Double(zone.endFrame - 1 + zone.startFrame)
            voice.readDir = -1
        }
        // m19-b: the zone's precomputed tune factor rides the SAME multiply
        // chain (×1.0 for nil zones is a float identity — bit-compat).
        voice.baseIncrement = exp2((Double(event.pitch) - Double(zone.rootPitch)) / 12.0)
            * zone.tuneFactor * zone.fileRate / sampleRate
        voice.increment = voice.baseIncrement * bendFactor  // bend applies now
        // Amp law (design §4.5): (1 − vt + vt·velocity/127) × zone.gain, with
        // params.gain staying in outputGain (hot-swap preserved). vt = 1 (nil)
        // reduces to (0 + velocity/127) × gain — today's law bit-for-bit; the
        // per-channel gains fold in the pan (nil → ×1.0 identity).
        let velocityAmp = 1 - zone.ampVelTrack
            + zone.ampVelTrack * (Float(event.velocity) / 127.0)
        let amp = velocityAmp * zone.gain
        voice.gainL = amp * zone.panL
        voice.gainR = amp * zone.panR
        // m27: a new voice starts AT the live expression value rather than
        // ramping up to it — the amp envelope is what shapes an attack, and
        // ramping here would make a note struck at low expression bloom
        // wrongly. With no CC ever received this is 1.0 (an IEEE identity).
        // m27 leg B: the velocity half is fixed now, for good; the CC half
        // keeps moving with the controller. Both are 1.0 without opcodes.
        voice.velXfade = velocityCrossfadeGain(zone, velocity: Float(event.velocity))
        let target = ampMultiplier * voice.velXfade * ccCrossfadeGain(zone)
        voice.expGainTarget = target
        voice.expGain = target
        // Envelope coefficients (design §4.4): four divides at trigger; the
        // -1 sentinel falls back to the LIVE global coefficients, so nil
        // zones keep following global attack/release hot-swaps for voices
        // triggered AFTER the swap (the documented semantic shift: already-
        // sounding voices no longer retarget).
        voice.attackStep = zone.envAttack < 0
            ? attackStep
            : Float(1.0 / max(1.0, Double(zone.envAttack) * sampleRate))
        // Time-accurate decay (the PolySynth law): 1 → sustain in `decay`
        // seconds. decay 0 / sustain 1 (the nil defaults) yield step 0 with
        // an immediate decay→sustain transition at level 1 — the legacy hold.
        voice.decayStep = Float((1.0 - Double(zone.envSustain))
            / max(1.0, Double(zone.envDecay) * sampleRate))
        voice.sustainLevel = zone.envSustain
        voice.releaseSlope = zone.envRelease < 0
            ? releaseSlope
            : Float(1.0 / max(1.0, Double(zone.envRelease) * sampleRate))
        voices[slot] = voice
        nextSerial &+= 1
    }

    /// One xorshift64* step → a Float in [0, 1) from the top 24 bits of the
    /// scrambled state (m19-a random-gate draw, design §4.3). Render thread;
    /// a handful of integer ops, no allocation.
    @inline(__always)
    private func nextRandom01() -> Float {
        var x = rngState
        x ^= x >> 12
        x ^= x << 25
        x ^= x >> 27
        rngState = x
        let scrambled = x &* 0x2545_F491_4F6C_DD1D
        return Float(scrambled >> 40) * (1.0 / 16_777_216.0)
    }
}
