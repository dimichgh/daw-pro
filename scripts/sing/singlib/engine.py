"""The SoulX-Singer backend behind the facade (runtime venv, Python 3.10). Imported by server.py only.

It calls upstream's OWN functions, unchanged, exactly as the spike's harness did (code/harness.py):
  * cli.inference.build_model(...) and load_config(...), loaded eagerly at start;
  * soulxsinger.utils.data_processor.DataProcessor(...).process(meta, wav_path) for the prompt and the target;
  * model.infer(..., auto_shift=False, pitch_shift=0, n_steps, cfg, control=req.control, use_fp16=False), with
    torch.manual_seed + torch.mps.manual_seed IMMEDIATELY before each call (the harness's seed_all()). req.control
    is "score" for every request (a v1 request cannot set it; v2 accepts only "score" until item x10), so the call
    is today's call, keyword for keyword (test P3 pins it with a spy).
Around them it adds only what the design asks for (§2.4): the converter (singlib.score), the output assembly of
cli/inference.py process() (a zero buffer of int(time[1]/1000*24000) samples, the model's output copied over
min(len)), a NaN/Inf check BEFORE writing, soxr VHQ to outputSampleRate, a float32 WAV (singlib.wavio), and
torch.mps.empty_cache() after each unit with the driver's memory reported.
facadeVersion 2 (design 2026-10-06 §7): Mandarin/Cantonese words go through singlib.phonemes.Lexicon, whose libraries
are imported on the first request that needs them; a v2 reply adds "control", and "substitutions" when a tone was
substituted. /health adds "capabilities" and keeps "facadeVersion": 1.

NO pitch shifting here, ever: `auto_shift=False, pitch_shift=0` are hard-coded. Upstream's pitch_shift is added
after the prompt and target pitches are concatenated, so it would move the PROMPT's labels too (design §2.4).
The app applies octaves in the target note numbers; `promptLabelOffset` moves an own voice's labels explicitly.

Layout it reads, under the runtime directory (design §2.3):
  upstream/                        the pinned SoulX-Singer checkout (phone_set.json, cli/, soulxsinger/)
  weights/model.pt, config.yaml    the pinned weights
  nltk_data/                       cmudict, averaged_perceptron_tagger(_eng)
  voices/<id>/prompt.wav, .json    built-in voices (builtin-1 = upstream's zh_prompt cut, 48 kHz as the spike)
  run/prompts/                     short-lived prompt WAVs for own voices (deleted after DataProcessor reads them)
"""
import copy
import hashlib
import importlib.util
import json
import os
import sys
import threading
import time
import uuid
from collections import OrderedDict

from . import langs, schema, score, wavio
from .refusals import Refusal, first_line

PROMPT_CACHE = 4
SR = score.SAMPLE_RATE
LANG_MODULES = (("zh", "g2pM"), ("yue", "ToJyutping"))   # found (never imported) at start, for capabilities


def sung_languages():
    """English, plus each Chinese language whose library this interpreter can find. find_spec locates the module
    without importing it, so an English-only process still never loads g2pM or ToJyutping (test P8)."""
    return ["en"] + [lang for lang, mod in LANG_MODULES if importlib.util.find_spec(mod) is not None]


def upstream_commit(upstream_dir):
    """The checkout's HEAD, read from .git (measured at start, not taken from a record)."""
    try:
        with open(os.path.join(upstream_dir, ".git", "HEAD"), "r") as f:
            head = f.read().strip()
        if head.startswith("ref:"):
            ref = head.split(None, 1)[1]
            p = os.path.join(upstream_dir, ".git", ref)
            if os.path.isfile(p):
                with open(p) as f:
                    return f.read().strip()
            return None
        return head
    except OSError:
        return None


