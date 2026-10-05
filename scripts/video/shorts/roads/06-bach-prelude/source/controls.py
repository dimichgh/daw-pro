#!/usr/bin/env python3
r"""⭐ ONE POSITIVE CONTROL PER ROUND-30 FIX: the wrong answer BEFORE, the right
one AFTER, with numbers. `ly2notes-before.py` is the parser as it stood at the
end of round 29; the fixed one is imported from its real home.

⚠ Fixes 3/4/5/6 could not even be REACHED by the old parser through its own
`block()`, because fix 1 made that block come back empty. Each of those controls
therefore hands the old parser a body extracted with a corrected delimiter, so
the failure being demonstrated is the one named and not fix 1 again."""
import re, os, importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
LY   = os.path.join(HERE, "wtk1-prelude1.ly")
MOON = os.path.join(HERE, "..", "..", "03-moonlight-long", "source", "moonlight1-a4.ly")


def load(p):
    s = importlib.util.spec_from_file_location(os.path.basename(p), p)
    m = importlib.util.module_from_spec(s); s.loader.exec_module(m); return m


OLD = load(os.path.join(HERE, "ly2notes-before.py"))
NEW = load(os.path.join(HERE, "..", "..", "03-moonlight-long", "ly2notes.py"))
SRC = open(LY).read()
NAMES = "C C# D D# E F F# G G# A A# B".split()
nn = lambda p: f"{NAMES[p % 12]}{p // 12 - 1}"


def body_old(name):
    i = SRC.index("\n" + name + " =")
    j = SRC.index("{", i); d, k = 0, j
    while True:
        if SRC[k] == "{": d += 1
        elif SRC[k] == "}": d -= 1
        if d == 0: return SRC[j + 1:k]
        k += 1


print("=" * 78)
print("FIX 1  block() matched inside `copyright = \"Public Domain\"`")
ev, _ = OLD.parse(OLD.block(SRC, "right"), 3)
print(f"  BEFORE  block(src,'right') -> {len(ev)} events, and NO ERROR")
ev2, _ = NEW.parse_voice(SRC, "right", 3)
print(f"  AFTER   parse_voice(src,'right') -> {len(ev2)} events, "
      f"{sum(1 for e in ev2 if not e[3])} sounding")
moon = open(MOON).read()
hits = [m.start() for m in re.finditer(re.escape("bottom ="), moon)]
print(f"  LATENT HERE TOO: 'bottom =' occurs at {hits} in the Moonlight file")
print(f"     the music is the FIRST hit ({hits[0]}); the others are "
      f"`ragged-bottom =` / `ragged-last-bottom =` inside \\paper.")
swapped = moon[hits[1] - 400:] + moon[:hits[1] - 400]   # a decoy hit, first
try:
    n = len(OLD.parse(OLD.block(swapped, "bottom"), 3)[0])
    print(f"     with a decoy `bottom =` placed BEFORE the music, the OLD "
          f"parser reads {n} bass events instead of 104")
except Exception as e:
    print(f"     with a decoy `bottom =` placed BEFORE the music, the OLD "
          f"parser: {type(e).__name__}")
print(f"     the NEW one is line-anchored: "
      f"{len(NEW.parse_voice(moon, 'bottom', 3)[0])} events either way")

print("=" * 78)
print("FIX 2  `<< A \\\\ B >>` polyphony concatenated into one line")
ev, _ = OLD.parse(body_old("left"), 3)
none_ = sum(1 for e in ev if not e[3] and e[1] is None)
print(f"  BEFORE  {len(ev)} events, {none_} with a None pitch list, "
      f"total duration {sum(e[2] for e in ev):.2f} whole notes (the piece is 35)")
a = NEW.parse_voice(SRC, "left", 3, voice=0)[0]
b = NEW.parse_voice(SRC, "left", 3, voice=1)[0]
print(f"  AFTER   voice 0 {sum(1 for e in a if not e[3])} sounding "
      f"({sum(e[2] for e in a):.2f} whole notes), "
      f"voice 1 {sum(1 for e in b if not e[3])} ({sum(e[2] for e in b):.2f})")

