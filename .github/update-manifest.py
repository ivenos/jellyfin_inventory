#!/usr/bin/env python3
"""Adds a released version to manifest.json, the repository Jellyfin subscribes to."""

import argparse
import json
import pathlib
import re

parser = argparse.ArgumentParser()
parser.add_argument("--manifest", default="manifest.json")
parser.add_argument("--version", required=True)
parser.add_argument("--target-abi", required=True)
parser.add_argument("--source-url", required=True)
parser.add_argument("--checksum", required=True)
parser.add_argument("--timestamp", required=True)
parser.add_argument("--changelog", default="")
args = parser.parse_args()

# An empty targetAbi means "every server" to Jellyfin, and an empty checksum fails every install,
# so a silently empty extraction upstream must not reach the file.
for name, value, pattern in (
    ("version", args.version, r"^\d+\.\d+\.\d+\.\d+$"),
    ("target-abi", args.target_abi, r"^\d+\.\d+\.\d+\.\d+$"),
    ("checksum", args.checksum, r"^[0-9a-fA-F]{32}$"),
    ("source-url", args.source_url, r"^https://\S+$"),
    ("timestamp", args.timestamp, r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"),
):
    if not re.fullmatch(pattern, value or ""):
        raise SystemExit(f"--{name} is {value!r}, which does not match {pattern}")

path = pathlib.Path(args.manifest)
packages = json.loads(path.read_text(encoding="utf-8")) if path.exists() else []
if not packages:
    raise SystemExit(f"{path} is missing or empty; it holds the plugin metadata and is not generated")

versions = packages[0].setdefault("versions", [])
# Older entries stay: a server only sees versions whose targetAbi it satisfies, so leaving
# them is what keeps installations on an older Jellyfin working.
versions = [v for v in versions if v.get("version") != args.version]
versions.append({
    "version": args.version,
    "changelog": args.changelog,
    "targetAbi": args.target_abi,
    "sourceUrl": args.source_url,
    "checksum": args.checksum,
    "timestamp": args.timestamp,
})


# A hand-written entry that is not plain numbers sorts last rather than killing the release job.
def order(entry):
    parts = entry.get("version", "").split(".")
    return tuple(int(p) for p in parts) if all(p.isdigit() for p in parts) else ()


versions.sort(key=order, reverse=True)
packages[0]["versions"] = versions

path.write_text(json.dumps(packages, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
print(f"manifest.json now lists {len(versions)} version(s), newest {versions[0]['version']}")
