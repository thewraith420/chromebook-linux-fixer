#!/bin/bash
set -uo pipefail
# Overridable so this can be driven fixture-only (see tests/) - defaults are
# the real paths, unchanged.
CONFIGS="${WAYDROID_LXC_CONFIGS:-/usr/lib/waydroid/data/configs/config_base /var/lib/waydroid/lxc/waydroid/config}"
FOUND=0
for f in $CONFIGS; do
    [ -f "$f" ] || continue
    if grep -q "^lxc.hook.post-stop *= */dev/null" "$f" 2>/dev/null; then
        echo "$f still sets post-stop to /dev/null"
        FOUND=1
    fi
    # The container touching the host's real /proc/cmdline (see apply.sh) -
    # every config missing the containment mount still needs it added.
    if ! grep -qF "proc/cmdline" "$f" 2>/dev/null; then
        echo "$f does not contain the Android container's access to /proc/cmdline"
        FOUND=1
    fi
done
[ "$FOUND" = 1 ] && exit 0
# waydroid absent entirely?
set -- $CONFIGS
[ -f "$1" ] || exit 1
exit 1
