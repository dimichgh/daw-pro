"""Shared helpers for scripts/sing/tests (standard library, Python 3.9 compatible).

Two groups of tests:
  * stdlib tests (test_*.py) run under the system /usr/bin/python3: schema, converter, WAV I/O, HTTP layer, stub,
    run.sh, install.sh against the fixture mirror, lock and pins;
  * venv tests (test_venv_*.py) need the singing runtime's packages (g2p_en, numpy, scipy, pyloudnorm). They skip
    when those are missing - unless SING_TESTS_REQUIRE_VENV=1, which turns every such skip into a FAILURE.
Likewise SING_TESTS_REQUIRE_MACHINE=1 turns a skip for a missing machine input (the spike's CPython and upstream
files the fixture mirror is built from, ffmpeg) into a failure. tests/run_all.sh sets both, one per pass, so a gate
can never pass by skipping.

Environment the venv tests read: NLTK_DATA (g2p_en's data), SING_TEST_UPSTREAM (a SoulX-Singer checkout, for
phone_set.json). SING_TEST_TMP picks where temp folders go (default: the system temp); every temp folder this
suite makes has a SPACE in its name, like "Application Support".
"""
import array
import contextlib
import hashlib
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request

TESTS = os.path.dirname(os.path.abspath(__file__))
SING = os.path.dirname(TESTS)
if SING not in sys.path:
    sys.path.insert(0, SING)
FIXTURES = os.path.join(TESTS, "fixtures")
SPIKE = os.path.expanduser("~/DAWPro-spikes/sing-soulx")
UPSTREAM = os.environ.get("SING_TEST_UPSTREAM") or os.path.join(SPIKE, "src", "SoulX-Singer")
REQUIRE_VENV = os.environ.get("SING_TESTS_REQUIRE_VENV") == "1"
REQUIRE_MACHINE = os.environ.get("SING_TESTS_REQUIRE_MACHINE") == "1"
SYSTEM_PY = "/usr/bin/python3"
RUN_SH = os.path.join(SING, "run.sh")
INSTALL_SH = os.path.join(SING, "install.sh")
STUB = os.path.join(SING, "stub_server.py")
SERVER = os.path.join(SING, "server.py")


def child_env(**extra):
    env = dict(os.environ)
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    env.update({k: v for k, v in extra.items() if v is not None})
    return env


def need(condition, why):
    """Skip unless `condition`; under SING_TESTS_REQUIRE_VENV=1 a missing venv requirement FAILS instead."""
    if condition:
        return
    if REQUIRE_VENV:
        raise AssertionError("required but missing: " + why)
    raise unittest.SkipTest(why)


def need_machine(condition, why):
    """Skip unless `condition`; under SING_TESTS_REQUIRE_MACHINE=1 a missing machine input FAILS instead."""
    if condition:
        return
    if REQUIRE_MACHINE:
        raise AssertionError("required but missing: " + why)
    raise unittest.SkipTest(why)


def have_modules(*names):
    import importlib
    for n in names:
        try:
            importlib.import_module(n)
        except Exception:
            return False
    return True


def temp_dir(label):
    base = os.environ.get("SING_TEST_TMP") or None
    if base:
        os.makedirs(base, exist_ok=True)
    return tempfile.mkdtemp(prefix="sing %s " % label, dir=base)


def sha256_bytes(b):
    return hashlib.sha256(b).hexdigest()


def sha256_path(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def listeners(port):
    """PIDs listening on TCP <port>, from lsof (the manager's own instrument). lsof exits 1 when it finds nothing;
    any other failure RAISES, so a broken probe can never read as "the port is free"."""
    r = subprocess.run(["/usr/sbin/lsof", "-w", "-nP", "-iTCP:%d" % port, "-sTCP:LISTEN", "-t"],
                       capture_output=True, text=True)
    if r.returncode not in (0, 1) or (r.returncode == 1 and r.stdout.strip()):
        raise AssertionError("lsof failed (exit %d): %s" % (r.returncode, r.stderr.strip()))
    return sorted(int(x) for x in r.stdout.split())


def lsof_lines(port):
    r = subprocess.run(["/usr/sbin/lsof", "-w", "-nP", "-iTCP:%d" % port, "-sTCP:LISTEN"],
                       capture_output=True, text=True)
    return r.stdout.strip()


def pid_alive(pid):
    r = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "pid="], capture_output=True, text=True)
    return r.stdout.strip() == str(pid)


def ps_field(pid, field):
    r = subprocess.run(["/bin/ps", "-p", str(pid), "-o", field + "="], capture_output=True, text=True)
    return r.stdout.strip()


def evidence(line):
    """A line for the test log (run_all.sh keeps it): the gate's lsof line, hashes, timings."""
    sys.stderr.write("\n    EVIDENCE %s\n" % line)
    sys.stderr.flush()


