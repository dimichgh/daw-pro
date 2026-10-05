import AVFAudio
import CryptoKit
import Foundation
import Testing

// `@testable` for `EffectDocument.effectDescriptor()`, the document mirror's
// own (internal) rebuild — the path `openProject` takes.
@testable import DAWCore
@testable import DAWEngine

// ⚠️ NON-ISOLATED SUITE, `@MainActor` ONLY ON THE TESTS THAT TOUCH THE STORE OR
// THE FACTORY (the `BitCrusherTests` shape): `MainActorOccupancySiteTests` Leg C
// counts main-actor SUITES against a cadence cap with one slot of slack.

/// m39-ac-2 — **THE CLIPPER'S NEW DEFAULT IS 1× AND NO SAVED PROJECT MAY HEAR IT.**
///
/// The user ruled on 2026-09-20 that a NEWLY ADDED clipper starts with
/// oversampling OFF. The clipper had shipped at 4×, in a pushed release, and a
/// shipped kind may not change tone — so an existing project with a clipper
/// must render byte-identically after the change.
///
/// ## Why this needs TWO instruments, and why the fixture is verbatim
///
/// The trap is in how a clipper is SAVED. Captured from the pre-ruling build on
/// 2026-09-24 (`store.addEffect(.clipper)` → `saveProject` → `project.json`):
/// **a clipper nobody touched is written as `{"id", "kind": "clipper"}` — NO
/// params object at all** (`addEffect` left `clipper` nil and `EffectDocument`
/// omits a nil one). It resolves through `EffectDescriptor.resolvedClipper`'s
/// fallback, so changing the DEFAULT would have silently changed every such
/// project. And a render byte gate is BLIND to a `Codable` decode default
/// (proven by a planted defect on 2026-09-20): hashes pinned over renders that
/// never decode the saved form cannot see a fallback move. So:
///
///  · **D1 DECODES** the document exactly as the old build wrote it, through
///    the real `ProjectBundle.read` → `runtimeState` path;
///  · **D2 RENDERS** what that decoded to, and compares against SHA-256s
///    CAPTURED FROM THE PRE-RULING BUILD, with a no-effect CONTROL hash so a
///    change in the surrounding code cannot be mistaken for a change here, and
///    an INVARIANCE CONTROL (the 1× render) proving the axis is not inert.
///
/// Then the forward half: D3/D4 prove a NEW clipper really is 1× — in the file,
/// on reopen, and in the DSP — and D5 that re-saving an old project does not
/// quietly rewrite its clipper.
@Suite("m39-ac-2 — a new clipper starts at 1×; a saved one keeps its 4×", .serialized)
struct ClipperDefaultOversamplingTests {

    // MARK: - The pre-ruling document, VERBATIM

