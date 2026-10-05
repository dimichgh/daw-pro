"""pins.env reader (standard library, Python 3.9 compatible).

install.sh reads the same file with a line parser that never evaluates it (no `source`), so the format is
deliberately narrow: `KEY=value` or `KEY="value with spaces"`, one per line, `#` comments and blank lines.
No `$`, backquote, backslash or quote (single or double) inside a value. test_lock_pins.py checks pins.env against this format.
"""
import os
import re

LINE = re.compile(r'''^([A-Z][A-Za-z0-9_]*)=("([^"$`\\']*)"|([^\s"$`\\'#]*))$''')


class PinsError(ValueError):
    pass


def parse(text, source="pins.env"):
    out = {}
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = LINE.match(line)
        if not m:
            raise PinsError("%s:%d is not KEY=value: %r" % (source, n, raw))
        key = m.group(1)
        if key in out:
            raise PinsError("%s:%d repeats %s" % (source, n, key))
        out[key] = m.group(3) if m.group(3) is not None else m.group(4)
    return out


def load(path=None):
    """The pins file the scripts use: `path`, else $SING_PINS_FILE (tests only), else scripts/sing/pins.env."""
    if path is None:
        path = os.environ.get("SING_PINS_FILE") or os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "pins.env")
    with open(path, "r", encoding="utf-8") as f:
        return parse(f.read(), path)
