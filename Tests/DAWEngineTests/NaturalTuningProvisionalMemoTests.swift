import DAWCore
import Foundation
import Testing

@testable import DAWEngine

/// Natural tuning §1 × p2-ren Stage B, lane NT-PK: **A VOICE-ONLY EDIT NEVER
/// REPLAYS A STALE PROVISIONAL PATCH.**
///
/// `ProvisionalRender.splice` memoises each cluster's patch under a key of
/// everything the patch reads (`PatchMemo`). Before NT-PK that key hashed the
/// new render's TRANSPOSE per chunk and its level mask, and not the formant
/// shift and base an ENGAGED render hands the stretcher beside the transpose
/// (`RenderDiff.formant`). A Voice edit keeps every transpose, so a re-edit of
/// the same note (a drag of the Voice offset, a second amount) got the key of
/// the previous edit's patch and played ITS voice until the final committed.
///
/// The extent was never the problem: `RenderDiff.extent` already compares the
/// formant tuple when both sides are engaged (NT-E1, `NaturalTuningRenderDiffTests`
/// G10), so a Voice-only edit has a cluster; the MEMO then served it stale.
/// Every leg here is a TWO-edit sequence from one base, because a single edit
/// on an empty memo renders its patch either way.
///
/// Deliberately NOT `@MainActor` (the cap): pure builds on temp files.
@Suite("Natural tuning §1 — a voice-only edit never replays a stale provisional patch (NT-PK)")
struct NaturalTuningProvisionalMemoTests {
    typealias Params = StretchRenderCache.Params
    typealias Fixture = ProvisionalRenderTests
    static let sampleRate = 48_000.0

    /// A set on `notes` at correction `amount` (nil = legacy), clip at ratio
    /// 1, 0 st, formant flag off: `ProvisionalRenderTests.params` plus the
    /// amount.
    static func params(_ notes: [NoteSegment], amount: Double?,
                       _ edit: (inout [NoteSegment]) -> Void = { _ in }) -> Params {
        var segments = notes
        edit(&segments)
        return Params(ratio: 1, semitones: 0, formantPreserve: false,
                      pitchEdits: PitchEditSet(segments: segments, formantCorrection: amount))
    }

    /// One base and ONE memo, as `ProvisionalRenderStore` holds them: every
    /// warm build shares the memo; a cold build has none (the reference).
    struct Session {
        let source: URL
        let dir: URL
        let base: ProvisionalRender.Base
        let memo = ProvisionalRender.PatchMemo()

        func build(_ params: Params, _ name: String, warm: Bool = true) throws -> ProvisionalRender.Built {
            var job = Fixture.job(source: source, base: base, params: params, dir: dir, name: name)
            job.memo = warm ? memo : nil
            return try Fixture.built(ProvisionalRender.build(job, isCancelled: { false }))
        }
    }

    /// Note `index`'s source frames (ratio 1: its output frames).
    static func frames(of note: NoteSegment) -> Range<Int> {
        Int(note.startSeconds * sampleRate)..<Int(note.endSeconds * sampleRate)
    }

