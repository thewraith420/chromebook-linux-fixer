#!/bin/bash
set -uo pipefail
sudo systemctl disable --now chromebook-ec-buttons.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/chromebook-ec-buttons.service
sudo systemctl daemon-reload
echo "EC button service removed"
