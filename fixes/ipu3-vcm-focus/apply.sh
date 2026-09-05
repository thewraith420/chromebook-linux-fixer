#!/bin/bash
set -euo pipefail

# Escalation is chosen by the caller: plain sudo in a terminal, pkexec
# under the GUI, which has no tty to prompt on.
SUDO="${FIXER_SUDO:-sudo}"
POSITION="${VCM_FOCUS_POSITION:-1800}"
RULE=/etc/udev/rules.d/99-chromebook-vcm-focus.rules
# Match on ATTR{name}: /dev/v4l-subdevN numbering is not stable across reboots.
$SUDO tee "$RULE" >/dev/null <<RULES
# Chromebook rear-camera lens focus default. Managed by chromebook-fixer.
# The ak7375 VCM powers on at 0 (hard against one end of travel), leaving the
# rear camera a blur until something drives it.
ACTION=="add", SUBSYSTEM=="video4linux", ATTR{name}=="ak7375*", \\
  RUN+="/usr/bin/v4l2-ctl -d /dev/%k --set-ctrl=focus_absolute=$POSITION"
RULES
$SUDO udevadm control --reload-rules
$SUDO udevadm trigger --subsystem-match=video4linux --action=add
sleep 2
echo "installed $RULE (position $POSITION)"
