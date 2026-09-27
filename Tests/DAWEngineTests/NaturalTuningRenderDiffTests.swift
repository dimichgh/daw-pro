import DAWCore
import Foundation
import Testing

@testable import DAWEngine

/// Natural tuning §1(d) items 1-4 and §1(g) G10, lane NT-E1: **RENDERDIFF
/// SEES THE FORMANT CURVE.** Without it a formant-only edit plans an EMPTY
/// extent (the transposes are identical chunk for chunk) and the provisional
/// splice would serve stale audio (design X6, risk 1(j)1).
///
/// ⚠️ The differential legs render through the plan and the curve loop
/// DIRECTLY, never `performRender`: the product render does not pass the
/// formant curve yet (`NaturalTuningFormantRenderTests.productRenderDoesNotEngageYet`),
/// so a differential against it would compare the extent with audio that
/// never engaged and pass for the wrong reason.
///
/// The consonant half of X6 (§2) is NT-E2's, later. Deliberately NOT `@MainActor`.
@Suite("Natural tuning §1 — RenderDiff compares the formant curve (NT-E1, G10)")
struct NaturalTuningRenderDiffTests {
    typealias Params = StretchRenderCache.Params
    static let sampleRate = 48_000.0

    static func params(_ notes: [NoteSegment], amount: Double?, formant: Bool = false,
                       _ edit: (inout [NoteSegment]) -> Void) -> Params {
        var segments = notes
        edit(&segments)
        return Params(ratio: 1, semitones: 0, formantPreserve: formant,
                      pitchEdits: PitchEditSet(segments: segments, retuneMs: 45,
                                               formantCorrection: amount))
    }

    static func extent(_ frames: Int, old: Params, new: Params) throws
        -> Result<RenderDiff.Extent, RenderDiff.Refusal> {
        try RenderDiff.extent(old: .init(params: old, curveContour: nil),
                              new: .init(params: new, curveContour: nil),
                              sourceFrames: frames, channels: 1, sampleRate: sampleRate)
    }

