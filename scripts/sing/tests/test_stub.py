"""The stub facade (stub_server.py) under the system /usr/bin/python3, launched through run.sh like the product.

  * a clean render: the planned length at 24/44.1/48 kHz, each note's sine at its target pitch, rests EXACTLY zero;
  * the facade's own refusals (the stub shares singlib's schema, converter and HTTP layer);
  * every fault, asserted on the WRITTEN BYTES or the process state (design §7.1's controls come from these):
    nan (64 NaN samples in the file while the reply still says nonFinite: false), nonfinite (500, nothing written),
    silence (all zero), click (one full-scale sample in note 2), crash (exit 70, no reply), slow (health still
    answers), balloon (the RSS really grows), and AFTER/COUNT scheduling;
  * launch refusals: an unknown fault, a non-loopback host, a port already taken.
"""
import hashlib
import json
import os
import subprocess
import threading
import time
import unittest

from _util import (SPB, T1_NOTES, T1_WORDS, T2_NOTES, T2_WORDS, concat, fixture_bytes, free_port, health_status,
                   http, listeners, own_voice, phrase_request, pid_alive, ps_field, start_stub_direct, stop_pid_exact,
                   stub_via_run_sh, temp_dir, wait_ready, wait_until, write_reference_wav)

from singlib import score, wavio

T1T2 = concat([(T1_NOTES, T1_WORDS, 0), (T2_NOTES, T2_WORDS, 16 + 100.0 / 60.0)])


def midi_hz(m):
    return 440.0 * 2.0 ** ((m - 69) / 12.0)


def zero_crossing_hz(y, a, b, sr):
    """Frequency from rising zero crossings over the middle half of [a, b)."""
    q = (b - a) // 4
    lo, hi = a + q, b - q
    ups = [k for k in range(lo + 1, hi) if y[k - 1] < 0.0 <= y[k]]
    if len(ups) < 2:
        return 0.0
    return (len(ups) - 1) * sr / float(ups[-1] - ups[0])


