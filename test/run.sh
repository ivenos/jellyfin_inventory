#!/bin/sh
# Builds the plugin, runs it in a throwaway Jellyfin, and checks the API against known fixtures.
set -eu

IMAGE="${JELLYFIN_IMAGE:-jellyfin/jellyfin:12.0}"
SDK_IMAGE="${SDK_IMAGE:-mcr.microsoft.com/dotnet/sdk:10.0}"
NODE_IMAGE="${NODE_IMAGE:-node:22-alpine}"
JSDOM_VERSION="${JSDOM_VERSION:-26.1.0}"
PORT="${PORT:-8097}"
# Keyed by port, so a second run on another port cannot tear down the first one.
CONTAINER="${CONTAINER:-jellyfin-inventory-test-$PORT}"
WORK="${INVENTORY_TEST_DIR:-$HOME/.cache/jellyfin-inventory-test-$PORT}"
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD=1
KEEP=0
REACHED_END=0
PASS=0
FAIL=0

for arg in "$@"; do
    case "$arg" in
        --no-build) BUILD=0 ;;
        --keep) KEEP=1 ;;
        *) echo "usage: $0 [--no-build] [--keep]" >&2; exit 2 ;;
    esac
done

cleanup() {
    status=$?
    if [ "$status" != 0 ] && [ "$REACHED_END" != 1 ]; then
        echo "the run stopped before its summary (exit $status)" >&2
        docker logs "$CONTAINER" 2>&1 | tail -20 >&2
    fi
    [ "$KEEP" = 1 ] && { echo "Instance left at http://localhost:$PORT (admin / inventorytest)"; return; }
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}

refused() {
    echo "the server refused ${2:-POST} $1" >&2
    docker logs "$CONTAINER" 2>&1 | tail -20 >&2
    exit 1
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# printf, because the echo of dash, which is sh on the CI runner, reads backslashes in a value.
check() {
    if [ -z "$2" ] || [ "$2" = "<unparseable>" ] || [ "$3" = "<unparseable>" ]; then
        FAIL=$((FAIL + 1))
        printf "FAIL %s: a value could not be read ('%s' vs '%s')\n" "$1" "$2" "$3"
    elif [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL %s: expected '%s', got '%s'\n" "$1" "$3" "$2"
    fi
}

api() {
    curl -sf --max-time 120 "http://localhost:$PORT/$1" -H "Authorization: MediaBrowser Token=\"$TOKEN\"" && return
    echo "the api answered $1 with $(curl -s --max-time 120 -o /dev/null -w '%{http_code}' \
        "http://localhost:$PORT/$1" -H "Authorization: MediaBrowser Token=\"$TOKEN\"")" >&2
    return 1
}

field() {
    python3 -c "import sys,json;print($1)" 2>/dev/null || echo "<unparseable>"
}

echo "== $IMAGE =="
echo "== strings =="
python3 "$ROOT/test/check-strings.py" "$ROOT/Jellyfin.Plugin.Inventory/Strings"

mkdir -p "$WORK"
python3 -c "
import pathlib, re, sys
html = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
scripts = re.findall(r'<script[^>]*>(.*?)</script>', html, re.S)
if not scripts:
    raise SystemExit('configPage.html carries no script block')
pathlib.Path(sys.argv[2]).write_text('\n'.join(scripts), encoding='utf-8')
" "$ROOT/Jellyfin.Plugin.Inventory/Configuration/configPage.html" "$WORK/page.js"
# Nothing else parses the page, and a typo in it leaves an empty dashboard with every check green.
check "the page script parses" \
    "$(docker run --rm --security-opt label=disable -v "$WORK:/w:ro" "$NODE_IMAGE" \
        node --check /w/page.js >/dev/null 2>&1 && echo ok || echo broken)" "ok"

# Only the tabs that hold something reach the schema, so an empty level would go unnamed.
check "every level a tab can hold is named in the strings" \
    "$(python3 -c "
import json, pathlib, re
kinds = re.findall(r'BaseItemKind\.(\w+)', pathlib.Path('$ROOT/Jellyfin.Plugin.Inventory/Hierarchy.cs').read_text(encoding='utf-8'))
strings = json.loads(pathlib.Path('$ROOT/Jellyfin.Plugin.Inventory/Strings/en.json').read_text(encoding='utf-8'))
missing = sorted({'level.' + k for k in kinds} - set(strings))
print('ok' if not missing else missing)")" "ok"
# CONTRIBUTING puts it the other way round: a column that is not in the README does not exist.
check "the readme lists exactly the columns there are" \
    "$(python3 -c "
import json, pathlib, re
root = pathlib.Path('$ROOT')
groups = {}
for key, group in re.findall(r'new\(\"([^\"]+)\",\s*([A-Za-z]+|\"[A-Za-z]+\")',
                             (root / 'Jellyfin.Plugin.Inventory/Columns.cs').read_text(encoding='utf-8')):
    strings = json.loads((root / 'Jellyfin.Plugin.Inventory/Strings/en.json').read_text(encoding='utf-8'))
    groups.setdefault(strings['group.' + group.strip('\"')], []).append(strings['column.' + key])
listed = {}
for line in re.search(r'## Columns\n\n(.*?)\n\n', (root / 'README.md').read_text(encoding='utf-8'), re.S).group(1).splitlines()[2:]:
    cells = [c.strip() for c in line.strip('|').split('|')]
    listed[cells[0]] = [c.strip() for c in cells[1].split(',')]
print('ok' if listed == groups else [listed, groups])")" "ok"

check "every file names the same jellyfin version" \
    "$(python3 -c "
import pathlib, re
root = pathlib.Path('$ROOT')
seen = {
    'build.yaml': (r'^targetAbi: \"(\d+\.\d+)', 'build.yaml'),
    'csproj': (r'\"Jellyfin\.\w+\" Version=\"(\d+\.\d+)', 'Jellyfin.Plugin.Inventory/Jellyfin.Plugin.Inventory.csproj'),
    'run.sh': (r'jellyfin/jellyfin:(\d+\.\d+)', 'test/run.sh'),
    'README.md': (r'Jellyfin (\d+\.\d+)', 'README.md'),
    'CONTRIBUTING.md': (r'Jellyfin (\d+\.\d+)', 'CONTRIBUTING.md'),
}
found = {name: sorted(set(re.findall(p, (root / f).read_text(encoding='utf-8'), re.M)))
         for name, (p, f) in seen.items()}
print('ok' if all(v == list(found['build.yaml']) for v in found.values()) and found['build.yaml'] else found)")" "ok"

check "the page takes its colors from the theme" \
    "$(python3 -c "
import pathlib, re
html = pathlib.Path('$ROOT/Jellyfin.Plugin.Inventory/Configuration/configPage.html').read_text(encoding='utf-8')
style = '\n'.join(re.findall(r'<style[^>]*>(.*?)</style>', html, re.S))
bare = re.sub(r'var\(--jf-[^()]*(?:\([^()]*\))?[^()]*\)', '', style)
loose = re.findall(r'#[0-9a-fA-F]{3,8}\b|rgba?\([^)]*\)', bare)
print('ok' if not loose else loose)")" "ok"

check "the header sticks as a whole, since firefox draws sticky cells low after a wheel scroll" \
    "$(python3 -c "
import pathlib, re
html = pathlib.Path('$ROOT/Jellyfin.Plugin.Inventory/Configuration/configPage.html').read_text(encoding='utf-8')
sticky = re.findall(r'([^{}]+)\{[^{}]*position:\s*sticky', html)
print('ok' if [s.strip().split()[-1] for s in sticky] == ['thead'] else sticky)")" "ok"
check "no input asks for the upgrade, which throws on one that already carries the class" \
    "$(grep -c 'is="emby-input"' "$ROOT/Jellyfin.Plugin.Inventory/Configuration/configPage.html" || true)" "0"

cp "$ROOT/manifest.json" "$WORK/manifest.json"
check "a release is written into the manifest ahead of the ones already listed" \
    "$(python3 "$ROOT/.github/scripts/update-manifest.py" --manifest "$WORK/manifest.json" \
        --version 99.9.9.0 --target-abi 12.0.0.0 --checksum 0123456789abcdef0123456789abcdef \
        --source-url https://example.invalid/inventory_99.9.9.0.zip \
        --timestamp 2099-01-01T00:00:00Z --changelog='- a note that opens with a dash' >/dev/null \
      && python3 -c "
import json
kept = json.load(open('$ROOT/manifest.json'))[0]['versions']
now = json.load(open('$WORK/manifest.json'))[0]['versions']
print('ok' if now[0]['version'] == '99.9.9.0'
      and now[0]['changelog'] == '- a note that opens with a dash'
      and [v['version'] for v in now[1:]] == [v['version'] for v in kept] else now)")" "ok"
check "while one whose checksum did not survive the release job is refused" \
    "$(python3 "$ROOT/.github/scripts/update-manifest.py" --manifest "$WORK/manifest.json" \
        --version 99.9.9.0 --target-abi 12.0.0.0 --checksum '' \
        --source-url https://example.invalid/inventory_99.9.9.0.zip \
        --timestamp 2099-01-01T00:00:00Z >/dev/null 2>&1 && echo written || echo refused)" "refused"

if [ "$BUILD" = 1 ]; then
    echo "== build =="
    # Docker would create a missing mount source as root, which the uid the build runs under cannot write to.
    mkdir -p "$WORK/nuget"
    docker run --rm --security-opt label=disable --user "$(id -u):$(id -g)" \
        -e HOME=/tmp -e DOTNET_CLI_TELEMETRY_OPTOUT=1 -e DOTNET_NOLOGO=1 -e NUGET_PACKAGES=/nuget \
        -v "$ROOT:/src" -v "$WORK/nuget:/nuget" -w /src "$SDK_IMAGE" \
        dotnet build -c Release --nologo
fi

DLL="$ROOT/Jellyfin.Plugin.Inventory/bin/Release/net10.0/Jellyfin.Plugin.Inventory.dll"
[ -f "$DLL" ] || { echo "no plugin build at $DLL" >&2; exit 1; }

echo "== fixtures =="
# The Jellyfin image carries the ffmpeg that produced these, so no second toolchain is needed.
RECIPE=$(cat <<'FIXTURES'
        set -e
        FF=/usr/lib/jellyfin-ffmpeg/ffmpeg
        mkdir -p "/media/movies/Blue Harbour (2021)" "/media/movies/Night Signal (2023)" \
                 "/media/movies/=Formula Trap (2024)" \
                 "/media/shows/Harbour Lights (2022)/Season 01" \
                 "/media/shows/Long Run (2020)/Season 01" "/media/shows/Long Run (2020)/Season 02"
        # 24000/1001 is kept as 23.976025, which is not the 23.976 anyone types.
        $FF -y -loglevel error -f lavfi -i testsrc2=size=1920x1080:rate=24000/1001:duration=20 \
            -f lavfi -i sine=frequency=440:duration=20 \
            -c:v libx264 -preset ultrafast -crf 30 -pix_fmt yuv420p -c:a aac -ac 2 -b:a 128k \
            "/media/movies/Blue Harbour (2021)/Blue Harbour (2021).mkv"
        # HDR10 has to go into the bitstream; the muxer-level color flags do not survive here.
        $FF -y -loglevel error -f lavfi -i testsrc2=size=3840x2160:rate=24:duration=15 \
            -f lavfi -i sine=frequency=300:duration=15 \
            -c:v libx265 -preset ultrafast -crf 32 -pix_fmt yuv420p10le \
            -bsf:v hevc_metadata=colour_primaries=9:transfer_characteristics=16:matrix_coefficients=9 \
            -c:a eac3 -ac 6 -b:a 640k \
            "/media/movies/Night Signal (2023)/Night Signal (2023).mkv"
        printf '1\n00:00:00,000 --> 00:00:05,000\nHarbour\n\n' > /tmp/sub.srt
        # The same file into all three, or their sizes stop being equal.
        for e in 01 02 03; do
            $FF -y -loglevel error -f lavfi -i testsrc2=size=1920x1080:rate=25:duration=10 \
                -f lavfi -i sine=frequency=600:duration=10 -f lavfi -i sine=frequency=700:duration=10 \
                -i /tmp/sub.srt \
                -map 0:v -map 1:a -map 2:a -map 3:s -c:v libx264 -preset ultrafast -crf 32 -pix_fmt yuv420p \
                -c:a aac -ac 2 -metadata:s:a:0 language=eng -metadata:s:a:1 language=deu \
                -c:s srt -metadata:s:s:0 language=eng \
                "/media/shows/Harbour Lights (2022)/Season 01/Harbour Lights S01E$e.mkv"
        done
        # An extra belongs to the film it sits with, not to a tab of its own.
        mkdir -p "/media/movies/Blue Harbour (2021)/behind the scenes"
        $FF -y -loglevel error -f lavfi -i testsrc2=size=320x240:rate=10:duration=2 \
            -c:v libx264 -preset ultrafast -crf 40 -pix_fmt yuv420p \
            "/media/movies/Blue Harbour (2021)/behind the scenes/Making Of.mkv"
        # A title a spreadsheet would evaluate rather than print.
        $FF -y -loglevel error -f lavfi -i testsrc2=size=320x240:rate=10:duration=2 \
            -c:v libx264 -preset ultrafast -crf 40 -pix_fmt yuv420p \
            "/media/movies/=Formula Trap (2024)/=Formula Trap (2024).mkv"
        # Two seasons, and a codec that differs between them, so the series aggregates to mixed.
        $FF -y -loglevel error -f lavfi -i testsrc2=size=640x360:rate=25:duration=4 \
            -f lavfi -i sine=frequency=500:duration=4 \
            -c:v libx264 -preset ultrafast -crf 40 -pix_fmt yuv420p -c:a aac -ac 2 \
            "/media/shows/Long Run (2020)/Season 01/Long Run S01E01.mkv"
        $FF -y -loglevel error -f lavfi -i testsrc2=size=320x180:rate=25:duration=4 \
            -f lavfi -i sine=frequency=500:duration=4 \
            -c:v libx265 -preset ultrafast -crf 40 -pix_fmt yuv420p -c:a aac -ac 2 \
            "/media/shows/Long Run (2020)/Season 02/Long Run S02E01.mkv"
        # One episode carries bytes but nothing else, which is what an unreadable file looks like.
        mkdir -p "/media/shows/Patchy (2021)/Season 01"
        $FF -y -loglevel error -f lavfi -i testsrc2=size=640x360:rate=25:duration=6 \
            -f lavfi -i sine=frequency=500:duration=6 \
            -c:v libx264 -preset ultrafast -crf 40 -pix_fmt yuv420p -c:a aac -ac 2 \
            "/media/shows/Patchy (2021)/Season 01/Patchy S01E05.mkv"
        dd if=/dev/urandom of="/media/shows/Patchy (2021)/Season 01/Patchy S01E06.mkv" \
            bs=1024 count=2048 status=none
        # A name a spreadsheet has to be protected from, a CSV has to quote and an XML has to escape.
        mkdir -p "/media/movies/Ärger, \"Quoted\" & <Mövie> (2018)"
        $FF -y -loglevel error -f lavfi -i testsrc2=size=320x240:rate=10:duration=2 \
            -c:v libx264 -preset ultrafast -crf 40 -pix_fmt yuv420p \
            "/media/movies/Ärger, \"Quoted\" & <Mövie> (2018)/Ärger, \"Quoted\" & <Mövie> (2018).mkv"
        # The file named after the folder is the film, and the second cut beside it is split in two.
        mkdir -p "/media/movies/Double Cut (2022)"
        $FF -y -loglevel error -f lavfi -i testsrc2=size=640x360:rate=25:duration=5 \
            -f lavfi -i sine=frequency=500:duration=5 \
            -c:v libx264 -preset ultrafast -crf 40 -pix_fmt yuv420p -c:a aac -ac 2 \
            "/media/movies/Double Cut (2022)/Double Cut (2022).mkv"
        $FF -y -loglevel error -f lavfi -i testsrc2=size=1280x720:rate=25:duration=3 \
            -f lavfi -i sine=frequency=500:duration=3 \
            -c:v libx264 -preset ultrafast -crf 34 -pix_fmt yuv420p -c:a aac -ac 2 \
            "/media/movies/Double Cut (2022)/Double Cut (2022) - 720p - part1.mkv"
        $FF -y -loglevel error -f lavfi -i testsrc2=size=1280x720:rate=25:duration=2 \
            -f lavfi -i sine=frequency=500:duration=2 \
            -c:v libx264 -preset ultrafast -crf 34 -pix_fmt yuv420p -c:a aac -ac 2 \
            "/media/movies/Double Cut (2022)/Double Cut (2022) - 720p - part2.mkv"
        # Both at once: a cut split across two files, beside a second cut of the same film.
        mkdir -p "/media/movies/Two Cuts (2019)"
        $FF -y -loglevel error -f lavfi -i testsrc2=size=640x360:rate=25:duration=6 \
            -f lavfi -i sine=frequency=500:duration=6 \
            -c:v libx264 -preset ultrafast -crf 40 -pix_fmt yuv420p -c:a aac -ac 2 \
            "/media/movies/Two Cuts (2019)/Two Cuts (2019) - part1.mkv"
        $FF -y -loglevel error -f lavfi -i testsrc2=size=640x360:rate=25:duration=4 \
            -f lavfi -i sine=frequency=500:duration=4 \
            -c:v libx264 -preset ultrafast -crf 40 -pix_fmt yuv420p -c:a aac -ac 2 \
            "/media/movies/Two Cuts (2019)/Two Cuts (2019) - part2.mkv"
        $FF -y -loglevel error -f lavfi -i testsrc2=size=1280x720:rate=25:duration=6 \
            -f lavfi -i sine=frequency=500:duration=6 \
            -c:v libx264 -preset ultrafast -crf 34 -pix_fmt yuv420p -c:a aac -ac 2 \
            "/media/movies/Two Cuts (2019)/Two Cuts (2019) - Directors Cut.mkv"
        # Jellyfin stacks these into one movie, and only the first part carries its size.
        mkdir -p "/media/movies/Two Part Feature (2019)"
        $FF -y -loglevel error -f lavfi -i testsrc2=size=640x360:rate=25:duration=6 \
            -f lavfi -i sine=frequency=500:duration=6 \
            -c:v libx264 -preset ultrafast -crf 40 -pix_fmt yuv420p -c:a aac -ac 2 \
            "/media/movies/Two Part Feature (2019)/Two Part Feature (2019) - part1.mkv"
        $FF -y -loglevel error -f lavfi -i testsrc2=size=640x360:rate=25:duration=4 \
            -f lavfi -i sine=frequency=500:duration=4 \
            -c:v libx264 -preset ultrafast -crf 40 -pix_fmt yuv420p -c:a aac -ac 2 \
            "/media/movies/Two Part Feature (2019)/Two Part Feature (2019) - part2.mkv"
        # A photo carries no stream, so its size and dimensions have to come off the item.
        mkdir -p /media/photos/Trip
        $FF -y -loglevel error -f lavfi -i testsrc2=size=4032x3024:rate=1:duration=1 \
            -frames:v 1 /media/photos/Trip/Beach.jpg
        $FF -y -loglevel error -f lavfi -i testsrc2=size=1600x1200:rate=1:duration=1 \
            -frames:v 1 /media/photos/Trip/Harbour.jpg
        # Fewer pixels but a larger first digit, so a text sort puts it in the wrong place.
        $FF -y -loglevel error -f lavfi -i testsrc2=size=800x600:rate=1:duration=1 \
            -frames:v 1 /media/photos/Trip/Garden.jpg
        mkdir -p "/media/music/The Fixtures/Test Pattern"
        for n in 1 2; do
            $FF -y -loglevel error -f lavfi -i sine=frequency=$((300 + n * 100)):duration=8 \
                -c:a flac -metadata artist="The Fixtures" -metadata album="Test Pattern" \
                -metadata title="Track $n" -metadata track="$n" -metadata date=2024 \
                "/media/music/The Fixtures/Test Pattern/0$n Track $n.flac"
        done
        # Beside the albums rather than in one, so no row opens to reach it.
        $FF -y -loglevel error -f lavfi -i sine=frequency=800:duration=12 \
            -c:a flac -metadata artist="Nobody" -metadata title="Loose Single" \
            "/media/music/Loose Single.flac"
FIXTURES
)
BOOK_TITLE="The Fixture Manual"
BOOK_AUTHOR="A. Tester"
# A second library of the same kind, so a row has to name the one it is really in.
SHELF_TITLE="The Second Shelf"
# Stamped with what produced them, so editing any of it rebuilds instead of silently reusing.
STAMP=$(printf '%s\n%s\n%s\n%s\n%s' "$RECIPE" "$BOOK_TITLE" "$BOOK_AUTHOR" "$SHELF_TITLE" "$IMAGE" \
    | cat - "$ROOT/test/make-book.py" | md5sum | cut -d' ' -f1)

if [ "$(cat "$WORK/media/.complete" 2>/dev/null || true)" != "$STAMP" ]; then
    rm -rf "${WORK:?}/media"
    mkdir -p "$WORK/media/books" "$WORK/media/shelf"
    python3 "$ROOT/test/make-book.py" "$WORK/media/books/$BOOK_TITLE.epub" \
        "$BOOK_TITLE" "$BOOK_AUTHOR"
    python3 "$ROOT/test/make-book.py" "$WORK/media/shelf/$SHELF_TITLE.epub" \
        "$SHELF_TITLE" "$BOOK_AUTHOR"
    docker run --rm --security-opt label=disable --user "$(id -u):$(id -g)" \
        -v "$WORK/media:/media" --entrypoint /bin/sh "$IMAGE" -c "$RECIPE"
    # Written last, so an interrupted run does not leave half a set that looks complete.
    printf '%s' "$STAMP" > "$WORK/media/.complete"
fi

# Left behind by the growing-library check, and it would throw off this run's counts.
rm -rf "${WORK:?}/media/movies/Late Arrival (2025)" "${WORK:?}/media/copies"

echo "== start =="
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
rm -rf "${WORK:?}/config" "${WORK:?}/cache"
mkdir -p "$WORK/config/plugins/Inventory" "$WORK/cache"
cp "$DLL" "$ROOT/.github/assets/thumb.png" "$WORK/config/plugins/Inventory/"
python3 "$ROOT/.github/scripts/make-meta.py" --version 9.9.9.0 --root "$ROOT" \
    --out "$WORK/config/plugins/Inventory/meta.json" >/dev/null
# Runs under the caller's uid so a later run can clear the config it writes.
docker run -d --name "$CONTAINER" --security-opt label=disable \
    --user "$(id -u):$(id -g)" \
    -p "127.0.0.1:$PORT:8096" \
    -v "$WORK/config:/config" -v "$WORK/cache:/cache" -v "$WORK/media:/media:ro" \
    "$IMAGE" >/dev/null

CLIENT='Authorization: MediaBrowser Client="test", Device="cli", DeviceId="inventory-test", Version="1.0.0"'
JSON='Content-Type: application/json'
BASE="http://localhost:$PORT"

# The port answers before the server is ready to serve, so wait on the endpoint the setup below uses.
printf 'waiting for startup'
i=0
until curl -sf --max-time 10 "$BASE/Startup/Configuration" -H "$CLIENT" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -gt 90 ] && { echo; echo "server did not come up" >&2; docker logs "$CONTAINER" 2>&1 | tail -20; exit 1; }
    printf '.'
    sleep 2
done
echo

docker logs "$CONTAINER" 2>&1 | grep -q "Loaded plugin: Inventory 9.9.9.0" \
    || { echo "plugin was not loaded under its own version" >&2; docker logs "$CONTAINER" 2>&1 | grep -i inventory; exit 1; }

echo "== setup =="
curl -sf -X POST "$BASE/Startup/Configuration" -H "$JSON" -H "$CLIENT" \
    -d '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}' >/dev/null || refused "Startup/Configuration"
curl -sf "$BASE/Startup/User" -H "$CLIENT" >/dev/null || refused "Startup/User" GET
curl -sf -X POST "$BASE/Startup/User" -H "$JSON" -H "$CLIENT" \
    -d '{"Name":"admin","Password":"inventorytest"}' >/dev/null || refused "Startup/User"
curl -sf -X POST "$BASE/Startup/RemoteAccess" -H "$JSON" -H "$CLIENT" \
    -d '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' >/dev/null || refused "Startup/RemoteAccess"
curl -sf -X POST "$BASE/Startup/Complete" -H "$CLIENT" >/dev/null || refused "Startup/Complete"
AUTH=$(curl -sf -X POST "$BASE/Users/AuthenticateByName" -H "$JSON" -H "$CLIENT" \
    -d '{"Username":"admin","Pw":"inventorytest"}')
TOKEN=$(printf '%s\n' "$AUTH" | field "json.load(sys.stdin)['AccessToken']")
USER_ID=$(printf '%s\n' "$AUTH" | field "json.load(sys.stdin)['User']['Id']")
case "$TOKEN" in
    ""|"<unparseable>") echo "could not sign in: $AUTH" >&2; exit 1 ;;
