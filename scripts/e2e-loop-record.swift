#!/usr/bin/env swift
// E2E: loop-cycle take recording (m15-b, design-m15b-loop-record) — the G10
// live gate. Run `swift scripts/e2e-loop-record.swift` against a RUNNING app
// (`swift run DAWApp`) with its control server on ws://127.0.0.1:17600.
// Creates a virtual CoreMIDI source and drives the whole path over the wire:
//
//   1. Loop [2, 6) @ 120 (2.0 s cycle), playhead parked at 5 →
//      transport.record RESPONSE shows the seek (positionBeats == 2) with
//      isLoopEnabled true + isRecording true (the audit-m15 B2 probe shape,
//      now honest).
//   2. While rolling: the playhead wraps MODULARLY (every polled position
//      stays inside [2, 6]) — no silent linear roll.
//   3. transport.setLoop mid-record refuses with the exact teaching error.
//   4. One note per cycle (60 in cycle 1, 64 in cycle 2), stop mid-cycle 3 →
//      the snapshot shows ONE take group with 3 lanes ("<track> Take 1.1/2/3"),
//      notes landed in their own cycles, lane 3 the honest EMPTY partial,
//      comp = the newest lane.
//   5. edit.undo removes the WHOLE loop take as one entry.
//
// Exits non-zero on any failure.

import CoreMIDI
import Foundation

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
            fail("send timed out for \(command) — is the app running with the control server on 17600?")
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
check(MIDIClientCreateWithBlock("DAWPro-E2E-Loop" as CFString, &midiClient, nil) == noErr,
      "MIDIClientCreate failed — CoreMIDI unavailable")
let sourceName = "DAWPro-E2E-Loop-\(getpid())"
var source = MIDIEndpointRef()
check(MIDISourceCreateWithProtocol(midiClient, sourceName as CFString, ._1_0, &source) == noErr,
      "MIDISourceCreateWithProtocol failed")
defer {
    MIDIEndpointDispose(source)
    MIDIClientDispose(midiClient)
}

func sendNote(on: Bool, pitch: UInt32, velocity: UInt32 = 100) {
    var list = MIDIEventList()
    let packet = MIDIEventListInit(&list, ._1_0)
    let word: UInt32 = (0x2 << 28) | ((on ? 0x90 : 0x80) << 16) | (pitch << 8) | (on ? velocity : 0)
    let words = [word]
    _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet,
                         mach_absolute_time(), words.count, words)
    MIDIReceivedEventList(source, &list)
}

// MARK: - Session setup

let client = ControlClient(url: URL(string: "ws://127.0.0.1:17600")!)
client.request("project.new", params: ["discardChanges": true])
let trackResult = client.request("track.add", params: ["kind": "instrument"])
guard let track = trackResult["result"] as? [String: Any],
      let trackID = track["id"] as? String,
      let trackName = track["name"] as? String else {
    fail("track.add returned no track id/name")
}
client.request("track.setArm", params: ["trackId": trackID, "armed": true])
let enumerated = poll(seconds: 2) {
    let response = client.request("midi.listInputs")
    guard let result = response["result"] as? [String: Any],
          let inputs = result["inputs"] as? [[String: Any]] else { return false }
    return inputs.contains { $0["name"] as? String == sourceName }
}
check(enumerated, "midi.listInputs did not list '\(sourceName)' within 2 s")

// MARK: - (1) Record seeks to the loop start (the honest B2 shape)

client.request("transport.setLoop",
               params: ["enabled": true, "startBeat": 2, "endBeat": 6])  // 2.0 s cycle @120
client.request("transport.seek", params: ["beats": 5])
let record = client.request("transport.record")
guard let recordState = record["result"] as? [String: Any] else { fail("record returned no transport") }
check(recordState["positionBeats"] as? Double == 2,
      "record response positionBeats \(recordState["positionBeats"] ?? "nil") != 2 (the loop-start seek)")
check(recordState["isRecording"] as? Bool == true, "record response isRecording != true")
check(recordState["isLoopEnabled"] as? Bool == true, "record response isLoopEnabled != true")
pass("(1) transport.record with loop [2,6) seeked to the loop start; loop claim honest while recording")

// MARK: - (2)+(3)+(4) roll ≥ 2 full cycles, wrap modularly, refuse setLoop, land lanes

// Anchor ≈ 60 ms after the response. One note per cycle, well inside it:
// pitch 60 at ~0.4 s (cycle 1), pitch 64 at ~2.4 s (cycle 2); stop ~4.7 s
// (mid-cycle 3 → 2 full cycles + an honest empty partial lane).
var maxPosition = 0.0
var minPosition = 999.0
func observePosition() {
    if let position = (client.snapshot()["transport"] as? [String: Any])?["positionBeats"] as? Double {
        maxPosition = max(maxPosition, position)
        minPosition = min(minPosition, position)
    }
}

