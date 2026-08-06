import Foundation
import Testing
@testable import DAWCore

/// m23-ay — `DAWPRO_PROFILE_ROOT`, the staging-profile override.
///
/// **What this suite is defending.** Before the override existed, every staging
/// instance a gate launched resolved `AppDirectories.applicationSupport(…)` to
/// the USER'S OWN `~/Library/Application Support/DAWPro/`. A gate run therefore
/// wrote `Autosave/session.lock` into the profile of the person using the app
/// (measured: a staging launch replaced pid 37057's lock) and ran
/// `pruneUntitledRecoveryBundles()` against their real recovery bundles.
///
/// The three properties below are the whole contract, and each has its own
/// tests:
///   1. ABSENT ⇒ byte-for-byte today's behaviour. The escape hatch must not
///      become the default by accident.
///   2. PRESENT AND USABLE ⇒ the profile relocates, keeping the
///      `DAWPro/<Category>` tail (the JS mirror in `scripts/gates/_staging.mjs`
///      and the m23-ay gate both spell that tail).
///   3. PRESENT AND UNUSABLE ⇒ REFUSED — never downgraded to "absent". A silent
///      fallback here re-creates the bug while looking fixed: the operator
///      believes the instance is isolated and it is writing into the user's real
///      profile. Every refusal test below therefore asserts `!= .absent`
///      explicitly, not merely `== .refused`.
///
/// **Why the injected `environment:`/`fileManager:`/`systemBase:` seam and not
/// `setenv`.** The process-wide answer is a `static let` decided once (see
/// `processProfileRootBase`), exactly like `TestEnvironment.isRunningTests`; a
/// test that mutated the real environment would be racing every other test in
/// the process and could not exercise the trap branch at all.
@Suite("AppDirectories — DAWPRO_PROFILE_ROOT staging override (m23-ay)")
struct AppDirectoriesProfileRootTests {

    private let key = AppDirectories.profileRootEnvironmentKey

    /// The base this machine would resolve with no override — the same call
    /// `applicationSupport(_:)` makes.
    private var resolvedSystemBase: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    /// A unique, non-existent path under the temp directory. NOT created — some
    /// tests need the creating branch to be the thing under test.
    private func tempPath(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("m23ay-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    /// The same, minted as a FILE URL (no trailing slash) — `Data.write(to:)`
    /// fails on a directory-flagged URL, so the "a regular file is not a profile
    /// root" test needs this spelling.
    private func tempFilePath(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("m23ay-\(label)-\(UUID().uuidString)", isDirectory: false)
    }

    private func resolve(_ raw: String?, systemBase: URL? = nil) -> AppDirectories.ProfileRootOverride {
        AppDirectories.profileRootOverride(
            environment: raw.map { [key: $0] } ?? [:],
            systemBase: systemBase)
    }

    // MARK: - The name itself

    /// The literal is spelled in three places outside Swift: `_staging.mjs`
    /// (which sets it for every gate launch), the m23-ay gate, and any operator
    /// running a staging app by hand. A rename here without those would silently
    /// un-isolate every gate run — the exact defect, restored, with all the code
    /// still present and looking correct.
    @Test("The variable name is pinned — the JS side spells this literal")
    func environmentKeyIsPinned() {
        #expect(key == "DAWPRO_PROFILE_ROOT")
    }

    // MARK: - Property 1: absent ⇒ today's behaviour

    @Test("An environment without the key is .absent")
    func absentEnvironmentIsAbsent() {
        #expect(resolve(nil, systemBase: resolvedSystemBase) == .absent)
        #expect(AppDirectories.profileRootOverride(
            environment: ["HOME": "/Users/nobody", "PATH": "/usr/bin"],
            systemBase: resolvedSystemBase) == .absent)
    }

    /// The roadmap's second half: "assert the app still resolves the REAL path
    /// when the override is absent, so the escape hatch cannot silently become
    /// the default". This is that assertion, made against the REAL process —
    /// `applicationSupport(_:)` with nothing injected.
    @Test("With no override set, every category resolves exactly where it did before")
    func absentOverrideLeavesEveryCategoryOnTheRealPath() throws {
        // A test runner with the variable exported would be testing something
        // else entirely, and the equality below would be a lie about production.
        try #require(ProcessInfo.processInfo.environment[key] == nil,
                     "\(key) is exported into the test process — unset it and re-run")
        #expect(AppDirectories.processProfileRootBase == nil)

