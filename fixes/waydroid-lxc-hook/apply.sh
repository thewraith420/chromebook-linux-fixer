#!/bin/bash
set -euo pipefail
CHANGED=0
for f in /usr/lib/waydroid/data/configs/config_base /var/lib/waydroid/lxc/waydroid/config; do
    [ -f "$f" ] || continue
    grep -q "^lxc.hook.post-stop *= */dev/null" "$f" || continue
    [ -f "$f.chromebook-fixer.orig" ] || sudo cp -a "$f" "$f.chromebook-fixer.orig"
    sudo sed -i 's|^lxc.hook.post-stop *= */dev/null|lxc.hook.post-stop = /bin/true|' "$f"
    echo "patched $f"
    CHANGED=1
done
[ "$CHANGED" = 1 ] || echo "nothing to change"