    /// The whole-file render a side's params produce WITH the formant curve,
    /// through the shipping shape (what `renderAudio` will do once it passes
    /// the curve). Curve path only: every side here moves a note.
    static func render(_ samples: [Float], _ params: Params) throws -> [Float] {
        let plan = try #require(StretchCurvePlan.make(
            editSet: params.pitchEdits, clipPitchShiftSemitones: params.semitones,
            sampleRate: sampleRate, ratio: params.ratio))
        return try OfflineStretcher.stretchTransposeCurve(
            input: [samples], sampleRate: sampleRate, ratio: params.ratio,
            semitonesAtOutputFrame: { plan.semitones(atOutputFrame: $0) },
            formantPreserve: params.formantPreserve,
            formant: plan.formantCurve(formantPreserve: params.formantPreserve),
            compensation: OfflineStretcher.curveLatencyCompensation(sampleRate: sampleRate))[0]
    }

    /// How many chunks' TRANSPOSES differ between two sides: what RenderDiff
    /// compared before §1(d). Zero on a formant-only edit, which is exactly
    /// why the pre-patch extent was empty (G10's documented negative control,
    /// executed rather than described).
    static func transposeOnlyDifferingChunks(_ frames: Int, old: Params, new: Params) throws -> Int {
        let schedule = try OfflineStretcher.curveSchedule(sourceFrames: frames, channels: 1,
                                                          sampleRate: sampleRate, ratio: 1)
        let interval = schedule.blockFrames
        let compensation = OfflineStretcher.curveLatencyCompensation(sampleRate: sampleRate)
        func side(_ p: Params) -> (RenderDiff.Side, StretchCurvePlan?, RenderDiff.Loop) {
            let s = RenderDiff.Side(params: p, curveContour: nil)
            let plan = RenderDiff.plan(for: s, sampleRate: sampleRate)
            return (s, plan, RenderDiff.loop(of: p, plan: plan))
        }
        let (a, ap, al) = side(old)
        let (b, bp, bl) = side(new)
        let chunks = (schedule.processOut + interval - 1) / interval
        return (0..<chunks).filter { chunk in
            RenderDiff.transpose(a, plan: ap, loop: al, chunk: chunk, interval: interval,
                                 compensation: compensation)
                != RenderDiff.transpose(b, plan: bp, loop: bl, chunk: chunk, interval: interval,
                                        compensation: compensation)
        }.count
    }

    static func firstDifference(_ a: [Float], _ b: [Float]) -> Int? {
        zip(a, b).enumerated().first { $0.element.0.bitPattern != $0.element.1.bitPattern }?.offset
    }

    // MARK: - Items 2 and 4: the refusals

    @Test("G10 item 2: a legacy set flipped to engaged (an amount, or an offset) refuses .formantCurveEngagement")
    func engagementFlipRefuses() throws {
        let voice = SpanRenderSignals.voice(seconds: 6, sampleRate: Self.sampleRate)
        let frames = voice.samples.count
        let legacy = Self.params(voice.notes, amount: nil) { $0[0].pitchOffsetCents = 50 }
        let amount = Self.params(voice.notes, amount: 1) { $0[0].pitchOffsetCents = 50 }
        let offset = Self.params(voice.notes, amount: nil) {
            $0[0].pitchOffsetCents = 50
            $0[3].formantOffsetSemitones = -2
        }
        // The flip's transposes are IDENTICAL chunk for chunk: the pre-§1
        // compare saw nothing (the reason item 2 exists).
        #expect(try Self.transposeOnlyDifferingChunks(frames, old: legacy, new: amount) == 0)
        #expect(try Self.extent(frames, old: legacy, new: amount) == .failure(.formantCurveEngagement))
        #expect(try Self.extent(frames, old: amount, new: legacy) == .failure(.formantCurveEngagement))
        #expect(try Self.extent(frames, old: legacy, new: offset) == .failure(.formantCurveEngagement))
        // Control: legacy against legacy still computes an extent.
        let legacyEdit = Self.params(voice.notes, amount: nil) {
            $0[0].pitchOffsetCents = 50
            $0[3].pitchOffsetCents = 200
        }
        #expect(try Self.extent(frames, old: legacy, new: legacyEdit).get().pitchRanges.count == 1)
    }

    @Test("G10 item 4: an engaged render against the source file refuses .formantAcrossLoops; a legacy one does not")
    func engagedAcrossLoopsRefuses() throws {
        let voice = SpanRenderSignals.voice(seconds: 4, sampleRate: Self.sampleRate)
        let frames = voice.samples.count
        let source = Params(ratio: 1, semitones: 0, formantPreserve: false)
        let engaged = Self.params(voice.notes, amount: 1) { $0[1].pitchOffsetCents = 100 }
        let legacy = Self.params(voice.notes, amount: nil) { $0[1].pitchOffsetCents = 100 }
        #expect(try Self.extent(frames, old: source, new: engaged) == .failure(.formantAcrossLoops))
        #expect(try Self.extent(frames, old: engaged, new: source) == .failure(.formantAcrossLoops))
        let across = try Self.extent(frames, old: source, new: legacy).get()
        #expect(!across.prefixExact && across.oldLoop == .sourceTimesMask)
    }

    // MARK: - Item 3: the tuple compare

    /// ⭐ **G10's headline.** A formant-only edit on one note (−2 st, no pitch
    /// move) between two ENGAGED sets: every chunk's transpose is identical
    /// (the executed negative control: the pre-patch compare was EMPTY here),
    /// and the extent is one run around that note, the same shape a pitch
    /// edit on it gets (the positive control, same pair of bounds).
    @Test("G10 a formant-only edit on one note yields a non-empty extent around that note; the transpose-only compare is EMPTY on it")
    func formantOnlyEditHasAnExtent() throws {
        let voice = SpanRenderSignals.voice(seconds: 6, sampleRate: Self.sampleRate)
        let frames = voice.samples.count
        let notes = voice.notes
        let old = Self.params(notes, amount: 1) { $0[0].pitchOffsetCents = 50 }
        let formantOnly = Self.params(notes, amount: 1) {
            $0[0].pitchOffsetCents = 50
            $0[3].formantOffsetSemitones = -2
        }
        let pitchOnly = Self.params(notes, amount: 1) {
            $0[0].pitchOffsetCents = 50
            $0[3].pitchOffsetCents = 200
        }
        #expect(try Self.transposeOnlyDifferingChunks(frames, old: old, new: formantOnly) == 0,
                "the negative control is not a formant-only edit")
        let noteStart = Int(notes[3].startSeconds * Self.sampleRate)
        let noteEnd = Int(notes[3].endSeconds * Self.sampleRate)
        for (label, new) in [("formant-only", formantOnly), ("pitch-only (control)", pitchOnly)] {
            let ext = try Self.extent(frames, old: old, new: new).get()
            print("NT-E1|G10| \(label): pitch ranges \(ext.pitchRanges), note \(noteStart)..<\(noteEnd)")
            #expect(ext.pitchRanges.count == 1 && ext.maskRanges.isEmpty && ext.prefixExact,
                    "\(label): \(ext.pitchRanges)")
            guard let range = ext.pitchRanges.first else { continue }
            #expect(range.lowerBound > noteStart - 9_600 && range.lowerBound < noteStart,
                    "\(label): the run does not start just before the note")
            #expect(range.upperBound > noteEnd - 9_600 && range.upperBound < noteEnd + 4_800,
                    "\(label): the run does not end around the note's end")
        }
    }

    /// An AMOUNT-only edit (c 1 → 0.5) changes F only where a note moved: two
    /// runs, around the two moved notes, and nothing at the four unmoved ones.
    /// A split of an unmoved note on an engaged set moves nothing: EMPTY (the
    /// halves carry the same f0, so the base does not move either).
    @Test("G10 an amount-only edit re-renders only the MOVED notes; a split on an engaged set is EMPTY")
    func amountEditIsLocalAndSplitIsEmpty() throws {
        let voice = SpanRenderSignals.voice(seconds: 6, sampleRate: Self.sampleRate)
        let frames = voice.samples.count
        let notes = voice.notes
        func moved(_ segs: inout [NoteSegment]) {
            segs[0].pitchOffsetCents = 50
            segs[3].pitchOffsetCents = 300
        }
        let full = Self.params(notes, amount: 1, moved)
        let half = Self.params(notes, amount: 0.5, moved)
        #expect(try Self.transposeOnlyDifferingChunks(frames, old: full, new: half) == 0)
        let ext = try Self.extent(frames, old: full, new: half).get()
        print("NT-E1|G10| amount 1 → 0.5: \(ext.pitchRanges)")
        #expect(ext.pitchRanges.count == 2, "expected one run per moved note: \(ext.pitchRanges)")
        for (index, range) in zip([0, 3], ext.pitchRanges) {
            let start = Int(notes[index].startSeconds * Self.sampleRate)
            let end = Int(notes[index].endSeconds * Self.sampleRate)
            #expect(range.lowerBound < max(1, start) && range.lowerBound > start - 9_600,
                    "note \(index): \(range) vs \(start)..<\(end)")
            #expect(range.upperBound > end - 9_600 && range.upperBound < end + 4_800)
        }
        let split = try Self.extent(frames, old: full, new: Self.params(notes, amount: 1) { segs in
            moved(&segs)
            let whole = segs[4]
            let middle = (whole.startSeconds + whole.endSeconds) / 2
            segs[4].endSeconds = middle
            segs.append(NoteSegment(startSeconds: middle, endSeconds: whole.endSeconds,
                                    detectedHz: whole.detectedHz,
                                    detectedConfidence: whole.detectedConfidence))
        }).get()
        #expect(split.isEmpty, "a split moved the transpose, the formant shift or the base: \(split.pitchRanges)")
    }

    /// ⭐ **THE DIFFERENTIAL.** For the formant-only and the amount-only edits,
    /// the two ENGAGED whole-file renders are bit-identical before the
    /// extent's first frame (the extent never starts late) and DO differ
    /// (the extent is not reporting a change that is not there).
    @Test("G10 differential: engaged renders are bit-identical before the extent's first frame, and differ after it")
    func extentPredictsTheEngagedRender() throws {
        let voice = SpanRenderSignals.voice(seconds: 5, sampleRate: Self.sampleRate)
        let frames = voice.samples.count
        let notes = voice.notes
        let old = Self.params(notes, amount: 1) {
            $0[2].pitchOffsetCents = 300
        }
        let cases: [(String, Params)] = [
            ("formant-only", Self.params(notes, amount: 1) {
                $0[2].pitchOffsetCents = 300
                $0[3].formantOffsetSemitones = -2
            }),
            ("amount-only", Self.params(notes, amount: 0.5) {
                $0[2].pitchOffsetCents = 300
            }),
        ]
        let a = try Self.render(voice.samples, old)
        for (label, new) in cases {
            let ext = try Self.extent(frames, old: old, new: new).get()
            let predicted = try #require(ext.firstDifferingFrame, "\(label): empty extent")
            let b = try Self.render(voice.samples, new)
            let actual = try #require(Self.firstDifference(a, b), "\(label): the renders are identical")
            print("NT-E1|G10| differential \(label): predicted first \(predicted), actual first \(actual), lag \(actual - predicted)")
            #expect(actual >= predicted,
                    "\(label): the render differs at \(actual), BEFORE the extent's first frame \(predicted)")
        }
    }
}

