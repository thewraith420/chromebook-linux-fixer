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

# "Known-dead here" is a claim about the KERNEL, and the lines above only
# establish the board. The same Nocturne runs kernels that drive this panel
# over AUX perfectly well - BobZKernel carries patch 9200, which relaxes the
# capability gate i915 7.x added, and on that kernel installing a second writer
# is the bug rather than the fix.
#
# The interface it picked says which happened, without needing root. i915
# drives this panel either through VESA AUX brightness-set, whose range is the
# full 16 bits, or through native PWM, whose range on this panel is 7500 - and
# native PWM is precisely the path that does not physically drive it. Those
# numbers are not guesses; they are the before and after in 9200's own commit
# message.
BL_MAX=
for d in /sys/class/backlight/*/max_brightness; do
    [ -r "$d" ] && { BL_MAX=$(cat "$d" 2>/dev/null); break; }
done
case "${BL_MAX:-}" in
    65535)
        echo "the kernel is already driving this panel over DPCD/AUX"
        echo "(backlight range ${BL_MAX}, the 16-bit VESA AUX range - native PWM"
        echo "would read 7500 here). A second writer would fight it."
        exit 1 ;;
    7500)
        ;;                              # native PWM: the fault this fixes
    *)
        echo "eDP panel present, but its backlight range (${BL_MAX:-unreadable})"
        echo "matches neither the VESA AUX range nor this panel's native PWM"
        echo "range, so which interface the kernel chose cannot be told from here"
        exit 2 ;;
esac

echo "$VENDOR $PRODUCT: eDP panel present, kernel on native PWM which does not"
echo "drive this panel (backlight range $BL_MAX)"
exit 0
