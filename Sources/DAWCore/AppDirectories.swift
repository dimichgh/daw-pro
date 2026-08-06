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
    ///
    /// **`DAWPRO_PROFILE_ROOT` (m23-ay).** When that variable is set in the
    /// process environment it REPLACES the resolved base — see
    /// `profileRootOverride(environment:fileManager:systemBase:)` for the rule
    /// and `processProfileRootBase` for the once-per-process resolution. Unset
    /// (the shipped app, always) means this function behaves exactly as it did
    /// before the override existed.
    public static func applicationSupport(_ category: Category) -> URL {
        // `processProfileRootBase` is nil in every process that does not set the
        // variable, so this reads as the original expression with one extra
        // already-computed optional in front of it.
        applicationSupport(
            category,
            systemBase: processProfileRootBase ?? FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first)
    }

    /// Seam for the fallback branch, which is otherwise untestable — the
    /// resolver essentially never returns empty on a real Mac, so tests pass
    /// `nil` to exercise the hand-built home path.
    static func applicationSupport(_ category: Category, systemBase: URL?) -> URL {
        base(systemBase: systemBase)
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(category.directoryName, isDirectory: true)
    }

    /// The directory every category hangs off — the resolved Application Support
    /// directory, or the hand-built home-relative one when the resolver comes
    /// back empty.
    ///
    /// Split out of `applicationSupport(_:systemBase:)` at m23-ay so the override
    /// validation below can name "the base this process would otherwise have
    /// used" without spelling the `??` a second time. It is the SAME expression,
    /// moved, not a copy.
    ///
    /// **Precedence note (do not "fix" this).** `systemBase ?? URL(…).appending…`
    /// binds as `systemBase ?? (URL(…).appending…)` because member access binds
    /// tighter than `??`. That is the behaviour every one of the nine original
    /// copies had and it is CORRECT: the fallback is the home-relative
    /// Application Support directory, not a bare home directory. Adding parens
    /// around the left operand would silently change the fallback.
    static func base(systemBase: URL?) -> URL {
        systemBase ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    // MARK: - The staging-profile override (m23-ay)

    /// The environment variable that relocates this process's whole profile.
    ///
    /// **What it is for.** Every staging instance a gate launches used to resolve
    /// this rule to the USER'S OWN `~/Library/Application Support/DAWPro/`,
    /// because nothing overrode it — so a gate run shared the autosave,
    /// recordings, generations and feedback directories with the person using the
    /// app. That is not a tidiness problem: a staging launch writes
    /// `Autosave/session.lock` (crash detection) and `pruneUntitledRecoveryBundles()`
    /// DELETES the oldest `Untitled-*.dawproj` recovery bundles it finds there.
    /// Run a gate while the user has DAW Pro open and their live crash-detection
    /// state is corrupted, with no teardown that can undo it (measured at m23-ay:
    /// pid 37057's lock was replaced by a gate's).
    ///
    /// **Why an env var and not a temp `HOME`.** Redirecting `HOME` moves
    /// `UserDefaults` too, so preference-persistence gates (`m23c2`) would stop
    /// testing the thing they exist to test. This moves ONE rule and leaves
    /// everything else about the process production-shaped.
    public static let profileRootEnvironmentKey = "DAWPRO_PROFILE_ROOT"

    /// The result of reading `DAWPRO_PROFILE_ROOT`.
    ///
    /// Three cases, not two, and the third is the point: an override that is
    /// PRESENT BUT UNUSABLE must never collapse into `.absent`. A silent fallback
    /// there puts the writes back in the user's real profile while every caller —
    /// and every gate — believes the process is isolated. That is the failure
    /// shape the m23-ah arc kept finding (a guard that validates SHAPE and calls
    /// it validated), so the refusals below check USABILITY too, not just that the
    /// string looks path-like.
    public enum ProfileRootOverride: Equatable, Sendable {
        /// The variable is not set. Production. Resolve the real profile.
        case absent
        /// The variable named a usable directory, which stands in for the
        /// resolved Application Support base: the profile is
        /// `<root>/DAWPro/<Category>/`.
        case root(URL)
        /// The variable was set to something that cannot be a profile root.
        /// `reason` names `DAWPRO_PROFILE_ROOT` and quotes the offending value —
        /// it is written to be read in a staging log by someone who did not write
        /// this code.
        case refused(reason: String)
    }

    /// Reads and VALIDATES `DAWPRO_PROFILE_ROOT`. Pure with respect to its
    /// inputs (environment, file manager, base) so both branches are testable
    /// without swapping processes — the `TestEnvironment.isSwiftTestProcess`
    /// shape.
    ///
    /// ⚠️ Not free of side effects, deliberately: the `.root` branch CREATES the
    /// directory. "Is this path usable as a profile root" cannot be answered
    /// without it — `isWritableFile(atPath:)` on a path that does not exist yet
    /// answers about nothing — and creating it here means the one process-wide
    /// resolution is also the one place that can report a creation failure.
    ///
    /// The order of the checks is load-bearing. Shape first (cheap, and its
    /// messages are the most actionable); then the "this override IS the real
    /// base" check, which is pure and must run BEFORE any filesystem work so
    /// that refusing it cannot itself touch the user's real profile directory;
    /// then usability, which is the only part that writes anything.
    static func profileRootOverride(
        environment: [String: String],
        fileManager: FileManager = .default,
        systemBase: URL?
    ) -> ProfileRootOverride {
        guard let raw = environment[profileRootEnvironmentKey] else { return .absent }
        // From here on the variable IS set, so no branch may return `.absent`.
        let quoted = String(reflecting: raw) // escapes NUL/newlines; safe to log

        if raw.isEmpty {
            return .refused(reason:
                "\(profileRootEnvironmentKey) is set but EMPTY. An empty value is not an "
                + "absent one: it is an attempt to name a profile root that cannot be a path, "
                + "and treating it as absent would silently put every write back in the user's "
                + "real ~/Library/Application Support/DAWPro/. Unset the variable to use the "
                + "real profile.")
        }
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .refused(reason:
                "\(profileRootEnvironmentKey)=\(quoted) is only whitespace — see the empty-value "
                + "note. Unset the variable to use the real profile.")
        }
        // The m23-ah-2 lesson, verbatim: a type-and-length guard validates SHAPE,
        // not usability. "/tmp/a\0b" is a non-empty absolute-looking String and
        // every POSIX path API rejects it (Foundation truncates or throws
        // depending on the call), so it is refused HERE rather than surfacing
        // later as an unrelated write failure in some category directory.
        if raw.contains("\0") {
            return .refused(reason:
                "\(profileRootEnvironmentKey)=\(quoted) contains a NUL byte, which cannot appear "
                + "in a filesystem path. (It passes a non-empty-string check, which is why it is "
                + "named explicitly.)")
        }
        guard raw.hasPrefix("/") else {
            return .refused(reason:
                "\(profileRootEnvironmentKey)=\(quoted) is not an ABSOLUTE path. A relative value "
                + "would resolve against whatever the working directory happens to be, and a "
                + "'~'-prefixed one is not expanded by the environment — expand it in the caller "
                + "(e.g. \"$HOME/…\") and pass the result.")
        }

        let url = URL(fileURLWithPath: raw, isDirectory: true)
        // Symlinks are deliberately NOT resolved: the caller gets back the root
        // it named. On macOS both `/tmp` and `/var` are symlinks, so resolving
        // would hand back `/private/…` and make a gate's "did the app write under
        // the root I gave it" comparison fail for a reason that is not a defect.

        // BEFORE any filesystem work. An override that resolves to the base the
        // process would have used anyway is not isolation — it is the real
        // profile wearing the override's name, and it would make every "this
        // instance is isolated" claim above it false while looking configured.
        // Unset the variable instead; that is the supported way to ask for the
        // real profile. Placed here rather than after the usability block so
        // that refusing this value cannot create or stat anything inside the
        // user's real Application Support directory.
        if url.standardizedFileURL == base(systemBase: systemBase).standardizedFileURL {
            return .refused(reason:
                "\(profileRootEnvironmentKey)=\(quoted) IS the base this process would have used "
                + "anyway, so it isolates nothing while looking configured. Unset the variable to "
                + "use the real profile deliberately.")
        }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            return .refused(reason:
                "\(profileRootEnvironmentKey)=\(quoted) could not be created as a directory: "
                + "\(error.localizedDescription)")
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .refused(reason:
                "\(profileRootEnvironmentKey)=\(quoted) exists but is not a directory.")
        }
        guard fileManager.isWritableFile(atPath: url.path) else {
            return .refused(reason:
                "\(profileRootEnvironmentKey)=\(quoted) is a directory this process cannot write "
                + "to. A profile root that cannot be written to would send every save, autosave "
                + "and recording to an error path rather than to isolation.")
        }
        return .root(url)
    }

    /// The override for THIS process, resolved once.
    ///
    /// `nil` means "no override" — the shipped app, every time, and the only cost
    /// it pays is one dictionary lookup at first use. A `static let` for the same
    /// reason `TestEnvironment.isRunningTests` is one: the answer cannot change
    /// while the process runs, every consumer must get the SAME answer, and a
    /// per-call re-resolution would re-run the directory creation on a path that
    /// `applicationSupport` reaches dozens of times.
    ///
    /// ⚠️ A REFUSED override TRAPS. It is not downgraded to `nil`, and this is the
    /// whole safety property: falling back would resume writing into the user's
    /// real profile while the operator believes the instance is isolated — the bug
    /// this override exists to fix, re-created and now invisible. The trap is
    /// unreachable in the shipped app (which never sets the variable) and loud
    /// everywhere else: the reason goes to stderr first, so it lands in a staging
    /// log even if the crash report does not.
    nonisolated public static let processProfileRootBase: URL? = {
        let resolved = profileRootOverride(
            environment: ProcessInfo.processInfo.environment,
            systemBase: FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first)
        switch resolved {
        case .absent:
            return nil
        case .root(let url):
            // Announced, not silent: a gate reads this line out of the staging
            // log to prove the instance it is about to drive is the isolated one.
            let announcement =
                "AppDirectories: \(profileRootEnvironmentKey) active — profile root \(url.path) "
                + "(autosave: \(applicationSupport(.autosave, systemBase: url).path))\n"
            FileHandle.standardError.write(Data(announcement.utf8))
            return url
        case .refused(let reason):
            FileHandle.standardError.write(Data("AppDirectories: \(reason)\n".utf8))
            fatalError(
                "\(reason) — refusing to fall back to the real profile, because a process that "
                + "asked to be isolated and silently was not is the defect m23-ay exists to "
                + "prevent.")
        }
    }()
}
