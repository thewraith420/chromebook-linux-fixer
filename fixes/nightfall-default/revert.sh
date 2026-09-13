#!/bin/bash
set -uo pipefail
SUDO="${FIXER_SUDO:-sudo}"
F=/etc/default/grub

$SUDO bash -s -- "$F" <<'ROOT'
set -uo pipefail
F="$1"
# Prefer the backup this fix took: it restores whatever was there before,
# rather than assuming the previous value was 0.
BAK=$(ls -1t "$F".chromebook-fixer.* 2>/dev/null | head -1)
if [ -n "$BAK" ] && [ -r "$BAK" ]; then
    cp -a "$BAK" "$F"
    echo "restored $F from $BAK"
else
    # No backup - set a first-entry default rather than leaving the machine
    # pointed at an entry this fix is meant to be stepping away from.
    if grep -qE '^GRUB_DEFAULT=' "$F"; then
        sed -i 's|^GRUB_DEFAULT=.*|GRUB_DEFAULT=0|' "$F"
    else
        echo 'GRUB_DEFAULT=0' >> "$F"
    fi
    echo "no backup found; set GRUB_DEFAULT=0"
fi
update-grub >/dev/null 2>&1 || echo "warning: update-grub failed; run it yourself" >&2
ROOT
echo "GRUB no longer boots Nightfall by default; select it from the menu."
