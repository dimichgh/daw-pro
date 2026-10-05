// song.json -> payload.json for the three.js scene.
//
// Everything MUSICAL is decided here, in one place, from the SAME song.json the
// DAW project is built from: the tempo map, the diatonic staff mapping, the
// split into voices, the drum lanes and the depth scale. The scene file draws;
// it does not decide.
import fs from "node:fs";
import path from "node:path";

const SCALES = { major: [0,2,4,5,7,9,11], minor: [0,2,3,5,7,8,10],
  dorian: [0,2,3,5,7,9,10], mixolydian: [0,2,4,5,7,9,10], harmonicMinor: [0,2,3,5,7,8,11] };

// world units
// ⚠ NOTE_R WAS 0.115 -- a notehead 0.23 across on a staff whose lines are
// 0.20 apart, i.e. a head WIDER THAN ITS OWN STAFF SPACING. Invisible at the
// round-1 framing (fov 42, camera 2.3 back); round 2's wider, closer camera
// passes within ~1.6 units of the paper and the same head rendered as a
// 140-pixel BLACK DISC that reads as a hole in the road. Found by opening the
// 6.60 s still and isolating it -- removing the drums did not shift it, and
// setting afterGain 0 left a plain black circle, which is what named it.
// ⚠ UMAX IS NO LONGER A CONSTANT. With one road it was the half-width of the
// sheet; with a road per instrument track the sheet has to cover every road's
// band plus a margin, so it is DERIVED from the layout below and returned in
// the payload. The old value is kept as the single-road floor.
export const SP = 0.20, STEP_X = SP / 2, BOT_X = -2 * SP, UMAX = 1.70, NOTE_R = 0.075;

class Timing {
  constructor(segs) {
    this.s = [...segs].sort((a, b) => a.startBeat - b.startBeat);
    this.t0 = [0];
    for (let i = 1; i < this.s.length; i++)
      this.t0.push(this.t0[i-1] + (this.s[i].startBeat - this.s[i-1].startBeat) * 60 / this.s[i-1].bpm);
  }
  secs(beat) {
    let i = 0;
    for (let k = 0; k < this.s.length; k++) if (this.s[k].startBeat <= beat) i = k;
    return this.t0[i] + (beat - this.s[i].startBeat) * 60 / this.s[i].bpm;
  }
}

// ⚠ DIATONIC, BY LETTER NAME. A chromatic ladder puts F# and G on the same
// spot. A pitch outside the key is a hard error, never a misplaced dot.
function staffStep(root, scale, p) {
  for (let d = 0; d < 7; d++)
    if (((root + scale[d]) % 12 + 12) % 12 === ((p % 12) + 12) % 12)
      return 7 * Math.floor((p - root - scale[d]) / 12) + d;
  throw new Error(`pitch ${p} (pc ${((p%12)+12)%12}) is not in the key — the staff is diatonic`);
}

// ⭐ POLYPHONY IS THE DEFAULT. Notes at one onset are dealt to voices by pitch
// rank with nearest-pitch voice leading, so a four-note piano chord becomes
// four lights that each move sensibly to the next chord.
function splitVoices(notes) {
  const groups = new Map();
  for (const n of notes) {
    const k = Math.round(n[0] * 1e4) / 1e4;
    if (!groups.has(k)) groups.set(k, []);
    groups.get(k).push(n);
  }
  const voices = [];
  for (const k of [...groups.keys()].sort((a, b) => a - b)) {
    const g = groups.get(k).sort((a, b) => b[1] - a[1]);
    const used = new Set();
    for (const n of g) {
      let best = -1, bd = 1e9;
      voices.forEach((v, vi) => {
        if (used.has(vi) || v.free > k + 1e-6) return;
        const d = Math.abs(v.last - n[1]);
        if (d < bd) { bd = d; best = vi; }
      });
      if (best < 0) { voices.push({ notes: [], last: n[1], free: -1e9 }); best = voices.length - 1; }
      used.add(best);
      voices[best].notes.push(n);
      voices[best].last = n[1];
      voices[best].free = n[0] + n[2];
    }
  }
  return voices.filter(v => v.notes.length).map(v => v.notes);
}

