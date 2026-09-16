#!/usr/bin/env python3
"""Assemble ONE wordless music Short: song.json + music.wav -> a 9:16 film.

    python3 tunesmith.py DIR [--skip-build]

DIR holds song.py / song.json; everything lands in DIR/out.

WHY NOT shortsmith.py. shortsmith renders narration CARDS and drives the
narrate->transcribe->compare gate; a wordless short has no words, and its
`verify_cached` refuses to assemble without a take per stage. And assemble.py's
play beat runs a single-pass `loudnorm=I=-16` over the music, which would undo
the -14 LUFS the mix was steered to. So this is the same chain with the two
narration-shaped links removed and the SAME gates kept: brand.py's outro,
meter.py's corner meter, verify.py on the finished file, plus sync.py, which is
what a wordless film has instead of a content check.

⛔ NO BRAND INTRO, deliberately, and it is a departure from every other short in
this tree. The brief is "catchy in two seconds"; four seconds of title card is
the two seconds and then some. The brand lands on the outro instead.
"""
import argparse, json, os, subprocess, sys, re

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = "/Users/dsemenov/Views/daw-pro"
PLUGIN = f"{REPO}/plugins/narrated-film"
VENV = f"{PLUGIN}/.venv/bin/python"
BRANDJSON = f"{HERE}/brand.tunes.json"
W, H, FPS = 1080, 1920, 30


def run(cmd, **kw):
    p = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if p.returncode != 0:
        sys.exit(f"FAILED: {' '.join(str(c) for c in cmd[:6])}\n{p.stdout[-2000:]}\n{p.stderr[-3000:]}")
    return p.stdout


def dur(p):
    return float(run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                      "-of", "csv=p=0", p]).strip())


def true_peak(path):
    # ⚠ -v error SUPPRESSES the ebur128 summary, which logs at INFO.
    p = subprocess.run(["ffmpeg", "-hide_banner", "-i", path, "-af", "ebur128=peak=true",
                        "-f", "null", "-"], capture_output=True, text=True)
    m = re.findall(r"Peak:\s*(-?\d+\.?\d*)", p.stderr)
    return float(m[-1]) if m else None


