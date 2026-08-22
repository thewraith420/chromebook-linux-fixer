#!/bin/bash
set -uo pipefail
command -v dkms >/dev/null 2>&1 || { echo "dkms not installed; nothing to revert"; exit 0; }
VER=$(dkms status 2>/dev/null | grep -oP 'ipu3-imgu-fixed/\K[^,:]+' | head -1)
[ -n "$VER" ] || { echo "no ipu3-imgu-fixed DKMS module registered"; exit 0; }
sudo dkms remove -m ipu3-imgu-fixed -v "$VER" --all
sudo depmod -a
echo "removed; the stock in-kernel ipu3-imgu is used again after reboot"
