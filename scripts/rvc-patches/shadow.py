"""Apply DAW Pro's fixes to the vendored MLX RVC fork WITHOUT writing inside the fence.

`scripts/rvc/` is read-only (user ruling, route (b): work on copies outside it, never
write into it). So the two corrected modules live here and are bound by name into
`sys.modules` BEFORE the fork imports them.

Why not sys.path shadowing: the fork's `rvc_mlx/` and `rvc_mlx/lib/` are namespace
packages but `rvc_mlx/lib/mlx/` is a REGULAR package (it has an __init__.py). A shadow
directory that also carries an __init__.py becomes a regular package that wins for
*every* submodule, hiding the ~12 fenced ones we do not patch (ModuleNotFoundError on
`rvc_mlx.lib.mlx.modules`); one without an __init__.py loses to the fenced regular
package and is silently ignored. Binding sys.modules by name sidesteps both.

Two independent defects are corrected -- see README.md, with the exact upstream diff in
generators.patch / synthesizers.patch.

Usage:
    from shadow import install
    install()
    from rvc_mlx.infer.infer_mlx import RVC_MLX
"""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def _resolve_src():
    """Where the vendored fork lives.

    Mirrors `scripts/rvc/server.py:65` so the sidecar and the CLI can never
    disagree about which checkout they are patching: RVC_SRC_DIR wins, else the
    repo-relative sibling.
    """
    env = os.environ.get("RVC_SRC_DIR", "")
    if env:
        return os.path.abspath(env)
    return os.path.abspath(os.path.join(HERE, "..", "rvc", "runtime", "src"))


SRC = _resolve_src()

# order matters: synthesizers imports HiFiGANNSFGenerator from generators, so ours must
# already be in sys.modules when synthesizers executes, or it binds the fenced one.
_MODULES = (
    ("rvc_mlx.lib.mlx.generators", "generators.py"),
    ("rvc_mlx.lib.mlx.synthesizers", "synthesizers.py"),
)


def _load(dotted, filename):
    path = os.path.join(HERE, filename)
    spec = importlib.util.spec_from_file_location(dotted, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[dotted] = mod
    spec.loader.exec_module(mod)
    return mod


def install(noise_scale=None, chunk_max_out=None, verbose=True):
    """Bind the patched modules. Returns (generators, synthesizers).

    Raises RuntimeError if a patch did NOT take -- silently running the unpatched fork
    while believing the fix was applied is the most misleading failure possible here.
    """
    if noise_scale is not None:
        os.environ["RVC_MLX_NOISE_SCALE"] = str(noise_scale)

    # ⚠️ SRC may not be resolvable from here, and that is NORMAL, not an error.
    #
    # Standalone (CLI) we are a sibling of `scripts/rvc/`, so the relative default
    # works. BUNDLED we live in `.../Contents/Resources/rvc-patches/` while the 1.7 GB
    # runtime is installed under Application Support -- the sibling does not exist, and
    # an unconditional chdir there raised FileNotFoundError and silently left the
    # sidecar UNPATCHED (measured: patchesBound=false, "conversions will be WRONG").
    #
    # When SRC is absent we simply trust the caller: inside the sidecar, `server.py:77-78`
    # has ALREADY chdir'd to the real SRC_DIR and put it on sys.path before this runs, so
    # the imports below resolve regardless. If neither is true the imports fail loudly a
    # few lines down, which is the honest place for it.
    src = _resolve_src()
    if os.path.isdir(src):
        if src not in sys.path:
            sys.path.insert(0, src)
        # The fork resolves weight files relative to its own src root. Omitting this
        # makes HuBERT silently fail while STILL producing audio -- a failure mode that
        # already cost one invalid A/B round. Skipped when we are already there.
        if os.path.realpath(os.getcwd()) != os.path.realpath(src):
            os.chdir(src)

    for dotted, filename in _MODULES:
        if dotted in sys.modules and not getattr(
            sys.modules[dotted], "__file__", "").startswith(HERE):
            raise RuntimeError(
                f"{dotted} was already imported from "
                f"{sys.modules[dotted].__file__} -- call install() before importing "
                f"anything from rvc_mlx.")
        _load(dotted, filename)

    generators = sys.modules["rvc_mlx.lib.mlx.generators"]
    synthesizers = sys.modules["rvc_mlx.lib.mlx.synthesizers"]

    if not hasattr(generators, "conv_transpose1d_chunked"):
        raise RuntimeError("generators bound but the conv-transpose fix is missing")
    if "_ns" not in synthesizers.Synthesizer.infer.__code__.co_varnames:
        raise RuntimeError("synthesizers bound but the noise-scale fix is missing")

    if chunk_max_out is not None:
        d = list(generators.conv_transpose1d_chunked.__defaults__)
        d[-1] = int(chunk_max_out)
        generators.conv_transpose1d_chunked.__defaults__ = tuple(d)

    if verbose:
        eff = os.environ.get("RVC_MLX_NOISE_SCALE", "0.66666 (default)")
        print(f"[shadow] patched: {generators.__file__}")
        print(f"[shadow] patched: {synthesizers.__file__}")
        print(f"[shadow] noise_scale={eff}  "
              f"convt_max_out={generators.conv_transpose1d_chunked.__defaults__[-1]}")

    return generators, synthesizers
