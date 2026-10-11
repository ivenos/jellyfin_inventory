#!/bin/sh
# Stands in for ffmpeg and ffprobe: a file that has a card under /probe is answered from it.
tool=/usr/lib/jellyfin-ffmpeg/$(basename "$0")
for arg in "$@"; do
    case "$arg" in file:*) card="/probe${arg#file:/media}.json" ;; esac
done
[ "$(basename "$0")" = ffprobe ] && [ -f "${card:-}" ] && exec cat "$card"
exec "$tool" "$@"
