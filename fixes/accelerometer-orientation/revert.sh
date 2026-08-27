#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail
SUDO="${FIXER_SUDO:-sudo}"
$SUDO rm -f /etc/udev/rules.d/60-chromebook-accelerometer.rules
$SUDO udevadm control --reload-rules
$SUDO systemctl restart iio-sensor-proxy 2>/dev/null || true
echo "removed the accelerometer rules."
