#!/bin/bash
set -uo pipefail
HOOK=/usr/lib/systemd/system-sleep/chromebook-touch-resume
[ -x "$HOOK" ] || exit 1
echo "touchscreen resume hook installed at $HOOK"
