import Foundation

// m23-ct — MUSICAL TYPING: the headless half of "this key press is a note".
//
// ═══ WHY THIS FILE EXISTS, AND WHY IT LOOKS LIKE ITS TWO NEIGHBOURS ═══
//
// The user has NO hardware MIDI controller (their words, 2026-08-04: "no
// physical keyboard"). `Sources/DAWEngine/MIDIInput/` is a complete CoreMIDI
// subsystem — client, UMP parser, RT-safe thru ring, capture session — with no
// door they can reach. This file is the first half of the door.
//
// It is a one-for-one mirror of `TransportKeyRouting` (space) and
// `DeleteKeyMonitorRouting` (⌫): a PURE predicate that the app's single
// `NSEvent` local monitor asks, mapping the live event's facts into value types
// with no AppKit import, so the guards are unit-testable headless.
//
// ⚠️⚠️ **NOT `.onKeyPress`, AND THAT IS MEASURED RATHER THAN STYLISTIC.**
// m23-al is OPEN: `pianoRollEditorFocused` alternates deterministically on clip
// switches (6 true / 6 false over 12 consecutive selections), so SwiftUI focus
// arbitration in this app is a coin flip. m23-fi measured the other half — a
// `.onKeyPress(.delete)` mount cannot fire for the ⌫ key at all, because
// `KeyEquivalent.delete` is 0x08 while the system translates `kVK_Delete` to
// 0x7F. Building a performance surface on either would re-acquire a bug this
// tree has already paid for twice. The monitor+predicate pattern is the shipped
// cure; this is that pattern.
//
// ═══ KEY CODES, NOT CHARACTERS — THE SAME DECISION THE OTHER TWO MADE ═══
//
// Every constant below is a `kVK_ANSI_*` virtual key code, VERIFIED against
// `MacOSX.sdk/…/HIToolbox.framework/Headers/Events.h` (2026-08-29) rather than
// recalled. Two reasons, one of them this repo's own scar:
//
//   * **A virtual key code names a PHYSICAL KEY POSITION**, which is exactly
//     what a musical keyboard layout is. `kVK_ANSI_A` is "the key left of S",
//     whatever legend is printed on it — so the note layout keeps its shape on
//     AZERTY/QWERTZ, which is what Logic and Live both do.
//   * **Character matching is the m23-fi defect.** `.characters` is layout- and
//     dead-key- and IME-dependent; the delete key's whole failure was a
//     character mismatch nobody could see.
//
// ⚠️ THE COST, SAID OUT LOUD: on a non-US layout the LEGENDS this file reports
// (`MusicalTypingKeyCap.label`) are the US-ANSI ones and will not match what is
// printed on the user's keys. The POSITIONS are right; the letters drawn on the
// on-screen keyboard may not be. Resolving live legends needs `UCKeyTranslate`
// (Carbon, and therefore not headless), so it is deliberately out of scope here
// — but it is a real, visible limitation, not a hypothetical one.

/// What a mapped key does. Note keys carry their offset ABOVE the current base
/// note; the five control keys carry no payload.
public enum MusicalTypingKeyRole: Equatable, Sendable {
    /// A note key: `semitone` semitones above the base note (0…16).
    case note(semitone: Int)
    /// Shift the whole layout down one octave.
    case octaveDown
    /// Shift the whole layout up one octave.
    case octaveUp
    /// Quieter — one step down the velocity ladder.
    case velocityDown
    /// Louder — one step up the velocity ladder.
    case velocityUp
    /// **THE SUSTAIN PEDAL (m34-l), Tab.** TOGGLES the damper pedal: press once
    /// for down, again for up. See `MusicalTypingController.toggleSustain` for
    /// why a latch rather than a hold.
    case sustainToggle
}

/// Why a key press did NOT become a note.
///
/// NAMED, never a bare `false` — `DeleteKeyMonitorRefusal`'s reason, and it bites
/// harder here: a suite that only ever proved refusals would pass identically
/// against a predicate that refused everything, which is how a dead feature ships
/// green.
public enum MusicalTypingRefusal: String, Equatable, Sendable, CaseIterable {
    /// Musical Typing is OFF. The mode is explicit and never ambient (the m23-ct
    /// hard requirement), so with it off this predicate has no opinion about any
    /// key on the keyboard.
    case modeOff = "mode-off"
    /// The mode is on, but this key is not part of the layout — Q, arrows, the
    /// space bar, ⌫. Passing these through is what keeps the mode from being a
    /// land grab: only the 22 keys in `allCaps` are ever swallowed.
    case unmapped
    /// A ⌘/⌥/⌃/⇧ chord. ⌘Z is undo, ⌘C is copy, ⌘S is save — and Z/C/S are all
    /// layout keys, so this guard is what makes the mode safe to leave on.
    case chord
    /// A text-input surface owns keyboard focus. ⚠️ **THE NON-NEGOTIABLE ONE.**
    /// Typing into a rename field, the Copilot rail, or a Settings box must
    /// insert characters, never notes — even with the mode ON.
    case textEditing = "text-editing"
    /// The event is aimed at some other window — a floating plugin window, a
    /// panel, or an unresolvable synthesized window number.
    case secondaryWindow = "secondary-window"
}

