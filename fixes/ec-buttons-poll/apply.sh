#!/bin/bash
set -euo pipefail
# Escalation is chosen by the caller: plain sudo in a terminal, pkexec
# under the GUI, which has no tty to prompt on. Never a bare "sudo".
SUDO="${FIXER_SUDO:-sudo}"
DAEMON="$FIXER_REPO/daemon/chromebook-ec-buttons"
UNIT_SRC="$FIXER_REPO/daemon/chromebook-ec-buttons.service"
UNIT_DST=/etc/systemd/system/chromebook-ec-buttons.service
BIN_DST=/usr/local/bin/chromebook-ec-buttons
[ -x "$DAEMON" ] || { echo "missing $DAEMON"; exit 1; }

# Refuse to stack on the in-kernel poll (DKMS add-on or patch 9201): two drains
# of one FIFO race for events. These are alternatives - pick one.
if [ -d /sys/module/cros_ec_evpoll ] || \
   { P=/sys/module/cros_ec/parameters/ec_event_poll_ms; [ -r "$P" ] && [ "$(cat "$P")" -gt 0 ] 2>/dev/null; }; then
    echo "The kernel is already polling the EC event FIFO (patch 9201, or a"
    echo "leftover cros-ec-evpoll module from the removed ec-buttons-dkms fix)."
    echo "That and this userspace poll are alternatives and would race for the"
    echo "same events - unload the kernel one first. Nothing changed."
    exit 1
fi

echo "Installing the EC volume-button poll service (system, root)."
echo "This polls /dev/cros_ec and injects volume keys via uinput."
echo

# Install the daemon into /usr/local/bin rather than running it out of the
# repo. The unit sets ProtectHome=true, so a service pointed at
# $FIXER_REPO/daemon/... under /home cannot exec its own binary (203/EXEC);
# and a system service should not depend on /home being present or unlocked
# at boot regardless. The shipped unit already expects this path.
# One escalation, not four: pkexec has no credential cache (auth_admin, not
# auth_admin_keep), so each $SUDO is another authentication prompt.
$SUDO bash -s -- "$DAEMON" "$BIN_DST" "$UNIT_SRC" "$UNIT_DST" <<'ROOT'
set -euo pipefail
install -m 0755 "$1" "$2"
install -m 0644 "$3" "$4"
systemctl daemon-reload
systemctl enable --now chromebook-ec-buttons.service
ROOT
sleep 2
if systemctl is-active chromebook-ec-buttons.service >/dev/null 2>&1; then
    echo "EC button service running - press volume up/down to test"
else
    echo "service failed to start:"
    systemctl status chromebook-ec-buttons.service --no-pager -n 10 || true
    exit 1
fi
