import AVFAudio
import Accelerate
import DAWCore
import Darwin
import Foundation
import Testing
@testable import DAWEngine

/// m39-tpl-0 (W7-TPL0) — THE DRUM MACHINE'S NOTE LAYOUT, render half.
/// `docs/design/2026-09-27-multi-instrument-templates.md` §3 and §10's TPL-0 gate.
///
/// Four legs, each asserting PHYSICS, never distinctness:
///   1. BIT IDENTITY for `pads`: the same kits over the same notes render the
///      SAME BITS as before TPL-0 (digests taken on the unchanged tree).
///   2. EVERY GM NOTE LANDS ON ITS VOICE, by spectral correlation AND decay
///      time against that voice's own solo render — plus the control that
///      shows the gate can tell every wrong voice from the right one (the
///      hats share a band; only their decays separate them).
///   3. THE SILENT GM NOTES ARE SILENT, and a live layout change reaches the
///      NEXT note-on while a sounding hit keeps playing.
///   4. F-4: the note lookup allocates nothing, with the probe's own positive
///      control.
///
/// nonisolated: `init`, `prepare` and `render` are nonisolated. The one
/// `@MainActor` call (`apply(params:)`, the live edit) goes through a single
/// `MainActor.run` hop, the way the engine publishes from the main actor.
@Suite("Drum note layout — TPL-0 render gate", .serialized)
struct DrumNoteLayoutRenderTests {
    static let sampleRate = 48_000.0
    static let quantum = 512

    // MARK: - Recording (the console log drops records; a file does not)

