#!/usr/bin/env python3
"""Six vertical Shorts cut from the same session and the same measurements.

Not clips of the film: each is written as its own 40-second argument, because a
Short that is a slice of a long video always feels like one. What they share
with the film is the AUDIO and the NUMBERS, which is the point -- the same
render, measured once, quoted in two places.
"""
import json, os

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(f"{HERE}/MEASUREMENTS.json"))
S, A = f"{HERE}/shots", f"{HERE}/audio"
SIR, HRT, THU, SAT, RN, VOW = (M["siren"], M["heart"], M["thunder"],
                               M["saturator"], M["rain"], M["vowels"])

def sp(t): return "   ".join(t.upper())
def sh(name, zoom=None):
    return {"path": f"{S}/{name}.png", "zoom": zoom} if zoom else f"{S}/{name}.png"

# Portrait crops: the app is a wide window, so a 9:16 frame has to take a
# COLUMN out of it. A full-window shot letterboxed into portrait is unreadable.
PANEL = [0.30, 0.30, 0.34, 0.60]     # a floating editor panel, centred
HEADS = [0.00, 0.05, 0.22, 0.62]     # the track headers column

SHORTS = [
  dict(id="V1", short="One Note Siren", tags="#sounddesign #synthesis #musicproduction".split(), title="A siren is one note",
       theme="quicktip", loop=f"{A}/siren.wav", playMax=8.0,
       cards=[
         dict(type="statement", size=76, lines=["A SIREN", "IS ONE NOTE"],
              sub=["it never changes pitch", "something else does the moving"]),
         dict(type="bignumber", label=sp("measured off the render"),
              value=f'{SIR["sweep_semitones_measured"]}', unit=sp("semitones"),
              notes=[f'the pitch-bend lane asked for {SIR["sweep_semitones_asked"]:.2f}',
                     f'{SIR["f0_min_hz"]} Hz to {SIR["f0_max_hz"]} Hz']),
       ],
       stages=[
         dict(id="01-hook", shots=[0], cut=3.4, loop=f"{A}/siren.wav",
              bedEligible=False, playMax=6.0,
              narration=("That siren is a single held note. It does not change "
                         "pitch even once.")),
         dict(id="02-why", shots=[1], cut=3.4,
              factCheck=[["three point nine seven", "3.97"]],
              narration=("What moves is a pitch-bend curve underneath it — a "
                         "triangle wave rising and falling twice a second. I "
                         "asked for four semitones. Measured off the rendered "
                         "file, it sweeps three point nine seven. One note, one "
                         "curve, and no sample anywhere.")),
       ]),

  dict(id="V2", short="Heartbeat Under 60Hz", tags="#sounddesign #bass #musicproduction".split(), title="Why a heartbeat vanishes on your phone",
       theme="quicktip",
       cards=[
         dict(type="bignumber", label=sp("a synthesised heartbeat"),
              value=f'{HRT["pct_below_60hz"]}%', unit=sp("below 60 hz"),
              notes=[f'{HRT["pct_60_120hz"]}% from 60 to 120 Hz',
                     f'{HRT["pct_above_120hz"]}% above that']),
         dict(type="statement", size=72, lines=["YOUR PHONE", "CANNOT PLAY IT"],
              sub=["a phone speaker gives up around 400 Hz",
                   "so the sound is there and you hear none of it"]),
       ],
       stages=[
         dict(id="01-play", shots=[0], cut=3.4, loop=f"{A}/heart.wav",
              bedEligible=False, playMax=6.0,
              factCheck=[["ninety four", "94"]],
              narration=("This heartbeat is a sine wave at about forty nine "
                         "hertz, hit twice. Ninety four per cent of its energy "
                         "is below sixty hertz.")),
         dict(id="02-point", shots=[1], cut=3.4,
              narration=("Which is why it feels like pressure in your chest in a "
                         "cinema, and why it disappears completely on a phone. "
                         "The sound is still there. Your speaker simply cannot "
                         "make that note.")),
       ]),

  dict(id="V3", short="The 808 Is A Sine", tags="#808 #bass #musicproduction".split(), title="The 808 is a sine wave someone ruined",
       theme="remix",
       cards=[
         dict(type="statement", size=74, lines=["THE 808", "IS A SINE WAVE"],
              sub=["that somebody deliberately ruined"]),
         dict(type="list", title=sp("what drive adds"), step=76,
              items=[["0 dB", f'{SAT["harmonics_pct_at_0db"]:.3f} % above the fundamental'],
                     ["14 dB", f'{SAT["harmonics_pct_at_14db"]:.3f} %'],
                     ["32 dB", f'{SAT["harmonics_pct_at_32db"]:.3f} %', "hot"],
                     ["the note never moved", "44 Hz in all three"]]),
       ],
       stages=[
         dict(id="01-ab", shots=[0], cut=3.2, loop=f"{A}/bass808.wav",
              bedEligible=False,
              ab=dict(before=f"{A}/bass808-clean.wav", seconds=4.0, cycles=2,
                      beforeShots=[0], afterShots=[1]),
              narration=("Clean sine on the left. Saturated sine on the right. "
                         "Same note, forty four hertz, both times.")),
         dict(id="02-why", shots=[1], cut=3.4,
              factCheck=[["seven point five nine seven", "7.597"]],
              narration=("Nothing was added underneath. What changed is above: "
                         "at no drive, zero per cent of the energy sits above "
                         "the fundamental. At thirty two decibels, seven point "
                         "five nine seven per cent does. Those harmonics are the "
                         "part a small speaker can actually reproduce — which is "
                         "why the distorted one sounds bigger on a device that "
                         "cannot play the note at all.")),
       ]),

  dict(id="V4", short="A Vowel Is Two Numbers", tags="#formants #synthesis #musictheory".split(), title="A vowel is two numbers",
       theme="theory",
       cards=[
         dict(type="statement", size=74, lines=["A VOWEL", "IS TWO NUMBERS"],
              sub=["no voice, no sample, no model"]),
         dict(type="list", title=sp("two eq peaks on a saw"), step=74,
              items=[["ee", f'{VOW["ee"][0]} / {VOW["ee"][1]} Hz'],
                     ["ah", f'{VOW["ah"][0]} / {VOW["ah"][1]} Hz', "hot"],
                     ["oo", f'{VOW["oo"][0]} / {VOW["oo"][1]} Hz'],
                     ["F1 and F2", "that is the entire trick"]]),
       ],
       stages=[
         dict(id="01-hear", shots=[0], cut=3.4, loop=f"{A}/vowel.wav",
              bedEligible=False, playMax=9.0,
              narration=("There is no voice in this. It is a saw wave through an "
                         "equaliser.")),
         dict(id="02-how", shots=[sh("fx-voice-eq", PANEL), 1], cut=3.4,
              factCheck=[["seven hundred and thirty", "730"], ["formant"]],
              narration=("The difference between ee and ah and oo is almost "
                         "entirely two resonances, called the first and second "
                         "formant. Park two narrow EQ peaks at seven hundred and "
                         "thirty and one thousand and ninety hertz, and a saw "
                         "wave says ah. Move the two peaks and it says something "
                         "else.")),
       ]),

  dict(id="V5", short="I Failed To Make Rain", tags="#sounddesign #synthesis #honest".split(), title="I tried to make rain and failed",
       theme="theory",
       cards=[
         dict(type="bignumber", label=sp("how noise-like a sound is"),
              value=f'{RN["flatness_attempt2"]}', unit=sp("spectral flatness"),
              notes=[f'white noise: {RN["flatness_white_noise"]}',
                     f'one pure tone: {RN["flatness_single_sine"]:.4f}',
                     "this is my best attempt at rain"]),
         dict(type="list", title=sp("the honest version"), step=76,
              items=[["attempt 1", f'{RN["flatness_attempt1"]}'],
                     ["attempt 2", f'{RN["flatness_attempt2"]}', "hot"],
                     [f'{RN["improvement_factor"]}x better',
                      f'and still {RN["short_of_noise_factor"]}x short of noise']]),
       ],
       stages=[
         dict(id="01-fail", shots=[0], cut=3.2, loop=f"{A}/rain2.wav",
              bedEligible=False, playMax=6.0,
              factCheck=[["noise oscillator"]],
              narration=("That is supposed to be rain, and it is not rain. My "
                         "synth has no noise oscillator, so I tried to build "
                         "noise out of thousands of very short blips.")),
         dict(id="02-numbers", shots=[1], cut=3.4,
              factCheck=[["zero point five six", "0.5615", "0.56"]],
              narration=("There is a measure for how noise-like a sound is. "
                         "White noise scores zero point five six. A pure tone "
                         "scores zero. My first attempt scored zero point zero "
                         "zero zero one, my second zero point zero one five "
                         "seven. A hundred and fifty seven times better, and "
                         "still thirty six times short. So it became a hi-hat "
                         "instead, which is a very old story in this industry.")),
       ]),

  dict(id="V6", short="Thunder Is A Filter", tags="#sounddesign #synthesis #automation".split(), title="Thunder is a filter closing",
       theme="remix",
       cards=[
         dict(type="statement", size=74, lines=["THUNDER", "IS NOT A PITCH"],
              sub=["it is a spectrum collapsing"]),
         dict(type="list", title=sp("centroid over eight seconds"), step=76,
              items=[["automation ON",
                      f'{THU["centroid_lane_on_start_hz"]} → {THU["centroid_lane_on_end_hz"]} Hz', "hot"],
                     ["automation OFF",
                      f'{THU["centroid_lane_off_start_hz"]} → {THU["centroid_lane_off_end_hz"]} Hz'],
                     ["the second line", "is the control that proves the first"]]),
       ],
       stages=[
         dict(id="01-hear", shots=[0], cut=3.2, loop=f"{A}/thunder2.wav",
              bedEligible=False, playMax=7.0,
              narration=("Thunder is not a note. It is a bright crack that loses "
                         "its top end as it rolls away from you.")),
         dict(id="02-how", shots=[1], cut=3.4,
              factCheck=[["six hundred and fifty two", "652"]],
              narration=("So this is a wide cluster of saw waves with a low-pass "
                         "filter closing over it. The brightness falls from six "
                         "hundred and fifty two hertz to two hundred and twenty. "
                         "And I rendered it a second time with the automation "
                         "switched off, to be sure the filter was doing it — that "
                         "one only falls to three hundred and fifty seven.")),
       ]),
]

if __name__ == "__main__":
    for s in SHORTS:
        body = " ".join(st["narration"] for st in s["stages"])
        spec = dict(id=s["id"], title=s["title"], theme=s["theme"],
                    filename=f'DAW Pro Short {13 + SHORTS.index(s)} - {s["short"]}',
                    size="1080x1920", playMax=s.get("playMax", 8.0),
                    playlist="Shorts", categoryId="27",
                    description=(body + "\n\nEverything in this clip was built inside "
                                 "DAW Pro from saw, square, triangle and sine — no "
                                 "sample, no recording, no generation model. Every "
                                 "figure was measured off the rendered audio.\n\n"
                                 "DISCLOSURE\nThe narration is a synthetic voice, "
                                 "generated locally. No music-generation model was "
                                 "used.\n\n#Shorts " + " ".join(s["tags"])),
                    tags=[t.lstrip("#") for t in s["tags"]],
                    cards=s["cards"], stages=s["stages"])
        p = f"{HERE}/{s['id']}.json"
        json.dump(spec, open(p, "w"), indent=1, ensure_ascii=False)
        words = sum(len(st["narration"].split()) for st in s["stages"])
        print(f"{s['id']}  {words:3d} words  {s['title']}")
