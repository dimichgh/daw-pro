import Foundation
import DAWCore

/// The ONE home for the question "what does *Convert Voice…* act on, what does
/// it say, and is it live?" (m24-m leg B) — the `DeleteMenuPolicy` shape applied
/// to the selection-driven voice-conversion action the user ratified 2026-08-13
/// (*"I agree on this"*).
///
/// ⭐ **TWO ROUTES, ONE DECISION.** `clipContextCommand` answers for the arrange
/// clip's right-click menu; `editMenuItem` answers for Edit ▸ Convert. They are
/// not two policies that agree — both count the SAME `selectedAudioClipIDs` the
/// handler then converts, so the label and the blast radius come out of one
/// producer (the m23-cf law: *a menu reading "Convert Clip to Voice…" while the
/// action converts three is worse than no menu at all*).
///
/// ⚠️ **THE ITEM MUST NEVER CARRY A KEY EQUIVALENT.** Not because conversion is
/// destructive — it is purely additive, it only ever appends a track — but
/// because menu key equivalents are checked BEFORE text insertion (the m17-d
/// trap, written up on `DeleteMenuPolicy`), and this leg has no keystroke to
/// offer. Adding one later would steal that character from every rename field in
/// the app.
///
/// ⛔ **THIS POLICY DOES NOT PRE-VALIDATE THE SELECTION BEYOND CLIP KIND.**
/// `ProjectStore.convertClipsToVoice` refuses an empty set, a duplicate id, an
/// unknown id, a MIDI clip and two SELECTED clips that overlap in beats, each
/// with a teaching message. Re-deriving the overlap rule here would be a second
/// home for it, and the two would drift; the panel lists the exact clips it will
/// convert and surfaces the store's refusal VERBATIM instead (the refusal-bubble
/// one-vocabulary law). The ONE thing decided here is clip KIND, because that is
/// a question about whether the affordance should EXIST — a MIDI clip has no
/// recording to convert, so the entry is hidden rather than offered-then-errored
/// (the standing "Quantize…" / "Humanize…" / "Breath Pad…" rule).
///
/// **WHY IN DAWAppKit.** `DAWApp` has no test target, so a menu policy written
/// there is unverifiable by the Swift suite — the standing remedy in this tree
/// (`DeleteMenuPolicy`, `ClipboardMenuPolicy`, `ArrangeScrollQuery`). Everything
/// that DECIDES lives here; `DAWApp` keeps only composition.
public enum VoiceConvertMenuPolicy {

    /// What Edit ▸ Convert says when it is greyed.
    ///
    /// **It drops the count, and that is the `DeleteMenuPolicy` rule verbatim**:
    /// a greyed "Convert 5 Clips to Voice…" claims a pending action that is not
    /// pending. The plural still teaches that the operation exists and wants a
    /// selection of audio clips.
    public static let inertTitle = "Convert Clips to Voice…"

    /// The verb every title is built from — ONE spelling, so the context menu
    /// and the Edit menu can never read as two different features.
    public static let verb = "Convert"

    /// The counted noun phrases. The trailing ellipsis is the house "this opens
    /// a panel" convention ("Quantize…", "Humanize…", "Breath Pad…").
    static let singular = "Clip to Voice…"
    static let plural = "Clips to Voice…"

    // MARK: - The arrange clip context menu

