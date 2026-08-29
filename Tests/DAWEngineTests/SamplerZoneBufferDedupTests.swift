import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m32-a — the sampler zone loader deduplicates decoded sample memory by
/// `SamplerZone.sourceFileKey`, so N zones on ONE file hold ONE file's bytes.
///
/// ⭐⭐ THIS GATE IS TWO-DIRECTIONAL AND THE SECOND HALF IS AN ALWAYS-ON
/// POSITIVE CONTROL. `sixteenZonesOneStereoFileHoldOneCopy` proves the dedup
/// works; `eightZonesEightFilesHoldEightCopies` proves the INSTRUMENT CAN
/// STILL SEE ALLOCATIONS. A seam that reported "one file's bytes"
/// unconditionally — or measured the wrong thing entirely — passes the first
/// and fails the second. A gate that can only ever go green in one direction
/// has not been controlled.
///
/// Every assertion reads the ALLOCATION LEDGER (`ownedChannelBuffers`) or a
/// zone's actual base pointers. Nothing here trusts a return value: the
/// loader cannot report bytes it did not allocate.
@MainActor
@Suite("Sampler zone buffer dedup (m32-a)", .serialized)
struct SamplerZoneBufferDedupTests {
    private let graphRate = 48_000.0
    /// ≈ 0.511 s @ 44.1 kHz. Every fixture in this suite is this long, so the
    /// N× arithmetic in the positive control is exact.
    ///
    /// ⚠️ 22 528 = 22 × 1024, and the 1024 is NOT cosmetic. MEASURED on this
    /// machine: a single `AVAudioFile.read(into:)` on a MONO float32 WAV
    /// short-reads — it stops on a whole 4096-BYTE boundary, so a 22 050-frame
    /// mono file yields 21 504 frames from one call (a second call returns the
    /// remainder). Stereo files of the same lengths read fully.
    /// `SamplerInstrument.init` issues exactly ONE read, so a mono fixture
    /// whose byte count is not page-aligned loads short and every byte
    /// assertion here would be off by the truncation rather than by the thing
    /// under test. A frame count that is a multiple of 1024 is page-aligned at
    /// BOTH 4 B/frame (mono) and 8 B/frame (stereo), so this suite measures
    /// dedup and nothing else. (The short read itself is a pre-existing loader
    /// defect, out of scope for m32-a — reported separately.)
    private static let fixtureFrames = 22_528
    private static let fixtureRate = 44_100.0
    /// One STEREO copy: 2 channels × 22 528 frames × 4 B = 180 224 B.
    private static var stereoFileBytes: Int { 2 * fixtureFrames * MemoryLayout<Float>.size }
    /// One MONO copy: 1 channel × 22 528 frames × 4 B = 90 112 B.
    private static var monoFileBytes: Int { fixtureFrames * MemoryLayout<Float>.size }

    // MARK: - Fixtures

    private struct Fixtures {
        let dir: URL
        /// 0.5 s @ 44.1 kHz STEREO, L = 220 Hz, R = 330 Hz (distinguishable
        /// channels, so a left/right mix-up cannot hide).
        let stereo: URL
        /// A byte-identical SECOND COPY of `stereo` at a different path — the
        /// non-deduped control for the render-equality test.
        let stereoCopy: URL
        /// `<dir>/sub/../stereoA.wav`: a different SPELLING of `stereo`.
        /// `sub/` is really created so a cache MISS would still open cleanly —
        /// under the implementation-time plant this test must redden on the
        /// ALLOCATION COUNT, not on a failed open.
        let stereoDotDot: URL
        /// 0.5 s @ 44.1 kHz MONO — the `:511` right-aliases-left regression pin.
        let mono: URL
        /// 8 DISTINCT stereo files, all `fixtureFrames` long.
        let eight: [URL]
    }

    private static var cachedFixtures: Fixtures?

    private func fixtures() throws -> Fixtures {
        if let cached = Self.cachedFixtures { return cached }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-m32a-dedup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)

        let stereo = dir.appendingPathComponent("stereoA.wav")
        try Self.writeStereo(to: stereo, leftHz: 220, rightHz: 330)
        let stereoCopy = dir.appendingPathComponent("stereoA-copy.wav")
        try Self.writeStereo(to: stereoCopy, leftHz: 220, rightHz: 330)
        let mono = dir.appendingPathComponent("monoA.wav")
        try Self.writeMono(to: mono, hz: 440)

