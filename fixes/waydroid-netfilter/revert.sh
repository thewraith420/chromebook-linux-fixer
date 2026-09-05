#!/bin/bash
set -euo pipefail

# Escalation is chosen by the caller: plain sudo in a terminal, pkexec
# under the GUI, which has no tty to prompt on.
SUDO="${FIXER_SUDO:-sudo}"
SCRIPT=/usr/lib/waydroid/data/scripts/waydroid-net.sh
BACKUP="$SCRIPT.chromebook-fixer.orig"
[ -f "$BACKUP" ] || { echo "no backup found at $BACKUP"; exit 1; }
$SUDO cp -a "$BACKUP" "$SCRIPT"
echo "restored original $SCRIPT"
