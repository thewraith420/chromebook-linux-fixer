#!/bin/bash
set -uo pipefail

# FIXER_REPO is normally set by Fix.run(); default it so this still works
# when run by hand (set -u would otherwise kill it outright, which reads
# as "not needed" - a quiet wrong answer rather than a loud one).
FIXER_REPO="${FIXER_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SENSOR=""
for s in imx319 imx355 ov5670 ov8856; do
    SD=$("$FIXER_REPO/lib/find-subdev.sh" "$s" 2>/dev/null)
    [ -n "$SD" ] && { SENSOR="$s"; SDEV="$SD"; break; }
done
[ -n "$SENSOR" ] || exit 1

# If the kernel reports rotation itself, nothing to do - the quirk is present.
if v4l2-ctl -d "$SDEV" -L 2>/dev/null | grep -q "camera_sensor_rotation"; then
    exit 1
fi
[ -f "$HOME/.config/environment.d/90-libcamera-orientation.conf" ] && exit 1
echo "$SENSOR does not report its mounting rotation and no override is set"
exit 0