        let systemBase = try #require(resolvedSystemBase)
        for category in AppDirectories.Category.allCases {
            #expect(AppDirectories.applicationSupport(category)
                == AppDirectories.applicationSupport(category, systemBase: systemBase),
                "\(category) must still resolve under the real Application Support base")
        }
    }

    // MARK: - Property 2: present and usable ⇒ relocated, same shape

    @Test("A usable override relocates every category under <root>/DAWPro/<Category>")
    func usableOverrideRelocatesEveryCategory() throws {
        let root = tempPath("relocate")
        defer { try? FileManager.default.removeItem(at: root) }

        guard case .root(let resolved) = resolve(root.path, systemBase: resolvedSystemBase) else {
            Issue.record("expected .root for \(root.path)")
            return
        }
        #expect(resolved.standardizedFileURL == root.standardizedFileURL)

        let realBase = try #require(resolvedSystemBase)
        for category in AppDirectories.Category.allCases {
            let url = AppDirectories.applicationSupport(category, systemBase: resolved)
            // The tail is UNCHANGED — this is the shape `_staging.mjs` mirrors.
            #expect(url.lastPathComponent == category.directoryName)
            #expect(url.deletingLastPathComponent().lastPathComponent == "DAWPro")
            #expect(url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
                == root.standardizedFileURL)
            // And it is NOT the user's profile — the point of the whole item.
            #expect(!url.path.hasPrefix(realBase.appendingPathComponent("DAWPro").path))
        }
    }

    /// The usability check is the reason this resolver has side effects: a
    /// writability answer about a path that does not exist is an answer about
    /// nothing. Creating the root here also means the ONE process-wide
    /// resolution is the one place a creation failure can be reported.
    @Test("Resolving a usable override CREATES the root directory")
    func resolvingCreatesTheRoot() {
        let root = tempPath("created").appendingPathComponent("nested/deeper", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        #expect(!FileManager.default.fileExists(atPath: root.path))

        guard case .root(let resolved) = resolve(root.path, systemBase: resolvedSystemBase) else {
            Issue.record("expected .root for a creatable path")
            return
        }
        #expect(resolved.path == root.path)

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test("An existing, writable directory is accepted as-is")
    func existingDirectoryIsAccepted() throws {
        let root = tempPath("existing")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        guard case .root(let resolved) = resolve(root.path, systemBase: resolvedSystemBase) else {
            Issue.record("an existing writable directory must be accepted")
            return
        }
        #expect(resolved.path == root.path)
    }

    /// macOS `/tmp` and `/var` are symlinks. If the resolver resolved them, a
    /// gate that hands the app `/var/folders/…` and then checks that directory
    /// for the app's writes would look at a path the app never used, and the
    /// gate would go red for a reason that is not a defect.
    @Test("Symlinks in the override are NOT resolved — the caller gets back the root it named")
    func symlinksAreNotResolved() throws {
        let real = tempPath("symlink-target")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = tempPath("symlink-alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: real)
        }
        guard case .root(let resolved) = resolve(link.path, systemBase: resolvedSystemBase) else {
            Issue.record("expected .root for the symlinked path")
            return
        }
        #expect(resolved.path == link.path)
        #expect(resolved.path != real.path)
    }

    // MARK: - Property 3: present and unusable ⇒ REFUSED, never .absent

    /// The table-driven half. Every one of these is a value someone can actually
    /// produce (`FOO=` in a shell, an unexpanded `~`, a path built from an empty
    /// variable), and for every one of them the answer that would re-create the
    /// bug is `.absent`.
    @Test("Malformed values are REFUSED — and never reported as .absent",
          arguments: [
            ("empty string", ""),
            ("whitespace only", "   \t\n "),
            ("relative path", "relative/profile"),
            ("bare name", "profile"),
            ("unexpanded tilde", "~/Library/Application Support/DAWPro-staging"),
            ("NUL byte", "/tmp/m23ay-nul\u{0}injected"),
          ])
    func malformedValuesAreRefused(label: String, raw: String) {
        let result = resolve(raw, systemBase: resolvedSystemBase)
        #expect(result != .absent, "\(label) must not be mistaken for an unset variable")
        guard case .refused(let reason) = result else {
            Issue.record("\(label): expected .refused, got \(result)")
            return
        }
        // The message is read in a staging log by someone who did not write this
        // code, so it has to name the variable it is complaining about.
        #expect(reason.contains(key), "\(label): refusal must name \(key) — got: \(reason)")
    }

    /// Spelled out separately from the table because it is the one the m23-ah
    /// arc paid for: `"/tmp/a\0b"` satisfies `typeof == "string" && length > 0`
    /// and every "is it absolute" check, and still cannot be a path. A guard
    /// that validates SHAPE is not a guard that validates USABILITY.
    @Test("A NUL byte is refused even though it passes every shape check")
    func nulByteIsRefusedDespitePassingShapeChecks() {
        let raw = "/tmp/m23ay-nul\u{0}injected"
        #expect(!raw.isEmpty)
        #expect(raw.hasPrefix("/"))
        guard case .refused(let reason) = resolve(raw, systemBase: resolvedSystemBase) else {
            Issue.record("a NUL-byte path must be refused")
            return
        }
        #expect(reason.contains("NUL"))
    }

    @Test("An empty value is refused with a message that says why it is not 'absent'")
    func emptyValueIsRefusedLoudly() {
        guard case .refused(let reason) = resolve("", systemBase: resolvedSystemBase) else {
            Issue.record("an empty override must be refused")
            return
        }
        #expect(reason.contains("EMPTY"))
        #expect(reason.contains("Unset"))
    }

    @Test("A path whose root is a regular file is refused (creation fails)")
    func regularFileRootIsRefused() throws {
        let file = tempFilePath("regular-file")
        try Data("not a directory".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let asRoot = resolve(file.path, systemBase: resolvedSystemBase)
        #expect(asRoot != .absent)
        guard case .refused = asRoot else {
            Issue.record("a regular file must not be accepted as a profile root, got \(asRoot)")
            return
        }
        let beneath = resolve(file.appendingPathComponent("child").path,
                              systemBase: resolvedSystemBase)
        #expect(beneath != .absent)
        guard case .refused = beneath else {
            Issue.record("a path under a regular file must be refused, got \(beneath)")
            return
        }
    }

    /// A root that exists but cannot be written to would send every save,
    /// autosave and recording to an error path — which reads in a log exactly
    /// like "the app is quiet", not like "the app is misconfigured".
    @Test("A read-only directory is refused")
    func unwritableRootIsRefused() throws {
        // Root ignores the permission bits, so this test would assert the
        // opposite of the truth if it ever ran as root.
        try #require(getuid() != 0, "not meaningful as root")
        let root = tempPath("read-only")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)

        let result = resolve(root.path, systemBase: resolvedSystemBase)
        #expect(result != .absent)
        guard case .refused(let reason) = result else {
            Issue.record("a read-only root must be refused, got \(result)")
            return
        }
        #expect(reason.contains("cannot write"))
    }

    /// The deceptive configuration: an override that names the base the process
    /// would have used anyway. It isolates nothing, but every log line, every
    /// gate assertion and every operator reading the launch command would say
    /// "isolated". Refused rather than accepted-as-a-no-op — unsetting the
    /// variable is the supported way to ask for the real profile.
    @Test("An override equal to the base this process would have used anyway is refused")
    func overrideEqualToTheRealBaseIsRefused() throws {
        let base = tempPath("would-have-used")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let sameResult = resolve(base.path, systemBase: base)
        #expect(sameResult != .absent)
        guard case .refused(let reason) = sameResult else {
            Issue.record("an override equal to the real base must be refused, got \(sameResult)")
            return
        }
        #expect(reason.contains("isolates nothing"))

        // Trailing slash is the same directory — a caller passing "$TMPDIR"
        // (which ends in one) must not sneak past by spelling.
        let trailing = resolve(base.path + "/", systemBase: base)
        guard case .refused = trailing else {
            Issue.record("a trailing slash must not defeat the same-base check, got \(trailing)")
            return
        }

        // A DIFFERENT root under the same parent is fine — the check must be
        // equality, not "anywhere near the real base", or nothing would pass.
        let sibling = base.deletingLastPathComponent()
            .appendingPathComponent("m23ay-sibling-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sibling) }
        guard case .root = resolve(sibling.path, systemBase: base) else {
            Issue.record("a sibling of the real base must still be accepted")
            return
        }
    }

    /// The real-profile spelling of the same check, asserted against THIS
    /// machine's actual base rather than a temp stand-in.
    @Test("Pointing the override at the machine's real Application Support base is refused")
    func overrideAtTheMachinesRealBaseIsRefused() throws {
        let base = try #require(resolvedSystemBase)
        let result = resolve(base.path, systemBase: base)
        #expect(result != .absent)
        guard case .refused = result else {
            Issue.record("the real base must be refused as an override, got \(result)")
            return
        }
    }
}
