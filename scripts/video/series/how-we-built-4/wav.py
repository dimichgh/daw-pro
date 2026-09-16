"""Read any wav ffmpeg can read as float64 mono + stereo. The comp/ files are
32-bit FLOAT, which python's `wave` refuses with `unknown format: 3` -- decode
through ffmpeg instead of guessing at the header."""
import subprocess, numpy as np


def read(path, sr=48000):
    """-> (sr, mono float64, stereo (n,2) float64)"""
    p = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", path,
                        "-f", "f32le", "-ac", "2", "-ar", str(sr), "-"],
                       capture_output=True)
    if p.returncode != 0:
        raise SystemExit(p.stderr.decode()[-800:])
    a = np.frombuffer(p.stdout, dtype="<f4").astype(np.float64).reshape(-1, 2)
    return sr, a.mean(axis=1), a


def db(x):
    return 20 * np.log10(np.sqrt(np.mean(np.square(x))) + 1e-12)


def env_db(x, sr, ms=50.0):
    w = int(sr * ms / 1000.0)
    k = len(x) // w
    return 20 * np.log10(np.sqrt((x[:k * w].reshape(k, w) ** 2).mean(axis=1)) + 1e-12), w
