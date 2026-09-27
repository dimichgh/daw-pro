"""install.sh's weights step: huggingface_hub.hf_hub_download for the pinned files, called from python (never the
`hf` console script: "Application Support" has a space, and a shebang with a space does not run).

Prints `@@bytes <done> <total>` every 0.5 s while it downloads (done = bytes on disk under --dest, which includes
huggingface_hub's own `.incomplete` file). install.sh checks sizes and sha256 afterwards; this tool only fetches.

Usage: <venv python> hf_fetch.py --repo R --revision REV --dest DIR --file NAME:BYTES [--file NAME:BYTES ...]
Runs under the runtime venv (Python 3.10). huggingface_hub reads HF_HOME / HF_HUB_DISABLE_TELEMETRY from the
environment install.sh sets.
"""
import argparse
import os
import sys
import threading


def bytes_on_disk(root):
    total = 0
    for d, _dirs, files in os.walk(root):
        for f in files:
            try:
                total += os.lstat(os.path.join(d, f)).st_size
            except OSError:
                pass
    return total


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--revision", required=True)
    ap.add_argument("--dest", required=True)
    ap.add_argument("--file", action="append", required=True, help="NAME:BYTES")
    a = ap.parse_args(argv)
    files = []
    for spec in a.file:
        name, _, size = spec.partition(":")
        files.append((name, int(size or 0)))
    total = sum(s for _, s in files)
    os.makedirs(a.dest, exist_ok=True)
    from huggingface_hub import hf_hub_download

    stop = threading.Event()

    def progress():
        while not stop.wait(0.5):
            print("@@bytes %d %d" % (min(bytes_on_disk(a.dest), total or 1 << 62), total), flush=True)

    t = threading.Thread(target=progress, daemon=True)
    t.start()
    try:
        for name, _size in files:
            path = hf_hub_download(repo_id=a.repo, filename=name, revision=a.revision, local_dir=a.dest)
            if os.path.realpath(path) != os.path.realpath(os.path.join(a.dest, name)):
                sys.stderr.write("hf_fetch: %s landed at %s, not in %s\n" % (name, path, a.dest))
                return 1
    finally:
        stop.set()
        t.join()
    print("@@bytes %d %d" % (total, total), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
