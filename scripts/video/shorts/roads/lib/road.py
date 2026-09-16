#!/usr/bin/env python3
"""⛔ SUPERSEDED — KEPT DELIBERATELY, NOT DEAD CODE.

This is the numpy/OpenCV renderer of the same idea: the staff drawn flat and
laid down with one cv2.warpPerspective, the light/arc/fireball projected as
real 3D points through the same pinhole. It WORKS and its frames are in
01-lantern/out/ — but the project moved to three.js (lib/road.html) on the
user's decision, for the interactive tuning loop and UnrealBloomPass.

Kept because it is the only renderer here that needs no browser and no GPU,
and because 01-lantern/song.json (built against it) is the CROSS-SONG CONTROL
the sync gate is falsified with.
"""
import argparse, json, math, os, sys
import numpy as np
import cv2
from PIL import Image, ImageDraw, ImageFont

W, H, FPS = 1080, 1920, 30
SF = "/System/Library/Fonts/SFNS.ttf"
MONO = "/System/Library/Fonts/SFNSMono.ttf"

SP = 0.20                     # staff line spacing, in world units
STEP_U = SP / 2.0
BOT_U = -2 * SP
UMAX = 1.55                   # half-width of the paper
PXU = 480.0                   # staff-buffer px per world x
PZ = 760.0                    # staff-buffer px per world z
PADZ = 1.30                   # world units of buffer before z=0
NOTE_R = 0.115                # notehead radius, world units (isotropic)

PAPER = (233, 225, 206)
INK = (16, 14, 13)
LINE = (46, 42, 38)

SCALES = {"major": [0, 2, 4, 5, 7, 9, 11], "minor": [0, 2, 3, 5, 7, 8, 10],
          "dorian": [0, 2, 3, 5, 7, 9, 10], "mixolydian": [0, 2, 4, 5, 7, 9, 10],
          "harmonicMinor": [0, 2, 3, 5, 7, 8, 11]}
VOICE_COLS = [(1.00, 0.72, 0.34), (0.55, 0.86, 1.00), (0.78, 0.62, 1.00),
              (0.62, 1.00, 0.72), (1.00, 0.55, 0.72), (1.00, 0.92, 0.52)]


# ---------------------------------------------------------------- camera ----
def look_at(eye, tgt, up=(0.0, 1.0, 0.0)):
    eye, tgt, up = map(lambda v: np.asarray(v, np.float64), (eye, tgt, up))
    f = tgt - eye
    f /= np.linalg.norm(f)
    s = np.cross(f, up)
    s /= np.linalg.norm(s)
    u = np.cross(s, f)
    M = np.eye(4)
    M[0, :3], M[1, :3], M[2, :3] = s, u, -f
    M[:3, 3] = -M[:3, :3] @ eye
    return M


def persp(fov_deg, aspect, near=0.02, far=400.0):
    t = 1.0 / math.tan(math.radians(fov_deg) / 2.0)
    P = np.zeros((4, 4))
    P[0, 0] = t / aspect
    P[1, 1] = t
    P[2, 2] = (far + near) / (near - far)
    P[2, 3] = 2 * far * near / (near - far)
    P[3, 2] = -1.0
    return P


VIEWPORT = np.array([[W / 2.0, 0.0, W / 2.0], [0.0, -H / 2.0, H / 2.0], [0.0, 0.0, 1.0]])


class Cam:
    """One frame's camera. `mvp` projects world (x,y,z) -> screen; `A` is the
    induced homography for the ROAD PLANE y=0, taking (x, z, 1) -> screen."""

    def __init__(self, eye, tgt, fov):
        self.mvp = persp(fov, W / H) @ look_at(eye, tgt)
        M = self.mvp
        Hc = np.array([[M[0, 0], M[0, 2], M[0, 3]],
                       [M[1, 0], M[1, 2], M[1, 3]],
                       [M[3, 0], M[3, 2], M[3, 3]]])
        self.A = VIEWPORT @ Hc
        self.Ainv = np.linalg.inv(self.A)

    def pts(self, x, y, z):
        """Project arbitrary world points. Returns (sx, sy, wclip)."""
        x, y, z = map(np.asarray, (x, y, z))
        o = np.ones_like(x, dtype=np.float64)
        v = np.stack([x, y, z, o]).astype(np.float64)
        q = self.mvp @ v
        wc = np.maximum(q[3], 1e-6) * np.sign(q[3] + 1e-12)
        sx = (q[0] / q[3] + 1.0) * 0.5 * W
        sy = (1.0 - q[1] / q[3]) * 0.5 * H
        return sx, sy, q[3]


