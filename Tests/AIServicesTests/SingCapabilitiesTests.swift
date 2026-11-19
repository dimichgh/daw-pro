import Foundation
import Testing
@testable import AIServices
@testable import DAWCore

/// p2-sing-x7 part A: `SingCapabilities` (what `sing.capabilities` answers, design 2026-10-06 §6.9), and the DRIFT
/// GATE between the two homes of the language list: the app's `LyricLanguage` and the facade's `/health`
/// `capabilities.languages` (`scripts/sing/singlib/langs.py`, read here through the STUB on a test port, the way the
/// app's tests always reach the facade: never the real engine, never port 8004). Nonisolated.
@Suite("SingCapabilities — languages from LyricLanguage, engine facts from install.json, and the stub drift gate (p2-sing-x7)")
struct SingCapabilitiesTests {

    private func tempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sing-caps-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("no engine wired in: English, Mandarin, Cantonese (Spanish is out), all supported, no update verdict, engine nil")
    func headless() {
        let caps = SingCapabilities.read(files: nil, engineNeedsUpdate: true)
        #expect(caps.languages.map(\.code) == ["en", "zh", "yue"])
        #expect(caps.languages.map(\.name) == ["English", "Chinese (Mandarin)", "Chinese (Cantonese)"])
        #expect(caps.languages.allSatisfy { $0.status == "supported" && !$0.needsEngineUpdate })
        #expect(!caps.languages.contains { $0.code == "es" })
        #expect(caps.engine == nil)
        #expect(caps.maxParts == 3)
        #expect(caps.vibratoChoices == ["asSung", "straight", "gentle", "normal", "wide"])
        #expect(caps.airRange == 0...1)
    }

    @Test("install.json and pins.env give the version facts; the manager's needsUpdate marks every language but English")
    func engineFacts() throws {
        let runtime = try tempDir("runtime")
        let scripts = try tempDir("scripts")
        defer {
            try? FileManager.default.removeItem(at: runtime)
            try? FileManager.default.removeItem(at: scripts)
        }
        let files = SingEngineFiles(runtimeDir: runtime, scriptsDir: scripts)
        let missing = SingCapabilities.read(files: files, engineNeedsUpdate: false)
        #expect(missing.engine == .init(installed: false, scriptsVersion: nil, shippedScriptsVersion: nil,
                                        needsUpdate: false))

        try Data(#"{"scriptsVersion": 1, "facadeVersion": 1}"#.utf8).write(to: runtime.appendingPathComponent("install.json"))
        try Data("# pins\nSCRIPTS_VERSION=2\n".utf8).write(to: scripts.appendingPathComponent("pins.env"))
        let current = SingCapabilities.read(files: files, engineNeedsUpdate: false)
        #expect(current.engine == .init(installed: true, scriptsVersion: 1, shippedScriptsVersion: 2, needsUpdate: false))
        #expect(current.languages.allSatisfy { !$0.needsEngineUpdate })

        let stale = SingCapabilities.read(files: files, engineNeedsUpdate: true)
        #expect(stale.engine?.needsUpdate == true)
        #expect(stale.languages.map(\.needsEngineUpdate) == [false, true, true], "English is sung by every engine")
    }

    @Test("DRIFT GATE: the stub's /health capabilities.languages equals LyricLanguage's supported set (positive-controlled)")
    func stubLanguagesMatchLyricLanguage() async throws {
        let scripts = try #require(
            SingingSidecarManager.Configuration.resolveScriptsDir(environment: ProcessInfo.processInfo.environment),
            "scripts/sing could not be resolved from this test process")
        let stub = scripts.appendingPathComponent("stub_server.py")
        #expect(FileManager.default.fileExists(atPath: stub.path), "the stub must exist: \(stub.path)")
        let runtime = try tempDir("stub-runtime")
        defer { try? FileManager.default.removeItem(at: runtime) }
        let port = try StubACEStepServer.unusedLoopbackPort()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [stub.path, "--port", String(port), "--runtime", runtime.path]
        process.currentDirectoryURL = scripts
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment
        let log = runtime.appendingPathComponent("stub.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        defer {
            // Pid-exact: only the process this test started.
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            try? handle.close()
        }

        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        var languages: [String]?
        let deadline = Date().addingTimeInterval(20)
        while languages == nil, Date() < deadline, process.isRunning {
            if let (data, response) = try? await URLSession.shared.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let capabilities = object["capabilities"] as? [String: Any] {
                languages = capabilities["languages"] as? [String]
            } else {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        let stubLog = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let facade = try #require(languages, "the stub never answered /health with capabilities; its log: \(stubLog)")
        // Positive control: the facade's list is read, not empty, and holds English.
        #expect(facade.contains("en"))
        let app = Set(([LyricLanguage.english] + LyricLanguage.chinese).filter { LyricLanguage.isSupported($0) })
        #expect(Set(facade) == app, "facade \(facade) vs LyricLanguage \(app.sorted())")
        #expect(Set(SingCapabilities.read(files: nil, engineNeedsUpdate: false).languages.map(\.code)) == app)
    }
}
