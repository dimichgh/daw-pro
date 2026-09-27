"""Deterministic WAV I/O, standard library only (Python 3.9 compatible).

Why not soundfile for the facade's output: libsndfile adds a PEAK chunk to float WAVs whose header carries a
wall-clock TIMESTAMP (measured on the spike's renders: `1cee b66a` vs `5701 b76a` at offset 0x3c). Two renders
with identical samples then differ in their file bytes, which would make every "byte-identical" comparison
(the prompt-f0 null test, a cache entry) fail for a reason that has nothing to do with audio. This writer's
bytes are a pure function of (samples, rate, channels).

Layout written: RIFF / WAVE / fmt (18 bytes: WAVE_FORMAT_IEEE_FLOAT, cbSize 0) / fact / data, little-endian.
"""
import array
import os
import struct
import sys

WAVE_FORMAT_PCM = 1
WAVE_FORMAT_IEEE_FLOAT = 3
WAVE_FORMAT_EXTENSIBLE = 0xFFFE


class WavError(ValueError):
    pass


def float32_le_bytes(samples):
    """array('f') / list of floats -> little-endian float32 bytes."""
    a = samples if isinstance(samples, array.array) and samples.typecode == "f" else array.array("f", samples)
    if sys.byteorder != "little":
        a = array.array("f", a)
        a.byteswap()
    return a.tobytes()


def wav_bytes_float32(data_le, sample_rate, channels=1):
    """Header + data for float32 little-endian sample bytes (interleaved when channels > 1)."""
    if len(data_le) % (4 * channels):
        raise WavError("data length %d is not a whole number of frames" % len(data_le))
    frames = len(data_le) // (4 * channels)
    fmt = struct.pack("<HHIIHHH", WAVE_FORMAT_IEEE_FLOAT, channels, sample_rate, sample_rate * 4 * channels,
                      4 * channels, 32, 0)
    fact = struct.pack("<I", frames)
    body = (b"WAVE" + b"fmt " + struct.pack("<I", len(fmt)) + fmt + b"fact" + struct.pack("<I", len(fact)) + fact
            + b"data" + struct.pack("<I", len(data_le)) + data_le)
    return b"RIFF" + struct.pack("<I", len(body)) + body


def write_atomic(path, blob):
    """Write bytes to `path` through a temp file in the same directory and os.replace(). The replace swaps the
    directory entry itself, so a symlink planted at `path` is replaced, never followed."""
    d = os.path.dirname(path) or "."
    tmp = os.path.join(d, ".%s.tmp-%d" % (os.path.basename(path), os.getpid()))
    try:
        with open(tmp, "wb") as f:
            f.write(blob)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


def write_float32_wav(path, samples_or_le_bytes, sample_rate, channels=1):
    data = samples_or_le_bytes if isinstance(samples_or_le_bytes, (bytes, bytearray)) \
        else float32_le_bytes(samples_or_le_bytes)
    write_atomic(path, wav_bytes_float32(bytes(data), sample_rate, channels))


def parse_wav(blob):
    """-> dict(format, channels, sample_rate, bits, frames, data_offset, data_size, chunks).
    Accepts PCM, IEEE float and WAVE_FORMAT_EXTENSIBLE (AVFoundation writes it)."""
    if len(blob) < 12 or blob[:4] != b"RIFF" or blob[8:12] != b"WAVE":
        raise WavError("not a RIFF/WAVE file")
    pos, fmt, data, chunks = 12, None, None, []
    while pos + 8 <= len(blob):
        cid, size = blob[pos:pos + 4], struct.unpack("<I", blob[pos + 4:pos + 8])[0]
        chunks.append(cid.decode("latin-1"))
        start = pos + 8
        if cid == b"fmt ":
            if size < 16:
                raise WavError("fmt chunk too short")
            tag, ch, sr, _br, align, bits = struct.unpack("<HHIIHH", blob[start:start + 16])
            if tag == WAVE_FORMAT_EXTENSIBLE and size >= 40:
                tag = struct.unpack("<H", blob[start + 24:start + 26])[0]   # SubFormat GUID's first two bytes
            fmt = (tag, ch, sr, align, bits)
        elif cid == b"data":
            data = (start, min(size, len(blob) - start))
        pos = start + size + (size & 1)
    if fmt is None or data is None:
        raise WavError("missing fmt or data chunk")
    tag, ch, sr, align, bits = fmt
    if ch < 1 or sr < 1 or align < 1:
        raise WavError("bad fmt values")
    return {"format": tag, "channels": ch, "sample_rate": sr, "bits": bits, "frames": data[1] // align,
            "data_offset": data[0], "data_size": data[1], "chunks": chunks}


def read_wav(path):
    with open(path, "rb") as f:
        blob = f.read()
    return parse_wav(blob), blob


def data_chunk(path):
    info, blob = read_wav(path)
    return blob[info["data_offset"]:info["data_offset"] + info["data_size"]]


def read_float32_mono(path):
    """-> (array('f'), sample_rate) for a float32 mono file (what the facade and the stub write)."""
    info, blob = read_wav(path)
    if info["format"] != WAVE_FORMAT_IEEE_FLOAT or info["bits"] != 32 or info["channels"] != 1:
        raise WavError("expected float32 mono, got format %d, %d bits, %d channels"
                       % (info["format"], info["bits"], info["channels"]))
    a = array.array("f")
    a.frombytes(blob[info["data_offset"]:info["data_offset"] + info["frames"] * 4])
    if sys.byteorder != "little":
        a.byteswap()
    return a, info["sample_rate"]
