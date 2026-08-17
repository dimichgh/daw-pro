import AVFoundation
import Foundation
import OnnxRuntimeBindings

// Pitch detection — the `PitchTracker` seam and its SwiftF0 backend
// (m23-ap-2a landed the ONNX Runtime dependency; m23-ap-2b landed everything
// above the raw model call).
//
// ONE HOME (design §7.8, and the spike's implementation plan step 3): this file
// owns EVERYTHING about detection — the protocol, the weights resource, the ORT
// environment/session lifetime, tensor marshalling, the 48 k → 16 k conversion,
// framing/timestamp alignment, the confidence threshold, the level floor, and
// the voicing derivation. Do NOT create a separate "SwiftF0 wrapper" file
// beside it; grow this one.
//
// ⚠️⚠️ REAL-TIME BOUNDARY — design §7.6 IS ABSOLUTE AND THIS IS THE FILE IT IS
// ABOUT. Nothing here may ever be reachable from DAWEngine's render thread.
// An `ORTSession` allocates, takes locks, dispatches through Objective-C and
// spawns threads; session CONSTRUCTION additionally reads a 400 KB file off
// disk; `AVAudioConverter` allocates and is not RT-safe either. Every one of
// those is a render-path violation on its own. This is OFFLINE analysis
// machinery, in the same class as `StretchRenderCache`: the render thread does
// not know the subsystem exists, which is the only way that invariant stays
// true. If anyone later proposes live pitch audition, the answer is a cached
// offline render plus a debounce — never inference on the audio thread.
//
// The structural enforcement, so this is more than a comment:
//   * NOTHING in this file is referenced by any render-path type. `AudioEngine`,
//     `PlaybackGraph`, `InstrumentSourceNode`, the tap/metering path and the
//     effect processors do not name `PitchTracker`, `SwiftF0PitchTracker`,
//     `PitchObservation`, `PitchContour` or `PitchFrame`. The subsystem is
//     unreachable from the audio thread because nothing on it links here.
//   * `SwiftF0PitchTracker` is deliberately NOT `Sendable`, and neither is the
//     `PitchTracker` protocol. The INTENT is that Swift 6 strict concurrency
//     then rejects "capture the tracker into something the render thread
//     touches" at compile time. ⚠️ STATED AS REASONING, NOT AS A MEASUREMENT:
//     no test constructs such a call site, so this is an argument about a
//     hypothetical caller. The unreachability above is the measured leg.
//   * The API is synchronous and blocking by design. There is no callback, no
//     completion handler and no shared buffer, so there is no seam through
//     which a result could be delivered *to* the audio thread; a caller takes a
//     value copy on whatever background executor it ran on.
//
// The one RT-ADJACENT control that IS taken here is `setIntraOpNumThreads(1)`:
// ORT's default intra-op pool sizes itself to the core count, and a pool that
// wide would contend with the audio thread for cores even though it never
// touches audio buffers. The spike (docs/research/2026-08-05-m23ap1-swiftf0-
// route-spike.md §1.6) calls this non-optional; it is set at :SESSION_OPTIONS
// below and is not a tuning knob.

// MARK: - The seam

/// Why a frame carries no pitch.
///
/// A consumer that sees `PitchObservation.frequencyHz == nil` can tell WHICH
/// hole it is looking at without re-running the analysis — design §5.6.6 is
/// explicit that segmentation must "treat holes as signal … not as something to
/// fill", and the two holes below want different treatment: a `belowLevel` run
/// is a gap in the *performance*, a `belowConfidence` run is a gap in the
/// *detector*.
public enum PitchAbsence: String, Sendable, Equatable, CaseIterable {
    /// The model declined to commit: confidence under
    /// `PitchAnalysisOptions.confidenceThreshold`.
    case belowConfidence
    /// There is effectively no audio in this frame — see
    /// `PitchAnalysisOptions.silenceFloorDbfs`. ⚠️ This gate is NOT redundant
    /// with the confidence one; see that property's note.
    case belowLevel
    /// The model named a pitch outside `PitchAnalysisOptions.frequencyRange`.
    case outOfRange
}

