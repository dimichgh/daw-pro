# Content ID dispute — "J. S. Bach — Prelude in C, BWV 846"

⚠️ This is a factual statement assembled from this repository's own build
record. It is not legal advice. Read it before you send it, and check that it
matches the claim you actually received — a dispute should answer the specific
claim, and the claimant's name and the claimed timestamps are not known here.

---

## Which dispute reason to select

YouTube asks for a reason before it gives you a text box. The accurate one is
that **the content is in the public domain / the use is not infringing** —
specifically, this is an original sound recording, made by me, of a composition
that is in the public domain. It is **not** "fair use": nothing of the
claimant's is being used at all.

⚠️ Do **not** select "I have a licence". No licence is involved, and claiming
one you cannot produce would weaken an otherwise strong position.

---

## The dispute text (paste this)

This video contains an original sound recording that I created myself. It does
not contain any part of the claimant's recording.

The composition is Johann Sebastian Bach's Prelude No. 1 in C major, BWV 846,
from Book I of The Well-Tempered Clavier, written c. 1722. Bach died in 1750.
The composition has been in the public domain worldwide for centuries.

The audio in this video was produced entirely by me, as follows:

1. The notes were taken from a public-domain engraving of the score: Mutopia
   Project edition Mutopia-2011/09/12-5, typeset by Shay Rojansky and edited by
   Han-Wen Nienhuys and Tobias Erbsland. That edition's own header states
   'copyright = "Public Domain"', and the engraver placed it in the public
   domain explicitly.
2. That score was converted to MIDI by my own software, and the conversion was
   verified note-for-note — all 549 notes matched, with zero disagreements in
   pitch, timing or duration.
3. The performance was rendered offline from that MIDI by my own software at
   48 kHz, at a fixed tempo of quarter-note = 60, and normalised to
   -14.0 LUFS integrated with a -1.2 dBFS true peak.

No commercial recording, sample, or third-party audio of any kind was used at
any stage. The full 35 bars run 149.2 seconds at a strict metronomic tempo,
which is itself inconsistent with any human performance.

Content ID appears to have matched a different performance of the same
public-domain composition. A match on the composition is not a match on the
recording, and the claimant has no rights in my recording.

I am the sole owner of this sound recording and I ask that the claim be
released.

---

## If the claim is upheld and escalated

Everything above is verifiable from the project record, which is worth keeping
until this resolves:

| fact | where it lives |
|---|---|
| the engraving and its public-domain header | `source/wtk1-prelude1.ly`, header lines 29 and 31 |
| note-for-note verification, 549/549 | `source/validate.py` against LilyPond's own MIDI export |
| the render settings and loudness | `DESCRIPTION.md`, "AUDIO" |
| the finished file | md5 `32de31b284d06d34be8d0cc444307025`, 149.200 s |

⚠️ Disputing is not risk-free: the claimant has 30 days to release, uphold, or
escalate to a takedown, and an upheld takedown becomes a copyright strike. On
these facts the position is strong — a public-domain composition, a public-domain
engraving, and a recording you made yourself — but the decision to file is
yours.
