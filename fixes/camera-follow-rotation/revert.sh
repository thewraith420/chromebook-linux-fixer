#!/bin/bash
set -uo pipefail

# Escalation is chosen by the caller: plain sudo in a terminal, pkexec
# under the GUI, which has no tty to prompt on.
SUDO="${FIXER_SUDO:-sudo}"
systemctl --user disable --now chromebook-camera-rotate.service 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/chromebook-camera-rotate.service"
systemctl --user daemon-reload
$SUDO rm -f /etc/modprobe.d/chromebook-camera-loopback.conf \
           /etc/modules-load.d/chromebook-camera-loopback.conf
$SUDO modprobe -r v4l2loopback 2>/dev/null || true
echo "rotation bridge removed (v4l2loopback package left installed)"
