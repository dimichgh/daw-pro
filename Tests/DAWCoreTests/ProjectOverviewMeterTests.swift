import Foundation
import Testing
@testable import DAWCore

/// m23-cv: per-track levels in the agent-facing `project.overview` projection.
///
/// THE POINT OF THIS SUITE, and the reason its central test stops the transport
/// first: `ProjectStore.stop()` deliberately zeroes every `trackMeters` entry to
/// `.silence`, and an agent reads `project.overview` BETWEEN actions — i.e.
/// while stopped. A projection wired naively to `trackMeters` would report
/// silence on every read and still pass any test that asserted DURING playback.
/// So every level assertion below happens after a `stop()`.
@MainActor
@Suite("Project overview — retained track levels (m23-cv)")
struct ProjectOverviewMeterTests {

    private func overviewTrack(_ store: ProjectStore, _ id: UUID) -> ProjectOverview.Track? {
        store.overview().tracks.first { $0.id == id }
    }

    // MARK: - 1. The critical test: levels survive a stop

    /// Would FAIL on the naive `trackMeters[id]` implementation: at the moment
    /// of the read the live meter has been zeroed by `stop()`, so a naive
    /// projection reports −80/−80 (or 0) for a track that was demonstrably
    /// making sound a line earlier.
    @Test("peakDb/rmsDb still report the last heard level AFTER the transport stops")
    func levelsSurviveStop() {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(name: "Drums")

        store.play()
        engine.trackMeteringHandler?(track.id, MeterFrame(peak: 0.5, rms: 0.25))
        store.stop()

        // The live meter really is dark — the trap this field exists to dodge.
        #expect(store.trackMeters[track.id] == .silence)

        let projected = overviewTrack(store, track.id)
        #expect(projected?.peakDb != nil)
        #expect(abs((projected?.peakDb ?? 0) - (-6.0206)) < 0.01)
        #expect(abs((projected?.rmsDb ?? 0) - (-12.0412)) < 0.01)
    }

    // MARK: - 2. Absence is honest, not a floor reading

    /// Catches "helpfully" defaulting to `.silence`: a track nobody ever heard
    /// would then claim a −80 dB MEASUREMENT that never happened.
    @Test("a track that has never metered reports nil — not 0, not the −80 floor")
    func neverHeardTrackReportsNil() {
        let store = ProjectStore()
        store.engine = FakeEngine()
        let track = store.addTrack(name: "Quiet")

        let projected = overviewTrack(store, track.id)
        #expect(projected?.peakDb == nil)
        #expect(projected?.rmsDb == nil)
    }

    /// Catches a retention predicate that stores every frame it is handed:
    /// silence must never be recorded as an observation.
    @Test("a track that has only ever metered silence still reports nil")
    func silenceOnlyTrackReportsNil() {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(name: "Muted")

        store.play()
        engine.trackMeteringHandler?(track.id, .silence)
        engine.trackMeteringHandler?(track.id, .silence)
        store.stop()

        #expect(store.trackMeters[track.id] == .silence)   // it DID meter
        #expect(store.lastNonSilentTrackMeters[track.id] == nil)
        #expect(overviewTrack(store, track.id)?.peakDb == nil)
    }

    /// Catches an unconditional write in the metering handler: the tail of
    /// silent frames the engine pushes as a note decays would erase the level
    /// that matters.
    @Test("a trailing silent frame does not erase the last heard level")
    func silentFrameDoesNotOverwriteHeardLevel() {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(name: "Bass")

        store.play()
        engine.trackMeteringHandler?(track.id, MeterFrame(peak: 0.5, rms: 0.25))
        engine.trackMeteringHandler?(track.id, .silence)
        store.stop()

        #expect(abs((overviewTrack(store, track.id)?.peakDb ?? 0) - (-6.0206)) < 0.01)
    }

    // MARK: - 3. Clipping reads positive

