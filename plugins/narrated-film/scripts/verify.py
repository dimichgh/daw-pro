#!/usr/bin/env python3
"""Check a finished film. The assembler cannot tell you it dropped a line.

Every probe here was written after a delivered film shipped with the defect it
looks for. They are collected in one place because they were being retyped as
shell one-liners each time, and a probe you retype is a probe you eventually
type wrong.

    python3 verify.py --film out.mp4
    python3 verify.py --film out.mp4 --manifest m.json      # + content gate
    python3 verify.py --film out.mp4 --joins 5.0,17.02      # + seam check

⚠ THE RULE BEHIND ALL OF IT: a tool that never ran and a tool that ran and
found nothing produce the same output. So every check that can pass by doing
nothing carries a POSITIVE CONTROL, and says so in its output. A check whose
control fails is reported as BROKEN, not as a pass -- an unverified pass is
worse than a failure, because you act on it.
"""
import argparse, json, os, re, subprocess, sys, tempfile

OK, BAD, BROKE = "ok", "FAIL", "BROKEN"
results = []


def record(name, status, detail):
    results.append((name, status, detail))
    mark = {OK: "  ok  ", BAD: " FAIL ", BROKE: "BROKEN"}[status]
    print(f"[{mark}] {name}: {detail}")


def run(args, binary=False):
    # ⚠ binary=True for anything that writes PCM to stdout. text=True decodes
    # stdout as utf-8, and raw audio is not utf-8 -- it raises UnicodeDecodeError
    # from inside subprocess, which reads like a bug in ffmpeg rather than here.
    return subprocess.run(args, capture_output=True, text=not binary)


def ff(args):
    """ffmpeg with the banner ON.

    ⚠ `-v error` SUPPRESSES the ebur128 and astats summaries, which log at INFO
    -- the numbers you are asking for vanish and the command still exits 0.
    """
    return run(["ffmpeg", "-hide_banner", *args, "-f", "null", "-"]).stderr


def probe(path, stream, fields):
    r = run(["ffprobe", "-v", "error", "-select_streams", stream,
             "-show_entries", f"stream={fields}", "-of", "csv=p=0", path])
    return r.stdout.strip()


def duration(path):
    r = run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "csv=p=0", path])
    try:
        return float(r.stdout.strip())
    except ValueError:
        return 0.0


# --------------------------------------------------------------------- checks
def check_streams(film, manifest=None):
    v = probe(film, "v:0", "codec_name,width,height,r_frame_rate,pix_fmt")
    a = probe(film, "a:0", "codec_name,sample_rate,channels")
    if not v or not a:
        return record("streams", BAD, f"missing stream (video={v!r} audio={a!r})")
    record("streams", OK, f"v={v}  a={a}  {duration(film):.1f}s")

    # ⚠ Reporting the dimensions is not checking them. A manifest that asks for
    # 1080x1920 and produces a landscape file is a silent, total failure for a
    # Short -- it uploads, it plays, and it is the wrong shape.
    if not manifest:
        return
    try:
        cfg = json.load(open(manifest)).get("video", {})
    except Exception as e:
        return record("frame size", BROKE, f"manifest unreadable: {e}")
    want_w, want_h = cfg.get("width"), cfg.get("height")
    if not want_w or not want_h:
        return record("frame size", BROKE, "manifest names no width/height")
    try:
        got_w = int(probe(film, "v:0", "width"))
        got_h = int(probe(film, "v:0", "height"))
    except ValueError:
        return record("frame size", BROKE, "ffprobe gave no dimensions")
    shape = "portrait" if want_h > want_w else "landscape"
    if (got_w, got_h) != (want_w, want_h):
        record("frame size", BAD,
               f"manifest asks {want_w}x{want_h} ({shape}), file is {got_w}x{got_h}")
    else:
        record("frame size", OK, f"{got_w}x{got_h} ({shape}), as the manifest asks")


def check_av_drift(film):
    """A concat that padded its joins shows up as video and audio disagreeing."""
    try:
        v = float(probe(film, "v:0", "duration"))
        a = float(probe(film, "a:0", "duration"))
    except ValueError:
        return record("a/v drift", BROKE, "stream durations unreadable")
    d = abs(v - a)
    frame = 1 / 30
    record("a/v drift", OK if d < frame * 1.5 else BAD,
           f"{d*1000:.1f} ms ({'under' if d < frame else 'over'} one frame)")


def frames(film, times, tmp, tag="f"):
    out = []
    for t in times:
        p = os.path.join(tmp, f"{tag}{t}.png")
        run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-ss", str(t),
             "-i", film, "-frames:v", "1", "-vf", "scale=480:-1", p, "-y"])
        if os.path.exists(p):
            out.append(p)
    return out


