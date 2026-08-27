#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail
RULES=/etc/udev/rules.d/60-chromebook-backlight.rules

writable=0
for b in /sys/class/backlight/*/brightness; do
    [ -w "$b" ] && writable=1
done

if [ -e "$RULES" ]; then
    [ "$writable" = "1" ] && { echo "brightness writable via the video group"; exit 0; }
    echo "rule installed but brightness is still not writable - log out and back in"
    exit 1
fi
[ "$writable" = "1" ] && { echo "brightness is already writable, but not via this fix"; exit 3; }
exit 1