    /// Resolves the clip context menu's entry, or `nil` when the entry must not
    /// exist at all.
    ///
    /// **Hidden, never offered-then-errored**, in exactly two cases:
    ///  - the clip under the pointer is MIDI (it has no recording to convert), or
    ///  - the resolved target set is empty (which can only happen through a
    ///    caller bug, since an audio clip under the pointer is always a target).
    ///
    /// **Targeting is the `DeleteMenuPolicy.clipContextCommand` rule verbatim:**
    /// right-clicking a clip that is IN the selection acts on the whole
    /// selection; right-clicking one that is NOT acts on that clip alone and
    /// leaves the selection untouched. The one addition is that a mixed
    /// selection is FILTERED to its audio clips — a MIDI clip caught in a
    /// marquee must not turn a legal conversion into a refusal, and the title
    /// names the count that will actually convert.
    ///
    /// - Parameters:
    ///   - clickedClipID: the clip under the pointer.
    ///   - clickedClipIsAudio: false for a MIDI clip (the entry then disappears).
    ///   - clickedClipIsSelected: the clicked clip is in `arrangeSelection`.
    ///   - selectedAudioClipIDs: the AUDIO clips in `arrangeSelection`, in the
    ///     order the panel should list them (by start beat — the same order
    ///     `ClipVoiceConversionResult.clips` comes back in).
    public static func clipContextCommand(
        clickedClipID: UUID,
        clickedClipIsAudio: Bool,
        clickedClipIsSelected: Bool,
        selectedAudioClipIDs: [UUID]
    ) -> VoiceConvertCommand? {
        guard clickedClipIsAudio else { return nil }
        // `clickedClipIsSelected` with an empty audio selection cannot occur for
        // an audio clip (it would be in its own selection) — resolved to the
        // clicked clip rather than trusted, so a caller bug degrades to
        // "convert the one you pointed at" instead of an empty no-op.
        guard clickedClipIsSelected, !selectedAudioClipIDs.isEmpty else {
            return VoiceConvertCommand(
                title: EditMenuTitles.counted(verb: verb, count: 1,
                                              singular: singular, plural: plural),
                clipIDs: [clickedClipID],
                targetsWholeSelection: false)
        }
        return VoiceConvertCommand(
            title: EditMenuTitles.counted(verb: verb, count: selectedAudioClipIDs.count,
                                          singular: singular, plural: plural),
            clipIDs: selectedAudioClipIDs,
            targetsWholeSelection: true)
    }

    // MARK: - What a clip has to be

    /// The ONE predicate behind *"can this clip be converted?"* — audio content
    /// with a file behind it.
    ///
    /// ⭐ **EXTRACTED AT LEG C, AND THAT IS THE POINT OF THE LEG.** Before this,
    /// `AppModel.selectedAudioClipIDs` carried the rule inline, and the drop
    /// route would have needed the same conjunction written a second time. Two
    /// copies of *"what is convertible"* is the exact defect class this tree
    /// keeps finding — the record says X, the source says Y, and nothing
    /// compares them. Every route now asks this function.
    ///
    /// `audioFileURL != nil` is not redundant with `!isMIDI`: a clip whose
    /// recording has been detached is neither MIDI nor convertible, and leg A
    /// would refuse it after the panel had already promised it.
    public static func isConvertible(_ clip: Clip) -> Bool {
        !clip.isMIDI && clip.audioFileURL != nil
    }

    /// Every convertible clip on `track`, ordered by start beat — the order the
    /// panel lists them in and the order `ClipVoiceConversionResult.clips` comes
    /// back in.
    public static func convertibleAudioClipIDs(in track: Track) -> [UUID] {
        track.clips
            .filter(isConvertible)
            .sorted { $0.startBeat < $1.startBeat }
            .map(\.id)
    }

    // MARK: - Dragging a voice model onto a track header (leg C)

