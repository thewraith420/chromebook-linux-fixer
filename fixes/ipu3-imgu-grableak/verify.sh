#!/bin/bash
set -uo pipefail
command -v dkms >/dev/null 2>&1 || exit 1
dkms status 2>/dev/null | grep -q "ipu3-imgu-fixed.*installed" || exit 1
echo "patched ipu3-imgu installed via DKMS"
