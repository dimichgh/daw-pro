#!/usr/bin/env python3
"""m23-fo MECHANISM GATE — does the `sitecustomize.py` hook actually arm, and
does it stay inert when it must?

**Code we own.** Never writes under `scripts/rvc/`; every spawn carries
`PYTHONDONTWRITEBYTECODE=1`, so nothing here creates a `__pycache__` anywhere —
under the fence, or next to the hook (where a stray directory would weaken the
"exactly one file" invariant this gate exists to protect).

Fast, no HTTP, no port bound.  The audio proof — that the hook actually cures
the saturation — is `scripts/gates/m23fo-conversion-stability.mjs`; this gate
covers the plumbing that gate cannot isolate, and covers it in seconds.

What it asserts

  A. STRUCTURE — `scripts/rvc-mitigation/` holds EXACTLY ONE FILE.  The
     directory is on `sys.path` ahead of site-packages, so a second module there
     would shadow a same-named module for the whole interpreter.

  B. POSITIVE CONTROL — with `PYTHONPATH` pointed at the directory and
     `argv[0]` basename `server.py`, the hook loads and installs exactly one
     `sys.meta_path` finder.

  C. NEGATIVE CONTROL 1 — with `PYTHONPATH` UNSET the hook does not load at all.
     (Without this, B proves only that Python starts.)

  D. NEGATIVE CONTROL 2 — with `PYTHONPATH` SET but `argv[0]` basename
     `notserver.py`, the hook LOADS AND STAYS INERT: no finder, `active` false.
     C and D fail differently on purpose — "never loaded" and "loaded but did
     not arm" are different bugs and only one of them is C.

  E. WRAP + PATCH — importing `uvicorn` puts our wrapper on `uvicorn.run`;
     calling it adds `GET /v1/_dawpro/mitigation` to the live app in the
     facade's own `{"data", "code", "error"}` envelope, wraps
     `RVC_MLX.infer` with `__dawpro_mitigation__`, and the counter increments
     on a call.  The real `uvicorn.run` IS invoked (so the delegation is under
     test) with `uvicorn.Server.run` stubbed, so no port is ever bound.

  F. RESOLUTION BY IDENTITY — the facade module is found by identity of the
     `app` object, not by name: a second run against an app owned by an
     ordinary imported module resolves to THAT module while `__main__` also
     holds a (different) `app`.  A third run against an app aliased into two
     modules is AMBIGUOUS and must fall back to `__main__` and SAY SO.

  G. FAIL-SAFE — with `mlx.core` stubbed out so `clear_cache` cannot resolve,
     the boot must SURVIVE (exit 0), `enginePatched` must be honestly false,
     the diagnostic route must still exist and answer, and one loud line must
     reach stdout.  `/health` and voice listing need no MLX at all, so a broken
     hook must never cost the user their sidecar.  This also exercises the
     "resolve `clear_cache` AT PATCH TIME" design: a future MLX that drops the
     API fails at boot, in the log and on the route — not silently at the
     user's first conversion.

    python3 scripts/rvc-model/gate_m23fo_mechanism.py
    python3 scripts/rvc-model/gate_m23fo_mechanism.py --no-vendored   # A-D only

Phases E/F need the vendored venv interpreter (MLX + the engine import);
`--no-vendored` runs A-D on the stdlib interpreter alone.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
MITIGATION_DIR = os.path.join(REPO, "scripts", "rvc-mitigation")
HOOK = os.path.join(MITIGATION_DIR, "sitecustomize.py")
VENDORED_SRC = os.path.join(REPO, "scripts", "rvc", "runtime", "src")
VENDORED_PY = os.path.join(VENDORED_SRC, ".venv", "bin", "python")

MARKER = "@@M23FO@@"

FAILURES: list[str] = []
NOTES: list[str] = []


def check(ok: bool, label: str, detail: str = "") -> bool:
    mark = "PASS" if ok else "FAIL"
    print(f"  [{mark}] {label}" + (f" — {detail}" if detail else ""))
    if not ok:
        FAILURES.append(label + (f" — {detail}" if detail else ""))
    return ok


# ---------------------------------------------------------------------------
# Probe source.  Written into a temp dir under whichever name the phase needs;
# `sitecustomize.py` arms on `basename(sys.argv[0])`, so the FILENAME is the
# variable phase D flips.
# ---------------------------------------------------------------------------

PROBE = r'''
import json, os, sys

MARKER = "@@M23FO@@"
report = {"argv0": os.path.basename(sys.argv[0]), "mode": os.environ.get("M23FO_MODE", "inert")}

hook = sys.modules.get("sitecustomize")
report["sitecustomizeLoaded"] = hook is not None
report["hookVersion"] = getattr(hook, "HOOK_VERSION", None)
report["hookFile"] = getattr(hook, "__file__", None)
report["active"] = getattr(hook, "STATE", {}).get("active") if hook else None
finders = [f for f in sys.meta_path if type(f).__name__ == "_UvicornFinder"]
report["finderCount"] = len(finders)
report["uvicornPreloaded"] = "uvicorn" in sys.modules

if report["mode"] == "full":
    # Mirror scripts/rvc/server.py:77-78 exactly: the vendored engine resolves
    # every model path relative to the src root, and is only importable once
    # that root is cwd + on sys.path.  This is why the hook defers its heavy
    # work to `uvicorn.run` instead of doing it at interpreter startup.
    SRC = os.environ["M23FO_SRC"]
    os.chdir(SRC)
    sys.path.insert(0, SRC)

    import uvicorn
    report["uvicornRunWrapped"] = bool(getattr(uvicorn.run, "__dawpro_mitigation__", False))

    # Never bind a port: the delegation target is stubbed one level down, so
    # the REAL uvicorn.run still runs (Config construction and all).
    # `started = True` is MANDATORY — uvicorn/main.py:628 does
    # `if not server.started ...: sys.exit(STARTUP_FAILURE)` (exit 3), which
    # silently killed this probe before the marker line the first time round.
    served = []

    def _stub_run(self, *a, **k):
        served.append(self.config.app)
        self.started = True

    uvicorn.Server.run = _stub_run

    from fastapi import FastAPI
    app = FastAPI(title="probe")

    uvicorn.run(app, host="127.0.0.1", port=65534, log_level="critical")

    report["delegated"] = len(served) == 1 and served[0] is app
    state = dict(hook.STATE)
    report["stateAfterRun"] = state
    report["routePaths"] = [getattr(r, "path", None) for r in app.routes]

    ep = [r for r in app.routes if getattr(r, "path", None) == "/v1/_dawpro/mitigation"]
    report["routeMethods"] = sorted(ep[0].methods) if ep else None
    report["routeBody"] = ep[0].endpoint() if ep else None

    from rvc_mlx.infer.infer_mlx import RVC_MLX
    report["inferMarker"] = bool(getattr(RVC_MLX.infer, "__dawpro_mitigation__", False))

    # Force ONE call through the wrapper.  A bogus `self` and a nonexistent
    # path make the ORIGINAL fail immediately; the wrapper body runs
    # clear_cache and bumps the counter BEFORE delegating, so this measures
    # the wrapper without paying for an inference.
    before = hook.STATE["clearCacheCalls"]
    try:
        RVC_MLX.infer(object(), "/nonexistent/m23fo-probe.wav", "/nonexistent/out.wav")
    except Exception as exc:
        report["inferRaised"] = type(exc).__name__
    after = hook.STATE["clearCacheCalls"]
    report["counterBefore"] = before
    report["counterAfter"] = after

    # --- F: resolution by IDENTITY, not by name -------------------------
    tmp = os.environ["M23FO_TMP"]
    sys.path.insert(0, tmp)
    import facade_mod                      # owns its own `app`
    uvicorn.run(facade_mod.app, host="127.0.0.1", port=65534, log_level="critical")
    report["identityModule"] = hook.STATE["facadeModule"]
    report["identityHow"] = hook.STATE["facadeResolvedBy"]

    import alias_mod
    alias_mod.app = facade_mod.app         # same object, two modules -> ambiguous
    uvicorn.run(facade_mod.app, host="127.0.0.1", port=65534, log_level="critical")
    report["ambiguousModule"] = hook.STATE["facadeModule"]
    report["ambiguousHow"] = hook.STATE["facadeResolvedBy"]

if report["mode"] == "failsafe":
    # G — the NEVER-FAIL-THE-BOOT clause, exercised rather than asserted.
    # Stubbing out mlx.core with a module that has no `clear_cache` is the
    # faithful shape of "a future MLX drops the API": the hook must resolve it
    # AT PATCH TIME, fail loudly, and still let the facade boot, because
    # /health and voice listing need no MLX at all.
    import types
    SRC = os.environ["M23FO_SRC"]
    os.chdir(SRC)
    sys.path.insert(0, SRC)
    sys.modules.setdefault("mlx", types.ModuleType("mlx"))
    sys.modules["mlx.core"] = types.ModuleType("mlx.core")   # no clear_cache

    import uvicorn

    def _stub_run(self, *a, **k):
        self.started = True

    uvicorn.Server.run = _stub_run
    from fastapi import FastAPI
    app = FastAPI(title="probe-failsafe")
    uvicorn.run(app, host="127.0.0.1", port=65534, log_level="critical")

    report["stateAfterRun"] = dict(hook.STATE)
    ep = [r for r in app.routes if getattr(r, "path", None) == "/v1/_dawpro/mitigation"]
    report["routeBody"] = ep[0].endpoint() if ep else None

print(MARKER + json.dumps(report))
'''

FACADE_MOD = "from fastapi import FastAPI\napp = FastAPI(title='facade_mod')\n"
ALIAS_MOD = "app = None\n"


def run_probe(tmp: str, filename: str, python: str, with_pythonpath: bool, mode: str):
    path = os.path.join(tmp, filename)
    with open(path, "w") as fh:
        fh.write(PROBE)
    env = dict(os.environ)
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    env["OMP_NUM_THREADS"] = "1"
    env["M23FO_MODE"] = mode
    env["M23FO_SRC"] = VENDORED_SRC
    env["M23FO_TMP"] = tmp
    if with_pythonpath:
        env["PYTHONPATH"] = MITIGATION_DIR
    else:
        env.pop("PYTHONPATH", None)
    proc = subprocess.run(
        [python, path], capture_output=True, text=True, env=env, timeout=600
    )
    payload = None
    for line in proc.stdout.splitlines():
        if line.startswith(MARKER):
            payload = json.loads(line[len(MARKER) :])
    return proc, payload


# ---------------------------------------------------------------------------


def _why(proc) -> str:
    """Exit code FIRST: a probe that dies silently (uvicorn's `sys.exit(3)`)
    leaves an empty stderr, and 'no output' alone does not say why."""
    return f"rc={proc.returncode} stderr={(proc.stderr or '').strip()[-400:]!r}"


def phase_a() -> None:
    print("A. structure — exactly one file in scripts/rvc-mitigation/")
    check(os.path.isfile(HOOK), "the hook exists", HOOK)
    entries = sorted(
        e for e in os.listdir(MITIGATION_DIR) if e != "__pycache__" and e != ".DS_Store"
    )
    check(
        entries == ["sitecustomize.py"],
        "directory holds EXACTLY ONE file (modulo __pycache__)",
        f"found {entries}",
    )
    check(
        not os.path.isdir(os.path.join(MITIGATION_DIR, "__pycache__")),
        "no __pycache__ beside the hook",
    )


def phase_bcd(python: str, tmp: str) -> None:
    print("B. positive control — PYTHONPATH set, argv[0] basename 'server.py'")
    proc, rep = run_probe(tmp, "server.py", python, True, "inert")
    if not check(rep is not None, "probe reported", (proc.stderr or "")[-400:]):
        return
    check(rep["sitecustomizeLoaded"], "sitecustomize loaded")
    check(rep["hookFile"] == HOOK, "…and it is OUR file", str(rep["hookFile"]))
    check(rep["active"] is True, "STATE['active'] is true", repr(rep["active"]))
    check(rep["finderCount"] == 1, "exactly ONE finder installed", str(rep["finderCount"]))
    check(
        rep["uvicornPreloaded"] is False,
        "uvicorn is NOT already imported at startup (the deferral is needed)",
    )

    print("C. negative control 1 — PYTHONPATH UNSET")
    proc, rep = run_probe(tmp, "server.py", python, False, "inert")
    if check(rep is not None, "probe reported", _why(proc)):
        # ⚠️ NOT "no sitecustomize module at all": some interpreters ship one of
        # their own (Homebrew's python3.14 does, at
        # .../lib/python3.14/sitecustomize.py — measured).  The assertion that
        # means something is that OUR file is not what loaded.  The vendored
        # 3.11 that actually runs the sidecar has none, so the hook shadows
        # nothing there — also measured.
        check(
            rep["hookFile"] != HOOK and rep["hookVersion"] is None,
            "OUR hook does NOT load without PYTHONPATH",
            repr(rep["hookFile"]),
        )
        check(rep["finderCount"] == 0, "no finder installed", str(rep["finderCount"]))

    print("D. negative control 2 — PYTHONPATH set, argv[0] basename 'notserver.py'")
    proc, rep = run_probe(tmp, "notserver.py", python, True, "inert")
    if check(rep is not None, "probe reported", _why(proc)):
        check(rep["sitecustomizeLoaded"] is True, "module IS imported (path is right)")
        check(
            rep["active"] is False,
            "…but the arm check keeps it INERT",
            repr(rep["active"]),
        )
        check(rep["finderCount"] == 0, "no finder installed", str(rep["finderCount"]))


def phase_ef(tmp: str) -> None:
    print("E. wrap + patch (vendored interpreter, no port bound)")
    with open(os.path.join(tmp, "facade_mod.py"), "w") as fh:
        fh.write(FACADE_MOD)
    with open(os.path.join(tmp, "alias_mod.py"), "w") as fh:
        fh.write(ALIAS_MOD)
    proc, rep = run_probe(tmp, "server.py", VENDORED_PY, True, "full")
    if not check(rep is not None, "probe reported", _why(proc)):
        return
    check(rep.get("uvicornRunWrapped") is True, "importing uvicorn wraps uvicorn.run")
    check(rep.get("delegated") is True, "the wrapper DELEGATES to the real uvicorn.run")

    state = rep.get("stateAfterRun") or {}
    check(state.get("enginePatched") is True, "enginePatched", repr(state.get("error")))
    check(state.get("error") is None, "no error recorded", repr(state.get("error")))
    check(rep.get("inferMarker") is True, "RVC_MLX.infer carries __dawpro_mitigation__")
    check(
        "/v1/_dawpro/mitigation" in (rep.get("routePaths") or []),
        "route added to the LIVE app before bind",
        str(rep.get("routePaths")),
    )
    check(rep.get("routeMethods") == ["GET"], "route is GET", str(rep.get("routeMethods")))

    body = rep.get("routeBody") or {}
    check(
        sorted(body.keys()) == ["code", "data", "error"],
        "route mirrors the facade's /health envelope",
        str(sorted(body.keys())),
    )
    data = body.get("data") or {}
    missing = [
        k
        for k in (
            "hookVersion",
            "active",
            "enginePatched",
            "clearCacheCalls",
            "cacheMemoryBytes",
            "mlxVersion",
            "target",
            "defect",
            "error",
        )
        if k not in data
    ]
    check(not missing, "route reports every contracted field", f"missing {missing}")
    check(data.get("defect") == "m23-fo", "defect field", repr(data.get("defect")))
    check(
        isinstance(data.get("cacheMemoryBytes"), int),
        "cacheMemoryBytes is a real MLX reading",
        repr(data.get("cacheMemoryBytes")),
    )
    check(bool(data.get("mlxVersion")), "mlxVersion reported", repr(data.get("mlxVersion")))

    check(
        rep.get("counterAfter") == rep.get("counterBefore") + 1,
        "the counter increments on an inference call",
        f"{rep.get('counterBefore')} -> {rep.get('counterAfter')}",
    )

    print("F. facade resolution is BY IDENTITY, not by name")
    # The shipped shape: server.py IS __main__, and `__mp_main__` is the SAME
    # module object under a second name (multiprocessing's spawn support).
    # Counting names rather than objects made this fall back on every boot —
    # measured, then fixed.
    check(
        state.get("facadeResolvedBy") == "identity"
        and state.get("facadeModule") == "__main__",
        "the shipped shape (app owned by __main__) resolves by IDENTITY",
        f"{state.get('facadeModule')} via {state.get('facadeResolvedBy')}",
    )
    check(
        "__mp_main__" in (state.get("facadeModuleAliases") or []),
        "…and the __mp_main__ alias is seen and collapsed, not counted twice",
        str(state.get("facadeModuleAliases")),
    )
    check(
        rep.get("identityHow") == "identity"
        and rep.get("identityModule") == "facade_mod",
        "an app owned by an ordinary module resolves to THAT module",
        f"{rep.get('identityModule')} via {rep.get('identityHow')}",
    )
    check(
        rep.get("ambiguousHow") == "fallbackMain"
        and rep.get("ambiguousModule") == "__main__",
        "an ambiguous app falls back to __main__ AND records it",
        f"{rep.get('ambiguousModule')} via {rep.get('ambiguousHow')}",
    )

    print("G. fail-safe — a BROKEN hook must never cost the user their sidecar")
    proc, rep = run_probe(tmp, "server.py", VENDORED_PY, True, "failsafe")
    if not check(rep is not None, "probe reported", _why(proc)):
        return
    check(proc.returncode == 0, "the boot SURVIVES a broken hook", f"rc={proc.returncode}")
    gstate = rep.get("stateAfterRun") or {}
    check(gstate.get("enginePatched") is False, "enginePatched is honestly FALSE",
          repr(gstate.get("enginePatched")))
    check(
        isinstance(gstate.get("error"), str) and "clear_cache" in gstate["error"],
        "the route's `error` names the missing clear_cache",
        repr(gstate.get("error"))[:200],
    )
    check(gstate.get("routeAdded") is True, "the diagnostic route is STILL added")
    gbody = rep.get("routeBody") or {}
    check(sorted(gbody.keys()) == ["code", "data", "error"],
          "…and still answers in the facade envelope", str(sorted(gbody.keys())))
    check((gbody.get("data") or {}).get("cacheMemoryBytes") is None,
          "cacheMemoryBytes degrades to null rather than raising",
          repr((gbody.get("data") or {}).get("cacheMemoryBytes")))
    out = proc.stdout or ""
    check("[dawpro-m23-fo]" in out and "MITIGATION NOT ACTIVE" in out,
          "ONE loud line reaches stdout (run.sh:70 -> the facade log)",
          [l for l in out.splitlines() if "dawpro" in l][:1])


def main(argv) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--no-vendored",
        action="store_true",
        help="skip E/F (which need the vendored venv: MLX + the engine import)",
    )
    args = ap.parse_args(argv)

    print(f"m23-fo mechanism gate — hook: {HOOK}")
    phase_a()

    tmp = tempfile.mkdtemp(prefix="m23fo-mech-")
    try:
        phase_bcd(sys.executable, tmp)
        if args.no_vendored:
            NOTES.append("E/F skipped (--no-vendored)")
        elif not os.path.exists(VENDORED_PY):
            print(f"  [SKIP] E/F — no vendored interpreter at {VENDORED_PY}")
            NOTES.append("E/F skipped: vendored venv absent")
        else:
            phase_ef(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

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
