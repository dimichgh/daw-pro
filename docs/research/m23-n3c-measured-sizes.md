# m23-n3c — Whisper variant sizes, MEASURED (not quoted)

**Method.** Every number below is the sum of `size` for every file under the variant's
directory in `argmaxinc/whisperkit-coreml`, read from the HuggingFace tree API
(`/api/models/.../tree/main/<variant>?recursive=true`). That directory is exactly what
WhisperKit's download glob `*<variant>/*` pulls, so it is the real transfer, not a
weights-only figure. `size` was verified to equal `lfs.size` where LFS is present, so it
is the true byte count and not an LFS pointer. Measured 2026-07-28. **No model was
downloaded to produce this table.**

## The correction this measurement forced

m23-n3a recorded that a downloaded `large-v3-turbo` "lands both `.mlmodelc` and
`.mlpackage` forms and occupies roughly double" the user's hand-copied 1.64 GB copy.
**That is wrong, and it is now withdrawn.** `tiny.en` is the ONLY one of the 27 variants
that ships both forms (153.0 MB, of which `.mlmodelc` is 76.6 and `.mlpackage` 76.4).
**Every other variant is `.mlmodelc`-only.** Measured consequences:

- a downloaded `openai_whisper-large-v3-v20240930_turbo` is **1,638.5 MB**
- the user's existing hand-copied install measures **1,563 MiB = 1,638.9 MB**

They are the same thing. There is no doubling, and no hidden second copy to reclaim.

## Sizes, smallest first

"Displaces default?" = whether installing it alongside today's
`openai_whisper-large-v3-v20240930_turbo` would **silently become the model every
transcription uses** — because `WhisperModelCatalog.installedModels()` sorts by
`variantDirectoryName` and `resolveModel(nil)` takes `.first`
(`WhisperModelCatalog.swift:327-333, 348`).

**The ordering in this column was confirmed by running Swift's own `String <` over
all 27 names, not inferred from the Python that first computed it.** That mattered
for two rows that turn on punctuation rather than letters — `openai_whisper-small`
vs `openai_whisper-small.en_217MB`, and `..._turbo` vs `..._turbo_632MB` — where a
Unicode-canonical collation could in principle disagree with byte order. It does
not: Swift returns the same order, the same first element
(`distil-whisper_distil-large-v3`), and the same count of 14 variants sorting ahead
of the installed one.

| variant | download MB | displaces default? |
|---|---:|---|
| `openai_whisper-tiny` | 76.6 | no |
| `openai_whisper-base.en` | 146.7 | yes |
| `openai_whisper-base` | 146.7 | yes |
| `openai_whisper-tiny.en` | 153.0 | no |
| `openai_whisper-small_216MB` | 217.4 | no |
| `openai_whisper-small.en_217MB` | 217.9 | no |
| `openai_whisper-small` | 486.5 | no |
| `openai_whisper-small.en` | 486.5 | no |
| `openai_whisper-large-v3-v20240930_547MB` | 549.6 | yes |
| `distil-whisper_distil-large-v3_594MB` | 594.5 | yes |
| `distil-whisper_distil-large-v3_turbo_600MB` | 607.1 | yes |
| `openai_whisper-large-v3-v20240930_626MB` | 626.7 | yes |
| `openai_whisper-large-v3-v20240930_turbo_632MB` | 645.7 | no |
| `openai_whisper-large-v3_947MB` | 948.1 | no |
| `openai_whisper-large-v2_949MB` | 952.2 | yes |
| `openai_whisper-large-v3_turbo_954MB` | 1,052.8 | no |
| `openai_whisper-large-v2_turbo_955MB` | 1,053.1 | yes |
| `distil-whisper_distil-large-v3` | 1,514.5 | yes |
| `distil-whisper_distil-large-v3_turbo` | 1,527.1 | yes |
| `openai_whisper-medium` | 1,529.7 | no |
| `openai_whisper-medium.en` | 1,529.7 | no |
| `openai_whisper-large-v3-v20240930` | 1,619.5 | yes |
| `openai_whisper-large-v3-v20240930_turbo` | 1,638.5 | no |  ← installed today
| `openai_whisper-large-v2` | 3,090.0 | yes |
| `openai_whisper-large-v3` | 3,090.3 | yes |
| `openai_whisper-large-v2_turbo` | 3,096.5 | yes |
| `openai_whisper-large-v3_turbo` | 3,195.1 | no |

**14 of 27 would take over silently**, and they include the cheap ones a user is most
likely to reach for (`openai_whisper-base` at 146.7 MB, and the quantized
`..._547MB` / `..._626MB`). The inverse is just as awkward: installing
`openai_whisper-large-v3-v20240930_turbo_632MB` — the quantized build of exactly what is
installed today — sorts AFTER it and so would appear to do nothing at all.

## There is no explicit default to pick

Worth stating plainly before the choice is made: **the app has no stored preference for
which model to use.** `WhisperTranscriber` calls `catalog.resolveModel(named:)`
(`WhisperTranscriber.swift:284`); `clip.transcribe` may pass a variant name, and when it
does not, alphabetical order decides. So "which variant ships as the default" is not
currently expressible in the codebase — whatever is chosen, an explicit-default
mechanism has to carry it, or the choice is enforced by filename accident.

One honesty mitigation already exists: every transcription result records
`modelVariantDirectoryName` (`TranscriptionBeats.swift:96`), so a silent switch is at
least visible in the payload after the fact.

**This is now filed as its own roadmap item, `m23-n3e`**, rather than being folded into
whichever variant gets chosen — it is the half that outlives the choice. It is
deliberately sequenced AFTER the user answers, because building a stored default before
there is a chosen value to store would bake in a pick nobody made.

## Catalog compatibility (checked, not assumed)

`WhisperModelCatalog.requiredComponents` = `MelSpectrogram`, `AudioEncoder`,
`TextDecoder` (`:189`). Spot-checked against the Hub listing: `..._turbo`,
`..._626MB`, `distil-..._turbo_600MB` and `base` all carry the three. The optional
`TextDecoderContextPrefill` is present on some and absent on others, which the catalog
explicitly tolerates ("Loaded when present, skipped when absent", `:190-191`). No
quantized or distil candidate is blocked by the catalog.

## Tokenizer, the second fetch

The tokenizer comes from `openai/whisper-<size>`, a different repo. Tokenizer-class
files there total **~4.6 MB** (`tokenizer.json` 2.48 MB dominating). Negligible against
any model, but it is per-variant, not shared — see n3a.

## What is NOT in this document

Accuracy and speed per variant: see `m23-n3c-whisper-variant-tradeoff.md`.
**The choice of default is the user's and is deliberately not made here.**
