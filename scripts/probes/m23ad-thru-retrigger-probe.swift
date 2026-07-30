// m23ad-thru-retrigger-probe — a VIRTUAL CoreMIDI source that sends a
// same-pitch retrigger, then one matching note-off.
//
// WHY THIS EXISTS. The m23-ad fix lives in `InstrumentRenderer`'s live-THRU
// drain, and `thruRing` has exactly one producer in the whole tree: the
// CoreMIDI receive thread (`MIDIInputManager.swift:24`). No control command
// reaches it. So a unit test can drive `renderQuantum` directly — and the
// m23-ad suite does — but nothing short of real MIDI proves the fix on the
// path a user actually plays through.
//
// `MIDIInputManager.setupChanged()` connects EVERY online source it enumerates,
// so a virtual source needs no selection step: create it and the app is
// listening.
//
// The sequence is the bug, verbatim:
//     noteOn 60 → noteOn 60 (retrigger, no off between) → noteOff 60
// Before m23-ad the first voice was ORPHANED — no off could ever pair with it,
// so it sounded until flush and the single off closed the SECOND voice instead.
// With the fix the retrigger closes the first voice itself, and the off pairs
// with the second: the track must fall silent.
//
// ⚠️ THIS PROBE'S STDOUT IS BUFFERED, AND THAT IS ONLY SAFE BECAUSE OF HOW ITS
// GATE READS IT. Swift's `print` is BLOCK-buffered when stdout is a pipe, so
// nothing below is guaranteed to arrive until this process exits.
// `m23ad-thru-retrigger.mjs` accumulates into `probeLog` and awaits exit
// (`:147`, `:158`) before reading a byte, so the buffering is invisible there.
//
// IF ANYONE EVER MAKES THAT GATE READ THIS INCREMENTALLY — an `awaitProbeLine`
// to anchor a sampling window on a probe line, the way m23-ae's gate does —
// ADD `setvbuf(stdout, nil, _IONBF, 0)` HERE FIRST. Skipping it does not fail
// loudly: the gate blocks until the probe exits, then samples a window in
// which the virtual source is already GONE, and every reading comes back
// null. That signature reads exactly like a real product failure, and at
// m23-ae it cost two runs and a confident, plausible, WRONG diagnosis
// (a CoreMIDI main-actor-hop race) before being measured.
//
// Usage: swiftc -O -o /tmp/m23ad-probe scripts/probes/m23ad-thru-retrigger-probe.swift
//        /tmp/m23ad-probe [pitch] [gap-ms]
import CoreMIDI
import Foundation

let pitch = UInt8(CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 60 : 60)
// Gaps are generous on purpose: `mixer.liveLoudness`'s momentary window is
// 400 ms and reads nil until it has filled, so a gap short enough to sample
// inside that warm-up makes a SOUNDING note read as silence. Measured
// m23-ad: at a 700 ms gap the first sample came back null while the note was
// audibly playing, and the gate's own precondition caught it.
let gapMs = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 1500 : 1500

var client = MIDIClientRef()
guard MIDIClientCreate("m23ad-probe-client" as CFString, nil, nil, &client) == noErr else {
    print("FAIL: MIDIClientCreate"); exit(2)
}
var source = MIDIEndpointRef()
guard MIDISourceCreate(client, "m23ad-probe" as CFString, &source) == noErr else {
    print("FAIL: MIDISourceCreate"); exit(2)
}
print("# virtual source 'm23ad-probe' created — the app connects online sources automatically")

func send(_ status: UInt8, _ d1: UInt8, _ d2: UInt8, _ label: String) {
    var packetList = MIDIPacketList()
    let packet = MIDIPacketListInit(&packetList)
    var bytes: [UInt8] = [status, d1, d2]
    _ = MIDIPacketListAdd(&packetList, 1024, packet, 0, 3, &bytes)
    let rc = MIDIReceived(source, &packetList)
    print("\(label): status=0x\(String(status, radix: 16)) pitch=\(d1) vel=\(d2) rc=\(rc)")
}

// Give the app's setupChanged() a moment to enumerate and connect the source.
// Without this the first note-on races the connect and is simply never received —
// which would look exactly like the fix failing.
Thread.sleep(forTimeInterval: 2.0)

send(0x90, pitch, 100, "ON  #1 (opens the voice)")
Thread.sleep(forTimeInterval: Double(gapMs) / 1000.0)
send(0x90, pitch, 100, "ON  #2 (RETRIGGER — pre-m23-ad this orphaned voice #1)")
Thread.sleep(forTimeInterval: Double(gapMs) / 1000.0)
send(0x80, pitch, 0, "OFF    (one off for two ons — must leave NOTHING sounding)")

// Hold the source alive so the app is not disconnected mid-measurement. A
// vanishing source triggers `requestFlush()` on every armed renderer
// (MIDIInputManager.swift:256-260) — which would silence a stuck voice and
// hand the gate a FALSE PASS on exactly the leg it exists to test.
Thread.sleep(forTimeInterval: 6.0)
print("# done")
