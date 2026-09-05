#!/bin/bash
set -uo pipefail
# Escalation is chosen by the caller: plain sudo in a terminal, pkexec
# under the GUI, which has no tty to prompt on. Never a bare "sudo".
SUDO="${FIXER_SUDO:-sudo}"
# One escalation, not four: pkexec has no credential cache (auth_admin, not
# auth_admin_keep), so each $SUDO is another authentication prompt.
$SUDO bash -s <<'ROOT'
set -u
systemctl disable --now chromebook-ec-buttons.service 2>/dev/null || true
rm -f /etc/systemd/system/chromebook-ec-buttons.service
rm -f /usr/local/bin/chromebook-ec-buttons
systemctl daemon-reload
ROOT
echo "EC button service removed"
