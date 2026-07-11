import Foundation
import Observation

/// A stable identifier for every control that carries an "Explain this" card
/// (M8 ex-a mechanism, ex-b coverage; VISION.md pillar 4, docs/DESIGN-LANGUAGE.md
/// "Explain this").
///
/// String-raw so the `debug.explainMode {focus}` capture-staging command can name
/// a control on the wire (`ExplainID(rawValue:)`) and so `ExplainCatalog` can be
/// keyed headlessly here in DAWAppKit — the curated copy stays UI-free and
/// unit-testable (the `PanelDensity` precedent). `CaseIterable` so the catalog
/// completeness test can assert every registered id has an entry.
///
/// Coverage is now app-wide (ex-b): the transport bar, the whole mixer console
/// (every channel + bus strip + the master), the piano roll, the arrange surface
/// (track rows + clip body), the AI panels, and Settings. SHARED controls carry
/// ONE id reused wherever they render (the SIMPLE/PRO chip → `panelDensity`; a
/// track row's Mute/Solo/Arm → the mixer's `mixerMute`/`mixerSolo`/`mixerArm`) —
/// never two entries with near-identical copy. Per-instance frame anchoring
/// (Components/Explain.swift) makes a shared id land on whichever instance is
/// hovered. Every NEW control ships with an entry from here on.
public enum ExplainID: String, CaseIterable, Sendable {
    // MARK: Transport bar
    case transportReturnToZero
    case transportPlay
    case transportRecord
    case transportLoop
    case transportPunch
    case transportClick
    case transportPosition
    case transportTime
    case transportTempo
    case transportTestTone
    case transportMasterFader
    /// The EXPORT affordance in the transport bar's right region (M8 ob-b) — bounces
    /// the whole mix to an audio file. A core beginner action, so it shows in both
    /// Simple and Pro transport modes.
    case transportExport
    /// The session vibe meter — the glowing orb near the master cluster (vm-b).
    /// Read-only status chrome, so it shows in both Simple and Pro transport modes.
    case vibeMeter

    // MARK: Shared — panel density
    /// The SIMPLE / PRO density chip (`SimpleProToggle`). ONE id shared across all
    /// four panels it renders on — the transport bar, arrange, mix, and the piano
    /// roll — because the copy explains the density concept, not any one panel;
    /// per-instance frames anchor the card wherever it's hovered.
    case panelDensity

    // MARK: Mixer channel / bus strip
    case mixerKindBadge
    case mixerInserts
    case mixerSends
    case mixerOutput
    case mixerPan
    /// The long-throw fader beside its live meter and dB readout (one card).
    case mixerFader
    case mixerMute
    case mixerSolo
    case mixerArm

    // MARK: Mixer master strip
    /// The master strip's fader + stereo output meter (one card) — the final mix
    /// stage. Distinct from `transportMasterFader` (the bar's mini master control).
    case mixerMaster

    // MARK: Piano roll
    case pianoRollSnap
    /// The note grid editor surface (a Canvas; one card summarizes its gestures —
    /// the clip-body honest-scope precedent).
    case pianoRollGrid
    case pianoRollVelocity

    // MARK: Arrange (timeline + sidebar)
    case arrangeSnap
    case arrangeAddTrack
    /// A sidebar track row's identity (its name + kind icon).
    case trackRowIdentity
    /// A timeline clip's body (a Canvas/gesture block; one card summarizes its
    /// move/trim/fade/split affordances — the honest-scope rule for Canvas chrome).
    case clipBlock

    // MARK: AI panels (violet affordances — Rule 3)
    case aiCopilot
    case aiSketchpad
    case aiFix
    case copilotInput
    case sketchpadStyle
    case sketchpadLyrics
    case sketchpadLength
    case sketchpadGenerate
    /// The "Use a Template" button beside GENERATE (M8 ob-b) — the instant, keyless
    /// song-scaffold path. NOT an AI affordance (a scaffold isn't generated audio),
    /// so its copy and chrome stay neutral, not violet.
    case sketchpadTemplate
    case lyricsWorkshop
    case clipFixRegion
    case clipFixStrength
    case clipFixGo

    // MARK: Settings
    case settingsGear
    /// A provider's key row in Settings (shared across every provider row).
    case settingsApiKey
}

