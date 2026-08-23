#!/bin/bash
set -euo pipefail

# Escalation is chosen by the caller: plain sudo in a terminal,
# "sudo -A" under the GUI, which has no tty to prompt on.
SUDO="${FIXER_SUDO:-sudo}"
$SUDO rm -f /etc/udev/rules.d/99-chromebook-vcm-focus.rules
$SUDO udevadm control --reload-rules
echo "removed the focus udev rule (lens returns to its power-on default)"
