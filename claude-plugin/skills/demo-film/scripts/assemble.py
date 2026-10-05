#!/usr/bin/env python3
"""Assemble a narrated demo film from a manifest, stills, loops and bursts.

Each stage becomes up to two beats:

  TALK — the narration, over the PREVIOUS stage's audio ducked to a bed, while
         the stage's stills cut on a timer. The bed is what makes a slideshow
         feel continuous instead of like a stack of separate clips.
  PLAY — the stage's own audio, clean and full level, under real footage of the
         transport running (a "burst") when there is any.

    python3 assemble.py --manifest m.json --vo vo/ --out film.mp4 \
                        --shots shots/ --loops loops/ --bursts bursts/

Manifest shape (only `id` is required):

    {"video": {"width":1920,"height":1080,"fps":30,"cut":5.0,
               "bed":0.16,"playMax":14.0},
     "stages":[{"id":"intro","narration":"...",
                "shots":["a.png","b.png"],   # relative to --shots
                "cut":3.4,                   # override the global cut
                "cutAt":[4.2,9.0],           # TALK only: change the picture at
                                             # THESE seconds instead of on a
                                             # timer, so the still matches the
                                             # sentence being spoken over it.
                "holdLast":true,             # stop cycling; hold the last still
                "loop":"intro.wav",          # relative to --loops
                "playOffset":12.0,           # seconds INTO the loop to start
                                             # playing. Two stages sharing a
                                             # loop MUST differ here or the
                                             # duplicate-beat gate refuses the
                                             # manifest.
                "bedEligible": false,        # optional; default true. false =
                                             # this audio is a DEMONSTRATION,
                                             # not music: do not carry it under
                                             # the next stage's narration.
                "burst":"intro"}]}           # a dir under --bursts holding
                                             # EITHER meta.json + f%04d.png
                                             # (captureUI) OR a single clip.mp4
                                             # (a screen recording).
"""
import argparse, json, os, re, subprocess, sys


def run(a):
    p = subprocess.run(a, capture_output=True, text=True)
    if p.returncode != 0:
        raise SystemExit(f"FAILED {' '.join(a[:8])}\n{p.stderr[-1800:]}")
    return p.stdout


def dur(p):
    return float(run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                      "-of", "csv=p=0", p]).strip())


def has_burst(bdir):
    """True if `bdir` holds footage this assembler can use.

    TWO shapes count, and for a while only one did. captureUI writes a PNG
    sequence with a meta.json beside it; the screen recorder writes a single
    clip.mp4 and no meta.json at all. Testing only for meta.json makes a
    perfectly good recording INVISIBLE — the stage falls back to stills, the
    build prints `burst=no`, nothing errors, and the footage that was recorded
    for that beat is the one thing the viewer never sees.
    """
    if not bdir:
        return False
    return (os.path.exists(os.path.join(bdir, "clip.mp4"))
            or os.path.exists(os.path.join(bdir, "meta.json")))


def assert_distinct_beats(stages):
    """Refuse a manifest in which two stages would build the SAME beat.

    From the review of the first cut: "nothing compares one beat to another, so
    identical beats are the default, not an accident." Three stages named
    mr-intro.wav and all three played its opening seconds; two more shared
    mr-build2.wav. Every existing gate passed, because every existing gate
    looks at ONE stage at a time — and a beat that is wrong only by being a
    repeat is invisible to any check that never sets two beats side by side.

    Two collisions are refused:
      (a) two stages resolving to the same BURST DIRECTORY — the same footage
          twice, which reads on screen as a video that has frozen;
      (b) two stages resolving to the same (LOOP BASENAME, playOffset) — the
          same audio twice, byte for byte.

    A stage with neither a loop nor a burst builds no play beat and is exempt.
    `ab.beforeBurst` is deliberately NOT gated: a before/after pair is MEANT to
    replay the unfixed footage on every cycle — that repetition is the point.
    """
    bursts, plays, bad = {}, {}, []
    for st in stages:
        sid = str(st.get("id", "<stage with no id>"))
        if st.get("burst") or st.get("loop") or st.get("ab"):
            bursts.setdefault(str(st.get("burst", sid)), []).append(sid)
        if st.get("loop"):
            key = (os.path.basename(str(st["loop"])),
                   round(float(st.get("playOffset", 0.0)), 3))
            plays.setdefault(key, []).append(sid)
    for name, ids in bursts.items():
        if len(ids) > 1:
            bad.append(f"burst {name!r} — {len(ids)} stages: " + ", ".join(ids))
    for (loop, off), ids in plays.items():
        if len(ids) > 1:
            bad.append(f"loop {loop!r} at playOffset {off:g}s — "
                       f"{len(ids)} stages: " + ", ".join(ids))
    if bad:
        raise SystemExit(
            "DUPLICATE BEATS — these stages would build byte-identical "
            "footage or audio:\n  " + "\n  ".join(sorted(bad))
            + "\nGive each stage its own burst directory, or a different "
              "\"playOffset\" into the loop.")


