import Foundation
import Observation
import DAWCore

/// Why a chop could not be started — the refusals the PANEL can answer without
/// asking the store. Everything the store refuses comes back as its own text and
/// is shown VERBATIM (see `lastRefusal`).
///
/// NAMED, never a bare nil — `MusicalTypingRefusal`'s rule: a panel that only
/// ever proved "the button was disabled" would pass identically against a button
/// that was ALWAYS disabled, which is how a dead feature ships green.
public enum PadChopRefusal: String, Equatable, Sendable, CaseIterable {
    /// Nothing is selected in the arrangement.
    case noClipSelected = "no-clip-selected"
    /// The selected clip holds MIDI notes, not a recording.
    case clipIsMIDI = "clip-is-midi"
    /// A chop is already running.
    case busy

    /// One beginner-readable sentence. ⚠️ It says what to DO, not what went
    /// wrong — Rule 6: a refusal a newcomer cannot act on is a refusal that
    /// needed rewriting.
    public var message: String {
        switch self {
        case .noClipSelected:
            return "Click an audio clip in the arrangement first — that recording "
                + "is what gets chopped onto the pads."
        case .clipIsMIDI:
            return "That clip holds notes, not a recording. Pick an audio clip — "
                + "a vocal, a drum loop, a sampled bar — and chop that."
        case .busy:
            return "Still chopping the last one."
        }
    }
}

/// What the chop panel is set to. Mirrors `SliceToSamplerSettings` and
/// deliberately does NOT re-declare its clamps: `settings(baseNote:)` builds the
/// real struct and lets its init do the clamping, so this table can never fork
/// the domain's bounds.
public struct PadChopSettings: Equatable, Sendable {
    public var mode: SliceBoundaryMode = .transients
    public var sensitivity: Double = 0.5
    public var divisions: Int = 16
    public var gridBeats: Double = 0.25
    public var maxSlices: Int = SliceToSamplerSettings.defaultMaxSlices
    public var baseNote: Int = SliceToSamplerSettings.defaultBaseNote
    public var includeHead: Bool = false
    /// ⚠️ **DEFAULT TRUE IN THE UI, DEFAULT FALSE ON THE WIRE — and the split is
    /// deliberate.** See `PadGridModel.muteSourceTrack`.
    public var muteSourceTrack: Bool = true

    public init() {}

    /// The domain settings this panel means. `generateMIDI` is always on: the
    /// reconstruction clip is the single most valuable thing a chop produces
    /// (it null-tests 28 dB under the source), and a user who does not want it
    /// can delete one clip.
    public func settings() -> SliceToSamplerSettings {
        SliceToSamplerSettings(
            mode: mode,
            sensitivity: sensitivity,
            divisions: mode == .divisions ? divisions : nil,
            gridBeats: mode == .grid ? gridBeats : nil,
            maxSlices: maxSlices,
            includeHead: includeHead,
            baseNote: baseNote,
            generateMIDI: true)
    }

    /// Beginner-readable name for the boundary mode — the picker's label, and
    /// the ONE home for these three strings.
    public static func modeLabel(_ mode: SliceBoundaryMode) -> String {
        switch mode {
        case .transients: return "Every hit"
        case .divisions: return "Equal pieces"
        case .grid: return "On the beat"
        }
    }

    /// One line saying what the mode actually does.
    public static func modeHelp(_ mode: SliceBoundaryMode) -> String {
        switch mode {
        case .transients:
            return "Listens for each attack and cuts there. Best on drums and anything percussive."
        case .divisions:
            return "Cuts the clip into the same number of equal pieces, however it sounds."
        case .grid:
            return "Cuts on the project's musical grid. Best on something already in time."
        }
    }

    /// The lead-in toggle's label — ONE home, read by the card's checkbox, the
    /// refusal vocabulary map and the lead-in notice, so a sentence that tells a
    /// person to tick it names the box they can actually see.
    public static let leadInLabel = "Keep the lead-in as pad 1"

    /// Does the lead-in toggle reach the chop in the chosen mode?
    ///
    /// ⚠️ READ OFF THE DOMAIN'S ONE HOME (`SliceToSamplerSettings
    /// .includeHeadIsEffective`), never a local `mode == .transients` — a
    /// second derivation that agrees today is how the card and the planner come
    /// to disagree tomorrow (DESIGN-LANGUAGE, "a setting that cannot reach the
    /// sound stays live, goes dim, and says so").
    public var leadInIsEffective: Bool { settings().includeHeadIsEffective }

    /// The line under a DIMMED lead-in toggle, in the card's own words (the
    /// mode chip, then the box's own label), or nil while the toggle is live.
    /// ≤ 51 characters — the one-line budget DESIGN-LANGUAGE measured on the
    /// narrower sampler card, kept here as a conservative bound (the chop card
    /// is wider). A 53-character first draft failed `PadGridTests` on it.
    public var leadInInertNote: String? {
        guard !leadInIsEffective else { return nil }
        return "\(Self.modeLabel(mode).uppercased()) always keeps the lead-in as pad 1."
    }

    /// The lead-in toggle's tooltip — the WHY, which costs no pixels.
    public var leadInHelp: String {
        if leadInIsEffective {
            return "Pad 1 normally starts at the first hit, like an MPC. Turn this on if the "
                + "chop is eating a downbeat."
        }
        return "Only “\(Self.modeLabel(.transients))” can leave the lead-in out — the quiet "
            + "bit before the first hit. “\(Self.modeLabel(mode))” cuts up the whole clip, so "
            + "pad 1 always starts at its very beginning."
    }
}

/// What the last successful chop produced — kept so the grid can say "slice 7 of
/// 53" and explain what just happened, WITHOUT re-reading the audio file.
public struct PadChopSummary: Equatable, Sendable {
    public var sliceCount: Int
    public var trackName: String
    public var createdTrack: Bool
    /// The track THIS CHOP muted, if any. Named so the notice can say which
    /// track undo will bring back.
    ///
    /// ⚠️ **CARRIED FROM `SliceToSamplerResult.mutedTrackId`, NEVER FROM THE
    /// REQUEST.** The store SKIPS the mute in two cases — the track was already
    /// muted, or it is the track the pads landed on — and a notice assembled
    /// from `chop.muteSourceTrack` would announce a mute that never happened.
    public var mutedTrackName: String?
    /// Will the original be heard under the pads? Read back out of the STORE
    /// after the edit (`sourceTrackMuted`), so it is a measurement rather than a
    /// restatement of the request.
    public var sourceStillAudible: Bool
    /// The store's warnings, VERBATIM — wire contract, written for an agent.
    public var warnings: [String]
    /// ⭐ The same warnings as a PERSON reads them in the notice — index-aligned
    /// with `warnings`. See `PadGridModel.chopWarningsForHumans`. Required, with
    /// no fallback to `warnings`: a default would be the leak this field closes.
    public var warningsForHumans: [String]

    public init(sliceCount: Int, trackName: String, createdTrack: Bool,
                mutedTrackName: String?, sourceStillAudible: Bool,
                warnings: [String], warningsForHumans: [String]) {
        self.sliceCount = sliceCount
        self.trackName = trackName
        self.createdTrack = createdTrack
        self.mutedTrackName = mutedTrackName
        self.sourceStillAudible = sourceStillAudible
        self.warnings = warnings
        self.warningsForHumans = warningsForHumans
    }
}

