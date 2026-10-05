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
    /// The CCs the built-in SAMPLER consumes REGARDLESS of its parameters
    /// (m16-b2 CC64 + m27 expression).
    ///
    /// ⚠️ **NOT the whole sampler answer** — see `samplerParameterRoutedCCs`,
    /// which adds the controllers a particular descriptor routes. Treating this
    /// constant as the complete set is a bug that shipped: a sampler with
    /// `expressionFilterDepth > 0` and `expressionFilterCC: 74` really does
    /// sweep its filter from CC74, and `clip.setControllerLane` told the user
    /// the lane "will not sound" (m27-b, found while building the
    /// instrument-change warning). Always go through `routing(for:instrument:)`.
    public static let samplerRoutedCCs: Set<Int> = [1, 2, 11, 64]
    /// The CCs the built-in POLY SYNTH consumes — sustain only (m16-b2).
    public static let polySynthRoutedCCs: Set<Int> = [64]

    /// The CCs THIS sampler descriptor routes on top of `samplerRoutedCCs`,
    /// because of parameters rather than of being a sampler at all. Mirrors
    /// `SamplerInstrument`'s own `ccInteresting` seeding:
    ///  · the brightness filter's controller, while `expressionFilterDepth > 0`
    ///    (the engine's `filterEnabled` gate; `expressionFilterCC` defaults to
    ///    11, which is already unconditional);
    ///  · every zone's CC-domain dynamic-layer crossfade controller, under the
    ///    engine's `hasCcXfade` rule — a controller AND at least one CC bound.
    ///    A velocity-only crossfade is fixed at note-on and routes no CC.
    public static func samplerParameterRoutedCCs(_ params: SamplerParams) -> Set<Int> {
        var extra: Set<Int> = []
        if (params.expressionFilterDepth ?? 0) > 0 {
            let filterCC = params.expressionFilterCC ?? 11
            if (0...127).contains(filterCC) { extra.insert(filterCC) }
        }
        for zone in params.zones {
            guard let crossfade = zone.crossfade,
                  let controller = crossfade.controller,
                  crossfade.ccInLo != nil || crossfade.ccInHi != nil
                    || crossfade.ccOutLo != nil || crossfade.ccOutHi != nil,
                  (0...127).contains(controller)
            else { continue }
            extra.insert(controller)
        }
        return extra
    }

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
        routing(for: type, instrument: instrument, samplerExtra: nil)
    }

    /// The verdict, with `samplerParameterRoutedCCs` optionally PRECOMPUTED.
    ///
    /// ⭐ Exists only so `honoredCCs` can ask 128 questions while scanning the
    /// zone list ONCE. A 309-zone imported library answered the naive way costs
    /// 128 × 309 zone visits per track per `project.snapshot`, which is a
    /// scaling trap for a field that is on every snapshot. Passing nil computes
    /// it, so there is still exactly ONE derivation of that set.
    private static func routing(for type: MIDIControllerType,
                                instrument: InstrumentDescriptor?,
                                samplerExtra: Set<Int>?) -> Routing {
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

        case .drumSynth:
            // ⭐ HONEST, NOT CONVENIENT. The drum machine reads NOTE VELOCITY
            // (that is the whole accent mechanism) but velocity is not a
            // controller — it rides on the note-on. No CC, no pitch bend and no
            // aftertouch reaches a voice: a one-shot latches its parameters at
            // trigger and has nothing left to steer. Saying `.routed` here to
            // look generous would put an INERT-lane warning's opposite in front
            // of the user, which is the failure this whole taxonomy exists to
            // prevent. Parameters are steered by `mod.addRoute` instead, and
            // all 75 of them are reachable that way.
            return .inert(reason: "the drum machine's voices are one-shots that latch every "
                + "parameter when a note starts, so no controller steers them. It DOES respond "
                + "to note velocity (see kit.velocityToTone and kit.accentThreshold), and every "
                + "one of its 75 parameters can be modulated with mod.addRoute")

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
                // m27-b: the sampler's routed set is DESCRIPTOR-dependent, not
                // a constant — the filter's controller and any zone crossfade
                // controller are routed by THIS instrument's parameters.
                let extra = samplerExtra
                    ?? samplerParameterRoutedCCs(instrument.resolvedSampler)
                guard samplerRoutedCCs.contains(controller) || extra.contains(controller) else {
                    let extraNote = extra.isEmpty ? "" : ", plus "
                        + extra.sorted().map { describe(.cc(controller: $0)) }
                            .joined(separator: " and ")
                        + " on this track's sampler settings"
                    return .inert(reason: "the built-in sampler consumes only CC1 (mod wheel), "
                        + "CC2 (breath), CC11 (expression), CC64 (sustain) and pitch bend"
                        + extraNote)
                }
                // A controller routed by a PARAMETER (filter/crossfade) sounds
                // whatever the mod depth is — the depth gate below governs the
                // CC1/CC2 amplitude path only, so it must not veto that.
                if extra.contains(controller) { return .routed }
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

    // MARK: - The honoured set (m27-b)

    /// **Does a lane of `type` change what the listener hears on `instrument`?**
    /// The one-line spelling of `routing(...) == .routed`, so no caller has to
    /// remember that `.routedButDisabled` is a NO — a controller that reaches
    /// the instrument through a parameter turned down to 0 sounds exactly the
    /// same as one that never arrives.
    public static func honors(_ type: MIDIControllerType,
                              instrument: InstrumentDescriptor?) -> Bool {
        routing(for: type, instrument: instrument) == .routed
    }

    /// Whether `instrument` forwards EVERY controller it is sent, making an
    /// enumerated answer meaningless. True for the hosted-AU kinds only:
    /// `HostedAUInstrument` re-emits each event as raw MIDI (`0xB0` for CC)
    /// with no filter, and what the plug-in then does with it is its business.
    public static func forwardsAllControllers(instrument: InstrumentDescriptor?) -> Bool {
        guard let instrument else { return false }
        switch instrument.kind {
        case .audioUnit, .soundBank: return true
        case .sampler, .polySynth, .testTone, .drumSynth: return false
        }
    }

    /// The CC numbers `instrument` acts on, ascending — empty when
    /// `forwardsAllControllers` (there is nothing to enumerate) and empty for
    /// an instrument-less track.
    ///
    /// ⭐ DERIVED by asking `routing` all 128 questions rather than by keeping
    /// a second list. That is the point: this file's header calls itself the
    /// ONE definition of "does this controller reach the sound?", and a
    /// parallel list is exactly how the two would drift.
    public static func honoredCCs(instrument: InstrumentDescriptor?) -> [Int] {
        guard let instrument, !forwardsAllControllers(instrument: instrument) else { return [] }
        // Scan the zone list once, not 128 times — see the private `routing`
        // overload. nil for every non-sampler kind, which ignores it anyway.
        let extra = instrument.kind == .sampler
            ? samplerParameterRoutedCCs(instrument.resolvedSampler) : []
        return (0...127).filter {
            routing(for: .cc(controller: $0), instrument: instrument,
                    samplerExtra: extra) == .routed
        }
    }

    /// One sentence when a bend lane is about to be AUTHORED against a
    /// different bend range than the instrument will PLAY it at — or nil when
    /// the two agree, which is the only case that existed before
    /// `SamplerParams.bendRangeSemitones` was settable.
    ///
    /// ⚠️ THE COUPLING THIS EXISTS FOR. There are two independently-settable
    /// bend-range figures in this codebase and they mean different things:
    ///  · `BreathContour.Options.bendRangeSemitones` — an AUTHORING figure.
    ///    `BreathContour` converts a musical width in cents into raw 14-bit
    ///    bend units by dividing by `range × 100 / 8192`, so it must be told
    ///    the range of the instrument the lane is FOR.
    ///  · `SamplerParams.bendRangeSemitones` — a PLAYBACK figure: what the
    ///    built-in sampler multiplies a raw deflection by.
    ///
    /// They were previously guaranteed equal because the playback one was a
    /// hard-wired 2.0 and the authoring one defaults to 2. Making playback
    /// settable is what lets them disagree, and the failure is silent and
    /// exactly proportional: author a 35-cent vibrato at range 2, set the
    /// sampler to 12, and it comes out 210 cents — a tone and a bit of wobble
    /// where a singer's vibrato was asked for. Nothing crashes, nothing
    /// refuses, and the numbers on every surface stay right.
    ///
    /// They are NOT auto-coupled, and that is a decision rather than an
    /// omission: `BreathContour` is DAWCore lane math with no knowledge of the
    /// track it is being written to, and lanes deliberately survive an
    /// instrument switch (see this type's own header). Auto-coupling would also
    /// silently rewrite a figure a caller passed explicitly. So: warn, name
    /// both numbers, and let the caller decide.
    ///
    /// ⚠️ Fires ONLY when the sampler's range is EXPLICITLY set. A nil range is
    /// the GM 2.0 the engine always used, and a lane authored at some other
    /// figure against it is a pre-existing authoring hazard that predates this
    /// field — warning about it here would change the response of projects
    /// nobody edited, which is the same class of regression as changing the
    /// default. It is named in the docs instead.
    public static func bendRangeMismatchWarning(
        authoredSemitones: Double,
        instrument: InstrumentDescriptor?
    ) -> String? {
        guard let instrument, instrument.kind == .sampler,
              let played = instrument.resolvedSampler.bendRangeSemitones,
              abs(played - authoredSemitones) > 1e-9
        else { return nil }
        let ratio = authoredSemitones > 0 ? played / authoredSemitones : Double.infinity
        let factor = ratio.isFinite
            ? "\(((ratio * 100).rounded() / 100))×"
            : "an undefined multiple of"
        return "the bend lane was authored for a \(authoredSemitones)-semitone bend range but "
            + "this track's sampler plays bend at \(played) semitones, so every bend — vibrato "
            + "width included — will sound \(factor) what was asked for. Pass "
            + "bendRangeSemitones: \(played) to match the instrument, or set the track's "
            + "sampler.bendRangeSemitones to \(authoredSemitones) to match the lane"
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
    /// block rate. At the 4096-frame block this was measured against, that was an
    /// **11.719 Hz sampler, Nyquist 5.86 Hz**, so an authored 5.5 Hz vibrato
    /// bounced as 35.4 ¢ at 5.50 Hz **plus a 30.0 ¢ alias at 6.22 Hz** — two
    /// vibratos beating. 8 Hz became a 3.72 Hz wobble; 11.72 Hz a static
    /// −17.9 ¢ detune. The built-in `.sampler` showed none of it.
    ///
    /// ⭐ **m28-bug moved the block to 512**, so this now returns **46.875 Hz**
    /// and no musical vibrato rate is refused. The limit is not gone — it is
    /// eight times higher, and `modulationAliasesUnacceptably` is what decides.
    ///
    /// ⚠️ **Whether LIVE playback is affected is NOT MEASURED** — live renders
    /// at the hardware buffer size, not 4096 — so this is stated as a bounce
    /// limit, which is what was actually observed.
    /// ⭐ **m28-bug: DERIVED from the render block, no longer the literal 5.86.**
    /// The 5.86 figure was half of 48000/4096; with the block at 512 the same
    /// arithmetic gives **46.875 Hz**, which is above the entire musical
    /// modulation band. Hard-coding it would have left this function reporting a
    /// limit the engine no longer has.
    public static func bendModulationNyquistHz(instrument: InstrumentDescriptor?) -> Double? {
        guard let instrument else { return nil }
        switch instrument.kind {
        case .soundBank, .audioUnit:
            return EffortField.hostedAUOfflineModulationSamplingHz / 2
        case .sampler, .polySynth, .testTone, .drumSynth: return nil
        }
    }

    /// Whether a modulation authored at `rateHz` on `instrument` would come back
    /// from an offline bounce with its sample-and-hold image louder than
    /// `EffortField.maxAcceptableImageRatio` — i.e. whether it must be
    /// suppressed rather than written.
    ///
    /// ⛔⛔ **m28-bug: THIS PREDICATE IS THE FIX'S OTHER HALF, AND OMITTING IT
    /// WOULD HAVE BEEN WORSE THAN LEAVING THE BLOCK AT 4096.** Both capability
    /// gates used to be *unconditional on rate*: hosting an AU was itself the
    /// disqualification. With the block at 512 the warning text would then have
    /// computed and printed "an extra copy at 85.75 Hz at 0.09x its depth …
    /// would need a rate at or below 18.75 Hz" — and suppressed a 4.565 Hz
    /// tremor anyway. A sentence that contradicts its own action is exactly the
    /// silent-plausible-wrong-answer failure this whole line of work exists to
    /// end. The ceiling was always the real criterion; it was simply never
    /// reachable, so nobody had to write it down.
    public static func modulationAliasesUnacceptably(instrument: InstrumentDescriptor?,
                                                     rateHz: Double) -> Bool {
        guard let samplingHz = controllerModulationSamplingHz(instrument: instrument),
              rateHz > 0 else { return false }
        return EffortField.modulationImageRatio(rateHz: rateHz, samplingHz: samplingHz)
            > EffortField.maxAcceptableImageRatio
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
              requestedRateHz > 0,
              // m28-bug: the ceiling is the criterion, not the mere fact of
              // hosting an AU. At the shipping 512-frame block this is false for
              // every musically sensible vibrato rate, so no warning is produced
              // and the vibrato is written.
              modulationAliasesUnacceptably(instrument: instrument, rateHz: requestedRateHz)
        else { return nil }
        let rate = String(format: "%.4g", requestedRateHz)
        return "vibrato was NOT written to the pitch-bend lane on this track: it hosts an Audio "
            + "Unit, and bend there is sampled at the offline render block rate "
            + "(\(String(format: "%.2f", nyquist)) Hz Nyquist), so a \(rate) Hz vibrato bounces "
            + "as two vibratos beating — the measured case at a 4096-frame block was 5.5 Hz "
            + "coming back as 35.4 cents at 5.50 Hz plus a 30.0 cent alias at 6.22 Hz. The "
            + "expression swell and the "
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
    /// figure is `OfflineRenderer`'s block at 48 kHz — 4096 frames when the
    /// table above was measured, 512 now (`RenderBlockSize`, m28-bug), which is
    /// why the ratios in that table are historical rather than current.
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
    /// of 512 (38912 = 76 × 512), i.e. every quantum the same size.
    ///
    /// ⭐⭐ **m28-bug CLOSED THE GAP THAT MEASUREMENT REVEALED.** When P6 took
    /// this number the bounce ran at 11.719 Hz and live at 93.75 Hz — **live was
    /// 8× finer than the bounce**, which is precisely the defect: the same
    /// project, monitored and then bounced, delivered vibrato at two different
    /// RATES, and the one the user approved was not the one written to disk.
    /// The offline block is now 512 (`RenderBlockSize`), so both paths sample at
    /// 93.75 Hz on this rig and the table above describes both. ⚠️ That equality
    /// is a fact about THIS machine's HAL buffer, not a guarantee — the ceiling
    /// remains a BOUNCE property, computed from OUR block, which is the only one
    /// of the two we control.
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
        case .sampler, .polySynth, .testTone, .drumSynth: return nil
        }
    }

    /// One sentence for a caller who asked for a `rateHz` micro-tremor on
    /// `instrument` and cannot have it, or nil when the tremor will be written.
    ///
    /// ⛔ **P5 SUPPRESSES rather than retunes, and the number is the argument.**
    /// Holding the sample-and-hold image 12 dB below the tremor on this path
    /// capped the rate at 2.34 Hz at the old 4096-frame block — *below* §10.1's
    /// whole 4–8 Hz physiological band. Clamping into that would deliver a slow
    /// wobble wearing the name "tremor", the silent-default failure this round
    /// exists to end. ⭐ At the 512-frame block the cap is **18.75 Hz**, so the
    /// band is written and only genuinely too-fast rates are refused.
    ///
    /// ⭐ **Names `OfflineRenderer`'s block as the cause, not the plugin**, and
    /// that is deliberate: `measure-gm-sax-cc.md` §2.4 called the 4096-frame
    /// default a bounce-fidelity bug rather than a physical limit. A warning
    /// that said "hosted AUs cannot do tremor" would have pointed at a dead end
    /// instead of at a fixable engine default — and the default was then duly
    /// fixed (m28-bug), which is the argument for naming causes you can act on.
    public static func tremorSuppressionWarning(for instrument: InstrumentDescriptor?,
                                                requestedRateHz: Double) -> String? {
        guard let samplingHz = controllerModulationSamplingHz(instrument: instrument),
              requestedRateHz > 0,
              // m28-bug: see `modulationAliasesUnacceptably`. Hosting an AU is
              // no longer the disqualification — exceeding the image ceiling is.
              modulationAliasesUnacceptably(instrument: instrument, rateHz: requestedRateHz)
        else { return nil }
        let ratio = EffortField.modulationImageRatio(rateHz: requestedRateHz,
                                                     samplingHz: samplingHz)
        let ceiling = EffortField.modulationRateCeilingHz(
            samplingHz: samplingHz, maxImageRatio: EffortField.maxAcceptableImageRatio)
        func f(_ value: Double, _ places: Int) -> String {
            String(format: "%.\(places)f", value)
        }
        return "micro-tremor was NOT written on this track: it hosts an Audio Unit, and in an "
            + "OFFLINE BOUNCE our own renderer feeds it MIDI in "
            + "\(RenderBlockSize.offlineFrames)-frame blocks — an "
            + "\(f(samplingHz, 3)) Hz sampler. A \(f(requestedRateHz, 3)) Hz tremor comes back "
            + "with an extra copy at \(f(abs(samplingHz - requestedRateHz), 3)) Hz at "
            + "\(f(ratio, 2))x its depth (measured at a 4096-frame block: 8 Hz returned 2.14x "
            + "more energy at 3.72 Hz than at 8 Hz). Keeping that copy 12 dB down would need a "
            + "rate at or below "
            + "\(f(ceiling, 2)) Hz. It is suppressed rather than quietly retuned to a rate you "
            + "did not ask for. Everything else in the shape — the swell, the drift, the "
            + "phrase arc — is far below this limit and was written normally, and the tremor "
            + "DOES land on a built-in Sampler track. Lowering the tremor rate to "
            + "\(f(ceiling, 2)) Hz or below writes it here too"
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