    /// Catches a conversion clamped to `...0` — the one number a mix agent most
    /// needs to see is the one ABOVE full scale.
    @Test("a clipping frame (peak > 1) projects a POSITIVE peakDb")
    func clippingReportsPositiveDb() {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(name: "Hot")

        store.play()
        engine.trackMeteringHandler?(track.id, MeterFrame(peak: 2.0, rms: 1.0))
        store.stop()

        let projected = overviewTrack(store, track.id)
        #expect((projected?.peakDb ?? -1) > 0)
        #expect(abs((projected?.peakDb ?? 0) - 6.0206) < 0.01)
        #expect(abs((projected?.rmsDb ?? -1) - 0) < 0.0001)   // 1.0 → 0 dBFS
    }

    // MARK: - 4. Lifecycle: the held entry never outlives its track

    /// Catches a retained dictionary that is not pruned with `trackMeters`: a
    /// level attributed to a deleted track is a lie the overview keeps telling.
    /// The second track is the positive control — the drop must be TARGETED.
    @Test("removeTrack drops the held level, and only that track's")
    func removeTrackDropsHeldLevel() throws {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine
        let doomed = store.addTrack(name: "Doomed")
        let keeper = store.addTrack(name: "Keeper")

        store.play()
        engine.trackMeteringHandler?(doomed.id, MeterFrame(peak: 0.5, rms: 0.25))
        engine.trackMeteringHandler?(keeper.id, MeterFrame(peak: 0.5, rms: 0.25))
        store.stop()
        #expect(store.lastNonSilentTrackMeters[doomed.id] != nil)

        _ = try store.removeTrack(id: doomed.id)

        #expect(store.lastNonSilentTrackMeters[doomed.id] == nil)
        #expect(store.lastNonSilentTrackMeters[keeper.id] != nil)
        #expect(overviewTrack(store, keeper.id)?.peakDb != nil)
    }

    /// The undo/redo restore path prunes `trackMeters` for vanished tracks;
    /// catches the held dictionary being forgotten at that second site.
    @Test("undoing a track add prunes its held level too")
    func undoDropsHeldLevel() throws {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(name: "Drums")
        engine.trackMeteringHandler?(track.id, MeterFrame(peak: 0.5, rms: 0.25))
        #expect(store.lastNonSilentTrackMeters[track.id] != nil)

        try store.undo()   // reverses the add — the track vanishes

        #expect(store.lastNonSilentTrackMeters[track.id] == nil)
    }

    /// Catches a level from the PREVIOUS session leaking into a fresh one.
    @Test("project.new clears every held level")
    func newProjectClearsHeldLevels() throws {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(name: "Drums")
        engine.trackMeteringHandler?(track.id, MeterFrame(peak: 0.5, rms: 0.25))
        #expect(!store.lastNonSilentTrackMeters.isEmpty)

        try store.newProject(discardChanges: true)

        #expect(store.lastNonSilentTrackMeters.isEmpty)
    }

    /// m23-dn: `newProject` had a test; `openProject` didn't. Catches
    /// cross-session leakage — opening a DIFFERENT project and having it
    /// report the PREVIOUS project's levels, which is worse than reporting
    /// nothing because it looks like real data an agent would act on. Covers
    /// both retained stores (track + master) at once, since one clear site
    /// touches both.
    @Test("project.open clears every held level (track and master)")
    func openProjectClearsHeldLevels() throws {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(name: "Drums")

        store.play()
        engine.trackMeteringHandler?(track.id, MeterFrame(peak: 0.5, rms: 0.25))
        engine.meteringHandler?(MeterFrame(peak: 0.5, rms: 0.25))
        store.stop()

        // Positive control: the levels are genuinely present before the open —
        // otherwise a test that never established a level would pass trivially.
        #expect(!store.lastNonSilentTrackMeters.isEmpty)
        #expect(store.lastNonSilentMasterMeter != nil)

        // A second, on-disk project to open into. Temp-dir only (m23-aq-2).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m23-dn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let other = ProjectStore()
        other.media = FakeMedia()
        other.addTrack(name: "Other")
        let otherPath = dir.appendingPathComponent("Other").path
        _ = try other.saveProject(to: otherPath)

        _ = try store.openProject(at: otherPath, discardChanges: true)

        #expect(store.lastNonSilentTrackMeters.isEmpty)
        #expect(store.lastNonSilentMasterMeter == nil)
    }

