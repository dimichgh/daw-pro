import Foundation

/// Host facts stamped into a feedback bundle's `manifest.json` (M9 beta): the
/// "what machine / what build" half of an actionable bug report. Value type,
/// `Codable`/`Sendable`. `.current()` resolves them from the running process —
/// `appVersion`/`build` from `Bundle.main`'s Info.plist (a bundled `.app`
/// carries them; a bare SPM binary has no Info.plist, so both read "dev"),
/// `osVersion` from `ProcessInfo`, `hardwareModel` from the `hw.model` sysctl.
/// Injected explicitly in reporter tests so a manifest is byte-deterministic.
public struct DiagnosticsHostInfo: Codable, Sendable, Equatable {
    /// `CFBundleShortVersionString` (e.g. "0.1.0") when bundled; "dev" otherwise.
    public var appVersion: String
    /// `CFBundleVersion` (e.g. "1") when bundled; "dev" otherwise.
    public var build: String
    /// `ProcessInfo.operatingSystemVersionString`, e.g. "Version 14.5 (Build 23F79)".
    public var osVersion: String
    /// The `hw.model` sysctl string, e.g. "MacBookPro18,3"; "unknown" if unreadable.
    public var hardwareModel: String

    public init(appVersion: String, build: String, osVersion: String, hardwareModel: String) {
        self.appVersion = appVersion
        self.build = build
        self.osVersion = osVersion
        self.hardwareModel = hardwareModel
    }

    /// Resolves the running host's facts. NEVER reads Keychain / environment key
    /// material — only the bundle Info.plist, the OS version, and the hardware
    /// model. Missing Info.plist keys (the bare-binary case) read "dev".
    public static func current() -> DiagnosticsHostInfo {
        let info = Bundle.main.infoDictionary
        let appVersion = (info?["CFBundleShortVersionString"] as? String) ?? "dev"
        let build = (info?["CFBundleVersion"] as? String) ?? "dev"
        return DiagnosticsHostInfo(
            appVersion: appVersion,
            build: build,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            hardwareModel: Self.hardwareModel()
        )
    }

    /// The `hw.model` sysctl string; "unknown" if the sysctl fails.
    private static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        // `size` includes sysctl's trailing NUL — decode only up to it.
        let bytes = buffer.prefix(while: { $0 != 0 })
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// The engine-health half of a feedback bundle — the on-disk `engine.json`. The
/// M9 telemetry (watchdog + performance snapshots) pays off here: a tester's
/// dropout report arrives WITH the watchdog state (did the engine self-heal? how
/// many times?) and the render-load window. The reporter itself stays engine-free
/// (DAWCore purity) — the caller passes these snapshots IN. `Codable`/`Sendable`.
public struct EngineDiagnostics: Codable, Sendable, Equatable {
    public var watchdog: EngineWatchdogStatus
    public var performance: EnginePerformanceStats

    public init(watchdog: EngineWatchdogStatus, performance: EnginePerformanceStats) {
        self.watchdog = watchdog
        self.performance = performance
    }
}

/// The on-disk `manifest.json` for a feedback bundle (M9 beta): the facts a
/// triager reads first, plus the presence/counts of the other bundle files.
/// Deliberately privacy-lean — carries no note content, no media paths, no key
/// material. Value type; `Codable`/`Sendable`.
public struct FeedbackManifest: Codable, Sendable, Equatable {
    public var appVersion: String
    public var build: String
    public var osVersion: String
    public var hardwareModel: String
    /// Wall-clock time the bundle was written (the reporter's injected clock).
    public var createdAt: Date
    /// True only when the tester opted into sharing the full project snapshot.
    public var includesProject: Bool
    /// Recent `DAWApp*.ips` crash reports copied into `crashes/`.
    public var crashReportCount: Int
    /// Whether `engine.json` landed (always true today; carried for forward-compat).
    public var hasEngine: Bool
    /// Whether `overview.json` landed (always true today).
    public var hasOverview: Bool

    public init(appVersion: String, build: String, osVersion: String,
                hardwareModel: String, createdAt: Date, includesProject: Bool,
                crashReportCount: Int, hasEngine: Bool, hasOverview: Bool) {
        self.appVersion = appVersion
        self.build = build
        self.osVersion = osVersion
        self.hardwareModel = hardwareModel
        self.createdAt = createdAt
        self.includesProject = includesProject
        self.crashReportCount = crashReportCount
        self.hasEngine = hasEngine
        self.hasOverview = hasOverview
    }
}

/// The one error a feedback-bundle write can surface: a real filesystem failure,
/// carried as a client-readable `LocalizedError` so the wire/MCP layer maps it to
/// a message (the `ProjectError` precedent) rather than dumping a Swift value.
public enum DiagnosticsError: LocalizedError, Equatable {
    /// Writing the bundle folder / a required file failed (disk full, no
    /// permission, …). The associated string is the underlying reason.
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .writeFailed(let reason):
            return "couldn't write the feedback bundle: \(reason)"
        }
    }
}

