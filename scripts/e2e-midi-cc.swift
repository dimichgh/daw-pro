#!/usr/bin/env swift
// E2E: MIDI CC / pitch-bend live thru + capture (m16-b3, design-m16b §8/C14).
//
// Run `swift scripts/e2e-midi-cc.swift` against a RUNNING app with its
// control server on ws://127.0.0.1:$DAW_CONTROL_PORT (default 17600 — the
// staging laws want a fresh 176xx instance). Creates a virtual CoreMIDI
// source and drives the whole path over the control protocol:
//
//   1. midi.listInputs sees the virtual source within 2 s (hot-plug).
//   2. Thru sounds AND live CC reaches the instrument: while STOPPED a
//      note-on makes the meter rise (the M3-vii event-gated thru law — a
//      held voice only renders continuously under a published schedule);
//      then under transport.play, SUSTAIN PEDAL down (CC64=127) + note-off
//      → the meter KEEPS ringing (the pedal held the released voice — live
//      CC64 audibly honored); pedal up → decay below 0.001.
//   3. transport.record + a note, a SENTINEL CC 87 value ramp
//      11/33/55/77/99 (virtual sources are system-global — the sentinel
//      controller keeps the assertion honest, the CC cousin of pitch 113),
//      and one pitch bend → the landed clip's snapshot shows the cc87 lane
//      (values exact, beats ascending ~0.5 beat apart) and the pitchBend
//      lane with the reassembled 14-bit value. edit.undo removes the take.
//   4. Loop [0,4) @120 (2.0 s cycle), record ≥ 2 full cycles with CC 87 = 25
//      in cycle 1 and CC 87 = 75 in cycle 2, stop mid-cycle 3 → THREE lanes:
//      lane 1 [(~1, 25)], lane 2 [(0, 25) INJECTED, (~1, 75)], lane 3
//      [(0, 75) INJECTED] — the per-cycle slicing law with cycle-boundary
//      state injection, live. One undo removes the whole take.
//
// Exits non-zero on any failure.

import CoreMIDI
import Foundation

// MARK: - Helpers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
}

func check(_ condition: Bool, _ message: String) {
    if !condition { fail(message) }
}

func pass(_ message: String) {
    print("PASS: \(message)")
}

// MARK: - Control client (the e2e-midi-record.swift client, verbatim shape)

final class ControlClient {
    private let task: URLSessionWebSocketTask
    private var nextID = 0

    init(url: URL) {
        task = URLSession(configuration: .ephemeral).webSocketTask(with: url)
        task.resume()
    }

    @discardableResult
    func request(_ command: String, params: [String: Any] = [:],
                 allowError: Bool = false, timeout: TimeInterval = 5) -> [String: Any] {
        nextID += 1
        let id = "e2e-\(nextID)"
        var body: [String: Any] = ["id": id, "command": command]
        if !params.isEmpty { body["params"] = params }
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let text = String(data: data, encoding: .utf8) else {
            fail("could not encode request for \(command)")
        }

        let sendDone = DispatchSemaphore(value: 0)
        var sendError: Error?
        task.send(.string(text)) { error in
            sendError = error
            sendDone.signal()
        }
        if sendDone.wait(timeout: .now() + timeout) == .timedOut {
            fail("send timed out for \(command) — is the app running with the control server up?")
        }
        if let sendError {
            fail("send failed for \(command): \(sendError) — is the app running?")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let receiveDone = DispatchSemaphore(value: 0)
            var received: String?
            var receiveError: Error?
            task.receive { result in
                switch result {
                case .success(.string(let string)): received = string
                case .success(.data(let data)): received = String(data: data, encoding: .utf8)
                case .success: break
                case .failure(let error): receiveError = error
                }
                receiveDone.signal()
            }
            if receiveDone.wait(timeout: .now() + timeout) == .timedOut {
                fail("receive timed out for \(command)")
            }
            if let receiveError {
                fail("receive failed for \(command): \(receiveError)")
            }
            guard let received,
                  let object = try? JSONSerialization.jsonObject(with: Data(received.utf8)),
                  let dict = object as? [String: Any] else { continue }
            guard dict["id"] as? String == id else { continue }  // broadcast — skip
            if !allowError, dict["ok"] as? Bool != true {
                fail("\(command) errored: \(dict["error"] as? String ?? "\(dict)")")
            }
            return dict
        }
        fail("no response for \(command) within \(timeout)s")
    }

