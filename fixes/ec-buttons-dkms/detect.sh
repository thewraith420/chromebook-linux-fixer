#!/bin/bash
# exit 0 = needed, 1 = not needed / not applicable, 2 = cannot tell
set -uo pipefail

# Needs a Chrome EC exposing the command chardev.
[ -e /dev/cros_ec ] || exit 1

# Already loaded ours?
[ -d /sys/module/cros_ec_evpoll ] && exit 1

# Kernel already polls the FIFO in-tree (patch 9201)? Then this is redundant.
POLL=/sys/module/cros_ec/parameters/ec_event_poll_ms
if [ -r "$POLL" ] && [ "$(cat "$POLL" 2>/dev/null || echo 0)" -gt 0 ] 2>/dev/null; then
    exit 1
fi

# The userspace alternative (ec-buttons-poll) already covers it?
systemctl is-active chromebook-ec-buttons.service >/dev/null 2>&1 && exit 1

# Board-specific fault; only offer where confirmed (keep in sync with
# ec-buttons-poll/detect.sh).
VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo)
PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo)
case "$VENDOR/$PRODUCT" in
    Google/Nocturne) ;;                      # Pixel Slate — confirmed
    *)
        echo "Chrome EC present but $VENDOR/$PRODUCT is not on the confirmed" \
             "dead-delivery list; not offering to avoid racing a working EC"
        exit 1
        ;;
esac

echo "$VENDOR $PRODUCT: EC present, async delivery known-dead; in-kernel poll module applies"
exit 0