/// Headless diagnostics-bundle writer (M9 beta). One call — `writeBundle(...)` —
/// produces ONE local FOLDER `feedback-<yyyyMMdd-HHmmss>/` that makes a beta bug
/// report actionable, and returns a `FeedbackBundleSummary`. A plain folder, NOT
/// a zip: fewer failure modes, testable headless, and Finder-attachable as-is.
///
/// Everything is LOCAL — the reporter makes NO network calls and never reads
/// Keychain / environment key material. The privacy-lean DEFAULT ships only an
/// app/OS/build manifest, engine-health snapshots, and a counts-only project
/// overview (no note content, no media paths); the full project snapshot is
/// included ONLY when the caller opts in (`projectDocument != nil`).
///
/// Layout (all under `feedback-<timestamp>/`):
///  - `manifest.json` — `FeedbackManifest` (host facts + presence/counts).
///  - `engine.json` — `EngineDiagnostics` (watchdog + performance snapshots).
///  - `overview.json` — the `ProjectOverview` projection (counts/ids only).
///  - `crashes/` — copies of recent `DAWApp*.ips` reports (may be empty).
///  - `project.dawproject/` — the full bundle snapshot, ONLY when opted in.
///
/// Injection mirrors `AutosaveManager`: `outputDir` (where bundles land),
/// `crashReportsDir` (where macOS writes `.ips` reports), and `clock` are all
/// injected so tests never write into the real profile, never scan the real
/// crash-report store, and get deterministic timestamps. `@MainActor` because
/// `ProjectStore` (its only production caller) drives it on the main actor; the
/// write is synchronous file I/O — a manual, user-initiated action, not a hot
/// path (the `openProject` precedent).
@MainActor
public final class DiagnosticsReporter {
    /// Where feedback bundles land. Default:
    /// `~/Library/Application Support/DAWPro/Feedback/`. Injected in tests.
    public var outputDir: URL
    /// Where macOS writes per-process crash reports. Default:
    /// `~/Library/Logs/DiagnosticReports/`. Injected in tests (a fake `.ips` dir).
    public var crashReportsDir: URL
    /// Time source for `createdAt` and the bundle folder name, plus the 14-day
    /// crash-report cutoff. Injected in tests for determinism.
    public var clock: @Sendable () -> Date

    /// Crash reports newer than this are eligible for copying.
    public static let crashReportMaxAge: TimeInterval = 14 * 24 * 60 * 60
    /// At most this many (newest-first) crash reports are copied.
    public static let crashReportCap = 10

    public init(
        outputDir: URL = DiagnosticsReporter.defaultOutputDir(),
        crashReportsDir: URL = DiagnosticsReporter.defaultCrashReportsDir(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.outputDir = outputDir
        self.crashReportsDir = crashReportsDir
        self.clock = clock
    }

    /// Default feedback dir: `~/Library/Application Support/DAWPro/Feedback/`.
    public static func defaultOutputDir() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("DAWPro", isDirectory: true)
            .appendingPathComponent("Feedback", isDirectory: true)
    }

    /// Default crash-report dir: `~/Library/Logs/DiagnosticReports/`.
    public static func defaultCrashReportsDir() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    /// Writes one feedback bundle and returns its summary. Throws
    /// `DiagnosticsError.writeFailed` on a real filesystem failure of a REQUIRED
    /// file (the folder, manifest, engine, overview, or an opted-in project
    /// snapshot); crash-report gathering is best-effort and never throws (a
    /// missing/unreadable crash dir simply copies zero).
    ///
    /// - Parameters:
    ///   - host: app/OS/build facts (`.current()` in production, injected in tests).
    ///   - engine: the CURRENT watchdog + performance snapshots (passed in by the
    ///     caller — the reporter stays engine-free).
    ///   - overview: the counts-only project projection (the privacy-lean default).
    ///   - projectDocument: the full snapshot to serialize into
    ///     `project.dawproject/`, or nil to omit it (the opt-in gate).
    public func writeBundle(
        host: DiagnosticsHostInfo,
        engine: EngineDiagnostics,
        overview: ProjectOverview,
        projectDocument: ProjectDocument?
    ) throws -> FeedbackBundleSummary {
        let now = clock()
        let bundleURL = uniqueBundleURL(for: now)
        let includesProject = projectDocument != nil

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let fm = FileManager.default
            try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)