    func snapshot() -> [String: Any] {
        request("project.snapshot")["result"] as? [String: Any] ?? [:]
    }
}

@discardableResult
func poll(seconds: TimeInterval, _ body: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if body() { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return body()
}

// MARK: - Virtual MIDI source

var midiClient = MIDIClientRef()
check(MIDIClientCreateWithBlock("DAWPro-E2E-CC" as CFString, &midiClient, nil) == noErr,
      "MIDIClientCreate failed — CoreMIDI unavailable")
let sourceName = "DAWPro-E2E-CC-\(getpid())"
var source = MIDIEndpointRef()
check(MIDISourceCreateWithProtocol(midiClient, sourceName as CFString, ._1_0, &source) == noErr,
      "MIDISourceCreateWithProtocol failed")
defer {
    MIDIEndpointDispose(source)
    MIDIClientDispose(midiClient)
}

func sendWord(_ word: UInt32) {
    var list = MIDIEventList()
    let packet = MIDIEventListInit(&list, ._1_0)
    let words = [word]
    _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet,
                         mach_absolute_time(), words.count, words)
    MIDIReceivedEventList(source, &list)
}

func sendNote(on: Bool, pitch: UInt32, velocity: UInt32 = 100) {
    sendWord((0x2 << 28) | ((on ? 0x90 : 0x80) << 16) | (pitch << 8) | (on ? velocity : 0))
}

/// SENTINEL controller 87 by default — virtual sources are system-global.
func sendCC(_ controller: UInt32, _ value: UInt32) {
    sendWord((0x2 << 28) | (0xB0 << 16) | (controller << 8) | value)
}

func sendBend(_ value14: UInt32) {
    let lsb = value14 & 0x7F
    let msb = (value14 >> 7) & 0x7F
    sendWord((0x2 << 28) | (0xE0 << 16) | (lsb << 8) | msb)
}

// MARK: - Lane JSON helpers (the Codable shape: {type: {type, controller?}, points})

func controllerLanes(of clip: [String: Any]) -> [[String: Any]] {
    clip["controllerLanes"] as? [[String: Any]] ?? []
}

func lane(_ clip: [String: Any], cc controller: Int) -> [String: Any]? {
    controllerLanes(of: clip).first {
        let type = $0["type"] as? [String: Any]
        return type?["type"] as? String == "cc" && type?["controller"] as? Int == controller
    }
}

func lane(_ clip: [String: Any], type name: String) -> [String: Any]? {
    controllerLanes(of: clip).first {
        ($0["type"] as? [String: Any])?["type"] as? String == name
    }
}

func points(_ lane: [String: Any]?) -> [(beat: Double, value: Int)] {
    ((lane?["points"] as? [[String: Any]]) ?? []).compactMap {
        guard let beat = $0["beat"] as? Double, let value = $0["value"] as? Int else { return nil }
        return (beat, value)
    }
}

// MARK: - Session setup

let port = ProcessInfo.processInfo.environment["DAW_CONTROL_PORT"] ?? "17600"
print("e2e-midi-cc: control port \(port), virtual source \(sourceName)")
let client = ControlClient(url: URL(string: "ws://127.0.0.1:\(port)")!)
client.request("project.new", params: ["discardChanges": true])
let trackResult = client.request("track.add", params: ["kind": "instrument"])
guard let track = trackResult["result"] as? [String: Any],
      let trackID = track["id"] as? String else {
    fail("track.add returned no track id")
}
client.request("track.setArm", params: ["trackId": trackID, "armed": true])

