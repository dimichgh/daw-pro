#!/usr/bin/env python3
"""Re-record the stages whose take BABBLED PAST THE END OF THE SCRIPT.

⚠⚠ THIS IS THE FILM'S OWN THESIS, IN THE FILM'S OWN NARRATION. Two takes said
every word of their script correctly and then kept talking: `08-before` ended
"...Listen to this one." and carried on with "that was at the corner. For yeah.
And it's the one, so it might be three and then over to size..."; `10-reveal`
ended "...a real one about 5." and carried on with "Action pandemics is the
signatures between 33 degrees and 45...". Both PASSED every gate: level, pace,
brand, facts, and a similarity of 0.83 and 0.87 against a floor of 0.80,
because a tail of junk on a 1,100-character script cannot move an aggregate far
enough. Nothing in the pipeline looks at what comes AFTER the last scripted word.

So this adds the missing check — a TAIL check — and re-records until a take
passes it. It does not touch the shared scripts; it drives shortsmith's own
synth/transcribe/sim so the take is a genuine single take, then writes the
cache key shortsmith computes so the film assembles from it.
"""
import json, os, re, sys

sys.path.insert(0, "/Users/dsemenov/Views/daw-pro/scripts/video")
import shortsmith as SS                                          # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = json.load(open(f"{HERE}/HWB4.json"))
VO = f"{HERE}/out/vo"
TRIES = 8
STAGES = sys.argv[1:] or ["08-before", "10-reveal"]


def tail_after(script, got):
    """What the take said AFTER the script's last few content words.

    Anchored on the last four words of the script rather than on length, so a
    take that merely paraphrases is not accused of babbling."""
    sw = [w for w in re.findall(r"[a-z']+", script.lower()) if len(w) > 2]
    gw = re.findall(r"[a-z']+", got.lower())
    anchor = sw[-4:]
    for i in range(len(gw) - 1, 2, -1):
        window = gw[max(0, i - 12):i]
        if sum(1 for a in anchor if a in window) >= 3:
            return gw[i:]
    return []          # anchor not found at all -> cannot judge, treat as clean


cache = json.load(open(f"{VO}/_cache.json"))
for sid in STAGES:
    st = next(s for s in SPEC["stages"] if s["id"] == sid)
    text = st["narration"]
    best = None
    for i in range(1, TRIES + 1):
        tmp = f"{VO}/_re{i}.wav"
        SS.synth(text, tmp, 0.35 if i < 4 else 0.30)
        got = SS.transcribe(tmp)
        s = SS.sim(text, got)
        tail = tail_after(text, got)
        missing = SS.fact_missing(st.get("factCheck", []), got)
        print(f"  {sid} take {i}: sim {s:.2f}  tail {len(tail)} words  "
              f"missing {missing}"
              + (f"  TAIL: {' '.join(tail[:12])}" if tail else ""))
        if s >= 0.80 and not missing and len(tail) <= 3:
            os.replace(tmp, f"{VO}/{sid}.wav")
            best = (i, s, got)
            break
        if best is None or (len(tail), -s) < (best[3], -best[1]):
            best = (i, s, got, len(tail), tmp)
        else:
            os.remove(tmp)
    if len(best) > 3:
        sys.exit(f"✘ {sid}: {TRIES} takes, none clean of a tail. "
                 f"Best had {best[3]} trailing words.")
    print(f"  {sid}: kept take {best[0]}, sim {best[1]:.2f}, no tail")
    cache[sid] = SS.vo_key(st)
    for f in os.listdir(VO):
        if f.startswith("_re"):
            os.remove(f"{VO}/{f}")

json.dump(cache, open(f"{VO}/_cache.json", "w"))
print("cache updated")
