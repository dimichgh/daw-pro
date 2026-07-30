import Foundation

/// The ONE home for "which side of the fader did this insert's spectrum tap
/// measure" (m23-r4, design D3) — built on the `ArrangeDropSnap` model
/// (`ResolvedDropBeat`'s `fileprivate init` + static constants): the only
/// way to obtain one is `InsertSpectrumTapPoint.forInsert(trackID:)`, so no
/// other file can mint a diverging label and the wire string, the (future)
/// UI label, and this type can never drift apart.
///
/// THE MEASURED FACT (m23-r2b/r3, pinned in `InsertSpectrumCoverageTests`):
/// a STRIP insert (audio/bus/instrument track) is measured PRE-fader — the
/// strip sandwich is `sumMixer -> chainHost -> mixer`, so the strip's own
/// fader sits DOWNSTREAM of the chain walk and moving it does not move the
/// reading (measured delta < 0.5 dB across a 1.0 -> 0.5 fader move). A
/// MASTER insert is measured POST the MASTER fader instead — the master
/// sandwich is `mainMixerNode -> masterChainHost -> output`, with the master
/// fader implemented as `mainMixerNode.outputVolume`, UPSTREAM of the master
/// walk (measured delta ~6.0206 dB across the same fader move). The tap
/// point itself never moves — what differs is only where each chain's own
/// fader happens to sit relative to it.
public struct InsertSpectrumTapPoint: Sendable, Equatable {
    /// The wire value `fx.spectrum` carries verbatim in its `tapPoint` field.
    public let wireValue: String
    /// One-sentence teaching line — the text the MCP tool description quotes
    /// (and any future UI label would too), so the two can never drift apart.
    public let explanation: String

    fileprivate init(wireValue: String, explanation: String) {
        self.wireValue = wireValue
        self.explanation = explanation
    }

    public static let postInsertPreFader = InsertSpectrumTapPoint(
        wireValue: "postInsertPreFader",
        explanation: "Measured after this insert but BEFORE the track's own "
            + "fader — moving the track fader will not move this reading.")

    public static let postInsertPostFader = InsertSpectrumTapPoint(
        wireValue: "postInsertPostFader",
        explanation: "Measured after this insert and AFTER the master fader "
            + "— moving the master fader WILL move this reading.")

    /// THE ONLY WAY to obtain one: `trackID == nil` is the master chain
    /// (POST the master fader); any real track/bus is a strip (PRE its own
    /// fader) — the `AudioEngineControlling.insertAnalysis`/
    /// `setInsertAnalysisArmed` nil-means-master convention, verbatim.
    public static func forInsert(trackID: UUID?) -> InsertSpectrumTapPoint {
        trackID == nil ? .postInsertPostFader : .postInsertPreFader
    }
}
