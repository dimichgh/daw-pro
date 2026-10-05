import Foundation

// I1: HEAR THE NOTE WHILE EDITING IT. THIS FILE IS THE POLICY HALF.
//
// Design: `docs/design/2026-09-24-pitch-editor-interaction-batch.md` §4,
// decision (c), "hybrid, with no live DSP". The user's words: "when we move
// vocal segment, it should play it like we do notes or when we change its
// properties pull or compress or modify the curve".
//
// The engine holds MECHANISM only (`AudioEngineControlling.auditionClipSpan`):
// it can play one span of one clip, once, from the file playback plays.
// Everything about WHEN and WHICH lives here:
//  * a press plays the notes as they sound NOW;
//  * a commit that changes the sound waits for THAT clip's render to land (the
//    engine's render-complete signal, never the app's 10 Hz status poll), then
//    plays the edited notes once;
//  * the latest request wins, and a wait longer than 8 s is dropped;
//  * nothing plays while the transport runs or records, and a transport start
//    stops a sounding audition;
//  * the app's audition switch is an INPUT (`enabled:`), so the UI's doors can
//    honour it and the wire can ignore it.
//
// I1-F1 ("is it possible to just play segment and update segment when editing
// the note, maybe raw, not precise?", the user, 2026-09-25) adds SPAN RENDERS:
// the engine renders just the edited notes' span through the ONE render loop,
// off-thread, in tens of milliseconds, instead of waiting ~1.7 s for the whole
// take to re-render. So:
//  * a press on a clip whose render is in flight renders the span of the
//    STORED edits and plays that (no more silent "not ready");
//  * a release plays the span render of the COMMITTED edits at once;
//  * a drag plays the span render of the DRAFT edits on each snapped step
//    (latest wins), and a free (⌥) drag keeps one render in flight plus the
//    newest step waiting behind it;
//  * an engine without span renders (`.unsupported`) keeps every I1 behaviour
//    above, including the release's wait for the whole-file render.
//
// UI-free and engine-free (the engine is handed in per call), so all of it is
// headless-testable. That is the `AuditionController` shape, on purpose.
//
// ⛔ NO LIVE PITCH DSP ANYWHERE ON THIS PATH. Option (b) of §4 (shift the
// original through a live voice while dragging) is forbidden: the preview would
// be one shifter and the result another. What plays here is always the render
// playback itself will play.

/// The numbers I1's policy is made of. Three are PICKS (design §4: "All three
/// are PICKS"); each is named once, here, and read from here by the store, the
/// controller and the engine.
public enum ClipNoteAuditionPolicy {

    /// PICK 1 of 3: audio played on each side of the notes, in source seconds.
    /// Enough for the note's own attack and release to be heard in context.
    public static let contextSeconds: Double = 0.060

    /// PICK 2 of 3: the longest one audition PLAYS, in HEARD (output) seconds.
    /// A group of notes longer than this plays its first 6 s. I1-F2 (RT
    /// re-review): it used to count SOURCE seconds, so a clip slowed to ratio
    /// 4 played 24 s and a span render rendered all 24. The source span it
    /// covers at a clip's ratio comes from the engine's one output↔source
    /// mapping (`AudioEngineControlling.clipAuditionSourceSeconds`), handed to
    /// `span` as `maxSourceSeconds`; with no engine to ask, it counts source
    /// seconds as before.
    public static let maxSpanSeconds: Double = 6.0

    /// PICK 3 of 3: the fade at each end of the played span, so an audition cut
    /// out of the middle of a sung phrase never clicks. The engine applies it.
    public static let fadeSeconds: Double = 0.005

    /// How long a commit waits for its clip's render before the audition is
    /// dropped (design §4: "a wait over 8 s is dropped"). A render that lands
    /// later plays nothing, so a slow render cannot surprise the user long
    /// after they moved on.
    public static let renderWaitSeconds: Double = 8.0

    /// The context a CLEAR is heard with (design §4: "I7 with 0.3 s of
    /// context"): a cleared note is silence, so it is only audible against the
    /// singing around it.
    public static let clearContextSeconds: Double = 0.3

    /// The context a caller may ask for. Wider than any pick above, and small
    /// enough that the span cap stays the thing that bounds an audition.
    public static let contextSecondsRange: ClosedRange<Double> = 0...2