def check_distinct_frames(film, tmp):
    """Identical pictures across the film mean a stuck slideshow.

    ⚠ DO NOT HASH THE FRAMES. That was the first version and it FALSELY PASSED
    a film that was a single still image for its whole duration: h264 encoding
    noise makes every extracted PNG a few bits different, so six identical
    pictures produced six different md5s and scored "5 distinct of 6". Hashing
    answers "are these files identical", which is not the question. Compare the
    PIXELS, with a threshold above the codec's own noise floor (measured at
    about 0.75 mean absolute difference on this encoder).
    """
    try:
        from PIL import Image
        import numpy as np
    except ImportError:
        return record("distinct frames", BROKE, "Pillow/numpy not installed")
    dur = duration(film)
    times = [round(dur * f, 2) for f in (0.08, 0.22, 0.38, 0.55, 0.72, 0.88)]
    got = frames(film, times, tmp)
    if len(got) < 3:
        return record("distinct frames", BROKE, f"only extracted {len(got)} frames")
    ims = [np.asarray(Image.open(g).convert("RGB"), float) for g in got]
    # POSITIVE CONTROL: a frame against itself must read 0.00. If it does not,
    # the comparison is broken and every verdict below it is meaningless.
    if float(np.abs(ims[0] - ims[0]).mean()) != 0.0:
        return record("distinct frames", BROKE, "control failed: a frame differs from itself")
    NOISE = 2.0                       # comfortably above ~0.75 of codec noise
    diffs = [float(np.abs(ims[i] - ims[i - 1]).mean()) for i in range(1, len(ims))]
    moved = sum(1 for d in diffs if d > NOISE)
    # ⚠ The bar is "the picture changes at all", NOT "it changes at every
    # sample". A short film built from two slides legitimately holds one of
    # them across several sample points, and demanding variation everywhere
    # failed the kit's OWN example film. Zero movement is the real defect --
    # that is a stuck slideshow. The count is always printed so a human can
    # judge whether the film should have moved more than it did.
    record("distinct frames", OK if moved > 0 else BAD,
           f"{moved} of {len(diffs)} consecutive pairs differ (max {max(diffs):.2f}, "
           f"min {min(diffs):.2f}, noise floor {NOISE}); control: frame vs itself = 0.00"
           + ("  -- STUCK: no sampled pair changed" if moved == 0 else ""))


def check_audio_present(film):
    """A missing narration wav silently shortens a film; silence is the tell."""
    dur = duration(film)
    spots = [round(dur * f, 1) for f in (0.1, 0.35, 0.6, 0.85)]
    quiet = []
    for t in spots:
        out = ff(["-ss", str(t), "-t", "6", "-i", film, "-af", "astats=metadata=1"])
        m = re.search(r"RMS level dB:\s*(-?[\d.]+|-inf)", out)
        if not m:
            return record("audio present", BROKE,
                          "no RMS in astats output (is the banner suppressed?)")
        v = m.group(1)
        if v == "-inf" or float(v) < -60:
            quiet.append(f"{t}s={v}")
    record("audio present", OK if not quiet else BAD,
           "audio at all 4 sample points" if not quiet else f"near-silent at {', '.join(quiet)}")


def check_loudness(film, target, tol):
    out = ff(["-i", film, "-af", "ebur128=peak=true"])
    # ⚠ ebur128 prints a running per-frame reading AND a final Summary. A plain
    # search finds the FIRST "I:" -- the reading at t=0, which on a film that
    # opens with a title card is gated silence and reports -70.0 LUFS. That is
    # a wrong number that looks like a real measurement. Parse the SUMMARY.
    tail = out[out.rindex("Summary:"):] if "Summary:" in out else ""
    li = re.search(r"I:\s*(-?[\d.]+)\s*LUFS", tail)
    tp = re.search(r"Peak:\s*(-?[\d.]+)\s*dBFS", tail)
    if not li or not tp:
        return record("loudness", BROKE, "ebur128 summary absent (use -hide_banner, not -v error)")
    L, P = float(li.group(1)), float(tp.group(1))
    bad = []
    # ⚠ There is no single right integrated loudness for a film. A narrated
    # lesson sits near -19 LUFS and a music trailer near -14; enforcing a
    # default here failed a perfectly good lesson. The number is always
    # REPORTED; it is only a failure when the caller states a target.
    if target is not None and abs(L - target) > tol:
        bad.append(f"{L} LUFS off stated target {target}")
    # True peak is different: over -1.0 dBTP risks clipping on any decoder, and
    # that is a defect whatever the material.
    if P > -1.0:
        bad.append(f"true peak {P} dBTP over -1.0")
    record("loudness", OK if not bad else BAD,
           f"{L} LUFS / {P} dBTP" + ("  (no target stated)" if target is None else f" (target {target})")
           + ("" if not bad else "  -- " + "; ".join(bad)))


