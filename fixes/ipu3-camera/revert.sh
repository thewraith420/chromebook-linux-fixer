#!/bin/bash
set -euo pipefail

# Escalation is chosen by the caller: plain sudo in a terminal, pkexec
# under the GUI, which has no tty to prompt on.
SUDO="${FIXER_SUDO:-sudo}"
BACKUP="${XDG_CACHE_HOME:-$HOME/.cache}/chromebook-fixer/libcamera/usr-backup"
if [ -d "$BACKUP" ]; then
    echo "Restoring the previous libcamera install from $BACKUP ..."
    find "$BACKUP" -type f | while read -r f; do
        $SUDO install -o root -g root -m "$(stat -c%a "$f")" "$f" "${f#$BACKUP}"
    done
else
    echo "No backup found; restoring the distribution packages instead."
    $SUDO apt-get install --reinstall -y \
        libcamera0.7 libcamera-ipa libcamera-tools libcamera-v4l2
fi
$SUDO rm -f /etc/libcamera/configuration.yaml
$SUDO ldconfig
systemctl --user restart pipewire.socket pipewire wireplumber 2>/dev/null || true
echo "Reverted."
