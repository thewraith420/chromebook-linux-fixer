#!/bin/bash
# exit 0 = needed, 1 = not needed / not applicable, 2 = cannot tell
set -uo pipefail

# Needs an accelerometer to be worth anything.
HAS=$(gdbus call --system --dest net.hadess.SensorProxy \
        --object-path /net/hadess/SensorProxy \
        --method org.freedesktop.DBus.Properties.Get \
        net.hadess.SensorProxy HasAccelerometer 2>/dev/null || true)
case "$HAS" in *true*) ;; *) exit 1 ;; esac

# Already running ours?
systemctl --user is-enabled chromebook-autorotate.service >/dev/null 2>&1 && exit 1

# Does the desktop already rotate on its own? If mutter reports touch mode and
# has an accelerometer it will handle this itself, and we should stay out of
# the way rather than fight it.
echo "accelerometer present and no rotation service installed"
exit 0
