"""The LOCAL FIXTURE MIRROR that install.sh's tests run against (SING_INSTALL_SOURCE + SING_PINS_FILE, tests only).
Standard library only. Nothing here touches the network; nothing is written outside the directory it is given.

What is REAL and what is a fixture:
  real   uv 0.11.19 (this Mac's own binary, packed in the release tarball's layout), CPython 3.10.20 (the spike's
         uv-managed install, re-tarred; served to `uv python install` through --python-downloads-json-url), git
         (a local bare repo), ffmpeg, and the built-in voice's SOURCE: upstream's real zh_prompt.mp3/.json, so the
         fixture run reproduces the REAL builtin pin (a65d6d51...), not a fixture one;
  fixture  the lock (two tiny wheels built here: `huggingface_hub` and `nltk` stand-ins whose download calls copy
         from the mirror, source in tests/fixture_pkgs/), the weights (3 MiB of deterministic bytes) and the NLTK
         zips. Their sizes and sha256s go into a fixture copy of pins.env; every other pin is the real one.
"""
import base64
import sys
import hashlib
import json
import os
import shutil
import subprocess
import urllib.parse
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
SING = os.path.dirname(HERE)
SPIKE = os.path.expanduser("~/DAWPro-spikes/sing-soulx")
UV_BIN = os.environ.get("SING_TEST_UV") or os.path.expanduser("~/.local/bin/uv")
CPYTHON_DIR = os.environ.get("SING_TEST_CPYTHON") or os.path.join(SPIKE, "python", "cpython-3.10.20-macos-aarch64-none")
UPSTREAM_SRC = os.environ.get("SING_TEST_UPSTREAM") or os.path.join(SPIKE, "src", "SoulX-Singer")
FIXED_ZIP_TIME = (1980, 1, 1, 0, 0, 0)
GIT_ENV = {"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "fixture",
           "GIT_AUTHOR_EMAIL": "fixture@invalid", "GIT_COMMITTER_NAME": "fixture",
           "GIT_COMMITTER_EMAIL": "fixture@invalid", "GIT_AUTHOR_DATE": "2026-01-01T00:00:00+0000",
           "GIT_COMMITTER_DATE": "2026-01-01T00:00:00+0000", "GIT_TERMINAL_PROMPT": "0"}


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def missing_inputs():
    """What the mirror needs from this Mac; a test skips (loudly) when any is absent."""
    need = [UV_BIN, os.path.join(CPYTHON_DIR, "bin", "python3.10"),
            os.path.join(UPSTREAM_SRC, "example", "audio", "zh_prompt.mp3"),
            os.path.join(UPSTREAM_SRC, "example", "audio", "zh_prompt.json"), "/usr/bin/git", "/usr/bin/tar"]
    return [p for p in need if not os.path.exists(p)]


def _run(cmd, **kw):
    env = dict(os.environ)
    env.update(kw.pop("env", {}))
    subprocess.run(cmd, check=True, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, **kw)


def _wheel(out_dir, pkg_dir, dist, version):
    """A minimal, valid, deterministic py3-none-any wheel of one package directory."""
    norm = dist.replace("-", "_")
    info = "%s-%s.dist-info" % (norm, version)
    files = []
    for root, _dirs, names in os.walk(pkg_dir):
        for n in sorted(names):
            if n.endswith(".pyc"):
                continue
            p = os.path.join(root, n)
            arc = os.path.join(os.path.basename(pkg_dir), os.path.relpath(p, pkg_dir))
            with open(p, "rb") as f:
                files.append((arc, f.read()))
    files.append(("%s/METADATA" % info, ("Metadata-Version: 2.1\nName: %s\nVersion: %s\nSummary: DAW Pro "
                                         "install.sh TEST FIXTURE\n" % (dist, version)).encode()))
    files.append(("%s/WHEEL" % info, b"Wheel-Version: 1.0\nGenerator: daw-pro-fixture\nRoot-Is-Purelib: true\n"
                                     b"Tag: py3-none-any\n"))
    record = []
    for arc, data in files:
        digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
        record.append("%s,sha256=%s,%d" % (arc, digest, len(data)))
    record.append("%s/RECORD,," % info)
    files.append(("%s/RECORD" % info, ("\n".join(record) + "\n").encode()))
    path = os.path.join(out_dir, "%s-%s-py3-none-any.whl" % (norm, version))
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for arc, data in files:
            zi = zipfile.ZipInfo(arc, FIXED_ZIP_TIME)
            zi.external_attr = 0o644 << 16
            z.writestr(zi, data)
    return path


def _zip(path, members):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for arc, data in members:
            zi = zipfile.ZipInfo(arc, FIXED_ZIP_TIME)
            zi.external_attr = 0o644 << 16
            z.writestr(zi, data)


def _pins_line(key, value):
    if any(c in value for c in '"$`\\\''):
        raise ValueError("pins value for %s cannot hold quotes, $, backquote or backslash: %r" % (key, value))
    return '%s="%s"' % (key, value) if (" " in value or "\t" in value or "#" in value) else "%s=%s" % (key, value)


