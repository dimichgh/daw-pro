import Foundation

/// The ONE shared sample-path normalization helper (m19-c, design §5.2),
/// used by `SampleLibraryMapper` for both formats: backslash → slash
/// (Windows-authored libraries), `default_path` prepend, percent/space
/// tolerance, resolution against the main file's directory. Paths that
/// resolve ABOVE the library root are allowed — some libraries legitimately
/// use `..\Samples` (RES §1.3) — but flagged so the mapper can note it.
public enum SampleLibraryPath {
    public struct Resolved: Sendable, Equatable {
        /// The chosen on-disk location (absolute, standardized).
        public let url: URL
        /// True when the path escapes `baseDirectory` (e.g. `../Samples`).
        public let escapesBaseDirectory: Bool
    }

    /// Resolves a region's raw `sample` value. `defaultPath` is prepended
    /// (with a separator inserted when the author omitted the trailing
    /// slash — tolerance, not spec); spaces pass through verbatim (the
    /// tokenizer already preserved them); a percent-encoded spelling is
    /// tried as a FALLBACK only when the literal path does not exist (so a
    /// file literally named `100%.wav` still wins).
    public static func resolve(sample: String, defaultPath: String?,
                               baseDirectory: URL) -> Resolved {
        let joined: String
        if let prefix = defaultPath, !prefix.isEmpty {
            let needsSeparator = !(prefix.hasSuffix("/") || prefix.hasSuffix("\\"))
            joined = prefix + (needsSeparator ? "/" : "") + sample
        } else {
            joined = sample
        }
        let slashed = joined.replacingOccurrences(of: "\\", with: "/")
        let primary = URL(fileURLWithPath: slashed,
                          relativeTo: baseDirectory).standardizedFileURL
        var chosen = primary
        if !FileManager.default.fileExists(atPath: primary.path),
           slashed.contains("%"),
           let decoded = slashed.removingPercentEncoding, decoded != slashed {
            let alternate = URL(fileURLWithPath: decoded,
                                relativeTo: baseDirectory).standardizedFileURL
            if FileManager.default.fileExists(atPath: alternate.path) {
                chosen = alternate
            }
        }
        let base = baseDirectory.standardizedFileURL.path
        let root = base.hasSuffix("/") ? base : base + "/"
        let escapes = !(chosen.path == base || chosen.path.hasPrefix(root))
        return Resolved(url: chosen, escapesBaseDirectory: escapes)
    }
}
