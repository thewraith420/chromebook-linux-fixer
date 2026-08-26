#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -uo pipefail
SUDO="${FIXER_SUDO:-sudo}"

$SUDO systemctl disable --now fprintd-shim.service 2>/dev/null || true
$SUDO rm -f /etc/systemd/system/fprintd-shim.service
$SUDO rm -f /usr/local/libexec/fprintd-shim
$SUDO systemctl unmask fprintd.service 2>/dev/null || true
$SUDO systemctl daemon-reload

echo "removed the fingerprint bridge and unmasked fprintd."
echo "Enrolled templates are left in each user's ~/.var/cros-fp-templates;"
echo "delete that file to remove them."
