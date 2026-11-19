"""TEST FIXTURE, not the real g2p_en. The real g2p-en 2.1.0 runs this AT IMPORT (g2p_en/g2p.py:21-28):

    try: nltk.data.find('taggers/averaged_perceptron_tagger.zip')
    except LookupError: nltk.download('averaged_perceptron_tagger')
    try: nltk.data.find('corpora/cmudict.zip')
    except LookupError: nltk.download('cmudict')

with NO download_dir, so nltk uses its default folder (~/nltk_data on a clean Mac). install.sh's venv check imports
g2p_en before the nltk step has put any data in the runtime, and on 2026-10-06 that import wrote 3.4 MB into the
user's home during the real install (W8-SFIX). This stand-in makes the same calls against the fixture nltk, so the
fixture install walks into the same trap, and reports on stderr the HOME, NLTK_DATA and TMPDIR it was imported under.
"""
import os
import sys

import nltk

__version__ = "2.1.0+fixture"

sys.stderr.write("fixture g2p_en import: HOME=%s NLTK_DATA=%s TMPDIR=%s\n" % (
    os.environ.get("HOME", ""), os.environ.get("NLTK_DATA", ""), os.environ.get("TMPDIR", "")))
for _resource, _package in (("taggers/averaged_perceptron_tagger.zip", "averaged_perceptron_tagger"),
                            ("corpora/cmudict.zip", "cmudict")):
    try:
        nltk.data.find(_resource)
    except LookupError:
        nltk.download(_package)
