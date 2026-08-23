#!/bin/bash
set -euo pipefail

# Escalation is chosen by the caller: plain sudo in a terminal,
# "sudo -A" under the GUI, which has no tty to prompt on.
SUDO="${FIXER_SUDO:-sudo}"
NODES=/var/lib/waydroid/lxc/waydroid/config_nodes
LXCPY=/usr/lib/waydroid/tools/helpers/lxc.py
ENTRY="lxc.mount.entry = /dev/bus/usb dev/bus/usb none bind,create=dir,optional 0 0"

[ -f "$NODES" ] || { echo "waydroid is not initialised ($NODES missing)"; exit 1; }

# Live config, for the current session.
if ! grep -q "dev/bus/usb" "$NODES"; then
    [ -f "$NODES.chromebook-fixer.orig" ] || $SUDO cp -a "$NODES" "$NODES.chromebook-fixer.orig"
    $SUDO tee -a "$NODES" >/dev/null <<< "$ENTRY"
    echo "added USB bind to $NODES"
fi

# Generator, so it survives the config being regenerated.
if [ -f "$LXCPY" ] && ! grep -q "dev/bus/usb" "$LXCPY"; then
    [ -f "$LXCPY.chromebook-fixer.orig" ] || $SUDO cp -a "$LXCPY" "$LXCPY.chromebook-fixer.orig"
    $SUDO python3 - "$LXCPY" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
if "dev/bus/usb" not in s:
    # Append after the last make_entry call in the nodes generator.
    marker = re.search(r'\n(\s*)make_entry\([^\n]*\)\n', s)
    if marker:
        indent = marker.group(1)
        add = (f'\n{indent}# USB passthrough (security keys etc). Bind the whole tree:\n'
               f'{indent}# bus/device numbers change on reconnect, so per-node entries break.\n'
               f'{indent}make_entry("/dev/bus/usb", options="bind,create=dir,optional 0 0")\n')
        idx = s.rfind(marker.group(0))
        s = s[:idx + len(marker.group(0))] + add + s[idx + len(marker.group(0)):]
        open(p, "w").write(s)
PY
    echo "patched $LXCPY so regenerated configs keep it"
fi
echo "restart the waydroid session for this to take effect:"
echo "  waydroid session stop && waydroid session start"
