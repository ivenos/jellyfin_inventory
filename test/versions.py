#!/usr/bin/env python3
"""Lists the Jellyfin releases to test against: every major.minor from the targetAbi on."""

import argparse
import json
import pathlib
import re
import time
import urllib.error
import urllib.request

REGISTRY = "https://registry-1.docker.io"
REPOSITORY = "jellyfin/jellyfin"

parser = argparse.ArgumentParser()
parser.add_argument("--root", default=pathlib.Path(__file__).resolve().parent.parent)
parser.add_argument("--json", action="store_true", help="as one array, for the workflow matrix")
args = parser.parse_args()

abi = re.search(r'^targetAbi:\s*"(\d+)\.(\d+)',
                (pathlib.Path(args.root) / "build.yaml").read_text(encoding="utf-8"), re.M)
if not abi:
    raise SystemExit("build.yaml carries no quoted targetAbi")
floor = (int(abi.group(1)), int(abi.group(2)))


def get(url, headers=None):
    request = urllib.request.Request(url, headers=headers or {})
    # A hiccup at the registry would otherwise turn every open pull request red.
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=60) as answer:
                return json.load(answer), answer.headers
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
            if attempt == 2:
                raise
            time.sleep(5 * (attempt + 1))


token, _ = get(f"https://auth.docker.io/token?service=registry.docker.io&scope=repository:{REPOSITORY}:pull")
tags = []
# The registry answers with every tag at once; the tag API on hub.docker.com takes 130 pages for it.
url = f"{REGISTRY}/v2/{REPOSITORY}/tags/list"
while url:
    page, headers = get(url, {"Authorization": "Bearer " + token["token"]})
    tags += page.get("tags") or []
    following = re.search(r'<([^>]+)>;\s*rel="next"', headers.get("Link", ""))
    url = REGISTRY + following.group(1) if following else None

releases = sorted({tuple(int(part) for part in t.split(".")) for t in tags if re.fullmatch(r"\d{1,2}\.\d+", t)})
tested = ["%d.%d" % r for r in releases if r >= floor]
# An empty matrix is a workflow that passes without running anything, so a short answer is fatal.
if "%d.%d" % floor not in tested:
    raise SystemExit(f"{REPOSITORY} lists no {floor[0]}.{floor[1]} tag among its {len(tags)}")

print(json.dumps(tested) if args.json else "\n".join(tested))