/// What the app's key-down monitor should do with a key press.
public enum MusicalTypingDecision: Equatable, Sendable {
    /// Act on this key AND swallow the event, so nothing downstream types or
    /// beeps.
    case perform(MusicalTypingKeyRole)
    /// Ours, but nothing to do: a HELD key auto-repeating. Swallow it silently.
    ///
    /// ⚠️ **THIS IS THE THIRD OUTCOME NEITHER NEIGHBOUR NEEDED, and it is not
    /// symmetry.** Space and ⌫ pass repeats through because they are one-shot
    /// commands. A held note key repeats ~15×/s, and both two-outcome answers are
    /// wrong: passing it through beeps and types letters into whatever is behind,
    /// and treating it as a fresh press machine-guns the note-on.
    case swallowRepeat
    /// Not ours — hand the event back untouched, carrying which guard refused.
    case passThrough(MusicalTypingRefusal)
}

/// One key of the layout: the physical key, the US-ANSI legend printed on it,
/// and what it does.
///
/// Carried as a value (rather than three parallel tables) so the on-screen
/// keyboard, the tests and the `debug.musicalTyping` seam all read ONE home for
/// "which key is which note" — the divergence `KeyboardSidebar.keyLabel`'s own
/// comment spends a paragraph preventing for note NAMES.
public struct MusicalTypingKeyCap: Equatable, Sendable, Identifiable {
    /// `NSEvent.keyCode` — a physical position, not a character.
    public let keyCode: UInt16
    /// The legend on a US-ANSI keyboard. ⚠️ DISPLAY ONLY, never matched against
    /// `.characters` — see this file's banner for the layout caveat.
    public let label: String
    /// What pressing it does.
    public let role: MusicalTypingKeyRole

    public var id: UInt16 { keyCode }

    public init(keyCode: UInt16, label: String, role: MusicalTypingKeyRole) {
        self.keyCode = keyCode
        self.label = label
        self.role = role
    }

    /// The semitone offset a note key carries, or nil for a control key.
    public var semitone: Int? {
        if case .note(let semitone) = role { return semitone }
        return nil
    }
}

/// What ONE key press produces (m23-cv).
///
/// ⭐ **ADDITIVE BY CONSTRUCTION.** `.notes` is the shipped behaviour, byte for
/// byte, and it is the default everywhere — a fresh launch, a fresh controller,
/// and every existing test. `.chords` changes only what the press COMPUTES; the
/// key table, the guards, the held ledger, the seam and the capture path are the
/// same objects doing the same work.
public enum MusicalTypingPlayMode: String, Equatable, Sendable, CaseIterable {
    /// One key, one note — m23-ct.
    case notes
    /// One key, one correctly-voiced diatonic chord — m23-cv.
    case chords
}

/// One cell of the on-screen CHORD ROW: which key plays it, what it is called,
/// and whether the lit progression uses it.
///
/// ⭐ **A LABEL CARRIER, DELIBERATELY CARRYING NO PITCHES.** What a cell sounds
/// depends on what was sounding before it (nearest-tone voice leading), so a cell
/// that carried a pitch array would be stale the moment anything was played and
/// the strip would draw a chord the keys do not produce. The view draws THIS; the
/// controller computes the pitches at press time.
public struct MusicalTypingChordCell: Equatable, Sendable, Identifiable {
    /// The physical key. `id` for the view, and the seam's handle on the cell.
    public let keyCode: UInt16
    /// The US-ANSI legend printed on that key — display only, never matched.
    public let keyLabel: String
    /// 1-based scale degree: 1 = the tonic's chord.
    public let degree: Int
    /// How many octaves above the base run this cell sits (0 or 1).
    public let octaveShift: Int
    /// Whether this is an ACCIDENTAL key, which flips its degree between a plain
    /// triad and its seventh chord. See `MusicalTypingRouting.chordDegree`.
    public let addsColour: Bool
    /// `"C"`, `"Am"`, `"G7"` — what the user reads.
    public let chordName: String
    /// `"I"`, `"vi"`, `"V7"` — what the user learns.
    public let romanNumeral: String
    /// This cell's step number in the lit progression, 1-based — **and only on
    /// the ONE cell a beginner should press for that step.**
    ///
    /// ⛔⛔ **NOT DRAWN ANY MORE — RETRACTED IN PLACE AT m34-i, NOT DELETED.** This
    /// used to be a numeric badge on the key. The user played it and reported the
    /// badges were *"hard to read"*, and the same pass found the deeper defect the
    /// badges were papering over (see `ChordSequencePlayer`). **State is shown by
    /// LIGHT, never by text — a performer cannot read while playing** — so the
    /// badge is gone and `isNextInProgression` below is what the surface paints.
    /// The number survives as **seam data**: it is what lets a gate say *which*
    /// step the border is on without re-deriving the progression from a second
    /// copy of the degrees. ⚠️ If you are about to draw it again, you are undoing
    /// m34-i.
    ///
    /// ⚠️ **NUMBERED IS NARROWER THAN LIT, AND THAT IS A LOOKING-AT-IT FIX** —
    /// kept because `isNextInProgression` inherits exactly the same narrowing and
    /// would re-earn the same bug without it. The first version numbered every
    /// cell carrying a lit DEGREE, which is arithmetically correct and visually
    /// wrong: the colour keys and the second octave run share their degree, so
    /// "Four Chords" painted TEN badges and the row showed four different cells
    /// all labelled `1`. A screenshot of the live app is the only instrument that
    /// could see that — no assertion in this tree looks at a pixel. The number
    /// lands on the base-octave natural key alone; the other cells of the same
    /// degree stay LIT, so "any lit key plays this chord" is still true.
    public let progressionOrder: Int?

