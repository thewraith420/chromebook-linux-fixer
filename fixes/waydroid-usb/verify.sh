#!/bin/bash
set -uo pipefail
NODES=/var/lib/waydroid/lxc/waydroid/config_nodes
[ -f "$NODES" ] || exit 1
grep -q "dev/bus/usb" "$NODES" 2>/dev/null || exit 1
echo "USB tree bound into the waydroid container"
