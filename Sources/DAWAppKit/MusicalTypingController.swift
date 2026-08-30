import Foundation
import Observation
import DAWCore

// m23-ct — MUSICAL TYPING: the state half. Mode, octave, velocity, and THE ONE
// held-note ledger that both input surfaces write and the on-screen keyboard
// reads.
//
// ═══ WHY THIS OBJECT AND NOT `@State` IN A VIEW ═══
//
// `StepSequencerBridge`'s three reasons, all of which apply, plus the one that
// is specific to this feature:
//
//   * **The staging seam must drive the SAME path the keys drive** (the m23-an
//     lesson: a chip the seam could not reach).
//   * **Two surfaces must agree.** The typed keys and the on-screen keyboard are
//     the same performance. If the keyboard view kept its own `@State` of what is
//     pressed, a chord typed on the computer keyboard would not light on screen —
//     and the brief's requirement that "the two surfaces agree" would be a
//     promise rather than a structure.
//   * **The `NSEvent` monitor is not in a view at all.** It lives on `AppModel`,
//     so a view-local ledger would be unreachable from the very code that fills
//     it.
//
// ⚠️ **SESSION STATE, NEVER PERSISTED.** The mode is deliberately NOT a
// `PanelLayoutStore` dimension: every sticky dimension is a leak class that
// changes a later cycle's gate verdict (the m23-be/bf/bg finding — pin to app
// defaults, never to ambient), and a mode that silently claims 21 letter keys
// across relaunches is the single worst thing to restore without being asked.
// **A fresh launch always starts with Musical Typing OFF.**

/// The live state of Musical Typing: is it on, where does the layout sit, and
/// what is sounding right now.
///
/// ⭐ **EDGE-SHAPED ABOVE, SET-SHAPED BELOW.** Fingers press and release; audio
/// wants "exactly these pitches". This object is the translation, and it is the
/// ONLY place the held set lives — see `LiveNoteSink`'s banner for why the
/// crossing under it must not be edge-shaped.
@MainActor
@Observable
public final class MusicalTypingController {

    // MARK: - Bounds

    /// Simultaneous sounding notes. Mirrors `AuditionController.maxVoices` so the
    /// store's own count guard — which THROWS at 9 and would drop the whole chord
    /// rather than the extra note — can never be reached from this path.
    ///
    /// ⚠️ **WE STEAL THE OLDEST; THE STORE WOULD KEEP THE LOWEST. THE DIVERGENCE
    /// IS DELIBERATE.** `AuditionController.clampPitches` keeps the lowest N
    /// because it serves a piano-roll DRAG, where a musician anchors on the bass.
    /// A typist pressing a 9th key means the 9th key — last-note priority, which
    /// is what every polyphonic synth does when it runs out of voices. Clamping
    /// HERE is what keeps the two policies from fighting: the store never sees a
    /// set it would have to trim.
    public static let maxVoices = AuditionController.maxVoices

    // MARK: - Mode

    /// Whether Musical Typing is ON.
    ///
    /// ⚠️ **EXPLICIT, NEVER AMBIENT** — the m23-ct hard requirement. This project
    /// has been bitten by key routing three times (m17-d, m23-g1, m23-cf); a mode
    /// that claimed 21 letter keys without the user turning it on and being able
    /// to SEE that it is on would be the fourth.
    public private(set) var isEnabled = false

    /// The octave the `A` key sits on. 4 = middle C (MIDI 60).
    public private(set) var baseOctave = MusicalTypingRouting.defaultBaseOctave

    /// The velocity the next note-on sounds at. Held notes keep the velocity they
    /// STARTED at — stepping C/V mid-chord changes the next note, never the ones
    /// already ringing, which is what a real keyboard does.
    public private(set) var velocity = AuditionController.defaultVelocity

    // MARK: - Chord mode (m23-cv)

    /// What ONE key press produces.
    ///
    /// ⭐ **ADDITIVE. `.notes` IS EXACTLY WHAT SHIPPED**, and every note-mode test
    /// in `MusicalTypingControllerTests` passes unmodified against it — that was
    /// checked before any chord behaviour was written, because a "mode" that
    /// quietly changed single-note typing would be a regression wearing a feature's
    /// clothes.
    public private(set) var playMode: MusicalTypingPlayMode = .notes

    /// The tonic of the chosen key, as a pitch class (0 = C).
    public private(set) var chordKey = 0

    /// Major or natural minor.
    public private(set) var chordKeyMode: KeyMode = .major

