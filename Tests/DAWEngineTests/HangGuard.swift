import Foundation

/// THE HANG GUARD (I1-F2 follow-up, 2026-09-25): how long a test waits for an
/// event that needs main-actor or cooperative-pool turns (a render landing, an
/// audition's completion, a status change) before it calls the event lost.
///
/// It is NOT a latency claim. A wait returns the moment its event happens, so
/// a generous guard costs nothing when the event comes; only a LOST event
/// waits this long. A latency a test claims is asserted on its own number,
/// measured where the latency happens (`ClipSpanRenderTests`' NH-A waiter
/// stamps its own give-up).
///
/// Why 120 s, MEASURED in the orchestrator's full suite of 2026-09-25 08:47
/// (9637 tests in 821 suites; one main thread for about 393 `@MainActor`
/// suites): the p2-ren Stage A veto test ran 88.3 s and failed only because
/// its 20 s guard on the injected render failure ran out (2.7 s in a filtered
/// run); "§3 another detector generation…" passed in 118.2 s; the I1-F2
/// contour-fallback test passed in 50.7 s (0.54 s filtered). The orchestrator
/// measured 96–165 s for the tests in this area in passing full runs. Guards
/// of 5–30 s sit inside what the full suite's queues can hold an event for.
///
/// The price is paid only on failure: a truly lost event costs this long for
/// every wait that asserts it.
enum HangGuard {
    static let seconds: Double = 120
}
