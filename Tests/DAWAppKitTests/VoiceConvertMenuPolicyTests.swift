import Foundation
import Testing
import DAWCore
@testable import DAWAppKit

/// Headless coverage for the *Convert Voice…* menu policy (m24-m leg B) — the
/// `DeleteMenuPolicyTests` shape: ONE producer for what the menu SAYS and what
/// it TARGETS, so a label reading "Convert Clip to Voice…" can never fire an
/// action that converts three.
@Suite("Convert Voice… menu policy (m24-m leg B)")
struct VoiceConvertMenuPolicyTests {

    private let a = UUID(), b = UUID(), c = UUID()

    // MARK: - The clip context menu

    @Test("a MIDI clip has NO entry at all — hidden, never offered-then-errored")
    func midiClipHasNoEntry() {
        #expect(VoiceConvertMenuPolicy.clipContextCommand(
            clickedClipID: a, clickedClipIsAudio: false,
            clickedClipIsSelected: true, selectedAudioClipIDs: [b, c]) == nil)
    }

    @Test("right-clicking an UNSELECTED audio clip targets that clip alone")
    func unselectedClipTargetsItself() throws {
        let command = try #require(VoiceConvertMenuPolicy.clipContextCommand(
            clickedClipID: a, clickedClipIsAudio: true,
            clickedClipIsSelected: false, selectedAudioClipIDs: [b, c]))
        #expect(command.title == "Convert Clip to Voice…")
        #expect(command.clipIDs == [a], "the user pointed at ONE thing")
        #expect(command.targetsWholeSelection == false)
    }

    @Test("right-clicking a SELECTED audio clip targets the whole audio selection, counted")
    func selectedClipTargetsSelection() throws {
        let command = try #require(VoiceConvertMenuPolicy.clipContextCommand(
            clickedClipID: a, clickedClipIsAudio: true,
            clickedClipIsSelected: true, selectedAudioClipIDs: [a, b, c]))
        #expect(command.title == "Convert 3 Clips to Voice…")
        #expect(command.clipIDs == [a, b, c])
        #expect(command.targetsWholeSelection == true)
    }

    @Test("a selection of one reads singular — never \"Convert 1 Clip\"")
    func selectionOfOneReadsSingular() throws {
        let command = try #require(VoiceConvertMenuPolicy.clipContextCommand(
            clickedClipID: a, clickedClipIsAudio: true,
            clickedClipIsSelected: true, selectedAudioClipIDs: [a]))
        #expect(command.title == "Convert Clip to Voice…")
        #expect(command.clipIDs == [a])
    }

    /// The marquee case: a MIDI clip swept into the selection must not turn a
    /// legal conversion into a store refusal, and the title must name the count
    /// that will ACTUALLY convert.
    @Test("a mixed selection converts its audio part, and the title counts THAT")
    func mixedSelectionCountsAudioOnly() throws {
        // Caller has already filtered: three clips selected, two of them audio.
        let command = try #require(VoiceConvertMenuPolicy.clipContextCommand(
            clickedClipID: a, clickedClipIsAudio: true,
            clickedClipIsSelected: true, selectedAudioClipIDs: [a, b]))
        #expect(command.title == "Convert 2 Clips to Voice…")
        #expect(command.clipIDs == [a, b])
    }

    /// INV: an audio clip flagged selected with an empty audio selection cannot
    /// occur — it would be in its own selection. Resolved rather than trusted,
    /// so a caller bug degrades to "convert the one you pointed at".
    @Test("a caller bug (selected, but no audio selection) degrades to the clicked clip")
    func inconsistentInputDegradesSafely() throws {
        let command = try #require(VoiceConvertMenuPolicy.clipContextCommand(
            clickedClipID: a, clickedClipIsAudio: true,
            clickedClipIsSelected: true, selectedAudioClipIDs: []))
        #expect(command.clipIDs == [a], "never an empty target set")
        #expect(command.targetsWholeSelection == false)
    }

    // MARK: - Edit ▸ Convert

    @Test("no audio selection → the item EXISTS, greyed, and drops its count")
    func inertItemDropsCount() {
        let item = VoiceConvertMenuPolicy.editMenuItem(
            arrangeWorkspace: true, isModalPresented: false, selectedAudioClipCount: 0)
        #expect(item.isEnabled == false)
        #expect(item.title == "Convert Clips to Voice…")
        #expect(item.clipCount == 0, "a greyed item must not claim a pending blast radius")
    }

    @Test("an audio selection lights the item and names the count")
    func liveItemNamesCount() {
        let one = VoiceConvertMenuPolicy.editMenuItem(
            arrangeWorkspace: true, isModalPresented: false, selectedAudioClipCount: 1)
        #expect(one.isEnabled)
        #expect(one.title == "Convert Clip to Voice…")
        #expect(one.clipCount == 1)

        let many = VoiceConvertMenuPolicy.editMenuItem(
            arrangeWorkspace: true, isModalPresented: false, selectedAudioClipCount: 4)
        #expect(many.isEnabled)
        #expect(many.title == "Convert 4 Clips to Voice…")
        #expect(many.clipCount == 4)
    }

    @Test("the Mix console has no clip selection, so the item is inert there")
    func mixWorkspaceIsInert() {
        let item = VoiceConvertMenuPolicy.editMenuItem(
            arrangeWorkspace: false, isModalPresented: false, selectedAudioClipCount: 3)
        #expect(item.isEnabled == false)
        #expect(item.title == VoiceConvertMenuPolicy.inertTitle)
        #expect(item.clipCount == 0)
    }

    @Test("a modal owns the window, so the item is inert behind one")
    func modalMakesItInert() {
        let item = VoiceConvertMenuPolicy.editMenuItem(
            arrangeWorkspace: true, isModalPresented: true, selectedAudioClipCount: 3)
        #expect(item.isEnabled == false)
        #expect(item.clipCount == 0)
    }

    @Test("the context menu and the Edit item AGREE on the words for one selection")
    func bothRoutesSayTheSameWords() throws {
        let context = try #require(VoiceConvertMenuPolicy.clipContextCommand(
            clickedClipID: a, clickedClipIsAudio: true,
            clickedClipIsSelected: true, selectedAudioClipIDs: [a, b, c]))
        let edit = VoiceConvertMenuPolicy.editMenuItem(
            arrangeWorkspace: true, isModalPresented: false, selectedAudioClipCount: 3)
        #expect(context.title == edit.title,
                "two routes into one action must not read as two features")
    }

    // MARK: - The panel's clip rows

    @Test("a target's beat span reads as trimmed SF Mono beats")
    func beatSpanFormatting() {
        let whole = VoiceConvertTarget(id: a, name: "Verse", trackName: "Vox",
                                       startBeat: 8, lengthBeats: 8)
        #expect(whole.beatSpanText == "beats 8–16")

        let fractional = VoiceConvertTarget(id: b, name: "Ad lib", trackName: "Vox",
                                            startBeat: 2.5, lengthBeats: 1.25)
        #expect(fractional.beatSpanText == "beats 2.5–3.75")

        let origin = VoiceConvertTarget(id: c, name: "Intro", trackName: "Vox",
                                        startBeat: 0, lengthBeats: 4)
        #expect(origin.beatSpanText == "beats 0–4")
    }

    // MARK: - The card's height budget (the m23-m3c hug-before-scroll law)

    @Test("the body room shrinks with the window and never drops below its floor")
    func bodyRoomTracksTheWindow() {
        let comfortable = VoiceConvertSheetLayout.bodyRoom(availableHeight: 900)
        let atFloor = VoiceConvertSheetLayout.bodyRoom(availableHeight: 640)
        #expect(comfortable > atFloor, "the budget is derived from the window, never a constant")
        #expect(atFloor >= VoiceConvertSheetLayout.minimumBodyRoom)
        #expect(VoiceConvertSheetLayout.bodyRoom(availableHeight: 200)
                == VoiceConvertSheetLayout.minimumBodyRoom)
    }

    /// The failure this budget exists to prevent: at the window floor the CARD
    /// (chrome + clamped body + both margins) must still fit the window, or the
    /// CONVERT button leaves the screen (m23-m3c, measured on the export card).
    @Test("at the WindowFloor the whole card still fits the window")
    func cardFitsAtTheWindowFloor() {
        let window = WindowFloor.minHeight
        let card = VoiceConvertSheetLayout.reservedChromeHeight
            + VoiceConvertSheetLayout.bodyRoom(availableHeight: window)
        #expect(card + 2 * VoiceConvertSheetLayout.windowMargin <= window)
    }
}

