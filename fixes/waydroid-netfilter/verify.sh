#!/bin/bash
set -uo pipefail
SCRIPT=/usr/lib/waydroid/data/scripts/waydroid-net.sh
[ -f "$SCRIPT" ] || exit 1
grep -q "chromebook-fixer" "$SCRIPT" || exit 1
echo "waydroid-net.sh patched to prefer nft-backed iptables"
