#!/bin/bash
set -uo pipefail
FOUND=0
for f in /usr/lib/waydroid/data/configs/config_base /var/lib/waydroid/lxc/waydroid/config; do
    [ -f "$f" ] || continue
    if grep -q "^lxc.hook.post-stop *= */dev/null" "$f" 2>/dev/null; then
        echo "$f still sets post-stop to /dev/null"
        FOUND=1
    fi
done
[ "$FOUND" = 1 ] && exit 0
# waydroid absent entirely?
[ -f /usr/lib/waydroid/data/configs/config_base ] || exit 1
exit 1
