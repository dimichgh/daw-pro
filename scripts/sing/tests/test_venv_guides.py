"""tools/make_guides.py: the two sing-along guides for Fixture P1 rebuild to the EXACT bytes SING-6 published (the
files the user recorded against), deterministically, and a detuned control does not (runtime venv only: numpy,
scipy, pyloudnorm).
"""
import os
import subprocess
import sys
import unittest

from _util import SING, child_env, evidence, have_modules, need, sha256_path, temp_dir

TOOL = os.path.join(SING, "tools", "make_guides.py")
PUBLISHED = {"row-guide-high.wav": "2b16520a3e7617789a8852e03ae45ba6fe15b53d00372d686f2a0c6c129535cb",
             "row-guide-low.wav": "05608e40c4a7e2344485f7dd31823ae70b4714761e75e96a9f2966f67953264c"}


def run(outdir, *args):
    return subprocess.run([sys.executable, TOOL, outdir] + list(args), env=child_env(), capture_output=True,
                          text=True, timeout=300)


class Guides(unittest.TestCase):
    def setUp(self):
        need(have_modules("numpy", "scipy", "pyloudnorm"), "numpy, scipy and pyloudnorm (the singing runtime's venv)")

    def test_both_guides_rebuild_to_the_published_bytes_twice(self):
        for n in (1, 2):
            out = temp_dir("guides %d" % n)
            r = run(out)
            self.assertEqual(r.returncode, 0, r.stderr)
            for name, sha in PUBLISHED.items():
                got = sha256_path(os.path.join(out, name))
                self.assertEqual(got, sha, "%s (run %d)" % (name, n))
                if n == 1:
                    evidence("%s sha256 %s == published" % (name, got))

    def test_a_detuned_control_differs(self):
        out = temp_dir("guides detuned")
        r = run(out, "--detune-cents", "5", "--only", "high", "--name", "detuned.wav")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotEqual(sha256_path(os.path.join(out, "detuned.wav")), PUBLISHED["row-guide-high.wav"])


if __name__ == "__main__":
    unittest.main()
