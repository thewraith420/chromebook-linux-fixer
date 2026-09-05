#!/bin/bash
set -uo pipefail

# Escalation is chosen by the caller: plain sudo in a terminal, pkexec
# under the GUI, which has no tty to prompt on.
SUDO="${FIXER_SUDO:-sudo}"
for f in /var/lib/waydroid/lxc/waydroid/config_nodes /usr/lib/waydroid/tools/helpers/lxc.py; do
    [ -f "$f.chromebook-fixer.orig" ] || continue
    $SUDO cp -a "$f.chromebook-fixer.orig" "$f"
    echo "restored $f"
done
