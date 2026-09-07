#!/bin/bash
# exit 0 = needed, 1 = not needed / not applicable, 2 = cannot tell
set -uo pipefail

BEGIN_MARK="### BEGIN nocturne-boot-picker ###"
CUSTOM_CFG=/boot/grub/custom.cfg

# The picker is a GRUB entry that chainloads a kernel. No GRUB, nothing to add.
[ -d /boot/grub ] || exit 1

# Already installed? The markers install-picker.sh writes are the record.
if grep -qsF "$BEGIN_MARK" "$CUSTOM_CFG" 2>/dev/null; then
    exit 1
fi

# The problem this solves is "no keyboard, so the boot menu cannot be
# navigated". A machine with a keyboard attached has a working answer already,
# but keyboards come and go on a convertible - the tablet is the normal state
# and that is what this is for. Report the condition, not the current posture.
TOUCH=no
for d in /sys/class/input/input*/name; do
    grep -qiE "touchscreen|wacom|hid.*touch" "$d" 2>/dev/null && { TOUCH=yes; break; }
done
if [ "$TOUCH" = no ]; then
    echo "no touchscreen found; a touch boot menu would have nothing to read"
    exit 1
fi

echo "GRUB's menu needs a keyboard this machine may not have attached;"
echo "no touch boot picker is installed"
exit 0
