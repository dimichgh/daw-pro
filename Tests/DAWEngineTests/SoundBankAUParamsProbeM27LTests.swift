import Accelerate
import AudioToolbox
import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// m27-l (W8-M27L, 2026-10-07): DOES A SOUND BANK EXPOSE ANY USEFUL AU PARAMETERS?
//
// A MEASUREMENT, not a product test. It decides whether the `.soundBank` refusal in `ProjectStore.resolveHostedAUTarget`
// (a pure KIND check: it never asks the hosted unit) should stay, or whether a short list of AUSampler parameters is
// worth exposing. Findings and the recommendation: docs/research/2026-10-07-sound-bank-au-params.md. Bars were
// pre-registered in the lane's PREDICTIONS.md before the first run.
//
// Subject: Apple's AUSampler ("aumu"/"samp"/"appl"), hosted by `AUHostRegistry` through the SAME `OfflineRenderer` path
// every `.soundBank` track uses, with the system General MIDI bank: melodic program 0 (bank MSB 121) and the Standard
// Drum Kit (bank MSB 120, program 0).
//
// Two dump instruments, so they can disagree: (1) the v3 `parameterTree.allParameters`, which is exactly what
// `au.describeParams` reads (`AudioEngine.describeHostedAUParameters`), and (2) the raw v2 `kAudioUnitProperty_
// ParameterList` + `ParameterInfo` walk over every scope (Global, Input, Output, Group, Part, Note, Layer, LayerItem)
// and element, which is the only place a parameter's DEFAULT and full flags live (an `AUParameter` has no default).
//
// "Exposes a parameter" is separated from "the parameter does something": every parameter in the tree is moved
// through `parameter.value =` (the `au.setParam` write path), on a FRESH renderer, between prepare and render, and the
// render is compared with the default render (level per channel, a log-frequency spectral shift in cents, a 24-band
// shape distance).
//
// Validity (asserted; a red means "cannot tell", never "the parameter does nothing"): the track reaches `.ready`; two
// default renders null; a velocity change moves the level (the metric can see a change); the bank really loaded (an
// unloaded AUSampler plays its factory sine, m10-n T6); every moved value reads back before AND after the render (a
// rate renegotiation would reset it); the positive control, Apple's AULowpass, publishes a non-empty tree through both
// dump instruments and its cutoff, moved through the same `parameter.value =` path as an insert on the same track,
// audibly cuts the render. The findings themselves are printed and written to `$M27L_OUT/probe.json`, never asserted.
//
// Env-gated (`M27L_PROBE=1`). Nonisolated suite (the `@MainActor` suite cap in `MainActorOccupancySiteTests`); the
// renderer is reached through `@MainActor static` helpers. Headless: no audio device, no engine, no app.

@Suite("W8-M27L sound-bank AU parameter probe (M27L_PROBE=1 only)")
struct SoundBankAUParamsProbeM27LTests {

    static let env = ProcessInfo.processInfo.environment
    static let enabled = env["M27L_PROBE"] == "1"

    // MARK: - Fixed harness constants (pre-registered)

    static let bpm = 120.0
    static let sampleRate = 48_000.0
    /// Notes land at beat 1 (frame 24 000), the `SoundBankHostingTests` idiom: never in the first block.
    static let onsetBeat = 1.0
    static let onsetFrame = 24_000
    static let renderSeconds = 2.5
    static let velocity = 100
    static let lowpass = AudioUnitComponentID(type: "aufx", subType: "lpas", manufacturer: "appl")

    enum Subject: String, CaseIterable, Sendable {
        case piano, kit

        var descriptor: InstrumentDescriptor {
            switch self {
            case .piano:
                return InstrumentDescriptor(kind: .soundBank, soundBank: SoundBankConfig(
                    source: .generalMIDI, program: 0, bankMSB: GMProgramCatalog.melodicBankMSB))
            case .kit:
                let kit = GMProgramCatalog.standardDrumKit
                return InstrumentDescriptor(kind: .soundBank, soundBank: SoundBankConfig(
                    source: .generalMIDI, program: kit.program, bankMSB: kit.bankMSB))
            }
        }
        /// C4 for 2 beats (1 s) on the piano; an acoustic snare (38) for half a beat on the kit.
        var pitch: Int { self == .piano ? 60 : 38 }
        var lengthBeats: Double { self == .piano ? 2 : 0.5 }
        /// The spectrum window: 50 ms after the onset for 32 768 frames (piano sustain), or from the onset for 16 384
        /// frames (the snare's body). Both end before the note-off.
        var windowOffset: Int { self == .piano ? 2_400 : 0 }
        var windowLength: Int { self == .piano ? 32_768 : 16_384 }
    }

    // MARK: - Dump rows (Sendable: nothing AU-typed leaves the main actor)

    struct TreeRow: Sendable {
        let address: UInt64
        let identifier: String
        let displayName: String
        let keyPath: String
        let unitRaw: UInt32
        let unitName: String?
        let minValue: Double
        let maxValue: Double
        let value: Double
        let flagsRaw: UInt32
        let writable: Bool
        let valueStringCount: Int
    }

    struct RawRow: Sendable {
        let scope: UInt32
        let element: UInt32
        let id: UInt32
        let name: String
        let unitRaw: UInt32
        let minValue: Double
        let maxValue: Double
        let defaultValue: Double
        let value: Double?
        let flagsRaw: UInt32
        let infoStatus: OSStatus
    }

