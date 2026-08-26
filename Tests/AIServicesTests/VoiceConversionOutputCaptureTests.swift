import Foundation
import Testing
@testable import AIServices

/// m23-fp — the RVC facade overwrites its own output within a wall-clock
/// second, so a returned `outputPath` is not a promise about the bytes on disk.
///
/// **What makes these tests able to SEE the defect.** A stub sidecar answers
/// every `POST /v1/voice/convert` with the SAME `outputPath` — the real
/// collision shape, which the live facade only produces by luck of timing —
/// and the test rewrites the file at that path between conversions, exactly as
/// the facade would. Before the fix the client returned that shared path
/// verbatim, so all three "results" aliased onto whichever bytes were written
/// last; that is precisely how a 12-rep timing run at m23-fo-1 read as a flat,
/// healthy curve while measuring one file three times.
///
/// ⚠️ Contents are asserted BYTE-IDENTICAL to what the stub wrote, not merely
/// "different from each other". Distinct paths prove nothing here — the whole
/// defect is content being overwritten while the paths looked fine.
///
/// ⚠️ Scope: these payloads are marker bytes, not audio. Nothing here converts
/// a voice, loads MLX, or spawns a process; this suite proves the capture and
/// the naming, never that a conversion sounds right.
private func makeClient(port: UInt16, captureDirectory: URL) -> VoiceConversionClient {
    VoiceConversionClient(
        configuration: .init(
            baseURL: URL(string: "http://127.0.0.1:\(port)")!,
            captureDirectory: captureDirectory))
}