class StubCase(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(temp_dir("stub"))
        self.runtime = os.path.join(self.tmp, "App Support", "DAWPro", "SingingEngine")
        self.cache = os.path.join(self.tmp, "App Support", "DAWPro", "SingingCache")
        self.voices = os.path.join(self.tmp, "App Support", "DAWPro", "SingingVoices")
        for d in (self.runtime, self.cache, self.voices):
            os.makedirs(d)
        self.roots = [self.cache, self.voices]
        self.port = free_port()

    def stub(self, **env):
        return stub_via_run_sh(self.runtime, self.port, self.roots, **env)

    def out(self, name):
        return os.path.join(self.cache, name)

    def render(self, notes=T2_NOTES, words=T2_WORDS, name="k.wav", **over):
        return http("POST", self.port, "/v1/sing/phrase", phrase_request(notes, words, self.out(name), **over),
                    timeout=120)


class CleanRender(StubCase):
    def test_length_pitch_and_silent_rests(self):
        with self.stub():
            for sr, frames in ((48000, 704640), (24000, 352320), (44100, 647388)):
                st, body = self.render(*T1T2, name="t1t2-%d.wav" % sr, outputSampleRate=sr)
                self.assertEqual(st, 200, body)
                self.assertEqual((body["frames"], body["sampleRate"], body["nonFinite"]), (frames, sr, False))
                info, _ = wavio.read_wav(self.out("t1t2-%d.wav" % sr))
                self.assertEqual((info["format"], info["channels"], info["sample_rate"], info["bits"], info["frames"]),
                                 (3, 1, sr, 32, frames))
                spike = json.loads(fixture_bytes("T1T2"))[0]
                for k in ("duration", "note_pitch", "note_type", "time", "text"):
                    self.assertEqual(body["targetMeta"][k], spike[k], k)
            y, sr = wavio.read_float32_mono(self.out("t1t2-48000.wav"))
            meta = json.loads(fixture_bytes("T1T2"))[0]
            bounds = score.bounds_of(meta)
            pitches = [int(p) for p in meta["note_pitch"].split()]
            self.assertTrue(all(v == v for v in y))
            self.assertLessEqual(max(abs(v) for v in y), 0.1 + 1e-6)
            for i, p in enumerate(pitches):
                a, b = int(round(bounds[i] * sr)), int(round(bounds[i + 1] * sr))
                if p == 0:
                    self.assertEqual(max(abs(v) for v in y[a:b]), 0.0, "rest %d must be digital silence" % i)
                else:
                    hz = zero_crossing_hz(y, a, b, sr)
                    self.assertLess(abs(hz / midi_hz(p) - 1.0), 0.01, "entry %d: %.2f Hz vs MIDI %d" % (i, hz, p))
            gap = [i for i, p in enumerate(pitches) if p == 0][1]           # the 1 s silence between T1 and T2
            self.assertAlmostEqual(bounds[gap + 1] - bounds[gap], 1.0, places=6)

    def test_the_facades_refusals(self):
        ref = os.path.join(self.voices, "v1", "reference.wav")
        sha = write_reference_wav(ref, seconds=5.0)
        junk = os.path.join(self.voices, "v2", "reference.wav")
        os.makedirs(os.path.dirname(junk))
        with open(junk, "wb") as f:
            f.write(b"not a wav at all")
        junk_sha = hashlib.sha256(b"not a wav at all").hexdigest()
        with self.stub():
            st, body = self.render(outputPath="/private/tmp/escape.wav")
            self.assertEqual((st, body["error"]), (403, "pathNotAllowed"))
            self.assertEqual(self.render(voice={"id": "builtin-2"})[1]["error"], "voiceNotFound")
            words = [("!!!", [0])] + list(T2_WORDS[1:])
            st, body = self.render(T2_NOTES, words)
            self.assertEqual((st, body["error"]), (400, "emptyWord"))
            self.assertIn("!!!", body["message"])
            st, body = self.render(voice=own_voice(ref, "0" * 64))
            self.assertEqual((st, body["error"]), (409, "referenceChanged"))
            st, body = self.render(voice=own_voice(junk, junk_sha))
            self.assertEqual((st, body["error"]), (422, "badReference"))
            st, body = self.render(voice=own_voice(ref, sha, window=(0.0, 9.0)))
            self.assertEqual((st, body["error"]), (422, "badReference"))    # the window runs past the recording
            st, body = self.render(voice=own_voice(ref, sha), name="own.wav")
            self.assertEqual(st, 200, body)
            self.assertEqual(body["voice"], {"id": "0b7c9e7a-own-voice", "kind": "own"})

    def test_loading_then_ready(self):
        p = start_stub_direct(self.runtime, self.port, log=os.path.join(self.tmp, "direct.log"),
                              SING_STUB_LOAD_S="2.5", SING_ALLOWED_ROOTS=os.pathsep.join(self.roots))
        try:
            self.assertTrue(wait_until(lambda: health_status(self.port), 10))
            self.assertEqual(health_status(self.port)["status"], "loading")
            st, body = self.render()
            self.assertEqual((st, body["error"]), (503, "loading"))
            self.assertTrue(wait_ready(self.port, 10))
            self.assertEqual(self.render()[0], 200)
        finally:
            stop_pid_exact(p.pid, p)


class Faults(StubCase):
    def samples(self, name):
        return wavio.read_float32_mono(self.out(name))[0]

    def spans(self, body, sr=48000):
        meta = body["targetMeta"]
        bounds = score.bounds_of(meta)
        return [(int(round(bounds[i] * sr)), int(round(bounds[i + 1] * sr)))
                for i, p in enumerate(meta["note_pitch"].split()) if int(p) > 0]

    def test_nan_is_in_the_bytes_while_the_reply_says_finite(self):
        with self.stub(SING_STUB_FAULT="nan"):
            st, body = self.render()
            self.assertEqual((st, body["nonFinite"], body["stub"]["fault"]), (200, False, "nan"))
            y = self.samples("k.wav")
            bad = [k for k, v in enumerate(y) if v != v]
            self.assertEqual(len(bad), 64)
            a, b = self.spans(body)[0]
            self.assertTrue(a <= bad[0] and bad[-1] < b)

    def test_nonfinite_refuses_and_writes_nothing(self):
        with self.stub(SING_STUB_FAULT="nonfinite"):
            st, body = self.render()
            self.assertEqual((st, body["error"]), (500, "nonFinite"))
            self.assertFalse(os.path.exists(self.out("k.wav")))

    def test_silence(self):
        with self.stub(SING_STUB_FAULT="silence"):
            st, body = self.render()
            y = self.samples("k.wav")
            self.assertEqual((st, len(y)), (200, body["frames"]))
            self.assertEqual(len(y), 195840)
            self.assertEqual(max(abs(v) for v in y), 0.0)

    def test_click(self):
        with self.stub(SING_STUB_FAULT="click"):
            st, body = self.render()
            y = self.samples("k.wav")
            loud = [k for k, v in enumerate(y) if abs(v) > 0.1 + 1e-6]
            self.assertEqual(len(loud), 1)
            self.assertEqual(y[loud[0]], 1.0)
            a, b = self.spans(body)[1]
            self.assertTrue(a <= loud[0] < b)

    def test_crash_exits_70_without_a_reply(self):
        with self.stub(SING_STUB_FAULT="crash") as (pid, proc, log):
            with self.assertRaises(Exception) as cm:
                self.render()
            self.assertNotIsInstance(cm.exception, AssertionError)
            self.assertEqual(proc.wait(timeout=10), 70)
            self.assertFalse(pid_alive(pid))
            self.assertEqual(listeners(self.port), [])
            self.assertTrue(os.path.isfile(os.path.join(self.runtime, "run", "sing.pid")))   # stale: run.sh clears it

    def test_slow_keeps_health_answering(self):
        with self.stub(SING_STUB_FAULT="slow", SING_STUB_SLOW_S="2.0"):
            got = []
            t0 = time.time()
            th = threading.Thread(target=lambda: got.append(self.render()))
            th.start()
            time.sleep(0.5)
            t1 = time.time()
            h = health_status(self.port)
            self.assertIsNotNone(h)
            self.assertLess(time.time() - t1, 1.0)
            th.join(30)
            self.assertEqual(got[0][0], 200)
            self.assertGreaterEqual(time.time() - t0, 2.0)

    def test_balloon_really_grows_then_renders(self):
        with self.stub(SING_STUB_FAULT="balloon", SING_STUB_BALLOON_HOLD_S="2.0") as (pid, proc, log):
            rss0 = int(ps_field(pid, "rss"))
            got = []
            th = threading.Thread(target=lambda: got.append(self.render()))
            th.start()
            peak = wait_until(lambda: (lambda r: r if r >= 600 * 1024 else None)(int(ps_field(pid, "rss") or 0)), 20,
                              step=0.05)
            th.join(60)
            self.assertIsNotNone(peak, "RSS never reached 600 MiB")
            self.assertLess(rss0, 200 * 1024)
            self.assertEqual(got[0][0], 200)
            self.assertEqual(got[0][1]["stub"]["fault"], "balloon")

    def test_after_and_count(self):
        with self.stub(SING_STUB_FAULT="silence", SING_STUB_FAULT_AFTER="1", SING_STUB_FAULT_COUNT="1"):
            faults, peaks = [], []
            for i in range(3):
                st, body = self.render(name="r%d.wav" % i)
                self.assertEqual(st, 200)
                faults.append(body["stub"]["fault"])
                peaks.append(max(abs(v) for v in self.samples("r%d.wav" % i)))
            self.assertEqual(faults, [None, "silence", None])
            self.assertEqual(peaks[1], 0.0)
            self.assertGreater(peaks[0], 0.09)
            self.assertGreater(peaks[2], 0.09)
            self.assertEqual(health_status(self.port)["stub"]["applied"], 1)


class LaunchRefusals(StubCase):
    def test_unknown_fault(self):
        p = start_stub_direct(self.runtime, self.port, SING_STUB_FAULT="gremlins")
        _, err = p.communicate(timeout=30)
        self.assertEqual(p.returncode, 2)
        self.assertIn("gremlins", err)

    def test_non_loopback_host(self):
        p = start_stub_direct(self.runtime, self.port, host="0.0.0.0")
        _, err = p.communicate(timeout=30)
        self.assertEqual(p.returncode, 2)
        self.assertEqual(listeners(self.port), [])

    def test_a_second_listener_on_the_same_port_exits_3(self):
        other = os.path.join(self.tmp, "other runtime")
        os.makedirs(other)
        with self.stub() as (pid, proc, log):
            p = start_stub_direct(other, self.port)
            _, err = p.communicate(timeout=30)
            self.assertEqual(p.returncode, 3, err)
            self.assertIn("cannot listen", err)
            self.assertEqual(listeners(self.port), [pid])


if __name__ == "__main__":
    unittest.main()
