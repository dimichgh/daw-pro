import Foundation
import Testing
import DAWCore
@testable import DAWAppKit

/// m25-c-2 — the Humanize and Quantize panels refuse a take-comp member BEFORE
/// the press, and say why.
///
/// The bug: `canApply` was blind to comp membership (Quantize had no `canApply`
/// at all), so Apply fired on a store-managed clip, `humanizeClipNotes` /
/// `quantizeClipNotes` threw `clipInTakeGroup`, a `try?` at the closure binding
/// site ate it, and the panel closed having changed nothing. Both models now ask
/// the store at `prepare` time through an injected provider.
///
/// **BOTH MODELS, EVERY ASSERTION.** Quantize shipped first and has the identical
/// shape; fixing one leaves the same bug one menu away.
///
/// ⚠️ **ANTI-VACUITY.** Every refusal row is paired with a row that flips exactly
/// ONE input. The pair that carries the weight is *MIDI + comp* (canApply false,
/// message present) against *audio + no comp* (canApply false, message ABSENT):
/// same verdict, different reason, so a test that could not tell them apart would
/// fail. The failure mode of this class of fix is warning on the ordinary case,
/// so the ordinary MIDI clip is pinned hardest of all.
@MainActor
@Suite("Humanize / Quantize — comp-member refusal before the press (m25-c-2)")
struct CompMemberApplyRefusalTests {

    // MARK: - Fixtures

    nonisolated static let compClip = UUID()
    nonisolated static let ordinaryClip = UUID()

    /// The store's real sentence for a comp member, built by the real error case
    /// rather than retyped — if `errorDescription` is ever reworded, these tests
    /// follow it instead of pinning a stale copy.
    private static var compRefusal: ProjectError {
        ProjectError.clipInTakeGroup("Chorus Comp", clipID: compClip)
    }

    private static var compMessage: String {
        compRefusal.errorDescription ?? "<no description>"
    }

    /// Records what each model did, and what it was ASKED about.
    @MainActor final class Harness {
        var humanized: [(clipID: UUID, timing: Double, velocity: Int)] = []
        var quantized: [(clipID: UUID, settings: QuantizeSettings)] = []
        /// Every clip id the refusal provider was consulted for, in order — the
        /// pin that `prepare` asks at all, and asks about the RIGHT clip.
        var asked: [UUID] = []

        /// Only `compClip` refuses. Any other id is an ordinary clip.
        func refusal(for clipID: UUID) -> ProjectError? {
            asked.append(clipID)
            return clipID == CompMemberApplyRefusalTests.compClip
                ? CompMemberApplyRefusalTests.compRefusal
                : nil
        }

        func makeHumanize() -> HumanizeModel {
            HumanizeModel(apply: { clipID, timing, velocity, _, _ in
                                    self.humanized.append((clipID, timing, velocity)) },
                          compRefusal: { self.refusal(for: $0) })
        }

        func makeQuantize() -> QuantizeModel {
            QuantizeModel(
                builtinGrooves: [],
                savedGrooves: { [] },
                apply: { self.quantized.append(($0, $1)) },
                extract: { clipID, name, grid, cycle in
                    _ = clipID
                    return GrooveTemplate(name: name, gridBeats: grid, cycleBeats: cycle,
                                          offsets: [0, 0])
                },
                compRefusal: { self.refusal(for: $0) })
        }
    }

    // MARK: - Humanize: the table

    /// Each row is a target the panel can be opened on. `expectMessage` is the
    /// discriminator: two rows refuse for two different reasons and the model must
    /// distinguish them, or the fix is "warn on everything".
    struct Row: Sendable {
        let label: String
        let clipID: UUID
        let isMIDI: Bool
        let zeroAmounts: Bool
        let expectCanApply: Bool
        let expectMessage: Bool
    }

    nonisolated static var rows: [Row] {
        [
            Row(label: "ordinary MIDI clip — THE REGRESSION THAT MATTERS",
                clipID: ordinaryClip, isMIDI: true, zeroAmounts: false,
                expectCanApply: true, expectMessage: false),
            Row(label: "comp member, MIDI",
                clipID: compClip, isMIDI: true, zeroAmounts: false,
                expectCanApply: false, expectMessage: true),
            // Exactly one input flipped from the row above: still not applicable,
            // and NO message — the audio branch of the panel explains itself.
            Row(label: "ordinary AUDIO clip",
                clipID: ordinaryClip, isMIDI: false, zeroAmounts: false,
                expectCanApply: false, expectMessage: false),
            // Both guards bite. Included to pin that it does not crash or blank
            // the message, NOT as evidence of which guard fired — the two rows
            // above are what prove that.
            Row(label: "comp member, AUDIO (both guards)",
                clipID: compClip, isMIDI: false, zeroAmounts: false,
                expectCanApply: false, expectMessage: true),
            Row(label: "ordinary MIDI clip, both amounts zero",
                clipID: ordinaryClip, isMIDI: true, zeroAmounts: true,
                expectCanApply: false, expectMessage: false),
            // The refusal outranks the no-op: raising a slider cannot help.
            Row(label: "comp member, both amounts zero",
                clipID: compClip, isMIDI: true, zeroAmounts: true,
                expectCanApply: false, expectMessage: true),
        ]
    }