esac

# The fixture names match real films and series, so a metadata lookup renames them mid-run.
OFFLINE=$(python3 -c "
import json
kinds = ['Movie', 'Series', 'Season', 'Episode', 'MusicArtist', 'MusicAlbum', 'Audio',
         'Book', 'Photo', 'PhotoAlbum', 'Video', 'MusicVideo', 'BoxSet', 'Trailer']
print(json.dumps({'LibraryOptions': {'TypeOptions': [
    {'Type': k, 'MetadataFetchers': [], 'MetadataFetcherOrder': [],
     'ImageFetchers': [], 'ImageFetcherOrder': []} for k in kinds]}}))")

curl -sf --max-time 600 -X POST "$BASE/Library/VirtualFolders?name=Movies&collectionType=movies&paths=/media/movies&refreshLibrary=true" \
    -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "$JSON" -d "$OFFLINE" >/dev/null || refused "Library/VirtualFolders?name=Movies"
curl -sf --max-time 600 -X POST "$BASE/Library/VirtualFolders?name=Shows&collectionType=tvshows&paths=/media/shows&refreshLibrary=true" \
    -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "$JSON" -d "$OFFLINE" >/dev/null || refused "Library/VirtualFolders?name=Shows"
curl -sf --max-time 600 -X POST "$BASE/Library/VirtualFolders?name=Music&collectionType=music&paths=/media/music&refreshLibrary=true" \
    -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "$JSON" -d "$OFFLINE" >/dev/null || refused "Library/VirtualFolders?name=Music"
curl -sf --max-time 600 -X POST "$BASE/Library/VirtualFolders?name=Books&collectionType=books&paths=/media/books&refreshLibrary=true" \
    -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "$JSON" -d "$OFFLINE" >/dev/null || refused "Library/VirtualFolders?name=Books"
curl -sf --max-time 600 -X POST "$BASE/Library/VirtualFolders?name=Shelf&collectionType=books&paths=/media/shelf&refreshLibrary=true" \
    -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "$JSON" -d "$OFFLINE" >/dev/null || refused "Library/VirtualFolders?name=Shelf"
curl -sf --max-time 600 -X POST "$BASE/Library/VirtualFolders?name=Photos&collectionType=homevideos&paths=/media/photos&refreshLibrary=true" \
    -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "$JSON" -d "$OFFLINE" >/dev/null || refused "Library/VirtualFolders?name=Photos"

# refreshLibrary on the create call does not always start a scan, so nudge it while waiting.
# Counted per tab rather than summed, or a half finished scan reaches the same total.
printf 'waiting for the scan'
i=0
until [ "$(api 'Inventory/Schema' | field "
(lambda have: 'ok' if all(have.get(k) == v for k, v in
                          {'Movie': 7, 'Series': 3, 'MusicAlbum': 3, 'Book': 2, 'Photo': 3}.items()) else have)(
    {t['MediaType']: t['Count'] for t in json.load(sys.stdin)['MediaTypes']})")" = "ok" ]; do
    i=$((i + 1))
    [ "$i" -gt 60 ] && { echo; echo "library did not settle" >&2; api 'Inventory/Schema'; exit 1; }
    [ $((i % 10)) = 0 ] && curl -sf -X POST "$BASE/Library/Refresh" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"" >/dev/null 2>&1
    printf '.'
    sleep 3
done
echo

# Items appear before Jellyfin has probed them, and a row without streams would fail the
# codec checks for the wrong reason.
printf 'waiting for the media analysis'
i=0
until [ "$(api 'Inventory/Items?mediaType=MusicAlbum' | field "','.join(sorted({r['Values'].get('audioCodec') or '' for r in json.load(sys.stdin)['Rows']}))")" = "flac" ] \
   && [ "$(api 'Inventory/Items?mediaType=Movie' \
        | field "all(r['Values'].get('videoCodec') for r in json.load(sys.stdin)['Rows'])")" = "True" ] \
   && [ "$(api 'Inventory/Items?mediaType=Series&level=Episode' \
        | field "all(r['Values'].get('videoCodec') for r in json.load(sys.stdin)['Rows']
                     if r['Values']['name'] != 'Patchy S01E06')")" = "True" ]; do
    i=$((i + 1))
    [ "$i" -gt 60 ] && { echo; echo "media was never analyzed" >&2; api 'Inventory/Items?mediaType=MusicAlbum'; exit 1; }
    [ $((i % 5)) = 0 ] && curl -sf -X POST "$BASE/Library/Refresh" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"" >/dev/null 2>&1
    printf '.'
    sleep 3
done
echo

echo "== checks =="
check "the plugin serves the image its meta.json names" \
    "$(curl -s --max-time 30 -o /dev/null -w '%{http_code} %{content_type}' \
        "$BASE/Plugins/$(field "json.load(open('$WORK/config/plugins/Inventory/meta.json'))['guid']" </dev/null)/9.9.9.0/Image")" \
    "200 image/png"
SCHEMA=$(api 'Inventory/Schema')
check "movie count" \
    "$(printf '%s\n' "$SCHEMA" | field "[t['Count'] for t in json.load(sys.stdin)['MediaTypes'] if t['MediaType']=='Movie'][0]")" "7"
check "seasons and episodes are not tabs of their own" \
    "$(printf '%s\n' "$SCHEMA" | field "','.join(t['MediaType'] for t in json.load(sys.stdin)['MediaTypes'])")" "Movie,Series,MusicAlbum,Book,Photo"
check "music is counted in tracks, the one filed loose among them" \
    "$(printf '%s\n' "$SCHEMA" | field "[t['Count'] for t in json.load(sys.stdin)['MediaTypes'] if t['MediaType']=='MusicAlbum'][0]")" "3"
check "an album breaks down into its tracks" \
    "$(printf '%s\n' "$SCHEMA" | field "','.join(l['Level'] for t in json.load(sys.stdin)['MediaTypes'] if t['MediaType']=='MusicAlbum' for l in t['Levels'])")" "MusicAlbum,Audio"
check "a book has no level below it" \
    "$(printf '%s\n' "$SCHEMA" | field "len([l for t in json.load(sys.stdin)['MediaTypes'] if t['MediaType']=='Book' for l in t['Levels']])")" "1"
check "series offers its three levels" \
    "$(printf '%s\n' "$SCHEMA" | field "','.join(l['Level'] for t in json.load(sys.stdin)['MediaTypes'] if t['MediaType']=='Series' for l in t['Levels'])")" "Series,Season,Episode"
check "columns are offered" \
    "$(printf '%s\n' "$SCHEMA" | field "len(json.load(sys.stdin)['Columns']) > 30")" "True"
check "an extra sitting beside a film is not an item of its own" \
    "$(api 'Inventory/Items?mediaType=Movie&search=Making' | field "json.load(sys.stdin)['TotalCount']")" "0"
FEATURE=$(wc -c < "$WORK/media/movies/Blue Harbour (2021)/Blue Harbour (2021).mkv")
check "and its bytes are not added to the film it sits with" \
    "$(api 'Inventory/Items?mediaType=Movie&search=Blue%20Harbour' \
        | field "json.load(sys.stdin)['Rows'][0]['Values']['size']")" "$FEATURE"
check "a movie table starts with the columns it was given" \
    "$(api 'Inventory/Items?mediaType=Movie&limit=1' | field "','.join(c['Key'] for c in json.load(sys.stdin)['Columns'])")" \
    "name,year,size,duration,sizePerHour,totalBitrate,videoCodec,resolution,videoRange,audioCodec,audioLayout"
check "and a track table with its own" \
    "$(api 'Inventory/Items?mediaType=MusicAlbum&level=Audio&limit=1' | field "','.join(c['Key'] for c in json.load(sys.stdin)['Columns'])")" \
    "name,year,size,duration,totalBitrate,audioCodec,audioChannels,audioSampleRate"
check "a sort column that names nothing is refused rather than quietly ignored" \
    "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/Inventory/Items?mediaType=Movie&sortBy=siez" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"")" "400"
