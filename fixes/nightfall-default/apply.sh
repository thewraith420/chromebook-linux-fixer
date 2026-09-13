#!/bin/bash
set -euo pipefail
SUDO="${FIXER_SUDO:-sudo}"
MARK="# set by chromebook-fixer (nightfall-default)"
F=/etc/default/grub
STAMP=$(date +%Y%m%d%H%M%S)

PREV=$(grep -hE '^GRUB_DEFAULT=' "$F" 2>/dev/null | head -1)
echo "current: ${PREV:-(GRUB_DEFAULT unset)}"
echo "setting GRUB_DEFAULT=nightfall and regenerating grub.cfg"

# One escalation: under the GUI $SUDO is pkexec with no credential cache, so
# every separate call is another authentication prompt.
$SUDO bash -s -- "$F" "$STAMP" "$MARK" <<'ROOT'
set -euo pipefail
F="$1"; STAMP="$2"; MARK="$3"
BAK="$F.chromebook-fixer.$STAMP"

cp -a "$F" "$BAK"
echo "backed up $F to $BAK"

# Replace the setting if it exists, add it if it does not. The marker goes on
# the line itself so verify can tell this fix's work from a hand edit, and so
# anyone reading /etc/default/grub sees who did it.
if grep -qE '^GRUB_DEFAULT=' "$F"; then
    sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=nightfall  $MARK|" "$F"
else
    printf 'GRUB_DEFAULT=nightfall  %s\n' "$MARK" >> "$F"
fi

if ! update-grub >/dev/null 2>&1; then
    echo "update-grub failed; restoring $F" >&2
    cp -a "$BAK" "$F"
    update-grub >/dev/null 2>&1 || true
    exit 1
fi

# A successful update-grub does not prove the setting reached grub.cfg.
if ! grep -qE '^[[:space:]]*set default=("?)nightfall\1' /boot/grub/grub.cfg; then
    echo "grub.cfg does not name nightfall as the default; restoring" >&2
    cp -a "$BAK" "$F"
    update-grub >/dev/null 2>&1 || true
    exit 1
fi
echo "grub.cfg now defaults to the nightfall entry"
ROOT

echo
echo "Done. The next boot goes straight into Nightfall's touch menu."
echo "If it ever misbehaves, it still falls back to booting the first kernel,"
echo "and 'chromebook-fixer revert nightfall-default' puts this back."
