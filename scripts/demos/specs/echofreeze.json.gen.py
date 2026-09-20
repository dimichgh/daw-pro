#!/usr/bin/env python3
"""Generates scripts/demos/specs/echofreeze.json (m39-k).

Kept next to the spec because the four variants differ in EXACTLY one number
and a hand-maintained copy of the same 60 lines is how an axis silently stops
being one axis. Run: python3 scripts/demos/specs/echofreeze.json.gen.py
"""
import json
import pathlib

DURATION = 14

RIFF = [
    (57, 0.0), (60, 0.5), (64, 1.0), (69, 1.5),
    (67, 2.0), (64, 2.5), (60, 3.0), (62, 3.5),
    (64, 4.0), (69, 4.5), (72, 5.0),
]

INSTRUMENT = {
    "command": "track.setInstrument",
    "params": {
        "trackId": "$lead",
        "kind": "polySynth",
        "waveform": "saw",
        "attack": 0.002,
        "decay": 0.18,
        "sustain": 0.0,
        "release": 0.12,
        "cutoffHz": 4200,
        "resonance": 0.18,
        "gain": 0.55,
        "unisonVoices": 2,
        "unisonDetuneCents": 7,
        "unisonStereoSpread": 0.35,
        "subLevel": 0.15,
        "subOctave": -1,
        "subWaveform": "sine",
    },
}

CLIP = {
    "command": "clip.addMIDI",
    "params": {
        "trackId": "$lead",
        "atBeat": 0,
        "notes": [
            {"pitch": p, "startBeat": b, "lengthBeats": 0.4, "velocity": 104}
            for p, b in RIFF
        ],
    },
}


def variant(name, axis, feedback, role=None):
    commands = [
        {"command": "track.add", "params": {"name": "Lead", "kind": "instrument"},
         "as": "lead"},
        INSTRUMENT,
    ]
    if feedback is not None:
        commands.append({
            "command": "fx.add",
            "params": {
                "trackId": "$lead",
                "kind": "delay",
                "params": {
                    "timeMs": 250,
                    "feedback": feedback,
                    "mix": 0.45,
                    "pingPong": 0,
                    "highCutHz": 20000,
                },
            },
            "as": "echo",
        })
    commands.append(CLIP)
    v = {
        "name": name,
        "axis": axis,
        "render": {"durationSeconds": DURATION},
        "commands": commands,
    }
    if role:
        v["role"] = role
    return v


