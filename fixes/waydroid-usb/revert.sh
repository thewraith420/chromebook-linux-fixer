#!/bin/bash
set -uo pipefail
for f in /var/lib/waydroid/lxc/waydroid/config_nodes /usr/lib/waydroid/tools/helpers/lxc.py; do
    [ -f "$f.chromebook-fixer.orig" ] || continue
    sudo cp -a "$f.chromebook-fixer.orig" "$f"
    echo "restored $f"
done