    /// The brief's three questions for a Voice-only re-edit, from ONE base:
    /// the memo is warmed by `a`, then `b` asks for the same notes' voice
    /// again with every transpose unchanged.
    ///  (a) does `b`'s extent mark the edited notes?
    ///  (b) is `b`'s patch RENDERED, or the memo's `a` patch reused?
    ///  (c) is the warm build the memo-less build's bytes?
    /// Returns the builds for callers that measure more.
    @discardableResult
    static func expectNoStaleReuse(label: String, voice: URL, notes: [NoteSegment], dir: URL,
                                   old: Params, a: Params, b: Params, edited: [Int]) throws
        -> (session: Session, builtA: ProvisionalRender.Built, warmB: ProvisionalRender.Built,
            coldB: ProvisionalRender.Built) {
        let frames = try StretchRenderCache.SpanSource.open(voice).frames
        // Premise: a VOICE-only edit. Every chunk's transpose is identical
        // (the base's, `a`'s and `b`'s), so only the formant term can tell
        // the three renders apart.
        #expect(try NaturalTuningRenderDiffTests.transposeOnlyDifferingChunks(frames, old: a, new: b) == 0,
                "premise (\(label)): a and b differ in a transpose, so this is not a Voice-only re-edit")
        #expect(try NaturalTuningRenderDiffTests.transposeOnlyDifferingChunks(frames, old: old, new: b) == 0,
                "premise (\(label)): the base and b differ in a transpose")
        let baseURL = try Fixture.finalRender(voice, old, dir: dir, name: "old")
        let session = Session(source: voice, dir: dir, base: Fixture.base(baseURL, old))
        let builtA = try session.build(a, "\(label)-a")
        #expect(builtA.kind == .spliced && builtA.renderedSpanFrames > 0 && builtA.reusedSpanFrames == 0,
                "premise (\(label)): the first edit did not render its patch into the memo")
        let warmB = try session.build(b, "\(label)-b-warm")
        let coldB = try session.build(b, "\(label)-b-cold", warm: false)
        print("NT-PK|\(label)| extent \(warmB.extent.pitchRanges) mask \(warmB.extent.maskRanges); A rendered \(builtA.renderedSpanFrames); B warm rendered \(warmB.renderedSpanFrames), reused \(warmB.reusedSpanFrames); B cold rendered \(coldB.renderedSpanFrames); memo keys \(session.memo.keysForTesting.map { String($0.prefix(12)) })")
        // (a) The extent marks every edited note, and nothing but the voice.
        #expect(warmB.kind == .spliced && warmB.extent.maskRanges.isEmpty, "(a) \(label): \(warmB.kind)")
        for index in edited {
            let note = Self.frames(of: notes[index])
            #expect(warmB.extent.pitchRanges.contains { $0.overlaps(note) },
                    "(a) \(label): the extent \(warmB.extent.pitchRanges) misses note \(index) \(note)")
        }
        // (b) Every cluster is a MISS: the memo's patch carries a's voice.
        #expect(warmB.renderedSpanFrames > 0 && warmB.renderedSpanFrames == coldB.renderedSpanFrames,
                "(b) \(label): the re-edit rendered \(warmB.renderedSpanFrames) of \(coldB.renderedSpanFrames) frames: the rest came from the memo")
        #expect(warmB.reusedSpanFrames == 0,
                "(b) \(label): \(warmB.reusedSpanFrames) frames of the PREVIOUS edit's patch were reused (a stale voice)")
        // (c) The memo changes no byte.
        #expect(try Fixture.bytes(warmB.url) == Fixture.bytes(coldB.url),
                "(c) \(label): the memoised build is not the memo-less build's bytes")
        // Control: the two edits are audibly different files, or (c) is vacuous.
        #expect(try Fixture.bytes(coldB.url) != Fixture.bytes(builtA.url),
                "control (\(label)): a and b built the same file, so the re-edit changed nothing")
        return (session, builtA, warmB, coldB)
    }

    // MARK: - The two Voice edits

    @Test("NT-PK (a)(b)(c): a Voice-OFFSET re-edit of one note (the memo holds +3 st, the edit asks +5 st) has an extent over that note, is a memo MISS, and writes the memo-less build's bytes")
    func voiceOffsetReEditIsAMiss() throws {
        let dir = try I1Signals.tempDir("ntpk-offset")
        defer { try? FileManager.default.removeItem(at: dir) }
        let voice = try Fixture.voiceFile(dir, seconds: 10)
        let notes = voice.notes
        func moved(_ s: inout [NoteSegment]) {
            s[0].pitchOffsetCents = 100
            s[2].pitchOffsetCents = 200
        }
        try Self.expectNoStaleReuse(
            label: "offset", voice: voice.url, notes: notes, dir: dir,
            old: Self.params(notes, amount: 1, moved),
            a: Self.params(notes, amount: 1) { moved(&$0); $0[2].formantOffsetSemitones = 3 },
            b: Self.params(notes, amount: 1) { moved(&$0); $0[2].formantOffsetSemitones = 5 },
            edited: [2])
    }

    @Test("NT-PK (a)(b)(c): an AMOUNT-only re-edit (base 1.0, the memo holds 0.25, the edit asks 0.5; never nil) marks both moved notes, is a memo MISS on both, and writes the memo-less build's bytes")
    func amountReEditIsAMiss() throws {
        let dir = try I1Signals.tempDir("ntpk-amount")
        defer { try? FileManager.default.removeItem(at: dir) }
        let voice = try Fixture.voiceFile(dir, seconds: 10)
        let notes = voice.notes
        func moved(_ s: inout [NoteSegment]) {
            s[0].pitchOffsetCents = 100
            s[2].pitchOffsetCents = 200
        }
        try Self.expectNoStaleReuse(
            label: "amount", voice: voice.url, notes: notes, dir: dir,
            old: Self.params(notes, amount: 1, moved),
            a: Self.params(notes, amount: 0.25, moved),
            b: Self.params(notes, amount: 0.5, moved),
            edited: [0, 2])
    }

    // MARK: - (c) on a voice with formants: the p2-ren G2 comparison, and the envelope

    /// The envelope meter's median shift of `y` against `reference` (cents)
    /// at `centres`, `NaturalTuningFormantRenderTests.envelopeShift`'s reading.
    static func envelope(_ reference: [Float], _ y: [Float], centres: [Int]) -> Double {
        NaturalTuningFormantRenderTests.envelopeShift(reference, y, centres: centres)
    }

    /// ⭐ **THE PHYSICS OF (c).** `SpanRenderSignals.voice` has flat 1/k
    /// harmonics, no formants to move; the known-answer source-filter voice
    /// has four. Six notes at 110 Hz, the first moved +100 c (so the base is
    /// a curve render), amount 1. The memo is warmed by note 3's Voice at
    /// +3 st, then the edit asks −3 st: a stale patch is 6 st off.
    ///  * G2 (`ProvisionalRenderTests.provisionalVersusFinalOnTheUsersTake`'s
    ///    gates, verbatim): over the extent, pitch |Δ| median ≤ 5 c, p95 ≤ 15 c
    ///    and LSD mean ≤ max(1 dB, 1.5 × the phase-carry floor: the final
    ///    against the final with an extra edit ≥ 2 s earlier);
    ///  * the envelope over note 3's middle reads the NEW final's within the
    ///    G-series floor of 50 c (the two renders share their f0, so the
    ///    f0-only control is 0 and the floor rules);
    ///  * the instrument's positive control: the +3 st patch the memo held
    ///    reads well over 4 × that floor from the new final.
    @Test("NT-PK (c) physics: on a voice with real formants, the re-edited note (memo +3 st, edit −3 st) passes the p2-ren G2 gates against the new final and its envelope reads the new final's; the memo's +3 st patch reads ≈ 6 st away (the instrument's positive control)")
    func provisionalCarriesTheNewVoice() throws {
        let dir = try I1Signals.tempDir("ntpk-physics")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f0 = 110.0
        let seconds = 6.0
        let url = dir.appendingPathComponent("voice.wav")
        try I1Signals.write([SourceFilterVoice.voice(f0Hz: f0, formantScaleCents: 0,
                                                     frames: Int(seconds * Self.sampleRate),
                                                     sampleRate: Self.sampleRate)],
                            sampleRate: Self.sampleRate, to: url)
        let notes = (0..<6).map {
            NoteSegment(startSeconds: Double($0) + 0.1, endSeconds: Double($0) + 0.9,
                        detectedHz: f0, detectedConfidence: 0.95)
        }
        func set(first cents: Double = 100, voice: Double) -> Params {
            Self.params(notes, amount: 1) {
                $0[0].pitchOffsetCents = cents
                $0[3].formantOffsetSemitones = voice
            }
        }
        let run = try Self.expectNoStaleReuse(label: "physics", voice: url, notes: notes, dir: dir,
                                              old: set(voice: 0), a: set(voice: 3), b: set(voice: -3),
                                              edited: [3])
        let y = try I1Signals.read(run.warmB.url).planar[0]
        let stale = try I1Signals.read(run.builtA.url).planar[0]
        let final = try I1Signals.read(Fixture.finalRender(url, set(voice: -3), dir: dir, name: "final")).planar[0]
        let floorFinal = try I1Signals.read(Fixture.finalRender(url, set(first: 150, voice: -3), dir: dir,
                                                                name: "floor")).planar[0]
        // G2, verbatim.
        let extent = (run.warmB.extent.pitchRanges.first { $0.overlaps(Self.frames(of: notes[3])) } ?? 0..<0)
            .clamped(to: 0..<y.count)
        #expect(extent.count > 24_000, "the extent over note 3 is \(extent)")
        func lsd(_ x: [Float]) -> Double {
            SpanRenderMetrics.compare(Array(final[extent]), Array(x[extent]), sampleRate: Self.sampleRate,
                                      minHz: 70, maxHz: 1_000).lsdMean
        }
        let floor = lsd(floorFinal)
        let limit = max(1, 1.5 * floor)
        let pitch = Fixture.pitchAgreement(final[extent], y[extent])
        let lsdFresh = lsd(y)
        let lsdStale = lsd(stale)
        // The envelope, at note 3's middle (clear of its 30 ms ramps).
        let centres = [3.3, 3.5, 3.7].map { Int($0 * Self.sampleRate) }
        let envFresh = Self.envelope(final, y, centres: centres)
        let envStale = Self.envelope(final, stale, centres: centres)
        let tolerance = 50.0
        print(String(format: "NT-PK|physics| extent %@: pitch med %.1f / p95 %.1f c (%d fr); LSD %.2f dB (floor %.2f, limit %.2f); the memo's +3 st patch: LSD %.2f dB %@ the limit; envelope vs the new final: provisional %.1f c, the memo's patch %.1f c (tolerance %.0f c)",
                     "\(extent)", pitch.median, pitch.p95, pitch.frames, lsdFresh, floor, limit, lsdStale,
                     lsdStale <= limit ? "PASSES" : "fails", envFresh, envStale, tolerance))
        #expect(pitch.median <= 5 && pitch.p95 <= 15 && pitch.frames > 0, "G2 pitch: \(pitch)")
        #expect(lsdFresh <= limit, "G2 LSD \(lsdFresh) dB > \(limit) dB")
        #expect(abs(envFresh) <= tolerance,
                "the provisional's voice on note 3 reads \(envFresh) c from the new final's")
        #expect(abs(envStale) > 4 * tolerance,
                "control: the memo's +3 st patch reads only \(envStale) c from the −3 st final, so the meter cannot see a stale voice")
    }

    // MARK: - Invariance: what must still be reused

    /// An ENGAGED set's memo still works: a level edit, and a pitch edit, on
    /// a note far from a Voice-edited one reuse that note's patch (its
    /// transposes, voice and mask over its window are unchanged), and the
    /// memoised build is the memo-less build's bytes.
    @Test("NT-PK invariance: on an ENGAGED set, a level edit and a pitch edit far from a Voice-edited note still REUSE its patch, byte-identical to a memo-less build")
    func engagedEditElsewhereStillReuses() throws {
        let dir = try I1Signals.tempDir("ntpk-reuse")
        defer { try? FileManager.default.removeItem(at: dir) }
        let voice = try Fixture.voiceFile(dir, seconds: 10)
        let notes = voice.notes
        func voiced(_ s: inout [NoteSegment]) {
            s[0].pitchOffsetCents = 100
            s[2].pitchOffsetCents = 200
            s[2].formantOffsetSemitones = 3
        }
        let old = Self.params(notes, amount: 1) {
            $0[0].pitchOffsetCents = 100
            $0[2].pitchOffsetCents = 200
        }
        let baseURL = try Fixture.finalRender(voice.url, old, dir: dir, name: "old")
        let session = Session(source: voice.url, dir: dir, base: Fixture.base(baseURL, old))
        let a = try session.build(Self.params(notes, amount: 1, voiced), "a")
        #expect(a.renderedSpanFrames > 0 && a.reusedSpanFrames == 0)
        let elsewhere: [(String, (inout [NoteSegment]) -> Void)] = [
            ("level −6 dB on note 8", { $0[8].amplitudeDb = -6 }),
            ("pitch −150 c on note 8", { $0[8].pitchOffsetCents = -150 }),
        ]
        for (label, edit) in elsewhere {
            let params = Self.params(notes, amount: 1) { voiced(&$0); edit(&$0) }
            let warm = try session.build(params, "warm-\(label.prefix(5))")
            let cold = try session.build(params, "cold-\(label.prefix(5))", warm: false)
            print("NT-PK|reuse| \(label): warm rendered \(warm.renderedSpanFrames), reused \(warm.reusedSpanFrames); cold rendered \(cold.renderedSpanFrames); spans \(warm.spanRanges); memo keys \(session.memo.keysForTesting.map { String($0.prefix(12)) })")
            #expect(warm.spanRanges.count == 2, "\(label): expected the Voice-edited note's cluster and note 8's: \(warm.spanRanges)")
            #expect(warm.reusedSpanFrames > 0, "\(label): the Voice-edited note's patch was not reused")
            #expect(warm.renderedSpanFrames > 0 && warm.renderedSpanFrames < cold.renderedSpanFrames,
                    "\(label): warm rendered \(warm.renderedSpanFrames) of \(cold.renderedSpanFrames)")
            #expect(try Fixture.bytes(warm.url) == Fixture.bytes(cold.url),
                    "\(label): the memoised build is not the memo-less build's bytes")
        }
    }

    /// ⭐ **THE LEGACY GOLDEN.** A set that does not engage the formant curve
    /// (amount nil, every offset 0: every set saved before natural tuning)
    /// keeps its memo keys BYTE-IDENTICAL to the keys p2-ren shipped:
    /// `patchMemoIsPure`'s A, B and C builds (a pitch edit; a second far
    /// away; a level edit inside the first, so both the "no mask" and the
    /// mask branch are pinned). CAPTURED 2026-09-25 on the tree BEFORE NT-PK's
    /// key change (recorded in docs/ROADMAP.md's NT-PK entry). An ENGAGED set's keys do change,
    /// by necessity: they now carry its voice.
    static let legacyGolden: [String] = [
        "57f886239112a05186165236e0faa21dd0f6b9d30d75c3249fee2bc666604f1d",
        "7c790d2f4f149df81cd89ab97e5d25c00106777ceef722a5e41c4a11d9dd68d1",
        "f5375e7c07732148af99304092d5aa3c36666b8fa1a67d87a408e10421cc0839",
    ]

    @Test("NT-PK invariance: a LEGACY set's patch-memo keys are byte-identical to the golden captured before the formant hash existed")
    func legacyMemoKeysAreTheGolden() throws {
        let dir = try I1Signals.tempDir("ntpk-golden")
        defer { try? FileManager.default.removeItem(at: dir) }
        let voice = try Fixture.voiceFile(dir, seconds: 10)
        let notes = voice.notes
        let old = Fixture.params(notes) { $0[0].pitchOffsetCents = 100 }
        #expect(old.pitchEdits?.engagesFormantCurve == false, "premise: the golden's set engages the formant curve")
        let baseURL = try Fixture.finalRender(voice.url, old, dir: dir, name: "old")
        let session = Session(source: voice.url, dir: dir, base: Fixture.base(baseURL, old))
        _ = try session.build(Fixture.params(notes) { $0[0].pitchOffsetCents = 100; $0[2].pitchOffsetCents = 200 }, "a")
        _ = try session.build(Fixture.params(notes) {
            $0[0].pitchOffsetCents = 100; $0[2].pitchOffsetCents = 200; $0[8].pitchOffsetCents = -150
        }, "b")
        _ = try session.build(Fixture.params(notes) {
            $0[0].pitchOffsetCents = 100; $0[2].pitchOffsetCents = 200; $0[2].amplitudeDb = -6
            $0[8].pitchOffsetCents = -150
        }, "c")
        let keys = session.memo.keysForTesting.sorted()
        print("NT-PK|golden| legacy keys \(keys)")
        #expect(keys.count == 3, "expected A's, B's new and C's cluster keys: \(keys)")
        #expect(keys == Self.legacyGolden, "a legacy set's memo keys moved")
    }
}