    /// **THE BORDER: is this the chord to play NEXT?** The moving cue that
    /// replaced the numeric badges (m34-i), driven by
    /// `ChordSequencePlayer.nextDegree`.
    ///
    /// ⛔ **EXACTLY ONE CELL CARRIES THIS while a preset is lit, and zero when
    /// none is** — it inherits `progressionOrder`'s narrowing (base-octave
    /// natural keys only) for the reason that comment records, and both counts
    /// are pinned by test and by the live smoke.
    ///
    /// ⛔ **IT IS A CUE, NEVER A GATE.** Playing some other chord neither moves it
    /// nor is refused; nothing on the sounding path reads this.
    public let isNextInProgression: Bool

    /// **THE LOOK-AHEAD QUEUE (m34-g): HOW SOON THIS CHORD COMES UP.** `1` is the
    /// one after the cue, `2` the one after that, up to
    /// `MusicalTypingController.queueDepth`. `nil` means "not in the queue" —
    /// **including the cued cell itself**, which wears the border instead, so no
    /// cell is ever both bordered and queued.
    ///
    /// ⭐⭐ **THIS IS WHAT FINALLY TELLS THE PRESETS APART AT REST**, and m34-i
    /// recorded the gap in its own close: Four Chords `[1,5,6,4]` and Doo-Wop
    /// `[1,6,4,5]` light the same four degrees AND both open on I, so with only a
    /// cue they are identical until the first chord is played. With a queue they
    /// are the same four cells in two different orders of brightness, before a
    /// note is struck.
    ///
    /// ⛔ **DRAWN AS LIGHT, NEVER AS A NUMBER.** The value is an ordinal, but the
    /// row paints it as a shrinking bar of the accent hue — the badge this
    /// replaced is exactly what m34-i deleted. If you are about to draw this
    /// integer, read `progressionOrder`'s doc first.
    ///
    /// ⚠️ Same narrowing as the border (base-octave natural keys only), so a
    /// degree marks ONE cell and not the four that share it.
    public let queueRank: Int?

    /// Whether the current progression uses this cell's degree. **Lit is PAINT
    /// AND NOTHING ELSE** — no code on the sounding path reads it, so a dim key
    /// cannot fail to play.
    public let isLit: Bool

    public var id: UInt16 { keyCode }

    public init(keyCode: UInt16, keyLabel: String, degree: Int, octaveShift: Int,
                addsColour: Bool, chordName: String, romanNumeral: String,
                isLit: Bool, progressionOrder: Int?,
                isNextInProgression: Bool = false,
                queueRank: Int? = nil) {
        self.keyCode = keyCode
        self.keyLabel = keyLabel
        self.degree = degree
        self.octaveShift = octaveShift
        self.addsColour = addsColour
        self.chordName = chordName
        self.romanNumeral = romanNumeral
        self.isLit = isLit
        self.progressionOrder = progressionOrder
        self.isNextInProgression = isNextInProgression
        self.queueRank = queueRank
    }
}

/// The pure decisions behind Musical Typing's key monitor (m23-ct).
///
/// Deliberately reuses `TransportKeyModifiers` / `TransportKeyResponder` /
/// `TransportKeyWindow` rather than minting a parallel vocabulary —
/// `DeleteKeyMonitorRouting` states the rule and the reason: the app already has
/// exactly one mapper for each of those three live facts, and two enums that
/// agree about everything are two things to keep in step.
public enum MusicalTypingRouting {

    // MARK: - The layout

