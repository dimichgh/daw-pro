# p2-sing: typed lyrics, sung on your melody (integration design)

**Status: SETTLED BY DESIGN 2026-09-27 (lane W7-SING, `daw-architect`). NOT BUILT.** Nothing in this document was
implemented, run or downloaded while writing it.

**Supersedes** the downstream-epic outline in `docs/design/2026-09-24-p2-sing-spike.md` §5 wherever the two differ. §14
lists every difference and its reason.

**Evidence base, all read for this design:**

- the spike plan, `docs/design/2026-09-24-p2-sing-spike.md`, whole;
- the spike's results: ROADMAP, the p2-sing "RAN 2026-09-25" entry (~:1861);
- the SING-6 own-voice run and the user's picks: ROADMAP `sing-pick = v1` and `sing-own-voice = yes` (:2542–2543), and the
  "SING-6 OWN-VOICE RUN" entry with `sing-own-pick = down18` (:2718–2743). The ROADMAP is being edited while this is written,
  so grep for the quoted words rather than trusting the line numbers;
- the spike code under `~/DAWPro-spikes/sing-soulx/code/`, read-only: `harness.py`, `own_voice.py`, `score_from_notes.py`,
  `f0_score.py`, `s8_tools.py`, `wer.py`, `logs/deviations.md`, `logs/freeze-alt.txt`, `env.sh`;
- the upstream checkout at the pinned commit, read-only;
- `scratchpad/w6/SING6/`: `STATUS.md`, `brief.md`, `make_guides.py`, `steps.md`, `sing-own-down18.json`;
- `docs/research/2026-09-24-lyrics-sung-on-a-melody.md` and `docs/research/2026-09-25-build-our-own-singing-voice.md`;
- the Swift and TypeScript sources cited inline.

**Evidence tags:**

| Tag | Meaning |
|---|---|
| **[M]** | Measured, with where. |
| **[R]** | Read in source: `path:line`. `Sources/DAWControl/Commands.swift` is cited by **case label** and `mcp-server/src/server.ts` by **tool name**, because other lanes are editing both files. |
| **[D]** | Derived by arithmetic from measured inputs. |
| **[A]** | Assumed or chosen, not measured. Every [A] number says what will replace it. |

---

## 0. The decision on one page

1. **Engine.** SoulX-Singer (Apache-2.0 code and weights) at the spike's pins, in score mode.
   - It runs as a **third loopback sidecar on 127.0.0.1:8004**, behind a small standard-library HTTP facade.
   - One request renders one phrase. The model loads when the sidecar starts.
2. **The app owns the job.** `SingJobCoordinator` is an AIServices actor: one instance per app, shared by the wire and the
   UI.
   - It plans the clip into render units and renders them one at a time, with progress and cancel.
   - It keeps a phrase cache keyed by content, runs the landing gates, and lands **one new violet track in one undo**.
   - Note accuracy and word clarity are checked **after** landing. They report; they never block.
3. **Voices.**
   - **"Built-in singer"** is upstream's Chinese-recorded prompt voice (the user's `sing-pick = v1`).
   - **"Your voice"** is a 3–12 s recording of one guided line, recorded in the app or imported. It is checked with the spike
     clip check's one-sentence reasons, and labelled by a new alignment (**Route N**) instead of the spike's Route H.
4. **Keys.** The vocal moves only by **whole octaves** on its own.
   - A key change moves the **whole song**, through a new `project.transpose`.
   - `sing.proposeKey` measures the voice's range (p10, median, p90) and proposes a song key and octave, the way a singer
     picks a key.
   - The default render (`octaveShift: "auto"`) never changes the key.
5. **Residency.** SoulX **always gives way.**
   - A new descriptor flag, `yieldsWhenBusy`, lets any other model's admission evict it, even mid-phrase. The job resumes
     from its cache afterwards.
   - A sing job waits while any other model is busy.
   - So SoulX and ACE are never resident together through DAW Pro's own actions.
   - **Prerequisite (item p2-sing-0):** every ACE and RVC job, from every origin, must register with the lifecycle
     coordinator. Today only the wire's ACE path does [R].
6. **Gates.** A take lands only if its physics are sound (finite samples, the right length), singing is present, its true peak
   is ≤ −1 dBTP after gain, and it is audible.
   - **−18 LUFS is the gain target, not a gate.** The render the user picked measured −19.2 LUFS, held down by the true-peak
     ceiling. A −18 LUFS gate would have rejected it: the ROADMAP SING-6 OWN-VOICE RUN entry says "capped at −19.2 LUFS by
     the −1 dBTP ceiling, so it fails G1" [M].
7. **Surface.** 17 new wire verbs, each with an MCP tool and tests, all additive.
   - Two acts stay human by definition: approving the ~7 GB download, and pressing Record.
   - Each of those two has a verb that **asks** for it.
8. **Not needed:** full Xcode, any new entitlement, or any change to render-thread code (§12).

---

## 1. What was decided before this document, and what each decision forces

