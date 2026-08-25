#!/bin/bash
set -uo pipefail
NAME=cros-ec-evpoll
VER=1.0
sudo modprobe -r "$NAME" 2>/dev/null || true
sudo rm -f /etc/modules-load.d/$NAME.conf
sudo dkms remove -m "$NAME" -v "$VER" --all 2>/dev/null || true
sudo rm -rf "/usr/src/$NAME-$VER"
echo "$NAME removed (module unloaded, DKMS package deleted)"
