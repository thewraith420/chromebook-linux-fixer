#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail
SUDO="${FIXER_SUDO:-sudo}"
$SUDO rm -f /etc/udev/rules.d/60-chromebook-backlight.rules
$SUDO udevadm control --reload-rules
$SUDO udevadm trigger --subsystem-match=backlight
echo "removed the backlight rule. Group membership was left alone;"
echo "remove it with:  sudo gpasswd -d \$USER video"
