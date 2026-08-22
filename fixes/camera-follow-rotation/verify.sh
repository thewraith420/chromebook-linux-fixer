#!/bin/bash
set -uo pipefail
systemctl --user is-enabled chromebook-camera-rotate.service >/dev/null 2>&1 || exit 1
STATE=$(systemctl --user is-active chromebook-camera-rotate.service 2>/dev/null || true)
DEV=""
for n in /sys/class/video4linux/video*/name; do
    grep -qi "chromebook camera" "$n" 2>/dev/null && DEV="/dev/$(basename "$(dirname "$n")")"
done
echo "rotation bridge enabled (currently $STATE)${DEV:+, publishing on $DEV}"
