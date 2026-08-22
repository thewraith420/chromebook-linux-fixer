#!/bin/bash
set -uo pipefail
OK=0
for f in /usr/lib/waydroid/data/configs/config_base /var/lib/waydroid/lxc/waydroid/config; do
    [ -f "$f" ] || continue
    grep -q "^lxc.hook.post-stop *= */dev/null" "$f" 2>/dev/null && exit 1
    grep -q "^lxc.hook.post-stop" "$f" 2>/dev/null && OK=1
done
[ "$OK" = 1 ] || exit 1
echo "post-stop hook is executable in every waydroid config"
