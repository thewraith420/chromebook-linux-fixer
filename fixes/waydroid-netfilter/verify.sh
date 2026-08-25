#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# exit 0 = this fix is in place, 1 = it is not,
#      3 = the script is already correct, but not because of this fix
set -uo pipefail
SCRIPT=/usr/lib/waydroid/data/scripts/waydroid-net.sh
[ -f "$SCRIPT" ] || exit 1

if grep -q "chromebook-fixer" "$SCRIPT"; then
    echo "waydroid-net.sh patched to prefer nft-backed iptables"
    exit 0
fi

# Someone may have made the same correction by hand, or waydroid may have
# shipped it upstream. The end state is right either way, and claiming credit
# for it would be a lie.
if ! grep -qE '^IPTABLES_BIN="\$\(command -v iptables-legacy\)"' "$SCRIPT" \
   && ! grep -qE '^IP6TABLES_BIN="\$\(command -v ip6tables-legacy\)"' "$SCRIPT"; then
    echo "waydroid-net.sh already prefers the nft-backed binaries; nothing for this fix to do"
    exit 3
fi
exit 1
