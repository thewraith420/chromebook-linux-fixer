#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
SUDO="${FIXER_SUDO:-sudo}"

$SUDO install -m755 "$FIX_DIR/src/chromebook-tablet-switch.py" \
    /usr/local/bin/chromebook-tablet-switch.py

$SUDO tee /etc/systemd/system/chromebook-tablet-switch.service >/dev/null <<'UNIT'
[Unit]
Description=Synthetic always-on SW_TABLET_MODE switch (lets GNOME auto-rotate)
After=systemd-udevd.service
# Must exist before the display manager starts, or mutter decides at startup
# that this is not a tablet and never reconsiders.
Before=display-manager.service gdm.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/chromebook-tablet-switch.py
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

$SUDO systemctl daemon-reload
$SUDO systemctl enable --now chromebook-tablet-switch.service
sleep 2

if systemctl is-active --quiet chromebook-tablet-switch.service; then
    echo "running. Log out and back in for mutter to notice the switch."
else
    echo "failed to start:"; systemctl status chromebook-tablet-switch.service --no-pager -n 15
    exit 1
fi
