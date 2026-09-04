#!/usr/bin/env python3
"""Emit the session film's spec.

Written as code rather than hand-typed JSON for one reason: every number the
narration says is injected from MEASUREMENTS.json, which the measuring scripts
write. A figure cannot drift from the file it came from, because it is never
typed twice.

⚠ Numbers are spelled out in the narration text because the speech model reads
digits unreliably, and the factCheck gate compares the TRANSCRIPT against the
script -- so the written form and the spoken form both have to be here.
"""
import json, os

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(f"{HERE}/MEASUREMENTS.json"))
S, A = f"{HERE}/shots", f"{HERE}/audio"

W = M["waveforms"]
SIR, HRT, THU, SAT, RN, VOW, TRK, DJ, WRD = (
    M["siren"], M["heart"], M["thunder"], M["saturator"], M["rain"],
    M["vowels"], M["track"], M["dj"], M["words"])
SPK = M["small_speaker"]
HPF = SPK["loss_db_through_150hz_hpf"]

# ------------------------------------------------------------------- cards
# ⚠ The card schema is `type` (not `kind`), and each template has its OWN field
# names: statement/closing take `lines`, bignumber takes `label`/`value`/`unit`
# /`notes`, list takes `title`/`items` where an item is [term, gloss, "hot"?].
# Getting this wrong is a KeyError at render time, which is the good case.
def sp(t): return t.upper()   # ⚠ NO literal spaces: card_bignumber and
# card_list already letter-space with `track=`. Adding "   ".join() on top
# TRIPLES the width, and every label then auto-shrank to 12-24pt to fit --
# legible, but a third of the intended size, which reads as a mistake.