    /// The SOURCE-second span that plays `notes`: from the earliest start minus
    /// `contextSeconds` to the latest end plus `contextSeconds`, clipped to
    /// `window` (the part of the source file the clip actually plays, when the
    /// caller knows it) and to the file's start, then capped at
    /// `maxSourceSeconds` from its START (the span keeps its start and loses
    /// its end). `maxSourceSeconds` is the source span `maxSpanSeconds` of
    /// HEARD audio covers at the clip's ratio, which only the engine can say
    /// (`AudioEngineControlling.clipAuditionSourceSeconds`); its default,
    /// `maxSpanSeconds` itself, is the cap at ratio 1 and the behaviour before
    /// I1-F2. `nil` when nothing is left to play: no notes, a non-finite input,
    /// or notes wholly outside the window.
    public static func span(of notes: [NoteSegment], contextSeconds: Double,
                            within window: ClosedRange<Double>? = nil,
                            maxSourceSeconds: Double = maxSpanSeconds) -> ClosedRange<Double>? {
        guard !notes.isEmpty, contextSeconds.isFinite, contextSeconds >= 0 else { return nil }
        var start = notes.map(\.startSeconds).min() ?? 0
        var end = notes.map(\.endSeconds).max() ?? 0
        guard start.isFinite, end.isFinite else { return nil }
        start -= contextSeconds
        end += contextSeconds
        start = max(0, start)
        if let window {
            start = max(start, window.lowerBound)
            end = min(end, window.upperBound)
        }
        let cap = maxSourceSeconds.isFinite && maxSourceSeconds > 0 ? maxSourceSeconds : maxSpanSeconds
        end = min(end, start + cap)
        guard end > start else { return nil }
        return start...end
    }
}

/// What a committed note edit was. The controller decides from this alone
/// whether the commit changed the SOUND, so "a split triggers nothing" is a
/// rule with one home instead of something each door remembers.
public enum ClipNoteEdit: String, Sendable, CaseIterable {
    /// A note's pitch moved (C1's drag, I4's group drag).
    case pitch
    /// A note's level changed (U-D, `setClipNoteGain`).
    case level
    /// Notes were cleared or restored (I7a, `setClipNotesCleared`).
    case clear
    /// A note was cut in two (C3). Both halves keep every edit, so nothing
    /// audible changes, and nothing plays.
    case split

    /// Whether a commit of this kind changes what the clip sounds like.
    public var changesSound: Bool { self != .split }

    /// The context this kind of commit is heard with.
    public var contextSeconds: Double {
        self == .clear ? ClipNoteAuditionPolicy.clearContextSeconds
                       : ClipNoteAuditionPolicy.contextSeconds
    }
}

/// One audition request: the clip, and the SOURCE-second span to play.
public struct ClipNoteAuditionSpan: Sendable, Equatable {
    public var trackID: UUID
    public var clipID: UUID
    public var startSeconds: Double
    public var endSeconds: Double