    static func record(_ key: String, _ value: String) {
        print("TPL0-PROBE \(key)=\(value)")
        guard let path = ProcessInfo.processInfo.environment["TPL0_PROBE_OUT"] else { return }
        let line = Data("\(key)=\(value)\n".utf8)
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: line)
        }
    }

    // MARK: - Render harness (the DrumSynthTests slicing)

    static func makeDrums(_ kit: DrumKitParams) -> DrumSynthInstrument {
        let drums = DrumSynthInstrument(params: kit)
        drums.prepare(sampleRate: sampleRate, maxFramesPerQuantum: quantum, channelCount: 2)
        return drums
    }

    static func gmKit(_ base: DrumKitParams = DrumKitParams()) -> DrumKitParams {
        var kit = base
        kit.noteLayout = .gm
        return kit
    }

    static func noteOn(_ pitch: UInt8, at sample: Int64, velocity: UInt8 = 110,
                       id: UInt64) -> ScheduledMIDIEvent {
        ScheduledMIDIEvent(sampleTime: sample, noteID: id,
                           kind: ScheduledMIDIEvent.noteOn,
                           pitch: pitch, velocity: velocity)
    }

    /// Renders in 512-frame quanta, replicating `InstrumentRenderer`'s slicing.
    /// With `applyAt`, publishes `apply` from the main actor at the first
    /// quantum boundary at or after that frame — a LIVE edit.
    static func render(_ drums: DrumSynthInstrument,
                       events unsorted: [ScheduledMIDIEvent],
                       frames totalFrames: Int,
                       applyAt: Int? = nil,
                       apply kitToApply: DrumKitParams? = nil) async throws -> [[Float]] {
        let events = unsorted.sorted { $0.sampleTime < $1.sampleTime }
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(quantum)))
        let channels = try #require(buffer.floatChannelData)
        var left: [Float] = [], right: [Float] = []
        left.reserveCapacity(totalFrames)
        right.reserveCapacity(totalFrames)
        var cursor = 0, rendered = 0, applied = false
        while rendered < totalFrames {
            if let applyAt, let kitToApply, !applied, rendered >= applyAt {
                await MainActor.run { drums.apply(params: kitToApply) }
                applied = true
            }
            let frames = min(quantum, totalFrames - rendered)
            buffer.frameLength = AVAudioFrameCount(frames)
            var end = cursor
            while end < events.count, events[end].sampleTime < Int64(rendered + frames) {
                end += 1
            }
            let output = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            events.withUnsafeBufferPointer { all in
                let slice = UnsafeBufferPointer(rebasing: all[cursor..<end])
                drums.render(events: slice, renderStart: Int64(rendered),
                             frameCount: frames, output: output)
            }
            cursor = end
            left.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: frames))
            right.append(contentsOf: UnsafeBufferPointer(start: channels[1], count: frames))
            rendered += frames
        }
        return [left, right]
    }

    static func mono(_ channels: [[Float]]) -> [Float] {
        zip(channels[0], channels[1]).map { ($0 + $1) * 0.5 }
    }

    /// One hit of `note` at sample 0 on `kit`, mono.
    static func hit(_ note: UInt8, kit: DrumKitParams, seconds: Double = 2.0) async throws -> [Float] {
        mono(try await render(makeDrums(kit), events: [noteOn(note, at: 0, id: 1)],
                              frames: Int(seconds * sampleRate)))
    }

    // MARK: - Leg 1: bit identity for pads

    /// FNV-1a 64 over the raw bit patterns of every sample, both channels.
    /// Bit patterns, not values: `-0.0` and `0.0` differ here on purpose.
    static func digest(_ channels: [[Float]]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for channel in channels {
            for sample in channel {
                var bits = sample.bitPattern
                var byte = 0
                while byte < 4 {
                    hash ^= UInt64(bits & 0xff)
                    hash = hash &* 0x0000_0100_0000_01b3
                    bits >>= 8
                    byte += 1
                }
            }
        }
        return String(hash, radix: 16)
    }

    /// One hit on EVERY note 30…60, 0.3 s apart, then a tail: the eight pad
    /// notes, the GM notes around them and silent notes on both sides.
    static func sweepEvents() -> [ScheduledMIDIEvent] {
        var events: [ScheduledMIDIEvent] = []
        var note = 30
        while note <= 60 {
            let at = Int64(Double(note - 30) * 0.3 * sampleRate)
            events.append(noteOn(UInt8(note), at: at, id: UInt64(note)))
            note += 1
        }
        return events
    }

    static let sweepFrames = Int((31.0 * 0.3 + 1.7) * sampleRate)

    /// ⛔ TAKEN ON THE UNCHANGED TREE (the v0 run, 2026-09-27,
    /// `$S/w7/TPL0/probe-before.txt`), before `noteLayout` existed. A `pads`
    /// kit must render these exact bits after TPL-0.
    static let digestBefore: [String: String] = [
        "default": "af5d4a9be873642b",
        "lofi": "aeab1f176b98b04",
    ]
    static let sweepFramesBefore = 527_999

    @Test("A pads kit renders bit-identically before and after TPL-0")
    func padsKitRendersBitIdentically() async throws {
        #expect(Self.sweepFrames == Self.sweepFramesBefore)
        let lofi = try #require(DrumKitParams.preset(named: "lofi")).params
        let cases: [(String, String, DrumKitParams)] = [
            ("default", "default", DrumKitParams()),
            ("lofi", "lofi", lofi),
            // An EXPLICIT pads layout is the same kit as an absent one.
            ("default", "default, explicit pads", DrumKitParams(noteLayout: .pads)),
        ]
        for (pin, label, kit) in cases {
            let channels = try await Self.render(Self.makeDrums(kit), events: Self.sweepEvents(),
                                                 frames: Self.sweepFrames)
            let now = Self.digest(channels)
            Self.record("digest.after.\(label)", now)
            #expect(now == Self.digestBefore[pin], "\(label): the pads render moved")
        }
    }

    // MARK: - Leg 2: every GM note lands on its voice

    /// §3.3's gm column, BY HAND (the model test pins the same table).
    static let designGM: [(note: UInt8, voice: DrumVoice)] = [
        (35, .kick), (36, .kick), (37, .rim), (38, .snare), (39, .clap), (40, .snare),
        (41, .tom), (42, .closedHat), (43, .tom), (44, .closedHat), (45, .tom),
        (46, .openHat), (47, .tom), (48, .tom), (49, .cymbal), (50, .tom),
        (51, .cymbal), (52, .cymbal), (53, .cymbal), (55, .cymbal), (57, .cymbal),
        (59, .cymbal),
    ]

    /// 1/3-octave band levels in dB, 25 Hz to 20 kHz, from a Hann-windowed
    /// Welch average (8192-point frames, 50 % overlap) over the first
    /// `seconds`, floored 90 dB under the loudest band so the far stopband
    /// cannot dominate a correlation. A voice's SPECTRAL SHAPE, independent of
    /// its level (Pearson correlation ignores a dB offset).
    static func bandLevelsDb(_ mono: [Float], seconds: Double = 1.5) -> [Double] {
        let size = 8192
        let log2n = vDSP_Length(13)
        let hop = 4096
        let count = min(mono.count, Int(seconds * sampleRate))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        var power = [Double](repeating: 0, count: size / 2)
        var frame = [Float](repeating: 0, count: size)
        var real = [Float](repeating: 0, count: size / 2)
        var imag = [Float](repeating: 0, count: size / 2)
        var start = 0
        var frames = 0
        repeat {
            for index in 0..<size {
                let source = start + index
                frame[index] = source < count ? mono[source] * window[index] : 0
            }
            real.withUnsafeMutableBufferPointer { realBuffer in
                imag.withUnsafeMutableBufferPointer { imagBuffer in
                    var split = DSPSplitComplex(realp: realBuffer.baseAddress!,
                                                imagp: imagBuffer.baseAddress!)
                    frame.withUnsafeBufferPointer { frameBuffer in
                        frameBuffer.baseAddress!.withMemoryRebound(
                            to: DSPComplex.self, capacity: size / 2) { complex in
                            vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(size / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    // Bin 0 packs DC and Nyquist; neither is in any band.
                    for bin in 1..<(size / 2) {
                        let re = Double(split.realp[bin]), im = Double(split.imagp[bin])
                        power[bin] += re * re + im * im
                    }
                }
            }
            frames += 1
            start += hop
        } while start + size <= count
        let binHz = sampleRate / Double(size)
        var levels: [Double] = []
        var centre = 25.0
        while centre <= 20_000 {
            let low = centre / pow(2, 1.0 / 6.0), high = centre * pow(2, 1.0 / 6.0)
            var sum = 0.0
            var bin = max(1, Int((low / binHz).rounded(.up)))
            while Double(bin) * binHz < high, bin < size / 2 {
                sum += power[bin]
                bin += 1
            }
            levels.append(10 * log10(sum / Double(frames) + 1e-30))
            centre *= pow(2, 1.0 / 3.0)
        }
        let top = levels.max() ?? 0
        return levels.map { max($0, top - 90) }
    }

    static func correlation(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, a.count > 1 else { return 0 }
        let meanA = a.reduce(0, +) / Double(a.count)
        let meanB = b.reduce(0, +) / Double(b.count)
        var cross = 0.0, varA = 0.0, varB = 0.0
        for index in a.indices {
            let x = a[index] - meanA, y = b[index] - meanB
            cross += x * y
            varA += x * x
            varB += y * y
        }
        guard varA > 0, varB > 0 else { return 0 }
        return cross / (varA.squareRoot() * varB.squareRoot())
    }

    /// The −60 dB time (DrumSynthTests' estimator): the first hop whose RMS is
    /// 60 dB under the peak hop. The hop must span several periods of the
    /// content, so each voice gets the setting DrumSynthTests measured it with.
    static func decayTime(_ samples: [Float], hop: Double, searchFrom: Double) -> Double? {
        let size = max(Int(hop * sampleRate), 1)
        var hops: [Double] = []
        var index = 0
        while index + size <= samples.count {
            var sum = 0.0
            for k in index..<(index + size) { sum += Double(samples[k]) * Double(samples[k]) }
            hops.append((sum / Double(size)).squareRoot())
            index += size
        }
        let tail = Array(hops.dropFirst(Int(searchFrom / hop)))
        guard let peak = tail.max(), peak > 0 else { return nil }
        guard let first = tail.firstIndex(where: { $0 < peak * 0.001 }) else { return nil }
        return Double(first) * hop
    }

    static func decaySetting(_ voice: DrumVoice) -> (hop: Double, searchFrom: Double) {
        switch voice {
        case .kick: return (0.02, 0)
        case .snare, .tom: return (0.012, 0)
        case .closedHat, .openHat, .rim: return (0.002, 0)
        case .clap: return (0.004, 0.040)
        case .cymbal: return (0.004, 0)
        }
    }

    struct Verdict {
        let correlation: Double
        let decayRatio: Double?
        var lands: Bool {
            guard let decayRatio else { return false }
            return correlation >= 0.9 && abs(decayRatio - 1) <= 0.2
        }
        var text: String {
            String(format: "r=%.4f decay=%@", correlation,
                   decayRatio.map { String(format: "%.3f", $0) } ?? "none")
        }
    }

    /// THE GATE (§8.8's row): does `candidate` sound like `voice`, whose own
    /// solo render is `reference`? Spectral correlation ≥ 0.9 AND decay within
    /// 20 %. A silent candidate never lands.
    static func judge(_ candidate: [Float], as voice: DrumVoice, reference: [Float]) -> Verdict {
        let peak = candidate.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 0 else { return Verdict(correlation: 0, decayRatio: nil) }
        let setting = decaySetting(voice)
        let r = correlation(bandLevelsDb(candidate), bandLevelsDb(reference))
        guard let got = decayTime(candidate, hop: setting.hop, searchFrom: setting.searchFrom),
              let want = decayTime(reference, hop: setting.hop, searchFrom: setting.searchFrom),
              want > 0 else { return Verdict(correlation: r, decayRatio: nil) }
        return Verdict(correlation: r, decayRatio: got / want)
    }

    /// Each voice's own solo render at its PADS note on a pads kit — today's
    /// sound, the thing a GM note must reproduce.
    static func references() async throws -> [DrumVoice: [Float]] {
        var out: [DrumVoice: [Float]] = [:]
        for voice in DrumVoice.allCases {
            out[voice] = try await hit(voice.note, kit: DrumKitParams())
        }
        return out
    }

    @Test("Every GM note in the design's table lands on its voice, by spectrum and decay")
    func everyGMNoteLandsOnItsVoice() async throws {
        let refs = try await Self.references()
        #expect(Self.designGM.count == 22)
        for (note, voice) in Self.designGM {
            let candidate = try await Self.hit(note, kit: Self.gmKit())
            #expect(candidate.allSatisfy { $0.isFinite }, "gm note \(note) rendered a non-finite sample")
            let verdict = Self.judge(candidate, as: voice, reference: try #require(refs[voice]))
            Self.record("gm.\(note).\(voice.rawValue)", verdict.text)
            // Recorded, not asserted: with one tom tuning and one cymbal, a GM
            // note renders the very samples of its voice's pad render. The
            // ASSERTED gate is the design's spectral one, so a later per-note
            // tuning does not break this test.
            Self.record("gm.\(note).bitIdenticalToReference", "\(candidate == refs[voice])")
            #expect(verdict.lands, "GM note \(note) does not sound like \(voice): \(verdict.text)")
        }
    }

    /// ⭐ THE CONTROL THAT MAKES LEG 2 MEAN SOMETHING. A gate that passed any
    /// drum for any drum would pass a swapped map. So: every WRONG voice,
    /// judged as every expected voice, must fail. The two hats share one band,
    /// so correlation alone cannot separate them; the decay does.
    @Test("The gate tells every voice apart from every other voice")
    func theGateTellsEveryVoiceApart() async throws {
        let refs = try await Self.references()
        for expected in DrumVoice.allCases {
            let reference = try #require(refs[expected])
            // The positive half: a voice lands on itself.
            #expect(Self.judge(reference, as: expected, reference: reference).lands)
            for wrong in DrumVoice.allCases where wrong != expected {
                let verdict = Self.judge(try #require(refs[wrong]), as: expected,
                                         reference: reference)
                Self.record("apart.\(expected.rawValue).vs.\(wrong.rawValue)", verdict.text)
                #expect(verdict.lands == false,
                        "the gate cannot tell \(wrong) from \(expected): \(verdict.text)")
            }
        }
    }

    // MARK: - Leg 3: silence, and a live change

    @Test("The silent GM notes play nothing on a gm kit")
    func silentGMNotesAreSilent() async throws {
        let silent = DrumNoteLayout.gm.silentGMNotes
        #expect(silent.isEmpty == false)
        for note in silent {
            let rendered = try await Self.hit(note, kit: Self.gmKit(), seconds: 0.3)
            let peak = rendered.reduce(Float(0)) { max($0, abs($1)) }
            #expect(peak == 0, "silent GM note \(note) made sound (peak \(peak))")
        }
        // Control: the same harness DOES hear a mapped note.
        let kick = try await Self.hit(36, kit: Self.gmKit(), seconds: 0.3)
        #expect(kick.reduce(Float(0)) { max($0, abs($1)) } > 0.01)
    }

    /// Note 39 is the OPEN HAT in pads and the CLAP in gm. Hit it, switch the
    /// layout LIVE while the open hat rings, hit it again.
    @Test("A layout change takes effect at the next note-on; a sounding hit keeps playing")
    func layoutChangeTakesEffectAtTheNextNoteOn() async throws {
        let second = Int(0.6 * Self.sampleRate)
        let frames = Int(2.6 * Self.sampleRate)
        let events = [Self.noteOn(39, at: 0, id: 1), Self.noteOn(39, at: Int64(second), id: 2)]
        let live = Self.mono(try await Self.render(
            Self.makeDrums(DrumKitParams()), events: events, frames: frames,
            applyAt: Int(0.1 * Self.sampleRate), apply: Self.gmKit()))
        let control = Self.mono(try await Self.render(
            Self.makeDrums(DrumKitParams()), events: events, frames: frames))

        // The hit already sounding is untouched by the change, to the bit.
        #expect(Array(live[..<second]) == Array(control[..<second]),
                "the layout change disturbed a sounding hit")

        let refs = try await Self.references()
        let clapRef = try #require(refs[.clap]), openRef = try #require(refs[.openHat])
        let liveSecond = Array(live[second...]), controlSecond = Array(control[second...])
        let asClap = Self.judge(liveSecond, as: .clap, reference: clapRef)
        let asOpen = Self.judge(liveSecond, as: .openHat, reference: openRef)
        let controlAsOpen = Self.judge(controlSecond, as: .openHat, reference: openRef)
        Self.record("live.second.asClap", asClap.text)
        Self.record("live.second.asOpenHat", asOpen.text)
        Self.record("control.second.asOpenHat", controlAsOpen.text)
        #expect(asClap.lands, "after the change, note 39 is not the clap: \(asClap.text)")
        #expect(asOpen.lands == false, "after the change, note 39 is still the open hat")
        // Control: without the change the same note is still the open hat.
        #expect(controlAsOpen.lands, "the control's second hit is not the open hat")
    }

    // MARK: - Leg 4: F-4, the note lookup allocates nothing

    private typealias MallocLoggerFn =
        @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    /// Heap cells, NOT stored properties: the hook runs INSIDE malloc with its
    /// locks held, so it must never allocate nor trip a lazy global init.
    private nonisolated(unsafe) static let eventCount =
        UnsafeMutablePointer<Int>.allocate(capacity: 1)
    private nonisolated(unsafe) static let watchedThread =
        UnsafeMutablePointer<UInt64>.allocate(capacity: 1)

    private static let eventHook: MallocLoggerFn = { _, _, _, _, _, _ in
        var tid: UInt64 = 0
        pthread_threadid_np(nil, &tid)
        if tid == DrumNoteLayoutRenderTests.watchedThread.pointee {
            DrumNoteLayoutRenderTests.eventCount.pointee &+= 1
        }
    }

    /// libmalloc's `malloc_logger` global. Nil is a FAILURE for the caller,
    /// never a skip — a silently-absent probe is vacuity, not a pass.
    private static func mallocLoggerSlot() -> UnsafeMutablePointer<MallocLoggerFn?>? {
        guard let raw = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                              "malloc_logger") else { return nil }
        return raw.assumingMemoryBound(to: MallocLoggerFn?.self)
    }

    /// ⛔ SIBLING-IDENTICAL TO `ClipperTests` ON PURPOSE. The `warmup` runs
    /// with the hook live and the counter is zeroed afterwards, because
    /// Swift's `static let` arrays allocate on FIRST TOUCH anywhere in the
    /// process.
    private static func mallocEvents(
        slot: UnsafeMutablePointer<MallocLoggerFn?>,
        warmup: () -> Void = {}, _ body: () -> Void
    ) -> Int {
        pthread_threadid_np(nil, &watchedThread.pointee)
        eventCount.pointee = 0
        let previous = slot.pointee  // restore, don't assume it was nil
        slot.pointee = eventHook
        warmup()
        eventCount.pointee = 0   // one-time lazy-global costs are not the measurement
        body()
        slot.pointee = previous
        return eventCount.pointee
    }

    @Test("F-4 control: the malloc probe can actually count")
    func theAllocationProbeCanSeeAnAllocation() throws {
        guard let slot = Self.mallocLoggerSlot() else {
            Issue.record("malloc_logger is unavailable — FAILURE, not a skip.")
            return
        }
        // ⭐ A zero from a probe that never fires and a zero from a lookup that
        // never allocates are the same number.
        var sink: [[Int]] = []
        let events = Self.mallocEvents(slot: slot) {
            var index = 0
            while index < 200 {
                sink.append([Int](repeating: index, count: 64))
                index += 1
            }
        }
        Self.record("f4.control.events.per200arrays", "\(events)")
        #expect(events > 0, "the malloc probe counted \(events) events on 200 allocations")
        #expect(sink.count == 200)
    }

    /// F-4: BEFORE TPL-0 the lookup was `DrumVoice.allCases.first { … }`, and
    /// on the unchanged tree this probe counted 20 000 malloc
    /// events for these 1 000 calls in the debug test build (the shipped
    /// release build had folded the scan into eight loads from a constant
    /// table: no calls at all). The `switch` must count zero in both layouts.
    @Test("F-4: the note lookup allocates nothing, in either layout")
    func theLookupAllocatesNothing() throws {
        guard let slot = Self.mallocLoggerSlot() else {
            Issue.record("malloc_logger is unavailable — FAILURE, not a skip.")
            return
        }
        var sink: Int32 = 0
        let calls = 1_000
        for layout in DrumNoteLayout.allCases {
            let events = Self.mallocEvents(slot: slot, warmup: {
                var note = 30
                while note <= 60 {
                    sink &+= DrumVoice.voice(forNote: UInt8(note), layout: layout)?.slot ?? -1
                    note += 1
                }
            }) {
                var call = 0
                while call < calls {
                    sink &+= DrumVoice.voice(forNote: UInt8(35 + call % 25),
                                             layout: layout)?.slot ?? -1
                    call += 1
                }
            }
            Self.record("f4.after.lookup.\(layout.rawValue).events.per1000", "\(events)")
            #expect(events == 0, "the \(layout) lookup allocated (\(events) malloc events)")
        }
        // The legacy entry point, which is now the pads column of the switch.
        let legacy = Self.mallocEvents(slot: slot) {
            var call = 0
            while call < calls {
                sink &+= DrumVoice.voice(forNote: UInt8(36 + call % 8))?.slot ?? -1
                call += 1
            }
        }
        Self.record("f4.after.lookup.legacy.events.per1000", "\(legacy)")
        #expect(legacy == 0, "voice(forNote:) allocated (\(legacy) malloc events)")
        #expect(sink != 0)
    }

    /// F-4, the whole note-on path in context: render quanta with one note-on
    /// each against the same quanta with none, both layouts. RECORDED for the
    /// RT review; see the assertion's comment for what is and is not claimed.
    @Test("F-4: a render quantum with a note-on, against one without")
    func noteOnQuantumEvents() throws {
        guard let slot = Self.mallocLoggerSlot() else {
            Issue.record("malloc_logger is unavailable — FAILURE, not a skip.")
            return
        }
        let warm = 16
        let quanta = 200
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.quantum)))
        buffer.frameLength = AVAudioFrameCount(Self.quantum)
        let output = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let empty = UnsafeBufferPointer<ScheduledMIDIEvent>(start: nil, count: 0)
        var withNoteOn: [DrumNoteLayout: Int] = [:]
        var idleEvents: [DrumNoteLayout: Int] = [:]
        for layout in DrumNoteLayout.allCases {
            // ⚠️ A RAW POINTER, NOT A SWIFT `Array` — the sibling shape. One
            // note-on at the top of every quantum, cycling through eight notes
            // that play all eight voices in this layout.
            let notes: [UInt8] = layout == .pads
                ? [36, 37, 38, 39, 40, 41, 42, 43]
                : [36, 38, 42, 46, 39, 45, 37, 49]
            let store = UnsafeMutablePointer<ScheduledMIDIEvent>.allocate(capacity: warm + quanta)
            defer { store.deallocate() }
            var index = 0
            while index < warm + quanta {
                (store + index).initialize(to: Self.noteOn(
                    notes[index % 8], at: Int64(index * Self.quantum), id: UInt64(index + 1)))
                index += 1
            }
            var kit = DrumKitParams()
            kit.noteLayout = layout
            let hitting = Self.makeDrums(kit)
            let withNotes = Self.mallocEvents(slot: slot, warmup: {
                var q = 0
                while q < warm {
                    hitting.render(events: UnsafeBufferPointer(start: store + q, count: 1),
                                   renderStart: Int64(q * Self.quantum),
                                   frameCount: Self.quantum, output: output)
                    q += 1
                }
            }) {
                var q = warm
                while q < warm + quanta {
                    hitting.render(events: UnsafeBufferPointer(start: store + q, count: 1),
                                   renderStart: Int64(q * Self.quantum),
                                   frameCount: Self.quantum, output: output)
                    q += 1
                }
            }
            let idle = Self.makeDrums(kit)
            let withoutNotes = Self.mallocEvents(slot: slot, warmup: {
                var q = 0
                while q < warm {
                    idle.render(events: empty, renderStart: Int64(q * Self.quantum),
                                frameCount: Self.quantum, output: output)
                    q += 1
                }
            }) {
                var q = warm
                while q < warm + quanta {
                    idle.render(events: empty, renderStart: Int64(q * Self.quantum),
                                frameCount: Self.quantum, output: output)
                    q += 1
                }
            }
            Self.record("f4.after.quantum.\(layout.rawValue).withNoteOn.events.per200",
                        "\(withNotes)")
            Self.record("f4.after.quantum.\(layout.rawValue).noNotes.events.per200",
                        "\(withoutNotes)")
            withNoteOn[layout] = withNotes
            idleEvents[layout] = withoutNotes
        }
        // ⚠️ WHAT THIS LEG DOES AND DOES NOT CLAIM. At -Onone (how the suite
        // builds) this render raises malloc events on EVERY frame, notes or
        // none: its `for … in 0..<n` loops (the frame loop and the 16-slot
        // loop, 17 iterations a frame) raise ~2 each — the m23-r1 law
        // (`LimiterTruePeakTests`). On the unchanged tree these 200 idle
        // quanta counted 3 481 600 = 34 a frame. That is PRE-EXISTING, reported
        // for the RT review, and not TPL-0's to change, so the count is not
        // asserted to be zero. What IS asserted: the layout costs nothing. The
        // gm notes above play the same eight voices in the same order as the
        // pads notes, so both layouts must raise EXACTLY the same count.
        #expect(withNoteOn[.gm] == withNoteOn[.pads],
                "gm note-ons raised \(withNoteOn[.gm] ?? -1) events, pads \(withNoteOn[.pads] ?? -1)")
        #expect(idleEvents[.gm] == idleEvents[.pads],
                "an idle gm kit raised \(idleEvents[.gm] ?? -1) events, pads \(idleEvents[.pads] ?? -1)")
    }

    /// F-4, RECORDED, NOT ASSERTED: the other runtime call a note-on makes.
    /// `trigger` reads `kit[voice]`, which is `self[keyPath: voiceKeyPath(for:)]`,
    /// and the release build's `render` calls `swift_getAtKeyPath` for it (a
    /// static census of the release binary's call sites, 2026-09-27). That is
    /// the same optimised libswiftCore function in this debug build, so the
    /// difference between the two counts below is what a shipped note-on's
    /// kit read raises. TPL-0 does not touch it; the numbers are for the RT
    /// review.
    @Test("F-4, recorded: what a note-on's kit read raises")
    func noteOnKitReadEvents() throws {
        guard let slot = Self.mallocLoggerSlot() else {
            Issue.record("malloc_logger is unavailable — FAILURE, not a skip.")
            return
        }
        // ⚠️ A RAW POINTER, NOT A SWIFT `Array`, and `while`, not `for … in`:
        // the harness must not raise events of its own.
        let voices = UnsafeMutablePointer<DrumVoice>.allocate(capacity: 8)
        defer { voices.deallocate() }
        var fill = 0
        for voice in DrumVoice.allCases {
            (voices + fill).initialize(to: voice)
            fill += 1
        }
        let kit = DrumKitParams()
        let calls = 1_000
        var sink = 0.0
        let reads = Self.mallocEvents(slot: slot, warmup: {
            var v = 0
            while v < 8 {
                sink += kit[voices[v]].level
                v += 1
            }
        }) {
            var call = 0
            while call < calls {
                sink += kit[voices[call % 8]].level
                call += 1
            }
        }
        let paths = Self.mallocEvents(slot: slot, warmup: {
            var v = 0
            while v < 8 {
                _ = DrumKitParams.voiceKeyPath(for: voices[v])
                v += 1
            }
        }) {
            var call = 0
            while call < calls {
                _ = DrumKitParams.voiceKeyPath(for: voices[call % 8])
                call += 1
            }
        }
        Self.record("f4.kitRead.events.per1000", "\(reads)")
        Self.record("f4.voiceKeyPath.events.per1000", "\(paths)")
        #expect(sink > 0)
    }
}