    /// Which instrument style the chords are voiced for.
    public private(set) var voicingPreset: VoicingPresetKind = .piano

    /// The named progression currently HIGHLIGHTED, or nil for none.
    ///
    /// ⛔⛔ **A PRESET LIGHTS KEYS. IT NEVER GATES THEM.** This is the whole shape
    /// of the feature the user chose — *"Both — presets highlight the scale"* —
    /// and it is enforced structurally rather than by discipline: this property is
    /// read by `chordCells` (which produces LABELS) and by nothing on the sounding
    /// path. `perform` and `pointerPress` never look at it, so there is no code in
    /// which a dim key could fail to play.
    public private(set) var progression: ChordProgressionPreset?

    /// The pitches the last chord was voiced at — the input nearest-tone voice
    /// leading measures the next chord against.
    ///
    /// ⚠️ **SESSION STATE, CLEARED ON THE SAME BOUNDARIES THE MODE IS** (mode off,
    /// play-mode change, preset change), matching the "session-only, never
    /// persisted" law that governs every other piece of Musical Typing state. It
    /// is deliberately NOT cleared when the key or the scale changes: a modulation
    /// is exactly the moment smooth voice leading is worth the most.
    @ObservationIgnored private var lastVoicing: [Int]?

    /// The 17 chord cells the strip draws, left to right — key legend, chord name,
    /// Roman numeral, and whether the current progression lights this one.
    ///
    /// ⭐ **DERIVED, NEVER STORED.** The view, the staging seam and any future
    /// gate read this ONE projection, so "what the keys say" and "what the keys
    /// play" cannot disagree — the divergence `MusicalKeyboardStrip`'s letter
    /// legend already spends a paragraph preventing for note names.
    public var chordCells: [MusicalTypingChordCell] {
        MusicalTypingRouting.noteCaps.compactMap { cap in
            guard let semitone = cap.semitone else { return nil }
            let layout = MusicalTypingRouting.chordDegree(semitone: semitone)
            let density = Self.density(for: voicingPreset, addsColour: layout.addsColour)
            let chord = ChordVoicing.diatonicChord(degree: layout.degree, key: chordKey,
                                                   mode: chordKeyMode, density: density)
            return MusicalTypingChordCell(
                keyCode: cap.keyCode,
                keyLabel: cap.label,
                degree: layout.degree,
                octaveShift: layout.octaveShift,
                addsColour: layout.addsColour,
                chordName: chord.name,
                romanNumeral: ChordVoicing.romanNumeral(degree: layout.degree,
                                                        mode: chordKeyMode, density: density),
                isLit: progression?.litDegrees.contains(layout.degree) == true,
                // ⚠️ THE NUMBER LANDS ON ONE CELL PER STEP — the base-octave
                // NATURAL key. See `MusicalTypingChordCell.progressionOrder`:
                // numbering every cell that shares the degree painted ten badges
                // for a four-chord preset, which only a screenshot could see.
                progressionOrder: (layout.octaveShift == 0 && !layout.addsColour)
                    ? progression?.order(ofDegree: layout.degree) : nil)
        }
    }

    /// The pitches a chord cell would sound RIGHT NOW, given what is sounding.
    ///
    /// **Pure with respect to this object** — it reads `lastVoicing` and writes
    /// nothing, so a view or a seam may call it to display a chord without
    /// disturbing the voice leading of the performance in progress. The write
    /// happens in `soundChord`, on the one path that actually makes sound.
    public func chordPitches(forKeyIndex index: Int) -> [Int] {
        let layout = MusicalTypingRouting.chordDegree(semitone: index)
        let preset = InstrumentVoicingPreset.preset(for: voicingPreset)
        let density = Self.density(for: voicingPreset, addsColour: layout.addsColour)
        let chord = ChordVoicing.diatonicChord(degree: layout.degree, key: chordKey,
                                               mode: chordKeyMode, density: density)
        // ⚠️ THE OCTAVE CHIP MOVES CHORDS TOO, and it has to: `baseOctave` is the
        // only register control this surface has, and in chord mode the preset's
        // own window is what it must move. Z/X therefore shift the whole voicing
        // by the same number of octaves they shift the note layout by.
        let octaveOffset = baseOctave - MusicalTypingRouting.defaultBaseOctave
        return ChordVoicing.voice(chord, previous: lastVoicing, preset: preset,
                                  octaveShift: layout.octaveShift + octaveOffset)
    }

