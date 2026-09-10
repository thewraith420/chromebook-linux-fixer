#!/bin/bash
set -uo pipefail
SUDO="${FIXER_SUDO:-sudo}"

# Prefer the picker's own uninstaller, which is what wrote all of this. Fall
# back to removing the same things by hand, because revert has to work on a
# machine where the checkout has since been deleted - otherwise the only way
# out of a boot entry is to still have the source tree that made it.
REPO="${FIXER_PICKER_REPO:-}"
if [ -z "$REPO" ]; then
    for c in "$HOME/nightfall-boot-manager" "$HOME/buildstuff/nightfall-boot-manager" \
             "$HOME/nocturne-boot-picker" "$HOME/buildstuff/nocturne-boot-picker"; do
        [ -d "$c" ] && { REPO="$c"; break; }
    done
fi

UNINSTALLER=
for cand in install-nightfall.sh install-picker.sh; do
    [ -n "$REPO" ] && [ -x "$REPO/boot-integration/$cand" ] && {
        UNINSTALLER="$REPO/boot-integration/$cand"; break; }
done

if [ -n "$UNINSTALLER" ]; then
    $SUDO "$UNINSTALLER" --uninstall
else
    echo "picker checkout not found; removing its files directly"
    # Delete BOTH markers and BOTH directories. The project was renamed, so a
    # revert can meet either layout - and a sed that matches neither removes
    # nothing while exiting 0, which would report the boot entry gone while
    # leaving it in place. That is the worst possible thing for revert to be
    # wrong about on a machine whose boot menu needs a keyboard to escape.
    $SUDO bash -s <<'ROOT'
set -uo pipefail
CUSTOM_CFG=/boot/grub/custom.cfg
REMOVED=0
for n in nightfall-boot-manager nocturne-boot-picker; do
    if [ -f "$CUSTOM_CFG" ] && grep -qF "### BEGIN $n ###" "$CUSTOM_CFG"; then
        sed -i "/### BEGIN $n ###/,/### END $n ###/d" "$CUSTOM_CFG"
        echo "removed the $n entry from $CUSTOM_CFG"
        REMOVED=1
    fi
done
for d in /boot/nightfall /boot/picker; do
    [ -d "$d" ] && { rm -rf "$d"; echo "removed $d"; REMOVED=1; }
done
[ "$REMOVED" = 1 ] || echo "nothing to remove - no picker entry or directory found"
echo "grub.cfg was not regenerated"
ROOT
fi

# Leaving GRUB_DEFAULT=picker behind would point the default entry at something
# that no longer exists, which on a keyboardless machine is the worst possible
# parting gift. Say so rather than silently editing /etc/default/grub, which
# this fix never wrote.
DEFAULT=$(grep -hE '^GRUB_DEFAULT=' /etc/default/grub 2>/dev/null | cut -d= -f2- | tr -d '"')
if [ "$DEFAULT" = picker ] || [ "$DEFAULT" = nightfall ]; then
    echo
    echo "WARNING: /etc/default/grub still has GRUB_DEFAULT=$DEFAULT, and that"
    echo "entry is now gone. Set it to 0 and run update-grub BEFORE rebooting."
fi
