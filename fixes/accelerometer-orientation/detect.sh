#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# exit 0 = needed, 1 = not needed / not applicable, 2 = cannot tell
set -uo pipefail
RULES=/etc/udev/rules.d/60-chromebook-accelerometer.rules
[ -e "$RULES" ] && exit 1

have_accel=0
for f in /sys/bus/iio/devices/iio:device*/name; do
    grep -qs "cros-ec-accel" "$f" && have_accel=1
done
[ "$have_accel" = "1" ] || exit 1

# Another rule already doing this?
grep -rqs "IIO_SENSOR_PROXY_TYPE" /etc/udev/rules.d/ && exit 1

echo "cros-ec-accel present with no polling hint or mount matrix configured"
exit 0