/// What a pad does when you LET GO — the two states the sampler can actually be
/// in, named by what the user hears rather than by the engine's flag.
///
/// ⭐⭐ **THIS IS ONE BOOLEAN THAT ALREADY EXISTED, SURFACED WHERE THE HAND IS.**
/// `SamplerParams.oneShot` has shipped for milestones, is settable over the wire
/// (`instrument.setSamplerParam`) and has a toggle on the SAMPLER EDITOR card.
/// None of that helped: a user chopping a vocal is looking at a pad grid, and
/// the grid never mentioned that a *click* — mouse down and up inside one
/// frame — is a complete gate cycle. `SliceToSampler` writes no `oneShot` on its
/// zones (measured 2026-09-20), so every chop inherits the global `false`, and
/// the default release is 0.05 s: **a tap on a two-second slice is a 50 ms
/// blip.** The material is there, the pad is loaded, the light flashes, and
/// almost nothing is heard.
///
/// ⚠️ **AND IT IS NOT A BUG IN THE GATE.** Holding the pad plays the slice and
/// letting go stops it, exactly as an MPC's NOTE ON mode does; what was missing
/// was its partner, ONE SHOT, and any way to see which one you were in.
///
/// ⚠️ **NAMED `triggerMode`, NOT `release`, ON PURPOSE.** `SamplerParams.release`
/// already exists and is the amp envelope's release TIME in seconds. A second
/// `release` meaning "what happens on note-off" would put two different things
/// one character apart in the same sampler's vocabulary. The hardware word is
/// used in the CODE; the UI says "LET GO: STOPS / PLAYS ON", which is the same
/// fact in words a newcomer already has.
public enum PadTriggerMode: String, Equatable, Sendable, CaseIterable {
    /// `oneShot == false` — the shipped default. Note-off releases the voice
    /// over `SamplerParams.release` (0.05 s unless changed).
    case gate
    /// `oneShot == true`. The engine drops the note-off on the floor
    /// (`SamplerInstrument`, the `oneShotState` branch) and the slice runs to
    /// its own end.
    case oneShot

    public init(oneShot: Bool) { self = oneShot ? .oneShot : .gate }

    /// The engine's flag. The ONE place this enum converts.
    public var isOneShot: Bool { self == .oneShot }

    /// ⚠️ Two words each, and they finish the question the row asks —
    /// "LET GO:" — so the chip completes a sentence rather than naming a mode
    /// the user has to already know. MPC calls these NOTE ON and ONE SHOT;
    /// that would be correct and would teach a newcomer nothing.
    public var label: String {
        switch self {
        case .gate: return "STOPS"
        case .oneShot: return "PLAYS ON"
        }
    }

    public var help: String {
        switch self {
        case .gate:
            return "Hold a pad to play, let go to cut it off. A quick click is a "
                + "quick sound — good for stutters and rolls."
        case .oneShot:
            return "A tap plays the whole slice through, however short the tap. "
                + "What a drum machine does, and what you want for one-hit chops. "
                // ⚠️ SAID OUT LOUD, because the surface cannot show it. The pad
                // light is driven by `soundingPitchSet`, which is the HAND's
                // ledger — it clears on pointer-up while the engine happily
                // plays the voice to its end. Rather than let the grid quietly
                // claim silence over audible sound, the mode that causes it
                // says so. (Making the light true needs a note-ended signal
                // back from the engine; filed, not faked.)
                + "The pad light follows your hand, so it goes dark while the "
                + "slice is still sounding."
        }
    }
}

/// The words for the two ways a Sixteen Levels spread can run (m39-levels-2) —
/// the ONE home for them, as `PadTriggerMode` is for LET GO's.
///
/// ⭐ **"UP" AND "CENTRED" ARE THE USER'S OWN WORDS** — the card they answered
/// offered *"a small up/centred toggle beside LEVELS."* A newcomer gets the rest
/// from the tooltip and, once a spread is up, from the pads themselves, which
/// then read "0", "+1"… or "-8"…"+7".
extension SixteenLevels.Direction {
    /// The chip. ⚠️ UK spelling ON SCREEN, US in code (`centered`) — the house
    /// split, as the phaser's `centerHz` reads "Centre" on its card.
    public var label: String {
        switch self {
        case .up: return "UP"
        case .centered: return "CENTRED"
        }
    }

    /// One or two sentences a person who is not a musician can act on.
    /// ⚠️ "Semitone" is glossed once as a piano key — the grid's other text
    /// already uses the word, and this is where it gets explained.
    public var help: String {
        switch self {
        case .up:
            return "Spread upward: pad 1 plays the slice exactly as recorded, and each pad "
                + "after it is one semitone (one piano key) higher, up to +15."
        case .centered:
            return "Spread both ways: pad 9 plays the slice exactly as recorded. The pads "
                + "before it play it lower, down to -8, and the pads after it play it "
                + "higher, up to +7."
        }
    }
}

/// THE PAD GRID's model (m39-pads) — "which square holds which slice, and what
/// happens when I hit it".
///
/// ## Shape
///
/// `SamplerEditorModel`'s shape verbatim, because it is the right one: the LIVE
/// facts arrive through injected closures read FRESH on every access, never from
/// a snapshot taken when the surface opened. A pad grid that cached its zones
/// would keep drawing a chop that an agent had already replaced over the wire —
/// this tree's characteristic failure, a light saying something no longer true.
///
/// ## ⛔ WHAT THIS OBJECT DELIBERATELY DOES NOT OWN
///
/// **The performance state.** `padBaseNote`, `padBank`, the velocity and the
/// sounding set all live on `MusicalTypingController`, and this model READS them
/// through the reference it holds. That is not indirection for its own sake: the
/// letter keys, the mouse and the sustain pedal already run through that one
/// controller and its one `LiveNoteSink`, whose `push()` is SET-SHAPED. A second
/// object pushing its own held set at the same sink would fight `releaseAll()`
/// for ownership of what is ringing — the exact hazard `holdsAnything`'s comment
/// was written to document. **One controller, one pusher, three faces.**
@MainActor
@Observable
public final class PadGridModel {

    // MARK: - Injected seams

    /// The LIVE sampler zones on the pad target — empty when the track is gone,
    /// is not an instrument track, or plays something other than the sampler.
    ///
    /// ⚠️ **EMPTY MEANS "NO PADS ARE LOADED", AND THAT IS SAFE HERE ONLY
    /// BECAUSE THIS MODEL NEVER WRITES ZONES.** `SamplerEditorModel`'s injector
    /// carries a loud warning that a nil reading turns into a wholesale write of
    /// an empty sampler. This one cannot: the pad grid reads zones and sounds
    /// notes, and every mutation it offers goes through `sliceClipToSampler`,
    /// which builds its own zones from the file. A grid drawn empty is a
    /// cosmetic wrong answer; an erased 300-zone library is not.
    /// ⚠️ **`var`, NOT `let`, AND ONLY SO `rebind` CAN EXIST.** The app's
    /// injectors resolve through `AppModel.activeTrackID`, which cannot be
    /// captured until every stored property of `AppModel` is initialised — and
    /// this model IS one of them. See `rebind`.
    private var zonesProvider: () -> [SamplerZone]
    /// The pad target's display name ("Vocal chops"), or nil when there is none.
    private var targetNameProvider: () -> String?
    /// Is the pad target's material AI-generated? Violet, always.
    private var targetIsAIProvider: () -> Bool
    /// The display name of a track named BY ID.
    ///
    /// ⛔⛔ **THE NOTICE MUST NAME THE TRACK THE PADS LANDED ON, AND
    /// `targetNameProvider` CANNOT ANSWER THAT.** Caught by LOOKING at a capture
    /// (m39-pads): the summary read the ACTIVE track's name, but the app only
    /// switches the active track AFTER `runChop` returns — so a chop that
    /// created "loop chops" from a clip on "Break" produced the sentence
    /// *"1 pad on “Break” (a new track)"* while the header two lines above it
    /// said "on loop chops". One screen, two answers, and the wrong one pointed
    /// the user at the track that had just been MUTED. Every test passed,
    /// because the harness's name provider is a constant.
    private var trackNameForIDProvider: (UUID) -> String?
    /// The clip the user has selected, as the chop panel needs to describe it.
    private var selectedClipProvider: () -> PadChopSource?
    /// The pad target's global `SamplerParams.oneShot`. **nil means "not a
    /// built-in sampler"** — a distinct third state from true/false, and the row
    /// draws disabled on it rather than picking a default and lighting a chip
    /// that claims a setting the track does not have.
    private var oneShotProvider: () -> Bool?
    /// Replaces the pad target's whole keymap. Returns the STORE's refusal or nil.
    ///
    /// ⚠️ WHOLESALE, because `setInstrument(id:sampler:)` is — see
    /// `setOneShotAction`. SIXTEEN LEVELS is the only caller, and it only ever
    /// hands over `existing + [spread]` or `existing − [spread]`.
    private var setZonesAction: ([SamplerZone]) -> String?
    /// Writes it, and returns the STORE's refusal or nil.
    ///
    /// ⚠️ **IT RETURNS AN ERROR BECAUSE THE WRITE CAN REALLY FAIL.** A sampler
    /// apply is wholesale — `setInstrument(id:sampler:)` re-validates every zone
    /// file — so a chop whose source moved on disk can refuse here. A toggle
    /// that flipped in the UI and silently did not take is this tree's
    /// characteristic failure wearing a switch.
    private var setOneShotAction: (Bool) -> String?
    /// Runs the chop. Wired to `ProjectStore.sliceClipToSampler` — the wire's own
    /// funnel, so the panel and `clip.sliceToSampler` cannot diverge.
    private var chopAction: (UUID, SliceToSamplerSettings, Bool) async throws -> SliceToSamplerResult
    /// Has `rebind` run? ⭐ **AN UNBOUND GRID IS A REAL, REACHABLE STATE AND IT
    /// LOOKS EXACTLY LIKE AN EMPTY KIT** — sixteen dim squares, `loadedCount`
    /// zero, every headless reading self-consistent. Recording the fact is what
    /// lets `PadGridSiteTests` prove the app actually binds it, instead of
    /// proving that an empty grid renders.
    public private(set) var isBound = false

