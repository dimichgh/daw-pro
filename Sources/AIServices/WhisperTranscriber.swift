import Foundation
import DAWCore
import WhisperKit

// MARK: - Request

/// One transcription job: which audio, which slice of it, and where that slice
/// sits on the project timeline.
///
/// `startSeconds`/`endSeconds` are positions **in the source file**;
/// `anchorBeat` is the **project** beat that `startSeconds` lands on. They are
/// two different offsets on two different axes and must not be conflated — see
/// `TranscriptionBeatMapper`.
public struct WhisperTranscriptionRequest: Sendable, Equatable {
    /// The audio file to read. Any sample rate and channel count: the 16 kHz
    /// mono conversion is WhisperKit's own (`AudioProcessor.loadAudio`), not
    /// ours, so there is no second resampler in this codebase.
    public var audioURL: URL
    /// Where to start reading, in seconds from the start of the file.
    /// `nil` (the default) reads from the beginning.
    public var startSeconds: Double?
    /// Where to stop reading, in seconds from the start of the file.
    /// `nil` reads to the end. Clamped to the file length upstream.
    public var endSeconds: Double?
    /// The project beat that `startSeconds` sits on — for a clip, its start
    /// beat. All returned beats are measured forward from here.
    public var anchorBeat: Double
    /// The project tempo map. Beat placement goes through this and only this.
    public var tempoMap: TempoMap
    /// Force a spoken language (`"en"`), or `nil` to let the recogniser decide
    /// exactly as it does by default.
    public var language: String?

    public init(
        audioURL: URL,
        startSeconds: Double? = nil,
        endSeconds: Double? = nil,
        anchorBeat: Double = 0,
        tempoMap: TempoMap,
        language: String? = nil
    ) {
        self.audioURL = audioURL
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.anchorBeat = anchorBeat
        self.tempoMap = tempoMap
        self.language = language
    }
}

// MARK: - Errors

/// Failures that are about **the request**, never about the model.
///
/// There is deliberately no "model missing" case here: model resolution throws
/// `WhisperModelError` (the catalog's teaching errors) and this actor lets it
/// through untouched, so there is exactly one vocabulary for "the weights
/// aren't installed" and it already names the directory it inspected.
public enum WhisperTranscriptionError: Error, LocalizedError, Equatable {
    /// The requested slice is not a slice: negative start, or an end that is
    /// not after the start.
    case invalidRange(startSeconds: Double, endSeconds: Double?)
    /// The slice resolved to no audio at all — usually a start past the end of
    /// the file, which reads as silence-of-length-zero rather than as an error
    /// further down.
    case emptyAudioRange(path: String, startSeconds: Double, endSeconds: Double?)

    public var errorDescription: String? {
        switch self {
        case .invalidRange(let start, let end):
            let endText = end.map { "\($0)s" } ?? "end of file"
            return "Cannot transcribe \(start)s → \(endText): the start must be zero or later "
                + "and the end must come after it."
        case .emptyAudioRange(let path, let start, let end):
            let endText = end.map { "\($0)s" } ?? "end of file"
            return "No audio between \(start)s and \(endText) in \(path). "
                + "Check the range against the file's length — a start past the end reads as nothing."
        }
    }
}

// MARK: - The transcriber