    struct ScopeNote: Sendable {
        let scope: UInt32
        let elementCount: Int?
        let elementCountStatus: OSStatus
        let elementsWalked: Int
        let listStatuses: [OSStatus]
        let parameterCount: Int
    }

    struct Dump: Sendable {
        let tree: [TreeRow]
        let hasTree: Bool
        let raw: [RawRow]
        let scopes: [ScopeNote]
        let isV2Bridge: Bool
        /// The AU's `fullState` structure (key names only, never the blob).
        let stateTopKeys: [String]
        let stateKeyNames: [String]
        let stateBytes: Int
        /// Read-only summary: `voice count`, the first `Filters` entry, and how many Layers/Zones/Envelopes it holds.
        let stateSummary: [String]
    }

    struct Move: Sendable {
        let address: UInt64
        let identifier: String
        let value: Double
    }

    struct Render: Sendable {
        let left: [Float]
        let right: [Float]
        /// Tree read-backs of every moved address, before and after the render.
        let readBefore: [Double]
        let readAfter: [Double]
        /// Raw Global-scope values of every v2 Global parameter, after the render (id -> value).
        let rawGlobalAfter: [UInt32: Double]
        let stateBytes: Data?
    }

    static let scopeNames: [UInt32: String] = [0: "Global", 1: "Input", 2: "Output", 3: "Group", 4: "Part", 5: "Note",
                                               6: "Layer", 7: "LayerItem"]

    // MARK: - Hosting (main actor)

    static func track(_ subject: Subject, velocity: Int = velocity, effects: [EffectDescriptor] = []) -> Track {
        Track(name: "M27L \(subject.rawValue)", kind: .instrument,
              clips: [Clip(name: "m27l", startBeat: 0, lengthBeats: 8, notes: [
                  MIDINote(pitch: subject.pitch, velocity: velocity, startBeat: onsetBeat,
                           lengthBeats: subject.lengthBeats),
              ])],
              instrument: subject.descriptor, effects: effects)
    }

    /// A FRESH renderer per call (no AU state can carry over), prepared; the sound-bank track must reach `.ready`.
    @MainActor
    static func prepared(_ track: Track) async throws -> OfflineRenderer {
        let renderer = OfflineRenderer()
        await renderer.prepareAudioUnits(tracks: [track])
        let status = renderer.auRegistry.status[track.id]
        try #require(status == .ready, "M27L: \(track.name) did not reach .ready (\(String(describing: status))): CANNOT TELL")
        return renderer
    }

