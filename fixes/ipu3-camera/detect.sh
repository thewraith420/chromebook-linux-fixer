#!/bin/bash
# exit 0 = needed, 1 = not needed / not applicable, 2 = cannot tell
set -uo pipefail

# Applicable only where an IPU3 CIO2 exists with a supported sensor.
[ -d /sys/bus/pci/devices/0000:00:14.3 ] || exit 1
SENSOR=""
for s in imx319 imx355; do
    [ -n "$("$FIXER_REPO/lib/find-subdev.sh" "$s" 2>/dev/null)" ] && SENSOR="$s" && break
done
[ -n "$SENSOR" ] || exit 1

command -v cam >/dev/null 2>&1 || { echo "libcamera tools not installed"; exit 0; }

# The real question: does libcamera actually enumerate any camera?
COUNT=$(timeout 60 cam -l 2>/dev/null | grep -cE "^[0-9]+: " || true)
if [ "${COUNT:-0}" -gt 0 ]; then
    exit 1                                   # cameras work already
fi

echo "$SENSOR present but libcamera enumerates no cameras"
exit 0
