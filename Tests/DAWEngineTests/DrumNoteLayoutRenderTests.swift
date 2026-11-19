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
        // W9-DRUMDEF: every factory kit now carries a new drum machine's
        // hats/cymbals trims (23.4 / 5.7). This pin is about the LAYOUT, and was
        // taken on trims at 0 — so hold them at the saved-kit neutral here.
        // W9-HEAD: the factory kits now carry the headroom (lofi 0.63); this pin was taken at lofi's old
        // 0.9, so read the kit as it was before (`presetsBeforeHeadroom`), every other value identical.
        var lofi = try #require(DrumKitParams.presetsBeforeHeadroom.first { $0.name == "lofi" }).params
        lofi.hatsLevelDb = DrumKitParams.savedKitLevelTrimDb
        lofi.cymbalsLevelDb = DrumKitParams.savedKitLevelTrimDb
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

    // The hook, the counter cells and the process-wide window lock live in
    // `Support/MallocProbe.swift` (m39-test-mallocprobe): one measurement at a time. This leg's F-4 idle count
    // used to read half its value in a 2 306-test parallel run, when another file's restore removed this hook.
    // `warmup:` runs with the hook live and the counter is zeroed after it.

    @Test("F-4 control: the malloc probe can actually count")
    func theAllocationProbeCanSeeAnAllocation() throws {
        guard let slot = MallocProbe.slot() else {
            Issue.record("malloc_logger is unavailable — FAILURE, not a skip.")
            return
        }
        // ⭐ A zero from a probe that never fires and a zero from a lookup that
        // never allocates are the same number.
        var sink: [[Int]] = []
        let events = MallocProbe.events(slot: slot) {
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
        guard let slot = MallocProbe.slot() else {
            Issue.record("malloc_logger is unavailable — FAILURE, not a skip.")
            return
        }
        var sink: Int32 = 0
        let calls = 1_000
        for layout in DrumNoteLayout.allCases {
            let events = MallocProbe.events(slot: slot, warmup: {
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
        let legacy = MallocProbe.events(slot: slot) {
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
        guard let slot = MallocProbe.slot() else {
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
            let withNotes = MallocProbe.events(slot: slot, warmup: {
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
            let withoutNotes = MallocProbe.events(slot: slot, warmup: {
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
        guard let slot = MallocProbe.slot() else {
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
        let reads = MallocProbe.events(slot: slot, warmup: {
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
        let paths = MallocProbe.events(slot: slot, warmup: {
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

// MARK: - W8-RTFIX (F1/F4/F7): the render thread's kit adoption and kit read

/// W8-RTFIX — `refreshOutputStages`, the render-thread pass that re-reads
/// `level`/`pan` for every SOUNDING voice when a new kit is adopted (and when
/// modulation stops), and the note-on kit read in `trigger`.
///
/// ⛔ THE DIGESTS BELOW ARE THE BYTE GATE, and they were taken on the source
/// BEFORE W8-RTFIX touched it (run B0). The live publish lands while all eight
/// voices ring, with a DIFFERENT level factor and pan offset per voice, so a
/// slot → voice mix-up in the refresh moves the bytes.
///
/// ⭐ PHYSICS, NOT DISTINCTNESS: `level` is the voice's FINAL multiply
/// (`renderSlot`: `out *= gate * level`), so a published kit that halves every
/// voice's level must make every later sample EXACTLY half (scaling by 0.5 is
/// exact in binary floating point), and every earlier sample identical.
extension DrumNoteLayoutRenderTests {
    static let rtfixFrames = Int(2.0 * sampleRate)
    /// `render(applyAt:)` publishes at the first quantum boundary at or after
    /// this frame: 12_288 = 24 × 512, the frame the render adopts the kit.
    static let rtfixPublishAt = 12_000
    static let rtfixAdoptionFrame = 12_288

    /// Eight hits, one per voice, 37 frames apart inside the first quantum,
    /// then the same eight at 0.6 s and 1.2 s at other velocities (127 is an
    /// accent). Notes are `layout`'s own, so the gm kit plays gm notes.
    static func rtfixEvents(_ layout: DrumNoteLayout) -> [ScheduledMIDIEvent] {
        var events: [ScheduledMIDIEvent] = []
        var id: UInt64 = 1
        let rounds: [(seconds: Double, velocity: UInt8)] = [(0, 110), (0.6, 70), (1.2, 127)]
        for round in rounds {
            for voice in DrumVoice.allCases {
                let at = Int64(round.seconds * sampleRate) + Int64(voice.slot) * 37
                events.append(noteOn(voice.notes(in: layout)[0], at: at,
                                     velocity: round.velocity, id: id))
                id += 1
            }
        }
        return events
    }

    /// Every voice's level × 0.5, nothing else.
    static func rtfixHalved(_ kit: DrumKitParams) -> DrumKitParams {
        var out = kit
        for voice in DrumVoice.allCases { out[voice].level *= 0.5 }
        return out
    }

    /// A different level factor AND pan offset per voice.
    static func rtfixReshaped(_ kit: DrumKitParams) -> DrumKitParams {
        var out = kit
        for voice in DrumVoice.allCases {
            let s = Double(voice.slot)
            out[voice].level = min(1, kit[voice].level * (0.45 + 0.07 * s))
            out[voice].pan = max(-1, min(1, kit[voice].pan + (s - 3.5) * 0.12))
        }
        return out
    }

    /// Before `adoption`: identical; from it on: exactly half. Value equality
    /// (−0 == 0); the first failing frame is named, never a collection diff.
    static func rtfixHalvingCheck(plain: [[Float]], published: [[Float]],
                                  from adoption: Int) -> (ok: Bool, detail: String) {
        var channel = 0
        while channel < 2 {
            let a = plain[channel], b = published[channel]
            guard a.count == b.count else { return (false, "lengths \(a.count) vs \(b.count)") }
            var i = 0
            while i < a.count {
                let expected = i < adoption ? a[i] : a[i] * 0.5
                if b[i] != expected {
                    return (false, "channel \(channel) frame \(i): \(b[i]) vs expected \(expected)")
                }
                i += 1
            }
            channel += 1
        }
        return (true, "")
    }

    static func rtfixEnergy(_ channels: [[Float]], from start: Int) -> Double {
        var sum = 0.0
        for channel in channels {
            var i = start
            while i < channel.count { sum += Double(channel[i]) * Double(channel[i]); i += 1 }
        }
        return sum
    }

    /// ⛔ TAKEN ON THE SOURCE BEFORE W8-RTFIX (run B0, 2026-10-06 19:28-19:30,
    /// `DrumSynthInstrument.swift` and `DrumKit.swift` `cmp`-identical to their
    /// pre-change copies at that moment). `plain` = the hits alone; `reshaped`
    /// = the same hits with the per-voice level/pan publish landing at 12 288.
    static let rtfixDigestsBefore: [String: String] = [
        "pads.plain": "3884478711cf7197", "pads.reshaped": "3c9603c585474c39",
        "gm.plain": "e85899cf5941f93c", "gm.reshaped": "ac50ad61d8097275",
        "trims.plain": "a35a7ff133a29e74", "trims.reshaped": "188d40b80a3f20f8",
    ]

    static func rtfixKits() throws -> [(label: String, kit: DrumKitParams)] {
        // W9-DRUMDEF: every factory kit now carries a new drum machine's
        // hats/cymbals trims (23.4 / 5.7). This pin is about the LAYOUT, and was
        // taken on trims at 0 — so hold them at the saved-kit neutral here.
        // W9-HEAD: the factory kits now carry the headroom (lofi 0.63); this pin was taken at lofi's old
        // 0.9, so read the kit as it was before (`presetsBeforeHeadroom`), every other value identical.
        var lofi = try #require(DrumKitParams.presetsBeforeHeadroom.first { $0.name == "lofi" }).params
        lofi.hatsLevelDb = DrumKitParams.savedKitLevelTrimDb
        lofi.cymbalsLevelDb = DrumKitParams.savedKitLevelTrimDb
        var trims = gmKit()
        trims.hatsLevelDb = 9.5
        trims.cymbalsLevelDb = -4.25
        return [("pads", DrumKitParams()), ("gm", gmKit(lofi)), ("trims", trims)]
    }

    @Test("W8-RTFIX byte gate: a live kit publish over eight ringing voices; pads, gm and trimmed kits")
    func rtfixRefreshByteGate() async throws {
        for (label, kit) in try Self.rtfixKits() {
            let events = Self.rtfixEvents(kit.noteLayout)
            let plain = try await Self.render(Self.makeDrums(kit), events: events,
                                              frames: Self.rtfixFrames)
            let halved = try await Self.render(Self.makeDrums(kit), events: events,
                                               frames: Self.rtfixFrames,
                                               applyAt: Self.rtfixPublishAt,
                                               apply: Self.rtfixHalved(kit))
            let reshaped = try await Self.render(Self.makeDrums(kit), events: events,
                                                 frames: Self.rtfixFrames,
                                                 applyAt: Self.rtfixPublishAt,
                                                 apply: Self.rtfixReshaped(kit))
            // Non-vacuity: the voices ARE ringing when the kit is adopted, and
            // the later rounds sound.
            let ringing = Self.rtfixEnergy(
                [Array(plain[0][Self.rtfixAdoptionFrame..<(Self.rtfixAdoptionFrame + 2_048)]),
                 Array(plain[1][Self.rtfixAdoptionFrame..<(Self.rtfixAdoptionFrame + 2_048)])],
                from: 0)
            #expect(ringing > 1e-6, "\(label): nothing rings at the adoption frame (\(ringing))")
            let check = Self.rtfixHalvingCheck(plain: plain, published: halved,
                                               from: Self.rtfixAdoptionFrame)
            #expect(check.ok, "\(label): halving every level did not halve the output: \(check.detail)")
            let plainDigest = Self.digest(plain)
            let reshapedDigest = Self.digest(reshaped)
            Self.record("rtfix.digest.\(label).plain", plainDigest)
            Self.record("rtfix.digest.\(label).reshaped", reshapedDigest)
            #expect(plainDigest != reshapedDigest, "\(label): the reshaped publish changed nothing")
            #expect(plainDigest == Self.rtfixDigestsBefore["\(label).plain"],
                    "\(label): the hits alone no longer render bit-identically")
            #expect(reshapedDigest == Self.rtfixDigestsBefore["\(label).reshaped"],
                    "\(label): the live publish no longer renders bit-identically")
        }
    }

    /// F1, the differential: 1 000 kit adoptions with all eight voices
    /// sounding, against 1 000 renders that adopt nothing. `prepare` resets
    /// the adopted generation, so the next `render` takes the SAME adoption
    /// path a published kit does (load, compare, copy, `refreshOutputStages`)
    /// without the main-actor half (`apply(params:)` allocates the snapshot by
    /// design, on the main actor). 0-frame renders: no voice decays, and the
    /// frame loop is the same in both. Recorded in B0 on the old scan:
    /// 192 000 events against 0. ASSERTED since the `switch`: EQUAL counts.
    @Test("W8-RTFIX F1: adopting a kit with eight voices sounding allocates nothing more than not adopting")
    func rtfixRefreshAllocationDifferential() throws {
        guard let slot = MallocProbe.slot() else {
            Issue.record("malloc_logger is unavailable — FAILURE, not a skip.")
            return
        }
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.quantum)))
        buffer.frameLength = AVAudioFrameCount(Self.quantum)
        let output = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let empty = UnsafeBufferPointer<ScheduledMIDIEvent>(start: nil, count: 0)
        // All eight voices struck at sample 0 of a ONE-frame quantum, so every
        // one is sounding when the measurement starts.
        let hits = UnsafeMutablePointer<ScheduledMIDIEvent>.allocate(capacity: 8)
        defer { hits.deallocate() }
        var fill = 0
        for voice in DrumVoice.allCases {
            (hits + fill).initialize(to: Self.noteOn(voice.note, at: 0, id: UInt64(fill + 1)))
            fill += 1
        }
        let refreshing = Self.makeDrums(DrumKitParams())
        let steady = Self.makeDrums(DrumKitParams())
        refreshing.render(events: UnsafeBufferPointer(start: hits, count: 8), renderStart: 0,
                          frameCount: 1, output: output)
        steady.render(events: UnsafeBufferPointer(start: hits, count: 8), renderStart: 0,
                      frameCount: 1, output: output)
        let rounds = 1_000
        let adopting = MallocProbe.events(slot: slot, warmup: {
            var r = 0
            while r < 8 {
                refreshing.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: Self.quantum,
                                   channelCount: 2)
                refreshing.render(events: empty, renderStart: 1, frameCount: 0, output: output)
                r += 1
            }
        }) {
            var r = 0
            while r < rounds {
                refreshing.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: Self.quantum,
                                   channelCount: 2)
                refreshing.render(events: empty, renderStart: 1, frameCount: 0, output: output)
                r += 1
            }
        }
        let notAdopting = MallocProbe.events(slot: slot, warmup: {
            var r = 0
            while r < 8 {
                steady.render(events: empty, renderStart: 1, frameCount: 0, output: output)
                r += 1
            }
        }) {
            var r = 0
            while r < rounds {
                steady.render(events: empty, renderStart: 1, frameCount: 0, output: output)
                r += 1
            }
        }
        Self.record("rtfix.refresh.adopting.events.per1000", "\(adopting)")
        Self.record("rtfix.refresh.notAdopting.events.per1000", "\(notAdopting)")
        #expect(adopting == notAdopting,
                "1 000 kit adoptions raised \(adopting) malloc events; 1 000 plain renders \(notAdopting)")
        // INVARIANCE CONTROL: re-reading an unchanged kit changes no sample.
        let a = try #require(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.quantum)))
        let b = try #require(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.quantum)))
        a.frameLength = AVAudioFrameCount(Self.quantum)
        b.frameLength = AVAudioFrameCount(Self.quantum)
        refreshing.render(events: empty, renderStart: 1, frameCount: Self.quantum,
                          output: UnsafeMutableAudioBufferListPointer(a.mutableAudioBufferList))
        steady.render(events: empty, renderStart: 1, frameCount: Self.quantum,
                      output: UnsafeMutableAudioBufferListPointer(b.mutableAudioBufferList))
        let ca = try #require(a.floatChannelData), cb = try #require(b.floatChannelData)
        var same = true, energy = 0.0, i = 0
        while i < Self.quantum {
            if ca[0][i] != cb[0][i] || ca[1][i] != cb[1][i] { same = false }
            energy += Double(ca[0][i]) * Double(ca[0][i])
            i += 1
        }
        #expect(same, "re-adopting the same kit changed the audio")
        #expect(energy > 1e-6, "the eight voices are silent after the measurement (\(energy))")
    }

    @Test("W8-RTFIX F1: voice(forSlot:) inverts slot for all eight voices, refuses every other slot, allocates nothing")
    func rtfixVoiceForSlot() throws {
        for voice in DrumVoice.allCases {
            #expect(DrumVoice.voice(forSlot: voice.slot) == voice, "slot \(voice.slot)")
        }
        for slot: Int32 in [8, 9, 16, -1, .min, .max] {
            #expect(DrumVoice.voice(forSlot: slot) == nil, "slot \(slot)")
        }
        guard let probe = MallocProbe.slot() else {
            Issue.record("malloc_logger is unavailable — FAILURE, not a skip.")
            return
        }
        var sink: Int32 = 0
        let events = MallocProbe.events(slot: probe, warmup: {
            var s: Int32 = -1
            while s <= 8 { sink &+= DrumVoice.voice(forSlot: s)?.slot ?? -1; s += 1 }
        }) {
            var call: Int32 = 0
            while call < 1_000 {
                sink &+= DrumVoice.voice(forSlot: call % 10)?.slot ?? -1
                call += 1
            }
        }
        Self.record("rtfix.voiceForSlot.events.per1000", "\(events)")
        #expect(events == 0, "voice(forSlot:) raised \(events) malloc events in 1 000 calls")
        #expect(sink != 0)
    }

    /// F4: the render's kit read. Same value as the KeyPath subscript for
    /// every voice of a kit whose eight voices all differ, and 0 malloc events
    /// for 1 000 reads — ASSERTED (F-4's `noteOnKitReadEvents` only records the
    /// KeyPath read, which main-actor callers keep).
    @Test("W8-RTFIX F4: voiceParams(_:) reads what the subscript reads, and allocates nothing")
    func rtfixVoiceParamsAccessor() throws {
        var kit = DrumKitParams()
        for voice in DrumVoice.allCases {
            kit[voice].level = 0.1 + 0.1 * Double(voice.slot)
            kit[voice].tune += 0.01 * Double(voice.slot)
        }
        var distinct = true
        for voice in DrumVoice.allCases {
            #expect(kit.voiceParams(voice) == kit[voice], "\(voice): the accessor and the subscript disagree")
            for other in DrumVoice.allCases where other != voice && kit[other] == kit[voice] {
                distinct = false
            }
        }
        #expect(distinct, "two voices share parameters, so a mix-up could pass")
        guard let probe = MallocProbe.slot() else {
            Issue.record("malloc_logger is unavailable — FAILURE, not a skip.")
            return
        }
        let voices = UnsafeMutablePointer<DrumVoice>.allocate(capacity: 8)
        defer { voices.deallocate() }
        var fill = 0
        for voice in DrumVoice.allCases {
            (voices + fill).initialize(to: voice)
            fill += 1
        }
        var sink = 0.0
        let events = MallocProbe.events(slot: probe, warmup: {
            var v = 0
            while v < 8 { sink += kit.voiceParams(voices[v]).level; v += 1 }
        }) {
            var call = 0
            while call < 1_000 {
                sink += kit.voiceParams(voices[call % 8]).level
                call += 1
            }
        }
        Self.record("rtfix.voiceParams.events.per1000", "\(events)")
        #expect(events == 0, "voiceParams raised \(events) malloc events in 1 000 reads")
        #expect(sink > 0)
    }

    /// F7, RECORDED (a ruling input, not a fix): the hats at the top of their
    /// trim (+36 dB) and the cymbal at the top of its own (+24 dB), the kit
    /// gain at the top of `gainRange`, struck at velocity 127. The asserted
    /// part is the gain law: against the same hit at trim 0 and gain 1, the
    /// peak rises by exactly 20·log10(2) + trim dB (both are final multiplies).
    /// With `RTFIX_F7_OUT` set, each render is also written there as a 32-bit
    /// float WAV for an independent true-peak meter.
    @Test("W8-RTFIX F7 (recorded): the loudest hats and cymbal the trims allow")
    func rtfixLoudestTrimPeaks() async throws {
        var top = DrumKitParams()
        top.gain = DrumKitParams.gainRange.upperBound
        top.hatsLevelDb = DrumKitParams.hatsLevelDbRange.upperBound
        top.cymbalsLevelDb = DrumKitParams.cymbalsLevelDbRange.upperBound
        var worst = top
        worst.accentDepth = DrumKitParams.accentDepthRange.upperBound
        for voice in [DrumVoice.closedHat, .openHat, .cymbal] { worst[voice].level = 1 }
        let reference = DrumKitParams()
        func peak(_ channels: [[Float]]) -> Float {
            var p: Float = 0
            for channel in channels { for x in channel { p = max(p, abs(x)) } }
            return p
        }
        let outDir = ProcessInfo.processInfo.environment["RTFIX_F7_OUT"]
        for voice in [DrumVoice.closedHat, .openHat, .cymbal] {
            let trim = voice == .cymbal ? top.cymbalsLevelDb : top.hatsLevelDb
            var peaks: [String: Float] = [:]
            for (label, kit) in [("reference", reference), ("top", top), ("worst", worst)] {
                let channels = try await Self.render(
                    Self.makeDrums(kit), events: [Self.noteOn(voice.note, at: 0, velocity: 127, id: 1)],
                    frames: Self.rtfixFrames)
                #expect(channels.allSatisfy { channel in channel.allSatisfy { $0.isFinite } },
                        "\(voice)/\(label): a non-finite sample")
                let p = peak(channels)
                peaks[label] = p
                Self.record("rtfix.f7.\(voice.rawValue).\(label).samplePeakDbfs",
                            String(format: "%.3f", 20 * log10(Double(p))))
                if let outDir {
                    try Self.rtfixWriteWAV(channels, to: URL(fileURLWithPath: outDir)
                        .appendingPathComponent("f7-\(voice.rawValue)-\(label).wav"))
                }
            }
            let rise = 20 * log10(Double(peaks["top"] ?? 0) / Double(peaks["reference"] ?? 1))
            let law = 20 * log10(DrumKitParams.gainRange.upperBound) + trim
            #expect(abs(rise - law) < 0.01, "\(voice): the peak rose \(rise) dB, the gain law says \(law)")
        }
    }

    static func rtfixWriteWAV(_ channels: [[Float]], to url: URL) throws {
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(channels[0].count)))
        buffer.frameLength = AVAudioFrameCount(channels[0].count)
        let data = try #require(buffer.floatChannelData)
        for channel in 0..<2 {
            channels[channel].withUnsafeBufferPointer { source in
                if let base = source.baseAddress { data[channel].update(from: base, count: source.count) }
            }
        }
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}
