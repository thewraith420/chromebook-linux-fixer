#!/bin/bash
set -uo pipefail
IMGU=/sys/bus/pci/devices/0000:00:05.0
[ -d "$IMGU" ] || exit 1
TYPE=$(cat "$IMGU/iommu_group/type" 2>/dev/null || echo none)
case "$TYPE" in
    identity)
        if "$FIXER_REPO/lib/kernel-cmdline.sh" active iommu=pt; then
            echo "ImgU in identity domain via iommu=pt on the kernel cmdline"
        else
            echo "ImgU in identity domain via a kernel quirk (no boot parameter needed)"
        fi
        exit 0 ;;
    none)
        echo "no IOMMU group at all (IOMMU disabled)"; exit 0 ;;
esac
exit 1
