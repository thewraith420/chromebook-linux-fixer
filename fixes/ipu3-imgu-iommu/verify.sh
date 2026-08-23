#!/bin/bash
# exit 0 = this fix is in place, 1 = it is not,
#      3 = the ImgU is already safe, but not because of this fix
set -uo pipefail
IMGU=/sys/bus/pci/devices/0000:00:05.0
[ -d "$IMGU" ] || exit 1
TYPE=$(cat "$IMGU/iommu_group/type" 2>/dev/null || echo none)
case "$TYPE" in
    identity)
        if "$FIXER_REPO/lib/kernel-cmdline.sh" active iommu=pt; then
            echo "ImgU in identity domain via iommu=pt on the kernel cmdline"
            exit 0
        fi
        # Mainline carries a VT-d quirk that puts the integrated Intel IPU in a
        # passthrough domain at PCI enumeration, and some custom kernels carry a
        # per-device equivalent. Either way the hazard is gone and there is
        # nothing for this fix to add - saying "applied" would be a lie.
        echo "ImgU already in an identity domain via a kernel quirk;"
        echo "no boot parameter needed and nothing for this fix to do"
        exit 3 ;;
    none)
        echo "no IOMMU group at all (IOMMU disabled); nothing for this fix to do"
        exit 3 ;;
esac
exit 1