class SoulXBackend(object):
    def __init__(self, runtime, pins, device="mps"):
        self.runtime = runtime
        self.pins = pins
        self.device = device
        self.upstream = os.path.join(runtime, "upstream")
        self.model_path = os.path.join(runtime, "weights", pins.get("MODEL_FILE", "model.pt"))
        self.config_path = os.path.join(runtime, "weights", pins.get("CONFIG_FILE", "config.yaml"))
        self.nltk_dir = os.path.join(runtime, "nltk_data")
        self.phoneset_path = os.path.join(self.upstream, "soulxsinger", "utils", "phoneme", "phone_set.json")
        self.prompt_tmp = os.path.join(runtime, "run", "prompts")
        self._state, self._error = "loading", None
        self.load_seconds = None
        self.rendered = 0
        self.mps_driver_bytes = None
        self.ffmpeg_major = None
        self._prompts = OrderedDict()
        self._commit = upstream_commit(self.upstream)
        self.languages = sung_languages()
        self.lexicon = None
        try:
            self._weights_bytes = os.stat(self.model_path).st_size
        except OSError:
            self._weights_bytes = None

    # ------------------------------------------------------------------ state

    def state(self):
        return self._state, self._error

    def health(self):
        h = {"status": self._state, "facadeVersion": 1,
             "engine": {"commit": self._commit, "weightsRevision": self.pins.get("WEIGHTS_REVISION"),
                        "weightsBytes": self._weights_bytes},
             "device": self.device, "pid": os.getpid(), "loadSeconds": self.load_seconds,
             "mpsDriverBytes": self.mps_driver_bytes, "rendered": self.rendered, "ffmpegMajor": self.ffmpeg_major}
        if self._error:
            h["error"] = self._error
        h["capabilities"] = self.capabilities()
        return h

    def capabilities(self):
        """What a request may use (design 2026-10-06 §7.5). "melody" appears only with item x10."""
        return {"facadeVersions": list(schema.FACADE_VERSIONS), "controls": list(schema.CONTROLS),
                "languages": list(self.languages)}

    # ------------------------------------------------------------------ load (eager, in a background thread)

    def load(self):
        t0 = time.time()
        try:
            self._load()
            self.load_seconds = round(time.time() - t0, 3)
            self._state = "ready"
            sys.stderr.write("sing: model ready in %.1f s (device %s, FFmpeg %s)\n"
                             % (self.load_seconds, self.device, self.ffmpeg_major))
        except BaseException as e:   # the status says why; the process stays up so the manager can read it
            self._error = first_line(e)
            self._state = "error"
            sys.stderr.write("sing: model failed to load: %s\n" % self._error)

    def _load(self):
        if os.environ.get("PYTORCH_ENABLE_MPS_FALLBACK"):
            raise RuntimeError("PYTORCH_ENABLE_MPS_FALLBACK is set; the singing engine refuses to fall back to the "
                               "CPU silently (design §2.5 step 8). Unset it.")
        os.environ["HF_HUB_OFFLINE"] = "1"          # run.sh sets these too; a facade may never download
        os.environ["TRANSFORMERS_OFFLINE"] = "1"
        for p in (self.upstream, self.model_path, self.config_path, self.nltk_dir, self.phoneset_path):
            if not os.path.exists(p):
                raise RuntimeError("The singing engine is incomplete: %s is missing." % p)
        if self.upstream not in sys.path:
            sys.path.insert(0, self.upstream)
        os.chdir(self.upstream)                      # as the spike's harness did
        import numpy  # noqa: F401  (fail at load, not at the first render)
        import soxr  # noqa: F401
        import soundfile  # noqa: F401
        import torch
        if self.device == "mps" and not torch.backends.mps.is_available():
            raise RuntimeError("Metal (MPS) is not available to the singing engine on this Mac.")
        try:
            # torchaudio 2.11 reads every prompt WAV through torchcodec, which loads FFmpeg's shared libraries
            # (its LC_RPATH is /opt/homebrew/opt/ffmpeg/lib). Fail here, loudly, not at the first render.
            from torchcodec._core import ops as _tc_ops
            self.ffmpeg_major = int(_tc_ops.ffmpeg_major_version)
        except Exception as e:
            raise RuntimeError("FFmpeg's libraries could not be loaded (torchaudio reads audio through torchcodec, "
                               "which needs FFmpeg 4-8): %s" % first_line(e))
        import cli.inference as ci                    # upstream, unmodified
        from soulxsinger.utils.data_processor import DataProcessor
        from .phonemes import G2PPhonemizer, Lexicon
        config = ci.load_config(self.config_path)
        model = ci.build_model(model_path=self.model_path, config=config, device=self.device, use_fp16=False)
        self.torch = torch
        self.model = model
        self.config = config
        self.dp = DataProcessor(hop_size=config.audio.hop_size, sample_rate=config.audio.sample_rate,
                                phoneset_path=self.phoneset_path, device=self.device)
        with open(self.phoneset_path, "r", encoding="utf-8") as f:
            self.phoneset = frozenset(json.load(f))
        self.phonemize = G2PPhonemizer(self.nltk_dir)
        self.lexicon = Lexicon()          # builds nothing yet: g2pM / ToJyutping load on their first word
        self._sync()
        self._note_memory()

    # ------------------------------------------------------------------ helpers

    def _sync(self):
        if self.device == "mps":
            self.torch.mps.synchronize()

    def _seed(self, seed):
        self.torch.manual_seed(seed)
        if self.device == "mps":
            self.torch.mps.manual_seed(seed)

    def _note_memory(self):
        if self.device == "mps":
            self.mps_driver_bytes = int(self.torch.mps.driver_allocated_memory())

    # ------------------------------------------------------------------ voices

    def _prompt(self, req):
        v = req.voice
        key = v.cache_key(req.test_prompt_f0)
        if key in self._prompts:
            self._prompts.move_to_end(key)
            item, facts = self._prompts[key]
            return item, dict(facts, promptCached=True)
        if v.kind == "builtin":
            with open(v.meta, "r", encoding="utf-8") as f:
                metas = json.load(f)
            meta = metas[0] if isinstance(metas, list) else metas
            item = self.dp.process(copy.deepcopy(meta), v.wav)
            facts = {"id": v.id, "kind": "builtin", "promptFrames": int(item["mel2note"].shape[1])}
        else:
            item, facts = self._prepare_own(v, req.test_prompt_f0)
        self._prompts[key] = (item, facts)
        while len(self._prompts) > PROMPT_CACHE:
            self._prompts.popitem(last=False)
        return item, dict(facts, promptCached=False)

    def _prepare_own(self, v, test_f0):
        """own_voice.py's convert() + route_h() cut, with the facade's labels: native-rate float64 -> mean
        downmix -> soxr VHQ to 24 kHz -> the window [start, start + span + 0.06 s] (zero-padded if the file ends
        first) -> float32 WAV -> DataProcessor.process. No f0 in the metadata (design §3.7.9) unless the
        launch-time test hook asked for one."""
        import numpy as np
        import soundfile as sf
        import soxr
        try:
            y, sr = sf.read(v.reference_real, dtype="float64", always_2d=True)
        except Exception as e:
            raise Refusal("badReference", "The voice recording can't be read: %s" % first_line(e))
        if y.shape[0] == 0 or sr <= 0:
            raise Refusal("badReference", "The voice recording is empty.")
        mono = y.mean(axis=1)
        dur = len(mono) / float(sr)
        if v.window_end > dur + 0.05:
            raise Refusal("badReference", "The voice window ends at %.2f s, but the recording is only %.2f s long."
                          % (v.window_end, dur))
        win = v.window_end - v.window_start
        if win < schema.MIN_WINDOW_S or win > schema.MAX_WINDOW_S:
            raise Refusal("badReference", "The voice window is %.2f s long; it must be %.0f-%.0f s."
                          % (win, schema.MIN_WINDOW_S, schema.MAX_WINDOW_S))
        meta, info = score.build_prompt_meta(v.prompt_notes, win, phonemize=self.phonemize, phoneset=self.phoneset,
                                             label_offset=v.label_offset)
        m24 = soxr.resample(mono, sr, SR, quality="VHQ") if sr != SR else mono.copy()
        span = meta["time"][1] / 1000.0
        a = int(round(v.window_start * SR))
        n_need = int(round((span + 0.06) * SR))
        cut = m24[a:a + n_need].astype(np.float32)
        padded = max(0, n_need - len(cut))
        if padded:
            cut = np.concatenate([cut, np.zeros(padded, dtype=np.float32)])
        if not np.isfinite(cut).all():
            raise Refusal("badReference", "The voice recording contains samples that are not numbers.")
        n_mel = score.mel_frames(meta)
        if test_f0 is not None:
            hz, frames = test_f0
            n = n_mel + 1 if frames == "full" else int(frames)
            meta["f0"] = " ".join(["%.1f" % hz] * n)
        os.makedirs(self.prompt_tmp, exist_ok=True)
        tmp = os.path.join(self.prompt_tmp, "prompt-%d-%s.wav" % (os.getpid(), uuid.uuid4().hex))
        wavio.write_float32_wav(tmp, cut.astype("<f4").tobytes(), SR)
        try:
            item = self.dp.process(copy.deepcopy(meta), tmp)
        finally:
            os.remove(tmp)
        facts = {"id": v.id, "kind": "own", "promptFrames": int(item["mel2note"].shape[1]), "promptMelFrames": n_mel,
                 "promptEntries": info["entries"], "promptPaddedSamples": padded,
                 "promptMeta": {k: meta[k] for k in meta if k != "f0"},
                 "promptF0Frames": len(meta["f0"].split()) if "f0" in meta else 0}
        return item, facts

    # ------------------------------------------------------------------ one unit

    def render(self, req):
        import numpy as np
        torch = self.torch
        t_all = time.time()
        missing = sorted(set(req.word_langs) - set(self.languages))
        if missing:
            raise Refusal("languageNotSupported", "This singing engine cannot sing %s: its %s library is not "
                          "installed." % (", ".join(langs.NAME.get(m, m) for m in missing), ", ".join(
                              mod for lang, mod in LANG_MODULES if lang in missing)))
        prompt_item, vfacts = self._prompt(req)
        meta, info = score.build_meta(req.notes, req.words, lead=req.lead, trail=req.trail,
                                      phonemize=self.phonemize, phoneset=self.phoneset,
                                      langs=req.word_langs, lexicon=self.lexicon)
        target_item = self.dp.process(copy.deepcopy(meta), None)     # process() mutates its dict
        self._seed(req.seed)
        self._sync()
        t0 = time.perf_counter()
        with torch.no_grad():
            out = self.model.infer({"prompt": prompt_item, "target": target_item}, auto_shift=False, pitch_shift=0,
                                   n_steps=req.n_steps, cfg=req.cfg, control=req.control, use_fp16=False)
        self._sync()
        audio = out.detach().float().cpu().reshape(-1).numpy()
        infer_s = time.perf_counter() - t0
        n24 = score.output_samples_24k(meta)
        buf = np.zeros(n24, dtype=np.float32)
        k = min(audio.shape[0], n24)
        buf[:k] = audio[:k]
        try:
            if not np.isfinite(buf).all():
                bad = int((~np.isfinite(buf)).sum())
                raise Refusal("nonFinite", "The model produced %d samples that are not numbers (NaN/Inf); nothing "
                              "was written." % bad)
            if req.out_sr != SR:
                import soxr
                y = soxr.resample(buf, SR, req.out_sr, quality="VHQ").astype(np.float32)
            else:
                y = buf
            if not np.isfinite(y).all():
                raise Refusal("nonFinite", "The resampled output has samples that are not numbers; nothing was "
                              "written.")
            blob = wavio.wav_bytes_float32(y.astype("<f4").tobytes(), req.out_sr)
            os.makedirs(os.path.dirname(req.output_real), exist_ok=True)
            wavio.write_atomic(req.output_real, blob)
        finally:
            if self.device == "mps":
                torch.mps.empty_cache()
            self._note_memory()
        self.rendered += 1
        data = blob[-y.shape[0] * 4:] if y.shape[0] else b""
        reply = {
            "outputPath": req.output_path, "sampleRate": req.out_sr, "channels": 1, "frames": int(y.shape[0]),
            "durationS": round(y.shape[0] / float(req.out_sr), 6),
            "peak": float(np.max(np.abs(y))) if y.size else 0.0,
            "rms": float(np.sqrt(np.mean(np.square(y, dtype=np.float64)))) if y.size else 0.0,
            "nonFinite": False,
            "outputSha256": hashlib.sha256(blob).hexdigest(), "pcmSha256": hashlib.sha256(data).hexdigest(),
            "seed": req.seed, "nSteps": req.n_steps, "cfg": req.cfg,
            "voice": vfacts, "entries": info["entries"], "targetFrames": int(target_item["mel2note"].shape[1]),
            "modelSamples24k": int(audio.shape[0]), "samples24k": n24,
            "inferSeconds": round(infer_s, 4), "rtf": round(infer_s / (n24 / float(SR)), 4) if n24 else None,
            "totalSeconds": round(time.time() - t_all, 4), "mpsDriverBytes": self.mps_driver_bytes,
            "targetMeta": meta,
        }
        if req.facade_version >= 2:          # a v1 reply keeps exactly today's keys
            reply["control"] = req.control
            if info["substitutions"]:
                reply["substitutions"] = info["substitutions"]
        return reply