    /// The live performance state, and the ONE pusher. See the type doc.
    public let typing: MusicalTypingController

    // MARK: - Panel state

    public var chop = PadChopSettings()
    // ⛔ THERE IS DELIBERATELY NO STORED `refusal` HERE (m39-pads). One existed,
    // was written by `runChop`, and was read by NOTHING: the card and the wire
    // both ask `blockingRefusal`, which RECOMPUTES from the live selection. A
    // stored copy is a second answer to "why can't I chop?" that goes stale the
    // instant the user clicks a different clip — this tree's characteristic
    // failure, a record nobody compares against the source. The panel's refusals
    // are DERIVED; only the STORE's sentence, which cannot be recomputed, is
    // kept (below).
    /// The last refusal the STORE decided, VERBATIM.
    ///
    /// ⭐⭐ **VERBATIM IS THE WHOLE POINT, AND IT IS MEASURED.** The chop
    /// REFUSES rather than truncating when a clip yields more boundaries than
    /// `maxSlices` (53 transients against a default cap of 32, measured on a
    /// real vocal), and `SliceToSamplerPlan.validateSliceCount` already writes a
    /// sentence that NAMES BOTH NUMBERS and lists four ways out. Re-wording that
    /// into "Chop failed" would throw away the only two numbers the user needs;
    /// a `PadGridModelTests` case pins that both survive into this property.
    public private(set) var lastRefusal: String?
    /// `lastRefusal` with the clip's UUID swapped for its NAME — what a PERSON
    /// reads.
    ///
    /// ⭐ **VERBATIM IS ABOUT THE NUMBERS, NOT ABOUT THE HEX.** `lastRefusal`
    /// stays byte-exact for the wire and for the test that pins both numbers
    /// through. But the store writes for an agent, so its sentence opens
    /// *"chopping clip 6017D54C-0E44-…-06E006C52A1B would make 15 pads"*, and a
    /// capture (m39-pads) showed that 36-character hex string sitting in a
    /// beginner's error message on a card that already says which clip it is.
    /// Rule 6: a refusal a newcomer cannot read is one that needed rewriting.
    /// Only the id is replaced — every number and every remedy survives.
    /// ⭐⭐ **THE UI VOCABULARY MAP — API SPELLING NEVER REACHES A PERSON.**
    /// The store's refusals are wire contract: agents read them, tests pin them
    /// byte-exact, and they are written in parameter names (`maxSlices`,
    /// `sensitivity`, `minSliceSeconds`, `includeHead`). A person reading this
    /// card sees sliders called "Most pads to make" and "How many hits to
    /// catch", so the raw sentence tells them to raise a control that does not
    /// exist on their screen.
    ///
    /// ⛔ **MEASURED ON A REAL USER, 2026-09-20.** They hit the pad ceiling and
    /// were told *"over the maxSlices limit of 9 — Raise maxSlices, lower
    /// sensitivity, raise minSliceSeconds"* while looking at a panel with none
    /// of those words on it. Every number and every remedy in the sentence was
    /// correct; the vocabulary was not theirs.
    ///
    /// ⚠️ **TRANSLATION HAPPENS HERE AND ONLY HERE.** Rewriting the store's
    /// string would change a wire contract to fix a presentation problem —
    /// which is how a UI fix breaks an agent. Keep this map in step with the
    /// panel's `sliderRow` / `checkRow` labels; a term added to a refusal
    /// without a row here simply passes through, which is the safe direction.
    private static let uiTerms: [(api: String, ui: String)] = [
        ("maxSlices", "“Most pads to make”"),
        ("sensitivity", "“How many hits to catch”"),
        ("minSliceSeconds", "the shortest-piece setting"),
        ("includeHead", "“\(PadChopSettings.leadInLabel)”"),
        ("baseNote", "“Pad 1 plays note”"),
    ]

    /// `uiTerms`, applied. The ONE loop both translations share.
    static func speakingUIVocabulary(_ text: String) -> String {
        var out = text
        for (api, ui) in uiTerms {
            out = out.replacingOccurrences(of: api, with: ui)
        }
        return out
    }

    public var lastRefusalForHumans: String? {
        guard let text = lastRefusal else { return nil }
        var out = text
        if let source = chopSource {
            out = out.replacingOccurrences(of: source.clipId.uuidString,
                                           with: "“\(source.clipName)”")
        }
        return Self.speakingUIVocabulary(out)
    }

    /// The chop's warnings in the words a PERSON reads in the pad grid's notice
    /// (m33-d) — index-aligned with `result.warnings`.
    ///
    /// ⭐⭐ **SAME FACT, TWO AUDIENCES (Rule 6), AND THE SPLIT IS FORCED.**
    /// ⛔ MEASURED 2026-09-24: the notice showed the store's sentence verbatim —
    /// *"…like an MPC or Recycle. Pass includeHead: true to keep it as pad 1 —
    /// worth doing if the detector missed the downbeat"* — to a person with no
    /// control called includeHead, who was never told where to click. That
    /// sentence is RIGHT for an agent (it names the parameter precisely), so it
    /// stays byte-exact in `warnings` and on the wire; this is the translation.
    ///
    /// ⭐ **WHY WHOLE-SENTENCE EQUALITY, NOT THE `uiTerms` PHRASE MAP.** Swapping
    /// the API token leaves "slice point", "onset", "Recycle" and "detector" in
    /// front of a newcomer and yields "Pass “Keep the lead-in as pad 1”: true".
    /// So the head warning is recognised WHOLE: the store builds it with
    /// `SliceToSamplerPlan.headDiscardedWarning(headSeconds:)`, and this rebuilds
    /// the same string from the result's OWN `headSeconds` — one builder, so a
    /// rewording moves both sides at once. A mismatch falls through to the
    /// vocabulary map, never to silence. ⛔ No wire field was added for this: a
    /// presentation problem does not get to change the wire contract.
    ///
    /// ⚠️ The OTHER plan warning ("snapWindowMs was reduced to…") gets no copy
    /// because this card cannot produce it: `PadChopSettings.settings()` sends
    /// the default 3 ms snap against the default 50 ms minimum slice, and the
    /// clamp only bites when the snap exceeds HALF the minimum. `PadGridTests`
    /// pins that arithmetic, so a card that grows either control fails a test
    /// and gets its own sentence then.
    public static func chopWarningsForHumans(_ result: SliceToSamplerResult) -> [String] {
        let wireHead = SliceToSamplerPlan.headDiscardedWarning(headSeconds: result.headSeconds)
        return result.warnings.map { warning in
            warning == wireHead
                ? leadInNotice(headSeconds: result.headSeconds)
                : speakingUIVocabulary(warning)
        }
    }

    /// What a person reads when an "Every hit" chop left the start of the clip
    /// off the pads: what happened, in their words, and every click to undo it.
    public static func leadInNotice(headSeconds: Double) -> String {
        "The first \(String(format: "%.2f", headSeconds)) s of the clip, before the first hit, "
            + "isn't on any pad. If a beat you want is in there: press Undo, open CHOP A CLIP… "
            + "again, switch to PRO, tick “\(PadChopSettings.leadInLabel)”, and chop."
    }
    /// What the last successful chop produced.
    public private(set) var lastChop: PadChopSummary?
    /// The track the last successful chop put the pads on. ⚠️ Carried
    /// separately from `lastChop` because the app needs it AFTER the notice is
    /// dismissed — it is what "point the app at the track you are now looking
    /// at" resolves against.
    public private(set) var lastChopTrackID: UUID?
    /// True while a chop is running — the button's spinner and its own guard.
    public private(set) var isChopping = false
    /// Bumped on every observable change, so a gate that drove the panel can
    /// prove the change went THROUGH rather than reading the previous call's
    /// state and stale-greening (the m23-e echo-seam law).
    public private(set) var reportSeq = 0