/// One analysed frame.
///
/// ⚠️⚠️ THE CENTRAL CONTRACT OF THIS TYPE: **`frequencyHz` is `nil` when the
/// tracker declines to name a pitch. It is NEVER 0 and NEVER a negative
/// sentinel.** A sentinel here becomes a phantom note downstream — a note the
/// user never sang, at a frequency nothing produced — and this repo's
/// honest-absence rule (`DAWCore/FileProfile.swift:64` states the same rule for
/// silent-window peak level) exists because that failure is invisible until it
/// is audible. `Optional` is the enforcement: no consumer can use the value as
/// a number without first deciding what an absence means to it, and a JSON
/// encoder omits the key rather than inventing one.
public struct PitchObservation: Sendable, Equatable {
    /// Frame start, in seconds from the start of the analysed buffer, on the
    /// SOURCE timebase (resampling preserves duration, so this needs no
    /// correction — measured, see `PitchTrackerAccuracyTests`).
    public let timeSeconds: Double
    /// The estimated fundamental, or `nil` if this frame has no pitch.
    /// See the type note above: never 0, never negative.
    public let frequencyHz: Double?
    /// The model's own confidence, 0...1. Reported for EVERY frame including
    /// unvoiced ones, so a hole can be read rather than merely noticed.
    ///
    /// ⚠️ MEASURED, AND IT IS THE MOST IMPORTANT CAVEAT IN THIS FILE:
    /// confidence does NOT mean "there is signal here". A 220 Hz tone at
    /// amplitude 1e-7 (−140 dBFS) reads confidence 0.9999 on 60 of 62 frames.
    /// That is why voicing is a CONJUNCTION of confidence and level.
    public let confidence: Double
    /// RMS of this frame's audio in dBFS, or `nil` for exact digital silence
    /// (dB has no value there — the same honest absence as `FileProfile.peakDb`).
    public let levelDbfs: Double?
    /// `nil` exactly when `frequencyHz != nil`.
    public let absence: PitchAbsence?

    public var isVoiced: Bool { frequencyHz != nil }

    /// Fractional MIDI note number, or `nil` for an unvoiced frame. Provided
    /// here so callers do not each re-derive the conversion (and cannot do it
    /// on a sentinel).
    public var midiNote: Double? {
        guard let frequencyHz else { return nil }
        return 69.0 + 12.0 * log2(frequencyHz / 440.0)
    }

    public init(timeSeconds: Double,
                frequencyHz: Double?,
                confidence: Double,
                levelDbfs: Double?,
                absence: PitchAbsence?) {
        precondition((frequencyHz == nil) == (absence != nil),
                     "a frame is either voiced with a pitch or unvoiced with a reason")
        precondition(frequencyHz.map { $0 > 0 && $0.isFinite } ?? true,
                     "a voiced frame's pitch must be a real positive frequency")
        self.timeSeconds = timeSeconds
        self.frequencyHz = frequencyHz
        self.confidence = confidence
        self.levelDbfs = levelDbfs
        self.absence = absence
    }
}

/// The voicing policy applied on top of a backend's raw output.
///
/// The thresholds live HERE, in the caller's hands, rather than baked into a
/// backend, because design §5.6.6 is explicit that "the threshold is ours to
/// tune against the §5.5 fixtures" — and because fixture thresholds and product
/// thresholds are different numbers (a pure synthetic sine sits at confidence
/// ~0.48 where a real vocal sits at 0.9+; asserting the product threshold on a
/// synthetic fixture is what broke ap-2a's first draft).
public struct PitchAnalysisOptions: Sendable, Equatable {
    /// SwiftF0's own documented default, and the design's (§5.6.6). It produces
    /// DELIBERATE GAPS where the model declines; upstream's author measured
    /// that post-processing to close them made accuracy worse. Do not close
    /// them here.
    public static let defaultConfidenceThreshold: Double = 0.9

    /// ⚠️⚠️ UNTUNED AGAINST REAL VOCAL MATERIAL — STATED, NOT IMPLIED.
    ///
    /// What this floor provably does is kill the pathology measured in
    /// `PitchTrackerAccuracyTests`: SwiftF0 is LEVEL-BLIND, and a buffer at
    /// −140 dBFS (or the numerically-zero residue left by resampling an
    /// out-of-band tone) comes back as a full contour at confidence ~1.0.
    /// Anything from about −90 to −60 dBFS kills that class, and −75 was picked
    /// inside that window.
    ///
    /// What it has NOT been tuned against is a real recording: typical home
    /// room tone sits around −50 to −60 dBFS RMS, which this floor does NOT
    /// reject. Tuning it needs real dry vocal material (§5.5's second fixture
    /// family), which nobody has run through this path yet. Treat the default
    /// as "sufficient for the measured pathology", not as "the right number".
    ///
    /// ⚠️⚠️ AND THE SUITE DOES NOT PIN THIS VALUE — SAID PLAINLY SO NOBODY
    /// READS THE GREEN TESTS AS AGREEMENT WITH −75. The accuracy fixtures sit
    /// at about −11.8 dBFS and the pathological ones at −145 to −164 dBFS, so
    /// **any floor from roughly −120 to −25 produces an identical test run.**
    /// What the tests prove is that the gate EXISTS and is load-bearing
    /// (removing it reddens five of them); they prove nothing about where it
    /// belongs.
    public static let defaultSilenceFloorDbfs: Double = -75