print("=" * 78)
print("FIX 3  the pitch model was hard-coded RELATIVE; this source is ABSOLUTE")
ev, _ = OLD.parse(body_old("right"), 3)
sound = [e for e in ev if not e[3]]
print(f"  BEFORE  bar 1 = {[nn(e[1][0][0]) for e in sound[2:8]]}   "
      f"highest MIDI in the part: {max(n[0] for e in sound for n in e[1])}")
ev2, _ = NEW.parse_voice(SRC, "right", 3)
s2 = [e for e in ev2 if not e[3]]
print(f"  AFTER   bar 1 = {[nn(e[1][0][0]) for e in s2[:6]]}   "
      f"highest MIDI in the part: {max(n[0] for e in s2 for n in e[1])}")
print("  MIDI    bar 1 = ['G4', 'C5', 'E5', 'G4', 'C5', 'E5']  (LilyPond's own)")
print(f"  mode DETECTED as: {NEW.voice_source(SRC, 'right')[1]}   "
      f"(Moonlight: {NEW.voice_source(moon, 'bottom')[1]})")

print("=" * 78)
print("FIX 4  `\\transpose c c'` left its two arguments behind as notes")
print(f"  BEFORE  first two events: "
      f"{[(e[0], nn(e[1][0][0])) for e in ev if not e[3]][:2]}  <- phantom")
print(f"  AFTER   first two events: "
      f"{[(e[0], nn(e[1][0][0])) for e in ev2 if not e[3]][:2]}")
print(f"  the transposition itself is now APPLIED: shift = "
      f"{NEW.voice_source(SRC, 'right')[2]} (diatonic steps, semitones)")

print("=" * 78)
print("FIX 5  `!` (forced accidental) detached the duration")
for mod, tag in ((OLD, "BEFORE"), (NEW, "AFTER ")):
    kw = {} if mod is OLD else {"mode": "relative"}
    e, _ = mod.parse("c4 b!2. b4", 4, **kw)
    print(f"  {tag}  'c4 b!2. b4' -> durations {[x[2] for x in e]}  "
          f"(a dotted half is 0.75 whole notes)")
print("  IN THE MOONLIGHT FILE: `b!2.` (line 137), `fis,!`/`a!` (260), "
      "`b,!`/`e!` (289).")
print("  The fix moves 31 melody events, ALL at whole-note 55.0 or later "
      "(bar 56+);")
print("  the film renders 42 bars, so all three song.json files are "
      "byte-identical.")

print("=" * 78)
print("THE GUARD ITSELF — it must FIRE, or it is decoration")
try:
    NEW.parse(body_old("right"), 3, mode="relative")
    print("  ⛔ BROKEN: parsing an absolute source in relative mode did NOT assert")
except AssertionError as e:
    print(f"  fires: {str(e).split(chr(10))[0][:150]}")
try:
    NEW.parse(body_old("right"), 3, mode="absolute")
    print("  and it does NOT fire on the correct mode (negative control) — ok")
except AssertionError as e:
    print(f"  ⛔ BROKEN: it fired on the CORRECT mode: {e}")
try:
    NEW.invariants("probe", [(0.0, [(9, "c", -1)], 0.25, False)], [0.0], verbose=False)
    print("  ⛔ BROKEN: invariants() accepted MIDI 9")
except AssertionError as e:
    print(f"  invariants fires: {str(e)[:110]}")
NEW.invariants("probe", [(0.0, [(60, "c", 4)], 0.25, False)], [0.0], verbose=False)
print("  invariants passes a well-formed part (negative control) — ok")

print("=" * 78)
print("FIX 6  `\\clef \"bass\"` -> the quote strip left `\\clef`, which then ate "
      "the next word")
demo = '\\clef "bass" \n    r8   f,16 a,'
q = re.sub(r'-?"[^"]*"', " ", demo)
print(f"  BEFORE  {demo!r}")
print(f"          after the quoted-string strip: {q!r}")
OLDCLEF = re.compile(r"\\clef\s+\"?[a-zA-Z]+\"?")
ate = OLDCLEF.sub(" ", q)
print(f"          after the unquoted clef rule : {ate!r}   <- the rest is GONE")
print(f"  AFTER   {NEW.clean(demo)!r}")
print("  MEASURED against LilyPond's MIDI: 21 of 415 figure notes disagreed "
      "(all in bars 33-34), 0 after.")
print("=" * 78)