    // ═══ WHY THIS LAYOUT: IT IS THE ONE THE USER MAY ALREADY KNOW ═══
    //
    // Two rows of a QWERTY keyboard read as two rows of a piano: the home row is
    // the naturals, the number-adjacent row is the accidentals, positioned over
    // the gaps the way real black keys sit. A/W/S/E/D is Logic Pro's Musical
    // Typing and Ableton Live's Computer MIDI Keyboard — the SAME 18 keys in the
    // same places in both, which makes it the closest thing to a standard this
    // control has. Copying it means a user arriving from either product already
    // knows this surface, and a user arriving from neither can look it up.
    //
    //     naturals   A  S  D  F  G  H  J  K  L  ;           C D E F G A B C D E
    //     accidentals   W  E     T  Y  U     O  P           C♯D♯   F♯G♯A♯   C♯D♯
    //
    // Span: 17 semitones (C … E an octave and a third up), so a two-hand chord
    // plus a melody note fits without an octave shift.
    //
    // ⚠️ **THE TABLE IS THE ARCHITECTURE SPIKE'S, NOT THIS FILE'S OPINION**
    // (m23-ct seam correction, 2026-08-29). Logic binds one key more — `'`
    // (`kVK_ANSI_Quote`, 0x27) as +17, F — and it is deliberately NOT here: the
    // spike handed down an explicit 17-entry table and a layout is exactly the
    // kind of thing two people should not each decide. Adding `'` later is purely
    // additive (a new cap, a bumped span, no behaviour change to the other 16),
    // and `layoutOffsetsAreContiguous` will keep it honest when someone does.
    //
    // ⚠️ **Z / X / C / V ARE CONTROLS, NOT NOTES — and that is why the layout
    // stops at ';'.** Logic and Live both reserve exactly these four for
    // octave and velocity, so extending the naturals down onto Z/X/C/V (which a
    // 3-octave layout would want) would collide with the convention AND with
    // ⌘Z/⌘X/⌘C/⌘V's muscle memory. The chord guard already keeps the ⌘ forms
    // safe; keeping the BARE forms as controls keeps them predictable.
    //
    // ⭐⭐ **TAB = SUSTAIN PEDAL SHIPPED AT m34-l. THE PARAGRAPH THAT USED TO
    // STAND HERE IS RETRACTED IN PLACE, NOT DELETED, BECAUSE ITS REASON DIED.**
    // It said: *"Tab = sustain pedal, 1/2 = modulation, 4/5 = pitch bend. All
    // three are CONTINUOUS CONTROLLERS, and the v1 emit target
    // (`ProjectStore.auditionPitches`) carries pitch + velocity and nothing else
    // — there is no controller lane on the audition path to send them down.
    // Adding key bindings that reach nothing would be four more keys claimed for
    // no sound."*
    //
    // **That ceiling is GONE.** m34-f step ② built the controller path the
    // paragraph said did not exist: `ProjectStore` →
    // `AudioEngine.setLiveExpression` → `MIDICaptureSession.ingest`, which
    // SOUNDS a CC and puts it in the rolling take. The pedal reaches it through
    // `ProjectStore.playLiveSustain`. A comment explaining why something is
    // absent, left standing after its reason dies, is how this tree gets
    // confidently wrong readers — so the claim is quoted and struck rather than
    // quietly removed.
    //
    // ⚠️ **STILL DELIBERATELY OUT, AND NOW FOR A DIFFERENT REASON THAN "IT
    // CANNOT BE DONE": 1/2 = modulation and 4/5 = pitch bend.** They *could*
    // ride the same path today. They are not here because a computer keyboard
    // key is a BINARY event and those two are continuous: the pedal is honestly
    // binary (a damper is up or down), while a mod wheel bound to two keys is a
    // ramp with no position — the user cannot see where it is and cannot put it
    // back. Bend is worse: `BreathContour.bendRangeSemitones` can disagree with
    // the sampler's range, so a keyed bend would be a control whose amount
    // depends on a setting elsewhere. Both want a visible continuous surface;
    // the breath pad is one and the controller strip is another. Also out and
    // measured: Logic binds `'` (`kVK_ANSI_Quote`) as +17 — see the layout note
    // above.
    //
    // ⚠️ **TAB IS AppKit's FOCUS-NAVIGATION KEY, AND THE MODE ONLY BORROWS IT.**
    // `decide` refuses it with the mode off (`modeOff`), inside any text-editing
    // responder (`textEditing`), under any ⌘/⌥/⌃/⇧ chord (`chord` — which is
    // what leaves ⇧Tab's reverse focus alone), and in any non-main window
    // (`secondaryWindow`). In every one of those states the event is handed back
    // untouched and Tab moves focus exactly as it always has. What the mode
    // takes is Tab in the main window while Musical Typing is ON and no field
    // has focus — which is the state in which the user is playing an instrument,
    // not filling in a form.

    /// `kVK_Tab` — the sustain pedal (m34-l). ⚠️ **A VIRTUAL KEY CODE, like
    /// every other key here (m23-fi), and for Tab the reason bites hardest:
    /// `NSEvent.characters` for this key is `"\t"`, which is also what ⌃I
    /// produces and what a paste of a tab character carries.** The physical key
    /// is the only unambiguous handle.
    public static let sustainKeyCode: UInt16 = 0x30

    /// `kVK_ANSI_Z` — one octave down.
    public static let octaveDownKeyCode: UInt16 = 0x06
    /// `kVK_ANSI_X` — one octave up.
    public static let octaveUpKeyCode: UInt16 = 0x07
    /// `kVK_ANSI_C` — one step quieter.
    public static let velocityDownKeyCode: UInt16 = 0x08
    /// `kVK_ANSI_V` — one step louder.
    public static let velocityUpKeyCode: UInt16 = 0x09

    /// The 17 note keys, ORDERED BY PITCH (semitone 0…16) rather than by row.
    ///
    /// Pitch order is what the on-screen keyboard draws left-to-right and what a
    /// reader checks the layout against; the physical rows are recoverable from
    /// the labels. Sorted-by-construction, and a test pins that the offsets are
    /// exactly 0…16 with no gap and no repeat — a silently duplicated offset
    /// would make two keys the same note and nothing else would notice.
    public static let noteCaps: [MusicalTypingKeyCap] = [
        MusicalTypingKeyCap(keyCode: 0x00, label: "A", role: .note(semitone: 0)),   // C
        MusicalTypingKeyCap(keyCode: 0x0D, label: "W", role: .note(semitone: 1)),   // C♯
        MusicalTypingKeyCap(keyCode: 0x01, label: "S", role: .note(semitone: 2)),   // D
        MusicalTypingKeyCap(keyCode: 0x0E, label: "E", role: .note(semitone: 3)),   // D♯
        MusicalTypingKeyCap(keyCode: 0x02, label: "D", role: .note(semitone: 4)),   // E
        MusicalTypingKeyCap(keyCode: 0x03, label: "F", role: .note(semitone: 5)),   // F
        MusicalTypingKeyCap(keyCode: 0x11, label: "T", role: .note(semitone: 6)),   // F♯
        MusicalTypingKeyCap(keyCode: 0x05, label: "G", role: .note(semitone: 7)),   // G
        MusicalTypingKeyCap(keyCode: 0x10, label: "Y", role: .note(semitone: 8)),   // G♯
        MusicalTypingKeyCap(keyCode: 0x04, label: "H", role: .note(semitone: 9)),   // A
        MusicalTypingKeyCap(keyCode: 0x20, label: "U", role: .note(semitone: 10)),  // A♯
        MusicalTypingKeyCap(keyCode: 0x26, label: "J", role: .note(semitone: 11)),  // B
        MusicalTypingKeyCap(keyCode: 0x28, label: "K", role: .note(semitone: 12)),  // C
        MusicalTypingKeyCap(keyCode: 0x1F, label: "O", role: .note(semitone: 13)),  // C♯
        MusicalTypingKeyCap(keyCode: 0x25, label: "L", role: .note(semitone: 14)),  // D
        MusicalTypingKeyCap(keyCode: 0x23, label: "P", role: .note(semitone: 15)),  // D♯
        MusicalTypingKeyCap(keyCode: 0x29, label: ";", role: .note(semitone: 16)),  // E
    ]