    /// A frame under this confidence is `.belowConfidence`.
    public var confidenceThreshold: Double
    /// A frame whose RMS is under this level is `.belowLevel`.
    public var silenceFloorDbfs: Double
    /// Optional narrowing of the accepted range. `nil` means "whatever the
    /// backend can detect" (`PitchTracker.detectableRange`).
    public var frequencyRange: ClosedRange<Double>?

    public init(confidenceThreshold: Double = PitchAnalysisOptions.defaultConfidenceThreshold,
                silenceFloorDbfs: Double = PitchAnalysisOptions.defaultSilenceFloorDbfs,
                frequencyRange: ClosedRange<Double>? = nil) {
        self.confidenceThreshold = confidenceThreshold
        self.silenceFloorDbfs = silenceFloorDbfs
        self.frequencyRange = frequencyRange
    }
}

/// A whole analysed buffer: one observation per frame, on a uniform grid.
///
/// Unvoiced frames are KEPT rather than dropped. Dropping them would make "the
/// singer stopped here" indistinguishable from "we did not analyse here", and
/// would destroy the uniform time grid segmentation reads. The absence is in
/// the VALUE (`frequencyHz == nil`), not in the frame's existence.
public struct PitchContour: Sendable, Equatable {
    public let observations: [PitchObservation]
    /// Frames per second — `1 / hop`. 62.5 for SwiftF0.
    public let frameRate: Double
    /// The rate the backend actually ran at (16 kHz for SwiftF0).
    public let analysisSampleRate: Double
    /// The rate the caller's samples were at, before any conversion.
    public let sourceSampleRate: Double
    /// The policy that produced the absences. A `nil` pitch is only
    /// interpretable together with the thresholds that made it one.
    public let options: PitchAnalysisOptions

    public init(observations: [PitchObservation],
                frameRate: Double,
                analysisSampleRate: Double,
                sourceSampleRate: Double,
                options: PitchAnalysisOptions) {
        self.observations = observations
        self.frameRate = frameRate
        self.analysisSampleRate = analysisSampleRate
        self.sourceSampleRate = sourceSampleRate
        self.options = options
    }

    public var voiced: [PitchObservation] { observations.filter(\.isVoiced) }

    public var voicedFraction: Double {
        observations.isEmpty ? 0 : Double(voiced.count) / Double(observations.count)
    }
}

/// The detection seam.
///
/// SwiftF0 is ONE implementation. The protocol exists so the model layer can be
/// replaced — design §5.6.6's fallback ladder (octave sanity check → in-house
/// pYIN → WORLD Harvest) is a ladder of *backends*, and §7.6 says "the model
/// layer is behind a protocol either way". It is also what lets the accuracy
/// gate be run against a deliberately-wrong tracker as a positive control,
/// which is the only way to know the gate can fail at all.
///
/// ⚠️⚠️ OFFLINE ONLY — §7.6. Deliberately **not** `Sendable` and deliberately
/// synchronous: see the header note. A conforming type owns an expensive
/// session and stays on whichever task built it.
public protocol PitchTracker {
    /// The rate the backend analyses at, after any conversion it does itself.
    var analysisSampleRate: Double { get }
    /// Frames per second in the returned contour.
    var frameRate: Double { get }
    /// The frequencies this backend can name at all. A backend never returns a
    /// voiced frame outside this range.
    var detectableRange: ClosedRange<Double> { get }

    /// Analyse a mono buffer at `sampleRate`.
    ///
    /// - Note: NEVER call this from the render thread (§7.6). It allocates,
    ///   takes locks, and blocks for the length of an inference run.
    func analyze(samples: [Float],
                 sampleRate: Double,
                 options: PitchAnalysisOptions) throws -> PitchContour
}