/// One control's curated explanation copy: a short control name and 2–3
/// beginner-readable sentences (WHAT it does + WHEN you'd reach for it). No jargon
/// without a plain-language gloss — the style rules are enforced by
/// `ExplainCatalogTests` (docs/DESIGN-LANGUAGE.md "Explain this").
public struct ExplainEntry: Sendable, Equatable {
    /// The control's name — the card's header (SF Pro semibold). Kept short
    /// (≤ 24 chars) so it reads as a title, not a sentence.
    public let title: String
    /// 2–3 short plain-language sentences. 40–280 chars, ends on a full stop /
    /// `!` / `?`, and avoids raw unit jargon (dB / Hz / …) a newcomer wouldn't know.
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

/// The curated plain-language explanation copy for every registered control (M8
/// ex-a mechanism, ex-b coverage). Headless (DAWAppKit) so previews, the real app,
/// and the style-rule tests all read one source of truth. Organized with a MARK
/// section per surface; every `ExplainID` has an entry (the completeness test) and
/// a count-floor test fails a silent shrink. Every NEW control ships with an entry.
public enum ExplainCatalog {
    public static let entries: [ExplainID: ExplainEntry] = [
        // MARK: Transport bar
        .transportReturnToZero: ExplainEntry(
            title: "Return to Start",
            body: "Jumps the playhead back to the very beginning of the song. Use it to replay from the top after a take, or to line up before you record."),
        .transportPlay: ExplainEntry(
            title: "Play / Pause",
            body: "Starts and stops playback from wherever the playhead sits. Press it to hear your song; press again to pause right where you are."),
        .transportRecord: ExplainEntry(
            title: "Record",
            body: "Captures new sound or notes onto any armed track. Arm a track first, set the playhead, then press this to lay down a take."),
        .transportLoop: ExplainEntry(
            title: "Loop",
            body: "Repeats one section over and over so you can practice or refine it. Turn it on to cycle the current region until you switch it off."),
        .transportPunch: ExplainEntry(
            title: "Punch Recording",
            body: "Records only inside a set window and leaves everything outside it untouched. Use it to redo one phrase without risking the rest of a good take."),
        .transportClick: ExplainEntry(
            title: "Metronome Click",
            body: "Plays a steady beat that keeps your timing honest while you record. Turn it on for a click track, then off once you are locked into the groove."),
        .transportPosition: ExplainEntry(
            title: "Song Position",
            body: "Shows where the playhead sits in bars and beats — the musical map of your song. Read it to know which part is playing or ready to record."),
        .transportTime: ExplainEntry(
            title: "Playback Time",
            body: "Shows the playhead's spot as elapsed minutes and seconds. Handy when real-world length matters, like fitting a video or a radio edit."),
        .transportTempo: ExplainEntry(
            title: "Tempo",
            body: "Sets how fast the song plays, counted in beats per minute. Nudge it up for a more energetic feel, or down for a slower, calmer groove."),
        .transportTestTone: ExplainEntry(
            title: "Test Tone",
            body: "Plays a steady reference note so you can confirm sound is actually reaching your speakers or headphones. Reach for it when you hear nothing and want to check your setup."),
        .transportMasterFader: ExplainEntry(
            title: "Master Volume",
            body: "Sets the overall loudness of everything you hear, mixed together. Drag it down when the whole song is too loud; double-click to reset it to normal."),
        .transportExport: ExplainEntry(
            title: "Export Song",
            body: "Saves your finished song as an audio file you can share or keep. Pick a spot to save it, and the whole mix is rendered down into one clean file."),
        .vibeMeter: ExplainEntry(
            title: "Vibe Meter",
            body: "A living glow that shows the feel of your whole mix at a glance. It burns warm and low when the sound is deep and bassy, turns cool and airy when it is bright, and settles to a dim ember when things go quiet."),

        // MARK: Shared — panel density
        .panelDensity: ExplainEntry(
            title: "Simple / Pro",
            body: "Switches this panel between a beginner-friendly set of controls and the full professional layout. Start on Simple, then flip to Pro whenever you want the extra tools."),

        // MARK: Mixer channel / bus strip
        .mixerKindBadge: ExplainEntry(
            title: "Track Type",
            body: "A colored tag showing what this channel carries — recorded audio, a software instrument, or a bus that groups other tracks. It tells you at a glance how the channel behaves."),
        .mixerInserts: ExplainEntry(
            title: "Inserts",
            body: "Effects that reshape this track's sound in order, top to bottom — think reverb, compression, or delay. Add one to color the tone, or bypass it to compare before and after."),
        .mixerSends: ExplainEntry(
            title: "Sends",
            body: "Taps a copy of this track off to a shared effect bus, like one reverb feeding many channels. Raise a send to add more of that shared effect to this track."),
        .mixerOutput: ExplainEntry(
            title: "Output Routing",
            body: "Chooses where this track's sound flows next — straight to the main mix, or into a group bus. Route related tracks to one bus so you can control them together."),
        .mixerPan: ExplainEntry(
            title: "Pan",
            body: "Places the track across the stereo field, from far left to far right. Spread instruments apart so each one owns its own space and the mix feels wider."),
        .mixerFader: ExplainEntry(
            title: "Volume Fader",
            body: "Sets how loud this track sits in the mix, with a live meter beside it showing its signal. Drag up to bring the part forward, down to tuck it behind the others."),
        .mixerMute: ExplainEntry(
            title: "Mute",
            body: "Silences this track without deleting anything. Use it to drop a part out of the mix so you can hear how everything else sounds without it."),
        .mixerSolo: ExplainEntry(
            title: "Solo",
            body: "Isolates this track by silencing every other one, so you hear it alone. Great for zeroing in on a single part to fix a small detail."),
        .mixerArm: ExplainEntry(
            title: "Record Arm",
            body: "Readies this track to receive a recording. Arm it before you press Record so your take lands here; leave it off to protect the track from being overwritten."),

        // MARK: Mixer master strip
        .mixerMaster: ExplainEntry(
            title: "Master Strip",
            body: "The final stage every track flows into before it reaches your speakers. Watch its stereo meter while you mix — if the bars keep slamming the top, pull the master down so the sound never distorts."),

        // MARK: Piano roll
        .pianoRollSnap: ExplainEntry(
            title: "Note Snap",
            body: "Locks where notes land onto a tidy grid — whole beats, half beats, or finer. Keep it tight while you rough parts in, then loosen it when you want a note to sit a little off the grid."),
        .pianoRollGrid: ExplainEntry(
            title: "Note Editor",
            body: "The grid where you draw a melody: double-click an empty spot to add a note, drag a note to move it, and drag its right edge to change how long it lasts. Higher notes sit higher up."),
        .pianoRollVelocity: ExplainEntry(
            title: "Velocity Lane",
            body: "Sets how hard each note is struck, which mostly shapes how loud and punchy it sounds. Drag a bar up for an accent or down for a softer touch, so the part feels more human."),

        // MARK: Arrange (timeline + sidebar)
        .arrangeSnap: ExplainEntry(
            title: "Grid Snap",
            body: "Lines up clip edits — moving, trimming, and splitting — to a musical grid so parts stay in time. Set it to Bar for big blocks, or a finer value for detailed edits."),
        .arrangeAddTrack: ExplainEntry(
            title: "Add Track",
            body: "Creates a new empty track to hold a recording, an instrument, or a generated part. Add one whenever you want to layer another sound on top of what you already have."),
        .trackRowIdentity: ExplainEntry(
            title: "Track",
            body: "A single lane of your song. The icon shows what it carries — recorded audio, a software instrument, or a group — and the name is yours to rename; its clips live in the timeline to the right."),
        .clipBlock: ExplainEntry(
            title: "Clip",
            body: "A block of sound or notes on the timeline. Drag it to move it in time; in Pro you can also drag its edges to trim, its top corners to fade, and double-click to split it in two."),

        // MARK: AI panels (violet affordances — Rule 3)
        .aiCopilot: ExplainEntry(
            title: "AI Copilot",
            body: "Opens a chat where you ask for changes in plain language and the AI makes them for you, one undoable step at a time. Great for quick jobs like adding a drum track or setting the tempo."),
        .aiSketchpad: ExplainEntry(
            title: "AI Sketchpad",
            body: "Opens the panel that generates a whole song from a short description. Describe the vibe, add optional lyrics, then audition a few takes and import the one you like into your project."),
        .aiFix: ExplainEntry(
            title: "Fix with AI",
            body: "Sends a slice of the selected audio clip to the AI to clean up or reshape. It comes back as a new take you can keep or discard, so your original recording is never overwritten."),
        .copilotInput: ExplainEntry(
            title: "Ask the Copilot",
            body: "Type what you want done here and press send. The copilot reads your whole project, makes the change, and shows each step — so you can undo anything you did not want."),
        .sketchpadStyle: ExplainEntry(
            title: "Style",
            body: "Describe the sound you want in a few words — the genre, the mood, the instruments. The more vivid the description, the closer the generated song lands to what you are imagining."),
        .sketchpadLyrics: ExplainEntry(
            title: "Lyrics",
            body: "Optional words for the AI to sing. Leave it blank for an instrumental, or type verses and choruses using the section tags to shape how the song is built."),
        .sketchpadLength: ExplainEntry(
            title: "Song Length",
            body: "Sets how long the generated song should be, in seconds. Keep it short for a quick idea to audition, or longer once you have found a direction worth hearing in full."),
        .sketchpadGenerate: ExplainEntry(
            title: "Generate",
            body: "Kicks off the AI and produces a few candidate songs from your description. Each one appears below, where you can preview it and import the take you like best into the timeline."),
        .sketchpadTemplate: ExplainEntry(
            title: "Use a Template",
            body: "Starts you off with a ready-made song layout — tracks and sections already laid out — with no waiting and no key needed. A quick way to get going before you generate anything."),
        .lyricsWorkshop: ExplainEntry(
            title: "Write with AI",
            body: "Drafts and refines lyrics for you, shaped around a theme and the song's key. Write a first version, nudge it with plain-language notes, then apply the finished words into the lyrics box."),
        .clipFixRegion: ExplainEntry(
            title: "Region to Fix",
            body: "The start and end points, counted in beats, of the part you want the AI to repair. Narrow it to just the phrase that needs work, so the rest of the take stays exactly as recorded."),
        .clipFixStrength: ExplainEntry(
            title: "Fix Strength",
            body: "How boldly the AI reworks the region. Subtle stays very close to your take, Bold rebuilds it more freely, and Balanced sits in the middle — a good place to start."),
        .clipFixGo: ExplainEntry(
            title: "Fix This Region",
            body: "Sends the chosen region to the AI and brings the repair back as a new take lane over just that part. Your original stays untouched, so you can compare the two and keep the better one."),

        // MARK: Settings
        .settingsGear: ExplainEntry(
            title: "Settings",
            body: "Opens the panel where you paste the keys that unlock the AI features. Everything else works without them; the keys switch on generation, the copilot, and lyric writing."),
        .settingsApiKey: ExplainEntry(
            title: "API Key",
            body: "A private password from an AI provider that turns on its features inside the app. It is saved in your Mac's Keychain, stays on this computer, and is never shown back to you in full."),
    ]

