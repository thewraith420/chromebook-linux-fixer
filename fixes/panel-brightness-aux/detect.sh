#!/bin/bash
# exit 0 = needed, 1 = not needed / not applicable, 2 = cannot tell
set -uo pipefail

# Overridable so this can be driven fixture-only (see tests/) - defaults are
# the real paths, unchanged. Shared names with apply.sh on purpose.
DRM_DP_AUX_DIR="${DRM_DP_AUX_DIR:-/sys/class/drm_dp_aux_dev}"
BACKLIGHT_DIR="${BACKLIGHT_DIR:-/sys/class/backlight}"
DMI_SYS_VENDOR="${DMI_SYS_VENDOR:-/sys/class/dmi/id/sys_vendor}"
DMI_PRODUCT_NAME="${DMI_PRODUCT_NAME:-/sys/class/dmi/id/product_name}"

# Needs an internal DisplayPort panel with an AUX channel to talk to.
HAVE_EDP=1
for dev in "$DRM_DP_AUX_DIR"/drm_dp_aux*; do
    [ -e "$dev" ] || continue
    case "$(readlink -f "$dev")" in
        *-eDP-*) HAVE_EDP=0 ;;
    esac
done
[ "$HAVE_EDP" -eq 0 ] || exit 1

# And a sysfs backlight interface to follow. Without one there is nothing to
# mirror - the desktop would have nothing to write to either.
ls "$BACKLIGHT_DIR"/*/brightness >/dev/null 2>&1 || exit 1

# Already running ours?
systemctl is-active chromebook-panel-brightness-aux.service >/dev/null 2>&1 && exit 1

# Whether the kernel already drives this panel's DPCD registers itself
# (a patched i915, or a future kernel that grew support) cannot be answered
# without reading /dev/drm_dp_aux*, which needs root - and detection runs
# unprivileged. apply.sh checks properly (as root) and installs either way:
# the daemon runs the same probe fresh at every startup and stands itself
# down on a kernel that drives DPCD on its own, which is the correct state on
# a system that dual-boots into more than one kernel. verify.sh (also
# unprivileged, via the daemon's own --why) is what reports that standing-down
# as "nothing for this fix to do" rather than "broken" - so the worst case
# here is offering an install that the daemon then sits idle on.
#
# Board specific, so only offer where the dead-backlight fault is confirmed.
# Add boards here as they are verified.
VENDOR=$(cat "$DMI_SYS_VENDOR" 2>/dev/null || echo)
PRODUCT=$(cat "$DMI_PRODUCT_NAME" 2>/dev/null || echo)
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
# message, and were then measured again from the other direction on this
# machine: on 7.2.3 (which has 9200) the range is 65535 and the DPCD probe
# shows the kernel driving the register, while on 7.0.0-30-generic (which does
# not) the range is 7500 and the register does not follow. Range and behaviour
# agree on both kernels, so this is not a proxy that happens to correlate.
#
# BOTH NUMBERS ARE PROPERTIES OF THIS PANEL, NOT UNIVERSAL. 7500 is Nocturne's
# native PWM range; another board's will differ. The DMI gate above is what
# makes hardcoding them safe, so if you widen that gate, re-measure both values
# on the board you are adding - otherwise its unrecognised range quietly
# becomes exit 2 on hardware this fix would have helped. apply.sh's DPCD probe
# is the backstop either way, since it observes rather than infers.
BL_MAX=
for d in "$BACKLIGHT_DIR"/*/max_brightness; do
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