    public init(typing: MusicalTypingController,
                zones: @escaping () -> [SamplerZone],
                targetName: @escaping () -> String?,
                targetIsAI: @escaping () -> Bool = { false },
                selectedClip: @escaping () -> PadChopSource? = { nil },
                trackNameForID: @escaping (UUID) -> String? = { _ in nil },
                oneShot: @escaping () -> Bool? = { nil },
                setOneShot: @escaping (Bool) -> String? = { _ in nil },
                setZones: @escaping ([SamplerZone]) -> String? = { _ in nil },
                chopAction: @escaping (UUID, SliceToSamplerSettings, Bool) async throws
                    -> SliceToSamplerResult = { _, _, _ in
                        throw ProjectError.engineUnavailable
                    }) {
        self.typing = typing
        self.zonesProvider = zones
        self.targetNameProvider = targetName
        self.targetIsAIProvider = targetIsAI
        self.selectedClipProvider = selectedClip
        self.trackNameForIDProvider = trackNameForID
        self.oneShotProvider = oneShot
        self.setOneShotAction = setOneShot
        self.setZonesAction = setZones
        self.chopAction = chopAction
    }

    /// Points an inert model at the live app.
    ///
    /// ⛔ **THIS IS A TWO-PHASE INIT, NOT A SETTER FOR CONVENIENCE.** The app's
    /// injectors close over `AppModel.activeTrackID` and `selectedClipID`, and
    /// Swift forbids capturing `self` in a closure before every stored property
    /// is initialised — this model being one of them. `AppModel` therefore
    /// builds it inert and calls this from `installPadGrid()`, the shape
    /// `installMusicalTyping()` already uses for the live-note sink.
    ///
    /// Every argument is optional so a test can rebind ONE seam without
    /// restating the others.
    public func rebind(zones: (() -> [SamplerZone])? = nil,
                       targetName: (() -> String?)? = nil,
                       targetIsAI: (() -> Bool)? = nil,
                       selectedClip: (() -> PadChopSource?)? = nil,
                       trackNameForID: ((UUID) -> String?)? = nil,
                       oneShot: (() -> Bool?)? = nil,
                       setOneShot: ((Bool) -> String?)? = nil,
                       setZones: (([SamplerZone]) -> String?)? = nil,
                       chopAction: ((UUID, SliceToSamplerSettings, Bool) async throws
                                    -> SliceToSamplerResult)? = nil) {
        if let zones { zonesProvider = zones }
        if let targetName { targetNameProvider = targetName }
        if let targetIsAI { targetIsAIProvider = targetIsAI }
        if let selectedClip { selectedClipProvider = selectedClip }
        if let trackNameForID { trackNameForIDProvider = trackNameForID }
        if let oneShot { oneShotProvider = oneShot }
        if let setOneShot { setOneShotAction = setOneShot }
        if let setZones { setZonesAction = setZones }
        if let chopAction { self.chopAction = chopAction }
        isBound = true
        bump()
    }

    // MARK: - Live reads

    public var baseNote: Int { typing.padBaseNote }
    public var bank: Int { typing.padBank }
    public var targetName: String? { targetNameProvider() }

    /// The zones, once per render pass. Every read below goes through this so a
    /// single body evaluation calls the injector ONCE rather than sixteen times.
    private var zones: [SamplerZone] { zonesProvider() }

    /// How many banks the loaded keymap reaches. Always ≥ 1.
    public var bankCount: Int {
        PadGridGeometry.bankCount(highestPitch: zones.map(\.rootPitch).max(),
                                  baseNote: baseNote)
    }

    /// SLICES whose root sits BELOW pad 1 — unreachable on this grid.
    ///
    /// ⭐ **REPORTED RATHER THAN HIDDEN.** A chop at `baseNote: 24` viewed on a
    /// grid based at 36 would draw sixteen empty pads over a fully loaded
    /// sampler, and every other reading in this model would agree with the
    /// picture. The header says "12 slices sit below pad 1" and offers the base
    /// note that would reach them.
    ///
    /// ⚠️ **SLICES ONLY — A SPREAD IS NOT COUNTED HERE (m39-levels-3).** A
    /// spread usually sits directly below the chop, so after a relaunch (the
    /// grid back at 36) it WOULD sit below pad 1 — and "show them" lands on the
    /// lowest ROOT, which for a CENTRED spread is its ninth key: pad 1 would
    /// open eight keys into the spread, half the grid spread and half chop. A
    /// spread is reached through LEVELS instead (`toggleLevels` goes to it,
    /// aligned), which also reaches a spread ABOVE the chop, where this
    /// affordance never looks.
    public var unreachableBelowCount: Int {
        slices(in: zones).filter { $0.rootPitch < baseNote }.count
    }

    /// The lowest root pitch among the SLICES — what `unreachableBelowCount`'s
    /// fix would set the base note to. Never a spread's (see above).
    public var lowestRootPitch: Int? { slices(in: zones).map(\.rootPitch).min() }

    /// Total loaded SLICES across every bank — the header's "8 slices loaded".
    ///
    /// ⛔ **NOT `zones.count` (m39-levels-3, measured).** A Sixteen Levels
    /// spread is one extra zone, and counting it made the header say "9 slices
    /// loaded" over an 8-slice chop for as long as LEVELS was up — and forever
    /// after a relaunch.
    public var loadedCount: Int { slices(in: zones).count }

    /// The keymap's SLICES: every zone except a Sixteen Levels spread.
    ///
    /// A spread is anything `SixteenLevels.isSpread` accepts — THE one
    /// predicate, the store's and the wire's too — plus the ONE zone this grid
    /// itself moved onto (`sessionSpread`), even after something reshaped it
    /// out of spread shape: the grid still draws that zone as a spread and
    /// still removes it on EXIT, so numbering it as a slice as well would
    /// shift the chop exactly as the bug did.
    private func slices(in live: [SamplerZone]) -> [SamplerZone] {
        let own = sessionSpread(in: live)?.id
        return live.filter { !SixteenLevels.isSpread($0) && $0.id != own }
    }

    /// The sixteen pads of the CURRENT bank, ready to draw.
    ///
    /// ⚠️ A zone answers a pad when the pad's pitch falls in the zone's
    /// `[minPitch, maxPitch]` span — NOT when it equals `rootPitch`. A chop
    /// writes `minPitch == maxPitch == rootPitch` so the two coincide there, but
    /// an SFZ library's multi-key zones do not, and a grid that only matched
    /// roots would draw an imported drum kit as almost entirely empty.
    public var pads: [PadState] {
        let live = zones
        let sounding = typing.soundingPitchSet
        let isAI = targetIsAIProvider()
        // Ordinals are assigned over the WHOLE keymap in pitch order, so bank 2
        // pad 1 reads "slice 17". Computed once per pass, not per pad.
        // ⛔ SLICES ONLY (m39-levels-3): `sliceOrdinals` drops every spread by
        // shape; the grid's own spread is dropped by identity too (`slices(in:)`).
        let own = sessionSpread(in: live)?.id
        let ordinals = Self.sliceOrdinals(zones: live.filter { $0.id != own })
        return PadGridGeometry.bankPadIndices.map { index in
            guard let pitch = PadGridGeometry.pitch(forPad: index,
                                                    baseNote: baseNote, bank: bank) else {
                return PadState(id: index, pitch: nil, noteName: "—",
                                keyLabel: PadGridGeometry.keyLabel(forPad: index),
                                isLoaded: false, isPlaying: false, sliceOrdinal: nil,
                                startFrame: nil, isAITouched: false)
            }
            let zone = live.first { $0.minPitch <= pitch && pitch <= $0.maxPitch }
            // ⭐ IN A SPREAD EVERY PAD IS THE SAME ZONE, so the slice number is
            // replaced by the interval — sixteen squares reading "slice 7"
            // would each play something different while all claiming to be one
            // thing. See `PadState.levelsSemitones`.
            // ⛔ READ OFF THE LIVE ZONE'S ROOT (m39-levels-2), never off the
            // toggle: UP and CENTRED differ ONLY in that root, so a label worked
            // out from what the toggle last said would lie the moment a write
            // bounced or an agent moved the root over the wire.
            // ⛔⛔ AND OFF THE ZONE THAT ANSWERS THIS PAD, RECOGNISED BY SHAPE
            // (m39-levels-3) — not only off the one spread this grid remembers
            // making. That memory is session state: a relaunch loses it and a
            // spread made over the wire never had it, and either way the spread
            // used to draw as sixteen pads all reading "1". Every spread on the
            // kit now labels itself, wherever the grid stands.
            let spread = zone.flatMap { answering in
                SixteenLevels.isSpread(answering) || answering.id == own
                    ? SixteenLevels.semitones(atPitch: pitch, on: answering) : nil
            }
            return PadState(
                id: index,
                pitch: pitch,
                noteName: Fundamental.noteName(midiNote: pitch),
                keyLabel: PadGridGeometry.keyLabel(forPad: index),
                isLoaded: zone != nil,
                isPlaying: sounding.contains(pitch),
                sliceOrdinal: spread == nil ? zone.flatMap { ordinals[$0.id] } : nil,
                startFrame: zone?.startFrame,
                isAITouched: zone != nil && isAI,
                levelsSemitones: spread)
        }
    }