def pcm(film, ss, t=0.30):
    import numpy as np
    r = run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-ss", str(ss),
             "-t", str(t), "-i", film, "-f", "f32le", "-ac", "1", "-ar", "48000", "-"],
            binary=True)
    return np.frombuffer(r.stdout, dtype="float32")


def check_joins(film, joins):
    """A `-c copy` concat can click at a join. Compare each seam to a hard splice.

    The control is the point: a seam is only 'clean' relative to what a real
    discontinuity measures on THIS material.
    """
    try:
        import numpy as np
    except ImportError:
        return record("joins", BROKE, "numpy not installed")
    dur = duration(film)
    jump = lambda x: float(np.abs(np.diff(x)).max()) if len(x) > 1 else 0.0
    # POSITIVE CONTROL. ⚠ The obvious version -- splice two arbitrary moments
    # together -- is NOT a worst case: splicing two QUIET moments produced a
    # jump of 0.06 while ordinary audio in the same film reached 0.11, so the
    # control sat below the thing it was meant to bound and proved nothing.
    # This builds the real worst case for THIS material: the loudest window
    # against its own inversion, i.e. peak to inverted peak.
    loud = max((pcm(film, dur * f, 0.15) for f in (0.2, 0.35, 0.5, 0.65, 0.8)),
               key=lambda w: float(np.abs(w).max()) if len(w) else 0.0)
    if len(loud) < 100:
        return record("joins", BROKE, "could not read PCM for the control")
    ctrl = 2.0 * float(np.abs(loud).max())       # peak -> inverted peak
    ref = jump(pcm(film, dur * 0.5))             # ordinary audio
    worst, where = 0.0, None
    for j in joins:
        v = jump(pcm(film, max(0.0, j - 0.15)))
        if v > worst:
            worst, where = v, j
    if ctrl <= ref:
        return record("joins", BROKE,
                      f"control ({ctrl:.4f}) not above ordinary audio ({ref:.4f}); probe proves nothing")
    record("joins", OK if worst < ctrl else BAD,
           f"worst seam {worst:.4f} at t={where}s vs peak-to-inverted-peak control {ctrl:.4f}, ordinary {ref:.4f}")


