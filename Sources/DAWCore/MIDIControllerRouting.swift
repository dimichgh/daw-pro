import Foundation

/// Which controller lanes a given instrument will actually CONSUME, and a
/// readable sentence for the ones it will not (m27).
///
/// Why this exists. `clip.setControllerLane` used to accept any lane on any
/// track and store it silently; a user authored SEVEN CC11 lanes that produced
/// byte-identical audio, because the built-in sampler dropped every CC but 64
/// at the voice. Accepting data we discard — with a success response — is the
/// defect that produced that whole thread. The engine half is fixed (the
/// sampler now routes CC1/CC2/CC11); this is the other half: whatever we
/// STILL do not route must say so at the moment it is accepted.
///
/// This type is pure DAWCore: no engine, no UI, no AVFoundation. It is the ONE
/// definition of "does this controller reach the sound?", so the wire, the
/// panel, and any future agent-facing surface cannot drift apart. It is a
/// WARNING, never a refusal — the lane is still stored, because the user may
/// be authoring for an instrument they have not chosen yet, and because a
/// controller lane survives an instrument switch.
public enum MIDIControllerRouting {
    /// The CCs the built-in SAMPLER consumes (m16-b2 CC64 + m27 expression).
    /// Anything outside this set is dropped at the voice.
    public static let samplerRoutedCCs: Set<Int> = [1, 2, 11, 64]
    /// The CCs the built-in POLY SYNTH consumes — sustain only (m16-b2).
    public static let polySynthRoutedCCs: Set<Int> = [64]

    /// How a lane of `type` fares on `instrument`.
    public enum Routing: Equatable, Sendable {
        /// The instrument consumes it and it will be audible.
        case routed
        /// The instrument consumes it, but a parameter currently set to zero
        /// makes it inaudible — a lane that is wired but turned down.
        case routedButDisabled(reason: String)
        /// Nothing consumes it; the lane is stored and inert.
        case inert(reason: String)
    }

    /// The routing verdict. `instrument == nil` is an instrument-less track:
    /// nothing consumes anything, which is worth saying out loud rather than
    /// letting the lane look accepted.
    public static func routing(for type: MIDIControllerType,
                               instrument: InstrumentDescriptor?) -> Routing {
        guard let instrument else {
            return .inert(reason: "this track has no instrument yet, so nothing will play it")
        }
        switch instrument.kind {
        case .audioUnit, .soundBank:
            // Hosted AUs receive every controller as raw MIDI (0xB0 …) —
            // whether the PLUGIN acts on it is the plugin's business and not
            // something we can honestly claim either way.
            return .routed

        case .testTone:
            return .inert(reason: "the test-tone instrument plays notes only and consumes no "
                + "controllers at all")

        case .polySynth:
            switch type {
            case .pitchBend:
                // PolySynthInstrument bends every voice's frequency (±2 st).
                return .routed
            case .channelPressure:
                return .inert(reason: "the built-in poly synth consumes no channel pressure "
                    + "(aftertouch)")
            case .cc(let controller):
                guard polySynthRoutedCCs.contains(controller) else {
                    return .inert(reason: "the built-in poly synth consumes only CC64 (sustain) "
                        + "and pitch bend")
                }
                return .routed
            }

        case .sampler:
            switch type {
            case .pitchBend:
                return .routed
            case .channelPressure:
                return .inert(reason: "the built-in sampler consumes no channel pressure "
                    + "(aftertouch)")
            case .cc(let controller):
                guard samplerRoutedCCs.contains(controller) else {
                    return .inert(reason: "the built-in sampler consumes only CC1 (mod wheel), "
                        + "CC2 (breath), CC11 (expression), CC64 (sustain) and pitch bend")
                }
                // CC1/CC2 are wired but gated by a depth that defaults to 0 —
                // see `SamplerParams.expressionModDepth` for why they cannot
                // be unconditional (their MIDI neutral is 0, so an
                // unconditional reading renders silence before the first
                // authored point). A lane on them with depth 0 is exactly the
                // "accepted but inaudible" case this type exists to name.
                if controller == 1 || controller == 2 {
                    let depth = instrument.resolvedSampler.expressionModDepth ?? 0
                    if depth <= 0 {
                        let name = controller == 1 ? "CC1 (mod wheel)" : "CC2 (breath)"
                        return .routedButDisabled(reason:
                            "the built-in sampler reaches \(name) only through "
                            + "sampler.expressionModDepth, which is 0 (off) on this track — set "
                            + "it above 0 to make the lane audible. CC11 (expression) needs no "
                            + "such switch")
                    }
                }
                return .routed
            }
        }
    }

