#!/bin/bash
set -uo pipefail
SUDO="${FIXER_SUDO:-sudo}"
$SUDO rm -f /usr/lib/systemd/system-sleep/chromebook-touch-resume
echo "touchscreen resume hook removed"