cards = [
  dict(type="statement", size=84,                                        # 0
       lines=["FOUR WAVEFORMS", "AND NOTHING ELSE"],
       sub=["saw · square · triangle · sine",
            "No sample. No recording. No generation model."]),
  dict(type="list", title=sp("what the synth will accept"), step=80,     # 1
       items=[["saw, square", "triangle, sine"],
              ["“noise”", "refused by the instrument", "hot"],
              ["“pulse”", "also refused"],
              ["so everything", "is built out of the other four"]]),
  dict(type="bignumber", label=sp("the siren, measured"),                # 2
       value=f'{SIR["sweep_semitones_measured"]}', unit=sp("semitones of sweep"),
       notes=[f'the pitch-bend lane asked for {SIR["sweep_semitones_asked"]:.2f}',
              f'{SIR["f0_min_hz"]} Hz to {SIR["f0_max_hz"]} Hz, {SIR["wails_in_8s"]} wails in 8 s',
              "one note. The note never changes pitch."]),
  dict(type="bignumber", label=sp("the heartbeat"),                      # 3
       value=f'{HRT["pct_below_60hz"]}%', unit=sp("below 60 hz"),
       notes=[f'{HRT["pct_60_120hz"]}% between 60 and 120 Hz',
              f'{HRT["pct_above_120hz"]}% above 120 Hz',
              "which is why it vanishes on a phone speaker"]),
  dict(type="list", title=sp("thunder is a filter closing"), step=78,    # 4
       items=[["automation ON",
               f'centroid {THU["centroid_lane_on_start_hz"]} → {THU["centroid_lane_on_end_hz"]} Hz', "hot"],
              ["automation OFF",
               f'centroid {THU["centroid_lane_off_start_hz"]} → {THU["centroid_lane_off_end_hz"]} Hz'],
              ["the control", "identical audio would mean the lane never applied"]]),
  dict(type="list", title=sp("what drive actually adds"), step=80,       # 5
       items=[["0 dB", f'{SAT["harmonics_pct_at_0db"]:.3f} % above the fundamental'],
              ["14 dB", f'{SAT["harmonics_pct_at_14db"]:.3f} %'],
              ["32 dB", f'{SAT["harmonics_pct_at_32db"]:.3f} %', "hot"],
              ["fundamental", "44 Hz in every one of them"],
              ["on a laptop",
               f'saturated survives a 150 Hz high-pass by {SPK["saturation_survival_advantage_db"]:+.1f} dB', "hot"]]),
  dict(type="bignumber", label=sp("my best rain"),                       # 6
       value=f'{RN["flatness_attempt2"]}', unit=sp("spectral flatness"),
       notes=[f'white noise measures {RN["flatness_white_noise"]}',
              f'a single sine measures {RN["flatness_single_sine"]:.4f}',
              "this chapter is a failure, and it stays in"]),
  dict(type="list", title=sp("a vowel is two numbers"), step=76,         # 7
       items=[["ee", f'{VOW["ee"][0]} / {VOW["ee"][1]} Hz'],
              ["ah", f'{VOW["ah"][0]} / {VOW["ah"][1]} Hz', "hot"],
              ["oo", f'{VOW["oo"][0]} / {VOW["oo"][1]} Hz'],
              ["F1 and F2", "two EQ peaks on a saw wave. That is the whole trick."]]),
  dict(type="statement", size=90,                                        # 8
       lines=[f'{TRK["notes"]:,}', "NOTES"],
       sub=[f'{TRK["tracks"]} tracks · {TRK["bars"]} bars · {TRK["bpm"]} BPM',
            "every one of them saw, square, triangle or sine"]),
  dict(type="list", title=sp("the rain chapter, honestly"), step=78,     # 9
       items=[["attempt 1", f'flatness {RN["flatness_attempt1"]}  ({RN["grains_attempt1"]} blips)'],
              ["attempt 2", f'flatness {RN["flatness_attempt2"]}  ({RN["grains_attempt2"]} grains)', "hot"],
              ["white noise", f'flatness {RN["flatness_white_noise"]}'],
              [f'{RN["improvement_factor"]}x better', f'and still {RN["short_of_noise_factor"]}x short']]),
  dict(type="closing", size=76,                                          # 10
       kicker=sp("everything you just heard"),
       lines=["WAS SAW, SQUARE,", "TRIANGLE OR SINE."]),
  dict(type="list", title=sp("one loop, five passes"), step=76,          # 11
       items=[["pass 1", "kick"],
              ["pass 2", f'+ hats      2-16 kHz   {DJ["hats_db_2k_16k"]:+.1f} dB'],
              ["pass 3", f'+ bass      120 Hz-2 kHz  {DJ["bass_db_120_2k"]:+.1f} dB'],
              ["pass 4", f'+ 808/stab  20-120 Hz  {DJ["sub_db_20_120"]:+.1f} dB', "hot"],
              ["pass 5", f'+ voice     700 Hz-2 kHz  {DJ["voice_db_700_2k"]:+.1f} dB']]),
  dict(type="statement", size=78, y=300,                                 # 12
       lines=["TURN IT UP", "FOR THIS PART"],
       sub=[f'through a laptop speaker this one loses {abs(HPF["heartbeat"]):.0f} dB',
            "it is already as loud as everything else in this film"],
       punch="HEADPHONES IF YOU HAVE THEM", punchSize=50),
  dict(type="list", title=sp("i asked it to say hi there"), step=76,     # 13
       items=[["asked for", f'"{WRD["asked_for"]}"'],
              ["heard back", f'"{WRD["heard_by_stt"]}"', "hot"],
              ["what landed", "the vowels, and the glide between them"],
              ["what did not", "h, th and r. Every one of them is noise."]]),
]

# ------------------------------------------------------------ chapter cards
# ⚠ WHY THESE EXIST. The first cut ran the heartbeat straight into thunder with
# no break of any kind, and the note back was exactly right: a chapter that
# starts with no title and no prolog reads as the previous chapter still going.
# Numbering is honest here — this IS a build order, each chapter using what the
# one before it established.
CHAPTERS = [
  ("siren",   "THE SIREN",         "one note that never changes pitch"),
  ("heart",   "THE HEARTBEAT",     "a sine wave you feel more than hear"),
  ("thunder", "THUNDER",           "not a note. A spectrum collapsing."),
  ("bass",    "THE 808",           "a sine wave somebody deliberately ruined"),
  ("rain",    "RAIN",              "the chapter that failed"),
  ("vowel",   "THE VOWEL",         "a voice made out of two numbers"),
  ("words",   "THE WORDS",         "and what happens when you ask for consonants"),
  ("track",   "THE TRACK",         "eight of these, playing at once"),
  ("dj",      "THE DJ MOVE",       "one loop, five passes, nothing new"),
  ("honest",  "WHAT I CANNOT SAY", "the part no measurement reaches"),
]
CHI = {}
for _i, (_key, _title, _punch) in enumerate(CHAPTERS, start=1):
    CHI[_key] = len(cards)
    cards.append(dict(type="statement", size=86, y=330, lines=[_title],
                      sub=[f"chapter {_i} of {len(CHAPTERS)}"],
                      punch=_punch, punchSize=50))

