#!/usr/bin/env python3
"""Upload a finished film to YouTube as a PRIVATE draft.

⛔ VISIBILITY IS THE USER'S ACTION. This tool only ever creates private
drafts; it refuses any other privacyStatus. Publishing, scheduling and
unlisting happen in YouTube Studio, by hand, by the account owner.

Usage:
    python3 yt_upload.py <video.mp4> <publish.json> [--client SECRET.json]

`publish.json` is the metadata block already produced beside each film
(title, description, tags, categoryId, madeForKids, containsSyntheticMedia).

First run opens a browser for one-time consent and writes `token.json`
next to the client secret. Later runs are non-interactive.
"""
import argparse, json, os, sys

SCOPES = ["https://www.googleapis.com/auth/youtube.upload"]
HERE = os.path.dirname(os.path.abspath(__file__))


def die(msg, code=2):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(code)


def load_meta(path):
    with open(path) as fh:
        meta = json.load(fh)
    for key in ("title", "description"):
        if not meta.get(key):
            die(f"{path}: missing required field {key!r}")
    # The refusal that makes this tool safe to hand to an agent.
    privacy = meta.get("privacyStatus", "private")
    if privacy != "private":
        die(f"{path}: privacyStatus is {privacy!r}. This tool uploads "
            f"PRIVATE DRAFTS ONLY — change visibility in YouTube Studio.")
    if len(meta["title"]) > 100:
        die(f"title is {len(meta['title'])} chars; YouTube's limit is 100")
    if len(meta["description"]) > 5000:
        die(f"description is {len(meta['description'])} chars; limit is 5000")
    return meta


def build_service(client_secret):
    try:
        from google.auth.transport.requests import Request
        from google.oauth2.credentials import Credentials
        from google_auth_oauthlib.flow import InstalledAppFlow
        from googleapiclient.discovery import build
    except ImportError:
        die("missing deps. Install with:\n"
            "  python3 -m pip install --user google-api-python-client "
            "google-auth-oauthlib google-auth-httplib2")
    token_path = os.path.join(os.path.dirname(client_secret), "token.json")
    creds = None
    if os.path.exists(token_path):
        creds = Credentials.from_authorized_user_file(token_path, SCOPES)
    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
        else:
            flow = InstalledAppFlow.from_client_secrets_file(client_secret, SCOPES)
            creds = flow.run_local_server(port=0)
        with open(token_path, "w") as fh:
            fh.write(creds.to_json())
        os.chmod(token_path, 0o600)
    return build("youtube", "v3", credentials=creds)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video")
    ap.add_argument("meta")
    ap.add_argument("--client", default=os.path.join(HERE, "client_secret.json"))
    args = ap.parse_args()

    if not os.path.exists(args.video):
        die(f"no such video: {args.video}")
    if not os.path.exists(args.client):
        die(f"no OAuth client secret at {args.client}\n"
            "See README.md in this directory for the one-time setup.")
    meta = load_meta(args.meta)
    size_mb = os.path.getsize(args.video) / 1024 / 1024

    from googleapiclient.http import MediaFileUpload
    yt = build_service(args.client)

    body = {
        "snippet": {
            "title": meta["title"],
            "description": meta["description"],
            "tags": meta.get("tags", []),
            "categoryId": str(meta.get("categoryId", "10")),
        },
        "status": {
            "privacyStatus": "private",
            "selfDeclaredMadeForKids": bool(meta.get("madeForKids", False)),
            "containsSyntheticMedia": bool(meta.get("containsSyntheticMedia", False)),
        },
    }
    print(f"uploading {args.video} ({size_mb:.1f} MiB) as a PRIVATE draft…")
    media = MediaFileUpload(args.video, chunksize=8 * 1024 * 1024, resumable=True)
    req = yt.videos().insert(part="snippet,status", body=body, media_body=media)
    resp = None
    while resp is None:
        status, resp = req.next_chunk()
        if status:
            print(f"  {int(status.progress() * 100):3d}%", flush=True)
    vid = resp["id"]
    print(f"\ndone — PRIVATE draft: https://studio.youtube.com/video/{vid}/edit")
    print("Set visibility yourself in Studio when you're ready.")


if __name__ == "__main__":
    main()