// MARK: - Natural tuning §2 (NT-E2): the consonant half of X6

/// Natural tuning §2 (m23-nt, lane NT-E2), X6: **RENDERDIFF SEES THE CONSONANT
/// MIX.** The mix blends each region frame with the source, and a toggle, a
/// sound dragged into the curve (R21) or anything else that moves a region
/// changes those frames with every transpose unchanged. Without the union the
/// extent of a toggle is EMPTY and the provisional serves the base (stale).
///
/// Every leg runs on NT-E2's phrase fixture (`NaturalTuningConsonantRenderTests`)
/// through the PRODUCT render body, which mixes. Deliberately NOT `@MainActor`.
@Suite("Natural tuning §2 — RenderDiff compares the consonant mix (NT-E2, X6)")
struct NaturalTuningConsonantRenderDiffTests {
    typealias Params = StretchRenderCache.Params
    typealias Phrase = NaturalTuningConsonantRenderTests
    typealias Fixture = ProvisionalRenderTests
    static let sampleRate = 48_000.0
    static var frames: Int { Phrase.phrase.count }

    static func extent(old: Params, new: Params, frames: Int = frames) throws -> RenderDiff.Extent {
        try RenderDiff.extent(old: .init(params: old, curveContour: nil),
                              new: .init(params: new, curveContour: nil),
                              sourceFrames: frames, channels: 1, sampleRate: sampleRate).get()
    }

