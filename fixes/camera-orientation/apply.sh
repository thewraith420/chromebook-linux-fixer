#!/bin/bash
set -euo pipefail
CONF="$HOME/.config/environment.d/90-libcamera-orientation.conf"
ROT="${CAMERA_ROTATION:-imx319:180,imx355:0}"
LOC="${CAMERA_LOCATION:-imx319:front,imx355:back}"
mkdir -p "$(dirname "$CONF")"
cat > "$CONF" <<CONFEOF
# Camera sensor mounting data. Managed by chromebook-fixer.
#
# The drivers do not expose rotation or front/back, and the firmware does not
# carry the ChromeOS SSDB table these values normally come from. Determined by
# looking at the picture; override with CAMERA_ROTATION / CAMERA_LOCATION.
LIBCAMERA_SENSOR_ROTATION=$ROT
LIBCAMERA_SENSOR_LOCATION=$LOC
CONFEOF
systemctl --user daemon-reload 2>/dev/null || true
systemctl --user set-environment "LIBCAMERA_SENSOR_ROTATION=$ROT" 2>/dev/null || true
systemctl --user set-environment "LIBCAMERA_SENSOR_LOCATION=$LOC" 2>/dev/null || true
systemctl --user restart pipewire.socket pipewire wireplumber 2>/dev/null || true
echo "wrote $CONF"
echo "  rotation: $ROT"
echo "  location: $LOC"
echo "If the picture is still wrong, re-run with e.g."
echo "  CAMERA_ROTATION=imx319:270,imx355:90 chromebook-fixer apply camera-orientation"