// MARK: - (1) Hot-plug enumeration

let enumerated = poll(seconds: 2) {
    let response = client.request("midi.listInputs")
    guard let result = response["result"] as? [String: Any],
          let inputs = result["inputs"] as? [[String: Any]] else { return false }
    return inputs.contains { $0["name"] as? String == sourceName }
}
check(enumerated, "midi.listInputs did not list '\(sourceName)' within 2 s")
pass("(1) midi.listInputs sees \(sourceName)")

// MARK: - (2) Thru sounds; live CC64 audibly holds a released note

func trackRMS(_ snapshot: [String: Any]) -> Double {
    let meters = snapshot["meters"] as? [String: Any]
    let tracks = meters?["tracks"] as? [String: Any]
    let frame = tracks?[trackID] as? [String: Any]
    return frame?["rms"] as? Double ?? 0
}

// (2a) Stopped: the event-gated thru law — a note-on makes energy appear
// within one poll (a stopped node renders only quanta in which events
// drain, so a HELD voice reads silent between events; the continuous-hold
// proof below runs under a published schedule).
sendNote(on: true, pitch: 60)
let thruRose = poll(seconds: 1) { trackRMS(client.snapshot()) > 0.001 }
check(thruRose, "no thru energy: track rms never rose above 0.001 within 1 s of note-on")
sendNote(on: false, pitch: 60)
_ = poll(seconds: 2) { trackRMS(client.snapshot()) < 0.001 }

// (2b) Rolling (empty session plays silence, schedules published — the
// instrument renders every quantum): pedal down + note-off must KEEP
// ringing, pedal up must release. This is live CC64 audibly honored.
client.request("transport.play")
Thread.sleep(forTimeInterval: 0.2)
sendCC(64, 127)                       // sustain pedal DOWN, live
sendNote(on: true, pitch: 60)
Thread.sleep(forTimeInterval: 0.2)
sendNote(on: false, pitch: 60)        // released — but the pedal must hold it
Thread.sleep(forTimeInterval: 0.8)
let heldRMS = trackRMS(client.snapshot())
check(heldRMS > 0.001,
      "live CC64 not honored: rms \(heldRMS) decayed although the pedal is down")
sendCC(64, 0)                         // pedal UP → deferred release runs
let decayed = poll(seconds: 2) { trackRMS(client.snapshot()) < 0.001 }
check(decayed, "stuck voice: rms did not decay below 0.001 within 2 s of pedal-up")
client.request("transport.stop")
pass("(2) thru sounds; live sustain pedal held the released note (rms \(heldRMS)) and released on pedal-up")

// MARK: - (3) Recorded take lands controller lanes

client.request("transport.record")
// The record anchor sits ~60 ms (startLeadSeconds) after the response; wait
// 120 ms so every event lands safely post-anchor.
Thread.sleep(forTimeInterval: 0.12)
sendNote(on: true, pitch: 60)
let rampValues: [UInt32] = [11, 33, 55, 77, 99]   // distinctive sentinel ramp
for value in rampValues {
    sendCC(87, value)                              // sentinel CC 87
    Thread.sleep(forTimeInterval: 0.25)            // 0.5 beat @120 between points
}
sendBend(12_288)                                   // +1 st: MSB 0x60, LSB 0x00
Thread.sleep(forTimeInterval: 0.2)
sendNote(on: false, pitch: 60)
Thread.sleep(forTimeInterval: 0.3)
client.request("transport.stop")

