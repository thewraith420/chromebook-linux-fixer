#!/bin/bash
set -uo pipefail
CONFIGS="${WAYDROID_LXC_CONFIGS:-/usr/lib/waydroid/data/configs/config_base /var/lib/waydroid/lxc/waydroid/config}"
OK=0
for f in $CONFIGS; do
    [ -f "$f" ] || continue
    grep -q "^lxc.hook.post-stop *= */dev/null" "$f" 2>/dev/null && exit 1
    grep -q "^lxc.hook.post-stop" "$f" 2>/dev/null && OK=1
    # Both fixes live in this one id, so both must be in place for either
    # config file that exists - a config missing just the containment line
    # is not "applied" either, the same way a half-reverted edit would not be.
    grep -qF "proc/cmdline" "$f" 2>/dev/null || exit 1
done
[ "$OK" = 1 ] || exit 1
echo "post-stop hook is executable, and the container's /proc/cmdline access is contained, in every waydroid config"
