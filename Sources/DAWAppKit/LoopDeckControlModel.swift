import Foundation
import DAWCore

/// LIVE LOOPING, THE DOOR (m34-h-2) — which loop-deck controls are available
/// right now, and, when one is not, **the sentence that says why**.
///
/// ⛔⛔ **THIS EXISTS TO KILL DEAD PRESSES, WHICH IS THE ONE FAILURE MODE THE
/// LOOPING RESEARCH SINGLES OUT.** *"A press that visibly did nothing reads as
/// ignored and invites a second press."* The transport bar's house idiom is
/// `try? store.someVerb()` — which silently swallows every refusal
/// `ProjectStore+LoopDeck` writes, and those refusals are the *teaching* half of
/// the feature. The worst instance is real and adjacent: `beginLoopDeck` refuses
/// while `transport.isLoopEnabled`, and the transport **LOOP** chip — which is
/// take-comping, *the opposite feature* — sits in the same bar, eight points
/// away. A `try?` start button under that condition is a button that does
/// nothing, forever, with no explanation on screen.
///
/// ⚠️⚠️ **THIS TYPE PREDICTS THE STORE'S ANSWER; IT IS NOT THE STORE'S ANSWER.**
/// `ProjectStore` stays authoritative — every action still calls it and the
/// store still throws. The prediction exists only so a view can *disable and
/// explain* instead of *accept and discard*. That is exactly this tree's
/// characteristic failure shape (**the record says X, the source says Y, and
/// nothing compares them**), so `LoopDeckControlModelTests` compares them: the
/// agreement tests drive a real `ProjectStore` and assert that when this type
/// says `.blocked`, the store really throws, and when it says available, the
/// store really succeeds.
///
/// ⚠️ **GUARD ORDER IS COPIED FROM THE STORE ON PURPOSE AND MUST STAY COPIED.**
/// Which refusal a performer *sees* is decided by which guard fires first, so
/// `resolve` mirrors `beginLoopDeck` / `armLoopLayer` / `finishLoopLayer` /
/// `peelLoopLayer` / `endLoopDeck` in their own order. Reordering these is a
/// behaviour change even though every branch is still reachable.
///
/// No SwiftUI, no `@MainActor`: DAWAppKit is the "pure, testable view-model"
/// library precisely so a view's decisions can be tested without a window.
public struct LoopDeckControlModel: Equatable, Sendable {

    // MARK: - Length

    /// How the loop's length gets decided. ⭐ **THE DEFAULT IS `.bars(4)` AND
    /// THAT IS A PRODUCT DECISION, NOT AN API DEFAULT.**
    ///
    /// ⚠️⚠️ **THE STORE'S DEFAULT IS THE OPPOSITE OF THE PRODUCT'S, AND THAT IS
    /// THE EASIEST WRONG LINE IN THIS WHOLE ITEM.**
    /// `beginLoopDeck(bars: Int? = nil)` — and `nil` means **press-to-end**. So
    /// a start button that calls `beginLoopDeck()` bare ships the *advanced*
    /// mode to every beginner who presses the only door in Simple mode. This
    /// enum makes the choice explicit at every call site, and
    /// `barsParameter` is what gets handed to the store.
    public enum LengthChoice: Equatable, Sendable {
        /// Fixed bar count — the safe mode. The research's own wording: *you
        /// cannot pick a bad length because you never pick a length, only a bar
        /// count.*
        case bars(Int)
        /// Press-to-end: the first layer's FINISH press sets the length,
        /// rounded to the nearest whole bar. Offered, never defaulted to.
        case pressToEnd

        /// The value to pass as `beginLoopDeck(bars:)`. **`nil` ONLY for
        /// `.pressToEnd`** — pinned by test, because `nil` here is a silent
        /// mode switch rather than an error.
        public var barsParameter: Int? {
            switch self {
            case .bars(let n): return n
            case .pressToEnd: return nil
            }
        }

        /// Beginner-readable, and deliberately not a number alone: `4 BAR`
        /// reads as a length, `4` reads as an index.
        public var label: String {
            switch self {
            case .bars(let n): return "\(n) BAR"
            case .pressToEnd: return "FREE"
            }
        }
    }

    /// The product default. Fixed bars, four of them.
    public static let defaultLength = LengthChoice.bars(4)

    /// The store's own accepted range (`beginLoopDeck` throws outside 1...64),
    /// mirrored so the stepper cannot ask for a refusal.
    public static let barsRange = 1...64

    /// Clamp a stepper move into `barsRange`. A stepper that can reach a value
    /// the store rejects is a stepper that can produce a dead press.
    public static func clampedBars(_ bars: Int) -> Int {
        min(barsRange.upperBound, max(barsRange.lowerBound, bars))
    }

    // MARK: - Refusals