var recordedClip: [String: Any]?
let clipLanded = poll(seconds: 2) {
    let snapshot = client.snapshot()
    guard let tracks = snapshot["tracks"] as? [[String: Any]],
          let instrumentTrack = tracks.first(where: { $0["id"] as? String == trackID }),
          let clips = instrumentTrack["clips"] as? [[String: Any]],
          clips.count == 1 else { return false }
    recordedClip = clips[0]
    return true
}
check(clipLanded, "expected exactly one new clip on the instrument track after transport.stop")
guard let clip = recordedClip else { fail("clip vanished") }
check((clip["notes"] as? [[String: Any]])?.count == 1, "expected the 1 recorded note")

let cc87 = points(lane(clip, cc: 87))
check(cc87.count == rampValues.count,
      "cc87 lane has \(cc87.count) points, expected \(rampValues.count): \(cc87)")
check(cc87.map(\.value) == rampValues.map(Int.init),
      "cc87 values \(cc87.map(\.value)) != \(rampValues) (the sentinel ramp, exact)")
for (index, point) in cc87.enumerated() {
    check(point.beat >= 0, "cc87 point \(index) beat \(point.beat) < 0")
    if index > 0 {
        let gap = point.beat - cc87[index - 1].beat
        check(gap > 0.2 && gap < 0.8,
              "cc87 spacing \(gap) beats not within (0.2, 0.8) of the nominal 0.5")
    }
}
check(cc87[0].beat < 0.5, "cc87 first point beat \(cc87[0].beat) not near the record start")
let bendPoints = points(lane(clip, type: "pitchBend"))
check(bendPoints.count == 1 && bendPoints[0].value == 12_288,
      "pitchBend lane \(bendPoints) != one point of the reassembled 12288")
pass("(3) recorded take landed the cc87 sentinel ramp \(cc87.map(\.value)) + pitchBend 12288")

let preUndo = client.snapshot()
check(preUndo["undoLabel"] as? String == "Record Take 1",
      "undoLabel '\(preUndo["undoLabel"] ?? "nil")' != 'Record Take 1'")
let undo1 = client.request("edit.undo")
guard let undo1Result = undo1["result"] as? [String: Any],
      let postUndo1 = undo1Result["snapshot"] as? [String: Any],
      let postTracks1 = postUndo1["tracks"] as? [[String: Any]],
      let postTrack1 = postTracks1.first(where: { $0["id"] as? String == trackID }) else {
    fail("edit.undo returned no snapshot")
}
check((postTrack1["clips"] as? [[String: Any]])?.isEmpty == true,
      "clip still present after edit.undo")
pass("(3b) edit.undo removed the recorded take")

// MARK: - (4) Loop take: per-cycle lanes with cycle-boundary injection

client.request("transport.setLoop",
               params: ["enabled": true, "startBeat": 0, "endBeat": 4])  // 2.0 s cycle @120
let record = client.request("transport.record")
guard let recordState = record["result"] as? [String: Any] else { fail("record returned no transport") }
check(recordState["positionBeats"] as? Double == 0,
      "record response positionBeats \(recordState["positionBeats"] ?? "nil") != 0 (loop-start seek)")
let rollStart = Date()

// Anchor ≈ 60 ms post-response. Cycle 1: a note (so the take lands) + the
// cycle-1 sentinel value; cycle 2: only the changed sentinel value — lane 3
// (the partial cycle) must get its state purely by INJECTION.
Thread.sleep(forTimeInterval: 0.3)
sendNote(on: true, pitch: 60)
Thread.sleep(forTimeInterval: 0.2)                 // ~0.5 s ≈ beat 1, cycle 1
sendCC(87, 25)
Thread.sleep(forTimeInterval: 0.1)
sendNote(on: false, pitch: 60)
// Into cycle 2 (wrap at anchor + 2.0 s) — send at ~2.5 s ≈ beat 1 of cycle 2.
Thread.sleep(forTimeInterval: rollStart.addingTimeInterval(2.56).timeIntervalSinceNow)
sendCC(87, 75)
// Stop mid-cycle 3 (~4.6 s ⇒ 2 full cycles + honest partial).
Thread.sleep(forTimeInterval: rollStart.addingTimeInterval(4.66).timeIntervalSinceNow)
client.request("transport.stop")

