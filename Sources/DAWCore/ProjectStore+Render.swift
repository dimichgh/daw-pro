import Foundation

/// Measured / loudness-normalized render store operations (M5 iv-b, spec
/// §4.1–4.3). Everything here is OFFLINE policy over the engine's buffer
/// seam (`renderOffline` / `writeAudioFile`) — DAWCore stays engine-free and
/// the render thread is never touched. `renderMixdown` (the raw/fast bounce)
/// is UNCHANGED; these ops are the measured/normalized surface. New domains
/// live in extension files (ProjectStore.swift is 2.3k lines).
@MainActor
extension ProjectStore {

    /// Renders the session offline and measures it (BS.1770-4 integrated +
    /// maxima + 4× true peak) — NOTHING is written to disk. All-nil
    /// measurement fields mean the program sits below the −70 LUFS gate
    /// (JSON has no −inf; nil is the honest encoding).
    ///
    /// `durationSeconds` nil → the shared default window (`renderWindowSeconds`):
    /// extent of ALL tracks' clips (audio AND instrument) past `fromBeat` plus a
    /// 2.0 s bus-reverb/release tail. Since m16-d `renderMixdown` defaults to
    /// this SAME window — the audio-only legacy carve-out is retired (it was a
    /// false-teaching bug, audit F4). No clips past `fromBeat` →
    /// `nothingToRender`.
    public func measureLoudness(fromBeat: Double = 0,
                                durationSeconds: Double? = nil) async throws -> LoudnessMeasureResult {
        guard let engine else { throw ProjectError.engineUnavailable }
        let startBeat = max(0, fromBeat)
        let duration = try renderWindowSeconds(fromBeat: startBeat, requested: durationSeconds)
        // MASTERED class (m13-d, design §2): measuring the PROGRAM is the
        // whole point — the Copilot adds EQ+limiter to master, then measures.
        // The master volume lane rides the class (m15-c): a programmed fade
        // IS part of the measured program.
        let audio = try await engine.renderOffline(
            // m23-bx-1: measuring a patch the user is not hearing would make
            // every loudness number a measurement of the wrong program.
            tracks: tracksWithLiveAudioUnitState(),
            tempoMap: transport.tempoMap, masterVolume: masterVolume,
            masterEffects: masterEffects,
            masterAutomation: masterAutomation,
            fromBeat: startBeat, durationSeconds: duration,
            forcedCompensationTargets: nil
        )
        return LoudnessMeasureResult(
            measurement: await Loudness.measureDetached(audio),
            durationSeconds: audio.sampleRate > 0
                ? Double(audio.frameCount) / audio.sampleRate : 0,
            sampleRate: audio.sampleRate
        )
    }

