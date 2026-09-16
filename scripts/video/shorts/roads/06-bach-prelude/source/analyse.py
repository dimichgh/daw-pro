"""BWV 846 Prelude — STRUCTURE AND HARMONY, DERIVED FROM THE NOTES.

⛔ NOTHING HERE IS RECALLED. Every figure is computed from the Mutopia edition's
own LilyPond-generated MIDI (an independent instrument against the .ly text) or
from the .ly text itself. The chord names come from matching each bar's PITCH
CLASS SET against a table of triads and sevenths, not from knowing the piece.
"""
import struct, sys, itertools, collections
P = "/private/tmp/claude-501/-Users-dsemenov-Views-daw-pro/b1758ed8-13eb-4d9e-a984-4f35f1dff02d/scratchpad/r29/wtk1-prelude1.mid"
d = open(P, "rb").read()
_, fmt, ntrk, div = struct.unpack(">IHHH", d[4:14]); pos = 14; tr = []
for t in range(ntrk):
    ln = struct.unpack(">I", d[pos+4:pos+8])[0]; body = d[pos+8:pos+8+ln]; pos += 8+ln
    i, tick, run, ev = 0, 0, None, []
    while i < len(body):
        v = 0
        while True:
            b = body[i]; i += 1; v = (v << 7) | (b & 0x7F)
            if not b & 0x80: break
        tick += v; st = body[i]
        if st < 0x80: st = run
        else: i += 1; run = st
        if st == 0xFF:
            mt = body[i]; i += 1; n = 0
            while True:
                b = body[i]; i += 1; n = (n << 7) | (b & 0x7F)
                if not b & 0x80: break
            i += n
        elif st in (0xF0, 0xF7):
            n = 0
            while True:
                b = body[i]; i += 1; n = (n << 7) | (b & 0x7F)
                if not b & 0x80: break
            i += n
        else:
            hi = st & 0xF0; a = body[i]; i += 1
            b2 = body[i] if hi not in (0xC0, 0xD0) else None
            if hi not in (0xC0, 0xD0): i += 1
            if hi == 0x90 and b2: ev.append((tick, a, "on"))
            elif hi == 0x80 or (hi == 0x90 and not b2): ev.append((tick, a, "off"))
    tr.append(ev)

BAR = 4 * div
NAMES = "C C# D D# E F F# G G# A A# B".split()
nn = lambda p: f"{NAMES[p % 12]}{p // 12 - 1}"
lower = [(tk, p) for tk, p, k in tr[1] if k == "on"]
upper = [(tk, p) for tk, p, k in tr[2] if k == "on"]

# ── POSITIVE CONTROL on the whole method ────────────────────────────────────
# A chord matcher that cannot be wrong is a chord matcher that is not looking.
QUAL = {(0,4,7): "", (0,3,7): "m", (0,3,6): "dim", (0,4,8): "aug",
        (0,4,7,10): "7", (0,4,7,11): "maj7", (0,3,7,10): "m7",
        (0,3,6,10): "m7b5", (0,3,6,9): "dim7", (0,5,7): "sus4", (0,2,7): "sus2"}
def name_pcs(pcs, bass_pc):
    pcs = tuple(sorted(set(pcs)))
    best = None
    for root in range(12):
        iv = tuple(sorted((p - root) % 12 for p in pcs))
        if iv in QUAL:
            score = (root != bass_pc, len(pcs))     # prefer root == bass
            cand = (NAMES[root] + QUAL[iv], root)
            if best is None or score < best[0]: best = (score, cand)
    return best[1][0] if best else "/".join(NAMES[p] for p in pcs)
assert name_pcs([0, 4, 7], 0) == "C", name_pcs([0, 4, 7], 0)
assert name_pcs([2, 6, 9, 0], 2) == "D7", name_pcs([2, 6, 9, 0], 2)
assert name_pcs([11, 2, 5], 11) == "Bdim", name_pcs([11, 2, 5], 11)
assert name_pcs([1, 3, 6], 1) != "C", "control: a set that is NOT C major must not name C"
print("[control ok] the chord matcher names C / D7 / Bdim correctly and refuses a non-C set as C")

