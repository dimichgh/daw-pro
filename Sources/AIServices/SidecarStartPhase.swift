import Foundation

/// Pure classifier mapping the TAIL of the sidecar's own log
/// (`SidecarManager.Configuration.logFileURL`) to a short, human phase string
/// for the "loading models…" progress hint shown while
/// `SidecarStatus.state == .starting` (M10-b). No I/O here — the caller reads
/// the log bytes; this type only pattern-matches the resulting text — so it's
/// directly headless-testable with excerpts.
///
/// Every marker below was lifted VERBATIM from a real cold boot captured at
/// `~/Library/Logs/DAWPro/ace-step.log` (the 2026-07-06 08:07 and 2026-07-10
/// 01:26 sessions) — never invented. That log is APPENDED across restarts,
/// never truncated, so a short tail read early in a new boot can still hold
/// the END of a previous session (e.g. its "Finished server process" line)
/// followed by this session's first few lines; `classify` always resolves to
/// the RIGHTMOST (most recent) marker it finds, so stale text from a prior
/// session never outranks fresher text later in the same tail.
public enum SidecarStartPhase: Sendable, Equatable {
    /// The `run.sh` child has just spawned: Python is still importing torch/
    /// mlx/acestep and no server output has appeared yet. Real markers seen
    /// BEFORE `"Started server process [pid]"` on a cold boot.
    case preparingEnvironment
    /// Uvicorn itself is up (or is in the process of coming up) — health
    /// should follow within a beat of this.
    case startingServer
    /// The FastAPI process is serving, but the DiT/LM checkpoints are still
    /// being loaded into memory (ACE-Step's lazy-load-on-first-request path,
    /// or an eager load) — real markers from `[API Server] Initializing
    /// models…` through the MLX DiT/VAE/LM init lines.
    case loadingModels

    public var displayText: String {
        switch self {
        case .preparingEnvironment: return "preparing environment…"
        case .startingServer: return "starting server…"
        case .loadingModels: return "loading models…"
        }
    }

    /// Ordered as (phase, marker substrings) — order among phases doesn't
    /// matter for correctness (resolution is purely by rightmost match
    /// index), but is kept roughly boot-chronological for readability.
    private static let markers: [(SidecarStartPhase, [String])] = [
        (.preparingEnvironment, [
            "torch/distributed/elastic",
            "bitsandbytes not installed",
            "[API Server] Using LM model:",
        ]),
        (.startingServer, [
            "Waiting for application startup",
            "Application startup complete",
            "Uvicorn running",
            "Server is ready to accept requests",
        ]),
        (.loadingModels, [
            "[API Server] Initializing models",
            "[API Server] Loading primary DiT model",
            "[API Server] Loading LLM model",
            "[Model Download]",
            "Loading checkpoint shards",
            "MLX-DiT] Native MLX DiT decoder initialized",
            "MLX-VAE] Native MLX VAE initialized",
            "loading 5Hz LM tokenizer",
            "Loading MLX model from",
        ]),
    ]

    /// Human phase text for the tail of the sidecar log, or nil when nothing
    /// recognizable is present (an empty/missing log, or text that matches
    /// none of the known markers) — the banner then falls back to a generic
    /// "starting" line instead of a phase-specific one.
    public static func classify(logTail: String) -> String? {
        guard !logTail.isEmpty else { return nil }
        var best: (phase: SidecarStartPhase, index: String.Index)?
        for (phase, needles) in markers {
            for needle in needles {
                guard let range = logTail.range(of: needle, options: .backwards) else { continue }
                if best == nil || range.lowerBound > best!.index {
                    best = (phase, range.lowerBound)
                }
            }
        }
        return best?.phase.displayText
    }
}
