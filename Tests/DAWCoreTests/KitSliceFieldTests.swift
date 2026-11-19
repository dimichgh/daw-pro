import Foundation
import Testing
@testable import DAWCore

// m39-w4-6 — design `docs/design/2026-10-07-loop-drum-depth.md` §5.3 and gate C7: the ONE new stored field,
// `SamplerZone.drumRole`. Optional on every door: a JSON written before it existed still decodes (to nil), a
// value from a newer version decodes to nil instead of failing the open, and a kit-sorted project keeps its
// roles AND its hat choke across save and open.
//
// NOT `@MainActor`: values and the document codec only.
@Suite("Kit slicing — SamplerZone.drumRole is optional everywhere (m39-w4-6 §5.3, C7)")
struct KitSliceFieldTests {

    static let url = URL(fileURLWithPath: "/tmp/w46-field/kit.wav")

    static func sortedJSON(_ data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data)
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                      as: UTF8.self)
    }

    @Test("SamplerZone: a zone JSON without drumRole decodes to nil; with it, to the role")
    func zoneCodableTreatsTheKeyAsOptional() throws {
        let zone = SamplerZone(audioFileURL: Self.url, rootPitch: 42, minPitch: 42, maxPitch: 42,
                               chokeGroup: 0, drumRole: .closedHat)
        let full = try JSONEncoder().encode(zone)
        #expect(try Self.sortedJSON(full).contains("\"drumRole\":\"closedHat\""), "control: the key is written")
        #expect(try JSONDecoder().decode(SamplerZone.self, from: full).drumRole == .closedHat)
        var object = try #require(try JSONSerialization.jsonObject(with: full) as? [String: Any])
        object.removeValue(forKey: "drumRole")
        let without = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(SamplerZone.self, from: without)
        #expect(decoded.drumRole == nil)
        #expect(decoded.chokeGroup == 0, "control: the neighbouring field still decodes")
        // nil never encodes: a zone that never heard of drum roles keeps its old shape.
        let plain = SamplerZone(audioFileURL: Self.url)
        #expect(try !Self.sortedJSON(JSONEncoder().encode(plain)).contains("drumRole"))
    }

    @Test("SamplerZoneDocument: absent → nil, a newer version's role → nil (the open never fails), present → the role")
    func documentTreatsTheKeyAsOptional() throws {
        let zone = SamplerZone(audioFileURL: Self.url, rootPitch: 36, minPitch: 36, maxPitch: 36,
                               drumRole: .kick)
        let document = SamplerZoneDocument(from: zone, media: "media/kit.wav")
        let data = try JSONEncoder().encode(document)
        #expect(try Self.sortedJSON(data).contains("\"drumRole\":\"kick\""))
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "drumRole")
        let absent = try JSONDecoder().decode(SamplerZoneDocument.self,
                                              from: JSONSerialization.data(withJSONObject: object))
        #expect(absent.drumRole == nil)
        object["drumRole"] = "cowbell"
        let newer = try JSONDecoder().decode(SamplerZoneDocument.self,
                                             from: JSONSerialization.data(withJSONObject: object))
        #expect(newer.drumRole == "cowbell", "the document keeps the text it read")
        let plain = SamplerZoneDocument(from: SamplerZone(audioFileURL: Self.url), media: nil)
        #expect(try !Self.sortedJSON(JSONEncoder().encode(plain)).contains("drumRole"), "nil never encodes")
    }

    static func kitTrack() -> Track {
        let roles: [(Int, DrumVoice?)] = [(36, .kick), (38, .snare), (42, .closedHat), (46, .openHat), (84, nil)]
        let zones = roles.enumerated().map { index, entry in
            SamplerZone(audioFileURL: Self.url, rootPitch: entry.0, minPitch: entry.0, maxPitch: entry.0,
                        startFrame: index * 24_000, endFrame: (index + 1) * 24_000,
                        chokeGroup: (entry.1 == .closedHat || entry.1 == .openHat) ? 0 : nil,
                        drumRole: entry.1)
        }
        var sampler = SamplerParams(zones: zones, gain: 1)
        sampler.markSliceKit()
        return Track(name: "Kit", kind: .instrument,
                     instrument: InstrumentDescriptor(kind: .sampler, sampler: sampler))
    }

    @Test("C7: a kit-sorted project keeps every zone's drumRole AND the hats' choke group across save and open")
    func kitSortedProjectRoundTrips() throws {
        let track = Self.kitTrack()
        let zones = try #require(track.instrument?.sampler?.zones)
        var refs: [UUID: String?] = [:]
        for zone in zones { refs[zone.id] = zone.audioFileURL.path }
        let document = ProjectDocument(name: "w46", transport: TransportState(), tracks: [track],
                                       masterVolume: 1, mediaRefs: refs)
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("w46-c7-kit-\(UUID().uuidString).dawproj", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        try ProjectBundle.write(document: document,
                                plan: ProjectBundle.MediaPlan(copies: [], refs: [:], warnings: []), to: bundle)
        let text = String(decoding: try Data(contentsOf: bundle.appendingPathComponent("project.json")),
                          as: UTF8.self)
        #expect(text.contains("\"drumRole\" : \"openHat\""), "control: the role reached the file")
        let reopened = try ProjectBundle.read(from: bundle).runtimeState(bundleURL: bundle).tracks
        let back = try #require(reopened.first?.instrument?.sampler?.zones)
        #expect(back.map(\.drumRole) == zones.map(\.drumRole))
        #expect(back.map(\.chokeGroup) == [nil, nil, 0, 0, nil])
        #expect(back.map(\.rootPitch) == [36, 38, 42, 46, 84])
    }
}
