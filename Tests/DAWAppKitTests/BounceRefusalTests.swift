import DAWAppKit
@testable import DAWCore
import Foundation
import Testing

/// A render double for the menu's Bounce in Place: the pan-law `renderOffline` the store calls returns one second of
/// tone, `writeAudioFile` counts instead of writing, and `duringPlan` presses New from inside the compensation probe,
/// the `RenderPassRaceSpy` shape (DAWEngineTests; copied because test files cannot share a private type). Any other
/// render overload would fall to the protocol default and refuse `engineUnavailable`, so a wrong signature here
/// fails the success test loudly rather than passing it.
@MainActor
private final class BounceRefusalEngine: AudioEngineControlling {
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var recordPermission: RecordPermission = .granted

    private(set) var renders = 0
    private(set) var writes = 0
    private(set) var hooksRun = 0
    /// Runs ONCE, inside the compensation probe (before the render), then clears.
    var duringPlan: (@MainActor () -> Void)?

    private static let audio: RenderedAudio = {
        let tone = (0..<48_000).map { Float(0.25 * sin(2 * Double.pi * 1_000 * Double($0) / 48_000)) }
        return RenderedAudio(sampleRate: 48_000, channelData: [tone, tone])
    }()
    private static let info = AudioFileInfo(durationSeconds: 1, sampleRate: 48_000, channelCount: 2)

    func prepare() throws { isRunning = true }
    func shutdown() { isRunning = false }
    func tracksDidChange(_ tracks: [Track]) {}
    func startPlayback(_ transport: TransportState) {}
    func stopPlayback() {}
    func seek(_ transport: TransportState) {}
    func setTempo(_ transport: TransportState) {}
    func loopChanged(_ transport: TransportState) {}
    func masterVolumeChanged(_ volume: Double) {}
    func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {}
    func availableInputDevices() -> [AudioInputDevice] { [] }
    func setInputDevice(uid: String?) throws {}
    func startRecording(_ transport: TransportState, to url: URL,
                        completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {}
    func stopRecording() {}
    func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor],
                       masterAutomation: [AutomationLane],
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL) async throws -> AudioFileInfo {
        Self.info
    }

    func offlineCompensationTargets(tracks: [Track]) async -> [UUID: Int] {
        if let hook = duringPlan { duringPlan = nil; hooksRun += 1; hook() }
        return [:]
    }

    func renderOffline(tracks: [Track], tempoMap: TempoMap, meterMap: MeterMap, panLaw: PanLaw,
                       masterVolume: Double,
                       masterEffects: [EffectDescriptor], masterAutomation: [AutomationLane],
                       masterModulationSources: [ModulationSource], masterModulationRoutes: [ModulationRoute],
                       fromBeat: Double, durationSeconds: Double,
                       forcedCompensationTargets: [UUID: Int]?) async throws -> RenderedAudio {
        renders += 1
        return Self.audio
    }

    func writeAudioFile(_ audio: RenderedAudio, to url: URL) throws -> AudioFileInfo {
        writes += 1
        return Self.info
    }
}

/// m39-render-pass-race-ui: the track menu's Bounce in Place SHOWS a refusal in the store's own words.
///
/// It used to run `Task { try? await store.bounceTrackInPlace(trackId:) }`, so the refusal m39-render-pass-race
/// added (New or Open pressed while the track renders: `bounceInPlaceSongChanged`) did nothing and said nothing, and
/// so did every other refusal. Two halves, because either alone can pass while the menu still swallows:
/// - the BEHAVIOUR: `TrackHeaderMenuBounce.press`, driven through a real store with the menu's exact arguments,
///   returns the store's sentence verbatim on a refusal and nil on a landing;
/// - the WIRING: the menu's `.bounceInPlace` case (`TrackListView.swift`, comment-stripped) calls that press and
///   shows its answer, with no `try?` left in it.
///
/// ⚠️ NOT `@MainActor`-isolated (the `TransportRecordButtonModelTests` precedent): the tree's `@MainActor` suite count
/// sits at its cadence cap, so the functions that drive a real store carry `@MainActor` themselves.
@Suite("Bounce in Place from the track menu shows the store's refusal (m39-render-pass-race-ui)")
struct BounceRefusalTests {

