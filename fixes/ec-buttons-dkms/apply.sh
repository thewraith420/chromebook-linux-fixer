#!/bin/bash
set -euo pipefail
NAME=cros-ec-evpoll
VER=1.0
SRC="$FIXER_REPO/fixes/ec-buttons-dkms/src"
USRSRC="/usr/src/$NAME-$VER"

# Don't stack on the userspace poll - they race the same FIFO.
if systemctl is-active chromebook-ec-buttons.service >/dev/null 2>&1; then
    echo "The userspace poll (ec-buttons-poll) is active. It and this module are"
    echo "alternatives - revert it first if you want to switch. Nothing changed."
    exit 1
fi

# Can this machine build out-of-tree modules at all?
if ! "$FIXER_REPO/lib/dkms-support.sh" --kernel "$(uname -r)" >/dev/null 2>&1; then
    echo "Cannot build the module for the running kernel yet:"
    echo
    "$FIXER_REPO/lib/dkms-support.sh" --why || true
    echo
    echo "Install the matching kernel headers (and dkms), then re-apply."
    exit 1
fi

echo "Building and installing the $NAME kernel module via DKMS."

# Stage the source and register it with DKMS (clean re-runs).
sudo dkms remove -m "$NAME" -v "$VER" --all >/dev/null 2>&1 || true
sudo rm -rf "$USRSRC"
sudo cp -r "$SRC" "$USRSRC"

sudo dkms add     -m "$NAME" -v "$VER"
sudo dkms build   -m "$NAME" -v "$VER" -k "$(uname -r)"
sudo dkms install -m "$NAME" -v "$VER" -k "$(uname -r)" --force

# Load now and on every boot (after cros_ec, which the symbol dep pulls in).
echo "$NAME" | sudo tee /etc/modules-load.d/$NAME.conf >/dev/null
sudo modprobe "$NAME"

sleep 1
if [ -d /sys/module/cros_ec_evpoll ]; then
    echo "$NAME loaded - press volume up/down (and try auto-rotate) to test"
else
    echo "module built but did not load:"; sudo dmesg | tail -5; exit 1
fi
