#!/bin/bash
set -euo pipefail
DAEMON="$FIXER_REPO/daemon/chromebook-ec-buttons"
UNIT_SRC="$FIXER_REPO/daemon/chromebook-ec-buttons.service"
UNIT_DST=/etc/systemd/system/chromebook-ec-buttons.service
[ -x "$DAEMON" ] || { echo "missing $DAEMON"; exit 1; }

# Refuse to stack on the in-kernel poll (DKMS add-on or patch 9201): two drains
# of one FIFO race for events. These are alternatives - pick one.
if [ -d /sys/module/cros_ec_evpoll ] || \
   { P=/sys/module/cros_ec/parameters/ec_event_poll_ms; [ -r "$P" ] && [ "$(cat "$P")" -gt 0 ] 2>/dev/null; }; then
    echo "The kernel is already polling the EC event FIFO (ec-buttons-dkms or"
    echo "patch 9201). That and this userspace poll are alternatives - revert"
    echo "the kernel one first if you want to switch. Nothing changed."
    exit 1
fi

echo "Installing the EC volume-button poll service (system, root)."
echo "This polls /dev/cros_ec and injects volume keys via uinput."
echo

# Point the unit at the daemon in the repo, like the other daemon fixes do.
sed "s|^ExecStart=.*|ExecStart=$DAEMON|" "$UNIT_SRC" | sudo tee "$UNIT_DST" >/dev/null

sudo systemctl daemon-reload
sudo systemctl enable --now chromebook-ec-buttons.service
sleep 2
if systemctl is-active chromebook-ec-buttons.service >/dev/null 2>&1; then
    echo "EC button service running - press volume up/down to test"
else
    echo "service failed to start:"
    systemctl status chromebook-ec-buttons.service --no-pager -n 10 || true
    exit 1
fi