    /// Why a control is unavailable. A CASE, not a string, so a test can assert
    /// *which* refusal fires without matching prose.
    public enum Refusal: String, Equatable, Sendable, CaseIterable {
        /// `beginLoopDeck`: a session is already open.
        case sessionAlreadyOpen
        /// `beginLoopDeck`: the transport loop is on — the take-comping feature,
        /// which is the opposite of stacking layers.
        case transportLoopEnabled
        /// `beginLoopDeck` / `armLoopLayer`: a take is rolling.
        case takeRolling
        /// Everything except `begin`: no session is open.
        case noSession
        /// `armLoopLayer`: the deck joins playback that is already running.
        case notPlaying
        /// `armLoopLayer`: one pass at a time, exactly like every hardware looper.
        case layerAlreadyPending
        /// `armLoopLayer`: v1 records instrument layers only, and the project
        /// has none to offer.
        case noInstrumentTrack
        /// `finishLoopLayer`: nothing is armed or rolling.
        case noPendingLayer
        /// `finishLoopLayer`: the pass is already closing on its boundary.
        case alreadyClosing
        /// `peelLoopLayer`: the pass history is empty.
        case nothingToPeel

        /// The sentence shown on the control's tooltip. Beginner-readable
        /// (Rule 6) and it names the *fix*, not the internal state — a performer
        /// who reads "the transport loop is enabled" still does not know what to
        /// press next.
        public var explanation: String {
            switch self {
            case .sessionAlreadyOpen:
                return "A looper session is already open."
            case .transportLoopEnabled:
                return "Turn LOOP off first — that is the take-comping loop "
                    + "(several tries at one part). The looper stacks different parts instead."
            case .takeRolling:
                return "A recording is already rolling — stop it first."
            case .noSession:
                return "No looper session is open."
            case .notPlaying:
                return "Press play first — a layer joins music that is already running."
            case .layerAlreadyPending:
                return "A layer is already armed or recording — finish it first."
            case .noInstrumentTrack:
                return "Add an instrument track first — the looper records played "
                    + "notes, not microphone audio."
            case .noPendingLayer:
                return "Nothing is armed — arm a track to record the next layer."
            case .alreadyClosing:
                return "This layer is already ending on the next loop boundary."
            case .nothingToPeel:
                return "No layer to take back yet."
            }
        }
    }

    /// One control's availability plus the sentence its tooltip shows.
    public struct Command: Equatable, Sendable {
        public var isEnabled: Bool
        /// The first guard that would refuse, or nil when the control is live.
        public var refusal: Refusal?
        /// Tooltip text: what the control does when enabled, why it cannot when
        /// not. Never empty — a disabled control with no explanation is the
        /// dead press wearing a grey coat.
        public var help: String

        public init(isEnabled: Bool, refusal: Refusal?, help: String) {
            self.isEnabled = isEnabled
            self.refusal = refusal
            self.help = help
        }

        static func live(_ help: String) -> Command {
            Command(isEnabled: true, refusal: nil, help: help)
        }

        static func blocked(_ refusal: Refusal) -> Command {
            Command(isEnabled: false, refusal: refusal, help: refusal.explanation)
        }
    }

    /// One armable destination. Plain values so a preview can build a menu with
    /// no store at all.
    public struct TrackChoice: Equatable, Sendable, Identifiable {
        public var id: UUID
        public var name: String

        public init(id: UUID, name: String) {
            self.id = id
            self.name = name
        }
    }

    // MARK: - The resolved set

    public var start: Command
    public var arm: Command
    public var finish: Command
    public var peel: Command
    public var end: Command
    /// Instrument tracks only — `armLoopLayer` throws `trackKindUnsupported` on
    /// anything else, so an audio track in this menu would be an entry whose
    /// only outcome is a refusal.
    public var armTargets: [TrackChoice]
    /// The menu's `primaryAction` target: the arrange view's ACTIVE track when
    /// it is an instrument track, else the first instrument track. nil when
    /// there is nothing to arm.
    ///
    /// ⭐ The active track is the right primary because it is already the track
    /// Musical Typing plays into — one click arms *the thing you are playing*.
    public var primaryArmTarget: UUID?
    /// Mirrored from the status so a view has one place to read the pass phase.
    public var pendingPhase: LoopPendingLayer.Phase?

    public init(start: Command,
                arm: Command,
                finish: Command,
                peel: Command,
                end: Command,
                armTargets: [TrackChoice],
                primaryArmTarget: UUID?,
                pendingPhase: LoopPendingLayer.Phase?) {
        self.start = start
        self.arm = arm
        self.finish = finish
        self.peel = peel
        self.end = end
        self.armTargets = armTargets
        self.primaryArmTarget = primaryArmTarget
        self.pendingPhase = pendingPhase
    }

    // MARK: - Resolution

