#!/bin/bash
set -uo pipefail
# Overridable so this can be driven fixture-only (see tests/) - defaults are
# the real paths, unchanged.
CONFIGS="${WAYDROID_LXC_CONFIGS:-/usr/lib/waydroid/data/configs/config_base /var/lib/waydroid/lxc/waydroid/config}"

# Matches only the broken ",ro," form this fix briefly shipped (c6f3110,
# fixed 2026-10-01: a read-only bind makes Android's first-stage init abort
# with EROFS on its fatal chmod("/proc/cmdline", 0440), killing the
# container on every boot - see apply.sh). A config carrying it needs this
# fix just as much as one with no containment line at all; it must not read
# as "already applied" just because a healthy-looking line is present.
is_broken_ro_mount() { grep -qE 'proc/cmdline[[:space:]]+none[[:space:]]+bind,ro,' "$1" 2>/dev/null; }

FOUND=0
for f in $CONFIGS; do
    [ -f "$f" ] || continue
    if grep -q "^lxc.hook.post-stop *= */dev/null" "$f" 2>/dev/null; then
        echo "$f still sets post-stop to /dev/null"
        FOUND=1
    fi
    if is_broken_ro_mount "$f"; then
        echo "$f carries the read-only containment mount, which stops the" \
             "container booting at all - needs migrating"
        FOUND=1
    elif ! grep -qF "proc/cmdline" "$f" 2>/dev/null; then
        echo "$f does not contain the Android container's access to /proc/cmdline"
        FOUND=1
    fi
done
[ "$FOUND" = 1 ] && exit 0
# waydroid absent entirely?
set -- $CONFIGS
[ -f "$1" ] || exit 1
exit 1
