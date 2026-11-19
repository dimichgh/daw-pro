import Foundation

// m39-w4-6 — what the engine measures about one chopped slice, so a pure classifier can sort a drum loop's
// hits into a kit. Design `docs/design/2026-10-07-loop-drum-depth.md` §5.2, step 1.
//
// The engine measures (`AudioEngineControlling.analyzeSliceTimbres`, off the render thread); DAWCore decides
// (`DrumHitClassifier`, `KitSliceLayout`). Nothing here touches audio.

/// One slice's span in the SOURCE FILE's own frames: the units of `SliceBoundaryGeometry` and of every
/// `SliceReport`. `end` nil = the file's end (the last pad of a chop that reaches it).
public struct SliceFrameSpan: Sendable, Equatable, Codable {
    public var start: Int
    public var end: Int?

    public init(start: Int, end: Int?) {
        self.start = start
        self.end = end
    }
}

/// The features `DrumHitClassifier` reads. Every SPECTRAL feature is taken over the slice's first
/// `attackWindowSeconds` (the hit, not its tail) of the channel-averaged signal; the decay and the peak are
/// taken over the whole slice.
public struct SliceTimbre: Sendable, Equatable, Codable {
    /// Share of the attack window's spectral power below `lowBandHz`, 0…1. Where a kick lives.
    public var lowEnergyShare: Double
    /// Share of the attack window's spectral power above `highBandHz`, 0…1. Where a hi-hat lives.
    public var highEnergyShare: Double
    /// The attack window's spectral centroid, Hz.
    public var attackCentroidHz: Double
    /// Seconds from the slice's loudest moment to the first moment `decayDropDb` below it. When the slice
    /// ends first, the seconds from the loudest moment to the slice's end, and `decayReachedFloor` is false:
    /// the sound was still ringing when the next hit cut it.
    public var decaySeconds: Double
    public var decayReachedFloor: Bool
    /// The attack window's spectral flatness: the geometric over the arithmetic mean of its power spectrum,
    /// 0 (one pure tone) … 1 (white noise).
    public var spectralFlatness: Double
    /// The largest absolute sample in the slice, linear (1 = full scale). `KitSliceLayout` gives a role's
    /// first note to its loudest slice.
    public var peak: Double
    /// The slice's length, seconds.
    public var durationSeconds: Double

    /// Below this a hit is "low" (design §5.2: "share of energy below 150 Hz").
    public static let lowBandHz = 150.0
    /// Above this a hit is "high" (design §5.2: "share above 5 kHz").
    public static let highBandHz = 5_000.0
    /// The spectral features' window (design §5.2: "centroid over the first 80 ms").
    public static let attackWindowSeconds = 0.080
    /// The decay is timed to this fall (design §5.2: "decay time from peak to −20 dB").
    public static let decayDropDb = 20.0

    public init(lowEnergyShare: Double, highEnergyShare: Double, attackCentroidHz: Double,
                decaySeconds: Double, decayReachedFloor: Bool, spectralFlatness: Double,
                peak: Double, durationSeconds: Double) {
        self.lowEnergyShare = lowEnergyShare
        self.highEnergyShare = highEnergyShare
        self.attackCentroidHz = attackCentroidHz
        self.decaySeconds = decaySeconds
        self.decayReachedFloor = decayReachedFloor
        self.spectralFlatness = spectralFlatness
        self.peak = peak
        self.durationSeconds = durationSeconds
    }
}