    /// The chord density a key produces: the preset's own, or its OPPOSITE on an
    /// accidental key.
    ///
    /// ⭐ **ONE HOME FOR THE FLIP, read by both `chordCells` (which names the
    /// chord) and `chordPitches` (which sounds it).** A second copy is how the
    /// legend would come to say `Cmaj7` over a key that played a bare `C`.
    private static func density(for preset: VoicingPresetKind,
                                addsColour: Bool) -> ChordDensity {
        let base = InstrumentVoicingPreset.preset(for: preset).density
        guard addsColour else { return base }
        return base == .triad ? .seventh : .triad
    }

    /// Whether a key press can actually make a sound right now, and if not, why.
    ///
    /// ⭐ Written by the app from `MusicalTypingRouting.targetState(...)` — the
    /// pure resolver — and read by BOTH the indicator and the note-on gate below,
    /// so the reason shown on screen is the reason the note did not sound. A lamp
    /// reading ON over silently dead keys is this tree's characteristic failure
    /// mode (M27's meta-finding); one value serving both makes it unreachable.
    public var targetState: MusicalTypingRouting.TargetState = .noTrack

    // MARK: - The held ledger

    /// The pitches ACTUALLY SOUNDING, oldest first.
    ///
    /// ⚠️ **NAMED FOR WHAT IT IS, NOT FOR WHAT IS PRESSED**, and the on-screen
    /// keyboard lights exactly this. A key whose note was voice-stolen, or pressed
    /// while the target was not ready, is physically down and NOT in here — so a
    /// lit key always means a sounding note.
    public private(set) var soundingPitches: [Int] = []

    /// Set projection for the view's per-key hit test.
    public var soundingPitchSet: Set<Int> { Set(soundingPitches) }

    /// The predicate's verdict on the most recent key-DOWN, verbatim.
    ///
    /// ⚠️ **FOR THE STAGING SEAM TO REPORT, NOT FOR THE VIEW TO DRAW.** The seam
    /// used to infer its label from whether the monitor swallowed the event, which
    /// cannot tell a performed note from a swallowed auto-repeat — both are
    /// swallowed. That inference reported `performed` for a repeat that sounded
    /// nothing (measured on staging). Carrying the real decision removes the guess.
    public private(set) var lastDecision: MusicalTypingDecision?

    /// Is this controller holding ANYTHING — a sounding note, a claimed key, or
    /// the pointer?
    ///
    /// ⛔ **THIS EXISTS FOR ONE CALLER AND IT IS A BUG FIX, NOT A CONVENIENCE.**
    /// `handleFlagsChangedEvent` releases everything when ⌘ engages, and that
    /// handler runs on EVERY ⌘ press in the whole app — ⌘Z, ⌘S, ⌘C — with
    /// Musical Typing OFF. `releaseAll()` pushes `[]` unconditionally (by design:
    /// a panic path may not trust its own bookkeeping), and that empty set goes
    /// to `ProjectStore.auditionPitches`, which stops **whatever is holding the
    /// shared audition** — including the piano roll's gutter or a note drag the
    /// user is in the middle of. So a ⌘Z during a roll drag would cut the note
    /// the roll was sounding, through a mode nobody turned on.
    ///
    /// The ⌘ path therefore asks this first. It does NOT weaken the rule: when
    /// anything IS held, ⌘ still releases all of it. And it does not apply to the
    /// real panic paths (mode off, resign-active, record start) — those are rare
    /// EVENTS, not a key pressed a few hundred times an hour, and they keep the
    /// unconditional push for the reason `releaseAll` documents.
    public var holdsAnything: Bool {
        !soundingPitches.isEmpty || !keyPitches.isEmpty || !pointerPitches.isEmpty
    }

    /// keyCode → the pitches that key sounded when it went down.
    ///
    /// ⚠️ **THE PITCHES ARE REMEMBERED, NOT RE-DERIVED ON RELEASE.** Shift the
    /// octave while a key is held and its release must still stop the notes it
    /// started — re-deriving from the CURRENT base octave would release a pitch
    /// that was never sounding and strand the one that is. Same for the velocity
    /// ladder, and the same for chord mode's key/scale/preset pickers, which move
    /// while keys are down.
    ///
    /// ⭐ **A GROUP, NOT A PITCH (m23-cv), AND NOTE MODE IS THE DEGENERATE CASE.**
    /// One key holds one pitch in note mode and a whole voiced chord in chord
    /// mode. Storing a group is what lets a chord's release stop exactly its own
    /// notes: two held chords routinely SHARE a pitch, and a per-pitch ledger
    /// would let the first key up steal a note the second key is still holding.
    /// Every note-mode behaviour is unchanged — a one-element group behaves
    /// exactly as the old scalar did, which `MusicalTypingControllerTests` was run
    /// UNMODIFIED to prove before chord mode was added on top.
    @ObservationIgnored private var keyPitches: [UInt16: [Int]] = [:]

