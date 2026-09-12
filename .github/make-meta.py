#!/usr/bin/env python3
"""Writes the meta.json that ships beside the assembly in the release archive."""

import argparse
import datetime
import json
import pathlib
import re

parser = argparse.ArgumentParser()
parser.add_argument("--version", required=True)
parser.add_argument("--root", default=".")
parser.add_argument("--out", required=True)
args = parser.parse_args()

if not re.fullmatch(r"\d+\.\d+\.\d+\.\d+", args.version):
    raise SystemExit(f"--version is {args.version!r}, which is not four numbers")

root = pathlib.Path(args.root)
package = json.loads((root / "manifest.json").read_text(encoding="utf-8"))[0]

abi = re.search(r'^targetAbi:\s*"(\d+\.\d+\.\d+\.\d+)"', (root / "build.yaml").read_text(encoding="utf-8"), re.M)
if not abi:
    raise SystemExit("build.yaml carries no targetAbi of four numbers in quotes")

# Without this file Jellyfin dates an unpacked plugin to the server's own version, and deletes
# every later release as if it were the older copy.
pathlib.Path(args.out).write_text(json.dumps({
    "guid": package["guid"],
    "name": package["name"],
    "description": package["description"],
    "overview": package["overview"],
    "owner": package["owner"],
    "category": package["category"],
    "version": args.version,
    "targetAbi": abi.group(1),
    "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "changelog": "",
    "status": "Active",
    "autoUpdate": True,
    "assemblies": [],
}, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
print(f"{args.out} describes {package['name']} {args.version} for abi {abi.group(1)}")
