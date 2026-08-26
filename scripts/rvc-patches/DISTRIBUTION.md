# Shipping voice conversion — what travels, what installs, what can't

Voice conversion is four separate things with four different distribution stories. The
one that used to silently not travel — our correctness patches — now does.

| Piece | Size | Ships how |
|---|---|---|
| **Our patches** (`scripts/rvc-patches/`) | ~40 KB | git, and as an app-bundle resource |
| **Our hook** (`scripts/rvc-mitigation/`) | ~15 KB | git, and as an app-bundle resource |
| **Vendored fork + venv** (`scripts/rvc/runtime/`) | ~1.7 GB | installed per machine by `scripts/rvc/install.sh` |
| **Voice models** | ~70 MB each | user data, `<Application Support>/DAWPro/VoiceModels/` |

Only the first two are ours and small enough to bundle. That split drives everything below.

## How the app finds them

`VoiceConversionManager.Configuration.resolveOwnedDir` resolves each of our two
directories in this order:

1. `DAWPRO_RVC_PATCHES_DIR` / `DAWPRO_RVC_MITIGATION_DIR` — explicit override
2. the **sibling of `rvcDir`**, if it exists on disk — the repo checkout
3. the **app bundle's Resources** — a distributed `.app`
4. the sibling again, existing or not — so a missing directory still errors against the
   path a developer expects to create

Step 2 cannot be trusted unconditionally, and that is the whole reason step 3 exists:
deriving our directories from `rvcDir` is correct in a checkout and **wrong in a bundle**,
because the 1.7 GB runtime cannot live inside a signed bundle and `rvcDir` therefore
points somewhere else entirely.

`resolveRVCDir` similarly falls back to `<Application Support>/DAWPro/rvc` when there is
no `Package.swift` to walk up to.

The app passes the resolved patches directory to the sidecar as
`DAWPRO_RVC_PATCHES_DIR`; the hook falls back to its own sibling when that is unset.

## Mode 1 — dev on another laptop

Works from a clean clone:

```bash
git clone <repo> && cd daw-pro
./scripts/rvc/install.sh      # ~1.7 GB, once per machine
swift run DAWApp
```

The patches travel in git and resolve by rule 2. Verify with:

```bash
curl -s http://127.0.0.1:8002/v1/_dawpro/mitigation | python3 -m json.tool
```

⚠️ 8002 is the **running app's own sidecar** — this is a read-only status probe, which is
safe, but never start, stop, or bind a test sidecar on it. Give test instances their own
port via `RVC_API_PORT`.

`patchesBound: true` and `patchesError: null` mean conversions are corrected.
**`patchesBound: false` means the sidecar is producing wrong audio** — the facade log
carries a `[dawpro-m10-p-6]` line saying why. (`[dawpro-m23-fo]` is the *other*,
independent mitigation; the tags are deliberately distinct so they grep apart.)

Voice models are user data and do **not** travel — copy
`<Application Support>/DAWPro/VoiceModels/<id>/` across, or re-import the `.pth`.

## Mode 2 — bundled `.app` / sidecar package

Copy both directories into the bundle, preserving their names:

```
DAWPro.app/Contents/Resources/rvc-patches/
DAWPro.app/Contents/Resources/rvc-mitigation/
```

Rule 3 then finds them with no configuration. Two requirements:

- **`rvc-mitigation/` must contain exactly one file.** It goes on `sys.path` ahead of
  site-packages, so a second module there would shadow a same-named module for the whole
  interpreter. `scripts/rvc-model/gate_m23fo_mechanism.py` asserts this. `rvc-patches/` has
  no such rule — it is loaded by path, never put on `sys.path`, which is precisely why the
  patch modules (`generators.py`, `synthesizers.py` — far too generic to expose) live
  there and not beside the hook.
- **The runtime still installs separately** into `<Application Support>/DAWPro/rvc`. The
  bundle carries the fixes, not the engine.

The app sets `PYTHONDONTWRITEBYTECODE=1` for the sidecar, so CPython never writes
`__pycache__` into the signed, read-only Resources directory. (It also stopped a real
bug: any real app run used to litter `__pycache__` beside the hook and turn the one-file
gate red.)

## Mode 3 — Mac App Store

**Not shippable as built, and no amount of path resolution changes that.** The blockers are
structural:

- the sidecar is a `/bin/bash` → Python subprocess spawn; App Sandbox forbids executing a
  non-bundled interpreter, and a bundled CPython + 1.7 GB of native wheels would need to be
  signed and hardened-runtime-compatible
- `install.sh` downloads ~800 MB of model weights at first run
- the vendored fork ships **no LICENSE file** (its `pyproject` claims MIT; GitHub reports
  `licenseInfo: null`), which is a redistribution problem independent of sandboxing

Direct distribution (Developer ID + notarization) is the realistic path for a
Python-sidecar design. Deciding otherwise means replacing the sidecar with an in-process
Swift/MLX implementation — a different project, not a packaging step.

## If you change the vendored fork

The patches are whole-file copies, so a runtime update can silently desync them. Check:

```bash
for f in generators synthesizers; do
  diff -u --label "vendored/$f.py" --label "patched/$f.py" \
       "scripts/rvc/runtime/src/rvc_mlx/lib/mlx/$f.py" "scripts/rvc-patches/$f.py" \
    | diff - "scripts/rvc-patches/$f.patch" && echo "$f: in sync"
done
```
