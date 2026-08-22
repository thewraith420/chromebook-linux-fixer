#!/bin/bash
set -uo pipefail
SDEV=""
for s in imx319 imx355 ov5670 ov8856; do
    SDEV=$("$FIXER_REPO/lib/find-subdev.sh" "$s" 2>/dev/null)
    [ -n "$SDEV" ] && break
done
[ -n "$SDEV" ] || exit 1
if v4l2-ctl -d "$SDEV" -L 2>/dev/null | grep -q "camera_sensor_rotation"; then
    echo "kernel reports sensor rotation itself; no override needed"
    exit 0
fi
[ -f "$HOME/.config/environment.d/90-libcamera-orientation.conf" ] || exit 1
echo "orientation overrides configured"
