r"""m23-fo mitigation hook — `mx.clear_cache()` before every RVC inference.

⚠️⚠️ **THIS DIRECTORY MUST CONTAIN EXACTLY ONE FILE, FOREVER.**  It is placed on
`PYTHONPATH`, i.e. on `sys.path` *ahead of* site-packages, so any second module
dropped here would shadow a same-named module for the whole interpreter.  The
mechanism gate (`scripts/rvc-model/gate_m23fo_mechanism.py`) asserts the count.
Helper modules belong in `scripts/rvc-model/`.

WHAT THIS FIXES
---------------
Repeated voice conversion in one long-lived sidecar process degrades to
saturated garbage: rms 0.032 -> 0.633 across reps, sample peak pinned at 0.99
by about the 5th call (the vendored max-normaliser at
`rvc_mlx/infer/pipeline_mlx.py:369-372` clamping an output that has run into the
decoder's final `tanh`).  `scripts/rvc/server.py` caches engines (`:94`, `:99`)
in a process that lives for the whole app session and serialises conversions
behind one lock (`:327`), so the 5th and later `vc.convertVocals` of a session
are in the degraded regime.

`mx.clear_cache()` immediately before each inference is NECESSARY AND
SUFFICIENT — established by an ABA design in
`docs/research/2026-08-10-voice-blending-spike.md` §2.2 (clear -> stable, stop
clearing -> monotonic degradation to saturation, resume clearing -> FULL
recovery).  §2.3 records the hypotheses that were killed.  The root cause is not
fully isolated; the behaviour is consistent with a cached Metal allocation being
handed back and read before it is fully written.  ⚠️ `mx.set_cache_limit(0)` was
NEVER measured — do not substitute it.

This is INDEPENDENT of m23-fn (half the base model's normalising flow is
randomly initialised on every load).  The degradation reproduces identically on
the flow-corrected model, so neither defect explains the other.

WHY A `sitecustomize.py` AND NOT A LAUNCHER
-------------------------------------------
Seam settled by `daw-architect`.  The obvious alternative — our own launcher
that imports the facade, patches the class and calls `uvicorn.run` — is
mechanically fine but would have to REPLACE the fenced `scripts/rvc/run.sh`.
Four Swift subsystems are built on properties of that exact process: the
kill-identity predicate `SidecarStop.Identity.rvc`
(`SidecarStopPlanner.swift:125-129`, `#"(^|/)rvc/(server\.py|run\.sh)(\s|$)"#`),
the exec-no-split assumption, the pidfile-pid-IS-the-server-pid assumption
(`VoiceConversionManager.swift:20-33`), and `ModelMemory.swift:325`.  Replacing
`run.sh` would force edits to the predicate that decides what this app is
allowed to `kill` — a direct hit on the standing pid-exact-kill rule.  So
`run.sh` runs UNCHANGED and still owns its own pidfile and double-start guard;
we only add `PYTHONPATH`.

⚠️ NOTHING UNDER `scripts/rvc/` IS WRITTEN, EDITED OR CREATED BY THIS FILE.  It
is a read-only fence.

WHY PER-INFERENCE AND NOT ASGI MIDDLEWARE
-----------------------------------------
`voice_convert` is a *sync* `def` (`server.py:259`), so FastAPI dispatches it to
a worker thread.  A class patch runs in that same thread, immediately before
inference — exactly the position the ABA proved.  Middleware would run on the
event loop instead, while `/health` is polled every 0.5 s
(`VoiceConversionManager.swift:279`), so it could fire DURING an in-flight
worker-thread inference on an allocator bug whose root cause is not isolated.
"one request == one inference" is also only true by today's coincidence
(`server.py:334`).

WHY THIS CANNOT SILENTLY DETACH
-------------------------------
The patch depends on the same three names the facade itself depends on —
`rvc_mlx.infer.infer_mlx` / `RVC_MLX` / `infer` (`server.py:102`, `:334`) — a
strict SUBSET.  Any vendored rename that detaches our patch also breaks the
facade's own call and 500s.  Detachment cannot hide behind working conversions.

CONTRACT
--------
* Inert unless `basename(sys.argv[0]) == "server.py"`, so an unrelated
  interpreter that merely inherits `PYTHONPATH` is unaffected.
* Installs ONE `sys.meta_path` finder, targeting `uvicorn` only.
* On `uvicorn` load, wraps `uvicorn.run`.  All the heavy work happens inside
  that wrapper, BEFORE delegating — i.e. before the port binds — because by then
  `server.py:77-78` has chdir'd to `SRC_DIR` and put it on `sys.path`, so
  `rvc_mlx` resolves (it does NOT at interpreter-startup time).
* ⚠️ NEVER fails the boot.  `/health` and voice listing need no `rvc_mlx` at
  all; a broken hook must not cost the user their sidecar.  Every failure is
  caught, reported on `GET /v1/_dawpro/mitigation`, and printed as one loud line
  to stdout (which `run.sh:70` redirects into the facade log).

Verified by `scripts/rvc-model/gate_m23fo_mechanism.py` (mechanism, no port) and
`scripts/gates/m23fo-conversion-stability.mjs` (RED without `PYTHONPATH`, GREEN
with it, over real HTTP on an isolated scratch facade).
"""

