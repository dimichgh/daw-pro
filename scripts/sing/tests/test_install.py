"""install.sh against the LOCAL FIXTURE MIRROR (tests/fixture_mirror.py; SING_INSTALL_SOURCE + SING_PINS_FILE, tests
only). Nothing here touches the network: every download is file:// from the mirror, uv runs offline.

Every runtime and the mirror itself live under paths WITH SPACES ("App Support"), like the real
~/Library/Application Support/DAWPro/SingingEngine (design §8 F14).

  a  a full install, then a re-run that skips every step and changes nothing (the idempotency gate);
  b  a cancel mid-download: exit 143, "@@cancelled weights" only after staging is gone, the download's whole process
     group gone, nothing that looks installed; a second install meanwhile is refused (75); a re-run completes,
     skipping what already verified;
  c  a built-in voice that rebuilds to different bytes fails LOUDLY, says whether only the header or the samples
     differ, and leaves nothing that looks installed; a re-run with the right pins recovers;
  d  --adopt-weights clones a matching model.pt instead of downloading, and downloads instead of adopting a wrong one;
  e  preflight refuses a disk without room before changing anything;
  f  usage refusals (the test variables go in pairs; a pins line that could execute is refused).
"""
import json
import os
import shutil
import signal
import subprocess
import threading
import time
import unittest

from _util import INSTALL_SH, child_env, evidence, need_machine, sha256_path, temp_dir, wait_until

import fixture_mirror
from singlib import pins as spins

STEPS = ("preflight", "uv", "python", "venv", "upstream", "weights", "nltk", "voice", "finish")
REAL_PINS = spins.load(os.path.join(fixture_mirror.SING, "pins.env"))


def at_lines(text):
    return [line for line in text.splitlines() if line.startswith("@@")]


def processes_mentioning(text):
    r = subprocess.run(["/bin/ps", "-Ao", "pid,command"], capture_output=True, text=True, check=True)
    return [line.strip() for line in r.stdout.splitlines()[1:] if text in line and "/bin/ps" not in line]


def ffmpeg_present():
    return any(os.access(p, os.X_OK) for p in [shutil.which("ffmpeg") or "", "/opt/homebrew/bin/ffmpeg",
                                                   "/usr/local/bin/ffmpeg"] if p)


