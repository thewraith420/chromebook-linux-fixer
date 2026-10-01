#!/bin/bash
set -euo pipefail
SUDO="${FIXER_SUDO:-sudo}"
DAEMON="$FIXER_REPO/daemon/chromebook-panel-brightness-aux"
UNIT_SRC="$FIXER_REPO/daemon/chromebook-panel-brightness-aux.service"
# Overridable so this can be driven fixture-only (see tests/) without writing
# to the real /usr/local/bin or /etc/systemd/system - defaults are the real
# paths, unchanged. PANEL_AUX_BIN_DST is also what verify.sh looks at, so a
# test can point both at the same scratch file.
UNIT_DST="${PANEL_AUX_UNIT_DST:-/etc/systemd/system/chromebook-panel-brightness-aux.service}"
BIN_DST="${PANEL_AUX_BIN_DST:-/usr/local/bin/chromebook-panel-brightness-aux}"
DRM_DP_AUX_DIR="${DRM_DP_AUX_DIR:-/sys/class/drm_dp_aux_dev}"
BACKLIGHT_DIR="${BACKLIGHT_DIR:-/sys/class/backlight}"
[ -x "$DAEMON" ] || { echo "missing $DAEMON"; exit 1; }

# Locate the internal panel's AUX channel and a sysfs backlight to follow.
AUX=
for dev in "$DRM_DP_AUX_DIR"/drm_dp_aux*; do
    [ -e "$dev" ] || continue
    case "$(readlink -f "$dev")" in
        *-eDP-*) AUX="/dev/$(basename "$dev")"; break ;;
    esac
done
[ -n "$AUX" ] || { echo "no eDP AUX device found"; exit 1; }

BL=
for d in "$BACKLIGHT_DIR"/*/; do
    [ -r "${d}brightness" ] && { BL="${d%/}"; break; }
done
[ -n "$BL" ] || { echo "no /sys/class/backlight interface found"; exit 1; }

# Whether the kernel already drives this panel's DPCD registers itself (a
# patched i915, or a future kernel that grew support) used to be checked here
# and refused on - but the daemon runs the exact same probe, properly, at
# EVERY startup (dc5a29d: the earlier one-shot version here can be fooled by
# GNOME's automatic brightness moving sysfs mid-probe, and wrongly refuse to
# install on a kernel that in fact needs this bridge). The daemon is not
# reinstalled when you reboot into a different kernel, so its own fresh check
# is the one that has to be right regardless; this script no longer needs to
# get it right too; and INSTALLED-BUT-STANDING-DOWN is the correct state for
# a dual-boot system that sometimes boots a DPCD-capable kernel - uninstalling
# it there would just mean reinstalling it by hand on the next boot that does
# not drive DPCD.
#
# Still worth telling the person what to expect before they watch the service
# apparently "not start". $SUDO here, not plain: the probe needs root to open
# the AUX chardev, same privilege this whole apply already has.
echo "Checking whether the kernel already drives this panel over DPCD..."
WHY=$($SUDO "$DAEMON" --why 2>&1) || true
STANDING_DOWN=""
echo "  $WHY"
case "$WHY" in
    "stand down:"*)
        STANDING_DOWN=1
        echo "  Installing anyway: this kernel is not every kernel you might"
        echo "  boot into, and the service decides fresh at every startup -"
        echo "  it will sit idle on this one rather than fight the kernel for"
        echo "  the same registers." ;;
esac

echo "Installing the userspace brightness bridge. It follows $BL and writes $AUX."
echo

# Install the daemon into /usr/local/bin rather than running it out of the
# repo. The unit sets ProtectHome=true, so a service pointed at
# $FIXER_REPO/daemon/... under /home cannot exec its own binary (203/EXEC);
# and a system service should not depend on /home being present or unlocked
# at boot regardless. The shipped unit already expects this path.
$SUDO install -m 0755 "$DAEMON" "$BIN_DST"
$SUDO install -m 0644 "$UNIT_SRC" "$UNIT_DST"

$SUDO systemctl daemon-reload
$SUDO systemctl enable --now chromebook-panel-brightness-aux.service
sleep 2
if systemctl is-active chromebook-panel-brightness-aux.service >/dev/null 2>&1; then
    echo "Brightness bridge running - try the brightness keys or the slider"
elif [ -n "$STANDING_DOWN" ]; then
    # Type=simple + Restart=on-failure: a clean "stand down, exit 0" (the
    # outcome just announced above) looks exactly like a crash to systemd -
    # both read "inactive" a moment later. Expected here, not a failure.
    # verify.sh tells the two apart the same way, via --why, for status checks.
    echo "Installed and enabled; idle on this kernel as expected."
else
    echo "service failed to start:"
    systemctl status chromebook-panel-brightness-aux.service --no-pager -n 10 || true
    exit 1
fi