from __future__ import annotations

import os
import sys

HOOK_VERSION = "1.0.0"
DEFECT = "m23-fo"
ROUTE_PATH = "/v1/_dawpro/mitigation"
TARGET = "rvc_mlx.infer.infer_mlx.RVC_MLX.infer"

#: Everything the route reports.  A plain dict rather than globals so the
#: wrapper closure can bump the counter without a `global` dance.
STATE = {
    "hookVersion": HOOK_VERSION,
    "active": False,           # armed AND the uvicorn finder is installed
    "enginePatched": False,    # RVC_MLX.infer actually carries our wrapper
    "clearCacheCalls": 0,
    "cacheMemoryBytes": None,
    "mlxVersion": None,
    "target": TARGET,
    "defect": DEFECT,
    "error": None,
    "facadeModule": None,
    "facadeModuleAliases": None,
    "facadeResolvedBy": None,  # "identity" | "fallbackMain" | "unresolved"
    "routeAdded": False,
}

_clear_cache = None       # resolved AT PATCH TIME, not at call time
_get_cache_memory = None  # diagnostic only; absence is not fatal


def _loud(message: str) -> None:
    """One line to stdout.  `run.sh:70` sends it to the facade log."""
    try:
        print("[dawpro-" + DEFECT + "] " + message, flush=True)
    except Exception:  # noqa: BLE001 — stdout is closed; nothing sane to do
        pass


def _fail(message: str) -> None:
    STATE["error"] = message
    _loud("MITIGATION NOT ACTIVE — " + message)


# ---------------------------------------------------------------------------
# Facade resolution
# ---------------------------------------------------------------------------


def _resolve_facade_module(app):
    """Resolve the module that owns `app` BY IDENTITY of the object, not by name.

    This is also the hook point that m23-fn-2 route (b) would use to set the
    facade's `BASE_MODEL_NPZ` before the engine loads; that correction is
    BLOCKED ON THE USER'S DECISION and is deliberately neither implemented nor
    stubbed here.

    Returns `(module_or_None, name_or_None, how)`.  `__dict__.get` is used
    rather than `getattr` on purpose: a module-level `__getattr__` (numpy and
    friends) could trigger a lazy import mid-scan and mutate `sys.modules`.

    ⚠️ Candidates are collapsed by MODULE OBJECT, not by name.  `sys.modules`
    routinely holds several names for one module — on the shipped path
    `__mp_main__` is literally `sys.modules["__main__"]` (multiprocessing's
    spawn support aliases it, and the vendored engine's dependencies import
    multiprocessing).  Counting names would therefore see two "matches" for the
    one real facade module and fall back on EVERY boot, which measured as
    exactly that before this de-duplication.
    """
    by_object = {}
    for name, mod in list(sys.modules.items()):
        if mod is None:
            continue
        namespace = getattr(mod, "__dict__", None)
        if not isinstance(namespace, dict):
            continue
        if namespace.get("app") is app:
            by_object.setdefault(id(mod), (mod, []))[1].append(name)
    if len(by_object) == 1:
        mod, names = next(iter(by_object.values()))
        name = "__main__" if "__main__" in names else sorted(names)[0]
        STATE["facadeModuleAliases"] = sorted(names)
        return mod, name, "identity"
    STATE["facadeModuleAliases"] = sorted(
        n for _, names in by_object.values() for n in names
    )
    main = sys.modules.get("__main__")
    if main is not None:
        return main, "__main__", "fallbackMain"
    return None, None, "unresolved"


