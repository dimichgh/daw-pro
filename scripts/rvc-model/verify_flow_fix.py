#!/usr/bin/env python3
"""m23-fn proof harness: flow-slot COMPLETENESS and cross-process DETERMINISM.

**Code we own.** Lives outside `scripts/rvc/`, writes nothing into it, and
must be run with `PYTHONDONTWRITEBYTECODE=1` because it imports the vendored
package (which is read-only, `.pyc` included).

It measures, through the **shipped loader** (`RVC_MLX`, exactly what
`scripts/rvc/server.py:107` constructs), three things a slot-mapping fix has
to establish:

1. **Completeness, per slot.** For every declared `flow.flow_N` parameter, was
   a value actually supplied by the checkpoint? `load_weights(..., strict=False)`
   at `infer_mlx.py:248` makes an unsupplied parameter a SILENT success, so the
   only way to see it is to ask the post-remap weight dict directly.
2. **Conservation.** Every tensor in the checkpoint's flow block reaches a
   declared parameter — nothing is discarded.
3. **Determinism.** A hash of every flow parameter. Two separate processes must
   agree. On the unfixed path they cannot, because the unfilled slots hold a
   fresh `mlx.nn` draw per construction.

Usage (cwd MUST be the vendored src root, as `server.py:77` does):

    PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=1 \
      <venv>/bin/python verify_flow_fix.py --model <model.npz> --json out.json

    ... --twice     also construct the model TWICE in this process and report
                    which parameters differ between the two constructions.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys

_SLOT_RE = re.compile(r"^flow\.flow_(\d+)\.")
# `flow.flow_0.enc.in_layers.0.weight` is MLX's *list* view of the same array
# `flow.flow_0.enc.in_layer_0.weight` exposes as a named property. Counting
# both double-counts every WaveNet conv. The named form is the one
# `remap_keys` targets and the one `load_weights` fills.
_ALIAS_RE = re.compile(r"\.(in_layers|res_skip_layers|convs1|convs2|ups|noise_convs|resblocks)\.\d+\.")


def _flatten(params):
    from mlx.utils import tree_flatten

    return dict(tree_flatten(params))


def _hash_array(arr) -> str:
    import numpy as np

    return hashlib.sha256(np.asarray(arr).tobytes()).hexdigest()[:32]


def census(model_path: str, twice: bool = False) -> dict:
    import mlx.core as mx
    from rvc_mlx.infer.infer_mlx import RVC_MLX, remap_keys

    # What the loader was actually handed, for THIS file, through the
    # unmodified remapper.
    supplied = set(remap_keys(dict(mx.load(model_path))).keys())
    raw_flow_tensors = [k for k in mx.load(model_path).keys() if k.startswith("flow.")]

    engine = RVC_MLX(model_path)
    flat = _flatten(engine.net_g.parameters())

    slots: dict[str, dict] = {}
    filled_names: set[str] = set()
    for name in sorted(flat):
        m = _SLOT_RE.match(name)
        if not m:
            continue
        if _ALIAS_RE.search(name):
            continue  # list-view alias of a named property; same array
        slot = f"flow_{m.group(1)}"
        entry = slots.setdefault(
            slot, {"declared": 0, "filledFromCheckpoint": 0, "unfilled": []}
        )
        entry["declared"] += 1
        if name in supplied:
            entry["filledFromCheckpoint"] += 1
            filled_names.add(name)
        else:
            entry["unfilled"].append(name)

    # Conservation: every flow tensor the checkpoint carries must have landed
    # on a declared parameter.
    supplied_flow = {k for k in supplied if k.startswith("flow.")}
    declared_flow = {n for n in flat if _SLOT_RE.match(n)}
    discarded = sorted(supplied_flow - declared_flow)

    # Determinism fingerprint: hash of every flow parameter, and one rollup.
    per_param = {}
    for name in sorted(declared_flow):
        if _ALIAS_RE.search(name):
            continue
        per_param[name] = _hash_array(flat[name])
    rollup = hashlib.sha256(
        "".join(f"{k}={v};" for k, v in sorted(per_param.items())).encode()
    ).hexdigest()

    report = {
        "pid": os.getpid(),
        "model": os.path.abspath(model_path),
        "checkpointFlowTensors": len(raw_flow_tensors),
        "suppliedFlowKeysAfterRemap": len(supplied_flow),
        "slots": {k: slots[k] for k in sorted(slots, key=lambda s: int(s.split("_")[1]))},
        "declaredFlowParams": len(per_param),
        "filledFlowParams": len(filled_names),
        "discardedCheckpointFlowTensors": discarded,
        "flowParamHashes": per_param,
        "flowFingerprint": rollup,
    }

    if twice:
        import numpy as np

        engine2 = RVC_MLX(model_path)
        flat2 = _flatten(engine2.net_g.parameters())
        differ = []
        for name in sorted(flat):
            if name not in flat2:
                continue
            a, b = np.asarray(flat[name]), np.asarray(flat2[name])
            if a.shape != b.shape or not np.array_equal(a, b):
                differ.append(name)
        report["twoConstructions"] = {
            "totalParams": len(flat),
            "differing": len(differ),
            "differingNames": differ,
            "differingOutsideFlow": [n for n in differ if not n.startswith("flow.")],
        }
    return report


def main(argv) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--json", help="write the report here")
    ap.add_argument("--twice", action="store_true")
    args = ap.parse_args(argv)

    rep = census(args.model, twice=args.twice)
    if args.json:
        with open(args.json, "w") as fh:
            json.dump(rep, fh, indent=2)
    small = {k: v for k, v in rep.items() if k != "flowParamHashes"}
    print(json.dumps(small, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