    /// zone id → 1-based ordinal in pitch order, over the SLICES. `static` and
    /// pure so a test can pin the numbering without building a model.
    ///
    /// ⛔⛔ **A SPREAD GETS NO NUMBER AND TAKES NONE (m39-levels-3, measured).**
    /// A spread sits directly BELOW the chop, so numbering it made it "slice 1"
    /// and pushed every real slice up one: the chop's first pad read "2". That
    /// happened the moment a spread existed — in-session on the chop's bank,
    /// and on every pad after a relaunch. Spreads are dropped here by THE one
    /// predicate (`SixteenLevels.isSpread`), so every caller — the pads, the
    /// header's source slice — numbers the same way.
    public static func sliceOrdinals(zones: [SamplerZone]) -> [UUID: Int] {
        let sorted = zones.filter { !SixteenLevels.isSpread($0) }.sorted { a, b in
            a.rootPitch == b.rootPitch ? a.id.uuidString < b.id.uuidString
                                       : a.rootPitch < b.rootPitch
        }
        var map: [UUID: Int] = [:]
        for (offset, zone) in sorted.enumerated() { map[zone.id] = offset + 1 }
        return map
    }

    /// The span of `startFrame`s across the loaded pads, for the position bar.
    /// nil when fewer than two pads carry one (a bar needs something to be a
    /// fraction OF).
    ///
    /// ⚠️ **FRAMES, NOT SECONDS.** See `PadState.startFrame`.
    public var loadedFrameSpan: ClosedRange<Int>? {
        let frames = zones.compactMap(\.startFrame)
        guard let lo = frames.min(), let hi = frames.max(), hi > lo else { return nil }
        return lo...hi
    }

    // MARK: - Bank switching

    public var canBankDown: Bool { bank > 0 }
    public var canBankUp: Bool {
        // ⚠️ Gated on MIDI, not on the loaded count: a user setting up an empty
        // kit must be able to move to bank 2 before anything is in it.
        PadGridGeometry.pitch(forPad: 0, baseNote: baseNote, bank: bank + 1) != nil
    }

    public func setBank(_ value: Int) {
        typing.setPadBank(value)
        bump()
    }

    public func shiftBank(by delta: Int) {
        typing.shiftPadBank(by: delta)
        bump()
    }

    /// Re-bases the grid so the LOWEST loaded slice lands on pad 1 — the fix
    /// `unreachableBelowCount` offers.
    public func baseOnLowestSlice() {
        guard let lowest = lowestRootPitch else { return }
        typing.setPadBaseNote(lowest)
        typing.setPadBank(0)
        bump()
    }

    // MARK: - What a pad does when you let go

    /// The live setting, or nil when the pad target is not a built-in sampler.
    ///
    /// ⚠️ **READ THROUGH, NEVER CACHED** — the same law every other reading on
    /// this model obeys. `instrument.setSamplerParam {oneShot}` over the wire,
    /// or the one-shot toggle on the sampler editor card, must move this row;
    /// a stored copy would be a second answer to "what happens when I let go?"
    /// that goes stale the moment an agent touches the sampler.
    public var triggerMode: PadTriggerMode? {
        oneShotProvider().map(PadTriggerMode.init(oneShot:))
    }

    /// Why the row is dead, in a sentence, or nil when it is live.
    public var triggerModeUnavailableReason: String? {
        guard triggerMode == nil else { return nil }
        guard let name = targetName else {
            return "Pick a track to choose what a pad does when you let go."
        }
        return "“\(name)” is not playing the built-in Sampler, so it has no pads to hold."
    }

    /// The store's refusal from the last attempt to change it, or nil.
    public private(set) var lastTriggerModeError: String?

    /// Flips it. A no-op when the value is already set, so a redundant click
    /// does not pay for a wholesale sampler re-validation.
    public func setTriggerMode(_ value: PadTriggerMode) {
        guard triggerMode != value else { return }
        lastTriggerModeError = setOneShotAction(value.isOneShot)
        bump()
    }

    // MARK: - Sixteen Levels

    /// A LIVE spread: which zone, which slice it came from, and where the grid
    /// goes when you leave.
    ///
    /// ⭐⭐ **DERIVED ON EVERY READ, NEVER STORED (m39-levels-3).** It used to be
    /// a stored property set by `enterLevels`, which made it the ONLY way the
    /// grid could know a spread existed — and it is session state. A project
    /// saved while LEVELS was up reopened with the spread still in the keymap
    /// and nothing in the grid that recognised it, so the spread was numbered as
    /// slice 1; a spread made over the wire (`instrument.spreadSlice`) or by the
    /// store was never recognised at all. Now the spread IS the record — its
    /// zone, read live through the one predicate — and this value is a view of
    /// it. See `liveSpreadZone` for which spread is "live".
    public struct Levels: Equatable, Sendable {
        /// The live spread's zone. ⚠️ Removal is BY THIS ID and nothing else —
        /// "remove the widest zone" or "remove the last one" would eat a user's
        /// own hand-built zone the first time one existed.
        public var spreadZoneID: UUID
        /// 1-based slice number of the slice the spread plays, for the header —
        /// or nil when no slice on the kit is its source any more (deleted, or
        /// its window edited since). Found by what the two PLAY
        /// (`SixteenLevels.sourceSlice`), so a hand-made spread and the same
        /// spread after a relaunch name the same slice.
        public var sourceOrdinal: Int?
        /// Pad 1's pitch while the spread is up.
        public var base: Int
        /// Where the grid goes on exit: where it stood when it moved onto this
        /// spread, or — for a spread it never moved onto itself — the chop's
        /// lowest slice, bank 1.
        public var homeBaseNote: Int
        public var homeBank: Int
    }

    /// What THIS grid remembers about a spread it moved onto — by hand
    /// (`enterLevels`) or by going to one it found (`toggleLevels`): which zone,
    /// and where to go back to.
    ///
    /// ⚠️ **SESSION STATE, AND NOTHING DEPENDS ON IT SURVIVING.** A relaunch
    /// loses it; a project opened over it, or a track switch, leaves it naming a
    /// zone that is not in the keymap, and then it is simply not consulted
    /// (`sessionSpread` finds nothing). It decides only two things: that its
    /// zone stays the live spread wherever the grid is banked, and where EXIT
    /// returns to.
    private struct Session: Equatable {
        var spreadZoneID: UUID
        var base: Int
        var homeBaseNote: Int
        var homeBank: Int
    }

    private var session: Session?

