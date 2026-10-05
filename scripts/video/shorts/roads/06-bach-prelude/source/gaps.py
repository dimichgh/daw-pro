"""⭐ CAN THE IDLE/REST FADE FIRE ON THIS PIECE? — measured, not assumed.

road.html:1802  gapNext = ns[kn].t - ns[k].t          (ONSET to ONSET)
road.html:1804  if (gapNext > arcMaxGap && t > noteEnd)   noteEnd = t + dur

So the clamp fires in the window [noteEnd, nextOnset) whenever the ONSET-TO-ONSET
gap exceeds 0.9 s. A held note whose duration reaches the next onset never fires,
however long the gap; a note that STOPS EARLY does, for exactly the hole it leaves.
Both numbers therefore have to be measured per voice, from the note-offs.
"""
import struct, collections
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
            if hi == 0x90 and b2: ev.append((tick, a, 1))
            elif hi == 0x80 or (hi == 0x90 and not b2): ev.append((tick, a, 0))
    tr.append(ev)

def notes(ev):
    open_, out = collections.defaultdict(list), []
    for tk, p, on in sorted(ev, key=lambda e: (e[0], e[2])):
        if on: open_[p].append(tk)
        elif open_[p]: out.append((open_[p].pop(0), p, tk))
    return sorted(out)

BAR = 4 * div
SEC_PER_BEAT = 1.0                      # the score's own \tempo 4=60
def beats(t): return t / div
NAMES = "C C# D D# E F F# G G# A A# B".split()
nn = lambda p: f"{NAMES[p % 12]}{p // 12 - 1}"

L, U = notes(tr[1]), notes(tr[2])
# split the left hand into its two written voices by pitch rank within each bar
bass, ten = [], []
for b in set(t // BAR for t, _, _ in L):
    inb = [n for n in L if n[0] // BAR == b]
    lo = min(p for _, p, _ in inb)
    for n in inb: (bass if n[1] == lo else ten).append(n)
ARC = 0.9
for nm, ns in (("RIGHT HAND figure", U), ("TENOR (left, upper)", sorted(ten)),
               ("BASS (left, lower)", sorted(bass))):
    ns = sorted(ns)
    fires = []
    for i in range(len(ns) - 1):
        on, p, off = ns[i]; nxt = ns[i+1][0]
        gap_onset = beats(nxt - on) * SEC_PER_BEAT
        hole = beats(nxt - off) * SEC_PER_BEAT
        if gap_onset > ARC and hole > 0: fires.append((on / BAR + 1, gap_onset, hole))
    on_on = [beats(ns[i+1][0] - ns[i][0]) for i in range(len(ns)-1)]
    holes = [beats(ns[i+1][0] - ns[i][2]) for i in range(len(ns)-1)]
    print(f"\n{nm}: {len(ns)} notes")
    print(f"   onset-to-onset gap: median {sorted(on_on)[len(on_on)//2]:.3f} beats, max {max(on_on):.3f}")
    print(f"   SILENT hole after each note: max {max(holes):.3f} beats, "
          f"{sum(1 for h in holes if h > 0)} of {len(holes)} are > 0")
    print(f"   ⭐ clamp would fire on {len(fires)} of {len(ns)-1} notes"
          + (f"; first at bar {fires[0][0]:.2f}, gap {fires[0][1]:.2f}s, hole {fires[0][2]:.2f}s" if fires else ""))
