import Foundation
import Testing
@testable import DAWCore

/// m19-d: the `.dspreset` XML parser onto the shared `SampleLibraryIR`.
/// House fixture idiom — inline string literals written to temp dirs, no
/// bundle resources (§7). Covers the three text-verified real-world shapes
/// (RES §3.5: the official boilerplate skeleton, the format author's
/// Kontakt-export attribute set, the minimal community one-liner), the
/// groups→group→sample nearest-wins inheritance, every native→neutral unit
/// conversion, the seqMode policy, and the m19-d roadmap GATE: field-level
/// parity between the SAME instrument authored as .sfz and as .dspreset.
@Suite(".dspreset parser (m19-d)")
struct DSPresetParserTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dspreset-parse-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func write(_ name: String, in dir: URL, _ text: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    @discardableResult
    private func writeSample(_ name: String, in dir: URL, bytes: Int = 4) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    /// Writes the preset text and parses it.
    private func parse(_ text: String, in dir: URL,
                       name: String = "preset.dspreset") throws -> SampleLibraryIR {
        let url = try write(name, in: dir, text)
        return try DSPresetParser.parse(fileAt: url)
    }

    // MARK: - The three text-verified real-world shapes (RES §3.5)

    @Test("the official boilerplate skeleton parses to zero regions cleanly; chrome elements are counted")
    func boilerplateSkeleton() throws {
        let dir = tempDir()
        let ir = try parse("""
        <?xml version="1.0" encoding="UTF-8"?>
        <DecentSampler minVersion="1.0.0">
            <ui width="812" height="375">
                <tab name="main"/>
            </ui>
            <groups attack="0.000" decay="25" sustain="1.0" release="0.430" volume="1.0">
                <group>
                </group>
            </groups>
            <effects>
                <effect type="lowpass" frequency="22000.0"/>
            </effects>
            <midi/>
        </DecentSampler>
        """, in: dir)
        #expect(ir.format == .dspreset)
        #expect(ir.baseDirectory.standardizedFileURL == dir.standardizedFileURL)
        #expect(ir.regions.isEmpty)
        #expect(ir.ignoredHeaders == ["<ui>": 1, "<effects>": 1, "<midi>": 1])
    }

    @Test("the format author's Kontakt-export attribute set maps every field")
    func hilowitzExportAttributeSet() throws {
        let dir = tempDir()
        let ir = try parse("""
        <DecentSampler>
          <groups>
            <group>
              <sample path="Samples/C4_f_rr1.wav" rootNote="60" loNote="48" hiNote="72"
                      loVel="64" hiVel="127" start="0" end="119546" tuning="-0.5"
                      volume="0.8" ampVelTrack="0.75" loopEnabled="true"
                      loopStart="2000" loopEnd="100000" loopCrossfade="1000"/>
            </group>
          </groups>
        </DecentSampler>
        """, in: dir)
        let region = try #require(ir.regions.first)
        #expect(region.samplePath == "Samples/C4_f_rr1.wav")
        #expect(region.defaultPath == nil)          // no default_path equivalent
        #expect(region.groupIndex == 0)
        #expect(region.keyCenter == 60)
        #expect(region.loKey == 48)
        #expect(region.hiKey == 72)
        #expect(region.loVel == 64)
        #expect(region.hiVel == 127)
        #expect(region.offsetFrames == 0)
        #expect(region.endFrame == 119_546)         // INCLUSIVE — mapper does the +1
        #expect(region.tuneCents == -50)            // semitones ×100
        #expect(region.gainLinear == 0.8)           // plain number → linear
        #expect(region.volumeDB == nil)
        #expect(region.ampVelTrackPercent == 75)    // 0…1 fraction ×100
        #expect(region.loopMode == "loop_continuous")  // real looping since m20-g
        #expect(region.loopStartFrame == 2_000)
        #expect(region.loopEndFrame == 100_000)        // INCLUSIVE — mapper does the +1
        // Authored crossfades stay out of the v1 subset — ignored, original
        // spelling (the engine's fixed equal-gain policy applies).
        #expect(region.ignored == ["loopCrossfade"])
        #expect(region.trigger == nil)              // nil reads as "attack"
        #expect(!region.ccTriggered)
    }

    @Test("the minimal community one-liner parses with everything else nil")
    func minimalCommunityPattern() throws {
        let dir = tempDir()
        let ir = try parse("""
        <DecentSampler>
          <groups>
            <group>
              <sample loNote="72" hiNote="72" rootNote="72" path="minibrass_72.wav"/>
            </group>
          </groups>
        </DecentSampler>
        """, in: dir)
        let region = try #require(ir.regions.first)
        #expect(region.samplePath == "minibrass_72.wav")
        #expect(region.loKey == 72)
        #expect(region.hiKey == 72)
        #expect(region.keyCenter == 72)
        #expect(region.groupIndex == 0)
        #expect(region.loVel == nil)
        #expect(region.hiVel == nil)
        #expect(region.seqLength == nil)
        #expect(region.randLo == nil)
        #expect(region.volumeDB == nil)
        #expect(region.gainLinear == nil)
        #expect(region.pan == nil)
        #expect(region.tuneCents == nil)
        #expect(region.ampVelTrackPercent == nil)
        #expect(region.offsetFrames == nil)
        #expect(region.endFrame == nil)
        #expect(region.attackSeconds == nil)
        #expect(region.decaySeconds == nil)
        #expect(region.sustainPercent == nil)
        #expect(region.releaseSeconds == nil)
        #expect(region.loopMode == nil)
        #expect(region.loopStartFrame == nil)
        #expect(region.loopEndFrame == nil)
        #expect(region.ignored.isEmpty)
    }

    // MARK: - Inheritance (groups → group → sample, nearest wins)

    @Test("attribute-level inheritance: <groups> defaults, <group> overrides, <sample> overrides — nearest wins")
    func nearestWinsInheritance() throws {
        let dir = tempDir()
        let ir = try parse("""
        <DecentSampler>
          <groups volume="0.5" release="0.25" pan="10">
            <group volume="0.7" pan="-100" attack="0.01">
              <sample path="a.wav" volume="0.9"/>
              <sample path="b.wav"/>
            </group>
            <group>
              <sample path="c.wav"/>
            </group>
          </groups>
        </DecentSampler>
        """, in: dir)
        #expect(ir.regions.count == 3)
        // a.wav: sample wins volume; group wins pan; groups supplies release.
        #expect(ir.regions[0].gainLinear == 0.9)
        #expect(ir.regions[0].pan == -100)
        #expect(ir.regions[0].attackSeconds == 0.01)
        #expect(ir.regions[0].releaseSeconds == 0.25)
        // b.wav: group wins volume/pan; groups supplies release.
        #expect(ir.regions[1].gainLinear == 0.7)
        #expect(ir.regions[1].pan == -100)
        #expect(ir.regions[1].attackSeconds == 0.01)
        // c.wav: only the <groups> instrument-wide defaults apply.
        #expect(ir.regions[2].gainLinear == 0.5)
        #expect(ir.regions[2].pan == 10)
        #expect(ir.regions[2].attackSeconds == nil)
        #expect(ir.regions[2].releaseSeconds == 0.25)
    }

    @Test("each <group> element is one fresh groupIndex ordinal; a sample directly under <groups> stays ungrouped")
    func groupIdentity() throws {
        let dir = tempDir()
        let ir = try parse("""
        <DecentSampler>
          <groups volume="0.5">
            <group><sample path="a.wav"/><sample path="b.wav"/></group>
            <sample path="loose.wav"/>
            <group><sample path="c.wav"/></group>
          </groups>
        </DecentSampler>
        """, in: dir)
        #expect(ir.regions.map(\.groupIndex) == [0, 0, nil, 1])
        // The ungrouped sample still inherits the instrument-wide defaults.
        #expect(ir.regions[2].gainLinear == 0.5)
    }

    // MARK: - Unit conversions

    @Test("volume: plain number → gainLinear, dB suffix → volumeDB (§2.2), garbage → ignored")
    func volumeLinearVsDB() throws {
        let dir = tempDir()
        let ir = try parse("""
        <DecentSampler>
          <groups>
            <group>
              <sample path="a.wav" volume="1.5"/>
              <sample path="b.wav" volume="3dB"/>
              <sample path="c.wav" volume="-6 dB"/>
              <sample path="d.wav" volume="loud"/>
            </group>
          </groups>
        </DecentSampler>
        """, in: dir)
        #expect(ir.regions[0].gainLinear == 1.5)
        #expect(ir.regions[0].volumeDB == nil)
        #expect(ir.regions[1].volumeDB == 3)
        #expect(ir.regions[1].gainLinear == nil)
        #expect(ir.regions[2].volumeDB == -6)
        #expect(ir.regions[3].gainLinear == nil)
        #expect(ir.regions[3].volumeDB == nil)
        #expect(ir.regions[3].ignored.contains("volume"))
    }

    @Test("tuning is fractional semitones → cents ×100; sustain and ampVelTrack are 0…1 fractions → percent ×100")
    func fractionalUnitConversions() throws {
        let dir = tempDir()
        let ir = try parse("""
        <DecentSampler>
          <groups>
            <group>
              <sample path="a.wav" tuning="-0.5" sustain="0.75" ampVelTrack="0.25"/>
              <sample path="b.wav" tuning="12"/>
            </group>
          </groups>
        </DecentSampler>
        """, in: dir)
        #expect(ir.regions[0].tuneCents == -50)
        #expect(ir.regions[0].sustainPercent == 75)
        #expect(ir.regions[0].ampVelTrackPercent == 25)
        #expect(ir.regions[1].tuneCents == 1_200)
        #expect(ir.regions[0].transposeSemitones == nil)  // SFZ-only field
    }

    @Test("pitch values accept MIDI numbers and note names (c4 = 60)")
    func noteNamePitches() throws {
        let dir = tempDir()
        let ir = try parse("""
        <DecentSampler>
          <groups><group>
            <sample path="a.wav" rootNote="c4" loNote="a0" hiNote="c8"/>
          </group></groups>
        </DecentSampler>
        """, in: dir)
        #expect(ir.regions[0].keyCenter == 60)
        #expect(ir.regions[0].loKey == 21)
        #expect(ir.regions[0].hiKey == 108)
    }

    // MARK: - seqMode policy

    @Test("seqMode=round_robin passes seqLength/seqPosition through; absent/always emits no gate and no tally")
    func seqModeRoundRobinAndAlways() throws {
        let dir = tempDir()
        let ir = try parse("""
        <DecentSampler>
          <groups>
            <group seqMode="round_robin" seqLength="4">
              <sample path="a.wav" seqPosition="2"/>
            </group>
            <group seqMode="always" seqLength="4">
              <sample path="b.wav" seqPosition="2"/>
            </group>
            <group>
              <sample path="c.wav" seqPosition="3"/>
            </group>
          </groups>
        </DecentSampler>
        """, in: dir)
        #expect(ir.regions[0].seqLength == 4)
        #expect(ir.regions[0].seqPosition == 2)
        #expect(ir.regions[0].randLo == nil)
        // always (explicit or the format default): the sample plays on
        // every trigger — seq attributes are inert in the format too, so
        // honoring them silently is exact, not a degradation.
        for region in ir.regions[1...] {
            #expect(region.seqLength == nil)
            #expect(region.seqPosition == nil)
            #expect(region.ignored.isEmpty)
        }
    }

    @Test("seqMode=random/true_random partitions [0,1) by position; unbuildable spans degrade to ignored")
    func seqModeRandom() throws {
        let dir = tempDir()
        let ir = try parse("""
        <DecentSampler>
          <groups>
            <group seqMode="random" seqLength="4">
              <sample path="a.wav" seqPosition="1"/>
              <sample path="b.wav" seqPosition="4"/>
            </group>
            <group seqMode="true_random" seqLength="2">
              <sample path="c.wav" seqPosition="2"/>
            </group>
            <group seqMode="random">
              <sample path="d.wav"/>
            </group>
            <group seqMode="shuffle" seqLength="2">
              <sample path="e.wav" seqPosition="1"/>
            </group>
          </groups>
        </DecentSampler>
        """, in: dir)
        #expect(ir.regions[0].randLo == 0)
        #expect(ir.regions[0].randHi == 0.25)
        #expect(ir.regions[1].randLo == 0.75)
        #expect(ir.regions[1].randHi == 1.0)       // closes the interval
        #expect(ir.regions[1].seqLength == nil)    // random: no RR gate
        #expect(ir.regions[2].randLo == 0.5)       // true_random → same law
        #expect(ir.regions[2].randHi == 1.0)
        // No seqLength/seqPosition to build the span → mode ignored.
        #expect(ir.regions[3].randLo == nil)
        #expect(ir.regions[3].ignored == ["seqMode"])
        // Unrecognized mode value → ignored.
        #expect(ir.regions[4].randLo == nil)
        #expect(ir.regions[4].seqLength == nil)
        #expect(ir.regions[4].ignored == ["seqMode"])
    }

    // MARK: - Degradation-policy inputs (§2.3)

    @Test("loopEnabled=true maps to a real continuous loop; false suppresses the smpl fallback")
    func loopEnabledReportPath() throws {
        let dir = tempDir()
        try writeSample("a.wav", in: dir)
        try writeSample("b.wav", in: dir)
        let ir = try parse("""
        <DecentSampler>
          <groups><group>
            <sample path="a.wav" loopEnabled="true"/>
            <sample path="b.wav" loopEnabled="false"/>
          </group></groups>
        </DecentSampler>
        """, in: dir)
        #expect(ir.regions[0].loopMode == "loop_continuous")
        // "false" records the EXPLICIT no_loop (m20-g) so the author's
        // intent suppresses the WAV smpl fallback in the mapper.
        #expect(ir.regions[1].loopMode == "no_loop")
        let (params, report) = try SampleLibraryMapper.map(ir)
        #expect(params.zones.count == 2)
        #expect(params.zones.allSatisfy { $0.oneShot == nil })  // loops are not one-shots
        // m20-g: loopEnabled="true" is a REAL loop now (points nil — the
        // engine resolves them to the playable span); "false" imports
        // unlooped with no note.
        #expect(params.zones[0].loopMode == .continuous)
        #expect(params.zones[0].loopStart == nil)
        #expect(params.zones[0].loopEnd == nil)
        #expect(params.zones[1].loopMode == nil)
        #expect(report.loopedZones == 1)
        #expect(!report.degradations.contains { $0.contains("looping") })
    }

    @Test("trigger=release reaches the IR verbatim and the mapper skips it reason-coded")
    func triggerReachesIRAndSkips() throws {
        let dir = tempDir()
        try writeSample("rel.wav", in: dir)
        try writeSample("atk.wav", in: dir)
        let ir = try parse("""
        <DecentSampler>
          <groups>
            <group trigger="release">
              <sample path="rel.wav"/>
            </group>
            <group>
              <sample path="atk.wav" trigger="attack"/>
            </group>
          </groups>
        </DecentSampler>
        """, in: dir)
        #expect(ir.regions[0].trigger == "release")
        #expect(ir.regions[1].trigger == "attack")
        let (params, report) = try SampleLibraryMapper.map(ir)
        #expect(params.zones.count == 1)
        #expect(params.zones[0].audioFileURL.lastPathComponent == "atk.wav")
        #expect(report.skippedRegions["trigger=release"] == 1)
    }

    @Test("onLoCCN/onHiCCN set ccTriggered; loCCN/hiCCN gating stays an ignored attribute")
    func ccTriggerDetection() throws {
        let dir = tempDir()
        let ir = try parse("""
        <DecentSampler>
          <groups><group>
            <sample path="a.wav" onLoCC64="126"/>
            <sample path="b.wav" onHiCC1="10"/>
            <sample path="c.wav" loCC64="0" hiCC64="63"/>
          </group></groups>
        </DecentSampler>
        """, in: dir)
        #expect(ir.regions[0].ccTriggered)
        #expect(ir.regions[0].ignored.isEmpty)
        #expect(ir.regions[1].ccTriggered)
        #expect(!ir.regions[2].ccTriggered)
        #expect(ir.regions[2].ignored == ["hiCC64", "loCC64"])
    }

    @Test("out-of-subset attributes land in ignored under their original spelling; the region still parses")
    func outOfSubsetAttributes() throws {
        let dir = tempDir()
        let ir = try parse("""
        <DecentSampler>
          <groups><group name="Close Mics" silencedByTags="mute-group-1">
            <sample path="a.wav" rootNote="60" attackCurve="-100" pitchKeyTrack="0.5"
                    delay="10" output1Target="AUX1" tags="rr1"/>
          </group></groups>
        </DecentSampler>
        """, in: dir)
        let region = try #require(ir.regions.first)
        #expect(region.keyCenter == 60)
        #expect(region.ignored == ["attackCurve", "delay", "output1Target",
                                   "pitchKeyTrack", "silencedByTags", "tags"])
        // "name" is cosmetic group metadata — consumed silently, no tally.
        #expect(!region.ignored.contains("name"))
    }

    @Test("unparseable recognized values degrade to ignored, never abort (m19-c amendment 11)")
    func unparseableValuesDegrade() throws {
        let dir = tempDir()
        let ir = try parse("""
        <DecentSampler>
          <groups><group>
            <sample path="a.wav" rootNote="banana" loVel="soft" tuning="sharp"
                    start="1.5" loopEnabled="maybe" hiNote="72"/>
          </group></groups>
        </DecentSampler>
        """, in: dir)
        let region = try #require(ir.regions.first)
        #expect(region.hiKey == 72)                 // the good value still lands
        #expect(region.keyCenter == nil)
        #expect(region.loVel == nil)
        #expect(region.tuneCents == nil)
        #expect(region.offsetFrames == nil)         // 1.5 frames is not an int
        #expect(region.loopMode == nil)
        #expect(region.ignored == ["loVel", "loopEnabled", "rootNote",
                                   "start", "tuning"])
    }

    // MARK: - Structural errors (the SFZPreprocessorError voice)

    @Test("malformed XML aborts with a structured, readable error naming the file")
    func malformedXMLAborts() throws {
        let dir = tempDir()
        let url = try write("broken.dspreset", in: dir,
                            "<DecentSampler><groups><group>")
        #expect {
            _ = try DSPresetParser.parse(fileAt: url)
        } throws: { error in
            guard case DSPresetParserError.malformedXML(let path, _) = error
            else { return false }
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            return path == url.path
                && message.hasPrefix("malformed .dspreset XML in ")
        }
    }

    @Test("a wrong root element aborts naming what was found")
    func wrongRootAborts() throws {
        let dir = tempDir()
        let url = try write("notapreset.dspreset", in: dir,
                            "<Instrument><groups/></Instrument>")
        #expect {
            _ = try DSPresetParser.parse(fileAt: url)
        } throws: { error in
            guard case DSPresetParserError.wrongRootElement(let found, _) = error
            else { return false }
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            return found == "Instrument"
                && message.contains("expected <DecentSampler>")
        }
    }

    @Test("a missing file aborts as unreadable")
    func missingFileAborts() throws {
        let dir = tempDir()
        let ghost = dir.appendingPathComponent("ghost.dspreset")
        #expect(throws: DSPresetParserError.unreadableFile(path: ghost.path)) {
            _ = try DSPresetParser.parse(fileAt: ghost)
        }
    }

    // MARK: - The m19-d roadmap GATE: .sfz / .dspreset parity

    /// Every SamplerZone field except the random identity.
    private func expectZoneParity(_ sfz: SamplerZone, _ dspreset: SamplerZone,
                                  _ label: String) {
        #expect(sfz.audioFileURL == dspreset.audioFileURL, "audioFileURL @ \(label)")
        #expect(sfz.rootPitch == dspreset.rootPitch, "rootPitch @ \(label)")
        #expect(sfz.minPitch == dspreset.minPitch, "minPitch @ \(label)")
        #expect(sfz.maxPitch == dspreset.maxPitch, "maxPitch @ \(label)")
        #expect(sfz.gain == dspreset.gain, "gain @ \(label)")
        #expect(sfz.minVelocity == dspreset.minVelocity, "minVelocity @ \(label)")
        #expect(sfz.maxVelocity == dspreset.maxVelocity, "maxVelocity @ \(label)")
        #expect(sfz.group == dspreset.group, "group @ \(label)")
        #expect(sfz.seqLength == dspreset.seqLength, "seqLength @ \(label)")
        #expect(sfz.seqPosition == dspreset.seqPosition, "seqPosition @ \(label)")
        #expect(sfz.randMin == dspreset.randMin, "randMin @ \(label)")
        #expect(sfz.randMax == dspreset.randMax, "randMax @ \(label)")
        #expect(sfz.tuneCents == dspreset.tuneCents, "tuneCents @ \(label)")
        #expect(sfz.pan == dspreset.pan, "pan @ \(label)")
        #expect(sfz.ampVelTrack == dspreset.ampVelTrack, "ampVelTrack @ \(label)")
        #expect(sfz.oneShot == dspreset.oneShot, "oneShot @ \(label)")
        #expect(sfz.startFrame == dspreset.startFrame, "startFrame @ \(label)")
        #expect(sfz.endFrame == dspreset.endFrame, "endFrame @ \(label)")
        #expect(sfz.attack == dspreset.attack, "attack @ \(label)")
        #expect(sfz.decay == dspreset.decay, "decay @ \(label)")
        #expect(sfz.sustain == dspreset.sustain, "sustain @ \(label)")
        #expect(sfz.release == dspreset.release, "release @ \(label)")
        // m20-g loop fields (§8.2 case 10).
        #expect(sfz.loopMode == dspreset.loopMode, "loopMode @ \(label)")
        #expect(sfz.loopStart == dspreset.loopStart, "loopStart @ \(label)")
        #expect(sfz.loopEnd == dspreset.loopEnd, "loopEnd @ \(label)")
    }

    @Test("PARITY GATE: the same instrument authored as .sfz and as .dspreset maps to EQUAL zones, field by field")
    func sfzDSPresetParity() throws {
        let dir = tempDir()
        try writeSample("soft.wav", in: dir, bytes: 64)
        try writeSample("soft_rr2.wav", in: dir, bytes: 64)
        try writeSample("hard.wav", in: dir, bytes: 64)

        // The SAME two-layer instrument: a round-robin soft layer with the
        // full m19-b scalar set + an m20-g loop, and a bare hard layer.
        let sfzURL = try write("parity.sfz", in: dir, """
        <group> lovel=0 hivel=63 volume=-6 pan=-30 tune=-50 amp_veltrack=50 \
        ampeg_attack=0.01 ampeg_decay=0.5 ampeg_sustain=75 ampeg_release=0.3 \
        offset=10 end=8000 seq_length=2 \
        loop_mode=loop_continuous loop_start=4410 loop_end=48509
        <region> sample=soft.wav lokey=48 hikey=60 pitch_keycenter=54 seq_position=1
        <region> sample=soft_rr2.wav lokey=48 hikey=60 pitch_keycenter=54 seq_position=2
        <group> lovel=64 hivel=127
        <region> sample=hard.wav lokey=61 hikey=72 pitch_keycenter=66
        """)
        let dspresetURL = try write("parity.dspreset", in: dir, """
        <DecentSampler>
          <groups>
            <group loVel="0" hiVel="63" volume="-6dB" pan="-30" tuning="-0.5"
                   ampVelTrack="0.5" attack="0.01" decay="0.5" sustain="0.75"
                   release="0.3" start="10" end="8000"
                   seqMode="round_robin" seqLength="2"
                   loopEnabled="true" loopStart="4410" loopEnd="48509">
              <sample path="soft.wav" loNote="48" hiNote="60" rootNote="54" seqPosition="1"/>
              <sample path="soft_rr2.wav" loNote="48" hiNote="60" rootNote="54" seqPosition="2"/>
            </group>
            <group loVel="64" hiVel="127">
              <sample path="hard.wav" loNote="61" hiNote="72" rootNote="66"/>
            </group>
          </groups>
        </DecentSampler>
        """)

        let sfzText = try SFZPreprocessor.preprocess(fileAt: sfzURL)
        let sfzIR = SFZParser.parse(text: sfzText, baseDirectory: dir)
        let dspresetIR = try DSPresetParser.parse(fileAt: dspresetURL)
        let (sfzParams, sfzReport) = try SampleLibraryMapper.map(sfzIR)
        let (dsParams, dsReport) = try SampleLibraryMapper.map(dspresetIR)

        // Zones: EQUAL field-by-field (modulo the random UUID identity).
        #expect(sfzParams.zones.count == 3)
        #expect(dsParams.zones.count == 3)
        for (index, pair) in zip(sfzParams.zones, dsParams.zones).enumerated() {
            expectZoneParity(pair.0, pair.1, "zone \(index)")
        }
        // Global params are format-independent defaults on both sides.
        #expect(sfzParams.oneShot == dsParams.oneShot)
        #expect(sfzParams.attack == dsParams.attack)
        #expect(sfzParams.release == dsParams.release)
        #expect(sfzParams.gain == dsParams.gain)

        // Reports: EQUAL modulo format.
        #expect(sfzReport.format == .sfz)
        #expect(dsReport.format == .dspreset)
        var neutral = sfzReport
        neutral.format = dsReport.format
        #expect(neutral == dsReport)
        #expect(dsReport.zonesImported == 3)
        #expect(dsReport.groupCount == 2)
        #expect(dsReport.velocityLayerCount == 2)
        #expect(dsReport.skippedRegions.isEmpty)
        #expect(dsReport.ignoredOpcodes.isEmpty)
        #expect(dsReport.degradations.isEmpty)
        // m20-g (§8.2 case 10): the loop lands field-identically — the +1
        // law applied once, on the shared inclusive convention.
        #expect(dsParams.zones[0].loopMode == .continuous)
        #expect(dsParams.zones[0].loopStart == 4_410)
        #expect(dsParams.zones[0].loopEnd == 48_510)
        #expect(dsReport.loopedZones == 2)   // both soft-layer zones loop
        #expect(sfzReport.loopedZones == 2)
    }
}