    /// The live spread, derived — see the type's note.
    public var levels: Levels? {
        let live = zones
        guard let spread = liveSpreadZone(in: live) else { return nil }
        let own = session?.spreadZoneID == spread.id ? session : nil
        return Levels(spreadZoneID: spread.id,
                      sourceOrdinal: Self.sourceOrdinal(of: spread, in: live),
                      base: own?.base ?? spread.minPitch,
                      homeBaseNote: own?.homeBaseNote
                          ?? Self.homeBaseNote(in: live, leaving: spread),
                      homeBank: own?.homeBank ?? 0)
    }

    /// LEVELS was pressed and the grid is waiting for the pad to spread.
    public private(set) var levelsArming = false
    public private(set) var lastLevelsError: String?

    public var isLevels: Bool { levels != nil }

    // MARK: Which way the spread runs (m39-levels-2)

    /// The direction the NEXT spread will run — what the UP / CENTRED toggle
    /// holds while no spread is up. UP by default, which is the behaviour that
    /// shipped, so nobody who never touches the toggle sees anything change.
    ///
    /// ⚠️ **SESSION STATE, DELIBERATELY NOT PERSISTED** — the same standing as
    /// the bank and the base note: a choice about how to PLAY, not a fact about
    /// the project. The fact that does persist is each spread's own direction,
    /// and that lives in its zone (see `SixteenLevels`' header), not here.
    public private(set) var preferredSpreadDirection: SixteenLevels.Direction = .up

    /// The LIVE spread, read FRESH from the keymap, or nil when LEVELS is not up.
    ///
    /// ⭐⭐ **LEVELS IS UP WHEN THE GRID IS PLAYING A SPREAD (m39-levels-3).**
    /// Two ways to be live, in this order:
    ///  1. **Identity first** — the zone THIS grid moved onto (`session`), for
    ///     as long as the keymap holds it, wherever the grid is banked: the
    ///     shipped behaviour for a hand-made spread, kept byte-for-byte. Held by
    ///     id, not by shape, so a spread something else reshaped is still the
    ///     one EXIT removes (and the one a flip refuses to touch).
    ///  2. **Shape second** — a spread (`SixteenLevels.isSpread`, THE one
    ///     predicate) that the grid is STANDING on: its sixteen keys ARE the
    ///     current bank's sixteen pads, pad 1 on its first key. This is how a
    ///     spread the grid never made — reopened after a relaunch, or made by
    ///     `instrument.spreadSlice` — comes up as LEVELS, with its intervals on
    ///     the pads and its slice in the header.
    ///
    /// ⚠️ **ALIGNED, NOT MERELY VISIBLE.** Every LEVELS sentence describes the
    /// pads on screen ("pad 1 is the slice as recorded"), so a grid straddling
    /// half a spread and half the chop is not in LEVELS — its spread pads still
    /// read their intervals (`pads` labels by shape everywhere), and the header
    /// offers LEVELS to go there aligned.
    public var liveSpreadZone: SamplerZone? { liveSpreadZone(in: zones) }

    private func liveSpreadZone(in live: [SamplerZone]) -> SamplerZone? {
        if let own = sessionSpread(in: live) { return own }
        guard let padOne = PadGridGeometry.pitch(forPad: 0, baseNote: baseNote, bank: bank),
              // First match, as the engine resolves a key within one group:
              // the zone that ANSWERS pad 1 must itself be the spread.
              let zone = live.first(where: { $0.contains(pitch: padOne) }),
              zone.minPitch == padOne, SixteenLevels.isSpread(zone) else { return nil }
        return zone
    }

    /// The zone this grid moved onto, if the keymap still holds it.
    private func sessionSpread(in live: [SamplerZone]) -> SamplerZone? {
        guard let id = session?.spreadZoneID else { return nil }
        return live.first { $0.id == id }
    }

    /// Spreads on this kit that are NOT live — lowest first. What LEVELS goes
    /// to, and what the header mentions when the grid is off them.
    ///
    /// ⭐ **MORE THAN ONE CAN EXIST** — `instrument.spreadSlice` can make
    /// several — and the grid still models ONE live spread. Every spread is
    /// kept out of the slice numbering and the slice count and labels its own
    /// pads; LEVELS goes to the lowest waiting one; EXIT removes only the live
    /// one, and LEVELS then goes to the next. The pad grid itself never makes a
    /// second: with a spread on the kit, LEVELS goes to it rather than arming.
    public var waitingSpreads: [SamplerZone] {
        let live = zones
        let current = liveSpreadZone(in: live)?.id
        return live.filter { SixteenLevels.isSpread($0) && $0.id != current }
            .sorted { a, b in
                a.minPitch == b.minPitch ? a.id.uuidString < b.id.uuidString
                                         : a.minPitch < b.minPitch
            }
    }

    /// The slice number of the slice `spread` plays, among the SLICES of
    /// `live`, or nil when none does. The ONE derivation, hand-made or not.
    private static func sourceOrdinal(of spread: SamplerZone,
                                      in live: [SamplerZone]) -> Int? {
        guard let source = SixteenLevels.sourceSlice(of: spread, in: live) else { return nil }
        return sliceOrdinals(zones: live.filter { $0.id != spread.id })[source.id]
    }

    /// Where EXIT takes the grid from a spread it did not move onto itself:
    /// the lowest SLICE — the chop's own pad 1 — or, with no slices left,
    /// the grid's default home.
    private static func homeBaseNote(in live: [SamplerZone], leaving spread: SamplerZone) -> Int {
        live.filter { $0.id != spread.id && !SixteenLevels.isSpread($0) }
            .map(\.rootPitch).min() ?? SliceToSamplerSettings.defaultBaseNote
    }

    /// What the toggle SHOWS. While a spread is up this is THAT SPREAD'S OWN
    /// direction, read off its zone — so a flip the store refused, or a root an
    /// agent moved over the wire, is reported as it is rather than as it was
    /// clicked (`triggerMode`'s rule). Otherwise, the preference.
    public var spreadDirection: SixteenLevels.Direction {
        liveSpreadZone.flatMap(SixteenLevels.direction(of:)) ?? preferredSpreadDirection
    }

    /// The toggle was clicked.
    ///
    /// No spread up → it only sets which way the next one runs. A spread up →
    /// it FLIPS that spread, through `SixteenLevels.keymap(_:respreading:to:)`:
    /// ⛔⛔ **ONE FIELD OF ONE ZONE — LEVELS' OWN.** The chop is written back as
    /// the same values in the same order; only the spread's `rootPitch` moves.
    ///
    /// A redundant click writes nothing (a sampler apply is wholesale and
    /// re-validates every zone file — the `setTriggerMode` guard). A REFUSED
    /// write leaves the preference alone too, so the toggle, which reads the
    /// zone, and the next spread, which reads the preference, cannot disagree
    /// about a click that did not take.
    public func setSpreadDirection(_ value: SixteenLevels.Direction) {
        guard let live = levels else {
            preferredSpreadDirection = value
            bump()
            return
        }
        let current = zones
        guard let spread = current.first(where: { $0.id == live.spreadZoneID }),
              SixteenLevels.direction(of: spread) != value else {
            // Already running that way — or the spread is gone, and there is
            // nothing to flip. Either way, remember the choice for the next one.
            preferredSpreadDirection = value
            bump()
            return
        }
        guard let respread = SixteenLevels.keymap(current, respreading: live.spreadZoneID,
                                                  to: value) else {
            // ⚠️ The spread is there but is no longer sixteen keys wide — the
            // sampler card or an agent reshaped it. Flipping it now would mean
            // editing more than its root, so REFUSE, and say so: silently
            // lighting the other chip would be a toggle claiming a state the
            // pads are not in. The preference stays put, as for any refusal.
            lastLevelsError = "This spread was changed outside the pad grid, so it cannot be "
                + "flipped. Press EXIT LEVELS, then make a new one."
            bump()
            return
        }
        if let refusal = setZonesAction(respread) {
            lastLevelsError = refusal
        } else {
            lastLevelsError = nil
            preferredSpreadDirection = value
        }
        bump()
    }

    /// Why the toggle is dead, or nil when it can be used. The LEVELS button's
    /// own reason: a direction for a spread that cannot be made is not a
    /// setting worth offering.
    public var spreadDirectionUnavailableReason: String? {
        isLevels ? nil : levelsUnavailableReason
    }

