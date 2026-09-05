#!/bin/bash
# exit 0 = needed, 1 = not needed / not applicable, 2 = cannot tell
set -uo pipefail

DRIVER=/sys/bus/i2c/drivers/i2c_hid_acpi
HOOK=/usr/lib/systemd/system-sleep/chromebook-touch-resume

# Needs an I2C-HID device bound to the ACPI variant of the driver.
[ -d "$DRIVER" ] || exit 1
FOUND=1
for path in "$DRIVER"/*; do
    dev=${path##*/}
    case "$dev" in bind|unbind|uevent|module|new_id|remove_id) continue ;; esac
    [ -L "$path" ] && FOUND=0
done
[ "$FOUND" -eq 0 ] || exit 1

# Already installed?
[ -x "$HOOK" ] && exit 1

# Board specific - only offer where the dead-touch-after-resume fault is
# confirmed. Add boards here as they are verified.
VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo)
PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo)
case "$VENDOR/$PRODUCT" in
    Google/Nocturne) ;;                      # Pixel Slate — confirmed
    *)
        echo "I2C-HID touchscreen present but $VENDOR/$PRODUCT is not on the" \
             "confirmed dead-after-resume list; not offering"
        exit 1
        ;;
esac

echo "$VENDOR $PRODUCT: I2C-HID touchscreen present, known to die across suspend"
exit 0
