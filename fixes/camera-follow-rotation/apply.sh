#!/bin/bash
set -euo pipefail

if ! modinfo v4l2loopback >/dev/null 2>&1; then
    echo "Installing v4l2loopback (builds a kernel module via DKMS)..."
    sudo apt-get install -y v4l2loopback-dkms
fi

# Load now, and on every boot, with a stable card label the daemon looks for.
sudo tee /etc/modprobe.d/chromebook-camera-loopback.conf >/dev/null <<'CONF'
# Loopback device used to republish the camera with rotation applied.
# exclusive_caps=1 makes it advertise itself as capture-only once a producer is
# attached, which is what applications expect from a webcam.
options v4l2loopback card_label="Chromebook Camera" exclusive_caps=1 max_buffers=2
CONF
echo "v4l2loopback" | sudo tee /etc/modules-load.d/chromebook-camera-loopback.conf >/dev/null

sudo modprobe -r v4l2loopback 2>/dev/null || true
sudo modprobe v4l2loopback
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

[Install]
WantedBy=graphical-session.target
UNITEOF

systemctl --user daemon-reload
systemctl --user enable --now chromebook-camera-rotate.service
sleep 4
if systemctl --user is-active chromebook-camera-rotate.service >/dev/null 2>&1; then
    echo "running. Select \"Chromebook Camera\" in your camera application."
else
    echo "service failed to start:"
    systemctl --user status chromebook-camera-rotate.service --no-pager -n 15
    exit 1
fi