    /// The five control keys, in the order a legend row reads them.
    ///
    /// ⚠️ **Tab is LAST, and that is the legend's reading order rather than a
    /// ranking**: Z/X/C/V are one contiguous run of physical keys and Tab is
    /// across the keyboard, so putting it between them would draw a legend the
    /// hand cannot follow.
    public static let controlCaps: [MusicalTypingKeyCap] = [
        MusicalTypingKeyCap(keyCode: octaveDownKeyCode, label: "Z", role: .octaveDown),
        MusicalTypingKeyCap(keyCode: octaveUpKeyCode, label: "X", role: .octaveUp),
        MusicalTypingKeyCap(keyCode: velocityDownKeyCode, label: "C", role: .velocityDown),
        MusicalTypingKeyCap(keyCode: velocityUpKeyCode, label: "V", role: .velocityUp),
        MusicalTypingKeyCap(keyCode: sustainKeyCode, label: "⇥", role: .sustainToggle),
    ]

    /// Every key the mode claims — and therefore the complete list of keys it can
    /// take away from anything else. **22 since m34-l** (was 21; Tab is the
    /// twenty-second). ⚠️ The count is asserted in `MusicalTypingRoutingTests`
    /// and quoted in the `unmapped` refusal's doc — a table that grew without
    /// both moving would leave a number nothing checks.
    public static let allCaps: [MusicalTypingKeyCap] = noteCaps + controlCaps

    /// The number of semitones the layout spans (17: C … E, an octave + a third).
    public static let semitoneSpan = noteCaps.count

    /// keyCode → cap, built once. A dictionary rather than a linear scan because
    /// this runs inside an `NSEvent` monitor on every key-down in the app,
    /// including the ~20 of 21 lookups that miss.
    private static let capsByKeyCode: [UInt16: MusicalTypingKeyCap] = {
        Dictionary(uniqueKeysWithValues: allCaps.map { ($0.keyCode, $0) })
    }()

    /// The cap for a physical key, or nil when the key is not part of the layout.
    ///
    /// ⚠️ **NO GUARDS HERE, AND THAT IS LOAD-BEARING FOR KEY-UP.** The guards
    /// below gate note-ON only; a key-up must be able to find its cap even when
    /// the mode has since been switched off, a text field has taken focus, or the
    /// event now names another window. See `MusicalTypingController.releaseKey`.
    public static func cap(forKeyCode keyCode: UInt16) -> MusicalTypingKeyCap? {
        capsByKeyCode[keyCode]
    }

    /// The cap wearing this US-ANSI legend, case-insensitively — the
    /// `debug.musicalTyping` seam's resolver, so a gate names keys the way a
    /// human does ("a", "x", ";") and the TABLE ABOVE does the translation
    /// instead of the gate hardcoding a second copy of the key codes.
    public static func cap(forLabel label: String) -> MusicalTypingKeyCap? {
        let wanted = label.uppercased()
        // m34-l: `"tab"` resolves the ⇥ cap. ⚠️ AN ALIAS FOR THE SEAM AND FOR
        // HUMANS, NOT A SECOND TABLE — it maps onto `sustainKeyCode`, the one
        // constant, so it cannot drift from the cap. It exists because `"⇥"` is
        // painful to type into a gate and easy to mangle in a shell, and a gate
        // that resorted to hardcoding `0x30` would be the second copy of a key
        // code this function exists to prevent.
        if wanted == "TAB" { return cap(forKeyCode: sustainKeyCode) }
        return allCaps.first { $0.label == wanted }
    }

    // MARK: - The decision