    /// Bounces the session to a WAV with a full loudness report, optionally
    /// normalized to `lufsTarget` (spec §4.1):
    ///
    /// - `lufsTarget` non-nil → one STATIC gain `lufsTarget − measured
    ///   integrated`, CLAMPED so the true peak never exceeds
    ///   `truePeakCeilingDb` (default −1.0 dBTP). No limiter in v0 — when the
    ///   clamp bites, `limitedByCeiling` is true and `report.output` shows
    ///   the loudness actually achieved. The output is RE-MEASURED after the
    ///   gain (the −70 gate can flip near-gate blocks), so the report is
    ///   ground truth for the file on disk.
    /// - `lufsTarget` nil → no gain (a measured mixdown, never a silent −14
    ///   default); the report echoes `appliedGainDb` 0.
    /// - Program gated-silent + a target → `bounceSilent` (nothing written);
    ///   silent without a target → succeeds with all-nil measurements.
    ///
    /// Contract ranges (enforced field-named at the control layer, iv-d):
    /// `lufsTarget` ∈ [−70, 0], `truePeakCeilingDb` ∈ [−20, 0]. `path` nil →
    /// a unique file under NSTemporaryDirectory()/DAWPro/; explicit paths
    /// expand `~`, append `.wav`, create parents, and overwrite (the caller
    /// chose the path). The heavy stages run off the main actor (cooperative
    /// render; detached measure m20-a; detached gain+re-measure m20-h) — only
    /// the ~20 ms-class `writeAudioFile` remains on-actor (measured, m20-f).
    ///
    /// `excludeTrackIds` (m23-m1) renders the FULL session with those tracks
    /// silenced FOR THIS RENDER ONLY — the minus-vocal/instrumental rung. The
    /// project's own `isMuted`/`isSoloed` flags, dirty flag and undo stack are
    /// untouched (a render-local mute-copy, `RenderExclusion.resolve`); an
    /// unknown id throws `trackNotFound` before anything renders. An excluded
    /// track takes its SENDS with it — reverb/delay tail included — and its
    /// sidechain key contribution: see `RenderExclusion` for the topology and
    /// for why "instrumental but keep the vocal's reverb" is not expressible
    /// here. The render WINDOW still comes from the whole session, so an
    /// instrumental is exactly as long as the mix it came from.
    ///
    /// `bitDepth` / `container` (m23-m2) pick the OUTPUT FORMAT: 16/24/32-bit
    /// integer or the Float32 default, into WAV or AIFF. `path`'s extension is
    /// made to agree with the container — it is what actually selects it — so
    /// `container: "aiff"` never lands a file AVFoundation writes as WAV.
    /// Integer depths CLAMP at full scale while the loudness report describes
    /// the pre-quantization buffer, so a > 0 dBFS bounce written at 16 bit is
    /// clipped on disk and the report will not say so: normalize, or keep the
    /// lossless default.
    public func renderBounce(toPath path: String? = nil, fromBeat: Double = 0,
                             durationSeconds: Double? = nil, lufsTarget: Double? = nil,
                             truePeakCeilingDb: Double = -1.0,
                             excludeTrackIds: [UUID]? = nil,
                             bitDepth: Int? = nil,
                             container: String? = nil) async throws -> BounceResult {
        guard let engine else { throw ProjectError.engineUnavailable }
        // Resolved FIRST, before anything renders: an invalid format must
        // reject instead of throwing after a long render (the
        // `RenderExclusion.resolve` validate-first precedent).
        let format = try DeliveryFormat.resolve(bitDepth: bitDepth, container: container)
        let startBeat = max(0, fromBeat)
        // The window is measured off the FULL session (clips, not gates) — an
        // instrumental must land the same length as the mix, even when the
        // excluded track is the longest one.
        let duration = try renderWindowSeconds(fromBeat: startBeat, requested: durationSeconds)
        // m23-bx-1: LIVE hosted-AU state — the deliverable must be the thing
        // the user auditioned (`tracksWithLiveAudioUnitState`).
        let exclusion = try RenderExclusion.resolve(session: tracksWithLiveAudioUnitState(),
                                                    excluding: excludeTrackIds)
        // MASTERED class (m13-d, design §2): the deliverable bounce carries
        // the master chain AND the master volume lane (m15-c — "fade out the
        // song" lands in the deliverable); the loudness report measures the
        // mastered file.
        let rendered = try await engine.renderOffline(
            tracks: exclusion.tracks, tempoMap: transport.tempoMap, masterVolume: masterVolume,
            masterEffects: masterEffects,
            masterAutomation: masterAutomation,
            fromBeat: startBeat, durationSeconds: duration,
            forcedCompensationTargets: nil
        )
        let normalized = try await Self.deliveryNormalized(
            consume rendered, lufsTarget: lufsTarget, truePeakCeilingDb: truePeakCeilingDb)

        let url = Self.bounceDestination(from: path, format: format)
        let info = try engine.writeAudioFile(normalized.audio, to: url, format: format)
        // A file landed on disk — tick the render counter for the onboarding
        // signal adapter (ob-b), which fires `renderCompleted` on an increment.
        renderCompletedCount += 1
        return BounceResult(
            path: url.path,
            durationSeconds: info.durationSeconds,
            sampleRate: info.sampleRate,
            channels: info.channelCount,
            report: normalized.report,
            excludedTracks: exclusion.excludedNames,
            bitDepth: format.reportedBitDepth,
            container: format.reportedContainer,
            ditherApplied: format.reportedDitherApplied
        )
    }

