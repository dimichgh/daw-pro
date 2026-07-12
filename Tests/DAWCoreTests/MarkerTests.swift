import Foundation
import Testing
@testable import DAWCore

/// Session markers (m11-c) — the `Marker` value type, the `ProjectStore`
/// mutations (add/remove/rename/move) with their one-undo-step + coalescing
/// contract, the beat-sorted (ties-stable) exposure, persistence (additive,
/// omit-when-empty, old-bundle-loads), and the overview/snapshot projections.
@MainActor
@Suite("Session markers (m11-c)")
struct MarkerTests {
    // MARK: - Value type

    @Test("Marker clamps a negative beat to 0 (init and decode)")
    func markerClampsBeat() throws {
        #expect(Marker(name: "X", beat: -5).beat == 0)
        // Decode routes through the clamping init; a missing name defaults, id required.
        let json = #"{"id":"\#(UUID().uuidString)","name":"Y","beat":-2}"#
        let decoded = try JSONDecoder().decode(Marker.self, from: Data(json.utf8))
        #expect(decoded.beat == 0)
        #expect(decoded.name == "Y")
    }

    @Test("Marker decode tolerates a missing name")
    func markerDecodeMissingName() throws {
        let json = #"{"id":"\#(UUID().uuidString)","beat":4}"#
        let decoded = try JSONDecoder().decode(Marker.self, from: Data(json.utf8))
        #expect(decoded.name == "Marker")
        #expect(decoded.beat == 4)
    }

    // MARK: - addMarker

    @Test("addMarker returns the marker, auto-names when empty, and exposes sorted by beat")
    func addAndSort() {
        let store = ProjectStore()
        let c = store.addMarker(name: "Chorus", beat: 16)
        let a = store.addMarker(name: nil, beat: 4)      // auto "Marker 2"
        let b = store.addMarker(name: "", beat: 8)        // auto "Marker 3"

        #expect(c.name == "Chorus")
        #expect(a.name == "Marker 2")
        #expect(b.name == "Marker 3")
        // Exposed SORTED by beat regardless of insertion order.
        #expect(store.markers.map(\.beat) == [4, 8, 16])
        #expect(store.markers.map(\.name) == ["Marker 2", "Marker 3", "Chorus"])
    }

    @Test("equal-beat markers keep insertion order (stable sort)")
    func stableTies() {
        let store = ProjectStore()
        let first = store.addMarker(name: "First", beat: 8)
        let second = store.addMarker(name: "Second", beat: 8)
        let atZero = store.addMarker(name: "Zero", beat: 0)
        #expect(store.markers.map(\.name) == ["Zero", "First", "Second"])
        #expect(store.markers[1].id == first.id)
        #expect(store.markers[2].id == second.id)
        _ = atZero
    }

    @Test("addMarker clamps a negative beat to 0")
    func addClamps() {
        let store = ProjectStore()
        let m = store.addMarker(name: "Neg", beat: -3)
        #expect(m.beat == 0)
        #expect(store.markers.first?.beat == 0)
    }

    // MARK: - one undo step per mutation

    @Test("each marker mutation is exactly one undo step; undo/redo restore markers")
    func oneUndoPerMutation() throws {
        let store = ProjectStore()
        #expect(store.journal.undoStack.count == 0)

        let m = store.addMarker(name: "Verse", beat: 4)
        #expect(store.journal.undoStack.count == 1)
        #expect(store.undoLabel == "Add Marker 'Verse'")

        _ = try store.renameMarker(id: m.id, name: "Chorus")
        #expect(store.journal.undoStack.count == 2)
        #expect(store.undoLabel == "Rename Marker 'Chorus'")

        _ = try store.moveMarker(id: m.id, beat: 12)
        #expect(store.journal.undoStack.count == 3)
        #expect(store.undoLabel == "Move Marker 'Chorus'")

        try store.removeMarker(id: m.id)
        #expect(store.journal.undoStack.count == 4)
        #expect(store.undoLabel == "Remove Marker 'Chorus'")
        #expect(store.markers.isEmpty)

        // Undo the remove → the marker returns at its moved beat with its new name.
        try store.undo()
        #expect(store.markers.count == 1)
        #expect(store.markers[0].name == "Chorus")
        #expect(store.markers[0].beat == 12)

        // Undo the move → back to beat 4.
        try store.undo()
        #expect(store.markers[0].beat == 4)

        // Redo the move → forward to 12 again.
        try store.redo()
        #expect(store.markers[0].beat == 12)
    }

    // MARK: - move coalescing

    @Test("a move scrub within the coalescing window folds into ONE undo step")
    func moveCoalesces() throws {
        let store = ProjectStore()
        let m = store.addMarker(name: "Drop", beat: 8)   // one entry
        var clock = ContinuousClock.now
        store.journal.now = { clock }

        _ = try store.moveMarker(id: m.id, beat: 10)
        clock = clock.advanced(by: .milliseconds(200))
        _ = try store.moveMarker(id: m.id, beat: 12)
        clock = clock.advanced(by: .milliseconds(200))
        _ = try store.moveMarker(id: m.id, beat: 16)

        // addMarker (1) + the three coalesced moves (1) = 2 undo entries.
        #expect(store.journal.undoStack.count == 2)
        #expect(store.undoLabel == "Move Marker 'Drop'")

        // One undo restores the marker to its pre-scrub beat.
        try store.undo()
        #expect(store.markers[0].beat == 8)
    }

