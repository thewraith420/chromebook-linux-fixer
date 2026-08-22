#!/bin/bash
set -euo pipefail
SCRIPT=/usr/lib/waydroid/data/scripts/waydroid-net.sh
BACKUP="$SCRIPT.chromebook-fixer.orig"
[ -f "$BACKUP" ] || sudo cp -a "$SCRIPT" "$BACKUP"
# Swap the preference order: try plain (nft-backed) iptables before legacy.
sudo python3 - "$SCRIPT" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
if "chromebook-fixer" not in s:
    s = s.replace("iptables-legacy", "iptables", 1)
    s = s.replace("ip6tables-legacy", "ip6tables", 1)
    s = "# Patched by chromebook-fixer: prefer nft-backed iptables, because\n" \
        "# kernels without CONFIG_NETFILTER_XTABLES_LEGACY cannot load ip_tables.\n" + s
    open(p, "w").write(s)
PY
echo "patched $SCRIPT (original at $BACKUP)"