/// Headless coverage for **leg C** — dragging a voice model onto a track header.
///
/// ⚠️ **WHAT THIS SUITE DOES AND DOES NOT PROVE, stated plainly because the gap
/// is real.** A synthetic OS drag is not reachable here: SwiftUI's drop
/// callbacks arrive from an AppKit dragging session with no public initializer,
/// and the unbundled staging binary has no Accessibility grant to synthesize one
/// (m17-b). So this pins the DECISION LOGIC — which rows accept, what each says,
/// and which clips a drop targets — exactly as leg B pinned the right-click it
/// could not fire. The gesture itself is covered as far as anything here can
/// cover it, by `scripts/gates/_m24m-convert-voice-probe.mjs` driving the SAME
/// functions `TrackRow`'s `.dropDestination` calls.
@Suite("Convert Voice… track-header drop (m24-m leg C)")
struct VoiceConvertTrackDropTests {

    private func audioClip(_ name: String, at beat: Double) -> Clip {
        Clip(name: name, startBeat: beat, lengthBeats: 4,
             audioFileURL: URL(fileURLWithPath: "/tmp/\(name).wav"))
    }

    private func audioTrack(clipBeats: [Double]) -> Track {
        var track = Track(name: "Lead Vox", kind: .audio)
        track.clips = clipBeats.enumerated().map { audioClip("take-\($0.offset)", at: $0.element) }
        return track
    }