class Film:
    def __init__(self, cfg, dirs):
        self.W = cfg.get("width", 1920)
        self.H = cfg.get("height", 1080)
        self.FPS = cfg.get("fps", 30)
        self.CUT = cfg.get("cut", 5.0)
        self.BED = cfg.get("bed", 0.16)
        self.PLAY_MAX = cfg.get("playMax", 14.0)
        self.__dict__.update(dirs)
        # Letterbox rather than crop: panels are the content, and cropping eats
        # the numbers at the edges of a card.
        self.VF = (f"scale={self.W}:{self.H}:force_original_aspect_ratio=decrease,"
                   f"pad={self.W}:{self.H}:(ow-iw)/2:(oh-ih)/2:color=0x0a0e14,"
                   f"fps={self.FPS},format=yuv420p,setsar=1")
        self.NORM = "loudnorm=I=-16:TP=-1.5:LRA=11,aresample=48000,aformat=channel_layouts=stereo"

    # ---------------------------------------------------------------- video
    @staticmethod
    def _crop_expr(z, to, dur):
        """Build a crop= for a zoom, in FRACTIONS of the source (0-1).

        `z` is [x, y, w, h] to sit on. `to` optionally gives a second position
        to travel to over `dur` seconds -- a PAN across the window.

        ⚠ TWO ffmpeg facts, both learned the hard way here:
        ① A comma inside min() MUST be escaped, or it ends crop's argument list
          and ffmpeg reports the rest of the expression as a missing FILTER --
          an error that reads like the filter does not exist.
        ② crop's w/h are evaluated ONCE, at configure time; only x/y are
          per-frame. So a moving crop can PAN but cannot ZOOM, and asking for a
          size that changes with t fails with "Error when evaluating the
          expression" rather than being silently ignored. A zoom that changes
          scale needs zoompan, which re-scales every frame and shimmers on UI
          text. These films therefore CUT to a zoom and pan within it -- which
          is what a screencast does anyway.
        The pan keeps `z`'s size and moves only the top-left corner.
        """
        w, h = z[2], z[3]
        if not to:
            return f"crop=iw*{w:.6f}:ih*{h:.6f}:iw*{z[0]:.6f}:ih*{z[1]:.6f}"
        k = f"min(1\\,t/{max(dur, 0.001):.3f})"          # 0 -> 1 across the shot
        px = f"(({z[0]:.6f})+(({to[0]:.6f})-({z[0]:.6f}))*{k})"
        py = f"(({z[1]:.6f})+(({to[1]:.6f})-({z[1]:.6f}))*{k})"
        return f"crop=iw*{w:.6f}:ih*{h:.6f}:iw*{px}:ih*{py}"

    def segments(self, total, cut=None, bounds=None):
        """How long each still is held, in order.

        Without `bounds` the picture changes on a FIXED TIMER: n = round(total
        / cut) equal slices. Nothing in that consults the narration, which is
        how "A saturator" came to play over the PHASER card and "A phaser" over
        HALL REVERB — the words and the pictures were each individually right
        and were never compared.

        `bounds` is a list of CUMULATIVE seconds, measured from the start of
        the narration, at which the picture should change. Bounds outside
        (0, total) are dropped, duplicates collapse, and a slice shorter than
        one frame is folded into its neighbour rather than handed to ffmpeg as
        `-t 0.000`, which fails with an error about the concat rather than
        about the number.
        """
        if not bounds:
            n = max(1, round(total / (cut or self.CUT)))
            return [total / n] * n
        cuts = sorted({round(float(b), 6) for b in bounds
                       if 0 < float(b) < total})
        durs, prev, carry = [], 0.0, 0.0
        for c in cuts + [float(total)]:
            d = c - prev + carry
            prev, carry = c, 0.0
            if d < 1.0 / self.FPS:
                if durs:
                    durs[-1] += d
                else:
                    carry = d
                continue
            durs.append(d)
        if carry and durs:
            durs[0] += carry
        return durs or [float(total)]

    def stills(self, shots, total, out, cut=None, hold_last=False, bounds=None):
        durs = self.segments(total, cut, bounds)
        n = len(durs)
        if hold_last:
            seq = [shots[min(i, len(shots) - 1)] for i in range(n)]
        else:
            seq = [shots[i % len(shots)] for i in range(n)]
        ins, filt, labels = [], [], []
        for i, (s, each) in enumerate(zip(seq, durs)):
            # A shot is a path, or {"path": ..., "zoom": [x,y,w,h], "to": [...]}
            # with the boxes given as FRACTIONS of the source image so a region
            # survives a change of capture resolution.
            z = to = None
            if isinstance(s, dict):
                z, to, s = s.get("zoom"), s.get("to"), s["path"]
            ins += ["-loop", "1", "-t", f"{each:.3f}", "-i", s]
            pre = (self._crop_expr(z, to, each) + ",") if z else ""
            filt.append(f"[{i}:v]{pre}{self.VF}[v{i}]")
            labels.append(f"[v{i}]")
        filt.append("".join(labels) + f"concat=n={n}:v=1:a=0[o]")
        run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *ins,
             "-filter_complex", ";".join(filt), "-map", "[o]", "-c:v", "libx264",
             "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
             "-r", str(self.FPS), out])

    def labelled(self, video, text, colour, out):
        """Burn a BEFORE/AFTER badge into the top-left of a built segment."""
        import sys as _s, os as _o
        _s.path.insert(0, _o.path.dirname(_o.path.abspath(__file__)))
        from brand import badge
        png = _o.path.join(self.work, f"_badge_{text.lower()}.png")
        if not _o.path.exists(png):
            badge(text, colour, png)
        run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", video,
             "-i", png, "-filter_complex",
             # ⚠ Placement has been wrong twice. The top-left corner is the app's
             # own title bar, so a badge there covers the project name; and the
             # MIDDLE of the frame is where a floating effect editor opens, so a
             # badge at H*0.46 sat squarely on the EQ curve the A/B exists to
             # show. This band -- centred, low, above the transport bar -- is
             # empty in the mixer, the arrange view and the panel shots alike.
             "[0:v][1:v]overlay=(W-w)/2:H*0.82:format=auto,format=yuv420p,setsar=1[v]",
             "-map", "[v]", "-c:v", "libx264", "-preset", "medium", "-crf", "20",
             "-pix_fmt", "yuv420p", "-r", str(self.FPS), out])

    def burst(self, name, total, out):
        d = os.path.join(self.bursts, name)
        clip = os.path.join(self.work, f"_b_{name}.mp4")
        src = os.path.join(d, "clip.mp4")
        if os.path.exists(src):
            # A screen recording arrives as ONE mp4, not a PNG sequence, and it
            # still goes through self.VF so the concat downstream can stay
            # `-c copy`.
            # ⚠ `-an` IS LOAD-BEARING. A recording carries its own audio track;
            # mux() maps no streams explicitly, so ffmpeg would pick an audio
            # stream by its own rules and could take the BURST's audio instead
            # of the stage's loop. The picture would be right, the sound would
            # be silently wrong, and nothing in the build would say so.
            run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", src,
                 "-an", "-vf", self.VF, "-c:v", "libx264", "-preset", "medium",
                 "-crf", "20", "-pix_fmt", "yuv420p", clip])
        else:
            meta = json.load(open(f"{d}/meta.json"))
            run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                 "-framerate", f"{meta['fps']:.4f}", "-i", f"{d}/f%04d.png",
                 "-vf", self.VF, "-c:v", "libx264", "-preset", "medium", "-crf", "20",
                 "-pix_fmt", "yuv420p", clip])
        blen = dur(clip)
        lst = os.path.join(self.work, f"_b_{name}.txt")
        # ⚠ ffmpeg resolves concat entries RELATIVE TO THE LIST FILE, so a
        # relative clip path here becomes segments/segments/... Always absolute.
        open(lst, "w").write("".join(f"file '{os.path.abspath(clip)}'\n"
                                     for _ in range(max(1, int(total / blen) + 1))))
        run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "concat",
             "-safe", "0", "-i", lst, "-t", f"{total:.3f}", "-c:v", "libx264",
             "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
             "-r", str(self.FPS), out])

    # ---------------------------------------------------------------- audio
    def talk_audio(self, vo, bed, out):
        vlen = dur(vo)
        ins, filt = ["-i", vo], [f"[0:a]{self.NORM}[vo]"]
        if bed:
            ins += ["-stream_loop", "-1", "-i", bed]
            filt += [f"[1:a]atrim=0:{vlen:.3f},volume={self.BED},"
                     f"afade=t=in:st=0:d=0.8,"
                     f"afade=t=out:st={max(vlen - 1.5, 0):.3f}:d=1.5,"
                     f"aresample=48000,aformat=channel_layouts=stereo[bd]",
                     # ⚠ normalize=0 IS LOAD-BEARING. ffmpeg's amix divides EVERY input by the
                     # number of inputs, so the default silently took 6.02 dB off the
                     # NARRATION -- the one signal already loudness-normalised to a
                     # target one line above -- every time a bed was present. MEASURED as
                     # a 4.4-6.0 dB drop on bedded stages against unbedded ones in the
                     # same film, by building one video twice with only the bed flag
                     # changed. The bed already has its own explicit `volume={self.BED}`;
                     # amix must mix, not re-level.
                     "[vo][bd]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[o]"]
        else:
            filt += ["[vo]anull[o]"]
        run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *ins,
             "-filter_complex", ";".join(filt), "-map", "[o]",
             "-c:a", "pcm_s16le", "-ac", "2", out])
        return vlen

    def play_audio(self, wav, out, offset=0.0):
        """Up to PLAY_MAX seconds of `wav`, starting `offset` seconds in.

        ⚠ THE OFFSET IS WHAT STOPS TWO STAGES BEING THE SAME BEAT. Before it
        existed every stage naming the same loop played the same opening
        seconds, byte for byte: mr-intro.wav was the audio of three stages and
        mr-build2.wav of two, and the film shipped with all five playing the
        top of the file.

        An offset past the end is a HARD ERROR, not a clamp to 0. A clamp would
        be the friendlier-looking behaviour and it would put back exactly the
        duplicate this argument exists to remove — quietly, and on the stage
        whose author had most clearly intended it to be different.
        """
        total = dur(wav)
        offset = float(offset)
        if offset < 0:
            raise SystemExit(f"playOffset {offset:g}s is negative, for {wav}")
        if offset >= total:
            raise SystemExit(
                f"playOffset {offset:g}s is at or past the end of {wav} "
                f"({total:.2f}s long). Pick an offset inside the file — "
                f"clamping it to 0 would silently re-create the duplicate beat "
                f"the offset exists to prevent.")
        n = min(total - offset, self.PLAY_MAX)
        run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", wav,
             "-af", f"atrim={offset:.3f}:{offset + n:.3f},asetpts=PTS-STARTPTS,"
                    f"afade=t=in:st=0:d=0.15,"
                    f"afade=t=out:st={max(n - 1.0, 0):.3f}:d=1.0,{self.NORM}",
             "-c:a", "pcm_s16le", "-ac", "2", out])
        return n

    def mux(self, v, a, out):
        run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", v, "-i", a,
             "-c:v", "copy", "-c:a", "aac", "-b:a", "192k", "-ac", "2",
             "-shortest", out])


