# Standard MIDI File fixtures (m23-k1)

Byte fixtures for the SMF decoder. **Read this before changing, regenerating, or
adding to them.**

## The one rule

**Never regenerate these with DAW Pro's own encoder.** Their entire value is that
they were produced by something that is not our parser and not our writer. A
fixture written by our encoder and read by our decoder proves only that the two
agree — which they will, including when both are wrong in the same direction.
That is the vacuity trap this directory exists to avoid.

## Provenance

| Source | Files | What it gates |
|---|---|---|
| **Apple `AudioToolbox`** (`MusicSequenceFileCreate`) | `apple-type1.mid` | Ordinary structure, as a real third-party encoder emits it. |
| **Hand-authored from the SMF 1.0 spec** | `hazard-*.mid`, `malformed-*.mid` | One parser hazard each — every one of them a thing Apple's encoder never emits. |

m23-k3 added exactly ONE new byte fixture, `hazard-type1-multichannel.mid`, and
that restraint was itself a decision: six of the seven hazards it had to gate
encode MAPPING verdicts, not PARSING claims, and the mapper's input is a
`StandardMIDIFile` VALUE — so those live as hand-built IR cases in
`StandardMIDIFileMapperTests.swift`, where one case carries one hazard with no
unvalidated byte-authoring step in between. **This scopes the one-hazard rule, it
does not relax it, and the rule that makes it safe is: every hand-built IR must
be one the reader can actually produce, and where reachability is ITSELF the
claim, use bytes.** The multi-channel fixture is exactly that case — its claim is
that k1 really does hand k3 a format-1 track with `channels.count == 2`, which no
hand-built IR can establish because a hand-built IR is what would be assumed.

The generator for the hand-authored files is `gen-smf-fixtures.py` and the
validator is `validate-smf.swift`; both live in the **session scratchpad, not in
the repo and not in the build**, deliberately. `AudioToolbox` appears in the
validator only — never in `Sources/DAWCore`, which parses with pure Foundation
`Data` (LAW L9, the `SoundFontPresetReader` precedent).

## Why both sources, and not just Apple's

Apple's encoder emits exactly **one shape**, and it is the shape that omits every
classic parser hazard: no running status, no note-on-velocity-0 note-offs,
format 1 rather than 0, tpqn rather than SMPTE division, and no delta long
enough to need more than a 2-byte VLQ. A decoder gated only against Apple's
output is untested on precisely the things that break real-world SMF import.

So: **Apple gates the shape, hand-authored bytes gate the hazards, one hazard
per fixture.** (This is the m23-z ONE HAZARD PER FIXTURE law, transferred from
drag geometry to parsing. A fixture carrying two hazards cannot tell you which
one broke.)

## Expectation table — CONFIRMED BY APPLE'S LOADER, not asserted by us

Every hazard fixture below was loaded with `MusicSequenceFileLoad` and Apple's
reading matched the bytes' intent. That is what makes this table third-party
evidence rather than the fixture author's opinion. Beats shown are Apple's;
ticks are the file's own, at 480 tpqn unless noted.

The **"Apple-confirmed / spec-asserted"** column says which kind of evidence each
row actually carries, because the two are not interchangeable and the table used
to blur them. *Apple-confirmed* means `MusicSequenceFileLoad` read these bytes
and agreed with the expectation. *Spec-asserted* means Apple cannot be the
witness — it rejects the file, or its beat-native model cannot represent what the
bytes say — so the expectation stands on the SMF 1.0 spec alone. A row that is
spec-asserted is not weaker evidence about OUR parser; it is weaker evidence
about the FILE, and that difference is worth being able to see at a glance.