    /// The pitches the on-screen keyboard's pointer is holding, empty if none.
    /// ONE pointer is ONE note in note mode and ONE chord in chord mode —
    /// polyphony on that surface comes from chording a click on top of typed
    /// keys, and from the typed keys themselves.
    @ObservationIgnored private var pointerPitches: [Int] = []

    /// What the pointer is currently anchored on, so a drag across the surface can
    /// tell "still the same key" from "moved to the next one" in BOTH modes: a
    /// MIDI pitch on the piano, a scale degree on the chord row.
    @ObservationIgnored private var pointerAnchor: PointerAnchor?

    /// The pointer's anchor — see `pointerAnchor`.
    private enum PointerAnchor: Equatable {
        /// A MIDI pitch on the piano strip (note mode).
        case pitch(Int)
        /// An index into `MusicalTypingRouting.noteCaps` — a cell of the chord
        /// row (chord mode). ⚠️ **A CELL, NOT A DEGREE**: two cells can carry the
        /// same degree (the second octave run, and the colour keys), so a
        /// degree-shaped anchor could not tell them apart and a drag between them
        /// would look like no movement at all.
        case cell(Int)
    }

    /// Bumped on every state change the seam can observe (the m23-e echo-seam
    /// law): a gate that pressed a key needs proof the change has been THROUGH,
    /// rather than reading the previous call's state and stale-GREENing.
    public private(set) var reportSeq = 0

    /// The last key-down refusal, for `debug.musicalTyping`. Nil after a granted
    /// press. `ArrangeNudgeRefusal`'s rule: named, never a bare false.
    public private(set) var lastRefusal: MusicalTypingRefusal?

    /// The target state that silenced the last otherwise-granted note key, or nil
    /// when the note sounded. Distinct from `lastRefusal`: THAT one means "the key
    /// was not ours", this one means "the key was ours and we could not sound it".
    public private(set) var lastSilencedBy: MusicalTypingRouting.TargetState?

    // MARK: - The seam below

    /// Where held sets go. Weak-free (the app owns both for its lifetime) and
    /// optional so a headless test can drive the ledger with no sink at all and
    /// still assert on it.
    @ObservationIgnored public var sink: (any LiveNoteSink)?

    public init(sink: (any LiveNoteSink)? = nil) {
        self.sink = sink
    }

    // MARK: - Derived layout

    /// The MIDI note the `A` key currently sounds.
    public var baseNote: Int { MusicalTypingRouting.baseNote(forOctave: baseOctave) }

    /// The lowest and highest pitch the layout can currently reach — what the
    /// on-screen keyboard draws.
    public var pitchSpan: ClosedRange<Int> {
        baseNote...(baseNote + MusicalTypingRouting.semitoneSpan - 1)
    }

    /// The cap whose note is `pitch` at the current octave, or nil if `pitch` is
    /// outside the layout. Lets the on-screen keyboard print the letter a user
    /// would type for the key they are looking at — the two surfaces teaching
    /// each other.
    public func cap(forPitch pitch: Int) -> MusicalTypingKeyCap? {
        let semitone = pitch - baseNote
        return MusicalTypingRouting.noteCaps.first { $0.semitone == semitone }
    }

    // MARK: - Mode

