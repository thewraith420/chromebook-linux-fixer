#!/bin/bash
# exit 0 = needed, 1 = not needed / not applicable, 2 = cannot tell
set -uo pipefail

# Needs a Chrome EC exposing the command chardev.
[ -e /dev/cros_ec ] || exit 1

# If the kernel is already draining the EC event FIFO (patch 9201, or the DKMS
# fix), userspace must NOT also drain it - the two would race. Stand down.
POLL=/sys/module/cros_ec/parameters/ec_event_poll_ms
if [ -r "$POLL" ] && [ "$(cat "$POLL" 2>/dev/null || echo 0)" -gt 0 ] 2>/dev/null; then
    exit 1
fi

# Already running ours?
systemctl is-active chromebook-ec-buttons.service >/dev/null 2>&1 && exit 1

# The DKMS add-on (ec-buttons-dkms) does the same job in-kernel. They are
# alternatives - if it is loaded, this userspace poll is not needed.
[ -d /sys/module/cros_ec_evpoll ] && exit 1

# The dead-EC-delivery fault is board specific. Only offer this where it is
# confirmed - enabling it on a board whose EC path works would race the kernel
# for events. Add confirmed boards here as they are verified.
VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo)
PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo)
case "$VENDOR/$PRODUCT" in
    Google/Nocturne) ;;                      # Pixel Slate — confirmed
    *)
        # Chrome EC present but board not on the confirmed list. Can't safely
        # tell whether its async event path works without pressing a button.
        echo "Chrome EC present but $VENDOR/$PRODUCT is not on the confirmed" \
             "dead-delivery list; not offering to avoid racing a working EC"
        exit 1
        ;;
esac

echo "$VENDOR $PRODUCT: EC present, async delivery known-dead, kernel not polling"
exit 0
