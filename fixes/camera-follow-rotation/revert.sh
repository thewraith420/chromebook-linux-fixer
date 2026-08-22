#!/bin/bash
set -uo pipefail
systemctl --user disable --now chromebook-camera-rotate.service 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/chromebook-camera-rotate.service"
systemctl --user daemon-reload
sudo rm -f /etc/modprobe.d/chromebook-camera-loopback.conf \
           /etc/modules-load.d/chromebook-camera-loopback.conf
sudo modprobe -r v4l2loopback 2>/dev/null || true
echo "rotation bridge removed (v4l2loopback package left installed)"