Thread.sleep(forTimeInterval: 0.4)
sendNote(on: true, pitch: 60)
Thread.sleep(forTimeInterval: 0.3)
sendNote(on: false, pitch: 60)
observePosition()

// Mid-record loop edits are refused with the m13-c-family teaching error.
let refused = client.request("transport.setLoop",
                             params: ["enabled": true, "startBeat": 0, "endBeat": 8],
                             allowError: true)
check(refused["ok"] as? Bool == false, "transport.setLoop mid-record unexpectedly succeeded")
check(refused["error"] as? String == "cannot change the loop while recording — stop first",
      "setLoop mid-record error was '\(refused["error"] ?? "nil")'")
pass("(3) transport.setLoop mid-record refused verbatim")

// Poll into cycle 2 (wrap happened ≈ anchor + 2.0 s), then note 64.
Thread.sleep(forTimeInterval: 1.5)
observePosition()
sendNote(on: true, pitch: 64)
Thread.sleep(forTimeInterval: 0.3)
sendNote(on: false, pitch: 64)
observePosition()
Thread.sleep(forTimeInterval: 1.6)   // into cycle 3
observePosition()
client.request("transport.stop")

check(maxPosition <= 6.0, "playhead escaped the loop while recording: max \(maxPosition) > 6")
check(minPosition >= 2.0, "playhead read before the loop start while recording: min \(minPosition) < 2")
check(maxPosition > 2.0, "playhead never moved (max \(maxPosition))")
pass("(2) playhead wrapped modularly while recording (observed [\(minPosition), \(maxPosition)] ⊂ [2, 6])")

// MARK: - (4) the landed take group

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
check(landed, "expected exactly ONE take group on the instrument track after stop")
guard let group,
      let lanes = group["lanes"] as? [[String: Any]] else { fail("group has no lanes array") }
check(lanes.count == 3, "expected 3 lanes (2 full cycles + honest partial), got \(lanes.count)")
let laneNames = lanes.compactMap { $0["name"] as? String }
check(laneNames == ["\(trackName) Take 1.1", "\(trackName) Take 1.2", "\(trackName) Take 1.3"],
      "lane names \(laneNames) != Take 1.1/1.2/1.3")

func laneNotes(_ lane: [String: Any]) -> [[String: Any]] {
    (lane["clip"] as? [String: Any])?["notes"] as? [[String: Any]] ?? []
}
for (index, lane) in lanes.enumerated() {
    guard let clip = lane["clip"] as? [String: Any] else { fail("lane \(index) has no clip") }
    check(clip["startBeat"] as? Double == 2, "lane \(index) startBeat != 2 (the loop start)")
}
check(laneNotes(lanes[0]).count == 1 && laneNotes(lanes[0])[0]["pitch"] as? Int == 60,
      "lane 1 should hold exactly the cycle-1 note 60, got \(laneNotes(lanes[0]))")
check(laneNotes(lanes[1]).count == 1 && laneNotes(lanes[1])[0]["pitch"] as? Int == 64,
      "lane 2 should hold exactly the cycle-2 note 64, got \(laneNotes(lanes[1]))")
check(laneNotes(lanes[2]).isEmpty, "lane 3 (partial) should be the honest EMPTY lane")
let lane3Length = (lanes[2]["clip"] as? [String: Any])?["lengthBeats"] as? Double ?? -1
check(lane3Length > 0 && lane3Length < 4, "partial lane length \(lane3Length) not in (0, 4)")
guard let comp = group["comp"] as? [[String: Any]], comp.count == 1,
      let newestLaneID = lanes[2]["id"] as? String else { fail("group has no 1-segment comp") }
check(comp[0]["laneId"] as? String == newestLaneID, "comp does not play the newest lane")
pass("(4) ONE group, 3 lanes (\(laneNames)), notes in their own cycles, empty honest partial, comp = newest")

// MARK: - (5) one undo removes the whole loop take

let finalSnapshot = client.snapshot()
check(finalSnapshot["undoLabel"] as? String == "Record Take 1",
      "undoLabel '\(finalSnapshot["undoLabel"] ?? "nil")' != 'Record Take 1'")
let undo = client.request("edit.undo")
guard let undoResult = undo["result"] as? [String: Any],
      let postUndo = undoResult["snapshot"] as? [String: Any],
      let postTracks = postUndo["tracks"] as? [[String: Any]],
      let postTrack = postTracks.first(where: { $0["id"] as? String == trackID }) else {
    fail("edit.undo returned no snapshot")
}
check(undoResult["undone"] as? String == "Record Take 1",
      "edit.undo undid '\(undoResult["undone"] ?? "nil")'")
check((postTrack["takeGroups"] as? [[String: Any]] ?? []).isEmpty, "take group survived undo")
check((postTrack["clips"] as? [[String: Any]])?.isEmpty == true, "clips survived undo")
pass("(5) edit.undo removed the whole loop take as ONE entry")

print("E2E loop record: ALL PASS")
exit(0)