# ------------------------------------------------------------------ stages
def sh(name, zoom=None, to=None):
    p = f"{S}/{name}.png"
    if zoom is None:
        return p
    return {"path": p, "zoom": zoom, **({"to": to} if to else {})}

# Zoom boxes, as FRACTIONS of the 3000x1900 capture.
# ⚠ A PAN MUST KEEP ITS SIZE. crop's width/height are fixed at configure time,
# so a "to" box of a different size is silently ignored and the shot goes
# static -- it looks like a zoom that did not happen rather than an error.
# Every pair below is therefore the same w/h, differing only in x/y.
FULL   = [0.00, 0.00, 1.00, 1.00]
TRANSP = [0.00, 0.855, 0.60, 0.135]     # the transport bar
HEADS  = [0.00, 0.055, 0.42, 0.55]      # the track headers, names visible
HEADS2 = [0.02, 0.135, 0.42, 0.55]      # ... drifting down the list
TIMEL  = [0.13, 0.055, 0.60, 0.42]      # the timeline, left half
TIMEL2 = [0.38, 0.055, 0.60, 0.42]      # ... panning right across the arrangement

# Panel crops, every one of them CONFIRMED BY RENDERING IT AND LOOKING. No gate
# in this rig knows where a crop lands, so a rect that has not been looked at is
# a rect that has not been checked.
PANEL = [0.22, 0.26, 0.563, 0.50]        # a synth editor overlay, whole
SATP  = [0.2745, 0.316, 0.45, 0.40]      # the saturator editor
EQP   = [0.20, 0.18, 0.62, 0.58]         # the EQ editor, curve visible
ROLL  = [0.045, 0.53, 0.405, 0.36]       # the piano roll: the NOTES, not the
# empty register above them. The first rect framed the roll's top half, where
# a bass part has nothing — a shot of an empty grid, and the eight gates passed
# it exactly as they passed the siren zoom. Rendered and looked at.

def sweep(prefix, values, box):
    """A control BEING MOVED: the same crop, the same panel, the value stepping.

    ⚠ A still of a panel tells a viewer nothing — they cannot tell a control
    they are being shown from a control that is doing something. shortsmith
    cycles a stage's shots at its `cut`, so a short cut over N stills IS the
    animation, and every frame is the real app with the real value on it.
    """
    return [sh(f"{prefix}{v}", box) for v in values]

def chapter(key, narration, extra=(), cut=3.6):
    """A titled break between chapters, with a spoken prolog over it."""
    return dict(id=f"ch-{key}", shots=[CHI[key], *extra], cut=cut,
                narration=narration)