def integrated(path):
    p = subprocess.run(["ffmpeg", "-hide_banner", "-i", path, "-af", "ebur128",
                        "-f", "null", "-"], capture_output=True, text=True)
    m = re.search(r"I:\s*(-?[\d.]+)\s*LUFS", p.stderr.split("Summary")[-1])
    return float(m.group(1)) if m else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--skip-build", action="store_true", help="reuse out/music.wav")
    ap.add_argument("--target", type=float, default=-14.0)
    ap.add_argument("--theme", default="tunes")
    # ⚠ ARGS, NOT A FORK. The roads series needs a different visualiser and a
    # different outro card; forking this file would leave two copies of the
    # true-peak backstop and the gate wiring to rot apart.
    ap.add_argument("--viz", default=f"{HERE}/viz.py")
    ap.add_argument("--brand", default=BRANDJSON)
    ap.add_argument("--viz-arg", action="append", default=[])
    ap.add_argument("--outro", type=float, default=2.4)
    a = ap.parse_args()
    D = os.path.abspath(a.dir)
    OUT = os.path.join(D, "out")
    os.makedirs(OUT, exist_ok=True)
    songp = os.path.join(D, "song.json")

    if not a.skip_build:
        run([sys.executable, os.path.join(D, "song.py")])
        env = dict(os.environ, DAW_CONTROL_PORT="17695")
        print(run(["node", f"{HERE}/build.mjs", songp, OUT], env=env), end="")
        print(run(["node", f"{HERE}/gain.mjs", songp, OUT, str(a.target)], env=env), end="")

    song = json.load(open(songp))
    wav = os.path.join(OUT, "music.wav")
    secs = dur(wav)
    report = {"id": song["id"], "musicSeconds": round(secs, 3)}

    # 1. picture, straight from viz.py's stdout — no PNG burst dir, so the frame
    #    count cannot silently disagree with the audio length.
    silent = os.path.join(OUT, "picture.mp4")
    nframes = int(round(secs * FPS))
    viz = subprocess.Popen([VENV, os.path.abspath(a.viz), songp,
                            "--seconds", f"{secs:.4f}"] + a.viz_arg,
                           stdout=subprocess.PIPE)
    ff = subprocess.Popen(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                           "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}",
                           "-r", str(FPS), "-i", "-", "-vf", "setsar=1", "-c:v", "libx264", "-preset", "medium",
                           "-crf", "19", "-pix_fmt", "yuv420p", "-r", str(FPS), silent],
                          stdin=viz.stdout)
    viz.stdout.close()
    if ff.wait() != 0 or viz.wait() != 0:
        sys.exit("viz|ffmpeg pipe failed")
    got = int(run(["ffprobe", "-v", "error", "-count_frames", "-select_streams", "v:0",
                   "-show_entries", "stream=nb_read_frames", "-of", "csv=p=0", silent]).strip().rstrip(","))
    if got != nframes:
        sys.exit(f"frame count {got} != round({secs:.3f}*{FPS}) = {nframes}")
    report["frames"] = got

    body = os.path.join(OUT, "body.mp4")

    # 2. the brand outro
    outro = os.path.join(OUT, "outro.mp4")
    run([VENV, f"{PLUGIN}/scripts/brand.py", "outro", "--brand", os.path.abspath(a.brand),
         "--theme", a.theme, "--size", f"{W}x{H}", "--seconds", str(a.outro), "--out", outro])
    film = os.path.join(OUT, f"{song['id']}.mp4")

    def assemble(trim_db):
        """Mux + concat at a given static trim. ⚠⚠ THE TRIM IS APPLIED HERE, TO
        THE ORIGINAL WAV, NOT TO THE FINISHED MP4. The first version re-encoded
        the finished file each pass and OSCILLATED: -0.80 dBTP, trim -0.20, then
        -0.90, trim -0.10, then -0.70 -- turning the audio DOWN made the
        measured true peak go UP, because every pass was a fresh lossy AAC
        encode of an already-lossy AAC encode and the codec's own inter-sample
        overshoot moved. Re-encoding once from the PCM source is monotonic and
        costs no generation loss."""
        af = "aresample=48000,aformat=channel_layouts=stereo"
        if abs(trim_db) > 1e-6:
            af = f"volume={trim_db:.2f}dB," + af
        run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", silent, "-i", wav,
             "-c:v", "copy", "-af", af, "-c:a", "aac", "-b:a", "192k", "-shortest", body])
        probe = lambda p, st: run(["ffprobe", "-v", "error", "-select_streams", st,
                                   "-show_entries",
                                   "stream=width,height,r_frame_rate,pix_fmt,sample_aspect_ratio"
                                   if st == "v:0" else "stream=codec_name,sample_rate,channels",
                                   "-of", "csv=p=0", p]).strip()
        for st in ("v:0", "a:0"):
            if probe(outro, st) != probe(body, st):
                sys.exit(f"outro stream mismatch ({st}): {probe(outro,st)} vs {probe(body,st)}")
        lst = os.path.join(OUT, "_concat.txt")
        open(lst, "w").write(f"file '{body}'\nfile '{outro}'\n")
        run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0",
             "-i", lst, "-c", "copy", film])
        return true_peak(film)

    # 3. TRUE-PEAK BACKSTOP. assemble.py owns one and this path bypasses it, so
    #    it is re-implemented rather than assumed away -- a static trim, never a
    #    limiter. The AAC encoder overshoots the PCM peak by a few tenths of a
    #    dB, which is why the DAW's own -1.20 dBTP render can still land over.
    trim, tp = 0.0, assemble(0.0)
    for _ in range(4):
        if tp is None or tp <= -1.0:
            break
        trim += (-1.05 - tp)
        was, tp = tp, assemble(trim)
        print(f"  true peak {was:+.2f} dBTP -> re-encode at {trim:+.2f} dB -> {tp:+.2f} dBTP")
    if tp is not None and tp > -0.95:
        sys.exit(f"true-peak trim would not converge: {tp:+.2f} dBTP")
    report["trimDb"] = round(trim, 2)

    # 4. the corner meter, BEFORE the gates, so they judge what ships
    nometer = os.path.join(OUT, f"{song['id']}-nometer.mp4")
    os.replace(film, nometer)
    run([VENV, f"{REPO}/scripts/video/meter.py", nometer, film,
         "--work", os.path.join(OUT, "seg"), "--corner", "br", "--start", "0", "--short"])

    report["duration"] = round(dur(film), 3)
    report["integratedLufs"] = integrated(film)
    report["truePeakDbtp"] = true_peak(film)
    print(f"\n  film {film}  {report['duration']:.1f}s  "
          f"{report['integratedLufs']} LUFS  {report['truePeakDbtp']} dBTP")
    if report["duration"] > 60:
        print(f"  ⚠ {report['duration']:.1f}s is OVER the 60 s Shorts ceiling")

    # 5. gates
    man = {"video": {"width": W, "height": H, "fps": FPS},
           "stages": [{"id": song["id"], "narration": "", "shots": []}]}
    manp = os.path.join(OUT, "manifest.json")
    json.dump(man, open(manp, "w"), indent=1)
    v = subprocess.run([VENV, f"{PLUGIN}/scripts/verify.py", "--film", film,
                        "--manifest", manp, "--joins", f"{dur(body):.3f}"],
                       capture_output=True, text=True)
    print(v.stdout)
    fails = [l.strip() for l in v.stdout.splitlines() if l.lstrip().startswith("[ FAIL ]")]
    broken = [l.strip() for l in v.stdout.splitlines() if l.lstrip().startswith("[BROKEN]")]
    # ⚠ ONE allowlisted BROKEN, and only this one: verify.py's content gate
    # needs >=3 NARRATED stages, and a wordless film has none at all. Every
    # other BROKEN means a probe could not judge, which is not a pass.
    allowed = [b for b in broken if "narrated stages" in b]
    broken = [b for b in broken if b not in allowed]

    print("  sync gate (this film's replacement for the content check):")
    sync_args = [VENV, f"{HERE}/sync.py", film, songp]
    if song.get("syncRoadOnly"):
        sync_args.append("--road-only")
    s = subprocess.run(sync_args, capture_output=True, text=True)
    print(s.stdout, end="")
    if s.returncode == 1:
        fails.append(s.stdout.strip().splitlines()[-1])
    elif s.returncode == 2:
        broken.append(s.stdout.strip().splitlines()[-1])

    report["verifyFails"], report["verifyBroken"] = fails, broken
    report["allowedBroken"] = allowed
    report["sync"] = s.stdout.strip().splitlines()[-1] if s.stdout else "no output"
    json.dump(report, open(os.path.join(OUT, "build-report.json"), "w"), indent=1)
    if fails or broken:
        sys.exit("REFUSING TO SHIP:\n  " + "\n  ".join(fails + broken))
    print(f"\nSHIPPED {film}")


if __name__ == "__main__":
    main()
