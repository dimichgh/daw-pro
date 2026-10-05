#!/usr/bin/env python3
"""THE STACK — a kick alone, and then one more instrument every two bars until
twelve are playing.

A minor, 128 BPM, 25 bars. The rows piling up the frame ARE the piece: each new
part gets its own colour and its own legend row, and the picture fills from the
bottom of the pitch range upward as the arrangement thickens.

⚠ ELEVEN ENTRIES, NOT TWELVE, and the twelfth is the landing. Twelve entries at
two bars each is 24 bars before anything happens; the concept's own arithmetic
did not fit in 55 seconds, so the last entry lands ON the final tutti instead of
two bars before it.
"""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
from theory import MIN, deg, N, shift, repeat, clip_to, write

BPM, BARS = 128, 25
LEN = BARS * 4
ROOT = 57                                     # A3
S = lambda d: deg(ROOT, MIN, d)               # A natural minor
B = lambda bar, beat=0.0: bar * 4.0 + beat    # bar index (0-based) -> beat
END = 22 * 4.0                                # the tutti landing, bar 23

# Harmony: | Am | F | C | G | two bars each, four-bar loop of one bar each.
CHORD = [[57, 60, 64], [53, 57, 60], [52, 55, 60], [55, 59, 62]]
ROOTN = [45, 41, 40, 43]


def per_bar(fn, first, last=BARS - 3):
    out = []
    for bar in range(first, last + 1):
        out += fn(bar, bar % 4)
    return out


# ⚠⚠ ENTRY 1 IS THE KIT, NOT A BARE KICK -- and that is a deliberate change to
# the concept, forced by a measurement. The first cut opened on the kick alone
# for two bars (3.75 s). Measured on the shipped file: 83.9 % of the first two
# seconds' energy sat BELOW 120 Hz and only 1.9 % above 300 Hz (positive
# controls: a 60 Hz sine reads 0.000 % above 300, a 2 kHz sine reads 100.000 %).
# A phone speaker reproduces almost none of that, so the brief's "enjoyable in
# the first two seconds" was being spent on an octave most viewers cannot hear.
# The closed hi-hat now enters WITH the kick -- one drum kit is still ONE
# instrument, so the "one more instrument every two bars" rule is intact -- and
# the old bar-4 hi-hat entry became a snare-and-shaker layer instead.
kick = per_bar(lambda b, c: [N(B(b, t), 36, 0.4, v) for t, v in
                             ((0.0, 118), (1.5, 84), (2.0, 110), (3.25, 78))]
                            + [N(B(b, i * 0.5), 42, 0.2, 104 if i % 2 == 0 else 72)
                               for i in range(8)], 0)
# ⚠ ROOTN, NOT ROOTN-12. MEASURED in the tutti window: at A1 the GM synth bass
# stem read -46.5 dB RMS against the cello's -25.9 -- twenty dB under, i.e. gone.
# A phone speaker reproduces almost none of that octave either, so moving up is
# both the audible fix and the right one for where these are watched.
sub = per_bar(lambda b, c: [N(B(b, t), ROOTN[c], l, v) for t, l, v in
                            ((0.0, 1.4, 120), (1.5, 0.4, 92), (2.0, 1.4, 112), (3.5, 0.4, 96))], 2)
hats = per_bar(lambda b, c: [N(B(b, 1.0), 38, 0.3, 104), N(B(b, 3.0), 38, 0.3, 110)]
                            + [N(B(b, 0.5 + i), 70, 0.2, 66) for i in range(4)], 4)
pizz = per_bar(lambda b, c: [N(B(b, t), CHORD[c][i % 3] - 12, 0.45, v) for i, (t, v) in
                             enumerate(((0.0, 96), (0.75, 70), (1.5, 88), (2.25, 68),
                                        (3.0, 90), (3.5, 66)))], 6)
mar = per_bar(lambda b, c: [N(B(b, t), CHORD[c][i % 3] + 12, 0.4, v) for i, (t, v) in
                            enumerate(((0.0, 92), (0.5, 62), (1.0, 84), (1.75, 70),
                                       (2.5, 90), (3.0, 64), (3.5, 78)))], 8)
ep = per_bar(lambda b, c: [N(B(b, t), p, 0.9, 74) for t in (0.0, 2.5) for p in CHORD[c]], 10)
choir = per_bar(lambda b, c: [N(B(b), p + 12, 4.0, 62) for p in CHORD[c]] if b % 2 == 0 else [], 12)
horns = per_bar(lambda b, c: [N(B(b, 2.0), CHORD[c][0], 1.8, 88),
                              N(B(b, 2.0), CHORD[c][2], 1.8, 80)], 14)
cello = per_bar(lambda b, c: [N(B(b, t), p, l, 86) for t, p, l in
                              ((0.0, ROOTN[c], 1.4), (2.0, ROOTN[c] + 7, 1.9))], 16)
glock = per_bar(lambda b, c: [N(B(b, t), CHORD[c][i % 3] + 24, 0.3, 112)
                              for i, t in enumerate((0.25, 1.25, 2.75, 3.25))], 18)
