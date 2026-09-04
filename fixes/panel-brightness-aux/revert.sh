#!/bin/bash
set -uo pipefail
SUDO="${FIXER_SUDO:-sudo}"
$SUDO systemctl disable --now chromebook-panel-brightness-aux.service 2>/dev/null || true
$SUDO rm -f /etc/systemd/system/chromebook-panel-brightness-aux.service
$SUDO rm -f /usr/local/bin/chromebook-panel-brightness-aux
$SUDO systemctl daemon-reload
echo "panel brightness bridge removed"
echo "note: the panel keeps whatever brightness it was last set to until reboot"
