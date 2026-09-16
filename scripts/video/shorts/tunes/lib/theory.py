"""Tiny shared helpers. Deliberately small: every short authors its own notes by
hand, because a generated take is not the thing being shown."""
import json, os

MAJ = [0, 2, 4, 5, 7, 9, 11]
MIN = [0, 2, 3, 5, 7, 8, 10]
DOR = [0, 2, 3, 5, 7, 9, 10]
MIXO = [0, 2, 4, 5, 7, 9, 10]
PENT = [0, 2, 4, 7, 9]           # major pentatonic
MPENT = [0, 3, 5, 7, 10]         # minor pentatonic
HARM = [0, 2, 3, 5, 7, 8, 11]


def deg(root, scale, d):
    """Scale-degree -> MIDI pitch, wrapping octaves in both directions."""
    n = len(scale)
    o, i = divmod(d, n)
    return root + 12 * o + scale[i]


def N(start, pitch, length, vel=100):
    return [round(start, 6), int(pitch), round(length, 6), int(max(1, min(127, vel)))]


def shift(notes, beats=0.0, semis=0):
    return [N(s + beats, p + semis, l, v) for s, p, l, v in notes]


def repeat(notes, period, times, start=0.0):
    out = []
    for k in range(times):
        out += shift(notes, start + k * period)
    return out


def clip_to(notes, end):
    """Drop anything starting at/after `end` and truncate what straddles it."""
    out = []
    for s, p, l, v in notes:
        if s >= end - 1e-6:
            continue
        out.append(N(s, p, min(l, end - s), v))
    return out


def write(song, path):
    tot = sum(len(t["notes"]) for t in song["tracks"])
    json.dump(song, open(path, "w"), indent=1)
    print(f"{song['id']}: {len(song['tracks'])} tracks, {tot} notes, "
          f"{song['lengthBeats']} beats, render {song['renderSeconds']}s -> {path}")
    return song
