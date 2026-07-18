# RVC voice-conversion sidecar (m10-p-2)

Loopback-only FastAPI facade over the MLX RVC fork
(`Acelogic/Retrieval-based-Voice-Conversion-MLX`, pinned commit
`eec7791a59eb`). The app / MCP integrate against THIS contract only — never
the fork's internals. Background: `docs/research/spike-m10p-vc.md`.

```
./install.sh    # idempotent; clones the pinned engine, builds the 3.11 venv,
                # stages the 4 shared Applio assets (sha256-verified, durable
                # cache ~/.cache/huggingface/daw-pro-rvc), derives the
                # CVE-2025-32434 safetensors + MLX .npz conversions
./run.sh        # boots 127.0.0.1:8002, writes .rvc.pid, logs to runtime/logs/
kill $(cat .rvc.pid)   # stop
```

## Contract v1 (stable)

Base URL `http://127.0.0.1:8002`. Errors are teaching-style:
`{"error": {"code": "<symbolic>", "message": "<what + what to do>"}}`.

| Endpoint | Shape |
|---|---|
| `GET /health` | ACE-style envelope `{"data": {service, version, engine, baseModelPresent, voiceCount, port}, "code": 0, "error": null}` |
| `GET /v1/voice/list` | `{"voices": [{id, name, state, hasIndex, createdAt}]}` — real user voices only; empty until p-6 training |
| `GET /v1/voice/{id}/status` | voice descriptor; `base` → builtin descriptor; unknown → 404 `unknownVoice` |
| `POST /v1/voice/convert` | in `{inputPath, voiceId, pitchSemitones?=0}` → `{outputPath, voiceId, inputSeconds, engineLoadSeconds, inferSeconds, rtf, sampleRate, realConversion, note}`; unknown voice → 404 |
| `POST /v1/voice/train` | in `{name, datasetDir, voiceId?, epochs?}` → validates shape, then 501 `trainingNotYetAvailable` (contract reserved — training ships with the Voice panel, p-5/p-6) |

`voiceId: "base"` is the reserved builtin smoke target: the generic
untrained Applio base synthesizer (sid=0). It exercises the full MLX
pipeline (HuBERT → RMVPE → TextEncoder/Flow/HiFiGAN-NSF) but is NOT a real
voice conversion. It never appears in `/v1/voice/list`.

## Voice store

`runtime/voices/<voiceId>/` with `model.npz` (MLX-runnable), optional
`model.pth` / `model.index`, optional `voice.json` (`{name, createdAt}`).
Voices are ONLY created by training on the user's own recordings —
no bundled voices, no celebrity/third-party checkpoints, ever.

## Shipping gates (open)

- The fork has **no LICENSE file** (pyproject self-declares MIT; GitHub
  licenseInfo null as of 2026-07-17). Resolve upstream or fall back to
  Applio's MIT code paths before shipping fork-derived code. Assets are MIT
  via `IAHispano/Applio`.
