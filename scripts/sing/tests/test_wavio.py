"""singlib/wavio.py: the facade's deterministic float32 WAV writer and the reader the stub, the installer's
diagnostic and the tests use. The writer's bytes are a pure function of (samples, rate, channels): no timestamp
(libsndfile's PEAK chunk carries one, which would break every byte-identical comparison, the prompt-f0 null test
included). Standard library only.
"""
import array
import os
import struct
import time
import unittest
import wave

from _util import RUNTIME, need_machine, sha256_path, temp_dir

from singlib import pins as spins
from singlib import wavio


class Writer(unittest.TestCase):
    def setUp(self):
        self.tmp = temp_dir("wavio")

    def test_the_exact_header(self):
        blob = wavio.wav_bytes_float32(wavio.float32_le_bytes([0.5, -0.25]), 48000)
        want = (b"RIFF" + struct.pack("<I", 4 + 26 + 12 + 16) + b"WAVE"
                + b"fmt " + struct.pack("<IHHIIHHH", 18, 3, 1, 48000, 192000, 4, 32, 0)
                + b"fact" + struct.pack("<II", 4, 2)
                + b"data" + struct.pack("<I", 8) + struct.pack("<ff", 0.5, -0.25))
        self.assertEqual(blob, want)
        info = wavio.parse_wav(blob)
        self.assertEqual((info["format"], info["channels"], info["sample_rate"], info["bits"], info["frames"]),
                         (3, 1, 48000, 32, 2))
        self.assertEqual(info["chunks"], ["fmt ", "fact", "data"])

    def test_the_bytes_depend_on_the_samples_only(self):
        y = array.array("f", [((k * 7919) % 2001 - 1000) / 1000.0 for k in range(24000)])
        a, b = os.path.join(self.tmp, "a.wav"), os.path.join(self.tmp, "b.wav")
        wavio.write_float32_wav(a, y, 24000)
        time.sleep(1.1)                                  # a timestamp in the header would now differ
        wavio.write_float32_wav(b, y, 24000)
        self.assertEqual(sha256_path(a), sha256_path(b))
        y[12000] += 1e-3
        wavio.write_float32_wav(b, y, 24000)
        self.assertNotEqual(sha256_path(a), sha256_path(b))   # control: one sample changes the bytes

    def test_round_trip(self):
        y = array.array("f", [0.0, 1.0, -1.0, 0.125, float("nan")])
        p = os.path.join(self.tmp, "r.wav")
        wavio.write_float32_wav(p, y, 44100)
        got, sr = wavio.read_float32_mono(p)
        self.assertEqual(sr, 44100)
        self.assertEqual(list(got[:4]), [0.0, 1.0, -1.0, 0.125])
        self.assertNotEqual(got[4], got[4])

    def test_a_symlink_at_the_path_is_replaced_never_followed(self):
        victim = os.path.join(self.tmp, "victim.txt")
        with open(victim, "wb") as f:
            f.write(b"precious")
        p = os.path.join(self.tmp, "out.wav")
        os.symlink(victim, p)
        wavio.write_float32_wav(p, [0.0] * 4, 24000)
        self.assertFalse(os.path.islink(p))
        with open(victim, "rb") as f:
            self.assertEqual(f.read(), b"precious")
        self.assertEqual([n for n in os.listdir(self.tmp) if ".tmp-" in n], [])

    def test_a_ragged_buffer_is_refused(self):
        with self.assertRaises(wavio.WavError):
            wavio.wav_bytes_float32(b"\x00" * 6, 24000)


class Reader(unittest.TestCase):
    def setUp(self):
        self.tmp = temp_dir("wavio")

    def test_pcm16_from_the_stdlib_wave_module(self):
        p = os.path.join(self.tmp, "pcm.wav")
        with wave.open(p, "wb") as w:
            w.setnchannels(2)
            w.setsampwidth(2)
            w.setframerate(44100)
            w.writeframes(b"\x01\x00\x02\x00" * 100)
        info, _ = wavio.read_wav(p)
        self.assertEqual((info["format"], info["channels"], info["bits"], info["frames"]), (1, 2, 16, 100))
        with self.assertRaises(wavio.WavError):
            wavio.read_float32_mono(p)

    def test_extensible_and_odd_chunks(self):
        fmt = struct.pack("<HHIIHHH", 0xFFFE, 1, 48000, 192000, 4, 32, 22) + struct.pack("<HI", 32, 4) \
            + struct.pack("<H", 3) + b"\x00\x00\x00\x00\x10\x00\x80\x00\x00\xaa\x00\x38\x9b\x71"
        body = (b"WAVE" + b"fmt " + struct.pack("<I", len(fmt)) + fmt + b"LIST" + struct.pack("<I", 3) + b"abc\x00"
                + b"data" + struct.pack("<I", 8) + struct.pack("<ff", 0.25, 0.5))
        info = wavio.parse_wav(b"RIFF" + struct.pack("<I", len(body)) + body)
        self.assertEqual((info["format"], info["frames"]), (3, 2))
        self.assertEqual(info["chunks"], ["fmt ", "LIST", "data"])

    def test_garbage_and_truncation(self):
        for blob in (b"", b"RIFF", b"RIFX\x00\x00\x00\x00WAVE", b"RIFF\x04\x00\x00\x00WAVE"):
            with self.assertRaises(wavio.WavError):
                wavio.parse_wav(blob)
        whole = wavio.wav_bytes_float32(wavio.float32_le_bytes([0.1] * 10), 24000)
        info = wavio.parse_wav(whole[:-12])                   # a cut-off download: 7 whole frames survive
        self.assertEqual(info["frames"], 7)

    def test_the_spikes_builtin_voice_file(self):
        # The installed runtime's built-in voice IS the spike's fixtures/zh_prompt_cut.wav, byte for byte (the pinned
        # sha256 below; measured equal to the spike's file on 2026-10-06, before the spike folder was deleted).
        p = spins.load()
        cut = os.path.join(RUNTIME, "voices", p["BUILTIN_VOICE_ID"], "prompt.wav")
        need_machine(os.path.isfile(cut), "the installed runtime's built-in voice %s" % cut)
        self.assertEqual(sha256_path(cut), p["BUILTIN_WAV_SHA256"])
        info, _ = wavio.read_wav(cut)
        self.assertEqual((info["format"], info["channels"], info["sample_rate"], info["bits"]), (3, 1, 48000, 32))
        self.assertEqual(info["chunks"], ["fmt ", "fact", "LIST", "data"])      # ffmpeg's LIST carries Lavf62.12.101
        import hashlib
        self.assertEqual(hashlib.sha256(wavio.data_chunk(cut)).hexdigest(), p["BUILTIN_PCM_SHA256"])
        with open(cut, "rb") as f:
            self.assertIn(b"Lavf62.12.101", f.read(info["data_offset"]))


if __name__ == "__main__":
    unittest.main()
