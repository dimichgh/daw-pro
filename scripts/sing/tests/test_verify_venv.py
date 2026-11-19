"""tools/verify_venv.py (install.sh's venv check) runs its imports OFFLINE and writes nothing into HOME (W8-SFIX,
2026-10-06: the real install's check imported g2p_en, whose import-time nltk.download() put 3.4 MB into the user's
~/nltk_data). Standard library only: the stand-ins in tests/fixture_pkgs/ (the fixture g2p_en repeats the real one's
import-time nltk.download() with no folder; the fixture nltk sends that to ~/nltk_data as a FIXTURE-LEAK file).
test_venv_offline.py repeats this against the REAL g2p_en in the installed runtime.

  a  the import-time download is recorded, not run: HOME stays empty, stderr names the packages, the @@venv-ok line
     keeps its shape. CONTROL: a plain `import g2p_en` under the same HOME does write ~/nltk_data, so the empty HOME
     above means something;
  b  an import that reaches for the network (and swallows the error, as nltk does) fails the check, naming the
     attempt. CONTROL: the same check without that import passes.
"""
import os
import subprocess
import sys
import unittest

from _util import SING, TESTS, child_env, evidence, temp_dir

TOOL = os.path.join(SING, "tools", "verify_venv.py")
PKGS = os.path.join(TESTS, "fixture_pkgs")
PY_VERSION = sys.version.split()[0]


class OfflineImports(unittest.TestCase):
    def setUp(self):
        self.tmp = temp_dir("verify venv")
        self.home = os.path.join(self.tmp, "home of the caller")
        os.makedirs(self.home)
        self.lock = os.path.join(self.tmp, "empty.lock")
        open(self.lock, "w").close()

    def env(self, *paths):
        e = child_env(HOME=self.home, PYTHONPATH=os.pathsep.join((PKGS,) + paths), SING_INSTALL_SOURCE=self.tmp)
        e.pop("NLTK_DATA", None)
        return e

    def verify(self, imports, *paths):
        return subprocess.run([sys.executable, TOOL, "--lock", self.lock, "--python-version", PY_VERSION,
                               "--prefix", sys.prefix, "--imports", imports], env=self.env(*paths),
                              capture_output=True, text=True, timeout=120)

    def test_a_g2p_ens_import_time_download_is_recorded_not_run(self):
        r = self.verify("g2p_en nltk")                        # g2p_en FIRST: it imports nltk itself
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, "@@venv-ok python %s, 0 pins, imports: g2p_en nltk\n" % PY_VERSION)
        self.assertIn("fixture g2p_en import: HOME=%s" % self.home, r.stderr)   # the trap really was imported
        self.assertIn("verify_venv: an import asked nltk to download averaged_perceptron_tagger, cmudict; nothing was "
                      "downloaded", r.stderr)
        self.assertEqual(os.listdir(self.home), [])
        control = subprocess.run([sys.executable, "-c", "import g2p_en"], env=self.env(), capture_output=True,
                                 text=True, timeout=60)
        self.assertEqual(control.returncode, 0, control.stderr)
        self.assertEqual(sorted(os.listdir(os.path.join(self.home, "nltk_data"))),
                         ["FIXTURE-LEAK-averaged_perceptron_tagger", "FIXTURE-LEAK-cmudict"])
        evidence("verify_venv: HOME empty after the check; the CONTROL import without it wrote %s/nltk_data" % self.home)

    def test_b_an_import_that_reaches_for_the_network_fails_the_check(self):
        mods = os.path.join(self.tmp, "modules")
        os.makedirs(mods)
        with open(os.path.join(mods, "reaches_for_the_network.py"), "w") as f:
            f.write("import socket\ntry:\n    socket.getaddrinfo('localhost', 80)\nexcept OSError:\n    pass\n")
        r = self.verify("nltk reaches_for_the_network", mods)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertNotIn("@@venv-ok", r.stdout)
        self.assertIn("verify_venv: an import reached for the network: socket.getaddrinfo", r.stderr)
        control = self.verify("nltk", mods)
        self.assertEqual(control.returncode, 0, control.stderr)
        self.assertEqual(os.listdir(self.home), [])


if __name__ == "__main__":
    unittest.main()