public extension PitchTracker {
    /// Convenience overload — a protocol requirement cannot carry a default
    /// argument, so the default policy lives here.
    func analyze(samples: [Float], sampleRate: Double) throws -> PitchContour {
        try analyze(samples: samples, sampleRate: sampleRate, options: PitchAnalysisOptions())
    }
}

// MARK: - Errors

public enum PitchTrackerError: Error, CustomStringConvertible {
    /// The vendored `swiftf0.onnx` resource is missing from the module bundle.
    case weightsMissing
    /// The input buffer was empty, or shorter than one analysis frame.
    case inputTooShort(sampleCount: Int)
    /// ONNX Runtime reported a failure. The underlying `NSError` is carried
    /// verbatim so a load failure is distinguishable from a run failure.
    case runtime(underlying: Error)
    /// The model returned an output this code does not know how to read —
    /// a shape or element-type mismatch, i.e. the weights are not the weights
    /// this file was written against.
    case unexpectedOutput(String)
    /// The caller asked for a sample rate that cannot be converted from.
    case unsupportedSampleRate(Double)
    /// `AVAudioConverter` failed. Carried rather than swallowed so a conversion
    /// failure never presents as "no pitch found".
    case resampleFailed(String)

    public var description: String {
        switch self {
        case .weightsMissing:
            return "SwiftF0 weights (swiftf0.onnx) are missing from the DAWEngine resource bundle"
        case let .inputTooShort(sampleCount):
            return "pitch detection needs at least one analysis frame; got \(sampleCount) samples"
        case let .runtime(underlying):
            return "ONNX Runtime error: \(underlying)"
        case let .unexpectedOutput(detail):
            return "unexpected SwiftF0 model output: \(detail)"
        case let .unsupportedSampleRate(rate):
            return "unsupported source sample rate for pitch detection: \(rate) Hz"
        case let .resampleFailed(detail):
            return "sample-rate conversion for pitch detection failed: \(detail)"
        }
    }
}

// MARK: - Conversion plumbing

/// Hands a single input buffer to `AVAudioConverter` once, then reports
/// end-of-stream.
///
/// ⚠️ THE ONE `@unchecked Sendable` IN THIS SUBSYSTEM, AND IT IS LOAD-BEARING
/// RATHER THAN A SHORTCUT — recorded here so a reviewer can disagree with the
/// reasoning rather than with the annotation.
///
/// AVFAudio types `AVAudioConverterInputBlock` as `@Sendable`, so a closure
/// that captures the input `AVAudioPCMBuffer` (non-Sendable) and flips a local
/// `var` draws three Swift 6 warnings. The concurrency those warnings describe
/// does not exist: `AVAudioConverter.convert(to:error:withInputFrom:)` invokes
/// the block SYNCHRONOUSLY, on the calling thread, and returns before the
/// caller regains control. This box makes that claim once, in a named place,
/// instead of scattering `nonisolated(unsafe)` over two locals.
///
/// The safety argument is the confinement, not the annotation: an instance is
/// created inside `conditioned(_:from:)`, is handed to exactly one converter,
/// and does not outlive that call. Nothing else can obtain a reference.
///
/// ⚠️ This is ALSO why none of it may reach the render thread (§7.6): the
/// buffer allocation, the converter and this block are all heap traffic.
private final class SingleShotConverterInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioPCMBuffer? {
        if supplied {
            status.pointee = .endOfStream
            return nil
        }
        supplied = true
        status.pointee = .haveData
        return buffer
    }
}

// MARK: - The raw model frame

/// One raw SwiftF0 output frame, straight off the model.
///
/// ⚠️ INTERNAL ON PURPOSE. `frequencyHz` here is non-optional because the model
/// always emits an argmax — including on digital silence, where it reads
/// 894–1946 Hz at confidence 0.26–0.38 (measured). Exposing that publicly is
/// exactly how a phantom note is born, so the public surface is
/// `PitchObservation`, whose pitch is optional, and this type never leaves the
/// module. `PitchTrackerInferenceTests` reaches it through `@testable`.
struct PitchFrame: Sendable, Equatable {
    /// Frame start, in seconds from the start of the analysed buffer.
    let timeSeconds: Double
    /// The model's argmax fundamental, in Hz. MEANINGLESS where the model is
    /// not confident — that is what the policy layer is for.
    let frequencyHz: Double
    /// The model's own voicing confidence, 0...1.
    let confidence: Double

