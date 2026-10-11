#!/bin/sh
# Starts a Jellyfin that holds the plugin and the sample library. Run it to click through one,
# or source it to go on with $BASE, $TOKEN and $CONTAINER.
set -eu

PORT="${PORT:-8095}"
CONTAINER="jellyfin_inventory-demo-$PORT"
WORK="${INVENTORY_DEMO_DIR:-$HOME/.cache/jellyfin_inventory-demo-$PORT}"
ROOT="${ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
IMAGE="${JELLYFIN_IMAGE:-jellyfin/jellyfin:$(python3 "$ROOT/test/versions.py" --root "$ROOT" | tail -n 1)}"
# Taken from the test run, so the versions stay in one place.
SDK_IMAGE="${SDK_IMAGE:-$(sed -n 's/^SDK_IMAGE=.*:-\(.*\)}"/\1/p' "$ROOT/test/run.sh")}"
case "$IMAGE" in *:) echo "test/versions.py named no Jellyfin release" >&2; exit 1 ;; esac
: "${SDK_IMAGE:?could not be read out of test/run.sh}"
BUILD=1

for arg in "$@"; do
    case "$arg" in
        --no-build) BUILD=0 ;;
        *) echo "usage: $0 [--no-build]" >&2; exit 2 ;;
    esac
done

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
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
rm -rf "${WORK:?}/media" "${WORK:?}/probe" "${WORK:?}/config" "${WORK:?}/cache"
mkdir -p "$WORK/config/plugins/Inventory" "$WORK/cache"
python3 "$ROOT/demo/library.py" "$WORK"
cp "$DLL" "$WORK/config/plugins/Inventory/"
python3 "$ROOT/.github/scripts/make-meta.py" --version 9.9.9.0 --root "$ROOT" \
    --out "$WORK/config/plugins/Inventory/meta.json" >/dev/null

echo "== start =="
# probe.sh answers in place of both tools, so nothing has to be encoded for Jellyfin to read.
docker run -d --name "$CONTAINER" --security-opt label=disable --user "$(id -u):$(id -g)" \
    -p "127.0.0.1:$PORT:8096" -e JELLYFIN_FFMPEG=/shim/ffmpeg \
    -v "$ROOT/demo/probe.sh:/shim/ffmpeg:ro" -v "$ROOT/demo/probe.sh:/shim/ffprobe:ro" \
    -v "$WORK/probe:/probe:ro" -v "$WORK/config:/config" -v "$WORK/cache:/cache" -v "$WORK/media:/media:ro" \
    "$IMAGE" >/dev/null
BASE="http://localhost:$PORT"
TOKEN=$(python3 "$ROOT/demo/setup.py" "$BASE" "$WORK") || { docker logs "$CONTAINER" 2>&1 | tail -20 >&2; exit 1; }
echo "The sample library is at $BASE (admin / inventoryshots), in the container $CONTAINER"