    /// The delivery-normalization policy (spec §4.1) — the ONE home for
    /// measure → static gain toward target → true-peak clamp → RE-measure,
    /// shared by `renderBounce` and `renderStems`' mastered sibling (m23-m1)
    /// so the two can never drift into two different definitions of "−14 LUFS".
    ///
    /// - `lufsTarget` nil → no gain at all; the input measurement IS the
    ///   output's and `appliedGainDb` is 0.
    /// - `lufsTarget` non-nil on a gated-silent program → `bounceSilent`
    ///   (there is nothing to normalize toward).
    /// - The gain is CLAMPED so the true peak never exceeds
    ///   `truePeakCeilingDb`; when the clamp bites, `limitedByCeiling` is true
    ///   and `output` reports the loudness actually achieved (no limiter in
    ///   v0).
    ///
    /// The buffer is taken `consuming` and the gain+re-measure stays fused into
    /// ONE detached unit (m20-h): the in-place gain loop alone held the main
    /// actor ~1.1 s on a 162 s program (m20-f), and passing the buffer's only
    /// reference across the hop keeps the mutation in place — no CoW copy of a
    /// multi-hundred-MB buffer.
    static func deliveryNormalized(
        _ rendered: consuming RenderedAudio,
        lufsTarget: Double?,
        truePeakCeilingDb: Double
    ) async throws -> (audio: RenderedAudio, report: BounceLoudnessReport) {
        var audio = consume rendered
        let input = await Loudness.measureDetached(audio)

        // Gain policy (spec §4.1): static gain toward the target, ceiling-
        // clamped — louder-than-target is impossible, and the report says so.
        var appliedGainDb = 0.0
        var limitedByCeiling = false
        if let lufsTarget {
            guard let integrated = input.integratedLufs else {
                throw ProjectError.bounceSilent
            }
            appliedGainDb = lufsTarget - integrated
            if let truePeak = input.truePeakDbtp,
               truePeak + appliedGainDb > truePeakCeilingDb {
                appliedGainDb = truePeakCeilingDb - truePeak
                limitedByCeiling = true
            }
        }

        let output: LoudnessMeasurement
        if appliedGainDb != 0 {
            // Re-measured, not derived — exact for the buffer that hits disk.
            let gained = await Loudness.applyGainAndMeasureDetached(
                consume audio, linear: Float(pow(10.0, appliedGainDb / 20.0)))
            audio = gained.audio
            output = gained.measurement
        } else {
            // No gain applied: the input measurement IS the output's.
            output = input
        }

        return (audio, BounceLoudnessReport(
            input: input,
            output: output,
            appliedGainDb: appliedGainDb,
            lufsTarget: lufsTarget,
            truePeakCeilingDbtp: truePeakCeilingDb,
            limitedByCeiling: limitedByCeiling
        ))
    }