    init(timeSeconds: Double, frequencyHz: Double, confidence: Double) {
        self.timeSeconds = timeSeconds
        self.frequencyHz = frequencyHz
        self.confidence = confidence
    }
}

// MARK: - The SwiftF0 backend

/// SwiftF0 pitch detection, running in-process on ONNX Runtime.
///
/// **Offline only.** See the §7.6 note at the top of this file.
///
/// Construction is EXPENSIVE (it reads the weights and builds an ORT session),
/// so build one and reuse it for a batch of clips rather than per call. The
/// type is deliberately NOT `Sendable`: `ORTEnv`/`ORTSession` are Objective-C
/// objects with no documented thread-safety contract for concurrent `run`, so
/// an instance stays owned by whichever task created it.
public final class SwiftF0PitchTracker: PitchTracker {
    /// The rate the model expects. SwiftF0 is trained at 16 kHz and this is a
    /// property of the weights, not a choice.
    public static let modelSampleRate: Double = 16_000

    /// Samples between analysis frames: 62.5 fps at `modelSampleRate`.
    public static let hopLength: Int = 256

    /// `MODEL_FMIN`/`MODEL_FMAX` from upstream `swift_f0/core.py` (G1–C7).
    /// Wider than the sung range in both directions.
    public static let modelFrequencyRange: ClosedRange<Double> = 46.875...2093.75

    public var analysisSampleRate: Double { Self.modelSampleRate }
    public var frameRate: Double { Self.modelSampleRate / Double(Self.hopLength) }
    public var detectableRange: ClosedRange<Double> { Self.modelFrequencyRange }

    /// Where the vendored weights live inside the DAWEngine resource bundle.
    ///
    /// Public so callers (and the offline-inference test) exercise the same
    /// resolution the app will, rather than reaching past it with `@testable`.
    /// Returns `nil` if the resource did not make it into the bundle — which is
    /// a packaging failure, not a runtime condition, and is surfaced as
    /// `PitchTrackerError.weightsMissing`.
    ///
    /// ⚠️⚠️ DELIBERATELY NOT `Bundle.module`, and this is not a style choice.
    /// SwiftPM's generated accessor is `Bundle(path: main/daw-pro_DAWEngine.bundle)
    /// ?? Bundle(path: <absolute .build path>)` and then **`Swift.fatalError`** —
    /// read first-hand from the generated `resource_bundle_accessor.swift`, not
    /// assumed. Touching `Bundle.module` at all arms that trap, so a shipped app
    /// missing this resource would CRASH rather than report a missing model.
    /// Worse, its first candidate is the .app's ROOT (`Bundle.main.bundleURL`),
    /// and `scripts/bundle.sh` explicitly refuses to put resource bundles there
    /// because "a stray top-level item would break the codesign seal". So in a
    /// packaged build the generated accessor cannot succeed by design.
    ///
    /// This is `OnboardingHeroArt.load`'s precedent (`OnboardingTourView.swift:57`),
    /// which avoids `Bundle.module` for exactly the same reason: search the
    /// real candidate locations and return nil.
    ///
    /// ⚠️ The anchor is `Bundle(for:)`, NOT `Bundle.main`, and that is a
    /// MEASURED correction rather than a preference. Under this repo's
    /// `./scripts/test.sh` (which passes `--disable-xctest`), the running
    /// process' `Bundle.main` is
    /// `…/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper`
    /// — SwiftPM's own helper binary, inside Xcode. A `Bundle.main`-anchored
    /// search therefore looks in the TOOLCHAIN and finds nothing, which is
    /// exactly what happened when this was first written that way.
    /// `Bundle(for:)` anchors to the image this code was linked into, which is
    /// the .xctest under test and the .app in production.
    ///
    /// ⚠️ KNOWN GAP, tracked as m23-ap-2a-1: `scripts/bundle.sh:117` copies
    /// ONLY `daw-pro_DAWApp.bundle` into `Contents/Resources` and ignores every
    /// other `daw-pro_*.bundle`. `daw-pro_DAWEngine.bundle` is emitted by the
    /// build (verified) but is NOT copied, so candidate (1) below misses in the
    /// packaged .app today. Nothing in the app reads the weights yet, so this
    /// is latent — but it must be closed before any pitch feature ships, and
    /// changing the ship pipeline needs the user's word (m23-dp's rule).
    public static var weightsURL: URL? {
        let bundleName = "daw-pro_DAWEngine.bundle"
        let code = Bundle(for: SwiftF0PitchTracker.self)
        var candidates: [URL?] = [
            // (1) Packaged .app: Contents/Resources/daw-pro_DAWEngine.bundle,
            //     where scripts/bundle.sh puts resource bundles. See the gap
            //     note above — it does not put THIS one there yet.
            code.resourceURL?.appendingPathComponent(bundleName),
            // (2) Bare SwiftPM executable (`swift run DAWApp`): the bundle is
            //     emitted beside the binary.
            code.bundleURL.appendingPathComponent(bundleName),
        ]
        // (3) SwiftPM test runner ONLY. `swift test` produces
        //     `.build/<triple>/debug/daw-proPackageTests.xctest/Contents/MacOS/…`
        //     with the resource bundle as the .xctest's SIBLING, not inside it
        //     — measured, both the miss at Contents/Resources and the hit here.
        //     Gated on the `.xctest` extension deliberately: an unconditional
        //     "look one directory up" would have a shipped app searching
        //     alongside itself in /Applications, which is not a place we should
        //     be willing to load code-adjacent resources from.
        if code.bundleURL.pathExtension == "xctest" {
            candidates.append(code.bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent(bundleName))
        }
        for url in candidates.compactMap({ $0 }) {
            if let bundle = Bundle(url: url),
               let resource = bundle.url(forResource: "swiftf0", withExtension: "onnx") {
                return resource
            }
        }
        return nil
    }

