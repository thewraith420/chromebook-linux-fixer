#!/bin/bash
set -uo pipefail
SCRIPT=/usr/lib/waydroid/data/scripts/waydroid-net.sh
[ -f "$SCRIPT" ] || exit 1                      # waydroid not installed
# Already patched?
grep -q "chromebook-fixer" "$SCRIPT" && exit 1
# Only needed when the legacy module genuinely cannot load.
if modprobe -n ip_tables >/dev/null 2>&1; then
    exit 1                                       # legacy path is available
fi
grep -q "iptables-legacy" "$SCRIPT" || exit 1
echo "waydroid prefers iptables-legacy but ip_tables cannot load on this kernel"
exit 0
