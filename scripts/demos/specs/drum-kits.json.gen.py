#!/usr/bin/env python3
"""Generates scripts/demos/specs/drum-kits.json (m39-dm listening fixture).

WHY A GENERATOR. The set's ONE axis is the KIT: every variant must play the
BYTE-IDENTICAL pattern so that any difference a listener hears is the preset
and nothing else. Hand-copying ~60 notes into four variants is the exact
transcription-error farm this repo keeps paying for — one mistyped startBeat
and the "one axis" claim is quietly false, with no test able to see it. Here
the pattern is written ONCE and emitted four times by construction.

Re-generate with:  python3 scripts/demos/specs/drum-kits.json.gen.py
"""

import json
import pathlib

# ── The kit's note map, VERIFIED against DrumVoice.note (36 + slot) in
#    Sources/DAWCore/DrumKit.swift, not assumed from the usual GM layout.
KICK, SNARE, CHAT, OHAT, CLAP, TOM, RIM, CYM = 36, 37, 38, 39, 40, 41, 42, 43

BARS = 4          # 4 bars of 4/4 at the project default 120 BPM = 8.0 s
BEATS_PER_BAR = 4


def pattern():
    """One 4-bar groove. Returns a list of note dicts.

    Written so EVERY voice a preset touches gets struck: all four presets move
    kick/snare/closedHat/openHat, `acoustic` and `lofi` also move
    clap/rim/cymbal, `trap` also moves clap. A groove that left a voice out
    would silently shrink the axis.
    """
    notes = []

    def hit(pitch, bar, beat, velocity=100):
        notes.append({
            "pitch": pitch,
            "startBeat": round(bar * BEATS_PER_BAR + beat, 4),
            "lengthBeats": 0.25,
            "velocity": velocity,
        })

    for bar in range(BARS):
        last = bar == BARS - 1

        # Kick: the 1 and the "and of 3" — the spine of the groove.
        hit(KICK, bar, 0.0, 118)
        hit(KICK, bar, 2.5, 104)
        if bar % 2 == 1:
            hit(KICK, bar, 1.75, 88)      # a pickup every other bar

        # Backbeat: snare on 2 and 4, with a clap LAYERED on 4 only. The clap
        # is what `lofi` and `trap` move, and layering it on the bar's loudest
        # moment is where a non-musician will notice it.
        hit(SNARE, bar, 1.0, 112)
        if not last:
            hit(SNARE, bar, 3.0, 112)
            hit(CLAP, bar, 3.0, 96)

        # Closed hats on 8ths, accented on the beat. This is the voice with the
        # widest preset spread (decay + tune + tone all move).
        for eighth in range(8):
            beat = eighth * 0.5
            if last and beat >= 3.0:
                continue                   # the fill takes the last beat
            if abs(beat - 3.5) < 1e-9:
                continue                   # the open hat owns the "and of 4"
            hit(CHAT, bar, beat, 104 if eighth % 2 == 0 else 74)

        # ⭐ THE CHOKE, deliberately audible and CONSTANT across every variant:
        # an open hat on the "and of 4" that the next bar's downbeat closed hat
        # cuts off. Not the set's axis — it is the same in all four renders —
        # but it means every variant also exercises the choke-group path, and
        # "the ringing hat gets cut off" is the one physics claim a
        # non-musician can hear without being told what to listen for.
        if not last:
            hit(OHAT, bar, 3.5, 108)

        # Rim ghost notes: quiet, off-grid-feeling, `acoustic` lengthens them.
        hit(RIM, bar, 1.75, 52)
        hit(RIM, bar, 2.75, 48)

        # Cymbal on the very first downbeat only — a crash, not a ride.
        if bar == 0:
            hit(CYM, bar, 0.0, 100)

        # Tom fill across the final beat of the last bar.
        if last:
            for i, beat in enumerate((3.0, 3.25, 3.5, 3.75)):
                hit(TOM, bar, beat, 92 + i * 8)
            hit(SNARE, bar, 3.875, 120)

    notes.sort(key=lambda n: (n["startBeat"], n["pitch"]))
    return notes


