#!/bin/bash
set -euo pipefail
BACKUP="${XDG_CACHE_HOME:-$HOME/.cache}/chromebook-fixer/libcamera/usr-backup"
if [ -d "$BACKUP" ]; then
    echo "Restoring the previous libcamera install from $BACKUP ..."
    find "$BACKUP" -type f | while read -r f; do
        sudo install -o root -g root -m "$(stat -c%a "$f")" "$f" "${f#$BACKUP}"
    done
else
    echo "No backup found; restoring the distribution packages instead."
    sudo apt-get install --reinstall -y \
        libcamera0.7 libcamera-ipa libcamera-tools libcamera-v4l2
fi
sudo rm -f /etc/libcamera/configuration.yaml
sudo ldconfig
systemctl --user restart pipewire.socket pipewire wireplumber 2>/dev/null || true
echo "Reverted."
