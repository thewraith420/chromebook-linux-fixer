#!/bin/bash
set -euo pipefail

# Escalation is chosen by the caller: plain sudo in a terminal, pkexec
# under the GUI, which has no tty to prompt on.
SUDO="${FIXER_SUDO:-sudo}"

# v4l2loopback is not always out-of-tree. The BobZKernel pixel-slate branch
# vendors it (patch 9205, CONFIG_V4L2LOOPBACK=m) and some distros ship it, in
# which case there is nothing to build and no reason to want a toolchain or
# kernel headers. Demanding them anyway refuses the whole fix on a self-built
# kernel with no headers package - for a module that is already installed and
# loadable. That combination is not hypothetical: it is what the reference
# machine runs, and 9205 exists partly because DKMS had already silently
# skipped that kernel for want of a build/ tree.
RUNNING=$(uname -r)
if modinfo v4l2loopback >/dev/null 2>&1; then
    echo "v4l2loopback is already available for $RUNNING; nothing to build."
elif ! "$FIXER_REPO/lib/dkms-support.sh" --kernel "$RUNNING" 2>/dev/null; then
    echo "Cannot build v4l2loopback for the running kernel ($RUNNING):"
    echo "  no headers at /lib/modules/$RUNNING/build"
    echo
    mapfile -t OK < <("$FIXER_REPO/lib/dkms-support.sh" --list 2>/dev/null)
    if [ ${#OK[@]} -gt 0 ]; then
        echo "These installed kernels do have headers, and the module can build there:"
        printf '    %s\n' "${OK[@]}"
        echo
        echo "Options:"
        echo "  - boot one of those kernels, or"
        echo "  - install the linux-headers package matching $RUNNING."
        echo "    For a self-built kernel, 'make bindeb-pkg' produces one"
        echo "    alongside the image. See KERNEL_HEADERS_REQUEST.md."
    fi
    echo
    echo "Nothing was changed."
    exit 1
else
    # Absent, but buildable for the running kernel: DKMS will produce a module
    # that actually loads. DKMS otherwise happily builds for every kernel it
    # has headers for and silently skips the one in use, which then fails at
    # modprobe with a confusing "module not found".
    echo "Installing v4l2loopback (builds a kernel module via DKMS)..."
    $SUDO apt-get install -y v4l2loopback-dkms
fi

# Load now, and on every boot, with a stable card label the daemon looks for.
$SUDO tee /etc/modprobe.d/chromebook-camera-loopback.conf >/dev/null <<'CONF'
# Loopback device used to republish the camera with rotation applied.
#
# exclusive_caps=0 is deliberate, despite exclusive_caps=1 being the usual
# advice. With 1, the device advertises CAPTURE only while a producer is
# actively streaming - so the daemon would have to hold the sensor open
# forever, keeping the hardware privacy LED lit and burning half a CPU core
# at idle. With 0 the device always advertises CAPTURE, so the daemon can
# open the sensor only when something actually reads the loopback. It also
# removes a race: WirePlumber probes the device at boot, and under
# exclusive_caps=1 it saw OUTPUT-only and never offered it as a camera.
#
# video_nr=31 keeps it out of the way. Left to itself the loopback claims
# /dev/video0 and pushes every real device up by one, which silently
# invalidates anything that recorded a video node number.
options v4l2loopback video_nr=31 card_label="Chromebook Camera" exclusive_caps=0 max_buffers=2
CONF
$SUDO tee /etc/modules-load.d/chromebook-camera-loopback.conf >/dev/null <<< "v4l2loopback"

# Stop any previous instance first. The daemon holds the loopback open, so
# "modprobe -r" would fail, the "|| true" would swallow it, and the reload
# would quietly keep the module's old options - meaning a re-apply appears to
# succeed while changing nothing.
if systemctl --user is-active --quiet chromebook-camera-rotate.service; then
    echo "stopping the running rotation daemon so the module can reload"
    systemctl --user stop chromebook-camera-rotate.service
fi
$SUDO modprobe -r v4l2loopback 2>/dev/null || true
if lsmod | grep -q '^v4l2loopback'; then
    echo "v4l2loopback is still in use and could not be reloaded:"
    fuser -v /dev/video* 2>&1 | grep -i "chromebook\|video" || true
    echo "close whatever is using it, or reboot, then re-apply."
    exit 1
fi
$SUDO modprobe v4l2loopback
sleep 1

DEV=""
for n in /sys/class/video4linux/video*/name; do
    grep -qi "chromebook camera" "$n" 2>/dev/null && DEV="/dev/$(basename "$(dirname "$n")")"
done
[ -n "$DEV" ] || { echo "loopback device did not appear"; exit 1; }
echo "loopback device: $DEV"

UNIT="$HOME/.config/systemd/user/chromebook-camera-rotate.service"
mkdir -p "$(dirname "$UNIT")"
cat > "$UNIT" <<UNITEOF
[Unit]
Description=Republish the camera with rotation following the accelerometer
PartOf=graphical-session.target
After=graphical-session.target

[Service]
Type=simple
ExecStart=$FIXER_REPO/daemon/chromebook-camera-rotate --width 1280 --height 720
Restart=on-failure
RestartSec=5
# The loopback only advertises CAPTURE once this daemon attaches, and
# WirePlumber probed it long before that. Without this it never becomes a
# selectable camera. Runs on every start, because the race repeats each boot.
ExecStartPost=$FIXER_REPO/daemon/chromebook-camera-nudge-pipewire

[Install]
WantedBy=graphical-session.target
UNITEOF

systemctl --user daemon-reload
systemctl --user enable --now chromebook-camera-rotate.service
sleep 4
if systemctl --user is-active chromebook-camera-rotate.service >/dev/null 2>&1; then
    echo "running. Applications should now offer \"Chromebook Camera\"."
    echo
    echo "The real sensor is held open by this daemon, so it is no longer"
    echo "offered separately - that is expected, not a failure."
else
    echo "service failed to start:"
    systemctl --user status chromebook-camera-rotate.service --no-pager -n 15
    exit 1
fi