def build(mirror, work):
    """Build the mirror in `mirror` (scratch in `work`). Returns {"pins": path, "lock": path, "facts": {...}}."""
    os.makedirs(mirror, exist_ok=True)
    os.makedirs(work, exist_ok=True)
    if SING not in sys.path:
        sys.path.insert(0, SING)
    from singlib import pins as spins
    with open(os.path.join(SING, "pins.env")) as f:
        real = spins.parse(f.read())
    over = {}

    # uv: this Mac's binary in the release tarball's layout
    uvdir = os.path.join(work, "uv-aarch64-apple-darwin")
    os.makedirs(uvdir, exist_ok=True)
    shutil.copy2(UV_BIN, os.path.join(uvdir, "uv"))
    uv_tar = os.path.join(mirror, real["UV_ASSET"])
    _run(["/usr/bin/tar", "-C", work, "-czf", uv_tar, "uv-aarch64-apple-darwin"])
    over["UV_SHA256"] = sha256(uv_tar)

    # CPython 3.10.20 for `uv python install ... --python-downloads-json-url file://...`
    pydir = os.path.join(mirror, "python")
    os.makedirs(pydir, exist_ok=True)
    py_tar = os.path.join(pydir, "cpython-3.10.20-fixture.tar.gz")
    base = os.path.basename(CPYTHON_DIR.rstrip("/"))
    _run(["/usr/bin/tar", "-C", os.path.dirname(CPYTHON_DIR.rstrip("/")), "-s", ",^%s,python," % base, "-czf", py_tar,
          base])
    downloads = {"cpython-3.10.20-macos-aarch64-none": {
        "name": "cpython", "arch": {"family": "aarch64", "variant": None}, "os": "macos", "libc": "none",
        "major": 3, "minor": 10, "patch": 20, "prerelease": "", "url": "file://" + urllib.parse.quote(py_tar),
        "sha256": sha256(py_tar), "variant": None, "build": "fixture"}}
    with open(os.path.join(pydir, "downloads.json"), "w") as f:
        json.dump(downloads, f, indent=1)

    # wheels + the fixture lock
    wheels = os.path.join(mirror, "wheels")
    os.makedirs(wheels, exist_ok=True)
    _wheel(wheels, os.path.join(HERE, "fixture_pkgs", "huggingface_hub"), "huggingface-hub", "0.36.2+fixture")
    _wheel(wheels, os.path.join(HERE, "fixture_pkgs", "nltk"), "nltk", "3.9.2+fixture")
    lock = os.path.join(work, "requirements-fixture.lock")
    with open(lock, "w") as f:
        f.write("huggingface-hub==0.36.2+fixture\nnltk==3.9.2+fixture\n")
    over["LOCK_FILE"] = lock
    over["VERIFY_IMPORTS"] = "huggingface_hub nltk"

    # upstream: a bare repo whose ONE commit carries upstream's real built-in voice source files
    repo = os.path.join(work, "upstream-work")
    os.makedirs(os.path.join(repo, "example", "audio"), exist_ok=True)
    for n in ("zh_prompt.mp3", "zh_prompt.json"):
        shutil.copyfile(os.path.join(UPSTREAM_SRC, "example", "audio", n), os.path.join(repo, "example", "audio", n))
    with open(os.path.join(repo, "README.md"), "w") as f:
        f.write("DAW Pro install.sh test fixture: stands in for SoulX-Singer's checkout.\n")
    _run(["/usr/bin/git", "-c", "init.defaultBranch=main", "init", "-q", repo], env=GIT_ENV)
    _run(["/usr/bin/git", "-C", repo, "add", "-A"], env=GIT_ENV)
    _run(["/usr/bin/git", "-C", repo, "commit", "-q", "-m", "fixture upstream"], env=GIT_ENV)
    commit = subprocess.run(["/usr/bin/git", "-C", repo, "rev-parse", "HEAD"], check=True, capture_output=True,
                            text=True, env=dict(os.environ, **GIT_ENV)).stdout.strip()
    _run(["/usr/bin/git", "clone", "-q", "--bare", repo, os.path.join(mirror, "upstream.git")], env=GIT_ENV)
    over["UPSTREAM_COMMIT"] = commit

    # weights: deterministic bytes at the real repo/revision path
    hf = os.path.join(mirror, "hf", real["WEIGHTS_REPO"], real["WEIGHTS_REVISION"])
    os.makedirs(hf, exist_ok=True)
    model = os.path.join(hf, real["MODEL_FILE"])
    with open(model, "wb") as f:
        block = hashlib.sha256(b"daw-pro fixture weights").digest() * (1 << 15)   # 1 MiB
        for _ in range(3):
            f.write(block)
    config = os.path.join(hf, real["CONFIG_FILE"])
    with open(config, "w") as f:
        f.write("# DAW Pro install.sh test fixture config\ninfer:\n  n_steps: 32\n")
    over.update({"MODEL_BYTES": str(os.path.getsize(model)), "MODEL_SHA256": sha256(model),
                 "CONFIG_BYTES": str(os.path.getsize(config)), "CONFIG_SHA256": sha256(config)})

    # NLTK zips (each unzips to a folder named like the zip, as the real ones do)
    for pkg in real["NLTK_PACKAGES"].split():
        rel = real["NLTK_ZIP_" + pkg]
        z = os.path.join(mirror, "nltk", rel)
        os.makedirs(os.path.dirname(z), exist_ok=True)
        _zip(z, [("%s/README" % pkg, ("fixture %s\n" % pkg).encode())])
        over["NLTK_SHA256_" + pkg] = sha256(z)

    pins_path = os.path.join(work, "pins-fixture.env")
    lines = ["# FIXTURE pins generated by scripts/sing/tests/fixture_mirror.py; every key not listed here is real."]
    for k, v in real.items():
        lines.append(_pins_line(k, over.get(k, v)))
    with open(pins_path, "w") as f:
        f.write("\n".join(lines) + "\n")
    return {"pins": pins_path, "lock": lock, "mirror": mirror,
            "facts": {"commit": commit, "model_sha256": over["MODEL_SHA256"], "uv_sha256": over["UV_SHA256"],
                      "builtin_wav_sha256": real["BUILTIN_WAV_SHA256"]}}