class Timing:
    def __init__(self, segs):
        self.segs = sorted(segs, key=lambda s: s["startBeat"])
        assert self.segs and self.segs[0]["startBeat"] == 0
        self.t0 = [0.0]
        for a, b in zip(self.segs, self.segs[1:]):
            self.t0.append(self.t0[-1] + (b["startBeat"] - a["startBeat"]) * 60.0 / a["bpm"])

    def secs(self, beat):
        i = max(k for k, s in enumerate(self.segs) if s["startBeat"] <= beat)
        return self.t0[i] + (beat - self.segs[i]["startBeat"]) * 60.0 / self.segs[i]["bpm"]


class Staff:
    def __init__(self, root, scale, bottom_line_pitch):
        self.root, self.scale = root % 12, scale
        self.ref = self.abs_step(bottom_line_pitch)

    def abs_step(self, p):
        for deg, s in enumerate(self.scale):
            if (self.root + s) % 12 == p % 12:
                k = p - self.root - s
                return 7 * (k // 12) + deg
        raise ValueError(f"pitch {p} (pc {p % 12}) is not in the key — the staff is diatonic")

    def step(self, p):
        return self.abs_step(p) - self.ref

    def x(self, p):
        return BOT_U + self.step(p) * STEP_U


def hexrgb(s):
    s = s.lstrip("#")
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))


def fit_font(txt, path, size, maxw):
    while size > 12:
        f = ImageFont.truetype(path, size)
        if ImageDraw.Draw(Image.new("L", (8, 8))).textlength(txt, font=f) <= maxw:
            return f
        size -= 1
    return ImageFont.truetype(path, 12)


# ---------------------------------------------------------------- voices ----
def split_voices(notes):
    """Chord-aware voice assignment. Notes at the same onset are dealt to
    voices by pitch rank with nearest-pitch voice leading, so a four-note piano
    chord becomes four lights that each move sensibly to the next chord."""
    groups = {}
    for n in notes:
        groups.setdefault(round(n[0], 4), []).append(n)
    voices = []            # each: {"notes": [...], "last": pitch, "free": endBeat}
    for k in sorted(groups):
        g = sorted(groups[k], key=lambda n: -n[1])
        used = set()
        for n in g:
            best, bd = None, 1e9
            for vi, v in enumerate(voices):
                if vi in used or v["free"] > k + 1e-6:
                    continue
                d = abs(v["last"] - n[1])
                if d < bd:
                    best, bd = vi, d
            if best is None:
                voices.append({"notes": [], "last": n[1], "free": -1e9})
                best = len(voices) - 1
            used.add(best)
            voices[best]["notes"].append(n)
            voices[best]["last"] = n[1]
            voices[best]["free"] = n[0] + n[2]
    return [v["notes"] for v in voices if v["notes"]]


# ------------------------------------------------------------ staff paper ----
def build_buffer(song, T, road_notes, lag, total, st):
    zt = lambda t: t * song["_zps"]
    bh = int((total + PADZ + 1.5) * song["_zps"] * PZ / song["_zps"] * 0 +
             (zt(total) + PADZ + 1.2) * PZ)
    im = Image.new("RGB", (int(2 * UMAX * PXU), bh), PAPER)
    a = np.asarray(im, np.int16) + np.random.default_rng(7).integers(
        -7, 8, (bh, int(2 * UMAX * PXU), 1)).astype(np.int16)
    im = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))
    dr = ImageDraw.Draw(im)
    BX = lambda x: (x + UMAX) * PXU
    BY = lambda z: (z + PADZ) * PZ

    for i in range(5):
        x = BX(BOT_U + i * SP)
        dr.rectangle([x - 2.2, BY(zt(-0.4)), x + 2.2, BY(zt(total) + 0.8)], fill=LINE)
    bpb = song.get("beatsPerBar", 4)
    b = 0
    while b <= song["lengthBeats"] + 1e-6:
        y = BY(zt(T.secs(b) + lag))
        th = 6 if b % (bpb * 4) == 0 else 3.5
        dr.rectangle([BX(BOT_U) - 3, y - th, BX(BOT_U + 4 * SP) + 3, y + th], fill=LINE)
        b += bpb

    for tr in song["tracks"]:
        if not tr.get("roadSide"):
            continue
        c = hexrgb(tr["color"])
        c = tuple(int(PAPER[i] * 0.52 + c[i] * 0.48) for i in range(3))
        sd = tr.get("roadSideU", 0.80)
        for s, p, l, v in tr["notes"]:
            y = BY(zt(T.secs(s) + lag))
            for sg in (-1, 1):
                x, r = BX(sg * sd), 8 + 0.08 * v
                dr.ellipse([x - r, y - r, x + r, y + r], fill=c)

    rx, rz = NOTE_R * PXU, NOTE_R * PZ
    for s, p, l, v in road_notes:
        stp = st.step(p)
        x, y = BX(st.x(p)), BY(zt(T.secs(s) + lag))
        e = 2 if stp > 8 else (-2 if stp < 0 else 0)
        k = e
        while e and (k <= stp if e > 0 else k >= stp):
            lx = BX(BOT_U + k * STEP_U)
            dr.rectangle([lx - 2.2, y - rz * 1.6, lx + 2.2, y + rz * 1.6], fill=LINE)
            k += e
        dr.ellipse([x - rx, y - rz, x + rx, y + rz], fill=INK)
        up = stp < 4
        ex = x + (3.4 * STEP_U * PXU if up else -3.4 * STEP_U * PXU)
        dr.rectangle([min(x, ex), y - rz * 0.20, max(x, ex), y + rz * 0.20], fill=INK)
    return np.asarray(im)