    /// `project.json` as the PRE-RULING build wrote it (captured 2026-09-24 from
    /// the tree at `ed0d3ad`, `Effects.swift` untouched). Three clippers:
    ///  · track `effects[0]` — added, never touched: NO params object;
    ///  · track `effects[1]` — added, `driveDb` set to 6: all six keys written,
    ///    `oversampling` 4 among them (our encoder always writes all six);
    ///  · `masterEffects[0]` — added to the master chain, never touched.
    /// ⛔ Do not "tidy" this string. Its value is that nobody wrote it by hand.
    static let preRulingProjectJSON = #"""
    {
      "masterEffects" : [
        {
          "id" : "DD85F36D-7B3E-4DF4-9EEA-9471258D1F1A",
          "kind" : "clipper"
        }
      ],
      "masterVolume" : 1,
      "name" : "Pre",
      "savedAt" : "2026-09-24T07:39:23Z",
      "schemaVersion" : 1,
      "tracks" : [
        {
          "clips" : [

          ],
          "effects" : [
            {
              "id" : "7FD9C01B-28EF-414E-A3B1-14DF5A8F2424",
              "kind" : "clipper"
            },
            {
              "clipper" : {
                "ceilingDb" : -0.3,
                "driveDb" : 6,
                "mix" : 1,
                "mode" : 0,
                "outputDb" : 0,
                "oversampling" : 4
              },
              "id" : "B7513D69-22D8-47D1-A25F-9CE4A47163A3",
              "kind" : "clipper"
            }
          ],
          "id" : "207B4EB2-5874-4CFD-8C1A-1E6BEA8FF83B",
          "isAIGenerated" : false,
          "isArmed" : false,
          "isMuted" : false,
          "isSoloed" : false,
          "kind" : "audio",
          "name" : "Drums",
          "pan" : 0,
          "volume" : 1
        }
      ],
      "transport" : {
        "countInBars" : 1,
        "isLoopEnabled" : false,
        "isMetronomeEnabled" : false,
        "isPunchEnabled" : false,
        "loopEndBeat" : 16,
        "loopStartBeat" : 0,
        "positionBeats" : 0,
        "punchInBeat" : 0,
        "punchOutBeat" : 4,
        "tempoBPM" : 120,
        "timeSignature" : {
          "beatUnit" : 4,
          "beatsPerBar" : 4
        }
      }
    }
    """#

    static let untouchedTrackClipper = UUID(uuidString: "7FD9C01B-28EF-414E-A3B1-14DF5A8F2424")!
    static let touchedTrackClipper = UUID(uuidString: "B7513D69-22D8-47D1-A25F-9CE4A47163A3")!
    static let untouchedMasterClipper = UUID(uuidString: "DD85F36D-7B3E-4DF4-9EEA-9471258D1F1A")!

    /// ⚠️ **NOT FROM OUR ENCODER — a hand-made partial object**, the one shape
    /// that reaches `ClipperParams.init(from:)`'s `oversampling` fallback (our
    /// encoder always writes all six keys). A hand-edited file or another tool
    /// can produce it, and whatever wrote it meant a clipper running at 4×.
    static let partialObjectEffectJSON = #"""
    {"id": "0C0FFEE0-1111-2222-3333-444444444444", "kind": "clipper",
     "clipper": {"ceilingDb": -0.3, "driveDb": 6, "mix": 1, "mode": 0, "outputDb": 0}}
    """#

    // MARK: - The render, and the hashes captured from the pre-ruling build

    /// SHA-256 of `render(_:)` through each clipper, captured from the
    /// PRE-RULING build on 2026-09-24 (same machine, `./scripts/test.sh`
    /// debug configuration) — BEFORE any line of the ruling was written.
    enum PreRulingSHA {
        /// The untouched clipper (track AND master) — and, identically, an
        /// explicit `ClipperParams(oversampling: 4)`.
        static let untouched = "fcd7d3f0156eba32510b0cd9e79b0e4afcb2b5c3a6bf49bb341bceea03223018"
        /// The touched one: drive 6, oversampling 4.
        static let driveSixAtFour = "4630b5b658973b1b8779c89e0031b0a1473f7ec2465b2938335913442d5ba024"
        /// Every default but oversampling 1 — what a NEW clipper must render.
        static let explicitOne = "76f78b9c68d3cfa3485a03d9c5a68ff40c858b37d36a01c631351fca2f1fca81"
        /// No effect at all: the input itself. The CONTROL.
        static let noEffect = "140081d44a4158673a2c1b5bddccdcf5bd7a5c6ebdcc88d0006ac792f7792c1f"
    }

    /// A stereo signal that clips hard at the default settings (ceiling −0.3,
    /// drive 0): a 6.3 kHz tone — whose odd harmonics fold back, so the factor
    /// is audible in the bytes — plus a second tone per channel, under a slow
    /// swell that peaks well above full scale.
    static func signal(frames: Int, channel: Int) -> [Float] {
        (0..<frames).map { i in
            let t = Double(i) / 48_000
            let env = 0.35 + 0.95 * abs(sin(2 * Double.pi * 1.7 * t + Double(channel)))
            let a = sin(2 * Double.pi * 6_300 * t)
            let b = 0.45 * sin(2 * Double.pi * (1_100 + 37 * Double(channel)) * t)
            return Float(env * (a + b))
        }
    }

    static let frames = 24_000

    static func render(_ effect: ClipperEffect) throws -> [[Float]] {
        let chunk = 512
        let inputs = [signal(frames: frames, channel: 0), signal(frames: frames, channel: 1)]
        effect.prepare(sampleRate: 48_000, maxFramesPerQuantum: chunk, channelCount: 2)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format,
                                                   frameCapacity: AVAudioFrameCount(chunk)))
        var out: [[Float]] = [[], []]
        var offset = 0
        while offset < frames {
            let n = min(chunk, frames - offset)
            buffer.frameLength = AVAudioFrameCount(n)
            let data = try #require(buffer.floatChannelData)
            for c in 0..<2 { for f in 0..<n { data[c][f] = inputs[c][offset + f] } }
            effect.process(buffers: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
                           frameCount: n)
            for c in 0..<2 {
                out[c].append(contentsOf: UnsafeBufferPointer(start: data[c], count: n))
            }
            offset += n
        }
        return out
    }

    static func sha(_ channels: [[Float]]) -> String {
        var hasher = SHA256()
        for channel in channels {
            channel.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The factory is `@MainActor`; the cast happens INSIDE the hop because
    /// `any EffectRendering` is not `Sendable` (the `HallReverbTests` shape). A
    /// nil here IS the "factory built the wrong type" failure.
    static func instance(for descriptor: EffectDescriptor) async throws -> ClipperEffect {
        try #require(await MainActor.run {
            EffectFactory.makeInstance(for: descriptor) as? ClipperEffect
        }, "the factory did not build a ClipperEffect")
    }

    /// Writes `json` as a real `.dawproj` bundle and reads it back through the
    /// SAME path `openProject` uses.
    static func bundle(_ json: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m39-ac-2-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = ProjectBundle.normalizedBundleURL(
            fromPath: dir.appendingPathComponent("Pre").path)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: bundleURL.appendingPathComponent("project.json"),
                                  options: .atomic)
        return bundleURL
    }

    static func preRulingEffects() throws -> [UUID: EffectDescriptor] {
        let url = try bundle(preRulingProjectJSON)
        let runtime = try ProjectBundle.read(from: url).runtimeState(bundleURL: url)
        let all = runtime.tracks.flatMap(\.effects) + runtime.masterEffects
        return Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    }

    // MARK: - D1: THE DECODE

    @Test("D1 — a clipper saved before the ruling DECODES to 4×, through the real document path")
    func preRulingDocumentDecodesToFour() throws {
        let effects = try Self.preRulingEffects()
        #expect(effects.count == 3)
        for id in [Self.untouchedTrackClipper, Self.untouchedMasterClipper] {
            let effect = try #require(effects[id])
            #expect(effect.kind == .clipper)
            // The mechanism: the file carried no params, so none were decoded…
            #expect(effect.clipper == nil)
            // …and absence resolves to 4×, everywhere a reader asks.
            #expect(effect.resolvedClipper.oversampling == 4, Comment(rawValue:
                "an untouched pre-ruling clipper resolved to "
                + "\(effect.resolvedClipper.oversampling)× — every saved project with one "
                + "has just had its oversampling turned off"))
            #expect(effect.resolvedClipper == ClipperParams.legacy)
            #expect(effect.paramValue("oversampling") == 4,
                    "the card and fx.describe would show a setting the effect is not in")
        }
        let touched = try #require(effects[Self.touchedTrackClipper])
        #expect(touched.clipper?.oversampling == 4)
        #expect(touched.clipper?.driveDb == 6)

        // The partial object — the decode fallback's own case.
        let partial = try JSONDecoder().decode(EffectDocument.self,
                                               from: Data(Self.partialObjectEffectJSON.utf8))
        let partialDescriptor = try #require(partial.effectDescriptor())
        #expect(partialDescriptor.clipper?.oversampling == 4, Comment(rawValue:
            "a clipper object with no `oversampling` key decoded to "
            + "\(partialDescriptor.clipper?.oversampling ?? -1)× — absence must keep meaning 4×"))
        #expect(partialDescriptor.clipper?.driveDb == 6)
    }

    // MARK: - D2: THE RENDER

    @Test("D2 — the pre-ruling document RENDERS byte-identically to the pre-ruling build")
    func preRulingDocumentRendersIdentically() async throws {
        // ⭐ CONTROL FIRST. If the INPUT's bytes moved, nothing below can be
        // scored — say so rather than blame the clipper for it.
        let input = [Self.signal(frames: Self.frames, channel: 0),
                     Self.signal(frames: Self.frames, channel: 1)]
        try #require(Self.sha(input) == PreRulingSHA.noEffect,
                     "CANNOT SCORE: the fixture signal itself changed, so the pinned hashes no longer describe it")

        let effects = try Self.preRulingEffects()
        for (id, expected, label) in [
            (Self.untouchedTrackClipper, PreRulingSHA.untouched, "untouched track clipper"),
            (Self.untouchedMasterClipper, PreRulingSHA.untouched, "untouched master clipper"),
            (Self.touchedTrackClipper, PreRulingSHA.driveSixAtFour, "drive-6 clipper"),
        ] {
            let descriptor = try #require(effects[id])
            let rendered = try Self.render(try await Self.instance(for: descriptor))
            #expect(Self.sha(rendered) == expected, Comment(rawValue:
                "the \(label) from a pre-ruling project no longer renders what the "
                + "pre-ruling build rendered — a saved project has changed tone"))
        }

        // The partial object renders as the 4× clipper it describes.
        let partial = try JSONDecoder().decode(EffectDocument.self,
                                               from: Data(Self.partialObjectEffectJSON.utf8))
        let partialRender = try Self.render(
            try await Self.instance(for: try #require(partial.effectDescriptor())))
        #expect(Self.sha(partialRender) == PreRulingSHA.driveSixAtFour,
                "a partial clipper object (no oversampling key) no longer renders at 4×")

        // ⭐ INVARIANCE CONTROL: the factor is NOT inert on this signal. If 1×
        // rendered the same as 4×, every equality above would be vacuous.
        let one = try Self.render(ClipperEffect(params: ClipperParams(oversampling: 1)))
        #expect(Self.sha(one) == PreRulingSHA.explicitOne)
        #expect(PreRulingSHA.explicitOne != PreRulingSHA.untouched)
        var differing = 0
        let four = try Self.render(ClipperEffect(params: ClipperParams.legacy))
        for c in 0..<2 {
            for i in 0..<Self.frames where one[c][i].bitPattern != four[c][i].bitPattern {
                differing += 1
            }
        }
        #expect(differing > Self.frames, Comment(rawValue:
            "1× and 4× differ in only \(differing) of \(2 * Self.frames) samples — the "
            + "oversampling axis is barely exercised and the byte pins prove little"))
    }

    // MARK: - D3/D4: A NEW CLIPPER

    @Test("D3 — a NEW clipper is 1×, on a track and on the master, and WRITES its 1× into the file")
    @MainActor
    func newClipperIsOneAndSaysSoInTheFile() throws {
        let store = ProjectStore()
        let track = store.addTrack(name: "Drums", kind: .audio)
        let onTrack = try store.addEffect(toTrack: track.id, kind: .clipper)
        let onMaster = try store.addMasterEffect(kind: .clipper)
        for (label, effect) in [("track", onTrack), ("master", onMaster)] {
            // ⛔ EXPLICIT params, not nil: a nil would read as a pre-ruling 4×.
            #expect(effect.clipper != nil, "a new \(label) clipper carries no params")
            #expect(effect.clipper?.oversampling == 1)
            #expect(effect.resolvedClipper.oversampling == 1)
            #expect(effect.paramValue("oversampling") == 1)
        }
        // Touching another knob keeps the new default (the wire's `fx.add
        // {params}` path is exactly this: add, then setEffectParam per name).
        let tweaked = try store.setEffectParam(trackID: track.id, effectID: onTrack.id,
                                               name: "driveDb", value: 6)
        #expect(tweaked.clipper?.oversampling == 1)
        #expect(tweaked.clipper?.driveDb == 6)

        // ⭐ IN THE FILE, not implied by it — so no later default can move it.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m39-ac-2-new-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try store.saveProject(to: dir.appendingPathComponent("New").path)
        let jsonURL = URL(fileURLWithPath: try #require(store.projectPath))
            .appendingPathComponent("project.json")
        let document = try ProjectBundle.read(from: jsonURL.deletingLastPathComponent())
        let savedEffects = (document.tracks.first?.effects ?? []) + (document.masterEffects ?? [])
        #expect(savedEffects.count == 2)
        for saved in savedEffects {
            #expect(saved.clipper?.oversampling == 1,
                    "a new clipper was saved without an explicit oversampling of 1")
        }
        let text = try String(contentsOf: jsonURL, encoding: .utf8)
        #expect(text.contains("\"oversampling\" : 1"), "the 1 is not literally in project.json")

        // …and it comes back as 1.
        let reopened = ProjectStore()
        _ = try reopened.openProject(at: try #require(store.projectPath))
        let back = (reopened.tracks.first?.effects ?? []) + reopened.masterEffects
        #expect(back.count == 2)
        for effect in back { #expect(effect.resolvedClipper.oversampling == 1) }
    }

    @Test("D4 — a NEW clipper RENDERS at 1×, not merely reports it")
    func newClipperRendersAtOne() async throws {
        let descriptor = try await MainActor.run { () throws -> EffectDescriptor in
            let store = ProjectStore()
            let track = store.addTrack(name: "Drums", kind: .audio)
            return try store.addEffect(toTrack: track.id, kind: .clipper)
        }
        let rendered = try Self.render(try await Self.instance(for: descriptor))
        #expect(Self.sha(rendered) == PreRulingSHA.explicitOne,
                "a new clipper does not render what an explicit 1× clipper renders")
        #expect(Self.sha(rendered) != PreRulingSHA.untouched,
                "a new clipper still renders at the old 4× default")
    }

    // MARK: - D5: RE-SAVING AN OLD PROJECT

    /// ⛔ Opening an old project and saving it again must not quietly REWRITE
    /// its clipper — neither turn it off, nor pin it by growing a params
    /// object it never had (`EffectDocument`'s "pre-existing files never grow
    /// keys they didn't carry" rule).
    @Test("D5 — an old project opened and re-saved keeps its clipper exactly as it was written")
    @MainActor
    func oldProjectResavedKeepsItsClipper() throws {
        let bundleURL = try Self.bundle(Self.preRulingProjectJSON)
        let store = ProjectStore()
        _ = try store.openProject(at: bundleURL.path)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m39-ac-2-resave-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try store.saveProject(to: dir.appendingPathComponent("Resaved").path)
        let resaved = try ProjectBundle.read(
            from: URL(fileURLWithPath: try #require(store.projectPath)))
        let original = try ProjectBundle.read(from: bundleURL)

        let before = (original.tracks.first?.effects ?? []) + (original.masterEffects ?? [])
        let after = (resaved.tracks.first?.effects ?? []) + (resaved.masterEffects ?? [])
        #expect(after == before, "re-saving an old project rewrote its clipper entries")
        let untouched = try #require(after.first { $0.id == Self.untouchedTrackClipper })
        #expect(untouched.clipper == nil, "an untouched old clipper grew a params object")
        #expect(untouched.effectDescriptor()?.resolvedClipper.oversampling == 4)
    }
}