# ---------------------------------------------------------------------------
# The patch itself — runs inside the wrapped `uvicorn.run`, before the bind
# ---------------------------------------------------------------------------


def _patch_engine() -> None:
    """Import MLX + the vendored engine and wrap `RVC_MLX.infer`.

    Costs ~0.4 s warm against `run.sh`'s 30 s-class startup budget, and is paid
    once, before the port binds.
    """
    global _clear_cache, _get_cache_memory

    import mlx.core as mx

    STATE["mlxVersion"] = getattr(mx, "__version__", None)
    # Resolved AT PATCH TIME on purpose: if a future MLX drops `clear_cache`
    # this fails loudly at boot, on the route and in the log, instead of
    # silently at the user's first conversion.
    _clear_cache = getattr(mx, "clear_cache", None)
    if _clear_cache is None:
        raise RuntimeError(
            "mlx.core has no clear_cache in version "
            + repr(STATE["mlxVersion"])
            + " — the m23-fo mitigation cannot be applied. Do NOT substitute "
            "mx.set_cache_limit(0); it was never measured."
        )
    # Diagnostic only.  Its absence must not disarm the mitigation.
    _get_cache_memory = getattr(mx, "get_cache_memory", None)

    from rvc_mlx.infer.infer_mlx import RVC_MLX

    original = RVC_MLX.infer
    if getattr(original, "__dawpro_mitigation__", False):
        STATE["enginePatched"] = True
        _loud("engine already patched — leaving it alone (idempotent)")
        return

    def infer(self, *args, **kwargs):
        _clear_cache()
        STATE["clearCacheCalls"] += 1
        return original(self, *args, **kwargs)

    try:
        import functools

        functools.update_wrapper(infer, original)
    except Exception:  # noqa: BLE001 — cosmetic only
        pass
    # AFTER update_wrapper: it copies __dict__ from the original and would
    # otherwise wipe the marker.
    infer.__dawpro_mitigation__ = True

    RVC_MLX.infer = infer
    STATE["enginePatched"] = True


def _add_route(app) -> None:
    """Add the diagnostic route.  NOT idempotent across repeated `uvicorn.run`
    calls on one `app` — the shipped facade calls it exactly once
    (`server.py:405-409`), so this is a note, not a defect."""

    def mitigation_status():
        # Mirrors the facade's own /health envelope so anything that already
        # parses {"data", "code", "error"} needs no new shape.
        if _get_cache_memory is not None:
            try:
                STATE["cacheMemoryBytes"] = int(_get_cache_memory())
            except Exception as exc:  # noqa: BLE001
                STATE["cacheMemoryBytes"] = None
                STATE["error"] = STATE["error"] or ("get_cache_memory: " + repr(exc))
        return {"data": dict(STATE), "code": 0, "error": None}

    app.add_api_route(
        ROUTE_PATH,
        mitigation_status,
        methods=["GET"],
        name="dawpro_mitigation_status",
    )
    STATE["routeAdded"] = True