    /// Every input is a plain value, so this is callable from a preview, a test
    /// and the live bar with no difference.
    ///
    /// - Parameters:
    ///   - hasSession: `store.loopDeckStatus != nil`.
    ///   - pendingPhase: `status?.pendingPhase` — queued / recording / closing.
    ///   - canPeel: `status?.canPeel` — the pass history is non-empty.
    ///   - instrumentTracks: every `.instrument` track, in project order.
    ///   - activeTrackID: the arrange view's active track, if any.
    public static func resolve(hasSession: Bool,
                               isPlaying: Bool,
                               isRecording: Bool,
                               isTransportLoopEnabled: Bool,
                               pendingPhase: LoopPendingLayer.Phase?,
                               canPeel: Bool,
                               instrumentTracks: [TrackChoice],
                               activeTrackID: UUID?) -> LoopDeckControlModel {

        // --- START: mirrors `beginLoopDeck`'s guards, in its order.
        let start: Command
        if hasSession {
            start = .blocked(.sessionAlreadyOpen)
        } else if isRecording {
            start = .blocked(.takeRolling)
        } else if isTransportLoopEnabled {
            start = .blocked(.transportLoopEnabled)
        } else {
            start = .live("Start a looper session — stack layers over a repeating "
                          + "loop while the music keeps playing")
        }

        // --- ARM: mirrors `armLoopLayer`'s guards, in its order. The pending
        // check really does come before the isPlaying check in the store.
        let arm: Command
        if !hasSession {
            arm = .blocked(.noSession)
        } else if pendingPhase != nil {
            arm = .blocked(.layerAlreadyPending)
        } else if !isPlaying {
            arm = .blocked(.notPlaying)
        } else if isRecording {
            arm = .blocked(.takeRolling)
        } else if instrumentTracks.isEmpty {
            arm = .blocked(.noInstrumentTrack)
        } else {
            arm = .live("Arm the next layer — it starts recording on the next loop boundary")
        }

        // --- FINISH: mirrors `finishLoopLayer`. ⭐ A QUEUED pass is CANCELLED
        // rather than closed (the store unwinds the arm and returns without
        // throwing), so the same button means two different things and its
        // tooltip has to say which.
        let finish: Command
        if !hasSession {
            finish = .blocked(.noSession)
        } else {
            switch pendingPhase {
            case .none:
                finish = .blocked(.noPendingLayer)
            case .queued:
                finish = .live("Cancel the armed layer — it has not started recording yet")
            case .recording:
                finish = .live("Finish this layer at the end of the loop")
            case .closing:
                finish = .blocked(.alreadyClosing)
            }
        }

        // --- PEEL: mirrors `peelLoopLayer`.
        let peel: Command
        if !hasSession {
            peel = .blocked(.noSession)
        } else if !canPeel {
            peel = .blocked(.nothingToPeel)
        } else {
            peel = .live("Take back the last layer — the music keeps playing")
        }

        // --- END: mirrors `endLoopDeck`, whose only guard is the session.
        let end: Command = hasSession
            ? .live("End the looper session — the layers stay as ordinary clips")
            : .blocked(.noSession)

        let primary: UUID? = {
            if let activeTrackID, instrumentTracks.contains(where: { $0.id == activeTrackID }) {
                return activeTrackID
            }
            return instrumentTracks.first?.id
        }()

        return LoopDeckControlModel(start: start,
                                    arm: arm,
                                    finish: finish,
                                    peel: peel,
                                    end: end,
                                    armTargets: instrumentTracks,
                                    primaryArmTarget: primary,
                                    pendingPhase: pendingPhase)
    }
}

/// The ONE phase every animated value on the loop-deck surface derives from —
/// `LoopDeckStrip`'s lamps and chrome and `LoopDeckControls`' ARM button all
/// read this, so they blink together rather than nearly together.
///
/// ⚠️⚠️ **THE BAR FALLBACK IS NOT A NICETY; WITHOUT IT THE INDICATOR FREEZES IN
/// THE ONE MODE THAT NEEDS IT MOST (m34-h-2).** `ProjectStore.loopDeckStatus`
/// pins `cyclePhase` to `0.0` whenever `cycleBeats == nil` — which is exactly
/// press-to-end mode before the first layer has decided the length. A
/// cycle-only derivation therefore leaves `onBeat` permanently TRUE there: the
/// queued lamp sits at a static half-bright amber instead of flashing, in the
/// mode where the performer is waiting on a bar boundary they cannot otherwise
/// see, and where the wait is longest. So when there is no cycle yet, the phase
/// comes from the BAR the launch is actually quantized to — which is the same
/// degradation `LoopDeck.launchGrid` already makes, for the same reason.
///
/// Lives in DAWAppKit rather than beside the view so the freeze and its fix are
/// testable without a window.
public struct LoopDeckPulse: Equatable, Sendable {
    /// 0..<1 through the cycle, or through the bar when no cycle exists yet.
    public let phase: Double

    public init(status: LoopDeckStatus?, playheadBeat: Double) {
        guard let status else { self.phase = 0; return }
        if status.cycleBeats != nil {
            self.phase = status.cyclePhase
        } else if status.beatsPerBar > 0 {
            let raw = (playheadBeat / status.beatsPerBar).truncatingRemainder(dividingBy: 1)
            self.phase = raw < 0 ? raw + 1 : raw
        } else {
            self.phase = 0
        }
    }

    /// A square wave on the phase's halves. The queued flash: fast enough to
    /// read as "waiting", locked to the music so it reads as a count.
    public var onBeat: Bool { phase.truncatingRemainder(dividingBy: 0.5) < 0.25 }
}
