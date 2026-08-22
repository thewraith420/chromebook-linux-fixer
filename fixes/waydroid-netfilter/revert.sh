#!/bin/bash
set -euo pipefail
SCRIPT=/usr/lib/waydroid/data/scripts/waydroid-net.sh
BACKUP="$SCRIPT.chromebook-fixer.orig"
[ -f "$BACKUP" ] || { echo "no backup found at $BACKUP"; exit 1; }
sudo cp -a "$BACKUP" "$SCRIPT"
echo "restored original $SCRIPT"
