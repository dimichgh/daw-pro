"""TEST FIXTURE, not the real huggingface_hub. install.sh's weights step runs
`python tools/hf_fetch.py`, which calls `huggingface_hub.hf_hub_download(repo_id, filename, revision, local_dir)`.
In the fixture venv this package answers that call by copying from the local mirror
($SING_INSTALL_SOURCE/hf/<repo_id>/<revision>/<filename>), through an `.incomplete` file under
local_dir/.cache/huggingface/download/ as the real one does, so install.sh's code path is the SAME in both modes.

SING_FIXTURE_THROTTLE_S (seconds per MiB, default 0) slows the copy so a test can cancel mid-download.
Each call reports on stderr the HOME and NLTK_DATA it ran under (test_install checks they are inside staging).
"""
import os
import shutil
import sys
import time

__version__ = "0.36.2+fixture"


def hf_hub_download(repo_id, filename, revision=None, local_dir=None, **_kw):
    sys.stderr.write("fixture hf_hub_download(%s): HOME=%s NLTK_DATA=%s\n" % (
        filename, os.environ.get("HOME", ""), os.environ.get("NLTK_DATA", "")))
    src = os.path.join(os.environ["SING_INSTALL_SOURCE"], "hf", repo_id, revision or "main", filename)
    if not os.path.isfile(src):
        raise FileNotFoundError("fixture mirror has no %s" % src)
    tmp_dir = os.path.join(local_dir, ".cache", "huggingface", "download")
    os.makedirs(tmp_dir, exist_ok=True)
    inc = os.path.join(tmp_dir, filename + ".fixture.incomplete")
    throttle = float(os.environ.get("SING_FIXTURE_THROTTLE_S", "0") or 0)
    with open(src, "rb") as fi, open(inc, "wb") as fo:
        while True:
            chunk = fi.read(1 << 20)
            if not chunk:
                break
            fo.write(chunk)
            fo.flush()
            if throttle:
                time.sleep(throttle)
    dest = os.path.join(local_dir, filename)
    shutil.move(inc, dest)
    return dest
