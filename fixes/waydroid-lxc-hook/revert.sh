#!/bin/bash
set -uo pipefail
for f in /usr/lib/waydroid/data/configs/config_base /var/lib/waydroid/lxc/waydroid/config; do
    [ -f "$f.chromebook-fixer.orig" ] || continue
    sudo cp -a "$f.chromebook-fixer.orig" "$f"
    echo "restored $f"
done