    @Test("Humanize — canApply, the message, and whether Apply fires", arguments: rows)
    func humanizeTable(row: Row) {
        let harness = Harness()
        let model = harness.makeHumanize()
        model.timingBeats = row.zeroAmounts ? 0 : 0.02
        model.velocityRange = row.zeroAmounts ? 0 : 8
        model.prepare(clipID: row.clipID, clipName: "Part", isMIDI: row.isMIDI)

        #expect(model.canApply == row.expectCanApply, "canApply wrong for \(row.label)")
        #expect((model.refusalMessage != nil) == row.expectMessage,
                "refusalMessage wrong for \(row.label)")
        if row.expectMessage {
            #expect(model.refusalMessage == Self.compMessage,
                    "the message must be the STORE's sentence verbatim (\(row.label))")
        }

        let fired = model.apply()
        #expect(fired == row.expectCanApply, "apply() return wrong for \(row.label)")
        #expect(harness.humanized.count == (row.expectCanApply ? 1 : 0),
                "the store closure fired wrongly for \(row.label)")
    }

    @Test("Quantize — canApply, the message, and whether Apply fires", arguments: rows)
    func quantizeTable(row: Row) {
        let harness = Harness()
        let model = harness.makeQuantize()
        // Quantize has no amounts, so the two zero-amount rows collapse onto their
        // ordinary twins: it can apply whenever a MIDI target is not refused.
        let expectCanApply = row.isMIDI && row.clipID != Self.compClip
        model.prepare(clipID: row.clipID, clipName: "Part", isMIDI: row.isMIDI)

        #expect(model.canApply == expectCanApply, "canApply wrong for \(row.label)")
        #expect((model.refusalMessage != nil) == row.expectMessage,
                "refusalMessage wrong for \(row.label)")
        if row.expectMessage {
            #expect(model.refusalMessage == Self.compMessage,
                    "the message must be the STORE's sentence verbatim (\(row.label))")
        }

        let fired = model.apply()
        #expect(fired == expectCanApply, "apply() return wrong for \(row.label)")
        #expect(harness.quantized.count == (expectCanApply ? 1 : 0),
                "the store closure fired wrongly for \(row.label)")
    }

    // MARK: - The ordinary case is untouched

    @Test("an ordinary MIDI clip applies exactly as before — no message, real arguments through")
    func ordinaryClipUnaffected() {
        let harness = Harness()
        let humanize = harness.makeHumanize()
        humanize.timingBeats = 0.03
        humanize.velocityRange = 11
        humanize.prepare(clipID: Self.ordinaryClip, clipName: "Riff", isMIDI: true)
        #expect(humanize.canApply)
        #expect(humanize.refusalMessage == nil)
        #expect(humanize.targetRefusal == nil)
        #expect(humanize.apply())
        #expect(harness.humanized.count == 1)
        #expect(harness.humanized.first?.clipID == Self.ordinaryClip)
        #expect(harness.humanized.first?.timing == 0.03)
        #expect(harness.humanized.first?.velocity == 11)

        let quantize = harness.makeQuantize()
        quantize.prepare(clipID: Self.ordinaryClip, clipName: "Riff", isMIDI: true)
        #expect(quantize.canApply)
        #expect(quantize.refusalMessage == nil)
        #expect(quantize.apply())
        #expect(harness.quantized.count == 1)
        #expect(harness.quantized.first?.clipID == Self.ordinaryClip)
    }

    // MARK: - Staleness

    @Test("a refusal never outlives its clip — reopening on an ordinary clip clears it")
    func refusalIsNeverStale() {
        let harness = Harness()
        let humanize = harness.makeHumanize()
        let quantize = harness.makeQuantize()

        humanize.prepare(clipID: Self.compClip, clipName: "Take 1", isMIDI: true)
        quantize.prepare(clipID: Self.compClip, clipName: "Take 1", isMIDI: true)
        #expect(humanize.refusalMessage != nil)
        #expect(quantize.refusalMessage != nil)

        humanize.prepare(clipID: Self.ordinaryClip, clipName: "Riff", isMIDI: true)
        quantize.prepare(clipID: Self.ordinaryClip, clipName: "Riff", isMIDI: true)
        #expect(humanize.refusalMessage == nil)
        #expect(quantize.refusalMessage == nil)
        #expect(humanize.canApply)
        #expect(quantize.canApply)

        // And the provider was consulted on EVERY open, for the clip being opened
        // — not once at construction, not from a cache.
        #expect(harness.asked == [Self.compClip, Self.compClip,
                                  Self.ordinaryClip, Self.ordinaryClip])
    }

    // MARK: - The refusal bites where the store bites, and nowhere else

    @Test("a comp member can still have its groove EXTRACTED — the store allows that")
    func extractStaysAvailableOnACompMember() {
        let harness = Harness()
        let quantize = harness.makeQuantize()
        quantize.prepare(clipID: Self.compClip, clipName: "Take 1", isMIDI: true)
        #expect(!quantize.canApply)              // apply is refused …
        quantize.beginExtract()
        #expect(quantize.canExtract)             // … extract is not
        #expect(!quantize.extractName.isEmpty)
    }

    // MARK: - The default provider

    @Test("a model built without a refusal provider refuses nothing")
    func defaultProviderIsSilent() {
        let humanize = HumanizeModel(apply: { _, _, _, _, _ in })
        humanize.prepare(clipID: Self.compClip, clipName: "Take 1", isMIDI: true)
        #expect(humanize.refusalMessage == nil)
        #expect(humanize.canApply)
    }
}