    private let env: ORTEnv
    private let session: ORTSession

    /// Builds the ORT environment and session against the vendored weights.
    ///
    /// - Parameter weightsURL: override for the model file; defaults to the
    ///   vendored resource. Present so the negative control (a path that does
    ///   not exist MUST throw) can be written, which is what distinguishes a
    ///   real model load from a silent no-op.
    public init(weightsURL: URL? = SwiftF0PitchTracker.weightsURL) throws {
        guard let weightsURL else { throw PitchTrackerError.weightsMissing }
        do {
            // `.warning` — ORT logs to stderr at `.info` and below, and this
            // subsystem must stay quiet in a DAW's console.
            env = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
            let options = try ORTSessionOptions()
            // :SESSION_OPTIONS — see the RT-adjacency note at the top.
            try options.setIntraOpNumThreads(1)
            try options.setLogSeverityLevel(ORTLoggingLevel.warning)
            session = try ORTSession(env: env,
                                     modelPath: weightsURL.path,
                                     sessionOptions: options)
        } catch {
            throw PitchTrackerError.runtime(underlying: error)
        }
    }

    // MARK: The public seam

    /// Analyse a mono buffer at any sample rate.
    ///
    /// The chain is: convert to 16 kHz if needed → run the model → apply the
    /// voicing policy. Timestamps come back on the SOURCE timebase, which needs
    /// no correction because the conversion preserves duration and introduces
    /// no measurable priming offset (measured: an onset at 0.5 s lands on the
    /// same frame index with and without conversion).
    ///
    /// - Note: NEVER call this from the render thread (§7.6).
    public func analyze(samples: [Float],
                        sampleRate: Double,
                        options: PitchAnalysisOptions) throws -> PitchContour {
        guard sampleRate.isFinite, sampleRate >= 4_000, sampleRate <= 768_000 else {
            throw PitchTrackerError.unsupportedSampleRate(sampleRate)
        }
        let analysed = try Self.conditioned(samples, from: sampleRate)
        let frames = try detect(samples: analysed)
        let range = options.frequencyRange ?? detectableRange
        let observations = frames.enumerated().map { index, frame -> PitchObservation in
            let level = Self.frameLevelDbfs(analysed, frameIndex: index)
            let absence = Self.absenceReason(frame: frame,
                                             levelDbfs: level,
                                             range: range,
                                             options: options)
            return PitchObservation(timeSeconds: frame.timeSeconds,
                                    frequencyHz: absence == nil ? frame.frequencyHz : nil,
                                    confidence: frame.confidence,
                                    levelDbfs: level,
                                    absence: absence)
        }
        return PitchContour(observations: observations,
                            frameRate: frameRate,
                            analysisSampleRate: Self.modelSampleRate,
                            sourceSampleRate: sampleRate,
                            options: options)
    }

