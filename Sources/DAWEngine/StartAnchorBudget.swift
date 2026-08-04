import Foundation

/// THE ONE HOME of the player-start anchor lead and of the continuation
/// horizon derived from it (m23-bs-2, design §13.4).
///
/// Pure, headless, stateless — no AVFoundation, no engine, no device. Every
/// start in the tree gets its lead from here, and `recoverEngine` gets its
/// prediction horizon from the SAME function, which is the whole point: a
/// continuation start must predict the instant its anchor will land, and it can
/// only do that if the prediction and the thing predicted are one expression.
///
/// ⚠️ NAMED `StartAnchorBudget`, NOT `ContinuationAnchorBudget` (§13.9 #2).
/// This file owns the lead used by EVERY start, not only continuations; a name
/// that said "continuation" would invite a second copy for the normal path,
/// which is the exact divergence the one-home rule exists to make
/// unrepresentable.
///
/// WHY THE LEAD EXISTS AT ALL (m19-f R2′ leg 2, design §3.4 — moved here from
/// `AudioEngine.startLeadSeconds` so the REASON lives with the formula):
/// players are started by a serial `play(at:)` loop costing 5.4–6.1 ms per
/// player (m18-c measured), and a `play(at:)` call that completes AFTER the
/// shared anchor starts that player SHIFTED-ORIGIN — probe-pinned 2026-07-16,
/// 5/5 runs: the player's timeline zero becomes the actual late start, so its
/// whole schedule runs late by (lateness + IO-quantum roundup), permanently,
/// silently off the grid for the rest of the roll. So the lead must cover a
/// render quantum plus the serial start loop plus scheduling jitter, and it
/// must scale with the number of players that loop will actually start.
/// 8 ms/player covers the measured cost plus variance.
enum StartAnchorBudget {

    /// The lead a start will use, and whether the cap had to bite.
    ///
    /// `wasCapped` exists so `AudioEngine.startPlayers` can keep its stderr cap
    /// warning WITHOUT re-evaluating the pre-cap expression — one computation,
    /// two consumers. A second evaluation would be a second home for the
    /// formula in all but name.
    struct Lead: Equatable {
        /// Post-cap seconds — the value the anchor is actually built from.
        let seconds: Double
        /// True when the raw expression exceeded `leadCapSeconds` and was
        /// clamped down to it.
        let wasCapped: Bool
    }

    /// Lead FLOOR: long enough to cover a render quantum + scheduling jitter,
    /// short enough to feel immediate. `n <= 5` sits here exactly, which is
    /// what keeps the small-project null case byte-identical to the pre-m19-f
    /// constant. The metronome enable-mid-play and reference re-anchors read
    /// this constant directly (they start ONE player, so the scaling term is
    /// irrelevant to them).
    static let leadFloorSeconds = 0.06

    /// Lead CEILING (m19-f R2′ leg 2): a 60+-active-player session gets a
    /// visible stderr line instead of a silent ~1 s pre-roll gap.
    static let leadCapSeconds = 0.5

    /// Seconds added to the predicted lead to cover a continuation start's
    /// SEGMENT B — everything between `startPlayers` entry and the instant it
    /// computes its anchor from: `scheduleAll`, the loop top-up,
    /// `prepareAllPlayers`, `countInPlan`.
    ///
    /// ⚠️ THE TWO NUMBERS THAT WOULD CHANGE THIS, so a future author raises it
    /// for a reason rather than by feel (design §13.4):
    ///
    ///  1. **m23-bs-1 measured segment B's worst at 20.2 ms** across 32 samples
    ///     (filtered AND full-suite, one-clip AND 32-clip projects; the median
    ///     was 0.7 ms and the 32-clip project read LOWER than the 1-clip one —
    ///     B does not scale with the project, its spread is OS preemption of a
    ///     synchronous main-actor block). 0.030 is that worst × 1.5.
    ///  2. **It also buys COUNT headroom.** The horizon's lead term is
    ///     forecast from the startable-player count read at recovery entry,
    ///     which is an upper bound on the resume count except at three named
    ///     paths (§13.3). Each UNFORESEEN player costs 8 ms of unpredicted
    ///     lead, so 30 ms absorbs THREE of them before the anchor overruns.
    ///
    /// If field overruns become common, THIS is the number to raise — never
    /// the accuracy it protects. An overrun is counted, printed, and degrades
    /// to exactly today's behaviour with a magnitude equal only to the
    /// prediction miss.
    static let scheduleAllowanceSeconds = 0.030

    /// The anchor lead for a start that will start `n` players.
    ///
    /// ⚠️ WRITTEN AS THE ORIGINAL EXPRESSION IN THE ORIGINAL ORDER — `max`
    /// first, then a STRICTLY-GREATER comparison against the cap — and NOT as
    /// the tidier `min(cap, max(floor, …))`. The tidy form silently changes the
    /// n = 60 edge: there the raw value is exactly `leadCapSeconds`, today's
    /// `>` leaves it uncapped and silent, and a `>=` (or a `min` paired with a
    /// `wasCapped = raw >= cap`) would emit a stderr warning today's code does
    /// not. `StartAnchorBudgetTests` pins `lead(60).wasCapped == false` for
    /// exactly this reason.
    static func lead(forStartablePlayerCount n: Int) -> Lead {
        let raw = max(leadFloorSeconds, 0.02 + Double(n) * 0.008)
        if raw > leadCapSeconds {
            return Lead(seconds: leadCapSeconds, wasCapped: true)
        }
        return Lead(seconds: raw, wasCapped: false)
    }

    /// How far in the FUTURE a continuation start must place its anchor, given
    /// the startable-player count observed before the recovery work began.
    ///
    /// A continuation (`recoverEngine`, and at m23-bs-3 the rewire/rebuild
    /// resumes) must commit its resume beat BEFORE `scheduleAll` runs, but the
    /// anchor only lands after `scheduleAll` + `prepareAllPlayers` + the lead.
    /// That is a genuine cycle — beat → schedule → player count → lead → anchor
    /// — and it is broken by predicting the instant instead of measuring it:
    /// the caller derives its beat FOR `now + continuationHorizonSeconds(n)`
    /// and hands `startPlayers` that same instant, so the beat committed to
    /// `scheduleAll` and the instant the anchor lands are two views of ONE
    /// chosen number.
    ///
    /// The forecast errs in the cheap direction by construction: over-predicting
    /// costs a slightly longer silent gap and playhead plateau with ZERO timing
    /// error (the beat was derived for the instant the anchor reached), while
    /// under-predicting clamps the anchor FORWARD and costs only the miss.
    static func continuationHorizonSeconds(forStartablePlayerCount n: Int) -> Double {
        lead(forStartablePlayerCount: n).seconds + scheduleAllowanceSeconds
    }
}