    public init(trackID: UUID, clipID: UUID, startSeconds: Double, endSeconds: Double) {
        self.trackID = trackID
        self.clipID = clipID
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

/// What the controller did with one request.
public enum ClipNoteAuditionStatus: Sendable, Equatable {
    /// The request reached the engine, which answered this. `.sounded` means
    /// ACCEPTED: the engine has taken it and will start playing within
    /// milliseconds, unless the audio underneath cannot be read (RT
    /// re-review NH-C — this doc previously said "is playing", which
    /// `EngineProtocol.swift`'s own `.sounded`/`ClipSpanAuditionDelivery`
    /// docs already contradicted); every other outcome says why nothing
    /// will be heard.
    case attempted(AuditionOutcome)
    /// A commit whose render has not landed yet: the edited notes play once
    /// when that clip's render completes, within `renderWaitSeconds`.
    case waitingForRender
    /// The transport is running or recording, so nothing played. The transport
    /// plays the edit in context once its render lands; a second voice on top
    /// would double the vocal.
    case refusedTransportRunning
    /// The caller's audition switch is off, so nothing played.
    case disabled
    /// A commit that does not change the sound (a split): nothing played, and
    /// any audition already waiting keeps waiting.
    case unchanged
    /// I1-F1: a SPAN RENDER was asked for (a press while the clip's render is
    /// in flight, a release, a drag step), and the engine answered this.
    /// `.sounded` means ACCEPTED: the span renders off-thread and plays the
    /// moment it is ready; every other outcome says why nothing will be heard.
    case spanRender(AuditionOutcome)
    /// I1-F1: a free (⌥) drag step, held behind the span render in flight. It
    /// renders as soon as that one finishes, unless a newer step replaces it
    /// first (one render in flight plus the newest step waiting).
    case queued
}

/// How a release that WAITED for its clip's render stands, and how it ended
/// (m23-ap I1 UI hooks, "honest waiting"). Before this the 8 s expiry dropped a
/// release silently: measured on a 5-minute take, where the whole-file render
/// takes about 13 s, the edit was simply never heard and nothing said so.
///
/// Only an engine WITHOUT span renders waits at all (a fake, a headless run);
/// the live engine renders the committed span at once (I1-F1). The words stay
/// anyway: a door must never be silent. The pitch editor keeps the serial it
/// was answered with (`ClipNoteAuditionController.waitSerial`) and asks
/// `waitState(of:)` until the wait ends.
public enum ClipNoteAuditionWaitState: String, Sendable, Equatable, CaseIterable {
    /// Still waiting, inside `ClipNoteAuditionPolicy.renderWaitSeconds`.
    case waiting
    /// The render landed in time and the edited notes were played (the
    /// engine's answer is `lastRenderCompleteOutcome`).
    case played
    /// `renderWaitSeconds` passed first. Nothing will play for this edit.
    case expired
    /// Replaced before it could end: a newer audition, a drag step, a stop, a
    /// transport start, or the switch turned off.
    case cancelled
}

/// What the controller has been asked, counted (diagnostics only: the
/// `debug.pitchEditor` echo's staging evidence, never an input to a decision).
/// Each door counts its ENTRIES, refused ones included, so "the switch off
/// sent 0 requests" is read from `engineRequests`, not from a door count.
public struct ClipNoteAuditionCounts: Sendable, Equatable {
    /// `press` entries (the editor's press door and the wire's `clip.auditionNote`).
    public internal(set) var presses = 0
    /// `commitDidChange` entries for an edit that changes the sound (a split is
    /// not counted: it is not a release audition).
    public internal(set) var releases = 0
    /// `dragDidStep` entries.
    public internal(set) var dragSteps = 0
    /// `stop` entries (the editor's stop doors, the switch, panic, project
    /// boundaries, `stopAllAudition`, a transport stop).
    public internal(set) var stops = 0
    /// Requests this controller put to the engine: a play of the render or
    /// source file, or a span render (a queued step's dispatch included).
    public internal(set) var engineRequests = 0
    /// Release waits that EXPIRED (`ClipNoteAuditionWaitState.expired`).
    public internal(set) var droppedWaits = 0

    public init() {}
}

/// THE policy home for hearing a vocal note (I1). The pitch editor's press and
/// release doors and the wire's audition verb all run through it, so "one
/// command surface" holds for this feature too.
@MainActor
public final class ClipNoteAuditionController {

    /// The commit waiting for its clip's render, or nil.
    public private(set) var pending: ClipNoteAuditionSpan?
    private var pendingDeadline: ContinuousClock.Instant?

    /// The last outcome the engine gave a render-complete play (diagnostics).
    public private(set) var lastRenderCompleteOutcome: AuditionOutcome?

    /// I1-F1: how the last span render this controller asked for ENDED
    /// (`ClipSpanAuditionDelivery`: played, failed or dropped). Diagnostics,
    /// and what the tests read.
    public private(set) var lastSpanDelivery: ClipSpanAuditionDelivery?

    /// I1-F1: the span render in flight, by request token, or nil. Set only
    /// while the engine has accepted a span render and not yet reported how it
    /// ended; a report for any other token is a superseded request's, ignored.
    private var spanRenderInFlight: UInt64?
    private var spanRenderToken: UInt64 = 0
    /// I1-F1: the newest free-drag step waiting behind `spanRenderInFlight`.
    private var queuedDraft: (span: ClipNoteAuditionSpan, draft: PitchEditSet)?
    /// The engine the queued step renders on. Weak: the controller never keeps
    /// an engine alive.
    private weak var queuedEngine: (any AudioEngineControlling)?

    /// True while a free-drag step waits behind the render in flight.
    public var hasQueuedDraft: Bool { queuedDraft != nil }

    /// m23-ap I1 UI hooks ("honest waiting"): bumped each time a release starts
    /// WAITING for its clip's render. A caller keeps the serial it was answered
    /// with and asks `waitState(of:)`.
    public private(set) var waitSerial: UInt64 = 0
    /// How the wait numbered `waitSerial` ended; nil while it is still waiting
    /// or when none has.
    private var lastWaitEnd: ClipNoteAuditionWaitState?

    /// Door and engine counts. Diagnostics: see `ClipNoteAuditionCounts`.
    public private(set) var counts = ClipNoteAuditionCounts()

    /// When the span render in flight was accepted, and how long the last one
    /// took from its request to the engine's `.played` report (the voice has
    /// its buffer). Diagnostics: the staging look times a drag's first step
    /// with it. Read on the injectable `clock`.
    private var spanRenderInFlightSince: ContinuousClock.Instant?
    public private(set) var lastSpanLatency: Duration?

    /// ⚠️ DEBUG TIER ONLY — set by `debug.pitchEditor {act:"auditionSpanRender",
    /// enabled:false}`, never by the product, and false by default. While true,
    /// every span render answers `.unsupported` WITHOUT asking the engine, so
    /// this controller behaves exactly as it does on an engine without span
    /// renders: a release waits for the whole-file render (I1). That is the
    /// only way a staging look can put I1's wait, "Preparing your note…" and
    /// the 8 s expiry, on screen: on the live engine a span render always
    /// answers, and the wait path is otherwise unreachable.
    public var spanRendersDisabledForStaging = false

    /// Injectable so the 8 s expiry is testable without waiting 8 s (the
    /// `AuditionController.clock` idiom).
    var clock: () -> ContinuousClock.Instant = { ContinuousClock.now }

    public init() {}

    /// How the release wait numbered `serial` stands. ⚠️ It NOTICES an expiry
    /// on read (the wait is dropped there and then, and counted), so a render
    /// that never lands cannot leave a caller saying "Preparing your note…"
    /// forever. A serial older than the newest wait reads `.cancelled`: a newer
    /// wait replaced it.
    public func waitState(of serial: UInt64) -> ClipNoteAuditionWaitState {
        guard serial == waitSerial else { return .cancelled }
        if pending != nil {
            if isWaitingForRender { return .waiting }
            dropWait(ending: .expired)
            return .expired
        }
        return lastWaitEnd ?? .cancelled
    }

    /// True while a commit is waiting for its render and has not expired.
    public var isWaitingForRender: Bool {
        guard pending != nil, let pendingDeadline else { return false }
        return clock() <= pendingDeadline
    }

    /// PRESS: play `span` as it sounds NOW (the render if it is ready, the
    /// source file for a clip that does not render). Never waits. I1-F1: when
    /// the clip's render is still in flight, the span of the STORED edits is
    /// rendered on its own and played (`.spanRender`), which is what playback
    /// will play there once its render lands. An engine without span renders
    /// answers I1's `.attempted(.inaudibleNotReady)` and nothing plays.
    /// Replaces any audition waiting, rendering or sounding (latest wins).
    @discardableResult
    public func press(_ span: ClipNoteAuditionSpan, enabled: Bool, transportRunning: Bool,
                      engine: (any AudioEngineControlling)?) -> ClipNoteAuditionStatus {
        counts.presses += 1
        dropWait()
        dropDraftPreview()
        guard enabled else { return .disabled }
        guard !transportRunning else { return .refusedTransportRunning }
        guard let engine else { return .attempted(.unsupported) }
        let outcome = playFile(span, engine: engine)
        guard outcome == .inaudibleNotReady else { return .attempted(outcome) }
        let rendered = renderSpan(span, source: .storedSpanRender, engine: engine)
        return rendered == .unsupported ? .attempted(outcome) : .spanRender(rendered)
    }

    /// RELEASE: a commit of kind `edit` has ALREADY reached the store (and so
    /// the engine). If it changed the sound, the edited notes play once: from
    /// the render when it is already on disk (an undo back to a rendered
    /// state); otherwise (I1-F1) from a span render of the committed edits,
    /// started at once (`.spanRender`), without waiting for the whole-file
    /// render. Only an engine without span renders still waits for THAT clip's
    /// render to complete (`.waitingForRender`, I1).
    ///
    /// ⚠️ Call it after the commit, never before: the engine resolves the clip
    /// it has now, and before the commit that is the pre-edit clip.
    @discardableResult
    public func commitDidChange(_ edit: ClipNoteEdit, span: ClipNoteAuditionSpan,
                                enabled: Bool, transportRunning: Bool,
                                engine: (any AudioEngineControlling)?) -> ClipNoteAuditionStatus {
        // A split changes nothing audible and triggers nothing: it neither
        // plays nor cancels an audition already waiting for its render.
        guard edit.changesSound else { return .unchanged }
        counts.releases += 1
        dropWait()
        dropDraftPreview()
        guard enabled else { return .disabled }
        guard !transportRunning else { return .refusedTransportRunning }
        guard let engine else { return .attempted(.unsupported) }
        // The immediate attempt also silences the pre-edit sound (the engine
        // plays one audition at a time). A render already on disk plays now.
        let outcome = playFile(span, engine: engine)
        guard outcome == .inaudibleNotReady else { return .attempted(outcome) }
        // I1-F1: do not wait for the whole-file render (it keeps running for
        // playback). The commit is already in the store, so the STORED edits
        // are the committed ones: render their span now and play it.
        let rendered = renderSpan(span, source: .storedSpanRender, engine: engine)
        guard rendered == .unsupported else { return .spanRender(rendered) }
        // An engine without span renders: I1's wait for that clip's render.
        // Numbered, so the editor can ask how THIS wait ended (`waitState`).
        pending = span
        pendingDeadline = clock().advanced(by: .seconds(ClipNoteAuditionPolicy.renderWaitSeconds))
        waitSerial &+= 1
        lastWaitEnd = nil
        return .waitingForRender
    }

    /// DRAG (I1-F1): one step of a pitch drag still in flight. Renders `span`
    /// with `draft` in place of the clip's stored edits and plays it; nothing
    /// is committed. Call it when the draft's offset CHANGED, with
    /// `snapped: false` while ⌥ frees the drag from the semitone grid.
    ///
    /// * SNAPPED: latest wins. The engine cancels the render in flight (it
    ///   reports `.dropped` and its buffer never plays) and renders this one.
    /// * FREE: a pointer moves far faster than a render finishes, and "latest
    ///   wins" would then cancel every render before it could play, so the
    ///   user would hear nothing until they stopped moving. A free step
    ///   renders at once when nothing is in flight; otherwise it waits
    ///   (`.queued`), replacing any step already waiting, and renders the
    ///   moment the one in flight ends (one in flight plus the newest pending).
    ///
    /// A sounding step keeps sounding until the next step's buffer is ready,
    /// then gives way to it (the engine's replace-on-ready), so a drag has no
    /// gap between steps. Refused, as every door is, while the transport runs
    /// or records and when the switch is off; a drag cancels a release that is
    /// still waiting for its render.
    @discardableResult
    public func dragDidStep(_ span: ClipNoteAuditionSpan, draft: PitchEditSet, snapped: Bool,
                            enabled: Bool, transportRunning: Bool,
                            engine: (any AudioEngineControlling)?) -> ClipNoteAuditionStatus {
        counts.dragSteps += 1
        dropWait()
        guard enabled else { dropDraftPreview(); return .disabled }
        guard !transportRunning else { dropDraftPreview(); return .refusedTransportRunning }
        guard let engine else { dropDraftPreview(); return .attempted(.unsupported) }
        if !snapped, spanRenderInFlight != nil {
            queuedDraft = (span, draft)
            queuedEngine = engine
            return .queued
        }
        queuedDraft = nil
        queuedEngine = nil
        return .spanRender(renderSpan(span, source: .draftSpanRender(draft), engine: engine))
    }

    /// The engine says `clipID`'s render just committed. Plays the waiting
    /// commit if it is for THAT clip, is inside its 8 s, and the transport is
    /// stopped. A render for any other clip changes nothing.
    public func renderDidComplete(clipID: UUID, transportRunning: Bool,
                                  engine: (any AudioEngineControlling)?) {
        guard let span = pending, span.clipID == clipID else { return }
        // Too late: nothing plays, and the wait ENDS as expired, so the editor
        // can say so instead of going quiet ("honest waiting").
        guard isWaitingForRender else { dropWait(ending: .expired); return }
        guard !transportRunning, let engine else { dropWait(); return }
        let outcome = playFile(span, engine: engine)
        lastRenderCompleteOutcome = outcome
        // Still not ready means this render was not the one the edit needs
        // (the clip re-keyed again in between): keep waiting, inside the 8 s.
        guard outcome != .inaudibleNotReady else { return }
        dropWait(ending: .played)  // plays ONCE
    }

    /// A transport start: the waiting audition is dropped and a sounding one
    /// stops. The transport plays the edit in context.
    public func transportDidStart(engine: (any AudioEngineControlling)?) {
        dropWait()
        dropDraftPreview()
        engine?.stopClipSpanAudition()
    }

    /// Stop hearing it (the switch turned off, a panic, a project boundary).
    /// Drops a release waiting for its render and a drag step waiting behind
    /// a span render, and cancels a span render in flight.
    public func stop(engine: (any AudioEngineControlling)?) {
        counts.stops += 1
        dropWait()
        dropDraftPreview()
        engine?.stopClipSpanAudition()
    }

    /// Forget the release waiting for its render, recording how that wait
    /// ended (`ending`) when there was one: `.cancelled` for every supersede,
    /// stop and refusal; `.played` and `.expired` from `renderDidComplete` and
    /// `waitState(of:)`, which alone can tell.
    private func dropWait(ending: ClipNoteAuditionWaitState = .cancelled) {
        if pending != nil {
            lastWaitEnd = ending
            if ending == .expired { counts.droppedWaits += 1 }
        }
        pending = nil
        pendingDeadline = nil
    }

    /// Forget the span render in flight and any free-drag step waiting behind
    /// it. The engine side is cancelled by whatever request or stop follows.
    private func dropDraftPreview() {
        spanRenderInFlight = nil
        spanRenderInFlightSince = nil
        queuedDraft = nil
        queuedEngine = nil
    }

    /// Asks the engine for a span render and tracks it until it ends. The
    /// completion carries this request's token, so a report for a superseded
    /// request changes nothing.
    private func renderSpan(_ span: ClipNoteAuditionSpan, source: ClipSpanAuditionSource,
                            engine: any AudioEngineControlling) -> AuditionOutcome {
        // The debug tier's stand-in for an engine without span renders (see
        // `spanRendersDisabledForStaging`): the engine is not asked at all.
        guard !spanRendersDisabledForStaging else { return .unsupported }
        spanRenderToken &+= 1
        let token = spanRenderToken
        counts.engineRequests += 1
        let outcome = engine.auditionClipSpan(
            trackID: span.trackID, clipID: span.clipID,
            startSourceSeconds: span.startSeconds, endSourceSeconds: span.endSeconds,
            source: source) { [weak self] delivery in
                self?.spanRenderDidEnd(token: token, delivery: delivery)
            }
        spanRenderInFlight = outcome == .sounded ? token : nil
        spanRenderInFlightSince = outcome == .sounded ? clock() : nil
        return outcome
    }

    /// The engine's report for one span render. When it is the render in
    /// flight, the newest free-drag step waiting behind it renders now —
    /// unless the render was DROPPED by the engine itself.
    private func spanRenderDidEnd(token: UInt64, delivery: ClipSpanAuditionDelivery) {
        guard token == spanRenderInFlight else { return }
        spanRenderInFlight = nil
        lastSpanDelivery = delivery
        if case .played = delivery, let since = spanRenderInFlightSince {
            lastSpanLatency = clock() - since
        }
        spanRenderInFlightSince = nil
        // ⛔ RT re-review NH-D (`scratchpad/i1f1-rt-rereview.md` §4). A `.dropped`
        // for the render IN FLIGHT can only come from a stop this controller
        // never saw: every supersede and stop it starts clears the queue first
        // (press, commit, a snapped step, a transport start, `stop`). So it is
        // the engine's own — a graph rebuild, a recovery after a device change,
        // shutdown. The free-drag step waiting behind it dies WITH it and never
        // plays: dispatching it would sound a drag the user may have let go of,
        // and, on an engine that just stopped, restart the audio hardware
        // through `prepare()`. `clipNoteSpanEngineSideDropNeverPlaysTheQueue`
        // is the gate (planted and shown red).
        if case .dropped = delivery {
            queuedDraft = nil
            queuedEngine = nil
            return
        }
        guard let next = queuedDraft, let engine = queuedEngine else { return }
        queuedDraft = nil
        queuedEngine = nil
        _ = renderSpan(next.span, source: .draftSpanRender(next.draft), engine: engine)
    }

    /// Plays `span` from the file playback plays (the render, or the source of
    /// a clip that does not render). Counted: every engine request is.
    private func playFile(_ span: ClipNoteAuditionSpan,
                          engine: any AudioEngineControlling) -> AuditionOutcome {
        counts.engineRequests += 1
        return engine.auditionClipSpan(trackID: span.trackID, clipID: span.clipID,
                                       startSourceSeconds: span.startSeconds,
                                       endSourceSeconds: span.endSeconds)
    }
}
