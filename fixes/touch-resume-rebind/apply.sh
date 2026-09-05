#!/bin/bash
set -euo pipefail
SUDO="${FIXER_SUDO:-sudo}"
FIX_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_SRC="$FIX_DIR/suspend-hook/chromebook-touch-resume"
HOOK_DST=/usr/lib/systemd/system-sleep/chromebook-touch-resume
[ -x "$HOOK_SRC" ] || { echo "missing $HOOK_SRC"; exit 1; }

echo "Installing a resume hook that rebinds the I2C-HID touchscreen."
echo "It runs on resume only, and takes about a second."
echo

$SUDO install -m 0755 "$HOOK_SRC" "$HOOK_DST"
echo "Installed $HOOK_DST"
echo "Test it by suspending and resuming, then touching the screen."
