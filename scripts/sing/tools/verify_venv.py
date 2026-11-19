"""install.sh's venv check, run BY the venv's own python: the interpreter version, sys.prefix, every lock pin
installed at exactly its version, and the listed modules import. Exit 0 only if all hold.

The imports run OFFLINE (W8-SFIX, measured 2026-10-06):
  * g2p_en calls nltk.download() AT IMPORT when its data is missing, with no folder, so nltk picks its default:
    ~/nltk_data on a clean Mac. During the real install that downloaded 3.4 MB from raw.githubusercontent.com into
    the user's home (the nltk step that fills the runtime's own nltk_data runs AFTER this check). So nltk.download is
    replaced by a recorder before any listed module is imported: this check proves the packages IMPORT; the data is
    the nltk step's job (pinned sha256, into the runtime).
  * any other network attempt during the imports is refused (an audit hook) and FAILS the check, naming it, so an
    import-time download can never come back unnoticed.

Usage: <venv python> verify_venv.py --lock FILE --python-version 3.10.20 --prefix DIR [--imports "a b c"]
"""
import argparse
import importlib
import os
import re
import sys

PIN = re.compile(r"^([A-Za-z0-9][A-Za-z0-9._-]*)==([^\s;#]+)\s*$")
NETWORK_EVENTS = frozenset(("socket.getaddrinfo", "socket.connect", "socket.gethostbyname", "socket.gethostbyname_ex",
                            "socket.gethostbyaddr", "urllib.Request", "http.client.connect", "socket.sendto",
                            "socket.sendmsg"))


class NetworkRefused(OSError):
    pass


def refuse_network(attempts):
    """Every network event in this process from now on is recorded in `attempts` and refused (no bytes flow)."""
    def hook(event, args):
        if event in NETWORK_EVENTS:
            attempts.append("%s %s" % (event, repr(args)[:160]))
            raise NetworkRefused("verify_venv: the venv check runs offline (%s refused)" % event)
    sys.addaudithook(hook)


def record_nltk_downloads(asked):
    """nltk.download (and the downloader's own two names for it, where they exist) only RECORDS what it was asked
    for: it downloads nothing and returns False, which g2p_en ignores."""
    def download(info_or_id=None, *_args, **_kwargs):
        asked.append(str(info_or_id))
        return False

    def download_method(_self, info_or_id=None, *args, **kwargs):
        return download(info_or_id, *args, **kwargs)
    try:
        import nltk
    except Exception:
        return            # nltk missing or broken: the lock check and the import loop report it
    nltk.download = download
    try:
        import nltk.downloader as downloader
    except Exception:
        return
    downloader.download = download
    if hasattr(downloader, "Downloader"):
        downloader.Downloader.download = download_method


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
    attempts, asked = [], []
    refuse_network(attempts)
    record_nltk_downloads(asked)
    for mod in a.imports.split():
        try:
            importlib.import_module(mod)
        except Exception as e:
            problems.append("import %s failed: %s: %s" % (mod, type(e).__name__, str(e).splitlines()[0][:200] if str(e) else ""))
    for attempt in attempts:
        problems.append("an import reached for the network: %s" % attempt)
    if asked:
        sys.stderr.write("verify_venv: an import asked nltk to download %s; nothing was downloaded (the nltk step puts "
                         "that data in the runtime)\n" % ", ".join(asked))
    if problems:
        for p in problems:
            sys.stderr.write("verify_venv: %s\n" % p)
        return 1
    print("@@venv-ok python %s, %d pins, imports: %s" % (got_py, n, a.imports or "-"), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
