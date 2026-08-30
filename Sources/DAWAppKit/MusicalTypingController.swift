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
        !soundingPitches.isEmpty || !keyPitches.isEmpty || pointerPitch != nil
    }

    /// keyCode → the pitch that key sounded when it went down.
    ///
    /// ⚠️ **THE PITCH IS REMEMBERED, NOT RE-DERIVED ON RELEASE.** Shift the octave
    /// while a key is held and its release must still stop the note it started —
    /// re-deriving from the CURRENT base octave would release a pitch that was
    /// never sounding and strand the one that is. Same for the velocity ladder.
    @ObservationIgnored private var keyPitches: [UInt16: Int] = [:]

    /// The pitch the on-screen keyboard's pointer is holding, if any. ONE pointer
    /// is ONE note — polyphony on that surface comes from chording a click on top
    /// of typed keys, and from the typed keys themselves.
    @ObservationIgnored private var pointerPitch: Int?

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
        if !enabled { releaseAll() } else { bump() }
    }

    public func toggle() { setEnabled(!isEnabled) }

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
        guard let pitch = keyPitches.removeValue(forKey: keyCode) else { return false }
        guard soundingPitches.contains(pitch) else {
            // The key was ours and is now released, but its note is not sounding
            // — voice-stolen, or never sounded because the target was not ready.
            // Nothing to stop, and nothing to swallow.
            bump()
            return false
        }
        // Another holder may still want this exact pitch: two keyCodes can name
        // one pitch after an octave shift mid-hold (hold A at C4, shift down an
        // octave, press K — also C4), and the pointer can be on it too.
        guard !isStillHeldElsewhere(pitch) else {
            bump()
            return true
        }
        soundingPitches.removeAll { $0 == pitch }
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
        pointerPitch = nil
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
        // ⛔ `.canSound`, NOT `== .ready` — both recording states SOUND. See
        // `TargetState.canSound`; a `.ready`-only gate here would kill the keys
        // at the exact moment the user is recording with them.
        guard isEnabled, targetState.canSound else {
            lastSilencedBy = isEnabled ? targetState : nil
            bump()
            return
        }
        guard AuditionPitchBounds.contains(pitch) else { return }
        guard pointerPitch != pitch else { return }
        if let previous = pointerPitch {
            pointerPitch = nil
            if !isStillHeldElsewhere(previous) {
                soundingPitches.removeAll { $0 == previous }
            }
        }
        pointerPitch = pitch
        lastSilencedBy = nil
        sound(pitch)
    }

    /// The pointer let go.
    public func pointerUp() {
        guard let pitch = pointerPitch else { return }
        pointerPitch = nil
        if !isStillHeldElsewhere(pitch) {
            soundingPitches.removeAll { $0 == pitch }
        }
        push()
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
            guard let pitch = MusicalTypingRouting.pitch(semitone: semitone,
                                                         baseOctave: baseOctave) else {
                bump()
                return
            }
            lastSilencedBy = nil
            keyPitches[keyCode] = pitch
            sound(pitch)
        }
    }

    /// Adds a pitch to the sounding set, stealing the oldest voice if the set is
    /// full, then pushes.
    private func sound(_ pitch: Int) {
        guard !soundingPitches.contains(pitch) else {
            // Already ringing (two keys can name one pitch after an octave
            // shift). Re-pushing the identical set is a documented no-op at the
            // sink, so this still refreshes the hold and costs nothing.
            push()
            return
        }
        if soundingPitches.count >= Self.maxVoices {
            // LAST-NOTE PRIORITY: the oldest ringing note loses its voice. Its
            // key stays in `keyPitches` so the eventual key-up is still
            // recognised — it simply finds nothing to stop. Stolen notes do NOT
            // come back when a voice frees up; no synth does that, and a note
            // that restarted itself seconds later would be a ghost.
            soundingPitches.removeFirst()
        }
        soundingPitches.append(pitch)
        push()
    }

    /// Is this pitch still wanted by some other holder?
    private func isStillHeldElsewhere(_ pitch: Int) -> Bool {
        pointerPitch == pitch || keyPitches.values.contains(pitch)
    }

    /// Hands the current set across the seam and bumps the report counter.
    private func push() {
        sink?.setHeldPitches(soundingPitches, velocity: velocity)
        bump()
    }

    private func bump() { reportSeq &+= 1 }
}
