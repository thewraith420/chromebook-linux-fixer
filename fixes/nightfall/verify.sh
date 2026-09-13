#!/bin/bash
# exit 0 = this fix is in place, 1 = it is not
set -uo pipefail

# Renamed project: match either marker, and either directory it installs into.
PICKER_NAMES="nightfall-boot-manager nocturne-boot-picker"
CUSTOM_CFG="${CUSTOM_CFG:-/boot/grub/custom.cfg}"

picker_marker() {
    local n
    for n in $PICKER_NAMES; do
        grep -qsF "### BEGIN $n ###" "$CUSTOM_CFG" 2>/dev/null && { echo "$n"; return 0; }
    done
    return 1
}

PICKER_DIR=
for d in /boot/nightfall /boot/picker; do
    [ -d "$d" ] && { PICKER_DIR="$d"; break; }
done
PICKER_DIR="${PICKER_DIR:-/boot/nightfall}"

NAME=$(picker_marker) || exit 1

# The entry alone is not the fix. An entry pointing at files that are not there
# is worse than no entry: it boots to a GRUB error on a machine whose menu
# cannot be navigated without a keyboard.
MISSING=""
for f in vmlinuz initramfs.img; do
    [ -r "$PICKER_DIR/$f" ] || MISSING="$MISSING $PICKER_DIR/$f"
done
if [ -n "$MISSING" ]; then
    echo "picker entry present but its files are missing:$MISSING"
    exit 1
fi

# Nightfall records how the last boot through it went, and a fallback is the
# thing worth noticing: it means the display or touch did not come up and it
# booted the first kernel blind rather than stranding the machine. That
# succeeds, so nothing else would ever mention it - which is how a degraded
# boot path stays invisible until the fallback also fails.
LOG=""
for c in /boot/nightfall-last-boot.log /boot/picker-last-boot.log; do
    [ -r "$c" ] && { LOG="$c"; break; }
done
OUTCOME=""
[ -n "$LOG" ] && OUTCOME=$(sed -n 's/^outcome:[[:space:]]*//p' "$LOG" | head -1)

DEFAULT=$(grep -hE '^GRUB_DEFAULT=' /etc/default/grub 2>/dev/null | cut -d= -f2- | tr -d '"')
echo "Nightfall installed [$NAME] ($(du -h "$PICKER_DIR/vmlinuz" | cut -f1) kernel,"\
     "$(du -h "$PICKER_DIR/initramfs.img" | cut -f1) initramfs)"
case "$DEFAULT" in
    picker|nightfall) echo "and it is the default GRUB entry" ;;
    *)      echo "selectable from the GRUB menu; not the default" ;;
esac
case "$OUTCOME" in
    "")      ;;                       # never booted through it, or no log
    *fallback*|*failed*|*error*)
        echo "WARNING: last boot through it ended in: $OUTCOME"
        echo "see 'chromebook-fixer logs nightfall' for why" ;;
    *)       echo "last boot through it: $OUTCOME" ;;
esac
