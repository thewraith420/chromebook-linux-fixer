#!/bin/bash
set -uo pipefail
command -v dkms >/dev/null 2>&1 || exit 1
# Cheap negative first: `dkms status` takes about four seconds here, and this
# runs on every status check. DKMS always creates this directory for a module
# it knows about, so no directory means not installed. See detect.sh.
DKMS_ROOT="${DKMS_ROOT:-/var/lib/dkms}"
[ -d "$DKMS_ROOT/ipu3-imgu-fixed" ] || exit 1
dkms status 2>/dev/null | grep -q "ipu3-imgu-fixed.*installed" || exit 1
echo "patched ipu3-imgu installed via DKMS"
