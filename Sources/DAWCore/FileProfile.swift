import Foundation

/// Offline windowed peak/RMS profile of a file on disk (m25-z — the missing
/// "what is the peak level between 53s and 54s of this WAV" surface, filed
/// after a verification session needed four external probes — `astats`,
/// `silencedetect`, `ffprobe`, a hand-written profiler — to answer that one
/// question about a rendered file).
///
/// A DIFFERENT job from `render.measureLoudness` (`LoudnessMeasureResult`,
/// SESSION-domain, before quantization, BS.1770 program loudness) and
/// `reference.analyze` (`ReferenceAnalysis`, whole-FILE-only, also BS.1770):
/// this is windowED sample peak/RMS over an ARBITRARY file on disk,
/// read-only, and deliberately never touches the project reference slot or
/// the References library. It is also deliberately NOT a second copy of the
/// BS.1770 loudness path (m23-ch: a single meter cannot detect its own
/// miscount, which is why the external `ebur128` cross-check stays
/// external) — the windows answer a WINDOWING question, not a loudness one.
/// The one exception is OPT-IN (m27-k): `loudness`, below, is the SAME meter
/// those commands use, read through this door so a bounce's loudness can be
/// checked without `reference.import` copying the file.
public struct FileProfile: Codable, Sendable, Equatable {
    /// The WHOLE file's duration — the `ffprobe` readback — independent of
    /// any `fromSeconds`/`durationSeconds` sub-range that was requested.
    public var durationSeconds: Double
    public var sampleRateHz: Double
    public var channelCount: Int
    /// On-disk PCM bit depth (e.g. 16, 24, 32). nil for formats with no
    /// fixed bit depth (compressed codecs) — never fabricated.
    public var bitDepth: Int?
    /// true = IEEE float samples on disk, false = integer PCM, nil when the
    /// format doesn't expose it (compressed codecs).
    public var isFloat: Bool?
    public var windows: [FileProfileWindow]
    /// m27-k, OPT-IN: the BS.1770 program reading for the PROFILED RANGE
    /// (`[fromSeconds, fromSeconds + durationSeconds)`, measured as if it were
    /// its own file: the filters start cold at `fromSeconds` and the true-peak
    /// edge is zero-padded at the range end). Present ONLY when the request
    /// asked for it (`audio.profileFile {loudness: true}`); nil otherwise,
    /// which synthesized Codable OMITS, so the no-flag reply is byte-identical
    /// to m25-z's. The `LoudnessMeasurement` shape `render.measureLoudness`
    /// reports, from `Loudness.Stream`, the meter `reference.analyze` uses (a
    /// second door, not a second meter). Each field is nil when the range
    /// holds no evidence for it: under 0.4 s has no integrated or momentary
    /// reading, under 3 s no short-term or range, digital silence none.
    public var loudness: LoudnessMeasurement?

    public init(
        durationSeconds: Double, sampleRateHz: Double, channelCount: Int,
        bitDepth: Int? = nil, isFloat: Bool? = nil, windows: [FileProfileWindow],
        loudness: LoudnessMeasurement? = nil
    ) {
        self.durationSeconds = durationSeconds
        self.sampleRateHz = sampleRateHz
        self.channelCount = channelCount
        self.bitDepth = bitDepth
        self.isFloat = isFloat
        self.windows = windows
        self.loudness = loudness
    }
}

/// One time window of a `FileProfile` (m25-z).
public struct FileProfileWindow: Codable, Sendable, Equatable {
    /// Absolute position IN THE FILE, seconds — `fromSeconds` plus however
    /// many whole windows precede this one. Never re-based to 0, so windows
    /// from two calls with different `fromSeconds` are directly comparable.
    public var startSeconds: Double
    /// Usually the requested `windowSeconds`, EXCEPT the final window of a
    /// profiled range, which truncates at EOF (or at
    /// `fromSeconds + durationSeconds`) and reads shorter. This is how a
    /// caller tells a full window from a truncated one without re-deriving
    /// it from `startSeconds` and the file's own `durationSeconds`.
    public var durationSeconds: Double
    /// Sample peak, dBFS. This is the raw inter-sample maximum, NOT the
    /// 4x-oversampled BS.1770 Annex-2 true peak `render.measureLoudness` /
    /// `reference.analyze` report as `truePeakDbtp` — a window can read
    /// under 0 dBFS sample peak here and still exceed 0 dBTP true peak. Use
    /// those commands for true-peak/loudness questions; use this one for
    /// "what did this window of the file actually contain".
    /// nil = every sample in this window is exactly digital silence
    /// (honest absence — JSON has no -inf; never a fabricated 0).
    public var peakDb: Double?
    /// RMS across all channels combined, dBFS (the live-meter convention —
    /// max-abs peak / combined-channel RMS, `MeterFrame`/`AudioEngine`'s
    /// meter tap — deliberately NOT a mono downmix first, which would
    /// under-report anti-phase content). nil for the same reason as
    /// `peakDb`.
    public var rmsDb: Double?

    public init(
        startSeconds: Double, durationSeconds: Double,
        peakDb: Double? = nil, rmsDb: Double? = nil
    ) {
        self.startSeconds = startSeconds
        self.durationSeconds = durationSeconds
        self.peakDb = peakDb
        self.rmsDb = rmsDb
    }
}
