#!/bin/bash
set -uo pipefail
NODES=/var/lib/waydroid/lxc/waydroid/config_nodes
[ -f "$NODES" ] || exit 1                     # waydroid not initialised
grep -q "dev/bus/usb" "$NODES" 2>/dev/null && exit 1
echo "waydroid container has no USB passthrough configured"
exit 0
