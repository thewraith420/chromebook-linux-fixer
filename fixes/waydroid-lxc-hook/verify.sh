#!/bin/bash
set -uo pipefail
CONFIGS="${WAYDROID_LXC_CONFIGS:-/usr/lib/waydroid/data/configs/config_base /var/lib/waydroid/lxc/waydroid/config}"

# Same pattern as detect.sh and apply.sh - kept in sync, see apply.sh for why
# the read-only form must never read as applied: it is a container that
# fails to boot, not a working install.
is_broken_ro_mount() { grep -qE 'proc/cmdline[[:space:]]+none[[:space:]]+bind,ro,' "$1" 2>/dev/null; }

OK=0
for f in $CONFIGS; do
    [ -f "$f" ] || continue
    grep -q "^lxc.hook.post-stop *= */dev/null" "$f" 2>/dev/null && exit 1
    grep -q "^lxc.hook.post-stop" "$f" 2>/dev/null && OK=1
    # Both fixes live in this one id, so both must be in place for either
    # config file that exists - a config missing just the containment line,
    # or still carrying its broken read-only form, is not "applied" either.
    is_broken_ro_mount "$f" && exit 1
    grep -qF "proc/cmdline" "$f" 2>/dev/null || exit 1
done
[ "$OK" = 1 ] || exit 1
echo "post-stop hook is executable, and the container's /proc/cmdline access is contained read-write, in every waydroid config"
