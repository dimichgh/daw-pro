import Foundation

/// The ONE home for "where does DAW Pro keep this on disk under Application
/// Support" (m23-n1b). Before this existed the same nine-line block was
/// open-coded at NINE call sites across six files in three modules — and two of
/// them (`ProjectStore.defaultAutosaveDirectory()` and
/// `AutosaveManager.defaultDirectory()`) independently resolved the SAME
/// category, so the rolling autosave and the recovery-bundle scan agreed only by
/// coincidence. There is now exactly one computation; the categories are an
/// enum, so a typo can no longer mint a directory nobody reads.
///
/// **Why DAWCore.** Every consumer already depends on it (DAWEngine, DAWControl,
/// AIServices, DAWAppKit, DAWApp) and it stays UI-free, engine-free and
/// dependency-free — Foundation only.
///
/// **What this is NOT.** Only the Application-Support rule lives here. The
/// scratch/bounce paths under `NSTemporaryDirectory()/DAWPro` and the sidecar
/// logs under `~/Library/Logs/DAWPro` are a different rule with a different
/// lifetime (purgeable vs. durable user data); folding them in would let a
/// change to one silently move the other.
public enum AppDirectories {

    /// The product folder that holds every category. A fixed product decision,
    /// not a resolved path — it is the same string in a sandboxed build.
    static let folderName = "DAWPro"

    /// Every durable thing the app keeps under Application Support. The raw
    /// value IS the on-disk directory name, so renaming a case without renaming
    /// its raw value cannot move a user's data by accident.
    ///
    /// These names are load-bearing for existing installs — a user who has been
    /// running the app has real files in `DAWPro/SoundBanks`,
    /// `DAWPro/VoiceDatasets` and friends. Changing a raw value orphans them.
    public enum Category: String, CaseIterable, Sendable {
        /// Per-session recording scratch (`ProjectStore` appends a
        /// `session-<uuid8>` subdirectory beneath this).
        case recordings = "Recordings"
        /// Rolling autosave snapshot + legacy per-slug recovery bundles.
        case autosave = "Autosave"
        /// Imported generated audio (M6 iii-a).
        case generations = "Generations"
        /// Imported reference audio (m22-g).
        case references = "References"
        /// The central sound-bank library (SF2/SFZ/DLS).
        case soundBanks = "SoundBanks"
        /// Diagnostics/feedback bundles.
        case feedback = "Feedback"
        /// RVC voice-training datasets.
        case voiceDatasets = "VoiceDatasets"
        /// Speech-model weights installed by the user (m23-n1).
        case models = "Models"

        /// The on-disk directory name.
        public var directoryName: String { rawValue }
    }

    /// `<Application Support>/DAWPro/<category>/` for the current user.
    ///
    /// The base is RESOLVED, never assumed: a sandboxed build gets
    /// `~/Library/Containers/<bundle-id>/Data/Library/Application Support`, a
    /// plain SwiftPM build gets `~/Library/Application Support`. Only the
    /// `DAWPro/<category>` tail is fixed.
    public static func applicationSupport(_ category: Category) -> URL {
        applicationSupport(
            category,
            systemBase: FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first)
    }

    /// Seam for the fallback branch, which is otherwise untestable — the
    /// resolver essentially never returns empty on a real Mac, so tests pass
    /// `nil` to exercise the hand-built home path.
    ///
    /// **Precedence note (do not "fix" this).** `systemBase ?? URL(…).appending…`
    /// binds as `systemBase ?? (URL(…).appending…)` because member access binds
    /// tighter than `??`. That is the behaviour every one of the nine original
    /// copies had and it is CORRECT: the fallback is the home-relative
    /// Application Support directory, not a bare home directory. Adding parens
    /// around the left operand would silently change the fallback.
    static func applicationSupport(_ category: Category, systemBase: URL?) -> URL {
        let base = systemBase ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(category.directoryName, isDirectory: true)
    }
}