    /// THE VOICING POLICY, in one place.
    ///
    /// It is a CONJUNCTION and the level leg is not decoration: SwiftF0 is
    /// level-blind (a −140 dBFS buffer reads confidence 0.9999), so confidence
    /// alone would turn room tone, a fade tail, or the numerically-zero residue
    /// of an out-of-band tone into a full contour of confident phantom notes.
    /// Measured in `PitchTrackerAccuracyTests`; the level leg exists because of
    /// that measurement, not on principle.
    ///
    /// Order matters only for which reason is reported, not for the outcome.
    /// Level is checked FIRST because "there was nothing here" is the more
    /// informative answer when both apply.
    private static func absenceReason(frame: PitchFrame,
                                      levelDbfs: Double?,
                                      range: ClosedRange<Double>,
                                      options: PitchAnalysisOptions) -> PitchAbsence? {
        guard let levelDbfs, levelDbfs >= options.silenceFloorDbfs else { return .belowLevel }
        guard frame.confidence >= options.confidenceThreshold else { return .belowConfidence }
        guard frame.frequencyHz.isFinite,
              frame.frequencyHz > 0,
              range.contains(frame.frequencyHz) else { return .outOfRange }
        return nil
    }

    /// RMS of the `hopLength` samples this frame index starts at, in dBFS.
    /// `nil` for exact digital silence — dB has no value there, and this repo
    /// reports that as an absence rather than a fabricated floor.
    ///
    /// ⚠️ This window is OURS, not the model's: SwiftF0's internal analysis
    /// window is longer than one hop, so at a note edge the level gate and the
    /// model's confidence can disagree by a frame. That is accepted, and no
    /// test asserts frame-exact agreement between them.
    private static func frameLevelDbfs(_ samples: [Float], frameIndex: Int) -> Double? {
        let start = frameIndex * hopLength
        guard start < samples.count else { return nil }
        let end = min(start + hopLength, samples.count)
        var sum = 0.0
        for i in start..<end {
            let v = Double(samples[i])
            // Denormal guard: a denormal squared underflows to zero anyway, but
            // this keeps a NaN or Inf in the input from poisoning the whole
            // frame's level (and therefore its voicing decision).
            guard v.isFinite else { return nil }
            sum += v * v
        }
        let rms = (sum / Double(end - start)).squareRoot()
        guard rms > 0, rms.isFinite else { return nil }
        return 20.0 * log10(rms)
    }

    // MARK: Input conditioning

    /// 48 k (or anything else) → 16 k.
    ///
    /// ⚠️ NO HAND-ROLLED RESAMPLER. This repo already deleted one of those
    /// (`WhisperModelInstaller.swift:296`, the m23-n2a lesson: "we once wrote a
    /// 16 kHz resampler WhisperKit already had, and deleted it"). The system
    /// converter is the resampler; we own the framing and the policy, not the
    /// filter design.
    ///
    /// `AVSampleRateConverterAlgorithm_Mastering` at `AVAudioQuality.max` was
    /// MEASURED rather than assumed: out-of-band rejection is −150.8 dB at
    /// 8.5 kHz rising to −230 dB at 16 kHz, a 220 Hz tone reads the SAME
    /// 220.061 Hz through the converter as natively at 16 kHz, and a 16 k → 16 k
    /// pass is bit-exact.
    ///
    /// An equal-rate call skips the converter entirely — not an optimisation,
    /// a guarantee: analysing a 16 kHz buffer touches the exact samples handed
    /// in.
    private static func conditioned(_ samples: [Float], from rate: Double) throws -> [Float] {
        guard rate != modelSampleRate else { return samples }
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: rate,
                                           channels: 1,
                                           interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: modelSampleRate,
                                            channels: 1,
                                            interleaved: false) else {
            throw PitchTrackerError.unsupportedSampleRate(rate)
        }
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw PitchTrackerError.resampleFailed("AVAudioConverter(\(rate) -> \(modelSampleRate)) is nil")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering

        guard !samples.isEmpty,
              let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat,
                                              frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw PitchTrackerError.inputTooShort(sampleCount: samples.count)
        }
        inBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            inBuffer.floatChannelData!.pointee.update(from: src.baseAddress!, count: samples.count)
        }

        let expected = Int((Double(samples.count) * modelSampleRate / rate).rounded(.up))
        var out = [Float]()
        out.reserveCapacity(expected + hopLength)

        let chunkFrames: AVAudioFrameCount = 16_384
        guard let chunk = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: chunkFrames) else {
            throw PitchTrackerError.resampleFailed("could not allocate a conversion buffer")
        }
        let source = SingleShotConverterInput(buffer: inBuffer)
        // Bounded so a converter that reports `.haveData` forever cannot hang a
        // build. The bound is generous (every iteration should deliver a full
        // chunk) and being hit is a failure, not a truncation.
        let maxIterations = expected / Int(chunkFrames) + 16
        for _ in 0..<maxIterations {
            chunk.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: chunk, error: &error) { _, outStatus in
                source.next(outStatus)
            }
            if status == .error {
                throw PitchTrackerError.resampleFailed(error?.localizedDescription ?? "unknown")
            }
            if chunk.frameLength > 0, let data = chunk.floatChannelData?.pointee {
                out.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(chunk.frameLength)))
            }
            // `.endOfStream` is the clean finish; `.inputRanOut` means the
            // block returned nil before filling the chunk, which for a
            // single-shot input is also "done". Either way an empty chunk ends
            // it, so a status this enum gains later cannot spin.
            if status != .haveData { break }
            if chunk.frameLength == 0 { break }
        }
        return out
    }

    // MARK: The raw model call

    /// Runs SwiftF0 over a mono buffer that is ALREADY at
    /// `SwiftF0PitchTracker.modelSampleRate`.
    ///
    /// INTERNAL: this is the raw model call — no conversion, no voicing policy,
    /// no smoothing — and its non-optional `frequencyHz` is exactly the sentinel
    /// hazard `analyze` exists to remove. Callers outside this module get
    /// `analyze`.
    ///
    /// - Note: never call this from the render thread (§7.6).
    func detect(samples: [Float]) throws -> [PitchFrame] {
        guard samples.count >= Self.hopLength else {
            throw PitchTrackerError.inputTooShort(sampleCount: samples.count)
        }

        // The ObjC API takes an `NSMutableData` it does NOT copy, so this must
        // outlive the `run` call below — hence a named local, not an inline
        // temporary.
        let inputData = samples.withUnsafeBufferPointer { buffer in
            NSMutableData(bytes: buffer.baseAddress, length: buffer.count * MemoryLayout<Float>.size)
        }

        do {
            let input = try ORTValue(
                tensorData: inputData,
                elementType: ORTTensorElementDataType.float,
                shape: [NSNumber(value: 1), NSNumber(value: samples.count)])

            let outputs = try session.run(
                withInputs: ["input_audio": input],
                outputNames: ["pitch_hz", "confidence"],
                runOptions: nil)

            guard let pitchValue = outputs["pitch_hz"],
                  let confidenceValue = outputs["confidence"] else {
                throw PitchTrackerError.unexpectedOutput(
                    "expected pitch_hz and confidence, got \(outputs.keys.sorted())")
            }

            let pitch = try Self.floats(from: pitchValue, named: "pitch_hz")
            let confidence = try Self.floats(from: confidenceValue, named: "confidence")
            guard pitch.count == confidence.count else {
                throw PitchTrackerError.unexpectedOutput(
                    "pitch_hz has \(pitch.count) values, confidence has \(confidence.count)")
            }

            let frameSeconds = Double(Self.hopLength) / Self.modelSampleRate
            return (0..<pitch.count).map { index in
                PitchFrame(timeSeconds: Double(index) * frameSeconds,
                           frequencyHz: Double(pitch[index]),
                           confidence: Double(confidence[index]))
            }
        } catch let error as PitchTrackerError {
            throw error
        } catch {
            throw PitchTrackerError.runtime(underlying: error)
        }
    }

    /// Reads a float32 tensor out of an `ORTValue`, checking the element type
    /// rather than trusting it — a mismatched type would otherwise be
    /// reinterpreted as garbage floats rather than reported.
    private static func floats(from value: ORTValue, named name: String) throws -> [Float] {
        let info = try value.tensorTypeAndShapeInfo()
        guard info.elementType == ORTTensorElementDataType.float else {
            throw PitchTrackerError.unexpectedOutput(
                "\(name) is element type \(info.elementType.rawValue), expected float")
        }
        let data = try value.tensorData() as Data
        let count = data.count / MemoryLayout<Float>.size
        return data.withUnsafeBytes { raw in
            Array(UnsafeBufferPointer(start: raw.bindMemory(to: Float.self).baseAddress, count: count))
        }
    }
}