    /// One sentence for a lane that will not sound, or nil when it will.
    /// Names the CONTROLLER and the REASON, so the caller can act without
    /// reading source. Shape follows the media-import warning idiom: a plain
    /// sentence, surfaced verbatim, alongside a SUCCESSFUL result.
    public static func inertLaneWarning(for type: MIDIControllerType,
                                        instrument: InstrumentDescriptor?) -> String? {
        switch routing(for: type, instrument: instrument) {
        case .routed:
            return nil
        case .routedButDisabled(let reason), .inert(let reason):
            return "\(describe(type)) is stored but will not sound: \(reason)"
        }
    }

    // MARK: - Measured capability limits (breath-pad P1, 2026-08-19)

    /// Whether an EXPRESSION contour on this instrument moves **brightness** as
    /// well as loudness, or loudness only.
    ///
    /// ⛔ **MEASURED, and the answer for the sound-bank path is NO**
    /// (`docs/research/measure-gm-sax-cc.md` §3, 2026-08-19). On a `.soundBank`
    /// track — Apple's AUSampler hosting the stock `gs_instruments.dls`, which
    /// is where the GM sax lives — CC 11 is **exactly a gain**: a single-scalar
    /// fit between CC11 = 127 and CC11 = 40 leaves a **−104 dB** residual, the
    /// float renderer's floor. The same fit *refuses* on the built-in sampler's
    /// real filter at −9.75 dB — a 95 dB separation — so this is a measured
    /// negative, not a measurement that failed to fire.
    ///
    /// The consequence is a rule about TEXT, which is why it lives here rather
    /// than in a comment somewhere: **nothing may promise brightness or timbre
    /// movement on a `.soundBank` or `.audioUnit` track.** Brightness is a
    /// built-in `.sampler` capability, gated on `expressionFilterDepth`.
    public static func expressionMovesBrightness(instrument: InstrumentDescriptor?) -> Bool {
        guard let instrument, instrument.kind == .sampler else { return false }
        return (instrument.resolvedSampler.expressionFilterDepth ?? 0) > 0
    }

    /// The vibrato rate, in Hz, above which a pitch-bend lane on `instrument`
    /// cannot be trusted to bounce correctly — or nil when there is no such
    /// limit.
    ///
    /// ⛔ **MEASURED** (`docs/research/measure-gm-sax-cc.md` §2, 2026-08-19):
    /// on the HOSTED-AU path, bend is sample-and-held at the offline render
    /// block rate (`OfflineRenderer` renders 4096 frames per block = an
    /// **11.719 Hz sampler, Nyquist 5.86 Hz**), so an authored 5.5 Hz vibrato
    /// bounces as 35.4 ¢ at 5.50 Hz **plus a 30.0 ¢ alias at 6.22 Hz** — two
    /// vibratos beating. 8 Hz becomes a 3.72 Hz wobble; 11.72 Hz becomes a
    /// static −17.9 ¢ detune. The built-in `.sampler` shows none of it.
    ///
    /// ⚠️ **Whether LIVE playback is affected is NOT MEASURED** — live renders
    /// at the hardware buffer size, not 4096 — so this is stated as a bounce
    /// limit, which is what was actually observed.
    public static func bendModulationNyquistHz(instrument: InstrumentDescriptor?) -> Double? {
        guard let instrument else { return nil }
        switch instrument.kind {
        case .soundBank, .audioUnit: return 5.86
        case .sampler, .polySynth, .testTone: return nil
        }
    }