/// A scratch directory that cleans itself up.
private func makeScratch() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("m23fp-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// The facade's convert response, with `outputPath` under our control.
private func convertResponse(outputPath: String) -> Data {
    StubACEStepServer.jsonResponse("""
        {"outputPath":"\(outputPath)","voiceId":"base","inputSeconds":1.5,\
        "engineLoadSeconds":0.25,"inferSeconds":0.4,"rtf":3.75,"sampleRate":40000,\
        "realConversion":false,"note":"smoke target"}
        """)
}

@Suite("VoiceConversionClient.convert — the m23-fp output collision")
struct VoiceConversionCollisionTests {

    /// THE REDDEN TEST. Three conversions, one sidecar path, three different
    /// payloads written at that path — the exact shape of the shipped defect.
    @Test("three conversions colliding on ONE sidecar path -> three distinct, byte-exact captures")
    func collidingSidecarPathsProduceDistinctCaptures() async throws {
        let scratch = makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let captureDirectory = scratch.appendingPathComponent("captures", isDirectory: true)
        // ONE path, reused by every conversion — `server.py:326` builds its name
        // from a one-second timestamp plus voiceId, pid and thread id, every one
        // of which is constant inside a second.
        let collidingPath = scratch.appendingPathComponent("convert-20260810T120000Z-base-1-1.wav")

        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        // One queued response repeats for every further call (the stub's
        // documented behaviour), so all three conversions are answered with the
        // same outputPath.
        server.enqueue(convertResponse(outputPath: collidingPath.path),
                       forKey: "POST /v1/voice/convert")

        let client = makeClient(port: server.port, captureDirectory: captureDirectory)
        let payloads = ["FIRST-conversion".data(using: .utf8)!,
                        "SECOND-conversion".data(using: .utf8)!,
                        "THIRD-conversion".data(using: .utf8)!]
        var results: [VoiceConvertResult] = []
        for payload in payloads {
            // The facade writing (and overwriting) its output, then answering.
            try payload.write(to: collidingPath)
            results.append(
                try await client.convert(
                    VoiceConvertRequest(inputPath: "/tmp/source.wav", voiceId: "base")))
        }

        // 1. The sidecar really did collide — otherwise this test would be
        //    proving nothing (its own negative control).
        #expect(Set(results.map(\.sidecarOutputPath)).count == 1,
                "the stub must reuse ONE sidecar path, or this test cannot see the defect")
        #expect(results.allSatisfy { $0.sidecarOutputPath == collidingPath.path })

        // 2. Our paths are distinct and are NOT the sidecar's.
        let ourPaths = results.map(\.outputPath)
        #expect(Set(ourPaths).count == 3, "\(ourPaths)")
        #expect(ourPaths.allSatisfy { $0 != collidingPath.path })

        // 3. THE ASSERTION THAT MATTERS: byte-exact, unoverwritten content —
        //    capture N holds what the facade wrote for conversion N.
        for (index, result) in results.enumerated() {
            let captured = try Data(contentsOf: URL(fileURLWithPath: result.outputPath))
            #expect(captured == payloads[index],
                    "capture \(index) holds \(String(data: captured, encoding: .utf8) ?? "?")")
        }

        // 4. And the sidecar's own file still holds only the LAST payload —
        //    the content the pre-fix client would have handed back three times.
        #expect(try Data(contentsOf: collidingPath) == payloads[2])
    }

    @Test("every capture lands INSIDE the configured capture directory")
    func capturesLandInTheCaptureDirectory() async throws {
        let scratch = makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let captureDirectory = scratch.appendingPathComponent("captures", isDirectory: true)
        let sidecarFile = scratch.appendingPathComponent("out.wav")
        try Data("payload".utf8).write(to: sidecarFile)

        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(convertResponse(outputPath: sidecarFile.path),
                       forKey: "POST /v1/voice/convert")

        let result = try await makeClient(port: server.port, captureDirectory: captureDirectory)
            .convert(VoiceConvertRequest(inputPath: "/tmp/source.wav", voiceId: "base"))

        let captured = URL(fileURLWithPath: result.outputPath)
        #expect(captured.deletingLastPathComponent().standardizedFileURL
                == captureDirectory.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: result.outputPath))
    }

    /// COPY, never move: a sidecar started by hand answers with a path inside
    /// the read-only `scripts/rvc/` fence, where a move would be a delete.
    @Test("the sidecar's own file is left completely alone (copy, never move)")
    func sourceSurvivesUntouched() async throws {
        let scratch = makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let sidecarFile = scratch.appendingPathComponent("out.wav")
        try Data("original".utf8).write(to: sidecarFile)
        let attributesBefore = try FileManager.default.attributesOfItem(atPath: sidecarFile.path)

        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(convertResponse(outputPath: sidecarFile.path),
                       forKey: "POST /v1/voice/convert")

        _ = try await makeClient(
            port: server.port,
            captureDirectory: scratch.appendingPathComponent("captures", isDirectory: true)
        ).convert(VoiceConvertRequest(inputPath: "/tmp/source.wav", voiceId: "base"))

        #expect(FileManager.default.fileExists(atPath: sidecarFile.path))
        #expect(try Data(contentsOf: sidecarFile) == Data("original".utf8))
        let attributesAfter = try FileManager.default.attributesOfItem(atPath: sidecarFile.path)
        #expect(attributesBefore[.modificationDate] as? Date
                == attributesAfter[.modificationDate] as? Date)
    }

    /// A conversion whose output cannot be captured must FAIL, loudly. The
    /// tempting fallback — return the sidecar's path anyway — is the defect.
    @Test("a vanished sidecar file throws outputCaptureFailed, never a silent passthrough")
    func missingSourceThrows() async throws {
        let scratch = makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let missing = scratch.appendingPathComponent("never-written.wav")

        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(convertResponse(outputPath: missing.path),
                       forKey: "POST /v1/voice/convert")

        let client = makeClient(
            port: server.port,
            captureDirectory: scratch.appendingPathComponent("captures", isDirectory: true))
        do {
            let result = try await client.convert(
                VoiceConvertRequest(inputPath: "/tmp/source.wav", voiceId: "base"))
            Issue.record("expected a throw, got outputPath \(result.outputPath)")
        } catch let error as VoiceConversionError {
            guard case .outputCaptureFailed(let detail) = error else {
                Issue.record("expected .outputCaptureFailed, got \(error)")
                return
            }
            #expect(detail.contains(missing.path))
        }
    }

    /// A throwing capture must still hand the convert gate back, or the client
    /// deadlocks for the rest of the process's life.
    @Test("a failed capture releases the convert gate — the next conversion still runs")
    func failedCaptureReleasesTheGate() async throws {
        let scratch = makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let captureDirectory = scratch.appendingPathComponent("captures", isDirectory: true)
        let missing = scratch.appendingPathComponent("never-written.wav")
        let real = scratch.appendingPathComponent("real.wav")
        try Data("real payload".utf8).write(to: real)

        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(convertResponse(outputPath: missing.path), forKey: "POST /v1/voice/convert")
        server.enqueue(convertResponse(outputPath: real.path), forKey: "POST /v1/voice/convert")

        let client = makeClient(port: server.port, captureDirectory: captureDirectory)
        await #expect(throws: VoiceConversionError.self) {
            _ = try await client.convert(
                VoiceConvertRequest(inputPath: "/tmp/source.wav", voiceId: "base"))
        }
        let second = try await client.convert(
            VoiceConvertRequest(inputPath: "/tmp/source.wav", voiceId: "base"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: second.outputPath))
                == Data("real payload".utf8))
    }
}

@Suite("VoiceConversionClient.convert — one conversion at a time (m23-fp gate)")
struct VoiceConversionGateTests {

