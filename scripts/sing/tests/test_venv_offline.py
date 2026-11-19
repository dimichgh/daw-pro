"""install.sh's venv check against the REAL g2p_en (runtime venv only; W8-SFIX, 2026-10-06).

The real install's check imported g2p_en before the nltk step had filled the runtime's nltk_data, and g2p_en's
import-time nltk.download() put 3.4 MB from raw.githubusercontent.com into the user's ~/nltk_data. Here, with HOME =
an empty temp folder and no NLTK_DATA (a clean Mac), under an audit hook that RECORDS every network attempt and every
file opened for writing:
  * tools/verify_venv.py with the real lock and pins.env's VERIFY_IMPORTS: exit 0, the @@venv-ok line, 0 network
    attempts, HOME still empty, and no write outside the test's own temp folder (the runtime is only read);
  * CONTROL: a plain `import g2p_en` under the same HOME, with a hook that REFUSES the network (no bytes flow), still
    reaches for raw.githubusercontent.com: the trap the check defuses is live in this venv, and the hook can see it.
Needs the venv the lock describes (tests/run_all.sh pass 2: the installed runtime's venv).
"""
import json
import os
import subprocess
import sys
import unittest

from _util import SING, child_env, evidence, have_modules, need, temp_dir

from singlib import pins as spins

TOOL = os.path.join(SING, "tools", "verify_venv.py")
LOCK = os.path.join(SING, "requirements.lock")
# Runs the script (or -c CODE) given after it under an audit hook. AUDIT_LOG gets the events as JSON;
# AUDIT_BLOCK_NET=1 refuses every network event instead of letting it through.
AUDIT = r'''
import json, os, runpy, sys
NET = {"socket.getaddrinfo", "socket.connect", "socket.gethostbyname", "socket.gethostbyname_ex",
       "socket.gethostbyaddr", "urllib.Request", "http.client.connect", "socket.sendto", "socket.sendmsg"}
FS = {"os.mkdir", "os.rename", "os.replace", "os.remove", "os.rmdir", "shutil.copyfile", "shutil.rmtree",
      "shutil.move", "os.symlink", "os.link", "os.truncate"}
WRITE = os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_APPEND
BLOCK = os.environ.get("AUDIT_BLOCK_NET") == "1"
events = []
def hook(ev, args):
    if ev in NET:
        events.append(["net", ev, repr(args)[:200]])
        if BLOCK:
            raise OSError("audit: network refused (%s)" % ev)
    elif ev == "open":
        path, mode, flags = (tuple(args) + (None, None, None))[:3]
        if (isinstance(mode, str) and any(c in mode for c in "wax+")) or \
           (not isinstance(mode, str) and isinstance(flags, int) and flags & WRITE):
            events.append(["write", ev, str(path)])
    elif ev in FS:
        events.append(["write", ev, str(args[0]) if args else ""])
sys.addaudithook(hook)
argv, rc = sys.argv[1:], 0
try:
    if argv[0] == "-c":
        sys.argv = ["-c"] + argv[2:]
        exec(compile(argv[1], "<audit>", "exec"), {"__name__": "__main__"})
    else:
        sys.argv = argv
        runpy.run_path(argv[0], run_name="__main__")
except SystemExit as e:
    rc = e.code if isinstance(e.code, int) else (0 if e.code is None else 1)
finally:
    data = json.dumps(events)
    with open(os.environ["AUDIT_LOG"], "w") as f:
        f.write(data)
sys.exit(rc)
'''


class RealVenvCheckIsOffline(unittest.TestCase):
    def setUp(self):
        need(have_modules("g2p_en", "nltk"), "g2p_en and nltk (the singing runtime's venv)")
        self.tmp = os.path.realpath(temp_dir("venv offline"))
        self.home = os.path.join(self.tmp, "home of the caller")
        os.makedirs(self.home)
        self.audit = os.path.join(self.tmp, "audit.py")
        with open(self.audit, "w") as f:
            f.write(AUDIT)

    def run_audited(self, args, block_net=False, timeout=300):
        log = os.path.join(self.tmp, "audit-%d.json" % len(os.listdir(self.tmp)))
        cache = os.path.join(self.tmp, "cache")
        env = child_env(HOME=self.home, TMPDIR=os.path.join(self.tmp, "tmp") + "/", AUDIT_LOG=log,
                        MPLCONFIGDIR=os.path.join(cache, "mpl"), NUMBA_CACHE_DIR=os.path.join(cache, "numba"),
                        XDG_CACHE_HOME=os.path.join(cache, "xdg"), TORCH_HOME=os.path.join(cache, "torch"),
                        HF_HOME=os.path.join(cache, "hf"), MODELSCOPE_CACHE=os.path.join(cache, "modelscope"),
                        HF_HUB_DISABLE_TELEMETRY="1", PYTHONNOUSERSITE="1", AUDIT_BLOCK_NET="1" if block_net else None)
        env.pop("NLTK_DATA", None)
        if not block_net:
            env.pop("AUDIT_BLOCK_NET", None)
        os.makedirs(env["TMPDIR"], exist_ok=True)
        r = subprocess.run([sys.executable, self.audit] + args, env=env, capture_output=True, text=True,
                           timeout=timeout)
        with open(log) as f:
            events = json.load(f)
        return r, [e for e in events if e[0] == "net"], [e for e in events if e[0] == "write"]

    def test_the_venv_check_makes_no_network_call_and_leaves_home_empty(self):
        imports = spins.load()["VERIFY_IMPORTS"]
        r, net, writes = self.run_audited([TOOL, "--lock", LOCK, "--python-version", sys.version.split()[0],
                                           "--prefix", sys.prefix, "--imports", imports])
        self.assertEqual(r.returncode, 0, r.stderr[-3000:])
        self.assertEqual(r.stdout, "@@venv-ok python %s, 83 pins, imports: %s\n" % (sys.version.split()[0], imports))
        self.assertEqual(net, [])
        self.assertEqual(os.listdir(self.home), [])
        self.assertEqual([w for w in writes if not w[2].startswith(self.tmp + "/")], [])
        self.assertIn("asked nltk to download", r.stderr)          # the import-time download WAS asked for, and refused
        evidence("real venv check: exit 0, 0 network attempts, HOME empty, %d writes all inside the test folder; "
                 "stderr: %s" % (len(writes), [x for x in r.stderr.splitlines() if "nltk" in x]))

    def test_control_a_plain_g2p_en_import_reaches_for_the_network(self):
        r, net, _ = self.run_audited(["-c", "import g2p_en"], block_net=True)
        self.assertEqual(r.returncode, 0, r.stderr[-3000:])
        self.assertTrue(net, "the CONTROL saw no network attempt: the hook is blind or the trap is gone\n" + r.stderr)
        self.assertTrue(any("raw.githubusercontent.com/nltk/nltk_data" in e[2] for e in net), net)
        self.assertEqual(os.listdir(self.home), [])                # refused before a byte arrived
        evidence("control: plain `import g2p_en` reached for the network %d times: %s" % (len(net), net[0][2][:120]))


if __name__ == "__main__":
    unittest.main()
