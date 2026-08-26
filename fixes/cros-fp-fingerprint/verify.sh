#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# exit 0 = this fix is in place and working, 1 = it is not
set -uo pipefail

systemctl is-active --quiet fprintd-shim.service 2>/dev/null || exit 1

# Ask the way GNOME asks. Capture first, then match: "cmd | grep -q" under
# pipefail reports failure when grep exits early, which has silently misreported
# a working fix before.
devices=$(timeout 15 dbus-send --system --print-reply \
    --dest=net.reactivated.Fprint /net/reactivated/Fprint/Manager \
    net.reactivated.Fprint.Manager.GetDevices 2>/dev/null || true)
case "$devices" in
    *object\ path*) ;;
    *) echo "service is running but offers no device"; exit 1 ;;
esac

echo "fingerprint device offered to GNOME via net.reactivated.Fprint"
exit 0