tpt = per_bar(lambda b, c: [N(B(b, t), p, l, 96) for t, p, l in
                            ((0.0, S(7 if c % 2 == 0 else 9), 1.4),
                             (2.0, S(4 if c % 2 == 0 else 5), 1.9))], 20)
taiko = per_bar(lambda b, c: [N(B(b, 0.0), 41, 0.5, 108), N(B(b, 3.0), 43, 0.5, 92)], 21)

# The landing: everything on the downbeat of bar 23, then two bars of ring.
tutti = {
    "kick": [N(END, 36, 0.5, 127), N(END, 49, 2.0, 112)], "taiko": [N(END, 41, 1.0, 120), N(END, 43, 1.0, 110)],
    "sub": [N(END, 45, 8.0, 124)], "cello": [N(END, 45, 8.0, 100)],
    "pizz": [N(END, p, 0.6, 104) for p in (57, 60, 64)],
    "mar": [N(END, p + 12, 0.6, 100) for p in (57, 60, 64)],
    "glock": [N(END, p + 24, 0.5, 96) for p in (57, 64)],
    "ep": [N(END, p, 8.0, 84) for p in (57, 60, 64)],
    "choir": [N(END, p + 12, 8.0, 78) for p in (57, 60, 64)],
    "horns": [N(END, p, 8.0, 100) for p in (52, 57, 60)],
    "tpt": [N(END, 76, 8.0, 108)], "hats": [N(END, 38, 0.5, 118), N(END, 70, 0.5, 84)],
}

P = [("Drum kit", 0, 120, "#FF6B6B", kick, 0.95, 0.0, 0.05),
     # ⚠ FINGERED BASS (33), NOT SYNTH BASS 1 (38), AND THEN TRIMMED DOWN.
     # Three measurements, in order: program 38 at A1 read -46.5 dB RMS in the
     # tutti window (twenty under the cello); an octave up plus volume and
     # velocity bought only 4.9 dB, because 38 is simply a quiet patch here;
     # program 33 with a +6.8 dB insert then read -16.4 dB, which made it the
     # LOUDEST thing in the mix by nine. The insert is gone and the fader does
     # the rest. This is what "measure, do not taste" costs and buys.
     ("Bass", 33, 121, "#FFB84D", sub, 0.62, 0.0, 0.06),
     ("Snare + shaker", 0, 120, "#8FA3BF", hats, 0.62, 0.18, 0.10),
     ("Pizzicato strings", 45, 121, "#7DF9D6", pizz, 0.82, -0.30, 0.18),
     ("Marimba", 12, 121, "#5AD1FF", mar, 0.72, 0.34, 0.20),
     ("Tine electric piano", 4, 121, "#A78BFA", ep, 0.62, -0.16, 0.24),
     ("Choir", 52, 121, "#C9B6FF", choir, 0.50, 0.10, 0.42),
     ("French horns", 60, 121, "#FFD27A", horns, 0.66, -0.22, 0.30),
     ("Cello", 42, 121, "#FF9A76", cello, 0.74, 0.24, 0.26),
     ("Glockenspiel", 9, 121, "#B8F1FF", glock, 0.88, -0.40, 0.34),
     ("Trumpet", 56, 121, "#FFE08A", tpt, 0.60, 0.40, 0.28),
     ("Taiko", 116, 121, "#FF7BAC", taiko, 0.78, 0.0, 0.16)]
KEYS = ["kick", "sub", "hats", "pizz", "mar", "ep", "choir", "horns", "cello",
        "glock", "tpt", "taiko"]

tracks = []
for (name, prog, msb, col, notes, vol, pan, snd), key in zip(P, KEYS):
    t = {"name": name, "program": prog, "bankMSB": msb, "bankLSB": 0,
         "color": col, "volume": vol, "pan": pan,
         "send": {"bus": "Air", "level": snd},
         "notes": clip_to(notes, END) + tutti[key]}
    tracks.append(t)

song = {
    "id": "stack", "title": "THE STACK",
    "subtitle": "one more instrument every two bars · A minor · 128",
    "legendMode": "list", "legendHold": 0.4,
    "tempoSegments": [{"startBeat": 0, "bpm": BPM}],
    "beatsPerBar": 4, "lengthBeats": LEN, "renderSeconds": round(LEN * 60 / BPM + 2.6, 2),
    "buses": [{"name": "Air", "volume": 0.85,
               "fx": [{"kind": "reverb", "params": {"roomSize": 0.62, "damping": 0.42,
                                                    "mix": 1.0, "preDelayMs": 18, "width": 1.0}}]}],
    "master": {"volume": 1.0, "fx": [
        {"kind": "gain", "index": 0, "params": {"gainLinear": 2.2}},
        {"kind": "limiter", "params": {"ceilingDb": -1.2, "releaseMs": 80, "truePeak": 1}}]},
    "tracks": tracks,
}
write(song, os.path.join(os.path.dirname(os.path.abspath(__file__)), "song.json"))
