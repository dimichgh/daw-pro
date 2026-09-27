"""The HTTP layer shared by the facade (server.py) and the stub (stub_server.py). Standard library only,
Python 3.9 compatible.

  GET  /health            -> 200, backend.health()
  POST /v1/sing/phrase    -> 200 + the render's facts, or {"error", "message"} with the §2.4 status

Order of checks for a render (each stage's refusals are listed in singlib/refusals.py):
  body size and JSON -> schema (400) -> engine state (503 loading / 500 inferenceFailed if the load failed)
  -> filesystem: allowed roots on the realpath (403), voice exists (404), reference sha256 (409)
  -> backend.render under ONE inference lock (phonemes 400, badReference 422, nonFinite/inferenceFailed 500).
The app never sends two renders at once; the lock is a backstop. /health never takes it, so a long render
never blocks the health poll.

There is deliberately NO shutdown endpoint (design §2.4): stopping is pid-exact, from the manager.
"""
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import schema
from .refusals import HTTP_STATUS, ROUTING_STATUS, Refusal, first_line

LOOPBACK = "127.0.0.1"
MAX_BODY = 1 << 20


def check_host(host):
    """The facade binds 127.0.0.1 and nothing else. Anything else is refused BEFORE a socket is opened."""
    if host != LOOPBACK:
        sys.stderr.write("sing: refusing to start on host %r: the singing engine only listens on %s.\n"
                         % (host, LOOPBACK))
        raise SystemExit(2)


def log(msg):
    sys.stderr.write("%s sing: %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg))
    sys.stderr.flush()


class SingServer(ThreadingHTTPServer):
    daemon_threads = True
    # http.server.HTTPServer's own default, stated: a restart right after a kill must not wait out the server
    # side's TIME_WAIT (every response closes the connection). A second LISTENER on 127.0.0.1:<port> still
    # fails to bind (tested). A foreign listener on the wildcard address is the manager's lsof check (§2.8.6).
    allow_reuse_address = True

    def __init__(self, port, backend, roots, voices_dir, test_hooks=False):
        self.backend = backend
        self.roots = roots
        self.voices_dir = voices_dir
        self.test_hooks = test_hooks
        self.render_lock = threading.Lock()
        ThreadingHTTPServer.__init__(self, (LOOPBACK, port), Handler)


class Handler(BaseHTTPRequestHandler):
    server_version = "DAWProSing/1"
    sys_version = ""

    def log_message(self, fmt, *args):
        log("%s %s" % (self.address_string(), fmt % args))

    def _send(self, status, obj):
        body = json.dumps(obj, allow_nan=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def _refuse(self, code, message):
        status = HTTP_STATUS.get(code) or ROUTING_STATUS[code]
        self._send(status, {"error": code, "message": message})

    def do_GET(self):
        if self.path.split("?", 1)[0] == "/health":
            self._send(200, self.server.backend.health())
        else:
            self._refuse("notFound", "No such endpoint: GET %s" % self.path)

    def _not_allowed(self):
        self._refuse("methodNotAllowed", "%s is not supported; use GET /health or POST /v1/sing/phrase." % self.command)

    do_PUT = do_DELETE = do_PATCH = do_HEAD = do_OPTIONS = _not_allowed

    def do_POST(self):
        if self.path.split("?", 1)[0] != "/v1/sing/phrase":
            self._refuse("notFound", "No such endpoint: POST %s" % self.path)
            return
        t0 = time.time()
        try:
            result = self._phrase()
        except Refusal as r:
            log("refused %s: %s" % (r.code, r.message))
            self._send(r.status, r.body())
            return
        except Exception as e:   # never a traceback on the wire; the log gets the first line
            log("inferenceFailed: %s" % first_line(e))
            self._send(500, {"error": "inferenceFailed", "message": first_line(e)})
            return
        log("rendered %s in %.2f s" % (result.get("outputPath"), time.time() - t0))
        self._send(200, result)

    def _phrase(self):
        n = self.headers.get("Content-Length")
        try:
            n = int(n)
        except (TypeError, ValueError):
            raise Refusal("badRequest", "Content-Length is required.")
        if n <= 0 or n > MAX_BODY:
            raise Refusal("badRequest", "The request body must be 1 B to %d B; it was %d B." % (MAX_BODY, n))
        raw = self.rfile.read(n)
        srv = self.server
        req = schema.validate(schema.parse_body(raw), test_hooks=srv.test_hooks)
        state, err = srv.backend.state()
        if state == "loading":
            raise Refusal("loading", "The singing engine is still loading.")
        if state != "ready":
            raise Refusal("inferenceFailed", "The singing engine failed to load: %s" % (err or state))
        schema.resolve(req, srv.roots, srv.voices_dir)
        with srv.render_lock:
            return srv.backend.render(req)


def make_server(port, backend, roots, voices_dir, test_hooks=False):
    return SingServer(port, backend, roots, voices_dir, test_hooks)