| Fixture | Apple's reading | The hazard | Apple-confirmed / spec-asserted |
|---|---|---|---|
| `apple-type1.mid` | tempo 120 bpm @beat 0 and 90 bpm @beat 4 (= 500000 and 666666 µs/qn at ticks 0 and 1920); notes 60/62/64/66 on ch 0 and 48/50/52/54 on ch 1, at beats 0/1/2/3 (ticks 0/480/960/1440), each dur 0.5 (240 ticks), velocities 70/80/90/100; CC 11 = 20/60/100 at beats 0/0.5/1 on each channel | **Not a hazard — this row is the ordinary-structure baseline.** Note the counting convention: Apple's loader reports **2** tracks because `MusicSequenceGetTrackCount` excludes the tempo track, while the file has **3** chunks and our decoder reports **3** parts (it keeps the tempo-only chunk rather than filtering it, since filtering is a mapping choice and belongs to k3). Both are right; they count different things. | **Apple-confirmed** (it wrote them). |
| `hazard-running-status.mid` | notes 60@beat 0 dur 3, 62@1 dur 2, 64@2 dur 1 (ticks: 60@0 len 1440, 62@480 len 960, 64@960 len 480) | Events after the first omit their status byte. A reader assuming every event carries one reads `3E` as a status and desynchronises. | **Apple-confirmed.** |
| `hazard-note-on-vel0.mid` | 60@0 dur 0.5, 64@0.5 dur 1.0 (ticks: 60@0 len 240, 64@240 len 480) | Note-off written as note-on with velocity 0. A reader treating it as a note-on ends with four dangling onsets and zero notes. | **Apple-confirmed.** |
| `hazard-type0-multichannel.mid` | 3 notes at beat 0 dur 1.0 on ch 0/1/2, pitches 60/64/67 | Type 0 puts all channels on ONE track — the decoder must split by channel. Type 0 and 1 differ in structure, not just a header field. | **Apple-confirmed.** |
| `hazard-vlq-multibyte.mid` | 60@0, 62@34.4, 64@4403.7334, each dur ≈0.2667 (ticks: 0, 16512, 2113792, len 128) | Deltas needing 2-, 3- and 4-byte VLQs. Apple's own fixture never exceeds 2 bytes. | **Apple-confirmed.** |
| `hazard-controllers.mid` | CC11=20@0, CC11=84@0.5, PB(LSB 0, MSB 64)=8192@1.0, PB(127,127)=16383@1.5, chan-pressure 64@2.0 | Pitch bend is 14-bit **LSB first** — the most commonly reversed decode in the format. | **Apple-confirmed.** |
| `hazard-unknown-chunk.mid` | one note 60@0 dur 1.0; the `XFIR` chunk is skipped | The spec **requires** unknown chunks be skipped by their length. A reader that errors here rejects files other DAWs write happily. | **Apple-confirmed.** |
| `hazard-smpte-division.mid` | **Apple accepts the file but reads it degenerately** (beat −0.0000, dur 0.0000) | Division `0xE728` = −25 fps × 40 ticks/frame = 1000 ticks/sec, absolute time, not tempo-relative. **Not third-party-confirmed** — Apple's beat-native model cannot represent it, which is itself the argument for our IR being tick-native. Assert against the spec: division records as SMPTE(fps 25, ticksPerFrame 40), note at tick 0 length 1000. | **Spec-asserted.** Apple accepts the file but reads it degenerately — its beat-native model cannot represent absolute time, which is itself the argument for our IR being tick-native. |
| `hazard-smpte-meter.mid` (m23-k4a) | format 1, division `0xE728` (25 fps × 40 ticks/frame = 1000 ticks/s), 84 bytes, sha256 `f6eea5727a18dc65a8e4ccbf396933e9fc6d2962e072e510ea6fc067642a72a1`. Chunk 0 = `FF 03 "Conductor"` + `FF 51 07 A1 20` (500000 µs/qn) + **`FF 58 04 03 02 18 08` (3/4)**, end at tick 1000; chunk 1 = `FF 03 "Lead"` + note 60 vel 100 at tick 0 for 1000 ticks | **SMPTE division × TIME SIGNATURE — the one m23-k3 conclusion that had no third-party arbiter**, because no shipped fixture carried an `FF 58` on a SMPTE file. m23-k3's meter half was hand-built-IR-only until this file. **The fixture is hand-derived in `docs/research/m23-k4a-midi-export-design.md` §9.3, and `SMFSMPTEMeterWitnessTests` asserts that `StandardMIDIFileWriter.encode` reproduces it BYTE FOR BYTE** — without that assertion Apple would have arbitrated a hand-authored blob rather than the artifact DAW Pro ships. If the writer's output ever differs, **that difference is the finding**: report it and re-flag the leg, do not adjust the fixture. | **Apple-confirmed:** the file is a valid SMF (`MusicSequenceFileLoad` status 0), a `0xE728` division does not prevent parsing, and the `FF 58` payload is present and readable (`META type=0x58 len=4 payload=03 02 18 08` on the tempo track). **NOT Apple-confirmed — spec/design-asserted:** any TIMING. Every timestamp comes back `-0.0` and the note duration `0.0`, exactly as for `hazard-smpte-division.mid`; Apple's beat-native model collapses absolute time. So "the note lands at 2.0 beats through the PROJECT's tempo map" remains ours alone and is gated against our own mapper, never against Apple. |
| `hazard-type1-multichannel.mid` | one `MusicTrack` (Apple counts 1, excluding the tempo track) carrying events on **two channels**: CC 11 = 20 on ch 0 and CC 11 = 100 on ch 1, note 60 vel 100 on ch 0 and note 48 vel 80 on ch 1, both at beat 0 dur 1.0; tempo 120 @beat 0 | **A format-1 `MTrk` that speaks on more than one channel.** Format 0 is the split everyone remembers; this is the one they forget. The decoder passes such a chunk through WHOLE (`channels == [0, 1]`, `channel == nil`), which is correct for a faithful readout — and it is m23-k3's MAPPING that must then split it into one DAW track per channel, because a clip holds at most one controller lane per type, so merging the two CC 11 streams would put two values on one beat and the equal-beat last-wins dedupe would silently eat one. The two CC values differ (20 vs 100) precisely so a track-COUNT-only assertion cannot pass a merging mapper. | **Apple-confirmed** for the BYTES (one track, events on 2 channels, both notes and both CC values). The SPLIT is our mapping decision and is spec/design-asserted — Apple has no opinion about how a host lays a multi-channel track out. |

