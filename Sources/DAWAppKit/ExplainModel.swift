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
    /// The engine-notices warning chip (m15-e, audit F6) — the amber warning that
    /// appears in the transport bar when a sound played on time but not exactly as
    /// set (a fade/envelope that couldn't be prepared in time, a stretch still
    /// rendering). Read-only diagnostic status chrome, shown in BOTH densities.
    case transportEngineNotices

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
    /// The master strip's Inserts section (m13-d, Pro only) — the effect chain on
    /// the whole mix, post-fader (the last stop before the speakers). Distinct
    /// from `mixerInserts` (a single track's chain) and `mixerMaster` (the fader).
    case mixerMasterInserts
    /// The master strip's Volume Automation section (m15-c, Pro only) — the drawn
    /// fade/level-ride curve on the whole mix's master volume. Distinct from
    /// `mixerMaster` (the manual fader) and `mixerMasterInserts` (the effect chain);
    /// there is no track-lane counterpart to point at (track automation lives in the
    /// arrange timeline, not the mixer, and carries no Explain card today).
    case masterAutomation

    // MARK: Piano roll
    case pianoRollSnap
    /// The note grid editor surface (a Canvas; one card summarizes its gestures —
    /// the clip-body honest-scope precedent).
    case pianoRollGrid
    case pianoRollVelocity
    /// The Pro controller strip under the velocity lane (m16-b4) — bend, mod wheel,
    /// sustain, and other CCs as a stepped value line.
    case pianoRollControllers
    /// The insert-/delete-bar control cluster in the header (beta m10-h) — one card
    /// for the whole time-range affordance.
    case pianoRollBarOps

    // MARK: Arrange (timeline + sidebar)
    case arrangeSnap
    case arrangeAddTrack
    /// A sidebar track row's identity (its name + kind icon).
    case trackRowIdentity
    /// A timeline clip's body (a Canvas/gesture block; one card summarizes its
    /// move/trim/fade/split affordances — the honest-scope rule for Canvas chrome).
    case clipBlock
    /// The arrange ruler's loop surface (beta m10-g) — a Canvas/gesture band; one
    /// card summarizes its sketch/resize/move/toggle/seek affordances (the
    /// clip-body honest-scope precedent). Distinct from `.transportLoop` (the chip):
    /// the ruler is the direct-manipulation region, the chip is the on/off twin.
    case loopRuler
    /// The crossfade marker over two overlapping audio clips (m11-d) — the "X"
    /// wedge where one clip fades out as the next fades in. Anchors the card that
    /// explains a crossfade; the "Crossfade with Next…" clip menu creates it. NOT
    /// an AI surface — no violet.
    case crossfade
    /// The per-clip GAIN ENVELOPE overlay on an audio clip (m13-e) — the line of
    /// glowing breakpoint dots that rides the clip's volume up and down over
    /// time. A Canvas/gesture overlay; one card summarizes its add/move/delete
    /// affordances (the clip-body honest-scope precedent). Pro density only —
    /// Simple hides it. NOT an AI surface — no violet.
    case clipGainEnvelope

    // MARK: Instrument picker (m10-n-3)
    /// The instrument CHIP on an instrument track's header + mixer strip — shows
    /// the track's current sound and opens the picker. ONE shared id across both
    /// renders (per-instance anchoring). NOT an AI surface — no violet.
    case trackInstrumentChip
    /// The picker's Sound Banks section (the General MIDI + imported/scanned banks
    /// + the "Add SoundFont…" import affordance).
    case instrumentPickerSoundBanks
    /// The picker's Audio Units section (installed AU instrument plugins).
    case instrumentPickerAudioUnits

    // MARK: Quantize & groove (m11-a)
    /// The QUANTIZE affordance (piano-roll header + arrange clip menu) that opens
    /// the timing-tightening flow. NOT an AI surface — no violet.
    case quantize
    /// The grid picker in the quantize panel (1/4 … 1/16 triplet).
    case quantizeGrid
    /// The strength slider — how far notes move toward the grid.
    case quantizeStrength
    /// The swing slider — the MPC shuffle amount (inert while a groove is chosen).
    case quantizeSwing
    /// The "also snap note ends" toggle (MIDI only).
    case quantizeEnds
    /// The groove picker section — built-in swings + saved templates + the
    /// extract-from-clip affordance. One card for the whole groove surface.
    case quantizeGroove

    // MARK: Undo history (m11-b)
    /// The HISTORY affordance (arrange toolbar) + the panel it opens: the list of
    /// past edits you can step back to and undone edits you can step forward to.
    /// One card for the whole surface (the chip and the panel share it — the
    /// loop-ruler honest-scope precedent). NOT an AI surface — no violet.
    case editHistory

    // MARK: Session markers (m11-c)
    /// The arrange ruler's marker lane (m11-c) — named song-section flags you can
    /// add, drag, rename, and click to jump to. One card for the whole surface (a
    /// Canvas/gesture lane; the loop-ruler honest-scope precedent). Distinct from
    /// `.loopRuler` (the loop band, one strip up). NOT an AI surface — no violet.
    case sessionMarkers

    // MARK: Track bounce-in-place (m11-e)
    /// The "Bounce in Place" track-header menu action (m11-e) — renders a track
    /// down to a fresh audio track+clip so an instrument part becomes plain
    /// audio. One card for the action. NOT an AI surface — no violet.
    case bounceInPlace

    // MARK: Tempo lane (m12-d)
    /// The arrange ruler's TEMPO LANE (m12-d) — the strip of tempo sections and
    /// time-signature flags you can drag, scrub, add, and remove. One card for
    /// the whole surface (a Canvas/gesture lane; the loop-ruler honest-scope
    /// precedent). NOT an AI surface — no violet.
    case tempoMap

    // MARK: Sidechain key (m12-g)
    /// The KEY picker on a compressor/gate insert row (m12-g) — chooses which
    /// other track drives this effect (the classic ducking/pump), with a lit
    /// KEY badge showing the current source and a clear affordance. One card for
    /// the whole picker. Mixer inserts are Pro-only, so this shows in Pro only.
    /// NOT an AI surface — no violet.
    case sidechain

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
    /// The Agent Connection section in Settings (beta m10-l) — the control-plane
    /// URL + port surface for hooking an AI agent up to the app.
    case settingsConnection
    /// The Copilot round-budget field in Settings (beta m10-m) — caps how many
    /// tool rounds one Copilot reply may take.
    case copilotMaxRounds
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
            body: "Captures new sound or notes onto any armed track. Arm a track first, set the playhead, then press this to lay down a take. With LOOP on it jumps to the loop start and each pass stacks a fresh take to pick from."),
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
        .transportEngineNotices: ExplainEntry(
            title: "Playback Notices",
            body: "A warning that shows up when a sound played on time but not exactly as you set it — usually a fade or effect that could not be prepared quickly enough. Click it to see what happened; nothing in your project was changed."),

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
        .mixerMasterInserts: ExplainEntry(
            title: "Master Inserts",
            body: "Effects that shape the whole mix at once, sitting after the master fader — the last stop before your speakers. Add gentle tone-shaping and a limiter here to polish the final sound and stop the loudest moments from distorting."),
        .masterAutomation: ExplainEntry(
            title: "Master Volume Automation",
            body: "Draws the master volume as a curve over time — the way to fade the whole mix out at the end of a song or ride the level through a section. Add points and drag them: higher is louder. This fade shapes what you hear but is left out of exported stems."),

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
        .pianoRollControllers: ExplainEntry(
            title: "Controller Strip",
            body: "Draws performance moves that ride under the notes — the mod wheel, sustain pedal, pitch bend, and other controls. Pick a lane, then drag to draw a stepped line; each point holds until the next one."),
        .pianoRollBarOps: ExplainEntry(
            title: "Insert / Delete Bar",
            body: "Adds or removes a whole bar at the marked spot. Insert opens an empty bar and slides the rest of the part later; delete takes that bar out and pulls everything after it back to close the gap."),

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
        .loopRuler: ExplainEntry(
            title: "Loop Region",
            body: "The strip along the top of the timeline where you mark a section to repeat. Drag across it to set the loop, click inside to turn looping on or off, or click an empty spot to jump the playhead there."),
        .crossfade: ExplainEntry(
            title: "Crossfade",
            body: "The blend where two audio clips overlap: the first fades out as the next fades in, so the join sounds smooth with no click or bump. Right-click a clip and choose Crossfade with Next to create one; drag either clip apart to undo it."),
        .clipGainEnvelope: ExplainEntry(
            title: "Clip Gain Envelope",
            body: "A volume line you draw across an audio clip to make it swell and dip over time — ride a chorus louder, or duck one word. Click the clip body to add a dot, drag a dot to move it, double-click a dot to remove it. It stacks on top of the clip's fixed level and fades."),

        // MARK: Instrument picker (m10-n-3)
        .trackInstrumentChip: ExplainEntry(
            title: "Instrument",
            body: "Shows the sound this track plays and lets you change it — a built-in synth, a ready-made instrument set, or a plugin. Click it to pick a different sound; the notes you have written stay exactly the same."),
        .instrumentPickerSoundBanks: ExplainEntry(
            title: "Sound Banks",
            body: "Ready-to-play instrument sounds. General MIDI gives you 128 classic instruments — piano, strings, brass, drums — with nothing to download. You can also add your own SoundFont bank files to grow the list."),
        .instrumentPickerAudioUnits: ExplainEntry(
            title: "Audio Units",
            body: "Instrument plugins installed on your Mac, from Apple or other makers. Pick one to play this track through it; its own settings window opens from the plugin button on the track and mixer strip."),

        // MARK: Quantize & groove (m11-a)
        .quantize: ExplainEntry(
            title: "Quantize",
            body: "Nudges your notes onto a tidy timing grid, so a part that was played a little loose lands right in the pocket. Choose how fine the grid is and how strongly to pull, then apply."),
        .quantizeGrid: ExplainEntry(
            title: "Quantize Grid",
            body: "Sets the timing grid your notes snap to — whole beats for big moves, or finer divisions like eighths and sixteenths for detailed parts. Pick the smallest division your part actually uses."),
        .quantizeStrength: ExplainEntry(
            title: "Quantize Strength",
            body: "Controls how far each note is pulled toward the grid. All the way tightens the timing completely; part way keeps some of the human feel of the original take while still cleaning it up."),
        .quantizeSwing: ExplainEntry(
            title: "Swing",
            body: "Adds a relaxed shuffle by nudging the in-between notes a touch late — the classic bounce behind hip-hop and jazz. Slide it up for more swing; it switches off when you choose a saved groove instead."),
        .quantizeEnds: ExplainEntry(
            title: "Snap Note Ends",
            body: "Also lines up where each note stops, not just where it starts. Turn it on when you want the note lengths tidy too; leave it off to keep the original lengths and only fix the starts."),
        .quantizeGroove: ExplainEntry(
            title: "Groove",
            body: "A feel borrowed from elsewhere — a swing preset, or one you extract from a clip — that shapes exactly how the notes sit. Pick one to stamp that groove onto this part; a chosen groove sets the grid and swing for you."),

        // MARK: Undo history (m11-b)
        .editHistory: ExplainEntry(
            title: "Edit History",
            body: "Shows every change you have made as a list you can step through. Click a past edit to jump back to it, or a step above the marker to move forward again. Your project rewinds or replays one edit at a time, so nothing is ever lost."),

        // MARK: Session markers (m11-c)
        .sessionMarkers: ExplainEntry(
            title: "Song Markers",
            body: "Named flags that label the parts of your song, like Intro, Chorus, or Drop. Drag empty ruler space here to add one, drag a flag to move it, double-click to rename, and click a flag to jump the playhead straight to that section."),

        // MARK: Track bounce-in-place (m11-e)
        .bounceInPlace: ExplainEntry(
            title: "Bounce in Place",
            body: "Renders this track down to one new audio track, turning a software instrument or effect-heavy part into plain recorded sound. Use it to lock in a decision, free up your computer, or share a clean copy. The original is muted, not deleted, and one undo brings it back."),

        // MARK: Tempo lane (m12-d)
        .tempoMap: ExplainEntry(
            title: "Tempo Lane",
            body: "Shows how the song's speed and time signature change across the timeline. Each section has its own beats-per-minute. Drag a divider to move a change, drag a section up or down to change its speed, or right-click to add one. Pro edits it; Simple just shows it."),

        // MARK: Sidechain key (m12-g)
        .sidechain: ExplainEntry(
            title: "Sidechain Key",
            body: "Makes this compressor or gate react to ANOTHER track instead of its own sound — pick a kick to duck a pad on every hit, the classic pump. Only compressors and gates can be keyed. Key from an audio track; to key an instrument, route it to a bus first."),

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
        .settingsConnection: ExplainEntry(
            title: "Agent Connection",
            body: "Shows the local address an AI helper connects to so it can drive the app for you, with a button to copy it and a box to change the port. Reach for it when you are hooking up an outside agent or automation tool."),
        .copilotMaxRounds: ExplainEntry(
            title: "Copilot Rounds",
            body: "How many back-and-forth rounds the Copilot may take to finish one request. In each round it reads your project, thinks, then makes a batch of changes. Raise it for big jobs, or lower it to keep every reply short and quick."),
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
