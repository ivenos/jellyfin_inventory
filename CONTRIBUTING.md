# Contributing

## Build

.NET 10 in the SDK container, targeting Jellyfin 12.0:

```bash
docker run --rm --security-opt label=disable -u "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$PWD:/src" -w /src mcr.microsoft.com/dotnet/sdk:10.0 \
  dotnet build -c Release
```

- The build lands in `Jellyfin.Plugin.Inventory/bin/Release/net10.0/`.
- A server picks it up from a folder of its own under `plugins`, beside a `meta.json` written by `.github/scripts/make-meta.py`, after a restart.

## Tests

`test/run.sh` builds the plugin, starts a throwaway Jellyfin with it installed and checks the API against fixture videos it generates once:

```bash
sh test/run.sh
sh test/run.sh --no-build     # reuse the existing build
sh test/run.sh --keep         # leave the server up to click through
```

- It needs Docker, python3, curl and the npm registry.
- `PORT` gives a run its own container and working directory. Runs side by side share the build, so all but one take `--no-build`.
- CI runs it once per major and minor Jellyfin release from `targetAbi` in `build.yaml` on, as listed by `test/versions.py`. The same sweep locally: `for v in $(python3 test/versions.py); do JELLYFIN_IMAGE=jellyfin/jellyfin:$v sh test/run.sh; done`
- There are no unit tests on the server side. `test/page.mjs` renders the page in jsdom against the answers the same run recorded.
- `.github/scripts/screenshots.sh` rebuilds the README screenshots from a showcase library, on the newest release the test matrix covers. Run it when a change alters what the table looks like.

## Code style

- C# on .NET 10 with the rules in `.editorconfig`, no line length limit.
- Analyzers run with `AnalysisMode=AllEnabledByDefault` and warnings are errors.
- XML documentation on public types and members, one type per file, named after it.
- An attribute the scan did not record is null, not zero.
- A comment only earns its place when it records something the code cannot. One or two lines.

## Adding a column

- The field on `InventoryRow`, the line that fills it in `InventoryService`, and the entry in `Columns`.
- A line in `Fold` if it rolls up to a series or an album, or in `FoldPlayback` or `FoldEveryone` if it is read per user.
- `column.<key>` in every file under `Strings/` and its English name in the README table, in the row of its group.
- A column that is not in the README does not exist.
- Keys are fixed once released.

## Translations

- `Strings/en.json` is the source. `test/check-strings.py` enforces that every other culture carries exactly its keys.
- A language is one file named after the culture: `pt-BR.json` for a regional variant, `pt.json` for the language.
- Take the wording from Jellyfin's own `strings/` where the term there fits.
- Counts are two-form, `ItemsOne` and `ItemsMany`. A language that needs a separate few or many form needs new keys and a change to the page.

## The configuration page

- Take colors from the theme variables (`--jf-palette-*`), never from a literal outside a `var()` fallback.
- Controls are `emby-input`, `emby-button` and `emby-select`, each with the class the web client would add to it.
- An input carries the class without `is="emby-input"`.
- The page is a flex column in the height the web client gives it, and the table takes what is left. Nothing is sized in `vh`.
- The table header sticks as a `thead`, not cell by cell.
- Nothing waits for the web client's upgrade module. Anything it would insert, such as the arrow on a select, the page draws itself.

## Jellyfin versions

- A new Jellyfin release moves these together: the `Jellyfin.Controller` and `Jellyfin.Model` versions, `targetAbi` in `build.yaml`, `IMAGE` in `test/run.sh`, and the version named in the README and under Build. `test/run.sh` checks that they agree.
- `targetAbi` is the floor of the test matrix.
- A new .NET release also moves `TargetFramework` in the csproj, `framework` in `build.yaml`, `SDK_IMAGE` in `test/run.sh`, the SDK image in the release workflow and under Build, and `net10.0` in the output path in `test/run.sh`, `.github/scripts/screenshots.sh`, the release workflow and under Build, and the version named under Build and Code style.

## Commits

Conventional Commits (https://www.conventionalcommits.org/en/v1.0.0/) with a short imperative subject.

## Releases

- A `v1.2.0` tag builds a draft release. A tag that is not three numbers is refused.
- Publishing the draft adds the version to `manifest.json`, with the release notes as its changelog. Publishing it as a pre-release does not.
- Notes edited after publishing, and a release that is deleted, reach `manifest.json` by hand.
- Rebuild the README screenshots before every release.
- The changelog lives in the GitHub release notes, in Keep a Changelog style (https://keepachangelog.com/en/1.1.0/). There is no CHANGELOG.md.

## Dependencies

- GitHub Actions and Docker images stay on version tags, never commit SHAs or digests.
- Renovate opens the bumps, including Node, jsdom and Playwright in `test/run.sh` and `.github/scripts/screenshots.sh`. Other PRs leave dependencies alone.
- `Jellyfin.Controller`, `Jellyfin.Model`, and the Jellyfin and SDK images in `test/run.sh` move by hand, with the Jellyfin version.

## Pull requests

- One concern per PR, with tests for behavior changes.
- Only the PR author and the maintainer commit to it.
- `sh test/run.sh` must pass.
- The test plan names the media types you exercised. Aggregation changes need a series or a season, not only movies.
- Fill in the PR template, including the test plan and the CLA checkbox.