/// On-device speech-to-text that answers in **musical time**.
///
/// Give it an audio file (optionally a slice of one) and the project tempo map;
/// get back the text with every segment and word placed on the project's beats.
/// Nothing leaves the machine: the model is loaded from local weights with
/// `download: false`, so a missing model is an error rather than a download.
///
/// ## Why an actor, and why one instance
///
/// Loading the model compiles its CoreML components for the Neural Engine the
/// first time it happens on a given machine. Measured 2026-07-27 on identical
/// runs: **93.7 s cold, 1.153 s warm** — the OS caches the compilation, but the
/// `WhisperKit` object still has to be built and its weights mapped in. So the
/// instance is created **once, lazily** and kept: constructing one per call
/// would pay that cost every time. Hold one `WhisperTranscriber` for the
/// process; `prewarm()` exists so the first *user-visible* call can be a warm
/// one.
///
/// ## Why an explicit lock inside the actor
///
/// Actor isolation alone is not enough here. `transcribe` suspends at its
/// `await`, and a second call arriving during that suspension would re-enter and
/// drive the *same* `WhisperKit` instance concurrently — it mutates per-run
/// state (timings, progress, decoder caches) while running. The
/// `acquire()`/`release()` pair below serialises whole jobs, so one instance is
/// only ever inside one job. It also collapses concurrent first calls into a
/// single model load instead of two.
///
/// ## Not yet reachable from outside the process
///
/// TODO (m23-n2b): expose this as the control command **`clip.transcribe`** in
/// `Sources/DAWControl/Commands.swift` and as the MCP tool **`clip_transcribe`**
/// in `mcp-server/src/server.ts`. Deliberately absent from n2a, which is the
/// headless engine only. n2b owns one real decision the ~90 s cold start forces:
/// pollable job (the `vc.trainVoice` precedent) versus blocking call plus a
/// prewarm at app start — `vc.convertVocals` is blocking, so whichever way it
/// goes needs writing down. Additive only; never rename a live command.
public actor WhisperTranscriber {
    /// The one loaded model, and which model it is.
    private struct LoadedKit {
        let descriptor: WhisperModelDescriptor
        let box: KitBox
    }

    /// Carries a `WhisperKit` across the isolation boundary.
    ///
    /// `@unchecked Sendable` JUSTIFICATION (required by the project's Swift 6
    /// rule): `WhisperKit` is an `open class` in the pinned 0.18.0 checkout,
    /// which builds in Swift 5 language mode and declares no `Sendable`
    /// conformance — the compiler cannot prove anything about it, and we may not
    /// edit a pinned dependency. Safety here is *structural*, not assumed:
    ///
    /// * the box is stored only in `WhisperTranscriber`'s actor state and is
    ///   never handed out to callers (nothing public returns or accepts one);
    /// * the only place it is unboxed is `runTranscription(_:samples:options:)`,
    ///   which is reached solely from `transcribe(_:)`;
    /// * every such call sits inside the actor's `acquire()`/`release()` bracket,
    ///   so no two tasks can be inside a `WhisperKit` call on the same instance
    ///   at the same time.
    ///
    /// In other words the concurrency the compiler cannot see is prevented by
    /// the lock, not merely believed to be absent.
    private struct KitBox: @unchecked Sendable {
        let kit: WhisperKit
    }

    /// Injected catalog. `nil` means "work it out at load time" — deliberately
    /// NOT at init time, so constructing a transcriber never touches the disk
    /// and a test can point a real catalog at an empty directory.
    private let catalog: WhisperModelCatalog?
    /// Model directory name to insist on, or `nil` for the first installed one.
    private let variantName: String?

    private var loaded: LoadedKit?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var activeJobs = 0

    /// The most jobs that have ever been inside the recogniser at the same
    /// time. `KitBox`'s justification claims this can never exceed 1; this
    /// counter makes that claim **observable** rather than merely asserted, and
    /// the suite pins it under deliberate contention.
    ///
    /// It is here because a weaker test was measured to be blind: on
    /// 2026-07-27, three concurrent transcriptions of the fixture still returned
    /// identical, correct text with the lock removed entirely. Agreement of
    /// results therefore cannot see the invariant — this can (it reads 3 with
    /// the lock disabled, 1 with it in place).
    public private(set) var peakConcurrentJobs = 0

    /// - Parameters:
    ///   - catalog: Where to look for weights. Defaults to
    ///     `WhisperModelCatalog.resolved()`, resolved lazily on first load.
    ///   - variantName: A specific model directory name, or `nil` for the first
    ///     installed one (`WhisperModelCatalog.resolveModel(named:)`).
    public init(catalog: WhisperModelCatalog? = nil, variantName: String? = nil) {
        self.catalog = catalog
        self.variantName = variantName
    }

    /// Directory name of the model currently held in memory, or `nil` when
    /// nothing has been loaded yet.
    public var loadedModelVariantDirectoryName: String? {
        loaded?.descriptor.variantDirectoryName
    }

    /// Load the model now, so the first real transcription is a warm one.
    /// Throws the catalog's `WhisperModelError` when there is nothing to load.
    public func prewarm() async throws {
        await acquire()
        defer { release() }
        _ = try await loadedKit()
    }

    /// Drop the loaded model. The next call reloads it (and pays the load cost
    /// again — the compile cache survives, the mapping does not).
    public func unload() {
        loaded = nil
    }

    /// Transcribe a file, or a slice of one, onto the project timeline.
    ///
    /// - Throws: `WhisperModelError` when no usable model is installed (the
    ///   catalog's teaching error, unchanged); `WhisperTranscriptionError` when
    ///   the requested range is unusable; WhisperKit's own errors when decoding
    ///   fails.
    public func transcribe(_ request: WhisperTranscriptionRequest) async throws -> Transcription {
        // Validate BEFORE queueing: a nonsense range should not wait behind a
        // model load, and a negative frame count would trap inside AVFoundation.
        let start = request.startSeconds ?? 0
        guard start >= 0, start.isFinite else {
            throw WhisperTranscriptionError.invalidRange(
                startSeconds: start, endSeconds: request.endSeconds)
        }
        if let end = request.endSeconds {
            guard end.isFinite, end > start else {
                throw WhisperTranscriptionError.invalidRange(
                    startSeconds: start, endSeconds: end)
            }
        }

        await acquire()
        defer { release() }

        // The model FIRST, so "no weights installed" reports as itself rather
        // than as whatever the audio happens to be.
        let kit = try await loadedKit()

        // The range read and the 16 kHz/mono conversion are BOTH WhisperKit's:
        // `loadAudioAsFloatArray` seeks to `startTime` and resamples anything
        // that is not already 16 kHz mono. We do not own a second resampler.
        // `channelMode` is left at its default so this matches, byte for byte,
        // the path `WhisperKit.transcribe(audioPath:)` takes.
        let samples = try AudioProcessor.loadAudioAsFloatArray(
            fromPath: request.audioURL.path,
            startTime: start,
            endTime: request.endSeconds
        )
        guard !samples.isEmpty else {
            throw WhisperTranscriptionError.emptyAudioRange(
                path: request.audioURL.path,
                startSeconds: start,
                endSeconds: request.endSeconds)
        }

        // `skipSpecialTokens` is OFF by default, and that default is wrong for
        // us: measured 2026-07-27, the fixture's segment text came back as
        // `<|startoftranscript|><|en|><|transcribe|><|0.00|> The quick brown fox
        // …<|2.44|><|endoftext|>`. Word timings are decoded separately and were
        // already clean, so only the prose was affected. Turning WhisperKit's
        // own knob on is the fix; stripping the markers ourselves afterwards
        // would be a second copy of its tokenizer rule. Nothing about the
        // timings changes — segment bounds come from timestamp TOKENS, not from
        // the decoded string.
        let options = DecodingOptions(
            language: request.language,
            skipSpecialTokens: true,
            wordTimestamps: true)
        let results = try await Self.runTranscription(kit.box, samples: samples, options: options)

        return TranscriptionBeatMapper.map(
            results: results,
            rangeStartSeconds: start,
            anchorBeat: request.anchorBeat,
            tempoMap: request.tempoMap,
            modelVariantDirectoryName: kit.descriptor.variantDirectoryName
        )
    }

    // MARK: Loading

    private func loadedKit() async throws -> LoadedKit {
        if let loaded { return loaded }
        let catalog: WhisperModelCatalog
        if let injected = self.catalog {
            catalog = injected
        } else {
            catalog = try WhisperModelCatalog.resolved()
        }
        // Throws WhisperModelError — the catalog's teaching text, verbatim.
        let descriptor = try catalog.resolveModel(named: variantName)
        let box = try await Self.makeKit(
            modelFolder: descriptor.modelFolder.path,
            tokenizerFolder: descriptor.tokenizerFolder)
        let result = LoadedKit(descriptor: descriptor, box: box)
        loaded = result
        return result
    }

    /// The proven local-only load: point WhisperKit at resolved folders and turn
    /// downloading OFF, so a missing or partial model fails here instead of
    /// quietly reaching for the network.
    private nonisolated static func makeKit(
        modelFolder: String,
        tokenizerFolder: URL
    ) async throws -> KitBox {
        let config = WhisperKitConfig(
            modelFolder: modelFolder,
            tokenizerFolder: tokenizerFolder,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false
        )
        return KitBox(kit: try await WhisperKit(config))
    }

    /// The single unboxing site. `nonisolated` and `static` so the box (which is
    /// `Sendable`) crosses the boundary rather than the class inside it, and so
    /// the long decode does not sit on the actor's executor.
    private nonisolated static func runTranscription(
        _ box: KitBox,
        samples: [Float],
        options: DecodingOptions
    ) async throws -> [TranscriptionResult] {
        try await box.kit.transcribe(audioArray: samples, decodeOptions: options)
    }

    // MARK: One job at a time

    /// Wait until no other job holds the transcriber. Waiters are woken all at
    /// once and re-check `busy` after resuming, so there is no hand-off to lose.
    private func acquire() async {
        while busy {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters.append(continuation)
            }
        }
        busy = true
        activeJobs += 1
        peakConcurrentJobs = max(peakConcurrentJobs, activeJobs)
    }

    private func release() {
        activeJobs -= 1
        busy = false
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}
