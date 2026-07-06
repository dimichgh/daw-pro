# Vendored third-party code

Header-only C++ vendored verbatim (headers + LICENSE files, nothing else) for
the offline time-stretch/pitch-shift facade (M5 ii-b). Upstream repo layout is
preserved so relative includes (`include/` wrappers, `./platform/*`) resolve
unchanged. Only the Accelerate platform backends are vendored — we always
compile with `SIGNALSMITH_USE_ACCELERATE`; the pffft/IPP backends are
preprocessor-dead on this build and were omitted.

| Library | Upstream | Commit | Fetched | License |
|---|---|---|---|---|
| signalsmith-stretch (v1.3.2) | https://github.com/Signalsmith-Audio/signalsmith-stretch | `57b93f4e9206a089a45387eaa39bdc9f310d3308` | 2026-07-05 | MIT (`vendor/signalsmith-stretch/LICENSE.txt`) |
| signalsmith-linear | https://github.com/Signalsmith-Audio/linear | `7f53cdd1ccd52b409dacf2af24e7ff838c5580cd` | 2026-07-05 | MIT (`vendor/signalsmith-linear/LICENSE.txt`) |

To update: clone both repos, re-copy the same file set, update the commit
hashes above, and bump `stretchEngineVersion` in DAWEngine so stale cache
renders are invalidated (see docs/ARCHITECTURE.md, time-stretch seam).
