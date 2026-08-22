#!/bin/bash
# dkms-support.sh — can this machine build out-of-tree kernel modules?
#
#   dkms-support.sh          exit 0 = yes, 1 = no
#   dkms-support.sh --why    explain, and say what is missing
#
# Building a patched copy of a single driver is far cheaper than rebuilding a
# kernel, and DKMS re-does it automatically on kernel updates. It needs three
# things: headers for the RUNNING kernel, dkms itself, and the ability to load
# an unsigned module.

set -uo pipefail
EXPLAIN=${1:-}
K=$(uname -r)
MISSING=()

BUILD="/lib/modules/$K/build"
[ -e "$BUILD" ] || MISSING+=("kernel headers for $K (no $BUILD)")

# CONFIG_MODVERSIONS kernels need Module.symvers or symbol CRCs will not match.
if [ -e "$BUILD" ] && grep -q modversions <<<"$(modinfo ipu3_imgu 2>/dev/null || true)"; then
    [ -e "$BUILD/Module.symvers" ] || MISSING+=("Module.symvers (kernel uses CONFIG_MODVERSIONS)")
fi

command -v dkms >/dev/null 2>&1 || MISSING+=("dkms (apt install dkms)")

if [ "$(cat /sys/module/module/parameters/sig_enforce 2>/dev/null || echo N)" = Y ]; then
    MISSING+=("module signature enforcement is ON; a self-built module will not load")
fi

if [ ${#MISSING[@]} -eq 0 ]; then
    [ "$EXPLAIN" = --why ] && echo "Out-of-tree module builds are possible on this machine."
    exit 0
fi

if [ "$EXPLAIN" = --why ]; then
    echo "This machine cannot build out-of-tree kernel modules yet."
    echo
    for m in "${MISSING[@]}"; do echo "  missing: $m"; done
    echo
    echo "Headers are the usual blocker on a custom kernel. Whoever builds it"
    echo "should ship the matching linux-headers package - 'make bindeb-pkg'"
    echo "produces one alongside the image. See KERNEL_HEADERS_REQUEST.md."
fi
exit 1