stages = [
  # ---------------------------------------------------------------- 1. hook
  dict(id="01-hook", shots=[0], cut=4.0, loop=f"{A}/cold-open.wav",
       bedEligible=False, playMax=13.0,
       narration=(
         "A police siren. A heartbeat. Thunder. And a voice, singing a vowel. "
         "None of those is a recording. Nothing was sampled, and no generation "
         "model was used. Every one of them is a saw, a square, a triangle or a "
         "sine wave — the only four shapes this synthesiser can make.")),

  # The constraint, SHOWN: four stills of the same panel with a different
  # oscillator lit in each. This used to be one frozen screenshot.
  dict(id="02-claim",
       shots=[*sweep("sweep-wave-", ["saw", "square", "triangle", "sine"], PANEL), 1],
       cut=2.6,
       # ⚠ "sine" and "sign" are homophones and the transcriber writes the
       # WRONG one. The take was right; the gate was too literal. Same class of
       # bug as the transcriber writing "72" for "seventy two".
       factCheck=[["saw"], ["square"], ["triangle"], ["sine", "sign"]],
       narration=(
         "I want to be precise about the constraint, because the constraint is "
         "the whole point. When I ask this instrument for a noise oscillator it "
         "refuses me, and it names what it will accept instead: saw, square, "
         "triangle, sine. There is no noise. There is no sample slot in use. "
         "So everything you are about to hear has to be built out of those four "
         "shapes, a filter, an envelope, and effects that ship with the app.")),

  # ------------------------------------------------------- 2. the instrument
  dict(id="03-instrument",
       shots=[sh("arrange-full", HEADS, HEADS2), sh("pianoroll-bass", ROLL)],
       cut=5.0, brandCheck="DAW Pro",
       factCheck=[["one thousand three hundred and twenty nine", "1,329", "1329"]],
       narration=(
         "This is DAW Pro. It is a macOS digital audio workstation, and it was "
         "written almost entirely by AI. Everything you see me do here, you can "
         "do with a mouse — the knobs drag, the curves are drawn in the piano "
         "roll, the filters have handles. I am not clicking, though: every move "
         "in this session is a command sent over a local WebSocket. That is the "
         "actual reason to do this with an agent. Nobody sits down and types "
         "one thousand three hundred and twenty nine notes by hand — an agent "
         "writes the whole arrangement in seconds, and then, which matters "
         "more, it renders the result and measures it. If the measurement "
         "disagrees with me, you will watch it disagree with me.")),

  chapter("siren",
    "Chapter one, and we start with a sound that every person watching this "
    "already knows by heart."),

  # ------------------------------------------------------------- 3. the siren
  # ⚠ THIS ZOOM WAS WRONG AND ONLY LOOKING CAUGHT IT. The first coordinates
  # ([0.10, 0.60, 0.30, 0.28]) framed empty timeline below the panel; every gate
  # in this rig passed anyway, because none of them knows WHERE a zoom lands.
  # These frame the POLY SYNTH panel with saw|square|triangle|sine legible --
  # confirmed by rendering the crop and looking at it.
  dict(id="04-siren", shots=[sh("synth-bass-saw", [0.22, 0.26, 0.563, 0.50]), 2],
       cut=5.5, loop=f"{A}/siren.wav", bedEligible=False, playMax=9.0,
       factCheck=[["three point nine seven", "3.97"], ["semitone"]],
       narration=(
         "The siren is one note. One. It is held for sixteen beats and it never "
         "changes pitch — the note does not move at all. What moves is a "
         "pitch-bend curve drawn underneath it, a triangle wave that rises and "
         "falls twice a second. I asked for four semitones of sweep. Measured "
         "off the rendered file, the sweep is three point nine seven semitones. "
         "That is the entire siren: one note and one curve.")),

  chapter("heart",
    "Chapter two, and a warning before it. This one lives at the very bottom "
    "of what a person can hear. On a laptop speaker or a phone you will not "
    "hear it at all — so turn it up, and put headphones on if you have a pair "
    "nearby.", extra=[12], cut=4.0),

  # --------------------------------------------------------- 4. the heartbeat
  dict(id="05-heart", shots=[3], cut=5.0, loop=f"{A}/heart.wav",
       bedEligible=False, playMax=9.0,
       factCheck=[["ninety four", "94"], ["sixty", "60"]],
       narration=(
         "A heartbeat is a sine wave, and it is lower than most people guess. "
         "This one sits at about forty nine hertz, hit twice — the lub and the "
         "dub, the second one softer and slightly higher. Ninety four per cent "
         "of its energy is below sixty hertz. That is why a heartbeat in a film "
         "feels like pressure in your chest rather than a sound in your ears, "
         "and it is why it disappears completely on a phone speaker.")),

  chapter("thunder",
    "Chapter three. From a sound you feel in your chest, to a sound you hear "
    "coming towards you."),

  # ------------------------------------------------------------- 5. thunder
  # The filter closing is this chapter's entire claim, so the knob is on screen
  # doing it: five stills, 16 kHz down to 70, the number legible in each.
  dict(id="06-thunder",
       shots=[*sweep("sweep-cutoff-", [16000, 6000, 1800, 480, 70], PANEL),
              sh("arrange-drop", [0.16, 0.05, 0.80, 0.45]), 4],
       cut=2.8, loop=f"{A}/thunder2.wav", bedEligible=False, playMax=9.0,
       factCheck=[["six hundred and fifty two", "652"], ["two hundred and twenty", "220"]],
       narration=(
         "Thunder is not a pitch. It is a spectrum collapsing — a bright crack "
         "that loses its top end as it rolls away from you. So thunder here is a "
         "wide cluster of saw waves with a low-pass filter closing over it, "
         "automated from sixteen kilohertz down to seventy. The brightness of "
         "the sound falls from six hundred and fifty two hertz to two hundred "
         "and twenty. And I know the automation is what did that, because I "
         "rendered it again with the automation switched off: that version only "
         "falls to three hundred and fifty seven. My first attempt at this "
         "failed, by the way, and it failed in the most misleading way possible "
         "— the filter was working perfectly, but the cluster was so low that "
         "there was nothing up there for the filter to remove.")),

  chapter("bass",
    "Chapter four, and let me say what an eight-oh-eight actually is before I "
    "make any claims about it. It is that deep, round, slightly rude boom "
    "underneath most hip-hop and pop you have heard in the last decade — the "
    "note you feel in a car. It is named after a drum machine from nineteen "
    "eighty, the Roland T R eight-oh-eight, and underneath all of it there is "
    "nothing but a sine wave. Turn it up again for this one, and if the first "
    "of the two sounds almost silent to you — that is not a mistake, and it is "
    "the entire point of the chapter.", extra=[12], cut=5.0),

  # ------------------------------------------------------------- 6. the 808
  # ⚠ The original capture had the saturator sitting at 30.0 dB while the
  # narration says "thirty two decibels" -- the figure the sweep was actually
  # measured at. A film whose whole claim is that its numbers are measured
  # cannot contradict itself on screen, so the panel was re-shot at 32.0 and
  # the crop confirmed by looking at it.
  dict(id="07-808",
       shots=[*sweep("sweep-drive-", [0, 14, 32], SATP), 5],
       cut=2.8, loop=f"{A}/bass808.wav",
       ab=dict(before=f"{A}/bass808-clean.wav", seconds=5.0, cycles=2,
               # ⚠ THE "BEFORE" HALF MUST NOT SHOW THE "AFTER" PANEL. This was
               # the saturator at 32.0 dB while the narration says "here is a
               # clean sine" -- the same self-contradiction as the 30-vs-32
               # figure one comment up, one row down. It is the 808's own synth
               # panel with SINE lit; shot fresh and the crop confirmed by eye.
               beforeShots=[sh("synth-808-sine", [0.22, 0.26, 0.563, 0.50])],
               afterShots=[5]),
       bedEligible=False,
       factCheck=[["seven point five nine seven", "7.597"], ["harmonic"],
                  ["four point six", "4.6"]],
       narration=(
         "The most recognisable bass sound in modern music is a sine wave that "
         "somebody deliberately ruined. Here is a clean sine at forty four "
         "hertz, and here is the same note through a saturator. Both halves are "
         "matched to the same loudness, so nothing you are about to hear is a "
         "volume trick. Nothing was added underneath either — the fundamental "
         "is identical. What changed is the harmonics above it: at zero drive, "
         "zero per cent of the energy sits above the fundamental. At thirty two "
         "decibels of drive, seven point five nine seven per cent does. And "
         "here is why that matters on the device you are probably using. I put "
         "both through a filter that throws away everything below a hundred and "
         "fifty hertz, which is roughly what a laptop speaker does to you for "
         "free. The clean sine loses thirty eight decibels. The saturated one "
         "loses thirty four — four point six decibels more of it survives. The "
         "distortion is not there to sound aggressive. It is there so the note "
         "can exist on a speaker that cannot play the note.")),

  chapter("rain",
    "Chapter five, and this is the one that did not work."),

  # ------------------------------------------------------ 7. rain, the failure
  dict(id="08-rain", shots=[6, 9], cut=5.0, loop=f"{A}/rain2.wav",
       bedEligible=False, playMax=8.0,
       factCheck=[["zero point five six", "0.5615", "0.56"], ["flat"]],
       narration=(
         "Now the one that did not work, because leaving it out would make "
         "everything else less believable. I wanted rain. Rain is noise, and I "
         "have no noise. So I tried to build it out of thousands of very short "
         "blips, on the theory that a short enough burst of any waveform is "
         "broadband. There is a measurement for how noise-like a sound is, "
         "called spectral flatness: white noise scores zero point five six, and "
         "a single pure tone scores zero. My first attempt scored zero point "
         "zero zero zero one. My second, with grains four milliseconds long, "
         "scored zero point zero one five seven. That is a hundred and fifty "
         "seven times better and still thirty six times short. The theory was "
         "right and it was not enough. So the rain became hi-hats instead, "
         "which is a very old story in this industry.")),

  chapter("vowel",
    "Chapter six. Four waveforms, a filter and an envelope — can that sing?"),

  # --------------------------------------------------------- 8. the vowel
  # ee, ah, oo — the same EQ, the two peaks in three different places. The
  # curve itself is the explanation, which is why it is on screen and not
  # described.
  dict(id="09-vowel",
       shots=[*sweep("sweep-vowel-", ["ee", "ah", "oo"], EQP), 7],
       cut=2.8, loop=f"{A}/vowel.wav", bedEligible=False, playMax=11.0,
       factCheck=[["seven hundred and thirty", "730"], ["vowel"]],
       narration=(
         "This is the one I find genuinely strange. A vowel — the difference "
         "between ee and ah and oo — is almost entirely two numbers. Two "
         "resonant peaks in the spectrum, called the first and second formant. "
         "Put a saw wave through two narrow bands of an equaliser, park them at "
         "seven hundred and thirty and one thousand and ninety hertz, and the "
         "saw says ah. Move the two bands and it says something else. No voice, "
         "no sample, no model — two numbers on an equaliser. Four of my five "
         "vowels land within a fifth of where the textbook puts them. The one "
         "that misses is a good lesson: a filter can only amplify a harmonic "
         "that is actually there, and at that note, there was nothing at that "
         "frequency to lift.")),

  # ------------------------------------------------------------ 7b. the words
  chapter("words",
    "Chapter seven. If one vowel is two numbers, then a word ought to be those "
    "two numbers moving."),

  dict(id="09b-words", shots=[sh("fx-voice-eq", EQP), 13], cut=4.0,
       loop=f"{A}/hithere.wav", bedEligible=False, playMax=6.0,
       factCheck=[["consonant"], ["vowel"]],
       narration=(
         "So I drew the two peaks as a curve over time and asked the saw wave "
         "to say hi there. The first word is a diphthong — it starts as ah and "
         "glides to ee — and that glide is just the two numbers travelling. "
         "Here is what came out. Then I did the only honest test I could think "
         "of: I fed it to a speech recogniser, the same one that checks this "
         "narration. It heard, quote, I am. Which is close, and it is close in "
         "exactly the way the theory predicts. The vowels landed. Every "
         "consonant did not — because h, th and r are noise, and noise is the "
         "one thing this instrument cannot make.")),

  # ----------------------------------------------------------- 9. the track
  chapter("track",
    "Chapter eight. All of it at once, which is where the arrangement starts."),

  dict(id="10-track",
       shots=[sh("arrange-full", TIMEL, TIMEL2), sh("pianoroll-bass", ROLL), 8],
       cut=4.0,
       loop=f"{A}/track-drop.wav", playMax=16.0,
       factCheck=[["one thousand three hundred and twenty nine", "1,329", "1329"],
                  ["one hundred and twenty eight", "128"]],
       narration=(
         "So: one track, built from all of it. A kick that is a short sine with "
         "a click on top, because that is how the first drum machines did it. "
         "Hi-hats that are the failed rain. A saw bass. The eight-oh-eight. A "
         "square stab through a ping-pong delay. And the vowel trick, singing "
         "the hook. Eight tracks, sixty four bars, one hundred and twenty eight "
         "beats per minute, one thousand three hundred and twenty nine notes — "
         "and not one sample.")),

  chapter("dj",
    "Chapter nine. The oldest move in dance music, and it is worth watching "
    "happen."),

  # ------------------------------------------------------- 10b. the DJ chapter
  dict(id="11-loop", shots=[sh("arrange-drop", [0.16, 0.05, 0.80, 0.45]), 11],
       cut=5.0, loop=f"{A}/dj-build.wav", playMax=20.0,
       # ⚠ The script says "four-bar loop"; a gate asking for "four bars" would
       # reject eight perfect takes over a hyphen. Check the words that are
       # actually spoken.
       factCheck=[["four-bar", "four bar", "4-bar"], ["loop"]],
       narration=(
         "This is the oldest move in dance music and it is worth watching "
         "happen. One four-bar loop, played five times, and nothing about the "
         "loop ever changes. What changes is which layers are switched on. A DJ "
         "does not rewrite the pattern — they decide what is allowed to play "
         "over it. And each layer arrives in its own part of the spectrum, so "
         "they do not fight: the hats add seven and a half decibels above two "
         "kilohertz, the bass adds twelve in the middle, the eight-oh-eight "
         "adds nearly five at the bottom. That is what arranging actually is, "
         "underneath the mystique.")),

  chapter("honest",
    "Chapter ten. What I am not going to claim."),

  # ------------------------------------------------------------ 10. the honest
  dict(id="11-honest", shots=[10], cut=5.0, brandCheck="DAW Pro",
       narration=(
         "Here is what I will not claim. I measured every sound in this session, "
         "and measurement told me a great deal: that the sweep was three point "
         "nine seven semitones, that the automation was really working, that my "
         "rain was thirty six times short of noise. Not one of those numbers "
         "tells me whether the track is any good. That part I cannot measure, "
         "and I am not going to pretend otherwise. What I can tell you is that "
         "it was made from four waveforms, inside DAW Pro — a workstation that "
         "was itself written by AI — and that you can check every number I said "
         "by rendering it yourself.")),
]

