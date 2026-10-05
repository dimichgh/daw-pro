#!/usr/bin/env python3
"""Build the tiny `.sf3` test fixture used by the m31-h conversion suite.

WHY A GENERATOR AND NOT JUST A CHECKED-IN BLOB: the fixture's whole value is
that its sample data is REAL MuseScore-produced Ogg Vorbis, copied verbatim out
of `FluidR3Mono_GM.sf3` — a synthetic stream we encoded ourselves would test our
own encoder's output rather than the format we actually have to read. This
script is the closed-form recipe that says exactly which bytes came from where,
the `scripts/make-bundled-samples.py` precedent.

WHAT IT PICKS, and why each one earns its place in a 20 KB fixture:

  * `square-8`  — one of the SEVENTEEN samples macOS's own (undocumented)
    Vorbis decoder CANNOT read: 64 frames, short enough that the OS decoder
    returns nothing at all. It is also a sample real GM presets depend on
    (program 80 "Square Lead" plays it above key 104), so it is the single
    best guard against a converted bank that loads and makes no sound.
  * `Sticks(R)` / `Sticks(L)` — `sfSampleType` 18 and 20, so the fixture
    exercises clearing the 0x10 Vorbis bit WITHOUT flattening the left/right
    bits, and preserving `wSampleLink`. (The real mono bank zeroes every link;
    the fixture sets a true one so a test can assert it survives.)
  * a plainly-looped mono sample — the ordinary case, and the one that proves
    loop points are rebased from SF3-relative to SF2-absolute.

Usage:
    python3 scripts/make-sf3-fixture.py <FluidR3Mono_GM.sf3> <out.sf3>

Source file: https://raw.githubusercontent.com/musescore/MuseScore/main/share/sound/FluidR3Mono_GM.sf3
SHA256: 2aacd036d7058d40a371846ef2f5dc5f130d648ab3837fe2626591ba49a71254
FluidR3 is MIT-licensed (Frank Wen); the MuseScore build carries the same terms.
"""

import struct
import sys

SHDR_SIZE = 46


def read_chunks(data, start, end):
    """Yield (id, body_offset, size) for the RIFF chunks in [start, end)."""
    out = []
    off = start
    while off + 8 <= end:
        cid = data[off:off + 4].decode("latin1")
        size = struct.unpack("<I", data[off + 4:off + 8])[0]
        body = off + 8
        if cid == "LIST":
            list_type = data[body:body + 4].decode("latin1")
            out.append((list_type, body + 4, size - 4, True))
            out.extend(read_chunks(data, body + 4, body + size))
        else:
            out.append((cid, body, size, False))
        off = body + size + (size & 1)
    return out


def locate(data):
    chunks = read_chunks(data, 12, 8 + struct.unpack("<I", data[4:8])[0])
    found = {}
    for cid, off, size, is_list in chunks:
        if not is_list:
            found[cid] = (off, size)
    return found


def sample_record(data, shdr_off, index):
    raw = data[shdr_off + index * SHDR_SIZE: shdr_off + (index + 1) * SHDR_SIZE]
    name = raw[:20].split(b"\0")[0].decode("latin1")
    start, end, sloop, eloop, rate = struct.unpack("<IIIII", raw[20:40])
    pitch, corr, link, typ = struct.unpack("<BbHH", raw[40:46])
    return dict(name=name, start=start, end=end, sloop=sloop, eloop=eloop,
                rate=rate, pitch=pitch, corr=corr, link=link, type=typ)


def chunk(cid, body):
    out = cid.encode("latin1") + struct.pack("<I", len(body)) + body
    if len(body) & 1:
        out += b"\0"
    return out


def zstr(text, length):
    raw = text.encode("latin1")[: length - 1]
    return raw + b"\0" * (length - len(raw))