    /// The curated entry for `id`, or nil if none is registered yet (an unregistered
    /// control simply shows no card — the completeness test guarantees every
    /// `ExplainID` has one).
    public static func entry(for id: ExplainID) -> ExplainEntry? {
        entries[id]
    }
}

/// App-level explain-mode state (M8 ex-a): whether the violet "?" EXPLAIN overlay
/// is active, plus an optional control forced-open for capture staging.
///
/// Explain mode is a transient session aid — it is NOT persisted (unlike panel
/// density, which is a sticky preference). `@Observable` so the header EXPLAIN chip
/// and the overlay coordinator re-render when the mode flips. `@MainActor` because
/// it is UI-state, driven by the header chip, the Esc key, and the debug-tier
/// `debug.explainMode` staging command.
@MainActor
@Observable
public final class ExplainModel {
    /// Whether explain mode is active. Default off — a newcomer opts in.
    public private(set) var isActive: Bool = false

    /// A control programmatically presented for capture staging
    /// (`debug.explainMode {focus}`) — the wire cannot synthesize a hover, so this
    /// forces one control's card open. nil in normal use (hover drives
    /// presentation then); always cleared when explain mode turns off.
    public var focusedForCapture: ExplainID?

    /// Which rendered INSTANCE of `focusedForCapture` the card anchors on (0-based,
    /// tree order; nil = the first). Lets a capture stage a NON-first copy of a
    /// repeated control (`debug.explainMode {focus, instance}`) — the wire can't
    /// hover a specific strip/row. Capture staging only; cleared with the mode.
    public var focusedInstance: Int?

    public init() {}

    /// Flips explain mode; turning it off also drops any forced capture focus.
    public func toggle() { setActive(!isActive) }

    /// Sets explain mode on/off; turning it off clears the capture focus so a
    /// stale card can never linger after the mode ends.
    public func setActive(_ active: Bool) {
        isActive = active
        if !active { focusedForCapture = nil; focusedInstance = nil }
    }
}
