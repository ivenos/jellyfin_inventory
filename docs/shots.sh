#!/bin/sh
# Rebuilds the README screenshots from a showcase library, so a change to the table can be shown
# without arranging one by hand.
set -eu

PORT="${PORT:-8095}"
CONTAINER="jellyfin-inventory-shots-$PORT"
NETWORK="jellyfin-inventory-shots-$PORT"
WORK="${INVENTORY_SHOTS_DIR:-$HOME/.cache/jellyfin-inventory-shots}"
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# Taken from the test run, so the versions stay in one place.
IMAGE="${JELLYFIN_IMAGE:-$(sed -n 's/^IMAGE=.*:-\(.*\)}"/\1/p' "$ROOT/test/run.sh")}"
SDK_IMAGE="${SDK_IMAGE:-$(sed -n 's/^SDK_IMAGE=.*:-\(.*\)}"/\1/p' "$ROOT/test/run.sh")}"
BROWSER_IMAGE="${PLAYWRIGHT_IMAGE:-mcr.microsoft.com/playwright:v1.63.0-noble}"
# The image carries the browsers but not the library, and the two have to be the same release.
BROWSER_VERSION=$(printf '%s' "$BROWSER_IMAGE" | sed -n 's/.*:v\([0-9.]*\).*/\1/p')
BUILD=1

for arg in "$@"; do
    case "$arg" in
        --no-build) BUILD=0 ;;
        *) echo "usage: $0 [--no-build]" >&2; exit 2 ;;
    esac
done

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

if [ "$BUILD" = 1 ]; then
    echo "== build =="
    mkdir -p "$WORK/nuget"
    docker run --rm --security-opt label=disable --user "$(id -u):$(id -g)" \
        -e HOME=/tmp -e DOTNET_CLI_TELEMETRY_OPTOUT=1 -e DOTNET_NOLOGO=1 -e NUGET_PACKAGES=/nuget \
        -v "$ROOT:/src" -v "$WORK/nuget:/nuget" -w /src "$SDK_IMAGE" \
        dotnet build -c Release --nologo
fi

DLL="$ROOT/Jellyfin.Plugin.Inventory/bin/Release/net10.0/Jellyfin.Plugin.Inventory.dll"
[ -f "$DLL" ] || { echo "no plugin build at $DLL" >&2; exit 1; }

