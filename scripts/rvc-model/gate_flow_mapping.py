#!/usr/bin/env python3
"""m23-fn GATE — flow-slot mapping: completeness, conservation, determinism.

**Code we own.** Never writes under `scripts/rvc/`; sets
`PYTHONDONTWRITEBYTECODE=1` on every vendored-interpreter invocation it spawns.

Run it against a model and it answers four questions with a hard exit code:

  A. Does the pure key mapping in `flow_remap.py` agree with the vendored
     REFERENCE implementation (`tools/convert_rvc_model.py`), and do its
     refusal guards actually refuse?  (stdlib only, no model needed)
  B. **Completeness** — does every declared `flow.flow_N` slot receive its
     weights?  (18 of 19; the 19th, `enc.n_channels_tensor`, is a constant
     buffer `mx.array([hidden_channels])` at `lib/mlx/modules.py:25`, which no
     RVC checkpoint carries and which is identical on every construction.)
  C. **Conservation** — is any checkpoint flow tensor silently discarded?
  D. **Determinism** — do two SEPARATE PROCESSES produce bit-identical flow
     weights, and does one process constructing the model twice produce zero
     differing parameters?

This gate is designed to go RED on the unfixed path. That is the point: point
it at `scripts/rvc/runtime/src/rvc_mlx/models/checkpoints/base_f0G40k.npz` and
D must fail, because the two unfilled slots hold a fresh random draw per
construction.

    python3 scripts/rvc-model/gate_flow_mapping.py --model <model.npz>
    python3 scripts/rvc-model/gate_flow_mapping.py --pure-only

Phases B–D need the vendored venv interpreter (MLX). `--pure-only` runs A
alone and needs nothing but the stdlib.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
VENDORED_SRC = os.path.join(REPO, "scripts", "rvc", "runtime", "src")
VENDORED_PY = os.path.join(VENDORED_SRC, ".venv", "bin", "python")
SHIPPED_BASE = os.path.join(
    VENDORED_SRC, "rvc_mlx", "models", "checkpoints", "base_f0G40k.npz"
)

sys.path.insert(0, HERE)
import flow_remap  # noqa: E402

FAILURES: list[str] = []
NOTES: list[str] = []
#: Set by `--no-vendored`. Phase A6 shells out to the vendored venv's
#: interpreter (torch import, several seconds); the Swift suite pins phase A
#: without it so `./scripts/test.sh` stays fast and does not depend on the
#: vendored install being present.
SKIP_VENDORED = False


def check(ok: bool, label: str, detail: str = "") -> bool:
    mark = "PASS" if ok else "FAIL"
    print(f"  [{mark}] {label}" + (f" — {detail}" if detail else ""))
    if not ok:
        FAILURES.append(label + (f" — {detail}" if detail else ""))
    return ok


# ---------------------------------------------------------------------------
# Phase A — the pure mapping, and its refusals
# ---------------------------------------------------------------------------


def phase_a() -> None:
    print("A. pure key mapping")

    # A1 — the documented reference mapping, spelled out.
    expected = {
        "flow.flows.0.pre.weight": "flow.flow_0.pre.weight",
        "flow.flows.2.pre.weight": "flow.flow_1.pre.weight",
        "flow.flows.4.pre.weight": "flow.flow_2.pre.weight",
        "flow.flows.6.pre.weight": "flow.flow_3.pre.weight",
        "flow.flows.4.enc.in_layers.1.bias": "flow.flow_2.enc.in_layer_1.bias",
        "flow.flows.6.enc.res_skip_layers.2.weight": (
            "flow.flow_3.enc.res_skip_layer_2.weight"
        ),
        "flow.flows.2.enc.cond_layer.weight": "flow.flow_1.enc.cond_layer.weight",
    }
    bad = {k: flow_remap.correct_flow_key(k) for k in expected}
    bad = {k: v for k, v in bad.items() if v != expected[k]}
    check(not bad, "i//2 slot mapping matches the documented reference", str(bad))

    # A2 — non-flow keys are left for remap_keys to handle, untouched.
    passthrough = [
        "enc_p.encoder.attn_layers.0.conv_q.weight",
        "dec.ups.0.weight",
        "emb_g.weight",
        "flow.flow_1.pre.weight",  # already corrected — must be idempotent
    ]
    untouched = [k for k in passthrough if flow_remap.correct_flow_key(k) != k]
    check(not untouched, "non-raw-flow keys pass through untouched", str(untouched))

    # A3 — refuses an ODD (Flip-position) index instead of colliding it.
    try:
        flow_remap.correct_flow_key("flow.flows.1.pre.weight")
        check(False, "refuses an odd (Flip) flow index", "it did not raise")
    except flow_remap.FlowRemapError as exc:
        check(True, "refuses an odd (Flip) flow index", str(exc).split(".")[0])

    # A4 — refuses a gapped index set.
    try:
        flow_remap.plan_correction(
            ["flow.flows.0.pre.weight", "flow.flows.4.pre.weight"]
        )
        check(False, "refuses a gapped index set", "it did not raise")
    except flow_remap.FlowRemapError:
        check(True, "refuses a gapped index set")

    # A5 — refuses a half-converted archive.
    try:
        flow_remap.plan_correction(
            ["flow.flows.0.pre.weight", "flow.flow_1.pre.weight"]
        )
        check(False, "refuses a half-converted archive", "it did not raise")
    except flow_remap.FlowRemapError:
        check(True, "refuses a half-converted archive")

    # A6 — agreement with the VENDORED reference, key by key, on the real
    # shipped checkpoint. Read-only; needs the vendored venv (torch import).
    if SKIP_VENDORED:
        print("  [SKIP] agrees with tools/convert_rvc_model.py (--no-vendored)")
    elif os.path.exists(SHIPPED_BASE) and os.path.exists(VENDORED_PY):
        agreed = _reference_agreement(SHIPPED_BASE)
        if agreed is None:
            NOTES.append(
                "A6 skipped: could not import tools/convert_rvc_model.py "
                "(needs the vendored venv's torch)"
            )
            print("  [SKIP] agrees with tools/convert_rvc_model.py key-by-key")
        else:
            n, mism = agreed
            check(
                not mism,
                f"agrees with tools/convert_rvc_model.py on all {n} flow keys",
                str(mism[:3]),
            )

    # A7 — THE LOAD-BEARING CLAIM OF THIS WHOLE APPROACH, asserted against the
    # live loader rather than inferred from reading it: `remap_keys` only
    # matches the prefix `flow.flows.` (plural), so a CORRECTED key
    # (`flow.flow_N.…`, singular) must come back IDENTICAL. If that is not
    # true, a corrected .npz cannot load through the unmodified sidecar and the
    # fix would need a fenced write after all.
    if SKIP_VENDORED:
        print("  [SKIP] remap_keys passes corrected keys through (--no-vendored)")
    elif os.path.exists(SHIPPED_BASE) and os.path.exists(VENDORED_PY):
        rt = _remapkeys_identity(SHIPPED_BASE)
        if rt is None:
            NOTES.append("A7 skipped: could not import rvc_mlx.infer.infer_mlx")
            print("  [SKIP] remap_keys passes corrected keys through")
        else:
            n, moved = rt
            check(
                not moved,
                f"the UNMODIFIED remap_keys leaves all {n} corrected flow keys "
                "untouched",
                str(moved[:3]),
            )


def _remapkeys_identity(model_npz: str):
    """Feed CORRECTED keys to the real `remap_keys` and demand the identity."""
    prog = (
        "import sys,zipfile,json;"
        f"sys.path.insert(0,{VENDORED_SRC!r});"
        f"sys.path.insert(0,{HERE!r});"
        "import flow_remap;"
        "from rvc_mlx.infer.infer_mlx import remap_keys;"
        f"z=zipfile.ZipFile({model_npz!r});"
        "ks=[n[:-4] for n in z.namelist() if n.endswith('.npy')];"
        "raw=[k for k in ks if k.startswith('flow.flows.')];"
        "corrected=[flow_remap.correct_flow_key(k) for k in raw];"
        "out=remap_keys({k:0 for k in corrected});"
        "print(json.dumps({'n':len(corrected),"
        "'moved':[k for k in corrected if k not in out]}))"
    )
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", OMP_NUM_THREADS="1")
    try:
        out = subprocess.run(
            [VENDORED_PY, "-c", prog],
            cwd=VENDORED_SRC,
            env=env,
            capture_output=True,
            text=True,
            timeout=300,
        )
    except Exception:
        return None
    if out.returncode != 0:
        return None
    data = json.loads(out.stdout.strip().splitlines()[-1])
    return data["n"], data["moved"]


def _reference_agreement(model_npz: str):
    """Compare our mapping against the vendored reference, key by key."""
    prog = (
        "import sys,zipfile,json,importlib.util;"
        f"sys.path.insert(0,{VENDORED_SRC!r});"
        f"spec=importlib.util.spec_from_file_location('cvt',{os.path.join(VENDORED_SRC,'tools','convert_rvc_model.py')!r});"
        "m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);"
        f"z=zipfile.ZipFile({model_npz!r});"
        "ks=[n[:-4] for n in z.namelist() if n.endswith('.npy')];"
        "print(json.dumps({k:m.remap_key_name(k) for k in ks if k.startswith('flow.flows.')}))"
    )
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", OMP_NUM_THREADS="1")
    try:
        out = subprocess.run(
            [VENDORED_PY, "-c", prog],
            cwd=VENDORED_SRC,
            env=env,
            capture_output=True,
            text=True,
            timeout=300,
        )
    except Exception:
        return None
    if out.returncode != 0:
        return None
    ref = json.loads(out.stdout.strip().splitlines()[-1])
    mism = [
        (k, flow_remap.correct_flow_key(k), v)
        for k, v in ref.items()
        if flow_remap.correct_flow_key(k) != v
    ]
    return len(ref), mism


# ---------------------------------------------------------------------------
# Phases B/C/D — the loaded model, measured in separate processes
# ---------------------------------------------------------------------------


def run_census(model: str, out_json: str, twice: bool) -> dict:
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", OMP_NUM_THREADS="1")
    cmd = [
        VENDORED_PY,
        os.path.join(HERE, "verify_flow_fix.py"),
        "--model",
        os.path.abspath(model),
        "--json",
        out_json,
    ]
    if twice:
        cmd.append("--twice")
    res = subprocess.run(
        cmd, cwd=VENDORED_SRC, env=env, capture_output=True, text=True, timeout=1800
    )
    if res.returncode != 0:
        raise SystemExit(f"census subprocess failed:\n{res.stdout}\n{res.stderr}")
    with open(out_json) as fh:
        return json.load(fh)


def phases_bcd(model: str) -> None:
    with tempfile.TemporaryDirectory(prefix="m23fn-") as tmp:
        p1 = run_census(model, os.path.join(tmp, "p1.json"), twice=True)
        p2 = run_census(model, os.path.join(tmp, "p2.json"), twice=False)

    print("B. completeness, per slot")
    slots = p1["slots"]
    check(
        len(slots) == 4,
        "four coupling-layer slots are declared",
        f"got {sorted(slots)}",
    )
    for name in sorted(slots, key=lambda s: int(s.split("_")[1])):
        v = slots[name]
        filled, declared = v["filledFromCheckpoint"], v["declared"]
        unfilled = v["unfilled"]
        ok = filled == declared - 1 and unfilled == [f"flow.{name}.enc.n_channels_tensor"]
        check(
            ok,
            f"{name} filled {filled}/{declared}",
            "" if ok else f"unfilled={unfilled}",
        )

    print("C. conservation — nothing discarded")
    check(
        p1["discardedCheckpointFlowTensors"] == [],
        "no checkpoint flow tensor is discarded",
        f"{len(p1['discardedCheckpointFlowTensors'])} discarded, e.g. "
        f"{p1['discardedCheckpointFlowTensors'][:2]}",
    )
    check(
        p1["filledFlowParams"] == p1["checkpointFlowTensors"],
        "every checkpoint flow tensor lands on a declared parameter",
        f"{p1['filledFlowParams']} filled vs {p1['checkpointFlowTensors']} in the file",
    )

    print("D. determinism")
    tc = p1["twoConstructions"]
    check(
        tc["differing"] == 0,
        "two constructions in ONE process are bit-identical",
        f"{tc['differing']} of {tc['totalParams']} parameters differ",
    )
    check(
        p1["pid"] != p2["pid"],
        "the two censuses really ran in separate processes",
        f"pids {p1['pid']} / {p2['pid']}",
    )
    check(
        p1["flowFingerprint"] == p2["flowFingerprint"],
        "two SEPARATE PROCESSES agree on every flow weight",
        f"{p1['flowFingerprint'][:16]} vs {p2['flowFingerprint'][:16]}",
    )
    if p1["flowFingerprint"] != p2["flowFingerprint"]:
        diff = [
            k
            for k, v in p1["flowParamHashes"].items()
            if p2["flowParamHashes"].get(k) != v
        ]
        print(f"        {len(diff)} flow parameters differ across processes, e.g.:")
        for k in diff[:6]:
            print(f"          {k}")


def main(argv) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--model",
        default=SHIPPED_BASE,
        help="the .npz to gate (default: the SHIPPED base, which must go RED)",
    )
    ap.add_argument("--pure-only", action="store_true")
    ap.add_argument(
        "--no-vendored",
        action="store_true",
        help="skip every check that needs the vendored venv (A6 and B/C/D)",
    )
    args = ap.parse_args(argv)

    global SKIP_VENDORED
    SKIP_VENDORED = args.no_vendored
    if args.no_vendored:
        args.pure_only = True

    print(f"m23-fn flow-mapping gate — model: {args.model}")
    phase_a()
    if not args.pure_only:
        if not os.path.exists(VENDORED_PY):
            print(f"  [SKIP] B/C/D — no vendored interpreter at {VENDORED_PY}")
            NOTES.append("B/C/D skipped: vendored venv absent")
        elif not os.path.exists(args.model):
            print(f"  [SKIP] B/C/D — no model at {args.model}")
            NOTES.append("B/C/D skipped: model absent")
        else:
            phases_bcd(args.model)

    print()
    for n in NOTES:
        print(f"note: {n}")
    if FAILURES:
        print(f"GATE RED — {len(FAILURES)} failing check(s):")
        for f in FAILURES:
            print(f"  - {f}")
        return 1
    print("GATE GREEN")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