export function prep(songPath, lagMsOverride, format) {
  const song = JSON.parse(fs.readFileSync(songPath, "utf8"));
  const T = new Timing(song.tempoSegments);
  const lag = (lagMsOverride ?? song.vizLagMs ?? 0) / 1000;
  const scale = SCALES[song.keyScale];
  if (!scale) throw new Error(`unknown keyScale ${song.keyScale}`);
  const ref = staffStep(song.keyRoot, scale, song.bottomLinePitch);
  const step = p => staffStep(song.keyRoot, scale, p) - ref;
  const xOf = p => BOT_X + step(p) * STEP_X;

  // ⭐ THE FRAME IS AN ARGUMENT. `formats` in song.json names each deliverable
  // with its size and its OWN camera keyframes; everything musical, physical
  // and photometric is shared. A Short is a re-framing of the same piece, not a
  // second build -- so a look decision can never apply to only one of them.
  const FMTS = song.formats ?? {};
  const fname = format ?? song.defaultFormat ?? 'short';
  const f = FMTS[fname];
  if (format && !f) throw new Error(
    `unknown format "${format}" — song.json declares: ${Object.keys(FMTS).join(', ') || '(none)'}`);
  const fmt = { name: fname,
    width:  f?.width  ?? 1080, height: f?.height ?? 1920,
    camera: f?.camera ?? song.camera ?? null, look: f?.look ?? {} };
  // ⭐⭐ ROUND 5: CAMERA TAKES ARE DATA, NOT CODE. One performance, several
  // camera tracks; a re-render from a new angle is a payload change, not an
  // edit to road.html. The following camera stays as take "default" so nothing
  // regresses, and the reverse angle the user asked for -- "even go in front
  // and show how the playing disks approach as we move camera back" -- is take
  // "approach".
  // ⚠ THE RETREAT RATE IS THE SHOT: at rate == zps the gap never changes and
  // the frame is static and dead; below it the disks close on the lens, grow,
  // and eventually pass it. It is a payload number precisely so the user picks
  // it rather than me.
  const takes = Object.assign({ default: fmt.camera }, f?.takes ?? song.takes ?? {});

  // ⭐⭐ ROUND 4: ONE ROAD PER INSTRUMENT TRACK.
  // A score page stacks staves; this page lies flat with z = time, so the
  // staves stack ACROSS x and recede together as one sheet. Every road shares
  // the SAME time axis (that is what makes it a score and not three videos),
  // and differs only in its lateral band, its staff, its clef origin and its
  // colour.
  // ⚠ EACH ROAD GETS ITS OWN `bottomLinePitch`. A bass line mapped through the
  // treble road's origin lands eight ledger lines below its staff -- a real
  // notehead, in a real place, on the wrong road. `roadBottomPitch` per track.
  const roadTracks = song.tracks.filter(t => t.road);
  if (!roadTracks.length) throw new Error('no track carries "road": true');
  const drumTracks = song.tracks.filter(t => t.roadDrum);

  const roads = [];
  roadTracks.forEach(tr => {
    // ⭐⭐ TWO WAYS TO REACH A STAFF LINE, and the second exists because the
    // first CANNOT REPRESENT REAL MUSIC. `staffStep` is diatonic BY PITCH
    // CLASS and throws on anything outside the key's seven notes; Beethoven's
    // Op. 27 No. 2 uses all twelve within twenty bars, so the tuning sample's
    // mapping would have refused the first real piece outright.
    // A staff is drawn by LETTER NAME: B# and C are one key and two lines, and
    // no function of pitch alone can tell them apart. So a note may carry its
    // own ABSOLUTE DIATONIC STEP (7*octave + letterIndex) as element 4, parsed
    // from the source's spelling, and the road names its bottom line in the
    // same units with `roadBottomStep`.
    // ⚠ THE TWO ARE NOT MIXED. A road that declares `roadBottomStep` REQUIRES
    // every note to carry a step and says so by name rather than silently
    // falling back to a mapping that would put the note somewhere plausible
    // and wrong.
    if (tr.roadBottomStep != null) {
      const bs = tr.roadBottomStep;
      roads.push({
        index: roads.length, kind: 'staff', name: tr.label ?? tr.name,
        color: tr.color, x0: tr.roadX0 ?? 0, lines: tr.roadLines ?? 5,
        halfW: tr.roadHalfW ?? 0.75, bottomLineStep: bs,
        step: n => {
          if (n[4] == null) throw new Error(
            `track "${tr.name}" declares roadBottomStep, so every note must carry ` +
            `its staff step as element 4 — note at beat ${n[0]} (pitch ${n[1]}) does not`);
          return n[4] - bs;
        },
        track: tr,
      });
      return;
    }
    const bot = tr.roadBottomPitch ?? song.bottomLinePitch;
    const rref = staffStep(song.keyRoot, scale, bot);
    roads.push({
      index: roads.length, kind: 'staff', name: tr.label ?? tr.name,
      color: tr.color, x0: tr.roadX0 ?? 0, lines: tr.roadLines ?? 5,
      halfW: tr.roadHalfW ?? 0.75, bottomLinePitch: bot,
      step: n => staffStep(song.keyRoot, scale, n[1]) - rref,
      track: tr,
    });
  });
  // all percussion shares ONE road: a percussion staff is 1-2 lines, not 5,
  // and the lanes are already a left/right split rather than a pitch.
  const percRoad = drumTracks.length ? {
    index: roads.length, kind: 'perc', name: song.percRoadName ?? 'Perc',
    color: drumTracks[0].color, x0: song.percRoadX0 ?? 0,
    lines: song.percRoadLines ?? 1, halfW: song.percRoadHalfW ?? 0.42,
  } : null;
  if (percRoad) roads.push(percRoad);

  const xIn = (rd, n) => rd.x0 + BOT_X + rd.step(n) * STEP_X;

  // ⚠ zps IS DERIVED FROM THE UNION OF ROAD ONSETS, and adding a road changes
  // it. Reported by the CLI so a framing change can never be silently
  // attributed to the camera when the road actually got longer or shorter.
  const allRoadNotes = roadTracks.flatMap(t => t.notes);
  const onsets = [...new Set(allRoadNotes.map(n => +(T.secs(n[0]) + lag).toFixed(5)))]
    .sort((a, b) => a - b);
  const diffs = [];
  for (let i = 1; i < onsets.length; i++) diffs.push(onsets[i] - onsets[i-1]);
  diffs.sort((a, b) => a - b);
  const medgap = diffs.length ? diffs[diffs.length >> 1] : 0.4;
  const zps = (song.zPerGap ?? 0.62) / Math.max(medgap, 1e-3);

  // ⭐ VOICES ARE SPLIT PER ROAD, NOT GLOBALLY. Splitting the union would deal
  // a bass note and a melody note to the SAME voice by pitch proximity, and
  // that voice's light would then leap between two staves on one note -- the
  // exact "right beat, wrong road" failure the gate exists to catch.
  const voices = [];
  const notes = [];
  roads.filter(r => r.kind === 'staff').forEach(rd => {
    const rn = rd.track.notes.slice().sort((a, b) => a[0] - b[0] || a[1] - b[1]);
    for (const n of rn)
      notes.push({ t: T.secs(n[0]) + lag, x: xIn(rd, n), step: rd.step(n),
                   road: rd.index });
    splitVoices(rn).forEach(vn => voices.push({
      index: voices.length, road: rd.index,
      notes: vn.map(n => ({ t: T.secs(n[0]) + lag,
                            dur: T.secs(n[0]+n[2]) - T.secs(n[0]),
                            x: xIn(rd, n), pitch: n[1], vel: n[3] / 127 })),
    }));
  });
  notes.sort((a, b) => a.t - b.t || a.x - b.x);

  const drums = [];
  for (const tr of drumTracks)
    for (const [s, p, l, v] of tr.notes)
      drums.push({ t: T.secs(s) + lag,
                   lane: percRoad.x0 + ((tr.drumLanes || {})[String(p)] ?? 0),
                   vel: v / 127, color: tr.color, road: percRoad.index });
  drums.sort((a, b) => a.t - b.t);
  const total = T.secs(song.lengthBeats) + lag;
  const bars = [];
  const bpb = song.beatsPerBar ?? 4;
  for (let b = 0; b <= song.lengthBeats + 1e-6; b += bpb)
    bars.push({ t: T.secs(b) + lag, heavy: b % (bpb * 4) === 0 });

  // ⛔ THE MISSING-NOTEHEAD BUG, and the shape of it is worth keeping.
  // This loop used to select on `tr.roadSide` and read a per-TRACK `roadSideU`,
  // while the fireballs were selected by `tr.roadDrum` and positioned from a
  // per-PITCH `drumLanes`. Two names for one concept and two coordinates for
  // one spot: no song ever set `roadSide`, so `side` came out EMPTY and all 24
  // fireballs bounced off bare paper. The user saw it before any check did.
  // ⭐ THE FIX IS ONE SOURCE OF TRUTH, not a second list that happens to agree:
  // the landing marks are DERIVED FROM `drums`, the very array the fireballs
  // are positioned from, so a mark and its ball cannot drift apart again.
  // ⚠ ROUND 4: `road` MUST TRAVEL WITH THE MARK. Derived-from-`drums` was
  // enough when there was one road; the moment the key carries a road id, a
  // mark that forgets its own road keys apart from the ball that lands on it —
  // 24 marks and 24 landings, every one of them "missing". The gate caught it
  // on its first run against the three-road payload, which is the same failure
  // shape (two representations of one concept drifting) it was written for.
  const side = drums.map(d => ({ t: d.t, u: d.lane, vel: d.vel, color: d.color, road: d.road }));

  // ⚠ THE SHEET MUST COVER EVERY ROAD. Derived from the bands actually laid
  // out (plus the widest ledger-line excursion any note makes), never assumed.
  let ext = 0;
  for (const rd of roads) ext = Math.max(ext, Math.abs(rd.x0) + (rd.halfW ?? 0.5));
  for (const nn of notes) ext = Math.max(ext, Math.abs(nn.x) + 0.15);
  for (const dd of drums) ext = Math.max(ext, Math.abs(dd.lane) + 0.15);
  // the single-road width stays the FLOOR, so a one-road song is framed as before
  const umax = Math.max(UMAX, Math.round((ext + (song.paperMargin ?? 0.45)) * 100) / 100);

  // ⭐⭐ THE CAMERA MUST FIT THE LAYOUT IT IS ACTUALLY POINTED AT.
  // ⚠ `ext` above is a SYMMETRIC half-width — max(|x|) — so it is BLIND to an
  // asymmetric layout, and that blindness is a measured defect, not a theory:
  // Moonlight's three roads run x -1.62 .. +2.27 (mid +0.325) while the tuning
  // sample's run -1.72 .. +1.97 (mid +0.125). The approved camera keyframes were
  // authored against the SAMPLE's layout, so on Moonlight the Bass road ran off
  // the RIGHT EDGE OF FRAME. Opening the frame is what found it; no gate did.
  // So compute the SIGNED extent, and let a song declare the layout its camera
  // keyframes were framed against.
  // ⚠⚠ TWO EXTENTS, AND CONFLATING THEM IS THE DEFECT. The SHEET's extent says
  // how wide the page is; the PLAYHEAD's extent says where the performance
  // actually happens. On the tuning sample they disagree badly — its Perc road
  // sits at x=1.55 and carries no playheads at all, so the sheet runs to +1.97
  // while every light lives between -1.60 and +0.50. Centring on the SHEET
  // therefore points the camera at a band the eye has no reason to look at.
  const R3 = v => Math.round(v * 1000) / 1000;
  let sLo = Infinity, sHi = -Infinity, pLo = Infinity, pHi = -Infinity;
  const sheet = (a, b) => { sLo = Math.min(sLo, a); sHi = Math.max(sHi, b); };
  const play  = (a, b) => { pLo = Math.min(pLo, a); pHi = Math.max(pHi, b); };
  for (const rd of roads) sheet(rd.x0 - (rd.halfW ?? 0.5), rd.x0 + (rd.halfW ?? 0.5));
  for (const nn of notes) { sheet(nn.x - 0.15, nn.x + 0.15); play(nn.x, nn.x); }
  // ⚠ DRUMS ARE IN THE SHEET EXTENT AND OUT OF THE PLAYHEAD EXTENT, deliberately
  // and on two independent grounds. (1) framing.mjs's subject is `__perf().voices`
  // — melodic playheads; drum rigs are not in that list, so including them here
  // would fit the camera to something the gate does not measure. (2) The user
  // ruled on this directly: "I am ok with percussion small artifacts", naming a
  // disk leaving frame at extreme right positions as ACCEPTED. Fitting the camera
  // to the drum lanes would re-open a question they closed.
  for (const dd of drums) sheet(dd.lane - 0.15, dd.lane + 0.15);
  const xMid = R3((sLo + sHi) / 2), xHalf = R3((sHi - sLo) / 2);
  const pMid = R3((pLo + pHi) / 2), pHalf = R3((pHi - pLo) / 2);
  const layout = { xLo: R3(sLo), xHi: R3(sHi), xMid, xHalf,
                   playLo: R3(pLo), playHi: R3(pHi), playMid: pMid, playHalf: pHalf };

  // ⭐ THE REFERENCE IS DECLARED, NOT GUESSED, and it is a property of the CAMERA
  // KEYFRAMES — so it lives beside them in `formats` and travels with them when a
  // second song inherits the format block. `cameraFitLayout: {xMid, xHalf}` says
  // "these keyframes were framed for a layout centred here, this wide". prep then
  // SLIDES the camera by the centre difference and WIDENS its field of view by the
  // half-width ratio.
  // ⚠⚠ THE TUNING SAMPLE DECLARES ITS OWN MEASURED VALUES, so the transform RUNS
  // there and is an EXACT no-op (dx 0, ratio 1) — which is the point. A song that
  // skipped the code path would prove nothing about the code path.
  // ⚠ fov widens through the TANGENT, not linearly: half-width on screen is
  // proportional to tan(fov/2), so tan(fov'/2) = tan(fov/2) * ratio. Scaling fov
  // itself would under-widen at 40 deg and over-widen at 60.
  // ⚠ Height/distance are NOT touched. Pulling `back` would also change how much
  // of the road's LENGTH is in frame, which is the shot the user approved.
  // ⚠ THE CONTROL: `--nocamerafit` (or ROADS_NO_CAMERA_FIT=1) restores the
  // layout-blind camera on purpose, so a gate that claims to see the Bass road
  // leave frame can be made to FIRE. A fix with no way to un-fix it is a fix
  // nothing can check.
  let cameraFit = null;
  const noFit = process.argv.includes('--nocamerafit') || process.env.ROADS_NO_CAMERA_FIT === '1';
  const fitRef = noFit ? null : (fmt.cameraFitLayout ?? song.cameraFitLayout ?? null);
  if (fitRef && Array.isArray(fmt.camera)) {
    if (typeof fitRef.xMid !== 'number' || typeof fitRef.xHalf !== 'number' || fitRef.xHalf <= 0)
      throw new Error(`cameraFitLayout must be {xMid:number, xHalf:number>0}, got ${JSON.stringify(fitRef)}`);
    // WHERE TO POINT: the centre of the PLAYHEAD band, because that is the
    // subject. MEASURED on Moonlight — sheet-centred dx +0.23 left 49 of 4585
    // playhead-frames outside the frame; playhead-centred dx +0.925 left 6.
    const dx = pMid - (fitRef.playMid ?? fitRef.xMid);
    // ⚠⚠ THE WORLD RATIO IS NECESSARY AND NOT SUFFICIENT, MEASURED.
    // xHalf/refHalf alone took Moonlight's out-of-frame playhead-frames from 82
    // to 49 and its worst overshoot from 18.7 % to 12.3 % of the frame — better,
    // and still not the approved standard, which is ZERO (the tuning sample
    // scores 0 out of 1074 playhead-frames). The reason is geometric: the crop
    // that survives is a NEAR-FIELD one. The camera is yawed 21 deg and offset
    // laterally, so the road's near end sweeps right across the frame far faster
    // than its lateral half-width predicts, and a symmetric widening about the
    // aim point does not cover it.
    // So `cameraFitExtra` is an EXTRA multiplier SOLVED against framing.mjs's own
    // projection probe, not reasoned about — the number and the run that produced
    // it are recorded in NOTES.md, and the gate that accepts it runs at
    // FRAMING_ALLOW=0. It defaults to 1, so a song that does not need one is
    // untouched and the tuning sample stays byte-identical.
    const extra = Number(process.env.ROADS_CAMERA_FIT_EXTRA ?? fitRef.extra ?? song.cameraFitExtra ?? 1);
    if (!(extra > 0)) throw new Error(`cameraFitExtra must be > 0, got ${extra}`);
    // ⭐⭐ HOW MUCH TO PULL BACK — A DOLLY, NOT A WIDER LENS, and that is a
    // correction to this function's own first design. Widening the field of view
    // converged hopelessly slowly on the near-field crop that actually survives:
    // at the approved zPerGap 0.45, the fov path was still leaving 28 of 4585
    // playhead-frames outside the frame at fov 56.5 (up from 40) — a visibly
    // wider, emptier shot AND still failing. A uniform dolly, `back` and `h`
    // scaled TOGETHER so the elevation angle and the lens are both preserved and
    // only the distance changes, reached ZERO at 1.25x and stayed there.
    // MEASURED on both ladders against framing.mjs at FRAMING_ALLOW=0:
    //   fov   x1.10 -> 62 offenders   x1.20 -> 50   x1.30 -> 39   x1.40 -> 28
    //   dolly x1.15 -> 26 offenders   x1.25 ->  0   x1.32 ->  0   x1.40 ->  0
    // ⚠ `back` ALONE is not the same move: it flattens the shot, because the
    // camera's angle over the road falls as it retreats. h scales with it exactly
    // so that it does not.
    // ⚠ fov IS NOT TOUCHED AT ALL. That also retires a rounding hazard the fov
    // path carried — 2*atan(tan(f/2)*1.0) need not return f bit for bit, and the
    // whole identity argument for the tuning sample rested on it doing so.
    const dolly = xHalf / fitRef.xHalf * extra;
    fmt.camera = fmt.camera.map(k => ({ ...k, x: (k.x ?? 0) + dx,
                                        back: (k.back ?? 2.3) * dolly,
                                        h: (k.h ?? 1.05) * dolly }));
    takes.default = fmt.camera;
    cameraFit = { ref: fitRef, layout, extra, dx: Math.round(dx * 1e6) / 1e6,
                  dolly: Math.round(dolly * 1e6) / 1e6,
                  back: fmt.camera.map(k => Math.round(k.back * 1000) / 1000),
                  h: fmt.camera.map(k => Math.round(k.h * 1000) / 1000),
                  x: fmt.camera.map(k => Math.round(k.x * 1000) / 1000) };
  }

  // paper extent and texture size, asserted against the GPU's 16384 limit
  const zNear = 1.30, zFar = -(total * zps + 1.4), zlen = zNear - zFar;
  // ⚠ texW AND UMAX MOVE TOGETHER -- texH = zlen/(2*UMAX)*texW, so narrowing the
  // sheet RAISES the texture height. UMAX 1.55->1.05 at texW 1536 would have
  // demanded 17654 rows against the GPU's 16384 limit; the assert below is what
  // caught it. 1280 lands at ~14800.
  // ⚠ texW SCALES WITH THE SHEET. Held at 1536 while the paper widened from
  // 1.70 to cover three roads, every road would get ~40 % fewer pixels per unit
  // and the staff lines would alias. Scaling keeps pixels-per-unit constant --
  // which also holds texH roughly constant, since texH = zlen/(2*umax)*texW.
  const texW = Math.min(4096, Math.round(1536 * umax / UMAX / 64) * 64);
  const texH = Math.round(zlen / (2 * umax) * texW);

  // ⭐⭐⭐ THE SCALING WALL, AND WHY IT DISSOLVES INSTEAD OF NEEDING TILES.
  // texH is the height ONE texture would need to hold the whole road at square
  // pixel density, and it grows without bound with the film: the 20-bar road at
  // the approved zPerGap 0.45 wants 50,230 rows against a measured 16384 GPU
  // limit. That is a hard blocker on any 60-90 s film, and it is init-time
  // geometry — no per-frame visibility cull touches it.
  //
  // ⭐ BUT THE PAPER MAP HAS BEEN CONTENT-FREE SINCE ROUND 5. Staff lines, bar
  // lines, labels, noteheads, stems and percussion marks are all REAL GEOMETRY
  // in the balls' own frame; the texture is nothing but a flat fill plus
  // isotropic grain. A brief written against the old painted-sheet model asks
  // for tiles that register content across a join. There is no content to
  // register.
  //
  // ⭐⭐ SO THE TILE REPEATS instead of being unique along its length: a bounded
  // canvas of `paperTileH` rows, wrapped `paperRepeatV` times down the road.
  // The join is exact rather than approximate — two sides of a wrap boundary are
  // two draws from the SAME uniform grain distribution about the SAME fill, which
  // is what every other pair of adjacent rows already is. Nothing can step, and
  // nothing can be missing, because nothing is drawn there.
  // ⚠ This is the mechanism paperNormal/paperRough have ALWAYS used (repeat 6x90).
  //
  // ⚠ TILE_MAX IS 12288, NOT THE 16384 LIMIT: 75 % of it, so the tile never
  // approaches the limit at any spacing, and — deliberately — ABOVE the tuning
  // sample's own 10939, so the sample takes tileH = texH, repeatV = 1, the
  // identical canvas, and its approved look is byte-identical by construction.
  // ⚠⚠ WHICH MEANS THE SAMPLE NEVER EXERCISES THE WRAP. The wrap is proven on a
  // payload that needs it — 20-bar Moonlight at zPerGap 0.45 — not on the
  // degenerate one. See lib/seam.mjs.
  const TILE_MAX = 12288;
  const paperTileH = Math.min(texH, TILE_MAX);
  const paperRepeatV = texH / paperTileH;
  if (paperTileH > 16384) throw new Error(`paper tile ${texW}x${paperTileH} exceeds the measured 16384 limit`);

  return { id: song.id, title: song.title ?? "", subtitle: song.subtitle ?? "",
    lagMs: lag * 1000, zps, medgap, total, notes, bars, side, drums, voices,
    takes, take: 'default',
    zNear, zFar, zlen, texW, texH, paperTileH, paperRepeatV,
    SP, STEP_X, BOT_X, UMAX: umax, NOTE_R,
    roads: roads.map(r => ({ index: r.index, kind: r.kind, name: r.name,
      color: r.color, x0: r.x0, lines: r.lines, halfW: r.halfW })),
    onsets, width: fmt.width, height: fmt.height, format: fmt.name,
    layout, cameraFit, camera: fmt.camera, drumGravity: song.drumGravity ?? 7.0,
    look: { ...(song.look ?? {}), ...(fmt.look ?? {}) } };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const argv = process.argv.slice(2);
  const flag = k => { const i = argv.indexOf(k); return i < 0 ? null : argv[i+1]; };
  const pos = argv.filter((a, i) => !a.startsWith('--') && !(i > 0 && argv[i-1].startsWith('--')));
  const format = flag('--format');
  const lead = flag('--lead');
  const p = prep(path.resolve(pos[0]), lead != null ? +lead : (pos[1] ? +pos[1] : undefined), format);
  const out = path.resolve(flag('--out') || pos[2] ||
    path.join(path.dirname(path.resolve(pos[0])), "out", "payload.json"));
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, JSON.stringify(p));
  // ⚠ zps AND medgap ARE REPORTED because adding a road CHANGES THEM: a road
  // whose onsets fall between the existing ones shortens the median gap, which
  // lengthens the paper. Without this line a framing change gets blamed on the
  // camera.
  console.error(
    `prep[${p.format} ${p.width}x${p.height}]: ${p.roads.length} roads ` +
    `(${p.roads.map(r => `${r.name}@${r.x0}${r.kind === 'perc' ? '*' : ''}`).join(' ')}), ` +
    `${p.notes.length} noteheads in ${p.voices.length} voices, ${p.drums.length} drum hits, ` +
    `zps ${p.zps.toFixed(3)}, medgap ${(p.medgap*1000).toFixed(0)} ms, ` +
    `paper ${(2*p.UMAX).toFixed(2)} wide x ${p.zlen.toFixed(1)} long, ` +
    `texture ${p.texW}x${p.texH} (tile ${p.texW}x${p.paperTileH} x ${p.paperRepeatV.toFixed(3)}) -> ${out}`);
}
