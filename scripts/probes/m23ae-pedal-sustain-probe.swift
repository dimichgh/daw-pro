// m23ae-pedal-sustain-probe — a VIRTUAL CoreMIDI source that holds the sustain
// pedal, plays one note, and RELEASES THE KEY while the pedal stays down.
//
// WHY A SECOND PROBE AND NOT A MODE ON THE m23-ad ONE. That probe is rebuilt
// from source by its own gate on every run, deliberately, so a stale binary can
// never measure a sequence that no longer exists. Adding a mode to it would
// change what the m23-ad gate compiles and therefore what m23-ad measures — a
// silent edit to a passing gate's meaning. Probes are cheap; shared mutable
// fixtures are not.
//
// THE SEQUENCE IS THE BUG (m23-ae):
//     CC64 = 127 (pedal down) → noteOn 60 → noteOff 60 → …hold… → CC64 = 0
//
// Both built-in instruments DEFER the release while the pedal is down
// (`PolySynthInstrument.swift:377`), so after the note-off the KEY is up —
// `pitchToLiveID` clear, `openLiveCount` back to 0 — while the VOICE sounds on.
// Before m23-ae the renderer's 6d re-arm had a term for keys and none for the
// pedal, so `liveTailRemaining` aged out and the sustaining voice was cut at
// `liveTailSeconds` (8 s). Every pedalled phrase longer than 8 s died mid-note.
//
// TIMING IS THE WHOLE MEASUREMENT. The discriminating window opens 8 s after
// the NOTE-OFF, because that is the quantum from which the pre-fix tail starts
// aging with nothing left to re-arm it. Sampling any earlier sits inside the
// region where the old code was still correct and proves nothing.
//
// EVERY LINE BELOW IS A SYNCHRONISATION POINT, AND THAT IS DELIBERATE. The gate
// anchors its sampling windows to these stdout lines rather than to its own
// `sleep` arithmetic, because the two clocks are NOT the same: `start` is taken
// after `MIDIClientCreate`/`MIDISourceCreate`, and process launch plus that
// CoreMIDI handshake put roughly a second between the gate's spawn and this
// file's t=0. Measured m23-ae — the meter fell a full second "late" against the
// gate's absolute sleeps, which is what a silent, machine-speed-dependent flake
// looks like before it is diagnosed. Do not reorder or reword these prints
// without updating the gate's matchers.
//
// Usage: swiftc -O -o /tmp/m23ae-probe scripts/probes/m23ae-pedal-sustain-probe.swift
//        /tmp/m23ae-probe [pitch]
import CoreMIDI
import Foundation

// ⚠️ UNBUFFERED STDOUT, AND IT IS LOAD-BEARING — DO NOT REMOVE.
// `print` goes through stdio, which is BLOCK-buffered whenever stdout is not a
// TTY. Under a gate stdout is a pipe, so without this every line below sits in
// the buffer until the process exits and the gate's log-watcher sees NOTHING
// until it is too late to matter.
//
// MEASURED m23-ae, because this was diagnosed the expensive way: with buffering
// on, a harness that waited for the "go-ahead" line observed ZERO lines in 12 s
// even though two are printed before the blocking read. The gate's sampling
// windows all opened after the probe had already exited, every window read
// null, and it presented as "the app received no MIDI at all". I first wrote
// that up as a CoreMIDI main-actor-hop race — plausible, and wrong. The buffer
// was the whole story.
setvbuf(stdout, nil, _IONBF, 0)

let pitch = UInt8(CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 60 : 60)

var client = MIDIClientRef()
guard MIDIClientCreate("m23ae-probe-client" as CFString, nil, nil, &client) == noErr else {
    print("FAIL: MIDIClientCreate"); exit(2)
}
var source = MIDIEndpointRef()
guard MIDISourceCreate(client, "m23ae-probe" as CFString, &source) == noErr else {
    print("FAIL: MIDISourceCreate"); exit(2)
}
print("# virtual source 'm23ae-probe' created")

// HANDSHAKE, NOT A SLEEP. The app connects new sources from a CoreMIDI notify
// block that hops to the MAIN ACTOR (`MIDIInputManager.swift:191-196`), so the
// connection lands at a time no fixed sleep can predict — it is scheduled work
// on an actor the gate has just been issuing commands to.
//
// So: block until the gate says the app can actually SEE this source (it polls
// `midi.listInputs`, whose cached list is refreshed by `setupChanged()`, until
// this endpoint shows up). Then the note is played into a connection that is
// known to exist, and "no audio" can only mean the thing the gate is testing.
//
// HONEST PROVENANCE: this handshake was added while chasing two all-null runs
// that turned out to be the stdout buffering above, NOT a connect race. It is
// kept because it is right on its own merits — the connect genuinely is
// asynchronous and previously unobserved — but it is not the fix for that bug,
// and nobody should read it as evidence such a race was ever measured here.
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

// Small settle after the go-ahead. NOT the connect wait — that was the
// handshake above; this is only slack for the port connect to be in effect on
// the receive side.
Thread.sleep(forTimeInterval: 0.5)

send(0xB0, 64, 127, "CC64 DOWN (sustain pedal held)")
Thread.sleep(forTimeInterval: 0.2)
send(0x90, pitch, 100, "ON      (voice opens under the pedal)")
Thread.sleep(forTimeInterval: 1.8)
send(0x80, pitch, 0, "OFF     (KEY UP — the synth DEFERS this; the voice must sound on)")

// Past `liveTailSeconds` (8 s) measured from the note-off above, plus room for
// the gate's discriminating window to open at OFF+9.0 and close at ≈OFF+10.6
// before this fires. Pre-m23-ae the voice is already silent by OFF+8.
Thread.sleep(forTimeInterval: 12.0)

send(0xB0, 64, 0, "CC64 UP   (the deferred release finally lands)")

// Hold the source alive through the LAST sample the gate takes. A vanishing
// source triggers `requestFlush()` on every armed renderer
// (MIDIInputManager.swift:256-260); here that would silence the voice, which is
// the direction that turns the final silence leg into a FALSE PASS — the gate
// would "prove" the pedal releases by having the release done for it.
//
// 9 s covers the gate's final window (CC64UP+2.5 → +4.5) with margin. Measured
// m23-ae: after the pedal lifts, momentary runs -17.84 → -19.20 → -21.02 →
// -39.46 → nil across ~430 ms, so +2.5 s is deep in the nil region and not a
// threshold guess.
Thread.sleep(forTimeInterval: 9.0)
print("# done")