    /// m23-dn: the `recoverFromAutosave` clear site had no test either. Same
    /// leakage catch as `openProjectClearsHeldLevels`, driven through the
    /// crash-recovery path (`CrashRecoveryTests`' fixture idiom: an injected
    /// temp `crashRecovery.directory` + fixed clock, never the real profile).
    /// The levels that must NOT survive are the PRE-recovery (about-to-be-
    /// replaced) session's own — established on `s2` before the recover call,
    /// exactly like `pendingOfferParksAutosave`'s "Bystander" track models the
    /// live session that gets superseded.
    @Test("project.recover clears every held level (track and master)")
    func recoverFromAutosaveClearsHeldLevels() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m23-dn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Session 1: writes the rolling autosave snapshot, then "crashes"
        // (no endCrashDetection — the lock survives).
        let s1 = ProjectStore()
        s1.media = FakeMedia()
        s1.crashRecovery.directory = dir
        s1.crashRecovery.clock = { Date(timeIntervalSince1970: 1000) }
        _ = s1.beginCrashDetection()
        s1.addTrack(name: "Recovered")
        await s1.autosaveTick()

        // Session 2 relaunches on the same dir → the stale lock is a crash,
        // and s1's snapshot is on offer.
        let engine = FakeEngine()
        let s2 = ProjectStore()
        s2.engine = engine
        s2.crashRecovery.directory = dir
        s2.crashRecovery.clock = { Date(timeIntervalSince1970: 2000) }
        #expect(s2.beginCrashDetection())
        #expect(s2.recoveryStatus().available)

        // s2's OWN pre-recovery session hears something before it gets replaced.
        let track = s2.addTrack(name: "Bystander")
        s2.play()
        engine.trackMeteringHandler?(track.id, MeterFrame(peak: 0.5, rms: 0.25))
        engine.meteringHandler?(MeterFrame(peak: 0.5, rms: 0.25))
        s2.stop()

        // Positive control: the levels are genuinely present before recovery.
        #expect(!s2.lastNonSilentTrackMeters.isEmpty)
        #expect(s2.lastNonSilentMasterMeter != nil)

        let outcome = try s2.recoverFromAutosave(accept: true)
        #expect(outcome == .recovered(warnings: []))

