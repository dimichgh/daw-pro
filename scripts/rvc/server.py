"""RVC voice-conversion sidecar facade — M10 (m10-p-2).

A STABLE, narrow v1 HTTP contract over the MLX RVC fork so the app / MCP
never see the underlying library's internals. Served loopback-only on
127.0.0.1:8002 (hard security rule — the bind host is not configurable).

Contract v1 (the shape p-3's client actor and the MCP tools build against):

  GET  /health                 ACE-style envelope {"data": {...}, "code": 0,
                               "error": null} — mirrors the ACE-Step sidecar
                               health convention SidecarManager already parses.
  GET  /v1/voice/list          {"voices": [...]} — real scan of the voice
                               store (runtime/voices/). Empty until p-6
                               trains the first voice from the USER'S OWN
                               recordings. Never bundled, never celebrity.
  GET  /v1/voice/{id}/status   Voice descriptor; unknown id -> 404 teaching
                               error. "base" is a reserved builtin: the
                               generic untrained Applio base synthesizer
                               (smoke target, not a voice — it does not
                               appear in /v1/voice/list).
  POST /v1/voice/convert       REAL conversion through the fork's MLX
                               pipeline (HuBERT content encode -> RMVPE
                               pitch -> TextEncoder/Flow/HiFiGAN-NSF).
                               Body: {"inputPath", "voiceId",
                               "pitchSemitones"?}. Returns output path +
                               timing. voiceId "base" runs the untrained
                               base target (spike's proven sid=0 path).
  POST /v1/voice/train         Contract reserved: validates the request
                               shape, then answers a structured 501 —
                               training ships with the Voice panel
                               (m10-p-5/p-6). DELIBERATE choice over wiring
                               a "real" job now: the m10-p-1 training probe
                               was a synthetic-batch step-rate probe, not
                               the fork's full preprocess/feature/train/
                               convert pipeline — wiring that is p-6 scope,
                               not trivially safe from here.

Error style: teaching errors — {"error": {"code": "<symbolic>", "message":
"<what happened + what to do instead>"}} with an honest HTTP status.

Run via run.sh (sets OMP_NUM_THREADS=1 — faiss segfault guard, spike
delta #4 — plus pidfile + log redirection). The engine resolves model paths
relative to its src root, so this process chdirs there at startup.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import sys
import threading
import time
from pathlib import Path
from typing import Any, Optional

# Defense in depth: run.sh sets this too. Must happen before faiss import.
os.environ.setdefault("OMP_NUM_THREADS", "1")

FACADE_VERSION = "0.1.0"

SCRIPT_DIR = Path(__file__).resolve().parent
RUNTIME_DIR = Path(os.environ.get("RVC_RUNTIME_DIR", SCRIPT_DIR / "runtime"))
SRC_DIR = Path(os.environ.get("RVC_SRC_DIR", RUNTIME_DIR / "src"))
VOICES_DIR = Path(os.environ.get("RVC_VOICES_DIR", RUNTIME_DIR / "voices"))
OUT_DIR = Path(os.environ.get("RVC_OUT_DIR", RUNTIME_DIR / "out"))
BASE_MODEL_NPZ = SRC_DIR / "rvc_mlx" / "models" / "checkpoints" / "base_f0G40k.npz"
API_PORT = int(os.environ.get("RVC_API_PORT", "8002"))

if not SRC_DIR.is_dir():
    sys.exit(
        f"RVC engine source not found at {SRC_DIR} — run scripts/rvc/install.sh first."
    )

# The fork resolves every model path relative to the src root (cwd).
os.chdir(SRC_DIR)
sys.path.insert(0, str(SRC_DIR))

from fastapi import FastAPI, Request  # noqa: E402
from fastapi.exceptions import RequestValidationError  # noqa: E402
from fastapi.responses import JSONResponse  # noqa: E402
from pydantic import BaseModel  # noqa: E402

app = FastAPI(title="DAW Pro RVC voice-conversion facade", version=FACADE_VERSION)

# ---------------------------------------------------------------------------
# Engine management. MLX inference is not assumed re-entrant: conversions are
# serialized behind one lock. Engines are lazy-loaded (keeps boot/health
# fast) and cached per voice id.
# ---------------------------------------------------------------------------

_engine_lock = threading.Lock()
_engines: dict[str, Any] = {}


def _load_engine(voice_id: str, model_path: Path):
    """Load (or return cached) RVC_MLX engine for a model .npz."""
    engine = _engines.get(voice_id)
    if engine is not None:
        return engine
    from rvc_mlx.infer.infer_mlx import RVC_MLX  # heavy import — lazy

    # The fork prints DEBUG lines on load; keep them in the server log but
    # off the hot response path is not a concern here (offline HTTP call).
    engine = RVC_MLX(str(model_path))
    _engines[voice_id] = engine
    return engine


# ---------------------------------------------------------------------------
# Teaching-error helpers
# ---------------------------------------------------------------------------


def teaching_error(status: int, code: str, message: str) -> JSONResponse:
    return JSONResponse(
        status_code=status,
        content={"error": {"code": code, "message": message}},
    )


@app.exception_handler(RequestValidationError)
async def validation_teaching(request: Request, exc: RequestValidationError):
    problems = "; ".join(
        f"{'.'.join(str(p) for p in err.get('loc', []) if p != 'body')}: {err.get('msg')}"
        for err in exc.errors()
    )
    return teaching_error(
        422,
        "invalidRequest",
        f"request body does not match the v1 contract ({problems}). "
        "See scripts/rvc/README.md for the exact shapes.",
    )


# ---------------------------------------------------------------------------
# Voice store — runtime/voices/<voiceId>/ with model.npz (MLX-runnable),
# optional model.pth / model.index, optional voice.json metadata. Voices are
# ONLY ever created by training on the user's own recordings (p-5/p-6).
# ---------------------------------------------------------------------------


def _voice_descriptor(voice_dir: Path) -> dict[str, Any]:
    meta: dict[str, Any] = {}
    meta_path = voice_dir / "voice.json"
    if meta_path.is_file():
        with contextlib.suppress(Exception):
            meta = json.loads(meta_path.read_text())
    npz = voice_dir / "model.npz"
    pth = voice_dir / "model.pth"
    index = voice_dir / "model.index"
    if npz.is_file():
        state = "ready"
    elif pth.is_file():
        state = "needsConversion"  # .pth exists but MLX .npz not derived yet
    else:
        state = "incomplete"
    return {
        "id": voice_dir.name,
        "name": meta.get("name", voice_dir.name),
        "state": state,
        "hasIndex": index.is_file(),
        "createdAt": meta.get("createdAt"),
    }


def _scan_voices() -> list[dict[str, Any]]:
    if not VOICES_DIR.is_dir():
        return []
    return [
        _voice_descriptor(d)
        for d in sorted(VOICES_DIR.iterdir())
        if d.is_dir() and not d.name.startswith(".")
    ]


def _base_descriptor() -> dict[str, Any]:
    return {
        "id": "base",
        "name": "Base (untrained smoke target)",
        "state": "ready" if BASE_MODEL_NPZ.is_file() else "incomplete",
        "kind": "builtin",
        "trained": False,
        "note": (
            "generic Applio base synthesizer (sid=0, untrained 109-speaker "
            "embedding) — exercises the full pipeline but is NOT a real "
            "voice conversion target; real voices arrive via training on "
            "the user's own recordings (p-6)"
        ),
    }


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


@app.get("/health")
def health():
    # Mirrors the ACE-Step sidecar health envelope ({"data": ..., "code",
    # "error"}) that SidecarManager already knows how to parse.
    voices = _scan_voices()
    return {
        "data": {
            "service": "rvc-vc-facade",
            "version": FACADE_VERSION,
            "engine": "Acelogic/Retrieval-based-Voice-Conversion-MLX",
            "baseModelPresent": BASE_MODEL_NPZ.is_file(),
            "voiceCount": len(voices),
            "port": API_PORT,
        },
        "code": 0,
        "error": None,
    }


@app.get("/v1/voice/list")
def voice_list():
    # Real user voices only — the "base" builtin is a smoke target, not a
    # voice, and deliberately does not appear here.
    return {"voices": _scan_voices()}


@app.get("/v1/voice/{voice_id}/status")
def voice_status(voice_id: str):
    if voice_id == "base":
        return _base_descriptor()
    voice_dir = VOICES_DIR / voice_id
    if voice_dir.is_dir():
        return _voice_descriptor(voice_dir)
    return teaching_error(
        404,
        "unknownVoice",
        f"no voice named '{voice_id}' exists. List real voices with "
        "GET /v1/voice/list (empty until you train one from your own "
        "recordings — training ships with the Voice panel, m10-p-5/p-6). "
        "The reserved id 'base' is always available as an untrained "
        "pipeline smoke target.",
    )


class ConvertRequest(BaseModel):
    inputPath: str
    voiceId: str
    pitchSemitones: int = 0


@app.post("/v1/voice/convert")
def voice_convert(req: ConvertRequest):
    # -- resolve the target model -----------------------------------------
    if req.voiceId == "base":
        model_path = BASE_MODEL_NPZ
        index_path = ""
        index_rate = 0.0
        if not model_path.is_file():
            return teaching_error(
                500,
                "baseModelMissing",
                f"the base smoke-target model is missing at {model_path} — "
                "re-run scripts/rvc/install.sh (Stage 7 derives it).",
            )
    else:
        voice_dir = VOICES_DIR / req.voiceId
        if not voice_dir.is_dir():
            return teaching_error(
                404,
                "unknownVoice",
                f"no voice named '{req.voiceId}' exists to convert with. "
                "List real voices with GET /v1/voice/list, or use voiceId "
                "'base' for the untrained pipeline smoke target.",
            )
        model_path = voice_dir / "model.npz"
        if not model_path.is_file():
            return teaching_error(
                409,
                "voiceNotReady",
                f"voice '{req.voiceId}' exists but has no MLX model "
                "(model.npz) yet — check GET /v1/voice/"
                f"{req.voiceId}/status.",
            )
        idx = voice_dir / "model.index"
        index_path = str(idx) if idx.is_file() else ""
        index_rate = 0.75 if index_path else 0.0

    # -- validate the input audio -----------------------------------------
    if not (-24 <= req.pitchSemitones <= 24):
        return teaching_error(
            400,
            "pitchOutOfRange",
            f"pitchSemitones {req.pitchSemitones} is outside the sane "
            "[-24, 24] window.",
        )
    input_path = Path(req.inputPath)
    if not input_path.is_file():
        return teaching_error(
            400,
            "inputNotFound",
            f"no readable audio file at '{req.inputPath}' — pass an "
            "absolute path to an existing audio file on this machine.",
        )
    import soundfile as sf

    try:
        info = sf.info(str(input_path))
        input_seconds = info.frames / float(info.samplerate)
    except Exception as exc:  # noqa: BLE001 — teach whatever sf raised
        return teaching_error(
            400,
            "inputUnreadable",
            f"'{req.inputPath}' exists but could not be read as audio "
            f"({exc}) — supply a WAV/FLAC/OGG file soundfile can decode.",
        )

    # -- run the real MLX pipeline (serialized) ----------------------------
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    out_path = OUT_DIR / f"convert-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}-{req.voiceId}-{os.getpid()}-{threading.get_ident() % 10000}.wav"
    with _engine_lock:
        t0 = time.perf_counter()
        engine = _load_engine(req.voiceId, model_path)
        load_seconds = time.perf_counter() - t0
        t1 = time.perf_counter()
        # The fork prints progress to stdout; keep the server log readable
        # by letting it flow (run.sh redirects stdout to the runtime log).
        engine.infer(
            str(input_path),
            str(out_path),
            pitch=req.pitchSemitones,
            f0_method="rmvpe",  # only MLX-supported pitch method (spike)
            index_path=index_path,
            index_rate=index_rate,
        )
        infer_seconds = time.perf_counter() - t1
    if not out_path.is_file():
        return teaching_error(
            500,
            "conversionFailed",
            "the pipeline ran but produced no output file — see the "
            "facade log under runtime/logs/ for the engine's own error.",
        )

    return {
        "outputPath": str(out_path),
        "voiceId": req.voiceId,
        "inputSeconds": round(input_seconds, 3),
        "engineLoadSeconds": round(load_seconds, 3),
        "inferSeconds": round(infer_seconds, 3),
        "rtf": round(input_seconds / infer_seconds, 2) if infer_seconds > 0 else None,
        "sampleRate": engine.tgt_sr,
        "realConversion": req.voiceId != "base",
        "note": (
            None
            if req.voiceId != "base"
            else "base is the untrained generic target — output exercises "
            "the full pipeline but is not a conversion to any real voice"
        ),
    }


class TrainRequest(BaseModel):
    name: str
    datasetDir: str
    voiceId: Optional[str] = None
    epochs: Optional[int] = None


@app.post("/v1/voice/train")
def voice_train(req: TrainRequest):
    # Shape validation first, so callers integrating early get real
    # feedback on their request construction.
    if req.voiceId == "base" or req.name == "base":
        return teaching_error(
            400,
            "reservedVoiceId",
            "'base' is the reserved builtin smoke target and can never be "
            "trained over — pick another name.",
        )
    if not Path(req.datasetDir).is_dir():
        return teaching_error(
            400,
            "datasetNotFound",
            f"datasetDir '{req.datasetDir}' is not a directory — pass an "
            "absolute path to a folder of the user's OWN recordings.",
        )
    return teaching_error(
        501,
        "trainingNotYetAvailable",
        "contract reserved — training ships with the Voice panel "
        f"(m10-p-5/p-6). Your request validated OK (voice '{req.name}', "
        f"dataset '{req.datasetDir}'); once training lands, this same "
        "request shape will start a real training job on your own "
        "recordings. No third-party or celebrity voice models, ever.",
    )


if __name__ == "__main__":
    import uvicorn

    # Loopback ONLY — hardcoded on purpose; never make the host configurable.
    uvicorn.run(app, host="127.0.0.1", port=API_PORT, log_level="info")
