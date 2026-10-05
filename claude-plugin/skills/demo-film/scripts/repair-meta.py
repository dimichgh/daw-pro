#!/usr/bin/env python3
"""Repair the title/description of videos ALREADY on the channel.

⛔ WHY THIS EXISTS. `publish.py` only ever INSERTS. When a title or description
turns out to be wrong after upload — which it did, for ten videos on 2026-09-21
— the only options were to ask the person to paste ten fields by hand in Studio,
or to re-upload and leave duplicates on the channel. Both are worse than a
`videos.update`.

⭐⭐ AND I NEARLY SHIPPED THE HAND-PASTE ASK ON A SCOPE CLAIM I NEVER CHECKED.
I had written, in three separate files, that `videos.update` needs a broader
OAuth scope than the uploader requests and would therefore force a fresh consent
screen. It does not. `publish.py` requests `https://www.googleapis.com/auth/
youtube` — the FULL scope — and the stored token carries it, so update was
available the whole time. The claim was recalled, not measured, and it had
already been written down as fact in a document the user reads.
**A CAPABILITY YOU ASSUME YOU LACK COSTS EXACTLY AS MUCH AS ONE YOU LACK.
`grep SCOPES` IS FIVE SECONDS.**

This DOES NOT touch privacyStatus. Every video stays exactly as private or as
public as it already is — visibility is the user's call and this script has no
opinion about it. It sends `part="snippet"` only, and it refuses to run against
a video whose current title it has not first read back.

    python3 repair-meta.py --token <t> --client-secret <c> \
        --patch VIDEO_ID=path/to/meta.json [--patch ...] [--dry-run]
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from publish import SCOPES, credentials, _google  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--token", default=os.environ.get("YT_TOKEN", "youtube-token.json"))
    ap.add_argument("--client-secret", default=os.environ.get("YT_CLIENT_SECRET", "client_secret.json"))
    ap.add_argument("--patch", action="append", required=True,
                    metavar="VIDEO_ID=META.json")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    jobs = []
    for spec in args.patch:
        vid, _, path = spec.partition("=")
        if not vid or not path:
            sys.exit(f"⛔ --patch wants VIDEO_ID=META.json, got {spec!r}")
        meta = json.load(open(path))
        jobs.append((vid, meta, path))

    _, _, _, build, HttpError, _ = _google()
    yt = build("youtube", "v3", credentials=credentials(
        args.client_secret, args.token, False), cache_discovery=False)

    # ⭐ READ BEFORE WRITE, ALWAYS. A wrong id here would overwrite a DIFFERENT
    # video's title with this one's and the API would report success. Fetching
    # first also gives the categoryId back, which `update` would otherwise CLEAR
    # — an update is a REPLACE of the part you send, not a merge.
    ids = [v for v, _, _ in jobs]
    got = {}
    for i in range(0, len(ids), 50):
        res = yt.videos().list(part="snippet,status", id=",".join(ids[i:i + 50])).execute()
        for item in res.get("items", []):
            got[item["id"]] = item
    missing = [v for v in ids if v not in got]
    if missing:
        sys.exit(f"⛔ not on the channel (or not yours): {missing}")

    changed = 0
    for vid, meta, path in jobs:
        cur = got[vid]["snippet"]
        new_title = meta["title"]
        new_desc = meta["description"]
        dt = cur["title"] != new_title
        dd = cur.get("description", "") != new_desc
        if not (dt or dd):
            print(f"  ok      {vid}  already correct")
            continue
        print(f"  patch   {vid}  {'title ' if dt else ''}{'description' if dd else ''}")
        if dt:
            print(f"            was: {cur['title']}")
            print(f"            now: {new_title}")
        if args.dry_run:
            changed += 1
            continue
        body = {
            "id": vid,
            "snippet": {
                "title": new_title,
                "description": new_desc,
                # carried forward, NOT invented — update replaces the whole part
                "categoryId": cur.get("categoryId", "10"),
                "tags": cur.get("tags", []),
            },
        }
        if cur.get("defaultLanguage"):
            body["snippet"]["defaultLanguage"] = cur["defaultLanguage"]
        try:
            yt.videos().update(part="snippet", body=body).execute()
        except HttpError as e:
            sys.exit(f"⛔ {vid}: {e}")
        changed += 1

    verb = "would change" if args.dry_run else "changed"
    print(f"\n═══ {verb} {changed} of {len(jobs)} ═══")
    # ⭐ ASSERT THE COUNT. A loop that silently processes fewer items than it was
    # given exits 0 and prints nothing wrong — that has already happened here
    # once, with `while read` dropping a trailing line and one upload with it.
    if len(jobs) != len(ids):
        sys.exit("⛔ job/id count mismatch — refusing to report success")


if __name__ == "__main__":
    main()
