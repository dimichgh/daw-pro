import Foundation
import Testing
@testable import DAWCore

/// m19-c: SampleLibraryMapper — every §2.3 degradation-policy row asserted.
/// Fixture "samples" are plain byte files (the mapper pre-checks EXISTENCE
/// only, no audio decode — decode honesty stays with the engine backstop),
/// written to per-test temp dirs (house idiom, no bundle resources).
@Suite("Sample-library mapper — §2.3 policy (m19-c)")
struct SampleLibraryMapperTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sfz-map-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func writeSample(_ name: String, in dir: URL,
                             bytes: Int = 4) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    /// A sparse file of logical size `bytes` — instant on APFS, so the
    /// 500 MB / 4 GB gates are testable without writing gigabytes.
    private func writeSparseSample(_ name: String, in dir: URL,
                                   bytes: UInt64) throws -> URL {
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: bytes)
        try handle.close()
        return url
    }

    /// A minimal real WAV whose `smpl` chunk embeds one forward loop —
    /// the m20-g fallback input (dwEnd INCLUSIVE, D4).
    @discardableResult
    private func writeSmplWAV(_ name: String, in dir: URL,
                              loopStart: UInt32, loopEndIncl: UInt32) throws -> URL {
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
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
        body.append(le16(1)); body.append(le16(1))
        body.append(le32(48_000)); body.append(le32(96_000))
        body.append(le16(2)); body.append(le16(16))
        body.append(Data("data".utf8)); body.append(le32(16))
        body.append(Data(repeating: 0, count: 16))
        body.append(Data("smpl".utf8)); body.append(le32(UInt32(smpl.count)))
        body.append(smpl)
        var data = Data("RIFF".utf8)
        data.append(le32(UInt32(body.count)))
        data.append(body)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func map(_ text: String, in dir: URL, force: Bool = false) throws
        -> (params: SamplerParams, report: SampleLibraryImportReport) {
        let ir = SFZParser.parse(text: text, baseDirectory: dir)
        return try SampleLibraryMapper.map(ir, force: force)
    }

    // MARK: - m27 leg B: dynamic-layer crossfade opcodes

    // MARK: - Global-vs-zone inheritance reporting (2026-08-20 field report)

    /// The report: "Sampler global release is inert when zones carry their own
    /// (SFZ imports always do)." The engine is RIGHT to prefer the zone (its
    /// own §4.4 design, and SFZ's region-over-global precedence); what was
    /// broken is that nothing said so. These tests pin the computation that
    /// `instrument.describeSampler` now reports, and they run it over a REAL
    /// mapped import rather than hand-built zones, because "SFZ imports always
    /// do" is precisely the claim under test.
    @Test("ampeg_release in <global> reaches EVERY zone, which makes the sampler's own global release inert")
    func sfzGlobalReleaseOverridesEveryZone() throws {
        let dir = tempDir()
        try writeSample("a.wav", in: dir)
        try writeSample("b.wav", in: dir)
        let (params, _) = try map("""
        <global> ampeg_release=0.5
        <region> sample=a.wav lokey=0 hikey=59
        <region> sample=b.wav lokey=60 hikey=127
        """, in: dir)
        // The import itself: the <global> opcode landed on both regions.
        #expect(params.zones.count == 2)
        #expect(params.zones.allSatisfy { $0.release == 0.5 })

        // The reporter's own numbers: a stored global of 3.4465 s over an
        // instrument that behaves at 0.5 s.
        var withReportedGlobal = params
        withReportedGlobal.release = 3.4465
        let use = SamplerGlobalUse.release(of: withReportedGlobal)
        print("[measured] release use — inert: \(use.globalIsInert), "
              + "overriding/inheriting: \(use.zonesOverriding)/\(use.zonesInheriting), "
              + "effective: \(use.effectiveValues)")
        #expect(use.global == 3.4465)            // the number still reported…
        #expect(use.globalIsInert)               // …and now labelled dead
        #expect(use.zonesOverriding == 2)
        #expect(use.zonesInheriting == 0)
        #expect(use.effectiveValues == [0.5])    // what will ACTUALLY be heard
        #expect(use.effectiveMin == 0.5)
        #expect(use.effectiveMax == 0.5)
        #expect(!use.valuesTruncated)
    }

    /// The case a bare "is the global inert?" boolean cannot describe, and the
    /// case that forces the computation to be real: an SFZ authoring
    /// `ampeg_release` on SOME regions. The global is live for the rest, so
    /// neither "inert" nor "fine" is the whole answer — only the effective
    /// value list is.
    @Test("a MIXED library leaves the global live for the zones that inherit, and says both values")
    func mixedReleaseOverridesReportBothValues() throws {
        let dir = tempDir()
        try writeSample("a.wav", in: dir)
        try writeSample("b.wav", in: dir)
        try writeSample("c.wav", in: dir)
        let (params, _) = try map("""
        <region> sample=a.wav lokey=0 hikey=41 ampeg_release=0.5
        <region> sample=b.wav lokey=42 hikey=83 ampeg_release=1.25
        <region> sample=c.wav lokey=84 hikey=127
        """, in: dir)
        var withGlobal = params
        withGlobal.release = 3.4465
        let use = SamplerGlobalUse.release(of: withGlobal)
        print("[measured] mixed release use — inert: \(use.globalIsInert), "
              + "effective: \(use.effectiveValues)")
        #expect(!use.globalIsInert)              // one zone still listens
        #expect(use.zonesOverriding == 2)
        #expect(use.zonesInheriting == 1)
        // Ascending, and the inheriting zone contributes the GLOBAL's value —
        // that is the whole point of "effective".
        #expect(use.effectiveValues == [0.5, 1.25, 3.4465])
        #expect(use.effectiveMin == 0.5)
        #expect(use.effectiveMax == 3.4465)
    }

    /// The control that keeps `globalIsInert` from being a stuck `true`: a
    /// library authoring no envelope opcodes at all leaves the global fully
    /// live, and the reported effective value IS the global.
    @Test("a library with no ampeg_release leaves the global live for every zone")
    func noReleaseOpcodeLeavesGlobalLive() throws {
        let dir = tempDir()
        try writeSample("a.wav", in: dir)
        let (params, _) = try map("""
        <region> sample=a.wav
        """, in: dir)
        var withGlobal = params
        withGlobal.release = 3.4465
        let use = SamplerGlobalUse.release(of: withGlobal)
        #expect(!use.globalIsInert)
        #expect(use.zonesOverriding == 0)
        #expect(use.zonesInheriting == 1)
        #expect(use.effectiveValues == [3.4465])

        // ATTACK is release's exact twin at the same engine trigger site, so it
        // gets the same treatment and the same control.
        let attackUse = SamplerGlobalUse.attack(of: withGlobal)
        #expect(!attackUse.globalIsInert)
        #expect(attackUse.effectiveValues == [withGlobal.attack])
    }

    /// A zero-zone sampler is deliberately NOT "inert": it is silent for
    /// reasons that have nothing to do with inheritance, and pointing a caller
    /// at the global would send them to fix the wrong thing.
    @Test("a sampler with no zones reports no inert global — silence there is not an inheritance problem")
    func zeroZoneSamplerIsNotInert() {
        let use = SamplerGlobalUse.release(of: SamplerParams(zones: [], release: 3.4465))
        #expect(!use.globalIsInert)
        #expect(use.zonesOverriding == 0)
        #expect(use.zonesInheriting == 0)
        #expect(use.effectiveValues.isEmpty)
        #expect(use.effectiveMin == nil)
        #expect(use.effectiveMax == nil)
    }

    /// More distinct values than the cap: the LIST truncates, the RANGE does
    /// not. A truncated list that also lost its extremes would be a second
    /// quietly-wrong number, which is the class of defect this whole change
    /// exists to remove.
    @Test("more distinct effective values than the cap truncates the list but keeps min/max exact")
    func manyDistinctValuesTruncateTheListNotTheRange() throws {
        let dir = tempDir()
        try writeSample("a.wav", in: dir)
        let regions = (0..<12).map { i in
            "<region> sample=a.wav lokey=\(i * 10) hikey=\(i * 10 + 9)"
                + " ampeg_release=\(Double(i + 1) / 10)"
        }.joined(separator: "\n")
        let (params, _) = try map(regions, in: dir)
        #expect(params.zones.count == 12)
        let use = SamplerGlobalUse.release(of: params)
        print("[measured] truncation — values: \(use.effectiveValues), "
              + "truncated: \(use.valuesTruncated), "
              + "range: \(String(describing: use.effectiveMin))…\(String(describing: use.effectiveMax))")
        #expect(use.valuesTruncated)
        #expect(use.effectiveValues.count == SamplerGlobalUse.valueCap)
        #expect(use.effectiveMin == 0.1)
        #expect(use.effectiveMax == 1.2)
        #expect(use.globalIsInert)
    }

    /// One-shot's own caveat: loop mode wins over one-shot in the engine, but
    /// only for a loop whose bounds survive the load-time check against the
    /// real audio — which DAWCore cannot evaluate. The count is REPORTED
    /// beside the inheritance figures instead of being folded into them.
    @Test("oneShot reports zones with a loop mode separately rather than guessing the engine's loop-validity check")
    func oneShotReportsLoopModeZonesWithoutFoldingThem() throws {
        let dir = tempDir()
        try writeSample("a.wav", in: dir)
        try writeSample("b.wav", in: dir)
        let (params, _) = try map("""
        <region> sample=a.wav lokey=0 hikey=59 loop_mode=one_shot
        <region> sample=b.wav lokey=60 hikey=127 loop_mode=loop_continuous loop_start=0 loop_end=1
        """, in: dir)
        let use = SamplerOneShotUse.oneShot(of: params)
        print("[measured] oneShot use — overriding/inheriting: "
              + "\(use.zonesOverriding)/\(use.zonesInheriting), "
              + "loop-mode zones: \(use.zonesWithLoopMode)")
        // one_shot sets the override; loop_continuous does not touch it.
        #expect(use.zonesOverriding == 1)
        #expect(use.zonesInheriting == 1)
        #expect(!use.globalIsInert)              // one zone still reads the global
        #expect(use.zonesWithLoopMode == 1)      // reported, not folded
    }

    @Test("xfin_locc/xfout_hicc import as a CONTINUOUS crossfade naming their CC")
    func ccCrossfadeImports() throws {
        let dir = tempDir()
        try writeSample("pp.wav", in: dir)
        try writeSample("ff.wav", in: dir)
        let (params, report) = try map("""
        <region> sample=pp.wav xfout_locc11=48 xfout_hicc11=96
        <region> sample=ff.wav xfin_locc11=48 xfin_hicc11=96
        """, in: dir)
        #expect(params.zones.count == 2)
        let soft = try #require(params.zones[0].crossfade)
        #expect(soft.controller == 11)
        #expect(soft.ccOutLo == 48)
        #expect(soft.ccOutHi == 96)
        #expect(soft.ccInLo == nil)          // untouched stays untouched
        let loud = try #require(params.zones[1].crossfade)
        #expect(loud.controller == 11)
        #expect(loud.ccInLo == 48)
        #expect(loud.ccInHi == 96)
        // The report must distinguish continuous from velocity crossfade.
        let sentence = try #require(report.degradations.first {
            $0.contains("dynamic-layer crossfade") })
        print("[measured] cc crossfade report: \(sentence)")
        #expect(sentence.contains("CONTINUOUS"))
        #expect(sentence.contains("equal-power"))
        #expect(!sentence.contains("VELOCITY"))
    }

    @Test("xfin_lovel/xfout_hivel import as a VELOCITY crossfade, named as note-on-only")
    func velocityCrossfadeImports() throws {
        let dir = tempDir()
        try writeSample("a.wav", in: dir)
        let (params, report) = try map("""
        <region> sample=a.wav xfin_lovel=25 xfin_hivel=60 xfout_lovel=61 xfout_hivel=84
        """, in: dir)
        let xf = try #require(params.zones[0].crossfade)
        #expect(xf.controller == nil)        // velocity domain names no CC
        #expect(xf.velInLo == 25)
        #expect(xf.velInHi == 60)
        #expect(xf.velOutLo == 61)
        #expect(xf.velOutHi == 84)
        let sentence = try #require(report.degradations.first {
            $0.contains("dynamic-layer crossfade") })
        print("[measured] velocity crossfade report: \(sentence)")
        #expect(sentence.contains("VELOCITY"))
        // The honesty this exists for: velocity crossfade CANNOT change a
        // held note, and the sentence must not let it read as if it could.
        #expect(sentence.contains("not within one"))
    }

    @Test("a library with no crossfade opcodes imports crossfade-free — no inert object")
    func noCrossfadeOpcodesMeansNil() throws {
        let dir = tempDir()
        try writeSample("a.wav", in: dir)
        let (params, report) = try map("""
        <region> sample=a.wav lovel=0 hivel=89
        <region> sample=a.wav lovel=90 hivel=127
        """, in: dir)
        // This is the shape of the user's OWN tenor sax: a hard velocity
        // switch at 90 and no xf opcodes anywhere. Leg B must not invent one.
        #expect(params.zones.allSatisfy { $0.crossfade == nil })
        #expect(!report.degradations.contains { $0.contains("dynamic-layer crossfade") })
    }

    @Test("a second CC crossfade on one region is reason-coded, never blended in")
    func twoControllersOnOneRegionIsReasonCoded() throws {
        let dir = tempDir()
        try writeSample("a.wav", in: dir)
        let (params, report) = try map("""
        <region> sample=a.wav xfin_locc1=0 xfin_hicc1=64 xfin_locc11=0 xfin_hicc11=64
        """, in: dir)
        let xf = try #require(params.zones[0].crossfade)
        #expect(xf.controller == 1)          // lowest opcode name wins, deterministically
        // The CC11 pair is DROPPED — and said so.
        #expect(report.ignoredOpcodes["xfin_locc11"] == 1)
        #expect(report.ignoredOpcodes["xfin_hicc11"] == 1)
    }

    @Test("xf_cccurve is reason-coded rather than silently given the engine's curve")
    func curveOpcodeIsReasonCoded() throws {
        let dir = tempDir()
        try writeSample("a.wav", in: dir)
        let (_, report) = try map("""
        <region> sample=a.wav xfin_locc11=0 xfin_hicc11=64 xf_cccurve=gain
        """, in: dir)
        // We implement SFZ's DEFAULT (power). A file asking for `gain` gets
        // power — so it must be told, not quietly obliged.
        #expect(report.ignoredOpcodes["xf_cccurve"] == 1)
    }

    // MARK: - Skip rules (reason-coded)

    @Test("trigger=release/first/legato regions are skipped, counted by reason")
    func triggerSkips() throws {
        let dir = tempDir()
        try writeSample("a.wav", in: dir)
        let (params, report) = try map("""
        <region> sample=a.wav trigger=release
        <region> sample=a.wav trigger=release
        <region> sample=a.wav trigger=first
        <region> sample=a.wav trigger=legato
        <region> sample=a.wav trigger=attack
        <region> sample=a.wav
        """, in: dir)
        #expect(params.zones.count == 2)   // explicit attack + default both play
        #expect(report.skippedRegions["trigger=release"] == 2)
        #expect(report.skippedRegions["trigger=first"] == 1)
        #expect(report.skippedRegions["trigger=legato"] == 1)
        #expect(report.zonesImported == 2)
    }

    @Test("CC-triggered regions (on_loccN) are skipped, reason-coded")
    func ccTriggeredSkip() throws {
        let dir = tempDir()
        try writeSample("a.wav", in: dir)
        let (params, report) = try map("""
        <region> sample=a.wav on_locc64=127
        <region> sample=a.wav
        """, in: dir)
        #expect(params.zones.count == 1)
        #expect(report.skippedRegions["cc-triggered (on_loccN)"] == 1)
    }

    @Test("keyswitch reduction keeps ONLY the sw_default articulation, notes the loss")
    func keyswitchReductionByDefault() throws {
        let dir = tempDir()
        try writeSample("nat.wav", in: dir)
        try writeSample("ret.wav", in: dir)
        let (params, report) = try map("""
        <group> sw_last=c1 sw_default=d1
        <region> sample=nat.wav
        <region> sample=nat.wav
        <group> sw_last=d1 sw_default=d1
        <region> sample=ret.wav
        """, in: dir)
        #expect(params.zones.count == 1)
        #expect(params.zones[0].audioFileURL.lastPathComponent == "ret.wav")
        #expect(report.skippedRegions["keyswitch articulation"] == 2)
        #expect(report.degradations.contains(
            "keyswitch articulations reduced to default; 2 regions skipped"))
    }

    @Test("keyswitch reduction falls back to the LOWEST sw_last when sw_default is absent")
    func keyswitchReductionLowestFallback() throws {
        let dir = tempDir()
        try writeSample("a.wav", in: dir)
        let (params, report) = try map("""
        <group> sw_last=d1
        <region> sample=a.wav
        <group> sw_last=c1
        <region> sample=a.wav
        """, in: dir)
        #expect(params.zones.count == 1)   // c1 (24) < d1 (26) — lowest wins
        #expect(report.skippedRegions["keyswitch articulation"] == 1)
    }

    @Test("regions without a sample opcode and end=-1 regions are skipped, reason-coded")
    func structuralSkips() throws {
        let dir = tempDir()
        try writeSample("a.wav", in: dir)
        let (params, report) = try map("""
        <region> lokey=10 hikey=20
        <region> sample=a.wav end=-1
        <region> sample=a.wav
        """, in: dir)
        #expect(params.zones.count == 1)
        #expect(report.skippedRegions["no sample opcode"] == 1)
        #expect(report.skippedRegions["end=-1 (sample disabled)"] == 1)
    }

    @Test("missing sample files skip their regions with a per-file note; existing ones import")
    func missingFileSkip() throws {
        let dir = tempDir()
        try writeSample("real.wav", in: dir)
        let (params, report) = try map("""
        <region> sample=real.wav
        <region> sample=ghost.wav
        <region> sample=ghost.wav lokey=2 hikey=2
        """, in: dir)
        #expect(params.zones.count == 1)
        #expect(report.skippedRegions["sample file missing"] == 2)
        // ONE note per unique file, path named.
        let notes = report.degradations.filter { $0.hasPrefix("sample file missing: ") }
        #expect(notes.count == 1)
        #expect(notes[0].hasSuffix("ghost.wav"))
    }

    @Test(".ogg samples are skipped with a per-file note (Core Audio cannot decode Vorbis)")
    func oggSkip() throws {
        let dir = tempDir()
        try writeSample("pad.ogg", in: dir)
        try writeSample("pad.wav", in: dir)
        let (params, report) = try map("""
        <region> sample=pad.ogg
        <region> sample=pad.wav
        """, in: dir)
        #expect(params.zones.count == 1)
        #expect(report.skippedRegions["unsupported sample format (.ogg)"] == 1)
        #expect(report.degradations.contains { $0.hasPrefix("cannot decode .ogg sample: ") })
    }

    @Test("zero playable zones yields an empty params + zero-count report (the store refuses on apply)")
    func zeroZonesReport() throws {
        let dir = tempDir()
        let (params, report) = try map("<region> sample=ghost.wav", in: dir)
        #expect(params.zones.isEmpty)
        #expect(report.zonesImported == 0)
        #expect(report.groupCount == 0)
        #expect(report.velocityLayerCount == 0)
    }

    // MARK: - Ignored opcodes (region still plays)

    @Test("excluded opcodes are counted per region via inheritance; the regions still import")
    func ignoredOpcodeTally() throws {
        let dir = tempDir()
        try writeSample("a.wav", in: dir)
        let (params, report) = try map("""
        <group> cutoff=800
        <region> sample=a.wav
        <region> sample=a.wav eq1_freq=100
        <region> sample=a.wav loop_start=5 loop_end=900
        """, in: dir)
        #expect(params.zones.count == 3)
        #expect(report.ignoredOpcodes["cutoff"] == 3)      // inherited by all three
        #expect(report.ignoredOpcodes["eq1_freq"] == 1)
        // m20-g (§8.2 case 9): loop points are CONSUMED — never in the tally.
        #expect(report.ignoredOpcodes["loop_start"] == nil)
        #expect(report.ignoredOpcodes["loop_end"] == nil)
        // Points without a mode (a.wav embeds no smpl loop) → the honest
        // degradation; the zone still imports, unlooped.
        #expect(params.zones[2].loopMode == nil)
        #expect(report.degradations.contains(
            "1 zone author loop points without a loop mode and their samples embed no smpl loop — imported without looping (the SFZ default)"))
    }

    @Test("skipped regions do NOT contribute to the ignored-opcode tally")
    func skippedRegionsNotTallied() throws {
        let dir = tempDir()
        try writeSample("a.wav", in: dir)
        let (_, report) = try map("""
        <region> sample=a.wav trigger=release cutoff=500
        <region> sample=a.wav
        """, in: dir)
        #expect(report.ignoredOpcodes["cutoff"] == nil)
    }

    @Test("ignored HEADERS (<curve>/<effect>) fold into the ignoredOpcodes tally")
    func ignoredHeadersFold() throws {
        let dir = tempDir()
        try writeSample("a.wav", in: dir)
        let (_, report) = try map("""
        <region> sample=a.wav
        <curve> v000=0
        """, in: dir)
        #expect(report.ignoredOpcodes["<curve>"] == 1)
    }

    // MARK: - Loops (m20-g §2.3: precedence, validity, honesty — played for real)

    // §8.2 cases 1 + 2: authored modes map to real model loops; the ONE +1
    // law converts the inclusive loop_end to the model's exclusive loopEnd.
    @Test("loop_mode + points map to real zone loops; loop_end is inclusive (+1 law)")
    func realLoopMapping() throws {
        let dir = tempDir()
        try writeSample("a.wav", in: dir)
        let (params, report) = try map("""
        <region> sample=a.wav loop_mode=loop_continuous loop_start=4410 loop_end=48509
        <region> sample=a.wav loop_mode=loop_sustain loop_start=10 loop_end=100
        """, in: dir)
        #expect(params.zones[0].loopMode == .continuous)
        #expect(params.zones[0].loopStart == 4_410)
        #expect(params.zones[0].loopEnd == 48_510)   // THE +1 assert
        #expect(params.zones[1].loopMode == .sustain)
        #expect(params.zones[1].loopStart == 10)
        #expect(params.zones[1].loopEnd == 101)
        #expect(report.loopedZones == 2)
        #expect(!report.degradations.contains { $0.contains("looping") })
        // §8.2 case 9: no loop keys in the tally, ever.
        for key in ["loop_start", "loop_end", "loopstart", "loopend",
                    "loopStart", "loopEnd", "loop_mode"] {
            #expect(report.ignoredOpcodes[key] == nil)
        }
    }

    // §8.2 case 3: an explicit no_loop suppresses the smpl fallback entirely.
    @Test("loop_mode=no_loop suppresses the smpl fallback — authored intent honored exactly")
    func noLoopSuppressesSmplFallback() throws {
        let dir = tempDir()
        try writeSmplWAV("looped.wav", in: dir, loopStart: 1_000, loopEndIncl: 2_000)
        let (params, report) = try map(
            "<region> sample=looped.wav loop_mode=no_loop", in: dir)
        #expect(params.zones.count == 1)
        #expect(params.zones[0].loopMode == nil)
        #expect(params.zones[0].loopStart == nil)
        #expect(params.zones[0].loopEnd == nil)
        #expect(report.loopedZones == 0)
        #expect(report.degradations.isEmpty)   // no loop, no fallback, no note
    }

    // §8.2 case 4: the SFZ default law — no opcodes + a WAV smpl forward
    // loop enables loop_continuous with the chunk's points.
    @Test("no loop opcodes + WAV smpl loop → loop_continuous with the chunk points")
    func smplFallbackDefaultLaw() throws {
        let dir = tempDir()
        try writeSmplWAV("looped.wav", in: dir, loopStart: 1_000, loopEndIncl: 2_000)
        let (params, report) = try map("<region> sample=looped.wav", in: dir)
        #expect(params.zones[0].loopMode == .continuous)
        #expect(params.zones[0].loopStart == 1_000)
        #expect(params.zones[0].loopEnd == 2_001)    // dwEnd inclusive → +1 law
        #expect(report.loopedZones == 1)
        #expect(report.degradations.isEmpty)
    }

    // §8.2 case 5: per-field precedence — authored opcodes win field by
    // field; the smpl chunk fills only the nil slots.
    @Test("authored fields win PER FIELD over the smpl chunk; nil slots fall back")
    func perFieldPrecedence() throws {
        let dir = tempDir()
        try writeSmplWAV("looped.wav", in: dir, loopStart: 1_000, loopEndIncl: 2_000)
        let (params, report) = try map("""
        <region> sample=looped.wav loop_mode=loop_sustain
        <region> sample=looped.wav loop_mode=loop_continuous loop_start=50
        <region> sample=looped.wav loop_start=50 loop_end=1500
        """, in: dir)
        // Authored mode, no points → both points from the chunk.
        #expect(params.zones[0].loopMode == .sustain)
        #expect(params.zones[0].loopStart == 1_000)
        #expect(params.zones[0].loopEnd == 2_001)
        // Authored start wins; end falls back to the chunk's.
        #expect(params.zones[1].loopMode == .continuous)
        #expect(params.zones[1].loopStart == 50)
        #expect(params.zones[1].loopEnd == 2_001)
        // Points authored but mode nil + the file HAS a smpl loop → the
        // default law enables loop_continuous; authored points win per field.
        #expect(params.zones[2].loopMode == .continuous)
        #expect(params.zones[2].loopStart == 50)
        #expect(params.zones[2].loopEnd == 1_501)
        #expect(report.loopedZones == 3)
    }

    // §8.2 case 6: invalid bounds — the zone imports UNLOOPED with the
    // reason-coded degradation; never a skip.
    @Test("invalid loop bounds import unlooped with the honest degradation — never a skip")
    func invalidLoopBounds() throws {
        let dir = tempDir()
        try writeSample("a.wav", in: dir)
        let (params, report) = try map("""
        <region> sample=a.wav loop_mode=loop_continuous loop_start=500 loop_end=100
        <region> sample=a.wav loop_mode=loop_sustain loop_start=500 loop_end=600 end=300
        """, in: dir)
        #expect(params.zones.count == 2)             // still imported
        #expect(params.zones.allSatisfy { $0.loopMode == nil })
        #expect(report.loopedZones == 0)
        #expect(report.zonesImported == 2)
        #expect(report.skippedRegions.isEmpty)
        #expect(report.degradations.contains(
            "2 zones author invalid loop bounds (loop end before loop start, or outside the playable span) — imported without looping"))
        // A 1-frame loop (loop_end == loop_start) is LEGAL — not invalid.
        let (oneFrame, oneFrameReport) = try map(
            "<region> sample=a.wav loop_mode=loop_continuous loop_start=10 loop_end=10",
            in: dir)
        #expect(oneFrame.zones[0].loopMode == .continuous)
        #expect(oneFrame.zones[0].loopStart == 10)
        #expect(oneFrame.zones[0].loopEnd == 11)
        #expect(oneFrameReport.loopedZones == 1)
    }

    // §8.2 case 7: loop points without a mode and no smpl loop → unlooped +
    // the points-without-mode degradation (the SFZ default law).
    @Test("points without a mode and no smpl loop import unlooped, reason-coded")
    func pointsWithoutMode() throws {
        let dir = tempDir()
        try writeSample("plain.wav", in: dir)   // 4 bytes — not a RIFF, no smpl
        let (params, report) = try map(
            "<region> sample=plain.wav loop_start=10 loop_end=100", in: dir)
        #expect(params.zones.count == 1)
        #expect(params.zones[0].loopMode == nil)
        #expect(params.zones[0].loopStart == nil)
        #expect(params.zones[0].loopEnd == nil)
        #expect(report.loopedZones == 0)
        #expect(report.degradations.contains(
            "1 zone author loop points without a loop mode and their samples embed no smpl loop — imported without looping (the SFZ default)"))
    }

    // §8.2 case 8: an unrecognized loop_mode value is tallied — the m20-g
    // honesty fix for the old silent `default: break`.
    @Test("unrecognized loop_mode values are tallied into ignoredOpcodes")
    func unrecognizedLoopMode() throws {
        let dir = tempDir()
        try writeSample("a.wav", in: dir)
        let (params, report) = try map(
            "<region> sample=a.wav loop_mode=loop_bidirectional", in: dir)
        #expect(params.zones.count == 1)     // imports, unlooped
        #expect(params.zones[0].loopMode == nil)
        #expect(report.ignoredOpcodes["loop_mode"] == 1)
        #expect(report.loopedZones == 0)
    }

    // §8.2 case 11: one_shot mapping unchanged — it is not a loop.
    @Test("loop_mode=one_shot maps to the per-zone oneShot override — it is not a loop")
    func oneShotMapping() throws {
        let dir = tempDir()
        try writeSample("kick.wav", in: dir)
        let (params, report) = try map("""
        <region> sample=kick.wav loop_mode=one_shot
        <region> sample=kick.wav
        """, in: dir)
        #expect(params.zones[0].oneShot == true)
        #expect(params.zones[0].loopMode == nil)     // never a loop
        #expect(params.zones[0].loopStart == nil)
        #expect(params.zones[0].loopEnd == nil)
        #expect(params.zones[1].oneShot == nil)
        #expect(report.loopedZones == 0)
        #expect(!report.degradations.contains { $0.contains("sustain loops") })
    }

    // MARK: - Group-ID assignment (§5.3)

    @Test("each <group> header gets one fresh ID; ungrouped regions get their OWN unique IDs; never nil, never 0")
    func groupIDAssignment() throws {
        let dir = tempDir()
        try writeSample("a.wav", in: dir)
        let (params, report) = try map("""
        <region> sample=a.wav
        <group> lovel=0
        <region> sample=a.wav
        <region> sample=a.wav
        <group> lovel=64
        <region> sample=a.wav
        <master>
        <region> sample=a.wav
        """, in: dir)
        let groups = params.zones.map(\.group)
        // The importer NEVER emits nil (implicit 0 is reserved for
        // hand-built zones) and never 0.
        #expect(groups.allSatisfy { $0 != nil && $0! >= 1 })
        #expect(groups[0] == 1)          // ungrouped: own ID
        #expect(groups[1] == 2)          // first <group>
        #expect(groups[2] == 2)          //   shares it
        #expect(groups[3] == 3)          // second <group>
        #expect(groups[4] == 4)          // ungrouped after <master>: own ID
        #expect(report.groupCount == 4)
    }

    // MARK: - Value mapping

    @Test("dB volume → linear zone gain (0…2, the A5 relax)")
    func dbToLinear() throws {
        let dir = tempDir()
        try writeSample("a.wav", in: dir)
        let (params, _) = try map("""
        <region> sample=a.wav volume=6
        <region> sample=a.wav volume=-6
        <region> sample=a.wav volume=20
        <region> sample=a.wav
        """, in: dir)
        #expect(abs(params.zones[0].gain - 1.9953) < 0.001)   // +6 dB survives A5
        #expect(abs(params.zones[1].gain - 0.5012) < 0.001)
        #expect(params.zones[2].gain == 2.0)                  // model ceiling clamps
        #expect(params.zones[3].gain == 1.0)
    }

    @Test("note-name pitches land on the zone's pitch fields through the whole pipeline")
    func noteNamesEndToEnd() throws {
        let dir = tempDir()
        try writeSample("a.wav", in: dir)
        let (params, _) = try map(
            "<region> sample=a.wav lokey=a0 hikey=c8 pitch_keycenter=a4", in: dir)
        #expect(params.zones[0].minPitch == 21)
        #expect(params.zones[0].maxPitch == 108)
        #expect(params.zones[0].rootPitch == 69)
    }

    @Test("unit scaling + model clamps: pan ÷100, amp_veltrack ÷100, transpose×100+tune, offset/end, ampeg_*")
    func unitScalingAndClamps() throws {
        let dir = tempDir()
        try writeSample("a.wav", in: dir)
        let (params, _) = try map("""
        <region> sample=a.wav pan=-100 amp_veltrack=50 transpose=2 tune=-30 offset=100 end=999 ampeg_attack=0.2 ampeg_decay=1.5 ampeg_sustain=50 ampeg_release=0.8
        <region> sample=a.wav pan=250 amp_veltrack=200 tune=9999999
        """, in: dir)
        let z = params.zones[0]
        #expect(z.pan == -1.0)
        #expect(z.ampVelTrack == 0.5)
        #expect(z.tuneCents == 170)          // 2×100 − 30
        #expect(z.startFrame == 100)
        #expect(z.endFrame == 1000)          // inclusive SFZ end → exclusive model frame
        #expect(z.attack == 0.2)
        #expect(z.decay == 1.5)
        #expect(z.sustain == 0.5)
        #expect(z.release == 0.8)
        let clamped = params.zones[1]
        #expect(clamped.pan == 1.0)          // model clamps −1…1
        #expect(clamped.ampVelTrack == 1.0)  // model clamps 0…1
        #expect(clamped.tuneCents == 4_800)  // model clamps ±4800
    }

    @Test("velocity spans + RR + random map through; velocityLayerCount counts distinct spans")
    func selectionFieldMapping() throws {
        let dir = tempDir()
        try writeSample("a.wav", in: dir)
        let (params, report) = try map("""
        <group> lovel=0 hivel=63
        <region> sample=a.wav seq_length=4 seq_position=2
        <group> lovel=64 hivel=127
        <region> sample=a.wav lorand=0 hirand=0.5
        <region> sample=a.wav lorand=0.5 hirand=1
        """, in: dir)
        #expect(params.zones[0].minVelocity == 0)
        #expect(params.zones[0].maxVelocity == 63)
        #expect(params.zones[0].seqLength == 4)
        #expect(params.zones[0].seqPosition == 2)
        #expect(params.zones[1].randMin == 0)
        #expect(params.zones[1].randMax == 0.5)
        #expect(report.velocityLayerCount == 2)
    }

    @Test("unauthored zone fields stay nil — the Sampler's documented defaults apply")
    func minimalRegionStaysNil() throws {
        let dir = tempDir()
        try writeSample("a.wav", in: dir)
        let (params, _) = try map("<region> sample=a.wav", in: dir)
        let z = params.zones[0]
        #expect(z.minVelocity == nil)
        #expect(z.maxVelocity == nil)
        #expect(z.seqLength == nil)
        #expect(z.randMin == nil)
        #expect(z.tuneCents == nil)
        #expect(z.pan == nil)
        #expect(z.ampVelTrack == nil)
        #expect(z.oneShot == nil)
        #expect(z.startFrame == nil)
        #expect(z.endFrame == nil)
        #expect(z.attack == nil)
        #expect(z.decay == nil)
        #expect(z.sustain == nil)
        #expect(z.release == nil)
        #expect(z.loopMode == nil)   // a.wav embeds no smpl loop → no fallback
        #expect(z.loopStart == nil)
        #expect(z.loopEnd == nil)
        #expect(z.group == 1)   // the ONE always-set import field
    }

    // MARK: - Paths

    @Test("default_path prepend + backslash normalization + ..-above-root note")
    func pathNormalization() throws {
        let dir = tempDir()
        let samples = dir.appendingPathComponent("lib", isDirectory: true)
        try FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
        try writeSample("Samples/close/c4.wav", in: dir)  // ABOVE the .sfz's folder
        let ir = SFZParser.parse(
            text: "<control> default_path=..\\Samples\\\n<region> sample=close\\c4.wav",
            baseDirectory: samples)
        let (params, report) = try SampleLibraryMapper.map(ir)
        #expect(params.zones.count == 1)
        #expect(params.zones[0].audioFileURL.path.hasSuffix("Samples/close/c4.wav"))
        #expect(report.degradations.contains {
            $0.contains("resolve outside the library folder")
        })
    }

    // MARK: - Byte accounting (§5.5)

    @Test("totalSampleBytes counts each UNIQUE file once")
    func uniqueFileByteAccounting() throws {
        let dir = tempDir()
        try writeSample("a.wav", in: dir, bytes: 100)
        try writeSample("b.wav", in: dir, bytes: 40)
        let (_, report) = try map("""
        <region> sample=a.wav lokey=1 hikey=1
        <region> sample=a.wav lokey=2 hikey=2
        <region> sample=b.wav
        """, in: dir)
        #expect(report.totalSampleBytes == 140)
    }

    @Test("≥500 MB adds the large-library degradation warning")
    func sizeWarning() throws {
        let dir = tempDir()
        _ = try writeSparseSample("big.wav", in: dir, bytes: 600_000_000)
        let (_, report) = try map("<region> sample=big.wav", in: dir)
        #expect(report.totalSampleBytes == 600_000_000)
        #expect(report.degradations.contains { $0.hasPrefix("large sample library: ") })
    }

    @Test(">4 GB refuses without force — the error names the limit and the flag — and imports WITH it")
    func sizeRefusalAndForceGate() throws {
        let dir = tempDir()
        _ = try writeSparseSample("huge.wav", in: dir, bytes: 4_000_000_001)
        let text = "<region> sample=huge.wav"
        #expect {
            _ = try map(text, in: dir)
        } throws: { error in
            guard case SampleLibraryImportError.libraryTooLarge(let bytes) = error
            else { return false }
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            return bytes == 4_000_000_001
                && message.contains("4 GB") && message.contains("force")
        }
        let (params, report) = try map(text, in: dir, force: true)
        #expect(params.zones.count == 1)
        #expect(report.totalSampleBytes == 4_000_000_001)
    }

    // MARK: - Report plumbing

    @Test("SampleLibraryImportReport round-trips through Codable")
    func reportCodableRoundTrip() throws {
        let report = SampleLibraryImportReport(
            format: .sfz, zonesImported: 12, groupCount: 3,
            velocityLayerCount: 4,
            skippedRegions: ["trigger=release": 49],
            ignoredOpcodes: ["cutoff": 43],
            degradations: ["keyswitch articulations reduced to default; 9 regions skipped"],
            loopedZones: 5,
            totalSampleBytes: 123_456
        )
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(SampleLibraryImportReport.self, from: data)
        #expect(decoded == report)
    }

    // MARK: - Store orchestration (ProjectStore+SampleLibraries)

    @MainActor
    private func makeStore() -> ProjectStore {
        let store = ProjectStore()
        store.media = FakeMedia()
        return store
    }

    @MainActor
    @Test("store dispatch: .dslibrary / wrong extension / missing file error shapes")
    func storeExtensionDispatch() throws {
        let store = makeStore()
        let track = store.addTrack(kind: .instrument)
        let dir = tempDir()

        func message(_ path: String) -> String {
            do {
                _ = try store.importSampleLibrary(trackID: track.id, path: path)
                return ""
            } catch {
                return (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
        let library = try writeSample("Piano.dslibrary", in: dir)
        #expect(message(library.path)
            == ".dslibrary is a zip archive — unzip it and import the .dspreset inside")
        let stray = try writeSample("Piano.exs", in: dir)
        #expect(message(stray.path)
            == "Piano.exs is not a sample library — this build imports .sfz (documented subset) and .dspreset sample-library files")
        #expect(message(dir.appendingPathComponent("ghost.sfz").path)
            .hasPrefix("no sample library file at "))
    }

    @MainActor
    @Test("store dispatch routes .dspreset through DSPresetParser (m19-d — no preprocess step)")
    func storeDSPresetDispatch() throws {
        let store = makeStore()
        let track = store.addTrack(kind: .instrument)
        let dir = tempDir()
        try writeSample("a.wav", in: dir)
        let preset = dir.appendingPathComponent("mini.dspreset")
        try Data("""
        <DecentSampler>
          <groups><group><sample path="a.wav" rootNote="60"/></group></groups>
        </DecentSampler>
        """.utf8).write(to: preset)

        let report = try store.importSampleLibrary(
            trackID: track.id, path: preset.path, dryRun: true)
        #expect(report.format == .dspreset)
        #expect(report.zonesImported == 1)
        #expect(store.tracks[0].instrument == nil)   // dryRun touches nothing
    }

    @MainActor
    @Test("store: dryRun computes the report and touches NOTHING; apply journals one undoable edit")
    func storeDryRunAndApply() throws {
        let store = makeStore()
        let track = store.addTrack(kind: .instrument)
        let dir = tempDir()
        try writeSample("a.wav", in: dir)
        let sfz = dir.appendingPathComponent("lib.sfz")
        try Data("<region> sample=a.wav lokey=10 hikey=20\n".utf8).write(to: sfz)

        let labelBeforeDryRun = store.undoLabel       // "Add Track" from the fixture
        let dryReport = try store.importSampleLibrary(
            trackID: track.id, path: sfz.path, dryRun: true)
        #expect(dryReport.zonesImported == 1)
        #expect(store.tracks[0].instrument == nil)     // untouched
        #expect(store.undoLabel == labelBeforeDryRun)  // no NEW journal entry

        let report = try store.importSampleLibrary(trackID: track.id, path: sfz.path)
        #expect(report.zonesImported == 1)
        let instrument = try #require(store.tracks[0].instrument)
        #expect(instrument.kind == .sampler)
        #expect(instrument.sampler?.zones.first?.minPitch == 10)
        #expect(store.undoLabel == "Change Instrument")  // the EXISTING set path
        _ = try store.undo()
        #expect(store.tracks[0].instrument == nil)       // one edit, fully reverted
    }

    @MainActor
    @Test("store: zero playable zones on APPLY throws with the skip summary; dryRun still reports")
    func storeZeroZonesApply() throws {
        let store = makeStore()
        let track = store.addTrack(kind: .instrument)
        let dir = tempDir()
        try writeSample("a.wav", in: dir)
        let sfz = dir.appendingPathComponent("rel.sfz")
        try Data("<region> sample=a.wav trigger=release\n".utf8).write(to: sfz)

        let dryReport = try store.importSampleLibrary(
            trackID: track.id, path: sfz.path, dryRun: true)
        #expect(dryReport.zonesImported == 0)

        #expect {
            try store.importSampleLibrary(trackID: track.id, path: sfz.path)
        } throws: { error in
            guard case SampleLibraryImportError.noPlayableZones(let report) = error
            else { return false }
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            return report.skippedRegions["trigger=release"] == 1
                && message.contains("trigger=release ×1")
        }
        #expect(store.tracks[0].instrument == nil)
    }

    @MainActor
    @Test("store: unknown track and non-instrument track refuse before any file work")
    func storeTrackGuards() throws {
        let store = makeStore()
        let audio = store.addTrack(kind: .audio)
        #expect(throws: ProjectError.self) {
            try store.importSampleLibrary(trackID: UUID(), path: "/tmp/x.sfz")
        }
        #expect(throws: ProjectError.self) {
            try store.importSampleLibrary(trackID: audio.id, path: "/tmp/x.sfz")
        }
    }
}
