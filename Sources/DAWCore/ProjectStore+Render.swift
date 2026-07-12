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
    /// `durationSeconds` nil → the shared default window: extent of ALL
    /// tracks' clips (audio AND instrument — deliberately broader than
    /// `renderMixdown`'s audio-only legacy default, which stays untouched)
    /// plus a 2.0 s bus-reverb/release tail. No clips past `fromBeat` →
    /// `nothingToRender`.
    public func measureLoudness(fromBeat: Double = 0,
                                durationSeconds: Double? = nil) async throws -> LoudnessMeasureResult {
        guard let engine else { throw ProjectError.engineUnavailable }
        let startBeat = max(0, fromBeat)
        let duration = try renderWindowSeconds(fromBeat: startBeat, requested: durationSeconds)
        let audio = try await engine.renderOffline(
            tracks: tracks, tempoMap: transport.tempoMap, masterVolume: masterVolume,
            fromBeat: startBeat, durationSeconds: duration,
            forcedCompensationTargets: nil
        )
        return LoudnessMeasureResult(
            measurement: Loudness.measure(audio),
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
    /// chose the path). Blocking; v0 accepts the main-actor stall.
    public func renderBounce(toPath path: String? = nil, fromBeat: Double = 0,
                             durationSeconds: Double? = nil, lufsTarget: Double? = nil,
                             truePeakCeilingDb: Double = -1.0) async throws -> BounceResult {
        guard let engine else { throw ProjectError.engineUnavailable }
        let startBeat = max(0, fromBeat)
        let duration = try renderWindowSeconds(fromBeat: startBeat, requested: durationSeconds)
        var audio = try await engine.renderOffline(
            tracks: tracks, tempoMap: transport.tempoMap, masterVolume: masterVolume,
            fromBeat: startBeat, durationSeconds: duration,
            forcedCompensationTargets: nil
        )
        let input = Loudness.measure(audio)

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
            audio.applyGain(linear: Float(pow(10.0, appliedGainDb / 20.0)))
            // Re-measured, not derived — exact for the buffer that hits disk.
            output = Loudness.measure(audio)
        } else {
            // No gain applied: the input measurement IS the output's.
            output = input
        }

        let url = Self.bounceDestination(from: path)
        let info = try engine.writeAudioFile(audio, to: url)
        // A file landed on disk — tick the render counter for the onboarding
        // signal adapter (ob-b), which fires `renderCompleted` on an increment.
        renderCompletedCount += 1
        return BounceResult(
            path: url.path,
            durationSeconds: info.durationSeconds,
            sampleRate: info.sampleRate,
            channels: info.channelCount,
            report: BounceLoudnessReport(
                input: input,
                output: output,
                appliedGainDb: appliedGainDb,
                lufsTarget: lufsTarget,
                truePeakCeilingDbtp: truePeakCeilingDb,
                limitedByCeiling: limitedByCeiling
            )
        )
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
    /// - Memory-bounded: one stem's buffers in flight at a time
    ///   (render → measure → write → release, N sequential passes). The
    ///   duration window is computed ONCE so every file has identical length
    ///   (summation requires it). Blocking; v0 accepts the main-actor stall
    ///   (~N × one-mixdown-time).
    public func renderStems(toDirectory directory: String? = nil, trackIds: [UUID]? = nil,
                            fromBeat: Double = 0, durationSeconds: Double? = nil,
                            includeMixdown: Bool = false) async throws -> StemExportResult {
        guard let engine else { throw ProjectError.engineUnavailable }
        let startBeat = max(0, fromBeat)
        let descriptors = try StemPlan.descriptors(tracks: tracks, including: trackIds)
        guard !descriptors.isEmpty else { throw ProjectError.nothingToRender }
        let duration = try renderWindowSeconds(fromBeat: startBeat, requested: durationSeconds)
        let dir = Self.stemsDestination(from: directory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // The full-session plan, probed ONCE — every pass below is forced
        // under it (WYSIWYG stretch awaits ride inside each renderOffline).
        let targets = await engine.offlineCompensationTargets(tracks: tracks)

        var stems: [StemFile] = []
        var sampleRate = 0.0
        var channels = 0
        var writtenDuration = 0.0
        for descriptor in descriptors {
            let audio = try await engine.renderOffline(
                tracks: StemPlan.passTracks(for: descriptor, session: tracks),
                tempoMap: transport.tempoMap, masterVolume: masterVolume,
                fromBeat: startBeat, durationSeconds: duration,
                forcedCompensationTargets: targets
            )
            let measurement = Loudness.measure(audio)
            let url = dir.appendingPathComponent(descriptor.fileName)
            let info = try engine.writeAudioFile(audio, to: url)
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
            let audio = try await engine.renderOffline(
                tracks: tracks, tempoMap: transport.tempoMap, masterVolume: masterVolume,
                fromBeat: startBeat, durationSeconds: duration,
                forcedCompensationTargets: targets
            )
            let url = dir.appendingPathComponent("00 Mixdown.wav")
            let measurement = Loudness.measure(audio)
            _ = try engine.writeAudioFile(audio, to: url)
            mixdown = MixdownFile(path: url.path, measurement: measurement)
        }

        return StemExportResult(directory: dir.path, sampleRate: sampleRate,
                                durationSeconds: writtenDuration, channels: channels,
                                stems: stems, mixdown: mixdown)
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
    /// otherwise `~` expands and `.wav` is appended unless already present
    /// (case-insensitive).
    private static func bounceDestination(from path: String?) -> URL {
        guard let path else {
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("DAWPro", isDirectory: true)
                .appendingPathComponent("bounce-\(UUID().uuidString.prefix(8)).wav")
        }
        var expanded = (path as NSString).expandingTildeInPath
        if !expanded.lowercased().hasSuffix(".wav") {
            expanded += ".wav"
        }
        return URL(fileURLWithPath: expanded)
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
