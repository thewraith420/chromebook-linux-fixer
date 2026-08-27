#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail
SUDO="${FIXER_SUDO:-sudo}"

$SUDO rm -f /etc/systemd/zram-generator.conf
$SUDO systemctl stop systemd-zram-setup@zram0.service 2>/dev/null || true
$SUDO swapoff /dev/zram0 2>/dev/null || true
$SUDO systemctl daemon-reload
echo "removed the zram configuration. Any disk swap is untouched."
echo "The package systemd-zram-generator is left installed; remove it with"
echo "  sudo apt remove systemd-zram-generator"