# ------------------------------------------------------------------- main ----
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("song")
    ap.add_argument("--seconds", type=float, required=True)
    ap.add_argument("--out", default="-")
    ap.add_argument("--stills", default=None, help="comma-separated seconds to write as PNGs")
    ap.add_argument("--out-dir", default=".")
    ap.add_argument("--lag-ms", type=float, default=None)
    a = ap.parse_args()
    song = json.load(open(a.song))
    T = Timing(song["tempoSegments"])
    lag = (a.lag_ms if a.lag_ms is not None else song.get("vizLagMs", 0.0)) / 1000.0

    roads = [t for t in song["tracks"] if t.get("road")]
    if not roads:
        sys.exit('road.py: no track carries "road": true')
    rn = sorted([n for t in roads for n in t["notes"]], key=lambda n: (n[0], n[1]))
    st = Staff(song["keyRoot"], SCALES[song["keyScale"]], song["bottomLinePitch"])

    onset_t = sorted({round(T.secs(n[0]) + lag, 5) for n in rn})
    MEDGAP = float(np.median(np.diff(onset_t))) if len(onset_t) > 2 else 0.4
    # ⭐ DEPTH SCALE FROM THE MUSIC. One note-gap = Z_PER_GAP world units, so a
    # 88 BPM film and a 138 BPM film read at the same visual pace whatever the
    # note values are.
    ZPS = float(song.get("zPerGap", 0.62)) / max(MEDGAP, 1e-3)
    song["_zps"] = ZPS
    total = T.secs(song["lengthBeats"]) + lag + 1.0

    voices = split_voices(rn)
    vt = [np.array([T.secs(n[0]) + lag for n in v]) for v in voices]
    vx = [np.array([st.x(n[1]) for n in v]) for v in voices]
    vp = [np.array([n[1] for n in v]) for v in voices]
    vv = [np.array([n[3] for n in v], np.float32) / 127.0 for v in voices]
    vcol = [np.array(VOICE_COLS[i % len(VOICE_COLS)], np.float32) for i in range(len(voices))]

    drums = []
    for tr in song["tracks"]:
        if not tr.get("roadDrum"):
            continue
        lanes = tr.get("drumLanes", {})
        for s, p, l, v in tr["notes"]:
            drums.append((T.secs(s) + lag, float(lanes.get(str(p), 0.0)), v / 127.0,
                          np.array(hexrgb(tr["color"]), np.float32) / 255.0))
    drums.sort()
    dt = np.array([d[0] for d in drums]) if drums else np.zeros(0)

    buf = build_buffer(song, T, rn, lag, total, st)

    # camera keyframes; default is a slow pull-back so the frame is never static
    cam_kf = song.get("camera") or [
        {"t": 0.0, "eye": [0.0, 0.52, -0.85], "tgt": [0.0, 0.05, 1.5], "fov": 52},
        {"t": 1e9, "eye": [0.0, 0.52, -0.85], "tgt": [0.0, 0.05, 1.5], "fov": 52}]

    def cam_at(t):
        kf = cam_kf
        i = max(k for k in range(len(kf)) if kf[k]["t"] <= t) if kf[0]["t"] <= t else 0
        j = min(i + 1, len(kf) - 1)
        if j == i or kf[j]["t"] <= kf[i]["t"]:
            f = 0.0
        else:
            f = (t - kf[i]["t"]) / (kf[j]["t"] - kf[i]["t"])
            f = float(np.clip(f, 0, 1))
            f = f * f * (3 - 2 * f)
        lerp = lambda k: [kf[i][k][d] + (kf[j][k][d] - kf[i][k][d]) * f for d in range(3)]
        fov = kf[i]["fov"] + (kf[j]["fov"] - kf[i]["fov"]) * f
        return Cam(lerp("eye"), lerp("tgt"), fov)

    Xg = np.arange(W, dtype=np.float32)[None, :]
    Yg = np.arange(H, dtype=np.float32)[:, None]
    A_inv_buf = np.array([[1.0 / PXU, 0.0, -UMAX], [0.0, 1.0 / PZ, -PADZ], [0.0, 0.0, 1.0]])

    title, sub = song.get("title", ""), song.get("subtitle", "")
    hdr = Image.new("RGBA", (W, 220), (0, 0, 0, 0))
    hd = ImageDraw.Draw(hdr)
    hd.text((52, 44), title, font=ImageFont.truetype(SF, 44), fill=(236, 240, 252, 230))
    hd.text((54, 106), sub, font=fit_font(sub, MONO, 25, W - 110), fill=(150, 172, 210, 202))
    hdr_a = np.asarray(hdr, np.float32)[:, :, 3:4] / 255.0
    hdr_c = np.asarray(hdr, np.float32)[:, :, :3]

    COOL = np.array([0.30, 0.46, 1.00], np.float32)
    WARM = np.array([1.00, 0.56, 0.20], np.float32)
    VIOL = np.array([0.34, 0.16, 0.42], np.float32)
    ss = np.linspace(0.0, 1.0, 24)
    TRAIL = 4
    G = float(song.get("drumGravity", 7.0))

    def render(t):
        cam = cam_at(t)
        # camera road position: hold, then accelerate onto the next onset
        gi = int(np.searchsorted(onset_t, t + 1e-6) - 1)
        gi = max(0, min(len(onset_t) - 1, gi))
        if gi < len(onset_t) - 1:
            g0, g1 = onset_t[gi], onset_t[gi + 1]
            hh = float(np.clip((t - g0) / (g1 - g0), 0, 1))
            tc = g0 + (g1 - g0) * hh ** 2.6
        else:
            tc = onset_t[gi] + (t - onset_t[gi]) * 0.30
        Zc = tc * ZPS

        # ---- the paper -----------------------------------------------------
        Tz = np.array([[1.0, 0.0, 0.0], [0.0, 1.0, -Zc], [0.0, 0.0, 1.0]])
        Aw = cam.A @ Tz @ A_inv_buf
        albedo = cv2.warpPerspective(buf, Aw, (W, H), flags=cv2.INTER_LINEAR,
                                     borderMode=cv2.BORDER_CONSTANT, borderValue=(0, 0, 0))
        albedo = albedo.astype(np.float32) * (1.0 / 255.0)

        # ⚠ EXACT visibility + per-pixel depth, from the inverse homography's
        # rows. g = 1/w_clip, so g > 0 IS "in front of the camera", and the
        # road-space z of every pixel falls out of the same two dot products.
        Ai = np.linalg.inv(cam.A @ Tz)
        g = (Ai[2, 0] * Xg + Ai[2, 1] * Yg + Ai[2, 2]).astype(np.float32)
        zw = ((Ai[1, 0] * Xg + Ai[1, 1] * Yg + Ai[1, 2]) / np.where(np.abs(g) < 1e-9, 1e-9, g))
        vis = (g > 1e-7).astype(np.float32)
        zrel = (zw.astype(np.float32) - Zc) / ZPS          # seconds ahead of the light row
        albedo *= vis[:, :, None]

        fog = np.clip(1.0 - (zrel - 9.0 * MEDGAP) / (30.0 * MEDGAP), 0.0, 1.0) ** 1.15
        fog *= vis
        ramp = np.clip((zrel + 0.5 * MEDGAP) / (14.0 * MEDGAP), 0.0, 1.0)
        amb = (COOL[None, None, :] * (0.115 + 0.40 * ramp)[:, :, None] +
               VIOL[None, None, :] * (0.20 * ramp)[:, :, None]).astype(np.float32)

        # ---- one light per voice -------------------------------------------
        lights = []
        for vi in range(len(voices)):
            tv, xv, pv = vt[vi], vx[vi], vp[vi]
            k = int(np.searchsorted(tv, t + 1e-6) - 1)
            if k < 0:
                k = 0
            kn = min(k + 1, len(tv) - 1)
            if kn != k:
                hf = float(np.clip((t - tv[k]) / (tv[kn] - tv[k]), 0, 1)) ** 2.6
            else:
                hf = 0.0
            leap = abs(int(pv[kn]) - int(pv[k])) if kn != k else 0
            amp = 0.16 + 0.55 * min(1.0, leap / 12.0)
            lx = xv[k] + (xv[kn] - xv[k]) * hf
            lz = (tv[k] + (tv[kn] - tv[k]) * hf) * ZPS - Zc
            ly = 0.030 + amp * 4.0 * hf * (1 - hf)
            age = t - tv[k]
            on = tv[0] - 0.15 <= t
            env = (0.60 + 0.55 * math.exp(-max(age, 0) / 0.16) * (0.5 + 0.5 * vv[vi][k])) if on else 0.0
            if t > tv[-1] + 0.05 and kn == k:
                env *= max(0.0, math.exp(-(t - tv[-1] - 0.05) / 1.6))
            if env > 0.01:
                lights.append((vi, lx, ly, lz, env, k, hf))

        img = np.zeros((H, W, 3), np.float32)
        illum = amb.copy()
        cores = []
        for vi, lx, ly, lz, env, k, hf in lights:
            sx, sy, wc = cam.pts(np.array([lx]), np.array([ly]), np.array([lz]))
            if wc[0] <= 0:
                continue
            px, py = float(sx[0]), float(sy[0])
            r2 = (Xg - px) ** 2 + (Yg - py) ** 2
            sc = float(np.clip(1.6 / max(wc[0], 0.25), 0.35, 3.0))
            pool = np.exp(-r2 / (2.0 * (215.0 * sc) ** 2)).astype(np.float32)
            wide = np.exp(-r2 / (2.0 * (560.0 * sc) ** 2)).astype(np.float32)
            tint = 0.55 * vcol[vi] + 0.45 * WARM
            illum += (pool * (1.05 * env))[:, :, None] * tint
            illum += (wide * (0.30 * env))[:, :, None] * (tint * 0.72 + COOL * 0.28)
            cores.append((r2, sc, env, vcol[vi]))

        lit = albedo * illum * fog[:, :, None]

        # ---- depth of field, focused on the light row ----------------------
        dofw = np.clip(np.where(zrel < 0, -zrel / (2.2 * MEDGAP), zrel / (9.0 * MEDGAP)),
                       0.0, 1.0).astype(np.float32) ** 1.3
        dofw = dofw[:, :, None]
        b1 = cv2.GaussianBlur(lit, (0, 0), 7.0)
        b2 = cv2.GaussianBlur(lit, (0, 0), 21.0)
        lit = lit * (1 - dofw) + (b1 * (1 - dofw) + b2 * dofw) * dofw
        img += lit

        # ---- arcs, in world space, through the SAME camera ------------------
        arcs = np.zeros((H, W, 3), np.float32)
        for vi in range(len(voices)):
            tv, xv, pv = vt[vi], vx[vi], vp[vi]
            k0 = int(np.searchsorted(tv, t + 1e-6) - 1)
            for k in range(max(0, k0 - TRAIL), k0 + 1):
                if k + 1 > len(tv) - 1:
                    break
                if k == k0:
                    fr = float(np.clip((t - tv[k]) / max(tv[k + 1] - tv[k], 1e-6), 0, 1)) ** 2.6
                    fade = 1.0
                else:
                    fr, fade = 1.0, math.exp(-(tc - tv[k + 1]) / 0.60)
                if fr <= 1e-3 or fade < 0.03:
                    continue
                sN = ss * fr
                lp = abs(int(pv[k + 1]) - int(pv[k]))
                am = 0.16 + 0.55 * min(1.0, lp / 12.0)
                ax = xv[k] + (xv[k + 1] - xv[k]) * sN
                az = (tv[k] + (tv[k + 1] - tv[k]) * sN) * ZPS - Zc
                ay = am * 4.0 * sN * (1 - sN)
                sx, sy, wc = cam.pts(ax, ay, az)
                ok = wc > 1e-4
                P = np.stack([sx, sy], 1)[ok]
                Wc = wc[ok]
                c = vcol[vi] * 0.55 + WARM * 0.45
                for s_ in range(len(P) - 1):
                    tp = (s_ + 1) / len(P)
                    gq = fade * tp * tp
                    th = int(np.clip(2 + 9 / max(Wc[s_], 0.2), 2, 26))
                    cv2.line(arcs, (int(P[s_][0]), int(P[s_][1])),
                             (int(P[s_ + 1][0]), int(P[s_ + 1][1])),
                             tuple((c * gq).tolist()), th, cv2.LINE_AA)
        img += cv2.GaussianBlur(arcs, (0, 0), 3.2) * 1.6

        # ---- percussion: fireballs that FALL, strike, bounce and vanish -----
        for (dtt, dlane, dv, dcol) in drums:
            rel = t - dtt
            if rel < -0.55 or rel > 0.75:
                continue
            if rel < 0:                       # falling in
                yb = 0.5 * G * rel * rel
                al = float(np.clip((rel + 0.55) / 0.35, 0.0, 1.0))
            else:                             # struck, then bounces back up
                v0 = 0.42 * G * (0.45 + 0.55 * dv)
                yb = max(0.0, v0 * rel - 0.5 * G * rel * rel) * 0.55
                al = math.exp(-rel / 0.26)
            zb = dtt * ZPS - Zc
            sx, sy, wc = cam.pts(np.array([dlane]), np.array([yb + 0.05]), np.array([zb]))
            if wc[0] <= 0:
                continue
            r2 = (Xg - float(sx[0])) ** 2 + (Yg - float(sy[0])) ** 2
            sc = float(np.clip(1.6 / max(wc[0], 0.25), 0.3, 3.0))
            k = (1.6 if rel >= 0 else 0.7) * al * (0.5 + 0.5 * dv)
            img += (np.exp(-r2 / (2.0 * (30.0 * sc) ** 2)) * k)[:, :, None] * \
                   (dcol * 0.4 + np.array([1.0, 0.95, 0.85], np.float32) * 0.6)
            img += (np.exp(-r2 / (2.0 * (120.0 * sc) ** 2)) * (k * 0.30))[:, :, None] * dcol

        # ---- light cores, last, so they clip to white -----------------------
        for r2, sc, env, col in cores:
            img += (np.exp(-r2 / (2.0 * (24.0 * sc) ** 2)) * (2.6 * env))[:, :, None] * \
                   np.array([1.0, 0.98, 0.94], np.float32)
            img += (np.exp(-r2 / (2.0 * (78.0 * sc) ** 2)) * (0.42 * env))[:, :, None] * \
                   (col * 0.5 + WARM * 0.5)

        # ---- bloom, quarter res ---------------------------------------------
        sm = cv2.resize(img, (W // 4, H // 4), interpolation=cv2.INTER_AREA)
        br = np.maximum(sm - 0.82, 0.0)
        bl = (cv2.GaussianBlur(br, (0, 0), 4.0) * 0.42 +
              cv2.GaussianBlur(br, (0, 0), 13.0) * 0.34 +
              cv2.GaussianBlur(br, (0, 0), 34.0) * 0.30)
        img = img + cv2.resize(bl, (W, H), interpolation=cv2.INTER_LINEAR)

        img = np.clip(img, 0.0, 1.0) ** (1.0 / 1.06)
        fr_ = img * 255.0
        fr_[:220] = fr_[:220] * (1 - hdr_a * 0.92) + hdr_c * hdr_a * 0.92
        fr_[0:5, :int(W * min(1.0, t / a.seconds))] = np.array([120, 200, 255], np.float32)
        return np.clip(fr_, 0, 255).astype(np.uint8)

    if a.stills:
        os.makedirs(a.out_dir, exist_ok=True)
        for s_ in [float(x) for x in a.stills.split(",")]:
            f = int(round(s_ * FPS))
            p = os.path.join(a.out_dir, f"t{s_:06.2f}.png")
            Image.fromarray(render(f / FPS)).save(p)
            print(f"still {s_:.2f}s -> {p}", file=sys.stderr)
        return

    n = int(round(a.seconds * FPS))
    out = sys.stdout.buffer
    for f in range(n):
        out.write(render(f / FPS).tobytes())
    print(f"road: {n} frames, {len(rn)} road notes in {len(voices)} voices, "
          f"{len(drums)} drum hits, lag {lag*1000:.0f} ms, buffer {buf.shape[1]}x{buf.shape[0]}",
          file=sys.stderr)


if __name__ == "__main__":
    main()