    @MainActor
    static func instrumentAU(_ renderer: OfflineRenderer, _ track: Track) throws -> AUAudioUnit {
        try #require(renderer.auRegistry.preparedInstrument(forTrack: track.id)?.auAudioUnit,
                     "M27L: no hosted instrument for \(track.name)")
    }

    /// Render one track with the given tree moves applied between prepare and render (the `au.setParam` path:
    /// `tree.parameter(withAddress:)` then `parameter.value =`). `lowpassCutoff` moves the AULowpass insert's Hz param.
    @MainActor
    static func render(_ subject: Subject, velocity: Int = velocity, moves: [Move] = [],
                       lowpassEffectID: UUID? = nil, lowpassCutoff: Double? = nil) async throws -> Render {
        var effects: [EffectDescriptor] = []
        if let lowpassEffectID {
            effects = [EffectDescriptor(id: lowpassEffectID, kind: .audioUnit,
                                        audioUnit: AudioUnitConfig(component: lowpass))]
        }
        let subjectTrack = track(subject, velocity: velocity, effects: effects)
        let renderer = try await prepared(subjectTrack)
        let au = try instrumentAU(renderer, subjectTrack)
        let tree = au.parameterTree
        var before: [Double] = []
        for move in moves {
            let parameter = try #require(tree?.parameter(withAddress: move.address),
                                         "M27L: address \(move.address) (\(move.identifier)) not in the tree")
            parameter.value = AUValue(move.value)
            before.append(Double(parameter.value))
        }
        if let lowpassEffectID {
            let hosted = try #require(renderer.auRegistry.preparedEffect(forEffect: lowpassEffectID),
                                      "M27L: the AULowpass insert was not prepared: positive control CANNOT RUN")
            let cutoff = try #require(hosted.auAudioUnit.parameterTree?.allParameters.first { $0.unit == .hertz },
                                      "M27L: AULowpass has no Hz parameter")
            if let lowpassCutoff { cutoff.value = AUValue(lowpassCutoff) }
            print("[M27L] AULowpass insert cutoff = \(cutoff.value) Hz")
        }
        let audio = try renderer.render(tracks: [subjectTrack], tempoMap: TempoMap(constantBPM: bpm),
                                        fromBeat: 0, durationSeconds: renderSeconds)
        var after: [Double] = []
        for move in moves {
            after.append(Double(tree?.parameter(withAddress: move.address)?.value ?? .nan))
        }
        var rawGlobal: [UInt32: Double] = [:]
        if let bridge = au as? AUAudioUnitV2Bridge {
            for id in parameterIDs(bridge.audioUnit, scope: kAudioUnitScope_Global, element: 0).ids {
                var value: AudioUnitParameterValue = 0
                if AudioUnitGetParameter(bridge.audioUnit, id, kAudioUnitScope_Global, 0, &value) == noErr {
                    rawGlobal[id] = Double(value)
                }
            }
        }
        let state = renderer.auRegistry.instrumentState(forTrack: subjectTrack.id)
        let channels = audio.channelData
        return Render(left: channels[0], right: channels.count > 1 ? channels[1] : channels[0],
                      readBefore: before, readAfter: after, rawGlobalAfter: rawGlobal, stateBytes: state)
    }

    // MARK: - The two dump instruments

    static func parameterIDs(_ unit: AudioUnit, scope: AudioUnitScope, element: AudioUnitElement)
        -> (status: OSStatus, ids: [AudioUnitParameterID]) {
        var size: UInt32 = 0
        let infoStatus = AudioUnitGetPropertyInfo(unit, kAudioUnitProperty_ParameterList, scope, element, &size, nil)
        guard infoStatus == noErr else { return (infoStatus, []) }
        let count = Int(size) / MemoryLayout<AudioUnitParameterID>.size
        guard count > 0 else { return (noErr, []) }
        var ids = [AudioUnitParameterID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBytes { buffer in
            AudioUnitGetProperty(unit, kAudioUnitProperty_ParameterList, scope, element, buffer.baseAddress!, &size)
        }
        return (status, status == noErr ? Array(ids.prefix(Int(size) / MemoryLayout<AudioUnitParameterID>.size)) : [])
    }

    static func parameterName(_ info: AudioUnitParameterInfo) -> String {
        if info.flags.contains(.flag_HasCFNameString), let cf = info.cfNameString {
            return info.flags.contains(.flag_CFNameRelease)
                ? cf.takeRetainedValue() as String : cf.takeUnretainedValue() as String
        }
        var tuple = info.name
        return withUnsafeBytes(of: &tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// Element enumeration is capped so a Group/Part scope with many elements cannot flood the log.
    static let elementCap = 64

    @MainActor
    static func dumpSurface(_ au: AUAudioUnit) -> Dump {
        let tree = au.parameterTree
        let treeRows: [TreeRow] = (tree?.allParameters ?? []).map { parameter in
            TreeRow(address: parameter.address, identifier: parameter.identifier, displayName: parameter.displayName,
                    keyPath: parameter.keyPath, unitRaw: parameter.unit.rawValue,
                    unitName: parameter.unitName, minValue: Double(parameter.minValue),
                    maxValue: Double(parameter.maxValue), value: Double(parameter.value),
                    flagsRaw: parameter.flags.rawValue, writable: parameter.flags.contains(.flag_IsWritable),
                    valueStringCount: parameter.valueStrings?.count ?? 0)
        }
        var rawRows: [RawRow] = []
        var scopes: [ScopeNote] = []
        let bridge = au as? AUAudioUnitV2Bridge
        if let unit = bridge?.audioUnit {
            for scope: AudioUnitScope in 0...7 {
                var count: UInt32 = 0
                var size = UInt32(MemoryLayout<UInt32>.size)
                let countStatus = AudioUnitGetProperty(unit, kAudioUnitProperty_ElementCount, scope, 0, &count, &size)
                let elements = scope == kAudioUnitScope_Global
                    ? 1 : (countStatus == noErr ? min(Int(count), elementCap) : 1)
                var listStatuses: [OSStatus] = []
                var parameterCount = 0
                for element in 0..<max(elements, 1) {
                    let (listStatus, ids) = parameterIDs(unit, scope: scope, element: AudioUnitElement(element))
                    listStatuses.append(listStatus)
                    parameterCount += ids.count
                    for id in ids {
                        var info = AudioUnitParameterInfo()
                        var infoSize = UInt32(MemoryLayout<AudioUnitParameterInfo>.size)
                        let infoStatus = AudioUnitGetProperty(unit, kAudioUnitProperty_ParameterInfo, scope, id,
                                                              &info, &infoSize)
                        var value: AudioUnitParameterValue = 0
                        let valueStatus = AudioUnitGetParameter(unit, id, scope, AudioUnitElement(element), &value)
                        rawRows.append(RawRow(
                            scope: scope, element: UInt32(element), id: id,
                            name: infoStatus == noErr ? parameterName(info) : "(info OSStatus \(infoStatus))",
                            unitRaw: info.unit.rawValue, minValue: Double(info.minValue),
                            maxValue: Double(info.maxValue), defaultValue: Double(info.defaultValue),
                            value: valueStatus == noErr ? Double(value) : nil, flagsRaw: info.flags.rawValue,
                            infoStatus: infoStatus))
                    }
                }
                scopes.append(ScopeNote(scope: scope, elementCount: countStatus == noErr ? Int(count) : nil,
                                        elementCountStatus: countStatus, elementsWalked: max(elements, 1),
                                        listStatuses: listStatuses, parameterCount: parameterCount))
            }
        }
        let state = au.fullState ?? [:]
        var names = Set<String>()
        collectKeys(state, depth: 0, into: &names)
        let bytes = (try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0))?.count
        var summary: [String] = ["voice count = \(state["voice count"].map { "\($0)" } ?? "absent")"]
        for key in ["Layers", "Zones", "Envelopes", "Filters", "LFOs", "Connections"] {
            summary.append("\(key): \(countArrays(named: key, in: state, depth: 0)) entries in total")
        }
        if let filter = firstValue(named: "Filters", in: state, depth: 0) {
            summary.append("first Filters entry: " + String(String(describing: filter).prefix(400))
                .replacingOccurrences(of: "\n", with: " "))
        }
        return Dump(tree: treeRows, hasTree: tree != nil, raw: rawRows, scopes: scopes, isV2Bridge: bridge != nil,
                    stateTopKeys: state.keys.sorted(), stateKeyNames: names.sorted(), stateBytes: bytes ?? -1,
                    stateSummary: summary)
    }

    /// Total element count of every array (or 1 per dictionary) stored under `name`, anywhere in the state.
    static func countArrays(named name: String, in value: Any, depth: Int) -> Int {
        guard depth < 10 else { return 0 }
        var total = 0
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if key == name { total += (child as? [Any])?.count ?? 1 }
                total += countArrays(named: name, in: child, depth: depth + 1)
            }
        } else if let array = value as? [Any] {
            for child in array { total += countArrays(named: name, in: child, depth: depth + 1) }
        }
        return total
    }

    /// The first value stored under `name` (an array's first element), depth-first.
    static func firstValue(named name: String, in value: Any, depth: Int) -> Any? {
        guard depth < 10 else { return nil }
        if let dictionary = value as? [String: Any] {
            if let hit = dictionary[name] { return (hit as? [Any])?.first ?? hit }
            for key in dictionary.keys.sorted() {
                if let hit = firstValue(named: name, in: dictionary[key]!, depth: depth + 1) { return hit }
            }
        } else if let array = value as? [Any] {
            for child in array { if let hit = firstValue(named: name, in: child, depth: depth + 1) { return hit } }
        }
        return nil
    }

    static func collectKeys(_ value: Any, depth: Int, into names: inout Set<String>) {
        guard depth < 10, names.count < 400 else { return }
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                names.insert(key)
                collectKeys(child, depth: depth + 1, into: &names)
            }
        } else if let array = value as? [Any] {
            for child in array.prefix(64) { collectKeys(child, depth: depth + 1, into: &names) }
        }
    }

    // MARK: - Signal helpers (nonisolated)

    static func dB(_ ratio: Double) -> Double { 20 * log10(max(ratio, 1e-30)) }

    static func rms(_ x: [Float], _ range: Range<Int>) -> Double {
        let r = range.clamped(to: 0..<x.count)
        guard !r.isEmpty else { return 0 }
        var sum = 0.0
        for i in r { sum += Double(x[i]) * Double(x[i]) }
        return (sum / Double(r.count)).squareRoot()
    }

    static func maxAbsDiff(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count else { return .infinity }
        var worst: Float = 0
        for i in a.indices { worst = max(worst, abs(a[i] - b[i])) }
        return Double(worst)
    }

    /// The level window: the onset to 1.5 s after it.
    static var levelRange: Range<Int> { onsetFrame..<(onsetFrame + Int(1.5 * sampleRate)) }

    static func mono(_ render: Render) -> [Float] {
        zip(render.left, render.right).map { ($0 + $1) * 0.5 }
    }

    /// Hann-windowed power spectrum of `x[start ..< start + n]` (n a power of two). Index = bin, width sr / n.
    static func powerSpectrum(_ x: [Float], start: Int, n: Int) -> [Float] {
        let log2n = vDSP_Length(log2(Double(n)).rounded())
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        var frame = [Float](repeating: 0, count: n)
        for i in 0..<n where start + i < x.count { frame[i] = x[start + i] }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(n))
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var power = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { realPointer in
            imag.withUnsafeMutableBufferPointer { imagPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { framePointer in
                    framePointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n / 2))
            }
        }
        power[0] = 0  // DC and Nyquist share bin 0 in the packed format
        return power
    }

    static func bandEnergy(_ power: [Float], n: Int, _ low: Double, _ high: Double) -> Double {
        let binHz = sampleRate / Double(n)
        let lo = max(1, Int((low / binHz).rounded(.up)))
        let hi = min(power.count - 1, Int((high / binHz).rounded(.down)))
        guard lo <= hi else { return 0 }
        var sum = 0.0
        for i in lo...hi { sum += Double(power[i]) }
        return sum
    }

    /// Fraction of the spectrum's energy above 400 Hz (20 Hz floor): the bank-loaded guard. The factory sine at C4
    /// (261.6 Hz) or D2 (73 Hz) has essentially none.
    static func energyAbove400(_ power: [Float], n: Int) -> Double {
        let total = bandEnergy(power, n: n, 20, sampleRate / 2)
        return total > 0 ? bandEnergy(power, n: n, 400, sampleRate / 2) / total : 0
    }

    /// The strongest partial between 80 Hz and 2 kHz, parabolically interpolated on log power.
    static func peakHz(_ power: [Float], n: Int) -> Double {
        let binHz = sampleRate / Double(n)
        let lo = Int(80 / binHz), hi = min(power.count - 2, Int(2_000 / binHz))
        var best = lo
        for i in lo...hi where power[i] > power[best] { best = i }
        let a = log(Double(max(power[best - 1], 1e-30)))
        let b = log(Double(max(power[best], 1e-30)))
        let c = log(Double(max(power[best + 1], 1e-30)))
        let denominator = a - 2 * b + c
        let offset = denominator != 0 ? 0.5 * (a - c) / denominator : 0
        return (Double(best) + offset) * binHz
    }

    /// Magnitude resampled onto a log-frequency grid: 50 Hz upward in 2-cent steps, 7 octaves (4 200 points).
    static let gridStepCents = 2.0
    static let gridPoints = 4_200
    static func logGrid(_ power: [Float], n: Int) -> [Float] {
        let binHz = sampleRate / Double(n)
        return (0..<gridPoints).map { index in
            let hz = 50 * pow(2, Double(index) * gridStepCents / 1_200)
            let position = hz / binHz
            let lower = Int(position)
            guard lower + 1 < power.count else { return 0 }
            let fraction = Float(position - Double(lower))
            let magnitude = (1 - fraction) * power[lower].squareRoot() + fraction * power[lower + 1].squareRoot()
            return magnitude
        }
    }

    /// The spectral shift (cents) that best aligns `moved` onto `reference`: the argmax over -2 600 ... +2 600 cents
    /// of the normalized correlation of their log-frequency magnitude grids. A gain change reads 0; a transposition
    /// reads its interval. Returns (shift, correlation at the best shift, correlation at zero shift).
    static func spectralShift(reference: [Float], moved: [Float]) -> (cents: Double, best: Double, atZero: Double) {
        let maxSteps = Int(2_600 / gridStepCents)
        func correlation(_ steps: Int) -> Double {
            // moved[i + steps] against reference[i]
            let start = max(0, -steps), end = min(gridPoints, gridPoints - steps)
            guard end - start > 200 else { return 0 }
            var dot: Float = 0, ra: Float = 0, mb: Float = 0
            reference.withUnsafeBufferPointer { r in
                moved.withUnsafeBufferPointer { m in
                    let count = vDSP_Length(end - start)
                    vDSP_dotpr(r.baseAddress! + start, 1, m.baseAddress! + start + steps, 1, &dot, count)
                    vDSP_svesq(r.baseAddress! + start, 1, &ra, count)
                    vDSP_svesq(m.baseAddress! + start + steps, 1, &mb, count)
                }
            }
            let denominator = Double(ra).squareRoot() * Double(mb).squareRoot()
            return denominator > 0 ? Double(dot) / denominator : 0
        }
        var bestSteps = 0
        var best = -Double.infinity
        for steps in -maxSteps...maxSteps {
            let value = correlation(steps)
            if value > best { best = value; bestSteps = steps }
        }
        return (Double(bestSteps) * gridStepCents, best, correlation(0))
    }

    /// 24 log-spaced bands, 50 Hz to 16 kHz, normalized to sum 1; L1 distance between two such shapes (0 = same shape).
    static func bandShape(_ power: [Float], n: Int) -> [Double] {
        let edges = (0...24).map { 50 * pow(16_000.0 / 50, Double($0) / 24) }
        let energies = (0..<24).map { bandEnergy(power, n: n, edges[$0], edges[$0 + 1]) }
        let total = energies.reduce(0, +)
        return total > 0 ? energies.map { $0 / total } : energies
    }

    static func shapeDistance(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) }
    }

    static func f(_ x: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", x) }

    /// Variadic print: each part has a String context, so long log lines type-check quickly.
    static func say(_ parts: String...) { print(parts.joined()) }

    /// JSONSerialization rejects NaN and infinity: those are written as strings.
    static func jsonNumber(_ x: Double) -> Any { x.isFinite ? x : String(x) }

    // MARK: - Output

    static func outputDirectory() throws -> URL {
        let url = env["M27L_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("M27L-sound-bank-au-params",
                                                                              isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Stereo 32-bit float WAV (the `TestSignals.write` settings, two channels).
    static func writeWAV(_ render: Render, _ name: String, in dir: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: dir.appendingPathComponent("\(name).wav"), settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                                channels: 2, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format,
                                                   frameCapacity: AVAudioFrameCount(render.left.count)))
        let channels = try #require(buffer.floatChannelData)
        for index in render.left.indices {
            channels[0][index] = render.left[index]
            channels[1][index] = render.right[index]
        }
        buffer.frameLength = AVAudioFrameCount(render.left.count)
        try file.write(from: buffer)
    }

    // MARK: - Move rules (pre-registered: one rule per unit, so an UNEXPECTED parameter is still measured)

    /// The moved values for one tree parameter: decibels -12 and +6 (relative to its current value), semitones +12,
    /// cents +50, pan hard left (its minimum); anything else 40 % of the way from its value to its far end.
    static func moves(for row: TreeRow) -> [Double] {
        func clamp(_ v: Double) -> Double { min(max(v, row.minValue), row.maxValue) }
        switch AudioUnitParameterUnit(rawValue: row.unitRaw) {
        case .decibels: return [clamp(row.value - 12), clamp(row.value + 6)]
        case .relativeSemiTones: return [clamp(row.value + 12)]
        case .cents: return [clamp(row.value + 50)]
        case .pan: return [row.minValue]
        default:
            let far = (row.maxValue - row.value) >= (row.value - row.minValue) ? row.maxValue : row.minValue
            return [clamp(row.value + 0.4 * (far - row.value))]
        }
    }

    // MARK: - The probe

    @Test("M27L: dump the AUSampler parameter surface on a GM program and the drum kit, and measure what each moved parameter does to a rendered note",
          .enabled(if: SoundBankAUParamsProbeM27LTests.enabled))
    func probeSoundBankParameterSurface() async throws {
        try await Self.runProbe()
    }

    @MainActor
    static func runProbe() async throws {
        let out = try outputDirectory()
        print("[M27L] output: \(out.path)")
        let harness: [String: Any] = [
            "bpm": bpm, "sampleRate": sampleRate, "onsetFrame": onsetFrame, "renderSeconds": renderSeconds,
            "velocity": velocity, "levelWindow": [levelRange.lowerBound, levelRange.upperBound],
        ]
        var json: [String: Any] = ["harness": harness]

        // ---- Positive control for both dump instruments: AULowpass, hosted by the same registry.
        let controlTrack = track(.piano, effects: [EffectDescriptor(
            id: UUID(), kind: .audioUnit, audioUnit: AudioUnitConfig(component: lowpass))])
        let controlRenderer = try await prepared(controlTrack)
        let controlEffect = try #require(controlRenderer.auRegistry.preparedEffect(
            forEffect: controlTrack.effects[0].id), "M27L: AULowpass control did not prepare")
        let controlDump = dumpSurface(controlEffect.auAudioUnit)
        say("[M27L] CONTROL AULowpass: tree \(controlDump.tree.count) params, raw v2 Global "
              , "\(controlDump.raw.filter { $0.scope == 0 }.count), v2 bridge \(controlDump.isV2Bridge)")
        for row in controlDump.tree {
            say("[M27L]   control tree \(row.address) '\(row.identifier)' '\(row.displayName)' unit \(row.unitRaw) "
                  , "[\(row.minValue), \(row.maxValue)] value \(row.value) flags 0x\(String(row.flagsRaw, radix: 16))")
        }
        #expect(controlDump.tree.count >= 1, "M27L: the tree dump read NOTHING on AULowpass: the probe is broken")
        #expect(controlDump.raw.contains { $0.scope == 0 },
                "M27L: the raw v2 dump read NOTHING on AULowpass Global: the probe is broken")

        var subjectsJSON: [String: Any] = [:]
        var dumps: [Subject: Dump] = [:]
        for subject in Subject.allCases {
            let n = subject.windowLength
            let spectrumStart = onsetFrame + subject.windowOffset

            // ---- The dump, on a freshly loaded unit.
            let dumpTrack = track(subject)
            let dumpRenderer = try await prepared(dumpTrack)
            let subjectDump = dumpSurface(try instrumentAU(dumpRenderer, dumpTrack))
            dumps[subject] = subjectDump
            say("[M27L] \(subject.rawValue): v2 bridge \(subjectDump.isV2Bridge), tree \(subjectDump.hasTree ? "present" : "NIL") "
                  , "with \(subjectDump.tree.count) params; raw v2 \(subjectDump.raw.count) params")
            for row in subjectDump.tree {
                say("[M27L]   tree \(row.address) (0x\(String(row.address, radix: 16))) id '\(row.identifier)' name '\(row.displayName)' "
                      , "keyPath '\(row.keyPath)' unit \(row.unitRaw)\(row.unitName.map { " '\($0)'" } ?? "") "
                      , "[\(row.minValue), \(row.maxValue)] value \(row.value) flags 0x\(String(row.flagsRaw, radix: 16)) "
                      , "writable \(row.writable) valueStrings \(row.valueStringCount)")
            }
            for scope in subjectDump.scopes {
                say("[M27L]   scope \(scope.scope) \(scopeNames[scope.scope] ?? "?"): elementCount "
                      , "\(scope.elementCount.map { String($0) } ?? "n/a (OSStatus \(scope.elementCountStatus))"), walked "
                      , "\(scope.elementsWalked), list statuses \(Set(scope.listStatuses).sorted()), params \(scope.parameterCount)")
            }
            for row in subjectDump.raw {
                say("[M27L]   raw scope \(row.scope) el \(row.element) id \(row.id) '\(row.name)' unit \(row.unitRaw) "
                      , "[\(row.minValue), \(row.maxValue)] default \(row.defaultValue) value "
                      , "\(row.value.map { String($0) } ?? "n/a") flags 0x\(String(row.flagsRaw, radix: 16)) info \(row.infoStatus)")
            }
            print("[M27L]   fullState: \(subjectDump.stateBytes) bytes, top keys \(subjectDump.stateTopKeys)")
            print("[M27L]   fullState key names (depth<=10): \(subjectDump.stateKeyNames)")
            for line in subjectDump.stateSummary { print("[M27L]   fullState \(line)") }

            // ---- Validity: determinism null, the bank-loaded guard, the velocity control.
            let base = try await render(subject)
            let again = try await render(subject)
            let nullDiff = max(maxAbsDiff(base.left, again.left), maxAbsDiff(base.right, again.right))
            let baseMono = mono(base)
            let baseLevel = rms(baseMono, levelRange)
            let nullResidualDb = dB(rms(zip(mono(again), baseMono).map { $0 - $1 }, levelRange) / max(baseLevel, 1e-30))
            print("[M27L] \(subject.rawValue) null: max |diff| \(nullDiff), residual \(f(nullResidualDb)) dB re the render")
            #expect(baseLevel > 1e-4, "M27L: \(subject.rawValue) default render is silent: CANNOT TELL")
            #expect(nullDiff == 0 || nullResidualDb < -80,
                    "M27L: \(subject.rawValue) two default renders differ (\(nullDiff)): deltas CANNOT be read")
            let basePower = powerSpectrum(baseMono, start: spectrumStart, n: n)
            let loadedFraction = energyAbove400(basePower, n: n)
            print("[M27L] \(subject.rawValue) bank-loaded guard: energy above 400 Hz = \(f(loadedFraction, 4))")
            #expect(loadedFraction >= 0.02,
                    "M27L: \(subject.rawValue) looks like the factory sine (bank NOT loaded): CANNOT TELL")
            try writeWAV(base, "\(subject.rawValue)-default", in: out)
            let baseGrid = logGrid(basePower, n: n)
            let baseShape = bandShape(basePower, n: n)
            let baseL = rms(base.left, levelRange), baseR = rms(base.right, levelRange)

            var controlsJSON: [String: Any] = [
                "nullMaxAbsDiff": jsonNumber(nullDiff), "nullResidualDb": nullResidualDb,
                "energyAbove400": loadedFraction, "levelDbfs": dB(baseLevel),
                "leftDbfs": dB(baseL), "rightDbfs": dB(baseR), "peakHz": peakHz(basePower, n: n),
            ]
            if subject == .piano {
                let soft = try await render(subject, velocity: 50)
                let velocityDelta = dB(rms(mono(soft), levelRange) / baseLevel)
                print("[M27L] piano velocity control: v50 vs v100 = \(f(velocityDelta)) dB")
                #expect(abs(velocityDelta) >= 3, "M27L: the level metric cannot see a velocity change: CANNOT TELL")
                controlsJSON["velocity50DeltaDb"] = velocityDelta
            }

            // ---- Every tree parameter, moved one at a time.
            // Read-only parameters (the Output Amp meters) are not set: `au.setParam` refuses a non-writable
            // parameter (`AudioEngine.setHostedAUParameter`), so they are reported, never moved.
            var rows: [[String: Any]] = []
            for row in subjectDump.tree where !row.writable {
                say("[M27L] \(subject.rawValue) READ-ONLY '\(row.identifier)' '\(row.displayName)' = \(row.value) ",
                    "(after the default render: \(base.rawGlobalAfter[UInt32(truncatingIfNeeded: row.address)].map { String($0) } ?? "n/a"))")
                rows.append(["address": String(row.address), "identifier": row.identifier,
                             "displayName": row.displayName, "readOnly": true, "value": row.value])
            }
            for row in subjectDump.tree where row.writable {
                for value in moves(for: row) where value != row.value {
                    let move = Move(address: row.address, identifier: row.identifier, value: value)
                    let moved = try await render(subject, moves: [move])
                    let tolerance = max(1e-3, 1e-4 * (row.maxValue - row.minValue))
                    try #require(abs(moved.readBefore[0] - value) <= tolerance,
                                 "M27L: \(row.identifier) wrote \(value) but read back \(moved.readBefore[0]) before the render")
                    try #require(abs(moved.readAfter[0] - value) <= tolerance,
                                 "M27L: \(row.identifier) read back \(moved.readAfter[0]) AFTER the render (wrote \(value)): the moved render was NOT moved")
                    let movedMono = mono(moved)
                    let power = powerSpectrum(movedMono, start: spectrumStart, n: n)
                    let level = dB(rms(movedMono, levelRange) / baseLevel)
                    let leftDelta = dB(rms(moved.left, levelRange) / max(baseL, 1e-30))
                    let rightDelta = dB(rms(moved.right, levelRange) / max(baseR, 1e-30))
                    let shift = spectralShift(reference: baseGrid, moved: logGrid(power, n: n))
                    let shape = shapeDistance(baseShape, bandShape(power, n: n))
                    let identical = maxAbsDiff(moved.left, base.left) == 0 && maxAbsDiff(moved.right, base.right) == 0
                    let stateChanged = moved.stateBytes != nil && moved.stateBytes != base.stateBytes
                    let name = "\(subject.rawValue)-\(row.identifier.isEmpty ? String(row.address) : row.identifier)-\(f(value, 1))"
                    try writeWAV(moved, name.replacingOccurrences(of: "/", with: "_"), in: out)
                    say("[M27L] \(subject.rawValue) MOVE '\(row.identifier)' (\(row.address)) \(row.value) -> \(value): "
                          , "level \(f(level)) dB (L \(f(leftDelta)), R \(f(rightDelta))), shift \(f(shift.cents, 0)) cents "
                          , "(corr \(f(shift.best, 3)), at 0: \(f(shift.atZero, 3))), shape \(f(shape, 4)), "
                          , "peak \(f(peakHz(power, n: n), 1)) Hz (default \(f(peakHz(basePower, n: n), 1))), "
                          , "identical \(identical), state bytes changed \(stateChanged), raw Global after \(moved.rawGlobalAfter)")
                    rows.append([
                        "address": String(row.address), "identifier": row.identifier, "displayName": row.displayName,
                        "from": row.value, "to": value, "readBack": moved.readBefore[0],
                        "readBackAfterRender": jsonNumber(moved.readAfter[0]), "levelDeltaDb": level, "leftDeltaDb": leftDelta,
                        "rightDeltaDb": rightDelta, "shiftCents": shift.cents, "shiftCorrelation": shift.best,
                        "zeroShiftCorrelation": shift.atZero, "shapeDistance": shape,
                        "peakHz": peakHz(power, n: n), "bitIdenticalToDefault": identical,
                        "stateBytesChanged": stateChanged,
                        "rawGlobalAfter": Dictionary(uniqueKeysWithValues: moved.rawGlobalAfter.map { (String($0.key), $0.value) }),
                    ])
                }
            }

            // ---- Persistence: move every writable parameter, then release and re-prepare the same track (what a
            // project reopen or a re-host does: `.soundBank` forces stateData nil, LAW L3).
            let persistTrack = track(subject)
            let persistRenderer = try await prepared(persistTrack)
            let persistAU = try instrumentAU(persistRenderer, persistTrack)
            var persisted: [[String: Any]] = []
            if let persistTree = persistAU.parameterTree {
                for row in subjectDump.tree where row.writable {
                    persistTree.parameter(withAddress: row.address)?.value = AUValue(moves(for: row)[0])
                }
                persistRenderer.auRegistry.releaseInstrument(forTrack: persistTrack.id)
                await persistRenderer.auRegistry.prepare(track: persistTrack, sampleRate: sampleRate)
                let rehosted = persistRenderer.auRegistry.preparedInstrument(forTrack: persistTrack.id)?.auAudioUnit
                say("[M27L] \(subject.rawValue) PERSIST re-hosted: \(rehosted != nil), a new instance: ",
                    "\(rehosted.map { $0 !== persistAU } ?? false)")
                for row in subjectDump.tree where row.writable {
                    let after = Double(rehosted?.parameterTree?.parameter(withAddress: row.address)?.value ?? .nan)
                    say("[M27L] \(subject.rawValue) PERSIST '\(row.identifier)': moved to \(moves(for: row)[0]), "
                          , "after release + re-prepare reads \(after) (default \(row.value))")
                    persisted.append(["identifier": row.identifier, "moved": moves(for: row)[0], "afterRehost": jsonNumber(after),
                                      "default": row.value])
                }
            }

            let subjectJSON: [String: Any] = [
                "tree": subjectDump.tree.map { row -> [String: Any] in
                    ["address": String(row.address), "identifier": row.identifier, "displayName": row.displayName,
                     "keyPath": row.keyPath, "unit": row.unitRaw, "unitName": row.unitName ?? "",
                     "min": row.minValue, "max": row.maxValue, "value": row.value,
                     "flags": row.flagsRaw, "writable": row.writable, "valueStrings": row.valueStringCount]
                },
                "raw": subjectDump.raw.map { row -> [String: Any] in
                    ["scope": row.scope, "element": row.element, "id": row.id, "name": row.name, "unit": row.unitRaw,
                     "min": row.minValue, "max": row.maxValue, "default": row.defaultValue,
                     "value": row.value.map { $0 as Any } ?? NSNull(), "flags": row.flagsRaw, "infoStatus": row.infoStatus]
                },
                "scopes": subjectDump.scopes.map { scope -> [String: Any] in
                    ["scope": scope.scope, "name": scopeNames[scope.scope] ?? "?",
                     "elementCount": scope.elementCount.map { $0 as Any } ?? NSNull(), "elementCountStatus": scope.elementCountStatus,
                     "elementsWalked": scope.elementsWalked, "listStatuses": scope.listStatuses,
                     "parameterCount": scope.parameterCount]
                },
                "fullState": ["bytes": subjectDump.stateBytes, "topKeys": subjectDump.stateTopKeys,
                              "keyNames": subjectDump.stateKeyNames, "summary": subjectDump.stateSummary],
                "controls": controlsJSON, "moves": rows, "persistence": persisted,
            ]
            subjectsJSON[subject.rawValue] = subjectJSON
        }

        // ---- Positive control for the SET path through the render: AULowpass insert on the piano, cutoff moved.
        let effectID = UUID()
        let open = try await render(.piano, lowpassEffectID: effectID)
        let closed = try await render(.piano, lowpassEffectID: effectID, lowpassCutoff: 200)
        let n = Subject.piano.windowLength
        let start = onsetFrame + Subject.piano.windowOffset
        let openHF = bandEnergy(powerSpectrum(mono(open), start: start, n: n), n: n, 2_000, 8_000)
        let closedHF = bandEnergy(powerSpectrum(mono(closed), start: start, n: n), n: n, 2_000, 8_000)
        let hfDrop = 10 * log10(max(closedHF, 1e-30) / max(openHF, 1e-30))
        print("[M27L] CONTROL set path: AULowpass cutoff 200 Hz vs default, 2-8 kHz band \(f(hfDrop)) dB")
        #expect(hfDrop <= -20, "M27L: moving AULowpass cutoff through parameter.value did not reach the render: the set path is broken")
        try writeWAV(open, "control-lowpass-default", in: out)
        try writeWAV(closed, "control-lowpass-200Hz", in: out)
        let controlJSON: [String: Any] = [
            "lowpassTreeCount": controlDump.tree.count,
            "lowpassRawGlobalCount": controlDump.raw.filter { $0.scope == 0 }.count,
            "lowpassTree": controlDump.tree.map { row -> [String: Any] in
                ["address": String(row.address), "identifier": row.identifier, "unit": row.unitRaw,
                 "min": row.minValue, "max": row.maxValue, "value": row.value]
            },
            "setPathHFDropDb": hfDrop,
        ]
        json["control"] = controlJSON
        if let piano = dumps[.piano], let kit = dumps[.kit] {
            let same = piano.tree.map { "\($0.address)|\($0.identifier)|\($0.minValue)|\($0.maxValue)" }
                == kit.tree.map { "\($0.address)|\($0.identifier)|\($0.minValue)|\($0.maxValue)" }
            print("[M27L] piano and kit trees identical (address, id, range): \(same)")
            json["treesIdenticalAcrossPrograms"] = same
        }
        json["subjects"] = subjectsJSON
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: out.appendingPathComponent("probe.json"))
        print("[M27L] wrote \(out.appendingPathComponent("probe.json").path) (\(data.count) bytes)")
    }
}