echo "== library =="
# Five encodings the table can tell apart, cut to a different length per title so no two rows
# carry the same numbers.
RECIPE=$(cat <<'FIXTURES'
        FF=/usr/lib/jellyfin-ffmpeg/ffmpeg
        M=/media
        rm -rf "$M/movies" "$M/shows" "$M/music" "$M/photos" "$M/seed"
        mkdir -p "$M/seed" "$M/movies" "$M/shows" "$M/music" "$M/photos"

        mk() {
            $FF -y -loglevel error -f lavfi -i "testsrc2=size=$2x$3:rate=24:duration=30" \
                -f lavfi -i "sine=frequency=$4:duration=30" \
                -c:v "$5" -preset ultrafast -crf "${10}" -g 24 -keyint_min 24 -sc_threshold 0 \
                -pix_fmt "$6" $7 -c:a "$8" -ac "$9" -b:a 192k -metadata:s:a:0 language=eng \
                "$M/seed/$1.mkv"
        }
        mk p1080 1920 1080 440 libx264 yuv420p "" aac 2 34
        mk p2160 3840 2160 300 libx265 yuv420p10le \
            "-bsf:v hevc_metadata=colour_primaries=9:transfer_characteristics=16:matrix_coefficients=9" \
            eac3 6 24
        mk p720 1280 720 600 libx264 yuv420p "" aac 2 36
        mk p1080h 1920 1080 520 libx265 yuv420p "" eac3 6 30
        mk p480 854 480 380 mpeg4 yuv420p "" ac3 2 38

        i=0
        for t in "Amber Distance (2021)" "Boulevard of Static (2019)" "Cinder Lake (2023)" \
                 "Driftwood County (2018)" "Every Quiet Harbour (2022)" "Fathom Line (2020)" \
                 "Glasswing (2024)" "Halcyon Freight (2017)" "Iron Meridian (2021)" \
                 "Junction 47 (2016)" "Kelvin Drift (2023)" "Lantern Fields (2019)" \
                 "Midnight Cartography (2022)" "Northbound Signal (2020)" "Ochre Season (2018)" \
                 "Paper Aviaries (2024)" "Quarry Light (2015)" "Reservoir Hymn (2021)"; do
            case $((i % 5)) in 0) p=p1080;; 1) p=p2160;; 2) p=p720;; 3) p=p1080h;; 4) p=p480;; esac
            mkdir -p "$M/movies/$t"
            $FF -y -loglevel error -i "$M/seed/$p.mkv" -t "$((6 + (i * 7) % 17))" -c copy \
                "$M/movies/$t/$t.mkv"
            i=$((i + 1))
        done

        show() {
            name=$1; shift
            s=1
            while [ $s -le 2 ]; do
                d="$M/shows/$name/$(printf 'Season %02d' $s)"; mkdir -p "$d"
                e=1
                for p in "$@"; do
                    $FF -y -loglevel error -i "$M/seed/$p.mkv" -t "$((5 + (s * 3 + e * 5) % 13))" \
                        -c copy "$(printf '%s/%s S%02dE%02d.mkv' "$d" "${name%% (*}" $s $e)"
                    e=$((e + 1))
                done
                s=$((s + 1))
            done
        }
        show "The Salt Road (2022)" p1080 p1080 p1080 p1080
        show "Ledger of Small Hours (2020)" p720 p720 p1080h p1080h
        show "Vanishing Point Blue (2024)" p2160 p2160 p2160 p2160

        alb() {
            d="$M/music/$1/$2"; mkdir -p "$d"
            n=1
            while [ $n -le $5 ]; do
                $FF -y -loglevel error -f lavfi -i "sine=frequency=$((220 + n * 40)):duration=$((90 + n * 17))" \
                    -c:a "$4" -metadata artist="$1" -metadata album="$2" -metadata date="$3" \
                    -metadata title="$(printf 'Track %02d' $n)" -metadata track="$n" \
                    "$(printf '%s/%02d Track %02d.%s' "$d" $n $n "$6")"
                n=$((n + 1))
            done
        }
        alb "Hollow Coast" "Tideline" 2021 flac 6 flac
        alb "Hollow Coast" "Second Weather" 2023 flac 5 flac
        alb "Marram" "Field Notes" 2019 libmp3lame 7 mp3

        shot() {
            $FF -y -loglevel error -f lavfi -i "testsrc2=size=$2x$3:rate=1:duration=1" \
                -frames:v 1 "$M/photos/$1.jpg"
        }
        shot Coastline 4032 3024
        shot "Dune Ridge" 6000 4000
        shot "Harbour Wall" 1600 1200
        shot "Old Pier" 800 600
FIXTURES
)
BOOKS="The Coast Road Companion|M. Ferrers
Notes on Tidewater|J. Aldis"
STAMP=$(printf '%s\n%s' "$RECIPE" "$BOOKS" | cat - "$ROOT/test/make-book.py" | md5sum | cut -d' ' -f1)

if [ "$(cat "$WORK/media/.complete" 2>/dev/null || true)" != "$STAMP" ]; then
    rm -rf "$WORK/media"
    mkdir -p "$WORK/media/books" "$WORK/media/photos"
    printf '%s\n' "$BOOKS" | while IFS='|' read -r title author; do
        python3 "$ROOT/test/make-book.py" "$WORK/media/books/$title.epub" "$title" "$author"
    done
    docker run --rm --security-opt label=disable --user "$(id -u):$(id -g)" \
        -v "$WORK/media:/media" --entrypoint /bin/sh "$IMAGE" -c "$RECIPE"
    printf '%s' "$STAMP" > "$WORK/media/.complete"
fi

echo "== start =="
cleanup
rm -rf "$WORK/config" "$WORK/cache"
mkdir -p "$WORK/config/plugins/Inventory" "$WORK/cache" "$WORK/browser"
cp "$DLL" "$WORK/config/plugins/Inventory/"
python3 "$ROOT/.github/make-meta.py" --version 9.9.9.0 --root "$ROOT" \
    --out "$WORK/config/plugins/Inventory/meta.json" >/dev/null
docker network create "$NETWORK" >/dev/null
docker run -d --name "$CONTAINER" --security-opt label=disable --user "$(id -u):$(id -g)" \
    --network "$NETWORK" -p "127.0.0.1:$PORT:8096" \
    -v "$WORK/config:/config" -v "$WORK/cache:/cache" -v "$WORK/media:/media:ro" \
    "$IMAGE" >/dev/null

CLIENT='Authorization: MediaBrowser Client="shots", Device="cli", DeviceId="inventory-shots", Version="1.0.0"'
JSON='Content-Type: application/json'
BASE="http://localhost:$PORT"

printf 'waiting for startup'
i=0
until curl -sf "$BASE/Startup/Configuration" -H "$CLIENT" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -gt 90 ] && { echo; echo "server did not come up" >&2; exit 1; }
    printf '.'
    sleep 2
done
echo

curl -sf -X POST "$BASE/Startup/Configuration" -H "$JSON" -H "$CLIENT" \
    -d '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}' >/dev/null
