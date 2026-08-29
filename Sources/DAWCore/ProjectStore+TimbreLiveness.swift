import Foundation

/// m31-f ② — the RENDER half of the timbre-liveness probe.
///
/// `TimbreLiveness` (same module) is the pure measurement: hand it a rendered
/// velocity ladder and it answers STATIC / LIVE / INCONCLUSIVE / SILENT. This
/// file is what actually BUILDS that ladder — it synthesises the notes, renders
/// them offline through the engine seam (`renderOffline`, the
/// `measureLoudness`/`bounceInPlace` pattern), and hands the buffer over.
///
/// ## The probe never touches the project
///
/// The ladder is rendered from a SYNTHETIC `[Track]` array built here and
/// thrown away — a one-track copy of the target carrying one temporary MIDI
/// clip. Nothing is inserted, no edit is performed, no undo entry is pushed,
/// and `store.tracks` is never mutated. A user with the app open sees nothing
/// change; a diagnostic that edited the song to diagnose it would be worse than
/// the defect it looks for.
///
/// ## Why the copy is stripped bare
///
/// The question is "does this PATCH have more than one timbre", not "does this
/// mix have more than one timbre". Every mix-plane thing that could forge or
/// destroy the signal is removed from the copy before rendering:
///
/// - `effects` / `sends` — a compressor or limiter on the strip flattens the
///   RMS spread and turns a healthy patch INCONCLUSIVE; a distortion pedal
///   moves the centroid and turns a dead patch LIVE. Either way the reading
///   would describe the chain, not the instrument.
/// - `automation` — a volume lane manufactures level movement the velocities
///   did not produce, which is exactly the evidence the verdict rests on.
/// - `isMuted` / `isSoloed` / `volume` / `pan` — a muted or faded-down track
///   renders silence, and SILENT would be reported for a perfectly good patch.
/// - `outputBusID` — the bus track is not in the synthetic array, so a
///   bus-routed track would render into nothing.
/// - `masterVolume` is forced to unity and the master chain is empty (STEM
///   class, m13-d): a pulled-down master fader must not make an instrument
///   read as dead.
///
/// The `TimbreLiveness.caveats` text promises the reading is DRY; this is the
/// code that has to keep that promise.
///
/// ## Render from beat 0, always
///
/// ⚠️ A `fromBeat`-windowed render DROPS every MIDI note whose note-on precedes
/// the window — it reports silence for material that is fine from the top. The
/// ladder is therefore authored at beat 0 and rendered from beat 0, and there
/// is deliberately no `fromBeat` parameter on the wire to get this wrong with.
@MainActor
extension ProjectStore {

    /// Default ladder pitch: MIDI 57 = A3. The calibration ground truth in the
    /// item brief (Apple DLS sax 0.05 %, GeneralUser GS sax 6.59 %) was
    /// measured at this pitch, so the shipped default reproduces it.
    public static let livenessDefaultPitch = 57
    /// Ascending pp → ff. Four rungs is the fewest that can show a PLATEAU
    /// (three would read any layer boundary as a slide).
    public static let livenessDefaultVelocities = [25, 60, 95, 127]
    /// One second of note, one second of gap — `scripts/probes/timbre-liveness.sh`'s
    /// geometry verbatim ("each 1 s long, starting on even seconds"), so a
    /// figure measured with the shell probe transfers to this one.
    public static let livenessNoteSeconds = 1.0
    public static let livenessNoteSpacingSeconds = 2.0
    /// The analysis window sits 0.30 s into each note and runs 0.60 s — past
    /// the attack transient, inside the sustain, ending before the release.
    /// Also verbatim from the shell probe.
    public static let livenessWindowOffsetSeconds = 0.30
    public static let livenessWindowSeconds = 0.60
    /// Release/reverb tail past the last note so a long-release patch is not
    /// truncated mid-render (the window never reaches here; it exists so the
    /// renderer is not asked to stop inside a sounding voice).
    public static let livenessTailSeconds = 2.0

