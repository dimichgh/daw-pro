#!/usr/bin/env swift
// E2E: MIDI hardware input — live thru + MIDI-clip recording (M3 vii).
//
// Run `swift scripts/e2e-midi-record.swift` (CLT-only, no Xcode needed)
// against a RUNNING app (`swift run DAWApp`) with its control server on
// ws://127.0.0.1:17600. Creates a virtual CoreMIDI source named
// DAWPro-E2E-<pid> and drives the whole path over the control protocol:
//
//   1. midi.listInputs sees the virtual source within 2 s (hot-plug).
//   2. Live thru while STOPPED: note-on 60 → armed instrument track meter
//      rms > 0.001 with transport.isPlaying == false; note-off → decay
//      below 0.001 within 2 s (no stuck note).
//   3. transport.record + arpeggio 60/64/67/72 at 0/0.5/1.0/1.5 s
//      (120 BPM ⇒ beats 0/1/2/3) → exactly one new MIDI clip at
//      startBeat 0 with 4 notes (pitches exact, velocities 100, onsets
//      within ±0.1 beat) and snapshot.midiEventCount ≥ 8.
//   4. edit.undo removes the whole take under "Record Take 1".
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

// MARK: - Control client (synchronous JSON request/response over WebSocket)

final class ControlClient {
    private let task: URLSessionWebSocketTask
    private var nextID = 0

    init(url: URL) {
        task = URLSession(configuration: .ephemeral).webSocketTask(with: url)
        task.resume()
    }

    /// Sends one command and blocks until the response with a matching id
    /// arrives (transport broadcasts and other unsolicited pushes are
    /// skipped). Fails the run on transport errors, timeouts, or ok:false.
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

/// Polls `body` every 50 ms until it returns true or `seconds` elapse.
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
check(MIDIClientCreateWithBlock("DAWPro-E2E" as CFString, &midiClient, nil) == noErr,
      "MIDIClientCreate failed — CoreMIDI unavailable")
let sourceName = "DAWPro-E2E-\(getpid())"
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

// MARK: - (2) Live thru while stopped

func trackRMS(_ snapshot: [String: Any]) -> Double {
    let meters = snapshot["meters"] as? [String: Any]
    let tracks = meters?["tracks"] as? [String: Any]
    let frame = tracks?[trackID] as? [String: Any]
    return frame?["rms"] as? Double ?? 0
}

sendNote(on: true, pitch: 60)
var sawThruWhileStopped = false
let thruRose = poll(seconds: 1) {
    let snapshot = client.snapshot()
    let playing = (snapshot["transport"] as? [String: Any])?["isPlaying"] as? Bool ?? true
    if trackRMS(snapshot) > 0.001 {
        sawThruWhileStopped = !playing
        return true
    }
    return false
}
check(thruRose, "no thru energy: track rms never rose above 0.001 within 1 s of note-on")
check(sawThruWhileStopped, "thru energy appeared but transport.isPlaying was true (expected stopped)")
sendNote(on: false, pitch: 60)
let decayed = poll(seconds: 2) { trackRMS(client.snapshot()) < 0.001 }
check(decayed, "stuck note: track rms did not decay below 0.001 within 2 s of note-off")
pass("(2) live thru while stopped: meter rose on note-on and decayed on note-off")

// MARK: - (3) Record an arpeggio

client.request("transport.record")
// The record anchor sits ~60 ms (startLeadSeconds) after the command is
// processed; wait 80 ms so nominal t=0 lands just AFTER the anchor (a
// pre-anchor note-on would be dropped by design). Expected onset error
// ≈ +0.04 beat at 120 BPM — inside the ±0.1 assertion below.
Thread.sleep(forTimeInterval: 0.08)
let pitches: [UInt32] = [60, 64, 67, 72]
for pitch in pitches {
    sendNote(on: true, pitch: pitch)          // at t = 0, 0.5, 1.0, 1.5 s
    Thread.sleep(forTimeInterval: 0.3)
    sendNote(on: false, pitch: pitch)
    Thread.sleep(forTimeInterval: 0.2)
}
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
check(clip["startBeat"] as? Double == 0, "clip startBeat \(clip["startBeat"] ?? "nil") != 0 (record position)")
guard let notes = clip["notes"] as? [[String: Any]], notes.count == 4 else {
    fail("expected 4 recorded notes, got \(String(describing: clip["notes"]))")
}
for (index, note) in notes.enumerated() {
    let pitch = note["pitch"] as? Int ?? -1
    let velocity = note["velocity"] as? Int ?? -1
    let startBeat = note["startBeat"] as? Double ?? -999
    check(pitch == Int(pitches[index]), "note[\(index)] pitch \(pitch) != \(pitches[index])")
    check(velocity == 100, "note[\(index)] velocity \(velocity) != 100")
    check(abs(startBeat - Double(index)) <= 0.1,
          "note[\(index)] startBeat \(startBeat) not within ±0.1 of \(index)")
}
let finalSnapshot = client.snapshot()
let eventCount = finalSnapshot["midiEventCount"] as? Int ?? 0
check(eventCount >= 8, "snapshot.midiEventCount \(eventCount) < 8")
pass("(3) recorded arpeggio: 1 clip @0, 4 notes on beats ±0.1, midiEventCount=\(eventCount)")

// MARK: - (4) Undo removes the take

check(finalSnapshot["undoLabel"] as? String == "Record Take 1",
      "undoLabel '\(finalSnapshot["undoLabel"] ?? "nil")' != 'Record Take 1'")
let undo = client.request("edit.undo")
guard let undoResult = undo["result"] as? [String: Any] else { fail("edit.undo returned no result") }
check(undoResult["undone"] as? String == "Record Take 1",
      "edit.undo undid '\(undoResult["undone"] ?? "nil")', expected 'Record Take 1'")
guard let postUndo = undoResult["snapshot"] as? [String: Any],
      let postTracks = postUndo["tracks"] as? [[String: Any]],
      let postTrack = postTracks.first(where: { $0["id"] as? String == trackID }) else {
    fail("edit.undo snapshot missing the instrument track")
}
check((postTrack["clips"] as? [[String: Any]])?.isEmpty == true,
      "clip still present after edit.undo")
pass("(4) edit.undo removed the take under 'Record Take 1'")

print("E2E MIDI record: ALL PASS")
exit(0)
