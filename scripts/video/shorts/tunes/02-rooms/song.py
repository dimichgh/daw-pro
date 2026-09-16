#!/usr/bin/env python3
"""FOUR CHORDS, FIVE ROOMS — Am F C G, five times, five different worlds.

100 BPM, 20 bars, four bars per room: bossa, house, metal, string quartet,
lo-fi. The harmony never changes and the arrangement changes completely, which
is the whole argument; the legend groups the twenty parts into the five rooms so
a viewer sees the ROOM change rather than fifteen names scrolling.

⚠ ONE TEMPO FOR ALL FIVE, deliberately. Real bossa is not 100 and real metal is
not 100 either, but a tempo map here would make the four-chord loop a different
length in every room and the "same harmony" claim would stop being visible in
the grid. The rooms are made by instrumentation, register and rhythm instead.
"""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
from theory import N, write

BPM, BARS = 100, 20
LEN = BARS * 4
CH = [[57, 60, 64], [53, 57, 60], [52, 55, 60], [55, 59, 62]]      # Am F C G
RT = [45, 41, 40, 43]
TOP = [64, 60, 64, 62]                                             # a singable top line
B = lambda bar, beat=0.0: bar * 4.0 + beat


def room(first, fn):
    out = []
    for i in range(4):
        out += fn(first + i, i)
    return out


T = []


def track(name, group, prog, msb, col, vol, pan, snd, notes, alpha=1.0):
    T.append({"name": name, "group": group, "program": prog, "bankMSB": msb, "bankLSB": 0,
              "color": col, "volume": vol, "pan": pan, "vizAlpha": alpha,
              "send": {"bus": "Air", "level": snd}, "notes": notes})


# ---------------------------------------------------------------- 1. BOSSA
G1 = "#FFC97A"
track("Nylon guitar", "Bossa nova", 24, 121, G1, 0.86, -0.28, 0.16,
      room(0, lambda b, i: [N(B(b, t), p, 0.55, v) for t, v in
                            ((0.0, 92), (0.75, 70), (1.5, 84), (2.25, 68), (3.0, 86))
                            for p in CH[i]]))
track("Upright bass", "Bossa nova", 32, 121, "#E8A54F", 0.92, 0.0, 0.06,
      room(0, lambda b, i: [N(B(b, 0.0), RT[i], 1.4, 104), N(B(b, 1.5), RT[i] + 7, 0.5, 78),
                            N(B(b, 2.0), RT[i], 1.4, 96), N(B(b, 3.5), RT[i] + 12, 0.4, 74)]))
# ⚠ 1.00 AND VELOCITY 118, NOT 0.44 AND 74. MEASURED: at the original setting
# the brush kit's own four-bar window read -49.6 dB RMS against the nylon
# guitar's -25.6 -- twenty-four dB down, i.e. not in the record at all. GM brush
# programs are intrinsically quiet and no amount of taste tells you that; a
# per-room windowed stem measurement does.
track("Brushes", "Bossa nova", 40, 120, "#C9A87A", 1.00, 0.16, 0.10,
      room(0, lambda b, i: [N(B(b, k * 0.5), 42 if k % 2 else 44, 0.2, 118 if k % 2 else 92)
                            for k in range(8)] +
                           [N(B(b, 1.0), 38, 0.3, 112), N(B(b, 3.0), 38, 0.3, 104)]))
track("Flute", "Bossa nova", 73, 121, "#FFE7B0", 0.85, 0.22, 0.30,
      room(0, lambda b, i: [N(B(b, 0.5), TOP[i], 1.4, 84), N(B(b, 2.5), TOP[i] + 3, 1.2, 76)]))

# ---------------------------------------------------------------- 2. HOUSE
G2 = "#5AD1FF"
track("Kit", "House", 0, 120, G2, 0.78, 0.0, 0.06,
      room(4, lambda b, i: [N(B(b, k), 36, 0.3, 118) for k in range(4)] +
                           [N(B(b, k + 0.5), 42, 0.2, 84) for k in range(4)] +
                           [N(B(b, 1.0), 38, 0.3, 96), N(B(b, 3.0), 38, 0.3, 96)]))
# ⚠ UP AN OCTAVE, not just up in level: at RT-12 (A1) the GM synth bass read
# -39.8 dB against the room's electric piano at -25.3, and a phone speaker
# reproduces almost none of that octave anyway.
track("Synth bass", "House", 38, 121, "#3FA9E0", 1.00, 0.0, 0.04,
      room(4, lambda b, i: [N(B(b, k * 0.5 + 0.25), RT[i], 0.3, 118) for k in range(8)]))
track("Electric piano stabs", "House", 4, 121, "#9BE4FF", 0.70, -0.26, 0.22,
      room(4, lambda b, i: [N(B(b, t), p, 0.35, 92) for t in (0.75, 1.75, 2.5, 3.75)
                            for p in CH[i]]))
track("String section", "House", 48, 121, "#BFF0FF", 0.56, 0.26, 0.34,
      room(4, lambda b, i: [N(B(b, 0.0), p + 12, 3.8, 74) for p in CH[i]], ))

# ---------------------------------------------------------------- 3. METAL
G3 = "#FF6B6B"
track("Distortion guitar", "Metal", 30, 121, G3, 0.74, -0.30, 0.10,
      room(8, lambda b, i: [N(B(b, k * 0.5), p, 0.42, 108) for k in range(8)
                            for p in (RT[i], RT[i] + 7)]))