    /// The gate's ONE claim, measured rather than timed: no conversion may be
    /// issued while an earlier output is still uncaptured. `maxConvertsInFlight`
    /// counts overlap between "POST issued" and "output captured", so this is
    /// deterministic — `1` exactly, not "usually 1". Without the gate an actor
    /// is re-entrant across its network `await` and this reads 4.
    @Test("four CONCURRENT conversions never overlap — max in flight is exactly 1")
    func concurrentConversionsAreSerialised() async throws {
        let scratch = makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let captureDirectory = scratch.appendingPathComponent("captures", isDirectory: true)
        let sidecarFile = scratch.appendingPathComponent("out.wav")
        try Data("payload".utf8).write(to: sidecarFile)

        let server = StubACEStepServer()
        try server.start()
        defer { server.stop() }
        server.enqueue(convertResponse(outputPath: sidecarFile.path),
                       forKey: "POST /v1/voice/convert")

        let client = makeClient(port: server.port, captureDirectory: captureDirectory)
        let paths = await withTaskGroup(of: String?.self) { group -> [String] in
            for _ in 0..<4 {
                group.addTask {
                    try? await client.convert(
                        VoiceConvertRequest(inputPath: "/tmp/source.wav", voiceId: "base")
                    ).outputPath
                }
            }
            var collected: [String] = []
            for await path in group { if let path { collected.append(path) } }
            return collected
        }

        #expect(paths.count == 4, "all four conversions must complete: \(paths)")
        #expect(Set(paths).count == 4, "each conversion gets its OWN capture: \(paths)")
        #expect(await client.maxConvertsInFlight == 1,
                "a second conversion was issued before an earlier output was captured")
    }
}

@Suite("VoiceConversionOutput — capture naming (m23-fp, pure)")
struct VoiceConversionOutputNamingTests {

    /// `voiceId` reaches this name straight off the wire — `vc.convertVocals`
    /// deliberately does not validate it (the facade's own teaching errors are
    /// meant to reach the caller verbatim). So a hostile id must not be able to
    /// steer the capture out of its directory.
    @Test("a path-traversal voiceId cannot escape the capture directory")
    func traversalVoiceIdCannotEscape() throws {
        let scratch = makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let captureDirectory = scratch.appendingPathComponent("captures", isDirectory: true)
        let source = scratch.appendingPathComponent("out.wav")
        try Data("payload".utf8).write(to: source)

        let captured = try VoiceConversionOutput.capture(
            sidecarPath: source.path, voiceId: "../../escape", sequence: 1,
            into: captureDirectory)

        #expect(captured.deletingLastPathComponent().standardizedFileURL
                == captureDirectory.standardizedFileURL)
        #expect(!captured.lastPathComponent.contains(".."))
        #expect(!captured.lastPathComponent.contains("/"))
    }

    @Test("names are unique even when voiceId AND sequence are identical")
    func uniquenessDoesNotDependOnVoiceIdOrSequence() {
        let names = (0..<500).map { _ in
            VoiceConversionOutput.captureFileName(
                voiceId: "base", sequence: 7, unique: UUID().uuidString, pathExtension: "wav")
        }
        #expect(Set(names).count == 500)
    }

    /// The teaching point of the whole item: the facade's name LOOKED unique
    /// because it carried a timestamp, and every field in it was constant.
    /// Uniqueness here comes from one place and one place only.
    @Test("the same `unique` reproduces the same name — nothing else is load-bearing")
    func nameIsPureInItsUniqueArgument() {
        let first = VoiceConversionOutput.captureFileName(
            voiceId: "base", sequence: 1, unique: "FIXED-UNIQUE", pathExtension: "wav")
        let second = VoiceConversionOutput.captureFileName(
            voiceId: "base", sequence: 1, unique: "FIXED-UNIQUE", pathExtension: "wav")
        #expect(first == second)
        #expect(first.contains("FIXED-UNIQUE"))
    }

    @Test("the sequence is zero-padded, so a listing sorts in conversion order")
    func sequenceIsZeroPadded() {
        let names = [1, 2, 10].map {
            VoiceConversionOutput.captureFileName(
                voiceId: "base", sequence: $0, unique: "u", pathExtension: "wav")
        }
        #expect(names[0].contains("convert-000001-"))
        #expect(names[2].contains("convert-000010-"))
        #expect(names.sorted() == names, "\(names)")
    }

    @Test("the source's extension is preserved; a missing one becomes wav")
    func extensionHandling() {
        #expect(VoiceConversionOutput.captureFileName(
            voiceId: "v", sequence: 1, unique: "u", pathExtension: "flac").hasSuffix(".flac"))
        #expect(VoiceConversionOutput.captureFileName(
            voiceId: "v", sequence: 1, unique: "u", pathExtension: "").hasSuffix(".wav"))
    }

    @Test("a voiceId that sanitises away to nothing falls back, never to an empty component")
    func emptyVoiceIdFallsBack() {
        let name = VoiceConversionOutput.captureFileName(
            voiceId: "///", sequence: 1, unique: "u", pathExtension: "wav")
        #expect(name == "convert-000001-voice-u.wav")
    }

    @Test("a very long voiceId is truncated, so the name stays a legal path component")
    func longVoiceIdIsTruncated() {
        let name = VoiceConversionOutput.captureFileName(
            voiceId: String(repeating: "a", count: 500), sequence: 1, unique: "u",
            pathExtension: "wav")
        #expect(name.count < 100, "\(name)")
    }
}