## Malformed set

All five are rejected by Apple's loader. Ours must give a **teaching error** —
never a crash, and never a plausible-looking empty parse that reads as "this file
has no notes."

| Fixture | Defect | Apple |
|---|---|---|
| `malformed-empty.mid` | zero bytes | rejects (−10871) |
| `malformed-truncated-header.mid` | 7-byte `MThd`, no body | rejects (−10871) |
| `malformed-bad-magic.mid` | chunk tag `MThX` | rejects (**−10870**, a different status from the rest) |
| `malformed-truncated-track.mid` | `MTrk` length claims 100 bytes, 3 follow | rejects (−10871) |
| `malformed-no-end-of-track.mid` | honest length, no `FF 2F 00` | rejects (−10871) |

`malformed-no-end-of-track.mid` is a **judgement call, not a settled answer**:
strict rejection matches Apple and matches this file's placement in the
malformed set, but real-world files do sometimes omit the marker, and a tolerant
recovery-with-warning would be defensible. Whichever is chosen must be pinned by
a test and the reasoning recorded — the one unacceptable outcome is silently
returning the notes as though the file were well-formed.

## The `encode-*` set — EXPECTED OUTPUT, not input (m23-k2)

The `encode-*.mid` files are a different kind of fixture and must not be read as
decoder inputs. Each one is **the exact bytes the encoder must produce** for a
stated input IR under a stated policy. They were hand-authored from the SMF 1.0
spec **before the encoder existed**, so the encoder has to match this table
rather than the table being read off the encoder.

They were validated by **two independent readers before being pinned** — Apple's
`MusicSequenceFileLoad` and DAW Pro's own k1 decoder — which agreed on every
value. Generator: `gen-encode-fixtures.py` (session scratchpad, not in the
build); readers: `dump-smf.swift` and the `dumpir` target of `probe-smf/`.

| Fixture | Input IR | What its bytes pin |
|---|---|---|
| `encode-minimal.mid` (63 B) | format 1, div 480; part 0 tempo-only (endTick 0); part 1 "Lead", ch 0, one note tick 0 len 480 n 60 vel 100 **relVel 64**, endTick 960; tempo 500000 @ tick 0 src 0 | P1 tempo goes to the track its `sourceTrackIndex` names · P2 note-off spelled `8n`, **not** `9n` with velocity 0 · P3 the velocity slot carries `releaseVelocity` verbatim · P4 running status OFF by default · P5 track name at delta 0 before channel events · P6 end-of-track at `endTick`, even when that is past the last note |
| `encode-format0-merge.mid` (51 B) | the same two-part shape with **format 0 requested**; part A ch 0 n 60 vel 100 tick 0 len 480 endTick 480; part B ch 0 n 60 vel 90 tick 480 len 480 endTick 960 | P7 format 0 merges all parts into ONE `MTrk` · P8 at an equal tick the order is **meta → note-off → controller → note-on** · P9 the merged end-of-track is the maximum `endTick` |
| `encode-controllers.mid` (57 B) | format 1, div 480, one track "Ctrl" on **channel 2**: cc(11)=84 @0, note 64 vel 100 @0 len 480, pitchBend 2048 @240, channelPressure 64 @720, endTick 960 | P10 pitch bend written 14-bit **LSB first** · P11 channel pressure is a TWO-byte message · P12 the channel nibble comes from the event, not a hardcoded 0 |

**P2 and P3 are two decisions, not one.** P2 chooses the note-off *spelling*;
P3 chooses what goes in its velocity slot. They are separable — `9n`-with-0 has
no velocity slot to fill — and only `encode-minimal.mid` exercises a nonzero
release velocity at all, because Apple's encoder never writes one and so no
decoded file will produce one. Apple's loader **does** report `relVel 64` back,
so P3 is third-party-confirmed and not merely byte-pinned.

**P8 is the one that will bite.** `encode-format0-merge.mid` is deliberately the
hardest case in the set: two parts, same channel, same pitch, one ending exactly
where the next begins. Emit B's note-on before A's note-off and the file is
still valid SMF — but any reader pairs the wrong events, giving a zero-length
note and a dangling one. Apple's reading discriminates: it must show **two**
notes, 60@beat 0 and 60@beat 1, each `dur 1.0`, velocities 100 then 90.

**Note the one place decode is not the inverse.** Decoding
`encode-format0-merge.mid` gives **one** part, not the two that were encoded —
format 0 splits by *channel*, and both parts are on channel 0. That is correct
and expected; it is also why round-tripping through our own decoder cannot be
the gate here (see the m23-k2 roadmap line).

## Integrity

SHA-256 pins are in the m23-k1, m23-k2 and m23-k3 close-out records in
`docs/ROADMAP.md`. If a fixture's hash changes, the expectation tables above are
no longer evidence of anything until they are re-validated against Apple's
loader.
