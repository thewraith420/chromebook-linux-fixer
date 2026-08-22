#!/bin/bash
set -uo pipefail
rm -f "$HOME/.config/environment.d/90-libcamera-orientation.conf"
systemctl --user unset-environment LIBCAMERA_SENSOR_ROTATION LIBCAMERA_SENSOR_LOCATION 2>/dev/null || true
systemctl --user daemon-reload 2>/dev/null || true
systemctl --user restart pipewire.socket pipewire wireplumber 2>/dev/null || true
echo "orientation overrides removed"