    /// Turns the mode on or off.
    ///
    /// ⚠️ **TURNING IT OFF RELEASES EVERYTHING.** A user who hits the toggle with
    /// three keys down would otherwise be left holding a chord with no way to
    /// stop it: the key-UPs still arrive and are still honoured (see
    /// `releaseKey`), but the *mode* is what a panicking user reaches for, so it
    /// must be a way out and not a way to strand a voice.
    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if !enabled {
            // ⚠️ THE VOICE-LEADING ANCHOR IS SESSION STATE AND DIES WITH THE
            // SESSION (§5.5 step 2). Keeping it would make the first chord of the
            // NEXT session lead from a voicing nobody can hear any more — a
            // hidden input to a visible result.
            lastVoicing = nil
            releaseAll()
        } else {
            bump()
        }
    }

    public func toggle() { setEnabled(!isEnabled) }

    // MARK: - Chord-mode controls

    /// Switches between one-key-one-note and one-key-one-chord.
    ///
    /// ⚠️ **RELEASES EVERYTHING, for the same reason `setEnabled` does.** A key
    /// physically down when the mode flips is holding pitches computed under the
    /// OLD rule; its key-up would still find and release them (`releaseKey` takes
    /// no guards and remembers the group), but the user has just changed what the
    /// instrument IS, and leaving the previous rule's chord ringing over the new
    /// one is the surprise a mode switch must not have.
    public func setPlayMode(_ mode: MusicalTypingPlayMode) {
        guard mode != playMode else { return }
        playMode = mode
        lastVoicing = nil
        releaseAll()
    }

    /// Sets the tonic (pitch class, 0 = C) and the scale.
    ///
    /// ⛔ **HELD NOTES ARE LEFT ALONE**, exactly as `shiftOctave` leaves them: the
    /// ledger remembers what each key sounded, so a key change mid-chord re-aims
    /// the NEXT press and the ringing one still releases correctly. Voice leading
    /// is deliberately NOT reset — a modulation is when smooth leading is worth
    /// the most.
    public func setChordKey(_ pitchClass: Int, mode: KeyMode? = nil) {
        let normalised = ((pitchClass % 12) + 12) % 12
        let nextMode = mode ?? chordKeyMode
        guard normalised != chordKey || nextMode != chordKeyMode else { return }
        chordKey = normalised
        chordKeyMode = nextMode
        bump()
    }

    /// Sets the instrument voicing style. Resets the voice-leading memory: the new
    /// preset has a different register window, so leading the first chord of a
    /// piano voicing from the last chord of a bass line would drag it out of the
    /// register the preset exists to define.
    public func setVoicingPreset(_ kind: VoicingPresetKind) {
        guard kind != voicingPreset else { return }
        voicingPreset = kind
        lastVoicing = nil
        bump()
    }

    /// Lights a named progression, or clears the lights with `nil`.
    ///
    /// ⭐ **SELECTING ONE SWITCHES THE SCALE TO THE PROGRESSION'S MODE AND KEEPS
    /// THE USER'S TONIC.** Picking "Minor Rock" in C major gives C minor, not
    /// A minor: the tonic is the thing the user chose deliberately, the mode is
    /// the thing the progression is written in. Nothing else changes, and no key
    /// becomes unplayable.
    public func setProgression(_ preset: ChordProgressionPreset?) {
        progression = preset
        if let preset, preset.mode != chordKeyMode {
            chordKeyMode = preset.mode
        }
        bump()
    }

    // MARK: - Key events

    /// A key went DOWN. Returns what the monitor should do with the event.
    ///
    /// The predicate decides eligibility; this decides what happens. Splitting
    /// them is what keeps the guards testable without a window and the ledger
    /// testable without an `NSEvent`.
    @discardableResult
    public func handleKeyDown(keyCode: UInt16,
                              modifiers: TransportKeyModifiers,
                              isRepeat: Bool,
                              responder: TransportKeyResponder,
                              window: TransportKeyWindow) -> MusicalTypingDecision {
        let decision = MusicalTypingRouting.decide(
            keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat,
            responder: responder, window: window, isEnabled: isEnabled)
        lastDecision = decision
        switch decision {
        case .passThrough(let refusal):
            lastRefusal = refusal
            bump()
        case .swallowRepeat:
            // Nothing changes and nothing is refused — a held key is simply
            // still held. No bump: a 15 Hz auto-repeat must not spin the seam's
            // change counter, which a gate waits on.
            //
            // ⚠️ BUT IT IS RECORDED. `lastDecision` exists because the staging
            // seam derived its label from "was the event swallowed?" and reported
            // a swallowed repeat as `performed` — MEASURED on staging 2026-08-29,
            // and it is this tree's characteristic failure: an instrument that
            // returns something that LOOKS like a valid answer. The seam now reads
            // the decision itself instead of inferring it.
            break
        case .perform(let role):
            lastRefusal = nil
            perform(role, keyCode: keyCode)
        }
        return decision
    }

    /// A key came UP.
    ///
    /// ⛔⛔ **GATE THE ONS, NEVER GATE THE OFFS. THIS TAKES NO GUARDS AT ALL, AND
    /// THAT IS THE MOST IMPORTANT RULE IN THE FEATURE.** Hold `A`, then click into
    /// a rename field: the key-up arrives with `responder == .textEditing`, in a
    /// window that may no longer be main, possibly with ⌘ down. Every one of those
    /// facts would refuse a note-ON, and applying any of them here strands a note
    /// ringing forever. It is `auditionPitches`' own documented law — *"Stopping is
    /// ALWAYS allowed, including mid-take: a refusal here would strand a voice."*
    ///
    /// - Returns: true when a sounding note was released, so the monitor should
    ///   swallow the event. **False for a key we never sounded — pass that one
    ///   through** rather than eating a key-up that belongs to something else.
    @discardableResult
    public func releaseKey(keyCode: UInt16) -> Bool {
        guard let group = keyPitches.removeValue(forKey: keyCode) else { return false }
        // The pitches this key was holding that are ACTUALLY sounding. The rest
        // were voice-stolen, replaced by a later chord, or never sounded because
        // the target was not ready — there is nothing to stop for those.
        let ringing = group.filter { soundingPitches.contains($0) }
        guard !ringing.isEmpty else {
            bump()
            return false
        }
        // ⛔ **ANOTHER HOLDER MAY STILL WANT THESE EXACT PITCHES**, and in chord
        // mode that is the COMMON case rather than the corner one: C major and
        // A minor share two tones, so letting go of one while the other is held
        // must not silence them. Two keyCodes can also name one pitch after an
        // octave shift mid-hold (hold A at C4, shift down an octave, press K —
        // also C4), and the pointer can be on it too.
        let releasable = ringing.filter { !isStillHeldElsewhere($0) }
        guard !releasable.isEmpty else {
            bump()
            return true
        }
        soundingPitches.removeAll { releasable.contains($0) }
        push()
        return true
    }

    /// Every note off, now. Idempotent — safe to call from a notification that
    /// may fire when nothing is held.
    ///
    /// The panic button behind: mode off, window resign, app resign-active, a ⌘
    /// chord engaging (macOS may then never deliver the key-up), and record
    /// starting (`ProjectStore.record` releases the audition engine-side, so not
    /// mirroring it here would leave the on-screen keyboard lighting notes the
    /// engine has already stopped).
    public func releaseAll() {
        keyPitches.removeAll()
        pointerPitches.removeAll()
        pointerAnchor = nil
        soundingPitches.removeAll()
        // ⚠️ PUSHED UNCONDITIONALLY, even when nothing was held. `[]` is the
        // honest statement, the sink is idempotent, and `ProjectStore.stopAllAudition`
        // is documented idempotent for exactly this reason. An "only if something
        // was held" guard would make the panic path conditional on this object's
        // bookkeeping being CORRECT — which is the one thing a panic path may not
        // assume, since a bookkeeping bug is the likeliest reason it was called.
        push()
    }

    // MARK: - The on-screen keyboard

    /// The pointer pressed (or slid onto) a key on the on-screen keyboard.
    ///
    /// One pointer, one note: moving to another key moves the note, exactly like
    /// `KeyboardSidebar`'s gutter drag, which glissandos for free because the
    /// controller below diffs. Typed keys held at the same time keep sounding —
    /// that is where this surface's polyphony comes from.
    public func pointerDown(pitch: Int) {
        guard AuditionPitchBounds.contains(pitch) else { return }
        pointerPress(anchor: .pitch(pitch), group: [pitch])
    }

    /// The pointer pressed (or slid onto) a CHORD CELL on the on-screen chord row
    /// — chord mode's half of `pointerDown`.
    ///
    /// ⚠️ **A DEGREE, NOT A PITCH, AND THAT IS NOT AN ALTERNATIVE SPELLING.** In
    /// chord mode the strip no longer draws a piano whose cells ARE pitches; it
    /// draws one cell per layout key, and which pitches that cell sounds depends
    /// on the key, the scale, the preset and the voicing that came before it. The
    /// view must therefore name the CELL and let this object do the harmony —
    /// exactly as the typed keys do, through the same `chordVoicing(forDegree:)`,
    /// so the mouse and the keyboard cannot voice the same chord differently.
    public func pointerDown(cellIndex: Int) {
        guard cellIndex >= 0, cellIndex < MusicalTypingRouting.noteCaps.count else { return }
        pointerPress(anchor: .cell(cellIndex),
                     group: chordPitches(forKeyIndex: cellIndex))
    }

    /// The keys whose chord is ACTUALLY SOUNDING right now — what the chord row
    /// lights.
    ///
    /// ⚠️ **NAMED FOR WHAT IS SOUNDING, NOT FOR WHAT IS PRESSED**, exactly as
    /// `soundingPitches` is. A key whose chord was replaced by a later one is
    /// still physically down and is deliberately NOT in here, so a lit cell always
    /// means audible harmony.
    public var soundingChordKeyCodes: Set<UInt16> {
        var codes = Set<UInt16>()
        let ringing = Set(soundingPitches)
        for (keyCode, group) in keyPitches where !ringing.isDisjoint(with: group) {
            codes.insert(keyCode)
        }
        if case .cell(let index) = pointerAnchor,
           !ringing.isDisjoint(with: pointerPitches),
           index < MusicalTypingRouting.noteCaps.count {
            codes.insert(MusicalTypingRouting.noteCaps[index].keyCode)
        }
        return codes
    }

    /// The pointer let go.
    public func pointerUp() {
        guard !pointerPitches.isEmpty || pointerAnchor != nil else { return }
        let held = pointerPitches
        pointerPitches = []
        pointerAnchor = nil
        let releasable = held.filter { !isStillHeldElsewhere($0) }
        soundingPitches.removeAll { releasable.contains($0) }
        push()
    }

    /// The shared body of both `pointerDown` overloads. ONE gate, ONE glissando
    /// rule, ONE sounding path — a second copy for chord mode is how the two
    /// surfaces would drift.
    private func pointerPress(anchor: PointerAnchor, group: [Int]) {
        // ⛔ `.canSound`, NOT `== .ready` — both recording states SOUND. See
        // `TargetState.canSound`; a `.ready`-only gate here would kill the keys
        // at the exact moment the user is recording with them.
        guard isEnabled, targetState.canSound else {
            lastSilencedBy = isEnabled ? targetState : nil
            bump()
            return
        }
        guard !group.isEmpty else { return }
        guard pointerAnchor != anchor else { return }
        let previous = pointerPitches
        pointerPitches = []
        pointerAnchor = anchor
        if playMode == .chords {
            // ONE replace policy for both surfaces. A chord clicked on the row
            // and a chord typed on the keyboard must behave identically, or the
            // two surfaces stop being one instrument.
            pointerPitches = group
            lastSilencedBy = nil
            soundChord(group)
            return
        }
        let dropped = previous.filter { !isStillHeldElsewhere($0) && !group.contains($0) }
        soundingPitches.removeAll { dropped.contains($0) }
        pointerPitches = group
        lastSilencedBy = nil
        sound(group)
    }

    // MARK: - Layout controls (also reachable without a key, for the seam)

    public func shiftOctave(by delta: Int) {
        let next = MusicalTypingRouting.clampOctave(baseOctave + delta)
        guard next != baseOctave else { return }
        baseOctave = next
        // ⚠️ HELD NOTES ARE LEFT ALONE. `keyPitches` remembers what each key
        // sounded, so a shift mid-chord re-aims the NEXT press and leaves the
        // ringing ones exactly where they are — a real keyboard's behaviour, and
        // the only one whose releases can still line up.
        bump()
    }

    public func stepVelocity(by steps: Int) {
        let next = MusicalTypingRouting.steppedVelocity(velocity, by: steps)
        guard next != velocity else { return }
        velocity = next
        // Held notes keep the velocity they started at — the audition path has no
        // aftertouch, and re-pushing the set at a new velocity would retrigger
        // every ringing note.
        bump()
    }

    // MARK: - Internals

    private func perform(_ role: MusicalTypingKeyRole, keyCode: UInt16) {
        switch role {
        case .octaveDown: shiftOctave(by: -1)
        case .octaveUp: shiftOctave(by: 1)
        case .velocityDown: stepVelocity(by: -1)
        case .velocityUp: stepVelocity(by: 1)
        case .note(let semitone):
            // ⛔ `.canSound`, NOT `== .ready`: `.recordingArmed` and
            // `.recordingUnarmed` are STATUSES, not refusals. Typing while a
            // take rolls on an armed instrument track is the entire point of
            // the engine half of m23-ct.
            guard targetState.canSound else {
                // The key IS ours (the caller still swallows it — the mode is on,
                // and letting an "a" type itself into the arrange view would be
                // worse than silence). It just cannot sound, and the indicator
                // already says why.
                lastSilencedBy = targetState
                bump()
                return
            }
            if playMode == .chords {
                // ── CHORD MODE. The SAME key, the SAME ledger, the SAME seam
                // below — only what the press computes has changed. That is what
                // makes this additive rather than a second input surface.
                let group = chordPitches(forKeyIndex: semitone)
                guard !group.isEmpty else { bump(); return }
                lastSilencedBy = nil
                keyPitches[keyCode] = group
                soundChord(group)
                return
            }
            guard let pitch = MusicalTypingRouting.pitch(semitone: semitone,
                                                         baseOctave: baseOctave) else {
                bump()
                return
            }
            lastSilencedBy = nil
            keyPitches[keyCode] = [pitch]
            sound([pitch])
        }
    }

    /// Sounds a chord, REPLACING whatever chord was sounding.
    ///
    /// ⭐ **NEW CHORD REPLACES OLD — the research's §7.2 default, and the reason
    /// is arithmetic as much as taste.** A hand moving from one chord to the next
    /// does not keep the first one down, and four-note voicings stack up against
    /// the 8-voice ceiling after only two chords: without a replace, the third
    /// chord would arrive to find the voice-stealer chewing a ragged hole in the
    /// first two rather than cleanly ending them.
    ///
    /// ⚠️ **THE COST, SAID PLAINLY: LAYERING TWO DIFFERENT CHORDS AT ONCE IS NOT
    /// POSSIBLE IN CHORD MODE.** It still is in note mode, which is untouched.
    /// §7.2's own text says both "new-chord-replaces-old, by default" and
    /// "holding two different keys stays possible"; those two cannot both be true
    /// of one key press, and this picks the first, because the user this feature
    /// was built for follows lit keys in sequence and would meet the ragged
    /// voice-stealing case long before they meant to layer anything.
    ///
    /// ⭐ **COMMON TONES ARE NOT RE-STRUCK, FOR FREE.** The seam below is
    /// set-shaped and diffs, so a tone shared by the old chord and the new one
    /// simply keeps sounding — which is what nearest-tone voice leading is FOR,
    /// and which no extra code here produces.
    private func soundChord(_ group: [Int]) {
        soundingPitches.removeAll { !group.contains($0) }
        sound(group)
        // ⚠️ WRITTEN HERE, ON THE SOUNDING PATH ONLY. A chord that was refused
        // (no track, preview off) must not move the voice-leading anchor — the
        // next chord has to lead from what is actually RINGING, not from
        // something the user never heard.
        lastVoicing = group
    }

    /// Adds a GROUP of pitches to the sounding set, stealing the oldest voices if
    /// the set overflows, then pushes ONCE.
    ///
    /// ⛔⛔ **THE GROUP IS ADDED ATOMICALLY, AND THAT IS A CORRECTNESS
    /// REQUIREMENT, NOT TIDINESS.** Sounding a four-note chord as four separate
    /// one-note calls would let the voice-stealer eat the chord's OWN earlier
    /// notes on the way in: press a chord while five notes are already ringing
    /// and notes 1 and 2 of the chord would be stolen by notes 3 and 4 of the
    /// same chord. Appending the whole group first and trimming from the front
    /// once means the arriving chord always survives intact, which is what
    /// last-note priority actually means.
    ///
    /// ⚠️ A group larger than `maxVoices` is clamped to its TOP voices before
    /// anything else — with `ChordVoicing.maxVoicedNotes` at 5 this is
    /// unreachable today, and it is here rather than assumed because the guard
    /// costs one line and the failure it prevents is a silently truncated chord.
    private func sound(_ group: [Int]) {
        let arriving = Array(group.suffix(Self.maxVoices))
        guard !arriving.isEmpty else { return }
        var next = soundingPitches
        for pitch in arriving where !next.contains(pitch) {
            // Already ringing pitches are left exactly where they are in the
            // order: re-appending one would make it look NEWER than it is and
            // hand the voice-stealer the wrong victim next time.
            next.append(pitch)
        }
        if next.count > Self.maxVoices {
            // LAST-NOTE PRIORITY: the oldest ringing notes lose their voices.
            // Their keys stay in `keyPitches` so the eventual key-up is still
            // recognised — it simply finds nothing to stop. Stolen notes do NOT
            // come back when a voice frees up; no synth does that, and a note
            // that restarted itself seconds later would be a ghost.
            next.removeFirst(next.count - Self.maxVoices)
        }
        soundingPitches = next
        push()
    }

    /// Is this pitch still wanted by some other holder?
    private func isStillHeldElsewhere(_ pitch: Int) -> Bool {
        pointerPitches.contains(pitch) || keyPitches.values.contains { $0.contains(pitch) }
    }

    /// Hands the current set across the seam and bumps the report counter.
    private func push() {
        sink?.setHeldPitches(soundingPitches, velocity: velocity)
        bump()
    }

    private func bump() { reportSeq &+= 1 }
}
