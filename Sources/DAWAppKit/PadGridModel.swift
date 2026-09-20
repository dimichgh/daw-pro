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
    public var warnings: [String]

    public init(sliceCount: Int, trackName: String, createdTrack: Bool,
                mutedTrackName: String?, sourceStillAudible: Bool,
                warnings: [String]) {
        self.sliceCount = sliceCount
        self.trackName = trackName
        self.createdTrack = createdTrack
        self.mutedTrackName = mutedTrackName
        self.sourceStillAudible = sourceStillAudible
        self.warnings = warnings
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
    public var lastRefusalForHumans: String? {
        guard let text = lastRefusal else { return nil }
        guard let source = chopSource else { return text }
        return text.replacingOccurrences(of: source.clipId.uuidString,
                                         with: "“\(source.clipName)”")
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
                       chopAction: ((UUID, SliceToSamplerSettings, Bool) async throws
                                    -> SliceToSamplerResult)? = nil) {
        if let zones { zonesProvider = zones }
        if let targetName { targetNameProvider = targetName }
        if let targetIsAI { targetIsAIProvider = targetIsAI }
        if let selectedClip { selectedClipProvider = selectedClip }
        if let trackNameForID { trackNameForIDProvider = trackNameForID }
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

    /// Zones whose root sits BELOW pad 1 — unreachable on this grid.
    ///
    /// ⭐ **REPORTED RATHER THAN HIDDEN.** A chop at `baseNote: 24` viewed on a
    /// grid based at 36 would draw sixteen empty pads over a fully loaded
    /// sampler, and every other reading in this model would agree with the
    /// picture. The header says "12 slices sit below pad 1" and offers the base
    /// note that would reach them.
    public var unreachableBelowCount: Int {
        zones.filter { $0.rootPitch < baseNote }.count
    }

    /// The lowest root pitch in the keymap — what `unreachableBelowCount`'s fix
    /// would set the base note to.
    public var lowestRootPitch: Int? { zones.map(\.rootPitch).min() }

    /// Total loaded pads across every bank.
    public var loadedCount: Int { zones.count }

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
        let ordinals = Self.sliceOrdinals(zones: live)
        return PadGridGeometry.bankPadIndices.map { index in
            guard let pitch = PadGridGeometry.pitch(forPad: index,
                                                    baseNote: baseNote, bank: bank) else {
                return PadState(id: index, pitch: nil, noteName: "—",
                                keyLabel: PadGridGeometry.keyLabel(forPad: index),
                                isLoaded: false, isPlaying: false, sliceOrdinal: nil,
                                startFrame: nil, isAITouched: false)
            }
            let zone = live.first { $0.minPitch <= pitch && pitch <= $0.maxPitch }
            return PadState(
                id: index,
                pitch: pitch,
                noteName: Fundamental.noteName(midiNote: pitch),
                keyLabel: PadGridGeometry.keyLabel(forPad: index),
                isLoaded: zone != nil,
                isPlaying: sounding.contains(pitch),
                sliceOrdinal: zone.flatMap { ordinals[$0.id] },
                startFrame: zone?.startFrame,
                isAITouched: zone != nil && isAI)
        }
    }

    /// zone id → 1-based ordinal in pitch order. `static` and pure so a test can
    /// pin the numbering without building a model.
    public static func sliceOrdinals(zones: [SamplerZone]) -> [UUID: Int] {
        let sorted = zones.sorted { a, b in
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

    // MARK: - Hitting a pad

    /// The pointer struck a pad of the current bank.
    ///
    /// `normalizedY` is 0 at the pad's TOP edge and 1 at its bottom; it moves the
    /// shared velocity before the note sounds, so the strip's VELOCITY readout is
    /// telling the truth about what was just played. See
    /// `PadGridGeometry.velocity(atNormalizedY:)` for why the velocity is shared
    /// rather than per-hit.
    public func padDown(index: Int, normalizedY: Double) {
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
                warnings: result.warnings)
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