        var eight: [URL] = []
        for index in 0..<8 {
            let url = dir.appendingPathComponent("eight-\(index).wav")
            // Distinct CONTENT as well as distinct paths, so nothing can
            // coalesce them by accident.
            try Self.writeStereo(to: url, leftHz: 200 + Double(index) * 10,
                                 rightHz: 300 + Double(index) * 10)
            eight.append(url)
        }

        let set = Fixtures(
            dir: dir, stereo: stereo, stereoCopy: stereoCopy,
            stereoDotDot: URL(fileURLWithPath: dir.path + "/sub/../stereoA.wav"),
            mono: mono, eight: eight)
        Self.cachedFixtures = set
        return set
    }

    private static func writeStereo(to url: URL, leftHz: Double, rightHz: Double) throws {
        try write(to: url, channels: 2) { channel, frame in
            let hz = channel == 0 ? leftHz : rightHz
            return 0.5 * sin(2.0 * .pi * hz * Double(frame) / fixtureRate)
        }
    }

    private static func writeMono(to url: URL, hz: Double) throws {
        try write(to: url, channels: 1) { _, frame in
            0.5 * sin(2.0 * .pi * hz * Double(frame) / fixtureRate)
        }
    }

    /// Float32 WAV at 44.1 kHz — the `SamplerLoopTests.writeMono` idiom,
    /// generalized to N channels. Scoped so the file flushes before a read.
    private static func write(to url: URL, channels channelCount: AVAudioChannelCount,
                              sample: (Int, Int) -> Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: fixtureRate,
            AVNumberOfChannelsKey: Int(channelCount),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: fixtureRate,
                                         channels: channelCount, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(fixtureFrames)),
              let data = buffer.floatChannelData else {
            throw NSError(domain: "SamplerZoneBufferDedupTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "buffer allocation failed"])
        }
        for channel in 0..<Int(channelCount) {
            for frame in 0..<fixtureFrames {
                data[channel][frame] = Float(sample(channel, frame))
            }
        }
        buffer.frameLength = AVAudioFrameCount(fixtureFrames)
        try file.write(from: buffer)
    }

    // MARK: - Harness

    /// ⚠️ All zones here leave `group` nil. The loader stable-sorts zones by
    /// group with an original-index tiebreaker, so with every group nil the
    /// sort is the IDENTITY and `zoneBufferBaseAddresses(i)` indexes the same
    /// zone the caller passed at position `i`.
    private func zone(_ url: URL, root: Int = 60, min: Int = 0, max: Int = 127) -> SamplerZone {
        SamplerZone(audioFileURL: url, rootPitch: root, minPitch: min, maxPitch: max)
    }

    private func sampler(_ zones: [SamplerZone]) -> SamplerInstrument {
        let params = SamplerParams(zones: zones, oneShot: false,
                                   attack: 0.001, release: 0.05, gain: 0.8)
        let instrument = SamplerInstrument(params: params, sampleRate: graphRate)
        instrument.prepare(sampleRate: graphRate, maxFramesPerQuantum: 512, channelCount: 2)
        return instrument
    }

    private func note(on: Int64, off: Int64, pitch: UInt8, id: UInt64) -> [ScheduledMIDIEvent] {
        [ScheduledMIDIEvent(sampleTime: on, noteID: id,
                            kind: ScheduledMIDIEvent.noteOn, pitch: pitch, velocity: 100),
         ScheduledMIDIEvent(sampleTime: off, noteID: id,
                            kind: ScheduledMIDIEvent.noteOff, pitch: pitch, velocity: 0)]
    }

    /// The `SamplerPlaybackTests` direct-render idiom: 512-frame quanta,
    /// hand-built event arrays, both channels returned.
    private func renderDirect(_ instrument: SamplerInstrument,
                              events unsorted: [ScheduledMIDIEvent],
                              frames totalFrames: Int,
                              quantum: Int = 512) throws -> (left: [Float], right: [Float]) {
        let events = unsorted.sorted { a, b in
            if a.sampleTime != b.sampleTime { return a.sampleTime < b.sampleTime }
            let rankA = a.kind == ScheduledMIDIEvent.noteOff ? 0 : 1
            let rankB = b.kind == ScheduledMIDIEvent.noteOff ? 0 : 1
            if rankA != rankB { return rankA < rankB }
            return a.noteID < b.noteID
        }
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: graphRate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(quantum)))
        let channels = try #require(buffer.floatChannelData)

        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(totalFrames)
        right.reserveCapacity(totalFrames)
        var cursor = 0
        var rendered = 0
        while rendered < totalFrames {
            let frames = min(quantum, totalFrames - rendered)
            buffer.frameLength = AVAudioFrameCount(frames)
            var end = cursor
            while end < events.count, events[end].sampleTime < Int64(rendered + frames) {
                end += 1
            }
            let output = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            events.withUnsafeBufferPointer { all in
                let slice = UnsafeBufferPointer(rebasing: all[cursor..<end])
                instrument.render(events: slice, renderStart: Int64(rendered),
                                  frameCount: frames, output: output)
            }
            cursor = end
            left.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: frames))
            right.append(contentsOf: UnsafeBufferPointer(start: channels[1], count: frames))
            rendered += frames
        }
        return (left, right)
    }

    // MARK: - 1. The fix works

    @Test("16 zones on one stereo file hold exactly ONE file's bytes")
    func sixteenZonesOneStereoFileHoldOneCopy() throws {
        let files = try fixtures()
        // The chop shape: 16 pads, one long record, 16 different spans.
        let zones = (0..<16).map { index in
            SamplerZone(audioFileURL: files.stereo,
                        rootPitch: 36 + index, minPitch: 36 + index, maxPitch: 36 + index,
                        startFrame: index * 1_000,
                        endFrame: (index + 1) * 1_000)
        }
        let instrument = sampler(zones)

        #expect(instrument.ownedSampleBufferCount == 2)          // L + R, once
        #expect(instrument.loadedSampleBytes == Self.stereoFileBytes)
        #expect(instrument.audioFileOpenCount == 1)              // the open was SKIPPED 15×
        // All 16 zones really loaded — a loader that silently dropped 15 of
        // them would also "hold one copy".
        #expect(instrument.zoneBufferBaseAddresses(15) != nil)
        #expect(instrument.zoneBufferBaseAddresses(16) == nil)
        #expect(instrument.zoneLoadNotes.isEmpty)
    }

    // MARK: - 2. ⭐ THE ALWAYS-ON POSITIVE CONTROL

    @Test("⭐ positive control: 8 zones on 8 DISTINCT files hold EIGHT copies")
    func eightZonesEightFilesHoldEightCopies() throws {
        let files = try fixtures()
        let instrument = sampler(files.eight.map { zone($0) })

        // If this goes green at 2 buffers / one file's bytes, the seam is
        // blind and test 1 proves nothing.
        #expect(instrument.ownedSampleBufferCount == 16)         // 8 files × (L + R)
        #expect(instrument.loadedSampleBytes == 8 * Self.stereoFileBytes)
        #expect(instrument.audioFileOpenCount == 8)
        // …and eight DISTINCT allocations, not one address reported eight times.
        var lefts = Set<UInt>()
        var rights = Set<UInt>()
        for index in 0..<8 {
            let addresses = try #require(instrument.zoneBufferBaseAddresses(index))
            lefts.insert(addresses.left)
            rights.insert(addresses.right)
        }
        #expect(lefts.count == 8)
        #expect(rights.count == 8)
        #expect(lefts.intersection(rights).isEmpty)
    }

    // MARK: - 3. Pointer identity

    @Test("zones sharing a file share the SAME base pointers")
    func sameFileZonesShareBasePointers() throws {
        let files = try fixtures()
        let zones = (0..<16).map { index in
            SamplerZone(audioFileURL: files.stereo,
                        rootPitch: 36 + index, minPitch: 36 + index, maxPitch: 36 + index,
                        startFrame: index * 1_000, endFrame: (index + 1) * 1_000)
        }
        let instrument = sampler(zones)

        let first = try #require(instrument.zoneBufferBaseAddresses(0))
        let last = try #require(instrument.zoneBufferBaseAddresses(15))
        #expect(first.left == last.left)
        #expect(first.right == last.right)
        // A stereo file's two channels are still two DISTINCT allocations —
        // an assertion that only ever compares equal proves nothing.
        #expect(first.left != first.right)
        for index in 1..<16 {
            let addresses = try #require(instrument.zoneBufferBaseAddresses(index))
            #expect(addresses.left == first.left)
            #expect(addresses.right == first.right)
        }
    }

    // MARK: - 4. Path spelling

    @Test("different spellings of one path share one copy")
    func differentPathSpellingsShareOneCopy() throws {
        let files = try fixtures()
        // POSITIVE CONTROL on the premise: the two RAW paths really do differ,
        // so `standardizedFileURL` is doing the work and not the URL initializer.
        #expect(files.stereo.path != files.stereoDotDot.path)
        #expect(files.stereoDotDot.path.contains("/sub/.."))
        #expect(files.stereo.standardizedFileURL.path == files.stereoDotDot.standardizedFileURL.path)
        // …and the one-home key agrees with that.
        #expect(zone(files.stereo).sourceFileKey == zone(files.stereoDotDot).sourceFileKey)

        let instrument = sampler([
            zone(files.stereo, root: 60, min: 60, max: 60),
            zone(files.stereoDotDot, root: 62, min: 62, max: 62),
        ])
        #expect(instrument.ownedSampleBufferCount == 2)
        #expect(instrument.loadedSampleBytes == Self.stereoFileBytes)
        #expect(instrument.audioFileOpenCount == 1)
        let first = try #require(instrument.zoneBufferBaseAddresses(0))
        let second = try #require(instrument.zoneBufferBaseAddresses(1))
        #expect(first.left == second.left)
        #expect(first.right == second.right)
    }

    // MARK: - 5. Regression pin on the aliasing that ALREADY shipped

    @Test("regression pin: a MONO file still aliases right at left")
    func monoFileStillAliasesLeftAndRight() throws {
        let files = try fixtures()
        let instrument = sampler([zone(files.mono)])

        // ONE allocation backs BOTH channel pointers — the pre-m32-a
        // behaviour at the old `:511`. m32-a widens this alias law; it must
        // not disturb it.
        #expect(instrument.ownedSampleBufferCount == 1)
        #expect(instrument.loadedSampleBytes == Self.monoFileBytes)
        let addresses = try #require(instrument.zoneBufferBaseAddresses(0))
        #expect(addresses.left == addresses.right)
    }

    /// Deliberately SEPARATE from the regression pin above. The pin asserts
    /// SHIPPED behaviour and must stay green under the m32-a plant (delete the
    /// cache hit); this asserts the NEW behaviour and must redden. Folding
    /// them together would make the plant's signal ambiguous.
    @Test("many mono zones on one file still hold ONE copy")
    func manyMonoZonesOnOneFileHoldOneCopy() throws {
        let files = try fixtures()
        // Four mono zones on that one file: still ONE allocation, still aliased.
        let many = sampler((0..<4).map { zone(files.mono, root: 60 + $0) })
        #expect(many.ownedSampleBufferCount == 1)
        #expect(many.loadedSampleBytes == Self.monoFileBytes)
        #expect(many.audioFileOpenCount == 1)
        let a = try #require(many.zoneBufferBaseAddresses(0))
        let d = try #require(many.zoneBufferBaseAddresses(3))
        #expect(a.left == a.right)
        #expect(a.left == d.left)
    }

    // MARK: - 6. Dedup does not change the audio

    @Test("dedup renders bit-identically to the non-deduped path")
    func dedupDoesNotChangeRenderedAudio() throws {
        let files = try fixtures()
        // ⚠️ DISJOINT pitch spans, and BOTH notes played. Two overlapping
        // full-range zones are both group 0, where the FIRST eligible zone
        // wins — the second zone's buffer would never be read, and the test
        // would pass even if dedup had corrupted it.
        let shared = sampler([
            zone(files.stereo, root: 60, min: 60, max: 60),
            zone(files.stereo, root: 62, min: 62, max: 62),
        ])
        // Byte-identical CONTENT at a DIFFERENT path → the loader must not
        // dedup it, so this instrument exercises the pre-m32-a two-copy path.
        let separate = sampler([
            zone(files.stereo, root: 60, min: 60, max: 60),
            zone(files.stereoCopy, root: 62, min: 62, max: 62),
        ])

        // POSITIVE CONTROL: the two instruments really are on different
        // allocation paths. Without this, the test compares dedup to dedup.
        #expect(shared.ownedSampleBufferCount == 2)
        #expect(separate.ownedSampleBufferCount == 4)
        #expect(shared.loadedSampleBytes * 2 == separate.loadedSampleBytes)

        let events = note(on: 0, off: 9_000, pitch: 60, id: 1)
            + note(on: 4_000, off: 13_000, pitch: 62, id: 2)
        let a = try renderDirect(shared, events: events, frames: 16_384)
        let b = try renderDirect(separate, events: events, frames: 16_384)

        #expect(a.left == b.left)
        #expect(a.right == b.right)
        // And the render is not silence — an all-zero comparison is free.
        #expect(a.left.contains { abs($0) > 0.01 })
        #expect(a.right.contains { abs($0) > 0.01 })
        // Denormal / NaN guard on both renders.
        #expect(!a.left.contains { $0.isNaN || $0.isInfinite })
        #expect(!a.right.contains { $0.isNaN || $0.isInfinite })

        // ⭐ POSITIVE CONTROL on zone ELIGIBILITY: prove the SECOND zone — the
        // one that only exists as an ALIAS in the deduped instrument —
        // actually produced audio. Without this, a render in which zone 1 was
        // never selected would compare equal even if its pointers were wrong.
        let firstNoteOnly = sampler([
            zone(files.stereo, root: 60, min: 60, max: 60),
            zone(files.stereo, root: 62, min: 62, max: 62),
        ])
        let c = try renderDirect(firstNoteOnly,
                                 events: note(on: 0, off: 9_000, pitch: 60, id: 1),
                                 frames: 16_384)
        #expect(a.left != c.left)
        #expect(a.right != c.right)
    }

    // MARK: - 7. Mixed load: dedup is per DISTINCT key, not "all or nothing"

    @Test("a mixed zone set holds exactly one copy per distinct file")
    func mixedZoneSetHoldsOneCopyPerDistinctFile() throws {
        let files = try fixtures()
        // 5 zones → 3 distinct sources: stereo ×2, stereoCopy ×2, mono ×1.
        let instrument = sampler([
            zone(files.stereo, root: 60), zone(files.stereoCopy, root: 61),
            zone(files.stereo, root: 62), zone(files.stereoCopy, root: 63),
            zone(files.mono, root: 64),
        ])
        // 2 stereo files × 2 channels + 1 mono file × 1 channel = 5.
        #expect(instrument.ownedSampleBufferCount == 5)
        #expect(instrument.loadedSampleBytes == 2 * Self.stereoFileBytes + Self.monoFileBytes)
        #expect(instrument.audioFileOpenCount == 3)

        let z0 = try #require(instrument.zoneBufferBaseAddresses(0))
        let z1 = try #require(instrument.zoneBufferBaseAddresses(1))
        let z2 = try #require(instrument.zoneBufferBaseAddresses(2))
        let z3 = try #require(instrument.zoneBufferBaseAddresses(3))
        #expect(z0.left == z2.left)      // same file → shared
        #expect(z1.left == z3.left)      // same file → shared
        #expect(z0.left != z1.left)      // different files → NOT shared
    }

    // MARK: - 8. Failures stay uncached (one note per skipped zone)

    @Test("a missing file is still noted once PER ZONE and allocates nothing")
    func missingFileNotesEveryZoneAndAllocatesNothing() throws {
        let files = try fixtures()
        let missing = files.dir.appendingPathComponent("does-not-exist.wav")
        let instrument = sampler([
            zone(missing, root: 60), zone(missing, root: 61), zone(files.stereo, root: 62),
        ])
        // Deliberate: failures are NOT cached, so the pre-m32-a
        // one-note-per-skipped-zone behaviour survives verbatim.
        #expect(instrument.zoneLoadNotes.count == 2)
        // Only the good file's bytes are held.
        #expect(instrument.ownedSampleBufferCount == 2)
        #expect(instrument.loadedSampleBytes == Self.stereoFileBytes)
        #expect(instrument.zoneBufferBaseAddresses(0) != nil)
        #expect(instrument.zoneBufferBaseAddresses(1) == nil)   // only one zone survived
    }
}