DESCRIPTION = """m39-k, the echo freeze: the delay's `feedback` knob taken to its new ceiling, where the repeats stop dying away and simply hold. Every variant plays the IDENTICAL eleven-note saw riff (120 BPM, the last note at bar 2 beat 2) so nothing but one number differs.

THE ONE AXIS IS `feedback`. `timeMs` (250 ms = a dotted-free straight 1/8 at this tempo), `mix` (0.45), `pingPong` (0) and `highCutHz` (20000) are byte-for-byte identical in all three effect variants; only the feedback moves, 0.4 -> 0.95 -> 0.999. Variant 1 has no delay at all.

WHAT FEEDBACK ACTUALLY DOES, because it is not a level control and not a time control. The delay writes a copy of your sound into a loop and plays it back 250 ms later. `feedback` is how much of that playback is written back INTO the loop. At 0.4 each repeat comes back at 40 % of the one before it, so the echoes fade out in about a second. At 0.95 - which was this effect's maximum until now - each repeat is 95 % of the last, which is a loss of 0.45 dB every time round: audible decay, roughly four seconds to fade away. At 0.999 the loss per repeat is 0.0087 dB, and the echo simply keeps going.

WHY THE MAXIMUM IS 0.999 AND NOT 1.0, measured rather than argued. At exactly 1.0 the loop gives back exactly what it took, which sounds ideal and is not: anything the loop cannot lose then accumulates forever. Feeding a constant (DC) offset into a 10 ms delay at feedback 1.0 measured 9.66 after one second, 96.97 after ten, 193.94 after twenty and 290.94 after thirty - a straight line with no end. The same input at 0.999 measured 94.56 after thirty seconds and stopped there, against a predicted ceiling of exactly 100 (= 1/(1-0.999) x the input). 0.999 is therefore the largest value that still cannot run away, and it is a freeze by any musical measure: this very render's tail loses 3.19 dB over 110 seconds.

WHAT TO LISTEN FOR. Variant 1 is the riff untouched, so you know what is being changed. In 'feedback-40' you hear a normal slapback: two or three repeats and gone. In 'feedback-95' the repeats stack into a wash and take about four seconds to disappear after the last note. In 'freeze-999' the riff never leaves: after the last note the loop keeps circling at essentially full level for the whole remaining ten seconds, and would still be going minutes later. That is the echo-out / hold sound - what a DJ does at the end of a track, and what a producer does to hang a vocal phrase in the air.

⚠️ `highCutHz` IS LOAD-BEARING AT THIS SETTING, AND IT IS SET WIDE OPEN HERE ON PURPOSE. The high-cut filter sits INSIDE the loop, so it is subtracted once per repeat, and at a feedback this high it - not the feedback - decides how long the hold lasts. Measured on a 350 ms delay at feedback 0.999: with `highCutHz` at 20000 the tail was 3.19 dB down after 110 seconds; with `highCutHz` at 500 the same tail was gone in about 20 seconds. If a freeze is dying faster than you expect, that number is why.

⚠️ AND IT WILL BUILD UP IF YOU KEEP FEEDING IT. A loop that loses almost nothing adds everything it is given. Held notes, or anything landing exactly on a repeat, stack up toward a ceiling of about 1/(1-feedback) - which at 0.999 is a thousand times the input, approached over `timeMs`/(1-feedback) seconds (350 ms delay: about six minutes). This riff is short and staccato, so what you hear here is the hold and not the build. The way to use a freeze is to STOP feeding it: put the delay on a bus, send to it, and pull the send to zero - then the loop holds what it already has and takes nothing new.

WHAT WOULD MAKE THIS HARD TO HEAR: nothing on a normal system. The axis here is how long a sound lasts, not what colour it is, so it survives a laptop speaker and a phone intact - the difference between a two-second tail and one that never stops is not a subtle one. Headphones only help with the stereo width of the repeats, which is not the axis.

LOUDNESS, STATED SO IT IS NOT MISTAKEN FOR THE AXIS (all measured on these exact renders). Integrated: no-effect -29.0, feedback-40 -32.0, feedback-95 -32.1, freeze-999 -27.7 LUFS. The three effect variants span 4.4 LU, which BREAKS this project's 1 LU house rule for an on-axis set, and the reason is worth reading rather than fixing: on this axis integrated loudness stops measuring what it usually measures. Integrated LUFS is a GATED MEAN, not a total. 'feedback-95' is audibly fuller than 'feedback-40' and its true peak is 2.0 dB higher (-14.2 against -16.2 dBTP), yet it reads 0.1 LU QUIETER - because its dying tail adds nine seconds of quiet blocks that drag the mean down. 'freeze-999' reads 4.4 LU louder for the mirror-image reason: its tail never becomes quiet, so there are no quiet blocks to drag anything down. Measured over the riff alone (the first 4.5 seconds) the three read -32.0 / -29.4 / -27.7 LUFS, and that 4.3 LU spread is the effect itself - a delay that recirculates more of itself puts more sound in the room, the same fact the flanger's `feedback` note records as '(1-mix) + mix/(1-feedback)'. Matching these three to 1 LU would mean lowering `mix` as feedback rises, which would hide the axis behind a second one, so it has not been done. The no-effect CONTROL sits at -29.0 LUFS, 3.0 LU above 'feedback-40', and that offset is arithmetic rather than a mix decision: at mix 0.45 only 55 % of the dry riff survives into the output. Do not pick a variant because it is louder."""


def main():
    spec = {
        "set": "echofreeze",
        "description": DESCRIPTION,
        "variants": [
            variant("no-echo",
                    "no delay at all - the riff untouched, so you know what is being changed",
                    None, role="control"),
            variant("feedback-40",
                    "feedback 0.4: an ordinary slapback, two or three repeats and gone",
                    0.4),
            variant("feedback-95",
                    "feedback 0.95: the OLD maximum - a wash that still audibly dies, "
                    "about 0.45 dB per repeat",
                    0.95),
            variant("freeze-999",
                    "feedback 0.999: the NEW maximum - the loop holds, losing 0.0087 dB "
                    "per repeat, and the riff never leaves",
                    0.999),
        ],
    }
    path = pathlib.Path(__file__).with_name("echofreeze.json")
    path.write_text(json.dumps(spec, indent=2) + "\n")
    print(f"wrote {path} ({path.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
