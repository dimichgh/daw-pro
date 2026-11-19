"""The facade's refusal table (design 2026-09-27-p2-sing-integration.md §2.4, plus the four facadeVersion 2 codes of
2026-10-06-p2-sing-expansion.md §7.4).

Every refusal answers `{"error": <code>, "message": <sentence>}` with the HTTP status below. The app maps each
code to its own user-facing sentence; `message` is for logs and agents, and names the offending word, note or
path wherever there is one.
"""

HTTP_STATUS = {
    "badRequest": 400,            # unknown keys (refused, like rejectUnknownKeys) or a malformed body
    "phraseTooLong": 400,         # longer than 30 s with the guards (a backstop: the app sends <= 20 s)
    "notesOverlap": 400,          # sorted, but a note starts before the previous one ends
    "notesUnsorted": 400,         # a note starts before the previous note's start
    "wordsDoNotCoverNotes": 400,  # a note without exactly one word, or indices not contiguous and ascending
    "emptyWord": 400,             # a word with no letters (nothing to sing)
    "unknownPhone": 400,          # a phone outside upstream's phone_set.json
    "pathNotAllowed": 403,        # a realpath outside SING_ALLOWED_ROOTS
    "voiceNotFound": 404,         # no voice with that id (or its reference file is gone)
    "referenceChanged": 409,      # the reference's sha256 does not match
    "badReference": 422,          # the reference is unreadable, or too short after the trim
    "loading": 503,               # the model is still loading
    "nonFinite": 500,             # NaN or Inf in the output (nothing is written)
    "inferenceFailed": 500,       # an exception (its first line), or the engine failed to load
    # facadeVersion 2 only (design 2026-10-06-p2-sing-expansion.md §7.4); a v1 request can never get one of these.
    "languageNotSupported": 400,  # a word's `lang` this facade does not sing (names it)
    "vibratoNeedsMelody": 400,    # a note's `vibrato` in score mode (melody mode is item p2-sing-x10)
    "promptF0Missing": 400,       # melody mode with an own voice and no voice.prompt.f0 (x10; unreachable before)
    "f0TooShort": 400,            # an internally built f0 curve shorter than the phrase's mel frames (x10; a defect)
}

# HTTP-level answers that are not part of the §2.4 table (routing, not rendering).
ROUTING_STATUS = {
    "notFound": 404,
    "methodNotAllowed": 405,
}


class Refusal(Exception):
    """A request the facade will not render. `code` must be a key of HTTP_STATUS."""

    def __init__(self, code, message):
        if code not in HTTP_STATUS:
            raise ValueError("unknown refusal code: %r" % (code,))
        super().__init__(message)
        self.code = code
        self.message = message
        self.status = HTTP_STATUS[code]

    def body(self):
        return {"error": self.code, "message": self.message}


def first_line(exc):
    """The first line of an exception, for `inferenceFailed` (never a traceback on the wire)."""
    text = ("%s: %s" % (type(exc).__name__, exc)).strip()
    return text.splitlines()[0][:400] if text else type(exc).__name__
