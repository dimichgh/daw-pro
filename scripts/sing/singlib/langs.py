"""The languages facadeVersion 2 can sing (design docs/design/2026-10-06-p2-sing-expansion.md §6.3, §6.4, §7.2).
Standard library only, Python 3.9 compatible: the schema, the converter and the stub all use it.

Language reaches the model ONLY through the token prefix (`en_`, `zh_`, `yue_`): upstream's DataProcessor never reads
the metadata's `language` field (upstream/soulxsinger/utils/data_processor.py:44-47, 152). An English token is split
into its phones inside the model; a Chinese token is ONE whole tonal syllable (data_processor.py:96-104). So one
phrase may mix English words with Chinese ones, as upstream's own preprocessing does (preprocess/tools/g2p.py:37-71).

  en   today's English path, unchanged (g2p_en ARPAbet joined with '-')
  zh   Mandarin: tonal pinyin, tones 1-5 (5 = neutral). The phone set spells u-umlaut "u:" (zh_lu:4, zh_nu:e4)
  yue  Cantonese: tonal jyutping, tones 1-6
"es" (Spanish through English phones, §6.5) is NOT here: it arrives only after its own word check and listening round.
"""
import re
import unicodedata

DEFAULT = "en"
SUPPORTED = ("en", "zh", "yue")
PREFIX = {"en": "en_", "zh": "zh_", "yue": "yue_"}
NAME = {"en": "English", "zh": "Mandarin", "yue": "Cantonese"}      # upstream's own metadata `language` values
TONES = {"zh": ("1", "2", "3", "4", "5"), "yue": ("1", "2", "3", "4", "5", "6")}
EXAMPLE = {"zh": "pinyin with a tone number, like ni3", "yue": "jyutping with a tone number, like nei5"}

_SYLLABLE = {"zh": re.compile(r"^[a-z]+(?::[a-z]*)?[1-5]$"), "yue": re.compile(r"^[a-z]+[1-6]$")}
# CJK Unified Ideographs, Extension A, Compatibility Ideographs, Extensions B-F and Compatibility Supplement, G-H.
CJK_RANGES = ((0x3400, 0x4DBF), (0x4E00, 0x9FFF), (0xF900, 0xFAFF), (0x20000, 0x2A6DF), (0x2A700, 0x2EBEF),
              (0x2F800, 0x2FA1F), (0x30000, 0x323AF))


def is_cjk_char(text):
    """One Chinese character (one sung syllable, one note)."""
    return isinstance(text, str) and len(text) == 1 and any(a <= ord(text) <= b for a, b in CJK_RANGES)


def is_syllable(lang, s):
    """`s` is one syllable in the phone set's spelling for `lang` (letters, then its tone number)."""
    return isinstance(s, str) and bool(_SYLLABLE[lang].match(s))


def romanised(lang, text):
    """A TYPED syllable (pinyin for zh, jyutping for yue, with its tone number) -> the phone set's spelling, or None.
    Case is ignored; in pinyin, u-umlaut may be typed as "ü" or "v" and is spelled "u:" (lü4 / lv4 -> lu:4)."""
    s = unicodedata.normalize("NFC", text).lower()
    if lang == "zh":
        s = s.replace("ü", "u:").replace("v", "u:")
    return s if is_syllable(lang, s) else None


def split_tone(s):
    """"ni3" -> ("ni", "3")."""
    return s[:-1], s[-1]