VARIANTS = [
    ("808", "control",
     "preset = 808 — THE CONTROL, and also the instrument's DEFAULTS "
     "(DrumKitParams.presets[0].params == DrumKitParams(), verified in source): "
     "long sub kick with a slow fall, loose hats, a snare that sits back. "
     "This is what a track sounds like the moment you pick Drum Machine."),
    ("909", None,
     "preset = 909 — the OTHER lineage. Same topology, different numbers: a "
     "faster and deeper pitch sweep on the kick, a much shorter kick body, a "
     "brighter snappier snare, tighter hats."),
    ("acoustic", None,
     "preset = acoustic — drive removed everywhere, inharmonic snare modes, "
     "longer tails and a wider stereo image (hats, cymbal and tom panned "
     "apart). The least synthetic of the five."),
    ("lofi", None,
     "preset = lofi — dull and driven. Every voice darker (tone pulled down), "
     "the kick and snare saturated, the hats short and closed down."),
    ("trap", None,
     "preset = trap — a very long sub kick, a clap-forward snare and fast "
     "bright hats built for rolls. MEASURED SEPARATELY: most of its distance "
     "from the control lives below 200 Hz, which a laptop speaker cannot "
     "reproduce — see the report's per-band numbers."),
]


def build():
    notes = pattern()
    variants = []
    for name, role, axis in VARIANTS:
        commands = [
            {"command": "track.add",
             "params": {"name": "Drums", "kind": "instrument"}, "as": "drums"},
            {"command": "track.setInstrument",
             "params": {"trackId": "$drums", "kind": "drumSynth"}},
            {"command": "instrument.loadDrumPreset",
             "params": {"trackId": "$drums", "name": name}},
            # ⚠️ HEADROOM, and deliberately OUTSIDE the instrument. The first
            # render peaked at +1.5 dBTP on `acoustic` and +0.8 on `trap` —
            # over full scale, which would clip in MP3 encoding and hand the
            # user distortion to blame on the drum machine. The harness's
            # `audible=true` passed all five; loudness gates do not look up.
            #
            # ⛔ The fix is TRACK VOLUME, not the kit's `gain`, because `gain`
            # IS part of the axis: `lofi` deliberately ships `gain = 0.9`, and
            # overriding it would have quietly deleted one of the 75 values
            # the preset comparison is supposed to be demonstrating. Track
            # volume is identical in every variant, so it cannot bias the
            # comparison — it only moves the whole set down 3.5 dB.
            {"command": "track.setVolume",
             "params": {"trackId": "$drums", "volume": 0.67}},
            {"command": "clip.addMIDI",
             "params": {"trackId": "$drums", "atBeat": 0,
                        "lengthBeats": BARS * BEATS_PER_BAR + 1,
                        "notes": notes}},
        ]
        variant = {"name": name, "axis": axis, "commands": commands}
        if role:
            variant["role"] = role
        variants.append(variant)

    return {
        "set": "drum-kits",
        "description":
            "DAW Pro's own drum machine (m39-dm), eight synthesised voices, "
            "playing ONE 4-bar groove at 120 BPM. The single axis is the KIT: "
            "every variant plays a byte-identical pattern and differs only in "
            "which factory preset is loaded. 808 is the control AND the "
            "instrument's defaults. The open hat on the 'and of 4' is choked "
            "by the next downbeat's closed hat in EVERY variant — that is "
            "constant, not the axis, but it is audible and worth pointing at.",
        "variants": variants,
    }


if __name__ == "__main__":
    # ⚠️ `.with_suffix("")` drops only ONE suffix (`.py`), leaving
    # `drum-kits.json.gen` — which wrote a file nothing reads. Name the target
    # explicitly instead of deriving it cleverly.
    out = pathlib.Path(__file__).parent / "drum-kits.json"
    spec = build()
    out.write_text(json.dumps(spec, indent=2) + "\n")
    # ⚠️ Find the MIDI command by name, never by index. This block indexed
    # `commands[3]` until `track.setVolume` was inserted above it, at which
    # point the self-check below would have compared `track.setVolume` blocks
    # to each other and passed while the patterns diverged unchecked.
    def notes_of(variant):
        for c in variant["commands"]:
            if c["command"] == "clip.addMIDI":
                return c["params"]["notes"]
        raise AssertionError(f"{variant['name']} has no clip.addMIDI")

    ref = notes_of(spec["variants"][0])
    print(f"wrote {out} — {len(spec['variants'])} variants, {len(ref)} notes each")
    # Self-check: every variant must carry the SAME pattern, or the axis is
    # not the only thing that differs. Cheap, and it fails loudly.
    for v in spec["variants"][1:]:
        assert notes_of(v) == ref, \
            f"{v['name']} pattern differs from the control — the axis is not alone"
    # And the ONLY thing that may differ between variants is the preset name.
    def fingerprint(variant):
        return [
            (c["command"], {k: val for k, val in c["params"].items()
                            if not (c["command"] == "instrument.loadDrumPreset"
                                    and k == "name")})
            for c in variant["commands"]
        ]
    for v in spec["variants"][1:]:
        assert fingerprint(v) == fingerprint(spec["variants"][0]), \
            f"{v['name']} differs from the control somewhere OTHER than the preset name"
    print("self-check: identical pattern, and the preset name is the ONLY difference")
