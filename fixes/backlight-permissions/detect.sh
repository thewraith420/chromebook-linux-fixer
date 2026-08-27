#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail
RULES=/etc/udev/rules.d/60-chromebook-backlight.rules
[ -e "$RULES" ] && exit 1

ls /sys/class/backlight/*/brightness >/dev/null 2>&1 || exit 1

# Can the user already write it, by any means (logind ACL, group, or a rule)?
for b in /sys/class/backlight/*/brightness; do
    [ -w "$b" ] && exit 1
done

echo "brightness is not writable by this user; only root can change the screen"
exit 0
