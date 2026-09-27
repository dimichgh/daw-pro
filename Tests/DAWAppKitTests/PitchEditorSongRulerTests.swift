import Testing
import CoreGraphics
import Foundation
import DAWCore
@testable import DAWAppKit

/// m23-ap I5-F1 — the note editor's time ruler numbers the SONG's bars
/// (`PitchEditorSongRuler`), never the clip's.
///
/// ⭐ **EVERY FIXTURE STARTS THE CLIP OFF A BAR LINE** (beats 2.5 and 3.1): on a
/// clip that starts on bar 1's line the song's numbering and the clip's are the
/// same numbers at the same x, and no assertion here could tell them apart. The
/// clip-local ruler (`PianoRollScrubRuler.ticks`) is run beside each one as the
/// control that shows the fixture discriminates.
///
/// Nonisolated value math, so a plain suite (no `@MainActor` slot is spent).
struct PitchEditorSongRulerTests {

    private static let fourFour = MeterMap(constant: TimeSignature())

    /// The labelled ticks as `(label, x)` pairs, in order.
    private static func labelled(_ ticks: [PianoRollScrubRuler.Tick]) -> [(String, CGFloat)] {
        ticks.compactMap { tick in tick.label.map { ($0, tick.x) } }
    }

    @Test("I5-F1 — a clip starting at beat 2.5 in 4/4: the first bar line inside it is SONG bar 2, drawn 1.5 beats in; the clip-local ruler says \"1\" at x 0 (the control)")
    func songBarsOffABarLine() {
        let ppb: CGFloat = 32   // the default zoom: bars only (32 < 44)
        let ticks = PitchEditorSongRuler.ticks(clipStartBeat: 2.5, lengthBeats: 16,
                                               pixelsPerBeat: ppb, meterMap: Self.fourFour)
        let bars = Self.labelled(ticks)
        // Song beats 4, 8, 12, 16 are bars 2…5; 2.5 + 16 = 18.5 ends inside bar 5.
        #expect(bars.map(\.0) == ["2", "3", "4", "5"], "\(bars)")
        #expect(bars.map(\.1) == [1.5, 5.5, 9.5, 13.5].map { CGFloat($0) * ppb })
        // Every tick sits on a WHOLE song beat, whatever the clip's start.
        for tick in ticks {
            let song = 2.5 + tick.localBeat
            #expect(abs(song - song.rounded()) < 1e-9, "tick at song beat \(song)")
            #expect(abs(tick.x - CGFloat(tick.localBeat) * ppb) < 1e-9)
        }
        // CONTROL — the clip-local ruler names a different bar at a different x.
        let local = Self.labelled(PianoRollScrubRuler.ticks(lengthBeats: 16, pixelsPerBeat: ppb,
                                                            beatsPerBar: 4))
        #expect(local.first?.0 == "1" && local.first?.1 == 0, "\(local)")
        #expect(local.map(\.0) != bars.map(\.0) || local.map(\.1) != bars.map(\.1),
                "the fixture cannot tell the two numberings apart")
    }

    @Test("I5-F1 — the staging capture's case: a vocal at beat 3.1, the transport at 15.6 reads \"4.4\" and the ruler's last bar at or before the playhead is \"4\"; beat labels (zoomed in) spell the transport's bar.beat")
    func theCapturedCase() {
        let start = 3.1
        let position = 15.6
        var transport = TransportState(positionBeats: position)
        #expect(transport.barsBeatsDisplay == "4.4")
        let ppb: CGFloat = 64   // beats labelled (64 ≥ 44)
        let ticks = PitchEditorSongRuler.ticks(clipStartBeat: start, lengthBeats: 30,
                                               pixelsPerBeat: ppb, meterMap: transport.meterMap)
        let playheadX = CGFloat(position - start) * ppb
        let bars = ticks.filter { $0.isBar && $0.label != nil && $0.x <= playheadX }
        #expect(bars.last?.label == "4", "\(bars.map { $0.label ?? "-" })")
        // First bar line inside the clip: song beat 4, 0.9 beats in, named "2".
        #expect(ticks.first(where: \.isBar)?.label == "2")
        #expect(abs((ticks.first(where: \.isBar)?.x ?? -1) - 0.9 * ppb) < 1e-9)
        // Every labelled beat inside a bar says what the transport says there.
        for tick in ticks where !tick.isBar {
            transport.positionBeats = start + tick.localBeat
            #expect(tick.label == transport.barsBeatsDisplay, "at song beat \(transport.positionBeats)")
        }
        // A bar line reads "5", the transport "5.1": the same bar, the ruler's
        // spelling (`label(atProjectBeat:)`).
        #expect(PitchEditorSongRuler.label(atProjectBeat: 16, meterMap: transport.meterMap) == "5")
        #expect(PitchEditorSongRuler.label(atProjectBeat: 17, meterMap: transport.meterMap) == "5.2")
    }

    @Test("I5-F1 — a meter change INSIDE the clip (4/4 → 3/4 at beat 8): bar lines re-space exactly where the song's meter map puts them, numbered on")
    func aMeterChangeInsideTheClip() throws {
        let meter = try MeterMap(changes: [.init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
                                           .init(startBeat: 8, beatsPerBar: 3, beatUnit: 4)])
        let ppb: CGFloat = 16   // a 3/4 bar = 48 pt ≥ 44: every bar labelled
        let ticks = PitchEditorSongRuler.ticks(clipStartBeat: 2.5, lengthBeats: 15,
                                               pixelsPerBeat: ppb, meterMap: meter)
        let bars = ticks.filter(\.isBar)
        // Song bars start at 4 (bar 2), 8 (bar 3, the change), 11 (bar 4), 14 (bar 5), 17 (bar 6).
        #expect(bars.map { 2.5 + $0.localBeat } == [4, 8, 11, 14, 17])
        #expect(bars.map(\.label) == ["2", "3", "4", "5", "6"])
        // CONTROL — a scalar 4/4 (the hard-coded meter this must never assume)
        // puts bar lines at 12 and 16 instead.
        let assumed = PitchEditorSongRuler.ticks(clipStartBeat: 2.5, lengthBeats: 15,
                                                 pixelsPerBeat: ppb, meterMap: Self.fourFour)
        #expect(assumed.filter(\.isBar).map { 2.5 + $0.localBeat } == [4, 8, 12, 16])
    }

    @Test("I5-F1 — a TEMPO change inside the clip moves the notes against the ruler and moves no tick: the axis is beats, so the bar-5 tick and the playhead at the transport's bar 5 share one x under either tempo map")
    func aTempoChangeMovesNoTick() throws {
        let clip = Clip(name: "vocal", startBeat: 3.1, lengthBeats: 20)
        let steady = TempoMap(constantBPM: 120)
        let changing = try TempoMap(segments: [.init(startBeat: 0, bpm: 120),
                                               .init(startBeat: 10, bpm: 90)])
        let meter = Self.fourFour
        let ppb: CGFloat = 32
        // The ruler takes no tempo map at all — the pinned claim is that it
        // needs none. Placed through each geometry, bar 5 (song beat 16) and the
        // playhead at song beat 16 land on the same x.
        let ticks = PitchEditorSongRuler.ticks(clipStartBeat: clip.startBeat, lengthBeats: clip.lengthBeats,
                                               pixelsPerBeat: ppb, meterMap: meter)
        let bar5 = try #require(ticks.first { $0.label == "5" })
        for tempo in [steady, changing] {
            let geometry = PitchEditorGeometry(clip: clip, tempoMap: tempo, pixelsPerBeat: ppb)
            #expect(abs(geometry.x(forProjectBeat: 16) - bar5.x) < 1e-9)
        }
        // CONTROL — the tempo change DOES move the audio on this axis: the same
        // source second lands on a different beat, so a ruler that followed
        // the audio would have moved too.
        let a = PitchEditorGeometry(clip: clip, tempoMap: steady, pixelsPerBeat: ppb)
        let b = PitchEditorGeometry(clip: clip, tempoMap: changing, pixelsPerBeat: ppb)
        #expect(abs(a.x(forSourceSecond: 6) - b.x(forSourceSecond: 6)) > 1)
    }

    @Test("I5-F1 — zoomed out, labels thin on the SONG's bars (1, 3, 5…), never from the clip's first bar; the ends of the clip keep their ticks; nothing for an empty or degenerate span")
    func thinningAndEdges() {
        // 6 pt/beat in 4/4: a bar is 24 pt, so every 2nd bar is labelled.
        let ticks = PitchEditorSongRuler.ticks(clipStartBeat: 3.1, lengthBeats: 30,
                                               pixelsPerBeat: 6, meterMap: Self.fourFour)
        // Song bars 2…9 lie inside 3.1…33.1; the ODD song bars keep their numbers.
        #expect(Self.labelled(ticks).map(\.0) == ["3", "5", "7", "9"], "\(Self.labelled(ticks))")
        #expect(ticks.allSatisfy { $0.isBar }, "beat ticks drop below 8 pt/beat")
        // A clip that starts and ends ON whole beats keeps both edge ticks.
        let exact = PitchEditorSongRuler.ticks(clipStartBeat: 4, lengthBeats: 8,
                                               pixelsPerBeat: 32, meterMap: Self.fourFour)
        #expect(exact.first?.x == 0 && exact.first?.label == "2")
        #expect(exact.last?.localBeat == 8 && exact.last?.label == "4")
        #expect(PitchEditorSongRuler.ticks(clipStartBeat: 3, lengthBeats: 0, pixelsPerBeat: 32,
                                           meterMap: Self.fourFour).isEmpty)
        #expect(PitchEditorSongRuler.ticks(clipStartBeat: 3, lengthBeats: 8, pixelsPerBeat: 0,
                                           meterMap: Self.fourFour).isEmpty)
        #expect(PitchEditorSongRuler.ticks(clipStartBeat: .nan, lengthBeats: 8, pixelsPerBeat: 32,
                                           meterMap: Self.fourFour).isEmpty)
    }
}
