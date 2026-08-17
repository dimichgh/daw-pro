import Foundation
import Testing
@testable import DAWCore

/// m25-c-2 — `ProjectStore.compEditRefusal`, the ASK form of the
/// `requireNotCompMember` guard.
///
/// It exists so a panel can refuse BEFORE the press instead of discovering the
/// refusal by throwing after it (the reported bug: Humanize/Quantize on a
/// take-comp member offered Apply, threw, got swallowed by `try?`, and closed the
/// panel having changed nothing). The only property that matters is therefore
/// **agreement**: what the ask predicts is exactly what the act does. A query
/// that answered "fine" and then threw, or answered "refused" for a clip the
/// store would happily edit, would be worse than the silence it replaces.
///
/// Every refusal row here is paired with a control that flips exactly ONE input
/// and lands somewhere else — a fixture that is a comp member AND an audio clip
/// proves nothing about which guard fired.
@MainActor
@Suite("ProjectStore — compEditRefusal (m25-c-2)")
struct CompEditRefusalTests {

    private func projectError(_ body: () throws -> Void) -> ProjectError? {
        do { try body(); return nil }
        catch let e as ProjectError { return e }
        catch { Issue.record("unexpected error type: \(error)"); return nil }
    }

    /// The settings the panel's Apply builds at its defaults — 1/16 grid, full
    /// strength, straight.
    private var settings: QuantizeSettings {
        QuantizeSettings(gridBeats: 0.25, strength: 1, swingPercent: 50, quantizeEnds: false)
    }

    /// A track with TWO overlapping MIDI takes grouped under `groupName`, plus one
    /// ORDINARY MIDI clip on the same track that is not in any group.
    ///
    /// The group name is deliberately unlike every clip name: the guard falls back
    /// to the CLIP's name when it cannot find the group, so a message asserted
    /// against a shared string would pass through the fallback and prove nothing.
    private func compFixture(groupName: String = "Chorus Comp")
        throws -> (store: ProjectStore, trackID: UUID, member: UUID, ordinary: UUID, groupID: UUID) {
        let takeA = Clip(name: "Take 1", startBeat: 0, lengthBeats: 4,
                         notes: [MIDINote(pitch: 60, startBeat: 0.3, lengthBeats: 1)])
        let takeB = Clip(name: "Take 2", startBeat: 0, lengthBeats: 4,
                         notes: [MIDINote(pitch: 62, startBeat: 0.4, lengthBeats: 1)])
        let solo = Clip(name: "Riff", startBeat: 8, lengthBeats: 4,
                        notes: [MIDINote(pitch: 64, startBeat: 0.2, lengthBeats: 1)])
        let track = Track(name: "Keys", kind: .instrument, clips: [takeA, takeB, solo])
        let store = ProjectStore(tracks: [track])
        let group = try store.groupTakes(trackId: track.id, clipIds: [takeA.id, takeB.id],
                                         name: groupName)
        let member = try #require(store.tracks[0].clips.first { $0.takeGroupID != nil })
        return (store, track.id, member.id, solo.id, group.id)
    }

    // MARK: - The refusal, and the control that flips one input

    @Test("comp member refuses and NAMES THE GROUP; the ungrouped clip on the same track does not")
    func memberRefusesOrdinaryDoesNot() throws {
        let f = try compFixture(groupName: "Chorus Comp")

        let refusal = try #require(f.store.compEditRefusal(clipID: f.member),
                                   "a take-comp member must refuse")
        guard case .clipInTakeGroup(let name, let clipID) = refusal else {
            Issue.record("expected clipInTakeGroup, got \(refusal)"); return
        }
        #expect(name == "Chorus Comp")          // the GROUP's name, not the clip's
        #expect(clipID == f.member)             // the m23-am anchor payload
        let message = try #require(refusal.errorDescription)
        #expect(message.contains("Chorus Comp"))
        #expect(message.contains("take.flatten"))   // the remedy is named

