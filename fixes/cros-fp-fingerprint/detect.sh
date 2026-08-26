#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# exit 0 = needed, 1 = not needed / not applicable, 2 = cannot tell
set -uo pipefail

[ -e /dev/cros_fp ] || exit 1                      # no fingerprint MCU here

# Already ours?
systemctl is-active --quiet fprintd-shim.service 2>/dev/null && exit 1

# Does anything already offer a fingerprint device? If some future libfprint
# grows a cros_fp driver, this fix becomes unnecessary rather than wrong.
devices=$(timeout 15 dbus-send --system --print-reply \
    --dest=net.reactivated.Fprint /net/reactivated/Fprint/Manager \
    net.reactivated.Fprint.Manager.GetDevices 2>/dev/null || true)
case "$devices" in
    *object\ path*) exit 1 ;;                      # something already handles it
esac

echo "fingerprint MCU present at /dev/cros_fp but no fprintd device is offered"
exit 0
