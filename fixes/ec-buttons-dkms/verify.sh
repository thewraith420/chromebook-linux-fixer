#!/bin/bash
set -uo pipefail
NAME=cros-ec-evpoll
VER=1.0
dkms status -m "$NAME" -v "$VER" 2>/dev/null | grep -q installed || exit 1
if [ -d /sys/module/cros_ec_evpoll ]; then
    echo "$NAME installed (DKMS) and loaded"
else
    echo "$NAME installed (DKMS) but not currently loaded"
    exit 1
fi
