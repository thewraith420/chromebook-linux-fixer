#!/bin/bash
set -uo pipefail

# Escalation is chosen by the caller: plain sudo in a terminal, pkexec
# under the GUI, which has no tty to prompt on.
SUDO="${FIXER_SUDO:-sudo}"
CONFIGS="${WAYDROID_LXC_CONFIGS:-/usr/lib/waydroid/data/configs/config_base /var/lib/waydroid/lxc/waydroid/config}"
for f in $CONFIGS; do
    [ -f "$f.chromebook-fixer.orig" ] || continue
    $SUDO cp -a "$f.chromebook-fixer.orig" "$f"
    echo "restored $f"
done

# The cmdline snapshot apply.sh may have created: harmless to leave (nothing
# references it once the mount.entry line above is gone), but tidy to remove
# since this fix reverts cleanly.
CMDLINE_SNAPSHOT="${WAYDROID_CMDLINE_SNAPSHOT:-/var/lib/waydroid/chromebook-fixer-cmdline}"
[ -f "$CMDLINE_SNAPSHOT" ] && $SUDO rm -f "$CMDLINE_SNAPSHOT"