def main():
    src, dst = sys.argv[1], sys.argv[2]
    data = open(src, "rb").read()
    assert data[:4] == b"RIFF" and data[8:12] == b"sfbk", "source is not an sfbk RIFF"
    found = locate(data)
    smpl_off, smpl_size = found["smpl"]
    shdr_off, shdr_size = found["shdr"]
    total = shdr_size // SHDR_SIZE - 1

    by_name = {}
    for i in range(total):
        rec = sample_record(data, shdr_off, i)
        by_name.setdefault(rec["name"], (i, rec))

    wanted = ["square-8", "Sticks(R)", "Sticks(L)"]
    picked = []
    for name in wanted:
        assert name in by_name, "sample %r not found in source" % name
        picked.append(by_name[name][1])

    # A plainly-looped ordinary mono sample: smallest type-17 with a real loop
    # and a sample rate that is not the 48 kHz the wavetables use, so the
    # fixture also covers a per-sample rate that differs from its neighbours.
    looped = None
    for i in range(total):
        rec = sample_record(data, shdr_off, i)
        if rec["type"] == 17 and rec["eloop"] > rec["sloop"] > 0 and rec["rate"] == 44100:
            if looped is None or (rec["end"] - rec["start"]) < (looped["end"] - looped["start"]):
                looped = rec
    assert looped is not None, "no looped 44.1 kHz mono sample found"
    picked.append(looped)

    # ── sdta: the Vorbis streams, copied byte for byte.
    smpl = b""
    headers = []
    for rec in picked:
        stream = data[smpl_off + rec["start"]: smpl_off + rec["end"]]
        headers.append((rec, len(smpl), len(smpl) + len(stream)))
        smpl += stream

    # Give the Sticks pair a REAL reciprocal link (indices 1 and 2 here), so a
    # test can assert wSampleLink survives conversion. The source bank zeroes
    # every link in its mono build, which would make that unassertable.
    links = {1: 2, 2: 1}

    shdr = b""
    for index, (rec, start, end) in enumerate(headers):
        shdr += zstr(rec["name"], 20)
        shdr += struct.pack("<IIIII", start, end, rec["sloop"], rec["eloop"], rec["rate"])
        shdr += struct.pack("<BbHH", rec["pitch"], rec["corr"],
                            links.get(index, 0), rec["type"])
    shdr += zstr("EOS", 20) + struct.pack("<IIIII", 0, 0, 0, 0, 0) \
        + struct.pack("<BbHH", 0, 0, 0, 0)

    # ── pdta: one preset → one instrument → one zone per sample.
    key_ranges = [(96, 127), (60, 71), (72, 83), (24, 59)]
    igen = b""
    ibag = b""
    for index in range(len(picked)):
        ibag += struct.pack("<HH", len(igen) // 4, 0)
        low, high = key_ranges[index]
        igen += struct.pack("<HBB", 43, low, high)          # keyRange
        igen += struct.pack("<HH", 54, 1)                    # sampleModes = loop
        igen += struct.pack("<HH", 53, index)                # sampleID — LAST, per spec
    ibag += struct.pack("<HH", len(igen) // 4, 0)            # terminal bag
    igen += struct.pack("<HH", 0, 0)                         # terminal gen

    inst = zstr("Fixture Inst", 20) + struct.pack("<H", 0)
    inst += zstr("EOI", 20) + struct.pack("<H", len(picked))

    pgen = struct.pack("<HH", 41, 0) + struct.pack("<HH", 0, 0)   # instrument, terminal
    pbag = struct.pack("<HH", 0, 0) + struct.pack("<HH", 1, 0)
    phdr = zstr("Fixture Preset", 20) + struct.pack("<HHHIII", 0, 0, 0, 0, 0, 0)
    phdr += zstr("EOP", 20) + struct.pack("<HHHIII", 0, 0, 1, 0, 0, 0)
    pmod = b"\0" * 10
    imod = b"\0" * 10

    info = b"INFO"
    info += chunk("ifil", struct.pack("<HH", 3, 1))       # SF3 — the point of the fixture
    info += chunk("isng", zstr("EMU8000", 8))
    info += chunk("INAM", zstr("m31-h SF3 conversion fixture", 32))
    info += chunk("ICMT", zstr(
        "Ogg Vorbis sample data copied verbatim from MuseScore's "
        "FluidR3Mono_GM.sf3 (FluidR3, Frank Wen, MIT). Generated by "
        "scripts/make-sf3-fixture.py for the m31-h test suite.", 176))
    info += chunk("ICOP", zstr("MIT (FluidR3, Frank Wen)", 32))

    sdta = b"sdta" + chunk("smpl", smpl)
    pdta = b"pdta"
    pdta += chunk("phdr", phdr)
    pdta += chunk("pbag", pbag)
    pdta += chunk("pmod", pmod)
    pdta += chunk("pgen", pgen)
    pdta += chunk("inst", inst)
    pdta += chunk("ibag", ibag)
    pdta += chunk("imod", imod)
    pdta += chunk("igen", igen)
    pdta += chunk("shdr", shdr)

    body = b"sfbk" + chunk("LIST", info) + chunk("LIST", sdta) + chunk("LIST", pdta)
    out = b"RIFF" + struct.pack("<I", len(body)) + body
    open(dst, "wb").write(out)

    print("wrote %s (%d bytes), %d samples:" % (dst, len(out), len(picked)))
    for index, (rec, start, end) in enumerate(headers):
        print("  [%d] %-14r type=%2d rate=%5d bytes=%6d loop=%d..%d keys=%s"
              % (index, rec["name"], rec["type"], rec["rate"], end - start,
                 rec["sloop"], rec["eloop"], key_ranges[index]))


if __name__ == "__main__":
    main()
