"""TEST FIXTURE, not the real nltk. install.sh's NLTK step runs `python tools/nltk_fetch.py`, which calls
`nltk.download(pkg, download_dir=..., quiet=True, raise_on_error=True)`. Here that copies
$SING_INSTALL_SOURCE/nltk/<subdir>/<pkg>.zip into download_dir/<subdir>/ and unzips it next to the zip, which is
the layout the real downloader leaves (the spike's cache/nltk has both the zips and the folders).

The fixture g2p_en (its import-time trap, W8-SFIX) needs two more pieces, shaped like the real nltk 3.9.2's:
  * `data.path` / `data.find`: NLTK_DATA's folders, then ~/nltk_data, then <sys.prefix>/nltk_data; a missing resource
    raises LookupError;
  * `download(pkg)` with NO download_dir goes to the real downloader's default: the first existing writable folder on
    data.path, else ~/nltk_data. Unlike the real one it writes only a small SENTINEL file there (never fixture zips),
    so a regression shows up as a stray `FIXTURE-LEAK-<pkg>` file, never as data.
Every call reports on stderr the HOME and NLTK_DATA it ran under (test_install checks they are inside staging).
"""
import os
import shutil
import sys
import zipfile

__version__ = "3.9.2+fixture"
_SUBDIR = {"cmudict": "corpora", "averaged_perceptron_tagger": "taggers", "averaged_perceptron_tagger_eng": "taggers"}


class _Data(object):
    def __init__(self):
        self.path = [p for p in os.environ.get("NLTK_DATA", "").split(os.pathsep) if p]
        self.path += [os.path.join(os.path.expanduser("~/"), "nltk_data"), os.path.join(sys.prefix, "nltk_data")]

    def find(self, resource):
        for d in self.path:
            p = os.path.join(d, resource)
            if os.path.exists(p):
                return p
        raise LookupError("fixture nltk: %s is not in %s" % (resource, self.path))


data = _Data()


def _report(what):
    sys.stderr.write("fixture %s: HOME=%s NLTK_DATA=%s\n" % (what, os.environ.get("HOME", ""),
                                                             os.environ.get("NLTK_DATA", "")))


def _default_download_dir():
    for d in data.path:
        if os.path.isdir(d) and os.access(d, os.W_OK):
            return d
    return os.path.join(os.path.expanduser("~/"), "nltk_data")


def download(info_or_id, download_dir=None, quiet=False, raise_on_error=False, **_kw):
    _report("nltk.download(%s)" % info_or_id)
    if download_dir is None:
        d = _default_download_dir()
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "FIXTURE-LEAK-%s" % info_or_id), "w") as f:
            f.write("the fixture nltk.download(%r) ran with no download_dir (as g2p_en's import does)\n" % info_or_id)
        return True
    sub = _SUBDIR[info_or_id]
    src = os.path.join(os.environ["SING_INSTALL_SOURCE"], "nltk", sub, info_or_id + ".zip")
    dst_dir = os.path.join(download_dir, sub)
    os.makedirs(dst_dir, exist_ok=True)
    dst = os.path.join(dst_dir, info_or_id + ".zip")
    shutil.copyfile(src, dst)
    with zipfile.ZipFile(dst) as z:
        z.extractall(dst_dir)
    return True
