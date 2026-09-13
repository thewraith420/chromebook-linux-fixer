#!/bin/bash
# exit 0 = this fix set it, 1 = not set, 3 = set, but not by this fix
set -uo pipefail
MARK="set by chromebook-fixer (nightfall-default)"
F=/etc/default/grub

LINE=$(grep -hE '^GRUB_DEFAULT=' "$F" 2>/dev/null | head -1)
VALUE=$(printf '%s' "$LINE" | cut -d= -f2- | sed 's/[[:space:]]*#.*//' | tr -d '"')

case "$VALUE" in
    nightfall|picker) ;;
    *) exit 1 ;;
esac

# Bob set this by hand long before this fix existed, and someone else may do
# the same. The state is right either way, but saying "applied" would claim
# this fix put it there and offer a revert that would undo a change it never
# made. That is what exit 3 is for.
case "$LINE" in
    *"$MARK"*)
        echo "GRUB boots Nightfall by default (set by this fix)" ;;
    *)
        echo "GRUB already boots Nightfall by default, set by hand rather than"
        echo "by this fix - nothing here to revert"
        exit 3 ;;
esac