    /// One sentence for a caller that wanted vibrato on `instrument` and cannot
    /// have it through the bend lane, or nil when the bend lane is fine.
    ///
    /// ⭐ Names the ROUTE THAT WORKS rather than just refusing: the stock DLS
    /// sax generates its own vibrato from **CC 1**, measured as
    /// `≈ 2.42 + 0.2996 × CC1` cents at a fixed **5.400 Hz**
    /// (`docs/research/measure-gm-sax-cc.md` §1). That vibrato is produced
    /// INSIDE AUSampler, never crosses our bend lane, and is therefore
    /// completely free of the aliasing above. A warning that only says "no" is
    /// how a user concludes the feature is broken.
    public static func bendVibratoWarning(for instrument: InstrumentDescriptor?,
                                          requestedRateHz: Double) -> String? {
        guard let nyquist = bendModulationNyquistHz(instrument: instrument),
              requestedRateHz > 0 else { return nil }
        let rate = String(format: "%.4g", requestedRateHz)
        return "vibrato was NOT written to the pitch-bend lane on this track: it hosts an Audio "
            + "Unit, and bend there is sampled at the offline render block rate "
            + "(\(String(format: "%.2f", nyquist)) Hz Nyquist), so a \(rate) Hz vibrato bounces "
            + "as two vibratos beating — the measured case is 5.5 Hz coming back as 35.4 cents "
            + "at 5.50 Hz plus a 30.0 cent alias at 6.22 Hz. The expression swell and the "
            + "micro-sharpening were written normally (both are far below that limit). For "
            + "vibrato on this track use the instrument's OWN: on the stock GM sound bank, a "
            + "CC1 (mod wheel) lane gives about 2.4 + 0.30 x CC1 cents at a fixed 5.4 Hz, "
            + "generated inside the plugin and free of this problem — author it with "
            + "clip.setControllerLane"
    }

    // MARK: - Measured capability limits (breath-pad P5, 2026-08-19)

    /// The rate, in Hz, at which an **offline bounce** re-samples the CONTROLLER
    /// lanes we write to `instrument` — or nil when the lane is delivered
    /// faithfully and there is no such limit.
    ///
    /// ⛔ **MEASURED FOR CC 11, not inherited from the bend measurement.**
    /// `bendModulationNyquistHz` above was measured with a pitch-bend lane;
    /// `measure-gm-sax-cc.md` §2.4 stated the mechanism as "AUSampler computes
    /// pitch per sample and merely reads its MIDI *inputs* per block", which
    /// makes the CC case a **derivation**. Breath-pad P5 was about to spend that
    /// derivation — the natural escape from the bend ceiling is to deliver
    /// modulation amplitude-side — so it measured the CC case instead
    /// (`SoundBankHostingTests` T5, stock GM alto sax through AUSampler):
    ///
    /// | CC 11 modulation | image at | image / commanded |
    /// |---|---|---|
    /// | 2.0 Hz | 9.719 Hz | 0.222 |
    /// | 4.0 Hz | 7.719 Hz | 0.520 |
    /// | 5.5 Hz | 6.219 Hz | 0.911 |
    /// | 8.0 Hz | 3.719 Hz | **2.139** |
    /// | 8.0 Hz, built-in `.sampler` | — | 0.043 |
    /// | no lane at all (floor) | — | 400× below |
    ///
    /// **There is no escape: CC 11 is re-sampled exactly as bend is.** The
    /// figure is `OfflineRenderer`'s 4096-frame block at 48 kHz.
    ///
    /// ⚠️ **Returns the SAMPLING rate, not the Nyquist rate**, unlike its bend
    /// sibling — the image ratio `f / (f_s − f)` needs `f_s`, and a helper that
    /// silently returned half of it would put every ceiling out by a factor of
    /// two. `bendModulationNyquistHz` keeps its own spelling because callers
    /// already read a Nyquist figure out of it.
    ///
    /// ⚠️ **BOUNCE only.** Live playback pulls at the hardware buffer size.
    ///
    /// ⭐ **AND THAT IS NOW MEASURED, NOT ASSUMED (breath pad P6, 2026-08-19).**
    /// This sentence previously read "at 512 frames the rate is 93.75 Hz" — a
    /// conditional dressed as a fact, since nothing had ever asked the live path
    /// what it hands the renderer. `EnginePerformance` already records
    /// `lastQuantumFrames` per quantum, so the number was free: a real
    /// `AudioEngine`, prepared against this machine's default output and left
    /// rendering for 400 ms, reported **quantumFrames = 512 at 48 kHz ⇒ 93.75 Hz
    /// block rate, Nyquist 46.875 Hz**, with `renderedFrames` an exact multiple
    /// of 512 (38912 = 76 × 512), i.e. every quantum the same size. **Live is
    /// 8× the offline bounce's 11.719 Hz**, so nothing in the table above
    /// applies to what a user hears while the transport rolls — the ceiling is
    /// a BOUNCE property and the two must never be quoted for each other.
    ///
    /// ⚠️ ONE machine, one device, one moment: the HAL buffer size is a device
    /// setting a user can change, so treat 512 as *what this rig reported*, not
    /// as a constant. The reproducing recipe is two lines — prepare an
    /// `AudioEngine`, read `performanceStats(reset:).quantumFrames` — and it is
    /// deliberately NOT a test, because a gate that needs a running output
    /// device is a flake generator.
    public static func controllerModulationSamplingHz(
        instrument: InstrumentDescriptor?) -> Double? {
        guard let instrument else { return nil }
        switch instrument.kind {
        case .soundBank, .audioUnit: return EffortField.hostedAUOfflineModulationSamplingHz
        case .sampler, .polySynth, .testTone: return nil
        }
    }

