#!/bin/bash
set -uo pipefail
SUDO="${FIXER_SUDO:-sudo}"

# Prefer the picker's own uninstaller, which is what wrote all of this. Fall
# back to removing the same things by hand, because revert has to work on a
# machine where the checkout has since been deleted - otherwise the only way
# out of a boot entry is to still have the source tree that made it.
REPO="${FIXER_PICKER_REPO:-}"
if [ -z "$REPO" ]; then
    for c in "$HOME/nocturne-boot-picker" "$HOME/buildstuff/nocturne-boot-picker"; do
        [ -d "$c" ] && { REPO="$c"; break; }
    done
fi

if [ -n "$REPO" ] && [ -x "$REPO/boot-integration/install-picker.sh" ]; then
    $SUDO "$REPO/boot-integration/install-picker.sh" --uninstall
else
    echo "picker checkout not found; removing its files directly"
    $SUDO bash -s <<'ROOT'
set -uo pipefail
CUSTOM_CFG=/boot/grub/custom.cfg
if [ -f "$CUSTOM_CFG" ]; then
    sed -i '/### BEGIN nocturne-boot-picker ###/,/### END nocturne-boot-picker ###/d' \
        "$CUSTOM_CFG"
fi
rm -rf /boot/picker
echo "picker entry and /boot/picker removed; grub.cfg was not regenerated"
ROOT
fi

# Leaving GRUB_DEFAULT=picker behind would point the default entry at something
# that no longer exists, which on a keyboardless machine is the worst possible
# parting gift. Say so rather than silently editing /etc/default/grub, which
# this fix never wrote.
DEFAULT=$(grep -hE '^GRUB_DEFAULT=' /etc/default/grub 2>/dev/null | cut -d= -f2- | tr -d '"')
if [ "$DEFAULT" = picker ]; then
    echo
    echo "WARNING: /etc/default/grub still has GRUB_DEFAULT=picker, and that"
    echo "entry is now gone. Set it to 0 and run update-grub BEFORE rebooting."
fi
