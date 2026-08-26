#!/usr/bin/env python3
"""Correct the RVC normalising-flow slot mapping in an MLX ``.npz`` checkpoint.

m23-fn. **Code we own.** Nothing here reads, writes, imports or executes
anything under ``scripts/rvc/`` — that directory is READ-ONLY for this project.
This module is stdlib-only (``zipfile``/``argparse``): no numpy, no MLX, no
torch, no vendored import. Run it with the system interpreter.

WHAT IS WRONG WITH THE SHIPPED PATH
-----------------------------------
A PyTorch RVC checkpoint stores its ``ResidualCouplingBlock`` as an
interleaved list ``[Layer, Flip, Layer, Flip, ...]``, so the *layers* live at
the EVEN indices only::

    flow.flows.0.*   flow.flows.2.*   flow.flows.4.*   flow.flows.6.*

The MLX port declares four named slots — ``flow.flow_0 … flow.flow_3``
(``rvc_mlx/lib/mlx/residuals.py``: ``for i, f in enumerate(self.flows):
setattr(self, f"flow_{i}", f)``) — and runs them as an ordered chain, in
reverse, at inference. So ``flow_i`` IS the i-th coupling layer; the
permutation is load-bearing and is not free to choose.

Two implementations of the checkpoint→slot mapping exist in the vendored tree
and they disagree:

* ``runtime/src/tools/convert_rvc_model.py``  (the REFERENCE, correct)::

        flow_idx = int(parts[2])
        # PyTorch flow list contains [Layer, Flip, Layer, Flip...]
        # We map Layer indices (0, 2, 4...) to MLX indices (0, 1, 2...)
        real_idx = flow_idx // 2

* ``runtime/src/rvc_mlx/infer/infer_mlx.py`` (``remap_keys``, what actually
  RUNS at load time) uses ``f_idx = parts[2]`` VERBATIM — no ``// 2``.

Verbatim renaming produces ``flow_0, flow_2, flow_4, flow_6``.  Only
``flow_0`` and ``flow_2`` exist, so:

* ``flow_1`` and ``flow_3`` receive NOTHING.  ``infer_mlx.py``'s
  ``load_weights(..., strict=False)`` turns that into a silent success and the
  two slots keep whatever ``mlx.nn`` drew at construction — **fresh random
  values on every single load**.
* ``flow_2`` holds the checkpoint's flow 2, which belongs in ``flow_1``.
* The checkpoint's ``flow.flows.4.*`` and ``flow.flows.6.*`` — 36 tensors —
  are silently discarded.

It hid because index 0 is the one place the two implementations agree.

WHY A KEY REWRITE IN A FILE WE OWN IS SUFFICIENT — NO FENCED EDIT
------------------------------------------------------------------
``remap_keys`` only rewrites keys that start with ``flow.flows.`` (PLURAL).
A key already in MLX slot form — ``flow.flow_1.…`` (SINGULAR) — does not match
that prefix and passes through the loader untouched. So an ``.npz`` that
already carries corrected slot names loads correctly through the COMPLETELY
UNMODIFIED sidecar and loader.  (Verified empirically; see
``verify_flow_fix.py``.)

Correcting the mapping is therefore a pure KEY RENAME: not one byte of tensor
data changes.  An ``.npz`` is a zip of ``<key>.npy`` members, so this tool
rewrites the archive member names and copies every payload byte-for-byte.

GUARDS (why this is not just ``//2`` sprinkled on a string)
-----------------------------------------------------------
The reference's own comment hedges — *"Flip modules (1, 3, 5...) have no
weights usually, but if they did, we'd skip or handle them."*  ``//2`` on an
ODD index collides with its even neighbour and would silently overwrite a real
coupling layer.  So this tool refuses rather than guesses:

* every ``flow.flows.<i>`` index must be EVEN;
* the indices must be exactly ``0, 2, 4, … 2(n-1)`` — no gaps;
* the rename must be INJECTIVE (no two sources land on one destination);
* no destination may collide with a key already in the archive;
* the number of flow tensors OUT must equal the number IN — nothing dropped.

Any violation raises ``FlowRemapError`` and no output file is written.

USE
---
    python3 scripts/rvc-model/flow_remap.py inspect  <model.npz>
    python3 scripts/rvc-model/flow_remap.py correct  <in.npz> <out.npz>

``inspect`` prints (and with ``--json`` emits) the per-slot tensor census of an
archive as the MLX loader will see it.  ``correct`` writes a corrected copy.

WHERE THIS MUST BE WIRED IN
---------------------------
Every ``.npz`` this project produces or hands to the RVC facade must pass
through ``correct_npz``.  Today that is exactly one prospective site: the
``.pth`` → ``.npz`` conversion of an imported third-party model
(``Sources/AIServices/VoiceModelImport.swift``, roadmap **m23-di-2b**), which
is BLOCKED on the user's decision and therefore does not exist yet.  When it
lands it must call this tool on the converter's output, because the vendored
converter ``tools/convert_pth_to_mlx.py`` emits raw ``flow.flows.{0,2,4,6}``
keys and has no flow-index logic at all.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import zipfile
from typing import Dict, Iterable, List, Tuple

__all__ = [
    "FlowRemapError",
    "RAW_FLOW_PREFIX",
    "MLX_FLOW_PREFIX",
    "correct_flow_key",
    "plan_correction",
    "slot_census",
    "correct_npz",
]

#: Prefix of a RAW (PyTorch-ordered) flow key, as ``convert_pth_to_mlx.py``
#: emits it and as ``remap_keys`` matches it.  Note the plural.
RAW_FLOW_PREFIX = "flow.flows."

#: Prefix of a CORRECTED (MLX slot-form) flow key.  Note the singular — this
#: is exactly why ``remap_keys`` passes it through untouched.
MLX_FLOW_PREFIX = "flow.flow_"

_MLX_SLOT_RE = re.compile(r"^flow\.flow_(\d+)\.")


class FlowRemapError(RuntimeError):
    """A checkpoint whose flow keys cannot be corrected without guessing."""


def correct_flow_key(key: str) -> str:
    """Map ONE raw ``flow.flows.<even>.…`` key to its MLX slot form.

    Reproduces ``remap_keys``' flow branch verbatim EXCEPT for the index, which
    takes the reference implementation's ``// 2``.  Non-flow keys are returned
    unchanged so that the rest of ``remap_keys`` still handles them at load
    time exactly as it does today.

    Raises ``FlowRemapError`` on an odd (Flip-position) index rather than
    silently colliding it with its even neighbour.
    """
    if not key.startswith(RAW_FLOW_PREFIX):
        return key

    parts = key.split(".")
    try:
        raw_idx = int(parts[2])
    except (IndexError, ValueError):
        raise FlowRemapError(
            f"cannot read a flow index out of {key!r} — expected "
            f"'flow.flows.<n>.…'"
        )
    if raw_idx % 2 != 0:
        raise FlowRemapError(
            f"{key!r} sits at ODD PyTorch flow index {raw_idx}, which is a "
            "Flip position. The reference mapping (i // 2) would collide it "
            "with the coupling layer at index "
            f"{raw_idx - 1} and silently overwrite real weights. Refusing: "
            "this checkpoint needs a mapping decision a tool cannot make."
        )
    slot = raw_idx // 2

    # --- remap_keys' own flow branch, index substituted ---------------------
    if "in_layers" in key:
        l_idx = parts[5]
        rest = parts[6:]
        new_key = f"flow.flow_{slot}.enc.in_layer_{l_idx}.{'.'.join(rest)}"
    elif "res_skip_layers" in key:
        l_idx = parts[5]
        rest = parts[6:]
        new_key = f"flow.flow_{slot}.enc.res_skip_layer_{l_idx}.{'.'.join(rest)}"
    else:
        rest = parts[3:]
        new_key = f"flow.flow_{slot}.{'.'.join(rest)}"

    # remap_keys applies this to EVERY key it returns, as a separate `if`
    # after the elif chain — so a corrected key must carry it too, or a
    # LayerNorm-carrying flow variant would arrive misnamed.
    if new_key.endswith(".gamma"):
        new_key = new_key[: -len(".gamma")] + ".weight"
    elif new_key.endswith(".beta"):
        new_key = new_key[: -len(".beta")] + ".bias"
    return new_key


def plan_correction(keys: Iterable[str]) -> Dict[str, object]:
    """Build and CHECK the full rename before touching a file.

    Returns a report dict; raises ``FlowRemapError`` if the rename would drop,
    collide or reorder anything.
    """
    keys = list(keys)
    key_set = set(keys)
    raw = [k for k in keys if k.startswith(RAW_FLOW_PREFIX)]
    already = [k for k in keys if k.startswith(MLX_FLOW_PREFIX)]

    if raw and already:
        raise FlowRemapError(
            f"archive mixes {len(raw)} raw 'flow.flows.*' keys with "
            f"{len(already)} corrected 'flow.flow_*' keys — half-converted "
            "input, refusing to guess which half is authoritative."
        )

    raw_indices = sorted({int(k.split(".")[2]) for k in raw}) if raw else []
    if raw_indices:
        expected = list(range(0, 2 * len(raw_indices), 2))
        if raw_indices != expected:
            raise FlowRemapError(
                f"PyTorch flow indices {raw_indices} are not the expected "
                f"interleaved-layer set {expected} — a gap or an odd index "
                "means the [Layer, Flip, …] assumption does not hold for this "
                "checkpoint."
            )

    mapping: Dict[str, str] = {}
    reverse: Dict[str, str] = {}
    for k in raw:
        new_key = correct_flow_key(k)
        if new_key in reverse:
            raise FlowRemapError(
                f"rename is not injective: {k!r} and {reverse[new_key]!r} both "
                f"map to {new_key!r}"
            )
        if new_key in key_set:
            raise FlowRemapError(
                f"rename would collide with an existing archive key: "
                f"{k!r} -> {new_key!r}"
            )
        reverse[new_key] = k
        mapping[k] = new_key

    if len(mapping) != len(raw):
        raise FlowRemapError(
            f"count not conserved: {len(raw)} flow tensors in, "
            f"{len(mapping)} mapped out"
        )

    census = slot_census(list(mapping.values()) or already)
    return {
        "totalKeys": len(keys),
        "rawFlowKeys": len(raw),
        "alreadyCorrectedFlowKeys": len(already),
        "pytorchFlowIndices": raw_indices,
        "mapping": mapping,
        "slotCensus": census,
        "droppedKeys": [],
    }


def slot_census(keys: Iterable[str]) -> Dict[str, int]:
    """Count tensors per MLX slot (``flow_0``…) for already-corrected keys."""
    out: Dict[str, int] = {}
    for k in keys:
        m = _MLX_SLOT_RE.match(k)
        if m:
            out[f"flow_{m.group(1)}"] = out.get(f"flow_{m.group(1)}", 0) + 1
    return dict(sorted(out.items(), key=lambda kv: int(kv[0].split("_")[1])))


def _member_to_key(name: str) -> str:
    return name[:-4] if name.endswith(".npy") else name


def _key_to_member(key: str, original_member: str) -> str:
    return key + ".npy" if original_member.endswith(".npy") else key


def correct_npz(src_path: str, dst_path: str) -> Dict[str, object]:
    """Write a slot-corrected copy of ``src_path`` to ``dst_path``.

    Pure key rename: every payload is copied byte-for-byte, so the tensor data
    of the output is bit-identical to the input. Returns the plan report,
    extended with a byte-conservation proof.
    """
    src_path = os.path.abspath(src_path)
    dst_path = os.path.abspath(dst_path)
    if os.path.realpath(src_path) == os.path.realpath(dst_path):
        raise FlowRemapError("refusing to correct an archive in place")

    with zipfile.ZipFile(src_path, "r") as zin:
        infos = zin.infolist()
        keys = [_member_to_key(i.filename) for i in infos]
        report = plan_correction(keys)
        mapping: Dict[str, str] = report["mapping"]  # type: ignore[assignment]

        payload_bytes_in = 0
        payload_bytes_out = 0
        tmp_path = dst_path + ".partial"
        with zipfile.ZipFile(tmp_path, "w", zipfile.ZIP_STORED) as zout:
            for info in infos:
                key = _member_to_key(info.filename)
                new_key = mapping.get(key, key)
                data = zin.read(info.filename)
                payload_bytes_in += len(data)
                out_info = zipfile.ZipInfo(
                    _key_to_member(new_key, info.filename),
                    date_time=info.date_time,
                )
                out_info.compress_type = zipfile.ZIP_STORED
                out_info.external_attr = info.external_attr
                zout.writestr(out_info, data)
                payload_bytes_out += len(data)

    os.replace(tmp_path, dst_path)

    # Read the result back and prove, from the FILE, that nothing moved.
    with zipfile.ZipFile(src_path, "r") as zin, zipfile.ZipFile(dst_path, "r") as zout:
        src_payloads = {_member_to_key(i.filename): zin.read(i.filename) for i in zin.infolist()}
        dst_payloads = {_member_to_key(i.filename): zout.read(i.filename) for i in zout.infolist()}
    identical = 0
    for old_key, blob in src_payloads.items():
        new_key = mapping.get(old_key, old_key)
        if new_key in dst_payloads and dst_payloads[new_key] == blob:
            identical += 1
    report["outputKeys"] = len(dst_payloads)
    report["payloadBytesIn"] = payload_bytes_in
    report["payloadBytesOut"] = payload_bytes_out
    report["payloadsBitIdentical"] = identical
    report["source"] = src_path
    report["destination"] = dst_path
    if identical != len(src_payloads) or len(dst_payloads) != len(src_payloads):
        raise FlowRemapError(
            f"post-write check failed: {identical}/{len(src_payloads)} payloads "
            f"bit-identical, {len(dst_payloads)} output keys vs "
            f"{len(src_payloads)} input keys"
        )
    return report


def inspect_npz(path: str) -> Dict[str, object]:
    with zipfile.ZipFile(path, "r") as z:
        keys = [_member_to_key(i.filename) for i in z.infolist()]
    raw = [k for k in keys if k.startswith(RAW_FLOW_PREFIX)]
    already = [k for k in keys if k.startswith(MLX_FLOW_PREFIX)]
    # What the UNMODIFIED loader (remap_keys, verbatim index) will name them.
    loader_names: List[str] = []
    for k in raw:
        parts = k.split(".")
        loader_names.append(f"flow.flow_{parts[2]}." + ".".join(parts[3:]))
    return {
        "path": os.path.abspath(path),
        "totalKeys": len(keys),
        "rawFlowKeys": len(raw),
        "correctedFlowKeys": len(already),
        "asLoadedToday": slot_census(loader_names + already),
        "asLoadedCorrected": slot_census(
            [correct_flow_key(k) for k in raw] + already
        ),
    }


def _main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_i = sub.add_parser("inspect", help="per-slot census of an .npz")
    p_i.add_argument("npz")
    p_i.add_argument("--json", action="store_true")

    p_c = sub.add_parser("correct", help="write a slot-corrected copy")
    p_c.add_argument("src")
    p_c.add_argument("dst")
    p_c.add_argument("--json", action="store_true")

    args = ap.parse_args(argv)
    try:
        if args.cmd == "inspect":
            rep = inspect_npz(args.npz)
            if args.json:
                print(json.dumps(rep, indent=2))
            else:
                print(f"{rep['path']}")
                print(f"  tensors                : {rep['totalKeys']}")
                print(f"  raw flow.flows.* keys  : {rep['rawFlowKeys']}")
                print(f"  corrected flow.flow_*  : {rep['correctedFlowKeys']}")
                print(f"  slots AS LOADED TODAY  : {rep['asLoadedToday']}")
                print(f"  slots AFTER CORRECTION : {rep['asLoadedCorrected']}")
        else:
            rep = correct_npz(args.src, args.dst)
            rep_small = {k: v for k, v in rep.items() if k != "mapping"}
            if args.json:
                print(json.dumps(rep_small, indent=2))
            else:
                print(f"wrote {rep['destination']}")
                print(f"  tensors in/out         : {rep['totalKeys']}/{rep['outputKeys']}")
                print(f"  flow tensors remapped  : {rep['rawFlowKeys']}")
                print(f"  per-slot census        : {rep['slotCensus']}")
                print(f"  payload bytes in/out   : {rep['payloadBytesIn']}/{rep['payloadBytesOut']}")
                print(f"  payloads bit-identical : {rep['payloadsBitIdentical']}")
    except FlowRemapError as exc:
        print(f"flow_remap: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
