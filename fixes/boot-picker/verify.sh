#!/bin/bash
# exit 0 = this fix is in place, 1 = it is not
set -uo pipefail

BEGIN_MARK="### BEGIN nocturne-boot-picker ###"
CUSTOM_CFG=/boot/grub/custom.cfg
PICKER_DIR=/boot/picker

grep -qsF "$BEGIN_MARK" "$CUSTOM_CFG" 2>/dev/null || exit 1

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

DEFAULT=$(grep -hE '^GRUB_DEFAULT=' /etc/default/grub 2>/dev/null | cut -d= -f2- | tr -d '"')
echo "touch boot picker installed ($(du -h "$PICKER_DIR/vmlinuz" | cut -f1) kernel,"\
     "$(du -h "$PICKER_DIR/initramfs.img" | cut -f1) initramfs)"
case "$DEFAULT" in
    picker) echo "and it is the default GRUB entry" ;;
    *)      echo "selectable from the GRUB menu; not the default" ;;
esac
