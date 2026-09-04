# Publishing to YouTube

`scripts/publish.py` uploads a finished film, sets its thumbnail, adds it to a
playlist, and then **reads the video back to prove it arrived intact**.

Two things to know before you start, because they shape everything else:

⚠️ **Uploads from an unaudited API project are forced to private.** Any Google
Cloud project created after 28 July 2020 that calls `videos.insert` has its
uploads locked to private until the project passes YouTube's compliance audit.
You will get an email saying so. This is YouTube policy, not a limitation of
this script — and `publish.py verify` names it explicitly when it sees it, so
you never mistake it for a bug.

⭐ **That is why the script defaults to `private` anyway.** Uploading is the
reversible half; publishing is not. The intended workflow is: upload as a
private draft with all metadata already correct, watch it once, then press
publish yourself in YouTube Studio.

---

## One-time setup

### 1. Install the upload dependencies

```bash
./install.sh --publish            # adds them to the kit's venv
./install.sh --no-models --publish  # if the models are already there
```

`validate` and `--dry-run` work **without** this step — only the network path
needs the Google libraries.

### 2. Create a Google Cloud project and an OAuth client

1. Go to <https://console.cloud.google.com/> and create a project.
2. **APIs & Services → Library →** enable **YouTube Data API v3**.
3. **APIs & Services → OAuth consent screen →** External. Add yourself as a
   **test user** — an app in "testing" only works for listed accounts.
4. **APIs & Services → Credentials → Create credentials → OAuth client ID →
   Desktop app.** Download the JSON.
5. Save it as `client_secret.json` (anywhere; point `--client-secret` at it, or
   set `YT_CLIENT_SECRET`).

The scope requested is `https://www.googleapis.com/auth/youtube`.

⚠️ That is deliberately not the narrower `youtube.upload`: **`playlistItems.insert`
does not accept `youtube.upload`**, so the narrow scope uploads fine and then
fails to file the video in a playlist. Verified against the per-method
authorization tables on 2026-09-03.

### 3. Authorise once

```bash
.venv/bin/python scripts/publish.py auth --client-secret /path/to/client_secret.json
```

A browser opens; approve. A refresh token is written to `youtube-token.json`
with mode `600`.

⚠️ **Both files grant write access to your channel.** They are in
`.gitignore` (`client_secret*.json`, `*token*.json`) — keep them there, and
never paste either into a chat, an issue, or a log.

### 4. Phone-verify your channel, if you want custom thumbnails

`thumbnails.set` needs a phone-verified account. Without it the upload still
succeeds; the thumbnail step prints a warning and YouTube keeps its auto-picked
frame.

---

## The metadata sidecar

Each film gets a `publish.json` beside it. Paths inside it resolve **relative to
the JSON file**, not your shell's working directory.

```json
{
  "title": "Your mix sounds muddy: I measured four fixes, and the winner isn't an EQ",
  "description": "Full description text.\nNewlines are fine.",
  "tags": ["mixing", "EQ", "music production"],
  "categoryId": "27",
  "defaultLanguage": "en",
  "privacyStatus": "private",
  "containsSyntheticMedia": false,
  "madeForKids": false,
  "publishAt": null,
  "thumbnail": "thumb.png",
  "playlist": "Mixing, measured"
}
```

| field | notes |
|---|---|
| `title` | ≤ 100 chars, no `<` or `>` |
| `description` | ≤ 5000 chars, no `<` or `>` |
| `tags` | ≤ 500 chars **in total**, including separators |
| `categoryId` | `27` Education, `10` Music, `28` Science & Technology. Run `publish.py categories` for the authoritative list for your region |
| `privacyStatus` | `private` (default), `unlisted`, `public` |
| `publishAt` | RFC3339, e.g. `2026-09-10T15:00:00Z`. **Requires `private`** — this is how you schedule |
| `containsSyntheticMedia` | YouTube's altered/synthetic disclosure. See below |
| `thumbnail` | ≤ 2 MB, `.png`/`.jpg` |
| `playlist` | Resolved **by title**, and created if missing — you never copy an id |

