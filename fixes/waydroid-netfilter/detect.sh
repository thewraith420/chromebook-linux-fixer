#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# exit 0 = needed, 1 = not needed / not applicable, 2 = cannot tell
set -uo pipefail
SCRIPT=/usr/lib/waydroid/data/scripts/waydroid-net.sh
[ -f "$SCRIPT" ] || exit 1                      # waydroid not installed
grep -q "chromebook-fixer" "$SCRIPT" && exit 1  # already patched by us

# Only needed when the legacy module genuinely cannot load.
modprobe -n ip_tables >/dev/null 2>&1 && exit 1

# The defect is the *preference order*, not the presence of the string. A file
# may mention iptables-legacy in a comment, or keep it as a deliberate
# fallback, and be perfectly correct. Testing for the bare string reported such
# a file as broken and invited a pointless re-patch.
# Anchored at column 0 on purpose: the primary assignment is unindented, while
# the fallback sits indented inside the "if". Allowing leading whitespace makes
# the pattern match the fallback too, so a correctly-ordered file reads as
# broken - which is exactly the false positive this replaced.
LEGACY_FIRST=0
grep -qE '^IPTABLES_BIN="\$\(command -v iptables-legacy\)"' "$SCRIPT" && LEGACY_FIRST=1
grep -qE '^IP6TABLES_BIN="\$\(command -v ip6tables-legacy\)"' "$SCRIPT" && LEGACY_FIRST=1
[ "$LEGACY_FIRST" -eq 1 ] || exit 1

echo "waydroid picks iptables-legacy first, but ip_tables cannot load on this kernel"
exit 0