var group: [String: Any]?
let landed = poll(seconds: 3) {
    let snapshot = client.snapshot()
    guard let tracks = snapshot["tracks"] as? [[String: Any]],
          let instrumentTrack = tracks.first(where: { $0["id"] as? String == trackID }),
          let groups = instrumentTrack["takeGroups"] as? [[String: Any]],
          groups.count == 1 else { return false }
    group = groups[0]
    return true
}
check(landed, "expected exactly ONE take group after the loop take")
guard let group, let lanes = group["lanes"] as? [[String: Any]] else { fail("group has no lanes") }
check(lanes.count == 3, "expected 3 cycle lanes (2 full + honest partial), got \(lanes.count)")

func laneClip(_ index: Int) -> [String: Any] {
    (lanes[index]["clip"] as? [String: Any]) ?? [:]
}
let cycle1 = points(lane(laneClip(0), cc: 87))
let cycle2 = points(lane(laneClip(1), cc: 87))
let cycle3 = points(lane(laneClip(2), cc: 87))

// Cycle 1: the literal point only (no injection at k = 0).
check(cycle1.count == 1 && cycle1[0].value == 25,
      "cycle-1 cc87 \(cycle1) != one literal point of 25")
check(cycle1[0].beat > 0.2 && cycle1[0].beat < 1.8,
      "cycle-1 cc87 beat \(cycle1[0].beat) not mid-cycle (sent ~beat 1)")
// Cycle 2: OPENS with the injected boundary state (beat 0 EXACT, value 25),
// then the literal 75.
check(cycle2.count == 2, "cycle-2 cc87 \(cycle2) != [injected, literal]")
check(cycle2[0].beat == 0 && cycle2[0].value == 25,
      "cycle-2 cc87 must OPEN with the injected (0, 25) boundary state, got \(cycle2)")
check(cycle2[1].value == 75 && cycle2[1].beat > 0.2 && cycle2[1].beat < 1.8,
      "cycle-2 cc87 literal \(cycle2[1]) != (~1, 75)")
// Cycle 3 (the partial): NO literal events — state exists PURELY by injection.
check(cycle3.count == 1 && cycle3[0].beat == 0 && cycle3[0].value == 75,
      "cycle-3 cc87 must be exactly the injected (0, 75), got \(cycle3)")
// Notes landed in cycle 1 only (the loop e2e's shape — lanes ride alongside).
check((laneClip(0)["notes"] as? [[String: Any]])?.count == 1, "cycle-1 note missing")
check((laneClip(1)["notes"] as? [[String: Any]] ?? []).isEmpty, "cycle 2 should have no notes")
pass("(4) loop take: cycle1 \(cycle1), cycle2 \(cycle2) (injected boundary), cycle3 \(cycle3) (injection only)")

// MARK: - (5) one undo removes the whole loop take

let finalSnapshot = client.snapshot()
let label = finalSnapshot["undoLabel"] as? String ?? ""
check(label.hasPrefix("Record Take"), "undoLabel '\(label)' is not the take entry")
let undo2 = client.request("edit.undo")
guard let undo2Result = undo2["result"] as? [String: Any],
      let postUndo2 = undo2Result["snapshot"] as? [String: Any],
      let postTracks2 = postUndo2["tracks"] as? [[String: Any]],
      let postTrack2 = postTracks2.first(where: { $0["id"] as? String == trackID }) else {
    fail("edit.undo (loop take) returned no snapshot")
}
check((postTrack2["takeGroups"] as? [[String: Any]] ?? []).isEmpty, "take group survived undo")
check((postTrack2["clips"] as? [[String: Any]])?.isEmpty == true, "clips survived undo")
pass("(5) one edit.undo removed the whole loop take")

print("E2E MIDI CC: ALL PASS")
exit(0)
