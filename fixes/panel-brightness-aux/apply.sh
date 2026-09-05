#!/bin/bash
set -euo pipefail
SUDO="${FIXER_SUDO:-sudo}"
DAEMON="$FIXER_REPO/daemon/chromebook-panel-brightness-aux"
UNIT_SRC="$FIXER_REPO/daemon/chromebook-panel-brightness-aux.service"
UNIT_DST=/etc/systemd/system/chromebook-panel-brightness-aux.service
BIN_DST=/usr/local/bin/chromebook-panel-brightness-aux
[ -x "$DAEMON" ] || { echo "missing $DAEMON"; exit 1; }

# Locate the internal panel's AUX channel and a sysfs backlight to follow.
AUX=
for dev in /sys/class/drm_dp_aux_dev/drm_dp_aux*; do
    [ -e "$dev" ] || continue
    case "$(readlink -f "$dev")" in
        *-eDP-*) AUX="/dev/$(basename "$dev")"; break ;;
    esac
done
[ -n "$AUX" ] || { echo "no eDP AUX device found"; exit 1; }

BL=
for d in /sys/class/backlight/*/; do
    [ -r "${d}brightness" ] && { BL="${d%/}"; break; }
done
[ -n "$BL" ] || { echo "no /sys/class/backlight interface found"; exit 1; }

# Refuse to stack on a kernel that already drives these registers itself
# (a patched i915, or a newer kernel that grew support). Two writers on one
# panel is a bug, not a belt and braces. The check is behavioural rather than
# a version test: nudge the sysfs interface and see whether the panel's DPCD
# brightness follows it.
echo "Checking whether the kernel already drives this panel over DPCD..."
VERDICT=$($SUDO python3 - "$AUX" "$BL" <<'PY'
import os, sys, time
aux, bl = sys.argv[1], sys.argv[2]
BRIGHT = 0x722
try:
    fd = os.open(aux, os.O_RDWR)
except OSError as exc:
    print(f"error:cannot open {aux}: {exc}")
    raise SystemExit(0)

def dpcd():
    raw = os.pread(fd, 2, BRIGHT)
    return (raw[0] << 8) | raw[1]

cap1 = os.pread(fd, 1, 0x701)[0]
adj = os.pread(fd, 1, 0x702)[0]
if not (cap1 & 0x01) or not (adj & 0x02):
    print("error:panel does not advertise AUX backlight control")
    raise SystemExit(0)

with open(f"{bl}/brightness") as fh:
    orig = int(fh.read().strip())
with open(f"{bl}/max_brightness") as fh:
    mx = int(fh.read().strip())

before = dpcd()
probe = max(1, int(mx * 0.4)) if orig > mx * 0.6 else min(mx, int(mx * 0.9))
try:
    with open(f"{bl}/brightness", "w") as fh:
        fh.write(str(probe))
    time.sleep(0.4)
    after = dpcd()
finally:
    with open(f"{bl}/brightness", "w") as fh:
        fh.write(str(orig))
    time.sleep(0.2)

print("kernel-drives" if after != before else "kernel-inert")
PY
)

case "$VERDICT" in
    error:*)
        echo "${VERDICT#error:}" >&2
        exit 1 ;;
    kernel-drives)
        echo "This kernel already drives the panel's DPCD backlight registers"
        echo "itself - the slider is reaching the panel without help. Installing"
        echo "this service would give the panel two writers. Nothing changed."
        exit 1 ;;
    kernel-inert) ;;
    *)
        echo "could not determine whether the kernel drives DPCD ($VERDICT)" >&2
        exit 1 ;;
esac

echo "Kernel is not driving DPCD - installing the userspace brightness bridge."
echo "It follows $BL and writes $AUX."
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
else
    echo "service failed to start:"
    systemctl status chromebook-panel-brightness-aux.service --no-pager -n 10 || true
    exit 1
fi
