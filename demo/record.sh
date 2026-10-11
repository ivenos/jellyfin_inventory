#!/bin/sh
# Records demo/web/data.json from the sample library and checks the demo against the server it came from.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# Taken from the test run, so the versions stay in one place.
NODE_IMAGE="${NODE_IMAGE:-$(sed -n 's/^NODE_IMAGE=.*:-\(.*\)}"/\1/p' "$ROOT/test/run.sh")}"
trap 'docker rm -f "${CONTAINER:-}" >/dev/null 2>&1 || true' EXIT
. "$ROOT/demo/serve.sh"

echo "== record =="
docker run --rm --init --security-opt label=disable --user "$(id -u):$(id -g)" \
    --network "container:$CONTAINER" -v "$ROOT:/src" -w /src "$NODE_IMAGE" \
    node demo/record.mjs http://localhost:8096 "$TOKEN"