            // engine.json — the M9 telemetry payoff.
            try encoder.encode(engine).write(
                to: bundleURL.appendingPathComponent("engine.json"), options: .atomic)

            // overview.json — counts/ids only, no note content or media paths.
            try encoder.encode(overview).write(
                to: bundleURL.appendingPathComponent("overview.json"), options: .atomic)

            // crashes/ — best-effort; created even when empty so the layout is
            // predictable ("no recent crashes" reads clearly as an empty folder).
            let crashesDir = bundleURL.appendingPathComponent("crashes", isDirectory: true)
            try fm.createDirectory(at: crashesDir, withIntermediateDirectories: true)
            let crashReportCount = copyRecentCrashReports(into: crashesDir, now: now)

            // project.dawproject/ — the full snapshot, ONLY when opted in. The SAME
            // serialization the autosave/save path uses (absolute media refs, zero
            // copies) so it round-trips through `project.open`.
            if let projectDocument {
                try ProjectBundle.write(
                    document: projectDocument,
                    plan: ProjectBundle.MediaPlan(copies: [], refs: [:], warnings: []),
                    to: bundleURL.appendingPathComponent("project.dawproject", isDirectory: true))
            }

            // manifest.json LAST so its presence signals a complete bundle.
            let manifest = FeedbackManifest(
                appVersion: host.appVersion, build: host.build,
                osVersion: host.osVersion, hardwareModel: host.hardwareModel,
                createdAt: now, includesProject: includesProject,
                crashReportCount: crashReportCount, hasEngine: true, hasOverview: true)
            try encoder.encode(manifest).write(
                to: bundleURL.appendingPathComponent("manifest.json"), options: .atomic)

            let (fileCount, byteCount) = measure(bundleURL)
            return FeedbackBundleSummary(
                path: bundleURL.path,
                fileCount: fileCount,
                byteCount: byteCount,
                crashReportCount: crashReportCount,
                includesProject: includesProject)
        } catch let error as DiagnosticsError {
            throw error
        } catch {
            throw DiagnosticsError.writeFailed(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: - Crash-report gathering

    /// Copies the newest recent `DAWApp*.ips` crash reports into `crashesDir` and
    /// returns how many landed. RULES: only files whose name starts with "DAWApp"
    /// and ends ".ips" (a foreign process's `.ips` is ignored — no other app's
    /// crash leaks in), modified within the last 14 days (relative to `now`),
    /// newest first, capped at 10. Best-effort: a missing/unreadable crash dir, or
    /// an individual copy failure, is tolerated (that report is simply skipped).
    private func copyRecentCrashReports(into crashesDir: URL, now: Date) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: crashReportsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        let cutoff = now.addingTimeInterval(-Self.crashReportMaxAge)
        let recent = entries
            .filter { url in
                let name = url.lastPathComponent
                return name.hasPrefix("DAWApp") && name.hasSuffix(".ips")
            }
            .compactMap { url -> (url: URL, mtime: Date)? in
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                guard let mtime, mtime >= cutoff else { return nil }
                return (url, mtime)
            }
            .sorted { $0.mtime > $1.mtime }
            .prefix(Self.crashReportCap)

        var copied = 0
        for report in recent {
            let dest = crashesDir.appendingPathComponent(report.url.lastPathComponent)
            do {
                try fm.copyItem(at: report.url, to: dest)
                copied += 1
            } catch {
                // Skip this one report; a partial crash set still helps a triager.
            }
        }
        return copied
    }

    // MARK: - Helpers

    /// A `feedback-<yyyyMMdd-HHmmss>/` URL under `outputDir` that does not yet
    /// exist — appends `-2`, `-3`, … if two bundles land in the same second.
    private func uniqueBundleURL(for date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: date)
        let fm = FileManager.default
        var candidate = outputDir.appendingPathComponent("feedback-\(stamp)", isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = outputDir.appendingPathComponent("feedback-\(stamp)-\(n)", isDirectory: true)
            n += 1
        }
        return candidate
    }

    /// Walks the finished bundle and returns (regular-file count, total bytes).
    /// Directories are not counted as files; symlinks are skipped.
    private func measure(_ bundleURL: URL) -> (fileCount: Int, byteCount: Int) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return (0, 0) }
        var files = 0
        var bytes = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            files += 1
            bytes += values?.fileSize ?? 0
        }
        return (files, bytes)
    }
}
