"""The facade's HTTP layer (singlib/http.py) with an in-process fake backend: every status in the §2.4 refusal
table reaches the wire as {error, message}; /health answers during a render; renders are serialized; no traceback
ever reaches the wire; 127.0.0.1 only. Standard library only (server.py's own launch refusals included: it refuses a
non-loopback host BEFORE the heavy imports, so the system python can run that part).
"""
import http.client as httpclient
import json
import os
import subprocess
import threading
import time
import unittest

from _util import (SERVER, SYSTEM_PY, T2_NOTES, T2_WORDS, child_env, free_port, http, listeners, own_voice,
                   phrase_request, temp_dir, wait_until, write_reference_wav)

from singlib import http as shttp
from singlib import schema, wavio
from singlib.refusals import HTTP_STATUS, Refusal


class FakeBackend(object):
    def __init__(self):
        self.st, self.err = "ready", None
        self.gate = None
        self.exc = None
        self.active = self.max_active = self.calls = 0
        self.lock = threading.Lock()

    def state(self):
        return self.st, self.err

    def health(self):
        return {"status": self.st, "facadeVersion": 1, "pid": os.getpid(), "rendered": self.calls}

    def render(self, req):
        with self.lock:
            self.active += 1
            self.calls += 1
            self.max_active = max(self.max_active, self.active)
        try:
            if self.gate is not None:
                self.gate.wait(20)
            if self.exc is not None:
                raise self.exc
            wavio.write_float32_wav(req.output_real, [0.0] * 8, req.out_sr)
            return {"outputPath": req.output_path, "frames": 8, "voice": req.voice.kind,
                    "testPromptF0": req.test_prompt_f0, "facadeVersion": req.facade_version, "control": req.control,
                    "langs": req.word_langs}
        finally:
            with self.lock:
                self.active -= 1


class Base(unittest.TestCase):
    hooks = False

    def setUp(self):
        self.tmp = os.path.realpath(temp_dir("http"))
        self.cache = os.path.join(self.tmp, "SingingCache")
        self.voices = os.path.join(self.tmp, "SingingVoices")
        self.runtime_voices = os.path.join(self.tmp, "SingingEngine", "voices")
        os.makedirs(self.cache)
        os.makedirs(os.path.join(self.runtime_voices, "builtin-1"))
        for n in ("prompt.wav", "prompt.json"):
            with open(os.path.join(self.runtime_voices, "builtin-1", n), "wb") as f:
                f.write(b"x")
        self.ref = os.path.join(self.voices, "v1", "reference.wav")
        self.ref_sha = write_reference_wav(self.ref, seconds=1.0)
        self.backend = FakeBackend()
        roots = schema.roots_from_env(os.pathsep.join([self.cache, self.voices]), always=[self.runtime_voices])
        self.server = shttp.make_server(0, self.backend, roots, self.runtime_voices, test_hooks=self.hooks)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        self.thread.start()

    def tearDown(self):
        if self.backend.gate is not None:
            self.backend.gate.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(5)

    def req(self, **over):
        return phrase_request(T2_NOTES, T2_WORDS, os.path.join(self.cache, "k.wav"), **over)

    def post(self, body, path="/v1/sing/phrase"):
        return http("POST", self.port, path, body, timeout=30)

    def raw(self, method, path, body=None, headers=None):
        c = httpclient.HTTPConnection("127.0.0.1", self.port, timeout=10)
        c.putrequest(method, path, skip_accept_encoding=True)
        for k, v in (headers or {}).items():
            c.putheader(k, v)
        c.endheaders()
        if body:
            c.send(body)
        r = c.getresponse()
        data = r.read()
        c.close()
        return r.status, (json.loads(data) if data else None)


class Routes(Base):
    def test_health(self):
        st, h = http("GET", self.port, "/health")
        self.assertEqual((st, h["status"], h["facadeVersion"]), (200, "ready", 1))

    def test_a_render(self):
        st, body = self.post(self.req())
        self.assertEqual(st, 200, body)
        self.assertEqual(body["outputPath"], os.path.join(self.cache, "k.wav"))
        self.assertTrue(os.path.isfile(os.path.join(self.cache, "k.wav")))

    def test_unknown_routes_and_methods(self):
        self.assertEqual(http("GET", self.port, "/nope"), (404, {"error": "notFound", "message": "No such endpoint: GET /nope"}))
        self.assertEqual(self.post(self.req(), "/v1/sing/other")[0], 404)
        for method in ("PUT", "DELETE", "PATCH", "OPTIONS"):
            st, body = self.raw(method, "/v1/sing/phrase")
            self.assertEqual((st, body["error"]), (405, "methodNotAllowed"), method)
        self.assertEqual(self.raw("HEAD", "/health")[0], 405)

    def test_malformed_bodies(self):
        for raw in (b"{", b"[1]", b'{"facadeVersion": NaN}', b"\xff"):
            st, body = self.post(raw)
            self.assertEqual((st, body["error"]), (400, "badRequest"), raw)
        st, body = self.raw("POST", "/v1/sing/phrase")                                   # no Content-Length
        self.assertEqual((st, body["error"]), (400, "badRequest"))
        st, body = self.raw("POST", "/v1/sing/phrase", headers={"Content-Length": str(shttp.MAX_BODY + 1)})
        self.assertEqual((st, body["error"]), (400, "badRequest"))
        self.assertEqual(self.backend.calls, 0)


