#!/bin/bash
set -uo pipefail
command -v cam >/dev/null 2>&1 || exit 1

# Capture once rather than piping cam into grep twice.
#
# Two reasons: running cam repeatedly needlessly claims the camera, and
# `cam -l | grep -q` is a trap under `set -o pipefail` - grep -q exits at the
# first match, cam takes SIGPIPE, and pipefail then reports the whole pipeline
# as failed even though the match succeeded.
OUT=$(timeout 60 cam -l 2>&1) || true

COUNT=$(printf '%s\n' "$OUT" | grep -cE "^[0-9]+: ") || true
[ "${COUNT:-0}" -gt 0 ] || exit 1

if printf '%s\n' "$OUT" | grep -q "pipeline handler ipu3"; then
    echo "$COUNT camera(s), hardware ISP (ipu3 pipeline handler)"
elif printf '%s\n' "$OUT" | grep -q "pipeline handler simple"; then
    echo "$COUNT camera(s), software ISP (simple pipeline handler)"
else
    echo "$COUNT camera(s)"
fi