        // ONE input flipped — same store, same track, same kind, same notes; it is
        // simply not in the group. If this also refused, the query would be
        // answering "is this a clip?" and every assertion above would be vacuous.
        #expect(f.store.compEditRefusal(clipID: f.ordinary) == nil)
    }

    @Test("kind is not the question: an AUDIO comp member refuses, an ungrouped audio clip does not")
    func membershipNotKind() throws {
        let takeA = Clip(name: "Vox 1", startBeat: 0, lengthBeats: 4,
                         audioFileURL: URL(fileURLWithPath: "/a.wav"))
        let takeB = Clip(name: "Vox 2", startBeat: 0, lengthBeats: 4,
                         audioFileURL: URL(fileURLWithPath: "/b.wav"))
        let solo = Clip(name: "Lead", startBeat: 8, lengthBeats: 4,
                        audioFileURL: URL(fileURLWithPath: "/c.wav"))
        let track = Track(name: "Vox", kind: .audio, clips: [takeA, takeB, solo])
        let store = ProjectStore(tracks: [track])
        _ = try store.groupTakes(trackId: track.id, clipIds: [takeA.id, takeB.id], name: "Vox Comp")
        let member = try #require(store.tracks[0].clips.first { $0.takeGroupID != nil })

        #expect(store.compEditRefusal(clipID: member.id) != nil)
        #expect(store.compEditRefusal(clipID: solo.id) == nil)   // one input flipped
    }

    @Test("an unknown clip id is nil, NOT a refusal — a different question, answered elsewhere")
    func unknownClipIsNotARefusal() throws {
        let f = try compFixture()
        let bogus = UUID()
        #expect(f.store.compEditRefusal(clipID: bogus) == nil)
        // ... and the act still refuses it, with the error that names the real
        // problem. `nil` here means "the comp guard would not bite", never "this
        // edit will succeed".
        let err = projectError {
            _ = try f.store.humanizeClipNotes(clipID: bogus, timingBeats: 0.02,
                                              velocityRange: 8, seed: 1)
        }
        guard case .clipNotFound? = err else {
            Issue.record("expected clipNotFound, got \(String(describing: err))"); return
        }
    }

    // MARK: - The property that makes ask-then-act honest

    @Test("the ask PREDICTS the act, clip by clip, for BOTH verbs")
    func askPredictsAct() throws {
        let f = try compFixture()
        // Every clip in the project, refusing and not, in one table. Both verbs
        // run the same guard, so a divergence in either direction is a bug.
        let rows: [(label: String, clipID: UUID, expectRefusal: Bool)] = [
            ("comp member", f.member, true),
            ("ordinary MIDI clip", f.ordinary, false),
        ]
        for row in rows {
            let asked = f.store.compEditRefusal(clipID: row.clipID) != nil
            #expect(asked == row.expectRefusal, "ask disagreed for \(row.label)")

            let humanized = projectError {
                _ = try f.store.humanizeClipNotes(clipID: row.clipID, timingBeats: 0.02,
                                                  velocityRange: 8, seed: 7)
            }
            let quantized = projectError {
                _ = try f.store.quantizeClipNotes(clipId: row.clipID, settings: self.settings)
            }
            if row.expectRefusal {
                guard case .clipInTakeGroup? = humanized else {
                    Issue.record("humanize should have thrown clipInTakeGroup for \(row.label), got \(String(describing: humanized))")
                    continue
                }
                guard case .clipInTakeGroup? = quantized else {
                    Issue.record("quantize should have thrown clipInTakeGroup for \(row.label), got \(String(describing: quantized))")
                    continue
                }
            } else {
                #expect(humanized == nil, "humanize refused the \(row.label) the ask cleared")
                #expect(quantized == nil, "quantize refused the \(row.label) the ask cleared")
            }
        }
    }

    // MARK: - The remedy the message names actually works

    @Test("flattening the group clears the refusal, and the notes become editable")
    func flattenClearsTheRefusal() throws {
        let f = try compFixture()
        #expect(f.store.compEditRefusal(clipID: f.member) != nil)

        _ = try f.store.flattenTakeGroup(trackId: f.trackID, groupId: f.groupID)

        // The comp member's id may not survive a flatten, so ask about whatever
        // MIDI clips the track now holds: none of them may still refuse.
        let survivors = f.store.tracks[0].clips.map(\.id)
        #expect(!survivors.isEmpty)
        for id in survivors {
            #expect(f.store.compEditRefusal(clipID: id) == nil,
                    "a clip still refuses after flatten — the remedy the message names does not work")
        }
        // And the act agrees: humanize now succeeds on one of them.
        let target = try #require(f.store.tracks[0].clips.first { $0.notes?.isEmpty == false })
        #expect(throws: Never.self) {
            _ = try f.store.humanizeClipNotes(clipID: target.id, timingBeats: 0.02,
                                              velocityRange: 8, seed: 3)
        }
    }
}