def true_peak(path):
    """dBTP of a rendered file, via ebur128. None if it cannot be read.

    ⚠ `-v error` SUPPRESSES the ebur128 summary, which logs at INFO -- asking
    for the number and silencing the thing that prints it. -hide_banner keeps
    it."""
    p = subprocess.run(["ffmpeg", "-hide_banner", "-i", path,
                        "-af", "ebur128=peak=true", "-f", "null", "-"],
                       capture_output=True, text=True)
    m = re.findall(r"Peak:\s*(-?\d+\.?\d*)", p.stderr)
    return float(m[-1]) if m else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--vo", required=True, help="dir of <stage-id>.wav narration")
    ap.add_argument("--out", required=True)
    ap.add_argument("--shots", default="shots")
    ap.add_argument("--loops", default="loops")
    ap.add_argument("--bursts", default="bursts")
    ap.add_argument("--work", default="segments")
    # Brand furniture. Both are produced by brand.py with the SAME encoder
    # flags as the body, so the final concat can stay -c copy.
    ap.add_argument("--intro", help="clip to place before the film")
    ap.add_argument("--outro", help="clip to place after the film")
    a = ap.parse_args()

    man = json.load(open(a.manifest))
    os.makedirs(a.work, exist_ok=True)
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    film = Film(man.get("video", {}),
                dict(shots=a.shots, loops=a.loops, bursts=a.bursts, work=a.work))

    def resolve(p, root):
        """A shot is a path, or {"path":…, "zoom":[…], "to":[…]} for a zoom.

        ⚠ The dict form was added for the session films and it reaches HERE
        before it reaches stills(): both this and the os.path.exists filter
        below would raise TypeError on a dict, so the zoom support has to be
        threaded through the resolver too, not just the renderer."""
        if isinstance(p, dict):
            return {**p, "path": resolve(p["path"], root)}
        return p if os.path.isabs(p) else os.path.join(root, p)

    def shot_path(s):
        return s["path"] if isinstance(s, dict) else s

    # ⚠ BEFORE ANYTHING IS BUILT. Every other check in this pipeline looks at
    # one beat; this one is the only thing that looks at two.
    assert_distinct_beats(man["stages"])

    parts, prev_loop, missing = [], None, []
    for st in man["stages"]:
        sid = st["id"]
        vo = os.path.join(a.vo, f"{sid}.wav")

        shots = [resolve(s, a.shots) for s in st.get("shots", [])]
        shots = [s for s in shots if os.path.exists(shot_path(s))]
        if not shots:
            missing.append(f"{sid}: no stills")
            continue

        tlen = plen = 0.0
        if os.path.exists(vo):
            ta = os.path.join(a.work, f"{sid}-talk.wav")
            tv = os.path.join(a.work, f"{sid}-talk.mp4")
            tm = os.path.join(a.work, f"{sid}-talk-mux.mp4")
            tlen = film.talk_audio(vo, prev_loop, ta)
            # `cutAt` is the TALK segment only: it is the narration's own beat
            # list, and the play/burst segments are not narrated.
            film.stills(shots, tlen, tv, st.get("cut"), st.get("holdLast", False),
                        bounds=st.get("cutAt"))
            film.mux(tv, ta, tm)
            parts.append(tm)
        else:
            missing.append(f"{sid}: no narration wav")

        # ---------------------------------------------------------------- A/B
        # A fix you only hear once is an assertion. Alternating the SAME passage
        # unfixed and fixed, twice, is the only way a listener can actually
        # judge it -- and the badges say which one is playing.
        ab = st.get("ab")
        if ab:
            before_wav = resolve(ab["before"], a.loops)
            after_wav = resolve(st["loop"], a.loops)
            half = float(ab.get("seconds", 5.5))
            for cycle in range(int(ab.get("cycles", 2))):
                for tag, wav, bname, col in (
                    ("BEFORE", before_wav, ab.get("beforeBurst"), (255, 184, 77)),
                    ("AFTER",  after_wav,  st.get("burst", sid),  (93, 255, 159))):
                    stem = os.path.join(a.work, f"{sid}-ab{cycle}-{tag.lower()}")
                    pa, pv, pl, pm = (stem + ".wav", stem + ".mp4",
                                      stem + "-lab.mp4", stem + "-mux.mp4")
                    saved, film.PLAY_MAX = film.PLAY_MAX, half
                    n = film.play_audio(wav, pa,
                                        offset=float(st.get("playOffset", 0.0)))
                    film.PLAY_MAX = saved
                    bdir = os.path.join(a.bursts, bname) if bname else None
                    if has_burst(bdir):
                        film.burst(bname, n, pv)
                    else:
                        # `beforeShots`/`afterShots` let each half show its own
                        # stills -- an untouched EQ panel against the moved
                        # one. Without it both halves show the same picture
                        # and only the badge distinguishes them, which reads
                        # as a stuck video on a subtle fix.
                        half_shots = shots
                        key = "beforeShots" if tag == "BEFORE" else "afterShots"
                        if ab.get(key):
                            hs = [resolve(x, a.shots) for x in ab[key]]
                            hs = [x for x in hs if os.path.exists(shot_path(x))]
                            if hs:
                                half_shots = hs
                        film.stills(half_shots, n, pv, st.get("cut"))
                    film.labelled(pv, tag, col, pl)
                    film.mux(pl, pa, pm)
                    parts.append(pm)
                    plen += n
            prev_loop = after_wav if st.get("bedEligible", True) else None
            print(f"  {sid:22s} talk {tlen:6.1f}s + A/B {plen:5.1f}s  "
                  f"({int(ab.get('cycles',2))} x before/after)", flush=True)
            continue

        loop = resolve(st["loop"], a.loops) if st.get("loop") else None
        if loop and os.path.exists(loop):
            pa = os.path.join(a.work, f"{sid}-play.wav")
            pv = os.path.join(a.work, f"{sid}-play.mp4")
            pm = os.path.join(a.work, f"{sid}-play-mux.mp4")
            plen = film.play_audio(loop, pa,
                                   offset=float(st.get("playOffset", 0.0)))
            bdir = os.path.join(a.bursts, st.get("burst", sid))
            if has_burst(bdir):
                film.burst(st.get("burst", sid), plen, pv)
            else:
                film.stills(shots, plen, pv, st.get("cut"))
            film.mux(pv, pa, pm)
            parts.append(pm)
            # ⚠ A DEMONSTRATION IS NOT A BED. Carrying the previous stage's
            # audio under the next narration is right for MUSIC and wrong for
            # everything else: in the tuning lesson a pair of beating test
            # tones kept droning under the speaker, which is both distracting
            # and something no real production would do. A stage whose audio is
            # a measurement rather than a piece of music sets
            # "bedEligible": false and the bed simply stops when it stops.
            prev_loop = loop if st.get("bedEligible", True) else None

        print(f"  {sid:22s} talk {tlen:6.1f}s + play {plen:5.1f}s  "
              f"stills={len(shots)}  burst={'yes' if plen and has_burst(os.path.join(a.bursts, st.get('burst', sid))) else 'no'}",
              flush=True)

    if not parts:
        # ⛔ SAY WHY. The `missing` list is printed near the end of this
        # function -- which never runs when we bail out here, so the one case
        # that most needs a diagnosis was the one case that printed a bare
        # three-word error. It took a forty-minute pipeline run and a manual
        # re-run to learn that every stage had been skipped for "no stills".
        raise SystemExit(
            "nothing to assemble — every stage was skipped:\n  "
            + "\n  ".join(missing or ["(no stages in the manifest at all)"])
            + "\n\nA stage is skipped when none of its `shots` resolve against "
              "--shots. Check that the build actually wrote them: a rebuild "
              "with --no-shots used to DELETE the stills a previous build made.")
    intro = a.intro or man.get("intro")
    outro = a.outro or man.get("outro")
    # ⚠ Do NOT precompute both positions: inserting the intro shifts every
    # later index by one, which silently puts the end card SECOND TO LAST.
    # Intro goes in first, outro is appended afterwards.
    for label, clip in (("intro", intro), ("outro", outro)):
        if not clip:
            continue
        if not os.path.exists(clip):
            raise SystemExit(f"--{label}: no such file {clip}")
        # ⚠ concat -c copy does NOT error on mismatched streams, it glitches on
        # playback. Refuse rather than ship a card that stutters.
        probe = lambda p, s: run(["ffprobe", "-v", "error", "-select_streams", s,
            "-show_entries", "stream=width,height,r_frame_rate,pix_fmt,sample_aspect_ratio"
            if s == "v:0" else "stream=codec_name,sample_rate,channels",
            "-of", "csv=p=0", p]).strip()
        for s in ("v:0", "a:0"):
            if probe(clip, s) != probe(parts[0], s):
                raise SystemExit(
                    f"--{label} stream mismatch ({s}):\n  card: {probe(clip, s)}"
                    f"\n  film: {probe(parts[0], s)}\nRe-render it with brand.py.")
        parts.insert(0, clip) if label == "intro" else parts.append(clip)
        print(f"  {label:22s} {dur(clip):5.1f}s")
    lst = os.path.join(a.work, "_all.txt")
    open(lst, "w").write("".join(f"file '{os.path.abspath(p)}'\n" for p in parts))
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "concat",
         "-safe", "0", "-i", lst, "-c", "copy", a.out])

    # ⚠ TRUE-PEAK BACKSTOP. `loudnorm`'s single-pass TP= is a target, not a
    # guarantee: percussive material sails past it. The Amen lesson came out of
    # the concat at -0.3 dBTP against a -1.0 ceiling, and the only reason anyone
    # noticed is that verify.py measures the finished file.
    # The fix is a STATIC trim, not a limiter -- if the peak is 0.7 dB too high,
    # turn the whole film down 0.7 dB. Nothing is compressed, no transient is
    # reshaped, and the film that ships is the film that was mixed.
    # ⛔⛔ EACH ATTEMPT RE-TRIMS THE PRISTINE MIX, NEVER THE PREVIOUS ATTEMPT.
    # This loop used to feed its own output back in, re-encoding AAC every pass.
    # AAC is lossy and its decoded output can overshoot the encoder's input, so
    # the "fix" accumulated generation loss: an observed run went -0.70 ->
    # -0.80 -> -0.90 -> +1.20 dBTP, i.e. a 0.10 dB REDUCTION raised the peak by
    # 2.1 dB, and the film was then rejected as "would not converge". The mix
    # was never the problem; the measurement chain was eating it.
    #
    # So: keep the untrimmed render, accumulate ONE total trim, and always
    # apply that single trim to the original. One generation, always.
    tp = true_peak(a.out)
    if tp is not None and tp > -1.0:
        pristine = a.out + ".pre-trim.mp4"
        os.replace(a.out, pristine)
        trim = 0.0
        for attempt in range(4):
            # The 0.1 dB of extra headroom absorbs the single AAC generation
            # that is still unavoidable, instead of discovering it afterwards.
            trim += (-1.0 - tp) - 0.1
            run(["ffmpeg", "-v", "error", "-y", "-i", pristine,
                 "-af", f"volume={trim:.2f}dB", "-c:v", "copy", "-c:a", "aac",
                 "-b:a", "192k", a.out])
            was, tp = tp, true_peak(a.out)
            print(f"  true peak   {was:+.2f} -> total trim {trim:.2f} dB -> {tp:+.2f} dBTP"
                  f"{'' if (tp is not None and tp <= -1.0) else '  (still over — retrying)'}")
            if tp is None or tp <= -1.0:
                break
        os.remove(pristine)
    if tp is not None and tp > -0.95:
        raise SystemExit(f"true-peak trim would not converge: {tp:+.2f} dBTP")

    print(f"\nWROTE {a.out}\n{dur(a.out):.1f}s from {len(parts)} clips")
    if missing:
        # Loud, because a missing narration wav silently shortens the film and
        # nothing else would tell you which line went absent.
        print("\nWARNINGS:")
        for m in missing:
            print("  -", m)
    return 0


if __name__ == "__main__":
    sys.exit(main())
