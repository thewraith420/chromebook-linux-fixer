#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail
SUDO="${FIXER_SUDO:-sudo}"
$SUDO systemctl disable --now chromebook-tablet-switch.service 2>/dev/null || true
$SUDO rm -f /etc/systemd/system/chromebook-tablet-switch.service
$SUDO rm -f /usr/local/bin/chromebook-tablet-switch.py
$SUDO systemctl daemon-reload
echo "removed. GNOME will stop auto-rotating after the next login."
