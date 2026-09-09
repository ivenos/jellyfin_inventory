# Contributing

## Build

.NET 10, targeting Jellyfin 12.0. Nothing has to be installed locally:

```bash
docker run --rm --security-opt label=disable -u "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$PWD:/src" -w /src mcr.microsoft.com/dotnet/sdk:10.0 \
  dotnet build -c Release
```

The build lands in `Jellyfin.Plugin.Inventory/bin/Release/net10.0/`. A server
picks it up from a folder of its own under `plugins`, after a restart.

## Tests

`test/run.sh` builds the plugin, starts a throwaway Jellyfin with it installed,
and checks the API against fixture videos it generates once. Needs Docker and a
few minutes; `PORT` gives a run its own container and working directory.

```bash
sh test/run.sh
sh test/run.sh --no-build     # reuse the existing build
sh test/run.sh --keep         # leave the server up to click through
```

There are no unit tests; everything here reads from a live library, and a mocked
`ILibraryManager` would only prove the mock was called.

## Adding a column

The field on `InventoryRow`, the line that fills it in `InventoryService`, the
entry in `Columns`, and, if it should roll up to a series or an album, a line in
`Fold`. Then `column.<key>` in every file under `Strings/` and a row in the
README table; a column that is not in the README does not exist. Keys are fixed
once released, since renaming one drops it from everyone's selection.

## Translations

`Strings/en.json` is the source, and `test/check-strings.py` enforces that every
other culture carries exactly its keys. A language is one file named after the
culture, `pt-BR.json` for a regional variant, `pt.json` for the language. Take
the wording from Jellyfin's own `strings/` where a term exists there.

## The configuration page

Take colours from the theme variables (`--jf-palette-*`) and never from literals,
or the table looks right in the default dark theme and wrong in the other five.
Controls are `emby-input`, `emby-button` and `emby-select`.

## Code style

- A comment only earns its place when it records something the code cannot: a
  Jellyfin API quirk, the reason a value is derived rather than read. One or two
  lines. Never restate what the code already says.
- XML documentation on public types and members. Analyzers run with
  `AnalysisMode=AllEnabledByDefault` and warnings are errors, which also means
  one type per file, named after it.
- An attribute the scan did not record is null, not zero.

## Jellyfin versions

Moving to a new release means moving three things together, because none of them
follows from the others: the `Jellyfin.Controller` and `Jellyfin.Model`
versions, `targetAbi` in `build.yaml`, and `IMAGE` in `test/run.sh`. Renovate
leaves all three alone.

A release that moves .NET as well takes `TargetFramework` in the csproj and
`framework` in `build.yaml` with it, `SDK_IMAGE` in `test/run.sh` and the image
in the release workflow, and the `net10.0` in the output path, spelled out in
`test/run.sh`, `docs/shots.sh`, the release workflow and under Build above.
`docs/shots.sh` reads both images out of `test/run.sh`.

## Releases

A `v1.2.0` tag builds a draft release; anything that is not three numbers is
refused. Publishing the draft is what adds the version to `manifest.json`. The
changelog lives in the release notes, in Keep a Changelog style
(https://keepachangelog.com/en/1.1.0/). There is no CHANGELOG.md file.

## Pull requests

- Conventional Commits (https://www.conventionalcommits.org/en/v1.0.0/), with a
  short imperative subject. One concern per PR.
- `test/run.sh` must pass and the build must stay free of analyzer warnings.
- Say which media types you exercised. Aggregation changes need a series or a
  season in the test plan, not only movies.
