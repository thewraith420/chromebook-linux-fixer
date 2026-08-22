#!/bin/bash
# Build and install a patched libcamera, choosing the ISP path that is safe on
# this kernel.
set -uo pipefail

echo "Checking whether the hardware ISP is usable on this kernel..."
echo

if "$FIXER_REPO/lib/imgu-safe.sh" >/dev/null 2>&1; then
    MODE=hardware
    echo "  Hardware ISP is SAFE here (ImgU is in a passthrough IOMMU domain)."
    echo "  Building libcamera with the ipu3 pipeline handler:"
    echo "    near-zero CPU, autofocus, best image quality."
else
    MODE=software
    echo "=================================================================="
    "$FIXER_REPO/lib/imgu-safe.sh" --why
    echo "=================================================================="
    echo
    echo "  Proceeding with the SOFTWARE ISP path instead. This needs no kernel"
    echo "  changes and cannot lock the machine. You get working cameras with"
    echo "  auto-exposure and auto-white-balance; you do not get autofocus, and"
    echo "  it costs most of a CPU core while streaming."
    echo
    echo "  Once the kernel can drive the ImgU safely, re-run:"
    echo "      chromebook-fixer apply ipu3-camera"
    echo "  and it will switch to the hardware path automatically."
fi
echo

BUILD="$FIX_DIR/build.sh"
[ -x "$BUILD" ] || { echo "missing $BUILD"; exit 1; }
exec "$BUILD" "$MODE"