class Installer(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        missing = fixture_mirror.missing_inputs()
        need_machine(not missing, "the fixture mirror's inputs: %s" % ", ".join(missing))
        need_machine(ffmpeg_present(), "ffmpeg (install.sh cuts the built-in voice with it)")
        cls.tmp = os.path.realpath(temp_dir("install"))
        t0 = time.time()
        built = fixture_mirror.build(os.path.join(cls.tmp, "fixture mirror"), os.path.join(cls.tmp, "mirror work"))
        cls.mirror, cls.pins, cls.lock, cls.facts = built["mirror"], built["pins"], built["lock"], built["facts"]
        with open(cls.pins) as f:
            cls.fixture_pins = spins.parse(f.read())
        evidence("fixture mirror built in %.1f s at %s" % (time.time() - t0, cls.mirror))
        cls.rt_a = cls.runtime("A")
        cls.first = cls.install(cls.rt_a)

    @classmethod
    def runtime(cls, tag):
        return os.path.join(cls.tmp, "runtime %s" % tag, "App Support", "DAWPro", "SingingEngine")

    @classmethod
    def env(cls, runtime, pins=None, **extra):
        e = child_env(SING_RUNTIME_DIR=runtime, SING_INSTALL_SOURCE=cls.mirror, SING_PINS_FILE=pins or cls.pins)
        e.pop("SING_FIXTURE_THROTTLE_S", None)
        for k, v in extra.items():
            if v is None:
                e.pop(k, None)
            else:
                e[k] = v
        return e

    @classmethod
    def install(cls, runtime, pins=None, args=(), timeout=900, **extra):
        t0 = time.time()
        r = subprocess.run(["/bin/bash", INSTALL_SH] + list(args), env=cls.env(runtime, pins, **extra),
                           capture_output=True, text=True, timeout=timeout)
        r.seconds = time.time() - t0
        return r

    def pins_with(self, **over):
        path = os.path.join(self.tmp, "pins-%s.env" % "-".join(sorted(over)))
        with open(path, "w") as f:
            for k, v in self.fixture_pins.items():
                v = over.get(k, v)
                f.write('%s="%s"\n' % (k, v) if " " in v else "%s=%s\n" % (k, v))
        return path

    def assertInstalled(self, rt):
        with open(os.path.join(rt, "install.json")) as f:
            m = json.load(f)
        self.assertEqual(m["source"], "fixture")
        self.assertEqual(m["builtinSha256"], REAL_PINS["BUILTIN_WAV_SHA256"])
        self.assertEqual(sha256_path(os.path.join(rt, "voices", "builtin-1", "prompt.wav")),
                         REAL_PINS["BUILTIN_WAV_SHA256"])
        self.assertEqual(sha256_path(os.path.join(rt, "voices", "builtin-1", "prompt.json")),
                         REAL_PINS["BUILTIN_META_SHA256"])
        self.assertEqual(sha256_path(os.path.join(rt, "weights", "model.pt")), self.facts["model_sha256"])
        self.assertEqual([n for n in os.listdir(rt) if n.startswith(".staging-") or n == ".install.lock"], [])
        return m

    def assertNothingLooksInstalled(self, rt):
        self.assertFalse(os.path.exists(os.path.join(rt, "install.json")))
        self.assertEqual([n for n in os.listdir(rt) if n.startswith(".staging-") or n == ".install.lock"], [])

    # ------------------------------------------------------------------------------------------------ a
    def test_a_full_install_then_a_rerun_that_skips_everything_and_changes_nothing(self):
        r = self.first
        self.assertEqual(r.returncode, 0, r.stderr[-4000:])
        at = at_lines(r.stdout)
        self.assertEqual([x for x in at if x.startswith("@@step ")],
                         ["@@step %s %d/9" % (n, i + 1) for i, n in enumerate(STEPS)])
        self.assertEqual([x for x in at if x.startswith("@@skip ")], [])
        self.assertTrue(any(x.startswith("@@free ") for x in at))
        self.assertTrue(any(x.startswith("@@bytes ") for x in at))
        done = int(at[-1].split()[1])
        self.assertTrue(at[-1].startswith("@@done "))
        m = self.assertInstalled(self.rt_a)
        want = {"facadeVersion": 1, "scriptsVersion": 1, "lockSha256": sha256_path(self.lock),
                "pinsSha256": sha256_path(self.pins), "commit": self.facts["commit"],
                "weightsRevision": REAL_PINS["WEIGHTS_REVISION"], "weightsSha256": self.facts["model_sha256"],
                "weightsBytes": 3 << 20, "builtinVoiceId": "builtin-1", "pythonVersion": "3.10.20",
                "uvVersion": "0.11.19", "installedBytes": done}
        for k, v in want.items():
            self.assertEqual(m[k], v, k)
        self.assertEqual(m["weightsInode"], os.stat(os.path.join(self.rt_a, "weights", "model.pt")).st_ino)
        evidence("first install: exit 0 in %.1f s, @@done %d, runtime %r" % (r.seconds, done, self.rt_a))

        watched = ("install.json", "weights/model.pt", "weights/config.yaml", "venv/bin/python", "bin/uv",
                   "voices/builtin-1/prompt.wav", "nltk_data/corpora/cmudict.zip", "upstream/.git/HEAD", ".stamps")
        def state():
            return {p: (os.lstat(os.path.join(self.rt_a, p)).st_ino, os.lstat(os.path.join(self.rt_a, p)).st_mtime_ns)
                    for p in watched}
        with open(os.path.join(self.rt_a, "install.json"), "rb") as f:
            marker_before = f.read()
        before = state()
        r2 = self.install(self.rt_a)
        self.assertEqual(r2.returncode, 0, r2.stderr[-4000:])
        at2 = at_lines(r2.stdout)
        self.assertEqual([x for x in at2 if x.startswith("@@skip ")], ["@@skip %s" % n for n in STEPS[1:]])
        self.assertEqual(at2[-1], "@@done %d" % done)
        self.assertEqual(state(), before)
        with open(os.path.join(self.rt_a, "install.json"), "rb") as f:
            self.assertEqual(f.read(), marker_before)
        self.assertInstalled(self.rt_a)
        evidence("re-run: exit 0 in %.1f s, 8/8 steps @@skip, 9 watched paths keep inode+mtime, marker bytes equal"
                 % r2.seconds)

    # ------------------------------------------------------------------------------------------------ b
    def test_b_cancel_mid_download_then_a_rerun_completes(self):
        rt = self.runtime("B")
        lines, err_path = [], os.path.join(self.tmp, "cancel.stderr")
        with open(err_path, "w") as err:
            p = subprocess.Popen(["/bin/bash", INSTALL_SH], env=self.env(rt, SING_FIXTURE_THROTTLE_S="1.5"),
                                 stdout=subprocess.PIPE, stderr=err, text=True, bufsize=1)
        reader = threading.Thread(target=lambda: [lines.append(x.rstrip("\n")) for x in p.stdout], daemon=True)
        reader.start()
        try:
            got = wait_until(lambda: "@@step weights 6/9" in lines and any(x.startswith("@@bytes ") for x in lines),
                             300, step=0.1)
            self.assertTrue(got, "never reached the weights download: %r" % lines[-5:])
            busy = self.install(rt)                                            # a second install meanwhile
            self.assertEqual(busy.returncode, 75, busy.stderr)
            self.assertIn("@@error preflight another install is running (pid %d)" % p.pid, busy.stdout)
            kids = processes_mentioning(rt)
            self.assertTrue(any("hf_fetch.py" in k for k in kids), kids)      # the positive control for "gone"
            p.send_signal(signal.SIGTERM)
            self.assertEqual(p.wait(timeout=60), 143)
        finally:
            if p.poll() is None:
                p.kill()
                p.wait()
        reader.join(10)
        p.stdout.close()
        self.assertEqual(lines[-1], "@@cancelled weights")
        self.assertNothingLooksInstalled(rt)
        self.assertEqual(processes_mentioning(rt), [])
        evidence("cancel: exit 143, last line %r, 0 staging, no marker, no process mentions the runtime (before: %d)"
                 % (lines[-1], len(kids)))
        r = self.install(rt)
        self.assertEqual(r.returncode, 0, r.stderr[-4000:])
        at = at_lines(r.stdout)
        self.assertEqual([x for x in at if x.startswith("@@skip ")],
                         ["@@skip uv", "@@skip python", "@@skip venv", "@@skip upstream"])
        self.assertInstalled(rt)
        evidence("re-run after cancel: exit 0 in %.1f s, skipped uv/python/venv/upstream" % r.seconds)

    # ------------------------------------------------------------------------------------------------ c
    def test_c_a_builtin_voice_that_rebuilds_differently_fails_loudly(self):
        rt = self.rt_a
        self.assertInstalled(rt)
        r = self.install(rt, self.pins_with(BUILTIN_WAV_SHA256="0" * 64))
        self.assertEqual(r.returncode, 1, r.stderr[-3000:])
        err = [x for x in at_lines(r.stdout) if x.startswith("@@error ")]
        self.assertEqual(len(err), 1)
        self.assertTrue(err[0].startswith("@@error voice "), err[0])
        self.assertIn("only the file header differs", err[0])
        self.assertIn(REAL_PINS["BUILTIN_WAV_SHA256"], err[0])
        self.assertNothingLooksInstalled(rt)
        r = self.install(rt, self.pins_with(BUILTIN_WAV_SHA256="0" * 64, BUILTIN_PCM_SHA256="1" * 64))
        self.assertEqual(r.returncode, 1)
        self.assertIn("the audio samples differ too", r.stdout)
        r = self.install(rt)
        self.assertEqual(r.returncode, 0, r.stderr[-3000:])
        self.assertIn("@@skip voice", r.stdout)
        self.assertInstalled(rt)

    # ------------------------------------------------------------------------------------------------ d
    def test_d_adopt_weights(self):
        rt = self.rt_a
        src = os.path.join(self.mirror, "hf", REAL_PINS["WEIGHTS_REPO"], REAL_PINS["WEIGHTS_REVISION"], "model.pt")
        shutil.rmtree(os.path.join(rt, "weights"))
        r = self.install(rt, args=["--adopt-weights", src])
        self.assertEqual(r.returncode, 0, r.stderr[-3000:])
        self.assertIn("adopted %s (APFS clone)" % src, r.stderr)
        self.assertNotIn("@@bytes", r.stdout)                               # nothing was downloaded
        self.assertInstalled(rt)
        shutil.rmtree(os.path.join(rt, "weights"))
        wrong = os.path.join(self.mirror, "hf", REAL_PINS["WEIGHTS_REPO"], REAL_PINS["WEIGHTS_REVISION"],
                             "config.yaml")
        r = self.install(rt, args=["--adopt-weights", wrong])
        self.assertEqual(r.returncode, 0, r.stderr[-3000:])
        self.assertIn("does not match the pinned size and sha256; downloading instead", r.stderr)
        self.assertIn("@@bytes", r.stdout)
        self.assertInstalled(rt)

    # ------------------------------------------------------------------------------------------------ e
    def test_e_preflight_refuses_a_disk_without_room(self):
        rt = self.runtime("E")
        r = self.install(rt, self.pins_with(MIN_FREE_KB="999999999999"))
        self.assertEqual(r.returncode, 1)
        at = at_lines(r.stdout)
        self.assertTrue(at[1].startswith("@@free "), at)
        self.assertTrue(at[-1].startswith("@@error preflight only "), at)
        self.assertEqual(os.listdir(rt), [])

    # ------------------------------------------------------------------------------------------------ f
    def test_f_usage_refusals(self):
        rt = self.runtime("F")
        for extra in ({"SING_PINS_FILE": None}, {"SING_INSTALL_SOURCE": None}, {"SING_RUNTIME_DIR": None},
                      {"SING_RUNTIME_DIR": "relative/SingingEngine"}):
            r = subprocess.run(["/bin/bash", INSTALL_SH], env=self.env(rt, **extra), capture_output=True, text=True,
                               timeout=60)
            self.assertEqual(r.returncode, 2, (extra, r.stderr))
            self.assertNotIn("@@step", r.stdout)
        r = subprocess.run(["/bin/bash", INSTALL_SH, "--frobnicate"], env=self.env(rt), capture_output=True, text=True,
                           timeout=60)
        self.assertEqual(r.returncode, 2)
        bad = os.path.join(self.tmp, "pins-bad.env")
        executed = os.path.join(self.tmp, "pins line executed")
        with open(self.pins) as f, open(bad, "w") as g:
            g.write(f.read() + "EVIL=\"$(touch '%s')\"\n" % executed)
        r = self.install(rt, bad)
        self.assertEqual(r.returncode, 2)
        self.assertIn("is not KEY=value", r.stderr)
        self.assertFalse(os.path.exists(executed))
        r = subprocess.run(["/bin/bash", "-c", 'source "$1"', "-", bad], capture_output=True, timeout=60)
        self.assertTrue(os.path.exists(executed), "control: SOURCING that pins file would have run the command")
        self.assertFalse(os.path.exists(rt))


if __name__ == "__main__":
    unittest.main()
