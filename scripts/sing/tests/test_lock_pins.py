"""requirements.lock and pins.env: the lock is the spike's freeze VERBATIM, the pins parse the same way in python and
in install.sh's bash (which never sources the file), every pin install.sh reads exists, and the INSTALLED runtime holds
exactly the lock's packages and what the pins say (read from its files, never from a record). Standard library only.

The spike folder these were first measured from is being deleted (W8-SFIX, 2026-10-06). Before that, every runtime
file read here was measured byte-identical to the spike's (cut wav, NLTK zips, config.yaml, model.pt size, pyvenv.cfg,
HEAD, zh_prompt.mp3/.json), and the spike's logs/freeze-alt.txt hashed to LOCK_SHA256 again.
"""
import hashlib
import json
import os
import re
import subprocess
import unittest

from _util import INSTALL_SH, RUNTIME, SING, child_env, need_machine, sha256_path, temp_dir

from singlib import pins as spins
from singlib import wavio

LOCK = os.path.join(SING, "requirements.lock")
PINS = os.path.join(SING, "pins.env")
# The sha256 of the spike's logs/freeze-alt.txt (measured 2026-09-27; re-measured equal 2026-10-06, the day the spike
# was cleared away). The file is gone with the spike: this hash is the record that the lock IS that freeze.
LOCK_SHA256 = "1e00efc36fded73625063e395b9afb4f85d9c92baa5101dbd60ef9ab25233567"
RUNTIME_VENV_PY = os.path.join(RUNTIME, "venv", "bin", "python")
DESIGN_VERSIONS = {"torch": "2.11.0", "torchaudio": "2.11.0", "torchcodec": "0.11.1", "g2p-en": "2.1.0",
                   "nltk": "3.9.2", "librosa": "0.11.0", "soxr": "1.1.0", "transformers": "4.41.2",
                   "numpy": "1.26.4", "huggingface-hub": "0.36.2"}                  # design §2.5 step 3


def read_pins():
    with open(PINS, encoding="utf-8") as f:
        return spins.parse(f.read(), PINS)


def install_sh_text():
    with open(INSTALL_SH, encoding="utf-8") as f:
        return f.read()


def bash_parse(pins_path, keys):
    """install.sh's OWN pin reader (its PIN_RE line and load_pins function, cut from the script), run by bash 3.2."""
    text = install_sh_text()
    pin_re = re.search(r"^PIN_RE=.*$", text, re.M).group(0)
    body = re.search(r"^load_pins\(\) \{\n.*?^\}\n", text, re.M | re.S).group(0)
    script = "\n".join(['usage_fail() { echo "USAGE_FAIL $*" >&2; exit 2; }', 'PINS_FILE="$1"', pin_re, body,
                        "load_pins",
                        'for k in %s; do v="PIN_$k"; printf "%%s=%%s\\n" "$k" "${!v}"; done' % " ".join(keys)])
    return subprocess.run(["/bin/bash", "-c", script, "-", pins_path], capture_output=True, text=True, timeout=30)


class Lock(unittest.TestCase):
    def test_the_lock_is_the_spikes_freeze_verbatim(self):
        with open(LOCK, "rb") as f:
            data = f.read()
        self.assertEqual(hashlib.sha256(data).hexdigest(), LOCK_SHA256)
        self.assertEqual(len(data.decode().splitlines()), 83)

    def test_the_installed_runtime_holds_exactly_the_lock(self):
        need_machine(os.access(RUNTIME_VENV_PY, os.X_OK), "the installed runtime's venv python at %s" % RUNTIME_VENV_PY)
        code = ("import json, importlib.metadata as md\n"
                "print(json.dumps(sorted([d.metadata['Name'], d.version] for d in md.distributions())))")
        r = subprocess.run([RUNTIME_VENV_PY, "-I", "-B", "-c", code], env=child_env(), capture_output=True, text=True,
                           timeout=120)
        self.assertEqual(r.returncode, 0, r.stderr)
        norm = lambda n: re.sub(r"[-_.]+", "-", n).lower()
        have = {norm(n): v for n, v in json.loads(r.stdout)}
        with open(LOCK) as f:
            want = {norm(m.group(1)): m.group(2) for m in (re.match(r"^(\S+)==(\S+)$", x.strip()) for x in f) if m}
        self.assertEqual(len(want), 83)
        self.assertEqual(have, want)

    def test_every_line_is_an_exact_pin_and_the_designs_versions_hold(self):
        with open(LOCK) as f:
            lines = [x.strip() for x in f if x.strip()]
        pins = {}
        for line in lines:
            m = re.match(r"^([A-Za-z0-9_.\-]+)==([A-Za-z0-9_.+\-]+)$", line)
            self.assertIsNotNone(m, "not an exact pin: %r" % line)
            pins[m.group(1).lower().replace("_", "-")] = m.group(2)
        for name, version in DESIGN_VERSIONS.items():
            self.assertEqual(pins.get(name), version, name)
        for name in ("fastapi", "uvicorn"):
            self.assertNotIn(name, pins)                     # design §2.4: not in the measured lock