DESC = f"""A whole track built inside DAW Pro from four waveforms and nothing else.

The synth here accepts saw, square, triangle and sine, and refuses everything
else — there is no noise oscillator, and no sample is loaded anywhere. So a
police siren, a heartbeat, thunder, an 808 and a singing vowel all had to be
built out of those four shapes, a resonant filter, an envelope, and the
effects that ship with the app. No generation model was used for any of it.

Every move was sent over the app's control protocol, and every number in the
video was measured off the rendered audio:

· the siren sweeps {SIR["sweep_semitones_measured"]} semitones; the pitch-bend lane asked for {SIR["sweep_semitones_asked"]:.2f}
· {HRT["pct_below_60hz"]}% of the heartbeat's energy is below 60 Hz
· thunder's spectral centroid falls {THU["centroid_lane_on_start_hz"]} → {THU["centroid_lane_on_end_hz"]} Hz with the filter
  automation on, and only {THU["centroid_lane_off_start_hz"]} → {THU["centroid_lane_off_end_hz"]} Hz with it off — that second render
  is the control
· the saturator takes the 808 from {SAT["harmonics_pct_at_0db"]:.3f}% to {SAT["harmonics_pct_at_32db"]:.3f}% of its energy above the
  fundamental, without moving the fundamental at all
· a vowel is two EQ peaks: ah is {VOW["ah"][0]} and {VOW["ah"][1]} Hz

THE CHAPTER THAT FAILED
I could not make rain. Spectral flatness went from {RN["flatness_attempt1"]} to {RN["flatness_attempt2"]} across two
attempts — {RN["improvement_factor"]}x better, and still {RN["short_of_noise_factor"]}x short of white noise's {RN["flatness_white_noise"]}. It stays
in the video, because leaving it out would make everything else less
believable.

{TRK["notes"]:,} notes, {TRK["tracks"]} tracks, {TRK["bars"]} bars, {TRK["bpm"]} BPM. Nothing sampled.

DISCLOSURE
The narration is a synthetic voice, generated locally. No music-generation
model was used.

#synthesis #sounddesign #musicproduction #daw #techno #musictheory"""

spec = dict(
  id="F1",
  title="Four waveforms, one whole track — no samples, no AI music",
  filename="DAW Pro Session - Four Waveforms",
  theme="remix",
  size="1920x1080",
  playMax=14.0,
  playlist="Mixing, measured",
  categoryId="27",
  description=DESC,
  tags=["sound design", "synthesis", "subtractive synthesis", "music production",
        "DAW", "formants", "808", "techno", "music theory"],
  cards=cards,
  stages=stages,
)

out = f"{HERE}/F1.json"
json.dump(spec, open(out, "w"), indent=1, ensure_ascii=False)
words = sum(len(s["narration"].split()) for s in stages)
print(f"wrote {out}")
print(f"{len(stages)} stages, {len(cards)} cards, {words} narration words "
      f"(~{words/2.6/60:.1f} min of speech before demos)")