    /// What happens when a voice model is dragged over ONE track header: the
    /// same `VoiceConvertCommand` the menus produce, or a short refusal in
    /// words the row can actually hold.
    ///
    /// ⭐ **A SECOND ENTRY POINT, NOT A SECOND RULE.** The drop opens the SAME
    /// panel on the SAME command type through the SAME `openVoiceConvert`
    /// funnel; if dragging a voice onto a track produced a different result
    /// from selecting that track's clips and using Edit ▸ Convert, that would
    /// be a bug. So the words and the ids travel together here exactly as they
    /// do in `clipContextCommand` (the `ClipDeleteCommand` law), and the KIND
    /// question is answered by the one function above.
    ///
    /// ⚠️ **A TRACK-RESOLVED TARGET SET CANNOT HIT LEG A's OVERLAP REFUSAL**,
    /// and that is structural rather than lucky: clips on ONE track cannot
    /// overlap in beats, and leg A refuses only pairs that do. So this verdict
    /// is the whole truth for a track drop — there is no second refusal waiting
    /// behind it, which is what makes it safe to state acceptance in the
    /// affordance BEFORE the drop.
    ///
    /// **Why it REFUSES rather than disappearing.** The kind rule for a menu is
    /// *hide it* (an entry that would error teaches nothing). A drop target has
    /// no such option: the user is already mid-gesture, the pointer is over the
    /// row, and a target that simply does not react is indistinguishable from a
    /// broken one. So the row answers — amber, with the reason — and the drop
    /// itself is rejected.
    ///
    /// - Parameters:
    ///   - trackKind: audio / instrument / bus.
    ///   - audioClipIDs: `convertibleAudioClipIDs(in:)` for that track.
    public static func trackDropVerdict(
        trackKind: TrackKind,
        audioClipIDs: [UUID]
    ) -> VoiceConvertDropVerdict {
        switch trackKind {
        case .instrument:
            // An instrument track's clips are notes, not audio. The remedy is
            // real and is named: bounce it, then convert the bounce.
            return .refuses(VoiceConvertDropRefusal.instrumentTrack)
        case .bus:
            // A bus carries no clips at all — it is a summing point.
            return .refuses(VoiceConvertDropRefusal.busTrack)
        case .audio:
            guard !audioClipIDs.isEmpty else {
                return .refuses(VoiceConvertDropRefusal.emptyAudioTrack)
            }
            return .accepts(VoiceConvertCommand(
                title: EditMenuTitles.counted(verb: verb, count: audioClipIDs.count,
                                              singular: singular, plural: plural),
                clipIDs: audioClipIDs,
                targetsWholeSelection: false))
        }
    }

    // MARK: - Edit ▸ Convert

    /// Resolves the Edit-menu item: what it says and whether it is live.
    ///
    /// **The item EXISTS even when it is inert** (the m23-cf rule): a greyed
    /// entry teaches that the operation is there and wants a selection, while an
    /// item that vanishes teaches nothing and is indistinguishable from the bug.
    ///
    /// **Every term is `@Observable` state**, deliberately, so a `Commands` body
    /// re-evaluates when any of them moves — a menu built from a term read out of
    /// AppKit (`NSApp.keyWindow.firstResponder`) freezes at whatever it was when
    /// the body last ran.
    ///
    /// - Parameters:
    ///   - arrangeWorkspace: the Mix console has no clip selection, so the item
    ///     is inert there (the `DeleteMenuPolicy` first guard).
    ///   - isModalPresented: a centered card owns the window; an Edit-menu action
    ///     firing behind it would act on a surface the user cannot see.
    ///   - selectedAudioClipCount: `selectedAudioClipIDs.count` — the SAME array
    ///     the action converts, never a second count.
    public static func editMenuItem(
        arrangeWorkspace: Bool,
        isModalPresented: Bool,
        selectedAudioClipCount: Int
    ) -> VoiceConvertMenuItem {
        guard arrangeWorkspace, !isModalPresented, selectedAudioClipCount > 0 else {
            return VoiceConvertMenuItem(title: inertTitle, clipCount: 0, isEnabled: false)
        }
        return VoiceConvertMenuItem(
            title: EditMenuTitles.counted(verb: verb, count: selectedAudioClipCount,
                                          singular: singular, plural: plural),
            clipCount: selectedAudioClipCount,
            isEnabled: true)
    }
}

/// What one arrange clip's context-menu *Convert Voice…* entry says and targets.
///
/// The title and the ids travel TOGETHER and the handler is handed this whole
/// value back rather than recomputing the set — so what the user was shown and
/// what runs cannot diverge (the `ClipDeleteCommand` law).
public struct VoiceConvertCommand: Equatable, Sendable {
    /// What the menu says — always names the real blast radius.
    public var title: String
    /// Exactly the clips the panel will convert, in list order.
    public var clipIDs: [UUID]
    /// True: the whole (audio part of the) arrange selection. False: only the
    /// clip that was right-clicked, leaving the selection alone.
    public var targetsWholeSelection: Bool

    public init(title: String, clipIDs: [UUID], targetsWholeSelection: Bool) {
        self.title = title
        self.clipIDs = clipIDs
        self.targetsWholeSelection = targetsWholeSelection
    }
}