@Suite("VoiceConversionOutput — capture copies bytes (m23-fp)")
struct VoiceConversionOutputCaptureFileTests {

    @Test("the capture is byte-identical to the source")
    func captureIsByteIdentical() throws {
        let scratch = makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("out.wav")
        // Bytes that would survive a naive text comparison but not a truncated
        // copy: NULs, high bytes, and a length that is not a round number.
        let payload = Data((0..<4097).map { UInt8($0 % 256) })
        try payload.write(to: source)

        let captured = try VoiceConversionOutput.capture(
            sidecarPath: source.path, voiceId: "base", sequence: 1,
            into: scratch.appendingPathComponent("captures", isDirectory: true))

        #expect(try Data(contentsOf: captured) == payload)
    }

    @Test("the capture directory is created on demand")
    func createsTheDirectory() throws {
        let scratch = makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("out.wav")
        try Data("payload".utf8).write(to: source)
        let nested = scratch.appendingPathComponent("a/b/c", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: nested.path))

        let captured = try VoiceConversionOutput.capture(
            sidecarPath: source.path, voiceId: "base", sequence: 1, into: nested)

        #expect(FileManager.default.fileExists(atPath: captured.path))
    }

    /// Structurally unreachable with a real UUID, which is exactly why it must
    /// throw rather than overwrite: an overwrite here would silently reproduce
    /// the defect being fixed.
    @Test("a name collision REFUSES to overwrite")
    func refusesToOverwrite() throws {
        let scratch = makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("out.wav")
        try Data("second".utf8).write(to: source)
        let captureDirectory = scratch.appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        let occupied = captureDirectory.appendingPathComponent(
            VoiceConversionOutput.captureFileName(
                voiceId: "base", sequence: 1, unique: "FIXED", pathExtension: "wav"))
        try Data("first".utf8).write(to: occupied)

        #expect(throws: VoiceConversionError.self) {
            _ = try VoiceConversionOutput.capture(
                sidecarPath: source.path, voiceId: "base", sequence: 1,
                into: captureDirectory, unique: "FIXED")
        }
        #expect(try Data(contentsOf: occupied) == Data("first".utf8))
    }
}

@Suite("VoiceConversionOutput — the directories are app-owned (m23-fp)")
struct VoiceConversionOutputDirectoryTests {

    @Test("both directories are under the app's own Application Support home")
    func directoriesAreAppOwned() {
        #expect(VoiceConversionOutput.directory.path.contains("/DAWPro/VoiceConversions"))
        #expect(VoiceConversionOutput.sidecarOutputDirectory.deletingLastPathComponent()
                .standardizedFileURL == VoiceConversionOutput.directory.standardizedFileURL)
    }

    /// The second thing this item fixes: before it, every shipped conversion
    /// wrote its wav into `scripts/rvc/runtime/out/` — inside the read-only
    /// fence — because nothing set `RVC_OUT_DIR`.
    @Test("neither directory is inside the read-only scripts/rvc fence")
    func directoriesAreOutsideTheFence() {
        #expect(!VoiceConversionOutput.directory.path.contains("scripts/rvc"))
        #expect(!VoiceConversionOutput.sidecarOutputDirectory.path.contains("scripts/rvc"))
    }

    /// Reading the rule must not materialise it — the facade `mkdir`s
    /// `RVC_OUT_DIR` itself, and the capture home appears on first capture.
    @Test("reading the paths creates nothing on disk")
    func readingCreatesNothing() {
        // "unchanged", not "absent": this machine may already have them from
        // real use, and an assertion that only holds on a fresh machine is not
        // an assertion.
        let manager = FileManager.default
        let before = [
            manager.fileExists(atPath: VoiceConversionOutput.directory.path),
            manager.fileExists(atPath: VoiceConversionOutput.sidecarOutputDirectory.path),
        ]
        _ = VoiceConversionOutput.directory
        _ = VoiceConversionOutput.sidecarOutputDirectory
        #expect(manager.fileExists(atPath: VoiceConversionOutput.directory.path) == before[0])
        #expect(manager.fileExists(atPath: VoiceConversionOutput.sidecarOutputDirectory.path)
                == before[1])
    }
}