    /// May this key-down become a note (or a layout control)?
    ///
    /// GUARD ORDER IS THE DIAGNOSIS, not just the answer — `DeleteKeyMonitorRouting`'s
    /// rule: a caller is told the FIRST refusal that fired, so the order decides
    /// what a red test and a `debug.musicalTyping` echo read.
    ///
    ///   1. **`modeOff` first**, deliberately ahead of `unmapped`. With the mode
    ///      off the honest answer to EVERY key is "the mode is off"; answering
    ///      "unmapped" there would invite the reading that the key was wrong when
    ///      the mode was.
    ///   2. `unmapped` — is this even one of the 22 (`allCaps`)?
    ///   3. `chord` — about the KEYSTROKE.
    ///   4. `textEditing`, 5. `secondaryWindow` — about the CONTEXT.
    ///
    /// Then, and only after every guard has passed, a key-REPEAT is swallowed
    /// inert. It is last on purpose: a repeat arriving while a rename field has
    /// focus must reach the FIELD (which wants the repeats), so it has to be
    /// refused by `textEditing` before this branch can see it.
    ///
    /// - Parameters:
    ///   - keyCode: `NSEvent.keyCode`.
    ///   - modifiers: the four chord modifiers, device-independent. Caps lock, fn
    ///     and numeric-pad flags deliberately do NOT block — caps lock being on
    ///     must not kill a performance, the same rule `TransportKeyRouting` states
    ///     for the space bar.
    ///   - isRepeat: `NSEvent.isARepeat`.
    ///   - responder: the classified first responder of the event's window.
    ///   - window: whether the event targets the app's content window.
    ///   - isEnabled: whether the user has turned Musical Typing ON.
    public static func decide(
        keyCode: UInt16,
        modifiers: TransportKeyModifiers,
        isRepeat: Bool,
        responder: TransportKeyResponder,
        window: TransportKeyWindow,
        isEnabled: Bool
    ) -> MusicalTypingDecision {
        guard isEnabled else { return .passThrough(.modeOff) }
        guard let cap = cap(forKeyCode: keyCode) else { return .passThrough(.unmapped) }
        guard modifiers.isEmpty else { return .passThrough(.chord) }
        guard responder == .none else { return .passThrough(.textEditing) }
        guard window == .main else { return .passThrough(.secondaryWindow) }
        guard !isRepeat else { return .swallowRepeat }
        return .perform(cap.role)
    }

    // MARK: - Base note / octave

    /// The base octave the layout starts on when the app is fresh: **4**, so the
    /// `A` key sounds MIDI 60 — middle C.
    ///
    /// Logic defaults an octave lower (C3). Middle C wins here for one measured
    /// reason rather than taste: MIDI 60 is the pitch this app's own piano-roll
    /// gutter singles out as the landmark (`KeyboardSidebar` draws it bold with an
    /// anchor bar), so the note the `A` key sounds is the note the user can
    /// already find on screen. Rule 6 — a beginner should not have to know what
    /// "C3" means to find the note they just played.
    public static let defaultBaseOctave = 4

    /// How far the layout can be shifted. The bounds are DERIVED, not chosen: the
    /// low end is the lowest base note (`C-1` = MIDI 0) and the high end is the
    /// highest whose top key still lands inside MIDI 0…127 (`C8` = 108, and
    /// 108 + 17 = 125). So every reachable octave sounds every one of its 18 keys
    /// — there is no setting in which some of the layout is silently dead.
    public static let baseOctaveRange = -1...8

    /// The MIDI note the `A` key sounds at this base octave. Scientific pitch, the
    /// repo's one convention (`Fundamental.noteName`: MIDI 60 = "C4").
    public static func baseNote(forOctave octave: Int) -> Int {
        (clampOctave(octave) + 1) * 12
    }

    /// Clamps an octave into `baseOctaveRange` — the ONE home for that bound, so
    /// the controller, the seam and any future arrow-key binding cannot disagree
    /// about how far down the keyboard goes.
    public static func clampOctave(_ octave: Int) -> Int {
        min(baseOctaveRange.upperBound, max(baseOctaveRange.lowerBound, octave))
    }

    /// The MIDI pitch a note key sounds, or nil if it would land outside 0…127.
    ///
    /// Nil is unreachable through `clampOctave` + the 0…16 span (see
    /// `baseOctaveRange`), and it is still here rather than a force-clamp because
    /// a pitch that silently slid to 127 would be a wrong note that sounded — the
    /// worse of the two failures. `nil` means "do not sound anything", which the
    /// controller can act on honestly.
    public static func pitch(semitone: Int, baseOctave: Int) -> Int? {
        let value = baseNote(forOctave: baseOctave) + semitone
        guard AuditionPitchBounds.contains(value) else { return nil }
        return value
    }

    // MARK: - Chord mode's key → scale-degree map (m23-cv)

