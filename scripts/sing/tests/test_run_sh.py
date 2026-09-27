"""run.sh, the launcher (design §2.6): the pid in <runtime>/run/sing.pid IS the process listening on the port (the
wrong-pid lesson), measured with lsof, the manager's own instrument. Also: a double start is refused, a stale pidfile
is cleared, SIGTERM removes the pidfile and frees the port, the environment the server gets is hermetic, and every
path it touches has a space in it ("Application Support").

The listener here is the stub (SING_USE_STUB=1, the same pidfile and exec); the real facade's launch through the SAME
script is the real-model smoke (tools/smoke_real_model.py, recorded in the lane's STATUS.md).
"""
import os
import subprocess
import unittest

from _util import (RUN_SH, SING, child_env, evidence, free_port, listeners, lsof_lines, pid_alive, ps_field,
                   read_pidfile, stop_pid_exact, stub_via_run_sh, temp_dir, wait_ready, wait_until)

FAKE_PYTHON = """#!/bin/bash
# test double for <runtime>/venv/bin/python: records what run.sh exec'd it with, then exits
OUT="$SING_RUNTIME_DIR/probe"
mkdir -p "$OUT"
echo "$$" > "$OUT/pid"
pwd -P > "$OUT/cwd"
/usr/bin/env > "$OUT/env"
printf '%s\\n' "$@" > "$OUT/args"
"""