    static func covers(_ ranges: [Range<Int>], _ range: Range<Int>) -> Bool {
        ranges.contains { $0.lowerBound <= range.lowerBound && $0.upperBound >= range.upperBound }
    }

    static func phraseFile(_ dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("phrase.wav")
        try I1Signals.write([Phrase.phrase], sampleRate: sampleRate, to: url)
        return url
    }

    @Test("X6 (a): a TOGGLE (flag off → on, same notes) differs in no transpose, yet its extent holds exactly the frames whose weight moved (every region), in pitchRanges and never maskRanges (which the provisional may rescale); the reverse toggle marks the same frames")
    func toggleMarksEveryRegion() throws {
        let off = Phrase.params(Phrase.set(consonants: false))
        let on = Phrase.params(Phrase.set(consonants: true))
        #expect(try NaturalTuningRenderDiffTests.transposeOnlyDifferingChunks(Self.frames, old: off, new: on) == 0,
                "premise: a toggle changes no transpose")
        let w = Phrase.weights(Phrase.set(consonants: true), count: Self.frames)
        let expected = Phrase.runs(Self.frames) { w[$0] < 1 }
        for (label, old, new) in [("on", off, on), ("off", on, off)] {
            let ext = try Self.extent(old: old, new: new)
            print("[measured] X6 toggle \(label): consonant \(ext.consonantRanges); pitch \(ext.pitchRanges); mask \(ext.maskRanges)")
            #expect(ext.consonantRanges == expected, "X6 toggle \(label): the marked frames are not the regions")
            #expect(ext.maskRanges.isEmpty)
            #expect(!ext.isEmpty, "X6 toggle \(label): the extent is empty, so the provisional would serve the base")
            #expect(expected.allSatisfy { Self.covers(ext.pitchRanges, $0) },
                    "X6 toggle \(label): a region is missing from pitchRanges (the splice's input)")
        }
    }

    @Test("X6 (b): flag on both sides, a moved note changes no weight (only its transpose marks it); a sound DRAGGED into the curve (R21) marks the region it wets")
    func weightsMoveOnlyWithRegions() throws {
        let before = Phrase.params(Phrase.set(consonants: true))
        let moved = Phrase.params(Phrase.set(consonants: true) { $0[0].pitchOffsetCents = 100 })
        let ext = try Self.extent(old: before, new: moved)
        #expect(ext.consonantRanges.isEmpty, "a pitch-only edit moved a weight: \(ext.consonantRanges)")
        #expect(!ext.pitchRanges.isEmpty)
        func withSound(_ cents: Double) -> Params {
            Phrase.params(Phrase.set(consonants: true) { notes in
                notes.append(NoteSegment(startSeconds: 2.62, endSeconds: 2.72, detectedHz: 110,
                                         detectedConfidence: 0.2, pitchOffsetCents: cents,
                                         origin: .unpitched))
            })
        }
        let dragged = try Self.extent(old: withSound(0), new: withSound(300))
        let sound = (Phrase.frame(2.62) + 1)..<(Phrase.frame(2.72) - 1)
        print("[measured] X6 R21 drag: consonant \(dragged.consonantRanges)")
        #expect(Self.covers(dragged.consonantRanges, sound), "the dragged sound's frames are not marked")
        #expect(Self.covers(dragged.pitchRanges, sound))
    }

    @Test("X6 (c): the FIRST edit of a new vocal (flag on) against its SOURCE marks no consonant frame (the source IS the dry signal) and stays a spliced provisional; the brief's literal per-side rule would mark every region")
    func firstEditAgainstTheSource() throws {
        let dir = try I1Signals.tempDir("nt-e2-first-edit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try Self.phraseFile(dir)
        let identity = Params(ratio: 1, semitones: 0, formantPreserve: false)
        let new = Phrase.params(Phrase.set(consonants: true) { $0[3].pitchOffsetCents = 0 })
        let ext = try Self.extent(old: identity, new: new)
        #expect(ext.oldLoop == .sourceTimesMask && ext.newLoop == .stretcher)
        #expect(ext.consonantRanges.isEmpty, "the first edit marked consonant frames against the source")
        let newSide = RenderDiff.Side(params: new, curveContour: nil)
        let literal = try RenderDiff.differingConsonantFrames(
            old: .init(params: identity, curveContour: nil), oldPlan: nil,
            new: newSide, newPlan: RenderDiff.plan(for: newSide, sampleRate: Self.sampleRate),
            outputFrames: Self.frames, sampleRate: Self.sampleRate, ratio: 1, isCancelled: { false })
        let built = try Fixture.built(ProvisionalRender.build(
            Fixture.job(source: url, base: Fixture.base(url, identity, isSource: true), params: new,
                        dir: dir, name: "first"),
            isCancelled: { false }))
        let literalFrames = literal.reduce(0) { $0 + $1.count }
        print("[measured] X6 first edit vs the source: \(built.kind), \(built.spanFrames) span frames; the literal rule would add \(literalFrames) frames in \(literal.count) ranges (the file is \(Self.frames))")
        #expect(built.kind == .spliced)
        #expect(literalFrames > Self.frames / 5, "premise: the literal rule marks the regions")
    }

    @Test("X6 (d): a toggle's provisional never serves a stale gap: on the phrase every region is dirty, so it is declined (the bridge plays until the final) or, if built, every dry frame is the source")
    func toggleProvisionalIsNotStale() throws {
        let dir = try I1Signals.tempDir("nt-e2-toggle")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try Self.phraseFile(dir)
        let off = Phrase.params(Phrase.set(consonants: false))
        let on = Phrase.params(Phrase.set(consonants: true))
        let baseURL = try Fixture.finalRender(url, off, dir: dir, name: "base-off")
        let outcome = try ProvisionalRender.build(
            Fixture.job(source: url, base: Fixture.base(baseURL, off), params: on, dir: dir, name: "toggle"),
            isCancelled: { false })
        switch outcome {
        case .declined(let reason):
            print("[measured] X6 toggle provisional: declined (\(reason))")
            #expect(reason.contains("cap"), "declined for another reason: \(reason)")
        case .built(let built):
            let y = try I1Signals.read(built.url).planar[0]
            let w = Phrase.weights(Phrase.set(consonants: true), count: Self.frames)
            let dry = Phrase.runs(Self.frames) { w[$0] == 0 }
            let stale = Phrase.mismatches(y, Phrase.phrase, in: dry)
            print("[measured] X6 toggle provisional: \(built.kind), \(stale) dry frames are not the source")
            #expect(stale == 0, "the provisional plays \(stale) stale (tuned) gap frames")
        }
    }

    /// The memo fixture: 8 s. A 0-3.0 s (110 Hz, +100 c on every side, so the
    /// base is a curve render), an 80 ms breath 3.0-3.08 s, D 3.08-3.9 s and E
    /// 3.9-8.0 s abutting it (one 147 Hz vowel). Retune 200 ms (Gentle), so
    /// D's ramp reaches back over the whole breath: the breath is the ONLY
    /// region, and it lies inside D's own changed chunks.
    static let memoAudio: [Float] = Phrase.vowel(110, seconds: 3.0) + Phrase.breath(seconds: 0.08, seed: 9)
        + Phrase.vowel(146.83, seconds: 4.92)

    static func memoParams(consonants: Bool, dMoved: Bool) -> Params {
        let notes = [
            NoteSegment(startSeconds: 0, endSeconds: 3.0, detectedHz: 110, detectedConfidence: 0.95,
                        pitchOffsetCents: 100),
            NoteSegment(startSeconds: 3.08, endSeconds: 3.9, detectedHz: 146.83, detectedConfidence: 0.95,
                        pitchOffsetCents: dMoved ? -200 : 0),
            NoteSegment(startSeconds: 3.9, endSeconds: 8.0, detectedHz: 146.83, detectedConfidence: 0.95),
        ]
        return Params(ratio: 1, semitones: 0, formantPreserve: false,
                      pitchEdits: PitchEditSet(segments: notes, retuneMs: 200,
                                               keepsConsonantsUntuned: consonants))
    }

    /// ⚠️ **THE PATCH MEMO HOLE, AND ITS KEY.** `ProvisionalRender.splice`
    /// keys each cluster's patch on the base, the cluster's bounds, the tuning
    /// and the new render's transposes, formant values and level mask. Here
    /// the toggle's only region lies inside the moved note's changed chunks,
    /// so the toggled edit has the SAME clusters as the edit before it. NT-PK's
    /// two-edit pattern, from one base.
    ///
    /// ⛔ **RED WITHOUT THE CONSONANT KEY, MEASURED (NT-E2, 2026-09-26):**
    /// before `memoKey` hashed `RenderDiff.consonantWeights` over the cluster,
    /// the warm build REUSED 89,415 frames of the previous edit's UNMIXED
    /// patch and its bytes differed from the memo-less build's: a user who
    /// toggled consonant protection heard the old, tuned gaps in the preview
    /// until the final landed. The key hashes the weights only when
    /// `RenderDiff.consonantRegions(newSide, plan:)` is non-empty, so every
    /// key of a render without the mix keeps its bytes
    /// (`NaturalTuningProvisionalMemoTests.legacyMemoKeysAreTheGolden`).
    /// Landed 2026-09-27 (W7-NTE2), with this test enabled; the plant that
    /// removes the key turns it RED.
    @Test("X6 (e) MEMO: a toggle whose only region lies inside the moved note's changed chunks keeps the cluster, and the patch memo must still MISS (the warm build is the memo-less build's bytes)")
    func toggleMemoIsAMiss() throws {
        let dir = try I1Signals.tempDir("nt-e2-memo")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("memo.wav")
        try I1Signals.write([Self.memoAudio], sampleRate: Self.sampleRate, to: url)
        let n = Self.memoAudio.count
        let old = Self.memoParams(consonants: false, dMoved: false)
        let a = Self.memoParams(consonants: false, dMoved: true)
        let b = Self.memoParams(consonants: true, dMoved: true)
        let extA = try Self.extent(old: old, new: a, frames: n)
        let extB = try Self.extent(old: old, new: b, frames: n)
        print("[measured] X6 memo premise: a pitch \(extA.pitchRanges); b pitch \(extB.pitchRanges), consonant \(extB.consonantRanges)")
        #expect(!extB.consonantRanges.isEmpty, "premise: the toggle marks the breath")
        #expect(extA.pitchRanges == extB.pitchRanges,
                "premise: the breath lies inside D's changed chunks, so the clusters are the same")
        let baseURL = try Fixture.finalRender(url, old, dir: dir, name: "base")
        let base = Fixture.base(baseURL, old)
        let memo = ProvisionalRender.PatchMemo()
        func build(_ params: Params, _ name: String, warm: Bool) throws -> ProvisionalRender.Built {
            var job = Fixture.job(source: url, base: base, params: params, dir: dir, name: name)
            job.memo = warm ? memo : nil
            return try Fixture.built(ProvisionalRender.build(job, isCancelled: { false }))
        }
        let builtA = try build(a, "a", warm: true)
        #expect(builtA.kind == .spliced && builtA.renderedSpanFrames > 0, "premise: a rendered its patch")
        let warmB = try build(b, "b-warm", warm: true)
        let coldB = try build(b, "b-cold", warm: false)
        print("[measured] X6 memo: b warm rendered \(warmB.renderedSpanFrames), reused \(warmB.reusedSpanFrames); b cold rendered \(coldB.renderedSpanFrames)")
        #expect(warmB.reusedSpanFrames == 0, "the toggle reused the UNMIXED patch of the edit before it")
        #expect(try Fixture.bytes(warmB.url) == Fixture.bytes(coldB.url),
                "the memoised build is not the memo-less build's bytes (a stale gap)")
    }

    /// ⭐ THE HISTORY CAVEAT, MEASURED (RenderDiff's step 3 comment): an
    /// earlier note's edit changes the phase wake over every later frame, so
    /// the final's later FADES differ from the base's (R1's ρ reads the wet
    /// side). The provisional keeps the base after its right seam.
    @Test("X6 HISTORY CAVEAT (bounded, not widened): after an earlier note's edit, the provisional's downstream fades differ from the final's no more than the downstream notes do, and every downstream region interior is the source in both")
    func historyCaveatIsBounded() throws {
        let dir = try I1Signals.tempDir("nt-e2-history")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try Self.phraseFile(dir)
        let old = Phrase.params(Phrase.set(consonants: true) { $0[3].pitchOffsetCents = 0 })
        let new = Phrase.params(Phrase.set(consonants: true) {
            $0[3].pitchOffsetCents = 0
            $0[0].pitchOffsetCents = 100
        })
        let baseURL = try Fixture.finalRender(url, old, dir: dir, name: "base")
        let built = try Fixture.built(ProvisionalRender.build(
            Fixture.job(source: url, base: Fixture.base(baseURL, old), params: new, dir: dir, name: "hist"),
            isCancelled: { false }))
        let finalURL = try Fixture.finalRender(url, new, dir: dir, name: "final")
        let y = try I1Signals.read(built.url).planar[0]
        let final = try I1Signals.read(finalURL).planar[0]
        let patchEnd = built.patchedFrames.map(\.upperBound).max() ?? 0
        let w = Phrase.weights(Phrase.set(consonants: true), count: Self.frames)
        let downstream = patchEnd..<Self.frames
        let fades = Phrase.runs(Self.frames) { w[$0] > 0 && w[$0] < 1 && downstream.contains($0) }
        let interiors = Phrase.runs(Self.frames) { w[$0] == 0 && downstream.contains($0) }
        let notes = [Phrase.frame(1.95)..<Phrase.frame(2.58), Phrase.frame(2.77)..<Phrase.frame(3.48)]
        func residual(_ ranges: [Range<Int>]) -> Double {
            var diff = 0.0, ref = 0.0
            for range in ranges {
                for i in range {
                    let d = Double(y[i]) - Double(final[i])
                    diff += d * d
                    ref += Double(final[i]) * Double(final[i])
                }
            }
            return diff > 0 ? 10 * log10(diff / max(ref, 1e-30)) : -.infinity
        }
        let fadeResidual = residual(fades), noteResidual = residual(notes)
        let interiorMismatch = Phrase.mismatches(y, final, in: interiors)
        print("[measured] X6 history caveat: patch ends at \(patchEnd) (\(String(format: "%.3f", Double(patchEnd) / Self.sampleRate)) s); downstream fades \(fades.count) at \(String(format: "%.1f", fadeResidual)) dB vs the final, downstream notes \(String(format: "%.1f", noteResidual)) dB; \(interiorMismatch) interior frames differ")
        #expect(built.kind == .spliced)
        #expect(patchEnd < Phrase.frame(1.95), "premise: the patch ends before C, so C, the breath and D are the base's")
        #expect(!fades.isEmpty && interiorMismatch == 0, "a downstream region interior is not the source in both")
        #expect(fadeResidual <= noteResidual, "the base's fades differ from the final's more than its notes do")
    }

    /// ⭐ **THE X6 SHORT-CIRCUIT, EXACT** (W7-NTE2, 2026-09-27).
    /// `differingConsonantFrames` returns `[]` without computing a weight when
    /// the two sides' region lists are the same bit for bit, the only per-side
    /// input the weights read (the range, the sample rate and the ratio reach
    /// it as one shared value each). Every leg checks the public result
    /// against the FULL comparison (`differingConsonantFrames(oldRegions:…)`,
    /// no short-circuit): a skipped edit is shown to have had nothing to mark,
    /// and a compared one to have been compared in full.
    ///
    /// ⚠️ A SPLIT TAKES IT, BY MEASUREMENT: the product's split
    /// (`ProjectStore.splitClipNoteSegment`) writes the SAME cut to the left
    /// half's end and the right half's start, a soft join (R15's bit-for-bit
    /// abut), so no region moves and no weight changes. The edit that does
    /// move a region's edge is a trim beside it.
    @Test("X6 SHORT-CIRCUIT: a pitch-only edit and a split keep the region list bit for bit and return [] without comparing (the full comparison agrees: []); a toggle, a trim beside a region and a ratio change alter it and are compared in full (the extent refuses the ratio change first); +0/−0 count as different; the region type stores exactly the four fields the check reads")
    func shortCircuitIsExact() throws {
        let sr = Self.sampleRate, n = Self.frames
        func regions(_ p: Params) -> [PitchConsonantRegion] {
            let side = RenderDiff.Side(params: p, curveContour: nil)
            return RenderDiff.consonantRegions(side, plan: RenderDiff.plan(for: side, sampleRate: sr))
        }
        func compare(_ old: Params, _ new: Params, ratio: Double = 1) throws
            -> (skipped: Bool, result: [Range<Int>], full: [Range<Int>]) {
            let oldSide = RenderDiff.Side(params: old, curveContour: nil)
            let newSide = RenderDiff.Side(params: new, curveContour: nil)
            let result = try RenderDiff.differingConsonantFrames(
                old: oldSide, oldPlan: RenderDiff.plan(for: oldSide, sampleRate: sr),
                new: newSide, newPlan: RenderDiff.plan(for: newSide, sampleRate: sr),
                outputFrames: n, sampleRate: sr, ratio: ratio, isCancelled: { false })
            let full = try RenderDiff.differingConsonantFrames(
                oldRegions: regions(old), newRegions: regions(new), outputFrames: n,
                sampleRate: sr, ratio: ratio, isCancelled: { false })
            return (RenderDiff.sameRegionBits(regions(old), regions(new)), result, full)
        }
        let base = Phrase.params(Phrase.set(consonants: true))
        // Edits that keep the regions: the short-circuit is taken, and exact.
        let pitchOnly = Phrase.params(Phrase.set(consonants: true) { $0[0].pitchOffsetCents = 100 })
        // The product's split of D (2.75-3.50 s) at 3.10 s: left.end = cut = right.start.
        let split = Phrase.params(Phrase.set(consonants: true) { notes in
            var left = notes[3]
            left.endSeconds = 3.10
            let right = NoteSegment(startSeconds: 3.10, endSeconds: notes[3].endSeconds, detectedHz: 110,
                                    detectedConfidence: 0.95, pitchOffsetCents: notes[3].pitchOffsetCents)
            notes.replaceSubrange(3...3, with: [left, right])
        })
        #expect(split.pitchEdits?.segments.count == 5, "premise: the split made two notes of D")
        for (label, new) in [("pitch-only edit", pitchOnly), ("split", split)] {
            let c = try compare(base, new)
            print("[measured] X6 short-circuit, \(label): skipped \(c.skipped), result \(c.result), full comparison \(c.full)")
            #expect(c.skipped, "\(label): the region list changed, so the short-circuit was not taken")
            #expect(c.result.isEmpty && c.full.isEmpty,
                    "\(label): the full comparison marks \(c.full), so skipping it is not exact")
        }
        // Edits that change the regions: compared in full.
        let toggle = Phrase.params(Phrase.set(consonants: false))
        // A trim beside a region: A ends 50 ms early, so the region after it starts at 0.95 s.
        let trim = Phrase.params(Phrase.set(consonants: true) { $0[0].endSeconds = 0.95 })
        // A ratio change: the stretched side runs no mix (§2b.5), so its list is empty.
        let stretched = Phrase.params(Phrase.set(consonants: true), ratio: 1.5)
        let changing: [(String, Params, Params, Double)] = [
            ("toggle", toggle, base, 1), ("trim beside a region", base, trim, 1),
            ("ratio change 1 → 1.5", base, stretched, 1.5),
        ]
        for (label, old, new, ratio) in changing {
            let c = try compare(old, new, ratio: ratio)
            print("[measured] X6 short-circuit, \(label): skipped \(c.skipped), \(c.result.count) ranges, \(c.result.reduce(0) { $0 + $1.count }) frames")
            #expect(!c.skipped, "\(label): the region list did not change")
            #expect(!c.full.isEmpty && c.result == c.full,
                    "\(label): not compared in full: \(c.result) against \(c.full)")
        }
        // Through the extent, a ratio change never reaches the union.
        let refused = try RenderDiff.extent(old: .init(params: base, curveContour: nil),
                                            new: .init(params: stretched, curveContour: nil),
                                            sourceFrames: n, channels: 1, sampleRate: sr)
        if case .failure(let refusal) = refused {
            #expect(refusal == .timeBase, "the ratio change was refused for \(refusal)")
        } else {
            Issue.record("a ratio change produced an extent")
        }
        // Bit for bit, not ==: +0 and −0 compare equal but are not the same bits.
        let plusZero = [PitchConsonantRegion(startSeconds: 0.0, endSeconds: 0.3, followsNote: false,
                                             precedesNote: true)]
        let minusZero = [PitchConsonantRegion(startSeconds: -0.0, endSeconds: 0.3, followsNote: false,
                                              precedesNote: true)]
        #expect(plusZero == minusZero, "premise: == calls +0 and −0 equal")
        #expect(!RenderDiff.sameRegionBits(plusZero, minusZero), "the check is not bit for bit")
        #expect(RenderDiff.sameRegionBits(plusZero, plusZero))
        let fields = Mirror(reflecting: plusZero[0]).children.compactMap(\.label)
        #expect(fields == ["startSeconds", "endSeconds", "followsNote", "precedesNote"],
                "PitchConsonantRegion stores \(fields): RenderDiff.sameRegionBits must compare every stored field, or the short-circuit stops being exact")
    }
}