def _prepare(app) -> None:
    """Everything that must happen before the port binds."""
    module, name, how = _resolve_facade_module(app)
    STATE["facadeModule"] = name
    STATE["facadeResolvedBy"] = how

    engine_error = None
    try:
        _patch_engine()
    except Exception as exc:  # noqa: BLE001 — a broken hook must not cost a boot
        engine_error = repr(exc)
        _fail("could not patch " + TARGET + ": " + engine_error)

    if app is not None:
        try:
            _add_route(app)
        except Exception as exc:  # noqa: BLE001
            _fail("could not add " + ROUTE_PATH + ": " + repr(exc))

    if engine_error is None:
        _loud(
            "mitigation ACTIVE — clear_cache before every "
            + TARGET
            + " (mlx "
            + str(STATE["mlxVersion"])
            + ", facade module "
            + str(STATE["facadeModule"])
            + " via "
            + str(STATE["facadeResolvedBy"])
            + ", route "
            + ROUTE_PATH
            + ")"
        )


# ---------------------------------------------------------------------------
# uvicorn interception
# ---------------------------------------------------------------------------


def _wrap_uvicorn_run(uvicorn_module) -> None:
    original_run = getattr(uvicorn_module, "run", None)
    if original_run is None or getattr(original_run, "__dawpro_mitigation__", False):
        return

    def run(*args, **kwargs):
        app = args[0] if args else kwargs.get("app")
        try:
            _prepare(app)
        except Exception as exc:  # noqa: BLE001 — never fail the boot
            _fail("hook raised before bind: " + repr(exc))
        return original_run(*args, **kwargs)

    try:
        import functools

        functools.update_wrapper(run, original_run)
    except Exception:  # noqa: BLE001
        pass
    run.__dawpro_mitigation__ = True
    uvicorn_module.run = run


class _UvicornFinder:
    """One `sys.meta_path` finder, targeting the `uvicorn` package only.

    It resolves nothing itself: it delegates to the rest of `sys.meta_path`
    (skipping itself, with a re-entrancy flag) and then wraps the returned
    loader's `exec_module` so `uvicorn.run` is replaced the instant the package
    finishes executing.
    """

    def __init__(self):
        self._busy = False

    def find_spec(self, fullname, path=None, target=None):
        if fullname != "uvicorn" or self._busy:
            return None
        self._busy = True
        try:
            spec = None
            for finder in list(sys.meta_path):
                if finder is self:
                    continue
                find = getattr(finder, "find_spec", None)
                if find is None:
                    continue
                try:
                    spec = find(fullname, path, target)
                except Exception:  # noqa: BLE001 — a finder said no, loudly
                    spec = None
                if spec is not None:
                    break
        finally:
            self._busy = False
        if spec is None:
            return None
        loader = getattr(spec, "loader", None)
        exec_module = getattr(loader, "exec_module", None)
        if exec_module is None:
            return spec

        def wrapped_exec_module(module, _original=exec_module):
            _original(module)
            try:
                _wrap_uvicorn_run(module)
            except Exception as exc:  # noqa: BLE001 — never break the import
                _fail("could not wrap uvicorn.run: " + repr(exc))

        try:
            loader.exec_module = wrapped_exec_module
        except Exception as exc:  # noqa: BLE001 — exotic loader; leave it alone
            _fail("loader is not patchable: " + repr(exc))
        return spec


def _install() -> None:
    for finder in sys.meta_path:
        if type(finder).__name__ == "_UvicornFinder" and getattr(
            type(finder), "__module__", ""
        ) == __name__:
            STATE["active"] = True
            return
    sys.meta_path.insert(0, _UvicornFinder())
    STATE["active"] = True
    # uvicorn is not imported at interpreter-startup time in the shipped path
    # (verified), but if some future dependency pulls it in first, wrap now.
    already = sys.modules.get("uvicorn")
    if already is not None:
        _wrap_uvicorn_run(already)


# ---------------------------------------------------------------------------
# Arm check — the whole file is inert for any other interpreter
# ---------------------------------------------------------------------------

try:
    _argv0 = sys.argv[0] if getattr(sys, "argv", None) else ""
    if os.path.basename(_argv0) == "server.py":
        _install()
except Exception as _exc:  # noqa: BLE001 — a hook may never break an interpreter
    try:
        _fail("install failed: " + repr(_exc))
    except Exception:  # noqa: BLE001
        pass
