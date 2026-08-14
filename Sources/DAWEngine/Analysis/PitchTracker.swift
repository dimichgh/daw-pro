import Foundation
import OnnxRuntimeBindings

// SwiftF0 pitch detection — the ONNX Runtime seam (m23-ap-2a).
//
// ONE HOME (design §7.8, and the spike's implementation plan step 3): this file
// owns EVERYTHING about the SwiftF0 model — the weights resource, the ORT
// environment/session lifetime, tensor marshalling, and (from m23-ap-2b) the
// 48 k → 16 k decimation, framing/timestamp alignment, the confidence
// threshold, and the `fmin`/`fmax` voicing derivation. Do NOT create a separate
// "SwiftF0 wrapper" type beside it; m23-ap-2b grows the `PitchTracker` protocol
// and the policy INSIDE this file rather than around it.
//
// ⚠️⚠️ REAL-TIME BOUNDARY — design §7.6 IS ABSOLUTE AND THIS IS THE FILE IT IS
// ABOUT. Nothing here may ever be reachable from DAWEngine's render thread.
// An `ORTSession` allocates, takes locks, dispatches through Objective-C and
// spawns threads; session CONSTRUCTION additionally reads a 400 KB file off
// disk. Every one of those is a render-path violation on its own. This is
// OFFLINE analysis machinery, in the same class as `StretchRenderCache`: the
// render thread does not know the subsystem exists, which is the only way that
// invariant stays true. If anyone later proposes live pitch audition, the
// answer is a cached offline render plus a debounce — never inference on the
// audio thread.
//
// The one RT-ADJACENT control that IS taken here is `setIntraOpNumThreads(1)`:
// ORT's default intra-op pool sizes itself to the core count, and a pool that
// wide would contend with the audio thread for cores even though it never
// touches audio buffers. The spike (docs/research/2026-08-05-m23ap1-swiftf0-
// route-spike.md §1.6) calls this non-optional; it is set at :SESSION_OPTIONS
// below and is not a tuning knob.

/// A single SwiftF0 analysis frame.
///
/// The model emits one frame every `PitchTracker.hopLength` samples at
/// `PitchTracker.modelSampleRate`, i.e. 62.5 frames per second.
public struct PitchFrame: Sendable, Equatable {
    /// Frame centre, in seconds from the start of the analysed buffer.
    public let timeSeconds: Double
    /// Estimated fundamental, in Hz. Meaningful only where `confidence` is high.
    public let frequencyHz: Double
    /// The model's own voicing confidence, 0...1.
    public let confidence: Double

    public init(timeSeconds: Double, frequencyHz: Double, confidence: Double) {
        self.timeSeconds = timeSeconds
        self.frequencyHz = frequencyHz
        self.confidence = confidence
    }
}

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
        }
    }
}

/// SwiftF0 pitch detection, running in-process on ONNX Runtime.
///
/// **Offline only.** See the §7.6 note at the top of this file.
///
/// Construction is EXPENSIVE (it reads the weights and builds an ORT session),
/// so build one and reuse it for a batch of clips rather than per call. The
/// type is deliberately NOT `Sendable`: `ORTEnv`/`ORTSession` are Objective-C
/// objects with no documented thread-safety contract for concurrent `run`, so
/// an instance stays owned by whichever task created it.
public final class PitchTracker {
    /// The rate the model expects. SwiftF0 is trained at 16 kHz and this is a
    /// property of the weights, not a choice — resampling to reach it is
    /// m23-ap-2b's job, and `AudioEngine.projectSampleRate` stays the
    /// authoritative project rate (there is no second sample-rate home).
    public static let modelSampleRate: Double = 16_000

    /// Samples between analysis frames: 62.5 fps at `modelSampleRate`.
    public static let hopLength: Int = 256

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
    /// ⚠️ KNOWN GAP, m23-ap-2b's precondition: `scripts/bundle.sh:117` copies
    /// ONLY `daw-pro_DAWApp.bundle` into `Contents/Resources` and ignores every
    /// other `daw-pro_*.bundle`. `daw-pro_DAWEngine.bundle` is emitted by the
    /// build (verified) but is NOT copied, so candidate (1) below misses in the
    /// packaged .app today. Nothing in the app reads the weights yet, so this
    /// is latent — but it must be closed before any pitch feature ships, and
    /// changing the ship pipeline needs the user's word (m23-dp's rule).
    public static var weightsURL: URL? {
        let bundleName = "daw-pro_DAWEngine.bundle"
        let code = Bundle(for: PitchTracker.self)
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
    public init(weightsURL: URL? = PitchTracker.weightsURL) throws {
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

    /// Runs SwiftF0 over a mono buffer that is ALREADY at
    /// `PitchTracker.modelSampleRate`.
    ///
    /// This is the raw model call: no decimation, no voicing policy, no
    /// smoothing. Those are m23-ap-2b's and land in this same file.
    ///
    /// - Note: never call this from the render thread (§7.6).
    public func detect(samples: [Float]) throws -> [PitchFrame] {
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
