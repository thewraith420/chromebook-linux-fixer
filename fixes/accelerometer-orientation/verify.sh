#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail
RULES=/etc/udev/rules.d/60-chromebook-accelerometer.rules
[ -e "$RULES" ] || {
    grep -rqs "IIO_SENSOR_PROXY_TYPE" /etc/udev/rules.d/ && {
        echo "accelerometer polling is configured, but not by this fix"; exit 3; }
    exit 1
}
echo "installed: $(grep -c . "$RULES") rule line(s)"
exit 0