    /// Renders a velocity ladder on `trackId` — the same pitch, one note per
    /// velocity, ascending — and measures whether the TIMBRE moves with it.
    ///
    /// Throws `TimbreLiveness.ProbeError.meterSelfCheckFailed` rather than
    /// returning a verdict when the spectral-centroid meter fails its own
    /// positive control: a flat centroid is exactly the shape a broken
    /// measurement makes, and reporting deadness from a meter that cannot
    /// discriminate is indistinguishable from a true finding.
    public func probeInstrumentLiveness(
        trackId: UUID,
        pitch: Int = ProjectStore.livenessDefaultPitch,
        velocities: [Int] = ProjectStore.livenessDefaultVelocities,
        noteSeconds: Double = ProjectStore.livenessNoteSeconds
    ) async throws -> TimbreLiveness.Result {
        guard let engine else { throw ProjectError.engineUnavailable }
        // m23-bx-1: probe the patch the user is HEARING. A hosted AU whose live
        // parameter state differs from the last-saved one would otherwise be
        // measured in a configuration nobody has listened to.
        let live = tracksWithLiveAudioUnitState()
        guard let source = live.first(where: { $0.id == trackId }) else {
            throw ProjectError.trackNotFound(trackId)
        }
        guard source.kind == .instrument else {
            throw ProjectError.instrumentRequiresInstrumentTrack(source.kind)
        }
        guard velocities.count >= 2 else { throw TimbreLiveness.ProbeError.noVelocities }
        let clampedPitch = pitch.clamped(to: MIDINote.pitchRange)
        let length = max(0.05, noteSeconds)
        let spacing = max(length * 2, Self.livenessNoteSpacingSeconds)

        // Note starts in SECONDS are the contract with `analyzeLadder`; the
        // clip is authored in BEATS. Both conversions go through the SAME tempo
        // map that is handed to the renderer, so a non-120 or multi-segment
        // tempo cannot slide the analysis window off its rung.
        let map = transport.tempoMap
        let starts = (0..<velocities.count).map { Double($0) * spacing }
        var notes: [MIDINote] = []
        for (index, velocity) in velocities.enumerated() {
            let startBeat = map.beat(from: 0, elapsedSeconds: starts[index])
            let endBeat = map.beat(from: 0, elapsedSeconds: starts[index] + length)
            notes.append(MIDINote(pitch: clampedPitch,
                                  velocity: velocity.clamped(to: MIDINote.velocityRange),
                                  startBeat: startBeat,
                                  lengthBeats: max(MIDINote.minLengthBeats, endBeat - startBeat)))
        }
        let totalSeconds = (starts.last ?? 0) + length + Self.livenessTailSeconds

        var probeTrack = source
        probeTrack.clips = [Clip(name: "Liveness Probe", startBeat: 0,
                                 lengthBeats: map.beat(from: 0, elapsedSeconds: totalSeconds),
                                 notes: notes)]
        probeTrack.effects = []
        probeTrack.sends = []
        probeTrack.automation = []
        probeTrack.takeGroups = []
        probeTrack.outputBusID = nil
        probeTrack.isMuted = false
        probeTrack.isSoloed = false
        probeTrack.volume = 1
        probeTrack.pan = 0

        // STEM class (m13-d): no master effects, no master automation, unity
        // master. `forcedCompensationTargets: nil` — one dry track with no
        // inserts has no PDC plan to force.
        let audio = try await engine.renderOffline(
            tracks: [probeTrack], tempoMap: map, masterVolume: 1.0,
            masterEffects: [], masterAutomation: [],
            fromBeat: 0, durationSeconds: totalSeconds,
            forcedCompensationTargets: nil)

        return try TimbreLiveness.analyzeLadder(
            audio: audio,
            velocities: notes.map(\.velocity),
            noteStarts: starts,
            windowOffsetSeconds: Self.livenessWindowOffsetSeconds,
            windowSeconds: Self.livenessWindowSeconds,
            trackId: trackId.uuidString,
            instrumentKind: source.instrument?.kind.rawValue
                ?? InstrumentDescriptor.default.kind.rawValue,
            instrumentDetail: Self.livenessInstrumentDetail(source.instrument),
            pitch: clampedPitch,
            noteSeconds: length)
    }

    /// A human-readable name for WHICH patch was probed, so a verdict in a log
    /// can be traced back to an instrument without a second round trip. nil
    /// when the kind carries no sub-selection (the built-in synth/test tone).
    static func livenessInstrumentDetail(_ instrument: InstrumentDescriptor?) -> String? {
        guard let instrument else { return nil }
        switch instrument.kind {
        case .soundBank:
            guard let bank = instrument.soundBank else { return nil }
            let file: String
            switch bank.source {
            case .generalMIDI: file = "General MIDI"
            case .file(let path): file = URL(fileURLWithPath: path).lastPathComponent
            }
            return "\(file) program \(bank.program)"
                + (bank.displayName.isEmpty ? "" : " — \(bank.displayName)")
        case .audioUnit:
            guard let unit = instrument.audioUnit else { return nil }
            return unit.name
        case .sampler:
            let zones = instrument.resolvedSampler.zones.count
            return "sampler, \(zones) zone\(zones == 1 ? "" : "s")"
        case .polySynth, .testTone:
            return nil
        }
    }
}