    /// **Where a key lands when CHORD MODE is on.**
    ///
    /// In note mode a key's `semitone` is an offset above the base note. In chord
    /// mode the same number is read as a POSITION IN THE SCALE instead: key 0 is
    /// the tonic's chord, key 1 the second degree's, and so on past the seventh
    /// into the next run. The physical layout is unchanged and the table above is
    /// still the only place key codes live — this is a second READING of the same
    /// number, not a second table.
    ///
    /// ⭐ **THE TONIC IS ANCHORED TO THE `A` KEY, WHICH IS WHY EVERY KEY IS IN
    /// KEY.** Picking D major does not move the chords onto different physical
    /// keys; it changes what the same keys sound. That is what makes the
    /// Roman-numeral legend meaningful (`A` is always `I`) and it is the model
    /// every scale-locked product in `docs/research/spike-chord-buttons.md` §3
    /// uses — NI's Harmonizer, Push's In-Key grid, Launchkey's Chord Map.
    ///
    /// ⭐⭐ **THE DEGREES SIT ON THE NATURAL KEYS — THE HOME ROW — AND THAT IS
    /// ERGONOMIC, NOT COSMETIC.** The user's chosen mock-up reads
    /// `A S D F G H J` → `I ii iii IV V vi vii`, and the first implementation of
    /// this function did the obvious thing instead: it numbered the 17 keys by
    /// pitch order, which puts the seven degrees on **`A W S E D F T`** — three
    /// of them on the accidental row. That is not the same feature. It makes a
    /// plain diatonic progression a two-row hand dance, in a mode whose entire
    /// promise is *one finger*. Caught by
    /// `MusicalTypingChordModeTests.homeRowIsTheDiatonicSeven`, which is exactly
    /// the mock-up keyed in.
    ///
    /// So: the **ten natural keys** (`A S D F G H J K L ;`) carry the ten chord
    /// degrees — the seven of the scale, then the first three again an octave up.
    ///
    /// ⭐ **AND THE SEVEN ACCIDENTAL KEYS ARE NOT DEAD: EACH ONE COLOURS THE
    /// NATURAL BELOW IT**, flipping that degree between a plain triad and its
    /// seventh chord. `W` beside `A` turns `C` into `Cmaj7`; on a preset that
    /// already voices sevenths it turns `Cmaj7` back into `C`. One sentence to
    /// explain, never ambiguous, and it is precisely the move §2.2's
    /// lo-fi / neo-soul / deep-house row is made of — *"the same progressions
    /// re-voiced with 7ths and 9ths"*. The alternative was seven silent keys in
    /// the middle of a performance surface.
    ///
    /// ⚠️ **DEGREES 3 AND 7 HAVE NO COLOUR KEY, AND THAT IS THE PIANO'S FAULT,
    /// NOT A BUG.** There is no black key between E and F or between B and C, so
    /// `D` (iii) and `J` (vii°) have no accidental above them. Said here rather
    /// than discovered: it is the layout being honest about a real keyboard.
    ///
    /// ⚠️ **THE OCTAVE RUN IS CAPPED AT ONE, AND THAT IS MEASURED RATHER THAN
    /// TIDY.** An uncapped run would put the last keys two octaves up — which on
    /// the piano preset's own register window starts the chord body at G6 and
    /// produced `[64, 88, 91, 95]` for `iii` when it was printed during
    /// development. That is not a register any of these presets was written for.
    public static func chordDegree(semitone: Int)
        -> (degree: Int, octaveShift: Int, addsColour: Bool) {
        let index = max(0, semitone)
        // Walk the layout from the bottom, counting naturals. An accidental
        // inherits the degree of the natural below it — which is the key
        // physically to its lower-left on every piano ever built.
        var degreeCount = 0
        var lastNatural = (degree: 1, octaveShift: 0)
        for semitone in 0...index {
            guard isNaturalSemitone(semitone) else { continue }
            lastNatural = (degree: degreeCount % 7 + 1,
                           octaveShift: min(maxChordOctaveShift, degreeCount / 7))
            degreeCount += 1
        }
        return (degree: lastNatural.degree, octaveShift: lastNatural.octaveShift,
                addsColour: !isNaturalSemitone(index))
    }

    /// Whether this layout offset lands on a WHITE key of the strip's piano — the
    /// same seven pitch classes `MusicalKeyboardGeometry.isBlackKey` uses, read
    /// from the other side so the two cannot disagree about which key is which.
    public static func isNaturalSemitone(_ semitone: Int) -> Bool {
        let pitchClass = ((semitone % 12) + 12) % 12
        return [0, 2, 4, 5, 7, 9, 11].contains(pitchClass)
    }

    /// How far the chord layout may climb above the base run. See `chordDegree`.
    public static let maxChordOctaveShift = 1

    // MARK: - Velocity

    /// One press of `C` / `V`. Eight steps spans the usable range, which is what
    /// makes the control worth a key: 16 is a whisper, 127 is a slam, and a
    /// player can get between them in under a second.
    public static let velocityStep = 16

    /// Steps the velocity, clamped to the audition path's own 1…127.
    ///
    /// ⚠️ Clamped, NOT wrapped. A velocity that wrapped from 127 to 16 would turn
    /// one key-press too many into a silent-sounding note in the middle of a
    /// performance — the class of surprise a live control must never have.
    public static func steppedVelocity(_ velocity: Int, by steps: Int) -> Int {
        let raw = velocity + steps * velocityStep
        return min(AuditionVelocityBounds.upperBound,
                   max(AuditionVelocityBounds.lowerBound, raw))
    }

    // MARK: - Target readiness

    /// Whether Musical Typing can actually make a sound right now, and if not,
    /// why — so the on-screen indicator can SAY it.
    ///
    /// ⭐ **THIS TYPE IS THE ANSWER TO THIS TREE'S CHARACTERISTIC FAILURE MODE.**
    /// M27's meta-finding: three of its four blockers failed SILENTLY, returning
    /// something that looked like a valid answer. A mode lamp that reads ON while
    /// every key is silently dead is exactly that shape — so the lamp renders from
    /// this enum, never from `isEnabled` alone.
    public enum TargetState: String, Equatable, Sendable, CaseIterable {
        /// An instrument track is active and audition is allowed — keys sound.
        case ready
        /// No track is active at all. Click a track first.
        case noTrack = "no-track"
        /// The active track is an audio or bus track, which has no instrument to
        /// play (`ProjectStore.validateAuditionTarget` refuses it).
        case notInstrument = "not-instrument"
        /// ⭐ **A take is running AND this track is armed — you are RECORDING.**
        /// Keys sound and every edge is ingested into the rolling take
        /// (`ProjectStore.playLiveNotes`, whose `captureIntoTake` is exactly
        /// `isRecording && isArmed && kind == .instrument`).
        ///
        /// ⚠️ **THIS IS A STATUS, NOT A REFUSAL — IT USED TO BE THE OPPOSITE.**
        /// Until the engine half of m23-ct landed, a single `.recording` case
        /// meant *blocked*: the surface sat on `auditionPitches`, which throws
        /// `transportBusy` mid-take by design. That ceiling is GONE. If you are
        /// reading this expecting "typing cannot be recorded", that claim is
        /// dead — it now can, and this is the case that says so.
        case recordingArmed = "recording-armed"
        /// ⛔ **A take is running and this track is NOT armed: you will hear
        /// yourself, and NOTHING will be kept.** The genuine footgun of the
        /// whole feature, because it is indistinguishable by ear from a
        /// successful take — the notes sound exactly the same, the transport
        /// looks exactly the same, and the clip comes back empty. It is a
        /// SOUNDING state (the keys work), so it must never be modelled as a
        /// refusal; it is a state the indicator has to SAY.
        case recordingUnarmed = "recording-unarmed"
        /// The app-wide note-preview switch (`PanelLayoutStore.auditionEnabled`,
        /// "ONE value for both audition surfaces") is off, so every audition
        /// surface is muted — this one included.
        case previewOff = "preview-off"

