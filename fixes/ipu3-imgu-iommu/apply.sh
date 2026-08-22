#!/bin/bash
set -euo pipefail
echo "Adding iommu=pt to the kernel command line."
echo "The better fix is a per-device IOMMU quirk in the kernel, which needs no"
echo "boot parameter at all - see kernel/README.md. That requires a kernel rebuild."
echo
"$FIXER_REPO/lib/kernel-cmdline.sh" add iommu=pt