check "while asking for no sort at all is how the table loads" \
    "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/Inventory/Items?mediaType=Movie&sortBy=" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"")" "200"
check "every column has a caption rather than falling back to its key" \
    "$(printf '%s\n' "$SCHEMA" | field "all(not c['Label'].startswith('column.') and not c['Group'].startswith('group.') for c in json.load(sys.stdin)['Columns'])")" "True"

# Rows are addressed by name: which row comes first is not something the API promises.
named() { field "[r['Values']['$2'] for r in json.load(sys.stdin)['Rows'] if r['Values'].get('name')=='$1'][0]"; }
identify() { field "[r['Id'] for r in json.load(sys.stdin)['Rows'] if r['Values'].get('name')=='$1'][0]"; }

# The second and third arguments name another user, for the counts that span all of them.
play() {
    curl -sf -X POST "$BASE/UserPlayedItems/$1" \
        -H "Authorization: MediaBrowser Token=\"${2:-$TOKEN}\"" -H "$JSON" -d '{}' >/dev/null 2>&1 \
      || curl -sf -X POST "$BASE/Users/${3:-$USER_ID}/PlayedItems/$1" \
        -H "Authorization: MediaBrowser Token=\"${2:-$TOKEN}\"" -H "$JSON" -d '{}' >/dev/null 2>&1 \
      || { echo "neither played endpoint answered; jellyfin may have renamed it" >&2; exit 1; }
}

MOVIES=$(api 'Inventory/Items?mediaType=Movie&sortBy=size&descending=true')
check "sorted by size" \
    "$(printf '%s\n' "$MOVIES" | field "json.load(sys.stdin)['Rows'][0]['Values']['name']")" "Blue Harbour (2021)"
check "empty cells stay at the end ascending" \
    "$(api 'Inventory/Items?mediaType=Movie&sortBy=audioCodec' \
        | field "(lambda rows: all('audioCodec' in r['Values'] for r in rows) and rows[-1]['Values']['audioCodec'] is None)(json.load(sys.stdin)['Rows'])")" "True"
check "and at the end descending too, rather than being turned around with the values" \
    "$(api 'Inventory/Items?mediaType=Movie&sortBy=audioCodec&descending=true' \
        | field "(lambda rows: all('audioCodec' in r['Values'] for r in rows) and rows[-1]['Values']['audioCodec'] is None)(json.load(sys.stdin)['Rows'])")" "True"
check "hdr10 is read from the stream" \
    "$(printf '%s\n' "$MOVIES" | field "[r['Values']['videoRange'] for r in json.load(sys.stdin)['Rows'] if r['Values']['videoCodec']=='hevc'][0]")" "HDR10"
check "size per hour follows size and runtime" \
    "$(printf '%s\n' "$MOVIES" | field "(lambda v: round(v['sizePerHour']) == round(v['size'] / v['duration'] * 3600))(json.load(sys.stdin)['Rows'][0]['Values'])")" "True"