    // MARK: - A real store, never the real library

    /// A named store whose every on-disk home is inside `dir` (the `RenderPassRaceRig.store` redirects): the New the
    /// song-change test presses must not touch the real recovery library, and a landed bounce must not write into
    /// the real Application Support.
    @MainActor
    private static func store(in dir: URL, tracks: [Track]) -> (ProjectStore, BounceRefusalEngine) {
        let store = ProjectStore(projectName: "W9-RUI bounce refusal", tracks: tracks)
        store.crashRecovery.directory = dir.appendingPathComponent("crash", isDirectory: true)
        store.crashRecovery.clock = { Date(timeIntervalSince1970: 1_000) }
        store.autosaveRecoveryDirectory = dir.appendingPathComponent("recovery", isDirectory: true)
        store.generationImportsDirectory = dir.appendingPathComponent("generations", isDirectory: true)
        let engine = BounceRefusalEngine()
        store.engine = engine
        return (store, engine)
    }

    private static func scratch(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dawpro-w9rui-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// One audio track with one clip: enough for the menu's default window (whole song + 2 s tail). The double
    /// renders nothing from it, so the clip needs no media.
    private static func guitar() -> [Track] {
        [Track(name: "Gtr", kind: .audio, clips: [Clip(name: "g", startBeat: 0, lengthBeats: 4)])]
    }

    // MARK: - Behaviour: the press returns the store's sentence or nil

    @Test("New pressed while the track renders: the press returns the song-changed sentence, verbatim")
    @MainActor
    func songChangedShowsItsOwnSentence() async throws {
        let dir = try Self.scratch("song-changed")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, engine) = Self.store(in: dir, tracks: Self.guitar())
        let source = store.tracks[0].id
        let generationBefore = store.projectGeneration
        engine.duringPlan = {
            do { try store.newProject(discardChanges: true) } catch {
                Issue.record("New was refused inside the render: \(error)")
            }
        }

        let sentence = await TrackHeaderMenuBounce.press(store, trackID: source)

        let expected = try #require(ProjectError.bounceInPlaceSongChanged.errorDescription)
        print("[W9-RUI] song-changed: sentence \(sentence ?? "none") | tracks \(store.tracks.map(\.name)) "
              + "| hooks \(engine.hooksRun) renders \(engine.renders) writes \(engine.writes)")
        #expect(engine.hooksRun == 1, "the New never landed inside the render")
        #expect(store.projectGeneration != generationBefore, "the song did not change")
        #expect(sentence == expected)
        #expect(sentence?.contains("nothing was added") == true, "\(sentence ?? "no sentence")")
        // The refusal is the store's whole answer: the new song gained nothing and no file was written.
        #expect(store.tracks.isEmpty, "the bounce landed in the other song: \(store.tracks.map(\.name))")
        #expect(engine.writes == 0)
    }

    @Test("A bounce that lands: the press returns nil (nothing to show) and the bounced track is there")
    @MainActor
    func successShowsNothing() async throws {
        let dir = try Self.scratch("success")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, engine) = Self.store(in: dir, tracks: Self.guitar())
        let source = store.tracks[0].id

        let sentence = await TrackHeaderMenuBounce.press(store, trackID: source)

