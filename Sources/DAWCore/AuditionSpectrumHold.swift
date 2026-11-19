import Foundation

// m27-j (W8-M27J, 2026-10-07): "audition a note, look at the spectrum" in ONE
// call. `fx.spectrum` used to arm its tap and read it in the same call, and
// one read analyzes only the newest `InsertSpectrumTap.maxDrainFrames` (4,096
// frames, ~85 ms at 48 kHz). An agent that called `note.audition` and THEN
// `fx.spectrum` therefore read the floor: the note had ended, or the 3 s lease
// had lapsed and the call armed a fresh, empty tap (measured: DAWEngineTests
// `InsertSpectrumCoverageTests` "m27-j …" legs). The probe below arms first,
// starts the note, and keeps reading while the note sounds, holding the
// loudest value each band reaches.

/// How much of an armed insert's sound has reached its analyzer — consumer-side
/// counters, read on the main actor (never on the render thread).
public struct InsertAnalysisCoverage: Sendable, Equatable {
    /// Frames the analyzer actually processed since the tap was armed.
    public var framesAnalyzed: UInt64
    /// Frames the tap received but discarded because a read came too late
    /// (the oldest are dropped first). Any increase during a hold is a gap.
    public var framesDropped: UInt64

    public init(framesAnalyzed: UInt64, framesDropped: UInt64) {
        self.framesAnalyzed = framesAnalyzed
        self.framesDropped = framesDropped
    }
}

/// A peak hold over successive insert-analysis reads.
///
/// - `bands`, `levelDB`, `peakDB`: the HIGHEST value each one reached across
///   all reads (per band, independently).
/// - `centroidHz`, `flux`, `correlation`, `width`, `balance`: taken from the
///   LOUDEST read (highest `levelDB`; the first one wins a tie), because a
///   maximum of a correlation or a balance means nothing.
public struct SpectrumPeakHold: Sendable, Equatable {
    /// How many reads were absorbed.
    public private(set) var reads = 0
    /// The held snapshot; nil until the first read.
    public private(set) var snapshot: MasterAnalysisSnapshot?

    public init() {}

    public mutating func absorb(_ reading: MasterAnalysisSnapshot) {
        reads += 1
        guard var held = snapshot else {
            snapshot = reading
            return
        }
        let count = min(held.bands.count, reading.bands.count)
        var index = 0
        while index < count {
            held.bands[index] = max(held.bands[index], reading.bands[index])
            index += 1
        }
        held.peakDB = max(held.peakDB, reading.peakDB)
        if reading.levelDB > held.levelDB {
            held.levelDB = reading.levelDB
            held.centroidHz = reading.centroidHz
            held.flux = reading.flux
            held.correlation = reading.correlation
            held.width = reading.width
            held.balance = reading.balance
        }
        snapshot = held
    }
}

/// The one-call "play a note and measure it" loop behind `fx.spectrum`'s
/// `audition` parameter. Pure orchestration: the caller supplies how to start
/// the note, how to read the insert, how to wait, and how to keep its lease
/// alive, so the SAME loop runs against the real engine in tests.
public enum AuditionSpectrumProbe {
    /// Pause between reads. Must stay well under the newest-window length one
    /// read can analyze (4,096 frames: ~85 ms at 48 kHz, ~43 ms at 96 kHz,
    /// ~21 ms at 192 kHz) so consecutive reads leave no gap; 20 ms is ~960
    /// frames at 48 kHz.
    public static let pollIntervalMs = 20
    /// How long the probe keeps reading after `durationMs`: covers the note's
    /// release and the audio output's own delay.
    public static let tailMs = 150
    /// The reply's `hold` value: what the returned spectrum is.
    public static let holdKind = "peakOverAudition"

    /// Reads taken for a note of `durationMs`: enough to cover the note plus
    /// `tailMs`, rounded up, never fewer than one.
    public static func pollCount(durationMs: Int) -> Int {
        let span = max(0, durationMs) + tailMs
        return max(1, (span + pollIntervalMs - 1) / pollIntervalMs)
    }

    /// Starts the note, then `pollCount(durationMs:)` times: waits
    /// `pollIntervalMs`, renews the caller's lease, reads, and folds the reading
    /// into the hold. A nil read (the insert stopped being measurable) is
    /// skipped, not counted. The note ends on its own (`start` is expected to
    /// be a self-releasing one-shot).
    @MainActor
    public static func hold(durationMs: Int,
                            start: () throws -> Void,
                            read: () -> MasterAnalysisSnapshot?,
                            wait: (Duration) async -> Void,
                            keepAlive: () -> Void) async throws -> SpectrumPeakHold {
        try start()
        var held = SpectrumPeakHold()
        let polls = pollCount(durationMs: durationMs)
        var poll = 0
        while poll < polls {
            await wait(.milliseconds(pollIntervalMs))
            keepAlive()
            if let reading = read() { held.absorb(reading) }
            poll += 1
        }
        return held
    }
}