    /// One sentence for a caller who asked for a `rateHz` micro-tremor on
    /// `instrument` and cannot have it, or nil when the tremor will be written.
    ///
    /// ⛔ **P5 SUPPRESSES rather than retunes, and the number is the argument.**
    /// Holding the sample-and-hold image 12 dB below the tremor on this path
    /// caps the rate at 2.34 Hz — *below* §10.1's whole 4–8 Hz physiological
    /// band. Clamping into that would deliver a slow wobble wearing the name
    /// "tremor", which is the silent-default failure this round exists to end.
    ///
    /// ⭐ **Names `OfflineRenderer`'s block as the cause, not the plugin**, and
    /// that is deliberate: `measure-gm-sax-cc.md` §2.4 calls the 4096-frame
    /// default a bounce-fidelity bug rather than a physical limit, and predicts
    /// live playback at 512 frames samples at 93.75 Hz and is clean. A warning
    /// that said "hosted AUs cannot do tremor" would point at a dead end
    /// instead of at a fixable engine default.
    public static func tremorSuppressionWarning(for instrument: InstrumentDescriptor?,
                                                requestedRateHz: Double) -> String? {
        guard let samplingHz = controllerModulationSamplingHz(instrument: instrument),
              requestedRateHz > 0 else { return nil }
        let ratio = EffortField.modulationImageRatio(rateHz: requestedRateHz,
                                                     samplingHz: samplingHz)
        let ceiling = EffortField.modulationRateCeilingHz(
            samplingHz: samplingHz, maxImageRatio: EffortField.maxAcceptableImageRatio)
        func f(_ value: Double, _ places: Int) -> String {
            String(format: "%.\(places)f", value)
        }
        return "micro-tremor was NOT written on this track: it hosts an Audio Unit, and in an "
            + "OFFLINE BOUNCE our own renderer feeds it MIDI in 4096-frame blocks — an "
            + "\(f(samplingHz, 3)) Hz sampler. A \(f(requestedRateHz, 3)) Hz tremor comes back "
            + "with an extra copy at \(f(abs(samplingHz - requestedRateHz), 3)) Hz at "
            + "\(f(ratio, 2))x its depth (measured: 8 Hz returns 2.14x more energy at 3.72 Hz "
            + "than at 8 Hz). Keeping that copy 12 dB down would need a rate at or below "
            + "\(f(ceiling, 2)) Hz, which is below the 4-8 Hz band a tremor IS, so it is "
            + "suppressed rather than quietly retuned out of its own band. Everything else "
            + "in the shape — the swell, the drift, the phrase arc — is far below this limit "
            + "and was written normally. The tremor DOES land on a built-in Sampler track, "
            + "and the block size is ours: live playback pulls at the hardware buffer, where "
            + "this does not apply"
    }

    /// Human name for a lane type, matching the copy users see elsewhere
    /// ("CC11 (expression)", not "cc:11").
    public static func describe(_ type: MIDIControllerType) -> String {
        switch type {
        case .pitchBend: return "pitch bend"
        case .channelPressure: return "channel pressure (aftertouch)"
        case .cc(let controller):
            switch controller {
            case 1: return "CC1 (mod wheel)"
            case 2: return "CC2 (breath)"
            case 7: return "CC7 (channel volume)"
            case 10: return "CC10 (pan)"
            case 11: return "CC11 (expression)"
            case 64: return "CC64 (sustain)"
            case 74: return "CC74 (brightness)"
            default: return "CC\(controller)"
            }
        }
    }
}
