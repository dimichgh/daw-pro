// Third-party arbiter for Standard MIDI File bytes — m23-k4a gate leg G8.
//
// Feeds a `.mid` file to Apple's `MusicSequenceFileLoad` and prints everything
// it recovers: the load status, the track count, every meta event (type byte and
// payload), every tempo change, and every note with its beat, pitch, velocity
// and duration.
//
// WHY THIS LIVES OUTSIDE THE BUILD (LAW L9): `Sources/DAWCore` never imports
// AudioToolbox or CoreMIDI — the parser and the writer are pure Foundation
// `Data`, so nothing in the shipping product can quietly start depending on
// Apple's loader. But a round trip through OUR OWN reader alone would pass a
// mirrored encoder/decoder bug with a green light, which is exactly what m23-k2's
// own doc comment says a byte pin must not rely on. So: our tests gate the bytes
// against checked-in pins, and THIS gates them against a shipping third party.
//
// WHY IT LIVES UNDER scripts/ RATHER THAN IN A SCRATCHPAD: m23-k3 paid for that
// once, when m23-k1's generator and validator both had to be rewritten from
// nothing because they had been left in a session directory.
//
// Usage:
//     xcrun swiftc -O scripts/validate-smf.swift -o /tmp/validate-smf
//     /tmp/validate-smf path/to/file.mid [more.mid ...]
//
// Requires full Xcode (not just the Command Line Tools) for the AudioToolbox
// SDK. Nothing else in m23-k4a does.

import AudioToolbox
import Foundation

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

func dump(_ path: String) {
    print("=== \(URL(fileURLWithPath: path).lastPathComponent) ===")
    var sequence: MusicSequence?
    guard NewMusicSequence(&sequence) == noErr, let sequence else {
        print("  could not create a MusicSequence")
        return
    }
    defer { DisposeMusicSequence(sequence) }

    let status = MusicSequenceFileLoad(sequence, URL(fileURLWithPath: path) as CFURL,
                                       .midiType, MusicSequenceLoadFlags())
    print("MusicSequenceFileLoad status = \(status)  "
          + (status == noErr ? "(ACCEPTED)" : "(REJECTED)"))
    guard status == noErr else { return }

    var trackCount: UInt32 = 0
    MusicSequenceGetTrackCount(sequence, &trackCount)
    // Apple EXCLUDES the tempo track from this count, while the file has one
    // more chunk than this number and our own decoder reports that larger
    // number. Both are right; they count different things.
    print("track count (excluding tempo track) = \(trackCount)")

    var tempoTrack: MusicTrack?
    MusicSequenceGetTempoTrack(sequence, &tempoTrack)
    if let tempoTrack { walk(tempoTrack, label: "tempo") }

    for index in 0 ..< trackCount {
        var track: MusicTrack?
        MusicSequenceGetIndTrack(sequence, index, &track)
        if let track { walk(track, label: "track \(index)") }
    }
}

func walk(_ track: MusicTrack, label: String) {
    var iterator: MusicEventIterator?
    guard NewMusicEventIterator(track, &iterator) == noErr, let iterator else { return }
    defer { DisposeMusicEventIterator(iterator) }

    var hasEvent: DarwinBoolean = false
    MusicEventIteratorHasCurrentEvent(iterator, &hasEvent)
    while hasEvent.boolValue {
        var timeStamp: MusicTimeStamp = 0
        var type: MusicEventType = 0
        var data: UnsafeRawPointer?
        var size: UInt32 = 0
        MusicEventIteratorGetEventInfo(iterator, &timeStamp, &type, &data, &size)

        switch type {
        case kMusicEventType_MIDINoteMessage:
            if let note = data?.assumingMemoryBound(to: MIDINoteMessage.self).pointee {
                print(String(format: "  [%@] t=%@ NOTE ch=%d pitch=%d vel=%d dur=%g",
                             label, "\(timeStamp)", Int(note.channel), Int(note.note),
                             Int(note.velocity), Double(note.duration)))
            }
        case kMusicEventType_ExtendedTempo:
            if let tempo = data?.assumingMemoryBound(to: ExtendedTempoEvent.self).pointee {
                print("  [\(label)] t=\(timeStamp) TEMPO bpm=\(tempo.bpm)")
            }
        case kMusicEventType_Meta:
            if let raw = data {
                let meta = raw.assumingMemoryBound(to: MIDIMetaEvent.self).pointee
                let length = Int(meta.dataLength)
                // `data` is a flexible array member at offset 8 in the struct.
                let payload = (0 ..< length).map {
                    raw.advanced(by: 8 + $0).assumingMemoryBound(to: UInt8.self).pointee
                }
                print(String(format: "  [%@] t=%@ META type=0x%02X len=%d payload=%@",
                             label, "\(timeStamp)", Int(meta.metaEventType),
                             length, hex(payload)))
            }
        default:
            break
        }

        MusicEventIteratorNextEvent(iterator)
        MusicEventIteratorHasCurrentEvent(iterator, &hasEvent)
    }
}

let paths = Array(CommandLine.arguments.dropFirst())
guard !paths.isEmpty else {
    print("usage: validate-smf <file.mid> [more.mid ...]")
    exit(2)
}
for path in paths { dump(path) }
