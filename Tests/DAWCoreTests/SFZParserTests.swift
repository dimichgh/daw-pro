import Foundation
import Testing
@testable import DAWCore

/// m19-c: the SFZ preprocessor + tokenizer + header-inheritance parser.
/// House fixture idiom — inline string literals written to temp dirs, no
/// bundle resources (§7). Every tokenizer wart from the design's §5.1 file
/// table gets a first-class test here.
@Suite("SFZ preprocessor + parser (m19-c)")
struct SFZParserTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sfz-parse-\(UUID().uuidString)", isDirectory: true)
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

    private let base = URL(fileURLWithPath: "/tmp/sfz-tests")

    private func parse(_ text: String) -> SampleLibraryIR {
        SFZParser.parse(text: text, baseDirectory: base)
    }

    // MARK: - Tokenizer warts

    @Test("sample= values keep their SPACES — value runs to the next word= token (the sfizz rule)")
    func spacedSampleValues() throws {
        let ir = parse("<region> sample=Kick 1 final.wav lokey=36 hikey=36")
        let region = try #require(ir.regions.first)
        #expect(region.samplePath == "Kick 1 final.wav")
        #expect(region.loKey == 36)
        #expect(region.hiKey == 36)
    }

    @Test("a spaced sample value stops at end of line")
    func spacedValueToEOL() throws {
        let ir = parse("<region> lokey=40 sample=snare hard hit.wav\n<region> sample=b.wav")
        #expect(ir.regions.count == 2)
        #expect(ir.regions[0].samplePath == "snare hard hit.wav")
        #expect(ir.regions[1].samplePath == "b.wav")
    }

    @Test("default_path with spaces and backslashes survives tokenizing")
    func spacedDefaultPath() throws {
        let ir = parse("<control> default_path=My Samples\\close\\\n<region> sample=c4.wav")
        let region = try #require(ir.regions.first)
        #expect(region.defaultPath == "My Samples\\close\\")
        #expect(region.samplePath == "c4.wav")
    }

    @Test("note-name pitches: c4, a#3, db4, case-insensitive, C-1…G9 span 0…127")
    func noteNames() throws {
        let ir = parse("""
        <region> sample=a.wav lokey=c-1 hikey=g9 pitch_keycenter=C4
        <region> sample=b.wav lokey=a#3 hikey=Db5 pitch_keycenter=60
        """)
        #expect(ir.regions[0].loKey == 0)
        #expect(ir.regions[0].hiKey == 127)
        #expect(ir.regions[0].keyCenter == 60)
        #expect(ir.regions[1].loKey == 58)   // A#3
        #expect(ir.regions[1].hiKey == 73)   // Db5
    }

    @Test("key= shorthand sets lokey/hikey/pitch_keycenter; explicit opcodes override it")
    func keyShorthand() throws {
        let ir = parse("""
        <region> sample=a.wav key=c4
        <region> sample=b.wav key=c4 pitch_keycenter=62
        """)
        #expect(ir.regions[0].loKey == 60)
        #expect(ir.regions[0].hiKey == 60)
        #expect(ir.regions[0].keyCenter == 60)
        #expect(ir.regions[1].keyCenter == 62)
        #expect(ir.regions[1].loKey == 60)
    }

    @Test("// line comments, /* block */ comments (spanning lines), and CRLF all tokenize")
    func commentsAndCRLF() throws {
        let text = "<region> sample=a.wav // trailing comment lokey=99\r\n"
            + "lokey=10 /* inline */ hikey=20\r\n"
            + "/* block\r\nspanning <region> lines */\r\n"
            + "<region> sample=b.wav"
        let ir = parse(text)
        #expect(ir.regions.count == 2)
        #expect(ir.regions[0].samplePath == "a.wav")
        #expect(ir.regions[0].loKey == 10)
        #expect(ir.regions[0].hiKey == 20)
        #expect(ir.regions[1].samplePath == "b.wav")
    }

    @Test("volume accepts plain dB numbers and a dB suffix")
    func dbValues() throws {
        let ir = parse("""
        <region> sample=a.wav volume=-6.5
        <region> sample=b.wav volume=3dB
        """)
        #expect(ir.regions[0].volumeDB == -6.5)
        #expect(ir.regions[1].volumeDB == 3)
    }

    @Test("multiple headers and opcodes on ONE line tokenize in order")
    func headersMidLine() throws {
        let ir = parse("<group> lovel=0 hivel=63 <region> sample=soft.wav <region> sample=soft2.wav")
        #expect(ir.regions.count == 2)
        #expect(ir.regions[0].loVel == 0)
        #expect(ir.regions[0].hiVel == 63)
        #expect(ir.regions[1].samplePath == "soft2.wav")
    }

    @Test("an unparseable recognized value degrades to the region's ignored list, never a crash")
    func unparseableValueDegrades() throws {
        let ir = parse("<region> sample=a.wav lokey=banana hikey=20")
        let region = try #require(ir.regions.first)
        #expect(region.loKey == nil)
        #expect(region.hiKey == 20)
        #expect(region.ignored.contains("lokey"))
    }

    // MARK: - Header inheritance

    @Test("effective region = control → global → master → group → region merge")
    func inheritancePrecedence() throws {
        let ir = parse("""
        <control> default_path=samples/
        <global> volume=-3 pan=10
        <master> pan=-20 tune=5
        <group> tune=7 lovel=64
        <region> sample=a.wav lovel=100
        """)
        let region = try #require(ir.regions.first)
        #expect(region.defaultPath == "samples/")
        #expect(region.volumeDB == -3)      // global survives
        #expect(region.pan == -20)          // master overrides global
        #expect(region.tuneCents == 7)      // group overrides master
        #expect(region.loVel == 100)        // region overrides group
    }

    @Test("a new <group> resets the previous group scope; <master> resets group")
    func headerScopeResets() throws {
        let ir = parse("""
        <group> lovel=64 seq_length=2
        <region> sample=a.wav
        <group> hivel=63
        <region> sample=b.wav
        <master> volume=-3
        <region> sample=c.wav
        """)
        #expect(ir.regions[0].loVel == 64)
        #expect(ir.regions[0].seqLength == 2)
        #expect(ir.regions[1].loVel == nil)      // second <group> reset the first
        #expect(ir.regions[1].hiVel == 63)
        #expect(ir.regions[2].hiVel == nil)      // <master> reset the group scope
        #expect(ir.regions[2].volumeDB == -3)
        #expect(ir.regions[2].groupIndex == nil) // and un-grouped what follows
    }

    @Test("group ordinals count <group> headers in file order; ungrouped regions carry nil")
    func groupOrdinals() throws {
        let ir = parse("""
        <region> sample=solo.wav
        <group> lovel=0
        <region> sample=a.wav
        <region> sample=b.wav
        <group> lovel=64
        <region> sample=c.wav
        """)
        #expect(ir.regions[0].groupIndex == nil)
        #expect(ir.regions[1].groupIndex == 0)
        #expect(ir.regions[2].groupIndex == 0)
        #expect(ir.regions[3].groupIndex == 1)
    }

    @Test("unknown headers (<curve>, <effect>) swallow their opcodes and are counted")
    func unknownHeadersCounted() throws {
        let ir = parse("""
        <region> sample=a.wav
        <curve> curve_index=17 v000=0 v127=1
        <region> sample=b.wav
        <effect> type=reverb
        """)
        #expect(ir.regions.count == 2)
        #expect(ir.regions[1].ignored.isEmpty)   // curve opcodes did NOT leak in
        #expect(ir.ignoredHeaders["<curve>"] == 1)
        #expect(ir.ignoredHeaders["<effect>"] == 1)
    }

    @Test("excluded opcodes land in the region's ignored list; on_loccN flags ccTriggered")
    func excludedOpcodes() throws {
        let ir = parse("""
        <group> cutoff=800 resonance=2
        <region> sample=a.wav xfin_lovel=0
        <region> sample=b.wav on_locc64=127
        """)
        #expect(ir.regions[0].ignored.contains("cutoff"))
        #expect(ir.regions[0].ignored.contains("resonance"))
        #expect(ir.regions[0].ignored.contains("xfin_lovel"))
        #expect(ir.regions[0].ccTriggered == false)
        #expect(ir.regions[1].ccTriggered == true)
        #expect(!ir.regions[1].ignored.contains("on_locc64"))  // consumed as policy input
    }

    @Test("trigger, sw_last/sw_default (note names), loop_mode + loopmode alias parse")
    func policyInputs() throws {
        let ir = parse("""
        <region> sample=a.wav trigger=Release sw_last=c1 sw_default=C1
        <region> sample=b.wav loop_mode=one_shot
        <region> sample=c.wav loopmode=loop_continuous
        """)
        #expect(ir.regions[0].trigger == "release")
        #expect(ir.regions[0].swLast == 24)
        #expect(ir.regions[0].swDefault == 24)
        #expect(ir.regions[1].loopMode == "one_shot")
        #expect(ir.regions[2].loopMode == "loop_continuous")
    }

    @Test("loop_start/loop_end parse (m20-g); v1 spellings alias; canonical wins; bad values degrade")
    func loopPoints() throws {
        let ir = parse("""
        <region> sample=a.wav loop_start=4410 loop_end=48509
        <region> sample=b.wav loopstart=100 loopend=200
        <region> sample=c.wav loopstart=1 loop_start=2 loopend=3 loop_end=4
        <region> sample=d.wav loop_start=banana loop_end=48509
        <region> sample=e.wav
        """)
        // Canonical spellings land as typed IR fields (loop_end INCLUSIVE).
        #expect(ir.regions[0].loopStartFrame == 4_410)
        #expect(ir.regions[0].loopEndFrame == 48_509)
        #expect(ir.regions[0].ignored.isEmpty)          // consumed, never tallied
        // v1 spellings are tolerated aliases.
        #expect(ir.regions[1].loopStartFrame == 100)
        #expect(ir.regions[1].loopEndFrame == 200)
        #expect(ir.regions[1].ignored.isEmpty)
        // Both spellings authored → the canonical underscore one wins.
        #expect(ir.regions[2].loopStartFrame == 2)
        #expect(ir.regions[2].loopEndFrame == 4)
        // An unparseable value degrades to ignored (take's contract).
        #expect(ir.regions[3].loopStartFrame == nil)
        #expect(ir.regions[3].loopEndFrame == 48_509)
        #expect(ir.regions[3].ignored == ["loop_start"])
        // Absent everywhere → nil (not authored).
        #expect(ir.regions[4].loopStartFrame == nil)
        #expect(ir.regions[4].loopEndFrame == nil)
    }

    // MARK: - #define

    @Test("#define substitutes $VARs textually, longest-name-first, last definition wins")
    func defineSubstitution() throws {
        let dir = tempDir()
        let main = try write("main.sfz", in: dir, """
        #define $VEL v1
        #define $VELX special
        #define $EXT wav
        #define $EXT flac
        <region> sample=$VELX/a.$EXT lokey=10 hikey=10
        <region> sample=$VEL/b.$EXT lokey=11 hikey=11
        """)
        let text = try SFZPreprocessor.preprocess(fileAt: main)
        let ir = SFZParser.parse(text: text, baseDirectory: dir)
        // $VELX matched as the LONGER name, not $VEL + "X"; $EXT redefined.
        #expect(ir.regions[0].samplePath == "special/a.flac")
        #expect(ir.regions[1].samplePath == "v1/b.flac")
    }

    @Test("an undefined $VAR at use aborts, naming the variable and the file")
    func undefinedVariableAborts() throws {
        let dir = tempDir()
        let main = try write("main.sfz", in: dir,
                             "#define $A 1\n<region> sample=$MISSING.wav")
        #expect {
            _ = try SFZPreprocessor.preprocess(fileAt: main)
        } throws: { error in
            guard case SFZPreprocessorError.undefinedVariable(let name, let file) = error
            else { return false }
            return name == "$MISSING" && file.hasSuffix("main.sfz")
        }
    }

    @Test("a malformed #define (no $name or no value) aborts structurally")
    func malformedDefineAborts() throws {
        let dir = tempDir()
        let main = try write("main.sfz", in: dir, "#define NOPE 3")
        #expect(throws: SFZPreprocessorError.self) {
            _ = try SFZPreprocessor.preprocess(fileAt: main)
        }
        let missing = try write("main2.sfz", in: dir, "#define $ONLY")
        #expect(throws: SFZPreprocessorError.self) {
            _ = try SFZPreprocessor.preprocess(fileAt: missing)
        }
    }

    // MARK: - #include

    @Test("#include nests and resolves relative to the MAIN file's folder (the ARIA rule)")
    func includeMainFileRelative() throws {
        let dir = tempDir()
        // inner.txt lives in Data/ but includes "Data/leaf.txt" — a path that
        // only resolves MAIN-file-relative, never inner-file-relative.
        try write("Data/leaf.txt", in: dir, "<region> sample=leaf.wav lokey=1 hikey=1")
        try write("Data/inner.txt", in: dir, "#include \"Data/leaf.txt\"\n<region> sample=inner.wav lokey=2 hikey=2")
        let main = try write("main.sfz", in: dir, "#include \"Data/inner.txt\"")
        let text = try SFZPreprocessor.preprocess(fileAt: main)
        let ir = SFZParser.parse(text: text, baseDirectory: dir)
        #expect(ir.regions.map(\.samplePath) == ["leaf.wav", "inner.wav"])
    }

    @Test("a missing #include aborts, naming the path and the asking file")
    func missingIncludeAborts() throws {
        let dir = tempDir()
        let main = try write("main.sfz", in: dir, "#include \"Data/ghost.txt\"")
        #expect {
            _ = try SFZPreprocessor.preprocess(fileAt: main)
        } throws: { error in
            guard case SFZPreprocessorError.includeMissing(let path, let file) = error
            else { return false }
            return path == "Data/ghost.txt" && file.hasSuffix("main.sfz")
        }
    }

    @Test("an #include cycle aborts, naming the cycle")
    func includeCycleAborts() throws {
        let dir = tempDir()
        try write("a.txt", in: dir, "#include \"b.txt\"")
        try write("b.txt", in: dir, "#include \"a.txt\"")
        let main = try write("main.sfz", in: dir, "#include \"a.txt\"")
        #expect {
            _ = try SFZPreprocessor.preprocess(fileAt: main)
        } throws: { error in
            guard case SFZPreprocessorError.includeCycle(let stack) = error
            else { return false }
            return stack.count >= 2 && stack.last!.hasSuffix("a.txt")
        }
    }

    @Test("include nesting beyond the depth cap (16) aborts")
    func includeDepthCapAborts() throws {
        let dir = tempDir()
        // main → d1 → d2 → … → d17: the 17th nested include exceeds the cap.
        for i in 1...16 {
            try write("d\(i).txt", in: dir, "#include \"d\(i + 1).txt\"")
        }
        try write("d17.txt", in: dir, "<region> sample=deep.wav")
        let main = try write("main.sfz", in: dir, "#include \"d1.txt\"")
        #expect(throws: SFZPreprocessorError.self) {
            _ = try SFZPreprocessor.preprocess(fileAt: main)
        }
    }

    @Test("a commented-out #include never fires")
    func commentedIncludeIgnored() throws {
        let dir = tempDir()
        let main = try write("main.sfz", in: dir, """
        // #include "Data/ghost.txt"
        /* #include "Data/ghost2.txt" */
        <region> sample=a.wav
        """)
        let text = try SFZPreprocessor.preprocess(fileAt: main)
        let ir = SFZParser.parse(text: text, baseDirectory: dir)
        #expect(ir.regions.count == 1)
    }

    // MARK: - Mini-Salamander topology (the flagship gate)

    @Test("mini-Salamander: a wrapper with ZERO region opcodes + 2 #includes + #defines parses")
    func miniSalamanderTopology() throws {
        let dir = tempDir()
        // The real Salamander V3.sfz holds no region opcodes at all — pure
        // include/define scaffolding (RES §1.5). This fixture mirrors that
        // exact topology: defines in one included file, regions (built from
        // those macros) in another.
        try write("Data/defines.txt", in: dir, """
        #define $VEL v1
        #define $EXT wav
        #define $TUNE01 -3
        #define $TUNE02 4
        """)
        try write("Data/regions.txt", in: dir, """
        <group> ampeg_release=0.5
        <region> sample=$VEL/a0.$EXT lokey=21 hikey=22 pitch_keycenter=21 tune=$TUNE01
        <region> sample=$VEL/b0.$EXT lokey=23 hikey=24 pitch_keycenter=23 tune=$TUNE02
        """)
        let main = try write("wrapper.sfz", in: dir, """
        // mini-Salamander wrapper: no region opcodes live here
        <control> default_path=samples/
        #include "Data/defines.txt"
        #include "Data/regions.txt"
        """)
        let text = try SFZPreprocessor.preprocess(fileAt: main)
        let ir = SFZParser.parse(text: text, baseDirectory: dir)
        #expect(ir.regions.count == 2)
        #expect(ir.regions[0].samplePath == "v1/a0.wav")
        #expect(ir.regions[0].defaultPath == "samples/")
        #expect(ir.regions[0].tuneCents == -3)
        #expect(ir.regions[0].releaseSeconds == 0.5)   // inherited from <group>
        #expect(ir.regions[1].samplePath == "v1/b0.wav")
        #expect(ir.regions[1].tuneCents == 4)
        #expect(ir.regions[0].groupIndex == 0)
        #expect(ir.regions[1].groupIndex == 0)
    }
}
