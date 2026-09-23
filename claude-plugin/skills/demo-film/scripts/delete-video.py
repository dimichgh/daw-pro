#!/usr/bin/env python3
"""Permanently delete videos from the channel.

    python3 delete-video.py --token T --client-secret C ID [ID ...]          # shows what would go
    python3 delete-video.py --token T --client-secret C ID [ID ...] --confirm  # actually deletes

⛔⛔ THIS IS THE ONLY IRREVERSIBLE THING IN THIS PIPELINE. Everything else here
can be re-rendered, re-uploaded or patched. A deleted video is gone for everyone,
the link dies, and no amount of re-uploading brings back the same id.

So the guards are not decoration:
  - It NEVER deletes without --confirm. The default is a dry run.
  - It READS EACH VIDEO BACK FIRST and prints the title, privacy and upload date
    it is about to destroy. A mistyped id would otherwise delete a stranger's
    work — or rather, the user's OTHER work — and the API would report success.
  - It REFUSES any id it cannot read back, rather than treating "not found" as
    "already gone, nothing to do". Those are different facts.
  - It refuses to delete anything PUBLIC unless --allow-public is also given.
    A private draft is a work in progress; a public video may have links to it.

⭐ A DELETE IS A USER DECISION EVERY TIME. Not a cleanup step, not an implied
consequence of uploading a replacement. If the person did not name these videos,
do not run this.
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from publish import credentials, _google  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ids", nargs="+")
    ap.add_argument("--token", default=os.environ.get("YT_TOKEN", "youtube-token.json"))
    ap.add_argument("--client-secret", default=os.environ.get("YT_CLIENT_SECRET", "client_secret.json"))
    ap.add_argument("--confirm", action="store_true",
                    help="actually delete; without it this only reports")
    ap.add_argument("--allow-public", action="store_true")
    args = ap.parse_args()

    _, _, _, build, HttpError, _ = _google()
    yt = build("youtube", "v3", credentials=credentials(
        args.client_secret, args.token, False), cache_discovery=False)

    got = {}
    for i in range(0, len(args.ids), 50):
        res = yt.videos().list(part="snippet,status",
                               id=",".join(args.ids[i:i + 50])).execute()
        for it in res.get("items", []):
            got[it["id"]] = it

    missing = [v for v in args.ids if v not in got]
    if missing:
        sys.exit(f"⛔ cannot read back, refusing to delete anything: {missing}\n"
                 "   (a video you cannot see is not the same as one already deleted)")

    public = [v for v in args.ids if got[v]["status"]["privacyStatus"] == "public"]
    if public and not args.allow_public:
        sys.exit(f"⛔ these are PUBLIC and --allow-public was not given: {public}")

    print(f"{'WOULD DELETE' if not args.confirm else 'DELETING'} {len(args.ids)} video(s):")
    for v in args.ids:
        s = got[v]["snippet"]
        print(f"  {v}  [{got[v]['status']['privacyStatus']}]  {s['publishedAt'][:10]}")
        print(f"      {s['title']}")

    if not args.confirm:
        print("\nDry run — nothing deleted. Re-run with --confirm.")
        return

    done = 0
    for v in args.ids:
        try:
            yt.videos().delete(id=v).execute()
        except HttpError as e:
            sys.exit(f"⛔ {v}: {e}  ({done} already deleted before this)")
        done += 1
        print(f"  deleted {v}")
    # ⭐ ASSERT THE COUNT — a loop that quietly does fewer than it was given exits
    # 0 and looks identical to one that did them all.
    if done != len(args.ids):
        sys.exit(f"⛔ deleted {done} of {len(args.ids)}")
    print(f"\n═══ deleted {done} of {len(args.ids)} ═══")


if __name__ == "__main__":
    main()
