import Foundation
import Testing
@testable import AIServices

/// p2-sing-h (W8-BSG): the singing engine's scripts ship inside the signed app. Nonisolated,
/// pure: the environment the launcher/installer hand to Python, and the scripts-dir override.
@Suite("SingBundle — sealed-bundle environment + scripts dir")
struct SingBundleResourcesTests {
    @Test("the sidecar's child environment forbids bytecode (a __pycache__ would break the seal)")
    func sidecarEnvironmentForbidsBytecode() {
        let env = SingingSidecarManager.Configuration.childEnvironment(
            base: ["PATH": "/usr/bin"], runtimeDir: "/rt", port: 18004, allowedRoots: "",
            logFile: nil, extra: [:])
        #expect(env["PYTHONDONTWRITEBYTECODE"] == "1")
    }

    @Test("an inherited PYTHONDONTWRITEBYTECODE=0 cannot re-enable bytecode in the sidecar")
    func sidecarEnvironmentOverridesInherited() {
        let env = SingingSidecarManager.Configuration.childEnvironment(
            base: ["PYTHONDONTWRITEBYTECODE": "0"], runtimeDir: "/rt", port: 18004, allowedRoots: "",
            logFile: nil, extra: [:])
        #expect(env["PYTHONDONTWRITEBYTECODE"] == "1")
    }

    @Test("the installer's child environment forbids bytecode")
    func installerEnvironmentForbidsBytecode() {
        let installer = SingingEngineInstaller(configuration: .init(
            scriptsDir: URL(fileURLWithPath: "/nonexistent"), runtimeDir: URL(fileURLWithPath: "/rt")))
        let env = installer.childEnvironment(base: ["PYTHONDONTWRITEBYTECODE": "0"],
                                             runtimeDir: URL(fileURLWithPath: "/rt"))
        #expect(env["PYTHONDONTWRITEBYTECODE"] == "1")
    }

    @Test("DAWPRO_SING_SCRIPTS_DIR wins over the repo and the bundle")
    func overrideWins() {
        let url = SingingSidecarManager.Configuration.resolveScriptsDir(
            environment: ["DAWPRO_SING_SCRIPTS_DIR": "/nonexistent/bundle/Contents/Resources/sing"])
        #expect(url?.path == "/nonexistent/bundle/Contents/Resources/sing")
    }

    // MARK: resolveScriptsDir order (override env -> repo walk-up -> bundle)

    private func makeTree() throws -> (root: URL, bundleResources: URL, repo: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sing-bundle-\(UUID().uuidString)")
        let resources = root.appendingPathComponent("X.app/Contents/Resources")
        let sing = resources.appendingPathComponent("sing")
        try FileManager.default.createDirectory(at: sing, withIntermediateDirectories: true)
        try Data().write(to: sing.appendingPathComponent("run.sh"))
        let repo = root.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent("Sources/x"), withIntermediateDirectories: true)
        try Data().write(to: repo.appendingPathComponent("Package.swift"))
        return (root, resources, repo)
    }

    @Test("no Package.swift above any anchor: the bundle's Contents/Resources/sing is used")
    func bundleUsedWhenNoRepo() throws {
        let t = try makeTree()
        defer { try? FileManager.default.removeItem(at: t.root) }
        // The anchor sits inside the .app (no Package.swift anywhere above it in the temp dir).
        let anchor = t.bundleResources.deletingLastPathComponent().appendingPathComponent("MacOS")
        let url = SingingSidecarManager.Configuration.resolveScriptsDir(
            environment: [:], anchors: [anchor], bundleResourceURLs: [t.bundleResources])
        #expect(url?.standardizedFileURL.path == t.bundleResources.appendingPathComponent("sing").standardizedFileURL.path)
    }

    @Test("a repo checkout among the anchors beats the bundle (order preserved)")
    func repoBeatsBundle() throws {
        let t = try makeTree()
        defer { try? FileManager.default.removeItem(at: t.root) }
        let url = SingingSidecarManager.Configuration.resolveScriptsDir(
            environment: [:], anchors: [t.repo.appendingPathComponent("Sources/x")],
            bundleResourceURLs: [t.bundleResources])
        #expect(url?.standardizedFileURL.path == t.repo.appendingPathComponent("scripts/sing").standardizedFileURL.path)
    }

    @Test("the override env still wins over both repo and bundle")
    func overrideBeatsRepoAndBundle() throws {
        let t = try makeTree()
        defer { try? FileManager.default.removeItem(at: t.root) }
        let url = SingingSidecarManager.Configuration.resolveScriptsDir(
            environment: ["DAWPRO_SING_SCRIPTS_DIR": "/nonexistent/override/sing"],
            anchors: [t.repo], bundleResourceURLs: [t.bundleResources])
        #expect(url?.path == "/nonexistent/override/sing")
    }
}
