// m23af-stuck-note-probe — a VIRTUAL CoreMIDI source that plays a note and then
// NEVER SENDS THE NOTE-OFF.
//
// That omission is not a shortcut, it IS the bug. m23-af exists because a lost
// note-off — cable unplugged mid-note, device removed, sending app crashes with a
// key down — legitimately leaves `openLiveCount > 0`, which since m23-u keeps the
// renderer awake indefinitely rather than cutting the voice at 8 s. That is the
// CORRECT engine behaviour (the voice really is open) and it is exactly why the
// user needs a way out. This probe manufactures that state honestly: it opens a
// voice through real CoreMIDI and then simply stops talking, like a device that
// went away.
//
// WHY A PROBE AND NOT THE WIRE. `note.audition` is reachable from the control
// port, so a gate could hold a note without any of this — but it would prove the
// wrong thing. An auditioned note has an entry in the engine's `auditionVoices`
// ledger, and `stopAllAudition()` alone would silence it. A note stuck via MIDI
// INPUT has no audition entry anywhere, so only the graph-wide flush reaches it.
// Testing the audition path would pass against a panic that never touches the
// renderers holding the actual bug.
//
//     virtual MIDI source -> CoreMIDI -> MIDIInputManager -> thruRing
//       -> InstrumentRenderer (voice open, no off will ever arrive)
//       -> polySynth -> master bus -> mixer.liveLoudness
//
// ⚠️ UNBUFFERED STDOUT, AND IT IS LOAD-BEARING — DO NOT REMOVE. Swift's `print`
// is BLOCK-buffered when stdout is a pipe, so a gate that anchors its sampling
// windows on a line from this probe would see NOTHING until the process exited,
// then sample windows in which the source is already gone. Measured m23-ae: 0
// lines in 12 s with buffering on, presenting as a clean product failure.
setvbuf(stdout, nil, _IONBF, 0)

// Usage: swiftc -O -o /tmp/m23af-probe scripts/probes/m23af-stuck-note-probe.swift
//        /tmp/m23af-probe [pitch] [hold-seconds]
import CoreMIDI
import Foundation

let pitch = UInt8(CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 60 : 60)
// How long to hold the source open AFTER the note-on. The gate must finish
// measuring well inside this: if the process exits, the virtual source is
// destroyed, and a source disappearing is itself a state change the engine may
// answer with a flush — which would hand a PASS to a build with no panic at all.
let holdSeconds = Double(CommandLine.arguments.count > 2
                         ? Int(CommandLine.arguments[2]) ?? 120 : 120)

var client = MIDIClientRef()
guard MIDIClientCreate("m23af-probe-client" as CFString, nil, nil, &client) == noErr else {
    print("FAIL: MIDIClientCreate"); exit(2)
}
var source = MIDIEndpointRef()
guard MIDISourceCreate(client, "m23af-probe" as CFString, &source) == noErr else {
    print("FAIL: MIDISourceCreate"); exit(2)
}
print("# virtual source 'm23af-probe' created")

// HANDSHAKE, NOT A SLEEP (the m23-ae law). The app connects new sources from a
// CoreMIDI notify block that hops to the MAIN ACTOR
// (`MIDIInputManager.swift:191-196`), so the connect lands at a time no fixed
// sleep can predict. The gate polls `midi.listInputs` until this endpoint is
// visible and only then writes the go-ahead, so "no audio" cannot mean "the app
// never heard the note".
print("# waiting for the gate's go-ahead on stdin")
if readLine() == nil {
    print("FAIL: stdin closed before the go-ahead — no gate to measure for")
    exit(2)
}
print("# go-ahead received")

let start = Date()
func send(_ status: UInt8, _ d1: UInt8, _ d2: UInt8, _ label: String) {
    var packetList = MIDIPacketList()
    let packet = MIDIPacketListInit(&packetList)
    var bytes: [UInt8] = [status, d1, d2]
    _ = MIDIPacketListAdd(&packetList, 1024, packet, 0, 3, &bytes)
    let rc = MIDIReceived(source, &packetList)
    let t = String(format: "%.1f", Date().timeIntervalSince(start))
    print("t=\(t) \(label): status=0x\(String(status, radix: 16)) d1=\(d1) d2=\(d2) rc=\(rc)")
}

// Slack for the port connect to be in effect on the receive side.
Thread.sleep(forTimeInterval: 0.5)

send(0x90, pitch, 100, "NOTEON  (voice opens — no note-off will ever follow)")

// From here the probe deliberately does NOTHING. No note-off, no controller, no
// exit. The voice stays open, the renderer stays awake, and the only thing that
// can silence it is the panic the gate is about to send.
print("# holding the source open, sending nothing — this IS the stuck-note state")
Thread.sleep(forTimeInterval: holdSeconds)
print("# hold elapsed — exiting (the gate should have killed this long ago)")