    @Test("moves of DIFFERENT markers do not coalesce (distinct keys)")
    func differentMarkersDontCoalesce() throws {
        let store = ProjectStore()
        let a = store.addMarker(name: "A", beat: 4)
        let b = store.addMarker(name: "B", beat: 8)
        var clock = ContinuousClock.now
        store.journal.now = { clock }
        _ = try store.moveMarker(id: a.id, beat: 5)
        clock = clock.advanced(by: .milliseconds(100))
        _ = try store.moveMarker(id: b.id, beat: 9)
        // two adds + two independent moves = 4 entries.
        #expect(store.journal.undoStack.count == 4)
    }

    // MARK: - rename rules

    @Test("renameMarker: empty/unchanged is a no-op; a real change commits one step")
    func renameRules() throws {
        let store = ProjectStore()
        let m = store.addMarker(name: "Bridge", beat: 4)
        let before = store.journal.undoStack.count

        // Unchanged (with padding) → no-op.
        _ = try store.renameMarker(id: m.id, name: " Bridge ")
        #expect(store.journal.undoStack.count == before)
        // Empty → no-op.
        _ = try store.renameMarker(id: m.id, name: "   ")
        #expect(store.journal.undoStack.count == before)
        #expect(store.markers[0].name == "Bridge")

        // Real change (trimmed) commits.
        let updated = try store.renameMarker(id: m.id, name: "  Outro  ")
        #expect(updated.name == "Outro")
        #expect(store.journal.undoStack.count == before + 1)
        #expect(store.markers[0].name == "Outro")
    }

    // MARK: - not-found errors

    @Test("remove/rename/move on an unknown id throw markerNotFound")
    func notFound() {
        let store = ProjectStore()
        let ghost = UUID()
        #expect(throws: ProjectError.self) { try store.removeMarker(id: ghost) }
        #expect(throws: ProjectError.self) { _ = try store.renameMarker(id: ghost, name: "X") }
        #expect(throws: ProjectError.self) { _ = try store.moveMarker(id: ghost, beat: 1) }
    }

    // MARK: - projections

    @Test("overview reports markerCount; snapshot carries the full marker list")
    func projections() {
        let store = ProjectStore()
        #expect(store.overview().markerCount == 0)
        #expect(store.snapshot().markers == nil)   // empty → omitted

        store.addMarker(name: "Intro", beat: 0)
        store.addMarker(name: "Chorus", beat: 16)
        #expect(store.overview().markerCount == 2)
        let snapMarkers = store.snapshot().markers
        #expect(snapMarkers?.count == 2)
        #expect(snapMarkers?.map(\.name) == ["Intro", "Chorus"])
    }

    @Test("newProject clears markers")
    func newProjectClears() throws {
        let store = ProjectStore()
        store.addMarker(name: "X", beat: 4)
        try store.newProject(discardChanges: true)
        #expect(store.markers.isEmpty)
    }

    // MARK: - persistence

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("marker-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("save then open round-trips markers (beat-sorted)")
    func persistenceRoundTrip() throws {
        let dir = tempDir()
        let store = ProjectStore()
        store.addMarker(name: "Chorus", beat: 16)
        store.addMarker(name: "Intro", beat: 0)
        store.addMarker(name: "Verse", beat: 4)

        let path = dir.appendingPathComponent("Markers").path
        try store.saveProject(to: path)

        let reopened = ProjectStore()
        try reopened.openProject(at: path)
        #expect(reopened.markers.map(\.name) == ["Intro", "Verse", "Chorus"])
        #expect(reopened.markers.map(\.beat) == [0, 4, 16])
    }

    @Test("a project with no markers omits the markers key (byte-identical to pre-marker)")
    func emptyOmitsKey() throws {
        let doc = ProjectDocument(
            name: "Empty", transport: TransportState(), tracks: [],
            masterVolume: 1, mediaRefs: [:], grooveTemplates: [], markers: [])
        #expect(doc.markers == nil)
        let data = try JSONEncoder().encode(doc)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("\"markers\""))
    }

    @Test("an old bundle with no markers key loads as no markers")
    func oldBundleLoads() throws {
        let dir = tempDir()
        // Hand-write a minimal document JSON WITHOUT the markers key (a pre-m11-c file).
        let json = """
        {"schemaVersion":\(ProjectBundle.currentSchemaVersion),"name":"Old",\
        "masterVolume":1,"transport":{"tempoBPM":120},"tracks":[]}
        """
        let bundleURL = dir.appendingPathComponent("Old.dawproj", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: bundleURL.appendingPathComponent("project.json"))

        let store = ProjectStore()
        _ = try store.openProject(at: bundleURL.path)
        #expect(store.markers.isEmpty)
        #expect(store.projectName == "Old")
    }

    @Test("markers ride EditState so undo/redo restore them across other edits")
    func markersRideEditState() throws {
        let store = ProjectStore()
        store.addMarker(name: "M", beat: 4)
        _ = store.addTrack(name: "T", kind: .audio)   // a non-marker edit on top
        #expect(store.markers.count == 1)
        try store.undo()                               // undo the track add
        #expect(store.markers.count == 1)              // marker unaffected
        try store.undo()                               // undo the marker add
        #expect(store.markers.isEmpty)
    }
}