### On `containsSyntheticMedia`

The flag exists for *realistic* altered or synthetic content: a real person
appearing to say something they didn't, a fabricated real event, a
realistic-looking scene that never happened. A synthetic narrator speaking over
screen recordings of real software is arguably outside that, which is why the
sidecars ship `false` and the end card discloses the synthetic voice in words
instead.

**It is your channel and your call.** Flip it to `true` and the script sets it.

---

## Publishing

```bash
V=.venv/bin/python
FILM="$HOME/Movies/DAW Pro Lesson 3 - Muddy Mix.mp4"
META="$HOME/Movies/DAW Pro Lesson 3 - Muddy Mix.publish.json"

# 1. offline checks — no network, no credentials, nothing uploaded
$V scripts/publish.py validate --film "$FILM" --meta "$META"

# 2. see the exact request body, still touching nothing
$V scripts/publish.py upload --film "$FILM" --meta "$META" --dry-run

# 3. for real
$V scripts/publish.py upload --film "$FILM" --meta "$META"
```

Step 3 uploads resumably in 8 MB chunks, sets the thumbnail, files it in the
playlist, then verifies.

### What `verify` actually checks

It polls until YouTube reports the video processed — `contentDetails.duration`
is simply **absent** for the first while, so a single read would compare against
nothing and pass. Then it asserts:

- title matches what was sent
- `privacyStatus` matches, and if you asked for `public` and got `private`, it
  says so **as the unaudited-project lock**, with what to do about it
- duration matches your local file within 2 s (via `ffprobe`)
- `containsSyntheticMedia` matches

Exit code `0` verified, `1` a real mismatch.

```bash
# re-check something uploaded earlier
$V scripts/publish.py verify --video-id dQw4w9WgXcQ --meta "$META" --film "$FILM"
```

### Helpers

```bash
$V scripts/publish.py categories --region US   # valid category ids
$V scripts/publish.py playlists                # your playlists and their ids
```

---

## What is and isn't proven

**Tested without credentials:** every offline validation rule, each with a
negative control — over-long title, blank title, angle brackets, over-long
description, over-long tag set, non-numeric category, bad privacy value,
malformed and misconfigured `publishAt`, missing thumbnail, non-boolean flags.
Eleven fail with exit 1; three (unknown category, `public`, unknown key) warn
deliberately and pass. The dry run prints the exact request body.

**Not tested, and cannot be until you authorise:** the upload, thumbnail,
playlist and verify network paths. Nobody has run them. Do your first real
upload on something you don't mind re-doing.

## Quota

The default is 10,000 units/day and an upload is the expensive call, but the
ceiling is far above a few videos a week. If you ever see `quotaExceeded`, it
resets at midnight Pacific.

## Uploading a whole batch

`publish.py` takes one film at a time on purpose. For a finished wave, use the
wrapper rather than writing the loop yourself:

```sh
./scripts/upload-batch.sh "DAW Pro Short"            # everything matching, in order
./scripts/upload-batch.sh --dry-run "DAW Pro Lesson" # no network; prints each request body
```

The match is a substring of the FILE NAME, and each film's metadata comes from
the `.publish.json` sidecar beside it — you never name a meta file.

What it does that a hand-written loop does not:

- **Refuses to upload the same film twice.** Every success is appended to
  `~/Movies/.uploaded.tsv`; a filename already in that ledger is skipped.
  YouTube will happily accept the same video ten times, and there is no undo
  from here. `--redo` overrides it deliberately.
- **Validates every sidecar offline before the first upload**, so a bad one is
  found now rather than after eleven videos have gone out.
- **Prints the plan and asks**, because a substring match can sweep up
  neighbouring files: `"DAW Pro Lesson"` matches an older wave's lessons too.
  Read the list before answering. `--yes` skips the prompt.
- **Stops at the first failure** and says how many were uploaded and how many
  were never attempted.
- Sorts `Short 10` after `Short 2`, so the plan reads the way you'd say it.
