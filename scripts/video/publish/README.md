# Uploading a film to YouTube

`yt_upload.py` creates **private drafts only**. It refuses any other
`privacyStatus` in the metadata file. Visibility — public, unlisted,
scheduled — is set by hand in YouTube Studio, by the account owner.

## One-time setup (yours, not the agent's)

The agent cannot do these steps: they need your Google account.

1. **Google Cloud console** → create a project (or reuse one).
2. **APIs & Services → Library** → enable **YouTube Data API v3**.
3. **APIs & Services → OAuth consent screen** → External, add your own
   Google account as a **Test user**.
4. **Credentials → Create credentials → OAuth client ID → Desktop app.**
   Download the JSON and save it here as `client_secret.json`.

Then install the client libraries once:

    python3 -m pip install --user google-api-python-client \
        google-auth-oauthlib google-auth-httplib2

## Uploading

    python3 scripts/video/publish/yt_upload.py \
        scripts/video/shorts/roads/03-moonlight-long/out/moonlight-long.mp4 \
        scripts/video/shorts/roads/03-moonlight-long/publish.json

First run opens a browser once for consent and writes `token.json`
(mode 600) beside the client secret. Later runs are non-interactive.

## ⚠ Two things to know before relying on this

- **An unverified OAuth project's API uploads are locked to private.**
  Google restricts uploads from clients that have not been through its
  API audit; the video lands but cannot be made public from the API, and
  may not be publishable from Studio either until the project is
  verified. Verify this against your own account with ONE test upload
  before committing a batch to it. Dragging the file into Studio has no
  such restriction and is the reliable path for anything you intend to
  publish.
- **Quota.** A video insert costs ~1600 units against a default daily
  quota of 10,000 — roughly six uploads a day.

## Files

    client_secret.json   your OAuth client (NOT committed — see .gitignore)
    token.json           your refresh token, mode 600 (NOT committed)
