import AVFAudio
import DAWCore
import DAWEngine
import Foundation
import Testing
@testable import DAWControl

/// m19-c/m19-d wire surface: `instrument.importSampleLibrary` — happy path
/// with snapshot readback of the mapped zone fields, dryRun leaving the
/// project byte-identical, every error shape (the .dslibrary unzip hint
/// verbatim), unknown-key rejection, undo reverting the journaled import,
/// a real `.dspreset` import over the wire (m19-d), and the E2E
/// offline-render gates for BOTH formats (the m17-e idiom: import →
/// clip.addMIDI → render.measureLoudness above silence). Reuses `FakeMedia`
/// from ControlTests.swift (same target).
@MainActor
@Suite("CommandRouter — sample-library import (m19-c/m19-d)")
struct SampleLibraryCommandTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("samplib-cmd-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func write(_ name: String, in dir: URL, _ text: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// 0.5 s Float32 WAV, amp 0.5, 44.1 kHz mono (the SamplerTests generated-
    /// sine idiom — no bundle resources). Scoped so AVAudioFile closes.
    private static func writeSine(to url: URL, frequency: Double) throws {
        let fileRate = 44_100.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: fileRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = Int(fileRate / 2)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: fileRate, channels: 1,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              let data = buffer.floatChannelData else {
            throw NSError(domain: "SampleLibraryCommandTests", code: 1)
        }
        for frame in 0..<frames {
            data[0][frame] = Float(0.5 * sin(2.0 * .pi * frequency * Double(frame) / fileRate))
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        try file.write(from: buffer)
    }

    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    private func importRequest(_ id: String, trackID: String, path: String,
                               extra: [String: JSONValue] = [:]) -> ControlRequest {
        var params: [String: JSONValue] = [
            "trackId": .string(trackID), "path": .string(path),
        ]
        for (key, value) in extra { params[key] = value }
        return ControlRequest(id: id, command: "instrument.importSampleLibrary",
                              params: params)
    }

    // 1.
    @Test("happy path: temp .sfz + generated WAVs apply, and the snapshot reads the mapped zone fields back")
    func happyPathSnapshotReadback() async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        let dir = tempDir()
        try Self.writeSine(to: dir.appendingPathComponent("soft.wav"), frequency: 300)
        try Self.writeSine(to: dir.appendingPathComponent("hard.wav"), frequency: 440)
        try write("piano.sfz", in: dir, """
        <group> lovel=0 hivel=63 volume=-6
        <region> sample=soft.wav lokey=c3 hikey=c5 pitch_keycenter=c4 pan=-50
        <group> lovel=64 hivel=127
        <region> sample=hard.wav lokey=c3 hikey=c5 pitch_keycenter=c4 ampeg_release=0.4
        """)

        let response = await router.handle(importRequest(
            "1", trackID: trackID, path: dir.appendingPathComponent("piano.sfz").path))
        #expect(response.ok, "import failed: \(response.error ?? "?")")
        #expect(response.result?["applied"]?.boolValue == true)
        let report = try #require(response.result?["report"])
        #expect(report["format"]?.stringValue == "sfz")
        #expect(report["zonesImported"]?.doubleValue == 2)
        #expect(report["groupCount"]?.doubleValue == 2)
        #expect(report["velocityLayerCount"]?.doubleValue == 2)
        #expect(report["degradations"]?.arrayValue?.isEmpty == true)

        // Snapshot readback: the mapped m19-a/b zone fields are LIVE.
        let snapshot = await router.handle(ControlRequest(id: "2", command: "project.snapshot"))
        let zones = try #require(
            snapshot.result?["tracks"]?.arrayValue?.first?["instrument"]?["sampler"]?["zones"]?.arrayValue)
        #expect(zones.count == 2)
        #expect(zones[0]["minVelocity"]?.doubleValue == 0)
        #expect(zones[0]["maxVelocity"]?.doubleValue == 63)
        #expect(zones[0]["group"]?.doubleValue == 1)
        #expect(zones[0]["pan"]?.doubleValue == -0.5)
        #expect(zones[0]["rootPitch"]?.doubleValue == 60)
        #expect(zones[0]["minPitch"]?.doubleValue == 48)
        #expect(zones[0]["maxPitch"]?.doubleValue == 72)
        let gain = try #require(zones[0]["gain"]?.doubleValue)
        #expect(abs(gain - 0.5012) < 0.001)                    // −6 dB → linear
        #expect(zones[1]["minVelocity"]?.doubleValue == 64)
        #expect(zones[1]["group"]?.doubleValue == 2)
        #expect(zones[1]["release"]?.doubleValue == 0.4)
        #expect(snapshot.result?["tracks"]?.arrayValue?.first?["instrument"]?["kind"]?.stringValue == "sampler")
    }

    // 2.
    @Test("dryRun computes the report and leaves the project snapshot byte-identical")
    func dryRunUntouched() async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        let dir = tempDir()
        try Self.writeSine(to: dir.appendingPathComponent("a.wav"), frequency: 440)
        try write("lib.sfz", in: dir, "<region> sample=a.wav lokey=10 hikey=20\n")

        let before = await router.handle(ControlRequest(id: "s1", command: "project.snapshot"))
        let response = await router.handle(importRequest(
            "1", trackID: trackID, path: dir.appendingPathComponent("lib.sfz").path,
            extra: ["dryRun": .bool(true)]))
        #expect(response.ok)
        #expect(response.result?["applied"]?.boolValue == false)
        #expect(response.result?["report"]?["zonesImported"]?.doubleValue == 1)
        let after = await router.handle(ControlRequest(id: "s2", command: "project.snapshot"))

        // Byte-equal snapshots: encode both results deterministically.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let beforeData = try encoder.encode(before.result)
        let afterData = try encoder.encode(after.result)
        #expect(beforeData == afterData)
    }

    // 3.
    @Test("undo reverts an applied import — it is one journaled Change Instrument edit")
    func undoRevertsImport() async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        let dir = tempDir()
        try Self.writeSine(to: dir.appendingPathComponent("a.wav"), frequency: 440)
        try write("lib.sfz", in: dir, "<region> sample=a.wav\n")

        let response = await router.handle(importRequest(
            "1", trackID: trackID, path: dir.appendingPathComponent("lib.sfz").path))
        #expect(response.ok)
        #expect(store.tracks[0].instrument?.kind == .sampler)

        let undo = await router.handle(ControlRequest(id: "2", command: "edit.undo"))
        #expect(undo.ok)
        #expect(store.tracks[0].instrument == nil)
    }

    // 4.
    @Test(".dslibrary errors with the unzip hint, verbatim")
    func dslibraryHint() async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        let dir = tempDir()
        let library = try write("Grand.dslibrary", in: dir, "zipbytes")

        let response = await router.handle(importRequest("1", trackID: trackID, path: library.path))
        #expect(!response.ok)
        #expect(response.error
            == ".dslibrary is a zip archive — unzip it and import the .dspreset inside")
    }

    // 5.
    @Test("wrong extension, malformed .dspreset XML, missing file, and relative path all refuse readably")
    func errorShapes() async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        let dir = tempDir()

        let exs = try write("Piano.exs", in: dir, "x")
        let wrongExt = await router.handle(importRequest("1", trackID: trackID, path: exs.path))
        #expect(!wrongExt.ok)
        #expect(wrongExt.error
            == "Piano.exs is not a sample library — this build imports .sfz (documented subset) and .dspreset sample-library files")

        let broken = try write("Broken.dspreset", in: dir, "<DecentSampler><groups>")
        let malformed = await router.handle(importRequest("2", trackID: trackID, path: broken.path))
        #expect(!malformed.ok)
        #expect(malformed.error?.hasPrefix("malformed .dspreset XML in ") == true)

        let missing = await router.handle(importRequest(
            "3", trackID: trackID, path: dir.appendingPathComponent("ghost.sfz").path))
        #expect(!missing.ok)
        #expect(missing.error?.hasPrefix("no sample library file at ") == true)

        let relative = await router.handle(importRequest(
            "4", trackID: trackID, path: "relative/lib.sfz"))
        #expect(!relative.ok)
        #expect(relative.error == "'path' must be an absolute path")
    }

    // 5b. — m19-d: the ".dspreset-not-yet" error flipped to a real import.
    @Test(".dspreset imports over the wire: dryRun reports without touching the project, apply lands the mapped zones")
    func dspresetImportsOverTheWire() async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        let dir = tempDir()
        try Self.writeSine(to: dir.appendingPathComponent("soft.wav"), frequency: 300)
        try Self.writeSine(to: dir.appendingPathComponent("hard.wav"), frequency: 440)
        try write("piano.dspreset", in: dir, """
        <DecentSampler>
          <groups>
            <group loVel="0" hiVel="63" volume="-6dB" pan="-50">
              <sample path="soft.wav" loNote="48" hiNote="72" rootNote="60"/>
            </group>
            <group loVel="64" hiVel="127" release="0.4">
              <sample path="hard.wav" loNote="48" hiNote="72" rootNote="60"/>
            </group>
          </groups>
        </DecentSampler>
        """)
        let path = dir.appendingPathComponent("piano.dspreset").path

        // dryRun: full report, project untouched.
        let dry = await router.handle(importRequest(
            "1", trackID: trackID, path: path, extra: ["dryRun": .bool(true)]))
        #expect(dry.ok, "dryRun failed: \(dry.error ?? "?")")
        #expect(dry.result?["applied"]?.boolValue == false)
        #expect(dry.result?["report"]?["format"]?.stringValue == "dspreset")
        #expect(dry.result?["report"]?["zonesImported"]?.doubleValue == 2)
        #expect(store.tracks[0].instrument == nil)

        // Apply: one journaled edit; the snapshot reads the zones back.
        let response = await router.handle(importRequest("2", trackID: trackID, path: path))
        #expect(response.ok, "import failed: \(response.error ?? "?")")
        #expect(response.result?["applied"]?.boolValue == true)
        let report = try #require(response.result?["report"])
        #expect(report["format"]?.stringValue == "dspreset")
        #expect(report["zonesImported"]?.doubleValue == 2)
        #expect(report["groupCount"]?.doubleValue == 2)
        #expect(report["velocityLayerCount"]?.doubleValue == 2)
        #expect(report["degradations"]?.arrayValue?.isEmpty == true)

        let snapshot = await router.handle(ControlRequest(id: "3", command: "project.snapshot"))
        let zones = try #require(
            snapshot.result?["tracks"]?.arrayValue?.first?["instrument"]?["sampler"]?["zones"]?.arrayValue)
        #expect(zones.count == 2)
        #expect(zones[0]["minVelocity"]?.doubleValue == 0)
        #expect(zones[0]["maxVelocity"]?.doubleValue == 63)
        #expect(zones[0]["group"]?.doubleValue == 1)
        #expect(zones[0]["pan"]?.doubleValue == -0.5)
        #expect(zones[0]["rootPitch"]?.doubleValue == 60)
        let gain = try #require(zones[0]["gain"]?.doubleValue)
        #expect(abs(gain - 0.5012) < 0.001)                    // −6 dB → linear
        #expect(zones[1]["minVelocity"]?.doubleValue == 64)
        #expect(zones[1]["group"]?.doubleValue == 2)
        #expect(zones[1]["release"]?.doubleValue == 0.4)
    }

    // 6.
    @Test("zero playable zones on apply errors with the skip summary; nothing lands")
    func zeroZonesOnApply() async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        let dir = tempDir()
        try Self.writeSine(to: dir.appendingPathComponent("a.wav"), frequency: 440)
        try write("rel.sfz", in: dir, "<region> sample=a.wav trigger=release\n")

        let response = await router.handle(importRequest(
            "1", trackID: trackID, path: dir.appendingPathComponent("rel.sfz").path))
        #expect(!response.ok)
        #expect(response.error?.contains("no playable zones") == true)
        #expect(response.error?.contains("trigger=release ×1") == true)
        #expect(store.tracks[0].instrument == nil)

        // dryRun on the SAME file still reports instead of erroring.
        let dry = await router.handle(importRequest(
            "2", trackID: trackID, path: dir.appendingPathComponent("rel.sfz").path,
            extra: ["dryRun": .bool(true)]))
        #expect(dry.ok)
        #expect(dry.result?["report"]?["skippedRegions"]?["trigger=release"]?.doubleValue == 1)
    }

    // 7.
    @Test("unknown keys are rejected, naming the verb and the valid keys")
    func unknownKeyRejection() async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        let response = await router.handle(importRequest(
            "1", trackID: trackID, path: "/tmp/x.sfz",
            extra: ["overwrite": .bool(true)]))
        #expect(!response.ok)
        #expect(response.error
            == "instrument.importSampleLibrary: unknown parameter 'overwrite' — valid keys are 'dryRun', 'force', 'path', 'trackId'")
    }

    // 8.
    @Test("preprocessor aborts (undefined $VAR) surface as readable wire errors")
    func preprocessorAbortSurfaces() async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        let dir = tempDir()
        try write("macro.sfz", in: dir, "<region> sample=$GHOST.wav\n")

        let response = await router.handle(importRequest(
            "1", trackID: trackID, path: dir.appendingPathComponent("macro.sfz").path))
        #expect(!response.ok)
        #expect(response.error?.contains("undefined SFZ macro $GHOST") == true)
    }

    // 9. — the m17-e E2E gate idiom, real engine, offline render.
    @Test("E2E: importSampleLibrary → clip.addMIDI → render.measureLoudness is above silence")
    func e2eRenderGate() async throws {
        let engine = AudioEngine()
        defer { engine.shutdown() }
        let store = ProjectStore()
        store.media = FakeMedia()
        store.engine = engine
        let router = CommandRouter(store: store)
        let trackID = store.addTrack(kind: .instrument).id.uuidString

        let dir = tempDir()
        try Self.writeSine(to: dir.appendingPathComponent("sine440.wav"), frequency: 440)
        try write("lib.sfz", in: dir,
                  "<region> sample=sine440.wav lokey=0 hikey=127 pitch_keycenter=a4\n")

        let imported = await router.handle(importRequest(
            "1", trackID: trackID, path: dir.appendingPathComponent("lib.sfz").path))
        #expect(imported.ok, "import failed: \(imported.error ?? "?")")

        let clip = await router.handle(ControlRequest(
            id: "2", command: "clip.addMIDI",
            params: [
                "trackId": .string(trackID),
                "lengthBeats": .number(4),
                "notes": .array([
                    .object(["pitch": .number(69), "startBeat": .number(0),
                             "lengthBeats": .number(2)]),
                ]),
            ]))
        #expect(clip.ok, "clip.addMIDI failed: \(clip.error ?? "?")")

        // LORE (m17-e): the measure window must START AT the note-on beat —
        // a mid-note window renders silence.
        let measure = await router.handle(ControlRequest(
            id: "3", command: "render.measureLoudness",
            params: ["fromBeat": .number(0), "durationSeconds": .number(1.0)]))
        #expect(measure.ok, "measureLoudness failed: \(measure.error ?? "?")")
        let lufs = measure.result?["measurement"]?["integratedLufs"]?.doubleValue
        // An EMPTY measurement object is the true-silence signature (below
        // the −70 LUFS gate) — the import must audibly sound.
        #expect(lufs != nil, "rendered silence — the imported sampler produced no signal")
        if let lufs { #expect(lufs > -70) }
    }

    // 10. — the m19-d E2E gate: the same chain through DSPresetParser.
    @Test("E2E: a .dspreset import → clip.addMIDI → render.measureLoudness is above silence")
    func e2eDSPresetRenderGate() async throws {
        let engine = AudioEngine()
        defer { engine.shutdown() }
        let store = ProjectStore()
        store.media = FakeMedia()
        store.engine = engine
        let router = CommandRouter(store: store)
        let trackID = store.addTrack(kind: .instrument).id.uuidString

        let dir = tempDir()
        try Self.writeSine(to: dir.appendingPathComponent("sine440.wav"), frequency: 440)
        try write("lib.dspreset", in: dir, """
        <DecentSampler>
          <groups>
            <group>
              <sample path="sine440.wav" loNote="0" hiNote="127" rootNote="69"/>
            </group>
          </groups>
        </DecentSampler>
        """)

        let imported = await router.handle(importRequest(
            "1", trackID: trackID, path: dir.appendingPathComponent("lib.dspreset").path))
        #expect(imported.ok, "import failed: \(imported.error ?? "?")")
        #expect(imported.result?["report"]?["format"]?.stringValue == "dspreset")

        let clip = await router.handle(ControlRequest(
            id: "2", command: "clip.addMIDI",
            params: [
                "trackId": .string(trackID),
                "lengthBeats": .number(4),
                "notes": .array([
                    .object(["pitch": .number(69), "startBeat": .number(0),
                             "lengthBeats": .number(2)]),
                ]),
            ]))
        #expect(clip.ok, "clip.addMIDI failed: \(clip.error ?? "?")")

        // LORE (m17-e): the measure window must START AT the note-on beat —
        // a mid-note window renders silence.
        let measure = await router.handle(ControlRequest(
            id: "3", command: "render.measureLoudness",
            params: ["fromBeat": .number(0), "durationSeconds": .number(1.0)]))
        #expect(measure.ok, "measureLoudness failed: \(measure.error ?? "?")")
        let lufs = measure.result?["measurement"]?["integratedLufs"]?.doubleValue
        #expect(lufs != nil, "rendered silence — the imported sampler produced no signal")
        if let lufs { #expect(lufs > -70) }
    }

    /// A real playable WAV (PCM16 mono 44.1 kHz sine) whose `smpl` chunk
    /// embeds one forward loop — the m20-g fallback fixture. Hand-built
    /// bytes: AVAudioFile reads it AND WAVSampleLoops sniffs the loop.
    private static func writeSmplSine(to url: URL, frequency: Double,
                                      loopStart: UInt32, loopEndIncl: UInt32) throws {
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        let fileRate = 44_100.0
        let frames = Int(fileRate / 2)
        var pcm = Data(capacity: frames * 2)
        for frame in 0..<frames {
            let value = 0.5 * sin(2.0 * .pi * frequency * Double(frame) / fileRate)
            pcm.append(le16(UInt16(bitPattern: Int16(value * 32_767))))
        }
        var smpl = Data()
        for _ in 0..<7 { smpl.append(le32(0)) }   // dwManufacturer...dwSMPTEOffset
        smpl.append(le32(1))                      // cSampleLoops
        smpl.append(le32(0))                      // cbSamplerData
        smpl.append(le32(0))                      // dwIdentifier
        smpl.append(le32(0))                      // dwType 0 = forward
        smpl.append(le32(loopStart))              // dwStart
        smpl.append(le32(loopEndIncl))            // dwEnd (inclusive)
        smpl.append(le32(0)); smpl.append(le32(0))  // dwFraction, dwPlayCount
        var body = Data("WAVE".utf8)
        body.append(Data("fmt ".utf8)); body.append(le32(16))
        body.append(le16(1)); body.append(le16(1))                   // PCM, mono
        body.append(le32(UInt32(fileRate))); body.append(le32(UInt32(fileRate) * 2))
        body.append(le16(2)); body.append(le16(16))                  // block align, bits
        body.append(Data("data".utf8)); body.append(le32(UInt32(pcm.count)))
        body.append(pcm)
        body.append(Data("smpl".utf8)); body.append(le32(UInt32(smpl.count)))
        body.append(smpl)
        var data = Data("RIFF".utf8)
        data.append(le32(UInt32(body.count)))
        data.append(body)
        try data.write(to: url)
    }

    /// 1.5 s Float32 WAV, 440 Hz amp 0.5, 44.1 kHz mono — the §8.3 loop
    /// fixture (66 150 frames; the loop span [4410, 48510) is 1.0 s).
    private static func writeLoopSine(to url: URL) throws {
        let fileRate = 44_100.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: fileRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = 66_150
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: fileRate, channels: 1,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              let data = buffer.floatChannelData else {
            throw NSError(domain: "SampleLibraryCommandTests", code: 2)
        }
        for frame in 0..<frames {
            data[0][frame] = Float(0.5 * sin(2.0 * .pi * 440.0 * Double(frame) / fileRate))
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        try file.write(from: buffer)
    }

    // 11. — m20-g §8.6: looped-SFZ E2E — the §5.2 report flip asserted
    //      exactly, then the loop proven audible past the file's natural end.
    @Test("E2E: a looped .sfz imports with the m20-g report flip and HOLDS past the file's natural end")
    func e2eLoopedSFZ() async throws {
        let engine = AudioEngine()
        defer { engine.shutdown() }
        let store = ProjectStore()
        store.media = FakeMedia()
        store.engine = engine
        let router = CommandRouter(store: store)
        let trackID = store.addTrack(kind: .instrument).id.uuidString

        let dir = tempDir()
        try Self.writeLoopSine(to: dir.appendingPathComponent("loop440.wav"))
        try Self.writeSine(to: dir.appendingPathComponent("plain440.wav"), frequency: 440)
        try Self.writeSmplSine(to: dir.appendingPathComponent("smpl440.wav"),
                               frequency: 440, loopStart: 4_410, loopEndIncl: 22_049)
        // r1: authored continuous loop with points (carries the render note);
        // r2: loop_sustain, no points, WAV without smpl; r3: no loop
        // anything; r4: no opcodes, WAV WITH an embedded smpl forward loop.
        try write("loop-fixture.sfz", in: dir, """
        <region> sample=loop440.wav lokey=60 hikey=80 pitch_keycenter=a4 loop_mode=loop_continuous loop_start=4410 loop_end=48509
        <region> sample=plain440.wav lokey=0 hikey=20 loop_mode=loop_sustain
        <region> sample=plain440.wav lokey=21 hikey=40
        <region> sample=smpl440.wav lokey=41 hikey=59
        """)

        let imported = await router.handle(importRequest(
            "1", trackID: trackID, path: dir.appendingPathComponent("loop-fixture.sfz").path))
        #expect(imported.ok, "import failed: \(imported.error ?? "?")")
        let report = try #require(imported.result?["report"])
        // The §5.2 report-flip table, asserted exactly:
        #expect(report["zonesImported"]?.doubleValue == 4)     // unchanged — loops never skip
        #expect(report["loopedZones"]?.doubleValue == 3)       // r1 + r2 + r4 (smpl fallback)
        #expect(report["skippedRegions"]?.objectValue?.isEmpty == true)
        let ignored = try #require(report["ignoredOpcodes"]?.objectValue)
        for key in ["loop_mode", "loop_start", "loop_end", "loopstart", "loopend"] {
            #expect(ignored[key] == nil, "'\(key)' must be consumed, not ignored")
        }
        let degradations = try #require(report["degradations"]?.arrayValue)
        #expect(!degradations.contains {
            $0.stringValue?.contains("looping") == true
        }, "no loop degradation sentences — loops play for real")

        // The zones carry the mapped loop fields (the +1 law on the wire).
        let snapshot = await router.handle(ControlRequest(id: "2", command: "project.snapshot"))
        let zones = try #require(
            snapshot.result?["tracks"]?.arrayValue?.first?["instrument"]?["sampler"]?["zones"]?.arrayValue)
        #expect(zones.count == 4)
        #expect(zones[0]["loopMode"]?.stringValue == "continuous")
        #expect(zones[0]["loopStart"]?.doubleValue == 4_410)
        #expect(zones[0]["loopEnd"]?.doubleValue == 48_510)    // 48509 inclusive + 1
        #expect(zones[1]["loopMode"]?.stringValue == "sustain")
        #expect(zones[1]["loopStart"] == nil)                  // engine resolves
        #expect(zones[2]["loopMode"] == nil)                   // no loop anything
        #expect(zones[3]["loopMode"]?.stringValue == "continuous")  // smpl fallback
        #expect(zones[3]["loopStart"]?.doubleValue == 4_410)
        #expect(zones[3]["loopEnd"]?.doubleValue == 22_050)    // dwEnd 22049 inclusive + 1

        // The §8.3 criterion at reduced length: hold the 1.5 s fixture for
        // 4 s (8 beats at 120 BPM), mixdown 0–4 s to a temp wav, and assert
        // the 3–4 s WINDOW still sounds — the un-looped file exhausts at
        // 1.5 s. (The m17-e LORE forbids a mid-note measureLoudness window —
        // the offline render starts at fromBeat and never delivers earlier
        // note-ons — so the window proof reads the rendered wav directly.)
        let clip = await router.handle(ControlRequest(
            id: "3", command: "clip.addMIDI",
            params: [
                "trackId": .string(trackID),
                "lengthBeats": .number(8),
                "notes": .array([
                    .object(["pitch": .number(69), "startBeat": .number(0),
                             "lengthBeats": .number(8)]),
                ]),
            ]))
        #expect(clip.ok, "clip.addMIDI failed: \(clip.error ?? "?")")
        let mixPath = dir.appendingPathComponent("loop-mix.wav").path
        let mixdown = await router.handle(ControlRequest(
            id: "4", command: "render.mixdown",
            params: ["path": .string(mixPath),
                     "fromBeat": .number(0), "durationSeconds": .number(4.0)]))
        #expect(mixdown.ok, "mixdown failed: \(mixdown.error ?? "?")")
        let renderRate = try #require(mixdown.result?["sampleRate"]?.doubleValue)
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: mixPath))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?[0])
        let window = Int(3.0 * renderRate)..<min(Int(4.0 * renderRate),
                                                 Int(buffer.frameLength))
        var sum = 0.0
        for frame in window { sum += Double(channel[frame]) * Double(channel[frame]) }
        let windowRMS = (sum / Double(window.count)).squareRoot()
        #expect(windowRMS > 0.1,
                "silence at 3–4 s — the imported loop did not hold past the file's natural end")
        print("[measured] looped-SFZ E2E — 3–4 s window RMS: \(windowRMS) "
              + "(un-looped file exhausts at 1.5 s)")
    }
}
