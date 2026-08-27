#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
SUDO="${FIXER_SUDO:-sudo}"
RULES=/etc/udev/rules.d/60-chromebook-accelerometer.rules

PRODUCT=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)

# Mount matrices are per-model and cannot be derived - they describe how the
# part was soldered. Add entries here as they are confirmed on real hardware;
# a wrong matrix is worse than none, so unknown models get polling only.
case "$PRODUCT" in
    Nocturne)  MATRIX="-1, 0, 0; 0, -1, 0; 0, 0, 1" ;;   # Pixel Slate, confirmed
    *)         MATRIX="" ;;
esac

{
    echo "# Written by chromebook-fixer (accelerometer-orientation)."
    echo "#"
    echo "# The EC's asynchronous event delivery does not work on these machines, so"
    echo "# iio-sensor-proxy never receives trigger-driven readings. Tell it to poll."
    echo 'SUBSYSTEM=="iio", ATTR{name}=="cros-ec-accel", ENV{IIO_SENSOR_PROXY_TYPE}="iio-poll-accel"'
    if [ -n "$MATRIX" ]; then
        echo ""
        echo "# Mount matrix for $PRODUCT: the sensor is not aligned with the panel."
        echo "ACTION==\"add\", SUBSYSTEM==\"iio\", ATTRS{name}==\"cros-ec-accel\", ENV{ACCEL_MOUNT_MATRIX}=\"$MATRIX\""
    fi
} | $SUDO tee "$RULES" >/dev/null

echo "wrote $RULES"
if [ -z "$MATRIX" ]; then
    echo
    echo "No mount matrix is known for '$PRODUCT', so only polling was configured."
    echo "If the screen now rotates but in the wrong direction, the matrix needs"
    echo "working out for this model - please contribute it back."
fi

$SUDO udevadm control --reload-rules
$SUDO udevadm trigger --subsystem-match=iio
systemctl restart iio-sensor-proxy 2>/dev/null || $SUDO systemctl restart iio-sensor-proxy 2>/dev/null || true
echo "reloaded udev and restarted iio-sensor-proxy"