def check_content(film, manifest, base):
    """Transcribe the film back and score each stage against its OWN line and a
    DIFFERENT one. Without the second number the first proves nothing."""
    try:
        import difflib, urllib.request, uuid
    except ImportError:
        return record("content", BROKE, "stdlib import failed")
    man = json.load(open(manifest))
    stages = [s for s in man["stages"] if s.get("narration")]
    dur0 = duration(film)
    # ⚠ THE CONTROL NEEDS ROOM. Each sample is a 12 s window; on a short film
    # those windows overlap so heavily that every window contains every stage,
    # and a stage scores identically against its own script and another's. That
    # is the control collapsing, not the film being wrong -- MEASURED 0.29 vs
    # 0.29 on a 27 s two-stage film that was in fact perfect. Refuse to score
    # rather than report a failure the film did not earn.
    if len(stages) < 3 or dur0 < 45:
        return record("content", BROKE,
                      f"{len(stages)} narrated stages over {dur0:.0f}s -- too few/short for the "
                      "cross-stage control to mean anything (need >=3 stages and >=45s)")

    def transcribe(path):
        b = uuid.uuid4().hex
        parts = []
        for n, v in (("model", "mlx-community--whisper-large-v3-turbo-asr-fp16"),
                     ("response_format", "json")):
            parts.append(f"--{b}\r\nContent-Disposition: form-data; name=\"{n}\"\r\n\r\n{v}\r\n".encode())
        parts.append((f"--{b}\r\nContent-Disposition: form-data; name=\"file\"; "
                      "filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n").encode()
                     + open(path, "rb").read() + b"\r\n")
        parts.append(f"--{b}--\r\n".encode())
        req = urllib.request.Request(f"{base}/v1/audio/transcriptions", data=b"".join(parts),
                                     headers={"Content-Type": f"multipart/form-data; boundary={b}"})
        with urllib.request.urlopen(req, timeout=900) as r:
            return json.loads(r.read()).get("text", "").strip()

    norm = lambda s: [w.strip(".,;:!?—-").lower() for w in s.split()]
    sim = lambda x, y: difflib.SequenceMatcher(None, norm(x), norm(y), autojunk=False).ratio()
    # ⚠ autojunk MUST be off and the comparison MUST be word-level. Character
    # level with autojunk on scored a VERBATIM take at 0.17.
    if sim("one two three four", "one two three four") != 1.0:
        return record("content", BROKE, "similarity metric fails its identity control")

    # ⚠ These windows are BLIND -- nothing here knows where a stage starts, so a
    # window routinely straddles two of them or lands on a music-only beat. That
    # costs absolute score: the same film that scores 0.76-0.91 when windows are
    # aligned to stage boundaries scores about 0.37 sampled this way. So the
    # verdict is the SEPARATION between own-script and other-script, not the
    # absolute number -- and both are always printed so a low pair with a good
    # ratio can be recognised for what it is.
    dur = duration(film)
    N = 6
    own, cross = [], []
    with tempfile.TemporaryDirectory() as tmp:
        for i in range(N):
            t = dur * (0.10 + 0.78 * i / (N - 1))
            w = os.path.join(tmp, f"s{i}.wav")
            run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-ss", str(round(t, 2)),
                 "-t", "12", "-i", film, "-ac", "1", "-ar", "16000", w, "-y"])
            try:
                txt = transcribe(w)
            except Exception as e:
                return record("content", BROKE, f"speech server unreachable at {base}: {e}")
            scored = sorted((sim(st["narration"], txt), j) for j, st in enumerate(stages))
            best, bj = scored[-1]
            # the control is the WORST-matching stage: if the film said nothing
            # from its script, best and worst would be equally poor.
            worst = scored[0][0]
            own.append(best)
            cross.append(worst)
    hi, lo = sum(own) / len(own), sum(cross) / len(cross)
    ratio = hi / lo if lo > 0 else float("inf")
    # Two criteria, and they catch different things. The FLOOR catches a film
    # whose narration is not this manifest at all (measured: a real film scored
    # against another film's manifest reaches only 0.15, while separation still
    # looks healthy at 7x -- so the ratio alone would have passed it). The RATIO
    # catches a film that matches every stage equally, which is what a window
    # full of music or babble looks like.
    floor_ok, ratio_ok = hi >= 0.25, ratio >= 2.0
    why = ("the film says its script" if floor_ok and ratio_ok else
           "; ".join(([] if floor_ok else [f"best match {hi:.2f} below the 0.25 floor -- "
                                           "this narration may not be this manifest"])
                     + ([] if ratio_ok else [f"separation {ratio:.1f}x below 2.0 -- "
                                             "matches every stage equally"])))
    record("content", OK if floor_ok and ratio_ok else BAD,
           f"best-matching stage {hi:.2f} vs worst-matching control {lo:.2f} "
           f"(separation {ratio:.1f}x over {N} blind windows) -- {why}")


def main():
    ap = argparse.ArgumentParser(description="Verify a finished film, with controls.")
    ap.add_argument("--film", required=True)
    ap.add_argument("--manifest", help="enables the transcribe-back content gate")
    ap.add_argument("--joins", help="comma-separated seconds where clips were concatenated")
    ap.add_argument("--target-lufs", type=float, default=None,
                    help="enforce an integrated-loudness target; omitted = report only")
    ap.add_argument("--tolerance", type=float, default=1.5)
    ap.add_argument("--base", default=os.environ.get("OMLX_BASE", "http://127.0.0.1:8000"))
    a = ap.parse_args()
    if not os.path.exists(a.film):
        sys.exit(f"no such film: {a.film}")

    print(f"verifying {a.film}\n")
    with tempfile.TemporaryDirectory() as tmp:
        check_streams(a.film, a.manifest)
        check_av_drift(a.film)
        check_distinct_frames(a.film, tmp)
        check_audio_present(a.film)
        check_loudness(a.film, a.target_lufs, a.tolerance)
        if a.joins:
            check_joins(a.film, [float(x) for x in a.joins.split(",")])
        if a.manifest:
            check_content(a.film, a.manifest, a.base.rstrip("/"))

    bad = [r for r in results if r[1] != OK]
    print()
    if not bad:
        print(f"ALL {len(results)} CHECKS PASSED")
        return 0
    print(f"{len(bad)} of {len(results)} checks did not pass:")
    for n, s, d in bad:
        print(f"  {s}  {n}: {d}")
    # BROKEN is not a failure of the film -- it is a failure of the probe, and
    # it must not be read as either a pass or a defect.
    return 1 if any(s == BAD for _, s, _ in bad) else 2


if __name__ == "__main__":
    sys.exit(main())