class Pins(unittest.TestCase):
    def test_every_line_has_the_narrow_format(self):
        with open(PINS, encoding="utf-8") as f:
            for n, raw in enumerate(f.read().splitlines(), 1):
                line = raw.strip()
                if line and not line.startswith("#"):
                    self.assertRegex(line, spins.LINE, "pins.env:%d" % n)

    def test_python_and_bash_read_the_same_values(self):
        p = read_pins()
        r = bash_parse(PINS, sorted(p))
        self.assertEqual(r.returncode, 0, r.stderr)
        got = dict(line.split("=", 1) for line in r.stdout.splitlines())
        self.assertEqual(got, p)
        self.assertEqual(got["VERIFY_IMPORTS"].split()[0], "torch")        # a quoted value with spaces

    def test_both_readers_refuse_what_could_execute(self):
        tmp = temp_dir("pins")
        for line in ('EVIL="$(date)"', "EVIL=`date`", 'EVIL=a\\b', "EVIL=a b", "lower=1", "EVIL='single'",
                     'EVIL="unterminated'):
            path = os.path.join(tmp, "bad.env")
            with open(path, "w") as f:
                f.write("GOOD=1\n%s\n" % line)
            with self.assertRaises(spins.PinsError, msg=line):
                spins.load(path)
            r = bash_parse(path, ["GOOD"])
            self.assertEqual(r.returncode, 2, (line, r.stdout, r.stderr))
            self.assertIn("USAGE_FAIL", r.stderr)
        with open(os.path.join(tmp, "dup.env"), "w") as f:
            f.write("A=1\nA=2\n")
        with self.assertRaises(spins.PinsError):
            spins.load(os.path.join(tmp, "dup.env"))

    def test_every_pin_install_sh_reads_exists(self):
        p = read_pins()
        text = install_sh_text()
        needed = set(re.findall(r"\bpin ([A-Z][A-Z0-9_]+)\b", text))
        block = re.search(r"^need_pins (.*?)(?<!\\)\n", text.replace("\\\n", " "), re.M).group(1)
        needed |= set(block.split())
        self.assertGreater(len(needed), 25)
        for k in sorted(needed):
            self.assertTrue(p.get(k), "pins.env lacks %s" % k)
        for pkg in p["NLTK_PACKAGES"].split():
            for k in ("NLTK_ZIP_" + pkg, "NLTK_SHA256_" + pkg):
                self.assertTrue(p.get(k), k)

    def test_the_pins_are_what_the_installed_runtime_holds(self):
        need_machine(os.path.isfile(os.path.join(RUNTIME, "install.json")), "the installed singing runtime at %s" % RUNTIME)
        p = read_pins()
        with open(os.path.join(RUNTIME, "venv", "pyvenv.cfg")) as f:
            cfg = dict(line.split(" = ", 1) for line in f.read().splitlines() if " = " in line)
        self.assertEqual(cfg["version_info"], p["PYTHON_VERSION"])
        self.assertEqual(cfg["uv"], p["UV_VERSION"])
        upstream = os.path.join(RUNTIME, "upstream")
        with open(os.path.join(upstream, ".git", "HEAD")) as f:         # read the file: never run git in the runtime
            self.assertEqual(f.read().strip(), p["UPSTREAM_COMMIT"])
        weights = os.path.join(RUNTIME, "weights")
        self.assertEqual(os.path.getsize(os.path.join(weights, p["MODEL_FILE"])), int(p["MODEL_BYTES"]))
        self.assertEqual(os.path.getsize(os.path.join(weights, p["CONFIG_FILE"])), int(p["CONFIG_BYTES"]))
        self.assertEqual(sha256_path(os.path.join(weights, p["CONFIG_FILE"])), p["CONFIG_SHA256"])
        voice = os.path.join(RUNTIME, "voices", p["BUILTIN_VOICE_ID"])
        cut = os.path.join(voice, "prompt.wav")                           # byte-identical to the spike's zh_prompt_cut.wav
        self.assertEqual(sha256_path(cut), p["BUILTIN_WAV_SHA256"])
        self.assertEqual(sha256_path(os.path.join(voice, "prompt.json")), p["BUILTIN_META_SHA256"])
        self.assertEqual(hashlib.sha256(wavio.data_chunk(cut)).hexdigest(), p["BUILTIN_PCM_SHA256"])
        info, _ = wavio.read_wav(cut)
        self.assertEqual((info["sample_rate"], info["frames"]), (48000, 497616))
        self.assertAlmostEqual(info["frames"] / 48000.0, float(p["BUILTIN_CUT_END"]) - float(p["BUILTIN_CUT_START"]),
                               places=3)
        self.assertEqual(sha256_path(os.path.join(upstream, p["BUILTIN_SOURCE_META"])), p["BUILTIN_META_SHA256"])
        for pkg in p["NLTK_PACKAGES"].split():
            z = os.path.join(RUNTIME, "nltk_data", p["NLTK_ZIP_" + pkg])
            self.assertEqual(sha256_path(z), p["NLTK_SHA256_" + pkg], pkg)

    def test_ffmpeg_libraries_are_where_the_pins_say(self):
        d = read_pins()["FFMPEG_LIB_DIR"]
        need_machine(os.path.isdir(d), "FFmpeg's libraries at %s" % d)
        self.assertTrue([n for n in os.listdir(d) if n.startswith("libavutil.") and n.endswith(".dylib")])


if __name__ == "__main__":
    unittest.main()
