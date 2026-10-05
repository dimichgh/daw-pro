"""DAW Pro singing sidecar: the standard-library HTTP facade over SoulX-Singer (design
docs/design/2026-09-27-p2-sing-integration.md §2.4, item p2-sing-b).

  GET  /health           {status: loading|ready|error, facadeVersion: 1, engine: {commit, weightsRevision,
                          weightsBytes}, device: "mps", pid, loadSeconds, mpsDriverBytes, rendered, error?}
  POST /v1/sing/phrase   renders ONE unit synchronously, writes a float32 WAV, returns its facts
                         (schema: singlib/schema.py; refusals: singlib/refusals.py)

It binds 127.0.0.1 and refuses any other host. The socket opens BEFORE the model loads (eagerly, in a background
thread), so /health answers "loading" and a render gets 503 until the model is ready: "ready" means ready.
There is no shutdown endpoint: stopping is pid-exact, from the manager. SIGTERM/SIGINT exit at once and remove
the pidfile only if it still names this process.

Launch it through run.sh (which execs the venv python, so the pidfile's pid IS this listener). Environment:
  SING_RUNTIME_DIR    required: the SingingEngine directory (design §2.3)
  SING_PORT           default 8004 (staging and tests use 18004)
  SING_HOST           default 127.0.0.1; any other value is refused (exit 2)
  SING_ALLOWED_ROOTS  ':'-separated folders the facade may read voices from and write WAVs into (the app passes
                      SingingVoices and SingingCache); <runtime>/voices is always added. Checked on the realpath.
  SING_TEST_HOOKS=1   tests only: accept "testPromptF0" (the §7.6 prompt-f0 null test). Set by whoever launches
                      the process; there is no way to set it over the wire.
"""
import argparse
import os
import signal
import sys
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

from singlib import http as shttp  # noqa: E402
from singlib import pins as spins  # noqa: E402
from singlib import schema  # noqa: E402


def remove_own_pidfile(pidfile):
    """Remove the pidfile only if it still names THIS process."""
    try:
        with open(pidfile) as f:
            if f.readline().strip() == str(os.getpid()):
                os.remove(pidfile)
    except OSError:
        pass


def _exit_on_signal(pidfile):
    def handler(signum, frame):
        remove_own_pidfile(pidfile)
        os._exit(0)
    return handler


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--host", default=os.environ.get("SING_HOST", shttp.LOOPBACK))
    ap.add_argument("--port", type=int, default=int(os.environ.get("SING_PORT", "8004")))
    ap.add_argument("--runtime", default=os.environ.get("SING_RUNTIME_DIR"))
    a = ap.parse_args(argv)
    shttp.check_host(a.host)          # before anything else, including the heavy imports
    if not a.runtime or not os.path.isdir(a.runtime):
        sys.stderr.write("sing: SING_RUNTIME_DIR must name the installed engine's folder (got %r).\n" % a.runtime)
        return 2
    runtime = os.path.realpath(a.runtime)
    pins = spins.load()
    voices_dir = os.path.join(runtime, "voices")
    roots = schema.roots_from_env(os.environ.get("SING_ALLOWED_ROOTS"), always=[voices_dir])
    test_hooks = os.environ.get("SING_TEST_HOOKS") == "1"

    from singlib.engine import SoulXBackend
    backend = SoulXBackend(runtime, pins, device="mps")
    pidfile = os.path.join(runtime, "run", "sing.pid")
    try:
        server = shttp.make_server(a.port, backend, roots, voices_dir, test_hooks)   # the port is open from here
    except OSError as e:
        sys.stderr.write("sing: cannot listen on %s:%d: %s\n" % (shttp.LOOPBACK, a.port, e))
        remove_own_pidfile(pidfile)
        return 3
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, _exit_on_signal(pidfile))
    shttp.log("facade pid %d listening on %s:%d (runtime %s; allowed roots %s; test hooks %s)"
              % (os.getpid(), shttp.LOOPBACK, a.port, runtime, roots, "ON" if test_hooks else "off"))
    threading.Thread(target=backend.load, name="sing-load", daemon=True).start()
    server.serve_forever(poll_interval=0.25)
    return 0


if __name__ == "__main__":
    sys.exit(main())