curl -sf "$BASE/Startup/User" -H "$CLIENT" >/dev/null
curl -sf -X POST "$BASE/Startup/User" -H "$JSON" -H "$CLIENT" \
    -d '{"Name":"admin","Password":"inventoryshots"}' >/dev/null
curl -sf -X POST "$BASE/Startup/Complete" -H "$CLIENT" >/dev/null
TOKEN=$(curl -sf -X POST "$BASE/Users/AuthenticateByName" -H "$JSON" -H "$CLIENT" \
    -d '{"Username":"admin","Pw":"inventoryshots"}' \
    | python3 -c "import sys,json;print(json.load(sys.stdin)['AccessToken'])")

# Titles that no provider knows, so a lookup would only replace them with nothing.
OPTIONS='{"LibraryOptions":{"EnableInternetProviders":false,"EnableChapterImageExtraction":false}}'
for library in "Movies:movies" "Shows:tvshows" "Music:music" "Books:books" "Photos:homevideos"; do
    name=${library%%:*}
    curl -sf -X POST -H "Authorization: MediaBrowser Token=\"$TOKEN\"" -H "$JSON" -d "$OPTIONS" \
        "$BASE/Library/VirtualFolders?name=$name&collectionType=${library#*:}&paths=/media/$(printf '%s' "$name" | tr 'A-Z' 'a-z')&refreshLibrary=true" >/dev/null
done

printf 'waiting for the scan'
i=0
until [ "$(curl -sf "$BASE/Inventory/Items?mediaType=Movie&limit=30" \
    -H "Authorization: MediaBrowser Token=\"$TOKEN\"" \
    | python3 -c "
import json, sys
rows = json.load(sys.stdin)['Rows']
print(len({r['Values'].get('size') for r in rows}), len(rows))" 2>/dev/null)" = "18 18" ]; do
    i=$((i + 1))
    [ "$i" -gt 60 ] && { echo; echo "library did not settle" >&2; exit 1; }
    [ $((i % 10)) = 0 ] && curl -sf -X POST "$BASE/Library/Refresh" \
        -H "Authorization: MediaBrowser Token=\"$TOKEN\"" >/dev/null 2>&1
    printf '.'
    sleep 3
done
echo

echo "== shots =="
cat > "$WORK/browser/shots.mjs" <<EOF
import { chromium } from 'playwright';

const BASE = 'http://$CONTAINER:8096';
EOF
cat >> "$WORK/browser/shots.mjs" <<'EOF'
const browser = await chromium.launch({ args: ['--no-sandbox'] });
// Wide enough for the whole column set, and drawn at a density a reader can still zoom into.
const page = await browser.newPage({
    viewport: { width: 1500, height: 950 },
    deviceScaleFactor: 1.4,
    locale: 'en-US',
});

await page.goto(BASE + '/web/index.html#/login', { waitUntil: 'domcontentloaded' });
await page.waitForSelector('input#txtManualName', { timeout: 60000 });
await page.fill('input#txtManualName', 'admin');
await page.fill('input#txtManualPassword', 'inventoryshots');
await page.locator('button:visible').first().click();
await page.waitForTimeout(6000);

// Jellyfin serves the embedded page from a cache a restart does not clear.
await page.evaluate(() => fetch('/web/ConfigurationPage?name=Inventory&cb=' + Date.now()));
await page.goto(BASE + '/web/index.html#/configurationpage?name=Inventory', { waitUntil: 'domcontentloaded' });
await page.waitForSelector('#invBody tr', { timeout: 60000 });
await page.waitForTimeout(2500);

await page.click('.invType[data-type="Movie"]');
await page.waitForFunction(() => document.querySelectorAll('#invBody tr').length === 18, null, { timeout: 30000 });
await page.waitForTimeout(1000);
await page.screenshot({ path: '/out/movies.png' });

await page.click('.invType[data-type="Series"]');
await page.waitForTimeout(2500);
await page.selectOption('#invExpand', '2');
await page.waitForFunction(() => document.querySelectorAll('#invBody tr').length === 33, null, { timeout: 30000 });
await page.waitForTimeout(1000);
await page.screenshot({ path: '/out/series.png' });

await browser.close();
EOF

docker run --rm --security-opt label=disable --user "$(id -u):$(id -g)" \
    --network "$NETWORK" --ipc=host -e HOME=/tmp \
    -v "$WORK/browser:/b" -v "$ROOT/docs:/out" -w /b "$BROWSER_IMAGE" sh -c \
    "[ -d node_modules/playwright ] || npm install --no-audit --no-fund --silent playwright@$BROWSER_VERSION
     node /b/shots.mjs"

ls -l "$ROOT/docs"