/// The Edit ▸ Convert item's resolved title + enabled state (the
/// `DeleteMenuItem` twin).
public struct VoiceConvertMenuItem: Equatable, Sendable {
    public var title: String
    /// How many clips the title claims. Zero whenever the item is inert — the
    /// count and the enabled flag are produced together so a greyed item can
    /// never advertise a pending blast radius.
    public var clipCount: Int
    public var isEnabled: Bool

    public init(title: String, clipCount: Int, isEnabled: Bool) {
        self.title = title
        self.clipCount = clipCount
        self.isEnabled = isEnabled
    }
}

/// One clip the panel will convert, as the panel needs to READ it: a plain value
/// input (the reusable-component rule), resolved from the live store once when
/// the panel opens.
///
/// **Why the panel lists them at all.** Leg A refuses an overlapping pair, a MIDI
/// clip and an unknown id BEFORE doing any work, and conversion is minutes-class
/// — so the moment before the user commits is the only cheap moment to notice
/// they selected the wrong take. Showing the set (name · track · beats) is how
/// the good path is made obvious WITHOUT growing a second copy of the store's
/// validation rules.
public struct VoiceConvertTarget: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var trackName: String
    public var startBeat: Double
    public var lengthBeats: Double

    public init(id: UUID, name: String, trackName: String,
                startBeat: Double, lengthBeats: Double) {
        self.id = id
        self.name = name
        self.trackName = trackName
        self.startBeat = startBeat
        self.lengthBeats = lengthBeats
    }

    /// The SF Mono beat readout the row shows — "beats 8–16" (the ClipFix
    /// region-card idiom). Trailing zeros trimmed so a whole-bar clip reads
    /// "8–16" rather than "8.00–16.00".
    public var beatSpanText: String {
        "beats \(Self.beats(startBeat))–\(Self.beats(startBeat + lengthBeats))"
    }

    static func beats(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%g", rounded)
    }
}

/// What a track header answers when a voice model is dragged over it (m24-m
/// leg C).
///
/// One value carries BOTH faces so the hover treatment and the drop handler
/// read the same answer — a row that lights up violet and then swallows the
/// drop, or greys out and then accepts it, cannot be expressed.
public enum VoiceConvertDropVerdict: Equatable, Sendable {
    /// The drop opens the panel on exactly these clips, under exactly this
    /// title.
    case accepts(VoiceConvertCommand)
    /// The drop is rejected; the row says this, in the refusal register.
    case refuses(String)

    public var accepted: Bool {
        if case .accepts = self { return true }
        return false
    }

    /// The command, or nil when refused.
    public var command: VoiceConvertCommand? {
        if case .accepts(let command) = self { return command }
        return nil
    }

    /// The refusal words, or nil when accepted.
    public var refusal: String? {
        if case .refuses(let reason) = self { return reason }
        return nil
    }
}

/// The three things a track header can say when it will not take a voice model.
///
/// ⭐ **SHORT ON PURPOSE, AND THE LENGTH IS A MEASURED CONSTRAINT.** These are
/// drawn as a chip INSIDE the row that refuses, at the 250 pt sidebar floor,
/// beside a track name that must stay legible — the `TrackRow.noClipsToSelectNotice`
/// budget verbatim ("No clips to select", 20 characters). A teaching sentence
/// does not fit, and hanging one outside the row is the exact geometry mistake
/// that chip's doc comment records: a message that lands on the wrong row.
///
/// The deixis is free because the chip is a CHILD of the row it names — "this
/// track" would be words spent on something the pixels already say.
public enum VoiceConvertDropRefusal {
    /// An instrument track: notes, not audio. Names the remedy, because there
    /// is one and it is one context-menu item away ("Bounce in Place").
    public static let instrumentTrack = "Bounce to audio first"
    /// A bus: a summing point, so it holds no clips at all and never will.
    public static let busTrack = "Buses hold no clips"
    /// An audio track with nothing on it — the ONE refusal that is about the
    /// moment rather than the kind, and it says so: record or drop audio here
    /// and the same drag works.
    public static let emptyAudioTrack = "No audio clips yet"
}