    /// The header line for whichever of the three states the grid is in.
    public var levelsStatus: String? {
        if let levels {
            let from = Self.sourcePhrase(levels.sourceOrdinal)
            switch spreadDirection {
            case .up:
                // ⚠️ BYTE-IDENTICAL to the line that shipped before the toggle
                // existed: UP is the default, and the default does not change.
                return "Sixteen Levels · \(from) · pad 1 is the "
                    + "slice as recorded, each pad up is a semitone higher"
            case .centered:
                // ⭐ It names what is ON SCREEN — the pad marked 0, the minus
                // pads, the plus pads — rather than pad numbers the grid does
                // not print. "Pad 9" stays because it is the card's own phrase
                // — the words the user read when they chose the toggle.
                return "Sixteen Levels · \(from) · pad 9, marked 0, "
                    + "is the slice as recorded — the minus pads play it lower, "
                    + "the plus pads higher"
            }
        }
        if levelsArming { return "Hit the pad holding the slice you want to play." }
        // ⭐ A SPREAD ON THE KIT, OFF THESE PADS (m39-levels-3) — after a
        // relaunch (the grid starts back on the chop), or made by an agent
        // while you played. Said out loud, because the button that goes there
        // reads plain "LEVELS", and a click that jumps somewhere instead of
        // arming would otherwise be a surprise.
        let waiting = waitingSpreads
        switch waiting.count {
        case 0:
            return nil
        case 1:
            let live = zones
            if let ordinal = Self.sourceOrdinal(of: waiting[0], in: live) {
                return "Sixteen Levels · slice \(ordinal) is spread on sixteen other pads — "
                    + "press LEVELS to go there"
            }
            return "Sixteen Levels · a spread is on sixteen other pads — press LEVELS to go there"
        default:
            return "Sixteen Levels · \(waiting.count) spreads are on other pads — press LEVELS "
                + "to go to the first"
        }
    }

    /// "slice 3", or the honest sentence when no slice on the kit is the
    /// spread's source any more — the header must never name a slice that is
    /// not the one being played.
    private static func sourcePhrase(_ ordinal: Int?) -> String {
        ordinal.map { "slice \($0)" } ?? "from a slice no longer on the pads"
    }

    /// Why LEVELS cannot be pressed, or nil when it can.
    public var levelsUnavailableReason: String? {
        guard levels == nil else { return nil }
        // ⭐ A spread already on the kit is always reachable: LEVELS goes to it
        // (`toggleLevels`), which needs neither a slice nor a free window.
        guard waitingSpreads.isEmpty else { return nil }
        guard !zones.isEmpty else {
            return "Chop something onto the pads first — Sixteen Levels spreads one "
                + "slice across the grid."
        }
        guard SixteenLevels.freeBase(zones: zones) != nil else {
            // ⚠️ NAMED, not a dimmed button. This is reachable — a 96-slice chop
            // low on the keyboard genuinely leaves no sixteen free notes — and a
            // control that just refuses to light teaches nothing.
            return "This kit fills the keyboard, so there is no room for a spread. "
                + "Chop fewer pieces, or raise “Pad 1 plays note” to free some low keys."
        }
        return nil
    }

    /// LEVELS pressed. On → back to the chop; arming → off; off with a spread
    /// already on the kit → go to it; otherwise off → arming.
    ///
    /// ⭐ **GO TO A SPREAD THAT EXISTS RATHER THAN MAKE ANOTHER (m39-levels-3).**
    /// After a relaunch the grid starts back on the chop with the saved spread
    /// sixteen keys away; arming there would stack a SECOND spread on the kit,
    /// and a third after the next relaunch. So LEVELS moves the grid onto the
    /// waiting spread, aligned, and WRITES NOTHING — the zone is already there.
    /// To spread a different slice: EXIT LEVELS (which removes this one), then
    /// LEVELS again.
    public func toggleLevels() {
        if levels != nil {
            exitLevels()
        } else if levelsArming {
            levelsArming = false
            bump()
        } else if let waiting = waitingSpreads.first {
            goToSpread(waiting)
        } else if levelsUnavailableReason == nil {
            levelsArming = true
            lastLevelsError = nil
            bump()
        } else {
            bump()
        }
    }

    /// Stands the grid on `spread` — pad 1 on its first key, bank 1 — and
    /// remembers where it was, so EXIT comes back here. No zone is written.
    private func goToSpread(_ spread: SamplerZone) {
        session = Session(spreadZoneID: spread.id, base: spread.minPitch,
                          homeBaseNote: baseNote, homeBank: bank)
        levelsArming = false
        lastLevelsError = nil
        typing.setPadBaseNote(spread.minPitch)
        typing.setPadBank(0)
        bump()
    }

    /// Spreads the slice under `padIndex` across the grid.
    ///
    /// ⛔⛔ **ADDS A ZONE; EDITS NOTHING.** See `SixteenLevels`'s header for why
    /// the two obvious builds — widening the slice in place, or swapping the
    /// keymap and remembering the original in this object — are data-loss
    /// shapes. The chop stays exactly where it was and keeps playing on its own
    /// notes while the spread is up.
    @discardableResult
    public func enterLevels(fromPad padIndex: Int) -> Bool {
        guard levels == nil else { return false }
        let live = zones
        guard let pitch = PadGridGeometry.pitch(forPad: padIndex,
                                                baseNote: baseNote, bank: bank),
              let source = live.first(where: { $0.minPitch <= pitch && pitch <= $0.maxPitch })
        else {
            lastLevelsError = "That pad is empty — pick one with a slice on it."
            bump()
            return false
        }
        // ⛔ NOT A SPREAD OF A SPREAD (m39-levels-3). A spread off the grid
        // now labels its own pads wherever the grid stands, so one can be under
        // the hand while arming (an agent made it mid-arm, or the grid
        // straddles one). Spreading it again would copy a copy — reachable,
        // and nothing a person asking for "this slice" meant.
        guard !SixteenLevels.isSpread(source) else {
            lastLevelsError = "That pad already plays a Sixteen Levels spread — pick a pad "
                + "holding one slice."
            bump()
            return false
        }
        guard let base = SixteenLevels.freeBase(zones: live) else {
            lastLevelsError = levelsUnavailableReason
            bump()
            return false
        }
        // ⭐ THE PREFERENCE DECIDES ONLY THE ROOT (m39-levels-2) — the keys, the
        // window and the "add one zone" write are identical in both directions.
        let spread = SixteenLevels.zone(from: source, base: base,
                                        direction: preferredSpreadDirection)
        // ⚠️ THE WRITE FIRST, THE VIEW SECOND. Moving the grid before the store
        // agreed would leave the pads pointing at sixteen empty notes with a
        // header announcing a spread — a surface describing an edit that did
        // not happen.
        if let refusal = setZonesAction(live + [spread]) {
            lastLevelsError = refusal
            bump()
            return false
        }
        // ⭐ Only WHERE THE GRID WAS is remembered. Which slice the spread
        // plays is derived on every read (`levels`), exactly as it is for a
        // spread the grid never made — one derivation, so a hand-made spread
        // and the same spread after a relaunch cannot name different slices.
        session = Session(spreadZoneID: spread.id, base: base,
                          homeBaseNote: baseNote, homeBank: bank)
        levelsArming = false
        lastLevelsError = nil
        typing.setPadBaseNote(base)
        typing.setPadBank(0)
        bump()
        return true
    }

    /// Takes the LIVE spread away and puts the grid back on the chop.
    ///
    /// ⭐ **THE SAME FOR EVERY SPREAD, WHOEVER MADE IT (m39-levels-3).** A
    /// spread reopened from disk or made over the wire is removed exactly as a
    /// hand-made one: by its own id, and nothing else in the keymap changes.
    /// The alternative — leave it, and only move the grid — would make EXIT
    /// mean two things depending on history the user cannot see, and would
    /// strand the spread on the kit with no way to take it off from here.
    /// The known cost is a zone that is spread-SHAPED without being a spread
    /// (see `SixteenLevels.isSpread`): standing on one and pressing EXIT
    /// removes it, as one undo step.
    ///
    /// ⚠️ **THE GRID MOVES HOME EVEN IF THE REMOVAL IS REFUSED.** Leaving the
    /// user parked on a spread they asked to leave, because the store could not
    /// write, would strand them in a mode with no way out; the refusal is shown
    /// instead. The worst case is one extra zone on unused notes, which the
    /// sampler card can delete — strictly better than a trapped surface.
    public func exitLevels() {
        guard let live = levels else { return }
        let refusal = setZonesAction(zones.filter { $0.id != live.spreadZoneID })
        lastLevelsError = refusal
        typing.setPadBaseNote(live.homeBaseNote)
        typing.setPadBank(live.homeBank)
        session = nil
        levelsArming = false
        bump()
    }