        #expect(s2.lastNonSilentTrackMeters.isEmpty)
        #expect(s2.lastNonSilentMasterMeter == nil)
    }

    // MARK: - 5. Wire shape

    /// Catches a `-inf`/`NaN` reaching the wire (JSON has neither: an infinity
    /// is an encode failure or a downstream decode failure, not a cosmetic
    /// wart) AND catches the optional fields being emitted as `null`/0 for a
    /// track that was never heard.
    @Test("overview JSON round-trips finite levels and omits the keys when never heard")
    func jsonRoundTrip() throws {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine
        let heard = store.addTrack(name: "Heard")
        let silent = store.addTrack(name: "Never")
        // A whisper-quiet but non-zero frame: the floor-clamp path, which is
        // exactly where a naive `20*log10` would have produced −inf.
        let floored = store.addTrack(name: "Floored")

        store.play()
        engine.trackMeteringHandler?(heard.id, MeterFrame(peak: 0.5, rms: 0.25))
        engine.trackMeteringHandler?(floored.id, MeterFrame(peak: 1e-9, rms: 1e-9))
        store.stop()

        let data = try JSONEncoder().encode(store.overview())
        let decoded = try JSONDecoder().decode(ProjectOverview.self, from: data)

        for track in decoded.tracks {
            if let peak = track.peakDb { #expect(peak.isFinite) }
            if let rms = track.rmsDb { #expect(rms.isFinite) }
        }
        #expect(decoded.tracks.first { $0.id == heard.id }?.peakDb != nil)
        #expect(decoded.tracks.first { $0.id == floored.id }?.peakDb == MeterLevel.floorDb)
        #expect(decoded.tracks.first { $0.id == silent.id }?.peakDb == nil)

        // The keys are ABSENT, not null — the overview's token budget is the
        // whole reason it exists.
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let tracks = object?["tracks"] as? [[String: Any]] ?? []
        let neverHeard = tracks.first { $0["name"] as? String == "Never" }
        #expect(neverHeard != nil)
        #expect(neverHeard?["peakDb"] == nil)
        #expect(neverHeard?["rmsDb"] == nil)
    }
}

/// m23-dm: the MASTER-BUS level in the agent-facing `project.overview`
/// projection — m23-cv's shape one level up.
///
/// SAME TRAP, SAME DEFENCE: `ProjectStore.stop()` zeroes `masterMeter` to
/// `.silence` (`ProjectStore.swift`, one line below the per-track loop), so a
/// projection wired to `masterMeter` reports silence on every agent read and
/// still passes any test that asserts DURING playback. Every level assertion
/// below therefore happens after a `stop()`, with `masterMeter == .silence`
/// asserted at read time as an embedded positive control.
///
/// WHY THE MASTER MATTERS SEPARATELY: it is the reference the per-track
/// numbers are read against — "the kick is 8 dB under the master" is a
/// judgement, "the kick is −14 dBFS" is a number that still needs one.
@MainActor
@Suite("Project overview — retained master level (m23-dm)")
struct ProjectOverviewMasterMeterTests {

    // MARK: - 1. The critical test: the master level survives a stop

    /// Would FAIL on the naive `masterMeter` projection: at the moment of the
    /// read the live master meter has been zeroed by `stop()`, so a naive
    /// projection reports −80 (or 0) for a mix that was demonstrably making
    /// sound a line earlier.
    @Test("master peakDb/rmsDb still report the last heard level AFTER the transport stops")
    func masterLevelSurvivesStop() {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine

        store.play()
        engine.meteringHandler?(MeterFrame(peak: 0.5, rms: 0.25))
        store.stop()

        // The live master meter really is dark — the trap this field exists to
        // dodge, asserted at READ TIME rather than assumed.
        #expect(store.masterMeter == .silence)

        let master = store.overview().master
        #expect(master.peakDb != nil)
        #expect(abs((master.peakDb ?? 0) - (-6.0206)) < 0.01)
        #expect(abs((master.rmsDb ?? 0) - (-12.0412)) < 0.01)
        // The pre-existing field is untouched by the addition.
        #expect(master.volume == store.masterVolume)
    }

    // MARK: - 2. Absence is honest, not a floor reading

    /// Catches "helpfully" defaulting to `.silence`: a session nobody has
    /// played would claim a −80 dB MEASUREMENT of the mix that never happened.
    @Test("a master that has never metered reports nil — not 0, not the −80 floor")
    func neverHeardMasterReportsNil() {
        let store = ProjectStore()
        store.engine = FakeEngine()

        let master = store.overview().master
        #expect(master.peakDb == nil)
        #expect(master.rmsDb == nil)
        #expect(store.lastNonSilentMasterMeter == nil)
    }

    /// Catches a retention predicate that stores every frame it is handed:
    /// silence must never be recorded as an observation.
    @Test("a master that has only ever metered silence still reports nil")
    func silenceOnlyMasterReportsNil() {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine

        store.play()
        engine.meteringHandler?(.silence)
        engine.meteringHandler?(.silence)
        store.stop()

        #expect(store.masterMeter == .silence)   // it DID meter
        #expect(store.lastNonSilentMasterMeter == nil)
        #expect(store.overview().master.peakDb == nil)
    }

    /// Catches an unconditional write in the master metering handler: the tail
    /// of silent frames the engine pushes as the mix decays would erase the
    /// level that matters.
    @Test("a trailing silent master frame does not erase the last heard level")
    func silentFrameDoesNotOverwriteHeardMasterLevel() {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine

        store.play()
        engine.meteringHandler?(MeterFrame(peak: 0.5, rms: 0.25))
        engine.meteringHandler?(.silence)
        store.stop()

        #expect(abs((store.overview().master.peakDb ?? 0) - (-6.0206)) < 0.01)
    }

    // MARK: - 3. Clipping reads positive

    /// Catches a conversion clamped to `...0`. On the MASTER this is the single
    /// most consequential number in the projection: a positive peak here is a
    /// clipped mixdown, not merely a hot track.
    @Test("a clipping master frame (peak > 1) projects a POSITIVE peakDb")
    func clippingMasterReportsPositiveDb() {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine

        store.play()
        engine.meteringHandler?(MeterFrame(peak: 2.0, rms: 1.0))
        store.stop()

        let master = store.overview().master
        #expect((master.peakDb ?? -1) > 0)
        #expect(abs((master.peakDb ?? 0) - 6.0206) < 0.01)
        #expect(abs((master.rmsDb ?? -1) - 0) < 0.0001)   // 1.0 → 0 dBFS
    }

    // MARK: - 4. Lifecycle: the held frame never crosses a session boundary

    /// Catches a master level from the PREVIOUS session leaking into a fresh
    /// one — the reading would look plausible and describe another song.
    @Test("project.new clears the held master level")
    func newProjectClearsHeldMasterLevel() throws {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine
        engine.meteringHandler?(MeterFrame(peak: 0.5, rms: 0.25))
        #expect(store.lastNonSilentMasterMeter != nil)

        try store.newProject(discardChanges: true)

        #expect(store.lastNonSilentMasterMeter == nil)
        #expect(store.overview().master.peakDb == nil)
    }

    /// The stop-zeroing is the UI contract this field exists to work around;
    /// catches someone "fixing" the retained value by making `stop()` clear it
    /// too (which would restore the exact bug) or by making `stop()` stop
    /// zeroing the live meter (which would leave the meter lit at rest).
    @Test("stop zeroes the LIVE master meter and leaves the retained one intact")
    func stopZeroesLiveMeterOnly() {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine

        store.play()
        engine.meteringHandler?(MeterFrame(peak: 0.5, rms: 0.25))
        #expect(store.masterMeter == MeterFrame(peak: 0.5, rms: 0.25))

        store.stop()

        #expect(store.masterMeter == .silence)
        #expect(store.lastNonSilentMasterMeter == MeterFrame(peak: 0.5, rms: 0.25))
    }

    // MARK: - 5. Wire shape

    /// Catches a `-inf`/`NaN` reaching the wire (JSON has neither) AND catches
    /// the optional fields being emitted as `null`/0 on a session that has
    /// never been played.
    @Test("overview JSON round-trips a finite master level and omits the keys when never heard")
    func masterJSONRoundTrip() throws {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine

        // (a) Never heard: both keys ABSENT, not null.
        let silentData = try JSONEncoder().encode(store.overview())
        let silentObject = try JSONSerialization.jsonObject(with: silentData) as? [String: Any]
        let silentMaster = silentObject?["master"] as? [String: Any]
        #expect(silentMaster != nil)
        #expect(silentMaster?["volume"] != nil)
        #expect(silentMaster?["peakDb"] == nil)
        #expect(silentMaster?["rmsDb"] == nil)

        // (b) A whisper-quiet but non-zero frame: the floor-clamp path, which
        // is exactly where a naive `20*log10` would have produced −inf.
        store.play()
        engine.meteringHandler?(MeterFrame(peak: 1e-9, rms: 1e-9))
        store.stop()

        let data = try JSONEncoder().encode(store.overview())
        let decoded = try JSONDecoder().decode(ProjectOverview.self, from: data)
        #expect(decoded.master.peakDb?.isFinite == true)
        #expect(decoded.master.rmsDb?.isFinite == true)
        #expect(decoded.master.peakDb == MeterLevel.floorDb)
    }

    /// The master's dB must be the SAME conversion the tracks use — catches a
    /// second `20*log10` growing on this path with a different floor or a
    /// different multiplier.
    @Test("master dB routes through MeterLevel, identically to the per-track fields")
    func masterRoutesThroughTheOneConversion() {
        let engine = FakeEngine()
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(name: "Drums")

        let frame = MeterFrame(peak: 0.37, rms: 0.11)
        store.play()
        engine.meteringHandler?(frame)
        engine.trackMeteringHandler?(track.id, frame)
        store.stop()

        let overview = store.overview()
        let projectedTrack = overview.tracks.first { $0.id == track.id }
        #expect(overview.master.peakDb == MeterLevel.dbFS(0.37))
        #expect(overview.master.rmsDb == MeterLevel.dbFS(0.11))
        #expect(overview.master.peakDb == projectedTrack?.peakDb)
        #expect(overview.master.rmsDb == projectedTrack?.rmsDb)
    }
}

/// The ONE meter-amplitude → dBFS conversion. Pinned here so a second copy
/// growing elsewhere has something to disagree with.
@Suite("Meter level — the one linear→dBFS conversion (m23-cv)")
struct MeterLevelTests {

    /// Catches a drifting floor: it must stay the SAME −80 the rest of the
    /// project clamps to, not a locally invented constant.
    @Test("the floor is the house floor, −80 dBFS")
    func floorIsTheHouseFloor() {
        #expect(MeterLevel.floorDb == Double(MasterAnalysisSnapshot.floorDB))
        #expect(MeterLevel.floorDb == -80)
    }

    /// Catches a wrong multiplier (10·log10 instead of 20·log10 — the classic
    /// power-vs-amplitude slip, which would halve every reading).
    @Test("amplitude reference points: 1.0 → 0 dB, 0.5 → −6 dB, 2.0 → +6 dB")
    func referencePoints() {
        #expect(abs(MeterLevel.dbFS(1.0) - 0) < 0.0001)
        #expect(abs(MeterLevel.dbFS(0.5) - (-6.0206)) < 0.001)
        #expect(abs(MeterLevel.dbFS(2.0) - 6.0206) < 0.001)
        #expect(abs(MeterLevel.dbFS(0.25) - (-12.0412)) < 0.001)
    }

    /// Catches every route to a non-finite JSON number. `log10(0)` is `-inf`
    /// and `log10(-1)` is `NaN`; both must land on the floor instead.
    @Test("zero, negative and non-finite amplitudes all read as the floor, finitely")
    func nonFiniteInputsAreFloored() {
        for amplitude in [Float(0), -0.5, -1, 1e-30, .nan, .infinity, -.infinity] {
            let db = MeterLevel.dbFS(amplitude)
            #expect(db.isFinite)
            #expect(db == MeterLevel.floorDb)
        }
    }

    /// Catches the retention predicate accepting a broken engine push, which
    /// would be published as −80 and read as "this track is quiet" when the
    /// truth is "this measurement is garbage".
    @Test("hasSignal rejects silence and non-finite frames, accepts any real level")
    func hasSignalPredicate() {
        #expect(MeterFrame.silence.hasSignal == false)
        #expect(MeterFrame(peak: 0.001, rms: 0).hasSignal)
        #expect(MeterFrame(peak: 0, rms: 0.001).hasSignal)
        #expect(MeterFrame(peak: 2.0, rms: 1.0).hasSignal)
        #expect(MeterFrame(peak: .nan, rms: 0.5).hasSignal == false)
        #expect(MeterFrame(peak: .infinity, rms: 0.5).hasSignal == false)
        #expect(MeterFrame(peak: 0.5, rms: .nan).hasSignal == false)
    }

    /// `MeterFrame`'s accessors must be the same conversion, not a second one.
    @Test("MeterFrame.peakDb/rmsDb route through MeterLevel")
    func frameAccessorsRouteThroughTheHelper() {
        let frame = MeterFrame(peak: 0.5, rms: 0.25)
        #expect(frame.peakDb == MeterLevel.dbFS(0.5))
        #expect(frame.rmsDb == MeterLevel.dbFS(0.25))
        #expect(MeterFrame.silence.peakDb == MeterLevel.floorDb)
    }
}
