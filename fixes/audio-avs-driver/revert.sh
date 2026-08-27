#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail
SUDO="${FIXER_SUDO:-sudo}"
$SUDO rm -f /etc/modprobe.d/chromebook-audio-avs.conf
command -v update-initramfs >/dev/null && $SUDO update-initramfs -u >/dev/null 2>&1 || true
echo "removed the AVS override; driver selection returns to automatic on reboot."
