"""install.sh's NLTK step: nltk.download() of each package into --dest, called from python (never a console
script). Needs `averaged_perceptron_tagger_eng` as well as g2p_en's two: nltk 3.9.2's pos_tag loads it and g2p_en
never fetches it (spike deviations 14:31:57). install.sh checks each zip's sha256 afterwards.

Usage: <venv python> nltk_fetch.py --dest DIR PACKAGE [PACKAGE ...]
"""
import argparse
import sys


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--dest", required=True)
    ap.add_argument("packages", nargs="+")
    a = ap.parse_args(argv)
    import nltk
    for pkg in a.packages:
        ok = nltk.download(pkg, download_dir=a.dest, quiet=True, raise_on_error=True)
        if not ok:
            sys.stderr.write("nltk_fetch: %s did not download\n" % pkg)
            return 1
        print("@@nltk %s" % pkg, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
