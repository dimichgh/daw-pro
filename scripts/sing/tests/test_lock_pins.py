"""requirements.lock and pins.env: the lock is the spike's freeze VERBATIM, the pins parse the same way in python and
in install.sh's bash (which never sources the file), every pin install.sh reads exists, and the pins equal what the
spike measured on this Mac (read from the spike's files, never from a record). Standard library only.
"""
import hashlib
import os
import re
import subprocess
import unittest

from _util import INSTALL_SH, SING, SPIKE, UPSTREAM, need_machine, sha256_path, temp_dir

from singlib import pins as spins
from singlib import wavio

LOCK = os.path.join(SING, "requirements.lock")
PINS = os.path.join(SING, "pins.env")
LOCK_SHA256 = "1e00efc36fded73625063e395b9afb4f85d9c92baa5101dbd60ef9ab25233567"
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
        freeze = os.path.join(SPIKE, "logs", "freeze-alt.txt")
        need_machine(os.path.isfile(freeze), "the spike's %s" % freeze)
        with open(freeze, "rb") as f:
            self.assertEqual(f.read(), data)

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

    def test_the_pins_are_what_the_spike_measured(self):
        need_machine(os.path.isdir(SPIKE), "the spike at %s" % SPIKE)
        p = read_pins()
        with open(os.path.join(SPIKE, "venv-alt", "pyvenv.cfg")) as f:
            cfg = dict(line.split(" = ", 1) for line in f.read().splitlines() if " = " in line)
        self.assertEqual(cfg["version_info"], p["PYTHON_VERSION"])
        self.assertEqual(cfg["uv"], p["UV_VERSION"])
        with open(os.path.join(UPSTREAM, ".git", "HEAD")) as f:              # read the file: never run git in the spike
            self.assertEqual(f.read().strip(), p["UPSTREAM_COMMIT"])
        weights = os.path.join(UPSTREAM, "pretrained_models", "SoulX-Singer")
        self.assertEqual(os.path.getsize(os.path.join(weights, "model.pt")), int(p["MODEL_BYTES"]))
        self.assertEqual(os.path.getsize(os.path.join(weights, "config.yaml")), int(p["CONFIG_BYTES"]))
        self.assertEqual(sha256_path(os.path.join(weights, "config.yaml")), p["CONFIG_SHA256"])
        cut = os.path.join(SPIKE, "fixtures", "zh_prompt_cut.wav")
        self.assertEqual(sha256_path(cut), p["BUILTIN_WAV_SHA256"])
        self.assertEqual(hashlib.sha256(wavio.data_chunk(cut)).hexdigest(), p["BUILTIN_PCM_SHA256"])
        info, _ = wavio.read_wav(cut)
        self.assertEqual((info["sample_rate"], info["frames"]), (48000, 497616))
        self.assertAlmostEqual(info["frames"] / 48000.0, float(p["BUILTIN_CUT_END"]) - float(p["BUILTIN_CUT_START"]),
                               places=3)
        self.assertEqual(sha256_path(os.path.join(UPSTREAM, p["BUILTIN_SOURCE_META"])), p["BUILTIN_META_SHA256"])
        for pkg in p["NLTK_PACKAGES"].split():
            z = os.path.join(SPIKE, "cache", "nltk", p["NLTK_ZIP_" + pkg])
            self.assertEqual(sha256_path(z), p["NLTK_SHA256_" + pkg], pkg)

    def test_ffmpeg_libraries_are_where_the_pins_say(self):
        d = read_pins()["FFMPEG_LIB_DIR"]
        need_machine(os.path.isdir(d), "FFmpeg's libraries at %s" % d)
        self.assertTrue([n for n in os.listdir(d) if n.startswith("libavutil.") and n.endswith(".dylib")])


if __name__ == "__main__":
    unittest.main()