| Decision | Source | What it forces here |
|---|---|---|
| SoulX-Singer, run locally: 6–8 GB peak, ~4 s for a 10 s line on MPS | the spike [M] | A sidecar. Render units of 20 s or less. A seeded memory hold of 6.05 GiB |
| Stock voice = Version 1 (upstream's Chinese-recorded prompt) | `sing-pick = v1` | The built-in voice is **the spike's `zh_prompt_cut` bytes**, rebuilt by the installer and hash-checked |
| Own voice = yes. The pick = the user's own voice at their own pitch (−18 st) | `sing-own-voice = yes`; `sing-own-pick = down18` | The recorder, Route N, and the key rule below |
| In a song, the vocal moves by octaves only. Propose a song key and octave from the voice's measured range | ROADMAP, the "Implication for p2-sing's design" bullets under the pick: a default decided by the orchestrator and carried by the brief | `VoiceRangeFit`, `sing.proposeKey` and `project.transpose`. `octaveShift` accepts whole octaves only |
| The user owns the provenance of any voice they supply. Importing user files is fine | the policy of 2026-07-27, carried by the brief | `sing.addVoice {path}` accepts any file that passes the clip check. There is no voice-identity gate |
| ACE stays (~75–84 GB, on 8001). Never both resident without a policy | the brief; `daw-pro-ace-stays`; ACE measured at 84.06 GiB (spike deviations, 16:07) [M] | The §2.7 residency rules and item p2-sing-0 |
| No memory admission gate ("let it fail if this happens, but still good to clean it up") | m23-dl; `ModelLifecycleCoordinator.swift:633–639` [R] | No admission arithmetic. A runaway watchdog that only cleans up |
| Conversions always create a new track | the user's ruling, quoted at `VoiceProvenance.swift:7–10` [R] | Every sing render lands on a NEW track. "Try another take" makes another new track |

---

## 2. Architecture

### 2.1 The picture

```text
 Sing sheet (DAWApp) ─► SingSheetModel (DAWAppKit) ─┐
                                                     ├─► SingJobCoordinator (AIServices actor, ONE per app)
 MCP sing_* tools ─► bridge ─► CommandRouter ───────┘      plan (DAWCore, pure) → wait for residency → render units
                               (DAWControl)                 → assemble, gain, gates → land (ProjectStore, one undo)
                                                            → async checks (notes, words)
                      ModelLifecycleCoordinator ◄──────────┤ admission, per-unit jobs, yield
 SingingSidecarManager ── spawn / stop / pidfile / watchdog ─► python facade 127.0.0.1:8004 (scripts/sing/server.py)
 SingingSynthesisClient ── POST /v1/sing/phrase ────────────►   SoulX-Singer, torch 2.11, MPS fp32
                                                                runtime: <App Support>/DAWPro/SingingEngine/
 AudioEngineControlling (DAWEngine): detectPitch(inFileAt:) for the checks; startInputOnlyCapture for the recorder
 WhisperTranscriber (AIServices, in-process): the word check
```

### 2.2 Port 8004

**Decision: 127.0.0.1:8004.** This is the spike plan's §2.5 decision, re-checked on 2026-09-27:

- 8001 is ACE and 8002 is RVC.
- 8003 is tentatively named by the unshipped real-time voice-conversion spike (`docs/research/2026-08-10-realtime-vc-spike.md`
  §9).
- A repo grep for 8004 (excluding video, ace-step, rvc, node_modules, demos, .build, dist and .claude) found it only inside the
  spike plan, 6 hits. The positive control, 8002, found 24.
- `lsof` shows nothing listening on 8004 [M, this session].

`SING_API_URL` overrides the client's base URL; staging and tests use 18004. This mirrors `RVC_API_URL`
(`VoiceConversionManager.swift:1008`) [R].

**Alternatives that lose:**

- **8003.** It carries a documented tentative claim. Two spikes colliding on a port is the exact failure the research doc
  warned about.
- **An ephemeral port picked at spawn.** The lifecycle coordinator's descriptors carry a fixed `baseURL`, and
  `SidecarProcessDiscovery.listeners(onPort:)` proves "stopped" by port. A moving port breaks both the three-limb stop proof
  and the "who owns this listener" check. Both exist because of past wrong-process near misses.

### 2.3 Where things live

| What | Where | Why |
|---|---|---|
| Scripts, text only: `install.sh`, `run.sh`, `server.py`, `singlib/` (converter, audio I/O), `requirements.lock`, `pins.env`, `stub_server.py`, `tests/`, `tools/make_guides.py` | `scripts/sing/` in the repo. `bundle.sh` copies it into `Contents/Resources/sing/` **before `codesign`**, exactly as it copies `rvc-patches` and `rvc-mitigation` (`scripts/bundle.sh:184–196`) [R] | Found in the `resolveOwnedDir` order (`VoiceConversionManager.swift:826–847`) [R]: the override `DAWPRO_SING_SCRIPTS_DIR`, then the repo checkout, then the bundle's resources |
| Runtime: uv-managed CPython 3.10.20, the venv, the pinned upstream checkout, `model.pt` and `config.yaml`, NLTK data, the built-in voice, redirected caches, `install.json`, the pidfile | `<Application Support>/DAWPro/SingingEngine/`, a **new** category `AppDirectories.Category.singingEngine`. Override: `DAWPRO_SING_RUNTIME_DIR` | **Outside the repo:** a multi-GB directory under `scripts/` is what made the `CLAUDE.md` grep rule rot (`scripts/video` 66 GB, `scripts/ace-step` 56 GB). **Profile-aware, unlike RVC's `installedRuntimeDir()` (`VoiceConversionManager.swift:1058`)**, so a staging E2E that exercises uninstall can never delete the user's real install |
| The user's voices | `<Application Support>/DAWPro/SingingVoices/<voiceId>/`, a **new** category `.singingVoices`. `reference.wav` is the take as recorded (Float32, mono, native rate); `voice.json` holds the name, range, check result and labels | User content never lives inside the engine runtime, so uninstalling the engine never deletes a voice |
| Phrase cache | `<Application Support>/DAWPro/SingingCache/`, a **new** category `.singingCache`, marked `isExcludedFromBackup = true`. LRU, 2 GB [A] | Profile-aware and purgeable; kept out of Time Machine |
| Landed audio | The project's media, through the existing import path | Nothing new |
| Sidecar log | `~/Library/Logs/DAWPro/sing-sidecar.log` | The existing sidecar-log rule (`AppDirectories.swift:16–20`) [R] |

**"Application Support" contains a space.** So:

- every script quotes every path;
- nothing runs through a console-script shebang: `run.sh` execs `venv/bin/python server.py`, and the installer uses
  `python -m` and `python -c`, never the `hf` or `pip` entry points;
- a test installs into a temp directory whose name contains a space.

During the spike, uv wrote a `~/.local/bin/python3.10` symlink until `UV_PYTHON_BIN_DIR` was pinned (spike deviations,
14:12:17) [M]. The installer pins it inside the runtime.

### 2.4 The facade (`scripts/sing/server.py`)

**The server.** Standard-library `http.server.ThreadingHTTPServer`, bound to 127.0.0.1. **It refuses to start on any other
host.** One inference lock: the app never sends two requests at once, and the lock is a backstop.

**The model.** It loads eagerly at start, through upstream's own `build_model` (`cli/inference.py:16`) and `DataProcessor`
(`soulxsinger/utils/data_processor.py`) [R], both unchanged. The spike's harness called the same functions, also unchanged.

**Endpoints:**

- `GET /health` returns
  `{status: "loading"|"ready"|"error", facadeVersion: 1, engine: {commit, weightsRevision, weightsBytes}, device: "mps", pid, loadSeconds, mpsDriverBytes, rendered, error?}`.
- `POST /v1/sing/phrase` renders one unit, synchronously, writes a WAV, and returns its facts.

**The request.** It uses DAW Pro's own schema; SoulX's metadata schema never crosses the wire, because the facade builds it:

```json
{
  "facadeVersion": 1,
  "voice": {"id": "builtin-1"},
  "phrase": {
    "notes": [{"startS": 0.0, "endS": 0.6, "midi": 60}, {"startS": 0.6, "endS": 1.2, "midi": 60}],
    "words": [{"text": "Twinkle", "noteIndices": [0, 1]}]
  },
  "leadS": 0.24, "trailS": 0.24,
  "seed": 20260924, "nSteps": 32, "cfg": 3.0,
  "outputPath": "<SingingCache>/<key>.wav",
  "outputSampleRate": 48000
}
```

An own voice is sent as:

```json
{"id": "<uuid>",
 "referencePath": "<SingingVoices>/<id>/reference.wav",
 "referenceSha256": "...",
 "prompt": {"windowStartS": 0.84, "windowEndS": 6.12,
            "notes": [{"startS": 0.24, "endS": 0.83, "midi": 44, "word": "Row", "continues": false}]},
 "promptLabelOffset": 0}
```

- The `prompt` holds the Route N labels (§3.7), relative to the window.
- `promptLabelOffset` (a whole number of semitones, default 0) adds an offset to the prompt's **non-rest** labels only.
  Upstream's own shift skips rests through its `note_pitch > 0` mask, and the §7.5 equivalence depends on matching that.
  It exists for §7.5's Round L. The Swift client sends 0 unless that round changes the default.

**Conversion rules.** They are the spike's converter (`code/score_from_notes.py:48–92`) [R], which produced every render the
user heard:

- a leading and a trailing `<SP>` of `leadS` and `trailS`, and an `<SP>` for every gap;
- boundaries rounded to 10 ms **cumulatively**, then differenced;
- each word's phonemes are `en_` plus its `g2p_en` ARPAbet, joined with `-`;
- **a word on k notes becomes k entries, each carrying the whole word's phonemes, with note_type 2 on the first and 3 on
  the rest** (`score_from_notes.py:53,64`). This is the measured-good convention. Upstream splits each phone into its own
  token (`data_processor.py:96–100`) [R], so no syllable splitting of phonemes is needed, and none is done;
- every phone must be in `phone_set.json`.

**No pitch shifting in the facade.** It always calls `infer(..., control="score", auto_shift=False, pitch_shift=0)`, and the
app applies octaves in the target note numbers. The reason: upstream's `pitch_shift` is added **after** the prompt and target
note pitches are concatenated (`note_pitch[note_pitch > 0] += f0_shift` in `soulxsinger.py` `infer()`) [R], so it moves the
**prompt's labels** too. §7.6 tests what that did to the render the user picked.

**Output.**

- Float32, resampled to `outputSampleRate` (the project's rate) with soxr VHQ, and written as a Float32 WAV.
- A NaN/Inf check runs before writing.
- `torch.mps.empty_cache()` runs after each unit, and the driver's memory is reported.

**Refusals.** Each returns `{error, message}`, and the app maps each code to a sentence:

| HTTP | Code | When |
|---|---|---|
| 400 | `badRequest` | Unknown keys (refused, like `rejectUnknownKeys`) or a malformed body |
| 400 | `phraseTooLong` | Longer than 30 s with the guards. A backstop: the app never sends more than 20 s |
| 400 | `notesOverlap`, `notesUnsorted` | The notes are not sorted and non-overlapping |
| 400 | `wordsDoNotCoverNotes` | A note without exactly one word, or indices that are not contiguous and ascending |
| 400 | `emptyWord`, `unknownPhone` | A word with no letters, or a phone outside `phone_set.json`. The message names the word |
| 403 | `pathNotAllowed` | A realpath outside `SING_ALLOWED_ROOTS` (the SingingVoices, SingingCache and runtime voice folders) |
| 404 | `voiceNotFound` | No voice with that id |
| 409 | `referenceChanged` | The reference's sha256 does not match |
| 422 | `badReference` | The reference is unreadable, or too short after the trim |
| 503 | `loading` | The model is still loading |
| 500 | `nonFinite`, `inferenceFailed` | NaN or Inf in the output, or an exception (the first line of it) |

**No shutdown endpoint.** Stopping is pid-exact, from the manager, never over HTTP. During the spike, a stop path that waited
on HTTP to a busy server stalled for about 45 s while ACE grew to 84 GiB (spike deviations, 16:07) [M].

**Alternatives that lose:**

- **A FastAPI facade with async jobs in the sidecar** (spike plan §5, p2-sing-b).
  - fastapi and uvicorn are not in the measured lock (`logs/freeze-alt.txt`, 83 pins) [M].
  - uvicorn's reloader and worker model add processes to a process tree that must stay pid-exact (a standing rule).
  - A job queue owned by the sidecar cannot know it is about to be evicted, cannot land a clip, and loses every job when it
    is killed. The app has to own the job anyway (§4.1).
- **Rendering the whole clip in one request.**
  - Memory grows with length: 6.05 GiB at 30 s, 8.32 GiB at 60 s [M].
  - There is no progress and no cancel.
  - One bad phrase costs the whole song.

### 2.5 Install, consent, update, uninstall

**Consent.** The engine download (~7 GB) starts only when the user clicks.

- In the UI, clicking "Install the singing engine" **is** the consent.
- Over the wire, `sing.installEngine` raises an in-app window ("An AI agent wants to install the singing engine: about 7 GB,
  one time. [Install] [Not now]") and returns `awaitingUserConsent`. Nothing downloads until the user clicks.
- `sing.uninstallEngine` works the same way.
- **This is a deliberate, documented exception** to "every operation is agent-invokable": consent is a human act, and no
  agent's message is ever the user's consent.
- For staging E2E there is a test-only launch flag, `DAWPRO_SING_TEST_AUTO_CONSENT=1`. It is set by whoever launches the
  process and can never be set over the wire.
- Q1 (§11) asks the user to confirm this policy.

**Steps (`scripts/sing/install.sh`).** The script is idempotent: each step checks its own output before skipping. Everything
downloads into `SingingEngine/.staging-<uuid>/` and moves into place only after verification. The marker is written last, so
a cancelled or failed install leaves nothing that looks installed.

1. **Preflight:** arm64; macOS 14 or later; at least 12 GB free on the runtime volume [A: ~5 GB installed plus staging plus
   margin; item p2-sing-b's measured peak replaces it]; a writable runtime directory.
2. **uv 0.11.19**, the spike's version (`logs/preflight-s9.txt:49`) [M]. Download it from its GitHub release, check its
   sha256, and put it in `SingingEngine/bin/`. `UV_PYTHON_INSTALL_DIR`, `UV_PYTHON_BIN_DIR` and `UV_CACHE_DIR` all point
   inside the runtime.
3. **CPython 3.10.20**, the spike's (`venv-alt/pyvenv.cfg`) [M].
   - Build the venv from `scripts/sing/requirements.lock`, which is the spike's `logs/freeze-alt.txt` **verbatim** [M]: torch
     and torchaudio 2.11.0, torchcodec 0.11.1, g2p-en 2.1.0, nltk 3.9.2, librosa 0.11.0, soxr 1.1.0, transformers 4.41.2,
     numpy 1.26.4, huggingface-hub 0.36.2, and the rest.
   - The lock is **not pruned**: a pruned lock is an unmeasured lock.
4. **Upstream:** `github.com/Soul-AILab/SoulX-Singer` at commit `81aeb3ae772c70093c3de74dc23c92d983801ae4`, verified with
   `git rev-parse HEAD`.
5. **Weights**, through `huggingface_hub.hf_hub_download` called from python, never through the `hf` entry point. Only two
   files, from repo `Soul-AILab/SoulX-Singer` at revision `40493ad90286056c7a9095035164434a79daa8c9`:
   - `model.pt`: exactly 2,818,092,278 B, sha256 `447eaf41f91a6b6659d55e9ec3c9b809221724fb8592aebaec35a23751a5b500` [M];
   - `config.yaml`: sha256 `d164c978dde6f57e1075bc21ef5f9b7b27895267f35b735cebe863418492be38` [M].

   The pin is also a **safety requirement:** upstream's `build_model` loads the checkpoint with
   `torch.load(..., weights_only=False)` [R], which is an unpickle.

   Optional `--adopt-weights <path>`: an existing file with the pinned size and sha256 is APFS-cloned (`cp -c`) instead of
   downloaded. It is a one-time convenience for this Mac and the spike's copy. It is **not** exposed on the wire.
6. **NLTK data** into `SingingEngine/nltk_data`: `cmudict`, `averaged_perceptron_tagger`, **and
   `averaged_perceptron_tagger_eng`**. nltk 3.9.2 needs the last one, and g2p_en does not fetch it (spike deviations,
   14:31:57) [M].
7. **The built-in voice, `builtin-1`.**
   - Decode `example/audio/zh_prompt.mp3` and cut it to 320–10687 ms, its metadata's window (spike deviations, 16:18) [M].
   - Write it as 24 kHz Float32, and copy `example/audio/zh_prompt.json` verbatim.
   - **The cut WAV's sha256 must equal that of the spike's `fixtures/zh_prompt_cut.wav`**, because those are the bytes the
     user picked. If a decoder difference changes them, the install fails loudly instead of shipping a different voice.
8. **Cache redirects** for everything the spike redirected (`env.sh`: `HF_HOME`, `TORCH_HOME`, `XDG_CACHE_HOME`,
   `NLTK_DATA`, `MODELSCOPE_CACHE`, `MPLCONFIGDIR`, `HF_HUB_DISABLE_TELEMETRY=1`) [M].
   - At run time, also set `HF_HUB_OFFLINE=1` and `TRANSFORMERS_OFFLINE=1`, so the running sidecar can never download.
   - `PYTORCH_ENABLE_MPS_FALLBACK` stays **unset**, as measured (the spike's F9). A missing MPS op then fails loudly instead
     of quietly running on the CPU.
9. **Finish:** prune the uv cache and measure `du`. Write `install.json` with `lockSha256`, `commit`, `weightsSha256`,
   `builtinSha256`, `installedBytes` (measured), `scriptsVersion` and `date`.

**Progress.** The script prints one machine-readable line per step (`@@step <name> <i>/<n>`, `@@bytes <done> <total>`), and
`SingingEngineInstaller` parses them into the status. `sing.cancelInstall` cancels, and the status turns `cancelled` only
after the staging directory is gone. That is the `SoundBankDownloadCoordinator` rule (`SoundBankDownloadCoordinator.swift:142–148`)
[R].

**Size.**

- The spike's parts: python 70 MB, venv 976 MB, weights 2.8 GB, uv cache 1.3 GB (pruned after install) [M].
- So expect ~4–5 GB installed and a ~4 GB download [D].
- The consent copy says "about 7 GB" [A]. That is the brief's deliberately conservative figure. The installer records the
  measured size, and the UI shows it afterwards.

**Update.** A later app version that ships a new lock or new pins changes `lockSha256`, so the status reports `needsUpdate`
and the install card reads "Update the singing engine". Updating is the same idempotent install: steps whose outputs still
verify are skipped.

**Uninstall.** Stop the sidecar, delete `SingingEngine/`, and report the bytes freed. Voices, the cache (a separate category)
and landed audio are untouched.

**Alternatives that lose:**

- **Install inside the repo** (`scripts/sing/runtime`, the ACE and RVC checkout shape). It fails the grep-hang law and does
  not work for distributed builds.
- **Download silently at the first "Sing it".** A 4 GB download hidden behind a button labelled "Sing it" is not consent.

### 2.6 Lifecycle

`SingingSidecarManager` (AIServices) mirrors `VoiceConversionManager`:

- `status()`, `start()`, `stop()`, and `evictWithoutCoordinator()` (its `ModelEvicting` conformance);
- a pidfile at `SingingEngine/run/sing.pid`;
- the stop planner with its three authority limbs: port free, probe unreachable, tree pids dead (`ModelStopEvidence`,
  `ModelLifecycleCoordinator.swift:35–67`) [R].

**Start.**

- Admission goes through the coordinator: `resolveAdmission` → `commitAdmission` → spawn `run.sh` → `recordBootPid` → poll
  `/health` until `ready` → `admitted(healthy:)`.
- `run.sh` `exec`s the venv python, so **the pidfile's pid is the listening process** (the wrong-pid lesson).
- Measured: cold start 13.7–20 s under load; model load ~5 s; import to loaded ~6–7 s [M].
- Start timeout: 120 s [A].

**Eager load.** The first render never pays a second, hidden wait: "ready" means ready.

**Idle unload.** 600 s after the last unit [A].

- This matches ACE's `aceStepIdleUnloadSeconds` (`ModelRegistry.swift:262`) [R].
- A cold start costs 7–20 s, so ten warm minutes across a session of edits and re-takes is worth 6 GB on a 128 GB Mac.
- Item p2-sing-g replaces this number if its session shows re-takes more than 10 minutes apart.

**Quit.** The coordinator's existing `shutdown()` unloads it.

**Runaway watchdog.** It cleans up; it is not an admission gate. While the sidecar is resident, it samples the sidecar
**tree's** `phys_footprint` at 4 Hz with the existing tree sampler. It SIGKILLs the tree, pid-exact, when either:

- the footprint passes **16 GiB** [D]: about twice the measured 60 s peak of 8.32 GiB. The app never sends more than 20 s,
  and memory measured flat at ~6.05 GiB from 10 s to 30 s;
- system memory pressure reads **Critical** on 2 consecutive samples.

It never calls HTTP. The spike's own watchdog used the same rules (0.25 s poll, > 16 GiB, Critical) and was proven by forcing
each cap (SING-6 `STATUS.md`) [M].

**Registry.** `ModelID.soulxSinger = ModelID(rawValue: "soulx-singer")`, built by `ModelRegistry.soulxSinger(baseURL:)`:

- display name "Singing voice";
- a seeded hold of 6.05 GiB [M: the tree's `phys_footprint` on 10 s and 30 s units], with a provenance string naming the
  spike;
- `isEvictable: true` and `idleUnloadSeconds: 600`;
- **`yieldsWhenBusy: true`**, a new field whose default is false.

It is registered in the same launch `Task` as ACE and RVC (`DAWProApp.swift:4793–4800`) [R], before anything can start it.
That block's ordering tripwire applies verbatim.

### 2.7 Residency with ACE and RVC

**Today's rules [R]:**

- Unload-before-load is unconditional (`commitAdmission`, `ModelLifecycleCoordinator.swift:678–684`).
- A resident model with `activeJobs > 0` is skipped, and the new boot proceeds **alongside** it (`ModelAdmission.swift:213–214`).
- A failed eviction does not abort the boot (the user's "let it fail").
- Boots are single-flight, with a cross-process lock.

**The gap that item p2-sing-0 closes.**

- `noteJobStarted` and `noteJobEnded` are called only in `Commands.swift`, and only for `.aceStep`: the `ai.generateSong`
  submission and its status path [R]. The grep that found this was positive-controlled.
- The Sketchpad and the import seam submit ACE jobs through `GenerationObservingGenerator` wrappers of the ONE raw client
  (`DAWProApp.swift:4895–4903`) [R], and they do not register.
- RVC's `convert` and `train` never register.
- **So a SoulX boot during a Sketchpad generation would see ACE at `activeJobs == 0`, evict it, and kill the user's song
  mid-generation.** A running RVC conversion would die the same way.

**The rules:**

- **R0 (item p2-sing-0).** Every job registers.
  - A `LifecycleTrackingSongGenerator: SongGenerating` wraps the raw ACE client **once**, below the three origin observers
    and below the presence poll.
  - `noteJobStarted` fires on every accepted submission: generate, extract stems, lego and repaint. `noteJobEnded` fires on
    the first terminal status, or terminal error, that any poller sees. The existing 1 h job lease is the backstop.
  - ✅ **Amended 2026-09-27 (W7-S0, built and gated): for ACE, a "terminal error" is ONLY `jobFailed` or
    `jobNotFound`.** A cancelled or transiently failed POLL does not end the job: ACE has no abort route, so the sidecar
    keeps rendering, and closing the job there would recreate the eviction. A cancelled or refused SUBMIT opens nothing.
    RVC's `convert` and `train` close on EVERY exit (a result, an error, a cancel), because the call is the job.
  - ⛔ **A second live defect R0 closes, which this design missed:** ACE's 600 s idle unload is armed at boot and only a
    registered job disarms it, so a Sketchpad-only session lost ACE about 10 minutes after boot, even mid-render.
  - The terminal rule now lives in three places: the wire (`errorProvesJobIsOver`), the presence model and the tracker. A
    later wire round makes the wire call the tracker's.
  - It does not observe presence, so the presence poll (`DAWProApp.swift:4849–4863`, "never a decorator — no
    self-observation loop") may read through it.
  - A `LifecycleTrackingVoiceConverter: VoiceConverting` brackets RVC's `convert` and `train`.
  - The wire's existing ACE calls stay, because the job sets are idempotent. Nothing is renamed.
- **R1.** SoulX registers as in §2.6.
- **R2 (before SoulX boots).** Before asking for admission, the sing job reads `residency()`.
  - While any OTHER resident model has `activeJobs > 0`, the job waits in `waitingForModel`. It polls every 2 s, can be
    cancelled, and has no timeout; the job lease bounds a leaked job.
  - Admission then evicts an idle ACE or RVC, as today.
- **R3 (another model boots while SoulX is resident).** `yieldsWhenBusy` changes one pure function: in
  `ModelAdmission.resolve`, a resident with `yieldsWhenBusy` goes to `evicting` even when `activeJobs > 0`.
  - Before its process dies, the manager records `lastStopReason = .yieldedTo(<model>)`. That is how the in-flight unit's
    HTTP failure is classified as a **yield**, not a crash.
  - The job returns to R2's wait and re-renders that unit afterwards. Finished units come from the cache.
  - Worst case, one unit's compute is wasted: about 8 s or less [D: a 15 s unit × RTF 0.51].
- **R4 (an ACE the app didn't start).** A listener on 8001 with no DAW Pro pidfile is never signalled.
  - The job proceeds with a notice: "The song generator is also running outside DAW Pro, so this Mac may run short of
    memory."
  - The runaway watchdog is the backstop.
- **R5.** SoulX jobs register per render unit (`"<jobId>#<unit>"`). That disarms idle unload during a unit, and
  `ai.modelResidency` shows SoulX as busy.
- **R6.** A failed eviction still lets the boot proceed (the user's ruling). The watchdog's Critical-pressure kill then removes
  SoulX, the smaller and restartable of the two.

**Result.** Through DAW Pro's own actions, SoulX and ACE are **never resident together**: SoulX never boots beside a busy
model, and any other model's boot removes SoulX first. The two remaining windows, R4 and R6, are named, visible and cleaned
up.

**Alternatives that lose:**

- **(a) Register SoulX jobs normally, with no yield flag.** A busy SoulX is then "protected", so an ACE boot proceeds
  **alongside** it: 84 GiB plus 6 GiB, on a Mac where ACE alone reached Critical pressure (spike deviations, 16:07) [M].
- **(b) Don't register SoulX jobs at all.** Nothing disarms the idle timer during a long render, and `ai.modelResidency`
  misreports SoulX as idle. The eviction also arrives without the manager knowing it was a yield, so a yield looks the same as
  a crash.
- **(c) A pairwise exclusivity table** (the spike plan's "marked exclusive with ACE"). The lifecycle design deliberately has a
  rule, not a table (m23-dl), and a table would have to be edited for every new model.

### 2.8 Preflight: what `sing.sidecarStatus` checks, cheapest first

1. The runtime directory and `install.json` exist.
2. `lockSha256` equals the shipped lock's hash; otherwise the state is `needsUpdate`.
3. `venv/bin/python` exists and is executable.
4. The weights' size and mtime/inode equal the marker's. The full sha256 runs only at install, or on
   `sing.sidecarStatus {verify: true}`.
5. The built-in voice is present.
6. Port 8004 has no listener, or its listener is the live pid in our pidfile (`SidecarProcessDiscovery.listeners(onPort:)`).
   A foreign listener gives `portBusy`, naming the process.
7. A stale pidfile is cleaned up.

**States:** `notInstalled`, `awaitingUserConsent`, `installing`, `needsUpdate`, `installedNotRunning`, `starting`, `ready`,
`stopping`, `error`.

---

## 3. The domain (DAWCore: pure, headless, Foundation only)

### 3.1 Lyrics on a clip

`Clip.lyrics: ClipLyrics?`, with `struct ClipLyrics: Codable, Sendable, Equatable { var text: String }`.

- It is additive: an absent field decodes as nil.
- It gets **its own decode test**, because a render byte-gate cannot see a `Codable` decode default.
- Only the text is stored. The word-to-note assignment is **derived** every time from the text, the current notes and the
  tempo map.
- Markup lives inside the text (§3.2), so there is exactly one source of truth.

**Alternatives that lose:**

- **Store word spans (note ids per word)**, as the spike plan sketched. Any note edit silently invalidates them, and this
  tree's characteristic failure is a stored record that disagrees with the thing it describes.
- **Store per-word note counts beside the text.** Their indices shift when the text is edited: a second copy of the same
  fact.

### 3.2 Tokenizer and markup (`LyricTokenizer`)

- **Words** split on whitespace. Punctuation is dropped for singing but kept in the stored text. Curly apostrophes map to
  `'`.
- **Line breaks** separate lines, which §3.3 uses.
- **`+`** as its own token means "the previous word also takes the next note". OpenUtau's **`+~`** is accepted as a synonym.
  - The research doc (§4(a).3) [R] names both OpenUtau conventions.
  - SoulX makes no distinction between a new syllable and a tie at the metadata level: both are type-3 entries carrying the
    word's phonemes. So one mark is enough.
- **A hyphen inside a word** (`twin-kle`) means "one note per part"; it is sung as the joined word.
  - ⚠️ **Amended 2026-09-27 (W7-SD1, measured with the facade's own phonemizer):** joined is right for a SYLLABLE split
    (`twin-kle` sung "twinkle" ✓, "twin kle" ✗) and WRONG for a COMPOUND (`well-known` sung "wellknown" ✗, "well known"
    ✓; `twenty-one` likewise). Swift has no lexicon to tell them apart, but the facade has CMUdict. **Decision:** the app
    sends the parts hyphen-joined; the facade sings the joined word when CMUdict has it, else the parts spaced when every
    part is in CMUdict. That is a facade change, carried by item p2-sing-e. Today the facade turns every hyphen into a
    space (W7-SB), which mis-sings syllable splits.
- **Non-English words** (characters outside English letters, apostrophes and hyphens) are refused up front, with a sentence.
- **Numbers** are one word each, and are sung through g2p_en's own normalisation in the facade [A: item p2-sing-b's tests
  confirm this].
  - ⛔ **REFUTED 2026-09-27 (W7-SB, W7-SD1): g2p_en does not normalise numbers on its own.** `"42"` straight into its
    phonemizer is garbled (F-AO0-R-T-UW1-T-W-AA2), and `1999` breaks the same way. The facade now PRE-normalises with
    g2p_en's own `normalize_numbers` (W7-SB), and `EnglishSyllables` counts what that expansion says: 4,442 of 4,442
    number tokens match it, including ordinals and plurals. Hyphen parts joined across a DIGIT get a space, so "3-2-1"
    sings "three two one", not "three hundred twenty one". `LyricWord.sung` can therefore contain a space, so per-word
    text on the wire uses `typed`. "1,999" is sung as a year, which matches the facade.

### 3.3 The assignment rule (`LyricNoteAssigner`)

**Inputs:**

- the tokenized lines;
- the melody's notes after §3.4's monophony rule, grouped into breath phrases by `PhraseDetection.phrases(in:maxGapBeats:)`
  (`PhraseDetection.swift:147`) [R]. This is the tree's **one** breath definition, with its threshold,
  `HumanizeLegato.defaultMaxGapBeats` = 0.125 beats (`ProjectStore+Humanize.swift:63`) [R];
- a syllable counter.

**Rules:**

1. If the lyrics have as many non-empty lines as the melody has phrases, line i sings phrase i. Otherwise the words flow, in
   order, across phrases.
2. A word never crosses a breath: all of a word's notes are in one phrase.
3. Explicit markup (`+`, hyphen parts) is honoured first.
4. **W = N** (as many words as notes in scope): one note each.
5. **W < N** (fewer words than notes). The spare notes go:
   1. first to words with more syllables than notes, one each, left to right, never taking a note that a later word needs;
   2. then to the word before them, which holds across them (a melisma).

   This is the research doc's default rule (§4(a).3) [R]. A warning lists the held words.
6. **W > N is refused, never guessed**, with the numbers. §5.7 has the sentence; it is given per line when rule 1 applies.
7. A word with more syllables than notes is allowed: SoulX sings the whole word on its notes. A warning appears when a word of
   three or more syllables lands on one note shorter than 0.3 s.

**Syllables.** `EnglishSyllables.estimate(_:)` is a pure vowel-group heuristic (silent e, -le, -ed, diphthongs).

- Target: at least 90% exact on a checked-in 1,000-word fixture derived from CMUdict [A]. The fixture measures it, and falling
  short blocks item p2-sing-d1.
- A miscount only changes how spare notes are shared, and markup overrides it.
- It runs with the engine down, so previews are instant.

**Alternatives that lose:**

- **A sidecar `/phonemize` endpoint for exact counts** (spike plan §5). The preview would need the 6 GB engine running.
- **Shipping a CMUdict table in the app.** It is a second, licence-reviewed data file, for a count that markup already
  corrects.

### 3.4 The planner (`SingPlanner`)

**Notes.** These are the notes the clip **plays**: loop repeats are expanded by the **same evaluator playback uses**. Item
p2-sing-d2 finds that evaluator and must not re-derive it. Notes are clipped to the clip's window and kept in canonical order.
A clip on a drum track is refused.

> ⛔ **CORRECTION (2026-09-27, W7-SD2's finding, read by the orchestrator):** "loop repeats are expanded" describes nothing
> that exists. A clip has no loop of its own; the only repeat is the transport cycle, which replays the landed vocal
> anyway. The planner follows playback's own rule for which notes play (`MIDIEventSchedule.buildEvents`, checked against
> it on 200 generated clips in `SingPlannerPlaybackParityTests`).

**Monophony.**

- Overlapping notes: the earlier one is truncated at the later onset.
- Notes that start together (a chord): the highest is sung and the others are dropped, with a warning.

**Legato.** Articulation gaps (≤ 0.125 beats) are closed by extending the earlier note, so the converter inserts no tiny
`<SP>` rests. Breath gaps stay rests.

**Render units.**

- Breath phrases are merged greedily into units of up to 15 s, each cut at the largest breath gap near that length.
- **The hard cap is 20 s.** A breath phrase longer than 20 s is split at its largest articulation gap, with a warning. A single
  note longer than 20 s is refused.
- Measured basis [M]: memory stays flat at 6.04–6.05 GiB from 10 s to 30 s and reaches 8.32 GiB at 60 s; RTF is 0.38 at 10 s
  and 0.51 at 30 s.
- The 15 s and 20 s values themselves are chosen for cancel latency and progress granularity [A].

**Times.** Beats become seconds through `TempoMap.seconds(fromBeatZeroTo:)` (`TempoMap.swift:181`) [R], so tempo changes are
honoured.

**Octave.** The target MIDI note is the melody note + 12 × `octaveShift`. **Nothing else ever moves the sung notes.** A unit
test asserts that every planned target minus its source is a multiple of 12.

**Placement.**

- Each unit's audio starts `leadS` before its first note.
- The landed file starts at T0 = max(0, first note − 0.24 s). Its beat is `TempoMap.beat(atSecondsFromZero:)` of T0
  (`TempoMap.swift:201`) [R].
- The units are summed into one buffer at their offsets.
- Where a unit's guard overlaps its neighbour (a cut at a breath shorter than 0.48 s), the overlap gets a 20 ms equal-power
  crossfade.

**Output.** `SingPlan { units: [SingUnit { notes (unit-relative seconds, target MIDI), words, offsetSeconds }], assignment,
warnings, t0Seconds, atBeat, signature }`. `signature` hashes everything the render depends on; it is how "the melody changed
while I was singing" is detected.

### 3.5 Voice range and the key proposal (`VoiceRangeFit`)

**The rule, as decided.** In a song, the backing fixes the key, so the vocal on its own may move only by whole octaves. A key
change moves the whole song. DAW Pro measures the voice and proposes, the way a singer picks a key.

**Measuring the voice.**

- SwiftF0 runs over the reference, through `EngineProtocol.detectPitch(inFileAt:)`. Its range is 46.875–2093.75 Hz [R], low
  enough for a bass. The spike's `f0_score.py` used pyin with a 65 Hz floor, which is not.
- Only confident frames count: confidence ≥ 0.9, the `clip.detectPitch` default [R].
- The result is the duration-weighted p10, median and p90, in fractional MIDI.
- The harmonic-comb octave check confirms the register. It is the check SING-6 used to prove the user's median real (odd/even
  ratio 1.80) [M].
- Built-in voices are measured the same way, at install.

**The measured values.**

- **The user's recording:** median 104 Hz (G♯2, MIDI 44.03), p10 85 Hz (MIDI 40.54) [M, SING-6]. ~~Its p90 was never
  recorded, so every use below assumes 123–139 Hz [A].~~ ⚖️ **Corrected 2026-09-27 10:40 (W7-SD3 round 2, MEASURED on the
  whole recording, read in place): p10 85.9 Hz, median 102.5 Hz, p90 178.7 Hz**, independently confirmed by the spike's
  stored pyin (86.6 / 103.8 / 179.6 Hz). The p90 is set by the held last note, "stream", sung around F3. It is neither
  123 nor 139. `sing.addVoice` still measures it when a recording is added.
- **Built-in V1**, from upstream's metadata f0: p10 / median / p90 = MIDI 61.7 / 65.9 / 68.7 [M].

**The metric (provisional).**

- Band = [p10 − 1, p90 + 1] semitones.
- cost(v) = (the duration-weighted mean of semitones outside the band) + 0.25 × |duration-weighted median of the sung notes −
  the voice's median|.
- v is the vocal offset, t + 12·o, with song transposition t ∈ −6…+5 and octave o ∈ −2…+2. Octave-only candidates have
  t = 0.
- Ties within 0.15 go to the smaller |t|, then to the smaller |o|.

**The proposal.**

- If the best octave-only candidate's out-of-band term is ≤ 0.25 semitone, recommend it.
- Otherwise, recommend the best key change, and offer the best octave-only fit as the alternative.
- §5.7 has the copy for both.

**What the arithmetic says about the user's pick, stated plainly.** On the SING-6 line (T1T2, notes MIDI 60–69), under the
provisional metric and the assumed p90 [D: scratch arithmetic, not a measurement]:

- The best octave-only fit is −24: cost 1.58, with 29% of note time below the band.
- The best overall is t = +3 with two octaves down (vocal −21), cost ~0.11. Next is t = +4 (vocal −20), cost 0.24–0.40.
- **The user's pick, −18, costs 0.88–1.51. The metric does not reproduce it as its first choice.**
- ⚖️ **Re-run 2026-09-27 10:40 with the MEASURED p90 (W7-SD3 round 2):** −21 (t = +3) 0.1904, −20 0.3048, **the pick −18
  0.8048**, −24 1.5652, −12 2.8623. Every note of −18 is inside the measured range. **The ranking is unchanged: the metric
  still does not choose the pick, so Round K is still needed** before the proposal becomes a default.

That does not contradict the pick. The user chose among 0, −12 and −18, and never heard −20, −21 or −24. It does mean the
weights are unvalidated. So:

- **The calibration round (§7.5, Round K: −18 / −20 / −21 / −24, on one axis) is part of item p2-sing-g's gate.**
- The metric ships as the proposal default only once its first choice matches the user's pick in that round, after
  re-weighting if needed.
- Until then, `sing.proposeKey` marks its recommendation `calibrated: false`, and the UI words it as a suggestion.
- The decided default itself (the vocal moves by octaves only; key changes move the whole song) does not depend on the
  weights. It ships as ruled.

**Where the melody comes from.** The notes of the clip being sung.

- `sing.render`'s default, `octaveShift: "auto"`, is the octave-only recommendation.
- **The render never changes the song's key.** Only `project.transpose` does, and only when asked.

**Alternatives that lose:**

- **Shift the vocal alone by the best number of semitones** (what the spike's `--pitch_shift -18` did). It is off-key against
  any backing, which the ruling forbids.
- **Always sing as written.** The user's own pick rejected the line as written (1.75 octaves above their range), and rejected
  −12 [M].

### 3.6 `project.transpose`, the only way the song's key changes

`ProjectStore.transposeProject(semitones:excludeTrackIds:dryRun:) throws -> TransposeReport`, as one undo step.

**What moves:**

- MIDI note pitches on pitched tracks.
- Audio clips' `pitchShiftSemitones` (+t).
- ~~Pitch-correction scale tonics (`PitchCorrectionScale.tonicPitchClass`, `PitchCorrection.swift:180`) [R], so a corrected
  vocal keeps snapping to the **new** key.~~ ⛔ **WRONG, corrected 2026-09-27 by W7-PK with render physics:** nothing
  stores a tonic (a scale is only an INPUT to Auto-Correct), and a tuned clip's corrections are KEPT. They are stored
  relative to the recording, and the clip's pitch shift, which this verb moves, carries them to the new key. Measured:
  a C-major-tuned vocal moved +3 plays every note within 15 c of the intended E♭-major note, with `pitchEdits`
  unchanged. Moving the scale instead (the negative control) plays B3 and E♭4 where D4 was meant. Hand-moved notes
  stay put the same way (a drag from B3 to D4, then +3, plays F4).
- Take-group lanes' clips (notes and shift) move with their comp, or the next comp edit would undo the move.
- Every other stored key or chord root the census finds.

**What is skipped:** drum tracks (`InstrumentFamilyResolution`, `.drumSynth`, GM percussion) [R], and anything in
`excludeTrackIds`, such as a vocal that already sits right.

**Refused:**

- |semitones| greater than 12;
- a note that would leave MIDI 0–127;
- an audio clip that would go past ±24, its allowed range (the refusal names the clip);
- ✅ added 2026-09-27 (W7-PK, accepted by the orchestrator): **an open looper session** (`transposeLooperOpen`). The
  looper rewrites each layer's clip from its stored copy on its next pass, so the move would be silently undone.
  A refusal in words beats a silent undo;
- ✅ added 2026-09-27 (W7-PK, accepted): an `excludeTrackIds` entry that names no track (`trackNotFound`), because a
  typo would otherwise move the very track the caller meant to keep.

⛔ **A second tonic hazard, OUTSIDE this verb, measured by W7-PK and confirmed by the orchestrator in source (PK-F1):**
Auto-Correct snaps the pitch AS RECORDED (`ProjectStore+PitchCorrection.swift` calls `PitchAutoCorrect.build(from:
detection.pitch, options:)` with no clip shift), while the render adds `Clip.pitchShiftSemitones` on top and the pitch
editor's drag snap uses the pitch AS PLAYED. So on any clip with a nonzero shift (every tuned audio clip after a
transpose), re-tuning "to the new key" snaps to the wrong notes. Fix, owed before `project.transpose` reaches users:
`PitchAutoCorrect.build` snaps `sung + clipShift` and stores the correction relative to the recording.

**Known limits, filed (PK follow-ups):** a slice kit made by `clip.sliceToSampler` maps one slice per key, so moved
notes fire the wrong slices, and nothing stored marks such a sampler as a kit (PK-F2). An AI fix in flight on a take
group lands in the old key (PK-F3; a plain clip's is refused as stale, which is safe). Musical Typing's chord key does
not follow the move; the report says so in words.

⚖️ **Amended 2026-09-27 10:10 (orchestrator, from W7-PK round 2):**
- **PK-F3 → REFUSE AS STALE, never "land in the current key".** Landing at the lanes' current shift double-applies
  any shift a lane already had (a lane at −1 at submit, +3 since, sits at +2; audio with −1 baked in then plays net
  +1). A correct rebase exists only when every lane moved together. So a take-group fix, like a plain clip's, records
  the lanes' pitch at submit (`PendingClipFix.frozenLanePitch`) and, if it changed, refuses in words at landing, keeps
  the pending job, and asks for a new submit. Installed by W7-PK round 3.
- **`vc.convert` has the same defect, silently** (it bakes the source pitch, `ProjectStore+ClipVoiceConversion.swift`
  ~:188, lands at shift 0 ~:412, and warns only about moves and trims ~:383). Same rule: refuse in words at landing
  if the source's pitch changed since submit. W7-PK round 3.
- **PK-F2:** the skip rule is live (`skippedSliceKit`, in words); the stored `SamplerParams.sliceKit` marker is a
  drafted patch installed after W7-SD2 releases `Model.swift`/`ProjectDocument.swift`. Until then no track reads as
  a kit. Known limit: the marker covers the whole instrument, so a pitched Sixteen Levels spread on a kit is skipped
  with it (a note-level rule, not built).
- **A sung take across a key change: see §4.5 "Project identity", amended the same day.**

**Warned:** each recorded or generated audio track that will be pitch-shifted, by name.

**The census comes first.** This tree's law is "never quote a per-kind site count; census it".

- Enumerate every stored model field that carries a pitch or a key: grep `pitch`, `tonic`, `root`, `key` and `semitone`
  across the `Sources/DAWCore` model types.
- Report the METHOD and the list, and give each field a test.
- Known today [R]: `MIDINote.pitch`, `Clip.pitchShiftSemitones`, `PitchCorrectionScale.tonicPitchClass`. The chord and scale
  settings on `ChordVoicing`-bearing models must also be checked.

**Alternatives that lose:**

- **Transpose only the melody clip.** That is the forbidden "vocal alone" move, with extra steps.
- **A project-level "key" field that everything reads.** Nothing reads one today, and retrofitting every pitch consumer is
  bigger than moving the stored values.

### 3.7 Own-voice reference labels: Route N, replacing Route H

**Why Route H failed [M].** Route H (`own_voice.py`, `route_h`) assumes the user sang the guide's rhythm with one global time
offset (cross-correlation `tau`), and the guide's intervals with one global key (median cents). The user sang freely:

- 5.93 s against a 4.8 s guide;
- intervals wider than written, with residuals from −221 to +449 c.

So only **1 of 10** labels landed within ±50 c of what was actually sung.

**Route N** (`VoiceReferenceLabeler`, pure DAWCore; the SwiftF0 frames come from the engine):

1. **Window.** Find the voiced region from confident frames. The prompt window is [first voiced − 0.24 s, last voiced +
   0.24 s].
2. **Contour.** Build the sung contour in semitones.
   - Isolated ±12 jumps against a 150 ms median are tracker octave errors, and are folded back.
   - The comb check confirms the register.
3. **Key-invariance.** Subtract each contour's own median, both the guide's and the sung.
4. **DTW** between the guide's frame sequence (P1: 10 notes, 4.8 s) and the sung frames.
   - Local cost = min(|guide − sung|, 3 semitones). The cap stops wide intervals dominating.
   - An unvoiced sung frame costs a constant 0.3.
   - Guide note onsets are pulled toward sung onset peaks (RMS rise, spectral flux).
   - The step pattern is symmetric, with the local slope limited to 1/3…3.
5. **Note spans** come from the DTW path. Boundaries between repeated same-pitch notes ("Row, row, row") snap to the
   strongest onset peak within ±80 ms.
6. **Labels are what was sung.** Each note's MIDI value = round(median of the sung contour over the middle 50% of its span),
   which is the §1.7 window. A span with less than 60 ms of confident pitch falls back to the key-relative guide pitch, and is
   flagged.
7. **Gaps** of 0.20 s or more become `<SP>`. Shorter gaps are absorbed into the following note (the spike's `MIN_GAP_S`).
8. **Words** come from the guide line P1: "Row, row, row your boat, gently down the stream". "gently" spans two notes.
9. **No f0 in the prompt metadata.**
   - In score mode, `infer()` zeroes the prompt f0 [R].
   - Its only other effect was `DataProcessor.process` truncating to its length (`data_processor.py:152–155`) [R].
   - Item p2-sing-b's null test confirms this (§7.6).

**Quality (reported, advisory):**

- the DTW mean local cost;
- a per-span pitch IQR of 100 c or less on at least 9 of 10 spans. A span that straddles two sung pitches is a boundary error;
- at least 90% of voiced frames inside spans;
- no span shorter than 60 ms.

These give a verdict of good, fair or poor. A poor voice is still saved, with the §5.7 notice.

> **Vacuity warning for whoever writes the gate.** "8 or more of 10 notes within ±50 c" is the bar Route H failed, and it is
> TRUE BY CONSTRUCTION for Route N, whose labels are the rounded sung pitch. It must not be Route N's gate. Route N is graded
> on boundary accuracy against known truth, and on the render outcome (§7.6).

**Tests.**

- **Synthetic frame fixtures**, pure Swift with no audio: P1 as sung
  1. with exact timing;
  2. at −18 st and ×1.24 tempo;
  3. with intervals stretched by up to +450 c (the user's shape);
  4. with ±30% local tempo drift;
  5. with a scoop splitting one note;
  6. with legato repeated notes marked only by onset peaks;
  7. with 5% octave-error frames;
  8. as a different melody, which must grade poor.

  The truth is known, so assert: boundary error median ≤ 40 ms, p90 ≤ 80 ms, and exact labels on at least 9 of 10 [A]. These
  thresholds are set before the first run and not moved after it.

  **Negative control:** Route H, kept as a test-only reference implementation, must FAIL fixture 3 (at most 2 of 10 labels
  within ±50 c). That proves the fixture exercises the defect.
- **Audio fixtures through the real SwiftF0** (DAWEngine tests): synthesised harmonic "singing" with consonant noise bursts,
  with the same assertions.
- **The real model** (item p2-sing-g):
  - the built-in voice singing P1 from a known score, as a stand-in with ground truth;
  - then, only if Q3 says yes, the user's own recording: the verdict must be "good", plus the §7.6 render comparison.

**Alternatives that lose:**

- **Route H with a per-note key.** It fixes the labels but not the timing (5.93 s against 4.8 s).
- **Route P, upstream's preprocessing stack**: up to 3.3 GB more weights, NeMo/funasr, and an unchecked licence (spike plan
  §1.6). It adds a second model family for a job that DTW over our own tracker can do.

### 3.8 The clip check, in Swift (`VoiceClipCheck`)

The spike's check (`own_voice.py` `clip_check`) moves into DAWCore with its constants **verbatim** [R]:

| Constant | Value |
|---|---|
| `DUR_MIN` | 3.0 s |
| `DUR_MAX` | 12.0 s |
| `TP_MAX` | −1.0 dBTP |
| `FLOOR_MARGIN_DB` | 30 |
| `GUARD_BEFORE` | 0.15 s |
| `GUARD_AFTER` | 0.30 s |
| `MIN_GAP_S` | 0.20 s |
| `MIN_COVERAGE` | 0.50 |
| `CUT_TOL` | 0.15 s |

Its order is kept: duration, singing found, not cut off, true peak, gaps measurable, noise floor. One reason is new and runs
last: `guide_leak`.

⚖️ **Amended 2026-09-27 10:40 (W7-SD3 round 2, `VoiceClipCheck.judgedOrder`): which FAILING check's sentence is shown.**
Music 20-28 dB under the voice fools the alignment, so a noisy take read "cut start" (SING-6's music fixture and the
synthetic one both did). Now, when the noise-floor check fails and an offset was found with a measurable gap, the two
checks that depend on that offset ("singing found", "not cut off") move to just after it; every other pair keeps the
order above, so a clipped take in a noisy room still reads "too loud" first. It chooses only the sentence: no take
flips between pass and fail, and no sentence text changed. Known consequence: a take that is truly cut off AND has a
fan at −25 dB now reads "noisy" instead of "cut start" (both are true).

**The instruments change** (pyin becomes SwiftF0; ffmpeg and pyloudnorm become `Loudness`' 4× true peak). So:

- the spike's negative controls are re-run as Swift fixtures: music under the voice → floor; 2 s → duration; a clipped file →
  true peak; silence → no singing;
- the user's recording must still **pass**, as it did in Python: 5.93 s, TP −6.9 dBTP, floor margin 44.6 dB [M].

**Duration.** The brief frames the recording as 5–12 s. The hard floor stays at the spike's 3.0 s, because the guided line
takes about 5 s at the guide's tempo and a brisk singer takes ~4 s. The copy asks for "about 5 seconds".

**`guide_leak`.** Take the normalised cross-correlation of the recording against both guide files (16 kHz, band-limited) at
any lag. It is a leak when the peak is ≥ 0.25 **and** ≥ 4× the median correlation [A]. Two fixtures set these thresholds
before first use:

- the guide mixed at −20 dB into a clean stand-in must trip it;
- a model-rendered stand-in sung in unison with the guide must not.

The SING-6 record says the Python check "cannot catch a guide played from the speakers" [R]. This closes that gap.

### 3.9 Provenance (`SungVocalProvenance`)

A new optional field, `Track.sungVocalProvenance`: additive, with its own decode test. It records:

- the engine id and pins;
- the voice's id, a snapshot of its name, and its kind;
- a snapshot of the lyric text;
- the source clip's id;
- the octave shift, and the song transposition in force;
- the seed, nSteps and cfg;
- the render date, the loudness report and the note-accuracy summary;
- the word-check result, filled in later.

It is **a fact, not a binding**: the `VoiceProvenance` doctrine (`VoiceProvenance.swift:5–34`) [R].

**Alternatives that lose:**

- **Reuse `VoiceProvenance`.** It drives save-time RVC voice embedding and `embeddedVoicesReport()`, which would look the
  singing voice up in the RVC store and report it missing.
- **No provenance at all.** "How do I make this again?" and the word check would have nowhere to live.

---

## 4. The job

### 4.1 Why the app owns it, and where it lives

`SingJobCoordinator` is an AIServices actor, **ONE instance per app**, handed to both `CommandRouter` and the Sing sheet's
model.

- It copies the `SoundBankDownloadCoordinator` shape (m34-c; `SoundBankDownloadCoordinator.swift:112–148`) [R]: one instance
  per app, start then poll, and a cancel that never invents a terminal state.
- Every read, and the landing mutation, goes through `ProjectStore`. Both surfaces call the same coordinator methods.
- It is the first in-app registry of **model-render** jobs.
  - The `clip.transcribe` case in `Commands.swift` says "there is NO in-app job registry (ai.generateSong's job lives in the
    ACE-Step SIDECAR)" [R]. Item p2-sing-e updates that comment.
  - The start-then-poll shape follows `ai.installSpeechModel` plus `ai.speechModelInstallStatus`, and the stretch-render
    status [R].

**Alternatives that lose:**

- **A blocking verb, like `vc.convertClips`.** No progress and no cancel, and a whole song would exceed the 330 s
  `VOICE_CONVERT` bridge tier (`mcp-server/src/bridge.ts`) [R].
- **A job owned by the sidecar (the ACE shape).** The sidecar cannot know it is about to be evicted (R3), cannot land a clip,
  and loses the job when it is killed.

### 4.2 Phases, progress and cancel

| Phase | What happens |
|---|---|
| `queued` | Waiting behind another sing job |
| `waitingForModel` | Another model is busy (R2); the status names it |
| `startingEngine` | The sidecar is booting |
| `preparingVoice` | The voice's first use: the facade loads and resamples the reference |
| `singing` | Unit i of n. Progress is weighted by unit length. The ETA comes from the measured warm RTF (0.38–0.51) and cold start (7–20 s) |
| `finishing` | Assembly, gain and the landing gates |
| `landed` | The track is in the project |
| `checking` | Note accuracy and words, in the background |
| terminal | `done`, `failed(reason)` or `cancelled` |

**Cancel takes effect at the next unit boundary.**

- The model has no cooperative cancel inside `infer()` [R], and killing it mid-unit would cost a 7–20 s reload.
- The UI says so ("Stopping after this line…"), which keeps the law "no cancel button the engine cannot honour".
- `cancelled` appears only after the in-flight unit has returned and nothing has landed.

**Queue.** One job renders at a time, and up to 4 may wait [A]. Beyond that the request is refused with `singQueueFull`.

### 4.3 The phrase cache

The **key** is the sha256 of a canonical JSON of:

- `facadeVersion`;
- the engine commit and the weights' sha256;
- the voice id, the reference's sha256, the prompt labels and `promptLabelOffset`;
- the unit's notes (seconds, target MIDI) and its words;
- lead and trail;
- seed, nSteps, cfg and `outputSampleRate`.

The **value** is the unit's WAV and its result JSON.

- A cache hit skips that unit, so editing one line and singing again renders only that line's unit.
- A truncated or unreadable entry is deleted and treated as a miss.
- LRU, capped at 2 GB [A].

> **WARNING: a cache hit is not a determinism claim.** The only determinism measured is "the same seed twice in one process →
> max |Δ| = 0" [M]. A re-render after a restart is **not known** to be byte-identical. The cache exists to skip work. Nobody may
> treat a hit as evidence that a fresh render would match.

### 4.4 Seeds

- There is one seed per take, used for every unit.
- The first take uses 20260924, the seed behind every render the user picked [M].
- "Try another take" draws a new random seed.
- The seed is recorded in the provenance.
- A unit that comes back `nonFinite` or silent gets one retry with seed + 1, recorded for that unit.

### 4.5 Assembly, gain and landing

1. Sum the units into one buffer (§3.4's placement).
2. Measure with `Loudness.measureDetached`.
3. Compute a static gain toward −18 LUFS, clamped so the true peak stays ≤ −1 dBTP. This is the `BounceLoudnessReport` policy
   (`Loudness.swift:121–158`) [R]: no limiter, and `limitedByCeiling` when the clamp bites.
4. Apply it with `applyGainAndMeasureDetached`, re-measure, and write a Float32 WAV.
5. Run the landing gates (§7.1).
6. Land through a new `ProjectStore.landSungVocal(fileURL:trackName:atBeat:provenance:)`, built on the `importConvertedVoice`
   path (`ProjectStore+VoiceConversion.swift:43`) [R]: **ONE new violet AI track, one clip at `atBeat`, one undo.**

The track is named "Vocals — Built-in singer", "Vocals — <voice name>", or the caller's `trackName`.

**Project identity.** The plan snapshots the project's identity and `signature`.

- **A different project is open at landing time:** nothing lands. The WAV is kept under `Generations`, and its path is
  reported.
- **Same project, but the melody or tempo changed:** the take lands at the planned beat, with the §5.7 notice.
- ⚖️ **Same project, and the SONG WAS TRANSPOSED since the plan (amended 2026-09-27 10:10, orchestrator; from W7-PK's
  finding that this section landed such a take in the OLD key under the generic notice):** detect a PURE
  transposition: the planned melody's notes all present with the same timing, every pitch moved by the same Δ
  semitones, and nothing else changed. Then the take lands with `Clip.pitchShiftSemitones = Δ`, exactly what
  `project.transpose` would have done to it had it landed first (§3.6 moves every recorded or generated audio clip),
  with its own notice in words: "The song moved up 3 semitones while this was being sung, so the new vocal was moved
  up 3 to match." |Δ| beyond `Clip.pitchShiftSemitonesRange` cannot happen (§3.6 refuses |semitones| > 12). Anything
  else that changed the melody falls back to the rule above. Why not refuse, as a clip fix does: a sung take lands on
  a NEW track with no existing lane shift to double-apply, and refusing would throw away minutes of generation.
  Owner: p2-sing-e (the coordinator), with a test for Δ = +3, Δ = 0 (byte-identical landing) and a melody edit plus a
  transposition (falls back).

### 4.6 Checks after landing (advisory: they never block and never un-land)

**Notes.**

- Run `detectPitch(inFileAt:)` on the landed file.
- Score it against the planned target notes with the §1.7 metric: hit rate (±50 c), mean |error| over the hits, and voiced
  coverage.
- Hits ≥ 85%, mean error ≤ 25 c and coverage ≥ 80% read "In tune". Anything else gets an amber notice naming the bars.

**Words.**

- Transcribe the landed file in-process with `WhisperTranscriber.transcribe` (language "en"). Use the router's ONE
  transcriber, so the CoreML compile cache is shared.
- WER uses the spike's normalisation (`code/wer.py`: lowercase, keep `[a-z0-9' ]`, word-level Levenshtein over the
  reference length) [R], ported to a pure DAWCore `WordErrorRate`.
- Curly apostrophes are mapped to `'` first. That is a documented addition, with its own test.
- The reference is each lyric word once; held continuations are not repeated (`ref_from_meta`) [R].
- With no speech model installed, the check is skipped honestly.
- The first transcription on a Mac pays a one-time compile of about 90–140 s [M: 93.7 s on 2026-07-27; 141 s and 116 s in
  the spike], so the card says so.
- **The agent-reachable equivalent** is the existing `clip.transcribe {clipId}` on the landed clip. It uses the same
  transcriber instance and the same `Clip.sourceWindowSeconds` mapping [R], so an agent can reproduce the check the card
  shows.

### 4.7 When something fails

| What happened | What the job does | What the user reads (§5.7) |
|---|---|---|
| The engine is not installed | Refuses at submit | The install card |
| The install fails | The status names the step and the cause; staging is removed | "Installing stopped at …" |
| The engine won't start | `failed`, with the log tail in the details | "The singing engine couldn't start: …" |
| Another model is busy | Waits (R2) | "Waiting for the song generator to finish…" |
| Yielded mid-job (R3) | Waits, resumes, and re-renders one unit | "Paused while the song generator runs…" |
| A unit is NaN or silent | One retry at seed + 1, then fails | "One line didn't come out right…" |
| A crash mid-unit, with no yield recorded | Restarts once and retries the unit, then fails | "The singing engine stopped unexpectedly." |
| The watchdog: footprint | Fails | "…used too much memory, so I stopped it…" |
| The watchdog: memory pressure | Fails | "Your Mac ran very low on memory…" |
| A landing gate fails | Doesn't land; the cache is kept | The gate's sentence (§7.1), and [Try another take] |
| The project was closed | Doesn't land; the WAV is kept | "The project was closed before the singing finished…" |

---

## 5. The novice flow

### 5.1 Where it starts

Right-click a MIDI clip → **"Sing these notes…"**. The same action is in the clip inspector and the piano-roll toolbar. The
sheet opens on that clip.

### 5.2 The Sing sheet

1. **Words.**
   - A text box: "Type the words to sing".
   - Under it, the melody's notes as a strip, with a glowing word chip over each word's notes. A stretched chip is a held word.
   - Warnings and the W > N refusal appear under the box as sentences.
   - Dragging a chip's edge adds or removes a `+` in the text. A one-line legend says "A + holds the word before it onto the
     next note."
2. **Voice.** "Built-in singer", each saved voice, and "Add your voice…".
3. **Height.** One line from `sing.proposeKey`: "Fits your voice.", or "I'll sing it one octave lower…", or the key-change card
   with [Move the song up 3] and [Keep the key]. [Move] shows the `project.transpose` preview first.
4. **[Sing it]**, in violet (AI).
   - The result lands on a new track and the sheet closes.
   - Progress continues in the progress card.

### 5.3 First use: the install card

"To sing, DAW Pro needs its singing engine: a one-time download of about 7 GB. It runs on this Mac, and nothing you sing
leaves it. [Install] [Not now]"

- After Install: progress with the step name and the bytes, and [Cancel].
- When an agent asked for the install, the card adds "An AI agent asked for this."

### 5.4 Add your voice (the recorder)

This is a human act. An agent can open it with `sing.openVoiceRecorder`, but only the user presses Record.

1. **"Pick the tune that's easiest for you."** [▶ Higher] [▶ Lower]
   - These are the two SING-6 guides: four count-in clicks, then "Row, row, row your boat, gently down the stream", at C4 and
     at C3.
   - They ship as DAWCore resources, following the `BundledSamples` precedent. `scripts/sing/tools/make_guides.py` generates
     them deterministically.
   - Measured: −18.0 LUFS; true peak −9.5 and −9.1 dBTP [M].
   - A test re-gates the bundled files with `Loudness` and SwiftF0: every note within ±10 c of P1.
2. **"Are you wearing headphones?"** [Yes — I'll sing along] [No — I'll listen first, then sing]
   - Microphone permission is asked here if needed.
   - The usage string already exists (`scripts/Info.plist:35`) [R].
3. **Record.**
   - "Get ready…" captures 1 s of quiet for the noise check.
   - Then four visual count-in beats. Clicks and the guide play only with headphones.
   - A live level meter, and [Stop]. After the click, capture continues for 0.30 s (the check's `GUARD_AFTER`), so a quick
     click never trips `cut_end`.
   - Recording also stops by itself after 1.5 s of quiet once 3 s of singing has been heard, and at 12 s.
   - "Sing it at whatever height feels natural — you don't have to match the tune."
   - Opening the recorder stops playback, so the song never plays into the microphone.
4. **The check** (~2 s).
   - Pass: "Got it! [▶ Listen] Name: [My voice] [Save]".
   - Fail: one sentence, and [Record again].
5. **Saved:** "Your voice sits around G♯2. I'll pick the best height for each song."

There are two other ways to add a voice:

- "Use a recording you already have… [Choose file]" accepts any audio file (`sing.addVoice {path}`).
- "Use as my singing voice" on an audio clip accepts a take from the project (`sing.addVoice {clipId}`).

**The engine side.** A new optional capability on `AudioEngineControlling`: `startInputOnlyCapture(to:maxSeconds:completion:)`,
`stopInputOnlyCapture()` and `inputOnlyCapturePeakDbfs()`.

- It is built from the existing `InputCapture` (its own input-only `AVAudioEngine`) and a `RecordingWriter` with no
  accept-window anchor (the writer's test mode).
- That is exactly the capture half of `startTakeBody` (`AudioEngine.swift:4887–4895`) [R], without the playback half.
- It refuses while a take is rolling or another capture is running. The default implementation throws "unsupported".

**RT safety.**

- The tap runs on AVFoundation's tap queue, not the render thread (`InputCapture.swift:105–111`) [R].
- The level meter is an unfair-lock float, written there and read by the UI at 30 Hz.
- No render-thread code changes.

**Alternatives that lose:**

- **`startRecording(to:)`.** It starts project playback, and it requires the engine not to be playing already
  (`EngineProtocol.swift:1224–1241`) [R]. The sheet would fight the transport, and the user's song would play into the
  microphone.
- **Record in QuickTime and import it (the SING-6 steps).** As the main path it takes 8 steps (`steps.md`). It stays available
  as "Use a recording you already have".

### 5.5 Progress

Sing jobs join the unified progress card (`GenerationPresenceModel`).

- A new origin, `.sing`, shows the chip "SING". Jobs that come over the wire show "AGENT".
- A determinate bar with "Singing line 3 of 8…", an ETA, and [Cancel], which becomes "Stopping after this line…".
- After landing: "Checking the notes…" and "Checking the words…", then the result chips.

### 5.6 Results

- **Green:** "In tune · Words clear".
- **Amber:** the notes or words notices in §5.7.
- **Buttons:** [▶ Play from here] [Try another take] [Choose a different voice].
- **A tip** after the first take: "Turn the melody track down to hear the voice clearly."

### 5.7 The novice copy, in one place

| Where | Text |
|---|---|
| Install card | "To sing, DAW Pro needs its singing engine: a one-time download of about 7 GB. It runs on this Mac, and nothing you sing leaves it." |
| Install card, agent-requested | "An AI agent asked for this." |
| Install stopped | "Installing stopped at '{step}': {cause}. [Try again]" |
| Engine won't start | "The singing engine couldn't start: {cause}. [Try again] [Details]" |
| Starting | "Starting the singing engine… (about 20 seconds)" |
| Waiting for another model | "Waiting for the song generator to finish — it's using most of this Mac's memory." |
| Yielded | "Paused while the song generator runs; I'll carry on after." |
| ACE started outside DAW Pro | "The song generator is also running outside DAW Pro, so this Mac may run short of memory." |
| Singing | "Singing line {i} of {n}…" · "Stopping after this line…" |
| Bad unit | "One line didn't come out right (line {i}). Try another take." |
| Crash | "The singing engine stopped unexpectedly." |
| Watchdog: footprint | "The singing engine used too much memory, so I stopped it. Try shorter lines." |
| Watchdog: pressure | "Your Mac ran very low on memory, so I stopped the singing engine. Close other apps or the song generator and try again." |
| W > N | "This line has {W} words but the tune has {N} notes. Each note sings one word, so remove {W−N} words or add {W−N} notes." |
| Held words | "The tune has {k} more notes than your words need. I held '{word}' across them. Add words, or drag a word to cover different notes." |
| Chords | "Your tune has chords at {k} places; I sang the top note." |
| Squeezed word | "'{word}' is squeezed onto one short note, so it may sound rushed." |
| Split line | "I had to split a very long line without a breath at bar {b}; you may hear a seam." |
| Note too long | "One note is longer than 20 seconds. Please shorten it or split it." |
| Not English | "I can only sing English words so far — '{word}' isn't one I can pronounce." |
| No lyrics | "Type the words you want me to sing." |
| Drum track | "This clip is on a drum track. Pick a melody clip — one with the notes you want sung." |
| Audio clip | "Sing needs a melody clip with notes. This one is audio." |
| Fits | "Fits your voice." |
| Octave | "Your voice sits lower than this tune. I'll sing it one octave lower — it stays in tune with the rest of the song." |
| Key change | "This tune is much higher than your voice. Best: move the whole song up {t} half-steps and I'll sing it two octaves lower — right where you sing." |
| Keep the key | "Keep the song as it is and I'll sing two octaves lower (some low notes will be below where you usually sing)." |
| Transpose preview | "This moves {n} instrument tracks and {m} recorded tracks. Drums stay as they are." |
| Transpose, audio | "Your recorded track '{name}' will be pitch-shifted too, which can sound slightly processed." |
| Melody changed | "The melody changed while I was singing; this take follows the earlier version." |
| Project closed | "The project was closed before the singing finished. The take is saved in {folder}." |
| Quiet take | "This take came out quieter than usual because of a sharp peak; turn the track up if you need to." |
| Results | "In tune · Words clear" · "Some notes may be off (bars {list})." · "Some words may be hard to make out." · "The words are hard to understand in this take — try another take, or give long words more notes." |
| Word check, first time | "Checking the words… (the first check on this Mac takes about two minutes)" |
| Word check skipped | "Word check skipped: no speech model is installed. [Install]" |
| Hard-to-judge voice | "Word check: hard to judge for this voice." |
| Mic permission | "Your Mac will ask whether DAW Pro may use the microphone — click Allow." |
| Mic denied | "DAW Pro isn't allowed to use the microphone. Open System Settings → Privacy & Security → Microphone and turn on DAW Pro." |
| Check: too short | "Your recording is only {d} seconds long. Please record the whole line again — it takes about 5 seconds." |
| Check: too long (imports only) | "Your recording is {d} seconds long. Please use one under 12 seconds that stops a moment after the singing ends." |
| Check: no voice | "I couldn't hear the line being sung. Please check that your Mac's microphone is chosen in Settings → Audio Input, then sing the whole line once at your normal loudness." |
| Check: cut start | "The recording starts after you began singing. Please wait for the count-in, then sing." |
| Check: cut end | "The recording stopped before you finished singing. Please wait a moment after the last word before you stop." |
| Check: too loud | "Your recording is too loud, so it may be distorted. Please record again a little further from the Mac, or sing a little softer." |
| Check: no gap | "Please leave a moment of quiet before you start singing and after you finish, so I can check the room is quiet." |
| Check: noisy | "There's too much background sound (music, a TV or a fan) around your singing. Please record again somewhere quieter, with nothing playing." |
| Check: guide leak | "I can hear the guide tune in your recording. Please use headphones, or listen to the tune first and then sing with nothing playing." |
| Poor alignment | "I couldn't follow your recording closely (did you sing the same words?). Your voice will still work, but it may sound less like you." |
| Voice saved | "Your voice sits around {note}. I'll pick the best height for each song." |
| Built-in voice name | "Built-in singer" |

---

## 6. Wire and MCP surface

**Everything is additive.** MCP tool names are the mechanical snake_case of the verb, like every existing tool
(`vc.sidecarStatus` → `vc_sidecar_status`) [R]. **Never quote the wire total:** take it from
`node scripts/gates/doc-count-drift.mjs` at merge time. W7-WIRE is changing it as this is written.

| # | Verb | MCP tool | Params | Returns | Refusals | Bridge tier |
|---|---|---|---|---|---|---|
| 1 | `sing.sidecarStatus` | `sing_sidecar_status` | `verify?` | State (§2.8), install progress, runtime facts, health, pid, resident, last error | — | default (5 s) |
| 2 | `sing.sidecarStart` | `sing_sidecar_start` | — | State once `ready` | `singEngineNotInstalled`, `singEngineNeedsUpdate`, `singPortBusy`, `singStartFailed` | LONG_RUNNING (180 s) |
| 3 | `sing.sidecarStop` | `sing_sidecar_stop` | `cancelJobs?` | The stop evidence (three limbs) | `singJobsRunning` unless `cancelJobs: true` | default |
| 4 | `sing.installEngine` | `sing_install_engine` | — | `awaitingUserConsent` (from the wire), `installing`, or `alreadyInstalled` | `singInstallInProgress`, `singDiskFull` (reports the measured free space), `singUnsupportedMac` | default |
| 5 | `sing.cancelInstall` | `sing_cancel_install` | — | `{cancelRequested: true}` | `singNoInstallRunning` | default |
| 6 | `sing.uninstallEngine` | `sing_uninstall_engine` | `dryRun?` | Bytes freed, or that would be freed. From the wire: `awaitingUserConsent` | `singInstallInProgress`, `singJobsRunning` | LONG_RUNNING |
| 7 | `sing.listVoices` | `sing_list_voices` | — | `[{id, name, kind, createdAt, durationS, range {p10Midi, p50Midi, p90Midi, lowNote, medianNote}, alignment {method, verdict}, wordCheck?}]`. Works with the engine down | — | default |
| 8 | `sing.addVoice` | `sing_add_voice` | `path` or `clipId`; `name?` | The saved voice. The check, range and labels run in Swift, so **no engine is needed**; the word check follows in the background | The 9 clip-check reasons (§5.7); `singVoiceFileUnreadable`; `singVoiceNeedsAudioClip`; `singVoiceClipStretched` (the `clip.transcribe` rule: a stretched clip's timing is not source timing) | CLIP_DETECT_PITCH (60 s) |
| 9 | `sing.removeVoice` | `sing_remove_voice` | `voiceId` | `{movedToTrash: path}` | `singVoiceNotFound`, `singVoiceBuiltIn` | default |
| 10 | `sing.openVoiceRecorder` | `sing_open_voice_recorder` | — | `{opened: true}` | `singNoWindow` | default |
| 11 | `sing.proposeKey` | `sing_propose_key` | `clipId`, `voiceId?` | The voice range, the melody range, the recommendation `{kind: octave\|songKey, octaveShift, songTranspose, vocalOffset, calibrated}`, alternatives, and a sentence | `clipNotFound`, `singNeedsMIDIClip`, `singVoiceNotFound` | default |
| 12 | `clip.setLyrics` | `clip_set_lyrics` | `clipId`, `text` (`""` clears), `dryRun?` | The assignment `{words: [{text, noteIds, startBeat, endBeat, held}], lines, warnings}` and `stored` | `clipNotFound`, `lyricsNeedMIDIClip`, `lyricsTooManyWords` (with the sentence), `lyricsNotEnglish`, `lyricsTooLong` (over 4,000 characters) | default |
| 13 | `clip.getLyrics` | `clip_get_lyrics` | `clipId` | The text, and the assignment derived now, with its warnings | `clipNotFound` | default |
| 14 | `sing.render` | `sing_render` | `clipId`; `lyrics?`; `voiceId?` (default `builtin-1`); `octaveShift?` (`"auto"` or −2…2); `seed?`; `trackName?`; `dryRun?` | `{jobId, plan}`. With `dryRun`, the plan alone: units, assignment, warnings, the octave choice, estimated seconds, and whether an install or start is needed | `clipNotFound`, `singNeedsMIDIClip`, `singClipHasNoNotes`, `singDrumTrack`, `singNeedsLyrics`, `lyricsTooManyWords`, `lyricsNotEnglish`, `singVoiceNotFound`, `singOctaveShiftInvalid` ("A vocal can only move by whole octaves on its own; to change the song's key use project.transpose."), `singNoteTooLong`, `singEngineNotInstalled`, `singEngineNeedsUpdate`, `singQueueFull` | default (returns at once) |
| 15 | `sing.jobStatus` | `sing_job_status` | `jobId?` (omit it for the last 20) | State, phase, unit i/n, progress, ETA, `waitingFor`, warnings, the result `{trackId, clipId, loudness, noteAccuracy, wordCheck {state, wer, heard, verdict}}`, and any error | `singJobNotFound` | default |
| 16 | `sing.cancelJob` | `sing_cancel_job` | `jobId` | `{cancelRequested: true}` | `singJobNotFound`, `singJobFinished` | default |
| 17 | `project.transpose` | `project_transpose` | `semitones` (−12…12), `excludeTrackIds?`, `dryRun?` | What moved and what was skipped, per field, plus warnings | `transposeOutOfRange`, `transposeNoteOutOfRange`, `transposeAudioShiftOutOfRange` (names the clip), `transposeLooperOpen`, `trackNotFound` (both added 2026-09-27 by W7-PK) | default |

**Rules that apply across the verbs:**

- `sing.render` with `lyrics` stores them through the same store call as `clip.setLyrics`, as its own undo step, before the
  job. The landing is a separate undo step.
- A render starts the engine if needed, so an agent needs only one call.
- Every verb uses `rejectUnknownKeys`, with the tree's teaching hint.

**Tests, per verb:**

- the params, and each refusal's exact sentence;
- a **spy test** (not a source-shape test) proving the UI path and the wire reach the same coordinator or store method;
- an npm test per MCP tool;
- `doc-count-drift.mjs` passing with the new count.

**What an agent can and cannot do.** An agent can do everything except the two human acts:

- it **asks** for the install (4), and the user approves it;
- it **opens** the recorder (10), and the user presses Record;
- it can add any existing file or take as a voice (8), then render (14).

---

## 7. Quality gates

### 7.1 Landing gates (a take that fails any of these does not land)

| Gate | Passes when | Basis |
|---|---|---|
| **L1 Physics** | Every sample is finite; the length is the planned span ± 20 ms; every unit reported `nonFinite: false` after its one retry | Structural |
| **L2 Singing present** | SwiftF0 voiced coverage is ≥ 50% of the planned note time | [A]. §1.7's advisory bar is 80% |
| **L3 True peak** | ≤ −1.0 dBTP after gain | Holds by construction, and is **asserted on the written bytes**: this tree has shipped a loudness gate that passed a clipping render |
| **L4 Audible** | Integrated ≥ −30 LUFS after gain | [A]. A take between −30 and −18 LUFS with `limitedByCeiling` lands, with the "quieter than usual" notice |

**Why −18 LUFS is the target, not the bar.** The render the user picked (−18 st) was held to −19.2 LUFS by the ceiling, and
the SING-6 record says it "fails G1" [M]. A −18 LUFS gate would reject the render the user chose.

**Controls** (from the stub facade's faults, item p2-sing-b):

- a planted NaN fails L1;
- a planted silent unit fails L2;
- a sine unit with a full-scale click lands ceiling-limited, with the L4 notice;
- a clean sine unit passes all four.

A gate that passes every plant cannot fail, and is not used.

### 7.2 Note accuracy (advisory)

The metric and bar are §1.7's: hit ≥ 85% within ±50 c, mean |error| ≤ 25 c, voiced coverage ≥ 80%.

- **Controls:** a sine at the exact pitches scores 100% within ±10 c, and a sine one semitone sharp scores 0% within ±50 c.
- The −12 own-voice render missed one note by a real octave: 18/19, confirmed by a second instrument [M]. This check is what
  surfaces such a miss, in amber.

### 7.3 Word clarity (advisory)

| WER | What the user sees |
|---|---|
| ≤ 0.20 | "Words: clear" |
| 0.20–0.40 | "Some words may be hard to make out" |
| > 0.40 | "The words are hard to understand in this take…" |

- The bands are provisional [A].
- The measured anchors: the built-in V1 voice on the spike's line scored WER 0 [M]. A sine control was transcribed as "" and
  as "*Sings*", i.e. WER 1.0 [M].

**The instrument check, per own voice.** At `sing.addVoice`, the reference is transcribed against the guide text, in the
background.

- If its WER is over 0.20, Whisper struggles with this voice's diction. Later word checks in this voice then read "hard to
  judge for this voice" instead of amber.
- Built-in V1 was recorded in Chinese, so its anchor is the measured stock result, not its prompt.

**Controls,** run when the check is first wired: the stock render must score ≤ 0.2, and a sine render > 0.9 (or empty).

### 7.4 Listening options in the product

"Try another take" draws a new seed and makes a new track. The options differ on one axis: the seed.

### 7.5 Listening rounds in item p2-sing-g (one axis each, 3–4 options)

Both rounds go on the user's listening page, rewritten in place. **The user's pick is the feedback.**

**How these renders are made.** −18, −20 and −21 are not whole octaves, so `sing.render` refuses them by design (§6 #14),
and the planner's test requires target − source to be a multiple of 12 (§3.4). So the gate harness calls the facade's
`/v1/sing/phrase` **directly**, with target MIDI = written + v (the spike harness's shape), bypassing the planner. The
octave-only invariant is a product rule enforced by the planner, not a facade rule.

- **Round K (key calibration).** The own voice on the SING-6 line at −18 (their pick, the anchor), −20, −21 and −24.
  - −24's lowest note, C2 at 65 Hz, sits below the recording's p10 (ROADMAP) [M]. SwiftF0's 46.9 Hz floor can measure it; the
    spike's 65 Hz pyin could not.
  - The pick calibrates the weights in §3.5.
- **Round L (prompt labels).** The own voice at −18, in three versions:
  1. the SING-6 file itself, as published: Route H labels with upstream `pitch_shift`, the exact render the user picked;
  2. Route N labels with `promptLabelOffset = −18` (prompt labels offset with the target, which reproduces upstream
     `pitch_shift`'s effect on the labels);
  3. Route N labels with `promptLabelOffset = 0`, the product default.

  A facade reproduction of option 1 is also compared byte for byte with the SING-6 file. That comparison is informative, not a
  gate: cross-process identity is unmeasured (§4.3).

### 7.6 Measurements before the listening rounds (items p2-sing-b and p2-sing-g)

- **The prompt-f0 null test.** In one process with one seed, a render with the prompt f0 omitted must match, byte for byte, a
  render with a full-length prompt f0. That licenses leaving f0 out (§3.7).
- **The label-offset question.**
  - The render the user picked came from upstream `--pitch_shift -18`, which moves the prompt's labels as well as the
    target's. So its prompt was labelled about 18 semitones below what was sung.
  - The product default (`promptLabelOffset = 0`, target-only octaves) is physically consistent, but it is **not** the recipe
    the user heard.
  - Round L decides. If the user prefers option 1 or 2, the planner sends `promptLabelOffset` equal to the vocal's shift. That
    is a one-line default change, and the comparison already needs the field.
- **H vs N, by the numbers.** Same seed, same target, with the Route H prompt and the Route N prompt. Score note accuracy, WER,
  and MFCC timbre-cosine against the recording, **with a second-seed noise floor**. SING-6 lacked that control, which is why
  its "about 2.4× closer" was not yet a claim.
- **Memory:** the tree's footprint per unit ≤ 7 GiB [M: 6.05 GiB].
- **Speed:** warm RTF per unit ≤ 0.6 [M: 0.38–0.51].

---

## 8. Failure modes this design is built around

| # | Failure | What catches it |
|---|---|---|
| F1 | A SoulX boot kills an ACE generation the Sketchpad started (an unregistered job) | Item p2-sing-0 and R2, with a negative-control test |
| F2 | ACE and SoulX resident together | `yieldsWhenBusy` and R2. The R4/R6 windows are named, and the watchdog cleans up |
| F3 | A stop that "succeeded" while the process ran on (m23-bb) | The three-limb evidence, pid-exact stops, and `run.sh` exec |
| F4 | The vocal shifted off-key | The facade hard-codes `auto_shift=False` and `pitch_shift=0`; `octaveShift` takes integers only; a planner test checks that target − source is a multiple of 12 |
| F5 | Reference labels silently wrong (Route H) | Route N, plus the vacuity warning |
| F6 | Downloads landing in shared caches, or happening at run time | Cache redirects, and `HF_HUB_OFFLINE=1` |
| F7 | A built-in voice that differs from the one picked (decoder drift) | The sha256 check on the cut WAV |
| F8 | Gates that cannot fail | A control for every gate (§7) |
| F9 | A clipping render that passes a loudness check | L3, asserted on the written bytes |
| F10 | The cache taken as proof of determinism | §4.3 |
| F11 | Path traversal through the facade | Allowed roots, checked on the realpath |
| F12 | The recorder capturing the song or the guide | Opening the recorder stops playback; the headphones question; `guide_leak` |
| F13 | A quiet but correct render refused | L4's semantics |
| F14 | The space in "Application Support" breaking a script | No console scripts, and a test path containing a space |
| F15 | The first word check blocking for about 2 minutes | It runs in the background, and the copy says so |
| F16 | The lyric assignment going stale after a note edit | The assignment is derived, never stored |
| F17 | Staging deleting the user's install | The runtime directory is profile-aware |
| F18 | An agent starting a 7 GB download | The consent window (Q1) |
| F19 | An MPS op silently falling back to the CPU | `PYTORCH_ENABLE_MPS_FALLBACK` stays unset, as measured |
| F20 | The main actor wedged while analysing minutes of audio | SwiftF0 and `Loudness` run detached, off the main actor |
| F21 | A sing job landing in a different project | The identity check (§4.5) |

---

## 9. Staged delivery, in order

**Standing constraints for every item** (brief every agent on these):

- Work on staging (port 17695) only. **Never touch 17600.**
- Name the test project `p2-sing-<item>-<date>`.
- Stop the SoulX sidecar pid-exact after every leg that loaded the model.
- **Never start ACE.** Residency tests use a fake registered model.
- Test with `./scripts/test.sh`, never bare `swift test`.
- No `git checkout`, `git stash`, `git restore` or `git clean`.
- No commits without the user's word.
- Never touch audio devices, `.env`, `scripts/ace-step/` or `scripts/rvc/`.

| Id | Item | Route | Depends on | Gate |
|---|---|---|---|---|
| **p2-sing-0** | Every model job registers. `LifecycleTrackingSongGenerator` goes below the three observers and the presence poll. Add `LifecycleTrackingVoiceConverter` | `mcp-integration-engineer`; review by `daw-architect` | — | A fake `SongGenerating` against the real coordinator. A Sketchpad-origin job appears in `openJobIDs`, and a terminal poll removes it. `ModelAdmission.resolve` lists ACE as `protectedByJobs` during a Sketchpad job. **Negative control:** without the decorator, the same test lists ACE in `evicting`. The same checks for RVC `convert` and `train` |
| **p2-sing-b** | `scripts/sing/`: the facade, `run.sh`, `install.sh`, the lock, the pins, `stub_server.py` and the guide generator. The stub is standard-library only and runs under the system `/usr/bin/python3`. Its faults: `nan`, `silence`, `click`, `crash`, `slow`, `balloon` | `audio-dsp-engineer` | — | Python tests: the converter reproduces the spike's T1, T2 and T1T2 JSON **byte for byte**; the allowed-roots and schema refusals. `install.sh` is idempotent against a local fixture mirror (`SING_INSTALL_SOURCE` and `SING_PINS_FILE`, tests only) under a path containing a space. `run.sh`'s pidfile pid owns the port (lsof). One real-model smoke run on staging: T1 renders, and the prompt-f0 null test (§7.6) passes |
| **p2-sing-c** | `SingingSynthesizing`/`SingingSynthesisClient`; `SingingSidecarManager` (with an injectable watchdog cap); `SingingEngineInstaller` and its install coordinator; `ModelRegistry.soulxSinger`; `yieldsWhenBusy`; the three new `AppDirectories` categories | `mcp-integration-engineer`; stop and lifecycle reviewed by `daw-architect` (the m23-bb precedent) | b | `ModelAdmission.resolve`: a busy `yieldsWhenBusy` resident lands in `evicting` while a busy ACE stays `protectedByJobs`. Control: with the flag false, SoulX is protected. The manager against the stub on a test port: spawn, health, the three stop limbs, a stale pidfile, the port-busy refusal, a yield classified as a yield, and a watchdog kill (512 MB cap, 600 MB balloon). The installer against the fixture mirror, including cancel (`cancelled` appears only after cleanup) |
| **p2-sing-d1** | `ClipLyrics`, `LyricTokenizer`, `LyricNoteAssigner`, `EnglishSyllables` | `swift-app-engineer` | — | A decode test (an old project gives nil) and a round-trip. Table tests for rules 1–7 (§3.3), the markup, punctuation, curly apostrophes, numbers, and the exact W > N sentence. Syllables ≥ 90% on the fixture |
| **p2-sing-d2** | `SingPlanner`; `landSungVocal`; `SungVocalProvenance` (with a decode test); `WordErrorRate` (a port of `wer.py`, tested against its outputs) | `swift-app-engineer` | d1 | Planner tables: monophony, legato, units, splits, tempo changes, loop expansion through playback's own evaluator, and target − source always a multiple of 12. Landing makes one track in one undo, and undo removes it. The identity and signature checks |
| **p2-sing-d3** | `VoiceRangeFit`; `VoiceClipCheck`; `VoiceReferenceLabeler` (Route N) plus a test-only Route H; `SingGuideLine` (P1) and the bundled guide WAVs | `audio-dsp-engineer` | — | §3.7's fixtures, with Route H failing fixture 3. §3.8's re-run controls. The guide files re-gated with `Loudness` and SwiftF0. `VoiceRangeFit` reproduces §3.5's [D] numbers on T1T2 from the same inputs: a test that pins the arithmetic, not the weights |
| **p2-sing-k** | `project.transpose` | `swift-app-engineer` (DAWCore); `mcp-integration-engineer` (wire and MCP) | — | The census first: the method and the field list go in the item report. A test per field. Drums skipped. The audio clamp refusal. One undo. `dryRun` changes nothing (store snapshot equality). **Invariance control:** `semitones: 0` gives a byte-identical render |
| **p2-sing-e** | `SingJobCoordinator`; `startInputOnlyCapture`; the 17 verbs, 17 MCP tools and the bridge tiers; the `clip.transcribe` comment update; `GenerationJobOrigin.sing` | `mcp-integration-engineer` (coordinator, wire, MCP); `audio-dsp-engineer` (capture); RT review by `daw-architect` | c and d1–d3. k is optional: it lights the [Move] button | Coordinator tests against a fake synthesizer: every phase, cancel at a boundary, yield and resume, the one retry, crash and restart, the queue, identity, and the landing gates with their controls. A capture test with synthetic buffers (the `RecordingWriter` precedent: no mic, no TCC). Wire and npm tests; `doc-count-drift` passes. A staging E2E with the stub: render, land, undo |
| **p2-sing-f** | The UI: the sheet, word chips, the voice picker, the key line and card, the install card and consent window, the recorder, progress, and results | `swift-app-engineer` + `ui-design-engineer` | e | `/dogfood` on staging with the stub (a UI phase isn't done until someone has looked at it). Screenshots of every state. Every string checked against §5.7. The design language: dark glass, violet for AI |
| **p2-sing-g** | The real-model gate, and listening rounds K and L | `qa-test-engineer` + `audio-dsp-engineer` | f | On staging, with the real runtime APFS-cloned into the staging profile (the spike's WhisperKit clone method, spike deviations 15:20) [M]. The built-in voice on T1T2 lands with hits ≥ 85%, error ≤ 25 c, WER ≤ 0.2, TP ≤ −1 dBTP, and audible. Memory and RTF per §7.6. Residency: a fake model's boot during a job makes SoulX yield, and the job resumes. If Q3 is yes: the user's recording goes in through `sing.addVoice {path}`, Route N's verdict is good, §7.6 is measured, and rounds K and L are published. At the end, the SoulX sidecar is stopped pid-exact, with a positive control |
| **p2-sing-h** | Docs. `docs/AI-INTEGRATIONS.md` port rows for **8002** (missing today) and **8004**. The ARCHITECTURE namespace list, and a section. ROADMAP boxes. CHANGELOG. A plugin bundle regeneration, **plus the sing tools added to the hand-maintained agent allowlists**, which regeneration does not update. `/plugin update` is the user's action | `docs-scribe` | g | `doc-count-drift` passes. The allowlist diff is checked against the artifact the user loads |

---

## 10. Out of scope, on purpose

- **Languages other than English.** SoulX supports Mandarin and Cantonese, but our G2P and UI are English only. The built-in
  voice sings English despite its Chinese prompt [M].
- **Arbitrary reference recordings** (anything other than the guided line). Labelling them needs WhisperKit word timestamps,
  which some installed variants lack (`wordTimestampSupport`) [R], plus a G2P alignment. Importing such a file is allowed;
  labelling it is a follow-up.
- **Melody-conditioned mode** (f0 from an audio melody) and **SVC mode.**
- **Route P's preprocessing stack**, and **MLX or quantized weights** (the spike did not adopt them).
- **RVC chaining inside the sing flow.** It is already composable: run `vc.convertClips` on the landed clip.
- **Embedding singing-voice references in saved projects.** The user's recorded voice would travel inside every project file
  they share. That is the user's call, and it is not asked now because v1 doesn't need it.
- **Per-note expression:** vibrato depth, breathiness, dynamics from velocity. Score mode has no velocity input.
- **Harmonies and backing vocals.** Chords sing their top note.
- **Live or streaming singing.**
- **Recording the voice over the song's playback.**
- **Auto-muting the melody track.**
- **Renaming a voice** in v1. Remove it and add it again.
- **More than one render at a time.** One renders; up to 4 queue.

---

## 11. Questions for the user

These are the only ones that are genuinely the user's: consent, disk and taste. Each has a recommended default. Everything
measurable was decided above, with its reason.

1. **Consent for the download.** When an AI agent asks DAW Pro to install the singing engine (a one-time download of about
   7 GB), what should happen?
   - (a) DAW Pro shows you a window, and nothing downloads until you click Install.
   - (b) It installs without asking.
   - (c) Agents can't start it at all; only you can, from the Sing sheet.

   **Recommended: (a).** Agents can still do everything else, and the big download stays your decision. The same window
   guards uninstalling.
2. **Disk.** Once DAW Pro's own singing engine passes its checks, may we delete the test folder `~/DAWPro-spikes/sing-soulx`?
   It holds several GB; the exact figure is measured right before deleting. The model file is copied into DAW Pro first, so
   nothing is downloaded twice.

   **Recommended: yes, delete it once the checks pass.**
3. **Your recording.** When the feature is ready, may DAW Pro save the recording you already gave
   (`~/Downloads/raw-raw-song.m4a`) as your singing voice, "My voice"? Then you won't need to record again. It stays on this
   Mac, and you can remove it any time.

   **Recommended: yes.**

**Asks that come later, not now.** Round K (which height sounds best, 4 options) and Round L (which sounds most like you,
3 options) appear on your listening page when item p2-sing-g runs.

**Decided here, not asked.** Only Version 1 ships as the built-in voice, because you picked it over the English-recorded
voice.

---

## 12. Full Xcode, signing, entitlements

**None of these is needed.**

- The microphone usage string already exists (`scripts/Info.plist:35`) [R].
- `bundle.sh` copies `scripts/sing/` into `Contents/Resources/` before its ad-hoc `codesign`, which the Command Line Tools
  provide.
- No AUv3 and no new entitlement: the app already spawns sidecar processes.
- The guide WAVs go in DAWCore's existing resource bundle, which `bundle.sh` already requires (`daw-pro_DAWCore.bundle`) [R].

---

## 13. Invariants this design keeps

- **The render thread is untouched.**
  - Synthesis runs offline, in another process.
  - The recorder's tap runs on AVFoundation's tap queue.
  - Loudness and pitch analysis run detached.
  - The landed take plays as an ordinary audio clip.
  - **Nothing here risks allocating, locking or blocking on the render thread.**
- **One command surface.** 17 verbs, with the UI and the wire sharing one coordinator and one set of store methods. The two
  acts that only a human can do each have a verb that asks for them.
- **DAWCore stays headless and dependency-free.** The new code is pure Foundation, and the guide audio uses DAWCore's existing
  resource bundle.
- **DAWEngine hides CoreAudio and AVAudioEngine.** Capture is a new optional capability behind `AudioEngineControlling`.
- **Additive only.** No existing verb, tool, field or file is renamed.

---

## 14. How this differs from the spike plan's §5, and why

| Spike plan §5 | This design | Why |
|---|---|---|
| A FastAPI facade with `/v1/sing/jobs` and `/jobs/{id}` | A standard-library server with one synchronous `/v1/sing/phrase` | The measured lock has no fastapi, and the app must own the job anyway (§2.4, §4.1) |
| `POST /v1/sing/phonemize` for syllable counts | A Swift heuristic, plus markup | Previews must work with the engine down (§3.3) |
| Word spans stored on the clip | Only the text is stored; the assignment is derived | No stale records (§3.1) |
| `sing.previewAssignment`, `sing.lyricsOnClip`, `sing.status`, `sing.import`, `sing.setVoiceReference` | `clip.setLyrics {dryRun}`, `sing.render`, `sing.jobStatus`, automatic landing, `sing.addVoice`, and 12 more | The job lands its own track (the "always a new track" ruling), so an agent cannot leave a finished render un-landed |
| MCP `sing_lyrics_on_lead` and `get_sing_job` | Mechanical names (`sing_render`, `sing_job_status`, …) | Every other tool maps one-to-one to its verb |
| A `HoldRequirement` "marked exclusive with ACE" | `yieldsWhenBusy`, and rules R0–R6 | A rule, not a table (m23-dl) |
| The runtime under `sidecars/soulx-singer/` | `DAWPro/SingingEngine/`, profile-aware | Uninstall safety on staging |
| Route H, in the app | Route N | Route H aligned 1 of 10 notes [M] |
| A voice picker that includes "your trained RVC voice" | The built-in voice plus own voices; RVC stays composable after landing | It was not part of the user's pick |
| Gate G1 at −18 LUFS | −18 LUFS is the target; the gates are L1–L4 | The user's pick measured −19.2 LUFS [M] |

---

## 15. Verification ledger

**Read first-hand for this design (2026-09-27):**

- `ModelLifecycleCoordinator.swift` (`commitAdmission` 641–686; `ModelStopEvidence` 35–67; `noteJobStarted`/`noteJobEnded`
  828–849), and `ModelAdmission.swift:204–218`;
- `ModelRegistry.swift` (245, 255, 262, 264–300);
- `DAWProApp.swift` 4770–4919;
- `GenerationPresenceModel.swift` 1–60 and 604–700;
- `SoundBankDownloadCoordinator.swift` 110–175;
- `VoiceConversionManager.swift` 806–1075;
- `bundle.sh` 136–210 and 264;
- `AppDirectories.swift` 1–140;
- `InputCapture.swift` (whole), `RecordingWriter.swift` 1–110, `AudioEngine.swift` 4872–4917, and `EngineProtocol.swift`
  1205–1280;
- `PhraseDetection.swift` 1–30 and 147;
- `Loudness.swift` 110–170 and 630–684;
- `VoiceProvenance.swift` (whole);
- the `Commands.swift` case `clip.transcribe`;
- the tier sets in `mcp-server/src/bridge.ts`, and the `vc_*` tool names in `server.ts`;
- `Package.swift`'s targets and resources;
- upstream `cli/inference.py` 16–62, `soulxsinger/models/soulxsinger.py` 20–45 and 105–200, `data_processor.py` (whole), and
  `preprocess/tools/midi_parser.py` 290–500;
- from the spike: `score_from_notes.py`, `wer.py`, `env.sh`, `own-voice.sh`, `s5_untimed_batch.sh`, `logs/deviations.md`,
  `logs/preflight-s9.txt:49` and `venv-alt/pyvenv.cfg`;
- from SING-6: `STATUS.md`, `brief.md`, `make_guides.py` and `steps.md`.

**Measured by me in this session:**

- nothing listening on 8004 (lsof);
- the port grep, with 8002 as its control;
- the job-registration grep (`noteJobStarted`/`noteJobEnded` only in `Commands.swift`), with its control.

**Taken from records, not re-measured:** every spike and SING-6 number marked [M] (the ROADMAP entries, the spike logs, the
SING-6 files).

**Derived:**

- the §3.5 key-fit numbers (scratch arithmetic over the T1T2 notes, with an assumed p90);
- the install size;
- the worst-case waste from a yield;
- the 16 GiB watchdog cap.

**Unverified, and the item that verifies each:**

| Unverified | Verified by |
|---|---|
| g2p_en's number normalisation | p2-sing-b |
| The prompt-f0 null test | p2-sing-b |
| That the rebuilt built-in cut WAV is byte-identical | p2-sing-b |
| That renders are byte-identical across processes | p2-sing-g |
| Every [A] threshold | The item named beside it |
