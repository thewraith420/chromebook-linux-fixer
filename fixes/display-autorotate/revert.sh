#!/bin/bash
set -uo pipefail
systemctl --user disable --now chromebook-autorotate.service 2>/dev/null || true
rm -f "$HOME/.config/systemd/user/chromebook-autorotate.service"
systemctl --user daemon-reload
echo "rotation service removed"