PARTS=$(cat "$WORK/media/movies/Two Part Feature (2019)"/*.mkv | wc -c)
check "a film split across two files reports the bytes of both" \
    "$(api 'Inventory/Items?mediaType=Movie&search=Two%20Part' \
        | field "json.load(sys.stdin)['Rows'][0]['Values']['size']")" "$PARTS"
check "and the runtime of both" \
    "$(api 'Inventory/Items?mediaType=Movie&search=Two%20Part' \
        | field "round(json.load(sys.stdin)['Rows'][0]['Values']['duration'])")" "10"
VERSIONS=$(cat "$WORK/media/movies/Double Cut (2022)"/*.mkv | wc -c)
check "a film kept in a second cut that is split in two reports every file of both" \
    "$(api 'Inventory/Items?mediaType=Movie&search=Double%20Cut' \
        | field "json.load(sys.stdin)['Rows'][0]['Values']['size']")" "$VERSIONS"
check "and the runtime of one cut, since both are the same film" \
    "$(api 'Inventory/Items?mediaType=Movie&search=Double%20Cut' \
        | field "round(json.load(sys.stdin)['Rows'][0]['Values']['duration'])")" "5"
CUTS=$(cat "$WORK/media/movies/Two Cuts (2019)"/*.mkv | wc -c)
check "and so does one whose own cut is the split one" \
    "$(api 'Inventory/Items?mediaType=Movie&search=Two%20Cuts' \
        | field "json.load(sys.stdin)['Rows'][0]['Values']['size']")" "$CUTS"
check "and runs as long as the cut it was measured from" \
    "$(api 'Inventory/Items?mediaType=Movie&search=Two%20Cuts' \
        | field "round(json.load(sys.stdin)['Rows'][0]['Values']['duration'])")" "10"
check "a film in several cuts takes no rate from bytes and a runtime that measure different files" \
    "$(api 'Inventory/Items?mediaType=Movie&search=Double%20Cut' \
        | field "(lambda v: v['sizePerHour'] is None and 0 < v['totalBitrate'] < v['size'] * 8 / v['duration'])(json.load(sys.stdin)['Rows'][0]['Values'])")" "True"
check "the totals line adds up the runtimes it is showing" \
    "$(printf '%s\n' "$MOVIES" | field "(lambda d: round(d['TotalDuration']) == round(sum(r['Values']['duration'] or 0 for r in d['Rows'])))(json.load(sys.stdin))")" "True"
check "and that runtime is not zero" \
    "$(printf '%s\n' "$MOVIES" | field "json.load(sys.stdin)['TotalDuration'] > 0")" "True"
check "a movie cannot be expanded" \
    "$(printf '%s\n' "$MOVIES" | field "json.load(sys.stdin)['Rows'][0]['Expandable']")" "False"
check "a bitrate is the bytes of a file over its runtime, counted in bits" \
    "$(printf '%s\n' "$MOVIES" | field "(lambda v: v['totalBitrate'] == int(v['size'] * 8 / v['duration']))([r['Values'] for r in json.load(sys.stdin)['Rows'] if r['Values']['name']=='Blue Harbour (2021)'][0])")" "True"
check "a page of no rows is answered with one rather than with none" \
    "$(api 'Inventory/Items?mediaType=Movie&limit=0' | field "len(json.load(sys.stdin)['Rows'])")" "1"
check "a page behind the last one is empty and still counts every row, which the page falls back on" \
    "$(api 'Inventory/Items?mediaType=Movie&startIndex=100' | field "(lambda d: '%s/%s' % (len(d['Rows']), d['TotalCount']))(json.load(sys.stdin))")" "0/7"
check "a level of another tab is refused" \
    "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/Inventory/Items?mediaType=Movie&level=Episode" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"")" "400"
curl -sf -X POST "$BASE/Inventory/Columns?level=AudioBook" \
    -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "$JSON" -d '["size","name"]' >/dev/null || refused "Inventory/Columns?level=AudioBook"
check "a table asked for no order is sorted by its first column" \
    "$(api 'Inventory/Items?mediaType=Movie&columnLevel=AudioBook&sortBy=' \
        | field "(lambda sizes: sizes == sorted(sizes))([r['Values']['size'] for r in json.load(sys.stdin)['Rows']])")" "True"
# A level no fixture fills, so its selection can be set without moving a table checked elsewhere.
curl -sf -X POST "$BASE/Inventory/Columns?level=Video" \
    -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "$JSON" \
    -d '["name","videoProfile","frameRate","bitDepth","pixelFormat","interlaced","audioLayout","audioChannels","audioSampleRate","audioBitrate","dateAdded"]' >/dev/null || refused "Inventory/Columns?level=Video"
STREAMS=$(api 'Inventory/Items?mediaType=Movie&columnLevel=Video')
check "what ffprobe says of a stream is what its row says" \
    "$(printf '%s\n' "$STREAMS" | field "(lambda v: '|'.join(str(v[k]) for k in ('videoProfile', 'frameRate', 'bitDepth', 'pixelFormat', 'interlaced', 'audioLayout', 'audioChannels', 'audioSampleRate')))([r['Values'] for r in json.load(sys.stdin)['Rows'] if r['Values']['name']=='Night Signal (2023)'][0])")" \
    "Main 10|24|10|yuv420p10le|False|5.1|6|44100"
check "and the audio bitrate is the one the track was encoded at" \
    "$(printf '%s\n' "$STREAMS" | field "round([r['Values']['audioBitrate'] for r in json.load(sys.stdin)['Rows'] if r['Values']['name']=='Night Signal (2023)'][0] / 10000)")" "64"
check "a film at 24000/1001 runs at that rate, not at the 1000 its time base reads as" \
    "$(printf '%s\n' "$STREAMS" | field "round([r['Values']['frameRate'] for r in json.load(sys.stdin)['Rows'] if r['Values']['name']=='Blue Harbour (2021)'][0], 3)")" "23.976"
check "paging returns the next rows, not the same ones" \
    "$(api 'Inventory/Items?mediaType=Movie&sortBy=name&limit=1&startIndex=1' \
        | field "json.load(sys.stdin)['Rows'][0]['Values']['name']")" \
    "$(api 'Inventory/Items?mediaType=Movie&sortBy=name&limit=2' \
        | field "json.load(sys.stdin)['Rows'][1]['Values']['name']")"

curl -sf -X POST "$BASE/Inventory/Columns?level=Series" \
    -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "$JSON" \
    -d '["name","children","size","duration","totalBitrate","sizePerHour","height","videoCodec","audioTracks","videoBitrate","subtitleTracks","subtitleLanguages","played","lastPlayed","playCount"]' >/dev/null || refused "Inventory/Columns?level=Series"
SERIES=$(api 'Inventory/Items?mediaType=Series')
check "series totals its episodes" \
    "$(printf '%s\n' "$SERIES" | named 'Harbour Lights' children)" "3"
HARBOUR=$(cat "$WORK/media/shows/Harbour Lights (2022)/Season 01"/*.mkv | wc -c)
check "a series weighs what its episodes weigh on disk" \
    "$(printf '%s\n' "$SERIES" | named 'Harbour Lights' size)" "$HARBOUR"
check "and runs as long as they do" \
    "$(printf '%s\n' "$SERIES" | field "round([r['Values']['duration'] for r in json.load(sys.stdin)['Rows'] if r['Values']['name']=='Harbour Lights'][0])")" "30"
check "series inherits the common codec" \
    "$(printf '%s\n' "$SERIES" | named 'Harbour Lights' videoCodec)" "h264"
check "a series whose episodes differ reports them as mixed, in the caller's language" \
    "$(api 'Inventory/Items?mediaType=Series&culture=de' | named 'Long Run' videoCodec)" "Gemischt"
check "a series totals across its seasons rather than per season" \
    "$(printf '%s\n' "$SERIES" | named 'Long Run' children)" "2"
check "series can be expanded" \
    "$(printf '%s\n' "$SERIES" | field "[r['Expandable'] for r in json.load(sys.stdin)['Rows'] if r['Values']['name']=='Harbour Lights'][0]")" "True"
check "a folder row aggregates the stream counts of its children" \
    "$(printf '%s\n' "$SERIES" | named 'Harbour Lights' audioTracks)" "2"
check "a folder row aggregates the subtitles of its children, by count and by language" \
    "$(printf '%s\n' "$SERIES" | field "(lambda v: '%s/%s' % (v['subtitleTracks'], v['subtitleLanguages']))([r['Values'] for r in json.load(sys.stdin)['Rows'] if r['Values']['name']=='Harbour Lights'][0])")" "1/eng"
check "a folder row aggregates the video bitrate of its children" \
    "$(printf '%s\n' "$SERIES" | field "[r['Values']['videoBitrate'] is not None for r in json.load(sys.stdin)['Rows'] if r['Values']['name']=='Harbour Lights'][0]")" "True"
check "and takes its own bitrate from the bytes and the runtime it adds up" \
    "$(printf '%s\n' "$SERIES" | field "(lambda v: v['totalBitrate'] == int(v['size'] * 8 / v['duration']))([r['Values'] for r in json.load(sys.stdin)['Rows'] if r['Values']['name']=='Harbour Lights'][0])")" "True"
curl -sf -X POST "$BASE/Inventory/Columns?level=MusicVideo" \
    -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "$JSON" \
    -d '["name","series","container","videoCodec","videoProfile","resolution","height","videoBitrate","frameRate","bitDepth","videoRange","dolbyVision","pixelFormat","interlaced","audioCodec","audioLayout","audioChannels","audioBitrate","audioSampleRate","spatialAudio","audioTracks","audioLanguages","subtitleTracks","subtitleLanguages"]' \
    >/dev/null || refused "Inventory/Columns?level=MusicVideo"
api 'Inventory/Items?mediaType=Series&columnLevel=MusicVideo' > "$WORK/folders.json"
api 'Inventory/Items?mediaType=Series&level=Episode&columnLevel=MusicVideo' > "$WORK/leaves.json"
check "every column of a series is the value all its episodes share, mixed where they differ, empty where none has one" \
    "$(python3 -c "
import json
folders = json.load(open('$WORK/folders.json'))['Rows']
leaves = [r['Values'] for r in json.load(open('$WORK/leaves.json'))['Rows']]
word = lambda v: None if v is None else str(v).lower()
wrong = []
for folder in folders:
    below = [v for v in leaves if v['series'] == folder['Values']['name']]
    for key, got in folder['Values'].items():
        if key in ('name', 'series'):
            continue
        present = [v[key] for v in below if v[key] is not None]
        agreed = len({word(v) for v in present}) == 1 and len(present) == len(below)
        want = None if not present else (present[0] if agreed else 'Mixed')
        if word(got) != word(want):
            wrong.append((folder['Values']['name'], key, got, want))
print('ok' if folders and below and not wrong else wrong)")" "ok"

SERIES_ID=$(printf '%s\n' "$SERIES" | identify 'Harbour Lights')
SEASONS=$(api "Inventory/Items?mediaType=Series&level=Season&parentIds=$SERIES_ID")
check "expanding a series yields its season" \
    "$(printf '%s\n' "$SEASONS" | field "json.load(sys.stdin)['TotalCount']")" "1"
SEASON_ID=$(printf '%s\n' "$SEASONS" | field "json.load(sys.stdin)['Rows'][0]['Id']")
EPISODES=$(api "Inventory/Items?mediaType=Series&level=Episode&parentIds=$SEASON_ID")
check "expanding a season yields its episodes" \
    "$(printf '%s\n' "$EPISODES" | field "json.load(sys.stdin)['TotalCount']")" "3"
check "an episode cannot be expanded" \
    "$(printf '%s\n' "$EPISODES" | field "json.load(sys.stdin)['Rows'][0]['Expandable']")" "False"
# The three episodes weigh the same, so nothing but the tie break decides their order.
check "episodes of equal size come back in episode order" \
    "$(api "Inventory/Items?mediaType=Series&level=Episode&parentIds=$SEASON_ID&sortBy=size" \
        | field "','.join(r['Values']['name'][-3:] for r in json.load(sys.stdin)['Rows'])")" "E01,E02,E03"
check "and reversing the column does not shuffle them" \
    "$(api "Inventory/Items?mediaType=Series&level=Episode&parentIds=$SEASON_ID&sortBy=size&descending=true" \
        | field "','.join(r['Values']['name'][-3:] for r in json.load(sys.stdin)['Rows'])")" "E01,E02,E03"
# Sorted by the parent table's first column, a renamed episode would leave its place.
EPISODE_ID=$(printf '%s\n' "$EPISODES" | field "json.load(sys.stdin)['Rows'][-1]['Id']")
curl -sf "$BASE/Items/$EPISODE_ID" -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -o "$WORK/episode.json" \
    || refused "Items/$EPISODE_ID" GET
python3 -c "
import json
item = json.load(open('$WORK/episode.json'))
item['Name'] = 'Aaa Renamed Episode'
json.dump(item, open('$WORK/episode-renamed.json', 'w'))"
curl -sf -X POST "$BASE/Items/$EPISODE_ID" -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "$JSON" \
    -d @"$WORK/episode-renamed.json" >/dev/null || refused "Items/$EPISODE_ID"
i=0
until [ "$(api "Inventory/Items?mediaType=Series&level=Episode&parentIds=$SEASON_ID&sortBy=name" \
    | field "json.load(sys.stdin)['Rows'][0]['Values']['name']")" = "Aaa Renamed Episode" ] || [ "$i" -gt 15 ]; do
    i=$((i + 1))
    sleep 1
done
check "an unsorted expansion keeps episode order whatever the episodes are called" \
    "$(api "Inventory/Items?mediaType=Series&level=Episode&parentIds=$SEASON_ID&columnLevel=Series" \
        | field "json.load(sys.stdin)['Rows'][-1]['Values']['name']")" "Aaa Renamed Episode"
check "and asking for a sort still sorts them" \
    "$(api "Inventory/Items?mediaType=Series&level=Episode&parentIds=$SEASON_ID&columnLevel=Series&sortBy=name" \
        | field "json.load(sys.stdin)['Rows'][0]['Values']['name']")" "Aaa Renamed Episode"
curl -sf -X POST "$BASE/Items/$EPISODE_ID" -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "$JSON" \
    -d @"$WORK/episode.json" >/dev/null || refused "Items/$EPISODE_ID"
i=0
until [ "$(printf '%s\n' "$(api "Inventory/Items?mediaType=Series&level=Episode&parentIds=$SEASON_ID")" \
    | field "json.load(sys.stdin)['Rows'][-1]['Values']['name'][-3:]")" = "E03" ] || [ "$i" -gt 15 ]; do
    i=$((i + 1))
    sleep 1
done
check "and the name given back is the one the table shows again" \
    "$(api "Inventory/Items?mediaType=Series&level=Episode&parentIds=$SEASON_ID" \
        | field "','.join(r['Values']['name'][-3:] for r in json.load(sys.stdin)['Rows'])")" "E01,E02,E03"

check "the season level names the series, which its own name does not" \
    "$(api 'Inventory/Items?mediaType=Series&level=Season&sortBy=series' \
        | field "json.load(sys.stdin)['Rows'][0]['Values']['series']")" "Harbour Lights"
check "children keep the columns of the table they are shown in" \
    "$(api "Inventory/Items?mediaType=Series&level=Episode&parentIds=$SEASON_ID&columnLevel=Series" \
        | field "','.join(c['Key'] for c in json.load(sys.stdin)['Columns'])")" \
    "$(api 'Inventory/Items?mediaType=Series&limit=1' | field "','.join(c['Key'] for c in json.load(sys.stdin)['Columns'])")"

ALBUM=$(api 'Inventory/Items?mediaType=MusicAlbum')
check "album totals its tracks" \
    "$(printf '%s\n' "$ALBUM" | named 'Test Pattern' children)" "2"
check "album inherits the track codec" \
    "$(printf '%s\n' "$ALBUM" | named 'Test Pattern' audioCodec)" "flac"
check "album can be expanded" \
    "$(printf '%s\n' "$ALBUM" | field "[r['Expandable'] for r in json.load(sys.stdin)['Rows'] if r['Values']['name']=='Test Pattern'][0]")" "True"
ALBUM_ID=$(printf '%s\n' "$ALBUM" | identify 'Test Pattern')
check "expanding an album yields its tracks" \
    "$(api "Inventory/Items?mediaType=MusicAlbum&level=Audio&parentIds=$ALBUM_ID" | field "json.load(sys.stdin)['TotalCount']")" "2"
check "a track filed loose beside the albums is listed with them, since no row opens to reach it" \
    "$(printf '%s\n' "$ALBUM" | field "(lambda d: '%s/%s' % (d['TotalCount'], [r['Expandable'] for r in d['Rows'] if r['Values']['name']=='Loose Single']))(json.load(sys.stdin))")" "2/[False]"
check "and the totals weigh it along with the albums" \
    "$(printf '%s\n' "$ALBUM" | field "json.load(sys.stdin)['TotalSize']")" \
    "$(find "$WORK/media/music" -name '*.flac' -exec cat {} + | wc -c)"
check "and so does the export" \
    "$(curl -sf "$BASE/Inventory/Export?mediaType=MusicAlbum&format=csv" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"" | python3 -c "
import csv, io, sys
rows = list(csv.reader(io.StringIO(sys.stdin.buffer.read().decode('utf-8-sig'))))
print(','.join(sorted(r[0] for r in rows[1:])))")" "Loose Single,Test Pattern"
curl -sf -X POST "$BASE/Inventory/Columns?level=Photo" \
    -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "$JSON" \
    -d '["name","size","container","resolution","height"]' >/dev/null || refused "Inventory/Columns?level=Photo"
PHOTOS=$(api 'Inventory/Items?mediaType=Photo&sortBy=size&descending=true')
check "a photo reports the dimensions jellyfin read off the file" \
    "$(printf '%s\n' "$PHOTOS" | field "json.load(sys.stdin)['Rows'][0]['Values']['resolution']")" "4032x3024"
check "and the size that goes with them" \
    "$(printf '%s\n' "$PHOTOS" | field "json.load(sys.stdin)['Rows'][0]['Values']['height']")" "3024"
check "a file jellyfin records no container for is named after one" \
    "$(printf '%s\n' "$PHOTOS" | field "json.load(sys.stdin)['Rows'][0]['Values']['container']")" "jpg"
check "which holds for a book too" \
    "$(api 'Inventory/Items?mediaType=Book' | field "json.load(sys.stdin)['Rows'][0]['Values']['container']")" "epub"
check "a row names the library it was found in" \
    "$(api 'Inventory/Items?mediaType=Book' | field "json.load(sys.stdin)['Rows'][0]['Values']['library']")" "Books"
check "and one of the same kind in another library names that one" \
    "$(api 'Inventory/Items?mediaType=Book' | named 'The Second Shelf' library)" "Shelf"
check "a book is not given a size per hour" \
    "$(api 'Inventory/Items?mediaType=Book' | field "'sizePerHour' in [c['Key'] for c in json.load(sys.stdin)['Columns']]")" "False"
curl -sf -X POST "$BASE/Inventory/Columns?level=Book" \
    -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "$JSON" \
    -d '["name","container","videoCodec","audioTracks"]' >/dev/null || refused "Inventory/Columns?level=Book"
check "a book carries none of the columns that are read off a stream" \
    "$(api 'Inventory/Items?mediaType=Book' \
        | field "(lambda v: v['videoCodec'] is None and v['audioTracks'] is None)(json.load(sys.stdin)['Rows'][0]['Values'])")" "True"

check "the totals count a match once, not once per level it was found on" \
    "$(api 'Inventory/Items?mediaType=Series&search=Long%20Run' \
        | field "json.load(sys.stdin)['TotalSize']")" \
    "$(api 'Inventory/Items?mediaType=Series' | named 'Long Run' size)"
check "search reaches a row through its path when its name carries nothing" \
    "$(api 'Inventory/Items?mediaType=Series&search=2020' | field "json.load(sys.stdin)['TotalCount']")" "5"
check "and reports every matching row it found" \
    "$(api 'Inventory/Items?mediaType=Series&search=Long%20Run' | field "json.load(sys.stdin)['TotalCount']")" "5"
check "an export adds up to the total the table shows, rather than to the levels put together" \
    "$(curl -sf "$BASE/Inventory/Export?mediaType=Series&format=csv&search=Long%20Run" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"" | python3 -c "
import csv, io, sys
rows = list(csv.reader(io.StringIO(sys.stdin.buffer.read().decode('utf-8-sig'))))
size = rows[0].index('Size')
print(sum(int(r[size] or 0) for r in rows[1:]))")" \
    "$(api 'Inventory/Items?mediaType=Series&search=Long%20Run' | field "json.load(sys.stdin)['TotalSize']")"
check "a number the children disagree on is worded, not left looking unrecorded" \
    "$(api 'Inventory/Items?mediaType=Series&culture=de' | named 'Long Run' height)" "Gemischt"
check "and one they agree on is the value itself" \
    "$(api 'Inventory/Items?mediaType=Series' | named 'Harbour Lights' height)" "1080"
PATCHY=$(api 'Inventory/Items?mediaType=Series&culture=de')
check "a folder whose items are not all measured reports no rate rather than a wrong one" \
    "$(printf '%s\n' "$PATCHY" | named 'Patchy' totalBitrate)" "None"
check "and no size per hour either" \
    "$(printf '%s\n' "$PATCHY" | named 'Patchy' sizePerHour)" "None"
check "a file that was never probed reports no track count rather than none at all" \
    "$(api 'Inventory/Items?mediaType=Series&level=Episode&columnLevel=Series' \
        | named 'Patchy S01E06' audioTracks)" "None"
check "a codec only some of the items below carry is not read as all of them" \
    "$(printf '%s\n' "$PATCHY" | named 'Patchy' videoCodec)" "Gemischt"
check "while a rate over items that are all measured is still given" \
    "$(api 'Inventory/Items?mediaType=Series' \
        | field "[r['Values']['totalBitrate'] is not None for r in json.load(sys.stdin)['Rows'] if r['Values']['name']=='Harbour Lights'][0]")" "True"
check "resolution sorts by how many pixels it is, not by how the text reads" \
    "$(api 'Inventory/Items?mediaType=Photo&sortBy=resolution' \
        | field "json.load(sys.stdin)['Rows'][0]['Values']['resolution']")" "800x600"
check "umlauts sort where the language puts them, not where their code point does" \
    "$(api 'Inventory/Items?mediaType=Movie&sortBy=name' \
        | field "(lambda n: n.index([x for x in n if x.startswith(chr(196))][0]) < n.index('Blue Harbour (2021)'))([r['Values']['name'] for r in json.load(sys.stdin)['Rows']])")" "True"

check "search narrows the rows" \
    "$(api 'Inventory/Items?mediaType=Series&level=Episode&search=S01E02' | field "json.load(sys.stdin)['TotalCount']")" "1"
check "search from the series view reaches the episodes below it" \
    "$(api 'Inventory/Items?mediaType=Series&search=S01E02' | field "json.load(sys.stdin)['TotalCount']")" "1"
# The conditions travel as JSON, which a query string has to have escaped.
filtered() { python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$1"; }
names() { field "','.join(sorted(r['Values']['name'] for r in json.load(sys.stdin)['Rows']))"; }

HEVC=$(filtered '[{"column":"videoCodec","op":"eq","value":"hevc"}]')
check "a filter keeps the rows that meet it" \
    "$(api "Inventory/Items?mediaType=Movie&filters=$HEVC" | names)" "Night Signal (2023)"
check "and the totals are those of what is left" \
    "$(api "Inventory/Items?mediaType=Movie&filters=$HEVC" | field "json.load(sys.stdin)['TotalSize']")" \
    "$(wc -c < "$WORK/media/movies/Night Signal (2023)/Night Signal (2023).mkv" | tr -d ' ')"
check "a number is held against the value it was given" \
    "$(api "Inventory/Items?mediaType=Movie&filters=$(filtered '[{"column":"height","op":"ge","value":1080}]')" | names)" \
    "Blue Harbour (2021),Night Signal (2023)"
check "text is held against the value whatever its case" \
    "$(api "Inventory/Items?mediaType=Movie&filters=$(filtered '[{"column":"videoCodec","op":"eq","value":"HEVC"}]')" | names)" "Night Signal (2023)"
check "a rate is held against the digits the table shows, not the ones it is kept as" \
    "$(api "Inventory/Items?mediaType=Movie&filters=$(filtered '[{"column":"frameRate","op":"eq","value":23.976}]')" | names)" "Blue Harbour (2021)"
check "a truth value that is false is a value, not an empty cell" \
    "$(api "Inventory/Items?mediaType=Movie&filters=$(filtered '[{"column":"interlaced","op":"eq","value":false}]')" \
        | field "json.load(sys.stdin)['TotalCount']")" "7"
check "several conditions all have to be met" \
    "$(api "Inventory/Items?mediaType=Movie&filters=$(filtered '[{"column":"height","op":"ge","value":"1080"},{"column":"audioCodec","op":"contains","value":"AAC"}]')" | names)" \
    "Blue Harbour (2021)"
check "an empty cell meets a negated condition, since it does not hold the value either" \
    "$(api "Inventory/Items?mediaType=Movie&filters=$(filtered '[{"column":"audioCodec","op":"notContains","value":"aac"}]')" \
        | field "json.load(sys.stdin)['TotalCount']")/$(api "Inventory/Items?mediaType=Movie&filters=$(filtered '[{"column":"audioCodec","op":"ne","value":"aac"}]')" \
        | field "json.load(sys.stdin)['TotalCount']")" "3/3"
check "a bound belongs to the range it closes" \
    "$(api "Inventory/Items?mediaType=Movie&filters=$(filtered '[{"column":"height","op":"le","value":1080}]')" \
        | field "json.load(sys.stdin)['TotalCount']")/$(api "Inventory/Items?mediaType=Movie&filters=$(filtered '[{"column":"height","op":"le","value":1079}]')" \
        | field "json.load(sys.stdin)['TotalCount']")" "6/5"
check "a number only some of the items below carry is not read as all of them" \
    "$(api "Inventory/Items?mediaType=Series&filters=$(filtered '[{"column":"height","op":"ge","value":0}]')" | names)" "Harbour Lights"
check "an episode is found by its season and by its number" \
    "$(api "Inventory/Items?mediaType=Series&level=Episode&columnLevel=Series&filters=$(filtered '[{"column":"season","op":"eq","value":2}]')" | names)/$(api "Inventory/Items?mediaType=Series&level=Episode&columnLevel=Series&filters=$(filtered '[{"column":"episode","op":"eq","value":5}]')" | names)" \
    "Long Run S02E01/Patchy S01E05"
check "a film is found by its year" \
    "$(api "Inventory/Items?mediaType=Movie&filters=$(filtered '[{"column":"year","op":"eq","value":2021}]')" | names)" "Blue Harbour (2021)"
check "a track that names no language is found as undetermined" \
    "$(api "Inventory/Items?mediaType=Movie&filters=$(filtered '[{"column":"audioLanguages","op":"eq","value":"und"}]')" \
        | field "json.load(sys.stdin)['TotalCount']")" "5"
check "search ignores case" \
    "$(api 'Inventory/Items?mediaType=Series&search=long%20run' | field "json.load(sys.stdin)['TotalCount']")" "5"
check "a cell can be asked whether it holds anything at all" \
    "$(api "Inventory/Items?mediaType=Movie&filters=$(filtered '[{"column":"audioCodec","op":"empty"}]')" \
        | field "json.load(sys.stdin)['TotalCount']")/$(api "Inventory/Items?mediaType=Movie&filters=$(filtered '[{"column":"audioCodec","op":"notEmpty"}]')" \
        | field "json.load(sys.stdin)['TotalCount']")" "2/5"
check "a date is held against the day" \
    "$(api "Inventory/Items?mediaType=Movie&filters=$(filtered '[{"column":"dateAdded","op":"ge","value":"2000-01-01"}]')" \
        | field "json.load(sys.stdin)['TotalCount']")/$(api "Inventory/Items?mediaType=Movie&filters=$(filtered '[{"column":"dateAdded","op":"le","value":"2000-01-01"}]')" \
        | field "json.load(sys.stdin)['TotalCount']")" "7/0"
ADDED=$(printf '%s\n' "$STREAMS" | field "[r['Values']['dateAdded'][:10] for r in json.load(sys.stdin)['Rows'] if r['Values']['name']=='Night Signal (2023)'][0]")
check "and a day is met by every hour of it" \
    "$(api "Inventory/Items?mediaType=Movie&filters=$(filtered "[{\"column\":\"dateAdded\",\"op\":\"eq\",\"value\":\"$ADDED\"}]")" \
        | field "'Night Signal (2023)' in [r['Values']['name'] for r in json.load(sys.stdin)['Rows']]")" "True"
check "a folder whose children disagree meets no condition on that column, not even a negated one" \
    "$(api "Inventory/Items?mediaType=Series&filters=$(filtered '[{"column":"videoCodec","op":"ne","value":"hevc"}]')" | names)" \
    "Harbour Lights"
check "nor does it read as empty, or as holding something" \
    "$(api "Inventory/Items?mediaType=Series&filters=$(filtered '[{"column":"videoCodec","op":"empty"}]')" \
        | field "json.load(sys.stdin)['TotalCount']")/$(api "Inventory/Items?mediaType=Series&filters=$(filtered '[{"column":"videoCodec","op":"notEmpty"}]')" | names)" \
    "0/Harbour Lights"
check "while the level below it is filtered file by file" \
    "$(api "Inventory/Items?mediaType=Series&level=Episode&columnLevel=Series&filters=$HEVC" | names)" "Long Run S02E01"
check "a search across the levels is filtered on each of them, and still weighs a file once" \
    "$(api "Inventory/Items?mediaType=Series&search=Long%20Run&filters=$HEVC" \
        | field "(lambda d: '%s/%s' % (d['TotalCount'], d['TotalSize']))(json.load(sys.stdin))")" \
    "2/$(wc -c < "$WORK/media/shows/Long Run (2020)/Season 02/Long Run S02E01.mkv" | tr -d ' ')"
check "the children of a row are filtered as well" \
    "$(api "Inventory/Items?mediaType=Series&level=Season&parentIds=$(printf '%s\n' "$SERIES" | identify 'Long Run')&filters=$HEVC" \
        | field "json.load(sys.stdin)['TotalCount']")" "1"
check "an export is filtered the way the table is" \
    "$(curl -sf "$BASE/Inventory/Export?mediaType=Movie&format=csv&filters=$HEVC" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"" | python3 -c "
import csv, io, sys
rows = list(csv.reader(io.StringIO(sys.stdin.buffer.read().decode('utf-8-sig'))))
print(','.join(r[0] for r in rows[1:]))")" "Night Signal (2023)"
for bad in '[{"column":"siez","op":"ge","value":"1"}]' '[{"column":"height","op":"contains","value":"1"}]' \
    '[{"column":"height","op":"ge","value":"tall"}]' '[{"column":"name","op":"contains"}]' '{"column":"name"}' 'not json' \
    '[{"column":"name","op":"ge","value":"a"}]' '[{"column":"interlaced","op":"ne","value":true}]' \
    '[{"column":"size","op":"ge","value":"Infinity"}]' '[null]' '[{"column":"size","op":"eq","value":1}]' \
    '[{"column":"name","op":"contains","value":"\ud800"}]'; do
    check "a filter that cannot be read is refused: $bad" \
        "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/Inventory/Items?mediaType=Movie&filters=$(filtered "$bad")" \
            -H "Authorization: MediaBrowser Token=\"$TOKEN\"")" "400"
done
check "more conditions than a request may carry are refused, not cut short" \
    "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/Inventory/Items?mediaType=Movie&filters=$(filtered "$(python3 -c "
import json
print(json.dumps([{'column': 'name', 'op': 'contains', 'value': 'a'}] * 21))")")" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"")" "400"
check "while exactly as many are taken" \
    "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/Inventory/Items?mediaType=Movie&filters=$(filtered "$(python3 -c "
import json
print(json.dumps([{'column': 'name', 'op': 'contains', 'value': 'a'}] * 20))")")" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"")" "200"
check "and the schema says how many that is" \
    "$(printf '%s\n' "$SCHEMA" | field "json.load(sys.stdin)['MaxFilters']")" "20"
check "an export refuses a filter it cannot read, rather than writing every row" \
    "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/Inventory/Export?mediaType=Movie&format=csv&filters=$(filtered '[{"column":"siez","op":"ge","value":"1"}]')" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"")" "400"
check "the schema says which conditions a column can be held against" \
    "$(printf '%s\n' "$SCHEMA" | field "' '.join('%s=%s' % (c['Key'], ','.join(c['Operators'])) for c in json.load(sys.stdin)['Columns'] if c['Key'] in ('name', 'size', 'height', 'played'))")" \
    "name=contains,notContains,eq,ne,empty,notEmpty size=ge,le,empty,notEmpty height=ge,le,eq,ne,empty,notEmpty played=eq,empty,notEmpty"

check "album totals the channel count of its tracks" \
    "$(api 'Inventory/Items?mediaType=MusicAlbum' | named 'Test Pattern' audioChannels)" "1"

curl -sf -X POST "$BASE/Inventory/Columns?level=Episode" \
    -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "$JSON" \
    -d '["name","audioLanguages","no-such-column"]' >/dev/null || refused "Inventory/Columns?level=Episode"
PICKED=$(api 'Inventory/Items?mediaType=Series&level=Episode&limit=1')
check "stored columns are honored, in the order they were given" \
    "$(printf '%s\n' "$PICKED" | field "','.join(c['Key'] for c in json.load(sys.stdin)['Columns'])")" "name,audioLanguages"

curl -sf -X POST "$BASE/Inventory/Columns?level=Episode" \
    -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "$JSON" \
    -d '["audioLanguages","name"]' >/dev/null || refused "Inventory/Columns?level=Episode"
check "a reordered selection keeps its order" \
    "$(api 'Inventory/Items?mediaType=Series&level=Episode&limit=1' | field "','.join(c['Key'] for c in json.load(sys.stdin)['Columns'])")" "audioLanguages,name"
check "both audio languages are listed, in a stable order" \
    "$(printf '%s\n' "$PICKED" | field "json.load(sys.stdin)['Rows'][0]['Values']['audioLanguages']")" "deu, eng"

SERIES_IDS=$(api 'Inventory/Items?mediaType=Series' | field "','.join(r['Id'] for r in json.load(sys.stdin)['Rows'])")
BOTH=$(api "Inventory/Items?mediaType=Series&level=Season&parentIds=$SERIES_IDS")
check "several parents in one call return every season between them" \
    "$(printf '%s\n' "$BOTH" | field "json.load(sys.stdin)['TotalCount']")" "4"
check "each returned child names the parent it belongs to" \
    "$(printf '%s\n' "$BOTH" | field "len({r['ParentId'] for r in json.load(sys.stdin)['Rows']})")" "3"
check "a parentIds list that holds nothing usable is rejected" \
    "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/Inventory/Items?mediaType=Series&level=Season&parentIds=not-an-id" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"")" "400"
check "and so is one with a single id that is not one, rather than answered for the others" \
    "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/Inventory/Items?mediaType=Series&level=Season&parentIds=$SERIES_ID,not-an-id" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"")" "400"

curl -sf -X POST "$BASE/Inventory/Expand?mediaType=Series&level=Episode" \
    -H "Authorization: MediaBrowser Token=\"$TOKEN\"" >/dev/null || refused "Inventory/Expand?mediaType=Series&level=Episode"
check "how far a tab is expanded is remembered" \
    "$(api 'Inventory/Schema' | field "[t['ExpandedTo'] for t in json.load(sys.stdin)['MediaTypes'] if t['MediaType']=='Series'][0]")" "Episode"
check "the schema says how each column is to be formatted" \
    "$(api 'Inventory/Schema' | field "','.join(sorted('%s=%s' % (c['Key'], c['Format']) for c in json.load(sys.stdin)['Columns'] if c['Key'] in ('size', 'duration', 'sizePerHour', 'dateAdded', 'played')))")" \
    "dateAdded=Date,duration=Duration,played=Boolean,size=Bytes,sizePerHour=BytesPerHour"
check "a level that does not belong is rejected" \
    "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/Inventory/Expand?mediaType=Movie&level=Episode" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"")" "400"
check "storing answers with a body, which the web client needs to read" \
    "$(curl -s -X POST "$BASE/Inventory/Expand?mediaType=Series&level=Season" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"" | field "json.load(sys.stdin)['Level']")" "Season"

for entry in "de:Größe/Stunde" "es:Tamaño/hora" "fr:Taille/heure" "it:Dimensione/ora"; do
    lang=${entry%%:*}
    expected=${entry#*:}
    check "$lang headers" \
        "$(api "Inventory/Schema?culture=$lang" | field "[c['Label'] for c in json.load(sys.stdin)['Columns'] if c['Key']=='sizePerHour'][0]")" "$expected"
done
check "an unsupported language reports the culture it was answered in" \
    "$(api 'Inventory/Schema?culture=xx-XX' | field "json.load(sys.stdin)['Culture']")" "en"
check "and a regional variant reports its language" \
    "$(api 'Inventory/Schema?culture=fr-CA' | field "json.load(sys.stdin)['Culture']")" "fr"
check "a regional variant uses its language file" \
    "$(api 'Inventory/Schema?culture=fr-CA' | field "[c['Label'] for c in json.load(sys.stdin)['Columns'] if c['Key']=='sizePerHour'][0]")" "Taille/heure"
check "german tab captions" \
    "$(api 'Inventory/Schema?culture=de-DE' | field "[t['Label'] for t in json.load(sys.stdin)['MediaTypes'] if t['MediaType']=='Series'][0]")" "Serien"
check "an unknown culture falls back to english" \
    "$(api 'Inventory/Schema?culture=xx-XX' | field "[c['Label'] for c in json.load(sys.stdin)['Columns'] if c['Key']=='sizePerHour'][0]")" "Size/hour"
check "the page title is translated too" \
    "$(api 'Inventory/Schema?culture=de' | field "json.load(sys.stdin)['Strings']['Title']")" "Inventar"
check "interface strings ship with the schema" \
    "$(api 'Inventory/Schema?culture=de' | field "json.load(sys.stdin)['Strings']['Search']")" "Suche"

check "playback columns are offered" \
    "$(printf '%s\n' "$SCHEMA" | field "','.join(c['Key'] for c in json.load(sys.stdin)['Columns'] if c['GroupKey']=='Playback')")" \
    "lastPlayed,everyoneLastPlayed,playCount,everyonePlayCount,played,everyonePlayed"
curl -sf -X POST "$BASE/Inventory/Columns?level=Movie" \
    -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "$JSON" \
    -d '["name","size","lastPlayed","playCount","played"]' >/dev/null || refused "Inventory/Columns?level=Movie"
check "an unplayed item counts no plays, which a filter and a sort can hold it by" \
    "$(api 'Inventory/Items?mediaType=Movie&limit=1' | field "json.load(sys.stdin)['Rows'][0]['Values']['playCount']")/$(api "Inventory/Items?mediaType=Movie&filters=$(filtered '[{"column":"playCount","op":"le","value":0}]')" \
        | field "json.load(sys.stdin)['TotalCount']")" "0/7"
check "an unplayed item is not marked played" \
    "$(api 'Inventory/Items?mediaType=Movie&limit=1' | field "json.load(sys.stdin)['Rows'][0]['Values']['played']")" "False"

MOVIE_ID=$(api 'Inventory/Items?mediaType=Movie&limit=1' | field "json.load(sys.stdin)['Rows'][0]['Id']")
play "$MOVIE_ID"
play "$(api 'Inventory/Items?mediaType=Series&level=Episode&search=Long%20Run%20S01E01' | field "json.load(sys.stdin)['Rows'][0]['Id']")"
sleep 2
check "marking an item played shows up in the table" \
    "$(api 'Inventory/Items?mediaType=Movie&sortBy=played&descending=true&limit=1' | field "json.load(sys.stdin)['Rows'][0]['Values']['played']")" "True"

for episode in $(api 'Inventory/Items?mediaType=Series&level=Episode&search=Harbour%20Lights' \
    | field "' '.join(r['Id'] for r in json.load(sys.stdin)['Rows'])"); do
    play "$episode"
done
sleep 2
# Jellyfin keeps no playback record on a series or a season; both are folded from the episodes.
WATCHED=$(api 'Inventory/Items?mediaType=Series')
check "a series whose episodes have all been played is played" \
    "$(printf '%s\n' "$WATCHED" | named 'Harbour Lights' played)" "True"
check "and it counts the plays underneath it" \
    "$(printf '%s\n' "$WATCHED" | named 'Harbour Lights' playCount)" "3"
check "and dates itself by the last of them" \
    "$(printf '%s\n' "$WATCHED" | field "[r['Values']['lastPlayed'] is not None for r in json.load(sys.stdin)['Rows'] if r['Values']['name']=='Harbour Lights'][0]")" "True"
check "a series with an episode left over is not played" \
    "$(printf '%s\n' "$WATCHED" | named 'Long Run' played)" "False"
check "though it counts the play it has" \
    "$(printf '%s\n' "$WATCHED" | named 'Long Run' playCount)" "1"
check "and of its seasons only the one played through is played" \
    "$(api "Inventory/Items?mediaType=Series&level=Season&columnLevel=Series&parentIds=$(printf '%s\n' "$WATCHED" | identify 'Long Run')" \
        | field "','.join(str(r['Values']['played']) for r in json.load(sys.stdin)['Rows'])")" "True,False"
check "a season is played once its own episodes are" \
    "$(api "Inventory/Items?mediaType=Series&level=Season&columnLevel=Series&parentIds=$(printf '%s\n' "$WATCHED" | identify 'Harbour Lights')" \
        | field "json.load(sys.stdin)['Rows'][0]['Values']['played']")" "True"

curl -sf "$BASE/Inventory/Export?mediaType=Movie&format=csv" \
    -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -o "$WORK/export.csv" || refused "Inventory/Export?format=csv" GET
check "csv export carries a header and every row" \
    "$(wc -l < "$WORK/export.csv" | tr -d ' ')" "8"
check "csv export is utf-8 with the mark excel needs, and crlf line endings" \
    "$(python3 -c "
data = open('$WORK/export.csv', 'rb').read()
print('ok' if data[:3] == b'\xef\xbb\xbf' and data.count(b'\r\n') == 8 else repr(data[:16]))")" "ok"
check "a title a spreadsheet would evaluate is written as text" \
    "$(python3 -c "
import csv, io
rows = list(csv.reader(io.StringIO(open('$WORK/export.csv', encoding='utf-8-sig').read())))
print(([r[0] for r in rows[1:] if 'Formula Trap' in r[0]] or ['missing'])[0])")" "'=Formula Trap (2024)"
check "no exported cell is handed to the spreadsheet as a formula" \
    "$(python3 -c "
import csv, io, re
text = open('$WORK/export.csv', encoding='utf-8-sig').read()
bad = [c for row in csv.reader(io.StringIO(text)) for c in row
       if c[:1] in ('=', '+', '@', '-', '\t', '\r') and not re.fullmatch(r'-?[\d.,]+', c)]
print('ok' if not bad else bad)")" "ok"
# The second column, because the first one is called Name in both languages, and a semicolon
# because german numbers use the comma the fields would otherwise be split on.
check "the export follows the language it was asked for" \
    "$(curl -sf "$BASE/Inventory/Export?mediaType=Movie&format=csv&culture=de" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"" | head -1 | tr -d '\r' | cut -d';' -f2)" "Größe"
check "a truth value is written in the language of the header beside it" \
    "$(curl -sf "$BASE/Inventory/Export?mediaType=Movie&format=csv&culture=de" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"" | python3 -c "
import csv, io, sys
rows = list(csv.reader(io.StringIO(sys.stdin.buffer.read().decode('utf-8-sig')), delimiter=';'))
played = rows[0].index('Vollständig gesehen')
values = {r[played] for r in rows[1:]}
print('ok' if 'Ja' in values and not values & {'true', 'false'} else sorted(values))")" "ok"

curl -sf -X POST "$BASE/Inventory/Columns?level=Episode" \
    -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "$JSON" \
    -d '["name","duration","sizePerHour"]' >/dev/null || refused "Inventory/Columns?level=Episode"
check "and writes its decimals the way that language does" \
    "$(curl -sf "$BASE/Inventory/Export?mediaType=Series&level=Episode&format=csv&culture=de" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"" | python3 -c "
import csv, io, sys
rows = list(csv.reader(io.StringIO(sys.stdin.buffer.read().decode('utf-8-sig')), delimiter=';'))
at = rows[0].index('Laufzeit')
values = [r[at] for r in rows[1:] if r[at]]
print('ok' if values and any(',' in v for v in values) and not any('.' in v for v in values) else values)")" "ok"
check "a language whose decimal separator no spreadsheet reads writes its numbers the invariant way" \
    "$(curl -sf "$BASE/Inventory/Export?mediaType=Series&level=Episode&format=csv&culture=ar-SA" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"" | python3 -c "
import csv, io, re, sys
rows = list(csv.reader(io.StringIO(sys.stdin.buffer.read().decode('utf-8-sig'))))
values = [r[1] for r in rows[1:] if r[1]]
print('ok' if values and all(re.fullmatch(r'\d+(\.\d+)?', v) for v in values) else values)")" "ok"
for invented in x-invented root de-x-private; do
    check "a culture the runtime does not ship is answered the invariant way, not with an error: $invented" \
        "$(curl -s -w ' %{http_code}' "$BASE/Inventory/Export?mediaType=Series&level=Episode&format=csv&culture=$invented" \
            -H "Authorization: MediaBrowser Token=\"$TOKEN\"" | tail -c 4)/$(curl -sf "$BASE/Inventory/Export?mediaType=Series&level=Episode&format=csv&culture=$invented" \
            -H "Authorization: MediaBrowser Token=\"$TOKEN\"" | head -1 | tr -dc ',;')" " 200/,,"
done
check "while the same export in english keeps the comma between its fields" \
    "$(curl -sf "$BASE/Inventory/Export?mediaType=Series&level=Episode&format=csv" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"" | head -1 | tr -d '\r' | cut -d, -f2)" "Duration"
# Items is second in the Series selection, Duration in the Episode one.
check "an export of an expanded level carries the columns the table is showing" \
    "$(curl -sf "$BASE/Inventory/Export?mediaType=Series&level=Episode&columnLevel=Series&format=csv" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"" | head -1 | tr -d '\r' | cut -d, -f2)" "Items"
check "a runtime added up from seventy-two episodes is written for a spreadsheet to show" \
    "$(curl -sf "$BASE/Inventory/Export?mediaType=Series&format=csv" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"" | python3 -c "
import csv, io, sys
rows = list(csv.reader(io.StringIO(sys.stdin.buffer.read().decode('utf-8-sig'))))
at = [rows[0].index(name) for name in ('Duration', 'Size/hour')]
print('ok' if all(len(r[i].partition('.')[2]) <= 3 for r in rows[1:] for i in at) else rows[1:])")" "ok"
check "csv export is offered as a file" \
    "$(curl -sf -o /dev/null -D - "$BASE/Inventory/Export?mediaType=Movie&format=csv" -H "Authorization: MediaBrowser Token=\"$TOKEN\"" | grep -ci 'filename=inventory-movie.csv')" "1"
curl -sf "$BASE/Inventory/Export?mediaType=Movie&format=ods" -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -o "$WORK/export.ods" \
    || refused "Inventory/Export?format=ods" GET
check "ods export opens as a spreadsheet" \
    "$(python3 -c "
import sys, zipfile
with zipfile.ZipFile('$WORK/export.ods') as book:
    names = book.namelist()
    mimetype = book.read('mimetype').decode()
    content = book.read('content.xml').decode()
    rows = content.count('<table:table-row>')
    stored = book.infolist()[0].compress_type == zipfile.ZIP_STORED
import xml.dom.minidom
xml.dom.minidom.parseString(content)
print('ok' if names[0] == 'mimetype' and stored
      and mimetype == 'application/vnd.oasis.opendocument.spreadsheet'
      and rows == 8 else f'{names[0]}/{mimetype}/{rows}/{stored}')")" "ok"
# Walked from the front, the way odf sniffers and java.util.zip read it, not via the directory.
check "the ods puts mimetype first and carries its sizes in the local headers" \
    "$(python3 -c "
data = open('$WORK/export.ods', 'rb').read()
at, seen, late = 0, [], []
while data[at:at + 4] == b'PK\\x03\\x04' and len(seen) < 20:
    flag = int.from_bytes(data[at + 6:at + 8], 'little')
    size = int.from_bytes(data[at + 18:at + 22], 'little')
    names = int.from_bytes(data[at + 26:at + 28], 'little')
    extra = int.from_bytes(data[at + 28:at + 30], 'little')
    seen.append(data[at + 30:at + 30 + names].decode('utf-8', 'replace'))
    if flag & 0x08:
        late.append(seen[-1])
        break
    at += 30 + names + extra + size
print('ok' if seen[:1] == ['mimetype'] and 'content.xml' in seen and not late else (seen, late))")" "ok"
check "every ods row carries as many cells as the header" \
    "$(python3 -c "
import re, zipfile
with zipfile.ZipFile('$WORK/export.ods') as book:
    content = book.read('content.xml').decode()
rows = re.findall(r'<table:table-row>(.*?)</table:table-row>', content, re.S)
counts = {len(re.findall(r'<table:table-cell', row)) for row in rows}
print('ok' if rows and len(counts) == 1 else sorted(counts))")" "ok"
check "the ods names its columns before its rows, which is what makes it valid odf" \
    "$(python3 -c "
import zipfile
content = zipfile.ZipFile('$WORK/export.ods').read('content.xml').decode()
print('ok' if '<table:table-column' in content
      and content.index('<table:table-column') < content.index('<table:table-row') else 'out of order')")" "ok"
check "a date and a truth value are typed too, and carry the format that shows them" \
    "$(python3 -c "
import zipfile
content = zipfile.ZipFile('$WORK/export.ods').read('content.xml').decode()
want = ['office:value-type=\"date\"', 'office:date-value=', 'office:value-type=\"boolean\"',
        'table:style-name=\"C-date\"', 'table:style-name=\"C-bool\"',
        'style:data-style-name=\"N-date\"', 'style:data-style-name=\"N-bool\"']
print('ok' if all(w in content for w in want) else [w for w in want if w not in content])")" "ok"
check "and the words beside them follow the language, the way the csv does" \
    "$(curl -sf "$BASE/Inventory/Export?mediaType=Movie&format=ods&culture=de" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -o "$WORK/de.ods" \
      && python3 -c "
import zipfile
content = zipfile.ZipFile('$WORK/de.ods').read('content.xml').decode()
print('ok' if '<text:p>Ja</text:p>' in content and '<text:p>true</text:p>' not in content else 'english')")" "ok"
check "ods numbers are typed as numbers, so a spreadsheet can total them" \
    "$(python3 -c "
import zipfile
with zipfile.ZipFile('$WORK/export.ods') as book:
    content = book.read('content.xml').decode()
print('ok' if 'office:value-type=\"float\"' in content else 'no typed cells')")" "ok"
check "a name with a comma stays one cell, and its umlauts survive" \
    "$(python3 -c "
import csv, io
text = open('$WORK/export.csv', encoding='utf-8-sig').read()
rows = list(csv.reader(io.StringIO(text)))
wide = [r for r in rows if len(r) != len(rows[0])]
want = '\u00c4rger, \"Quoted\" & <M\u00f6vie> (2018)'
print('ok' if not wide and want in [r[0] for r in rows[1:]] else (wide, [r[0] for r in rows[1:]]))")" "ok"
check "and the same name comes back out of the spreadsheet" \
    "$(python3 -c "
import xml.dom.minidom, zipfile
with zipfile.ZipFile('$WORK/export.ods') as book:
    doc = xml.dom.minidom.parseString(book.read('content.xml'))
cells = [n.firstChild.nodeValue for n in doc.getElementsByTagName('text:p') if n.firstChild]
print('ok' if '\u00c4rger, \"Quoted\" & <M\u00f6vie> (2018)' in cells else cells)")" "ok"
# Name is what an unsorted export falls back to, so sorting on it proves nothing.
check "the export follows the sort the table was showing" \
    "$(curl -sf "$BASE/Inventory/Export?mediaType=Movie&format=csv&sortBy=size&descending=true" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"" | python3 -c "
import csv, io, sys
rows = list(csv.reader(io.StringIO(sys.stdin.buffer.read().decode('utf-8-sig'))))
print(rows[1][0])")" "Blue Harbour (2021)"
check "a date is written the one way every spreadsheet reads, whatever the language" \
    "$(for lang in en de; do curl -sf "$BASE/Inventory/Export?mediaType=Movie&columnLevel=Video&format=csv&culture=$lang" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"" | python3 -c "
import csv, io, re, sys
text = sys.stdin.buffer.read().decode('utf-8-sig')
rows = list(csv.reader(io.StringIO(text), delimiter=';' if text.split('\n')[0].count(';') else ','))
print('ok' if len(rows) > 1 and all(re.fullmatch(r'\d{4}-\d{2}-\d{2}', r[-1]) for r in rows[1:]) else rows[1:])"; done | sort -u)" "ok"
check "and the spreadsheet types it that way too" \
    "$(python3 -c "
import re, zipfile
content = zipfile.ZipFile('$WORK/export.ods').read('content.xml').decode()
days = re.findall(r'office:date-value=\"([^\"]*)\"', content)
print('ok' if days and all(re.fullmatch(r'\d{4}-\d{2}-\d{2}', d) for d in days) else days)")" "ok"
check "a sort column that names nothing is refused by the export too" \
    "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/Inventory/Export?mediaType=Movie&format=csv&sortBy=siez" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"")" "400"
check "the format is read whatever its case" \
    "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/Inventory/Export?mediaType=Movie&format=CSV" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"")" "200"
check "a spreadsheet is offered as one, named after the level it lists" \
    "$(curl -sf -o /dev/null -D- "$BASE/Inventory/Export?mediaType=Series&level=Episode&format=ods" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"" | tr -d '\r' \
        | grep -ci -e '^content-type: application/vnd.oasis.opendocument.spreadsheet$' -e 'filename=inventory-episode.ods')" "2"
check "an export tells the browser how long it is going to be" \
    "$(curl -sf -o /dev/null -D- "$BASE/Inventory/Export?mediaType=Movie&format=csv" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"" | grep -ci '^content-length:')" "1"
check "and so does the spreadsheet" \
    "$(curl -sf -o /dev/null -D- "$BASE/Inventory/Export?mediaType=Movie&format=ods" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"" | grep -ci '^content-length:')" "1"
check "an unknown export format is rejected" \
    "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/Inventory/Export?mediaType=Movie&format=pdf" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"")" "400"

check "the configuration page is served, so a missing resource cannot pass unnoticed" \
    "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/web/ConfigurationPage?name=Inventory" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"")" "200"
check "the configuration page carries the table it is supposed to draw" \
    "$(curl -sf "$BASE/web/ConfigurationPage?name=Inventory" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"" | grep -c 'id="invBody"')" "1"
check "the table has its own entry in the dashboard sidebar" \
    "$(curl -sf "$BASE/web/ConfigurationPages?enableInMainMenu=true" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"" \
        | field "[p['DisplayName'] for p in json.load(sys.stdin) if p['Name'] == 'Inventory']")" "['Inventory']"
menu() {
    curl -sf "$BASE/web/ConfigurationPages?enableInMainMenu=true" -H "Authorization: MediaBrowser Token=\"$TOKEN\"" \
        -H "Accept-Language: $1" | field "[p['DisplayName'] for p in json.load(sys.stdin) if p['Name'] == 'Inventory'][0]"
}
check "and its name is worded in the language the browser asks in, by the weight it gives each one" \
    "$(menu 'de-DE,de;q=0.9,en;q=0.8')/$(menu 'de;q=0.3, fr;q=0.9')/$(menu 'nl,en-GB;q=0.5')" "Inventar/Inventaire/Inventory"

# The rows are cached per user, so a second administrator has to see his own playback and not
# the one the first has just written.
SECOND=$(curl -sf -X POST "$BASE/Users/New" -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "$JSON" \
    -d '{"Name":"second","Password":"secondtest"}')
SECOND_ID=$(printf '%s\n' "$SECOND" | field "json.load(sys.stdin)['Id']")
printf '%s\n' "$SECOND" | python3 -c "
import json, sys
policy = json.load(sys.stdin)['Policy']
policy['IsAdministrator'] = True
print(json.dumps(policy))" > "$WORK/policy.json"
curl -sf -X POST "$BASE/Users/$SECOND_ID/Policy" -H "Authorization: MediaBrowser Token=\"$TOKEN\"" \
    -H "$JSON" -d @"$WORK/policy.json" >/dev/null || refused "Users/$SECOND_ID/Policy"
SECOND_TOKEN=$(curl -sf -X POST "$BASE/Users/AuthenticateByName" -H "$JSON" -H "$CLIENT" \
    -d '{"Username":"second","Pw":"secondtest"}' | field "json.load(sys.stdin)['AccessToken']")
check "playback belongs to whoever asks, not to whoever played it" \
    "$(curl -sf "$BASE/Inventory/Items?mediaType=Movie&sortBy=played&descending=true&limit=1" \
        -H "Authorization: MediaBrowser Token=\"$SECOND_TOKEN\"" \
        | field "json.load(sys.stdin)['Rows'][0]['Values']['played']")" "False"

curl -sf -X POST "$BASE/Inventory/Columns?level=Movie" \
    -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "$JSON" \
    -d '["name","size","played","everyonePlayCount","everyoneLastPlayed","everyonePlayed"]' >/dev/null || refused "Inventory/Columns?level=Movie"
SHARED=$(curl -sf "$BASE/Inventory/Items?mediaType=Movie&sortBy=everyonePlayCount&descending=true&limit=1" \
    -H "Authorization: MediaBrowser Token=\"$SECOND_TOKEN\"")
check "the count across all users holds a play the asking user did not make" \
    "$(printf '%s\n' "$SHARED" | field "json.load(sys.stdin)['Rows'][0]['Values']['everyonePlayCount']")" "1"
check "and dates it, though the asking user has played nothing" \
    "$(printf '%s\n' "$SHARED" | field "json.load(sys.stdin)['Rows'][0]['Values']['everyoneLastPlayed'] is not None")" "True"
play "$MOVIE_ID" "$SECOND_TOKEN" "$SECOND_ID"
BOTH_PLAYED=$(curl -sf "$BASE/Inventory/Items?mediaType=Movie&sortBy=everyonePlayCount&descending=true&limit=1" \
    -H "Authorization: MediaBrowser Token=\"$SECOND_TOKEN\"")
check "a second user playing the same film adds to it" \
    "$(printf '%s\n' "$BOTH_PLAYED" | field "json.load(sys.stdin)['Rows'][0]['Values']['everyonePlayCount']")" "2"
check "and both count as having played it to the end" \
    "$(printf '%s\n' "$BOTH_PLAYED" | field "json.load(sys.stdin)['Rows'][0]['Values']['everyonePlayed']")" "2"
check "and it is dated by the later of the two plays" \
    "$(printf '%s\n' "$BOTH_PLAYED" | field "json.load(sys.stdin)['Rows'][0]['Values']['everyoneLastPlayed'][:19]")" \
    "$(curl -sf "$BASE/Items/$MOVIE_ID?userId=$SECOND_ID" -H "Authorization: MediaBrowser Token=\"$TOKEN\"" \
        | field "json.load(sys.stdin)['UserData']['LastPlayedDate'][:19]")"
TWO_CUTS=$(api 'Inventory/Items?mediaType=Movie&search=Two%20Cuts' | field "json.load(sys.stdin)['Rows'][0]['Id']")
play "$(curl -sf "$BASE/Items/$TWO_CUTS?userId=$USER_ID" -H "Authorization: MediaBrowser Token=\"$TOKEN\"" \
    | field "[s['Id'] for s in json.load(sys.stdin)['MediaSources'] if 'Directors' in s['Name']][0]")" "$SECOND_TOKEN" "$SECOND_ID"
check "a film played in its second cut counts and dates that play, which jellyfin keeps on the cut" \
    "$(curl -sf "$BASE/Inventory/Items?mediaType=Movie&search=Two%20Cuts" -H "Authorization: MediaBrowser Token=\"$SECOND_TOKEN\"" \
        | field "(lambda v: '%s/%s/%s' % (v['played'], v['everyonePlayCount'], v['everyoneLastPlayed'] is not None))(json.load(sys.stdin)['Rows'][0]['Values'])")" \
    "True/1/True"
curl -sf -X POST "$BASE/Auth/Keys?app=inventory-test" -H "Authorization: MediaBrowser Token=\"$TOKEN\"" >/dev/null || refused "Auth/Keys"
KEY=$(curl -sf "$BASE/Auth/Keys" -H "Authorization: MediaBrowser Token=\"$TOKEN\"" \
    | field "[k['AccessToken'] for k in json.load(sys.stdin)['Items'] if k['AppName']=='inventory-test'][0]")
check "an api key is nobody's, so it reads the totals and no playback of its own" \
    "$(curl -sf "$BASE/Inventory/Items?mediaType=Movie&sortBy=everyonePlayCount&descending=true&limit=1" \
        -H "Authorization: MediaBrowser Token=\"$KEY\"" \
        | field "(lambda v: '%s/%s' % (v['played'], v['everyonePlayCount']))(json.load(sys.stdin)['Rows'][0]['Values'])")" "None/2"
curl -sf -X POST "$BASE/Inventory/Columns?level=Series" \
    -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "$JSON" \
    -d '["name","playCount","everyonePlayCount","everyonePlayed"]' >/dev/null || refused "Inventory/Columns?level=Series"
play "$(api 'Inventory/Items?mediaType=Series&level=Episode&search=Long%20Run%20S02E01' | field "json.load(sys.stdin)['Rows'][0]['Id']")" \
    "$SECOND_TOKEN" "$SECOND_ID"
WHOLE=$(curl -sf "$BASE/Inventory/Items?mediaType=Series" \
    -H "Authorization: MediaBrowser Token=\"$SECOND_TOKEN\"")
check "a series totals the plays of its episodes across all users" \
    "$(printf '%s\n' "$WHOLE" | named 'Harbour Lights' everyonePlayCount)" "3"
check "while its own column stays with the user asking" \
    "$(printf '%s\n' "$WHOLE" | named 'Harbour Lights' playCount)" "0"
check "a series counts the user who has played every episode of it" \
    "$(printf '%s\n' "$WHOLE" | named 'Harbour Lights' everyonePlayed)" "1"
check "and nobody where each user has played a different part of it" \
    "$(printf '%s\n' "$WHOLE" | field "(lambda v: '%s/%s' % (v['everyonePlayed'], v['everyonePlayCount']))([r['Values'] for r in json.load(sys.stdin)['Rows'] if r['Values']['name']=='Long Run'][0])")" "0/2"

# Nothing tells a plugin that an account is gone, so the totals have to notice by themselves.
curl -sf -X DELETE "$BASE/Users/$SECOND_ID" -H "Authorization: MediaBrowser Token=\"$TOKEN\"" >/dev/null || refused "Users/$SECOND_ID" DELETE
check "a deleted account stops counting toward the totals" \
    "$(api 'Inventory/Items?mediaType=Movie&sortBy=everyonePlayCount&descending=true&limit=1' \
        | field "json.load(sys.stdin)['Rows'][0]['Values']['everyonePlayCount']")" "1"

# Sixty-five accounts, because the count was a bitmask once and stopped at sixty-four.
CROWD=0
while [ "$CROWD" -lt 65 ]; do
    EXTRA=$(curl -sf -X POST "$BASE/Users/New" -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "$JSON" \
        -d "{\"Name\":\"crowd$CROWD\",\"Password\":\"crowdtest\"}" | field "json.load(sys.stdin)['Id']")
    case "$EXTRA" in ""|"<unparseable>") echo "could not create crowd$CROWD" >&2; exit 1 ;; esac
    curl -sf -X POST "$BASE/Users/$EXTRA/PlayedItems/$MOVIE_ID" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "$JSON" -d '{}' >/dev/null \
        || refused "Users/$EXTRA/PlayedItems/$MOVIE_ID"
    CROWD=$((CROWD + 1))
done
check "a film every account has played is counted past sixty-four" \
    "$(api 'Inventory/Items?mediaType=Movie&sortBy=everyonePlayed&descending=true&limit=1' \
        | field "json.load(sys.stdin)['Rows'][0]['Values']['everyonePlayed']")" "66"
check "while a series still counts only the account that watched every episode of it" \
    "$(api 'Inventory/Items?mediaType=Series' | named 'Harbour Lights' everyonePlayed)" "1"
NIGHT=$(api 'Inventory/Items?mediaType=Movie' | identify 'Night Signal (2023)')
BEFORE=$(api 'Inventory/Items?mediaType=Movie' | named 'Night Signal (2023)' everyonePlayCount)
curl -sf -X POST "$BASE/Users/$EXTRA/PlayedItems/$NIGHT" -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "$JSON" -d '{}' >/dev/null \
    || refused "Users/$EXTRA/PlayedItems/$NIGHT"
check "a play by another account reaches the totals the caller had already read" \
    "$BEFORE/$(api 'Inventory/Items?mediaType=Movie' | named 'Night Signal (2023)' everyonePlayCount)" "0/1"

echo "== the page =="
# The page is half the plugin and nothing else ever runs it, so it is driven here against the
# answers this server just gave, with the web client's globals stubbed out.
mkdir -p "$WORK/page"
cp "$ROOT/Jellyfin.Plugin.Inventory/Configuration/configPage.html" "$ROOT/test/page.mjs" \
   "$ROOT/test/rows.json" "$WORK/page/"
curl -sf -X POST "$BASE/Inventory/Columns?level=Movie" -H "Authorization: MediaBrowser Token=\"$TOKEN\"" \
    -H "$JSON" -d '["name","size","duration","sizePerHour","videoCodec","interlaced"]' >/dev/null || refused "Inventory/Columns?level=Movie"
# Two rows to a page, so the pager has something to count.
curl -sf -X POST "$BASE/Inventory/PageSize?size=2" \
    -H "Authorization: MediaBrowser Token=\"$TOKEN\"" >/dev/null || refused "Inventory/PageSize?size=2"
api 'Inventory/Schema' > "$WORK/page/schema.json"
api 'Inventory/Items?mediaType=Movie&sortBy=size&descending=true&limit=100' > "$WORK/page/items.json"
api 'Inventory/Items?mediaType=Movie&search=Two%20Part' > "$WORK/page/one.json"
docker run --rm --security-opt label=disable --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -e TZ=Asia/Tokyo -e "JSDOM=$JSDOM_VERSION" -v "$WORK/page:/w" -w /w "$NODE_IMAGE" sh -c \
    'set -e
     [ -f "node_modules/.jsdom-$JSDOM" ] || { rm -rf node_modules
         npm install --no-audit --no-fund --silent "jsdom@$JSDOM" \
           || { sleep 15; npm install --no-audit --no-fund --silent "jsdom@$JSDOM"; }
         touch "node_modules/.jsdom-$JSDOM"; }
     node /w/page.mjs /w/configPage.html /w/schema.json /w/items.json /w/one.json /w/rows.json' \
    > "$WORK/page/report.txt" 2> "$WORK/page/error.txt" \
  || { echo "the page did not render:"; tail -5 "$WORK/page/error.txt"; }
rendered() { sed -n "s/^$1=//p" "$WORK/page/report.txt"; }

check "the page turns its state into the query it sends" \
    "$(rendered query)" "Inventory/Items?mediaType=Movie&level=Movie&columnLevel=Movie&search=&filters=&sortBy=&descending=false&startIndex=0&limit=2&culture=en"
check "the page draws a row for every item" "$(rendered rows)" "7"
check "the title is the logo, worded like the rest of the page, and opens the repository beside the dashboard" \
    "$(rendered brand)" "https://github.com/ivenos/jellyfin_inventory|_blank|noopener noreferrer|Inventory"
check "the page links a row to the item it stands for" \
    "$(rendered link | cut -d= -f1)" "#/details?id"
check "the tab shows it is busy while the rows are on their way" \
    "$(rendered spinningWhileLoading)" "1"
check "and stops once they are drawn" "$(rendered spinningAfterwards)" "0"
check "and leaving while the rows are still coming does not strand it" \
    "$(rendered hide.stranded)" "0"
check "both export buttons are held while the file is being built" \
    "$(rendered export.during)" "true,true,1"
check "and handed back once it arrives, even if the table moved on meanwhile" \
    "$(rendered export.after)" "false,false,0"
check "an answer that arrives too late still takes the loading message down" \
    "$(rendered stale.overlay)" "0"
check "a table the user asked for does not discard the schema of the visit it was asked in" \
    "$(rendered stale.tabs)" "New Movies 7,New Series 3,New Music 3,New Books 2,New Photos 3"
check "and the answer to a visit that was left does not take down this visit's loading message" \
    "$(rendered overlay.pending)" "1"
check "which comes down when this visit is answered" \
    "$(rendered overlay.settled)/$(rendered overlay.tabs | cut -d, -f1)" "0/New Movies 7"
check "an export that never lands does not hold the buttons past the visit" \
    "$(rendered hung.during)/$(rendered hung.after)" "true,true/false,false"
check "and leaves no spinner behind on the way out" "$(rendered hung.spinning)" "0"
check "a first load that fails says so where the table would be" \
    "$(rendered failed.shown)/$(rendered failed.message)" "true/Could not load the inventory."
check "a page turn that fails does not skip the page behind it" \
    "$(rendered retry.asked)" "startIndex=2"
check "and leaves the pager on the page that is drawn" \
    "$(rendered retry.pager)" "1 / 4"
check "and a sort that fails does not turn the next page in an order that was never drawn" \
    "$(rendered retry.sorted)" "sortBy=&descending=false&startIndex=4"
check "and coming back to rows that did not arrive leaves the next page reachable" \
    "$(rendered retry.revisit)" "1"
check "a tab whose rows never arrive does not keep the rows of the one before it" \
    "$(rendered switch.selected)/$(rendered switch.rows)/$(rendered switch.headers)/$(rendered switch.totals)" \
    "Series 3/0/0/"
check "nor pages to turn through them" "$(rendered switch.pager)" "/true/true"
check "and the column picker is not offered over a table that is not there" \
    "$(rendered switch.columns)/$(rendered switch.boxes)/$(rendered failed.columns)" "true/0/true"
check "children that are thrown away close the control that asked for them" \
    "$(rendered stuck.opened)/$(rendered stuck.after)/$(rendered stuck.children)" "true/false/0"
check "a condition typed into the filter panel is sent in the unit the server keeps" \
    "$(rendered filter.sent)" '[{"column":"size","op":"ge","value":"1610612736"}]'
check "and lists the level the tab is expanded to, flat, with the columns of the tab" \
    "$(rendered filter.level)/$(rendered filter.before)/$(rendered filter.after)" "level=Child&columnLevel=Movie/7/0"
check "and the button counts the conditions that hold" "$(rendered filter.button)" "Filters (1)"
check "while one still waiting for its value asks for nothing" "$(rendered filter.idle)" "0"
check "an export asks for the level, the columns and the conditions the table is showing" \
    "$(rendered filter.exported)" "true,true,true"
check "no more conditions can be added than the server takes" \
    "$(rendered filter.capped)/$(rendered filter.freed)" "true/false"
check "one that asks whether a cell is empty is sent without a value, and shows no box for one" \
    "$(rendered filter.bare)/$(rendered filter.valueless)" \
    '[{"column":"size","op":"ge","value":"1610612736"},{"column":"name","op":"empty"}]/0'
check "and the rows open again once the last condition is gone" "$(rendered filter.restored)" "7"
check "a page left behind the end of a library that shrank falls back to the last one there is" \
    "$(rendered beyond.asked)/$(rendered beyond.rows)/$(rendered beyond.pager)" "2,0/2/1 / 1"
check "a row opened in the tree draws its children right below it, and closing it takes them away" \
    "$(rendered tree.opened)/$(rendered tree.closed)" "0,1,1,0,0,0,0,0,0/child 1,child 2/0,0,0,0,0,0,0"
check "a second view of the page binds its own controls, not those of the view the web client kept" \
    "$(rendered twice.tabs)/$(rendered twice.schemas)/$(rendered twice.exports)" "5/1/1"
check "coming back to the tab that was open keeps its sort and its page" \
    "$(rendered revisit.asked)" "sortBy=size&descending=true&startIndex=2"
check "a page turned while a changed condition is still waiting lists that condition from its first page" \
    "$(rendered debounce.asked)/$(rendered debounce.pager)" "startIndex=0/1 / 4"
check "a condition on a column the server no longer offers is dropped rather than breaking the page" \
    "$(rendered gone.asked)/$(rendered gone.button)/$(rendered gone.rows)" "1/Filters/7"
check "a value is sent in the unit the server keeps, and a decimal comma is read as a point" \
    "$(rendered units.sent)" "5400|128000|2147483648|1610612736|none|none|2024-03-01|true"
check "while one that cannot be read is marked and asks for nothing" \
    "$(rendered units.invalid)" "false|false|false|false|true|true|false|-"
check "a ticked column is stored behind the last chosen one the picker offers before it" \
    "$(rendered controls.ticked)" '["name","year","size","duration","sizePerHour","videoCodec","interlaced"]'
check "ctrl with an arrow key moves a column" \
    "$(rendered controls.moved)" '["size","name","duration","sizePerHour","videoCodec","interlaced"]'
check "a number column sorts largest first, a second click turns it round, and text sorts from the start" \
    "$(rendered controls.sorted)" "size=true,size=false,name=false"
check "a page size is stored, and the rows are asked for again from the first" \
    "$(rendered controls.size)" "Inventory/PageSize?size=250&culture=en/0,250"
check "a search is sent as it was typed" "$(rendered controls.search)" "Blue"
check "the page raises nothing while it is driven" "$(rendered raised)" "0"
check "the page takes its column headers from the strings" \
    "$(rendered headers)" "Name,Size,Duration,Size/hour,Video codec,Interlaced"
check "the page names every tab and how much it holds" \
    "$(rendered tabs)" "Movies 7,Series 3,Music 3,Books 2,Photos 3"
check "the totals line counts the rows the server matched" \
    "$(rendered totals | cut -d' ' -f1-2)" "7 items"
check "the pager counts the pages the rows need" "$(rendered pager)" "1 / 4"
check "a single row is counted in the singular" \
    "$(rendered one.rows)/$(rendered one.totals | cut -d' ' -f1-2)" "1/1 item"

# Values chosen so every formatting rule has one case it alone can satisfy.
check "the page formats every kind of value the way it says it does" \
    "$(rendered exact.grid)" \
    "Exactly one gibibyte | 1.00 GB | 45 s | 3.73 GB | 128 kbit/s | 3/1/2024 | Yes | 1,234,567 | 2024 / One byte short of it | 1.00 GB | 1 h 0 min |  | 1.50 Mbit/s |  | No | 0 |  / Children that disagree | Mixed | Mixed | Mixed | Mixed | Mixed | Mixed | 2 | Mixed"
check "and adds the totals line up the same way" \
    "$(rendered exact.totals)" "3 items · 2.00 GB · 1 h 1 min"
check "and counts the pages those rows need" "$(rendered exact.pager)" "1 / 2"

curl -sf -X POST "$BASE/Inventory/PageSize?size=100" \
    -H "Authorization: MediaBrowser Token=\"$TOKEN\"" >/dev/null || refused "Inventory/PageSize?size=100"

curl -sf -X POST "$BASE/Users/New" -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "$JSON" \
    -d '{"Name":"viewer","Password":"viewertest"}' >/dev/null || refused "Users/New"
VIEWER=$(curl -sf -X POST "$BASE/Users/AuthenticateByName" -H "$JSON" -H "$CLIENT" \
    -d '{"Username":"viewer","Pw":"viewertest"}' | field "json.load(sys.stdin)['AccessToken']")
# One [Authorize] on the class covers all six routes, so a lost attribute shows on one of them.
for guarded in "Schema" "Items?mediaType=Movie" "Export?mediaType=Movie&format=csv"; do
    check "reading ${guarded%%\?*} needs a token" \
        "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/Inventory/$guarded")" "401"
    check "reading ${guarded%%\?*} needs an administrator" \
        "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/Inventory/$guarded" \
            -H "Authorization: MediaBrowser Token=\"$VIEWER\"")" "403"
done
for guarded in "Columns?level=Movie" "PageSize?size=50" "Expand?mediaType=Series&level=Season"; do
    check "posting ${guarded%%\?*} needs a token" \
        "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/Inventory/$guarded" \
            -H "$JSON" -d '["name"]')" "401"
    check "posting ${guarded%%\?*} needs an administrator" \
        "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/Inventory/$guarded" \
            -H "Authorization: MediaBrowser Token=\"$VIEWER\"" -H "$JSON" -d '["name"]')" "403"
done

check "a level that is not a level is rejected before it reaches the configuration file" \
    "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/Inventory/Columns?level=A%01B" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "$JSON" -d '["name"]')" "400"
check "a selection that names no known column is rejected" \
    "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/Inventory/Columns?level=Movie" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "$JSON" -d '["no-such-column"]')" "400"
check "a repeated column is stored once" \
    "$(curl -sf -X POST "$BASE/Inventory/Columns?level=Movie" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "$JSON" \
        -d '["name","name","size","name"]' | field "','.join(json.load(sys.stdin)['Columns'])")" "name,size"
check "a level given in another case is stored the way the table asks for it" \
    "$(curl -sf -X POST "$BASE/Inventory/Columns?level=movie" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "$JSON" \
        -d '["name","size"]' | field "json.load(sys.stdin)['Level']")" "Movie"

check "a filter reads the caller's playback though no column on screen does" \
    "$(api "Inventory/Items?mediaType=Movie&filters=$(filtered '[{"column":"played","op":"eq","value":true}]')" \
        | field "(lambda d: '%s/%s' % (d['TotalCount'], ','.join(c['Key'] for c in d['Columns'])))(json.load(sys.stdin))")" "1/name,size"

check "and one on the totals reads every account's" \
    "$(api "Inventory/Items?mediaType=Movie&filters=$(filtered '[{"column":"everyonePlayCount","op":"ge","value":2}]')" \
        | field "(lambda d: '%s/%s' % (d['TotalCount'], ','.join(c['Key'] for c in d['Columns'])))(json.load(sys.stdin))")" "1/name,size"
check "and so does a sort, which puts the one film played last" \
    "$(api 'Inventory/Items?mediaType=Movie&sortBy=played&limit=100' | field "json.load(sys.stdin)['Rows'][-1]['Id']")" "$MOVIE_ID"

check "a column level that is not a level is rejected rather than answered with the generic set" \
    "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/Inventory/Items?mediaType=Movie&columnLevel=Nonsense" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"")" "400"
check "and the export says the same" \
    "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/Inventory/Export?mediaType=Movie&format=csv&columnLevel=Nonsense" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"")" "400"
check "an empty column level falls back to the level being listed" \
    "$(curl -sf "$BASE/Inventory/Items?mediaType=Movie&columnLevel=&limit=1" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"" \
        | field "','.join(c['Key'] for c in json.load(sys.stdin)['Columns'])")" "name,size"
check "unknown media type is rejected" \
    "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/Inventory/Items?mediaType=Nonsense" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"")" "400"
check "a page size the table would never ask for is rejected" \
    "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/Inventory/PageSize?size=20000" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"")" "400"
check "and so is one below a single row" \
    "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/Inventory/PageSize?size=0" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"")" "400"
check "the largest page the table offers is taken" \
    "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/Inventory/PageSize?size=10000" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"")" "200"
check "a page holds what was asked for" \
    "$(curl -sf -X POST "$BASE/Inventory/PageSize?size=3" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"" >/dev/null \
      && api 'Inventory/Items?mediaType=Movie' | field "len(json.load(sys.stdin)['Rows'])")" "3"
check "the export is not cut off at the page size" \
    "$(curl -sf "$BASE/Inventory/Export?mediaType=Movie&format=csv" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"" | python3 -c "
import csv, io, sys
print(len(list(csv.reader(io.StringIO(sys.stdin.buffer.read().decode('utf-8-sig'))))) - 1)")" \
    "$(api 'Inventory/Items?mediaType=Movie' | field "json.load(sys.stdin)['TotalCount']")"
curl -sf -X POST "$BASE/Inventory/PageSize?size=1" \
    -H "Authorization: MediaBrowser Token=\"$TOKEN\"" >/dev/null || refused "Inventory/PageSize?size=1"
check "expanding is not cut off at the page size either" \
    "$(api "Inventory/Items?mediaType=Series&level=Episode&parentIds=$SEASON_ID" \
        | field "len(json.load(sys.stdin)['Rows'])")" "3"
curl -sf -X POST "$BASE/Inventory/PageSize?size=3" \
    -H "Authorization: MediaBrowser Token=\"$TOKEN\"" >/dev/null || refused "Inventory/PageSize?size=3"
check "the api needs a token" \
    "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/Inventory/Schema")" "401"

# The rows are dropped by a library event, not by a clock, and only the movie tab is covered below.
curl -sf "$BASE/Items/$ALBUM_ID" -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -o "$WORK/album.json" || refused "Items/$ALBUM_ID" GET
python3 -c "
import json
item = json.load(open('$WORK/album.json'))
item['Name'] = '@Renamed;=1+1'
json.dump(item, open('$WORK/album-renamed.json', 'w'))"
curl -sf -X POST "$BASE/Items/$ALBUM_ID" -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "$JSON" \
    -d @"$WORK/album-renamed.json" >/dev/null || refused "Items/$ALBUM_ID"
i=0
until [ "$(api 'Inventory/Items?mediaType=MusicAlbum' | named '@Renamed;=1+1' name)" = "@Renamed;=1+1" ] \
    || [ "$i" -gt 10 ]; do
    i=$((i + 1))
    sleep 1
done
check "a rename outside the movie tab reaches the table as well" \
    "$(api 'Inventory/Items?mediaType=MusicAlbum' | named '@Renamed;=1+1' name)" "@Renamed;=1+1"
check "a name that holds another separator stays one cell, so a spreadsheet splitting there finds no formula" \
    "$(curl -sf "$BASE/Inventory/Export?mediaType=MusicAlbum&format=csv" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"" | python3 -c "
import csv, io, re, sys
text = sys.stdin.buffer.read().decode('utf-8-sig')
kept = [r[0] for r in csv.reader(io.StringIO(text))]
split = [c for r in csv.reader(io.StringIO(text), delimiter=';') for c in r
         if c[:1] in ('=', '+', '-', '@') and not re.fullmatch(r'-?[\d.,]+', c)]
print('ok' if \"'@Renamed;=1+1\" in kept and not split else (kept, split))")" "ok"
curl -sf -X POST "$BASE/Items/$ALBUM_ID" -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "$JSON" \
    -d @"$WORK/album.json" >/dev/null || refused "Items/$ALBUM_ID"

echo "== a growing library =="
cp -r "$WORK/media/movies/Blue Harbour (2021)" "$WORK/media/movies/Late Arrival (2025)"
mv "$WORK/media/movies/Late Arrival (2025)/Blue Harbour (2021).mkv" \
   "$WORK/media/movies/Late Arrival (2025)/Late Arrival (2025).mkv"
curl -sf -X POST "$BASE/Library/Refresh" -H "Authorization: MediaBrowser Token=\"$TOKEN\"" >/dev/null || refused "Library/Refresh"
printf 'waiting for the new film'
i=0
until [ "$(api 'Inventory/Items?mediaType=Movie' | field "json.load(sys.stdin)['TotalCount']")" = "8" ]; do
    i=$((i + 1))
    [ "$i" -gt 40 ] && { echo; echo "the new film never arrived" >&2; exit 1; }
    [ $((i % 10)) = 0 ] && curl -sf -X POST "$BASE/Library/Refresh" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"" >/dev/null 2>&1
    printf '.'
    sleep 3
done
echo
check "a film added while the server runs reaches the table without a restart" \
    "$(api 'Inventory/Items?mediaType=Movie' | field "json.load(sys.stdin)['TotalCount']")" "8"
rm -rf "$WORK/media/movies/Late Arrival (2025)"
curl -sf -X POST "$BASE/Library/Refresh" -H "Authorization: MediaBrowser Token=\"$TOKEN\"" >/dev/null || refused "Library/Refresh"
i=0
until [ "$(api 'Inventory/Items?mediaType=Movie' | field "json.load(sys.stdin)['TotalCount']")" = "7" ] || [ "$i" -gt 40 ]; do
    i=$((i + 1))
    [ $((i % 10)) = 0 ] && curl -sf -X POST "$BASE/Library/Refresh" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"" >/dev/null 2>&1
    sleep 3
done
check "and one taken away leaves it again" \
    "$(api 'Inventory/Items?mediaType=Movie' | field "json.load(sys.stdin)['TotalCount']")" "7"

mkdir -p "$WORK/media/copies/Night Signal (2023)"
cp "$WORK/media/movies/Night Signal (2023)/Night Signal (2023).mkv" "$WORK/media/copies/Night Signal (2023)/Night Signal (2023) - 4K.mkv"
curl -sf --max-time 600 -X POST "$BASE/Library/VirtualFolders?name=Copies&collectionType=movies&paths=/media/copies&refreshLibrary=true" \
    -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "$JSON" -d "$OFFLINE" >/dev/null || refused "Library/VirtualFolders?name=Copies"
i=0
until [ "$(api 'Inventory/Items?mediaType=Movie&search=Night%20Signal' | field "json.load(sys.stdin)['TotalCount']")" = "2" ] || [ "$i" -gt 40 ]; do
    i=$((i + 1))
    [ $((i % 10)) = 0 ] && curl -sf -X POST "$BASE/Library/Refresh" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"" >/dev/null 2>&1
    sleep 3
done
curl -sf -X POST "$BASE/Videos/MergeVersions?ids=$(api 'Inventory/Items?mediaType=Movie&search=Night%20Signal' \
    | field "','.join(r['Id'] for r in json.load(sys.stdin)['Rows'])")" \
    -H "Authorization: MediaBrowser Token=\"$TOKEN\"" >/dev/null || refused "Videos/MergeVersions"
TWICE=$(($(wc -c < "$WORK/media/movies/Night Signal (2023)/Night Signal (2023).mkv") * 2))
i=0
until [ "$(api 'Inventory/Items?mediaType=Movie&search=Night%20Signal' | field "json.load(sys.stdin)['TotalSize']")" = "$TWICE" ] || [ "$i" -gt 15 ]; do
    i=$((i + 1))
    sleep 1
done
# 12.0 hides the version in the other library, while 12.1 lists it there as a row of its own.
check "a film grouped with a version in another library weighs both files once, whether or not that library lists it" \
    "$(api 'Inventory/Items?mediaType=Movie&search=Night%20Signal' | field "json.load(sys.stdin)['TotalSize']")" "$TWICE"

GUID=$(field "json.load(open('$WORK/config/plugins/Inventory/meta.json'))['guid']" </dev/null)
curl -sf -X POST "$BASE/Plugins/$GUID/Configuration" -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "$JSON" \
    -d '{"Presets":null,"Expanded":null,"PageSize":100}' >/dev/null || refused "Plugins/$GUID/Configuration"
check "a configuration stored with empty lists through jellyfin's own endpoint still answers everywhere" \
    "$(for route in Schema 'Items?mediaType=Series' 'Export?mediaType=Series&format=csv'; do
        curl -s -o /dev/null -w '%{http_code} ' "$BASE/Inventory/$route" -H "Authorization: MediaBrowser Token=\"$TOKEN\""
    done)" "200 200 200 "

echo "== restart =="
curl -sf -X POST "$BASE/Inventory/Columns?level=Book" \
    -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "$JSON" -d '["name","container"]' >/dev/null || refused "Inventory/Columns?level=Book"
curl -sf -X POST "$BASE/Inventory/Expand?mediaType=Series&level=Season" \
    -H "Authorization: MediaBrowser Token=\"$TOKEN\"" >/dev/null || refused "Inventory/Expand?mediaType=Series&level=Season"
curl -sf -X POST "$BASE/Inventory/PageSize?size=250" \
    -H "Authorization: MediaBrowser Token=\"$TOKEN\"" >/dev/null || refused "Inventory/PageSize?size=250"
docker restart "$CONTAINER" >/dev/null
i=0
until curl -sf --max-time 10 "$BASE/Inventory/Schema" \
    -H "Authorization: MediaBrowser Token=\"$TOKEN\"" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -gt 90 ] && { echo "server did not come back" >&2; exit 1; }
    sleep 2
done
check "a stored column selection survives a restart" \
    "$(api 'Inventory/Items?mediaType=Book&limit=1' | field "','.join(c['Key'] for c in json.load(sys.stdin)['Columns'])")" "name,container"
check "so does how far a tab is expanded" \
    "$(api 'Inventory/Schema' | field "[t['ExpandedTo'] for t in json.load(sys.stdin)['MediaTypes'] if t['MediaType']=='Series'][0]")" "Season"
check "and the page size the table starts with" \
    "$(api 'Inventory/Schema' | field "json.load(sys.stdin)['PageSize']")" "250"

echo
if [ "$FAIL" != 0 ]; then
    echo "the last lines from $IMAGE, since a check that reads nothing says nothing:"
    docker logs --tail 30 "$CONTAINER" 2>&1 | sed 's/^/    /'
    echo
fi
REACHED_END=1
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
