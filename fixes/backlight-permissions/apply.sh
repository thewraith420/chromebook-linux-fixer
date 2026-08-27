#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
SUDO="${FIXER_SUDO:-sudo}"
RULES=/etc/udev/rules.d/60-chromebook-backlight.rules
USER_NAME="${SUDO_USER:-$USER}"

$SUDO tee "$RULES" >/dev/null <<'RULEEOF'
# Written by chromebook-fixer (backlight-permissions).
#
# Give the video group write access to brightness. Not MODE="0666": that is
# world-writable, letting any local account change the display. Group
# ownership keeps it to accounts meant to drive display hardware.
ACTION=="add", SUBSYSTEM=="backlight", \
  RUN+="/bin/chgrp video /sys/class/backlight/%k/brightness", \
  RUN+="/bin/chmod 0664 /sys/class/backlight/%k/brightness"
RULEEOF
echo "wrote $RULES"

if ! id -nG "$USER_NAME" 2>/dev/null | tr ' ' '\n' | grep -qx video; then
    $SUDO usermod -aG video "$USER_NAME"
    echo "added $USER_NAME to the video group"
    NEEDS_LOGIN=1
else
    echo "$USER_NAME is already in the video group"
    NEEDS_LOGIN=0
fi

$SUDO udevadm control --reload-rules
$SUDO udevadm trigger --subsystem-match=backlight
echo "reloaded udev rules"

[ "$NEEDS_LOGIN" = "1" ] && {
    echo
    echo "Log out and back in - group membership only applies to new sessions."
}
exit 0
