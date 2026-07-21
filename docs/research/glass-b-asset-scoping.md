# glass-b — GPT-Image asset scoping evaluation

**Date**: 2026-07-20 · **Item**: M8 (glass-b), remaining half after the app icon landed 2026-07-19
**Question**: which app surfaces (beyond the icon) genuinely want generated art — and for those that do, do generated candidates clear the design-language bar?
**Method**: every candidate surface read at source; verdicts held against `docs/DESIGN-LANGUAGE.md` and the glass-a/c compliance audits (`design-audit-glass-a.md` — the cockpit is already highly compliant, so decoration is presumed guilty until proven helpful). Candidates generated via `scripts/gen-art.mjs` (gpt-image-2, 1536×1024), reviewed at full size AND at the size they would actually render (640×220 @2x banner crops). Assets live in `assets/generated/` (gitignored); **promotion into Sources/Resources + wiring is a separate follow-up item, not done here**.

## Verdict table

| Surface | Code | Verdict | One-line rationale |
|---|---|---|---|
| Onboarding **welcome** card | `Sources/DAWApp/Onboarding/OnboardingTourView.swift:20-127` (centered framing card, `OnboardingTourView.swift:159` places it) | **GENERATE** — candidate ready | One-time framing moment, pure typography today; art sits over no live data; the canonical first-run hero slot. |
| Onboarding **done** card | same card component, `done` step (`DAWAppKit/OnboardingModel.swift:138-140` "You Made a Song") | **GENERATE** — candidate ready | Celebration framing card; same reasoning; a distinct "finished song" image rewards completion. |
| Onboarding **task** cards (5 coach-marks) | `OnboardingTourView.swift:159-173` (anchored beside controls) | **SKIP** | Coach-marks point at live controls; art inflates the measured card height that drives flip-above-anchor placement and adds noise beside the very control the user must operate. |
| Arrange empty state ("No tracks yet") | `Sources/DAWApp/TrackListView.swift:88-117` | **SKIP** | The ADD TRACK chip is the designed focal point (m10-i, comment at :98-100); the area is size-variable (250-420 pt sidebar × window height, a fixed-ratio PNG crops unpredictably); on first run the welcome card already overlays this exact moment — art in both would double up. |
| Mixer "No inserts" / "No sends" | `Sources/DAWApp/Mixer/MixerStripView.swift:363-368` / `:159-164` | **SKIP** (categorical) | 9 pt honest-status captions inside 132 pt strips, repeated per strip across the rack; per-strip art = N copies of noise and variable heights that break the m17-f F2 cross-strip row registration (the alignment-slot law). |
| Sketchpad idle (empty CANDIDATES) | `Sources/DAWApp/Sketchpad/SketchpadView.swift:314-319` | **SKIP** | The panel already carries maximal AI identity (violet hairline/chip/GENERATE); the caption is transient (the user is about to generate); the m17-f F4 compression law makes vertical space in the one scroller precious; any art here would have to be violet yet must not out-glow the REAL violet state signals (armed GENERATE, progress cards) — net-negative. |
| Cockpit backgrounds / panel textures (the roadmap's general class) | app-wide Canvas surfaces | **SKIP** (confirming the roadmap's own suspicion) | Meters, waveforms, the vibe meter and the timeline are data displays on flat near-black; texture under them costs contrast floor, invites banding, and competes with the one signature visualization (vibe meter). glass-a found these surfaces CLEAN — decoration can only subtract. |

Net: **two GENERATE surfaces, both onboarding framing cards; everything else needs no generated art.** The cockpit itself stays hand-drawn — that is a feature of the design language, not a gap.

## Why the two framing cards clear the bar (and nothing else does)

The welcome/done cards are the only surfaces in the app that are (a) one-time framing moments rather than working chrome, (b) centered over a dimmed workspace with no live data underneath, and (c) currently pure typography (`OnboardingCard` is title + body + CTA). A hero banner there is the industry-standard first-run treatment, adds warmth for exactly the beginner audience the tour serves, and cannot interfere with any meter, readout, or anchored control. Every other empty state is either honest status (mixer captions), a CTA the art would compete with (arrange), or an already-saturated AI surface (Sketchpad).

## Generated candidates

### 1. `assets/generated/onboarding-welcome-hero.png` — welcome card banner

**Final prompt** (gpt-image-2, 1536×1024, non-transparent):

> Wide dark cinematic banner illustration for a music production app welcome screen. A sleek futuristic studio mixing console seen at a low dramatic angle in a near-black room, background color deep near-black #0B0D12, dark glass panels. Thin neon cyan #3EE6FF accent lines: glowing fader tracks, a single glowing cyan waveform hovering above the console, soft cyan light bloom. A few tiny faint warm amber LED dots on the hardware. Night-flight avionics meets high-end studio hardware aesthetic. Minimalist, lots of empty dark space, calm and precise. Absolutely no text, no letters, no numbers, no logos, no watermarks.