class RunSh(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(temp_dir("run-sh"))
        self.runtime = os.path.join(self.tmp, "Application Support", "DAWPro", "SingingEngine")
        self.cache = os.path.join(self.tmp, "Application Support", "DAWPro", "SingingCache")
        os.makedirs(self.runtime)
        os.makedirs(self.cache)
        self.pidfile = os.path.join(self.runtime, "run", "sing.pid")
        self.port = free_port()

    def run_sh(self, **env):
        base = child_env(SING_RUNTIME_DIR=self.runtime, SING_PORT=str(self.port), SING_USE_STUB="1",
                         SING_ALLOWED_ROOTS=self.cache, SING_STUB_LOAD_S="0.2")
        for k, v in env.items():
            if v is None:
                base.pop(k, None)
            else:
                base[k] = v
        return base

    def test_the_pidfile_pid_is_the_listener(self):
        """THE GATE (design §9 p2-sing-b): run.sh's pidfile pid owns the port."""
        with stub_via_run_sh(self.runtime, self.port, [self.cache]) as (pid, proc, log):
            self.assertEqual(listeners(self.port), [pid])
            self.assertEqual(proc.pid, pid)                  # run.sh's own pid became the server: an exec, no child
            cmd = ps_field(pid, "command")
            self.assertIn("stub_server.py", cmd)
            self.assertNotIn("bash", ps_field(pid, "comm"))
            evidence("pidfile %s = %d" % (self.pidfile, pid))
            evidence("lsof -nP -iTCP:%d -sTCP:LISTEN ->\n%s" % (self.port, lsof_lines(self.port)))
            evidence("ps -p %d -o command= -> %s" % (pid, cmd))

    def test_a_double_start_is_refused(self):
        with stub_via_run_sh(self.runtime, self.port, [self.cache]) as (pid, proc, log):
            r = subprocess.run(["/bin/bash", RUN_SH], env=self.run_sh(SING_PORT=str(free_port())),
                               capture_output=True, text=True, timeout=30)
            self.assertEqual(r.returncode, 3, r.stderr)
            self.assertIn("already running (pid %d" % pid, r.stderr)
            self.assertEqual(read_pidfile(self.pidfile), pid)
            self.assertEqual(listeners(self.port), [pid])

    def test_a_stale_pidfile_of_a_dead_process_is_cleared(self):
        dead = subprocess.Popen(["/usr/bin/true"])
        dead.wait()
        self.assertFalse(pid_alive(dead.pid))
        os.makedirs(os.path.dirname(self.pidfile))
        with open(self.pidfile, "w") as f:
            f.write("%d\n" % dead.pid)
        with stub_via_run_sh(self.runtime, self.port, [self.cache]) as (pid, proc, log):
            self.assertNotEqual(pid, dead.pid)
            self.assertEqual(listeners(self.port), [pid])
            with open(log) as f:
                self.assertIn("clearing a stale pidfile", f.read())

    def test_a_stale_pidfile_naming_a_live_stranger_is_cleared_and_the_stranger_untouched(self):
        stranger = subprocess.Popen(["/bin/sleep", "60"])
        try:
            os.makedirs(os.path.dirname(self.pidfile))
            with open(self.pidfile, "w") as f:
                f.write("%d\n" % stranger.pid)
            with stub_via_run_sh(self.runtime, self.port, [self.cache]) as (pid, proc, log):
                self.assertEqual(listeners(self.port), [pid])
                self.assertTrue(pid_alive(stranger.pid))
        finally:
            stop_pid_exact(stranger.pid, stranger)

    def test_sigterm_removes_the_pidfile_and_frees_the_port(self):
        proc = subprocess.Popen(["/bin/bash", RUN_SH], env=self.run_sh(SING_LOG_FILE=os.path.join(self.tmp, "l.log")))
        try:
            pid = wait_until(lambda: read_pidfile(self.pidfile), 10)
            self.assertTrue(wait_ready(self.port, 20))
            self.assertEqual(listeners(self.port), [pid])    # positive control for the "free" check below
            os.kill(pid, 15)
            self.assertEqual(proc.wait(timeout=10), 0)
            self.assertFalse(os.path.exists(self.pidfile))
            self.assertEqual(listeners(self.port), [])
            self.assertFalse(pid_alive(pid))
        finally:
            stop_pid_exact(proc.pid, proc)

    def test_usage_refusals(self):
        r = subprocess.run(["/bin/bash", RUN_SH], env=self.run_sh(SING_RUNTIME_DIR=None), capture_output=True,
                           text=True, timeout=30)
        self.assertEqual(r.returncode, 2, r.stderr)
        r = subprocess.run(["/bin/bash", RUN_SH], env=self.run_sh(SING_RUNTIME_DIR=os.path.join(self.tmp, "missing")),
                           capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 2, r.stderr)
        r = subprocess.run(["/bin/bash", RUN_SH], env=self.run_sh(SING_USE_STUB=None), capture_output=True, text=True,
                           timeout=30)
        self.assertEqual(r.returncode, 4, r.stderr)
        self.assertIn("not installed", r.stderr)
        self.assertFalse(os.path.exists(self.pidfile))

    def test_the_real_path_execs_the_venv_python_with_a_hermetic_environment(self):
        py = os.path.join(self.runtime, "venv", "bin", "python")
        os.makedirs(os.path.dirname(py))
        with open(py, "w") as f:
            f.write(FAKE_PYTHON)
        os.chmod(py, 0o755)
        env = self.run_sh(SING_USE_STUB=None, SING_PORT=None, PYTHONPATH="/bogus/site", PYTHONHOME="/bogus/home",
                          PYTORCH_ENABLE_MPS_FALLBACK="1", HF_HUB_OFFLINE="0", HF_HOME="/Users/shared-cache")
        r = subprocess.run(["/bin/bash", RUN_SH], env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0, r.stderr)
        probe = os.path.join(self.runtime, "probe")

        def read(name):
            with open(os.path.join(probe, name)) as f:
                return f.read()
        self.assertEqual(int(read("pid")), read_pidfile(self.pidfile))
        self.assertEqual(read("cwd").strip(), self.runtime)
        self.assertEqual(read("args").splitlines(), [os.path.join(SING, "server.py")])
        got = dict(line.split("=", 1) for line in read("env").splitlines() if "=" in line)
        for k in ("PYTHONPATH", "PYTHONHOME", "PYTORCH_ENABLE_MPS_FALLBACK"):
            self.assertNotIn(k, got)
        want = {"HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1",
                "PYTHONNOUSERSITE": "1", "PYTHONUNBUFFERED": "1", "SING_PORT": "8004",
                "SING_RUNTIME_DIR": self.runtime, "NLTK_DATA": os.path.join(self.runtime, "nltk_data"),
                "HF_HOME": os.path.join(self.runtime, "cache", "hf")}
        for k in ("TORCH_HOME", "XDG_CACHE_HOME", "MODELSCOPE_CACHE", "MPLCONFIGDIR", "NUMBA_CACHE_DIR"):
            self.assertTrue(got[k].startswith(os.path.join(self.runtime, "cache") + "/"), (k, got[k]))
        for k, v in want.items():
            self.assertEqual(got.get(k), v, k)


if __name__ == "__main__":
    unittest.main()
