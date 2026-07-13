import Foundation
import ObjCExceptionGuard

/// Runs `body` under an Objective-C `@try/@catch` barrier (m16-a Leg 1,
/// docs/research/design-m16a-canvas-crash.md §4): a caught `NSException`
/// converts to `EngineError.engineException(name:reason:context:)` — an
/// ordinary thrown Swift error the wire's LocalizedError mapping surfaces as
/// a teaching message — instead of unwinding through the calling MainActor
/// job frame, which (proven live) leaks the runtime's executor-tracking TLS
/// record and either crashes the next SE-0423 dynamic actor-isolation check
/// on stack garbage or wedges the MainActor silently.
///
/// Swift errors thrown by `body` propagate unchanged; the happy path returns
/// `body`'s value with zero added cost (arm64 zero-cost EH). `context` is a
/// beginner-readable phrase naming the interrupted intent ("transport start",
/// "offline render", …) — it lands verbatim in the teaching error and the
/// `engine-exception` notice.
///
/// CONTROL-PLANE ONLY (C8): install this at `AudioEngine`'s main-actor entry
/// points, never anywhere the render thread executes — the render path gains
/// zero new surface.
///
/// Known, accepted tradeoff: Swift stack frames between the raise and the
/// barrier do not run cleanup (potential leak of in-flight locals) — a leak
/// is strictly better than a poisoned MainActor, and raises here are already
/// a hard failure of the underlying AVFAudio call.
func withObjCExceptionBarrier<T>(
    _ context: @autoclosure () -> String,
    _ body: () throws -> T
) throws -> T {
    var result: Result<T, any Error>?
    if let exception = DAWCatchObjCException({ result = Result { try body() } }) {
        throw EngineError.engineException(
            name: exception.name.rawValue,
            reason: exception.reason ?? "an unnamed condition",
            context: context()
        )
    }
    // No exception ⇒ the block ran to completion, so `result` is always set:
    // either body's value or the Swift error it threw (propagated unchanged).
    return try result!.get()
}