**Pixel review against the design language** (first attempt accepted, no retries needed):

- **Palette**: cyan-dominant on a near-black field — correct for the tour's NON-VIOLET rule (`OnboardingTourView.swift:11-15`); cyan is the tour's own active accent, so the art and the chrome (cyan dots, cyan CTA) speak one language. Faint amber LEDs read as studio hardware, not as the warning semantic — they are tiny, dim, and clearly diegetic. **No violet anywhere** (Rule 3 holds: nothing on this card is AI content). No red, no green.
- **Base field**: top-left corner averages ≈ `#000206` — *darker* than the `#0B0D12` base surface. Acceptable **as a clipped media well** (an inset darker than the panel reads like a screen), but it should not be used full-bleed as card background; see promotion notes.
- **Text**: none legible. The console screens carry abstract blocky UI patterns; at the 320 pt render width (≈4.8× downscale) they compress to texture. Verified on the 640×220 preview.
- **Size survival**: the center-band 2.9:1 crop keeps the hovering waveform (crisp at 640 px) over the fader field; console detail compresses gracefully. Survives.
- **Glow discipline**: the glow inside the image depicts *signal* (a waveform, lit fader tracks) — consistent with the house meaning of glow. See the standing tension noted below.

### 2. `assets/generated/onboarding-done-hero.png` — done card banner

**Attempt 1 — FAILED, regenerated.** The phrase "night-flight avionics" was taken literally: the image contained an airplane cabin window with a planet horizon top-left — an off-theme narrative element (this is a studio, not a spacecraft). Recorded per the honest-failure rule; the metaphor phrase was removed and the background locked to "plain seamless, no room, no windows, no environment."

**Final prompt** (retry 1, gpt-image-2, 1536×1024, non-transparent):

> Wide dark cinematic banner illustration for a music production app completion screen, celebrating a finished song. A single elegant modern vinyl turntable made of dark glass on a plain seamless near-black background, background color #0B0D12, no room, no windows, no environment details, pure dark emptiness around the subject. The record groove glows as a thin neon cyan #3EE6FF circular waveform ring with soft cyan bloom; one small calm green #5DFF9F indicator light glows on the plinth. High-end minimalist studio hardware aesthetic, precise, quietly triumphant. Absolutely no text, no letters, no numbers, no logos, no watermarks.

**Pixel review against the design language**:

- **Palette**: cyan waveform-ring (the song, made physical) + exactly **one** small green LED — green = success/healthy is the correct house semantic for "You Made a Song", used at indicator scale, not as a wash. No violet (correct — the done card's chrome is deliberately non-violet even though its body mentions Copilot, `OnboardingTourView.swift:12-15`). No amber, no red.
- **Base field**: corner averages ≈ `#000001` — same darker-than-base note as the welcome hero; same media-well framing applies.
- **Text**: none. The record label is blank; no glyphs anywhere.
- **Size survival**: at 640×220 center crop the ring reads immediately as a waveform pressed into vinyl; the green LED stays visible; the tonearm survives. A crop biased slightly upward (≈40 px) centers the ring better — promotion-time tuning.
- **Concept**: groove-as-waveform is the strongest single image for "that's a real song — saved" and stays inside the studio-hardware register.

## Standing tension flagged for the human eye

`DESIGN-LANGUAGE.md` Rule ("Glow recipe"): *"Never glow static chrome."* A hero illustration is static, and both candidates contain glow. Position taken here: these are **content images on one-time framing cards, not chrome** — the glow inside them depicts signal (waveform, groove), which is exactly what glow means house-wide, and the card's actual chrome (dots, CTA, ring) keeps its earned-state discipline unchanged. But this is a judgment call at the edge of the written rule, so: **if the human eye reads the banners as "glowing chrome," the correct resolution is to drop them, not to weaken the rule.** If they are promoted, DESIGN-LANGUAGE.md should gain one sentence scoping the exception (framing-card media wells may contain depicted glow; chrome glow rules unchanged) — that edit belongs to the promotion item.

## Follow-up (separate item — NOT done in this flight)

Worth promoting, pending the human-eye check above:

1. `assets/generated/onboarding-welcome-hero.png` → welcome-card banner
2. `assets/generated/onboarding-done-hero.png` → done-card banner

Promotion item scope: downscale/crop masters to ~640×220 @1x+@2x (center crop; done-hero biased ≈40 px up), add to `Sources/DAWApp/Resources/`, render as a rounded-rect **clipped media well at the top of `OnboardingCard`** for the two unanchored framing steps only (welcome/done — task cards must stay art-free), no SwiftUI `.glow` on or around the image, hairline border per the panel idiom, and re-measure the card height math (`OnboardingTourOverlay.cardSize`) — centered placement makes the +~110 pt height benign at the 640 pt window floor, but verify. Add the one-sentence DESIGN-LANGUAGE.md scoping note. All other surfaces: **no generated art, by decision** — this table is the record, so the question doesn't reopen every cycle.