class RefusalTable(Base):
    """Every code in the §2.4 table, with its HTTP status, through the wire."""

    def expect(self, body, code, status=None):
        st, got = self.post(body)
        self.assertEqual(got.get("error") if isinstance(got, dict) else got, code, got)
        self.assertEqual(st, status or HTTP_STATUS[code])
        self.assertEqual(sorted(got), ["error", "message"])
        self.assertTrue(got["message"])
        self.assertNotIn("Traceback", got["message"])
        self.seen.add(code)
        return got

    def test_every_code_in_the_table(self):
        self.seen = set()
        r = self.req()
        r["extra"] = 1
        self.expect(r, "badRequest")
        r = self.req(trailS=5.0)
        r["phrase"]["notes"][-1]["endS"] = 25.0
        self.expect(r, "phraseTooLong")
        r = self.req()
        r["phrase"]["notes"][1]["startS"] = 0.5
        self.expect(r, "notesOverlap")
        r = self.req()
        n = r["phrase"]["notes"]
        n[0], n[1] = n[1], n[0]
        self.expect(r, "notesUnsorted")
        r = self.req()
        r["phrase"]["words"] = r["phrase"]["words"][:2]
        self.expect(r, "wordsDoNotCoverNotes")
        r = self.req()
        r["phrase"]["words"][0]["text"] = " "
        self.expect(r, "emptyWord")
        self.expect(self.req(outputPath="/private/tmp/escape.wav"), "pathNotAllowed")
        self.expect(self.req(voice={"id": "builtin-2"}), "voiceNotFound")
        self.expect(self.req(voice=own_voice(self.ref, "0" * 64)), "referenceChanged")
        for code in ("unknownPhone", "badReference", "nonFinite"):          # raised inside the backend's render
            self.backend.exc = Refusal(code, "planted %s" % code)
            got = self.expect(self.req(), code)
            self.assertEqual(got["message"], "planted %s" % code)
        self.backend.exc = RuntimeError("boom\nsecond line\nTraceback (most recent call last):")
        got = self.expect(self.req(), "inferenceFailed")
        self.assertEqual(got["message"], "RuntimeError: boom")
        self.backend.exc = None
        self.backend.st = "loading"
        self.expect(self.req(), "loading")
        self.backend.st, self.backend.err = "error", "FFmpeg's libraries could not be loaded"
        got = self.expect(self.req(), "inferenceFailed")
        self.assertIn("FFmpeg", got["message"])
        self.backend.st, self.backend.err = "ready", None
        # facadeVersion 2's codes (design 2026-10-06 §7.4): two come from the schema over the wire ...
        r = self.req(facadeVersion=2)
        r["phrase"]["words"][0]["lang"] = "es"
        self.assertIn("'es'", self.expect(r, "languageNotSupported")["message"])
        r = self.req(facadeVersion=2)
        r["phrase"]["notes"][0]["vibrato"] = {"rateHz": 5.5, "depthCents": 45, "onsetS": 0.25}
        self.expect(r, "vibratoNeedsMelody")
        # ... and two belong to melody mode (item x10), unreachable while control can only be "score": planted
        for code in ("promptF0Missing", "f0TooShort"):
            self.backend.exc = Refusal(code, "planted %s" % code)
            self.assertEqual(self.expect(self.req(facadeVersion=2), code)["message"], "planted %s" % code)
        self.backend.exc = None
        self.assertEqual(self.seen, set(HTTP_STATUS))                        # the whole table, no more, no less

    def test_the_schema_answers_before_the_engine_state(self):
        self.backend.st = "loading"
        r = self.req()
        r["extra"] = 1
        self.assertEqual(self.post(r)[0], 400)
        self.assertEqual(self.post(self.req())[0], 503)


