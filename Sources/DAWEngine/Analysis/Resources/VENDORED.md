# Vendored third-party model weights

`swiftf0.onnx` is the SwiftF0 pitch-detection model, committed verbatim
(m23-ap-2a). It is **397,987 bytes** — a rounding error against a ~17.5 MiB
shipped binary — so it ships as a SwiftPM resource with **no download
infrastructure**. `ai.installSpeechModel` exists for the WhisperKit models,
which are three orders of magnitude larger; it is deliberately not involved
here, and there is no `.gitignore` entry for this file.

| Artefact | Upstream | Commit | Fetched | License |
|---|---|---|---|---|
| SwiftF0 `model.onnx` → `swiftf0.onnx` | https://github.com/lars76/swift-f0 | `64700fce8ef39c2970814bf427ac1d75a2f20d72` | 2026-08-13 | MIT (`SwiftF0-LICENSE`, © 2025 Lars Nieradzik) |

    swiftf0.onnx      397,987 B
    SHA256            7e2390db8379cd9e1e2b22828e55b45b57c8559e4c8335678c717dc245c18176
    SwiftF0-LICENSE     1,071 B
    SHA256            3e1e1a059f12dfb08ec39d7eb0bdb19ba57b937410457b9e4fe008f545bd8891

Model facts, read from the file rather than from documentation: `ir_version 9`,
`opset 20`, input `input_audio` of shape `[1, audio_length]` float32, outputs
`pitch_hz` and `confidence` of shape `[1, frames]` float32, 16 kHz input rate,
hop length 256 (62.5 frames/s), 97,164 parameters, 51 nodes.

## ⚠️ The published PyPI wheel ships a DIFFERENT build of this model

Measured 2026-08-13, and worth stating because it is the kind of thing that
silently invalidates a parity gate:

| Source | Bytes | SHA256 |
|---|---|---|
| GitHub `64700fce` (**vendored here**) | 397,987 | `7e2390db…c18176` |
| PyPI `swift_f0-0.1.2-py3-none-any.whl` | 399,114 | `fa91bb45…8336a5` |

The GitHub artefact is the one the m23-ap-1 route spike measured and the one its
recorded fixture value (220.8 Hz from a 220 Hz sine) belongs to, so it is what
is vendored. **m23-ap-2b's §5.5 parity gate compares against the upstream Python
package — `pip install swift-f0` would install the OTHER weights**, and a parity
failure sourced there would look like an implementation bug. Compare against the
GitHub checkout, or re-derive the reference numbers against the wheel's weights
deliberately.

## To update

Re-fetch `swift_f0/model.onnx` at the new commit, update the commit hash, both
byte counts and both SHA256s above, and re-run
`Tests/DAWEngineTests/PitchTrackerInferenceTests.swift` — its
`vendoredWeightsMatchThePinnedArtefact` leg pins the size and hash, so a swapped
model reddens immediately instead of quietly changing every detected pitch.
