# Where these notes come from

`wtk1-prelude1.ly` is the **Mutopia Project**'s LilyPond edition of

> Johann Sebastian Bach (1685–1750), *Das Wohltemperierte Clavier* I,
> Praeludium I in C major, **BWV 846**.

Downloaded 2026-09-08 from
`https://www.mutopiaproject.org/ftp/BachJS/BWV846/wtk1-prelude1/wtk1-prelude1.ly`
(md5 recorded in NOTES.md ROUND 29).

## Attribution, read out of the file's own `\header` — not from memory

| field | value |
|---|---|
| Mutopia reference (`footer`) | **Mutopia-2011/09/12-5** |
| `mutopiatitle` | Das Wohltemperierte Clavier I, Praeludium I |
| `mutopiacomposer` | BachJS |
| `mutopiaopus` | BWV 846 |
| `mutopiainstrument` | Harpsichord, Piano |
| `style` | Baroque |
| `source` | **"Unknown"** — this edition names no source edition |
| entered by (`History`) | Shay Rojansky |
| edited by | Han-Wen Nienhuys, then Tobias Erbsland |
| version update | Javier Ruiz-Alma, 2011-09-11 |
| `maintainer` | Tobias Erbsland |
| `lastupdated` | 2005/Nov/16 |
| **`copyright`** | **"Public Domain"** |

The `tagline` in the same header states it explicitly: *"This sheet music has
been placed in the public domain by the typesetter"*, linking
`http://creativecommons.org/licenses/publicdomain`.

## Licence position — DIFFERENT FROM, AND EASIER THAN, THE MOONLIGHT

- **The composition is PUBLIC DOMAIN.** Bach died in 1750.
- **The typeset EDITION is ALSO public domain**, dedicated by the typesetter.
  ⭐ This is the material difference from `03-moonlight-long`, whose engraving is
  **CC BY-SA 2.5** and therefore carries a share-alike obligation that had to be
  flagged to the user. **There is no share-alike obligation here.**
- We synthesise the audio ourselves from these notes through our own
  instruments, so there is **no sound-recording copyright** involved.
- Attribution is therefore a COURTESY here rather than a licence condition. It
  should still travel on the end card, in the same form the Moonlight uses.

⚠️ **Two honest caveats, neither of them a blocker.**
1. `source = "Unknown"` — unlike the Beethoven (Berners 1908, ed. Winterberger),
   this edition does not say which printed score it was made from. So the
   attribution can name the TYPESETTERS but not an underlying edition.
2. A public-domain dedication by the typesetter is a statement made in the file
   itself. It is what Mutopia publishes and it is what we are relying on; it is
   recorded here verbatim rather than paraphrased so anyone can check it.

## The audio and picture files beside it

`wtk1-prelude1.mid` and `wtk1-prelude1-preview.png` are Mutopia's own outputs of
this same `.ly`. They are kept **as an independent instrument against our
parser**: LilyPond's own rendering of the file is what the file MEANS, so a
disagreement between it and `ly2notes.py` is a parser bug, not a matter of
opinion. Every structural figure in NOTES.md ROUND 29 was derived from the MIDI
and cross-read against the `.ly` text.
