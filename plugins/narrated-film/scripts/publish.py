#!/usr/bin/env python3
"""Publish a finished film to YouTube, and verify it arrived intact.

Design rules, each of which came from a defect in this pipeline:

  * DEFAULT TO PRIVATE. Publishing is irreversible in the way that matters —
    people see it. `public` requires an explicit privacyStatus in the metadata
    AND an audited API project (see below).
  * A SETTER'S RETURN IS NOT PROOF IT TOOK. After the upload we read the video
    back and compare title, privacy and duration against what we sent.
  * EVERYTHING CHECKABLE OFFLINE IS CHECKED OFFLINE. `validate` needs no
    credentials and no network, so the metadata is provably right before any
    irreversible call.

⚠️ Uploads from an API project that has not passed YouTube's compliance audit
are FORCED TO PRIVATE, whatever you ask for. That is a YouTube policy, not a
bug in this script, and `verify` names it explicitly when it sees it.

Usage:
  publish.py auth      [--client-secret F] [--token F]
  publish.py validate  --film F --meta publish.json
  publish.py upload    --film F --meta publish.json [--dry-run]
  publish.py verify    --video-id ID [--meta publish.json] [--film F]
  publish.py categories [--region US]
  publish.py playlists
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time

SCOPES = ["https://www.googleapis.com/auth/youtube"]
# Verified 2026-09-03 against the per-method Authorization tables:
#   videos.insert        accepts youtube.upload | youtube | youtubepartner | youtube.force-ssl
#   thumbnails.set       accepts youtube.upload | youtube | youtubepartner | youtube.force-ssl
#   playlistItems.insert accepts             youtube | youtubepartner | youtube.force-ssl
# `youtube` is the only ONE scope all three accept — youtube.upload alone
# cannot add the video to a playlist.

MAX_TITLE = 100
MAX_DESC = 5000
MAX_TAGS_TOTAL = 500
MAX_THUMB_BYTES = 2 * 1024 * 1024
THUMB_TYPES = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg"}
PRIVACY = {"private", "unlisted", "public"}

# Well-known category IDs. This map is a CONVENIENCE, not an authority: run
# `publish.py categories` to list what your region actually accepts. validate()
# only WARNS on an id outside this map, so a correct-but-unlisted id can still
# be uploaded.
KNOWN_CATEGORIES = {
    "1": "Film & Animation", "2": "Autos & Vehicles", "10": "Music",
    "15": "Pets & Animals", "17": "Sports", "19": "Travel & Events",
    "20": "Gaming", "22": "People & Blogs", "23": "Comedy",
    "24": "Entertainment", "25": "News & Politics", "26": "Howto & Style",
    "27": "Education", "28": "Science & Technology",
}

DEFAULTS = {
    "title": None,
    "description": "",
    "tags": [],
    "categoryId": "27",
    "defaultLanguage": "en",
    "privacyStatus": "private",
    # The safe default for THIS kit is True: it exists to make narrated films,
    # and the narration is synthetic. A meta file that omits the key should
    # over-disclose, not under-disclose.
    "containsSyntheticMedia": True,
    "madeForKids": False,
    "publishAt": None,
    "thumbnail": None,
    "playlist": None,
}


# ---------------------------------------------------------------- helpers


def die(msg):
    print(f"✘ {msg}", file=sys.stderr)
    sys.exit(1)


def load_meta(path):
    if not os.path.exists(path):
        die(f"metadata file not found: {path}")
    with open(path) as fh:
        try:
            raw = json.load(fh)
        except json.JSONDecodeError as e:
            die(f"{path} is not valid JSON: {e}")
    unknown = set(raw) - set(DEFAULTS)
    meta = dict(DEFAULTS)
    meta.update(raw)
    meta["_unknown"] = sorted(unknown)
    meta["_dir"] = os.path.dirname(os.path.abspath(path))
    return meta


def resolve(meta, key):
    """Resolve a path in the metadata relative to the metadata file."""
    v = meta.get(key)
    if not v:
        return None
    return v if os.path.isabs(v) else os.path.join(meta["_dir"], v)


def ffprobe_duration(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=nw=1:nk=1", path],
        capture_output=True, text=True)
    try:
        return float(out.stdout.strip())
    except ValueError:
        return None


def iso8601_seconds(s):
    """PT1M12S -> 72.0 . Returns None if unparseable."""
    m = re.fullmatch(r"P(?:(\d+)D)?T(?:(\d+)H)?(?:(\d+)M)?(?:([\d.]+)S)?", s or "")
    if not m:
        return None
    d, h, mi, sec = (float(x) if x else 0.0 for x in m.groups())
    return d * 86400 + h * 3600 + mi * 60 + sec


# ---------------------------------------------------------------- validate


def validate(film, meta, quiet=False):
    """Every check that can run without credentials or network. Returns
    a list of (level, message); level is 'FAIL' or 'WARN'."""
    p = []

    if film:
        if not os.path.exists(film):
            p.append(("FAIL", f"film not found: {film}"))
        elif os.path.getsize(film) == 0:
            p.append(("FAIL", f"film is empty: {film}"))
        else:
            dur = ffprobe_duration(film)
            if dur is None:
                p.append(("FAIL", f"ffprobe could not read a duration from {film}"))
            elif dur > 60.0 and "#shorts" in (meta.get("description", "") + str(meta.get("title", ""))).lower():
                p.append(("WARN", f"tagged #Shorts but {dur:.1f}s long — Shorts must be 60s or under"))

    for k in meta.get("_unknown", []):
        p.append(("WARN", f"unknown key in metadata, ignored: {k!r}"))

    title = meta.get("title")
    if not title or not str(title).strip():
        p.append(("FAIL", "title is required and cannot be blank"))
    else:
        if len(title) > MAX_TITLE:
            p.append(("FAIL", f"title is {len(title)} chars, limit {MAX_TITLE}"))
        if "<" in title or ">" in title:
            p.append(("FAIL", "title contains < or >, which YouTube rejects"))

    desc = meta.get("description") or ""
    if len(desc) > MAX_DESC:
        p.append(("FAIL", f"description is {len(desc)} chars, limit {MAX_DESC}"))
    if "<" in desc or ">" in desc:
        p.append(("FAIL", "description contains < or >, which YouTube rejects"))

    tags = meta.get("tags") or []
    if not isinstance(tags, list):
        p.append(("FAIL", "tags must be a list of strings"))
    else:
        total = sum(len(t) + 1 for t in tags)
        if total > MAX_TAGS_TOTAL:
            p.append(("FAIL", f"tags total {total} chars, limit {MAX_TAGS_TOTAL}"))

    cat = str(meta.get("categoryId") or "")
    if not cat.isdigit():
        p.append(("FAIL", f"categoryId must be numeric, got {cat!r}"))
    elif cat not in KNOWN_CATEGORIES:
        p.append(("WARN", f"categoryId {cat} is not in this script's known list — "
                          f"run `publish.py categories` to confirm it is valid"))

    priv = meta.get("privacyStatus")
    if priv not in PRIVACY:
        p.append(("FAIL", f"privacyStatus must be one of {sorted(PRIVACY)}, got {priv!r}"))
    if priv == "public":
        p.append(("WARN", "privacyStatus is 'public' — this publishes immediately to "
                          "anyone, and an unaudited API project will force it back to private"))

    at = meta.get("publishAt")
    if at:
        if priv != "private":
            p.append(("FAIL", "publishAt requires privacyStatus 'private'"))
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})", at):
            p.append(("FAIL", f"publishAt must be RFC3339, e.g. 2026-09-10T15:00:00Z — got {at!r}"))

    thumb = resolve(meta, "thumbnail")
    if thumb:
        if not os.path.exists(thumb):
            p.append(("FAIL", f"thumbnail not found: {thumb}"))
        else:
            ext = os.path.splitext(thumb)[1].lower()
            if ext not in THUMB_TYPES:
                p.append(("FAIL", f"thumbnail must be .png/.jpg, got {ext}"))
            n = os.path.getsize(thumb)
            if n > MAX_THUMB_BYTES:
                p.append(("FAIL", f"thumbnail is {n/1e6:.2f} MB, limit 2 MB"))

    if not isinstance(meta.get("containsSyntheticMedia"), bool):
        p.append(("FAIL", "containsSyntheticMedia must be true or false"))
    if not isinstance(meta.get("madeForKids"), bool):
        p.append(("FAIL", "madeForKids must be true or false"))

    if not quiet:
        for level, msg in p:
            print(f"  {'✘' if level == 'FAIL' else '⚠'} {level}: {msg}")
        if not p:
            print("  ✔ metadata valid (offline checks)")
    return p


def body_from(meta):
    body = {
        "snippet": {
            "title": meta["title"],
            "description": meta["description"],
            "tags": meta["tags"],
            "categoryId": str(meta["categoryId"]),
        },
        "status": {
            "privacyStatus": meta["privacyStatus"],
            "selfDeclaredMadeForKids": meta["madeForKids"],
            "containsSyntheticMedia": meta["containsSyntheticMedia"],
        },
    }
    if meta.get("defaultLanguage"):
        body["snippet"]["defaultLanguage"] = meta["defaultLanguage"]
    if meta.get("publishAt"):
        body["status"]["publishAt"] = meta["publishAt"]
    return body


# ---------------------------------------------------------------- auth


def _google():
    try:
        from google.auth.transport.requests import Request
        from google.oauth2.credentials import Credentials
        from google_auth_oauthlib.flow import InstalledAppFlow
        from googleapiclient.discovery import build
        from googleapiclient.errors import HttpError
        from googleapiclient.http import MediaFileUpload
    except ImportError:
        die("the Google client libraries are not installed. Run:\n"
            "    ./install.sh --publish\n"
            "  or, into whichever interpreter you are using:\n"
            "    pip install google-api-python-client google-auth-oauthlib")
    return Request, Credentials, InstalledAppFlow, build, HttpError, MediaFileUpload


def credentials(client_secret, token_path, interactive):
    Request, Credentials, InstalledAppFlow, _, _, _ = _google()
    creds = None
    if os.path.exists(token_path):
        creds = Credentials.from_authorized_user_file(token_path, SCOPES)
    if creds and creds.valid:
        return creds
    if creds and creds.expired and creds.refresh_token:
        creds.refresh(Request())
    elif interactive:
        if not os.path.exists(client_secret):
            die(f"OAuth client secret not found: {client_secret}\n"
                "  Create one in Google Cloud Console: APIs & Services > Credentials >\n"
                "  Create credentials > OAuth client ID > Desktop app, then download the JSON.")
        creds = InstalledAppFlow.from_client_secrets_file(client_secret, SCOPES).run_local_server(port=0)
    else:
        die(f"no usable token at {token_path} — run `publish.py auth` first")
    with open(token_path, "w") as fh:
        fh.write(creds.to_json())
    os.chmod(token_path, 0o600)
    return creds


def service(args, interactive=False):
    _, _, _, build, _, _ = _google()
    return build("youtube", "v3", credentials=credentials(
        args.client_secret, args.token, interactive), cache_discovery=False)


# ---------------------------------------------------------------- upload


def find_or_create_playlist(yt, title):
    """Resolve a playlist BY TITLE so nobody has to copy an id by hand."""
    req = yt.playlists().list(part="snippet", mine=True, maxResults=50)
    while req is not None:
        res = req.execute()
        for item in res.get("items", []):
            if item["snippet"]["title"].strip().lower() == title.strip().lower():
                print(f"  playlist: found {title!r} ({item['id']})")
                return item["id"]
        req = yt.playlists().list_next(req, res)
    res = yt.playlists().insert(
        part="snippet,status",
        body={"snippet": {"title": title},
              "status": {"privacyStatus": "public"}}).execute()
    print(f"  playlist: created {title!r} ({res['id']})")
    return res["id"]


def upload(args):
    meta = load_meta(args.meta)
    film = args.film
    print(f"validating {os.path.basename(args.meta)} …")
    problems = validate(film, meta)
    if any(l == "FAIL" for l, _ in problems):
        die("metadata did not validate — nothing was uploaded")

    body = body_from(meta)
    thumb = resolve(meta, "thumbnail")

    if args.dry_run:
        print("\n--- DRY RUN: this is the exact videos.insert body ---")
        print(json.dumps(body, indent=2, ensure_ascii=False))
        print(f"\nmedia file : {film} ({os.path.getsize(film)/1e6:.1f} MB)")
        print(f"thumbnail  : {thumb or '(none)'}")
        print(f"playlist   : {meta.get('playlist') or '(none)'}")
        print(f"scopes     : {SCOPES}")
        print("\nNo network call was made. Nothing was uploaded.")
        return 0

    _, _, _, _, HttpError, MediaFileUpload = _google()
    yt = service(args)

    media = MediaFileUpload(film, chunksize=8 * 1024 * 1024, resumable=True,
                            mimetype="video/*")
    req = yt.videos().insert(part="snippet,status", body=body, media_body=media)
    print(f"uploading {os.path.basename(film)} …")
    response, last = None, -1
    while response is None:
        try:
            status, response = req.next_chunk()
        except HttpError as e:
            die(f"upload failed: {e}")
        if status:
            pct = int(status.progress() * 100)
            if pct >= last + 10:
                print(f"  {pct}%")
                last = pct
    vid = response["id"]
    print(f"✔ uploaded: https://youtu.be/{vid}")

    if thumb:
        try:
            yt.thumbnails().set(videoId=vid, media_body=thumb).execute()
            print(f"  thumbnail: set from {os.path.basename(thumb)}")
        except HttpError as e:
            print(f"  ⚠ thumbnail NOT set: {e}\n"
                  "    Custom thumbnails require a phone-verified YouTube account.")

    if meta.get("playlist"):
        try:
            pid = find_or_create_playlist(yt, meta["playlist"])
            yt.playlistItems().insert(
                part="snippet",
                body={"snippet": {"playlistId": pid,
                                  "resourceId": {"kind": "youtube#video",
                                                 "videoId": vid}}}).execute()
            print("  playlist: added")
        except HttpError as e:
            print(f"  ⚠ playlist step failed: {e}")

    print()
    return verify_video(yt, vid, meta, film, args.timeout)


# ---------------------------------------------------------------- verify


def verify_video(yt, vid, meta, film, timeout):
    """Read the video back and compare it with what we sent. YouTube processes
    asynchronously, so contentDetails.duration is absent at first — poll."""
    print(f"verifying {vid} (polling up to {timeout}s for processing) …")
    deadline = time.time() + timeout
    v = None
    while True:
        res = yt.videos().list(part="snippet,status,contentDetails,processingDetails",
                               id=vid).execute()
        items = res.get("items", [])
        if not items:
            die(f"video {vid} was not readable back — upload did not land")
        v = items[0]
        state = v.get("processingDetails", {}).get("processingStatus")
        if v.get("status", {}).get("uploadStatus") == "processed" or state == "succeeded":
            break
        if time.time() > deadline:
            print(f"  ⚠ still processing after {timeout}s — checks below may be partial")
            break
        time.sleep(5)

    fails = []
    got_title = v["snippet"]["title"]
    if meta and got_title != meta["title"]:
        fails.append(f"title mismatch:\n      sent {meta['title']!r}\n      got  {got_title!r}")
    else:
        print(f"  ✔ title: {got_title!r}")

    got_priv = v["status"]["privacyStatus"]
    want_priv = meta["privacyStatus"] if meta else None
    if want_priv and got_priv != want_priv:
        if want_priv == "public" and got_priv == "private":
            fails.append(
                "privacy: asked for 'public', YouTube stored 'private'.\n"
                "      This is the UNAUDITED API PROJECT LOCK, not a script bug:\n"
                "      uploads from projects created after 2020-07-28 are forced to\n"
                "      private until the project passes YouTube's compliance audit.\n"
                "      Flip it to public in YouTube Studio, or complete the audit.")
        else:
            fails.append(f"privacy mismatch: sent {want_priv!r}, got {got_priv!r}")
    else:
        print(f"  ✔ privacy: {got_priv}")

    iso = v.get("contentDetails", {}).get("duration")
    remote = iso8601_seconds(iso)
    if film and remote is not None:
        local = ffprobe_duration(film)
        if local and abs(local - remote) > 2.0:
            fails.append(f"duration mismatch: local {local:.1f}s, YouTube {remote:.1f}s")
        else:
            print(f"  ✔ duration: {remote:.0f}s (local {local:.0f}s)")
    elif remote is None:
        print("  ⚠ duration not reported yet (still processing) — check later")

    syn = v["status"].get("containsSyntheticMedia")
    if meta and syn is not None and syn != meta["containsSyntheticMedia"]:
        fails.append(f"containsSyntheticMedia: sent {meta['containsSyntheticMedia']}, got {syn}")

    print()
    if fails:
        for f in fails:
            print(f"  ✘ {f}")
        print(f"\n✘ VERIFY FAILED for https://youtu.be/{vid}")
        return 1
    print(f"✔ verified: https://youtu.be/{vid}")
    return 0


# ---------------------------------------------------------------- main


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--client-secret", default=os.environ.get(
        "YT_CLIENT_SECRET", "client_secret.json"))
    ap.add_argument("--token", default=os.environ.get("YT_TOKEN", "youtube-token.json"))
    ap.add_argument("--timeout", type=int, default=180,
                    help="seconds to wait for YouTube to finish processing (verify)")

    # ⚠ These three are GLOBAL, but nobody types them in the global position.
    # `publish.py auth --client-secret X` is the obvious spelling and it used to
    # die with "unrecognized arguments" -- an error that names the flag it just
    # documented one line above, which reads like the flag is wrong rather than
    # merely misplaced. Accepting them AFTER the subcommand too costs one
    # parent parser. argparse.SUPPRESS is what makes it safe: without it the
    # subparser would write its own default over whatever the global position
    # (or the environment variable) had already set.
    common = argparse.ArgumentParser(add_help=False)
    for flag, kw in (("--client-secret", {}), ("--token", {}), ("--timeout", {"type": int})):
        common.add_argument(flag, default=argparse.SUPPRESS, **kw)

    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("auth", parents=[common],
                   help="one-time browser consent; writes the token file")

    v = sub.add_parser("validate", parents=[common],
                       help="offline metadata checks; no network, no credentials")
    v.add_argument("--film")
    v.add_argument("--meta", required=True)

    u = sub.add_parser("upload", parents=[common], help="upload, set thumbnail, add to playlist, verify")
    u.add_argument("--film", required=True)
    u.add_argument("--meta", required=True)
    u.add_argument("--dry-run", action="store_true",
                   help="validate and print the exact request body; touch no network")

    w = sub.add_parser("verify", parents=[common], help="re-check a video that is already uploaded")
    w.add_argument("--video-id", required=True)
    w.add_argument("--meta")
    w.add_argument("--film")

    c = sub.add_parser("categories", parents=[common], help="list valid category ids for a region")
    c.add_argument("--region", default="US")

    sub.add_parser("playlists", parents=[common], help="list your playlists and their ids")

    a = ap.parse_args()

    if a.cmd == "auth":
        credentials(a.client_secret, a.token, interactive=True)
        print(f"✔ token written to {a.token} (mode 600)")
        print("  Keep it out of git — it grants write access to your channel.")
        return 0

    if a.cmd == "validate":
        problems = validate(a.film, load_meta(a.meta))
        return 1 if any(l == "FAIL" for l, _ in problems) else 0

    if a.cmd == "upload":
        return upload(a)

    if a.cmd == "verify":
        yt = service(a)
        meta = load_meta(a.meta) if a.meta else None
        return verify_video(yt, a.video_id, meta, a.film, a.timeout)

    if a.cmd == "categories":
        yt = service(a)
        res = yt.videoCategories().list(part="snippet", regionCode=a.region).execute()
        for it in sorted(res["items"], key=lambda x: int(x["id"])):
            if it["snippet"].get("assignable"):
                print(f"  {it['id']:>3}  {it['snippet']['title']}")
        return 0

    if a.cmd == "playlists":
        yt = service(a)
        req = yt.playlists().list(part="snippet,contentDetails", mine=True, maxResults=50)
        while req is not None:
            res = req.execute()
            for it in res.get("items", []):
                print(f"  {it['id']}  {it['contentDetails']['itemCount']:>3} videos  "
                      f"{it['snippet']['title']}")
            req = yt.playlists().list_next(req, res)
        return 0


if __name__ == "__main__":
    sys.exit(main())