    // MARK: - Hitting a pad

    /// The pointer struck a pad of the current bank.
    ///
    /// `normalizedY` is 0 at the pad's TOP edge and 1 at its bottom; it moves the
    /// shared velocity before the note sounds, so the strip's VELOCITY readout is
    /// telling the truth about what was just played. See
    /// `PadGridGeometry.velocity(atNormalizedY:)` for why the velocity is shared
    /// rather than per-hit.
    public func padDown(index: Int, normalizedY: Double) {
        // ⚠️ ARMING SWALLOWS THE HIT, AND DOES NOT SOUND IT. A tap that both
        // picked the slice and played it would leave the user unsure which of
        // the two just happened — and the sound would be the LAST thing they
        // heard from this keymap anyway, since entering re-bases the grid.
        if levelsArming {
            enterLevels(fromPad: index)
            return
        }
        guard let pitch = PadGridGeometry.pitch(forPad: index,
                                                baseNote: baseNote, bank: bank) else { return }
        // ⚠️ VELOCITY FIRST, THEN THE NOTE. `push()` reads `velocity` at the
        // moment it sends, so setting it after `pointerDown` would sound this
        // hit at the PREVIOUS strike's level and only correct itself on the next
        // one — an off-by-one the readout would hide.
        typing.setVelocity(PadGridGeometry.velocity(atNormalizedY: normalizedY))
        typing.pointerDown(pitch: pitch)
        bump()
    }

    public func padUp() {
        typing.pointerUp()
        bump()
    }

    // MARK: - The chop

    /// What the panel can chop right now, or nil.
    public var chopSource: PadChopSource? { selectedClipProvider() }

    /// Why the CHOP button is disabled, or nil when it is live.
    ///
    /// ⚠️ Recomputed on every read rather than cached on selection change: a
    /// button whose enablement lagged the selection would invite a press the
    /// store then refuses, which is the affordance-lies shape.
    public var blockingRefusal: PadChopRefusal? {
        if isChopping { return .busy }
        guard let source = chopSource else { return .noClipSelected }
        return source.isMIDI ? .clipIsMIDI : nil
    }

    /// ⭐⭐ **THE SOURCE-STILL-PLAYS PROBLEM, AND WHY THE UI DEFAULTS TO MUTING
    /// WHILE THE WIRE DOES NOT.**
    ///
    /// `sliceClipToSampler` leaves the source clip exactly where it is — by
    /// design, and correctly: the chop READS the file and writes zones, it does
    /// not consume the recording. So after a chop the timeline holds BOTH the
    /// original and a reconstruction that replays it. Measured 2026-09-19: the
    /// two together are **+6.0 LU** louder than the source alone and audibly
    /// comb-filtered, because the reconstruction is the same waveform a few
    /// samples adrift.
    ///
    /// Three ways to handle that, and the middle one is the only honest one:
    ///
    ///  1. **Say nothing.** The user's first chop sounds wrong and nothing on
    ///     screen explains it. Rejected.
    ///  2. **Mute the source silently.** A command that quietly silences a track
    ///     the user did not name is the plausible-looking-success shape this
    ///     whole subsystem is arranged against — and if the source track carries
    ///     twelve other clips, it silences those too.
    ///  3. **Offer it, default it ON, NAME the track and its other clips, and
    ///     put the undo in the same edit.** That is this flag.
    ///
    /// On the WIRE the same parameter defaults FALSE, because `clip.sliceToSampler`
    /// is shipped and an agent's existing call must keep meaning exactly what it
    /// meant yesterday (the additive-only law). The UI is a NEW surface and may
    /// choose its own default; it just has to show it, which it does.
    public var muteSourceTrack: Bool {
        get { chop.muteSourceTrack }
        set { chop.muteSourceTrack = newValue; bump() }
    }

    /// The mute toggle's own label — it NAMES the track, and warns when other
    /// clips ride along.
    public var muteLabel: String {
        guard let source = chopSource else { return "Mute the original track" }
        if source.otherClipsOnTrack > 0 {
            // ⚠️ THE VERB AGREES TOO. "its 1 other clip GO quiet too" shipped and
            // was caught by LOOKING at a capture, not by a test: the plural was
            // handled on the noun and forgotten on the verb, which every
            // multi-clip fixture hid.
            return "Mute “\(source.trackName)” — its \(source.otherClipsOnTrack) "
                + (source.otherClipsOnTrack == 1
                   ? "other clip goes quiet too" : "other clips go quiet too")
        }
        return "Mute “\(source.trackName)”, the original"
    }

    /// Why muting is offered at all, in one beginner-readable line.
    public static let muteExplanation =
        "The pads are a copy of this recording. Left unmuted, the original and the "
        + "pads play together — about 6 LU louder, and hollow, because the two are "
        + "the same sound a few samples apart."

    /// Runs the chop. Returns true when pads landed.
    @discardableResult
    public func runChop() async -> Bool {
        if blockingRefusal != nil {
            // The card is already showing this refusal, recomputed — see the
            // note where the stored copy used to be.
            lastRefusal = nil
            bump()
            return false
        }
        guard let source = chopSource else {
            bump()
            return false
        }
        lastRefusal = nil
        isChopping = true
        bump()
        defer { isChopping = false; bump() }

        do {
            let result = try await chopAction(source.clipId, chop.settings(),
                                              chop.muteSourceTrack)
            // ⭐ Re-base the grid on what the chop ACTUALLY used, not on what the
            // panel asked for. `SliceToSamplerSettings.init` clamps `baseNote`,
            // so a panel value of 120 with 53 slices comes back lower — and a
            // grid based on the REQUEST would then draw empty pads over a
            // perfectly good chop, with every reading agreeing with the picture.
            let landed = result.slices.first?.pitch ?? chop.settings().baseNote
            typing.setPadBaseNote(landed)
            typing.setPadBank(0)
            lastChopTrackID = result.trackId
            lastChop = PadChopSummary(
                sliceCount: result.sliceCount,
                // ⛔ THE TRACK THE PADS LANDED ON, BY ID — never the ACTIVE
                // track, which is still the SOURCE at this instant. See
                // `trackNameForIDProvider`.
                trackName: trackNameForIDProvider(result.trackId)
                    ?? targetNameProvider() ?? "the chop track",
                createdTrack: result.createdTrackId != nil,
                // ⚠️ THE STORE'S ANSWER, NOT THE REQUEST — see the field's doc.
                mutedTrackName: result.mutedTrackId != nil ? source.trackName : nil,
                sourceStillAudible: !result.sourceTrackMuted,
                warnings: result.warnings,
                // What the notice SHOWS — see `chopWarningsForHumans`.
                warningsForHumans: Self.chopWarningsForHumans(result))
            bump()
            return true
        } catch {
            // VERBATIM. See `lastRefusal`.
            lastRefusal = (error as? ProjectError)?.errorDescription
                ?? error.localizedDescription
            bump()
            return false
        }
    }

    /// Clears the post-chop notice (its "Got it" affordance).
    public func dismissChopNotice() {
        lastChop = nil
        bump()
    }

    private func bump() { reportSeq &+= 1 }
}

/// The clip a chop would consume, as the panel needs to describe it. A VALUE,
/// assembled by the app from the store — this model never walks `tracks`.
public struct PadChopSource: Equatable, Sendable {
    public var clipId: UUID
    public var clipName: String
    public var trackId: UUID
    public var trackName: String
    public var isMIDI: Bool
    /// How many OTHER clips sit on the source track — what makes muting it a
    /// bigger decision than it looks.
    public var otherClipsOnTrack: Int

    public init(clipId: UUID, clipName: String, trackId: UUID, trackName: String,
                isMIDI: Bool, otherClipsOnTrack: Int) {
        self.clipId = clipId
        self.clipName = clipName
        self.trackId = trackId
        self.trackName = trackName
        self.isMIDI = isMIDI
        self.otherClipsOnTrack = otherClipsOnTrack
    }
}
