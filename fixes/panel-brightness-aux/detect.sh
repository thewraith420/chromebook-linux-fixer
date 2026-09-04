#!/bin/bash
# exit 0 = needed, 1 = not needed / not applicable, 2 = cannot tell
set -uo pipefail

# Needs an internal DisplayPort panel with an AUX channel to talk to.
HAVE_EDP=1
for dev in /sys/class/drm_dp_aux_dev/drm_dp_aux*; do
    [ -e "$dev" ] || continue
    case "$(readlink -f "$dev")" in
        *-eDP-*) HAVE_EDP=0 ;;
    esac
done
[ "$HAVE_EDP" -eq 0 ] || exit 1

# And a sysfs backlight interface to follow. Without one there is nothing to
# mirror - the desktop would have nothing to write to either.
ls /sys/class/backlight/*/brightness >/dev/null 2>&1 || exit 1

# Already running ours?
systemctl is-active chromebook-panel-brightness-aux.service >/dev/null 2>&1 && exit 1

# Whether the kernel already drives this panel's DPCD registers itself
# (a patched i915, or a future kernel that grew support) cannot be answered
# without reading /dev/drm_dp_aux*, which needs root - and detection runs
# unprivileged. apply.sh does that check properly and refuses to install if
# the kernel turns out to be driving them, so the worst case here is offering
# a fix that then declines to install itself.
#
# Board specific, so only offer where the dead-backlight fault is confirmed.
# Add boards here as they are verified.
VENDOR=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo)
PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo)
case "$VENDOR/$PRODUCT" in
    Google/Nocturne) ;;                      # Pixel Slate — confirmed
    *)
        echo "eDP AUX panel present but $VENDOR/$PRODUCT is not on the" \
             "confirmed dead-backlight list; not offering"
        exit 1
        ;;
esac

echo "$VENDOR $PRODUCT: eDP panel present, kernel-side DPCD backlight known-dead here"
exit 0
