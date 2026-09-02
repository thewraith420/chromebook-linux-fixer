#!/bin/bash
set -uo pipefail
SUDO="${FIXER_SUDO:-sudo}"
TPLG=/lib/firmware/intel/avs/max98357a-tplg.bin
TPLG_BAK="$TPLG.chromebook-fixer.bak"

$SUDO rm -f /etc/modprobe.d/chromebook-audio-avs.conf
# Put back the MAX98357A topology if apply moved it aside, so reverting leaves
# the firmware package's files as they were found.
if [ -e "$TPLG_BAK" ]; then
    if [ -e "$TPLG" ]; then
        # The firmware package reinstalled it while the fix was applied; that
        # copy is authoritative, so discard ours rather than overwrite it.
        $SUDO rm -f "$TPLG_BAK"
        echo "$(basename "$TPLG") was already reinstated by its package"
    else
        $SUDO mv "$TPLG_BAK" "$TPLG"
        echo "restored $(basename "$TPLG")"
    fi
fi
$SUDO update-initramfs -u
echo "AVS override removed; reboot to return to the default DSP driver selection"