class Versions(Base):
    def test_v1_and_v2_requests_reach_the_backend_as_they_were_sent(self):
        st, body = self.post(self.req())
        self.assertEqual((st, body["facadeVersion"], body["control"], body["langs"]), (200, 1, "score", ["en"] * 3))
        r = self.req(facadeVersion=2, control="score")
        r["phrase"]["words"][2].update(text="你", lang="zh")
        st, body = self.post(r)
        self.assertEqual((st, body["facadeVersion"], body["control"], body["langs"]), (200, 2, "score",
                                                                                         ["en", "en", "zh"]))
        r = self.req(control="score")                                     # the same key under v1: refused, unrendered
        st, body = self.post(r)
        self.assertEqual((st, body["error"]), (400, "badRequest"))
        self.assertIn("'control' needs facadeVersion 2.", body["message"])
        self.assertEqual(self.backend.calls, 2)


class Concurrency(Base):
    def test_health_answers_while_a_render_runs(self):
        self.backend.gate = threading.Event()
        results = []
        t = threading.Thread(target=lambda: results.append(self.post(self.req())))
        t.start()
        self.assertTrue(wait_until(lambda: self.backend.active == 1, 10))
        t0 = time.time()
        st, h = http("GET", self.port, "/health", timeout=5)
        took = time.time() - t0
        self.assertEqual((st, h["status"]), (200, "ready"))
        self.assertLess(took, 1.0)
        self.backend.gate.set()
        t.join(20)
        self.assertEqual(results[0][0], 200)

    def test_renders_are_serialized(self):
        self.backend.gate = threading.Event()
        results = []
        threads = [threading.Thread(target=lambda: results.append(self.post(self.req()))) for _ in range(3)]
        for t in threads:
            t.start()
        self.assertTrue(wait_until(lambda: self.backend.active == 1, 10))
        time.sleep(0.4)
        self.assertEqual((self.backend.calls, self.backend.max_active), (1, 1))
        self.backend.gate.set()
        for t in threads:
            t.join(20)
        self.assertEqual(sorted(st for st, _ in results), [200, 200, 200])
        self.assertEqual((self.backend.calls, self.backend.max_active), (3, 1))


class Hooks(Base):
    hooks = True

    def test_the_hook_reaches_the_backend_only_when_launched_with_it(self):
        st, body = self.post(self.req(voice=own_voice(self.ref, self.ref_sha), testPromptF0={"hz": 220, "frames": "full"}))
        self.assertEqual(st, 200, body)
        self.assertEqual(body["testPromptF0"], [220.0, "full"])


class NoHooks(Base):
    def test_the_hook_is_an_unknown_key_otherwise(self):
        st, body = self.post(self.req(voice=own_voice(self.ref, self.ref_sha), testPromptF0={"hz": 220, "frames": "full"}))
        self.assertEqual((st, body["error"]), (400, "badRequest"))
        self.assertIn("testPromptF0", body["message"])


class Launch(unittest.TestCase):
    def test_check_host(self):
        for host in ("0.0.0.0", "localhost", "::1", "", "127.0.0.2"):
            with self.assertRaises(SystemExit) as cm:
                shttp.check_host(host)
            self.assertEqual(cm.exception.code, 2, host)
        shttp.check_host("127.0.0.1")

    def test_server_py_refuses_a_non_loopback_host(self):
        rt = temp_dir("launch")
        for args, env in (([ "--host", "0.0.0.0"], {}), ([], {"SING_HOST": "0.0.0.0"})):
            port = free_port()
            r = subprocess.run([SYSTEM_PY, SERVER, "--port", str(port)] + args,
                               env=child_env(SING_RUNTIME_DIR=rt, **env), capture_output=True, text=True, timeout=60)
            self.assertEqual(r.returncode, 2, r.stderr)
            self.assertIn("refusing to start on host '0.0.0.0'", r.stderr)
            self.assertEqual(listeners(port), [])

    def test_server_py_needs_a_runtime(self):
        r = subprocess.run([SYSTEM_PY, SERVER, "--port", str(free_port())],
                           env=child_env(SING_RUNTIME_DIR=os.path.join(temp_dir("launch"), "missing")),
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn("SING_RUNTIME_DIR", r.stderr)

    def test_a_second_listener_on_the_same_port_cannot_bind(self):
        a = shttp.make_server(0, FakeBackend(), [], "/nonexistent")
        try:
            port = a.server_address[1]
            self.assertEqual(a.server_address[0], "127.0.0.1")
            with self.assertRaises(OSError):
                shttp.make_server(port, FakeBackend(), [], "/nonexistent")
        finally:
            a.server_close()
        b = shttp.make_server(port, FakeBackend(), [], "/nonexistent")     # control: the port itself is fine
        b.server_close()


if __name__ == "__main__":
    unittest.main()