bars = {}
for tk, p in lower + upper: bars.setdefault(tk // BAR, []).append((tk, p))
NB = max(bars) + 1
print(f"\n{NB} bars, {len(lower)} left-hand note-ons, {len(upper)} right-hand note-ons, "
      f"{len(lower)+len(upper)} total")

rows = []
for b in range(NB):
    ev = sorted(bars[b])
    pit = [p for _, p in ev]
    pcs = sorted(set(p % 12 for p in pit))
    bass = min(pit)
    rows.append((b + 1, name_pcs(pcs, bass % 12), nn(bass), len(ev), sorted(set(pit))))
print("\nBAR  CHORD    BASS   events   distinct pitches")
for b, ch, bs, n, ps in rows:
    print(f"{b:3d}  {ch:7s}  {bs:5s}  {n:3d}   " + " ".join(nn(x) for x in ps))

print("\n" + "="*70)
print("A. IS EVERY BAR THE SAME? — the half-bar repetition test")
print("   The RH figure is written twice per bar. Compare the pitch sequence of")
print("   the first half-bar against the second, per bar.")
half = {}
for tk, p in upper: half.setdefault((tk // BAR, (tk % BAR) // (BAR // 2)), []).append((tk, p))
broken = []
for b in range(NB):
    a = [p for _, p in sorted(half.get((b, 0), []))]
    c = [p for _, p in sorted(half.get((b, 1), []))]
    if a != c: broken.append((b + 1, a, c))
print(f"   bars whose two half-bars are IDENTICAL: {NB - len(broken)} of {NB}")
for b, a, c in broken:
    print(f"   ⭐ bar {b:2d} BREAKS the repetition: {' '.join(nn(x) for x in a)}  |  {' '.join(nn(x) for x in c)}")

print("\nB. RESTS AND GAPS — can the idle/rest fade ever fire?")
print("   `arcMaxGap` is 0.9 s. Measure the largest gap between consecutive")
print("   note-ons in each voice, in BEATS, and convert at the score's own tempo.")
for nm, ev in (("left hand", lower), ("right hand", upper)):
    ts = sorted(tk for tk, _ in ev)
    gaps = [(ts[i+1] - ts[i]) / div for i in range(len(ts) - 1)]
    big = sorted(gaps)[-3:]
    print(f"   {nm}: {len(ts)} onsets, largest gaps {['%.2f beats' % g for g in big]}")
# per-voice within the left hand: split by pitch into bass (lowest) / tenor
bass_ons, ten_ons = [], []
for b in range(NB):
    ev = sorted(bars[b]); lo = [x for x in ev if x[1] in [p for _, p in lower]]
    l = sorted([(tk, p) for tk, p in lower if tk // BAR == b])
    if not l: continue
    m = min(p for _, p in l)
    for tk, p in l: (bass_ons if p == m else ten_ons).append(tk)
for nm, ts in (("bass voice", sorted(bass_ons)), ("tenor voice", sorted(ten_ons))):
    gaps = [(ts[i+1] - ts[i]) / div for i in range(len(ts) - 1)]
    print(f"   {nm}: {len(ts)} onsets, largest gap {max(gaps):.2f} beats")

print("\nC. THE BASS AS A LINE — where does it stop moving?")
seq = []
for b in range(NB):
    l = [(tk, p) for tk, p in lower if tk // BAR == b]
    seq.append(min(p for _, p in l))
runs, i = [], 0
while i < len(seq):
    j = i
    while j + 1 < len(seq) and seq[j+1] == seq[i]: j += 1
    runs.append((i + 1, j + 1, seq[i])); i = j + 1
for a, b, p in runs:
    mark = "  ⭐ PEDAL" if b - a >= 2 else ""
    print(f"   bars {a:2d}-{b:2d}  {nn(p)}{mark}")

print("\nD. HOW CHROMATIC IS EACH BAR? — bars the triad/seventh table cannot name")
for b, ch, bs, n, ps in rows:
    if "/" in ch: print(f"   ⭐ bar {b:2d}: {' '.join(nn(x) for x in ps)}  (bass {bs}) — not a plain triad or seventh")

print("\nE. DENSITY — events per bar")
cnt = collections.Counter(len(bars[b]) for b in range(NB))
print("   ", dict(cnt))