        print("[W9-RUI] success: sentence \(sentence ?? "none") | tracks \(store.tracks.map(\.name)) "
              + "| renders \(engine.renders) writes \(engine.writes)")
        #expect(sentence == nil, "a landed bounce showed: \(sentence ?? "")")
        // nil must mean LANDED, not "refused in a way nobody saw".
        #expect(store.tracks.map(\.name) == ["Gtr", "Gtr (Bounced)"])
        #expect(engine.renders == 1)
        #expect(engine.writes == 1)
    }

    @Test("Another real refusal (a song with no clips): the press returns the menu's plain sentence, not the wire's")
    @MainActor
    func nothingToRenderShowsItsSentence() async throws {
        let dir = try Self.scratch("empty")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (store, engine) = Self.store(in: dir, tracks: [Track(name: "Keys", kind: .instrument)])
        let source = store.tracks[0].id

        let sentence = await TrackHeaderMenuBounce.press(store, trackID: source)

        let wire = try #require(ProjectError.nothingToRender.errorDescription)
        print("[W9-RUI] empty song: sentence \(sentence ?? "none") | renders \(engine.renders)")
        #expect(sentence == TrackHeaderMenuBounce.emptySongSentence)
        // Control: the wire sentence really does name a parameter a menu user cannot pass.
        #expect(wire.contains("durationSeconds"))
        #expect(!(sentence ?? "").contains("durationSeconds"))
        #expect(sentence != ProjectError.bounceInPlaceSongChanged.errorDescription)
        #expect(store.tracks.map(\.name) == ["Keys"])
        #expect(engine.renders == 0)
    }

    // MARK: - Wiring: the menu case calls the press and shows its answer

    /// The `PitchTuneDoorSiteTests` reader: walk up from `#filePath` to `Sources/`.
    private static func sourcesDir() -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fm = FileManager.default
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent("Sources", isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        Issue.record("Could not locate Sources from \(#filePath)")
        return URL(fileURLWithPath: "/nonexistent")
    }

    private static func raw(_ relativePath: String) -> String {
        let url = sourcesDir().appendingPathComponent(relativePath)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("Could not read \(relativePath) under \(sourcesDir().path)")
            return ""
        }
        return content
    }

    /// Comment lines blanked, trailing `//` comments cut (the `PitchTuneDoorSiteTests` stripper).
    private static func stripped(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { rawLine in
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("///") {
                return ""
            }
            return line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
        }.joined(separator: "\n")
    }

    /// The text from `case .bounceInPlace:` up to the next menu case, `case .exportMIDI:`.
    private static func bounceCase(in source: String) -> String {
        guard let start = source.range(of: "case .bounceInPlace:"),
              let end = source.range(of: "case .exportMIDI:", range: start.upperBound..<source.endIndex) else {
            Issue.record("the menu's .bounceInPlace case was not found in TrackListView.swift")
            return ""
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    @Test("The menu's Bounce in Place case calls the press and shows its answer, with no try? left")
    func menuCaseShowsTheRefusal() {
        let source = Self.raw("DAWApp/TrackListView.swift")
        let rawCase = Self.bounceCase(in: source)
        let code = Self.bounceCase(in: Self.stripped(source))
        // Positive controls: the reader reached the real case, and the needle `try?` CAN be found by this search
        // (the case's comment still names it), so its absence from the CODE below is a measurement, not a blind
        // spot. The stripper is what removes it.
        #expect(code.count > 40, "the case read as \(code.count) characters")
        #expect(rawCase.contains("try?"), "positive control: the comment that names try? is gone; re-pick a control")

        #expect(code.contains("TrackHeaderMenuBounce.press(store, trackID: track.id)"),
                "the menu case no longer runs the tested press:\n\(code)")
        #expect(code.contains("presentRefusal("), "the menu case no longer shows the press's answer:\n\(code)")
        #expect(!code.contains("try?"), "the menu case swallows a refusal again:\n\(code)")
        #expect(!code.contains("bounceTrackInPlace"), "the menu case bypasses the press:\n\(code)")

        // The alert shows the store's sentence AS IS: the body is the sentence, under the menu's shared title.
        let all = Self.stripped(source)
        #expect(all.contains("private func presentRefusal(_ sentence: String)"))
        #expect(all.contains("alert.informativeText = sentence"))
    }
}
