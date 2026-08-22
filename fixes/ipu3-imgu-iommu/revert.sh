#!/bin/bash
set -euo pipefail
"$FIXER_REPO/lib/kernel-cmdline.sh" remove iommu=pt