    /// Exports the master-input partition as stem WAVs (M5 iv-c, spec §2,
    /// §4.3): one file per direct-to-master track (dry — sends stripped) and
    /// one per bus (carrying ALL send contributions routed into it, through
    /// the bus chain and fader). The normative invariant: Σ stems ≡ the
    /// mixdown, null residual peak ≤ 1e-4.
    ///
    /// PDC is why every pass is FORCED under the full-session compensation
    /// plan, probed ONCE up front: a subset pass's automatic plan would give a
    /// lone dry track target 0 where the mix delays it to the session's
    /// highest-latency strip, landing the stem early and combing the sum.
    ///
    /// - Stems are NEVER normalized (spec §4.1) — independent gains would
    ///   destroy inter-stem balance and the sum invariant. Each file ships a
    ///   full `LoudnessMeasurement` instead (> 0 dBFS stretch overshoots stay
    ///   visible in Float32, never clipped, never gain-baked).
    /// - `trackIds` nil → all master inputs; a bus-routed track id rejects
    ///   `stemNotMasterInput`; an unknown id rejects `trackNotFound`; an empty
    ///   selection is `nothingToRender`.
    /// - `includeMixdown` adds a "00 Mixdown.wav" reference pass over the full
    ///   session under the SAME forced targets (forcing the auto-plan's own
    ///   values is a parity no-op) — the null-check anchor.
    /// - `includeMasteredMixdown` (m23-m1) adds a "00 Mastered Mix.wav" SIBLING
    ///   — the real mastered mix, rendered exactly the way `render.bounce`
    ///   renders (full session, real master chain, real master automation lane,
    ///   real master volume), optionally normalized via `masteredLufsTarget` /
    ///   `masteredTruePeakCeilingDb` through the SAME gain-only policy
    ///   (`deliveryNormalized`). It is a sibling, NEVER a transformation of the
    ///   stems: for a nonlinear master chain `M`, `Σᵢ M(sᵢ) ≠ M(Σᵢ sᵢ)`
    ///   (S-3′, research §4.3), which is why the chain is not printed onto each
    ///   stem. `includeMixdown` and `includeMasteredMixdown` are INDEPENDENT
    ///   booleans producing two independently-optional files with different,
    ///   non-overlapping meanings — the chain-EXCLUDED null anchor and the
    ///   mastered deliverable — never a shared flag with a "which chain"
    ///   switch. Both may be requested at once.
    /// - Memory-bounded: one stem's buffers in flight at a time
    ///   (render → measure → write → release, N sequential passes). The
    ///   duration window is computed ONCE so every file has identical length
    ///   (summation requires it). Blocking; v0 accepts the main-actor stall
    ///   (~N × one-mixdown-time).
    /// - The mastered pass runs LAST, after every stem and after the reference
    ///   mixdown. Consequence, documented rather than hidden: a
    ///   `masteredLufsTarget` on a gated-silent program throws `bounceSilent`
    ///   AFTER the stem files have already landed on disk (throwing matches
    ///   `renderBounce`; the partial output is real).
    public func renderStems(toDirectory directory: String? = nil, trackIds: [UUID]? = nil,
                            fromBeat: Double = 0, durationSeconds: Double? = nil,
                            includeMixdown: Bool = false,
                            includeMasteredMixdown: Bool = false,
                            masteredLufsTarget: Double? = nil,
                            masteredTruePeakCeilingDb: Double = -1.0,
                            bitDepth: Int? = nil,
                            container: String? = nil) async throws -> StemExportResult {
        guard let engine else { throw ProjectError.engineUnavailable }
        // Resolved FIRST — this op writes N files, so an invalid format must
        // reject before ANY of them lands, not part-way through the set.
        let format = try DeliveryFormat.resolve(bitDepth: bitDepth, container: container)
        let startBeat = max(0, fromBeat)
        let descriptors = try StemPlan.descriptors(tracks: tracks, including: trackIds,
                                                   format: format)
        guard !descriptors.isEmpty else { throw ProjectError.nothingToRender }
        let duration = try renderWindowSeconds(fromBeat: startBeat, requested: durationSeconds)
        let dir = Self.stemsDestination(from: directory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // m23-bx-1: captured ONCE for the whole stem set, so every pass below
        // renders the SAME hosted-AU state — re-capturing per pass would let a
        // mid-export plugin edit land in some stems and not others, and the
        // partition (Σ stems nulls against "00 Mixdown.wav") would stop
        // holding for a reason no one could see in the files.
        let liveTracks = tracksWithLiveAudioUnitState()
        // The full-session plan, probed ONCE — every pass below is forced
        // under it (WYSIWYG stretch awaits ride inside each renderOffline).
        let targets = await engine.offlineCompensationTargets(tracks: liveTracks)

        var stems: [StemFile] = []
        var sampleRate = 0.0
        var channels = 0
        var writtenDuration = 0.0
        for descriptor in descriptors {
            // STEM class (m13-d, design §2 / S-3′): stems are PRE-master
            // material — a nonlinear master chain does not distribute over
            // the partition, so every pass renders chain-excluded. The master
            // volume LANE is excluded too (m15-c, the S-3′ extension): a fade
            // is master performance, not material — baking it into every stem
            // would destroy the re-mixable partition (the static masterVolume
            // stays included, exactly as ever).
            let audio = try await engine.renderOffline(
                tracks: StemPlan.passTracks(for: descriptor, session: liveTracks),
                tempoMap: transport.tempoMap, masterVolume: masterVolume,
                masterEffects: [],
                masterAutomation: [],
                fromBeat: startBeat, durationSeconds: duration,
                forcedCompensationTargets: targets
            )
            let measurement = await Loudness.measureDetached(audio)
            let url = dir.appendingPathComponent(descriptor.fileName)
            let info = try engine.writeAudioFile(audio, to: url, format: format)
            sampleRate = info.sampleRate
            channels = info.channelCount
            writtenDuration = info.durationSeconds
            stems.append(StemFile(trackId: descriptor.id, name: descriptor.name,
                                  kind: descriptor.kind, path: url.path,
                                  measurement: measurement))
            // `audio` goes out of scope here — one stem's buffers alive at a
            // time (~230 MB transient for a 10-min stereo render, spec §5).
        }

        var mixdown: MixdownFile?
        if includeMixdown {
            // STEM class too (m13-d, S-3′): "00 Mixdown.wav" is the stems'
            // own chain-excluded (and lane-excluded, m15-c) reference — the
            // null-check anchor Σ-stems compares against. A MASTERED file
            // comes from `render.bounce`.
            let audio = try await engine.renderOffline(
                tracks: liveTracks, tempoMap: transport.tempoMap, masterVolume: masterVolume,
                masterEffects: [],
                masterAutomation: [],
                fromBeat: startBeat, durationSeconds: duration,
                forcedCompensationTargets: targets
            )
            // The name comes from `StemPlan` (m23-m3c), never a literal here:
            // the export dialog PREVIEWS the planned set, so this string has a
            // reader as well as a writer.
            let url = dir.appendingPathComponent(format.fileName(StemPlan.mixdownBaseName))
            let measurement = await Loudness.measureDetached(audio)
            _ = try engine.writeAudioFile(audio, to: url, format: format)
            mixdown = MixdownFile(path: url.path, measurement: measurement)
        }

        var masteredMixdown: MasteredMixdownFile?
        if includeMasteredMixdown {
            // MASTERED class (m13-d, design §2) — the `render.bounce` pass,
            // verbatim: full session, real master chain, real master
            // automation lane, real master volume. The SIBLING of the stems,
            // never a transformation of them (S-3′, research §4.3): a
            // nonlinear master chain does not distribute over the partition,
            // so Σ stems nulls against "00 Mixdown.wav" and NOT against this
            // file — that difference IS the chain, and it is the reason the
            // chain is not printed onto each stem.
            //
            // Same forced full-session targets as every other pass here: the
            // array is the full session, so forcing the auto-plan's own values
            // is a parity no-op, and it removes timing as a confound when
            // someone diffs this file against the stems' sum.
            let rendered = try await engine.renderOffline(
                tracks: liveTracks, tempoMap: transport.tempoMap, masterVolume: masterVolume,
                masterEffects: masterEffects,
                masterAutomation: masterAutomation,
                fromBeat: startBeat, durationSeconds: duration,
                forcedCompensationTargets: targets
            )
            // The SAME normalization policy `render.bounce` runs — one home,
            // so "−14 LUFS" cannot mean two different things (m23-m1).
            let normalized = try await Self.deliveryNormalized(
                consume rendered, lufsTarget: masteredLufsTarget,
                truePeakCeilingDb: masteredTruePeakCeilingDb)
            // `StemPlan.masteredMixdownBaseName` (m23-m3c) — same one-home rule
            // as the reference mixdown above.
            let url = dir.appendingPathComponent(
                format.fileName(StemPlan.masteredMixdownBaseName))
            _ = try engine.writeAudioFile(normalized.audio, to: url, format: format)
            masteredMixdown = MasteredMixdownFile(path: url.path, report: normalized.report)
        }

        return StemExportResult(directory: dir.path, sampleRate: sampleRate,
                                durationSeconds: writtenDuration, channels: channels,
                                stems: stems, mixdown: mixdown,
                                // Honesty field (m13-d, design §2): present —
                                // as "excluded" — exactly when the project
                                // carries a non-empty master chain, so an
                                // agent cannot mistake stems for mastered
                                // deliverables. It describes the STEMS, which
                                // stay chain-excluded whether or not the
                                // mastered sibling was written — m23-m1 does
                                // not touch this live string.
                                masterChain: masterEffects.isEmpty ? nil : "excluded",
                                masteredMixdown: masteredMixdown,
                                bitDepth: format.reportedBitDepth,
                                container: format.reportedContainer,
                                ditherApplied: format.reportedDitherApplied)
    }

    // MARK: - Shared window / destination policy

    /// The shared default render window (spec §4.3): explicit duration wins;
    /// otherwise the extent of ALL tracks' clips past `fromBeat` at the
    /// current tempo, plus a 2.0 s tail (bus reverb/release). Computed ONCE
    /// per call so every file of a multi-pass export (iv-c stems) has
    /// identical length.
    /// Internal (not private) so `bounceTrackInPlace` (m11-e) shares the SAME
    /// default window as `render.stems` — a one-track bounce must land the same
    /// length a direct stem render of that track would.
    func renderWindowSeconds(fromBeat startBeat: Double,
                             requested: Double?) throws -> Double {
        if let requested { return requested }
        let clipEnds = tracks.flatMap(\.clips).map { $0.startBeat + $0.lengthBeats }
        guard let lastEndBeat = clipEnds.max() else {
            throw ProjectError.nothingToRender
        }
        // The integral over [startBeat, lastEndBeat] (m12-b, design row 20) —
        // ONE conversion site shared by stems / bounce / bounce-in-place.
        let contentSeconds = transport.tempoMap.seconds(from: startBeat, to: lastEndBeat)
        guard contentSeconds > 0 else { throw ProjectError.nothingToRender }
        return contentSeconds + 2.0
    }

    /// Destination resolution (the `mixdownDestination` policy with a bounce
    /// prefix): nil → a unique file under NSTemporaryDirectory()/DAWPro/;
    /// otherwise `~` expands and the FORMAT's extension is applied.
    ///
    /// The extension comes from `DeliveryFormat` (m23-m2) and not from a
    /// literal here, because it is load-bearing: `AVAudioFile` picks the
    /// container off the path extension, so `container: "aiff"` with
    /// `path: "mix"` used to write a WAV named `mix.wav` while the response
    /// said AIFF. See `DeliveryFormat.applyingExtension` for the exact rule
    /// (append, never clobber; canonicalize casing).
    static func bounceDestination(from path: String?,
                                  format: DeliveryFormat = .default) -> URL {
        guard let path else {
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("DAWPro", isDirectory: true)
                .appendingPathComponent(
                    format.fileName("bounce-\(UUID().uuidString.prefix(8))"))
        }
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: format.applyingExtension(to: expanded))
    }

    /// Stem-directory resolution (spec §4.3): nil → a unique directory under
    /// NSTemporaryDirectory()/DAWPro/; otherwise `~` expands. Created (with
    /// intermediates) by the caller.
    private static func stemsDestination(from directory: String?) -> URL {
        guard let directory else {
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("DAWPro", isDirectory: true)
                .appendingPathComponent("stems-\(UUID().uuidString.prefix(8))",
                                        isDirectory: true)
        }
        let expanded = (directory as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }
}