    // MARK: - What is convertible

    @Test("a MIDI clip is not convertible, and neither is an audio clip with no file")
    func convertiblePredicate() {
        #expect(VoiceConvertMenuPolicy.isConvertible(audioClip("take", at: 0)))
        #expect(!VoiceConvertMenuPolicy.isConvertible(
            Clip(name: "Part", startBeat: 0, lengthBeats: 4, notes: [])))
        // Neither MIDI nor convertible: leg A would refuse it AFTER the panel
        // had already promised it.
        #expect(!VoiceConvertMenuPolicy.isConvertible(Clip(name: "Detached", startBeat: 0)))
    }

    @Test("a track's convertible clips come back ordered by start beat, MIDI dropped")
    func trackClipsOrderedAndFiltered() {
        var track = Track(name: "Comp", kind: .audio)
        let late = audioClip("late", at: 16)
        let early = audioClip("early", at: 0)
        let middle = audioClip("middle", at: 8)
        let midi = Clip(name: "Notes", startBeat: 4, lengthBeats: 4, notes: [])
        track.clips = [late, midi, early, middle]

        #expect(VoiceConvertMenuPolicy.convertibleAudioClipIDs(in: track)
                == [early.id, middle.id, late.id],
                "the panel lists them in this order and so does the result")
    }

    // MARK: - The verdict

    @Test("an audio track with clips ACCEPTS, and the title counts them")
    func audioTrackAccepts() throws {
        let track = audioTrack(clipBeats: [0, 8, 16])
        let ids = VoiceConvertMenuPolicy.convertibleAudioClipIDs(in: track)
        let verdict = VoiceConvertMenuPolicy.trackDropVerdict(
            trackKind: .audio, audioClipIDs: ids)

        let command = try #require(verdict.command)
        #expect(verdict.accepted)
        #expect(verdict.refusal == nil)
        #expect(command.clipIDs == ids)
        #expect(command.title == "Convert 3 Clips to Voice…")
        // A drop names a TRACK, never the arrange selection — dropping on a
        // track the user had not selected must not claim their selection.
        #expect(command.targetsWholeSelection == false)
    }

    @Test("one clip reads singular")
    func singleClipTrack() throws {
        let track = audioTrack(clipBeats: [0])
        let command = try #require(VoiceConvertMenuPolicy.trackDropVerdict(
            trackKind: .audio,
            audioClipIDs: VoiceConvertMenuPolicy.convertibleAudioClipIDs(in: track)).command)
        #expect(command.title == "Convert Clip to Voice…")
    }

    @Test("an INSTRUMENT track refuses, and names the remedy")
    func instrumentTrackRefuses() {
        var track = Track(name: "Keys", kind: .instrument)
        track.clips = [Clip(name: "Part", startBeat: 0, lengthBeats: 4, notes: [])]
        let verdict = VoiceConvertMenuPolicy.trackDropVerdict(
            trackKind: .instrument,
            audioClipIDs: VoiceConvertMenuPolicy.convertibleAudioClipIDs(in: track))
        #expect(!verdict.accepted)
        #expect(verdict.command == nil)
        #expect(verdict.refusal == VoiceConvertDropRefusal.instrumentTrack)
    }

    @Test("a BUS refuses — it holds no clips and never will")
    func busRefuses() {
        let verdict = VoiceConvertMenuPolicy.trackDropVerdict(trackKind: .bus, audioClipIDs: [])
        #expect(verdict.refusal == VoiceConvertDropRefusal.busTrack)
    }

    @Test("an EMPTY audio track refuses with the one refusal that is about the moment")
    func emptyAudioTrackRefuses() {
        let verdict = VoiceConvertMenuPolicy.trackDropVerdict(trackKind: .audio, audioClipIDs: [])
        #expect(verdict.refusal == VoiceConvertDropRefusal.emptyAudioTrack)
        // Record audio here and the same drag works; the instrument track's
        // remedy is a different one, so it must not borrow those words.
        #expect(verdict.refusal != VoiceConvertDropRefusal.instrumentTrack)
    }

    /// ⚠️ An audio track whose ONLY clips are MIDI cannot exist in the store, but
    /// the policy must not depend on that: the verdict is derived from the
    /// resolved id list, so a track that filters down to nothing refuses for the
    /// empty reason rather than accepting an empty conversion (which leg A would
    /// then refuse, after the panel had opened).
    @Test("a track whose clips all filter out refuses rather than accepting an empty set")
    func filteredToNothingRefuses() {
        var track = Track(name: "Odd", kind: .audio)
        track.clips = [Clip(name: "Notes", startBeat: 0, lengthBeats: 4, notes: [])]
        let ids = VoiceConvertMenuPolicy.convertibleAudioClipIDs(in: track)
        #expect(ids.isEmpty)
        #expect(VoiceConvertMenuPolicy.trackDropVerdict(trackKind: .audio, audioClipIDs: ids)
                .refusal == VoiceConvertDropRefusal.emptyAudioTrack)
    }

    // MARK: - One vocabulary across all three routes

    @Test("the drop, the context menu and the Edit item say the SAME words for 3 clips")
    func allThreeRoutesAgree() throws {
        let a = UUID(), b = UUID(), c = UUID()
        let drop = try #require(VoiceConvertMenuPolicy.trackDropVerdict(
            trackKind: .audio, audioClipIDs: [a, b, c]).command)
        let context = try #require(VoiceConvertMenuPolicy.clipContextCommand(
            clickedClipID: a, clickedClipIsAudio: true,
            clickedClipIsSelected: true, selectedAudioClipIDs: [a, b, c]))
        let edit = VoiceConvertMenuPolicy.editMenuItem(
            arrangeWorkspace: true, isModalPresented: false, selectedAudioClipCount: 3)
        #expect(drop.title == context.title)
        #expect(drop.title == edit.title,
                "THREE routes into one action must not read as three features")
    }

    // MARK: - The refusal chip has to FIT

    /// The refusals are drawn INSIDE the row that refuses, at the 250 pt sidebar
    /// floor, beside a track name that must stay legible. The budget is
    /// `TrackRow.noClipsToSelectNotice` — "No clips to select", 20 characters —
    /// and a teaching sentence does not fit. Pinned because the failure is
    /// invisible to every other check here: a longer string still passes every
    /// equality assertion above and silently eats the track name.
    @Test("every refusal fits the row-chip budget")
    func refusalsFitTheRow() {
        for reason in [VoiceConvertDropRefusal.instrumentTrack,
                       VoiceConvertDropRefusal.busTrack,
                       VoiceConvertDropRefusal.emptyAudioTrack] {
            #expect(reason.count <= 22, "\"\(reason)\" is too long for a track header chip")
            #expect(!reason.isEmpty)
        }
        // Three distinct remedies must not collapse into one word.
        #expect(Set([VoiceConvertDropRefusal.instrumentTrack,
                     VoiceConvertDropRefusal.busTrack,
                     VoiceConvertDropRefusal.emptyAudioTrack]).count == 3)
    }

    // MARK: - The verdict's two faces are mutually exclusive

    @Test("accepted and refused are never both true")
    func facesAreExclusive() {
        let accepting = VoiceConvertMenuPolicy.trackDropVerdict(
            trackKind: .audio, audioClipIDs: [UUID()])
        let refusing = VoiceConvertMenuPolicy.trackDropVerdict(trackKind: .bus, audioClipIDs: [])
        #expect(accepting.accepted && accepting.refusal == nil && accepting.command != nil)
        #expect(!refusing.accepted && refusing.refusal != nil && refusing.command == nil)
    }
}
