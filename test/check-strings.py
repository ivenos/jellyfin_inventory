#!/usr/bin/env python3
"""Checks that every culture carries exactly the keys en does, with usable values."""

import json
import pathlib
import re
import sys

directory = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "Jellyfin.Plugin.Inventory/Strings")


def load(path):
    seen = []

    def keep(pairs):
        seen.extend(k for k, _ in pairs)
        return dict(pairs)

    strings = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=keep)
    if len(seen) != len(strings):
        raise SystemExit(f"FAIL {path.name}: a key appears twice")
    return strings


base = load(directory / "en.json")
cultures = sorted(directory.glob("*.json"))
failed = False

for path in cultures:
    strings = load(path)
    problems = []
    if path.name != "en.json":
        problems += [f"missing {k}" for k in sorted(set(base) - set(strings))]
        problems += [f"unknown {k}" for k in sorted(set(strings) - set(base))]

    for key, value in strings.items():
        if not isinstance(value, str) or not value.strip():
            problems.append(f"{key} is empty")
        elif re.search(r"[\u2013\u2014]", value):
            problems.append(f"{key} carries a typographic dash")
        # A placeholder dropped renders a sentence with no number, one invented renders braces.
        if key in base and sorted(re.findall(r"\{\d+\}", value)) != sorted(re.findall(r"\{\d+\}", base[key])):
            problems.append(f"{key} does not carry the placeholders en has")

    if problems:
        failed = True
        print(f"FAIL {path.name}: " + ", ".join(problems))

page = directory.parent / "Configuration" / "configPage.html"
# The closing bracket keeps a key built by concatenation out.
asked = set(re.findall(r"\bt\('([^']+)'\s*[,)]", page.read_text(encoding="utf-8")))
if not asked:
    failed = True
    print(f"FAIL {page.name}: no translated string is asked for, which cannot be right")
unknown = sorted(asked - set(base))
if unknown:
    failed = True
    print(f"FAIL {page.name}: " + ", ".join(f"asks for {k}, which en.json has not" for k in unknown))

print(f"{len(base)} keys across {len(cultures)} cultures, {len(asked)} asked for by the page")
sys.exit(1 if failed else 0)