def http(method, port, path, body=None, timeout=60.0):
    """-> (status, json). Never raises on HTTP error statuses."""
    data = None
    headers = {}
    if body is not None:
        data = body if isinstance(body, bytes) else json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request("http://127.0.0.1:%d%s" % (port, path), data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, raw.decode("utf-8", "replace")


def wait_until(fn, timeout=20.0, step=0.1):
    t0 = time.time()
    while time.time() - t0 < timeout:
        v = fn()
        if v:
            return v
        time.sleep(step)
    return None


def health_status(port):
    try:
        st, h = http("GET", port, "/health", timeout=2)
        return h if st == 200 else None
    except (OSError, ValueError):
        return None


def wait_ready(port, timeout=30.0):
    return wait_until(lambda: (lambda h: h if h and h.get("status") == "ready" else None)(health_status(port)), timeout)


def read_log(path):
    try:
        with open(path, "r", errors="replace") as f:
            return f.read()
    except OSError:
        return "(no log at %s)" % path


def read_pidfile(path):
    """The pid in a pidfile, or None if it is missing, empty or not a number."""
    try:
        with open(path) as f:
            text = f.read().split()
        return int(text[0]) if text else None
    except (OSError, ValueError):
        return None


def stop_pid_exact(pid, proc=None, wait_s=10.0):
    """SIGTERM the pid (never by name), SIGKILL if it outlives wait_s; reap `proc` if we own it."""
    if pid and pid_alive(pid):
        os.kill(pid, 15)
    if proc is not None:
        try:
            proc.wait(timeout=wait_s)
        except subprocess.TimeoutExpired:
            if pid and pid_alive(pid):
                os.kill(pid, 9)
            proc.wait(timeout=wait_s)
    else:
        wait_until(lambda: not pid_alive(pid), wait_s)
        if pid_alive(pid):
            os.kill(pid, 9)


@contextlib.contextmanager
def stub_via_run_sh(runtime, port, roots, **stub_env):
    """Start the stub through run.sh (the product's launch path) and yield (pidfile pid, Popen, log path).

    run.sh writes its OWN pid ($$) and then execs, so the pidfile must come to name exactly the process we spawned:
    we wait for THAT (a stale pidfile left by a test is not mistaken for the new one). Always stopped pid-exact: the
    pid we spawned, which is the one the pidfile names."""
    log = os.path.join(runtime, "stub.log")
    env = child_env(SING_RUNTIME_DIR=runtime, SING_PORT=str(port), SING_USE_STUB="1",
                    SING_ALLOWED_ROOTS=os.pathsep.join(roots), SING_LOG_FILE=log)
    env.setdefault("SING_STUB_LOAD_S", "0.2")
    env.update({k: v for k, v in stub_env.items() if v is not None})
    os.makedirs(runtime, exist_ok=True)
    with open(log, "ab") as out:     # run.sh's own lines before the exec land in the same log as the server's
        proc = subprocess.Popen(["/bin/bash", RUN_SH], env=env, stdout=out, stderr=subprocess.STDOUT)
    pidfile = os.path.join(runtime, "run", "sing.pid")
    try:
        if not wait_until(lambda: read_pidfile(pidfile) == proc.pid or proc.poll() is not None, 10) \
                or proc.poll() is not None:
            raise AssertionError("run.sh exited %r before its pidfile named it; log:\n%s" % (proc.poll(), read_log(log)))
        if not wait_ready(port, 20):
            raise AssertionError("stub not ready; log:\n" + read_log(log))
        yield proc.pid, proc, log
    finally:
        stop_pid_exact(proc.pid, proc)


def start_stub_direct(runtime, port, host=None, log=None, **stub_env):
    """The stub without run.sh (for launch-refusal tests). Output goes to `log` when given (a long-running stub must
    never block on a full pipe), else to pipes for communicate(). The caller stops it with stop_pid_exact(p.pid, p)."""
    env = child_env(SING_RUNTIME_DIR=runtime, SING_PORT=str(port))
    env.update({k: v for k, v in stub_env.items() if v is not None})
    args = [SYSTEM_PY, STUB] + (["--host", host] if host else [])
    if log:
        with open(log, "ab") as f:
            return subprocess.Popen(args, env=env, stdout=f, stderr=subprocess.STDOUT)
    return subprocess.Popen(args, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def write_reference_wav(path, seconds=5.0, sr=48000, hz=220.0):
    """A float32 mono WAV (a quiet sine) to stand in for an own voice's recording in stub and schema tests."""
    import math
    from singlib import wavio
    n = int(seconds * sr)
    y = array.array("f", (0.05 * math.sin(2 * math.pi * hz * k / sr) for k in range(n)))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    wavio.write_float32_wav(path, y, sr)
    return sha256_path(path)


def own_voice(reference_path, sha, voice_id="0b7c9e7a-own-voice", window=(0.0, 5.0), offset=None):
    """A valid own-voice object (window-relative prompt notes on the words of the spike's T2)."""
    v = {"id": voice_id, "referencePath": reference_path, "referenceSha256": sha,
         "prompt": {"windowStartS": window[0], "windowEndS": window[1],
                    "notes": [{"startS": 0.24, "endS": 0.84, "midi": 57, "word": "hold", "continues": False},
                              {"startS": 0.84, "endS": 1.14, "midi": 59, "word": "me", "continues": False},
                              {"startS": 1.14, "endS": 1.44, "midi": 60, "word": "me", "continues": True},
                              {"startS": 2.04, "endS": 3.24, "midi": 62, "word": "now", "continues": False}]}}
    if offset is not None:
        v["promptLabelOffset"] = offset
    return v


# ----------------------------------------------------------------------------- the spike's fixtures (beats form)
SPB = 0.6    # 100 BPM
T1_NOTES = [(60, 0, 1), (60, 1, 1), (67, 2, 1), (67, 3, 1), (69, 4, 1), (69, 5, 1), (67, 6, 2),
            (65, 8, 1), (65, 9, 1), (64, 10, 1), (64, 11, 1), (62, 12, 1), (62, 13, 1), (60, 14, 2)]
T1_WORDS = [("Twinkle", [0, 1]), ("twinkle", [2, 3]), ("little", [4, 5]), ("star", [6]), ("how", [7]), ("I", [8]),
            ("wonder", [9, 10]), ("what", [11]), ("you", [12]), ("are", [13])]
T2_NOTES = [(64, 0, 1), (65, 1, 0.5), (67, 1.5, 0.5), (69, 2, 1), (67, 4, 2)]
T2_WORDS = [("hold", [0]), ("me", [1, 2, 3]), ("now", [4])]
T2_SEP_WORDS = [("hold", [0]), ("me", [1]), ("me", [2]), ("me", [3]), ("now", [4])]


def concat(parts):
    """The spike's concat(): (notes, words, beat_offset) parts -> merged notes/words."""
    notes, words = [], []
    for n_list, w_list, off in parts:
        base = len(notes)
        notes += [(p, s + off, l) for p, s, l in n_list]
        words += [(w, [i + base for i in idx]) for w, idx in w_list]
    return notes, words


def spike_cases():
    """name -> (notes in beats, words): exactly what the spike's fixtures() built for the three gate fixtures."""
    t1t2 = concat([(T1_NOTES, T1_WORDS, 0), (T2_NOTES, T2_WORDS, 16 + 100.0 / 60.0)])
    return {"T1": (T1_NOTES, T1_WORDS), "T2": (T2_NOTES, T2_WORDS), "T1T2": t1t2}


def all_spike_cases():
    """name -> (notes, words, build kwargs) for ALL EIGHT fixtures the spike's fixtures() built
    (`score_from_notes.py:95-107`)."""
    cases = {name: (n, w, {}) for name, (n, w) in spike_cases().items()}
    cases["T2-sep"] = (T2_NOTES, T2_SEP_WORDS, {})
    cases["T1-f0-110"] = (T1_NOTES, T1_WORDS, {"f0_const": 110.0})
    cases["T1-plus2"] = (T1_NOTES, T1_WORDS, {"pitch_offset": 2})
    for reps, name in ((3, "T3-30"), (6, "T3-60")):
        n, w = concat([(T1_NOTES, T1_WORDS, r * 17) for r in range(reps)])
        cases[name] = (n, w, {})
    return cases


def fixture_bytes(name):
    with open(os.path.join(FIXTURES, "spike", name + ".json"), "rb") as f:
        return f.read()


def phrase_request(notes_beats, words, output_path, voice=None, **over):
    """A facade request carrying the spike's notes as seconds (start = sb * 0.6, computed here as the spike did)."""
    req = {"facadeVersion": 1, "voice": voice or {"id": "builtin-1"},
           "phrase": {"notes": [{"startS": sb * SPB, "endS": (sb + lb) * SPB, "midi": p} for p, sb, lb in notes_beats],
                      "words": [{"text": t, "noteIndices": list(i)} for t, i in words]},
           "leadS": 0.24, "trailS": 0.24, "seed": 20260924, "nSteps": 32, "cfg": 3.0,
           "outputPath": output_path, "outputSampleRate": 48000}
    req.update(over)
    return req


# phonemes of every word in the spike's fixtures, as the spike's T1/T2 JSON carry them (the stdlib table phonemizer)
SPIKE_PHONEMES = {"twinkle": "T-W-IH1-NG-K-AH0-L", "little": "L-IH1-T-AH0-L", "star": "S-T-AA1-R", "how": "HH-AW1",
                  "i": "AY1", "wonder": "W-AH1-N-D-ER0", "what": "W-AH1-T", "you": "Y-UW1", "are": "AA1-R",
                  "hold": "HH-OW1-L-D", "me": "M-IY1", "now": "N-AW1"}


def table_phonemize(word):
    return SPIKE_PHONEMES[word.lower()].split("-")
