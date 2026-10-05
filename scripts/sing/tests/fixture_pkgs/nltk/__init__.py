"""TEST FIXTURE, not the real nltk. install.sh's NLTK step runs `python tools/nltk_fetch.py`, which calls
`nltk.download(pkg, download_dir=..., quiet=True, raise_on_error=True)`. Here that copies
$SING_INSTALL_SOURCE/nltk/<subdir>/<pkg>.zip into download_dir/<subdir>/ and unzips it next to the zip, which is
the layout the real downloader leaves (the spike's cache/nltk has both the zips and the folders).
"""
import os
import shutil
import zipfile

__version__ = "3.9.2+fixture"
_SUBDIR = {"cmudict": "corpora", "averaged_perceptron_tagger": "taggers", "averaged_perceptron_tagger_eng": "taggers"}


def download(info_or_id, download_dir=None, quiet=False, raise_on_error=False, **_kw):
    sub = _SUBDIR[info_or_id]
    src = os.path.join(os.environ["SING_INSTALL_SOURCE"], "nltk", sub, info_or_id + ".zip")
    dst_dir = os.path.join(download_dir, sub)
    os.makedirs(dst_dir, exist_ok=True)
    dst = os.path.join(dst_dir, info_or_id + ".zip")
    shutil.copyfile(src, dst)
    with zipfile.ZipFile(dst) as z:
        z.extractall(dst_dir)
    return True