track("Picked bass", "Metal", 34, 121, "#E05555", 0.86, 0.0, 0.04,
      room(8, lambda b, i: [N(B(b, k * 0.5), RT[i] - 12, 0.42, 110) for k in range(8)]))
track("Power kit", "Metal", 16, 120, "#FFA0A0", 0.82, 0.10, 0.08,
      room(8, lambda b, i: [N(B(b, 0.0), 36, 0.3, 122), N(B(b, 1.0), 38, 0.3, 116),
                            N(B(b, 2.0), 36, 0.3, 118), N(B(b, 2.5), 36, 0.3, 100),
                            N(B(b, 3.0), 38, 0.3, 116)] +
                           [N(B(b, k * 0.5), 49 if k == 0 and i == 0 else 42, 0.25,
                              104 if k % 2 == 0 else 70) for k in range(8)]))
track("Church organ", "Metal", 19, 121, "#FFCACA", 0.46, 0.30, 0.36,
      room(8, lambda b, i: [N(B(b, 0.0), p + 12, 3.9, 80) for p in CH[i]], ))

# ---------------------------------------------------------------- 4. QUARTET
G4 = "#B39BFF"
track("Violin I", "String quartet", 40, 121, G4, 0.74, -0.34, 0.34,
      room(12, lambda b, i: [N(B(b, 0.0), TOP[i] + 12, 2.0, 88),
                             N(B(b, 2.0), CH[i][2] + 12, 1.9, 80)]))
track("Violin II", "String quartet", 40, 121, "#9C86E8", 0.80, -0.12, 0.34,
      room(12, lambda b, i: [N(B(b, k * 0.5), CH[i][1], 0.45, 88) for k in range(8)]))
track("Viola", "String quartet", 41, 121, "#8A76CC", 0.66, 0.16, 0.32,
      room(12, lambda b, i: [N(B(b, 0.0), CH[i][0], 1.9, 78), N(B(b, 2.0), CH[i][1], 1.9, 72)]))
track("Cello", "String quartet", 42, 121, "#7364AF", 0.86, 0.30, 0.28,
      room(12, lambda b, i: [N(B(b, 0.0), RT[i] - 5, 1.4, 96), N(B(b, 1.5), RT[i] + 2, 0.5, 72),
                             N(B(b, 2.0), RT[i] - 5, 1.9, 90)]))

# ---------------------------------------------------------------- 5. LO-FI
G5 = "#7DF9D6"
track("Rhodes", "Lo-fi", 4, 121, G5, 0.80, -0.20, 0.26,
      room(16, lambda b, i: [N(B(b, t), p, 1.6, v) for t, v in ((0.25, 82), (2.25, 66))
                             for p in CH[i] + [CH[i][1] + 12]]))
track("Soft bass", "Lo-fi", 32, 121, "#5CD9B8", 0.90, 0.0, 0.06,
      room(16, lambda b, i: [N(B(b, 0.0), RT[i] - 12, 1.8, 100),
                             N(B(b, 2.5), RT[i] - 5, 1.2, 78)]))
track("Brush kit", "Lo-fi", 40, 120, "#9BE8D4", 1.00, 0.14, 0.14,
      room(16, lambda b, i: [N(B(b, 0.0), 36, 0.3, 120), N(B(b, 2.0), 38, 0.3, 116)] +
                            [N(B(b, k * 0.5 + 0.25), 42, 0.2, 92) for k in range(8)]))
track("Vibraphone", "Lo-fi", 11, 121, "#C6FFF0", 0.95, 0.28, 0.38,
      room(16, lambda b, i: [N(B(b, 1.0), TOP[i] + 12, 1.2, 104),
                             N(B(b, 3.25), CH[i][0] + 12, 0.8, 88)]))

# The landing: the lo-fi room holds the last Am for two bars.
E = 19 * 4.0
for t in T:
    if t["group"] == "Lo-fi":
        if "Rhodes" in t["name"]:
            t["notes"] += [N(E, p, 6.0, 74) for p in (57, 60, 64, 72)]
        if "bass" in t["name"]:
            t["notes"] += [N(E, 33, 6.0, 96)]
        if "Vibraphone" in t["name"]:
            t["notes"] += [N(E, 76, 6.0, 70)]

song = {
    "id": "rooms", "title": "FOUR CHORDS", "subtitle": "five rooms · A minor · F · C · G · 100",
    "legendMode": "groups",
    "tempoSegments": [{"startBeat": 0, "bpm": BPM}],
    "beatsPerBar": 4, "lengthBeats": LEN, "renderSeconds": round(LEN * 60 / BPM + 3.0, 2),
    "buses": [{"name": "Air", "volume": 0.9,
               "fx": [{"kind": "reverb", "params": {"roomSize": 0.66, "damping": 0.40,
                                                    "mix": 1.0, "preDelayMs": 20, "width": 1.0}}]}],
    "master": {"volume": 1.0, "fx": [
        {"kind": "gain", "index": 0, "params": {"gainLinear": 2.0}},
        {"kind": "limiter", "params": {"ceilingDb": -1.2, "releaseMs": 80, "truePeak": 1}}]},
    "tracks": T,
}
write(song, os.path.join(os.path.dirname(os.path.abspath(__file__)), "song.json"))