        /// Whether a key press can make a sound in this state.
        ///
        /// ⛔⛔ **THE CONTROLLER GATES ON THIS, NOT ON `== .ready`.** Both
        /// recording states SOUND — one is captured and one is not — so a
        /// `.ready`-only gate would silence the user at exactly the moment they
        /// are trying to record, which is the bug the engine half exists to
        /// remove. The three false cases are the three genuine refusals.
        public var canSound: Bool {
            switch self {
            case .ready, .recordingArmed, .recordingUnarmed: return true
            case .noTrack, .notInstrument, .previewOff: return false
            }
        }

        /// ⭐ **THE HONESTY LIGHT'S PREDICTION.** True only where the app
        /// believes this performance is being kept. ⚠️ It is a PREDICTION and
        /// must be presented beside the engine's own answer
        /// (`LivePlayResult.isRecording`), never instead of it: the engine
        /// narrows the verdict further (is a take actually capturing MIDI, does
        /// a session exist, is CoreMIDI up) and only it can see that.
        public var isCapturing: Bool { self == .recordingArmed }
    }

    /// Resolves the target state. Pure, so the indicator's wording is testable
    /// without a window.
    ///
    /// ORDER IS THE DIAGNOSIS again, and here it is ordered by WHAT THE USER
    /// SHOULD FIX FIRST: pick a track, then pick the right kind of track, then
    /// turn preview back on. Reporting `previewOff` to someone who has not
    /// selected a track yet would send them to the wrong switch.
    ///
    /// ⛔⛔ **EVERY REFUSAL IS CHECKED BEFORE EITHER RECORDING STATUS, AND THAT
    /// ORDER INVERTED WHEN THE ENGINE HALF LANDED.** `previewOff` used to sit
    /// BELOW `recording`, which was correct while `recording` was itself a
    /// refusal — the earlier of two refusals won and both meant silence. Now
    /// the recording cases SOUND, so leaving the old order would report
    /// `recordingArmed` — the honesty light ON — over keys that are silently
    /// dead. **A lamp that reads "you are recording" over silence is exactly
    /// the failure this whole type was written to prevent.** Refusals first,
    /// statuses second, permanently.
    ///
    /// - Parameter isArmed: whether the ACTIVE track is record-armed. Only
    ///   consulted while a take is running; it is what separates *your
    ///   performance is being kept* from *you will hear this and lose it*.
    public static func targetState(hasTrack: Bool,
                                   isInstrumentTrack: Bool,
                                   isRecording: Bool,
                                   isArmed: Bool,
                                   auditionEnabled: Bool) -> TargetState {
        guard hasTrack else { return .noTrack }
        guard isInstrumentTrack else { return .notInstrument }
        guard auditionEnabled else { return .previewOff }
        guard !isRecording else { return isArmed ? .recordingArmed : .recordingUnarmed }
        return .ready
    }
}

// MARK: - Bounds mirrored from the emit target

/// The pitch range the emit target accepts (`AuditionController.pitchRange`).
///
/// ⚠️ **MIRRORED, NOT RE-DECIDED — and stated here so the next reader does not
/// "fix" the duplication the wrong way.** `DAWAppKit` depends on `DAWCore`, so
/// these could read `AuditionController` directly; they are named constants
/// instead because the CONTROLLER must keep working when the sink is swapped for
/// the live-MIDI one, which has its own bounds.
///
/// ⚠️ **THE SWAP THIS ANTICIPATED HAS HAPPENED (m23-ct join).** The shipped
/// sink pushes at `LivePlayController` now, so
/// `MusicalTypingRoutingTests.mirroredBoundsHaveNotDrifted` pins these against
/// THAT — and keeps the `AuditionController` comparison beside it, because
/// `ProjectStore` arbitrates between the two and a silent divergence between
/// them is the thing nothing else would catch. The `Audition…` NAMES here are
/// historical, not a claim about which sink is wired; the test is where the
/// answer to that lives.
public enum AuditionPitchBounds {
    public static let lowerBound = 0
    public static let upperBound = 127
    public static func contains(_ pitch: Int) -> Bool {
        (lowerBound...upperBound).contains(pitch)
    }
}

/// The velocity range the emit target accepts (`AuditionController.velocityRange`).
public enum AuditionVelocityBounds {
    public static let lowerBound = 1
    public static let upperBound = 127
}
