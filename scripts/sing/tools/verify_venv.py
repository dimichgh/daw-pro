"""install.sh's venv check, run BY the venv's own python: the interpreter version, sys.prefix, every lock pin
installed at exactly its version, and the listed modules import. Exit 0 only if all hold.

Usage: <venv python> verify_venv.py --lock FILE --python-version 3.10.20 --prefix DIR [--imports "a b c"]
"""
import argparse
import importlib
import os
import re
import sys

PIN = re.compile(r"^([A-Za-z0-9][A-Za-z0-9._-]*)==([^\s;#]+)\s*$")


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--lock", required=True)
    ap.add_argument("--python-version", required=True)
    ap.add_argument("--prefix", required=True)
    ap.add_argument("--imports", default="")
    a = ap.parse_args(argv)
    from importlib import metadata as md
    problems = []
    got_py = sys.version.split()[0]
    if got_py != a.python_version:
        problems.append("python %s, expected %s" % (got_py, a.python_version))
    if os.path.realpath(sys.prefix) != os.path.realpath(a.prefix):
        problems.append("sys.prefix %s, expected %s" % (sys.prefix, a.prefix))
    n = 0
    with open(a.lock, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            m = PIN.match(line)
            if not m:
                problems.append("lock line is not name==version: %r" % line)
                continue
            n += 1
            name, want = m.group(1), m.group(2)
            try:
                have = md.version(name)
            except md.PackageNotFoundError:
                problems.append("%s is not installed (lock pins %s)" % (name, want))
                continue
            if have != want:
                problems.append("%s is %s, lock pins %s" % (name, have, want))
    for mod in a.imports.split():
        try:
            importlib.import_module(mod)
        except Exception as e:
            problems.append("import %s failed: %s: %s" % (mod, type(e).__name__, str(e).splitlines()[0][:200] if str(e) else ""))
    if problems:
        for p in problems:
            sys.stderr.write("verify_venv: %s\n" % p)
        return 1
    print("@@venv-ok python %s, %d pins, imports: %s" % (got_py, n, a.imports or "-"), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
