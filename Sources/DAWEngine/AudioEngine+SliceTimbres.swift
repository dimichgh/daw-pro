import DAWCore
import Foundation

// m39-w4-6 — the engine side of kit-aware slicing, in its own file so the shared `AudioEngine.swift` is not
// touched. Design `docs/design/2026-10-07-loop-drum-depth.md` §5.2 step 1.
extension AudioEngine {

    /// Measures each slice's timbre (`SliceTimbreAnalyzer`) on a detached task, the
    /// `resolveSliceBoundaries` posture: zero render-thread involvement, zero live-graph involvement. NOT
    /// cached: the answer depends on the caller's spans, so a cache would key on the request and almost never
    /// hit. The file is read once, over the frames the spans cover.
    public func analyzeSliceTimbres(inFileAt url: URL,
                                    frameRanges: [SliceFrameSpan]) async throws -> [SliceTimbre] {
        try await Task.detached(priority: .userInitiated) {
            try SliceTimbreAnalyzer.analyze(fileAt: url, frameRanges: frameRanges)
        }.value
    }
}
