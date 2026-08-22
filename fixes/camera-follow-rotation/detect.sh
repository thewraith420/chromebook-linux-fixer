#!/bin/bash
set -uo pipefail
# Only meaningful with an accelerometer AND a camera.
HAS=$(gdbus call --system --dest net.hadess.SensorProxy \
        --object-path /net/hadess/SensorProxy \
        --method org.freedesktop.DBus.Properties.Get \
        net.hadess.SensorProxy HasAccelerometer 2>/dev/null || true)
case "$HAS" in *true*) ;; *) exit 1 ;; esac
command -v cam >/dev/null 2>&1 || exit 1
OUT=$(timeout 60 cam -l 2>/dev/null || true)
printf '%s\n' "$OUT" | grep -qE "^[0-9]+: " || exit 1

systemctl --user is-enabled chromebook-camera-rotate.service >/dev/null 2>&1 && exit 1
echo "camera does not follow screen rotation (image stays fixed when the screen turns)"
exit 0
